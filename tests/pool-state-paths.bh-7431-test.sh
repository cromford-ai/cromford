#!/bin/bash
# tests/pool-state-paths.bh-7431-test.sh — BH-7431 (BH-6896 S4): every state/
# path the pool tick names has a catalog row or a fly-pool snapshot-list line,
# and bin/pool-state-paths-lint.sh fails on one that has neither.
#
#   T1  catalog/state-paths.json has a row for each of the 14 paths the
#       BH-6896 note found with no row, plus dispatch-now and the sourced-lib
#       caches, each in a class the guard accepts (rows, cache, box-local),
#       and no new path is class rows
#   T2  bin/state-paths-guard.sh still loads the catalog: rc 0 on an empty
#       added-file list
#   T3  the lint decision table (plan, Failure modes), one fixture per row,
#       plus the trailing-dot, .wo and --trace shapes
#   T4  lint rc 2: catalog {}, catalog not JSON, target missing, manifest dir
#       missing; the escape hatch skips a miss only with a justification
#   T5  lri_paths fly-pool demo ro|rw rc 0 with no lri: line on stderr, and
#       the lri_member_ok accept and refuse table on the fly-pool lists
#   T6  the real lint on this repo: rc 0 and unclassified=0
#
# Every lint case runs the real script as a process and asserts its exact rc
# (0 clean, 1 a miss, 2 could not check), so a missing script's 127 never
# reads as a pass or a miss.
#
# Run from anywhere: tests/pool-state-paths.bh-7431-test.sh  (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LINT="$DIR/bin/pool-state-paths-lint.sh"
CATALOG="$DIR/catalog/state-paths.json"
MANI="$DIR/catalog/lane-run-inputs.d"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq missing"; exit 0; }
unset PR_LABELS GUARDRAIL_JUSTIFICATION SPG_FILES SPG_ROOT SPG_CATALOG

# ============================================================================
echo "T1: catalog rows for the pool's state/ paths"
for p in fly fly-cost quota pool-tailnet preplan-files auth-accounts.local.json \
         vercel-deploys overlap-after fly-onboard lane-gate gh-app-tokens gh-app-installations.json \
         gh-rest-ledger dispatch-now dispatch-mode hotfix-announced hold-ambiguous model-routes \
         alert-line-sent blind-list flags-cache; do
  c=$(jq -r --arg p "$p" '[.paths[] | select(.path == $p) | .class] | if length == 1 then .[0] else "count=\(length)" end' "$CATALOG" 2>/dev/null)
  case "$c" in
    cache|box-local) ok "T1 $p has one row, class $c" ;;
    rows) bad "T1 $p is class rows: no new path may be rows (the guard would block a new writer)" ;;
    *) bad "T1 $p: ${c:-catalog unreadable}" ;;
  esac
done
# remote-results went to class rows on main (BH-7429: pool_record_files rows);
# it is the one pre-existing rows path this suite names, so check it apart.
c=$(jq -r '[.paths[] | select(.path == "remote-results") | .class] | if length == 1 then .[0] else "count=\(length)" end' "$CATALOG" 2>/dev/null)
[ "$c" = rows ] && ok "T1 remote-results has one row, class rows (BH-7429)" || bad "T1 remote-results: ${c:-catalog unreadable}"
# The three rows whose notes the plan fixes name what the pool writes there.
NOTE=$(jq -r '.paths[] | select(.path == "pool") | .note' "$CATALOG" 2>/dev/null)
for w in .terminal-noted .terminal-alerted .after-since .after-released .after-loop .defer-to-human cap-wait \
         .hold-noted .pr-noted hold-cache pool_markers; do
  case "$NOTE" in *"$w"*) ok "T1 pool note names $w" ;; *) bad "T1 pool note lacks $w: $NOTE" ;; esac
done
NOTE=$(jq -r '.paths[] | select(.path == "fly-pool") | .note' "$CATALOG" 2>/dev/null)
for w in .snapmt .sweep.json legacy-caps; do
  case "$NOTE" in *"$w"*) ok "T1 fly-pool note names $w" ;; *) bad "T1 fly-pool note lacks $w: $NOTE" ;; esac
done
NOTE=$(jq -r '.paths[] | select(.path == "build-queue") | .note' "$CATALOG" 2>/dev/null)
for w in .failed.json .dispatched .json.bad ROWS_ONLY=0; do
  case "$NOTE" in *"$w"*) ok "T1 build-queue note names $w" ;; *) bad "T1 build-queue note lacks $w: $NOTE" ;; esac
