# Plan: BH-9999 — reuse each suite result once per commit

## Scope
Cut the merge-queue run time. A suite that already passed at the same input
fingerprint is not run again.

## Target metric
Target metric: mq-full-share from 0.62 to 0.30 share

## Tasks

### T1. Reuse a passed suite
Read the suite ledger before the run and skip a suite that passed at the same
fingerprint.
VALIDATE: `bash tests/suite-reuse-fixture-test.sh`
SATISFIES: "record each test result once per commit and reuse it"

### T2. Report the replay
Write the outcome-replay table into the PR body.
VALIDATE: `bash tests/suite-reuse-fixture-test.sh R1`
SATISFIES: "the PR reports what it measured"

## Acceptance tests
- tests/suite-reuse-fixture-test.sh C1: a passed suite at the same fingerprint is reused.
- tests/suite-reuse-fixture-test.sh R1: the outcome replay runs over the last 50 real merge-queue batches,
  reports mq-full-share, and lists the top miss reasons.
  It names the hit rate of the fallback path (a full run when the ledger is unreachable).
  The PR body reports it under '## Outcome replay' with the same 'Target metric:' line and a 'measured: <number>' line.

## QA screens
None.

SIZE: S
