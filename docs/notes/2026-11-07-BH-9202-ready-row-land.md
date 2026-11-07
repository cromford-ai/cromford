# A READY machine row is a hub landing, not "handled" (BH-9202)

Doc: MERGE-CONDUCTOR

## What happened

On 2026-11-07 cromford #9188 and #9197 were open, CLEAN and approved,
and did not land. The lane-run rows for #9188 were one per hour from 01:01Z
to 06:01Z, each `done rc=0` with
`PROF mc-pr state=READY reason=clean-approved-checks-green deferred=-`.

A machine run (`MC_ON_MACHINE=1`) never lands. Only the explicit machine arm
of the READY step wrote `deferred=land`. The other exits of the READY arm
(lead hold, block gate, prequeue, queue hold, a moved state) returned with no
word. The hub's `mc_fly_deferred_for` keyed only on the word, so it read the
row as handled, and `mc_fly_enqueue` added a new row of the same head on each
tick. The hub ran no worker for the PR, so nothing landed.

## What changed

- `bin/merge-conductor-pr.sh`: a row that is `READY` after the run with no
  deferred word prints `deferred=hold`. The land step still writes `land`,
  and a set word (`prequeuegroup`, `rebase`) is printed as before, with no
  `hold` added.
- `bin/lib/mc/fly-workers.sh`, `mc_fly_deferred_for`: a newest `done` row
  with `state=READY` and `deferred=-` (or no deferred field) reads as `hold`.
  The hub runs the PR's own worker this tick (rc 5,
  `fallback=machine-deferred (hold)`) and enqueues no new row. This fixes the
  rows already stored and machines that still run an older checkout.
- `bin/lib/mc/fly-workers.sh`, `_mc_fly_ready_loop` (new): one alert per
  (PR, head) when `MC_FLY_READY_LOOP_ALERT_N` (new knob, default 3, settings
  row `lane.merge-conductor.mc_fly_ready_loop_alert_n`) done rows of one head
  end `READY`. Attempt kind `flyreadyloop`. It uses the one existing prefix
  read; no new read.

The hub worker holds every normal gate (lead verdict on head, CI, block gate,
mode and kill switch, merge budget). A READY PR that the hub then holds runs
on the hub every tick, which was the behavior before the Fly path.

## Why `hold` and not `land`

The first build (ab13cba23) added `land` to every READY row. Then a READY
run that the machine held (main red) printed the same PROF line as a run
that reached the land step, and `tests/lane-run-inputs-mc-manifest.bh-6889-test.sh`
T1c failed. A held run and a land-step run are different outcomes, so the
held run gets its own word. The hub treats every word the same (rc 5).

Suite: `tests/conductor-ready-land.bh-9202-test.sh`.
