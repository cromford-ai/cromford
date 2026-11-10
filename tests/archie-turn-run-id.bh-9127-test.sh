#!/bin/bash
# tests/archie-turn-run-id.bh-9127-test.sh — BH-9127: the turn's cost run id is
# the turn's own call's, never a child's.
#
# bin/orchestrate.sh sets COST_RUN_ID=staff-turn:<key> on every orc-monitor
# call, so the turn's cost rows join its row on /staff. An Archie turn also
# starts builds (`setsid /root/harness/bin/run-build.sh ...`), and a build's
# calls take their run_id from the build dir their output lands in, the unit
# bin/cost-rollup.sh joins to a PR. bin/agent-call.sh reads COST_RUN_ID first,
# so an inherited staff-turn id would move a whole build's spend onto the turn
# and leave the PR with none (lead review lr-9148-d1713fa5dd6a).
#
# WHAT RUNS. The real bin/agent-call.sh and the real bin/claude-cost.sh, on a
# scratch harness, the way tests/llm-lane-id.bh-2303-test.sh runs them. The
# vendor CLIs are PATH stubs: each records the COST_RUN_ID it was handed, and
# with CHILD_BUILD=1 starts a build's plan call through the real agent-call
# with its output in $T/builds/lproj-X-1/, inheriting the stub's environment
# as a real session's `setsid run-build.sh` does. No vendor, no network.
#
#   R1  agent-call path (the ladder rung, bin/orchestrate.sh's grok/codex turn)
#   R2  claude-cost path (the three direct claude turns)
#   each: the vendor CLI sees no COST_RUN_ID; the turn's own row carries
#   staff-turn:<key>; the build's row carries its build dir.
#   R3  with no child, the turn's row still carries staff-turn:<key> (the
#       un-export must not blank the turn's own tag).
#
# MUTANTS. Drop `export -n COST_RUN_ID` from bin/agent-call.sh -> R1 red.
# Drop it from bin/claude-cost.sh -> R2 red.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/archie-turn-run-id.bh-9127-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$T" lproj
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

mkdir -p "$T/logs" "$T/locks" "$T/flags" "$T/state" "$T/fakebin" "$T/bin" "$T/catalog" "$T/work" "$T/cfg"
model_routes_fixture "$T" || exit 1

for R in claude codex grok gemini; do
  cat > "$T/fakebin/$R" <<EOF
#!/bin/bash
printf '%s\n' "\${COST_RUN_ID-<unset>}" >> "\$SENTINEL_DIR/vendor-env-runid"
# CHILD_BUILD=1: this "session" starts a build's plan call, inheriting THIS
# process's env, with its output in a build dir.
if [ "\${CHILD_BUILD:-}" = 1 ]; then
  mkdir -p "\$SENTINEL_DIR/builds/lproj-X-1"
  env -u CHILD_BUILD \\
    bash "\$DIR_UNDER_TEST/bin/agent-call.sh" plan lproj claude-fable-5 60 "\$SENTINEL_DIR/builds/lproj-X-1/plan.txt" "build step" </dev/null >/dev/null 2>&1
  echo "\$?" > "\$SENTINEL_DIR/child-rc"
fi
cat >/dev/null 2>&1
printf '{"result":"ok","usage":{"input_tokens":10,"output_tokens":2},"total_cost_usd":0.01}\n'
EOF
  chmod +x "$T/fakebin/$R"
done
printf '#!/bin/bash\necho subscription\n' > "$T/fakebin/billing-mode.sh"; chmod +x "$T/fakebin/billing-mode.sh"
cp "$T/fakebin/billing-mode.sh" "$T/bin/billing-mode.sh"
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
chmod +x "$T/fakebin/timeout"
cat > "$T/bin/jobs-client.sh" <<'EOF'
#!/bin/bash
_jobs_req() {
  case "$2" in /api/metrics/llm-spend*) printf '{"usd":0,"calls":0,"refused":0}\n'; return 0 ;; esac
  return 1
}
EOF
printf '{ "version": 1, "lanes": [] }\n' > "$T/catalog/lanes.json"

