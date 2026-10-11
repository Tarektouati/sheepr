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

# Harness session logs, too: usage must never be read from the real ones.
# Empty by default; tests/sheepr-usage.test.sh points these at fixtures.
SHEEPR_CLAUDE_HOME="$SHEEPR_HOME/claude-home"
CODEX_HOME="$SHEEPR_HOME/codex-home"
export SHEEPR_CLAUDE_HOME CODEX_HOME

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

# --- fake flock -------------------------------------------------------------
#
# Point sheepr at tests/fake-flock and feed it a canned status document, so
# gates are tested without a live Herdr, a real remote, or gh.

use_fake_flock() {
  SHEEPR_FLOCK="$SHEEPR_ROOT/tests/fake-flock"
  FAKE_FLOCK_JSON="$SHEEPR_HOME/flock-status.json"
  export SHEEPR_FLOCK FAKE_FLOCK_JSON
}

# Build one worktree row. Defaults describe a clean, landed-nowhere worktree;
# pass jq assignments to change individual fields.
#   flock_row /path/to/wt 'sheepr/x' '.dirty = 3 | .ahead = 2'
flock_row() {  # <path> <branch> [jq-overrides]
  jq -nc --arg p "$1" --arg b "$2" '{
    branch: $b, path: $p, linked: true, prunable: false, detached: false,
    exists: true, head: "deadbeef", workspace_id: "w9", agents: [],
    dirty: 0, ahead: 0, behind: 0,
    upstream: null, upstream_gone: false, unpushed: null,
    contained_in_base: true, pr: null
  }' | jq -c "${3:-.}"
}

# Write a status document made of the given rows into the fake's fixture.
flock_doc() {  # <row-json>...
  local rows
  rows=$(printf '%s\n' "$@" | jq -sc '.')
  jq -nc --argjson w "$rows" '{
    repo_root: "/repo", repo_name: "repo", base: "main",
    base_ref: "origin/main", pr_lookup: true, worktrees: $w
  }' >"$FAKE_FLOCK_JSON"
}

# Run a command under a wall-clock bound and print what it printed. There is
# no `timeout` binary on macOS, so the bound is enforced here. Returns 124 when
# the command was still running at the bound: a test for a hang must fail, not
# hang the suite with it.
run_bounded() {  # <seconds> <command...>
  local limit=$1; shift
  local out pid rc waited=0
  out=$(mktemp "${TMPDIR:-/tmp}/sheepr-bound-XXXXXX") || return 125
  "$@" >"$out" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$limit" ]; then
      # The command may have forked; a spinning grandchild left behind would
      # burn a core for the rest of the session.
      pkill -9 -P "$pid" 2>/dev/null
      kill -9 "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      cat "$out"; rm -f "$out"
      return 124
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid"; rc=$?
  cat "$out"; rm -f "$out"
  return "$rc"
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
