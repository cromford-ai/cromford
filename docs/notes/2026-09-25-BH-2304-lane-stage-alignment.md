# LLM gate: a lane's registered stages are the stages its script calls with

Doc: LLM_CALL_SITES

## What was wrong

`bin/lib/llm-gate.sh` picks the lane a model call belongs to by matching the call's stage
against `stats.cost_stage` in the lane registry. Two lanes registered a stage their script
never passes to `bin/agent-call.sh`:

- postmerge-qa registered `fix` and calls with `prodqa`.
- run-product registered `plan` and calls with `map`, `signals`, `ideate` and `synth`.

So neither lane's `LLM_USD_CAP_DAY` or `LLM_LANE_ENABLED` ever applied to its own calls.
It was worse the other way round. Those knobs landed on run-build's `fix` and `plan`
stages. Switching run-product off would have refused every build plan in the fleet.

Four more lanes did not match what they call: blocked-resolver (`execute` only, calls
`execute` and `review`), review-rescue (`review`), rule-miner (`mine`) and prompt-eval
(`eval`) had no stage or a partial one.

## What changed

- `stats.cost_stage` takes a string or an array of strings. Six `catalog/lanes.d` files
  now list exactly the stages their script calls with.
- `llm-gate.sh` matches a stage inside an array. A lane with several stages is one
  budget: `_llm_cap_check` sums one D1 spend read per registered stage
  (`_llm_lane_stages`). If any of those reads fails, the total is unknown and the call is
  allowed (fail open), the same as a single failed read before.
- `GET /api/lanes/status` owns a spend row when its stage is any of the lane's stages. A
  lane is `shared` when any of its `stage|filter` pairs is shared.
- `tests/lane-stage-ratchet.bh-2304-test.sh` fails when a lane's registered stages differ
  from the stages its own script passes to `agent-call.sh`. Lanes with no direct call in
  their own script (fly-pool, preplan-tick, merge-conductor, run-triage) are skipped.

## What operators will see

- `fix` and `plan` now resolve to `stage-fix` / `stage-plan`. Any existing
  `lane.postmerge-qa.*` or `lane.run-product.*` LLM row now gates those lanes' own calls,
  not the build pipeline. Nobody checked from the build box whether such rows exist in
  prod.
- `review` is shared by five lanes and `execute` by two, so those calls still resolve to
  `stage-review` / `stage-execute`. On the lanes page, blocked-resolver and review-rescue
  now show `cost_attribution: shared`.
- The console Settings note renders an array as `map,signals,ideate,synth`.
