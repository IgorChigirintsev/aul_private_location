-- --- push subscriptions ---

-- Register a device for push on either channel. `kind` says how to read the
-- row: a webpush row's endpoint is a push-service URL with p256dh/auth beside
-- it; an fcm row's endpoint IS the registration token, with both keys NULL
-- (see migration 00008). One row shape, one unique key, one prune path.
--
-- kind is updated on conflict too: the same opaque string re-registering under
-- the other channel is nonsense, but if it ever happened the row must not keep
-- claiming a shape its key material no longer matches.
-- name: UpsertPushSubscription :one
INSERT INTO push_subscriptions (user_id, device_id, endpoint, p256dh, auth, kind)
VALUES ($1, $2, $3, $4, $5, $6)
ON CONFLICT (endpoint) DO UPDATE
SET p256dh = EXCLUDED.p256dh, auth = EXCLUDED.auth, user_id = EXCLUDED.user_id,
    kind = EXCLUDED.kind
RETURNING *;

-- Unsubscribe by the row's opaque address: a push endpoint URL for webpush, the
-- registration token for fcm. Both live in `endpoint`, so one query serves both.
-- name: DeletePushSubscription :exec
DELETE FROM push_subscriptions WHERE endpoint = $1 AND user_id = $2;

-- Every push subscription that should receive the sender's notification: the
-- circle's members, minus the sender themselves (who must not notify their own
-- devices), minus anyone who muted this circle or muted the sender. Drives the
-- /notify fan-out.
--
-- The mute filter lives HERE, on the send path, because the product requirement
-- is "other members stop sending to me" — a muted recipient's endpoint is never
-- handed to the push service, rather than the device receiving the push and
-- hiding it. sender_user_id is therefore both the excluded user and the mute
-- target to test: they are the same person.
--
-- `kind` selects the delivery channel per row (webpush or fcm); a member with
-- both a browser subscription and a phone token simply has two rows and gets
-- both. The mute filter below is channel-agnostic on purpose: it drops the
-- RECIPIENT, so muting silences every device they own, not just their browser.
-- name: ListCirclePushSubscriptions :many
SELECT ps.id, ps.user_id, ps.endpoint, ps.p256dh, ps.auth, ps.kind
FROM push_subscriptions ps
JOIN circle_members cm ON cm.user_id = ps.user_id
WHERE cm.circle_id = $1
  AND ps.user_id <> sqlc.arg(sender_user_id)
  AND NOT EXISTS (
      SELECT 1 FROM notification_mutes m
      WHERE m.user_id = ps.user_id
        AND m.circle_id = $1
        AND (m.muted_user_id IS NULL OR m.muted_user_id = sqlc.arg(sender_user_id))
  )
ORDER BY ps.created_at;

-- Prune a subscription the push service reported as gone (404/410).
-- name: DeletePushSubscriptionByID :exec
DELETE FROM push_subscriptions WHERE id = $1;

-- --- app versions ---

-- name: LatestActiveVersion :one
SELECT * FROM app_versions
WHERE platform = $1 AND is_active = true
ORDER BY version_code DESC
LIMIT 1;

-- name: UpsertAppVersion :one
INSERT INTO app_versions (
    platform, version_code, version_name, apk_url, sha256, changelog, min_supported, is_active
) VALUES ($1, $2, $3, $4, $5, $6, $7, true)
ON CONFLICT (platform, version_code) DO UPDATE SET
    version_name = EXCLUDED.version_name,
    apk_url = EXCLUDED.apk_url,
    sha256 = EXCLUDED.sha256,
    changelog = EXCLUDED.changelog,
    min_supported = EXCLUDED.min_supported,
    is_active = true
RETURNING *;

-- --- audit log ---

-- name: WriteAudit :exec
INSERT INTO audit_log (event, actor_user_id, actor_device_id, circle_id, ip, detail)
VALUES ($1, $2, $3, $4, $5, $6);

-- name: ListAuditForUser :many
SELECT * FROM audit_log
WHERE actor_user_id = $1
ORDER BY ts DESC
LIMIT $2;

