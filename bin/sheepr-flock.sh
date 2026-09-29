#!/usr/bin/env bash
# bin/sheepr-flock.sh - the flock adapter. THE ONLY file that runs flock.
#
# Owns: locating the flock skill, and every call into its scripts.
#
# Refuses:
#   - to source flock's own lib.sh. Both libraries define die(), and sourcing
#     flock's would silently replace ours with different semantics. The
#     contract between the two projects is flock's JSON output, nothing else.
#   - to continue when flock is absent. sheepr does not carry a second,
#     worse copy of this analysis to fall back on.
#
# Why sheepr depends on flock at all: flock already resolves a repository's
# base branch correctly, compares against the remote base so merges done on
# the forge are visible, and knows that a merged pull request only counts when
# it merged the current HEAD. sheepr had hand-rolled versions of all three and
# two of them were wrong.
#
# flock: https://github.com/Tarektouati/skills/tree/main/flock

# shellcheck source=bin/sheepr-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sheepr-lib.sh"

# Where flock may be installed, in order. SHEEPR_FLOCK overrides everything,
# which is also how the tests point at a fake.
sheepr_flock_dir() {
  local d
  for d in "${SHEEPR_FLOCK:-}" "$HOME/.agents/skills/flock" "$HOME/.claude/skills/flock"; do
    [ -n "$d" ] || continue
    [ -x "$d/scripts/wt-status.sh" ] || continue
    printf '%s' "$d"
    return 0
  done
  return 1
}

# Fail now, in the caller's own shell, if flock is missing.
#
# Call this before any loop that reads flock. A die() inside a command
# substitution only kills the subshell, so a missing flock would otherwise
# read as "this one repository could not be read" and the command would
# carry on and exit 0.
sheepr_flock_require() {
  sheepr_flock_dir >/dev/null || die \
"the flock skill is required but was not found.
  Looked in: \$SHEEPR_FLOCK, ~/.agents/skills/flock, ~/.claude/skills/flock
  Install it from https://github.com/Tarektouati/skills, or set SHEEPR_FLOCK."
}

# The whole repository's worktree, agent and pull-request state, as JSON.
# See flock's scripts/wt-status.sh for the shape.
sheepr_flock_status() {  # <repo-path>
  local dir out
  dir=$(sheepr_flock_dir) || { warn "the flock skill is not installed"; return 1; }

  out=$("$dir/scripts/wt-status.sh" --cwd "$1" --json 2>&1) || {
    warn "flock wt-status.sh failed for $1:"
    printf '%s\n' "$out" | head -5 >&2
    return 1
  }
  printf '%s' "$out"
}

# Resolve a path to its physical form so a symlinked prefix (/tmp against
# /private/tmp on macOS) cannot make two names for one directory look
# different when they are compared.
sheepr_realpath() {  # <path>
  local p=$1
  if [ -d "$p" ]; then (cd "$p" 2>/dev/null && pwd -P) && return 0; fi
  printf '%s' "$p"
}

# One worktree's row out of a status document, matched by path.
# Returns 1 when the repository has no worktree at that path.
sheepr_flock_row() {  # <status-json> <worktree-path>
  local real row
  real=$(sheepr_realpath "$2")
  row=$(printf '%s' "$1" | jq -c --arg p "$2" --arg r "$real" \
    '[.worktrees[] | select(.path == $p or .path == $r)][0] // empty') || return 1
  [ -n "$row" ] || return 1
  printf '%s' "$row"
}

sheepr_flock_base_ref() {  # <status-json>
  printf '%s' "$1" | jq -r '.base_ref // .base // "main"'
}
