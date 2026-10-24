# BH-7816: the lead review does not review a head that conflicts with fresh main

Doc: LEAD-REVIEW

## Cause

Three lead BLOCK verdicts (1533 on #5864, 1879 on #5990, 2330 on #6648) were
for conflicts that main caused. Another ticket rewrote the same lines while the
PR waited. The request-time rebase hold (BH-5796,
`bin/lib/lead-gates.d/85-rebase-hold.sh`) runs `git merge-tree` on the clone
before the review fetches, and GitHub's `mergeable_state` lags a main merge.
The lead review then fetched a fresh `origin/<base>`, reviewed the head, saw
the conflict and answered BLOCK. The PR was charged with that BLOCK, a fix
round started, and the paid review bought nothing.

## What changed

- `bin/lib/lead-review/fresh-conflict.sh` (new module, `fresh-conflict` in
  `bin/lib/lead-review/MODULES`): after the fetch, `git merge-tree
  --write-tree` of `origin/<base>` and the head. A conflict ends the request
  `superseded` with the detail `needs rebase: conflicts with origin/<base> in
  <paths>` (5 paths, then `(+N more)`). No verdict, no agent call.
- `bin/lead-review.sh`: one call block between the fetch and the console qa
  gate.
- Only the lane's own requests are held (`requested_by`
  `lead-review-enqueue:*`, `lead-review-worklist`, or `src` `worklist`). A
  person's request is reviewed, the same rule as the patch-same replay.
- Anything that cannot run (no `origin/<base>`, no head object, a merge-tree rc
  other than 0 or 1) fails open: the head is reviewed.
- A failed result post leaves the job for the watchdog and logs no supersede.

## The next tick

The fetch updated `origin/<base>` in the clone. The next tick's
`lg_gate_rebase_hold` runs the same `merge-tree` on it, holds the head with a
`[skip rebase]` line and starts no request. The conductor's rebase or a fix
round makes a new head, and that head gets an ordinary review.

## Knob

`LEAD_REVIEW_FRESH_CONFLICT_HOLD` (lead-review lane, default 1). Set it to 0
to review a conflicting head as before. A value other than 0 or 1 is logged
once and read as 1.

## Out of scope

- A head that duplicates a change already on main (BH-5802 `dup_main_pr`
  gives the lead a note).
- Main that moves during a review.
