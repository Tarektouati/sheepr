#!/usr/bin/env bash
# tests/sheepr-teardown.test.sh - the landed-work proof.
#
# Every case here is about refusing. Teardown destroys a worktree, so the only
# interesting question is whether it declines when the work is not safe
# somewhere else. Real git repositories are used; no herdr is needed, because
# every refusal happens before the workspace is touched.

. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
. "$SHEEPR_ROOT/bin/sheepr-lib.sh"

begin

GIT="git -c user.email=t@x -c user.name=test -c commit.gpgsign=false -c init.defaultBranch=main"

# Build a repo, a worktree on a task branch, and the task metadata.
# Prints the worktree path.
make_task() {  # <task-id> <delivery> [--remote]
  local id=$1 delivery=$2 remote=${3:-}
  local root="$SHEEPR_HOME/repos/$id"
  local repo="$root/repo" wt="$root/wt"
  mkdir -p "$repo"
  ( cd "$repo" && $GIT init -q -b main && printf 'x\n' >a.txt \
      && $GIT add -A && $GIT commit -qm init ) >/dev/null 2>&1

  if [ "$remote" = --remote ]; then
    $GIT init -q --bare "$root/origin.git" >/dev/null 2>&1
    ( cd "$repo" && $GIT remote add origin "$root/origin.git" \
        && $GIT push -q origin main ) >/dev/null 2>&1
  fi

  ( cd "$repo" && $GIT worktree add -q -b "sheepr/$id" "$wt" ) >/dev/null 2>&1

  mkdir -p "$SHEEPR_HOME/tasks/$id"
  cat >"$SHEEPR_HOME/tasks/$id/meta" <<EOF
worktree=$wt
repo=$repo
branch=sheepr/$id
delivery=$delivery
label=sheepr-$id
name=sheepr-$id
workspace=
EOF
  : >"$SHEEPR_HOME/tasks/$id/status"
  printf '%s' "$wt"
}

commit_in() {  # <worktree> <message>
  ( cd "$1" && printf '%s\n' "$2" >work.txt && $GIT add -A && $GIT commit -qm "$2" ) >/dev/null 2>&1
}

teardown() {  # <task-id> [--force] -> combined output
  SHEEPR_HOME="$SHEEPR_HOME" "$SHEEPR_ROOT/bin/sheepr-teardown.sh" "$@" 2>&1
}

# --- uncommitted changes ----------------------------------------------------

wt=$(make_task dirty local)
commit_in "$wt" 'real work'
printf 'scratch\n' >"$wt/untracked.txt"
out=$(teardown dirty); rc=$?
is "$rc" '1' 'a dirty worktree is refused'
case "$out" in *"uncommitted changes"*) ok 'the refusal names the uncommitted changes' ;;
  *) fail 'the refusal names the uncommitted changes' "got: $out" ;; esac
[ -d "$wt" ] && ok 'the worktree still exists after a refusal' \
  || fail 'the worktree still exists after a refusal'

# --- local delivery ---------------------------------------------------------

wt=$(make_task nocommits local)
out=$(teardown nocommits); rc=$?
is "$rc" '1' 'local delivery with no commits is refused'
case "$out" in *"no commit that main does not already have"*)
  ok 'the refusal explains that nothing was committed' ;;
  *) fail 'the refusal explains that nothing was committed' "got: $out" ;; esac

wt=$(make_task good local)
commit_in "$wt" 'the deliverable'
out=$(teardown good); rc=$?
is "$rc" '0' 'local delivery with a commit succeeds'
case "$out" in *"1 commit(s) not on main"*) ok 'the success names the evidence' ;;
  *) fail 'the success names the evidence' "got: $out" ;; esac
[ -d "$SHEEPR_HOME/tasks/good" ] && fail 'the task directory was moved out of tasks/' \
  || ok 'the task directory was moved out of tasks/'
ls "$SHEEPR_HOME/tasks/.archive/" 2>/dev/null | grep -q '^good-' \
  && ok 'the task was archived rather than deleted' \
  || fail 'the task was archived rather than deleted'

# --- pr delivery ------------------------------------------------------------

wt=$(make_task nourl pr)
commit_in "$wt" 'work'
out=$(teardown nourl); rc=$?
is "$rc" '1' 'pr delivery with no URL in the done line is refused'
case "$out" in *"no done line carries an https:// URL"*)
  ok 'the refusal asks for the pull request URL' ;;
  *) fail 'the refusal asks for the pull request URL' "got: $out" ;; esac

# A done line carrying a URL gets past the URL check and on to gh.
wt=$(make_task withurl pr)
commit_in "$wt" 'work'
printf 'done|1||https://github.com/nobody/nothing/pull/999\n' \
  >"$SHEEPR_HOME/tasks/withurl/status"
out=$(teardown withurl); rc=$?
is "$rc" '1' 'pr delivery is still refused when gh cannot confirm the pull request'
case "$out" in *"gh could not read"*|*"gh is not installed"*)
  ok 'the refusal names the gh verification failure' ;;
  *) fail 'the refusal names the gh verification failure' "got: $out" ;; esac

# --- branch delivery --------------------------------------------------------

wt=$(make_task unpushed branch --remote)
commit_in "$wt" 'work'
out=$(teardown unpushed); rc=$?
is "$rc" '1' 'branch delivery is refused when the branch is not on the remote'
case "$out" in *"not on the remote"*) ok 'the refusal says the branch is unpushed' ;;
  *) fail 'the refusal says the branch is unpushed' "got: $out" ;; esac

wt=$(make_task pushed branch --remote)
commit_in "$wt" 'work'
( cd "$wt" && $GIT push -q -u origin sheepr/pushed ) >/dev/null 2>&1
out=$(teardown pushed); rc=$?
is "$rc" '0' 'branch delivery succeeds once the branch is pushed'
case "$out" in *"is pushed at"*) ok 'the success names the pushed commit' ;;
  *) fail 'the success names the pushed commit' "got: $out" ;; esac

# Diverged: local moved on after the push.
wt=$(make_task diverged branch --remote)
commit_in "$wt" 'first'
( cd "$wt" && $GIT push -q -u origin sheepr/diverged ) >/dev/null 2>&1
commit_in "$wt" 'second, unpushed'
out=$(teardown diverged); rc=$?
is "$rc" '1' 'branch delivery is refused when the local branch is ahead of the remote'

# --- force ------------------------------------------------------------------

wt=$(make_task discard local)
printf 'scratch\n' >"$wt/untracked.txt"
out=$(teardown discard --force); rc=$?
is "$rc" '0' '--force discards work that would otherwise be refused'
case "$out" in *"skipping the landed-work check"*)
  ok '--force says plainly that it skipped the check' ;;
  *) fail '--force says plainly that it skipped the check' "got: $out" ;; esac

finish
