#!/usr/bin/env bash
# tests/sheepr-report.test.sh - the fleet report.
#
# The report is description only, so what matters is that each row says what
# the task's own records say, and that it still works outside Herdr.

. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

begin

# HERDR_ENV is cleared so the agent column never reaches a live fleet.
report() { HERDR_ENV='' SHEEPR_HOME="$SHEEPR_HOME" "$SHEEPR_ROOT/bin/sheepr-report.sh" "$@" 2>&1; }

mkmeta() {  # <id> <kind> <delivery>
  mkdir -p "$SHEEPR_HOME/tasks/$1"
  printf 'kind=%s\ndelivery=%s\nname=sheepr-%s\n' "$2" "$3" "$1" >"$SHEEPR_HOME/tasks/$1/meta"
}

is "$(report)" 'no tasks.' 'an empty fleet says so'

now=$(date +%s)
mkmeta busy cursor pr
write_status busy <<EOF
working|$((now - 720))||added the failing test
EOF
mkmeta asker codex local
write_status asker <<EOF
working|$((now - 900))||read the code
question|$((now - 300))|backoff|exponential or fixed?
EOF
mkmeta scout claude report
write_status scout <<EOF
done|$((now - 5))||4 proposals in report.md
EOF

json=$(report --json)
printf '%s' "$json" | jq -e . >/dev/null && ok '--json is valid JSON' || fail '--json is valid JSON' "$json"

row() { printf '%s' "$json" | jq -r --arg id "$1" ".tasks[] | select(.id == \$id) | $2"; }

is "$(row busy '.state')" 'working' 'a working task reads working'
is "$(row busy '.detail')" 'added the failing test' 'a working task shows its latest progress'
is "$(row busy '.agent')" '?' 'the agent is ? outside Herdr'
is "$(row busy '.kind + " " + .delivery')" 'cursor pr' 'kind and delivery come from meta'
age=$(row busy '.age_s')
[ "$age" -ge 720 ] && [ "$age" -lt 780 ] && ok 'the age is measured from the last line' \
  || fail 'the age is measured from the last line' "got: $age"

is "$(row asker '.state')" 'question' 'an open question is the state'
is "$(row asker '.key + ": " + .detail')" 'backoff: exponential or fixed?' 'a question shows its key and text'
is "$(row scout '.state + " " + .detail')" 'done 4 proposals in report.md' 'a done task shows its done text'
is "$(printf '%s' "$json" | jq '.open_questions')" '1' 'open questions are counted'
is "$(printf '%s' "$json" | jq '.sheepr_proposals')" '0' 'no sheepr proposals by default'

printf '1|asker|x|y\n2|busy|x|y\n' >"$SHEEPR_HOME/tasks/.sheepr-proposals"
text=$(report)
case "$text" in *'TASK'*'busy'*'12m'*'added the failing test'*) ok 'the text report has a row per task' ;;
  *) fail 'the text report has a row per task' "got: $text" ;; esac
case "$text" in *'1 open question(s) for the captain.'*) ok 'the text report counts open questions' ;;
  *) fail 'the text report counts open questions' "got: $text" ;; esac
case "$text" in *'2 sheepr proposal(s) pending'*) ok 'the text report counts sheepr proposals' ;;
  *) fail 'the text report counts sheepr proposals' "got: $text" ;; esac

finish
