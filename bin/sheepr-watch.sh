#!/usr/bin/env bash
# bin/sheepr-watch.sh - the supervision loop. Burns no tokens.
#
# Usage:
#   sheepr-watch.sh                   poll until something is actionable, print
#                                     it, exit. Cursor runs this as a
#                                     background shell; finishing wakes it.
#   sheepr-watch.sh --once            one pass, no sleeping. Exit 0 woke,
#                                     1 quiet, 3 another watcher owns the fleet
#   sheepr-watch.sh --hook cursor     Cursor stop hook: one pass, never parks.
#                                     `--hook` alone means this.
#   sheepr-watch.sh --hook claude     Claude Code Stop hook with asyncRewake:
#                                     poll in the background, exit 2 to wake
#   sheepr-watch.sh --hook codex      Codex async Stop hook: start a detached
#                                     --wake-pane watcher and return at once
#   sheepr-watch.sh --wake-pane <id>  poll; deliver the wake into that Herdr
#                                     pane once its agent is idle
#
# Owns: deciding whether the fleet needs the supervisor's attention, and the
# wake queue.
#
# One watcher owns the fleet: every mode that writes task state holds
# tasks/.watch.lock, and every other mode leaves without touching anything.
#
# A wake is delivered first and recorded (.woke, tasks/.wakes) second. Dying
# between the two repeats a wake on the next pass; the reverse order would
# record a wake nobody received and absorb it forever.
#
# Refuses:
#   - to type into a Herdr pane that holds no agent. Text submitted to a bare
#     shell runs as a command. The wake stays unrecorded for the next session.
#   - to treat a herdr `idle` as proof that a worker has stopped. Only
#     `working` is positive evidence of life; everything else must be
#     corroborated by the status log or by file writes in the worktree.
#   - to wake twice for the same thing. Each wake records a signature; an
#     unchanged signature is absorbed to the triage log instead. A done is
#     also remembered in .done-woke, so a review's wakes in between do not
#     bring it round again; a reopened task forgets it.
#   - to discard work over a budget. Crossing it interrupts the current turn;
#     the session, the worktree and the status log are all kept.
#
# The decision ladder, per task, first match wins:
#
#   0. A review is open (bin/sheepr-review.sh start) and the fold is done:
#      the review's own ladder runs instead, see inspect_review. It reads the
#      reviewer pane through the Herdr adapter and wakes `reviewed: <id>` on
#      the sentinel. This is the one place the watcher reads a terminal to
#      decide anything; the reviewer writes no status log. Without the
#      sentinel it applies the reviewer's budget, `missing:`, `blocked:` and
#      the usual `stalled:` rules.
#
#   1. Budget, when meta has one and the log is not done or failed. Read the
#      usage with bin/sheepr-usage.sh. Spent is input + output: fresh input
#      tokens plus output tokens. Cache reads and cache creation do not count
#      toward a budget. At or over the budget -> interrupt the worker if herdr
#      says it is working (every pass, so nothing more is spent), and wake
#      `overbudget: <id> <spent>/<budget>` once per budget. Raising the budget
#      (sheepr-send.sh --budget) re-arms it. Usage `unknown` -> wake
#      `warning: <id> budget not enforced (<reason>)` once per budget. A
#      reason that can clear by itself (no session or no counts yet, as at
#      spawn) is warned only once it has lasted SHEEPR_STALL seconds. Once
#      either wake is delivered, the ladder carries on below it, so a later
#      question or done still wakes.
#   2. Fold the status log. question / blocked / done / failed -> wake.
#   3. Ask herdr. blocked -> wake. missing -> try label recovery, then wake.
#      working -> alive, next task.
#   4. idle / done / unknown prove nothing. Look for evidence of life: has the
#      status log grown, or has any file in the worktree changed inside the
#      quiet window? If neither, and the window is older than SHEEPR_STALL,
#      wake as stalled.
#
# Every wake is one line. Text quoted from a status log is cut to
# SHEEPR_EXCERPT characters (120): the wake lands in the supervisor's context,
# and the full line is one `sheepr-status.sh fold` away.

set -uo pipefail

# shellcheck source=bin/sheepr-herdr.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sheepr-herdr.sh"
# shellcheck source=bin/sheepr-status.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sheepr-status.sh"

