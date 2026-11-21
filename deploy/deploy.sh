#!/usr/bin/env bash
# Idempotent deploy: render secrets -> migrate -> up -> wait -> smoke.
# NEVER runs `down -v` (destroys pgdata/rabbitmq volumes).
set -euo pipefail

ENV="${1:-stage}"
cd "$(dirname "$0")"
COMPOSE="docker compose --env-file env/$ENV.env -f docker-compose.yml -f compose.$ENV.yml"
STATE_FILE="../.deploy-state-$ENV"
HISTORY_FILE="../.deploy-history-$ENV"
REPO_ROOT="$(cd .. && pwd)"

if [ ! -f "env/$ENV.env" ]; then echo "unknown ENV=$ENV" >&2; exit 1; fi
set -a; . "env/$ENV.env"; set +a

# Vault dev-root token стабилен на env: смена токена пересоздает Vault и
# стирает in-memory секреты. env -> .vault-token-<env> -> generate.
# ensure_vault_token also pins COMPOSE_PROJECT_NAME/RUNTIME_ENV_FILE.
. ./lib/env.sh
ensure_vault_token "$ENV"
acquire_deploy_lock "$ENV"

APP_VERSION="${APP_VERSION:-$(../scripts/version.sh)}"
export APP_VERSION API_PORT LOG_LEVEL
echo "deploy ENV=$ENV project=$COMPOSE_PROJECT_NAME version=$APP_VERSION"

# Building from a dirty tree records a version that does not identify the code.
if [ "${ALLOW_DIRTY:-0}" != "1" ] && [ -e "$REPO_ROOT/.git" ] \
  && [ -n "$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null)" ]; then
  echo "FATAL: working tree is dirty; commit changes or set ALLOW_DIRTY=1" >&2
  exit 1
fi

# Deployment history is append-only and independent from the single "last good"
# state file: it keeps enough information to choose a manual rollback target.
record_release() {
  local version="$1" kind="$2" ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  {
    printf '%s\t%s\t%s' "$ts" "$kind" "$version"
    for image in northwind/payment-api northwind/payment-worker northwind/mock-provider; do
      printf '\t%s' "$(docker image inspect "$image:$version" --format '{{.Id}}' 2>/dev/null || echo missing)"
    done
    printf '\n'
  } >> "$HISTORY_FILE"
}

service_healthy() {
  local service="$1" id status
  id="$($COMPOSE ps -q "$service" 2>/dev/null || true)"
  [ -n "$id" ] || return 1
  status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$id" 2>/dev/null)" || return 1
  [ "$status" = "healthy" ] || [ "$status" = "running" ]
}

infra_healthy() {
  service_healthy db && service_healthy rabbitmq
}

# Host may not reach published ports (VPN/firewall): prefer in-network smoke,
# fall back to host smoke. Never fail silently — one of them must pass.
# Чистая машина по ТЗ: host smoke requires both curl and python3; without either
# use the in-network smoke (python lives inside the worker image).
run_smoke() {
  if [ -n "${SMOKE_NET:-}" ] \
    || ! command -v curl >/dev/null 2>&1 \
    || ! command -v python3 >/dev/null 2>&1 \
    || ! curl -fsS -m 5 "http://localhost:${API_PORT:-8080}/health" >/dev/null 2>&1; then
    echo "host network to proxy unreachable (VPN?), no curl or no python3; using in-network smoke" >&2
    ../scripts/smoke-net.sh "$ENV"
  else
    ../scripts/smoke.sh "$ENV"
  fi
}

