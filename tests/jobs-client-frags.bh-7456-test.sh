#!/bin/bash
# tests/jobs-client-frags.bh-7456-test.sh — BH-7456: a NEW jobs-client verb is
# a fragment file under bin/jobs-client.d/, never a new arm in
# bin/jobs-client.sh, so two sibling builds that each add a verb do not edit
# the same hunk. bin/jobs-client.sh is a list file in catalog/list-files.tsv, so
# bin/list-file-lint.sh refuses a PR that grows it without a fragment.
#
# Fragment: bin/jobs-client.d/<ticket-key>-<verb>.sh, with `#: <verb> <args>`
# line(s) at column 0 and one function jc_verb_<verb, - as _>. The client reads
# fragments only on direct invocation, only for a verb no in-file arm takes.
#
#   F1  two sibling branches that each add a fragment merge clean; the client
#       stays byte-identical; lint rc 0 on each branch and on the merge; both
#       verbs dispatch through the real client; the usage ends with both entries
#   F2  two siblings that each insert an in-file arm above `*)` conflict, and
#       each alone is lint rc 1 naming bin/jobs-client.sh and bin/jobs-client.d/
#   F3  dispatch decision table: an in-file verb wins over a fragment that
#       defines the same function; bad verb names are rc 2 with one usage line
#       and run no fragment; a broken fragment prints one `did not load` line and
#       a sibling still works; a fragment's return code is the script's rc
#   F4  library mode (sourced) defines no jc_verb_* and no _jc_frags
#   R1  the usage with the real bin/jobs-client.d/ is the in-file `#:` entries
#       joined, then the real fragments' entries (today: none)
#   R2  the `case "$CMD" in` block, `*)` arm excluded, is byte-equal to 40d7e7d5
#   R3  every real fragment is well-formed and shadows no in-file verb
#   L1  the real catalog has exactly one bin/jobs-client.sh row, input bin/jobs-client.d/
#   L2  an in-file append with no fragment -> lint rc 1
#   L3  a fragment-only PR -> rc 0; a +1/-1 value edit -> rc 0
#   L4  near misses: bin/lib/jobs/queue.sh and x/bin/jobs-client.sh grow -> rc 0
#
# No network: every client run unsets HARNESS_SECRET and JOBS_URL and reads an
# empty global.env. Each case builds its own scratch dir.
# JC_SRC=<file> runs the suite against another copy of the client.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/jobs-client-frags.bh-7456-test.sh   (exit 0 = all pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
SRC="${JC_SRC:-$REPO/bin/jobs-client.sh}"
LINT="$REPO/bin/list-file-lint.sh"
CAT="$REPO/catalog/list-files.tsv"
REALD="$REPO/bin/jobs-client.d"
PIN=40d7e7d5
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
info() { echo "  info $1"; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.com
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.com
export GIT_AUTHOR_DATE='2026-10-20T05:00:00Z' GIT_COMMITTER_DATE='2026-10-20T05:00:00Z'

# The in-file `#:` entries of a client, in file order.
doc_entries() {
  awk '/^  case "\$CMD" in/{f=1;next} f&&/^    \*\)/{exit} f&&sub(/^    #: /,""){print}' "$1"
}
arm_list() {
  awk '/^  case "\$CMD" in/{f=1;next} f&&/^    \*\)/{exit}
       f&&match($0,/^    [a-z][a-z0-9-]*\)/){print substr($0,5,RLENGTH-5)}' "$1"
}
# frag <file> <verb> <usage-args> <body> — one fragment file.
frag() {
  local fn="jc_verb_${2//-/_}"
  printf '#: %s %s\n%s() {\n  %s\n}\n' "$2" "$3" "$fn" "$4" > "$1"
}
# mkh <name> — a scratch harness at $T/<name> running $SRC as delivered.
mkh() {
  H="$T/$1"
  mkdir -p "$H/env" "$H/logs" || return 1
  : > "$H/env/global.env"
  scratch_install_closure bin/jobs-client.sh "$H" >/dev/null || { echo "closure install failed"; return 1; }
  cp "$SRC" "$H/bin/jobs-client.sh"
}
# jc <harness> <args...> — run that harness's client; stdout $T/out, stderr $T/err.
jc() {
  local h=$1; shift
  env -u HARNESS_SECRET -u JOBS_URL HARNESS="$h" HARNESS_ENV_DIR="$h/env" \
    bash "$h/bin/jobs-client.sh" "$@" >"$T/out" 2>"$T/err"
}
usage_body() { local u; u=$(cat "$T/err"); u=${u#usage: jobs-client.sh \{}; printf '%s' "${u%\}}"; }
lint() { OUT=$("$LINT" "$@" 2>&1); RC=$?; }
has() { case "$OUT" in *"$1"*) return 0 ;; esac; return 1; }
# mkr <case> — a git repo at $T/<case>: the client and the real catalog, branch `base`.
mkr() {
  R="$T/$1"
  mkdir -p "$R/bin/lib/jobs" "$R/catalog" "$R/x/bin" && cd "$R" || return 1
  git init -q -b main .
  cp "$SRC" bin/jobs-client.sh && cp "$CAT" catalog/list-files.tsv
  cp "$SRC" x/bin/jobs-client.sh
  printf 'a\nb\n' > bin/lib/jobs/queue.sh
  git add -A && git commit -q -m base && git branch base
}
pr() { git add -A && git commit -q -m "$1"; }
# add_arm <file> <verb> — insert one documented arm just above `    *)`.
add_arm() {
  awk -v v="$2" '/^    \*\)/&&!d{print "    #: " v " <x>"; print "    " v ") echo " v "; RC=0 ;;"; d=1} {print}' \
    "$1" > "$1.n" && mv "$1.n" "$1"
}

[ -r "$SRC" ] || { echo "jobs-client-frags.bh-7456-test: cannot read $SRC"; exit 1; }

# ══ F1. two sibling fragments merge clean and both dispatch ═════════════════
echo "F1 sibling fragments"
mkr f1 || exit 1
git checkout -q -b a base; mkdir -p bin/jobs-client.d
frag bin/jobs-client.d/bh-9001-zz-alpha.sh zz-alpha '<x>' 'echo alpha'; pr a
lint --base base; [ "$RC" = 0 ] && ok "F1 lint rc 0 on branch a" || bad "F1 lint branch a rc=$RC: $OUT"
git checkout -q -b b base; mkdir -p bin/jobs-client.d
frag bin/jobs-client.d/bh-9002-zz-beta.sh zz-beta '<y>' 'echo beta'; pr b
lint --base base; [ "$RC" = 0 ] && ok "F1 lint rc 0 on branch b" || bad "F1 lint branch b rc=$RC: $OUT"
git checkout -q a
if git merge -q --no-edit b >/dev/null 2>&1; then ok "F1 merge of a and b: rc 0, no conflict"
else bad "F1 merge of a and b conflicted"; git merge --abort 2>/dev/null; fi
git show base:bin/jobs-client.sh | cmp -s - bin/jobs-client.sh \
  && ok "F1 bin/jobs-client.sh is byte-identical to the base" || bad "F1 bin/jobs-client.sh changed in the merge"
lint --base base; [ "$RC" = 0 ] && ok "F1 lint rc 0 on the merge" || bad "F1 lint merge rc=$RC: $OUT"
mkh f1h || exit 1
cp bin/jobs-client.sh "$H/bin/jobs-client.sh" && cp -R bin/jobs-client.d "$H/bin/"
jc "$H" zz-alpha q; rc=$?
[ "$rc" = 0 ] && [ "$(cat "$T/out")" = alpha ] && ok "F1 zz-alpha prints alpha, rc 0" \
  || bad "F1 zz-alpha rc=$rc out=$(cat "$T/out") err=$(head -c 200 "$T/err")"
jc "$H" zz-beta; rc=$?
[ "$rc" = 0 ] && [ "$(cat "$T/out")" = beta ] && ok "F1 zz-beta prints beta, rc 0" \
  || bad "F1 zz-beta rc=$rc out=$(cat "$T/out") err=$(head -c 200 "$T/err")"
jc "$H"; rc=$?
case "$(cat "$T/err")" in
  *'|zz-alpha <x>|zz-beta <y>}') [ "$rc" = 2 ] && ok "F1 usage ends |zz-alpha <x>|zz-beta <y>}" || bad "F1 usage rc=$rc" ;;
  *) bad "F1 usage tail: $(tail -c 80 "$T/err")" ;;
