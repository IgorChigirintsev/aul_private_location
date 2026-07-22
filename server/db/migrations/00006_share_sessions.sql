-- +goose Up

-- Live-share sessions: a time-boxed link that shows ONE outsider (unregistered,
-- no account) the sharer's live position. The position is sealed client-side
-- under a per-session key K_share that lives only in the link's URL fragment and
-- never reaches the server — deliberately NOT the circle key, so handing out a
-- share link exposes nothing but this one session's fixes.
--
-- viewer_token_hash binds the link to the first device that opens it: the server
-- mints an opaque token, hands it back in an HttpOnly cookie, and stores only
-- HMAC-SHA256(pepper, token) here (same construction as sessions.access_token_hash;
-- a database-only compromise cannot forge the cookie). NULL = not yet opened.
CREATE TABLE share_sessions (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id           uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at        timestamptz NOT NULL DEFAULT now(),
    expires_at        timestamptz NOT NULL,
    revoked_at        timestamptz,
    viewer_token_hash bytea,
    viewer_bound_at   timestamptz
);
CREATE INDEX idx_share_sessions_user ON share_sessions(user_id);
CREATE INDEX idx_share_sessions_expiry ON share_sessions(expires_at);

-- The single latest sealed position per share session — upserted in place, never
-- appended. A viewer follows a live dot; no track exists for them to replay, and
-- nothing accumulates for the retention job to leak.
CREATE TABLE share_positions (
    session_id  uuid PRIMARY KEY REFERENCES share_sessions(id) ON DELETE CASCADE,
    nonce       bytea NOT NULL,
    ciphertext  bytea NOT NULL,
    captured_at timestamptz NOT NULL,
    updated_at  timestamptz NOT NULL DEFAULT now()
);

-- +goose Down
DROP TABLE IF EXISTS share_positions;
DROP TABLE IF EXISTS share_sessions;
