#!/usr/bin/env bash
# tests/fake-flock/scripts/wt-status.sh - a stand-in for flock's wt-status.sh.
#
# The real one requires a live Herdr, a real repository, and reaches the forge
# through gh. None of that belongs in a unit test, so this prints whatever
# document the test put in $FAKE_FLOCK_JSON and ignores its arguments.
#
# Set FAKE_FLOCK_FAIL=1 to simulate flock failing.
#
# This file exists so sheepr's own gates are tested, not flock's. flock's
# analysis is flock's to test.

set -u

[ "${FAKE_FLOCK_FAIL:-0}" = 1 ] && {
  printf 'fake-flock: simulated failure\n' >&2
  exit 1
}

if [ -n "${FAKE_FLOCK_JSON:-}" ] && [ -f "$FAKE_FLOCK_JSON" ]; then
  cat "$FAKE_FLOCK_JSON"
  exit 0
fi

# No fixture: an empty repository with no worktrees.
printf '%s\n' '{"repo_root":"/nowhere","repo_name":"nowhere","base":"main","base_ref":"origin/main","pr_lookup":false,"worktrees":[]}'
