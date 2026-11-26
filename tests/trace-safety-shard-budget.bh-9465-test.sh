#!/bin/bash
# tests/trace-safety-shard-budget.bh-9465-test.sh — bin/test-trace-safety.sh
# --gate always writes a shard verdict, and the verdict names the tests that
# timed out or did not run.
#
# WHY. A CI shard has a 45-minute job cap. One slow test on a slow runner took
# the shard past it, the job was cancelled before the verdict file was written,
# and both fan-in checks said "shard left no verdict" for the whole batch. The
# gate now takes a shard budget (TRACE_SAFETY_SHARD_BUDGET_S, measured from
# TRACE_SAFETY_T0): it caps the running test at the time left, starts no test
# once the budget is spent, and writes the verdict with the names.
#
# Fixtures `exec sleep`, so the timeout kills the sleep itself and no orphan
# holds a file open.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
RUN="$DIR/bin/test-trace-safety.sh"
VERDICTS="$DIR/bin/ci-verdicts.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }
if ! command -v timeout >/dev/null 2>&1; then
  [ -n "${CI:-}" ] && { echo "FAIL: no timeout(1) on a CI runner"; exit 1; }
  echo "trace-safety-shard-budget: no timeout(1) on PATH — skipping on this dev machine"; exit 0
fi
if [ "$(id -u)" -eq 0 ]; then export HARNESS_TEST_SANDBOX=1; fi
# The suite sets these itself; a value from the caller's env must not leak in.
unset TRACE_SAFETY_SHARD_BUDGET_S TRACE_SAFETY_T0 TRACE_SAFETY_TEST_TIMEOUT

mktree() { mkdir -p "$T/$1/tests/mc"; printf '%s\n' "$T/$1"; }
vget() { sed -n "s/^$1=//p" "$2" 2>/dev/null | head -1; }
fast() { printf '#!/bin/bash\necho "%s: 1 pass, 0 fail"\nexit 0\n' "$2" > "$1"; }
slow() { printf '#!/bin/bash\nexec sleep %s  # determinism: ok the sleep IS the fixture; the runner timeout is the assertion\n' "$2" > "$1"; }

# ── S1. the per-test bound: the timed-out test is named in the verdict.
S1=$(mktree s1)
slow "$S1/tests/slow.sh" 5
OUT=$(TRACE_SAFETY_TEST_TIMEOUT=2 "$RUN" --gate --verdict "$T/v1.txt" "$S1" 2>&1); RC=$?
[ "$RC" -eq 1 ] && ok || bad "S1: a timeout must make --gate rc 1 (rc=$RC) [$OUT]"
[ "$(vget pure "$T/v1.txt")" = fail ] && ok || bad "S1: pure=fail expected: $(cat "$T/v1.txt" 2>/dev/null)"
[ "$(vget failed "$T/v1.txt")" = 1 ] && ok || bad "S1: failed=1 expected: $(cat "$T/v1.txt" 2>/dev/null)"
[ "$(vget timeout_names "$T/v1.txt")" = tests/slow.sh ] && ok || bad "S1: timeout_names=tests/slow.sh expected: $(cat "$T/v1.txt" 2>/dev/null)"
[ "$(vget notrun "$T/v1.txt")" = 0 ] && ok || bad "S1: notrun=0 expected: $(cat "$T/v1.txt" 2>/dev/null)"
has "TIMEOUT slow.sh (killed after 2s)" "$OUT" && ok || bad "S1: the per-test bound keeps its TIMEOUT line [$OUT]"

