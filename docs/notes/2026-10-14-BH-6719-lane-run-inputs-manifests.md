# Lane-run inputs are per-lane manifests (BH-6719, BH-6047.6)

Doc: PROJECT-LANES

## What changed

- The allow-list of hub files a lane run reads and writes moved out of
  `bin/lib/lane-run-inputs.sh` into one manifest pair per lane:
  `catalog/lane-run-inputs.d/<lane>.rw` and `<lane>.ro`. The lib reads them.
  It holds no lane's list. `LRI_LANE_DEFAULT=blocked-resolver` is the only lane
  name left. It is the lane for the call forms that name none
  (`lri_member_ok` with four arguments, `_lri_validate`, `_lri_base_line`).
- `blocked-resolver.{rw,ro}` hold the same entries the lib held. For the same
  tree, `lri_paths`, `_lri_list` and the published snapshot are the same as
  before. The BH-6719 test pins the list against goldens from main 908ec1f7.
  Two one-off publishes of the test fixture with both libs gave byte-identical
  snapshots (sha 5f1989f681ad and d9e648f56cf9; the fixture mtimes follow the
  clock, so the sha differs between runs).
- `pipeline-health.{rw,ro}` list what one `bin/pipeline-health.sh --project <p>`
  run reads and writes. Nothing uses them yet. The publisher cron runs only
  `--lane blocked-resolver`, and pipeline-health has no `fly` placement.
- The placement flip of pipeline-health is NOT in this change. Issue #6260
  (BH-6047.5, flip blocked-resolver to Fly) was open on 2026-10-14. The ticket
  makes the flip depend on it, so no `worker/jobs/schema.d/` fragment ships.

## Manifest format

- One entry a line. A blank line and a `#` line are skipped.
- A path line is `<glob>[ <comment>]`. `lri_paths` prints the whole line, with
  `$p` replaced by the project.
- In a glob, `*` is any run of non-`/` characters. `**` is one or more
  segments, and only as the whole last segment. `<KEY>` is a ticket key
  (`[A-Z][A-Za-z0-9]*-[0-9]+`). `<KEY>-*` is a ticket key alone or followed by
  `-` and more. `<name>` is a set from `@token`.
- `@token <name> <glob>...` defines `<name>` as any of the one-segment globs.
- `@lines <path> <ERE>` is for `.ro` only. The snapshot carries `<path>` as
  its last 20000 lines that match `<ERE>`, with mtime 0. `$p` in the ERE is
  the project, escaped. `<path>` must also be a path line of the `.ro`.
- `@row <path> <lockname>` is for `.rw` only, and at most once. `<path>` is a
  fleet-wide TSV keyed by project in column 1. A write-back carries only this
  project's row, as `.lri/visited.tsv`. The hub merges it under
  `locks/<lockname>.lock`. `<path>` must also be a path line of the `.rw`.
- `rw` mode is the `.rw` lines. `ro` mode is the `.rw` lines, then the `.ro`
  lines.
- A record dir member (tar type `d`) is allowed for the parent dir of a glob
  whose parent segment holds `<KEY>`. The `lane_snapshot.builds_days` window
  applies to those dirs.
- A file under a glob whose last segment has a wildcard or a token is capped
  at `LRI_FILE_MAX` bytes. A literal last segment is not capped.
- A literal path that is a symlink is not listed. Before, `pr-state.tsv` and
  `fleet.conf` were listed when they were symlinks, and the fetch then
  refused the symlink member.
- The manifest dir is `$LRI_MANIFEST_DIR`, else
  `<root>/catalog/lane-run-inputs.d`, else the catalog beside the lib.
  `fly/lane-run.Dockerfile` bakes `catalog/`, and `bin/harness-sync.sh` syncs
  `catalog/` before `bin/`.
- No manifest: the lane has no inputs. `lri_paths` prints nothing,
  `lri_fetch` returns 0 and `lri_publish` returns 1, as before.
- A malformed manifest: `lri_paths` prints one `lri: <file>:<line>: <why>`
  line and returns 1. `lri_publish` returns 1, `lri_fetch` returns 2,
  `lri_checkpoint` returns 1, `lri_apply_pending` returns 1 and
  `lri_member_ok` refuses every member. Malformed is an unknown directive, an
  undefined token, `@lines` in `.rw`, `@row` in `.ro`, a second `@row`, an
  `@lines` or `@row` path that is not a path line, `**` that is not the whole
  last segment, an absolute path, an empty, `.` or `..` segment, or a
  character no member name can hold.

## pipeline-health inventory (one `--project <p>` run)

Read from the code. `ph` is `bin/pipeline-health.sh`, `ct` is
`bin/lib/closeout-terminal.sh`. A project run executes ph:332-348, 402-631,
827-1223 and the epilogue 2942-3034. The fleet sections do not run.

