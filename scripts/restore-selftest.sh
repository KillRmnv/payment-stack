#!/usr/bin/env bash
# Regression test for restore.sh: a valid dump verifies, while a dump with a
# SQL error in the middle MUST fail (psql reads stdin, so ON_ERROR_STOP is the
# only thing that prevents a false-positive "verified" result).
set -euo pipefail

ENV="${1:-stage}"
cd "$(dirname "$0")/../deploy"
[ -f "env/$ENV.env" ] || { echo "FATAL: unknown ENV=$ENV" >&2; exit 1; }
set -a; . "env/$ENV.env"; set +a
. ./lib/env.sh
ensure_vault_token "$ENV"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

valid_sql="$TMP/valid.sql"
cat > "$valid_sql" <<'SQL'
CREATE TABLE schema_migrations (version TEXT PRIMARY KEY);
CREATE TABLE transfers (id UUID PRIMARY KEY, status TEXT NOT NULL);
INSERT INTO schema_migrations (version) VALUES ('001_create_transfers.sql');
INSERT INTO transfers (id, status) VALUES ('11111111-1111-1111-1111-111111111111', 'PENDING');
SQL

gzip -c "$valid_sql" > "$TMP/valid.sql.gz"
( cd "$TMP" && sha256sum valid.sql.gz > valid.sql.gz.sha256 )

echo "1) valid dump must verify"
./restore.sh "$TMP/valid.sql.gz" --verify-only "$ENV" >/dev/null

echo "2) dump with a SQL error must NOT verify"
cp "$valid_sql" "$TMP/broken.sql"
printf 'INSERT INTO no_such_table VALUES (1);\n' >> "$TMP/broken.sql"
gzip -c "$TMP/broken.sql" > "$TMP/broken.sql.gz"
( cd "$TMP" && sha256sum broken.sql.gz > broken.sql.gz.sha256 )
if ./restore.sh "$TMP/broken.sql.gz" --verify-only "$ENV" >/dev/null 2>&1; then
  echo "FATAL: restore verified a dump with a SQL error" >&2
  exit 1
fi

echo "3) dump without .sha256 must be rejected"
cp "$TMP/valid.sql.gz" "$TMP/nosum.sql.gz"
if ./restore.sh "$TMP/nosum.sql.gz" --verify-only "$ENV" >/dev/null 2>&1; then
  echo "FATAL: restore accepted a dump without checksum" >&2
  exit 1
fi

echo "4) empty pre-migration dump must verify"
: > "$TMP/empty.sql"
gzip -c "$TMP/empty.sql" > "$TMP/empty.sql.gz"
( cd "$TMP" && sha256sum empty.sql.gz > empty.sql.gz.sha256 )
./restore.sh "$TMP/empty.sql.gz" --verify-only "$ENV" >/dev/null

echo "restore selftest OK"
