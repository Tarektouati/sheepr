#!/usr/bin/env bash
# bin/sheepr-usage.sh - the usage adapter. THE ONLY file that reads harness
# session logs.
#
# Usage:
#   sheepr-usage.sh task <task-id> [--json] [--read-only]
#   sheepr-usage.sh self [--json]
#
# Prints one line:
#   <total> <input> <output> <source>      usage was read
#   unknown <reason>                       it could not be, and that is the answer
#
# `task` reads the usage of one task's worker, from the log of the harness
# named by its kind, for sessions whose working directory is its worktree.
# `self` reads the supervisor's own: every harness log for sessions run in
# sheepr's own directory ($SHEEPR_HOME), all of them summed.
#
# --json prints the breakdown, including cache tokens:
#   {"total":N,"input":N,"output":N,"cache_read":N,"cache_creation":N,"source":S}
#   {"unknown":"<reason>"}
#
# The fields, the same for every harness:
#   input           fresh input tokens, never served from or written to a cache
#   cache_read      input tokens served from the prompt cache
#   cache_creation  input tokens written to the prompt cache
#   output          output tokens, reasoning included
#   total           input + cache_read + cache_creation + output
#
# Owns: where each harness keeps its session logs, their formats, and the
# usage_source key in meta, written the first time a task's usage is read
# (never with --read-only, which the read-only fleet view passes).
#
# Refuses:
#   - to estimate. A log that is missing, unreadable, or carries no counts is
#     `unknown`, which is a correct answer. Hard rule 5.
#   - to read an unknown task. That exits 1; it is not usage.
#
# Readers, and the environment that moves them (the tests point both at
# fixtures):
#   claude  $SHEEPR_CLAUDE_HOME/projects/<slug>/**/*.jsonl  (default ~/.claude)
#           <slug> is the session's working directory with every character
#           other than a letter or digit replaced by `-`. Sums message.usage
#           over assistant entries. A message is logged once per content
#           block with the same usage, and a resumed session can copy earlier
#           messages into its new file, so each message id counts once.
#   codex   $CODEX_HOME/{sessions,archived_sessions}/**/rollout-*.jsonl
#           (default ~/.codex), only files whose session_meta cwd is the
#           directory. token_count events are cumulative, so each file
#           contributes its last one that carries counts. codex reaches its
#           models through codex-cursor-bridge, which forwards real usage.
#   cursor  unknown cursor-unreadable. Checked against cursor-agent
#           2026.10.01: its chat store (~/.cursor/chats/*/*/store.db) holds
#           messages but no token counts, and it keeps no other usage record.
#           A user-installed afterAgentResponse hook can record counts, but
#           that is not cursor-agent's record and it drops a turn silently
#           when it fails, so it is not read here.
#
# Reasons:
#   cursor-unreadable   the harness keeps no usage we can read
#   <kind>-no-session   no session log for the directory
#   <kind>-no-usage     session logs exist but carry no counts yet
#   no-worktree         the task's meta records no worktree
#   kind-unknown        the task's meta records no kind this file reads
#   no-session          (self) no harness has a session in sheepr's directory

set -uo pipefail

# shellcheck source=bin/sheepr-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sheepr-lib.sh"

SHEEPR_CLAUDE_HOME="${SHEEPR_CLAUDE_HOME:-$HOME/.claude}"
SHEEPR_CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"

# Every reader prints one compact JSON object: the breakdown, or
# {"unknown": reason}.
unknown_json() { jq -nc --arg r "$1" '{unknown: $r}'; }

# The directory as given and its physical form, one per line, deduplicated.
# Harnesses record the physical path (/private/tmp, not /tmp), while meta
# records what spawn was given.
dir_names() {  # <dir>
  local real=$1
  [ -d "$1" ] && real=$(cd "$1" 2>/dev/null && pwd -P)
  printf '%s\n%s\n' "$1" "$real" | awk 'NF && !seen[$0]++'
}

# --- claude -----------------------------------------------------------------

claude_slug() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }

