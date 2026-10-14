# The bootstrap smoke writes a cost row; the model lint catches bare aliases

Doc: MODEL-ROUTES, LLM_CALL_SITES

## What was wrong

`bin/bootstrap-machine.sh` ran its install smoke turn as a bare
`claude -p --model "$SMOKE_M" "Reply exactly: OK"`. That call wrote no cost row,
so `catalog/llm-sites.json` listed it as `priced: "no"` and both raw-call
allowlists carried it. `tests/model-literal-lint.sh` only knew the full model
ids in the price catalog, so a bare alias like `--model haiku` passed it.

## What changed

- The smoke block now calls `$HERE/agent-call.sh probe fleet "$SMOKE_M" 90 <out>
  "Reply exactly: OK"` with `AGENT_CALL_RUNNERS=claude` and
  `AGENT_CALL_LANE=claude-auth-check`. It writes a priced cost row at stage
  `probe`, lane `claude-auth-check`. Pinning the runner to claude matters: a
  fallback rung answering OK would pass the smoke on a dead claude login. Any
  non-zero rc is FATAL (a refusal's marker line is quoted), and so is rc 0
  with an empty answer. The model still comes from `model_for bootstrap.smoke`.
  No knob was added.
- The `bootstrap-machine` row of `catalog/llm-sites.json` now says
  `kind: agent-call`, `stage: probe`, `lane: claude-auth-check`,
  `through_agent_call: true`, `priced: yes`, `gated: agent-call`. Its line is
  gone from `tests/raw-claude-allowlist.txt` and
  `tests/llm-call-ratchet-allowlist.txt`, so a regrown raw call goes red.
- `tests/model-literal-lint.sh` has a second scan for `haiku|sonnet|opus|fable`
  in model-argument position only: `--model X`, `<ident containing model>[:=] X`
  and a `${...:-X}` default. The alias has to end at a character that cannot
  continue a model id. Case labels, `claude-(opus|...)` regex vocabularies and
  prose are not hits. It prints `N bare-alias line(s) found (E exempt)` and
  fails under strict when N > 0.
- `tests/model-literal-alias-allowlist.txt` (path TAB reason) exempts one path,
  `bin/oauth-refresh.sh`. Its `--model haiku` belongs to BH-2549.3 (#2561).
  When that lands, the lint prints `stale alias exemption bin/oauth-refresh.sh`
  instead of failing, and the line should be deleted.

## Coupling to know about

The smoke now goes through the LLM gate, so the `claude-auth-check` lane's
settings apply to it. If that lane is disabled (`LLM_LANE_ENABLED=0`) or has hit
its day cap, agent-call refuses with rc 74 and every new-box bootstrap stops
FATAL, quoting the refusal. That is on purpose: a smoke that called nothing
proved nothing. But whoever turns that lane off should know `load-project`
stops with it.

## Stage `probe` has no route, on purpose

`probe` is listed in the `PINNED` table of
`tests/stage-route-seed.bh-2536-test.sh`, next to decompose, orchestrator and
the other stages whose caller decides the runner in code. There is no
`stage.probe` row in `worker/jobs/schema.sql`: bootstrap pins
`AGENT_CALL_RUNNERS=claude`, so a route would be a Models-page switch that
changes nothing. Once a bootstrap has written a cost row, the Models page's
unrouted-stages list (BH-2512) shows `probe`. That is expected. If someone drops
the runner pin from the smoke line, that suite's R6 goes red and says to seed
`stage.probe`. This PR is the second try: the first one (#2709) went red in the
merge queue on exactly that suite's R1, because nothing seeded or pinned `probe`.

## Still owed

The first real bootstrap after this lands should add one row to
`logs/cost.csv` with stage `probe` and lane_id `claude-auth-check`. That has not
been checked on a real box. The build could not run a real bootstrap.

## Not changed here

lane-probe, claude-auth-check, oauth-refresh and fly-builder-smoke are the
canary sites D9 (#2549) replaces, through its slices #2558 to #2562. This change
does not touch them or their census rows. #2560 names their stage `canary`, and
this ticket asked for `probe`. Only the bootstrap row uses `probe`.

Tests: `tests/bootstrap-smoke-agent-call.bh-2535-test.sh`,
`tests/model-literal-alias.bh-2535-test.sh`, `tests/stage-route-seed.bh-2536-test.sh` (the `probe` PINNED row).
