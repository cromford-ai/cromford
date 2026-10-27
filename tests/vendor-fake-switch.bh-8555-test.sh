#!/bin/bash
# tests/vendor-fake-switch.bh-8555-test.sh — BH-8555: ONE vendor fake switch.
# HARNESS_VENDOR_FAKE (fixtures in tests/fixtures/vendor-fake, override
# HARNESS_VENDOR_FAKE_DIR) is the keeper. The BH-7974 name is a retired alias,
# read only inside vendor_fake_on in bin/lib/vendor/_common.sh, for one release.
#
#   S1-S15  vendor_fake_on decision table: rc 0 fake, 1 real, 2 unknown value
#   S-prod  bin/lib/vendor/xai.sh probe with a typo switch exits 99, no call
#   L1-L12  the retired-name matcher on a scratch git tree (red and near misses)
#   L-tree  the matcher on this checkout: 0 hits
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/vendor-fake-switch.bh-8555-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }

# The retired names, built from parts so this file is not its own hit.
RM="HARNESS_VENDOR""_MODE"
RD="VENDOR_FAKE""_DIR"
RP="tests/fakes""/vendor"

# ── S: the decision table ───────────────────────────────────────────────────
# sw <fake|-> <mode|-> — rc of vendor_fake_on in a clean subshell ('-' = unset).
sw() {
  ( unset HARNESS_VENDOR_FAKE "$RM"
    [ "$1" = - ] || export HARNESS_VENDOR_FAKE="$1"
    [ "$2" = - ] || export "$RM=$2"
    # shellcheck source=bin/lib/vendor/_common.sh
    . "$DIR/bin/lib/vendor/_common.sh" || exit 98
    declare -F vendor_fake_on >/dev/null || exit 97
    vendor_fake_on ) 2> "$T/sw.err"
}
echo "S: vendor_fake_on"
n=0
while read -r f m want; do
  n=$((n+1))
  sw "$f" "$m"; rc=$?
  [ "$rc" = "$want" ] && ok "S$n fake=$f alias=$m -> $want" || bad "S$n fake=$f alias=$m: rc $rc, want $want"
  if [ "$n" = 5 ]; then
    c=$(grep -c "$RM is retired" "$T/sw.err")
    [ "$c" = 1 ] && ok "S5 one deprecation line" || bad "S5 deprecation lines: $c ($(cat "$T/sw.err"))"
  fi
done <<'EOF'
- - 1
0 real 1
0 - 1
1 - 0
- fake 0
- real 1
0 fake 0
1 real 0
yes - 2
true - 2
2 - 2
- Fake 2
- FAKE 2
- fakes 2
1 bogus 2
EOF
sw '' '' ; [ $? = 1 ] && ok "S2b empty strings are real" || bad "S2b empty strings are not real"
sw ' 1' - ; [ $? = 2 ] && ok "S11b ' 1' is unknown" || bad "S11b ' 1' is not unknown"

# ── S-prod: the seam itself fails closed, no call ───────────────────────────
echo "S-prod: xai.sh probe"
H="$T/h"; mkdir -p "$H/tests/fixtures" "$T/shim"
( cd "$DIR" && scratch_install_closure bin/lib/vendor/xai.sh "$H" ) >/dev/null 2>&1 || bad "setup: could not install xai.sh"
cp -r "$DIR/tests/fixtures/vendor-fake" "$H/tests/fixtures/vendor-fake"
COUNT="$T/calls"; : > "$COUNT"
printf '#!/bin/bash\necho "curl" >> "%s"\nexit 7\n' "$COUNT" > "$T/shim/curl"; chmod +x "$T/shim/curl"
for f in yes true; do
  : > "$COUNT"
  printf 'tok-fixture-xai-good' | env -u "$RM" PATH="$T/shim:$PATH" HARNESS_VENDOR_FAKE="$f" \
    "$H/bin/lib/vendor/xai.sh" probe > "$T/out" 2> "$T/err"; rc=$?
  [ "$rc" = 99 ] && grep -q 'unknown fake switch value' "$T/err" && [ ! -s "$COUNT" ] \
    && ok "S-prod HARNESS_VENDOR_FAKE=$f: exit 99, names the switch, 0 calls" \
    || bad "S-prod HARNESS_VENDOR_FAKE=$f: rc $rc, err=$(cat "$T/err"), calls=$(wc -l < "$COUNT")"
done
: > "$COUNT"
printf 'tok-fixture-xai-good' | env -u HARNESS_VENDOR_FAKE PATH="$T/shim:$PATH" "$RM=fake" \
  "$H/bin/lib/vendor/xai.sh" probe > "$T/out" 2> "$T/err"; rc=$?
