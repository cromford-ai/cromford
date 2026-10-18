# BH-7252 C2: lane-move judges a late-found flip on a window it can see

Doc: OPERATING

This note adds to `docs/notes/2026-10-17-BH-7252-pipeline-health-move.md`
(C1). That note is not edited (D37).

## Why

On 2026-10-18T16:06Z the hub posted a lane-move report on #7252 with
`Verdict: FAIL` for pipeline-health (#issuecomment-6252072531). The check
judged the after window 2026-10-17T09:50Z to 10:50Z. That window closed about
29 h before C1 merged.

An operator set `lane_placement.pipeline-health=fly` at 2026-10-17T09:30:45Z.
The first lane-move tick after the deploy found that row and took its
`updated_at` as the flip time. The next tick was past flip + 5400 s, so it
judged the old window at once. For that window a FAIL was certain:

1. The `--lane pipeline-health` publisher line came only with C1, so the
   window had no publisher line.
2. `/api/lane-runs/by-prefix` returns the newest 50 rows. All 50 were newer
   than the window, so `lane-run ok` was 0 for each of the 13 projects.

The check then wrote the kill row (`hub`). The state is `rolled-back` +
`posted`, which is terminal.

## What changed (`bin/lane-move.sh`)

- **Late-found flip.** A `fly` row is late when lane-move first sees it
  1200 s (`AFTER_FROM`) or more after its `updated_at`. The state line is
  `flipped <seen epoch> load5=<x> found-late <row epoch>`. The after window
  is [seen+1200, seen+4800), and the check runs at seen + 5400 s. The before
  window stays the hour before the row time, because that hour is the hub
  baseline. The log line is `step=found why=row fly by <actor> at <updated_at>;
  late by <n>s, after window from <iso seen>`. A found row younger than
  1200 s keeps the C1 form `flipped <row epoch> load5=<x> found`.
- **Empty before window.** When `before.tsv` has no valid project row, the
  check adds the reason `no runs in the before window`, and the verdict is
  FAIL. Before C2 the project loop ran zero times and a PASS rested on the
  publisher alone. This can occur on a late-found flip when
  `logs/pipeline-health.log.1` has rotated past the row time.
- **Report.** For a late-found flip the `Flip:` line names both times:
  `Flip: <row time> (an operator set the row; lane-move first saw it at
  <seen time>, so the after window starts there). Before window: <row-1h> to
  <row>. After window: <seen+1200> to <seen+4800> (UTC).` The marker is
  `<!-- lane-move:<lane>:<seen epoch> -->`, so it never matches the old
  marker on #7252.

## Run the pipeline-health move again

The hub state for pipeline-health is terminal. lane-move does not flip the
row again by itself. To run the move again, on the hub:

1. Delete `state/lane-move/pipeline-health`,
   `state/lane-move/pipeline-health.before.tsv` and
   `state/lane-move/pipeline-health.report.md`.
2. Run `bin/jobs-client.sh setting-set lane_placement.pipeline-health fly`.
3. The next lane-move tick (10 min) finds the row under 1200 s old and writes
   `flipped <row epoch> load5=<x> found`. The check runs 5400 s after the row
   time and posts one report on #7252.

To check it: `tail logs/lane-move.log` shows `step=found` with no `late by`.
The new report's marker epoch is after 2026-10-18T15:41Z.

Verified by `tests/lane-move-late-flip.bh-7252-test.sh` (L1-L9) and
`tests/lane-move.bh-7252-test.sh`.
