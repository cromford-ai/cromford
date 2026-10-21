# The dedicated lane host: merge conductor and blocked-resolver on one Fly machine (BH-7716)

Doc: MERGE-CONDUCTOR, PROJECT-LANES

Pattern: BH-7636 (`box:<name>` placement), BH-7434 (fleet groups), BH-6890
(the conductor per project on a machine), BH-6495 (the SIGTERM hand-off).

## Why

The hub is overloaded (load5 40 to 81 on 4 vCPU on 2026-10-20). The merge
conductor and the blocked-resolver turn approved work into merged work, so
they wait behind pool ticks and health lanes. This change runs both lanes on
ONE dedicated Fly machine: performance-8x, 16 GB, a volume with a warm clone
of each fleet repo at `/root/repos/<project>`.

## The value

`lane_placement.<lane>` or `lane_placement.<lane>.<project>` = `fly-dedicated`.

- Valid only for a lane in the settings row `lane_dedicated.lanes` (seed
  `merge-conductor,blocked-resolver`; whitespace deleted, A-Z lowercased; no
  row = the same list in code). For any other lane, on `lane_placement.default`,
  with an empty list, or when the list read fails, it is `hub` and `LP_WHY`
  says why.
- It is `LP_PLACE=box`, `LP_BOX=fly-dedicated` (`bin/lib/lane-placement.sh`).
  A project row wins over the lane row, as for `fly`: a project row `hub`,
  `fly` or `box:<name>` under a lane row `fly-dedicated` keeps its own value.
- A non-empty `lane_placement.<lane>.hub_only` row keeps the lane on the hub.
- One rule, two readers: `lp_placement` (shell) and `placementsFrom` /
  `placementOf` (`worker/jobs/src/lib/lane-box-placement.js`). The table
  `tests/fixtures/bh-7716/dedicated-placement-cases.tsv` is read by the tests
  of both.

## What each side runs

| side | what it does |
|---|---|
| hub, merge-conductor | The cron tick still runs. For each placed project the BH-6890 gate (`mc_proj_gate`) publishes the snapshot and enqueues ONE `lane_runs` row, log tag `<project> project-box(fly-dedicated): ...`. It runs no PR read, no local PR worker and no landing for the project. A keyed tick (`MC_ONLY_PR`) of a placed project returns at the same gate. |
| hub, blocked-resolver | `blocked-resolver --dispatch` (`pl_dispatch`) enqueues one row per project (`placed: <n> fly, 0 hub (lane_placement.blocked-resolver=fly-dedicated)`) and starts no local run. |
| jobs worker | A lane row is the key `<lane>\|*`; the lane's other project rows are exceptions. `POST /api/lane-runs/claim` with `box: fly-dedicated` takes only these rows. A claim without `box` never takes a merge-conductor row of the box (the hub takes it back itself, BH-7636), and takes a blocked-resolver row only after `lane_run.group_fallback_s` (900 s; 0 = never). A group claim never takes one. `GET /api/lane-runs/stats?fleet=dedicated` counts only the box's rows and answers `box` and `placed`. |
| machine | `fly/lane-run-entrypoint.sh` with `LANE_RUN_WORKERS=6` starts 6 loops of `bin/lane-run-worker.sh --box fly-dedicated --machine <FLY_MACHINE_ID>-w<i>`. With `LANE_RUN_WARM_CLONES=1` a loop never evicts a clone, refreshes every fleet repo at most once per `lane_run.warm_refresh_s` (300 s), and ensures the row's clone before it runs the row. |
| fleet | `bin/lane-fleet.sh` runs the group `lane_fleet.group.dedicated` (app `lane-run-dedicated`). It starts the machine with `-v repos:/root/repos` and creates the volume once. The group's `warm_floor` (1) applies only while `placed` is true. When every row is back to `hub`, the floor is 0 and `lane_fleet.idle_stop_s` stops the machine. With no row placed, no queued row of the box and no machine, the pass makes no Fly call. |

## Warm clones

