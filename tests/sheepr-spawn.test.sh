#!/usr/bin/env bash
# tests/sheepr-spawn.test.sh - the argument parser, and spawns run in parallel.
#
# Nothing here reaches herdr. Spawn parses its arguments before it touches the
# environment, which is what makes a parser bug so expensive: it strikes on
# every machine, live fleet or not.

. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

begin

spawn() { "$SHEEPR_ROOT/bin/sheepr-spawn.sh" "$@" 2>&1; }

# --- a flag with no value is refused, not spun on ---------------------------
#
# A trailing flag used to leave $# at 1 forever: `shift 2` shifts nothing, and
# the while loop burned a core until the pane was killed.

for flag in --kind --delivery --brief --model --budget --route; do
  out=$(run_bounded 5 spawn "$SHEEPR_ROOT" t1 "$flag"); rc=$?
  is "$rc" '1' "$flag with no value is refused rather than looping forever"
  case "$out" in *"$flag needs a value"*) ok "the refusal names $flag" ;;
    *) fail "the refusal names $flag" "got: $out" ;; esac
done

# The live repro: a complete command line whose last flag lost its value.
out=$(run_bounded 5 spawn "$SHEEPR_ROOT" t1 --kind cursor --delivery pr --brief); rc=$?
is "$rc" '1' 'a trailing --brief after valid flags is refused'

# --- the parser still accepts a well formed line ----------------------------
#
# Refusing too much is as broken as refusing too little, so check the values
# arrive: this line gets past the parser and fails on the missing brief file.

out=$(run_bounded 5 spawn "$SHEEPR_ROOT" t1 --kind cursor --delivery pr --brief /nonexistent/brief.md); rc=$?
is "$rc" '1' 'a complete line is still refused when the brief file is missing'
case "$out" in *'brief file not found'*) ok 'and it is refused for the brief, not for the parse' ;;
  *) fail 'and it is refused for the brief, not for the parse' "got: $out" ;; esac

# --- model, budget and route ---------------------------------------------
#
# Each is checked before anything touches herdr, so a bad value never leaves a
# half-made workspace behind. A good value gets past the parser and stops at
# the missing brief file.

ok_line() { run_bounded 5 spawn "$SHEEPR_ROOT" t1 --kind claude --delivery local \
  --brief /nonexistent/brief.md "$@"; }

for pair in '--model|-m' '--model|a b' '--model|$(id)' \
            '--budget|0' '--budget|-5' '--budget|10k' '--budget|1.5' \
            '--route|-x' '--route|a b'; do
  flag=${pair%%|*}; val=${pair#*|}
  out=$(ok_line "$flag" "$val"); rc=$?
  is "$rc" '1' "$flag '$val' is refused"
  case "$out" in *"$flag '$val'"*) ok "  and the refusal names $flag" ;;
    *) fail "  and the refusal names $flag" "got: $out" ;; esac
done

out=$(ok_line --model claude-opus-5-5 --budget 1500000 --route default); rc=$?
is "$rc" '1' 'valid --model --budget --route reach the brief check'
case "$out" in *'brief file not found'*) ok 'and are refused for the brief, not for the flags' ;;
  *) fail 'and are refused for the brief, not for the flags' "got: $out" ;; esac

out=$(ok_line --model composer-2.5); rc=$?
case "$out" in *'brief file not found'*) ok 'a model id with a dot is accepted' ;;
  *) fail 'a model id with a dot is accepted' "got: $out" ;; esac

# --- parallel spawns ---------------------------------------------------------
#
# Everything below runs spawn end to end with herdr stubbed on PATH. The stub
# creates a real git worktree, and can be told to hold inside `worktree create`
# until the test releases it: that is the window, often a minute long, in which
# a supervisor running several spawns writes its next brief.

if ! command -v jq >/dev/null 2>&1; then
  skip 'jq is not installed, so spawn cannot read herdr responses'
  finish
fi

GIT="git -c user.email=t@x -c user.name=test -c commit.gpgsign=false -c init.defaultBranch=main"
REPO="$SHEEPR_HOME/repo"
mkdir -p "$REPO"
( cd "$REPO" && $GIT init -q -b main && printf 'x\n' >a.txt \
    && $GIT add -A && $GIT commit -qm init ) >/dev/null 2>&1

