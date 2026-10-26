# The resolver says why a non-harness REQUEST_CHANGES review starts no fix round (BH-8307)

Doc: BLOCKED-RESOLVER

On 2026-10-25 a user posted review 5643798807 on example-org/project-6#2597:
"BLOCK ... VERDICT: REQUEST_CHANGES", no harness footer. `br_from_reviews`
skipped it, which is correct: a user-written review never starts a fix round.
But the skip left no trace, and two sessions waited about 15 minutes for a
round that could not come.

## What changed

- New fragment `bin/blocked-resolver.d/bh-8307-review-skip-note.sh`.
  `br_rsn_pick` takes the newest non-DISMISSED review on the PR's current head.
  When that review asks for changes (state CHANGES_REQUESTED, or a
  `VERDICT: REQUEST_CHANGES` line anywhere in its body, bold allowed) and fails
  `harness_verdict_author_match` or the `BR_REVIEW_FOOTER` check, it is noted.
  The lead-review lane's own marker rows (`<!-- lead-review:`) are never noted.
- `br_rsn_note` writes one line to `logs/blocked-resolver.log` and posts the
  same line once as a PR comment:
  `<p>/<slug>#<n>: review <id> by <login> on <head12> is not a harness verdict (<reasons>) — skipped; request a lead review to start a fix round`.
  `<reasons>` is `author`, `footer` or `author,footer`.
- Dedup: `bin/lib/comment-mark.sh`, ledger kind `commented`, key
  `review-skip <slug>#<num> <review-id>`, token `-`, file
  `state/blocked-resolver/review-skip/<slug with / as _>-<num>-<review-id>`.
  Order is post, then mark. A failed post leaves no mark and the next pass
  tries again. Observe mode logs the line with `(observe mode: not posted)` and
  posts nothing.
- `bin/blocked-resolver.sh`: `br_review_newest` takes an optional 4th arg, a
  file that gets the reviews rows it already read (0 extra GitHub reads).
  `br_from_reviews` calls `br_rsn_note` on its no-candidate exits only. The
  unreadable path (rc 2) never notes. The candidate rows do not change.

## What did not change

The self-approval boundary. The note never makes a candidate. Which review
starts a fix round is decided by `br_lead_pick` and `br_review_harness_pick`
exactly as before.

## Operate

- Turn it off: `BR_OPT_OFF=bh-8307-review-skip-note`.
- Post a note again for one review: `cm_clear "review-skip <slug>#<num> <review-id>" "<marker file>"`.
- Suite: `tests/resolver-review-skip-note.bh-8307-test.sh`.
