# A newer human MERGE on the exact head overrides the conductor's own re-review BLOCK (BH-3814)

Doc: MERGE-CONDUCTOR, BLOCKED-RESOLVER

## What happened

project-4 #1815, 2026-10-01. The detached head-bound re-review of `94fafc78`
returned BLOCK at 16:04Z. Its only finding was body-only. At 16:19Z a human
recorded `MERGE-WITH-NOTES` on that head (`bin/lead-verdict.sh post … --source
human`, verdict #366). At 16:33Z the conductor consumed its own BLOCK, parked
the row `BLOCKED_HUMAN head-not-reapproved` and handed it to
`bin/blocked-resolver.sh` for an agent fix round. Nothing on that path read the
verdicts table, so verdict #366 was ignored and the PR was queued by hand.

## What changed

- **One judge, `mc_hv_override <key> <head>`** (`bin/lib/mc/classify.sh`).
  rc 0 when a `lead` or `human` `MERGE`/`MERGE-WITH-NOTES` row stands on this
  exact head (`vd_standing`) and its `created_at` is strictly newer than our
  BLOCK of it. The BLOCK time is the re-review job's `finished_at`. With no job
  file (a resolver re-review BLOCK, the autopilot's, a job gc'd after 3 days) it
  is the hand-off record's park time, used only when that record names this
  head. rc 1 for no row, a BLOCK row, a `box` row, an older or same-second row,
  or an unknowable BLOCK time (logged). rc 2 when the verdicts table cannot be
  read. Once applied, an `hvoverride <key> <head>` attempts row keeps the answer
  rc 0 for that head, unless a later human BLOCK replaces the MERGE as standing.
- **At the moment the BLOCK is consumed** (`headbound_review`, `done` arm), an
  rc 0 rebinds the approval through `hb_approve_bind` instead of
  `hb_block_park`. The findings still post, under a footer naming the human
  verdict. No `hbrefused` row, no hand-off. The row goes `WAIT_REVIEW` with the
  reason `human verdict #<id> overrides re-review BLOCK on <sha8>; reclassify
  next tick`, and the next tick classifies it (READY when CI is green and the
  merge state is CLEAN). `hb_approve_bind` takes that reason as an optional
  12th argument; every other caller keeps its old reason.
- **A row already parked `head-not-reapproved`** is re-checked inside the
  sticky hand-off block of `bin/merge-conductor.sh` each tick (actions mode
  only). On rc 0 the `hbrefused` row is cleared, the park is released
  (`mc_handoff_release … human-verdict`), the approval is rebound and the row
  goes `WAIT_REVIEW` with the same reason. One `vd_standing` GET per such row
  per tick.
- **The resolver refuses the fix round** (`br_one` in `bin/blocked-resolver.sh`,
  after the merged guard and before the carry seam). For a `review-blocked`
  reason it asks the same judge on the parked head. rc 0 logs `human verdict
  #<id> … no fix round` and returns rc 3 (no rung, no slot). This matters
  because `br_from_conductor` recovers a hand-off whose row has moved on to
  WAIT_REVIEW or READY on the same head.
- **rc 2 keeps today's behaviour everywhere.** The conductor parks (or keeps the
  park) and is never READY. The resolver logs `the verdicts table could not be
  read … the ladder runs as it did before BH-3814` and runs its ladder.
- **A human BLOCK still beats a lane APPROVE.** No change: the block gate
  (`vd_block_line`) refuses the merge from the READY arm. It is now pinned for
  `source=human` after a head-bound re-review APPROVE (case H6).

## After the human review (2026-10-01)

- **A lead row overrides only where lead authority stands.** For `source=lead`,
  `mc_hv_override` asks `la_decide <slug> <num> <head> lead` last. On a
  protected-path PR (or with lane authority revoked) the lead MERGE is advisory
  (`authority:human-required` in `bin/lead-verdict.sh`), so it is rc 1, no
  override. la_decide rc 2 is a hold (rc 2). No la_decide loaded is rc 1. A
  human row needs no read. Cases L0-L3.
- **The `hvoverride` marker never skips the time comparison.** The newest BLOCK
  time (the job's `finished_at`, else this head's park record) is compared every
  time, so a lane re-review re-run on the same head after an override ends it.
  The marker only answers when no BLOCK time is readable at all. Case V1.
- **A newer human BLOCK beats an older human MERGE**, pinned at the override
  layer (case N1).
- **The resolver re-reads the live PR head** (`br_pr_field .head.sha`) instead
  of trusting the hand-off file. An unreadable head runs the ladder. Case R6.

## Not changed

- If the ledger's own verdict word for the build is BLOCK or CONTRADICTION,
  `mc_classify` still parks `review-block` after the rebind. project-4 #1815 had a
  build APPROVE.
- The autopilot `*)` arm already lets a standing lead/human MERGE win over a box
  row (BH-1525) without comparing times, because a box row never stands.
- Who may post a human verdict is unchanged.

Proven by `tests/mc/human-verdict-overrides-rereview.bh-3814-test.sh`.
