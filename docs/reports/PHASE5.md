# Phase 5 report — Places, geofences, history, SOS, precision

**Status: complete.** Encrypted places (with geofence radii), client-side
geofence enter/exit, the history timeline, the SOS centre, and precision modes
are built across all three clients on the E2EE foundation from Phase 4. A
scouting pass found the **server side already implemented** in the Phase-1 core
(places CRUD, SOS, ping history, precision, realtime fan-out), so Phase 5 was
mostly **clients + tests + hardening** (D-0036).

## Acceptance criteria

> "Places, geofences, history, SOS, precision modes on all clients."

**Met and validated end-to-end.** The web dashboard (the demonstrable client)
drives all five through the real UI against the real server; the reporter app
gets correct, unit-tested implementations of the same capabilities. Everything
new stays sealed under K_c — the server only relays ciphertext.

- **Places** — create/edit/delete with a map-click centre + radius slider,
  rendered as labelled pins + true-metre geofence circles. Name + coordinates +
  radius are sealed as a single **framed, padded** blob (D-0034); the server
  stores one opaque `ciphertext` column with no name/coord fields.
- **Geofences** — computed **entirely client-side** (D-0035): the web shows live
  "who is inside which place" + an arrive/depart feed from decrypted positions vs
  places; the app has a pure-Dart `GeofenceEngine` (hysteresis/debounce). No
  server geofence table — a crossing carries no new server-visible plaintext.
- **History** — a device picker + time window fetch the encrypted pings, decrypt
  them with the circle keyring, and draw the track on the map with a scrubber.
  The server validates `from ≤ to` and reports `truncated` (no silent cut-off).
- **SOS** — a red banner for active alerts with Resolve, a raise action (web and
  app), sealed payload + realtime fan-out. The app's SOS flips tracking to a fast
  precise live cadence (`TrackingMode.sos`, 5 s) so watchers get a location. An
  undecryptable alert **still shows** (metadata) so no emergency is missed.
- **Precision** — precise/city/paused settable on both clients; the web now
  live-refreshes on the `precision_mode` realtime event.

## Cross-language crypto (place_framed)

`/vectors/crypto-vectors.json` gained a **`place_framed`** vector pinning the
exact byte layout places/SOS use: `pad(json, 256)` (libsodium `sodium_pad`) then
`nonce||ciphertext`. Go generates it; **JS and Dart both reproduce the padding
and open Go's framed blob**, so the layout is pinned across languages — not just
round-tripped per client. Padding hides name/message length (verified: a short
and a long place name seal to equal-length ciphertext).

## Server hardening (D-0036)

- History: `from ≤ to` validation (400 otherwise) + a `truncated` flag when the
  5000-row window fills.
- Retention: the hourly worker now prunes **resolved SOS** and **soft-deleted
  place tombstones** past the max-retention horizon (both were unbounded).
- Tests: integration coverage for places (CRUD + 409 version-conflict), SOS
  (lifecycle), history (ordering + validation); the **no-plaintext audit extended
  to `places_enc` and `sos_events`** (no coordinate/name columns; sealed markers
  never appear in stored bytes).

## Validation

- **Server**: `-race` unit, serial (`-p 1`) integration incl. the new Phase-5
  tests, `golangci-lint` 0 issues, `gosec` (excl. generated) clean.
- **Web**: `oxlint` + `tsc` clean, 17 unit tests (place codec, geofence, crypto
  vectors incl. place_framed), production build, and **3 Playwright e2e** live
  against the Go build: marker-move, create-place-with-geofence, SOS
  raise→banner→resolve.
- **App**: `flutter analyze` clean, 43 tests incl. place codec, geofence engine
  (hysteresis/prune), and the place_framed cross-vector.

## Security review

An adversarial review (4 dimensions — places/SOS crypto + no-plaintext,
access control, client-side geofences, history/retention/realtime — each
reviewer → independent verifier) was run. It **confirmed the server secure**
where it matters: no cross-circle IDOR on places/SOS/history, correct
optimistic-concurrency, correct owner/member scoping, no circle-existence leak,
and retention that never deletes an active SOS or a live place. **No
critical/high** findings. Fixed (D-0037):

- **[MEDIUM] Stale SOS poll clobbered a live alert** → race-safe `reconcile`
  (never hides a live SOS for a poll interval).
- **[MEDIUM] Viewer-side geofence presence went permanently stale** for a device
  that stopped reporting → freshness cutoff (15 min) + periodic re-evaluation.
- **[LOW] `SoftDeletePlace`** missing `deleted=false` guard (tombstone refresh /
  version inflation) → guarded. **History truncation** dropped the newest pings
  → newest-first LIMIT, reversed for playback. **Domain-separation AD**
  (`aul-place:v1`/`aul-sos:v1`) so a ciphertext can't cross field types.
  **Length-leak** honesty: THREAT_MODEL §5 documents the 256-byte bucket + the
  unpadded circle-name length; UI caps (name 80, SOS 160); D-0034 over-claim
  softened. Plus small web fixes (pure React updater, presence key by `placeId`,
  `openSos` never throws on a malformed payload).

Re-ran the full sweep after the fixes: server (`-race` + serial integration +
lint + gosec), web (lint + 17 unit + 3 Playwright e2e live), app (analyze + 43
tests incl. the `place_framed` vector now asserting a wrong-AD open fails) — all
green.

## Known debts (see `docs/TODO.md`)

Cross-member geofence **push** notifications ("X arrived home") ride the Web
Push/APNs/FCM roadmap (Phase 6/7), not a new plaintext endpoint. The app's
geofence engine is wired and tested but not yet connected to native region
monitoring / a synced place cache on-device. SOS payload from the app carries a
message + timestamp (watchers see the live location via the forced 5 s cadence);
attaching a one-shot fresh fix is a follow-up. Device→member marker labelling is
still circle-level (carried P3 debt) — history uses the device list to pick.

## Next: Phase 6 — Landing + distribution
Marketing landing page, download page with SHA-256, `/version/latest`,
self-update, SEO.
