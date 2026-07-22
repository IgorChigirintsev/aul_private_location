# Self-host Aul

Run the whole Aul stack on a computer you own. Your circle's data lives in a
SQLite file on **your** disk and never touches our servers.

You build it from source, so there is **nothing to download and no OS
code-signing certificate to buy** — the "unidentified developer" warnings only
apply to pre-built binaries you download, not to code you compile yourself. It is
free on Windows, macOS, and Linux.

> Most people should just use the hosted cloud — it's the same trust model (the
> server only ever holds ciphertext). Self-hosting is for those who want the data
> on their own machine and are comfortable with a terminal.

## Quick start (Go + Node)

Prerequisites: [Go](https://go.dev/dl/) and [Node/npm](https://nodejs.org/).

```bash
git clone <this-repo> aul
cd aul
make selfhost
```

That builds the web bundle, compiles the pure-Go server + launcher, and starts
your server. The launcher provisions the SQLite database and a persistent session
secret on first run, then opens the dashboard. `Ctrl-C` stops it.

For **just yourself on this machine**, that's all — the dashboard runs on
`localhost`. Create a circle and you're done.

## Letting remote family reach it

Phones on cellular need a public, stable address. Aul uses **Tailscale Funnel**
on **your own** Tailscale account, so no third party ever sees your traffic in
the clear (TLS terminates on your box). Check what's needed:

```bash
make selfhost-doctor
```

It inspects Tailscale and prints the exact next step for whatever isn't ready —
install Tailscale, `tailscale up`, or enable Funnel in the admin console. Once
`doctor` says **Ready**, re-run `make selfhost`: it auto-detects your
`https://<name>.ts.net` address and bakes it into every invite, so the web and
the app just work for remote members.

This one-time Tailscale setup is the only manual part — no launcher can automate
an SSO login and an admin-console toggle.

## Alternative: Docker

Prefer not to install Go/Node? Use Docker instead (it builds everything inside
the image):

```bash
git clone <this-repo> aul
cd aul
docker compose -f deploy/docker-compose.yml up --build
```

Reachability is the same story (`make selfhost-doctor`, or set `PUBLIC_ORIGIN`
directly if you run your own reverse proxy / domain).

## Good to know

- **Keep the computer on.** It's what your circle connects to; a laptop that
  sleeps is the wrong host for real use.
- **Back up the data dir.** Your database and session secret live there
  (`~/.config/aul` by default, or `AUL_DATA_DIR`). A dead disk loses the circle's
  history and logs everyone out — there is no copy anywhere else.
- **It's open source** (server AGPL-3.0, clients MIT) — audit anything you like.
