# run-build.sh runs its stages from bin/lib/rb/

Doc: RUN-BUILD-GRAPH, verification-map

## What changed

The last part of BH-478 (BH-572). `bin/run-build.sh` went from 7056 lines to
197. The eleven inline stage slices were deleted, and each one is now a bare
`rb_<entry>` call to the body the seven modules under `bin/lib/rb/` already
defined. Before the cut, the six modules that had drifted were re-synced to the
driver's current text. The flattened pipeline (`tests/lib/rb-all.sh`) equals the
pre-cut driver byte for byte, so no behaviour changed.

The driver keeps its head, the per-key dedupe lock and env load, and the EXIT
trap. Call order: `rb_gate_prelude`, [flock + env load],
`rb_gate_claim_and_workspace`, `rb_plan`, [trap], `rb_gate_overlap`,
`rb_execute`, `rb_spec_artifact`, `rb_execute_gates`, `rb_review`, `rb_pr`,
`rb_settle`, `rb_close_out`.

## What it touches

- A marker block is read through `$RB_ALL`, never by grepping the driver. The
  four twin pins (bh-1026 §4, bh-117 D1, bh-851 P1, bh-1319) became one-copy
  pins: absent from the driver, present once in the module.
- `tests/rb-split-layout.bh-572-test.sh` pins the shape: 400 lines or fewer, one
  bare call per entry in order, and modules that print nothing when sourced.
- `docs/RUN-BUILD-GRAPH.md` maps each transition row to its entry function.
- The kept `# >>> stage modules` comment still says "nothing calls into one
  yet". It is stale, but it stays as it is because the identity proof forbids
  editing kept text. A comment-only follow-up can fix it.
