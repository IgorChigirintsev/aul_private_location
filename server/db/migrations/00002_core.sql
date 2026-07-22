-- +goose Up

-- Accounts. Email is case-insensitive (citext). Password is an Argon2id PHC hash.
CREATE TABLE users (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    email      citext NOT NULL UNIQUE,
    pass_hash  text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

-- Devices belong to a user. pubkey is the X25519 identity public key (set from
-- Phase 4 onward; nullable so Phase 1 trusted-mode clients can register first).
CREATE TABLE devices (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id      uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    platform     text NOT NULL CHECK (platform IN ('android', 'ios', 'web')),
    display_name text,
    pubkey       bytea,  -- 32-byte X25519 identity public key; validated in app code
    push_token   text,
    created_at   timestamptz NOT NULL DEFAULT now(),
    last_seen    timestamptz
);
CREATE INDEX idx_devices_user ON devices(user_id);

-- Opaque session tokens. Only HMAC-SHA256 hashes are stored (peppered), never
-- the tokens themselves. Refresh rotates on use; prev hash enables reuse
-- (theft) detection. Revocable by device (delete/mark the session).
CREATE TABLE sessions (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id             uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    device_id           uuid NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    access_token_hash   text NOT NULL UNIQUE,
    refresh_token_hash  text NOT NULL UNIQUE,
    prev_refresh_hash   text,
    access_expires_at   timestamptz NOT NULL,
    refresh_expires_at  timestamptz NOT NULL,
    revoked_at          timestamptz,
    created_at          timestamptz NOT NULL DEFAULT now(),
    rotated_at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_sessions_device ON sessions(device_id);
CREATE INDEX idx_sessions_refresh_expiry ON sessions(refresh_expires_at);

-- A family circle. name_enc is an E2EE ciphertext blob (nonce||ct); the server
-- never reads it. retention_days bounds ping history age.
CREATE TABLE circles (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name_enc       bytea,
    retention_days int NOT NULL DEFAULT 7 CHECK (retention_days BETWEEN 1 AND 3650),
    key_epoch      int NOT NULL DEFAULT 1,  -- bumps on circle-key rotation
    created_by     uuid NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    created_at     timestamptz NOT NULL DEFAULT now()
);

-- Membership: a user in a circle with a role and a self-chosen precision mode.
CREATE TABLE circle_members (
    circle_id      uuid NOT NULL REFERENCES circles(id) ON DELETE CASCADE,
    user_id        uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    role           text NOT NULL DEFAULT 'member' CHECK (role IN ('owner', 'member', 'guardian')),
    precision_mode text NOT NULL DEFAULT 'precise' CHECK (precision_mode IN ('precise', 'city', 'paused')),
    joined_at      timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (circle_id, user_id)
);
CREATE INDEX idx_circle_members_user ON circle_members(user_id);

-- Invites. The circle key travels in the URL fragment and NEVER reaches the
-- server; only the id and status live here.
CREATE TABLE invites (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    circle_id  uuid NOT NULL REFERENCES circles(id) ON DELETE CASCADE,
    created_by uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    role       text NOT NULL DEFAULT 'member' CHECK (role IN ('member', 'guardian')),
    max_uses   int NOT NULL DEFAULT 1 CHECK (max_uses BETWEEN 1 AND 1000),
    uses       int NOT NULL DEFAULT 0,
    expires_at timestamptz NOT NULL,
    status     text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'revoked')),
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_invites_circle ON invites(circle_id);

-- Encrypted places (one blob per place). Clients sync and compute geofences
-- locally; the server never reads coordinates.
CREATE TABLE places_enc (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    circle_id  uuid NOT NULL REFERENCES circles(id) ON DELETE CASCADE,
    ciphertext bytea NOT NULL,
    version    int NOT NULL DEFAULT 1,
    deleted    boolean NOT NULL DEFAULT false,
    updated_by uuid REFERENCES users(id) ON DELETE SET NULL,
    updated_at timestamptz NOT NULL DEFAULT now(),
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_places_circle ON places_enc(circle_id);

-- Sealed circle-key envelopes: crypto_box_seal(K_c) to a recipient device's
-- identity pubkey. The server relays boxes it cannot open (key rotation/join).
CREATE TABLE key_envelopes (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    circle_id           uuid NOT NULL REFERENCES circles(id) ON DELETE CASCADE,
    recipient_device_id uuid NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    sender_device_id    uuid REFERENCES devices(id) ON DELETE SET NULL,
    ciphertext          bytea NOT NULL,
    key_epoch           int NOT NULL DEFAULT 1,
    created_at          timestamptz NOT NULL DEFAULT now(),
    consumed_at         timestamptz
);
CREATE INDEX idx_key_envelopes_pending ON key_envelopes(recipient_device_id) WHERE consumed_at IS NULL;

-- SOS events. Payload (location etc.) is an encrypted blob.
CREATE TABLE sos_events (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    circle_id   uuid NOT NULL REFERENCES circles(id) ON DELETE CASCADE,
    device_id   uuid REFERENCES devices(id) ON DELETE SET NULL,
    ciphertext  bytea NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    resolved_at timestamptz,
    resolved_by uuid REFERENCES users(id) ON DELETE SET NULL
);
CREATE INDEX idx_sos_circle_active ON sos_events(circle_id) WHERE resolved_at IS NULL;

-- Web Push subscriptions (VAPID). Endpoint is unique.
CREATE TABLE push_subscriptions (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id    uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    device_id  uuid REFERENCES devices(id) ON DELETE CASCADE,
    endpoint   text NOT NULL UNIQUE,
    p256dh     text NOT NULL,
    auth       text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_push_user ON push_subscriptions(user_id);

-- App update manifest served by /v1/version/latest.
CREATE TABLE app_versions (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    platform      text NOT NULL CHECK (platform IN ('android', 'ios')),
    version_code  int NOT NULL,
    version_name  text NOT NULL,
    apk_url       text,
    sha256        text,
    changelog     text,
    min_supported int NOT NULL DEFAULT 0,
    is_active     boolean NOT NULL DEFAULT true,
    created_at    timestamptz NOT NULL DEFAULT now(),
    UNIQUE (platform, version_code)
);

-- Append-only security audit log. IP is nulled by the retention job after
-- IP_LOG_RETENTION_DAYS; the event itself is kept. Never stores coordinates.
CREATE TABLE audit_log (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ts              timestamptz NOT NULL DEFAULT now(),
    event           text NOT NULL,
    actor_user_id   uuid,
    actor_device_id uuid,
    circle_id       uuid,
    ip              text,
    detail          jsonb
);
CREATE INDEX idx_audit_ts ON audit_log(ts);
CREATE INDEX idx_audit_actor ON audit_log(actor_user_id, ts);

-- Login attempts feed the persistent exponential-lockout logic (survives
-- restarts). Pruned by the retention job.
CREATE TABLE login_attempts (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email      citext,
    ip         text,
    success    boolean NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_login_attempts_email ON login_attempts(email, created_at);
CREATE INDEX idx_login_attempts_ip ON login_attempts(ip, created_at);

-- +goose Down
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
