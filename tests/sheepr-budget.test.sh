#!/usr/bin/env bash
# tests/sheepr-budget.test.sh - budgets: the interrupt, the re-arm, the warning.
#
# herdr is a fake on PATH that logs every call, so the interrupt is checked by
# the keys that reached it. Usage is read by the real bin/sheepr-usage.sh from
# the usage fixtures: task worktree /wt/alpha under claude spent 16 fresh input
# and 17 output tokens (413 in all, the rest cache), so its spend is 33.
#
# The properties that matter: spend is input + output, never the total; the
# wake comes once per budget and a new budget re-arms it; a budget that cannot
# be enforced says so once; nothing is ever discarded.

. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
. "$SHEEPR_ROOT/bin/sheepr-watch.sh"

begin

SHEEPR_CLAUDE_HOME="$SHEEPR_ROOT/tests/fixtures/usage/claude"
export SHEEPR_CLAUDE_HOME

# --- the fake herdr -----------------------------------------------------------

FAKE=$(mktemp -d "${TMPDIR:-/tmp}/sheepr-fakeherdr-XXXXXX")
FAKE_HERDR_LOG="$FAKE/calls"
FAKE_HERDR_STATE="$FAKE/state"
FAKE_HERDR_KIND="$FAKE/kind"
export FAKE_HERDR_LOG FAKE_HERDR_STATE FAKE_HERDR_KIND
cat >"$FAKE/herdr" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$FAKE_HERDR_LOG"
case "$1 $2" in
  "agent get")
    printf '{"result":{"agent":{"agent":"%s","agent_status":"%s"}}}\n' \
      "$(cat "$FAKE_HERDR_KIND")" "$(cat "$FAKE_HERDR_STATE")" ;;
  *) printf '{"result":{"type":"ok"}}\n' ;;
esac
EOF
chmod +x "$FAKE/herdr"
PATH="$FAKE:$PATH"
trap 'rm -rf "$FAKE"; cleanup_home' EXIT

herdr_says() {  # <state> [kind]
  printf '%s' "$1" >"$FAKE_HERDR_STATE"
  printf '%s' "${2:-claude}" >"$FAKE_HERDR_KIND"
  : >"$FAKE_HERDR_LOG"
}
keys_sent() { grep '^agent send-keys' "$FAKE_HERDR_LOG" 2>/dev/null | cut -d' ' -f3- | tr '\n' ';'; }

