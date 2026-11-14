# BH-9263: the QA read token, the QA allowlist and the Pages middleware

Doc: OPERATOR-SETUP, DB-COORDINATION-SPEC

## What changed

A console QA preview session (a `dashqa` cookie, BH-5909) runs unreviewed
preview JS. Before this change, the coord proxy forwarded every QA GET to
harness-jobs under `HARNESS_SECRET`. So `GET /api/coord/otp` returned a login
code and `GET /api/coord/settings` returned every knob.

1. The QA allowlist. `console-ui/functions/_lib/qa-read-policy.js` holds
   `QA_READ_ROUTES`: `jobs` and `flags`. Pages answers `whoami` itself. Each
   route lists its allowed query parameters and the fields an answer keeps.
   An unknown route, parameter, top-level key or column is dropped. `meta`,
   `beat_note`, `beat_box` (jobs) and `value`, `actor` (flags) are not on the
   list.
2. The coord proxy (`console-ui/functions/api/coord/[[path]].js`, `qaRead`).
   A QA GET off the list answers `403 {"error":"not available to a QA
   session"}`, and harness-jobs is not called. A QA GET on the list forwards
   only the allowed parameters and projects the answer, `no-store`. The
   operator path does not change.
3. The jobs worker (`worker/jobs/src/lib/qa-read.js`). After `bearerOk`
   fails, a `QA_READ_TOKEN` bearer runs the real GET handler of an allowlisted
   route with the allowed parameters only, and answers the projected body.
   Anything else under that token is 403. An unset or blank token, or a token
   equal to `HARNESS_SECRET`, opens nothing.
4. The Pages root middleware (`console-ui/functions/_middleware.js`, `/api/*`
   only):
   - A write (not GET, HEAD or OPTIONS) that carries a `dash` or `dashqa`
     cookie must be same-origin: `Origin` equal to this origin, or no
     `Origin` and `Sec-Fetch-Site: same-origin`, or neither header. Else 403.
   - A request with both `dash` and `dashqa`: the console worker is asked
     about `dash` alone. A 200 removes `dashqa` from the request (an operator
     with a stale QA cookie keeps full access). Any other answer or a throw
     removes `dash` (a forged `dash` stays a QA session).
   - Every `/api/*` response is `Cache-Control: no-store`.

## Two copies of the policy

`worker/jobs/src/lib/qa-read-policy.js` is a byte-identical copy of
`console-ui/functions/_lib/qa-read-policy.js`. Each deploy bundles only its
own tree: a console preview copies only `console-ui/functions` and
`console-ui/src` (`bin/lib/console-preview.sh`), and the worker deploy
snapshot (`bin/harness-sync.sh` `snapshot_tree`) holds `worker/`, `catalog/`
and `agent-core/`. A worker import from `console-ui/` would stop the
harness-jobs deploy (the BH-6687 failure). Edit both files together: worker
test J9 and `tests/qa-read-token.bh-9263-test.sh` fail when they differ.

## The allowlist is code

A settings row would let a `HARNESS_SECRET` holder widen what the separate
token opens. To add a route, add a row to `QA_READ_ROUTES` with its
parameters and fields, in both copies, in a PR.

## The log lines (the measurement)

The ticket asks to start the allowlist from 7 days of the coord proxy log.
No build can wait 7 days, so the list starts with the three routes the
ticket names, and every QA GET writes one line to the Pages log:

- `qa-read: allowed GET <route>`
- `qa-read: refused GET <route>`: read these to find what QA previews need.
- `qa-read: QA_READ_TOKEN unset; GET <route> under HARNESS_SECRET, projected here`
- `qa-read: QA_READ_TOKEN refused by harness-jobs; GET <route> retried under HARNESS_SECRET, projected here`

No line holds a query string or a token.

## Env set-up order

1. Make a new random value. Set it as the harness-jobs secret
   `QA_READ_TOKEN` (`wrangler secret put QA_READ_TOKEN` in `worker/jobs`).
2. Set the same value as `QA_READ_TOKEN` on the Pages project, production
   and preview.

Until step 2, QA previews use the fallback mode: `HARNESS_SECRET`, the same
projection on Pages, and one `QA_READ_TOKEN unset` warn line per QA GET. If
step 2 runs before step 1, harness-jobs answers 401, and Pages retries once
under `HARNESS_SECRET` with the `refused by harness-jobs` warn line.

## Tests

`console-ui/tests/qa-read.bh-9263.test.js`,
`console-ui/tests/middleware.bh-9263.test.js`,
`worker/jobs/test/qa-read-token.bh-9263.test.js`, run together by
`tests/qa-read-token.bh-9263-test.sh`.
