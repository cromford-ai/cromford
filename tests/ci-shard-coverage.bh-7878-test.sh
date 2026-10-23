#!/bin/bash
# tests/ci-shard-coverage.bh-7878-test.sh — the BH-6491 scope is proven on
# main by a coverage record (BH-7878).
#
# WHY. The merged slice of #6491 (PR #7867) had no requirements coverage
# table, so its close-out could not prove the scope was built and filed
# #7878. The record is docs/notes/2026-10-21-BH-7878-ci-shard-coverage.md.
# This suite pins that record to the tree, so a row that cites a path or a
# symbol that moves goes red here.
#
#   C1  the note exists and has one table row for each of R1..R9
#   C2  each `path` or `path:line` a row cites exists, and the line is in the file
#   C3  each row's status is MET, MET-AMENDED, NOT MET, NOT RUN or OWED
#   C4  the symbols the rows name are in the tree: size_by_time() in
#       bin/ci-plan.sh, suite_shard_size() in bin/lib/suite-runner.sh, the
#       knob files CI_SHARD_BUDGET_S.json and CI_MAX_SHARDS.json, the logged
#       `ci-plan: sizing: count, ceil(` fallback and `title=ci-plan sizing`
#   C5  `## Replay` holds 1 or more `replay: <k> batches;` lines and
#       `## Re-measure` holds 2 or more (window 1 and window 2); a `NOT RUN: rc
#       <n>` line no longer counts, because the numbers were measured
#       2026-10-22. A row R8/R9 says NOT RUN exactly when its section has no
#       `replay:` line (a status never claims a number that was not printed)
#   C6  R8's status agrees with its number: the FIRST `replay:` line of
#       `## Replay` (the run at the knobs on main) gives `predicted max mean
#       <p> min`, the R8 row gives `at or under <t> min`; R8 is MET when
#       p <= t and NOT MET when p > t. Later lines (a counterfactual) and
#       `## Re-measure` never feed it. No `replay:` line skips it (C5 owns that).
#       Fixture notes under $T prove each branch.
#
# It reads the tree only. No network, no vendor, no clock. C6 writes its
# fixtures under the scratch tree $T (tests/lib/scratch.sh), removed on exit.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
NOTE="$DIR/docs/notes/2026-10-21-BH-7878-ci-shard-coverage.md"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# The table row for R<n>: `| R<n> | ... |`.
row() { grep -E "^\| *R$1 *\|" "$NOTE" 2>/dev/null; }
# The last cell of a row is its status.
status() { row "$1" | awk -F'|' '{ s = $(NF-1); gsub(/^[ \t*]+|[ \t*]+$/, "", s); print s }'; }
# The body of section `## <name>`, up to the next `## `.
section() { awk -v h="## $1" '$0 == h { on = 1; next } on && /^## / { exit } on' "$NOTE"; }

# C1
if [ -f "$NOTE" ]; then ok; else bad "C1: no coverage record at ${NOTE#"$DIR"/}"; fi
for r in 1 2 3 4 5 6 7 8 9; do
  n=$(row "$r" | wc -l)
  [ "$n" = 1 ] && ok || bad "C1: R$r must have exactly one table row (found $n)"
done

# C2
for r in 1 2 3 4 5 6 7 8 9; do
  refs=$(row "$r" | grep -oE '`(bin|tests|catalog|docs|worker|\.harness)/[A-Za-z0-9._/-]+(:[0-9]+)?`' | tr -d '`')
  [ -n "$refs" ] || { bad "C2: R$r cites no path"; continue; }
  for ref in $refs; do
    p=${ref%%:*}; l=""; [ "$p" = "$ref" ] || l=${ref#*:}
    if [ ! -f "$DIR/$p" ]; then bad "C2: R$r cites $p, which is not in the tree"; continue; fi
    if [ -n "$l" ] && [ "$l" -gt "$(wc -l < "$DIR/$p")" ]; then bad "C2: R$r cites $ref, past the end of $p"; continue; fi
    ok
  done
done

# C3
for r in 1 2 3 4 5 6 7 8 9; do
  s=$(status "$r")
  case "$s" in MET|MET-AMENDED|"NOT MET"|"NOT RUN"|OWED) ok ;; *) bad "C3: R$r status '$s' is not MET, MET-AMENDED, NOT MET, NOT RUN or OWED" ;; esac
