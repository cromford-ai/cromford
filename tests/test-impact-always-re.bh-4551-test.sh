#!/bin/bash
# tests/test-impact-always-re.bh-4551-test.sh — BH-4551: THE ALWAYS-RUN SET IS
# THE SUITES THAT SCAN THE WHOLE TREE, NOT THE ONES THAT SAY `ls-files`.
#
# bin/test-impact.sh used to grep each suite's whole text for a bare `ls-files`,
# so a comment, a git stub's `"ls-files")` arm or a scoped `git ls-files catalog`
# put a suite in the always-run set. On 2026-10-04 two such suites (#4256,
# #4257) landed there with no durations row and turned fast-lints-data D1-D3
# red in the merge queue. Every case drives the real CLI:
#
#   F1  a comment mentioning ls-files / --tree: not always
#   F2  a heredoc git stub with a `"ls-files")` arm, plus a comment: not always
#   F3  git -C "$DIR" ls-files, -z, inside "$(...)", `git ls-files .`, with a
#       redirect (2>/dev/null, 2>&1 >file) or in backticks: always
#   F4  git ls-files catalog / git -C "$DIR" ls-files -- docs/x.md: not always
#   F5  bin/checks-run.sh --tree .: always
#   F6  find "$DIR/bin" and "$DIR"/tests/*: always
#   F7  quoted messages, quoted grep patterns, case patterns, a file named
#       ls-files: not always
#   F8  always-why: one `<suite>\t<source>` row per always suite, cut -f1 of it
#       is `always`, a catalog-only suite cites the catalog, `always --why` rc 2
#   F9  fast-lints-data D1 warns, naming the matched line of an unmeasured always suite
#   F10 the real tree: every suite the OLD detector put in the set at c84de0d
#       is still there unless it only matched in comments (that list printed),
#       and the new set adds nothing the old detector or the catalog did not
#       (BH-8098: the C1_OUT suites left on purpose, slice C1 of #8050)
#   F11 a scanner that dies fails `always` and makes fast-lints --list rc 2
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1

TI="$DIR/bin/test-impact.sh"
PASS=0 FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }

# One scratch root per case: a tests/ dir of fixture suites and an empty catalog.
newroot() {
  R="$T/$1"
  mkdir -p "$R/tests" "$R/catalog"
  : > "$R/catalog/test-impact-always.txt"
}
# fixture <name> <line>... — one suite. The lines are single-quoted on purpose:
# quoted text is data to the detector, so this suite's fixtures do not put the
# suite itself in the always-run set (and need no durations row).
fixture() { local n="$1"; shift; printf '%s\n' "$@" > "$R/tests/$n-test.sh"; }
run_always() {
  "$TI" --root "$R" always > "$R.out" 2> "$R.err"
  ARC=$?
}
is_always()  { grep -qxF "tests/$1-test.sh" "$R.out"; }
expect_in()  { if is_always "$1"; then ok "$2"; else bad "$2 (always: $(tr '\n' ' ' < "$R.out"))"; fi; }
expect_out() { if is_always "$1"; then bad "$2 (always: $(tr '\n' ' ' < "$R.out"))"; else ok "$2"; fi; }

echo "F1: a comment is not a scan"
newroot f1
fixture comment \
  '#!/bin/bash' \
  '# a comment that says git ls-files and --tree' \
  '   # indented: git -C "$DIR" ls-files | wc -l' \
  'echo hi'
run_always
[ "$ARC" = 0 ] && ok "F1 always rc 0" || bad "F1 always rc=$ARC err=$(cat "$R.err")"
expect_out comment "F1 comment-only suite is not always"

echo "F2: a git stub's ls-files arm is not a scan (#4257's shape)"
newroot f2
fixture stub \
  '#!/bin/bash' \
  '# the stub answers ls-files with a fixed list' \
  'mkdir -p "$T/bin"' \
  'cat > "$T/bin/git" <<'"'"'EOF'"'"'' \
  '#!/bin/bash' \
  'case "$1" in' \
  '  "ls-files") echo x ;;' \
  '  ls-files) echo y ;;' \
  'esac' \
  'EOF'
