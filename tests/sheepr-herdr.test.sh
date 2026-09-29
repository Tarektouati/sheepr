#!/usr/bin/env bash
# tests/sheepr-herdr.test.sh - the per-kind launch table.
#
# The regression that matters: a codex worker's status log lives in
# $SHEEPR_HOME/tasks/<id>/, outside its worktree, so under `-s workspace-write`
# every append it makes is denied. It can never report question, blocked or
# done, and the supervisor sees a task that simply stops. The task directory
# has to reach codex as --add-dir.
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

# --- the other kinds are untouched ------------------------------------------

is "$(args cursor)" '--force,--trust' 'cursor keeps --force --trust'
is "$(args claude)" '--dangerously-skip-permissions' 'claude keeps its bypass flag'
args nosuchkind >/dev/null 2>&1
is "$?" '1' 'an unknown kind is refused'

# --- codex: the sandbox must reach the status log ---------------------------

is "$(args codex)" '-s,workspace-write,-a,never' \
  'with no task directory the codex args are unchanged'

is "$(args codex /tmp/sheepr/tasks/t1)" \
  '-s,workspace-write,-a,never,--add-dir,/tmp/sheepr/tasks/t1' \
  'the task directory is added to the codex sandbox'

# A path with a space must arrive as one argument. A flat string that the
# caller word-splits would break this into two, and codex would take the tail
# of the path as its next flag.
sheepr_kind_args codex '/tmp/my tasks/t1'
is "${#SHEEPR_KIND_ARGS[@]}" '6' 'a task directory with a space stays one argument'
is "${SHEEPR_KIND_ARGS[5]}" '/tmp/my tasks/t1' 'and it arrives unmangled'

# --- codex: the optional profile --------------------------------------------

SHEEPR_CODEX_PROFILE=cursor-bridge
is "$(args codex /tmp/sheepr/tasks/t1)" \
  '-s,workspace-write,-a,never,--add-dir,/tmp/sheepr/tasks/t1,-p,cursor-bridge' \
  'a profile is appended as -p <profile>'
is "$(args cursor)" '--force,--trust' 'the profile does not leak into other kinds'
unset SHEEPR_CODEX_PROFILE

SHEEPR_CODEX_PROFILE=''
is "$(args codex)" '-s,workspace-write,-a,never' \
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

finish
