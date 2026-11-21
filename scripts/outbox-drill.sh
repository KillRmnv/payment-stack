#!/usr/bin/env bash
# Drill: prove that API accepts a transfer while RabbitMQ is down, the outbox
# keeps it, and the worker completes it after RabbitMQ returns.
# Destructive for the running stack: stops/starts rabbitmq. Run manually.
set -euo pipefail
ENV="${1:-stage}"
cd "$(dirname "$0")/../deploy"
[ -f "env/$ENV.env" ] || { echo "FATAL: unknown ENV=$ENV" >&2; exit 1; }
set -a; . "env/$ENV.env"; set +a
. ./lib/env.sh
ensure_vault_token "$ENV"
acquire_deploy_lock "$ENV"

# Pin every image to the deployed version. Without this, the `up` calls below
# fall back to ${APP_VERSION:-dev} and can silently downgrade the stand to an
# old `dev` image that may not even contain worker.outbox.
APP_VERSION="${APP_VERSION:-$(cat "../.deploy-state-$ENV" 2>/dev/null || true)}"
[ -n "$APP_VERSION" ] || APP_VERSION="$(../scripts/version.sh)"
export APP_VERSION
COMPOSE="docker compose --env-file env/$ENV.env -f docker-compose.yml -f compose.$ENV.yml"

if [ "$ENV" = "prod" ] && [ "${ALLOW_PROD_DRILL:-0}" != "1" ]; then
  echo "FATAL: refusing to stop RabbitMQ in prod; set ALLOW_PROD_DRILL=1 if intended" >&2
  exit 1
fi

verify_versions() {
  local svc id img expected
  for svc in api worker outbox mock-provider; do
    id="$($COMPOSE ps -q "$svc" 2>/dev/null || true)"
    if [ -z "$id" ]; then
      echo "FATAL: service $svc has no container after drill" >&2
      return 1
    fi
    img="$(docker inspect --format '{{.Config.Image}}' "$id" 2>/dev/null || true)"
    case "$svc" in
      api) expected="northwind/payment-api:$APP_VERSION" ;;
      worker|outbox) expected="northwind/payment-worker:$APP_VERSION" ;;
      mock-provider) expected="northwind/mock-provider:$APP_VERSION" ;;
    esac
    if [ "$img" != "$expected" ]; then
      echo "FATAL: $svc runs '$img', expected '$expected' (drill downgraded the stand?)" >&2
      return 1
    fi
  done
}

verify_health() {
  $COMPOSE exec -T api python3 -c "
import urllib.request
for url in ('http://outbox:8002/health', 'http://worker:8001/health'):
    urllib.request.urlopen(url, timeout=5).read()
" >/dev/null
}

cleanup() {
  local rc=$?
  set +e
  echo "restoring rabbitmq/outbox/worker (version $APP_VERSION)..." >&2
  if ! $COMPOSE up -d --wait rabbitmq >/dev/null; then
    echo "FATAL: failed to restore rabbitmq" >&2
    rc=1
  fi
  if ! $COMPOSE up -d --wait outbox worker >/dev/null; then
    echo "FATAL: failed to restore outbox/worker" >&2
    rc=1
  fi
  if ! verify_versions; then
    rc=1
  fi
  if ! verify_health; then
    echo "FATAL: worker/outbox health failed after drill" >&2
    rc=1
  fi
  exit "$rc"
}
trap cleanup EXIT

echo "stopping rabbitmq..."
$COMPOSE stop rabbitmq >/dev/null

echo "posting transfer while broker is down..."
ID="$($COMPOSE exec -T api python3 - <<'PY'
import json
import urllib.request
import uuid

body = {"amount": "100.00", "currency": "RUB", "recipient": "TH1234567890"}
request = urllib.request.Request(
    "http://reverse-proxy/transfers",
    data=json.dumps(body).encode(),
    headers={"Content-Type": "application/json", "Idempotency-Key": str(uuid.uuid4())},
    method="POST",
)
with urllib.request.urlopen(request, timeout=10) as response:
    assert response.status == 202, response.status
    print(json.load(response)["id"])
PY
)"
echo "created $ID"

STATUS="$($COMPOSE exec -T db psql -U payments -d payments -tAc \
  "SELECT status FROM transfer_outbox WHERE transfer_id = '$ID'")"
STATUS="${STATUS//[[:space:]]/}"
[ "$STATUS" = "PENDING" ] || { echo "FATAL: expected outbox PENDING, got '$STATUS'" >&2; exit 1; }
echo "outbox row is PENDING"

echo "starting rabbitmq..."
$COMPOSE up -d --wait rabbitmq >/dev/null

echo "waiting for worker to complete the transfer..."
$COMPOSE exec -T api python3 - "$ID" <<'PY'
import json
import sys
import time
import urllib.request

transfer_id = sys.argv[1]
for attempt in range(1, 31):
    with urllib.request.urlopen(f"http://reverse-proxy/transfers/{transfer_id}", timeout=10) as response:
        status = json.load(response)["status"]
    print(f"try {attempt} status={status}")
    if status == "COMPLETED":
        sys.exit(0)
    time.sleep(2)
raise SystemExit("transfer never completed")
PY

STATUS="$($COMPOSE exec -T db psql -U payments -d payments -tAc \
  "SELECT status FROM transfer_outbox WHERE transfer_id = '$ID'")"
STATUS="${STATUS//[[:space:]]/}"
[ "$STATUS" = "SENT" ] || { echo "FATAL: expected outbox SENT, got '$STATUS'" >&2; exit 1; }
echo "outbox drill OK"
