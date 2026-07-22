# Known debts & backlog

Tracked honestly. Each item notes the phase it belongs to. `[P1]` = Phase 1, etc.

## Carried debts (as of Phase 1)

- `[P1]` Rate limiter is in‑process only; multi‑instance deploys need a shared
  (Redis) backend. Interface exists; impl deferred. (See D-0008.)
- `[P1]` Realtime hub is single‑instance; multi‑instance needs a Postgres
  `LISTEN/NOTIFY` bridge. (See D-0009.)
- `[P1]` `/metrics` (Prometheus) endpoint is behind `METRICS_ENABLED` but exposes
  a minimal set; expand instrumentation later.
- `[P1]` APNs and FCM push are not wired in Phase 1 (Phase 6/7). Realtime is
  WS/poll only for now.
- `[P4]` No forward secrecy in E2EE v1; MLS is roadmap. (Documented in threat model.)
- `[P1]` ~~Web/app directories are placeholders until Phases 2–3.~~ **RESOLVED** —
  both clients are built out (web dashboard + landing; app full dashboard, D-0048).
- `[P1→P7]` **Registration account enumeration** (LOW): `POST /v1/auth/register` returns
  409 for an existing email, confirming account existence. Mitigated partially by
  non‑spoofable IP rate limiting; full fix (uniform response + email verification)
  waits on the email-verification feature in Phase 7.
- `[P1]` **Stdlib TLS/ECH advisory** GO‑2026‑5856 is flagged by govulncheck on
  toolchains before the fix. The server serves plain HTTP behind Caddy (it never
  calls the TLS listener), so the path is not reached; CI uses a patched Go 1.25.x.
- `[P1]` Per‑IP lockout is disabled when `IP_LOG_RETENTION_DAYS=0` (no IP stored);
  per‑account lockout still applies. Documented tradeoff.

## Carried debts (as of Phase 2 — Android reporter)

- `[P2]` **On‑device battery/background validation** on real hardware (the ≤3 %/day
  target and 24h‑in‑pocket criterion). The sandbox has no phone and can't keep an
  emulator resident; validated instead via the live E2EE test + built APK + unit
  tests (D‑0020).
- `[P2]` **ActivityRecognition** is currently approximated (speed → scheduler
  profile); wire the native ActivityTransition API for precise motion classes.
- `[P2]` **WorkManager watchdog** to re‑assert the foreground service on aggressive
  vendors; and **per‑vendor onboarding** (MIUI/EMUI/ColorOS/Samsung) deep‑links in
  the dontkillmyapp style.
- `[P2]` **Live Activity / iOS runtime** — iOS is scaffolded (CoreLocation bridge,
  purpose strings, privacy manifest) but not built/run (needs macOS/Xcode).
