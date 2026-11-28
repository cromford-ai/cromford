#!/bin/bash
# tests/onboard-canary-gate.bh-9442-test.sh — BH-9442: the onboarding canary
# build gate, bin/lib/rb/gates.d/onboard-canary.sh, sourced by rb_gate_prelude
# in bin/lib/rb/gates.sh by one call line.
#
# A project whose settings row onboard.<p>.canary_gate reads `held` (written by
# bin/onboard-canary.sh --hold at onboarding) does not build until its canary PR
# is green in the repo's own CI, or an operator writes the override row.
#
#   P1 gates.sh holds exactly one call line for onboard-canary.sh, after
#      `# <<< dispatch mode gate` and before `# >>> budget launch gate`
#   G1 held, no override -> RESULT `BUILD_DEFERRED onboard-canary held: <state>
#      <sha12>`, exit 3, one line in pipeline.log and in logs/<p>.log  (REPRO)
#   G2 released -> admitted, no RESULT
#   G3 no row (every project already in the fleet) -> admitted
#   G4 held + override row -> admitted, one pipeline.log line names the override
#   G5 BUILDER_EXEC=1, and a resume -> admitted with 0 settings reads
#   G6 unreadable gate row (jobs client rc 1, or no jobs client rc 127) ->
#      ADMITTED with one pipeline line "onboard-canary unverifiable: gate row
#      unreadable (rc N); admitted": the gate runs for every build of every
#      project, so a deferral here would turn one jobs-worker outage into a
#      fleet-wide build stop. A readable `held` row still defers (G1, G6c).
#   G7 held + an override row that is only whitespace -> deferred
#
# Each case runs the call line the way rb_gate_prelude does: `.` in a function
# scope with RB_GATES_D set, under `set -u`, and a stub jobs client.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/onboard-canary-gate.bh-9442-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

G="$DIR/bin/lib/rb/gates.sh"
FRAG="$DIR/bin/lib/rb/gates.d/onboard-canary.sh"

# ══ P1: the call line and its place ═════════════════════════════════════════
n=$(grep -cx '\. "\$RB_GATES_D/onboard-canary.sh"' "$G")
cl=$(grep -nx '\. "\$RB_GATES_D/onboard-canary.sh"' "$G" | head -1 | cut -d: -f1)
dm=$(grep -n '^# <<< dispatch mode gate' "$G" | head -1 | cut -d: -f1)
bg=$(grep -n '^# >>> budget launch gate' "$G" | head -1 | cut -d: -f1)
if [ "$n" = 1 ] && [ -n "$dm" ] && [ -n "$bg" ] && [ "${cl:-0}" -gt "$dm" ] && [ "${cl:-0}" -lt "$bg" ]; then ok
else bad "P1 want one call line between dispatch mode ($dm) and budget ($bg); got $n at ${cl:-none}"; fi

# The prelude's chain as it runs today: every call line of gates.sh from the
# dispatch mode gate to the budget gate, in order. Without the fragment this
# chain holds no onboard-canary step and the build is admitted (the defect).
CHAIN="$T/chain.sh"
awk -v a="${dm:-0}" -v b="${bg:-0}" 'NR>a && NR<b && /^\. "\$RB_GATES_D\/[a-z0-9-]+\.sh"$/' "$G" > "$CHAIN"

# ══ Stubs ═══════════════════════════════════════════════════════════════════
H="$T/h"; mkdir -p "$H/bin" "$H/logs" "$T/rows"
cat > "$H/bin/jobs-client.sh" <<EOF
#!/bin/bash
# A file-backed settings stub: rows/<key> holds the value; rows/.rc forces an rc.
echo "\$*" >> "$T/jc.log"
[ "\$1" = setting-get ] || exit 2
[ -f "$T/rows/.rc" ] && exit "\$(cat "$T/rows/.rc")"
[ -f "$T/rows/\$2" ] || { echo; exit 2; }
cat "$T/rows/\$2"; echo
EOF
chmod +x "$H/bin/jobs-client.sh"

