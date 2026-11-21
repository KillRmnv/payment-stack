#!/usr/bin/env bash
# Sanitize + pack repo into a submission ZIP without secrets.
#
# WITH_GIT=1 (default): include .git and require a clean tree. The tracked
# VERSION file stays untouched; version resolution uses the git SHA after
# extraction, so deploy.sh's dirty-tree check remains clean.
# WITH_GIT=0: standalone ZIP without .git and with a generated VERSION.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-../Романов_Кирилл_devops.zip}"
WITH_GIT="${WITH_GIT:-1}"
mkdir -p "$(dirname "$OUT")"
OUT="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"

case "$WITH_GIT" in
  0|1) ;;
  *) echo "FATAL: WITH_GIT must be 0 or 1" >&2; exit 1 ;;
esac

if [ "$WITH_GIT" = 1 ]; then
  [ -d .git ] || { echo "FATAL: WITH_GIT=1 but .git is missing; use WITH_GIT=0" >&2; exit 1; }
  if [ -n "$(git status --porcelain)" ]; then
    echo "FATAL: working tree is dirty; commit/stash before packaging with .git" >&2
    echo "HINT: use WITH_GIT=0 for a standalone archive without git history." >&2
    exit 1
  fi
fi

VERSION_VALUE="$(./scripts/version.sh)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
if [ "$WITH_GIT" = 0 ]; then
  printf '%s\n' "$VERSION_VALUE" > "$TMP/VERSION"
fi

echo "version: $VERSION_VALUE (with_git=$WITH_GIT)"
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
  --include="*.env" --include="*.example" --include="*.conf" \
  --include="*.md" --include="*.json" --include="*.sql" --include="*.cron" \
  --include="*.txt" --include="Dockerfile" . 2>/dev/null || {
  echo "FATAL: token-like string or private key found in repo" >&2
  exit 1
}

# If history is shipped, at least block obviously real credentials in commits.
if [ "$WITH_GIT" = 1 ]; then
  if git log -p --all 2>/dev/null | grep -qE \
    'ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|BEGIN [A-Z ]*PRIVATE KEY'; then
    echo "FATAL: token-like string or private key found in git history" >&2
    exit 1
  fi
  echo "WARNING: .git history contains starter test placeholders (nw-test-*), not real secrets." >&2
fi

echo "packing to $OUT ..."
rm -f "$OUT"
EXCLUDES=(
  -x "deploy/runtime.env"
  -x "deploy/runtime.*.env"
  -x "deploy/.env"
  -x ".env"
  -x ".vault-token-*"
  -x ".deploy-state-*"
  -x ".deploy-history-*"
  -x ".deploy-lock-*"
  -x "backups/*"
  -x ".metrics/*"
  -x "*.zip"
  -x "__pycache__/*" "*/__pycache__/*"
  -x ".pytest_cache/*" ".ruff_cache/*"
  -x "*.log"
)
if [ "$WITH_GIT" = 0 ]; then
  EXCLUDES+=( -x ".git/*" -x "VERSION" )
fi
zip -r "$OUT" . "${EXCLUDES[@]}" >/dev/null

if [ "$WITH_GIT" = 1 ]; then
  if ! unzip -Z1 "$OUT" | grep -qx '\.git/HEAD'; then
    echo "FATAL: .git/HEAD missing from ZIP" >&2
    exit 1
  fi
else
  ( cd "$TMP" && zip -q "$OUT" VERSION )
  if ! unzip -p "$OUT" VERSION | grep -qx "$VERSION_VALUE"; then
    echo "FATAL: VERSION missing or mismatched in ZIP" >&2
    exit 1
  fi
fi

echo "packed $OUT"
LEAKS="$(unzip -Z1 "$OUT" | grep -E \
  '(^|/)deploy/runtime(\.[^/]+)?\.env$|(^|/)deploy/\.env$|(^|/)\.env$|(^|/)\.vault-token-|(^|/)\.deploy-(state|history|lock)-|(^|/)backups/payments-' || true)"
if [ -n "$LEAKS" ]; then
  echo "FATAL: secret/state file leaked into ZIP:" >&2
  echo "$LEAKS" >&2
  exit 1
fi
echo "ZIP clean: version=$VERSION_VALUE, with_git=$WITH_GIT, no runtime env / tokens / state / backups"
