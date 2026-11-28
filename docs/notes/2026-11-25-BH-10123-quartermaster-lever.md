# The quartermaster owns orphan_usd_day, and stops orphan pool machines as its lever (BH-10123)

Doc: STAFF, OPERATING

Slice C2 of #9423 (the quartermaster part of #9187 "Second wave"). The staff
contract (C0, BH-9187) says each staff agent owns ONE metric and is judged by
whether that metric moved. This slice gives the quartermaster its metric,
`orphan_usd_day`, and its one lever, a stop of an orphan pool machine through
`bin/fly-idle-reaper.sh act`. The target is the existing seed row
`staff.quartermaster.target` = 0.

## The metric

`orphan_usd_day` = Fly part + Orgo part, rounded to 2 decimals.

- Fly part. The lane reads `GET /api/fly-idle`, the snapshot the reaper writes
  every 5 minutes. The snapshot must be at most
  `staff.quartermaster.snapshot_max_age_min` (30) old, else `fly=stale` and no
  sample. An orphan is a machine with `idle_state` idle or over and `idle_s`
  MORE than `staff.quartermaster.idle_min` (60) minutes. The reaper's `idle_s`
  is the time with no job row (its pool witness is the pool tracking file and
  the claimed queue rows). The Fly part is the sum of `usd_per_hour * 24` over
  the orphans of every source. An orphan with no price adds 0 and shows as
  `unpriced=N`. Machines in `unknown` or `nosignal` are not orphans; they show
  as `unsettled=N` (the collector's `fly-unsettled` findings cover them).
- Orgo part. For each account in `catalog/orgo-plans.json` whose `pool`
  records a number that has a price: idle $/day = max(pool - used, 0) * monthly
  price / days in the UTC month. Used = the account's computers in
  `GET /api/orgo-computers` with `gone_at` null (the count, the sum of cpu,
  ram_gb, disk_gb). Today every pool field is null, so the part is
  `not-recorded`, the route is not read, and the part adds 0. If a pool is
  recorded and the route fails, answers `truncated`, or a needed spec is null
  on a live computer, the run is `orgo=unreadable`: no sample, no action.

The sample detail: `fly_usd_day=<x> orphans=<n> unpriced=<u> unsettled=<k>
orgo_usd_day=<y|not-recorded> idle_min=<m>`. It shows on Mission Control
/staff METRICS and /staff/quartermaster through the BH-9422 scoreboard and
scorecard, with no code change.

## The lever

At `staff.quartermaster.level` = `act` only (seed: observe):

1. Candidates are the orphans with source `pool` (the registry source, never
   the app name), most idle first, at most `staff.quartermaster.stops_max_run`
   (3) per run. The rest are `over_cap=N`.
2. For each candidate the lane records ONE `staff_lever_actions` row FIRST,
   key `fly-stop:<dry|apply>:<app>/<mid>:<UTC hour>`. Only a new row acts. An
   existing row or a 409 is `taken`; any other answer is `failed`. So no stop
   runs without its ledger row, and a second run in the same hour does not stop
   again.
3. Dry (`staff.quartermaster.lever_dry_run` is not exactly 0; seed 1): the row
   is a dry-run row and the lane runs `act probe` (read only).
   Apply (`lever_dry_run` = 0): the lane runs `act stop`. The reaper probes the
   machine again and refuses a busy one (rc 1 = `refused`). A stop writes the
   reaper's own stop row (source `act`, shown on /machines) and one beat.
4. Each reaper call runs under `timeout staff.quartermaster.act_timeout_s`
   (180; the reaper's lock wait is 60 s).

A later sample settles each non-dry action at least `staff.settle_hours` (24)
old: `moved` = 1 when `orphan_usd_day` is lower than `metric_before`.

## From dry to apply

1. Set `staff.quartermaster.level` to `act`.
2. Read the dry rows: `GET /api/staff/levers/scorecard?agent=quartermaster`
   (`dry_runs`) and the candidate lines in `logs/staff-quartermaster-lever.log`.
3. If the targets are right, set `staff.quartermaster.lever_dry_run` to `0`.

## Knobs (settings rows, seed `worker/jobs/schema.d/202611252040-bh-10123-quartermaster-lever.sql`)

| Row | Seed | Fallback | Meaning |
|---|---|---|---|
| `staff.quartermaster.idle_min` | 60 | 60 | minutes with no job row before a machine is an orphan |
| `staff.quartermaster.lever_dry_run` | 1 | dry | only `0` stops |
| `staff.quartermaster.stops_max_run` | 3 | 3 | lever actions per run |
| `staff.quartermaster.snapshot_max_age_min` | 30 | 30 | max age of the fly-idle snapshot |
| `staff.quartermaster.act_timeout_s` | 180 | 180 | timeout around one reaper call |

## The log

`logs/staff-quartermaster-lever.log`, one line per candidate:
`<ts> <app>/<mid> idle_s=<s> action=<recorded|taken|failed> act=<probe:<ans>|stopped|refused|failed|->`
and one summary line per run:
`<ts> level=<L> orphan_usd_day=<v|unreadable> fly=<ok|unreadable|stale> orgo=<ok|not-recorded|unreadable|-> sample=<ok|failed|none> dry=<0|1|-> candidates=<n> recorded=<n> taken=<n> failed=<n> stopped=<n> refused=<n> over_cap=<n>`

## Off

`bin/harness-ctl.sh off staff-quartermaster-lever`, or a staff kill flag
(`staff-off-all`, `staff-kill-all`, `staff-off-quartermaster`,
`staff-kill-quartermaster`), or `STAFF_ENABLED=0`. Each stops the lane before
any request of its own.

Test: `tests/staff-quartermaster-lever.bh-10123-test.sh`.
