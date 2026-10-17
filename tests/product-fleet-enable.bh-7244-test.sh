#!/bin/bash
# tests/product-fleet-enable.bh-7244-test.sh — BH-7262 (BH-7244 slice 4): the
# product stage on for seven projects, and the per-run USD cap.
#
#   E1-E4  the context files, the weekly run-product line in each owning box's
#          rendered crontab, the registry renders, the boxes and the knob
#   C1-C3  product_run_cap_check: cap 0, cap 5 with 4.99, cap 5 with 5.00
#   C4     the real bin/run-product.sh in a scratch harness: a stub spend of
#          6.00 after SIGNALS with PRODUCT_RUN_USD_CAP=5 stops before IDEATE
#   C5-C7  an invalid cap, a bare source, the near misses and a stage sum
#
# Run from anywhere: tests/product-fleet-enable.bh-7244-test.sh   (exit 0 = pass)
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
unset HARNESS_SECRET JOBS_URL JOBS_BOX JOBS_ALERT PRODUCT_RUN_USD_CAP

CAP_LIB="$DIR/bin/lib/product-run-cap.sh"
LANE="$DIR/catalog/lanes.d/run-product.json"
PROJECTS="project-6-os project-5 project-2 project-4 project-3 project-9 project-8"
# shellcheck source=bin/lib/cron-lines.sh
. "$DIR/bin/lib/cron-lines.sh" || { echo "FAIL: source bin/lib/cron-lines.sh"; exit 1; }

# ════════════════════════════════════════════════════════════════════════════
# E1 — a context file for each of the 7 projects
# ════════════════════════════════════════════════════════════════════════════
for p in $PROJECTS; do
  if [ -s "$DIR/prompts/product-$p.md" ] && grep -q 'READ-ONLY' "$DIR/prompts/product-$p.md"; then ok
  else bad "E1: prompts/product-$p.md exists, is non-empty and carries READ-ONLY"; fi
done

# ════════════════════════════════════════════════════════════════════════════
# E2 / E4 — each owning box renders the weekly line; the registry names the box
# ════════════════════════════════════════════════════════════════════════════
for p in $PROJECTS; do
  BOXCOL=$(bash "$DIR/bin/fleet-conf.sh" "$p" box 2>/dev/null)
  OFF=$(bash "$DIR/bin/fleet-conf.sh" "$p" offset 2>/dev/null)
  BOX=$(cron_box_id_for "$BOXCOL")
  [ -n "$BOXCOL" ] && [ -n "$OFF" ] || { bad "E2: fleet.conf has a box and an offset for $p ('$BOXCOL' '$OFF')"; continue; }
  HARNESS_TEST_SANDBOX=1 bash "$DIR/bin/render-cron.sh" --root "$DIR" "$BOX" > "$T/base-$BOX.cron" 2>"$T/render.err" \
    || bad "E2: render-cron.sh $BOX rc 0: $(cat "$T/render.err")"
  HARNESS_TEST_SANDBOX=1 bash "$DIR/bin/render-crontab.sh" --root "$DIR" --base "$T/base-$BOX.cron" "$BOX" > "$T/tab-$BOX.cron" 2>"$T/render.err" \
    || bad "E2: render-crontab.sh $BOX rc 0: $(cat "$T/render.err")"
  if grep -qx "$OFF 9 \\* \\* 1 /root/harness/bin/run-product.sh $p" "$T/tab-$BOX.cron"; then ok
  else bad "E2: box $BOX has '$OFF 9 * * 1 /root/harness/bin/run-product.sh $p': $(grep -E 'run-product|run-triage' "$T/tab-$BOX.cron" | tr '\n' '|')"; fi
  if jq -e --arg b "$BOX" '.boxes | index($b) != null' "$LANE" >/dev/null 2>&1; then ok
  else bad "E4: run-product.json .boxes names $BOX (owner of $p)"; fi
done

