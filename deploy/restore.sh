#!/usr/bin/env bash
# Restore + verify: restores dump into a temp db and checks transfers table.
set -euo pipefail
FILE="${1:?usage: restore.sh <dump.sql.gz> [--verify-only]}"
cd "$(dirname "$0")"
TMPDB="restore_verify_$(date +%s)"
gunzip -c "$FILE" | docker compose exec -T db psql -U payments -d postgres -c "CREATE DATABASE $TMPDB;" >/dev/null
trap "docker compose exec -T db psql -U payments -d postgres -c 'DROP DATABASE $TMPDB;' >/dev/null" EXIT
gunzip -c "$FILE" | docker compose exec -T db psql -U payments -d "$TMPDB" >/dev/null
docker compose exec -T db psql -U payments -d "$TMPDB" -c "SELECT count(*) FROM transfers;"
echo "restore verified into $TMPDB (dropped on exit)"
