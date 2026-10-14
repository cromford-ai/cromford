#!/bin/bash
# tests/impact-map-tree-scanners.bh-6688-test.sh — a suite that scans a whole
# source directory gets that directory as a map row, so any change under it
# reaches the suite (BH-6688 fix round).
#
# WHY. The BH-6688 replay (PR #6702) bounded the reach of most infra paths. On
# draft #6367 the real culprit #6355 then fell out of the candidate set. #6355
# changed bin/lib/stall-alerts.sh and broke
# tests/ticket-branch-ratchet.bh-3835-test.sh, which reads every file under bin/
# with `( cd "$1" && grep -rnI … bin/ )`. A BARE directory token is dropped by
# the path extractor (only a rooted token may name a directory), so the suite
# had no bin/ row and no `*` row. Before BH-6688 #6355 reached `*` through a
# catalog path, so it was a candidate by accident.
#
#   S1  the real map: ticket-branch-ratchet.bh-3835 has a bin/ row
#   S2  the #6367 regression: a diff of only bin/lib/stall-alerts.sh selects
#       ticket-branch-ratchet.bh-3835, in the PR select and the batch select
#       (TI_BATCH_SELECT=1), and bim_reach puts it in the member's reach
#   S3  the other whole-bin scanners the signal finds have a bin/ row:
#       gh-graphql-reads-lint.bh-1585 (os.walk over root/bin),
#       file-children.bh-981, flag-callsites-pool.bh-5635
#   S4  fixture tree: `cd "$DIR" && grep -rn X bin/` is a bin/ row; a second
#       directory on the same line (fly/) is a fly/ row
#   S5  fixture tree: the same grep on a scratch path ("$T/bin"), a comment
#       line, and a quoted pattern 'bin/' add no row
#   S6  fixture tree: os.walk(os.path.join(root, "bin")) is a bin/ row
#   S7  fixture tree: the LAST sorted scan row names a directory the tree does
#       not hold: `map` still exits 0 with a full map, and adds no row for it
#       (lead review verdict #2202: the loop's last test was the rc)
#   S8  fixture tree: a scan row that names a FILE is an exact row, never a
#       `<file>/` directory row, and the map still exits 0
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/impact-map-tree-scanners.bh-6688-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

TI="$DIR/bin/test-impact.sh"
RATCHET=tests/ticket-branch-ratchet.bh-3835-test.sh
CULPRIT=bin/lib/stall-alerts.sh
MAP="$T/map"
bash "$TI" map --root "$DIR" --out "$MAP" 2>"$T/map.err" && [ -s "$MAP" ] \
  || { echo "FAIL: the map could not be built: $(cat "$T/map.err")"; exit 1; }
row() { awk -F'\t' -v s="$1" -v p="$2" '$1 == s && $2 == p { f = 1 } END { exit !f }' "$3"; }

# S1 — the ratchet reads all of bin/.
[ -f "$DIR/$RATCHET" ] && [ -f "$DIR/$CULPRIT" ] || bad "S1 fixture: $RATCHET or $CULPRIT is not in this tree"
row "$RATCHET" bin/ "$MAP" && ok || bad "S1 $RATCHET has a bin/ row: $(awk -F'\t' -v s="$RATCHET" '$1 == s' "$MAP" | head -3 | tr '\n' ' ')"

# S2 — the #6367 regression, in each select the conductor uses.
printf '%s\n' "$CULPRIT" > "$T/changed"
SEL=$(bash "$TI" --root "$DIR" --map "$MAP" select --changed "$T/changed" --map-only 2>"$T/sel.err")
grep -qxF "$RATCHET" <<<"$SEL" && ok || bad "S2 the PR select of $CULPRIT holds $RATCHET: $(head -c 300 "$T/sel.err")"
SELB=$(TI_BATCH_SELECT=1 bash "$TI" --root "$DIR" --map "$MAP" select --changed "$T/changed" --map-only 2>"$T/selb.err")
grep -qxF "$RATCHET" <<<"$SELB" && ok || bad "S2 the batch select of $CULPRIT holds $RATCHET: $(head -c 300 "$T/selb.err")"
REACH=$(HARNESS="$DIR" bash -c '. "$1" || exit 9; bim_reach "$2" "$3"' _ "$DIR/bin/lib/mc-batch-impact.sh" "$T/changed" "$MAP"); RRC=$?
[ "$RRC" = 0 ] && { grep -qxF "$RATCHET" <<<"$REACH" || grep -qxF '*' <<<"$REACH"; } && ok \
  || bad "S2 bim_reach of $CULPRIT holds $RATCHET (rc $RRC, $(grep -c . <<<"$REACH") lines)"

# S3 — the other whole-bin scanners.
for s in tests/gh-graphql-reads-lint.bh-1585-test.sh tests/file-children.bh-981-test.sh tests/flag-callsites-pool.bh-5635-test.sh; do
  [ -f "$DIR/$s" ] || { bad "S3 fixture: $s is not in this tree"; continue; }
  row "$s" bin/ "$MAP" && ok || bad "S3 $s has a bin/ row"
