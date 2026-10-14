# A Fly infra cost row at the live-machine reap (BH-4019, child 2 of #3989)

Doc: COST

## What changed

When `bin/fly-pool.sh` pulls a RESULT off a pool machine that is still running,
it now writes one infra row for that job into the build dir's `cost.csv`, right
before `push_pool_cost_rows` pushes that file. So the row reaches `cost_rows`
under the machine's own box id, `pool-<project>-<mid>`, the same as the LLM rows
the machine wrote itself.

The writer is `fly_cost_row_once` in `bin/lib/fly-cost-row.sh`. The pool's
wrapper is `pool_fly_cost_row`, and it is called at one place only.

The row:

- start is the machine json's `spawned_at`, and end is the reap tick, so
  `duration_s` is the job's wall seconds on that machine;
- the size (`cpu_kind`, `cpus`, `memory_mb`) comes from this tick's
  `machines list` answer and never from the spawn line;
- `cost_usd` is `duration_s × fly_price_per_s`, printed `%.6f`, with prices from
  `catalog/fly-prices.json` (or the contract's fallback table; the note says
  which);
- `stage=infra`, `runner=fly`, `model=<kind>-<cpus>x-<mem>mb`,
  `billing_mode=metered`, `row_source=fly-machine`, `lane_id` empty;
- `ticket` is the key, `run_id` is the hub build dir's name, and `job_id` is the
  last non-empty `job_id` in the build's own `cost.csv`. It is empty when that
  file has none.

## Once per job

`state/fly-cost/ledger.tsv` on the hub holds one `mid<TAB>key<TAB>spawned_at`
line per row written. It is checked and appended under `flock` on
`ledger.tsv.lock`, so a re-reap of the same machine json writes nothing. A
reused machine's next job has its own `spawned_at`, so it gets its own row. The
`cost_rows` (box, row_hash) key stays as the second line of defence.

## When no row, or no price

- Size unknown (listing unusable, machine not in it): the row is written with
  an empty `cost_usd` and the note `UNPRICED:fly-size-unknown:<mid>`. It is
  never $0.
- No `spawned_at`, or an end not after the start: no row, and one
  `fly cost row: skipped:…` line in `logs/fly-pool.log`.
- The lib missing from the tree: no row and no log line. The reap is unchanged.

The pool-result-row branch (`RES_FROM_ROW=1`), the dead/stale branch, the sweep
and `bin/fly-dispatch.sh` write no row. None of them has a live machine to end
the interval on, and using "now" there would invent seconds.

## What this does to totals

These rows are `billing_mode=metered`, so `bin/cost-rollup.sh` now counts Fly
machine time in fleet totals and in cash. They do not count against the LLM
lane caps: `lane_id` is empty and no lane's signature uses `stage=infra`. The
hub's `logs/cost.csv` is never written, so the hub's 10-minute mirror does not
count them a second time.
