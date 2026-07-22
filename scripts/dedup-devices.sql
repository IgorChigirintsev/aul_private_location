-- One-time cleanup of duplicate device rows (see D-0067).
--
-- Before device registration was made idempotent, a web browser that
-- re-authenticated minted a NEW devices row for the same identity, so one
-- physical device accrued several rows — and the live map draws one marker per
-- device, so the same person showed up multiple times (the extra markers even
-- linger, because each device's newest ping is never pruned).
--
-- This keeps, per (user_id, pubkey), the MOST-RECENTLY-SEEN device and deletes
-- the rest. Deleting a device cascades its pings/envelopes/push rows away, so the
-- phantom markers disappear. Rows with a NULL pubkey have no identity to dedup on
-- and are left untouched.
--
-- SAFE to run repeatedly: once each (user_id, pubkey) is unique it is a no-op.
-- SAFE for existing clients: the pre-fix web client never persisted a device id,
-- so on its next sign-in it sends none and the server re-adopts the surviving row
-- by pubkey — no client is holding an id this could delete out from under it.
--
-- Dialect-agnostic (window function + CTE DELETE work on both engines).
--   Postgres (live cloud box):  docker compose exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" < scripts/dedup-devices.sql
--   SQLite  (self-host launcher, stop it first):  sqlite3 ~/.config/aul/aul.db < scripts/dedup-devices.sql

WITH ranked AS (
  SELECT id,
         ROW_NUMBER() OVER (
           PARTITION BY user_id, pubkey
           ORDER BY last_seen DESC NULLS LAST, id
         ) AS rn
  FROM devices
  WHERE pubkey IS NOT NULL
)
DELETE FROM devices
WHERE id IN (SELECT id FROM ranked WHERE rn > 1);
