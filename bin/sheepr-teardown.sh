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
#   pr      a full https:// URL in a done line, and `gh` confirms the pull
#           request exists.
#   branch  the branch exists on the remote at the same commit as locally.
#   local   at least one commit on the branch that the base branch does not
#           have.
#
# In every mode the worktree must have no uncommitted change. brief.md is
# excluded at spawn time so it does not count against this.

set -uo pipefail

# shellcheck source=bin/sheepr-herdr.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sheepr-herdr.sh"
# shellcheck source=bin/sheepr-status.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sheepr-status.sh"

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
  [ -d "$WORKTREE" ] || refuse "the worktree is gone: $WORKTREE (use --force only if the captain said to discard)"

  dirty=$(git -C "$WORKTREE" status --porcelain 2>/dev/null)
  if [ -n "$dirty" ]; then
    refuse "the worktree has uncommitted changes:
$(printf '%s' "$dirty" | head -10)"
  fi

  case "$DELIVERY" in
    pr)
      url=$(sheepr_status_fold "$ID" | grep -oE 'https://[^ ]+' | head -1)
      [ -n "$url" ] || refuse "delivery is 'pr' but no done line carries an https:// URL"
      command -v gh >/dev/null 2>&1 || refuse "delivery is 'pr' but gh is not installed, so the pull request cannot be verified"
      state=$(gh pr view "$url" --json state -q .state 2>/dev/null) \
        || refuse "gh could not read the pull request at $url"
      printf 'pull request %s is %s\n' "$url" "$state"
      ;;
    branch)
      local_sha=$(git -C "$WORKTREE" rev-parse "$BRANCH" 2>/dev/null) \
        || refuse "branch $BRANCH does not exist"
      remote_sha=$(git -C "$WORKTREE" ls-remote origin "refs/heads/$BRANCH" 2>/dev/null | awk '{print $1}')
      [ -n "$remote_sha" ] || refuse "delivery is 'branch' but $BRANCH is not on the remote"
      [ "$local_sha" = "$remote_sha" ] \
        || refuse "delivery is 'branch' but the remote $BRANCH is at $remote_sha, not $local_sha"
      printf 'branch %s is pushed at %s\n' "$BRANCH" "${local_sha:0:8}"
      ;;
    local)
      base=$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null) || base=main
      ahead=$(git -C "$WORKTREE" rev-list --count "$base..$BRANCH" 2>/dev/null) || ahead=0
      [ "${ahead:-0}" -gt 0 ] \
        || refuse "delivery is 'local' but $BRANCH has no commit that $base does not already have"
      printf 'branch %s holds %s commit(s) not on %s\n' "$BRANCH" "$ahead" "$base"
      ;;
    *)
      refuse "unknown delivery mode '$DELIVERY'"
      ;;
  esac
else
  warn "--force: skipping the landed-work check for $ID"
fi

# --- retire -----------------------------------------------------------------

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
