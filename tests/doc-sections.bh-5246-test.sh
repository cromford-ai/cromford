#!/bin/bash
# tests/doc-sections.bh-5246-test.sh — BH-5246 (BH-5235.2): docs/PR-OWNERSHIP.md
# is a COMMITTED RENDER of docs/PR-OWNERSHIP.d/NN-<slug>.md, so two PRs that each
# add a section add two files and never conflict on a hunk.
#
#   D0 bin/render-doc-sections.sh exists, is executable, parses, shellchecks.
#   D1 the render of the committed fragments is byte-identical to the doc as it
#      stood before the split (recorded sha) and to the committed doc.
#   D2 every fragment is named NN-<slug>.md, ends in \n, holds no CR, and C
#      order equals en_US order.
#   R1 the REAL renderer over scratch copies (--root): every exit code of the
#      contract in bin/lib/render-fragments.sh.
#   R2 the registry row, the Generated-files row and the guardrail's baked map.
#   R3 real git: two siblings that each add a fragment never conflict in the
#      fragment dir, and a --write over the merge holds both in name order.
#   R4 the CI step and the Verification Contract run the --check.
#   R5 this checkout's render is fresh.
#
# No network, no clock, no gh: scratch trees under $T and nothing else.
#   HARNESS_TEST_SANDBOX=1 bash tests/doc-sections.bh-5246-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
RDS="$DIR/bin/render-doc-sections.sh"
RF="$DIR/bin/lib/render-fragments.sh"
WF="$DIR/.github/workflows/harness-ci.yml"
TAIL="$DIR/docs/verification-map/index/tail.md"
GR="$DIR/guardrails/rendered-file-freshness/check.sh"
DOC=docs/PR-OWNERSHIP.md
FD=docs/PR-OWNERSHIP.d
# The sha256 of docs/PR-OWNERSHIP.md as it stood on main when this split landed
# (main at 16beb2c47, after #4051 (BH-3936) built the superseded close and the
# health rollup; the split was first cut at cde670a2d, sha a33610460b2999f4,
# and re-cut onto #4051's text, so the pin moved with it): its
# first 16 hex digits (64 bits), ample for a byte-identity check. The full
# 64-hex digest is the shape of a secret, and the public-mirror leak check
# (bin/share/leakcheck.py, "64-hex token") refuses it; BH-5244 made the same
# change in tests/prompt-sections.bh-5235-test.sh.
# TEST-CHANGE (BH-3935, #4108): the age ladder's own text (§2, §9, §10) landed in
# the fragments on the merge with main, so the pin moved again, from
# 1aba15684e120b1b to the render of that text.
# TEST-CHANGE (BH-3933, #5087): enroll, the ownerless clock and the D1 kill knob
# (§0, §2, §7, §8, §9, §10) landed in the fragments, so the pin moved from
# 5ad22a891b2e6d27 to the render of that text.
# TEST-CHANGE (BH-6814, #6846): the stacked-PR guard and the close-path ticket
# HOLD (§10, rule 3 and the to_merge_hold paragraph) landed in the fragments,
# so the pin moved from 28fd59dcde365903 to the render of that text.
# TEST-CHANGE (BH-6815): the done-ticket close guard landed as a new section,
# docs/PR-OWNERSHIP.d/11-done-close-guard.md, so the pin moved from
# 5e31bf4f72404d51 (main after #6846) to the render of both texts and the
# fragment count is 12.
BASE_SHA=275bfb50c596fe8d
STEP='lane renders generate and their sources validate'

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }

# ============================================================================
# D0 the renderer ships runnable
# ============================================================================
if [ -x "$RDS" ]; then ok; else bad "D0: $RDS missing or not executable"; fi
bash -n "$RDS" 2>/dev/null && ok || bad "D0: bash -n bin/render-doc-sections.sh"
if command -v shellcheck >/dev/null; then
  shellcheck --severity=error "$RDS" >/dev/null 2>&1 && ok || bad "D0: shellcheck --severity=error bin/render-doc-sections.sh"
else
  echo "SKIP: D0 shellcheck not installed"
fi

# A scratch root carrying the committed fragments and doc.
seed() { # seed <root>
  mkdir -p "$1/docs"
  cp -R "$DIR/$FD" "$1/$FD" 2>/dev/null || mkdir -p "$1/$FD"
  cp "$DIR/$DOC" "$1/$DOC"
}

