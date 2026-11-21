#!/usr/bin/env bash
# Rotate DB/RabbitMQ passwords without data loss (no `down -v`).
#
# This is a maintenance-window operation: app services are stopped, DB/Rabbit
# passwords are changed, Vault/runtime are updated, then services are started
# on the new secrets. A failed rotation restores the old values from Vault and
# tries to start the services again.
#
# Usage: ./vault/rotate.sh <env>
set -euo pipefail
ENV="${1:?usage: rotate.sh <env>}"
cd "$(dirname "$0")/.."
[ -f "env/$ENV.env" ] || { echo "FATAL: unknown ENV=$ENV" >&2; exit 1; }
set -a; . "env/$ENV.env"; set +a
. ./lib/env.sh
ensure_vault_token "$ENV"
acquire_deploy_lock "$ENV"

APP_VERSION="${APP_VERSION:-$(cat "../.deploy-state-$ENV" 2>/dev/null || true)}"
[ -n "$APP_VERSION" ] || APP_VERSION="$(../scripts/version.sh)"
export APP_VERSION
COMPOSE="docker compose --env-file env/$ENV.env -f docker-compose.yml -f compose.$ENV.yml"

: "${DB_PASSWORD:?set DB_PASSWORD in host env (new value)}"
: "${RABBITMQ_PASSWORD:?set RABBITMQ_PASSWORD in host env (new value)}"
: "${PROVIDER_API_KEY:?set PROVIDER_API_KEY in host env (new or same value)}"
export DB_PASSWORD RABBITMQ_PASSWORD PROVIDER_API_KEY

vault_get() {
  $COMPOSE exec -T vault vault kv get -field="$1" "secret/payment-stack/$ENV" 2>/dev/null || true
}
alter_db_password() {
  # psql -c does not substitute :variables; feed the statement on stdin instead.
  $COMPOSE exec -T db psql -v ON_ERROR_STOP=1 -U payments -d payments \
    -v newpw="$1" >/dev/null <<'SQL'
ALTER USER payments PASSWORD :'newpw';
SQL
}
set_rabbit_password() {
  $COMPOSE exec -T rabbitmq rabbitmqctl change_password payments "$1" >/dev/null
}
put_vault_secret() {
  $COMPOSE exec -T vault vault kv put "secret/payment-stack/$ENV" \
    db_password="$1" rabbitmq_password="$2" provider_api_key="$3" >/dev/null
}
wait_service_healthy() {
  local svc="$1" id status
  for _ in $(seq 1 60); do
    id="$($COMPOSE ps -q "$svc" 2>/dev/null || true)"
    if [ -n "$id" ]; then
      status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$id" 2>/dev/null || true)"
      [ "$status" = "healthy" ] && return 0
    fi
    sleep 2
  done
  echo "FATAL: $svc did not become healthy during rotation" >&2
  return 1
}
start_services() {
  $COMPOSE up -d api worker outbox mock-provider >/dev/null
  for svc in api worker outbox mock-provider; do
    wait_service_healthy "$svc" || return 1
  done
}

OLD_DB="$(vault_get db_password)"
OLD_MQ="$(vault_get rabbitmq_password)"
OLD_PROVIDER="$(vault_get provider_api_key)"
if [ -z "$OLD_DB" ] || [ -z "$OLD_MQ" ] || [ -z "$OLD_PROVIDER" ]; then
  echo "FATAL: current secrets are missing in Vault; seed them before rotating" >&2
  exit 1
fi

STOPPED=0
SUCCESS=0
rollback() {
  local rc=$?
  set +e
  if [ "$STOPPED" = 1 ] && [ "$SUCCESS" != 1 ]; then
    echo "rotation failed; restoring previous secrets from Vault..." >&2
    alter_db_password "$OLD_DB"
    set_rabbit_password "$OLD_MQ"
    put_vault_secret "$OLD_DB" "$OLD_MQ" "$OLD_PROVIDER"
    if ./vault/render-env.sh "$ENV" --strict >/dev/null; then
      start_services
    else
      echo "FATAL: rollback render failed; services left stopped for triage" >&2
    fi
  fi
  exit "$rc"
}
trap rollback EXIT

echo "stopping app services for rotation (maintenance window)..."
STOPPED=1
$COMPOSE stop api worker outbox mock-provider

echo "rotating db password..."
alter_db_password "$DB_PASSWORD"

echo "rotating rabbitmq password..."
set_rabbit_password "$RABBITMQ_PASSWORD"

echo "persisting new secrets to Vault and runtime env..."
./vault/seed.sh "$ENV" --force
./vault/render-env.sh "$ENV" --strict

echo "starting services with new secrets..."
start_services

SUCCESS=1
echo "rotation OK for $ENV"
echo "HINT: keep the new DB_PASSWORD/RABBITMQ_PASSWORD/PROVIDER_API_KEY in your secret store."
