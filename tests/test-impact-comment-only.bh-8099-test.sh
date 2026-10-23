#!/bin/bash
# tests/test-impact-comment-only.bh-8099-test.sh — BH-8099 (slice C2 of
# BH-8050): A COMMENT EDIT OF A SHELL FILE SELECTS ONLY THE SUITES THAT READ IT.
#
# bin/lib/test-impact-comment-only.sh classes every line of a changed shell
# file (tco_classes). When every changed line on both sides is an inert
# comment or blank line, the path's source, closure and named rows go and
# its self, reads, learned, regression and always rows stay, plus the suites
# that scan its directory. Rule P of bin/lib/test-impact-fn-reach.sh skips the
# same inert lines.
#
#   L1-L17  tco_classes on fixture files: the class of each named line
#   S1-S10  which changed paths are comment-only (select --why stderr)
#   K1-K3   near misses: a code byte, a trailing comment, a heredoc line
#   A1-A12  the rows kept and dropped, plain and batch, and the log counts
#   P1-P5   rule P in fn-reach
#   E1-E3   the exit paths select what TI_COMMENT_ONLY=0 selects
#   Z5      the real tree: a header comment of a lane script selects < 200
#
# Every select case drives the real bin/test-impact.sh against a scratch git
# repo. Self-contained: no network, no secrets, no clock read.
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1

TI="$DIR/bin/test-impact.sh"
LIB="$DIR/bin/lib/test-impact-comment-only.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v git >/dev/null || { echo "test-impact-comment-only-8099: git is required"; exit 2; }
[ -f "$LIB" ] || { echo "FAIL: $LIB is missing"; exit 1; }

# ── the scratch repository ──────────────────────────────────────────────────
R="$T/repo"
mkdir -p "$R/bin/lib" "$R/tests/lib" "$R/catalog/test-impact-learned.d" "$R/catalog/ci-batch-regression.d"
cat > "$R/bin/lib/core.sh" <<'SH'
#!/bin/bash
# core lib header
core_alpha_fn() {
  # alpha body comment
  echo alpha
}
core_beta_fn() {
  cat <<EOF
# beta heredoc
EOF
}
core_gamma_fn() {
  echo gamma # gamma tail
}
SH
cat > "$R/bin/lib/test-impact-fake.sh" <<'SH'
#!/bin/bash
# a selector lib of its own
fake_sel_fn() { :; }
SH
cat > "$R/bin/tool.sh" <<'SH'
#!/bin/bash
. "$(dirname "$0")/lib/core.sh"
core_alpha_fn
SH
cat > "$R/bin/selfhelp.sh" <<'SH'
#!/bin/bash
# selfhelp: prints this header
sed -n '2,3p' "$0"
SH
cat > "$R/bin/directive.sh" <<'SH'
#!/bin/bash
# module: one
echo directive
SH
cat > "$R/bin/modscan.sh" <<'SH'
#!/bin/bash
grep -l '^# module:' "$1"
SH
cat > "$R/bin/plain.bash" <<'SH'
#!/bin/bash
# a bash file
echo plain
SH
printf '# a doc\n' > "$R/bin/notes.md"
printf '#!/usr/bin/env python3\n# a python file\nprint(1)\n' > "$R/bin/tool.py"
cat > "$R/tests/lib/helper.sh" <<'SH'
#!/bin/bash
# helper header
helper_one_fn() { :; }
SH
cat > "$R/tests/lib/wrap.sh" <<'SH'
#!/bin/bash
. "$(dirname "${BASH_SOURCE[0]}")/helper.sh"
SH
suite() { # <name> <body line>
  printf '#!/bin/bash\nDIR=$(cd "$(dirname "$0")/.." && pwd)\n%s\n' "$2" > "$R/tests/$1-test.sh"
}
for i in 1 2 3; do suite "src-$i" '. "$DIR/bin/lib/core.sh"; core_alpha_fn'; done
suite src-b      '. "$DIR/bin/lib/core.sh"; core_beta_fn'
suite plain-src  '. "$DIR/bin/lib/core.sh"; echo src'
suite name       'echo core_gamma_fn'
suite tool       'bash "$DIR/bin/tool.sh" >/dev/null'
suite pin        'grep -c core "$DIR/bin/lib/core.sh"'
suite scan       'grep -rn x "$DIR/bin/lib" >/dev/null'
suite copy       'cp "$DIR/bin/lib/"*.sh "$T/"'
suite wide       'git -C "$DIR" ls-files | wc -l'
suite learn      'echo learn'
suite reg        'echo reg'
suite selfhelp   'bash "$DIR/bin/selfhelp.sh"'
suite directive  'bash "$DIR/bin/directive.sh"'
suite plainb     'bash "$DIR/bin/plain.bash"'
suite fake       '. "$DIR/bin/lib/test-impact-fake.sh"'
suite h          '. "$DIR/tests/lib/helper.sh"'
suite w          '. "$DIR/tests/lib/wrap.sh"'
printf 'bin/lib/core.sh\ttests/learn-test.sh\n' > "$R/catalog/test-impact-learned.d/bh-8099.tsv"
printf 'tests/reg-test.sh\tbin/lib/core.sh\n' > "$R/catalog/ci-batch-regression.d/bh-8099.txt"
gitc() { git -C "$R" -c user.email=t@example.com -c user.name=t "$@"; }
gitc init -q; gitc add -A; gitc commit -qm base
BASE=$(git -C "$R" rev-parse HEAD)

