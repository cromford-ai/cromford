# Pre-plan outcome as a stage_events row, and GET /api/preplans/adoption (BH-2543 slice 2, BH-2571)

Doc: EVENTS, DB-COORDINATION-SPEC

## What changed

- **Every non-resumed build posts its pre-plan outcome.** A new block,
  `# >>> preplan outcome event (BH-2543)`, sits right after `# <<< preplan adopt`
  in `bin/lib/rb/plan.sh`. It calls
  `job_event "$JOB_ID" preplan <VERDICT> "<detail>"`. The outcome maps like this:
  HIT becomes ADOPTED, STALE stays STALE, OFF stays OFF, and anything else is
  MISS. The detail is the rest of `$BUILD/preplan-outcome` after its first word,
  cut to 400 characters.
- **One line in `pipeline.log` on every path.** The block logs one of these:
  - `PREPLAN_EVENT <V> recorded`
  - `PREPLAN_EVENT not recorded (no job row)`, when `JOB_ID` is empty or the
    jobs client is not loaded
  - `PREPLAN_EVENT not recorded (post failed rc=N)`

  It ends in `true`, so the build's rc never depends on the hub.
- **A resumed dir posts nothing.** The first pass through the dir already
  posted, so the route counts each build once.
- **A build that died mid-PLAN posts nothing either.** A MISS, STALE or OFF
  build has `preplan-outcome` but no `plan.md` until PLAN ends, so its next
  attempt is not a resume. After a successful post the block writes
  `$BUILD/preplan-event`, and a dir that carries it logs
  `PREPLAN_EVENT already recorded by an earlier attempt (<V>) — not re-posted`
  and posts nothing. A failed post writes no marker, so the next attempt tries
  again.
- **`GET /api/preplans/adoption?project=<p>&days=<1-30>`** (bearer) answers the
  shape documented in `bin/lib/preplan-cadence.sh`:
  - `bought` is adopted + stale.
  - `rate` is adopted/bought, and it is null (never 0) when nothing was bought.
  - `days` outside 1-30 or not an integer is a 400. It is never clamped.
  - An empty or absent `project` means every project.
  - `recent` holds the 50 newest rows, and `recent_truncated` says whether there
    were more.
  - Only verdicts ADOPTED, STALE, MISS and OFF are counted.
  - Counts are distinct jobs (`COUNT(DISTINCT e.job_id)`), not rows, so a POST
    that `bin/lib/jobs/req.sh` re-sent after a lost reply counts once.
- **`idx_events_stage_created ON stage_events(stage, created_at)`** is added to
  `worker/jobs/schema.sql`. `bin/harness-sync.sh` applies it before the worker
  deploys.

## What it does not do

It does not backfill. Outcomes from before this merge exist only in
`$BUILD/preplan-outcome` and `logs/preplan.log`. `preplan_adopt_stats` is still
the stub. The cadence child is what will read this route.

## Tests

- `tests/preplan-outcome-event.bh-2571-test.sh` runs the adopt block and the
  event block, both extracted from the flattened pipeline, with a stub
  `job_event`. Case 9 rewrites the resume guard and checks that the resume
  assertion goes red. Case 10 re-runs the blocks in a MISS dir with no
  `plan.md` and checks one post, not two; case 11 checks that a failed post
  leaves no marker and the retry posts.
- `worker/jobs/test/routes/preplans-adoption.bh-2571.test.js` drives
  `worker.fetch` over the real `schema.sql` in node:sqlite. A9 runs
  `EXPLAIN QUERY PLAN` on the exported SQL. A13 adds duplicate rows for three
  jobs and checks the totals do not move.
