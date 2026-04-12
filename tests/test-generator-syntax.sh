#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_HOME="$REPO_DIR/tests/fixtures/home"
TEST_OUTPUT=$(mktemp -d)

trap 'rm -rf "$TEST_OUTPUT"; rm -f "$FIXTURE_HOME/Desktop/SECRETS_FOR_PASSWORD_MANAGER.md"; rmdir "$FIXTURE_HOME/Desktop" 2>/dev/null || true' EXIT

# Ensure fixture home has a Desktop dir for secrets file
mkdir -p "$FIXTURE_HOME/Desktop"

# Run generator with fixtures as HOME, skipping sections that need live tools
HOME="$FIXTURE_HOME" bash "$REPO_DIR/generate-setup.sh" \
  --output "$TEST_OUTPUT" \
  --only shell,git \
  2>/dev/null || {
    echo "Generator failed to run"
    exit 1
  }

# Check generated script exists
if [[ ! -f "$TEST_OUTPUT/setup-new-mac.sh" ]]; then
  echo "setup-new-mac.sh was not generated"
  exit 1
fi

# Syntax check the generated script
if ! bash -n "$TEST_OUTPUT/setup-new-mac.sh"; then
  echo "Generated script has syntax errors"
  exit 1
fi

echo "Generator syntax: OK"
