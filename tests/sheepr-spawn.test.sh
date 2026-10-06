#!/usr/bin/env bash
# tests/sheepr-spawn.test.sh - the refusals in the argument parser.
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

for flag in --kind --delivery --brief; do
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

finish
