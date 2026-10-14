# A BLOCKed parent PR with approved children gets the next fix round (BH-5741)

Doc: MERGE-CONDUCTOR

## What changed

`bin/lib/br/opt/parentprio.sh` is a new optional module of
`bin/blocked-resolver.sh` (the BH-1468 seam). It has two hooks.

- `br_opt_parent_children` runs in `br_rank_rows` for each plain row. A row is
  a parent when its reason is `review-changes-requested` or
  `head-not-reapproved` and it has open approved children. A child is an open,
  non-draft PR in the same repo whose base is the parent's head branch. A child
  is approved when `mc_verdict` answers `APPROVE` bound to the child's current
  head, to `-`, or to the reviewed sha in the child's `pr-state.tsv` row for
  that same head.
- A parent ranks 3. `br_rank_rows` now doubles `priority_rank_meta`: 0 hotfix,
  2 main-red, 4 plain. So a parent goes after hotfix and main-red rows and
  before every plain row. The lane logs one line per promoted row:
  `<p>/<rkey> [<reason>]: PRIORITY parent — <n> approved child PR(s) wait on its branch (#a #b)`.
- `br_opt_parent_wait` runs once per tick after the dispatch loop. It keeps
  `state/blocked-resolver/.parent-wait.tsv`, one row per parent:
  `<p> <ck> <url> <first_seen> <fixrounds_at_first_seen> <alerted>`. When a
  parent has waited `BR_PARENT_WAIT_ALERT_MIN` minutes (default 120) with no fix
  round, it sends ONE line through
  `lane-alert.sh --id parent-blocked-children-<p>-<ck>`. The line starts
  `[blocked-resolver] PARENT BLOCKED`.
- A fix round counts as started when the record's `fixrounds` rose (the clock
  restarts) or when `fix_round_get` answers `queued`, `claimed` or `done` (no
  alert). A queue that does not read still pages, and the line says so.
- A held project gets no alert. Observe mode still alerts, as STARVED does.
- A row is pruned when its parent leaves the candidate stream of a project the
  tick saw. A parent seen with 0 approved children keeps its row unchanged.
- `br_open_prs` asks for `baseRefName` too. The per-tick cache that
  `br_from_reviews` fills answers the module, so a normal tick makes no extra
  GitHub call.

## Why

On 2026-10-09, 16 approved PRs waited outside the merge queue on 9 unmerged
parents. 4 of those parents had a lead BLOCK that no fix round picked up
(#4942 with 4 children, #4908 with 2, #4761, #4332). A person cleared them by
hand.

## Knobs

- `BR_PARENT_WAIT_ALERT_MIN` (`catalog/lanes.d/blocked-resolver.json`): int,
  default 120, 0 = no alert. A non-number falls back to 120 with one log line.
- `BR_OPT_OFF=parentprio` turns the whole rule off. The lane then ranks and
  pages exactly as before.

## Not changed

The fix-round claim priority (`hot`, the `hotfix` field of
`fix_round_enqueue`) is not given to parents. That flag puts a round above
main-red, and the ticket says below.

Tests: `tests/parent-blocked-priority.bh-5741-test.sh`.