# sel <label> [env...] — --why and plain select over BASE..HEAD.
sel() {
  local label="$1"; shift
  env "$@" "$TI" --root "$R" select "$BASE..HEAD" --why > "$T/$label.why" 2> "$T/$label.err"
  env "$@" "$TI" --root "$R" select "$BASE..HEAD" > "$T/$label.sel" 2> "$T/$label.selerr"
}
has()    { grep -qxF "tests/$2-test.sh" "$T/$1.sel"; }
row()    { grep -qxF "$2" "$T/$1.why"; }
errhas() { grep -qF -- "$2" "$T/$1.err"; }
coline() { grep -c '^comment-only: ' "$T/$1.err"; }
reset_base() { gitc reset -q --hard "$BASE"; }
commit() { gitc add -A; gitc commit -qm "$1"; }
show() { tr '\n' ' ' < "$T/$1.sel"; echo "| $(tr '\n' ' ' < "$T/$1.err")"; }
TAB=$'\t'

# ── L1-L17: tco_classes ─────────────────────────────────────────────────────
# cls <file> <line> — the class tco_classes prints for <line> of <file>.
eval "$(grep -m1 '^TI_READ_RE=' "$TI")"
[ -n "${TI_READ_RE:-}" ] || { echo "FAIL: TI_READ_RE not found in $TI"; exit 1; }
classes() ( # <file> [root] — tco_classes in a clean shell; rc is its rc
  ROOT="${2:-$R}"; TI_TMP=$(mktemp -d "$T/tco.XXXXXX"); export ROOT TI_TMP TI_READ_RE
  bash -c '. "$1" || exit 9; tco_classes "$2"' _ "$LIB" "$1"
)
L="$T/lex"; mkdir -p "$L"
cat > "$L/a.sh" <<'SH'
#!/bin/bash
# L1 top comment
f_one() {
  # L2 indented
  echo "a\\" ; echo b

  case "$1" in
    x) # L4 in a case arm
       : ;;
  esac
  cat <<EOF
# L7 in a heredoc
EOF
  # L5 after a heredoc terminator
  echo x # L6 quoted backslash before me
	cat <<-'T'
	# L8 in a tabbed heredoc
	T
  awk '
# L9 in a single-quoted program
'
  y="two
# L10 in a double-quoted string
"
  foo \
