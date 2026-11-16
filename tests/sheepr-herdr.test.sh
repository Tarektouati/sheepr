#!/usr/bin/env bash
# tests/sheepr-herdr.test.sh - the per-kind launch table.
#
# The regression that matters: a worker's status log lives in
# $SHEEPR_HOME/tasks/<id>/, outside its worktree, so a harness that confines
# writes to the worktree denies every append it makes. It can never report
# question, blocked or done, and the supervisor sees a task that simply stops.
# The task directory has to reach claude and codex as --add-dir.
#
# The other: workers start with permission checks on. Only
# SHEEPR_WORKER_PERMISSIONS=bypass turns them off, and never for a reviewer.
#
# Nothing here starts an agent, so no live Herdr is needed.

. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
. "$SHEEPR_ROOT/bin/sheepr-herdr.sh"

begin

# Render the arg array as one comma-separated string. The separator is a
# character no flag holds, so an argument carrying a space is still visibly a
# single argument.
args() {  # <kind> [task-dir]
  sheepr_kind_args "$@" || return 1
  local IFS=,
  printf '%s' "${SHEEPR_KIND_ARGS[*]}"
}

# --- the safe default ------------------------------------------------------
#
# Every worker starts with its harness's permission checks on. The task
# directory reaches claude and codex as --add-dir: the status log lives
# outside the worktree, and a worker that cannot append to it can never
# report question, blocked or done.

unset SHEEPR_WORKER_PERMISSIONS
is "$(args cursor)" '--auto-review,--sandbox,enabled,--trust' 'cursor runs auto-review in its sandbox'
is "$(args claude)" '--permission-mode,auto' 'claude runs in auto permission mode'
is "$(args claude /tmp/sheepr/tasks/t1)" '--permission-mode,auto,--add-dir,/tmp/sheepr/tasks/t1' \
  'the task directory is added to claude'
args nosuchkind >/dev/null 2>&1
is "$?" '1' 'an unknown kind is refused'

for k in cursor claude codex; do
  case ",$(args "$k" /tmp/t1)," in
    *,--dangerously-skip-permissions,*|*,--force,*|*,--yolo,*|*,never,*)
      fail "a $k worker carries no bypass flag by default" "got: $(args "$k" /tmp/t1)" ;;
    *) ok "a $k worker carries no bypass flag by default" ;;
  esac
done

SHEEPR_WORKER_PERMISSIONS=''
is "$(args claude)" '--permission-mode,auto' 'an empty SHEEPR_WORKER_PERMISSIONS is the safe default'
unset SHEEPR_WORKER_PERMISSIONS

# --- codex: the sandbox must reach the status log ---------------------------

is "$(args codex)" '-s,workspace-write,-a,on-request' \
  'with no task directory codex gets only the sandbox and approval flags'

is "$(args codex /tmp/sheepr/tasks/t1)" \
  '-s,workspace-write,-a,on-request,--add-dir,/tmp/sheepr/tasks/t1' \
  'the task directory is added to the codex sandbox'

# A path with a space must arrive as one argument. A flat string that the
# caller word-splits would break this into two, and codex would take the tail
# of the path as its next flag.
sheepr_kind_args codex '/tmp/my tasks/t1'
is "${#SHEEPR_KIND_ARGS[@]}" '6' 'a task directory with a space stays one argument'
is "${SHEEPR_KIND_ARGS[5]}" '/tmp/my tasks/t1' 'and it arrives unmangled'
sheepr_kind_args claude '/tmp/my tasks/t1'
is "${SHEEPR_KIND_ARGS[3]}" '/tmp/my tasks/t1' 'claude gets the same path as one argument'

# --- the opt-out ------------------------------------------------------------
#
# bypass restores the old worker flags exactly. Anything else is refused: a
# typo must not silently land on either side.

