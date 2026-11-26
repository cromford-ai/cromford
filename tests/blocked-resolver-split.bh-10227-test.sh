#!/bin/bash
# tests/blocked-resolver-split.bh-10227-test.sh — config/blocked-resolver.d/
# holds the HEAD of bin/blocked-resolver.sh as verbatim fragments (BH-10227 C0,
# target #4 of BH-9704). C1 adds the tail and the registry row; this suite then
# runs the renderer's full golden (S6) with no edit.
#   S1  names: NNNN-<slug>.txt or README.md, no dotfile/subdir/symlink, >= 2 fragments
#   S2  each fragment: non-empty, final newline, no CR, no merge marker, bash -n alone
#   S3  prefix golden: the LC_ALL=C concatenation is a byte prefix of the script
#       at the folder's last-writer commit (no commit -> the working tree), a
#       tail remains, and the prefix ends on a line boundary
#   S4  README: an "Adoption state" section and one table row per fragment
#   S5  size: the head is at most 285,000 bytes
#   S6  forward arm: a split-registry row names the script -> the renderer's
#       --check of the script is rc 0 (S3 and S5 are skipped then)
#   S7  the suite leaves `git status --porcelain` unchanged
#   S8  the gh-guard marker rule (catalog/silence-markers.tsv) skips a split
#       fragment, whose bytes are a copy of the render, and still hits the
#       same line in bin/ (0100-head.txt copies main's line 212, a comment
#       that names the marker with no reason after it)
#   M1-M5 mutants in scratch git repos: one changed byte (S3 red), a fragment
#       cut mid-line (S3 red), a stray 0150-X.txt (S1 red), a later commit that
#       edits line 2 of the script (S3 green), a registry row with no tail (S6 red)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

FDIR=config/blocked-resolver.d
SCRIPT=bin/blocked-resolver.sh
HEAD_CAP=285000
RS=bin/render-split.sh
NAME_RE='^[0-9]{4}-[a-z0-9][a-z0-9-]*\.txt$'
G() { git -c user.email=t@t -c user.name=t -c commit.gpgsign=false "$@"; }

# frags <root>: the fragment paths in LC_ALL=C name order.
frags() { (cd "$1" && LC_ALL=C ls -1 "$FDIR" 2>/dev/null | LC_ALL=C grep -E "$NAME_RE" | sed "s#^#$1/$FDIR/#"); }

# reg_row <root>: the split-registry line that names the script, if any.
reg_row() {
  local f
  for f in "$1"/catalog/splits.d/*.tsv; do
    [ -f "$f" ] || continue
    LC_ALL=C grep -m1 -P "^\Q$SCRIPT\E\t" "$f" && return 0
  done
  return 1
}

# Each check sets MSG and returns 0 (green) or 1 (red).
s1() { # names
  local R="$1" e name n=0
  MSG=
  [ -d "$R/$FDIR" ] || { MSG="no dir $FDIR/"; return 1; }
  while IFS= read -r -d '' e; do
    name=${e##*/}
    [ -L "$e" ] && { MSG="$name: a symlink"; return 1; }
    [ -f "$e" ] || { MSG="$name: not a regular file"; return 1; }
    [ "$name" = README.md ] && continue
    [[ "$name" =~ $NAME_RE ]] || { MSG="$name: bad name"; return 1; }
    n=$((n + 1))
  done < <(find "$R/$FDIR" -mindepth 1 -maxdepth 1 -print0)
  [ "$n" -ge 2 ] || { MSG="only $n fragment(s)"; return 1; }
  # A fragment name that sorts the same in C order and in name order is all
  # the renderer reads; a duplicate number would make the order ambiguous.
  local dup
  dup=$(frags "$R" | sed 's#.*/##' | cut -c1-4 | sort | uniq -d | head -1)
  [ -z "$dup" ] || { MSG="number $dup used twice"; return 1; }
  return 0
}

s2() { # each fragment alone
  local f
  MSG=
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -s "$f" ] || { MSG="${f##*/}: empty"; return 1; }
    [ -z "$(tail -c1 -- "$f")" ] || { MSG="${f##*/}: no final newline"; return 1; }
    ! LC_ALL=C grep -q $'\r' -- "$f" || { MSG="${f##*/}: a CR byte"; return 1; }
    ! LC_ALL=C grep -a -q -E '^(<<<<<<<|>>>>>>>) ' -- "$f" || { MSG="${f##*/}: a merge marker"; return 1; }
    bash -n "$f" 2>/dev/null || { MSG="${f##*/}: fails bash -n alone"; return 1; }
  done < <(frags "$1")
  return 0
}

