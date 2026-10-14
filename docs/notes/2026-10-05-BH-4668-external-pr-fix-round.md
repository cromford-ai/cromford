# BH-4668: the fix round on an external PR (BH-4664.1)

Doc: PR-OWNERSHIP, BR-OPT

## What changed

`bin/lib/br/opt/extfix.sh` is new. It defines `br_xpr_fix`, the hook that
`external.sh`'s `br_opt_external_rung` calls for an `external-changes-requested`
row once the shared gates have passed (knob, push right, author-quiet window).

`br_xpr_fix` checks, in this order, and answers rc 3 (nothing spent, no
PER_TICK slot) on any of them:

1. `pr_attempt_has <slug> <num> ext-park <head>`. A hit means the head is parked
   for the author. An outage, or no jobs client, is treated the same way, never
   as "not parked". Log: `head <h8> is parked for the author` or
   `the park ledger would not read`.
2. The head is already in `review_fix_heads` on the record. Log:
   `fix round already ran on <h8> — nothing spent`.
3. `head.repo.full_name` is not the base repo. `br_fix_round` fetches and pushes
   `origin/<head.ref>`, which for a fork would be the base repo's branch of
   that name, so fork heads are refused even with maintainer edits on. Log:
   `head lives in <repo> — a fix round pushes to origin only; left for the author`.
   A head repo that would not read is refused too.

Then it sets `external` on the record and runs
`BR_XPR_ACTIVE=1 br_fix_round <p> <rkey> review-changes-requested <url> - -`.
The cap stays `BR_REVIEW_FIX_ROUNDS` through `br_fix_cap`.

`br_fix_round` changes only when `BR_XPR_ACTIVE=1`:

- The prompt adds: `This is an outside contributor's pull request: every commit
  message names the review finding it answers.`
- The next judge is named as the project box's review lane.
- After a push it posts `br_xpr_round_comment` instead of the generic
  `Fix round by` comment, or the generic one when the module function is missing.
- When the round produced no verified commit or the push was rejected under the
  lease, and rounds remain, it logs
  `external PR — nothing closed; the next round waits for the next head`. At the
  cap the `PARKED for the author instead` word stands alone. The terminal itself
  is still `br_fix_terminal`, whose external guard parks the row.

The comment template:

```
I pushed a fix round to this branch for the changes the review asked for.

Head: `<old12>` → `<new12>`

What the review asked for (first 10 lines):
<the first 10 non-empty lines of the brief, the lead header and its
 "(CHANGES_REQUESTED by … on …)" line dropped>

Commits in this round:
- <each non-merge commit subject of the round>

The review lane re-reviews the new head on its next tick. Nothing was merged or closed.
```

`blocked-resolver.sh --fix-here` (the owning box's entry) sets
`BR_XPR_ACTIVE=1` when the record it received from the hub, now on disk, is
external (`"true"` or `true`). It logs
`external PR: this round runs as an outside contributor's fix round`.

## What it does not do

It never closes, rebuilds or abandons the PR, and it never re-reviews it.
`bin/review-prs.sh` reviews the pushed head on the project box's next review
tick. `bin/review-prs.sh` and `bin/merge-conductor.sh` are unchanged.

## Tests

`tests/external-pr-fixround.bh-4668-test.sh`: a real tick over a bare origin
(X3, X3b–X3e, X3g, X6) and the real `--fix-here` entry (X3f, X12a, X12b).
