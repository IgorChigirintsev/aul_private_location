-- name: CreateShareSession :one
INSERT INTO share_sessions (user_id, expires_at)
VALUES ($1, $2)
RETURNING *;

-- The caller's own live-or-revoked links that have not yet expired. Expired ones
-- are gone from the UI's point of view (and the retention job removes them).
-- name: ListShareSessionsForUser :many
SELECT * FROM share_sessions
WHERE user_id = $1 AND expires_at > now()
ORDER BY created_at DESC;

-- Public lookup by id alone: the viewer is unregistered and holds only the link.
-- name: GetShareSession :one
SELECT * FROM share_sessions WHERE id = $1;

-- Ownership-scoped lookup; no row means unknown-or-not-yours (both → 404, so a
-- stranger cannot probe for the existence of someone else's link).
-- name: GetShareSessionForOwner :one
SELECT * FROM share_sessions WHERE id = $1 AND user_id = $2;

-- Idempotent revoke: COALESCE keeps the first revocation's timestamp, so calling
-- it twice still returns the row (200) rather than looking like a missing link.
-- name: RevokeShareSession :one
UPDATE share_sessions
SET revoked_at = COALESCE(revoked_at, now())
WHERE id = $1 AND user_id = $2
RETURNING *;

-- One-device binding, compare-and-swap: only the request that finds
-- viewer_token_hash still NULL binds the link and gets the row back. A racing
-- second viewer matches no row and is refused, so a link can never be bound
-- twice.
-- name: BindShareViewer :one
UPDATE share_sessions
SET viewer_token_hash = $2, viewer_bound_at = now()
WHERE id = $1 AND viewer_token_hash IS NULL
RETURNING *;

-- Latest sealed position only: the new fix replaces the old one in place.
-- name: UpsertSharePosition :exec
INSERT INTO share_positions (session_id, nonce, ciphertext, captured_at)
VALUES ($1, $2, $3, $4)
ON CONFLICT (session_id) DO UPDATE SET
    nonce = EXCLUDED.nonce,
    ciphertext = EXCLUDED.ciphertext,
    captured_at = EXCLUDED.captured_at,
    updated_at = now();

-- name: GetSharePosition :one
SELECT * FROM share_positions WHERE session_id = $1;

-- Drop dead share sessions (and, by cascade, their position) once the grace
-- period has passed, so the table cannot grow without bound.
-- name: PruneShareSessions :execrows
DELETE FROM share_sessions
WHERE expires_at < now() - make_interval(hours => sqlc.arg(grace_hours)::int)
   OR (revoked_at IS NOT NULL
       AND revoked_at < now() - make_interval(hours => sqlc.arg(grace_hours)::int));
