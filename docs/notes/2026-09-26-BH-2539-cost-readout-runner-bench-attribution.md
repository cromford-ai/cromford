# cost-readout and runner-bench bill to their own stage and project

Doc: COST, MODEL-ROUTES

## What was wrong

Two operator scripts wrote their cost rows under somebody else's name (goal-gap
audit 2026-09-25, gap C8).

- `bin/cost-readout.sh` is a fleet read-out, but it called
  `agent-call.sh review project-1`. Every row it wrote landed in project-1's
  review spend.
- `bin/runner-bench.sh` called `agent-call.sh triage bench`. The gate
  (`llm_gate_lane_id`) finds no lane filtered on project `bench`, so it fell to
  the one null-filter triage lane, `run-triage`. Bench spend counted against
  run-triage's `LLM_USD_CAP_DAY`, and a bench run could be refused by it.

Neither script is any lane's `script`, so the BH-2304 lane-stage ratchet never
looked at them.

## What changed

- cost-readout bills `readout` / `fleet`. Its gate lane is still `cost-rollup`
  (`AGENT_CALL_LANE`). Its model is `review_model "$HARNESS" fleet`, and the
  call carries `AGENT_CALL_ROLE=build.review`, so it walks the same claude
  ladder as before. A project-1-only `build.review` override no longer applies
  to it.
- runner-bench bills `bench` / `bench`. The runner comes from `RUNNER_BENCH`,
  which it already set; the dead `RUNNER_TRIAGE` is gone. That also fixes
  `run()` with an empty env hint, which exited 127 before (the empty `$(...)`
  word left `RUNNER_TRIAGE=...` in the command position) and never called the
  model.
- The gate now answers the synthetic `stage-bench` for bench. Its knobs are
  the raw keys `lane.stage-bench.*`; there is no registry lane, so harness-ctl
  cannot set them by lane name.
- `catalog/context-budgets.json` gains lanes `cost-readout` (readout, fleet,
  30K / 180K) and `runner-bench` (bench, 50K / 180K). Both are unmeasured and
  unarmed. Bench loses project-triage's 2.7M context kill until bench rows are
  measured (BH-2538: no kill without data); the $25 dollar tripwire still
  bounds it.
- `catalog/llm-sites.json` rows say the new stage and project.
- The ratchet (`tests/lib/lane-stage-check.py`) gains a sites pass: every
  `kind: agent-call` site's declared stage must equal what its script passes,
  and a literal declared project must equal the literal project argument.
  `rb-plan` and `trap-eval` are skipped (no call the scanner can resolve), and
  `tests/lane-stage-ratchet.bh-2539-test.sh` pins that skip set.

History is not rewritten: rows written before this change keep their old
stage and project.
