# Context

The words this project uses, and what each one means.
Use these words in code, in commits, and when talking to the captain.
Do not invent synonyms.

## Roles

**captain** - the human. The only person sheepr serves.
There is exactly one, and collaboration between humans is out of scope.

**supervisor** - the agent the captain talks to.
It starts workers, watches them, and reports outcomes.
It never edits project code itself.

**worker** - an agent that does one task and then stops.
A worker never addresses the captain.

**reviewer** - an agent that runs one review of a finished task, in a pane
split beside the worker, in the same workspace and worktree. It reads and
reports; it never edits, never posts, and never addresses the captain. A
claude reviewer runs in plan mode; any other kind is told not to edit.

## Things

**task** - one unit of work.
It owns one git worktree, one Herdr workspace, one worker, and one status log.
A task is identified by a **task id**: lowercase letters, digits and hyphens, 25 characters at most.

**brief** - the instructions a worker is given, as a file.
The captain's request plus the sheepr protocol.
It is written to `brief.md` inside the worktree and is never passed as a command-line argument.

**status log** - `tasks/<id>/status`.
An append-only file. The worker writes one line per event.
It is the only thing a worker says. Nothing reads a worker's terminal to decide anything.

The one exception is the reviewer's pane: a reviewer writes no status log, so
the watcher and `sheepr-review.sh collect` read its pane, through the Herdr
adapter only, for the sentinel and the findings. Nothing else reads a terminal
to decide anything.

**review** - a `/semantic-review` of a done task's PR, or of its branch
against meta's `base`, run by a reviewer the captain said yes to.
`bin/sheepr-review.sh`. Its findings are saved to `tasks/<id>/review.md`,
which travels with the task. The reviewer has its own budget, from the
`review` route, recorded in meta apart from the worker's.

**sentinel** - the line a reviewer prints after its last finding,
`SHEEPR-REVIEW-DONE-<nonce>`, which wakes `reviewed:`. The prompt describes it
in parts and never holds it whole, so its echo cannot be mistaken for it. A
reviewer that goes quiet without it is `stalled:`.

**meta** - `tasks/<id>/meta`.
Key and value, one per line. Where the task's workspace, pane, worktree, branch, kind and delivery are recorded.

**wake** - a reason the supervisor must take a turn.
Written to `tasks/.wakes` and printed by the watcher.

**watcher** - the one `bin/sheepr-watch.sh` process that owns the fleet,
holding `tasks/.watch.lock`. It runs in the background and wakes the
supervisor; any other watcher that finds the lock held leaves.

**delivery** - how finished work reaches the captain. One of:

- `pr` - a pull request is opened and its URL is reported.
- `branch` - the branch is pushed, no pull request.
- `local` - commits stay on the local branch.

There is no default. The supervisor asks the captain every time.

**route** - the kind, model and default budget chosen for a task, from the
first matching rule in `routes`. `bin/sheepr-route.sh`. The captain's
explicit kind, model or budget always overrides it. There is no fallback:
an unavailable harness is a refusal.

**traits** - what the router matches on: type, size, risk, and repo.

**model** - the model a worker runs. claude uses Claude models, cursor uses
Cursor's model list, and codex runs only through codex-cursor-bridge, so its
models are Cursor's too.

**usage** - the tokens a worker has spent, read from its harness's own
session log by `bin/sheepr-usage.sh`. When it cannot be read, it is
`unknown`, never an estimate.

**budget** - the token limit for one task, recorded in meta. It is measured
against fresh input plus output tokens; cache reads and cache creation do not
count. Reaching it interrupts the worker and wakes the supervisor (**over
budget**). The work is kept. `bin/sheepr-send.sh <id> --budget` raises it.

## Actions

**spawn** - create a task and start its worker. `bin/sheepr-spawn.sh`.

**fold** - replay a status log to get the current state. `bin/sheepr-status.sh fold`.
The fold exists because the last line is not the current state: a question asked
ten lines ago is still open.

**wake** (verb) - report one actionable thing and stop. `bin/sheepr-watch.sh`.

**absorb** - decide that something is not actionable, record it in the triage
log, and stay silent.

**resolve** - close an open question or blocker by key. `bin/sheepr-send.sh --resolve`.

**reopen** - send a done worker a fix plan the captain approved after a
review. `bin/sheepr-send.sh --reopen`. Writes `reopened`.

**tear down** - retire a task after proving its work landed. `bin/sheepr-teardown.sh`.

**refuse** - stop and report, rather than guess or proceed.
A refusal is a correct outcome. It is never an obstacle to work around.

## Status verbs

A worker may write five:

| verb | meaning |
|---|---|
| `working` | progress. No action needed. |
| `question` | needs a captain decision. Carries a key. The worker stops. |
| `blocked` | needs the supervisor. The worker stops. |
| `done` | finished, with delivery evidence in the text. |
| `failed` | gave up, with the reason. |

The supervisor writes two: `resolved`, which closes a key, and `reopened`,
which sends a done worker back to work on a fix plan. `reopened` folds as
working, so the worker's next `done` wakes again.

Line format, four pipe-separated fields:

    <verb>|<unix-epoch>|<key>|<text>

## Agent states

Herdr reports five: `idle`, `working`, `blocked`, `done`, `unknown`.
sheepr adds `missing` for "Herdr could not tell us".

Only `working` is positive evidence that a worker is alive.
`idle` is not evidence that a worker has stopped: a harness waiting on its own
long tool call reads idle, and so does an agent parked at a dialog Herdr does
not recognise. Every other state must be corroborated by the status log or by
file writes in the worktree.
