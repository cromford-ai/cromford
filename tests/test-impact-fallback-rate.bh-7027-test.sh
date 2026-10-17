#!/bin/bash
# tests/test-impact-fallback-rate.bh-7027-test.sh — bin/test-impact-fallback-rate.sh
# replays a directory of changed-path lists through a plain select and counts
# how many went to the whole corpus (BH-7027). A run with no answer is never
# counted as selected.
#
#   F1  4 lists, 1 full: rows parse back, `fallback: 1 of 4 (25%)`, a why row
#   F2  an empty lists dir: rc 2, no fallback: line
#   F3  a run that prints no impact: line: rc 2, no fallback: line
#   F4  the select runs with TI_BATCH_SELECT unset, even when the caller sets it
#   F5  the real bin/test-impact.sh on two lists and a built map: rc 0
#   F6  an unreadable --map: rc 2, no fallback: line
#   F7  the why rows: the most frequent first, a one-level path keeps its dir
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
RATE="$DIR/bin/test-impact-fallback-rate.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# The stub: answers full for any list that holds a catalog/ path, records the
# batch flag it saw, and prints nothing for a list that holds `silent`.
cat > "$T/stub.sh" <<'EOF'
#!/bin/bash
changed=""
while [ $# -gt 0 ]; do [ "$1" = --changed ] && changed="$2"; shift; done
echo "batch=${TI_BATCH_SELECT:-unset}" >> "${STUB_LOG:?}"
grep -q silent "$changed" && exit 0
echo tests/a-test.sh
if grep -q '^catalog/' "$changed"; then
  echo "impact: 10 of 10 suites (full: infra change ($(grep -m1 '^catalog/' "$changed")))" >&2
else
  echo "impact: 1 of 10 suites (selected: $(grep -c . < "$changed") changed path(s))" >&2
fi
EOF
chmod +x "$T/stub.sh"
: > "$T/map.fixture"
export STUB_LOG="$T/stub.log"

# ── F1.
mkdir -p "$T/l1"
printf 'bin/a.sh\n' > "$T/l1/101.txt"
printf 'catalog/lanes.d/x.json\nbin/b.sh\n' > "$T/l1/102.txt"
printf 'docs/x.md\n' > "$T/l1/103.txt"
printf 'bin/c.sh\nbin/d.sh\n' > "$T/l1/104.txt"
: > "$STUB_LOG"
OUT=$(TI_BATCH_SELECT=1 bash "$RATE" --lists "$T/l1" --impact "$T/stub.sh" --root "$T" --map "$T/map.fixture"); rc=$?
[ "$rc" = 0 ] && ok || bad "F1: rc=$rc"
nfull=$(awk -F'\t' 'NF == 3 && $2 == "full"' <<<"$OUT" | grep -c .)
nsel=$(awk -F'\t' 'NF == 3 && $2 == "selected"' <<<"$OUT" | grep -c .)
{ [ "$nfull" = 1 ] && [ "$nsel" = 3 ]; } && ok || bad "F1: want 1 full + 3 selected rows, got $nfull + $nsel: $OUT"
awk -F'\t' '$1 == "102" && $2 == "full" && $3 == "full: infra change (catalog/lanes.d/x.json)" { f = 1 } END { exit(f ? 0 : 1) }' <<<"$OUT" \
  && ok || bad "F1: the 102 row must carry its full reason: $OUT"
grep -qx 'fallback: 1 of 4 (25%)' <<<"$OUT" && ok || bad "F1: no 'fallback: 1 of 4 (25%)' line: $OUT"
awk '/^fallback:/ { f = NR } /^fallback-why:/ && !f { bad = 1 } END { exit(f && !bad ? 0 : 1) }' <<<"$OUT" \
  && ok || bad "F1: the why rows must follow the fallback: line: $OUT"
grep -qx $'fallback-why: 1\tinfra change\tcatalog/lanes.d' <<<"$OUT" && ok \
  || bad "F1: no fallback-why row for the infra change class: $OUT"

# ── F4. the batch flag never reaches the select.
grep -q '^batch=1$' "$STUB_LOG" && bad "F4: a run saw TI_BATCH_SELECT=1" || ok
[ "$(grep -c '^batch=unset$' "$STUB_LOG")" = 4 ] && ok || bad "F4: want 4 runs with the flag unset: $(cat "$STUB_LOG")"

# ── F7. the why rows sort by count, most first.
mkdir -p "$T/l7"
printf 'catalog/zz.json\n' > "$T/l7/1.txt"
printf 'catalog/lanes.d/a.json\n' > "$T/l7/2.txt"
printf 'catalog/lanes.d/b.json\n' > "$T/l7/3.txt"
OUT=$(bash "$RATE" --lists "$T/l7" --impact "$T/stub.sh" --root "$T" --map "$T/map.fixture"); rc=$?
WHY=$(grep '^fallback-why:' <<<"$OUT")
[ "$rc" = 0 ] && [ "$WHY" = $'fallback-why: 2\tinfra change\tcatalog/lanes.d\nfallback-why: 1\tinfra change\tcatalog' ] \
  && ok || bad "F7: want the lanes.d row (2) before the catalog row (1), rc=$rc: $OUT"

# ── F2. no lists.
mkdir -p "$T/l2"
OUT=$(bash "$RATE" --lists "$T/l2" --impact "$T/stub.sh" --root "$T" --map "$T/map.fixture" 2>&1); rc=$?
[ "$rc" = 2 ] && ok || bad "F2: an empty dir must be rc 2, got $rc"
grep -q '^fallback:' <<<"$OUT" && bad "F2: an empty dir printed a fallback: line: $OUT" || ok

# ── F3. a run with no answer.
cp -r "$T/l1" "$T/l3"; printf 'silent\n' > "$T/l3/105.txt"
OUT=$(bash "$RATE" --lists "$T/l3" --impact "$T/stub.sh" --root "$T" --map "$T/map.fixture" 2>&1); rc=$?
[ "$rc" = 2 ] && ok || bad "F3: a run with no impact: line must be rc 2, got $rc"
grep -q '105: the select printed no impact: line' <<<"$OUT" && ok || bad "F3: the error must name list 105: $OUT"
grep -q '^fallback:' <<<"$OUT" && bad "F3: printed a fallback: line: $OUT" || ok

# ── F6. an unreadable map.
OUT=$(bash "$RATE" --lists "$T/l1" --impact "$T/stub.sh" --root "$T" --map "$T/no-such-map" 2>&1); rc=$?
[ "$rc" = 2 ] && ok || bad "F6: an unreadable map must be rc 2, got $rc"
grep -q '^fallback:' <<<"$OUT" && bad "F6: printed a fallback: line: $OUT" || ok

# ── F5. the real selector, on a map built from this tree.
"$DIR/bin/test-impact.sh" map --root "$DIR" --out "$T/map" || { echo "FAIL: F5: the map could not be built"; exit 1; }
mkdir -p "$T/l5"
printf 'docs/notes/README.md\n' > "$T/l5/201.txt"
printf '.github/workflows/harness-ci.yml\n' > "$T/l5/202.txt"
OUT=$(bash "$RATE" --lists "$T/l5" --root "$DIR" --map "$T/map"); rc=$?
[ "$rc" = 0 ] && ok || bad "F5: rc=$rc: $OUT"
[ "$(printf '%s\n' "$OUT" | grep -c '^fallback:')" = 1 ] && ok || bad "F5: want one fallback: line: $OUT"
grep -qx 'fallback: 1 of 2 (50%)' <<<"$OUT" && ok || bad "F5: want 'fallback: 1 of 2 (50%)': $OUT"

echo "test-impact-fallback-rate: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
