# A merge-queue batch red stops being filed as a main red when main already passed those suites (BH-4329)

Doc: MERGIFY

## What changed

- `bin/lib/mrb-detect.sh`, flag source. When the flagged run is a merge-queue
  batch (`mergify/merge-queue/*`) and its failed traced shards name red
  suites, the detector asks one more thing before it writes `flag-<run>.ep`:
  did a successful run of the same workflow on `main`, at exactly the batch's
  merge-base, already run every one of those suites with `rc=0`?
- Evidence is the `--- tests/<x> rc=0` lines in the logs of that run's
  successful `Tests, traced (shard ...)` jobs. All red suites have to be in
  ONE run, matched as whole paths. A skipped shard, a gone log (404/410), a
  run at an ancestor sha, a run of another workflow and a run off `main` are
  not evidence. At most 3 main runs are read.
- Cleared: one `mrb-detect:` line naming the main run, no episode file, rc 0.
  The bisect driver never sees the episode, so there is no probe, no
  quarantine and no ticket.
- No evidence: today's behaviour, unchanged. A failed read (5xx, 429, 403,
  network) is rc 75, the existing "this source writes no file this tick" path.
- main-class flags (a run on `main` itself) and the nightly source are
  unchanged.

## Why

#4220, #4286, #4289, #4318, #4321 and #4329 were all filed in about 5 hours
as "red on main with no culprit merge". Each one quarantined suites that main
passed. For #4329, Harness CI on main at a00ade0 (run 37175771401) had
`--- tests/lanes-registry.bh-2205-test.sh rc=0` and
`--- tests/triage-state-pr-contract.bh-3418-test.sh rc=0`. The red came from
merge-queue batch b3fa5d2 (run 37178276949), whose queued PRs broke both
suites. The detector mapped the batch red to its merge-base and wrote it as a
main episode without checking main's own CI at that sha.

## Limits

Push runs on main skip the traced shards (#2220), so this only fires when
main has a full run (a dispatch, say) at exactly the merge-base. Other batch
reds still go to the probe as before. The reads repeat each tick while the
flag stands, because a skip writes no ledger. That is at most 1 list, 3 jobs
and 24 log reads per tick, all GitHub REST.

Pinned by `tests/mrb-detect-batch.bh-4329-test.sh`.
