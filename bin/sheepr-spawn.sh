#!/usr/bin/env bash
# bin/sheepr-spawn.sh - start one worker on one task.
#
# Usage:
#   sheepr-spawn.sh <repo-path> <task-id> --kind <cursor|claude|codex> \
#                   --delivery <pr|branch|local> --brief <file>
#
# Owns: creating the worktree workspace, writing the task metadata and brief,
# starting the worker, and delivering the doorbell prompt.
#
# Refuses:
#   - when --kind or --delivery is absent. There is no default delivery. The
#     supervisor must ask the captain and pass the answer explicitly, because
#     guessing how finished work reaches a human is never recoverable.
#   - when the brief still contains a {{placeholder}}.
#   - when the task id is already in use.
#
# The brief is never passed through argv. Every agent kind quotes, truncates
# and strips characters differently, so the brief goes to a file and the
# prompt is one short fixed line that points at it.

set -uo pipefail

# shellcheck source=bin/sheepr-herdr.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sheepr-herdr.sh"

usage() {
  sed -n '3,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 2
}

[ $# -ge 2 ] || usage
REPO_ARG=$1; shift
ID=$1; shift

KIND=''; DELIVERY=''; BRIEF=''
while [ $# -gt 0 ]; do
  case "$1" in
    --kind) KIND=${2:-}; shift 2 ;;
    --delivery) DELIVERY=${2:-}; shift 2 ;;
    --brief) BRIEF=${2:-}; shift 2 ;;
    -h|--help) usage ;;
    *) die "unknown argument: $1" ;;
  esac
done

# --- refusals ---------------------------------------------------------------

[ -n "$REPO_ARG" ] || usage
sheepr_validate_id "$ID"

[ -n "$KIND" ] || die "--kind is required (one of: $SHEEPR_AGENT_KINDS)"
sheepr_kind_valid "$KIND" || die "unknown --kind '$KIND' (one of: $SHEEPR_AGENT_KINDS)"

[ -n "$DELIVERY" ] || die "--delivery is required (pr, branch, or local). There is no default: ask the captain."
case "$DELIVERY" in
  pr|branch|local) ;;
  *) die "unknown --delivery '$DELIVERY' (pr, branch, or local)" ;;
esac

[ -n "$BRIEF" ] || die "--brief <file> is required"
[ -f "$BRIEF" ] || die "brief file not found: $BRIEF"
if grep -q '{{[^}]*}}' "$BRIEF"; then
  die "brief still contains placeholders: $(grep -o '{{[^}]*}}' "$BRIEF" | sort -u | tr '\n' ' ')"
fi

REPO=$(cd "$REPO_ARG" 2>/dev/null && pwd) || die "repo path not found: $REPO_ARG"
git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository: $REPO"

sheepr_herdr_require
sheepr_ensure_home
sheepr_task_exists "$ID" && die "task '$ID' already exists; tear it down first"

# --- create -----------------------------------------------------------------

BRANCH="sheepr/$ID"
LABEL="sheepr-$ID"
NAME="sheepr-$ID"
TASK_DIR=$(sheepr_task_dir "$ID")
STATUS=$(sheepr_status_file "$ID")

git -C "$REPO" show-ref --verify --quiet "refs/heads/$BRANCH" \
  && die "branch $BRANCH already exists in $REPO"

OUT=$(sheepr_worktree_create "$REPO" "$BRANCH" "$LABEL") \
  || die "could not create the worktree workspace"
WS=$(printf '%s' "$OUT" | cut -f1)
PANE=$(printf '%s' "$OUT" | cut -f2)
WORKTREE=$(printf '%s' "$OUT" | cut -f3)

mkdir -p "$TASK_DIR"
: >"$STATUS"

sheepr_meta_set "$ID" workspace "$WS"
sheepr_meta_set "$ID" pane "$PANE"
sheepr_meta_set "$ID" label "$LABEL"
sheepr_meta_set "$ID" name "$NAME"
sheepr_meta_set "$ID" worktree "$WORKTREE"
sheepr_meta_set "$ID" repo "$REPO"
sheepr_meta_set "$ID" kind "$KIND"
sheepr_meta_set "$ID" delivery "$DELIVERY"
sheepr_meta_set "$ID" branch "$BRANCH"
sheepr_meta_set "$ID" created "$(sheepr_now)"

# --- the brief --------------------------------------------------------------

