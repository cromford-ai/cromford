# Per-stage runner allow-list for build calls (LLM_RUNNER_ALLOWED_<STAGE>)

Doc: llm-choke-point

Part 4 of #2533. BH-2578 made every run-build model call name the `fly-pool`
lane, so fly-pool's lane-wide `LLM_RUNNER_ALLOWED` binds a build. That is one
list for every build stage. This adds a second list per stage.

## What changed

- `llm_gate_runner_ok` in `bin/lib/llm-gate.sh` checks the lane-wide
  `LLM_RUNNER_ALLOWED` first, exactly as before, with the same refusal string.
  If the rung passes, it then reads `LLM_RUNNER_ALLOWED_<STAGE>` through
  `lane_knob` (stage upper-cased, `-` read as `_`). A rung has to be in both
  lists. An empty list is every rung. Matching is exact, so `openrouter` never
  matches `openrouter-floor` or the other way round. A stage whose name has a
  character outside letters, digits, `-` and `_` reads no knob.
- A per-stage refusal reads
  `runner-not-allowed <rung> not in [<list>] lane=<lane> stage=<stage>`, and it
  leaves the usual zero-cost `row_source=refused` row in `logs/cost.csv`.
- `catalog/lanes.d/fly-pool.json` registers `LLM_RUNNER_ALLOWED_PLAN`,
  `_EXECUTE`, `_REVIEW`, `_FIX` and `_QA`, strings with default "". Those are
  the five stages `CC()` is called with. `stats.cost_stage` and the three
  lane-wide knobs are unchanged.

## How to use it

To keep one project's execute stage off the metered fallback rungs, write the
settings row `lane.fly-pool.<project>.llm_runner_allowed_execute = claude,codex`
(console knob page or `bin/harness-ctl.sh`). Drop the `<project>.` part to set
it for every project's builds.

## What this does not cover

- A lane-less `fix` call (`bin/lander.sh`) resolves to `stage-fix`, not
  fly-pool, so a fly-pool `_FIX` row does not bind it.
- On a Fly builder a settings row only takes effect if `_lg_settings_refresh`
  can reach `GET /api/settings`. If it cannot, `lane_knob` falls back to the
  environment and then the registry default (""), so the gate fails open and
  every rung is allowed. That is the same BH-1141 fail-open rule the lane-wide
  knob follows, and nothing in this change proves the row reaches a live
  builder.
- An exported `LLM_RUNNER_ALLOWED_<STAGE>` binds any lane that reads it, the same
  as the lane-wide knob. `bin/run-build.sh` already unsets both at entry.

Proven by `tests/llm-runner-stage.bh-2581-test.sh`.
