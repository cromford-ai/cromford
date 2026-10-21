# BH-7764: gateFacts is one indexed read; an overload give-up is a 503

Doc: pr-rows-contract

Sentry CROMFORD-HARNESS-1P: `GET /api/pr-state/gate` threw
`D1 DB is overloaded. Requests queued for too long.` after all 5
withD1Retry attempts, 3 times in 24 h.

What changed:

- `gateFacts` (`worker/jobs/src/lib/pr-gate.js`) runs ONE statement:
  `WHERE repo=?1 AND state='gate' ORDER BY number, id`. It folds each field
  to its latest non-null value in JS. The old SQL ran 14 correlated
  subqueries per PR. The output is the same (pinned by E1, which runs the
  old SQL as the reference).
- New index `idx_pr_state_events_gate ON pr_state_events(repo, state,
  number, id)`, in `worker/jobs/schema.d/202610202038-bh-7764-pr-gate-index.sql`
  and in the `CREATED_TABLES.pr_state_events` belt in `core.js`. The deploy
  applies it through `bin/harness-sync.sh` (BH-4987).
- `GET /api/pr-state/gate` and `GET /api/pr-state/needs-review` use
  `overloadGuardedRoute("pr_state_events", …)` (BH-7580). An overload
  give-up answers 503 `retryable:true` with one `d1-overload:` warn line and
  no Sentry event. Every other error still throws to withSentry.

Not changed: the retry constants in `lib/d1-retry.js` (5 attempts, fleet-wide).

Test: `worker/jobs/test/pr-gate-overload.bh-7764.test.js`.
