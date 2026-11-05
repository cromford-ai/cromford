# The hub files the lead review request for a head a machine deferred (BH-9026)

Doc: MERGE-CONDUCTOR

## What happened

On 2026-11-03 the lane-run machine that ran cromford #9022's conductor
tick reported `PROF mc-pr state=HEAD_MOVED ... deferred=rereview` (row 74800,
19:21Z). The hub's next tick took the `fallback=machine-deferred (rereview)`
arm of `mc_fly_arm` and ran the PR on the hub, but it filed no
`lead_review_requests` row. Cromford merges need the `lead-verdict`
check, so the PR waited until a person ran `bin/lead-verdict.sh request` at
19:51Z.

## What changed

- `mc_fly_arm` (`bin/lib/mc/fly-workers.sh`), rc 5 arm: when the deferred
  words contain `rereview` (whole word in the comma list), the hub calls
  `mc_fly_rereview_request` before the fallback.
- `mc_fly_rereview_request` asks only for a repo in `LEAD_REVIEW_AUTO_REPOS`
  (lead-review-land's knob, default `example-org/cromford`). It calls
  `bin/lead-verdict.sh request <slug> <pr> <head40>`, with `--priority
  MC_REREVIEW_REQUEST_HOTFIX_PRIORITY` (new knob, default 500) for a
  hotfix-labelled PR.
- Log lines in `logs/merge-conductor.log`: `rereview requested <id> for
  <head12> (pool deferred)`, `rereview request exists for <head12>`, `rereview
  request FAILED for <head12> (pool deferred): <why>`.
- Attempt kinds `rrleadreq` (written after a created or 409 answer, so a later
  tick makes no call) and `rrleadreqfail` (one alert per PR and head).
- A failed request sets the pr-state `BLOCKED_HUMAN` with the new reason
  `rereview-request-failed` and starts no local worker that tick. The next
  tick asks again. `bin/blocked-resolver.sh` treats the reason as unmapped.
- On a requested, exists or skipped answer the hub fallback runs as before.

Suite: `tests/conductor-rereview-request.bh-9026-test.sh`.
