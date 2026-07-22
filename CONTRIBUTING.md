# Contributing to Aul

Thanks for helping build a private alternative to surveillance‑ware.

## Ground rules (non‑negotiable)

1. **Never log plaintext coordinates** or any decrypted payload, anywhere.
2. **Never send the circle key (K_c) or any private key to the server.**
3. **No hand‑rolled cryptography.** Use libsodium primitives only.
4. **Parameterized SQL only** (sqlc). No string‑concatenated queries.
5. **No hidden location reporting.** Anti‑stalking guarantees (visible
   notification, one‑tap "who sees me", instant leave) are product law.
6. **No third‑party trackers/ad SDKs.** Not in the app, not on the landing page.

## Dev setup

- **Server** (`server/`, Go 1.25+):
  ```sh
  cd server
  go build ./...
  go test ./...                 # unit tests, no DB required
  # integration tests need a DB (run serially: -p 1 — they share/truncate one DB):
  docker compose -f ../deploy/docker-compose.yml up -d db
  DATABASE_URL=postgres://aul:aul@localhost:5433/aul?sslmode=disable go test -p 1 -tags=integration ./...
  ```
  Regenerate typed queries after editing `db/queries/*.sql` or `db/migrations/*`:
  ```sh
  sqlc generate         # run from server/
  ```
- **Web** (`web/`): Phase 3.
- **App** (`app/`): Phase 2.

## Style

- Go: `gofmt`, `golangci-lint run`. Keep handlers thin; put logic in packages.
- Every decision that isn't obvious goes in `docs/DECISIONS.md`.
- Add tests with code, especially for anything in `auth`, `crypto`, `ratelimit`,
  `retention`.

## Commit / PR

- Small, focused PRs. Reference the phase.
- CI must pass: `gofmt`/`golangci-lint`, `go test`, `govulncheck`, `gosec`, build.
- Security‑relevant changes get an extra review pass.

## License

By contributing you agree your contributions are licensed under AGPL‑3.0
(`server/`, `deploy/`) or MIT (`web/`, `app/`) matching the directory.
