#!/bin/bash
# tests/lane-switch-frags.bh-8397-test.sh — BH-8397: the RT, G and S9 cases of
# tests/lane-switch.bh-2407-test.sh live in tests/lane-switch.bh-2407-test.d/,
# one fragment per file, and the driver sources every such file once, in
# LC_ALL=C name order, from ONE marker block after M1/M2. bin/list-file-lint.sh
# refuses a PR that grows the driver with no new file in that dir.
#
# WHAT THIS PINS. The R cases cut the marker block out of the REAL driver and
# run it in a clean `bash --norc` with stub ok/bad and a scratch DIR. The M and
# C cases build scratch git repos with the real driver, the real fragment dir
# and the real catalog, and run the REAL bin/list-file-lint.sh as a process.
#   R1 the driver with its block replaced by the 3 split-time fragments is
#      byte-identical to the file before the split (sha256 pin); one open and
#      one close marker; the LS_MUTANT stop and M2 come before the block
#   R2 order and selection: regular *.sh only, each once, LC_ALL=C order,
#      whatever the caller's locale
#   R3 fail-closed: no dir or an empty dir is one `bad`; a syntax error is one
#      `bad` naming it and the next fragment still runs; a fragment whose last
#      status is 3 is no `bad`
#   R4 every real fragment has a good name and parses; the 3 split-time files
#      exist
#   M1 two sibling branches each add a fragment and merge clean, and the merged
#      block sources both; on the old shape two appends to the C4 line conflict
#   C1 the shipped catalog has one row for the driver
#   C2 the real lint: a case appended to the driver with no fragment is rc 1;
#      a fragment-only PR and a +1/-1 value edit are rc 0
#
# A later ticket that edits the driver outside its block, or one of the 3
# split-time fragments, updates R1's hash with a TEST-CHANGE line.
#
# Run from anywhere: tests/lane-switch-frags.bh-8397-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
DRIVER="$REPO/tests/lane-switch.bh-2407-test.sh"
FRAGS="$REPO/tests/lane-switch.bh-2407-test.d"
LINT="$REPO/bin/list-file-lint.sh"
CAT="$REPO/catalog/list-files.tsv"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.com
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.com
export GIT_AUTHOR_DATE='2026-10-26T12:00:00Z' GIT_COMMITTER_DATE='2026-10-26T12:00:00Z'

OPEN='# >>> lane-switch.bh-2407-test.d fragments (BH-8397)'
CLOSE='# <<< lane-switch.bh-2407-test.d fragments (BH-8397)'
# The file before the split (blob 9e56ff2b5040 on main e10496f1).
# Four pieces: the share-mirror leakcheck reads a 32- or 64-hex literal as a secret.
BEFORE_SHA=da3c7060d6e9be19"92682dbf4d0ea5cb""576622b48c25b236"ada5006ff6616171
SPLIT_FRAGS="bh-2407-1-ratchet-drop.sh bh-2407-2-registry-a-f.sh bh-2407-3-switch-migrate.sh"

# block_of <driver> — the marker block, markers included.
block_of() { awk -v o="$OPEN" -v c="$CLOSE" '$0==o{on=1} on{print} $0==c{on=0}' "$1"; }

# render_of <driver> <frag dir> — the driver with its block replaced by the
# split-time fragments, in that order.
render_of() {
  local f
  awk -v o="$OPEN" -v c="$CLOSE" -v d="$2" -v l="$SPLIT_FRAGS" '
    $0==o { on=1; n=split(l, a, " "); for (i=1; i<=n; i++) { while ((getline x < (d "/" a[i])) > 0) print x; close(d "/" a[i]) } next }
    $0==c { on=0; next }
    !on { print }' "$1"
  for f in $SPLIT_FRAGS; do [ -f "$2/$f" ] || echo "MISSING $f"; done
}

# run_block <block file> <DIR> [extra script] — the block in a clean shell with
# stub ok/bad. Sets OUT and RC (RC is the block's own status).
run_block() {
  local blk=$1 dir=$2 extra=${3:-}
  cat > "$T/runner.sh" <<'EOF'
set -uo pipefail
DIR=$1; BLK=$2
ok()  { echo OK; }
bad() { echo "BAD $1"; }
. "$BLK"; brc=$?
echo "BLOCK-RC $brc"
EOF
  printf '%s\n' "$extra" >> "$T/runner.sh"
  OUT=$(cd "$T" && env -i PATH="${RUN_PATH:+$RUN_PATH:}$PATH" LC_ALL="${RUN_LC_ALL-C}" ${RUN_LANG:+LANG="$RUN_LANG"} \
    bash --norc --noprofile "$T/runner.sh" "$dir" "$blk" 2>&1)
  RC=$(sed -n 's/^BLOCK-RC //p' <<<"$OUT")
}
has() { case "$OUT" in *"$1"*) return 0 ;; esac; return 1; }
nbad() { grep -c '^BAD ' <<<"$OUT"; }

