# Cost readers read D1 only; no box is reached over ssh

Doc: COST

## What was wrong

Five hub cost readers still reached across the tailnet for facts the harness-jobs
D1 database already holds. `bin/cost-rollup.sh` had four ssh calls: a tar of each
box's `builds/*/{cost.csv,RESULT}`, a per-box `logs/cost.csv` fallback when
`cost_rows` was unreadable, each box's `logs/extra-usage.csv` and its
`state/extra-usage-unavailable`. The fleet ceiling in `bin/pipeline-health.sh`
(section B) ssh-tailed 1500 lines per `fleet.conf` box when `cost_rows` failed.
`bin/cap-loss-detector.sh` scp'd `failovers.log` and `cost.csv` from three
hardcoded boxes. `bin/cost-report.sh` and `bin/cost-readout.sh` scp/ssh'd every
box's `cost.csv`. A box that could not be reached read as a box that spent nothing.

## What changed

- **Rollup.** Fleet rows come from `cost_rows` only. When the table cannot be read,
  or the read is disarmed (`COST_ROWS_FROM_DB=0`, `flags/cost-rows-from-db-off`),
  the run writes one ALERTS line a day (`flags/alerted-cost-rollup-db-unreadable-YYYYMMDD`)
  and exits before it rewrites anything under `state/cost/`. The last good
  `summary.json`, `fleet-cost.csv` and `cost-per-pr.csv` stay as they were.
- **Per-PR attribution.** Hub build dirs still bill from their own `cost.csv`, bound
  by the ledger and then their RESULT. Other boxes' builds are the `fleet-cost.csv`
  rows grouped by `run_id` (pool-/fly- prefix stripped). They are bound through the
  ledger only, so a remote build the ledger does not name is not attributed. A
  `run_id` that is a hub dir is skipped there, so it is never counted twice.
  `state/cost/remote-builds/` is no longer written.
- **Account meters (1b).** New `bin/lib/extra-usage-read.sh`:
  `extra_usage_fetch <label> <out>` reads `GET /api/metrics/extra-usage` into the
  tracker's CSV shape, oldest first. `extra_usage_label_for_box <box>` picks the
  `catalog/cost-accounts.json` account whose login is that box's `/root/.claude`,
  and falls back to the box id. When the read fails, `overage/<box>.why` says
  "extra_usage_snapshots unreadable". When the newest poll's status is not `ok`, it
  says "latest poll status=<status> at <ts>".
- **Fleet ceiling.** With `cost_rows` unreadable the brake sums this box's
  `logs/cost.csv` only. The page's source reads `LOCAL ONLY — cost_rows unreadable,
  other boxes' spend is NOT in this total`, and one ALERTS line a day
  (`flags/alerted-costceiling-blind-YYYYMMDD`) says the brake is partial.
- **Cap-loss.** The day's `cost_rows` rows are grouped by `host`. A failover is a
  claude row with `rc` not 0. Deferred time is the summed `duration_s` of non-claude
  rows. If the table is unreadable, the log line reads
  `cost_rows unreadable — cap-loss NOT measured`, one ALERTS line is written, and
  there is no beat. The day is never reported as "0 failovers". `failovers.log` also
  held gate-refusal lines containing "claude", and those are no longer counted.
- **Reports.** `cost-report.sh` and `cost-readout.sh` read their window from
  `cost_rows`, grouped by host. An unreadable table exits 75 with no beat and no LLM
  call, and the cron line stays.
- The three scripts that pinned `HARNESS=/root/harness` now honour `$HARNESS`, so
  they can be driven in a scratch tree.

`tests/cost-readers-no-ssh.bh-2527-test.sh` is the ratchet. It fails on any
command-position `ssh`/`scp`/`rsync` in `bin/cost-*.sh`, `bin/cap-loss-detector.sh`
or pipeline-health section B, and it drives every reader above with stubs that
record any remote call.

## Still true / not changed

`docs/COST.md`'s K1 table row that says the ceiling falls back to "this box's ledger
plus every distinct box in `fleet.conf --tailnet-ips`" is superseded by this note.
The fallback is now this box's ledger only, labelled LOCAL ONLY.
