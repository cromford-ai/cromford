# pr-url-reconcile runs per project, with a manifest pair (BH-6894)

Doc: PROJECT-LANES

## What changed

`bin/pr-url-reconcile.sh` walked every build record of every project in one
hub process, under one lock. It now has three run modes:

| invocation | what it walks | lock |
|---|---|---|
| no flag (an operator's run) | every record, as before | `locks/pr-url-reconcile.lock`, exclusive on fd 9; held = exit 0 |
| `--project <p>` | `builds/<p>-*`, `builds/pool-<p>-*`, `builds/fly-<p>-*`, and only the records `project_of` puts in `<p>` (so a `pa` run never walks `pa-x-…`) | `locks/pr-url-reconcile-<p>.lock` on fd 9 (the runner's, or taken by a hand run), then a SHARED lock on `locks/pr-url-reconcile.lock` on fd 8; either held = one log line, exit 0 |
| `--dispatch` (cron) | nothing itself: `pl_dispatch pr-url-reconcile <spread> bin/pr-url-reconcile.sh --project` | none |

- `--dispatch` and `--project` together: one stderr line, exit 2.
- `--project` with an empty name, a leading `.`, a character outside
  `[A-Za-z0-9._-]` or a name not in `bin/fleet-conf.sh --projects`: the log
  line `--project '<p>' is not a project in fleet.conf — no run`, exit 2. No
  lock is opened and nothing is walked.
- The lane gate, `lane_switch pr-url-reconcile-off` and `PR_URL_RECONCILE=0`
  run first in every mode, as before.
- A project run's summary line ends ` project=<p>`. The fleet line is
  byte for byte as before.
- `PR_URL_RECONCILE_MAX` (50) and `PR_URL_RECONCILE_DEADLINE_SECS` (240) count
  per process, so per project in a project run.
- The shared lock is on fd 8 because fd 9 is the runner's project lock
  (`bin/project-lane-run.sh`), and `exec 9>` would release it. A fleet run
  and a project run never overlap. Two project runs do.
- The dispatcher takes no lock. If it held the fleet lock, every project run
  that starts at offset 0 would skip.
- No `bin/lib/project-lanes.sh` (a box in mid-sync): `--dispatch` logs
  `project-lanes.sh not loaded — this tick walks every project in one process`
  and runs the fleet walk.

The cron line (`cron/lanes/390-pr-url-reconcile.cron`) now runs
`--dispatch`. The knob `PR_URL_RECONCILE_DISPATCH_SPREAD_SECS`
(`catalog/lanes.d/pr-url-reconcile.knobs.d/`) is the start window, default
120 s, range 0..540. The lane runs at :03 and the merge sweep at :06, so
pipeline-health's 540 s would move most project runs past the sweep. A
non-number logs one line and uses 120.

## Placement

`worker/jobs/schema.d/202610151545-bh-6894-pr-url-reconcile-placement.sql`
seeds `lane_placement.pr-url-reconcile = hub`. The flip to `fly` is a data
change, not in this PR. It needs a proof run and the alert path below.

`tests/lanes-offhub.bh-6721-test.sh` O3 refused any fragment that names
`lane_placement.<lane>` for a lane that stays. It now lets a dispatch-ready
lane (a `pl_dispatch` call and both manifests) carry a row whose value is
`hub`. A lane that is not dispatch-ready is refused as before.

The BH-6721 note's `pr-url-reconcile` stays line says the lane is not on
pl_dispatch and has no manifest reader. That is no longer true. This note is
the correction (notes are never edited). The lane still stays on the hub,
because of the NOT CARRIED writes below.

## Manifest pair

`catalog/lane-run-inputs.d/pr-url-reconcile.rw`: the record files a run
writes, under `builds/$p-<KEY>-*/`, `builds/pool-$p-<KEY>-*/` and
`builds/fly-$p-<KEY>-*/`:

| file | where (bin/pr-url-reconcile.sh) |
|---|---|
| `RESULT` | `relink` tmp + mv |
| `pipeline.log` | `_gpc_rung_create` appends (restack arm) |
| `.pr-url-reconciled` | `relink`; the merged arm |
| `.pr-url-reconcile-alerted`, `.pr-url-reconcile-mislink-alerted`, `.pr-url-reconcile-restack-gaveup` | `alert()` |
| `.pr-url-reconcile-mislinked` | the mislink arm |
| `.pr-url-reconcile-restack-tries` | `restack_try` |
| `.pr-url-reconcile-restacked` | `restack_orphan` |
| `.verdict-handoff-done` | `verdict_handoff` |

`catalog/lane-run-inputs.d/pr-url-reconcile.ro` adds what a run only reads:
`review.md`, `ticket-meta.json`, `pr-body.md`, `.blocked-resolver-abandoned`,
`.blocked-resolver-superseded` under the same three globs, `fleet.conf` and
`flags/*`. The `.ro` uses its own token name (`<read file>`): a second
`<record file>` would replace the `.rw` one for every path.

Each manifest line carries the `bin/pr-url-reconcile.sh:<line>` it comes from.

NOT CARRIED (listed in the `.rw` header). These block the flip:

- `logs/ALERTS.log`: `alert()` and `valert()` append to it. The fix is the
  jobs-API alert lines of #6889, which is not on main.
- `/root/repos/$p`: `slug_of` reads its origin when fleet.conf has no repo,
  and the restack arm's `mc_restack` rebases and pushes in it.
- `logs/pr-url-reconcile.stderr.log`, `logs/gh-rate.log`, `locks/*`,
  `state/lane-gate/*`, `env/*`: machine-local.

`logs/pr-url-reconcile.log` rides back as the lane log. The lane writes no
fleet-wide TSV, so the pair has no `@row`.

## Tests

`tests/pr-url-reconcile-per-project.bh-6894-test.sh` drives the real script.
A3 builds a root from `_lri_list pa ro 0` only, runs `--project pa` there and
checks two things: pa's RESULT files equal a run on the full tree, and every
file the run writes is `lri_member_ok … rw` or on the NOT CARRIED list.
A4f runs `--dispatch` with placement `fly` against the BH-6124 worker stub
and counts one `lane_runs` row per project. It does not count POSTs, so it
stays green when #6886 makes `pl_dispatch` enqueue in one batch call.

## Metric

The ticket's metric (the lane's hub share after the flip) needs the flip, so
this change does not move it. This build box has no `state/hub-load/` files,
so this note names no command for it.
