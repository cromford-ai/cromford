#!/bin/bash
# tests/pm-signals.bh-7258-test.sh — BH-7258 (BH-7244 slice 1): the PM agent's
# data-signals file and its path into the run-product SIGNALS stage.
#
#   S1-S8  bin/pm-signals.sh: the snapshot file, the registry load order, the
#          error row for a failed adapter, the hash, usage and read-only
#   A1-A4  bin/pm-signals.d/common-alerts.sh (pms_alerts): the 7d/30d counts
#   R1-R6  the real bin/run-product.sh in a scratch harness (stub agent-call
#          that records each stage and prompt): DATA_SIGNALS=, data_evidence=,
#          the fail-open path, the two seams
#   P1     prompts/product-stages/signals.md source 5
#
# The clock is pinned: NOW below is passed as PM_SIGNALS_NOW, and every
# fixture timestamp is computed from it.
#
# Run from anywhere: tests/pm-signals.bh-7258-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-6052: run-product's CYCLE_DIR is the UTC day, read by the code and again here; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 60 || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }
unset HARNESS_SECRET JOBS_URL JOBS_BOX JOBS_ALERT PM_SIGNALS_DIR PM_SIGNALS_ADAPTER_TIMEOUT_S

RUNNER="$DIR/bin/pm-signals.sh"
ADAPTER="$DIR/bin/pm-signals.d/common-alerts.sh"
CAP_LIB="$DIR/bin/lib/product-run-cap.sh"
LAND_LIB="$DIR/bin/lib/pm-ideas-land.sh"
PROMPT="$DIR/prompts/product-stages/signals.md"

NOW=1791979200   # 2026-10-14 12:00:00Z
ts() { date -u -d "@$((NOW - $1))" '+%Y-%m-%d %H:%M:%SZ'; }
ts_iso() { date -u -d "@$((NOW - $1))" '+%Y-%m-%dT%H:%M:%SZ'; }

# pms <harness> <project> <out> [env...] — the runner on a pinned clock.
pms() {
  local h=$1 p=$2 o=$3; shift 3
  env HARNESS="$h" PM_SIGNALS_NOW="$NOW" "$@" bash "$RUNNER" "$p" "$o" 2>>"$T/pms.err"
}
val() { jq -r --arg i "$2" '.evidence[] | select(.id == $i) | .value' "$1" 2>/dev/null; }
st()  { jq -r --arg i "$2" '.evidence[] | select(.id == $i) | .status' "$1" 2>/dev/null; }

# ════════════════════════════════════════════════════════════════════════════
# S1 / A1-A3 — the real registry on a fixture ALERTS.log
# ════════════════════════════════════════════════════════════════════════════
HA="$T/ha"; mkdir -p "$HA/logs"
{
  echo "$(ts 3600) [proj] one hour ago"
  echo "$(ts $((6*86400 + 23*3600))) [proj] the 7d edge, inside"
  echo "$(ts_iso 7200) [proj] an ISO T stamp"
  echo "$(ts $((7*86400 + 60))) [proj] the 7d edge, outside (30d only)"
  echo "$(ts $((20*86400))) [proj] twenty days ago"
  echo "$(ts $((31*86400))) [proj] thirty-one days ago"
  echo "$(ts 600) [proj-x] another project"
  echo "$(ts 600) proj with no brackets"
  echo "no timestamp [proj] here"
  echo "$(date -u -d "@$((NOW + 3600))" '+%Y-%m-%d %H:%M:%SZ') [proj] in the future"
} > "$HA/logs/ALERTS.log"
O1="$T/s1.json"
pms "$HA" proj "$O1"; RC=$?
[ "$RC" = 0 ] && ok || bad "S1: the runner exits 0 (rc=$RC)"
[ "$(val "$O1" alerts.7d)" = 3 ] && ok || bad "S1/A1/A2: alerts.7d = 3 (got '$(val "$O1" alerts.7d)'): $(cat "$O1" 2>/dev/null)"
[ "$(val "$O1" alerts.30d)" = 5 ] && ok || bad "A1/A3: alerts.30d = 7d hits + 8-30d hits = 5 (got '$(val "$O1" alerts.30d)')"
jq -e '.evidence | length > 0' "$O1" >/dev/null 2>&1 && jq -e '.evidence[] | .id and .status' "$O1" >/dev/null 2>&1 && ok \
  || bad "S1: every evidence row has id and status"
