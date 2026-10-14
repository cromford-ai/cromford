# claude-cost follow-ups: K3 on the raw-claude callers, real lanes for box-chat and greenfield, one refused row per turn

Doc: CALL-GUARD, LLM_CALL_SITES

## What was wrong

The review of #2597 (BH-2534) left three gaps on the callers of
`bin/claude-cost.sh`:

- K3 was wired but never enforced for the orchestrator, the chat pane or
  greenfield. None of their stages were in `CALL_GUARD_STAGES_DEFAULT`. On top
  of that, the orchestrator's fresh turn sends its prompt on stdin with no
  `AGENT_CALL_FP`, and claude-cost skips the claim for that shape.
- box-chat and greenfield resolved to synthetic `stage-chat` / `stage-gf-*`
  lanes. Neither `bin/harness-ctl.sh` nor the Settings page could set a knob
  on those lanes.
- A refused orchestrator turn wrote two refused rows, one per model in its
  ladder. With survival runners configured, a lane-wide refusal wrote one more
  row per survival runner.

## What changed

- **Fingerprints and guard families.** Each call site now names its work and
  its family:
  - `bin/orchestrate.sh`: `orc:c<command id>`, family `orchestrator`. With no
    command id, the fp is `orc:d<dedupe key>:<epoch>`, so K3 bounds only that
    turn's own ladder.
  - `bin/box-chat.sh`: `chat:<project>:c<command id>`, family `box-chat`. The
    `-c` rung, its no-conversation retry and the fallback rung all share it.
  - `bin/greenfield.sh`: `gf:<workspace sha 12>:<stage>:p<prompt sha 16>`,
    family `greenfield`.
- **Defaults** in `bin/lib/call-guard.sh` and `catalog/lanes.d/_lib.call-guard.json`:
  `orchestrator=6` (two models on up to three account rungs), `box-chat=3`,
  `greenfield=2`. The raw stage `chat` is still NOT guarded, because
  `bin/product-cmd.sh` shares it.
- **Lanes.** `catalog/lanes.d/box-chat.json` (scope project, cost_stage chat)
  and `catalog/lanes.d/greenfield.json` (scope hub, no cost stage) are wired
  lanes with `LLM_LANE_ENABLED`, `LLM_RUNNER_ALLOWED` and `LLM_USD_CAP_DAY`.
  - box-chat gates before its malformed-request reply. A switched-off pane
    still gets one `lane_off` reply.
  - greenfield gates before it ingests anything.
  - `catalog/llm-sites.json` names both lanes.
- **product-cmd** pins `AGENT_CALL_LANE=stage-chat` on its chat call. That is
  the lane it already resolved to, and without the pin the new box-chat lane
  (same stage) would capture it.
- **One refused row.**
  - `orc_model_ladder` stops at an rc 74 carrying `AGENT_CALL_REFUSED` instead
    of asking the next model.
  - A lane-wide refusal (`lane-disabled`, `usd-cap-day`) skips the survival
    runners, which would be refused on the same lane `orc-monitor`, and the
    bash floor says the lane refused the turn. `runner-not-allowed` and K3
    refusals still try survival.
  - box-chat skips its fallback rung on a lane-wide or K3-repeat refusal for
    the same reason.

## Operator step

A prod settings row `lib.call-guard.call_guard_stages` or
`lib.call-guard.call_guard_max_map` overrides these code defaults. If such a
row exists, append `orchestrator box-chat greenfield` (and
`orchestrator=6 box-chat=3 greenfield=2`) to it. Otherwise K3 stays off for
these families.

Pinned by `tests/claude-cost-followups.bh-2603-test.sh`, the updated case 9
of `tests/claude-cost-gate.bh-2534-test.sh`, and A1–A3 of
`tests/agent-call-call-guard.bh-2305-test.sh`.