STUB=$(mktemp -d "${TMPDIR:-/tmp}/sheepr-sstub-XXXXXX")
cat >"$STUB/herdr" <<'STUB_EOF'
#!/bin/sh
d=$STUB_DIR
case "$1 $2" in
  "worktree create")
    shift 2
    cwd=''; branch=''; label=''
    while [ $# -gt 0 ]; do
      case "$1" in
        --cwd) cwd=$2; shift 2 ;;
        --branch) branch=$2; shift 2 ;;
        --label) label=$2; shift 2 ;;
        *) shift ;;
      esac
    done
    printf '%s\n' "$label" >>"$d/creates"
    if [ -f "$d/hold" ]; then
      : >"$d/entered-$label"
      while [ ! -f "$d/release" ]; do sleep 0.1; done
    fi
    if [ -f "$d/create-fails" ]; then
      printf '{"error":{"code":"boom"}}\n'
      exit 1
    fi
    wt="$d/wt-$label"
    git -C "$cwd" worktree add -q -b "$branch" "$wt" >/dev/null 2>&1 || exit 1
    printf '{"result":{"workspace":{"workspace_id":"w-%s"},"root_pane":{"pane_id":"p-%s"},"worktree":{"path":"%s"}}}\n' \
      "$label" "$label" "$wt"
    ;;
  "agent get") printf '{"result":{"agent":{"agent":"cursor","agent_status":"working"}}}\n' ;;
  *) printf '{"result":{}}\n' ;;
esac
STUB_EOF
chmod +x "$STUB/herdr"
trap 'rm -rf "$STUB"; cleanup_home' EXIT

# Spawn records the base flock detects; the fake reports origin/main.
use_fake_flock

stub_spawn() {  # <id> <brief>
  env PATH="$STUB:$PATH" HERDR_ENV=1 STUB_DIR="$STUB" SHEEPR_HOME="$SHEEPR_HOME" \
    SHEEPR_FLOCK="$SHEEPR_FLOCK" FAKE_FLOCK_JSON="${FAKE_FLOCK_JSON:-}" FAKE_FLOCK_FAIL="${FAKE_FLOCK_FAIL:-0}" \
    "$SHEEPR_ROOT/bin/sheepr-spawn.sh" "$REPO" "$1" --kind cursor --delivery local --brief "$2" 2>&1
}

wait_for() {  # <file> - up to ten seconds
  local _
  for _ in $(seq 1 100); do [ -e "$1" ] && return 0; sleep 0.1; done
  return 1
}

# Rewriting the brief file while spawn waits on herdr must not change what the
# worker is given. With one shared /tmp/brief.md this used to hand task A's
# worker task B's instructions, silently.

BRIEF="$SHEEPR_HOME/shared-brief.md"
printf 'TASK A: fix the login flake\n' >"$BRIEF"
: >"$STUB/hold"
stub_spawn race-a "$BRIEF" >"$SHEEPR_HOME/race-a.out" &
pid_a=$!
if wait_for "$STUB/entered-sheepr-race-a"; then
  printf 'TASK B: rewrite the billing page\n' >"$BRIEF"
  : >"$STUB/release"
  wait "$pid_a"; rc=$?
  is "$rc" '0' 'a spawn whose brief file is rewritten mid-spawn still succeeds'
  wt_brief="$STUB/wt-sheepr-race-a/brief.md"
  case "$(cat "$wt_brief" 2>/dev/null)" in
    *'TASK A'*) ok 'the worker gets the brief as it was when spawn started' ;;
    *) fail 'the worker gets the brief as it was when spawn started' "got: $(head -3 "$wt_brief" 2>&1)" ;;
  esac
  grep -q 'TASK B' "$wt_brief" 2>/dev/null \
    && fail 'the rewritten brief never reaches the worker' \
    || ok 'the rewritten brief never reaches the worker'
  is "$(cat "$SHEEPR_HOME/tasks/race-a/brief.md")" 'TASK A: fix the login flake' \
    'the task keeps the brief it was spawned with'
else
  fail 'spawn reached worktree creation' "$(cat "$SHEEPR_HOME/race-a.out")"
  kill "$pid_a" 2>/dev/null
fi
rm -f "$STUB/hold" "$STUB/release"

# Two spawns of one id: the second is refused while the first is still inside
# worktree creation, before it creates anything of its own.

