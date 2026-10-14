# A finished Fly build rings the doorbell: `fly_result` → `queue` wake (BH-4171, slice of BH-4059)

Doc: EVENTS

## What changed

`PUT /api/jobs/:id/artifacts` in `worker/jobs/src/routes/job-artifacts.js` now
calls the tracer's `queueWake` (BH-4169) when `artifact_kind` is `fly_result`,
the artifact `fly/builder-runner.sh` `fly_result_put` writes when a Fly build
finishes. The wake is repo `harness/build-queue`, kind `queue`, key
`<project>:<job id>` (capped at 160 characters), event `fly_result.put`. It runs
after the artifact upsert and its read-back, so the artifact has landed before
the wake is tried. `queueWake` never throws and dedupes on
`idx_wakes_dedupe(repo,kind,key,minute)`, so a failed wake insert logs one
`console.error` and the PUT answers 200 with the same body, and a second PUT in
the same minute writes no second row. Every other artifact kind, and every
400/404, writes no wake. No schema change, and the response body is unchanged.

On an armed hub (`wake-lanes-queue`) the drain launches `bin/fly-dispatch.sh`
and `bin/fly-pool-tick.sh` once, the same as for an enqueue wake.

## What did not change

- `bin/fly-results-ingest.sh` is not wake-launched and stays on its `*/2` cron.
  It holds no flock, and its relay hold is sized in sweep intervals against the
  builder's 600 s idle autostop.
- The fly lanes' cron entries and cadences.

Test: `worker/jobs/test/fly-result-wake.bh-4059.test.js`.