run_always
expect_out stub "F2 heredoc stub with ls-files arms is not always"

echo "F3: unscoped git ... ls-files is always"
newroot f3
fixture dashc \
  'n=$(git -C "$DIR" ls-files | wc -l)'
fixture z \
  'git -C "$DIR" ls-files -z | tar --null -T - -cf "$T/x.tar"'
fixture subst \
  '[ -z "$(git -C "$R" ls-files -u)" ] && echo clean'
fixture dot \
  'cd "$DIR" && git ls-files . > "$T/files"'
run_always
expect_in dashc 'F3 git -C "$DIR" ls-files | wc -l is always'
expect_in z     'F3 git -C "$DIR" ls-files -z | tar is always'
expect_in subst 'F3 "$(git -C "$R" ls-files -u)" is always'
expect_in dot   'F3 git ls-files . is always'

newroot f3r
fixture devnull \
  'n=$(git ls-files 2>/dev/null | wc -l)'
fixture tick \
  'n=`git ls-files`'
fixture fd \
  'git -C "$DIR" ls-files 2>&1 >"$T/all"'
fixture scopedredir \
  'git ls-files catalog 2>/dev/null | wc -l'
run_always
expect_in  devnull     'F3 git ls-files 2>/dev/null | wc -l is always'
expect_in  tick        'F3 `git ls-files` is always'
expect_in  fd          'F3 git -C "$DIR" ls-files 2>&1 >"$T/all" is always'
expect_out scopedredir 'F3 git ls-files catalog 2>/dev/null is still scoped'

echo "F4: a scoped ls-files is not a whole-tree scan (#4256's shape)"
newroot f4
fixture catalog \
  'for f in $(git ls-files catalog); do echo "$f"; done'
fixture dashdash \
  'git -C "$DIR" ls-files -- docs/x.md > /dev/null || echo untracked'
run_always
expect_out catalog  'F4 git ls-files catalog is not always'
expect_out dashdash 'F4 git -C "$DIR" ls-files -- docs/x.md is not always'

echo "F5: the whole-tree lane"
newroot f5
fixture tree \
  '"$DIR/bin/checks-run.sh" --tree . > "$T/out" 2>&1'
run_always
expect_in tree 'F5 bin/checks-run.sh --tree . is always'

echo "F6: find over the checkout and the corpus glob are kept"
newroot f6
fixture find \
  'find "$DIR/bin" -name x'
fixture glob \
  'for t in "$DIR"/tests/*.sh; do :; done'
run_always
expect_in find 'F6 find "$DIR/bin" is always'
expect_in glob 'F6 "$DIR"/tests/* is always'

echo "F7: quoted text and case patterns are data"
newroot f7
fixture msg \
  'bad "GT-9: git ls-files reports x"'
fixture sq \
  'grep -q '"'"'git ls-files'"'"' f && echo y'
fixture casepat \
  'case "$args" in' \
  '  *"bin/checks-run.sh --tree"*) ok ;;' \
  'esac'
fixture grepre \
  'grep -qE "^--tree $H/x" log'
fixture fname \
  'printf x > "$T/ls-files"'
# Each of these three is a hit if its own rule is removed: the case-arm strip
# (casedir), the double-quote mask (dqtree) and the single-quote mask (sqpipe).
fixture casedir \
  'case "$f" in' \
  '  "$DIR"/tests/*) echo suite ;;' \
  'esac'
fixture dqtree \
  'echo "the lane runs bin/checks-run.sh --tree . on main"'
fixture sqpipe \
  'say '"'"'git ls-files | wc -l'"'"''
run_always
expect_out casedir 'F7 a case pattern "$DIR"/tests/*) is not always'
expect_out dqtree  'F7 a double-quoted message with --tree . is not always'
expect_out sqpipe  'F7 a single-quoted git ls-files | wc -l is not always'
expect_out msg     'F7 a double-quoted message naming git ls-files is not always'
expect_out sq      'F7 a single-quoted grep pattern is not always'
expect_out casepat 'F7 a case pattern naming --tree is not always'
expect_out grepre  'F7 "^--tree $H/x" is not always'
expect_out fname   'F7 a file named ls-files is not always'

