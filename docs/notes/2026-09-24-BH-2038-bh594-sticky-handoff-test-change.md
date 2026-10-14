# BH-594 changed what conductor-sticky-handoff #438 expects; its old coverage moved to #439

Doc: MERGE-CONDUCTOR

## What changed

BH-594 (PR #2020) edited an existing assertion in
`tests/conductor-sticky-handoff-test.sh`, and its PR body never said so. This
note records that change.

- **#438 now expects the resolver to wait.** The #438 fixture is a hand-off that
  the conductor then re-flipped to `HEAD_MOVED` on its own handed-off head.
  Before BH-594 the suite expected the resolver to recover it as a candidate.
  Since BH-594 that shape is a head-bound re-review in flight, so the suite
  expects zero candidates for #438 and the log line
  `example-org/demo-os#438: re-review in flight on <head>, resolver waits`
  (the fixture comment at lines ~283-294, the assertions at lines ~371-373).
- **The old coverage moved to a new #439 fixture.** "A recovered hand-off keeps
  its own rung" used to ride on #438. #439 carries it now: the same
  `head-not-reapproved` hand-off, with its row in `WAIT_CI` (lines ~294 and
  305). The suite asserts #439 is a candidate again and still owes its fix round
  (lines ~374-380).

## Why

BH-594's fourth ask was that the resolver waits while the conductor's
head-bound re-review runs on the same head (the TK-1669 race). #438 was exactly
that shape, so its old expectation became wrong. The change is deliberate, but
a test whose expectation flips has to be named where the reviewer reads it
(BH-2038, ask 3).

## Also

PR #2020's Assumptions section is cut off partway through A5. A6 ("the hop
ignores `HUB_NO_BUILD_LANES`") is in the spec, `.harness/specs/BH-594/plan.md:137`.
