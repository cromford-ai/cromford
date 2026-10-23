# Fly pool dead-machine sweep (stopped machines, orphan jobs, failed destroys)

**What it is:** the part of `bin/fly-pool.sh`'s tick that looks at the pool app
as a whole rather than one tracked machine at a time. Every tick reads ONE
`fly machines list`, uses it to answer liveness for every tracked machine, then
destroys the untracked machines that have been sitting `stopped`/`failed`/
`suspended` past a TTL, and records what it saw in
`state/fly-pool/<project>/.sweep.json` for `bin/fleet-fly-block.sh` to publish.

It exists because `fly/builder-runner.sh` has told machines since wave 3 that "a
stopped pool machine is then destroyed by fly-pool.sh's dead-machine sweep" and
nothing ever listed the app. The REAP loop only visits machines that have a
`state/fly-pool/<p>/<machine>.json` tracking file, so the moment a destroy
failed — and every destroy was `>/dev/null 2>&1` with its exit code dropped, and
the tracking file removed regardless — the machine left the harness's field of
view for good. BH-660 counted 18 of them across two pools.

Since BH-1056 the tick also writes to the Fly machine registry rows
introduced in BH-1054: it refreshes the observed machine list once per usable
listing, records every spawn and reuse, and closes rows at every terminal
destroy. These writes are advisory and fail-open — when the `fly_machines_rows`
setting is off or missing, or when the worker is unreachable, the tick issues no
worker requests and its file lifecycle is unchanged. §2, §3c and §6 of
`tests/fly-machines-rows-pool.bh-1056-test.sh` are what check that, on the spawn,
reuse and reap paths respectively.

Since BH-2522 `bin/fly-pool-tick.sh` runs `bin/fly-pool-rows-parity.sh
--backfill --flip` after every pool has settled. It compares each
`state/fly-pool/<p>/*.json` with the project's live machines rows. While the
flag is off it backfills a row for every file that has none, then re-reads the
rows to confirm. Once every file older than 240 s has its keyed row, and the
settings row is still the untouched seed (`value=off`, `actor=seed`), it sets
`fly_machines_rows=on` itself. An operator's `off` (any other actor) and a
`FLY_MACHINES_ROWS` env value are never overridden. From then on it runs
report-only, and `bin/sweep-stale-builds.sh` takes its pool evidence from the
rows instead of from files, with no ssh.

**How an operator reaches it:** `cron/hub.cron` `*/10` → `bin/fly-pool-tick.sh` →
one `bin/fly-pool.sh <project>` per `flags/fly-pool-<project>`, each self-locking
on `locks/fly-pool-<project>.lock`. Since BH-7890 the wrapper classifies the
projects first (`ptb_split`), and it runs `bin/fly-lock-guard.sh` and reads
`bin/pool-cap.sh --autoscale` only when a project is left for the hub (the
guard also runs before an onboard launch); a fly-placed project gets no hub
start in either autoscale mode
(`HARNESS_TEST_SANDBOX=1 bash tests/fly-pool-tick-autoscale-move.bh-7890-test.sh`).
Inside that script:

