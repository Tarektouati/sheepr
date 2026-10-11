#!/usr/bin/env bash
# tests/sheepr-usage.test.sh - reading what a worker spent from its harness's
# own session log.
#
# The cases that matter are the ones that tempt an estimate: a log with no
# counts, a harness with no readable log, a repeated message. Each must give
# either the real number or `unknown`, never something in between.

. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
. "$SHEEPR_ROOT/bin/sheepr-lib.sh"

begin

FIX="$SHEEPR_ROOT/tests/fixtures/usage"
SHEEPR_CLAUDE_HOME="$FIX/claude"
CODEX_HOME="$FIX/codex"
export SHEEPR_CLAUDE_HOME CODEX_HOME

mktask() {  # <id> <kind> [worktree]
  mkdir -p "$SHEEPR_HOME/tasks/$1"
  {
    printf 'kind=%s\n' "$2"
    [ -z "${3:-}" ] || printf 'worktree=%s\n' "$3"
  } >"$SHEEPR_HOME/tasks/$1/meta"
}

usage() { "$SHEEPR_ROOT/bin/sheepr-usage.sh" "$@" 2>&1; }

# --- claude -----------------------------------------------------------------

# Fixture: msg_A logged twice in the session and copied once more into a
# subagent log, msg_B, msg_C in the subagent log, one entry with no id, and a
# half-written last line.
mktask alpha claude /wt/alpha
is "$(usage task alpha)" '413 16 17 claude' \
  'claude: sums every message once, subagents included'
j=$(usage task alpha --json)
is "$(printf '%s' "$j" | jq -r '.cache_read')" '350' 'claude: cache reads are reported apart from input'
is "$(printf '%s' "$j" | jq -r '.cache_creation')" '30' 'claude: cache creation is reported apart from input'
is "$(printf '%s' "$j" | jq -r '.input')" '16' 'claude: input excludes both cache counts'
is "$(sheepr_meta_get alpha usage_source)" 'claude' 'the first read records usage_source in meta'

printf 'usage_source=elsewhere\n' >>"$SHEEPR_HOME/tasks/alpha/meta"
usage task alpha >/dev/null
is "$(sheepr_meta_get alpha usage_source)" 'elsewhere' 'usage_source is written only the first time'

mktask quiet claude /wt/alpha
usage task quiet --read-only >/dev/null
if sheepr_meta_get quiet usage_source >/dev/null; then
  fail '--read-only writes nothing to meta'
else
  ok '--read-only writes nothing to meta'
fi

mktask gamma claude /wt/gamma
is "$(usage task gamma)" 'unknown claude-no-usage' 'claude: a session with no counts is unknown, not zero'
if sheepr_meta_get gamma usage_source >/dev/null; then
  fail 'an unknown usage records no usage_source'
else
  ok 'an unknown usage records no usage_source'
fi

mktask nolog claude /wt/never-ran
is "$(usage task nolog)" 'unknown claude-no-session' 'claude: no session log is unknown'

# --- codex ------------------------------------------------------------------

# Fixture: one live rollout for /wt/beta with two cumulative events and a
# trailing event with no counts, one archived rollout for /wt/beta, and a
# large rollout for another directory that must not be counted.
mktask beta codex /wt/beta
is "$(usage task beta)" '385 230 35 codex' \
  'codex: last cumulative count per session, summed over sessions in the worktree'
j=$(usage task beta --json)
is "$(printf '%s' "$j" | jq -r '.cache_read')" '120' 'codex: cached input is reported apart from input'
is "$(printf '%s' "$j" | jq -r '.total')" '385' 'codex: total matches its own total_tokens'

mktask gammacx codex /wt/gamma
is "$(usage task gammacx)" 'unknown codex-no-usage' 'codex: a session with no counts is unknown, not zero'

mktask nocx codex /wt/never-ran
is "$(usage task nocx)" 'unknown codex-no-session' 'codex: no session for the worktree is unknown'

# --- cursor and the rest ----------------------------------------------------

mktask delta cursor /wt/alpha
is "$(usage task delta)" 'unknown cursor-unreadable' 'cursor: unreadable, never estimated'
is "$(usage task delta --json)" '{"unknown":"cursor-unreadable"}' '--json carries the reason'

mktask nowt claude
is "$(usage task nowt)" 'unknown no-worktree' 'a task with no worktree in meta is unknown'

mktask oddkind gemini /wt/alpha
is "$(usage task oddkind)" 'unknown kind-unknown' 'a kind with no reader is unknown'

out=$(usage task ghost); rc=$?
is "$rc" '1' 'an unknown task is refused'
case "$out" in *'no such task'*) ok 'and the refusal says why' ;;
  *) fail 'and the refusal says why' "got: $out" ;; esac

out=$(usage task 'Bad Id'); rc=$?
is "$rc" '1' 'an invalid task id is refused'

out=$(usage sideways); rc=$?
is "$rc" '1' 'an unknown mode is refused'

# --- self -------------------------------------------------------------------

# The supervisor's sessions are the ones run in sheepr's own directory.
CL=$(mktemp -d "${TMPDIR:-/tmp}/sheepr-usage-XXXXXX")
CX=$(mktemp -d "${TMPDIR:-/tmp}/sheepr-usage-XXXXXX")
trap 'rm -rf "$CL" "$CX"; cleanup_home' EXIT

is "$(SHEEPR_CLAUDE_HOME=$CL CODEX_HOME=$CX usage self)" 'unknown no-session' \
  'self: no supervisor session is unknown'

home_real=$(cd "$SHEEPR_HOME" && pwd -P)
slug=$(printf '%s' "$home_real" | sed 's/[^A-Za-z0-9]/-/g')
mkdir -p "$CL/projects/$slug" "$CX/sessions/2026/10/11"
cp "$FIX/claude/projects/-wt-alpha/s1.jsonl" "$CL/projects/$slug/"
is "$(SHEEPR_CLAUDE_HOME=$CL CODEX_HOME=$CX usage self)" '347 14 13 claude' \
  'self: reads the claude session in sheepr directory'

{
  printf '{"type":"session_meta","payload":{"id":"s","cwd":"%s"}}\n' "$home_real"
  printf '{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"cached_input_tokens":4,"output_tokens":2,"total_tokens":12}}}}\n'
} >"$CX/sessions/2026/10/11/rollout-self.jsonl"
is "$(SHEEPR_CLAUDE_HOME=$CL CODEX_HOME=$CX usage self)" '359 20 15 claude+codex' \
  'self: every harness used in sheepr directory is summed'

finish
