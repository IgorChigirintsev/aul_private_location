#!/usr/bin/env bash
# Generates the Aul Android release signing keystore and android/key.properties.
#
# The signing key is the ROOT OF TRUST for auto-update: if it is lost, installed
# users cannot auto-update and must reinstall manually. BACK IT UP in two
# independent places (see docs/RELEASE.md). NEVER commit the .jks or key.properties.
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"          # app/
KEYSTORE="${1:-$DIR/aul-release.jks}"
ALIAS="${KEY_ALIAS:-aul}"

if [ -f "$KEYSTORE" ]; then
  echo "Refusing to overwrite existing keystore: $KEYSTORE" >&2
  exit 1
fi

echo "Generating 4096-bit RSA release key (validity ~27 years)…"
keytool -genkeypair -v \
  -keystore "$KEYSTORE" \
  -alias "$ALIAS" \
  -keyalg RSA -keysize 4096 -validity 10000

cat > "$DIR/android/key.properties" <<EOF
storeFile=$KEYSTORE
keyAlias=$ALIAS
# Fill these in (they were set during keytool above). Do NOT commit this file.
storePassword=
keyPassword=
EOF

echo
echo "Wrote android/key.properties (fill in the passwords)."
echo "Print the certificate SHA-256 (publish it so users can verify APKs):"
echo "  keytool -list -v -keystore \"$KEYSTORE\" -alias \"$ALIAS\""
echo
echo "!! BACK UP $KEYSTORE + its passwords in two independent, offline locations."
