# Phase 4 report — E2EE hardening across the stack

**Status: complete.** Both acceptance criteria met and validated: the Dart↔JS
(and Go) cross‑test passes for all E2EE primitives, and the server is proven to
store no plaintext. The "hard half" of E2EE deferred in D‑0019 — multi‑device
key envelopes, key rotation, and safety‑code verification — is implemented and
validated end‑to‑end.

## Acceptance criteria

> "Cross‑test Dart↔JS; the server contains no plaintext."

**1. Cross‑test — met (three‑way Go↔Dart↔JS).** The committed
`/vectors/crypto-vectors.json` now pins **safety codes**, **XChaCha20‑Poly1305**,
and **`crypto_box_seal`** (key envelopes). Automated tests in Go, Dart
(`flutter test`), and JS (`vitest`) each reproduce/open every vector — including
Dart and JS **opening a sealed box that Go produced**, and each round‑tripping
its own.

**2. Server contains no plaintext — met.** `TestServerStoresNoPlaintext`
(integration) posts a client‑sealed ping and asserts: the stored ciphertext does
**not** contain the plaintext marker, the `pings` table has **no coordinate
columns**, and the `circles` table stores **no key**. No coordinate is logged
anywhere (audited).

## What was built

- **`crypto_box_seal` in Go** (`nacl/box` anonymous, libsodium‑compatible) with a
  reproducible cross‑language vector (D‑0028).
- **Key‑envelope endpoints** already existed; added **`GET /v1/circles/:id/devices`**
  (member device identity public keys) so senders can seal K_c to each device.
- **Web `KeyManager`** + a per‑circle **keyring** (rotation‑safe history) +
  **`VerifyDevices`** safety‑code UI (compare emoji in person to detect MITM).
- **Dart `KeyManager`** (open pending envelopes on login/restore; distribute;
  rotate).
- **Rotation**: owner generates a new K_c, bumps the server key‑epoch, then
  distributes the new key to all member devices as sealed envelopes at that new
  epoch (order matters — one distinct envelope per rotation so an offline device
  catches up on every intermediate key; D‑0031). Old keys are retained so
  history stays readable (v1 has no forward secrecy — MLS is roadmap, D‑0029).
- Clients pick up keys via `openPendingEnvelopes()` on startup; the web dashboard
  exposes rotate + verify actions; K_c and private keys never touch the server.

## Validation

- **Three‑way crypto cross‑vectors** pass (Go, Dart, JS).
- **Key‑envelope round‑trip validated live** against the real server, in **both
  JS** (`test/envelope.live.test.ts`) **and Dart** (`key_manager_live_test.dart`):
  seal K_c to a device identity key → server relays a box it can't open → the
  device recovers K_c by opening it. The server never saw K_c.
- **No‑plaintext** integration test passes.
- Full sweep green: server (`-race`, integration, `golangci-lint`, `gosec`), app
  (`flutter analyze` + 35 tests), web (`oxlint` + 7 tests + build).

## Security review

An adversarial multi‑agent review (reviewer → independent verifier, two
dimensions: envelope/rotation correctness and no‑plaintext) was run. The
no‑plaintext dimension was **clean**. One **MEDIUM** finding was confirmed and
**fixed**:

- **Rotation collapsed all key epochs to `1`** (availability/correctness, not a
  confidentiality/integrity breach). The server hardcoded `key_epoch = 1` for
  envelopes posted with `key_epoch ≤ 0`, but envelopes upsert on
  `(circle, device, epoch)` — so each rotation overwrote the same row, and a
  device offline across **two** rotations received only the newest key, losing
  the ability to read pings sealed under the intermediate one. **Fix (D‑0031):**
  the server clamps `≤0` to the circle's real `key_epoch`, and both clients now
  bump the epoch *before* distributing (avoiding the verifier's noted off‑by‑one).
  Now each rotation produces a distinct envelope so an offline device catches up
  on every intermediate key. Regression‑guarded by
  `TestAPI_KeyEnvelopes_PerEpochDistribution`. No plaintext, key material, or
  access‑control property was ever affected.

Re‑ran the full sweep after the fix: server (`-race` + integration incl. the new
per‑epoch test, `golangci-lint` 0 issues, `gosec` clean), web (`oxlint` + 8
tests + build), app (`flutter analyze` + 35 tests) — all green.

## Known debts (see `docs/TODO.md`)

No forward secrecy in v1 (MLS roadmap); the reporter app keeps a single current
key (no history keyring — it seals, doesn't view); auto‑rotation on member
removal is offered to owners but not forced; safety‑code UI is web‑only so far
(app screen is a follow‑up).

## Next: Phase 5 — Places, geofences, history, SOS, precision modes
Encrypted places + client‑side geofence enter/exit, the history timeline, the SOS
center, and precision modes across all clients — on the E2EE foundation now
completed.