# run_gate <project> [env assignments...] — sets OUT (stdout), RC, RES (the RESULT text).
run_gate() {
  local p="$1"; shift
  rm -rf "$T/b"; mkdir -p "$T/b"; : > "$T/jc.log"; rm -f "$T/result"
  OUT=$(cd "$T" && env -u BUILDER_EXEC -u RESUME_BUILD "$@" bash -u -c '
    STAMP() { echo 2026-11-10T00:00:00Z; }
    RESULT() { printf "%s\n" "$1" > "'"$T"'/result"; }
    stage() {
      RB_GATES_D="'"$DIR"'/bin/lib/rb/gates.d"
      . "'"$CHAIN"'"
      echo ADMITTED
    }
    stage' 2>&1); RC=$?
  RES=$(cat "$T/result" 2>/dev/null)
}
BASE_ENV=(HARNESS="$H" BUILD="$T/b" KEY=K-1)
SHA=0123456789abcdef0123456789abcdef01234567

# ══ G1: held, no override -> deferred (the REPRO) ═══════════════════════════
rm -f "$T/rows/"*
P=g1-proj
echo held > "$T/rows/onboard.$P.canary_gate"
printf '{"state":"red","pr":7,"sha":"%s","at":1,"mode":"hold"}' "$SHA" > "$T/rows/onboard.$P.canary"
run_gate "$P" "${BASE_ENV[@]}" PROJECT="$P"
if [ "$RC" = 3 ] && ! grep -q ADMITTED <<<"$OUT" && [ "$RES" = "BUILD_DEFERRED onboard-canary held: red 0123456789ab" ]; then ok
else bad "G1 held must defer: rc=$RC result='$RES' out=$OUT"; fi
[ "$(grep -c 'onboard-canary held' "$T/b/pipeline.log" 2>/dev/null)" = 1 ] && ok || bad "G1 want 1 pipeline.log line"
[ "$(grep -c 'onboard-canary held' "$H/logs/$P.log" 2>/dev/null)" = 1 ] && ok || bad "G1 want 1 line in logs/$P.log"

# ══ G2: released -> admitted ════════════════════════════════════════════════
rm -f "$T/rows/"*; P=g2-proj
echo released > "$T/rows/onboard.$P.canary_gate"
run_gate "$P" "${BASE_ENV[@]}" PROJECT="$P"
[ "$RC" = 0 ] && grep -q ADMITTED <<<"$OUT" && [ -z "$RES" ] && ok || bad "G2 released must admit: rc=$RC res='$RES' out=$OUT"

# ══ G3: no row -> admitted ══════════════════════════════════════════════════
rm -f "$T/rows/"*; P=g3-proj
run_gate "$P" "${BASE_ENV[@]}" PROJECT="$P"
[ "$RC" = 0 ] && grep -q ADMITTED <<<"$OUT" && [ -z "$RES" ] && ok || bad "G3 no row must admit: rc=$RC res='$RES' out=$OUT"

# ══ G4: held + override -> admitted, one log line ═══════════════════════════
rm -f "$T/rows/"*; P=g4-proj
echo held > "$T/rows/onboard.$P.canary_gate"
echo "repo has no CI, accepted by operator" > "$T/rows/onboard.$P.canary_override"
run_gate "$P" "${BASE_ENV[@]}" PROJECT="$P"
[ "$RC" = 0 ] && grep -q ADMITTED <<<"$OUT" && [ -z "$RES" ] && ok || bad "G4 override must admit: rc=$RC res='$RES'"
[ "$(grep -c 'override' "$T/b/pipeline.log" 2>/dev/null)" = 1 ] && ok || bad "G4 want 1 override line in pipeline.log"

# ══ G5: pool machine and resume -> admitted, no read ════════════════════════
rm -f "$T/rows/"*; P=g5-proj
echo held > "$T/rows/onboard.$P.canary_gate"
run_gate "$P" "${BASE_ENV[@]}" PROJECT="$P" BUILDER_EXEC=1
[ "$RC" = 0 ] && grep -q ADMITTED <<<"$OUT" && [ ! -s "$T/jc.log" ] && ok || bad "G5 BUILDER_EXEC=1 must admit with 0 reads: rc=$RC reads=$(cat "$T/jc.log")"
run_gate "$P" "${BASE_ENV[@]}" PROJECT="$P" RESUME_BUILD=/x
[ "$RC" = 0 ] && grep -q ADMITTED <<<"$OUT" && [ ! -s "$T/jc.log" ] && ok || bad "G5 a resume must admit with 0 reads: rc=$RC"

# ══ G6: unreadable -> admitted with one line (no fleet-wide stop) ══════════
rm -f "$T/rows/"*; P=g6-proj
echo held > "$T/rows/onboard.$P.canary_gate"
echo 1 > "$T/rows/.rc"
run_gate "$P" "${BASE_ENV[@]}" PROJECT="$P"
[ "$RC" = 0 ] && grep -q ADMITTED <<<"$OUT" && [ -z "$RES" ] && ok || bad "G6 unreadable (rc 1) must admit: rc=$RC res='$RES' out=$OUT"
[ "$(grep -c 'onboard-canary unverifiable: gate row unreadable (rc 1); admitted' "$T/b/pipeline.log" 2>/dev/null)" = 1 ] \
  && [ "$(wc -l < "$T/b/pipeline.log")" -eq 1 ] && ok || bad "G6 want exactly 1 unverifiable line: $(cat "$T/b/pipeline.log" 2>/dev/null)"
rm -f "$T/rows/.rc"
H6="$T/h6"; mkdir -p "$H6/logs"
run_gate "$P" HARNESS="$H6" BUILD="$T/b" KEY=K-1 PROJECT="$P"
[ "$RC" = 0 ] && grep -q ADMITTED <<<"$OUT" && [ -z "$RES" ] && ok || bad "G6 no jobs client (rc 127) must admit: rc=$RC res='$RES'"
[ "$(grep -c 'onboard-canary unverifiable: gate row unreadable (rc 127); admitted' "$T/b/pipeline.log" 2>/dev/null)" = 1 ] \
  && [ "$(wc -l < "$T/b/pipeline.log")" -eq 1 ] && ok || bad "G6 rc 127 want exactly 1 line: $(cat "$T/b/pipeline.log" 2>/dev/null)"
# G6c: the same project, readable `held` row, still defers
run_gate "$P" "${BASE_ENV[@]}" PROJECT="$P"
[ "$RC" = 3 ] && ! grep -q ADMITTED <<<"$OUT" && [ "$RES" = "BUILD_DEFERRED onboard-canary held: - -" ] && ok || bad "G6c a readable held row must defer: rc=$RC res='$RES'"

# ══ G7: an empty override does not release ══════════════════════════════════
rm -f "$T/rows/"*; P=g7-proj
echo held > "$T/rows/onboard.$P.canary_gate"
printf '   ' > "$T/rows/onboard.$P.canary_override"
run_gate "$P" "${BASE_ENV[@]}" PROJECT="$P"
[ "$RC" = 3 ] && [ "$RES" = "BUILD_DEFERRED onboard-canary held: - -" ] && ok || bad "G7 empty override must defer: rc=$RC res='$RES'"

echo "onboard-canary-gate (BH-9442): $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
