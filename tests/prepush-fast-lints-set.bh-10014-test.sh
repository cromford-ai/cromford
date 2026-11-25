#!/bin/bash
# tests/prepush-fast-lints-set.bh-10014-test.sh — BH-10014: the builder's
# pre-push gate runs a small, catalog-driven set of fast always-suites
# (catalog/prepush-fast-lints.d/, one file per suite), not the whole fast set,
# and a could-not-run never blocks the push but is countable.
#
#   THE INCIDENT (2026-11-10..24). 8 fleet-built PRs went red in CI on a lint
#   step. 7 were fast always-suites (pr-scoped-test-lint, br-split-layout,
#   gh-app-ratchet, cross-tree-rows) that the box never ran: the fast set came
#   from a CI durations file the box did not have, so fast-lints was
#   could-not-run on every build, and could-not-run let the push go on.
#
#   S1  --run --set DIR runs exactly the suites DIR/*.txt names (comments and
#       blank lines skipped, duplicates once): green rc 0, a red suite rc 1
#   S2  a named suite that is not a file: a rc 127 row, the run ends rc 2
#   S3  a DIR that names nothing: rc 2
#   S4  --set reads no durations file (FAST_LINTS_DURATIONS points at nothing)
#   S5  the real catalog names 4 suites, each an existing tests/ file
#   S6  bin/prepush-gate.sh's fast-lints row runs the catalog set
#   S7  bin/lib/rb/pr.sh, block mode, fast-lints could-not-run: the push goes
#       on, the PR body names it (rc 124 named as a timeout), and
#       logs/prepush-gate.log gets ONE countable PREPUSH-COULD-NOT-RUN line
#   S8  a set with one missing entry AND one red suite ends rc 1: red wins
#   S9  the real pr.sh span, block mode, a RED fast-lints row: no push
#   S10 warn mode, fast-lints could-not-run: the push goes on, the line counts
#   S11 the usage text names --set
# Run from anywhere; exit 0 = all pass.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# A scratch repo with bin/fast-lints.sh and three stub suites.
R="$T/repo"; mkdir -p "$R/bin" "$R/tests" "$R/set" "$R/empty"
cp "$DIR/bin/fast-lints.sh" "$R/bin/"
printf '#!/bin/bash\nexit 0\n' > "$R/tests/green-a-test.sh"
printf '#!/bin/bash\nexit 0\n' > "$R/tests/green-b-test.sh"
printf '#!/bin/bash\necho broken; exit 1\n' > "$R/tests/red-test.sh"
printf '# a comment\n\ntests/green-a-test.sh\n' > "$R/set/a.txt"
printf 'tests/green-b-test.sh\ntests/green-a-test.sh\n' > "$R/set/b.txt"
run() { ( cd "$R" && FAST_LINTS_DURATIONS="$T/no-such-durations.tsv" bin/fast-lints.sh --run --set "$1" --out "$T/out-$2" > "$T/$2.txt" 2>&1 ); echo $?; }

# S1 + S4
rc=$(run set s1)
[ "$rc" = 0 ] && ok || bad "S1: a green set must be rc 0 (rc $rc: $(cat "$T/s1.txt"))"
[ "$(cut -f1 "$T/out-s1/timings.tsv" 2>/dev/null | tr '\n' ' ')" = "tests/green-a-test.sh tests/green-b-test.sh " ] && ok \
  || bad "S1: the set must run each named suite once (timings: $(cat "$T/out-s1/timings.tsv" 2>/dev/null))"
grep -q 'durations' "$T/s1.txt" && bad "S4: --set must not read the durations file: $(cat "$T/s1.txt")" || ok
printf 'tests/red-test.sh\n' > "$R/set/c.txt"
rc=$(run set s1r)
[ "$rc" = 1 ] && ok || bad "S1: a red suite in the set must be rc 1 (rc $rc)"
rm -f "$R/set/c.txt"

# S2
printf 'tests/not-here-test.sh\n' > "$R/set/d.txt"
rc=$(run set s2)
[ "$rc" = 2 ] && grep -q $'^tests/not-here-test.sh\t0\t127$' "$T/out-s2/timings.tsv" 2>/dev/null && ok \
  || bad "S2: a missing suite must be a rc 127 row and rc 2 (rc $rc, timings: $(cat "$T/out-s2/timings.tsv" 2>/dev/null))"
rm -f "$R/set/d.txt"

# S8 red wins over a missing entry
printf 'tests/not-here-test.sh\n' > "$R/set/d.txt"; printf 'tests/red-test.sh\n' > "$R/set/c.txt"
rc=$(run set s8)
[ "$rc" = 1 ] && ok || bad "S8: a missing entry beside a red suite must end rc 1 (red wins), got $rc"
rm -f "$R/set/c.txt" "$R/set/d.txt"

# S11 usage
( cd "$R" && bin/fast-lints.sh > "$T/usage.txt" 2>&1 )
grep -q -- '--set DIR' "$T/usage.txt" && ok || bad "S11: the usage text must name --set DIR"

# S3
rc=$(run empty s3)
[ "$rc" = 2 ] && ok || bad "S3: an empty set must be rc 2 (rc $rc)"

