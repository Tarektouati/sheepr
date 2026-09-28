#!/usr/bin/env bash
# bin/sheepr-herdr.sh - the Herdr adapter. THE ONLY file that runs `herdr`.
#
# Owns: every call into the herdr CLI, the per-kind launch table, and the
# mapping from herdr's JSON to sheepr's vocabulary.
#
# Refuses:
#   - to construct or predict an id. Every id is read from a JSON response.
#   - to report `idle` when a call fails. A failure is always `missing`,
#     because failing to `idle` is how a lost worker goes unnoticed.
#   - to steal focus. Every mutating call passes --no-focus.
#
# Verified against herdr 0.9.1, protocol 22, macOS.
#
# Response shapes this file depends on (confirmed empirically):
#   worktree create -> .result.workspace.workspace_id
#                      .result.root_pane.pane_id
#                      .result.worktree.path
#   agent get       -> .result.agent.agent_status
#   agent start     -> .result.agent.agent_status | .error.code
#   workspace list  -> .result.workspaces[] {workspace_id,label,agent_status}
#   pane list       -> .result.panes[] {pane_id,agent_status}
#   agent read      -> PLAIN TEXT on stdout, not JSON.

# shellcheck source=bin/sheepr-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sheepr-lib.sh"

SHEEPR_AGENT_KINDS="cursor claude codex"

# --- per-kind launch table --------------------------------------------------
#
# Filled empirically by starting each kind in a scratch worktree workspace and
# recording what actually reaches an interactive prompt. Do not guess here.
#
# cursor: without --trust it stops at a workspace trust dialog that herdr
#         reports as `idle`, not `blocked`. That combination is invisible to
#         any state check, so the flag is mandatory, not a convenience.
# claude: --dangerously-skip-permissions reaches "bypass permissions on".
# codex:  workspace-write plus never-ask is enough, but an out-of-date codex
#         stops at an update prompt. herdr does report that one as `blocked`.

sheepr_kind_args() {  # <kind> -> native args, space separated
  case "$1" in
    cursor) printf '%s' '--force --trust' ;;
    claude) printf '%s' '--dangerously-skip-permissions' ;;
    codex)  printf '%s' '-s workspace-write -a never' ;;
    *) return 1 ;;
  esac
}

sheepr_kind_timeout() {  # <kind> -> readiness timeout in ms
  case "$1" in
    cursor) printf '60000' ;;
    claude) printf '90000' ;;
    codex)  printf '90000' ;;
    *) return 1 ;;
  esac
}

sheepr_kind_valid() {  # <kind>
  case " $SHEEPR_AGENT_KINDS " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# Clear a known first-run dialog, and only that one.
#
# Every worktree is a directory the agent has never seen, so some kinds ask to
# trust it before they will accept any input. claude asks even under
# --dangerously-skip-permissions. The worktree was created by sheepr from a
# repository the captain named when they spawned the task, so answering this
# particular question is carrying out their instruction, not widening it.
#
# The match is deliberately narrow: an unrecognised dialog is left alone and
# reported, because a prompt we cannot identify is not one we may answer.
#
# Returns 0 when a dialog was recognised and answered, 1 otherwise.
sheepr_kind_clear_startup_dialog() {  # <kind> <name>
  local kind=$1 name=$2 screen
  screen=$(sheepr_agent_read "$name" 40 detection) || return 1

  case "$kind" in
    claude)
      case "$screen" in
        *"Is this a project you created or one you trust"*)
          # "No, exit" is preselected; "Yes, I trust this folder" is next.
          sheepr_agent_send_keys "$name" down || return 1
          sheepr_agent_send_keys "$name" enter || return 1
          return 0
          ;;
      esac
      ;;
  esac
  return 1
}

# --- preconditions ----------------------------------------------------------

sheepr_herdr_require() {
  sheepr_require_tools herdr jq
  [ "${HERDR_ENV:-}" = 1 ] || die "not running inside a Herdr pane (HERDR_ENV is not 1)"
}

