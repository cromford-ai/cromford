#!/bin/bash
# tests/ph-sections-ownership.bh-6616-test.sh — a `--sections` run owns only the
# namespaces it selected, and reads every carry from the ACTIVE it reads under
# the state/health-active.txt.lock it writes under (BH-6616).
#
# Drives the REAL bin/pipeline-health.sh in a tests/lib/ph-sections-fixture.sh
# tree. The window hook: this suite writes its own bin/lib/wake-armed-watch.sh,
# whose wake_armed_watch_eval runs $HARNESS/during.sh (if present) and answers
# "SKIP off". The wake-armed block runs after every section and before the
# epilogue, so during.sh is a project run's epilogue that lands in the window:
# it takes the ACTIVE lock and rewrites ACTIVE.
#   AT-1  a key a project run adds in the window (unselected namespace) is kept
#   AT-2  a key a project run retracts in the window (unselected namespace)
#         stays retracted, with no RESOLVED line from this run
#   AT-3  a stalepr skip carry does not bring back a key retracted in the window
#   AT-3b the same for the budget-low stalepr prefix carry
#   AT-4  a leadunqueued prefix carry keeps only the keys still in ACTIVE, and
#         no carry marker reaches ACTIVE
#   AT-5  overlap edge: a selected-namespace key added in the window is retracted
#         with a RESOLVED line, never dropped silently
#   AT-6  control (no window): every key stays, no resolve, no temp file left
#   AT-7  the exact carry stays exact: +=stalepr:ts never carries stalepr:tsx
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/ph-sections-ownership.bh-6616-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/ph-sections-fixture.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null && command -v python3 >/dev/null && command -v flock >/dev/null \
  || { echo "jq/python3/flock missing — skipping"; exit 0; }

# mk <dir> <seed> — a tree with the window hook and ACTIVE seeded.
mk() {
  local d="$1"; phs_mktree "$d"
  cat > "$d/bin/lib/wake-armed-watch.sh" <<'WA'
wake_armed_watch_eval() {
  [ -x "$HARNESS/during.sh" ] && "$HARNESS/during.sh" >/dev/null 2>&1
  echo "SKIP off"
}
WA
  echo '[]' > "$d/prs-r.json"
  printf '%s\n' "$2" > "$d/state/health-active.txt"
}
# during <dir> <sed-expr> — the project run that lands in the window: under the
# ACTIVE lock it rewrites ACTIVE with the sed expression.
during() {
  cat > "$1/during.sh" <<DU
#!/bin/bash
A="\$HARNESS/state/health-active.txt"
{ flock -w 5 6; sed -e '$2' "\$A" > "\$A.dur"; mv -f "\$A.dur" "\$A"; } 6>"\$A.lock"
DU
  chmod +x "$1/during.sh"
}
ph() { # ph <dir> [args...] — one REAL pipeline-health run; RC is its exit code
  local d="$1"; shift
  ( export HARNESS="$d"; phs_env; export LEAD_REVIEW_AUTO_REPOS=o/r WAKE_ARMED_WATCH_S=3600
    "$DIR/bin/pipeline-health.sh" "$@" ) >/dev/null 2>"$d/err.txt"
  RC=$?
}
has_line() { grep -qxF "$2" "$1/state/health-active.txt"; }
act() { tr '\n' ' ' < "$1/state/health-active.txt"; }
resolved_line() { grep -qF "RESOLVED $2 " "$1/logs/pipeline-health.log" 2>/dev/null; }
# open_stalepr <dir> — a stale run opens the ph-stalepr_ts console row, then the
# PR list goes clean (the same setup as tests/ph-sections-filter.bh-4055-test.sh).
open_stalepr() {
  printf '[%s]\n' "$(phs_pr 50)" > "$1/prs-r.json"
  ph "$1" --sections stalepr
  grep -qxF ph-stalepr_ts "$1/open.ids" 2>/dev/null || bad "setup: the stale run did not open ph-stalepr_ts: $(cat "$1/err.txt")"
  echo '[]' > "$1/prs-r.json"
}

echo "--- AT-1: a key a project run adds in the window is kept"
D="$T/at1"; mk "$D" 'stalepr:ts'; open_stalepr "$D"
printf '%s\n' stalepr:ts stuckqueue:x > "$D/state/health-active.txt"
during "$D" '$a stuckqueue:ts:new'
ph "$D" --sections stalepr
[ "$RC" = 0 ] && ok || bad "AT-1: rc=$RC err=$(cat "$D/err.txt")"
has_line "$D" stuckqueue:ts:new && ok || bad "AT-1: stuckqueue:ts:new dropped from ACTIVE: $(act "$D")"
has_line "$D" stuckqueue:x && ok || bad "AT-1: stuckqueue:x dropped from ACTIVE: $(act "$D")"
has_line "$D" stalepr:ts && bad "AT-1: stalepr:ts still active" || ok
phs_resolved "$D" | grep -qxF alert:ph-stalepr_ts && ok || bad "AT-1: no resolve for alert:ph-stalepr_ts: '$(phs_resolved "$D" | tr '\n' ' ')'"

echo "--- AT-2: a key a project run retracts in the window stays retracted"
D="$T/at2"; mk "$D" $'stuckqueue:x\ntmpfull:root'
during "$D" '/^stuckqueue:x$/d'
ph "$D" --sections stalepr
[ "$RC" = 0 ] && ok || bad "AT-2: rc=$RC err=$(cat "$D/err.txt")"
has_line "$D" stuckqueue:x && bad "AT-2: stuckqueue:x came back: $(act "$D")" || ok
has_line "$D" tmpfull:root && ok || bad "AT-2: tmpfull:root dropped: $(act "$D")"
resolved_line "$D" stuckqueue:x && bad "AT-2: this run wrote RESOLVED stuckqueue:x" || ok

