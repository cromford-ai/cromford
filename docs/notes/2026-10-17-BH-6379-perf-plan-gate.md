# BH-6379 (BH-6372.1): the plan stage asks perf tickets for a target and a replay

Doc: RUN-BUILD-GRAPH

## What changed
- New `bin/lib/perf-plan-rule.sh`. It uses the BH-6378 contract `bin/lib/perf-ticket.sh` and does not change it.
  - `pt_plan_rule` adds one paragraph to the plan prompt when `pt_classify` says the ticket is perf/cost.
  - `pt_build_perf` reads `$BUILD/ticket-meta.json` once and sets `PLAN_GATE_PERF`. If `ticket-body.md` is empty or absent, it writes `pt-ticket-body.md` and never overwrites `ticket-body.md`.
  - `pt_plan_check` is the gate check. `pt_repair_note` is the repair-pass sentence.
- `bin/lib/rb/plan.sh` runs `pt_build_perf` above the plan checkpoint, so a reused plan is gated too. It logs `plan: perf ticket (<evidence>)` to `pipeline.log`, passes `PLAN_GATE_PERF` to `bin/plan-gate.sh` in `PG_RUN`, and adds the rule to the plan prompt and the note to the repair prompt.
- `bin/plan-gate.sh` has a new block after the BH-5800 failure-mode block. It is active when `PLAN_GATE_PERF=1` or the plan has a `## Target metric` heading. It prints `  UNTRACED: outcome replay — <gap>` lines and `PLAN_OUTCOME_REPLAY: ok | missing | n/a`. A gap raises rc 0 to 2. rc 3 stays 3. `PLAN_TRACE:` stays the last line.
- New knob `OUTCOME_REPLAY_N` (int, default 50, 5..500) in `catalog/lanes.d/_lib.perf-ticket.json`. A settings row wins, then env, then 50. A bad value gives 50 and one stderr line.
- `prompts/plan-contract.md` §16 states the rule.

## Why
The #5354 family: a perf PR merged on a claim it never measured. A perf plan now names its target number and a replay over real inputs before any code is written.

## Kill path
`PLAN_GATE_ENFORCE=0` (existing) turns every plan-gate refusal, this one included, into a logged warning.

## Tests
`tests/plan-gate-outcome-replay.bh-6379-test.sh` (P1-P12, the real gate on mutations of `tests/fixtures/bh-6372/plan-perf-complete.md`) and `tests/perf-plan-rule.bh-6379-test.sh` (N1-N5, R1-R5, W1, W2).
