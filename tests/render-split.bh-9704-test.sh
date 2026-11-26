#!/bin/bash
# tests/render-split.bh-9704-test.sh — bin/render-split.sh renders a committed
# file from a fragment folder byte for byte, and the PLAN-stage lib
# bin/lib/rb/plan.sh is such a render of config/rb-plan.d/ (BH-9704).
#   R1      golden: the real checkout's --check is rc 0 and the print equals
#           the committed bin/lib/rb/plan.sh; --write in a scratch copy keeps
#           the bytes and mode 644
#   R2      one changed byte in one fragment: --check rc 1, DRIFT
#   R3      bad fragment names / dotfile / subdir / symlink: rc 3
#   R4      CR byte, empty fragment, no final newline, merge marker: rc 3
#   R5      bad registry rows: rc 2
#   R6      --write on a stale render: rc 0, bytes and mode (644 and 755)
#   R7      --cut: cut points, round trip, marker heads
#   R8      --cut near misses never start a fragment
#   R9      --cut refusals: rc 2, nothing written
#   R10     the CLAUDE.md union command carries bin/render-split.sh --check
#   R11     the Generated files table declares the render as committed, and
#           only render-split rows follow it
#   R12     catalog/list-files.tsv row + bin/list-file-lint.sh on a scratch diff
#   R13     every name in config/rb-plan.d/ has an extension the share mirror
#           reads as text (TEXT_EXT in bin/share/mapping.py); r9's .part did not
#   M1-M3   mutants: no C sort, a dropped last fragment, --cut on every marker
#   M5      mutant: --cut writes .part -> R7 and R13 red (the mutant moves the
#           default fragment extension to part, BH-9704 C1)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

RS=bin/render-split.sh
REG=catalog/splits.d/bh-9704-rb-plan.tsv
FDIR=config/rb-plan.d
RENDER=bin/lib/rb/plan.sh

# --- the tool, installed once outside any fixture root -------------------
TOOL="$T/tool"
mkdir -p "$TOOL"
scratch_install_closure "$RS" "$TOOL" >/dev/null || bad "closure install: $RS"
[ -f "$TOOL/bin/lib/render-fragments.sh" ] && ok || bad "closure: $RS must source bin/lib/render-fragments.sh"
rs() { RC=0; OUT=$(bash "${RSX:-$TOOL/$RS}" "$@" 2>"$T/err"); RC=$?; ERR=$(cat "$T/err"); }

# fixture <root> [mode]: a registry row out/r.sh -> f.d/ and three fragments.
fixture() {
  local R="$1" mode="${2:-644}"
  scratch_rm "$R"; mkdir -p "$R/catalog/splits.d" "$R/f.d" "$R/out"
  printf '# fixture\nout/r.sh\tf.d/\t%s\n' "$mode" > "$R/catalog/splits.d/x.tsv"
  printf 'echo head\n' > "$R/f.d/0100-head.txt"
  printf '# >>> one\necho one\n' > "$R/f.d/0200-one.txt"
  printf '# >>> two\necho two\n' > "$R/f.d/0300-two.txt"
  printf '# readme, never rendered\n' > "$R/f.d/README.md"
  cat "$R/f.d/0100-head.txt" "$R/f.d/0200-one.txt" "$R/f.d/0300-two.txt" > "$R/out/r.sh"
}

# ============================== R1 golden ==============================
rs --root "$DIR" --check
[ "$RC" = 0 ] && ok || bad "R1: --check on the real checkout must be rc 0, rc=$RC out=[$OUT] err=[$ERR]"
bash "$TOOL/$RS" --root "$DIR" "$RENDER" > "$T/golden.sh" 2>"$T/err"; rc=$?
git -C "$DIR" show "HEAD:$RENDER" > "$T/head.sh"
[ "$rc" = 0 ] && cmp -s "$T/golden.sh" "$T/head.sh" && ok \
  || bad "R1: the print of $RENDER must equal git show HEAD:$RENDER byte for byte (rc=$rc, $(cmp "$T/golden.sh" "$T/head.sh" 2>&1))"
