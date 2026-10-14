# The reopen rate's denominator is windowed to the same 14 days as its numerator

Doc: RUN-BUILD-GRAPH

## What was wrong

`bin/reopen-metrics.sh` wrote `{reopens_14d, builds_total}` per project.
`reopens_14d` counted the last 14 days. `builds_total` counted every PR-shaped
build ever: every `logs/metrics.csv` row with `PR_MERGED` or `PR_CREATED`, and
on the GitHub lane every `builds/<P>-*/RESULT` of those kinds. So the rate only
ever diluted. At 500 lifetime builds a project needed 75 reopens in 14 days to
cross the 0.15 demote threshold, and the tier demoter could never fire on a
mature project.

## What changed

Both denominator sources now count only builds dated on or after `$SINCE`, the
same `YYYYMMDD` cut the numerator uses on `logs/reopens.csv`.

- A `metrics.csv` row is dated by `merged_at`, then `pr_at`, then `started`,
  then run-build's `-YYYYMMDDHHMM` build_dir suffix.
- A build dir (the fallback, used only when metrics.csv has no rows for the
  project) is dated by that suffix, then by its RESULT file's mtime.
- A build with no date from any of those is not counted. It can't be shown to
  be in the window. Every row `metrics-collect.sh` writes carries a suffixed
  build_dir, so live rows always date.

The key keeps its name. `builds_total` now means "PR-shaped builds in the last
14 days". The file, the `ledgers(kind=reopen_rate)` row and every reader
(`reopen trust signal`, the demoter, `bin/cost-rollup.sh`) keep their shape and
code.

## Worth knowing

- A project with fewer than `REOPEN_MIN_SAMPLE` (default 10) builds in 14 days
  now reads "no signal" where it used to read a diluted rate. That is the
  gate's existing small-sample rule applied to an honest count.
- The build-dir fallback dates a build by its launch, not its merge. A GitHub
  lane build launched before the window and merged inside it is left out. That
  can only nudge the rate up a hair.

Pinned by `tests/reopen-window.bh-115-test.sh` (the ticket's 500 lifetime /
10 in-window / 2 reopens fixture reads 2/10 and demotes).
