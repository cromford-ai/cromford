#!/bin/bash
# tests/lead-review-enqueue-frags.bh-8396-test.sh — BH-8396: a new optional lib
# or helper for the lead-review enqueue is its own file,
# bin/lead-review-enqueue.d/<key>-<name>.sh, and the driver sources every such
# file once, in LC_ALL=C name order, from ONE marker block after its in-file
# optional libs. bin/list-file-lint.sh refuses a PR that grows
# bin/lead-review-enqueue.sh with no new file under bin/lead-review-enqueue.d/.
#
# WHAT THIS PINS. The F cases cut the marker block out of the REAL driver and
# run it in a clean `bash --norc` with H set to a scratch tree and a stub log.
# The M and C cases build scratch git repos with the real driver and the real
# catalog, and run the REAL bin/list-file-lint.sh as a process.
#   F1 the real fragment dir: no variable and no output added; the only new
#      functions are the ones its fragments declare (none while it holds only
#      the README: the tick defines what it defined before the block)
#   F2 order and selection: LC_ALL=C name order, regular *.sh only, each once
#   F3 a syntax error and a `return 3`: one log line each (real rc), goes on;
#      the syntax error is refused by `bash -n` before any of its lines run
#   F4 no lead-review-enqueue.d/ at all, and an empty one: nothing sourced, no
#      output, no variable
#   F5 a fragment's function is callable after the block (main shell)
#   M1 placement: after the console-qa-gate lib, before cqg_gate_on(); the only
#      text naming lead-review-enqueue.d past the header; nothing generated
#      tracked in the dir
#   M2 two sibling branches each add a fragment (+1 call site) and merge clean;
#      the merged tree's block defines both; the old append shape conflicts
#   C1 the shipped catalog has one row for bin/lead-review-enqueue.sh
#   C2 a source line appended to the driver with no fragment -> lint rc 1
#   C3 a fragment-only PR, and a +1/-1 value edit of the driver -> rc 0
#   V1 every real fragment passes the fragment checker
#   V2-V4 the checker refuses bad names, a syntax error, a shadowed driver
#      name and a name defined twice; it accepts a good fragment
#   P1 the lead-protected seed protects bin/lead-review-enqueue.d/**, and the
#      BH-4148 fixture mirrors that glob (its case F compares the two)
#
# Run from anywhere: tests/lead-review-enqueue-frags.bh-8396-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
DRIVER="$REPO/bin/lead-review-enqueue.sh"
FRAGS="$REPO/bin/lead-review-enqueue.d"
LINT="$REPO/bin/list-file-lint.sh"
CAT="$REPO/catalog/list-files.tsv"
SEED="$REPO/catalog/lead-protected-paths.seed.tsv"
FIXTURE="$REPO/tests/fixtures/lead-protected-paths.bh-4148.txt"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.com
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.com
export GIT_AUTHOR_DATE='2026-10-26T12:00:00Z' GIT_COMMITTER_DATE='2026-10-26T12:00:00Z'

OPEN='# >>> lead-review-enqueue.d fragments (BH-8396)'
CLOSE='# <<< lead-review-enqueue.d fragments (BH-8396)'

# block_of <driver> — the marker block, markers included.
block_of() { awk -v o="$OPEN" -v c="$CLOSE" '$0==o{on=1} on{print} $0==c{on=0}' "$1"; }

# run_block <block file> <H> [extra script] — the block in a clean shell with a
# stub log; records the function and variable sets before and after under
# $T/state. Sets OUT and RC (RC is the block's own status).
run_block() {
  local blk=$1 h=$2 extra=${3:-}
  mkdir -p "$T/state"
  cat > "$T/runner.sh" <<'RUNNER'
H=$1; ST=$2; BLK=$3
log() { echo "LOG $*"; }
declare -F | sort > "$ST/before.f"; compgen -v | sort > "$ST/before.v"
. "$BLK"; brc=$?
declare -F | sort > "$ST/after.f"; compgen -v | grep -vx brc | sort > "$ST/after.v"
echo "BLOCK-RC $brc"
RUNNER
  printf '%s\n' "$extra" >> "$T/runner.sh"
  OUT=$(cd "$T" && env -i PATH="$PATH" LC_ALL="${RUN_LC_ALL:-C}" ${RUN_LANG:+LANG="$RUN_LANG"} \
    bash --norc --noprofile "$T/runner.sh" "$h" "$T/state" "$blk" 2>&1)
  RC=$(sed -n 's/^BLOCK-RC //p' <<<"$OUT")
}
has() { case "$OUT" in *"$1"*) return 0 ;; esac; return 1; }

