-- Upsert one sealed key per (circle, recipient device, epoch): re-sending the
-- rotated key replaces the prior envelope and re-arms it for fetching, so the
-- table cannot grow without bound from repeated sends.
-- name: CreateKeyEnvelope :one
INSERT INTO key_envelopes (
    circle_id, recipient_device_id, sender_device_id, ciphertext, key_epoch
) VALUES ($1, $2, $3, $4, $5)
ON CONFLICT (circle_id, recipient_device_id, key_epoch) DO UPDATE
SET ciphertext = EXCLUDED.ciphertext,
    sender_device_id = EXCLUDED.sender_device_id,
    created_at = now(),
    consumed_at = NULL
RETURNING *;

-- Pending (unconsumed) envelopes addressed to a device, bounded.
-- name: PendingEnvelopesForDevice :many
SELECT * FROM key_envelopes
WHERE recipient_device_id = $1 AND consumed_at IS NULL
ORDER BY created_at
LIMIT 500;

-- Prune consumed envelopes and stale unconsumed ones (privacy + storage bound).
-- name: PruneKeyEnvelopes :execrows
DELETE FROM key_envelopes
WHERE (consumed_at IS NOT NULL AND consumed_at < now() - interval '7 days')
   OR (consumed_at IS NULL AND created_at < now() - interval '30 days');

-- name: MarkEnvelopeConsumed :exec
UPDATE key_envelopes SET consumed_at = now()
WHERE id = $1 AND recipient_device_id = $2 AND consumed_at IS NULL;