SHEEPR_POLL=${SHEEPR_POLL:-15}
SHEEPR_STALL=${SHEEPR_STALL:-240}
SHEEPR_SCAN_MAXDEPTH=${SHEEPR_SCAN_MAXDEPTH:-6}
SHEEPR_SCAN_TIMEOUT=${SHEEPR_SCAN_TIMEOUT:-10}
# How long a background watcher started by a turn-end hook may wait. It must
# stay below the hook timeout in .claude/settings.json (28800), or the harness
# can kill it between delivering a wake and recording it.
SHEEPR_HOOK_MAX=${SHEEPR_HOOK_MAX:-28000}
SHEEPR_EXCERPT=${SHEEPR_EXCERPT:-120}

TRIAGE="$SHEEPR_TASKS/.watch-triage.log"
WATCH_LOCK="$SHEEPR_TASKS/.watch.lock"
PANE_LOG="$SHEEPR_TASKS/.watch-pane.log"

REARM_MESSAGE="sheepr: no watcher is running. Start ./bin/sheepr-watch.sh as a background command, then end your turn."

MODE=loop
PANE=''

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

# --- budget -----------------------------------------------------------------

# One line of at most SHEEPR_EXCERPT characters. Control characters, tabs and
# newlines among them, become spaces: a tab would split the wake record.
excerpt() {  # <text>
  local t=${1//[[:cntrl:]]/ }
  if [ "${#t}" -gt "$SHEEPR_EXCERPT" ]; then
    t="${t:0:$((SHEEPR_EXCERPT - 3))}..."
  fi
  printf '%s' "$t"
}

# The usage adapter's one-line answer for a task's worker, or with <mode>
# `review`, for its reviewer. A function so the tests can put their own
# answer in its place.
task_usage() {  # <task-id> [task|review]
  bash "$SHEEPR_ROOT/bin/sheepr-usage.sh" "${2:-task}" "$1" 2>/dev/null
}

# Ladder step 1, and the review's own budget step. Print
# "<signature>\t<reason>" and return 0 when the budget needs the supervisor,
# return 1 when it does not.
#
# A budget wake is remembered apart from .woke (in .budget-woke, or
# .review-budget-woke for the reviewer, written by commit_wake), because .woke
# is overwritten by the next wake of any kind, and the budget wake would then
# come round again after every question.
#
# <role> is `worker` (the default) or `reviewer`. The reviewer's budget is
# meta's review_budget, its usage is `sheepr-usage.sh review`, its agent is
# review_name, and its signatures carry an `rv-` prefix.
inspect_budget() {  # <task-id> <dir> [role]
  local id=$1 dir=$2 role=${3:-worker} budget out spent name reason sig began
  local bkey=budget umode=task woke="$dir/.budget-woke" since="$dir/.usage-unknown-since" p='' who=''
  if [ "$role" = reviewer ]; then
    bkey=review_budget umode=review woke="$dir/.review-budget-woke"
    since="$dir/.review-usage-unknown-since" p='rv-' who='reviewer '
  fi
  budget=$(sheepr_meta_get "$id" "$bkey") || return 1
  [ -n "$budget" ] || return 1
  [[ $budget =~ ^[1-9][0-9]*$ ]] || {
    sig="${p}budget-bad:$budget"
    [ "$(cat "$woke" 2>/dev/null)" = "$sig" ] && return 1
    printf '%s\t%s' "$sig" "warning: $id ${who}budget not enforced (meta $bkey '$(excerpt "$budget")' is not a token count)"
    return 0
  }
  out=$(task_usage "$id" "$umode") || out=''
  [ -n "$out" ] || out='unknown usage-unreadable'

  case "$out" in
    unknown\ *)
      reason=${out#unknown }
      sig="${p}warning:$budget"
      [ "$(cat "$woke" 2>/dev/null)" = "$sig" ] && return 1
      case "$reason" in
        *-no-session|*-no-usage)
          # Normal for an agent that has only just started. Give it the stall
          # window to write its first counts before calling it unenforced.
          [ -f "$since" ] || touch "$since"
          began=$(stat -f %m "$since" 2>/dev/null || stat -c %Y "$since" 2>/dev/null) || began=0
          if [ $(( $(sheepr_now) - began )) -lt "$SHEEPR_STALL" ]; then
            triage "$id" "${who}usage unknown ($reason); waiting before warning"
            return 1
          fi
          ;;
      esac
      printf '%s\t%s' "$sig" "warning: $id ${who}budget not enforced ($(excerpt "$reason"))"
      return 0
      ;;
  esac
  rm -f "$since"

  # <total> <input> <output> <source>. Input already excludes cache tokens.
  local input output
  read -r _ input output _ <<<"$out"
  if ! [[ $input =~ ^[0-9]+$ && $output =~ ^[0-9]+$ ]]; then
    triage "$id" "${who}usage unparseable: $(excerpt "$out")"
    sig="${p}warning:$budget"
    [ "$(cat "$woke" 2>/dev/null)" = "$sig" ] && return 1
    printf '%s\t%s' "$sig" "warning: $id ${who}budget not enforced (usage unparseable)"
    return 0
  fi
  spent=$((input + output))
  [ "$spent" -ge "$budget" ] || return 1

  # Over. Stop the spending first, whether or not the wake is new: an agent
  # resumed without a raised budget is stopped again.
  if [ "$role" = reviewer ]; then
    name=$(sheepr_meta_get "$id" review_name) || name="rv-$id"
  else
    name=$(sheepr_meta_get "$id" name) || name="sheepr-$id"
  fi
  local note=''
  if [ "$(sheepr_agent_state "$name")" = working ]; then
    if sheepr_agent_interrupt "$name"; then
      triage "$id" "${who}over budget ($spent/$budget); interrupted"
    else
      triage "$id" "${who}over budget ($spent/$budget); interrupt FAILED"
      note=" (interrupt failed; the ${who:-worker }may still be spending)"
      note=${note/  / }
    fi
  fi

  # A failed interrupt is a different thing to report than a clean one.
  sig="${p}over:$budget"
  [ -z "$note" ] || sig="$sig:interrupt-failed"
  [ "$(cat "$woke" 2>/dev/null)" = "$sig" ] && return 1
  printf '%s\t%s' "$sig" "overbudget: $id ${who}$spent/$budget$note"
  return 0
}

