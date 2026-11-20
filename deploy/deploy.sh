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

if ../scripts/smoke.sh "$ENV"; then
  echo "$APP_VERSION" > "$STATE_FILE"
  echo "deploy OK $APP_VERSION"
else
  echo "smoke FAILED, auto-rollback..." >&2
  if [ -n "$PREV" ] && [ "$PREV" != "$APP_VERSION" ]; then
    APP_VERSION="$PREV" $COMPOSE up -d --wait api worker
  fi
  exit 1
fi

for s in api worker mock-provider; do $COMPOSE ps "$s"; done
