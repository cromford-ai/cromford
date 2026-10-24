#!/bin/bash
# tests/no-cloud-mcp-impact.bh-8192-test.sh — BH-8192: a change under mcp/test/
# runs tests/no-cloud-in-engine.bh-5239-test.sh in its own PR CI.
#
# #7749 added the Cloud path as a literal to mcp/test/batch-failure.test.mjs.
# The impact map did not select the no-cloud suite for that diff, so the PR was
# green and main went red. The hand learned edge
# catalog/test-impact-learned.d/8c18f206ca6a2e11.tsv maps mcp/test/ onto it.
#
#   M1  a change to mcp/test/batch-failure.test.mjs selects the no-cloud suite
#   M2  a new file mcp/test/new.test.mjs selects it (a directory row); the near
#       misses mcp/src/x.mjs and mcp/testdata/x do not select it as `learned`
#   M3  a scratch repo whose mcp/test/a.test.mjs names the Cloud path: the
#       no-cloud suite gives rc 1 and names the file
#   M4  the same file with the path built by concatenation: rc 0
#   M5  no file under this checkout's mcp/ names the Cloud path
#
# The Cloud path is built by concatenation, so this file never matches itself.
# Self-contained: no network, no vendor, scratch data per run.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/no-cloud-mcp-impact.bh-8192-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)

P='worker/''cloud'
NC_RE="${P}([^A-Za-z0-9_-]|\$)"
NC=tests/no-cloud-in-engine.bh-5239-test.sh
TI="$DIR/bin/test-impact.sh"
NOTE=docs/notes/2026-10-12-BH-5239-cloud-moved.md

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL $1"; }

# ── M1 + M2: the real map ────────────────────────────────────────────────────
# One select per path: one path of unknown reach makes the whole answer `full`.
n=0
for f in mcp/test/batch-failure.test.mjs mcp/test/new.test.mjs; do
  n=$((n+1)); id=M$n
  printf '%s\n' "$f" > "$T/in$n.txt"
  WHY=$("$TI" select --changed "$T/in$n.txt" --why 2>/dev/null); RC=$?
  if [ "$RC" = 0 ] && grep -qP "^\Q$NC\E\tlearned\t" <<<"$WHY"; then
    ok "$id: a change to $f selects $NC (learned)"
  else
    bad "$id: a change to $f must select $NC as learned; rc $RC, got: $(grep -F "$NC" <<<"$WHY" || echo '<absent>')"
  fi
done

printf 'mcp/src/x.mjs\nmcp/testdata/x\n' > "$T/out.txt"
WHY_OUT=$("$TI" select --changed "$T/out.txt" --why 2>/dev/null); RC=$?
[ "$RC" = 0 ] || bad "M2: select over the near misses exited $RC"
if grep -qP "^\Q$NC\E\tlearned\t" <<<"$WHY_OUT"; then
  bad "M2: mcp/src/x.mjs or mcp/testdata/x must not select $NC as learned: $(grep -F "$NC" <<<"$WHY_OUT")"
else
  ok "M2: mcp/src/x.mjs and mcp/testdata/x do not select $NC as learned"
fi

# ── M3 + M4: the no-cloud suite over a scratch repo ──────────────────────────
seed() { # $1 = dir, $2 = the line for mcp/test/a.test.mjs
  git init -q "$1" && git -C "$1" config user.name m3 && git -C "$1" config user.email m3@example.invalid
  mkdir -p "$1/docs/notes" "$1/mcp/test"
  printf 'Moved to example-org/cromford-web; it was %s.\n' "$P" > "$1/$NOTE"
  printf '%s\n' "$2" > "$1/mcp/test/a.test.mjs"
  git -C "$1" add -A && git -C "$1" commit -qm seed
}
R="$T/m3"
seed "$R" "const s = 'FAIL: C7 1 public file(s) name $P';"
OUT=$(NC_ROOT="$R" NC_NO_MIRROR=1 bash "$DIR/$NC" 2>&1); RC=$?
if [ "$RC" = 1 ] && [[ "$OUT" == *"mcp/test/a.test.mjs names the Cloud path"* ]]; then
  ok "M3: a literal Cloud path in mcp/test/a.test.mjs gives rc 1 and is named"
else
  bad "M3: want rc 1 naming mcp/test/a.test.mjs, got rc $RC: $OUT"
fi
R="$T/m4"
seed "$R" "const CLOUD = 'worker/' + 'cloud';"
OUT=$(NC_ROOT="$R" NC_NO_MIRROR=1 bash "$DIR/$NC" 2>&1); RC=$?
if [ "$RC" = 0 ]; then ok "M4: the concatenated form gives rc 0"
else bad "M4: want rc 0 for the concatenated form, got rc $RC: $OUT"; fi

# ── M5: this checkout ────────────────────────────────────────────────────────
HITS=$(git -C "$DIR" grep -lE "$NC_RE" -- mcp/ 2>/dev/null)
if [ -z "$HITS" ]; then ok "M5: no file under mcp/ names the Cloud path"
else bad "M5: files under mcp/ name the Cloud path: $(tr '\n' ' ' <<<"$HITS")"; fi

echo "no-cloud-mcp-impact.bh-8192: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
