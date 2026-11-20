#!/bin/bash
# tests/test-impact-gate-failed.bh-4548-test.sh — BH-4548: `bin/test-impact-gate.sh
# --failed <file>` names the suites that went red, one per line, so the
# pre-queue workflow (.github/workflows/prequeue-gate.yml) can say WHICH suites
# fail on the head merged onto main.
#
#   F1  one red suite and one green suite: rc 1, and the file holds exactly the
#       red suite's path
#   F2  the green suite alone: rc 0, and the file exists and is empty
#   F3  a pre-filled file and no selection (rc 2): the file is emptied, never
#       left stale
#   F4  rc and stdout are the same with and without --failed, on the same
#       durations hint
#
# Real git repo under $T, the real gate, selector and runner. No network, one
# clock read.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v git >/dev/null || { echo "test-impact-gate-failed: git is required for this suite"; exit 2; }

NOW=$(date +%s)
export GIT_AUTHOR_DATE="@$NOW +0000" GIT_COMMITTER_DATE="@$NOW +0000"
export TEST_IMPACT_DURATIONS_FILE="$T/state/test-impact-durations.tsv"

R="$T/repo"
mkdir -p "$R/bin/lib" "$R/tests"
for f in bin/test-impact.sh bin/test-suite-run.sh bin/lib/suite-runner.sh bin/lib/train-shape.sh; do
  cp "$DIR/$f" "$R/$f" || exit 1
done
cp "$DIR/bin/test-impact-gate.sh" "$R/bin/test-impact-gate.sh" || exit 1
chmod +x "$R/bin/"*.sh
printf '#!/bin/bash\nwidget() { echo 1; }\n' > "$R/bin/lib/widget.sh"
# Both suites "read" the changed file, so both are selected.
cat > "$R/tests/red-test.sh" <<'SH'
#!/bin/bash
DIR=$(cd "$(dirname "$0")/.." && pwd)
grep -q 'widget()' "$DIR/bin/lib/widget.sh"
echo "FAIL: red on purpose"; echo "red: 0 passed, 1 failed"; exit 1
SH
cat > "$R/tests/green-test.sh" <<'SH'
#!/bin/bash
DIR=$(cd "$(dirname "$0")/.." && pwd)
grep -q 'widget()' "$DIR/bin/lib/widget.sh"
echo "green: 1 passed, 0 failed"
SH
gitc() { git -C "$R" -c user.email=t@example.com -c user.name=t "$@"; }
gitc init -q; gitc add -A; gitc commit -qm base
BASE=$(git -C "$R" rev-parse HEAD)
echo '# touched' >> "$R/bin/lib/widget.sh"; gitc commit -qam "touch widget"
gate() { ( cd "$R" && bash "$R/bin/test-impact-gate.sh" "$@" ); }

# ── F1. one red, one green ──────────────────────────────────────────────────
gate --base "$BASE" --runner local --failed "$T/f1" > "$T/f1.out" 2>&1; RC=$?
[ "$RC" = 1 ] && ok || bad "F1: a red suite is rc 1 (got $RC: $(tail -3 "$T/f1.out"))"
[ "$(cat "$T/f1" 2>/dev/null)" = "tests/red-test.sh" ] && ok \
  || bad "F1: the failed file holds exactly the red suite (got: '$(cat "$T/f1" 2>/dev/null)')"
grep -q 'done tests/green-test.sh rc=0' "$T/f1.out" && ok || bad "F1 setup: the green suite ran and passed"

# ── F2. green only: an empty file ───────────────────────────────────────────
gitc rm -q tests/red-test.sh; gitc commit -qm "drop red"
gate --base "$BASE" --runner local --failed "$T/f2" > "$T/f2.out" 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "F2: green is rc 0 (got $RC: $(tail -3 "$T/f2.out"))"
[ -e "$T/f2" ] && [ ! -s "$T/f2" ] && ok || bad "F2: on green the failed file exists and is empty (got: '$(cat "$T/f2" 2>/dev/null)')"

# ── F3. no selection: the file is truncated, not stale ──────────────────────
echo tests/stale-test.sh > "$T/f3"
gate --base no-such-ref --runner local --failed "$T/f3" > "$T/f3.out" 2>&1; RC=$?
[ "$RC" = 2 ] && ok || bad "F3: no selection is rc 2 (got $RC)"
[ -e "$T/f3" ] && [ ! -s "$T/f3" ] && ok || bad "F3: a stale failed file must be emptied (got: '$(cat "$T/f3" 2>/dev/null)')"
gate --base "$BASE" --runner local --failed "$T/no-such-dir/f" > "$T/f3b.out" 2>&1; RC=$?
[ "$RC" = 2 ] && ok || bad "F3: an unwritable --failed path is rc 2 before anything runs (got $RC)"
grep -q 'impact-gate: done' "$T/f3b.out" && bad "F3: nothing runs when --failed cannot be written" || ok

# ── F4. --failed changes neither rc nor stdout ──────────────────────────────
gitc reset -q --hard HEAD~1
# Both runs start from the same durations hint (BH-9855). The first run rewrites
# the file with its own wall times, and a suite that crosses a second boundary
# reorders the second run's plan; that is the hint doing its job, not --failed.
{ cat "$TEST_IMPACT_DURATIONS_FILE" 2>/dev/null; :; } > "$T/f4.dur"
gate --base "$BASE" --runner local > "$T/f4a.out" 2>/dev/null; RA=$?
cp "$T/f4.dur" "$TEST_IMPACT_DURATIONS_FILE" || exit 1
gate --base "$BASE" --runner local --failed "$T/f4" > "$T/f4b.out" 2>/dev/null; RB=$?
[ "$RA" = "$RB" ] && [ "$RA" = 1 ] && ok || bad "F4: the rc is unchanged by --failed (without $RA, with $RB)"
# Wall times and the gate's mktemp dir differ run to run; mask them, compare the rest.
mask() { sed -E 's/[0-9]+s\b/Ns/g; s#/impact-gate\.[A-Za-z0-9]+#/impact-gate.X#g' "$1"; }
[ "$(mask "$T/f4a.out")" = "$(mask "$T/f4b.out")" ] && ok \
  || bad "F4: stdout is unchanged by --failed (diff: $(diff <(mask "$T/f4a.out") <(mask "$T/f4b.out") | head -5))"

echo "test-impact-gate-failed.bh-4548: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