# --- the review ---------------------------------------------------------------

# A short fingerprint of what the reviewer pane shows, for evidence of life.
pane_fingerprint() {  # <text>
  printf '%s' "$1" | cksum | cut -d' ' -f1
}

# The review's own ladder, used instead of the worker's while a review is
# open on a done task. Print "<signature>\t<reason>" when actionable.
#
#   1. The reviewer's budget (review_budget), as for a worker.
#   2. The sentinel in the reviewer pane, read through the Herdr adapter.
#      Found -> `reviewed: <id>`, once per review.
#   3. Ask herdr about the reviewer. missing -> `missing:`, blocked ->
#      `blocked:`, working -> alive.
#   4. Otherwise the usual stall rules: a quiet window of SHEEPR_STALL
#      seconds with no change in the pane and no file written in the worktree
#      -> `stalled:`.
inspect_review() {  # <task-id> <dir>
  local id=$1 dir=$2 pane name nonce text agent
  pane=$(sheepr_meta_get "$id" review_pane) || pane=''
  name=$(sheepr_meta_get "$id" review_name) || name="rv-$id"
  nonce=$(sheepr_meta_get "$id" review_started) || nonce=''

  # The reviewer's session id appears only once it has taken a turn.
  if [ -z "$(sheepr_meta_get "$id" review_session 2>/dev/null)" ]; then
    sheepr_review_record_session "$id" "$name" 1 >/dev/null 2>&1 || true
  fi

  inspect_budget "$id" "$dir" reviewer && return 0

  if text=$(sheepr_pane_read "$pane" 60); then
    if sheepr_marker_line "$text" "$(sheepr_review_marker DONE "$nonce")" >/dev/null; then
      printf '%s\t%s' "reviewed:$nonce" "reviewed: $id - the reviewer printed its findings"
      return 0
    fi
  else
    text=''
  fi

  agent=$(sheepr_agent_state "$name")
  case "$agent" in
    missing) printf '%s\t%s' "rv-missing:$nonce" "missing: $id - no reviewer at the recorded pane"; return 0 ;;
    blocked) printf '%s\t%s' "rv-blocked:$nonce" "blocked: $id - the reviewer is parked at a dialog"; return 0 ;;
    working) rm -f "$dir/.review-quiet-since"; triage "$id" "reviewer working"; return 1 ;;
  esac

  local fp prev
  fp=$(pane_fingerprint "$text")
  prev=$(cat "$dir/.review-seen" 2>/dev/null || printf '')
  printf '%s' "$fp" >"$dir/.review-seen"
  if [ "$fp" != "$prev" ]; then
    rm -f "$dir/.review-quiet-since"
    triage "$id" "reviewer pane changed"
    return 1
  fi
  if [ ! -f "$dir/.review-quiet-since" ]; then
    touch "$dir/.review-quiet-since"
    triage "$id" "reviewer quiet window opened (agent=$agent)"
    return 1
  fi
  local began age wt
  began=$(stat -f %m "$dir/.review-quiet-since" 2>/dev/null || stat -c %Y "$dir/.review-quiet-since" 2>/dev/null) || began=0
  age=$(( $(sheepr_now) - began ))
  if [ "$age" -lt "$SHEEPR_STALL" ]; then
    triage "$id" "reviewer quiet ${age}s of ${SHEEPR_STALL}s (agent=$agent)"
    return 1
  fi
  wt=$(sheepr_meta_get "$id" worktree) || wt=''
  worktree_written_since "$wt" "$dir/.review-quiet-since"
  case $? in
    0) rm -f "$dir/.review-quiet-since"; triage "$id" "worktree written during the reviewer's quiet window"; return 1 ;;
    2) triage "$id" "worktree scan inconclusive; treating as no evidence" ;;
  esac
  printf '%s\t%s' "rv-stalled:$began" \
    "stalled: $id - reviewer reads $agent, no sentinel and no change for ${age}s"
  return 0
}

