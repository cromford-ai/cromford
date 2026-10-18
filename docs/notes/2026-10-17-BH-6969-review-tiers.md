# Outcomes by review tier in the DORA digest (BH-6969, wave 3 of #6544)

Doc: DORA

## What changed

The daily DORA digest (`bin/dora-digest.sh`) has a new `review` block,
`fleet.review` in `state/dora/<date>.json` and `review ...` lines in
`state/dora/latest.txt`. Over the window it counts PRs by review tier and mode,
verdict flips, reverts and main-red culprits by tier, and review $ per PR by
tier (from `state/cost/cost-per-pr.csv` joined on PR url). The counting is the
new pure module `bin/dora_review.py`.

The rows come from a new read-only, bearer-gated worker route,
`GET /api/metrics/review-tiers?days=N` (`worker/jobs/src/routes/review-tiers.js`,
fragment `worker/jobs/test/route-table.d/bh-6969-review-tiers.txt`). It makes
four indexed reads in one `Promise.all`. The schema fragment
`worker/jobs/schema.d/202610181831-bh-6969-review-tiers.sql` adds
`idx_outcome_created ON outcome_metrics(created_at)` and seeds the settings row
`review.tier_revert_margin` = `0.02`.

One new alert, `[dora-review-tiers]`: once a UTC day, when the low or intent
cohort's 7-day revert rate is more than `review.tier_revert_margin` over the
full cohort's. The rules are in docs/DORA.md, "Review block (BH-6969)".

## Why

BH-6967 made the review tier and mode a column of every verdict row. This block
answers whether the cheaper reviews (the low-tier sign-off, the intent review)
let through more reverts than a full review.

## Rollout

The block reads `n/a (... http=404 ...)` until the next worker deploy
(`bin/harness-sync.sh`) adds the route and applies the schema fragment.
Nothing pages before then.
