# BH-9260: a machine review BLOCK on a READY head becomes a resolver park

Doc: MERGE-CONDUCTOR

## Cause

example-org/project-4-site#4 was READY on a carried lead verdict. On 2026-11-08 at
00:42:58Z the review autopilot posted `[BLOCK core-flow-broken]` on the head
(comment 6715190779). The block gate refused the merge on 22 ticks. It wrote
no row by design (BH-762), so the row stayed READY. `bin/blocked-resolver.sh`
reads only `BLOCKED_HUMAN` and `RED_TWICE` rows, so it saw 0 candidates. No
fix round ran, and the PR waited 15 h for a person.

## Change

`bin/lib/mc/review-block-park.sh` (new, loaded by `bin/lib/merge-conductor-lib.sh`):

- **Park.** In the block gate's refusal branch, `mc_rbp_park` parks the row
  `BLOCKED_HUMAN` with why `review-block: <comment id> <first [BLOCK …] tag> <comment url>`.
  It parks on the same tick only when all of these are true:
  - enforcement is on;
  - knob `MC_REVIEW_BLOCK_PARK` is 1;
  - the CI-block hook (`mc_block_ci_step`) answered rc 2 (declined), or the hook is absent;
  - the comment, read by id, is the review autopilot's BLOCK of this head. Its
    author is the harness's own identity (`harness_own_review_match`: an App
    verdict author or the operator login), and its body carries
    `<!-- harness-review-autopilot <head12> -->` for this head. Both conditions
    apply to every login. Any other bot (`github-actions[bot]`,
    `dependabot[bot]`, a third-party App) is not trusted, because the comment
    becomes the fix round's brief (the BH-1992 verdict-author rule).
- **Not parked.** A person's BLOCK, a stranger or another bot who pastes the marker, a marker for another head,
  `cr-*` and `verdict-*` blocks, and an unreadable body keep the BH-762
  behaviour: READY, refused, waiting.
- **Ownership.** `mc_resolver_owns` and `mc_handoff_owns` accept `review-block*`.
  The row displays `BLOCKED_AGENT`, does not page, and is sticky on its head.
- **Release.** The sticky branch calls `mc_rbp_unpark`. It re-reads the thread
  with `bg_scan_read`. A clean scan, a different newest block, the knob at 0,
  or enforcement off releases the hand-off. The row then classifies READY on
  the same tick. After the resolver releases the hand-off, `mc_rbp_hold` keeps
  the row parked while the block stands, so the row never flips back to READY.
  A new head ends the park through the existing per-head sticky rule.
- **Resolver.** `br_reason_of` maps `review-block*` to `head-not-reapproved`
  (ladder class `review-blocked`, fix round first). The ticket's word
  `rebuild-review-blocked` maps to `abandon-rebuild`, which would end the ticket
  on the first tick. `br_findings` reads the parked comment by id as the brief
  (`mc_rbp_brief`). A failed read is rc 75, so no rung is spent. The hand-off
  recovery loop does not revive a `review-block` hand-off whose row moved on.
- **Alert.** If a machine BLOCK refuses a READY row and the conductor cannot
  park it (the body is unreadable, or the park did not write), one warn alert
  goes out on the first refusal after `MC_REVIEW_BLOCK_STUCK_TICKS`
  (default 2) consecutive ticks. Its id is
  `review-block-unparked:<pr>:<head12>:<comment id>`. The counter is in
  `state/merge-conductor/review-block/stuck-<pr>`.

## Knobs

- `MC_REVIEW_BLOCK_PARK` (int 0..1, default 1). 0 is the rollback. It restores
  BH-762 behaviour, and each existing park releases on its next recheck.
- `MC_REVIEW_BLOCK_STUCK_TICKS` (int 1..288, default 2).

## Tests

- `tests/conductor-review-block-park.bh-9260-test.sh`
- `tests/br-review-block.bh-9260-test.sh`
