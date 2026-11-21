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
COMPOSE="docker compose --env-file env/$ENV.env -f docker-compose.yml -f compose.$ENV.yml"

restore_services() {
  $COMPOSE up -d --wait rabbitmq >/dev/null 2>&1 || true
  $COMPOSE up -d --wait outbox worker >/dev/null 2>&1 || true
}
trap restore_services EXIT

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
