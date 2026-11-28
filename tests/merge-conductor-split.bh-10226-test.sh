#!/bin/bash
# tests/merge-conductor-split.bh-10226-test.sh — the merge conductor driver
# bin/merge-conductor.sh is a declared split of config/merge-conductor.d/
# under bin/render-split.sh (BH-10226, slice C2 of #9704). The cut needed a
# new rule: `--cut ... --at <ERE>` starts a fragment at a comment BLOCK start.
#   C1  golden: the render-split print of the driver equals the committed file;
#       --check <it> rc 0; --check over every row rc 0; the registry row
#       (3 fields, mode 755)
#   C2  the fragment set: NNNN-<slug>.txt or README.md only, 20 or more
#       fragments, none over 200 lines; a re-cut with the registry header's
#       exact command gives the same names and bytes (the re-cut port rule)
#   C3  the --at rule on a synthetic file: block start after --min-lines cuts,
#       a 2nd block line, a block before --min-lines, `#!`, `#x`, `echo "# x"`
#       and a blank line do not; an indented `    # x` does; the slug; the
#       default cut is unchanged; --at with --check, --at '' and --at '(' are
#       rc 2 and write nothing
#   C4  --write in a scratch copy keeps the bytes and gives mode 755
#   C5  the merge guard on the real fragments: two branches that each add a
#       fragment merge and --write rc 0 with both lines; a branch that
#       hand-edited the render is refused rc 4 and the edit is kept
#   M1  mutant: a guard that always says yes drops the hand edit (C5 is real)
#   M2  mutant: an --at branch with no `!(prev ~ at)` cuts inside a block (C3
#       is real)
#   C6  tests/split-overlap.bh-9704-test.sh with the conductor SO_* values:
#       two plans that each add one conductor fragment are not deferred
# No network, no gh, no LLM.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

RS=bin/render-split.sh
MC=bin/merge-conductor.sh
MD=config/merge-conductor.d
MREG=catalog/splits.d/bh-10226-merge-conductor.tsv
CUTARGS=(--cut "$MC" --min-lines 60 --at '^ *# ')
CUTLINE="# cut: bin/render-split.sh --cut bin/merge-conductor.sh --min-lines 60 --at '^ *# '"

TOOL="$T/tool"; mkdir -p "$TOOL"
scratch_install_closure "$RS" "$TOOL" >/dev/null || bad "closure install: $RS"
SCRIPT="$TOOL/$RS"
M1="$TOOL/bin/render-split-m1.sh"
sed 's/^rs_guard() {$/rs_guard() { return 0/' "$SCRIPT" > "$M1"
cmp -s "$M1" "$SCRIPT" && bad "M1: the mutant changed nothing"
M2="$TOOL/bin/render-split-m2.sh"
sed 's/ && !(prev ~ at)//' "$SCRIPT" > "$M2"
cmp -s "$M2" "$SCRIPT" && bad "M2: the mutant changed nothing"
rs() { RC=0; OUT=$(bash "${RSX:-$SCRIPT}" "$@" 2>"$T/err") || RC=$?; ERR=$(cat "$T/err"); }

# ============================== C1 golden ==============================
rs --root "$DIR" "$MC"
printf '%s\n' "$OUT" > "$T/print.sh"   # $(...) strips the final newline; the render ends in one
[ "$RC" = 0 ] && cmp -s "$T/print.sh" "$DIR/$MC" && ok \
  || bad "C1: the render-split print of $MC must equal the committed file, rc=$RC err=[$ERR] $(cmp "$T/print.sh" "$DIR/$MC" 2>&1)"
bash "$SCRIPT" --root "$DIR" "$MC" 2>/dev/null | cmp -s - "$DIR/$MC" && ok || bad "C1: print | cmp - $MC must be equal"
rs --root "$DIR" --check "$MC"
[ "$RC" = 0 ] && ok || bad "C1: --check $MC must be rc 0, rc=$RC out=[$OUT] err=[$ERR]"
rs --root "$DIR" --check
[ "$RC" = 0 ] && ok || bad "C1: --check over every row must be rc 0, rc=$RC out=[$OUT] err=[$ERR]"
grep -qxP 'bin/merge-conductor.sh\tconfig/merge-conductor.d/\t755' "$DIR/$MREG" 2>/dev/null && ok \
  || bad "C1: $MREG must hold the 3-field row $MC TAB $MD/ TAB 755"

