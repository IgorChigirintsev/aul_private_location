-- name: ListPlaces :many
SELECT * FROM places_enc
WHERE circle_id = $1 AND deleted = false
ORDER BY created_at;

-- The author is both the creator and (so far) the last editor. created_by is set
-- ONLY here: no update path may rewrite it, so "«Home» · <owner nick>" keeps
-- naming who added the place, not whoever touched it last.
-- name: CreatePlace :one
INSERT INTO places_enc (circle_id, ciphertext, version, created_by, updated_by)
VALUES ($1, $2, 1, sqlc.arg(author_id), sqlc.arg(author_id))
RETURNING *;

-- Optimistic-concurrency update: only if the caller's version matches.
-- name: UpdatePlace :one
UPDATE places_enc
SET ciphertext = $3, version = version + 1, updated_by = $4, updated_at = now()
WHERE id = $1 AND circle_id = $2 AND version = $5 AND deleted = false
RETURNING *;

-- Soft-delete only a live place. The `deleted = false` guard makes re-deleting a
-- tombstone a no-op (returns no row → 404) instead of refreshing updated_at
-- (which would defeat tombstone retention) or inflating the version.
-- name: SoftDeletePlace :one
UPDATE places_enc
SET deleted = true, version = version + 1, updated_by = $3, updated_at = now()
WHERE id = $1 AND circle_id = $2 AND deleted = false
RETURNING *;

-- Hard-delete soft-deleted place tombstones once clients have had time to
-- converge the deletion (privacy + storage bound).
-- name: PrunePlaceTombstones :execrows
DELETE FROM places_enc
WHERE deleted = true AND updated_at < $1;
