#!/bin/bash
# tests/test-impact-ratchets.bh-9439-test.sh — the whole-repo ratchets that
# ejected merge-queue batches are in the builder gate's run list, and the gate
# runs a `regression *` suite on HEAD merged with fresh main (BH-9439).
#
# 14 days of the cromford queue: 114 of 303 batches red. The failing
# suites (no-state-files 37 batches, no-flag-files 12, ...) were selected by the
# builder gate only as `full` (rank 7) and the cap of 80 cut them. The
# prequeue-red ones were green alone and red merged with main, and the
# fresh-main pass moved only `always` suites onto the merge.
#
#   C1  the real tree: a state/ diff prints a `*` regression row for each of
#       the 10 suites in catalog/ci-batch-regression.d/bh-9439.txt
#   C2  each of those suites is a file in the tree (the A4 rule)
#   C3  a scratch repo, the real selector and gate, --cap 3: a `*` row puts a
#       state/ ratchet in the plan as `regression *`; with no row the cap
#       leaves it to CI
#   F1  a `regression *` suite green on HEAD and red on HEAD merged with main
#       is red with --fresh-main on, and it ran on the merge
#   F2  the same head with --fresh-main off is green
#   F3  a `regression bin/` row (not `*`) runs on HEAD with --fresh-main on
#   F4  F1's --table row carries `(fresh main <sha8>)`
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0 FAIL=0
TAB=$(printf '\t')
ok()  { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }

if ! command -v git > /dev/null 2>&1 || ! command -v jq > /dev/null 2>&1; then
  echo "test-impact-ratchets: SKIPPED — needs git and jq"
  echo "test-impact-ratchets: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]; exit
fi
export GIT_AUTHOR_DATE='2026-11-01T00:00:00Z' GIT_COMMITTER_DATE='2026-11-01T00:00:00Z'
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export HARNESS="$T/empty" TEST_IMPACT_GATE_FAST="$T/fast.empty" TEST_IMPACT_DURATIONS_FILE="$T/dur.tsv"
export TEST_IMPACT_GATE_TIERS="$T/no-tiers.tsv"
unset TEST_IMPACT_GATE_FRESH_MAIN SUITE_REUSE SUITE_REUSE_RUN_KEY GITHUB_ACTIONS
: > "$T/fast.empty"

RATCHETS="tests/no-state-files.bh-4159-test.sh
tests/no-flag-files.bh-4154-test.sh
tests/share-registry-exact.bh-6760-test.sh
tests/share-registry-guard.bh-6494-test.sh
tests/share-registry-repo.bh-6797-test.sh
tests/test-determinism-lint-test.sh
tests/test-impact-always-cut.bh-8098-test.sh
tests/stage-route-seed.bh-2536-test.sh
tests/ci-plan-spa-worker.bh-4969-test.sh
tests/lanes-registry-test.sh"

# ── C1 / C2: the real tree ──────────────────────────────────────────────────
printf 'state/foo.json\n' > "$T/c1.changed"
"$DIR/bin/test-impact.sh" --root "$DIR" regression --changed "$T/c1.changed" > "$T/c1.out" 2> "$T/c1.err"
C1RC=$?
[ "$C1RC" = 0 ] && ok "C1 regression rc 0" || bad "C1 rc=$C1RC: $(tail -2 "$T/c1.err")"
miss=""
while IFS= read -r s; do
  grep -qxF "$s${TAB}*" "$T/c1.out" || miss+=" $s"
done <<< "$RATCHETS"
[ -z "$miss" ] && ok "C1 a state/ diff prints a * row for each of the 10 ratchets" || bad "C1 missing:$miss"
[ "$(grep -c "${TAB}\*\$" "$T/c1.out")" -ge 10 ] && ok "C1 at least 10 * rows" || bad "C1 * rows: $(grep -c "${TAB}\*\$" "$T/c1.out")"
[ "$(awk -F'\t' 'NF == 2 && $2 == "*"' "$DIR/catalog/ci-batch-regression.d/bh-9439.txt" 2>/dev/null | wc -l)" = 10 ] \
  && ok "C1 bh-9439.txt holds exactly the 10 rows" || bad "C1 fragment rows: $(cat "$DIR/catalog/ci-batch-regression.d/bh-9439.txt" 2>/dev/null)"
