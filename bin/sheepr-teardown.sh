#!/usr/bin/env bash
# bin/sheepr-teardown.sh - retire a task, but only once its work has landed.
#
# Usage:
#   sheepr-teardown.sh <task-id>
#   sheepr-teardown.sh <task-id> --force     discard, captain-authorised only
#
# Owns: proving that a task's work exists somewhere durable before its
# worktree and workspace are destroyed.
#
# Refuses: to remove anything holding work that has not landed. A refusal here
# is a correct outcome, not an obstacle. Report it and stop. --force exists
# only for work the captain has explicitly said to discard.
#
# Evidence required, by delivery mode:
#
#   pr      a pull request for this branch that is either merged AT THIS
#           COMMIT, or open with nothing left unpushed. A closed unmerged
#           pull request is refused: abandoning work is the captain's call.
#   branch  an upstream on the remote with nothing unpushed.
#   local   at least one commit the base branch does not have.
#
# A reviewer pane, if the task has one, is closed with the workspace, and
# tasks/<id>/review.md is archived with the rest of the task. Neither changes
# the proof above: a merge before the review's findings are in is never
# blocked by the review.
#
# In every mode the worktree must have no uncommitted change. brief.md is
# excluded at spawn time so it does not count against this.
#
# All of that evidence is read from flock, which already resolves the base
# branch properly, compares against the remote base so forge-side merges are
# visible, and knows a merged pull request only counts when it merged the
# current HEAD. The versions this script used to carry got the last two wrong.

set -uo pipefail

# shellcheck source=bin/sheepr-herdr.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sheepr-herdr.sh"
# shellcheck source=bin/sheepr-status.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sheepr-status.sh"
# shellcheck source=bin/sheepr-flock.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sheepr-flock.sh"

[ $# -ge 1 ] || die "usage: sheepr-teardown.sh <task-id> [--force]"
ID=$1; shift
FORCE=0
case "${1:-}" in
  --force) FORCE=1 ;;
  '') ;;
  *) die "unknown argument: $1" ;;
esac

sheepr_validate_id "$ID"
sheepr_task_exists "$ID" || die "no such task: $ID"

WORKTREE=$(sheepr_meta_get "$ID" worktree) || die "task $ID has no recorded worktree"
REPO=$(sheepr_meta_get "$ID" repo) || die "task $ID has no recorded repo"
BRANCH=$(sheepr_meta_get "$ID" branch) || die "task $ID has no recorded branch"
DELIVERY=$(sheepr_meta_get "$ID" delivery) || die "task $ID has no recorded delivery mode"
WS=$(sheepr_meta_get "$ID" workspace) || WS=''
LABEL=$(sheepr_meta_get "$ID" label) || LABEL="sheepr-$ID"

refuse() { printf 'sheepr: refusing to tear down %s: %s\n' "$ID" "$1" >&2; exit 1; }

# --- prove the work landed --------------------------------------------------

