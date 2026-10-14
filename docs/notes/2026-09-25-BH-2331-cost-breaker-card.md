# Mission Control shows the cost breaker and can reset the call guard

Doc: CALL-GUARD, COST

## What was missing

An autohalt trip showed up only as a paused board. Nothing on the console said the pause came
from the breaker, and the worker's audited call-guard reset (`DELETE /api/call-guard`) had no
UI. The only way to reset a key was `bin/jobs-client.sh call-guard-reset` from a box.

## What changed

- `/costs` has a COST BREAKER section below SPEND (`console-ui/src/screens/CostBreaker.js`,
  shaping in `console-ui/src/lib/cost-breaker.js`):
  - AUTOHALT: ON, OFF or UNKNOWN from the `lane.pipeline-health.cost_autohalt` settings row. With
    no row, or a value `cb_knob` would ignore, the registry default (1, on) applies and the card
    says so. The hub-local `flags/cost-autohalt-off` file is not readable from the console, and
    the card states that next to the value. The switch stays on the Settings screen, which the
    card links to.
  - TRIPS: active `paused-<project>` flag rows whose reason ends with `(cost autohalt)` or
    `(zero-merge breaker)`, the two suffixes `cb_halt` writes. Each project links to `/p/<project>`,
    where RESUME already lives.
  - CALL GUARD · 24H: `GET /api/call-guard?hours=24`, one row per (project, stage, fp), with a
    CAP HIT tag when the guard refused at least one call in the window, and a RESET button.
- RESET needs a reason and sends `DELETE /api/coord/call-guard?project=&stage=&fp=&reason=`.
- The coord proxy (`console-ui/functions/api/coord/[[path]].js`) now admits exactly one DELETE:
  `call-guard`. `call-guard/claim`, `call-guard/settle` and every other DELETE still answer 405.
  The proxy sets `actor=console` on that request and overwrites any actor the browser sent, the
  same rule it already applies to hub/ POST bodies.

## What did not change

No worker route, schema, `bin/pipeline-health.sh` or `bin/lib/call-guard.sh` behavior changed.
A console reset writes the same audit row as `jobs-client.sh call-guard-reset`. Only the actor
differs.
