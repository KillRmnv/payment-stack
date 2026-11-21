#!/usr/bin/env bash
set -euo pipefail
umask 077

ENV="${1:-stage}"
cd "$(dirname "$0")"
. ./lib/env.sh
ensure_vault_token "$ENV"
DIR="../backups/$ENV"
FILE="$DIR/payments-$(date +%Y%m%d-%H%M%S)-$$.sql.gz"
TMP="$FILE.partial.$$"
mkdir -p "$DIR"
chmod 700 "$DIR" 2>/dev/null || true
trap 'rm -f "$TMP"' EXIT
docker compose exec -T db pg_dump -U payments payments | gzip > "$TMP"
test -s "$TMP" || { echo "backup empty!" >&2; exit 1; }
mv "$TMP" "$FILE"
trap - EXIT
# Checksum contains only the basename: restore.sh verifies it from the dump's
# directory regardless of whether the caller passed a relative or absolute path.
( cd "$DIR" && sha256sum "$(basename "$FILE")" > "$(basename "$FILE").sha256" )
# Export timestamp/size for Prometheus (read by the outbox container; no PII).
METRICS_DIR="../.metrics"
mkdir -p "$METRICS_DIR" 2>/dev/null || true
chmod 755 "$METRICS_DIR" 2>/dev/null || true
METRICS_FILE="$METRICS_DIR/backup-$ENV.prom"
{
  printf '# HELP backup_last_success_timestamp_seconds Unix time of the last successful backup\n'
  printf '# TYPE backup_last_success_timestamp_seconds gauge\n'
  printf 'backup_last_success_timestamp_seconds %s\n' "$(date +%s)"
  printf '# HELP backup_last_size_bytes Size of the last backup archive\n'
  printf '# TYPE backup_last_size_bytes gauge\n'
  printf 'backup_last_size_bytes %s\n' "$(stat -c%s "$FILE")"
} > "$METRICS_FILE.tmp" 2>/dev/null || true
chmod 644 "$METRICS_FILE.tmp" 2>/dev/null || true
mv "$METRICS_FILE.tmp" "$METRICS_FILE" 2>/dev/null || true
# Retention: держать последние 14 дней, остальное удалять (переопределить через KEEP_DAYS).
KEEP_DAYS="${KEEP_DAYS:-14}"
find "$DIR" -name 'payments-*.sql.gz' -mtime +"$KEEP_DAYS" -delete || true
find "$DIR" -name 'payments-*.sha256' -mtime +"$KEEP_DAYS" -delete || true
echo "$FILE ($(du -h "$FILE" | cut -f1))"
