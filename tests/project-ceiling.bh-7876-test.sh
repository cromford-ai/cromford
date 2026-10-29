#!/bin/bash
# tests/project-ceiling.bh-7876-test.sh — the per-project daily spend ceiling
# (BH-7876): settings row conf.cost-caps.<project>.daily_usd, catalog line
# `daily <project> <usd>`.
#
#   G1-G6  the grammar in bin/lib/cost-budget.sh: file line, the exact row
#          the operator wrote (project-6-os.daily_usd = 5000), row beats line, a junk
#          row is named and binds nothing, another box's row and a dotted
#          project bind nothing, the warn percent and its default; G7 the
#          shipped catalog and seed carry the operator's 5000 and 10000
#   C1-C9  bin/lib/project-ceiling.sh against a fake jobs client: 79% no
#          alert, 80% one warn alert, 100% one over alert and a refusal, one
#          alert per project per UTC day, the alert names project, spend and
#          ceiling, no row = no read, an unreadable spend, the kill switch;
#          C10 the warn row moves the warn point
#   L1-L5  the `# >>> budget launch gate` block of bin/lib/rb/gates.sh,
#          verbatim: over = BUILD_DEFERRED budget-project-day and no ADMITTED,
#          a hotfix still starts, no row behaves as today, an admitted resume
#          is not re-checked, and pool_lane_failure (bin/fly-pool.sh) reads
#          the deferral as the lane's condition
#   S1-S2  the `# >>> project ceiling note` block of bin/agent-call.sh,
#          verbatim: alert only, never a refusal; a stage outside
#          plan/execute/review/lead-review reads nothing
#   N      the node suites console-ui/tests/daily-ceilings.bh-7876.test.js and
#          mcp/test/project-status-ceiling.bh-7876.test.mjs, when node can run
#
# Every case has its own project slug. The UTC day is pinned through
# PROJECT_CEILING_DAY, so no case reads the wall clock for its alert id.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/project-ceiling.bh-7876-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: got [$2] want [$3]"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

PCLIB="$DIR/bin/lib/project-ceiling.sh"
GATES="$DIR/bin/lib/rb/gates.sh"
AC="$DIR/bin/agent-call.sh"
DAY=20261021
NOW=$(date +%s)

# ── the tree: the libs' closures, a fake alert-line, a settings cache ───────
H="$T/h"
mkdir -p "$H/state" "$H/flags" "$H/logs" "$T/spend"
for s in bin/lib/cost-budget.sh bin/lib/budget-stop.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || { echo "closure install of $s failed"; exit 1; }
done
if [ -f "$PCLIB" ]; then
  scratch_install_closure bin/lib/project-ceiling.sh "$H" >/dev/null || { echo "closure install of project-ceiling.sh failed"; exit 1; }
  ok
else
  bad "no bin/lib/project-ceiling.sh"
fi
cat > "$H/bin/alert-line.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$ALERT_LOG"
EOF
chmod +x "$H/bin/alert-line.sh"

# cache <values-json> — the shape _lg_settings_refresh writes, fresh.
cache() {
  jq -n --argjson v "$1" --argjson t "$NOW" '{fetched_at: $t, values: $v, seeded: {}}' > "$H/state/settings-cache.json"
}
# spend <project> <usd>|down — what GET /api/metrics/llm-spend answers.
spend() {
  if [ "$2" = down ]; then echo down > "$T/spend/$1.json"
  else printf '{"usd":%s,"calls":1,"refused":0,"settled":0}' "$2" > "$T/spend/$1.json"; fi
}
reads() { local n; n=$(grep -c "llm-spend?project=$1\$" "$T/req.log" 2>/dev/null); echo "${n:-0}"; }
alerts() { local n; n=$(grep -c -- "--id project-ceiling-$1" "$T/alerts.log" 2>/dev/null); echo "${n:-0}"; }

