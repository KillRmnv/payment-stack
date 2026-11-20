#!/usr/bin/env bash
# Smoke: POST /transfers -> 202 -> poll GET until COMPLETED (max 60s).
# Требует curl+python3 на хосте. Без них — ./smoke-net.sh (python внутри контейнера).
set -euo pipefail
ENV="${1:-stage}"
command -v curl >/dev/null 2>&1 || { echo "FATAL: curl not found, use ./scripts/smoke-net.sh $ENV (in-network, no host curl needed)" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not found, use ./scripts/smoke-net.sh $ENV" >&2; exit 1; }
cd "$(dirname "$0")/.."
PORT="8080"; [ "$ENV" = "prod" ] && PORT="8081"
[ -n "${API_PORT:-}" ] || true
# allow override via deploy env file
if [ -f "deploy/env/$ENV.env" ]; then set -a; . "deploy/env/$ENV.env"; set +a; PORT="${API_PORT:-$PORT}"; fi
# SMOKE_BASE переопределяет точку входа: по умолчанию localhost (хост),
# внутри docker-сети — http://reverse-proxy (обходит VPN/файрвол хоста).
BASE="${SMOKE_BASE:-http://localhost:$PORT}"

echo "smoke $ENV $BASE"
ID="$(curl -fsS -X POST "$BASE/transfers" -H 'Content-Type: application/json' \
  -d '{"amount":"100.00","currency":"RUB","recipient":"TH1234567890"}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')"
echo "created $ID"
for i in $(seq 1 30); do
  STATUS="$(curl -fsS "$BASE/transfers/$ID" | python3 -c 'import sys,json;print(json.load(sys.stdin)["status"])')"
  echo "try $i status=$STATUS"
  [ "$STATUS" = "COMPLETED" ] && { echo "smoke OK"; exit 0; }
  sleep 2
done
echo "smoke FAILED: $ID never COMPLETED" >&2
exit 1