# scratch <root>: the registry, every fragment dir and every render.
scratch() {
  local G="$1" r d
  scratch_rm "$G"; mkdir -p "$G/catalog"
  cp -r "$DIR/catalog/splits.d" "$G/catalog/"
  while IFS=$'\t' read -r r d _; do
    case "$r" in ''|'#'*) continue ;; esac
    mkdir -p "$G/$(dirname "$r")" "$G/$(dirname "${d%/}")"
    cp -p "$DIR/$r" "$G/$r"; cp -r "$DIR/${d%/}" "$G/${d%/}"
  done < <(cat "$DIR"/catalog/splits.d/*.tsv)
}
G="$T/g"

# ============================== C2 fragment set ==============================
n=0; big=; badname=
for f in "$DIR/$MD"/* "$DIR/$MD"/.[!.]*; do
  [ -e "$f" ] || continue
  b=${f##*/}
  [ "$b" = README.md ] && continue
  if [[ "$b" =~ ^[0-9]{4}-[a-z0-9][a-z0-9-]*\.txt$ ]]; then
    n=$((n + 1))
    [ "$(wc -l < "$f")" -le 200 ] || big="$big $b"
  else
    badname="$badname $b"
  fi
done
[ -z "$badname" ] && ok || bad "C2: $MD/ may hold only NNNN-<slug>.txt and README.md, found [$badname]"
[ "$n" -ge 20 ] && ok || bad "C2: $MD/ must hold 20 or more fragments, got $n"
[ -z "$big" ] && ok || bad "C2: no fragment may be over 200 lines, found [$big]"
grep -qxF "$CUTLINE" "$DIR/$MREG" 2>/dev/null && ok || bad "C2: $MREG must name the exact cut command [$CUTLINE]"
scratch "$G"; rm -f "$G/$MD"/[0-9]*.txt
rs --root "$G" "${CUTARGS[@]}"
[ "$RC" = 0 ] && diff -r "$G/$MD" "$DIR/$MD" >/dev/null && ok \
  || bad "C2: a re-cut must give the committed fragments byte for byte, rc=$RC err=[$ERR] $(diff -rq "$G/$MD" "$DIR/$MD" 2>&1 | head -5)"

