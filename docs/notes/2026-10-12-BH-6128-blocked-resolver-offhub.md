# blocked-resolver runs on Fly lane machines (BH-6128, BH-6047 part 5 of 5)

Doc: PROJECT-LANES

## What changed

`blocked-resolver` is the first lane that CAN run on Fly. This change ships
the snapshot path only. It does NOT seed the flip: schema fragment
`worker/jobs/schema.d/0024-bh-6047-blocked-resolver-fly.sql` adds the tables
and the `lane_snapshot.*` knobs, and `lane_placement.blocked-resolver` stays
unset, so the lane stays on the hub (`lane_placement.default`).

No host runs `bin/lane-run-worker.sh` yet. The heartbeat (BH-6125) and the
lease sweep are stubs, and the Fly lane fleet (BH-6126) is not built. A flip
before those land would enqueue rows that nothing claims, and every later
dispatch would count them `already live`, so no rung would run and nothing
would page. A run longer than `lane_run.lease_s` without a heartbeat would
also be claimed by a second machine. The flip ships as its own one-row
fragment after BH-6125 and BH-6126 are live. That PR must carry a probe:
`GET /api/lane-runs/stats?lane=blocked-resolver` that shows a live claimer.
After the flip, `blocked-resolver.sh --dispatch` enqueues one `lane_runs` row
per project, and a lane machine runs it through `bin/lane-run-worker.sh`.

A lane machine has no hub files. This change carries them:

- `bin/lane-snapshot-publish.sh` (hub, cron `2,12,22,32,42,52`, two minutes
  before the dispatch) applies the machines' write-backs for every project and,
  while the lane is placed `fly`, publishes one snapshot per project through
  `worker/jobs/src/routes/lane-snapshots.js`.
- `lri_fetch` (machine, `bin/lib/lane-run-inputs.sh`) downloads the snapshot
  and every write-back newer than it, checks each sha and each archive member,
  and overlays them on the machine's harness root. It refuses a root that is a
  live harness (`builds/` populated and no `state/lane-run-inputs/.managed`).
- `lri_checkpoint` (machine) posts the files a run changed as one write-back.
  `bin/blocked-resolver.sh` calls it after every candidate when `LANE_RUN_ID`
  is set; a failure stops the run (`reason=writeback-failed`, exit 75).
  `bin/lane-run-worker.sh` calls it once more after the run.
- `lri_apply_pending` (hub) applies write-backs with compare-and-set per file:
  the hub copy changes only when it still has the sha the machine started from.
  Otherwise the hub copy stays and the publisher counts a conflict.
- `bin/lane-run-worker.sh`: a failed fetch is reported rc 66 with prof
  `PROF lri_fetch rc=<n> <lane>/<project>` and one `lane-inputs-<lane>` alert
  per worker process. A failed final write-back is reported rc 75, never the
  run's own rc.
- `bin/blocked-resolver.sh`: off the hub, the test-tamper resume arm enqueues a
  fresh build (`br_rebuild_fresh`) instead of starting `run-build.sh`. A hub
  run of one project applies that project's pending write-backs before its scan
  (only when the publisher has seen the project).

The routes (all behind the main bearer):

| route | what |
|---|---|
| `PUT /api/lane-snapshots/<lane>/<project>/parts/<n>` | stage one base64 part (at most 1,400,000 chars) |
| `POST /api/lane-snapshots/<lane>/<project>/commit` | make the staged sha current (409 `parts_missing`) |
| `GET /api/lane-snapshots/<lane>/<project>` | sha, parts, `age_s` on the server clock, write-backs above `applied_through`, `truncated` |
| `GET /api/lane-snapshots/<lane>/<project>/parts/<n>?sha=` | one part |
| `POST /api/lane-snapshots/<lane>/<project>/writebacks` | one write-back; a replay of (run_id, sha) gets the same id |
| `GET /api/lane-snapshots/<lane>/<project>/writebacks` | the hub's unapplied list |
| `GET /api/lane-snapshots/<lane>/<project>/writebacks/<id>` | one write-back |
| `POST /api/lane-snapshots/<lane>/<project>/writebacks/ack` | stamp applied/rejected up to an id; prune rows done more than 7 days ago |

Settings rows (code fallback in brackets): `lane_snapshot.max_age_s` (1200),
`lane_snapshot.max_bytes` (33554432), `lane_snapshot.builds_days` (30),
`lane_snapshot.max_pending` (500).

## The inputs and where each one comes from

