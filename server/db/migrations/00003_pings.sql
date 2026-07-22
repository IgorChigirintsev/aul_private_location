-- +goose Up

-- Encrypted location pings, RANGE-partitioned monthly by captured_at (see
-- DECISIONS D-0012). The server stores ciphertext it cannot read. captured_at is
-- the client-declared, server-validated ping time; received_at is the server
-- clock (audit). Retention is an O(1) partition DROP, not a mass DELETE.
CREATE TABLE pings (
    id          uuid NOT NULL DEFAULT gen_random_uuid(),
    circle_id   uuid NOT NULL REFERENCES circles(id) ON DELETE CASCADE,
    device_id   uuid NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    client_id   text NOT NULL,
    nonce       bytea NOT NULL,
    ciphertext  bytea NOT NULL,
    captured_at timestamptz NOT NULL,
    received_at timestamptz NOT NULL DEFAULT now(),
    expires_at  timestamptz,
    PRIMARY KEY (id, captured_at)
) PARTITION BY RANGE (captured_at);

-- Idempotency: a retried batch carries the same (device_id, client_id,
-- captured_at) and is dropped by ON CONFLICT DO NOTHING. The partition key
-- (captured_at) is included as PostgreSQL requires.
CREATE UNIQUE INDEX uq_pings_dedup ON pings (device_id, client_id, captured_at);

-- "Latest ping per device in a circle" and "device history over a range".
CREATE INDEX idx_pings_circle_device_time ON pings (circle_id, device_id, captured_at DESC);

-- +goose StatementBegin
-- Create a single monthly partition if it does not already exist.
CREATE OR REPLACE FUNCTION aul_ensure_ping_partition(month_start date)
RETURNS void AS $$
DECLARE
    part_name text := format('pings_p%s', to_char(month_start, 'YYYY_MM'));
    range_end date := (month_start + interval '1 month')::date;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_class WHERE relname = part_name) THEN
        EXECUTE format(
            'CREATE TABLE %I PARTITION OF pings FOR VALUES FROM (%L) TO (%L)',
            part_name, month_start, range_end);
    END IF;
END;
$$ LANGUAGE plpgsql;
-- +goose StatementEnd

-- +goose StatementBegin
-- Ensure all monthly partitions covering [from_ts, to_ts] exist. Called at
-- startup and by the daily maintenance job.
CREATE OR REPLACE FUNCTION aul_ensure_ping_partitions(from_ts timestamptz, to_ts timestamptz)
RETURNS void AS $$
DECLARE
    m date := date_trunc('month', from_ts)::date;
    last_m date := date_trunc('month', to_ts)::date;
BEGIN
    WHILE m <= last_m LOOP
        PERFORM aul_ensure_ping_partition(m);
        m := (m + interval '1 month')::date;
    END LOOP;
END;
$$ LANGUAGE plpgsql;
-- +goose StatementEnd

-- Seed partitions for a window around deploy time so the first inserts land.
SELECT aul_ensure_ping_partitions(now() - interval '3 months', now() + interval '2 months');

-- +goose Down
DROP FUNCTION IF EXISTS aul_ensure_ping_partitions(timestamptz, timestamptz);
DROP FUNCTION IF EXISTS aul_ensure_ping_partition(date);
DROP TABLE IF EXISTS pings;