jq -e '(.snapshot_hash | test("^[0-9a-f]{64}$")) and .generated_at == "2026-10-14T12:00:00Z"' "$O1" >/dev/null 2>&1 && ok \
  || bad "S1: snapshot_hash is sha256 hex and generated_at is the pinned clock: $(jq -c '{snapshot_hash,generated_at}' "$O1" 2>/dev/null)"
[ "$(jq -c '[.evidence[].id]' "$O1" 2>/dev/null)" = '["alerts.30d","alerts.7d"]' ] && ok \
  || bad "S1: the rows are sorted by id (got $(jq -c '[.evidence[].id]' "$O1" 2>/dev/null))"
jq -e '.evidence[] | select(.id == "alerts.7d") | .source == "alerts" and .metric == "alert_lines" and .window == "7d" and .link == "logs/ALERTS.log" and .status == "ok"' "$O1" >/dev/null 2>&1 && ok \
  || bad "S1: the alerts.7d row carries source/metric/window/link/status"

# A4 — no ALERTS.log: not-configured, value null (never a zero).
HN="$T/hn"; mkdir -p "$HN/logs"
pms "$HN" proj "$T/a4.json"; RC=$?
[ "$RC" = 0 ] && [ "$(jq -c '[.evidence[] | [.id, .status, .value]]' "$T/a4.json" 2>/dev/null)" = '[["alerts.30d","not-configured",null],["alerts.7d","not-configured",null]]' ] && ok \
  || bad "A4: no ALERTS.log gives 2 not-configured rows with value null (rc=$RC): $(cat "$T/a4.json" 2>/dev/null)"

# ════════════════════════════════════════════════════════════════════════════
# S4 — the hash covers the evidence only
# ════════════════════════════════════════════════════════════════════════════
pms "$HA" proj "$T/s4a.json"
PM_SIGNALS_NOW_OTHER=$((NOW + 5))
env HARNESS="$HA" PM_SIGNALS_NOW="$PM_SIGNALS_NOW_OTHER" bash "$RUNNER" proj "$T/s4b.json"
H1=$(jq -r .snapshot_hash "$T/s4a.json" 2>/dev/null); H2=$(jq -r .snapshot_hash "$T/s4b.json" 2>/dev/null)
G1=$(jq -r .generated_at "$T/s4a.json" 2>/dev/null); G2=$(jq -r .generated_at "$T/s4b.json" 2>/dev/null)
[ -n "$H1" ] && [ "$H1" != null ] && [ "$H1" = "$H2" ] && [ "$G1" != "$G2" ] && ok \
  || bad "S4: two runs on the same inputs give one hash ($H1 / $H2; generated_at $G1 / $G2)"
echo "$(ts 60) [proj] one more" >> "$HA/logs/ALERTS.log"
pms "$HA" proj "$T/s4c.json"
H3=$(jq -r .snapshot_hash "$T/s4c.json" 2>/dev/null)
[ -n "$H3" ] && [ "$H3" != "$H1" ] && ok || bad "S4: a changed fixture line changes the hash ($H1 / $H3)"

