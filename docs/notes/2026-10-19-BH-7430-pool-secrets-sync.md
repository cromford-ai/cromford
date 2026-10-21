# BH-7430: pool secrets sync and the machine-pull switch (operator steps)

Spec: `docs/notes/2026-10-15-BH-6896-fly-pool-offhub.md`, section 4 (S3).
Doc: none

## What changed

With `POOL_MACHINE_PULL=1` on a project, `bin/fly-pool.sh` ends a spawn at ONE
`fly machine run`. The hub makes no box ssh, no `sleep 20`, no `ssh sftp` and
no `ssh console` push for that spawn. The machine gets its parts as follows:

| part | where it comes from | written by | read by |
|---|---|---|---|
| harness | a shallow git fetch of `HARNESS_SHA` (the hub checkout HEAD) from `HARNESS_SLUG` | the hub, as `-e` on `machine run` | `fly/harness-fetch.sh`, run by `fly/entrypoint.sh` |
| static env | the pool app's Fly secrets `HBUNDLE_G_<VAR>`, `HBUNDLE_P_<VAR>`, `HBUNDLE_SYNCED_AT` | `bin/fly-pool-secrets-sync.sh <project>` (operator) | `fly/entrypoint.sh` (seed block) |
| token files | ONE `--file-secret /run/harness-seed-secret/bundle.b64=SEED_<epoch>_<hex>`: a base64 tar.gz of `global.override.env` (App token, installation id, read tokens, leased account, `OPENROUTER_FALLBACK`), `gh-token`, `gh-token-read`, `gh-token-harness` and `auth-accounts.local.json`. The SEED_ app secret is imported by stdin (`--stage`) just before the launch | `spawn_one` (`pool_pull_seal`) | `fly/entrypoint.sh` unpacks it into the RAM-only tmpfs and deletes the rootfs copy |
| job and relays | `--file-local /run/harness-seed/<push path>=<file>`: `job.json`, pre-plan, reroute, build note, bake evidence, deploy snapshot, model routes. No token is in these files | `spawn_one` (mput seed mode) | `fly/entrypoint.sh` moves each file to its push path |
| row stamp | `psr_claim_machine` from the machine, after the fetch | `fly/entrypoint.sh` (`POOL_CLAIM_MACHINE=1`) | the worker |

A spawn takes the push path, and logs `<key>: push path (<why>)`, when one of
these is missing: the `HBUNDLE_SYNCED_AT` secret, a 40-hex git HEAD in
`/root/harness-checkout`, a minted App token (not the PAT), a read token for the
harness repo, or a seed of at most `POOL_SEED_MAX_BYTES`.

NO TOKEN IS IN THE MACHINE CONFIG. flyctl stores `--file-local` content as
`config.files[].raw_value`. `fly machines list --json` returns it to anyone with
the app's Fly token, also after the machine is destroyed, and the idle reaper,
`bin/lane-fleet.sh` and `bin/fly-pool.sh` write that listing to hub files. So the
token files travel as the secret-backed file above: the config holds only the
secret NAME. `pool_pull_prime` unsets each SEED_ secret older than 15 minutes
(`POOL_SEED_SECRET_TTL_S`), from the names of its one `fly secrets list` per tick
(10 s timeout; a timeout sends the next 5 minutes of spawns down the push path).
A token bundle that does not unpack on the machine writes
`BUILD_DEFERRED seed-unseal: ...` and exits, as a failed fetch does.

A failed harness fetch on the machine writes the pool-result row
`BUILD_DEFERRED harness-fetch: <why>` and exits. The reap requeues it as a
deferral. It does not count a death.

## What the sync writes

`bin/fly-pool-secrets-sync.sh <project>` runs `bin/fly-envbundle.sh <project>
<tmp> --pool` once (one ssh to the owning box). It maps each `KEY=VAL` of
`global.env` to `HBUNDLE_G_KEY` and each line of `<project>.env` to
`HBUNDLE_P_KEY`. It adds `HBUNDLE_SYNCED_AT=<UTC>`. It writes all of them in one
`fly secrets import --stage -a pool-<project>`. Then it unsets (`--stage`) any
other `HBUNDLE_*` name on the app.

