#!/usr/bin/env bash
# Restore: verify dump in a temporary DB (default) or apply it to the live DB.
#
# Safety rules:
#   - a .sha256 file is mandatory;
#   - every psql invocation stops on the first SQL error;
#   - the dump is replayed in a transaction, so a broken dump cannot leave the
#     live DB half-restored;
#   - --apply verifies the dump in a temp DB first and takes a safety backup;
#   - if DROP+dump fails, the transaction rolls back and api/worker restart on
#     the previous schema; a migrator failure leaves them stopped for triage.
#
# Usage:
#   ./restore.sh <dump.sql.gz> [--verify-only] [env]
#   ./restore.sh <dump.sql.gz> --apply [env]
set -euo pipefail

FILE="${1:?usage: restore.sh <dump.sql.gz> [--verify-only|--apply] [env]}"
MODE="${2:---verify-only}"
ENV="${3:-stage}"

case "$MODE" in
  --verify-only|--apply) ;;
  *) echo "FATAL: unknown mode '$MODE' (use --verify-only or --apply)" >&2; exit 1 ;;
esac

cd "$(dirname "$0")"
# Accept repo-relative backup paths from the README/Makefile as well as paths
# relative to deploy/ (backup.sh prints ../backups/<env>/...).
case "$FILE" in
  backups/*) FILE="../$FILE" ;;
  ./backups/*) FILE="../${FILE#./}" ;;
esac
[ -f "env/$ENV.env" ] || { echo "FATAL: unknown ENV=$ENV" >&2; exit 1; }
set -a; . "env/$ENV.env"; set +a
. ./lib/env.sh
ensure_vault_token "$ENV"
acquire_deploy_lock "$ENV"
APP_VERSION="${APP_VERSION:-$(../scripts/version.sh)}"
export APP_VERSION
COMPOSE="docker compose --env-file env/$ENV.env -f docker-compose.yml -f compose.$ENV.yml"

die() { echo "FATAL: $*" >&2; exit 1; }

[ -s "$RUNTIME_ENV_FILE" ] || die "missing/empty $RUNTIME_ENV_FILE; run ./vault/render-env.sh $ENV --strict first"

[ -f "$FILE" ] || die "dump not found: $FILE"
[ -f "$FILE.sha256" ] || die "checksum not found: $FILE.sha256 (restore refuses unverified dumps)"

verify_checksum() {
  local dir base
  dir="$(dirname "$FILE")"
  base="$(basename "$FILE")"
  # New format (basename only), verified from the dump's directory.
  if ( cd "$dir" && sha256sum --status -c "$base.sha256" 2>/dev/null ); then
    return 0
  fi
  # Compatibility with checksum files created by older versions of backup.sh
  # (they contain a path relative to deploy/, e.g. ../backups/...).
  if sha256sum --status -c "$FILE.sha256" 2>/dev/null; then
    return 0
  fi
  die "checksum mismatch: $FILE.sha256"
}
verify_checksum

TMPDB=""
cleanup_tmp_db() {
  if [ -n "${TMPDB:-}" ]; then
    $COMPOSE exec -T db psql -v ON_ERROR_STOP=1 -U payments -d postgres \
      -c "DROP DATABASE IF EXISTS \"$TMPDB\";" >/dev/null 2>&1 || true
    TMPDB=""
  fi
}
trap cleanup_tmp_db EXIT

psql_run() {
  local db="$1"; shift
  $COMPOSE exec -T db psql -v ON_ERROR_STOP=1 -U payments -d "$db" "$@"
}

# The DB container may be stopped during an incident; verify/apply both need it.
echo "ensuring db is up..."
$COMPOSE up -d --wait db >/dev/null

verify_into_tmp() {
  TMPDB="restore_verify_$(date +%s)_$$"
  echo "verifying dump in temporary DB $TMPDB..."
  psql_run postgres -c "CREATE DATABASE \"$TMPDB\";" >/dev/null
  # ON_ERROR_STOP is mandatory: psql reading stdin returns 0 after SQL errors,
  # which used to make a partially restored dump look "verified".
  gunzip -c "$FILE" | psql_run "$TMPDB" --single-transaction >/dev/null
  psql_run "$TMPDB" -c \
    "SELECT count(*) AS transfers, count(*) FILTER (WHERE status='PENDING') AS pending FROM transfers;"
  psql_run "$TMPDB" -c "SELECT count(*) AS schema_migrations FROM schema_migrations;"
  cleanup_tmp_db
  echo "restore verified"
}

if [ "$MODE" = "--verify-only" ]; then
  verify_into_tmp
  exit 0
fi

# --apply: verify first, so an invalid dump never reaches the live database.
verify_into_tmp

echo "taking safety backup before --apply..."
./backup.sh "$ENV"

echo "WARNING: restoring dump into LIVE database 'payments' (ENV=$ENV)." >&2
echo "api/worker/outbox will be stopped during restore." >&2
$COMPOSE stop api worker outbox

# DROP + dump are one transaction: on a SQL error PostgreSQL rolls it back and
# the previous tables/data remain intact.
if ! { printf 'DROP TABLE IF EXISTS transfers, schema_migrations CASCADE;\n'; gunzip -c "$FILE"; } \
  | psql_run payments --single-transaction >/dev/null; then
  echo "FATAL: dump apply failed and was rolled back; restarting api/worker on the previous schema." >&2
  $COMPOSE up -d api worker outbox || true
  exit 1
fi
echo "dump applied"

echo "running migrations..."
if ! APP_VERSION="${APP_VERSION:-$(../scripts/version.sh)}" \
  $COMPOSE --profile tools run --rm migrator; then
  echo "FATAL: migrator failed after restore; api/worker remain stopped. Check ./scripts/status.sh $ENV" >&2
  exit 1
fi

if ! $COMPOSE up -d --wait api worker outbox; then
  echo "FATAL: api/worker/outbox did not become ready after restore." >&2
  exit 1
fi

# Same fallback as deploy.sh: host smoke needs curl AND python3.
if [ -n "${SMOKE_NET:-}" ] \
  || ! command -v curl >/dev/null 2>&1 \
  || ! command -v python3 >/dev/null 2>&1 \
  || ! curl -fsS -m 5 "http://localhost:${API_PORT:-8080}/health" >/dev/null 2>&1; then
  ../scripts/smoke-net.sh "$ENV"
else
  ../scripts/smoke.sh "$ENV"
fi
echo "restore --apply OK"