miss=""
while IFS= read -r s; do [ -f "$DIR/$s" ] || miss+=" $s"; done <<< "$RATCHETS"
[ -z "$miss" ] && ok "C2 each ratchet is a file in the tree" || bad "C2 not in the tree:$miss"

# ── C3: the cap, in a scratch repo ──────────────────────────────────────────
C="$T/c3"
mkdir -p "$C"
for s in bin/test-impact-gate.sh bin/test-impact.sh bin/test-suite-run.sh; do
  scratch_install_closure "$s" "$C" > /dev/null || { echo "cannot install $s"; exit 1; }
done
mkdir -p "$C/tests/lib" "$C/state" "$C/catalog/ci-batch-regression.d"
printf '# scratch lib\n' > "$C/tests/lib/scratch.sh"
: > "$C/catalog/test-impact-always.txt"
printf '{}\n' > "$C/state/keep.json"
# Six suites that name the changed file outrank a ratchet that only scans state/.
for i in 1 2 3 4 5 6; do
  printf '#!/bin/bash\n# reads state/foo.json\necho "n%s: 1 passed, 0 failed"\n' "$i" > "$C/tests/n$i-test.sh"
done
printf '#!/bin/bash\nn=$(ls "$PWD"/st""ate | wc -l)\necho "ratchet: $n files"\n' > "$C/tests/no-state-files-test.sh"
chmod +x "$C"/tests/*.sh
GC() { git -C "$C" -c user.email=t@t -c user.name=t "$@"; }
GC init -q -b main && GC add -A && GC commit -qm A || { echo "cannot build the C3 fixture"; exit 1; }
CA=$(GC rev-parse HEAD)
printf '{}\n' > "$C/state/foo.json"
GC add -A && GC commit -qm H || exit 1
( cd "$C" && bin/test-impact-gate.sh --base "$CA" --runner plan --cap 3 ) > "$T/c3-none.out" 2>&1
awk '/left to CI by the cap/{f=1} f' "$T/c3-none.out" | grep -q 'tests/no-state-files-test.sh' \
  && ! grep -q '^plan: tests/no-state-files-test.sh' "$T/c3-none.out" \
  && ok "C3 near miss: no row, the cap leaves the ratchet to CI" || bad "C3 none: $(cat "$T/c3-none.out")"
printf '# C3\ntests/no-state-files-test.sh\t*\n' > "$C/catalog/ci-batch-regression.d/c3.txt"
GC add -A && GC commit -qm R || exit 1
( cd "$C" && bin/test-impact-gate.sh --base "$CA" --runner plan --cap 3 ) > "$T/c3-row.out" 2>&1
grep -qE '^plan: tests/no-state-files-test\.sh +regression \*' "$T/c3-row.out" \
  && ok "C3 a * row puts the ratchet in the plan, inside the cap, as regression *" || bad "C3 row: $(cat "$T/c3-row.out")"

# ── F: fresh main, a regression * suite ─────────────────────────────────────
R="$T/repo"
mkdir -p "$R"
for s in bin/test-impact-gate.sh bin/test-impact.sh bin/test-suite-run.sh; do
  scratch_install_closure "$s" "$R" > /dev/null || { echo "cannot install $s"; exit 1; }
done
mkdir -p "$R/tests/lib" "$R/catalog/ci-batch-regression.d"
printf '# scratch lib\n' > "$R/tests/lib/scratch.sh"
: > "$R/catalog/test-impact-always.txt"
printf '#!/bin/bash\necho a\n' > "$R/bin/a.sh"
LOGLINE='where=head; ls bin | grep -qx m.sh && where=fresh
[ -n "${FIXTURE_LOG:-}" ] && echo "$(basename "$0" .sh) $where" >> "$FIXTURE_LOG"'
{ echo '#!/bin/bash'; echo "$LOGLINE"
  echo 'n=$(ls bin | grep -cE "^[a-z]\.sh$")'
  echo '[ "$n" -le 2 ] || { echo "ceiling: $n one-letter scripts, the ceiling is 2"; exit 1; }'
  echo 'echo "ceiling: 1 passed, 0 failed"'; } > "$R/tests/ceiling-test.sh"
{ echo '#!/bin/bash'; echo "$LOGLINE"; echo 'echo "s: 1 passed, 0 failed"'; } > "$R/tests/s-test.sh"
printf '# F\ntests/ceiling-test.sh\t*\n' > "$R/catalog/ci-batch-regression.d/f.txt"
chmod +x "$R"/tests/*.sh "$R"/bin/*.sh
G() { git -C "$R" -c user.email=t@t -c user.name=t "$@"; }
G init -q -b main && G add -A && G commit -qm A || { echo "cannot build the F fixture"; exit 1; }
A=$(G rev-parse HEAD)
G checkout -q -b head
printf '#!/bin/bash\necho h\n' > "$R/bin/h.sh"
printf '# touched\n' >> "$R/tests/s-test.sh"
G add -A && G commit -qm H || exit 1
G checkout -q main
printf '#!/bin/bash\necho m\n' > "$R/bin/m.sh"
G add -A && G commit -qm M || exit 1
M=$(G rev-parse HEAD); M8=${M:0:8}
G checkout -q head
# The pin: the suite has no always row, so only the regression row picks it.
grep -qF 'tests/ceiling-test.sh' "$R/catalog/test-impact-always.txt" && bad "F the fixture ceiling is an always suite"

gate() {
  local tag="$1"; shift
  : > "$T/$tag.log"
  ( cd "$R" && FIXTURE_LOG="$T/$tag.log" bin/test-impact-gate.sh --base "$A" \
      --failed "$T/$tag.failed" --table "$T/$tag.md" "$@" ) > "$T/$tag.out" 2>&1
  GRC=$?
}
has() { grep -qxF "$2" "$T/$1.log"; }

gate f1 --fresh-main on --fresh-ref main --runner local
[ "$GRC" = 1 ] && ok "F1 rc 1: red on HEAD merged with main" || bad "F1 rc=$GRC: $(tail -8 "$T/f1.out")"
has f1 "ceiling-test fresh" && ! has f1 "ceiling-test head" && ok "F1 the regression * suite ran on the merge only" \
  || bad "F1 log: $(cat "$T/f1.log")"
grep -qxF tests/ceiling-test.sh "$T/f1.failed" && ok "F1 --failed names the suite" || bad "F1 failed: $(cat "$T/f1.failed")"
grep -q '^plan: tests/ceiling-test.sh  *regression \*' "$T/f1.out" && ok "F1 its reason is regression *" \
  || bad "F1 plan: $(grep '^plan:' "$T/f1.out")"

gate f2 --fresh-main off --runner local
[ "$GRC" = 0 ] && has f2 "ceiling-test head" && ok "F2 --fresh-main off: green alone" || bad "F2 rc=$GRC log: $(cat "$T/f2.log")"

printf '# F3\ntests/ceiling-test.sh\tbin/\n' > "$R/catalog/ci-batch-regression.d/f.txt"
G commit -qam F3 || exit 1
gate f3 --fresh-main on --fresh-ref main --runner local
[ "$GRC" = 0 ] && has f3 "ceiling-test head" && ! has f3 "ceiling-test fresh" \
  && ok "F3 near miss: a regression bin/ row runs on HEAD, green" || bad "F3 rc=$GRC log: $(cat "$T/f3.log") out: $(grep fresh "$T/f3.out")"

grep -F '`tests/ceiling-test.sh`' "$T/f1.md" | grep -qF "(fresh main $M8)" && ok "F4 the table row is tagged fresh main" \
  || bad "F4 table: $(cat "$T/f1.md")"

echo "test-impact-ratchets: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
