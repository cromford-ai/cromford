# Lane-run image: flyctl, harness tree and Fly token for a pool tick (BH-7516)

Doc: PROJECT-LANES

## What changed

`bin/fly-pool-project.sh --preflight <project>` (#7515) checks four things
before a pool tick runs on a lane-run machine. This change supplies three of
them. The fourth, `env-bundle`, is BH-6896 S3.

- `fly-binary`: `fly/lane-run.Dockerfile` has a new `bake-flyctl` block. It
  installs the flyctl release named by the build arg `FLYCTL_VERSION` into
  `/root/.fly/bin` (the `FLY_BIN_DIR` default), links `fly` to it, and puts the
  directory on PATH. The arg has no default. `bake_require` stops the build on
  an empty arg, `bake_sha256` checks the tarball against the release's
  `checksums.txt`, and `bake_verify` checks `flyctl version`. The value comes
  from the new settings row `bake.flyctl.version`. The row is not in
  `bin/lib/bake-deps.sh`, because that manifest feeds the pool image.
- `harness-src`: the image now also copies `prompts`, `rules` and `fly` into
  `/opt/harness`, and sets `POOL_HARNESS_SRC=/opt/harness`. The code sync
  (`bin/lib/lane-run-code.sh`, `lrc_sync`) swaps those three paths too, so they
  stay at `HARNESS_COMMIT` after the first sync. It swaps a path only when the
  fetched commit has it. A failed archive of a path the commit has fails the
  sync, and the tree stays unchanged.
- `fly-token`: `fly/lane-run-entrypoint.sh` writes `fly.env` (mode 600) with
  each `FLY_API_TOKEN` and `FLY_API_TOKEN_<P>` variable, shell-quoted with
  `%q`. A Fly token has a space (`FlyV1 ...`), and `bin/fly-pool.sh` sources
  the file. With no token the file is empty, so that source does not fail.
  `FLY_ACCESS_TOKEN` and the other `FLY_*` variables are never copied.
  `bin/lane-fleet.sh`'s `app-secrets` alert now names the token and its staging
  command. The ready gate still needs only `HARNESS_SECRET` and `JOBS_URL`.

## Operator steps

1. Set the row: `bin/jobs-client.sh setting-set bake.flyctl.version <x.y.z>`
   (a flyctl release number, no `v`).
2. Stage the token on the group app. The value goes through stdin, never argv:

   ```bash
   ( set -a; . /etc/harness/env/fly.env; \
     printf 'FLY_API_TOKEN_project-6_OS=%s\n' "$FLY_API_TOKEN_project-6_OS" ) \
     | flyctl secrets import -a lane-run-mk --stage
   ```
3. Rebuild the image with the deploy command in `fly/lane-run.toml` (it now
   passes `--build-arg FLYCTL_VERSION=...`).
4. On a lane-run-mk machine, run `bin/fly-pool-project.sh --preflight
   project-6-os`. The answer must be `preflight project-6-os: missing
   env-bundle` until BH-6896 S3.

## Image size and boot time

Not measured here. This box has no docker and no flyctl, and no network to the
flyctl release. The local proxy: the three new directories are 880 KB
(`du -sk prompts rules fly`). The flyctl tarball size was not read.

To measure: build the image at `origin/main` and at the branch head with
`flyctl deploy . -c fly/lane-run.toml --build-only --image-label bh7516-before`
(and `-after`), read the size with `flyctl image show`, then start one machine of
each image in `lane-run-mk` and record the time from `machine run` to the first
`lane-run-worker` log line.

## Tests

`tests/lane-run-image.bh-7516-test.sh` (I1-I5, H1-H4, K1-K4, P1). P1 builds a
machine root from the Dockerfile's own `COPY ... /opt/harness/...` lines and
runs the real `--preflight` when `bin/fly-pool-project.sh` is in the tree. Before
#7515 merges it checks the three ingredients one by one.
