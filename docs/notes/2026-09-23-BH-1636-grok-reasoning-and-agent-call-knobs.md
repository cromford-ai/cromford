# grok output tokens include reasoning, and agent-call.sh's knobs are settings rows

Doc: COST, OPERATOR-SETUP

## Why

BH-1636 collected the follow-ups from the BH-1494 review (#1552). Two of them
can ship now and be proved in CI:

- **Item 3.** The one measured grok 1.0.40 envelope says `output_tokens 1`
  beside `reasoning_tokens 412`. One token cannot contain 412, so grok counts
  reasoning separately, and a cost row with `output_toks=1` under-reported what
  the call generated.
- **Item 2.** `GROK_OUTPUT_JSON` was an env var, so the flip BH-1494 set up
  (turn the envelope read on once a probe confirms `.result`) meant editing
  `env/global.env` on every box.

## What changed

**`bin/grok-usage.sh` adds a sibling reasoning count to output.** A
`reasoning_tokens`/`reasoningTokens` key in the SAME dict as the output key is
added to it, on both the envelope path and the ledger walk. It is never taken
from a nested `*_details` dict (OpenAI's output already includes that), codex's
`reasoning_output_tokens` is not read, a negative or non-numeric value is
ignored, and reasoning alone never makes a dict a usage record. Envelope dollars
still come from the vendor's `total_cost_usd`. A row priced from tokens
(`cost_price_tokens`) now prices the reasoning too. If a later grok folds
reasoning into `output_tokens`, this double counts; a real 1.0.x capture (item
1b) is what would show it.

**`bin/agent-call.sh`'s operator knobs are registered as the `agent-call` lib**
in `catalog/lanes.d/_lib.json`, keyed `lib.agent-call.<env lowercased>`, and
agent-call.sh calls `lib_env_apply agent-call` right after it sources
`bin/lib/llm-gate.sh`. The 11 knobs: `GROK_OUTPUT_JSON`, `GROK_MAX_TURNS`,
`GROK_RULES_INJECT`, `LADDER_TIER2_GROK`, `LADDER_SAME_RETRIES`,
`LADDER_BACKOFF_SECS`, `CLIFF_ROUTE_SAMPLE`, `CLIFF_ROUTE_MIN_SAMPLES`,
`CONTEXT_KILL_POLL_S`, `COST_SOURCE_DELTA_PCT`, `AGENT_CALL_LEDGER_TTL_S`. None
is `required`, so with no row nothing is exported and the call is what it was.
`LANE_GATE_DISABLE=1` skips the apply. Left out on purpose: secrets, paths,
model slugs (they go through `model_routes`), `GROK_BILLING`, per-call
context a calling lane sets, because a row outranks the env and would override
every caller, and the three cooldowns (`MODEL_COOLDOWN_SECS`,
`ACCOUNT_COOLDOWN_SECS`, `ACCOUNT_OVERAGE_COOLDOWN_SECS`). Those are read
against the same stamps by `bin/orchestrate.sh`, `bin/quota-poll.sh`,
`bin/quota-status.sh` and `bin/lib/pool-account.sh`, none of which applies the
`agent-call` lib, so a row would split the box's view of one cooldown. They
need a shared lib every reader applies; that is another ticket.

The grok envelope flip is now one row: `lib.agent-call.grok_output_json = 1`
(PUT /api/settings).

## Still owed (not in this change)

- Item 1a: the probe on a grok 1.0.40 box that confirms `.result` carries the
  answer text.
- Item 1b: a real `~/.grok/logs/unified.jsonl` and envelope capture, turning
  `tests/cost-grok-usage.bh-1494-test.sh` §A8's TODO into an assertion.
- Item 1c: writing the row `lib.agent-call.grok_output_json = 1`, after 1a.
- Item 4: the per-box grok requirement, decided after the first post-merge
  `bin/cli-version-check.sh` run (2026-09-24 05:40Z).
- The Mission Control lanes page shows no `libs` knobs yet (none of the six
  libs), so these rows are set through the API, not the page.

## Tests

`tests/cost-grok-usage.bh-1636-test.sh`, `tests/agent-call-knobs.bh-1636-test.sh`,
and `tests/cost-grok-usage.bh-1494-test.sh` A1/A2/D1 now pin output 413.
