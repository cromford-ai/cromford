#!/bin/bash
# tests/size-gate-fallbacks.bh-6025-test.sh — BH-6025: every code fallback of
# the fleet size gate is 1200 lines / 30 files, the numbers the operator set by hand on
# the hub's size_gate.lines / size_gate.files rows on 2026-10-14. A fresh
# settings table, a box with no worker, LANE_GATE_DISABLE=1 or a bad cache then
# gives the same answer as the hub. The rows still win over every fallback.
#
#   F1  no rows at all                        -> 1200 30 default
#   F1b a corrupt cache                       -> 1200 30
#   F2  bin/size-gate.sh with no limit args   -> lines=1200 files=30, the 15%
#       band at 1380 lines / 34 files
#   F2b junk limit args                       -> lines=1200 files=30
#   F3  plan.sh's size threshold call, junk from size-threshold.sh
#                                             -> 1200 30 default
#   F4  run-decompose.sh and pr.sh guards     -> 1200 / 30
#   F5  rows still win: fleet, project, hotfix
#   F6  the composed schema seeds 1200/30 (hotfix 1500/30), and a re-apply
#       keeps an operator's edit
#   F7  the pipeline's size gate block with no rows: 1500 lines splits, 900
#       continues (the r1 regression, read from ledger-stages D1's side)
#   F5b a project row of 600 still splits a 700-line plan
#   F8  the shipped pr.sh SP_MAXL lines and run-decompose.sh header lines,
#       executed with no answer / junk: 1200 (bound 2400) and 1200/30; and no
#       700/20 size fallback literal is left in the five product files
#   F9  catalog/size-thresholds.conf states 1200/30; 700/20 only on the
#       "Before 2026-10-14" history line
# Rows come from a state/settings-cache.json fixture with JOBS_URL= and no jobs
# client in the scratch tree: nothing reaches the network.
#
#   HARNESS_TEST_SANDBOX=1 bash tests/size-gate-fallbacks.bh-6025-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

THRESH="$DIR/bin/size-threshold.sh"
GATE="$DIR/bin/size-gate.sh"
h="$T/h"
mkdir -p "$h/state" "$h/flags" "$h/catalog" "$h/logs"
cache() { jq -n --argjson fa 1900000000 --argjson v "$1" '{fetched_at:$fa,values:$v,seeded:{}}' > "$h/state/settings-cache.json"; }
th() { LANE_GATE_NOW=1900000000 HARNESS="$h" JOBS_URL= SIZE_THRESHOLDS_CONF=/nonexistent "$THRESH" "$@" 2>/dev/null; }
reset() { rm -f "$h/state/settings-cache.json" "$h/flags/size-gate-widget-os"; scratch_rm "$h/state/lane-gate"; }

# F1. no rows, no flag, no catalog row
reset
[ "$(LANE_GATE_DISABLE=1 th anything all)" = "1200 30 default" ] && ok \
  || bad "F1: LANE_GATE_DISABLE=1 must answer '1200 30 default', got '$(LANE_GATE_DISABLE=1 th anything all)'"
[ "$(th widget-os all)" = "1200 30 default" ] && ok || bad "F1: no cache must answer '1200 30 default', got '$(th widget-os all)'"
[ "$(SIZE_TIER=hotfix th widget-os all)" = "1200 30 default" ] && ok \
  || bad "F1: a hotfix with no rows falls to the same default, got '$(SIZE_TIER=hotfix th widget-os all)'"

# F1b. a corrupt cache is no rows
reset; printf 'not json{' > "$h/state/settings-cache.json"
[ "$(th widget-os)" = "1200 30" ] && ok || bad "F1b: a corrupt cache must answer '1200 30', got '$(th widget-os)'"

