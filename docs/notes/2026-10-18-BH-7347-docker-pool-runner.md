# Docker-pool host runner (BH-7347, slice C1 of #7300)

Doc: BUILD-CONCURRENCY

## What changed

A new host runner, `bin/docker-pool-runner.sh`, and its function library
`bin/lib/docker-pool-host.sh`. The runner runs ON a Docker host (a Mac with
Docker Desktop), not on the hub. It builds one queued pool ticket in local
Docker with the Fly builder image. It uses the C0 claim lease
(`bin/lib/docker-pool.sh`, `docs/notes/2026-10-17-BH-7300-docker-pool-lease.md`).
It calls the C2 functions (#7348: cost rows, result rows, token rotation) when
the tree has them. No file in `fly/` and no line of `bin/fly-pool.sh` changed.

## Verbs and exit codes

| verb | what it does | exit |
|---|---|---|
| `run <project> <key>` | builds the key the caller names | 0 finished (RESULT reaped, released `done`); 2 nothing queued for the key; 9 refused (`off`, `full`, `killed`, `lost`, held, fenced); 1 setup failure or no RESULT (a claimed row is released `queued`); 143 / 130 TERM / INT hand-off |
| `smoke <project>` | a SMOKE job: no claim, no lease, no hold gate; prints RESULT line 1 | 0 on `SMOKE_OK`, else 1 |
| `reap-orphans` | stops labeled containers whose lease file is past due; prints `<stopped> <kept>` | 0 |

`run`, in order:

1. Refuses a key that is `RB-*`, `SMOKE` or has a character outside
   `[A-Za-z0-9._-]`, before any request.
2. Deletes old work dirs (`DOCKER_POOL_KEEP_DAYS`) and runs `reap-orphans`.
3. Preflight: `docker info` answers, an image resolves, and
   `GET /api/queue?project=&key=&status=queued&target=fly` holds the row. This
   is the keyed form of `queue_list <p> queued fly`, so a queue of more than one
   page cannot hide the key.
4. `docker_pool_claim`. The worker applies `docker_pool.max_concurrent` and
   `docker_pool.kill`.
5. `job.json` through `queue_row_job_file` (the pool's own mapping) with the
   claimed ticket and attempt.
6. The file set (below), then the HOLD gate for a numeric ticket id
   (`hold_check` with the minted token). `held` and `unreadable` release the
   row `queued` and start no container. A board ticket id (not a number) has
   no GitHub issue and is not read.
7. `docker run -d --platform linux/amd64` with `POOL_MODE=1`, `PROJECT`,
   `FLY_MACHINE_ID=<tag>`, `HARNESS_CHECKOUT=/data/harness`,
   `WARMUP_WAIT_S=300`, `--hostname pool-<p>-<tag>`, `--cpus`, `--memory`,
   three bind mounts and three labels.
8. A heartbeat per `DOCKER_POOL_BEAT_S` (cut to a third of the lease left at
   the claim), a lease file per beat, and C2's `docker_pool_token_rotate` per
   beat when it exists.
9. Finish: `docker stop -t DOCKER_POOL_STOP_S`, copy `RESULT`, `job.json` and
   `logs/cost.csv` to `<work>/reap/`, C2's `docker_pool_reap` when it exists,
   then `docker_pool_release ... done`. No RESULT: `docker_pool_release ...
   queued`. The finish log line
   `docker-pool-runner: <p> <key> <outcome> result=<word|-> reap=<rc|absent> release=<done|queued>:<rc>`
   is written after the release returns.

The finish check, per beat: the build is done when `run/RESULT` is not empty
AND `docker logs` holds `job cycle complete` (the line `fly/builder-runner.sh`
logs after `run_job`, so its cost flush is done). RESULT without that line is
not done: the builder still appends TIER and PR lines. A container that is not
running ends the loop, and RESULT decides the release.

The heartbeat answer:

- rc 0: the lease file gets the new `lease_until`.
- rc 9 `killed` (`docker_pool.kill`): stop the container, no release (the
  worker already requeued the row), no ALERTS line.
- rc 9 any other reason (`lost`): stop the container, no release, one ALERTS
  line.
- rc 1 or 2 (the worker does not answer): go on while now is before the last
  `lease_until` minus `DOCKER_POOL_FENCE_S`. After that: `fenced`, stop the
  container, one ALERTS line. So the hub sweep never requeues a row that a live
  container still builds, while the runner lives.

The ALERTS line is `DOCKER POOL FENCE <project> <key> on <box>: ...`, id
`docker-pool-fence-<project>-<key>`, at most one per build.

SIGTERM / SIGINT: the trap stops the beat and the container, then releases
`done` (after the reap) with a RESULT, `queued` with none, and exits 143 / 130.

## Who names the key

The caller (an operator now). The runner never picks a row. It applies the
HOLD gate and the C0 claim rules (queued, target fly, max, kill). The other
pool gates in `pool_spawn_decision` (`bin/fly-pool.sh`) do not run here:
execute-empty stop, sibling serial, `After:`, open PR, terminal, spawn cap,
trigger actor. A later ticket can call `bin/docker-pool-runner.sh run` from the
dispatcher after those gates (#7297 moves dispatch to the scheduler).

## The file set

The core of `spawn_one` (`bin/fly-pool.sh`), from this host:

- `bin/fly-envbundle.sh <p> <work>/env --pool`.
- A repo-scoped App token (`bin/gh-token.sh [--app $POOL_GH_APP_PROFILE]
  --min-life 3300 <slug>`) when `gh_auth_armed`. It replaces the `GH_TOKEN=`
  line in `global.env`, adds `GH_TOKEN_INSTALLATION_ID`, and goes to
  `env/gh-token`. Its expiry goes to `<work>/gh-token.state` as
  `expires_at=<ISO>` (C2's rotation reads it). No App token and no PAT: the row
  is released `queued`, no container.
- `pool_account_lease <p> <key> <env>/global.env <tag>`. The tag is the
  machine id, released at every exit.
- The account-label overlay: the lease's own, else the host's
  `state/auth-accounts.local.json`.
- `harness_tarball` of `bin prompts rules catalog fleet.conf fly` from
  `DOCKER_POOL_CHECKOUT` (default: the repo root of the runner), extracted to
  `<work>/data/harness`. No `fly/builder-runner.sh` in it: setup failure.

Not shipped: the extra-read token for spec repos, the model-routes bundle, the
vercel deploy snapshot, preplan, reroute, build note and bake evidence. The
builder resolves each at job start or runs without it, as the pool's own
"push FAILED" branches allow.

The token goes to files through `printf` builtins only. It is never in argv,
stdout or a log.

## The work dir

`<DOCKER_POOL_ROOT>/<project>/<key>-<tag>/`, tag `dk-<YYYYmmddHHMMSS>-<4 hex>`
(never a Fly machine id, `[0-9a-f]{14}`):

| path | what | life |
|---|---|---|
| `env/` | mode 700, the container's `/run/harness-env` | removed at every exit |
| `run/` | `job.json`, `RESULT`, the container's `/run/harness` | kept |
| `data/` | the container's `/data` (a cold clone per build) | removed after the reap |
| `reap/` | `RESULT`, `job.json`, `cost.csv`: what C2's reap reads | kept |
| `lease` | one line: `lease_until` as epoch seconds | kept |
| `gh-token.state` | `expires_at=<ISO>` | kept |

Dirs older than `DOCKER_POOL_KEEP_DAYS` are deleted at each runner start. They
hold no money row: C2's result row is the record.

Container labels: `harness.docker-pool=1`,
`harness.docker-pool.lease=<work>/lease`, `harness.docker-pool.key=<KEY>`.
Only `reap-orphans` reads them. It stops a labeled container whose lease file
is past due or missing, and never touches a container without the label.

## FLY_MACHINE_ID in the builder

Two readers on the builder path, and no `fly/` edit is needed:

- `fly/entrypoint.sh`: `HOST="pool-$PROJECT-${FLY_MACHINE_ID:-...}"` is the box
  name and `COST_ROWS_BOX`. With `-e FLY_MACHINE_ID=<tag>` and `--hostname
  pool-<p>-<tag>` the container answers the same name. `hostname "$HOST"`
  fails without CAP_SYS_ADMIN, and that is harmless (`|| true`).
- `fly/builder-runner.sh`: `pool_result_row_put ... "${FLY_MACHINE_ID:-}"`
  stores the tag as the result row's machine. The hub reap reads result rows
  only for the machines it lists, so a `dk-` tag is never read as a Fly
  machine.

The entrypoint mounts a tmpfs at `/run/harness-env` only when it is not a
mountpoint already, and a bind mount is one. `POOL_MODE=1` skips tailscale.

## Knobs

Registry `catalog/lanes.d/_lib.docker-pool-host.json`, settings rows
`lib.docker-pool-host.<name lowercased>`, read by `dph_knob`.

| knob | default | rule |
|---|---|---|
| `DOCKER_POOL_IMAGE` | empty | empty = the fly_images row, else `state/fly/<p>.image`; not settable |
| `DOCKER_POOL_PLATFORM` | `linux/amd64` | the image is amd64 only (Rosetta on a Mac) |
| `DOCKER_POOL_CPUS` | 8 | 1..64 |
| `DOCKER_POOL_MEMORY` | `16g` | |
| `DOCKER_POOL_ROOT` | empty | empty = `$HARNESS/state/docker-pool`; not settable |
| `DOCKER_POOL_CHECKOUT` | empty | empty = the runner's repo root; not settable |
| `DOCKER_POOL_BEAT_S` | 60 | 10..600 |
| `DOCKER_POOL_FENCE_S` | 30 | 5..300 |
| `DOCKER_POOL_STOP_S` | 60 | 5..600, the cost-flush time |
| `DOCKER_POOL_MAX_BUILD_S` | 21600 | 600..86400, the hub's 360-minute claim window |
| `DOCKER_POOL_SMOKE_S` | 900 | 60..3600 |
| `DOCKER_POOL_KEEP_DAYS` | 7 | 1..90 |

The gate stays C0's: `docker_pool.max_concurrent` (0 = off, the seed) and
`docker_pool.kill`. In prod the runner claims nothing until an operator writes
a box row.

## Go-live steps (the Mac)

1. Pick the Mac's box name and set `JOBS_BOX=<name>` in its env.
2. Put a harness checkout and an env dir on the Mac (`HARNESS`,
   `HARNESS_SECRET`, `JOBS_URL`, `env/github-app.env`). `bin/fly-envbundle.sh
   --pool` reads the owning box's secrets over tailnet ssh, so the Mac needs
   that access.
3. Run `docker login registry.fly.io`.
4. Run the smoke: `JOBS_BOX=<name> bin/docker-pool-runner.sh smoke
   cromford`. Expect stdout line 1 `SMOKE_OK claude credential alive ...`.
5. Add a launchd entry for `bin/docker-pool-runner.sh reap-orphans` every 5
   minutes. A runner that dies leaves its container until this runs.
6. Write the settings row `docker_pool.max_concurrent.<name>` (for example 2).

## Not verified here

This box has no `docker` and no registry login. The suite
`tests/docker-pool-runner.bh-7347-test.sh` drives the entry point against the
real jobs worker with a stub `docker`. A live SMOKE on Docker Desktop is the
go-live step 4.
