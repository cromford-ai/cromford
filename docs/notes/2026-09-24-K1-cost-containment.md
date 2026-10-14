# K1: the cost breakers brake, see zero-merge spend, count unpriced rows, and read the whole fleet

Doc: COST

## What changed

- **The autohalt is on by default.** `bin/pipeline-health.sh`'s cost block
  used to pause a project only where `flags/cost-autohalt-optin` existed, and
  no box had it. It now pauses at `COST_AUTOHALT_MULTIPLE` × a project's `$/PR`
  budget with no opt-in. Kill switches: `flags/cost-autohalt-off`, or the
  settings row `lane.pipeline-health.cost_autohalt = 0`. Resume is the console's
  `resume_board` or `flag_set paused-<p> off` (deleting the file does not
  resume: flag_sync re-creates it). A re-arm window
  (`COST_AUTOHALT_REARM_S`, default 24h) keeps a resumed project resumed.
- **A zero-merge breaker.** A `fleet.conf` project with ≥ `COST_ZM_7D_USD`
  ($400) delivery spend over 7d and fewer than `COST_ZM_MIN_MERGES` (1) merged
  in 7d is paused and paged critical. ≥ `COST_ZM_24H_USD` ($300) over 24h with
  none merged today pauses only if 7d merges are also under the minimum —
  otherwise it is a merge stop and is paged, not paused. Merges are counted by
  merge date (`bin/cost-rollup.sh` 7d `created:>=` → `merged:>=`). After a halt
  only post-halt windows are judged; an already-paused project is left alone.
  Every threshold takes a per-project settings row (`lane.pipeline-health.<p>.…`).
- **Unpriced rows count against the fleet ceiling**, priced pessimistically
  (model rate, else the table's top rate, else `COST_UNPRICED_ROW_USD` = $2 for
  a call with no usage; subscription rows add nothing). One runner writing more than
  `COST_UNPRICED_RUNNER_HOUR_MAX` (60) unpriced rows in an hour pages critical, once a day.
- **The ceiling reads the topology**: the `cost_rows` table first, else this
  box plus every `fleet.conf --tailnet-ips` box. The hardcoded six-box list
  (no project-6, no project-9) is gone.
- **`bin/lib/page-critical.sh`**: the money breakers page on a deterministic
  path — an ALERTS line, a `"triaged":true` critical beat (never quarantined
  for the LLM triage lane), a direct Telegram DM if the console refuses it.

## Why

The 2026-09-24 runaway / silent-stop analysis: project-9 spent $643 over 7d
with 0 merged PRs and showed up only in a once-a-day "could not evaluate" line;
the autohalt that existed could not fire; the $4,000/day ceiling could not see
rows the ledger failed to price or boxes its list did not name. the operator's rule: no
per-ticket dollar budgets — anomaly tripwires and lane/fleet rate breakers.

## Owed proof

Built and driven in a scratch tree (`tests/cost-containment.k1-test.sh`,
`tests/page-critical.k1-test.sh`). Not yet observed live: after the merge
syncs to the hub, the first zero-merge or ceiling page should arrive as a
`CRITICAL [pipeline-health]` ALERTS line and a triaged console row, and
`state/costhalt/` should hold a stamp for any project it paused.
