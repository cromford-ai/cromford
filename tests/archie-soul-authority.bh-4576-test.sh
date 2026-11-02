#!/bin/bash
# tests/archie-soul-authority.bh-4576-test.sh — BH-4576: Archie's soul
# (prompts/archie-soul.d/, checked here as its concat) describes the
# factory-manager role. It carries the `Runs the factory` lane and the MAY / NEVER / REPORT authority blocks, keeps
# the voice traits and the initiative command block, and no longer tells Archie
# to ask before merges, rebases or fix rounds. The two places that read it
# still do: compose_v2_prompt and run_survival in bin/orchestrate.sh, and the
# check-prompt assembly in bin/archie.sh, both lifted from the SHIPPED scripts.
#
# The ticket names this suite tests/archie-soul-authority-test.sh; it ships
# under the per-ticket name.
#
# Sections: A (the soul's content), O (orchestrate.sh), C (archie.sh),
# X (mutation: the pre-BH-4576 soul must be red).
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/archie-soul-authority.bh-4576-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
T="$SCRATCH"
cat "$DIR"/prompts/archie-soul.d/*.md > "$T/soul.md"; SOUL="$T/soul.md"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }

# No network: anything that tries is logged and fails.
mkdir -p "$T/fakebin"
for c in curl gh; do
  printf '#!/bin/bash\nprintf "%%s %%s\\n" %s "$*" >> "%s/net.log"\nexit 7\n' "$c" "$T" > "$T/fakebin/$c"
  chmod +x "$T/fakebin/$c"
done
export PATH="$T/fakebin:$PATH"

# soul_checks <file> [quiet]: the A-checks over one soul file. Prints a FAIL
# line per miss (unless quiet) and echoes the miss count on its last line.
# Block checks join the block onto one line: prose wraps anywhere.
# Each block is read into blk before grep (BH-8937): sed piped into grep -q
# under pipefail is rc 141 when sed still writes after grep exits.
soul_checks() {
  local f="$1" q="${2:-}" n=0 s blk
  sc_bad() { n=$((n+1)); [ -n "$q" ] || echo "FAIL: $1" >&2; }
  [ -s "$f" ] || sc_bad "A1 the soul exists and is non-empty"
  grep -q '^MAY, without asking:' "$f" || sc_bad "A2 a line starts 'MAY, without asking:'"
  blk=$(sed -n '/^MAY, without asking:/,/^NEVER:/p' "$f" | tr '\n' ' ')
  for s in rebase 'fix round' enqueue 'HOLD/RESUME' ai-build; do
    grep -qF "$s" <<<"$blk" || sc_bad "A2 the MAY block names [$s]"
  done
  grep -q '^NEVER:' "$f" || sc_bad "A3 a line starts 'NEVER:'"
  blk=$(sed -n '/^NEVER:/,/^REPORT:/p' "$f" | tr '\n' ' ')
  for s in 'gh pr merge' 'push to main' 'production DB write' 'spend cap'; do
    grep -qF "$s" <<<"$blk" || sc_bad "A3 the NEVER block names [$s]"
  done
  grep -q '^REPORT:' "$f" || sc_bad "A4 a line starts 'REPORT:'"
  blk=$(sed -n '/^REPORT:/,/^$/p' "$f" | tr '\n' ' ')
  for s in 'daily factory digest' 'stop-the-line'; do
    grep -qF "$s" <<<"$blk" || sc_bad "A4 the REPORT block names [$s]"
  done
  awk '/^MAY, without asking:/{m=NR} /^NEVER:/{v=NR} /^REPORT:/{r=NR}
       END{exit !(m && v && r && m < v && v < r)}' "$f" || sc_bad "A5 MAY comes before NEVER before REPORT"
  for s in 'MUST ASK: merges' 'MUST ASK' 'asks before anything touching clients, money or production' 'waits for the operator'; do
    grep -qiF "$s" "$f" && sc_bad "A6 the soul still says [$s]"
  done
  for s in 'Runs the factory' 'Acts first within the gates'; do
    grep -qF "$s" "$f" || sc_bad "A7 the lane says [$s]"
  done
  for s in 'Owner, not assistant.' 'Curious and restless.' 'Measures before he brags.' "Respects the operator's attention." 'Has opinions.' 'De-AI'; do
    grep -qF "$s" "$f" || sc_bad "A8 the trait [$s] is kept"
  done
  blk=$(sed -n '/^Initiatives\./,$p' "$f")
  for s in 'Archie, track <goal> | metric:' 'Archie approve I<n> / Archie change I<n> <what> / Archie drop I<n>'; do
    grep -qF "$s" <<<"$blk" || sc_bad "A9 the initiative block keeps [$s]"
  done
  echo "$n"
}

# ═════ A: the shipped soul ═══════════════════════════════════════════════════
misses=$(soul_checks "$SOUL" 2> "$T/a.err" | tail -1)
cat "$T/a.err"
if [ "$misses" = 0 ]; then ok; else bad "A the shipped soul has $misses miss(es), listed above"; fi
# A10: the ordered line-by-line view the A-checks lean on (each label owns a line).
eq_count=$(grep -c '^MAY, without asking:\|^NEVER:\|^REPORT:' "$SOUL")
check "A10 exactly one MAY, NEVER and REPORT line" '[ "$eq_count" = 3 ]'

# ═════ O: bin/orchestrate.sh still injects it ════════════════════════════════
SRC="$DIR/bin/orchestrate.sh"
mkdir -p "$T/h/prompts" "$T/h/bin"
cp -r "$DIR/prompts/archie-soul.d" "$T/h/prompts/"
printf '#!/bin/bash\necho "(history)"\n' > "$T/h/bin/orc-context.sh"
chmod +x "$T/h/bin/orc-context.sh"
FN=$(sed -n '/^compose_v2_prompt() {/,/^}/p' "$SRC")
check "O1 compose_v2_prompt was lifted" '[ -n "$FN" ]'
P=$(env HARNESS="$T/h" TEXT=hi META_TRANSPORT=telegram ORIGIN="" bash -c "$FN"$'\n''compose_v2_prompt' 2>/dev/null)
check "O1 the v2 prompt carries the WHO YOU ARE marker" 'grep -qF "=== WHO YOU ARE (prompts/archie-soul.md) ===" <<<"$P"'
check "O1 the v2 prompt carries the MAY block" 'grep -qF "MAY, without asking:" <<<"$P"'
check "O1 the v2 prompt carries the NEVER block" 'grep -q "^NEVER:" <<<"$P"'
check "O1 the v2 prompt has no MUST ASK" '! grep -qiF "MUST ASK" <<<"$P"'
check "O1 the marker comes before the MAY line" \
  'mk=$(grep -nF "=== WHO YOU ARE" <<<"$P" | head -1 | cut -d: -f1); ml=$(grep -nF "MAY, without asking:" <<<"$P" | head -1 | cut -d: -f1); [ -n "$mk" ] && [ -n "$ml" ] && [ "$mk" -lt "$ml" ]'
check "O2 run_survival appends the soul" \
  'grep -qF "prompts/archie-soul.d" <<<"$(sed -n "/^run_survival() {/,/^}/p" "$SRC")"'

# ═════ C: bin/archie.sh puts it first in the check prompt ════════════════════
BLK=$(sed -n '/cat "\$H"\/prompts\/archie-soul\.d/,/> "\$pf"/p' "$DIR/bin/archie.sh")
check "C1 the check-prompt block was lifted" '[ -n "$BLK" ]'
check "C1 the soul is cat before archie-check.md" \
  'ls_=$(grep -n "prompts/archie-soul.d" <<<"$BLK" | head -1 | cut -d: -f1); lc=$(grep -n "catalog/prompts/archie-check.md" <<<"$BLK" | head -1 | cut -d: -f1); [ -n "$ls_" ] && [ -n "$lc" ] && [ "$ls_" -lt "$lc" ]'
mkdir -p "$T/h/catalog/prompts"
echo "CHECK-PROMPT" > "$T/h/catalog/prompts/archie-check.md"
printf '%s\n' "$BLK" > "$T/blk.sh"
env H="$T/h" pf="$T/pf" row='{}' v= due= NOWISO= bash -c '. "$1"' _ "$T/blk.sh" 2>/dev/null
check "C1 the prompt file starts with the soul's first line" '[ "$(head -1 "$T/pf")" = "$(head -1 "$SOUL")" ]'
check "C1 the prompt file carries the MAY block" 'grep -qF "MAY, without asking:" "$T/pf"'
check "C1 the check prompt follows the soul" 'grep -qF "CHECK-PROMPT" "$T/pf"'

# ═════ X: the pre-BH-4576 soul is red (non-vacuity) ══════════════════════════
if ! git -C "$DIR" show 327cf5e9d:prompts/archie-soul.md > "$T/old-soul.md" 2>/dev/null || [ ! -s "$T/old-soul.md" ]; then
  # Shallow checkout: the two Authority lines that BH-4576 removed, verbatim.
  cat > "$T/old-soul.md" <<'OLD'
> - **Knows his lane.** Fixes freely inside his authority; asks before anything touching clients, money or production.

Authority. MAY: comment, HOLD/RESUME, file `ai-build` tickets, write ideas into
the existing Ideas ledger. MUST ASK: merges, deploys, client-board writes,
spend-cap changes, harness code or rule changes (those go as PRs through normal
review).
OLD
fi
xm=$(soul_checks "$T/old-soul.md" quiet 2>/dev/null | tail -1)
check "X1 the pre-BH-4576 soul is red ($xm misses)" '[ "${xm:-0}" -gt 0 ]'
# X2: the A6 negative alone fires on the old soul (not only the missing blocks).
check "X2 the A6 negative fires on the old soul" \
  'soul_checks "$T/old-soul.md" 2>&1 >/dev/null | grep "^FAIL: A6" >/dev/null'
# X3: a soul that drops the MAY line goes red even with everything else intact.
grep -v '^MAY, without asking:' "$SOUL" > "$T/no-may.md"
xm=$(soul_checks "$T/no-may.md" quiet 2>/dev/null | tail -1)
check "X3 a soul with no MAY line is red" '[ "${xm:-0}" -gt 0 ]'

check "N1 nothing reached the network" '[ ! -s "$T/net.log" ]'

echo "archie-soul-authority: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
