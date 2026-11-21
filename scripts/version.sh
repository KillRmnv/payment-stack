#!/usr/bin/env bash
# Resolve an immutable, Docker-tag-safe application version.
#
# Precedence:
#   1. APP_VERSION from the environment (CI/release override)
#   2. git short SHA (with -dirty for tracked changes)
#   3. VERSION file (fallback for the submission ZIP, which has no .git)
#   4. nogit-<UTC timestamp> (last-resort unique local build)
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version="${APP_VERSION:-}"

if [ -z "$version" ] && [ -e "$repo/.git" ] && git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
  version="$(git -C "$repo" rev-parse --short HEAD 2>/dev/null || true)"
  if [ -n "$version" ] && [ -n "$(git -C "$repo" status --porcelain 2>/dev/null)" ]; then
    version="${version}-dirty"
  fi
fi

if [ -z "$version" ] && [ -f "$repo/VERSION" ]; then
  version="$(head -n 1 "$repo/VERSION" | tr -d '[:space:]')"
fi

if [ -z "$version" ]; then
  version="nogit-$(date -u +%Y%m%d%H%M%S)"
fi

# Docker tag rules: [A-Za-z0-9_][A-Za-z0-9_.-]{0,127}
if ! printf '%s' "$version" | grep -Eq '^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$'; then
  echo "FATAL: invalid APP_VERSION '$version' (must be a Docker tag)" >&2
  exit 1
fi

printf '%s\n' "$version"