# ============================================================================
# D1 the split moved bytes, it did not rewrite them
# ============================================================================
seed "$T/d1"
"$RDS" --root "$T/d1" > "$T/d1.out" 2> "$T/d1.err"; rc=$?
eq "D1 print rc" "$rc" 0
eq "D1 render sha = recorded pre-split sha" "$(sha256sum < "$T/d1.out" | cut -c1-16)" "$BASE_SHA"
cmp -s "$T/d1.out" "$DIR/$DOC" && ok || bad "D1: the render does not cmp equal to the committed $DOC"

# ============================================================================
# D2 the fragments themselves
# ============================================================================
mapfile -t NAMES < <(cd "$DIR/$FD" 2>/dev/null && LC_ALL=C ls -1)
eq "D2 fragment count" "${#NAMES[@]}" 12
for n in "${NAMES[@]}"; do
  f="$DIR/$FD/$n"
  [[ "$n" =~ ^[0-9]{2}-[a-z0-9-]+\.md$ ]] && ok || bad "D2: $n is not NN-<slug>.md"
  [ -s "$f" ] && ok || bad "D2: $n is empty"
  [ -z "$(tail -c1 "$f")" ] && ok || bad "D2: $n does not end in a newline"
  c=$(grep -c $'\r' "$f") || c=0
  eq "D2 $n CR count" "$c" 0
done
loc=en_US.UTF-8
if ! grep -qi '^en_US\.utf-\?8$' <<<"$(locale -a 2>/dev/null)"; then
  echo "SKIP: D2 en_US.UTF-8 not installed, comparing against C.UTF-8"; loc=C.UTF-8
fi
eq "D2 C order = $loc order" "$(printf '%s\n' "${NAMES[@]}" | LC_ALL=C sort)" "$(printf '%s\n' "${NAMES[@]}" | LC_ALL=$loc sort)"

# ============================================================================
# R1 the exit-code contract, from the REAL renderer
# ============================================================================
R="$T/r1"; seed "$R"
out=$("$RDS" --root "$R" --check); rc=$?
eq "R1 clean --check rc" "$rc" 0
eq "R1 clean --check stdout" "$out" ""

# TEST-CHANGE (BH-6815): the line goes into the fragment that sorts LAST, so
# it is still the written doc's last line now that 10-hooks.md is not last.
LASTF=$(cd "$R/$FD" && LC_ALL=C ls -1 | tail -n 1)
printf 'an added hooks line\n' >> "$R/$FD/$LASTF"
out=$("$RDS" --root "$R" --check); rc=$?
eq "R1 edited fragment --check rc" "$rc" 1
eq "R1 edited fragment first line" "$(head -1 <<<"$out")" "DRIFT $DOC"

"$RDS" --root "$R" --write; rc=$?
eq "R1 --write rc" "$rc" 0
"$RDS" --root "$R" --check >/dev/null; rc=$?
eq "R1 --check after --write rc" "$rc" 0
eq "R1 written doc's last line" "$(tail -1 "$R/$DOC")" "an added hooks line"
s1=$(sha256sum < "$R/$DOC")
"$RDS" --root "$R" --write; rc=$?
eq "R1 second --write rc" "$rc" 0
eq "R1 second --write is byte-identical" "$(sha256sum < "$R/$DOC")" "$s1"

# a fragment without its trailing newline would glue two sections together
cp "$R/$FD/04-alerts.md" "$T/04.keep"
printf 'x' > "$R/$FD/04-alerts.md"
"$RDS" --root "$R" > "$T/nl.out" 2> "$T/nl.err"; rc=$?
eq "R1 no-newline print rc" "$rc" 3
grep -q "$FD/04-alerts.md" "$T/nl.err" && ok || bad "R1: no-newline refusal does not name the fragment on stderr: $(cat "$T/nl.err")"
[ ! -s "$T/nl.out" ] && ok || bad "R1: no-newline print wrote stdout"
"$RDS" --root "$R" --write 2>/dev/null; rc=$?
eq "R1 no-newline --write rc" "$rc" 3
eq "R1 no-newline --write leaves the doc" "$(sha256sum < "$R/$DOC")" "$s1"
out=$("$RDS" --root "$R" --check 2>/dev/null); rc=$?
eq "R1 no-newline --check rc" "$rc" 2
case "$out" in *DRIFT*) bad "R1: a refused render under --check printed DRIFT" ;; *) ok ;; esac
: > "$R/$FD/04-alerts.md"
"$RDS" --root "$R" >/dev/null 2>&1; rc=$?
eq "R1 empty fragment print rc" "$rc" 3
cp "$T/04.keep" "$R/$FD/04-alerts.md"