if [ "$FORCE" = 0 ]; then
  # Fail here rather than inside the command substitution below, where a die()
  # would only kill the subshell. --force needs no evidence, so it needs no
  # flock either.
  sheepr_flock_require

  [ -d "$WORKTREE" ] || refuse "the worktree is gone: $WORKTREE (use --force only if the captain said to discard)"

  STATUS_JSON=$(sheepr_flock_status "$REPO") \
    || refuse "flock could not read $REPO, so nothing about this worktree can be proved"
  ROW=$(sheepr_flock_row "$STATUS_JSON" "$WORKTREE") \
    || refuse "flock reports no worktree at $WORKTREE"
  BASE_REF=$(sheepr_flock_base_ref "$STATUS_JSON")

  field() { printf '%s' "$ROW" | jq -r "$1"; }

  # A null dirty count means git could not read the worktree. That is unknown,
  # not clean, and unknown is never evidence.
  dirty=$(field '.dirty')
  [ "$dirty" != null ] \
    || refuse "git could not read the worktree state, so it cannot be proved clean"
  [ "$dirty" = 0 ] \
    || refuse "the worktree has $dirty uncommitted change(s); commit or discard them first"

  case "$DELIVERY" in
    pr)
      [ "$(printf '%s' "$STATUS_JSON" | jq -r '.pr_lookup')" = true ] \
        || refuse "delivery is 'pr' but pull requests could not be looked up (is gh installed and authenticated?)"

      pr_state=$(field '.pr.state // ""')
      pr_url=$(field '.pr.url // ""')
      [ -n "$pr_state" ] \
        || refuse "delivery is 'pr' but no pull request was found for $BRANCH"

      unpushed=$(field '.unpushed // 0')
      case "$pr_state" in
        MERGED)
          # A merged pull request only counts when it merged THIS commit. A
          # reused branch name, or commits pushed after the merge, would
          # otherwise look landed while real work is thrown away.
          [ "$(field '.pr.head_matches')" = true ] \
            || refuse "$pr_url is merged, but not at this branch's current commit: there is work after the merge that has not landed"
          printf 'pull request %s is merged at this commit\n' "$pr_url"
          ;;
        OPEN)
          [ "${unpushed:-0}" = 0 ] \
            || refuse "$pr_url is open but $unpushed commit(s) here are not pushed; they exist nowhere else"
          printf 'pull request %s is open and fully pushed\n' "$pr_url"
          ;;
        CLOSED)
          refuse "$pr_url was closed without merging, so the work has not landed. Discarding it is the captain's call: use --force only if they said so"
          ;;
        *)
          refuse "$pr_url is in an unrecognised state: $pr_state"
          ;;
      esac
      ;;
    branch)
      [ "$(field '.upstream_gone')" != true ] \
        || refuse "delivery is 'branch' but the upstream for $BRANCH has gone from the remote"
      upstream=$(field '.upstream // ""')
      [ -n "$upstream" ] \
        || refuse "delivery is 'branch' but $BRANCH has no upstream on the remote"
      unpushed=$(field '.unpushed // 0')
      [ "${unpushed:-0}" = 0 ] \
        || refuse "delivery is 'branch' but $unpushed commit(s) are not pushed"
      printf 'branch %s is pushed to %s\n' "$BRANCH" "$upstream"
      ;;
    local)
      ahead=$(field '.ahead')
      [ "$ahead" != null ] \
        || refuse "$BASE_REF could not be resolved, so $BRANCH cannot be compared against it"
      [ "$ahead" -gt 0 ] \
        || refuse "delivery is 'local' but $BRANCH has no commit that $BASE_REF does not already have"
      printf 'branch %s holds %s commit(s) not on %s\n' "$BRANCH" "$ahead" "$BASE_REF"
      ;;
    *)
      refuse "unknown delivery mode '$DELIVERY'"
      ;;
  esac
else
  warn "--force: skipping the landed-work check for $ID"
fi

# --- retire -----------------------------------------------------------------

# The reviewer first: closing its pane is harmless when it is already gone.
RPANE=$(sheepr_meta_get "$ID" review_pane) || RPANE=''
if [ -n "$RPANE" ]; then
  if sheepr_pane_close "$RPANE"; then
    printf 'closed reviewer pane %s\n' "$RPANE"
  else
    warn "could not close reviewer pane $RPANE; removing the workspace closes it"
  fi
fi

# Resolve the workspace by label if the recorded id is stale.
if [ -z "$WS" ] || ! herdr workspace list 2>/dev/null \
     | jq -e --arg w "$WS" '.result.workspaces[] | select(.workspace_id == $w)' >/dev/null 2>&1; then
  WS=$(sheepr_workspace_by_label "$LABEL") || WS=''
fi

if [ -n "$WS" ]; then
  sheepr_worktree_remove "$WS" && printf 'removed workspace %s\n' "$WS"
else
  warn "no herdr workspace found for $ID; removing the git worktree directly"
  git -C "$REPO" worktree remove --force "$WORKTREE" 2>/dev/null || true
fi

git -C "$REPO" worktree prune 2>/dev/null || true

# Archive rather than delete. The status log is the only record of what the
# worker did, and it costs nothing to keep.
ARCHIVE="$SHEEPR_TASKS/.archive"
mkdir -p "$ARCHIVE"
mv "$(sheepr_task_dir "$ID")" "$ARCHIVE/$ID-$(sheepr_now)"

printf 'torn down %s (archived)\n' "$ID"