# --- per task ---------------------------------------------------------------

# Print "<signature>\t<reason>" when the task is actionable, nothing when not.
inspect_task() {  # <task-id>
  local id=$1 dir fold state key text agent
  dir=$(sheepr_task_dir "$id")

  fold=$(sheepr_status_fold "$id")
  state=${fold%%|*}
  key=$(printf '%s' "$fold" | cut -d'|' -f2)
  text=$(printf '%s' "$fold" | cut -d'|' -f3-)

  # A done is woken for once, even after other wakes came between (a review's,
  # for one). It is remembered apart from .woke for that reason, and forgotten
  # as soon as the worker is no longer done.
  [ "$state" = done ] || rm -f "$dir/.done-woke"

  # 0. an open review on a done task has its own ladder. The worker is
  # finished and has nothing more to say.
  if [ "$state" = done ] && sheepr_review_open "$id"; then
    inspect_review "$id" "$dir"
    return $?
  fi

  # 1. the budget. A finished task spends nothing more.
  case "$state" in
    done|failed) ;;
    *) inspect_budget "$id" "$dir" && return 0 ;;
  esac

  # 2. the status log is authoritative about what the worker has said. The
  # signature keeps the whole text; only the printed reason is cut.
  case "$state" in
    question) printf '%s\t%s' "q:$key:$text" "question: $id - $(excerpt "${key}: $text")"; return 0 ;;
    blocked)  printf '%s\t%s' "b:$key:$text" "blocked: $id - $(excerpt "$text")"; return 0 ;;
    done)
      [ "$(cat "$dir/.done-woke" 2>/dev/null)" = "d:$text" ] && return 1
      printf '%s\t%s' "d:$text" "done: $id - $(excerpt "$text")"; return 0 ;;
    failed)   printf '%s\t%s' "f:$text" "failed: $id - $(excerpt "$text")"; return 0 ;;
  esac

  # 3. ask herdr
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

  # 4. idle, done, unknown: prove nothing. Look for evidence of life.
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

# Print "<task-id>\t<signature>\t<reason>" for the first wake not yet
# delivered, and return 0. Records nothing: see commit_wake.
find_wake() {
  local id out sig last
  while read -r id; do
    [ -n "$id" ] || continue
    out=$(inspect_task "$id") || continue
    sig=${out%%$'\t'*}
    last=$(cat "$(sheepr_task_dir "$id")/.woke" 2>/dev/null || printf '')
    if [ "$sig" = "$last" ]; then
      triage "$id" "absorbed (already woke for: $sig)"
      continue
    fi
    printf '%s\t%s' "$id" "$out"
    return 0
  done < <(sheepr_task_ids)
  return 1
}

