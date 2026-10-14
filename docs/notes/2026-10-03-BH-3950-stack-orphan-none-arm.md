# A stacked child whose parent has no PR is retargeted, and an orphan retarget owes a re-review (BH-3950, part 3 of BH-3943)

Doc: MERGE-CONDUCTOR

## What changed

`bin/merge-conductor.sh`'s stacked block has a `NONE` arm. `NONE` is what
`stack_parent_memo` answers when no PR exists on the child's base branch, and
until now no arm read it, so the child waited for ever. The arm:

- reads what the parent list read actually said. `mc_stack_parent` keeps its
  stdout (`NONE` for a failed read and for an empty list alike) and now also
  writes the real answer to the file `MC_STACK_PARENT_ANS` names: `none`,
  `HTTP <status>`, or `unparseable`. The arm goes on only on `none`; anything
  else, or no answer at all, keeps waiting and logs `UNVERIFIABLE` once per
  head. No second list read is made, so the per-tick read count is unchanged.
- probes the base branch (`mc_branch_exists`, `GET repos/<slug>/branches/<b>`:
  rc 0 present, 1 404, 2 unreadable). It goes on only when the branch is gone,
  or when it is still there and the row has been `STACKED_WAIT` longer than
  `mc_ttl STACKED_WAIT` (`MC_TTL_STACKED_WAIT`, default 6h).
- asks `open_pr_for_key` (`bin/lib/open-pr-precheck.sh`, BH-3948) whether the
  parent ticket has an open PR under the other head shape. Open or unreadable
  keeps waiting.
- runs the CLOSED arm's orphan path: `mc_orphan_clean`, then the retarget and
  CI kick (`stack_orphan_retarget`, now shared by both arms), or the
  `orphaned-child` hand-off to `bin/blocked-resolver.sh`. For a gone branch,
  `mc_orphan_clean` takes a new sixth argument `0` that skips the "carries the
  parent's commits" half, since there is no parent ref left to read. A success
  logs `RETARGETED <key> base <old> -> <base> (parent: none, branch gone|ttl)`.

Actions mode only; `MC_ORPHAN_RETARGET=0` parks it, as for a closed parent.

A retarget off a CLOSED-unmerged or PR-less parent now owes a head-bound
re-review. After the PATCH the conductor writes `rtreview <key> <head>` to the
attempts ledger and logs `retargeted off closed parent - re-review owed`. Until
a claude head-bound read of that head, bought AFTER the retarget, APPROVES
(recorded as `rtcleared <key> <head>`), the row is held on `WAIT_REVIEW` with
that reason, ahead of the classifier. `mc_prov_cleared` does not release it: a
retarget leaves the head where it was, so a `provcleared` row or a lead/human
MERGE on it can predate the retarget and judged the diff against the dead
parent. The read is
bought through `headbound_review provenance`, the detached job that runs
`mc_rereview`, with its CI-green, budget, cap and call-guard checks. A BLOCK
parks `head-not-reapproved` for the resolver. The MERGED arm is unchanged and
owes nothing. Kill flag `MC_RETARGET_REREVIEW=0`
(`catalog/lanes.d/_lib.mc-stack-orphan.json`, default 1) restores the old
"keeps its review".

## Why

project-4 #1778 (head `ticket/TK-2103`, base `agent/TK-2102`) sat in STACKED_WAIT
for 4.6 days: nothing ever opened a PR on `agent/TK-2102`, and the stuck
detector paged the row every tick while nothing acted.

The review reversal: a child's review was of its diff against the parent's
branch. Once the parent closes unmerged, or never existed as a PR, that diff on
the project base can hold commits no reviewer read, so the old review is not
evidence for the merge.

## Known limits

- A row whose head is DIRTY/CONFLICTING is not held. The rebase path owns it,
  and the rebased head is a different head with no `rtreview` marker.
- The re-review is not bought on the retarget's own tick. The CI kick has just
  fired, and the review waits for green anyway.

- A head that already had a detached re-review job (or a consumed one) when
  it was retargeted is marked `rtpreread`. That job is one per (PR, head) and
  cannot be bought again, so the row stays held on `WAIT_REVIEW` (and pages on
  its TTL) until a push gives it a new head, which HEAD_MOVED re-reviews.
- With `MC_RETARGET_REREVIEW=0` a NONE parent's gone branch is NOT judged on
  the conflict half alone (`carry=0` needs the re-review to read the parent's
  commits); the full check runs and parks it `orphaned-child`.
- A parent rebuilt as `ticket/<key>-rN` with an open PR keeps the child
  waiting (`mc_retry_pr`, the CLOSED arm's probe); `open_pr_for_key` only sees
  `agent/<KEY>` and `ticket/<key>`.

## Where

`bin/merge-conductor.sh` (NONE arm, `stack_orphan_retarget`, the owed-review
gate), `bin/lib/mc/rebase.sh` (`mc_stack_parent`'s answer file, `mc_branch_exists`,
`mc_stack_parent_key`, `mc_parent_pr_open`, `mc_orphan_clean` carry). Suite:
`tests/merge-conductor-stack-orphan.bh-3950-test.sh`.
