#!/usr/bin/env bash
# tests/sheepr-send.test.sh - answering a worker.
#
# The regression that matters: the answer must be written INTO the resolved
# line. An empty resolved line reads to a worker as "answered with nothing",
# and it asks the same question again. That happened in a live run.

. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
. "$SHEEPR_ROOT/bin/sheepr-status.sh"

begin

mktask() {  # <id>
  mkdir -p "$SHEEPR_HOME/tasks/$1"
  printf 'name=sheepr-%s\nlabel=sheepr-%s\n' "$1" "$1" >"$SHEEPR_HOME/tasks/$1/meta"
  : >"$SHEEPR_HOME/tasks/$1/status"
}

send() { SHEEPR_HOME="$SHEEPR_HOME" "$SHEEPR_ROOT/bin/sheepr-send.sh" "$@" 2>&1; }

# --- validation happens before the environment is checked -------------------

mktask t1
printf 'question|1|wanted|which one?\n' >"$SHEEPR_HOME/tasks/t1/status"

out=$(send t1 'an answer' --resolve not-open); rc=$?
is "$rc" '1' 'resolving a key that is not open is refused'
case "$out" in *"is not open on t1"*) ok 'the refusal says the key is not open' ;;
  *) fail 'the refusal says the key is not open' "got: $out" ;; esac
case "$out" in *"open: wanted"*) ok 'the refusal lists the keys that are open' ;;
  *) fail 'the refusal lists the keys that are open' "got: $out" ;; esac

out=$(send nosuchtask 'hello'); rc=$?
is "$rc" '1' 'sending to an unknown task is refused'

# The status log must be untouched by a refused send.
is "$(grep -c '' "$SHEEPR_HOME/tasks/t1/status")" '1' \
  'a refused send appends nothing to the status log'

# --- a flag with no value is refused, not spun on ---------------------------
#
# `--resolve` as the last argument used to leave $# at 1 forever: `shift 2`
# shifts nothing, and the while loop burned a core until the pane was killed.

out=$(run_bounded 5 send t1 'an answer' --resolve); rc=$?
is "$rc" '1' '--resolve with no value is refused rather than looping forever'
case "$out" in *'--resolve needs a value'*) ok 'the refusal names the flag' ;;
  *) fail 'the refusal names the flag' "got: $out" ;; esac

# --- the resolved line carries the answer -----------------------------------
#
# sheepr-send.sh needs a live worker to deliver the prompt, so the append
# itself is exercised through the same helper the script uses.

mktask t2
printf 'question|1|style|Good day or Dear?\n' >"$SHEEPR_HOME/tasks/t2/status"
sheepr_status_append t2 resolved style 'Use "Dear <name>".'

line=$(tail -1 "$SHEEPR_HOME/tasks/t2/status")
is "$(printf '%s' "$line" | cut -d'|' -f1)" 'resolved' 'the appended line is a resolved line'
is "$(printf '%s' "$line" | cut -d'|' -f3)" 'style' 'it carries the key it closes'
is "$(printf '%s' "$line" | cut -d'|' -f4)" 'Use "Dear <name>".' \
  'it carries the answer text, so the log is a complete record'

is "$(sheepr_status_fold t2)" 'working||' 'the question is closed by the resolved line'
is "$(sheepr_status_open_keys t2)" '' 'no keys remain open'

# --- an empty answer would be the original bug ------------------------------

mktask t3
printf 'question|1|style|Good day or Dear?\n' >"$SHEEPR_HOME/tasks/t3/status"
sheepr_status_append t3 resolved style ''
is "$(tail -1 "$SHEEPR_HOME/tasks/t3/status" | cut -d'|' -f4)" '' \
  'an empty resolved text is still possible, and is what the worker rejected'
is "$(sheepr_status_fold t3)" 'working||' \
  'the fold still closes it: the fold cannot tell a good answer from an empty one'

# --- answering a dialog clears the wake suppression -------------------------
#
# The regression that matters: the worker's next dialog carries the same wake
# signature as the one just answered. While .woke still holds that signature
# the watcher absorbs the wake, and the supervisor is never told the worker is
# parked again.
#
# herdr is stubbed on PATH, so no dialog and no live fleet are needed.

if ! command -v jq >/dev/null 2>&1; then
  skip 'jq is not installed, so sheepr-send.sh refuses before it sends keys'
else
  STUB=$(mktemp -d "${TMPDIR:-/tmp}/sheepr-stub-XXXXXX")
  printf '#!/bin/sh\nexit 0\n' >"$STUB/herdr"
  chmod +x "$STUB/herdr"

  mktask t4
  printf 'blocked|1||at a dialog\n' >"$SHEEPR_HOME/tasks/t4/status"
  printf '%s' 'agent:blocked' >"$SHEEPR_HOME/tasks/t4/.woke"

  out=$(PATH="$STUB:$PATH" HERDR_ENV=1 \
    "$SHEEPR_ROOT/bin/sheepr-send.sh" t4 --keys down enter 2>&1); rc=$?
  is "$rc" '0' 'answering a dialog succeeds'
  case "$out" in *'sent keys to t4: down enter'*) ok 'it reports the keys it sent' ;;
    *) fail 'it reports the keys it sent' "got: $out" ;; esac

  if [ -f "$SHEEPR_HOME/tasks/t4/.woke" ]; then
    fail 'answering a dialog clears the wake suppression' \
      'the .woke from the answered dialog is still there'
  else
    ok 'answering a dialog clears the wake suppression'
  fi

  rm -rf "$STUB"
fi

finish