echo "--- AT-3: a stalepr skip carry does not bring back a retracted key"
D="$T/at3"; mk "$D" 'stalepr:ts'
touch "$D/listfail"
during "$D" '/^stalepr:ts$/d'
ph "$D" --sections stalepr
[ "$RC" = 0 ] && ok || bad "AT-3: rc=$RC err=$(cat "$D/err.txt")"
has_line "$D" stalepr:ts && bad "AT-3: stalepr:ts came back: $(act "$D")" || ok
[ -z "$(phs_resolved "$D")" ] && ok || bad "AT-3: resolve sent: $(phs_resolved "$D")"
grep -q '^+' "$D/state/health-active.txt" && bad "AT-3: a carry marker reached ACTIVE: $(act "$D")" || ok

echo "--- AT-3b: the budget-low stalepr carry keeps only the keys still in ACTIVE"
D="$T/at3b"; mk "$D" $'stalepr:ts\nstalepr:zz'
during "$D" '/^stalepr:ts$/d'
( export HARNESS="$D" GH_BUDGET_CORE_REMAINING=100; phs_env; export LEAD_REVIEW_AUTO_REPOS=o/r WAKE_ARMED_WATCH_S=3600
  "$DIR/bin/pipeline-health.sh" --sections stalepr ) >/dev/null 2>"$D/err.txt"; RC=$?
[ "$RC" = 0 ] && ok || bad "AT-3b: rc=$RC err=$(cat "$D/err.txt")"
has_line "$D" stalepr:zz && ok || bad "AT-3b: stalepr:zz dropped: $(act "$D")"
has_line "$D" stalepr:ts && bad "AT-3b: stalepr:ts came back: $(act "$D")" || ok
grep -q '^+' "$D/state/health-active.txt" && bad "AT-3b: a carry marker reached ACTIVE: $(act "$D")" || ok

echo "--- AT-4: a prefix carry keeps only the keys still in ACTIVE"
D="$T/at4"; mk "$D" $'leadunqueued:o/r#5:aaa\nleadunqueued:o/r#6:bbb'
during "$D" '/^leadunqueued:o\/r#6:bbb$/d'
( export HARNESS="$D" GH_BUDGET_CORE_REMAINING=100; phs_env; export LEAD_REVIEW_AUTO_REPOS=o/r WAKE_ARMED_WATCH_S=3600
  "$DIR/bin/pipeline-health.sh" --sections leadunqueued ) >/dev/null 2>"$D/err.txt"; RC=$?
[ "$RC" = 0 ] && ok || bad "AT-4: rc=$RC err=$(cat "$D/err.txt")"
has_line "$D" 'leadunqueued:o/r#5:aaa' && ok || bad "AT-4: #5 dropped: $(act "$D")"
has_line "$D" 'leadunqueued:o/r#6:bbb' && bad "AT-4: #6 came back: $(act "$D")" || ok
grep -q '^+' "$D/state/health-active.txt" && bad "AT-4: a carry marker reached ACTIVE: $(act "$D")" || ok
[ -z "$(phs_resolved "$D")" ] && ok || bad "AT-4: resolve sent: $(phs_resolved "$D")"

echo "--- AT-5: overlap edge: a selected key added in the window is retracted with a line"
D="$T/at5"; mk "$D" 'stalepr:ts'
during "$D" '$a stalepr:ts2'
ph "$D" --sections stalepr
[ "$RC" = 0 ] && ok || bad "AT-5: rc=$RC err=$(cat "$D/err.txt")"
has_line "$D" stalepr:ts2 && bad "AT-5: stalepr:ts2 kept: $(act "$D")" || ok
resolved_line "$D" stalepr:ts2 && ok || bad "AT-5: no RESOLVED stalepr:ts2 line"

echo "--- AT-6: control, no window: every key stays"
D="$T/at6"; mk "$D" $'stalepr:ts\nstuckqueue:x\nleadunqueued:o/r#5:abc'
touch "$D/listfail"
ph "$D" --sections stalepr,leadunqueued
[ "$RC" = 0 ] && ok || bad "AT-6: rc=$RC"
for K in stalepr:ts stuckqueue:x 'leadunqueued:o/r#5:abc'; do
  has_line "$D" "$K" && ok || bad "AT-6: $K dropped: $(act "$D")"
done
[ -z "$(phs_resolved "$D")" ] && ok || bad "AT-6: resolve sent: $(phs_resolved "$D")"
[ ! -s "$D/err.txt" ] && ok || bad "AT-6: stderr: $(cat "$D/err.txt")"
ls "$D/state/health-fired."* >/dev/null 2>&1 && bad "AT-6: a health-fired temp file was left behind" || ok
[ "$(wc -l < "$D/state/health-active.txt")" = 3 ] && ok || bad "AT-6: ACTIVE has extra lines: $(act "$D")"

echo "--- AT-7: the exact carry stays exact"
D="$T/at7"; mk "$D" 'stalepr:tsx'
touch "$D/listfail"
ph "$D" --sections stalepr
[ "$RC" = 0 ] && ok || bad "AT-7: rc=$RC"
has_line "$D" stalepr:tsx && bad "AT-7: stalepr:tsx carried by +=stalepr:ts" || ok
resolved_line "$D" stalepr:tsx && ok || bad "AT-7: no RESOLVED stalepr:tsx line"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
