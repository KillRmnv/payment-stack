#!/usr/bin/env bash
set -euo pipefail

ENV="${1:?usage: seed.sh <env> [--force]}"
FORCE="${2:-}"
cd "$(dirname "$0")/.."
. ./lib/env.sh
ensure_vault_token "$ENV"

if [ "$FORCE" != "--force" ] && docker compose exec -T vault vault kv get "secret/payment-stack/$ENV" >/dev/null 2>&1; then
  echo "secret/payment-stack/$ENV exists, skip (use --force to rotate)" >&2
  exit 0
fi

: "${DB_PASSWORD:?set DB_PASSWORD in host env (never commit it)}"
: "${RABBITMQ_PASSWORD:?set RABBITMQ_PASSWORD in host env}"
: "${PROVIDER_API_KEY:?set PROVIDER_API_KEY in host env}"

docker compose exec -T vault vault kv put "secret/payment-stack/$ENV" \
  db_password="$DB_PASSWORD" \
  rabbitmq_password="$RABBITMQ_PASSWORD" \
  provider_api_key="$PROVIDER_API_KEY" >/dev/null
echo "seeded secret/payment-stack/$ENV"