REAL_BLK="$T/real-block.sh"
block_of "$DRIVER" > "$REAL_BLK"

# R1
nopen=$(grep -cxF "$OPEN" "$DRIVER"); nclose=$(grep -cxF "$CLOSE" "$DRIVER")
open_ln=$(grep -nxF "$OPEN" "$DRIVER" | head -n 1 | cut -d: -f1)
stop_ln=$(grep -n '^if \[ -n "\${LS_MUTANT:-}" \]; then$' "$DRIVER" | head -n 1 | cut -d: -f1)
m2_ln=$(grep -n '^mutant M2 ' "$DRIVER" | head -n 1 | cut -d: -f1)
render_of "$DRIVER" "$FRAGS" > "$T/render.sh"
got_sha=$(sha256sum < "$T/render.sh" | cut -d' ' -f1)
if [ "$nopen" = 1 ] && [ "$nclose" = 1 ] && [ "$got_sha" = "$BEFORE_SHA" ] \
   && [ -n "$stop_ln" ] && [ -n "$m2_ln" ] && [ "$stop_ln" -lt "$m2_ln" ] && [ "$m2_ln" -lt "$open_ln" ]; then
  ok "R1 the driver with its block replaced by the split-time fragments is the file before the split"
else bad "R1 open=$nopen close=$nclose stop=$stop_ln m2=$m2_ln open_ln=$open_ln sha=$got_sha (want $BEFORE_SHA)"; fi

# R2 — each fragment appends its name to TRACE.
d="$T/r2/tests/lane-switch.bh-2407-test.d"
mkdir -p "$d/x" "$d/bh-9-d.sh"
for n in bh-12-b bh-1-a-x bh-1-a; do
  printf 'TRACE="${TRACE:-}%s "\n' "$n" > "$d/$n.sh"
done
echo 'TRACE="${TRACE:-}README "' > "$d/README.md"
echo 'TRACE="${TRACE:-}tilde "' > "$d/bh-1-a.sh~"
echo 'TRACE="${TRACE:-}bak "' > "$d/bh-1-a.sh.bak"
echo 'TRACE="${TRACE:-}sub "' > "$d/x/bh-1-f.sh"
ln -s "$d/no-such-file" "$d/bh-9-e.sh"
r2_ok=1; r2_why=
run_block "$REAL_BLK" "$T/r2" 'echo "TRACE=${TRACE:-}"'
{ [ "$RC" = 0 ] && has 'TRACE=bh-1-a-x bh-1-a bh-12-b ' && [ "$(nbad)" = 0 ]; } || { r2_ok=0; r2_why="LC_ALL=C: $OUT"; }
for loc in $(locale -a 2>/dev/null | grep -ixE 'c\.utf-?8|en_us\.utf-?8'); do
  RUN_LC_ALL= RUN_LANG=$loc run_block "$REAL_BLK" "$T/r2" 'echo "TRACE=${TRACE:-}"'
  { has 'TRACE=bh-1-a-x bh-1-a bh-12-b ' && [ "$(nbad)" = 0 ]; } || { r2_ok=0; r2_why="$r2_why LANG=$loc: $OUT"; }
done
# A box may have no locale whose collation differs from C (only C.utf8). A
# `sort` on PATH that reverses its input unless LC_ALL=C stands in for one, so
# the block must pin LC_ALL=C on its own sort, whatever the caller's locale.
mkdir -p "$T/r2-sort"
real_sort=$(command -v sort)
printf '#!/bin/bash
if [ "${LC_ALL:-}" = C ]; then exec %s "$@"; fi
exec %s -r "$@"
' "$real_sort" "$real_sort" > "$T/r2-sort/sort"
chmod +x "$T/r2-sort/sort"
RUN_PATH="$T/r2-sort" RUN_LC_ALL= RUN_LANG=en_US.UTF-8 run_block "$REAL_BLK" "$T/r2" 'echo "TRACE=${TRACE:-}"'
{ has 'TRACE=bh-1-a-x bh-1-a bh-12-b ' && [ "$(nbad)" = 0 ]; } || { r2_ok=0; r2_why="$r2_why non-C collation: $OUT"; }
[ "$r2_ok" = 1 ] && ok "R2 regular *.sh only, LC_ALL=C order (bh-1-a-x bh-1-a bh-12-b), each once" \
  || bad "R2 $r2_why"

