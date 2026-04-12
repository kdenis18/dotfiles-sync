#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v shellcheck &>/dev/null; then
  echo "shellcheck not installed — install with: brew install shellcheck"
  exit 1
fi

ERRORS=0

for f in "$REPO_DIR/generate-setup.sh" "$REPO_DIR"/lib/*.sh "$REPO_DIR"/tests/*.sh; do
  [[ -f "$f" ]] || continue
  if ! shellcheck -s bash -e SC1090,SC1091,SC2034 "$f"; then
    ((ERRORS++))
  fi
done

exit $ERRORS
