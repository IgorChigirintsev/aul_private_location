#!/usr/bin/env bash
#
# Install a built APK on an already-running device/emulator, launch it, and fail
# unless the app is still alive afterwards.
#
# This exists because a release APK can pass every static check and still be
# incapable of starting: 1.0.0 shipped with R8 renaming a class WorkManager
# resolves reflectively, and the app died before any Dart code ran. Debug builds
# do not run R8 and the Dart test suite never reaches the native layer, so
# nothing else in CI can catch that class of failure.
#
# Kept as a FILE rather than inline YAML on purpose: the emulator-runner action
# executes its `script:` input line by line, each line in a separate `sh -c`, so
# any multi-line `if`/`for` there dies with "Syntax error: end of file
# unexpected". A single-line invocation of this script sidesteps that entirely —
# and makes the check runnable by hand against a local emulator.
#
# Usage:  scripts/smoke-test.sh <path-to-apk>   (with `adb devices` non-empty)

set -euo pipefail

APK="${1:?usage: smoke-test.sh <path-to-apk>}"
PKG="${SMOKE_PKG:-app.aul.aul}"
WAIT="${SMOKE_WAIT:-25}"

echo "Smoke-testing $APK ($PKG)"

adb install -r "$APK"
adb logcat -c
adb shell am start -n "$PKG/.MainActivity"

# Startup crashes surface within a few seconds; the rest is slack for a cold
# emulator, where first-frame work is far slower than on real hardware.
sleep "$WAIT"

if adb logcat -d -b crash | grep -q "$PKG"; then
  echo "::error::$PKG crashed on launch — refusing to publish this build."
  adb logcat -d -b crash | tail -60
  exit 1
fi

pid="$(adb shell pidof "$PKG" | tr -d '\r' || true)"
if [ -z "$pid" ]; then
  echo "::error::$PKG is not running ${WAIT}s after launch — refusing to publish this build."
  adb logcat -d | grep -iE "$PKG|AndroidRuntime|FATAL" | tail -60 || true
  exit 1
fi

echo "OK: $PKG launched and is still alive (pid $pid)."
