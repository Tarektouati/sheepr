#!/usr/bin/env bash
# tests/sheepr-hooks.test.sh - the background watch modes and their hooks.
#
# Every case runs the script as a subprocess against its own SHEEPR_HOME, with
# herdr stubbed on PATH. The stub answers `agent get` for the supervisor pane
# from a state file, records every `agent prompt`, and reads every other agent
# as `working`, so a task is only actionable through its status log.
#
# The properties that matter: no hook mode parks the session, no wake is
# recorded before it was delivered, and a held lock keeps a second watcher out.

. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

begin

if ! command -v jq >/dev/null 2>&1; then
  skip 'jq is not installed, so the watcher cannot start'
  finish
fi

WATCH="$SHEEPR_ROOT/bin/sheepr-watch.sh"
PANE='w9:p1'

STUB=$(mktemp -d "${TMPDIR:-/tmp}/sheepr-hstub-XXXXXX")
cat >"$STUB/herdr" <<'STUB_EOF'
#!/bin/sh
d=$STUB_DIR
case "$1 $2" in
  "agent get")
    if [ "$3" = "$STUB_PANE" ]; then
      if [ -f "$d/gone" ]; then
        printf '{"error":{"code":"agent_not_found","message":"not found"}}\n'
        exit 1
      fi
      printf '{"result":{"agent":{"agent":"codex","agent_status":"%s"}}}\n' "$(cat "$d/pane-state")"
    else
      printf '{"result":{"agent":{"agent":"cursor","agent_status":"working"}}}\n'
    fi
    ;;
  "agent prompt")
    if [ -f "$d/prompt-fails" ]; then
      printf '{"error":{"code":"boom"}}\n'
      exit 1
    fi
    printf '%s\n' "$4" >>"$d/prompts"
    printf 'working' >"$d/pane-state"
    printf '{"result":{}}\n'
    ;;
  *) printf '{}\n' ;;
esac
STUB_EOF
chmod +x "$STUB/herdr"

HOMES=()
cleanup_all() {
  local h pid
  for h in "${HOMES[@]}"; do
    pid=$(cat "$h/tasks/.watch.lock/pid" 2>/dev/null) && kill -9 "$pid" 2>/dev/null
    rm -rf "$h"
  done
  rm -rf "$STUB"
  cleanup_home
}
trap cleanup_all EXIT

# A fresh home and stub state. <kind>: question (actionable), quiet, empty.
newhome() {  # <kind>
  H=$(mktemp -d "${TMPDIR:-/tmp}/sheepr-hhome-XXXXXX")
  HOMES+=("$H")
  SD="$H/stub"; mkdir -p "$SD" "$H/tasks"
  printf 'idle' >"$SD/pane-state"
  [ "$1" = empty ] && return 0
  mkdir -p "$H/tasks/t1"
  printf 'name=sheepr-t1\nlabel=sheepr-t1\n' >"$H/tasks/t1/meta"
  : >"$H/tasks/t1/status"
  [ "$1" = question ] && printf 'question|1|pick|a or b?\n' >"$H/tasks/t1/status"
  return 0
}

watch() {  # <args...>  runs the watcher under the stub, in the current home
  env -u CURSOR_VERSION PATH="$STUB:$PATH" HERDR_ENV=1 SHEEPR_HOME="$H" \
    SHEEPR_POLL=1 STUB_DIR="$SD" STUB_PANE="$PANE" HERDR_PANE_ID="$PANE" \
    bash "$WATCH" "$@"
}

wait_for() {  # <seconds> <test-command...>
  local limit=$1 waited=0; shift
  while ! "$@" && [ "$waited" -lt "$limit" ]; do sleep 1; waited=$((waited + 1)); done
  "$@"
}

lock_pid() { cat "$H/tasks/.watch.lock/pid" 2>/dev/null; }
holds_lock() { [ -d "$H/tasks/.watch.lock" ]; }
not_holds_lock() { [ ! -d "$H/tasks/.watch.lock" ]; }
woke() { [ -f "$H/tasks/t1/.woke" ]; }
prompted() { [ -s "$SD/prompts" ]; }
wake_rows() { grep -c '' "$H/tasks/.wakes" 2>/dev/null || printf '0'; }

# Hold the lock with a live process that is not a watcher.
hold_lock() {
  sleep 60 &
  HOLDER=$!
  mkdir -p "$H/tasks/.watch.lock"
  printf '%s' "$HOLDER" >"$H/tasks/.watch.lock/pid"
}
release_held() { kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null; }

# --- --hook claude ------------------------------------------------------------

