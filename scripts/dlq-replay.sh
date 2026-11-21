#!/usr/bin/env bash
# Re-drive messages from transfers.dlq back to transfers.
#
# Default: only valid JSON messages with a UUID transfer_id are replayed;
# malformed poison stays in the DLQ for manual triage. --all replays them too.
# The retry headers are reset, otherwise a max-retries message would immediately
# go back to the DLQ.
#
# Usage: ./scripts/dlq-replay.sh [stage|prod] [--dry-run] [--limit N] [--all]
set -euo pipefail

ENV="stage"
LIMIT=100
DRY=0
ALL=0
if [ $# -gt 0 ] && [[ "$1" != --* ]]; then
  ENV="$1"
  shift
fi
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --all) ALL=1 ;;
    --limit)
      LIMIT="${2:?--limit requires a number}"
      shift
      ;;
    --limit=*) LIMIT="${1#*=}" ;;
    -h|--help)
      sed -n '2,12p' "$0"
      exit 0
      ;;
    *)
      echo "FATAL: unknown argument: $1" >&2
      exit 1
      ;;
  esac
  shift
done

if ! [[ "$LIMIT" =~ ^[1-9][0-9]*$ ]] || [ "$LIMIT" -gt 1000 ]; then
  echo "FATAL: --limit must be 1..1000" >&2
  exit 1
fi

cd "$(dirname "$0")/../deploy"
[ -f "env/$ENV.env" ] || { echo "FATAL: unknown ENV=$ENV" >&2; exit 1; }
set -a; . "env/$ENV.env"; set +a
. ./lib/env.sh
ensure_vault_token "$ENV"

docker compose --env-file "env/$ENV.env" -f docker-compose.yml -f "compose.$ENV.yml" \
  exec -T rabbitmq python3 - "$LIMIT" "$DRY" "$ALL" <<'PY'
import base64
import json
import os
import sys
import urllib.error
import urllib.request
import uuid

limit = int(sys.argv[1])
dry_run = sys.argv[2] == "1"
replay_all = sys.argv[3] == "1"
DLQ = "transfers.dlq"
QUEUE = "transfers"
BASE = "http://localhost:15672/api"
USER = os.environ.get("RABBITMQ_DEFAULT_USER", "payments")
PASSWORD = os.environ.get("RABBITMQ_DEFAULT_PASS", "")

if not PASSWORD:
    raise SystemExit("FATAL: RABBITMQ_DEFAULT_PASS is empty")

AUTH = "Basic " + base64.b64encode(f"{USER}:{PASSWORD}".encode()).decode()


def api(method, path, payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(
        BASE + path,
        data=data,
        method=method,
        headers={"Authorization": AUTH, "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as response:
            body = response.read()
    except urllib.error.HTTPError as exc:
        detail = exc.read(300).decode(errors="replace")
        raise SystemExit(f"FATAL: management API {method} {path}: HTTP {exc.code} {detail}")
    return json.loads(body) if body else None


def valid_transfer(payload):
    try:
        data = json.loads(payload)
        uuid.UUID(str(data["transfer_id"]))
        return True
    except (ValueError, KeyError, TypeError, json.JSONDecodeError):
        return False


def publish(routing_key, payload, properties, reset_retry):
    headers = {} if reset_retry else dict((properties or {}).get("headers") or {})
    out = {"delivery_mode": 2, "headers": headers}
    for key in ("content_type", "content_encoding", "correlation_id", "message_id"):
        if (properties or {}).get(key):
            out[key] = properties[key]
    result = api(
        "POST",
        "/exchanges/%2F/amq.default/publish",
        {
            "routing_key": routing_key,
            "payload": payload,
            "payload_encoding": "string",
            "properties": out,
        },
    )
    if not result.get("routed"):
        raise RuntimeError(f"message was not routed to {routing_key}")


def get_one():
    messages = api(
        "POST",
        f"/queues/%2F/{DLQ}/get",
        {"count": 1, "ackmode": "ack_requeue_false", "encoding": "auto"},
    )
    return messages[0] if messages else None


info = api("GET", f"/queues/%2F/{DLQ}")
depth = int(info.get("messages") or 0)
print(f"DLQ depth before: {depth}")

if depth == 0:
    raise SystemExit(0)

if dry_run:
    sample = api(
        "POST",
        f"/queues/%2F/{DLQ}/get",
        {"count": min(limit, depth), "ackmode": "ack_requeue_true", "encoding": "auto"},
    )
    valid = sum(1 for message in sample if valid_transfer(message["payload"]))
    print(f"dry-run: inspected={len(sample)} replayable={valid} skipped={len(sample) - valid}")
    print("no messages were moved")
    raise SystemExit(0)

replayed = skipped = 0
for _ in range(min(limit, depth)):
    message = get_one()
    if message is None:
        break
    payload = message["payload"]
    properties = message.get("properties") or {}
    valid = valid_transfer(payload)
    target = QUEUE if (valid or replay_all) else DLQ
    try:
        publish(target, payload, properties, reset_retry=(target == QUEUE))
    except Exception as exc:
        # The get() above removed the message. Never lose it silently: try to
        # put the original back into the DLQ, then abort.
        try:
            publish(DLQ, payload, properties, reset_retry=False)
        except Exception as restore_exc:
            raise SystemExit(
                f"FATAL: publish failed ({exc}) and DLQ restore failed ({restore_exc}); "
                "message may be lost"
            ) from exc
        raise SystemExit(f"FATAL: publish failed ({exc}); message returned to DLQ")
    if target == QUEUE:
        replayed += 1
    else:
        skipped += 1

info = api("GET", f"/queues/%2F/{DLQ}")
print(f"replayed={replayed} skipped={skipped} DLQ depth after: {info.get('messages', 0)}")
PY
