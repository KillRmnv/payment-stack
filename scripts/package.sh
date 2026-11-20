#!/usr/bin/env bash
# Sanitize + pack repo into a submission ZIP without secrets.
# Usage: ./scripts/package.sh [output.zip]
# Excludes: runtime.env, .vault-token-*, .deploy-state-*, backups/, .git/, caches.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-../payment-stack-submit.zip}"

echo "secret scan (fail on real values)..."
if [ -f deploy/runtime.env ]; then
  if grep -qvE "change-me|dev-only|test-|example" deploy/runtime.env 2>/dev/null; then
    echo "WARNING: deploy/runtime.env looks REAL — it will be EXCLUDED from ZIP (see below)." >&2
  fi
fi
# Hard fail if example/placeholder secrets leaked anywhere unexpected.
! grep -rnE "ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}" --include="*.sh" --include="*.yml" --include="*.env" --include="*.example" . || {
  echo "FATAL: token-like string found in repo" >&2; exit 1;
}

echo "packing to $OUT ..."
rm -f "$OUT"
zip -r "$OUT" . \
  -x "deploy/runtime.env" \
  -x ".vault-token-*" \
  -x ".deploy-state-*" \
  -x "backups/*" \
  -x ".git/*" \
  -x "__pycache__/*" "*/__pycache__/*" \
  -x ".pytest_cache/*" ".ruff_cache/*" \
  -x "*.log" >/dev/null
echo "packed $OUT"
echo "verify (must be empty):"
unzip -l "$OUT" | grep -E " deploy/runtime\.env$|\.vault-token|\.deploy-state |backups/payments-" && {
  echo "FATAL: secret/state file leaked into ZIP" >&2; exit 1;
} || echo "ZIP clean: no runtime.env / tokens / backups"
