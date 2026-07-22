#!/usr/bin/env sh
# Aul database backup — pg_dump to a rotated, gzipped file.
#
# The data is ciphertext by design (the server cannot read locations), so a
# backup is not a privacy risk the way a plaintext location dump would be — but
# it IS the only thing standing between a lost VM and every account and circle
# vanishing. A free host can disappear with its disk; treat backups as mandatory,
# not optional. (This exists because a dev database was once wiped irrecoverably.)
#
# Usage:
#   deploy/backup.sh                 # writes to deploy/backups/
#   BACKUP_DIR=/mnt/x deploy/backup.sh
#   KEEP=30 deploy/backup.sh         # keep the newest 30 (default 14)
#
# Cron (daily 03:30, log to syslog):
#   30 3 * * * cd /path/to/aul && deploy/backup.sh >> deploy/backups/backup.log 2>&1
#
# RESTORE into a fresh stack:
#   gunzip -c deploy/backups/aul-YYYY-MM-DD-HHMMSS.sql.gz \
#     | docker compose -f deploy/docker-compose.yml exec -T db psql -U aul -d aul

set -eu

COMPOSE="docker compose -f $(dirname "$0")/docker-compose.yml"
BACKUP_DIR="${BACKUP_DIR:-$(dirname "$0")/backups}"
KEEP="${KEEP:-14}"
DB_USER="${POSTGRES_USER:-aul}"
DB_NAME="${POSTGRES_DB:-aul}"

mkdir -p "$BACKUP_DIR"
# No Date.now() literacy needed — the shell has the clock the app isolates lack.
stamp=$(date +%Y-%m-%d-%H%M%S)
out="$BACKUP_DIR/aul-$stamp.sql.gz"
tmp="$out.partial"

# --clean --if-exists so the dump restores over an existing schema cleanly.
# Stream straight through gzip; never land a plaintext .sql on disk in between.
if $COMPOSE exec -T db pg_dump -U "$DB_USER" -d "$DB_NAME" --clean --if-exists \
  | gzip -9 > "$tmp"; then
  mv "$tmp" "$out"          # atomic: a half-written dump never wears a real name
  echo "$(date -Iseconds) backup ok: $out ($(wc -c < "$out") bytes)"
else
  rm -f "$tmp"
  echo "$(date -Iseconds) backup FAILED" >&2
  exit 1
fi

# Rotate: keep the newest $KEEP, delete the rest. Newline-safe (our names have none).
count=$(ls -1 "$BACKUP_DIR"/aul-*.sql.gz 2>/dev/null | wc -l)
if [ "$count" -gt "$KEEP" ]; then
  ls -1t "$BACKUP_DIR"/aul-*.sql.gz | tail -n "+$((KEEP + 1))" | while IFS= read -r old; do
    rm -f "$old" && echo "$(date -Iseconds) pruned $old"
  done
fi