SHEEPR_WORKER_PERMISSIONS=bypass
is "$(args cursor)" '--force,--trust' 'bypass: cursor gets --force --trust'
is "$(args claude /tmp/t1)" '--dangerously-skip-permissions' 'bypass: claude gets its bypass flag and nothing else'
is "$(args codex /tmp/t1)" '-s,workspace-write,-a,never,--add-dir,/tmp/t1' 'bypass: codex gets -a never'
is "$(args claude '' claude-opus-5-5)" '--dangerously-skip-permissions,--model,claude-opus-5-5' \
  'bypass keeps the model'
unset SHEEPR_WORKER_PERMISSIONS

for bad in 'yes' 'Bypass' 'bypass ' 'off' '1'; do
  out=$(SHEEPR_WORKER_PERMISSIONS=$bad; export SHEEPR_WORKER_PERMISSIONS; args claude 2>&1); rc=$?
  is "$rc" '1' "an unknown SHEEPR_WORKER_PERMISSIONS is refused: '$bad'"
  case "$out" in *'SHEEPR_WORKER_PERMISSIONS'*) ok 'the refusal names the variable' ;;
    *) fail 'the refusal names the variable' "got: $out" ;; esac
done

# --- reviewers never bypass -------------------------------------------------
#
# The opt-out is for workers. A reviewer must not change the worktree, so no
# setting may put a bypass flag on its command line.

rargs() {  # <kind>
  sheepr_reviewer_args "$@" || return 1
  local IFS=,
  printf '%s' "${SHEEPR_KIND_ARGS[*]}"
}
for setting in unset bypass; do
  for k in cursor claude codex; do
    if [ "$setting" = bypass ]; then
      got=$(SHEEPR_WORKER_PERMISSIONS=bypass; export SHEEPR_WORKER_PERMISSIONS; rargs "$k")
    else
      got=$(unset SHEEPR_WORKER_PERMISSIONS; rargs "$k")
    fi
    case ",$got," in
      *,--dangerously-skip-permissions,*|*,--force,*|*,--yolo,*|*bypass*|*danger-full-access*|*,--auto-review,*)
        fail "a $k reviewer carries no bypass flag ($setting)" "got: $got" ;;
      *) ok "a $k reviewer carries no bypass flag ($setting)" ;;
    esac
  done
done
is "$(SHEEPR_WORKER_PERMISSIONS=bypass; export SHEEPR_WORKER_PERMISSIONS; rargs claude)" \
  "$(unset SHEEPR_WORKER_PERMISSIONS; rargs claude)" 'bypass does not change a reviewer at all'

# --- codex: the optional profile --------------------------------------------

SHEEPR_CODEX_PROFILE=cursor-bridge
is "$(args codex /tmp/sheepr/tasks/t1)" \
  '-s,workspace-write,-a,on-request,--add-dir,/tmp/sheepr/tasks/t1,-p,cursor-bridge' \
  'a profile is appended as -p <profile>'
is "$(args cursor)" '--auto-review,--sandbox,enabled,--trust' 'the profile does not leak into other kinds'
unset SHEEPR_CODEX_PROFILE

SHEEPR_CODEX_PROFILE=''
is "$(args codex)" '-s,workspace-write,-a,on-request' \
  'an empty profile is the same as no profile'
unset SHEEPR_CODEX_PROFILE

# An unvalidated profile is a shell word landing in an agent command line.
# `--sandbox` is in the allowed character set but codex would read it as a
# flag, so a leading `-` is refused too.
for bad in 'a b' 'a;rm -rf /' '$(id)' '--sandbox' '-p' '../other'; do
  out=$(SHEEPR_CODEX_PROFILE=$bad; export SHEEPR_CODEX_PROFILE; args codex 2>&1); rc=$?
  is "$rc" '1' "an invalid profile is refused: $bad"
  case "$out" in *'SHEEPR_CODEX_PROFILE'*) ok 'the refusal names the variable' ;;
    *) fail 'the refusal names the variable' "got: $out" ;; esac
done

# --- the model -------------------------------------------------------------
#
# Each harness spells the flag its own way. Getting it wrong does not fail the
# launch: the harness quietly runs its default model and the route is ignored.

