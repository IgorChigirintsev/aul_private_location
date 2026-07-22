-- +goose Up
--
-- =====================================================================
-- Aul embedded-SQLite schema (Milestone 1 of the single-binary port).
--
-- This is a PARALLEL migration set to server/db/migrations/*.sql. The
-- Postgres set is the source of truth and stays byte-identical; the cloud
-- server runs on Postgres. This set materializes the SAME end-state schema
-- on a fresh SQLite database (modernc.org/sqlite, pure-Go, no cgo).
--
-- APPROACH: consolidated END-STATE, not a replay of the 8 historical
-- Postgres migrations. Because this is a brand-new parallel set applied to
-- a fresh database, there is no history to migrate and no rows to backfill,
-- so every ALTER TABLE / data-migration step from the Postgres 00004-00008
-- migrations is folded directly into the table it targets:
--   * 00004 key-envelope dedup DELETE ... USING  -> nothing to dedup on a
--     fresh DB; only the resulting UNIQUE index is created below. (Its
--     SQLite-legal equivalent would be a correlated-subquery DELETE, but a
--     fresh table has zero duplicate rows, so it is a no-op and omitted.)
--   * 00005 ALTER circle_members ADD profile_enc -> column in the table.
--   * 00007 ALTER places_enc ADD created_by + backfill -> column in table
--     (no backfill needed); notification_mutes created in end-state.
--   * 00008 ALTER push_subscriptions ADD kind, DROP NOT NULL on p256dh/auth,
--     ADD CONSTRAINT kind_shape -> all folded into the table definition,
--     which sidesteps SQLite's inability to ALTER nullability or ADD
--     CONSTRAINT (no 12-step table rebuild required for a fresh schema).
--
-- TYPE REPRESENTATION (documented once, applied consistently):
--   * uuid        -> TEXT. UUIDs are supplied by Go at INSERT time
--                   (Milestone 2); columns have NO default. Store the
--                   canonical lower-case hyphenated form, which round-trips
--                   through google/uuid.UUID.String()/uuid.Parse().
--   * timestamptz -> TEXT holding an ISO-8601 UTC instant with millisecond
--                   precision and a literal 'Z', e.g. 2026-07-20T12:34:56.789Z.
--                   DEFAULT now() -> DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
--                   which SQLite evaluates in UTC. This parses cleanly with
--                   Go's time.RFC3339/RFC3339Nano and, formatted back with
--                   t.UTC().Format(time.RFC3339Nano), round-trips time.Time.
--   * bytea       -> BLOB. Go []byte maps directly.
--   * jsonb       -> TEXT. No JSON operators are used in any query; this is a
--                   pure storage-type mapping (audit_log.detail).
--   * boolean     -> INTEGER (0/1).
--   * citext      -> TEXT COLLATE NOCASE (see users.email / login_attempts.email).
--   * bigint GENERATED ALWAYS AS IDENTITY -> INTEGER PRIMARY KEY AUTOINCREMENT.
--
-- FOREIGN KEYS: every ON DELETE CASCADE / RESTRICT / SET NULL from the
-- Postgres schema is preserved verbatim. SQLite enforces FKs ONLY when
-- `PRAGMA foreign_keys = ON`, which is per-connection and off by default; the
-- open helper (internal/store/sqlitedb) sets it on every pooled connection.
-- Without it the mute/key-envelope cascade cleanup silently dies.
-- =====================================================================

-- ---- users (Postgres 00002) -----------------------------------------
-- Email is case-insensitive: citext -> TEXT COLLATE NOCASE on the column
-- (so `email = ?` lookups match case-insensitively, as citext did) plus a
-- COLLATE NOCASE UNIQUE index (so 'A@x' and 'a@x' collide).
CREATE TABLE users (
    id         TEXT PRIMARY KEY,
    email      TEXT NOT NULL COLLATE NOCASE,
    pass_hash  TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE UNIQUE INDEX uq_users_email ON users (email COLLATE NOCASE);

-- ---- devices (Postgres 00002) ---------------------------------------
CREATE TABLE devices (
    id           TEXT PRIMARY KEY,
    user_id      TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    platform     TEXT NOT NULL CHECK (platform IN ('android', 'ios', 'web', 'web-mobile')),
    display_name TEXT,
    pubkey       BLOB,  -- 32-byte X25519 identity public key; validated in app code
    push_token   TEXT,
    created_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    last_seen    TEXT
);
CREATE INDEX idx_devices_user ON devices(user_id);

-- ---- sessions (Postgres 00002) --------------------------------------
CREATE TABLE sessions (
    id                  TEXT PRIMARY KEY,
    user_id             TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    device_id           TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    access_token_hash   TEXT NOT NULL UNIQUE,
    refresh_token_hash  TEXT NOT NULL UNIQUE,
    prev_refresh_hash   TEXT,
    access_expires_at   TEXT NOT NULL,
    refresh_expires_at  TEXT NOT NULL,
    revoked_at          TEXT,
    created_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    rotated_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE INDEX idx_sessions_device ON sessions(device_id);
CREATE INDEX idx_sessions_refresh_expiry ON sessions(refresh_expires_at);

-- ---- circles (Postgres 00002) ---------------------------------------
CREATE TABLE circles (
    id             TEXT PRIMARY KEY,
    name_enc       BLOB,
    retention_days INTEGER NOT NULL DEFAULT 7 CHECK (retention_days BETWEEN 1 AND 3650),
    key_epoch      INTEGER NOT NULL DEFAULT 1,  -- bumps on circle-key rotation
    created_by     TEXT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    created_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

-- ---- circle_members (Postgres 00002 + profile_enc from 00005) -------
CREATE TABLE circle_members (
    circle_id      TEXT NOT NULL REFERENCES circles(id) ON DELETE CASCADE,
    user_id        TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    role           TEXT NOT NULL DEFAULT 'member' CHECK (role IN ('owner', 'member', 'guardian')),
    precision_mode TEXT NOT NULL DEFAULT 'precise' CHECK (precision_mode IN ('precise', 'city', 'paused')),
    joined_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    profile_enc    BLOB,  -- 00005: per-circle nickname+avatar sealed under K_c
    PRIMARY KEY (circle_id, user_id)
);
CREATE INDEX idx_circle_members_user ON circle_members(user_id);

-- ---- invites (Postgres 00002) ---------------------------------------
CREATE TABLE invites (
    id         TEXT PRIMARY KEY,
    circle_id  TEXT NOT NULL REFERENCES circles(id) ON DELETE CASCADE,
    created_by TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    role       TEXT NOT NULL DEFAULT 'member' CHECK (role IN ('member', 'guardian')),
    max_uses   INTEGER NOT NULL DEFAULT 1 CHECK (max_uses BETWEEN 1 AND 1000),
    uses       INTEGER NOT NULL DEFAULT 0,
    expires_at TEXT NOT NULL,
    status     TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'revoked')),
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE INDEX idx_invites_circle ON invites(circle_id);

-- ---- places_enc (Postgres 00002 + created_by from 00007) ------------
CREATE TABLE places_enc (
    id         TEXT PRIMARY KEY,
    circle_id  TEXT NOT NULL REFERENCES circles(id) ON DELETE CASCADE,
    ciphertext BLOB NOT NULL,
    version    INTEGER NOT NULL DEFAULT 1,
    deleted    INTEGER NOT NULL DEFAULT 0,  -- boolean
    updated_by TEXT REFERENCES users(id) ON DELETE SET NULL,
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    created_by TEXT REFERENCES users(id) ON DELETE SET NULL  -- 00007: place author
);
CREATE INDEX idx_places_circle ON places_enc(circle_id);
CREATE INDEX idx_places_created_by ON places_enc(created_by);

-- ---- key_envelopes (Postgres 00002 + unique index from 00004) -------
CREATE TABLE key_envelopes (
    id                  TEXT PRIMARY KEY,
    circle_id           TEXT NOT NULL REFERENCES circles(id) ON DELETE CASCADE,
    recipient_device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    sender_device_id    TEXT REFERENCES devices(id) ON DELETE SET NULL,
    ciphertext          BLOB NOT NULL,
    key_epoch           INTEGER NOT NULL DEFAULT 1,
    created_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    consumed_at         TEXT
);
CREATE INDEX idx_key_envelopes_pending ON key_envelopes(recipient_device_id) WHERE consumed_at IS NULL;
-- 00004: exactly one sealed circle-key per (circle, recipient, epoch), so
-- CreateKeyEnvelope can upsert. No pre-existing duplicates on a fresh DB.
CREATE UNIQUE INDEX uq_key_envelopes_recipient_epoch
    ON key_envelopes (circle_id, recipient_device_id, key_epoch);

-- ---- sos_events (Postgres 00002) ------------------------------------
CREATE TABLE sos_events (
    id          TEXT PRIMARY KEY,
    circle_id   TEXT NOT NULL REFERENCES circles(id) ON DELETE CASCADE,
    device_id   TEXT REFERENCES devices(id) ON DELETE SET NULL,
    ciphertext  BLOB NOT NULL,
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    resolved_at TEXT,
    resolved_by TEXT REFERENCES users(id) ON DELETE SET NULL
);
CREATE INDEX idx_sos_circle_active ON sos_events(circle_id) WHERE resolved_at IS NULL;

-- ---- push_subscriptions (Postgres 00002 + kind/shape from 00008) ----
-- Web Push needs both keys; FCM has neither. Per-kind shape enforced by the
-- CHECK (folded in from 00008), so p256dh/auth are nullable but a webpush row
-- still cannot lose its key material.
CREATE TABLE push_subscriptions (
    id         TEXT PRIMARY KEY,
    user_id    TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    device_id  TEXT REFERENCES devices(id) ON DELETE CASCADE,
    endpoint   TEXT NOT NULL UNIQUE,
    p256dh     TEXT,
    auth       TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    kind       TEXT NOT NULL DEFAULT 'webpush' CHECK (kind IN ('webpush', 'fcm')),
    CONSTRAINT push_subscriptions_kind_shape CHECK (
        (kind = 'webpush' AND p256dh IS NOT NULL AND auth IS NOT NULL)
        OR
        (kind = 'fcm' AND p256dh IS NULL AND auth IS NULL)
    )
);
CREATE INDEX idx_push_user ON push_subscriptions(user_id);

-- ---- app_versions (Postgres 00002) ----------------------------------
CREATE TABLE app_versions (
    id            TEXT PRIMARY KEY,
    platform      TEXT NOT NULL CHECK (platform IN ('android', 'ios')),
    version_code  INTEGER NOT NULL,
    version_name  TEXT NOT NULL,
    apk_url       TEXT,
    sha256        TEXT,
    changelog     TEXT,
    min_supported INTEGER NOT NULL DEFAULT 0,
    is_active     INTEGER NOT NULL DEFAULT 1,  -- boolean
    created_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    UNIQUE (platform, version_code)
);

-- ---- audit_log (Postgres 00002) -------------------------------------
-- bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY -> INTEGER PRIMARY KEY
-- AUTOINCREMENT (monotonic rowid). detail jsonb -> TEXT.
CREATE TABLE audit_log (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    ts              TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    event           TEXT NOT NULL,
    actor_user_id   TEXT,
    actor_device_id TEXT,
    circle_id       TEXT,
    ip              TEXT,
    detail          TEXT  -- jsonb; no JSON operators used, pure storage
);
CREATE INDEX idx_audit_ts ON audit_log(ts);
CREATE INDEX idx_audit_actor ON audit_log(actor_user_id, ts);

-- ---- login_attempts (Postgres 00002) --------------------------------
-- email citext -> TEXT COLLATE NOCASE (the lookup index inherits NOCASE, so
-- lockout probes match case-insensitively). Not UNIQUE. success boolean.
CREATE TABLE login_attempts (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    email      TEXT COLLATE NOCASE,
    ip         TEXT,
    success    INTEGER NOT NULL,  -- boolean
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE INDEX idx_login_attempts_email ON login_attempts(email, created_at);
CREATE INDEX idx_login_attempts_ip ON login_attempts(ip, created_at);

-- ---- pings (Postgres 00003; DE-PARTITIONED) -------------------------
-- SQLite has no table partitioning. The Postgres table was RANGE-partitioned
-- monthly on captured_at, which forced the composite PK (id, captured_at).
-- Here `pings` is a PLAIN table with `id` as the SOLE primary key; the
-- PL/pgSQL partition functions (aul_ensure_ping_partition[s]) are deleted
-- entirely (nothing to create). Retention becomes DELETE-by-timestamp; the
-- row-level prune queries were already plain DELETEs, so they survive.
CREATE TABLE pings (
    id          TEXT PRIMARY KEY,
    circle_id   TEXT NOT NULL REFERENCES circles(id) ON DELETE CASCADE,
    device_id   TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    client_id   TEXT NOT NULL,
    nonce       BLOB NOT NULL,
    ciphertext  BLOB NOT NULL,
    captured_at TEXT NOT NULL,
    received_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    expires_at  TEXT
);
-- Idempotency: a retried batch carries the same (device_id, client_id,
-- captured_at) and is dropped by ON CONFLICT DO NOTHING.
CREATE UNIQUE INDEX uq_pings_dedup ON pings (device_id, client_id, captured_at);
-- "Latest ping per device in a circle" and "device history over a range".
CREATE INDEX idx_pings_circle_device_time ON pings (circle_id, device_id, captured_at DESC);

-- ---- share_sessions / share_positions (Postgres 00006) --------------
CREATE TABLE share_sessions (
    id                TEXT PRIMARY KEY,
    user_id           TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at        TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    expires_at        TEXT NOT NULL,
    revoked_at        TEXT,
    viewer_token_hash BLOB,
    viewer_bound_at   TEXT
);
CREATE INDEX idx_share_sessions_user ON share_sessions(user_id);
CREATE INDEX idx_share_sessions_expiry ON share_sessions(expires_at);

CREATE TABLE share_positions (
    session_id  TEXT PRIMARY KEY REFERENCES share_sessions(id) ON DELETE CASCADE,
    nonce       BLOB NOT NULL,
    ciphertext  BLOB NOT NULL,
    captured_at TEXT NOT NULL,
    updated_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

-- ---- notification_mutes (Postgres 00007) ----------------------------
-- muted_user_id set = mute ONE member; muted_user_id NULL = mute the WHOLE
-- circle. FK cascades are load-bearing: muted_user_id is CASCADE (NOT SET
-- NULL) so a deleted target drops the row rather than silently widening
-- "mute Bob" into "mute everyone".
CREATE TABLE notification_mutes (
    user_id       TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    circle_id     TEXT NOT NULL REFERENCES circles(id) ON DELETE CASCADE,
    muted_user_id TEXT REFERENCES users(id) ON DELETE CASCADE,
    created_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
-- Postgres used `UNIQUE NULLS NOT DISTINCT (user_id, circle_id, muted_user_id)`
-- so that the whole-circle row (muted_user_id IS NULL) is unique too and
-- `InsertMute ... ON CONFLICT DO NOTHING` dedups it. SQLite treats NULLs as
-- DISTINCT in a UNIQUE index, so that single constraint would let whole-circle
-- mutes pile up. Split it into TWO PARTIAL UNIQUE INDEXES that together
-- reproduce NULLS NOT DISTINCT exactly:
--   (a) member mutes: unique on the full triple, only where a member is named.
CREATE UNIQUE INDEX uq_notification_mutes_member
    ON notification_mutes (user_id, circle_id, muted_user_id)
    WHERE muted_user_id IS NOT NULL;
--   (b) whole-circle mutes: unique on (user_id, circle_id) alone, only where
--       muted_user_id IS NULL -- at most one whole-circle row per (user,circle).
CREATE UNIQUE INDEX uq_notification_mutes_circle
    ON notification_mutes (user_id, circle_id)
    WHERE muted_user_id IS NULL;
-- InsertMute's bare `ON CONFLICT DO NOTHING` (no target) fires on whichever of
-- these two indexes the row violates, preserving the idempotent-mute contract.
-- These two extra indexes serve the FK cascades (a bare user/circle delete
-- would otherwise seq-scan this table), matching the Postgres schema.
CREATE INDEX idx_notification_mutes_circle ON notification_mutes(circle_id);
CREATE INDEX idx_notification_mutes_muted_user ON notification_mutes(muted_user_id);

-- +goose Down
DROP TABLE IF EXISTS notification_mutes;
DROP TABLE IF EXISTS share_positions;
DROP TABLE IF EXISTS share_sessions;
DROP TABLE IF EXISTS pings;
DROP TABLE IF EXISTS login_attempts;
DROP TABLE IF EXISTS audit_log;
DROP TABLE IF EXISTS app_versions;
DROP TABLE IF EXISTS push_subscriptions;
DROP TABLE IF EXISTS sos_events;
DROP TABLE IF EXISTS key_envelopes;
DROP TABLE IF EXISTS places_enc;
DROP TABLE IF EXISTS invites;
DROP TABLE IF EXISTS circle_members;
DROP TABLE IF EXISTS circles;
DROP TABLE IF EXISTS sessions;
DROP TABLE IF EXISTS devices;
DROP TABLE IF EXISTS users;
