-- name: CreateUser :one
INSERT INTO users (email, pass_hash)
VALUES ($1, $2)
RETURNING *;

-- name: GetUserByEmail :one
SELECT * FROM users WHERE email = $1;

-- name: GetUserByID :one
SELECT * FROM users WHERE id = $1;

-- name: UpdateUserPassword :exec
UPDATE users SET pass_hash = $2, updated_at = now() WHERE id = $1;

-- name: EmailExists :one
SELECT EXISTS (SELECT 1 FROM users WHERE email = $1);