read_claude() {  # <dir>
  local d name files=()
  while read -r name; do
    d="$SHEEPR_CLAUDE_HOME/projects/$(claude_slug "$name")"
    [ -d "$d" ] || continue
    while IFS= read -r -d '' f; do files+=("$f"); done \
      < <(find -H "$d" -type f -name '*.jsonl' -print0 2>/dev/null)
  done < <(dir_names "$1")

  [ ${#files[@]} -gt 0 ] || { unknown_json claude-no-session; return; }

  # A live session may be writing its last line as we read; a line that is
  # not yet whole JSON is skipped, not fatal. awk, not cat, so that line ends
  # where its file does instead of swallowing the next file's first line.
  # Entries without an id cannot be deduplicated, so each counts on its own.
  awk 1 "${files[@]}" | jq -R -c '
      fromjson? // empty
      | select(.type == "assistant" and (.message.usage | type) == "object")
      | {id: (.message.id // null), u: .message.usage}' \
    | jq -s -c '
      if length == 0 then {unknown: "claude-no-usage"} else
        (reduce .[] as $e ({n: 0, by: {}};
           if $e.id == null then .by["\u0000\(.n)"] = $e.u | .n += 1
           else .by[$e.id] = $e.u end)
         | [.by[]]
         | {input:          (map(.input_tokens // 0) | add),
            cache_read:     (map(.cache_read_input_tokens // 0) | add),
            cache_creation: (map(.cache_creation_input_tokens // 0) | add),
            output:         (map(.output_tokens // 0) | add)}
         | .total = .input + .cache_read + .cache_creation + .output
         | .source = "claude")
      end'
}

# --- codex ------------------------------------------------------------------

read_codex() {  # <dir>
  local names files=() matched=() f
  names=$(dir_names "$1" | jq -R . | jq -sc .)

  local root
  for root in "$SHEEPR_CODEX_HOME/sessions" "$SHEEPR_CODEX_HOME/archived_sessions"; do
    [ -d "$root" ] || continue
    while IFS= read -r -d '' f; do files+=("$f"); done \
      < <(find -H "$root" -type f -name 'rollout-*.jsonl' -print0 2>/dev/null)
  done

  # The session's working directory is in its first line. One awk and one jq
  # over every file rather than a jq per file: the sessions directory grows
  # forever. Rollout paths are codex's own and carry no tab.
  if [ ${#files[@]} -gt 0 ]; then
    while IFS= read -r f; do
      [ -n "$f" ] && matched+=("$f")
    done < <(awk 'FNR == 1 { printf "%s\t%s\n", FILENAME, $0; nextfile }' "${files[@]}" \
      | jq -R -r --argjson names "$names" '
          index("\t") as $i
          | .[:$i] as $path
          | (.[$i + 1:] | fromjson? // empty)
          | select(.type == "session_meta" and (.payload.cwd as $c | $names | index($c)))
          | $path')
  fi

  [ ${#matched[@]} -gt 0 ] || { unknown_json codex-no-session; return; }

  for f in "${matched[@]}"; do
    jq -R -c 'fromjson? // empty
      | select(.type == "event_msg" and .payload.type == "token_count"
               and (.payload.info.total_token_usage | type) == "object")
      | .payload.info.total_token_usage' "$f" | tail -1
  done | jq -s -c '
    if length == 0 then {unknown: "codex-no-usage"} else
      {cache_read: (map(.cached_input_tokens // 0) | add),
       input:      (map((.input_tokens // 0) - (.cached_input_tokens // 0)) | add),
       output:     (map(.output_tokens // 0) | add),
       cache_creation: 0}
      | .total = .input + .cache_read + .cache_creation + .output
      | .source = "codex"
    end'
}

# --- reading ----------------------------------------------------------------

read_kind() {  # <kind> <dir>
  case "$1" in
    claude) read_claude "$2" ;;
    codex)  read_codex "$2" ;;
    cursor) unknown_json cursor-unreadable ;;
    *)      unknown_json kind-unknown ;;
  esac
}

usage_task() {  # <task-id> <read-only>
  local id=$1 kind wt out src
  sheepr_validate_id "$id"
  sheepr_task_exists "$id" || die "no such task: $id"

  kind=$(sheepr_meta_get "$id" kind) || kind=''
  wt=$(sheepr_meta_get "$id" worktree) || wt=''
  if [ -z "$wt" ]; then
    unknown_json no-worktree
    return
  fi
  out=$(read_kind "$kind" "$wt")
  printf '%s\n' "$out"

  [ "$2" = 1 ] && return
  src=$(printf '%s' "$out" | jq -r '.source // empty')
  if [ -n "$src" ] && ! sheepr_meta_get "$id" usage_source >/dev/null; then
    sheepr_meta_set "$id" usage_source "$src"
  fi
}

# Every harness's sessions in sheepr's own directory, summed. The supervisor
# may have run under more than one harness, and each one's spend is real.
usage_self() {
  local k parts=()
  for k in claude codex; do
    parts+=("$(read_kind "$k" "$SHEEPR_HOME")")
  done
  printf '%s\n' "${parts[@]}" | jq -s -c '
    [.[] | select(.unknown == null)] as $found
    | if ($found | length) == 0 then {unknown: "no-session"} else
        {total:          ($found | map(.total) | add),
         input:          ($found | map(.input) | add),
         output:         ($found | map(.output) | add),
         cache_read:     ($found | map(.cache_read) | add),
         cache_creation: ($found | map(.cache_creation) | add),
         source:         ($found | map(.source) | join("+"))}
      end'
}

# --- main -------------------------------------------------------------------

sheepr_require_tools jq

MODE=${1:-}
[ $# -gt 0 ] && shift
JSON=0
READ_ONLY=0
ID=''
while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON=1 ;;
    --read-only) READ_ONLY=1 ;;
    -h|--help) sed -n '3,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown argument: $1" ;;
    *) [ -z "$ID" ] || die "unexpected argument: $1"; ID=$1 ;;
  esac
  shift
done

case "$MODE" in
  task) [ -n "$ID" ] || die "usage: sheepr-usage.sh task <task-id> [--json] [--read-only]"
        RESULT=$(usage_task "$ID" "$READ_ONLY") || exit 1 ;;
  self) [ -z "$ID" ] || die "self takes no task id"
        RESULT=$(usage_self) || exit 1 ;;
  -h|--help) sed -n '3,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) die "usage: sheepr-usage.sh task <task-id> | self  [--json]" ;;
esac

[ -n "$RESULT" ] || die "could not read usage"

if [ "$JSON" = 1 ]; then
  printf '%s\n' "$RESULT"
else
  printf '%s\n' "$RESULT" | jq -r '
    if .unknown then "unknown \(.unknown)"
    else "\(.total) \(.input) \(.output) \(.source)" end'
fi
