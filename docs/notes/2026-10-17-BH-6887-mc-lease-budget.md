# Merge lock to the project lease, re-review cap to D1 (BH-6887, BH-6881.3)

Doc: MERGE-CONDUCTOR, HARNESS-COORDINATION

## What changed

The merge conductor's merge lock now takes the D1 project lease (BH-6883,
`bin/lib/project-lease.sh`) for lane `merge-conductor`. Each landing writer
checks the held fence before its GitHub call. The daily re-review cap
(`MC_REREVIEW_DAILY_CAP`) now spends a D1 counter. Why: a lane-run machine
cannot land while the lock is a box flock and the cap is a box file
(docs/notes/2026-10-14-BH-6495-conductor-fly.md).

### `mc_merge_locked <project> <cmd…>` (`bin/lib/mc/locks.sh`)

rc is the command's own; 99 = nothing written, try next tick.

| where | lease | result |
|---|---|---|
| hub | flock not had in the wait | 99 (as before) |
| hub | flock had, acquire 200 | run the command with the fence exported, release, unlock |
| hub | flock had, acquire 409 `held` | unlock, log `merge lease held by another holder`, 99 |
| hub | flock had, acquire not answered | run under the flock only (as before); one log line when `JOBS_URL` is set |
| machine | `MC_LEASE_FENCE` set by an outer owner | no acquire, no release; run the command (a landing too) |
| machine | no outer owner, command `mc_merge`/`mc_enqueue` | write `merge`/`enqueue` to `MC_PR_DEFERRED_FILE`, 99, no lease call (as before) |
| machine | no outer owner, other command, acquire 200 | run the command with the fence exported, release |
| machine | no outer owner, other command, acquire 409 `held` | log `merge lease held by another holder`, 99 |
| machine | no outer owner, other command, acquire not answered | log `merge lease unavailable on a lane-run machine`, 99 |

A machine lands only under a lease an outer owner holds. That keeps the
bh-6495 pr-claim suite case C4 true: a direct merge and an enqueue through the
merge lock defer on a machine. `pr_worker` already defers a READY PR there
(`deferred=land`). #6890's per-project runner takes the lease for the tick,
exports it, and its landings then run lease-guarded. In production the only
callers of `mc_merge_locked` are `mc_merge` and `mc_enqueue`.

Holder ids: `hub-<hostname>` on the hub (one id for all hub workers; the hub
flock serialises them), `FLY_MACHINE_ID` (else `machine-<hostname>`) on a
machine, reduced to `[A-Za-z0-9._-]` and 64 characters.

### The fence check `mc_lease_fence_ok`

Called before the GitHub write in `mc_merge`, `mc_enqueue` (after its machine
guard), `conductor_settle` (after its machine guard) and `mc_close_shipped`.

| state | result |
|---|---|
| no `MC_LEASE_FENCE` | rc 0, no request |
| renew 200 | rc 0 |
| renew 409 `lost` | log `project lease lost`, rc 99 |
| renew not answered (503, transport, a 409 that is not `lost`), machine | rc 99 |
| renew not answered, hub | log `hub flock only`, rc 0 |

On 99: `mc_merge` and `mc_enqueue` return 99; `conductor_settle` writes
`settle` to `MC_PR_DEFERRED_FILE` and returns 0 (the QUEUED pass settles it);
`mc_close_shipped` prints `close-failed` (the caller retries).

Rule: the hub fails open on a lease outage, because its flock still
serialises the hub and a D1 outage must not stop every landing (BH-1000). A
machine fails closed on a landing, because it has no other serialisation.

### The contract for #6888 and #6890

`mc_merge_locked` exports three variables to its command, as locals, so they
do not leak past the call:

- `MC_LEASE_FENCE`: the fence token held
- `MC_LEASE_PROJECT`: the project of that fence
- `MC_LEASE_HOLDER`: the holder id

A per-project runner that holds the lease for a whole tick exports all three
itself. `mc_merge_locked` then takes no lease and releases none, and every
writer renews that fence. On a machine this is the only way a landing runs.
`pr_worker` still defers a READY PR on a machine (`deferred=land`); #6890
switches that and supplies the runner.

Known edge with #7073 (`landing_direct`): its `landingdirect` mark is written
before `mc_merge` runs. If the fence is lost there, nothing merges and the
mark stays, so a later queue landing of that head is labelled `path=direct`
in the ledger. It is a label, not a merge.

### The daily cap (`headbound_review`, `bin/lib/mc/classify.sh`)

With `MC_REREVIEW_DAILY_CAP` > 0, one unit is taken from `mc_budget` before
the spawn and given back when the per-tick budget refuses or the spawn fails.

| take answer | result |
|---|---|
| granted | spawn (the box file still gets its line) |
| denied | log `hit the operator-set daily cap (N)`, no spawn |
| not answered, hub | count the box file (`CAPFILE`) as before |
| not answered, machine | log `the daily cap counter could not be read`, no spawn |

With the cap at 0 (the default on every box) there is no D1 call.

- Table `mc_budget (project, day, kind, spent)`, PRIMARY KEY
  `(project, day, kind)` (`worker/jobs/schema.d/202610170521-bh-6887-mc-budget.sql`).
- `POST /api/mc-budget/take {project, kind, limit}`: a seed
  `INSERT OR IGNORE`, then ONE spend
  `UPDATE … SET spent = spent + 1 WHERE project=? AND day=? AND kind=? AND spent < ? RETURNING spent`.
  200 `{granted:true, day, spent}` or 200 `{granted:false, day}`.
- `POST /api/mc-budget/give {project, kind, day}`: `spent - 1`, never below 0.
- The day is the worker's UTC date. The take answers it; the give sends it back.
- Retention: rule `mc_budget.age` in `worker/jobs/src/routes/retention.js`
  deletes rows older than `retention.mc_budget.days` (seed 30). The
  d1-retention lane calls the route hourly; `retention.dry_run` applies.

## Verified by

- `tests/mc-locks-lease.bh-6887-test.sh`
- `tests/mc-budget.bh-6887-test.sh`