- `[P2]` ~~`maplibre_gl` map screen deferred — the reporter needs no map~~
  **RESOLVED** (D-0048): the app now has a MapLibre map with live member markers
  (`maplibre_gl` ^0.22.0, OpenFreeMap positron — the web's style).
- `[P2]` Gradle heap capped for small hosts; release builds should produce all ABIs.

## Carried debts (as of Phase 3 — Web dashboard)

- `[P3]` **Bespoke warm MapLibre style** — OpenFreeMap "positron" is used now;
  a custom palette‑matched style (warm base, pine road accents) is polish.
- `[P3]` ~~**Web Push (VAPID)** not wired yet~~ **RESOLVED** (D-0049): VAPID keys +
  sender on the server (`aul vapid-keys`), subscription + a service worker that
  decrypts the sealed payload on the web. The server relays ciphertext only.
- `[P3]` ~~**Bundle size** ~1.8 MB (MapLibre + libsodium)~~ **RESOLVED** (D-0048c):
  routes are lazy and crypto/map load on demand — the entry chunk the landing
  downloads is now **200 KB** (was one 1927 KB bundle).
- `[P3]` ~~**Device→member marker labelling**~~ **RESOLVED** (D-0046/D-0047):
  `GET /circles/:id/devices` gives device→user, and the sealed per-circle profile
  gives the nickname/avatar — markers are labelled per member (web + app), with a
  "PC" badge for web devices.
- `[P3]` ~~Dashboard is the MVP (map + members + invite); history timeline, place
  editor, SOS center, live-share session … come with Phases 4–5.~~ **RESOLVED** —
  all shipped on both clients (P4/P5 + D-0048), and the **live-share session** —
  the last survivor of this item, which had only a dead `TrackingMode.liveShare`
  behind it — is now built (D-0051): a per-session-key link that shows one
  unregistered outsider your live location, bound to the first device that opens
  it, ≤60 min, revocable.
- `[P3]` **Dev origin**: run the server with `PUBLIC_ORIGIN=http://localhost:5173`
  when using the Vite dev proxy (the WebSocket Origin allow‑list), or serve the
  embedded build same‑origin. Documented in DECISIONS D‑0027.

## Carried debts (as of Phase 4 — E2EE hardening)

- `[P4]` **No forward secrecy in v1** (documented in THREAT_MODEL §6). Rotating
  K_c doesn't make old ciphertext unreadable to members who had the old key. MLS
  (Messaging Layer Security) group keying is the roadmap.
- `[P4]` ~~The **reporter app keeps a single current circle key**~~ **RESOLVED**
  (D-0048): the app now keeps a per-circle **keyring** (all K_c epochs), so its
  new map/history/places/SOS viewer decrypts pre-rotation data.
- `[P4]` ~~**Auto‑rotation on member removal** ... consider prompting~~ **RESOLVED**:
  both clients prompt a key rotation right after a member is removed (web
  `promptRotateAfterRemoval`, app `_remove` → rotate confirm), so a removed member
  loses access to future data.
- `[P4]` ~~**Safety‑code verification UI is web‑only**~~ **RESOLVED** (D-0048): the
  app has a device-verification screen (safety-code emojis/digest per member device).

## Carried debts (as of Phase 5 — places, geofences, history, SOS, precision)

- `[P5]` **Cross-member geofence push** — **WEB HALF DONE** (D-0049): the arriving
  client seals the event under K_c and `POST /circles/:id/notify` relays it over
  Web Push to the circle; the web service worker decrypts and shows it with the
  tab closed. Still no plaintext-leaking geofence endpoint. **Remaining:** the app
  has no FCM/APNs (needs a Firebase project + `google-services.json`), so a phone
  with the app closed still gets nothing.
- `[P5]` The app **`GeofenceEngine` is unit-tested but not wired** to a native
  region-monitoring path or an on-device synced place cache; the reporter doesn't
  yet consume `/places` in the background isolate. (Enter/exit currently
  demonstrable on the web viewer.)
- `[P5]` ~~**App SOS payload** carries only `{msg, ts}`~~ **RESOLVED**: `raiseSos`
  now seals this user's freshest own position (`lat`/`lng`) into the alert, so it
  carries a location immediately, before the forced precise cadence delivers its
  first live ping. (A truly one-shot native GPS fix is a future refinement.)
- `[P5]` ~~**History is single-device, LIMIT 5000**, no cursor pagination~~ **MOOT**
  (D-0054): the history feature was deleted on both clients and the server
  endpoint removed. Ping ingest + `/pings/latest` remain for the live map.
- `[P5]` **Resolved-SOS history**: `GET /sos` returns only active alerts; the web
  keeps recently-resolved client-side. A server resolved-history endpoint
  (`GetSOS` exists, unused) is a possible addition.
- `[P5]` ~~**Device→member labelling** (carried P3)~~ **RESOLVED** — see the P3
  entry: markers/members show the sealed per-circle nickname + avatar on both
  clients; the history device picker resolves member names too.
- `[P5]` **Safety-code / places / SOS on iOS**: iOS remains scaffolded, not built
  (needs macOS/Xcode) — carried from P2.

## Carried debts (as of Phase 6 — landing + distribution)

- `[P6]` ~~**OG social card is a placeholder**~~ **RESOLVED** — `web/public/og-image.png`
  is now a purpose-built 1200×630 card (brand green, wordmark, "end-to-end
  encrypted" in mint, open-source/self-hostable/no-trackers chips, and the
  concentric-circle motif). Regenerate with the PIL snippet in the repo history if
  the brand copy changes.
- `[P6]` **Live signing/publish is untested in CI's own runs** — the release
  pipeline's real paths (keystore decode → signed APK, `aul publish-version`
  against a prod DB) only execute on a tagged run with `ANDROID_KEYSTORE_BASE64`
  + `DATABASE_URL` secrets configured. Without secrets it dry-runs (debug
  signing, publish skipped). Exercise once for real before the first release.
