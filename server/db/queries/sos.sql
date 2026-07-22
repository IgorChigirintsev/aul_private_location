-- name: CreateSOS :one
INSERT INTO sos_events (circle_id, device_id, ciphertext)
VALUES ($1, $2, $3)
RETURNING *;

-- name: ResolveSOS :one
UPDATE sos_events
SET resolved_at = now(), resolved_by = $3
WHERE id = $1 AND circle_id = $2 AND resolved_at IS NULL
RETURNING *;

-- name: ListActiveSOS :many
SELECT * FROM sos_events
WHERE circle_id = $1 AND resolved_at IS NULL
ORDER BY created_at DESC;

-- name: GetSOS :one
SELECT * FROM sos_events WHERE id = $1;

-- Prune resolved SOS events past the retention horizon (unbounded-growth bound).
-- name: PruneResolvedSOS :execrows
DELETE FROM sos_events
WHERE resolved_at IS NOT NULL AND resolved_at < $1;
