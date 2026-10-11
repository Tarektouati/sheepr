#!/usr/bin/env bash
# tests/sheepr-fleet.test.sh - the join between sheepr's tasks and what is
# actually on disk.
#
# The case that matters is the orphan: a linked worktree with no task record.
# Every other sheepr command is blind to one, including teardown, which is
# what protects unlanded work.

. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
. "$SHEEPR_ROOT/bin/sheepr-lib.sh"

begin
use_fake_flock

mktask() {  # <id> <worktree> [delivery] [kind]
  mkdir -p "$SHEEPR_HOME/tasks/$1"
  cat >"$SHEEPR_HOME/tasks/$1/meta" <<EOF
worktree=$2
repo=/repo
branch=sheepr/$1
delivery=${3:-local}
kind=${4:-cursor}
label=sheepr-$1
name=sheepr-$1
EOF
  : >"$SHEEPR_HOME/tasks/$1/status"
}

fleet() { SHEEPR_HOME="$SHEEPR_HOME" "$SHEEPR_ROOT/bin/sheepr-fleet.sh" "$@" 2>&1; }
fleet_json() { fleet --repo /repo --json; }

# --- nothing at all ---------------------------------------------------------

flock_doc
out=$(fleet --repo /repo)
case "$out" in *'no worktrees, and no tasks'*) ok 'an empty fleet says so' ;;
  *) fail 'an empty fleet says so' "got: $out" ;; esac

# --- a task ----------------------------------------------------------------

mktask alpha /wt/alpha
printf 'working|1||going\nquestion|2|pick|a or b?\n' >"$SHEEPR_HOME/tasks/alpha/status"
flock_doc "$(flock_row /wt/alpha sheepr/alpha '.ahead = 2 | .agents = [{name:"sheepr-alpha",kind:"cursor",status:"working",pane_id:"w1:p1"}]')"

j=$(fleet_json)
is "$(printf '%s' "$j" | jq -r '.tasks | length')" '1' 'the task is recognised as a task'
is "$(printf '%s' "$j" | jq -r '.orphans | length')" '0' 'and not as an orphan'
is "$(printf '%s' "$j" | jq -r '.tasks[0].task')" 'alpha' 'the task id is reported'
is "$(printf '%s' "$j" | jq -r '.tasks[0].state')" 'question' 'the folded state is reported'
is "$(printf '%s' "$j" | jq -r '.tasks[0].agent')" 'working' 'the agent status comes from flock'
is "$(printf '%s' "$j" | jq -r '.tasks[0].ahead')" '2' 'the commit count comes from flock'

out=$(fleet --repo /repo)
case "$out" in *alpha*question*) ok 'the table shows the task and its state' ;;
  *) fail 'the table shows the task and its state' "got: $out" ;; esac

# --- an orphan --------------------------------------------------------------

flock_doc \
  "$(flock_row /wt/alpha sheepr/alpha '.ahead = 2')" \
  "$(flock_row /wt/stranger sheepr/stranger '.dirty = 11')"

j=$(fleet_json)
is "$(printf '%s' "$j" | jq -r '.orphans | length')" '1' 'a worktree with no task record is an orphan'
is "$(printf '%s' "$j" | jq -r '.orphans[0].branch')" 'sheepr/stranger' 'the orphan branch is reported'
is "$(printf '%s' "$j" | jq -r '.orphans[0].dirty')" '11' 'the orphan uncommitted count is reported'
is "$(printf '%s' "$j" | jq -r '.orphans[0].task')" 'null' 'an orphan has no task id'

out=$(fleet --repo /repo)
case "$out" in *'(orphan)'*) ok 'the table marks the orphan' ;;
  *) fail 'the table marks the orphan' "got: $out" ;; esac
case "$out" in *'1 orphaned worktree'*) ok 'the summary counts orphans' ;;
  *) fail 'the summary counts orphans' "got: $out" ;; esac
case "$out" in *'hold uncommitted work'*) ok 'the summary warns that an orphan holds uncommitted work' ;;
  *) fail 'the summary warns that an orphan holds uncommitted work' "got: $out" ;; esac

# The primary checkout is not an orphan: it is not a linked worktree.
flock_doc \
  "$(flock_row /repo main '.linked = false')" \
  "$(flock_row /wt/alpha sheepr/alpha '.ahead = 1')"
is "$(fleet_json | jq -r '.orphans | length')" '0' 'the primary checkout is never an orphan'

# --- a stale task -----------------------------------------------------------

mktask ghost /wt/ghost
flock_doc "$(flock_row /wt/alpha sheepr/alpha '.ahead = 1')"

j=$(fleet_json)
is "$(printf '%s' "$j" | jq -r '.stale | length')" '1' 'a task whose worktree is gone is stale'
is "$(printf '%s' "$j" | jq -r '.stale[0].task')" 'ghost' 'the stale task id is reported'

out=$(fleet --repo /repo)
case "$out" in *'ghost (stale)'*) ok 'the table names the stale task and marks it' ;;
  *) fail 'the table names the stale task and marks it' "got: $out" ;; esac
