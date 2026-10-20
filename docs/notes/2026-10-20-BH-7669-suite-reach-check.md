# A suite that names a changed file runs on head and base (BH-7669)

Doc: TESTING, RUN-BUILD-GRAPH

## Problem

The builder gate runs the test selection (`bin/test-impact-gate.sh`), bounded
by a cap and a budget. A suite that names a file the PR changes, but that the
selection ranks past its bounds or does not pick, was first run in the merge
queue. Three shapes reached the queue red: a knob default flip that a
wake-loop suite pins, deleted worker tests that a `package.json` test script
still names, and a `bin/lead-verdict.sh` change that its bash-3.2 suite
rejects.

## What changed

1. New check `bin/suite-reach-check.sh --base <ref> [--tree <dir>]
   [--runner auto|isolated|local] [--cap N] [--budget S] [--suite-timeout S]
   [--table <file>] [--list-only]`.
   - It lists the changed files (`git diff --name-status -M <fork> HEAD`,
     committed HEAD only) and every `tests/*.sh` and `tests/mc/*.sh` suite
     whose text names one. It does not read the test selection.
   - Match ranks: `self` (the suite changed), `path` (the path with path
     boundaries on a non-comment line), `implied`, `glob` (a token such as
     `worker/*/package.json`), `basename` (only when one tracked file has
     that basename, so `package.json` never matches by basename), `comment`.
   - Implied targets come from deleted files: a `package.json` whose `test`
     script names the deleted file or its directory, and a file under a
     `fixtures/` directory that names it.
   - Each listed suite runs on HEAD. A red suite runs on the merge base. If
     base is green, the suite runs on HEAD again. Red again prints
     `RED: <suite> base=<p/f rc> head=<p/f rc> case: <first new FAIL line>`.
   - Not a block: red on both trees (`[NOTE]`), a new suite red on HEAD
     (`[NOTE]`), a deleted suite (`[NOTE]`, the test-tamper gate judges it),
     rc 75, 124 or 137 on either tree (`TRANSIENT`), red then green on the
     second HEAD run (`TRANSIENT … flaky`), a suite past the cap or the
     budget (`NOT RUN: <suite> (cap|budget)`).
   - Exit: 0 clean, 1 at least one green→red, 2 bad arguments, 125 nothing
     could run. On 0 and 1 the last line is
     `SUITE_REACH_VERDICT: clean|red (listed= ran= red= note= transient= notrun=)`.
   - `auto` runs an isolated snapshot as nobody
     (`bin/lib/rules-pack-snapshot.sh`) when root beside a live harness, else
     the local runner.
2. New gate `suite_reach_block` in `bin/lib/suite-reach-gate.sh`, called once
   from `bin/lib/rb/execute.sh` after `STAGE_END gates` (block
   `# >>> suite reach gate`). It runs the worktree's own check, so only a
   repo that carries `bin/suite-reach-check.sh` (cromford) runs it. It
   writes `$BUILD/suite-reach.txt`, `$BUILD/suite-reach.md` and one
   `SUITE_REACH rc=… verdict=…` line to `pipeline.log`.
   - Red: an alert line, `escalate_block suite-reach`, and
     `RESULT "REVIEW_BLOCKED suite-reach: <n> suite(s) green on base, red on head: <suite> (<case>); …"`,
     exit 6. The blocked resolver takes it as every other `REVIEW_BLOCKED`.
   - Clean: a `SUITE-REACH GATE: clean` paragraph in GATES_NOTE, with every
     NOTE, TRANSIENT and NOT RUN line.
   - Any other rc, or rc 1 with no red verdict: `could not run (rc=…) — not a
     pass` in GATES_NOTE. It never blocks.
3. Four fly-pool knobs (`catalog/lanes.d/fly-pool.knobs.d/`):
   `SUITE_REACH_BLOCK` (1; 0 = warn only), `SUITE_REACH_CAP` (60),
   `SUITE_REACH_BUDGET_S` (600), `SUITE_REACH_SUITE_TIMEOUT_S` (300).

## How to fix a block

Read `$BUILD/suite-reach.txt`. The `RED:` line names the suite and the case.
Fix the code so the suite passes, or, when the suite pins the old behavior on
purpose, amend the suite to the new behavior in the same PR and add a
`TEST-CHANGE:` line that says why. A suite green on the new head never blocks.

Tests: `tests/suite-reach-check.bh-7669-test.sh`.
