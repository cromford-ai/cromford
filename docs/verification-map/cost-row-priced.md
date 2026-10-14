# Write-time row pricing, and the blank-cost flood alert

**What it is:** `cost_row_price` in `bin/lib/cost-row.sh`, called once per
attempt from `run_attempt` in `bin/agent-call.sh` immediately before the cost row
is assembled, plus the hourly counter in `bin/cost-reconcile.sh` that pages when
one runner floods the ledger with rows nobody priced.

Before BH-1020 only the grok branch priced its own tokens. The codex, openrouter
and fireworks lanes captured token counts and wrote them beside an empty
`cost_usd`, so 1,987 rows and about $3.5K in three days read as $0.00 on every
view that does not go through `bin/cost-rollup.sh` (the DB mirror,
`run-build.sh`'s `COST_LINE`, `builder-direct.sh`'s per-build cost,
`run-triage.sh`'s spend line, `cost-reconcile.sh` itself).

| | what happens | where it lands |
|---|---|---|
| **price** | every runner's row is priced from `catalog/model-prices.json` before it is appended — unless the vendor already gave dollars, which are never overwritten | `cost_usd`, col 13 of `logs/cost.csv` |
| **mark** | a billed row that could not be priced says which kind of failure it was: `UNPRICED:no-usage` (rc 0, nothing reported) or `UNPRICED:no-price:<model>` (counts, no rate) | `note`, col 24 |
| **page** | more than `RECONCILE_BLANK_ROWS_MAX` rc=0 rows with a blank `cost_usd` from ONE runner in an hour | one line in `logs/ALERTS.log`, one per runner per UTC day |

**How an operator reaches it.** The pricer has no cron of its own: it runs on
every `bin/agent-call.sh` attempt, which is every lane in the fleet (~29 call
sites — `run-build.sh`, `run-triage.sh`, `orc-job.sh`, `alert-triage.sh`, the
review lanes, `builder-direct.sh`). The alert is the hub's hourly reconcile line:

| lane | where it runs | what it does here |
|---|---|---|
| `cost-reconcile` | `bin/cost-reconcile.sh --window 1h`, hub cron `:50` | counts blank rc=0 rows per runner and pages over the threshold |
| `cost-reconcile` | `bin/cost-reconcile.sh --window 24h`, hub cron 04:50 | does NOT run this pass — a day's total is not an hour's flood |

**Knobs:**

| knob | effect |
|---|---|
| `RECONCILE_BLANK_ROWS_MAX` (20) | strictly-greater threshold for one runner in one hour; `0` turns the pass off. Non-numeric falls back to 20 |
| `RECONCILE=0`, `flags/cost-reconcile-off` | the existing kill switches; they stop the whole script, this pass included |
| `MODEL_PRICES` | the price table, used as given and never fallen back from (see [model-prices.md](model-prices.md)) |

There is no knob that turns write-time pricing off. The only way a box writes an
unpriced row is that it has not synced `bin/lib/cost-row.sh`, and then the
identity stub in `bin/agent-call.sh` leaves it behaving exactly as it did before
this shipped — which is the state the alert exists to name.

**How it is driven (the suites that run the real code):**

```
HARNESS_TEST_SANDBOX=1 bash tests/cost-row-priced-test.sh
HARNESS_TEST_SANDBOX=1 bash tests/cost-reconcile.bh-1020-test.sh
HARNESS_TEST_SANDBOX=1 bash tests/cost-grok-usage-test.sh     # the branch this did not touch
```

The first extracts `cost_row_price` by its markers and runs it, then drives
`bin/agent-call.sh` with a fake codex CLI writing the real captured session
shape — an openrouter call reporting 44450/18 tokens must land
`cost_usd = 0.445400` — and includes a mutation guard that cuts the fence out of
a copy of the library and requires the same row to land blank. The second drives
`bin/cost-reconcile.sh` against a stubbed `/api/metrics/cost-rows`.

**What shows it working on a live box** (owed — nothing has been priced live yet,
see `docs/COST.md` § Owed proof):

- `/root/harness/logs/cost.csv` —
  `grep -E ',(openrouter|fireworks|codex),' … | tail -5`: col 13 non-empty on
  every row that carries tokens in cols 9/10.
- the same file — `awk -F, '$7=="0" && $9!="" && $13==""' … | wc -l` stops
  growing after the box syncs.
- `/root/harness/logs/cost-reconcile.log` — a `blank-cost 1h` line every hour at
  :50: `runner=<r> blank=<n> alerted=<0|1>` per runner with blanks, `clean` when
  there are none, `unread` when the rows read did not complete.
- `/root/harness/logs/ALERTS.log` — at most one `[cost-reconcile] BLANK COST`
  line per runner per day, and none on a healthy hour.
- `/root/harness/flags/alerted-cost-blank-<runner>-<YYYYMMDD>` — the daily
  dedupe; deleting it re-arms the alert for that runner today.

**Known limits, stated rather than solved:**

- **The dollars on a subscription row are NOTIONAL.** A flat-rate codex row now
  carries what the call would have cost at retail, which is what `cost_usd` has
  always meant (`bin/cost-rollup.sh:433`) and what `cash_of()` zeroes by
  `billing_mode`. Cash views do not move; lane comparison, volume and
  cost-per-PR do, which is the point.
- **The `note` column is CSV-only.** The worker's `cost_rows` table has no
  `note` column (BH-656 shipped it that way and this ticket kept it), so
  `UNPRICED:*` is readable in `logs/cost.csv` and not queryable fleet-wide.
- **The flood count is a floor at the page cap.** The rows endpoint answers at
  most `RECONCILE_PAGE_LIMIT` (2000) × `RECONCILE_MAX_PAGES` (10) rows; an hour
  past that is truncated by the existing walker and the log line says
  `pages=<n> capped` rather than implying a total.

**Where it does NOT apply:** `bin/cost-rollup.sh` prices blank rows from their
tokens itself and is unchanged — its `unpriced_calls_*` counters simply shrink
for these lanes. `bin/claude-cost.sh` writes through `cost_append` but not
through `run_attempt`, so its rows are priced by the transcript reader as before.