esac
cd "$T" || exit 1

# ══ F2. two sibling in-file arms conflict; each alone is red ════════════════
echo "F2 sibling in-file arms"
mkr f2 || exit 1
git checkout -q -b c base; add_arm bin/jobs-client.sh zz-gamma; pr c
lint --base base
[ "$RC" = 1 ] && has 'bin/jobs-client.sh grew' && has 'bin/jobs-client.d/' \
  && ok "F2 an in-file arm alone: lint rc 1 naming bin/jobs-client.sh and bin/jobs-client.d/" \
  || bad "F2 branch c rc=$RC: $OUT"
git checkout -q -b d base; add_arm bin/jobs-client.sh zz-delta; pr d
lint --base base
[ "$RC" = 1 ] && has 'bin/jobs-client.sh grew' && has 'bin/jobs-client.d/' \
  && ok "F2 the sibling arm alone: lint rc 1" || bad "F2 branch d rc=$RC: $OUT"
git checkout -q c
if git merge -q --no-edit d >/dev/null 2>&1; then bad "F2 two in-file arms merged clean (the counter-case is wrong)"
else ok "F2 two in-file arms above *) conflict"; git merge --abort 2>/dev/null; fi
cd "$T" || exit 1

# ══ F3. the dispatch decision table ═════════════════════════════════════════
echo "F3 dispatch"
mkh f3 || exit 1
FD="$H/bin/jobs-client.d"; MARK="$T/f3.mark"
mkdir -p "$FD"
frag "$FD/bh-9001-zz-alpha.sh" zz-alpha '<x>' "echo alpha; : > '$MARK.alpha'"
frag "$FD/bh-9003-setting-get.sh" setting-get '<k>' "echo frag; : > '$MARK.sg'"
frag "$FD/bh-9004-zz-a-b.sh" zz-a-b '<p> <q>' 'echo "ab:$*"'
frag "$FD/bh-9005-zz-three.sh" zz-three '' 'echo three; return 3'
printf '#: zz-broken\njc_verb_zz_broken() {\n  if then\n}\n' > "$FD/bh-9006-zz-broken.sh"
printf 'not a fragment\n' > "$FD/README.md"
jc "$H" setting-get zz.f3.key
[ ! -e "$MARK.sg" ] && ! grep -qx frag "$T/out" \
  && ok "F3 setting-get runs its in-file arm, not the fragment" || bad "F3 setting-get ran the fragment"