# The fake jobs client: llm-spend from $T/spend/<project>.json, every request
# logged, anything else (and a "down" file) a transport failure.
FAKE_JOBS='
_jobs_req() {
  printf "%s\n" "$2" >> "$T/req.log"
  case "$2" in
    /api/metrics/llm-spend\?project=*)
      local p="${2#*project=}"; p="${p%%&*}"
      [ -r "$T/spend/$p.json" ] || { printf "{\"usd\":0,\"calls\":0,\"refused\":0,\"settled\":0}"; return 0; }
      grep -q "^down" "$T/spend/$p.json" && return 1
      cat "$T/spend/$p.json" ;;
    *) return 1 ;;
  esac
}'
export T H NOW DAY FAKE_JOBS
# lib <snippet> — a cold shell over the tree, the fake jobs client loaded.
lib() {
  env HARNESS="$H" LANE_GATE_NOW="$NOW" JOBS_BOX=testbox PROJECT_CEILING_DAY="$DAY" \
      HARNESS_SECRET=fixture-secret JOBS_URL=https://jobs.invalid ALERT_LOG="$T/alerts.log" "${XENV[@]}" \
    bash -c 'set -uo pipefail; eval "$FAKE_JOBS"
      . "$HARNESS/bin/lib/project-ceiling.sh" 2>/dev/null || . "$HARNESS/bin/lib/cost-budget.sh" || exit 9
      eval "$1"' _ "$1" 2>/dev/null
}
XENV=()

# ── G: the grammar ──────────────────────────────────────────────────────────
printf 'daily g1-acme 50\n' > "$T/g1.conf"
cache '{}'
XENV=(COST_CAPS_CONF="$T/g1.conf")
eq "G1 a catalog line binds the ceiling" "$(lib 'cost_budget_daily g1-acme; echo "rc=$?"')" "$(printf '50\nrc=0')"
eq "G1 no line, no ceiling (rc 1)" "$(lib 'cost_budget_daily g1-other; echo "rc=$?"')" "rc=1"
XENV=()
cache '{"conf.cost-caps.project-6-os.daily_usd":"5000"}'
eq "G2 the row the operator wrote binds 5000" "$(lib 'cost_budget_daily project-6-os; echo "rc=$?"')" "$(printf '5000\nrc=0')"
mkdir -p "$H/catalog"; printf 'daily g3-acme 50\n' > "$H/catalog/cost-caps.conf"
cache '{"conf.cost-caps.g3-acme.daily_usd":"75"}'
eq "G3 the row beats the file line" "$(lib 'cost_budget_daily g3-acme')" "75"
cache '{}'
eq "G3 the file line alone answers" "$(lib 'cost_budget_daily g3-acme')" "50"
rm -f "$H/catalog/cost-caps.conf"
cache '{"conf.cost-caps.g4-acme.daily_usd":"abc"}'
eq "G4 a junk row binds no ceiling" "$(lib 'cost_budget_daily g4-acme; echo "rc=$?"')" "rc=1"
case " $(lib 'cost_budget_legacy_rows') " in *" row:g4-acme.daily_usd "*) ok ;; *) bad "G4 legacy rows: $(lib 'cost_budget_legacy_rows')" ;; esac
cache '{"conf.cost-caps.g4-zero.daily_usd":"0"}'
eq "G4 a zero row binds no ceiling" "$(lib 'cost_budget_daily g4-zero; echo "rc=$?"')" "rc=1"
cache '{"conf.cost-caps.g5-acme.daily_usd.otherbox":"10","conf.cost-caps.a.b.daily_usd":"10"}'
eq "G5 another box's row binds nothing" "$(lib 'cost_budget_daily g5-acme; echo "rc=$?"')" "rc=1"
eq "G5 a dotted project binds nothing" "$(lib 'cost_budget_daily a.b; echo "rc=$?"')" "rc=1"
cache '{"conf.cost-caps.g5-box.daily_usd.testbox":"30","conf.cost-caps.g5-box.daily_usd":"60"}'
eq "G5 this box's row beats the fleet row" "$(lib 'cost_budget_daily g5-box')" "30"
cache '{}'
eq "G6 the warn percent defaults to 80" "$(lib 'cost_budget_daily_warn_pct')" "80"
cache '{"conf.cost-caps.daily_warn_pct":"90"}'
eq "G6 the warn row answers" "$(lib 'cost_budget_daily_warn_pct')" "90"
cache '{"conf.cost-caps.daily_warn_pct":"150"}'
eq "G6 a warn row over 100 is refused" "$(lib 'cost_budget_daily_warn_pct')" "80"

