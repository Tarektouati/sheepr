#!/usr/bin/env bash
# bin/sheepr-fleet.sh - everything in the worktrees, not just sheepr's tasks.
#
# Usage:
#   sheepr-fleet.sh              every repository sheepr has a task in
#   sheepr-fleet.sh --repo PATH  one repository, task or not
#   sheepr-fleet.sh --json       machine readable
#
# Owns: the join between what sheepr knows (tasks, status logs) and what is
# actually on disk (worktrees, agents, pull requests, read through flock).
#
# Refuses: to change anything. This command is read-only, on purpose. It
# reports orphans; deciding what to do about one is the captain's.
#
# Why it exists: sheepr only knows tasks it created, by reading tasks/*/. A
# worktree made by hand, or left behind by a task whose records were removed,
# is invisible to every other sheepr command - including teardown, which is
# what protects unlanded work. This is the command that sees them.
#
# Usage: each task row carries its tokens, read through bin/sheepr-usage.sh
# with --read-only so this view still writes nothing; `?` is unknown. The
# footer gives the total over the tasks shown, and the supervisor's own spend.
#
# Three kinds of row:
#   task    a worktree with a matching task record; shows its folded state
#   orphan  a linked worktree with no task record; sheepr does not manage it
#   stale   a task whose worktree no longer exists

set -uo pipefail

# shellcheck source=bin/sheepr-flock.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sheepr-flock.sh"
# shellcheck source=bin/sheepr-status.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sheepr-status.sh"

JSON=0
ONLY_REPO=''
while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON=1; shift ;;
    --repo) ONLY_REPO=${2:-}; shift 2 ;;
    -h|--help) sed -n '3,7p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

sheepr_require_tools jq
sheepr_flock_require

# --- which repositories to look at -----------------------------------------

# One path per line. sheepr_realpath deliberately prints without a trailing
# newline, so every line is terminated here: a final unterminated line makes
# `while read` return non-zero and skip the body entirely.
repos() {
  if [ -n "$ONLY_REPO" ]; then
    printf '%s\n' "$(sheepr_realpath "$ONLY_REPO")"
    return
  fi
  local id r
  while read -r id; do
    [ -n "$id" ] || continue
    r=$(sheepr_meta_get "$id" repo) || continue
    printf '%s\n' "$(sheepr_realpath "$r")"
  done < <(sheepr_task_ids) | sort -u
}

USAGE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sheepr-usage.sh"

# A task's total tokens, or null when its usage is unknown. A refusal from
# the usage adapter is unknown too: this view reports, it does not fail.
task_tokens() {  # <task-id>
  local line
  line=$("$USAGE" task "$1" --read-only 2>/dev/null) || line=''
  case "$line" in
    [0-9]*) printf '%s' "${line%% *}" ;;
    *) printf 'null' ;;
  esac
}

# --- index sheepr's tasks by worktree path ---------------------------------

TASK_INDEX=$(
  while read -r id; do
    [ -n "$id" ] || continue
    wt=$(sheepr_meta_get "$id" worktree) || wt=''
    [ -n "$wt" ] || continue
    jq -nc --arg id "$id" --arg wt "$wt" --arg real "$(sheepr_realpath "$wt")" \
           --arg fold "$(sheepr_status_fold "$id")" \
           --arg delivery "$(sheepr_meta_get "$id" delivery || printf '?')" \
           --arg kind "$(sheepr_meta_get "$id" kind || printf '?')" \
           --argjson tokens "$(task_tokens "$id")" \
      '{id: $id, worktree: $wt, real: $real, delivery: $delivery, kind: $kind,
        tokens: $tokens,
        state: ($fold | split("|")[0]), detail: ($fold | split("|")[2:] | join("|"))}'
  done < <(sheepr_task_ids) | jq -sc '.'
)

# --- gather -----------------------------------------------------------------

ROWS='[]'
SEEN='[]'