# F2. size-gate.sh with no limit args: the default and its 15% band
splan() { printf '# Plan\n\n### Task 1\n- VALIDATE: x\n\n## Size\nFILES: %s\nLINES: %s\n' "$2" "$1" > "$T/plan.md"; }
gate() { env -u SIZE_LIMITS_SRC -u SIZE_GATE_TOLERANCE_PCT "$GATE" "$T/plan.md" "$@" 2>&1; }
splan 1100 25
G=$(gate); RC=$?
[ "$RC" = 0 ] && ok || bad "F2: 1100/25 must be within (rc 0), got rc $RC: $G"
grep -q '^SIZE_LIMITS: lines=1200 files=30$' <<<"$G" && ok || bad "F2: no args must use lines=1200 files=30: $G"
splan 1400 25
G=$(gate); RC=$?
[ "$RC" = 2 ] && ok || bad "F2: 1400 lines must be over (rc 2), got rc $RC: $G"
grep -q 'lines=1400>1200' <<<"$G" && ok || bad "F2: the over line must name 1400>1200: $G"
verdict() { splan "$1" "$2"; sed -n 's/^SIZE_VERDICT: //p' <<<"$(gate)"; }
[ "$(verdict 1380 10)" = within ] && ok || bad "F2: 1380 lines is inside the band, got '$(verdict 1380 10)'"
[ "$(verdict 1381 10)" = over ] && ok || bad "F2: 1381 lines is past the band, got '$(verdict 1381 10)'"
[ "$(verdict 100 34)" = within ] && ok || bad "F2: 34 files is inside the band, got '$(verdict 100 34)'"
[ "$(verdict 100 35)" = over ] && ok || bad "F2: 35 files is past the band, got '$(verdict 100 35)'"
[ "$(verdict 1200 30)" = within ] && ok || bad "F2: exactly 1200/30 is within, got '$(verdict 1200 30)'"
[ "$(verdict 900 6)" = within ] && ok || bad "F2: 900 lines (the old D1 value) is within, got '$(verdict 900 6)'"

# F2b. junk limit args fall back to the same default
splan 100 2
G=$(gate banana x)
grep -q '^SIZE_LIMITS: lines=1200 files=30$' <<<"$G" && ok || bad "F2b: junk args must use lines=1200 files=30: $G"

# F3. plan.sh's size threshold call, when size-threshold.sh prints junk
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
awk '/^# >>> size threshold call/{f=1;next} /^# <<< size threshold call/{exit} f' "$RB_ALL" > "$T/tcall.sh"
if [ -s "$T/tcall.sh" ]; then
  mkdir -p "$T/p/bin"
  pdrive() { # pdrive <what the fake size-threshold.sh prints> <its exit code>
    printf '#!/bin/bash\nprintf "%%s\\n" "%s"\nexit %s\n' "$1" "$2" > "$T/p/bin/size-threshold.sh"
    chmod +x "$T/p/bin/size-threshold.sh"
    env -u SIZE_TIER HARNESS="$T/p" PROJECT=widget-os HOTFIX= \
      bash -c '. "$1"; printf "%s %s %s\n" "$SG_MAXL" "$SG_MAXF" "$SG_SRC"' _ "$T/tcall.sh" 2>/dev/null
  }
  [ "$(pdrive 'banana x' 0)" = "1200 30 default" ] && ok || bad "F3: junk limits must be '1200 30 default', got '$(pdrive 'banana x' 0)'"
  [ "$(pdrive '' 1)" = "1200 30 default" ] && ok || bad "F3: a failed read must be '1200 30 default', got '$(pdrive '' 1)'"
  [ "$(pdrive '700 20 row' 0)" = "700 20 row" ] && ok || bad "F3: a real answer must pass through, got '$(pdrive '700 20 row' 0)'"
else
  bad "F3: no '# >>> size threshold call' block in bin/lib/rb/plan.sh"
fi