# L11 after a continuation
  echo ${#arr[@]} $# a#b
  cat <<<"$x"
  # L16 after a here-string
}
# shellcheck disable=SC2086
# module: one
SH
classes "$L/a.sh" > "$T/a.cls"; rc=$?
[ "$rc" -eq 0 ] && ok || bad "L: tco_classes on a.sh must exit 0 (rc $rc: $(cat "$T/a.cls"))"
lcls() { sed -n "${1}p" "$T/a.cls"; }
lnum() { grep -n -m1 -F -- "$1" "$L/a.sh" | cut -d: -f1; }
expect() { # <case> <marker text> <class>
  local n c; n=$(lnum "$2"); c=$(lcls "$n")
  [ "$c" = "$3" ] && ok || bad "$1: line $n ('$2') must be class $3 (got '$c')"
}
expect L1  '# L1 top comment' I
expect L2  '# L2 indented' I
[ "$(lcls 6)" = I ] && ok || bad "L3: a blank line between commands must be I (got '$(lcls 6)')"
expect L4  '# L4 in a case arm' X        # a trailing comment on a code line is code
expect L5  '# L5 after a heredoc terminator' I
expect L6  'echo x # L6' X
expect L7  '# L7 in a heredoc' X
expect L8  '# L8 in a tabbed heredoc' X
expect L9  '# L9 in a single-quoted program' X
expect L10 '# L10 in a double-quoted string' X
expect L11 '# L11 after a continuation' X
expect L16 'echo ${#arr[@]}' X
expect L16 '# L16 after a here-string' I
expect L13 '# shellcheck disable=SC2086' X
expect L14 '# module: one' "D${TAB}module"
[ "$(lcls 1)" = X ] && ok || bad "L12: line 1 #! must be X (got '$(lcls 1)')"
# L6 proper: a line after `"a\\"` (the backslash is inside quotes) is not continued.
printf '#!/bin/bash\necho "a\\\\"\n# after\n' > "$L/l6.sh"
[ "$(classes "$L/l6.sh" | sed -n 3p)" = I ] && ok || bad "L6: a comment after a quoted backslash must be I ($(classes "$L/l6.sh" | tr '\n' ' '))"
# L4 proper: a whole comment line inside a case arm.
printf 'case x in\n  x)\n    # arm\n    : ;;\nesac\n' > "$L/l4.sh"
[ "$(classes "$L/l4.sh" | sed -n 3p)" = I ] && ok || bad "L4: a comment line inside a case arm must be I"
# L15: a file that reads its own text turns every comment line into S.
printf '#!/bin/bash\n# usage: x\n# more help\n\nsed -n 2,3p "$0"\n' > "$L/self.sh"
[ "$(classes "$L/self.sh" | sed -n '3p;4p' | tr '\n' ' ')" = "S I " ] && ok || bad "L15: a self-reading file's comment is S, its blank stays I ($(classes "$L/self.sh" | tr '\n' ' '))"
printf '#!/bin/bash\n# more help\nDIR=$(cd "$(dirname "$0")" && pwd)\n' > "$L/noself.sh"
[ "$(classes "$L/noself.sh" | sed -n 2p)" = I ] && ok || bad "L15: \$0 with no read verb is not a self-read"
# L17: EOF inside an open quote or a heredoc is ERR, rc 3.
printf "echo 'open\n# x\n" > "$L/q.sh"
out=$(classes "$L/q.sh"); rc=$?
[ "$rc" -eq 3 ] && [[ $out == ERR$'\t'*"open quote"* ]] && ok || bad "L17: EOF in an open quote must be ERR rc 3 (rc $rc: $out)"
printf 'cat <<EOF\n# x\n' > "$L/h.sh"
out=$(classes "$L/h.sh"); rc=$?
[ "$rc" -eq 3 ] && [[ $out == ERR$'\t'*heredoc* ]] && ok || bad "L17: EOF in a heredoc must be ERR rc 3 (rc $rc: $out)"
# Exit path 3: the tag scan cannot run, every tag-shaped comment is a directive.
printf '#!/bin/bash\n# note: x\n# plain\n' > "$L/tags.sh"
out=$(classes "$L/tags.sh" "$T/no-such-root" 2> "$T/tags.err" | tr '\n' ' ')
[ "$out" = "X D${TAB}note I " ] && grep -qxF 'comment-only: fallback (directive tags unreadable)' "$T/tags.err" && ok \
  || bad "E-tags: an unreadable tag scan makes every tag comment D and logs once (got '$out' / $(cat "$T/tags.err"))"
