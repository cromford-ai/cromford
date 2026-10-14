#!/bin/bash
# tests/day-boundary-guard.bh-6052-test.sh — a suite that reads a UTC day stamp
# twice must not straddle 00:00Z.
#
# THE FAILURE (BH-6052, from the #6049 audit). 63 suites compute a `date -u`
# day stamp. The code under test reads the day, and the suite reads it again to
# build the value it expects. A run that crosses 00:00Z between the two reads
# compares two different days and goes red on a correct build.
#
# The fix is tests/lib/day-boundary.sh (clear_boundary <period_s> <margin_s>),
# called once near the top of each such suite, and tests/lib/at-utc-midnight.sh,
# which runs a suite with a `date` shim that starts the clock at 23:59:50Z.
#
#   A. clear_boundary's decision rule, with a fixed clock and a recorded sleep.
#   B. the repro tool: an unguarded two-read suite fails under it, the same
#      suite with the guard passes, and one real guarded suite passes.
#   C. every day-stamp read in tests/*.sh is guarded or listed below as benign.
#   D. C goes red, and names the file, when a guard is removed.
#
# Run from anywhere: tests/day-boundary-guard.bh-6052-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/tests/lib/day-boundary.sh"
TOOL="$DIR/tests/lib/at-utc-midnight.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# The ticket's grep, built from two pieces so this file is not a hit itself.
P1='date -u \+%('
P2='Y%m%d|F|Y-%m-%d)\)'
PAT="$P1$P2"
# A day format for the scratch suites, also built from pieces.
F='%Y''%m%d'

# A fixed day boundary: 20000 * 86400 is 2024-10-03 00:00:00Z.
DAY0=1728000000

# ── A. clear_boundary decision rule ─────────────────────────────────────────
echo "--- A. clear_boundary"
# cb <epoch> <args...> — run clear_boundary in a subshell with `date` fixed at
# <epoch> and `sleep` recorded. Sets RC; the sleeps are in $T/slept, stderr in
# $T/err.
cb() {
  local epoch=$1; shift
  rm -f "$T/slept" "$T/err"; : > "$T/slept"
  (
    date() { echo "$epoch"; }
    sleep() { echo "$1" >> "$T/slept"; }
    . "$LIB" || exit 9
    clear_boundary "$@"
  ) 2> "$T/err"
  RC=$?
}

# A1. 100 s left, margin 30: no wait.
cb $((DAY0 - 100)) 86400 30
[ "$RC" = 0 ] && ok || bad "A1 rc=$RC, want 0"
[ ! -s "$T/slept" ] && ok || bad "A1 slept '$(cat "$T/slept")', want no sleep"
[ ! -s "$T/err" ] && ok || bad "A1 stderr '$(cat "$T/err")', want none"

# A2. 31 s left, margin 30: just outside, no wait.
cb $((DAY0 - 31)) 86400 30
[ "$RC" = 0 ] && ok || bad "A2 rc=$RC, want 0"
[ ! -s "$T/slept" ] && ok || bad "A2 slept '$(cat "$T/slept")', want no sleep"

# A3. 30 s left, margin 30: the edge is inclusive, sleep 31.
cb $((DAY0 - 30)) 86400 30
[ "$RC" = 0 ] && ok || bad "A3 rc=$RC, want 0"
[ "$(cat "$T/slept")" = 31 ] && ok || bad "A3 slept '$(cat "$T/slept")', want 31"

# A4. 23:59:50Z (10 s left), margin 30: sleep 11 and say why.
cb $((DAY0 - 10)) 86400 30
[ "$RC" = 0 ] && ok || bad "A4 rc=$RC, want 0"
[ "$(cat "$T/slept")" = 11 ] && ok || bad "A4 slept '$(cat "$T/slept")', want 11"
grep -qx 'clear_boundary: waiting 11s for the 86400s boundary' "$T/err" && ok \
  || bad "A4 stderr '$(cat "$T/err")', want the waiting line"

# A5. exactly 00:00:00Z: a whole day is left, no wait.
cb "$DAY0" 86400 30
[ "$RC" = 0 ] && ok || bad "A5 rc=$RC, want 0"
[ ! -s "$T/slept" ] && ok || bad "A5 slept '$(cat "$T/slept")', want no sleep"

# A6. bad arguments: rc 2, no sleep.
for args in "abc 30" "86400 0" "86400 86400" "86400 90000" "86400" "86400 30 7" "86400 -5" "086400 30"; do
  # shellcheck disable=SC2086
  cb $((DAY0 - 10)) $args
  [ "$RC" = 2 ] && ok || bad "A6 '$args' rc=$RC, want 2"
  [ ! -s "$T/slept" ] && ok || bad "A6 '$args' slept '$(cat "$T/slept")', want no sleep"
done

