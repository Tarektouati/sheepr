#!/usr/bin/env bash
# bin/sheepr-send.sh - answer a worker.
#
# Usage:
#   sheepr-send.sh <task-id> <text> [--resolve <key>]
#   sheepr-send.sh <task-id> --keys <key> [<key>...]
#   sheepr-send.sh <task-id> --budget <tokens>
#   sheepr-send.sh <task-id> --reopen <fix-brief>
#
# Owns: delivering the supervisor's reply to a running worker, closing the
# question or blocker that reply answers, raising a task's budget, and
# reopening a finished task on a fix plan.
#
# --reopen appends `reopened|<epoch>|reopen-<n>|<first line of the plan>` to
# the status log, which folds the task back to working, then copies the plan
# to ./fix-brief.md in the worktree (excluded from git like brief.md) and
# tells the worker to carry it out. The plan is the one the captain approved
# after a review; the worker's next done wakes, and is offered a review,
# like the first.
#
# --budget only records the new budget in meta; it sends nothing. The watcher
# wakes `overbudget:` once per budget, so a new budget re-arms it. To resume a
# worker the watcher stopped, raise the budget first, then send an ordinary
# reply. Resumed without a raise, it is still over and is stopped again.
#
# Refuses:
#   - to resolve a key that is not open. Closing a key nobody asked about
#     would hide the real question behind a fold that now looks clean.
#   - to retype a prompt into a composer that already holds one.
#   - to --reopen a task whose fold is not `done`: only finished work is
#     reopened, and a worker still running needs a reply, not a plan.
#   - to --reopen while a review is open: the findings come in first
#     (bin/sheepr-review.sh collect), then the plan is drafted from them.
#   - to --reopen with a plan file that is missing, empty or still holds a
#     {{placeholder}}.
#
# The resolved line is written BEFORE the prompt is delivered. If the worker
# dies between the two, the record still shows the captain answered, and the
# reply can be redelivered. The reverse order could lose the answer entirely.

set -uo pipefail

# shellcheck source=bin/sheepr-herdr.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sheepr-herdr.sh"
# shellcheck source=bin/sheepr-status.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sheepr-status.sh"

