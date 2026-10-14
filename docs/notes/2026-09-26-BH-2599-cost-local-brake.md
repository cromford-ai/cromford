# The cost brake reaches the owning box during a harness-jobs outage

Doc: COST

## What was wrong

The cost breaker runs on the hub (`bin/pipeline-health.sh`, `cost budget`).
Every fleet.conf project lives on a remote box, and the hub's pause reaches that
box only as the `paused-<p>` row its `flag_active` reads. With the worker down:

- `flag_set` touched `flags/paused-<p>` on the HUB, then its PUT failed. The
  hub paged `costhaltfail` once. But the hub file stayed, and at the next cost
  check `cb_paused` read it as `already`, so the page went quiet. That file
  paused nothing, because the hub owns no project.
- The owning box never heard about it, so its triage kept running for the whole
  outage.

## What changed

1. **The hub keeps no file it could not publish.** `cb_halt` removes
   `flags/paused-<p>` when `flag_set` fails. `cb_paused` had just said the
   project was not paused, so this only undoes what `flag_set` wrote. The next
   check retries the halt and pages `costhaltfail` again, every check, until the
   row lands.
2. **Each owning box brakes itself during an outage.** New lane
   `cost-local-brake` (`bin/cost-local-brake.sh`) runs every 10 minutes on the
   boxes that own a project. It evaluates nothing while the worker answers. When
   `flag_sync paused-<p>` fails (outage), it judges each project this box owns
   (`fleet-conf.sh --projects-on-box`) with the hub's own rules and settings rows:
   - spend from this box's `logs/cost.csv` (delivery stages only, numeric
     `cost_usd`),
   - merged-PR counts from the rollup's GitHub search (a count it cannot take
     means no pause and one `costlocalnoeval:<p>` alert a day),
   - the $/PR autohalt and the zero-merge breaker, the kill switches
     (`flags/cost-autohalt-off`, `lane.pipeline-health.cost_autohalt = 0`) and
     `COST_AUTOHALT_REARM_S`.

   A trip writes `flags/paused-<p>` on the box, so `run-triage` stops at its next
   tick, and pages `costlocalhalt:<p>`. The reason ends in `(cost autohalt)` or
   `(zero-merge breaker)`, which is what the console's COST BREAKER card lists.

   The PUT usually fails during an outage. The reason is then kept in
   `state/cost-local-brake/<p>.pending`, and the first tick the worker answers
   writes the row (console-visible, `resume_board` clears it). The marker is
   removed only once that PUT lands.

## Limits

- Fly pool builds write their cost rows on the pool machine, not in the box's
  `cost.csv`. The local spend is a floor, so the local brake can miss a runaway
  the hub would catch. It never pauses on more than the box actually recorded.
- A box whose `flag_sync` gets an unreadable row (rc 1) is treated as in an
  outage. It still needs real over-budget numbers to pause anything.

## Undoing a box-local pause

- Once the worker is back and the row is published: `resume_board` from the
  console, as for any autohalt.
- While the worker is still down: on the box, remove
  `/root/harness/flags/paused-<p>` and `/root/harness/state/cost-local-brake/<p>.pending`.
  The next tick the worker answers sees no file, drops nothing into the DB, and
  the re-arm stamp stops this box from pausing it again for `COST_AUTOHALT_REARM_S`.

## One-time check after deploy

A hub halt that failed before this change may have left `flags/paused-<p>` on
the hub with no row behind it. The code can't tell that file apart from an
operator's, so it is not cleaned up automatically. On the hub, compare
`ls /root/harness/flags/paused-*` against the console's pause list and remove
any file with no active row.

Tests: `tests/cost-local-brake.bh-2599-test.sh`; `tests/routing-writers.bh-1373-test.sh`
case 5 now pins "no hub file after a failed halt".
