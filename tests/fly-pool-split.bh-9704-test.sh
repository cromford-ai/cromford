#!/bin/bash
# tests/fly-pool-split.bh-9704-test.sh — the Fly pool script bin/fly-pool.sh is
# a declared split of config/fly-pool.d/ under bin/render-split.sh (BH-9704 C1).
# The registry row takes a 4th field, the fragment extension (txt or sh).
#   F1  golden: the render-split print of bin/fly-pool.sh equals the committed
#       file; --check <it> rc 0; bin/fly-pool-build.sh --check rc 0 (the two
#       renderers agree)
#   F2  --write in a scratch copy keeps the bytes and gives mode 755
#   F3  the extension is per row: a .txt fragment in config/fly-pool.d/ and a
#       .sh fragment in config/rb-plan.d/ are each refused rc 3
#   F4  registry rows: 4th field py / SH / .sh and a 5-field row are rc 2; a
#       3-field row and a 4-field txt row load; a trailing tab reads as 3 fields
#   F5  a new .sh fragment: --check rc 1, --write rc 0, --check rc 0, the block
#       is in the render, and bin/fly-pool-build.sh --check agrees
#   F6  the merge guard on the real fly-pool fragments: two branches that each
#       add a fragment merge and --write rc 0 with both blocks; a branch that
#       hand-edited the render is refused rc 4 and the edit is kept
#   M1  mutant: a guard that always says yes drops the hand edit (F6 is real)
#   F7  tests/split-overlap.bh-9704-test.sh with the fly-pool SO_* values:
#       two plans that each add one fly-pool fragment are not deferred
# No network, no gh, no LLM.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

RS=bin/render-split.sh
FP=bin/fly-pool.sh
FD=config/fly-pool.d
FREG=catalog/splits.d/bh-9704-fly-pool.tsv
PLAN=bin/lib/rb/plan.sh
PD=config/rb-plan.d

TOOL="$T/tool"; mkdir -p "$TOOL"
scratch_install_closure "$RS" "$TOOL" >/dev/null || bad "closure install: $RS"
SCRIPT="$TOOL/$RS"
M1="$TOOL/bin/render-split-m1.sh"
sed 's/^rs_guard() {$/rs_guard() { return 0/' "$SCRIPT" > "$M1"
cmp -s "$M1" "$SCRIPT" && bad "M1: the mutant changed nothing"
rs() { RC=0; OUT=$(bash "${RSX:-$SCRIPT}" "$@" 2>"$T/err") || RC=$?; ERR=$(cat "$T/err"); }

# ============================== F1 golden ==============================
rs --root "$DIR" "$FP"
printf '%s\n' "$OUT" > "$T/print.sh"   # $(...) strips the final newline; the render ends in one
[ "$RC" = 0 ] && cmp -s "$T/print.sh" "$DIR/$FP" && ok \
  || bad "F1: the render-split print of $FP must equal the committed file, rc=$RC err=[$ERR] $(cmp "$T/print.sh" "$DIR/$FP" 2>&1)"
bash "$SCRIPT" --root "$DIR" "$FP" 2>/dev/null | cmp -s - "$DIR/$FP" && ok || bad "F1: print | cmp - $FP must be equal"
rs --root "$DIR" --check "$FP"
[ "$RC" = 0 ] && ok || bad "F1: --check $FP must be rc 0, rc=$RC out=[$OUT] err=[$ERR]"
rs --root "$DIR" --check
[ "$RC" = 0 ] && ok || bad "F1: --check over every row must be rc 0, rc=$RC out=[$OUT] err=[$ERR]"
RC=0; bash "$DIR/bin/fly-pool-build.sh" --check >/dev/null 2>"$T/err" || RC=$?
[ "$RC" = 0 ] && ok || bad "F1: bin/fly-pool-build.sh --check must be rc 0 (both renderers agree), rc=$RC err=[$(cat "$T/err")]"
grep -qxP 'bin/fly-pool.sh\tconfig/fly-pool.d/\t755\tsh' "$DIR/$FREG" 2>/dev/null && ok \
  || bad "F1: $FREG must hold the row $FP TAB $FD/ TAB 755 TAB sh"

