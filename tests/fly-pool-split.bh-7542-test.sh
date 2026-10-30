#!/bin/bash
# tests/fly-pool-split.bh-7542-test.sh — BH-7454 (slice BH-7542): bin/fly-pool.sh
# is a committed render of the fragments in config/fly-pool.d/, joined by
# bin/fly-pool-build.sh.
#
# The set is complete (BH-8740): config/fly-pool.d/ holds 0100-head.sh and the
# 20 fine tail fragments, and catalog/list-files.tsv holds the bin/fly-pool.sh
# row. Each scratch tree copies every REAL fragment and README.md, and its
# bin/fly-pool.sh is the LC_ALL=C cat of those fragments.
#
# WHAT THIS PINS. Every case runs the REAL bin/fly-pool-build.sh as a process.
# The scratch cases get their own tree under $T (scratch_install_closure of the
# generator plus the fragments above), so no case shares state with another and
# the order of the cases does not matter.
#   C1 the real tree: bin/fly-pool.sh is tracked with mode 100755, and the
#      generator is tracked with mode 100755; --check is rc 0 and silent;
#      fpb_render equals bin/fly-pool.sh and git show HEAD:bin/fly-pool.sh
#   C2 order: 1950-bh-9001-alpha.sh renders between 0100-head.sh and the real
#      2000-... to 3900-... tail fragments; with a caller
#      LC_ALL=en_US.UTF-8, x-y.sh still renders before x.sh (C order)
#   C3 every real fragment passes bash -n, is not empty and ends in a newline;
#      0100-head.sh is a byte prefix of bin/fly-pool.sh as of the commit that
#      last wrote 0100-head.sh (so a sibling edit of bin/fly-pool.sh is not red)
#   C4 stale: one edited line in 2000-qrow-and-machine-io.sh -> --check rc 1 naming --write, render unchanged;
#      --write -> --check rc 0, mode 755; a deleted fragment -> --check rc 1
#   C5 malformed names, a missing dir, usage, a bash -n failure, --absorb, and
#      no bin/.fly-pool.sh.* temp file left after a refusal
#   C8 the real catalog holds the bin/fly-pool.sh row; with it, bin/list-file-lint.sh
#      refuses a commit that grows bin/fly-pool.sh with no fragment, and passes
#      one that adds a fragment and re-renders
#   C9 bin/state-paths-guard.sh skips an added config/fly-pool.d/ fragment (it
#      is the source of bin/fly-pool.sh, an existing writer), and still refuses
#      the same state write in a new bin/ script or another config/*.d/ dir
#
# Run from anywhere: tests/fly-pool-split.bh-7542-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
GEN="$REPO/bin/fly-pool-build.sh"
FRAG="$REPO/config/fly-pool.d"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
has() { case "$OUT" in *"$1"*) return 0 ;; esac; return 1; }

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.com
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.com
export GIT_AUTHOR_DATE='2026-10-19T18:00:00Z' GIT_COMMITTER_DATE='2026-10-19T18:00:00Z'

# The bin/fly-pool.sh row of catalog/list-files.tsv (slice C1, BH-8740).
C1_ROW=$'bin/fly-pool.sh\trendered config/fly-pool.d/\tcommitted render of bin/fly-pool-build.sh (BH-7454); hand edit: run --absorb'
# frags <dir> — copy every real fragment and README.md into <dir>, and print
# the LC_ALL=C cat of the fragments (the render) on stdout.
frags() {
  cp -p "$FRAG"/[0-9][0-9][0-9][0-9]-*.sh "$FRAG/README.md" "$1/" || return 1
  (cd "$1" && LC_ALL=C cat [0-9][0-9][0-9][0-9]-*.sh)
}
# mk <case> — a scratch tree at $T/<case> with the generator closure, every
# real fragment and README.md, and the render (their cat, mode 755). Prints
# the tree path.
mk() {
  local R="$T/$1" D
  D="$R/config/fly-pool.d"
  mkdir -p "$D" "$R/bin" "$R/tmp" || return 1
  scratch_install_closure bin/fly-pool-build.sh "$R" >/dev/null || return 1
  frags "$D" > "$R/bin/fly-pool.sh" && chmod 755 "$R/bin/fly-pool.sh" || return 1
  printf '%s\n' "$R"
}
# run <tree> [args...] — the tree's own generator, TMPDIR=<tree>/tmp; sets OUT and RC.
run() { local R=$1; shift; OUT=$(TMPDIR="$R/tmp" "$R/bin/fly-pool-build.sh" "$@" 2>&1); RC=$?; }
# notmp <tree> — no temp render is left in <tree>/bin or in its TMPDIR.
notmp() { ! compgen -G "$1/bin/.fly-pool.sh.*" >/dev/null && [ -z "$(ls -A "$1/tmp" 2>/dev/null)" ]; }
# line_of <file> <fixed string> — the first line number that holds it.
line_of() { grep -nF -- "$2" "$1" | head -1 | cut -d: -f1; }

