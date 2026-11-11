# Resolver retires parks of closed PRs, offers fresh parks before stale OVERDUE rows, and gives a one-PR run its own lock (BH-9369, slice C0)

Doc: MERGE-CONDUCTOR

## Problem

On 2026-11-09 `bin/blocked-resolver.sh` was saturated, and a fresh red PR waited hours for its first rung. This slice fixes three causes:

1. `br_prepass` retired a row only from its record (`br_finished`). It did not read the PR state. A park whose PR merged or closed somewhere else stayed on the list. project-6#289 was merged and was still OVERDUE, offered first on every tick, 38,960 min after its park.
2. `br_overdue_first` offers every overdue row oldest first. With 200 rows a week old, a park 30 min old sat behind all of them, and `BR_PER_TICK=50` did not reach it.
3. A `BR_ONLY_PR` run (the conductor's fix-now launch, BH-6000) took the project lock. While the project's sweep ran, the run logged `another tick is live` and exited. The fix round it was started for did not start.

## What changed

1. **Closed-PR retire** (`bin/blocked-resolver.d/bh-9369-closed-pr-retire.sh`). Before discovery, `bcr_load` reads the repo's closed pull list: one `gh_rest` call per page, newest update first. The read stops at the last complete read's newest `updated_at` minus 600 s, so the steady state is one call per project per tick. The answers go to `state/blocked-resolver/.closed-prs-<project>.tsv`: one watermark line, then `<n> <merged|closed> <closed_at> <retired>`. The watermark moves only after a complete read. In the pre-pass, a row whose PR url is in that set leaves the list with one `resolver_retired ... PR is <merged|closed>` line. The store row is then marked retired, and from the next tick the BH-9029 discovery skip drops the row (`retired_skipped=` on the prof line). The record is not flagged, because it belongs to the ticket and another open PR of the same ticket keeps its ladder.
   These rows are not retired: an open or reopened PR (it is in the open list); a `rebuild-*` reason (the rebuild is still owed); a closed-unmerged PR while the open list cannot be read (a merged PR still retires); another repo's url; a url that is not a PR url.
2. **Fresh first** (`bin/blocked-resolver.d/bh-7555-overdue-first.sh`). Sometimes one overdue row is `BR_STALE_OVERDUE_DAYS` old. Then the live PR rows parked less than `BR_FRESH_PARK_MIN` ago go directly after the hotfix rows. One `fresh-first:` line says how many. With no stale row, the BH-7555 order stays the same, byte for byte.
3. **One-PR lock** (driver lock block, `bin/blocked-resolver.d/bh-9369-one-pr-lock.sh`). A `BR_ONLY_PR=<owner>/<repo>#<n>` run takes `locks/blocked-resolver-<project>-pr-<n>.lock`, not the project lock. It pre-passes only its PR's rows. It does not write `.tick-budget-<project>` or `.saturation-<project>.tsv`, because a one-PR run is not a sweep tick. The sweep skips a row while that PR lock is held and logs `<p>/<key>: skip: one-PR run holds <n>`. A malformed value, or a run with no project, exits 2 and creates no lock file.

## Knobs

All four are `catalog/lanes.d/blocked-resolver.knobs.d/` rows:

| Knob | Default | 0 means |
|---|---|---|
| `BR_CLOSED_PR_MAX_PAGES` | 30 | no read, fix 1 off |
| `BR_CLOSED_PR_KEEP_DAYS` | 90 | keep every store row |
| `BR_FRESH_PARK_MIN` | 1440 | fix 5 off |
| `BR_STALE_OVERDUE_DAYS` | 7 | fix 5 off |

## Not in this slice

Fix 2 (age out records with no open PR), fix 3 (incremental discovery) and fix 4 (a per-row time cap) are left to child slices. Fix 4 needs a design decision first, because a fix round holds a row for up to 90 minutes.

## Tests

`tests/br-retire-closed.bh-9369-test.sh`, `tests/br-fresh-first.bh-9369-test.sh`, `tests/br-one-pr-lock.bh-9369-test.sh`.