newhome question
err=$(watch --hook claude 2>&1 >/dev/null); rc=$?
is "$rc" '2' 'claude: a wake exits 2, which is what asyncRewake wakes on'
is "$err" 'question: t1 - pick: a or b?' 'claude: the reason is on stderr'
woke && ok 'claude: the wake is recorded after it was delivered' \
  || fail 'claude: the wake is recorded after it was delivered'
not_holds_lock && ok 'claude: the lock is released on exit' \
  || fail 'claude: the lock is released on exit'

newhome empty
out=$(watch --hook claude 2>&1); rc=$?
is "$rc:$out" '0:' 'claude: an empty fleet exits 0 with no output'

newhome question
hold_lock
out=$(watch --hook claude 2>&1); rc=$?
is "$rc:$out" '0:' 'claude: a held lock exits 0 silently'
woke && fail 'claude: a held lock leaves task state alone' 'found .woke' \
  || ok 'claude: a held lock leaves task state alone'
release_held

newhome question
out=$(run_bounded 10 env CURSOR_VERSION=9.9 PATH="$STUB:$PATH" HERDR_ENV=1 \
  SHEEPR_HOME="$H" STUB_DIR="$SD" bash "$WATCH" --hook claude); rc=$?
is "$rc:$out" '0:' 'claude: under Cursor the imported hook stands down at once'
holds_lock && fail 'claude: under Cursor no lock is taken' \
  || ok 'claude: under Cursor no lock is taken'
woke && fail 'claude: under Cursor nothing is recorded' || ok 'claude: under Cursor nothing is recorded'

# --- --hook cursor ------------------------------------------------------------

newhome question
out=$(run_bounded 20 watch --hook cursor); rc=$?
is "$rc" '0' 'cursor: the stop hook returns instead of parking'
is "$(printf '%s' "$out" | jq -r .followup_message)" 'question: t1 - pick: a or b?' \
  'cursor: a wake is a followup_message carrying the reason'
woke && ok 'cursor: the wake is recorded' || fail 'cursor: the wake is recorded'

newhome quiet
out=$(run_bounded 20 watch --hook cursor); rc=$?
is "$rc" '0' 'cursor: a quiet fleet with no watcher returns at once'
case "$(printf '%s' "$out" | jq -r .followup_message)" in
  *"Start ./bin/sheepr-watch.sh as a background command"*)
    ok 'cursor: with no watcher armed, the hook asks the supervisor to start one' ;;
  *) fail 'cursor: with no watcher armed, the hook asks the supervisor to start one' "got: $out" ;;
esac

newhome question
hold_lock
out=$(run_bounded 20 watch --hook cursor); rc=$?
is "$rc:$out" '0:' 'cursor: a running watcher means the hook says nothing'
woke && fail 'cursor: a running watcher keeps the hook off task state' \
  || ok 'cursor: a running watcher keeps the hook off task state'
release_held

out=$(run_bounded 20 watch --hook); rc=$?
is "$rc" '0' 'cursor: bare --hook still works and still returns'

# --- --once and the loop under a held lock -----------------------------------

newhome question
hold_lock
out=$(watch --once); rc=$?
is "$rc" '3' '--once with the lock held exits 3'
is "$out" "watching: a watcher already owns the fleet (pid $HOLDER)" \
  '--once with the lock held says who owns the fleet'
woke && fail '--once with the lock held does no pass' || ok '--once with the lock held does no pass'

out=$(watch); rc=$?
is "$rc:$out" "0:watching: a watcher already owns the fleet (pid $HOLDER)" \
  'the loop with the lock held leaves one line, so Cursor does not re-arm it'
release_held

# --- --hook codex -------------------------------------------------------------

newhome quiet
out=$(run_bounded 10 watch --hook codex); rc=$?
is "$rc:$out" '0:' 'codex: the hook returns at once with no stdout'
wait_for 10 holds_lock && ok 'codex: a detached watcher took the lock' \
  || fail 'codex: a detached watcher took the lock'
is "$(cat "$H/tasks/.watch.lock/pane" 2>/dev/null)" "$PANE" \
  'codex: the lock records which pane it delivers to'
first=$(lock_pid)

out=$(run_bounded 10 watch --hook codex); rc=$?
is "$rc:$out" '0:' 'codex: a second Stop with a watcher running says nothing'
sleep 2
is "$(lock_pid)" "$first" 'codex: no second watcher replaced the first'
kill -TERM "$first" 2>/dev/null
wait_for 10 not_holds_lock && ok 'codex: the detached watcher releases the lock on TERM' \
  || fail 'codex: the detached watcher releases the lock on TERM'

newhome quiet
out=$(run_bounded 10 env -u HERDR_PANE_ID -u CURSOR_VERSION PATH="$STUB:$PATH" \
  HERDR_ENV=1 SHEEPR_HOME="$H" STUB_DIR="$SD" bash "$WATCH" --hook codex); rc=$?