# R3
mkdir -p "$T/r3-none/tests"
run_block "$REAL_BLK" "$T/r3-none"; r3_none=$(nbad); r3_none_out=$OUT
mkdir -p "$T/r3-empty/tests/lane-switch.bh-2407-test.d"
run_block "$REAL_BLK" "$T/r3-empty"; r3_empty=$(nbad); r3_empty_out=$OUT
d="$T/r3/tests/lane-switch.bh-2407-test.d"; mkdir -p "$d"
printf 'if then\n' > "$d/bh-1-syntax.sh"
printf 'TRACE="${TRACE:-}two "\n' > "$d/bh-2-next.sh"
printf 'TRACE="${TRACE:-}three "\n(exit 3)\n' > "$d/bh-3-rc.sh"
run_block "$REAL_BLK" "$T/r3" 'echo "TRACE=${TRACE:-}"'
if [ "$r3_none" = 1 ] && grep -q '^BAD F0 no fragment' <<<"$r3_none_out" \
   && [ "$r3_empty" = 1 ] && grep -q '^BAD F0 no fragment' <<<"$r3_empty_out" \
   && [ "$(nbad)" = 1 ] && has 'BAD F0 fragment bh-1-syntax.sh does not parse' \
   && has 'TRACE=two three '; then
  ok "R3 no dir / empty dir / a syntax error: one bad each; a last status of 3 is no bad"
else bad "R3 none=$r3_none ($r3_none_out) empty=$r3_empty ($r3_empty_out) frags: $OUT"; fi

# R4 — the 3 split-time files, by rooted path.
r4_why=
for f in tests/lane-switch.bh-2407-test.d/bh-2407-1-ratchet-drop.sh \
         tests/lane-switch.bh-2407-test.d/bh-2407-2-registry-a-f.sh \
         tests/lane-switch.bh-2407-test.d/bh-2407-3-switch-migrate.sh; do
  [ -f "$REPO/$f" ] || r4_why="$r4_why missing:$f"
done
n4=0
for f in "$FRAGS"/*.sh; do
  [ -f "$f" ] || continue
  n4=$((n4+1)); n=${f##*/}
  [[ $n =~ ^[a-z]+-[0-9]+(\.[0-9]+)?-[a-z0-9][a-z0-9-]*\.sh$ ]] || r4_why="$r4_why name:$n"
  bash -n "$f" 2>/dev/null || r4_why="$r4_why syntax:$n"
done
[ -z "$r4_why" ] && [ "$n4" -ge 3 ] && ok "R4 $n4 real fragment(s): good names, all parse" || bad "R4 n=$n4$r4_why"

# Scratch repos: the real driver, the real fragment dir and the real catalog.
mk() {
  local R="$T/$1"
  mkdir -p "$R/catalog" "$R/tests" && cd "$R" || return 1
  git init -q -b main .
  cp "$CAT" catalog/list-files.tsv
  cp "$DRIVER" tests/lane-switch.bh-2407-test.sh
  [ -d "$FRAGS" ] && cp -R "$FRAGS" tests/lane-switch.bh-2407-test.d
  git add -A && git commit -q -m base && git branch base
}
pr() { git add -A && git commit -q -m "${1:-pr}"; }
lint() { OUT=$("$LINT" --base base --catalog "$CAT" 2>&1); RC=$?; }

