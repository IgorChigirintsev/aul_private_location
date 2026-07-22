# Release & Signing

> Full APK signing and self‑update pipeline land in Phase 6. This file captures
> the procedure now so key handling is designed, not improvised.

## Server

- Tag `server-vX.Y.Z`. CI builds a static binary and a Docker image.
- Images are published with a digest; self‑hosters pin by digest.

## Android APK (Phase 6)

Aul distributes the Android APK from our own site (SHA‑256 published), **not**
Google Play. The signing key is the root of trust for auto‑updates, so its
handling is strict.

### Generating the keystore (once)

```sh
cd app && ./scripts/gen-keystore.sh    # writes aul-release.jks + android/key.properties
```

The script runs `keytool -genkeypair -keyalg RSA -keysize 4096 -validity 10000`
and scaffolds `android/key.properties` (git-ignored). When `key.properties`
exists, `flutter build apk --release` produces a **signed** APK; otherwise it
falls back to debug keys so CI dry-runs still work.

### Key backup (mandatory, two independent locations)

The signing key **cannot be rotated without breaking auto‑update** for installed
users. Losing it means every user must manually reinstall. Therefore:

1. Store the keystore + password in an offline password manager / hardware token.
2. Store a second encrypted copy in a physically separate location (e.g. a
   printed, encrypted paper backup or a second offline drive in another building).
3. Never commit the keystore or `keystore.properties` (both are git‑ignored).
4. In CI, the keystore is injected from encrypted secrets, never stored in the
   repo or image.

### Release build & manifest (Phase 6)

Pushing an **`app-vX.Y.Z`** tag runs `.github/workflows/release.yml`:

1. Restores the signing keystore from CI secrets into `app/android/key.properties`
   (see below) and runs `flutter build apk --release` — a **signed** APK.
2. Computes its SHA‑256 (`sha256sum`), derives `version_name` from the tag and
   `version_code` from `pubspec.yaml`, and attaches the APK to a GitHub Release.
3. Registers the release in the `app_versions` row served by
   `GET /v1/version/latest?platform=android`:

```json
{
  "version_code": 42,
  "version_name": "1.2.0",
  "apk_url": "https://dl.aul.app/aul-1.2.0.apk",
  "sha256": "…",
  "changelog": "…",
  "min_supported": 10
}
```

Registration is done by the **`aul publish-version` CLI subcommand** (D-0040),
not an HTTP endpoint — no new authenticated write surface on the public API:

```sh
aul publish-version --platform android --version-code 42 --version-name 1.2.0 \
  --apk-url /download/aul-1.2.0.apk --sha256 <hex> --changelog "…" --min-supported 10
```

It reads **`DATABASE_URL` directly** (never the full server config, so it needs
no `SESSION_HASH_PEPPER` etc.), upserts on `(platform, version_code)`, and
**refuses `--apk-url` without `--sha256`** (never publish an unverifiable APK).

**CI secrets** (all optional — absent ⇒ the workflow dry-runs with debug signing
and skips publish): `ANDROID_KEYSTORE_BASE64`, `ANDROID_STORE_PASSWORD`,
`ANDROID_KEY_PASSWORD`, `ANDROID_KEY_ALIAS`, and `DATABASE_URL`. Because a prod
DB is usually unreachable from GitHub runners, self-hosters typically skip the
`DATABASE_URL` secret and run `aul publish-version` **on the server host** after
the APK is placed under `/download/`.

Clients download, **verify the SHA‑256 against this manifest** before invoking the
system installer intent (`REQUEST_INSTALL_PACKAGES`), and refuse mismatches — the
in-app updater (`UpdateService`) deletes a mismatched download rather than install it.

## iOS (later)

App Store distribution. `PrivacyInfo.xcprivacy` and purpose strings are in the
repo from day one so review passes without private‑API surprises.