done

# ============================================================================
echo "T2: the guard still loads the catalog"
: > "$T/empty.list"
OUT=$(SPG_FILES="$T/empty.list" SPG_ROOT="$T" "$DIR/bin/state-paths-guard.sh" 2>&1); RC=$?
[ "$RC" = 0 ] && ok "T2 state-paths-guard rc 0 on an empty list ($OUT)" || bad "T2 state-paths-guard rc=$RC: $OUT"

# ============================================================================
echo "T3: the lint decision table"
# A fixture catalog with one rows path and a manifest dir per case shape.
FXC="$T/fx-catalog.json"
printf '%s\n' '{"version":1,"paths":[{"path":"pool","class":"rows","authority":"x","note":""}]}' > "$FXC"
mkdir -p "$T/m-none" "$T/m-man" "$T/m-comment" "$T/m-wo"
printf '%s\n' '# a fixture manifest' 'state/zz-man/$p/*' > "$T/m-man/fly-pool.rw"
printf '%s\n' '# state/zz-man/$p/*' > "$T/m-comment/fly-pool.rw"
printf '%s\n' 'state/zz-wo/$p/*' > "$T/m-wo/fly-pool.wo"
N3=0
# lint_case <name> <manifest-dir> <want-rc> <line> — one fixture script of one line.
lint_case() {
  local name="$1" md="$2" want="$3" line="$4" f
  N3=$((N3 + 1)); f="$T/fx/$N3.sh"; mkdir -p "$T/fx"
  printf '#!/bin/bash\n%s\n' "$line" > "$f"
  OUT=$("$LINT" --file "$f" --catalog "$FXC" --manifests "$T/$md" 2>&1); RC=$?
  if [ "$RC" != "$want" ]; then bad "T3 $name: rc=$RC want $want :: $OUT"; return; fi
  if [ "$want" = 1 ]; then
    grep -qF "($f:2)" <<<"$OUT" && [[ "$(tail -n 1 <<<"$OUT")" == "pool-state-paths: unclassified=1 checked="* ]] \
      && ok "T3 $name: miss rc 1, file:line named" || bad "T3 $name: output :: $OUT"
  else
    [[ "$(tail -n 1 <<<"$OUT")" == "pool-state-paths: unclassified=0 checked="* ]] && ! grep -q UNCLASSIFIED <<<"$OUT" \
      && ok "T3 $name: pass rc 0" || bad "T3 $name: output :: $OUT"
  fi
}
lint_case "redirect into a new path"      m-none    1 'printf x > "$HARNESS/state/zz-new/$P/k"'
grep -qF 'UNCLASSIFIED state/zz-new (' <<<"$OUT" && ok "T3 the miss line names state/zz-new" || bad "T3 miss line :: $OUT"
lint_case "assignment only"               m-none    1 'ZZ="$HARNESS/state/zz-new"'
lint_case "a top-level file"              m-none    1 'jq . "$HARNESS/state/zz-file.json"'
grep -qF 'UNCLASSIFIED state/zz-file.json (' <<<"$OUT" && ok "T3 the file seg is named whole" || bad "T3 file seg :: $OUT"
lint_case "near miss of row pool"         m-none    1 'ls "$H/state/pool-stats/x"'
grep -qF 'UNCLASSIFIED state/pool-stats (' <<<"$OUT" && ok "T3 pool-stats is not pool" || bad "T3 pool-stats :: $OUT"
lint_case "a comment"                     m-none    0 '  # state/zz-new'
lint_case "the machine root"              m-none    0 'mput "$m" f /data/harness/state/zz-new.txt'
lint_case "a catalog row"                 m-none    0 'touch "$H/state/pool/$P/k.held"'
lint_case "a manifest line (.rw)"         m-man     0 'cat "$H/state/zz-man/$P/x"'
lint_case "a commented manifest line"     m-comment 1 'cat "$H/state/zz-man/$P/x"'
lint_case "a manifest line (.wo)"         m-wo      0 'cat "$H/state/zz-wo/$P/x"'
lint_case "a sentence-final dot"          m-none    0 'say "parked in state/pool."'
lint_case "state/ inside a longer word"   m-none    0 'x=/tmp/mystate/zz-new'
# Two misses and a pass on one line: each miss is one line, each token counted.
lint_case_two() {
  local f="$T/fx/two.sh"
  printf '#!/bin/bash\n%s\n' 'cp "$H/state/zz-a/x" "$H/state/zz-b/y" "$H/state/pool/z"' > "$f"
  OUT=$("$LINT" --file "$f" --catalog "$FXC" --manifests "$T/m-none" 2>&1); RC=$?
  [ "$RC" = 1 ] && [ "$(grep -c '^UNCLASSIFIED ' <<<"$OUT")" = 2 ] \
    && [ "$(tail -n 1 <<<"$OUT")" = "pool-state-paths: unclassified=2 checked=3" ] \
    && ok "T3 two misses and a pass on one line: unclassified=2 checked=3" || bad "T3 two on a line rc=$RC :: $OUT"
}
lint_case_two
# --trace: a normalised trace list, state/ lines only, a state TAB prefix allowed.
printf '%s\n' $'idle\tstate/pool/<p>/<KEY>.spawns' 'logs/fly-pool.log' 'state/zz-trace/<p>/x' > "$T/trace.txt"
OUT=$("$LINT" --trace "$T/trace.txt" --catalog "$FXC" --manifests "$T/m-none" 2>&1); RC=$?
[ "$RC" = 1 ] && grep -qF "UNCLASSIFIED state/zz-trace ($T/trace.txt:3)" <<<"$OUT" \
  && [ "$(tail -n 1 <<<"$OUT")" = "pool-state-paths: unclassified=1 checked=2" ] \
  && ok "T3 --trace: one miss, the logs/ line not checked" || bad "T3 --trace rc=$RC :: $OUT"