done

# C4
grep -q '^size_by_time() {' "$DIR/bin/ci-plan.sh" && ok || bad "C4: size_by_time() is not in bin/ci-plan.sh"
grep -q '^suite_shard_size() {' "$DIR/bin/lib/suite-runner.sh" && ok || bad "C4: suite_shard_size() is not in bin/lib/suite-runner.sh"
for k in CI_SHARD_BUDGET_S CI_MAX_SHARDS; do
  [ -f "$DIR/catalog/lanes.d/ci-plan-settings.knobs.d/$k.json" ] && ok || bad "C4: knob file $k.json is missing"
done
# The logged fallback is `ci-plan: sizing: count, ceil(...)`: SIZING holds the
# rule and one echo adds the prefix.
{ grep -qF 'SIZING="count, ceil(' "$DIR/bin/ci-plan.sh" && grep -qF 'echo "ci-plan: sizing: $SIZING"' "$DIR/bin/ci-plan.sh"; } && ok \
  || bad "C4: the count fallback line 'ci-plan: sizing: count, ceil(' is not in bin/ci-plan.sh"
grep -qF 'title=ci-plan sizing' "$DIR/bin/ci-plan.sh" && ok || bad "C4: the 'title=ci-plan sizing' notice is not in bin/ci-plan.sh"

# C5
c5() { # <section> <min> <row>
  local body nrep nnot s
  body=$(section "$1")
  nrep=$(printf '%s\n' "$body" | grep -cE '^replay: [0-9]+ batches;')
  nnot=$(printf '%s\n' "$body" | grep -cE '^NOT RUN: rc [0-9]+')
  [ "$nrep" -ge "$2" ] && ok \
    || bad "C5: ## $1 must hold $2 or more 'replay: <k> batches;' lines (found $nrep, and $nnot 'NOT RUN: rc' lines)"
  s=$(status "$3")
  if [ "$nrep" = 0 ]; then
    [ "$s" = "NOT RUN" ] && ok || bad "C5: R$3 is '$s' but ## $1 has no replay: line; it must be NOT RUN"
  else
    [ "$s" != "NOT RUN" ] && ok || bad "C5: R$3 is NOT RUN but ## $1 has a replay: line"
  fi
}
c5 Replay 1 8
c5 Re-measure 2 9

# C6
# c6_check <note>: 0 = R8 agrees with the first ## Replay number, 1 = it
# contradicts it (or the row has no threshold), 2 = no replay: line (skip).
c6_check() {
  local f=$1 r8 s t p
  r8=$(grep -E '^\| *R8 *\|' "$f")
  s=$(printf '%s\n' "$r8" | awk -F'|' '{ s = $(NF-1); gsub(/^[ \t*]+|[ \t*]+$/, "", s); print s }')
  t=$(printf '%s\n' "$r8" | grep -oE 'at or under [0-9]+(\.[0-9]+)? min' | head -n1 | grep -oE '[0-9]+(\.[0-9]+)?')
  p=$(awk '$0 == "## Replay" { on = 1; next } on && /^## / { exit } on' "$f" \
    | grep -E '^replay: [0-9]+ batches;' | head -n1 \
    | grep -oE 'predicted max mean [0-9]+(\.[0-9]+)? min' | grep -oE '[0-9]+(\.[0-9]+)?')
  [ -n "$p" ] || return 2
  [ -n "$t" ] || { echo "c6: the R8 row names no 'at or under <t> min' target" >&2; return 1; }
  if awk -v p="$p" -v t="$t" 'BEGIN { exit !(p + 0 <= t + 0) }'; then
    [ "$s" = "MET" ] && return 0
    echo "c6: predicted max mean $p min <= $t min, but R8 is '$s' (want MET)" >&2; return 1
  fi
  [ "$s" = "NOT MET" ] && return 0
  echo "c6: predicted max mean $p min > $t min, but R8 is '$s' (want NOT MET)" >&2; return 1
}