# ════════════════════════════════════════════════════════════════════════════
# E3 — the git-ignored renders are valid
# ════════════════════════════════════════════════════════════════════════════
( cd "$DIR" && HARNESS_TEST_SANDBOX=1 bin/lanes-build.sh --check ) > "$T/e3.out" 2>&1 && ok \
  || bad "E3: bin/lanes-build.sh --check rc 0: $(tail -5 "$T/e3.out")"
( cd "$DIR" && HARNESS_TEST_SANDBOX=1 bin/render-cron.sh --check ) > "$T/e3.out" 2>&1 && ok \
  || bad "E3: bin/render-cron.sh --check rc 0: $(tail -5 "$T/e3.out")"

# E4 — the knob, from the composed registry: default 0, zero means unlimited,
# read in the cap library, and its own file under run-product.knobs.d/.
( cd "$DIR" && HARNESS_TEST_SANDBOX=1 bin/lanes-build.sh ) > "$T/lanes.json" 2>"$T/e4.err" || bad "E4: bin/lanes-build.sh composes: $(cat "$T/e4.err")"
if jq -e '[.lanes[] | select(.id == "run-product") | .knobs[] | select(.env == "PRODUCT_RUN_USD_CAP")]
          | length == 1 and (.[0].default == 0) and .[0].zero_means == "unlimited" and .[0].type == "float"
          and .[0].min == 0 and .[0].read_in == "bin/lib/product-run-cap.sh"' "$T/lanes.json" >/dev/null 2>&1; then ok
else bad "E4: one PRODUCT_RUN_USD_CAP knob on run-product, float, default 0, zero_means unlimited: $(jq -c '.lanes[] | select(.id == "run-product") | .knobs' "$T/lanes.json" 2>/dev/null)"; fi
[ -f "$DIR/catalog/lanes.d/run-product.knobs.d/PRODUCT_RUN_USD_CAP.json" ] && ok || bad "E4: the knob is its own file (BH-4987)"

# ════════════════════════════════════════════════════════════════════════════
# C1-C3, C5-C7 — product_run_cap_check on a fixture cost.csv
# ════════════════════════════════════════════════════════════════════════════
HDR="ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd,billing_mode,auth_fp,auth_account,session_id,row_source,result_usd,ticket,job_id,pr,run_id,note,lane_id,guard_fp"
HC="$T/hc"; mkdir -p "$HC/logs" "$HC/bin"
# beat.sh is stubbed first: scratch_install_closure keeps a file that is already there.
printf '#!/bin/bash\nexit 0\n' > "$HC/bin/beat.sh"; chmod +x "$HC/bin/beat.sh"
# alert-line.sh is run, not sourced, so it is not in the lib's closure.
scratch_install_closure bin/lib/product-run-cap.sh "$HC" > /dev/null || bad "setup: install the product-run-cap closure"
scratch_install_closure bin/alert-line.sh "$HC" > /dev/null || bad "setup: install the alert-line closure"
START=1791979200   # 2026-10-14 12:00:00Z
iso() { date -u -d "@$((START + $1))" '+%Y-%m-%dT%H:%M:%SZ'; }
row() { # row <offset_s> <project> <stage> <usd>
  printf '%s,box,%s,%s,claude,stub,0,1,0,0,0,0,%s,subscription,,,,,,,,,,,run-product,\n' "$(iso "$1")" "$2" "$3" "$4"
}
csv() { { echo "$HDR"; for r in "$@"; do printf '%s\n' "$r"; done; } > "$HC/logs/cost.csv"; }
# chk <cap> <stage> -> rc of product_run_cap_check, in a fresh shell; project project-6-os
chk() {
  : > "$HC/logs/ALERTS.log"; : > "$HC/logs/run.log"
  env PRODUCT_RUN_USD_CAP="$1" HARNESS="$HC" PROJECT=project-6-os RUN_START_EPOCH="$START" \
      LOG="$HC/logs/run.log" ALERTS="$HC/logs/ALERTS.log" \
      bash -c '. "$1" && product_run_cap_check "$2"' _ "$CAP_LIB" "$2"
}
nalerts() { wc -l < "$HC/logs/ALERTS.log"; }