printf '## bad\n' > "$R/$FD/1-bad.md"
"$RDS" --root "$R" >/dev/null 2>&1; rc=$?
eq "R1 bad name print rc" "$rc" 3
rm -f "$R/$FD/1-bad.md"
printf '## Upper\n' > "$R/$FD/11-Upper.md"
"$RDS" --root "$R" >/dev/null 2>&1; rc=$?
eq "R1 uppercase name print rc" "$rc" 3
rm -f "$R/$FD/11-Upper.md"
printf 'ignored\n' > "$R/$FD/11-notes.txt"
"$RDS" --root "$R" --check >/dev/null 2>&1; rc=$?
eq "R1 a .txt beside the fragments is ignored" "$rc" 0
rm -f "$R/$FD/11-notes.txt"

printf '## crlf\r\n' > "$R/$FD/11-crlf.md"
"$RDS" --root "$R" >/dev/null 2>&1; rc=$?
eq "R1 CR print rc" "$rc" 3
rm -f "$R/$FD/11-crlf.md"
"$RDS" --root "$R" --check >/dev/null; rc=$?
eq "R1 restored tree --check rc" "$rc" 0

E="$T/r1-empty"; mkdir -p "$E/$FD"; cp "$DIR/$DOC" "$E/$DOC"
"$RDS" --root "$E" >/dev/null 2>&1; rc=$?
eq "R1 empty .d print rc" "$rc" 2
"$RDS" --root "$E" --check >/dev/null 2>&1; rc=$?
eq "R1 empty .d --check rc" "$rc" 2
rmdir "$E/$FD"
"$RDS" --root "$E" >/dev/null 2>&1; rc=$?
eq "R1 missing .d print rc" "$rc" 2

"$RDS" --root "$R" --write --check >/dev/null 2>&1; rc=$?
eq "R1 two modes rc" "$rc" 2
"$RDS" --root "$R" --frobnicate >/dev/null 2>&1; rc=$?
eq "R1 unknown flag rc" "$rc" 2
"$RDS" --root "$R" docs/PR-OWNERSHIP.txt >/dev/null 2>&1; rc=$?
eq "R1 non-.md doc rc" "$rc" 2
"$RDS" --root "$T/nowhere" >/dev/null 2>&1; rc=$?
eq "R1 bad root rc" "$rc" 2

M="$T/r1-missing"; seed "$M"; rm -f "$M/$DOC"
out=$("$RDS" --root "$M" --check); rc=$?
eq "R1 missing doc --check rc" "$rc" 1
eq "R1 missing doc first line" "$(head -1 <<<"$out")" "DRIFT $DOC"
"$RDS" --root "$M" "$DOC" > "$T/explicit.out"; rc=$?
eq "R1 explicit doc arg rc" "$rc" 0
cmp -s "$T/explicit.out" "$DIR/$DOC" && ok || bad "R1: an explicit doc arg does not render the same bytes"

# ============================================================================
# R2 the declared row, in each of its three spellings
# ============================================================================
ROW=$'docs/PR-OWNERSHIP.md\tdocs/PR-OWNERSHIP.d/\tbin/render-doc-sections.sh --write'
REG=$( . "$RF"; rf_registry )
eq "R2 rf_registry rows for $DOC" "$(printf '%s\n' "$REG" | awk -F'\t' -v d="$DOC" '$1 == d' | grep -c .)" 1
eq "R2 rf_registry row" "$(printf '%s\n' "$REG" | awk -F'\t' -v d="$DOC" '$1 == d')" "$ROW"
grep -qxF '| `docs/PR-OWNERSHIP.md` | `bin/render-doc-sections.sh --write` | committed |' "$TAIL" \
  && ok || bad "R2: tail.md's Generated-files table has no committed row for $DOC"
MAP=$(awk '/^# >>> rff default map/ { inb = 1; next } /^# <<< rff default map/ { inb = 0 } inb' "$GR" | tr '|' '\t')
grep -qxF "$ROW" <<<"$MAP" && ok || bad "R2: the guardrail's baked map has no row for $DOC"

