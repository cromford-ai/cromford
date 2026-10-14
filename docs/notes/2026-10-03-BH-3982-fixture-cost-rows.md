# The cron cost-rows mirror drops rows from projects that are not in the fleet (BH-3982, slice BH-4004)

Doc: COST

## Why

Prod D1 `cost_rows` holds 274 rows whose project is a test fixture name. All
of them came from `pool-cromford-*` boxes:

| project | rows | boxes | newest ts |
|---|---|---|---|
| `lproj` | 194 | `pool-cromford-*` | |
| `gateproj` | 77 | `pool-cromford-*` | |
| `freeproj` | 2 | `pool-cromford-*` | |
| `otherproj` | 1 | `pool-cromford-*` | |
| all four | 274 | `pool-cromford-*` | 2026-09-28T22:33:33Z |

The newest row predates the BH-3223 merge (suites stopped POSTing cost rows),
and nothing has leaked since. So this is a backstop, not the fix for a leak
that is still going on. BH-3223 only knew the name `testproj`; this guard
knows the fleet instead.

## What changed

- `cost_row_allowed_projects` (`bin/lib/cost-row.sh`) prints
  `bin/fleet-conf.sh --projects`, then the words of
  `${COST_ROWS_LANE_PROJECTS:-fleet alert-triage responder medic rule-miner greenfield trap-eval}`,
  one per line. Lane-named rows (`fleet`, `medic`, …) are real spend that is
  not filed under a fleet project.
- `_metric_cost_rows_chunk` (`bin/lib/jobs/cost.sh`): when `COST_ROWS_ALLOW`
  is set, a row whose project is not one of its words is skipped like a
  `testproj` row. The cursor still moves past it, and its project is appended
  to `$COST_ROWS_DROP_LOG`. With `COST_ROWS_ALLOW` unset nothing is filtered.
  The match is exact and case-sensitive: `Cromford` is dropped.
- `bin/cost-rows-push.sh`, **cron mode only** (`cost-rows-push.sh <box>`):
  after the lane gate and `lane_env_apply`, it builds `COST_ROWS_ALLOW`, makes a
  per-run temp drop log (removed on exit), and after the push writes one line
  to `logs/cost-rows-push.log` when anything was dropped:
  `… [<box>] dropped 4 row(s) whose project is not in fleet.conf or COST_ROWS_LANE_PROJECTS (freeproj gateproj lproj otherproj) — BH-3982`.
  Up to five distinct names, sorted. No line when nothing was dropped.
  `--box` (pool machines and the reap) and `--verify` use the same list since
  BH-4007; see [2026-10-03-BH-4007-cost-rows-allowlist-all-modes.md](2026-10-03-BH-4007-cost-rows-allowlist-all-modes.md).

## Fail-open

No `bin/lib/cost-row.sh`, no `bin/fleet-conf.sh`, or a fleet.conf that lists
no project (missing, empty, unreadable) gives an empty list, and an empty list
filters nothing. A broken registry must never cost a real row.

## Edge cases

- **A new project before its fleet.conf line lands:** its rows are dropped from
  the DB mirror only. `cost.csv` keeps them and the drop line names the
  project.
- **Empty `project` field:** not on the list, so it is dropped and counted (it
  shows up as an empty name in the line).
- **A failed push:** the line is still written. Rows dropped in a chunk whose
  POST failed are seen again on the next tick, because the cursor did not move
  past them, so the same drops can be counted on two ticks in a row.

## Recovery for a real row dropped by mistake

Add the project to fleet.conf, or the lane name to `COST_ROWS_LANE_PROJECTS`
(a `lane.cost-rows-push` settings row or `env/global.env`), then on that box:

    echo 0 > /root/harness/state/cost-rows-push.cursor

The next tick re-offers the whole of `cost.csv`. The `(box, row_hash)` PK makes
every row already in the DB a no-op.

## Cleanup of the 274 rows — HUMAN STEP, never run by a build (iron guardrail 2)

Not applied yet. Run each statement with
`wrangler d1 execute <jobs db> --remote --command "…"`:

1. `SELECT project, box, COUNT(*), MAX(ts) FROM cost_rows WHERE project IN ('lproj','gateproj','freeproj','otherproj') GROUP BY project, box;`
   Expect 274 rows in total, every box `pool-cromford-…`.
2. `SELECT COUNT(*) FROM cost_rows WHERE project IN ('lproj','gateproj','freeproj','otherproj') AND box NOT LIKE 'pool-cromford-%';`
   Expect 0. If it is not 0, stop: one of these names is real somewhere.
3. `DELETE FROM cost_rows WHERE project IN ('lproj','gateproj','freeproj','otherproj') AND box LIKE 'pool-cromford-%';`
4. Re-run step 1 and expect no rows.

## Pinned by

`tests/cost-rows-push-allowlist.bh-4004-test.sh` drives the real
`bin/cost-rows-push.sh <box>` against a loopback worker.
