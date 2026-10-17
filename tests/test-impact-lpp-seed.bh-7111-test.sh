#!/bin/bash
# tests/test-impact-lpp-seed.bh-7111-test.sh — a diff that touches only
# catalog/lead-protected-paths.seed.tsv selects the suites that read the seed's
# content as `regression`, so the builder gate ranks them 1 (BH-7111).
#
# WHY. Merge-queue batch #7096 (and the stacked #7097) failed
# lead-authority-db.bh-4148 because PR #7067 edited the seed file. The select
# listed the suite only as `source`, the gate ranks `source` below 75 `always`
# suites, and the gate cap (80) left it to CI. catalog/ci-batch-regression.d/
# bh-7111.txt maps the seed to the three suites that read and assert on it.
#
# The real bin/test-impact.sh drives every case, on a map built once from this
# tree.
#
#   R1  select --why on the seed only: not full; lead-authority-db.bh-4148 is
#       `regression` for the seed path
#   R2  same select: lead-protected-paths-seed.bh-4140 and
#       lead-gates-loader.bh-5870 are `regression` too
#   R3  plain select lists tests/lead-authority-db.bh-4148-test.sh
#   R4  regression --changed: the three rows on the seed; none of them on an
#       unrelated catalog path
#   R5  each suite in the fragment exists and names lead-protected-paths.seed
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/test-impact-lpp-seed.bh-7111-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
IMPACT="$DIR/bin/test-impact.sh"
FRAG="$DIR/catalog/ci-batch-regression.d/bh-7111.txt"
SEEDP=catalog/lead-protected-paths.seed.tsv
SUITES=(tests/lead-authority-db.bh-4148-test.sh
        tests/lead-protected-paths-seed.bh-4140-test.sh
        tests/lead-gates-loader.bh-5870-test.sh)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
TAB=$(printf '\t')

"$IMPACT" map --root "$DIR" --out "$T/map" || { echo "FAIL: the map could not be built"; exit 1; }
[ -s "$T/map" ] || { echo "FAIL: the map is empty"; exit 1; }

printf '%s\n' "$SEEDP" > "$T/seed.changed"
printf '%s\n' catalog/perf-ticket.tsv > "$T/other.changed"

# ── R1. select --why on the seed only.
env -u TI_BATCH_SELECT "$IMPACT" --root "$DIR" select --why --map "$T/map" \
  --changed "$T/seed.changed" > "$T/r1.why" 2> "$T/r1.err"
rc=$?
[ "$rc" = 0 ] && ok || bad "R1: select --why exited $rc"
r=$(grep '^impact:' "$T/r1.err" | tail -1)
case "$r" in
  *"(full:"*|"") bad "R1: the select went full or said nothing: '$r'" ;;
  *) ok ;;
esac
grep -qxF "${SUITES[0]}${TAB}regression${TAB}$SEEDP" "$T/r1.why" && ok \
  || bad "R1: no '${SUITES[0]} regression $SEEDP' row; got: $(grep -F "${SUITES[0]}" "$T/r1.why" | tr '\t' ' ')"

# ── R2. the other two readers are regression too.
for s in "${SUITES[@]:1}"; do
  grep -qxF "$s${TAB}regression${TAB}$SEEDP" "$T/r1.why" && ok \
    || bad "R2: no '$s regression $SEEDP' row; got: $(grep -F "$s" "$T/r1.why" | tr '\t' ' ')"
done

# ── R3. plain select lists the suite (the ticket's literal acceptance).
env -u TI_BATCH_SELECT "$IMPACT" --root "$DIR" select --map "$T/map" \
  --changed "$T/seed.changed" > "$T/r3.out" 2> "$T/r3.err"
rc=$?
[ "$rc" = 0 ] && ok || bad "R3: select exited $rc"
grep -qxF "${SUITES[0]}" "$T/r3.out" && ok || bad "R3: plain select does not list ${SUITES[0]}"

# ── R4. the regression verb: three rows on the seed, none on another path.
"$IMPACT" --root "$DIR" regression --changed "$T/seed.changed" > "$T/r4.seed" 2> "$T/r4.err"
rc=$?
[ "$rc" = 0 ] && ok || bad "R4: regression --changed <seed> exited $rc"
for s in "${SUITES[@]}"; do printf '%s\t%s\n' "$s" "$SEEDP"; done | LC_ALL=C sort -u > "$T/r4.want"
grep -F "$SEEDP" "$T/r4.seed" | LC_ALL=C sort -u > "$T/r4.got"
cmp -s "$T/r4.want" "$T/r4.got" && ok \
  || bad "R4: the seed rows differ: want [$(tr '\n\t' '; ' < "$T/r4.want")] got [$(tr '\n\t' '; ' < "$T/r4.got")]"
"$IMPACT" --root "$DIR" regression --changed "$T/other.changed" > "$T/r4.other" 2>> "$T/r4.err"
rc=$?
[ "$rc" = 0 ] && ok || bad "R4: regression --changed <other> exited $rc"
for s in "${SUITES[@]}"; do
  grep -qF "$s" "$T/r4.other" && bad "R4: $s fires on catalog/perf-ticket.tsv" || ok
done

# ── R5. the fragment's suites exist and still read the seed.
[ -r "$FRAG" ] || bad "R5: $FRAG is not in the tree"
n=0
while IFS="$TAB" read -r s p; do
  case "$s" in ''|'#'*) continue ;; esac
  n=$((n+1))
  [ -f "$DIR/$s" ] && ok || bad "R5: $s is not in the tree"
  grep -qF lead-protected-paths.seed "$DIR/$s" 2>/dev/null && ok \
    || bad "R5: $s no longer names lead-protected-paths.seed"
  [ "$p" = "$SEEDP" ] && ok || bad "R5: $s maps '$p', want '$SEEDP'"
done < <(cat "$FRAG" 2>/dev/null)
[ "$n" = 3 ] && ok || bad "R5: the fragment has $n rows, want 3"

echo "test-impact-lpp-seed: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