# C1
if git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
  for f in bin/fly-pool.sh bin/fly-pool-build.sh; do
    mode=$(git -C "$REPO" ls-files -s "$f" | cut -d' ' -f1)
    [ "$mode" = 100755 ] && ok "C1 $f tracked, mode 100755" || bad "C1 $f mode '$mode'"
  done
else
  echo "  note C1 mode checks skipped: $REPO is not a git checkout"
fi
OUT=$("$GEN" --check 2>&1); RC=$?
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok "C1 --check on the real tree: rc 0, silent" || bad "C1 --check rc=$RC out: $OUT"
OUT=$( ( . "$GEN" && fpb_render "$T/c1-render" "$REPO" ) 2>&1); RC=$?
[ "$RC" = 0 ] && cmp -s "$T/c1-render" "$REPO/bin/fly-pool.sh" \
  && ok "C1 fpb_render (sourced) of the real fragments equals bin/fly-pool.sh" || bad "C1 fpb_render rc=$RC differs from bin/fly-pool.sh; out: $OUT"
if git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
  git -C "$REPO" show HEAD:bin/fly-pool.sh > "$T/c1-head" 2>/dev/null \
    && cmp -s "$T/c1-render" "$T/c1-head" \
    && ok "C1 fpb_render equals git show HEAD:bin/fly-pool.sh" || bad "C1 fpb_render differs from git show HEAD:bin/fly-pool.sh"
else
  echo "  note C1 git show half skipped: $REPO is not a git checkout"
fi

# C2
R=$(mk c2) || bad "C2 scratch tree"
printf 'fpb_alpha_9001() { echo alpha; }\n' > "$R/config/fly-pool.d/1950-bh-9001-alpha.sh"
run "$R" --write
n_alpha=$(line_of "$R/bin/fly-pool.sh" 'fpb_alpha_9001()')
n_head=$(wc -l < "$FRAG/0100-head.sh")
[ "$RC" = 0 ] && [ "$n_alpha" = $((n_head + 1)) ] \
  && cmp -s <(tail -n +$((n_head + 2)) "$R/bin/fly-pool.sh") <(cd "$FRAG" && LC_ALL=C cat [23][0-9][0-9][0-9]-*.sh) \
  && ok "C2 1950-bh-9001-alpha.sh renders after 0100-head.sh and before the real 2000-3900 fragments" \
  || bad "C2 rc=$RC alpha at line '$n_alpha', head has $n_head lines; out: $OUT"
en=$(locale -a 2>/dev/null | grep -iE '^en_US\.utf-?8$' | head -1)
if [ -n "$en" ]; then
  printf '# fpb-order x\n' > "$R/config/fly-pool.d/1960-bh-9001-x.sh"
  printf '# fpb-order x-y\n' > "$R/config/fly-pool.d/1960-bh-9001-x-y.sh"
  OUT=$(LC_ALL="$en" "$R/bin/fly-pool-build.sh" --write 2>&1); RC=$?
  nx=$(grep -nx '# fpb-order x' "$R/bin/fly-pool.sh" | cut -d: -f1)
  nxy=$(grep -nx '# fpb-order x-y' "$R/bin/fly-pool.sh" | cut -d: -f1)
  [ "$RC" = 0 ] && [ -n "$nx" ] && [ -n "$nxy" ] && [ "$nxy" -lt "$nx" ] \
    && ok "C2 caller LC_ALL=$en: x-y.sh renders before x.sh (C order)" \
    || bad "C2 locale order rc=$RC x-y at '$nxy', x at '$nx'; out: $OUT"
