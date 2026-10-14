# The overlap schedule stacks instead of deferring (BH-1174)

Doc: BUILD-CONCURRENCY, SCHEDULER

## Why

Two ready tickets that plan the same file already launched in order:
`bin/overlap-schedule.sh` put A in WAVE 1 and B in WAVE 2. Once A's PR was
open and A left the candidates, B went back to WAVE 1 and launched on the
default branch. `bin/overlap-guard.sh`'s open-PR check then deferred B every
tick until A merged, or B built anyway and paid a rebase. The stacked-child
flow (`STACK_BASE`) could build B on A's branch, but it was only chosen for
declared `Blocked-by` chains.

## What changed

- `bin/overlap-schedule.sh` reads the open-PR cache the guard already writes,
  `state/overlap-guard/<project>-prs.json`. It only reads that file and makes
  no GitHub call of its own. For each WAVE 1 key it compares the key's planned
  files with each non-draft open PR. The comparison is whole files only, like
  the guard's `OVERLAP_EXACT=1`, and uses the same prune, `OVERLAP_IGNORE` and
  `OVERLAP_THRESHOLD`. A PR on the key's own branch is skipped. When exactly
  one PR collides, the script prints a new line after the WAVE lines:

      STACK: AB-2 base=ticket/ab-1 (overlaps open PR #11 on code/shared.ts)

  With `--key AB-2` it prints `AB-2 STACK base=ticket/ab-1 (...)` in place of
  the `WAVE 1` answer. No other line shape moved.
- The tick prompt's `OVERLAP_SEC` launch rule (`bin/lib/rt/scope.sh`) and the
  shard's overlap note (`bin/lib/rt/shards.sh`) now say that a STACK key is
  launchable like WAVE 1, with its base passed through:
  `STACK_BASE=<base> setsid /root/harness/bin/run-build.sh ...`. HELD still
  wins over it.

## What it does NOT do

- No STACK line when the key overlaps two or more open PRs (it cannot sit on
  two parents), overlaps a running build (that is HELD), or is in WAVE 2 or
  later. No STACK line for a draft PR, for a branch name outside
  `[A-Za-z0-9._/-]` or containing `..`, or for a planned directory that only
  contains a PR's file. In all of those cases the guard settles the launch
  exactly as before.
- A missing, stale (older than `OVERLAP_SNAPSHOT_MAX_AGE`, default 600 s) or
  unparseable cache prints today's output. Nothing locks, queues or waits.
- The ticket's `pipeline`/`fleet_status` "deferred: overlap with ..." column
  and the daily "rebases avoided" count are not built here.

## Knobs (none new)

- `OVERLAP_SNAPSHOT_MAX_AGE`: how old the PR cache may be.
- `STACKED_BUILDS=0` or the `stacked-builds-off` switch (`lane_switch`, file
  fallback `flags/stacked-builds-off`): no STACK verdict. This is the same
  switch `bin/lib/rb/gates.sh` honours when it ignores `STACK_BASE`.

## Probe

On a box: `/root/harness/bin/overlap-schedule.sh <project> | grep -E '^(WAVE|STACK|HELD)'`.
Suite: `HARNESS_TEST_SANDBOX=1 bash tests/overlap-schedule-stack.bh-1174-test.sh`.
