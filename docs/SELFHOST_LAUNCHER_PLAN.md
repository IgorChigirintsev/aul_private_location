# Self-host launcher — build plan (grounded in the current code)

> **Decision update (2026-07-21):** the **signed / packaged one-click installer**
> direction is dropped — per-OS code-signing (Windows EV, macOS notarization) is
> costly and, for a solo maintainer, often not obtainable. The shipped self-host
> path is **build-from-source**: `make selfhost` (Go + Node, or Docker) compiles
> and runs the stack, and `make selfhost-doctor` guides the one-time Tailscale
> setup. Building locally needs no code-signing certificate at all. See
> [`../SELFHOST.md`](../SELFHOST.md). The launcher core + `doctor` (increments
> A–D below) are exactly what powers this; the tray scaffold (D) is retained but
> unshipped. This doc is kept for the architecture + the honest blocker ledger.


> Companion to [`SELF_HOST_DESIGN.md`](SELF_HOST_DESIGN.md) (the design and
> critique) and [`SELFHOST_PHASE0_REACHABILITY.md`](SELFHOST_PHASE0_REACHABILITY.md)
> (the Funnel reachability spike). **This doc is the engineering build plan**: what is
> *already implemented*, the gap to a "full one-click launcher", what is buildable in-repo
> vs. gated on external things, and a sequenced increment list with verification.
>
> Written 2026-07-21 after reading the launcher source. Target from the owner: the **full
> one-click launcher** (native, per-OS, tray UI, guided Tailscale Funnel setup).
>
> **Cross-OS is a hard requirement: self-host must run on Windows, macOS, AND Linux —
> not Linux-only.** The launcher core already satisfies this: it is `CGO_ENABLED=0` pure
> Go, so `GOOS=windows|darwin|linux go build` all produce a working headless binary today
> (`funnel.go` shells out to the cross-platform `tailscale` CLI; `browser.go` +
> `syncdir_{unix,other}.go` already fork per-OS). What is genuinely per-OS is only the
> **last mile** — the native tray shell (increment D) and installer signing/notarization —
> so "all-OS" is a packaging effort on top of one shared cross-OS codebase, not three
> separate ports.

---

## 1. Status snapshot — what already exists

The **headless launcher core is built and in production**: it is exactly what runs the
owner's live box (`aul-launcher --origin https://<name>.ts.net --port 8080`) that serves
`:8080` through the ts.net origin.

- **`server/cmd/aul-launcher/main.go`** — thin CLI. Flags: `--data-dir --origin --port
  --server-bin --no-open --ready-timeout --version`. Wires SIGINT/SIGTERM → graceful stop.
- **`server/internal/launcher/launcher.go` `Run()`** — the whole supervised lifecycle:
  `resolveDataDir` → single-instance `acquireLock` → `resolveServerBin` → **`provisionPepper`**
  (generate once, persist, never rotate — rotating logs everyone out) → **`resolveOrigin`**
  (Funnel detect → localhost fallback) → `composeEnv` (`PUBLIC_ORIGIN` + `AUL_ENV=production`
  + `SECURE_COOKIES=true` + SQLite DSN) → spawn `aul` under a **supervisor** (500 ms→30 s
  backoff, 60 s stable-run reset, 5 s stop grace) → `waitReady` on `/readyz` → `printStatus`
  → `openBrowser(origin)`.
- **`server/internal/launcher/funnel.go` `FunnelOrigin()`** — **auto-detects an existing
  Tailscale Funnel** from `tailscale status --json` + `tailscale serve status --json`
  (4 s deadline per call; any failure → localhost fallback with a human reason). It only
  **detects** a Funnel; it does not set one up. So `--origin` is optional when Funnel is live.
- Supporting: `readyz.go`, `env.go`, `paths.go`, `browser.go`, `syncdir_unix.go`,
  plus unit tests `funnel_test.go`, `pepper_test.go`.

