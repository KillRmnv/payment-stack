#!/usr/bin/env bash
# Manual rollback: code only, schema stays (forward-only migrations).
set -euo pipefail
VERSION="${1:?usage: rollback.sh <version> [env]}"
ENV="${2:-stage}"
cd "$(dirname "$0")"
echo "WARNING: schema is NOT rolled back (forward-only). Code -> $VERSION" >&2
APP_VERSION="$VERSION" docker compose --env-file "env/$ENV.env" up -d --wait api worker
../scripts/smoke.sh "$ENV"