- `GH_TOKEN` and `GH_TOKEN_INSTALLATION_ID` are NOT synced. A pull spawn always
  carries a minted App token, so the owning box's PAT stays off the app.
- Values go through `fly secrets import`, which reads dotenv. A value of only
  `[A-Za-z0-9_.\/:@+,=-]` is written as is. Any other value (space, `#`, `"`,
  `$`) is written in single quotes. A value with a single quote stops the sync
  with an alert that names the key (never the value).
- `--stage` restarts no live machine. The next `fly machine run` gets the values.
- `--dry-run` prints the names it would import and unset. It prints no value.
- A failure writes one ALERTS line that names the app and the step.

## Operator steps, per pool app (project-6-os first)

Do these for `pool-project-6-os` first. Do the next project only after step 7
passes on project-6-os. The other pool apps are the `.app` values of
`state/fly/*.json` on the hub.

1. Bake a new pool image that carries `/opt/fly-boot/harness-fetch.sh`
   (`fly/Dockerfile`, the image bake lane BH-2523). An older image ignores
   `HARNESS_SHA` and waits for a tarball that never comes.
2. On a box with flyctl, confirm the flag: `fly machine run --help | grep -- --file-local`.
   If it prints nothing, stop. Keep the knob at 0.
3. Run `bin/fly-pool-secrets-sync.sh project-6-os --dry-run`. Check the names.
4. Run `bin/fly-pool-secrets-sync.sh project-6-os`.
5. Run `fly secrets list -a pool-project-6-os` and confirm `HBUNDLE_SYNCED_AT` is listed.
6. Set the row `lane.fly-pool.project-6-os.machine_pull` to `1`.
7. On the next tick, read `logs/fly-pool.log`. Each spawn says
   `spawned <mid> for <key> (pull, live=...)` and `<mid>: seeded N file(s)`.
   On the machine, `logs` show `harness-fetch: ... into /data/harness` and
   `env: composed global.env`. The build reaches RESULT.
8. If step 7 fails, set the row back to `0`. The next spawn takes the push path.

Run step 4 again after a change to the owning box's env for that project. A
secret change does not need a rebake.

## Assumptions not verified on the build box

- `fly machine run --file-local` exists and takes small files (step 2 checks it).
- A staged secret (`--stage`) is in the env of a machine that `machine run`
  creates later.
- `fly secrets import` keeps each value verbatim after the first `=`.
- `fly machine run --file-secret` takes a staged app secret, and the file holds
  the secret value as is (no extra base64 decode). Probe check 2a proves both.
- `fly secrets import` strips single quotes from a single-quoted dotenv value.
- A value up to 20000 base64 bytes is accepted as one secret. Larger: the spawn
  logs `seed secret staging FAILED` and the job stays queued.
- The token file exists on the machine rootfs (Fly writes it) from boot until
  the entrypoint deletes it. The rootfs is ephemeral. Only the tmpfs copy stays.
- The lease rank on the pull path sees no `EXECUTE_MODEL` (it is a line of the
  box's `<project>.env`, which the hub no longer reads per spawn). The rank then
  uses its default weight.

## Probe (the acceptance check; NOT run on the build box)

Part 1 needs a Fly token for a TEST app and a pool image with the new entrypoint:

    FLY_API_TOKEN=<test-app token> bin/fly-pool-probe-pull.sh <test-app> <image>

It stages a throwaway secret, starts one machine with `--file-secret`, then
checks over `ssh console` that the file has the same bytes, mode 600, and no
rootfs copy. It checks that `machines list --json` shows `secret_name` and no
token value. It destroys the machine and unsets the secret. Exit 0 = all held.

Part 2, on the test pool app after steps 1 to 5 above: queue ONE fixture job on a
test project, set `machine_pull=1`, run one tick, and wait for the pool-result row
`RESULT` for that key (the ledger row `pool-result/<project>/<key>`). Then measure
the hub CPU per spawned job: run `BH7430_MEASURE=1 bash tests/fly-pool-machine-pull.bh-7430-test.sh`
for the stub numbers, and on the hub compare `time` (user+sys) of two ticks, one
with 0 jobs and one with 3 jobs, divided by 3. Target: 2.15 to at most 0.80 CPU s.