# C1 — cap 0 is unlimited, whatever the spend.
csv "$(row 60 project-6-os signals 100.00)"
chk 0 signals; RC=$?
[ "$RC" = 0 ] && [ "$(nalerts)" = 0 ] && ok || bad "C1: cap 0 with spend 100 returns 0 and writes no ALERTS line (rc=$RC, alerts=$(nalerts))"

# C2 — cap 5, spend 4.99: continue.
csv "$(row 60 project-6-os signals 4.99)"
chk 5 signals; RC=$?
[ "$RC" = 0 ] && [ "$(nalerts)" = 0 ] && ok || bad "C2: cap 5 with spend 4.99 returns 0 (rc=$RC, alerts=$(nalerts))"

# C3 — cap 5, spend 5.00: stop, one log line, one ALERTS line.
csv "$(row 60 project-6-os signals 5.00)"
chk 5 signals; RC=$?
[ "$RC" = 1 ] && ok || bad "C3: cap 5 with spend 5.00 returns 1 (rc=$RC)"
[ "$(nalerts)" = 1 ] && grep -q '\[project-6-os\] product: run USD cap reached after signals: spend \$5.00 >= PRODUCT_RUN_USD_CAP \$5, cycle stopped' "$HC/logs/ALERTS.log" && ok \
  || bad "C3: exactly one ALERTS line naming project, stage, spend and cap: $(cat "$HC/logs/ALERTS.log")"
[ "$(wc -l < "$HC/logs/run.log")" = 1 ] && grep -q '\[project-6-os\] product: run cap reached after signals: spend \$5.00 >= cap \$5' "$HC/logs/run.log" && ok \
  || bad "C3: exactly one project log line: $(cat "$HC/logs/run.log")"

# C5 — an invalid cap is unlimited: rc 0, no line.
csv "$(row 60 project-6-os signals 100.00)"
for c in abc -1 '' ' ' 1e3 5x; do
  chk "$c" signals; RC=$?
  [ "$RC" = 0 ] && [ "$(nalerts)" = 0 ] && ok || bad "C5: cap '$c' returns 0 with no ALERTS line (rc=$RC)"
done
chk 2.5 signals; RC=$?
[ "$RC" = 1 ] && ok || bad "C5: a decimal cap 2.5 is valid and stops at 100 (rc=$RC)"

# C6 — a bare source with no run scope returns 0.
if env -u PROJECT -u HARNESS -u RUN_START_EPOCH -u LOG -u ALERTS PRODUCT_RUN_USD_CAP=5 \
     bash -c '. "$1" && product_run_cap_check map && product_run_cap_check synth' _ "$CAP_LIB" 2>/dev/null; then ok
else bad "C6: a bare source with no PROJECT, HARNESS or RUN_START_EPOCH returns 0"; fi
csv "$(row 60 project-6-os signals 100.00)"
if ( cd "$HC" && env -u HARNESS -u H PRODUCT_RUN_USD_CAP=5 PROJECT=project-6-os RUN_START_EPOCH="$START" \
     ALERTS="$HC/logs/ALERTS.log" LOG="$HC/logs/run.log" bash -c '. "$1" && product_run_cap_check signals' _ "$CAP_LIB" ); then ok
else bad "C6: no HARNESS and no H returns 0 (the lib never defaults its root)"; fi
env PRODUCT_RUN_USD_CAP=5 H="$HC" PROJECT=project-6-os RUN_START_EPOCH="$START" LOG="$HC/logs/run.log" ALERTS="$HC/logs/ALERTS.log" \
  bash -c 'unset HARNESS; . "$1" && product_run_cap_check signals' _ "$CAP_LIB"; RC=$?
