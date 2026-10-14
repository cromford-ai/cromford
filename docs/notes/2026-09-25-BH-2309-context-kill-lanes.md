# The context kill is armed on the build, preplan, lead-review, post-merge QA and product lanes

Doc: CONTEXT-COMPOSITION

Until now three lanes carried `context_kill_tokens`: alert-triage, responder and rule-miner.
Every other lane was unbounded, and the per-call `--max-budget-usd` cap it fell back on is
recorded INERT on subscription accounts. BH-2309 adds the key to fifteen more lanes in
`catalog/context-budgets.json`:

| lane | stage | kill |
|---|---|---|
| build-plan | plan | 6,600,000 |
| build-execute | execute | 40,500,000 |
| build-review | review | 4,900,000 |
| build-fix | fix | 20,600,000 |
| preplan | preplan | 8,300,000 |
| preplan-files | preplan-files | 100,000 |
| preplan-map | map | 2,700,000 |
| lead-review | lead-review | 4,900,000 |
| postmerge-prodqa | prodqa | 6,200,000 |
| product-prd | prd | 3,300,000 |
| product-mockup | mockup | 4,700,000 |
| product-revise | revise | 3,300,000 |
| product-signals | signals | 5,800,000 |
| product-synth | synth | 4,700,000 |
| product-ideation | ideate | 5,200,000 |

**How the numbers were set.** The source is `GET /api/metrics/cost-rows?stage=<s>&since=2026-09-11&limit=2000`,
pulled 2026-09-25. It counts claude rows with `input_toks + cache_read > 0`, the kill's own unit.
The endpoint returns the newest 2000 rows, so the window for busy stages is shorter than 14 days.
Each lane's `context_kill_basis` records its real window and row count.

- 30 or more rows: base = the stage's p95.
- 1 to 29 rows: base = the larger of their max and the lane's `measured.per_call_max`.
- No rows: the number of a named analog lane (lead-review uses build-review, product-revise uses product-prd).
- kill = max(ceil(1.5 x base / 100,000) x 100,000, 2 x `ceiling_tokens`).

1.5 x p95 lands near the observed p99. The typical session finishes and the runaway tail is stopped.

**The cost row says why.** `ac_cost_row_write` in `bin/agent-call.sh` adds
`context-kill:ceiling=<cap>:total=<n>` to the row's `note` when the claude attempt left
`$OUT.ctxkill`. It adds `cliff-avoided:ceiling=<cap>:total=<n>` instead when the price cliff
lowered the ceiling. The token is read from the marker file only, so a timeout or an outside
TERM (rc 143 with no marker) is never labelled a kill.

**Not changed.** Only claude calls are metered. codex, grok, openrouter and fireworks rungs on
these stages are unbounded as before. The escape hatches are unchanged: `flags/context-kill-off`,
`CONTEXT_KILL=0` and a per-call `CONTEXT_KILL_TOKENS`. The numbers are operator knobs: edit the
manifest, no deploy. Each new bounds entry says PENDING until the first live `CONTEXT KILL` line
for its stage.

Proof: `tests/context-kill-lanes.bh-2309-test.sh`.