# G7: the operator's values ship as reviewed lines and seed rows (ticket comment
# 6326016557): the catalog alone binds project-6-os 5000 and the fleet ceiling
# 10000, and bin/cost-caps-seed.sh turns both lines into settings rows.
cache '{}'
XENV=(COST_CAPS_CONF="$DIR/catalog/cost-caps.conf")
eq "G7 the shipped catalog binds project-6-os 5000" "$(lib 'cost_budget_daily project-6-os; echo "rc=$?"')" "$(printf '5000\nrc=0')"
eq "G7 the shipped catalog sets the fleet ceiling to 10000" "$(lib 'cost_budget_ceiling')" "10000"
eq "G7 a project with no line has no ceiling" "$(lib 'cost_budget_daily g7-none; echo "rc=$?"')" "rc=1"
XENV=()
eq "G7 the code default for the fleet ceiling is unchanged" \
  "$(sed -n 's/^COST_BUDGET_DEFAULT_CEILING=//p' "$DIR/bin/lib/cost-budget.sh")" "4000"
G7_ROWS=$(HARNESS="$DIR" "$DIR/bin/cost-caps-seed.sh" --dry-run 2>/dev/null \
  | jq -r '.rows[] | select(.key == "conf.cost-caps.project-6-os.daily_usd" or .key == "conf.cost-caps.ceiling") | "\(.key)=\(.value)"' | LC_ALL=C sort)
eq "G7 the seed sends both rows" "$G7_ROWS" "$(printf 'conf.cost-caps.ceiling=10000\nconf.cost-caps.project-6-os.daily_usd=5000')"

