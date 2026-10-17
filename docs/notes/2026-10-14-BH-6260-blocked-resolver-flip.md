# blocked-resolver is placed on Fly (BH-6260)

Doc: PROJECT-LANES

## What changed

- Schema fragment `worker/jobs/schema.d/202610170602-bh-6260-blocked-resolver-flip.sql`
  seeds `lane_placement.blocked-resolver=fly`. After `bin/harness-sync.sh`
  applies it, `lp_decide blocked-resolver` answers
  `fly|lane_placement.blocked-resolver=fly`. The hub publisher
  (`bin/lane-snapshot-publish.sh`) then publishes a snapshot for each project,
  and the dispatch enqueues `lane_runs` rows that the Fly lane machines claim.
  `INSERT OR IGNORE` keeps a value an operator already set.
- Two code constants are now settings rows, seeded by the same fragment:

  | row | seed | accepted range | out of range or unset |
  |---|---|---|---|
  | `lane_snapshot.file_max` | 262144 | 1..1000000 (`LRI_PART_BYTES`) | 262144 (`LRI_FILE_MAX`) |
  | `lane_snapshot.prune_after_s` | 604800 | 3600..7776000 | 604800 |

  `lane_snapshot.file_max` is read by `_lri_file_max` in
  `bin/lib/lane-run-inputs.sh`. The hub snapshot list and the machine
  write-back list use the same row. Each side reads the row when it lists, so
  the cap at checkpoint time can differ from the cap at fetch time. The
  checkpoint therefore never sends a deletion for a file that is still on the
  machine: a file over the cap at checkpoint time stays out of the write-back,
  the hub copy stays, and one line goes into the run log
  (`checkpoint: <lane>/<p> <relpath> (<bytes> bytes) is over
  lane_snapshot.file_max=<n>; not in the write-back, the hub copy stays`). The
  run log reaches the hub with the write-back. If the run itself grew the file
  past the cap, the run's edit does not reach the hub.
  The upper bound keeps one file inside one write-back body.
  `lane_snapshot.prune_after_s` is read by `pruneAfterS` in
  `worker/jobs/src/routes/lane-snapshots.js`, and the write-back ack prunes on
  it.
- The hub logs each snapshot skip one time, in `logs/lane-snapshot-publish.log`:

  ```
  <stamp> lane-snapshot-publish: skip <p> <relpath> (<bytes> bytes > lane_snapshot.file_max=<n>)
  <stamp> lane-snapshot-publish: skip <p> <dir> (record dir older than lane_snapshot.builds_days=<d>)
  ```

  A skip is logged when it starts. The open skips are kept in
  `state/lane-run-inputs/<lane>/<p>/skipped.tsv`, so the next publish does not
  log them again. A skip that ends and comes back is logged again. Only
  allow-listed files are logged (a transcript is never a member). A file at
  exactly the cap rides. The publisher's stdout line and return codes do not
  change. The machine checkpoint logs only the files it holds back, as above.

## Test-tamper ACCEPT on a lane machine

A lane machine holds a copy of the build record, so an adjudicated ACCEPT
takes the pool-copy arm of `bin/blocked-resolver.sh`. That arm writes the
TEST-CHANGE line to `state/build-notes/<p>/<KEY>.md` and rebuilds the ticket
fresh. The note is in the write-back allow-list. The hub applies it, and the
next build's plan stage reads it (`bin/lib/rb/plan.sh`, `CARRIED_NOTE_SRC`).
`tests/blocked-resolver-tamper-offhub.bh-6260-test.sh` proves this end to end.
The in-place resume arm writes the line only into `$rec/plan.md`, which a fresh
build does not read. That arm is unreachable today (its guard is never true for
an absolute record path), and this change does not edit it.

## Agent CLIs and credentials on the lane machines

Decision (the operator, 2026-10-17 03:40Z): "definitely let the fly machines have
credentials". The lane's agent rungs (the test-tamper adjudication and the
inline fix agent in `bin/blocked-resolver.sh`) call `bin/agent-call.sh`, and
`runner_ready` refuses a runner whose CLI is not on the machine. So:

- `fly/lane-run.Dockerfile` bakes node, `claude` and `codex`. The `bake-node`
  and `cli-pin-verify` blocks are byte-identical copies of the blocks in
  `fly/Dockerfile` (the pool image). Each version is a required build arg:
  `NODE_VERSION` (row `bake.node.version`), `CLAUDE_CODE_VERSION`
  (row `cli.claude_code.version`), `CODEX_VERSION` (row `cli.codex.version`).
  An empty arg or a version mismatch fails the build.
- The pool machines get their credentials from the hub at job time:
  `bin/fly-envbundle.sh` ships `CLAUDE_CODE_OAUTH_TOKEN` in `global.env`
  (`bin/fly-pool.sh` swaps in a leased account), and `bin/fly-dispatch.sh`
  pushes `/root/.codex/auth.json` and `config.toml`. A lane machine has no
  push channel, so the same credentials are Fly secrets on the `lane-run` app.
  `fly/lane-run-entrypoint.sh` writes `CLAUDE_CODE_OAUTH_TOKEN` into
  `global.env`, and `CODEX_AUTH_JSON` / `CODEX_CONFIG_TOML` into
  `$HOME/.codex/auth.json` / `config.toml`, mode 600, at boot.
- `tests/lane-run-agent-clis.bh-6260-test.sh` proves the image installs and
  pins both CLIs, the blocks match the pool image, and the entrypoint writes
  the same credential names the pool gets, with no value in its output.

Operator steps, before the flip row takes effect (restart lane: the image is
rebuilt and the machines are rolled):

1. Set the secrets (names only here; values from the hub's
   `env/global.env` and `/root/.codex/`):
   `flyctl secrets set CLAUDE_CODE_OAUTH_TOKEN=... CODEX_AUTH_JSON=... CODEX_CONFIG_TOML=... -a lane-run --stage`
2. Rebuild the image with the three version args (`fly/lane-run.toml` has the
   exact command).
3. Roll the machines. `bin/lane-fleet.sh` reuses a stopped machine with
   `machine start`, and that keeps its old image. So for each id in
   `flyctl machine list -a lane-run`, run
   `flyctl machine update <id> --image registry.fly.io/lane-run:latest -a lane-run --yes`.
   This also applies the staged secrets.
4. Check one machine:
   `flyctl ssh console -a lane-run -C 'claude --version'` and the same for
   `codex` answer the pinned versions, and `logs/ALERTS.log` gets no
   `runner '...' for ... not installed/authed` line from a lane-run machine.

## Probe

Before the merge, from a host with `JOBS_URL` and the bearer:

```
GET /api/lane-runs/stats?lane=blocked-resolver
GET /api/lane-fleet/machines
```

At least one machine must show a heartbeat inside `lane_run.lease_s`.

After the apply, for each project of `bin/fleet-conf.sh --projects`,
`GET /api/lane-snapshots/blocked-resolver/<p>` must show `age_s` < 600 within
one publish interval (10 min). This check cannot run before the flip: the
publisher publishes only while the lane is placed `fly`.

## Kill knob

Set the settings row `lane_placement.blocked-resolver` to `hub`. The next
publisher tick publishes nothing, and the next dispatch enqueues no fly row.
Wait for `GET /api/lane-runs/stats?lane=blocked-resolver` to show 0 queued and
0 claimed. No deploy.
