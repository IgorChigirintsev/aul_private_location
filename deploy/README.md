# Self-hosting Aul

One command brings up the server + PostgreSQL. Everything the server needs
(migrations, web assets) is embedded in the single binary.

> **Want a free public server, step by step?** See
> [../docs/DEPLOY_FREE.md](../docs/DEPLOY_FREE.md) — a zero-cost walkthrough on
> Oracle Cloud Always Free (ARM) + DuckDNS + automatic HTTPS. This file is the
> generic reference for all the knobs.

## 1. Configure

```sh
cp deploy/.env.example deploy/.env
# Edit deploy/.env — at minimum set PUBLIC_ORIGIN, POSTGRES_PASSWORD,
# and SESSION_HASH_PEPPER. Generate secrets with: openssl rand -base64 48
```

## 2. Run

```sh
docker compose -f deploy/docker-compose.yml up -d
```

- App: `http://localhost:8080` (health: `/healthz`).
- The database is **not** exposed to the host — only the server reaches it.
- Migrations run automatically on startup.

## 3. TLS (recommended for anything public)

```sh
# set AUL_DOMAIN in .env, point DNS at this host, then:
docker compose -f deploy/docker-compose.yml --profile tls up -d
```

Caddy obtains and renews certificates automatically and proxies to the server.
Keep `PUBLIC_ORIGIN=https://your-domain` and `SECURE_COOKIES=true`.

## 4. Optional: self-hosted map tiles

```sh
# Put an OpenFreeMap/Protomaps export at deploy/tiles/<name>.pmtiles, then:
docker compose -f deploy/docker-compose.yml --profile tiles up -d
# Set TILES_ORIGIN in .env to the tile server's public origin so CSP allows it.
```

## 5. APK hosting

Place signed APKs in `deploy/apk/` (mounted read-only at `/apk`). They are served
at `/download/<file>.apk`, and `GET /v1/version/latest?platform=android` returns
the manifest clients verify against (see [../docs/RELEASE.md](../docs/RELEASE.md)).

## Security

Read the **Security checklist for self-hosters** in
[../docs/SECURITY.md](../docs/SECURITY.md) before exposing the server. Highlights:
keep `TRUSTED_SERVER_MODE=false` (default) to preserve E2EE, back up Postgres
(the data is ciphertext by design), and firewall everything except the proxy.

## Operations

- Logs: `docker compose -f deploy/docker-compose.yml logs -f server`
- Health: `curl https://your-domain/healthz` and `/readyz`
- Backups: `docker compose exec db pg_dump -U aul aul > backup.sql`
- Upgrades: pull a new image/tag and `up -d` again; migrations apply on boot.
