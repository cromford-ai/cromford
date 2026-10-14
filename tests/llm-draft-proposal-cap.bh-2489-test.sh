#!/bin/bash
# tests/llm-draft-proposal-cap.bh-2489-test.sh — BH-2489. bin/run-product.sh
# exports AGENT_CALL_LANE=run-product and runs bin/draft-proposal.sh as a child,
# so the child's `agent-call.sh prd …` and `agent-call.sh mockup …` rows are
# stamped lane_id=run-product. Before this ticket run-product registered only
# map/signals/ideate/synth, so _llm_lane_stages never read prd or mockup spend
# and run-product's daily cap never counted what its own drafts cost.
#
# Drives llm_gate_precall (what bin/agent-call.sh calls before every rung)
# against the registry bin/lanes-build.sh renders from catalog/lanes.d, with the
# worker's spend endpoint stubbed at `_jobs_req`, and the stage ratchet's
# `stats.cost_stage_via` declaration against fixtures.
#
#   bash tests/llm-draft-proposal-cap.bh-2489-test.sh          exit 0 = pass
# As root next to a live harness: HARNESS_TEST_SANDBOX=1 bash tests/…
# BH2489_RED=1 renders origin/main's catalog/lanes.d/run-product.json instead
# (the red proof: C1 and C2 must fail there).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

cp -r "$DIR/catalog" "$T/"
if [ "${BH2489_RED:-0}" = 1 ]; then
  git -C "$DIR" show origin/main:catalog/lanes.d/run-product.json > "$T/catalog/lanes.d/run-product.json" \
    || { echo "FAIL: BH2489_RED=1 but origin/main:catalog/lanes.d/run-product.json is unreadable"; exit 1; }
fi
HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --root "$T" --write >/dev/null 2>&1 \
  || { echo "FAIL: bin/lanes-build.sh could not render the registry into $T"; exit 1; }
REG="$T/catalog/lanes.json"
mkdir -p "$T/h/state" "$T/h/logs"

PINNED=1789000000   # determinism: ok a fixed epoch, the only time this file knows

# gate <stage> <project> [NAME=value ...] — llm_gate_precall in a clean shell;
# prints "<rc>|<LLM_GATE_REASON>". The stub answers $6 for exactly the query
# suffix in $HOT ("stage=<s>&…&lane=<l>" matched as stage + lane) and $0 for
# every other spend read, and logs each request path to $T/req.log.
gate() {
  local st="$1" pj="$2"; shift 2
  env -i PATH="$PATH" HOME="$T" HARNESS="$T/h" LANE_REGISTRY="$REG" \
      LANE_GATE_NOW="$PINNED" LLM_GATE_NOW="$PINNED" REQ_LOG="$T/req.log" \
      LIB="$DIR/bin/lib/llm-gate.sh" "$@" \
    bash -c '
      _jobs_req() {
        printf "%s %s\n" "$1" "$2" >> "$REQ_LOG"
        case "$2" in
          /api/metrics/llm-spend*)
            s=${2#*stage=}; s=${s%%&*}
            l=""; case "$2" in *"&lane="*) l=${2##*&lane=}; l=${l%%&*} ;; esac
            if [ "$s" = "${HOT_STAGE:-}" ] && [ "$l" = "${HOT_LANE:-}" ]; then
              printf "{\"usd\":6}"
            else
              printf "{\"usd\":0}"
            fi
            return 0 ;;
        esac
        return 1
      }
      . "$LIB"
      llm_gate_precall "$0" "$1"; rc=$?
      printf "%s|%s" "$rc" "$LLM_GATE_REASON"' "$st" "$pj"
}
cap() { # cap <lane> <usd> — a fresh settings cache holding exactly that one row
  jq -nc --argjson f "$PINNED" --arg k "lane.$1.llm_usd_cap_day" --arg v "$2" \
    '{fetched_at:$f, values:{($k):$v}}' > "$T/h/state/settings-cache.json"
}

# ── C1: run-product's own draft (stage prd, lane run-product) is capped ──────
rm -f "$T/req.log"; cap run-product 5
R=$(gate prd project-4 AGENT_CALL_LANE=run-product HOT_STAGE=prd HOT_LANE=run-product)
case "$R" in 2\|*usd-cap-day*spent=\$6*cap=\$5*lane=run-product*) ok ;;
  *) bad "C1: \$6 of run-product prd spend against its \$5 cap was not refused: '$R'" ;; esac