is "$(args cursor '' composer-2.5)" '--auto-review,--sandbox,enabled,--trust,--model,composer-2.5' \
  'cursor takes --model'
is "$(args claude /tmp/t1 claude-opus-5-5)" '--permission-mode,auto,--add-dir,/tmp/t1,--model,claude-opus-5-5' \
  'claude takes --model'
is "$(args codex /tmp/t1 gpt-5.5)" \
  '-s,workspace-write,-a,on-request,--add-dir,/tmp/t1,-m,gpt-5.5' 'codex takes -m'

SHEEPR_CODEX_PROFILE=cursor-bridge
is "$(args codex /tmp/t1 composer-2.5)" \
  '-s,workspace-write,-a,on-request,--add-dir,/tmp/t1,-p,cursor-bridge,-m,composer-2.5' \
  'codex keeps -p <profile> alongside -m'
unset SHEEPR_CODEX_PROFILE

is "$(args claude '' '')" '--permission-mode,auto' 'an empty model adds no flag'

# A model id lands in an agent command line just as a profile does.
for bad in 'a b' 'm;id' '$(id)' '--sandbox' '-m' '../x' 'gpt[high]'; do
  out=$(args cursor '' "$bad" 2>&1); rc=$?
  is "$rc" '1' "an invalid model is refused: $bad"
done
sheepr_model_valid 'claude-sonnet-4.5_x'; is "$?" '0' 'a model id with . - _ is valid'

# --- delivery is proved by the status log, never by `done` ------------------
#
# The regression that matters: a worker that had already ended its turn reads
# `done` before the prompt is sent. When the Enter is swallowed the text sits
# unsent in the composer and the state never moves, so `done` was reported to
# the supervisor as "delivered" for a reply the worker never saw.
#
# herdr is stubbed by overriding the three calls the function makes. The
# settle budget is one second, so the whole section costs a couple of seconds.

STUB_STATE="done"
STUB_READS=no          # yes: the worker picks the prompt up and writes a line
STATUS="$SHEEPR_HOME/tasks/t-verify/status"
mkdir -p "$(dirname "$STATUS")"
: >"$STATUS"

# shellcheck disable=SC2317
sheepr_agent_state() { printf '%s' "$STUB_STATE"; }
# shellcheck disable=SC2317
sheepr_agent_prompt() {
  [ "$STUB_READS" = yes ] && printf 'working|1||picked up the reply\n' >>"$STATUS"
  return 0
}
# shellcheck disable=SC2317
sheepr_agent_send_keys() { return 0; }

verify() { sheepr_agent_prompt_verified sheepr-t-verify 'a reply' "$STATUS" 1; }

verify; is "$?" '4' 'a done agent whose status log never moved is not delivery'

STUB_READS=yes
verify; is "$?" '0' 'a status log that grew is proof the prompt landed'

STUB_READS=no
STUB_STATE=working
verify; is "$?" '0' 'an agent that started working needs no further proof'

STUB_STATE=blocked
verify; is "$?" '3' 'an agent parked at a dialog is still reported as parked'

STUB_STATE=idle
verify; is "$?" '4' 'an idle agent with a silent log is still not delivery'

# The status log is the worker's, so a line written by anyone counts as the
# worker having moved. Nothing else in sheepr writes to it while a prompt is
# in flight, which is why the size is taken immediately before submitting.
is "$(grep -c '' "$STATUS")" '1' 'only the read prompt appended to the log'

# --- the interrupt table ----------------------------------------------------

is "$(sheepr_kind_interrupt_keys claude)" 'esc' 'claude is interrupted with esc'
is "$(sheepr_kind_interrupt_keys cursor)" 'esc ctrl+u' 'cursor also has its composer emptied'
is "$(sheepr_kind_interrupt_keys codex)" 'esc ctrl+u' 'codex also has its composer emptied'
sheepr_kind_interrupt_keys nosuchkind >/dev/null
is "$?" '1' 'a kind with no checked key has none'

finish
