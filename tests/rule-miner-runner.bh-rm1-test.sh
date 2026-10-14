#!/bin/bash
# tests/rule-miner-runner.bh-rm1-test.sh — the weekly rule miner drafts on the
# RUNNER its lane names, not on whatever the hub's triage stage runner is.
#
# THE INCIDENT. bin/rule-miner.sh's drafting call is `agent-call.sh triage
# rule-miner "$MINER_MODEL" …`: the model comes from model_routes role
# `rule.miner`, but the RUNNER is the triage stage's, and the hub sets
# RUNNER_TRIAGE=grok. cost.csv 2026-08-31 → 2026-09-21: every rule-miner row is
# grok-4.6, never the claude model its route names. The first fix (#1768) was
# a RULE_MINER_RUNNERS allow-list knob. BH-1764 (#1823) replaced it with the
# stronger contract below: the call is its own stage `mine` and runs on the
# ROUTE's runner, pinned through AGENT_CALL_RUNNERS. A non-claude route is
# refused outright (tests/rule-miner-ceiling.bh-1749-test.sh case 6). No knob
# can hand the call back to the stage runner, so RULE_MINER_RUNNERS is retired.
#
# DRIVEN, NOT GREPPED: the real bin/rule-miner.sh runs past its gathering stage
# in a scratch checkout ($T/co) whose agent-call.sh is a recorder, against a
# scratch harness ($T/h) with one recurring-finding incident so the week is not
# empty. gh answers only the clone; nothing leaves the box.
#
#   1  with RUNNER_TRIAGE=grok, the drafting call still gets AGENT_CALL_RUNNERS=claude
#   2  a leftover RULE_MINER_RUNNERS= (empty) in env/global.env cannot reopen it
#   3  a leftover RULE_MINER_RUNNERS list is ignored as well: the route decides
#   4  the model argument is the model_routes value for rule.miner, the stage is
#      `mine` and the project is `rule-miner`
#   5  the retired knob is no longer registered in catalog/lanes.d/rule-miner.json
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-6052: the day stamp below is read by the code and again here; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 30 || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }
command -v jq >/dev/null 2>&1 || { echo "rule-miner-runner.bh-rm1-test: SKIPPED — jq missing"; exit 0; }

H="$T/h"; CO="$T/co"
mkdir -p "$H/logs" "$H/state" "$H/flags" "$H/env" "$H/locks" "$H/bin/lib" "$H/catalog" "$CO/bin" "$T/stub"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$H" || exit 1
: > "$H/fleet.conf"
cp "$DIR/bin/rule-miner.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/rule-miner-digest.sh" "$CO/bin/"
mkdir -p "$CO/bin/lib" && cp "$DIR/bin/lib/lane-switch.sh" "$DIR/bin/lib/lane-gate.sh" "$CO/bin/lib/"
# The lane's context ceiling (BH-1764 refuses the call without it).
cp "$DIR/catalog/context-budgets.json" "$H/catalog/"

# The recorder: one line per call — the allow-list as the child saw it (set or
# not), then the stage, project and model arguments.
cat > "$CO/bin/agent-call.sh" <<'SH'
#!/bin/bash
printf 'RUNNERS=%s\tSTAGE=%s\tPROJECT=%s\tMODEL=%s\n' \
  "${AGENT_CALL_RUNNERS-<unset>}" "$1" "$2" "$3" >> "$CALLS"
exit 0
SH
chmod +x "$CO/bin/"*.sh

printf '#!/bin/sh\nexit 0\n' > "$T/stub/flock"
# gh: the clone lands a build-discipline.md to number the next rule from.
cat > "$T/stub/gh" <<'SH'
#!/bin/bash
if [ "$1 $2" = "repo clone" ]; then
  mkdir -p "$4/prompts"; printf -- '- **D1 A rule.** Cite TK-1.\n' > "$4/prompts/build-discipline.md"; exit 0
fi
exit 1
SH
chmod +x "$T/stub/"*

# One recurring-finding family over PROMOTE_MIN, so the week has an incident.
TODAY=$(date -u +%Y-%m-%d)  # determinism: ok the miner's own 30-day window is wall-clock; a fixed date would age out of it
for k in 1 2 3; do
  printf '%s 12:00:00Z [x-os] ticket=TK-%s lens=general verdict=BLOCK rule=D1 family=aaaaaaaaaaaa :: same finding\n' \
    "$TODAY" "$k" >> "$H/logs/findings.log"
done

run() { # run [VAR=value ...] -> the one recorded call line (empty if none)
  : > "$T/calls"
  scratch_rm "$H/state/rule-mining"; mkdir -p "$H/state/rule-mining"
  env "$@" PATH="$T/stub:$PATH" HARNESS="$H" CALLS="$T/calls" \
    bash "$CO/bin/rule-miner.sh" >/dev/null 2>&1
  cat "$T/calls"
}
field() { printf '%s\n' "$1" | tr '\t' '\n' | sed -n "s/^$2=//p"; }

# 1. the hub's RUNNER_TRIAGE=grok does not reach the drafting call
: > "$H/env/global.env"
L=$(run -u RULE_MINER_RUNNERS RUNNER_TRIAGE=grok)
[ "$(printf '%s\n' "$L" | grep -c .)" = 1 ] && ok || bad "1 expected exactly one drafting call, got: '$L'"
eq "1 the drafting call is pinned to claude while RUNNER_TRIAGE=grok" "$(field "$L" RUNNERS)" "claude"

# 2. a leftover empty RULE_MINER_RUNNERS in env/global.env cannot reopen it
printf 'RULE_MINER_RUNNERS=\n' > "$H/env/global.env"
L=$(run -u RULE_MINER_RUNNERS RUNNER_TRIAGE=grok)
eq "2 an empty RULE_MINER_RUNNERS no longer hands the call to the stage runner" "$(field "$L" RUNNERS)" "claude"
: > "$H/env/global.env"

# 3. a leftover list is ignored too: the route's runner is the whole answer
L=$(run RULE_MINER_RUNNERS=claude,openrouter RUNNER_TRIAGE=grok)
eq "3 a RULE_MINER_RUNNERS list no longer widens the call" "$(field "$L" RUNNERS)" "claude"

# 4. the model is still the route's, and the call shape is unchanged
ROUTE=$(awk -F'\t' '$1==0{print $2}' "$H/state/model-routes/rule.miner.tsv" 2>/dev/null)
[ -n "$ROUTE" ] && ok || bad "4 fixture: no cached rule.miner route"
L=$(run -u RULE_MINER_RUNNERS)
eq "4 the model argument is the model_routes value" "$(field "$L" MODEL)" "$ROUTE"
eq "4 the call is its own stage" "$(field "$L" STAGE)" "mine"
eq "4 project unchanged" "$(field "$L" PROJECT)" "rule-miner"

# 5. retired: a registered knob nothing reads would be a lie on the settings page
K=$(jq -r '[.knobs[]|select(.env=="RULE_MINER_RUNNERS")]|length' "$DIR/catalog/lanes.d/rule-miner.json" 2>/dev/null)
eq "5 RULE_MINER_RUNNERS is no longer registered" "$K" "0"

echo "rule-miner-runner.bh-rm1-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