`lw_warm_ensure <project>` (`bin/lib/lane-run-warm.sh`), under
`locks/warm-<project>.lock`:

| state of `/root/repos/<project>` | result |
|---|---|
| missing | `git clone --filter=blob:none`, then the row runs |
| a dir with `.git` | `git fetch --prune origin`, then the row runs |
| a dir with `.git`, fetch fails | the row runs on the existing clone, one `kept-stale` log line |
| a dir without `.git` (a half clone) | moved to `<project>.broken-<epoch>`, then cloned |
| a symlink, or a clone that fails, or a project not in fleet.conf | the row is not run and is reported rc 75 `reason=clone-ensure` (a temp failure: the lease returns the row; no fix-round counter changes) |

The token is `bin/gh-token.sh --read <repo>`, sent as an `http.extraHeader`
through `GIT_CONFIG_*` env, never in argv, the URL or a log.

## Claim, heartbeat, stale reclaim, SIGTERM hand-off

All existing (BH-6124, BH-6125, BH-6495). Each loop has its own machine id, so
an expired lease of `<mid>-w1` is reclaimed by `<mid>-w2`. On a Fly stop the
entrypoint forwards TERM to every loop; each loop releases its row to `queued`
with its attempts kept, within `lane_run.term_grace_s`.

## Go-live steps (a person, after the merge and the worker deploy)

1. Create the app secrets (`fly/lane-run.toml` lists them):
   `flyctl secrets set HARNESS_SECRET=... JOBS_URL=... GH_APP_ID=... GH_APP_PRIVATE_KEY=... GH_APP_INSTALLATION_<OWNER>=... CLAUDE_CODE_OAUTH_TOKEN=... CODEX_AUTH_JSON=... CODEX_CONFIG_TOML=... -a lane-run-dedicated --stage`.
   `bin/lane-fleet.sh` creates the app itself when `FLY_ORG` is set in `env/fly.env`.
2. Set `FLY_API_TOKEN_LANE_RUN_DEDICATED` (or rely on `FLY_API_TOKEN`) in the hub's `env/fly.env`. Set `FLY_REGION` there if the volume must not be in `iad`.
3. Write the group row (the value is `tests/fixtures/bh-7716/dedicated-group.json`):
   `bin/jobs-client.sh setting-set lane_fleet.group.dedicated '{"app":"lane-run-dedicated","vm_size":"performance-8x","vm_memory":16384,"max_machines":1,"warm_floor":1,"box":"fly-dedicated","volume":"repos","workers":6}'`
4. Flip: `bin/jobs-client.sh setting-set lane_placement.merge-conductor fly-dedicated`, then the same for `blocked-resolver`.

Rollback: the same rows set to `hub`. The machine stops after
`lane_fleet.idle_stop_s`.

Cost: performance-8x 16 GB is about $0.45 per hour (`catalog/fly-prices.json`),
about $324 per month while a row is placed.

## Probes

- `GET /api/lane-fleet/machines?app=lane-run-dedicated`: one `started` machine.
- `GET /api/lane-runs/stats?fleet=dedicated`: `placed: true`, the queued rows of the box.
- Hub `logs/merge-conductor.log`: `<project> project-box(fly-dedicated): enqueued merge-conductor <project>`.
- Machine `logs/lane-run-worker.log`: `warm ensure <project>: cloned|fetched|kept-stale`, `warm refresh: <n> repos in <s>s`.

## Measurement (the ticket's "proof after merge")

Before the flip and 24 h after it, over the last 10 merged harness PRs:

1. Conductor tick time. The hub conductor writes no tick duration line today.
   Before: per cron fire, the span from its first to its last
   `logs/merge-conductor.log` line, p50 and p90 over 24 h. After: per
   `lane_runs` row of lane merge-conductor, `finished_at - claimed_at`
   (`GET /api/lane-runs/stats?fleet=dedicated&run_p50=1` gives the p50).
2. "approved + green" to "queued": per PR, the time between the `pr_state`
   ledger transition to approved with green CI and the transition to queued
   (`GET /api/ledgers?kind=pr_state`).
