# BH-9897: conductor rows of merged PRs settle from every live state

## Cause

On bh-hub-2, 2026-11-22 16:55Z, 962 of 1,133 live rows in
`state/merge-conductor/pr-state.tsv` belonged to PRs that were merged (937) or
closed (25). `mc_settle_offlist_rows` (`bin/lib/mc/settle.sh`, BH-8310) read
only READY and WAIT_CI rows. A PR that merged while its row was in another
state kept that state. `mc_classify` never runs on an off-list PR, so no other
writer moved the row. The "mergeState unknown, keeping prior state" reason on 7
project-3 NEEDS_HUMAN_VERDICT rows was only the last reason from when the PR was open.

## Change

- `mc_settle_offlist_rows` builds its candidate set from `MC_STATES` minus
  MERGED, CLOSED, ABANDONED and QUEUED. The queue settle still owns QUEUED.
  The move stays row-only: no `conductor_settle`, no issue close, no deploy
  request.
- `mc_classify` keeps the prior state on an unknown mergeState only when the
  pstate is OPEN. Any other pstate answers WAIT_CI with the reason "PR not on
  the open list — the off-list settle owns this row".
- `bin/mc-stale-rows-sweep.sh` calls the same settle, so it reads the same list.
- `bin/pipeline-health.sh` block `merged rows live`: it counts live rows with a
  `merged` memo (`mc_merged_live_count`, `bin/lib/mc-merged-live.sh`). If the
  count stays above 0 for `PH_MC_MERGED_LIVE_ALERT_MIN` minutes (settings row,
  default 60), it sends one `mcmergedlive:fleet` alert per
  `PH_MC_MERGED_LIVE_ALERT_TTL_S` (default 86400).
- The blocked-resolver fragment `bin/blocked-resolver.d/bh-9897-merged-memo-skip.sh`
  skips a conductor row whose PR memo is `merged`. `BR_OPT_OFF=bh-9897-merged-memo-skip`
  turns it off.

## The `closed` memo rule, per state

One rule for every candidate state: a `closed` memo whose epoch is at or after
the row's `since` moves the row to CLOSED. An older memo moves nothing (the PR
can be open again). A `gone` memo moves nothing in any state.

| state | closed memo, epoch >= since | epoch < since |
|---|---|---|
| WAIT_CI, READY | CLOSED | skip |
| WAIT_REVIEW, HEAD_MOVED, NEEDS_REBASE | CLOSED | skip |
| REBASING | CLOSED | skip (a held PR lock in the tick skips the row) |
| BLOCKED_HUMAN, RED_TWICE | CLOSED | skip |
| NEEDS_HUMAN_VERDICT, WAIT_LEAD, WAIT_MIGRATION, STACKED_WAIT | CLOSED | skip |
| QUEUED | not a candidate | not a candidate |
| MERGED, CLOSED, ABANDONED | terminal | terminal |

`closed_unmerged_rows` already moves a harness PR's row to CLOSED from any
state, so this rule agrees with it.

## Operator step (after merge)

1. On the hub, run `bin/mc-stale-rows-sweep.sh` (dry run).
2. Compare its totals line with the table in the ticket (962 rows, 937 merged,
   25 closed on 2026-11-22; the count can be lower if the conductor ticks ran).
3. Run `bin/mc-stale-rows-sweep.sh --apply`.

The sweep makes 0 GitHub calls and writes one `STALE-ROW` line per row to
`logs/merge-conductor.log`.