# ── S2. the shard budget: the slow test is cut at the budget, the rest do not
#    start, and the verdict is written with every name.
S2=$(mktree s2)
slow "$S2/tests/a-slow.sh" 10
fast "$S2/tests/b-fast.sh" b; fast "$S2/tests/c-fast.sh" c
OUT=$(TRACE_SAFETY_SHARD_BUDGET_S=3 "$RUN" --gate --verdict "$T/v2/shard-0.txt" "$S2" 2>&1); RC=$?
V2="$T/v2/shard-0.txt"
[ "$RC" -eq 1 ] && ok || bad "S2: a budget stop must be rc 1 (rc=$RC) [$OUT]"
[ -r "$V2" ] && ok || bad "S2: a budget stop must still write the verdict [$OUT]"
[ "$(vget timeout_names "$V2")" = tests/a-slow.sh ] && ok || bad "S2: timeout_names=tests/a-slow.sh expected: $(cat "$V2" 2>/dev/null)"
[ "$(vget notrun "$V2")" = 2 ] && ok || bad "S2: notrun=2 expected: $(cat "$V2" 2>/dev/null)"
[ "$(vget notrun_names "$V2")" = tests/b-fast.sh,tests/c-fast.sh ] && ok || bad "S2: notrun_names expected b and c: $(cat "$V2" 2>/dev/null)"
[ "$(vget tests "$V2")" = 1 ] && ok || bad "S2: tests=1 (only a-slow ran) expected: $(cat "$V2" 2>/dev/null)"
[ "$(vget pure "$V2")" = fail ] && ok || bad "S2: pure=fail expected: $(cat "$V2" 2>/dev/null)"
has "NOTRUN tests/b-fast.sh (shard budget 3s spent)" "$OUT" && ok || bad "S2: each skipped test gets a NOTRUN line [$OUT]"
has "TIMEOUT a-slow.sh (killed after" "$OUT" && has "s, shard budget)" "$OUT" && ok \
  || bad "S2: the budget kill names itself as a shard-budget timeout [$OUT]"
has "BUDGET: 2 of 3 tests not run (shard budget 3s)" "$OUT" && ok || bad "S2: the BUDGET line must count the skipped tests [$OUT]"
LAST2=$(printf '%s\n' "$OUT" | tail -2 | cut -d' ' -f1 | tr '\n' ' ')
[ "$LAST2" = "TRACE: GATE: " ] && ok || bad "S2: TRACE: then GATE: must stay the last two lines (got '$LAST2') [$OUT]"
PREV=$(printf '%s\n' "$OUT" | tail -3 | head -1)
has "BUDGET:" "$PREV" && ok || bad "S2: the BUDGET line comes just before TRACE: (got '$PREV')"

