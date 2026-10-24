#!/bin/bash
# tests/render-doc-index.bh-1162-test.sh — `bin/render-doc-index.sh
# --check-committed` tells in-sync from stale without ever writing the index.
#
# TEST-CHANGE (BH-8254): this byte comparison was `--check`. docs/notes/INDEX.md
# left git, and `--check` now validates the notes instead
# (tests/render-doc-index.bh-8254-test.sh). The byte compare is unchanged under
# its new name, so every case below is the same case with the new flag.
#
# BH-1162 asked for it in so many words: "Whichever is chosen,
# bin/render-doc-index.sh should grow a --check mode so drift is a gate rather
# than a thing someone remembers." The rc contract pinned here:
#   rc 0 = the committed index is exactly what a render would write
#   rc 1 = drift (or no index at all), with a message naming the fix
#   rc 2 = the check itself could not run (no notes dir, no temp dir)
# and on every rc the target's bytes and mtime are untouched.
#
# Drives the real script on a scratch notes dir. Nothing reads a clock.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
R="$DIR/bin/render-doc-index.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

N="$T/notes"; mkdir -p "$N"
note() { printf '# %s\n\nDoc: EVENTS\n' "$2" > "$N/$1"; }
note 2026-09-01-BH-1-one.md "Note one"
note 2026-09-02-BH-2-two.md "Note two"

# The renderer's default layout: docs/notes/INDEX.md under a repo root.
"$R" "$N" "$N/INDEX.md" >/dev/null 2>&1 || bad "the fixture render failed"
touch -d '2026-01-01 00:00:00' "$N/INDEX.md"
SUM0=$(sha256sum < "$N/INDEX.md"); MT0=$(stat -c %Y "$N/INDEX.md")
unchanged() { # unchanged <label>
  [ "$(sha256sum < "$N/INDEX.md")" = "$SUM0" ] && ok || bad "$1: --check-committed changed the index bytes"
  [ "$(stat -c %Y "$N/INDEX.md")" = "$MT0" ] && ok || bad "$1: --check-committed touched the index mtime"
}

# 1. In sync -> rc 0, explicit args.
OUT=$("$R" --check-committed "$N" "$N/INDEX.md" 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "in sync should be rc 0, got rc=$RC: $OUT"
unchanged "in sync"

# 1b. In sync via the env form too (no positional args after the flag).
OUT=$(DOC_NOTES_DIR="$N" DOC_NOTES_INDEX="$N/INDEX.md" "$R" --check-committed 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "in sync via env should be rc 0, got rc=$RC: $OUT"

# 2. A note added without a re-render -> rc 1, the stale message, index untouched.
note 2026-09-03-BH-3-three.md "Note three"
OUT=$("$R" --check-committed "$N" "$N/INDEX.md" 2>&1); RC=$?
[ "$RC" = 1 ] && ok || bad "drift should be rc 1, got rc=$RC: $OUT"
grep -q "is stale" <<<"$OUT" && grep -q 'run bin/render-doc-index.sh' <<<"$OUT" && ok \
  || bad "drift should say the index is stale and name the fix, got: $OUT"
grep -q 'Note three' <<<"$OUT" && ok || bad "drift output should show the missing row, got: $OUT"
unchanged "drift"
grep -q 'Note three' "$N/INDEX.md" && bad "--check-committed must never write the missing row" || ok

# 3. A hand edit to the index is drift too.
cp "$N/INDEX.md" "$T/keep"
"$R" "$N" "$N/INDEX.md" >/dev/null 2>&1
echo "- hand-added row" >> "$N/INDEX.md"
"$R" --check-committed "$N" "$N/INDEX.md" >/dev/null 2>&1; RC=$?
[ "$RC" = 1 ] && ok || bad "a hand-edited index should be rc 1, got rc=$RC"
"$R" "$N" "$N/INDEX.md" >/dev/null 2>&1
"$R" --check-committed "$N" "$N/INDEX.md" >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "after a re-render --check-committed should be rc 0 again, got rc=$RC"

# 4. No index at all is drift, and --check-committed does not create one.
rm -f "$T/n2" ; mkdir -p "$T/n2"; cp "$N"/2026-*.md "$T/n2/"
"$R" --check-committed "$T/n2" "$T/n2/INDEX.md" >/dev/null 2>&1; RC=$?
[ "$RC" = 1 ] && ok || bad "a missing index should be rc 1, got rc=$RC"
[ -e "$T/n2/INDEX.md" ] && bad "--check-committed created the index" || ok

# 5. The check could not run -> rc 2, never rc 0.
"$R" --check-committed "$T/no-such-dir" "$T/x.md" >/dev/null 2>&1; RC=$?
[ "$RC" = 2 ] && ok || bad "a missing notes dir should be rc 2 under --check-committed, got rc=$RC"
"$R" "$N" "$N/INDEX.md" >/dev/null 2>&1
SUM0=$(sha256sum < "$N/INDEX.md"); MT0=$(stat -c %Y "$N/INDEX.md")
OUT=$(TMPDIR="$T/no-such-tmp" "$R" --check-committed "$N" "$N/INDEX.md" 2>&1); RC=$?
[ "$RC" = 2 ] && ok || bad "a render that cannot write its temp file should be rc 2, got rc=$RC: $OUT"
unchanged "render failed"
# No stray temp file next to the target either.
grep -q '^\.render-doc-index' <<<"$(ls -A "$N")" && bad "--check-committed left a temp file beside the index" || ok

# 6. Without a check flag the renderer still writes (the old path is intact).
note 2026-09-04-BH-4-four.md "Note four"
OUT=$("$R" "$N" "$N/INDEX.md" 2>&1); RC=$?
[ "$RC" = 0 ] && grep -q 'Note four' "$N/INDEX.md" && ok || bad "a plain render should still write (rc=$RC: $OUT)"

echo "render-doc-index.bh-1162-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
