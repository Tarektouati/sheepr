#!/usr/bin/env bash
# tests/sheepr-watch.test.sh - the decision ladder.
#
# herdr is stubbed by overriding sheepr_agent_state after sourcing, so the
# ladder is tested without a live fleet. The two properties that matter:
# a herdr `idle` never by itself means stopped, and nothing wakes twice for
# the same signature.

. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
. "$SHEEPR_ROOT/bin/sheepr-watch.sh"

begin

STUB_STATE=idle
# shellcheck disable=SC2317
sheepr_agent_state() { printf '%s' "$STUB_STATE"; }

mktask() {  # <id> <worktree-has-writes:yes|no>
  local id=$1 writes=${2:-no}
  local dir="$SHEEPR_HOME/tasks/$id"
  mkdir -p "$dir" "$dir/wt"
  cat >"$dir/meta" <<EOF
name=sheepr-$id
label=sheepr-$id
worktree=$dir/wt
workspace=w1
pane=w1:p1
EOF
  : >"$dir/status"
  [ "$writes" = yes ] && : >"$dir/wt/touched"
  printf '%s' "$dir"
}

verdict() {  # <id> -> "<signature>" or "" when not actionable
  local out
  out=$(inspect_task "$1") || { printf ''; return 0; }
  printf '%s' "${out%%	*}"
}

reason_of() {  # <id>
  local out
  out=$(inspect_task "$1") || { printf ''; return 0; }
  printf '%s' "${out#*	}"
}

# --- status log drives the verdict -----------------------------------------

d=$(mktask t-q)
printf 'working|1||started\nquestion|2|pick|a or b?\n' >"$d/status"
STUB_STATE=working
is "$(verdict t-q)" 'q:pick:a or b?' 'a question wakes even when herdr says working'
is "$(reason_of t-q)" 'question: t-q - pick: a or b?' 'the reason names the key and the text'

d=$(mktask t-d)
printf 'done|2||https://example.com/pr/1\n' >"$d/status"
is "$(verdict t-d)" 'd:https://example.com/pr/1' 'done wakes'

d=$(mktask t-f)
printf 'failed|2||could not reproduce\n' >"$d/status"
is "$(verdict t-f)" 'f:could not reproduce' 'failed wakes'

# --- herdr state ------------------------------------------------------------

mktask t-blocked >/dev/null
STUB_STATE=blocked
is "$(verdict t-blocked)" 'agent:blocked' 'a blocked agent wakes'

mktask t-working >/dev/null
STUB_STATE=working
is "$(verdict t-working)" '' 'a working agent is not actionable'

# --- idle proves nothing ----------------------------------------------------

d=$(mktask t-idle)
STUB_STATE=idle
is "$(verdict t-idle)" '' 'first idle pass opens a quiet window rather than waking'
[ -f "$d/.quiet-since" ] && ok 'the quiet window marker was created' \
  || fail 'the quiet window marker was created'

is "$(verdict t-idle)" '' 'a young quiet window does not wake'

# Age the window past the stall bound.
SHEEPR_STALL=1
touch -t 200001010000 "$d/.quiet-since"
sig=$(verdict t-idle)
case "$sig" in
  stalled:*) ok 'an idle agent with no writes and no status wakes as stalled' ;;
  *) fail 'an idle agent with no writes and no status wakes as stalled' "got: $sig" ;;
esac

# Same task, but a file in the worktree is newer than the quiet marker.
d=$(mktask t-idle-writes)
STUB_STATE=idle
verdict t-idle-writes >/dev/null          # opens the window
touch -t 200001010000 "$d/.quiet-since"   # age it
touch "$d/wt/touched"                     # a write after the window opened
is "$(verdict t-idle-writes)" '' \
  'file writes in the worktree defer the stall even though herdr says idle'
[ -f "$d/.quiet-since" ] || ok 'the quiet window is reset by write evidence'

# A growing status log is also evidence.
d=$(mktask t-idle-grows)
STUB_STATE=idle
verdict t-idle-grows >/dev/null
touch -t 200001010000 "$d/.quiet-since"
printf 'working|9||still here\n' >>"$d/status"
is "$(verdict t-idle-grows)" '' 'a growing status log defers the stall'

SHEEPR_STALL=240

# --- suppression ------------------------------------------------------------

STUB_STATE=idle

