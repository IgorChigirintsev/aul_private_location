-- +goose Up

-- Second push channel: FCM (Firebase Cloud Messaging) alongside Web Push.
--
-- push_subscriptions was Web-Push-shaped: an RFC 8291 endpoint URL plus the
-- subscription's own P-256 public key (p256dh) and auth secret. An FCM
-- registration token has neither — it is a single opaque string, and the
-- transport encryption to the device is Google's, not ours. So `kind` says how
-- to read the row:
--
--   webpush: endpoint = push service URL, p256dh + auth = the client's keys
--   fcm:     endpoint = the registration token, p256dh + auth NULL
--
-- The token lives in `endpoint` rather than a new column because it plays the
-- same role — the opaque per-device address the fan-out sends to — and that
-- keeps ONE unique key, one prune path (DeletePushSubscriptionByID), and one
-- unsubscribe query for both channels. A registration token is unique like an
-- endpoint URL, so the UNIQUE constraint still holds.
--
-- What does NOT change: the payload. Both channels carry the same opaque blob
-- the client sealed under the circle key K_c. FCM messages are data-only (never
-- `notification`), or Android would render the payload itself — which would
-- force plaintext through Google. See internal/fcm.
--
-- Backfill is implicit: every existing row is a Web Push subscription and the
-- DEFAULT gives it kind='webpush'. Existing rows keep their NOT NULL values;
-- only new fcm rows exercise the nullability.
ALTER TABLE push_subscriptions
    ADD COLUMN kind text NOT NULL DEFAULT 'webpush'
        CHECK (kind IN ('webpush', 'fcm'));

-- Web Push needs both keys; FCM has neither. The per-kind shape is enforced by
-- the CHECK below rather than by NOT NULL, so a webpush row still cannot lose
-- its key material.
ALTER TABLE push_subscriptions ALTER COLUMN p256dh DROP NOT NULL;
ALTER TABLE push_subscriptions ALTER COLUMN auth DROP NOT NULL;

-- A webpush row without keys is undeliverable and would panic-or-fail on every
-- send; an fcm row WITH keys is a client confusing the two channels. Reject
-- both at the database, not only in the handler.
ALTER TABLE push_subscriptions ADD CONSTRAINT push_subscriptions_kind_shape CHECK (
    (kind = 'webpush' AND p256dh IS NOT NULL AND auth IS NOT NULL)
    OR
    (kind = 'fcm' AND p256dh IS NULL AND auth IS NULL)
);

-- +goose Down
ALTER TABLE push_subscriptions DROP CONSTRAINT IF EXISTS push_subscriptions_kind_shape;
-- Down must restore NOT NULL, so the rows that legitimately hold NULLs (fcm)
-- cannot survive it: they have no representation in the old schema.
DELETE FROM push_subscriptions WHERE kind = 'fcm';
ALTER TABLE push_subscriptions ALTER COLUMN p256dh SET NOT NULL;
ALTER TABLE push_subscriptions ALTER COLUMN auth SET NOT NULL;
ALTER TABLE push_subscriptions DROP COLUMN IF EXISTS kind;
</content>