wipe() {
  local p
  for p in vendor-env-runid child-rc out.txt logs/cost.csv; do scratch_rm "$T/$p" || exit 1; done
  scratch_rm "$T/builds" || exit 1
  scratch_rm "$T/state/lane-gate" || exit 1
  : > "$T/logs/ALERTS.log"
}
# The shared environment of both paths. LLM_GATE_DISABLE: the gate is not the
# subject, and tests/llm-lane-id.bh-2303-test.sh covers it.
fx_env() {
  export SENTINEL_DIR="$T" PATH="$T/fakebin:$PATH" HARNESS="$T" HOME="$T" DIR_UNDER_TEST="$DIR" \
         LANE_REGISTRY="$T/catalog/lanes.json" CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json" \
         BEAT_LOG=/dev/null LLM_GATE_DISABLE=1 CLAUDE_CONFIG_DIR="$T/cfg"
}
# turn_agent_call <env...> — the turn as a ladder rung through the real agent-call.
turn_agent_call() {
  wipe
  ( fx_env
    "$@" bash "$DIR/bin/agent-call.sh" review lproj claude-fable-5 60 "$T/out.txt" "hello" </dev/null >/dev/null 2>&1 )
  echo $?
}
# turn_claude_cost <env...> — the turn as a direct claude call through the real claude-cost.
turn_claude_cost() {
  wipe
  ( fx_env; cd "$T/work" || exit 1
    "$@" bash "$DIR/bin/claude-cost.sh" -p --model claude-fable-5 "hello" </dev/null >/dev/null 2>&1 )
  echo $?
}
# run_id (column 23) of the newest row of one stage.
runid_of() { awk -F, -v s="$1" 'NR>1 && $4==s {print $23}' "$T/logs/cost.csv" 2>/dev/null | tail -1; }
KEY=staff-turn:archie-turn-1793926800-43

# ═════ R1: the agent-call path ═══════════════════════════════════════════════
RC=$(turn_agent_call env AGENT_CALL_LANE=orc-monitor COST_RUN_ID="$KEY" CHILD_BUILD=1)
eq R1_rc "$RC" 0
eq R1_vendor_env "$(head -1 "$T/vendor-env-runid" 2>/dev/null)" "<unset>"
eq R1_child_rc "$(cat "$T/child-rc" 2>/dev/null)" 0
eq R1_turn_row "$(runid_of review)" "$KEY"
eq R1_build_row "$(runid_of plan)" lproj-X-1

# ═════ R2: the claude-cost path ══════════════════════════════════════════════
RC=$(turn_claude_cost env AGENT_CALL_LANE=orc-monitor COST_STAGE=orchestrator COST_RUN_ID="$KEY" CHILD_BUILD=1)
eq R2_rc "$RC" 0
eq R2_vendor_env "$(head -1 "$T/vendor-env-runid" 2>/dev/null)" "<unset>"
eq R2_child_rc "$(cat "$T/child-rc" 2>/dev/null)" 0
eq R2_turn_row "$(runid_of orchestrator)" "$KEY"
eq R2_build_row "$(runid_of plan)" lproj-X-1

# ═════ R3: no child, the turn's own tag stays ════════════════════════════════
RC=$(turn_agent_call env AGENT_CALL_LANE=orc-monitor COST_RUN_ID="$KEY")
eq R3_agent_call_row "$RC/$(runid_of review)" "0/$KEY"
RC=$(turn_claude_cost env AGENT_CALL_LANE=orc-monitor COST_STAGE=orchestrator COST_RUN_ID="$KEY")
eq R3_claude_cost_row "$RC/$(runid_of orchestrator)" "0/$KEY"

echo "archie-turn-run-id.bh-9127: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
