# trap-eval and feature-map-draft name their lanes

Doc: LLM_CALL_SITES, LANES

## What was wrong

Both scripts call `bin/agent-call.sh` without `AGENT_CALL_LANE`, so their
`catalog/llm-sites.json` rows said `"lane": null` and `bin/lib/llm-gate.sh` had
no lane to read `LLM_LANE_ENABLED`, `LLM_RUNNER_ALLOWED` or `LLM_USD_CAP_DAY`
from. trap-eval had no registry lane at all, so it had no off switch either.

## What changed

- New lane `catalog/lanes.d/trap-eval.json`: operator-run, no cron line, the
  eight builder boxes (not the hub), switch `lane-off-trap-eval`, cost stage
  `trapeval`, and the three LLM knobs read in `bin/lib/llm-gate.sh`. It also
  registers the three env names the script already read, because a wired lane
  must carry them (`tests/lanes-registry-test.sh` §7): `TRAP_EVAL_AGENT_CALL`
  and `TRAP_EVAL_FIXTURES` (not settable from the control plane) and
  `TRAP_EVAL_JUDGE_TIMEOUT` (default 300 s, settable 1..3600).
- `catalog/lanes.d/feature-map-draft.json` gets the same three knobs after
  `FEATURE_MAP_DRAFT_ENABLED`.
- `bin/trap-eval.sh` exports `AGENT_CALL_LANE=trap-eval` and runs the lane
  gate after argument parsing, before refusal 1. `flags/all-off` or
  `flags/lane-off-trap-eval` exits 0 before any cell, `--list` and `--dry-run`
  included. It sources `lane-gate.sh` from `$HARNESS` and falls back to the lib
  beside the script.
- `bin/feature-map-draft.sh` exports `AGENT_CALL_LANE=feature-map-draft` above
  its existing lane gate.
- The `trap-eval` and `feature-map-draft` rows in `catalog/llm-sites.json` name
  those lanes. No other row changed.

The knob defaults (1 / "" / 0) change nothing until somebody writes a settings
row. The lane gate only reads flags: leaving the hub out of `boxes` does not stop
a no-tools trap-2 run there.

Pinned by `tests/llm-lane-bind.bh-2580-test.sh`.