printf 'the first one\n' >"$SHEEPR_HOME/dup1.md"
printf 'the second one\n' >"$SHEEPR_HOME/dup2.md"
: >"$STUB/creates"
: >"$STUB/hold"
stub_spawn dup "$SHEEPR_HOME/dup1.md" >"$SHEEPR_HOME/dup1.out" &
pid_1=$!
if wait_for "$STUB/entered-sheepr-dup"; then
  out=$(run_bounded 10 stub_spawn dup "$SHEEPR_HOME/dup2.md"); rc=$?
  is "$rc" '1' 'a second spawn of an id that is still being spawned is refused'
  case "$out" in *'being spawned by another'*) ok 'the refusal says another spawn holds the id' ;;
    *) fail 'the refusal says another spawn holds the id' "got: $out" ;; esac
  is "$(grep -c 'sheepr-dup' "$STUB/creates")" '1' 'the refused spawn never asked herdr for a worktree'
  : >"$STUB/release"
  wait "$pid_1"; rc=$?
  is "$rc" '0' 'the first spawn of the id still completes'
  is "$(cat "$SHEEPR_HOME/tasks/dup/brief.md")" 'the first one' 'and the task holds the first brief, not the second'
else
  fail 'spawn reached worktree creation' "$(cat "$SHEEPR_HOME/dup1.out")"
  kill "$pid_1" 2>/dev/null
fi
rm -f "$STUB/hold" "$STUB/release"

out=$(run_bounded 10 stub_spawn dup "$SHEEPR_HOME/dup2.md"); rc=$?
is "$rc" '1' 'spawning an id that already exists is refused'
case "$out" in *"task 'dup' already exists"*) ok 'and the refusal says the task exists' ;;
  *) fail 'and the refusal says the task exists' "got: $out" ;; esac
[ -d "$SHEEPR_HOME/tasks/dup" ] && ok 'the refusal leaves the existing task alone' \
  || fail 'the refusal leaves the existing task alone'

# A spawn that fails before the task exists must give the id back, or it stays
# taken by a directory no other command lists.

printf 'a brief\n' >"$SHEEPR_HOME/fails.md"
: >"$STUB/create-fails"
out=$(run_bounded 10 stub_spawn fails "$SHEEPR_HOME/fails.md"); rc=$?
is "$rc" '1' 'a spawn whose worktree cannot be created fails'
[ -e "$SHEEPR_HOME/tasks/fails" ] && fail 'a failed spawn releases its claim on the id' "$(ls -la "$SHEEPR_HOME/tasks/fails")" \
  || ok 'a failed spawn releases its claim on the id'
rm -f "$STUB/create-fails"
out=$(run_bounded 10 stub_spawn fails "$SHEEPR_HOME/fails.md"); rc=$?
is "$rc" '0' 'the id can be spawned again after a failed attempt'

# --- the base ------------------------------------------------------------------
#
# A review diffs a branch or local task against meta's base, so spawn records
# the one flock detects, and refuses rather than guess when flock cannot say.

is "$(grep '^base=' "$SHEEPR_HOME/tasks/fails/meta")" 'base=origin/main' \
  'spawn records the base flock detects in meta'

printf 'a brief\n' >"$SHEEPR_HOME/nobase.md"
out=$(FAKE_FLOCK_FAIL=1 run_bounded 10 stub_spawn nobase "$SHEEPR_HOME/nobase.md"); rc=$?
is "$rc" '1' 'spawn refuses when flock cannot read the repository'
case "$out" in *'base branch is unknown'*) ok 'and the refusal says the base is unknown' ;;
  *) fail 'and the refusal says the base is unknown' "got: $out" ;; esac
[ -e "$SHEEPR_HOME/tasks/nobase" ] && fail 'a spawn refused for its base claims no id' \
  || ok 'a spawn refused for its base claims no id'

# The placeholder check reads the snapshot too, and still refuses.

printf 'fix {{thing}} please\n' >"$SHEEPR_HOME/ph.md"
out=$(run_bounded 10 stub_spawn ph "$SHEEPR_HOME/ph.md"); rc=$?
is "$rc" '1' 'a brief with a placeholder is still refused'
case "$out" in *'{{thing}}'*) ok 'and the refusal names the placeholder' ;;
  *) fail 'and the refusal names the placeholder' "got: $out" ;; esac
[ -e "$SHEEPR_HOME/tasks/ph" ] && fail 'a refused brief claims no id' || ok 'a refused brief claims no id'

leftover=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'sheepr-brief-*' -newer "$REPO/a.txt" 2>/dev/null | head -3)
is "$leftover" '' 'no brief snapshot is left behind in the temp directory'

finish
