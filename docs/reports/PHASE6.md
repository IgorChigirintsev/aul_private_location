# Phase 6 report — Landing + distribution

**Status: complete.** Aul now has a public marketing landing, a download page,
SHA‑256‑verified in‑app self‑update, and a signed‑APK release pipeline. A
scouting pass found the **distribution plumbing already scaffolded** in the
Phase 1–5 core — `GET /v1/version/latest` (backed by `app_versions`), the
`/download/*.apk` static handler, the app's `UpdateService` (download →
SHA‑256 → install) with its native FileProvider/installer, and `gen-keystore.sh`
— but with **no landing, no way to register a release, and the self‑update never
wired into the UI**. Phase 6 filled those gaps.

## Acceptance criteria

> "Landing + distribution: download page, `/version/latest`, self‑update,
> SHA‑256, SEO."

**Met and validated end‑to‑end.** The whole chain — CLI publish → DB →
`/version/latest` → what the web and app consume — was driven live against a real
server + PostGIS:

```
GET /v1/version/latest?platform=android         → 404 (no published version)
aul publish-version --platform android …        → upserted row (exit 0)
GET /v1/version/latest?platform=android         → manifest JSON
  --apk-url without --sha256                     → error, exit 1  (never unverifiable)
  --platform windows                             → error, exit 1
GET /  /download  /robots.txt  /sitemap.xml  /og-image.png  → 200, correct types
```

## What shipped

- **Landing** (`web/src/features/Landing.tsx`) — hero, four value props (E2EE /
  no‑ads / self‑host / anti‑stalking), a three‑step "how it works", an AGPL‑server
  + MIT‑clients self‑host strip, a JS‑free `<details>` FAQ, and a footer. Served
  at `/` to logged‑out visitors; the dashboard stays at `/` for logged‑in users,
  so no deep link moved (D‑0041). Dark‑mode aware via a scoped `.landing` palette
  (D‑0039) — zero impact on the light‑only dashboard.
- **Download** (`web/src/features/Download.tsx`) — fetches the manifest via a new
  `api.versionLatest()`, renders version + changelog, a copyable **SHA‑256** with
  a `sha256sum` hint, and the off‑Play sideload note; degrades to "coming soon —
  build from source" on 404 and an iOS "coming soon" card. New routes `/download`
  and `/login` (the sign‑in form, reached from the landing CTA).
- **SEO** — `index.html` gains canonical, `og:image`/`og:url`, a Twitter summary
  card, and JSON‑LD `SoftwareApplication`; `public/robots.txt` (Sitemap ref;
  **disallows `/i/`** — invite links carry the circle key in the fragment) and
  `public/sitemap.xml` (`/`, `/download`).
- **`/version/latest`** already existed; Phase 6 added its **only writer** —
  `aul publish-version` (D‑0040), a CLI subcommand that reads `DATABASE_URL`
  directly (no server secrets), validates flags in a pure, unit‑tested
  `parsePublishFlags` (9 cases), and upserts `app_versions`. `--apk-url` requires
  `--sha256`.
- **In‑app self‑update** — a Riverpod `UpdateController` sequences the existing,
  untouched `UpdateService` (discover → download + verify → install); a
  non‑intrusive Home banner runs a best‑effort startup check (errors swallowed —
  offline is normal) and an **About & updates** screen (Home app‑bar menu) offers
  a manual check and shows the installed version. Android‑only guard; install
  permission via `permission_handler`; a SHA‑256 mismatch aborts and surfaces
  "integrity check failed" rather than installing. Widget test covers
  prompt‑shown / no‑prompt / dismiss.
- **Release pipeline** (`.github/workflows/release.yml`, D‑0038) — on an
  `app-v*` tag: restore keystore from secrets → `flutter build apk --release` →
  `sha256sum` → GitHub Release → guarded `aul publish-version`. No‑secret runs
  dry‑run (debug signing, publish skipped); `actionlint` clean.

## Verification

- **server** — `gofmt -l` clean, `go build ./...`, `go vet ./...`,
  `go test ./cmd/aul/` (9/9). Live: publish + endpoint + validation + re‑upsert.
- **web** — `npm run build` (tsc + vite + PWA), `npm run lint` (oxlint), and
  `npm test` green; no new deps. **Driven in a real browser** (Playwright/Chromium)
  against the live server: the landing renders in full, `/download` shows the
  live manifest's version + SHA-256 + APK link, and `/login` renders. This browser
  pass caught a **render-loop blocker**: `Landing` calling `useMe()` added a second
  observer to the signed-out (errored) `['me']` query, whose refetch-on-mount
  flipped `Home` back to its loading branch and unmounted/re-mounted the landing in
  a tight loop (a ~120 req/s `/v1/account/me` storm — the marketing page never
  appeared). Fixed: `Landing` now reads auth state non-reactively via
  `getQueryData(['me'])` instead of subscribing; verified the storm is gone
  (`/v1/account/me` called once).
- **app** — `flutter analyze` clean, `flutter test` green (48 tests incl. the new
  self‑update UI cases). Native installer path (MethodChannel + FileProvider) was
  already present from earlier scaffolding.
- **ci** — `release.yml` valid YAML + `actionlint` clean; live signing/publish is
  exercised only on a real tagged run with secrets (see debts).

## Debts & follow‑ups (tracked in TODO.md)

- `og-image.png` is a placeholder copy of `hero.png`, not a 1200×630 social card.
- The release pipeline's real signing/publish paths are **untested without
  secrets + a reachable DB**; run once for real before the first release.
- Prod DB is usually unreachable from GitHub runners → self‑hosters run
  `aul publish-version` on the server host after the APK lands under `/download/`.
- Self‑update shows an indeterminate spinner (no byte‑progress callback).
- Cross‑member/background **push** (Web Push/APNs/FCM) stays deferred to Phase 7.

> Note: the app tree (untracked scaffold) was run through the repo's Dart 3.12
> "tall" formatter, so this phase's app diff includes whitespace‑only
> reformatting of pre‑existing files alongside the five self‑update files.
> `flutter analyze` + tests confirm the reformat is semantics‑preserving.