# ── S3. no budget (the default): the old verdict, plus empty name keys.
S3=$(mktree s3)
fast "$S3/tests/a.sh" a; fast "$S3/tests/b.sh" b; fast "$S3/tests/c.sh" c
OUT=$("$RUN" --gate --verdict "$T/v3.txt" "$S3" 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok || bad "S3: a clean tree with no budget must be rc 0 (rc=$RC) [$OUT]"
FIRST5=$(head -5 "$T/v3.txt" 2>/dev/null | tr '\n' ' ')
[ "$FIRST5" = "tests=3 failed=0 hits=0 pure=pass trace=clean " ] && ok || bad "S3: the first five keys must be today's (got '$FIRST5')"
[ "$(vget notrun "$T/v3.txt")" = 0 ] && ok || bad "S3: notrun=0 expected: $(cat "$T/v3.txt" 2>/dev/null)"
grep -qx 'timeout_names=' "$T/v3.txt" && grep -qx 'notrun_names=' "$T/v3.txt" && ok \
  || bad "S3: both name keys must be present and empty: $(cat "$T/v3.txt" 2>/dev/null)"
has "BUDGET:" "$OUT" && bad "S3: no BUDGET line when nothing was skipped [$OUT]" || ok

# ── S4. a junk budget is a usage error: rc 2, the knob named, no verdict.
OUT=$(TRACE_SAFETY_SHARD_BUDGET_S=x "$RUN" --gate --verdict "$T/v4.txt" "$S3" 2>&1); RC=$?
[ "$RC" -eq 2 ] && ok || bad "S4: a junk budget must be rc 2 (rc=$RC) [$OUT]"
has "TRACE_SAFETY_SHARD_BUDGET_S" "$OUT" && ok || bad "S4: the error must name the knob [$OUT]"
[ ! -e "$T/v4.txt" ] && ok || bad "S4: rc 2 must leave no verdict file"
OUT=$(TRACE_SAFETY_SHARD_BUDGET_S=60 TRACE_SAFETY_T0=soon "$RUN" --gate --verdict "$T/v4b.txt" "$S3" 2>&1); RC=$?
{ [ "$RC" -eq 2 ] && has "TRACE_SAFETY_T0" "$OUT" && [ ! -e "$T/v4b.txt" ]; } && ok \
  || bad "S4: a junk TRACE_SAFETY_T0 must be rc 2 with the knob named and no verdict (rc=$RC) [$OUT]"
OUT=$(TRACE_SAFETY_SHARD_BUDGET_S=60 "$RUN" "$S3" 2>&1); RC=$?
{ [ "$RC" -eq 2 ] && has "only meaningful with --gate" "$OUT"; } && ok \
  || bad "S4: a budget without --gate must be refused, not ignored (rc=$RC) [$OUT]"

# ── S5. a clock that started long ago: nothing runs, the verdict is written.
#    T0 is a fixed epoch in 2001, so the budget is spent whatever the clock says.
OUT=$(TRACE_SAFETY_SHARD_BUDGET_S=50 TRACE_SAFETY_T0=1000000000 "$RUN" --gate --verdict "$T/v5.txt" "$S3" 2>&1); RC=$?
[ "$RC" -eq 1 ] && ok || bad "S5: a spent budget is rc 1 (rc=$RC) [$OUT]"
[ "$(vget tests "$T/v5.txt")" = 0 ] && ok || bad "S5: tests=0 expected: $(cat "$T/v5.txt" 2>/dev/null)"
[ "$(vget pure "$T/v5.txt")" = fail ] && ok || bad "S5: not-run tests alone make pure=fail: $(cat "$T/v5.txt" 2>/dev/null)"
[ "$(vget notrun "$T/v5.txt")" = 3 ] && ok || bad "S5: notrun=3 expected: $(cat "$T/v5.txt" 2>/dev/null)"
[ "$(vget notrun_names "$T/v5.txt")" = tests/a.sh,tests/b.sh,tests/c.sh ] && ok || bad "S5: all three named: $(cat "$T/v5.txt" 2>/dev/null)"
has "--- tests/a.sh rc=" "$OUT" && bad "S5: a not-run test must get no '--- rc=' line (suite-reuse would record it) [$OUT]" || ok

# ── S6. round trip: the S2 verdict through both fan-in checks.
for LANE in pure trace; do
  VOUT=$(PLAN_RESULT=success "$VERDICTS" "$LANE" "$T/v2" 1 3 2>&1); VRC=$?
  [ "$VRC" -eq 1 ] && ok || bad "S6: $LANE must be red on a budget stop (rc=$VRC) [$VOUT]"
  { has "tests/a-slow.sh" "$VOUT" || has "tests/b-fast.sh" "$VOUT"; } && ok || bad "S6: $LANE must name the tests [$VOUT]"
  has "left no verdict" "$VOUT" && bad "S6: $LANE must not say 'left no verdict' [$VOUT]" || ok
  has "plan selected" "$VOUT" && bad "S6: $LANE: tests + notrun must add up to the plan count [$VOUT]" || ok
done

# ── S7. the budget is the run's own: a traced test does not inherit it. CI sets
#    the knobs on the traced step, and a suite there that runs the plain lane
#    (tests/tests-trace-safety-test.sh) was refused rc 2 by S4's check. T0 is a
#    fixed epoch in 2100, so the budget is never spent here.
S7=$(mktree s7)
printf '#!/bin/bash\necho "seen budget=[${TRACE_SAFETY_SHARD_BUDGET_S-unset}] t0=[${TRACE_SAFETY_T0-unset}]"\nexit 1\n' > "$S7/tests/env.sh"
OUT=$(TRACE_SAFETY_SHARD_BUDGET_S=600 TRACE_SAFETY_T0=4102444800 "$RUN" --gate --verdict "$T/v7.txt" "$S7" 2>&1)
has "seen budget=[unset] t0=[unset]" "$OUT" && ok \
  || bad "S7: a traced test must run with TRACE_SAFETY_SHARD_BUDGET_S and TRACE_SAFETY_T0 unset [$OUT]"

echo "trace-safety-shard-budget: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
