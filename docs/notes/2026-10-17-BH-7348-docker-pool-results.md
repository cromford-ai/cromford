# Docker-pool cost rows, result rows and App token rotation (BH-7348, BH-7300 slice C2)

Doc: DB-COORDINATION-SPEC

## What changed

A docker host has no inbound path from the hub, so the hub cannot reap it the
way `bin/fly-pool.sh` reaps a Fly machine. The host keeps its disk after the
container exits. So the host reaps its own build dir, and the hub reads the
outcome from the jobs worker. This slice adds the routes, the table, two host
libs, one client function and one watchdog block. No runner calls the host
libs yet: the runner is slice C1 (BH-7347). This note is the contract it
calls.

- Table `docker_pool_results`
  (`worker/jobs/schema.d/202610172327-bh-7348-docker-pool-results.sql`): one
  row per finished docker claim. The natural key is
  `(project, ticket_key, claimed_at)`, and `claimed_at` is the lease's claim,
  so a requeued and re-claimed ticket gets a new row. The row holds counts,
  not money: the money stays in `cost_rows` under `cost_box`. The same file
  adds `idx_docker_pool_leases_key` on C0's lease table and the settings row
  `retention.docker_pool_results.days` (30).
- Routes (`worker/jobs/src/routes/docker-pool-results.js`, fragment
  `worker/jobs/test/route-table.d/bh-7348-docker-pool-results.txt`,
  bearer-gated):
  - `POST /api/docker-pool/result {project, key, box, result, cost_box,
    cost_rows, unpriced_rows, cost_verified, job_id?, pr_url?, tier?,
    auth_account?}`. A bad field is 400 and nothing is written. An absent
    `cost_rows` is 400, never 0. An `auth_account` that starts like a
    credential (`sk-`, `ghs_`, `ghp_`, `gho_`, `ghu_`, `github_pat_`) is 400
    with reason `auth_account_not_a_label`. An empty one is stored `unknown`.
    Then the route reads this box's newest lease for the key. No lease is 409
    `no_lease`. A lease that ended `expired`, `killed` or `released` is 409
    `superseded`: the row went back on the queue, so this run is not the
    ticket's result. `active` or `done` is one upsert. A re-post before the
    hub read replaces the row. After the hub read it is 409 `already_reaped`
    and the row is unchanged. 200 `{recorded:true, claimed_at}`.
  - `POST /api/docker-pool/results/reap {limit?}`. `limit` is 1..50 (default
    50); any other value is 400. One read of the oldest unread ids, then one
    `UPDATE ... RETURNING` that stamps `reaped_at`. Only the rows this call
    stamped come back, so two concurrent reads never return one row twice.
    200 `{reaped:[...], backlog:0|1}`. `backlog` is 1 when the read was full.
- Retention rule `docker_pool_results.age` (`worker/jobs/src/routes/retention.js`):
  a row the hub read, older than `retention.docker_pool_results.days`, is
  deleted. An unread row is never a candidate. `retention.dry_run` applies.
- `bin/lib/docker-pool.sh` gets `docker_pool_results_reap [limit]`. rc 0
  prints `<n> <backlog>`, then one TSV line per row: `project key box
  result_word cost_rows unpriced_rows cost_verified auth_account pr_url
  cost_box` (an empty field is `-`). rc 1 is a worker it cannot use.
- `bin/jobs-watchdog.sh` calls it every tick after the C0 sweep. It writes one
  log line per row (`docker-pool result: <p>/<k> on <box>: ...`), one summary
  line (`docker-pool results: <n> result(s) read`), and one ALERTS line
  (`DOCKER POOL COST ROWS: ...`) per row with `cost_rows > 0` and unpriced
  rows or `cost_verified = 0`. A failed read writes one log line
  (`docker-pool results: reap failed ...`) and no ALERTS line. The summary
  prefix is `docker-pool results:`, not `docker-pool:`, so the C0 sweep's
  own log lines keep their count.

## What the C1 runner calls

1. Before the container starts, the runner gets the cost box:
   `docker_pool_cost_box <project> <tag>` prints `pool-<project>-<tag>`. Pass
   `FLY_MACHINE_ID=<tag>` and `POOL_MODE=1` to the container. Then
   `fly/entrypoint.sh` sets `COST_ROWS_BOX` to the same string, and the
   container's own pushes and the host reap write one box id.
   `tests/docker-pool-reap.bh-7348-test.sh` I1 pins this equality.
2. While the build runs, call
   `docker_pool_token_rotate <owner/repo> <env-dir> <state-file>` from the
   heartbeat loop (`bin/lib/docker-pool-token.sh`). `<env-dir>` is the dir
   the container mounts as `/run/harness-env`. `<state-file>` is a host file
   outside that dir, with `expires_at=<ISO>` written at spawn (the expiry of
   the token the bundle shipped; no line for a PAT build). It always returns
   rc 0 and prints one word: `off <why>`, `no-expiry`, `not-due`,
   `no-fresher`, `keep <why>` or `rotated <expires_at>`. The rules are those
   of `bin/fly-pool.sh` `rotate_gh_token`: rotate inside
   `POOL_GH_TOKEN_ROTATE_BEFORE` (1200 s) of expiry, at most once per
   `POOL_GH_TOKEN_ROTATE_EVERY` (1800 s), mint with `bin/gh-token.sh
   [--app $POOL_GH_APP_PROFILE] --min-life $POOL_GH_TOKEN_MIN_LIFE` (3300),
   and keep the old token when the new expiry is not later (the PAT that
   `gh-token.sh` prints on a failed mint). The same kill switches stop it:
   `GH_APP_TOKENS=0`, `gh-app-tokens-off`, `gh-app-rotate-off`,
   `GH_APP_ROTATE=0`. The token is written to `<env-dir>/gh-token` (mode
   600, temp file and `mv`), and `fly/gh-credential.sh` reads that file at
   push time. The token is never in argv, stdout, a log or the state file.
3. After the container exits, call
   `docker_pool_reap <project> <key> <build-dir> <cost-box> [auth_account]`
   (`bin/lib/docker-pool-reap.sh`) as box `$JOBS_BOX` with the jobs client
   sourced. `auth_account` is the Claude account the runner leased for the
   build. The function pushes the cost rows first (`bin/cost-rows-push.sh
   --box`, then `--verify`), then posts the result row. rc 0 prints
   `cost_rows unpriced_rows cost_verified claimed_at`. rc 9 is a refusal
   (`no_lease`, `superseded`, `already_reaped`, reason on stderr). rc 1 is
   no RESULT or a transport failure. The cost cursor is
   `<build-dir>/.cost-rows.cursor`, so a re-run sends only duplicates.
   Then end the lease with `docker_pool_release ... done` (or the sweep
   ends it).

## Why

#7300 change items 3 and 4, and acceptance test 3: "A finished local build
writes a priced cost row and a result row the hub reads."

## Tests

- `worker/jobs/test/docker-pool-results.bh-7348.test.js`: the route decision
  rules (P1-P16), the reap read (Q1-Q5), the seed (K1) and EXPLAIN QUERY PLAN
  at 5,000 results and 5,000 leases (E1).
- `tests/docker-pool-reap.bh-7348-test.sh`: the two host libs, the client
  function and the real `bin/jobs-watchdog.sh`, over real curl against the
  real worker (`tests/lib/docker-pool-worker.bh-7300.mjs`).
