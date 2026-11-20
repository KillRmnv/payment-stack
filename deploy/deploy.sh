#!/usr/bin/env bash
# Idempotent deploy: render secrets -> migrate -> up -> wait -> smoke.
# NEVER runs `down -v` (destroys pgdata/rabbitmq volumes).
set -euo pipefail

ENV="${1:-stage}"
cd "$(dirname "$0")"
COMPOSE="docker compose --env-file env/$ENV.env -f docker-compose.yml -f compose.$ENV.yml"
STATE_FILE="../.deploy-state-$ENV"
TOKEN_FILE="../.vault-token-$ENV"

if [ ! -f "env/$ENV.env" ]; then echo "unknown ENV=$ENV" >&2; exit 1; fi
set -a; . "env/$ENV.env"; set +a

# Vault dev-root token must be STABLE per env: changing it recreates the vault
# container, wiping in-memory secrets (dev mode) and desyncing pgdata passwords.
# Reuse exported value, else a gitignored local file, else generate+save it.
# gen_secret: openssl, иначе python3, иначе /dev/urandom (чистая машина по ТЗ:
# только Docker+Git+make, openssl может отсутствовать).
gen_secret() { openssl rand -hex 16 2>/dev/null || python3 -c 'import secrets;print(secrets.token_hex(16))' 2>/dev/null || head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
if [ -z "${VAULT_DEV_ROOT_TOKEN:-}" ]; then
  if [ -f "$TOKEN_FILE" ]; then
    VAULT_DEV_ROOT_TOKEN="$(cat "$TOKEN_FILE")"
  else
    VAULT_DEV_ROOT_TOKEN="$(gen_secret)"
    echo "$VAULT_DEV_ROOT_TOKEN" > "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE"
    echo "generated $TOKEN_FILE (gitignored, keep it: token change wipes dev Vault)" >&2
  fi
fi
export VAULT_DEV_ROOT_TOKEN

APP_VERSION="${APP_VERSION:-$(git rev-parse --short HEAD 2>/dev/null || echo dev)}"
export APP_VERSION API_PORT LOG_LEVEL
echo "deploy ENV=$ENV APP_VERSION=$APP_VERSION"

touch runtime.env
$COMPOSE up -d --wait vault
./vault/seed.sh "$ENV"
./vault/render-env.sh "$ENV" --strict

echo "migrate..."
$COMPOSE build api worker mock-provider
$COMPOSE --profile tools run --rm migrator

PREV="$(cat "$STATE_FILE" 2>/dev/null || true)"
$COMPOSE up -d --remove-orphans --wait

# Fail fast on pgdata/password desync (persistent volume vs fresh secrets):
# if the DB data dir was initialized with other passwords, api auth fails and
# smoke would misleadingly blame the code. Detect here with a clear hint.
echo "db-auth-check..."
if ! $COMPOSE exec -T api python3 -c "import sys; sys.path.insert(0,'/app'); from app.config import load_settings; import psycopg; psycopg.connect(load_settings().dsn, connect_timeout=5).close()" 2>/dev/null; then
  echo "FATAL: api cannot auth to db with current runtime.env." >&2
  echo "HINT: pgdata was initialized with different passwords. Either restore the old secrets" >&2
  echo "      (seed --force with previous values + render) or reset data (manual down -v, DATA LOSS)." >&2
  exit 1
fi

# Host may not reach published ports (VPN/firewall): prefer in-network smoke,
# fall back to host smoke. Never fail silently — one of them must pass.
# Чистая машина по ТЗ: curl может отсутствовать — тогда сразу in-network.
run_smoke() {
  if [ -n "${SMOKE_NET:-}" ] || ! command -v curl >/dev/null 2>&1 || ! curl -fsS -m 5 "http://localhost:${API_PORT:-8080}/health" >/dev/null 2>&1; then
    echo "host network to proxy unreachable (VPN?) or no curl, using in-network smoke" >&2
    ../scripts/smoke-net.sh "$ENV"
  else
    ../scripts/smoke.sh "$ENV"
  fi
}

if run_smoke; then
  echo "$APP_VERSION" > "$STATE_FILE"
  echo "deploy OK $APP_VERSION"
else
  echo "smoke FAILED, auto-rollback (code only, schema stays)..." >&2
  if [ -n "$PREV" ] && [ "$PREV" != "$APP_VERSION" ]; then
    APP_VERSION="$PREV" $COMPOSE up -d --wait api worker
    run_smoke
  fi
  exit 1
fi
