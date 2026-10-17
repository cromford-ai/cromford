# Docker-pool claim lease (BH-7300, slice C0)

Doc: DB-COORDINATION-SPEC

## What changed

A new D1 table, four bearer-gated routes, four settings rows, a retention
rule, a shell client and one sweep block in the hub watchdog. This is the
hub-side half of the pull-mode Docker runner of #7300. No runner calls the
routes yet: the runner script, the file set it builds and the `docker run`
are slice C1. Cost rows, result reaping and App token rotation are slice C2.

- Table `docker_pool_leases`
  (`worker/jobs/schema.d/202610171004-bh-7300-docker-pool-leases.sql`): one
  row per docker-pool claim. `status` is `active`, `done`, `released`,
  `expired` or `killed`. A partial unique index allows one `active` row per
  `(project, ticket_key)`. `claimed_at` is the build_queue row's `claimed_at`
  of the same claim, so a lease only ever acts on the claim it was made for.
- Routes (`worker/jobs/src/routes/docker-pool.js`, fragment
  `worker/jobs/test/route-table.d/bh-7300-docker-pool.txt`):
  - `POST /api/docker-pool/claim {project, key, box}`. The key is required.
    There is no "oldest row" claim, because the hub pool's gates (HOLD,
    `After:`, the spawn cap) run before a key is named. `docker_pool.kill=1`
    is 409 `killed`, a max of 0 is 409 `off`; both write nothing. Then the
    sweep runs, and one batch claims the row (only while it is `queued`,
    `target='fly'`, and the box holds fewer active leases than its max) and
    inserts the lease. 200 `{claimed:true, queued:{ticket_key, ticket_id,
    attempt}, lease_until}`. Else 404 `nothing queued`, or 409
    `{refused:true, reason}` with `not_pool`, `lost` or `full`.
  - `POST /api/docker-pool/heartbeat {project, key, box}` extends the lease
    while the row is still claimed by the box at the lease's `claimed_at`.
    Else 409 `{error:'lost', reason}` with `no_lease`, `expired`,
    `not_claimer` or `row_moved`, and nothing is written. With kill on, the
    lease ends `killed` and the row goes back on the queue (409 `killed`).
  - `POST /api/docker-pool/release {project, key, box, status, reason?}`.
    `queued` (the SIGTERM hand-off) requeues the row and ends the lease
    `released`. `done` ends the lease `done` and leaves the row to the build
    wrapper's `queue_done`. Any other status is 400. No live lease of the box
    is 409 `lost`.
  - `POST /api/docker-pool/sweep`: at most 50 active leases past
    `lease_until`. Each row that is still the lease's claim goes back on the
    queue with no claimant; each lease ends `expired`. One batch.
    `{expired:[{project, key, box, requeued}], requeued, backlog}`.
- A claim also ends an `active` lease whose row is already back on the queue
  (the 360-minute watchdog release can do that), so that lease does not block
  the next claim of the key.
- The keyed hub claim `POST /api/queue/claim {project, key, target:'fly'}` of
  a row a docker box holds answers 404 (`queue_claim` rc 2), because it reads
  only a `queued` row. `bin/fly-pool.sh` `spawn_one` reads rc 2 and rc 9 the
  same way: no machine is spawned.
- `attempt` is never changed, the same as the watchdog's `queue_release`.
- Shell client `bin/lib/docker-pool.sh`: `docker_pool_claim <project> <key>`
  (rc 0 prints `key ticket_id attempt lease_until`), `docker_pool_heartbeat`,
  `docker_pool_release <project> <key> <done|queued> [reason]`,
  `docker_pool_sweep`. rc 9 = a refusal (the reason on stderr), rc 2 =
  nothing queued, rc 1 = anything else. The box is `$JOBS_BOX`. The caller
  sources `bin/jobs-client.sh` first.
- `bin/jobs-watchdog.sh` calls `docker_pool_sweep` on every hub tick (*/5),
  after the stale-claim release. It writes one ALERTS line per requeued row
  (`DOCKER POOL LEASE EXPIRED: <p>/<k> on <box>; ...`) and one log line
  `docker-pool: <n> lease(s) expired, <m> row(s) requeued`. A failed sweep is
  one log line and no ALERTS line. With the lib absent the block is silent.

## Knobs

| settings row | seed | rule |
|---|---|---|
| `docker_pool.max_concurrent` | 0 | builds one box may hold at once, 0..64; 0 = off |
| `docker_pool.max_concurrent.<box>` | none | wins over the fleet row for that box |
| `docker_pool.kill` | 0 | 1 refuses every claim and ends every lease at its next heartbeat |
| `docker_pool.lease_s` | 300 | lease length after a claim or a heartbeat, 60..3600 |
| `retention.docker_pool_leases.days` | 30 | ended lease rows kept; 0 = off |

A max value that is not an integer in 0..64, or no row at all, is 0 (off).
A `lease_s` value outside 60..3600 uses the code fallback 300. A dead host
loses its row within `lease_s` plus one watchdog tick (5 minutes), or at the
next claim by any box, which sweeps first.

## Retention

Rule `docker_pool_leases.ended` in `worker/jobs/src/routes/retention.js`:
ended leases with `ended_at` older than `retention.docker_pool_leases.days`
are deleted by the hourly `d1-retention` lane. `retention.dry_run` applies as
for every rule. An active lease is never a candidate. Lease rows hold no
money; the build history stays in `build_queue` and the jobs ledger.

## Turning it on (C1 go-live)

Nothing claims until an operator sets a max row above 0 for a box AND a
runner (slice C1) calls the routes. C0 ships neither the runner nor a box row.

## Proof

`worker/jobs/test/docker-pool.bh-7300.test.js` drives the real worker on
node:sqlite with the composed schema: the claim, heartbeat and sweep decision
rules, the two-box race, retention, and EXPLAIN QUERY PLAN at 5,000 leases
and 5,000 queue rows (no statement scans either table).
`tests/docker-pool.bh-7300-test.sh` drives the lib and `bin/jobs-watchdog.sh`
over real curl (`tests/lib/docker-pool-worker.bh-7300.mjs`).
