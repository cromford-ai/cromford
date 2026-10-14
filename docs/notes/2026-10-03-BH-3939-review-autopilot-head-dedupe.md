# The review autopilot stands down on any head-bound verdict but the builder's (BH-3939)

Doc: CALL-GUARD

## What changed

`bin/review-autopilot.sh` (a slice of BH-3930) now sources
`bin/lib/review-bought.sh` and asks it, before the paid call, whether a verdict
is already bound to this exact head:
`review_bought <slug> <n> <40-hex sha> --except-builder`.

- rc 0: any verdict on this head except the builder's own (review-prs,
  mc-rereview, the lead; a BLOCK counts as much as an APPROVE). The lane writes
  `skipped <stamp>: <source> verdict <WORD> bound to this head (ledger)` to the
  key, a `review_autopilot` row and a `review_skip_unchanged` line in
  `logs/review-autopilot.log`, and buys nothing.
- rc 1: one `review_dedupe unreadable` line, then the old path.
- rc 2: the old path (`state/<p>.pr-reviews.json`, then the review).

The `verdict_single_home` flag and the `source=review-prs` filter no longer
gate this block. `REVIEW_DEDUPE=0` (settings row `lib.review-bought.review_dedupe`)
skips the read.

The paid call is now claimed as `review:<slug>#<n>@<sha>` on guard stage
`review-head` (K=1), the same key every review lane uses on that head. It used
to be `review-autopilot:<slug>#<n>@<sha>` on `review`. The positional stage
stays `review`, so cost rows and the model route are unchanged.

## What it does today

`review_bought` is still the BH-3937 stub that always answers rc 2, so the
skip never fires until the real reads land in a BH-3930 sibling. The fp and
`review-head` K=1 apply now.

Probe: `grep -c review_skip_unchanged logs/review-autopilot.log` (0 until the
reads land). Proof: `tests/review-autopilot-dedupe.bh-3930-test.sh`.
