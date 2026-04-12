#!/usr/bin/env bash
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAILURES=0
PASSED=0

run_test() {
  local name="$1" script="$2"
  shift 2
  printf "  %-40s " "$name"
  if bash "$script" "$@" > /dev/null 2>&1; then
    echo "PASS"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL"
    FAILURES=$((FAILURES + 1))
    # Re-run with output for debugging
    echo "    --- output ---"
    bash "$script" "$@" 2>&1 | sed 's/^/    /'
    echo "    --- end ---"
  fi
}

echo ""
echo "Running dotfiles-sync tests..."
echo ""

run_test "ShellCheck"         "$TESTS_DIR/test-shellcheck.sh"
run_test "Generator syntax"   "$TESTS_DIR/test-generator-syntax.sh"
run_test "No secret leaks"    "$TESTS_DIR/test-no-secrets.sh"

# Golden tests only if golden files exist
if [[ -f "$TESTS_DIR/fixtures/golden/setup-new-mac.golden.sh" ]]; then
  run_test "Golden files"     "$TESTS_DIR/test-golden.sh" "${1:-}"
else
  echo "  Golden files                           SKIP (run with --update-golden first)"
fi

echo ""
echo "Results: $PASSED passed, $FAILURES failed"
exit $FAILURES
