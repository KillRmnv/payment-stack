#!/usr/bin/env bash
# Rotate DB/RabbitMQ passwords without data loss (no `down -v`).
# Usage: ./vault/rotate.sh <env>
# Reads new passwords from host env, applies them to live services,
# then seeds Vault and re-renders runtime.env.
set -euo pipefail
ENV="${1:?usage: rotate.sh <env>}"
cd "$(dirname "$0")/.."

: "${DB_PASSWORD:?set DB_PASSWORD in host env (new value)}"
: "${RABBITMQ_PASSWORD:?set RABBITMQ_PASSWORD in host env (new value)}"
: "${PROVIDER_API_KEY:?set PROVIDER_API_KEY in host env (new or same value)}"

echo "rotate passwords for $ENV (no data loss)..."
# 1. Apply to live DB (needs current working password from runtime.env).
set -a; [ -f runtime.env ] && . runtime.env; set +a
docker compose exec -T db psql -U payments -d payments \
  -c "ALTER USER payments PASSWORD '$DB_PASSWORD';"
echo "db password rotated"

# 2. Apply to live RabbitMQ.
docker compose exec -T rabbitmq rabbitmqctl change_password payments "$RABBITMQ_PASSWORD"
echo "rabbitmq password rotated"

# 3. Persist to Vault + re-render.
./vault/seed.sh "$ENV" --force
./vault/render-env.sh "$ENV" --strict

echo "HINT: run 'make deploy ENV=$ENV' to roll services with new secrets."
