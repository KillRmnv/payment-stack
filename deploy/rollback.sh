#!/usr/bin/env bash
# Manual rollback: code only, schema stays (forward-only migrations).
set -euo pipefail
VERSION="${1:?usage: rollback.sh <version> [env]}"
ENV="${2:-stage}"
cd "$(dirname "$0")"
echo "WARNING: schema is NOT rolled back (forward-only). Code -> $VERSION" >&2
echo "WARNING: if migration already applied, old code must be compatible or fix forward with 004_..." >&2
COMPOSE="docker compose --env-file env/$ENV.env -f docker-compose.yml -f compose.$ENV.yml"
# Образ PREV должен существовать локально (собран прошлым deploy).
# Если его нет (prune/GC) — честно падаем с подсказкой, а не молча поднимаем чужой код.
if ! docker image inspect "northwind/payment-api:$VERSION" >/dev/null 2>&1 || ! docker image inspect "northwind/payment-worker:$VERSION" >/dev/null 2>&1; then
  echo "FATAL: image northwind/payment-{api,worker}:$VERSION not found locally." >&2
  echo "HINT: rollback needs the previously built tag. Rebuild from git tag VERSION, or deploy current code." >&2
  exit 1
fi
APP_VERSION="$VERSION" $COMPOSE up -d --wait api worker

# Smoke с fallback как в deploy.sh: хост может не доставать до
# published-портов (VPN/файрвол режет host->bridge) или curl отсутствует.
if [ -f "env/$ENV.env" ]; then set -a; . "env/$ENV.env"; set +a; fi
if [ -n "${SMOKE_NET:-}" ] || ! command -v curl >/dev/null 2>&1 || ! curl -fsS -m 5 "http://localhost:${API_PORT:-8080}/health" >/dev/null 2>&1; then
  echo "host network to proxy unreachable (VPN?) or no curl, using in-network smoke" >&2
  ../scripts/smoke-net.sh "$ENV"
else
  ../scripts/smoke.sh "$ENV"
fi
