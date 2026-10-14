# harness-jobs retries a D1 overload (BH-6690)

Doc: VERIFICATION-MAP

## The gap

The harness-jobs worker sent every D1 query once. D1 rejects a query with
`D1_ERROR: D1 DB is overloaded. Requests queued for too long.` when its queue
is full. One such rejection failed the whole request. Sentry issue
CROMFORD-HARNESS-W (7791943763) counted 113 events in 24 h.

## What changed

- New lib `worker/jobs/src/lib/d1-retry.js`. `withD1Retry` runs a D1 call at
  most 3 times. It retries only an error whose message contains
  `D1 DB is overloaded`. The wait before attempt n+1 is `d/2` plus a random
  part up to `d/2`, where `d = min(1000, 50 * 2^(n-1))` ms. Any other error
  rethrows after one call. After the 3rd failure the same error rethrows with
  `d1Attempts = 3`.
- `fetch` in `worker/jobs/src/index.js` replaces `env.DB` with
  `retryingDb(env.DB)` once per request. The proxy is memoised per binding.
  `first`, `all`, `run`, `raw`, `batch` and `exec` go through the retry. No
  route changed.
- `ensureTable` and `ensureColumns` in `worker/jobs/src/lib/core.js` key their
  caches on the raw binding (`rawDb`). A caller that holds the raw binding and
  a request through the proxy share one cache entry.
- `beforeSend` in `worker/jobs/src/lib/sentry.js` adds tag `d1_attempts` to
  the one event withSentry already sends for a give-up. The message and stack
  do not change, so the event groups into the same Sentry issue.

The attempts and the backoff are code constants. They bound a retry against a
D1 that is overloaded, so they cannot be read from D1 in the same request.

## Not done here

The ticket also asks to read the worker's D1 query rates and spread or batch
the heaviest writers. That needs Cloudflare D1 analytics and a study of the
cron schedule. It is still owed.

## Check on the box

1. `grep "worker jobs deployed" /root/harness/logs/update-runners.log | tail -1`
   shows the merge sha.
2. 24 h after that, read the event count of CROMFORD-HARNESS-W for the window.
   Pass: below 10 (113 before).
