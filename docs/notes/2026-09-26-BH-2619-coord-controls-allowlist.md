# The coord proxy admits the Controls editors' four PUTs (BH-2513.2, BH-2619)

Doc: DB-COORDINATION-SPEC

## What changed

`console-ui/functions/api/coord/[[path]].js` has four new `WRITES` rows, all
PUT and all exact paths:

| path | forwarded body fields |
|---|---|
| `review-gate/thresholds` | scope, window_days, min_merges, tighten_rate, clear_rate, note, reason |
| `rules` | scope, selector, kind, max_concurrent, note, reason |
| `retry-policies` | lane, max_attempts, backoff_seconds, escalate_allowed, note, reason |
| `contracts` | phase, artifact_kind, pattern, note, reason |

Like every other body row, anything not listed is dropped, a query string is
not forwarded, and `actor` is stamped from `writeActor`.

Each row also carries a new property, `needsReason`. When the parsed body's
`reason` is missing, not a string, or only whitespace, the proxy answers
`400 {"error":"a reason is required"}` and nothing reaches harness-jobs. The
check runs after the "must carry a JSON object body" 400. A valid reason is
forwarded exactly as sent, with no trim.

`DELETE rules` and `PUT review-gate` still have no row, so they stay 405 from
a browser.

## Tests

`console-ui/tests/coord-controls-allowlist.bh-2513.test.js` drives the real
`onRequest`: P1 (the forwarded body per route), P2 (the reason 400s), P2b (the
check order) and P3 (the off-table verbs stay 405).
