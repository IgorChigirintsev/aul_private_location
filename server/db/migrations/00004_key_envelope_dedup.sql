-- +goose Up
-- A recipient device needs exactly one sealed circle-key per (circle, epoch).
-- Enforcing uniqueness lets CreateKeyEnvelope upsert instead of inserting
-- unbounded duplicates (DoS / storage-exhaustion hardening; see D-0017). Any
-- pre-existing duplicates are collapsed to the newest row first.
DELETE FROM key_envelopes a
USING key_envelopes b
WHERE a.circle_id = b.circle_id
  AND a.recipient_device_id = b.recipient_device_id
  AND a.key_epoch = b.key_epoch
  AND a.created_at < b.created_at;

CREATE UNIQUE INDEX uq_key_envelopes_recipient_epoch
    ON key_envelopes (circle_id, recipient_device_id, key_epoch);

-- +goose Down
DROP INDEX IF EXISTS uq_key_envelopes_recipient_epoch;
