#!/usr/bin/env bash
# tests/lib.sh - the shared test harness.
#
# Owns: pass/fail counting, the temporary SHEEPR_HOME every test runs against,
# and the gate that skips tests needing a live Herdr.
#
# Refuses: to let a test touch the real tasks directory. SHEEPR_HOME is always
# redirected to a temporary directory created here.

set -uo pipefail

SHEEPR_ROOT="${SHEEPR_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export SHEEPR_ROOT

TESTS_PASS=0
TESTS_FAIL=0
TESTS_SKIP=0
TEST_NAME=$(basename "${0%.test.sh}")

SHEEPR_HOME=$(mktemp -d "${TMPDIR:-/tmp}/sheepr-test-XXXXXX")
export SHEEPR_HOME
mkdir -p "$SHEEPR_HOME/tasks"

cleanup_home() { [ -n "${SHEEPR_HOME:-}" ] && rm -rf "$SHEEPR_HOME"; }
trap cleanup_home EXIT

ok() {  # <description>
  TESTS_PASS=$((TESTS_PASS + 1))
  printf '  ok   %s\n' "$1"
}

fail() {  # <description> [detail...]
  TESTS_FAIL=$((TESTS_FAIL + 1))
  printf '  FAIL %s\n' "$1"
  shift
  local l
  for l in "$@"; do printf '       %s\n' "$l"; done
}

skip() {  # <reason>
  TESTS_SKIP=$((TESTS_SKIP + 1))
  printf '  skip: %s\n' "$1"
}

is() {  # <got> <want> <description>
  if [ "$1" = "$2" ]; then
    ok "$3"
  else
    fail "$3" "want: $2" "got:  $1"
  fi
}

# Skip the rest of a file unless a live Herdr session is reachable.
need_herdr() {
  if [ "${HERDR_ENV:-}" != 1 ] || ! command -v herdr >/dev/null 2>&1; then
    skip "no live Herdr session (HERDR_ENV is not 1)"
    summary
    exit 0
  fi
}

# Write a status log for <task-id> from stdin.
write_status() {  # <task-id>
  mkdir -p "$SHEEPR_HOME/tasks/$1"
  cat >"$SHEEPR_HOME/tasks/$1/status"
}

begin() { printf 'FM_TEST_BEGIN %s\n' "$TEST_NAME"; }

summary() {
  printf 'FM_TEST_SUMMARY %s pass=%d fail=%d skip=%d\n' \
    "$TEST_NAME" "$TESTS_PASS" "$TESTS_FAIL" "$TESTS_SKIP"
  [ "$TESTS_FAIL" -eq 0 ]
}

finish() {
  summary
  exit $?
}