out=$(classes "$L/tags.sh" | tr '\n' ' ')
[ "$out" = "X I I " ] && ok || bad "L14: a tag no script reads is prose (got '$out')"

# ── eligibility ─────────────────────────────────────────────────────────────
elig() ( # <path> [env...] — rc of tco_eligible in a clean shell
  p="$1"; shift
  env "$@" bash -c '. "$1" || exit 9; tco_eligible "$2"' _ "$LIB" "$p"
)
elig bin/lib/test-impact-fn-reach.sh TI_NAMED_BASE=x; [ $? -eq 1 ] && ok || bad "S9: the selector's own lib must not be eligible"
elig bin/x.sh TI_NAMED_BASE=x; [ $? -eq 0 ] && ok || bad "S9: bin/x.sh with a base must be eligible"
elig tests/lib/y.bash TI_NAMED_BASE=x; [ $? -eq 0 ] && ok || bad "S5: a .bash path must be eligible"
elig bin/x.py TI_NAMED_BASE=x; [ $? -eq 1 ] && ok || bad "S10: a .py path must not be eligible"
elig docs/x.md TI_NAMED_BASE=x; [ $? -eq 1 ] && ok || bad "S10: a .md path must not be eligible"
elig bin/x.sh; [ $? -eq 1 ] && ok || bad "S10: no TI_NAMED_BASE must not be eligible"
elig bin/x.sh TI_NAMED_BASE=x TI_COMMENT_ONLY=0; [ $? -eq 1 ] && ok || bad "K: TI_COMMENT_ONLY=0 must not be eligible"

# ── S1 / A1-A9 / A12 / P1: a header comment in a lib ───────────────────────
reset_base
sed -i '2a # one more header line' "$R/bin/lib/core.sh"
sed -n 3p "$R/bin/lib/core.sh" | grep -qxF '# one more header line' || { echo "FAIL: the S1 fixture edit did not land"; exit 1; }
commit S1
sel S1; sel S1off TI_COMMENT_ONLY=0
errhas S1 'comment-only: bin/lib/core.sh: dropped ' && ok || bad "S1: a header comment must be comment-only ($(show S1))"
errhas S1 'fn-reach: comment only (bin/lib/core.sh)' && ok || bad "P1: fn-reach must log comment only ($(show S1))"
errhas S1off 'fn-reach: fallback (top-level change at head:3: bin/lib/core.sh)' && ok || bad "P5: knob off keeps the old rule P ($(show S1off))"
[ "$(coline S1off)" = 0 ] && ok || bad "K: knob 0 logs no comment-only line ($(show S1off))"
for s in pin learn reg wide scan; do has S1 "$s" && ok || bad "S1: $s must stay ($(show S1))"; done
row S1 "tests/pin-test.sh${TAB}reads${TAB}bin/lib/core.sh" && ok || bad "A2: the reads row stays"
row S1 "tests/learn-test.sh${TAB}learned${TAB}bin/lib/core.sh" && ok || bad "A3: the learned row stays"
row S1 "tests/reg-test.sh${TAB}regression${TAB}bin/lib/core.sh" && ok || bad "A4: the regression row stays"
row S1 "tests/wide-test.sh${TAB}always${TAB}*" && ok || bad "A5: the always row stays"
for s in src-1 src-2 src-3 src-b plain-src tool copy name; do
  has S1off "$s" && ok || bad "S1off: $s must be selected with the knob off ($(show S1off))"
  has S1 "$s" && bad "A6-A9: $s must be dropped ($(show S1))" || ok
