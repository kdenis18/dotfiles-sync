#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_HOME="$REPO_DIR/tests/fixtures/home"
TEST_OUTPUT=$(mktemp -d)

trap 'rm -rf "$TEST_OUTPUT"; rm -f "$FIXTURE_HOME/Desktop/SECRETS_FOR_PASSWORD_MANAGER.md"; rmdir "$FIXTURE_HOME/Desktop" 2>/dev/null || true' EXIT

# Ensure fixture home has a Desktop dir for secrets file
mkdir -p "$FIXTURE_HOME/Desktop"

# Run generator with fixtures
HOME="$FIXTURE_HOME" bash "$REPO_DIR/generate-setup.sh" \
  --output "$TEST_OUTPUT" \
  --only shell,claude,git \
  2>/dev/null || true

SCRIPT="$TEST_OUTPUT/setup-new-mac.sh"
[[ -f "$SCRIPT" ]] || { echo "No script generated"; exit 1; }

LEAKED=0

# Check for known fixture secrets in the install script
for secret in "sk-test-fixture-secret-12345" "sk-test-mcp-secret-67890"; do
  if grep -q "$secret" "$SCRIPT"; then
    echo "LEAKED: $secret found in setup-new-mac.sh"
    ((LEAKED++))
  fi
done

# Check migration-configs too
if [[ -d "$TEST_OUTPUT/migration-configs" ]]; then
  for secret in "sk-test-fixture-secret-12345" "sk-test-mcp-secret-67890"; do
    if grep -rq "$secret" "$TEST_OUTPUT/migration-configs/"; then
      echo "LEAKED: $secret found in migration-configs/"
      ((LEAKED++))
    fi
  done
fi

# Check for common secret prefixes (that shouldn't appear in install scripts)
for prefix in "sk-test-" "ghp_" "gho_" "AKIA" "-----BEGIN.*PRIVATE KEY"; do
  if grep -qE "$prefix" "$SCRIPT"; then
    echo "SUSPICIOUS: pattern '$prefix' found in setup-new-mac.sh"
    ((LEAKED++))
  fi
done

# Verify secrets DO appear in the secrets file
SECRETS_FILE="$FIXTURE_HOME/Desktop/SECRETS_FOR_PASSWORD_MANAGER.md"
if [[ -f "$SECRETS_FILE" ]]; then
  for secret in "sk-test-fixture-secret-12345" "sk-test-mcp-secret-67890"; do
    if ! grep -q "$secret" "$SECRETS_FILE"; then
      echo "MISSING: $secret not found in SECRETS_FOR_PASSWORD_MANAGER.md"
      ((LEAKED++))
    fi
  done
fi

if [[ $LEAKED -gt 0 ]]; then
  echo "Secret leak check: FAILED ($LEAKED issues)"
  exit 1
fi

echo "Secret leak check: OK"