# ════════════════════════════════════════════════════════════════════════════
# S2 / S3 / S5 / S6 — a fixture registry
# ════════════════════════════════════════════════════════════════════════════
REG="$T/reg"; mkdir -p "$REG"
cp "$ADAPTER" "$REG/common-alerts.sh"
cat > "$REG/common-zz.sh" <<'EOF'
pms_zz() { jq -nc --arg p "$1" '{id:"zz.one",source:"zz",metric:"m",value:1,window:"",link:"",status:"ok",project:$p}'; }
EOF
cat > "$REG/proj.sh" <<'EOF'
pms_proj() { jq -nc '{id:"proj.one",source:"proj",metric:"m",value:1,window:"",link:"",status:"ok"}'; }
EOF
cat > "$REG/other.sh" <<'EOF'
pms_other() { jq -nc '{id:"other.one",source:"other",metric:"m",value:1,window:"",link:"",status:"ok"}'; }
EOF
pms "$HA" proj "$T/s2.json" PM_SIGNALS_DIR="$REG"; RC=$?
[ "$RC" = 0 ] && [ "$(jq -c '[.evidence[].id]' "$T/s2.json" 2>/dev/null)" = '["alerts.30d","alerts.7d","proj.one","zz.one"]' ] && ok \
  || bad "S2: common-*.sh then <project>.sh are loaded, other projects are not (rc=$RC): $(jq -c '[.evidence[].id]' "$T/s2.json" 2>/dev/null)"
[ "$(jq -r '.evidence[] | select(.id == "zz.one") | .project' "$T/s2.json" 2>/dev/null)" = proj ] && ok \
  || bad "S2: the adapter function gets the project as \$1"
[ "$(cd "$DIR/bin/pm-signals.d" && ls)" = common-alerts.sh ] && ok \
  || bad "S2: the real registry holds common-alerts.sh only: $(cd "$DIR/bin/pm-signals.d" 2>/dev/null && ls | tr '\n' ' ')"

# S3 — an adapter that exits 1: one error row, the others kept, rc 0.
REG3="$T/reg3"; mkdir -p "$REG3"; cp "$ADAPTER" "$REG3/common-alerts.sh"
printf 'pms_fail() { echo "{\\"id\\":\\"fail.partial\\",\\"source\\":\\"fail\\",\\"status\\":\\"ok\\"}"; return 1; }\n' > "$REG3/common-fail.sh"
pms "$HA" proj "$T/s3.json" PM_SIGNALS_DIR="$REG3"; RC=$?
[ "$RC" = 0 ] && ok || bad "S3: a failed adapter leaves the runner rc 0 (rc=$RC)"
[ "$(jq -c '[.evidence[] | select(.status == "error") | [.id, .source, .metric, .value, .link]]' "$T/s3.json" 2>/dev/null)" = '[["adapter.fail","fail","adapter_rc",1,"bin/pm-signals.d/common-fail.sh"]]' ] && ok \
  || bad "S3: exactly one error row adapter.fail with rc 1: $(cat "$T/s3.json" 2>/dev/null)"
[ "$(jq '[.evidence[] | select(.id == "fail.partial")] | length' "$T/s3.json" 2>/dev/null)" = 0 ] && ok \
  || bad "S3: the failed adapter's own rows are dropped"
[ "$(val "$T/s3.json" alerts.7d)" = 4 ] && ok || bad "S3: the alerts rows are still present (alerts.7d=$(val "$T/s3.json" alerts.7d))"

# S5 — a non-JSON line, no pms_ function, two pms_ functions, a row without
# the string keys: one error row each.
REG5="$T/reg5"; mkdir -p "$REG5"; cp "$ADAPTER" "$REG5/common-alerts.sh"
printf 'pms_badjson() { echo "{\\"id\\":\\"b.1\\",\\"source\\":\\"b\\",\\"status\\":\\"ok\\"}"; echo "not json"; }\n' > "$REG5/common-badjson.sh"
printf 'helper() { :; }\n' > "$REG5/common-nofn.sh"
printf 'pms_a() { :; }\npms_b() { :; }\n' > "$REG5/common-twofn.sh"
printf 'pms_nokey() { echo "{\\"id\\":7,\\"source\\":\\"k\\",\\"status\\":\\"ok\\"}"; }\n' > "$REG5/common-nokey.sh"
printf 'pms_empty() { :; }\n' > "$REG5/common-empty.sh"
pms "$HA" proj "$T/s5.json" PM_SIGNALS_DIR="$REG5"; RC=$?
[ "$RC" = 0 ] && [ "$(jq -c '[.evidence[] | select(.status == "error") | .id]' "$T/s5.json" 2>/dev/null)" = '["adapter.badjson","adapter.nofn","adapter.nokey","adapter.twofn"]' ] && ok \
  || bad "S5: one error row per broken adapter, none for an empty one (rc=$RC): $(jq -c '[.evidence[] | [.id, .value]]' "$T/s5.json" 2>/dev/null)"
