#!/usr/bin/env bash
# Verify the alert delivery chain: Alertmanager must deliver the always-firing
# Watchdog alert to the local alert-sink.
set -euo pipefail
ENV="${1:-stage}"
cd "$(dirname "$0")/../deploy"
[ -f "env/$ENV.env" ] || { echo "FATAL: unknown ENV=$ENV" >&2; exit 1; }
set -a; . "env/$ENV.env"; set +a
. ./lib/env.sh
ensure_vault_token "$ENV"

docker compose --env-file "env/$ENV.env" -f docker-compose.yml -f "compose.$ENV.yml" \
  exec -T api python3 - <<'PY'
import json
import sys
import time
import urllib.request

url = "http://alert-sink:8080/alerts"
for attempt in range(1, 46):
    try:
        with urllib.request.urlopen(url, timeout=5) as response:
            alerts = json.load(response)
    except Exception as exc:
        alerts = []
        print(f"try {attempt}: alert-sink unavailable: {exc}", flush=True)
    else:
        names = [a.get("labels", {}).get("alertname") for a in alerts]
        print(f"try {attempt}: {names}", flush=True)
        if "Watchdog" in names:
            print("alert delivery OK (Watchdog received by alert-sink)")
            sys.exit(0)
    time.sleep(2)
raise SystemExit("FATAL: Watchdog was not delivered to alert-sink")
PY
