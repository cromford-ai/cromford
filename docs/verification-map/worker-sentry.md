# Workers report exceptions to Sentry (BH-5618)

**What it is:** `withHarnessSentry` in `worker/jobs/src/lib/sentry.js` wraps the
`fetch` and `scheduled` handlers of `harness-jobs`. `harness-cloud` used the
same file; it moved to example-org/cromford-web (BH-5239). With the Cloudflare
secret `HARNESS_SENTRY_DSN` bound, an exception becomes one Sentry event. With
no DSN the handler runs unchanged and `@sentry/cloudflare` is never imported.

**What is sent:** the exception and its stack, with tags `lane`
(`harness-jobs`), `box` (`cloudflare`), `project` (`-`) and
`harness_sha` (`HARNESS_SHA`, else `unknown`). The deploy in
`bin/harness-sync.sh` sets `HARNESS_SHA` to the full sha of the snapshot it
deployed (`wrangler deploy --var HARNESS_SHA:<sha>`), for each worker whose
`src/` names `HARNESS_SHA` (BH-6813). An error that
`worker/jobs/src/lib/d1-retry.js` gave up on also carries tag `d1_attempts`
(the attempt count, `5`) and tag `d1_op`: `<method> <VERB> <table>` of the
call that gave up, for example `all PRAGMA pause_flags` or
`batch(4) UPDATE stages`. `d1_op` never holds SQL text, a literal or a bound
value. `beforeSend` removes the request
body, cookies, query string, and every header, `extra`, `contexts` and
breadcrumb key that matches `authorization|cookie|token|secret`.

**Spend gate (in `beforeSend`, before the send):**
- at most `HARNESS_SENTRY_MAX_PER_FP_HOUR` events (default 6) per worker +
  exception type + first 120 characters of the message, per UTC hour, per
  isolate. The SDK's own dedupe also drops an event equal to the one before it;
- the `pause_flags` row `lane-off-sentry-report` with `active = 1` drops
  every event. A failed read of that row sends (fail-open).

**D1 overload retry (BH-6690):** `fetch` in `worker/jobs/src/index.js` wraps
`env.DB` with `retryingDb` from `worker/jobs/src/lib/d1-retry.js`, once per
request, memoised per binding. `ensureTable` and `ensureColumns` in
`lib/core.js` key their caches on the raw binding (`rawDb`), so the raw
binding and the proxy share one cache entry. Every `first`, `all`, `run`, `raw`, `batch` and
`exec` call that fails with `D1 DB is overloaded` runs again, at most 5
attempts in total (BH-6813; 3 before). The wait before attempt n+1 is `d/2`
plus a random part up to `d/2`, where `d = min(1000, 100 * 2^(n-1))` ms, so a
give-up sleeps 750 to 1500 ms in total. Any other error rethrows after one
call. After the 5th failure the same error rethrows with `d1Attempts = 5` and
`d1Op`, and the one event withSentry sends carries tags `d1_attempts` and
`d1_op`. There is no second capture. Verified by
`worker/jobs/test/d1-retry.bh-6690.test.js` and
`worker/jobs/test/d1-retry.bh-6813.test.js`.

**Deploy:** `harness-jobs` sets `compatibility_flags: ["nodejs_compat"]`. The
`# >>> worker npm ci (BH-5618)` block of `bin/harness-sync.sh` runs
`npm ci --omit=dev` in the worker snapshot before `wrangler deploy`. A failed
install writes one ALERTS line (`npm ci FAILED`), skips that deploy and leaves
the stamp, so the next run retries.

**Where the secret is set:** `harness-jobs` has `HARNESS_SENTRY_DSN`.

**Verified by:** `tests/worker-sentry.bh-5618-test.sh`, which runs
`worker/jobs/test/sentry.bh-5618.test.js` and drives the harness-sync block,
and `tests/harness-sync-sha-var.bh-6813-test.sh` for the `HARNESS_SHA` var.

**Live probe (hub, read-only):**
1. `grep "worker jobs deployed" /root/harness/logs/update-runners.log | tail -1`
   shows the merge sha, and `logs/ALERTS.log` has no `npm ci FAILED` line.
2. `GET /api/flags` on harness-jobs with the fleet bearer answers 200.
3. In Sentry project `cromford-harness`, filter on tag `lane:harness-jobs`. An
   event shows only after a real exception. Do not force one on prod.
4. After a deploy of BH-6690, read the 24 h event count of issue
   CROMFORD-HARNESS-W (7791943763). Pass: below 10 (113 before).
5. After a deploy of BH-6813, read the newest event of issue
   CROMFORD-HARNESS-19 (7792534404), if any. Pass: 0 new events in 24 h. An
   event that does come must carry `harness_sha` equal to the full snapshot
   sha whose first 7 characters the step 1 line names after `snapshot of`,
   `d1_attempts` `5`, and
   a `d1_op` that names the query.
