# BH-9472: a ci-red fix round reproduces the failing CI test before it pushes

Doc: MERGE-CONDUCTOR
Ticket: BH-9472, slice C2 of #9414 (#9285 Fix 4). This is the last slice of #9414.

## What changed

A fix round on a `ci-red` park (`br_ladder_class`: red-ci-twice, red-twice,
queue-ejected-twice, provenance-ci-red, queue-dequeued) now has two more rules.

1. Before the agent call (`brfr_pre`, one line in `br_fix_round`). The round
   reads the failed CI jobs of the PR head, takes the failing test files by
   name from each job log, and runs them once on the box with the CI locale,
   the throwaway Postgres (when `POOL_TEST_POSTGRES` is on) and the
   `CI_LOCAL_BUDGET_S` budget (`bin/lib/verify-run.sh` `vr_run_files`).
   The run uses the head CI ran. When the round's tree is not that head
   (origin/main merged in, a reused checkpoint), a detached worktree at the
   head is used, and a green there runs again on the round's tree.
   - Red here: the round runs, and the files go to `state/<p>/<ck>.repro.txt`.
   - Green on the head and on the round's tree: NOT REPRODUCED. No agent call,
     no push. `fix-verify.txt` gets `REPRO_EXIT: not-reproduced`,
     `REPRO_FILES:` and `REPRO_WHERE:`. The record gets one `fix-round`
     attempt (`fixrounds` +1). Then one PR comment:
     `NOT REPRODUCED: <files> pass locally on <sha8> with LC_ALL=<locale> and a
     local Postgres (collation <c>); CI run <url> failed. No guess pushed.`
     At the fix cap the ordinary terminal runs (`br_fix_terminal`).
2. Before the push (`brfr_verify`, one line in the verify block). When rule 1
   reproduced the red, the same files run on the round's tree after the agent:
   `REPRO_EXIT: passes | still-red | could-not-run`. Only `passes` lets the
   push go; the other two set `vrc=1` and the log says "the failing CI test is
   not proven green here".

## What is not gated (the round runs as before, one log line)

- A park that is not `ci-red` (review-blocked, conflict, prequeue-red, ...).
- A merge that left conflicted paths.
- A red that names no test file: a typecheck, lint or build job, a failed run
  with no failed job, a check that is not an Actions job. If ANY failed job
  names no test file, the whole red is not gated, so a test that is green here
  never hides a real red in another job.
- An unreadable CI, job list or job log.
- A could-not-run (budget, no node_modules, a missing locale, Postgres down,
  exit 124-127). It is never `reproduced` and never NOT REPRODUCED.

## Failing test lines read from a job log

vitest `FAIL  <path> > ...`, jest `FAIL <path>`, and this repo's CI
(`bin/test-trace-safety.sh`) `--- <tests/x.sh> rc=<n> <t>s` with n != 0.
Timestamps and colour codes are stripped. A path must be relative, without
`..`, not start with `-`, and be a regular file (not a symlink) in the tree.
The plan named a harness form `FAIL: tests/<x>.sh`; this repo's CI does not
print that form (a suite prints `FAIL: <assertion>`), so the parser reads the
`--- <suite> rc=<n>` line that CI does print.

## Knobs (catalog/lanes.d/_lib.fixround-repro.json)

- `FIXROUND_REPRO_GATE` (row `lib.fixround-repro.fixround_repro_gate`, or
  `lib.fixround-repro.<project>.fixround_repro_gate`): 1 on (default), 0 off.
- `FIXROUND_REPRO_LOG_MAX_KB` (row `lib.fixround-repro.fixround_repro_log_max_kb`,
  or the `<project>` form): the tail of each failed job log that is read,
  default 2048 KiB. A FAIL line before the tail is not read, and that job is
  then not gated.

## Decision A2

A NOT REPRODUCED round counts as a fix round. Without the count the park would
run the repro and post the comment again on every tick.

Code: `bin/lib/fixround-repro.sh`, `bin/blocked-resolver.d/bh-9472-fixround-repro.sh`,
three lines in `br_fix_round`. Test: `tests/fixround-repro.bh-9472-test.sh`.
