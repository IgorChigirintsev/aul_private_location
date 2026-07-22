# Aul

**Private family location, end‑to‑end encrypted.** A self‑hostable, open‑source
alternative to Life360 where the server never sees your coordinates.

> Aul (аул) — a family/kin settlement. The name is the promise: your circle,
> your data, nobody else's.

- **No ads, no third‑party analytics, no data sales.** Privacy *is* the product.
- **End‑to‑end encrypted.** The server stores ciphertext blobs it cannot read.
  Location pings, place names and geofences are encrypted on the device with a
  key that never leaves your circle.
- **Self‑host in one command** (`make selfhost`) — built from source, so no
  code‑signing certificate needed — or use our cloud.
- **Anti‑stalking by design.** No hidden mode — a reporter always shows a visible
  notification. One‑tap "who can see me". Instant, unilateral leave.

## Status

Built in phases (see [docs/DECISIONS.md](docs/DECISIONS.md),
[docs/TODO.md](docs/TODO.md), and the per-phase reports in `docs/reports/`).
**Phases 1–7 are complete**: server core, Android reporter, web dashboard, E2EE
across the stack, places/geofences/history/SOS/precision, the landing +
distribution pipeline (marketing site, download page, `/version/latest`,
SHA‑256‑verified in‑app self‑update), and retention features (behind flags,
default off), internationalization (English + Russian), iOS Dart‑readiness, and a
full test pass. The phased build‑out is done; remaining work is the carried debts
in [docs/TODO.md](docs/TODO.md) — chiefly the push pipeline (VAPID/FCM) and a
macOS iOS build.

## Repository layout

| Path       | What                                                             | License   |
|------------|-----------------------------------------------------------------|-----------|
| `server/`  | Go 1.25+ backend: REST + WebSocket + static web + APK, one binary | AGPL‑3.0 |
| `web/`     | React + TypeScript PWA (dashboard + landing)                    | MIT       |
| `app/`     | Flutter (Android first, iOS later) full client — reporter + dashboard (map, circles, places, history, SOS, verify) | MIT       |
| `deploy/`  | docker‑compose, Caddy example, self‑host docs                   | AGPL‑3.0  |
| `docs/`    | Architecture, threat model, decisions, release, security        | —         |

## Quickstart (self‑host)

Build from source and run your own server. There is **nothing to download and no
code‑signing certificate to buy** — the OS "unidentified developer" warnings only
apply to pre‑built binaries, not to code you compile yourself. Requires Go + Node:

```sh
git clone https://github.com/aul-app/aul
cd aul
make selfhost
```

The launcher provisions a SQLite database + session secret on first run and opens
the dashboard. To let remote family (phones on cellular) reach it, run
`make selfhost-doctor` — it guides the one‑time Tailscale setup. **Full guide:
[SELFHOST.md](SELFHOST.md).**

Prefer containers? `docker compose -f deploy/docker-compose.yml up --build` (copy
`deploy/.env.example` → `deploy/.env` first). See [deploy/README.md](deploy/README.md)
and the **Security checklist for self‑hosters** in [docs/SECURITY.md](docs/SECURITY.md).

## Documentation

- [Architecture](docs/ARCHITECTURE.md)
- [Threat model](docs/THREAT_MODEL.md) — what the server sees and, honestly, what it doesn't
- [Engineering decisions log](docs/DECISIONS.md)
- [Security policy](docs/SECURITY.md)
- [Release & signing](docs/RELEASE.md)
- [Contributing](CONTRIBUTING.md)

## License

Aul is split‑licensed. The server (`server/`, `deploy/`) is **AGPL‑3.0** so that
network‑hosted modifications stay open. The clients (`web/`, `app/`) are **MIT**
so anyone can build and distribute them freely. See per‑directory `LICENSE`
files.