REAL_BLK="$T/real-block.sh"
block_of "$DRIVER" > "$REAL_BLK"
nopen=$(grep -cxF "$OPEN" "$DRIVER"); nclose=$(grep -cxF "$CLOSE" "$DRIVER")

# F1
mkdir -p "$T/f1/bin"
[ -d "$FRAGS" ] && cp -R "$FRAGS" "$T/f1/bin/lead-review-enqueue.d"
run_block "$REAL_BLK" "$T/f1"
f1_want=$( (set +f; cat "$T"/f1/bin/lead-review-enqueue.d/*.sh 2>/dev/null) \
  | sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)() *{.*/\1/p' | LC_ALL=C sort -u | paste -sd' ' -)
f1_got=$(LC_ALL=C comm -13 "$T/state/before.f" "$T/state/after.f" | awk '{print $NF}' | LC_ALL=C sort -u | paste -sd' ' -)
f1_lost=$(LC_ALL=C comm -23 "$T/state/before.f" "$T/state/after.f")
if [ "$nopen" = 1 ] && [ "$nclose" = 1 ] && [ -d "$T/f1/bin/lead-review-enqueue.d" ] \
   && [ "$RC" = 0 ] && [ "$OUT" = "BLOCK-RC 0" ] && [ "$f1_got" = "$f1_want" ] \
   && [ -z "$f1_lost" ] \
   && cmp -s "$T/state/before.v" "$T/state/after.v"; then
  ok "F1 the real fragment dir adds no variable and no output, and only its declared functions (${f1_want:-none})"
else bad "F1 open=$nopen close=$nclose rc=$RC out: $OUT; funcs want=[$f1_want] got=[$f1_got]; vars: $(diff "$T/state/before.v" "$T/state/after.v" | tr '\n' ' ')"; fi

# F2 — each fragment appends its name to TRACE.
mk_frags() {
  local d=$1/bin/lead-review-enqueue.d n
  mkdir -p "$d/x" "$d/bh-9-d.sh"
  for n in bh-12-b bh-1-a-x bh-1-a bh-2.1-c; do
    printf 'TRACE="${TRACE:-}%s "\n' "$n" > "$d/$n.sh"
  done
  echo 'TRACE="${TRACE:-}README "' > "$d/README.md"
  echo 'TRACE="${TRACE:-}tilde "' > "$d/bh-1-a.sh~"
  echo 'TRACE="${TRACE:-}bash "' > "$d/bh-1-a.bash"
  echo 'TRACE="${TRACE:-}sub "' > "$d/x/bh-1-f.sh"
  ln -s "$d/no-such-file" "$d/bh-9-e.sh"
}
mk_frags "$T/f2"
f2_ok=1; f2_why=
want_trace='TRACE=bh-1-a-x bh-1-a bh-12-b bh-2.1-c '
run_block "$REAL_BLK" "$T/f2" 'echo "TRACE=$TRACE"'
[ "$RC" = 0 ] && has "$want_trace" && ! has LOG || { f2_ok=0; f2_why="LC_ALL=C: $OUT"; }
# The block fixes its own order, so a caller locale does not change it.
for loc in $(locale -a 2>/dev/null | grep -ixE 'c\.utf-?8|en_us\.utf-?8'); do
  RUN_LC_ALL= RUN_LANG=$loc run_block "$REAL_BLK" "$T/f2" 'echo "TRACE=$TRACE"'
  has "$want_trace" || { f2_ok=0; f2_why="$f2_why LANG=$loc: $OUT"; }
done
[ "$f2_ok" = 1 ] && ok "F2 regular *.sh only, LC_ALL=C order (bh-1-a-x bh-1-a bh-12-b bh-2.1-c), each once" \
  || bad "F2 $f2_why"

# F3
d="$T/f3/bin/lead-review-enqueue.d"; mkdir -p "$d"
echo 'f3_one() { echo one; }' > "$d/bh-1-one.sh"
printf 'F3_RAN=1\nf3_bad() {\n  if then\n}\n' > "$d/bh-2-syntax.sh"
printf 'f3_ret() { :; }\nreturn 3\n' > "$d/bh-3-ret.sh"
echo 'f3_four() { echo four; }' > "$d/bh-4-four.sh"
run_block "$REAL_BLK" "$T/f3" 'declare -F f3_one f3_four >/dev/null && echo BOTH-DEFINED; echo "F3_RAN=${F3_RAN:-0}"'
nlog=$(grep -c '^LOG lead-review-enqueue.d: ' <<<"$OUT")
if [ "$RC" = 0 ] && [ "$nlog" = 2 ] && has 'LOG lead-review-enqueue.d: bh-2-syntax.sh does not parse; skipped this tick' \
   && has 'LOG lead-review-enqueue.d: bh-3-ret.sh failed to source (rc 3); skipped this tick' && has BOTH-DEFINED \
   && has 'F3_RAN=0' && ! has 'bh-1-one.sh' && ! has 'bh-4-four.sh'; then
  ok "F3 one log line per failed fragment (parse, real rc 3), no line of the bad one runs, the good ones load"
else bad "F3 rc=$RC logs=$nlog out: $OUT"; fi

# F4 — no dir, then an empty dir.
mkdir -p "$T/f4/bin" "$T/f4e/bin/lead-review-enqueue.d"
f4_why=
for h in f4 f4e; do
  run_block "$REAL_BLK" "$T/$h"
  [ "$RC" = 0 ] && [ "$OUT" = "BLOCK-RC 0" ] \
    && cmp -s "$T/state/before.f" "$T/state/after.f" && cmp -s "$T/state/before.v" "$T/state/after.v" \
    || f4_why="$f4_why $h: rc=$RC out: $OUT;"
done
[ -z "$f4_why" ] && ok "F4 no lead-review-enqueue.d/, and an empty one: nothing sourced, no output, no variable left" \
  || bad "F4$f4_why"

# F5
d="$T/f5/bin/lead-review-enqueue.d"; mkdir -p "$d"
echo 'bh5_gate() { echo "gate:$1"; }' > "$d/bh-5-gate.sh"
run_block "$REAL_BLK" "$T/f5" 'bh5_gate x'
[ "$RC" = 0 ] && has 'gate:x' && ok "F5 a fragment's function is callable after the block" || bad "F5 rc=$RC out: $OUT"

# M1
cqg_lib=$(grep -n '^CQG=0; \. "\$H/bin/lib/console-qa-gate.sh"' "$DRIVER" | cut -d: -f1)
cqg_fn=$(grep -n '^cqg_gate_on() {' "$DRIVER" | cut -d: -f1)
body=$(grep -n '^set -uo pipefail' "$DRIVER" | head -1 | cut -d: -f1)
open_ln=$(grep -nxF "$OPEN" "$DRIVER" | cut -d: -f1)
close_ln=$(grep -nxF "$CLOSE" "$DRIVER" | cut -d: -f1)
outside=$(awk -v s="${body:-0}" -v a="${open_ln:-0}" -v b="${close_ln:-0}" 'NR>s && (NR<a || NR>b)' "$DRIVER" | grep -c 'lead-review-enqueue\.d')
tracked=$(git -C "$REPO" ls-files bin/lead-review-enqueue.d | grep -vxE 'bin/lead-review-enqueue\.d/(README\.md|[a-z]+-[0-9]+(\.[0-9]+)?-[a-z0-9][a-z0-9-]*\.sh)')
has_readme=$(git -C "$REPO" ls-files bin/lead-review-enqueue.d/README.md)
if [ -n "$open_ln" ] && [ -n "$cqg_lib" ] && [ -n "$cqg_fn" ] && [ -n "$body" ] \
   && [ "$open_ln" -gt "$cqg_lib" ] && [ "$close_ln" -lt "$cqg_fn" ] \
   && [ "$outside" = 0 ] && [ -z "$tracked" ] && [ -n "$has_readme" ]; then
  ok "M1 block after the console-qa-gate lib (:$cqg_lib) and before cqg_gate_on (:$cqg_fn); nothing generated tracked"
else bad "M1 open=$open_ln close=$close_ln cqg_lib=$cqg_lib cqg_fn=$cqg_fn outside=$outside tracked=[$tracked] readme=[$has_readme]"; fi

# The scratch repos for M2 and C1-C3: the real driver and catalog, on branch `base`.
mk() {
  local R="$T/$1"
  mkdir -p "$R" && cd "$R" || return 1
  git init -q -b main .
  mkdir -p catalog bin/lead-review-enqueue.d
  cp "$CAT" catalog/list-files.tsv
  cp "$DRIVER" bin/lead-review-enqueue.sh
  echo 'fragments' > bin/lead-review-enqueue.d/README.md
  git add -A && git commit -q -m base && git branch base
}
pr() { git add -A && git commit -q -m "${1:-pr}"; }
lint() { OUT=$("$LINT" "$@" 2>&1); RC=$?; }
# insert_after <line no> <text> <file>
insert_after() { awk -v n="$1" -v t="$2" '{print} NR==n{print t}' "$3" > "$3.tmp" && mv "$3.tmp" "$3"; }
# append_source_line <name> — the old shape: one more optional lib line after
# the silence-scan lib, the run of lines every sibling appended to.
append_source_line() {
  local ln; ln=$(grep -n '^\. "\$H/bin/lib/silence-scan.sh" 2>/dev/null || true$' bin/lead-review-enqueue.sh | cut -d: -f1)
  awk -v n="$ln" -v x="$1" '{print} NR==n{print "# The " x " gate."; print ". \"$H/bin/lib/" x ".sh\" 2>/dev/null || true"}' \
    bin/lead-review-enqueue.sh > bin/lead-review-enqueue.sh.tmp && mv bin/lead-review-enqueue.sh.tmp bin/lead-review-enqueue.sh
}

# M2
rq=$(grep -n '^request() {' "$DRIVER" | cut -d: -f1)
rb=$(grep -n '^rebase_hold() {' "$DRIVER" | cut -d: -f1)
mk m2
git checkout -q -b a base
echo 'bh101_a_gate() { echo A; }' > bin/lead-review-enqueue.d/bh-101-a.sh
insert_after "$rq" '  command -v bh101_a_gate >/dev/null 2>&1 && bh101_a_gate' bin/lead-review-enqueue.sh
pr a; lint --base base; rc_a=$RC
git checkout -q -b b base
echo 'bh102_b_gate() { echo B; }' > bin/lead-review-enqueue.d/bh-102-b.sh
insert_after "$rb" '  command -v bh102_b_gate >/dev/null 2>&1 && bh102_b_gate' bin/lead-review-enqueue.sh
pr b; lint --base base; rc_b=$RC
git checkout -q -b merged base
git merge -q --no-edit a >/dev/null 2>&1; rc_ma=$?
git merge -q --no-edit b >/dev/null 2>&1; rc_mb=$?
bash -n bin/lead-review-enqueue.sh; rc_n=$?
block_of bin/lead-review-enqueue.sh > "$T/m2-block.sh"
run_block "$T/m2-block.sh" "$T/m2" 'bh101_a_gate; bh102_b_gate'
m2_out=$OUT
# Control: the old shape, two siblings each appending a source line.
git checkout -q -b ca base; append_source_line ca-gate; pr ca
git checkout -q -b cb base; append_source_line cb-gate; pr cb
git checkout -q -b cm base
git merge -q --no-edit ca >/dev/null 2>&1
git merge -q --no-edit cb >/dev/null 2>&1; rc_ctl=$?
git merge --abort >/dev/null 2>&1
cd "$T" || exit 1
if [ "$rc_a" = 0 ] && [ "$rc_b" = 0 ] && [ "$rc_ma" = 0 ] && [ "$rc_mb" = 0 ] && [ "$rc_n" = 0 ] \
   && [ "$RC" = 0 ] && grep -qx A <<<"$m2_out" && grep -qx B <<<"$m2_out" && [ "$rc_ctl" != 0 ]; then
  ok "M2 two sibling fragments merge clean and both load; two appended source lines conflict"
else bad "M2 lint a=$rc_a b=$rc_b merge a=$rc_ma b=$rc_mb bash-n=$rc_n block=$RC control=$rc_ctl out: $m2_out"; fi

# C1
c1=$(grep -vE '^(#|[[:space:]]*$)' "$CAT" | awk -F'\t' '$1=="bin/lead-review-enqueue.sh"')
c1n=$(grep -cvE '^(#|[[:space:]]*$)' <<<"$c1")
[ "$c1n" = 1 ] && [ "$(cut -f2 <<<"$c1")" = "bin/lead-review-enqueue.d/" ] \
  && ok "C1 one catalog row: bin/lead-review-enqueue.sh -> bin/lead-review-enqueue.d/" || bad "C1 rows: [$c1]"

# C2
mk c2; append_source_line foo-gate; pr
lint --base base
[ "$RC" = 1 ] && has 'list-file-lint: bin/lead-review-enqueue.sh grew by 2 line(s)' && has 'bin/lead-review-enqueue.d/' \
  && has 'Fix: put the new entry in its own file under bin/lead-review-enqueue.d/' \
  && ok "C2 a source line appended with no fragment is rc 1 and names the file, growth and dir" \
  || bad "C2 rc=$RC out: $OUT"

# C3
mk c3; echo 'bh7_gate() { :; }' > bin/lead-review-enqueue.d/bh-7-gate.sh; pr
lint --base base; c3a=$RC; c3a_out=$OUT
mk c3b; sed -i '0,/^# The ticket-branch parser (BH-3835)/s//# The ticket-branch reader (BH-3835)/' bin/lead-review-enqueue.sh; pr
lint --base base
[ "$c3a" = 0 ] && [ "$RC" = 0 ] && [ -z "$OUT" ] && ! git diff --quiet base HEAD \
  && ok "C3 a fragment-only PR and a +1/-1 value edit of the driver are rc 0" \
  || bad "C3 frag rc=$c3a ($c3a_out) edit rc=$RC out: $OUT"
cd "$T" || exit 1

# The fragment checker. frag_check <dir> <repo> — prints one line per problem
# and is rc 1 on any. A fragment's functions are read from its text (column
# `name()`, optional `function`), so checking never runs fragment code.
fn_names() { sed -nE 's/^[[:space:]]*(function[[:space:]]+)?([A-Za-z_][A-Za-z0-9_:-]*)[[:space:]]*\(\)[[:space:]]*\{?.*$/\2/p' "$@" | sort -u; }
frag_check() {
  local dir=$1 root=$2 f n bad=0 lib
  local -a libs=("$root/bin/lead-review-enqueue.sh")
  for lib in "$root"/bin/jobs-client.sh \
             $(grep -oE '"\$H/bin/lib/[A-Za-z0-9_./-]+\.sh"' "$root/bin/lead-review-enqueue.sh" | tr -d '"' | sed "s#\\\$H#$root#"); do
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
[ "$RC" = 0 ] && [ -z "$OUT" ] && grep -qx request "$T/driver-names" && grep -qx log "$T/driver-names" \
  && grep -qx cqg_gate_on "$T/driver-names" \
  && ok "V1 the real bin/lead-review-enqueue.d/ passes the fragment checker" || bad "V1 rc=$RC out: $OUT"

# V2-V4
v() { rm -rf "$T/v"; mkdir -p "$T/v"; }
v; echo 'x() { :; }' > "$T/v/foo.sh"; echo 'y() { :; }' > "$T/v/BH-1-a.sh"; echo 'z() { :; }' > "$T/v/bh-1-.sh"
OUT=$(frag_check "$T/v" "$REPO"); RC=$?
[ "$RC" = 1 ] && has 'bad name: foo.sh' && has 'bad name: BH-1-a.sh' && has 'bad name: bh-1-.sh' \
  && ok "V2 the checker refuses foo.sh, BH-1-a.sh and bh-1-.sh" || bad "V2 rc=$RC out: $OUT"
v; printf 'bh1_a() {\n  if then\n}\n' > "$T/v/bh-1-a.sh"
echo 'request() { :; }' > "$T/v/bh-2-b.sh"; echo 'log() { :; }' > "$T/v/bh-3-c.sh"
OUT=$(frag_check "$T/v" "$REPO"); RC=$?
[ "$RC" = 1 ] && has 'syntax: bh-1-a.sh' && has 'shadows driver name: bh-2-b.sh: request' \
  && has 'shadows driver name: bh-3-c.sh: log' \
  && ok "V3 the checker refuses a syntax error and a fragment defining request or log" || bad "V3 rc=$RC out: $OUT"
v; echo 'x_gate() { :; }' > "$T/v/bh-1-a.sh"; echo 'x_gate() { :; }' > "$T/v/bh-2-b.sh"
OUT=$(frag_check "$T/v" "$REPO"); RC=$?; v4a=$RC; v4a_out=$OUT
v; echo 'bh1_a_gate() { :; }' > "$T/v/bh-1-a.sh"
OUT=$(frag_check "$T/v" "$REPO"); RC=$?
[ "$v4a" = 1 ] && grep -q 'defined twice: x_gate' <<<"$v4a_out" && [ "$RC" = 0 ] && [ -z "$OUT" ] \
  && ok "V4 the checker refuses x_gate in two fragments and accepts bh-1-a.sh defining bh1_a_gate" \
  || bad "V4 dup rc=$v4a ($v4a_out) good rc=$RC out: $OUT"

# P1
p1_seed=0; p1_fix=0
grep -qxF "$(printf 'example-org/cromford\tbin/lead-review-enqueue.d/**')" "$SEED" && p1_seed=1
grep -qxF 'bin/lead-review-enqueue.d/**' "$FIXTURE" && p1_fix=1
[ "$p1_seed" = 1 ] && [ "$p1_fix" = 1 ] \
  && ok "P1 the lead-protected seed protects bin/lead-review-enqueue.d/**, and the BH-4148 fixture mirrors it" \
  || bad "P1 seed row=$p1_seed fixture line=$p1_fix"

echo "lead-review-enqueue-frags.bh-8396: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
