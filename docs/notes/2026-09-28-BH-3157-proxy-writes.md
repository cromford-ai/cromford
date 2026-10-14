# The coord proxy admits the merge-queue PATCH and the held-page release (BH-3157)

Doc: harness-control-plane, MERGE-CONDUCTOR

Slice BH-2325.2. `console-ui/src/api.js` already had `setMergeQueue` and
`releaseHeldPage` (BH-3155), but the coord proxy
(`console-ui/functions/api/coord/[[path]].js`) had no `WRITES` row for either,
so both answered 405. It now has two rows, each with a validator that rebuilds
the body.

| Write | Checked here | Forwarded |
|---|---|---|
| `PATCH merge-queue` (`mergeQueueBody`) | `project` a non-blank string; `pr` a positive integer of number type (`'41'` is a 400, not coerced); `status` exactly `queued`, `blocked` or `dropped` (`landed` is a 400: the console never records a landing); `reason` a non-blank string | `{project, pr, status, reason, actor}` |
| `POST conductor/held/release` (`heldReleaseBody`) | `repo`, `state`, `head`, `kind` strings; `number` a positive integer of number type; `why` a non-blank string | `{repo, number, state, head, kind, why, actor}` |

- The actor is the proxy's (`console`, or the Access email when Access verifies).
  A browser `actor`, unknown keys and a `__proto__` key are dropped.
- Values are forwarded as sent. Blank is checked on the trimmed string, but a
  padded value is not trimmed.
- An invalid body is a 400 and nothing reaches the worker. The worker's own
  refusals (unknown project, a 409 transition, a bad hold key, `why` over 2000
  characters) come back with the worker's status.
- `POST merge-queue` (enqueue), `PUT`/`DELETE merge-queue` and every write to
  `conductor/held` itself are still 405.
- No worker change. The routes are `worker/jobs/src/routes/merge-queue.js` and
  `worker/jobs/src/routes/conductor-held.js`.

Tests: `console-ui/tests/merge-queue-proxy.bh-3157.test.js`, through the real
`onRequest` with a stubbed fetch.
