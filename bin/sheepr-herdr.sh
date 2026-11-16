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
#   pane split      -> .result.pane.pane_id                  (herdr 0.9.5)
#   pane read       -> PLAIN TEXT on stdout; .error.code pane_not_found and
#                      exit 1 once the pane is gone           (herdr 0.9.5)
#   pane close      -> .result.type "ok"; .error.code pane_not_found and
#                      exit 1 when it is already gone         (herdr 0.9.5)
#   agent get       -> .result.agent.agent_session.value is the harness's
#                      session id once the agent has taken a turn: claude's
#                      <id>.jsonl, codex's session_meta payload.id. It is
#                      absent before the first prompt.        (herdr 0.9.5)
#
# The reviewer (bin/sheepr-review.sh) runs in a second pane split beside the
# worker, in the same workspace and worktree. Confirmed on herdr 0.9.5 with
# claude 2.1.325: `pane split --no-focus` leaves focus where it was, the new
# pane starts at a shell in --cwd, `agent start` in it works as in a root
# pane, `--permission-mode plan` reaches "plan mode on", and a reviewer told
# to print a sentinel built from parts ("the word X followed by a hyphen and
# the number N") prints it on a line of its own while the prompt echo never
# holds it whole. Closing the pane removes the agent: `agent get` on its name
# then answers agent_not_found.

# shellcheck source=bin/sheepr-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sheepr-lib.sh"

SHEEPR_AGENT_KINDS="cursor claude codex"

# --- per-kind launch table --------------------------------------------------
#
# Filled empirically by starting each kind in a scratch worktree workspace and
# recording what actually reaches an interactive prompt. Do not guess here.
#
# Workers start with each harness's permission checks ON. Checked live on
# 2026-11-16 (herdr 0.9.5, macOS) by starting each kind with these flags in a
# scratch worktree workspace, the status file in a directory under $HOME,
# outside both the worktree and tmp, as $SHEEPR_HOME/tasks/<id>/ is:
#
# claude: --permission-mode auto --add-dir <task dir>. claude 2.1.325 reaches
#         "auto mode on" (its folder trust dialog, if shown, is answered by
#         sheepr_kind_clear_startup_dialog as before). Told to append a line
#         to the status file, it did, with no prompt ("Allowed by auto mode").
#         There is no auto-mode opt-in dialog. Checked on a fresh config (a
#         scratch CLAUDE_CONFIG_DIR holding only the credentials): after
#         first-run onboarding and the folder trust dialog, claude prints an
#         informational notice ("Auto mode lets Claude handle permission
#         prompts automatically ...") and is at its prompt, with nothing to
#         answer. So no case is added for it.
# cursor: --auto-review --sandbox enabled --trust. Without --trust it stops at
#         a workspace trust dialog that herdr reports as `idle`, not
#         `blocked`. That combination is invisible to any state check, so the
#         flag is mandatory, not a convenience. cursor-agent 2026.11.13: no
#         opt-in dialog at startup, footer "Auto-review". The status append
#         ran with no prompt: the model asked to run outside the sandbox and
#         the auto-review classifier approved it, so it depends on the
#         classifier, not on the sandbox allowing the path.
#         CAUTION: a persisted `"approvalMode": "unrestricted"` in
#         ~/.cursor/cli-config.json wins over --auto-review. With it, the
#         same flags start in "Run Everything" with no warning, and a write
#         outside the workspace succeeded under --sandbox enabled. Confirmed
#         by the same launch against a copy of that config set to
#         "allowlist", whose footer read "Auto-review".
#         So spawn refuses a cursor worker on such a machine
#         (sheepr_cursor_config_check), unless the captain chose bypass.
# codex:  -s workspace-write -a on-request --add-dir <task dir>. codex-cli
#         0.140.0 launched with these flags reaches its prompt; an
#         out-of-date codex first stops at an update prompt, and a
#         repository it has never trusted at a folder trust dialog (both
#         reported `blocked`, and both seen with the old `-a never` too).
#         A full worker turn was checked through codex-cursor-bridge
#         (SHEEPR_CODEX_PROFILE=cursor-bridge, -m composer-2.5): told to
#         append to the status file, it ran the command with no approval
#         prompt. Told to write to a sibling directory outside --add-dir, the
#         sandbox refused it ("operation not permitted") and codex did not
#         ask to escalate. Without the bridge, codex's own models are refused
#         on a ChatGPT account ("The 'gpt-5.5' model is not supported when
#         using Codex with a ChatGPT account.").
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
#
# bypass: SHEEPR_WORKER_PERMISSIONS=bypass restores the old worker flags
#         exactly: claude --dangerously-skip-permissions, cursor --force
#         --trust, codex -s workspace-write -a never --add-dir <task dir>.
#         Workers only; a reviewer never reads it.

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

