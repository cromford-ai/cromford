# agent-call reads the stage runner from the stage.* route and checks the model against it

Doc: OPERATOR-SETUP, MODEL-ROUTES

## What changed

`bin/agent-call.sh` picks each field of the runner in this order:

1. `RUNNER_<STAGE>` / `RUNNER_<STAGE>_FALLBACK` from env, as before.
2. Otherwise rung 0 / rung 1 of the `stage.<stage>` model route, read by
   `stage_runner_for` in `bin/lib/model-route.sh` (same client, box cache and
   hub-vs-project precedence as every other role).
3. Otherwise `claude`, with one `failovers.log` line per (stage, project) per UTC
   day: `<stage>/<project>: no stage.<stage> route and no RUNNER_<STAGE> — running claude`.

`stage_runner_for` never writes an ALERTS line: a missing `stage.*` route is the
normal case. A worker that is down with nothing cached is rc 75, so the call
behaves as it did before this change.

When an env `RUNNER_<STAGE>` and the route's rung 0 both exist and differ, the env
value runs and ALERTS gets one line per (stage, project) per UTC day:
`RUNNER_<STAGE> env=<env> overrides route stage.<stage>=<route>`.

Right after runner selection (after the `AGENT_CALL_RUNNERS` narrowing, before the
llm-gate precall), the `# >>> model-runner-match` block compares the argv model's
family (`claude-*`, `grok-*`/`x-ai/grok*`, `gpt-*`/`*codex*`) with the primary
runner when that runner is claude, grok or codex. On a mismatch it writes
`MODEL/RUNNER MISMATCH: …` to ALERTS once per (stage, project, runner, model) per
day and to `failovers.log` on every call. `AGENT_CALL_MODEL_MISMATCH=refuse`
stops the call there: `AGENT_CALL_REFUSED model-runner-mismatch …` in `$OUT` and
`$OUT.err`, a zero-cost refused row, rc 74. Any other value, unset included, warns
and runs.

## What operators should know

- `env-templates/lanes/030-llm-runners.env.example` no longer ships the six
  `RUNNER_*_FALLBACK=codex` lines. `bin/bootstrap-machine.sh` still appends
  fallback lines to `global.env` when they are absent (OPERATOR-SETUP, Step 0),
  and on a box that has them they override route rung 1.
- Every agent-call on a box with `HARNESS_SECRET` now makes one
  `GET /api/model-routes/stage.<stage>` read.
