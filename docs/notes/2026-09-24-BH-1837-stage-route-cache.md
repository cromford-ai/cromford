# agent-call caches the stage route read, bounds its wait, and stops repeating the mismatch line

Doc: OPERATOR-SETUP, MODEL-ROUTES

## What changed

Follow-ups to BH-1765 (`2026-09-24-BH-1765-stage-runner-routes.md`).

- **The `stage.<stage>` route read is cached on the box.** `stage_runner_for` in
  `bin/lib/model-route.sh` takes two optional args, `[ttl-s] [timeout-s]`, and only
  `bin/agent-call.sh` passes them. With a TTL, the answer is kept in
  `state/model-routes/stage-runner/<role>[@project].ans`: `runner<TAB>fallback` for
  a route, `-` for none. A fresh file answers with no network call. Without the
  args nothing is cached, as before.
- **The worker wait is capped.** The lookup runs with `JOBS_TIMEOUT=<timeout-s>`
  and `JOBS_RETRIES=0`, scoped with `local` so no other `model_ladder` caller
  sees it. On a timeout `model_ladder` serves its last-good ladder if the box has
  one; otherwise the call runs `RUNNER_<STAGE>` or claude, and that "none" is
  cached for the TTL too. Before this a hanging worker cost up to ~17 s per call.
- **Two knobs**, rows on the `agent-call` lib in `catalog/lanes.d/_lib.json`
  (`lib.agent-call.agent_call_stage_route_ttl_s`, default 120, 0 = no cache;
  `lib.agent-call.agent_call_stage_route_timeout_s`, default 3, max 8). Env
  template: `env-templates/lanes/031-agent-call-stage-route.env.example`.
- **`AGENT_CALL_MODEL_MISMATCH` is registered** on the same lib (string, default
  `warn`). It used to exist only in the env template.
- **The warn-mode `failovers.log` mismatch line is once a day** per (stage,
  runner, model), across projects, throttled by
  `flags/noted-model-runner-mismatch-<STAGE>-<runner>-<model>-<YYYYMMDD>`. Refuse
  mode still writes a line for every refused call. The ALERTS line is unchanged
  (once a day per stage, project, runner, model).
- **alerts-medic skips its own mismatch line.** A row whose own leading tag is
  `[medic]` and that reads `MODEL/RUNNER MISMATCH:` is dropped from the pass
  before the claim, the family stamp and the SEEN write (block `# >>> own
  mismatch line` in `bin/alerts-medic.sh`), and `medic.log` gets one count line.
  The row stays `new` on the console. Other projects' mismatch lines still reach
  the medic.

## Not done here

Seeding the `stage.*` rows (`bin/runner-routes-seed.sh --apply`, after #1832
merges) is a production write and is left as an operator step.

Tests: `tests/agent-call-stage-route-cache.bh-1837-test.sh`,
`tests/alerts-medic-self-mismatch.bh-1837-test.sh`.