# Record a delivered wake, so it is not delivered again.
commit_wake() {  # <task-id> <signature> <reason>
  printf '%s' "$2" >"$(sheepr_task_dir "$1")/.woke"
  case "$2" in
    over:*|warning:*|budget-bad:*) printf '%s' "$2" >"$(sheepr_task_dir "$1")/.budget-woke" ;;
    rv-over:*|rv-warning:*|rv-budget-bad:*) printf '%s' "$2" >"$(sheepr_task_dir "$1")/.review-budget-woke" ;;
    d:*) printf '%s' "$2" >"$(sheepr_task_dir "$1")/.done-woke" ;;
  esac
  mkdir -p "$(dirname "$SHEEPR_WAKES")"
  printf '%s|%s|%s\n' "$(sheepr_now)" "$1" "$3" >>"$SHEEPR_WAKES"
}

# Split find_wake's output into WAKE_ID, WAKE_SIG and WAKE_REASON.
split_wake() {  # <find_wake-output>
  WAKE_ID=${1%%$'\t'*}
  local rest=${1#*$'\t'}
  WAKE_SIG=${rest%%$'\t'*}
  WAKE_REASON=${rest#*$'\t'}
}

# Prints the reason, then records it, and returns 0 when something is
# actionable.
pass_once() {
  local found
  found=$(find_wake) || return 1
  split_wake "$found"
  printf '%s\n' "$WAKE_REASON"
  commit_wake "$WAKE_ID" "$WAKE_SIG" "$WAKE_REASON"
  return 0
}

# Submit a wake into the supervisor's Herdr pane.
# 0 delivered, 1 not now (busy, at a dialog, or the submit failed),
# 2 nobody to deliver to: the pane is gone or holds no agent.
deliver_to_pane() {  # <pane-id> <task-id> <reason>
  local st
  sheepr_pane_agent "$1" >/dev/null || return 2
  st=$(sheepr_agent_state "$1")
  case "$st" in
    idle|done) ;;
    missing) return 2 ;;
    *) return 1 ;;
  esac
  sheepr_agent_prompt_verified "$1" "sheepr wake: $3" ''
  case $? in
    0) return 0 ;;
    # Submitted and visible in the composer, but no turn was observed.
    # Retrying would type it a second time onto the first copy.
    4) triage "$2" "wake submitted to $1 but no turn observed"; return 0 ;;
    *) return 1 ;;
  esac
}