# ── C: the check ────────────────────────────────────────────────────────────
: > "$T/req.log"; : > "$T/alerts.log"
cache '{"conf.cost-caps.c1.daily_usd":"50","conf.cost-caps.c6.daily_usd":"50","conf.cost-caps.c8.daily_usd":"50","conf.cost-caps.c9.daily_usd":"50"}'
spend c1 39.50
eq "C1 79% stage note rc 0" "$(lib 'pc_stage_note c1 execute; echo "rc=$?"')" "rc=0"
eq "C1 79% reads the spend once" "$(reads c1)" "1"
eq "C1 79% raises no alert" "$(alerts warn-c1)$(alerts over-c1)" "00"
spend c1 39.99
eq "C1 79.98% is still under" "$(lib 'pc_eval c1; echo "$?:$PC_STATE:$PC_PCT"')" "0:under:79"
spend c1 40.00
eq "C2 80% is warn" "$(lib 'pc_eval c1; echo "$?:$PC_STATE:$PC_PCT"')" "0:warn:80"
lib 'pc_stage_note c1 plan' >/dev/null
eq "C2 80% raises one warn alert" "$(alerts "warn-c1-$DAY")" "1"
lib 'pc_stage_note c1 review' >/dev/null
eq "C3 a second 80% read raises no second alert" "$(alerts "warn-c1-$DAY")" "1"
spend c1 49.99
eq "C3 99.98% is warn, not over" "$(lib 'pc_launch_check c1 0; echo "rc=$?"')" "rc=0"
spend c1 50.00
eq "C4 100% refuses a launch" "$(lib 'pc_launch_check c1 0; echo "rc=$?|$PC_LINE"')" "rc=1|project-ceiling project=c1 usd=50.00/50"
eq "C4 100% raises one over alert" "$(alerts "over-c1-$DAY")" "1"
lib 'pc_launch_check c1 0' >/dev/null
eq "C4 a second 100% read raises no second alert" "$(alerts "over-c1-$DAY")" "1"
eq "C3/C4 exactly two alert lines for c1" "$(grep -c -- '--project c1 ' "$T/alerts.log")" "2"
L=$(grep -- "--id project-ceiling-over-c1-$DAY" "$T/alerts.log")
case "$L" in *'c1 has spent $50.00 today (UTC)'*'daily ceiling of $50.'*'No new build starts for c1 until 00:00Z'*) ok ;; *) bad "C5 over line: $L" ;; esac
L=$(grep -- "--id project-ceiling-warn-c1-$DAY" "$T/alerts.log")
case "$L" in *'c1 has spent $40.00 today (UTC), 80% of its daily ceiling of $50.'*) ok ;; *) bad "C5 warn line: $L" ;; esac
spend c6 75
eq "C6 straight to 100% refuses" "$(lib 'pc_launch_check c6 0; echo "rc=$?"')" "rc=1"
spend c6 40
lib 'pc_stage_note c6 execute' >/dev/null
eq "C6 one over alert and no later warn the same day" "$(alerts "over-c6-$DAY")$(alerts "warn-c6-$DAY")" "10"
eq "C7 no ceiling row: allowed" "$(lib 'pc_launch_check c7 0; echo "rc=$?"; pc_stage_note c7 execute; echo "rc=$?"')" "$(printf 'rc=0\nrc=0')"
eq "C7 no ceiling row: no spend read" "$(reads c7)" "0"
eq "C7 no ceiling row: no alert" "$(grep -c -- '--project c7 ' "$T/alerts.log")" "0"
spend c8 down
eq "C8 an unreadable spend refuses a launch (rc 2)" "$(lib 'pc_launch_check c8 0; echo "rc=$?|$PC_REASON"')" "rc=2|project-ceiling-unreadable:c8"
eq "C8 an unreadable spend admits a hotfix with a note" "$(lib 'pc_launch_check c8 1; echo "rc=$?|$PC_NOTE"')" "rc=0|project-ceiling-unreadable:c8"
eq "C8 an unreadable spend never stops a stage call" "$(lib 'pc_stage_note c8 execute; echo "rc=$?"')" "rc=0"
spend c6 75
eq "C8 a hotfix over the ceiling is admitted with a note" "$(lib 'pc_launch_check c6 1; echo "rc=$?|$PC_NOTE"')" "rc=0|project-ceiling project=c6 usd=75.00/50"
spend c9 60
touch "$H/flags/project-ceiling-off"
eq "C9 the kill switch allows" "$(lib 'pc_launch_check c9 0; echo "rc=$?"')" "rc=0"
eq "C9 the kill switch reads nothing" "$(reads c9)" "0"
rm -f "$H/flags/project-ceiling-off"
eq "C9 non-vacuity: switch off, c9 refuses" "$(lib 'pc_launch_check c9 0; echo "rc=$?"')" "rc=1"
eq "C-inert no jobs client: no read, allowed" \
  "$(env -u JOBS_URL HARNESS="$H" LANE_GATE_NOW="$NOW" JOBS_BOX=testbox bash -c '. "$HARNESS/bin/lib/project-ceiling.sh" 2>/dev/null || exit 9; pc_launch_check c9 0; echo "rc=$?"' 2>/dev/null)" "rc=0"

cache '{"conf.cost-caps.c10.daily_usd":"50","conf.cost-caps.daily_warn_pct":"90"}'
spend c10 40
eq "C10 a 90% warn row: 80% is under" "$(lib 'pc_eval c10; echo "$PC_STATE"')" "under"
spend c10 45
eq "C10 a 90% warn row: 90% is warn" "$(lib 'pc_eval c10; echo "$PC_STATE"')" "warn"

