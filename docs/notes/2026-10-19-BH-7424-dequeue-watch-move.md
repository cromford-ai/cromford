# BH-7424: move the dequeue-watch project runs to lane-run

Doc: OPERATING

## What changed

- New lane-move module `bin/lib/lane-move/dequeue-watch.sh`. `bin/lane-move.sh`
  finds it by filename, so its next pass also evaluates `dequeue-watch`. A
  finished run is the summary line a `bin/dequeue-watch.sh <p>` run writes at
  its end: `<ISO stamp> tick projects=... project=<p>`. The module reads
  `logs/dequeue-watch.log.1` and `logs/dequeue-watch.log`.
- New manifest pair `catalog/lane-run-inputs.d/dequeue-watch.ro` and `.rw`.
  A machine run gets `fleet.conf` and `flags/*` read-only. It writes back this
  repo's `state/merge-conductor/attempts.txt` lines (`@rows`, the same ERE as
  `merge-conductor.rw`) and `state/merge-conductor/mergify-asked/<repokey>_*`.
- `cron/lanes/579-lane-snapshot-publish.cron` has a line for
  `bin/lane-snapshot-publish.sh --lane dequeue-watch` at `3,13,...`. Gate g4
  of lane-move needs its `; dequeue-watch placed` log line.
- Seed row `lane_placement.dequeue-watch = hub` by actor `seed`
  (`worker/jobs/schema.d/202610271650-bh-7424-dequeue-watch-placement.sql`,
  `INSERT OR IGNORE`). Gate g1 flips only a `hub` row by `seed`.

## Why

The hub runs at load 160-185 on 4 cores (#7397). dequeue-watch starts one
project process per project every 5 minutes on the hub.

The lane reads no hub-only state, so no `lane_placement.dequeue-watch.hub_only`
row is written. A project run reads GitHub REST and the jobs worker. The hub
files it writes are in the `.rw`. The rest are caches and logs that can stay on
the machine (named in the `.rw` header).

## Operate

- Status: `state/lane-move/dequeue-watch` line 1 on the hub, and
  `logs/lane-move.log` lines `lane=dequeue-watch`.
- The report goes to lane-move's default issue (#7252), because no
  `lane_move.dequeue-watch.issue` row is set.
- Kill row (no deploy): `bin/jobs-client.sh setting-set lane_placement.dequeue-watch hub`.
