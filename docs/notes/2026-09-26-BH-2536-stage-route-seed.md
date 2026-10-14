# A stage.* route for every catalogued stage

Doc: MODEL-ROUTES

## What changed

- **17 new `stage.*` seed rows** in `worker/jobs/schema.sql`, at hub scope:
  qa, preplan-files, prodqa, repro, lead-review, map, signals, ideate, synth,
  prd, mockup, revise, remediate, mine, feature-map-draft, readout, chat. Each one
  is a single rung with runner `claude` and no fallback. That is what
  `bin/agent-call.sh` already ran for these stages with no route, so no
  runner changes. The Models page can now switch any of them. The model on
  the rung is reused from `stage.execute` rung 0, and only the runner column
  decides anything. The seed is guarded per role the same way BH-1766 is:
  once an operator has written a role, a re-apply leaves it alone.
- **chat is seeded.** `bin/product-cmd.sh` and box-chat's primary call run it
  with no `RUNNER_CHAT`, so they read the route. Only box-chat's fallback retry
  exports `RUNNER_CHAT="$FB"`; if that disagrees with a non-claude route,
  agent-call writes its usual env-vs-route ALERTS line.
- **Five stages get no row**, because their callers pick the runner in code,
  so a route would switch nothing:
  - decompose: `bin/run-decompose.sh` (`export RUNNER_DECOMPOSE=`)
  - orchestrator: `bin/orchestrate.sh` (`env RUNNER_ORCHESTRATOR="$r"`)
  - trapeval: `bin/trap-eval.sh` (`RUNNER_TRAPEVAL="$runner"`)
  - bench: `bin/runner-bench.sh` (`RUNNER_BENCH="$runner"`)
  - eval: `bin/prompt-eval.sh` runs it under `AGENT_CALL_NO_TOOLS=1`, which only claude can run
- **Still open.** For those five, the gap this ticket was filed about stays
  open: their runner still cannot be switched from the Models page.
  decompose is the one that could be closed cheaply, because
  `bin/run-decompose.sh` only hard-defaults `RUNNER_DECOMPOSE` to
  `${RUNNER_PLAN:-claude}`; dropping that default would let a route apply.
  That needs its own ticket.
- **Census fix.** The `rb-plan` row in `catalog/llm-sites.json` said
  `...|verify`. The pipeline calls `CC qa`, and nothing calls `CC verify`. It
  now says `...|qa`.

## Ratchet

`tests/stage-route-seed.bh-2536-test.sh` fails when:
- an agent-call stage in the census has no seeded route;
- run-build calls a `CC <stage>` that the census row does not list;
- one of the five pinned stages gets a row, or its caller loses the pin. When a
  caller loses its pin, that stage owes a row.

`worker/jobs/test/stage-route-seed.bh-2536.test.js` drives the Models-page
PUT against the shipped schema.
