-- name: CreateSession :one
INSERT INTO sessions (
    user_id, device_id, access_token_hash, refresh_token_hash,
    access_expires_at, refresh_expires_at
) VALUES ($1, $2, $3, $4, $5, $6)
RETURNING *;

-- Resolve an access token to a live session (not revoked, not expired).
-- name: GetSessionByAccessHash :one
SELECT * FROM sessions
WHERE access_token_hash = $1
  AND revoked_at IS NULL
  AND access_expires_at > now();

-- Look up a session by the current refresh hash (valid refresh).
-- name: GetSessionByRefreshHash :one
SELECT * FROM sessions
WHERE refresh_token_hash = $1
  AND revoked_at IS NULL
  AND refresh_expires_at > now();

-- Look up a session where the presented refresh matches the PREVIOUS hash:
-- a replay of an already-rotated token → theft signal.
-- name: GetSessionByPrevRefreshHash :one
SELECT * FROM sessions
WHERE prev_refresh_hash = $1
  AND revoked_at IS NULL;

-- Rotate: issue new access+refresh, keep the presented refresh as prev. This is
-- a compare-and-swap on the presented refresh hash so that two concurrent
-- refreshes of the same token cannot both succeed: only the request whose
-- old_refresh_hash still matches the current one rotates; the loser matches 0
-- rows and the caller treats it as reuse (see auth.Refresh).
-- name: RotateSession :one
UPDATE sessions SET
    access_token_hash  = $2,
    refresh_token_hash = $3,
    prev_refresh_hash  = sqlc.arg(old_refresh_hash),
    access_expires_at  = $4,
    refresh_expires_at = $5,
    rotated_at = now()
WHERE id = $1
  AND refresh_token_hash = sqlc.arg(old_refresh_hash)
  AND revoked_at IS NULL
RETURNING *;

-- name: RevokeSession :exec
UPDATE sessions SET revoked_at = now() WHERE id = $1 AND revoked_at IS NULL;

-- name: RevokeSessionsForDevice :exec
UPDATE sessions SET revoked_at = now()
WHERE device_id = $1 AND revoked_at IS NULL;

-- name: RevokeSessionsForUser :exec
UPDATE sessions SET revoked_at = now()
WHERE user_id = $1 AND revoked_at IS NULL;

-- name: ListActiveSessionsForUser :many
SELECT s.*, d.platform, d.display_name
FROM sessions s
JOIN devices d ON d.id = s.device_id
WHERE s.user_id = $1 AND s.revoked_at IS NULL AND s.refresh_expires_at > now()
ORDER BY s.rotated_at DESC;

-- name: DeleteExpiredSessions :execrows
DELETE FROM sessions
WHERE refresh_expires_at < now() - interval '1 day'
   OR (revoked_at IS NOT NULL AND revoked_at < now() - interval '1 day');