# M1
mk m1
git checkout -q -b a base
printf '# A1 a case\nTRACE="${TRACE:-}A "\n' > tests/lane-switch.bh-2407-test.d/bh-9001-a-case.sh
pr a
git checkout -q -b b base
printf '# B1 a case\nTRACE="${TRACE:-}B "\n' > tests/lane-switch.bh-2407-test.d/bh-9002-b-case.sh
pr b
git checkout -q -b merged base
git merge -q --no-edit a >/dev/null 2>&1; rc_ma=$?
git merge -q --no-edit b >/dev/null 2>&1; rc_mb=$?
unmerged=$(git diff --name-only --diff-filter=U)
block_of tests/lane-switch.bh-2407-test.sh > "$T/m1-block.sh"
# Only the two new fragments: the real ones need the driver's full state.
mkdir -p "$T/m1run/tests/lane-switch.bh-2407-test.d"
cp tests/lane-switch.bh-2407-test.d/bh-900[12]-*.sh "$T/m1run/tests/lane-switch.bh-2407-test.d/" 2>/dev/null
run_block "$T/m1-block.sh" "$T/m1run" 'echo "TRACE=${TRACE:-}"'
m1_out=$OUT; m1_rc=$RC
# Control: the old shape, two siblings each appending a name to the C4 list.
cd "$T" || exit 1
mkdir -p "$T/m1c/tests" && cd "$T/m1c" || exit 1
git init -q -b main .
cp "$T/render.sh" tests/lane-switch.bh-2407-test.sh
git add -A && git commit -q -m base && git branch base
c4_last='^pool-account-routing-off pr-create-rest-fallback-off pr-dep-gate-off pr-merge-rest-off resume-disabled"$'
grep -q "$c4_last" tests/lane-switch.bh-2407-test.sh; c4_found=$?
git checkout -q -b ca base; sed -i "s/$c4_last/pool-account-routing-off pr-create-rest-fallback-off pr-dep-gate-off pr-merge-rest-off resume-disabled ca-off\"/" tests/lane-switch.bh-2407-test.sh; pr ca
git checkout -q -b cb base; sed -i "s/$c4_last/pool-account-routing-off pr-create-rest-fallback-off pr-dep-gate-off pr-merge-rest-off resume-disabled cb-off\"/" tests/lane-switch.bh-2407-test.sh; pr cb
git checkout -q -b cm base
git merge -q --no-edit ca >/dev/null 2>&1
git merge -q --no-edit cb >/dev/null 2>&1; rc_ctl=$?
ctl_u=$(git diff --name-only --diff-filter=U)
git merge --abort >/dev/null 2>&1
cd "$T" || exit 1
if [ "$rc_ma" = 0 ] && [ "$rc_mb" = 0 ] && [ -z "$unmerged" ] && [ "$m1_rc" = 0 ] \
   && grep -qx 'TRACE=A B ' <<<"$m1_out" && ! grep -q '^BAD ' <<<"$m1_out" \
   && [ "$c4_found" = 0 ] && [ "$rc_ctl" != 0 ] && [ "$ctl_u" = tests/lane-switch.bh-2407-test.sh ]; then
  ok "M1 two sibling fragments merge clean and both run; two appends to the old C4 line conflict"
else bad "M1 merge a=$rc_ma b=$rc_mb unmerged=[$unmerged] block=$m1_rc out: $m1_out; control c4=$c4_found rc=$rc_ctl u=[$ctl_u]"; fi

# C1
c1=$(grep -vE '^(#|[[:space:]]*$)' "$CAT" | awk -F'\t' '$1=="tests/lane-switch.bh-2407-test.sh"')
c1n=$(grep -cvE '^(#|[[:space:]]*$)' <<<"$c1")
[ "$c1n" = 1 ] && [ "$(cut -f2 <<<"$c1")" = "tests/lane-switch.bh-2407-test.d/" ] \
  && ok "C1 one catalog row: tests/lane-switch.bh-2407-test.sh -> tests/lane-switch.bh-2407-test.d/" || bad "C1 rows: [$c1]"

# C2
mk c2
sed -i 's/^echo "lane-switch.bh-2407: \$PASS passed, \$FAIL failed"$/eq "X1 a new case" "1" "1"\n&/' tests/lane-switch.bh-2407-test.sh
grep -q '^eq "X1 a new case"' tests/lane-switch.bh-2407-test.sh; c2_applied=$?
pr; lint; c2a=$RC; c2a_out=$OUT
mk c2b; printf '# C1 a case\nok\n' > tests/lane-switch.bh-2407-test.d/bh-9003-c-case.sh; pr
lint; c2b=$RC; c2b_out=$OUT
mk c2c; sed -i 's/^# M1\/M2 — D1, every run\./# M1\/M2: D1, every run./' tests/lane-switch.bh-2407-test.sh; pr
lint; c2c=$RC; c2c_out=$OUT; c2c_diff=$(git diff --numstat base HEAD)
cd "$T" || exit 1
if [ "$c2_applied" = 0 ] && [ "$c2a" = 1 ] && grep -q 'tests/lane-switch.bh-2407-test.sh' <<<"$c2a_out" \
   && grep -q 'tests/lane-switch.bh-2407-test.d/' <<<"$c2a_out" \
   && [ "$c2b" = 0 ] && [ "$c2c" = 0 ] && [ -n "$c2c_diff" ]; then
  ok "C2 the real lint: an appended case is rc 1 and names the driver; a fragment-only PR and a value edit are rc 0"
else bad "C2 applied=$c2_applied append rc=$c2a ($c2a_out) frag rc=$c2b ($c2b_out) edit rc=$c2c ($c2c_out) diff=[$c2c_diff]"; fi

echo "lane-switch-frags.bh-8397: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
