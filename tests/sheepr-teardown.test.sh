#!/usr/bin/env bash
# tests/sheepr-teardown.test.sh - the landed-work proof.
#
# Every case is about refusing. Teardown destroys a worktree, so the only
# interesting question is whether it declines when the work is not safe
# somewhere else.
#
# Evidence now comes from flock, so these drive a canned flock document rather
# than building remotes and pull requests. flock's own analysis is flock's to
# test; what is tested here is sheepr's gate on top of it.

. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
. "$SHEEPR_ROOT/bin/sheepr-lib.sh"

begin
use_fake_flock

GIT="git -c user.email=t@x -c user.name=test -c commit.gpgsign=false -c init.defaultBranch=main"

# A task with a real worktree directory, so the retire step has something to
# act on. Prints the worktree path.
make_task() {  # <task-id> <delivery>
  local id=$1 delivery=$2
  local root="$SHEEPR_HOME/repos/$id"
  local repo="$root/repo" wt="$root/wt"
  mkdir -p "$repo"
  ( cd "$repo" && $GIT init -q -b main && printf 'x\n' >a.txt \
      && $GIT add -A && $GIT commit -qm init \
      && $GIT worktree add -q -b "sheepr/$id" "$wt" ) >/dev/null 2>&1

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

teardown() { SHEEPR_HOME="$SHEEPR_HOME" "$SHEEPR_ROOT/bin/sheepr-teardown.sh" "$@" 2>&1; }

archived() { ls "$SHEEPR_HOME/tasks/.archive/" 2>/dev/null | grep -q "^$1-"; }

# refused <id> <expected-substring> <description>
refused() {
  local out rc
  out=$(teardown "$1"); rc=$?
  if [ "$rc" = 0 ]; then
    fail "$3" "expected a refusal, got success" "$out"
  elif ! printf '%s' "$out" | grep -qF "$2"; then
    fail "$3" "wanted text: $2" "got: $out"
  else
    ok "$3"
  fi
}

# accepted <id> <expected-substring> <description>
accepted() {
  local out rc
  out=$(teardown "$1"); rc=$?
  if [ "$rc" != 0 ]; then
    fail "$3" "expected success, got refusal" "$out"
  elif ! printf '%s' "$out" | grep -qF "$2"; then
    fail "$3" "wanted text: $2" "got: $out"
  elif ! archived "$1"; then
    fail "$3" "the task was not archived"
  else
    ok "$3"
  fi
}

# --- the worktree itself ----------------------------------------------------

wt=$(make_task gone local)
flock_doc "$(flock_row "$wt" sheepr/gone '.ahead = 1')"
rm -rf "$wt"
refused gone 'the worktree is gone' 'a missing worktree is refused'

wt=$(make_task norow local)
flock_doc "$(flock_row /somewhere/else sheepr/other '.ahead = 1')"
refused norow 'flock reports no worktree at' 'a worktree flock does not know about is refused'

wt=$(make_task flockdown local)
flock_doc "$(flock_row "$wt" sheepr/flockdown '.ahead = 1')"
FAKE_FLOCK_FAIL=1 refused flockdown 'flock could not read' 'a flock failure is refused, not assumed clean'
unset FAKE_FLOCK_FAIL

# --- uncommitted changes ----------------------------------------------------

wt=$(make_task dirty local)
flock_doc "$(flock_row "$wt" sheepr/dirty '.dirty = 3 | .ahead = 1')"
refused dirty '3 uncommitted change(s)' 'a dirty worktree is refused'
[ -d "$wt" ] && ok 'the worktree survives a refusal' || fail 'the worktree survives a refusal'

wt=$(make_task unknown local)
flock_doc "$(flock_row "$wt" sheepr/unknown '.dirty = null | .ahead = 1')"
refused unknown 'cannot be proved clean' 'an unreadable worktree is refused: unknown is not clean'

# --- local delivery ---------------------------------------------------------

wt=$(make_task nocommits local)
flock_doc "$(flock_row "$wt" sheepr/nocommits '.ahead = 0')"
refused nocommits 'no commit that origin/main does not already have' \
  'local delivery with no commits is refused'

wt=$(make_task nobase local)
flock_doc "$(flock_row "$wt" sheepr/nobase '.ahead = null')"
refused nobase 'could not be resolved' 'local delivery is refused when the base cannot be resolved'

wt=$(make_task goodlocal local)
flock_doc "$(flock_row "$wt" sheepr/goodlocal '.ahead = 2')"
accepted goodlocal '2 commit(s) not on origin/main' 'local delivery with commits succeeds'

# --- branch delivery --------------------------------------------------------

wt=$(make_task noupstream branch)
flock_doc "$(flock_row "$wt" sheepr/noupstream '.upstream = null')"
refused noupstream 'has no upstream' 'branch delivery with no upstream is refused'

wt=$(make_task gonestream branch)
flock_doc "$(flock_row "$wt" sheepr/gonestream '.upstream_gone = true')"
refused gonestream 'has gone from the remote' 'branch delivery is refused when the upstream vanished'

wt=$(make_task ahead branch)
flock_doc "$(flock_row "$wt" sheepr/ahead '.upstream = "origin/sheepr/ahead" | .unpushed = 2')"
refused ahead '2 commit(s) are not pushed' 'branch delivery with unpushed commits is refused'

wt=$(make_task pushed branch)
flock_doc "$(flock_row "$wt" sheepr/pushed '.upstream = "origin/sheepr/pushed" | .unpushed = 0')"
accepted pushed 'is pushed to origin/sheepr/pushed' 'branch delivery succeeds once pushed'

# --- pr delivery ------------------------------------------------------------

pr() {  # <state> <head_matches> [extra]
  printf '.pr = {number: 7, state: "%s", url: "https://x/pr/7", head_matches: %s}%s' \
    "$1" "$2" "${3:-}"
}

wt=$(make_task nopr pr)
flock_doc "$(flock_row "$wt" sheepr/nopr '.pr = null')"
refused nopr 'no pull request was found' 'pr delivery with no pull request is refused'

# THE BUG: a closed, unmerged pull request used to pass and destroy the work.
wt=$(make_task closed pr)
flock_doc "$(flock_row "$wt" sheepr/closed "$(pr CLOSED false)")"
refused closed 'closed without merging' 'a CLOSED pull request is refused'

# THE BUG: a pull request merged at an older commit used to pass, discarding
# everything committed after the merge.
wt=$(make_task stalemerge pr)
flock_doc "$(flock_row "$wt" sheepr/stalemerge "$(pr MERGED false)")"
refused stalemerge 'not at this branch' 'a pull request merged at a different commit is refused'

wt=$(make_task merged pr)
flock_doc "$(flock_row "$wt" sheepr/merged "$(pr MERGED true)")"
accepted merged 'is merged at this commit' 'a pull request merged at this commit succeeds'

wt=$(make_task openunpushed pr)
flock_doc "$(flock_row "$wt" sheepr/openunpushed "$(pr OPEN false ' | .unpushed = 1')")"
refused openunpushed 'not pushed' 'an open pull request with unpushed commits is refused'

wt=$(make_task openclean pr)
flock_doc "$(flock_row "$wt" sheepr/openclean "$(pr OPEN false ' | .unpushed = 0')")"
accepted openclean 'is open and fully pushed' 'an open, fully pushed pull request succeeds'

wt=$(make_task weirdpr pr)
flock_doc "$(flock_row "$wt" sheepr/weirdpr "$(pr DRAFTED false)")"
refused weirdpr 'unrecognised state' 'an unrecognised pull request state is refused'

wt=$(make_task nogh pr)
flock_doc "$(flock_row "$wt" sheepr/nogh "$(pr MERGED true)")"
jq -c '.pr_lookup = false' "$FAKE_FLOCK_JSON" >"$FAKE_FLOCK_JSON.tmp" \
  && mv "$FAKE_FLOCK_JSON.tmp" "$FAKE_FLOCK_JSON"
refused nogh 'could not be looked up' 'pr delivery is refused when pull requests cannot be read'

# --- force ------------------------------------------------------------------

wt=$(make_task discard local)
flock_doc "$(flock_row "$wt" sheepr/discard '.dirty = 9 | .ahead = 0')"
out=$(teardown discard --force); rc=$?
is "$rc" '0' '--force discards work that would otherwise be refused'
case "$out" in *'skipping the landed-work check'*)
  ok '--force says plainly that it skipped the check' ;;
  *) fail '--force says plainly that it skipped the check' "got: $out" ;; esac

# --- a missing flock is a refusal, not a silent pass ------------------------

wt=$(make_task noflock local)
flock_doc "$(flock_row "$wt" sheepr/noflock '.ahead = 1')"
out=$(SHEEPR_FLOCK=/nonexistent HOME=/nonexistent teardown noflock); rc=$?
is "$rc" '1' 'teardown refuses when flock is not installed'
case "$out" in *'flock skill is required'*) ok 'the refusal explains how to install flock' ;;
  *) fail 'the refusal explains how to install flock' "got: $out" ;; esac

finish
