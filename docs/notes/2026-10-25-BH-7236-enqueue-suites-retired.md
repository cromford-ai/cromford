# The enqueue-named suites are retired; their live cases run on the worklist (BH-7236)

Doc: TESTING

Slice C0 of #7236. Since BH-7235 no cron lane or wake starts `bin/lead-review-enqueue.sh`. Its per-PR gates run
in `bin/lead-review.sh tick` (the worklist, `bin/lib/lead-gates.d/`). The suites that drove the enqueue `tick`
tested a script nobody runs. This slice removes them. The script itself stays on disk, unwired, until C2.

## What was deleted

Nine suites:

- `tests/lead-review-enqueue.bh-3545-test.sh`
- `tests/lead-review-enqueue-failed-retry.bh-5779-test.sh`
- `tests/lead-review-enqueue-no-silent-skip.bh-5779-test.sh`
- `tests/lead-review-enqueue-risk.bh-5022-test.sh`
- `tests/lead-review-enqueue-low-small.bh-7041-test.sh`
- `tests/lead-review-enqueue-human-step-done.bh-6696-test.sh`
- `tests/lead-enqueue-body-lint.bh-5790-test.sh`
- `tests/lead-enqueue-traced-wait.bh-5795-test.sh`
- `tests/lead-enqueue-self-check-zero.bh-5905-test.sh`

The verification-map row `docs/verification-map/entries/BH-3479-enqueue.md` was deleted. Its only proof was the
3545 suite, and its cron line was already gone.

Two suites keep their worklist half only:

- `tests/lead-review-enqueue-authors.bh-5351-test.sh`: E1-E6 went; DA1-DA3 (gate 25) stay.
- `tests/lead-enqueue-no-builder-gate.bh-5630-test.sh`: G1-G8 went; D1-D6c (gate 10, the skip ledger) stay.

## Where each case went

`.harness/specs/BH-7236/twin-map.md` has one row per case: TWIN (a worklist suite pins the same outcome),
ENQUEUE-OWN (only the enqueue wrote that output), PORT or KEPT.

The worklist still has every behaviour a NO-TWIN case pinned, so no product code changed. Those cases are ported
to new suites. Each new suite drives `bin/lead-review.sh tick` whole and has a mutation case (M1):

| New suite | Cases | From |
|---|---|---|
| `tests/lead-step-done.bh-7236-test.sh` | U1-U12 (moved verbatim) | human-step-done |
| `tests/lead-gates-selfcheck-zero.bh-7236-test.sh` | Z1-Z3 | self-check-zero |
| `tests/lead-gates-authors.bh-7236-test.sh` | A1-A5 | authors E1, E3 (404), E4-E6 |
| `tests/lead-gates-builder-earlier-head.bh-7236-test.sh` | E2b, E10, E11, E13 | human-step-done |
| `tests/lead-gates-traced-ports.bh-7236-test.sh` | T1, T8, T9, D2, D3, D4, D4b, B2 | traced-wait |
| `tests/lead-gates-risk-ports.bh-7236-test.sh` | B8, B9, B13, B16 | risk |
| `tests/lead-gates-retry-ports.bh-7236-test.sh` | F2, F6, F9, F10 | failed-retry |
| `tests/lead-gates-skip-ledger.bh-7236-test.sh` | D2, D3, D4 | no-silent-skip |

The "Verified by" clauses of the BH-5022, BH-5351, BH-5779, BH-6696, BH-7041 and BH-5870.1 map rows now name
the twin or port suites. No other text of those rows changed.

## Left for later slices

- C1: remove the enqueue cases from the mixed suites that still run its `tick`.
- C2: the static readers, then the script, its lane JSON, the cron stub, the supersede block, the protected-path
  row, the step 6 comments, the other step 7 map rows, and `tests/lead-enqueue-retired.bh-5870-test.sh`.
