# Hub load report and the conductor window-stall alert (BH-7397, slice C0)

Doc: OPERATING, ALERTS-STATE-MACHINE

## What changed

Two parts of #7397 that come before any load cut:

1. `bin/hub-load-report.sh`, a new read-only report. It prints the hub
   baseline in one fixed format, so every later slice measures before and
   after the same way.
2. A warn alert when the merge conductor defers every PR of a repo
   (`deferred:window`) on 2 fan-in runs in a row. Before this, that stall was
   silent.

No load path changes in this slice.

## Take a baseline

On the hub, as root:

```bash
/root/harness/bin/hub-load-report.sh
```

That is the last 3600 s. For a fixed window:

```bash
/root/harness/bin/hub-load-report.sh --since 2026-10-18T16:00:00Z --until 2026-10-18T17:00:00Z
```

That second command is the launch-day hour. `logs/gh-calls/` keeps 180 min
only, so for that hour the `gh_calls` line ends `partial(oldest=<ISO>)`. The
load and conductor lines read 14 days of `state/hub-load/*.tsv` and the whole
`logs/merge-conductor.log`.

Flags: `--cap N` (default: settings row `hub_load.max_runnable`, else 8) and
`--tick-window S` (default: `MC_FULL_TICK_BUDGET_S`, else 1500). `--help`
prints the usage. A bad flag exits 2. The report writes no file and makes no
GitHub call. Without `--cap` it reads one settings row through
`bin/jobs-client.sh`.

## What each line means

```
hub-load-report since=<ISO> until=<ISO>
load samples=N runnable_p50= runnable_p90= runnable_max= cap=N(row|default|flag) over_cap=yes|no|NA
lane_share <name>=<pct> ...
gh_calls total=N <caller>=n ... [partial(oldest=<ISO>)]
conductor_ticks n= secs_p50= secs_p90= secs_max= tick_window=S over_window=
conductor_fanin runs= deferred_runs= deferred_run_share=% deferred_pr_share=% all_deferred_runs= window_deferred_lines=
```

- `load`: the `runnable=` values of `bin/hub-load-sample.sh` in the window.
  p50 and p90 use linear interpolation, the rule of `bin/hub-load-baseline.sh`.
  `over_cap` compares p90 with the cap.
- `lane_share`: the mean share (%) of R-state samples per `<name>=` column,
  top 10. A sample that does not list a name counts 0 for it.
- `gh_calls`: wrapped gh calls per caller (`bin/lib/gh-limit-logger.sh`), top
  10.
- `conductor_ticks`: `secs` of the `TICK` lines (`mc_tick_metrics`).
  `over_window` counts ticks with secs over the tick window.
- `conductor_fanin`: the `FANIN merge-conductor` lines (`_fanin_report`).
  `deferred_runs` have at least one `deferred:window`. `deferred_pr_share` is
  the sum of `deferred:window` over the sum of enumerated PRs.
  `all_deferred_runs` deferred every PR. `window_deferred_lines` counts
  `WINDOW_DEFERRED` log lines.

A value with no input is `NA`, never 0. A missing source adds
`(missing: <path>)` at the end of its line.

## The stall alert

`bin/lib/fanin-window-stall.sh` (`fws_note`), called by `_fanin_report` in
`bin/lib/fanin.sh` after the `FANIN` line. Lane `merge-conductor` only.

- A run counts when every enumerated PR is accounted `deferred:window`.
- `MC_WINDOW_STALL_TICKS` such runs in a row (default 2, 0 = off; settings key
  `lane.merge-conductor.mc_window_stall_ticks`) open
  `--severity warn --id mc-window-stall-<repo>`, plus one line in
  `logs/merge-conductor.log`.
- The first later run with any other outcome resets the streak. If the streak
  had reached the threshold, it sends `--resolve` for the same id.
- A run with 0 PRs and an orphan report ("run died before fan-in") do not
  change the streak. `deferred:solo` resets it (a hand-off, not a stall).
- State: `state/fanin/merge-conductor/.window-stall`, TSV
  `repo<TAB>count<TAB>epoch`, one row per repo, under a flock. Rows older than
  7 days are dropped on each write.

## Remaining slices of #7397

- **C1**: shed low-value polling lanes for one tick while the newest hub-load
  p90 is over `hub_load.max_runnable`. Merge, review and alert lanes are never
  shed.
- **C2**: cache GitHub reads per tick for the top callers the C0 report names,
  other than the conductor (it already reads `pr-snapshot.sh`).
- **C3**: move fly-pool scheduling off the hub, or batch it. Blocked by #7251.
- **C4**: after C1-C3 and #7376 merge, run this report over 1 hour on the hub
  and over the launch-day hour, and post the before and after numbers.
