#!/bin/bash
# tests/rb-gates-fragments.bh-8957-test.sh — BH-8957 (slice C1 of BH-8930):
# BH-7876's daily-ceiling check and the two gate blocks BH-7921 edits live in
# bin/lib/rb/gates.d/, each sourced at its old place by one call line.
#
# What is proved here:
#   R1 gates.sh holds exactly one call line for project-ceiling.sh,
#      closed-issue-skip.sh and issue-created-at.sh, and none of their code;
#   R2 each call line sits at the old place of its block;
#   R3 the rb_all flatten carries each marker pair once, in the old order, and
#      holds no call line;
#   R4 the flatten of the three regions equals the base tree's inline text,
#      minus the two new `project daily ceiling` marker lines;
#   R5 DRIVEN: the raw `budget launch gate` block with RB_GATES_D set defers on
#      a refusing pc_launch_check (exit 3, no ADMITTED) and admits on a passing
#      one; rb_gates_d_check defers when project-ceiling.sh is missing.
# Run from anywhere: tests/rb-gates-fragments.bh-8957-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

G="$DIR/bin/lib/rb/gates.sh"
GD="$DIR/bin/lib/rb/gates.d"
gln() { grep -nxF -- "$1" "$G" | head -1 | cut -d: -f1; }

# ══ R1: one call line each, no inline code left ═════════════════════════════
for f in project-ceiling closed-issue-skip issue-created-at; do
  n=$(grep -cxF ". \"\$RB_GATES_D/$f.sh\"" "$G")
  [ "$n" = 1 ] && ok || bad "R1 gates.sh must hold exactly one call line for $f.sh (got $n)"
  [ -s "$GD/$f.sh" ] && ok || bad "R1 bin/lib/rb/gates.d/$f.sh is missing or empty"
done
for s in pc_launch_check issue_is_closed ISSUE-CREATED-AT 'project daily ceiling' 'closed issue skip' 'issue created-at stamp'; do
  n=$(grep -cF -- "$s" "$G")
  [ "$n" = 0 ] && ok || bad "R1 gates.sh still carries '$s' ($n line(s)); it must live in gates.d only"
done

# ══ R2: each call line sits at the old place of its block ══════════════════
before_g() { # before_g <a> <b> — in gates.sh, the line of a < the line of b
  local a b; a=$(gln "$1"); b=$(gln "$2")
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ] && ok || bad "R2 '$1' (line ${a:-none}) must come before '$2' (line ${b:-none}) in gates.sh"
}
PC=$(gln '. "$RB_GATES_D/project-ceiling.sh"')
ADW='  echo "$(STAMP) $KEY" > "$BUILD/ADMITTED"'
AD=$(grep -m1 -nF -- "$ADW" "$G" | cut -d: -f1)
SH=$(grep -nF 'BUILD_DEFERRED spend-hold $PROJECT' "$G" | head -1 | cut -d: -f1)
BLO=$(gln '# >>> budget launch gate (BH-4489)'); BLC=$(gln '# <<< budget launch gate')
[ -n "$PC" ] && [ -n "$SH" ] && [ -n "$AD" ] && [ -n "$BLO" ] && [ -n "$BLC" ] \
  && [ "$BLO" -lt "$SH" ] && [ "$SH" -lt "$PC" ] && [ "$PC" -lt "$AD" ] && [ "$AD" -lt "$BLC" ] && ok \
  || bad "R2 project-ceiling call (line ${PC:-none}) must sit after the spend-hold refusal (${SH:-none}) and before the ADMITTED write (${AD:-none}) inside the budget launch gate (${BLO:-none}..${BLC:-none})"
[ -n "$PC" ] && [ -n "$AD" ] && [ "$((PC+1))" = "$AD" ] && ok || bad "R2 project-ceiling call (line ${PC:-none}) must sit directly above the ADMITTED write (line ${AD:-none})"
before_g '. "$RB_GATES_D/hotfix-detect.sh"' '. "$RB_GATES_D/closed-issue-skip.sh"'
before_g '. "$RB_GATES_D/closed-issue-skip.sh"' '# >>> held issue skip'
CA=$(gln '. "$RB_GATES_D/issue-created-at.sh"')
JO=$(grep -nxF 'if command -v job_open >/dev/null 2>&1; then' "$G" | head -1 | cut -d: -f1)
[ -n "$CA" ] && [ -n "$JO" ] && [ "$((CA+1))" = "$JO" ] && ok || bad "R2 issue-created-at call (line ${CA:-none}) must sit directly above 'if command -v job_open' (line ${JO:-none})"
before_g '# <<< plan-blocked notice' '. "$RB_GATES_D/issue-created-at.sh"'

