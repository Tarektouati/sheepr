# sheepr

A supervisor for a fleet of coding agents, in Herdr.

You talk to one agent. It starts the others, watches them, and comes back to
you only when something needs a decision.

## What it is

About 1,700 lines of bash and one instruction file. There is nothing to
install: the repository is the thing. Start a coding agent inside it and
`AGENTS.md` turns that agent into the supervisor.

Each task gets its own Herdr workspace, its own git worktree, and its own
worker. Workers report by appending lines to a status log. A bash loop watches
the fleet and spends no tokens until something is actionable.

The words used here (captain, supervisor, worker, task, brief, status log,
wake, fold, resolve, refuse) are defined in `CONTEXT.md`. You are the captain.

## Requirements

- [Herdr](https://herdr.dev) 0.9.1 or newer, and you must be inside a Herdr pane
- The [flock](https://github.com/Tarektouati/skills/tree/main/flock) skill,
  installed at `~/.agents/skills/flock` or `~/.claude/skills/flock`, or pointed
  at by `SHEEPR_FLOCK`
- `git`, `jq`
- At least one of `cursor-agent`, `claude`, `codex`
- `gh`, only if you use `--delivery pr`

## Use

Start your supervisor session inside this repository:

```sh
cursor-agent --trust
```

Then talk to it:

```
> fix the flaky login test in ~/code/myapp
```

It will ask how you want the work delivered, write a brief, start a worker in
its own worktree, and tell you when there is something to decide.

## Staying informed

You never have to ask the supervisor for updates, and it never makes you wait
while it watches. The watcher runs in the background. You can keep talking to
the supervisor while workers run, and the watcher hands it a new turn as soon
as something is actionable.

The supervisor can be `cursor-agent`, `claude` or `codex`. Each arms the
watcher differently, because each offers a different way to wake an idle
session:

| supervisor | how the watcher runs | how a wake reaches it |
|---|---|---|
| Claude Code | `Stop` hook with `asyncRewake`, in `.claude/settings.json`, running `--hook claude` | the hook exits 2 with the wake on stderr, which wakes Claude even when it is idle |
| Cursor | `./bin/sheepr-watch.sh`, started by the supervisor as a background shell command | the finished command's completion follow-up |
| Codex | async `Stop` hook in `.codex/hooks.json`, running `--hook codex`, which starts a detached `--wake-pane` watcher | the watcher types the wake into the supervisor's Herdr pane once the agent there is idle |

Claude Code:

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "\"${CLAUDE_PROJECT_DIR}\"/bin/sheepr-watch.sh --hook claude",
            "asyncRewake": true,
            "timeout": 28800
          }
        ]
      }
    ]
  }
}
```

Cursor's `stop` hook in `.cursor/hooks.json` is a safety net, and it never
parks the session. `--hook cursor` does one pass and then gives the turn back:

- It says nothing when a watcher is already running.
- When it finds something, it prints a `followup_message`, which starts the
  supervisor's next turn with that line as the prompt:

  ```json
  {"followup_message": "question: fix-login - retry-policy: retry the flaky call or mark the test as known-flaky?"}
  ```

- Otherwise, it asks the supervisor to start the background watcher.

```json
{
  "version": 1,
  "hooks": {
    "stop": [
      {
        "type": "command",
        "command": "\"$CURSOR_PROJECT_DIR\"/bin/sheepr-watch.sh --hook cursor",
        "timeout": 30,
        "loop_limit": 200
      }
    ]
  }
}
```

Cursor also loads Claude Code hooks from `.claude/settings.json`. It does not
support `asyncRewake`, so it would run that hook in the foreground. When
`CURSOR_VERSION` is set, `--hook claude` exits at once, and Cursor's own hook
covers the session.

Codex is the exception. Its background hooks and background terminals cannot
start a turn on an idle session
([openai/codex#33712](https://github.com/openai/codex/issues/33712)), so its
wakes go through Herdr. The `--wake-pane` watcher delivers through
`HERDR_PANE_ID`:

- It waits while the agent in that pane is working or at a dialog.
- It never types into a pane that has no agent in it: one that is gone, or that
  holds a bare shell.

There are two costs:

- **Trust:** you must trust sheepr's hook once in Codex's `/hooks` screen.
- **Mixed text:** a wake typed in while you are typing in the same composer
  gets mixed with your text.

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "\"$(git rev-parse --show-toplevel)/bin/sheepr-watch.sh\" --hook codex",
            "async": true,
            "timeout": 30
          }
        ]
      }
    ]
  }
}
```

