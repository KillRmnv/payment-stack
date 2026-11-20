#!/usr/bin/env bash
# Restore: verify dump in temp DB (default) or apply to production.
# Usage:
#   ./restore.sh <dump.sql.gz> [--verify-only]   # default: verify only
#   ./restore.sh <dump.sql.gz> --apply [env]     # stop api/worker, restore payments, migrate, smoke
set -euo pipefail
FILE="${1:?usage: restore.sh <dump.sql.gz> [--verify-only|--apply] [env]}"
MODE="${2:---verify-only}"
cd "$(dirname "$0")"
[ -f "$FILE" ] || { echo "dump not found: $FILE" >&2; exit 1; }
if [ -f "$FILE.sha256" ]; then sha256sum -c "$FILE.sha256" || exit 1; fi

verify_into_tmp() {
  TMPDB="restore_verify_$(date +%s)"
  gunzip -c "$FILE" | docker compose exec -T db psql -U payments -d postgres -c "CREATE DATABASE $TMPDB;" >/dev/null
  trap "docker compose exec -T db psql -U payments -d postgres -c 'DROP DATABASE $TMPDB;' >/dev/null" EXIT
  gunzip -c "$FILE" | docker compose exec -T db psql -U payments -d "$TMPDB" >/dev/null
  docker compose exec -T db psql -U payments -d "$TMPDB" -c "SELECT count(*) AS transfers, count(*) FILTER (WHERE status='PENDING') AS pending FROM transfers;"
  docker compose exec -T db psql -U payments -d "$TMPDB" -c "SELECT count(*) FROM schema_migrations;"
  echo "restore verified into $TMPDB (dropped on exit)"
}

if [ "$MODE" = "--verify-only" ]; then
  verify_into_tmp
  exit 0
fi

if [ "$MODE" = "--apply" ]; then
  ENV="${3:-stage}"
  COMPOSE="docker compose --env-file env/$ENV.env -f docker-compose.yml -f compose.$ENV.yml"
  echo "WARNING: restoring dump into LIVE database 'payments' (ENV=$ENV)." >&2
  echo "api/worker will be stopped during restore." >&2
  $COMPOSE stop api worker
  # shellcheck disable=SC2094
  gunzip -c "$FILE" | $COMPOSE exec -T db psql -U payments -d payments >/dev/null
  echo "dump applied, running migrations..."
  APP_VERSION="${APP_VERSION:-$(git rev-parse --short HEAD 2>/dev/null || echo dev)}" \
    $COMPOSE --profile tools run --rm migrator
  $COMPOSE up -d --wait api worker
  ../scripts/smoke-net.sh "$ENV" || ../scripts/smoke.sh "$ENV"
  echo "restore --apply OK"
  exit 0
fi

echo "unknown mode $MODE (use --verify-only or --apply)" >&2
exit 1