[ "$RC" = 1 ] && ok || bad "C6: H is the root when HARNESS is unset (rc=$RC)"
rm -f "$HC/logs/cost.csv"
chk 5 synth; RC=$?
[ "$RC" = 0 ] && [ "$(nalerts)" = 0 ] && ok || bad "C6: no cost.csv returns 0 (rc=$RC)"
grep -q '^# Owner: BH-7244.5' "$CAP_LIB" && ok || bad "C6: the seam keeps its owner comment"

# C7 — near misses each return 0, then a sum over two stages stops.
for r in "$(row 60 project-6 signals 6.00)" "$(row -60 project-6-os signals 6.00)" \
         "$(row 60 project-6-os replan 6.00)" "$(row 60 project-6-os-x signals 6.00)"; do
  csv "$r"
  chk 5 signals; RC=$?
  [ "$RC" = 0 ] && [ "$(nalerts)" = 0 ] && ok || bad "C7: a near-miss row is not counted (rc=$RC): $r"
done
printf '%s\n' "ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,9999" > "$HC/logs/cost.csv"
chk 5 signals; RC=$?
[ "$RC" = 0 ] && ok || bad "C7: the header row is not counted (rc=$RC)"
csv "$(row 60 project-6-os signals 3.00)" "$(row 120 project-6-os pm 2.50)"
chk 5 ideate; RC=$?
[ "$RC" = 1 ] && grep -q 'spend \$5.50 >= PRODUCT_RUN_USD_CAP \$5' "$HC/logs/ALERTS.log" && ok \
  || bad "C7: 3.00 signals + 2.50 pm sums to 5.50 and stops (rc=$RC): $(cat "$HC/logs/ALERTS.log")"
csv "$(row 0 project-6-os map 1)" "$(row 1 project-6-os ideate 1)" "$(row 2 project-6-os synth 1)" \
    "$(row 3 project-6-os prd 1)" "$(row 4 project-6-os mockup 0.5)"
chk 4.5 synth; RC=$?
[ "$RC" = 1 ] && ok || bad "C7: map+ideate+synth+prd+mockup at the run start sum to 4.50 and stop at cap 4.5 (rc=$RC)"

# ════════════════════════════════════════════════════════════════════════════
# C4 — the real bin/run-product.sh: spend 6.00 at SIGNALS, cap 5
# ════════════════════════════════════════════════════════════════════════════
P=project-6-os
H="$T/h"
mkdir -p "$H/bin/lib" "$H/env" "$H/state" "$H/logs" "$H/flags" "$H/prompts/product-stages" "$T/stub"
printf 'lane_model() { echo stub-model; }\n' > "$H/bin/lib/lane-model.sh"
: > "$H/bin/lib/gh-app-auth.sh"; : > "$H/bin/lib/gh-limit-logger.sh"
scratch_install_closure bin/run-product.sh "$H" > /dev/null || bad "setup: install the run-product closure"
scratch_install_closure bin/alert-line.sh "$H" > /dev/null || bad "setup: install the alert-line closure"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
printf '#!/bin/bash\nprintf prd > "$2/prd.md"\nexit 0\n' > "$H/bin/draft-proposal.sh"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/post-proposal.sh"
# agent-call <stage> <project> <model> <timeout> <outfile> <prompt>; SIGNALS spends 6.00.
cat > "$H/bin/agent-call.sh" <<EOF
#!/bin/bash
stage=\$1; prompt=\$6
echo "\$stage" >> "$T/stages.log"
field() { printf '%s\n' "\$prompt" | sed -n "s/^\$1=\([^ ]*\).*/\1/p" | head -1; }
case "\$stage" in
  signals) printf '{"signals":[{"s":1}]}' > "\$(field SIGNALS_OUT)"
           printf '%s,box,%s,signals,claude,stub,0,1,0,0,0,0,6.00,subscription,,,,,,,,,,,run-product,\n' "\$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "\$2" >> "$H/logs/cost.csv" ;;
  ideate)  cp "$T/ideas.json" "\$(field IDEAS_OUT)" ;;
  synth)   cp "$T/ideas.json" "\$(field IDEAS_OUT)" ;;