[ "$(jq -c '[.evidence[] | select(.id == "adapter.nofn" or .id == "adapter.twofn") | .value]' "$T/s5.json" 2>/dev/null)" = '[98,98]' ] && ok \
  || bad "S5: a file without exactly one pms_ function is rc 98"
[ "$(jq '[.evidence[] | select(.id == "b.1")] | length' "$T/s5.json" 2>/dev/null)" = 0 ] && ok \
  || bad "S5: the valid line of a file with a non-JSON line is dropped too"

# S6 — a slow adapter is killed at PM_SIGNALS_ADAPTER_TIMEOUT_S.
REG6="$T/reg6"; mkdir -p "$REG6"; cp "$ADAPTER" "$REG6/common-alerts.sh"
printf 'pms_slow() { while :; do :; done; }\n' > "$REG6/common-slow.sh"
T0=$(date +%s)
pms "$HA" proj "$T/s6.json" PM_SIGNALS_DIR="$REG6" PM_SIGNALS_ADAPTER_TIMEOUT_S=1; RC=$?
EL=$(( $(date +%s) - T0 ))
[ "$RC" = 0 ] && [ "$(st "$T/s6.json" adapter.slow)" = error ] && [ "$(val "$T/s6.json" adapter.slow)" = 124 ] && ok \
  || bad "S6: a timed-out adapter gives an error row with rc 124 (rc=$RC): $(cat "$T/s6.json" 2>/dev/null)"
[ "$EL" -lt 15 ] && ok || bad "S6: the runner does not wait for the killed adapter (${EL}s)"
[ "$(val "$T/s6.json" alerts.7d)" = 4 ] && ok || bad "S6: the alerts rows are kept next to a timed-out adapter"

# S7 — usage and an unwritable out dir.
pms "$HA" ../x "$T/s7.json"; RC=$?
[ "$RC" = 2 ] && [ ! -e "$T/s7.json" ] && ok || bad "S7: project ../x is rc 2 and writes nothing (rc=$RC)"
pms "$HA" .. "$T/s7.json"; RC=$?
[ "$RC" = 2 ] && [ ! -e "$T/s7.json" ] && ok || bad "S7: project .. is rc 2 (rc=$RC)"
env HARNESS="$HA" bash "$RUNNER" proj > /dev/null 2>&1; RC=$?
[ "$RC" = 2 ] && ok || bad "S7: one arg is rc 2 (rc=$RC)"
pms "$HA" proj "$T/no-such-dir/out.json" 2>/dev/null; RC=$?
[ "$RC" = 1 ] && [ ! -e "$T/no-such-dir" ] && ok || bad "S7: a missing out dir is rc 1 (rc=$RC)"
[ -z "$(find "$T" -maxdepth 1 -name 's1.json.tmp.*' 2>/dev/null)" ] && ok || bad "S7: no tmp file is left beside the out file"

# S8 — no model string and no write path in the runner or the registry.
if grep -rn 'claude-' "$RUNNER" "$DIR/bin/pm-signals.d/" >/dev/null 2>&1; then
  bad "S8: a claude- string in bin/pm-signals.sh or bin/pm-signals.d/: $(grep -rn 'claude-' "$RUNNER" "$DIR/bin/pm-signals.d/")"