# ============================================================================
# R3 two siblings, two fragments, no fragment conflict
# ============================================================================
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.email t@example.com
git config --global user.name t
git config --global init.defaultBranch main
git config --global commit.gpgsign false
G="$T/r3"; seed "$G"
git init -q -b main "$G"
git -C "$G" add -A && git -C "$G" commit -qm base
git -C "$G" checkout -qb a
printf '## 11. Section from a\n\nalpha text\n' > "$G/$FD/11-a.md"
"$RDS" --root "$G" --write
git -C "$G" add -A && git -C "$G" commit -qm a
git -C "$G" checkout -q main && git -C "$G" checkout -qb b
printf '## 11. Section from b\n\nbravo text\n' > "$G/$FD/11-b.md"
"$RDS" --root "$G" --write
git -C "$G" add -A && git -C "$G" commit -qm b
MT=$(git -C "$G" merge-tree --write-tree --name-only a b); mrc=$?
CONF=$(printf '%s\n' "$MT" | awk 'NR>1 { if (NF == 0) exit; print }')
if [ "$mrc" -gt 1 ]; then
  bad "R3: git merge-tree --write-tree could not run (rc $mrc)"
else
  case "$CONF" in *"$FD/"*) bad "R3: a fragment conflicted: $CONF" ;; *) ok ;; esac
fi
git -C "$G" checkout -q a
git -C "$G" merge -q --no-edit b >/dev/null 2>&1 || {
  git -C "$G" checkout -q --theirs -- "$DOC"
  git -C "$G" add -- "$DOC"
}
"$RDS" --root "$G" --write; rc=$?
eq "R3 --write over the merge rc" "$rc" 0
ia=$(grep -n '^alpha text$' "$G/$DOC" | cut -d: -f1)
ib=$(grep -n '^bravo text$' "$G/$DOC" | cut -d: -f1)
if [ -n "$ia" ] && [ -n "$ib" ] && [ "$ia" -lt "$ib" ]; then ok; else bad "R3: merged render lacks both sections in name order (a@${ia:-none} b@${ib:-none})"; fi
"$RDS" --root "$G" --check >/dev/null; rc=$?
eq "R3 --check after merge" "$rc" 0
git -C "$G" add -A && git -C "$G" commit -qm merged >/dev/null 2>&1
eq "R3 merge committed clean" "$(git -C "$G" status --porcelain)" ""
# non-vacuity: the detector above does see a conflict when one is there
git -C "$G" checkout -q main && git -C "$G" checkout -qb c
printf 'c edit\n' > "$G/$FD/04-alerts.md"; git -C "$G" commit -qam c
git -C "$G" checkout -q main && git -C "$G" checkout -qb d
printf 'd edit\n' > "$G/$FD/04-alerts.md"; git -C "$G" commit -qam d
MT=$(git -C "$G" merge-tree --write-tree --name-only c d)
CONF=$(printf '%s\n' "$MT" | awk 'NR>1 { if (NF == 0) exit; print }')
case "$CONF" in *"$FD/04-alerts.md"*) ok ;; *) bad "R3: same-line edits to one fragment showed no conflict, so the detector proves nothing" ;; esac

# ============================================================================
# R4 CI and the Verification Contract run the check
# ============================================================================
BLOCK=$(awk -v n="- name: $STEP" '
  index($0, n) { inb = 1; next }
  inb && /^[[:space:]]*- name:/ { exit }
  inb { print }
' "$WF")
if [ -z "$BLOCK" ]; then
  bad "R4: no step named '$STEP' in $WF"
else
  N=$(printf '%s\n' "$BLOCK" | grep -c '^ *bin/render-doc-sections\.sh --check$')
  eq "R4 CI --check lines" "$N" 1
  N=$(printf '%s\n' "$BLOCK" | grep -c 'render-doc-sections\.sh --write')
  eq "R4 CI --write lines" "$N" 0
fi
VC=$(awk '/^```bash$/ { inb = 1; next } inb && /^```/ { exit } inb' "$DIR/CLAUDE.md" | grep -v '^#' | grep -m1 .)
case "$VC" in
  *'HARNESS_TEST_SANDBOX=1 bin/render-doc-sections.sh --check'*) ok ;;
  *) bad "R4: the Verification Contract's first command does not run bin/render-doc-sections.sh --check" ;;
esac

# ============================================================================
# R5 this checkout's committed render is fresh
# ============================================================================
"$RDS" --root "$DIR" --check; rc=$?
eq "R5 --check over this checkout" "$rc" 0

echo "doc-sections.bh-5246: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
