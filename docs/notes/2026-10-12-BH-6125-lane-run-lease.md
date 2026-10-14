# Lane runs: the lease heartbeat and the death count (BH-6125, BH-6047 part 2 of 5)

Doc: PROJECT-LANES

## What changed

The two lease seams of the lane-run queue (BH-6124) now do their work.

- `POST /api/lane-runs/<id>/heartbeat {machine}`
  (`worker/jobs/src/routes/lane-runs-lease.js`). ONE statement sets
  `lease_until = now + lane_run.lease_s` and `heartbeat_at = now`, only while
  the row is `claimed` by that machine. The answer is 200
  `{id, status:"claimed", lease_until}`. Anything else writes nothing and
  answers 409 `{error:"lost", reason, id, status}`:
  - `no_row`: no row has that id.
  - `not_claimed`: the row is `queued`, `done` or `died`.
  - `not_claimer`: another machine holds the claim. The 409 does not name it.
  A missing or bad `machine` is 400. A lease that ran out, with no other
  claim yet, is still extended for its claimer.
- `sweepDead(env, now)` (same file). The claim route calls it before every
  claim. ONE statement sets `status='died'`, `rc=137`, `finished_at=now` on
  every `claimed` row with `lease_until < now` and
  `attempts >= lane_run.max_attempts`. It returns the count. The claim never
  matches `died` and the live index `lane_runs_live` excludes it, so the row
  is terminal and a new enqueue of the same lane and project is allowed.
- `bin/lib/lane-run-heartbeat.sh`:
  - `lrh_start <run_id> <pgid>` starts a background loop. Every
    `lane_run.heartbeat_s` seconds it POSTs the heartbeat with the worker's
    `MACHINE` (else `FLY_MACHINE_ID`, else `_jobs_box_name`).
  - On 409 with `error == "lost"` it writes
    `state/lane-run-worker/lost-<worker pid>-<run id>`, logs
    `run <id>: lease lost (<reason>); killing process group <pgid>`, sends
    TERM to the group (to the pid alone when the group kill fails) and KILL to
    the group 5 s later, then stops.
  - Any other answer (transport failure, 5xx, 503 schema not applied, 404, a
    409 with another error) logs `heartbeat failed` and the run goes on. An
    outage is not a lost lease. If the outage outlasts the lease, another
    machine re-claims the row, and the next beat that lands gets 409 lost.
  - The loop stops by itself when the worker process that started it is gone,
    so a dead worker never keeps a lease alive.
  - A pgid that is not a positive integer, is `1`, or is the worker's own pid
    or process group is never signalled. The log says `not killed: bad pgid`.
  - `lrh_stop` ends the loop. `lrh_lost` is rc 0 when the lost file exists,
    also after `lrh_stop`. `bin/lane-run-worker.sh` then logs
    `lease lost; not reported` and sends no report. The next `lrh_start`
    removes the file.
- Schema fragment `worker/jobs/schema.d/0021-bh-6047-lane-run-lease.sql` seeds
  two settings rows. `worker/jobs/schema.sql` is regenerated from it.

## Knobs

| row | seed | bounds | outside the bounds or no row |
|---|---|---|---|
| `lane_run.heartbeat_s` | 30 | 1..300 | 30 |
| `lane_run.max_attempts` | 3 | 1..20 | 3 |

With the seeds, a 120 s lease gets 4 beats, so 3 failed beats in a row still
keep it. A run whose lease runs out at its third claim dies on the next claim.
A beat at or above `lane_run.lease_s` is allowed, and the lease then expires
between beats. The two knobs are not cross-checked.

The 5 s TERM-to-KILL grace is a code constant.

## Why

A machine that dies mid-run leaves a `claimed` row. Before this change its
lease expired and the row was re-claimed with no cap, and a slow machine never
learned that another machine took its row, so both ran it and both reported.
Now the old claimer's next beat gets 409 lost, it kills its run and does not
report, and a row that keeps killing its machine dies after
`lane_run.max_attempts` claims. The "No attempt cap" limit in
`docs/notes/2026-10-12-BH-6124-lane-runs.md` ends with this part.

## Verify

- `cd worker/jobs && node --test test/lane-run-lease.bh-6125.test.js`
- `HARNESS_TEST_SANDBOX=1 bash tests/lane-run-lease.bh-6125-test.sh`

## Limits

- A lost file stays in `state/lane-run-worker/` when the worker exits right
  after a lost run. It is one empty file per lost run, and the file name
  carries the worker's pid.
- The 409 for a missing row is `lost`, not 404, so the loop stops on it.
- Nothing runs on Fly yet: every lane is seeded `hub`, so no row exists in
  prod and the first sweep marks nothing.