# scratch <root>: the registry, both fragment dirs, both renders, and the
# fly-pool builder (its --check reads the parent of its own dir).
scratch() {
  local G="$1"
  scratch_rm "$G"; mkdir -p "$G/catalog" "$G/config" "$G/bin/lib/rb"
  cp -r "$DIR/catalog/splits.d" "$G/catalog/"
  cp -r "$DIR/$FD" "$DIR/$PD" "$G/config/"
  cp -p "$DIR/$FP" "$G/$FP"; cp -p "$DIR/$PLAN" "$G/$PLAN"
  cp -p "$DIR/bin/fly-pool-build.sh" "$G/bin/fly-pool-build.sh"
}
G="$T/g"

# ============================== F2 write ==============================
scratch "$G"; chmod 644 "$G/$FP"
rs --root "$G" --write "$FP"
[ "$RC" = 0 ] && cmp -s "$G/$FP" "$DIR/$FP" && ok || bad "F2: --write must keep the bytes of $FP, rc=$RC err=[$ERR]"
[ "$(stat -c %a "$G/$FP")" = 755 ] && ok || bad "F2: --write must give $FP mode 755, got $(stat -c %a "$G/$FP")"

# ============================== F3 extension rule ==============================
scratch "$G"; printf 'echo x\n' > "$G/$FD/1950-bh-1-x.txt"
rs --root "$G" --check "$FP"
[ "$RC" = 3 ] && grep -qF '1950-bh-1-x.txt' <<<"$ERR" && grep -qF '.sh' <<<"$ERR" && ok \
  || bad "F3: a .txt fragment in $FD/ must be refused rc 3 naming the file and .sh, rc=$RC err=[$ERR]"
scratch "$G"; printf 'echo x\n' > "$G/$PD/1950-bh-1-x.sh"
rs --root "$G" --check "$PLAN"
[ "$RC" = 3 ] && grep -qF '1950-bh-1-x.sh' <<<"$ERR" && ok \
  || bad "F3: a .sh fragment in $PD/ must be refused rc 3 (rb-plan stays txt), rc=$RC err=[$ERR]"
for n in 3950-Demo.sh 395-x.sh .3950-x.sh; do
  scratch "$G"; printf 'echo x\n' > "$G/$FD/$n"
  rs --root "$G" --check "$FP"
  [ "$RC" = 3 ] && ok || bad "F3: the name $n in $FD/ must be refused rc 3, rc=$RC err=[$ERR]"
done

# ============================== F4 registry ==============================
f4() { # f4 <label> <want rc> <row text> [render to check]
  scratch "$G"; printf '%b' "$3" > "$G/$FREG"
  rs --root "$G" --check ${4:+"$4"}
  [ "$RC" = "$2" ] && ok || bad "F4: $1 must be rc $2, rc=$RC err=[$ERR]"
}
f4 "a 4th field py" 2 'bin/fly-pool.sh\tconfig/fly-pool.d/\t755\tpy\n'
grep -qF 'bad fragment extension' <<<"$ERR" && ok || bad "F4: a 4th field py must say 'bad fragment extension', err=[$ERR]"
f4 "a 4th field SH" 2 'bin/fly-pool.sh\tconfig/fly-pool.d/\t755\tSH\n'
f4 "a 4th field .sh" 2 'bin/fly-pool.sh\tconfig/fly-pool.d/\t755\t.sh\n'
f4 "a row with 5 fields" 2 'bin/fly-pool.sh\tconfig/fly-pool.d/\t755\tsh\tx\n'
f4 "the 4-field sh row" 0 'bin/fly-pool.sh\tconfig/fly-pool.d/\t755\tsh\n'
f4 "fly-pool as a 3-field (txt) row" 3 'bin/fly-pool.sh\tconfig/fly-pool.d/\t755\n' "$FP"
f4 "a trailing tab after the mode (reads as txt)" 3 'bin/fly-pool.sh\tconfig/fly-pool.d/\t755\t\n' "$FP"
scratch "$G"; printf '%b' 'bin/lib/rb/plan.sh\tconfig/rb-plan.d/\t644\ttxt\n' > "$G/catalog/splits.d/bh-9704-rb-plan.tsv"
rs --root "$G" --check
[ "$RC" = 0 ] && ok || bad "F4: a 4-field txt row must load like the 3-field row, rc=$RC err=[$ERR]"
scratch "$G"; rs --root "$G" --check "$PLAN"
[ "$RC" = 0 ] && ok || bad "F4: the shipped 3-field rb-plan row must still load, rc=$RC err=[$ERR]"

