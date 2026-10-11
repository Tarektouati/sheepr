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
#
#         workspace-write also permits writes only inside the worktree and
#         tmp, and the task's status log is in $SHEEPR_HOME/tasks/<id>/, which
#         is neither. Without --add-dir on that directory the worker's every
#         append is denied and it can never report question, blocked or done.
#         Needs codex-cli 0.140 or newer.
#
#         SHEEPR_CODEX_PROFILE, when set and non-empty, starts codex under
#         `-p <profile>`. Unset, codex picks its own profile as before.
#
# model:  optional. claude and cursor take `--model <m>`, codex takes `-m <m>`.
#         codex runs only through codex-cursor-bridge, so its model is a Cursor
#         model id; bin/sheepr-route.sh checks it against the bridge catalog.
#         With no model, each harness runs its own default.

# Letters, digits, `-` and `_`, and never a leading `-`: a value codex would
# read as a flag rather than as the name of a profile is not a profile.
SHEEPR_CODEX_PROFILE_RE='^[A-Za-z0-9][A-Za-z0-9_-]*$'

# The same rule, plus `.`: model ids such as `composer-2.5` carry a dot. A
# leading `-` is still refused, because the harness would read it as a flag.
SHEEPR_MODEL_RE='^[A-Za-z0-9][A-Za-z0-9._-]*$'

sheepr_model_valid() {  # <model>
  [[ ${1:-} =~ $SHEEPR_MODEL_RE ]]
}

# The binary each kind runs. A route to a kind whose binary is not installed is
# refused: there is no fallback to another harness.
sheepr_kind_bin() {  # <kind>
  case "$1" in
    cursor) printf 'cursor-agent' ;;
    claude) printf 'claude' ;;
    codex)  printf 'codex' ;;
    *) return 1 ;;
  esac
}

# Fill SHEEPR_KIND_ARGS with the native launch args for <kind>.
#
# An array rather than a string: the codex task directory is a path the
# captain chose, and a caller that word-splits a flat string would cut one
# containing a space into two arguments, the tail of which codex reads as a
# flag.
sheepr_kind_args() {  # <kind> [task-dir] [model]
  local kind=$1 task_dir=${2:-} model=${3:-}
  SHEEPR_KIND_ARGS=()
  if [ -n "$model" ]; then
    sheepr_model_valid "$model" || die "model '$model' must match $SHEEPR_MODEL_RE"
  fi
  case "$kind" in
    cursor)
      SHEEPR_KIND_ARGS=(--force --trust)
      [ -z "$model" ] || SHEEPR_KIND_ARGS+=(--model "$model")
      ;;
    claude)
      SHEEPR_KIND_ARGS=(--dangerously-skip-permissions)
      [ -z "$model" ] || SHEEPR_KIND_ARGS+=(--model "$model")
      ;;
    codex)
      SHEEPR_KIND_ARGS=(-s workspace-write -a never)
      if [ -n "$task_dir" ]; then
        SHEEPR_KIND_ARGS+=(--add-dir "$task_dir")
      fi
      if [ -n "${SHEEPR_CODEX_PROFILE:-}" ]; then
        [[ $SHEEPR_CODEX_PROFILE =~ $SHEEPR_CODEX_PROFILE_RE ]] \
          || die "SHEEPR_CODEX_PROFILE must match $SHEEPR_CODEX_PROFILE_RE"
        SHEEPR_KIND_ARGS+=(-p "$SHEEPR_CODEX_PROFILE")
      fi
      [ -z "$model" ] || SHEEPR_KIND_ARGS+=(-m "$model")
      ;;
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
#
# <task-dir> is the task's directory in SHEEPR_HOME. It is optional only so a
# caller with no task can still start an agent; a codex worker without it
# cannot write its status log.
#
# <model> is optional; empty means the harness's own default.
#
# Returns 0 when herdr confirms the agent is interactive, 1 otherwise.
sheepr_agent_start() {  # <name> <kind> <pane-id> [task-dir] [model]
  local name=$1 kind=$2 pane=$3 task_dir=${4:-} model=${5:-} timeout json code

  sheepr_kind_valid "$kind" || { warn "unknown agent kind: $kind"; return 1; }
  sheepr_kind_args "$kind" "$task_dir" "$model"
  timeout=$(sheepr_kind_timeout "$kind")

  json=$(herdr agent start "$name" --kind "$kind" --pane "$pane" \
           --timeout "$timeout" -- "${SHEEPR_KIND_ARGS[@]}" 2>&1) || true

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

# The harness running in <pane-id>, as herdr names it (cursor, claude, codex).
#
# Returns 1 when herdr finds no agent there: the pane is gone, or it holds a
# bare shell. A caller about to type into the pane must treat that as "do not
# type", because text submitted to a shell prompt runs as a command.
sheepr_pane_agent() {  # <pane-id>
  local json agent
  json=$(herdr agent get "$1" 2>/dev/null) || true
  agent=$(printf '%s' "$json" | jq -r '.result.agent.agent // empty' 2>/dev/null) || return 1
  [ -n "$agent" ] || return 1
  printf '%s' "$agent"
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
# JSON. Used for diagnosis only, never to decide state. The default is small
# on purpose: whatever is read lands in the supervisor's context.
sheepr_agent_read() {  # <name> [lines] [source]
  herdr agent read "$1" --source "${3:-recent-unwrapped}" --lines "${2:-20}" 2>/dev/null
}

# Send a logical key to an agent, for answering a dialog herdr reported as
# blocked.
sheepr_agent_send_keys() {  # <name> <key...>
  herdr agent send-keys "$@" >/dev/null 2>&1
}

# --- interrupt table ----------------------------------------------------------
#
# The keys that stop the current turn, per kind. Filled empirically like the
# launch table: start the kind in a scratch workspace, give it a long turn,
# send the key, and watch herdr's state. Checked against herdr 0.9.3.
#
# claude: esc. Stops the turn ("Interrupted"), state working -> done inside a
#         second. The composer is left empty. Only one esc: two in a row on an
#         idle claude open its rewind menu.
# cursor: esc, then ctrl+u. esc stops the turn (working -> done inside a
#         second, cursor-agent 2026.10.01), but cursor puts the cancelled
#         prompt back in the composer, and the next prompt typed there would
#         be appended to it. ctrl+u empties the composer. The prompt was
#         already delivered once, so nothing is lost.
# codex:  esc, codex's own documented interrupt key. NOT yet confirmed here:
#         the probe machine had no codex-cursor-bridge profile, and running
#         codex without it spends OpenAI tokens, which the captain has ruled
#         out. Confirm before relying on it, and record the result here.

sheepr_kind_interrupt_keys() {  # <kind>
  case "$1" in
    claude) printf 'esc' ;;
    cursor) printf 'esc ctrl+u' ;;
    codex)  printf 'esc' ;;
    *) return 1 ;;
  esac
}

