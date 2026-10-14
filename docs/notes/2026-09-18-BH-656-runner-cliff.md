# The grok lane stops paying the 200K doubling

Doc: COST

**What changed.** A per-runner PRICE CLIFF is now declared beside the rate in
`catalog/model-prices.json` (`cliff_tokens`: 200000 on `grok-4.6` and
`x-ai/grok-4.6`, absent everywhere else), and three things read it:

- **Warn.** After a grok call, `bin/agent-call.sh` reads the session's per-call
  series from the grok ledger (`bin/grok-usage.sh --calls`, a new mode on the
  one existing grok reader) and appends ONE line to `logs/<project>.log` naming
  the first call whose context crossed the cliff and what that call's context
  was. The records are cumulative, so a call's context is the delta between
  consecutive records.
- **Route.** Before a grok call is issued — on either grok rung, the primary
  runner or tier-2 — the lane's projected context is compared to the cliff.
  Past it the call is NOT MADE: one `failovers.log` line, a marker as the first
  line of `$OUT`, rc 79, no cost row, and the ladder descends exactly as it does
  when grok fails. The projection is the median of the last 10 successful
  `logs/cost.csv` rows for the same stage+project in `input_toks + cache_read`;
  fewer than 3 such rows means no projection and nothing routes.
- **Price.** `cost_price_tokens` (`bin/lib/cost-row.sh`) and `row_cost`
  (`bin/cost-rollup.sh`) multiply a row by 2 when its model has a cliff and
  `input_toks + cache_read` exceeds it. A vendor-reported `cost_usd` is
  authoritative and is never re-doubled.

`logs/cost.csv` gained a 24th trailing column, `note`, carrying
`cliff-routed:grok:<projected>><cliff>` on the row the SERVING rung wrote after a
route, and empty on every other row.

**Why.** xAI bills the whole request at 2x once it exceeds 200,000 tokens.
BH-653 measured the hub's `alert-triage` lane at a 676K median context over
1,087 calls in 68h — so the majority of that lane's grok calls have been billed
double, priced flat in every cost view here, with nothing anywhere saying the
cliff had been crossed. A runner with no cliff at that size is simply cheaper
than a doubled grok, which makes the descent a saving rather than a degradation.

**What it touches.**

- `catalog/model-prices.json` — `cliff_tokens` on the two grok keys. No code
  constant: adding or removing a cliff is an edit to this file.
- `bin/update-model-prices.sh` — CARRIES `cliff_tokens` from the committed
  catalog into `state/model-prices.json`. OpenRouter publishes rates, not
  cliffs, and every reader prefers the live table, so without the carry the hub
  would lose the cliff at 04:30 every morning. `$FALLBACK` is now resolved above
  the fetch because it is an input as well as the comparison target.
- `catalog/context-budgets.json` — `cliff_route: true` on the `alert-triage`
  lane, and no other. Resolved through the same specificity ladder
  `_budget_for` and `_ctx_kill_ceiling` use.
- `bin/agent-call.sh` — the `# >>> cliff_route` block (`cliff_route_enabled`,
  `cliff_projected_context`, `cliff_routed_rc`), the skip and warn blocks in the
  `grok)` branch, `note` on the row, and the ladder's reading of rc 79.
- `bin/cost-rollup.sh` — the doubling in `row_cost`, and `note` on the
  fleet-cost.csv header.

**Two things worth knowing before you read a number.**

- **rc 79 now has two meanings.** `agent_argv_refuse` (the prompt does not fit
  in argv) and a cliff route both answer 79. The first line of `$OUT` tells them
  apart: `PROMPT_TOO_LARGE …` vs `AGENT_CALL_CLIFF_ROUTED …`. `ladder_classify`
  maps the route to a new class, `routed/cliff` — no retry, no account cooldown,
  descend a rung.
- **A cliff-routed descent does not page.** No vendor failed, so the tier-3 and
  tier-3b gates log one `failovers.log` line instead of beating `fleet_alert`
  and writing to `ALERTS.log`. Otherwise alert-triage would triage its own
  routing every tick. A survival lane that then FAILS alerts exactly as before,
  and a route with nothing below it at all writes one `STUCK` line naming
  `RUNNER_<STAGE>_FALLBACK` and the kill switch — never `DEAD`, because nothing
  ran.

**Knobs.** `RUNNER_CLIFF_ROUTE=1` forces routing on, `0` (or any other non-empty
value — garbage is OFF, never on) forces it off, unset reads the manifest.
`flags/cliff-route-off` beats the env in every form. `CLIFF_ROUTE_SCAN` (4000),
`CLIFF_ROUTE_SAMPLE` (10) and `CLIFF_ROUTE_MIN_SAMPLES` (3) bound and shape the
projection.

**Where it is verified.** `tests/runner-cliff.bh-656-test.sh` drives
`bin/agent-call.sh` itself against a scratch `$HARNESS` and asserts on artifacts.
The operator-facing version, including what the lines look like on a live box, is
`docs/verification-map/runner-cliff.md`.

**Known limits, stated rather than solved.** Row pricing is per row while the
cliff is per request, so a session-sized row over 200K may hold no single request
over it (this is what the ticket's acceptance test asks for, and it errs in the
direction `runner_ceilings_note` already documents). The warn inherits
`bin/grok-usage.sh`'s attribution limit under concurrency. `bin/jobs-client.sh`
pushes a fixed list of 23 column names, so `note` is not mirrored into the
coordination DB.