elif [ -f "$RUNNER" ] && [ -f "$ADAPTER" ]; then ok
else bad "S8: bin/pm-signals.sh or bin/pm-signals.d/common-alerts.sh is missing"; fi
if grep -En 'agent-call|post-proposal|run-build|curl|(^|[^a-z_-])gh ' "$RUNNER" "$ADAPTER" >/dev/null 2>&1; then
  bad "S8: the runner or the adapter calls a model, a poster, a build or the network: $(grep -En 'agent-call|post-proposal|run-build|curl|(^|[^a-z_-])gh ' "$RUNNER" "$ADAPTER")"
else ok; fi

# ════════════════════════════════════════════════════════════════════════════
# T3 — the seams, as shipped
# ════════════════════════════════════════════════════════════════════════════
if bash -c '. "$1" && . "$2" && product_run_cap_check map && product_run_cap_check synth && pm_ideas_land p /tmp' _ "$CAP_LIB" "$LAND_LIB" 2>/dev/null; then ok
else bad "T3: the placeholder seams source and return 0"; fi
grep -q '^# Owner: BH-7244.5' "$CAP_LIB" 2>/dev/null && grep -q '^# Owner: BH-7244.3' "$LAND_LIB" 2>/dev/null && ok \
  || bad "T3: each seam carries its owner comment"

# ════════════════════════════════════════════════════════════════════════════
# R1-R6 — the real bin/run-product.sh
# ════════════════════════════════════════════════════════════════════════════
P=proj
H="$T/h"
mkdir -p "$H/bin/lib" "$H/env" "$H/state" "$H/logs" "$H/flags" "$H/prompts/product-stages" "$T/stub"
# Stubs first: scratch_install_closure keeps a file that is already there.
printf 'lane_model() { echo stub-model; }\n' > "$H/bin/lib/lane-model.sh"
: > "$H/bin/lib/gh-app-auth.sh"; : > "$H/bin/lib/gh-limit-logger.sh"
scratch_install_closure bin/run-product.sh "$H" > /dev/null || bad "setup: install the run-product closure"
# pm-signals is run, not sourced, so it is not in the closure.
mkdir -p "$H/bin/pm-signals.d"
[ -f "$RUNNER" ] && cp "$RUNNER" "$H/bin/pm-signals.sh"
[ -f "$ADAPTER" ] && cp "$ADAPTER" "$H/bin/pm-signals.d/"
for s in beat.sh; do printf '#!/bin/bash\nexit 0\n' > "$H/bin/$s"; done
cat > "$H/bin/draft-proposal.sh" <<EOF
#!/bin/bash
printf 'prd' > "\$2/prd.md"
exit 0
EOF
printf '#!/bin/bash\necho "\$2" >> "%s/post.log"\nexit 0\n' "$T" > "$H/bin/post-proposal.sh"
# agent-call <stage> <project> <model> <timeout> <outfile> <prompt>
cat > "$H/bin/agent-call.sh" <<EOF
#!/bin/bash
stage=\$1; prompt=\$6
echo "\$stage" >> "$T/stages.log"
printf '%s' "\$prompt" > "$T/prompt-\$stage.txt"
field() { printf '%s\n' "\$prompt" | sed -n "s/^\$1=\([^ ]*\).*/\1/p" | head -1; }
case "\$stage" in
  signals) printf '{"signals":[{"s":1}]}' > "\$(field SIGNALS_OUT)" ;;
  ideate)  cp "$T/ideas.json" "\$(field IDEAS_OUT)" ;;
