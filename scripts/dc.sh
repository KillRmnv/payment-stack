#!/usr/bin/env bash
# Docker Compose wrapper that loads the Vault token and per-env project.
# Prevents RUNBOOK commands like `docker compose logs outbox` from failing with
# "required variable VAULT_DEV_ROOT_TOKEN is missing".
#
# Usage: ./scripts/dc.sh <stage|prod> <compose args...>
#   ./scripts/dc.sh stage logs outbox
#   ./scripts/dc.sh stage exec -T db psql -U payments -d payments -c 'select 1'
set -euo pipefail

ENV="${1:?usage: dc.sh <env> <compose args...>}"
shift
cd "$(dirname "$0")/../deploy"
[ -f "env/$ENV.env" ] || { echo "FATAL: unknown ENV=$ENV" >&2; exit 1; }
. ./lib/env.sh
ensure_vault_token "$ENV"
APP_VERSION="${APP_VERSION:-$(cat "../.deploy-state-$ENV" 2>/dev/null || true)}"
[ -n "$APP_VERSION" ] || APP_VERSION="$(../scripts/version.sh)"
export APP_VERSION
exec docker compose --env-file "env/$ENV.env" -f docker-compose.yml -f "compose.$ENV.yml" "$@"
