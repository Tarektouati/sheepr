#!/usr/bin/env bash
# bin/sheepr-watch.sh - the supervision loop. Burns no tokens.
#
# Usage:
#   sheepr-watch.sh           poll until something is actionable, then exit
#   sheepr-watch.sh --once    one pass, no sleeping (tests, diagnosis)
#   sheepr-watch.sh --hook    as default, but print a Cursor followup_message
#
# Owns: deciding whether the fleet needs the supervisor's attention, and the
# wake queue.
#
# Refuses:
#   - to treat a herdr `idle` as proof that a worker has stopped. Only
#     `working` is positive evidence of life; everything else must be
#     corroborated by the status log or by file writes in the worktree.
#   - to wake twice for the same thing. Each wake records a signature; an
#     unchanged signature is absorbed to the triage log instead.
#
# The decision ladder, per task, first match wins:
#
#   1. Fold the status log. question / blocked / done / failed -> wake.
#   2. Ask herdr. blocked -> wake. missing -> try label recovery, then wake.
#      working -> alive, next task.
#   3. idle / done / unknown prove nothing. Look for evidence of life: has the
#      status log grown, or has any file in the worktree changed inside the
#      quiet window? If neither, and the window is older than SHEEPR_STALL,
#      wake as stalled.

set -uo pipefail

# shellcheck source=bin/sheepr-herdr.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sheepr-herdr.sh"
# shellcheck source=bin/sheepr-status.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sheepr-status.sh"

SHEEPR_POLL=${SHEEPR_POLL:-15}
SHEEPR_STALL=${SHEEPR_STALL:-240}
SHEEPR_SCAN_MAXDEPTH=${SHEEPR_SCAN_MAXDEPTH:-6}
SHEEPR_SCAN_TIMEOUT=${SHEEPR_SCAN_TIMEOUT:-10}
# How long the turn-end hook may park before giving the turn back. A hook that
# parks forever on an idle fleet makes the supervisor look hung.
SHEEPR_HOOK_MAX=${SHEEPR_HOOK_MAX:-3600}

TRIAGE="$SHEEPR_TASKS/.watch-triage.log"
WATCH_LOCK="$SHEEPR_TASKS/.watch.lock"

MODE=loop

triage() {  # <task-id> <verdict>
  mkdir -p "$(dirname "$TRIAGE")"
  printf '%s|%s|%s\n' "$(sheepr_now)" "$1" "$2" >>"$TRIAGE"
}

# --- evidence of life -------------------------------------------------------

# Has any file under the worktree changed since <ref-file> was touched?
# 0 yes, 1 no, 2 could not tell.
#
# Bounded three ways: a depth cap, a prune list, and a wall clock. There is no
# `timeout` binary on macOS, so the wall clock is enforced here.
worktree_written_since() {  # <worktree> <ref-file>
  local wt=$1 ref=$2 out pid waited=0
  [ -d "$wt" ] || return 2
  [ -f "$ref" ] || return 2
  out=$(mktemp "${TMPDIR:-/tmp}/sheepr-scan-XXXXXX") || return 2

  find "$wt" -maxdepth "$SHEEPR_SCAN_MAXDEPTH" \
      \( -name .git -o -name node_modules -o -name target \
         -o -name dist -o -name build -o -name .venv \
         -o -name __pycache__ -o -name .next \) -prune -o \
      -type f -newer "$ref" -print -quit >"$out" 2>/dev/null &
  pid=$!

  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$SHEEPR_SCAN_TIMEOUT" ]; then
      kill -9 "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      rm -f "$out"
      return 2
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid" 2>/dev/null

  if [ -s "$out" ]; then rm -f "$out"; return 0; fi
  rm -f "$out"
  return 1
}

# --- per task ---------------------------------------------------------------

