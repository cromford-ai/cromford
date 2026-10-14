# Queue-row knob flips get a preflight (BH-2338, BH-2313.0)

Doc: DB-COORDINATION-SPEC

## What changed

- **`bin/queue-rows-flip-preflight.sh` (new, read-only).** It runs one block per
  gate: `build`, `merge`, `deploy`, `ready`, `closeout` (all five by default,
  or the ones named). Each block reads the gate's knob row with a raw
  `GET /api/settings/<knob>`, sources `bin/lib/qrf/<gate>.sh` and runs
  `qrf_gate_<gate>`, prints the rollback command, then prints
  `RESULT: READY <gate>` or `RESULT: NOT READY <gate>`. Exit 0 only when every
  requested gate is READY, 1 otherwise, 2 on a usage error, a missing jobs
  client or an empty `JOBS_URL`.
- **Five stub gate modules** in `bin/lib/qrf/`. Each one FAILs with
  `row parity: check not implemented yet`, so every gate prints NOT READY
  until its BH-2313 sibling replaces the stub with real checks.
- **`tests/lib/qrf-fixture.sh`**, the fake worker the sibling suites reuse.

## Why

The five knobs move a lane from its per-box files to the coordination DB rows.
Setting one before the rows match the files would drop or double work. The
preflight is the one place each gate proves that first. It never writes: GETs
only, nothing under `$HARNESS`, and a missing knob row (404) is a FAIL rather
than a `0`.

The knobs all stay `0`. Nothing in this PR sets any of them.

## Flip order, per gate (an operator step, not done here)

1. `HARNESS=/root/harness bin/queue-rows-flip-preflight.sh <gate>` prints
   `RESULT: READY <gate>` on every `fleet.conf` box that holds the gate's files.
2. `bin/jobs-client.sh setting-set <knob> 1`
3. Re-run the preflight.
4. Watch the lane log for 24h.

Rollback, one per knob. The ticket wrote `setting-put`; the client's verb is
`setting-set` (`bin/jobs-client.sh`), and `setting-put` is a usage error.

| gate | rollback |
|---|---|
| build | `bin/jobs-client.sh setting-set build_queue_rows_only 0` |
| merge | `bin/jobs-client.sh setting-set merge_queue_rows_only 0` |
| deploy | `bin/jobs-client.sh setting-set deploy_queue_rows 0` |
| ready | `bin/jobs-client.sh setting-set ready_queue_rows 0` |
| closeout | `bin/jobs-client.sh setting-set closeout_aged_table 0` |

## Follow-up: the B1-B5 file-queue deletions

Once a gate's knob is 1 and has held, its sibling deletes the file path. Each
of those tickets:

- runs the knob probe as step 0;
- makes the rows branch unconditional;
- deletes the file reads and writes, and the ssh `ls`/`touch`/`scp` fallbacks;
- ALERTs on a failed row write;
- ships a per-ticket suite with no file dir and an ssh stub that fails if called.

B1 and B2 both touch `bin/fly-pool.sh`.

Out of scope here: `fly_machines_rows` (not a gate of this script; naming it
is a usage error), any settings write, and the B1-B5 deletions themselves.