case "$out" in *'1 stale task'*) ok 'the summary counts stale tasks' ;;
  *) fail 'the summary counts stale tasks' "got: $out" ;; esac

rm -rf "$SHEEPR_HOME/tasks/ghost"

# --- usage ------------------------------------------------------------------

# alpha is a cursor task, so its usage is unknown. beta is a claude task
# whose session log is the usage fixture for /wt/alpha: 413 tokens.
mktask beta /wt/alpha-claude local claude
mkdir -p "$SHEEPR_HOME/claude-link/projects"
ln -s "$SHEEPR_ROOT/tests/fixtures/usage/claude/projects/-wt-alpha" \
  "$SHEEPR_HOME/claude-link/projects/-wt-alpha-claude"
SHEEPR_CLAUDE_HOME="$SHEEPR_HOME/claude-link"
export SHEEPR_CLAUDE_HOME
flock_doc \
  "$(flock_row /wt/alpha sheepr/alpha)" \
  "$(flock_row /wt/alpha-claude sheepr/beta)" \
  "$(flock_row /wt/stranger sheepr/stranger)"

j=$(fleet_json)
is "$(printf '%s' "$j" | jq -r '.tasks[] | select(.task == "beta") | .tokens')" '413' \
  'a task row carries its tokens'
is "$(printf '%s' "$j" | jq -r '.tasks[] | select(.task == "alpha") | .tokens')" 'null' \
  'a task whose usage is unknown carries null, not zero'
is "$(printf '%s' "$j" | jq -c '.usage')" \
  '{"fleet_total":413,"measured":1,"unknown":1,"supervisor":null}' \
  'the usage summary totals the measured tasks and counts the unknown'

out=$(fleet --repo /repo)
case "$out" in *TOKENS*) ok 'the table has a tokens column' ;;
  *) fail 'the table has a tokens column' "got: $out" ;; esac
alpha_line=$(printf '%s\n' "$out" | grep '^alpha ')
case "$alpha_line" in *' ? '*) ok 'unknown usage shows as ?' ;;
  *) fail 'unknown usage shows as ?' "got: $alpha_line" ;; esac
beta_line=$(printf '%s\n' "$out" | grep '^beta ')
case "$beta_line" in *' 413 '*) ok 'measured usage shows its tokens' ;;
  *) fail 'measured usage shows its tokens' "got: $beta_line" ;; esac
case "$out" in *'tokens: fleet 413 over 1 task(s), 1 unknown; supervisor ?'*)
  ok 'the footer gives the fleet total and the supervisor spend' ;;
  *) fail 'the footer gives the fleet total and the supervisor spend' "got: $out" ;; esac

# The supervisor's spend is read from sessions in sheepr's own directory.
home_slug=$(cd "$SHEEPR_HOME" && pwd -P | sed 's/[^A-Za-z0-9]/-/g')
mkdir -p "$SHEEPR_HOME/claude-link/projects/$home_slug"
printf '%s\n' '{"type":"assistant","message":{"id":"m1","usage":{"input_tokens":1200,"output_tokens":300,"cache_read_input_tokens":2500000,"cache_creation_input_tokens":0}}}' \
  >"$SHEEPR_HOME/claude-link/projects/$home_slug/s.jsonl"
is "$(fleet_json | jq -r '.usage.supervisor')" '2501500' 'the supervisor spend is reported'
case "$(fleet --repo /repo)" in *'supervisor 2.5M'*) ok 'and shown in the footer, abbreviated' ;;
  *) fail 'and shown in the footer, abbreviated' "got: $(fleet --repo /repo)" ;; esac

if sheepr_meta_get beta usage_source >/dev/null; then
  fail 'the fleet view does not record usage_source'
else
  ok 'the fleet view does not record usage_source'
fi
rm -rf "$SHEEPR_HOME/tasks/beta"

# --- read only --------------------------------------------------------------

flock_doc "$(flock_row /wt/alpha sheepr/alpha '.dirty = 4')"
before=$(find "$SHEEPR_HOME/tasks" -type f | sort | xargs md5 -q 2>/dev/null | md5 -q 2>/dev/null \
         || find "$SHEEPR_HOME/tasks" -type f | sort | xargs md5sum 2>/dev/null | md5sum)
fleet --repo /repo >/dev/null
after=$(find "$SHEEPR_HOME/tasks" -type f | sort | xargs md5 -q 2>/dev/null | md5 -q 2>/dev/null \
        || find "$SHEEPR_HOME/tasks" -type f | sort | xargs md5sum 2>/dev/null | md5sum)
is "$after" "$before" 'the fleet view changes nothing on disk'

# --- flock is required ------------------------------------------------------

out=$(SHEEPR_FLOCK=/nonexistent HOME=/nonexistent fleet --repo /repo); rc=$?
is "$rc" '1' 'the fleet view refuses when flock is not installed'
case "$out" in *'flock skill is required'*) ok 'and explains how to install it' ;;
  *) fail 'and explains how to install it' "got: $out" ;; esac

finish