# Stop the agent's current turn. The session, its context and the worktree are
# kept: this is a pause, never a discard.
#
# The kind is read from herdr, not from meta: the keys must fit whatever is
# actually running in the pane, and herdr is the one that knows.
#
# Returns 0 when the keys were sent, 1 when there is no agent to interrupt or
# its kind has no entry in the table above. An unknown kind gets no keys: a
# key we have not checked could answer a dialog nobody has read.
sheepr_agent_interrupt() {  # <name>
  local kind keys
  kind=$(sheepr_pane_agent "$1") || return 1
  keys=$(sheepr_kind_interrupt_keys "$kind") || { warn "no interrupt key known for kind '$kind'"; return 1; }
  local k
  for k in $keys; do
    sheepr_agent_send_keys "$1" "$k" || return 1
  done
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
# <status-file> is the task's status log, and it is the only evidence that
# separates a worker which read the prompt and finished quickly from one whose
# Enter was swallowed. Both read `done`: a worker that had already ended its
# turn is `done` before the prompt is even sent.
#
# Exit: 0 the agent started working, or its status log grew while the prompt
#         was in flight, 3 parked at a dialog, 1 could not submit,
#       4 submitted, but nothing observable followed.
sheepr_agent_prompt_verified() {  # <name> <text> <status-file> [settle-seconds]
  local name=$1 text=$2 status=${3:-} budget=${4:-20} rc st i before after

  before=0
  [ -n "$status" ] && [ -f "$status" ] && before=$(wc -c <"$status" | tr -d ' ')

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

  st=$(sheepr_agent_state "$name")
  case "$st" in
    working) return 0 ;;
    blocked) return 3 ;;
  esac

  # Every remaining state, `done` included, is compatible with a prompt still
  # sitting unsent in the composer. A very short task can genuinely finish
  # inside the budget, so ask the status log: a worker that read the prompt
  # wrote something, and one that never got it wrote nothing.
  after=0
  [ -n "$status" ] && [ -f "$status" ] && after=$(wc -c <"$status" | tr -d ' ')
  [ "${after:-0}" -gt "${before:-0}" ] && return 0
  return 4
}
