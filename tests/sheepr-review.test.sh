#!/usr/bin/env bash
# tests/sheepr-review.test.sh - the review after a done: start, the sentinel,
# collect, post, the reviewer's budget, reopen, and teardown.
#
# herdr and gh are fakes on PATH that log every call. The fake herdr serves a
# pane's text from $FAKE/pane-<pane-id>, and an agent's state, kind and
# session from $FAKE/{state,kind,session}-<name>. Usage is read by the real
# bin/sheepr-usage.sh from the usage fixtures: claude session s1 in /wt/alpha
# spent 33 (16 fresh input + 17 output).
#
# The properties that matter: the sentinel wakes once, and its description in
# the prompt never counts as it; collect refuses without it; post posts
# nothing without --yes; the reviewer's spend is its own; a reopened task's
# next done wakes again.

. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
. "$SHEEPR_ROOT/bin/sheepr-watch.sh"

begin

if ! command -v jq >/dev/null 2>&1; then
  skip 'jq is not installed'
  finish
fi

SHEEPR_CLAUDE_HOME="$SHEEPR_ROOT/tests/fixtures/usage/claude"
export SHEEPR_CLAUDE_HOME
use_fake_flock

FAKE=$(mktemp -d "${TMPDIR:-/tmp}/sheepr-fakereview-XXXXXX")
export FAKE
cat >"$FAKE/herdr" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$FAKE/calls"
case "$1 $2" in
  "agent get")
    [ -f "$FAKE/state-$3" ] || { printf '{"error":{"code":"agent_not_found"}}\n'; exit 1; }
    sess=''
    [ -f "$FAKE/session-$3" ] && sess=$(printf ',"agent_session":{"value":"%s"}' "$(cat "$FAKE/session-$3")")
    printf '{"result":{"agent":{"agent":"%s","agent_status":"%s"%s}}}\n' \
      "$(cat "$FAKE/kind-$3" 2>/dev/null || echo claude)" "$(cat "$FAKE/state-$3")" "$sess" ;;
  "pane read")
    [ -f "$FAKE/pane-$3" ] || { printf '{"error":{"code":"pane_not_found"}}\n'; exit 1; }
    cat "$FAKE/pane-$3" ;;
  "pane close")
    [ -f "$FAKE/pane-$3" ] || { printf '{"error":{"code":"pane_not_found"}}\n'; exit 1; }
    rm -f "$FAKE/pane-$3"; printf '{"result":{"type":"ok"}}\n' ;;
  "pane split")
    : >"$FAKE/pane-w1:p9"
    printf '{"result":{"pane":{"pane_id":"w1:p9"}}}\n' ;;
  "agent start")
    printf 'working' >"$FAKE/state-$3"
    printf '{"result":{"type":"ok"}}\n' ;;
  "workspace list") printf '{"result":{"workspaces":[]}}\n' ;;
  *) printf '{"result":{"type":"ok"}}\n' ;;
esac
EOF
cat >"$FAKE/gh" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$FAKE/gh-calls"
case "$*" in
  "pr view"*) printf '{"headRefOid":"abc123","author":{"login":"someone"}}\n' ;;
  "api user"*) printf 'me\n' ;;
  "pr diff"*) cat "$FAKE/diff" ;;
  *"/comments --paginate"*) printf '[{"path":"src/a.ts","side":"RIGHT","line":3,"body":"**Suggestion:** Use the helper."}]\n' ;;
  *"/reviews --paginate"*) printf '[]\n' ;;
  *"-X POST"*) printf '{"html_url":"https://github.com/o/r/pull/5#pullrequestreview-1"}\n' ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$FAKE/herdr" "$FAKE/gh"
PATH="$FAKE:$PATH"
HERDR_ENV=1
export PATH HERDR_ENV
trap 'rm -rf "$FAKE"; cleanup_home' EXIT

agent() {  # <name> <state> [session]
  printf '%s' "$2" >"$FAKE/state-$1"
  [ -z "${3:-}" ] || printf '%s' "$3" >"$FAKE/session-$1"
}