# A9. a clock that does not answer with an epoch: rc 2, no sleep.
cb "not-a-number" 86400 30
[ "$RC" = 2 ] && ok || bad "A9 unreadable clock rc=$RC, want 2"
[ ! -s "$T/slept" ] && ok || bad "A9 unreadable clock slept '$(cat "$T/slept")', want no sleep"

# A7. a clear_boundary defined before the source (#6049's wait-for.sh) is kept.
OUT=$(
  clear_boundary() { echo "earlier definition"; }
  . "$LIB" || exit 9
  clear_boundary 86400 30
); RC=$?
[ "$RC" = 0 ] && [ "$OUT" = "earlier definition" ] && ok \
  || bad "A7 the earlier clear_boundary was replaced (rc=$RC out='$OUT')"

# A8. production wiring: a suite that uses the exact lines the guarded suites
# carry, with `date` and `sleep` stubs on PATH, waits at 23:59:50Z.
mkdir -p "$T/a8/tests/lib" "$T/a8/stub"
cp "$LIB" "$T/a8/tests/lib/day-boundary.sh"
cat > "$T/a8/tests/a8-test.sh" <<'EOF'
#!/bin/bash
set -uo pipefail
# TEST-CHANGE BH-6052: the day stamp below is read by the code and again here; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 45 || exit 1
echo "after guard"
EOF
cat > "$T/a8/stub/date" <<EOF
#!/bin/bash
echo $((DAY0 - 10))
EOF
cat > "$T/a8/stub/sleep" <<EOF
#!/bin/bash
echo "\$1" >> "$T/a8/slept"
EOF
chmod +x "$T/a8/stub/date" "$T/a8/stub/sleep"
OUT=$(PATH="$T/a8/stub:$PATH" bash "$T/a8/tests/a8-test.sh" 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "A8 the guarded suite exited $RC, want 0 ($OUT)"
[ "$(cat "$T/a8/slept" 2>/dev/null)" = 11 ] && ok || bad "A8 slept '$(cat "$T/a8/slept" 2>/dev/null)', want 11"
case "$OUT" in *"clear_boundary: waiting 11s"*"after guard"*) ok ;; *) bad "A8 output '$OUT', want the wait and then the suite body" ;; esac

# ── B. the repro tool ───────────────────────────────────────────────────────
echo "--- B. at-utc-midnight.sh"
[ -x "$TOOL" ] && ok || bad "B0 tests/lib/at-utc-midnight.sh is missing or not executable"

# B1. with the default lead the shim clock starts at 23:59:4x or 23:59:5x.
cat > "$T/b1-test.sh" <<'EOF'
date -u +%H:%M:%S
EOF
OUT=$(bash "$TOOL" "$T/b1-test.sh" 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "B1 the tool exited $RC, want 0"
case "$OUT" in 23:59:[45][0-9]) ok ;; *) bad "B1 the shim clock read '$OUT', want 23:59:4x or 23:59:5x" ;; esac

# B2. RED control: read the day, let the clock cross 00:00Z, read it again. This
# is the defect, and under the tool it must fail.
LEAD=3; S=$((LEAD + 2))
cat > "$T/b2-test.sh" <<EOF
#!/bin/bash
first=\$(date -u +$F)
sleep "$S"
second=\$(date -u +$F)
echo "first=\$first second=\$second"
[ "\$first" = "\$second" ]
EOF
OUT=$(bash "$TOOL" "$T/b2-test.sh" "$LEAD" 2>&1); RC=$?
[ "$RC" = 1 ] && ok || bad "B2 the unguarded two-read suite exited $RC under the tool, want 1 ($OUT)"

# B3. GREEN: the same suite with the guard at the top passes under the tool.
{ echo '#!/bin/bash'
  echo ". \"$LIB\" || exit 1"
  echo 'clear_boundary 86400 30 || exit 1'
  tail -n +2 "$T/b2-test.sh"; } > "$T/b3-test.sh"
OUT=$(bash "$TOOL" "$T/b3-test.sh" "$LEAD" 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "B3 the guarded two-read suite exited $RC under the tool, want 0 ($OUT)"
case "$OUT" in *"clear_boundary: waiting"*) ok ;; *) bad "B3 the guard did not wait under the tool ($OUT)" ;; esac

# B4. a real guarded suite passes when it starts at 23:59:50Z. cost-reconcile
# reads every clock through `date`; a suite that also compares `date +%s` with a
# file mtime (cost-grok-usage) fails under the shim with or without the guard.
B4_SUITE="$DIR/tests/cost-reconcile.bh-1020-test.sh"
OUT=$(bash "$TOOL" "$B4_SUITE" 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "B4 $B4_SUITE exited $RC under the tool, want 0"
case "$OUT" in *"clear_boundary: waiting"*) ok ;; *) bad "B4 $B4_SUITE did not wait for 00:00Z under the tool" ;; esac

