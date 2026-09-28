#!/usr/bin/env bash
# bin/sheepr-lib.sh - shared paths, task metadata, and locking.
#
# Owns: the location of the sheepr home and its tasks directory, the key=value
# metadata format, the wake queue path, and the single directory-lock helper
# every script uses.
#
# Refuses: nothing. This file has no side effects beyond creating the tasks
# directory on demand. It never runs `herdr` and never touches a project.
#
# Sourced by every other script in bin/. Not executable on its own.

set -o pipefail

# SHEEPR_ROOT is the checkout that holds bin/. SHEEPR_HOME is where task state
# lives; tests override it to a temporary directory.
SHEEPR_ROOT="${SHEEPR_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SHEEPR_HOME="${SHEEPR_HOME:-$SHEEPR_ROOT}"
SHEEPR_TASKS="$SHEEPR_HOME/tasks"
SHEEPR_WAKES="$SHEEPR_TASKS/.wakes"

# Task ids must be safe as a directory name, a git branch component, and a
# herdr agent name. herdr requires [a-z][a-z0-9_-]{0,31} and we prefix with
# "sheepr-" (7 characters), so the id itself is capped at 25.
SHEEPR_ID_RE='^[a-z][a-z0-9-]{0,24}$'

die() { printf 'sheepr: %s\n' "$*" >&2; exit 1; }
warn() { printf 'sheepr: %s\n' "$*" >&2; }

sheepr_require_tools() {
  local t
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 || die "required tool not found: $t"
  done
}

sheepr_validate_id() {
  local id=${1:-}
  [ -n "$id" ] || die "task id is empty"
  [[ $id =~ $SHEEPR_ID_RE ]] || die "task id '$id' must match $SHEEPR_ID_RE"
}

sheepr_task_dir() { printf '%s/%s' "$SHEEPR_TASKS" "$1"; }
sheepr_status_file() { printf '%s/%s/status' "$SHEEPR_TASKS" "$1"; }
sheepr_meta_file() { printf '%s/%s/meta' "$SHEEPR_TASKS" "$1"; }

sheepr_task_exists() { [ -f "$(sheepr_meta_file "$1")" ]; }

# List every task that has a meta file, one id per line.
sheepr_task_ids() {
  [ -d "$SHEEPR_TASKS" ] || return 0
  local d
  for d in "$SHEEPR_TASKS"/*/; do
    [ -f "$d/meta" ] || continue
    basename "$d"
  done
}

# --- metadata: one key=value per line, last write wins ----------------------

sheepr_meta_get() {  # <task-id> <key>
  local f
  f=$(sheepr_meta_file "$1")
  [ -f "$f" ] || return 1
  local line
  line=$(grep -E "^$2=" "$f" | tail -1) || return 1
  [ -n "$line" ] || return 1
  printf '%s' "${line#*=}"
}

sheepr_meta_set() {  # <task-id> <key> <value>
  local f tmp
  f=$(sheepr_meta_file "$1")
  mkdir -p "$(dirname "$f")"
  tmp="$f.tmp.$$"
  # Drop any existing line for this key, then append the new one.
  { [ -f "$f" ] && grep -vE "^$2=" "$f"; printf '%s=%s\n' "$2" "$3"; } >"$tmp" 2>/dev/null || {
    printf '%s=%s\n' "$2" "$3" >"$tmp"
  }
  mv -f "$tmp" "$f"
}

# --- locking ----------------------------------------------------------------

# A lock is a directory plus a pid file. mkdir is atomic on every filesystem we
# care about. A lock whose holder is gone is reclaimed.
sheepr_lock_acquire() {  # <lock-path>
  local lock=$1 held
  mkdir -p "$(dirname "$lock")"
  if mkdir "$lock" 2>/dev/null; then
    printf '%s' "$$" >"$lock/pid"
    return 0
  fi
  held=$(cat "$lock/pid" 2>/dev/null || printf '')
  if [ -n "$held" ] && kill -0 "$held" 2>/dev/null; then
    return 1
  fi
  # Stale: the recorded holder is not running.
  rm -rf "$lock"
  if mkdir "$lock" 2>/dev/null; then
    printf '%s' "$$" >"$lock/pid"
    return 0
  fi
  return 1
}

sheepr_lock_release() {  # <lock-path>
  rm -rf "$1"
}

sheepr_now() { date +%s; }

sheepr_ensure_home() {
  mkdir -p "$SHEEPR_TASKS"
}
