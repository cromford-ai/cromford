# BH-9697: the pre-queue gate runs on fresh main, and main's reds are quarantined

Doc: REMOTE-GATE, FLAKY-TESTS, GATES-VS-REPORTS

Slice C0 of #9697 (Part D of BH-9582). Part B (build stacks) is not in this
slice; #9697 stays open for it.

## What changed

- `bin/selection-gate.sh` step 1b: with `SELECTION_GATE_FRESH_MAIN=1` the gate
  merges a fresh fetch of origin's main onto HEAD (`git merge-tree`, a dangling
  `git commit-tree` object, a detached worktree) and runs the batch selection
  and the suites there, with main's tip as the base. Off reasons write one
  `fresh-main: off (<why>)` line and the run on HEAD.
- `bin/selection-gate.sh` steps 5 and 6: with
  `SELECTION_GATE_SUITE_QUARANTINE=1`, a suite red on the merged tree and on
  main, not changed by the diff, gets an active `suite_quarantine` row and
  goes to the new `quarantined:` line. A suite with an active row is
  quarantined at step 5. One EXIT trap now cleans both worktrees.
- New D1 table `suite_quarantine` (partial unique index: one active row per
  (repo, suite)), route family `worker/jobs/src/routes/suite-quarantine.js`,
  retention rule (released rows after 60 days), four jobs-client verbs.
- `bin/flaky-tier.sh` steps 4b, 5b and 6 (logic in
  `bin/lib/suite-quarantine-hub.sh`): one repair ticket per row, the union
  with the flaky rows in `CI_QUARANTINE`, and the release after a green
  nightly on a newer main sha.
- Rules: `docs/gates/prequeue-fresh-main.md`.

## Assumptions (from the plan)

- A1. The batch drops a quarantined suite through the existing
  `CI_QUARANTINE` projection. `bin/ci-plan.sh` is not edited: CI does not hold
  `HARNESS_SECRET`, so it cannot read the table.
- A2. The release lives in `bin/flaky-tier.sh`, which already caches each
  nightly run's per-suite rc. `bin/main-red-bisect.sh` has no green path on a
  newer main sha. `ft_release` fetches only when a flaky row is eligible, so
  step 5b fetches the uncached runs itself (`_ftr_fetch`).
- A3. The gate only writes the row. The hub lane files the ticket, so no
  GitHub call runs on a pool machine or in a gate test.
- A4. The parent's settings rows map to lane knobs: `selection_gate.fresh_main.enabled`
  is `SELECTION_GATE_FRESH_MAIN`, `suite_quarantine.enabled` is
  `SELECTION_GATE_SUITE_QUARANTINE`, `suite_quarantine.max_new_per_run` is
  `SELECTION_GATE_QUARANTINE_MAX_NEW` (rows per gate run) and
  `SUITE_QUARANTINE_MAX_NEW` (tickets per tick). `suite_quarantine.retention_days`
  stays a settings row, because the worker reads it.
- A5. `git merge-tree --write-tree` gives a tree, and the runner needs a
  commit. The gate makes a dangling `commit-tree` object with the identity
  `gate@harness`. No ref points at it and nothing pushes it.
