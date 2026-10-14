# The blocked-resolver has no terminal that waits on a person (BH-4149)

Doc: MERGE-CONDUCTOR

## What changed

`bin/blocked-resolver.sh`, the last slice of BH-4140:

- `br_fix_terminal` sends `review-changes-requested` to `br_abandon` on the
  cap key. `br_escalate_review` is gone. A review verdict whose fix rounds are
  spent now ends with the PR closed (the comment lists what was tried), one
  `ABANDONED` outcome, one ABANDONED ALERTS line and the
  `blocked-resolver-abandoned` beat. The ticket is re-filed through the board.
- `fix-round-noop` no longer runs `lane-alert` ("a person must act or push").
  It still records the attempt, freezes the head in `noop_heads` and pushes
  nothing, then calls `br_fix_terminal` in the same tick:
  `br_rebuild_fresh` for a ladder reason, `br_abandon` for a review verdict.
- The frozen-head gate in `br_fix_round` calls `br_fix_terminal` instead of
  returning, and it moved above the (PR, head) dedupe, which would otherwise
  return first for a review head. `br_from_reviews` no longer skips a frozen
  head, so heads frozen before this change are finished on their next offer.
- `br_supersede_guard` no longer declines on a lead BLOCK standing on a head
  that is in `noop_heads`. The fix round already ran on that head against the
  lead's findings and answered none of them. Before this, every noop on a
  ladder reason (`head-not-reapproved`, `orphaned-child`, ...) reached
  `br_rebuild_fresh`, was declined on the lead's own BLOCK, and sat behind a
  `SUPERSEDE DECLINED` page asking a person to "decide it". Now it rebuilds
  fresh, and at the rebuild cap it ends ABANDONED. A BLOCK on a head the lane
  never ran a round on still declines, and so does every other verdict.
- The review terminal asks `vd_standing` first (`br_review_cleared`). A lead
  MERGE or MERGE-WITH-NOTES on the PR's head means the conductor merges it, so
  nothing is closed. An unreadable head or verdicts table closes nothing that
  tick and is retried.
- `br_unmapped`'s warn alert no longer says "or declare it human-only". It says
  the reason has no agent rung yet. `hotfix-migration-hold:` rows get one log
  line per window and no alert. That is the production-DB apply gate, and it is
  the one terminal still left with a person.

## Not changed

Records already stamped `ESCALATED` stay terminal (no backfill).
`br_needs_human_park` / HOLD, `br_setup_blocked`, `br_nokey_alert`,
`br_sup_alert`, and the `NEEDS_HUMAN_VERDICT` TTL in `bin/lib/mc/` are as they
were.

Tests: `tests/blocked-resolver-no-person.bh-4140-test.sh`, and section 9 of
`tests/blocked-resolver-supersede.bh-1642-test.sh` (the frozen ladder head).
