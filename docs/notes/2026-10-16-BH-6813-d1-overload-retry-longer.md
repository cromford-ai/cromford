# D1 overload retry waits longer and names the query (BH-6813)

Doc: OPERATING

## The gap

Sentry issue CROMFORD-HARNESS-19 kept getting "D1 DB is overloaded" events
after BH-6690 deployed the retry. The retry made 3 attempts at a 50 ms base,
so it gave up after at most 150 ms of sleep. The events also tagged
`harness_sha` `unknown`, because nothing set `HARNESS_SHA`, and they did not
name the query.

## What changed

- `worker/jobs/src/lib/d1-retry.js`: at most 5 attempts at a 100 ms base
  (cap 1000 ms). A give-up sleeps 750 to 1500 ms in total. The formula and
  the jitter are the same.
- On give-up the error carries `d1Op`, `<method> <VERB> <table>` (for example
  `all PRAGMA pause_flags`, `batch(2) UPDATE stages`). `d1OpOf` cuts string
  literals and comments out first and keeps only identifiers, so no SQL text,
  literal or bound value goes out. `lib/sentry.js` tags it `d1_op`.
- `bin/harness-sync.sh` `deploy_workers` passes
  `--var HARNESS_SHA:<snapshot sha>` to `wrangler deploy` for a worker whose
  `src/` names `HARNESS_SHA` (today only `worker/jobs`). The value is the full
  sha of the snapshot, the `snapshot of` sha in the update-runners.log line.
- `/api/verdict` and `/api/verdict/history` still answer
  `503 {retryable:true, d1_attempts}` on a give-up (BH-6807). `d1_attempts`
  is now 5.

## Policy before and after

| | before (BH-6690) | after (BH-6813) |
|---|---|---|
| attempts | 3 | 5 |
| base | 50 ms | 100 ms |
| cap | 1000 ms | 1000 ms |
| waits (d) | 50, 100 | 100, 200, 400, 800 |
| total sleep before a give-up | 75..150 ms | 750..1500 ms |

The jobs client timeout (`curl -m "${JOBS_TIMEOUT:-8}"`) still bounds a
give-up: 1.5 s of sleep plus 5 D1 round trips.

## Post-deploy probe

1. Run `grep "worker jobs deployed" /root/harness/logs/update-runners.log | tail -1`.
   It names the snapshot after `snapshot of`.
2. In Sentry, open issue 7792534404 (CROMFORD-HARNESS-19). Pass: 0 new events
   in 24 h. An event that does come must carry `harness_sha` equal to that
   snapshot sha, `d1_attempts` `5`, and a `d1_op` that names the query.

## Not changed

The constants stay code constants: a retry bound against an overloaded D1
cannot be read from that D1. The batching of a heavy job's writes waits for
`d1_op` evidence after the deploy.

Tests: `worker/jobs/test/d1-retry.bh-6813.test.js`,
`tests/harness-sync-sha-var.bh-6813-test.sh`.
