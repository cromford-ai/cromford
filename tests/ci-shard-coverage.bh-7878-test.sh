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
#   C5  `## Replay` holds 1 `replay: <k> batches;` line or 1 `NOT RUN: rc <n>`
#       line, and `## Re-measure` holds 2 or more of them; a row R8/R9 says
#       NOT RUN exactly when its section has no `replay:` line (a status never
#       claims a number that was not printed)
#
# It reads the tree only. No network, no vendor, no scratch tree, no clock.
set -uo pipefail
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
  [ $((nrep + nnot)) -ge "$2" ] && ok \
    || bad "C5: ## $1 must hold $2 or more 'replay: <k> batches;' or 'NOT RUN: rc <n>' lines (found $nrep + $nnot)"
  s=$(status "$3")
  if [ "$nrep" = 0 ]; then
    [ "$s" = "NOT RUN" ] && ok || bad "C5: R$3 is '$s' but ## $1 has no replay: line; it must be NOT RUN"
  else
    [ "$s" != "NOT RUN" ] && ok || bad "C5: R$3 is NOT RUN but ## $1 has a replay: line"
  fi
}
c5 Replay 1 8
c5 Re-measure 2 9

echo "ci-shard-coverage: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
