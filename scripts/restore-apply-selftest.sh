#!/usr/bin/env bash
# Regression test for restore.sh --apply against a temporary database.
#
# It catches the class of bug where --apply drops only a hardcoded list of
# tables: a current-schema dump contains transfer_outbox, and the old table was
# left in place, so CREATE TABLE transfer_outbox failed.
#
# The target database is disposable; the live `payments` database and running
# services are not touched (RESTORE_TARGET_DB is the internal test hook).
set -euo pipefail

ENV="${1:-stage}"
cd "$(dirname "$0")/../deploy"
[ -f "env/$ENV.env" ] || { echo "FATAL: unknown ENV=$ENV" >&2; exit 1; }
set -a; . "env/$ENV.env"; set +a
. ./lib/env.sh
ensure_vault_token "$ENV"

APP_VERSION="${APP_VERSION:-$(../scripts/version.sh)}"
export APP_VERSION
COMPOSE="docker compose --env-file env/$ENV.env -f docker-compose.yml -f compose.$ENV.yml"
TARGET="restore_apply_test_$(date +%s)_$$"
TMP="$(mktemp -d)"

psql_admin() {
  $COMPOSE exec -T db psql -v ON_ERROR_STOP=1 -U payments -d postgres "$@"
}
psql_target() {
  $COMPOSE exec -T db psql -v ON_ERROR_STOP=1 -U payments -d "$TARGET" "$@"
}
dump_target() {
  local name="$1"
  $COMPOSE exec -T db pg_dump -U payments "$TARGET" | gzip > "$TMP/$name.sql.gz"
  ( cd "$TMP" && sha256sum "$name.sql.gz" > "$name.sql.gz.sha256" )
}
apply_target() {
  local dump="$1"
  RESTORE_TARGET_DB="$TARGET" ./restore.sh "$dump" --apply "$ENV" >/dev/null
}
assert_eq() {
  local got="$1" want="$2" what="$3"
  [ "$got" = "$want" ] || { echo "FATAL: $what: got '$got', want '$want'" >&2; exit 1; }
}

cleanup() {
  set +e
  psql_admin -c "DROP DATABASE IF EXISTS \"$TARGET\";" >/dev/null 2>&1
  rm -rf "$TMP"
}
trap cleanup EXIT

echo "ensuring db is up..."
$COMPOSE up -d --wait db >/dev/null
psql_admin -c "DROP DATABASE IF EXISTS \"$TARGET\";" >/dev/null
psql_admin -c "CREATE DATABASE \"$TARGET\";" >/dev/null

echo "1) current-schema dump (with transfer_outbox) must apply"
psql_target >/dev/null <<'SQL'
CREATE TABLE schema_migrations (version TEXT PRIMARY KEY, checksum TEXT);
INSERT INTO schema_migrations (version, checksum) VALUES ('001_create_transfers.sql', 'x');
CREATE TABLE transfers (id UUID PRIMARY KEY, amount_minor BIGINT NOT NULL, status TEXT NOT NULL);
CREATE TABLE transfer_outbox (
    id UUID PRIMARY KEY,
    transfer_id UUID NOT NULL UNIQUE REFERENCES transfers(id),
    payload JSONB NOT NULL,
    status TEXT NOT NULL DEFAULT 'PENDING'
);
INSERT INTO transfers (id, amount_minor, status)
VALUES ('11111111-1111-1111-1111-111111111111', 100, 'PENDING');
INSERT INTO transfer_outbox (id, transfer_id, payload)
VALUES ('22222222-2222-2222-2222-222222222222',
        '11111111-1111-1111-1111-111111111111', '{}');
SQL
dump_target current
apply_target "$TMP/current.sql.gz"
assert_eq "$(psql_target -tAc 'SELECT count(*) FROM transfers')" 1 "current dump: transfers"
assert_eq "$(psql_target -tAc 'SELECT count(*) FROM transfer_outbox')" 1 "current dump: outbox"
echo "current-schema apply OK"

echo "2) pre-004 dump must apply, then 004 must create transfer_outbox"
psql_target -c "DROP TABLE IF EXISTS transfer_outbox, transfers, schema_migrations CASCADE;" >/dev/null
psql_target >/dev/null <<'SQL'
CREATE TABLE schema_migrations (version TEXT PRIMARY KEY, checksum TEXT);
INSERT INTO schema_migrations (version, checksum) VALUES ('003_add_amount_minor.sql', 'y');
CREATE TABLE transfers (id UUID PRIMARY KEY, amount_minor BIGINT NOT NULL, status TEXT NOT NULL);
INSERT INTO transfers (id, amount_minor, status)
VALUES ('33333333-3333-3333-3333-333333333333', 250, 'PENDING');
SQL
dump_target pre004
apply_target "$TMP/pre004.sql.gz"
assert_eq "$(psql_target -tAc "SELECT COALESCE(to_regclass('public.transfer_outbox')::text, '')")" "" \
  "pre-004 apply must not create outbox before migrator"
$COMPOSE exec -T db psql -v ON_ERROR_STOP=1 -U payments -d "$TARGET" \
  < ../migrations/004_outbox_idempotency.sql >/dev/null
assert_eq "$(psql_target -tAc "SELECT COALESCE(to_regclass('public.transfer_outbox')::text, '')")" \
  "transfer_outbox" "004 must create transfer_outbox"
assert_eq "$(psql_target -tAc 'SELECT count(*) FROM transfer_outbox')" 1 \
  "004 must backfill PENDING transfers"
echo "pre-004 apply + 004 OK"

echo "3) broken dump must not touch the target database"
gunzip -c "$TMP/pre004.sql.gz" > "$TMP/broken.sql"
printf 'INSERT INTO no_such_table VALUES (1);\n' >> "$TMP/broken.sql"
gzip -c "$TMP/broken.sql" > "$TMP/broken.sql.gz"
( cd "$TMP" && sha256sum broken.sql.gz > broken.sql.gz.sha256 )
BEFORE="$(psql_target -tAc 'SELECT count(*) FROM transfers')"
if RESTORE_TARGET_DB="$TARGET" ./restore.sh "$TMP/broken.sql.gz" --apply "$ENV" >/dev/null 2>&1; then
  echo "FATAL: restore applied a dump with a SQL error" >&2
  exit 1
fi
AFTER="$(psql_target -tAc 'SELECT count(*) FROM transfers')"
assert_eq "$AFTER" "$BEFORE" "broken dump changed the target database"
echo "broken dump left the target intact"

echo "restore apply selftest OK"