# C6's fixtures live under $T; tests/lib/scratch.sh removes $T on exit.
C6T="$T/c6"
mkdir -p "$C6T" || { bad "C6: mkdir $C6T failed"; C6T=""; }

# The committed note.
if [ -n "$C6T" ]; then
  c6_check "$NOTE" 2>"$C6T/note.err"; rc=$?
  case $rc in
    0|2) ok ;;
    *) bad "C6: the committed note: $(cat "$C6T/note.err")" ;;
  esac
fi

# Fixtures. A line in the format bin/ci-shard-replay.sh prints (M1, 2026-10-22).
rline() { echo "replay: 30 batches; actual max shard mean 21.3 min; predicted max mean $1 min; no-ledger fallback 0 of 30; runner min per batch mean 276.6; sizing=time 30 of 30"; }
# c6_fixture <name> <R8 status> <Replay body file> [<line appended to ## Re-measure>]
# A copy of the real note with the R8 status cell and the ## Replay body swapped.
c6_fixture() {
  local out="$C6T/$1.md"
  awk -v st="$2" -v body="$3" -v extra="${4:-}" '
    /^\| *R8 *\|/ { n = split($0, c, "|"); c[n-1] = " " st " "; l = c[1]; for (i = 2; i <= n; i++) l = l "|" c[i]; print l; next }
    $0 == "## Replay" { print; print ""; while ((getline x < body) > 0) print x; print ""; skip = 1; next }
    skip && /^## / { skip = 0 }
    skip { next }
    { print }
    $0 == "## Re-measure" && extra != "" { print ""; print extra }
  ' "$NOTE" > "$out"
  echo "$out"
}
# c6_case <label> <want rc> <R8 status> <Replay body lines (\n-separated)> [<Re-measure line>]
c6_case() {
  local body="$C6T/$1.body" f rc
  printf '%b' "$4" > "$body"
  f=$(c6_fixture "$1" "$3" "$body" "${5:-}")
  c6_check "$f" 2>/dev/null; rc=$?
  [ "$rc" = "$2" ] && ok || bad "C6 fixture '$1': c6_check rc $rc, want $2"
}
if [ -n "$C6T" ]; then
  c6_case real-18.8-not-met      0 "NOT MET" "$(rline 18.8)\n"
  c6_case edge-14.9-met          0 "MET"     "$(rline 14.9)\n"
  c6_case near-15.0-met          1 "MET"     "$(rline 15.0)\n"
  c6_case edge-14.9-not-met      1 "NOT MET" "$(rline 14.9)\n"
  c6_case no-line                2 "NOT RUN" "NOT RUN: rc 1 at 2026-10-21T19:41:10Z.\n"
  c6_case second-11.3-ignored    0 "NOT MET" "$(rline 18.8)\n\n$(rline 11.3)\n"
  c6_case second-11.3-not-used   1 "MET"     "$(rline 18.8)\n\n$(rline 11.3)\n"
  c6_case first-11.3-met         0 "MET"     "$(rline 11.3)\n"
  c6_case 18.8-met-substring     1 "MET"     "$(rline 18.8)\n"
  c6_case remeasure-25.8-ignored 2 "MET"     "NOT RUN: rc 1 at 2026-10-21T19:41:10Z.\n" "$(rline 25.8)"
  c6_case remeasure-25.8-not-fed 0 "MET"     "$(rline 11.3)\n" "$(rline 25.8)"
fi

echo "ci-shard-coverage: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