| region | what it does |
|---|---|
| `# >>> machine destroy (BH-660)` | `destroy_machine` — the one destroy path, used by all six call sites; `machines_row_close` writes the terminal row state (`destroyed`, `gone`, or `destroy_failed` with flyctl's error as detail) |
| `# >>> pool listing (BH-660)` | the tick's single `machines list`, with the fail-open fallback; when the listing is usable, `machines_row machines_observe` refreshes the registry before the REAP loop mutates state |
| `# --- Fly machine registry advisory row writes (BH-1056)` | `machine_put` after spawn/reuse JSON writes; `machines_row_close` at every terminal destroy; advisory log when a live row has no matching local tracking file; all guarded by `machines_rows_on` and `command -v machines_row` |
| `# >>> dead-machine sweep (BH-660)` | the sweep itself, after REAP and before SPAWN |

There is **no UI route.** The operator surfaces are files and one console tile:

- `logs/fly-pool.log` —
  - `sweep <project>: listed=N stopped=N destroyed=N destroy_failed=N orphans=N ttl=600s`
    (written only when there is something to report; a clean tick stays quiet)
  - `row says <key> is live on <machine> and no file says so — spawning anyway
    this cycle (BH-1035 advisory; the row becomes the gate next slice)`
    (only when `fly_machines_rows` is on and a live registry row has no matching
    tracking file)
  - `machines row: <verb> <app> failed (worker unreachable or refused) — file is
    authoritative this cycle` (once per tick on the first worker failure;
    subsequent failures this tick are silent, because a worker that is down is
    down for every verb)
- `logs/ALERTS.log` — three shapes, each deduped by a dated flag under `flags/`:
  - `machine destroy <id> FAILED rc=<n>: <flyctl's error> — still in <app>; the sweep retries it next tick` (once per machine per UTC day)
  - `machines list for <app> unusable (<reason>) — dead-machine sweep skipped; stopped machines are not being reclaimed until it answers` (once per project per day)
  - `<KEY> still tracked on <id> which Fly no longer returns after the reap — the dead path did not close it` (once per key per day)
- `state/fly-pool/<project>/.sweep.json` — a DOTFILE, deliberately: every reader
  of that directory globs `*.json` and must not see it as a machine. Shape:
  `{at, listing:"ok", listed, ttl_s, capped, stopped:[{machine,state,age_s}], unaged:[id], destroyed:[id], destroy_failed:[{machine,rc,error}], orphan_jobs:[{machine,key,ticket_id}]}`,
  or `{at, listing:"failed", reason}` when the listing could not be used — an
  unknown is written as an unknown, never as a zero.
- `state/fly-pool/.parity.json` (BH-2522) — a DOTFILE at the top level, so no
  reader that globs `state/fly-pool/*/` or `<p>/*.json` sees it. Shape:
  `{at, box, verdict:"parity"|"drift"|"unknown", flag, flag_source, flip, sig, projects:{<p>:{status, files, rows, young, file_without_row:[id], row_without_file:[id], unreadable:[file]}}, reason?}`.
  `flip` is `none`, `done`, `failed`, `held` (not parity), `env`, `operator` or
  `deferred_young`. `bin/fly-pool-rows-parity.sh --json` prints the same object.
- `logs/fly-pool.log`, `[pool-parity]` lines (BH-2522), written only when the
  verdict, flag, flip or counts changed since the last report:
  - `parity <verdict> (flag=… flip=… files=N rows=N file_without_row=N unreadable=N)[ — <reason>]`
  - `fly_machines_rows flipped on after parity (files=N rows=N)` (once, plus a
    `fly_machines_rows_flipped` fleet_event beat)
  - `fly_machines_rows is off by <actor> (operator-set, not flipping) …`
- `logs/ALERTS.log`, `[pool-parity]` (BH-2522), each deduped by a dated flag:
  the flip PUT failed (`flags/alerted-fly-rows-flip-<YYYYMMDD>`), or, with the
  flag on, the same machine has had no live keyed row two runs in a row
  (`flags/alerted-fly-rows-drift-<YYYYMMDD>`).
- the console Fleet tile and `/machines`, through `bin/fleet-fly-block.sh`, which
  adds `orphan_jobs`, `stopped_machines`, `destroy_failed`, `sweep_at` and
  `sweep_listing` to a project's block **only when a sweep file exists**.

**Knobs** (resolution order, first usable value wins; a non-numeric value is
named in `fly-pool.log` and skipped, never clamped):

| knob | resolves | default |
|---|---|---|
| seconds a machine must have been stopped | `POOL_STOPPED_TTL_S` (env/global.env) → `bin/jobs-client.sh setting-get pool_stopped_ttl_s` → default | `600` |
| destroys per tick | `POOL_SWEEP_MAX_DESTROY` (env/global.env) → default | `25` |
| Fly machine registry rows | `FLY_MACHINES_ROWS` env (`on`/`off`) → `bin/jobs-client.sh setting-get fly_machines_rows` exact `on`/`off` → off | `off` (seeded); flipped `on` by `bin/fly-pool-rows-parity.sh` after file/row parity, only while the row is still the seed (BH-2522) |

No seed row is needed: an absent settings row means "use the documented
fallback" (see [settings-knobs.md](settings-knobs.md)).

**How to drive it:**

| what | how |
|---|---|
| the sweep: TTL, the bound, the knobs, every negative, the failed-destroy alert | `HARNESS_TEST_SANDBOX=1 bash tests/fly-pool-sweep-test.sh` |
| liveness off the listing, requeue/park of a job whose machine is gone, the snapshot keys, the builder-record retirement | `HARNESS_TEST_SANDBOX=1 bash tests/fly-orphan-jobs-test.sh` |
| the snapshot shape for projects with no sweep | `HARNESS_TEST_SANDBOX=1 bash tests/fleet-status-fly-test.sh` |
| the registry row writes: observe, put, close, advisory, and fail-open behavior | `HARNESS_TEST_SANDBOX=1 bash tests/fly-machines-rows-pool.bh-1056-test.sh` |
| file/row parity, the backfill, the seed-only flip and its negatives, the tick wiring (BH-2522) | `HARNESS_TEST_SANDBOX=1 bash tests/fly-pool-rows-parity.bh-2522-test.sh` |
| the stale-build sweep reading rows (flag on) or hub files (flag off), never ssh (BH-2522) | `HARNESS_TEST_SANDBOX=1 bash tests/sweep-stale-builds-rows.bh-2522-test.sh` |
| parity on a live hub, read-only | `HARNESS=/root/harness bin/fly-pool-rows-parity.sh --json` (no `--backfill`/`--flip`: it writes only `.parity.json`) and `bin/jobs-client.sh setting-get fly_machines_rows` |
| the suites read one clock and no network | `bin/test-determinism-lint.sh tests/fly-pool-sweep-test.sh tests/fly-orphan-jobs-test.sh tests/fly-machines-rows-pool.bh-1056-test.sh` |
| on a live hub, after a tick | `grep 'sweep ' /root/harness/logs/fly-pool.log \| tail` and `HARNESS=/root/harness bin/fleet-fly-block.sh \| jq '.[] \| {stopped_machines, sweep_at, sweep_listing}'` |

**Preconditions / seed needs:** a project with `flags/fly-pool-<p>` AND
`flags/fly-pool-app-<p>` (the dedicated pool app), plus `FLY_API_TOKEN_<P>` in
`env/fly.env`. No new env var is required — both knobs have documented
fallbacks. Nothing to apply to a database.

**What must never regress:**

- **The sweep never runs without `flags/fly-pool-app-<p>`.** Without a dedicated
  pool app, `$APP` is the persistent `builder-*` app, and that app recreates
  machines on destroy — the SPRAWL GUARD at the top of `bin/fly-pool.sh`. No
  listing, no destroy, no `.sweep.json`.
- **An unusable listing is not an empty pool.** A `[]` answer beside tracking
  files, a non-JSON answer, and a non-zero exit all mean: fall back to the
  per-machine `machine status` call, skip the sweep, log it, page once a day.
- **Started/starting/created/replacing/stopping/destroying are never touched** —
  including `bin/fly-pool-rollout.sh`'s untracked smoke machine.
- **An unknown age is not an old age.** A missing or unparseable `updated_at`
  is reported under `unaged` and never destroyed.
- **The reap and the sweep never both destroy one machine in one tick.** The
  reap claims every machine it visits for the whole tick (`REAPED_IDS`), because
  it deletes the tracking file on every terminal path.
- **A failed destroy is never logged as a success**, and it never costs a build
  its row: the tracking file still goes, and the machine comes back to the sweep
  on a later tick.
- **Registry row writes are advisory and fail-open.** When `fly_machines_rows` is
  off/missing or the worker routes are down, the tick issues zero
  `/api/machines*` requests, leaves the file lifecycle unchanged, exits 0, and
  logs at most one `machines row:` line. A missing `jobs-client` contract or a
  function sourced alone must never cause an error — `next_job_or_destroy` is
  extracted and sourced with nothing else by `tests/pool-account-routing-test.sh`
  and `tests/hotfix-cap-exempt-test.sh`, so both of its row calls are
  `command -v`-guarded.
- **The flag is flipped only on parity, only over the seed.** A worker outage,
  a 404, a full 500-row page, an unreadable file, a file whose row is missing or
  carries another key, a young file with no row yet, `FLY_MACHINES_ROWS` in the
  env, or an `off` written by anyone but `seed` must never produce a
  `PUT /api/settings`. A backfill counts only after the re-read shows the row.
- **The reuse row carries no image.** `IMAGE` is assigned in the SPAWN half of
  the tick, ~900 lines below `next_job_or_destroy`; naming it on the reuse row
  killed the whole tick under `set -u`, after the queue file was consumed and
  the machine json rewritten but before the reuse was pushed or logged. §3b of
  the suite drives a real reuse through the entry point and pins it.

**Manual-only / not automatable from a box:**

- The two persistent **builder machines** behind the retired records. A
  one-shot in `bin/fly-pool-tick.sh` (BH-660, removed in BH-7433 after it ran on
  every pool project) moved their ids under `builder_retired` in
  `state/fly/<p>.json` and sent one ALERTS line with the exact
  `fly machine destroy <id> -a <app> --force`. The machine is destroyed by a
  human, because this harness must not run a Fly command against a `builder-*`
  app and those machines carry volumes. `bin/fleet-fly-block.sh` still does not
  publish a `builder_retired` record as a builder.
- **Tailnet nodes.** The harness holds no Tailscale API credential (only
  `TS_AUTHKEY`, handed to machines by `fly/entrypoint.sh`), so retiring offline
  `builder-*` nodes is a Tailscale admin console action: Machines → select the
  offline nodes → remove.
