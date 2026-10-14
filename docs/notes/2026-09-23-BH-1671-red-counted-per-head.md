# The conductor counts red per head, never across heads

Doc: MERGE-CONDUCTOR

## What was wrong

`mc_classify` (`bin/lib/mc/classify.sh`) parked a red head as
`BLOCKED_HUMAN red-ci-twice` once the PR had red strikes on two DIFFERENT heads
(`red <key> <head>` lines in `attempts.txt`). That check ran before the per-head
red ladder (`MC_RED_RUNG`). So when head A went red and the author pushed head
B, B was parked the first time it went red, before it got its one rerun. The
blocked-resolver then climbed its ladder on that park, and its rebuild rung
closed the PR as "Superseded by a fresh build". The count behind that close
included code that was no longer on the branch. BH-1671 asks for red twice to be
counted per head sha.

## What changed

The `red-ci-twice` arm is gone from `mc_classify`. A red head now always climbs
its own ladder: rung 0 dispatches one `gh run rerun --failed`, rung 1 is WAIT_CI
while that rerun runs, and rung 2 (red again on the same head) is `RED_TWICE`,
reason `red-twice`, which the resolver owns. A push resets the ladder because the
mark is keyed on the head.

The strike ledger is still written by `bin/merge-conductor.sh`, and the flake
path still forgives only an all-known-flake red. The ledger is a record now. It
no longer parks anything.

`red-ci-twice` is still understood everywhere it was (`mc_resolver_owns`,
`br_ladder_class` = `ci-red`, the resolver's supersede guard), so rows parked
before this shipped drain the same way they always did.

The state-table rows in `docs/MERGE-CONDUCTOR.md` that mention `red-ci-twice`
describe the park as it was before this change.

Pinned by `tests/flaky-rerun-test.sh` case 3e (driven through
`bin/merge-conductor.sh`: red on two earlier heads + red once on the current
head = WAIT_CI and one rerun, and no park; red again on that head = RED_TWICE)
and `tests/mc/classify-test.sh`.
