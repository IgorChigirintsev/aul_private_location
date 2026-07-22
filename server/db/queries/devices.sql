-- name: CreateDevice :one
INSERT INTO devices (user_id, platform, display_name, pubkey)
VALUES ($1, $2, $3, $4)
RETURNING *;

-- name: GetDevice :one
SELECT * FROM devices WHERE id = $1;

-- name: GetDeviceForUser :one
SELECT * FROM devices WHERE id = $1 AND user_id = $2;

-- name: ListDevicesForUser :many
SELECT * FROM devices WHERE user_id = $1 ORDER BY created_at;

-- name: SetDevicePubkey :exec
UPDATE devices SET pubkey = $2 WHERE id = $1;

-- name: SetDevicePushToken :exec
UPDATE devices SET push_token = $2 WHERE id = $1;

-- name: TouchDevice :exec
UPDATE devices SET last_seen = now() WHERE id = $1;

-- name: DeleteDevice :exec
DELETE FROM devices WHERE id = $1 AND user_id = $2;

-- List devices of all members of a circle (recipients for key envelopes).
-- name: ListCircleDevices :many
SELECT d.*
FROM devices d
JOIN circle_members cm ON cm.user_id = d.user_id
WHERE cm.circle_id = $1
ORDER BY d.created_at;
