#!/usr/bin/env bash
set -e
cd "$(dirname "$0")/../deploy"
for service in api worker mock-provider db rabbitmq; do
  docker compose ps "$service"
done
curl -fsS http://localhost:9090/-/healthy >/dev/null && echo "prometheus up" || echo "prometheus down"