# pinned <root> <out>: write the script the prefix is pinned to; PIN names it.
pinned() {
  local R="$1" out="$2" c=
  if git -C "$R" rev-parse --git-dir >/dev/null 2>&1; then
    c=$(git -C "$R" log -1 --format=%H -- "$FDIR/" 2>/dev/null) || c=
  fi
  if [ -n "$c" ] && git -C "$R" cat-file -e "$c:$SCRIPT" 2>/dev/null; then
    PIN="commit ${c:0:12}"
    git -C "$R" show "$c:$SCRIPT" > "$out"
  else
    PIN="working tree"
    cp -- "$R/$SCRIPT" "$out"
  fi
}

s3() { # prefix golden
  local R="$1" t n total last
  MSG=
  t=$(mktemp -d "$T/s3.XXXXXX")
  pinned "$R" "$t/script" || { MSG="cannot read $SCRIPT"; return 1; }
  # shellcheck disable=SC2046
  frags "$R" | tr '\n' '\0' | xargs -0 cat -- > "$t/head" 2>/dev/null
  n=$(wc -c < "$t/head"); total=$(wc -c < "$t/script")
  [ "$n" -gt 0 ] || { MSG="empty head"; return 1; }
  [ "$n" -lt "$total" ] || { MSG="the head ($n B) is not shorter than $SCRIPT ($total B): no tail remains"; return 1; }
  head -c "$n" "$t/script" | cmp -s - "$t/head" \
    || { MSG="the fragments are not a byte prefix of $SCRIPT at the $PIN ($(head -c "$n" "$t/script" | cmp - "$t/head" 2>&1 | head -1))"; return 1; }
  last=$(head -c "$n" "$t/script" | tail -c1 | od -An -c | tr -d ' ')
  [ "$last" = '\n' ] || { MSG="the prefix ends mid-line at byte $n"; return 1; }
  return 0
}

s4() { # README
  local R="$1" rd="$1/$FDIR/README.md" nf nr f
  MSG=
  [ -f "$rd" ] || { MSG="no README.md"; return 1; }
  [ "$(grep -c 'Adoption state' "$rd")" -ge 1 ] || { MSG="no Adoption state section"; return 1; }
  nf=$(frags "$R" | grep -c .); nr=$(grep -c '^| `[0-9]\{4\}-' "$rd")
  [ "$nf" = "$nr" ] || { MSG="$nf fragments, $nr README table rows"; return 1; }
  while IFS= read -r f; do
    grep -qF "| \`${f##*/}\` |" "$rd" || { MSG="README has no row for ${f##*/}"; return 1; }
  done < <(frags "$R")
  return 0
}

s5() { # size
  local n
  MSG=
  n=$(frags "$1" | tr '\n' '\0' | xargs -0 cat -- 2>/dev/null | wc -c)
  [ "$n" -le "$HEAD_CAP" ] || { MSG="head is $n B, cap $HEAD_CAP"; return 1; }
  return 0
}

s6() { # forward arm: the renderer's full golden
  local R="$1" rs="${2:-$DIR/$RS}" rc
  MSG=
  bash "$rs" --root "$R" --check "$SCRIPT" > "$T/s6.out" 2>&1; rc=$?
  [ "$rc" = 0 ] || { MSG="render-split --check $SCRIPT rc $rc: $(head -3 "$T/s6.out" | tr '\n' ' ')"; return 1; }
  return 0
}

STATUS0=$(git -C "$DIR" status --porcelain 2>/dev/null)

# ============================== the real checkout ==============================
s1 "$DIR" && ok || bad "S1: $MSG"
s2 "$DIR" && ok || bad "S2: $MSG"
if ROW=$(reg_row "$DIR"); then
  echo "SKIP S3 S5: registered ($ROW)"
  s6 "$DIR" && ok || bad "S6: $MSG"
else
  echo "SKIP S6 not registered"
  s3 "$DIR" && ok || bad "S3: $MSG"
  s5 "$DIR" && ok || bad "S5: $MSG"
fi
s4 "$DIR" && ok || bad "S4: $MSG"