# F4. the other guards. run-decompose.sh needs a model runner and pr.sh a PR to
# drive, so these pin the exact guard lines (each must exist exactly once).
cnt() { grep -cxF -- "$2" "$DIR/$1"; }
[ "$(cnt bin/run-decompose.sh 'MAXL="${5:-1200}"; MAXF="${6:-30}"')" = 1 ] && ok || bad "F4: run-decompose.sh default args must be 1200/30"
[ "$(cnt bin/run-decompose.sh 'case "$MAXL" in '"''"'|*[!0-9]*) MAXL=1200 ;; esac')" = 1 ] && ok || bad "F4: run-decompose.sh MAXL junk guard must be 1200"
[ "$(cnt bin/run-decompose.sh 'case "$MAXF" in '"''"'|*[!0-9]*) MAXF=30 ;; esac')" = 1 ] && ok || bad "F4: run-decompose.sh MAXF junk guard must be 30"
[ "$(cnt bin/lib/rb/pr.sh 'case "${SP_MAXL:-}" in '"''"'|*[!0-9]*) SP_MAXL=1200 ;; esac')" = 1 ] && ok || bad "F4: pr.sh SP_MAXL guard must be 1200"
OLD=$(grep -nE '(MAXL|MAXF|SG_MAXL|SG_MAXF|SP_MAXL)=(700|20)\b|:-700\}|:-20\}' \
  "$DIR/bin/size-gate.sh" "$DIR/bin/run-decompose.sh" "$DIR/bin/lib/rb/plan.sh" "$DIR/bin/lib/rb/pr.sh")
[ -z "$OLD" ] && ok || bad "F4: an old 700/20 fallback is left: $OLD"

# F5. the rows still win over the fallback
reset; cache '{"size_gate.lines":"700","size_gate.files":"20"}'
[ "$(th widget-os all)" = "700 20 row" ] && ok || bad "F5: fleet rows 700/20 must win, got '$(th widget-os all)'"
reset; cache '{"size_gate.lines.widget-os":"500"}'
[ "$(th widget-os all)" = "500 30 lines:row,files:default" ] && ok || bad "F5: a project row must win on its axis only, got '$(th widget-os all)'"
reset; cache '{"size_gate.lines.hotfix":"1500","size_gate.files.hotfix":"30"}'
[ "$(SIZE_TIER=hotfix th widget-os all)" = "1500 30 row:hotfix" ] && ok || bad "F5: the hotfix rows must win, got '$(SIZE_TIER=hotfix th widget-os all)'"

# F5b. a project row below the new default still wins and still splits
reset; cache '{"size_gate.lines.widget-os":"600"}'
read -r PL PF _ <<<"$(th widget-os all)"
splan 700 6
[ "$(sed -n 's/^SIZE_VERDICT: //p' <<<"$(gate "$PL" "$PF")")" = over ] && ok \
  || bad "F5b: a 600-line project row must split a 700-line plan (limits '$PL $PF')"

