# A fly enqueue rings the doorbell: the `queue` wake tracer (BH-4169, first slice of BH-4059)

Doc: EVENTS

## What changed

`POST /api/queue` in `worker/jobs/src/routes/queue.js` now writes one wake row
after the `build_queue` upsert, when the row lands `queued` with `target=fly`:
repo `harness/build-queue` (a synthetic slug no fleet repo can equal), kind
`queue`, key `<project>:<KEY>`, event `build_queue.insert`. It uses the
existing `idx_wakes_dedupe(repo,kind,key,minute)` index with
`ON CONFLICT DO NOTHING`, so a re-queue in the same minute writes no second
row. The insert is best effort: a failure logs one `console.error` and the
enqueue still answers 201 with the same body. A `local` target or a `ready`
put writes no wake. No schema change.

`bin/lib/wake-class-queue.sh` is a new wake class. `bin/wake-loop.sh` gets two
marked blocks (`# >>> queue wakes (BH-4059)`):

- on the hub, an armed class adds `queue` to the claim's `kinds_all_repos`;
  unarmed, the claim stays `pr,checks` byte for byte;
- in the drain, a `queue` row is handed to the class before the fleet-repo
  mapping (which would drop it as "not a fleet repo") and is acked either way.

The class turns a drain's queue rows into ONE launch of `bin/fly-dispatch.sh`
and one of `bin/fly-pool-tick.sh`, logged as `queue[fleet] (<n> wake(s))`.
Off the hub, unarmed, or under `flags/wake-lanes-off`, nothing launches.

## What did not change

- The fly lanes' cron entries and cadences. A wake only starts them sooner.
- `bin/fly-results-ingest.sh` is never wake-launched: it holds no flock, so a
  wake copy racing its cron copy could ingest one RESULT twice.
- There is no per-invocation cap and no owed marker in this slice.

## Arming

Ships unarmed. Arm it only after the worker is deployed via harness-sync:

    bin/jobs-client.sh flag-set wake-lanes-queue on "BH-4059"

Tests: `worker/jobs/test/build-queue-wake.bh-4059.test.js`,
`tests/wake-class-queue.bh-4059-test.sh`.