esac
exit 0
EOF
chmod +x "$H"/bin/*.sh
for s in map signals ideate-dept synth; do echo "$s" > "$H/prompts/product-stages/$s.md"; done
echo 'ctx' > "$H/prompts/product-$P.md"
printf '#!/bin/bash\nexit 0\n' > "$T/stub/git"; chmod +x "$T/stub/git"
jq -n '{ideas:[{slug:"X",title:"T X",summary:"s",dus:"derisk",impact:10,confidence:10,effort:1},
               {slug:"W",title:"T W",summary:"s",dus:"derisk",impact:0.1,confidence:1,effort:1}]}' > "$T/ideas.json"
printf -- '---\ndepartments: [ops]\n---\n' > "$H/state/$P.company-map.md"
ALERTS_FIX="$(ts 3600) [proj] a fixture alert
$(ts 7200) [proj] another fixture alert
$(ts 600) [proj-x] not this project"

cycle() { echo "$H/products/$P/$(date -u +%Y-%m-%d)"; }
LOGF="$H/logs/$P.log"
reset() {
  scratch_rm "$H/products"; scratch_rm "$H/state/product-$P.ledger.json"
  scratch_rm "$T/stages.log"; scratch_rm "$T/land.log"; scratch_rm "$T/post.log"
  scratch_rm "$T/prompt-signals.txt"; scratch_rm "$T/prompt-ideate.txt"
  printf '%s\n' "$ALERTS_FIX" > "$H/logs/ALERTS.log"; : > "$LOGF"
}
# restore_seams — put the shipped seams back after a case stubbed or removed them.
restore_seams() {
  scratch_rm "$H/bin/lib/product-run-cap.sh"; scratch_rm "$H/bin/lib/pm-ideas-land.sh"
  scratch_install_closure bin/run-product.sh "$H" > /dev/null
}
RP_SAFE=0
grep -q '^HARNESS="${HARNESS:-/root/harness}"$' "$H/bin/run-product.sh" && RP_SAFE=1
runp() {
  [ "$RP_SAFE" = 1 ] || { echo "run-product.sh pins HARNESS=/root/harness; not executed" > "$T/out.txt"; return 99; }
  HARNESS="$H" PM_SIGNALS_NOW="$NOW" PATH="$T/stub:$PATH" bash "$H/bin/run-product.sh" "$P" > "$T/out.txt" 2>&1
}
summary() { grep 'product rc=0 :: product v2:' "$LOGF" | tail -1; }
stages() { tr '\n' ' ' < "$T/stages.log" 2>/dev/null; }

# R1 — the observable outcome.
reset
runp; RC1=$?
C=$(cycle)
[ "$RC1" = 0 ] && ok || bad "R1: run-product exits 0 (rc=$RC1): $(cat "$T/out.txt") $(tail -3 "$H/logs/ALERTS.log")"
[ "$(val "$C/data-signals.json" alerts.7d)" = 2 ] && ok \
  || bad "R1: \$CYCLE_DIR/data-signals.json carries alerts.7d=2: $(cat "$C/data-signals.json" 2>/dev/null)"
grep -qxF "DATA_SIGNALS=$C/data-signals.json   (read-only product data evidence; cite evidence_id)" "$T/prompt-signals.txt" 2>/dev/null && ok \
  || bad "R1: the SIGNALS prompt names DATA_SIGNALS=<that path>: $(grep DATA_SIGNALS "$T/prompt-signals.txt" 2>/dev/null)"
summary | grep -q ' signals=1 data_evidence=2 ideated=' && ok || bad "R1: the summary line shows data_evidence=2: $(summary)"
grep -q DATA_SIGNALS "$T/prompt-ideate.txt" 2>/dev/null && bad "R1: only the SIGNALS prompt gets DATA_SIGNALS" || ok
R1_STAGES=$(stages)
[ "$R1_STAGES" = "signals ideate " ] && ok || bad "R1: the stage sequence is signals ideate (got '$R1_STAGES')"
R1_SEL=$(jq '.selected | length' "$C/selected.json" 2>/dev/null)
[ "$R1_SEL" = 1 ] && ok || bad "R1: one idea is selected (got '$R1_SEL')"
R1_ALERTS=$(wc -l < "$H/logs/ALERTS.log")

# R2 — the runner fails: no DATA_SIGNALS=, one log line, data_evidence=0, rc unchanged.
reset
printf '#!/bin/bash\nexit 1\n' > "$H/bin/pm-signals.sh"; chmod +x "$H/bin/pm-signals.sh"
runp; RC=$?
[ "$RC" = "$RC1" ] && ok || bad "R2: a failed pm-signals leaves the rc as R1 ($RC vs $RC1): $(cat "$T/out.txt")"
grep -q 'DATA_SIGNALS=' "$T/prompt-signals.txt" 2>/dev/null && bad "R2: no DATA_SIGNALS= line when pm-signals fails" || ok
[ -s "$T/prompt-signals.txt" ] && ok || bad "R2: SIGNALS still runs"
[ "$(grep -c 'product: pm-signals failed or missing, SIGNALS runs without data evidence' "$LOGF")" = 1 ] && ok \
  || bad "R2: exactly one pm-signals failure line in the project log: $(cat "$LOGF")"
summary | grep -q ' data_evidence=0 ' && ok || bad "R2: the summary shows data_evidence=0: $(summary)"

# R3 — a stale same-day file is never cited; a missing runner is the same; ALERTS untouched.
reset
mkdir -p "$(cycle)"
printf '{"snapshot_hash":"x","generated_at":"x","evidence":[{"id":"alerts.7d","source":"alerts","status":"ok","value":9}]}' > "$(cycle)/data-signals.json"
runp; RC=$?
[ "$RC" = "$RC1" ] && ok || bad "R3: rc unchanged with a stale file and a failing runner ($RC)"
grep -q 'DATA_SIGNALS=' "$T/prompt-signals.txt" 2>/dev/null && bad "R3: the stale data-signals.json is cited" || ok
[ ! -e "$(cycle)/data-signals.json" ] && ok || bad "R3: the stale data-signals.json is removed"
[ "$(wc -l < "$H/logs/ALERTS.log")" = "$R1_ALERTS" ] && ! grep -q pm-signals "$H/logs/ALERTS.log" && ok \
  || bad "R3: a pm-signals failure adds no ALERTS line: $(cat "$H/logs/ALERTS.log")"
reset
rm -f "$H/bin/pm-signals.sh"
runp; RC=$?
[ "$RC" = "$RC1" ] && ! grep -q 'DATA_SIGNALS=' "$T/prompt-signals.txt" 2>/dev/null \
  && grep -q 'pm-signals failed or missing' "$LOGF" && ok \
  || bad "R3: a missing pm-signals.sh is one log line and no DATA_SIGNALS= (rc=$RC)"
[ -f "$RUNNER" ] && cp "$RUNNER" "$H/bin/pm-signals.sh"

# R4 — the cap seam ends the cycle with rc 0.
cap_stub() { printf 'product_run_cap_check() { [ "$1" != %s ]; }\n' "$1" > "$H/bin/lib/product-run-cap.sh"; }
reset; cap_stub signals
runp; RC=$?
[ "$RC" = 0 ] && [ "$(stages)" = "signals " ] && ok \
  || bad "R4: a cap after SIGNALS: IDEATE is not called, rc 0 (rc=$RC, stages '$(stages)')"
grep -q "\[$P\] product rc=0 :: run cap reached after signals, cycle ended data_evidence=2" "$LOGF" && ok \
  || bad "R4: one 'run cap reached after signals' line: $(cat "$LOGF")"
[ ! -e "$(cycle)/selected.json" ] && [ -z "$(summary)" ] && ok || bad "R4: no SELECT and no summary line after the cap"
reset; cap_stub map
runp; RC=$?
[ "$RC" = 0 ] && [ ! -s "$T/stages.log" ] && grep -q 'run cap reached after map, cycle ended data_evidence=0' "$LOGF" && ok \
  || bad "R4: a cap after MAP (fresh map): no SIGNALS, rc 0 (rc=$RC, stages '$(stages)'): $(cat "$LOGF")"
reset; cap_stub ideate
runp; RC=$?
[ "$RC" = 0 ] && [ "$(stages)" = "signals ideate " ] && [ ! -e "$(cycle)/ideas.json" ] && grep -q 'run cap reached after ideate' "$LOGF" && ok \
  || bad "R4: a cap after IDEATE: no SYNTH output, rc 0 (rc=$RC)"
reset; cap_stub synth
printf 'pm_ideas_land() { echo "$*" >> "%s/land.log"; }\n' "$T" > "$H/bin/lib/pm-ideas-land.sh"
runp; RC=$?
[ "$RC" = 0 ] && [ -e "$(cycle)/ideas.json" ] && [ ! -e "$(cycle)/selected.json" ] && grep -q 'run cap reached after synth' "$LOGF" && ok \
  || bad "R4: a cap after SYNTH: no SELECT, rc 0 (rc=$RC)"
[ "$(cat "$T/land.log" 2>/dev/null)" = "$P $(cycle)" ] && ok || bad "R4: pm_ideas_land runs before the synth cap: $(cat "$T/land.log" 2>/dev/null)"
restore_seams

# R5 — the placeholders change nothing: the same as a run with no seam files.
reset
runp; RC_A=$?; ST_A=$(stages); SEL_A=$(jq '.selected | length' "$(cycle)/selected.json" 2>/dev/null)
rm -f "$H/bin/lib/product-run-cap.sh" "$H/bin/lib/pm-ideas-land.sh"
reset
runp; RC_B=$?; ST_B=$(stages); SEL_B=$(jq '.selected | length' "$(cycle)/selected.json" 2>/dev/null)
[ "$RC_A/$ST_A/$SEL_A" = "$RC_B/$ST_B/$SEL_B" ] && [ "$RC_A/$ST_A/$SEL_A" = "$RC1/$R1_STAGES/$R1_SEL" ] && ok \
  || bad "R5: placeholder seams = no seam files = R1 ('$RC_A/$ST_A/$SEL_A' vs '$RC_B/$ST_B/$SEL_B' vs '$RC1/$R1_STAGES/$R1_SEL')"
summary | grep -q ' data_evidence=2 ' && ok || bad "R5: missing seam files are fail-open: $(summary) $(cat "$T/out.txt")"
restore_seams

# R6 — pm_ideas_land is called once with <project> <cycle_dir>; its rc is ignored.
reset
printf 'pm_ideas_land() { echo "$*" >> "%s/land.log"; return 1; }\n' "$T" > "$H/bin/lib/pm-ideas-land.sh"
runp; RC=$?
[ "$RC" = 0 ] && [ "$(cat "$T/land.log" 2>/dev/null)" = "$P $(cycle)" ] && ok \
  || bad "R6: pm_ideas_land called once with '$P $(cycle)' (rc=$RC): $(cat "$T/land.log" 2>/dev/null)"
[ "$(jq '.selected | length' "$(cycle)/selected.json" 2>/dev/null)" = 1 ] && [ -n "$(summary)" ] && ok \
  || bad "R6: the run continues to SELECT and the summary after a failed pm_ideas_land"
restore_seams

# R7 — no idea above the threshold: that log line carries data_evidence too.
reset
cp "$T/ideas.json" "$T/ideas.keep.json"
jq -n '{ideas:[{slug:"W",title:"T W",summary:"s",dus:"derisk",impact:0.1,confidence:1,effort:1}]}' > "$T/ideas.json"
runp; RC=$?
[ "$RC" = 0 ] && grep -q "\[$P\] product rc=0 :: ideated 1, none above threshold data_evidence=2$" "$LOGF" && ok \
  || bad "R7: the none-above-threshold line shows data_evidence=2 (rc=$RC): $(cat "$LOGF")"
mv "$T/ideas.keep.json" "$T/ideas.json"

# ════════════════════════════════════════════════════════════════════════════
# P1 — the SIGNALS prompt's source 5
# ════════════════════════════════════════════════════════════════════════════
grep -qF '**Product data**' "$PROMPT" && [ "$(grep -c 'evidence_id' "$PROMPT")" -ge 2 ] && grep -q 'not-configured' "$PROMPT" \
  && grep -qF 'No data claim without an evidence_id from $DATA_SIGNALS.' "$PROMPT" && ok \
  || bad "P1: signals.md has source 5 Product data, evidence_id, not-configured and the no-claim rule"

echo "pm-signals: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
