-- Idempotent insert of one encrypted ping. Retries of the same
-- (device_id, client_id, captured_at) are dropped. Returns the row only when a
-- NEW ping was inserted, so the handler knows what to fan out over realtime.
-- name: InsertPing :one
INSERT INTO pings (
    circle_id, device_id, client_id, nonce, ciphertext, captured_at, expires_at
) VALUES ($1, $2, $3, $4, $5, $6, $7)
ON CONFLICT (device_id, client_id, captured_at) DO NOTHING
RETURNING *;

-- Latest ping per device in a circle (for the live map).
-- name: LatestPingsForCircle :many
SELECT DISTINCT ON (device_id) *
FROM pings
WHERE circle_id = $1
ORDER BY device_id, captured_at DESC;

-- name: CountPingsForCircle :one
SELECT count(*) FROM pings WHERE circle_id = $1;