# ============================== mutants ==============================
# mk <root>: a scratch git repo with the folder and the script the prefix is
# pinned to, committed once.
mk() {
  local R="$1"
  scratch_rm "$R"; mkdir -p "$R/bin" "$R/config"
  cp -r "$DIR/$FDIR" "$R/config/"
  pinned "$DIR" "$R/$SCRIPT"
  G -C "$R" init -q && G -C "$R" add -A && G -C "$R" commit -q -m base
}
LAST=$(frags "$DIR" | tail -1); LAST=${LAST##*/}

# M1 one byte changed in the last fragment -> S3 red
R="$T/m1"; mk "$R"
s3 "$R" && ok || bad "M1 setup: the clean scratch copy must pass S3: $MSG"
python3 -I -c 'import sys; p=sys.argv[1]; b=bytearray(open(p,"rb").read()); b[len(b)//2]^=1; open(p,"wb").write(b)' "$R/$FDIR/$LAST"
s3 "$R" && bad "M1: one changed byte in $LAST must turn S3 red" || ok

# M2 the last fragment's final line cut in half -> S3 red
R="$T/m2"; mk "$R"
python3 -I -c '
import sys; p=sys.argv[1]; b=open(p,"rb").read()
i=b.rstrip(b"\n").rfind(b"\n")+1; line=b[i:]
open(p,"wb").write(b[:i]+line[:max(1,len(line)//2)])' "$R/$FDIR/$LAST"
G -C "$R" add -A && G -C "$R" commit -q -m cut
s3 "$R" && bad "M2: a fragment set that ends mid-line must turn S3 red" || ok
[[ "$MSG" == *mid-line* ]] && ok || bad "M2: the S3 reason must name mid-line, got [$MSG]"

# M3 a stray 0150-X.txt -> S1 red
R="$T/m3"; mk "$R"
printf 'echo x\n' > "$R/$FDIR/0150-X.txt"
s1 "$R" && bad "M3: a stray 0150-X.txt must turn S1 red" || ok

# M4 a sibling commit after the folder's commit edits line 2 of the script -> S3 green
R="$T/m4"; mk "$R"
sed -i '2s/$/ # sibling edit/' "$R/$SCRIPT"
G -C "$R" commit -q -am sibling
head -2 "$R/$SCRIPT" | grep -q 'sibling edit' && ok || bad "M4 setup: line 2 must carry the sibling edit"
s3 "$R" && ok || bad "M4: a later commit that edits the head of $SCRIPT must leave S3 green: $MSG"
# and the same edit with no pin (no git) is red: the pin is what keeps it green
scratch_rm "$R/.git"
s3 "$R" && bad "M4: with no git the working-tree edit must turn S3 red" || ok

# M5 a registry row while the tail is absent -> S6 red (rc 1 drift)
R="$T/m5"; mk "$R"
TOOL="$T/tool"; mkdir -p "$TOOL"
scratch_install_closure "$RS" "$TOOL" >/dev/null || bad "M5 setup: closure install of $RS"
# the head alone as the committed script = the renderer reads a clean drift-free tree
mkdir -p "$R/catalog/splits.d"
printf '%s\t%s/\t755\ttxt\n' "$SCRIPT" "$FDIR" > "$R/catalog/splits.d/bh-10227-blocked-resolver.tsv"
s6 "$R" "$TOOL/$RS" && bad "M5: a registry row with the tail absent must turn S6 red" || ok
grep -q '^DRIFT ' "$T/s6.out" && ok || bad "M5: the renderer must report DRIFT, got [$(head -2 "$T/s6.out" | tr '\n' ' ')]"
# the arm is not vacuous the other way: a script that IS the head renders clean
frags "$R" | tr '\n' '\0' | xargs -0 cat -- > "$R/$SCRIPT"
s6 "$R" "$TOOL/$RS" && ok || bad "M5: a script equal to the fragments must pass S6: $MSG"

# ============================== S8 ==============================
. "$DIR/bin/lib/silence-scan.sh" || { bad "S8: cannot load bin/lib/silence-scan.sh"; }
MLINE='# call may survive here except a line that carries its own `# gh-guard-allo'w':`'  # the marker is split so this file is no hit for its own rule
out=$(printf '%s\t-\t%s\n' "$FDIR/0100-head.txt" "$MLINE" | ss_match "$DIR/catalog/silence-markers.tsv" reasonless)
[ -z "$out" ] && ok || bad "S8: the gh-guard rule must skip $FDIR/0100-head.txt, got [$out]"
out=$(printf '%s\t-\t%s\n' "$SCRIPT" "$MLINE" | ss_match "$DIR/catalog/silence-markers.tsv" reasonless)
[[ "$out" == *"gh guard marker"* ]] && ok || bad "S8: the gh-guard rule must still hit $SCRIPT, got [$out]"
out=$(printf '%s\t-\t%s\n' "config/x.d/notes.txt" "$MLINE" | ss_match "$DIR/catalog/silence-markers.tsv" reasonless)
[[ "$out" == *"gh guard marker"* ]] && ok || bad "S8: the skip must cover NNNN- fragments only, got [$out]"

# ============================== S7 ==============================
[ "$(git -C "$DIR" status --porcelain 2>/dev/null)" = "$STATUS0" ] && ok || bad "S7: the suite changed git status of $DIR"

echo "blocked-resolver-split.bh-10227: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