# ── C2: the cap read every one of run-product's six stages, lane-scoped ──────
for s in map signals ideate synth prd mockup; do
  n=$(grep -c "llm-spend?stage=$s&.*&lane=run-product\$" "$T/req.log" 2>/dev/null); n=${n:-0}
  [ "$n" = 1 ] && ok || bad "C2: expected one lane=run-product spend read for stage $s, saw $n: $(cat "$T/req.log" 2>/dev/null)"
done
# ...and a mockup call is measured against the same six-stage budget.
rm -f "$T/req.log"
R=$(gate mockup project-4 AGENT_CALL_LANE=run-product HOT_STAGE=prd HOT_LANE=run-product)
case "$R" in 2\|*spent=\$6*lane=run-product*) ok ;;
  *) bad "C2: a run-product mockup call did not count the lane's \$6 prd spend: '$R'" ;; esac

# ── C3: another lane's prd spend is never run-product's ──────────────────────
rm -f "$T/req.log"; cap run-product 5
R=$(gate map project-4 AGENT_CALL_LANE=run-product HOT_STAGE=prd HOT_LANE=review-prs)
[ "${R%%|*}" = 0 ] && ok || bad "C3: \$6 of review-prs prd spend refused a run-product call: '$R'"
grep -q 'lane=review-prs' "$T/req.log" 2>/dev/null \
  && bad "C3: run-product's cap read review-prs' spend: $(cat "$T/req.log")" || ok

# ── C4: no cap (0 = unlimited) refuses nothing ───────────────────────────────
rm -f "$T/req.log"; cap run-product 0
R=$(gate prd project-4 AGENT_CALL_LANE=run-product HOT_STAGE=prd HOT_LANE=run-product)
[ "${R%%|*}" = 0 ] && ok || bad "C4: LLM_USD_CAP_DAY=0 refused a prd call: '$R'"

# ── C5: the ratchet follows a DECLARED helper, and refuses a bad declaration ─
CHK="$DIR/tests/lib/lane-stage-check.py"
fixture() { # fixture <dir> <lane json> — a root with bin/lane.sh calling stage `a`
  mkdir -p "$1/bin" "$1/lanes.d"
  printf '#!/bin/bash\n"$HARNESS/bin/agent-call.sh" a p m 60 out prompt\n' > "$1/bin/lane.sh"
  printf '#!/bin/bash\n"$HARNESS/bin/agent-call.sh" x p m 60 out prompt\n' > "$1/bin/helper.sh"
  printf '%s\n' "$2" > "$1/lanes.d/fx.json"
}
F="$T/c5-missing"
fixture "$F" '{"id":"fx","script":"bin/lane.sh","stats":{"cost_stage":["a"],"cost_stage_via":["bin/nope.sh"]}}'
OUT=$(python3 "$CHK" "$F" "$F/lanes.d" 2>&1); rc=$?
{ [ "$rc" -ne 0 ] && grep -q '^FAIL: .*bin/nope.sh' <<<"$OUT"; } && ok \
  || bad "C5: a cost_stage_via naming a missing script was not a FAIL (rc=$rc): $OUT"
F="$T/c5-unreg"
fixture "$F" '{"id":"fx","script":"bin/lane.sh","stats":{"cost_stage":["a"],"cost_stage_via":["bin/helper.sh"]}}'
OUT=$(python3 "$CHK" "$F" "$F/lanes.d" 2>&1); rc=$?
{ [ "$rc" -ne 0 ] && grep -q '^FAIL: lane fx registers cost_stage \[a\] .*\[a,x\]' <<<"$OUT"; } && ok \
  || bad "C5: a helper calling unregistered stage x was not a FAIL (rc=$rc): $OUT"
F="$T/c5-good"
fixture "$F" '{"id":"fx","script":"bin/lane.sh","stats":{"cost_stage":["a","x"],"cost_stage_via":["bin/helper.sh"]}}'
OUT=$(python3 "$CHK" "$F" "$F/lanes.d" 2>&1); rc=$?
{ [ "$rc" -eq 0 ] && grep -q '^LANE fx registered=a,x called=a,x sites=2$' <<<"$OUT"; } && ok \
  || bad "C5: a lane registering its declared helper's stage was not accepted (rc=$rc): $OUT"
# Undeclared, the helper's stage is not the lane's: registering x is a FAIL.
F="$T/c5-undeclared"
fixture "$F" '{"id":"fx","script":"bin/lane.sh","stats":{"cost_stage":["a","x"]}}'
OUT=$(python3 "$CHK" "$F" "$F/lanes.d" 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok || bad "C5: an undeclared helper's stage was followed anyway (rc=$rc): $OUT"

echo "llm-draft-proposal-cap: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