Reads (`pipeline-health.ro`):

| entry | where |
|---|---|
| `builds/$p-<KEY>-*/` and `builds/pool-$p-<KEY>-*/`: RESULT, COMMENTED, RELAYED, DEFERRED, SUPERSEDED, job.json | ph:462-546, 578; ct:77; bin/queued-fly-relayed.sh:15-23 |
| `state/build-queue/$p/*.json` | ph:336-342 |
| `state/remote-results/$p/*.json` | ph:575 |
| `state/stranded-watch/$p/.count` | ph:980-983 |
| `state/merge-conductor/pr-state.tsv` | ph:990-992 |
| `state/closeout-aged-out.tsv`, rows `^$p<TAB>` only | ct:146 |
| `state/health-active.txt` | ph:917, 1068, 1082 |
| `state/health-alerted.json` | ph:291 |
| `prompts/$p.md` | bin/lib/preplan-lib.sh:515 |
| `logs/fly-pool.log`, lines `\[pool/$p\] reaped` only | ph:415, 418 |
| `logs/$p.log`, lines `rc=(0\|skip) ::` only | ph:589-590 |
| `flags/*` | bin/lib/lane-gate.sh:238, bin/lib/alert-state.sh:57, bin/beat.sh:170 |
| `fleet.conf` | ph:135, 601, 989 |

A project run does not read `logs/ALERTS.log` (it appends only),
`logs/merge-conductor.log` (ph:788, 806, fleet section) or `logs/cost.csv`
(ph:1912, fleet section). `builds/fly-$p-*` is read only by
`preplan_midbuild_keys`, which a project run does not call.

Writes it may carry back (`pipeline-health.rw`):

| entry | where |
|---|---|
| `state/pipeline-health/$p/*` (closeout-aged.tsv) | ct:173-252 |
| `state/pipeline-health/noprogress/$p.stranded`, `$p.parked` | ph:998-1004 |
| `flags/pool-halt-$p` | ph:421-422 |

## Not carried: what blocks a later flip

A per-file compare-and-set from N project runs would conflict on every tick
for these fleet-wide writes. The flip ticket must solve them first:

- appends to `logs/ALERTS.log` (bin/alert-line.sh:87) and `logs/alerts-state.log`;
- `state/health-active.txt`, `state/health-active.stamp`;
- `state/health-alerted.json`;
- appends to `state/closeout-aged-out.tsv` (ct:148);
- `state/alert-line-sent/*`, `state/alerts/*`, `state/alert-quarantine.jsonl`;
- the `/root/repos/$p` ref writes of the stale-parent check (ph:1094-1119);
- `bin/fleet-conf.sh` reads `/root/harness/fleet.conf` by absolute path unless
  `FLEET_CONF` is set (fleet-conf.sh:64);
- two lanes on one machine both overlay `flags/*` and `fleet.conf`.

Never carried: secrets and machine-local state (`env/*`, `locks/*`,
`state/gh-*`, `state/gh-budget/*`, `state/settings-cache.json`,
`state/lane-gate/*`). `logs/pipeline-health.log` rides back as the lane log
(`.lri/log-append`).

## The scratch run

This is NOT a hub run. The build ran on a pool builder with no hub logs.

- Command: `bin/pipeline-health.sh --project demo` in a scratch root built
  with `tests/lib/ph-sections-fixture.sh` (gh and the jobs client stubbed).
  The root held `builds/demo-BH-1-x/RESULT` (2 h old),
  `state/build-queue/demo/BH-1.json`, `logs/fly-pool.log` and `fleet.conf`.
- Start 2026-10-14T17:43:32Z, rc 0.
- Files under the root newer than a marker set before the run (`find -newer`):
  `locks/pipeline-health-demo.lock`, `logs/ALERTS.log`,
  `logs/alerts-state.log`, `logs/pipeline-health.log`,
  `state/alert-line-sent/` (2 files), `state/alerts/.gc`,
  `state/alerts/alias/` (2 files), `state/alerts/ph-stuckqueue_demo_BH-1.json.json`
  and `.lock`, `state/alerts/ph-uncommented_demo_1.json` and `.lock`,
  `state/gh-budget/notoken.json`, `state/health-active.stamp`,
  `state/health-active.txt` and `.lock`, `state/health-alerted.json` and
  `.lock`. The fixture's own stub files (`gh.calls`, `note.log`, `open.ids`,
  `sent.jsonl`) are left out.
- Every file it wrote is in the not-carried list above. It wrote no `.rw`
  file: no record was old enough to age out, and no project was stranded.
  The fixture had no `bin/queued-fly-relayed.sh`, so ph:487 printed one
  "No such file" line.