cmp -s "$T/golden.sh" "$DIR/$RENDER" && ok || bad "R1: the print must equal the working-tree $RENDER"
grep -qxF "$RENDER	$FDIR/	644" "$DIR/$REG" && ok || bad "R1: $REG must hold the row $RENDER TAB $FDIR/ TAB 644"
n=0; for f in "$DIR/$FDIR"/*.txt; do [ -f "$f" ] && n=$((n + 1)); done
[ "$n" = 24 ] && ok || bad "R1: $FDIR/ must hold 24 fragments, has $n"
G="$T/golden"
mkdir -p "$G/catalog/splits.d" "$G/bin/lib/rb" "$G/config"
cp -r "$DIR/$FDIR" "$G/config/"
cp "$DIR/$REG" "$G/$REG"
printf 'stale\n' > "$G/$RENDER"; chmod 600 "$G/$RENDER"
rs --root "$G" --write
[ "$RC" = 0 ] && cmp -s "$G/$RENDER" "$T/head.sh" && ok || bad "R1: --write of the real fragments must reproduce $RENDER, rc=$RC err=[$ERR]"
[ "$(stat -c %a "$G/$RENDER")" = 644 ] && ok || bad "R1: --write must give $RENDER mode 644, got $(stat -c %a "$G/$RENDER")"

# ============================== R2 drift ==============================
R="$T/r2"; fixture "$R"
rs --root "$R" --check
[ "$RC" = 0 ] && ok || bad "R2: a clean fixture must check rc 0, rc=$RC err=[$ERR]"
printf '# >>> one\necho ONE\n' > "$R/f.d/0200-one.txt"
rs --root "$R" --check
[ "$RC" = 1 ] && grep -qxF 'DRIFT out/r.sh' <<<"$OUT" && ok || bad "R2: one changed byte must be DRIFT rc 1, rc=$RC out=[$OUT]"
grep -q 'fix: edit f.d/ and run bin/render-split.sh --write' <<<"$OUT" && ok || bad "R2: drift must name the fix, out=[$OUT]"
fixture "$R"; rm -f "$R/out/r.sh"
rs --root "$R" --check
[ "$RC" = 1 ] && ok || bad "R2: a missing committed render is drift rc 1, rc=$RC"
# the env locale never changes the order (M1's real-code half)
locfix() { # C order puts 1300-a-c before 1300-ab; en_US (punctuation ignored) puts it after
  fixture "$R"
  printf '# ab\n' > "$R/f.d/1300-ab.txt"; printf '# a-c\n' > "$R/f.d/1300-a-c.txt"
  cat "$R/f.d/0100-head.txt" "$R/f.d/0200-one.txt" "$R/f.d/0300-two.txt" "$R/f.d/1300-a-c.txt" "$R/f.d/1300-ab.txt" > "$R/out/r.sh"
}
locfix
HAVE_EN=0; locale -a 2>/dev/null | grep -qix 'en_US.utf8' && HAVE_EN=1
RC=0; OUT=$(env LC_ALL=en_US.utf8 bash "$TOOL/$RS" --root "$R" --check 2>&1) || RC=$?
[ "$RC" = 0 ] && ok || bad "R2: the C order must hold under any env locale, rc=$RC out=[$OUT]"

# ============================== R3 names ==============================
for bad_name in 12-x.txt .hidden 1300-x.sh 1300-X.txt .1300-x.txt 1300-x.part; do
  fixture "$R"; printf 'x\n' > "$R/f.d/$bad_name"
  rs --root "$R" --check
  [ "$RC" = 3 ] && grep -qF "$bad_name" <<<"$ERR" && ok || bad "R3: a file named $bad_name must refuse the set (rc 3), rc=$RC err=[$ERR]"
done
fixture "$R"; mkdir -p "$R/f.d/1400-sub.txt"
rs --root "$R" --check
[ "$RC" = 3 ] && ok || bad "R3: a subdir must refuse the set, rc=$RC err=[$ERR]"
fixture "$R"; ln -s 0100-head.txt "$R/f.d/1400-link.txt"
rs --root "$R" --check
[ "$RC" = 3 ] && ok || bad "R3: a symlink must refuse the set, rc=$RC err=[$ERR]"
fixture "$R"
rs --root "$R" out/r.sh
grep -q readme <<<"$OUT" && bad "R3: README.md must never enter the render" || ok

# ============================== R4 content ==============================
r4() { # r4 <label> <printf args for 0200-one.txt>
  local label="$1"; shift
  fixture "$R"; printf "$@" > "$R/f.d/0200-one.txt"
  rs --root "$R" --check
  [ "$RC" = 3 ] && grep -qF 'f.d/0200-one.txt' <<<"$ERR" && ok || bad "R4: $label must be rc 3 naming the file, rc=$RC err=[$ERR]"
}
r4 "a CR byte" '# >>> one\r\necho one\n'
r4 "an empty fragment" ''
r4 "no final newline" '# >>> one\necho one'
r4 "a merge marker" '<<<<<<< HEAD\necho one\n'
r4 "a closing merge marker" 'echo one\n>>>>>>> main\n'
fixture "$R"; printf 'if true; then\n' > "$R/f.d/0200-one.txt"
rs --root "$R" --check
[ "$RC" = 3 ] && ok || bad "R4: a .sh render that fails bash -n must be rc 3, rc=$RC err=[$ERR]"
fixture "$R"; rm -f "$R"/f.d/*.txt
rs --root "$R" --check
[ "$RC" = 2 ] && ok || bad "R4: a dir with only README.md must be rc 2, rc=$RC err=[$ERR]"

# ============================== R5 registry ==============================
r5() { # r5 <label> <row text>
  fixture "$R"; printf '%b' "$2" > "$R/catalog/splits.d/x.tsv"
  rs --root "$R" --check
  [ "$RC" = 2 ] && ok || bad "R5: $1 must be rc 2, rc=$RC err=[$ERR]"
}
r5 "a row with 2 fields" 'out/r.sh\tf.d/\n'
r5 "a row with 4 fields" 'out/r.sh\tf.d/\t644\textra\n'
r5 "a .. render path" '../r.sh\tf.d/\t644\n'
r5 "a .. dir" 'out/r.sh\tx/../f.d/\t644\n'
r5 "an absolute path" '/tmp/r.sh\tf.d/\t644\n'
r5 "a dir with no slash" 'out/r.sh\tf.d\t644\n'
r5 "a bad mode" 'out/r.sh\tf.d/\t64\n'
r5 "a non-octal mode" 'out/r.sh\tf.d/\t689\n'
r5 "a duplicate render" 'out/r.sh\tf.d/\t644\nout/r.sh\tf.d/\t644\n'
fixture "$R"
rs --root "$R" --check out/none.sh
[ "$RC" = 2 ] && ok || bad "R5: a named render with no row must be rc 2, rc=$RC"
fixture "$R"; rm -f "$R/catalog/splits.d/x.tsv"
rs --root "$R" --check
[ "$RC" = 2 ] && ok || bad "R5: an empty registry must be rc 2, rc=$RC"

# ============================== R6 write ==============================
for mode in 644 755; do
  fixture "$R" "$mode"; printf 'stale\n' > "$R/out/r.sh"; chmod 600 "$R/out/r.sh"
  rs --root "$R" --write
  cat "$R/f.d/0100-head.txt" "$R/f.d/0200-one.txt" "$R/f.d/0300-two.txt" > "$T/want"
  [ "$RC" = 0 ] && cmp -s "$R/out/r.sh" "$T/want" && ok || bad "R6: --write ($mode) must render the fragments, rc=$RC err=[$ERR]"
  [ "$(stat -c %a "$R/out/r.sh")" = "$mode" ] && ok || bad "R6: --write must give mode $mode, got $(stat -c %a "$R/out/r.sh")"
done
fixture "$R"; printf 'stale\n' > "$R/out/r.sh"; printf '\r\n' > "$R/f.d/0200-one.txt"
rs --root "$R" --write
[ "$RC" = 3 ] && [ "$(cat "$R/out/r.sh")" = stale ] && ok || bad "R6: a refused set must write nothing, rc=$RC"

# ============================== R7 cut ==============================
# cutroot <root> <min> -> a 300-line out/c.sh with 6 markers, registry row, no fragments.
cutroot() {
  local R="$1" i
  scratch_rm "$R"; mkdir -p "$R/catalog/splits.d" "$R/out"
  printf 'out/c.sh\tc.d/\t644\n' > "$R/catalog/splits.d/c.tsv"
  for i in $(seq 1 300); do
    case "$i" in
      20)  echo '# >>> early one' ;;
      50)  echo '# >>> early two' ;;
      100) echo '# >>> Alpha Block (BH-1)' ;;
      130) echo '# >>> too soon' ;;
      200) echo '# >>> a very long marker name that runs well past forty characters' ;;
      290) echo '# >>> !!!' ;;
      *)   echo ": line $i" ;;
    esac
  done > "$R/out/c.sh"
}
R7="$T/r7"; cutroot "$R7"
rs --root "$R7" --cut out/c.sh --min-lines 60
[ "$RC" = 0 ] && ok || bad "R7: --cut must be rc 0, rc=$RC err=[$ERR]"
got=$(cd "$R7/c.d" 2>/dev/null && for f in *.txt; do printf '%s:%s\n' "$f" "$(wc -l < "$f")"; done)
want=$'0100-head.txt:99\n0200-alpha-block-bh-1.txt:100\n0300-a-very-long-marker-name-that-runs-well-p.txt:90\n0400-block.txt:11'
[ "$got" = "$want" ] && ok || bad "R7: the cut points must be [$want], got [$got]"
cat "$R7"/c.d/*.txt | cmp -s - "$R7/out/c.sh" && ok || bad "R7: the fragments must render back byte for byte"
for f in "$R7"/c.d/*.txt; do
  case "${f##*/}" in 0100-head.txt) continue ;; esac
  head -n1 "$f" | grep -q '^# >>> ' && ok || bad "R7: ${f##*/} must start with a # >>> line"
