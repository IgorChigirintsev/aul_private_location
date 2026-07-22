# Deploying Aul on a free server (Oracle Cloud + DuckDNS)

A concrete, zero-cost path to a public Aul server: **Oracle Cloud Always Free**
(an ARM box that is free *forever*, not a trial) + a free **DuckDNS** subdomain +
automatic HTTPS. Total cost: €0. A card is asked only for identity verification;
Always Free resources are never billed.

For the generic self-host reference (all the knobs), see
[../deploy/README.md](../deploy/README.md). This document is the specific
walkthrough for the free path.

> **Before you start, one honest thing.** The moment other people use your
> server, you are the custodian of their data. Aul is E2EE — you cannot read
> anyone's location, and the database is ciphertext (see
> [THREAT_MODEL.md](THREAT_MODEL.md) §4 for the metadata you *can* see: emails,
> who-is-in-a-circle-with-whom, IPs). But you are now responsible for uptime,
> backups, and not losing the box. Backups below are **not optional**.

---

## What you are building

```
  phone / browser
        │  https://aul-yourname.duckdns.org
        ▼
   ┌─────────┐   :443
   │  Caddy  │  ← gets & renews the TLS cert automatically
   └────┬────┘
        │ :8080 (internal)
   ┌────▼────┐        ┌──────────────┐
   │ server  │───────▶│ postgres:16  │  (ciphertext only; not exposed)
   └─────────┘        └──────────────┘
```

One `docker compose` command brings up all three. The server binary already
contains the web app and the migrations.

---

## Step 1 — The machine (Oracle Cloud Always Free)

1. Sign up at **cloud.oracle.com** → choose a home region near you (e.g.
   **Frankfurt** / **Amsterdam** for RU/KZ — ~30–50 ms).
2. **Create a VM instance:**
   - Shape: **`VM.Standard.A1.Flex`** (Ampere ARM) — Always Free covers up to
     **4 OCPU / 24 GB**. Give it all 4 and 24 GB; it costs nothing.
   - Image: **Ubuntu 24.04**.
   - Add your **SSH public key** (you paste it during creation).
   - Boot volume: the default (~47 GB) is plenty; Always Free allows up to 200 GB.
3. **Networking — open 80 and 443.** In the instance's VCN → Security List, add
   two ingress rules: source `0.0.0.0/0`, TCP ports **80** and **443**. (22 is
   open by default for SSH.)

> **If you get "Out of capacity" on the ARM shape** — common in busy regions —
> you have two options in the *same* free account: retry later / another region,
> or create up to **two `VM.Standard.E2.1.Micro`** (AMD, 1 GB) instances instead.
> The stack runs on AMD unchanged; it is just a smaller box. Then SSH in and open
> 80/443 the same way.

SSH in:

```sh
ssh ubuntu@<your-instance-ip>
```

Oracle's Ubuntu images often keep a restrictive host firewall. Make sure 80/443
are allowed at the OS level too:

```sh
sudo iptables -I INPUT 6 -m state --state NEW -p tcp --dport 80 -j ACCEPT
sudo iptables -I INPUT 6 -m state --state NEW -p tcp --dport 443 -j ACCEPT
sudo netfilter-persistent save    # persist across reboots (install if missing)
```

---

## Step 2 — The domain (DuckDNS, free)

1. Go to **duckdns.org**, sign in, and create a subdomain, e.g.
   **`aul-yourname`** → you get `aul-yourname.duckdns.org`.
2. Set its IP to your instance's **public IP** (the DuckDNS dashboard has a box
   for it, or run their update URL once).
3. Confirm it resolves: `ping aul-yourname.duckdns.org` shows your instance IP.

Let's Encrypt issues certificates for `*.duckdns.org` names, so Caddy will get
HTTPS automatically — nothing else to do here.

---

## Step 3 — Install Docker

```sh
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker ubuntu        # log out and back in so this takes effect
```

---

## Step 4 — Get Aul and configure it

```sh
git clone <your-aul-repo-url> aul && cd aul
cp deploy/.env.example deploy/.env
```

Edit `deploy/.env`. The **three required** values:

```sh
PUBLIC_ORIGIN=https://aul-yourname.duckdns.org   # your exact https URL
AUL_DOMAIN=aul-yourname.duckdns.org              # same host, no scheme (Caddy uses it)
POSTGRES_PASSWORD=<paste: openssl rand -base64 48>
SESSION_HASH_PEPPER=<paste a DIFFERENT: openssl rand -base64 48>
```

Keep `SECURE_COOKIES=true` and `TRUSTED_SERVER_MODE=false` (the E2EE default).

**Optional — background push:**
- **Web Push (browser)**: generate a keypair and paste it in —
  ```sh
  docker compose -f deploy/docker-compose.yml run --rm server aul vapid-keys
  ```
  set `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`, and `VAPID_SUBJECT=mailto:you@…`.
- **FCM (Android background push)**: put your Firebase service-account JSON at
  `deploy/fcm/service-account.json` and set
  `FCM_SERVICE_ACCOUNT_FILE=/fcm/service-account.json`. (See the FCM setup notes;
  the file is a secret and is git-ignored.)

Both are optional — the server boots fine without either; you just get no
background notifications until they're set.

---

## Step 5 — Launch (with TLS)

```sh
docker compose -f deploy/docker-compose.yml --profile tls up -d
```

This builds the server image **on the box** (so it's native ARM), starts
Postgres, runs migrations, and starts Caddy — which fetches your certificate on
first request. Give it a minute, then:

```sh
curl https://aul-yourname.duckdns.org/healthz     # → ok
```

Open `https://aul-yourname.duckdns.org` in a browser, create an account, make a
circle. In the **app**, point it at this server URL on the login screen.

---

## Step 6 — Backups (do this now, not later)

A free VM can be reclaimed with its disk. Set up the daily backup **before** real
people depend on the box:

```sh
mkdir -p deploy/backups
deploy/backup.sh        # test it once — writes deploy/backups/aul-<stamp>.sql.gz
```

Add a cron job:

```sh
crontab -e
# add:
30 3 * * * cd /home/ubuntu/aul && deploy/backup.sh >> deploy/backups/backup.log 2>&1
```

It keeps the newest 14 dumps (`KEEP=…` to change) and rotates the rest. For real
safety, also copy them **off the box** periodically (another host, object
storage) — a backup that dies with the VM is not a backup. Restore instructions
are in the header of `deploy/backup.sh`.

---

## Operating it

| | |
|---|---|
| Logs | `docker compose -f deploy/docker-compose.yml logs -f server` |
| Health | `curl https://…/healthz` and `/readyz` |
| Update | `git pull && docker compose -f deploy/docker-compose.yml --profile tls up -d --build` (migrations apply on boot) |
| Restart | `docker compose -f deploy/docker-compose.yml --profile tls restart server` |
| Backup now | `deploy/backup.sh` |

See [SECURITY.md](SECURITY.md) for the self-hoster security checklist before you
invite anyone.

---

## Notes for this free tier

- **ARM works because the stack is multi-arch:** `postgres:16` is official and
  multi-arch, and the server builds from source on the box. Aul dropped PostGIS
  precisely so the DB runs on plain, official, ARM-capable Postgres (D-0061).
- **One instance only.** Aul's realtime hub is in-process (D-0035-era design), so
  running two server replicas would split live updates. One box handles far more
  than a family or a few circles need — this is not a scaling concern at this size.
- **The card.** Oracle asks for one to verify identity. Always Free resources are
  not charged; to be certain you are never billed, do not "upgrade to Pay As You
  Go" and stay within the Always Free shapes above.