# pass_once walks every task, so drive it against a home with one task only.
ISOLATED=$(mktemp -d "${TMPDIR:-/tmp}/sheepr-iso-XXXXXX")
OLD_HOME=$SHEEPR_HOME
SHEEPR_HOME=$ISOLATED; SHEEPR_TASKS="$ISOLATED/tasks"; SHEEPR_WAKES="$SHEEPR_TASKS/.wakes"
TRIAGE="$SHEEPR_TASKS/.watch-triage.log"
mkdir -p "$SHEEPR_TASKS"
d=$(mktask solo)
printf 'question|2|k|pick one\n' >"$d/status"

out1=$(pass_once); rc1=$?
out2=$(pass_once); rc2=$?
is "$rc1" '0' 'the first pass is actionable'
is "$out1" 'question: solo - k: pick one' 'the first pass prints the reason'
is "$rc2" '1' 'the second pass absorbs the unchanged signature'
is "$out2" '' 'the absorbed pass prints nothing'
is "$(grep -c '' "$SHEEPR_WAKES")" '1' 'exactly one row reached the wake queue'

# A second question raised while the first is still open must NOT wake: the
# fold still reports the oldest open question, so the signature is unchanged
# and the captain is not asked the same thing twice.
printf 'question|3|k2|and another?\n' >>"$d/status"
out3=$(pass_once); rc3=$?
is "$rc3" '1' 'a second question is absorbed while the first is still open'
is "$(grep -c '' "$SHEEPR_WAKES")" '1' 'the wake queue did not grow'

# Answering the first surfaces the second.
printf 'resolved|4|k|\n' >>"$d/status"
out4=$(pass_once); rc4=$?
is "$rc4" '0' 'resolving the first question surfaces the second'
is "$out4" 'question: solo - k2: and another?' 'the second question is reported with its own key'
is "$(grep -c '' "$SHEEPR_WAKES")" '2' 'the wake queue grew to two rows'

# Resolving everything returns the task to silence.
printf 'resolved|5|k2|\n' >>"$d/status"
STUB_STATE=working
out5=$(pass_once); rc5=$?
is "$rc5" '1' 'a task with nothing open and a working agent is silent'

rm -rf "$ISOLATED"
SHEEPR_HOME=$OLD_HOME

# --- TERM stops the watcher, and the lock goes with it ----------------------
#
# The loop only exists in a subprocess, so this is the one test that runs the
# script rather than a function. herdr is stubbed on PATH: it always answers
# `working`, so the fleet below is never actionable and the loop keeps polling
# until it is signalled.

if ! command -v jq >/dev/null 2>&1; then
  skip 'jq is not installed, so the watch loop cannot start'
else
  STUB=$(mktemp -d "${TMPDIR:-/tmp}/sheepr-stub-XXXXXX")
  cat >"$STUB/herdr" <<'STUB_EOF'
#!/bin/sh
printf '{"result":{"agent":{"agent_status":"working"}}}\n'
STUB_EOF
  chmod +x "$STUB/herdr"

  TERM_HOME=$(mktemp -d "${TMPDIR:-/tmp}/sheepr-term-XXXXXX")
  mkdir -p "$TERM_HOME/tasks/t-term"
  printf 'name=sheepr-t-term\nlabel=sheepr-t-term\n' >"$TERM_HOME/tasks/t-term/meta"
  : >"$TERM_HOME/tasks/t-term/status"
  LOCK="$TERM_HOME/tasks/.watch.lock"

  PATH="$STUB:$PATH" HERDR_ENV=1 SHEEPR_HOME="$TERM_HOME" SHEEPR_POLL=1 \
    bash "$SHEEPR_ROOT/bin/sheepr-watch.sh" >/dev/null 2>&1 &
  wpid=$!

  waited=0
  while [ ! -d "$LOCK" ] && [ "$waited" -lt 10 ]; do sleep 1; waited=$((waited + 1)); done
  if [ -d "$LOCK" ]; then ok 'the watcher holds the lock while it polls'
  else fail 'the watcher holds the lock while it polls' 'no lock appeared in ten seconds'; fi

  kill -TERM "$wpid" 2>/dev/null
  waited=0
  while kill -0 "$wpid" 2>/dev/null && [ "$waited" -lt 10 ]; do sleep 1; waited=$((waited + 1)); done

  if kill -0 "$wpid" 2>/dev/null; then
    fail 'a watcher sent TERM exits' 'it was still polling ten seconds later'
    kill -9 "$wpid" 2>/dev/null
    wait "$wpid" 2>/dev/null
  else
    wait "$wpid"
    is "$?" '143' 'a watcher sent TERM exits, and exits as terminated'
  fi

  if [ -d "$LOCK" ]; then fail 'the lock is gone once the watcher has stopped' 'the lock is still there'
  else ok 'the lock is gone once the watcher has stopped'; fi

  rm -rf "$STUB" "$TERM_HOME"
fi

finish
