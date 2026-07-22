# Phase 7 report — Retention, i18n, iOS prep, polish

**Status: complete** (within this environment's limits — no macOS for an iOS
build). Phase 7 adds opt-in retention features, full internationalization
(English + Russian) across both clients, iOS Dart-readiness plus a native review,
and a full test pass. It was built and verified in three stages (features →
i18n over the new strings → verification + docs).

## Acceptance criteria

> "Retention features (behind flags), iOS finishing, i18n, polish, docs, full
> test pass."

- **Retention features (behind flags)** — three, all **client-side and
  E2EE-preserving**, each **double-gated**: active iff the operator kill-switch
  `RETENTION_FEATURES_ENABLED` (server, default on, advertised in
  `/v1/server-info`) **and** a per-user opt-in (client-local, default **off**)
  (D-0042). Nothing is on by default; the server gains no new plaintext.
- **i18n** — the entire web and app UI is internationalized with a complete,
  idiomatic **Russian** translation alongside English (D-0044). Verified live.
- **iOS finishing** — build is **deferred** (needs Xcode/macOS, unavailable
  here); Dart is iOS-guarded and the native side reviewed, surfacing one concrete
  blocker to fix in Xcode (D-0045).
- **polish / docs / full test pass** — done; see Verification.

## What shipped

**Retention (client-side, opt-in, off by default):**
- *Weekly digest* — web: a dashboard panel computing a rolling-7-day summary
  (places visited, distance, most-active member, SOS count) from **already-
  decrypted** data, no new endpoint; app: a lighter "This week" screen from
  on-device tracking stats.
- *Arrival / ETA* — app: the `GeofenceEngine` (over the device's own foreground
  fixes) wired to **local notifications** ("You arrived at …"); web: the browser
  **Notification API** + the in-session geofence feed with a rough ETA. All
  geofence computation stays client-side (D-0043).
- *Re-engagement* — app: honest, de-duplicated local reminders ("sharing is off",
  "battery low affecting tracking"). No nagware.
- Gating: server env + `/v1/server-info` field; per-feature opt-ins in the app's
  About screen and the web Preferences dialog; features fail **closed** when the
  server flag is off or state is unknown.

**i18n (EN + RU, both clients):**
- Web — `react-i18next` with **bundled** catalogs (`src/i18n/locales/{en,ru}.json`,
  synchronous init, no Suspense/loading gate — deliberately, so it can't
  reintroduce the Phase-6 render-loop). 14 feature areas fully extracted;
  interpolation + Russian plural forms; EN/RU switcher in Preferences + the
  landing footer; `<html lang>` tracks the language; a key-parity test enforces
  catalog completeness.
- App — Flutter `gen-l10n` (`flutter_localizations` + `intl` + `.arb`, 86 keys),
  a persisted System/English/Русский picker in About, localized notification
  bodies (via injected `AppLocalizations`, not hardcoded), and an `.arb`
  key-parity test.

**iOS (review only — no build):**
- Info.plist location purpose strings + `UIBackgroundModes`, and
  `PrivacyInfo.xcprivacy` (required-reason APIs, no tracking, honest collected
  types) reviewed and validated as well-formed plists; Dart guarded for iOS.
- **Blocker found:** `LocationBridge.swift` is not a member of the Runner target
  in `project.pbxproj`, so `AppDelegate` can't resolve it → the target won't
  compile. Recorded as a precise debt to fix in Xcode (not guessed blind here).

## Verification

Everything below was re-run by the integrator, not taken from agent self-reports.

- **server** — `go build/vet` clean; the **full integration suite** (`go test -p 1
  -tags=integration ./...`) passes against a live PostGIS (httpapi, auth,
  retention, crypto, config). `/v1/server-info` live-returns
  `retention_features_enabled`.
- **web** — `npm run build` + `npm run lint` + `npm test` green (i18n parity +
  RU render tests included).
- **app** — `flutter analyze` clean; `flutter test` **63 pass** (arrival gating,
  opt-in defaults-off, re-engagement, digest math, `.arb` parity, and a
  `Locale('ru')` widget test asserting Russian renders).
- **browser (real Chromium)** — landing defaults to EN; clicking **RU** re-renders
  all copy to Russian ("Приватная геолокация семьи", "Сквозное шифрование"),
  `<html lang>` → `ru`, the choice **persists** across reload; **`/v1/account/me`
  called once** (the Phase-6 render-loop did not return); `/download` still shows
  the live manifest. No console errors.

## Debts & follow-ups (tracked in TODO.md)

- **Cross-device background push** (VAPID for web + FCM/Firebase for app) is still
  unwired — arrival/ETA notify only while the app/tab is active. Biggest item.
- **iOS build** deferred to macOS; fix the `LocationBridge.swift` target
  membership in `project.pbxproj` there.
- App retention arrival runs in the foreground path only (no background isolate).
- Server-originated `error.message` strings aren't localized (would need
  server-side i18n or a client code→message map).
- Weekly-digest distance uses a `.` decimal (not locale-correct `,` for RU) —
  switch to `intl` number formatting. Minor.

> The phased build-out (P1–P7) is complete. Remaining work is the carried debts
> above plus the longer-horizon threat-model items (forward secrecy / MLS,
> multi-instance scale-out) — not new phases.
