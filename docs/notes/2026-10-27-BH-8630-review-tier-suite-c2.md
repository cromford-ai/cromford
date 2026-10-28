# The bh-6967 suite loses its enqueue part; six live cases move to a worklist suite (BH-8630)

Doc: TESTING

Slice C2 of #8526 (BH-8526.2). Since BH-7235 no cron lane or wake starts `bin/lead-review-enqueue.sh`. Its
review tier and mode tokens come from `bin/lib/lead-gates.d/60-risk.sh` in `bin/lead-review.sh tick`. On main
at e06fef66, part A of `tests/review-tier-medium.bh-6967-test.sh` still ran the enqueue `tick`. This slice
removes part A. No file under `bin/`, `worker/`, `cron/` or `catalog/` changes.

## What left the suite

- Part A (M1, M1e, M2, M2b, M2c, M2d, M2e, M3, M3c, M4b, M7, M8, M4c, M10) and its enqueue rig went, with the
  `lpp-stub.sh` source that only part A read.
- Parts B, C and D do not change. M4 and M10c read notes that part A built. They now read literals in the form
  the worklist sends. Their checks do not change.

## Where each case went

`.harness/specs/BH-8630/twin-map.md` has one row per removed case: TWIN, ENQUEUE-OWN or PORT. The twins are
`tests/lead-gates-tier-notes.bh-5878-test.sh` T1-T4 and T9, and `tests/lead-gates-notes.bh-5878-test.sh` N1
and N2.

The new suite `tests/lead-gates-tier-ports.bh-8630-test.sh` holds the ports. It drives
`bin/lead-review.sh tick` whole over the worklist fixture:

- TP1 (M2): row `full`: `review-tier:medium review-mode:full`, stored. TP1b (M2e): no row: full, no log line.
- TP2 (M3): a high head with the row at intent: `review-tier:high review-mode:full`.
- TP3 (M3c): a low head under shadow with the row at intent: a job, `review-tier:low review-mode:full`.
- TP4 (M1e tokens): enforce, no build job: the grace is skipped and the notes carry the intent tokens.
- TP5 (M2c): a PR whose risk block is skipped after an intent PR in one tick: no tokens.
- TP6 (M7): ` Intent ` reads intent; `yes` reads full, with one log line and one row read a tick.
- PM1-PM4 mutate the scratch gate 60 (no trim, no memo, a leaked token, high as intent). Each turns its case red.

## What is left

This is the last gate-60 slice of #8526 apart from C1 (#8629: bh-5325 and bh-5024).