- `[P6]` **Prod DB usually unreachable from GitHub runners**, so the
  `publish-version` step is guarded and self-hosters instead run
  `aul publish-version` on the server host after the APK lands under `/download/`
  (documented in `release.yml` + RELEASE.md). A push-to-host or bastion path is
  a follow-up. (See D-0038/D-0040.)
- `[P6]` **Self-update download has no byte-progress** — `UpdateService`
  (unchanged) exposes no progress callback, so the app shows an indeterminate
  "Downloading & verifying…" spinner rather than a percentage. Add a progress
  stream if the download UX needs it.
- `[P6]` ~~**Marketing dark mode is scoped to `.landing`**~~ **RESOLVED**: dark mode
  is app-wide now — the `--color-*` tokens are overridden under
  `prefers-color-scheme: dark` at `:root`, so the dashboard/login follow the OS
  theme too (with a pine primary a white label reads on; the map basemap stays
  the light "positron" — a dark tile style is separate polish).
- `[P6→P7]` **Cross-member/background push still deferred** — Web Push (VAPID),
  APNs, and FCM remain unwired (carried from P1/P3/P5). The landing/download and
  in-app self-update ship without them; "X arrived home" and update-available
  push wait on Phase 7.

## Carried debts (as of Phase 7 — retention, i18n, iOS prep, polish)

