-- The caller's own mutes in one circle. A NULL muted_user_id row means the
-- whole circle is muted; every other row names one muted member.
-- name: ListMutes :many
SELECT muted_user_id FROM notification_mutes
WHERE user_id = $1 AND circle_id = $2
ORDER BY created_at;

-- name: DeleteMutes :exec
DELETE FROM notification_mutes WHERE user_id = $1 AND circle_id = $2;

-- Idempotent: the UNIQUE (user_id, circle_id, muted_user_id) NULLS NOT DISTINCT
-- constraint makes re-muting the same target — or the circle — a no-op.
-- name: InsertMute :exec
INSERT INTO notification_mutes (user_id, circle_id, muted_user_id)
VALUES ($1, $2, $3)
ON CONFLICT DO NOTHING;

-- How many of the given user ids actually belong to the circle. Lets PUT /mutes
-- validate a whole mute set in one round trip (count < len → someone is not a
-- member) without leaking WHICH id was rejected.
-- name: CountMembersIn :one
SELECT count(*) FROM circle_members
WHERE circle_id = $1 AND user_id = ANY(sqlc.arg(user_ids)::uuid[]);
