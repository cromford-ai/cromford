# BH-8850: a harness suite that could not run never refutes a claim

Doc: RUN-BUILD-GRAPH

## Why

On 2026-10-31 the lead review of example-org/project-6#3443 at 2f8537c3
(lr-3443-2f8537c3f21a) blocked on two REFUTED evidence rows:
harness-suite.txt:6603 and :6612. The box run of that file ended
`HARNESS_EXIT: could-not-run`. The same tests passed 37/37 at that head on
the Mac, and CI Unit 1-16 was green. The scorer read FAIL lines from a run
that did not run. The BLOCK cost one fix round.

## What changed

- `bin/lib/evidence.sh` `evidence_locate`: before it reads a harness-suite
  file for a named test, it reads the file's LAST line-leading
  `HARNESS_EXIT:` value (the same read as `LIVE_SUITE` in
  `bin/lib/rb/gates.sh`).
  - A non-integer value (`could-not-run`, `no-test-script`): the file decides
    nothing, pass or fail. The next source is read.
  - An integer value (`0`, `1`, `124`): the file decides as before.
  - No `HARNESS_EXIT:` line: the file decides as before.
- If no source decides, and a skipped file named the test, `evidence_locate`
  returns `none` with the note `harness suite could not run (<file>)`.
- `evidence_score` rule 4 (INCONCLUSIVE) prints that note in place of
  `named test never appears in harness-suite*.txt or validate.txt (<test>)`.
- The `CLAIM n:` line format does not change.

## Check

`HARNESS_TEST_SANDBOX=1 bash tests/evidence-scorer.bh-8850-test.sh`
(cases A-L). Cases A and C are red at ff11ed853.