# F6. the composed fresh-install seed
SCH="$T/schema.sql"
if HARNESS_TEST_SANDBOX=1 "$DIR/bin/schema-build.sh" --root "$DIR" --worker jobs --to "$SCH" >/dev/null 2>&1 && [ -s "$SCH" ]; then
  ok
  if python3 -I -c 'import sqlite3' 2>/dev/null; then
    sq() { python3 -I -c 'import sqlite3,sys
c=sqlite3.connect(sys.argv[1]); q=sys.argv[2] or open(sys.argv[3]).read()
if q.lstrip().upper().startswith("SELECT"):
    print("\n".join("|".join(str(x) for x in r) for r in c.execute(q)))
else:
    c.executescript(q); c.commit()' "$@"; }
    DB="$T/fresh.db"
    sq "$DB" "" "$SCH" && ok || bad "F6: the composed schema must apply to an empty database"
    v() { sq "$DB" "SELECT value FROM settings WHERE key='$1'"; }
    [ "$(v size_gate.lines)" = 1200 ] && ok || bad "F6: size_gate.lines seeds '$(v size_gate.lines)', want 1200"
    [ "$(v size_gate.files)" = 30 ] && ok || bad "F6: size_gate.files seeds '$(v size_gate.files)', want 30"
    [ "$(v size_gate.lines.hotfix)" = 1500 ] && ok || bad "F6: the hotfix line seed must stay 1500"
    [ "$(v size_gate.files.hotfix)" = 30 ] && ok || bad "F6: the hotfix file seed must stay 30"
    sq "$DB" "UPDATE settings SET value='900', actor='operator' WHERE key='size_gate.lines'"
    sq "$DB" "" "$SCH" && ok || bad "F6: the composed schema must re-apply cleanly"
    [ "$(v size_gate.lines)" = 900 ] && ok || bad "F6: a re-apply must keep an operator's edit, got '$(v size_gate.lines)'"
  else
    echo "note: no python3 sqlite — F6 apply cases skipped"
  fi
else
  bad "F6: bin/schema-build.sh could not compose worker/jobs/schema.sql"
fi

# F7. the shipped `# >>> size gate` block with no rows, SIZE_GATE_ENFORCE=1.
#     1500 lines is past 1380 and reaches the decomposer; 900 continues.
awk '/^# >>> size gate/{f=1;next} /^# <<< size gate/{exit} f' "$RB_ALL" > "$T/sizeblock.sh"
awk '/^# >>> size enforce switch/{f=1;next} /^# <<< size enforce switch/{exit} f' "$RB_ALL" > "$T/switch.sh"
if [ -s "$T/sizeblock.sh" ] && [ -s "$T/switch.sh" ]; then
  g="$T/g"; mkdir -p "$g/bin" "$g/state" "$g/logs" "$g/flags" "$g/catalog"
  for S in bin/size-scope.sh bin/size-threshold.sh bin/size-gate.sh bin/planned-files.sh; do
    scratch_install_closure "$S" "$g" >/dev/null || bad "F7: could not install $S's closure"
  done
  printf '#!/bin/bash\necho "DECOMPOSER $5 $6" >> "%s/seq.txt"\nprintf "BH-9.1\\nBH-9.2\\n" > "$4/children.txt"\nexit 0\n' "$T" > "$g/bin/run-decompose.sh"
  chmod +x "$g/bin/run-decompose.sh"
  sdrive() { # sdrive <LINES> — the sequence lands in $T/seq.txt
    rm -rf "$T/sb"; mkdir -p "$T/sb/b"; : > "$T/seq.txt"
    printf '# Plan\n\n### Task 1\n- VALIDATE: npm test\n- SATISFIES: c1\n\n## Size\nFILES: 6\nLINES: %s\n\nKIND: feature\nSIZE: M\n' "$1" > "$T/sb/b/plan.md"
    ( env -u SIZE_TIER -u SIZE_LIMITS_SRC -u SIZE_GATE_TOLERANCE_PCT HARNESS="$g" BUILD="$T/sb/b" PROJECT=widget-os KEY=WD-9 \
          TICKET=tkt-1 BKEY=build:widget-os:WD-9:b ALERTS="$g/logs/ALERTS.log" JOB_ID=job-1 JOBS_URL= LANE_GATE_DISABLE=1 \
          SIZE_THRESHOLDS_CONF=/nonexistent SIZE_GATE_ENFORCE=1 SWITCHBLOCK="$T/switch.sh" SEQ="$T/seq.txt" \
      bash -c 'set -uo pipefail
               STAMP() { echo TS; }; BB() { :; }
               RESULT() { echo "RESULT $*" >> "$SEQ"; }
               job_artifact_put() { :; }
               . "$SWITCHBLOCK"
               . "$0"; echo CONTINUED >> "$SEQ"' "$T/sizeblock.sh" >/dev/null 2>&1 )
  }
  sdrive 1500
  grep -q '^DECOMPOSER 1200 30$' "$T/seq.txt" && ok || bad "F7: 1500 lines must reach the decomposer with 1200/30: $(cat "$T/seq.txt")"
  grep -q CONTINUED "$T/seq.txt" && bad "F7: a 1500-line plan must not reach EXECUTE: $(cat "$T/seq.txt")" || ok
  sdrive 900
  grep -q CONTINUED "$T/seq.txt" && ok || bad "F7: a 900-line plan must continue under 1200: $(cat "$T/seq.txt")"
  grep -q DECOMPOSER "$T/seq.txt" && bad "F7: a 900-line plan must not split: $(cat "$T/seq.txt")" || ok
else
  bad "F7: could not extract the size gate block or the size enforce switch"
fi

# F8. execute the shipped guard lines, not only their text (r4 pinned text).
#     pr.sh: the four lines from SP_LIMITS= to SP_BOUND=, with a fake
#     size-threshold.sh that answers nothing.
awk '/^SP_LIMITS=\$\(/{f=1} f{print} /^SP_BOUND=/{exit}' "$DIR/bin/lib/rb/pr.sh" > "$T/spblock.sh"
if [ "$(grep -vc '^#' "$T/spblock.sh")" = 4 ]; then
  mkdir -p "$T/sp/bin"
  printf '#!/bin/bash\nexit 1\n' > "$T/sp/bin/size-threshold.sh"; chmod +x "$T/sp/bin/size-threshold.sh"
  SP=$(HARNESS="$T/sp" PROJECT=widget-os bash -c '. "$1"; echo "$SP_MAXL $SP_BOUND"' _ "$T/spblock.sh" 2>/dev/null)
  [ "$SP" = "1200 2400" ] && ok || bad "F8: pr.sh with no answer must give SP_MAXL=1200 SP_BOUND=2400, got '$SP'"
  printf '#!/bin/bash\necho "800 25 row"\n' > "$T/sp/bin/size-threshold.sh"
  SP=$(HARNESS="$T/sp" PROJECT=widget-os bash -c '. "$1"; echo "$SP_MAXL $SP_BOUND"' _ "$T/spblock.sh" 2>/dev/null)
  [ "$SP" = "800 1600" ] && ok || bad "F8: pr.sh must pass a real answer through, got '$SP'"
else
  bad "F8: could not extract the SP_LIMITS..SP_BOUND lines from bin/lib/rb/pr.sh"
fi
#     run-decompose.sh: the PROJECT= line through the MAXF guard.
awk '/^PROJECT="\$\{1:\?project\}"/{f=1} f{print} /^case "\$MAXF" in/{exit}' "$DIR/bin/run-decompose.sh" > "$T/rdhead.sh"
if [ "$(grep -vc '^#' "$T/rdhead.sh")" = 4 ]; then
  rd() { bash -c '. "$0"; echo "$MAXL $MAXF"' "$T/rdhead.sh" "$@" 2>/dev/null; }
  [ "$(rd p t k b)" = "1200 30" ] && ok || bad "F8: run-decompose.sh with no limits must give 1200 30, got '$(rd p t k b)'"
  [ "$(rd p t k b banana x)" = "1200 30" ] && ok || bad "F8: run-decompose.sh junk limits must give 1200 30, got '$(rd p t k b banana x)'"
  [ "$(rd p t k b 900 12)" = "900 12" ] && ok || bad "F8: run-decompose.sh must pass real limits through, got '$(rd p t k b 900 12)'"
else
  bad "F8: could not extract the header lines of bin/run-decompose.sh"
fi
#     no 700/20 size fallback literal in any of the five product files
OLD=$(grep -nE '^(DEF_LINES|DEF_FILES)=(700|20)$|(MAXL|MAXF|SG_MAXL|SG_MAXF|SP_MAXL)=(700|20)\b|:-700\}|:-20\}' \
  "$DIR/bin/size-threshold.sh" "$DIR/bin/size-gate.sh" "$DIR/bin/run-decompose.sh" "$DIR/bin/lib/rb/plan.sh" "$DIR/bin/lib/rb/pr.sh")
[ -z "$OLD" ] && ok || bad "F8: a 700/20 size fallback literal is left: $OLD"
[ "$(grep -cxE 'DEF_LINES=1200|DEF_FILES=30' "$DIR/bin/size-threshold.sh")" = 2 ] && ok || bad "F8: bin/size-threshold.sh must set DEF_LINES=1200 and DEF_FILES=30"

# F9. the catalog's prose follows the numbers
CONF="$DIR/catalog/size-thresholds.conf"
grep -q 'seeded 1200/30' "$CONF" && ok || bad "F9: catalog/size-thresholds.conf must say the fleet rows are seeded 1200/30"
grep -qF '1200 lines / 30 files' "$CONF" && ok || bad "F9: catalog/size-thresholds.conf step 5 must be 1200 lines / 30 files"
STALE=$(grep -nE '700/20|700 lines' "$CONF" | grep -v 'Before 2026-10-14')
[ -z "$STALE" ] && ok || bad "F9: a 700/20 line outside the history line: $STALE"

echo "size-gate-fallbacks.bh-6025: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