printf '%s\n' 'state/pool/<p>/<KEY>.spawns' 'flags/alerted-x' > "$T/trace-ok.txt"
OUT=$("$LINT" --trace "$T/trace-ok.txt" --catalog "$FXC" --manifests "$T/m-none" 2>&1); RC=$?
[ "$RC" = 0 ] && [ "$(tail -n 1 <<<"$OUT")" = "pool-state-paths: unclassified=0 checked=1" ] \
  && ok "T3 --trace: a clean trace is rc 0" || bad "T3 --trace clean rc=$RC :: $OUT"

# ============================================================================
echo "T4: could not check, and the escape hatch"
printf '#!/bin/bash\ntouch "$H/state/zz-new/x"\n' > "$T/miss.sh"
printf '{}\n' > "$T/c-empty.json"
OUT=$("$LINT" --file "$T/miss.sh" --catalog "$T/c-empty.json" --manifests "$T/m-none" 2>&1); RC=$?
[ "$RC" = 2 ] && ok "T4 catalog {} is rc 2" || bad "T4 catalog {} rc=$RC :: $OUT"
printf 'not json\n' > "$T/c-bad.json"
OUT=$("$LINT" --file "$T/miss.sh" --catalog "$T/c-bad.json" --manifests "$T/m-none" 2>&1); RC=$?
[ "$RC" = 2 ] && ok "T4 a catalog that is not JSON is rc 2" || bad "T4 bad JSON rc=$RC :: $OUT"
OUT=$("$LINT" --file "$T/miss.sh" --catalog "$T/no-such.json" --manifests "$T/m-none" 2>&1); RC=$?
[ "$RC" = 2 ] && ok "T4 a missing catalog is rc 2" || bad "T4 missing catalog rc=$RC :: $OUT"
OUT=$("$LINT" --file "$T/no-such.sh" --catalog "$FXC" --manifests "$T/m-none" 2>&1); RC=$?
[ "$RC" = 2 ] && ok "T4 a missing target is rc 2" || bad "T4 missing target rc=$RC :: $OUT"
OUT=$("$LINT" --trace "$T/no-such.txt" --catalog "$FXC" --manifests "$T/m-none" 2>&1); RC=$?
[ "$RC" = 2 ] && ok "T4 a missing trace is rc 2" || bad "T4 missing trace rc=$RC :: $OUT"
OUT=$("$LINT" --file "$T/miss.sh" --catalog "$FXC" --manifests "$T/no-such-dir" 2>&1); RC=$?
[ "$RC" = 2 ] && ok "T4 a missing manifest dir is rc 2" || bad "T4 missing manifest dir rc=$RC :: $OUT"
OUT=$("$LINT" --bogus 2>&1); RC=$?
[ "$RC" = 2 ] && ok "T4 an unknown option is rc 2" || bad "T4 unknown option rc=$RC :: $OUT"
OUT=$(PR_LABELS=skip-guardrail GUARDRAIL_JUSTIFICATION='Guardrail-Justification: a fixture miss proven harmless here' \
      "$LINT" --file "$T/miss.sh" --catalog "$FXC" --manifests "$T/m-none" 2>&1); RC=$?
