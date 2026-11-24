# BH-9944: the design-collision check reads each open PR one time

Doc: RUN-BUILD-GRAPH

## Cause

On 2026-11-23 the PLAN stage of `cromford` hit its cap on most builds:
BH-9268 after 23,526 s, BH-9312 after 21,682 s, BH-9908 after 14,808 s,
BH-9923 after 13,540 s, BH-9438 after 13,301 s, BH-9935 after 8,015 s. Every
`pipeline.log` had the same gap between `plan gate: shared files` and
`design collisions:`. BH-9438 had a pre-plan hit, so no model call ran in its
3 h 35 min gap. On pool machine `85d506b4e5d648` (BH-9933) the process list
showed `bin/plan-collisions.sh` at 8,908 s, in one whole-tree `git grep`.

`pc_pr_hits` (`bin/lib/plan-collisions.sh`) called `pc_hit` for every symbol
and every open PR: up to 40 symbols times 51 PRs. One `pc_hit` call runs 2 to 4
whole-tree `git grep` calls (`pc_locate`) and one `git log -G`. That is about
4 s on a `shared-cpu-2x` machine, and about 2,000 calls.

## Change

- `_pc_pr_text` reads one PR one time: the patch of every commit in
  `merge-base..head`, and the content at the head of every file the range
  touches (each commit's file list plus the net diff).
- `pc_pr_hits` calls `pc_hit` for a symbol only when its name is in that text.
- The rows do not change. A changed body needs a commit in the range that
  touches the file of the definition at the head, and that file is in the text.
  A removed, renamed or moved definition has its line in a patch. A text match
  is a patch line that holds the name.
- If the range or a name list cannot be read, the PR gets the old loop. A
  `grep` read error on the text sends the symbol to `pc_hit`.
- Knob `PLAN_COLLISION_PREFILTER` in `catalog/lanes.d/_lib.design-collisions.knobs.d/`
  (default 1; `0`, `false`, `no` or `off` gives the old loop).
- `bin/plan-collisions.sh` writes one line to stderr, which the plan stage
  appends to `pipeline.log`:
  `plan-collisions: open PRs read=<n> prefilter=<0|1> pc_hit calls=<c> skipped=<s>`.

## Test

`tests/plan-collisions-prefilter.bh-9944-test.sh`: 6 PR refs and 8 symbols. The
rows with the pre-filter on are byte-equal to the rows with it off. The cases
are a changed body whose patch does not hold the name, a removed function, a
function moved to a new file, a route text match, a body changed and changed
back, and a PR that touches no symbol (0 `pc_hit` calls).

## After deploy

In the `pipeline.log` of the next `cromford` plan, the time between
`plan gate: shared files` and `design collisions:` must be under 10 minutes,
and the `plan-collisions:` line must show `skipped` above `calls`.
