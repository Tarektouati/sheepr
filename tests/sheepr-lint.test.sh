#!/usr/bin/env bash
# tests/sheepr-lint.test.sh - the AGENTS.md word limit.
#
# AGENTS.md loads on every supervisor turn, so lint fails when it grows past
# its limit. The limit is lowered here to prove the check can fail.

. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

begin

lint() { "$SHEEPR_ROOT/bin/sheepr-lint.sh" 2>&1; }

words=$(wc -w <"$SHEEPR_ROOT/AGENTS.md" | tr -d ' ')

out=$(SHEEPR_AGENTS_MAX_WORDS=$((words - 1)) lint); rc=$?
is "$rc" '1' 'lint fails when AGENTS.md is over its word limit'
case "$out" in *"AGENTS.md is $words words"*) ok 'and says how long it is' ;;
  *) fail 'and says how long it is' "got: $out" ;; esac

out=$(SHEEPR_AGENTS_MAX_WORDS=$words lint)
case "$out" in *"ok   $words words, limit $words"*) ok 'AGENTS.md at its limit passes the word check' ;;
  *) fail 'AGENTS.md at its limit passes the word check' "got: $out" ;; esac

finish
