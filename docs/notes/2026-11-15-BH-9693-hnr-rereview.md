# BH-9693: another lane's BLOCK buys the conductor's own read before a head-not-reapproved park

Doc: MERGE-CONDUCTOR

Ticket #9693 (BH-9427.1, scope 2 of #9427).

## Why

The conductor parked a moved head as `head-not-reapproved` on sight when
another review lane had a BLOCK bound to it. The >12h review autopilot was the
main source. No read by the conductor ever looked at that head. A PR search
since 2026-11-07 found the autopilot park on 9 PRs (#8979, #9547, #9189, #9137,
#9569, #9381, #9138, #9171, #9317). The same park was posted 2 to 4 times on one
head (#9189 and #9137 four times each), because the resolver released the
hand-off, the head did not move, and the autopilot arm parked and posted again.

The conductor's own read path does not loop: one job per (PR, head), and a done
verdict is consumed once (`rereviewdone`).

## What changed

- `bin/lib/hnr-rereview.sh` (new): `mc_hnr_decide <key> <head> <source> <ci> <mstate>`
  prints `buy`, `wait` or `park` and a reason. In this order:

  | Input | Answer |
  |---|---|
  | `MC_HNR_REREVIEW_MAX=0` | park (today's text) |
  | source not `autopilot`, `review-prs`, `box`, `run-build` (lead, human, `mc-rereview`, empty, unknown) | park |
  | merge state `DIRTY` | park |
  | CI not `green`, `pending`, `none`, `any` (red, failure) | park, reason names CI |
  | `hnrbuy <key> <head>` already recorded | buy (no new unit) |
  | units used >= max | park, `re-review budget used (<used> of <max>)` |
  | CI `pending`, or `none` with no spent flake ladder | wait (no unit) |
  | otherwise | write `hnrbuy <key> <head>`, then buy (`unit <n> of <max>`) |

- `headbound_review` (`bin/lib/mc/classify.sh`), mode `moved` only: the
  autopilot `BLOCK)` arm and the bound-verdict `block)` arm ask
  `mc_hnr_decide`. On `buy` or `wait` they fall through to the ordinary spawn
  path (lead-row check, lane-down guard, tick budget, CI debounce, job check,
  daily cap). The row stays HEAD_MOVED. On `buy` with a new unit the
  conductor logs one line `HNR_REREVIEW <key> <head8> — <source> BLOCK; the
  conductor buys its own head-bound read (unit n of max); no park`. On `park`
  the arm parks as before, and the log line and the PR comment carry the
  reason (for example `re-review budget used (1 of 1)`). The reason word stays
  `head-not-reapproved`.
- `br_rereview` (`bin/blocked-resolver.sh`): a reused BLOCK is not reused when
  `mc_hnr_decide` answers `buy` (CI word `any`). The rung buys the read under
  its own reason and counters.
- With no lib in the tree, both sites behave as before.

The conductor's own verdict then decides: APPROVE rebinds (`hb_approve_bind`),
BLOCK parks once per head (`hb_block_park`).

## The knob

`MC_HNR_REREVIEW_MAX`, registry row `catalog/lanes.d/_lib.hnr-rereview.json`,
int, default 1, min 0, max 10, 0 = off. It counts heads per PR, through the
attempts lines `hnrbuy <owner/repo#num> <head>` (`mc_attempt_count hnrbuy <key>`).
A unit is written before the spawn. A unit whose spawn is refused stays
counted, and the next tick on the same head takes no second unit.

## Not changed

- `bin/merge-conductor.sh:683` (BH-3814 human-verdict override) and
  `1525-1551` (the provenance BLOCK): both act on the conductor's own read.
- The BH-9154 patch-id carry: `rebind_patch_id` already runs before the
  HEAD_MOVED arm.
- The conductor's own BLOCK still parks at once.

## Check

`HARNESS_TEST_SANDBOX=1 bash tests/mc-head-reapprove.bh-9693-test.sh`. After
deploy, grep the hub's `logs/merge-conductor.log` for `HNR_REREVIEW` and
`re-review budget used`.
