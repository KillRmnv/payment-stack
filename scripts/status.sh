#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/../deploy"
ENV="${1:-stage}"
. ./lib/env.sh
ensure_vault_token "$ENV"
if [ -f "env/$ENV.env" ]; then set -a; . "env/$ENV.env"; set +a; fi
PORT="${API_PORT:-8080}"
for service in api worker mock-provider db rabbitmq vault prometheus; do
  docker compose ps "$service" 2>/dev/null || true
done
echo "--- health ---"
if curl -fsS -m 5 "http://localhost:$PORT/health" >/dev/null 2>&1; then
  curl -fsS "http://localhost:$PORT/health" || echo "api down"
else
  echo "host network to proxy unreachable (VPN?), check in-network:"
  echo "  ./scripts/smoke-net.sh $ENV"
  docker compose --env-file "env/$ENV.env" -f docker-compose.yml -f "compose.$ENV.yml" exec -T worker python3 -c "import urllib.request; print(urllib.request.urlopen('http://reverse-proxy/health', timeout=5).read().decode())" 2>/dev/null || echo "api down (host + in-network)"
fi
echo
echo "--- metrics (in-network: edge proxy не публикует /metrics) ---"
docker compose --env-file "env/$ENV.env" -f docker-compose.yml -f "compose.$ENV.yml" exec -T worker python3 -c "
import urllib.request
body = urllib.request.urlopen('http://api:8000/metrics', timeout=5).read().decode()
print('\n'.join(l for l in body.splitlines() if l.startswith(('api_pending_transfers','api_oldest_pending_seconds','api_requests_total','worker_messages_total','worker_dlq_published_total'))))
" 2>/dev/null || echo "metrics unavailable in-network (api down?)"
echo "--- prometheus ---"
PROM_PORT=""
[ "$ENV" = "stage" ] && PROM_PORT="9090"
if [ -n "$PROM_PORT" ] && curl -fsS -m 5 http://localhost:$PROM_PORT/-/healthy >/dev/null 2>&1; then
  echo "prometheus up (stage only, prod intentionally has no published 9090)"
else
  echo "prometheus down/unpublished (expected in prod: no published 9090)"
fi
