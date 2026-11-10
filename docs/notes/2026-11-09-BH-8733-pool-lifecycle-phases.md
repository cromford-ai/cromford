# BH-8733: the pool writes ticket phases; a plan block stores its question in the DB

Doc: FLY-POOL

## What changed

1. `bin/lib/pool-lifecycle.sh` (new) writes the ticket phase through the
   BH-8731 verb `lifecycle_transition`, as actor `pool`:

   | Where (config/fly-pool.d) | Phase |
   |---|---|
   | `push_preplan`, after a relay that succeeded (2500) | `planned` |
   | `next_job_or_destroy`, after the `reused` line (3300) | `building` |
   | `spawn_one`, after the `spawned` line (3800) | `building` |
   | the reap, after `# <<< reap row close` (3400), RESULT `PLAN_BLOCKED` | `plan_blocked` + the question |
   | the reap, RESULT `PR_CREATED <url>/pull/<n>` | `pr_open`, pr `<n>` |

   The question is `pb_excerpt` of the record's plan.md, defanged, and cut on a
   line end to `POOL_LIFECYCLE_QUESTION_MAX` bytes (new fly-pool knob, 2000).
   Every write returns rc 0. The queue row is closed before the phase is written.
2. The 409 table of `pool_phase_set`:

   | 409 `current` | Action |
   |---|---|
   | equal to the target | silent: the move is already done |
   | NULL or `pr_open`, target `plan_blocked`; NULL, `triaged` or `planned`, target `pr_open` | repair: send `building`, then the target once more (max 2 extra calls) |
   | any other | one `refused` line, no retry; a refused `plan_blocked` goes to the table in step 3 |

   `plan_blocked` from `triaged` or `planned` is legal at once, so it never
   answers 409 and needs no repair.
3. A refused `plan_blocked` (lead review verdict 5198). `merged` and `closed`
   are terminal in `lifecycle.js`, so the phase cannot hold the stop, and the
   spawn gate passes those phases. Without more, the key relaunched up to the
   spawn cap every day. `pool_phase_reap <p> <key> <dir> <ticket>` now does this,
   once per build record:

   | Refused `current` | Ticket | Action |
   |---|---|---|
   | `merged`, `closed` | all digits (an issue) | ONE needs-human hold through `bin/needs-human-hold.sh <p> <ticket> <fp> <action> plan-blocked`. The fp is the first 16 hex of `sha1(<p>:<key>:plan_blocked-refused)`, so one hold per key. The action carries the question. `<dir>/lifecycle-refused.held` is written only after rc 0. The pool's HOLD gate (`pool_hold_check`) reads the marker and stops the next spawn until a person answers. |
   | `merged`, `closed` | all digits, hold rc != 0 | no `.held`; one ALERTS line `... (current <c>); hold not placed (rc <n>)` |
   | `merged`, `closed` | not digits (an in-app board ticket) | one ALERTS line `...; board ticket, no issue to hold; the per-key spawn cap bounds a relaunch` |
   | `abandoned`, `ejected`, `in_queue` | any | one ALERTS line `[pool/<p>] <KEY>: PLAN_BLOCKED not stored (current <c>)`; the spawn gate refuses these keys |

   `<dir>/lifecycle-refused.alerted` keeps a second reap of the record quiet.

   rc 2 (no row), rc 1 (outage) and rc 3 (bad arguments) give one line each.
   Lane job keys (`RB-`, `RR-`, `LR-`, `FXR-`, `CP-`) are never written.
4. `worker/jobs/src/lib/lifecycle.js`: `pr_open` gets the exit `building`
   (owner `pool`). A resolver rebuild-fresh over an open PR phase can now reach
   `plan_blocked`. The #8765 design answered 409 there, and the key looped
   until the per-key spawn cap.
5. `bin/lib/plan-blocked-stop.sh` (`pbs_stop_check`) reads the phase only, with
   one `GET /api/queue?project=&key=&limit=1`. It refuses `plan_blocked`,
   `abandoned`, `ejected` and `in_queue`. It passes every other phase, NULL,
   no row and an outage (one line). It reads no `builds/` record and no
   `plan-blocked.*` file. The call moved above `pool_gates_applicable`, just
   after the execute-empty stop, so it applies to every project.
6. The record gate is removed with its file reads: the "already done on main"
   auto-close, the `After:` prerequisite hold, the "a person answered" release
   and the 2-stop NEEDS_HUMAN hold. The knobs `POOL_PLAN_BLOCKED_MAX` and
   `POOL_PLAN_BLOCKED_WINDOW_S` are removed. No legacy gate file exists.

## Operator re-entry

The BH-8736 Tackler (on main, dcaa6bf2) owns re-entry from `plan_blocked`,
`abandoned` and `ejected`. An operator can also re-enter a key with:

    bin/jobs-client.sh lifecycle-transition <project> <KEY> planned lifecycle "<why>"

A key held by step 3 builds again when a person answers on the issue (the
HOLD gate then reads it clear) and the ticket is queued again.

## Known gap

`bin/lib/unblock/collectors/infra.sh` (BH-8766) still reads
`plan-blocked.after`. Nothing writes that file now, so its `after` source finds
nothing. Its `stack-wait` source does not change. A cleanup ticket owns it.
