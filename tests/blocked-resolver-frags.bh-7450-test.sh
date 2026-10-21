#!/bin/bash
# tests/blocked-resolver-frags.bh-7450-test.sh — BH-7450: new optional resolver
# code is its own file, bin/blocked-resolver.d/<key>-<name>.sh, and the driver
# sources every such file once, in LC_ALL=C name order, from ONE block after its
# optional-module loop. bin/list-file-lint.sh refuses a PR that grows
# bin/blocked-resolver.sh with no new file under bin/blocked-resolver.d/.
#
# WHAT THIS PINS. The F cases cut the block out of the REAL driver and run it
# in a clean `bash --norc` under `set -uo pipefail`, with H set to a scratch
# tree, a stub say and BR_OPT_OFF set. The M and C cases build scratch git
# repos with the real driver and the real catalog, and run the REAL
# bin/list-file-lint.sh as a process.
#   F1 the real fragment dir: no variable, no output, no say call, and only the
#      functions its fragments declare
#   F2 order and selection: LC_ALL=C name order, regular *.sh only, each once
#   F3 a syntax error and a `return 3`: one say line each (real rc), goes on
#   F4 no blocked-resolver.d/ at all: nothing sourced, no output, no variable
#   F5 BR_OPT_OFF skips a fragment by its whole name without .sh; a fragment's
#      function is callable after the block (main shell)
#   M1 placement: after the optional loop, before the dispatcher; the only text
#      naming blocked-resolver.d; BR_OPT_MODULES unchanged; nothing generated
#   M2 two sibling branches each add a fragment (+1 call site) and merge clean;
#      the merged block loads both; the old BR_OPT_MODULES append conflicts
#   C1 the shipped catalog has one row for bin/blocked-resolver.sh
#   C2 a source line appended to the driver with no fragment -> lint rc 1
#   C3 a fragment-only PR, and a +1/-1 value edit of the driver -> rc 0
#   C4 growth of bin/lib/br/ladder.sh and bin/lib/br/opt/stale.sh -> rc 0
#   V1 every real fragment passes the fragment checker
#   V2-V4 the checker refuses bad names, a syntax error, a shadowed driver or
#      bin/lib/br name and a name defined twice; it accepts a good fragment
#
# Run from anywhere: tests/blocked-resolver-frags.bh-7450-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
DRIVER="$REPO/bin/blocked-resolver.sh"
FRAGS="$REPO/bin/blocked-resolver.d"
LINT="$REPO/bin/list-file-lint.sh"
CAT="$REPO/catalog/list-files.tsv"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.com
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.com
export GIT_AUTHOR_DATE='2026-10-21T12:00:00Z' GIT_COMMITTER_DATE='2026-10-21T12:00:00Z'

OPEN='# blocked-resolver.d (BH-7450)'
CLOSE='done; unset _br_frags'
MODS='mechanical family cirepair stale external extfix extpark extrebase parentprio untouched profile readmemo unchanged'

# block_of <driver> — the block, from its first comment line to its `done` line.
block_of() { awk -v o="$OPEN" -v c="$CLOSE" 'index($0,o)==1{on=1} on{print} on&&index($0,c)==1{on=0}' "$1"; }

# run_block <block file> <H> [BR_OPT_OFF] [extra script] — the block in a clean
# shell under set -u with a stub say; writes before/after function and variable
# lists under $T/state. Sets OUT and RC (RC is the block's own status).
run_block() {
  local blk=$1 h=$2 off=${3:-} extra=${4:-}
  mkdir -p "$T/state"
  cat > "$T/runner.sh" <<'EOF'
set -uo pipefail
H=$1; ST=$2; BLK=$3; BR_OPT_OFF=$4
say() { echo "SAY $*"; }
declare -F | sort > "$ST/before.f"; compgen -v | sort > "$ST/before.v"
. "$BLK"; brc=$?
declare -F | sort > "$ST/after.f"; compgen -v | grep -vx brc | sort > "$ST/after.v"
echo "BLOCK-RC $brc"
EOF
  printf '%s\n' "$extra" >> "$T/runner.sh"
  OUT=$(cd "$T" && env -i PATH="$PATH" LC_ALL="${RUN_LC_ALL:-C}" ${RUN_LANG:+LANG="$RUN_LANG"} \
    bash --norc --noprofile "$T/runner.sh" "$h" "$T/state" "$blk" "$off" 2>&1)
  RC=$(sed -n 's/^BLOCK-RC //p' <<<"$OUT")
}
has() { case "$OUT" in *"$1"*) return 0 ;; esac; return 1; }

