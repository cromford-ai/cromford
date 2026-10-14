# A red-CI park merges main once more before the resolver buys an agent

Doc: MERGE-CONDUCTOR

BH-968 shipped the contract half of the regenerate rung: `mc_regen_table` in
`bin/lib/merge-conductor-lib.sh` and a `BR_REGEN_RUNG` default in
`bin/blocked-resolver.sh` that nothing read. This is the rung itself.

Before it, a `ci-red` park whose mechanical rung was spent went straight to the
agent fix round. The commonest red CI in this repo is a GENERATED file that main
has since moved — `docs/verification-map/README.md` is the loud one — and 12 of
the open PRs in the #950 census were parked exactly there, each of them about to
pay for an agent call to do what one more merge of `origin/main` does for free.

## What the lane does now

Between rung 1 (mechanical) and rung 2 (the fix round), a `ci-red` park is
offered ONE more `mc_rebase` on its current head.

**What it regenerates today: nothing.** #969 is the slice that teaches `mc_rebase`
to run `mc_regen_table`; until it lands this rung is a plain re-merge of
`origin/main`, and its value is the ordinary drift a second merge clears. It is
still free and tokenless, and a park with nothing to merge records `regen-noop`
and takes its ladder answer in the same tick — but it does cost one clone, fetch,
merge and hub gate per distinct head. The rung ships ON (`BR_REGEN_RUNG` default
1) because the #968 contract pins that default and
`tests/merge-conductor-lib.bh-968-test.sh` asserts it; `BR_REGEN_RUNG=0` is the
switch for a lane that does not want to pay that until #969 lands.

- `br_regen_ladder <class> <ladder-action>` turns the ladder's own answer into
  `regen` for the `ci-red` class only. `review-blocked` has posted findings a
  merge answers nothing about, `orphaned-parent` needs its parent's commits taken
  OUT, and a `rebase-conflict` park has already had this exact merge refused at
  rung 1 — all three pass straight through, as does `mechanical`.
- `br_regen_rung` is the body. A regenerate that pushes records `regen` with
  `head8=<head>` in its detail and bumps `regens`; CI then runs on the new head
  and the conductor judges it. A regenerate that lands nothing (nothing to merge,
  a conflict, a red hub gate) records `regen-noop`, bumps nothing, and dispatches
  the displaced ladder answer IN THE SAME TICK — this rung can cost a merge and
  never a tick.
- `mc_rebase` rc 4 is `br_setup_blocked` with the rung name `regen`: a fact about
  the box, nothing spent, nothing cascaded, one page per episode.
- Bounded twice, and the two bounds are NOT the same bound. `br_regen_offered`
  (the head8 dedup) is what bounds `mc_rebase` CALLS: at most one per ticket per
  distinct head. `regens >= BR_MAX_REGEN` (default 1) bounds LANDED regenerates,
  because `regens` is bumped only by an arm that pushed (rc 0/5 with a new head)
  or handed the branch to the pool (rc 6) — a `regen-noop`, a conflict, a
  rejected lease and a setup failure spend nothing by design, so a later head
  deserves the free merge again. Read together: a ticket can ask `mc_rebase` once
  per head it ever shows, and land at most `BR_MAX_REGEN` of those.
- The rc-6 arm (the pool took the rebase) counts as a landed regenerate and
  pushes the conductor row to `REBASING`, the same way rung 1's own rc-6 arm
  does, so the next tick does not buy a fix round on a branch a pool machine is
  rebasing right now.

## Knobs and state

- `BR_REGEN_RUNG` (default 1, pinned there by the #968 contract test) — `0`
  restores the pre-BH-950 dispatch exactly; `br_ladder_rung`'s outputs are
  untouched either way.
- `BR_MAX_REGEN` (default 1) — regenerate PUSHES per ticket, not `mc_rebase`
  calls. Both knobs are in `env-templates/global.env.example`.
- Observe mode answers before the PR is read (`br_mechanical`'s own order), so a
  dry run of this rung costs no GitHub call; its line names the conditions it
  could not check rather than claiming the rung would certainly be taken.
- `state/blocked-resolver/<project>/<key>.json` gains `regens`. Records written
  before this change have no such field and `br_num` reads them as 0; there is
  no migration.

Driven by `HARNESS_TEST_SANDBOX=1 bash tests/blocked-resolver.bh-950-test.sh`
(the ticket's own path) — the rung, the once-per-head dedup, the same-tick
dispatch of the displaced answer, the dispatch table including
`BR_REGEN_RUNG=0`, observe mode, the setup arm, the pool (rc 6) arm, and the
per-ticket bound.