# ============================== F5 a new entry ==============================
scratch "$G"; printf '# >>> demo\ndemo_fn() { :; }\n' > "$G/$FD/3950-bh-1-demo.sh"
rs --root "$G" --check "$FP"
[ "$RC" = 1 ] && grep -qxF "DRIFT $FP" <<<"$OUT" && ok || bad "F5: a new fragment must be DRIFT rc 1 before --write, rc=$RC out=[$OUT] err=[$ERR]"
rs --root "$G" --write "$FP"
[ "$RC" = 0 ] && ok || bad "F5: --write must be rc 0, rc=$RC err=[$ERR]"
rs --root "$G" --check "$FP"
[ "$RC" = 0 ] && grep -qxF 'demo_fn() { :; }' "$G/$FP" && ok || bad "F5: after --write the render must hold demo_fn and --check be rc 0, rc=$RC"
RC=0; bash "$G/bin/fly-pool-build.sh" --check >/dev/null 2>"$T/err" || RC=$?
[ "$RC" = 0 ] && ok || bad "F5: bin/fly-pool-build.sh --check must agree with the render-split write, rc=$RC err=[$(cat "$T/err")]"

# ============================== F6 the merge guard ==============================
g() { git -C "$R" -c user.email=t@fixture.test -c user.name=t -c commit.gpgsign=false "$@"; }
# f6 <root> <hand 0|1> -> a: adds 3950 + --write; b: adds 3960 + --write, or
# (hand=1) appends `echo HAND` to the render with no fragment. Then a merges b
# and takes b's render on a conflict; the merge is left in progress.
f6() {
  R="$1"; scratch "$R"; git -C "$R" init -q -b main; g add -A; g commit -qm base
  g checkout -q -b a
  printf '# >>> a\na_fn() { :; }\n' > "$R/$FD/3950-bh-1-a.sh"
  bash "$SCRIPT" --root "$R" --write "$FP" || bad "F6 fixture: --write on branch a"
  g add -A; g commit -qm a
  g checkout -q -b b main
  if [ "$2" = 1 ]; then
    printf 'echo HAND\n' >> "$R/$FP"
  else
    printf '# >>> b\nb_fn() { :; }\n' > "$R/$FD/3960-bh-2-b.sh"
    bash "$SCRIPT" --root "$R" --write "$FP" || bad "F6 fixture: --write on branch b"
  fi
  g add -A; g commit -qm b
  g checkout -q a
  g merge -q --no-edit --no-commit b >/dev/null 2>&1 || :
  g checkout -q --theirs -- "$FP" 2>/dev/null || :
  g add -- "$FP"
  git -C "$R" rev-parse -q --verify MERGE_HEAD >/dev/null || bad "F6 fixture: the merge must be in progress"
}
R6="$T/f6"
f6 "$R6" 0
rs --root "$R6" --write "$FP"
[ "$RC" = 0 ] && grep -qxF 'a_fn() { :; }' "$R6/$FP" && grep -qxF 'b_fn() { :; }' "$R6/$FP" && ok \
  || bad "F6: two fragment-adding branches merged: --write must be rc 0 and keep both blocks, rc=$RC err=[$ERR]"
f6 "$R6" 1
rs --root "$R6" --write "$FP"
[ "$RC" = 4 ] && grep -qxF 'echo HAND' "$R6/$FP" && grep -qF 'edited by hand' <<<"$ERR" && ok \
  || bad "F6: a hand-edited render side must be refused rc 4 and keep 'echo HAND', rc=$RC err=[$ERR]"
f6 "$R6" 1
RSX="$M1" rs --root "$R6" --write "$FP"
grep -qxF 'echo HAND' "$R6/$FP" && bad "M1: a guard that always says yes must drop 'echo HAND' (else F6 proves nothing), rc=$RC" || ok

# ============================== F7 not deferred ==============================
RC=0
F7OUT=$(env SO_REG="$FREG" SO_FDIR="$FD" SO_RENDER="$FP" SO_MODE=755 SO_EXT=sh \
          bash "$DIR/tests/split-overlap.bh-9704-test.sh" 2>&1) || RC=$?
[ "$RC" = 0 ] && ok || bad "F7: split-overlap for fly-pool must pass, rc=$RC out=[$F7OUT]"

echo "fly-pool-split.bh-9704: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
