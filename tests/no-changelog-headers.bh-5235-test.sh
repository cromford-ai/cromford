#!/bin/bash
# tests/no-changelog-headers.bh-5235-test.sh — the per-ticket changelog-bullet
# lint (BH-5260, BH-5235.0): bin/changelog-header-lint.sh and its rules-pack row.
#
# A comment line whose body is a dash bullet keyed by a ticket (BH-N or #N,
# letter N standing for the digits) is history, and history lives in git and on
# the ticket. Every bullet fixture below is built at runtime so that no line of
# this suite is itself a finding (N1 scans this file too).
#
#   N1. the real tree is clean: rc 0, no output.
#   N2. a // bullet on line 2 of x.js: rc 1 and the exact finding line; line 1 too.
#   N3. #, -- and // comment leaders with BH-N (parenthesised alias), BH-N and #N
#       keys each go red; findings come out by file, then numeric line.
#   N4. inline citations, *.md at any depth, docs/, .harness/ and tests/fixtures/
#       are not findings; the same repo plus one bad.sh names only bad.sh.
#   N5. a directory outside any git work tree: rc 2, stderr reason, no stdout.
#   N6. the catalog row and the pack: --list names it, --only runs it green.
#   N7. the pre-cleanup coord proxy file (a [[path]].js name) goes red.
# Run from anywhere: tests/no-changelog-headers.bh-5235-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LINT="$DIR/bin/changelog-header-lint.sh"
RP="$DIR/bin/rules-pack.sh"
CAT="$DIR/catalog/rules-pack.tsv"
MSG='per-ticket changelog bullet (history lives in git and on the ticket; put the note next to the code it explains)'

[ -n "${T:-}" ] && [ -d "$T" ] || { echo "FAIL: no scratch dir"; exit 1; }
cd "$T" || exit 1

# run <cmd...> — sets RC, OUT, ERR
run() {
  "$@" >"$T/out" 2>"$T/err"; RC=$?
  OUT=$(cat "$T/out"); ERR=$(cat "$T/err")
}

# mkrepo <name> — a fresh git repo at $T/<name>; prints its path
mkrepo() {
  local r="$T/$1"
  scratch_rm "$r" || exit 1; mkdir -p "$r"
  git -C "$r" init -q
  printf '%s\n' "$r"
}
# commit <repo> — add and commit everything
commit() {
  git -C "$1" add -A
  git -C "$1" -c user.email=t@t -c user.name=t commit -qm fixture
}

# --- N1 -------------------------------------------------------------------
run bash "$LINT" "$DIR"
[ "$RC" -eq 0 ] && ok || bad "N1 real tree rc $RC (want 0): $ERR"
[ -z "$OUT" ] && ok || bad "N1 real tree printed findings: $OUT"

# --- N2 -------------------------------------------------------------------
R=$(mkrepo n2)
printf 'const a = 1;\n// - %s-4153: a note\n' BH >"$R/x.js"
commit "$R"
run bash "$LINT" "$R"
[ "$RC" -eq 1 ] && ok || bad "N2 rc $RC (want 1): $ERR"
[ "$OUT" = "x.js:2: $MSG" ] && ok || bad "N2 output [$OUT] (want [x.js:2: $MSG])"

R=$(mkrepo n2b)
printf '// - %s-4153: a note\nconst a = 1;\n' BH >"$R/x.js"
commit "$R"
run bash "$LINT" "$R"
[ "$RC" -eq 1 ] && ok || bad "N2 line-1 rc $RC (want 1): $ERR"
[ "$OUT" = "x.js:1: $MSG" ] && ok || bad "N2 line-1 output [$OUT]"

# --- N3 -------------------------------------------------------------------
R=$(mkrepo n3a)
printf 'set -u\n# - %s-4147 (%s-4140.2): a note\n' BH BH >"$R/x.sh"
commit "$R"
run bash "$LINT" "$R"
[ "$RC" -eq 1 ] && ok || bad "N3 # leader rc $RC (want 1): $ERR"
[ "$OUT" = "x.sh:2: $MSG" ] && ok || bad "N3 # leader output [$OUT]"

R=$(mkrepo n3b)
printf -- '-- - %s-12: x\nSELECT 1;\n' BH >"$R/x.sql"
commit "$R"
run bash "$LINT" "$R"
[ "$RC" -eq 1 ] && ok || bad "N3 -- leader rc $RC (want 1): $ERR"
[ "$OUT" = "x.sql:1: $MSG" ] && ok || bad "N3 -- leader output [$OUT]"

R=$(mkrepo n3c)
printf 'let b;\n\n// - #%s: x\n' 1132 >"$R/y.js"
commit "$R"
run bash "$LINT" "$R"
[ "$RC" -eq 1 ] && ok || bad "N3 #N key rc $RC (want 1): $ERR"
[ "$OUT" = "y.js:3: $MSG" ] && ok || bad "N3 #N key output [$OUT]"