is "$rc" '0' 'codex: with no Herdr pane the hook still returns'
case "$(printf '%s' "$out" | jq -r .systemMessage 2>/dev/null)" in
  *"HERDR_PANE_ID is not set"*) ok 'codex: with no Herdr pane the refusal is reported' ;;
  *) fail 'codex: with no Herdr pane the refusal is reported' "got: $out" ;;
esac
sleep 2
holds_lock && fail 'codex: with no Herdr pane no watcher is started' \
  || ok 'codex: with no Herdr pane no watcher is started'

# --- --wake-pane ----------------------------------------------------------------

newhome question
printf 'working' >"$SD/pane-state"
watch --wake-pane "$PANE" >/dev/null 2>&1 &
wpid=$!
sleep 3
prompted && fail 'pane: nothing is typed while the supervisor is working' \
  || ok 'pane: nothing is typed while the supervisor is working'
woke && fail 'pane: an undelivered wake is not recorded' \
  || ok 'pane: an undelivered wake is not recorded'
printf 'idle' >"$SD/pane-state"
wait_for 15 woke
wait "$wpid" 2>/dev/null
is "$(cat "$SD/prompts" 2>/dev/null)" 'sheepr wake: question: t1 - pick: a or b?' \
  'pane: once idle, the wake is submitted exactly once'
woke && ok 'pane: the delivered wake is recorded' || fail 'pane: the delivered wake is recorded'
is "$(wake_rows)" '1' 'pane: one row reached the wake queue'
not_holds_lock && ok 'pane: the watcher exits after one wake and frees the lock' \
  || fail 'pane: the watcher exits after one wake and frees the lock'

newhome question
: >"$SD/prompt-fails"
watch --wake-pane "$PANE" >/dev/null 2>&1 &
wpid=$!
sleep 3
woke && fail 'pane: a failed submit records nothing' || ok 'pane: a failed submit records nothing'
is "$(wake_rows)" '0' 'pane: a failed submit adds nothing to the wake queue'
rm -f "$SD/prompt-fails"
printf 'idle' >"$SD/pane-state"
wait_for 15 woke
wait "$wpid" 2>/dev/null
is "$(grep -c '' "$SD/prompts" 2>/dev/null)" '1' 'pane: the retry delivers it once'
is "$(wake_rows)" '1' 'pane: and records it once'

newhome question
: >"$SD/gone"
out=$(run_bounded 15 watch --wake-pane "$PANE"); rc=$?
is "$rc" '0' 'pane: a pane with no agent ends the watcher'
prompted && fail 'pane: nothing is typed into a pane with no agent' \
  || ok 'pane: nothing is typed into a pane with no agent'
woke && fail 'pane: the wake stays unrecorded for the next session' \
  || ok 'pane: the wake stays unrecorded for the next session'
not_holds_lock && ok 'pane: the lock is released' || fail 'pane: the lock is released'

# --- the shipped hook configuration -------------------------------------------

cfg="$SHEEPR_ROOT/.claude/settings.json"
is "$(jq -r '.hooks.Stop[0].hooks[0] | "\(.command)|\(.asyncRewake)|\(.timeout)"' "$cfg")" \
  '"${CLAUDE_PROJECT_DIR}"/bin/sheepr-watch.sh --hook claude|true|28800' \
  'claude settings: an asyncRewake Stop hook with the long timeout'
max=$(sed -n 's/^SHEEPR_HOOK_MAX=\${SHEEPR_HOOK_MAX:-\([0-9]*\)}$/\1/p' "$WATCH")
[ -n "$max" ] && [ "$max" -lt "$(jq -r '.hooks.Stop[0].hooks[0].timeout' "$cfg")" ] \
  && ok 'claude settings: the watcher gives up before the hook timeout kills it' \
  || fail 'claude settings: the watcher gives up before the hook timeout kills it' "max=$max"

cfg="$SHEEPR_ROOT/.codex/hooks.json"
is "$(jq -r '.hooks.Stop[0].hooks[0] | "\(.command)|\(.async)"' "$cfg")" \
  '"$(git rev-parse --show-toplevel)/bin/sheepr-watch.sh" --hook codex|true' \
  'codex hooks: an async Stop hook'

cfg="$SHEEPR_ROOT/.cursor/hooks.json"
is "$(jq -r '.hooks.stop[0] | "\(.command)|\(.timeout)"' "$cfg")" \
  '"$CURSOR_PROJECT_DIR"/bin/sheepr-watch.sh --hook cursor|30' \
  'cursor hooks: a short stop hook in cursor mode'

finish
