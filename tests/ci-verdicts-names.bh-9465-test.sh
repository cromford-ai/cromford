#!/bin/bash
# tests/ci-verdicts-names.bh-9465-test.sh — bin/ci-verdicts.sh reads the
# three verdict keys a shard budget adds (notrun, timeout_names, notrun_names)
# and names the tests in both fan-in checks.
#
# The rules under test:
#   - an old five-key verdict still parses and passes (absent keys = 0 / empty);
#   - pure: a red shard names the tests that timed out and that did not run;
#   - trace: notrun > 0 is red (those tests were not traced), with the names;
#   - trace: a timeout with no hit is green with one ::warning:: line;
#   - the count check adds tests + notrun, so a budget stop does not read as a
#     split that dropped suites.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
V="$DIR/bin/ci-verdicts.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }
judge() { OUT=$(PLAN_RESULT=success "$V" "$1" "$2" "$3" "$4" 2>&1); RC=$?; }
old5() { mkdir -p "$1"; printf 'tests=%s\nfailed=%s\nhits=%s\npure=%s\ntrace=%s\n' "$3" "$4" "$5" "$6" "$7" > "$1/shard-$2.txt"; }
new8() { old5 "$@"; printf 'notrun=%s\ntimeout_names=%s\nnotrun_names=%s\n' "$8" "$9" "${10}" >> "$1/shard-$2.txt"; }

# ── N1. an old five-key verdict still passes both lanes.
old5 "$T/old" 0 4 0 0 pass clean
judge pure "$T/old" 1 4;  [ "$RC" -eq 0 ] && ok || bad "N1: an old verdict must pass pure (rc=$RC) [$OUT]"
judge trace "$T/old" 1 4; [ "$RC" -eq 0 ] && ok || bad "N1: an old verdict must pass trace (rc=$RC) [$OUT]"

# ── N2. pure red names the timed-out and the not-run tests.
new8 "$T/pf" 0 3 1 0 fail clean 1 tests/a-slow.sh tests/mc/z-test.sh
judge pure "$T/pf" 1 4; [ "$RC" -eq 1 ] && ok || bad "N2: a timeout + not-run shard must turn pure red (rc=$RC) [$OUT]"
has "timed out: tests/a-slow.sh" "$OUT" && ok || bad "N2: pure must name the timed-out test [$OUT]"
has "not run (shard budget): tests/mc/z-test.sh" "$OUT" && ok || bad "N2: pure must name the not-run test [$OUT]"
has "plan selected" "$OUT" && bad "N2: 3 run + 1 not run is the plan's 4, not a dropped suite [$OUT]" || ok

# ── N3. trace red on a not-run test, with its name.
new8 "$T/nr" 0 2 0 0 fail clean 1 "" tests/c-fast.sh
judge trace "$T/nr" 1 3; [ "$RC" -eq 1 ] && ok || bad "N3: a not-run test must turn trace red (rc=$RC) [$OUT]"
has "tests/c-fast.sh did not run, so they were not traced" "$OUT" && ok || bad "N3: trace must name the not-run test [$OUT]"

# ── N4. a timeout with no hit: trace green, one warning that names it.
new8 "$T/to" 0 3 1 0 fail clean 0 tests/a-slow.sh ""
judge trace "$T/to" 1 3; [ "$RC" -eq 0 ] && ok || bad "N4: a timeout with a clean trace must leave trace green (rc=$RC) [$OUT]"
has "::warning::shard 0/1: tests/a-slow.sh timed out" "$OUT" && ok || bad "N4: trace must warn with the name [$OUT]"
judge pure "$T/to" 1 3; [ "$RC" -eq 1 ] && ok || bad "N4: the same timeout is pure red (rc=$RC) [$OUT]"

# ── N5. the count: tests + notrun must equal the plan's count, no more.
new8 "$T/cnt" 0 0 0 0 fail clean 3 "" tests/a.sh,tests/b.sh,tests/c.sh
judge pure "$T/cnt" 1 3; [ "$RC" -eq 1 ] && ok || bad "N5: a shard that ran nothing is red (rc=$RC) [$OUT]"
has "tests/a.sh,tests/b.sh,tests/c.sh" "$OUT" && ok || bad "N5: and it names the not-run tests [$OUT]"
has "ran 0 tests" "$OUT" && bad "N5: a budget stop is not 'ran 0 tests' [$OUT]" || ok
new8 "$T/cnt2" 0 2 0 0 fail clean 1 "" tests/c.sh
judge trace "$T/cnt2" 1 5; [ "$RC" -eq 1 ] && ok || bad "N5: 2 + 1 of 5 planned is red (rc=$RC) [$OUT]"
old5 "$T/cnt3" 0 3 0 0 pass clean
judge pure "$T/cnt3" 1 3; [ "$RC" -eq 0 ] && ok || bad "N5: an absent notrun key counts as 0 (rc=$RC) [$OUT]"

# ── N6. a junk notrun is a verdict that does not parse.
new8 "$T/junk" 0 3 0 0 pass clean many "" ""
judge pure "$T/junk" 1 3; [ "$RC" -eq 1 ] && ok || bad "N6: notrun=many must be red (rc=$RC) [$OUT]"
has "does not parse" "$OUT" && ok || bad "N6: and say it does not parse [$OUT]"

# ── N7. a verdict that says pure=pass but has a not-run test is still red.
new8 "$T/lie" 0 2 0 0 pass clean 1 "" tests/c.sh
judge pure "$T/lie" 1 3; [ "$RC" -eq 1 ] && ok || bad "N7: a not-run test must turn pure red even when pure=pass (rc=$RC) [$OUT]"
has "not run (shard budget): tests/c.sh" "$OUT" && ok || bad "N7: and name it [$OUT]"

echo "ci-verdicts-names: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
