# The runner per build stage is a model_routes row: `stage.<stage>`

Doc: MODEL-ROUTES

## What changed

- `worker/jobs/schema.sql` seeds six hub roles, `stage.triage`, `stage.plan`,
  `stage.preplan`, `stage.execute`, `stage.review` and `stage.fix`. Each has two
  rungs: position 0 runner `claude` (agent-call's default) and position 1
  runner `codex` (the `RUNNER_*_FALLBACK=codex` template value). For a
  `stage.*` role the runner column is what decides. The model is the one that
  rung runs, reused from an existing seed row of the same runner. The seed is
  guarded per role, so a re-apply never puts back a rung an operator cut.
- `PUT /api/model-routes` refuses a `stage.*` ladder longer than two rungs
  (400). Agent-call reads a primary and one fallback, nothing past it. An
  unknown runner was already a 400.
- `/models` shows the `stage.*` roles as their own STAGE RUNNERS table: stage,
  runner, fallback runner, model, scope and a history link. They are left out
  of the main roles table and the SPEND ATTRIBUTION note. Their spend is
  already counted under that stage's model roles.
- `bin/runner-routes-seed.sh [--apply]` is new. It is a one-shot, run on the
  hub, that writes the box's live `RUNNER_<STAGE>` / `RUNNER_<STAGE>_FALLBACK`
  values (for example the hub's `RUNNER_TRIAGE=grok`) as audited hub PUTs, with
  the box name as the actor. It reads `global.env` with sed and never sources
  it. It refuses any runner outside claude|codex|openrouter|grok|fireworks
  before it asks the worker anything. A ladder that already matches is left
  alone. A failed read exits 2.

## What it does not change yet

Nothing reads these rows. `stage_runner_for` in `bin/lib/model-route.sh` is
still the BH-1749.0 stub (rc 75), so every stage still runs on its
`RUNNER_*` env value until the agent-call sibling of #1749 lands.

## Operator step

After the worker deploy applies the schema, run
`bin/runner-routes-seed.sh` on the hub to see what the box's env would change,
then `bin/runner-routes-seed.sh --apply` to write it.