# S5 the real catalog
CAT="$DIR/catalog/prepush-fast-lints.d"
n=0; missing=""
for f in "$CAT"/*.txt; do
  [ -f "$f" ] || continue
  while IFS= read -r s; do
    n=$((n + 1)); [ -f "$DIR/$s" ] || missing="$missing $s"
  done < <(awk '/^[[:space:]]*(#|$)/ { next } { print $1 }' "$f")
done
[ "$n" = 4 ] && [ -z "$missing" ] && ok || bad "S5: the catalog must name 4 existing suites (named $n, missing:${missing:- none})"

# S6 the gate row
grep -q "fast-lints 'bin/fast-lints.sh --run --set catalog/prepush-fast-lints.d " "$DIR/bin/prepush-gate.sh" && ok \
  || bad "S6: bin/prepush-gate.sh's fast-lints row must run --set catalog/prepush-fast-lints.d"

# S7 the pr.sh span, block mode, fast-lints could-not-run.
awk '/^# >>> prepush gate/{f=1} f{print} /^# <<< prepush gate/{exit}' "$DIR/bin/lib/rb/pr.sh" > "$T/span.sh"
[ -s "$T/span.sh" ] && ok || bad "S7: no '# >>> prepush gate' span in bin/lib/rb/pr.sh"
# span <case> <summary rows> [SETV] — runs the real span with a stub gate.
span() {
  local C="$T/$1"; mkdir -p "$C/co/bin" "$C/co/catalog" "$C/build" "$C/h/logs"
  { printf '#!/bin/bash\nO=""; while [ $# -gt 0 ]; do case "$1" in --out) O=$2; shift ;; esac; shift; done\nmkdir -p "$O"\n'
    printf "printf '%s' > \"\$O/summary.tsv\"\n" "$2"
    printf 'echo "prepush-gate: stub"\nexit 1\n'; } > "$C/co/bin/prepush-gate.sh"
  chmod +x "$C/co/bin/prepush-gate.sh"
  ( cd "$C/co" && BUILD="$C/build" PROJECT=cromford KEY=BH-1 BASE=origin/main HARNESS="$C/h" SETV="${3:-}" bash -c '
      set -uo pipefail
      STAMP() { echo TS; }
      RESULT() { printf "%s\n" "$1" > "$BUILD/RESULT"; }
      escalate_block() { printf "%s\n" "$1" > "$BUILD/escalate"; }
      [ -n "$SETV" ] && setting_get() { printf "%s" "$SETV"; }
      PREPR_SECTION=""
      . "$0"
      echo "$PREPR_SECTION" > "$BUILD/section"
      echo PUSH_REACHED' "$T/span.sh" > "$C/out.txt" 2>&1 )
}
CNR=$'rules-pack\tgreen\t0\t30\trules-pack\nfast-lints\tcould-not-run\t124\t300\tfast-lints\n'
span s7 "$CNR"; C="$T/s7"
grep -q PUSH_REACHED "$C/out.txt" && [ ! -e "$C/build/RESULT" ] && ok \
  || bad "S7: a fast-lints could-not-run must not block the push (RESULT: $(cat "$C/build/RESULT" 2>/dev/null); out: $(tail -3 "$C/out.txt"))"
grep -q 'could-not-run.*fast-lints' "$C/build/section" 2>/dev/null && ok || bad "S7: the PR body must name fast-lints as could-not-run"
grep -q 'fast-lints (rc 124: timed out)' "$C/build/section" 2>/dev/null && ok || bad "S7: the PR body must name rc 124 as a timeout: $(cat "$C/build/section" 2>/dev/null)"
[ "$(grep -c 'PREPUSH-COULD-NOT-RUN project=cromford key=BH-1 ids=fast-lints' "$C/h/logs/prepush-gate.log" 2>/dev/null)" = 1 ] && ok \
  || bad "S7: one countable PREPUSH-COULD-NOT-RUN line in logs/prepush-gate.log (got: $(cat "$C/h/logs/prepush-gate.log" 2>/dev/null))"
# S9 a red fast-lints row through the real span: no push.
span s9 $'rules-pack\tgreen\t0\t30\trules-pack\nfast-lints\tred\t1\t20\tfast-lints\n'
grep -q PUSH_REACHED "$T/s9/out.txt" && bad "S9: a red fast-lints row must stop the push (out: $(tail -3 "$T/s9/out.txt"))" || ok
grep -q '^REVIEW_BLOCKED prepush-gate: red in fast-lints' "$T/s9/build/RESULT" 2>/dev/null && ok || bad "S9: RESULT must name the red fast-lints (got '$(cat "$T/s9/build/RESULT" 2>/dev/null)')"
# S10 warn mode, could-not-run: pushes, counted.
span s10 "$CNR" warn
grep -q PUSH_REACHED "$T/s10/out.txt" && [ "$(grep -c PREPUSH-COULD-NOT-RUN "$T/s10/h/logs/prepush-gate.log" 2>/dev/null)" = 1 ] && ok \
  || bad "S10: warn mode must push and count the could-not-run"

echo "prepush-fast-lints-set (BH-10014): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
