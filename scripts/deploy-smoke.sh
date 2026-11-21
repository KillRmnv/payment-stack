#!/usr/bin/env bash
# Clean-machine deploy proof, also used by the GitHub Actions deploy-smoke job.
# Creates a fresh compose project with generated secrets, deploys HEAD, then
# runs the business/DR/alerting checks that do not need a self-hosted runner.
#
# For a local run on a dirty working tree set ALLOW_DIRTY=1 (explicit escape).
set -euo pipefail

cd "$(dirname "$0")/.."
export PAYMENT_STACK_PROJECT="${PAYMENT_STACK_PROJECT:-ci}"
export PAYMENT_STACK_RUNTIME_ENV="${PAYMENT_STACK_RUNTIME_ENV:-runtime.ci.env}"

gen() {
  openssl rand -hex 16 2>/dev/null \
    || python3 -c 'import secrets;print(secrets.token_hex(16))' \
    || head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n'
}

export DB_PASSWORD="${DB_PASSWORD:-$(gen)}"
export RABBITMQ_PASSWORD="${RABBITMQ_PASSWORD:-$(gen)}"
export PROVIDER_API_KEY="${PROVIDER_API_KEY:-$(gen)}"
export VAULT_DEV_ROOT_TOKEN="${VAULT_DEV_ROOT_TOKEN:-$(gen)}"

echo "deploy-smoke: project=$PAYMENT_STACK_PROJECT runtime=$PAYMENT_STACK_RUNTIME_ENV"
if ! make deploy ENV=stage; then
  echo "FATAL: deploy failed; stack diagnostics:" >&2
  ./scripts/status.sh stage || true
  exit 1
fi

echo "deploy-smoke: idempotency"
make smoke-idempotency ENV=stage

echo "deploy-smoke: alert delivery"
make alert-selftest ENV=stage

echo "deploy-smoke: restore --apply regression"
make restore-apply-selftest ENV=stage

echo "deploy-smoke: outbox drill"
make outbox-drill ENV=stage

echo "deploy-smoke OK"
