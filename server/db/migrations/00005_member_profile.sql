-- +goose Up
-- A member's per-circle profile (nickname + small avatar) sealed under the
-- circle key K_c. The server only ever stores/serves this ciphertext, never the
-- plaintext nick or image (E2EE; ad "aul-profile:v1"). Nullable: no profile set
-- means clients fall back to the member's email and its first letter.
ALTER TABLE circle_members ADD COLUMN profile_enc bytea;

-- +goose Down
ALTER TABLE circle_members DROP COLUMN profile_enc;