# ============================== C3 the --at rule ==============================
# 150 lines. A cut starts at 61 (a 3-line block) and at 140 (indented).
# Line 5: a block before --min-lines. Lines 119-121: a block that reaches
# --min-lines on its 3rd line (cnt 60), which must NOT cut. Lines 125-128: no
# match at all.
c3root() {
  local R="$1" i
  scratch_rm "$R"; mkdir -p "$R/catalog/splits.d" "$R/out"
  printf 'out/s.sh\ts.d/\t644\n' > "$R/catalog/splits.d/s.tsv"
  for i in $(seq 1 150); do
    case "$i" in
      5)   echo '# early' ;;
      61)  echo '  # A HELD PR (BH-1)' ;;
      62)  echo '# more' ;;
      63)  echo '    # more' ;;
      119) echo '# late one' ;;
      120) echo '# late two' ;;
      121) echo '  # late three' ;;
      125) echo '#!/bin/bash' ;;
      126) echo '#x' ;;
      127) echo 'echo "# x"' ;;
      128) echo '' ;;
      140) echo '    # indented' ;;
      *)   echo ": line $i" ;;
    esac
  done > "$R/out/s.sh"
}
cuttable() { (cd "$1/s.d" 2>/dev/null && for f in *.txt; do printf '%s:%s\n' "$f" "$(wc -l < "$f")"; done); }
C3="$T/c3"; c3root "$C3"
rs --root "$C3" --cut out/s.sh --min-lines 60 --at '^ *# '
want=$'0100-head.txt:60\n0200-a-held-pr-bh-1.txt:79\n0300-indented.txt:11'
got=$(cuttable "$C3")
[ "$RC" = 0 ] && [ "$got" = "$want" ] && ok || bad "C3: the --at cut points must be [$want], got [$got] rc=$RC err=[$ERR]"
cat "$C3"/s.d/*.txt | cmp -s - "$C3/out/s.sh" && ok || bad "C3: the --at fragments must render back byte for byte"
# M2: no prev check -> line 121 cuts too.
c3root "$C3"
RSX="$M2" rs --root "$C3" --cut out/s.sh --min-lines 60 --at '^ *# '
got=$(cuttable "$C3")
[ "$got" != "$want" ] && ok || bad "M2: a cut with no prev check must change C3's cut table (else C3 proves nothing), got [$got]"
# The default rule (no --at) is unchanged: no `# >>> ` line, one fragment.
c3root "$C3"
rs --root "$C3" --cut out/s.sh --min-lines 60
got=$(cuttable "$C3")
[ "$RC" = 0 ] && [ "$got" = "0100-head.txt:150" ] && ok || bad "C3: the default cut of the same file must give one fragment, got [$got] rc=$RC"
# Refusals: rc 2, nothing written.
c3r() { # c3r <label> <args...>
  local label="$1"; shift
  c3root "$C3"
  rs --root "$C3" "$@"
  local k; k=$(find "$C3" -name '*.txt' 2>/dev/null | wc -l)
  [ "$RC" = 2 ] && [ "$k" = 0 ] && ok || bad "C3: $label must be rc 2 with nothing written, rc=$RC parts=$k err=[$ERR]"
}
c3r "--at with --check" --check --at '^ *# '
c3r "--at with --write" --write --at '^ *# '
c3r "--at with print" out/s.sh --at '^ *# '
c3r "--at ''" --cut out/s.sh --min-lines 60 --at ''
c3r "--at with no value" --cut out/s.sh --min-lines 60 --at
c3r "--at '('" --cut out/s.sh --min-lines 60 --at '('

# ============================== C4 write ==============================
scratch "$G"; chmod 644 "$G/$MC"
rs --root "$G" --write "$MC"
[ "$RC" = 0 ] && cmp -s "$G/$MC" "$DIR/$MC" && ok || bad "C4: --write must keep the bytes of $MC, rc=$RC err=[$ERR]"
[ "$(stat -c %a "$G/$MC")" = 755 ] && ok || bad "C4: --write must give $MC mode 755, got $(stat -c %a "$G/$MC")"

# ============================== C5 the merge guard ==============================
g() { git -C "$R" -c user.email=t@fixture.test -c user.name=t -c commit.gpgsign=false "$@"; }
# c5 <root> <hand 0|1> -> a: adds 2950 + --write; b: adds 3950 + --write, or
# (hand=1) appends `: HAND` to the render with no fragment. Then a merges b
# and takes b's render on a conflict; the merge is left in progress.
c5() {
  R="$1"; scratch "$R"; git -C "$R" init -q -b main; g add -A; g commit -qm base
  g checkout -q -b a
  printf '  : bh1_a\n' > "$R/$MD/2950-bh-1-a.txt"
  bash "$SCRIPT" --root "$R" --write "$MC" || bad "C5 fixture: --write on branch a"
  g add -A; g commit -qm a
  g checkout -q -b b main
  if [ "$2" = 1 ]; then
    printf ': HAND\n' >> "$R/$MC"
  else
    printf '  : bh2_b\n' > "$R/$MD/3950-bh-2-b.txt"
    bash "$SCRIPT" --root "$R" --write "$MC" || bad "C5 fixture: --write on branch b"
  fi
  g add -A; g commit -qm b
  g checkout -q a
  g merge -q --no-edit --no-commit b >/dev/null 2>&1 || :
  g checkout -q --theirs -- "$MC" 2>/dev/null || :
  g add -- "$MC"
  git -C "$R" rev-parse -q --verify MERGE_HEAD >/dev/null || bad "C5 fixture: the merge must be in progress"
}
R5="$T/c5"
c5 "$R5" 0
rs --root "$R5" --write "$MC"
[ "$RC" = 0 ] && grep -qxF '  : bh1_a' "$R5/$MC" && grep -qxF '  : bh2_b' "$R5/$MC" && ok \
  || bad "C5: two fragment-adding branches merged: --write must be rc 0 and keep both lines, rc=$RC err=[$ERR]"
rs --root "$R5" --check "$MC"
[ "$RC" = 0 ] && ok || bad "C5: --check after the merge write must be rc 0, rc=$RC out=[$OUT] err=[$ERR]"
bash -n "$R5/$MC" 2>"$T/err" && ok || bad "C5: the merged render must pass bash -n, err=[$(cat "$T/err")]"
c5 "$R5" 1
rs --root "$R5" --write "$MC"
[ "$RC" = 4 ] && grep -qxF ': HAND' "$R5/$MC" && grep -qF 'edited by hand' <<<"$ERR" && ok \
  || bad "C5: a hand-edited render side must be refused rc 4 and keep ': HAND', rc=$RC err=[$ERR]"
c5 "$R5" 1
RSX="$M1" rs --root "$R5" --write "$MC"
grep -qxF ': HAND' "$R5/$MC" && bad "M1: a guard that always says yes must drop ': HAND' (else C5 proves nothing), rc=$RC" || ok

# ============================== C6 not deferred ==============================
RC=0
C6OUT=$(env SO_REG="$MREG" SO_FDIR="$MD" SO_RENDER="$MC" SO_MODE=755 SO_EXT=txt SO_OLD=0100-head \
          bash "$DIR/tests/split-overlap.bh-9704-test.sh" 2>&1) || RC=$?
[ "$RC" = 0 ] && ok || bad "C6: split-overlap for the merge conductor must pass, rc=$RC out=[$C6OUT]"

echo "merge-conductor-split.bh-10226: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
