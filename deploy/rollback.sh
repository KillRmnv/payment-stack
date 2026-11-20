#!/usr/bin/env bash
# Manual rollback: code only, schema stays (forward-only migrations).
set -euo pipefail
VERSION="${1:?usage: rollback.sh <version> [env]}"
ENV="${2:-stage}"
cd "$(dirname "$0")"
echo "WARNING: schema is NOT rolled back (forward-only). Code -> $VERSION" >&2
echo "WARNING: if migration already applied, old code must be compatible or fix forward with 004_..." >&2
APP_VERSION="$VERSION" docker compose --env-file "env/$ENV.env" -f docker-compose.yml -f "compose.$ENV.yml" up -d --wait api worker

# Smoke с fallback как в deploy.sh: хост может не доставать до
# published-портов (VPN/файрвол режет host->bridge) или curl отсутствует.
if [ -f "env/$ENV.env" ]; then set -a; . "env/$ENV.env"; set +a; fi
if [ -n "${SMOKE_NET:-}" ] || ! command -v curl >/dev/null 2>&1 || ! curl -fsS -m 5 "http://localhost:${API_PORT:-8080}/health" >/dev/null 2>&1; then
  echo "host network to proxy unreachable (VPN?) or no curl, using in-network smoke" >&2
  ../scripts/smoke-net.sh "$ENV"
else
  ../scripts/smoke.sh "$ENV"
fi