[ "$rc" = 0 ] && [ ! -s "$COUNT" ] && ok "S-prod the alias proves the fixture key, 0 calls" \
  || bad "S-prod alias: rc $rc, err=$(cat "$T/err"), calls=$(wc -l < "$COUNT")"

# ── L: the retired-name matcher ─────────────────────────────────────────────
# lint <root> <file-list> — print `path:line: <text>` for each retired name in
# the listed files, minus the allowed lines. rc 0 = no hit.
lint() {
  local root="$1" list="$2" f lo hi
  lo=""; hi=""
  if [ -r "$root/bin/lib/vendor/_common.sh" ]; then
    lo=$(grep -n '^# vendor_fake_on' "$root/bin/lib/vendor/_common.sh" | head -1 | cut -d: -f1)
    hi=$(awk '/^vendor_fake_on\(\)/{s=1} s && /^}/{print NR; exit}' "$root/bin/lib/vendor/_common.sh")
  fi
  while IFS= read -r -d '' f; do
    case "$f" in
      .harness/specs/*|docs/notes/*) continue ;;
      tests/vendor-fake-switch.bh-8555-test.sh|tests/vendor-fake-budget.bh-8555-test.sh) continue ;;
    esac
    [ -f "$root/$f" ] || continue
    grep -nIE "$RM|(^|[^A-Z_])$RD|$RP" "$root/$f" 2>/dev/null | while IFS= read -r hit; do
      ln="${hit%%:*}"
      if [ "$f" = bin/lib/vendor/_common.sh ] && [ -n "$lo" ] && [ -n "$hi" ] \
         && [ "$ln" -ge "$lo" ] && [ "$ln" -le "$hi" ]; then continue; fi
      if [ "$f" = docs/SECRETS-ENVELOPE.md ] && [[ $hit == *'<!-- retired-alias BH-8555 -->'* ]]; then continue; fi
      printf '%s:%s  (use HARNESS_VENDOR_FAKE=1, HARNESS_VENDOR_FAKE_DIR, tests/fixtures/vendor-fake)\n' "$f" "$hit"
    done
  done < "$list" | tee "$T/lint.out"
  [ ! -s "$T/lint.out" ]
}

echo "L: the matcher on planted trees"
# plant <name> <path> <line> <want: red|green>
plant() {
  local name="$1" p="$2" line="$3" want="$4" F="$T/tree-$1"
  scratch_rm "$F"; mkdir -p "$F"
  ( cd "$DIR" && scratch_install_closure bin/lib/vendor/_common.sh "$F" ) >/dev/null 2>&1 || bad "$name setup: could not install _common.sh"
  mkdir -p "$F/$(dirname "$p")"
  printf '%s\n' "$line" >> "$F/$p"
  git -C "$F" init -q && git -C "$F" add -A
  git -C "$F" ls-files -z > "$T/list-$name"
  if lint "$F" "$T/list-$name" > "$T/lint-$name.out"; then got=green; else got=red; fi
  if [ "$got" = "$want" ] && { [ "$want" = green ] || grep -q "^$p:" "$T/lint-$name.out"; }; then
    ok "$name $p -> $want"
  else
    bad "$name $p: got $got, want $want ($(cat "$T/lint-$name.out"))"
  fi
}
plant L1  bin/x.sh                  "x=\$$RM"                              red
plant L2  tests/y-test.sh           "export $RM=fake"                      red
plant L3  tests/z-test.sh           "cat <<E
$RM=fake
E"                                                                         red
plant L4  bin/w.sh                  "$RD=/tmp/x"                           red
plant L5  tests/v-test.sh           "cp $RP/x.json ."                      red
plant L6  bin/lib/vendor/_common.sh "m=\${$RM:-}"                         red
plant L7  bin/a.sh                  "d=\$HARNESS_VENDOR_FAKE_DIR"          green
plant L8  bin/b.sh                  "[ \"\$HARNESS_VENDOR_FAKE\" = 1 ]"    green
plant L9  tests/c-test.sh           "cp tests/fixtures/vendor-fake/x.json ." green
plant L10 .harness/specs/x/plan.md  "$RM was the old name"                 green
plant L11 docs/notes/x.md           "$RM was the old name"                 green
plant L12 bin/d.sh                  "VENDOR_MODE=1"                        green

echo "L-tree: the matcher on this checkout"
git -C "$DIR" ls-files -z > "$T/tree-files" || bad "L-tree: git ls-files failed"
[ -s "$T/tree-files" ] || bad "L-tree: empty file list"
if lint "$DIR" "$T/tree-files" > "$T/lint-tree.out"; then
  ok "L-tree no retired fake-switch name outside the alias"
else
  bad "L-tree retired names found:"; sed 's/^/       /' "$T/lint-tree.out"
fi

echo "vendor-fake-switch.bh-8555: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
