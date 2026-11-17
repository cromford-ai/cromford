# BH-7921: run-build on the tracker contract (slice C0)

Doc: VERIFICATION-MAP

## What changed
- New lib `bin/lib/rb-tracker.sh` (`rbt_*`): the run-build seam onto
  `bin/lib/tracker.sh`.
- For a project whose `tracker_kind` is `jira` or `linear`:
  - the closed-ticket skip (`gates.d/closed-issue-skip.sh`) reads the ticket
    and refuses a closed one (`BUILD_REFUSED SKIP_CLOSED`);
  - `TICKET_FP` and `TICKET_META` read the ticket through `tracker_read`;
  - the plan ambiguity rule keys on `tracker_kind` (jira and linear are
    assumption-forward, as before; a board row asks);
  - `escalate_block` posts the BUILD BLOCKED notice with `tracker_comment`;
  - the PR is linked on the ticket, and the ticket moves to review;
  - `CLOSE_ISSUE_AFTER_MERGE` posts the merge comment and moves the ticket to
    done, except on a REFUTED claim or a `SLICE:` plan.
- Every harness write that a resume can see runs inside `rbt_own_write`,
  which refreshes `$BUILD/ticket-fp` when the only turn since the plan is ours.
- GitHub-issues and board projects are unchanged.
- The Jira and Linear sections of `docs/connecting-a-board.md` and
  `docs/guide/03-connectors.md` now say what a build does on the ticket, and
  that hold labels, merge-queue merges and blocker reads use GitHub only.
- `tests/docs-connectors.bh-7924-test.sh` N6 strips the `tracker_kind` route
  from its own fixture copy of `pr.sh`, so it still proves D6 goes red on an
  unrouted `pr.sh` now that the checkout is routed.

## Why
PR #8655 (the first C0) closed on a data-loss BLOCK: a resumed Jira or Linear
build went PLAN_STALE on its own BUILD BLOCKED comment. Comment 6522650545
asked for the fingerprint fix and a resume test (L8-L10, J5, J7).

## Status
Built, not yet exercised live. C4 is the live proof on the sandbox.
