#!/usr/bin/env bash
# Idempotent deploy: render secrets -> migrate -> up -> wait -> smoke.
# NEVER runs `down -v` (destroys pgdata/rabbitmq volumes).
set -euo pipefail

ENV="${1:-stage}"
cd "$(dirname "$0")"
COMPOSE="docker compose --env-file env/$ENV.env -f docker-compose.yml -f compose.$ENV.yml"
STATE_FILE="../.deploy-state-$ENV"

if [ ! -f "env/$ENV.env" ]; then echo "unknown ENV=$ENV" >&2; exit 1; fi
set -a; . "env/$ENV.env"; set +a

# Vault dev-root token стабилен на env: смена токена пересоздает Vault и
# стирает in-memory секреты. env -> .vault-token-<env> -> generate.
. ./lib/env.sh
ensure_vault_token "$ENV"

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

# nginx.conf/monitoring — bind-mount; `up` их не перечитывает. Graceful reload,
# чтобы правки edge/алертов применялись при деплое (битый конфиг -> старый жив).
if $COMPOSE exec -T reverse-proxy nginx -t >/dev/null 2>&1; then
  $COMPOSE exec -T reverse-proxy nginx -s reload >/dev/null 2>&1 && echo "nginx reloaded"
else
  echo "WARN: nginx config invalid, keeping previous config" >&2
fi
$COMPOSE exec -T api python3 -c "import urllib.request; urllib.request.urlopen(urllib.request.Request('http://prometheus:9090/-/reload', method='POST'), timeout=5)" >/dev/null 2>&1 \
  && echo "prometheus rules reloaded" || echo "WARN: prometheus reload skipped"

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
    if docker image inspect "northwind/payment-api:$PREV" >/dev/null 2>&1 && docker image inspect "northwind/payment-worker:$PREV" >/dev/null 2>&1; then
      APP_VERSION="$PREV" $COMPOSE up -d --wait api worker
      run_smoke
    else
      echo "FATAL: PREV image northwind/payment-{api,worker}:$PREV not found locally, cannot auto-rollback. Old code tag was pruned." >&2
      exit 1
    fi
  fi
  exit 1
fi