# One task at a time, so pass_once sees only it.
mktask() {  # <id> <kind> <worktree> [budget]
  rm -rf "${SHEEPR_TASKS:?}"/*
  local dir="$SHEEPR_TASKS/$1"
  mkdir -p "$dir"
  {
    printf 'name=sheepr-%s\nlabel=sheepr-%s\nkind=%s\nworktree=%s\n' "$1" "$1" "$2" "$3"
    [ -z "${4:-}" ] || printf 'budget=%s\n' "$4"
  } >"$dir/meta"
  : >"$dir/status"
  printf '%s' "$dir"
}

send() { "$SHEEPR_ROOT/bin/sheepr-send.sh" "$@" 2>&1; }

# --- over budget: interrupt, then wake ----------------------------------------

d=$(mktask b1 claude /wt/alpha 30)
herdr_says working
out=$(pass_once); rc=$?
is "$rc" '0' 'a worker over its budget wakes'
is "$out" 'overbudget: b1 33/30' 'the wake shows input + output, not the 413 total, over the budget'
is "$(keys_sent)" 'sheepr-b1 esc;' 'a working claude worker is interrupted with esc'
is "$(cat "$d/meta" | grep -c '^worktree=')" '1' 'the task is kept'

herdr_says working
out=$(pass_once); rc=$?
is "$rc" '1' 'the same budget does not wake twice'
is "$(keys_sent)" 'sheepr-b1 esc;' 'but a worker still spending is interrupted again'

herdr_says idle
pass_once >/dev/null
is "$(keys_sent)" '' 'an idle worker gets no keys: a stray esc can open a menu'

# The budget wake must not hide what the worker says next.
printf 'question|5|scope|stop here or finish the tests?\n' >>"$d/status"
out=$(pass_once); rc=$?
is "$out" 'question: b1 - scope: stop here or finish the tests?' \
  'a question after the overbudget wake still wakes'
out=$(pass_once); rc=$?
is "$rc" '1' 'and the overbudget wake does not come round again after it'
printf 'resolved|6|scope|finish\n' >>"$d/status"

# --- at the budget counts as over --------------------------------------------

mktask b2 claude /wt/alpha 33 >/dev/null
herdr_says working
is "$(pass_once)" 'overbudget: b2 33/33' 'a spend equal to the budget is over it'

mktask b3 claude /wt/alpha 34 >/dev/null
herdr_says working
pass_once >/dev/null; rc=$?
is "$rc" '1' 'a spend under the budget is quiet'
is "$(keys_sent)" '' 'and nobody is interrupted'

# --- cursor: esc, then empty the composer ------------------------------------

mktask b4 claude /wt/alpha 10 >/dev/null
herdr_says working cursor
pass_once >/dev/null
is "$(keys_sent)" 'sheepr-b4 esc;sheepr-b4 ctrl+u;' \
  'cursor gets esc then ctrl+u, so the cancelled prompt is not left in the composer'

# A kind with no checked key gets nothing, and the wake says so.
mktask b5 claude /wt/alpha 10 >/dev/null
herdr_says working nosuchkind
out=$(pass_once 2>/dev/null)
is "$(keys_sent)" '' 'an unknown kind gets no keys'
is "$out" 'overbudget: b5 33/10 (interrupt failed; the worker may still be spending)' \
  'a failed interrupt is reported in the wake'

# --- raising the budget re-arms it -------------------------------------------

d=$(mktask b6 claude /wt/alpha 30)
herdr_says idle
is "$(pass_once)" 'overbudget: b6 33/30' 'over the first budget'

is "$(send b6 --budget 100)" 'budget for b6: 30 -> 100' 'send --budget records the new budget'
is "$(sheepr_meta_get b6 budget)" '100' 'and it is in meta'
pass_once >/dev/null; rc=$?
is "$rc" '1' 'under the raised budget the task is quiet'

send b6 --budget 33 >/dev/null
is "$(pass_once)" 'overbudget: b6 33/33' 'a new budget, crossed again, wakes again'

for bad in 0 -5 abc 1.5 ''; do
  out=$(send b6 --budget "$bad"); rc=$?
  is "$rc" '1' "send --budget refuses '$bad'"
done
is "$(sheepr_meta_get b6 budget)" '33' 'a refused budget leaves meta alone'
out=$(send nosuch --budget 10); rc=$?
is "$rc" '1' 'send --budget refuses an unknown task'

# --- unknown usage: warn once, never pretend ---------------------------------

mktask w1 cursor /wt/alpha 500000 >/dev/null
herdr_says working cursor
out=$(pass_once); rc=$?
is "$out" 'warning: w1 budget not enforced (cursor-unreadable)' 'an unmeasurable kind warns'
is "$(keys_sent)" '' 'and nobody is interrupted on a guess'
pass_once >/dev/null; rc=$?
is "$rc" '1' 'the warning comes once'

# A worker that has not yet written a session log is normal at spawn. It is
# warned about only once that has lasted the stall window.
d=$(mktask w2 claude /wt/no-such-session 500000)
herdr_says working
pass_once >/dev/null; rc=$?
is "$rc" '1' 'no session yet is not warned about straight away'
touch -t 200001010000 "$d/.usage-unknown-since"
is "$(pass_once)" 'warning: w2 budget not enforced (claude-no-session)' \
  'no session for longer than the stall window warns'
pass_once >/dev/null; rc=$?
is "$rc" '1' 'and only once'

# A finished task spends nothing more; its done is what matters.
d=$(mktask w3 claude /wt/alpha 10)
printf 'done|9||pushed sheepr/w3\n' >"$d/status"
herdr_says idle
is "$(pass_once)" 'done: w3 - pushed sheepr/w3' 'a done task over budget reports done, not overbudget'

# --- every wake is one short line --------------------------------------------

long=$(printf 'x%.0s' $(seq 1 300))
d=$(mktask t1 claude /wt/alpha)
printf 'question|1|k|%s\n' "$long" >"$d/status"
out=$(pass_once)
is "$(printf '%s\n' "$out" | grep -c '')" '1' 'a wake is one line'
quoted=${out#question: t1 - }
is "${#quoted}" '120' 'the quoted text is cut to 120 characters'
case "$quoted" in *...) ok 'and the cut is marked' ;; *) fail 'and the cut is marked' "got: $quoted" ;; esac
is "$(cat "$d/.woke")" "q:k:$long" 'the signature keeps the whole text'

is "$(excerpt "$(printf 'a\tb\nc')")" 'a b c' 'control characters become spaces'
is "$(excerpt short)" 'short' 'short text is left alone'

finish