# Refuse a cursor worker whose saved config would silently undo its checks.
#
# A persisted `"approvalMode": "unrestricted"` in cursor's cli-config.json
# wins over --auto-review (see the launch table), so the worker would start in
# Run Everything with no checks at all, and nothing on screen says so. A
# missing file or a missing key is cursor's default, not unrestricted. A file
# that exists but cannot be read or parsed is refused: guessing it safe is how
# a worker runs unchecked.
#
# Returns 0 when the config is fine; dies otherwise.
sheepr_cursor_config_check() {
  local dir=${CURSOR_CONFIG_DIR:-$HOME/.cursor} file mode
  file="$dir/cli-config.json"
  [ -e "$file" ] || return 0
  command -v jq >/dev/null 2>&1 || die "jq is required to read cursor's config $file"
  [ -r "$file" ] || die "cannot read cursor's config $file, so whether it overrides --auto-review is unknown"
  mode=$(jq -r 'if type == "object" then (.approvalMode // "") else error("not an object") end' "$file" 2>/dev/null) \
    || die "cursor's config $file is not valid JSON, so whether it overrides --auto-review is unknown"
  if [ "$mode" = unrestricted ]; then
    die "cursor's config $file has \"approvalMode\": \"unrestricted\", which silently overrides --auto-review: this worker would start with no permission checks at all. Set approvalMode to \"allowlist\" in that file, or set SHEEPR_WORKER_PERMISSIONS=bypass to accept running without checks knowingly."
  fi
  return 0
}

# SHEEPR_WORKER_PERMISSIONS=bypass restores the old worker launch flags, which
# turn every harness's permission checks off. Workers only: a reviewer never
# reads it. Unset or empty is the safe default; any other value is refused,
# because a typo must not silently pick either side.
#
# Returns 0 when bypass is asked for, 1 for the default.
sheepr_worker_permissions_bypass() {
  case "${SHEEPR_WORKER_PERMISSIONS:-}" in
    '') return 1 ;;
    bypass) return 0 ;;
    *) die "SHEEPR_WORKER_PERMISSIONS must be unset, empty, or 'bypass' (got '$SHEEPR_WORKER_PERMISSIONS')" ;;
  esac
}

