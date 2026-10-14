# The alerts groomer reads the DB, not the box

Doc: ALERTS-GROOMING-SPEC

## What was wrong

`bin/alerts-groom.sh` decided three of its settle rules by ssh-ing to the box
that owns the project: it ran the app's migration status probe there (rule 2),
tested `[ -f <build>/COMMENTED ]` there (rule 3), and read the last line of
`logs/<project>.log` there (rule 4). A box that was down answered nothing, and
nothing looked exactly like "not settled yet", so a dead box read as a quiet one.

## What changed

- Rule 2 settles a `MIGRATION-PR merged: #N` row when a `kind=migration` job of
  the project has a stage_event `APPLIED` whose detail names `PR#N` (followed by
  a non-digit or the end), and none says `FAILED` or `FLAGGED`. The newest
  `ALERTS_GROOM_MIGRATION_JOBS` jobs are read (settings row on the alerts-groom
  lane, default 20). A hub-local project also keeps the app status probe. A
  migration applied by hand leaves no event, so its row waits for the 72h TTL.
- Rule 3 settles a build row when `GET /api/artifacts?kind=commented&project=P`
  has a row whose ref is that build dir (exact basename). A hub-local build is
  also checked on the hub's disk.
- Rule 4 reads the triage lane's `lanes` row (`GET /api/lanes`, written by
  `lane_tick`): `live` with last tick `run`/`skip` settles; `stale` is a dead
  box and holds the row with `hold <id> (watcher-dead: <box> last tick <ts>)`;
  a failing last tick holds it silently (the alert is still true).
- Any DB read that fails holds the row and logs `hold <id> (<rule>-unknown: …)`.
  The pass summary is written every pass: `pass done: resolved N dead=D unknown=U`.
- New writer `bin/commented-mirror.sh <project>`, called from `bin/lib/rt/gate.sh`
  on every triage tick before the cost gate: a build dir with `COMMENTED` and a
  `job.json` `.job_id` becomes a `commented` artifact (ref = the dir), stamped
  `.commented-db` only after the PUT succeeds; a stamped dir whose `COMMENTED`
  was cleared is withdrawn (ref `withdrawn`). Capped by `COMMENTED_MIRROR_MAX`
  (settings row on the run-triage lane, default 25, 0 = off); the rest are
  counted `deferred` in `logs/commented-mirror.log` and drained next tick.

The groomer reads the `lanes` row rather than `lane_ticks`: `lane_ticks` records
only that a lane started, so it cannot tell an rc=1 tick from an rc=0 one.

No schema or worker change. Tests: `tests/alerts-groom-db.bh-2526-test.sh`,
`tests/commented-mirror.bh-2526-test.sh`.
