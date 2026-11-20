#!/usr/bin/env bash
# Manual rollback: code only, schema stays (forward-only migrations).
set -euo pipefail
VERSION="${1:?usage: rollback.sh <version> [env]}"
ENV="${2:-stage}"
cd "$(dirname "$0")"
echo "WARNING: schema is NOT rolled back (forward-only). Code -> $VERSION" >&2
echo "WARNING: if migration already applied, old code must be compatible or fix forward with 004_..." >&2
APP_VERSION="$VERSION" docker compose --env-file "env/$ENV.env" -f docker-compose.yml -f "compose.$ENV.yml" up -d --wait api worker
../scripts/smoke.sh "$ENV"