for v in bogus-verb '' Zz-alpha zz_alpha ../x 'zz-alpha;id' README; do
  jc "$H" "$v"; rc=$?
  n=$(grep -c '^usage: jobs-client.sh {' "$T/err")
  [ "$rc" = 2 ] && [ "$n" = 1 ] && [ ! -s "$T/out" ] && [ ! -e "$MARK.alpha" ] \
    && ok "F3 '$v': rc 2, one usage line, no fragment ran" \
    || bad "F3 '$v': rc=$rc usage-lines=$n out=$(head -c 80 "$T/out") mark=$([ -e "$MARK.alpha" ] && echo yes || echo no)"
  rm -f "$MARK.alpha"
done
jc "$H" zz-alpha; rc=$?
nl=$(grep -c 'did not load' "$T/err")
[ "$rc" = 0 ] && [ "$(cat "$T/out")" = alpha ] && [ "$nl" = 1 ] \
  && grep -q "jobs-client: fragment .*bh-9006-zz-broken.sh did not load" "$T/err" \
  && ok "F3 a broken sibling: one 'did not load' line naming it; zz-alpha still runs" \
  || bad "F3 broken sibling: rc=$rc out=$(cat "$T/out") err=$(head -c 300 "$T/err")"
jc "$H" zz-broken; rc=$?
[ "$rc" = 2 ] && grep -q '^usage: jobs-client.sh {' "$T/err" \
  && ok "F3 the broken fragment's own verb: rc 2 with the usage" || bad "F3 zz-broken rc=$rc"
