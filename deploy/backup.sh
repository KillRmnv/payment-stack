#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
. ./lib/env.sh
ensure_vault_token "${1:-stage}"
FILE="../backups/payments-$(date +%Y%m%d-%H%M%S).sql.gz"
mkdir -p ../backups
docker compose exec -T db pg_dump -U payments payments | gzip > "$FILE"
test -s "$FILE" || { echo "backup empty!" >&2; exit 1; }
sha256sum "$FILE" > "$FILE.sha256"
# Retention: держать последние 14 дней, остальное удалять (переопределить через KEEP_DAYS).
KEEP_DAYS="${KEEP_DAYS:-14}"
find ../backups -name 'payments-*.sql.gz' -mtime +"$KEEP_DAYS" -delete || true
find ../backups -name 'payments-*.sha256' -mtime +"$KEEP_DAYS" -delete || true
echo "$FILE ($(du -h "$FILE" | cut -f1))"
