# The pool tick of one project on a lane-run machine (BH-7505)

Part of #6881. Pattern: BH-6890 (merge conductor per project). Plan source:
docs/notes/2026-10-15-BH-6896-fly-pool-offhub.md (slice S5).

## What it does

With `lane_placement.fly-pool.<project>` = `fly`, the hub tick of that project
(`bin/fly-pool.sh`, after its flock and the lane gate) calls `pp_gate`
(`bin/lib/pool-placement.sh`). The gate enqueues ONE `lane_runs` row (lane
`fly-pool`, args `bin/fly-pool-project.sh <project>`) and the hub does no row
work. A machine of the fleet group claims the row, takes the project lease,
runs `bin/fly-pool.sh <project>` with `POOL_ON_MACHINE=1`, and posts
write-backs.

Rows: `lane_placement.fly-pool.<project>` (`fly`|`hub`), the lane row
`lane_placement.fly-pool`, `lane_fallback.fly-pool.<project>` (`hub`|`off`).
The default row never places a pool. No row: today's hub tick.

## Inputs

| input | source on the machine |
|---|---|
| queue files, pool state, spawn records, markers, flags, fly app and image pointer, caps, overlap After: markers, custody markers | snapshot (`catalog/lane-run-inputs.d/fly-pool.rw` and `.ro`) fetched by `lri_fetch` |
| queue rows, pool rows, model routes, machine rows, account leases | jobs API (`JOBS_URL`, `HARNESS_SECRET`) |
| GitHub App token | `env/github-app.env` written by the lane-run entrypoint from the Fly secrets `GH_APP_ID`, `GH_APP_PRIVATE_KEY`, `GH_APP_INSTALLATION_*` |
| Fly API token | Fly secret `FLY_API_TOKEN_project-6_OS` (or `FLY_API_TOKEN`) on `lane-run-mk`, read from the environment by `fly_token_resolve` |
| build artifacts a reap pulls home | written on the machine, carried back by the write-only list `fly-pool.wo`, never in a snapshot |

## One run at a time

The project lease (lane `fly-pool`) is the lock. The machine holds it for the
whole run. The hub holds it for its whole tick when a Fly run is possible (a
fallback, a take-back, a backoff, or a rollback with the placed mark set), with
a renewer that ends with the tick. A second holder gets 409 `held` and does
nothing. `pp_fence_ok` renews the fence before a spawn and before a destroy: a
lost lease is rc 99 and nothing is spent; an unanswered renew stops a machine
and not the hub (its flock still holds).

## Write-backs

`pp_checkpoint` posts a write-back after each spawn record. The entry posts one
more when the run ends or on TERM. The hub applies them with compare-and-set
(`lri_apply_pending`, acked, so a second apply adds nothing) before every row
decision that follows a finished run, and before every hub fallback. The
machine's log bytes ride back once (`logs/fly-pool.log`); the entry writes a
`fly run start` and a `fly run end` line so the hub log shows which lines a
machine wrote.

## Fallback, backoff, rollback

- Unclaimed row older than `POOL_FLY_QUEUE_STALE_S`: withdrawn, hub runs the tick.
- Machine run failed or deferred: hub runs the tick once, then enqueues no new
  row for `POOL_FLY_TAKEBACK_BACKOFF_S`.
- `lane_fallback` = `off`: the hub runs nothing and one ALERTS line goes out.
- Rollback: set the placement row to `hub`. The next hub tick withdraws a
  queued row, takes the lease (waits if a Fly run holds it), runs, and clears
  the placed mark.

## What a machine needs before a spawn works

`bin/fly-pool-project.sh --preflight <project>` names what is missing, and a
run that finds anything missing defers (`PROF ... state=DEFERRED deferred=...`)
so the hub takes the tick back. Today the lane-run image lacks all of these:

1. `fly-binary`: flyctl in the image (`fly/lane-run.Dockerfile`).
2. `fly-token`: the Fly secret above.
3. `harness-src`: a tree with bin, prompts, rules, catalog, fly at
   `POOL_HARNESS_SRC` (`/root/harness-checkout` by default). The image carries
   only bin, catalog and fleet.conf.
4. `env-bundle`: `bin/fly-envbundle.sh` reads the owning box over the tailnet
   (project-6-os: box-project-6-os-1). A machine has no tailnet ssh. This is
   BH-6896 slice S3.

Until 1 to 4 are met the flip is safe and useless: the machine defers, the hub
runs the tick.

## Single-run and write-back fixes (BH-7519, from the #7515 review)

- An unanswered lease request is no hub work. `_pp_take` runs only for a project
  placed fly or with a `.placed` mark, and the hub flock does not stop a machine.
- A rollback keeps `.placed` until the newest row is over: withdraw rc 0, or
  none, done, failed, deferred or withdrawn. A claimed row, an unreadable row
  and a withdraw that gets no answer keep the mark.
- `pp_fence_ok` runs again just before `fly machine run` (the first check is
  about 12 minutes older). Rc 99 hands the claim back (`pool_unclaim`). The reuse
  handoff is fenced too.
- `pp_checkpoint` runs after the reap park record and before the machine is
  destroyed or handed on.
- `pp_fence_ok` loads `bin/lib/project-lease.sh` when it is missing. The tick
  is a child of the entry script and does not inherit its functions, so every
  machine fence read "renew unavailable" and stopped the spawn.
- The TERM path: the tick's wait is cut to `lane_run.term_grace_s` minus 12 s,
  and the write-back is cut at the grace deadline.
- `POOL_PROJECT_RENEW_S` is read through `lane_env_apply` and capped at a third
  of the lease TTL. Stop files of dead hub ticks are pruned. A row lookup asks
  for the whole 50-row window and picks the exact project; a full window with no
  row of the project is `unread`, never `none`.

## Known limits

- A build record file over `lane_snapshot.file_max` (262144) stays on the
  machine; the lane log names it.
- A SIGKILL between `fly machine run` and the spawn checkpoint leaves a build
  machine the orphan release and the warmup exit end.
- `state/auth-accounts.local.json` and `env/tokens.d` are not carried: a
  machine spawns on the global account.
- `plans/<p>-<KEY>` is not carried; `preplan_fetch` serves the pre-plan.
