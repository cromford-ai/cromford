# BH-7252 C1: move the pipeline-health project runs to lane-run

Doc: OPERATING

## What changed

- New hub lane `bin/lane-move.sh` (`cron/lanes/736-lane-move.cron`, every
  10 min at `6,16,...`, behind `bin/hub-lease.sh check`; registry
  `catalog/lanes.d/lane-move.json`; off: `flags/lane-off-lane-move`). It moves
  one lane's project runs to Fly lane-run after proof gates, checks the hour
  after the move, and writes the kill row when the check fails.
- One module per lane, found by filename: `bin/lib/lane-move/<lane>.sh`. The
  first is `pipeline-health`.
- `cron/lanes/579-lane-snapshot-publish.cron` has a second line:
  `bin/lane-snapshot-publish.sh --lane pipeline-health` at `8,18,...`. It
  applies the machines' write-backs for the lane always, and publishes its
  snapshots once the row is `fly`. The line is in the publisher lane's own
  fragment because `bin/render-cron.sh` names a fragment by its registry id,
  and a second registry entry for the same script fails the lane-gate check.
- `gh_repo_invisible_alert` (`bin/lib/gh-repo-token.sh`): with `LANE_RUN_ID`
  set, the once-a-day flag goes under `GHRT_FLAG_DIR` when the caller sets it,
  flags older than yesterday are pruned there by the date in the name, and no
  `beat.sh` fleet_alert is made. `alert-line.sh` still posts the line, and the
  hub replay notes it. `bin/pipeline-health.sh` sets
  `GHRT_FLAG_DIR=state/pipeline-health/<p>` on a machine, which its write-back
  carries. On the hub (`LANE_RUN_ID` unset or empty) nothing changes. This was
  the last open item of BH-6892 "Not covered".

## Why pipeline-health

The only per-lane hub numbers available at plan time were the #6881 sample
(hub, 2026-10-15 12:39Z-12:45Z, runnable share): `fly-pool` 19 %,
`pipeline-health` 9, `rules-pack.sh` 7.6, `merge-conductor` 7.3. `fly-pool`
(#6896) and `merge-conductor` (#6895) have their own tickets, and
`rules-pack.sh` is not a cron lane. So `pipeline-health` was the most
expensive movable lane with no other owner. The C0 table
(`bin/lane-cpu-rank.sh`) gives the measured before numbers for the hub.

## The gates (before the flip)

In order; the first that fails stops the run:

1. g1, the row `lane_placement.<lane>`: `fly` (any actor) is an operator
   flip, recorded as `found` with the row's `updated_at` as the flip time.
   `hub` by actor `seed` goes on. Any other value or actor is `held`: an
   operator chose, and lane-move never overwrites it. No row or no answer
   is `waiting`.
2. g2, a `lane_placement.<lane>.hub_only` row: `held`.
3. g3, `GET /api/lane-runs/stats`: the lane-run fleet has done work.
4. g4, a `; <lane> placed` publisher line at most 1800 s old.
5. g5, at least 1 finished run in the hour before (written to
   `state/lane-move/<lane>.before.tsv`).

Then `setting_set lane_placement.<lane> fly`. The state is `flipped` only
after rc 0. A gate that fails counts one wait; the `LANE_MOVE_WAIT_MAX`-th
(36, 6 h) writes `gave-up` and one log-only lane-alert line.

## The check (1 h after)

At flip + `LANE_MOVE_VERIFY_AFTER_S` (5400 s), over the after window
[flip+1200, flip+4800):

- the row is not `fly`: `killed <ts> <actor>`, the report says KILLED;
- PASS when, for each project in before.tsv, after runs >= before runs - 1 and
  at least one lane_runs row of exactly that project finished `done` in the
  window; failed + died rows <= `lane_move.<lane>.fail_max` (default 0); and
  at least one publisher line for the lane in the window, with 0 conflicts
  and 0 failed.
- FAIL: `setting_set lane_placement.<lane> hub` (the kill row), then
  `rolled-back` and one `lane-alert --severity warn --id lane-move-<lane>`.
  If that write fails, the state stays `flipped` and the next run tries again.

For pipeline-health a run is a `pipeline-health project <p>: run done` line
in `logs/pipeline-health.log` (machine runs reach it through their
write-back). The report (`state/lane-move/<lane>.report.md`) has the
per-project table, the publisher counts, load5 at the flip and at the check,
the verdict and the kill command. It is posted once on issue
`lane_move.<lane>.issue` (default 7252), deduped by the marker
`<!-- lane-move:<lane>:<flip epoch> -->` in the issue's comments.

## The state file

`state/lane-move/<lane>` line 1: `waiting <n> <why>` | `held <ts> <why>` |
`flipped <epoch> load5=<x> [found]` | `verified <ts>` | `rolled-back <ts>
<why>` | `killed <ts> <actor>` | `gave-up <ts> <why>`. Line 2 after a verdict:
`post-attempts <n>` | `posted <ts> [found]` | `posted gave-up`. held,
gave-up and a verdict with `posted` are terminal. To run a lane's move again,
delete its state file on the hub.

## The kill row

`bin/jobs-client.sh setting-set lane_placement.pipeline-health hub` sends the
next `pipeline-health --dispatch` back to local runs (no deploy).
`tests/pipeline-health-placement.bh-7252-test.sh` P2 pins it.

## How a later slice adds a lane

1. Add `bin/lib/lane-move/<lane>.sh` with `LM_LANE`, `lm_runs_done_<s>` and
   `lm_publisher_lane_<s>` (the contract is in the pipeline-health module).
2. Add one `bin/lane-snapshot-publish.sh --lane <lane>` line to
   `cron/lanes/579-lane-snapshot-publish.cron`.
3. Make sure the lane's `.rw` manifest carries every file its project run
   writes, and that the lane has a `lane_placement.<lane>` row seeded `hub`.
