# The lead call's guard key names a changed PR body (BH-5888, re-plan 2)

Doc: OPERATING

## What happened

PR #5987 made the lane review a body-only edit on the same head again. But the paid call still
carried the K=1 guard key `lead:<slug>#<n>@<sha>` on stage `lead-head`. The guard allows one paid
call per key in 86400 s. So `agent-call.sh` refused the second call with rc 74, and the lane logged
`agent-call refused <key> (rc=74, nothing billed); request left for the next tick` every tick for
24 hours. The body-only BLOCK did not clear.

Evidence from `logs/call-guard.log` on the builder box: `REFUSED [cromford] lead-head
fp=lead:example-org/cromford#5454@40b03490... paid=1/1 in 86400s` at 2026-10-11 17:55:04Z and
19:34:32Z, and two refusals for #5273 on 2026-10-09. These show the guard refusing a second lead
review of one head. They do not prove a body edit on those two PRs.

A second defect: for a request that was reset after the edit, the BH-5793 loop deleted the old
report before the BH-5888 body check read it. The lane lost the fact that the body changed.

## What changed

1. `lr_body_reason <bfp> [nv]` in `bin/lib/lead-reviews.sh` returns `body<D>` (or `nvbody<D>`).
   `<D>` is the decimal of the first 12 hex of the body fingerprint. Decimal, because
   `bin/review-paid-unchanged.sh` strips trailing digits from a reason, so the ledger groups
   these as the exceptions `body` and `nvbody`.
2. `review_one` in `bin/lead-review.sh` sets `bchg=1` when the artifact or the disk report names
   another body. The disk check now runs before the BH-5793 loop.
3. With `bchg=1`, the paid call's key is `lead:<slug>#<n>@<sha>~body<D>`, and the unknown-verdict
   retry is `~nvbody<D>`. The lane logs `body changed since the stored review of <key>; guard
   key <fp>` to `logs/lead-review.log`.
4. With no body change seen, the keys are `lead:<slug>#<n>@<sha>` and `~noverdict`, as before
   (BH-3930).
5. One head and one body has one key, so it is never paid twice.

Test: `tests/lead-review-guard-body.bh-5888-test.sh`. Its stub `agent-call.sh` refuses a key it
already paid, as the guard does.

## Not changed

- A reset with an unchanged body still gets rc 74 on the same key (BH-5793 vs BH-3930).
- A body change where neither the disk report nor the artifact survives keeps the plain key. The
  lane cannot see the change.
- The `.empty` marker is not bound to the body.
- B1 to B2 and back to B1 on one head pays a third time. `LEAD_REVIEW_MAX_PER_PR_DAY` bounds it.

No knob, worker, schema or deploy change.
