#!/usr/bin/env bash
# bin/sheepr-send.sh - answer a worker.
#
# Usage:
#   sheepr-send.sh <task-id> <text> [--resolve <key>]
#   sheepr-send.sh <task-id> --keys <key> [<key>...]
#
# Owns: delivering the supervisor's reply to a running worker, and closing the
# question or blocker that reply answers.
#
# Refuses:
#   - to resolve a key that is not open. Closing a key nobody asked about
#     would hide the real question behind a fold that now looks clean.
#   - to retype a prompt into a composer that already holds one.
#
# The resolved line is written BEFORE the prompt is delivered. If the worker
# dies between the two, the record still shows the captain answered, and the
# reply can be redelivered. The reverse order could lose the answer entirely.

set -uo pipefail

# shellcheck source=bin/sheepr-herdr.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sheepr-herdr.sh"
# shellcheck source=bin/sheepr-status.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sheepr-status.sh"

[ $# -ge 2 ] || die "usage: sheepr-send.sh <task-id> <text> [--resolve <key>]"

ID=$1; shift
sheepr_validate_id "$ID"
sheepr_task_exists "$ID" || die "no such task: $ID"

KEYS_MODE=0
if [ "${1:-}" = "--keys" ]; then
  KEYS_MODE=1; shift
  [ $# -ge 1 ] || die "--keys needs at least one key"
else
  TEXT=$1; shift
fi

RESOLVE=''
while [ $# -gt 0 ] && [ "$KEYS_MODE" = 0 ]; do
  case "$1" in
    --resolve) RESOLVE=${2:-}; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

# Validate the arguments before touching the environment, so a mistyped key is
# reported as a mistyped key rather than as a missing Herdr.
if [ -n "$RESOLVE" ] && ! sheepr_status_open_keys "$ID" | grep -qxF "$RESOLVE"; then
  open=$(sheepr_status_open_keys "$ID" | tr '\n' ' ')
  die "key '$RESOLVE' is not open on $ID (open: ${open:-none})"
fi

sheepr_herdr_require
NAME=$(sheepr_meta_get "$ID" name) || NAME="sheepr-$ID"

# --- key mode: answer a dialog ---------------------------------------------

if [ "$KEYS_MODE" = 1 ]; then
  sheepr_agent_send_keys "$NAME" "$@" || die "could not send keys to $ID"
  printf 'sent keys to %s: %s\n' "$ID" "$*"
  exit 0
fi

# --- resolve ----------------------------------------------------------------

if [ -n "$RESOLVE" ]; then
  # The answer goes INTO the resolved line, not just into the terminal.
  # A worker that reads its own log must find the answer there: delivering it
  # only as a prompt leaves an empty resolved line that reads as "answered with
  # nothing", and the worker asks again.
  sheepr_status_append "$ID" resolved "$RESOLVE" "$TEXT"
  printf 'resolved %s on %s\n' "$RESOLVE" "$ID"
fi

# --- deliver ----------------------------------------------------------------

sheepr_agent_prompt_verified "$NAME" "$TEXT"
case $? in
  0) printf 'delivered to %s\n' "$ID" ;;
  3) die "worker $ID is parked at a dialog; use --keys to answer it" ;;
  4) die "the reply was submitted to $ID but it never started a turn" ;;
  *) die "could not deliver to $ID" ;;
esac

# Clear the wake suppression so the next thing this worker says is reported.
rm -f "$(sheepr_task_dir "$ID")/.woke"
