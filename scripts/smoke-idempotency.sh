#!/usr/bin/env bash
# In-network idempotency regression test. Requires a deployed stack.
set -euo pipefail
ENV="${1:-stage}"
cd "$(dirname "$0")/../deploy"
[ -f "env/$ENV.env" ] || { echo "FATAL: unknown ENV=$ENV" >&2; exit 1; }
set -a; . "env/$ENV.env"; set +a
. ./lib/env.sh
ensure_vault_token "$ENV"

docker compose --env-file "env/$ENV.env" -f docker-compose.yml -f "compose.$ENV.yml" \
  exec -T api python3 - "${REQUIRE_IDEMPOTENCY_KEY:-true}" <<'PY'
import json
import sys
import urllib.error
import urllib.request
import uuid

BASE = "http://reverse-proxy"
required = sys.argv[1].lower() not in ("0", "false", "no")


def post(body, key=None):
    headers = {"Content-Type": "application/json"}
    if key is not None:
        headers["Idempotency-Key"] = key
    request = urllib.request.Request(
        f"{BASE}/transfers",
        data=json.dumps(body).encode(),
        headers=headers,
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            return response.status, json.load(response), response.headers
    except urllib.error.HTTPError as exc:
        return exc.code, json.loads(exc.read() or b"{}"), exc.headers


body = {"amount": "100.00", "currency": "RUB", "recipient": "TH1234567890"}
other = {"amount": "101.00", "currency": "RUB", "recipient": "TH1234567890"}
key = str(uuid.uuid4())

status, first, _ = post(body, key)
assert status == 202, (status, first)

status, replay, headers = post(body, key)
assert status == 200, (status, replay)
assert replay["id"] == first["id"], (replay, first)
assert headers.get("X-Idempotent-Replay") == "true", dict(headers)

status, conflict, _ = post(other, key)
assert status == 409, (status, conflict)

if required:
    status, missing, _ = post(body)
    assert status == 400, (status, missing)

print("idempotency smoke OK")
PY
