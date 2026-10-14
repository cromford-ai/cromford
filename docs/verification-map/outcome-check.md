# Perf PR outcome check (BH-6382, BH-6372)

**What it is:** `bin/outcome-check.sh`, a hub lane at `*/30 * * * *`
(`cron/lanes/730-outcome-check.cron`, registry
`catalog/lanes.d/outcome-check.json`). It reads the merge ledger (kind
`merge`) for the last `OUTCOME_CHECK_LOOKBACK_H` hours (48). A merged PR is a
perf PR when `pt_classify_issue` says so for its linked issue, or `pt_classify`
says so for the PR's own text when it links no issue (`bin/lib/perf-ticket.sh`).
Its target is the PR body line `Target metric: <id> from <a> to <b>`.

At merge + `OUTCOME_CHECK_DELAY_H` (6 h, on GitHub's `merged_at`) the lane runs
`om_<id>` from `bin/lib/outcome-metrics.d/<id>.sh` over `[merged_at, now]`.
Moved = the measured value is strictly closer to `<b>` than `<a>` is. Not moved
= ONE issue on the PR's repo, title `outcome-check: <repo>#<pr> did not move
<id> toward its target`, no labels, body with the marker
`<!-- outcome-check: <repo>#<pr> -->`, the PR url and the numbers.

## State

One `ledgers` row per PR: kind `outcome-check`, key = the PR url, detail
`<id> from <a> to <b> measured <m> n=<k>[ issue=<i>]`.

| status | means | retried |
|---|---|---|
| `filed` | the issue exists; `issue=<n>` in the detail | no |
| `moved` | the metric moved toward the target | no |
| `insufficient` | fewer than `OUTCOME_CHECK_MIN_SAMPLES` (5) samples at merge + `OUTCOME_CHECK_MAX_WAIT_H` (24 h); one ALERTS line | no |
| `unmeasurable` | no measurer file for the id; one ALERTS line | no |
| `unparseable` | a `Target metric:` line that does not parse; one ALERTS line | no |
| `no-direction` | `<a>` equals `<b>` | no |
| `no-target` | a perf PR with no target line; no alert | no |
| `not-perf` | the classifier says no | no |
| `wait` | too few samples so far | yes |
| `file-failed` | the marker search or the POST failed | yes |
| `filing` | the POST may have happened; the next tick searches the marker first | yes |

## Measurers

`bin/lib/outcome-metrics.d/<id>.sh` defines `om_<id with - as _> <since>
<until>` and prints `<number|-> <int>` (the value and the sample count). Today:
`mq-full-share`, the share of merge-queue CI runs (`mergify/merge-queue/*`)
whose ci-plan mode was `full`, read from `GET /api/ci-batches`
(`bin/ci-batch-ledger.sh` fills it). `full-legacy` rows are not counted.

## How to verify

1. On the hub, run `bin/outcome-check.sh --dry-run`. It prints each would-be
   line with ` (dry run)` and a summary
   `seen=… candidates=… decided=… filed=… waiting=… skipped=… deferred=…`.
   It writes no row, makes no search and no POST, and writes no ALERTS line.
2. Read `logs/outcome-check.log` for the real ticks.
3. Read the rows: `job_ledger_list outcome-check` (`bin/jobs-client.sh`).
4. Turn the lane off with `bin/harness-ctl.sh off outcome-check`.

Tests: `tests/outcome-check.bh-6372-test.sh`.
