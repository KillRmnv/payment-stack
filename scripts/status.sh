#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/../deploy"
ENV="${1:-stage}"
if [ -f "env/$ENV.env" ]; then set -a; . "env/$ENV.env"; set +a; fi
PORT="${API_PORT:-8080}"
for service in api worker mock-provider db rabbitmq vault prometheus; do
  docker compose ps "$service" 2>/dev/null || true
done
echo "--- health ---"
curl -fsS "http://localhost:$PORT/health" || echo "api down"
echo
echo "--- metrics ---"
curl -fsS "http://localhost:$PORT/metrics" | grep -E "^(api_pending_transfers|api_oldest_pending_seconds|api_requests_total|worker_messages_total)" || echo "metrics unavailable"
echo "--- prometheus ---"
curl -fsS http://localhost:9090/-/healthy >/dev/null && echo "prometheus up" || echo "prometheus down (expected in prod/base, see compose.stage.yml)"