# ── L: the launch gate, verbatim ────────────────────────────────────────────
awk '/^# >>> budget launch gate/{f=1} f{print} /^# <<< budget launch gate/{f=0}' "$GATES" > "$T/launch.sh"
[ -s "$T/launch.sh" ] && ok || bad "L no '# >>> budget launch gate' block in bin/lib/rb/gates.sh"
# launch <project> [VAR=VAL ...] -> rc; RESULT in $T/L/result, the Fly gate reached in $T/L/reached
launch() {
  local p="$1"; shift
  rm -rf "$T/L"; mkdir -p "$T/L/build"
  # The box's own HOTFIX / RESUME_BUILD never reach a case: each sets its own.
  ( unset HOTFIX RESUME_BUILD ADMIT_FIRST
    export HARNESS="$H" LANE_GATE_NOW="$NOW" JOBS_BOX=testbox PROJECT_CEILING_DAY="$DAY" \
           HARNESS_SECRET=fixture-secret JOBS_URL=https://jobs.invalid ALERT_LOG="$T/alerts.log" P="$p" "$@"
    bash -c '
      set -uo pipefail
      eval "$FAKE_JOBS"
      PROJECT=$P; KEY=LT-1; BUILD="$T/L/build"
      [ -n "${ADMIT_FIRST:-}" ] && echo admitted > "$BUILD/ADMITTED"
      STAMP() { date -u +%FT%TZ; }
      RESULT() { printf "%s\n" "$*" > "$T/L/result"; }
      . "$1"
      echo REACHED > "$T/L/reached"' _ "$T/launch.sh" ) >/dev/null 2>&1
  echo $?
}
: > "$T/req.log"
cache '{"conf.cost-caps.l1.daily_usd":"50","conf.cost-caps.l2.daily_usd":"50","conf.cost-caps.l4.daily_usd":"50"}'
spend l1 50
eq "L1 over: exit 3" "$(launch l1 HOTFIX=)" "3"
grep -q '^BUILD_DEFERRED budget-project-day project-ceiling project=l1 usd=50.00/50 ' "$T/L/result" 2>/dev/null && ok || bad "L1 RESULT: $(cat "$T/L/result" 2>/dev/null)"
[ -e "$T/L/build/ADMITTED" ] && bad "L1 ADMITTED written over the ceiling" || ok
[ -e "$T/L/reached" ] && bad "L1 the Fly enqueue was reached over the ceiling" || ok
L1_RESULT=$(cat "$T/L/result" 2>/dev/null)
spend l1 49.99
eq "L1 non-vacuity: 99.98% starts" "$(launch l1)" "0"
[ -e "$T/L/build/ADMITTED" ] && ok || bad "L1 99.98% wrote no ADMITTED"
spend l2 50
eq "L2 a hotfix at 100% starts" "$(launch l2 HOTFIX=1)" "0"
[ -e "$T/L/build/ADMITTED" ] && [ -e "$T/L/reached" ] && ok || bad "L2 hotfix: no ADMITTED or not reached"
grep -q 'HOTFIX admitted over the daily ceiling: project-ceiling project=l2 usd=50.00/50' "$T/L/build/pipeline.log" 2>/dev/null \
  && ok || bad "L2 pipeline.log: $(cat "$T/L/build/pipeline.log" 2>/dev/null)"
eq "L3 no ceiling row starts" "$(launch l3)" "0"
[ -e "$T/L/build/ADMITTED" ] && ok || bad "L3 no ADMITTED"
eq "L3 no ceiling row reads nothing" "$(reads l3)" "0"
spend l4 80
eq "L4 an admitted resume at 160% goes on" "$(launch l4 RESUME_BUILD=1 ADMIT_FIRST=1)" "0"
eq "L4 an admitted resume reads nothing" "$(reads l4)" "0"
spend l5 down
cache '{"conf.cost-caps.l5.daily_usd":"50"}'
eq "L-unreadable defers" "$(launch l5)" "3"
grep -q '^BUILD_DEFERRED budget-cap-unreadable launch project-ceiling-unreadable:l5 ' "$T/L/result" 2>/dev/null && ok || bad "L-unreadable RESULT: $(cat "$T/L/result" 2>/dev/null)"
awk '/^pool_lane_failure\(\)/{f=1} f{print} f&&/^}/{exit}' "$DIR/bin/fly-pool.sh" > "$T/plf.sh"
eq "L5 pool_lane_failure reads the L1 deferral as the lane's condition" \
  "$(bash -c '. "$1"; pool_lane_failure "$2"; echo $?' _ "$T/plf.sh" "$L1_RESULT")" "0"

# ── S: the agent-call stage note, verbatim ─────────────────────────────────
awk '/^# >>> project ceiling note/{f=1} f{print} /^# <<< project ceiling note/{f=0}' "$AC" > "$T/note.sh"
[ -s "$T/note.sh" ] && ok || bad "S no '# >>> project ceiling note' block in bin/agent-call.sh"
ORDER=$(grep -n '^# <<< budget-stop precall\|^# >>> project ceiling note\|^ctx_kill_work$' "$AC" | awk -F: '{print $2}' | tr '\n' '|')
eq "S placement: after the budget stop, before the call" "$ORDER" "# <<< budget-stop precall|# >>> project ceiling note (BH-7876)|ctx_kill_work|"
# note <project> <stage> -> "rc=<n> out=<$OUT contents>"
note() {
  ( export HARNESS="$H" LANE_GATE_NOW="$NOW" JOBS_BOX=testbox PROJECT_CEILING_DAY="$DAY" \
           HARNESS_SECRET=fixture-secret JOBS_URL=https://jobs.invalid ALERT_LOG="$T/alerts.log"
    bash -c '
      set -uo pipefail
      eval "$FAKE_JOBS"
      PROJECT=$1; STAGE=$2; OUT="$T/s-out.txt"; : > "$OUT"
      . "$3"
      echo "rc=$? out=$(cat "$OUT")"' _ "$1" "$2" "$T/note.sh" ) 2>/dev/null
}
cache '{"conf.cost-caps.s1.daily_usd":"50","conf.cost-caps.s2.daily_usd":"50"}'
spend s1 40
eq "S1 80% at execute: goes on, nothing refused" "$(note s1 execute)" "rc=0 out="
eq "S1 one warn alert" "$(alerts "warn-s1-$DAY")" "1"
spend s1 60
eq "S1 over the ceiling mid-build: the call still goes on" "$(note s1 lead-review)" "rc=0 out="
eq "S1 one over alert" "$(alerts "over-s1-$DAY")" "1"
spend s2 40
for st in triage fix qa; do note s2 "$st" >/dev/null; done
eq "S2 triage/fix/qa read nothing" "$(reads s2)" "0"
eq "S2 triage/fix/qa alert nothing" "$(alerts "warn-s2-$DAY")" "0"

# ── N: the node suites ─────────────────────────────────────────────────────
CONSOLE_LIB="$DIR/console-ui/src/lib/daily-ceilings.js"
CONSOLE_SCREEN="$DIR/console-ui/src/screens/DailyCeilings.js"
for f in "$CONSOLE_LIB" "$CONSOLE_SCREEN"; do [ -f "$f" ] && ok || bad "missing $f"; done
if command -v node >/dev/null 2>&1; then
  if [ -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
    ( cd "$DIR/console-ui" && node --test tests/daily-ceilings.bh-7876.test.js >"$T/node-console.txt" 2>&1 ) \
      && ok || { bad "N console-ui/tests/daily-ceilings.bh-7876.test.js"; tail -30 "$T/node-console.txt"; }
  else
    echo "project-ceiling: console node suite SKIPPED — console-ui dependencies are not installed"
  fi
  ( cd "$DIR/mcp" && node --test test/project-status-ceiling.bh-7876.test.mjs >"$T/node-mcp.txt" 2>&1 ) \
    && ok || { bad "N mcp/test/project-status-ceiling.bh-7876.test.mjs"; tail -30 "$T/node-mcp.txt"; }
else
  echo "project-ceiling: node suites SKIPPED — node is not installed"
fi

echo "project-ceiling.bh-7876: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
