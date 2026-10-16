# BH-7118: the lead-review enqueue carries a verdict across a schema restamp

Doc: none

## Why

#7012 reached `LEAD_REVIEW_MAX_PER_PR_DAY=4` on 2026-10-16. Two of its four
lead reviews were for heads that only renamed its schema.d fragment to a new
stamp (the merge conductor's restamp commit, `bin/lib/schema-restamp.sh`).
No SQL changed.

The conductor already carried a lead MERGE across a restamp (`lead_carry`,
BH-6842). The enqueue did not. `ld_classify` (`bin/lib/lead-delta.sh`) saw the
renamed fragment as a protected path in the own delta, so it never asked
`patch_same`, and it answered `delta ... protected:worker/jobs/schema.d/...`
(after a lead MERGE, within `LEAD_DELTA_PROTECTED_MAX_LINES`) or
`full protected:...`. Both buy a lead review.

## What changed

- `ld_classify` asks `restamp_same` before the protected-path loop. When it
  proves the head (every commit after the reviewed head is a restamp or a clean
  main merge, with at least one restamp), the class is `replay restamp`. The
  three callers (the enqueue's inline replay, gate 50 and `lw_replay`) already
  treat any `replay <how>` as a carry. If the lib does not load or
  `restamp_same` refuses, the class is what it was before.
- `bin/lead-verdict.sh post`: when the note holds a `lead-replay:<sha>` token,
  the `lead-verdict` status description ends with `, carried from <sha>`.

A one-line code change, a fragment byte change, a conflict-resolved main merge
or a force-push (the reviewed head is not an ancestor) does not carry.
`tests/lead-delta-restamp.bh-7118-test.sh` pins each case.

## The #7012 probe (from the plan)

With main pinned at the last main commit before 2026-10-16T09:00Z:

- `restamp_same R $M 7c83c5266d0a d031cedf224f` -> `restamp`, rc 0 (the 06:39Z restamp).
- `restamp_same R $M 0aa758383018 d932a39e51ea` -> `restamp`, rc 0 (the 09:39Z restamp).
- `restamp_same R $M d031cedf224f 0aa758383018` -> rc 1 (the 08:24Z test-setup line).

## Cache caveat

`state/lead-review-enqueue/delta.tsv` keeps a class for up to 7 days. A
(reviewed, head) pair classified before this change keeps its old protected
class. Each restamp makes a new head, so only pairs already reviewed are
affected.
