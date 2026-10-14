# A MERGE verdict dismisses the bot BLOCK review on the same head (BH-6548)

Doc: MERGE-CONDUCTOR

## What happened

PR #6134 (review 5507427606, head a4127b0b4452) and PR #6321 (review
5507897822, head 3d98fcf7c6c6) each had a green `lead-verdict` status and a
`cromford[bot]` REQUEST_CHANGES review with the `<!-- lead-review:`
marker on the same head. Mergify queues only on
`#changes-requested-reviews-by=0`, so each PR stayed in "Waiting for queue
conditions" for about 1 h, until a person dismissed the review by hand.

## Cause

`bin/lead-verdict.sh post ... MERGE|MERGE-WITH-NOTES` calls `lv_dismiss_stale`
after it publishes the status (BH-5213). That called `lsr_dismiss_stale` with
five arguments, and the jq filter in `lsr_stale`
(`bin/lib/lead-stale-review.sh`) kept a review only when its `commit_id` was
NOT the verdict head. So the tool dismissed the bot BLOCK reviews on older
heads and left the one on the verdict head.

## What changed

- `lsr_stale` has a third mode, `verdict`. In mode `verdict` an own review is
  stale whatever its commit. The third output column says `same` for a review
  on the verdict head. The own-review filter (CHANGES_REQUESTED, the marker,
  `user.type` Bot, a bot login from `lsr_bots_json`) does not change, so a
  person's review is never dismissed.
- `lsr_dismiss_stale ... "" verdict ""` uses that mode. A same-head review gets
  its own message: it names the verdict row, the verdict, the head and BH-6548.
- `lv_dismiss_stale` takes the verdict source. Source `lead` or `human` uses
  mode `verdict`. Source `risk-tier` keeps the older-head rule: a rules
  sign-off did not read the code, so it does not clear a BLOCK on that code.
- Mode `verdict` does not read or write the per-head clean flag
  (`state/lead-stale-review/clean-*`). A re-review can post a new BLOCK on the
  same head after a clean pass, and the flag is per box. The cost is one
  reviews GET per MERGE post.
- Two failure paths that were silent now print one stderr line each: the lib
  does not load, and `mktemp` fails. The post exit code does not change.

What stays the same: a BLOCK post reads and dismisses nothing.
`LV_DISMISS_STALE=0` skips the step. `bin/lead-review-land.sh` step 2d,
`bin/lead-stale-review-sweep.sh` and `bin/pipeline-health.sh` section 13d keep
the older-head rule.

## Retry

If a dismissal fails, the post prints `not all dismissed`, the review ids and
the HTTP status. Re-run the same post to retry. The sweep retries older-head
reviews only.

## Proof

`tests/lead-verdict-same-head.bh-6548-test.sh` drives the real
`bin/lead-verdict.sh post` against a stubbed GitHub and jobs worker. No live
PR review was dismissed by this change.
