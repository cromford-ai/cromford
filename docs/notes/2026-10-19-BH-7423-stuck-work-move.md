# BH-7423: move the stuck-work project runs to lane-run

Doc: OPERATING

## What changed

`bin/lane-move.sh` now has a second module, `bin/lib/lane-move/stuck-work.sh`.
On the hub, the lane-move pass runs gates g1-g5 for `stuck-work`. After a hub
hour with at least one finished run, it flips `lane_placement.stuck-work` to
`fly`. 90 min later it checks the hour after the flip against the hour before.
On a failed check it writes the kill row (`hub`). The report goes to issue
`lane_move.stuck-work.issue` (default 7252).

## The input check (ticket step 1)

No input of a project run is hub-only, so no `lane_placement.stuck-work.hub_only`
row is written. The manifest pair `catalog/lane-run-inputs.d/stuck-work.{rw,ro}`
names every hub file a run reads or writes, with the file:line that reads it.
The files it does not carry are machine-local caches (`state/gh-*`,
`state/pr-snapshot/*`, `state/verdicts/*`, `state/gh-app-default*`,
`state/hold-ambiguous/*`). Each falls back to a live read or a ledger check.
Alerts from a machine are POSTs to `/api/alert-lines`, and the publisher
replays them on the hub.

## A finished run

The module counts the summary line `bin/stuck-work.sh` writes at the end of a
run, `<ts> items=<n> ...`, per project in `[from, to)`:

- `logs/stuck-work.log`: an untagged line is the home project's run. A line
  `<ts> project=<p> items=<n> ...` is project `<p>`'s run on a lane-run machine.
- `logs/stuck-work-<p>.log`: project `<p>`'s run on the hub.
- The `.log.1` copies of both are read too.

The lines `off`, `disabled`, `busy`, `no-token`, `no-classifier` and `no-tmp`
are not runs. `logs/stuck-work-profile.log` and `logs/stuck-work-cron.log` are
not project logs.

## The machine summary line

Only `logs/<lane>.log` rides back from a machine (`.lri/log-append`). So a
non-home run with `LANE_RUN_ID` set writes its summary to `logs/stuck-work.log`
with the `project=<p>` tag, not to `logs/stuck-work-<p>.log`. Without the tag,
a watched non-home project has hub runs in the before window and none in the
after window, and the check rolls back a working lane. Hub runs do not change.
The profile and cron log lines of a machine run stay on the machine.

## What the gates need

- g1: the seed row `lane_placement.stuck-work=hub` by actor `seed`
  (`worker/jobs/schema.d/202610191444-bh-7423-stuck-work-placement.sql`,
  INSERT OR IGNORE, so an operator row is never overwritten).
- g4: a `; stuck-work placed` publisher line at most 1800 s old. The
  `--lane stuck-work` line in `cron/lanes/579-lane-snapshot-publish.cron` runs at
  3,13,...,53. The dispatch is `*/5` with a 240 s spread, so a run starts on a
  snapshot at most 12 min old (under `lane_snapshot.max_age_s`, 1200 s).

## Kill row

`bin/jobs-client.sh setting-set lane_placement.stuck-work hub` moves the lane
back to the hub, with no deploy.

Test: `tests/lane-move-stuck-work.bh-7423-test.sh`.