# --- worktree workspaces ----------------------------------------------------

# Create a linked git worktree and the herdr workspace that holds it.
# Prints: <workspace_id> TAB <pane_id> TAB <worktree_path>
sheepr_worktree_create() {  # <repo-path> <branch> <label>
  local repo=$1 branch=$2 label=$3 json
  json=$(herdr worktree create --cwd "$repo" --branch "$branch" --label "$label" --no-focus 2>&1) \
    || { warn "herdr worktree create failed: $(printf '%s' "$json" | head -3)"; return 1; }

  local ws pane path
  ws=$(printf '%s' "$json" | jq -r '.result.workspace.workspace_id // empty')
  pane=$(printf '%s' "$json" | jq -r '.result.root_pane.pane_id // empty')
  path=$(printf '%s' "$json" | jq -r '.result.worktree.path // empty')

  [ -n "$ws" ] && [ -n "$pane" ] && [ -n "$path" ] \
    || { warn "herdr worktree create returned an incomplete response"; return 1; }

  printf '%s\t%s\t%s' "$ws" "$pane" "$path"
}

sheepr_worktree_remove() {  # <workspace-id>
  herdr worktree remove --workspace "$1" --force >/dev/null 2>&1
}

# The root pane of a workspace. Used on recovery, when a stored pane id may be
# stale after a herdr server restart.
sheepr_pane_of() {  # <workspace-id>
  local pane
  pane=$(herdr pane list --workspace "$1" 2>/dev/null \
    | jq -r '.result.panes[0].pane_id // empty') || return 1
  [ -n "$pane" ] || return 1
  printf '%s' "$pane"
}

# Find a workspace by its label. Pane and workspace ids do not survive a herdr
# server restart; the label does, so this is the recovery path.
sheepr_workspace_by_label() {  # <label>
  local ws
  ws=$(herdr workspace list 2>/dev/null \
    | jq -r --arg l "$1" '.result.workspaces[] | select(.label == $l) | .workspace_id' \
    | head -1) || return 1
  [ -n "$ws" ] || return 1
  printf '%s' "$ws"
}

# --- agents -----------------------------------------------------------------

# Start an agent of <kind> in an existing pane, under a stable name.
# Returns 0 when herdr confirms the agent is interactive, 1 otherwise.
sheepr_agent_start() {  # <name> <kind> <pane-id>
  local name=$1 kind=$2 pane=$3 args timeout json code

  sheepr_kind_valid "$kind" || { warn "unknown agent kind: $kind"; return 1; }
  args=$(sheepr_kind_args "$kind")
  timeout=$(sheepr_kind_timeout "$kind")

  # Word splitting on $args is intended: the table holds separate flags.
  # shellcheck disable=SC2086
  json=$(herdr agent start "$name" --kind "$kind" --pane "$pane" \
           --timeout "$timeout" -- $args 2>&1) || true

  code=$(printf '%s' "$json" | jq -r '.error.code // empty' 2>/dev/null)

  # agent_not_ready is not a failure: herdr found the agent but it is parked at
  # a first-run dialog. The name is usable for read and send-keys, so we can
  # look at what it is asking.
  if [ -n "$code" ] && [ "$code" != agent_not_ready ]; then
    warn "herdr agent start failed for $name ($kind): $code"
    return 1
  fi

  local state i
  for i in $(seq 1 30); do
    state=$(sheepr_agent_state "$name")
    case "$state" in
      idle|working|done) return 0 ;;
      missing) warn "agent $name vanished during startup"; return 1 ;;
      blocked)
        if sheepr_kind_clear_startup_dialog "$kind" "$name"; then
          sleep 2
          continue
        fi
        warn "agent $name ($kind) is parked at an unrecognised startup dialog"
        return 1
        ;;
    esac
    sleep 1
  done

  warn "agent $name ($kind) never became interactive"
  return 1
}