jc "$H" zz-a-b p1 p2; rc=$?
[ "$rc" = 0 ] && [ "$(cat "$T/out")" = 'ab:p1 p2' ] \
  && ok "F3 zz-a-b dispatches to jc_verb_zz_a_b with its args" || bad "F3 zz-a-b rc=$rc out=$(cat "$T/out")"
jc "$H" zz-three; rc=$?
[ "$rc" = 3 ] && [ "$(cat "$T/out")" = three ] && ok "F3 a fragment returning 3: script rc 3" \
  || bad "F3 zz-three rc=$rc out=$(cat "$T/out")"

# ══ F4. library mode loads no fragment and defines no new function ══════════
echo "F4 library mode"
env -u HARNESS_SECRET -u JOBS_URL HARNESS="$H" HARNESS_ENV_DIR="$H/env" \
  bash -c '. "$1/bin/jobs-client.sh" >/dev/null 2>&1; declare -F' _ "$H" > "$T/f4.fns" 2>/dev/null
if [ -s "$T/f4.fns" ] && grep -q 'job_open' "$T/f4.fns"; then
  ! grep -qE 'jc_verb_|_jc_frags' "$T/f4.fns" \
    && ok "F4 sourced client defines no jc_verb_* and no _jc_frags" \
    || bad "F4 sourced client defined: $(grep -E 'jc_verb_|_jc_frags' "$T/f4.fns" | tr '\n' ' ')"
else bad "F4 the sourced client did not load its modules"; fi

# ══ R1. the usage is the in-file entries, then the real fragments' ══════════
echo "R1 usage with the real fragment dir"
mkh r1 || exit 1
[ -d "$REALD" ] && cp -R "$REALD" "$H/bin/"
nreal=0; want=$(doc_entries "$SRC")
if [ -d "$REALD" ]; then
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    nreal=$((nreal + 1)); want+=$'\n'$(sed -n 's/^#: //p' "$f")
  done < <(find "$REALD" -maxdepth 1 -type f -name '*.sh' | LC_ALL=C sort)
fi
want=$(printf '%s\n' "$want" | sed '/^$/d' | paste -sd'|')
jc "$H"; rc=$?
[ "$rc" = 2 ] && [ "$(usage_body)" = "$want" ] \
  && ok "R1 usage = in-file #: entries + $nreal real fragment(s)" \
  || bad "R1 usage differs (rc $rc): got ...$(usage_body | tail -c 100) want ...$(printf '%s' "$want" | tail -c 100)"
[ "$nreal" = 0 ] && { [ "$(usage_body)" = "$(doc_entries "$SRC" | paste -sd'|')" ] \
  && ok "R1 no real fragment: the usage is exactly the in-file entries" || bad "R1 zero fragments, usage is not the in-file entries"; }

# ══ R2. no in-file arm moved or changed ═════════════════════════════════════
echo "R2 in-file arms vs $PIN"
block() { awk '/^  case "\$CMD" in/{f=1;next} f&&/^    \*\)/{exit} f' "$1"; }
if git -C "$REPO" cat-file -e "$PIN:bin/jobs-client.sh" 2>/dev/null; then
  git -C "$REPO" show "$PIN:bin/jobs-client.sh" > "$T/pin.sh"
  n=$(arm_list "$T/pin.sh" | wc -l)
  [ "$n" -ge 148 ] && [ "$(block "$SRC")" = "$(block "$T/pin.sh")" ] \
    && ok "R2 the case block above *) is byte-equal to $PIN ($n arms)" || bad "R2 the case block differs from $PIN (pin arms $n)"