done
rs --root "$R7" --check
[ "$RC" = 0 ] && ok || bad "R7: --check after --cut must be rc 0, rc=$RC err=[$ERR]"

# ============================== R8 near misses ==============================
R8="$T/r8"; scratch_rm "$R8"; mkdir -p "$R8/catalog/splits.d" "$R8/out"
printf 'out/n.sh\tn.d/\t644\n' > "$R8/catalog/splits.d/n.tsv"
printf ': a\n # >>> x\n#>>> x\n# >>>x\n# <<< x\necho "# >>> x"\n: z\n' > "$R8/out/n.sh"
rs --root "$R8" --cut out/n.sh --min-lines 1
n=$(find "$R8/n.d" -name '*.txt' | wc -l)
[ "$RC" = 0 ] && [ "$n" = 1 ] && ok || bad "R8: near-miss markers must not start a fragment, rc=$RC fragments=$n"
scratch_rm "$R8/n.d"
printf ': a\n# >>> real\n: z\n' > "$R8/out/n.sh"
rs --root "$R8" --cut out/n.sh --min-lines 1
[ -f "$R8/n.d/0200-real.txt" ] && ok || bad "R8: a real marker must start a fragment (the near-miss case proves something)"

# ============================== R9 refusals ==============================
r9() { # r9 <label> <args...>
  local label="$1"; shift
  cutroot "$R7"
  rs --root "$R7" "$@"
  local n; n=$(find "$R7" -name '*.txt' 2>/dev/null | wc -l)
  [ "$RC" = 2 ] && [ "$n" = 0 ] && ok || bad "R9: $label must be rc 2 with nothing written, rc=$RC parts=$n err=[$ERR]"
}
r9 "a --cut with no --min-lines" --cut out/c.sh
r9 "--min-lines 0" --cut out/c.sh --min-lines 0
r9 "--min-lines x" --cut out/c.sh --min-lines x
r9 "a --cut of a path with no row" --cut out/other.sh --min-lines 60
cutroot "$R7"; mkdir -p "$R7/c.d"; printf 'x\n' > "$R7/c.d/0100-old.txt"
rs --root "$R7" --cut out/c.sh --min-lines 60
n=$(find "$R7/c.d" -name '*.txt' | wc -l)
[ "$RC" = 2 ] && [ "$n" = 1 ] && ok || bad "R9: a dir that already holds a .txt must be rc 2 and untouched, rc=$RC parts=$n"
# a cut that cannot reproduce the file (no final newline) is rc 1 and keeps nothing
cutroot "$R7"; printf ': no newline' >> "$R7/out/c.sh"
rs --root "$R7" --cut out/c.sh --min-lines 60
n=$(find "$R7" -name '*.txt' 2>/dev/null | wc -l)
[ "$RC" = 1 ] && [ "$n" = 0 ] && ok || bad "R9: a cut that does not reproduce must be rc 1 and keep nothing, rc=$RC parts=$n"

