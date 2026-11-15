#!/bin/bash
# tests/retention-moves.bh-9732-test.sh — tests/retention-moves.bh-8407-test.sh
# is green on a checkout whose git history does not hold its pin a43d2f08 (the
# test host's shallow context from bin/remote-gate.sh), and its committed
# fixture is not a pass-through (ticket BH-9732).
#
#   A1 pin present: the real suite is rc 0 and says the fixture equals git archive
#   A2 pin absent, fixture intact: rc 0, "using the fixture", M1 and M3 ok
#   A3 pin absent, fixture removed: rc 1, FAIL M1 names the fixture path
#   A4 pin absent, fixture wakes.age def 30 -> 31: rc 1, "differs: wakes.age"
#   A5 pin present (alternates), fixture value changed: rc 1, "fixture differs"
#   A6 pin absent, fixture not JSON: rc 1, FAIL M1
#
# Each case builds its own scratch git repo (one commit, fixed identity). No network.
#   HARNESS_TEST_SANDBOX=1 bash tests/retention-moves.bh-9732-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v node >/dev/null 2>&1 || { echo "SKIPPED: node is not on PATH"; exit 0; }

PIN=a43d2f083de99b6e0770c7c0667bffb45f4afc3a
SUITE=tests/retention-moves.bh-8407-test.sh
FIX=tests/fixtures/retention-rules-a43d2f08.bh-9732.json
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
HAVE_PIN=0; git -C "$DIR" cat-file -e "$PIN^{commit}" 2>/dev/null && HAVE_PIN=1

# repo <dir> — a fresh one-commit git repo holding a copy of the suite, its
# libs, the fixture and the jobs worker. Its history has no $PIN.
repo() {
  mkdir -p "$1/tests/fixtures" "$1/worker/jobs"
  cp "$DIR/$SUITE" "$1/tests/"
  cp -R "$DIR/tests/lib" "$1/tests/"
  cp "$DIR/$FIX" "$1/tests/fixtures/"
  cp -R "$DIR/worker/jobs/src" "$DIR/worker/jobs/scripts" "$DIR/worker/jobs/package.json" "$1/worker/jobs/"
  git -C "$1" init -q && git -C "$1" add -A && git -C "$1" commit -qm scratch
}

# run <dir> <case> — run the copied suite; output in $T/<case>.out, rc in RC.
run() {
  ( cd "$1" && HARNESS_TEST_SANDBOX=1 bash "$SUITE" ) >"$T/$2.out" 2>&1; RC=$?
}
has() { grep -qF -- "$2" "$T/$1.out"; }

# ── A1 pin present ────────────────────────────────────────────────────────────
echo "A1: pin present"
if [ "$HAVE_PIN" = 1 ]; then
  ( cd "$DIR" && HARNESS_TEST_SANDBOX=1 bash "$SUITE" ) >"$T/a1.out" 2>&1; RC=$?
  [ "$RC" = 0 ] && has a1 "M1 the fixture equals git archive $PIN" && has a1 "M1 same names, count and entries" \
    && ok "A1 rc 0 and the fixture equals git archive $PIN" || bad "A1 rc $RC: $(grep FAIL "$T/a1.out" | head -3)"
else
  echo "NOTE: A1 not run: pin absent"
fi

# ── A2 pin absent, fixture intact ─────────────────────────────────────────────
echo "A2: pin absent, fixture intact"
repo "$T/a2"; run "$T/a2" a2
[ "$RC" = 0 ] && ok "A2 rc 0" || bad "A2 rc $RC: $(grep FAIL "$T/a2.out" | head -3)"
for l in "using the fixture" "M1 same names, count and entries" "M3 M1 goes red and names wakes.age" " 0 failed"; do
  has a2 "$l" && ok "A2 says: $l" || bad "A2 does not say: $l"
done

# ── A3 fixture removed ────────────────────────────────────────────────────────
echo "A3: pin absent, fixture removed"
repo "$T/a3"; rm -f "$T/a3/$FIX"; run "$T/a3" a3
[ "$RC" = 1 ] && grep -q "FAIL M1 .*$FIX is missing" "$T/a3.out" && ok "A3 rc 1 and FAIL M1 names $FIX" \
  || bad "A3 rc $RC: $(grep FAIL "$T/a3.out" | head -2)"

# ── A4 fixture wakes.age def changed ──────────────────────────────────────────
echo "A4: pin absent, fixture wakes.age def 30 -> 31"
repo "$T/a4"
node -e 'const fs=require("fs"),p=process.argv[1],r=JSON.parse(fs.readFileSync(p,"utf8"));
  const w=r.find((x)=>x.rule==="wakes.age"); if(!w||w.def!==30) process.exit(2); w.def=31;
  fs.writeFileSync(p, JSON.stringify(r, null, 1) + "\n");' "$T/a4/$FIX" || bad "A4 could not edit the fixture"
run "$T/a4" a4
[ "$RC" = 1 ] && has a4 "differs: wakes.age" && ok "A4 rc 1 and names differs: wakes.age" \
  || bad "A4 rc $RC: $(grep FAIL "$T/a4.out" | head -2)"

# ── A5 pin present, fixture drifted ───────────────────────────────────────────
echo "A5: pin present through alternates, fixture value changed"
if [ "$HAVE_PIN" = 1 ]; then
  repo "$T/a5"
  OBJ=$(cd "$DIR" && cd "$(git rev-parse --git-common-dir)" && pwd)/objects
  echo "$OBJ" >"$T/a5/.git/objects/info/alternates"
  sed -i '0,/"def": 30,/s//"def": 29,/' "$T/a5/$FIX"
  git -C "$T/a5" cat-file -e "$PIN^{commit}" 2>/dev/null || bad "A5 the alternates do not reach $PIN"
  run "$T/a5" a5
  [ "$RC" = 1 ] && has a5 "M1 the fixture differs from git archive $PIN" && ok "A5 rc 1 and the fixture differs" \
    || bad "A5 rc $RC: $(grep FAIL "$T/a5.out" | head -2)"
else
  echo "NOTE: A5 not run: pin absent"
fi

# ── A6 fixture not JSON ───────────────────────────────────────────────────────
echo "A6: pin absent, fixture not JSON"
repo "$T/a6"; echo 'not json {' >"$T/a6/$FIX"; run "$T/a6" a6
[ "$RC" = 1 ] && grep -q "FAIL M1 .*not a JSON array" "$T/a6.out" && ok "A6 rc 1 and FAIL M1" \
  || bad "A6 rc $RC: $(grep FAIL "$T/a6.out" | head -2)"

echo "retention-moves.bh-9732: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
