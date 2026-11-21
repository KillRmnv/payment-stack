#!/usr/bin/env bash
# Verify the alert delivery chain end-to-end:
#   test -> Alertmanager -> alert-sink -> /alerts
# Uses a unique synthetic SelfTest alert, so a stale Watchdog from a previous
# run cannot make the test pass.
set -euo pipefail
ENV="${1:-stage}"
cd "$(dirname "$0")/../deploy"
[ -f "env/$ENV.env" ] || { echo "FATAL: unknown ENV=$ENV" >&2; exit 1; }
set -a; . "env/$ENV.env"; set +a
. ./lib/env.sh
ensure_vault_token "$ENV"

docker compose --env-file "env/$ENV.env" -f docker-compose.yml -f "compose.$ENV.yml" \
  exec -T api python3 - <<'PY'
import datetime
import json
import sys
import time
import urllib.error
import urllib.request
import uuid

ALERTMANAGER = "http://alertmanager:9093/api/v2/alerts"
SINK = "http://alert-sink:8080/alerts"
selftest_id = uuid.uuid4().hex
start = datetime.datetime.now(datetime.UTC).replace(microsecond=0)
end = start + datetime.timedelta(seconds=120)
payload = [{
    "labels": {
        "alertname": "SelfTest",
        "severity": "none",
        "service": "payment-stack",
        "selftest_id": selftest_id,
    },
    "annotations": {"summary": "synthetic alert delivery self-test"},
    "startsAt": start.isoformat().replace("+00:00", "Z"),
    "endsAt": end.isoformat().replace("+00:00", "Z"),
}]


def request(url, data=None, method="GET"):
    req = urllib.request.Request(
        url,
        data=json.dumps(data).encode() if data is not None else None,
        method=method,
        headers={"Content-Type": "application/json"} if data is not None else {},
    )
    with urllib.request.urlopen(req, timeout=10) as response:
        return response.status, response.read()


try:
    status, _ = request(ALERTMANAGER, payload, "POST")
except urllib.error.HTTPError as exc:
    raise SystemExit(f"FATAL: Alertmanager rejected SelfTest: HTTP {exc.code} {exc.read(300)!r}")
if status not in (200, 202):
    raise SystemExit(f"FATAL: Alertmanager returned HTTP {status} for SelfTest")
print(f"sent SelfTest {selftest_id} to Alertmanager", flush=True)

for attempt in range(1, 46):
    try:
        _, body = request(SINK)
        alerts = json.loads(body or b"[]")
    except Exception as exc:
        print(f"try {attempt}: alert-sink unavailable: {exc}", flush=True)
    else:
        matches = [
            alert
            for alert in alerts
            if alert.get("labels", {}).get("alertname") == "SelfTest"
            and alert.get("labels", {}).get("selftest_id") == selftest_id
        ]
        if matches:
            print(f"try {attempt}: SelfTest delivered to alert-sink", flush=True)
            print("alert delivery OK")
            sys.exit(0)
        print(f"try {attempt}: SelfTest not delivered yet", flush=True)
    time.sleep(2)
raise SystemExit("FATAL: SelfTest was not delivered to alert-sink")
PY
