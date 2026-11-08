# The disprove report line and the stop rule (BH-9238, C2 of BH-9047)

Doc: OPERATING

Slice C2 of #9047. C0 (the lead review pass) and C1 (the conductor lane) are
on main. This slice adds the report the operator reads before he sets
`review.disprove.mode` to `enforce`, and the rule that turns the pass off when
an auto-dropped BLOCK was right.

## What changed

A new hub lane, `bin/review-disprove-report.sh`, runs daily at 06:25Z
(`cron/lanes/718-review-disprove-report.cron`, lease-gated). It makes no model
call. Its pure half is `bin/lib/review-disprove-report.sh`.

### The report line

The lane reads `GET /api/review-disprove?since=<start>&limit=<review.disprove.list_max>`.
Over the last `REVIEW_DISPROVE_REPORT_WINDOW_D` days (7), per lane and in total:

- `blocks`: rows with `verdict_before = BLOCK` and `checked > 0`.
- `fully disproved k of n (p%)`: rows where every model BLOCK finding was
  DISPROVED (`findings > 0` and `disproved = findings`). A protected finding
  (`kept_protected`) does not count, because enforce would not drop it.
- The next read of each fully disproved row: the earliest `/api/verdicts` row
  on the same PR, later than the disprove row, on a different head or from
  `source = human`. `agreed false` when it clears the PR (MERGE,
  MERGE-WITH-NOTES, APPROVE) on the same head, or on a moved head whose GitHub
  compare changes no DISPROVED finding's path. `disagreed` when it is BLOCK or
  the compare changes such a path. `pending` when there is no such row.
  `unreadable` when a read failed; it is never counted as agreed. At most
  `REVIEW_DISPROVE_REPORT_MAX_READS` (40) rows are looked up per run.
- Findings totals and the summed cost.

It writes `state/review-disprove-report/latest.txt` and `<date>.json` every
run, and deletes `<date>.json` files older than `REVIEW_DISPROVE_REPORT_KEEP_D`
(84) days. It posts one triaged fleet_alert beat (akey
`review-disprove-report:<date>`) on weekday `REVIEW_DISPROVE_REPORT_DOW` (1 =
Monday), when `REVIEW_DISPROVE_REPORT_SEND` = 1 and there is at least one
BLOCK. An unreadable worker is `n/a`, never `0 of 0`, and posts nothing. The
lane never writes `review.disprove.mode`.

### The stop rule

Only when `review.disprove.mode` reads `enforce`, and only for a project whose
`dp_gate` reads `enforce`. Shadow mode (the prod seed) reads nothing from
GitHub and writes nothing.

1. A candidate is a row of the last 2 x `REVIEW_DISPROVE_STOP_WINDOW_D` days
   (14) with `mode = enforce`, verdict BLOCK -> APPROVE or MERGE-WITH-NOTES,
   and a DISPROVED finding at `<path>:<n>[-<m>]`.
2. Its PR merged after the row (`GET repos/<slug>/pulls/<pr>`).
3. A merged PR with the main-red label (`main_red_label_resolve`, BH-1770: the settings row `lib.main-red-label.mc_main_red_label`, then `MC_MAIN_RED_LABEL`, then `fix-main-red`; reverts
   carry it too) merged within `REVIEW_DISPROVE_STOP_WINDOW_D` (7) days after
   that merge.
4. One of its file hunks (old or new side) overlaps the finding's lines plus or
   minus `REVIEW_DISPROVE_STOP_SLACK_LINES` (10). A renamed file matches on its
   old name. A file with no patch in the GitHub answer counts as a touch.

Then, in this order: `review.disprove.<project>.enabled` = 0 (re-read to prove
it), a ledger row `review_disprove_stop` `<repo>#<pr>@<head12>:<fix-pr>`, and
one critical `lane-alert.sh` with `--id review-disprove-stop-<project>`. If the
setting write fails, the alert says so and names the row to set by hand, and
no ledger row is written, so the next run tries again. A pair with a ledger
row is skipped. GitHub reads per run are capped by
`REVIEW_DISPROVE_STOP_MAX_PRS` (50); past it the report says truncated.

## Commands

- See the line now, change nothing: `/root/harness/bin/review-disprove-report.sh --print --no-send --dry-stop`
- Post this week's beat on another weekday: `--report-now`.
- Log: `grep review-disprove-report /root/harness/logs/review-disprove-report.log`.
- Turn the lane off: `bin/harness-ctl.sh off review-disprove-report`.

## After a stop

Read the alert. It names the PR, the finding location and the fix PR. If the
disprove pass was wrong, leave the project off. If the fix PR is not related
to the finding, set `review.disprove.<project>.enabled` back to 1. The ledger
row keeps the same pair from turning it off again.

Tests: `tests/review-disprove-report.bh-9238-test.sh`.
