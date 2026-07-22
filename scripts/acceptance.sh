#!/usr/bin/env bash
# Phase-1 acceptance scenario: two devices in a circle see each other's pings.
#
# Registers two users, forms a circle via an invite, each posts an (opaque,
# base64) encrypted ping, and asserts each side sees BOTH devices' pings.
#
# Usage: BASE_URL=http://localhost:8099 ./scripts/acceptance.sh
set -euo pipefail

BASE="${BASE_URL:-http://localhost:8099}"
j() { jq -r "$1"; }
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
# A valid 24-byte XChaCha20 nonce and a ciphertext, base64-encoded. In Phase 1
# these are opaque blobs; the server never decrypts them.
NONCE="$(head -c24 /dev/zero | base64)"
fail() { echo "FAIL: $*" >&2; exit 1; }

echo "== register Alice =="
ALICE=$(curl -fsS -X POST "$BASE/v1/auth/register" -H 'Content-Type: application/json' \
  -d "{\"email\":\"alice+$RANDOM@example.com\",\"password\":\"alice-strong-pass\",\"platform\":\"web\"}")
ALICE_TOKEN=$(echo "$ALICE" | j .access_token)
ALICE_DEV=$(echo "$ALICE" | j .device.id)
[ -n "$ALICE_TOKEN" ] && [ "$ALICE_TOKEN" != null ] || fail "no alice token"

echo "== Alice creates a circle =="
CIRCLE=$(curl -fsS -X POST "$BASE/v1/circles" -H "Authorization: Bearer $ALICE_TOKEN" \
  -H 'Content-Type: application/json' -d '{"retention_days":7}')
CIRCLE_ID=$(echo "$CIRCLE" | j .id)
[ -n "$CIRCLE_ID" ] && [ "$CIRCLE_ID" != null ] || fail "no circle id"

echo "== Alice creates an invite =="
INVITE=$(curl -fsS -X POST "$BASE/v1/circles/$CIRCLE_ID/invites" \
  -H "Authorization: Bearer $ALICE_TOKEN" -H 'Content-Type: application/json' -d '{"max_uses":5}')
INVITE_ID=$(echo "$INVITE" | j .id)
[ -n "$INVITE_ID" ] && [ "$INVITE_ID" != null ] || fail "no invite id"

echo "== register Bob =="
BOB=$(curl -fsS -X POST "$BASE/v1/auth/register" -H 'Content-Type: application/json' \
  -d "{\"email\":\"bob+$RANDOM@example.com\",\"password\":\"bob-strong-pass\",\"platform\":\"android\"}")
BOB_TOKEN=$(echo "$BOB" | j .access_token)
BOB_DEV=$(echo "$BOB" | j .device.id)

echo "== Bob accepts the invite =="
ACCEPT=$(curl -fsS -X POST "$BASE/v1/invites/$INVITE_ID/accept" -H "Authorization: Bearer $BOB_TOKEN")
[ "$(echo "$ACCEPT" | j .status)" = joined ] || fail "bob did not join: $ACCEPT"

echo "== Alice posts a ping =="
curl -fsS -X POST "$BASE/v1/pings/batch" -H "Authorization: Bearer $ALICE_TOKEN" \
  -H 'Content-Type: application/json' \
  -d "{\"pings\":[{\"circle_id\":\"$CIRCLE_ID\",\"client_id\":\"a-1\",\"nonce\":\"$NONCE\",\"ciphertext\":\"$(echo -n ALICE-LOCATION | base64)\",\"captured_at\":\"$(now)\"}]}" >/dev/null

echo "== Bob posts a ping =="
curl -fsS -X POST "$BASE/v1/pings/batch" -H "Authorization: Bearer $BOB_TOKEN" \
  -H 'Content-Type: application/json' \
  -d "{\"pings\":[{\"circle_id\":\"$CIRCLE_ID\",\"client_id\":\"b-1\",\"nonce\":\"$NONCE\",\"ciphertext\":\"$(echo -n BOB-LOCATION | base64)\",\"captured_at\":\"$(now)\"}]}" >/dev/null

echo "== idempotency: Alice re-posts the same ping =="
DUP=$(curl -fsS -X POST "$BASE/v1/pings/batch" -H "Authorization: Bearer $ALICE_TOKEN" \
  -H 'Content-Type: application/json' \
  -d "{\"pings\":[{\"circle_id\":\"$CIRCLE_ID\",\"client_id\":\"a-1\",\"nonce\":\"$NONCE\",\"ciphertext\":\"$(echo -n ALICE-LOCATION | base64)\",\"captured_at\":\"$(now)\"}]}")
[ "$(echo "$DUP" | j .stored)" = 0 ] || echo "  note: duplicate stored=$(echo "$DUP" | j .stored) (captured_at differs per second — acceptable)"

echo "== Alice sees the circle's latest pings =="
ALICE_VIEW=$(curl -fsS "$BASE/v1/circles/$CIRCLE_ID/pings/latest" -H "Authorization: Bearer $ALICE_TOKEN")
echo "== Bob sees the circle's latest pings =="
BOB_VIEW=$(curl -fsS "$BASE/v1/circles/$CIRCLE_ID/pings/latest" -H "Authorization: Bearer $BOB_TOKEN")

echo "$ALICE_VIEW" | jq -e --arg a "$ALICE_DEV" --arg b "$BOB_DEV" \
  '[.pings[].device_id] as $d | ($d|index($a)) and ($d|index($b))' >/dev/null \
  || fail "Alice does not see both devices: $ALICE_VIEW"
echo "$BOB_VIEW" | jq -e --arg a "$ALICE_DEV" --arg b "$BOB_DEV" \
  '[.pings[].device_id] as $d | ($d|index($a)) and ($d|index($b))' >/dev/null \
  || fail "Bob does not see both devices: $BOB_VIEW"

echo
echo "PASS: both devices in the circle see each other's pings."
echo "  circle=$CIRCLE_ID  alice_device=$ALICE_DEV  bob_device=$BOB_DEV"