# --- main -------------------------------------------------------------------
#
# Only when executed. Tests source this file and drive inspect_task directly.

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  usage="usage: sheepr-watch.sh [--once | --hook [cursor|claude|codex] | --wake-pane <pane-id>]"
  case "${1:-}" in
    --once) MODE=once ;;
    --hook)
      case "${2:-cursor}" in
        cursor|claude|codex) MODE="hook-${2:-cursor}" ;;
        *) die "$usage" ;;
      esac
      ;;
    --wake-pane)
      [ -n "${2:-}" ] || die "--wake-pane needs a pane id"
      MODE=wake-pane; PANE=$2
      ;;
    '') MODE=loop ;;
    *) die "$usage" ;;
  esac

  # Cursor imports Claude Code hooks from .claude/settings.json, but not
  # asyncRewake: it would run this one in the foreground and park the
  # session. Cursor's own stop hook covers it.
  if [ "$MODE" = hook-claude ] && [ -n "${CURSOR_VERSION:-}" ]; then
    exit 0
  fi

  sheepr_ensure_home

  # An empty fleet has nothing to supervise. Give the turn straight back
  # rather than parking, or every turn on an idle repo looks hung.
  if [ "$MODE" != once ] && [ -z "$(sheepr_task_ids)" ]; then
    exit 0
  fi

  command -v herdr >/dev/null 2>&1 || die "herdr not found"
  command -v jq >/dev/null 2>&1 || die "jq not found"

  if [ "$MODE" = hook-codex ]; then
    # Codex's Stop rejects plain text on stdout, and an async hook cannot
    # start a turn, so the work is handed to a detached watcher that delivers
    # through Herdr.
    sheepr_lock_holder "$WATCH_LOCK" >/dev/null && exit 0
    if [ -z "${HERDR_PANE_ID:-}" ]; then
      printf '{"systemMessage": %s}\n' \
        "$(printf 'sheepr: HERDR_PANE_ID is not set, so no watcher was started and no wake can reach this session. Run ./bin/sheepr-watch.sh --once each turn.' | jq -Rs .)"
      exit 0
    fi
    nohup bash "$SHEEPR_ROOT/bin/sheepr-watch.sh" --wake-pane "$HERDR_PANE_ID" \
      </dev/null >>"$PANE_LOG" 2>&1 &
    exit 0
  fi

  if ! sheepr_lock_acquire "$WATCH_LOCK"; then
    holder=$(sheepr_lock_holder "$WATCH_LOCK") || holder=unknown
    case "$MODE" in
      once) printf 'watching: a watcher already owns the fleet (pid %s)\n' "$holder"; exit 3 ;;
      # Under Cursor this line is the completion follow-up; it tells the
      # supervisor it is covered and must not start another.
      loop) printf 'watching: a watcher already owns the fleet (pid %s)\n' "$holder"; exit 0 ;;
      *) exit 0 ;;
    esac
  fi
  # The lock is released on EXIT only. A handler that released it on INT or
  # TERM did not stop the loop: the watcher carried on polling with no lock,
  # and a second watcher could take it and race this one on .woke, .seen-size
  # and .quiet-since. Exiting from the signal handlers runs the EXIT trap.
  trap 'sheepr_lock_release "$WATCH_LOCK"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  [ "$MODE" = wake-pane ] && printf '%s' "$PANE" >"$WATCH_LOCK/pane"

  if [ "$MODE" = once ]; then
    pass_once
    exit $?
  fi

  if [ "$MODE" = hook-cursor ]; then
    # Cursor hooks only run in the foreground, so this one never parks: one
    # pass, then give the turn back. Cursor ignores exit code 2; a
    # followup_message on stdout is the only channel that reaches the session.
    if found=$(find_wake); then
      split_wake "$found"
      printf '{"followup_message": %s}\n' "$(printf '%s' "$WAKE_REASON" | jq -Rs .)"
      commit_wake "$WAKE_ID" "$WAKE_SIG" "$WAKE_REASON"
    else
      printf '{"followup_message": %s}\n' "$(printf '%s' "$REARM_MESSAGE" | jq -Rs .)"
    fi
    exit 0
  fi

  started=$(sheepr_now)
  while :; do
    if found=$(find_wake); then
      split_wake "$found"
      case "$MODE" in
        loop)
          printf '%s\n' "$WAKE_REASON"
          commit_wake "$WAKE_ID" "$WAKE_SIG" "$WAKE_REASON"
          exit 0
          ;;
        hook-claude)
          # asyncRewake: exit 2 wakes Claude, and stderr is what it reads.
          printf '%s\n' "$WAKE_REASON" >&2
          commit_wake "$WAKE_ID" "$WAKE_SIG" "$WAKE_REASON"
          exit 2
          ;;
        wake-pane)
          deliver_to_pane "$PANE" "$WAKE_ID" "$WAKE_REASON"
          case $? in
            0) commit_wake "$WAKE_ID" "$WAKE_SIG" "$WAKE_REASON"; exit 0 ;;
            2)
              triage "$WAKE_ID" "no agent in supervisor pane $PANE; wake left unrecorded"
              exit 0
              ;;
          esac
          ;;
      esac
    fi
    # Every task has gone quiet for good (all torn down, or all absorbed and
    # terminal). Nothing further can arrive from a fleet with no tasks.
    if [ -z "$(sheepr_task_ids)" ]; then
      exit 0
    fi
    if [ "$MODE" != loop ] && [ $(( $(sheepr_now) - started )) -ge "$SHEEPR_HOOK_MAX" ]; then
      # Give up quietly. The next turn end re-arms the hook.
      exit 0
    fi
    sleep "$SHEEPR_POLL"
  done
fi