done
row S1off "tests/plain-src-test.sh${TAB}source${TAB}bin/lib/core.sh" && ok || bad "A6: fixture: plain-src has a source row with the knob off"
row S1off "tests/tool-test.sh${TAB}closure${TAB}bin/lib/core.sh" && ok || bad "A7: fixture: tool has a closure row with the knob off"
row S1off "tests/name-test.sh${TAB}named${TAB}bin/lib/core.sh#core_gamma_fn" && ok || bad "A8: fixture: name has a named row with the knob off"
row S1 "tests/scan-test.sh${TAB}closure${TAB}bin/lib/core.sh" && ok || bad "A9: the directory scanner keeps its row ($(show S1))"
# A12: the log counts are the rows the filter removed and the suites it left.
cnt() { awk -F'\t' '$3 == "bin/lib/core.sh" || index($3, "bin/lib/core.sh#") == 1' "$T/$1.why" | grep -c .; }
scnt() { awk -F'\t' '$3 == "bin/lib/core.sh" || index($3, "bin/lib/core.sh#") == 1 { print $1 }' "$T/$1.why" | sort -u | grep -c .; }
want="comment-only: bin/lib/core.sh: dropped $(( $(cnt S1off) - $(cnt S1) )) row(s), $(scnt S1) of $(scnt S1off) suite(s) left, 1 kept by a directory scan"
grep -qxF "$want" "$T/S1.err" && ok || bad "A12: want '$want' ($(grep '^comment-only' "$T/S1.err"))"
[ "$(( $(cnt S1off) - $(cnt S1) ))" -ge 10 ] && ok || bad "A12: the fixture must drop 10 or more rows (got $(( $(cnt S1off) - $(cnt S1) )))"
# A plain select agrees with --why.
cmp -s "$T/S1.sel" <(cut -f1 "$T/S1.why" | LC_ALL=C sort -u) && ok || bad "A: plain select must equal the --why suites"

# ── E3: an unknown knob value is off, says so once, and equals knob 0 ──────
sel E3 TI_COMMENT_ONLY=yes
grep -qxF 'comment-only: off (TI_COMMENT_ONLY=yes)' "$T/E3.err" && [ "$(coline E3)" = 1 ] && ok || bad "E3: one off line ($(show E3))"
cmp -s "$T/E3.why" "$T/S1off.why" && ok || bad "E3: TI_COMMENT_ONLY=yes must equal TI_COMMENT_ONLY=0 ($(diff "$T/E3.why" "$T/S1off.why" | head -3 | tr '\n' ' '))"

# ── E1 / E2: the lib failed, the apply failed ───────────────────────────────
for v in e1 e2; do
  mkdir -p "$T/$v"
  scratch_install_closure bin/test-impact.sh "$T/$v" > /dev/null || { echo "FAIL: scratch_install_closure bin/test-impact.sh"; exit 1; }
  [ -f "$T/$v/bin/lib/test-impact-comment-only.sh" ] || { echo "FAIL: the closure of bin/test-impact.sh must hold the comment-only lib"; exit 1; }
done
printf 'return 3\n' > "$T/e1/bin/lib/test-impact-comment-only.sh"
rm -f "$T/e2/bin/lib/test-impact-fn-reach.sh"
for v in e1 e2; do
  "$T/$v/bin/test-impact.sh" --root "$R" select "$BASE..HEAD" --why > "$T/$v.why" 2> "$T/$v.err"
  TI_COMMENT_ONLY=0 "$T/$v/bin/test-impact.sh" --root "$R" select "$BASE..HEAD" --why > "$T/${v}off.why" 2> "$T/${v}off.err"
done
errhas e1 'comment-only: fallback (lib failed)' && cmp -s "$T/e1.why" "$T/e1off.why" && ok \
  || bad "E1: a lib that fails to load must log lib failed and select what knob 0 selects ($(show e1); $(diff "$T/e1.why" "$T/e1off.why" | head -3 | tr '\n' ' '))"
