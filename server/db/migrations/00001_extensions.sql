-- +goose Up
-- pgcrypto: gen_random_uuid(). citext: case-insensitive email uniqueness.
-- Both ship with the official `postgres` image (contrib), so the stack runs on
-- plain Postgres — no PostGIS. PostGIS was created here "for a future
-- trusted-server geofencing mode", but nothing uses it (no geometry column, no
-- ST_* call), it only builds for amd64 (blocking free ARM hosts), and adding a
-- third-party multi-arch image would be trust we don't need for a dead feature.
-- If trusted-server mode is ever built, it reintroduces PostGIS with its own
-- migration then. (D-0061)
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS citext;

-- +goose Down
DROP EXTENSION IF EXISTS citext;
DROP EXTENSION IF EXISTS pgcrypto;
