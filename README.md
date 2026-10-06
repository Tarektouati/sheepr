# sheepr

A supervisor for a fleet of coding agents, in Herdr.

You talk to one agent. It starts the others, watches them, and comes back to
you only when something needs a decision.

## What it is

About 1,300 lines of bash and one instruction file. There is nothing to
install: the repository is the thing. Start a coding agent inside it and
`AGENTS.md` turns that agent into the supervisor.

Each task gets its own Herdr workspace, its own git worktree, and its own
worker. Workers report by appending lines to a status log. A bash loop watches
the fleet and spends no tokens until something is actionable.

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

## By hand

```sh
# see everything: tasks, plus worktrees sheepr did not make
./bin/sheepr-fleet.sh

# start a task
./bin/sheepr-spawn.sh ~/code/myapp fix-login \
    --kind cursor --delivery pr --brief /tmp/brief.md

# watch: silent until something needs you, then one line.
# Also wakes with a report every SHEEPR_REPORT seconds (default 1800, 0 = off)
./bin/sheepr-watch.sh

# what is every worker doing?
./bin/sheepr-report.sh

# send a scout: no code change, proposals in tasks/perf-ideas/report.md
./bin/sheepr-spawn.sh ~/code/myapp perf-ideas \
    --kind claude --delivery report --brief /tmp/scout.md

# answer a question the worker raised
./bin/sheepr-send.sh fix-login "Use the second approach." --resolve approach

# retire it, once the work has landed
./bin/sheepr-teardown.sh fix-login
```

## How it decides

The hard part is telling a stuck worker from a thinking one. Herdr reports an
agent as `idle` both when it has finished and when it is waiting on its own
long tool call, so `idle` alone means nothing. The watcher uses a ladder:

1. The status log. A worker that asked a question, reported done, or failed
   wins immediately, whatever Herdr says.
2. Herdr's state. `working` proves life. `blocked` and `missing` wake you.
3. Neither. Look for evidence: did the status log grow, or did any file in the
   worktree change? Only when there is none of that, for longer than the stall
   bound, is a worker reported as stalled.

Nothing wakes you twice for the same thing. Each wake records a signature, and
an unchanged signature is absorbed to `tasks/.watch-triage.log` instead.

## Rules it enforces

The scripts refuse rather than guess:

- The supervisor never edits project code. Every change goes to a worker.
- Nothing merges without your explicit word.
- `sheepr-teardown.sh` proves the work landed before destroying a worktree.
- `sheepr-spawn.sh` refuses without an explicit delivery mode. There is no
  default for how finished work reaches you.

## Layout

```
AGENTS.md    the supervisor's contract
CONTEXT.md   the vocabulary
bin/         the scripts; sheepr-herdr.sh is the only one that runs herdr
tasks/       per-task state, gitignored
tests/       run with ./bin/sheepr-test.sh
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
