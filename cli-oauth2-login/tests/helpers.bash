# Shared helpers for the bats test suite.
#
# The suite manages its own per-test temp directory (TEST_TMPDIR) instead of
# relying on BATS_TEST_TMPDIR, which only exists in bats >= 1.4.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
SCRIPT="$REPO_ROOT/oidc-discovery-override.sh"
FIXTURES="$BATS_TEST_DIRNAME/fixtures"

common_setup() {
  TEST_TMPDIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/oidc-discovery-override-test.XXXXXX")"
}

common_teardown() {
  if [[ -n ${TEST_TMPDIR:-} && -d $TEST_TMPDIR ]]; then
    rm -rf "$TEST_TMPDIR"
  fi
}

assert_contains() {
  if [[ $1 != *"$2"* ]]; then
    echo "expected to find: $2"
    echo "in:               $1"
    return 1
  fi
}

assert_equal() {
  if [[ $1 != "$2" ]]; then
    echo "expected: $2"
    echo "actual:   $1"
    return 1
  fi
}
