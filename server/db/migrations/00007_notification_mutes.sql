-- +goose Up

-- Per-member notification mutes. A row says "user_id does not want arrival /
-- geofence pushes in circle_id", either from ONE member (muted_user_id set) or
-- from the whole circle (muted_user_id IS NULL).
--
-- This is enforced at the SENDER's fan-out (see ListCirclePushSubscriptions),
-- not on the muted member's device: a muted recipient is never handed to the
-- push service at all, so the notification does not exist rather than arriving
-- and being hidden. Nothing here is derived from ciphertext — a mute is pure
-- routing metadata (who, in which circle, about whom), never place or position.
--
-- NULLS NOT DISTINCT (PG15+) makes the whole-circle row unique too: without it
-- every NULL muted_user_id would be distinct and "mute this circle" could pile
-- up duplicate rows.
CREATE TABLE notification_mutes (
    user_id       uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    circle_id     uuid NOT NULL REFERENCES circles(id) ON DELETE CASCADE,
    -- CASCADE, deliberately not SET NULL: NULL is meaningful here ("mute the
    -- whole circle"), so SET NULL would silently widen "mute Bob" into "mute
    -- everyone" the day Bob deletes his account. Dropping the row is correct —
    -- there is no one left to mute.
    muted_user_id uuid REFERENCES users(id) ON DELETE CASCADE,
    created_at    timestamptz NOT NULL DEFAULT now(),
    UNIQUE NULLS NOT DISTINCT (user_id, circle_id, muted_user_id)
);

-- The UNIQUE constraint above already indexes (user_id, circle_id,
-- muted_user_id) — exactly the fan-out probe
-- `m.user_id = ps.user_id AND m.circle_id = $1 AND (m.muted_user_id IS NULL OR
-- m.muted_user_id = <sender>)` — and its (user_id, circle_id) prefix serves the
-- GET /mutes read. These two extra indexes exist for the FK cascades instead:
-- deleting a user or a circle would otherwise seq-scan this table.
CREATE INDEX idx_notification_mutes_circle ON notification_mutes(circle_id);
CREATE INDEX idx_notification_mutes_muted_user ON notification_mutes(muted_user_id);

-- Places gain an author distinct from `updated_by` (the LAST editor), so clients
-- can show "«Home» · <owner nick>". Set once on INSERT and never touched again.
-- Still no plaintext server-side: the place's name lives inside `ciphertext`,
-- sealed under K_c; this is only a user id, the same metadata `updated_by`
-- already carried. ON DELETE SET NULL matches updated_by: a departed author
-- leaves the place readable by everyone else rather than deleting it.
ALTER TABLE places_enc ADD COLUMN created_by uuid REFERENCES users(id) ON DELETE SET NULL;

-- Backfill: for rows predating this column the last editor is the best available
-- estimate of the author (and is exactly right for never-edited places).
UPDATE places_enc SET created_by = updated_by;

CREATE INDEX idx_places_created_by ON places_enc(created_by);

-- +goose Down
DROP INDEX IF EXISTS idx_places_created_by;
ALTER TABLE places_enc DROP COLUMN IF EXISTS created_by;
DROP TABLE IF EXISTS notification_mutes;
