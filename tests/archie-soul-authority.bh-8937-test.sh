#!/bin/bash
# tests/archie-soul-authority.bh-8937-test.sh — BH-8937: the nightly A9 red in
# tests/archie-soul-authority.bh-4576-test.sh was a SIGPIPE race, not a soul
# regression. Under pipefail, `sed ... | grep -qF` is rc 141 when grep exits
# at its match while sed still has a second pipe write (the Initiatives block
# is over 4096 bytes). This suite makes the race deterministic with a sed shim
# that writes 4096 bytes, sleeps, then writes the rest, and proves the 4576
# suite now reads each block to EOF before grep.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/archie-soul-authority.bh-8937-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
T="$SCRATCH"
SUITE="$DIR/tests/archie-soul-authority.bh-4576-test.sh"
cat "$DIR"/prompts/archie-soul.d/*.md > "$T/soul.md"; SOUL="$T/soul.md"
REAL_SED=$(command -v sed)

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }

# The two-write sed shim: same bytes as the real sed, second write delayed.
mkdir -p "$T/shim"
cat > "$T/shim/sed" <<SHIM
#!/bin/bash
o="$T/shim/out.\$\$"
"$REAL_SED" "\$@" > "\$o" || exit \$?
head -c 4096 "\$o"; sleep 0.2
exec tail -c +4097 "\$o"
SHIM
chmod +x "$T/shim/sed"
SHIMPATH="$T/shim:$PATH"

# R5: the shim changes timing only, never the bytes.
"$REAL_SED" -n '/^Initiatives\./,$p' "$SOUL" > "$T/real.out"
PATH="$SHIMPATH" sed -n '/^Initiatives\./,$p' "$SOUL" > "$T/shim.out"
check "R5 shim output is byte-identical to real sed" 'cmp -s "$T/real.out" "$T/shim.out"'
check "R5 the Initiatives block is over 4096 bytes (the race needs two writes)" \
  '[ "$(wc -c < "$T/real.out")" -gt 4096 ]'

# R1 non-vacuity: the OLD pipe shape under the shim reports a miss.
PATH="$SHIMPATH" bash -c 'set -o pipefail; sed -n "/^Initiatives\./,\$p" "$1" | grep -qF "Archie, track <goal> | metric:"' _ "$SOUL"
r1=$?
check "R1 the old sed|grep -q shape is red under the shim (rc $r1)" '[ "$r1" != 0 ]'

# R2: the shipped soul_checks, lifted from the 4576 suite, has 0 misses under the shim.
FN=$("$REAL_SED" -n '/^soul_checks() {/,/^}/p' "$SUITE")
check "R2 soul_checks was lifted" '[ -n "$FN" ]'
misses=$(PATH="$SHIMPATH" bash -c "set -uo pipefail; $FN"$'\n''soul_checks "$1"' _ "$SOUL" 2> "$T/r2.err" | tail -1)
cat "$T/r2.err"
check "R2 soul_checks under the shim has 0 misses (got [$misses])" '[ "$misses" = 0 ]'

# R3: the whole 4576 suite is green under the shim.
PATH="$SHIMPATH" HARNESS_TEST_SANDBOX=1 bash "$SUITE" > "$T/r3.out" 2>&1
r3=$?
check "R3 the 4576 suite exits 0 under the shim (rc $r3)" '[ "$r3" = 0 ]'
check "R3 the 4576 suite prints 18 passed, 0 failed under the shim" \
  'grep -qF "archie-soul-authority: 18 passed, 0 failed" "$T/r3.out"'
[ "$r3" = 0 ] || cat "$T/r3.out"

# R4: no producer piped into grep -q is left in the 4576 suite.
r4=$(grep -cE '\| *grep -q' "$SUITE")
check "R4 the 4576 suite has no '| grep -q' line (got $r4)" '[ "$r4" = 0 ]'

echo "archie-soul-authority-bh-8937: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
