# BH-9502: the 14-day size re-measure on #6025

Slice C5 of #9441. It delivers scope item 6 of #9441 (comment 6780689984).

## What the lane does

`bin/size-remeasure.sh` is a hub lane. Cron runs it daily at 07:47Z behind the hub lease
(`cron/lanes/781-size-remeasure.cron`).

1. If `state/size-remeasure/posted` exists, it logs `done: posted <url>` and stops. It makes no call.
2. It reads #9441 and #9437. Both must be closed as completed. An open issue, a `not_planned` close or a failed read stops the tick.
3. It waits `SIZE_REMEASURE_DELAY_DAYS` (14) after the later close.
4. It reads the #6025 thread. If the hidden marker `<!-- harness-status: size-remeasure-bh-9502 -->` is there, it records that URL as posted and stops.
5. It runs `bin/split-chain-report.sh --days 14` on the harness repo.
6. It counts ABANDONED and closed-unmerged PRs per repo from `$HARNESS/builds`, in four buckets: under 600, 600 to 1200, 1200 to 3000, over 3000 product lines.
7. It posts ONE comment on #6025 with the baseline (36 PRs, 20 with a large-diff note, median about 2,900 lines) and both tables.

If the report is INCOMPLETE, the thread is unreadable or the POST fails, it writes one ALERTS line and posts nothing. The next tick tries again.

It changes no limit. It does not read or write `bin/size-gate.sh`, `bin/size-threshold.sh` or any `size_*` settings row. The limit stays a decision for the operator.

## What it reads

- `RESULT` line 1, first token: `ABANDONED` or `ABANDONED_<X>` is abandoned, `PR_CLOSED` is closed-unmerged.
- `.blocked-resolver-abandoned` (abandoned) and `.blocked-resolver-superseded` (closed-unmerged). Abandoned wins.
- The mtime of the deciding file must be inside the window.
- The last `SIZE: shipped <N> product lines` line of `pipeline.log`. No such line: the PR is `unmeasured`, never 0.
- The repo is the owner/repo of the PR URL, else `job.json` `.project`. One count per PR URL.

A PR closed by hand on GitHub with no marker is not counted. A build dir pruned before the run is not counted.

## Preview

```bash
bin/size-remeasure.sh --dry-run
```

It prints the gate verdict, the split-chain line, the bucket table and the full comment body. It posts nothing, writes no state and writes no alert.

The bucket count alone, with no network call:

```bash
bin/size-remeasure.sh buckets --builds /root/harness/builds --days 14
```

## Off and re-arm

- Off: `bin/harness-ctl.sh off size-remeasure` (flag `lane-off-size-remeasure`).
- Re-arm: delete the #6025 comment AND `state/size-remeasure/posted`. If the comment stays, the thread check finds it and the lane posts nothing.

## Knobs

`lane.size-remeasure.*` settings rows (catalog/lanes.d/size-remeasure.json): `size_remeasure_delay_days` (14),
`size_remeasure_window_days` (14), `size_remeasure_edge_low` / `_mid` / `_high` (600 / 1200 / 3000),
`size_remeasure_gate_issues` (`9441 9437`), `size_remeasure_target_issue` (6025), `size_remeasure_max_pages` (30).
