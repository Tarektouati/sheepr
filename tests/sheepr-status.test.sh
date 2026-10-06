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

# --- but a terminal state is not sticky -------------------------------------
#
# The regression that matters: a worker that reports failed and then asks a
# question is asking the supervisor for a way forward. A fold that kept
# printing `failed` swallowed the question entirely.

write_status t-failed-then-q <<'EOF'
working|100||started
failed|110||tests need DB creds
question|120|schema|keep or drop the column?
EOF
is "$(fold t-failed-then-q)" 'question|schema|keep or drop the column?' \
  'a question after a failed run reaches the supervisor'

write_status t-done-then-blocked <<'EOF'
done|100||https://example.com/pr/1
blocked|110||the branch will not push
EOF
is "$(fold t-done-then-blocked)" 'blocked|default|the branch will not push' \
  'a blocker after done reaches the supervisor'

write_status t-done-then-work <<'EOF'
done|100||https://example.com/pr/1
working|110||review asked for one more thing
EOF
is "$(fold t-done-then-work)" 'working||' \
  'progress after done means the worker is working again'

write_status t-done-again <<'EOF'
failed|100||tests need DB creds
question|110|schema|keep or drop the column?
resolved|120|schema|drop it
working|130||dropping it
done|140||https://example.com/pr/2
EOF
is "$(fold t-done-again)" 'done||https://example.com/pr/2' \
  'a terminal state still wins when it is the last thing the worker said'

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

# --- last: what the report describes ---------------------------------------

write_status t-last <<'EOF'
working|100||first step
working|110||second | step
question|120|k|which one?
not a status line
EOF
is "$(sheepr_status_last t-last)" '120|question|second | step' \
  'last gives the newest line epoch and verb, and the newest progress text'

write_status t-last-none <<'EOF'
done|100||shipped
EOF
is "$(sheepr_status_last t-last-none)" '100|done|' 'last has empty progress when there was no working line'
is "$(sheepr_status_last t-no-such-task)" '' 'last prints nothing for a task with no log'

# --- append round trip ------------------------------------------------------

sheepr_status_append t-append working '' 'hello there'
sheepr_status_append t-append question 'pick' 'a|b|c which one?'
is "$(fold t-append | cut -d'|' -f1-2)" 'question|pick' 'append then fold round trips'
is "$(grep -c '' "$SHEEPR_HOME/tasks/t-append/status")" '2' 'append wrote exactly two lines'
is "$(awk -F'|' 'NR==2 {print NF}' "$SHEEPR_HOME/tasks/t-append/status")" '4' \
  'append strips pipes from the text so the line stays four fields'

finish
