#!/bin/bash
# tests/share-publish-clean.box6.bh-6469-test.sh — project-6's box short-name
# is rewritten by the publisher's sanitizer, refused by its guard when it is
# not, and its look-alikes are left alone (BH-6469).
#
# The name is one row of BOUNDED_PROJECTS in bin/share/mapping.py. That row
# feeds the rewrite rules (sanitize.build_rules) and the never-ship list
# (NAME_TOKENS, then leakcheck.BOUNDED), so this suite checks all three.
# BH-6494 moved the name to project-6-os (and the host to box-project-6-os-1):
# as project-6 it collided with project-6's own cron/boxes/project-6.d.
#
# NO NAME IS SPELLED IN THIS FILE. It ships in the mirror (sanitized), and a
# literal here would be a hit for the guard it tests. The short-name and the
# host prefix are glued together at run time.
#
# Run from anywhere: tests/share-publish-clean.box6.bh-6469-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
SHARE="$DIR/bin/share"

if [ ! -f "$SHARE/sanitize.py" ]; then
  # The mirror does not carry bin/share: the publisher is upstream-only.
  echo "SKIP share-publish-clean.box6: no bin/share in this copy"
  exit 0
fi

M="m""kos"; BW="board-""watcher-"
# Look-alikes: the name inside a longer word, and a base64 run that holds the
# letters with no word boundary (the console font carries one).
NEG=("${M}i" "s${M}x" "EKVN/7""project-6-os""DGQhnN")

# ── M1. the row is in the table and in both guard lists ─────────────────────
got=$(cd "$SHARE" && M="$M" python3 -c '
import os
from mapping import BOUNDED_PROJECTS, NAME_TOKENS
import leakcheck
m = os.environ["M"]
print((m, "project-6-os") in BOUNDED_PROJECTS, m in NAME_TOKENS, m in leakcheck.BOUNDED)' 2>&1)
if [ "$got" = "True True True" ]; then ok
else bad "M1 row/NAME_TOKENS/leakcheck.BOUNDED: got '$got', expected 'True True True'"; fi

# ── a scratch source tree the sanitizer will accept ─────────────────────────
# sanitize.py applies its PATCHES after the rewrite and fails if a target is
# missing, so the patched files are copied in from this checkout.
SRC="$T/src"; mkdir -p "$SRC/notes"
while IFS= read -r rel; do
  mkdir -p "$SRC/$(dirname "$rel")"
  cp "$DIR/$rel" "$SRC/$rel"
done < <(cd "$SHARE" && python3 -c '
import sanitize
for rel, _, _ in sanitize.PATCHES: print(rel)' | sort -u)
printf '{\n    "box-%s": "%s",\n}\n' "$M" "$M" > "$SRC/notes/accounts.json"
printf 'host %s%s\n' "$BW" "$M" > "$SRC/notes/host.md"
printf 'first\nsecond\n' > "$SRC/notes/$M.order"
printf '%s\n' "${NEG[@]}" > "$SRC/notes/neg.md"

# ── M2. sanitize rewrites the name in text and in a path ────────────────────
python3 "$SHARE/sanitize.py" "$SRC" "$T/mirror" > "$T/sanitize.out" 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
  bad "M2a sanitize.py exited $rc"; sed -n '1,20p' "$T/sanitize.out"
  echo "share-publish-clean.box6.bh-6469-test: $PASS pass, $FAIL fail"; exit 1
fi
ok
line=$(sed -n 2p "$T/mirror/notes/accounts.json" 2>/dev/null)
if [ "$line" = '    "box-project-6-os": "project-6-os",' ]; then ok
else bad "M2b accounts.json rewrote to '$line', expected '    \"box-project-6-os\": \"project-6-os\",'"; fi
line=$(sed -n 1p "$T/mirror/notes/host.md" 2>/dev/null)
if [ "$line" = "host box-project-6-os-1" ]; then ok
else bad "M2c host.md rewrote to '$line', expected 'host box-project-6-os-1'"; fi
if [ -f "$T/mirror/notes/project-6-os.order" ] && [ ! -e "$T/mirror/notes/$M.order" ]; then ok
else bad "M2d the .order path was not renamed: $(cd "$T/mirror/notes" && ls | tr '\n' ' ')"; fi

# ── M3. the sanitized tree passes the publisher's guard ─────────────────────
python3 "$SHARE/leakcheck.py" "$T/mirror" > "$T/leak-clean.out" 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then ok
else bad "M3 leakcheck refused the sanitized tree (rc=$rc):"; sed -n '1,30p' "$T/leak-clean.out"; fi

# ── M4. an UNSANITIZED copy is refused, naming every file ───────────────────
mkdir -p "$T/raw/notes"
cp "$SRC/notes/accounts.json" "$SRC/notes/host.md" "$SRC/notes/$M.order" "$T/raw/notes/"
python3 "$SHARE/leakcheck.py" "$T/raw" > "$T/leak-raw.out" 2>&1
rc=$?
if [ "$rc" -eq 1 ]; then ok; else bad "M4 leakcheck exited $rc on the unsanitized copy, expected 1"; fi
for f in accounts.json host.md "$M.order"; do
  if grep -qF "notes/$f" "$T/leak-raw.out"; then ok
  else bad "M4 leakcheck did not name notes/$f"; fi
done

# ── M5. the look-alikes are untouched and unflagged ─────────────────────────
if cmp -s "$SRC/notes/neg.md" "$T/mirror/notes/neg.md"; then ok
else bad "M5a sanitize rewrote a look-alike"; fi
mkdir -p "$T/negonly"; cp "$SRC/notes/neg.md" "$T/negonly/"
python3 "$SHARE/leakcheck.py" "$T/negonly" > "$T/leak-neg.out" 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then ok; else bad "M5b leakcheck flagged a look-alike (rc=$rc)"; fi

echo "share-publish-clean.box6.bh-6469-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
