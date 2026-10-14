# claude-cost.sh calls go through the lane gate and K3

Doc: LLM_CALL_SITES, CALL-GUARD

## What was wrong

`bin/claude-cost.sh` priced the raw-claude callers (the orchestrator's primary
turn, greenfield, box-chat's `-c` rung) and gated none of them. Setting
`LLM_LANE_ENABLED=0` on `orc-monitor` stopped the orchestrator's survival turn,
which goes through `bin/agent-call.sh`, and left the primary turn running and
billing. `catalog/llm-sites.json` said `gated: none` for all three.

## What changed

- `bin/claude-cost.sh` sources `bin/jobs-client.sh`, `bin/lib/llm-gate.sh` and
  `bin/lib/call-guard.sh` (sibling first, the same "allow" stubs as agent-call
  when a lib is missing) and applies the `lib.call-guard.*` settings rows.
- Before claude starts it runs `llm_gate_precall` and
  `llm_gate_runner_ok <stage> <project> claude` with stage `$COST_STAGE` and
  project `$COST_PROJECT`. The lane is `$AGENT_CALL_LANE`, else whatever the
  stage resolves to (`stage-chat`, `stage-gf-*` for box-chat and greenfield).
- It then claims a K3 slot when the guard enforces the stage. The fingerprint
  is `AGENT_CALL_FP`, else the lib's fallback over a sha256 of the caller's
  argv. A call whose prompt is on a stdin pipe or file and has no
  `AGENT_CALL_FP` is not claimed, and that skip is logged in
  `logs/claude-cost.log` when the stage is enforced. After the call it settles
  once: `ok`, or `empty` when the transcript says 0 output tokens, or `failed`.
  All three count as paid.
- A refusal from either check prints `AGENT_CALL_REFUSED llm-gate …` or
  `AGENT_CALL_REFUSED call-guard …` on stderr, appends a `logs/failovers.log`
  line, writes a zero-cost `row_source=refused` row and exits **74**. Nothing
  is spawned. Every other exit code is still claude's.
- `AGENT_CALL_LANE`, `AGENT_CALL_FP`, `AGENT_CALL_GUARD_STAGE`,
  `AGENT_CALL_TICKET` and `AGENT_CALL_GUARD_FORCE` are `export -n`'d, so they
  never reach the claude session.
- `bin/orchestrate.sh` `run_turn()` passes `AGENT_CALL_LANE=orc-monitor` on all
  three claude-cost calls.
- `catalog/lanes.d/orc-monitor.json` registers `LLM_LANE_ENABLED`,
  `LLM_RUNNER_ALLOWED` and `LLM_USD_CAP_DAY`, so `bin/harness-ctl.sh set
  orc-monitor LLM_LANE_ENABLED 0` is accepted.
- `catalog/llm-sites.json`: claude-cost, orchestrate-primary and greenfield are
  `gated: claude-cost`.

## Defaults

With no settings row nothing changes: the lane is enabled, every runner is
allowed and there's no daily cap. `CALL_GUARD_STAGES_DEFAULT` doesn't list
`orchestrator`, `chat` or `gf-*`, so K3 makes no claim for these callers until
someone writes a `lib.call-guard.call_guard_stages` row.

## Still ungated

A box with no `bin/lib/cost-row.sh` still execs claude directly. Without a
ledger writer a refusal couldn't leave its row.

## Proof

`tests/claude-cost-gate.bh-2534-test.sh`. Case 9 drives the real `run_turn()`
and claude ladder from `bin/orchestrate.sh` into the real wrapper.
