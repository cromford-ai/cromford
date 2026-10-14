# The model-id literal lint is an error, pinned at 0, and CI runs it on every PR

Doc: MODEL-ROUTES

## What changed

BH-1510.4, the last slice of "no model id literal in code".

- **The lint is strict by default.** `tests/model-literal-lint.sh` now exits 1
  on any model id it finds under `bin/`, `fly/`, `worker/jobs/src`,
  `console-ui/src`, `prompts/` or `catalog/lanes.d`, comments included.
  `--warn` lists the hits and exits 0, for surveying only. `--strict` is still
  accepted and does nothing extra. The baseline went from 157 lines (2026-09-22)
  to 0.
- **CI runs it on every PR.** `.github/workflows/harness-ci.yml` has a step
  `model-id literal lint (BH-1510)` in the `Pure-logic gate fixtures` job, next
  to the `tests/ sourcing lint`. It runs whatever `bin/test-impact.sh` selects.
- **`bin/update-model-prices.sh` has no slug map of its own.** The bash
  `MAP='{…}'` table is gone. `catalog/model-slugs.json` was already a superset
  of it (BH-1361) and is now the only map. If that file is absent or not an
  object of strings, the lane writes one ALERTS line
  (`model-prices: slug map absent|invalid at … — no refresh, keeping existing
  table …`) and exits 0 before the OpenRouter fetch. `state/model-prices.json`
  is left alone. Before, it quietly priced from the script copy and logged to
  `agent-rules.log`. An empty `{}` is unchanged: the >=5 floor refuses the write.
- **The bootstrap smoke turn reads a route.** `bin/bootstrap-machine.sh` (the
  `# >>> smoke model` block) asks `model_for bootstrap.smoke`. The new hub row
  in `worker/jobs/schema.sql` carries the id the script used before, so
  deploying it changes nothing. No route in the DB and none cached is FATAL,
  naming the role, and `claude` is never called.
- Ten comments that named a model id now say `<model id>` or name the family in
  words. No code token changed in those files.

## Already done before this slice

- Every `*_MODEL` knob in `catalog/lanes.d` has `default: ""` and names its role
  (#1507's knobs folded into roles). `tests/model-literal-strict.bh-1510-4-test.sh`
  pins that.
- The #1507 carry-over seed rows were already moved in prod on 2026-09-23 by
  `lead` and `operator (claude session)`. The planner probed
  `GET /api/model-routes/<role>` for them at 2026-09-24T12:58Z. This PR does not
  change them.

## How to change a model now

`PUT /api/model-routes/<role>` or the console Models screen. A new call site
adds a role (an `INSERT OR IGNORE` seed row in `worker/jobs/schema.sql`) and
reads it through `bin/lib/model-route.sh`. A new model to price is a key in
`catalog/model-slugs.json`.