done

# ── fixture tree ─────────────────────────────────────────────────────────────
R="$T/r"
mkdir -p "$R/bin/lib" "$R/fly" "$R/tests" "$R/docs"
printf '#!/bin/bash\necho a\n' > "$R/bin/a.sh"
printf '#!/bin/bash\necho l\n' > "$R/bin/lib/l.sh"
printf '#!/bin/bash\necho f\n' > "$R/fly/f.sh"
cat > "$R/tests/scan-test.sh" <<'SH'
#!/bin/bash
DIR=$(cd "$(dirname "$0")/.." && pwd)
hits=$(cd "$DIR" && grep -rnE 'needle' bin/ fly 2>/dev/null)
echo "scan: 1 passed, 0 failed"
SH
cat > "$R/tests/scratch-test.sh" <<'SH'
#!/bin/bash
DIR=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
grep -rn needle "$T/bin" || true
# a comment that says grep -r needle bin/ adds nothing
grep -c 'grep -r x bin/' "$DIR/tests/scan-test.sh"
echo "scratch: 1 passed, 0 failed"
SH
cat > "$R/tests/walk-test.sh" <<'SH'
#!/bin/bash
DIR=$(cd "$(dirname "$0")/.." && pwd)
python3 - "$DIR" <<'PY'
import os, sys
root = sys.argv[1]
for dirpath, dirs, names in os.walk(os.path.join(root, "bin")):
    pass
PY
echo "walk: 1 passed, 0 failed"
SH
echo "a note" > "$R/docs/note.md"
git -C "$R" init -q && git -C "$R" add -A && git -C "$R" -c user.email=t@example.com -c user.name=t commit -qm base
RMAP="$T/rmap"
bash "$TI" --root "$R" map --out "$RMAP" 2>"$T/rmap.err" && [ -s "$RMAP" ] || bad "fixture: the map could not be built: $(cat "$T/rmap.err")"

# S4 — a recursive grep over bare directories run from the checkout.
row tests/scan-test.sh bin/ "$RMAP" && ok || bad "S4 scan-test has a bin/ row: $(cat "$RMAP")"
row tests/scan-test.sh fly/ "$RMAP" && ok || bad "S4 scan-test has a fly/ row: $(cat "$RMAP")"
# S5 — scratch paths, comments and quoted patterns add nothing.
row tests/scratch-test.sh bin/ "$RMAP" && bad "S5 scratch-test has no bin/ row: $(cat "$RMAP")" || ok
# S6 — a python walk of root/bin.
row tests/walk-test.sh bin/ "$RMAP" && ok || bad "S6 walk-test has a bin/ row: $(cat "$RMAP")"

# mini <dir> <suite-body> — a one-suite fixture tree with bin/a.sh, committed.
mini() {
  local d="$1"; mkdir -p "$d/bin" "$d/tests" "$d/docs"
  printf '#!/bin/bash\necho a\n' > "$d/bin/a.sh"
  printf '#!/bin/bash\nDIR=$(cd "$(dirname "$0")/.." && pwd)\n%s\necho "z: 1 passed, 0 failed"\n' "$2" > "$d/tests/zzz-test.sh"
  echo "a note" > "$d/docs/note.md"
  git -C "$d" init -q && git -C "$d" add -A && git -C "$d" -c user.email=t@example.com -c user.name=t commit -qm base
}
# S7 — the last row names a directory this tree does not hold (no worker/).
mini "$T/r7" 'hits=$(cd "$DIR" && grep -rn needle bin/ worker/ 2>/dev/null)'
bash "$TI" --root "$T/r7" map --out "$T/m7" 2>"$T/m7.err"; M7=$?
[ "$M7" = 0 ] && [ -s "$T/m7" ] && ok || bad "S7 map exits 0 when the last scan row names a missing dir (rc $M7: $(head -c 300 "$T/m7.err"))"
row tests/zzz-test.sh bin/ "$T/m7" && ok || bad "S7 the bin/ row is kept"
W7ROWS=$(awk -F'\t' '$2 ~ /^worker/' "$T/m7")
[ -z "$W7ROWS" ] && ok || bad "S7 no row for the missing worker/: $W7ROWS"
# S8 — a scan row that names a file.
mini "$T/r8" 'hits=$(cd "$DIR" && grep -rn needle bin/a.sh 2>/dev/null)'
bash "$TI" --root "$T/r8" map --out "$T/m8" 2>"$T/m8.err"; M8=$?
[ "$M8" = 0 ] && [ -s "$T/m8" ] && ok || bad "S8 map exits 0 when a scan row names a file (rc $M8: $(head -c 300 "$T/m8.err"))"
row tests/zzz-test.sh bin/a.sh "$T/m8" && ok || bad "S8 the file is an exact row: $(cat "$T/m8" 2>/dev/null)"
row tests/zzz-test.sh bin/a.sh/ "$T/m8" && bad "S8 no bin/a.sh/ directory row" || ok

echo "impact-map-tree-scanners.bh-6688: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
