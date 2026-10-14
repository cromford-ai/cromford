# BH-4055: PR events close merge-path alerts in the same drain

Doc: EVENTS, ALERTS-GROOMING-SPEC

Part 3 of 4 of BH-3997. Stacked on BH-4054, whose retraction epilogue
(`ph-<key>` → `bin/beat.sh resolved:true` → console resolve) this reuses.

## What changed

- `wakeOf` (`worker/jobs/src/lib/core.js`) now stores `pull_request.enqueued`
  and `pull_request.dequeued` (GitHub's native merge queue) as `pr` wakes. The
  `labeled` branch is unchanged (the `queued` label only) and `unlabeled` is
  still dropped: the stored row carries no label name to tell `queued` apart.
- `bin/pipeline-health.sh --sections <csv>` (or `PH_SECTIONS=<csv>`; the
  argument wins) runs only the named PR checks. Known names: `stalepr`,
  `leadunqueued`. An unknown name is logged and dropped; a list with no known
  name logs one line and exits 0, never a full run. Every `health-active.txt`
  key outside the selected sections is carried into the run's fired set, so a
  skipped section is never retracted (the budget-low rule from BH-4054). A
  sections run that finds `locks/pipeline-health.lock` held skips; the cron
  run (no arguments) takes the lock with `flock -n` and never waits on it.
- `bin/lib/wake-class-pr-closed.sh`: a `closed`, `labeled` (queued), `enqueued`
  or `dequeued` pr row launches `pipeline-health.sh --sections
  stalepr,leadunqueued` last in the dispatch, at most once per wake-loop
  invocation (a second one logs "held, per-tick cap") and under
  `cooled pipeline-health fleet` (hub only, `WAKE_COOLDOWN_S`). `enqueued` also
  joins `--queued` for `bin/alerts-merge-resolve.sh`; `dequeued` does not. A
  held launch is not owed: the `*/10` cron covers it.
- `bin/alerts-resolve-closed-prs.sh` closes a pipeline-health row (akey
  `alert:ph-*` or a `[pipeline-health]` line) whose `prs=` token lists ONLY
  webhook-closed PRs, matched on the whole lowercased `owner/repo#N`. Its local
  alerts row id is the akey minus `alert:`. A row that only mentions a PR URL,
  or lists one PR still open, stays open. `ALERTS_PR_SUBJECT_RE` is untouched.

## Why

A merged or queued PR's `ph-stalepr_*` / `ph-leadunqueued_*` row only retracted
on the next `*/10` pipeline-health tick, and a leadunqueued row was never in
the closed-PR resolver's reach at all.