# ══ R3: the flatten, in the old order ═══════════════════════════════════════
ALL="$T/real.all"
rb_all "$DIR" "$ALL" >/dev/null || bad "R3 rb_all on the repo failed"
ln() { grep -nxF -- "$1" "$ALL" | head -1 | cut -d: -f1; }
cnt() { grep -cxF -- "$1" "$ALL"; }
left=$(grep -cE '^\. "\$RB_GATES_D/[a-z0-9-]+\.sh"$' "$ALL")
[ "$left" = 0 ] && ok || bad "R3 the flatten still holds $left fragment call line(s)"
for m in '# >>> project daily ceiling' '# <<< project daily ceiling' '# >>> closed issue skip' '# <<< closed issue skip' \
         '# >>> issue created-at stamp' '# <<< issue created-at stamp'; do
  [ "$(cnt "$m")" = 1 ] && ok || bad "R3 '$m' must appear once in the flatten (got $(cnt "$m"))"
done
before() { # before <a> <b> — in the flatten, line of a < line of b, both present
  local a b; a=$(ln "$1"); b=$(ln "$2")
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ] && ok || bad "R3 '$1' (line ${a:-none}) must come before '$2' (line ${b:-none})"
}
before '# <<< hotfix detect' '# >>> closed issue skip'
before '# <<< closed issue skip' '# >>> held issue skip'
FSH=$(grep -nF 'BUILD_DEFERRED spend-hold $PROJECT' "$ALL" | head -1 | cut -d: -f1)
FPO=$(ln '# >>> project daily ceiling')
[ -n "$FSH" ] && [ -n "$FPO" ] && [ "$FSH" -lt "$FPO" ] && ok || bad "R3 the spend-hold refusal (line ${FSH:-none}) must come before '# >>> project daily ceiling' (line ${FPO:-none})"
before '# >>> project daily ceiling' '# <<< project daily ceiling'
before '# <<< project daily ceiling' '  echo "$(STAMP) $KEY" > "$BUILD/ADMITTED" 2>/dev/null || true'
before '  echo "$(STAMP) $KEY" > "$BUILD/ADMITTED" 2>/dev/null || true' '# <<< budget launch gate'
before '# <<< plan-blocked notice' '# >>> issue created-at stamp'
before '# <<< issue created-at stamp' 'if command -v job_open >/dev/null 2>&1; then'
grep -qF 'BL_RC=0; pc_launch_check "$PROJECT" "$PC_HF" || BL_RC=$?' "$ALL" && ok || bad "R3 the ceiling check body is not in the flatten"
grep -qF 'issue_is_closed "$CI_REPO" "$CI_N" "$HARNESS" "$CI_MEMO"; CI_RC=$?' "$ALL" && ok || bad "R3 the closed-issue body is not in the flatten"

# ══ R4: byte identity with the base tree's inline text ══════════════════════
# The base is the merge-base with origin/main, computed once. When the base
# already carries the move (this commit is on main), there is no "before" to
# compare and R4 says so instead of comparing a tree with itself.
regions() { # regions <flatten> — the three regions, in order
  sed -n '/^# >>> closed issue skip$/,/^# <<< closed issue skip$/p
          /^# >>> budget launch gate/,/^# <<< budget launch gate$/p
          /^# >>> issue created-at stamp$/,/^# <<< issue created-at stamp$/p' "$1"
}
BASE=$(git -C "$DIR" merge-base HEAD origin/main 2>/dev/null) || BASE=""
if [ -z "$BASE" ]; then
  echo "R4 skipped: no merge-base with origin/main in this checkout"
elif git -C "$DIR" cat-file -e "$BASE:bin/lib/rb/gates.d/project-ceiling.sh" 2>/dev/null; then
  echo "R4 skipped: the base ${BASE:0:12} already carries gates.d/project-ceiling.sh"