else
  echo "  SKIP C2 locale half: no en_US.UTF-8 locale on this host (locale -a)"
fi

# C3
nfr=0; c3=0
for f in "$FRAG"/[0-9][0-9][0-9][0-9]-*.sh; do
  [ -e "$f" ] || continue
  nfr=$((nfr + 1))
  [ -s "$f" ] || { c3=1; bad "C3 $(basename "$f") is empty"; }
  bash -n "$f" 2>/dev/null || { c3=1; bad "C3 $(basename "$f") fails bash -n"; }
  [ "$(tail -c1 "$f" | od -An -c | tr -d ' ')" = '\n' ] || { c3=1; bad "C3 $(basename "$f") does not end in a newline"; }
done
[ "$nfr" -ge 1 ] && [ "$c3" = 0 ] && ok "C3 $nfr real fragment(s): each passes bash -n, is not empty, ends in a newline" \
  || bad "C3 fragments=$nfr"
# The prefix is checked against bin/fly-pool.sh AT THE COMMIT THAT LAST WROTE
# 0100-head.sh, not against today's file: until slice C1 nothing keeps the two in
# step, and a sibling PR that edits the head part of bin/fly-pool.sh must not turn
# this suite red in the merge queue. An uncommitted head is checked against the
# working tree.
c3src=$REPO/bin/fly-pool.sh; c3at="the working tree"
if git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 \
  && git -C "$REPO" diff --quiet HEAD -- config/fly-pool.d/0100-head.sh 2>/dev/null; then
  c3c=$(git -C "$REPO" log -1 --format=%H -- config/fly-pool.d/0100-head.sh 2>/dev/null)
  if [ -n "$c3c" ] && git -C "$REPO" show "$c3c:bin/fly-pool.sh" > "$T/c3-render" 2>/dev/null; then
    c3src=$T/c3-render; c3at="commit ${c3c:0:12}"
  fi
fi
if [ -s "$FRAG/0100-head.sh" ] && head -n "$(wc -l < "$FRAG/0100-head.sh")" "$c3src" | cmp -s - "$FRAG/0100-head.sh"; then
  ok "C3 0100-head.sh is a byte prefix of bin/fly-pool.sh at $c3at"
else bad "C3 0100-head.sh is not a byte prefix of bin/fly-pool.sh at $c3at (re-cut it, see README.md)"; fi
OUT=$( ( . "$GEN" && fpb_validate "$REPO" ) 2>&1); RC=$?
[ "$RC" = 0 ] && ok "C3 fpb_validate (sourced) on the real tree is rc 0" || bad "C3 fpb_validate rc=$RC out: $OUT"

# C4
R=$(mk c4) || bad "C4 scratch tree"
sha0=$(sha256sum < "$R/bin/fly-pool.sh")
sed -i '2s/^/# c4 edit\n/' "$R/config/fly-pool.d/2000-qrow-and-machine-io.sh"
run "$R" --check
[ "$RC" = 1 ] && has 'bin/fly-pool.sh is stale' && has '--write' && [ "$(sha256sum < "$R/bin/fly-pool.sh")" = "$sha0" ] \
  && ok "C4 edited fragment: --check rc 1, names --write, render unchanged" || bad "C4 stale rc=$RC out: $OUT"
run "$R" --write
w=$RC
run "$R" --check
[ "$w" = 0 ] && [ "$RC" = 0 ] && [ "$(stat -c %a "$R/bin/fly-pool.sh")" = 755 ] && grep -qx '# c4 edit' "$R/bin/fly-pool.sh" && notmp "$R" \
  && ok "C4 --write then --check rc 0; render mode 755; no temp left" || bad "C4 write rc=$w check rc=$RC out: $OUT"
R=$(mk c4b) || bad "C4b scratch tree"
rm -f "$R/config/fly-pool.d/2000-qrow-and-machine-io.sh"
run "$R" --check
[ "$RC" = 1 ] && has 'is stale' && ok "C4 deleted fragment: --check rc 1" || bad "C4 deleted fragment rc=$RC out: $OUT"

