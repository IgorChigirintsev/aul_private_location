#!/usr/bin/env bash
# Fast deploy for a RAM-starved host (the free GCP e2-micro has 1 GB).
#
# Instead of `docker compose up --build` — which compiles the whole Go module ON
# the box and, when the embedded web bundle changed, thrashes swap for 20+ minutes
# and can OOM the linker — this builds the static binary HERE (where there's RAM),
# ships just the ~19 MB binary, and wraps it in distroless on the box. End to end
# it is seconds, not half an hour, and it never loads the box's CPU.
#
# The binary embeds the migrations and the web bundle (embed.FS), so whatever is in
# server/cmd/aul/webdist at build time is what goes live. This script refreshes
# that from web/dist first, so run `npm --prefix web run build` beforehand (or pass
# --build-web to have it done here).
#
# Usage:
#   deploy/push-prebuilt.sh [--build-web]
# Env (override these for your own deployment):
#   BOX=you@your-server.example.com
#   SSH_KEY=~/.ssh/id_ed25519
#   PUBLIC_URL=https://aul.example.com   # for the post-deploy health check
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOX="${BOX:-you@your-server.example.com}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
PUBLIC_URL="${PUBLIC_URL:-https://aul.example.com}"
SSHOPT=(-o StrictHostKeyChecking=accept-new -o ServerAliveInterval=15 -o ConnectTimeout=25 -i "$SSH_KEY")

if [[ "${1:-}" == "--build-web" ]]; then
  echo ">> building web"
  npm --prefix "$REPO/web" run build
fi

echo ">> refreshing embedded web bundle (web/dist -> server/cmd/aul/webdist)"
rm -rf "$REPO/server/cmd/aul/webdist"/*
cp -r "$REPO/web/dist/." "$REPO/server/cmd/aul/webdist/"

echo ">> building static linux/amd64 binary locally"
BIN="$(mktemp -d)/aul"
( cd "$REPO/server" && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath \
    -ldflags "-s -w -X main.version=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo dev)" \
    -o "$BIN" ./cmd/aul )
file "$BIN" | grep -q 'ELF 64-bit.*x86-64' || { echo "!! not a linux/amd64 ELF"; exit 1; }

# Prove the bundle we intend to ship is actually embedded, before we ship it.
WANT="$(basename "$(ls "$REPO"/server/cmd/aul/webdist/assets/index-*.js | head -1)")"
grep -qa "$WANT" "$BIN" || { echo "!! embedded bundle $WANT not found in binary"; exit 1; }
echo "   ok: $(du -h "$BIN" | cut -f1) binary, embeds $WANT"

echo ">> shipping binary + minimal Dockerfile to $BOX"
ssh "${SSHOPT[@]}" "$BOX" 'mkdir -p ~/aul/prebuilt'
scp "${SSHOPT[@]}" "$BIN" "$BOX:~/aul/prebuilt/aul"
ssh "${SSHOPT[@]}" "$BOX" 'cat > ~/aul/prebuilt/Dockerfile' <<'DOCKERFILE'
FROM gcr.io/distroless/static-debian12:nonroot
COPY aul /aul
EXPOSE 8080
USER nonroot:nonroot
ENTRYPOINT ["/aul"]
DOCKERFILE

echo ">> building image on box + recreating container (no host compile)"
ssh "${SSHOPT[@]}" "$BOX" 'set -e
  sudo docker build -t aul-server:local -f ~/aul/prebuilt/Dockerfile ~/aul/prebuilt
  cd ~/aul/deploy && sudo docker compose --profile tls up -d server
  sudo docker compose ps server --format "{{.Name}} {{.State}} {{.Status}}"'

echo ">> verifying live"
sleep 4
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 12 "$PUBLIC_URL/healthz" || true)"
got="$(curl -s --max-time 15 "$PUBLIC_URL/" | grep -oE 'assets/index-[^"]+\.js' | head -1 | xargs -r basename || true)"
echo "   healthz=$code  served=$got  wanted=$WANT"
[[ "$code" == "200" && "$got" == "$WANT" ]] && echo "OK: live serves the new bundle" || { echo "!! mismatch"; exit 1; }