# Fill SHEEPR_KIND_ARGS with the native launch args for a WORKER of <kind>:
# the safe flags from the table above, or the old bypass flags when
# SHEEPR_WORKER_PERMISSIONS=bypass. The task directory reaches claude and
# codex as --add-dir, so the worker can append to its status log.
#
# An array rather than a string: the codex task directory is a path the
# captain chose, and a caller that word-splits a flat string would cut one
# containing a space into two arguments, the tail of which codex reads as a
# flag.
sheepr_kind_args() {  # <kind> [task-dir] [model]
  local kind=$1 task_dir=${2:-} model=${3:-} bypass=0
  SHEEPR_KIND_ARGS=()
  if [ -n "$model" ]; then
    sheepr_model_valid "$model" || die "model '$model' must match $SHEEPR_MODEL_RE"
  fi
  sheepr_worker_permissions_bypass && bypass=1
  case "$kind" in
    cursor)
      if [ "$bypass" = 1 ]; then
        SHEEPR_KIND_ARGS=(--force --trust)
      else
        SHEEPR_KIND_ARGS=(--auto-review --sandbox enabled --trust)
      fi
      [ -z "$model" ] || SHEEPR_KIND_ARGS+=(--model "$model")
      ;;
    claude)
      if [ "$bypass" = 1 ]; then
        SHEEPR_KIND_ARGS=(--dangerously-skip-permissions)
      else
        SHEEPR_KIND_ARGS=(--permission-mode auto)
        [ -z "$task_dir" ] || SHEEPR_KIND_ARGS+=(--add-dir "$task_dir")
      fi
      [ -z "$model" ] || SHEEPR_KIND_ARGS+=(--model "$model")
      ;;
    codex)
      if [ "$bypass" = 1 ]; then
        SHEEPR_KIND_ARGS=(-s workspace-write -a never)
      else
        SHEEPR_KIND_ARGS=(-s workspace-write -a on-request)
      fi
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

# Fill SHEEPR_KIND_ARGS with the launch args for a REVIEWER of <kind>.
#
# A reviewer must not change the worktree, and each kind is held to that by
# its own harness, not only by the prompt:
#
# claude: --permission-mode plan, and never --dangerously-skip-permissions,
#         which would override it. Reaches "plan mode on" (claude 2.1.325).
# cursor: --trust --mode plan, and never --force. Plan mode is cursor's
#         read-only mode: checked live (cursor-agent 2026.11.13, herdr 0.9.5),
#         asked to create a file it declined and said plan mode only lets it
#         edit markdown files; no file was written. --trust is still needed
#         for the trust dialog herdr reports as idle (see the worker table).
#         It may still write a markdown plan file, which the prompt forbids.
# codex:  -s read-only -a never. Checked with `codex sandbox -c
#         sandbox_mode="read-only"` (codex-cli 0.140.0): reads succeed, a
#         write in the worktree is refused ("Operation not permitted"). NOT
#         checked: a full codex TUI reviewer through codex-cursor-bridge, as
#         no bridge profile was configured on the machine that verified it.
#         No --add-dir: a reviewer writes no status log, so it needs no
#         directory outside the worktree.
sheepr_reviewer_args() {  # <kind> [model]
  local kind=$1 model=${2:-}
  if [ -n "$model" ]; then
    sheepr_model_valid "$model" || die "model '$model' must match $SHEEPR_MODEL_RE"
  fi
  case "$kind" in
    claude)
      SHEEPR_KIND_ARGS=(--permission-mode plan)
      [ -z "$model" ] || SHEEPR_KIND_ARGS+=(--model "$model")
      ;;
    cursor)
      SHEEPR_KIND_ARGS=(--trust --mode plan)
      [ -z "$model" ] || SHEEPR_KIND_ARGS+=(--model "$model")
      ;;
    codex)
      SHEEPR_KIND_ARGS=(-s read-only -a never)
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

# --- panes ------------------------------------------------------------------

# Split a new pane to the right of <pane-id>, at a shell in <cwd>, without
# taking focus. Prints the new pane's id, read from herdr's response.
sheepr_pane_split() {  # <pane-id> <cwd>
  local json pane
  json=$(herdr pane split "$1" --direction right --cwd "$2" --no-focus 2>&1) \
    || { warn "herdr pane split failed: $(printf '%s' "$json" | head -3)"; return 1; }
  pane=$(printf '%s' "$json" | jq -r '.result.pane.pane_id // empty' 2>/dev/null)
  [ -n "$pane" ] || { warn "herdr pane split returned no pane id"; return 1; }
  printf '%s' "$pane"
}

