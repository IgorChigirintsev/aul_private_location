# Security Policy & Self‑Hoster Checklist

## Reporting a vulnerability

Please report security issues privately, **not** in public issues.

- We aim to acknowledge within 72 hours and to ship a fix or mitigation within 90
  days, crediting you unless you prefer otherwise.
- Please include reproduction steps and the commit/version. Do not run tests
  against accounts or servers you don't own.

Scope: the server, web, and app in this repository. Out of scope: third‑party
infrastructure, social engineering, physical attacks, and denial‑of‑service via
raw volume (we rate‑limit; please don't stress‑test production).

## Security properties (enforced in code)

- **Passwords**: Argon2id (m=64 MiB, t=3, p=4, 16‑byte salt, 32‑byte key).
- **Sessions**: opaque 256‑bit tokens, SHA‑256‑hashed at rest, `httpOnly` +
  `Secure` + `SameSite=Lax` cookie (web) or Bearer (mobile); access TTL 15 min,
  refresh TTL 30 days with rotation and reuse‑detection; revocable by device.
- **Rate limiting**: per‑IP and per‑account; auth 10/min, invites 20/hour, pings
  120/min per device; exponential lockout on repeated auth failures.
- **Input validation**: ciphertext ≤ 4 KiB, batch ≤ 100, request body caps,
  per‑request timeouts.
- **Headers**: strict CSP (self + configured tiles origin), HSTS, `X-Content-Type-Options`,
  `Referrer-Policy`; CORS restricted to the configured origin.
- **Queries**: parameterized only (sqlc/pgx). No string‑built SQL.
- **Logging**: **plaintext coordinates are never logged, anywhere.** IP addresses
  in logs are retained ≤ 7 days (configurable, can be disabled).
- **Audit log**: logins, key rotations, invite issuance, member changes.

See [THREAT_MODEL.md](THREAT_MODEL.md) for the E2EE guarantees and honest limits.

## Security checklist for self‑hosters

Before exposing an Aul server to the internet:

1. **Set every secret in `deploy/.env`.** The server refuses to start if
   `SESSION_HASH_PEPPER` or `DATABASE_URL` are missing/weak. Generate secrets with
   `openssl rand -base64 48`.
2. **Terminate TLS.** Use the bundled Caddy example or your own reverse proxy.
   `SECURE_COOKIES=true` (default in prod) requires HTTPS.
3. **Set `PUBLIC_ORIGIN`** to your exact HTTPS origin; CORS and cookie scope
   derive from it.
4. **Keep `TRUSTED_SERVER_MODE=false`** unless you fully understand that enabling
   it lets the server read coordinates. It is off by default.
5. **Back up Postgres**, but remember the data is ciphertext — losing the circle
   key (client‑side) means the history is unrecoverable *by design*.
6. **Restrict database access** to the server only; do not expose `5432`.
7. **Set `IP_LOG_RETENTION_DAYS`** to your policy (default 7; `0` disables IP
   logging).
8. **Keep the binary updated**; watch releases for security fixes. Run
   `govulncheck` in your own CI if you build from source.
9. **Firewall** everything except the reverse proxy port.
10. **Review `audit_log`** periodically for unexpected key rotations or logins.
