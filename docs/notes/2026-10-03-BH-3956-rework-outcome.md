# `reworked`, a fourth outcome in bin/outcome-metrics.sh (BH-3956)

Doc: DORA

## What changed

`bin/outcome-metrics.sh` now reports a fourth outcome next to `reverted`,
`reopened` and `merged_then_red`. The pass lives in `bin/lib/outcome-rework.sh`
and runs after the existing per-PR loop, inside the same Monday 05:20Z hub run.

A merged PR **A** is `reworked` when a later merged PR **B** in the same repo:

- merged no more than `REWORK_WINDOW_DAYS` after A (exactly the window counts),
- touches at least `REWORK_MIN_SHARE` percent of A's product files, where
  "product" is whatever `bin/size-scope.sh --filter` keeps (tests, docs, `*.md`
  and lockfiles never count), and
- is not A's own repair round, meaning the two PR titles don't carry the same
  ticket key. If either title has no key, the pair is judged on window and share
  alone.

Trains (`batch(…)`) and `Revert …` PRs are never A or B. PRs merged to a
non-default base are left out too. Each A gets at most one row, naming the
earliest B. The evidence reads `reworked by <B> (<ticket>) merged <date>, <d>d
later: <k> of <n> product files (<pct>%) [<files>]; sibling=<PARENT|->`.
`sibling=WD-40` means both titles carry the same decomposed parent
(`<TICKET>: <PARENT>.<n>: …`, the title `bin/lib/file-children.sh` gives a
child).

Share is measured on product **files**, not lines. The ticket allowed either,
and line-range intersection across intermediate edits is costly and fragile.

## Where it lands

- `logs/outcome-metrics.csv` gets a `…,reworked,…` row, and the harness-jobs
  outcome push gets it as well. Both are deduped by the existing
  `state/outcome-metrics-seen.txt` key `reworked:<A-url>`.
- **Not** `logs/findings.log`. Sibling rework is a decomposition metric, not a
  reviewer mistake, so `bin/rule-miner.sh` never mines it. Every existing reader
  of the outcome vocabulary (review-tighten's `BAD`, the worker's DORA rollup,
  the console's `BAD_OUTCOMES`) filters by allowlist, so none of their rates
  move.
- `logs/outcome-rework-rollup.csv` gets one row per (ISO week of A's merge,
  project), appended once that week's Sunday plus the window has passed:
  `week,project,merged,reworked,rate,decomposed_merged,decomposed_reworked,decomposed_rate,sibling_reworked,source`.
  `merged` counts PRs with at least one product file. `decomposed_*` is the
  subset whose title names a parent. A zero denominator prints `-`, not 0.
  `source` is `backfill` or `weekly`. A matching
  `rework week=… project=… rate=…% (r/m) decomposed=…% (r/m)` line goes to
  `logs/outcome-metrics.log`. To compare before and after slicing, read the
  `rate` and `decomposed_rate` columns across weeks for a project.

## Data and bounds

The merged list comes from GitHub's REST pulls listing for each fleet repo
(`fleet-conf.sh`), not from the merge ledger, which holds only 500 rows
fleet-wide. Each merged PR's product file list is cached permanently at
`state/outcome-rework/files/<owner_repo>/<n>`. A file containing `#none` means
the list was fetched and had no product files. A failed read leaves no file, so
the next run retries it. File reads per run are capped at
`min(REWORK_FETCH_CAP, core.remaining - REWORK_GH_RESERVE)`. When a listing
fails, or that cap is reached, the repo is **incomplete** for the run: one log
line is written, and no ALERT is raised or exit code changed. The next run picks
up from the cache. Since BH-6165 a repo with a failed listing gets no rows and
no rollup, but a repo with unread PRs still rolls up each closed week whose PRs
and window were all read (see
[2026-10-12-BH-6165-rework-week-complete.md](2026-10-12-BH-6165-rework-week-complete.md)).

## Backfill

While `state/outcome-rework-backfill.done` is absent, the scan covers
`REWORK_BACKFILL_DAYS` (60). The marker is written only by a non-dry run that
read every repo completely. From then on, each run scans the window plus 14
days, which is enough to close last week. Cron does the backfill with no human
step. `bin/outcome-metrics.sh` on the hub runs it sooner.
`OUTCOME_DRY=1` writes nothing: no CSV, rollup, marker or persistent cache.

## Knobs (settings rows on lane `outcome-metrics`)

| knob | default | meaning |
|---|---|---|
| `REWORK_WINDOW_DAYS` | 7 | the window; 0 turns the pass off |
| `REWORK_MIN_SHARE` | 30 | percent of A's product files B must touch |
| `REWORK_BACKFILL_DAYS` | 60 | scan length until the marker exists |
| `REWORK_FETCH_CAP` | 1500 | file-list reads per run |
| `REWORK_GH_RESERVE` | 1500 | core calls left for other hub lanes |

A value that isn't a plain number falls back to the default.
