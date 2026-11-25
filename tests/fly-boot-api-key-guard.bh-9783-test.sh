#!/bin/bash
# tests/fly-boot-api-key-guard.bh-9783-test.sh — BH-9783: the R0 predicate of
# tests/fly-boot-api-key.bh-9718-test.sh (tests/lib/warmup-guard.bh-9783.sh).
# R0 must hold "the line after `  load_env` in warm_up is the APIKEY_MISSING
# guard", not a line count. Mutants of the real fly/builder-runner.sh are
# written to a scratch dir and given to warmup_guard_ok.
#
# PINNED:
#   G1 the real runner passes.
#   G2 a `local x=1` line above load_env passes.
#   G3 a comment line above load_env passes.
#   G4 the guard line deleted fails.
#   G5 the guard moved below the `base=` line fails.
#   G6 a blank line between load_env and the guard fails.
#   G7 a runner with no warm_up fails.
# Run from anywhere: bash tests/fly-boot-api-key-guard.bh-9783-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/warmup-guard.bh-9783.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

RN="$DIR/fly/builder-runner.sh"
GUARD_RE='APIKEY_MISSING:-}" \] ||'
grep -q "$GUARD_RE" "$RN" && grep -q '^  load_env$' "$RN" || { echo "FAIL: G0: fly/builder-runner.sh has no load_env + APIKEY_MISSING guard to mutate"; exit 1; }
# mutant <name> <awk program over the runner> -> $T/<name>.sh
mutant() { awk "$2" "$RN" > "$T/$1.sh"; }
# expect <case> <0|1> <file>
expect() {
  warmup_guard_ok "$3"; local rc=$?
  [ "$rc" = "$2" ] && ok || bad "$1: warmup_guard_ok rc $2 expected, got $rc"
}

# G1 the real runner
expect G1 0 "$RN"
# G2 a local line above load_env (inside warm_up only)
mutant g2 '/^warm_up\(\) \{/ { w = 1 } w && $0 == "  load_env" { print "  local x=1"; w = 0 } { print }'
grep -c '^  local x=1$' "$T/g2.sh" | grep -qx 1 && ok || bad "G2: the mutant was not written"
expect G2 0 "$T/g2.sh"
# G3 a comment above load_env
mutant g3 '/^warm_up\(\) \{/ { w = 1 } w && $0 == "  load_env" { print "  # a new comment"; w = 0 } { print }'
expect G3 0 "$T/g3.sh"
# G4 the guard deleted
mutant g4 '/APIKEY_MISSING:-}" \] \|\|/ { next } { print }'
grep -q "$GUARD_RE" "$T/g4.sh" && bad "G4: the mutant still has the guard" || ok
expect G4 1 "$T/g4.sh"
# G5 the guard moved below base=
mutant g5 '/APIKEY_MISSING:-}" \] \|\|/ { g = $0; next } { print } /^  base="\$\{BASE_BRANCH/ && g != "" { print g; g = "" }'
grep -q "$GUARD_RE" "$T/g5.sh" && ok || bad "G5: the mutant lost the guard"
expect G5 1 "$T/g5.sh"
# G6 a blank line between load_env and the guard
mutant g6 '/^warm_up\(\) \{/ { w = 1 } { print } w && $0 == "  load_env" { print ""; w = 0 }'
expect G6 1 "$T/g6.sh"
# G7 no warm_up at all
mutant g7 '{ sub(/^warm_up\(\) \{/, "warm_up_gone() {"); print }'
expect G7 1 "$T/g7.sh"

echo "fly-boot-api-key-guard (BH-9783): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
