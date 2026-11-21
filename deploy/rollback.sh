#!/usr/bin/env bash
# Manual rollback: code only, schema stays (forward-only migrations).
set -euo pipefail
VERSION="${1:?usage: rollback.sh <version> [env]}"
ENV="${2:-stage}"
cd "$(dirname "$0")"
STATE_FILE="../.deploy-state-$ENV"
HISTORY_FILE="../.deploy-history-$ENV"
. ./lib/env.sh
ensure_vault_token "$ENV"
acquire_deploy_lock "$ENV"
echo "WARNING: schema is NOT rolled back (forward-only). Code -> $VERSION" >&2
echo "WARNING: if migration already applied, old code must be compatible or fix forward with 005_..." >&2
echo "WARNING: only api/worker/outbox/mock-provider are rolled back; nginx/monitoring configs are not." >&2
COMPOSE="docker compose --env-file env/$ENV.env -f docker-compose.yml -f compose.$ENV.yml"
# Образ PREV должен существовать локально (собран прошлым deploy).
# Если его нет (prune/GC) — честно падаем с подсказкой, а не молча поднимаем чужой код.
APP_VERSION="$VERSION"
export APP_VERSION
for image in northwind/payment-api northwind/payment-worker northwind/mock-provider; do
  if ! docker image inspect "$image:$VERSION" >/dev/null 2>&1; then
    echo "FATAL: image $image:$VERSION not found locally." >&2
    echo "HINT: rollback needs the previously built tag. Rebuild from git tag VERSION, or deploy current code." >&2
    exit 1
  fi
done
if worker_supports_outbox "$VERSION"; then
  APP_VERSION="$VERSION" $COMPOSE up -d --wait api worker outbox mock-provider
else
  # Pre-outbox release: stop the new relay and restore the old direct-publish path.
  $COMPOSE stop outbox >/dev/null 2>&1 || true
  APP_VERSION="$VERSION" $COMPOSE up -d --wait api worker mock-provider
fi

# Smoke с fallback как в deploy.sh: хост может не доставать до
# published-портов (VPN/файрвол режет host->bridge) или curl отсутствует.
if [ -f "env/$ENV.env" ]; then set -a; . "env/$ENV.env"; set +a; fi
if [ -n "${SMOKE_NET:-}" ] \
  || ! command -v curl >/dev/null 2>&1 \
  || ! command -v python3 >/dev/null 2>&1 \
  || ! curl -fsS -m 5 "http://localhost:${API_PORT:-8080}/health" >/dev/null 2>&1; then
  echo "host network to proxy unreachable (VPN?), no curl or no python3; using in-network smoke" >&2
  ../scripts/smoke-net.sh "$ENV"
else
  ../scripts/smoke.sh "$ENV"
fi

# A manual rollback is a new "last good" release: without this write the next
# deploy would treat the bad version in .deploy-state as PREV.
echo "$VERSION" > "$STATE_FILE"
printf '%s\trollback\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$VERSION" >> "$HISTORY_FILE"
echo "rollback OK $VERSION"