esac
exit 0
EOF
chmod +x "$H"/bin/*.sh
for s in map signals ideate-dept synth; do echo "$s" > "$H/prompts/product-stages/$s.md"; done
echo ctx > "$H/prompts/product-$P.md"
printf '#!/bin/bash\nexit 0\n' > "$T/stub/git"; chmod +x "$T/stub/git"
jq -n '{ideas:[{slug:"X",title:"T X",summary:"s",dus:"derisk",impact:10,confidence:10,effort:1}]}' > "$T/ideas.json"
printf -- '---\ndepartments: [ops, sales]\n---\n' > "$H/state/$P.company-map.md"
RP_SAFE=0
grep -q '^HARNESS="${HARNESS:-/root/harness}"$' "$H/bin/run-product.sh" && RP_SAFE=1
reset() {
  scratch_rm "$H/products"; scratch_rm "$H/state/product-$P.ledger.json"; scratch_rm "$T/stages.log"
  echo "$HDR" > "$H/logs/cost.csv"
  echo "$(date -u -d '-1 hour' '+%Y-%m-%d %H:%M:%SZ') [$P] a fixture alert" > "$H/logs/ALERTS.log"; : > "$H/logs/$P.log"
}
runp() { # runp <cap>
  [ "$RP_SAFE" = 1 ] || { echo "run-product.sh pins HARNESS=/root/harness; not executed" > "$T/out.txt"; return 99; }
  HARNESS="$H" PRODUCT_RUN_USD_CAP="$1" PATH="$T/stub:$PATH" bash "$H/bin/run-product.sh" "$P" > "$T/out.txt" 2>&1
}
stages() { tr '\n' ' ' 2>/dev/null < "$T/stages.log"; }

reset; runp 5; RC=$?
[ "$RC" = 0 ] && ok || bad "C4: run-product exits 0 at the cap (rc=$RC): $(cat "$T/out.txt")"
[ "$(stages)" = "signals " ] && ok || bad "C4: SIGNALS runs and IDEATE is never called (stages '$(stages)')"
NEW=$(tail -n +2 "$H/logs/ALERTS.log")
[ "$(grep -c . <<<"$NEW")" = 1 ] && ok || bad "C4: ALERTS.log gained exactly 1 line: $NEW"
grep -q "\[$P\] product: run USD cap reached after signals: spend \\\$6.00 >= PRODUCT_RUN_USD_CAP \\\$5" <<<"$NEW" && ok \
  || bad "C4: the ALERTS line names the project, signals, 6.00 and 5: $NEW"
grep -q "\[$P\] product rc=0 :: run cap reached after signals, cycle ended" "$H/logs/$P.log" && ok \
  || bad "C4: run-product logs the cycle end: $(cat "$H/logs/$P.log")"
[ ! -e "$H/products/$P/$(date -u +%Y-%m-%d)/selected.json" ] && ok || bad "C4: no SELECT after the cap"

reset; runp 0; RC=$?
[ "$RC" = 0 ] && [ "$(stages)" = "signals ideate ideate synth " ] && ok \
  || bad "C4: cap 0 runs every stage (rc=$RC, stages '$(stages)'): $(cat "$T/out.txt")"
[ "$(wc -l < "$H/logs/ALERTS.log")" = 1 ] && ok || bad "C4: cap 0 writes no ALERTS line: $(cat "$H/logs/ALERTS.log")"
grep -q "product rc=0 :: product v2: .*selected=1 gated=1 cost~\\\$6.00" "$H/logs/$P.log" && ok \
  || bad "C4: cap 0 reaches the run summary with cost 6.00: $(cat "$H/logs/$P.log")"

echo "product-fleet-enable: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
