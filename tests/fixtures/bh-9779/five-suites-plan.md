# Fixture plan: five named suites and no loop

## Verify (run, not edited)

One command per suite. The gate runs the wide selection.
- `HARNESS_TEST_SANDBOX=1 bash tests/plan-gate-test.sh`
- `HARNESS_TEST_SANDBOX=1 bash tests/coverage-rows.bh-9441-test.sh`
- `HARNESS_TEST_SANDBOX=1 bash tests/selection-gate.bh-8062-test.sh`
- `HARNESS_TEST_SANDBOX=1 bash tests/agent-call-session-profile-test.sh`
- `HARNESS_TEST_SANDBOX=1 bash tests/execute-oom-classifier.bh-9288-test.sh`
- `bash -n bin/*.sh` (a glob outside tests/)
- `tests/lib/scratch.sh` is the helper each suite sources; it is not a suite.
- Do not run with no timeout, and never run tests/*.sh in a loop: the gate runs it.
- If `tests/plan-gate-test.sh` is slow, it passed its 600 s timeout once; that is fine.

## Tasks

### T1. Fixture task
- VALIDATE: `HARNESS_TEST_SANDBOX=1 bash tests/plan-gate-test.sh`
- SATISFIES: "fixture criterion"

SIZE: S