[ "$RC" = 0 ] && grep -q SKIPPED <<<"$OUT" && ok "T4 label + justification skips (rc 0)" || bad "T4 hatch rc=$RC :: $OUT"
OUT=$(PR_LABELS=skip-guardrail "$LINT" --file "$T/miss.sh" --catalog "$FXC" --manifests "$T/m-none" 2>&1); RC=$?
[ "$RC" = 1 ] && ok "T4 the label alone does not skip (rc 1)" || bad "T4 label alone rc=$RC :: $OUT"

# ============================================================================
echo "T5: the fly-pool snapshot lists parse and classify"
LIB="$DIR/bin/lib/lane-run-inputs.sh"
setting_get() { return 1; }
L() { ( export HARNESS="$T/none" FLEET_CONF="$T/fleet.conf"; . "$LIB" || exit 99; "$@" ); }
printf 'demo o/demo - - 2 box-a 192.0.2.1\n' > "$T/fleet.conf"
for m in ro rw; do
  [ -f "$MANI/fly-pool.$m" ] || { bad "T5 catalog/lane-run-inputs.d/fly-pool.$m is missing"; continue; }
  OUT=$(L lri_paths fly-pool demo "$m" 2>"$T/lri.err"); RC=$?
  [ "$RC" = 0 ] && [ -n "$OUT" ] && ! grep -q 'lri:' "$T/lri.err" \
    && ok "T5 lri_paths fly-pool demo $m rc 0, no lri: line" || bad "T5 lri_paths $m rc=$RC err=$(cat "$T/lri.err")"
done
OUT=$(L lri_paths fly-pool demo ro 2>/dev/null)
for want in 'state/preplan-files/demo-*' 'state/dispatch-now/demo/*' 'state/fly/demo.json' 'state/overlap-after/demo/*'; do
  grep -qxF -- "$want" <<<"$OUT" && ok "T5 ro lists $want" || bad "T5 ro lacks $want"
done
# member <want-rc> <relpath> <mode>
member() {
  L lri_member_ok demo "$2" - "$3" fly-pool; local rc=$?
  [ "$rc" = "$1" ] && ok "T5 lri_member_ok $2 $3 rc $rc" || bad "T5 lri_member_ok $2 $3 rc=$rc want $1"
}
member 0 state/pool/demo/BH-1.after-since rw
member 0 state/pool/demo/BH-1.defer-to-human rw
member 0 state/pool/demo/hold-cache/1.json rw
member 0 state/fly-pool/demo/abc.json rw
member 0 state/remote-results/demo/BH-1.json rw
member 0 state/preplan-files/demo-BH-1 ro
member 0 state/dispatch-now/demo/BH-1 ro
member 1 state/preplan-files/demo-BH-1 rw
member 1 state/dispatch-now/demo/BH-1 rw
member 1 state/pool/other/BH-1.after-since rw
member 1 state/quota/leases/a/b ro
member 1 state/fly-onboard/demo.n ro
member 1 state/lane-gate/x.json ro

# ============================================================================
echo "T6: the real lint on this repo"
OUT=$("$LINT" 2>&1); RC=$?
LAST=$(tail -n 1 <<<"$OUT")
[ "$RC" = 0 ] && [[ $LAST =~ ^pool-state-paths:\ unclassified=0\ checked=[1-9][0-9]*$ ]] \
  && ok "T6 $LAST (rc 0)" || bad "T6 rc=$RC :: $OUT"
# The default target is bin/fly-pool.sh (named here, so bin/test-impact.sh
# selects this suite for any diff to it).
OUT2=$("$LINT" --file "$DIR/bin/fly-pool.sh" 2>&1); RC2=$?
[ "$RC2" = "$RC" ] && [ "$OUT2" = "$OUT" ] && ok "T6 the default target is bin/fly-pool.sh" \
  || bad "T6 --file bin/fly-pool.sh rc=$RC2 differs from the default :: $OUT2"

echo
echo "pool-state-paths.bh-7431: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
