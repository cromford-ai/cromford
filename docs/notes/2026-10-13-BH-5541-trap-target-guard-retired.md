# The trap-target guard is retired; its stale references are fixed (BH-5541)

Doc: CI-RUNNERS

## What changed

- PR #6017 deleted `tests/trap-target-safety-test.sh` and
  `tests/trap-target-safety.bh-5191-test.sh`, and their `catalog/test-tiers.tsv`
  row. `bin/test-trace-safety.sh` catches every shape the guard read (S1-S8).
- The header comments of `tests/prequeue-invariants.bh-5429-test.sh` and
  `tests/prequeue-invariants-real.bh-5429-test.sh` now name the guard in the
  past tense.
- `docs/verification-map/entries/BH-5541.md` now records the measured drop.

## Correction to 2026-10-08-BH-5429-prequeue-invariants.md

That note says `tests/prequeue-invariants.bh-5429-test.sh` is a suite
`tests/trap-target-safety-test.sh` traces. That was true on 2026-10-08. The
guard no longer exists. `bin/test-trace-safety.sh` traces the suite on its own
shard.

## Measured time

The ticket gave 842 s a batch for the guard. That median predates BH-5429,
which moved the nested real suites out of the guard. On CI, run 38176510579
(2026-10-11T21:28Z, head d6c600d2e) recorded 324.9 s for the guard and 26.4 s
for its bh-5191 suite: 351.3 s. Run 38191422152 (2026-10-12T01:19Z, head
9310701b3), after the merge, has neither row. The measured drop is about
351 s a batch. Source: the `ci-durations-next` artifact of each run.

## Pinned by

`tests/test-trace-safety-shapes.bh-5541-test.sh` (S1-S8 bad and good
fixtures, the incident fixture through `--gate --shard 0/1`, R1-R3 for the
removed files and rows).
