# utilization: the daily went-quiet alert (BH-4012, BH-3988.4)

Doc: VERIFICATION-MAP

## What changed

- **History read.** `GET /api/utilization?project=<p>&since=<iso>` now answers
  that project's rows with `hour >= since`, ordered by hour ascending, at most
  500, plus `truncated`. Either param alone, an empty project or a `since`
  that does not parse is 400. With no params the GET answers exactly what it
  did before: the newest row per project. `utilization_rows` already sent both
  params, so the client did not change.
- **Predicate.** `util_quiet <rows> <merges_prior_week> <min_rows>` in
  `bin/lib/utilization-quiet.sh` prints `quiet`, `not-quiet` or `unmeasured`
  with a reason. Quiet means every hour in the window had zero ready tickets,
  free build slots and a verdict other than `paused` or `unknown`, and the
  project merged something the week before.
- **Lane.** `bin/utilization-quiet.sh`, hub only, daily at 07:20Z
  (`cron/lanes/725-utilization-quiet.cron`). Per project it reads the last
  72h of rows and the prior week's merges from DORA (`days=10` minus
  `days=3`). Quiet raises one warn `util-went-quiet-<p>` through
  `bin/lane-alert.sh`; not-quiet resolves it; unmeasured never resolves it
  and goes into one `util-quiet-unmeasured` warn instead.

## Why

A project can stall with nothing in front of it: slots free, no ready work,
and nobody filing more. BH-3988 records the hourly snapshot; this turns three
days of it into one line in the digest.

## What to expect

- Until the verdict rules (BH-3988 siblings) ship, every row's verdict is
  `unknown`, so the lane can only answer `not-quiet` and never fires.
- For the first ~60h after the tracer starts writing, every project has fewer
  than 60 rows: one `util-quiet-unmeasured` warn opens and resolves itself once
  the rows exist.
- An open `util-went-quiet-<p>` is counted, not re-sent, while it stays quiet.

## Commands

- Off: `bin/harness-ctl.sh off utilization-quiet` (the
  `flags/lane-off-utilization-quiet` flag), or the `UTIL_QUIET_ENABLED=0`
  settings row.
- Knobs (settings rows on lane `utilization-quiet`): `UTIL_QUIET_WINDOW_H`
  (72), `UTIL_QUIET_PRIOR_DAYS` (7), `UTIL_QUIET_MIN_ROWS` (60).
- Test: `HARNESS_TEST_SANDBOX=1 bash tests/utilization-quiet.bh-3988-test.sh`,
  `cd worker/jobs && node --test test/routes/utilization-history.bh-3988.test.js`.