errhas e2 'comment-only: fallback (apply failed)' && cmp -s "$T/e2.why" "$T/e2off.why" && ok \
  || bad "E2: a failed apply must log apply failed and leave the rows ($(tr '\n' ' ' < "$T/e2.err"); $(diff "$T/e2.why" "$T/e2off.why" | head -3 | tr '\n' ' '))"

# ── S2 / S3 / S4: an edited comment, comment + blanks, blanks only ─────────
for c in S2 S3 S4; do
  reset_base
  case "$c" in
    S2) sed -i 's/# alpha body comment/# alpha body note/' "$R/bin/lib/core.sh" ;;
    S3) sed -i 's/^core_beta_fn() {$/\n# beta notes\n\ncore_beta_fn() {/' "$R/bin/lib/core.sh" ;;
    S4) sed -i 's/^core_gamma_fn() {$/\n\ncore_gamma_fn() {/' "$R/bin/lib/core.sh" ;;
  esac
  git -C "$R" diff --quiet && { echo "FAIL: the $c fixture edit did not land"; exit 1; }
  commit "$c"; sel "$c"
  errhas "$c" 'comment-only: bin/lib/core.sh: dropped ' && ! has "$c" plain-src && ok || bad "$c: must be comment-only ($(show "$c"))"
done

# ── S5: a .bash file ────────────────────────────────────────────────────────
reset_base
sed -i 's/# a bash file/# a bash file, edited/' "$R/bin/plain.bash"; commit S5; sel S5; sel S5off TI_COMMENT_ONLY=0
errhas S5 'comment-only: bin/plain.bash: dropped 1 row(s), 0 of 1 suite(s) left' && ! has S5 plainb && has S5off plainb && ok \
  || bad "S5: a .bash comment edit drops its runner ($(show S5) / $(show S5off))"

# ── K1 / K2 / K3 / P4: near misses ──────────────────────────────────────────
reset_base
sed -i 's/# alpha body comment/# alpha body note/; s/echo alpha$/echo alpha2/' "$R/bin/lib/core.sh"; commit K1; sel K1
[ "$(coline K1)" = 0 ] && has K1 src-1 && ok || bad "K1: a code byte beside a comment is not comment-only ($(show K1))"
reset_base
sed -i 's/# gamma tail/# gamma tail, edited/' "$R/bin/lib/core.sh"; commit K2; sel K2
[ "$(coline K2)" = 0 ] && has K2 name && ok || bad "K2: a trailing comment on a code line is code ($(show K2))"
reset_base
sed -i 's/^# beta heredoc$/# beta heredoc\n# beta heredoc two/' "$R/bin/lib/core.sh"; commit K3; sel K3
[ "$(coline K3)" = 0 ] && ok || bad "K3: a comment line inside a heredoc is data ($(show K3))"
errhas K3 'fn-reach: bin/lib/core.sh: kept ' && has K3 src-b && ! has K3 src-1 && ok || bad "P4: a heredoc line in core_beta_fn narrows to core_beta_fn ($(show K3))"

# ── P2 / P3: rule P skips inert lines in a mixed diff ───────────────────────
reset_base
sed -i '2a # header note' "$R/bin/lib/core.sh"; sed -i 's/echo gamma #/echo gamma2 #/' "$R/bin/lib/core.sh"; commit P2; sel P2; sel P2off TI_COMMENT_ONLY=0
errhas P2 'fn-reach: bin/lib/core.sh: kept ' && [ "$(coline P2)" = 0 ] && has P2 name && ! has P2 src-1 && ok || bad "P2: code in core_gamma_fn + a header comment narrows to core_gamma_fn ($(show P2))"
errhas P2off 'fn-reach: fallback (top-level change' && ok || bad "P2: with the knob off the header comment still falls back ($(show P2off))"
reset_base
sed -i 's/# alpha body comment/# alpha body note/; s/echo gamma #/echo gamma2 #/' "$R/bin/lib/core.sh"; commit P3; sel P3
errhas P3 '(1 function(s): core_gamma_fn;' && has P3 name && ! has P3 src-1 && ok || bad "P3: a comment in core_alpha_fn is not a change of it ($(show P3))"

