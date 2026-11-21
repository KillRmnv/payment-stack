#!/usr/bin/env bash
# In-network smoke: тот же сценарий, что smoke.sh (POST -> poll COMPLETED),
# но трафик идет внутри compose-сети через reverse-proxy.
# Нужен, когда хост не может достучаться до published-портов (VPN/файрвол):
#   ./scripts/smoke-net.sh [stage|prod]
set -euo pipefail
ENV="${1:-stage}"
cd "$(dirname "$0")/../deploy"
. ./lib/env.sh
ensure_vault_token "$ENV"
COMPOSE="docker compose --env-file env/$ENV.env -f docker-compose.yml -f compose.$ENV.yml"
$COMPOSE exec -T worker python3 - http://reverse-proxy <<'EOF'
import json
import sys
import time
import urllib.request
import uuid

BASE = sys.argv[1]
body = json.dumps({"amount": "100.00", "currency": "RUB", "recipient": "TH1234567890"}).encode()
req = urllib.request.Request(
    f"{BASE}/transfers",
    data=body,
    headers={"Content-Type": "application/json", "Idempotency-Key": str(uuid.uuid4())},
)
with urllib.request.urlopen(req, timeout=15) as r:
    transfer_id = json.load(r)["id"]
print(f"created {transfer_id}", flush=True)
for i in range(1, 31):
    with urllib.request.urlopen(f"{BASE}/transfers/{transfer_id}", timeout=15) as r:
        status = json.load(r)["status"]
    print(f"try {i} status={status}", flush=True)
    if status == "COMPLETED":
        print("smoke-net OK")
        sys.exit(0)
    time.sleep(2)
print(f"smoke-net FAILED: {transfer_id} never COMPLETED", file=sys.stderr)
sys.exit(1)
EOF