REAL_BLK="$T/real-block.sh"
block_of "$DRIVER" > "$REAL_BLK"
nopen=$(grep -c "^$OPEN" "$DRIVER"); nclose=$(grep -c "^$CLOSE" "$DRIVER")

# F1
mkdir -p "$T/f1/bin"
[ -d "$FRAGS" ] && cp -R "$FRAGS" "$T/f1/bin/blocked-resolver.d"
run_block "$REAL_BLK" "$T/f1"
f1_want=$( (set +f; cat "$T"/f1/bin/blocked-resolver.d/*.sh 2>/dev/null) \
  | sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)() *{.*/\1/p' | LC_ALL=C sort -u | paste -sd' ' -)
f1_got=$(LC_ALL=C comm -13 "$T/state/before.f" "$T/state/after.f" | awk '{print $NF}' | LC_ALL=C sort -u | paste -sd' ' -)
f1_lost=$(LC_ALL=C comm -23 "$T/state/before.f" "$T/state/after.f")
if [ "$nopen" = 1 ] && [ "$nclose" = 1 ] && [ -s "$REAL_BLK" ] && [ -d "$T/f1/bin/blocked-resolver.d" ] \
   && [ "$RC" = 0 ] && [ "$OUT" = "BLOCK-RC 0" ] && [ "$f1_got" = "$f1_want" ] && [ -z "$f1_lost" ] \
   && cmp -s "$T/state/before.v" "$T/state/after.v"; then
  ok "F1 the real fragment dir adds no variable, no output, no say line, and only its declared functions (${f1_want:-none})"
else bad "F1 block not found or not clean: open=$nopen close=$nclose rc=$RC out: $OUT; funcs want=[$f1_want] got=[$f1_got]; vars: $(diff "$T/state/before.v" "$T/state/after.v" 2>&1 | tr '\n' ' ')"; fi

# F2 — each fragment appends its name to TRACE.
d="$T/f2/bin/blocked-resolver.d"; mkdir -p "$d/bh-4-d.sh" "$d/x"
for n in bh-2-b bh-1-a bh-10-x; do printf 'TRACE="${TRACE:-}%s "\n' "$n" > "$d/$n.sh"; done
echo 'TRACE="${TRACE:-}README "' > "$d/README.md"
echo 'TRACE="${TRACE:-}bak "' > "$d/bh-3-c.sh.bak"
echo 'TRACE="${TRACE:-}upper "' > "$d/bh-3-c.SH"
echo 'TRACE="${TRACE:-}sub "' > "$d/x/bh-5-e.sh"
f2_ok=1; f2_why=
run_block "$REAL_BLK" "$T/f2" '' 'echo "TRACE=$TRACE"'
[ "$RC" = 0 ] && has 'TRACE=bh-1-a bh-10-x bh-2-b ' && ! has 'TRACE=bh-1-a bh-10-x bh-2-b *[a-zA-Z]' && ! has SAY \
  || { f2_ok=0; f2_why="LC_ALL=C: $OUT"; }
for loc in $(locale -a 2>/dev/null | grep -ixE 'c\.utf-?8|en_us\.utf-?8'); do
  RUN_LC_ALL= RUN_LANG=$loc run_block "$REAL_BLK" "$T/f2" '' 'echo "TRACE=$TRACE"'
  has 'TRACE=bh-1-a bh-10-x bh-2-b ' || { f2_ok=0; f2_why="$f2_why LANG=$loc: $OUT"; }
done
[ "$f2_ok" = 1 ] && ok "F2 regular *.sh only, LC_ALL=C order (bh-1-a bh-10-x bh-2-b), each once" || bad "F2 $f2_why"

# F3
d="$T/f3/bin/blocked-resolver.d"; mkdir -p "$d"
echo 'f3_one() { echo one; }' > "$d/bh-1-one.sh"
printf 'f3_bad() {\n  if then\n}\n' > "$d/bh-2-syntax.sh"
printf 'f3_ret() { :; }\nreturn 3\n' > "$d/bh-3-ret.sh"
echo 'f3_four() { echo four; }' > "$d/bh-4-four.sh"
run_block "$REAL_BLK" "$T/f3" '' 'declare -F f3_one f3_four f3_ret >/dev/null && echo ALL-DEFINED'
nsay=$(grep -c '^SAY ' <<<"$OUT")
if [ "$RC" = 0 ] && [ "$nsay" = 2 ] \
   && has 'SAY fragment bin/blocked-resolver.d/bh-2-syntax.sh does not parse — skipped, this tick runs without it' \
   && has 'SAY fragment bin/blocked-resolver.d/bh-3-ret.sh failed on source (rc 3) — skipped, this tick runs without it' \
   && has ALL-DEFINED && ! has 'bh-1-one.sh' && ! has 'bh-4-four.sh'; then
  ok "F3 one say line per failed fragment (real rc), the good ones load, block rc 0"
else bad "F3 rc=$RC says=$nsay out: $OUT"; fi

# F4
mkdir -p "$T/f4/bin"
run_block "$REAL_BLK" "$T/f4"
if [ -s "$REAL_BLK" ] && [ "$RC" = 0 ] && [ "$OUT" = "BLOCK-RC 0" ] \
   && cmp -s "$T/state/before.f" "$T/state/after.f" && cmp -s "$T/state/before.v" "$T/state/after.v"; then
  ok "F4 no blocked-resolver.d/ under set -u: nothing sourced, no output, no variable left"
else bad "F4 rc=$RC out: $OUT"; fi

# F5
d="$T/f5/bin/blocked-resolver.d"; mkdir -p "$d"
echo 'bh1_a_gate() { echo "gate-a:$1"; }' > "$d/bh-1-a.sh"
echo 'bh2_b_gate() { echo "gate-b:$1"; }' > "$d/bh-2-b.sh"
call='command -v bh1_a_gate >/dev/null 2>&1 && bh1_a_gate x; bh2_b_gate y'
run_block "$REAL_BLK" "$T/f5" 'bh-1-a' "$call"; f5_off=$OUT; f5_off_rc=$RC
run_block "$REAL_BLK" "$T/f5" 'bh-1' "$call"; f5_part=$OUT
run_block "$REAL_BLK" "$T/f5" 'mechanical,bh-1-a.sh' "$call"; f5_sfx=$OUT
if [ "$f5_off_rc" = 0 ] && ! grep -q 'gate-a' <<<"$f5_off" && grep -qx 'gate-b:y' <<<"$f5_off" \
   && grep -qx 'gate-a:x' <<<"$f5_part" && grep -qx 'gate-b:y' <<<"$f5_part" \
   && grep -qx 'gate-a:x' <<<"$f5_sfx" && grep -qx 'gate-b:y' <<<"$f5_sfx"; then
  ok "F5 BR_OPT_OFF=bh-1-a skips it; bh-1 and bh-1-a.sh do not; fragment functions are callable after the block"
else bad "F5 off: $f5_off | partial: $f5_part | suffix: $f5_sfx"; fi

# M1
loop_end=$(grep -n '^unset _br_o _br_of$' "$DRIVER" | cut -d: -f1)
disp=$(grep -n '^# THE DISPATCHER STOPS HERE' "$DRIVER" | cut -d: -f1)
open_ln=$(grep -n "^$OPEN" "$DRIVER" | cut -d: -f1)
close_ln=$(grep -n "^$CLOSE" "$DRIVER" | cut -d: -f1)
outside=$(awk -v a="${open_ln:-0}" -v b="${close_ln:-0}" 'NR<a || NR>b' "$DRIVER" | grep -c 'blocked-resolver\.d')
mods=$(sed -n 's/^BR_OPT_MODULES="\(.*\)"$/\1/p' "$DRIVER")
tracked=$(git -C "$REPO" ls-files bin/blocked-resolver.d | grep -vxE 'bin/blocked-resolver\.d/(README\.md|[a-z]+-[0-9]+(\.[0-9]+)?-[a-z0-9][a-z0-9-]*\.sh)')
has_readme=$(git -C "$REPO" ls-files bin/blocked-resolver.d/README.md)
if [ -n "$open_ln" ] && [ -n "$close_ln" ] && [ -n "$loop_end" ] && [ -n "$disp" ] \
   && [ "$open_ln" -gt "$loop_end" ] && [ "$close_ln" -lt "$disp" ] && [ "$outside" = 0 ] \
   && [ "$mods" = "$MODS" ] && [ -z "$tracked" ] && [ -n "$has_readme" ]; then
  ok "M1 block after the optional loop (:$loop_end) and before the dispatcher (:$disp); BR_OPT_MODULES unchanged; nothing generated tracked"
else bad "M1 open=$open_ln close=$close_ln loop_end=$loop_end disp=$disp outside=$outside mods=[$mods] tracked=[$tracked] readme=[$has_readme]"; fi

# The scratch repos for M2 and C1-C4: the real driver and catalog, plus
# stand-ins for the near-miss files, on branch `base`.
mk() {
  local R="$T/$1"
  mkdir -p "$R" && cd "$R" || return 1
  git init -q -b main .
  mkdir -p catalog bin/lib/br/opt bin/blocked-resolver.d
  cp "$CAT" catalog/list-files.tsv
  cp "$DRIVER" bin/blocked-resolver.sh
  echo 'fragments' > bin/blocked-resolver.d/README.md
  printf 'echo ladder\n' > bin/lib/br/ladder.sh
  printf 'echo stale\n' > bin/lib/br/opt/stale.sh
  git add -A && git commit -q -m base && git branch base
}
pr() { git add -A && git commit -q -m "${1:-pr}"; }
lint() { OUT=$("$LINT" "$@" 2>&1); RC=$?; }
# insert_after <line no> <text> <file>
insert_after() { awk -v n="$1" -v t="$2" '{print} NR==n{print t}' "$3" > "$3.tmp" && mv "$3.tmp" "$3"; }
# The old shape: one more BR_OPT_MODULES word and a comment pair above it.
append_module_word() {
  local ln; ln=$(grep -n '^BR_OPT_MODULES="' bin/blocked-resolver.sh | cut -d: -f1)
  awk -v n="$ln" -v x="$1" 'NR==n{print "# " x " is a new rung."; print "# It does one more thing."; sub(/"$/, " " x "\"")} {print}' \
    bin/blocked-resolver.sh > bin/blocked-resolver.sh.tmp && mv bin/blocked-resolver.sh.tmp bin/blocked-resolver.sh
}

# M2
fa=$(grep -n '^br_queue_enq() {' "$DRIVER" | cut -d: -f1)
fb=$(grep -n '^br_rebuild_wait() {' "$DRIVER" | cut -d: -f1)
mk m2
git checkout -q -b a base
echo 'bh101_a_gate() { echo A; }' > bin/blocked-resolver.d/bh-101-a.sh
insert_after "$fa" '  command -v bh101_a_gate >/dev/null 2>&1 && bh101_a_gate' bin/blocked-resolver.sh
pr a; lint --base base; rc_a=$RC
git checkout -q -b b base
echo 'bh102_b_gate() { echo B; }' > bin/blocked-resolver.d/bh-102-b.sh
insert_after "$fb" '  command -v bh102_b_gate >/dev/null 2>&1 && bh102_b_gate' bin/blocked-resolver.sh
pr b; lint --base base; rc_b=$RC
git checkout -q -b merged base
git merge -q --no-edit a >/dev/null 2>&1; rc_ma=$?
git merge -q --no-edit b >/dev/null 2>&1; rc_mb=$?
bash -n bin/blocked-resolver.sh; rc_n=$?
block_of bin/blocked-resolver.sh > "$T/m2-block.sh"
run_block "$T/m2-block.sh" "$T/m2" '' 'bh101_a_gate; bh102_b_gate'
m2_out=$OUT; m2_rc=$RC
# Control: the old shape, two siblings each appending a BR_OPT_MODULES word.
git checkout -q -b ca base; append_module_word cagate; pr ca
git checkout -q -b cb base; append_module_word cbgate; pr cb
git checkout -q -b cm base
git merge -q --no-edit ca >/dev/null 2>&1
git merge -q --no-edit cb >/dev/null 2>&1; rc_ctl=$?
git merge --abort >/dev/null 2>&1
cd "$T" || exit 1
if [ -s "$T/m2-block.sh" ] && [ "$rc_a" = 0 ] && [ "$rc_b" = 0 ] && [ "$rc_ma" = 0 ] && [ "$rc_mb" = 0 ] \
   && [ "$rc_n" = 0 ] && [ "$m2_rc" = 0 ] && grep -qx A <<<"$m2_out" && grep -qx B <<<"$m2_out" && [ "$rc_ctl" != 0 ]; then
  ok "M2 two sibling fragments merge clean and both load; two BR_OPT_MODULES appends conflict"
else bad "M2 lint a=$rc_a b=$rc_b merge a=$rc_ma b=$rc_mb bash-n=$rc_n block=$m2_rc control=$rc_ctl out: $m2_out"; fi

# C1
c1=$(grep -vE '^(#|[[:space:]]*$)' "$CAT" | awk -F'\t' '$1=="bin/blocked-resolver.sh"')
c1n=$(grep -cvE '^(#|[[:space:]]*$)' <<<"$c1")
cd "$REPO" && lint --base HEAD --catalog "$CAT"; c1_rc=$RC; cd "$T" || exit 1
[ "$c1n" = 1 ] && [ "$(cut -f2 <<<"$c1")" = "bin/blocked-resolver.d/" ] && [ "$c1_rc" = 0 ] \
  && ok "C1 one catalog row: bin/blocked-resolver.sh -> bin/blocked-resolver.d/; the lint loads it clean" \
  || bad "C1 rows: [$c1] lint rc=$c1_rc"

# C2
mk c2
insert_after "$(grep -n '^\[ -r "\$H/bin/lib/heartbeat.sh" \]' bin/blocked-resolver.sh | cut -d: -f1)" \
  '[ -r "$H/bin/lib/foo-gate.sh" ] && . "$H/bin/lib/foo-gate.sh"' bin/blocked-resolver.sh
pr; lint --base base
[ "$RC" = 1 ] && has 'list-file-lint: bin/blocked-resolver.sh grew by 1 line(s)' && has 'bin/blocked-resolver.d/' \
  && ok "C2 a source line appended with no fragment is rc 1 and names bin/blocked-resolver.d/" \
  || bad "C2 rc=$RC out: $OUT"

# C3
mk c3; echo 'bh7_gate() { :; }' > bin/blocked-resolver.d/bh-7-gate.sh; pr
lint --base base; c3a=$RC; c3a_out=$OUT
mk c3b; sed -i '0,/^# THE DISPATCHER STOPS HERE (BH-5913)/s//# THE DISPATCHER ENDS HERE (BH-5913)/' bin/blocked-resolver.sh; pr
lint --base base
[ "$c3a" = 0 ] && [ "$RC" = 0 ] && [ -z "$OUT" ] && ! git diff --quiet base HEAD \
  && ok "C3 a fragment-only PR and a +1/-1 value edit of the driver are rc 0" \
  || bad "C3 frag rc=$c3a ($c3a_out) edit rc=$RC out: $OUT"

# C4
mk c4
printf 'echo more\necho more\n' | tee -a bin/lib/br/ladder.sh bin/lib/br/opt/stale.sh >/dev/null
pr; lint --base base
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok "C4 bin/lib/br/ladder.sh and bin/lib/br/opt/stale.sh grow freely (rc 0, no output)" \
  || bad "C4 rc=$RC out: $OUT"
cd "$T" || exit 1

# The fragment checker. frag_check <dir> <repo> — prints one line per problem
# and is rc 1 on any. A fragment's functions are read from its text, so
# checking never runs fragment code.
fn_names() { sed -nE 's/^[[:space:]]*(function[[:space:]]+)?([A-Za-z_][A-Za-z0-9_:-]*)[[:space:]]*\(\)[[:space:]]*\{?.*$/\2/p' "$@" | sort -u; }
frag_check() {
  local dir=$1 root=$2 f n bad=0 lib
  local -a libs=("$root/bin/blocked-resolver.sh")
  for lib in "$root"/bin/lib/br/*.sh "$root"/bin/lib/br/opt/*.sh \
             $(grep -oE '"\$H/bin/lib/[A-Za-z0-9_./-]+\.sh"' "$root/bin/blocked-resolver.sh" | tr -d '"' | sed "s#\\\$H#$root#"); do
    [ -f "$lib" ] && libs+=("$lib")
  done
  fn_names "${libs[@]}" > "$T/driver-names"
  : > "$T/frag-names"
  for f in "$dir"/*.sh; do
    [ -f "$f" ] || continue
    n=${f##*/}
    [[ $n =~ ^[a-z]+-[0-9]+(\.[0-9]+)?-[a-z0-9][a-z0-9-]*\.sh$ ]] || { echo "bad name: $n"; bad=1; }
    bash -n "$f" 2>/dev/null || { echo "syntax: $n"; bad=1; }
    while IFS= read -r fn; do
      [ -n "$fn" ] || continue
      grep -qxF "$fn" "$T/driver-names" && { echo "shadows driver name: $n: $fn"; bad=1; }
      printf '%s\t%s\n' "$fn" "$n" >> "$T/frag-names"
    done < <(fn_names "$f")
  done
  while IFS= read -r fn; do echo "defined twice: $fn"; bad=1; done < <(cut -f1 "$T/frag-names" | sort | uniq -d)
  return "$bad"
}

# V1
OUT=$(frag_check "$FRAGS" "$REPO"); RC=$?
[ -d "$FRAGS" ] && [ "$RC" = 0 ] && [ -z "$OUT" ] && grep -qx br_queue_enq "$T/driver-names" \
  && grep -qx say "$T/driver-names" && grep -qx br_ladder_rung "$T/driver-names" \
  && ok "V1 the real bin/blocked-resolver.d/ passes the fragment checker" || bad "V1 dir=$([ -d "$FRAGS" ] && echo y || echo n) rc=$RC out: $OUT"

# V2-V4
v() { rm -rf "$T/v"; mkdir -p "$T/v"; }
v; echo 'x() { :; }' > "$T/v/foo.sh"; echo 'y() { :; }' > "$T/v/BH-1-a.sh"; echo 'z() { :; }' > "$T/v/bh-1-.sh"
OUT=$(frag_check "$T/v" "$REPO"); RC=$?
[ "$RC" = 1 ] && has 'bad name: foo.sh' && has 'bad name: BH-1-a.sh' && has 'bad name: bh-1-.sh' \
  && ok "V2 the checker refuses foo.sh, BH-1-a.sh and bh-1-.sh" || bad "V2 rc=$RC out: $OUT"
v; printf 'bh1_a() {\n  if then\n}\n' > "$T/v/bh-1-a.sh"
echo 'br_queue_enq() { :; }' > "$T/v/bh-2-b.sh"; echo 'br_ladder_rung() { :; }' > "$T/v/bh-3-c.sh"
echo 'say() { :; }' > "$T/v/bh-4-d.sh"
OUT=$(frag_check "$T/v" "$REPO"); RC=$?
[ "$RC" = 1 ] && has 'syntax: bh-1-a.sh' && has 'shadows driver name: bh-2-b.sh: br_queue_enq' \
  && has 'shadows driver name: bh-3-c.sh: br_ladder_rung' && has 'shadows driver name: bh-4-d.sh: say' \
  && ok "V3 the checker refuses a syntax error and a fragment defining br_queue_enq, br_ladder_rung or say" \
  || bad "V3 rc=$RC out: $OUT"
v; echo 'x_gate() { :; }' > "$T/v/bh-1-a.sh"; echo 'x_gate() { :; }' > "$T/v/bh-2-b.sh"
OUT=$(frag_check "$T/v" "$REPO"); RC=$?; v4a=$RC; v4a_out=$OUT
v; echo 'bh1_a_gate() { :; }' > "$T/v/bh-1-a.sh"
OUT=$(frag_check "$T/v" "$REPO"); RC=$?
[ "$v4a" = 1 ] && grep -q 'defined twice: x_gate' <<<"$v4a_out" && [ "$RC" = 0 ] && [ -z "$OUT" ] \
  && ok "V4 the checker refuses x_gate in two fragments and accepts bh-1-a.sh defining bh1_a_gate" \
  || bad "V4 dup rc=$v4a ($v4a_out) good rc=$RC out: $OUT"

echo "blocked-resolver-frags.bh-7450: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