# ── A10: two paths, one comment-only and one code ──────────────────────────
reset_base
sed -i '2a # header note' "$R/bin/lib/core.sh"; sed -i 's/^core_alpha_fn$/core_alpha_fn; echo t/' "$R/bin/tool.sh"; commit A10; sel A10
row A10 "tests/tool-test.sh${TAB}source${TAB}bin/tool.sh" && ! row A10 "tests/tool-test.sh${TAB}closure${TAB}bin/lib/core.sh" && ! has A10 plain-src && ok \
  || bad "A10: only the comment-only path loses rows ($(show A10))"
[ "$(coline A10)" = 1 ] && ok || bad "A10: one comment-only line, for core.sh only ($(show A10))"

# ── A1: a suite's own comment edit keeps its self row ──────────────────────
reset_base
sed -i '1a # a suite comment' "$R/tests/src-1-test.sh"; commit A1; sel A1
row A1 "tests/src-1-test.sh${TAB}self${TAB}tests/src-1-test.sh" && errhas A1 'comment-only: tests/src-1-test.sh: dropped 0 row(s), 1 of 1 suite(s) left' && ok \
  || bad "A1: the self row stays ($(show A1))"

# ── directive and self-read fallbacks (L14 / L15 through select) ──────────
reset_base
sed -i 's/^# module: one$/# module: two/' "$R/bin/directive.sh"; commit DIRV; sel DIRV
errhas DIRV 'comment-only: fallback (directive module: bin/directive.sh)' && has DIRV directive && ok || bad "L14: a read directive keeps today's rows ($(show DIRV))"
reset_base
sed -i 's/^# selfhelp: prints this header$/# selfhelp: prints this header, edited/' "$R/bin/selfhelp.sh"; commit SELF; sel SELF
errhas SELF 'comment-only: fallback (self-read: bin/selfhelp.sh)' && has SELF selfhelp && ok || bad "L15: a self-reading script keeps today's rows ($(show SELF))"

# ── S6 / S7 / S8 / S9: added, deleted, mode only, the selector's own lib ──
reset_base
printf '#!/bin/bash\n# only a comment\n' > "$R/bin/new.sh"; commit S6; sel S6
[ "$(coline S6)" = 0 ] && ok || bad "S6: an added file is not comment-only and logs nothing ($(show S6))"
reset_base
gitc rm -q bin/directive.sh; commit S7; sel S7
[ "$(coline S7)" = 0 ] && ok || bad "S7: a deleted file logs nothing ($(show S7))"
reset_base
chmod +x "$R/bin/lib/core.sh"; commit S8; sel S8
[ "$(coline S8)" = 0 ] && has S8 plain-src && ok || bad "S8: a mode change is not comment-only ($(show S8))"
reset_base
sed -i '2a # one more' "$R/bin/lib/test-impact-fake.sh"; commit S9; sel S9
[ "$(coline S9)" = 0 ] && has S9 fake && ok || bad "S9: a selector lib keeps today's rows ($(show S9))"

# ── S10: --changed with no TI_NAMED_BASE is not eligible ───────────────────
reset_base
sed -i '2a # one more header line' "$R/bin/lib/core.sh"
printf 'bin/lib/core.sh\n' > "$T/S10.changed"
"$TI" --root "$R" select --changed "$T/S10.changed" --why > "$T/S10.why" 2> "$T/S10.err"
[ "$(coline S10)" = 0 ] && grep -q '^tests/plain-src-test.sh' "$T/S10.why" && ok || bad "S10: no base, no rule ($(tr '\n' ' ' < "$T/S10.err"))"
gitc checkout -q -- .