case "$DELIVERY" in
  pr)     EVIDENCE='Open a pull request with `gh pr create` and put its full https:// URL in the done line.' ;;
  branch) EVIDENCE='Push the branch with `git push -u origin '"$BRANCH"'` and put the branch name in the done line.' ;;
  local)  EVIDENCE='Commit your work on this branch and leave it unpushed. Put the final commit subject in the done line.' ;;
esac

cp "$BRIEF" "$TASK_DIR/brief.md"

# The brief lives inside the worktree so the doorbell can stay a fixed "./brief.md"
# for every agent kind. Exclude it locally so it never shows up as an untracked
# change, which teardown would otherwise read as unlanded work.
EXCLUDE=$(git -C "$WORKTREE" rev-parse --git-path info/exclude 2>/dev/null)
if [ -n "$EXCLUDE" ]; then
  EXCLUDE=$(cd "$WORKTREE" && cd "$(dirname "$EXCLUDE")" && pwd)/$(basename "$EXCLUDE")
  mkdir -p "$(dirname "$EXCLUDE")"
  grep -qxF '/brief.md' "$EXCLUDE" 2>/dev/null || printf '/brief.md\n' >>"$EXCLUDE"
fi

{
  cat "$BRIEF"
  cat <<BRIEF_TAIL

---

# How to work (sheepr protocol)

You are a worker. You have one task, described above. When it is finished, you stop.

## Your workspace

You are in an isolated git worktree on branch \`$BRANCH\`. It is yours alone.
Confirm before you start:

    pwd -P    # must be $WORKTREE

If you are anywhere else, write a blocked line and stop.

## Reporting

Append one line to this file at every event. Nothing else reads your terminal.

    $STATUS

Format, pipe separated, exactly four fields:

    <verb>|<unix-epoch>|<key>|<text>

Write it like this:

    printf '%s|%s||%s\\n' working "\$(date +%s)" "added the failing test" >> $STATUS

The five verbs you may write:

- \`working\` - progress. Write one when you start, and at each meaningful step.
- \`question\` - you need a decision only the captain can make. Set a short key
  in the third field, then STOP and wait. Example:
  \`question|1759000000|db-choice|sqlite or postgres for the cache?\`
- \`blocked\` - something outside the task stops you (missing access, broken
  tool). STOP and wait.
- \`done\` - the task is finished and the evidence below exists.
- \`failed\` - you cannot finish. Say why.

Rules:

- One line per event. Never rewrite or delete earlier lines.
- The epoch must be real: \`\$(date +%s)\`.
- Keep the text short and on one line. No pipes in the text.
- After \`question\` or \`blocked\`, stop working and wait.
  The supervisor answers in two places at once: it types the reply into your
  terminal, and it appends a \`resolved\` line carrying the same answer in its
  fourth field. Either one is the answer. Resume as soon as you have it, and
  do not ask again unless the answer is genuinely unusable.

## Delivery

This task ships as: **$DELIVERY**

$EVIDENCE

Do not merge anything. Do not push to \`main\`.

## Who you talk to

You never address the captain. You have no access to them. The supervisor reads
your status log and speaks for you. Put everything you need to say in the log.
BRIEF_TAIL
} >"$WORKTREE/brief.md"

# --- launch -----------------------------------------------------------------

if ! sheepr_agent_start "$NAME" "$KIND" "$PANE"; then
  warn "worker did not become ready; the workspace is left in place for inspection"
  warn "workspace=$WS pane=$PANE worktree=$WORKTREE"
  exit 1
fi

DOORBELL='Read ./brief.md and follow it. Do not ask me anything; use the status log.'
sheepr_agent_prompt_verified "$NAME" "$DOORBELL"
case $? in
  0) ;;
  3) warn "worker is parked at a dialog; the brief was not delivered" ; exit 1 ;;
  4) warn "the doorbell was submitted but the worker never started a turn" ; exit 1 ;;
  *) warn "could not deliver the doorbell prompt" ; exit 1 ;;
esac

printf 'spawned %s\n' "$ID"
printf '  kind      %s\n' "$KIND"
printf '  delivery  %s\n' "$DELIVERY"
printf '  branch    %s\n' "$BRANCH"
printf '  worktree  %s\n' "$WORKTREE"
printf '  workspace %s (pane %s)\n' "$WS" "$PANE"
printf '  status    %s\n' "$STATUS"
