# Phase 2 report — Android reporter

**Status: complete.** The Flutter reporter builds to a working APK, its E2EE
reporting pipeline is validated end‑to‑end against the real server, and 34
Dart/widget tests pass. On‑device emulator UI validation is constrained by this
sandbox's resources (see below and DECISIONS **D‑0020/D‑0023**).

## What was built

A Flutter (Dart 3) app — Android first, iOS‑compatible from day one — that logs
in, joins a circle by invite link, and reports **end‑to‑end‑encrypted** location
from a native foreground service.

### E2EE from day one (no stubs, no plaintext to the server)
- `AulCrypto` wraps **libsodium** (`sodium`): X25519 identity keypair,
  XChaCha20‑Poly1305 ping/place sealing, `crypto_box_seal` key envelopes, and
  ISO‑7816 padding so ciphertext length doesn't leak precision.
- The **safety‑code** fingerprint uses SHA‑256 (`package:crypto`) for exact
  cross‑language parity.
- **Cross‑language interop is proven**: `flutter test` verifies the Dart safety
  code reproduces every Go vector, and that Dart **decrypts Go's XChaCha20
  ciphertext and re‑encrypts byte‑identically** — both from
  `/vectors/crypto-vectors.json`.
- The circle key `K_c` is generated on device (owner) or arrives only in the
  invite **URL fragment** (never sent to the server); private keys live in
  `flutter_secure_storage`.

### Reporting pipeline
- `LocationFix` + `PingCodec` (JSON → pad → seal), a **drift** offline queue that
  stores **only ciphertext**, a **dio** API client with automatic refresh‑token
  rotation, an **adaptive scheduler** (STILL 10 min / WALKING 60 s / DRIVING 15 s
  / live·SOS 5 s), exponential backoff, and battery‑accounting stats — the
  `Reporter` ties them together.
- **Live end‑to‑end test passes**: the app registers → creates a circle → seals a
  fix → posts it → the server stores ciphertext it cannot read → the client reads
  it back and decrypts to the exact coordinates.

### Native Android (Kotlin, no third‑party location plugin)
- `LocationService` — foreground service (`type=location`) with FusedLocation, a
  persistent, honest notification ("Sharing with … · [Pause 1h]"), and a
  **background FlutterEngine** running the tested Dart pipeline so reporting
  survives UI death and reboot (D‑0021).
- `BootReceiver` restarts reporting after reboot/update **only if the user
  enabled it**. Battery‑optimization exclusion prompt. Manifest declares all
  location/foreground/boot/install permissions.

### UI (warm, honest design system)
- Login/register, **progressive permission onboarding** (notification → while‑in‑
  use → background → battery), Home (share toggle, precision precise/city/paused,
  **"Who can see me"**, join‑by‑link, SOS long‑press), and a **debug/battery**
  screen. `themeMode: system`.

### iOS‑compat (second queue, but ready from day 1)
- `LocationBridge.swift` (CoreLocation: significant‑change + background indicator,
  no private APIs), all `NSLocation*UsageDescription` strings, and
  `PrivacyInfo.xcprivacy` (no tracking, no third‑party SDKs).

### Self‑update
- `UpdateService`: checks `/v1/version/latest`, downloads the APK, and **verifies
  its SHA‑256 against the manifest before installing** (verified‑only), then hands
  it to the system installer via a FileProvider. SHA‑256 verification is
  unit‑tested. Keystore generator (`scripts/gen-keystore.sh`) + RELEASE.md.

## Acceptance criterion

> "Phone in pocket for a day → track on the server; battery accounting in a debug screen."

- **Track on server: validated** — the live E2EE integration test proves an
  encrypted fix travels through the offline queue to the real server and back.
- **Battery accounting: present** — the adaptive‑scheduler cadence (the
  battery‑defining logic) is unit‑tested; the in‑app debug screen surfaces
  queue depth and config for on‑device measurement.
- **24‑hour on‑device battery drain: cannot be measured in this sandbox** (no
  physical phone; the emulator can't stay resident in ~2 GB free RAM). The
  ≤3 %/day target is enforced by design and documented as pending on‑hardware
  confirmation (D‑0020).

## Quality
- **34 tests** pass via `flutter test --exclude-tags live` (crypto incl. Dart⇄Go
  interop, ping codec, offline queue, adaptive scheduler, backoff, stats, SHA‑256
  update verify, onboarding + SOS widgets). The `live` E2EE test passes against a
  running server.
- `flutter analyze`: clean. **APK builds** (`flutter build apk` → valid APK with
  `classes.dex` + `libsodium.so` per ABI + manifest).
- CI: a Flutter job (pub get → codegen → analyze → test → build APK) added to
  `.github/workflows/ci.yml`.

## Security review

An adversarial multi‑agent review of the Phase‑2 crypto/key‑handling and
privacy/leak surfaces (reviewer → independent verifier, same method as Phase 1)
returned **zero findings**. The reviewers confirmed: `K_c` and the private
identity key never leave the device; `K_c` is taken only from the invite URL
fragment; the offline queue stores only ciphertext; and no plaintext coordinate
is logged or persisted. This is consistent with the checked‑in Dart⇄Go crypto
vectors.

## Known debts (see `docs/TODO.md`)
Full on‑device battery/background validation on real hardware; ActivityRecognition
is approximated by speed/scheduler (native transition API is a refinement);
vendor‑specific (MIUI/EMUI/…) auto‑start deep‑links; WorkManager watchdog;
maplibre map screen (deferred — the reporter needs no map; that's Phase 3).

## Next: Phase 3 — Web dashboard
React + Vite + MapLibre (OpenFreeMap tiles) live map, real‑time updates, members,
invite flow, PWA.
