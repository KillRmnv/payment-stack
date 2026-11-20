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

# ensure_vault_token <env>
ensure_vault_token() {
  local env="${1:-stage}" repo token_file
  repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  token_file="$repo/.vault-token-$env"
  if [ -z "${VAULT_DEV_ROOT_TOKEN:-}" ]; then
    if [ -f "$token_file" ]; then
      VAULT_DEV_ROOT_TOKEN="$(cat "$token_file")"
    else
      VAULT_DEV_ROOT_TOKEN="$(_gen_secret)"
      printf '%s\n' "$VAULT_DEV_ROOT_TOKEN" > "$token_file"
      chmod 600 "$token_file"
      echo "generated $token_file (gitignored, keep it: token change wipes dev Vault)" >&2
    fi
  fi
  export VAULT_DEV_ROOT_TOKEN
}
