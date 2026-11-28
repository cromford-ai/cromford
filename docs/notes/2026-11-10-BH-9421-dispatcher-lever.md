# The dispatcher pilot: metric ready_unqueued_2h and the enqueue / release lever (BH-9421, BH-9187 slice C3)

Doc: DB-COORDINATION-SPEC

## What changed

A new hub lane, `bin/staff-dispatcher-lever.sh` (registry `catalog/lanes.d/staff-dispatcher-lever.json`, cron `cron/lanes/729-staff-dispatcher-lever.cron`, at :05, :20, :35 and :50). It is the first production caller of the C0 helpers `staff_metric_post` and `staff_action_post` (`bin/lib/staff-contract.sh`). It makes no model call and no GitHub call. It changes no route, no table and no other lane.

## The metric

`ready_unqueued_2h` = R + C. Lower is better. The target row `staff.dispatcher.target` stays 0.

- R: `build_queue` rows in status `ready` whose `enqueued_at` is at least `STAFF_DSP_READY_AGE_MIN` (default 120) minutes before the worker's `as_of`. A `ready` row is the fleet's record of "the board says this ticket is buildable, and nothing queued it" (BH-1033).
- C: `build_queue` rows in status `claimed` whose `claimed_at` is at least `STAFF_DSP_CLAIM_AGE_MIN` (default 30) minutes before `as_of`, with no `running` job of kind `build` in the same project for the row's `ticket_key` or `ticket_id`. A triage or review job does not hold the build claim.

The clock is the worker's `as_of`, never the box clock.

## The reads

Three GETs, all with `limit=500` (the worker's page cap):

1. `GET /api/queue?status=ready&limit=500`
2. `GET /api/queue?status=claimed&limit=500`
3. `GET /api/jobs?status=running&kind=build&limit=500`

The claimed read sends no `stale_min`. The worker applies `stale_min` after its `LIMIT`, so a truncated answer would look complete. The lane computes the age itself.

A failed or non-JSON read is one `unreadable: <which>` line. An answer that holds 500 rows is one `incomplete: <which>` line. In both cases the run posts no sample and no action (D12). A sample of 0 from a read that failed is never written.

## Levels

- `observe` and `file`: the run posts one metric sample and nothing else.
- `act`: the run also pulls the lever. The level is the row `staff.dispatcher.level` through `staff_level`. No row, an outage or a bad value is `observe` (logged `level_fallback=1`). The C0 seed is `observe`, and this PR does not change it.

## The lever (level act only)

Candidates: the C rows by `claimed_at`, then the R rows by `enqueued_at`, oldest first. At most `STAFF_DSP_LEVER_MAX` (default 3) NEW action rows per run. The rest is logged `deferred=<n>` and comes back next run.

- release (a C row): `queue_release_counted` (PATCH /api/queue, `count_attempt:true`). It is the same counted call the jobs-watchdog stale-claim release uses, so the cap `queue.release_attempt_max` applies. A capped answer is one `release-cap` line.
- enqueue (an R row): `queue_put` with no status (POST /api/queue). The worker promotes a `ready` row to `queued`. A `duplicate` answer is one line.

The enqueue guard runs before any action row. A running build job for the key declines the row. Then `bin/triage-gate.sh <project> --buildable-strict <ticket_id or key>` must print exactly `OK` within `STAFF_DSP_GATE_TIMEOUT_S` (default 60). Any other answer (BLOCKED, text after OK, empty, a timeout, no script) declines the row. A declined row is one `declined enqueue` line and no action row. A release launches no build, so it has no board guard. It has the running-job check.

The release guard (lead BLOCK on #9469) runs before any release action row. On the fly path the hub claims the row, and `bin/fly-pool.sh` closes it only when it collects the result (every 10 minutes). So a build that has FINISHED leaves the row `claimed` with no running job, and a release would start a second paid build. The lane reads `GET /api/jobs?project=<p>&ticket_id=<key>&kind=build&limit=50` (and the same for the ticket_id when it differs). It declines the release when a build job opened at or after `claimed_at` (any status), when any build job finished less than `STAFF_DSP_FINISH_GRACE_MIN` (default 20, two fly-pool cycles) before `as_of`, or when the read fails. A declined row is one `declined release` line and no action row, in dry run too. The metric still counts these rows; the guard is on the lever.

The action row comes first: `POST /api/staff/levers/actions` with the key `<lever>|<dry|live>|<project>/<key>|<claimed_at or enqueued_at>`. The row's own timestamp is in the key, so one stuck row is one action, and a row that is stuck again later is a new action.

- 200 with no `existing`: a new action. In live mode the queue write runs now.
- 200 `existing:true`, or 409 `key_mismatch`: this row state was already handled. It is counted `seen`. No queue write.
- Any other answer: counted `failed`. No queue write.

So a queue write without its action row cannot happen. A queue write that fails after a new action row is one `failed after record` line. That action settles as not moved.

`detail` is a JSON string on both posts, because the C0 route accepts a string of at most 2000 characters and refuses an object.

## The dry run

`STAFF_DSP_LEVER_DRY_RUN` (default 1). At level `act` with the knob at 1, the lane posts `dryRun:true` action rows and writes nothing to the queue. The dry and live keys differ, so the first live run is not blocked by the dry-run rows.

## Turn it on

1. Set the settings row `staff.dispatcher.level` to `act`.
2. Read the dry-run rows: `GET /api/staff/levers/scorecard?agent=dispatcher` (`dry_runs`), and the `logs/staff-dispatcher-lever.log` summary lines on the hub.
3. If the dry-run rows name the right rows, set `lane.staff-dispatcher-lever.staff_dsp_lever_dry_run` (`STAFF_DSP_LEVER_DRY_RUN`) to 0.

Off: `STAFF_DSP_LEVER_ENABLED=0`, the flags `staff-off-all`, `staff-kill-all`, `staff-off-dispatcher`, `staff-kill-dispatcher`, or the level row back to `observe`.

## The log

One summary line per run that read: `level= metric= value= ready= claimed_orphan= actions_new= seen= declined= failed= dry_run= released= enqueued= deferred=`. `released` and `enqueued` count only a `queued` answer from the worker. The lane writes no `state/` file and no ALERTS line.

## Neighbours

- `bin/jobs-watchdog.sh` releases every claim older than 360 minutes with no job check. This lane releases at 30 minutes, only with no running build job. Both use the same counted compare-and-swap, so a row is released once; the second caller gets `stale`.
- `bin/orphan-reconcile.sh` re-offers stranded GitHub tickets with `queue_put`. If it went first, this lane logs `duplicate`.
- `bin/lib/gate-release/queue.sh` and the triage tick launch from ready rows. After a promote, their next `queue_ready_put` answers `duplicate`. That is the intended state.
- `bin/stale-owed-tickets.sh` writes ready rows with a 24h cooldown on `enqueued_at`. This lane changes `enqueued_at` only through the promote.
- The staff tick (`bin/staff.sh tick dispatcher`) uses another lock and shares no file. The kill flags are the same.
- C0 retention covers the sample and action rows: 96 samples a day.

## Test

`tests/staff-dispatcher-lever.bh-9421-test.sh` runs the shipped script against a stub worker (A1-A12).
