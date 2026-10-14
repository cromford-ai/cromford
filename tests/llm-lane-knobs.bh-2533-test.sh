#!/bin/bash
# tests/llm-lane-knobs.bh-2533-test.sh — BH-2579 (BH-2533.1): every lane an LLM
# site names carries the three llm-gate knobs, and a lane's cap binds only it.
#
# WHY. bin/lib/llm-gate.sh reads LLM_LANE_ENABLED / LLM_RUNNER_ALLOWED /
# LLM_USD_CAP_DAY per lane, but an operator can only set a knob the registry
# declares (bin/harness-ctl.sh set, the console Settings page). Seven lanes that
# call a model through bin/agent-call.sh had no knobs at all, so nobody could
# cap or switch them off without a code change.
#
#   1  ratchet: the lane set is DERIVED from catalog/llm-sites.json
#      (through_agent_call sites), never a hand list; each lane is in the
#      rendered registry with the three knobs at the canonical type/default,
#      read_in bin/lib/llm-gate.sh
#   2  the checker is live: a fixture registry missing lead-review's
#      LLM_USD_CAP_DAY, and a sites file naming an unregistered lane, both fail
#   3  isolation through the real bin/agent-call.sh: lead-review over its $1 cap
#      is refused (rc 74, vendor never ran, refused row stamped lead-review);
#      the other newly-knobbed lanes, same spend, run; LLM_GATE_DISABLE=1 on
#      lead-review runs (the detector is not vacuous)
# Run from anywhere: tests/llm-lane-knobs.bh-2533-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/rendered.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "FAIL: jq missing"; exit 1; }

unset AGENT_CALL_LANE LLM_LANE_ENABLED LLM_RUNNER_ALLOWED LLM_USD_CAP_DAY LLM_GATE_DISABLE \
      LANE_GATE_DISABLE JOBS_URL COST_STAGE COST_PROJECT

# check_knobs <registry.json> <llm-sites.json> — prints `<lane> <ENV>` for every
# missing or malformed knob (`<lane> NO-LANE` for a lane the registry lacks);
# non-zero when there is any.
check_knobs() {
  local out
  out=$(jq -rn --slurpfile reg "$1" --slurpfile sites "$2" '
    def want: [
      {env:"LLM_LANE_ENABLED",   type:"int",    default:1},
      {env:"LLM_RUNNER_ALLOWED", type:"string", default:""},
      {env:"LLM_USD_CAP_DAY",    type:"float",  default:0} ];
    ($reg[0].lanes // []) as $lanes
    | [$sites[0].sites[] | select(.through_agent_call == true) | .lane | select(. != null)] | unique | .[]
    | . as $l
    | ([$lanes[] | select(.id == $l)] | first) as $lane
    | if $lane == null then "\($l) NO-LANE"
      else want[] | . as $w
        | ([$lane.knobs[]? | select(.env == $w.env)] | first) as $k
        | select($k == null or $k.type != $w.type or $k.default != $w.default
                 or $k.read_in != "bin/lib/llm-gate.sh")
        | "\($l) \($w.env)"
      end') || { echo "check_knobs: jq failed"; return 2; }
  [ -z "$out" ] && return 0
  printf '%s\n' "$out"; return 1
}

# ── 1: ratchet over the real registry ────────────────────────────────────────
HARNESS_TEST_SANDBOX=1 bash "$DIR/bin/lanes-build.sh" --to "$T/lanes.json" >/dev/null 2>&1 \
  || { echo "FAIL: bin/lanes-build.sh --to failed"; exit 1; }
SITES="$DIR/catalog/llm-sites.json"
LANES=$(jq -r '[.sites[] | select(.through_agent_call == true) | .lane | select(. != null)] | unique | .[]' "$SITES")
N=$(printf '%s\n' "$LANES" | grep -c .)
[ "$N" -ge 20 ] && ok || bad "1: only $N lanes derived from llm-sites.json — the ratchet would be vacuous"
for l in lead-review claude-auth-check; do
  grep -qx "$l" <<<"$LANES" && ok || bad "1: derived lane set lacks $l"
done
if OUT=$(check_knobs "$T/lanes.json" "$SITES"); then ok
else while IFS= read -r line; do bad "1: missing/malformed knob: $line"; done <<< "$OUT"; fi

# ── 2: the checker goes red on a missing knob and on an unregistered lane ───
jq '(.lanes[] | select(.id == "lead-review") | .knobs) |= map(select(.env != "LLM_USD_CAP_DAY"))' \
  "$T/lanes.json" > "$T/lanes-mut.json"
# the fixture needs lead-review's other two knobs present for the name check to be exact
jq '(.lanes[] | select(.id == "lead-review") | .knobs) += [
      {env:"LLM_LANE_ENABLED",type:"int",default:1,read_in:"bin/lib/llm-gate.sh"},
      {env:"LLM_RUNNER_ALLOWED",type:"string",default:"",read_in:"bin/lib/llm-gate.sh"}]' \
  "$T/lanes-mut.json" > "$T/lanes-mut2.json"
OUT=$(check_knobs "$T/lanes-mut2.json" "$SITES"); RC=$?
[ "$RC" -ne 0 ] && ok || bad "2: a registry without lead-review LLM_USD_CAP_DAY passed the checker"
grep -qx 'lead-review LLM_USD_CAP_DAY' <<<"$OUT" && ok \
  || bad "2: the checker did not name 'lead-review LLM_USD_CAP_DAY': $OUT"
jq '.sites += [{id:"ghost",lane:"ghost-lane",through_agent_call:true}]' "$SITES" > "$T/sites-ghost.json"
OUT=$(check_knobs "$T/lanes.json" "$T/sites-ghost.json"); RC=$?
[ "$RC" -ne 0 ] && grep -qx 'ghost-lane NO-LANE' <<<"$OUT" && ok \
  || bad "2: a site naming an unregistered lane passed the checker (rc $RC): $OUT"

# ── 3: isolation through the real bin/agent-call.sh ─────────────────────────
H="$T/h"
mkdir -p "$H/logs" "$H/locks" "$H/flags" "$H/state" "$H/fakebin" "$H/bin" "$H/catalog"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" lproj
model_routes_fixture "$H" || exit 1
cp "$T/lanes.json" "$H/catalog/lanes.json"
for R in claude codex grok gemini; do
  cat > "$H/fakebin/$R" <<EOF
#!/bin/bash
touch "\$SENTINEL_DIR/$R-ran"
printf '{"result":"ok","usage":{"input_tokens":10,"output_tokens":2},"total_cost_usd":0.01}\n'
EOF
  chmod +x "$H/fakebin/$R"
done
printf '#!/bin/bash\necho subscription\n' > "$H/bin/billing-mode.sh"; chmod +x "$H/bin/billing-mode.sh"
cp "$H/bin/billing-mode.sh" "$H/fakebin/billing-mode.sh"
cat > "$H/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
chmod +x "$H/fakebin/timeout"
cat > "$H/bin/jobs-client.sh" <<'EOF'
#!/bin/bash
_jobs_req() {
  case "$2" in
    /api/metrics/llm-spend*)
      local lane; lane=$(printf '%s' "$2" | sed -nE 's/.*[?&]lane=([^&]*).*/\1/p')
      cat "$SPEND_DIR/spend-$lane.json" 2>/dev/null || printf '{"usd":0,"calls":0,"refused":0}\n'
      return 0 ;;
  esac
  return 1
}
EOF
# setting <key> <value> — one settings row, as the worker's cache holds it.
setting() {
  local f="$H/state/settings-cache.json"
  [ -s "$f" ] || printf '{"fetched_at":%s,"values":{},"seeded":{}}' "$(date -u +%s)" > "$f"
  jq --arg k "$1" --arg v "$2" '.values[$k]=$v' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}