# C5
i=0
for name in foo.sh 100-x.sh 0100-X.sh 0100-x.sh.bak 0100-x.txt 0100-.sh .0100-x.sh 0100-d.sh/; do
  i=$((i + 1)); R=$(mk "c5-$i") || bad "C5 scratch tree $name"
  case "$name" in
    */) mkdir "$R/config/fly-pool.d/$name" ;;
    *) printf 'true\n' > "$R/config/fly-pool.d/$name" ;;
  esac
  run "$R" --check; c=$RC; co=$OUT
  run "$R" --write
  [ "$c" = 2 ] && [ "$RC" = 2 ] && case "$co" in *"${name%/}"*) true ;; *) false ;; esac && notmp "$R" \
    && ok "C5 '$name': --check and --write rc 2, named" || bad "C5 '$name' check rc=$c write rc=$RC out: $co"
done
R=$(mk c5-readme) || bad "C5 scratch tree readme"
run "$R" --check
[ -f "$R/config/fly-pool.d/README.md" ] && [ "$RC" = 0 ] && ok "C5 README.md present: rc 0" || bad "C5 README rc=$RC out: $OUT"
R=$(mk c5-nodir) || bad "C5 scratch tree nodir"
scratch_rm "$R/config/fly-pool.d"
run "$R" --check
[ "$RC" = 2 ] && has 'config/fly-pool.d' && ok "C5 missing config/fly-pool.d/: rc 2" || bad "C5 nodir rc=$RC out: $OUT"
R=$(mk c5-none) || bad "C5 scratch tree none"
rm -f "$R/config/fly-pool.d/"*.sh
run "$R" --check
[ "$RC" = 2 ] && ok "C5 no fragment: rc 2" || bad "C5 no fragment rc=$RC out: $OUT"
R=$(mk c5-usage) || bad "C5 scratch tree usage"
run "$R"; a=$RC; run "$R" --bogus; b=$RC; run "$R" --check --write; c=$RC
[ "$a" = 2 ] && [ "$b" = 2 ] && [ "$c" = 2 ] && has 'usage' && ok "C5 no args / --bogus / two verbs: rc 2 with usage" \
  || bad "C5 usage rc=$a/$b/$c out: $OUT"
R=$(mk c5-bad) || bad "C5 scratch tree badsyntax"
printf 'if true; then\n' > "$R/config/fly-pool.d/1500-bad.sh"
sha0=$(sha256sum < "$R/bin/fly-pool.sh")
run "$R" --check; c=$RC; co=$OUT
run "$R" --write
[ "$c" = 1 ] && [ "$RC" = 1 ] && case "$co" in *'1500-bad.sh fails bash -n'*) true ;; *) false ;; esac \
  && [ "$(sha256sum < "$R/bin/fly-pool.sh")" = "$sha0" ] && notmp "$R" \
  && ok "C5 1500-bad.sh with no fi: rc 1 naming it, render unchanged, no temp" || bad "C5 bad syntax check rc=$c write rc=$RC out: $co"
R=$(mk c5-empty) || bad "C5 scratch tree empty"
: > "$R/config/fly-pool.d/1500-empty.sh"
run "$R" --check
[ "$RC" = 1 ] && has '1500-empty.sh' && ok "C5 empty fragment: rc 1 naming it" || bad "C5 empty rc=$RC out: $OUT"
R=$(mk c5-absorb) || bad "C5 scratch tree absorb"
OUT=$(TMPDIR="$R/tmp" "$R/bin/fly-pool-build.sh" --absorb 2>&1 >/dev/null); RC=$?
[ "$RC" = 2 ] && has 'fly-pool-build: --absorb is not built yet (BH-7454.3)' && notmp "$R" \
  && ok "C5 --absorb: rc 2 with the not-built line on stderr" || bad "C5 --absorb rc=$RC out: $OUT"