The Claude and Codex watchers stop with nothing to report in four cases:

- the fleet has no tasks;
- another watcher already owns the fleet;
- `SHEEPR_HOOK_MAX` seconds (default 28000) have passed;
- for `--wake-pane`, the pane no longer holds an agent.

The next turn end re-arms them. Workers started in a sheepr worktree load these
hooks too, but their `tasks/` is empty, so the hooks exit at once.

### What reaches you

Not everything a worker says is news. The supervisor filters:

| a worker says | what happens |
|---|---|
| `question` | relayed to you. Your answer is relayed back to the worker. |
| `blocked` | usually handled by the supervisor: expired credentials, a missing tool, a wrong assumption in the brief. You hear about it only if it needs you. |
| `done` | reported with the outcome, the risk, and the decision needed from you. |
| `failed` | reported as a failure, with the evidence. |
| `working` | not reported. Routine progress never reaches you. |

A worker never addresses you directly. Everything comes through the
supervisor.

### Example

```
> fix the flaky login test in ~/code/myapp

  How should the work reach you: a pull request, a pushed branch, or local
  commits?

> a PR

  Started. I will come back when there is something to decide.

  [later, without being asked]

  The worker on the login flake needs a decision: the flake is a slow call to
  the auth stub. Should it retry the call, or mark the test as known-flaky?

> retry, at most twice

  Sent.

  [later]

  The login flake is fixed and the PR is up: https://github.com/you/myapp/pull/42.
  CI is green. It was a race in the test setup, not the app. The risk is low:
  only test code changed. Want me to merge?

> merge it
```

## Delivery modes

