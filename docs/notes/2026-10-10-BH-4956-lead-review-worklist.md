# The lead review lane reads the needs-review worklist (BH-4956)

Doc: docs/verification-map/lead-review.md

## What changed

- `bin/lead-review.sh tick` has two inputs now, in this order:
  1. The needs-review worklist. For each `LEAD_REVIEW_AUTO_REPOS` repo this box
     owns, `pr_needs_review` (`GET /api/pr-state/needs-review`) lists the heads
     the gate facts say need a lead review. The route orders them: nudged,
     then hotfix, then the oldest approval.
  2. The lead review request rows, as before (BH-5151 order and janitor).
- A request row for the same `(repo, pr, head)` as a worklist item is worked
  once, in the item's place, by its id (`/claim`). An item with no row is
  claimed with `lr_start` (`POST /api/lead-reviews/start`).
- `LEAD_REVIEW_MAX_PER_TICK` is gone from the script and the registry. A tick
  starts every eligible item as soon as a pool slot is free.
  `LEAD_REVIEW_DEADLINE_S` closes STARTS; running reviews finish.
- Two settings rows bound the starts. Both are re-read before every start
  (cached `LW_READ_TTL_S`, 15 s):
  - `lead_review.concurrency`: a fleet-wide count. The lane counts
    `GET /api/jobs?kind=lead_review&status=running` on other boxes plus its
    own live workers. No row: the per-box `LEAD_REVIEW_CONCURRENCY` (K)
    governs. The running count unreadable: no start this pass.
  - `lead_review.daily_spend_usd`: compared with
    `llm_gate_spend_today lead-review "" lead-review`. At or over it, no new
    start, and one `lane-alert` warn a UTC day (id `lead-spend-cap-<day>`,
    marker `state/lead-review/spend-cap-<day>`). No row: no cap. A cap row
    with the cap or the spend unreadable: no start, no alert.
- `LEAD_REVIEW_MAX_PER_PR_DAY` (registry knob, default 4) keeps the BH-3545
  tripwire on this lane: lead reviews of one PR the model answered per UTC
  day on this box, one line a review in `state/lead-review/started.tsv`
  (pruned to today and yesterday). A claim with no model answer (rc 74..79, a
  rate limit, paid, replayed, superseded) is not marked. A trip sends one
  `lane-alert` warn a PR a UTC day (id `lead-trip-<owner_repo>-<pr>-<day>`,
  marker `state/lead-review/trip-<owner_repo>-<pr>-<day>`).
- Counted failures are `pr_attempts` rows of kind `lead-review-1..3` on the
  head: live head unreadable, checkout failed (it was terminal at once
  before), artifact or result post failed, and a stale claim taken over. The
  third posts `outcome=failed detail="attempts-exhausted: <reason>"` and the
  gate fact `review_failed_sha`. Not counted: agent-call rc 74..79, a rate
  limit (the model's, or GitHub's on the live-head read), superseded, the
  caps. A worker that ends and leaves its request row `running` on purpose (a
  not-counted exit, or a counted failure already written) PUTs the release
  marker `pr_attempts` kind `lead-review-free` on the head. The next takeover
  of that claim reads it, deletes it and is not counted. A takeover with no
  marker is a crashed claim, and it counts. A worklist item with 3 attempts, or with its
  attempts unreadable, is not claimed. A request row is claimed on its own
  status: the third failure already made it terminal.
- Dedup before spend: `/start` terminal `done` (`paid`), then the artifact and
  the disk report, then `<key>.empty`, then the patch-same replay
  (`lw_replay`: the newest lead verdict on another head that is not itself a
  replay, `ld_classify` says `replay <how>`), then the `lead_fp` guard. A
  replay posts `/result outcome=done verdict=<word> reviewer_model=lead-replay
  report_ref=lead-replay:<prev12>:<how>` and rings lead-land.
- On a claim the lane writes the gate fact `reviewing_sha`. One worker per key:
  `flock -n locks/lead-review-<key>.lock` (fd 8), a dedupe, never a wait.
- The janitor (pass 2) supersedes `running` rows too, not only `requested`
  ones, when the PR closed or the head moved. A `running` row under a live job
  refuses the claim and is skipped.
- `bin/lead-verdict.sh request` (and `bin/harness-ctl.sh review`) now nudges:
  after the request it writes the gate fact `nudged_sha` and rings
  `lcw_ring lead-review`. Both are fail-open.
- The summary line adds `worklist= paid= replayed= capped=` after `started=`.

## What did not change, and why

- `bin/lead-review-enqueue.sh` is kept. Ticket item 7 asked to delete it, but
  five merged tickets (BH-5022, BH-5023, BH-5294, BH-5325, BH-5630) put work
  there that no other lane does: risk-tier sign-off, the in-build hold, delta
  scope notes, and requests for CI-green heads with no builder approval. Its
  rows are the lane's second input. A follow-up ticket moves those jobs and
  then retires it.
- The request rows stay an input because the gate facts were empty in
  production on 2026-10-10 04:10Z (`pr_needs_review` rc 2 for cromford).
  A lane that read only the worklist would stop every lead review.
- `bin/lib/review-pool.sh` is the dispatcher. It was not rewritten on `wait -n`.
- `one <request-id>` (the in-build review) has no worklist and no limits.

## How to read the before/after count

Run on a box with the harness, as of a stated time:

```bash
. /root/harness/bin/jobs-client.sh; . /root/harness/bin/lib/lead-reviews.sh
pr_needs_review example-org/cromford | wc -l
lr_get '?status=requested,running&repo=example-org/cromford' | jq '.requests|length'
```

The first number is the worklist length, the second the open request backlog.
After the change both fall as the lane drains them. `grep ' tick seen='
logs/lead-review.log | tail` shows `started=` above 1 per tick when there is
work.

## Operator step

The settings row `lane.lead-review.lead_review_max_per_tick` is an orphan now.
Nothing reads it, and it can be deleted.
