#!/usr/bin/env bash
# Render runtime.env from Vault. Fail-fast: missing secret = hard error.
set -euo pipefail
ENV="${1:?usage: render-env.sh <env> [--strict]}"
cd "$(dirname "$0")/.."

get() {
  docker compose exec -T vault vault kv get -field="$1" "secret/payment-stack/$ENV" 2>/dev/null || true
}

DB_PASSWORD_VAULT="$(get db_password)"
MQ_PASSWORD_VAULT="$(get rabbitmq_password)"
PROVIDER_KEY_VAULT="$(get provider_api_key)"

missing=()
[ -n "$DB_PASSWORD_VAULT" ] || missing+=("db_password@$ENV")
[ -n "$MQ_PASSWORD_VAULT" ] || missing+=("rabbitmq_password@$ENV")
[ -n "$PROVIDER_KEY_VAULT" ] || missing+=("provider_api_key@$ENV")
if [ "${#missing[@]}" -ne 0 ]; then
  echo "FATAL: missing secrets in Vault: ${missing[*]}" >&2
  echo "HINT: export DB_PASSWORD/RABBITMQ_PASSWORD/PROVIDER_API_KEY and run ./vault/seed.sh $ENV" >&2
  exit 1
fi

cat > runtime.env <<EOT
POSTGRES_PASSWORD=${DB_PASSWORD_VAULT}
RABBITMQ_DEFAULT_PASS=${MQ_PASSWORD_VAULT}
PROVIDER_API_KEY=${PROVIDER_KEY_VAULT}
EOT
echo "rendered runtime.env for $ENV"
