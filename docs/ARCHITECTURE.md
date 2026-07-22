# Aul — Architecture

## Overview

```
                 ┌─────────────────────── Reporter (Flutter, Android/iOS) ──────────┐
                 │  FusedLocation/CoreLocation → adaptive profiles → drift queue     │
                 │  libsodium: seal ping {lat,lng,…} with K_c (XChaCha20-Poly1305)   │
                 └───────────────┬───────────────────────────────────────────────────┘
                                 │ HTTPS (Bearer) / WSS
   Watcher (Web PWA / app) ──────┤
   libsodium-wrappers, MapLibre  │
                                 ▼
        ┌──────────────────────────── Aul server (Go, one binary) ─────────────────────┐
        │  chi router → middleware (rate-limit, headers, CORS, body-limit, timeouts)    │
        │  REST /v1/*        WebSocket /v1/realtime (in-proc hub, per-circle fan-out)    │
        │  auth (Argon2id, opaque sessions)   handlers   embed.FS (web + APK)            │
        │  sqlc/pgx (parameterized only)      retention + partition-maint background jobs│
        └───────────────┬───────────────────────────────────────────────────────────────┘
                        │ pgx pool
                        ▼
        PostgreSQL 16 + PostGIS   (pings partitioned monthly by server_ts)
        Stores ciphertext blobs. Cannot read coordinates (E2EE mode).
```

## Server components (`server/internal/`)

| Package      | Responsibility |
|--------------|----------------|
| `config`     | Load & validate all env into a typed `Config`. Fail fast on missing secrets. |
| `crypto`     | Argon2id password hash/verify, secure token generation, token hashing, safety‑code derivation. Real, tested, no stubs. |
| `store`      | sqlc‑generated typed queries + a thin `Store` wrapper (pool, tx helpers). |
| `auth`       | Register/login/refresh/logout, session issuance & rotation, device revocation. |
| `middleware` | Request ID, real‑IP, security headers, CORS, body limit, timeout, panic recovery, structured access log (IP retention‑aware). |
| `ratelimit`  | `Limiter` interface + in‑process token‑bucket impl keyed by IP and account, with exponential lockout. |
| `httpapi`    | chi router assembly; circle/invite/ping/place/sos/key‑envelope/version handlers; request/response DTOs; static+APK serving. |
| `realtime`   | WebSocket hub: auth handshake, per‑circle subscriptions, event fan‑out. |
| `retention`  | Background jobs: delete expired pings (per‑circle `retention_days`), prune old IP logs, pre‑create ping partitions. |
| `audit`      | Append‑only security event log writer. |
| `version`    | `GET /v1/version/latest` — APK/app update manifest. |
| `validate`   | Shared input validators (sizes, batch limits, formats). |

`cmd/aul` wires everything, runs migrations on boot (opt‑out), starts HTTP + jobs,
and handles graceful shutdown.

## Request lifecycle (a ping batch)

1. `POST /v1/pings/batch` with `Authorization: Bearer <access>` and a JSON body of
   ≤ 100 items, each `{client_id, nonce, ciphertext, ttl, server_ts?}`.
2. Middleware: rate‑limit (device 120/min), body‑limit (≤ ~450 KiB), auth →
   resolves `device_id` + circle membership.
3. Handler validates each item (blob ≤ 4 KiB, base64, ttl bounds), upserts by
   `(device_id, client_id)` for idempotency, in one transaction.
4. On commit, handler publishes a `ping` event per circle to the realtime hub.
5. Hub fan‑outs the ciphertext blob to every subscribed watcher socket.

The server never inspects blob contents and never logs them.

## Data model

See [../server/db/migrations](../server/db/migrations). Key tables: `users`,
`devices`, `sessions`, `circles`, `circle_members`, `invites`, `pings`
(partitioned), `places_enc`, `key_envelopes`, `sos_events`,
`push_subscriptions`, `app_versions`, `audit_log`, `login_attempts`.

## Realtime

Single hub goroutine owns subscription state; connections have buffered send
channels; slow consumers are dropped (bounded memory). Handlers → hub via a
non‑blocking publish. Multi‑instance scaling (future): bridge hubs over Postgres
`LISTEN/NOTIFY`.

## Deployment

`deploy/docker-compose.yml`: `server` + `postgres` (+ optional `tiles`). Caddy in
the example terminates TLS and adds edge rate‑limits. Config via `deploy/.env`.
Single binary also runs bare‑metal with a `DATABASE_URL`.
