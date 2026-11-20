#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
FILE="../backups/payments-$(date +%Y%m%d-%H%M%S).sql.gz"
mkdir -p ../backups
docker compose exec -T db pg_dump -U payments payments | gzip > "$FILE"
test -s "$FILE" || { echo "backup empty!" >&2; exit 1; }
echo "$FILE ($(du -h "$FILE" | cut -f1))"