# One task at a time, so pass_once sees only it.
mktask() {  # <id> <delivery> [worktree]
  rm -rf "${SHEEPR_TASKS:?}"/*
  local dir="$SHEEPR_TASKS/$1" wt=${3:-}
  if [ -z "$wt" ]; then wt="$dir/wt"; mkdir -p "$wt"; fi
  mkdir -p "$dir"
  cat >"$dir/meta" <<META
name=sheepr-$1
label=sheepr-$1
kind=claude
worktree=$wt
repo=$SHEEPR_HOME
workspace=w1
pane=w1:p1
branch=sheepr/$1
delivery=$2
base=origin/main
META
  printf 'working|1||started\n' >"$dir/status"
  printf '%s' "$dir"
}

review() { "$SHEEPR_ROOT/bin/sheepr-review.sh" "$@" 2>&1; }
send() { "$SHEEPR_ROOT/bin/sheepr-send.sh" "$@" 2>&1; }

# --- start: refusals --------------------------------------------------------

d=$(mktask r1 pr)
out=$(review start r1 --kind claude); rc=$?
is "$rc" '1' 'a review of a task that is not done is refused'
case "$out" in *"not done"*) ok 'and the refusal says so' ;; *) fail 'and the refusal says so' "got: $out" ;; esac

printf 'done|2||PR is up https://github.com/o/r/pull/5\n' >>"$d/status"
out=$(review start r1); rc=$?
is "$rc" '1' 'a review without --kind is refused'

out=$(review start r1 --kind claude --budget 10k); rc=$?
is "$rc" '1' 'a review with a bad budget is refused'

# --- start ------------------------------------------------------------------

agent sheepr-r1 idle
out=$(review start r1 --kind claude --model claude-sonnet-5-5 --budget 30 --route review); rc=$?
is "$rc" '0' 'a review of a done task starts'
is "$(sheepr_meta_get r1 review_pane)" 'w1:p9' 'review_pane is the split pane herdr reported'
for k in review_kind review_model review_budget review_route; do
  [ -n "$(sheepr_meta_get r1 "$k")" ] && ok "$k is recorded" || fail "$k is recorded"
done
is "$(sheepr_meta_get r1 review_target)" 'https://github.com/o/r/pull/5' 'the target is the PR URL from the done line'
nonce=$(sheepr_meta_get r1 review_started)
[ -n "$nonce" ] && ok 'review_started is recorded' || fail 'review_started is recorded'
grep -q -- '--no-focus' "$FAKE/calls" && grep -q '^pane split w1:p1 ' "$FAKE/calls" \
  && ok 'the pane is split beside the worker, without focus' \
  || fail 'the pane is split beside the worker, without focus' "$(grep split "$FAKE/calls")"
start_line=$(grep '^agent start rv-r1' "$FAKE/calls")
case "$start_line" in *'--permission-mode plan'*) ok 'a claude reviewer starts in plan mode' ;;
  *) fail 'a claude reviewer starts in plan mode' "got: $start_line" ;; esac
case "$start_line" in *dangerously*) fail 'and never with --dangerously-skip-permissions' ;;
  *) ok 'and never with --dangerously-skip-permissions' ;; esac
prompt=$(grep '^agent prompt rv-r1' "$FAKE/calls")
case "$prompt" in *'/semantic-review https://github.com/o/r/pull/5'*) ok 'the reviewer is prompted with /semantic-review and the PR' ;;
  *) fail 'the reviewer is prompted with /semantic-review and the PR' "got: $prompt" ;; esac
case "$prompt" in *"SHEEPR-REVIEW-DONE-$nonce"*) fail 'the prompt never holds the sentinel whole' ;;
  *) ok 'the prompt never holds the sentinel whole' ;; esac

out=$(review start r1 --kind claude); rc=$?
is "$rc" '1' 'a second review while one is open is refused'

# --- the sentinel wakes once ------------------------------------------------

# The fold's done was woken for before the review.
printf 'd:PR is up https://github.com/o/r/pull/5' >"$d/.woke"
printf 'd:PR is up https://github.com/o/r/pull/5' >"$d/.done-woke"

agent rv-r1 working s1
printf '❯ %s\n' "$(grep '^agent prompt rv-r1' "$FAKE/calls" | cut -d' ' -f4-)" >"$FAKE/pane-w1:p9"
out=$(pass_once); rc=$?
is "$rc" '1' 'the prompt echo in the pane is not the sentinel'
is "$(sheepr_meta_get r1 review_session)" 's1' 'the watcher records the reviewer session herdr reports'

cat >>"$FAKE/pane-w1:p9" <<PANE
⏺ SHEEPR-REVIEW-BEGIN-$nonce
  Reviewing PR #5 (o/r, open)
  Changes expected (1 Important)

  1. src/a.ts:3
     Important: off by one when the list is empty.
  2. src/a.ts:3
     Suggestion: Use the helper.
  3. src/gone.ts:99
     Hint: not in the diff.
  SHEEPR-REVIEW-DONE-$nonce
✻ Baked for 3m · done
PANE
agent rv-r1 done
out=$(pass_once); rc=$?
is "$out" 'reviewed: r1 - the reviewer printed its findings' 'the sentinel wakes reviewed:'
out=$(pass_once); rc=$?
is "$rc" '1' 'the sentinel wakes once'

# --- collect ------------------------------------------------------------------

d=$(mktask r2 branch)
printf 'done|2||pushed sheepr/r2\n' >>"$d/status"
agent sheepr-r2 idle
review start r2 --kind claude >/dev/null
is "$(sheepr_meta_get r2 review_target | cut -c1-28)" 'sheepr/r2 vs origin/main (th' 'a branch is reviewed against meta base'
printf 'some output, no sentinel\n' >"$FAKE/pane-w1:p9"
out=$(review collect r2); rc=$?
is "$rc" '1' 'collect refuses without the sentinel'
case "$out" in *'no sentinel'*) ok 'and says the review is not finished' ;; *) fail 'and says the review is not finished' "got: $out" ;; esac
[ -f "$d/review.md" ] && fail 'a refused collect writes no review.md' || ok 'a refused collect writes no review.md'
[ -f "$FAKE/pane-w1:p9" ] && ok 'and leaves the reviewer pane open' || fail 'and leaves the reviewer pane open'

# Back to r1, whose reviewer printed its findings.
rm -rf "${SHEEPR_TASKS:?}"/*
d=$(mktask r1 pr)
printf 'done|2||PR is up https://github.com/o/r/pull/5\n' >>"$d/status"
agent sheepr-r1 idle
cp "$FAKE/pane-w1:p9" "$SHEEPR_HOME/saved-pane" 2>/dev/null
review start r1 --kind claude --budget 30 >/dev/null
nonce=$(sheepr_meta_get r1 review_started)
{ printf '❯ /semantic-review ... SHEEPR-REVIEW-DONE followed by a hyphen and the number %s\n' "$nonce"
  printf '⏺ SHEEPR-REVIEW-BEGIN-%s\n  Reviewing PR #5 (o/r, open)\n  Changes expected (1 Important)\n\n' "$nonce"
  printf '  1. src/a.ts:3\n     Important: off by one when the list is empty.\n'
  printf '  2. src/a.ts:3\n     Suggestion: Use the helper.\n'
  printf '  3. src/gone.ts:99\n     Hint: not in the diff.\n'
  printf '  SHEEPR-REVIEW-DONE-%s\n' "$nonce"
} >"$FAKE/pane-w1:p9"
out=$(review collect r1); rc=$?
is "$rc" '0' 'collect succeeds once the sentinel is there'
case "$out" in *'3 finding(s)'*) ok 'and counts the findings' ;; *) fail 'and counts the findings' "got: $out" ;; esac
is "$(sed -n 2p "$d/review.md")" 'Reviewing PR #5 (o/r, open)' 'review.md starts at the target line, bullet and indent removed'
grep -q 'SHEEPR-REVIEW' "$d/review.md" && fail 'review.md holds neither marker' || ok 'review.md holds neither marker'
[ -f "$FAKE/pane-w1:p9" ] && fail 'collect closes the reviewer pane' || ok 'collect closes the reviewer pane'
[ -n "$(sheepr_meta_get r1 review_done)" ] && ok 'collect records review_done' || fail 'collect records review_done'
sheepr_review_open r1 && fail 'the review is no longer open' || ok 'the review is no longer open'

# After collect, the done already woken for stays quiet.
printf 'd:PR is up https://github.com/o/r/pull/5' >"$d/.done-woke"
printf 'reviewed:%s' "$nonce" >"$d/.woke"
pass_once >/dev/null; rc=$?
is "$rc" '1' 'after collect the done does not wake a second time'

# --- post ---------------------------------------------------------------------

printf 'diff --git a/src/a.ts b/src/a.ts\n--- a/src/a.ts\n+++ b/src/a.ts\n@@ -1,2 +1,3 @@\n a\n+b\n+c\n' >"$FAKE/diff"
: >"$FAKE/gh-calls"
out=$(review post r1 1,2,3); rc=$?
is "$rc" '0' 'post without --yes succeeds as a dry run'
grep -q -- '-X POST' "$FAKE/gh-calls" && fail 'post without --yes posts nothing' "$(cat "$FAKE/gh-calls")" \
  || ok 'post without --yes posts nothing'
case "$out" in *'event REQUEST_CHANGES'*) ok 'an Important makes the event REQUEST_CHANGES' ;;
  *) fail 'an Important makes the event REQUEST_CHANGES' "got: $out" ;; esac
case "$out" in *'src/a.ts:3  **Important:** off by one'*) ok 'an anchored finding is an inline comment' ;;
  *) fail 'an anchored finding is an inline comment' "got: $out" ;; esac
case "$out" in *'Moved into the body (no anchor in the diff): 3'*) ok 'a finding off the diff moves into the body' ;;
  *) fail 'a finding off the diff moves into the body' "got: $out" ;; esac
case "$out" in *'duplicates of your existing comments: 2'*) ok 'a duplicate of an existing comment is skipped' ;;
  *) fail 'a duplicate of an existing comment is skipped' "got: $out" ;; esac

out=$(review post r1 1,7); rc=$?
is "$rc" '1' 'post refuses a number that is not a finding'

out=$(review post r1 1 --yes); rc=$?
is "$rc" '0' 'post --yes posts'
grep -q -- '-X POST' "$FAKE/gh-calls" && ok 'with gh' || fail 'with gh'
case "$out" in *'posted: https://github.com/o/r/pull/5#pullrequestreview-1'*) ok 'and prints the review URL' ;;
  *) fail 'and prints the review URL' "got: $out" ;; esac

d2=$(mktask r3 local)
printf 'done|2||committed\n' >>"$d2/status"
cp "$d/review.md" "$d2/review.md" 2>/dev/null
out=$(review post r3 1); rc=$?
is "$rc" '1' 'post refuses a task not delivered as a pr'

# --- the reviewer budget --------------------------------------------------------

# The worktree must exist for start, so its claude log is the fixture's,
# copied under the slug of a real directory.
bwt="$SHEEPR_HOME/bwt"; mkdir -p "$bwt"
SHEEPR_CLAUDE_HOME="$SHEEPR_HOME/claude-fix"; export SHEEPR_CLAUDE_HOME
mkdir -p "$SHEEPR_CLAUDE_HOME/projects"
cp -R "$SHEEPR_ROOT/tests/fixtures/usage/claude/projects/-wt-alpha" \
  "$SHEEPR_CLAUDE_HOME/projects/$(printf '%s' "$bwt" | sed 's/[^A-Za-z0-9]/-/g')"
d=$(mktask b1 pr "$bwt")
printf 'done|2||PR is up https://github.com/o/r/pull/5\n' >>"$d/status"
printf 'd:PR is up https://github.com/o/r/pull/5' >"$d/.done-woke"
agent sheepr-b1 idle
review start b1 --kind claude --budget 30 >/dev/null
agent rv-b1 working s1
printf 'working on it\n' >"$FAKE/pane-w1:p9"
: >"$FAKE/calls"
out=$(pass_once); rc=$?
is "$out" 'overbudget: b1 reviewer 33/30' 'the reviewer over its own budget wakes overbudget:'
grep -q '^agent send-keys rv-b1 esc' "$FAKE/calls" && ok 'and the reviewer is interrupted' \
  || fail 'and the reviewer is interrupted' "$(cat "$FAKE/calls")"
out=$(pass_once); rc=$?
is "$rc" '1' 'the reviewer budget wakes once'
is "$("$SHEEPR_ROOT/bin/sheepr-usage.sh" task b1)" 'unknown claude-no-session' \
  "the worker's usage leaves out the reviewer's session"
is "$("$SHEEPR_ROOT/bin/sheepr-usage.sh" review b1)" '413 16 17 claude' 'usage review reads the reviewer session alone'

# --- the reviewer pane goes missing -------------------------------------------

rm -f "$FAKE/pane-w1:p9" "$FAKE/state-rv-b1"
sheepr_meta_set b1 review_budget ''
out=$(pass_once); rc=$?
is "$out" 'missing: b1 - no reviewer at the recorded pane' 'a reviewer pane that is gone wakes missing:'

# --- reopened -------------------------------------------------------------------

d=$(mktask o1 pr)
printf 'done|2||https://github.com/o/r/pull/5\n' >>"$d/status"
printf 'a fix plan\n' >"$SHEEPR_HOME/fix.md"
sheepr_meta_set o1 review_started 100
sheepr_meta_set o1 review_done ''
out=$(send o1 --reopen "$SHEEPR_HOME/fix.md"); rc=$?
is "$rc" '1' 'reopen is refused while a review is open'
sheepr_meta_set o1 review_done 200

printf 'd:https://github.com/o/r/pull/5' >"$d/.woke"
printf 'd:https://github.com/o/r/pull/5' >"$d/.done-woke"
agent sheepr-o1 working
out=$(send o1 --reopen "$SHEEPR_HOME/fix.md"); rc=$?
is "$rc" '0' 'reopen of a done task succeeds'
is "$(tail -1 "$d/status" | cut -d'|' -f1,3,4)" 'reopened|reopen-1|a fix plan' 'reopen appends the reopened verb'
is "$(sheepr_status_fold o1)" 'working||' 'reopened folds as working'
is "$(cat "$d/wt/fix-brief.md")" 'a fix plan' 'the plan reaches the worktree'
grep -q '^agent prompt sheepr-o1 .*fix-brief.md' "$FAKE/calls" && ok 'and the worker is told to read it' \
  || fail 'and the worker is told to read it'

out=$(send o1 --reopen "$SHEEPR_HOME/fix.md"); rc=$?
is "$rc" '1' 'reopen of a task that is not done is refused'

printf 'done|9||https://github.com/o/r/pull/5\n' >>"$d/status"
agent sheepr-o1 idle
is "$(pass_once)" 'done: o1 - https://github.com/o/r/pull/5' 'a done after reopen wakes again, same text or not'

# --- teardown closes the reviewer pane ----------------------------------------

wt="$SHEEPR_HOME/tdwt"; mkdir -p "$wt"
d=$(mktask td local "$wt")
sheepr_meta_set td review_pane w1:p9
: >"$FAKE/pane-w1:p9"
flock_doc "$(flock_row "$wt" sheepr/td '.ahead = 1')"
: >"$FAKE/calls"
out=$("$SHEEPR_ROOT/bin/sheepr-teardown.sh" td 2>&1); rc=$?
is "$rc" '0' 'teardown of landed work with a reviewer pane succeeds'
grep -q '^pane close w1:p9' "$FAKE/calls" && ok 'teardown closes the reviewer pane' \
  || fail 'teardown closes the reviewer pane' "$out"

finish