# Print "<signature>\t<reason>" when the task is actionable, nothing when not.
inspect_task() {  # <task-id>
  local id=$1 dir fold state key text agent
  dir=$(sheepr_task_dir "$id")

  # 1. the status log is authoritative about what the worker has said
  fold=$(sheepr_status_fold "$id")
  state=${fold%%|*}
  key=$(printf '%s' "$fold" | cut -d'|' -f2)
  text=$(printf '%s' "$fold" | cut -d'|' -f3-)

  case "$state" in
    question) printf '%s\t%s' "q:$key:$text" "question: $id - ${key}: $text"; return 0 ;;
    blocked)  printf '%s\t%s' "b:$key:$text" "blocked: $id - $text"; return 0 ;;
    done)     printf '%s\t%s' "d:$text" "done: $id - $text"; return 0 ;;
    failed)   printf '%s\t%s' "f:$text" "failed: $id - $text"; return 0 ;;
  esac

  # 2. ask herdr
  local name
  name=$(sheepr_meta_get "$id" name) || name="sheepr-$id"
  agent=$(sheepr_agent_state "$name")

  if [ "$agent" = missing ]; then
    # Pane and workspace ids do not survive a herdr server restart; the label
    # does. Try to re-resolve before reporting the worker as gone.
    local label ws pane
    label=$(sheepr_meta_get "$id" label) || label="sheepr-$id"
    if ws=$(sheepr_workspace_by_label "$label") && pane=$(sheepr_pane_of "$ws"); then
      sheepr_meta_set "$id" workspace "$ws"
      sheepr_meta_set "$id" pane "$pane"
      agent=$(sheepr_agent_state "$pane")
      [ "$agent" = missing ] || triage "$id" "recovered endpoint by label -> $ws/$pane"
    fi
  fi

  case "$agent" in
    blocked) printf '%s\t%s' "agent:blocked" "blocked: $id - the worker is parked at a dialog"; return 0 ;;
    missing) printf '%s\t%s' "agent:missing" "missing: $id - no agent at the recorded endpoint"; return 0 ;;
    working) rm -f "$dir/.quiet-since"; triage "$id" "working"; return 1 ;;
  esac

  # 3. idle, done, unknown: prove nothing. Look for evidence of life.
  local size prev
  size=$(wc -c <"$(sheepr_status_file "$id")" 2>/dev/null | tr -d ' ') || size=0
  prev=$(cat "$dir/.seen-size" 2>/dev/null || printf '0')
  printf '%s' "$size" >"$dir/.seen-size"
  if [ "$size" != "$prev" ]; then
    rm -f "$dir/.quiet-since"
    triage "$id" "status log grew ($prev -> $size)"
    return 1
  fi

  # The quiet window starts the first time we see no progress.
  if [ ! -f "$dir/.quiet-since" ]; then
    touch "$dir/.quiet-since"
    triage "$id" "quiet window opened (agent=$agent)"
    return 1
  fi

  local began age
  began=$(stat -f %m "$dir/.quiet-since" 2>/dev/null || stat -c %Y "$dir/.quiet-since" 2>/dev/null) || began=0
  age=$(( $(sheepr_now) - began ))
  if [ "$age" -lt "$SHEEPR_STALL" ]; then
    triage "$id" "quiet ${age}s of ${SHEEPR_STALL}s (agent=$agent)"
    return 1
  fi

  local wt
  wt=$(sheepr_meta_get "$id" worktree) || wt=''
  worktree_written_since "$wt" "$dir/.quiet-since"
  case $? in
    0)
      # Files are still being written behind a static display. That is life.
      rm -f "$dir/.quiet-since"
      triage "$id" "worktree written during the quiet window"
      return 1
      ;;
    2) triage "$id" "worktree scan inconclusive; treating as no evidence" ;;
  esac

  printf '%s\t%s' "stalled:$began" \
    "stalled: $id - agent reads $agent, no status and no file writes for ${age}s"
  return 0
}

# --- one pass ---------------------------------------------------------------

# Prints the reason and returns 0 when something is actionable.
pass_once() {
  local id out sig reason last dir
  while read -r id; do
    [ -n "$id" ] || continue
    out=$(inspect_task "$id") || continue
    sig=${out%%$'\t'*}
    reason=${out#*$'\t'}
    dir=$(sheepr_task_dir "$id")
    last=$(cat "$dir/.woke" 2>/dev/null || printf '')
    if [ "$sig" = "$last" ]; then
      triage "$id" "absorbed (already woke for: $sig)"
      continue
    fi
    printf '%s' "$sig" >"$dir/.woke"
    mkdir -p "$(dirname "$SHEEPR_WAKES")"
    printf '%s|%s|%s\n' "$(sheepr_now)" "$id" "$reason" >>"$SHEEPR_WAKES"
    printf '%s\n' "$reason"
    return 0
  done < <(sheepr_task_ids)
  return 1
}

# --- main -------------------------------------------------------------------
#
# Only when executed. Tests source this file and drive inspect_task directly.

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-}" in
    --once) MODE=once ;;
    --hook) MODE=hook ;;
    '') MODE=loop ;;
    *) die "usage: sheepr-watch.sh [--once|--hook]" ;;
  esac

  sheepr_ensure_home
  command -v herdr >/dev/null 2>&1 || die "herdr not found"
  command -v jq >/dev/null 2>&1 || die "jq not found"

  if [ "$MODE" = once ]; then
    pass_once
    exit $?
  fi

  # An empty fleet has nothing to supervise. Give the turn straight back
  # rather than parking, or every turn on an idle repo looks hung.
  if [ -z "$(sheepr_task_ids)" ]; then
    exit 0
  fi

  if ! sheepr_lock_acquire "$WATCH_LOCK"; then
    # Another watcher owns the fleet. Say nothing and leave.
    exit 0
  fi
  # The lock is released on EXIT only. A handler that released it on INT or
  # TERM did not stop the loop: the watcher carried on polling with no lock,
  # and a second watcher could take it and race this one on .woke, .seen-size
  # and .quiet-since. Exiting from the signal handlers runs the EXIT trap.
  trap 'sheepr_lock_release "$WATCH_LOCK"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  started=$(sheepr_now)
  while :; do
    if reason=$(pass_once); then
      if [ "$MODE" = hook ]; then
        # Cursor ignores exit code 2; a followup_message on stdout is the only
        # channel that reaches the session.
        printf '{"followup_message": %s}\n' "$(printf '%s' "$reason" | jq -Rs .)"
      else
        printf '%s\n' "$reason"
      fi
      exit 0
    fi
    # Every task has gone quiet for good (all torn down, or all absorbed and
    # terminal). Nothing further can arrive from a fleet with no tasks.
    if [ -z "$(sheepr_task_ids)" ]; then
      exit 0
    fi
    if [ "$MODE" = hook ] && [ $(( $(sheepr_now) - started )) -ge "$SHEEPR_HOOK_MAX" ]; then
      # Hand the turn back. The next turn re-arms the hook.
      exit 0
    fi
    sleep "$SHEEPR_POLL"
  done
fi
