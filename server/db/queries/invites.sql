-- name: CreateInvite :one
INSERT INTO invites (circle_id, created_by, role, max_uses, expires_at)
VALUES ($1, $2, $3, $4, $5)
RETURNING *;

-- name: GetInvite :one
SELECT * FROM invites WHERE id = $1;

-- Atomically consume one use of an active, unexpired invite. Returns the row
-- only if a use was available (uses < max_uses); NULL otherwise.
-- name: ConsumeInvite :one
UPDATE invites
SET uses = uses + 1
WHERE id = $1
  AND status = 'active'
  AND expires_at > now()
  AND uses < max_uses
RETURNING *;

-- name: RevokeInvite :exec
UPDATE invites SET status = 'revoked' WHERE id = $1 AND circle_id = $2;

-- name: ListInvitesForCircle :many
SELECT * FROM invites
WHERE circle_id = $1 AND status = 'active' AND expires_at > now()
ORDER BY created_at DESC;

-- name: CountRecentInvitesByUser :one
SELECT count(*) FROM invites
WHERE created_by = $1 AND created_at > now() - interval '1 hour';
