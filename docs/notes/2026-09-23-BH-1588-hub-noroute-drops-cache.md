# A hub "no route" answer now drops the hub cache too

Doc: MODEL-ROUTES

BH-1588, a follow-up from the #1581 review.

## What changed

`model_ladder` in `bin/lib/model-route.sh` deletes the cache for the scope it
read when a reachable worker says there is no route (`ladder: []`, or a gapped
hub ladder with no rung 0). #1581 did that for project scope only: the
project's cache and its `.hub` marker. A hub read now also deletes
`state/model-routes/<role>.tsv`. The rc 75 and the one-a-day ALERTS line are
unchanged.

## Why

Without it, the hub's cache outlived the worker's answer. The next time the
worker was unreachable, the outage branch served `<role>.tsv`, which held rungs
the worker had just said no longer exist. That's the exact replay the file
header says a `source: none` answer must never allow.

## Scope

Only the scope that was read is cleared. A hub "no route" does not touch any
project's own `<role>@<project>.tsv` or `.hub` marker; each project's own read
governs those. A transport failure (unreachable, 404, a 2xx that is not a
model-routes answer) still never deletes anything.

## Tests

- `tests/model-route-hub-noroute.bh-1588-test.sh` (new): hub none deletes
  `<role>.tsv`, the following outage is rc 75, one ALERTS line, project cache
  untouched, a plain outage with a warm cache still serves it.
- `tests/model-route-other-lanes.bh-1510-2-test.sh`: the #1581 no-route block
  now seeds `lander.tsv` before its outage call, so its rc 75 proves the `.hub`
  marker path is shut rather than just finding no hub cache to serve.
