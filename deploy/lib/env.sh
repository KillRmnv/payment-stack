#!/usr/bin/env bash
# Shared env loading для deploy-скриптов.
# Vault dev-root token: env -> gitignored .vault-token-<env> -> generate.
# Compose объявляет ${VAULT_DEV_ROOT_TOKEN:?...} (fail-fast без дефолта),
# поэтому токен должен быть загружен ДО любого docker compose вызова.

_gen_secret() {
  openssl rand -hex 16 2>/dev/null \
    || python3 -c 'import secrets;print(secrets.token_hex(16))' 2>/dev/null \
    || head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n'
}

# worker_supports_outbox <version>
# A version before the outbox deploy has no worker.outbox module. Rollback must
# not try to start the new outbox service with that image.
worker_supports_outbox() {
  local version="$1"
  docker run --rm --network none --entrypoint python3 \
    "northwind/payment-worker:$version" -c "import worker.outbox" >/dev/null 2>&1
}

# acquire_deploy_lock <env>
# Serializes deploy/rollback/rotate/restore on the same host. The lock is
# released by the kernel when the process exits (including SIGKILL).
acquire_deploy_lock() {
  local env="${1:-stage}" repo lock
  repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  lock="$repo/.deploy-lock-$env"
  if ! command -v flock >/dev/null 2>&1; then
    echo "FATAL: flock not found (util-linux is required for deploy locking)" >&2
    return 1
  fi
  exec 9>"$lock" || return 1
  if ! flock -n 9; then
    echo "FATAL: another deploy/rollback/rotate/restore holds $lock" >&2
    return 1
  fi
}

# ensure_vault_token <env>
# Also pins the compose project/runtime env file to the selected environment:
# stage and prod must never share containers, volumes or secrets.
# PAYMENT_STACK_PROJECT is an explicit escape hatch for migrating an old stand.
ensure_vault_token() {
  local env="${1:-stage}" repo token_file existing
  if ! [[ "$env" =~ ^[a-z0-9_-]+$ ]]; then
    echo "FATAL: invalid ENV='$env' (use stage/prod)" >&2
    return 1
  fi
  repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  token_file="$repo/.vault-token-$env"
  export STACK_ENV="$env"
  export RUNTIME_ENV_FILE="${PAYMENT_STACK_RUNTIME_ENV:-runtime.$env.env}"
  export COMPOSE_PROJECT_NAME="${PAYMENT_STACK_PROJECT:-payment-stack-$env}"
  if [ -n "${VAULT_DEV_ROOT_TOKEN:-}" ]; then
    if [ -f "$token_file" ]; then
      existing="$(cat "$token_file")"
      if [ "$existing" != "$VAULT_DEV_ROOT_TOKEN" ]; then
        echo "FATAL: VAULT_DEV_ROOT_TOKEN differs from $token_file." >&2
        echo "HINT: unset VAULT_DEV_ROOT_TOKEN to reuse the saved token, or remove" >&2
        echo "      $token_file intentionally (this recreates dev Vault and wipes secrets)." >&2
        return 1
      fi
    else
      umask 077
      printf '%s\n' "$VAULT_DEV_ROOT_TOKEN" > "$token_file"
      chmod 600 "$token_file"
      echo "recorded $token_file (gitignored, keep it: token change wipes dev Vault)" >&2
    fi
  elif [ -f "$token_file" ]; then
    VAULT_DEV_ROOT_TOKEN="$(cat "$token_file")"
    chmod 600 "$token_file" 2>/dev/null || true
  else
    VAULT_DEV_ROOT_TOKEN="$(_gen_secret)"
    umask 077
    printf '%s\n' "$VAULT_DEV_ROOT_TOKEN" > "$token_file"
    chmod 600 "$token_file"
    echo "generated $token_file (gitignored, keep it: token change wipes dev Vault)" >&2
  fi
  export VAULT_DEV_ROOT_TOKEN
}