# ── A11: a batch skips a comment-only helper's closure ─────────────────────
batch() { # <label>
  printf 'tests/lib/helper.sh\n' > "$T/$1.changed"
  TI_BATCH_SELECT=1 TI_NAMED_BASE="$BASE" "$TI" --root "$R" select --changed "$T/$1.changed" --why > "$T/$1.why" 2> "$T/$1.err"
  cut -f1 "$T/$1.why" | LC_ALL=C sort -u > "$T/$1.sel"
}
reset_base
sed -i 's/# helper header/# helper header, edited/' "$R/tests/lib/helper.sh"; commit A11; batch A11
reset_base
sed -i 's/helper_one_fn() { :; }/helper_one_fn() { true; }/' "$R/tests/lib/helper.sh"; commit A11c; batch A11c
! has A11 w && ! has A11 h && errhas A11 'comment-only: tests/lib/helper.sh: dropped ' && ok || bad "A11: a comment-only helper selects no suite through it ($(show A11))"
has A11c w && has A11c h && ok || bad "A11: a code change to the helper still selects its closure ($(show A11c))"

# ── Z5: the real tree, a header comment of a lane script ───────────────────
LANE=bin/stuck-work.sh
[ -f "$DIR/$LANE" ] || { echo "FAIL: Z5: $LANE is gone from the tree; pick another lane"; exit 1; }
git clone --shared -q "$DIR" "$T/c" || { echo "FAIL: Z5: cannot clone $DIR"; exit 1; }
awk 'NR == 3 { print "# A comment line added to the header for the BH-8099 lane fixture." } 1' "$T/c/$LANE" > "$T/lane.new" && cat "$T/lane.new" > "$T/c/$LANE"
git -C "$T/c" -c user.email=t@example.com -c user.name=t commit -qam Z5 || { echo "FAIL: Z5: commit"; exit 1; }
"$TI" --root "$T/c" map --out "$T/z5.map" 2> "$T/z5.maperr" || { echo "FAIL: Z5: the map could not be built: $(cat "$T/z5.maperr")"; exit 1; }
"$TI" --root "$T/c" select HEAD~1..HEAD --map "$T/z5.map" --why > "$T/z5.why" 2> "$T/z5.err"
TI_COMMENT_ONLY=0 "$TI" --root "$T/c" select HEAD~1..HEAD --map "$T/z5.map" --why > "$T/z5off.why" 2> "$T/z5off.err"
Z5=$(cut -f1 "$T/z5.why" | LC_ALL=C sort -u | grep -c .)
Z5OFF=$(cut -f1 "$T/z5off.why" | LC_ALL=C sort -u | grep -c .)
[ "$Z5" -lt 200 ] && ok || bad "Z5: a header comment of $LANE must select under 200 suites (got $Z5: $(tr '\n' ' ' < "$T/z5.err"))"
! awk -F'\t' '$2 !~ /^(self|reads|learned|regression|always|source)$/ { b = 1 } END { exit !b }' "$T/z5.why" && ok || bad "Z5: an unexpected kind ($(cut -f2 "$T/z5.why" | sort | uniq -c | tr '\n' ' '))"
[ -z "$(awk -F'\t' '($2 == "closure" || $2 == "named") && ($3 == "'"$LANE"'" || index($3, "'"$LANE"'#") == 1)' "$T/z5.why")" ] && ok || bad "Z5: no closure or named row for $LANE"
[ "$Z5OFF" -gt "$Z5" ] && ok || bad "Z5: TI_COMMENT_ONLY=0 must select more ($Z5OFF, on: $Z5)"
grep -q "^comment-only: $LANE: dropped " "$T/z5.err" && ok || bad "Z5: the comment-only line ($(tr '\n' ' ' < "$T/z5.err"))"
# Every source row left is a directory scanner that rule T3 keeps.
Z5SRC=$(awk -F'\t' '$2 == "source"' "$T/z5.why" | grep -c .)
Z5DIR=$(sed -n "s|^comment-only: $LANE: .*, \([0-9]*\) kept by a directory scan\$|\1|p" "$T/z5.err")
[ "$Z5SRC" = "$Z5DIR" ] && ok || bad "Z5: the $Z5SRC source rows must be the $Z5DIR directory-scan keeps"

echo "test-impact-comment-only-8099: Z5=$Z5 (knob off $Z5OFF)"
echo "test-impact-comment-only-8099: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