echo "F8: always-why names the line"
newroot f8
fixture a \
  '#!/bin/bash' \
  '# git ls-files in a comment does not count' \
  '    n=$(git -C "$DIR" ls-files | wc -l)'
fixture b \
  'echo listed by hand'
fixture c \
  'echo neither'
printf '# hand list\ntests/b-test.sh  reason here\ntests/a-test.sh  also listed\ntests/gone-test.sh  renamed away\n' \
  > "$R/catalog/test-impact-always.txt"
"$TI" --root "$R" always-why > "$R.why" 2> "$R.err"; WRC=$?
run_always
[ "$WRC" = 0 ] && ok "F8 always-why rc 0" || bad "F8 always-why rc=$WRC err=$(cat "$R.err")"
printf 'tests/a-test.sh\ttests/a-test.sh:3: n=$(git -C "$DIR" ls-files | wc -l)\ntests/b-test.sh\tcatalog/test-impact-always.txt\n' > "$R.want"
if cmp -s "$R.want" "$R.why"; then ok "F8 rows: detected line (wins over the catalog), catalog-only source"
else bad "F8 always-why rows differ: $(diff "$R.want" "$R.why" | tr '\n' '|')"; fi
if cut -f1 "$R.why" | cmp -s - "$R.out"; then ok "F8 cut -f1 of always-why is always"
else bad "F8 always-why suites != always: $(cut -f1 "$R.why" | tr '\n' ' ') vs $(tr '\n' ' ' < "$R.out")"; fi
"$TI" --root "$R" always --why > /dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "F8 always --why stays rc 2" || bad "F8 always --why rc=$rc"
"$TI" --root "$R" always-why --out "$R.whyout" > /dev/null 2>&1
cmp -s "$R.why" "$R.whyout" && ok "F8 always-why honours --out" || bad "F8 always-why --out differs"
# The real tree: the line the ticket's plan names.
"$TI" always-why > "$T/real.why" 2> "$T/real.err"; rc=$?
[ "$rc" = 0 ] && ok "F8 real always-why rc 0" || bad "F8 real always-why rc=$rc err=$(cat "$T/real.err")"
awk -F'\t' '$1 == "tests/test-impact-test.sh" {print $2}' "$T/real.why" | grep -qE '^tests/test-impact-test\.sh:[0-9]+: .*ls-files' \
  && ok "F8 real tests/test-impact-test.sh cites its ls-files line" \
  || bad "F8 real row: $(awk -F'\t' '$1 == "tests/test-impact-test.sh"' "$T/real.why")"

echo "F9: fast-lints-data D1 names the matched line of an unmeasured suite"
newroot f9
fixture wide \
  'git -C "$DIR" ls-files | wc -l'
printf 'suite\tseconds\trun\n' > "$T/f9.tsv"
FLD_ROOT="$R" FLD_DURATIONS="$T/f9.tsv" bash "$DIR/tests/fast-lints-data.bh-3860-test.sh" > "$T/f9.out" 2>&1; rc=$?
# TEST-CHANGE BH-5292: was "D1 is red on an unmeasured always suite". the operator
# changed the rule (2026-10-07): a missing timing row is a WARNING, never a red,
# because it ejected every merge-queue batch for six hours. What F9 guards is
# unchanged: the unmeasured suite is NAMED, with the line that matched.
grep -qE '^  WARN D1 .*tests/wide-test.sh' "$T/f9.out" && ok "F9 D1 warns on an unmeasured always suite" \
  || bad "F9 no D1 warning naming the unmeasured suite (rc=$rc): $(grep 'D1' "$T/f9.out" | tr '\n' '|')"
grep -qF 'D1 hint: tests/wide-test.sh is always-run via tests/wide-test.sh:1: git -C "$DIR" ls-files | wc -l; add a durations row or stop matching' "$T/f9.out" \
  && ok "F9 the hint names the matched line" || bad "F9 no hint: $(grep 'D1' "$T/f9.out" | tr '\n' '|')"