- `[P7]` **Cross-device background push — WEB DONE, APP REMAINS** (D-0049). The
  server now has a VAPID sender (`aul vapid-keys`, `POST /circles/:id/notify`,
  dead-subscription pruning) and the web subscribes + decrypts the sealed payload
  in its service worker, so "X arrived home" reaches a **closed browser tab**.
  **Remaining:** the Flutter app has no **FCM** — it needs a Firebase project +
  `google-services.json` (external setup this environment can't do), and the app
  should also POST `/notify` from its own arrival monitor so a phone arriving
  notifies the circle. Until then a *closed app* still gets nothing, and
  **delivery has not been exercised against a real push service** from here (the
  SW push path itself is verified in a real browser via CDP). (See D-0043/D-0049.)
- `[P7]` **iOS still does not build.** `LocationBridge.swift` is **not a member of
  the Runner target** in `project.pbxproj`, so `AppDelegate` can't see it —
  `flutter build ios` would fail to compile. Fixing target membership (and a real
  build/run) needs **Xcode on macOS**, which this environment lacks. Info.plist
  purpose strings, background modes, and `PrivacyInfo.xcprivacy` were reviewed and
  are correct. Dart is iOS-guarded. (See D-0045.)
- `[P7]` **App retention runs in the foreground/active path only** — the geofence
  arrival monitor is not wired into the background isolate (carried from P5's
  "GeofenceEngine unit-tested but not wired"); background arrival needs the push
  pipeline above anyway.
- `[P7]` ~~**Server-originated error messages are not localized.**~~ **RESOLVED**
  (selective): a client code→message map localizes the context-free error codes
  (`rate_limited`, `account_locked`, `timeout`, `internal_error`, `forbidden`,
  `payload_too_large`) on both clients; context-specific codes (a login "wrong
  password") still pass through the server's own message, which reads better than
  a coarse category. Wired at the raw-message sites (web `Login`, app
  `login_screen`).
- `[P7]` ~~**Weekly-digest distance uses a `.` decimal**~~ **MOOT** (D-0054): the
  digest and the movement stats were deleted, so no distance is displayed at all.
- `[P7]` **`dart format` restyled pre-existing app files** (Dart 3.12 "tall"
  style) as a side effect of the retention/i18n work — semantics-preserving
  (analyze + tests green), noted for diff transparency (carried from P6).
- `[P7→later]` Optional polish: a `react-i18next.d.ts` type augmentation for
  compile-time `t()` key checking; native-speaker review of a few RU register
  choices (all listed in the Phase-7 report).

## Carried debts (as of app full-dashboard parity, D-0048)

- `[APP]` **App UI is not device-tested here** — no Android emulator/device in
  this environment, so map/tile rendering, the gallery picker, crop gestures, and
  marker interaction are verified only by `flutter analyze` + widget/unit tests +
  a successful **native APK build** (`flutter build apk`). Run the APK on a real
  phone to validate the live UI before release.
- `[APP]` **`flutter build apk` is now part of app verification** — `analyze`/
  `test` don't compile the Android native side. A Phase-7 desugaring gap
  (`flutter_local_notifications`) had left the APK un-buildable; fixed in
  `android/app/build.gradle.kts` (core-library desugaring on).
- `[APP]` **`maplibre_gl` pinned to `^0.22.0`** — `>=0.23` needs JDK 21 to compile
  its Android module; this env is JDK 17. Bump when CI/build JDK moves to 21.
- `[APP]` **Rotation & the background isolate**: a long-lived reporter isolate
  keeps its cached seal-key until the next cold start after an owner rotates the
  key. Safe (the old key stays in the keyring; v1 has no forward secrecy), but for
  an immediate refresh, inject vault+crypto into `BackgroundReporter` and add a
  native-forwarded `refreshTargets()`.
- `[APP]` **iOS still unbuilt** (no macOS/Xcode; carried, D-0045). The new
  Dart/UI is iOS-guarded but the iOS target's `LocationBridge.swift` target
  membership must still be fixed in Xcode.

## Carried debts (as of the mute/dashboard batch, D-0052b–D-0054)

- `[NEW]` ~~**Ping retention outlived its reason.**~~ **RESOLVED** (D-0056):
  `PING_RETENTION_HOURS` (default 6) replaces the 7-day window for pings; each
  device's newest ping survives at any age so nobody blanks off the map. A busy
  device stores ~17 pings instead of ~500.
- `[NEW]` **Mutes survive leave + rejoin** (keyed to user+circle, not membership).
  Defensible — it's the user's own preference — but flag it if you'd rather a
  fresh join starts unmuted.
- `[NEW]` **Screenshot blackout on the share viewer is a deterrent, not a control**
  (D-0051). A browser cannot stop an OS screenshot; the copy says only what's true.
  `FLAG_SECURE` (real, OS-level) would work inside the Android app but the viewer
  is deliberately a browser page for unregistered outsiders.

## Carried debts (app parity, D-0055)

- `[APP]` **Background push receipt needs FCM** — a Firebase project +
  `google-services.json`, which this environment cannot create. The app *sends*
  `/notify` fine (web clients get pushed); it just can't be reached while closed.
  Until then the app also only detects crossings in the FOREGROUND (the
  background isolate is unwired — carried from P5). **Cross-circle SOS is now
  surfaced**: a Home banner polls the user's other circles and shows an active SOS
  in any of them (tap to switch), so the selected-circle-scoped realtime socket no
  longer hides an SOS raised elsewhere while the app is open.
- `[APP]` **Foreground-service notification names the finest mode** when circles
  are on mixed precisions — there is no single honest mode to name, so it errs
  toward overstating what you share (understating would be the dangerous side).
- `[APP]` **No share-link viewer in the app** (deliberate): `/s/…` links open the
  web viewer. The sharer side is at parity and the codec is compatible.
- `[APP]` **No marker interpolation** — app pins jump between fixes; the web
  animates. Cosmetic.

## Roadmap status

**Phases 1–7 are complete** (see `docs/reports/`). The spec's phased build-out is
done: **P1** server core · **P2** Android reporter · **P3** web dashboard ·
**P4** E2EE across the stack · **P5** places/geofences/history/SOS/precision ·
**P6** landing + distribution · **P7** retention features (behind flags), i18n
(EN + RU), iOS Dart-prep + native review, polish, docs, full test pass.

What remains is **not a phase** but the carried debts above — chiefly the
**push pipeline** (VAPID/FCM) and a **macOS iOS build**, plus the longer-horizon
items already in the threat model (forward secrecy / MLS, multi-instance
scale-out via Redis + Postgres `LISTEN/NOTIFY`).