else
  mkdir -p "$T/base"
  git -C "$DIR" archive "$BASE" bin/run-build.sh bin/lib/rb | tar -x -C "$T/base" \
    && rb_all "$T/base" "$T/base.all" >/dev/null && ok || bad "R4 could not flatten the base tree ${BASE:0:12}"
  regions "$T/base.all" > "$T/base.reg"
  regions "$ALL" | grep -vxF -e '# >>> project daily ceiling' -e '# <<< project daily ceiling' > "$T/head.reg"
  [ -s "$T/base.reg" ] && cmp -s "$T/base.reg" "$T/head.reg" && ok \
    || bad "R4 the three regions differ from the base ${BASE:0:12}: $(diff "$T/base.reg" "$T/head.reg" | head -8)"
fi

# ══ R5: driven ══════════════════════════════════════════════════════════════
awk '/^# >>> budget launch gate/{f=1} f{print} /^# <<< budget launch gate/{f=0}' "$G" > "$T/launch.sh"
[ -s "$T/launch.sh" ] && ok || bad "R5 no '# >>> budget launch gate' block in gates.sh"
mkdir -p "$T/h"
launch() { # launch <pc rc> -> rc; RESULT in $T/r5/result, REACHED in $T/r5/reached
  rm -rf "$T/r5"; mkdir -p "$T/r5/build"
  ( unset HOTFIX RESUME_BUILD
    export HARNESS="$T/h" RB_GATES_D="$GD" R5="$T/r5" PCRC="$1"
    bash -c '
      set -uo pipefail
      PROJECT=fixture-proj; KEY=FX-1; BUILD="$R5/build"
      STAMP() { echo 2026-11-02T00:00:00Z; }
      RESULT() { printf "%s\n" "$*" > "$R5/result"; }
      pc_launch_check() { PC_LINE="project-ceiling project=$1 usd=50.00/50"; PC_REASON=x; return "$PCRC"; }
      . "$1"
      echo REACHED > "$R5/reached"' _ "$T/launch.sh" ) >/dev/null 2>&1
  echo $?
}
rc=$(launch 1)
[ "$rc" = 3 ] && ok || bad "R5 a refusing pc_launch_check must exit 3 (got $rc)"
grep -q '^BUILD_DEFERRED budget-project-day project-ceiling project=fixture-proj ' "$T/r5/result" 2>/dev/null && ok \
  || bad "R5 RESULT must be BUILD_DEFERRED budget-project-day (got '$(cat "$T/r5/result" 2>/dev/null)')"
[ ! -e "$T/r5/build/ADMITTED" ] && [ ! -e "$T/r5/reached" ] && ok || bad "R5 a refused launch must write no ADMITTED and not reach the end"
rc=$(launch 0)
[ "$rc" = 0 ] && [ -s "$T/r5/build/ADMITTED" ] && [ -e "$T/r5/reached" ] && ok \
  || bad "R5 a passing pc_launch_check must write ADMITTED and reach the end (rc $rc)"
[ ! -e "$T/r5/result" ] && ok || bad "R5 a passing launch must write no RESULT (got '$(cat "$T/r5/result" 2>/dev/null)')"

# rb_gates_d_check on a scratch tree whose gates.d lacks project-ceiling.sh.
mkdir -p "$T/fakebin" "$T/c/bin/lib/rb"
printf '#!/bin/bash\necho fixture-host\n' > "$T/fakebin/hostname"; chmod +x "$T/fakebin/hostname"
cp "$G" "$T/c/bin/lib/rb/"; cp -r "$GD" "$T/c/bin/lib/rb/"
rm -f "$T/c/bin/lib/rb/gates.d/project-ceiling.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$HARNESS/alerts.argv"\n' > "$T/c/bin/lane-alert.sh"; chmod +x "$T/c/bin/lane-alert.sh"
out=$(env PATH="$T/fakebin:$PATH" HARNESS="$T/c" KEY=BH-1 PROJECT=fixture-proj BUILD="$T/c/build" \
  bash -c 'RESULT() { printf "%s\n" "$1" >> "$HARNESS/result"; }
           . "$0" || exit 9
           rb_gates_d_check; echo "rc=$?"' "$T/c/bin/lib/rb/gates.sh" 2>/dev/null)
[ "$out" = rc=3 ] && ok || bad "R5 a missing project-ceiling.sh must make rb_gates_d_check rc 3 (got '$out')"
res=$(cat "$T/c/result" 2>/dev/null)
[[ "$res" == "BUILD_DEFERRED gates.d/project-ceiling.sh missing"* ]] && ok \
  || bad "R5 RESULT must start 'BUILD_DEFERRED gates.d/project-ceiling.sh missing' (got '$res')"

echo "rb-gates-fragments (BH-8957): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
