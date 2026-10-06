#!/usr/bin/env bash
# bin/sheepr-report.sh - what every worker is doing, as one digest.
#
# Usage:
#   sheepr-report.sh            text digest, one row per task
#   sheepr-report.sh --json     machine readable
#
# Owns: the fleet report the supervisor turns into the captain's periodic
# update, and the answer to "what is everyone doing?".
#
# Refuses: to change anything. It reads task records and status logs, and asks
# herdr for agent states when it can. Outside Herdr the agent column reads `?`
# rather than failing, so the report works anywhere.
#
# This is description, never decision. What needs attention is the watcher's
# job, through the fold; this file only says where each task stands.

set -uo pipefail

# shellcheck source=bin/sheepr-herdr.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sheepr-herdr.sh"
# shellcheck source=bin/sheepr-status.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sheepr-status.sh"

SHEEPR_PROPOSALS="$SHEEPR_TASKS/.sheepr-proposals"

JSON=0
case "${1:-}" in
  --json) JSON=1 ;;
  '') ;;
  -h|--help) sed -n '3,6p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) die "usage: sheepr-report.sh [--json]" ;;
esac

sheepr_require_tools jq

# Ask herdr only when it can answer. A report that dies outside Herdr is a
# report nobody gets.
HAVE_HERDR=0
if [ "${HERDR_ENV:-}" = 1 ] && command -v herdr >/dev/null 2>&1; then
  HAVE_HERDR=1
fi

now=$(sheepr_now)

rows=$(
  while read -r id; do
    [ -n "$id" ] || continue
    fold=$(sheepr_status_fold "$id")
    state=${fold%%|*}
    key=$(printf '%s' "$fold" | cut -d'|' -f2)
    text=$(printf '%s' "$fold" | cut -d'|' -f3-)

    last=$(sheepr_status_last "$id")
    last_epoch=${last%%|*}
    progress=$(printf '%s' "$last" | cut -d'|' -f3-)

    # A working task is described by its latest progress; any other state by
    # the line the fold chose.
    case "$state" in
      (working|empty) detail=$progress ;;
      (*) detail=$text ;;
    esac

    if [ "$HAVE_HERDR" = 1 ]; then
      name=$(sheepr_meta_get "$id" name) || name="sheepr-$id"
      agent=$(sheepr_agent_state "$name")
    else
      agent='?'
    fi

    jq -nc --arg id "$id" --arg state "$state" --arg key "$key" \
      --arg detail "$detail" --arg agent "$agent" \
      --arg kind "$(sheepr_meta_get "$id" kind || printf '?')" \
      --arg delivery "$(sheepr_meta_get "$id" delivery || printf '?')" \
      --arg last "${last_epoch:-}" --argjson now "$now" \
      '{id: $id, state: $state, key: (if $key == "" then null else $key end),
        detail: $detail, agent: $agent, kind: $kind, delivery: $delivery,
        last_epoch: (if $last == "" then null else ($last | tonumber? // null) end)}
       | .age_s = (if .last_epoch == null then null else ($now - .last_epoch) end)'
  done < <(sheepr_task_ids) | jq -sc '.'
)

proposals=0
if [ -f "$SHEEPR_PROPOSALS" ]; then
  proposals=$(grep -c . "$SHEEPR_PROPOSALS" 2>/dev/null || printf '0')
fi

if [ "$JSON" = 1 ]; then
  jq -n --argjson t "$rows" --argjson p "$proposals" '{
    tasks: $t,
    open_questions: ([$t[] | select(.state == "question")] | length),
    sheepr_proposals: $p
  }'
  exit 0
fi

if [ "$(printf '%s' "$rows" | jq 'length')" = 0 ]; then
  printf 'no tasks.\n'
else
  printf '%s' "$rows" | jq -r '
    def age: if . == null then "-"
             elif . < 60 then "\(.)s"
             elif . < 3600 then "\(. / 60 | floor)m"
             elif . < 86400 then "\(. / 3600 | floor)h"
             else "\(. / 86400 | floor)d" end;
    (["TASK","STATE","AGENT","KIND","DELIVERY","LAST","DETAIL"] | @tsv),
    (.[] | [ .id, .state, .agent, .kind, .delivery, (.age_s | age),
             ((if .key then "\(.key): " else "" end) + .detail) ] | @tsv)
  ' | column -t -s "$(printf '\t')"
fi

questions=$(printf '%s' "$rows" | jq '[.[] | select(.state == "question")] | length')
[ "$questions" = 0 ] || printf '%s open question(s) for the captain.\n' "$questions"
[ "$proposals" = 0 ] || printf '%s sheepr proposal(s) pending in %s.\n' "$proposals" "$SHEEPR_PROPOSALS"
exit 0