# C8
L="$T/c8"
mkdir -p "$L" && cd "$L" && git init -q -b main . || bad "C8 git init"
scratch_install_closure bin/list-file-lint.sh "$L" >/dev/null || bad "C8 lint closure"
scratch_install_closure bin/fly-pool-build.sh "$L" >/dev/null || bad "C8 generator closure"
mkdir -p catalog config/fly-pool.d
grep -qxF -- "$C1_ROW" "$REPO/catalog/list-files.tsv" \
  && ok "C8 the real catalog/list-files.tsv holds the bin/fly-pool.sh row" || bad "C8 the real catalog/list-files.tsv has no bin/fly-pool.sh row"
cp "$REPO/catalog/list-files.tsv" catalog/ \
  && frags config/fly-pool.d > bin/fly-pool.sh && chmod 755 bin/fly-pool.sh || bad "C8 scratch tree"
git add -A && git commit -q -m base && git branch base
echo '# hand append' >> bin/fly-pool.sh
git add -A && git commit -q -m hand
OUT=$(bin/list-file-lint.sh --base base 2>&1); RC=$?
[ "$RC" = 1 ] && has 'bin/fly-pool.sh' && has 'config/fly-pool.d/' \
  && ok "C8 hand append to bin/fly-pool.sh: lint rc 1 naming config/fly-pool.d/" || bad "C8 hand rc=$RC out: $OUT"
git checkout -q -b frag base
printf 'fpb_alpha_9001() { echo alpha; }\n' > config/fly-pool.d/1950-bh-9001-alpha.sh
w=0; bin/fly-pool-build.sh --write || w=$?
git add -A && git commit -q -m frag
OUT=$(bin/list-file-lint.sh --base base 2>&1); RC=$?
[ "$w" = 0 ] && [ "$RC" = 0 ] && ok "C8 fragment + --write: lint rc 0" || bad "C8 frag write rc=$w lint rc=$RC out: $OUT"
cd "$REPO" || exit 1

# C9
SPG="$REPO/bin/state-paths-guard.sh"
# Find the line by its text, not its number: main moves bin/fly-pool.sh often,
# and every re-cut shifts the line numbers.
line=$(grep -m1 -xF 'POOL="$HARNESS/state/fly-pool/$P"; PDIR="$HARNESS/state/pool/$P"' "$FRAG/0100-head.sh")
case "$line" in *state/pool/*) ok "C9 0100-head.sh holds the state/pool write the guard flags" ;;
  *) bad "C9 0100-head.sh has no POOL=/PDIR= state/pool line: $line" ;; esac
G="$T/c9"; mkdir -p "$G/bin" "$G/config/zz.d" "$G/config/fly-pool.d" || bad "C9 dirs"
printf '#!/bin/bash
%s
' "$line" > "$G/bin/zz-new.sh"
printf '%s
' "$line" > "$G/config/zz.d/0100-x.sh"
printf '%s
' "$line" > "$G/config/fly-pool.d/0100-head.sh"
spg() { printf '%s
' "$@" > "$G/files"; OUT=$(cd "$G" && SPG_FILES="$G/files" "$SPG" 2>&1); RC=$?; }
spg config/fly-pool.d/0100-head.sh
[ "$RC" = 0 ] && ok "C9 added config/fly-pool.d/0100-head.sh: guard rc 0" || bad "C9 fragment rc=$RC out: $OUT"
OUT=$(cd "$REPO" && printf '%s\n' "$FRAG"/[0-9][0-9][0-9][0-9]-*.sh | sed "s|^$REPO/||" > "$G/real" && SPG_FILES="$G/real" "$SPG" 2>&1); RC=$?
[ "$RC" = 0 ] && ok "C9 the real fragments: guard rc 0" || bad "C9 real fragments rc=$RC out: $OUT"
spg bin/zz-new.sh
[ "$RC" = 1 ] && has 'bin/zz-new.sh' && ok "C9 same line in a new bin/zz-new.sh: guard rc 1" || bad "C9 bin rc=$RC out: $OUT"
spg config/zz.d/0100-x.sh
[ "$RC" = 1 ] && has 'config/zz.d/0100-x.sh' && ok "C9 same line in config/zz.d/0100-x.sh: guard rc 1" || bad "C9 other .d rc=$RC out: $OUT"

echo "fly-pool-split: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