# Read a pane's rendered output, as plain text. Returns 1 when the pane is
# gone or the call fails, so a caller can never mistake "no pane" for "no
# output".
#
# This is the one place sheepr reads a terminal to decide anything: the
# reviewer writes no status log, so its sentinel line is read here. Workers
# are still judged only by their status log.
sheepr_pane_read() {  # <pane-id> [lines]
  herdr pane read "$1" --source recent-unwrapped --lines "${2:-40}" 2>/dev/null
}

# Close a pane. 0 when herdr closed it or it was already gone, 1 otherwise.
sheepr_pane_close() {  # <pane-id>
  local json code
  json=$(herdr pane close "$1" 2>&1) && return 0
  code=$(printf '%s' "$json" | jq -r '.error.code // empty' 2>/dev/null)
  [ "$code" = pane_not_found ] && return 0
  warn "herdr pane close failed for $1: ${code:-unreadable response}"
  return 1
}

# The harness session id of the agent called <name>, or return 1 when herdr
# has none yet (before the first turn) or the agent is gone.
sheepr_agent_session() {  # <name-or-pane-id>
  local s
  s=$(herdr agent get "$1" 2>/dev/null | jq -r '.result.agent.agent_session.value // empty' 2>/dev/null) || return 1
  [ -n "$s" ] || return 1
  printf '%s' "$s"
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
# <role> is `worker` (the default) or `reviewer`, which launches with
# sheepr_reviewer_args instead.
#
# Returns 0 when herdr confirms the agent is interactive, 1 otherwise.
sheepr_agent_start() {  # <name> <kind> <pane-id> [task-dir] [model] [role]
  local name=$1 kind=$2 pane=$3 task_dir=${4:-} model=${5:-} role=${6:-worker} timeout json code

  sheepr_kind_valid "$kind" || { warn "unknown agent kind: $kind"; return 1; }
  case "$role" in
    worker) sheepr_kind_args "$kind" "$task_dir" "$model" ;;
    reviewer) sheepr_reviewer_args "$kind" "$model" ;;
    *) warn "unknown agent role: $role"; return 1 ;;
  esac
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

# Start a reviewer: sheepr_agent_start with the reviewer's launch args. A
# reviewer needs no task directory, since it writes no status log.
sheepr_reviewer_start() {  # <name> <kind> <pane-id> [model]
  sheepr_agent_start "$1" "$2" "$3" '' "${4:-}" reviewer
}

# Record the reviewer's harness session id in meta, as review_session and in
# review_sessions, the list the worker's own usage leaves out. Waits up to
# <tries> seconds for herdr to know it. The watcher retries every pass.
sheepr_review_record_session() {  # <task-id> <name> [tries]
  local id=$1 name=$2 tries=${3:-1} s all i
  for i in $(seq 1 "$tries"); do
    if s=$(sheepr_agent_session "$name"); then
      sheepr_meta_set "$id" review_session "$s"
      all=$(sheepr_meta_get "$id" review_sessions) || all=''
      case " $all " in *" $s "*) ;; *) sheepr_meta_set "$id" review_sessions "${all:+$all }$s" ;; esac
      return 0
    fi
    [ "$i" -lt "$tries" ] && sleep 1
  done
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
# codex:  esc, then ctrl+u, as for cursor. esc stops the turn ("Conversation
#         interrupted"), working -> done inside half a second (codex-cli
#         0.140.0 via codex-cursor-bridge, composer-2.5, herdr 0.9.3). When
#         esc lands before the prompt is committed to the transcript, codex
#         puts it back in the composer; ctrl+u empties it. On an idle codex,
#         esc and ctrl+u both do nothing.

sheepr_kind_interrupt_keys() {  # <kind>
  case "$1" in
    claude) printf 'esc' ;;
    cursor) printf 'esc ctrl+u' ;;
    codex)  printf 'esc ctrl+u' ;;
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