[ $# -ge 2 ] || die "usage: sheepr-send.sh <task-id> <text> [--resolve <key>] | --keys <key>... | --budget <tokens> | --reopen <fix-brief>"

ID=$1; shift
sheepr_validate_id "$ID"
sheepr_task_exists "$ID" || die "no such task: $ID"

# --- budget mode: record a new budget ----------------------------------------

if [ "$1" = "--budget" ]; then
  [ $# -eq 2 ] || die "usage: sheepr-send.sh <task-id> --budget <tokens>"
  [[ $2 =~ ^[1-9][0-9]*$ ]] || die "--budget '$2' must be a positive integer (tokens)"
  old=$(sheepr_meta_get "$ID" budget) || old=none
  sheepr_meta_set "$ID" budget "$2"
  printf 'budget for %s: %s -> %s\n' "$ID" "$old" "$2"
  exit 0
fi

# --- reopen mode: send a finished worker a fix plan --------------------------

if [ "$1" = "--reopen" ]; then
  [ $# -eq 2 ] || die "usage: sheepr-send.sh <task-id> --reopen <fix-brief>"
  PLAN=$2
  [ -f "$PLAN" ] || die "fix brief not found: $PLAN"
  [ -s "$PLAN" ] || die "fix brief is empty: $PLAN"
  if grep -q '{{[^}]*}}' "$PLAN"; then
    die "fix brief still contains placeholders: $(grep -o '{{[^}]*}}' "$PLAN" | sort -u | tr '\n' ' ')"
  fi
  fold=$(sheepr_status_fold "$ID")
  [ "${fold%%|*}" = done ] || die "refusing to reopen $ID: its fold is '${fold%%|*}', not done"
  sheepr_review_open "$ID" \
    && die "refusing to reopen $ID: a review is open; collect it first (sheepr-review.sh collect $ID)"
  WORKTREE=$(sheepr_meta_get "$ID" worktree) || die "task $ID has no recorded worktree"
  [ -d "$WORKTREE" ] || die "the worktree is gone: $WORKTREE"

  sheepr_herdr_require
  NAME=$(sheepr_meta_get "$ID" name) || NAME="sheepr-$ID"

  TASK_DIR=$(sheepr_task_dir "$ID")
  n=$(( $(grep -c '^reopened|' "$(sheepr_status_file "$ID")" 2>/dev/null || true) + 1 ))
  cp "$PLAN" "$TASK_DIR/fix-$n.md" || die "could not store the fix brief in $TASK_DIR"
  cp "$PLAN" "$WORKTREE/fix-brief.md" || die "could not write the fix brief into $WORKTREE"
  EXCLUDE=$(git -C "$WORKTREE" rev-parse --git-path info/exclude 2>/dev/null)
  if [ -n "$EXCLUDE" ]; then
    case "$EXCLUDE" in /*) ;; *) EXCLUDE="$WORKTREE/$EXCLUDE" ;; esac
    mkdir -p "$(dirname "$EXCLUDE")"
    grep -qxF '/fix-brief.md' "$EXCLUDE" 2>/dev/null || printf '/fix-brief.md\n' >>"$EXCLUDE"
  fi

  # Recorded before delivery, for the same reason as a resolved line.
  sheepr_status_append "$ID" reopened "reopen-$n" "$(head -1 "$PLAN" | cut -c1-200)"
  printf 'reopened %s (reopen-%s)\n' "$ID" "$n"

  # The done that was woken for is over; the next one must wake.
  rm -f "$TASK_DIR/.woke" "$TASK_DIR/.done-woke"

  MSG='Your task is reopened. Read ./fix-brief.md and carry out that fix plan on this branch. Report in your status log exactly as before, and write done with the same delivery evidence when it is finished.'
  sheepr_agent_prompt_verified "$NAME" "$MSG" "$(sheepr_status_file "$ID")"
  case $? in
    0) printf 'delivered the fix plan to %s\n' "$ID" ;;
    3) die "worker $ID is parked at a dialog; the plan is recorded but not delivered: use --keys, then send it again" ;;
    4) die "the fix plan was submitted to $ID but it never started a turn" ;;
    *) die "could not deliver the fix plan to $ID; it is recorded in the status log" ;;
  esac
  exit 0
fi

KEYS_MODE=0
if [ "${1:-}" = "--keys" ]; then
  KEYS_MODE=1; shift
  [ $# -ge 1 ] || die "--keys needs at least one key"
else
  TEXT=$1; shift
fi

RESOLVE=''
# A flag must carry its value. `shift 2` with one argument left shifts nothing
# and reports failure, so the loop would spin on the same argument forever.
while [ $# -gt 0 ] && [ "$KEYS_MODE" = 0 ]; do
  case "$1" in
    --resolve)
      [ $# -ge 2 ] || die "--resolve needs a value"
      RESOLVE=$2; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

# Validate the arguments before touching the environment, so a mistyped key is
# reported as a mistyped key rather than as a missing Herdr.
if [ -n "$RESOLVE" ] && ! sheepr_status_open_keys "$ID" | grep -qxF "$RESOLVE"; then
  open=$(sheepr_status_open_keys "$ID" | tr '\n' ' ')
  die "key '$RESOLVE' is not open on $ID (open: ${open:-none})"
fi

sheepr_herdr_require
NAME=$(sheepr_meta_get "$ID" name) || NAME="sheepr-$ID"

# --- key mode: answer a dialog ---------------------------------------------

if [ "$KEYS_MODE" = 1 ]; then
  sheepr_agent_send_keys "$NAME" "$@" || die "could not send keys to $ID"
  printf 'sent keys to %s: %s\n' "$ID" "$*"
  # The same reason as at the foot of this file, and it bites harder here: the
  # worker's next dialog carries the same wake signature as the one just
  # answered, so a stale .woke absorbs it and the supervisor is never told the
  # worker is parked again.
  rm -f "$(sheepr_task_dir "$ID")/.woke"
  exit 0
fi

# --- resolve ----------------------------------------------------------------

if [ -n "$RESOLVE" ]; then
  # The answer goes INTO the resolved line, not just into the terminal.
  # A worker that reads its own log must find the answer there: delivering it
  # only as a prompt leaves an empty resolved line that reads as "answered with
  # nothing", and the worker asks again.
  sheepr_status_append "$ID" resolved "$RESOLVE" "$TEXT"
  printf 'resolved %s on %s\n' "$RESOLVE" "$ID"
fi

# --- deliver ----------------------------------------------------------------

sheepr_agent_prompt_verified "$NAME" "$TEXT" "$(sheepr_status_file "$ID")"
case $? in
  0) printf 'delivered to %s\n' "$ID" ;;
  3) die "worker $ID is parked at a dialog; use --keys to answer it" ;;
  4) die "the reply was submitted to $ID but it never started a turn" ;;
  *) die "could not deliver to $ID" ;;
esac

# Clear the wake suppression so the next thing this worker says is reported.
rm -f "$(sheepr_task_dir "$ID")/.woke"