else info "R2: $PIN is not in this clone's history; the compare did not run"; fi

# ══ R3. every real fragment is well-formed ══════════════════════════════════
echo "R3 real fragments"
arms=" $(arm_list "$SRC" | tr '\n' ' ') "; nr=0; r3bad=0
if [ -d "$REALD" ]; then
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    nr=$((nr + 1)); b=$(basename "$f"); why=""
    if ! [[ $b =~ ^[a-z]+-[0-9]+(\.[0-9]+)?-([a-z][a-z0-9-]*)\.sh$ ]]; then why="bad file name"
    else
      v=${BASH_REMATCH[2]}; fn="jc_verb_${v//-/_}"
      fns=$(grep -oE '^[A-Za-z_][A-Za-z0-9_]*\(\)' "$f" | tr -d '()' | sort -u | tr '\n' ' ')
      bash -n "$f" 2>/dev/null || why="bash -n fails"
      [ "$fns" = "$fn " ] || why="${why:+$why; }functions '$fns', want '$fn'"
      w=$(sed -n 's/^#: //p' "$f" | awk '{print $1}' | sort -u | tr '\n' ' ')
      [ "$w" = "$v " ] || why="${why:+$why; }#: verbs '$w', want '$v'"
      [[ $arms == *" $v "* ]] && why="${why:+$why; }shadows the in-file arm $v"
    fi
    [ -z "$why" ] || { r3bad=1; bad "R3 $b: $why"; }
  done < <(find "$REALD" -maxdepth 1 -type f -name '*.sh' | LC_ALL=C sort)
fi
[ "$r3bad" = 0 ] && ok "R3 $nr real fragment(s), all well-formed"

# ══ L1-L4. the catalog row and the lint decision table ══════════════════════
echo "L1-L4 list-file-lint"
nrow=$(awk -F'\t' '$1 == "bin/jobs-client.sh"' "$CAT" | wc -l)
inp=$(awk -F'\t' '$1 == "bin/jobs-client.sh" {print $2}' "$CAT")
[ "$nrow" = 1 ] && [ "$inp" = bin/jobs-client.d/ ] \
  && ok "L1 one bin/jobs-client.sh row, input bin/jobs-client.d/" || bad "L1 rows=$nrow input='$inp'"
mkr l2 || exit 1
add_arm bin/jobs-client.sh zz-l2; pr l2; lint --base base
[ "$RC" = 1 ] && has 'bin/jobs-client.sh grew by 2 line(s)' && has 'adds no file under bin/jobs-client.d/' \
  && ok "L2 an in-file append with no fragment: rc 1" || bad "L2 rc=$RC: $OUT"
mkr l3a || exit 1
mkdir -p bin/jobs-client.d; frag bin/jobs-client.d/bh-9007-zz-l3.sh zz-l3 '' 'echo l3'; pr l3a; lint --base base
[ "$RC" = 0 ] && ok "L3 a fragment-only PR: rc 0" || bad "L3 fragment-only rc=$RC: $OUT"
mkr l3b || exit 1
sed -i 's/^    #: cap <lane>$/    #: cap <lane-name>/' bin/jobs-client.sh; pr l3b
[ "$(git diff --numstat base HEAD -- bin/jobs-client.sh | cut -f1,2)" = $'1\t1' ] || bad "L3 the value edit is not +1/-1"
lint --base base
[ "$RC" = 0 ] && ok "L3 a +1/-1 value edit: rc 0" || bad "L3 value edit rc=$RC: $OUT"
mkr l4 || exit 1
echo c >> bin/lib/jobs/queue.sh; echo '# grow' >> x/bin/jobs-client.sh; pr l4; lint --base base
[ "$RC" = 0 ] && ok "L4 near misses bin/lib/jobs/queue.sh and x/bin/jobs-client.sh grow: rc 0" || bad "L4 rc=$RC: $OUT"
cd "$T" || exit 1

echo "jobs-client-frags.bh-7456-test: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
