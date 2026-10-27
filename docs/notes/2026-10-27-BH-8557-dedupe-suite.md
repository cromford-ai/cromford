# The bh-3930 dedupe suite loses its enqueue cases; gate 50's live replay rules move to a worklist suite (BH-8557)

Doc: TESTING

Slice C1 of #8524 (BH-8524.1), the last gate-50 slice. Since BH-7235 no cron lane or wake starts
`bin/lead-review-enqueue.sh`. Since BH-8363 it has no lane row. Its rebound replay runs in
`bin/lead-review.sh tick` (the worklist, `bin/lib/lead-gates.d/50-replay-delta.sh`). This slice removes the
enqueue `tick` cases from bh-3930. No file under `bin/`, `worker/`, `cron/` or `catalog/` changes.

## What left the suite

`tests/lead-review-dedupe.bh-3930-test.sh`: part 2 went. That is D4, D4b, D5, D6, D6b, D6c, D7, D8 (added by
#8489, BH-8476) and the D8 control, with the enqueue rig: the `$Q` harness and its hand-copied libs, the
token and its fleet.conf, the git fixture, the curl and gh stubs, the `lead-verdict.sh` and `lane-alert.sh`
stubs, and the helpers only part 2 read. `bin/lead-review-enqueue.sh` left the file-exists check. D1-D3 and
the dispatcher cases B1-B4 do not change.

## Where each case went

`.harness/specs/BH-8557/twin-map.md` has one row per removed case: TWIN (the worklist suite and case that
pins the same outcome), ENQUEUE-OWN (output only the enqueue wrote) or PORT. D4, D8 and the D8 control are
TWINs of bh-3930 B1, B4 and B2 (plus bh-5294 R1 and bh-5878 tier-notes T9 for D4). D6b is ENQUEUE-OWN: the
worklist holds on post rc 1, and bh-5294 R2 pins that.

`tests/lead-gates-replay-dedupe.bh-8557-test.sh` drives `bin/lead-review.sh tick` whole over the worklist
fixture, on a rebound head:

- DD1, DD1b, DD1c (from D4b): post rc 5 and rc 4 (the real writer, POST statuses 500) are replays; rc 3 is
  held.
- DD2, DD3, DD4 (from D6 and D6c): a 500, a non-JSON or a truncated history read is a full review. A 500 on
  every verdicts read stops the head at the standing-verdict read before gate 50 runs, so DD2 and DD3 fail
  only the history read, through a suite-local curl wrapper.
- DD5, DD6 (from D6c): a box-only history or an empty lead word has no G: a full review.
- DD7, DD7b, DD7c (from D7): a `lead-replay:` row counts as "already replayed" only from the lead, on this
  head, and not retracted. bh-3930 B3 keeps the match.
- DD9 (from D5): a rebound head with one own line is a full review. The planned twin bh-5878 N1 is not a
  rebound-head case, so D5 took the plan's fallback port.
- M1 and M2 cut the head clause and the truncated check from the scratch copy of gate 50; DD7 and DD4 then
  fail.

## What is left

On this head, 10 suites still name an enqueue `tick` (the plan's V9 count, measured after this change):
bh-5325 (risk-tier-rules-lane), bh-5024 (jev-risk-shadow), bh-6968 (risk-tier-evidence), bh-6967,
bh-5023, bh-5875, bh-7041, bh-5797 (silence-before-risk), bh-8363 (the lane-retired suite) and bh-5740
(inbuild-grace-outside-push). bh-3930 is no longer in the list.