R=$(mkrepo n3d)
mkdir -p "$R/a"
printf 'set -u\n# - %s-4147 (%s-4140.2): a note\n' BH BH >"$R/x.sh"
printf -- '-- - %s-12: x\n' BH >"$R/a/x.sql"
printf 'let b;\n\n// - #%s: x\n' 1132 >"$R/y.js"
printf '/*\n * - %s-7: x\n */\n' BH >"$R/a/z.js"
commit "$R"
run bash "$LINT" "$R"
[ "$RC" -eq 1 ] && ok || bad "N3 combined rc $RC (want 1): $ERR"
n=$(printf '%s\n' "$OUT" | grep -c .)
[ "$n" -eq 4 ] && ok || bad "N3 combined $n findings (want 4): $OUT"
printf '%s\n' "$OUT" | cut -d: -f1 | LC_ALL=C sort -c 2>/dev/null && ok || bad "N3 combined output not sorted by file: $OUT"
[ "$(printf '%s\n' "$OUT" | cut -d: -f1,2 | tr '\n' ' ')" = "a/x.sql:1 a/z.js:2 x.sh:2 y.js:3 " ] \
  && ok || bad "N3 combined file:line set wrong: $OUT"

# Within a file the order is the line number, not its text: 9 before 10.
R=$(mkrepo n3e)
{ for i in 1 2 3 4 5 6 7 8; do printf 'x%s=1\n' "$i"; done
  printf '# - %s-9: a\n# - %s-10: b\n' BH BH; } >"$R/m.sh"
printf '# - %s-11: c\n' BH >"$R/m.sh.bak"
commit "$R"
run bash "$LINT" "$R"
[ "$RC" -eq 1 ] && ok || bad "N3 order rc $RC (want 1): $ERR"
[ "$(printf '%s\n' "$OUT" | cut -d: -f1,2 | tr '\n' ' ')" = "m.sh:9 m.sh:10 m.sh.bak:1 " ] \
  && ok || bad "N3 order: want file then numeric line, got: $OUT"

# --- N4 -------------------------------------------------------------------
R=$(mkrepo n4)
mkdir -p "$R/sub" "$R/docs" "$R/.harness/specs" "$R/tests/fixtures"
printf '// %s-4147: note above code\nconst a = 1;\n' BH >"$R/a.js"
printf '# see %s-4153 for why\n' BH >"$R/b.sh"
printf -- '- %s-4153: x\n' BH >"$R/notes.md"
printf '# - %s-9: x\n' BH >"$R/sub/deep.md"
printf '# - %s-1: x\n' BH >"$R/docs/a.sh"
printf '# - %s-1: x\n' BH >"$R/.harness/specs/x.sh"
printf '# - %s-1: x\n' BH >"$R/tests/fixtures/x.sh"
commit "$R"
run bash "$LINT" "$R"
[ "$RC" -eq 0 ] && ok || bad "N4 exclusions rc $RC (want 0): $OUT $ERR"
[ -z "$OUT" ] && ok || bad "N4 exclusions printed findings: $OUT"
printf '# - %s-2: x\n' BH >"$R/bad.sh"
commit "$R"
run bash "$LINT" "$R"
[ "$RC" -eq 1 ] && ok || bad "N4 control rc $RC (want 1): $ERR"
[ "$OUT" = "bad.sh:1: $MSG" ] && ok || bad "N4 control output [$OUT] (want only bad.sh)"

# --- N5 -------------------------------------------------------------------
mkdir -p "$T/plain"
printf '# - %s-1: x\n' BH >"$T/plain/x.sh"
GIT_CEILING_DIRECTORIES="$T" run bash "$LINT" "$T/plain"
[ "$RC" -eq 2 ] && ok || bad "N5 rc $RC (want 2): $OUT $ERR"
grep -q 'not a git work tree' <<<"$ERR" && ok || bad "N5 stderr [$ERR] lacks the reason"
[ -z "$OUT" ] && ok || bad "N5 printed stdout: $OUT"

# --- N6 -------------------------------------------------------------------
row=$(grep -v '^#' "$CAT" | awk -F'\t' '$1=="changelog-headers"{print $2, $3, $4}')
[ "$row" = "tree cmd bin/changelog-header-lint.sh" ] && ok || bad "N6 catalog row [$row]"
run bash "$RP" --list
[ "$RC" -eq 0 ] && ok || bad "N6 --list rc $RC: $ERR"
grep -q '^changelog-headers' <<<"$OUT" && ok || bad "N6 --list lacks changelog-headers: $OUT"
HARNESS_TEST_SANDBOX=1 run bash "$RP" --runner local --only changelog-headers --tree "$DIR" --out "$T/rp"
[ "$RC" -eq 0 ] && ok || bad "N6 rules-pack --only changelog-headers rc $RC (want 0): $OUT $ERR"

# --- N7 -------------------------------------------------------------------
R=$(mkrepo n7)
CF='console-ui/functions/api/coord/[[path]].js'
mkdir -p "$R/console-ui/functions/api/coord"
if git -C "$DIR" cat-file -e 645b72ecb 2>/dev/null; then
  git -C "$DIR" show "645b72ecb:$CF" >"$R/$CF"
else
  printf '// - %s-2105: a\n// - %s-1946: b\n// - #%s: c\nconst x = 1;\n' BH BH 1132 >"$R/$CF"
fi
commit "$R"
run bash "$LINT" "$R"
[ "$RC" -eq 1 ] && ok || bad "N7 pre-cleanup coord rc $RC (want 1): $ERR"
n=$(printf '%s\n' "$OUT" | grep -c .)
[ "$n" -ge 3 ] && ok || bad "N7 only $n findings (want >= 3)"
stray=$(printf '%s\n' "$OUT" | grep -vF "$CF:" || true)
[ -z "$stray" ] && ok || bad "N7 findings not naming $CF: $stray"

echo "no-changelog-headers: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