rollback_release() {
  local target="$1" kind="$2" image
  if [ -z "$target" ] || [ "$target" = "$APP_VERSION" ]; then
    echo "FATAL: no previous release to roll back to (state='$target')" >&2
    return 1
  fi
  for image in northwind/payment-api northwind/payment-worker northwind/mock-provider; do
    if ! docker image inspect "$image:$target" >/dev/null 2>&1; then
      echo "FATAL: image $image:$target not found locally; cannot roll back." >&2
      return 1
    fi
  done
  echo "rolling back to $target ($kind)..." >&2
  if worker_supports_outbox "$target"; then
    if ! APP_VERSION="$target" $COMPOSE up -d --wait api worker outbox mock-provider; then
      echo "FATAL: rollback readiness failed for $target" >&2
      return 1
    fi
  else
    # Rolling back to a pre-outbox release: keep the old direct-publish path.
    $COMPOSE stop outbox >/dev/null 2>&1 || true
    if ! APP_VERSION="$target" $COMPOSE up -d --wait api worker mock-provider; then
      echo "FATAL: rollback readiness failed for $target" >&2
      return 1
    fi
  fi
  if ! run_smoke; then
    echo "FATAL: smoke failed after rollback to $target" >&2
    return 1
  fi
  echo "$target" > "$STATE_FILE"
  record_release "$target" "$kind"
  echo "rollback OK $target" >&2
}

touch "$RUNTIME_ENV_FILE"
$COMPOSE up -d --wait vault
./vault/seed.sh "$ENV"
./vault/render-env.sh "$ENV" --strict

echo "build..."
$COMPOSE build api worker mock-provider

# Start DB explicitly and fail fast on pgdata/password desync before migrator
# or api/worker are touched. A one-off container with the new runtime env checks
# DB auth; this used to be unreachable behind `up --wait`/migrator failures.
$COMPOSE up -d --wait db
echo "db-auth-check..."
if ! $COMPOSE run --rm -T --no-deps api python3 -c \
  "import sys; sys.path.insert(0,'/app'); from app.config import load_settings; import psycopg; psycopg.connect(load_settings().dsn, connect_timeout=5).close()" \
  >/dev/null 2>&1; then
  echo "FATAL: api cannot auth to db with current $RUNTIME_ENV_FILE." >&2
  echo "HINT: pgdata was initialized with different passwords. Either restore the old secrets" >&2
  echo "      (seed --force with previous values + render) or reset data (manual down -v, DATA LOSS)." >&2
  exit 1
fi

echo "pre-migration backup..."
./backup.sh "$ENV"

echo "migrate..."
$COMPOSE --profile tools run --rm migrator

PREV="$(cat "$STATE_FILE" 2>/dev/null || true)"
if ! $COMPOSE up -d --remove-orphans --wait; then
  echo "up --wait FAILED" >&2
  if infra_healthy; then
    rollback_release "$PREV" failed-readiness || true
  else
    echo "WARN: db/rabbitmq is unhealthy; not rolling back code" >&2
  fi
  exit 1
fi

# nginx.conf/monitoring — bind-mount; `up` их не перечитывает. Graceful reload,
# чтобы правки edge/алертов применялись при деплое (битый конфиг -> старый жив).
if $COMPOSE exec -T reverse-proxy nginx -t >/dev/null 2>&1; then
  $COMPOSE exec -T reverse-proxy nginx -s reload >/dev/null 2>&1 && echo "nginx reloaded"
else
  echo "WARN: nginx config invalid, keeping previous config" >&2
fi
$COMPOSE exec -T api python3 -c "import urllib.request; urllib.request.urlopen(urllib.request.Request('http://prometheus:9090/-/reload', method='POST'), timeout=5)" >/dev/null 2>&1 \
  && echo "prometheus rules reloaded" || echo "WARN: prometheus reload skipped"
$COMPOSE exec -T api python3 -c "import urllib.request; urllib.request.urlopen(urllib.request.Request('http://alertmanager:9093/-/reload', method='POST'), timeout=5)" >/dev/null 2>&1 \
  && echo "alertmanager config reloaded" || echo "WARN: alertmanager reload skipped"

if run_smoke; then
  echo "$APP_VERSION" > "$STATE_FILE"
  record_release "$APP_VERSION" deploy
  echo "deploy OK $APP_VERSION"
else
  echo "smoke FAILED, code rollback requested (schema stays)..." >&2
  if infra_healthy; then
    rollback_release "$PREV" auto-rollback || true
  else
    echo "WARN: db/rabbitmq is unhealthy; not rolling back code" >&2
  fi
  exit 1
fi
