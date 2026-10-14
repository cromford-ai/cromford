# Every cost row is priced at write time, and a runner that floods the ledger with blank ones pages

Doc: COST

The 2026-09-17..19 spend audit counted 1,987 cost rows and about $3.5K in three
days that carried real token counts and an EMPTY `cost_usd`. They came from the
three codex-driven lanes. `run_attempt` in `bin/agent-call.sh` captures tokens
for all of them — `:1195` (codex), `:1266` (openrouter), `:1332` (fireworks)
each do `IFS='|' read -r IN OUTT CR CW <<<"${CU_LINE// /|}"` — and no line after
those reads assigns `USD`. Only the grok branch (`:1462`) called
`cost_price_tokens`, and `cost_row_source` sets `USD` for claude alone. So the
row assembly wrote `$USD` as it found it and `bin/cost-rows-push.sh` mirrored
the blank into the DB.

`bin/cost-rollup.sh` prices a blank row from its tokens, so the hub's own
rollup was right the whole time. Every reader that does NOT go through it was
wrong: the `cost_rows` table, `bin/run-build.sh`'s `COST_LINE`,
`bin/lib/builder-direct.sh`'s per-build cost, `bin/run-triage.sh`'s spend line,
and `bin/cost-reconcile.sh`. The fleet's busiest runners read as weightless.

## `cost_row_price`, in `bin/lib/cost-row.sh`

`cost_row_price <runner> <model> <rc> <in> <out> <cache_read> <cache_write> <usd> <note>`
prints `<usd>|<note>` and always returns 0. Fenced by its own markers, like the
rest of that file. Rules, in order:

1. `usd` already set → returned unchanged. A vendor's `costUsdTicks` and a
   claude transcript figure are measurements; a catalog rate is an estimate, and
   an estimate never overwrites a measurement.
2. any of in/out/cache_read/cache_write present → `cost_price_tokens`. A price
   is the answer. No price (no table, or no row for this model) leaves `cost_usd`
   EMPTY and adds `UNPRICED:no-price:<model>` to the note.
3. no counts and `rc = 0` → `UNPRICED:no-usage`. Same gate `cost_parity_alert`
   pages on: the call was billed and reported nothing.
4. no counts and `rc != 0` → nothing changes. It was never billed.

Empty is never `0`, the same contract `cost_price_tokens` states: a zero reads
as "this call was free" and makes the rollup skip a row it would otherwise
price. The markers join an existing note with `;`, so `cliff-routed:grok:…`
(BH-656) survives on the same row.

The runner argument is in the signature for symmetry with `cost_parity_alert`
and is deliberately not read — what a call costs is a fact about the model and
the counts.

## The call site, in `bin/agent-call.sh`

One line before the `ROW=` assembly, after `AUTH_ACCT` and `_RUNID` resolve:

    _PN=$(cost_row_price "$runner" "$rmodel" "$RC" "$IN" "$OUTT" "$CR" "$CW" "$USD" "${CLIFF_ROUTE_NOTE:-}")
    USD="${_PN%%|*}"; _ROW_NOTE="${_PN#*|}"

and the row's last field is `$(cost_csv_field "$_ROW_NOTE")` instead of the
cliff note directly. Beside the other stale-library stubs there is now an
IDENTITY stub for `cost_row_price`, so a box whose `bin/lib` sync has not landed
writes exactly the row it writes today.

Nothing else moved. The grok branch keeps its own `cost_price_tokens` call (rule
1 makes it redundant, not conflicting), `cost_parity_alert` still pages on the
first rc-0/no-usage call, the build-dir `cost.csv` tee and `$PROV` are
unchanged, and the budget-inert check reads `$USD` earlier in the function so
its decision cannot move.

**A subscription codex row now carries a NOTIONAL retail figure.** That is what
this column has always meant (`bin/cost-rollup.sh:433`: "row_cost() is
NOTIONAL"), and `cash_of()` zeroes `billing_mode=subscription`, so no cash view
changes. What does change: `run-build.sh`'s "AI cost to PR" line,
`builder-direct.sh`'s per-build `cost_usd`, `PHASE_USD` and the job row's
`spend_delta` show a retail figure where they showed nothing. That is the
ticket's point.

## The blank-cost flood alert, in `bin/cost-reconcile.sh`

The pricer only helps a box that has synced it, and only for a model
`catalog/model-prices.json` carries. Both failures look the same from the hub,
so the hourly run counts them: rc=0 rows with a blank `cost_usd`, per runner,
over the window, read from the same `/api/metrics/cost-rows` pages the script
already walks and deduped on `(box, row_hash)` the same way. More than
`RECONCILE_BLANK_ROWS_MAX` (default 20, env, template-documented) from one
runner is ONE line through `bin/lane-alert.sh`, deduped by
`flags/alerted-cost-blank-<runner>-<YYYYMMDD>`. The line names the runner, the
count, the model most of the flood ran on, and both things to check.

- **`--window 1h` only.** The ticket's threshold is per hour; the 04:50 24h run
  would read a day's total as one hour's flood.
- **`clean` is only written after a successful read.** `fetch_rows` now sets
  `FETCH_OK` and `FETCH_CAPPED`; a fetch that did not complete logs
  `blank-cost 1h unread` and alerts nothing, and a walk stopped by
  `RECONCILE_MAX_PAGES` appends `pages=<n> capped` because the count is then a
  floor.
- **Log first, page, then flag** — a crash between the page and the flag costs a
  duplicate line tomorrow, never a lost page. Same order `cost_parity_alert`
  uses.
- **Kill:** `RECONCILE=0`, `flags/cost-reconcile-off` (the whole script), or
  `RECONCILE_BLANK_ROWS_MAX=0` (just this pass).
- Not pushed to `/api/metrics/reconcile`: that table is per-account meter rows
  and a per-runner count is a different shape. The log line and the ALERTS line
  are the record.

## Deliberately not in this ticket

The audit's other two remedies — the promptsha+stage+project choke-point guard
and the per-stage claude-only intent — belong to #1037, and so does the open
question of whether `RUNNER_*_FALLBACK=openrouter` with an `anthropic/` slug
should be opt-in per stage. Changing fleet routing inside a pricing ticket is
the larger, harder-to-reverse reading. The `note` column still does not exist in
the worker's `cost_rows` table (BH-656 shipped it CSV-only); the markers are
readable in `logs/cost.csv` and not yet queryable fleet-wide.

## How it is proven

    HARNESS_TEST_SANDBOX=1 bash tests/cost-row-priced-test.sh
    HARNESS_TEST_SANDBOX=1 bash tests/cost-reconcile.bh-1020-test.sh

The first extracts `cost_row_price` by its markers and runs it (A1–A8), then
drives `bin/agent-call.sh` itself with a fake codex CLI writing the REAL
captured session shape: an openrouter call reporting 44450/18 tokens lands
`cost_usd = 0.445400`, the same call with no ledger lands blank with
`UNPRICED:no-usage` and exactly one `[cost-parity]` line, and the grok branch
still answers `0.285000`. B4 is the mutation guard: the same drive against a
copy of `bin/lib/cost-row.sh` with the fence cut out lands the row blank, which
is what proves B1 is not asserting something that already worked.

The second drives `bin/cost-reconcile.sh` against a stubbed API: 21 blank
openrouter rows page and 20 do not, rc=1 rows and priced rows never count, the
24h window never runs the pass, the second run of the day is silent, the knob
raises and lowers the threshold, and a 404 from the rows endpoint logs `unread`
rather than `clean`.

No live row has been priced by this yet — the read-backs that would prove it on
a box are in `docs/COST.md` § Owed proof.
