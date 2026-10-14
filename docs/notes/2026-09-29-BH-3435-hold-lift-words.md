# A lift word opening a comment lifts a hold; an ambiguous comment on a held ticket alerts (BH-3435)

Doc: resolver-hold

## What changed

project-5 #3354 stayed on HOLD for about 15.6 hours after the operator wrote
"RELEASED (the operator, 2026-09-28). Proceed on the decision in #3348 … This
supersedes the HOLD." `bin/lib/hold.sh` lifted only on capital `RESUME` /
`UNHOLD` or a "release the hold" phrase, so the capital `HOLD` in that
sentence read as a fresh hold. Nothing reached an operator.

- `HOLD_LIFT_LEAD_RE` (exported): the first word of a comment, after
  whitespace, any case: `resume`, `release`, `released`, `unhold`, `proceed`,
  not followed by a letter, digit, `_`, `-` or `?`. It is asked before the
  abandon and hold tests, so `HOLD` later in the comment never re-holds. Behind
  a negation (`HOLD_NEG_RE`) it is neutral: no lift, no hold.
- Comments that do not open with a lift word are judged exactly as before.
- Bots still never lift. A comment carrying `<!-- harness:hold-ambiguous` (the
  note below) is skipped in both directions.
- `hold_ambiguous` (pure): a ticket held by a comment, the title or the body
  whose newest person comment is neutral. `hold_ambiguous_note`, called from
  `hold_check` and `hold_read` when the verdict is held: per-box `mkdir` claim
  `state/hold-ambiguous/<owner>__<repo>-<n>-<id>`, the `hold_ambiguous`
  ledgers row (`<slug>#<n> <id>`) checked across boxes, then
  `bin/lane-alert.sh --severity warn --id hold-ambiguous:<slug>#<n>:<id> hold …`
  quoting the first line, the ledger row written, then one ticket comment
  naming the five lift words. A failed alert drops the claim and posts nothing.
  No `HARNESS`/`H` root means no writes. The verdict line and rc are unchanged.
- `bin/launch-fastpath.sh` reads `HOLD_LIFT_LEAD_RE` and skips the marker.

Not changed: PR-thread holds (`hold_classify_thread`), and
`bin/orphan-reconcile.sh`'s python fallback (used only without the lib).