Way 1 is a D1 source the lane already reads. Way 2 is the snapshot.

| Input (relative to `$H`) | Written by the lane? | Choice |
|---|---|---|
| ladder records `state/blocked-resolver/<p>/**` | yes | way 2 + write-back. The `br_record` ledger rows keep 7 fields only; they stay the wiped-hub fallback. |
| `state/blocked-resolver/rounds/<p>-*`, `.tick-budget-<p>`, `.saturation-<p>.tsv`, `.saturated-project-<p>`, `.untouched-<p>`, `unmapped/`, `unmapped-family/`, `handoffs/` | yes | way 2 + write-back |
| `state/blocked-resolver/.last-visited.tsv` (one row per project) | yes | way 2. The write-back carries this project's row only; the hub replaces that row. |
| build records `builds/{<p>,pool-<p>,fly-<p>}-<KEY>-*/` (the listed record files, at most 256 KB each, record dir younger than `builds_days`) | yes (markers) | way 2 + write-back, dir mtimes kept. The record index is already way 1 (`bor_union`). |
| `state/build-queue/<p>/*.json` | no | way 2 read-only; `queue_list` stays primary |
| `state/build-notes/<p>/*` | yes | way 2 + write-back; also a `bn_put` row (way 1) |
| `logs/merge-conductor.log` | no | way 2, only the `handed to bin/blocked-resolver.sh` lines; the D1 hand-off rows are read first |
| `state/merge-conductor/pr-state.tsv` | no | way 2 read-only; `pr_state` is way 1 |
| `plans/<p>-*/planned-files.txt` | no | way 2 read-only |
| `flags/*` | no | way 2 read-only; D1 pause rows stay primary |
| `fleet.conf` | no | way 2 read-only |
| `locks/blocked-resolver-*` | — | machine-local. `lane_runs_live` holds one live run per (lane, project). |
| ALERTS | yes | way 1: `lane-alert.sh` / `alert-line.sh` already send a beat. The machine's `logs/ALERTS.log` is not copied back. |
| rebuild enqueue, fix round, comment marks | yes | way 1, already D1 |
| `logs/blocked-resolver.log` | yes | the bytes a run adds ride in the write-back and are appended to the hub log |
| `env/` | no | never in a snapshot. The machine's env is the lane app's secrets. |

## Hub apply guards

- `.lri/base.tsv` is parsed by one function, `_lri_base_line`, in both the
  validator and the hub apply. A line must be `relpath TAB sha` (64 hex or
  `-`), and relpath must be in the rw allow-list. The apply checks each line
  again before any `cp` or `rm`.
- The hub appends at most `LRI_LOG_APPEND_MAX` bytes of `.lri/log-append` per
  write-back. `state/lane-run-inputs/<lane>/<p>/logs-through` records the
  newest write-back id whose log bytes are in the hub log, so a re-apply
  after a failed ack does not append them twice.
- `lri_publish` holds `locks/lane-snapshot-<lane>-<p>.lock` from the file
  list to `applied_through`, so a hub apply cannot land between the two.
- Known limit: if a write-back POST is stored but its answer is lost, the next
  checkpoint posts the same base with newer content. The hub applies the
  first row, then counts the second as a conflict and keeps the first copy.
  The `lane-snapshot-conflict` alert names the project.
- Known limit: a commit deletes the parts of the previous sha. A machine that
  is downloading that sha gets a 404, reports rc 66, and the project waits
  one dispatch. The publisher runs two minutes before the dispatch, so the
  window is small.

## Moving the lane to Fly, and back to the hub

To place it on Fly (only after BH-6125 and BH-6126 are live and the stats
probe shows a live claimer): set the settings row
`lane_placement.blocked-resolver` to `fly`.

To move it back:

1. Set the settings row `lane_placement.blocked-resolver` to `hub` (or set
   `lane_placement.blocked-resolver.hub_only` to a reason).
2. Wait until `GET /api/lane-runs/stats?lane=blocked-resolver` shows 0 queued
   and 0 claimed.
3. Nothing else. The publisher still applies write-backs every ten minutes, and
   a hub run of one project applies its own pending write-backs first.

## Verified by

`tests/blocked-resolver-offhub.bh-6128-test.sh` (real worker via
`tests/lib/lane-snapshots-worker.bh-6128.mjs`, real `blocked-resolver.sh` on
both sides) and `worker/jobs/test/lane-snapshots.bh-6128.test.js`.