echo "F10: the real tree keeps main's classification, except comment-only suites and BH-8098's cut"
# The suites the old detector put in the set at c84de0d (main when BH-4551 was
# planned), and that detector verbatim, to tell a comment-only match apart.
SNAP="tests/account-lease-cas-test.sh tests/br-split-layout-test.sh tests/checks-suite-test.sh
tests/ci-shard-split-test.sh tests/config-literal-lint.sh tests/env-path-test.sh
tests/fixround-lead-reviews.bh-2200-test.sh tests/fixround-unaddressed-report.bh-2276-test.sh
tests/generated-files-train-test.sh tests/gh-rest-etag-test.sh tests/gh-rest-etag.bh-1322-test.sh
tests/gh-rest-lib-test.sh tests/gh-rest-list-lib-test.sh tests/gh-rest-quota-test.sh
tests/gh-rest-quota.bh-1509-test.sh tests/gh-shim-token-prefix.bh-789-test.sh tests/hold-push-guard.bh-2504-test.sh
tests/jobs-client-modules.bh-1194-test.sh tests/lanes-registry-class-libs.bh-1351-test.sh
tests/lanes-registry.bh-2205-test.sh tests/lead-review-rules-pack.bh-3546-test.sh tests/llm-call-ratchet-test.sh
tests/llm-lane-bind.bh-2580-test.sh tests/model-literal-lint.sh tests/pycache-untracked.bh-1138-test.sh
tests/ratchet-markers-test.sh tests/rb-modules-source-test.sh tests/rb-prepr-gate.bh-1706-test.sh
tests/rb-prepr-rules-pack.bh-3513-test.sh tests/readiness-report-test.sh tests/regenerated-path-conflicts.bh-1162-test.sh
tests/registry-no-commit-test.sh tests/remote-gate-test.sh tests/remote-gate.bh-1597-test.sh
tests/responder-prefetch-test.sh tests/rollup-crash-loud-test.sh tests/rules-pack-contract.bh-3509-test.sh
tests/rules-pack.bh-3510-test.sh tests/share-publish-clean.bh-795-test.sh tests/spec-artifact-test.sh
tests/state-restore-standby.bh-401-test.sh tests/switch-convert-pipeline.bh-2435-test.sh tests/telegram-topics-sync-test.sh
tests/test-impact-gate.bh-1524-test.sh tests/test-impact-test.sh tests/test-impact-why.bh-1524-test.sh
tests/tests-scratch-only-check-test.sh tests/tests-trace-safety-test.sh tests/trap-target-safety-test.sh
tests/triage-state-pr-record.bh-3417-test.sh tests/untriaged-lib.bh-2752-test.sh
tests/verification-map-no-commit-test.sh tests/watchdog-url-tree.bh-2091-test.sh"
OLD_RV='DIR|ROOT|REPO|HERE|D'
OLD_RE='ls-files|--tree|find[[:space:]]+"?\$\{?('"$OLD_RV"')\}?"?|\$\{?('"$OLD_RV"')\}?"?/tests/\*'
"$TI" always > "$T/real.always" 2> "$T/real.err"; rc=$?
[ "$rc" = 0 ] && [ -s "$T/real.always" ] && ok "F10 real always rc 0, non-empty" || bad "F10 real always rc=$rc err=$(cat "$T/real.err")"
# TEST-CHANGE BH-8098: slice C1 of #8050 cut the always set to reads of the
# real checkout on purpose. These snapshot suites left it: 11 whose detector
# hit read a scratch directory and 8 whose catalog pin read no real tree path.
# Any OTHER snapshot suite that leaves the set still fails below.
C1_OUT=" tests/gh-rest-etag-test.sh tests/gh-rest-etag.bh-1322-test.sh tests/gh-rest-lib-test.sh
tests/gh-rest-list-lib-test.sh tests/gh-rest-quota-test.sh tests/gh-rest-quota.bh-1509-test.sh
tests/rules-pack.bh-3510-test.sh tests/state-restore-standby.bh-401-test.sh tests/tests-trace-safety-test.sh
tests/triage-state-pr-record.bh-3417-test.sh tests/untriaged-lib.bh-2752-test.sh
tests/ci-shard-split-test.sh tests/fixround-lead-reviews.bh-2200-test.sh
tests/fixround-unaddressed-report.bh-2276-test.sh tests/hold-push-guard.bh-2504-test.sh
tests/lead-review-rules-pack.bh-3546-test.sh tests/readiness-report-test.sh
tests/remote-gate.bh-1597-test.sh tests/spec-artifact-test.sh "
C1_OUT=$(printf '%s' "$C1_OUT" | tr '\n' ' ')
n=0 commentonly="" lost=""
for s in $SNAP; do
  n=$((n + 1))
  [ -f "$DIR/$s" ] || continue
  grep -qxF "$s" "$T/real.always" && continue
  case "$C1_OUT" in *" $s "*) continue ;; esac
  if grep -E "$OLD_RE" "$DIR/$s" | grep -qvE '^[[:space:]]*#'; then lost="$lost $s"
  else commentonly="$commentonly $s"; fi
