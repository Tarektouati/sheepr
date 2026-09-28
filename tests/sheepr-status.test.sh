#!/usr/bin/env bash
# tests/sheepr-status.test.sh - the fold.
#
# The property that matters most: a question written early stays the current
# state until it is resolved, however much progress is appended after it.

. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
. "$SHEEPR_ROOT/bin/sheepr-status.sh"

begin

fold() { sheepr_status_fold "$1"; }

# --- empty and trivial ------------------------------------------------------

is "$(fold nosuch)" 'empty||' 'a task with no status file folds to empty'

write_status t-empty </dev/null
is "$(fold t-empty)" 'empty||' 'an empty status file folds to empty'

write_status t-work <<'EOF'
working|100||started
working|110||still going
EOF
is "$(fold t-work)" 'working||' 'only working lines fold to working'

# --- the buried question ----------------------------------------------------

write_status t-buried <<'EOF'
working|100||started
question|110|db-choice|sqlite or postgres?
working|120||meanwhile, writing the tests
working|130||tests pass
working|140||tidying up
EOF
is "$(fold t-buried)" 'question|db-choice|sqlite or postgres?' \
  'a question stays current under later working lines'

# --- resolution -------------------------------------------------------------

write_status t-resolved <<'EOF'
working|100||started
question|110|db-choice|sqlite or postgres?
resolved|120|db-choice|
working|130||using sqlite
EOF
is "$(fold t-resolved)" 'working||' 'a resolved question returns to working'

write_status t-wrongkey <<'EOF'
question|110|db-choice|sqlite or postgres?
resolved|120|other-thing|
EOF
is "$(fold t-wrongkey)" 'question|db-choice|sqlite or postgres?' \
  'a resolved line with a different key does not close the question'

# --- two concurrent keys ----------------------------------------------------

write_status t-two <<'EOF'
question|100|first|which database?
question|110|second|which port?
EOF
is "$(fold t-two)" 'question|first|which database?' \
  'the oldest open question wins when two are open'

write_status t-two-b <<'EOF'
question|100|first|which database?
question|110|second|which port?
resolved|120|first|
EOF
is "$(fold t-two-b)" 'question|second|which port?' \
  'closing the oldest surfaces the next one'

is "$(sheepr_status_open_keys t-two | tr '\n' ' ')" 'first second ' \
  'open lists every unresolved key in order'

# --- blocked ----------------------------------------------------------------

write_status t-blocked <<'EOF'
working|100||started
blocked|110||gh auth is expired
EOF
is "$(fold t-blocked)" 'blocked|default|gh auth is expired' \
  'a blocked line with no key uses the default key'

write_status t-blocked-res <<'EOF'
blocked|110||gh auth is expired
resolved|120||
EOF
is "$(fold t-blocked-res)" 'working||' 'the default key resolves too'

# --- terminal states win ----------------------------------------------------

write_status t-done <<'EOF'
working|100||started
question|110|db-choice|sqlite or postgres?
done|120||https://github.com/you/repo/pull/42
EOF
is "$(fold t-done)" 'done||https://github.com/you/repo/pull/42' \
  'done wins over an unresolved question'

write_status t-failed <<'EOF'
question|110|x|something
failed|120||cannot reproduce
EOF
is "$(fold t-failed)" 'failed||cannot reproduce' 'failed wins over an open question'

# --- robustness -------------------------------------------------------------

write_status t-prose <<'EOF'
working|100||started
I am now going to look at the tests.
Some more prose with no verb at all.
question|110|k|real question
EOF
is "$(fold t-prose)" 'question|k|real question' \
  'unrecognised prose lines are ignored, not fatal'

write_status t-pipes <<'EOF'
done|100||see https://example.com/a|b|c
EOF
is "$(fold t-pipes)" 'done||see https://example.com/a|b|c' \
  'pipes inside the text are preserved'

write_status t-reopen <<'EOF'
question|100|k|first ask
resolved|110|k|
working|120||carried on
question|130|k|asked again
EOF
is "$(fold t-reopen)" 'question|k|asked again' 'a reopened key surfaces again'

# --- append round trip ------------------------------------------------------

sheepr_status_append t-append working '' 'hello there'
sheepr_status_append t-append question 'pick' 'a|b|c which one?'
is "$(fold t-append | cut -d'|' -f1-2)" 'question|pick' 'append then fold round trips'
is "$(grep -c '' "$SHEEPR_HOME/tasks/t-append/status")" '2' 'append wrote exactly two lines'
is "$(awk -F'|' 'NR==2 {print NF}' "$SHEEPR_HOME/tasks/t-append/status")" '4' \
  'append strips pipes from the text so the line stays four fields'

finish