setting lane.lead-review.llm_usd_cap_day 1
for l in $LANES; do printf '{"usd":5,"calls":20,"refused":0}\n' > "$H/spend-$l.json"; done

# call <lane> <stage> [env...] — the real agent-call; echoes rc
call() {
  local lane=$1 stage=$2; shift 2
  rm -f "$H"/*-ran "$H/out.txt" "$H/logs/cost.csv"; scratch_rm "$H/state/lane-gate"
  ( export SENTINEL_DIR="$H" PATH="$H/fakebin:$PATH" HARNESS="$H" HOME="$H" SPEND_DIR="$H" \
           LANE_REGISTRY="$H/catalog/lanes.json" CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json" \
           BEAT_LOG=/dev/null
    env AGENT_CALL_LANE="$lane" "$@" bash "$DIR/bin/agent-call.sh" "$stage" lproj claude-fable-5 60 "$H/out.txt" "hello" >/dev/null 2>&1 )
  echo $?
}
ran() { [ -f "$H/claude-ran" ]; }
last() { tail -1 "$H/logs/cost.csv" 2>/dev/null | awk -F, -v c="$1" '{print $c}'; }

RC=$(call lead-review lead-review)
[ "$RC" = 74 ] && ok || bad "3: lead-review over its \$1 cap exited $RC, not 74"
ran && bad "3: lead-review's vendor ran past its cap" || ok
[ "$(last 18)" = refused ] && ok || bad "3: last cost row is not row_source=refused: $(tail -1 "$H/logs/cost.csv" 2>/dev/null)"
case "$(last 24)" in refused:usd-cap-day*) ok ;; *) bad "3: refused note does not start refused:usd-cap-day: $(last 24)" ;; esac
[ "$(last 25)" = lead-review ] && ok || bad "3: refused row lane_id is '$(last 25)', not lead-review"

for pair in rule-miner:mine review-rescue:review prompt-eval:eval cost-rollup:review \
            prebuild-repro:repro claude-auth-check:probe; do
  RC=$(call "${pair%%:*}" "${pair#*:}")
  [ "$RC" = 0 ] && ran && ok || bad "3: ${pair%%:*} was refused on lead-review's cap (rc $RC)"
done

RC=$(call lead-review lead-review LLM_GATE_DISABLE=1)
[ "$RC" = 0 ] && ran && ok || bad "3: LLM_GATE_DISABLE=1 on lead-review did not run the vendor (rc $RC)"

echo "llm-lane-knobs.bh-2533: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