# B5. the tool refuses a missing suite and a bad lead.
bash "$TOOL" "$T/no-such-test.sh" 2>/dev/null; RC=$?
[ "$RC" = 2 ] && ok || bad "B5 a missing suite exited $RC, want 2"
bash "$TOOL" "$T/b1-test.sh" ten 2>/dev/null; RC=$?
[ "$RC" = 2 ] && ok || bad "B5 a bad lead exited $RC, want 2"

# ── C. every day-stamp read in tests/*.sh is guarded or benign ──────────────
echo "--- C. guard coverage"
# The hits that are not a day read. Each row is <file>|<why it is benign>.
BENIGN=(
  "tests/test-determinism-lint-test.sh|the hit is fixture text inside a quoted heredoc that the lint scans; the suite never compares it with a stamp"
  "tests/lane-down-canary.bh-1674-test.sh|the hit is literal text in a single-quoted sed replacement, a mutation written into a fixture copy of bin/claude-auth-check.sh; the suite reads no day itself"
)
is_benign() {
  local row
  for row in "${BENIGN[@]}"; do
    [ "${row%%|*}" = "$1" ] && return 0
  done
  return 1
}
# guarded <file> — the source line, the call before the first day read, and
# the TEST-CHANGE flag.
guarded() {
  local call hit
  call=$(grep -nE '^[[:space:]]*clear_boundary 86400 [0-9]+ \|\| exit 1' "$1" | head -n 1)
  hit=$(grep -nE "$PAT" "$1" | head -n 1)
  [ -n "$call" ] && [ "${call%%:*}" -lt "${hit%%:*}" ] \
    && grep -qE 'lib/day-boundary\.sh" \|\| exit 1' "$1" \
    && grep -q 'TEST-CHANGE BH-6052' "$1"
}
# check_tree <root> — print each tests/*.sh hit that is neither guarded nor benign.
check_tree() {
  local f rel
  while IFS= read -r f; do
    rel="tests/${f##*/}"
    is_benign "$rel" && continue
    guarded "$f" || echo "$rel"
  done < <(grep -lE "$PAT" "$1"/tests/*.sh)
}

[ "${#BENIGN[@]}" = 2 ] && ok || bad "C the benign table has ${#BENIGN[@]} rows, want 2"
for row in "${BENIGN[@]}"; do
  [ -n "${row#*|}" ] && [ "${row#*|}" != "$row" ] && ok || bad "C benign row '$row' has no reason"
done
HITS=$(grep -lE "$PAT" "$DIR"/tests/*.sh | wc -l)
[ "$HITS" -gt 0 ] && ok || bad "C the grep found no hit at all; the pattern is broken"
OFF=$(check_tree "$DIR")
[ -z "$OFF" ] && ok || bad "C unguarded day-stamp reads (guard them with clear_boundary, or list them as benign): $OFF"

# ── D. C names a suite whose guard is removed ───────────────────────────────
echo "--- D. mutation"
mkdir -p "$T/d1/tests"
cp "$DIR/tests/cost-grok-usage-test.sh" "$DIR/tests/extra-usage-loud.bh-3985-test.sh" \
   "$DIR/tests/lane-down-canary.bh-1674-test.sh" "$T/d1/tests/"
# D1. the three guard lines removed from one copy.
grep -vE 'TEST-CHANGE BH-6052|lib/day-boundary\.sh|^clear_boundary ' "$DIR/tests/cost-reconcile.bh-1020-test.sh" \
  > "$T/d1/tests/cost-reconcile.bh-1020-test.sh"
# D2. a new suite with an unguarded read.
printf '#!/bin/bash\nday=$(%s)\n' "date -u +%F" > "$T/d1/tests/new-day-read-test.sh"
# D3. a guard with no TEST-CHANGE flag.
grep -v 'TEST-CHANGE BH-6052' "$DIR/tests/flaky-rerun-test.sh" > "$T/d1/tests/flaky-rerun-test.sh"
# D4. a guard placed after the first day read.
printf '#!/bin/bash\n. "$(dirname "$0")/lib/scratch.sh" || exit 1\nday=$(%s)\n# TEST-CHANGE BH-6052: late guard\n. "$(dirname "$0")/lib/day-boundary.sh" || exit 1\nclear_boundary 86400 30 || exit 1\n' \
  "date -u +%F" > "$T/d1/tests/late-guard-test.sh"
OFF=$(check_tree "$T/d1")
WANT=$'tests/cost-reconcile.bh-1020-test.sh\ntests/flaky-rerun-test.sh\ntests/late-guard-test.sh\ntests/new-day-read-test.sh'
[ "$(printf '%s\n' "$OFF" | LC_ALL=C sort)" = "$WANT" ] && ok \
  || bad "D1-D4 check_tree named '$OFF', want exactly: $WANT"

echo "day-boundary-guard.bh-6052-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