# ============================== R10 union command ==============================
# Read the block the way bin/batch-resolve.sh's verify_cmd reads it.
UNION=$(awk '
  /^##+[ \t]*[Vv]erification [Cc]ontract/ { sec=1; next }
  sec && /^## / { exit }
  sec && /^```/ { fence = 1 - fence; next }
  sec && fence && NF && $0 !~ /^[ \t]*#/ { print; exit }' "$DIR/CLAUDE.md")
grep -qF 'HARNESS_TEST_SANDBOX=1 bin/render-split.sh --check' <<<"$UNION" && ok \
  || bad "R10: the CLAUDE.md union command must run bin/render-split.sh --check"

# ============================== R11 generated table ==============================
TR="$T/tr"; mkdir -p "$TR/docs/verification-map/index"
git -C "$TR" init -q -b main
cp "$DIR/docs/verification-map/index/tail.md" "$TR/docs/verification-map/index/tail.md"
git -C "$TR" add -A && git -C "$TR" -c user.email=t@fixture.test -c user.name=t -c commit.gpgsign=false commit -qm t
GT=$(bash -c '. "$1" || exit 90; gen_table_paths "$2" HEAD' _ "$DIR/bin/lib/generated-table.sh" "$TR")
NC=$(bash -c '. "$1" || exit 90; gen_nocommit_paths "$2" HEAD' _ "$DIR/bin/lib/generated-table.sh" "$TR")
grep -qxF "$RENDER" <<<"$GT" && ok || bad "R11: the Generated files table must declare $RENDER"
grep -qxF "$RENDER" <<<"$NC" && bad "R11: $RENDER must be marked committed (it is in the no-commit list)" || ok
# The render-split rows are LAST (BH-9704 C1 added bin/fly-pool.sh after this
# one, same command): no other row's command may follow this row, so every
# other command runs before render-split's.
after=$(grep '^| `' "$DIR/docs/verification-map/index/tail.md" | sed -n "/^| \`${RENDER//\//\\/}\` |/,\$p")
[ "$(head -n1 <<<"$after")" = "| \`$RENDER\` | \`$RS --write\` | committed |" ] && ok || bad "R11: the table must hold the committed $RENDER row, got [$(head -n1 <<<"$after")]"
other=$(grep -vF "| \`$RS --write\` | committed |" <<<"$after" || :)
[ -z "$other" ] && ok || bad "R11: only render-split rows may follow the $RENDER row, got [$other]"

# ============================== R12 list-file lint ==============================
grep -qxF "$RENDER	rendered $FDIR/	committed render of bin/render-split.sh (BH-9704); a new block is a new fragment" "$DIR/catalog/list-files.tsv" \
  && ok || bad "R12: catalog/list-files.tsv must hold the rendered $FDIR/ row"
L="$T/lint"; mkdir -p "$L/catalog" "$L/bin/lib/rb" "$L/$FDIR"
git -C "$L" init -q -b main
gl() { git -C "$L" -c user.email=t@fixture.test -c user.name=t -c commit.gpgsign=false "$@"; }
cp "$DIR/catalog/list-files.tsv" "$L/catalog/list-files.tsv"
printf 'a\n' > "$L/$RENDER"; printf 'a\n' > "$L/$FDIR/0100-head.txt"
gl add -A; gl commit -qm base
gl checkout -q -b render-only
printf 'b\n' >> "$L/$RENDER"; gl commit -qam render-only
RC=0; OUT=$(cd "$L" && bash "$DIR/bin/list-file-lint.sh" --base main 2>&1) || RC=$?
[ "$RC" != 0 ] && ok || bad "R12: a render-only append must be refused by list-file-lint, rc=$RC out=[$OUT]"
gl checkout -q main; gl checkout -q -b with-fragment
printf 'b\n' >> "$L/$RENDER"; printf 'b\n' >> "$L/$FDIR/0100-head.txt"; gl commit -qam with-fragment
RC=0; OUT=$(cd "$L" && bash "$DIR/bin/list-file-lint.sh" --base main 2>&1) || RC=$?
[ "$RC" = 0 ] && ok || bad "R12: a render edit with its fragment edit must pass list-file-lint, rc=$RC out=[$OUT]"

# ============================== R13 mirror readability ==============================
# The share mirror refuses any file whose extension is not in TEXT_EXT
# (bin/share/leakcheck.py: "un-auditable non-text file"). r9 named the
# fragments .part and the built mirror was refused. Read TEXT_EXT the way
# bin/fast-lints.sh --share-precheck reads it: python3 -I, import mapping.
# r13 <dir>: rc 0 when every entry's lower-cased extension is in TEXT_EXT.
r13() {
  python3 -I - "$DIR/bin/share" "$1" <<'PY'
import os, sys
sys.path.insert(0, sys.argv[1])
import mapping
bad = []
names = sorted(os.listdir(sys.argv[2]))
for n in names:
    ext = os.path.splitext(n)[1].lower()
    if ext not in mapping.TEXT_EXT:
        bad.append(n)
if not names:
    print("no files in " + sys.argv[2]); sys.exit(2)
if bad:
    print("not TEXT_EXT: " + " ".join(bad)); sys.exit(1)
PY
}
RC=0; OUT=$(r13 "$DIR/$FDIR" 2>&1) || RC=$?
[ "$RC" = 0 ] && ok || bad "R13: every name in $FDIR/ must have a TEXT_EXT extension the share mirror reads, rc=$RC out=[$OUT]"
# near miss: the r9 name is refused by the same check (else R13 proves nothing)
NM="$T/r13nm"; mkdir -p "$NM"; printf 'x\n' > "$NM/0100-head.part"
RC=0; OUT=$(r13 "$NM" 2>&1) || RC=$?
[ "$RC" = 1 ] && ok || bad "R13: a .part fragment must fail the TEXT_EXT check, rc=$RC out=[$OUT]"

# ============================== mutants ==============================
# M1: no C order (the export and the shared lib's LC_ALL=C sort both gone).
if [ "$HAVE_EN" = 1 ]; then
  M="$T/m1"; mkdir -p "$M/bin/lib"
  sed '/^export LC_ALL=C$/d' "$TOOL/$RS" > "$M/$RS"
  sed 's/LC_ALL=C sort/sort/' "$TOOL/bin/lib/render-fragments.sh" > "$M/bin/lib/render-fragments.sh"
  cmp -s "$M/$RS" "$TOOL/$RS" && bad "M1: the mutant changed nothing"
  locfix
  RC=0; OUT=$(env LC_ALL=en_US.utf8 bash "$M/$RS" --root "$R" --check 2>&1) || RC=$?
  [ "$RC" = 1 ] && ok || bad "M1: without the C order R2's locale case must drift (else it proves nothing), rc=$RC"
else
  echo "M1: skipped: no en_US.utf8 locale on this box, so a non-C sort orders like C"
fi
# M2: drop the last fragment -> R1 red.
# Each mutant sits beside the installed tool, so it sources the same lib.
M2="$TOOL/bin/render-split-m2.sh"
sed 's|cat -- "\${files\[@\]}" > "\$tmp"|cat -- "${files[@]:0:${#files[@]}-1}" > "$tmp"|' "$TOOL/$RS" > "$M2"
cmp -s "$M2" "$TOOL/$RS" && bad "M2: the mutant changed nothing"
RSX="$M2" rs --root "$DIR" --check
[ "$RC" != 0 ] && ok || bad "M2: a render that drops the last fragment must drift on the real checkout (else R1 proves nothing), rc=$RC"
# M3: --cut on every marker -> R7 red.
M3="$TOOL/bin/render-split-m3.sh"
sed 's/== "# >>> " && cnt >= n)/== "# >>> ")/' "$TOOL/$RS" > "$M3"
cmp -s "$M3" "$TOOL/$RS" && bad "M3: the mutant changed nothing"
cutroot "$R7"
RSX="$M3" rs --root "$R7" --cut out/c.sh --min-lines 60
got=$(cd "$R7/c.d" 2>/dev/null && for f in *.txt; do printf '%s:%s\n' "$f" "$(wc -l < "$f")"; done)
[ "$got" != "$want" ] && ok || bad "M3: a cut on every marker must change R7's cut table (else R7 proves nothing)"

# M5: --cut writes .part (the r9 name; the name rule follows it so the
# mutant is self-consistent) -> R7's cut table and R13's TEXT_EXT check red.
M5="$TOOL/bin/render-split-m5.sh"
# Since BH-9704 C1 the cut's extension is the row's (default txt), so the
# mutant also moves the default and the allow-list to part.
sed -e 's/\.txt/.part/g' -e 's/e=\${e:-txt}/e=${e:-part}/' -e 's/in txt|sh)/in part|txt|sh)/' "$TOOL/$RS" > "$M5"
cmp -s "$M5" "$TOOL/$RS" && bad "M5: the mutant changed nothing"
cutroot "$R7"
RSX="$M5" rs --root "$R7" --cut out/c.sh --min-lines 60
[ "$RC" = 0 ] || bad "M5: the self-consistent .part mutant must cut, rc=$RC err=[$ERR]"
got=$(cd "$R7/c.d" 2>/dev/null && for f in *.txt; do [ -e "$f" ] && printf '%s:%s\n' "$f" "$(wc -l < "$f")"; done)
[ "$got" != "$want" ] && ok || bad "M5: a .part cut must change R7's cut table (else R7 proves nothing)"
RC=0; r13 "$R7/c.d" >/dev/null 2>&1 || RC=$?
[ "$RC" = 1 ] && ok || bad "M5: R13's check must refuse the .part cut (else R13 proves nothing), rc=$RC"

echo "render-split.bh-9704: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