while read -r repo; do
  [ -n "$repo" ] || continue
  status=$(sheepr_flock_status "$repo") || {
    warn "skipping $repo: flock could not read it"
    continue
  }
  rows=$(printf '%s' "$status" | jq -c --argjson tasks "$TASK_INDEX" --arg repo "$repo" '
    [ .worktrees[]
      | select(.linked)
      | . as $w
      # [...][0] yields null when nothing matches. A bare `$tasks[] | select`
      # would emit nothing instead, silently dropping the orphan we are here
      # to find.
      | ([$tasks[] | select(.real == $w.path or .worktree == $w.path)][0]) as $t
      | {
          repo: $repo,
          kind: (if $t == null then "orphan" else "task" end),
          task: ($t.id // null),
          state: ($t.state // null),
          detail: ($t.detail // null),
          delivery: ($t.delivery // null),
          tokens: ($t.tokens // null),
          branch: .branch, path: .path,
          dirty: .dirty, ahead: .ahead, behind: .behind, unpushed: .unpushed,
          pr: (if .pr == null then null else "#\(.pr.number) \(.pr.state)" end),
          agent: (if (.agents | length) == 0 then null
                  else (.agents | map(.status) | join(",")) end)
        }
    ]')
  ROWS=$(jq -nc --argjson a "$ROWS" --argjson b "$rows" '$a + $b')
  SEEN=$(jq -nc --argjson s "$SEEN" --argjson r "$rows" '$s + [$r[].path]')
done < <(repos)

# Tasks whose worktree never turned up in any repository's listing.
STALE=$(jq -nc --argjson tasks "$TASK_INDEX" --argjson seen "$SEEN" '
  [ $tasks[]
    | select((.real as $r | $seen | index($r)) == null)
    | select((.worktree as $w | $seen | index($w)) == null)
    | { repo: null, kind: "stale", task: .id, state: .state, detail: .detail,
        delivery: .delivery, tokens: .tokens, branch: null, path: .worktree,
        dirty: null, ahead: null, behind: null, unpushed: null,
        pr: null, agent: null }
  ]')

ALL=$(jq -nc --argjson r "$ROWS" --argjson s "$STALE" '$r + $s')

# The supervisor's own spend: null when unknown, like a task's.
SELF=$("$USAGE" self 2>/dev/null) || SELF=''
case "$SELF" in [0-9]*) SELF=${SELF%% *} ;; *) SELF=null ;; esac

# Over the task and stale rows shown: an orphan has no harness sheepr knows.
USAGE_SUMMARY=$(printf '%s' "$ALL" | jq -c --argjson self "$SELF" '
  [.[] | select(.kind != "orphan")] as $t
  | { fleet_total: ([$t[] | .tokens | numbers] | add // 0),
      measured: ([$t[] | .tokens | numbers] | length),
      unknown: ([$t[] | select(.tokens == null)] | length),
      supervisor: $self }')

if [ "$JSON" = 1 ]; then
  printf '%s\n' "$ALL" | jq --argjson usage "$USAGE_SUMMARY" '{
    tasks:   [.[] | select(.kind == "task")],
    orphans: [.[] | select(.kind == "orphan")],
    stale:   [.[] | select(.kind == "stale")],
    usage:   $usage,
    all: .
  }'
  exit 0
fi

# --- present ----------------------------------------------------------------

count=$(printf '%s' "$ALL" | jq 'length')
if [ "$count" = 0 ]; then
  printf 'no worktrees, and no tasks.\n'
  exit 0
fi

printf '%s' "$ALL" | jq -r '
  def human: if . == null then "?"
             elif . >= 1000000 then "\((. / 100000 | floor) / 10)M"
             elif . >= 1000 then "\((. / 100 | floor) / 10)k"
             else tostring end;
  (["TASK","STATE","AGENT","TOKENS","BRANCH","DIRTY","AHEAD","PR","PATH"] | @tsv),
  (.[] | [
     (if .kind == "orphan" then "(orphan)"
      elif .kind == "stale" then "\(.task) (stale)"
      else .task end),
     (.state // "-"),
     (.agent // "-"),
     (if .kind == "orphan" then "-" else (.tokens | human) end),
     (.branch // "-"),
     (.dirty | if . == null then "?" else tostring end),
     (.ahead | if . == null then "?" else tostring end),
     (.pr // "-"),
     .path
   ] | @tsv)' | column -t -s "$(printf '\t')"

printf '%s' "$USAGE_SUMMARY" | jq -r '
  def human: if . == null then "?"
             elif . >= 1000000 then "\((. / 100000 | floor) / 10)M"
             elif . >= 1000 then "\((. / 100 | floor) / 10)k"
             else tostring end;
  "\ntokens: fleet \(.fleet_total | human) over \(.measured) task(s)"
  + (if .unknown > 0 then ", \(.unknown) unknown" else "" end)
  + "; supervisor \(.supervisor | human)"'

orphans=$(printf '%s' "$ALL" | jq '[.[] | select(.kind == "orphan")] | length')
stale=$(printf '%s' "$ALL" | jq '[.[] | select(.kind == "stale")] | length')
dirty_orphans=$(printf '%s' "$ALL" \
  | jq '[.[] | select(.kind == "orphan") | select((.dirty // 0) > 0)] | length')

if [ "$orphans" != 0 ] || [ "$stale" != 0 ]; then
  printf '\n'
  [ "$orphans" = 0 ] || printf '%s orphaned worktree(s): not sheepr tasks, so no sheepr command protects them.\n' "$orphans"
  [ "$dirty_orphans" = 0 ] || printf '  %s of them hold uncommitted work. Decide before anything removes them.\n' "$dirty_orphans"
  [ "$stale" = 0 ] || printf '%s stale task(s): the record exists but the worktree is gone.\n' "$stale"
  printf 'Use the flock skill to triage these; it confirms each action with you.\n'
fi