**Maps to the design:** Phase 0 (reachability) is done; **most of Phase 1** (the walking
skeleton: pepper, origin injection, one supervised server, `/readyz`, open-at-origin) is done.
What Phase 1 still lacks is the **tray UI**; Phase 2 (guided onboarding, machine-name pin,
offline signal, cross-OS breadth, signing) is essentially untouched.

---

## 2. The honest gap to "full one-click"

A *shipped, signed, cross-OS, tray* self-host app is **weeks** of work, and several parts
**cannot be produced from this dev environment** — they need specific OSes, hardware, and
paid/legal credentials:

- **Code-signing / packaging**: macOS notarization (needs a Mac + Apple Developer ID),
  **Windows EV signing** (the critique flags it as *possibly legally unavailable*, not just
  costly), Linux AppImage (no cert, the cheap one).
- **Bundling `tailscaled`** per OS (must-mitigate #2) — per-platform binaries + updater.
- **The Tailscale onboarding itself is inherently manual** and no launcher can hide it
  (design §a): account via third-party SSO, install `tailscaled` (root), `tailscale up`
  browser auth, and **enable Funnel in the admin console** (an ACL/grant + HTTPS-certs
  toggle — a web-console action). The truthful product claim is *"one button to run your
  server; a short guided one-time setup to make it reachable."*

So "full one-click" is delivered as: **buildable-here code** (below) + a **last-mile
packaging/signing pass done on each target OS** with the right credentials.

---

## 3. Buildable here vs. externally gated

| Piece | Buildable in this repo/env? | Gate |
|---|---|---|
| Offline/staleness safety signal (web + app) | ✅ fully (code + tests) | — |
| `aul-launcher setup`/`doctor` guided TUI (Tailscale/Funnel preflight) | ✅ fully (pure Go + tests) | — |
| Auto-origin default + machine-name pin | ✅ fully | — |
| Wire desktop-web self-host card → guide page | ✅ fully | — |
| Member-facing disclosure (Tailscale metadata, FCM, tiles) | ✅ copy/UI | — |
| Self-host tiles (`TILES_ORIGIN`) to stop the OpenFreeMap leak | ✅ server/docs | operator runs a tile source |
| Linux tray GUI shell over the core | ⚠️ code yes (CGO/GTK) | can't sign/package for distribution here |
| macOS / Windows tray + installers | ❌ | Mac/Win hosts + signing certs |
| Bundle `tailscaled` | ❌ | per-OS binaries + updater |
| Actual Tailscale account + admin-console Funnel enablement | ❌ (inherently manual) | the operator, one-time |

---

## 4. Sequenced increments

Ordered by value-per-unblocked-effort. Each is independently shippable.

### A. Offline / staleness safety signal — **do first** (must-mitigate #3)
**Why:** for a location-safety product the worst failure is a *stale dot that looks live*.
A self-hosted box on a home PC WILL go offline (sleep, reboot, ISP), and an offline server
**cannot announce its own offline-ness** — so this must be **client-inferred**.
**Scope:** viewer detects realtime-WS disconnect + computes last-fix age locally → shows a
"Home server last seen N min ago — location may be stale" badge on the map + a per-member
staleness treatment. Web (`Dashboard`/`ConnectionBanner`/marker) and app
(`connection_banner.dart`/marker) already have most of the inputs (there is already a
client-inferred "updates paused" banner and marker staleness — this extends them into an
explicit *server-offline* state and an age readout).
**Verify:** unit tests for the age/threshold logic; Playwright (web) driving a WS drop;
`flutter test` for the badge state. No device needed.

### B. Guided setup TUI + auto-origin + machine-name pin
**Scope:** `aul-launcher setup` (and `doctor`) — a pure-Go preflight that runs the existing
`FunnelOrigin` probe and, on each failure reason, prints the *exact* next step (install
Tailscale / `tailscale up` / enable Funnel in the console with the ACL snippet / enable
MagicDNS+HTTPS). Make `--origin` optional (already auto-detected). **Pin the machine name**
so a Tailscale rename can't append `-1` and silently break every issued invite (design §c,
must-mitigate #6).
**Verify:** unit tests with a stubbed `tailscale` (the funnel probe is already stub-tested);
`aul-launcher doctor` golden-output tests.

### C. Wire the desktop-web self-host card → a real guide
**Scope:** replace the disabled "Coming soon" card (already **desktop-web-only** as of the
gating change) with an enabled card → a `/self-host` guide page: download the launcher,
the one command to run it, the guided Tailscale steps (shared with B), and "then open your
own `https://<name>.ts.net` and create your circle there." A browser cannot spawn a server,
so this is guide + download, honestly.
**Verify:** Playwright — card enabled on desktop, routes to the guide; still hidden on mobile.

### D. Cross-OS tray GUI shell — SCAFFOLDED
**Done here (pure-Go, in the default build + tests):**
- **`launcher.Options.OnReady func(origin string)`** — called the moment the server passes
  `/readyz`, handing the reachable origin to any GUI/tray shell. Keeps the core CGO-free.
- **`server/cmd/aul-tray/main.go`** — the shared cross-OS systray shell over `launcher.Run`
  (status · reachable address · open-dashboard · quit; `fyne.io/systray`, same source for
  Windows/macOS/Linux). Behind the `tray` build tag, so `go build ./...` and CI never pull
  in CGO. gofmt-clean, syntactically valid.

**NOT done here (honestly):** the tray was **not built or run** — a native tray needs CGO +
a GUI toolkit + a display, none available in the authoring env. Build it on a real desktop:
```
go get fyne.io/systray
sudo apt install libayatana-appindicator3-dev            # Linux
CGO_ENABLED=1 go build -tags tray -o aul-tray ./cmd/aul-tray   # place next to `aul`
```
macOS/Windows use the same source on their own hosts. **Signing/packaging/notarization for
distribution is the last mile** on each OS.

### Last mile (external, per OS) — not producible from this environment
macOS/Windows tray + notarized/EV-signed installers; bundled `tailscaled` + updater; the
disk-failure **backup-export** UX (must-mitigate #7); a diagnosable Direct-mode reachability
self-check (design §11).

---

## 5. Must-mitigate blockers from the critique → where they land

| # | Blocker | Lands in |
|---|---|---|
| 3 | Offline signal is client-inferred, not server-emitted | **A** (before any non-dogfood exposure) |
| 6 | Machine-name/identity portability breaks invites | **B** (pin name) |
| 1 | FCM is an undisclosed third party | disclosure copy (with C) + resolved by the existing FCM setup on the box |
| 4 | Members conscripted into Tailscale metadata w/o consent | member-facing disclosure (with C) |
| 10 | OpenFreeMap tiles leak coarse location | self-host tiles via `TILES_ORIGIN` (server/docs) |
| 7 | Disk failure = total loss; no off-box backup | backup-export (last mile, before GA) |
| 2 | "Single binary" contradicted by bundled `tailscaled` | last mile (packaging) |
| 5 | Funnel single-vendor WS-at-scale risk | standing dependency risk — document; load-test in Phase 0 follow-up |
| 8 | Dual-dialect SQL is a live safety-path bug source | ongoing server hygiene (sqlc parity tests) |
| 9 | Windows EV signing possibly unavailable | last mile; fall back to "use the hosted instance" |
| 11 | Direct-mode CGNAT failures | last mile (advanced toggle + self-check) |

---

## 6. Recommended sequence

**A → B → C** are all fully buildable + testable in-repo and deliver the safety-critical and
usability core; **D** is buildable-but-not-distributable here; the **last mile** is an
external, per-OS packaging/signing pass. Start with **A** (the safety bug), because it must
land before self-host is exposed to anyone who isn't dogfooding.