Delivery is how finished work reaches you. There is no default. The supervisor
asks you before every spawn, and `sheepr-spawn.sh` refuses without
`--delivery`. If you give a standing answer for one project ("always PRs for
myapp"), the supervisor uses it for that project only.

| mode | the worker produces | teardown requires |
|---|---|---|
| `pr` | a pull request, opened with `gh pr create`; its URL is in the done line | a pull request for the branch that is either merged at the branch's current commit, or open with nothing unpushed |
| `branch` | the branch pushed with `git push -u origin sheepr/<id>`; the branch name is in the done line | an upstream on the remote that still exists, with nothing unpushed |
| `local` | commits on the local branch, unpushed; the final commit subject is in the done line | at least one commit the base branch does not have |

In every mode the worktree must have no uncommitted change. A pull request
closed without merging is refused: abandoning work is your call.

## Agent kinds

A worker is one of three kinds, chosen with `--kind`. With no preference, the
supervisor uses `cursor`.

| kind | started with |
|---|---|
| `cursor` | `--force --trust`. Without `--trust` it stops at a trust dialog Herdr reports as `idle`. |
| `claude` | `--dangerously-skip-permissions`. Its folder trust dialog is answered at start, and no other dialog is. |
| `codex` | `-s workspace-write -a never --add-dir <task dir>`, so it can write its status log. Needs codex-cli 0.140 or newer. `SHEEPR_CODEX_PROFILE` adds `-p <profile>`. |

## Worker reporting protocol

`sheepr-spawn.sh` appends the protocol to every brief. A worker reports by
appending one line per event to its status log, `tasks/<id>/status`:

    <verb>|<unix-epoch>|<key>|<text>

The five verbs a worker may write:

| verb | meaning |
|---|---|
| `working` | progress. No action needed. |
| `question` | needs a captain decision. Carries a key. The worker stops. |
| `blocked` | needs the supervisor. The key is optional. The worker stops. |
| `done` | finished, with delivery evidence in the text. |
| `failed` | gave up, with the reason. |

The supervisor writes one more, `resolved`, which closes the question or
blocker with the same key and carries the answer in its text. A missing key
counts as the key `default`.

The worker writes lines like this:

```sh
printf '%s|%s||%s\n' working "$(date +%s)" "added the failing test" >> tasks/fix-login/status
```

A status log with a question and its answer:

```
working|1759000000||reproduced the flake locally
working|1759000420||the auth stub responds slowly under load
question|1759000480|retry-policy|retry the flaky call or mark the test as known-flaky?
resolved|1759000900|retry-policy|retry, at most twice
working|1759000960||added a bounded retry
done|1759001500||https://github.com/you/myapp/pull/42
```

The last line is not the current state. A question asked ten lines ago is
still open, so nothing decides from the tail. The fold replays the whole log,
in order, and reports in this priority:

1. A `done` or `failed` with no `working`, `question` or `blocked` after it.
   A worker that speaks again was not finished.
2. Otherwise the oldest question or blocker still open.
3. Otherwise `working`, or `empty` when the log holds nothing recognisable.

Unrecognised lines are ignored, not fatal. Folded after the fourth line above,
the log reads `working||`; folded after the third, it reads:

```
question|retry-policy|retry the flaky call or mark the test as known-flaky?
```

## Scripts

Each script refuses rather than guesses. The header comment of each one is
its full reference.

### sheepr-spawn.sh

Create a task and start its worker.

```sh
./bin/sheepr-spawn.sh <repo-path> <task-id> \
    --kind <cursor|claude|codex> --delivery <pr|branch|local> --brief <file>
```

```sh
./bin/sheepr-spawn.sh ~/code/myapp fix-login \
    --kind cursor --delivery pr --brief briefs/fix-login.md
```

It creates the branch `sheepr/<id>` in a new worktree and Herdr workspace,
writes the brief plus the protocol to `brief.md` in the worktree, starts the
worker, and tells it to read `./brief.md`. The brief never goes through argv.

Spawns are safe to run in parallel. Spawn reads the `--brief` file once, at the
start, and works from that copy, so rewriting the file while a spawn waits on
Herdr cannot change what its worker gets. Still give each task its own brief
file, such as `briefs/<id>.md`: one shared path is easy to overwrite before you
meant to.

A task id is lowercase letters, digits and hyphens, starting with a letter, at
most 25 characters. Spawn refuses without `--kind` or `--delivery`, when the
brief still holds a `{{placeholder}}`, when the id is in use (including by a
spawn of the same id that is still running), and when the branch already
exists.

Optional: `--model <id>` is passed to the harness (claude and cursor as
`--model`, codex as `-m`); without it the harness runs its own default.
`--budget <tokens>` and `--route <rule>` are recorded in the task's meta.
All three are printed in the spawn summary.

### sheepr-route.sh

Pick the kind, model and token budget for a task from the `routes` table.

```sh
./bin/sheepr-route.sh --type <fix|feature|refactor|research|review|docs> \
    --size <small|medium|large> --risk <low|high> --repo <path>
```

```
$ ./bin/sheepr-route.sh --type docs --size small --risk low --repo ~/code/myapp
cursor composer-2.5 50000 small-docs
```

`routes` sits at the repository root and is yours to edit: one rule per
line, first match wins, `*` matches anything, and its header explains each
column. The router refuses an unknown trait, a malformed table, no matching
rule, an unknown kind, and a harness that is not installed. It never falls
back to another harness. A codex route also needs `SHEEPR_CODEX_PROFILE` and a
model listed in codex-cursor-bridge's catalog,
`$CODEX_HOME/cursor-bridge-models.json`. Whatever kind, model or budget you
name yourself wins over the route.

### sheepr-watch.sh

The supervision loop. It spends no tokens while it waits. A supervisor runs it
in the background (see Staying informed). Run by hand, it blocks your shell
until it wakes.

```sh
./bin/sheepr-watch.sh                    # poll until something is actionable, print one line, exit
./bin/sheepr-watch.sh --once             # one pass, no sleeping
./bin/sheepr-watch.sh --hook cursor      # Cursor stop hook: one pass, never parks; `--hook` alone means this
./bin/sheepr-watch.sh --hook claude      # Claude Code asyncRewake Stop hook: poll, exit 2 with the wake on stderr
./bin/sheepr-watch.sh --hook codex       # Codex async Stop hook: start a detached --wake-pane watcher, return
./bin/sheepr-watch.sh --wake-pane <pane> # poll; type the wake into that Herdr pane once its agent is idle
```

```
$ ./bin/sheepr-watch.sh
question: fix-login - retry-policy: retry the flaky call or mark the test as known-flaky?
```

The line it prints starts with one of `question:`, `blocked:`, `done:`,
`failed:`, `missing:` or `stalled:`. Each wake is also appended to
`tasks/.wakes`.

`--once` exits with:

- 0 when it woke;
- 1, printing nothing, when the fleet is quiet;
- 3 when another watcher already owns the fleet.

Only one watcher owns the fleet at a time, through `tasks/.watch.lock`. A
watcher that finds the lock held leaves without touching task state:

- `--once` and the plain loop print
  `watching: a watcher already owns the fleet (pid N)`;
- the hook modes print nothing.

`--wake-pane` writes its output to `tasks/.watch-pane.log`, and records its
target pane in `tasks/.watch.lock/pane`.

### sheepr-fleet.sh

A read-only view of every worktree, not just the ones sheepr made.

```sh
./bin/sheepr-fleet.sh               # every repository sheepr has a task in
./bin/sheepr-fleet.sh --repo PATH   # one repository, task or not
./bin/sheepr-fleet.sh --json        # machine readable
```

```
$ ./bin/sheepr-fleet.sh --repo ~/code/myapp
TASK                  STATE     AGENT    TOKENS  BRANCH              DIRTY  AHEAD  PR         PATH
fix-login             question  idle     1.4M    sheepr/fix-login    0      2      -          /Users/you/.herdr/worktrees/myapp/sheepr-fix-login
(orphan)              -         -        -       spike-cache         3      1      -          /Users/you/code/myapp-spike
old-docs (stale)      done      -        ?       -                   ?      ?      -          /Users/you/.herdr/worktrees/myapp/sheepr-old-docs

tokens: fleet 1.4M over 1 task(s), 1 unknown; supervisor 20.2M

1 orphaned worktree(s): not sheepr tasks, so no sheepr command protects them.
  1 of them hold uncommitted work. Decide before anything removes them.
1 stale task(s): the record exists but the worktree is gone.
Use the flock skill to triage these; it confirms each action with you.
```

There are three kinds of row:

- **task**: a worktree with a task record. Shows its folded state.
- **orphan**: a linked worktree with no task record. sheepr does not manage
  it, and no sheepr command protects it.
- **stale**: a task record whose worktree no longer exists.

`TOKENS` is the task's usage from `sheepr-usage.sh`; `?` means it could not be
read. The footer gives the total over the tasks shown and the supervisor's own
spend.

`--json` prints an object with `tasks`, `orphans`, `stale` and `all` arrays,
and a `usage` object: `fleet_total`, `measured`, `unknown` and `supervisor`.
Fleet never changes anything.

### sheepr-status.sh

The status log grammar and the fold.

```sh
./bin/sheepr-status.sh fold   <task-id>                     # <state>|<key>|<text>
./bin/sheepr-status.sh open   <task-id>                     # one open key per line
./bin/sheepr-status.sh append <task-id> <verb> <key> <text>
```

```
$ ./bin/sheepr-status.sh fold fix-login
question|retry-policy|retry the flaky call or mark the test as known-flaky?
$ ./bin/sheepr-status.sh open fix-login
retry-policy
$ ./bin/sheepr-status.sh append fix-login working "" "note from the supervisor"
```

`append` strips pipes and newlines from the key and text, so a written line
always has four fields.

### sheepr-send.sh

Answer a worker.

```sh
./bin/sheepr-send.sh <task-id> <text> [--resolve <key>]
./bin/sheepr-send.sh <task-id> --keys <key> [<key>...]
```

```sh
# relay the captain's answer and close the question
./bin/sheepr-send.sh fix-login "Retry, at most twice." --resolve retry-policy

# answer a dialog the worker is parked at, after reading it
./bin/sheepr-send.sh fix-login --keys down enter
```

With `--resolve`, the answer is written into the `resolved` line before it is
typed into the worker's terminal, so the record survives a worker that dies in
between. Send refuses to resolve a key that is not open, and refuses to type
into a worker parked at a dialog: use `--keys` for that.

### sheepr-teardown.sh

Retire a task once its work has landed.

```sh
./bin/sheepr-teardown.sh <task-id>
./bin/sheepr-teardown.sh <task-id> --force
```

```
$ ./bin/sheepr-teardown.sh fix-login
pull request https://github.com/you/myapp/pull/42 is merged at this commit
removed workspace w7
torn down fix-login (archived)
```

It checks the evidence for the task's delivery mode (see Delivery modes),
removes the workspace and worktree, and moves the task's records to
`tasks/.archive/<id>-<epoch>`. The status log is kept.

A refusal is a finding, not an obstacle. `--force` skips the check, and is
only for work you have said, in as many words, to discard.

### sheepr-usage.sh

What a worker spent in tokens, read from its harness's own session log. The
only file that reads those logs.

```sh
./bin/sheepr-usage.sh task fix-login         # 1409233 38 14112 claude
./bin/sheepr-usage.sh task fix-login --json  # with cache_read and cache_creation
./bin/sheepr-usage.sh self                   # the supervisor's own spend
```

One line: `<total> <input> <output> <source>`, or `unknown <reason>`. Input
counts fresh tokens only; cache reads and cache writes are separate, in
`--json`, and in the total. It never estimates:

| kind | read from |
|---|---|
| claude | `~/.claude/projects/<slug of the worktree>/**/*.jsonl`, each message once |
| codex | `~/.codex/{sessions,archived_sessions}/**/rollout-*.jsonl` whose cwd is the worktree; the last cumulative count per session |
| cursor | nothing: cursor-agent keeps no usage record, so it is always `unknown cursor-unreadable` |

`self` sums every harness's sessions in sheepr's own directory. The first read
of a task records `usage_source` in its meta; `--read-only` skips that.

### sheepr-test.sh

Run the tests.

```sh
./bin/sheepr-test.sh                # every test
./bin/sheepr-test.sh watch send     # tests whose file name contains any argument
```

Tests that need a live Herdr print `skip:` when one is not available.

### sheepr-lint.sh

Check every script: `bash -n` always, and `shellcheck` at warning level when it
is installed. It also fails when `AGENTS.md` is over 3000 words, because the
supervisor loads it on every turn.

```sh
./bin/sheepr-lint.sh
```

## How it decides

The hard part is telling a stuck worker from a thinking one. Herdr reports an
agent as `idle` both when it has finished and when it is waiting on its own
long tool call, so `idle` alone means nothing. The watcher uses a ladder:

1. The status log. A worker that asked a question, reported done, or failed
   wins immediately, whatever Herdr says.
2. Herdr's state. `working` proves life. `blocked` and `missing` wake you.
   Before reporting `missing`, the watcher looks the workspace up by its label,
   because workspace and pane ids do not survive a Herdr restart.
3. Neither. Look for evidence: did the status log grow, or did any file in the
   worktree change? Only when there is none of that, for longer than the stall
   bound, is a worker reported as stalled.

Nothing wakes you twice for the same thing. Each wake records a signature, and
an unchanged signature is absorbed to `tasks/.watch-triage.log` instead.

The signature is recorded only after the wake was delivered: printed, written
to stderr, or confirmed by Herdr as submitted to the supervisor's pane. A
watcher killed in between repeats the wake on the next pass rather than losing
it. A failed delivery records nothing and is retried.

### The stall rule

The first pass that sees no progress opens a quiet window. While the window is
younger than `SHEEPR_STALL` seconds (default 240), the watcher waits. Once it
is older, the watcher scans the worktree for any file written since the window
opened. The scan goes `SHEEPR_SCAN_MAXDEPTH` levels deep (default 6), skips
`.git`, `node_modules`, `target`, `dist`, `build`, `.venv`, `__pycache__` and
`.next`, and is killed after `SHEEPR_SCAN_TIMEOUT` seconds (default 10).

A written file is life, and closes the window. A scan that times out counts as
no evidence. With no evidence, the watcher wakes as `stalled:`. A stall is a
request to look, not a diagnosis.

### The triage log

Every decision that does not wake you is recorded in
`tasks/.watch-triage.log`, one line each:

```
1759000420|fix-login|working
1759000435|fix-login|quiet window opened (agent=idle)
1759000450|fix-login|quiet 15s of 240s (agent=idle)
1759000480|fix-login|status log grew (210 -> 298)
1759000495|fix-login|absorbed (already woke for: q:retry-policy:retry the flaky call or mark the test as known-flaky?)
```

Read it when you want to know why the watcher stayed silent.

## Configuration

All optional. Durations are in seconds.

| variable | default | what it does |
|---|---|---|
| `SHEEPR_POLL` | `15` | seconds between watcher passes |
| `SHEEPR_STALL` | `240` | seconds a quiet window must last before the worktree is scanned and a stall can wake |
| `SHEEPR_HOOK_MAX` | `28000` | seconds a `--hook claude` or `--wake-pane` watcher waits before giving up with nothing to report. Keep it below the 28800s timeout in `.claude/settings.json`, so Claude never kills the watcher between delivering a wake and recording it |
| `SHEEPR_SCAN_MAXDEPTH` | `6` | directory depth of the worktree scan |
| `SHEEPR_SCAN_TIMEOUT` | `10` | seconds before the worktree scan is killed and counted as no evidence |
| `SHEEPR_FLOCK` | unset | the flock skill directory; must contain an executable `scripts/wt-status.sh`. Checked before `~/.agents/skills/flock` and `~/.claude/skills/flock` |
| `SHEEPR_HOME` | `SHEEPR_ROOT` | where `tasks/` lives |
| `SHEEPR_ROOT` | the checkout holding `bin/` | the sheepr checkout |
| `SHEEPR_CLAUDE_HOME` | `~/.claude` | where `sheepr-usage.sh` reads claude session logs |
| `CODEX_HOME` | `~/.codex` | where `sheepr-usage.sh` reads codex rollouts |
| `SHEEPR_AGENTS_MAX_WORDS` | `3000` | the AGENTS.md word limit `sheepr-lint.sh` enforces |
| `SHEEPR_CODEX_PROFILE` | unset | when set and non-empty, codex workers start with `-p <profile>`. Letters, digits, `-` and `_` only, and not a leading `-`; anything else is refused |

Two variables are read but never set by you, because the harness sets them:

| variable | set by | what sheepr does with it |
|---|---|---|
| `CURSOR_VERSION` | Cursor, in every hook | `--hook claude` exits at once, because Cursor imported it from `.claude/settings.json` and would run it in the foreground |
| `HERDR_PANE_ID` | Herdr, in every pane | `--hook codex` delivers wakes to this pane. When it is unset, the hook starts no watcher and reports why in a `systemMessage` |

```sh
SHEEPR_STALL=600 SHEEPR_POLL=30 ./bin/sheepr-watch.sh
SHEEPR_CODEX_PROFILE=work ./bin/sheepr-spawn.sh ~/code/myapp fix-login \
    --kind codex --delivery branch --brief briefs/fix-login.md
```

## Rules it enforces

The scripts refuse rather than guess:

- The supervisor never edits project code. Every change goes to a worker.
- Nothing merges without your explicit word.
- `sheepr-teardown.sh` proves the work landed before destroying a worktree.
- `sheepr-spawn.sh` refuses without an explicit delivery mode. There is no
  default for how finished work reaches you.

## Layout

```
AGENTS.md           the supervisor's contract
CONTEXT.md          the vocabulary
.claude/settings.json  Claude Code's turn-end hook that arms the watcher
.codex/hooks.json   Codex's turn-end hook that arms the watcher
.cursor/hooks.json  Cursor's turn-end hook, a safety net that never parks
bin/                the scripts; sheepr-herdr.sh is the only one that runs herdr,
                    sheepr-flock.sh the only one that runs flock,
                    sheepr-usage.sh the only one that reads harness session logs
tasks/              per-task state, gitignored
tests/              run with ./bin/sheepr-test.sh
```

Inside `tasks/`:

```
tasks/<id>/meta           workspace, pane, worktree, branch, kind, delivery, usage_source
tasks/<id>/status         the status log
tasks/<id>/brief.md       the brief as the supervisor wrote it, copied when spawn started
tasks/.wakes              every wake, one line each
tasks/.watch-triage.log   every decision that did not wake
tasks/.watch.lock/        held by the one watcher that owns the fleet: pid, and pane for --wake-pane
tasks/.watch-pane.log     output of the detached --wake-pane watcher
tasks/.archive/           torn-down tasks
```

## Development

```sh
./bin/sheepr-test.sh      # all tests
./bin/sheepr-lint.sh      # syntax, and shellcheck when installed
```

Tests that need a live Herdr print `skip:` when one is not available.

## flock

Git and worktree analysis is delegated to the
[flock](https://github.com/Tarektouati/skills/tree/main/flock) skill: base
branch resolution, what is pushed, and whether a pull request merged the
current commit. sheepr reads flock's JSON output and never sources its shell.

The two tools sit on opposite gates, deliberately. sheepr acts without asking
and refuses when something is unsafe, because a supervisor that stops to
confirm every spawn is not delegating. flock confirms every state-changing
action with you, which makes it the right tool for the interactive work sheepr
declines: triaging orphaned worktrees, rebasing, cleaning up by hand.

`sheepr-fleet.sh` is where they meet. It reports orphans; flock helps you
decide what to do about them.

## Credit

The design owes a lot to [firstmate](https://github.com/kunchenguid/firstmate),
which solves the same problem across five session backends and seven agent
harnesses. sheepr is the small version: Herdr only.