# The agent's current state, in sheepr's vocabulary.
#
# Returns one of: idle working blocked done unknown missing
#
# `missing` means herdr could not tell us anything: no such agent, a failed
# call, or an unparseable response. It is never reported as `idle`.
#
# IMPORTANT: a returned `idle` is NOT evidence that the worker has stopped.
# A harness waiting on its own long foreground tool reads idle, and so does an
# agent parked at a dialog herdr does not recognise. Only `working` is positive
# evidence of life. Callers must corroborate every other value.
sheepr_agent_state() {  # <name-or-pane-id>
  local json status
  json=$(herdr agent get "$1" 2>/dev/null) || { printf 'missing'; return 0; }
  status=$(printf '%s' "$json" | jq -r '.result.agent.agent_status // empty' 2>/dev/null) \
    || { printf 'missing'; return 0; }
  case "$status" in
    idle|working|blocked|done) printf '%s' "$status" ;;
    unknown) printf 'unknown' ;;
    *) printf 'missing' ;;
  esac
}

# Submit a prompt. Deliberately does NOT pass --wait.
#
# `herdr agent prompt --wait` is not a completion signal: its own help states
# it does not track turns, and it returns agent_prompt_stalled when the agent
# takes longer than five seconds to visibly start. Completion is decided by the
# status log, never here.
#
# Exit: 0 submitted, 3 the agent is parked at a dialog, 1 anything else.
sheepr_agent_prompt() {  # <name> <text>
  local json code
  json=$(herdr agent prompt "$1" "$2" 2>&1) || true
  code=$(printf '%s' "$json" | jq -r '.error.code // empty' 2>/dev/null)
  case "$code" in
    '') return 0 ;;
    agent_blocked) return 3 ;;
    *) warn "herdr agent prompt failed for $1: $code"; return 1 ;;
  esac
}

# Read rendered pane output. Prints plain text; herdr does not wrap this in
# JSON. Used for diagnosis only, never to decide state.
sheepr_agent_read() {  # <name> [lines] [source]
  herdr agent read "$1" --source "${3:-recent-unwrapped}" --lines "${2:-80}" 2>/dev/null
}

# Send a logical key to an agent, for answering a dialog herdr reported as
# blocked.
sheepr_agent_send_keys() {  # <name> <key...>
  herdr agent send-keys "$@" >/dev/null 2>&1
}

# Submit a prompt and prove it started a turn.
#
# `herdr agent start` returns as soon as the agent looks interactive, but a TUI
# can take another moment before it will accept a submission. When a prompt
# arrives inside that window the text lands in the composer and the Enter is
# swallowed: the agent then sits at `idle` with an unsent prompt on screen,
# which no state check can distinguish from an agent that simply has nothing to
# do. Observed on cursor-agent roughly one spawn in two.
#
# So: submit, wait for observable activity, and if none appears press Enter to
# submit whatever is sitting in the composer. Never retype the prompt, which
# would concatenate it with the pending copy.
#
# Exit: 0 the agent started working, 3 parked at a dialog, 1 could not submit,
#       4 submitted but never observed starting.
sheepr_agent_prompt_verified() {  # <name> <text> [settle-seconds]
  local name=$1 text=$2 budget=${3:-20} rc st i

  sheepr_agent_prompt "$name" "$text"; rc=$?
  [ "$rc" -eq 0 ] || return "$rc"

  for i in $(seq 1 "$budget"); do
    st=$(sheepr_agent_state "$name")
    case "$st" in
      working) return 0 ;;
      blocked) return 3 ;;
      missing) return 1 ;;
    esac
    # Half way through, nudge the composer once.
    if [ "$i" -eq $(( budget / 2 )) ]; then
      sheepr_agent_send_keys "$name" enter
    fi
    sleep 1
  done

  # A very short task can finish inside the budget; treat a written status log
  # or a terminal state as proof the prompt did land.
  st=$(sheepr_agent_state "$name")
  case "$st" in
    working|done) return 0 ;;
    blocked) return 3 ;;
  esac
  return 4
}
