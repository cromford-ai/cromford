# Build calls bind the fly-pool lane (BH-2533 part 1, BH-2578)

Doc: LLM_CALL_SITES, LANES

## What was wrong

Every run-build model call goes through one site, `CC()` in
`bin/lib/rb/plan.sh`. `bin/run-build.sh` drops an inherited `AGENT_CALL_LANE`
at entry (BH-2303), so a build call named no lane at all.
`bin/lib/llm-gate.sh` then resolved it to a synthetic `stage-<stage>` lane, and
any knob registered on `fly-pool` bound nothing. That is the BH-1132 dead-knob
shape. It is gap C2 of the #2533 goal-gap audit.

## The split

#2533 lands in four parts. Part 1 (BH-2578, this note) is the contract the
other three build on: build calls name `fly-pool`, and `fly-pool` carries the
three lane-wide LLM knobs. Parts 2 to 4 are the per-stage knobs and the ratchet.
They are sibling children of #2533 and are not in this change; they record
themselves in later notes.

## What changed in part 1

- `CC()` puts `AGENT_CALL_LANE=fly-pool` on the env prefix of its one
  `bin/agent-call.sh` line. It is a command prefix, not an export, so
  `bin/run-decompose.sh` and `bin/prebuild-repro.sh`, launched from the same
  file, keep their own lane.
- `bin/run-build.sh` also unsets `LLM_LANE_ENABLED`, `LLM_RUNNER_ALLOWED`,
  `LLM_USD_CAP_DAY` and every `LLM_RUNNER_ALLOWED_*` at entry, right after the
  `AGENT_CALL_LANE` unset. A launching lane that exported its own caps through
  `lane_env_apply` (blocked-resolver's rebuild) would otherwise have them read
  as fly-pool's env fallback. `env/global.env` is sourced later in the same
  script, so a box-wide value there still applies, now to `fly-pool` rather
  than to a `stage-*` lane.
- `catalog/llm-sites.json` site `rb-plan` names `"lane": "fly-pool"`. No other
  site changed.
- `catalog/lanes.d/fly-pool.json` gains `LLM_LANE_ENABLED` (1),
  `LLM_RUNNER_ALLOWED` ("") and `LLM_USD_CAP_DAY` (0), same type and bounds as
  `review-autopilot`, `read_in: bin/lib/llm-gate.sh`. At those defaults nothing
  a build does changes.

## What the cap measures

`stats.cost_stage` stays `execute`. So `LLM_USD_CAP_DAY` on `fly-pool` sums the
day's `execute`-stage spend stamped `fly-pool`, which is where the metered
fallback money is. Plan, review, fix and qa spend is not in that sum. Once the
cap is hit, the gate refuses those stages too, because they all name the same
lane.

A lane-less call outside a build is unchanged: a `fix` from `bin/lander.sh`
still resolves `stage-fix`.

## Proof

`tests/llm-build-lane.bh-2578-test.sh` drives the real `CC()` against a fake
`bin/agent-call.sh`, evaluates the real head of `bin/run-build.sh` with the caps
inherited, and reads the rendered registry.
