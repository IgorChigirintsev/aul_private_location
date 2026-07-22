-- name: CreateCircle :one
INSERT INTO circles (name_enc, retention_days, created_by)
VALUES ($1, $2, $3)
RETURNING *;

-- name: GetCircle :one
SELECT * FROM circles WHERE id = $1;

-- name: UpdateCircleName :one
UPDATE circles SET name_enc = $2 WHERE id = $1 RETURNING *;

-- name: UpdateCircleRetention :one
UPDATE circles SET retention_days = $2 WHERE id = $1 RETURNING *;

-- name: BumpCircleKeyEpoch :one
UPDATE circles SET key_epoch = key_epoch + 1 WHERE id = $1 RETURNING *;

-- name: DeleteCircle :exec
DELETE FROM circles WHERE id = $1;

-- name: ListCirclesForUser :many
SELECT c.*, cm.role, cm.precision_mode
FROM circles c
JOIN circle_members cm ON cm.circle_id = c.id
WHERE cm.user_id = $1
ORDER BY c.created_at;

-- name: AllCircleRetention :many
SELECT id, retention_days FROM circles;

-- --- membership ---

-- name: AddMember :one
INSERT INTO circle_members (circle_id, user_id, role, precision_mode)
VALUES ($1, $2, $3, 'precise')
ON CONFLICT (circle_id, user_id) DO UPDATE SET role = EXCLUDED.role
RETURNING *;

-- name: GetMembership :one
SELECT * FROM circle_members WHERE circle_id = $1 AND user_id = $2;

-- name: ListMembers :many
SELECT cm.*, u.email
FROM circle_members cm
JOIN users u ON u.id = cm.user_id
WHERE cm.circle_id = $1
ORDER BY cm.joined_at;

-- name: RemoveMember :exec
DELETE FROM circle_members WHERE circle_id = $1 AND user_id = $2;

-- name: SetPrecisionMode :one
UPDATE circle_members SET precision_mode = $3
WHERE circle_id = $1 AND user_id = $2
RETURNING *;

-- name: SetMemberRole :one
UPDATE circle_members SET role = $3
WHERE circle_id = $1 AND user_id = $2
RETURNING *;

-- name: SetMemberProfile :exec
UPDATE circle_members SET profile_enc = $3 WHERE circle_id = $1 AND user_id = $2;

-- name: CountOwners :one
SELECT count(*) FROM circle_members WHERE circle_id = $1 AND role = 'owner';