-- --- login attempts (persistent lockout) ---

-- name: RecordLoginAttempt :exec
INSERT INTO login_attempts (email, ip, success)
VALUES ($1, $2, $3);

-- Count consecutive recent failures for an email since its last success,
-- within a window. Drives exponential lockout.
-- name: CountRecentFailuresByEmail :one
SELECT count(*) FROM login_attempts la
WHERE la.email = $1
  AND la.success = false
  AND la.created_at > now() - make_interval(secs => sqlc.arg(window_secs)::double precision)
  AND la.created_at > COALESCE(
        (SELECT max(ok.created_at) FROM login_attempts ok
         WHERE ok.email = $1 AND ok.success = true), 'epoch'::timestamptz);

-- name: CountRecentFailuresByIP :one
SELECT count(*) FROM login_attempts
WHERE ip = $1
  AND success = false
  AND created_at > now() - make_interval(secs => sqlc.arg(window_secs)::double precision);

-- --- retention / maintenance ---

-- name: EnsurePingPartitions :exec
SELECT aul_ensure_ping_partitions($1, $2);

-- NOTE: listing/dropping ping partitions queries pg_catalog (pg_inherits),
-- which sqlc's analyzer does not model; that runs as raw pgx in the retention
-- package (see internal/retention).

-- name: PruneLoginAttempts :execrows
DELETE FROM login_attempts WHERE created_at < now() - make_interval(days => sqlc.arg(keep_days)::int);

-- name: PruneAuditIPs :execrows
UPDATE audit_log SET ip = NULL
WHERE ip IS NOT NULL AND ts < now() - make_interval(days => sqlc.arg(keep_days)::int);

-- Delete every ping older than the global ping window EXCEPT the newest one per
-- (circle_id, device_id), which is kept no matter how old it is.
--
-- Why: since D-0054 removed history and the movement/digest stats, the only
-- reader left is "latest ping per device" (LatestPingsForCircle) plus the
-- realtime fan-out, which publishes on insert and never reads back. Stored
-- history is therefore unreadable-but-present ciphertext whose timing and
-- frequency still leak to whoever steals the database (THREAT_MODEL §4). The
-- short window is what dedup (uq_pings_dedup) and in-flight reads need; the
-- per-device carve-out is what the map needs — drop it and a phone that has
-- been off for three days silently blanks off everyone's map.
--
-- "Not the newest" is expressed as "a newer ping exists for the same circle and
-- device", which idx_pings_circle_device_time (circle_id, device_id,
-- captured_at DESC) serves directly, and the outer captured_at bound lets the
-- planner prune whole monthly partitions. Ties at a device's max captured_at
-- (possible: dedup is keyed by client_id too) all survive, so whichever row
-- LatestPingsForCircle's DISTINCT ON picks is guaranteed to still be there.
-- name: PruneStalePings :execrows
DELETE FROM pings p
WHERE p.captured_at < now() - make_interval(hours => sqlc.arg(keep_hours)::int)
  AND EXISTS (
      SELECT 1 FROM pings newer
      WHERE newer.circle_id = p.circle_id
        AND newer.device_id = p.device_id
        AND newer.captured_at > p.captured_at
  );

-- Delete pings older than each circle's retention window that still linger in
-- live partitions (belt-and-suspenders alongside partition drops).
--
-- PruneStalePings above supersedes this for pings in the default config, but a
-- circle whose retention_days is shorter than PING_RETENTION_HOURS still wants
-- its pings gone sooner — whichever rule deletes more, deletes. The same
-- newest-per-device carve-out applies: an absolute rule, not a per-window one.
-- name: DeleteExpiredPingsForCircle :execrows
DELETE FROM pings p
WHERE p.circle_id = $1
  AND p.captured_at < now() - make_interval(days => sqlc.arg(retention_days)::int)
  AND EXISTS (
      SELECT 1 FROM pings newer
      WHERE newer.circle_id = p.circle_id
        AND newer.device_id = p.device_id
        AND newer.captured_at > p.captured_at
  );