done
[ "$n" = 53 ] && ok "F10 the snapshot holds 53 suites" || bad "F10 snapshot holds $n suites"
echo "  comment-only (left the always set):${commentonly:- none}"
[ -z "$lost" ] && ok "F10 no snapshot suite lost for a non-comment match" || bad "F10 lost for non-comment matches:$lost"
case "$commentonly" in
  ""|" tests/rb-prepr-gate.bh-1706-test.sh") ok "F10 only rb-prepr-gate.bh-1706 left, and only for its comment" ;;
  *) bad "F10 comment-only list grew:$commentonly" ;;
esac
# Narrowing never adds: every always suite is one the old detector matched or
# one the catalog lists.
added=""
while IFS= read -r s; do
  grep -qE "$OLD_RE" "$DIR/$s" && continue
  awk -v s="$s" '!/^[[:space:]]*#/ && $1 == s {f = 1} END {exit !f}' "$DIR/catalog/test-impact-always.txt" && continue
  added="$added $s"
done < "$T/real.always"
[ -z "$added" ] && ok "F10 the new detector adds no suite" || bad "F10 added:$added"

echo "F11: a scanner that dies is a failure, never a short set"
mkdir -p "$T/shim"
REAL_AWK=$(command -v awk)
cat > "$T/shim/awk" <<EOF
#!/bin/bash
case "\$*" in *"function mask("*) echo "shim: scanner killed" >&2; exit 1 ;; esac
exec "$REAL_AWK" "\$@"
EOF
chmod +x "$T/shim/awk"
newroot f11
fixture wide \
  'git -C "$DIR" ls-files | wc -l'
PATH="$T/shim:$PATH" "$TI" --root "$R" always > "$R.out" 2> "$R.err"; rc=$?
[ "$rc" != 0 ] && ok "F11 always rc $rc when the scanner dies" || bad "F11 always rc 0 with a dead scanner (out: $(tr '\n' ' ' < "$R.out"))"
grep -q 'shim: scanner killed' "$R.err" && ok "F11 the scanner's stderr is not swallowed" || bad "F11 stderr: $(cat "$R.err")"
PATH="$T/shim:$PATH" "$TI" --root "$R" map > /dev/null 2>&1; rc=$?
[ "$rc" != 0 ] && ok "F11 map rc $rc when the scanner dies" || bad "F11 map rc 0 with a dead scanner"
mkdir -p "$T/h"
HARNESS="$T/h" HARNESS_TEST_SANDBOX=1 PATH="$T/shim:$PATH" "$DIR/bin/fast-lints.sh" --list > "$T/fl.out" 2> "$T/fl.err"; rc=$?
[ "$rc" = 2 ] && ok "F11 fast-lints --list rc 2" || bad "F11 fast-lints --list rc=$rc err=$(cat "$T/fl.err")"
[ ! -s "$T/fl.out" ] && ok "F11 fast-lints --list prints no suite" || bad "F11 fast-lints stdout: $(tr '\n' ' ' < "$T/fl.out")"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
