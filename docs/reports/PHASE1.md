# Phase 1 report — Server core

**Status: complete.** Acceptance criterion met, full test suite green (`-race`),
security tooling clean, adversarial security review run and findings fixed.

## What was built

A single Go 1.25 binary (`server/cmd/aul`) that serves the REST API, the
WebSocket realtime channel, the embedded web app, and APK downloads — configured
entirely by environment variables and failing fast on invalid config.

- **Auth & sessions** (`internal/auth`): register / login / refresh / logout;
  Argon2id passwords (m=64 MiB, t=3, p=4); opaque 256‑bit session tokens stored
  only as peppered HMAC‑SHA256 hashes; refresh rotation with reuse detection
  (now an atomic compare‑and‑swap); persistent, escalating brute‑force lockout;
  device revocation; timing‑equalized unknown‑account login.
- **Crypto core** (`internal/crypto`): real, tested Argon2id, secure token
  generation/hashing, and the emoji **safety‑code** fingerprint — with a
  committed cross‑language vector file (`/vectors/crypto-vectors.json`) the Dart
  and JS clients will verify against in Phase 4.
- **Circles / members / invites** with roles (owner/member/guardian), precision
  modes, key‑epoch rotation trigger, and **instant unilateral leave** (anti‑
  stalking guarantee) that also cuts the departing member's live feed.
- **Pings**: idempotent encrypted batch ingestion (partitioned, dedup by
  `(device_id, client_id, captured_at)`), latest‑per‑device and history reads.
  The server stores ciphertext blobs it cannot read.
- **Places, SOS, key‑envelopes** (all E2EE blob relays), **version/latest**,
  **web‑push subscribe**, **server‑info**.
- **Realtime hub** (`internal/realtime`): per‑circle fan‑out, bounded per‑client
  buffers (slow clients dropped), membership‑change eviction, 30 s poll fallback.
- **Security middleware**: strict CSP/HSTS/nosniff/Referrer‑Policy, same‑origin
  CORS, body limits, per‑request timeouts, panic recovery, WebSocket‑safe access
  log, and a keyed token‑bucket rate limiter (per IP / account / device).
- **Background jobs** (`internal/retention`): monthly ping‑partition
  maintenance, O(1) partition drops past the retention horizon, per‑circle
  retention deletes, login‑attempt pruning, audit‑IP scrubbing, session cleanup.
- **Data model**: PostgreSQL 16 + PostGIS, `goose` SQL migrations, `sqlc`
  parameterized‑only typed queries.
- **Deploy**: distroless Docker image (22 MB), `docker compose` stack
  (server + postgres, optional Caddy TLS + self‑hosted tiles), `.env.example`,
  self‑host guide.
- **CI**: gofmt, vet, golangci‑lint v2, gosec, govulncheck, sqlc‑drift check,
  race tests (unit + integration), server build, Docker build.

## Acceptance criterion

> "Two devices in a circle see each other's pings."

**Met.** `scripts/acceptance.sh` runs the full curl scenario against a live
server + Postgres (register two users → circle → invite → join → each posts an
encrypted ping → each sees both devices' pings, plus idempotency). Realtime
fan‑out additionally verified: a watcher's WebSocket receives another member's
ping live.

## Quality

- **50 tests**, all passing under `go test -p 1 -race -tags=integration ./...`
  (unit tests need no DB; integration tests use a Postgres and run serially).
- Crypto, auth (incl. concurrent‑refresh double‑spend), rate limiter, hub
  (incl. eviction), retention, config, and full API flow are covered.
- `gofmt`, `go vet`, `golangci-lint` (v2), `gosec`, `govulncheck` — all clean
  (one stdlib TLS advisory unreachable in our plain‑HTTP‑behind‑proxy design;
  see TODO).

## Security review

Two adversarial multi‑agent passes were run (independent reviewer per dimension
→ independent verifier that tries to *refute* each finding). **Round 2 found no
authorization/IDOR defects** — membership/ownership enforcement held across every
endpoint. All confirmed findings were fixed and regression‑tested (DECISIONS
**D‑0016**, **D‑0017**):

| Sev | Finding | Fix |
|-----|---------|-----|
| HIGH | X‑Forwarded‑For leftmost‑hop trust → IP spoofing defeats rate‑limit/lockout | Prefer proxy‑set `X-Real-IP`; use only the rightmost XFF hop |
| MED | Non‑atomic refresh rotation → concurrent double‑spend evades reuse detection | Compare‑and‑swap rotation; 0 rows ⇒ reuse ⇒ revoke |
| MED | Removed member's live WS keeps receiving the circle | Hub `EvictUser`/`EvictCircle` on remove/leave/delete |
| MED | `login_attempts` retained email↔IP 30 days, ignoring IP‑log policy | Gate IP on IP‑logging flag; prune to 1 day |
| MED | Key‑envelope write amplification (no limit, 1000/req, never pruned) | Per‑user limit, cap 200, upsert (unique per epoch), retention prune |
| MED | Unbounded WebSocket connections (no limit, no cap) | Per‑IP upgrade limiter + per‑user/global admission ceilings |
| LOW | `PendingEnvelopesForDevice` unbounded | `LIMIT 500` + upsert bounds the queue |
| LOW | Registration reveals account existence (409) | Accepted for v1; documented; awaits email verification (P7) |

## Known debts

See [../TODO.md](../TODO.md). Highlights: in‑process rate limiter and single‑
instance realtime hub (both interface‑ready for Redis / `LISTEN‑NOTIFY`);
registration enumeration; FCM/APNs push deferred to later phases.

## Run it

```sh
# One-command stack:
cp deploy/.env.example deploy/.env   # set the 3 required secrets
docker compose -f deploy/docker-compose.yml up -d

# Or locally:
cd server && make db && make run
BASE_URL=http://localhost:8080 ./scripts/acceptance.sh
```

## Next: Phase 2 — Android reporter

Login, join‑by‑link, foreground location service, adaptive ping profiles,
offline queue, battery accounting. (Flutter codebase, iOS‑compatible from day 1.)
