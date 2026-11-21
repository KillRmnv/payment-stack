#!/usr/bin/env bash
# Sanitize + pack repo into a submission ZIP without secrets.
# The ZIP gets a generated VERSION file: the submission has no .git, so this is
# what makes APP_VERSION stable and rollback traceable after extraction.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-../payment-stack-submit.zip}"
mkdir -p "$(dirname "$OUT")"
OUT="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
VERSION_VALUE="$(./scripts/version.sh)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
printf '%s\n' "$VERSION_VALUE" > "$TMP/VERSION"

echo "version: $VERSION_VALUE"
echo "secret scan (fail on real values)..."
for f in deploy/runtime.env deploy/runtime.*.env; do
  [ -f "$f" ] || continue
  if grep -qvE "change-me|dev-only|test-|example" "$f" 2>/dev/null; then
    echo "WARNING: $f looks REAL — it will be EXCLUDED from ZIP." >&2
  fi
done
# Hard fail on token-like strings / private keys leaking into source files.
! grep -rInE "ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|BEGIN [A-Z ]*PRIVATE KEY" \
  --exclude-dir=.git --exclude-dir=__pycache__ --exclude-dir=.pytest_cache --exclude-dir=.ruff_cache \
  --include="*.py" --include="*.sh" --include="*.yml" --include="*.yaml" \
  --include="*.env" --include="*.example" --include="*.conf" . 2>/dev/null || {
  echo "FATAL: token-like string or private key found in repo" >&2
  exit 1
}

echo "packing to $OUT ..."
rm -f "$OUT"
zip -r "$OUT" . \
  -x "deploy/runtime.env" \
  -x "deploy/runtime.*.env" \
  -x "deploy/.env" \
  -x ".env" \
  -x ".vault-token-*" \
  -x ".deploy-state-*" \
  -x ".deploy-history-*" \
  -x ".deploy-lock-*" \
  -x "backups/*" \
  -x ".metrics/*" \
  -x ".git/*" \
  -x "VERSION" \
  -x "*.zip" \
  -x "__pycache__/*" "*/__pycache__/*" \
  -x ".pytest_cache/*" ".ruff_cache/*" \
  -x "*.log" >/dev/null
# VERSION is generated, not taken from the working tree: it always describes
# this exact package build (git SHA or explicit APP_VERSION).
( cd "$TMP" && zip -q "$OUT" VERSION )

echo "packed $OUT"
if ! unzip -p "$OUT" VERSION | grep -qx "$VERSION_VALUE"; then
  echo "FATAL: VERSION missing or mismatched in ZIP" >&2
  exit 1
fi
LEAKS="$(unzip -Z1 "$OUT" | grep -E \
  '(^|/)deploy/runtime(\.[^/]+)?\.env$|(^|/)deploy/\.env$|(^|/)\.env$|(^|/)\.vault-token-|(^|/)\.deploy-(state|history|lock)-|(^|/)backups/payments-' || true)"
if [ -n "$LEAKS" ]; then
  echo "FATAL: secret/state file leaked into ZIP:" >&2
  echo "$LEAKS" >&2
  exit 1
fi
echo "ZIP clean: version=$VERSION_VALUE, no runtime env / tokens / state / backups"
