#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_HOME="$REPO_DIR/tests/fixtures/home"
GOLDEN_DIR="$REPO_DIR/tests/fixtures/golden"
GOLDEN_FILE="$GOLDEN_DIR/setup-new-mac.golden.sh"
TEST_OUTPUT=$(mktemp -d)

trap 'rm -rf "$TEST_OUTPUT"; rm -f "$FIXTURE_HOME/Desktop/SECRETS_FOR_PASSWORD_MANAGER.md"; rmdir "$FIXTURE_HOME/Desktop" 2>/dev/null || true' EXIT

# Ensure fixture home has a Desktop dir for secrets file
mkdir -p "$FIXTURE_HOME/Desktop"

# Run generator with fixtures
HOME="$FIXTURE_HOME" bash "$REPO_DIR/generate-setup.sh" \
  --output "$TEST_OUTPUT" \
  --only shell,git \
  2>/dev/null || true

SCRIPT="$TEST_OUTPUT/setup-new-mac.sh"
[[ -f "$SCRIPT" ]] || { echo "No script generated"; exit 1; }

# Strip dynamic content (timestamps, hostnames, git SHAs) before comparing
_normalize() {
  sed -E \
    -e 's/Generated: [0-9]{4}-[0-9]{2}-[0-9]{2}T[^ ]*/Generated: TIMESTAMP/' \
    -e 's/Generated: [0-9]{4}-[0-9]{2}-[0-9]{2}/Generated: DATE/' \
    -e 's/Source machine: [^ ]*/Source machine: HOST/' \
    -e 's/Generator version: [a-f0-9]+/Generator version: SHA/' \
    -e 's/dotfiles-sync \([a-f0-9]+\)/dotfiles-sync (SHA)/' \
    -e 's/Migration script from: [^ ]*/Migration script from: HOST/' \
    "$1"
}

if [[ "${1:-}" == "--update-golden" ]]; then
  mkdir -p "$GOLDEN_DIR"
  _normalize "$SCRIPT" > "$GOLDEN_FILE"
  echo "Golden file updated: $GOLDEN_FILE"
  exit 0
fi

if [[ ! -f "$GOLDEN_FILE" ]]; then
  echo "No golden file found. Run with --update-golden first."
  exit 1
fi

# Compare
ACTUAL=$(mktemp)
_normalize "$SCRIPT" > "$ACTUAL"

if diff -u "$GOLDEN_FILE" "$ACTUAL"; then
  echo "Golden file check: OK"
else
  echo ""
  echo "Golden file check: FAILED"
  echo "Run './tests/run-tests.sh --update-golden' to update"
  rm -f "$ACTUAL"
  exit 1
fi

rm -f "$ACTUAL"
