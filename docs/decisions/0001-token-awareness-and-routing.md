# 0001 - Token awareness and a router

Status: accepted, not yet built.
Date: 2026-10-10.

## Why

Three things were missing.

- **The kind was picked by hand.** The supervisor passed `--kind` with
  `cursor` as the default, whatever the task. A one-line docs fix and a
  migration got the same harness.
- **No model was ever chosen.** Each harness ran its own default model. A
  small task paid for a large model, or a risky task got a weak one.
- **Spend was invisible.** Nothing measured what a worker consumed, so a
  runaway worker could burn tokens until someone noticed, and the captain
  had no number to judge a route by.

The captain asked for sheepr to be token aware and to route each task to the
right harness and model.

## What we decided

| topic | decision | why |
|---|---|---|
| Meaning of "token aware" | Four parts: measure and report, budgets that refuse, cheaper by routing, a frugal supervisor | Measuring without enforcing changes nothing; routing without measuring cannot be judged |
| Who routes | A deterministic rules script, `bin/sheepr-route.sh` | Testable, the same answer every time, and it refuses when no rule matches, like every sheepr script |
| Router vs captain | The captain's explicit kind, model or budget always wins | The router only fills the gap that the `cursor` default used to fill |
| Router output | A kind **and** a model | The model is most of the cost difference |
| Models per kind | claude: Claude models. cursor: Cursor's model list. codex: **only** through [codex-cursor-bridge](https://github.com/Tarektouati/codex-cursor-bridge), so its models are Cursor's catalog | The captain runs codex on their Cursor subscription, never on OpenAI's models |
| Traits the router reads | type, size, risk, repo/language | The supervisor can judge these from the brief and the repository |
| Where rules live | One `routes` file in sheepr | One fleet, one policy, one place to look |
| Usage source | Parse each harness's own session log, in one adapter, `bin/sheepr-usage.sh` | A worker cannot count its own tokens reliably, and a stuck worker reports nothing |
| Unreadable usage | Report `unknown`, never estimate | Hard rule 5: report faithfully |
| Budget unit | Tokens | No price table to keep current |
| Budget source | Each route carries a default; `--budget` overrides | Every task gets a budget without one more question per spawn |
| Budget on an unmeasurable kind | Allow, warn once that it is not enforced | Not blocking cursor, but never pretending |
| Over budget | The watcher interrupts the worker and wakes the supervisor with `overbudget:` | Nothing more is spent until the captain decides; the work is never discarded |
| Harness unavailable | Refuse, no fallback | A silent substitute is a guess about what the captain wanted |
| Frugal supervisor | Terse one-line wakes, smaller default pane reads, the supervisor's own spend shown, and lint fails when AGENTS.md exceeds 3000 words | The supervisor is the only agent that runs all day |

## What we rejected

- **An LLM classifier as router.** It spends tokens to save tokens, adds an
  API dependency, and cannot be tested deterministically.
- **The supervisor's judgment alone.** Cheapest to build, but it drifts and
  cannot be tested.
- **Workers self-reporting usage.** Unreliable, and silent exactly when it
  matters.
- **Dollar budgets.** Closer to what the captain cares about, but they need
  a per-model price table that goes stale.
- **Fallback routing.** A substitute harness or model is a decision the
  captain did not make.
- **Routing silently, or asking every time.** The captain overrides when they
  care; otherwise the route is one line next to the delivery-mode question.

## Codex and the bridge

Codex reaches models only through the bridge. It is started with
`-p <profile>` (the existing `SHEEPR_CODEX_PROFILE`, e.g. `cursor-bridge`) and
`-m <cursor-model-id>`. The router refuses a codex route unless the profile
is set and the model is in the bridge's catalog,
`$CODEX_HOME/cursor-bridge-models.json`. The bridge passes Cursor's `usage`
through in `response.completed`, so codex rollout logs carry real token
counts.

## Consequences

- New file to maintain: `routes`. A wrong default rule routes badly until the
  captain edits it.
- cursor usage reads `unknown` until a reliable source is found, so budgets on
  cursor workers are not enforced and the captain is told so.
- New task metadata: `model`, `budget`, `route`, `usage_source`.
- New wake: `overbudget:`. A new herdr adapter operation interrupts a worker.
- New vocabulary in `CONTEXT.md`: route, traits, budget, usage, over budget.

## How it is delivered

Three tasks, `claude` workers, delivery `branch`:

1. `token-usage`: `bin/sheepr-usage.sh`, usage in the fleet view, the
   supervisor's own spend, the AGENTS.md word-limit lint.
2. `task-router`: `routes`, `bin/sheepr-route.sh`, the `--model` flag through
   spawn and the herdr launch table, `--budget` recorded in meta. Runs at
   the same time as 1.
3. `token-budgets`: the over-budget check in the watcher, interrupting the
   worker, `sheepr-send.sh --budget`, terse wakes. Starts after 1 lands.
