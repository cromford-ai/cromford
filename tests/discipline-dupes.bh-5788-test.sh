#!/bin/bash
# tests/discipline-dupes.bh-5788-test.sh — no two build-discipline rules claim
# the same D number (BH-5788 D).
#
# The builtin rp_discipline_dupes (bin/lib/rules-pack-checks.sh) reads every
# `- **D<n> ` rule opener in <tree>/prompts/build-discipline.md and reports
# each number that was already seen.
#   D1  two D64 openers: one finding naming both lines
#   D2  this repo's prompts/build-discipline.md is clean; the catalog row exists
#       and the real bin/rules-pack.sh runs it on a fixture tree
#   D3  a gap and an out-of-order pair are not findings
#   D4  D6 and D60 are distinct; D64 named in prose is not an opener; no file
#       is clean; three openers of one number are two findings
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/discipline-dupes.bh-5788-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# shellcheck source=../bin/lib/rules-pack-checks.sh
. "$DIR/bin/lib/rules-pack-checks.sh" || { echo "FAIL: cannot source bin/lib/rules-pack-checks.sh"; exit 1; }
command -v rp_discipline_dupes >/dev/null 2>&1 || bad "rp_discipline_dupes is not defined in bin/lib/rules-pack-checks.sh"

F=prompts/build-discipline.md
# tree <tag> <lines...> — a fixture tree whose build-discipline.md is <lines>.
tree() {
  R="$T/$1"; shift; scratch_rm "$R"; mkdir -p "$R/prompts"
  printf '%s\n' "$@" > "$R/$F"
}
lint() { OUT=$(rp_discipline_dupes "$R" 2>"$T/err"); RC=$?; }

# ── D1 a duplicate number ─────────────────────────────────────────────────────
tree d1 '# Build discipline' \
        '- **D64 Fixtures look fake on purpose.** One.' \
        '- **D63 Prove each new test can fail.** Two.' \
        '' \
        '- **D64 Fixtures again.** Three.'
lint
[ "$RC" = 1 ] && ok || bad "D1 rc $RC (want 1): $OUT $(cat "$T/err")"
[ "$OUT" = "$F:5: duplicate D64 (first at line 2)" ] && ok \
  || bad "D1 finding [$OUT] (want [$F:5: duplicate D64 (first at line 2)])"

# ── D2 the real file, the row, the real pack ──────────────────────────────────
OUT=$(rp_discipline_dupes "$DIR" 2>&1); RC=$?
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "D2 this repo's $F must be clean, rc $RC out [$OUT]"
N=$(grep -c $'^discipline-dupes\ttree\tbuiltin\trp_discipline_dupes\t' "$DIR/catalog/rules-pack.tsv")
[ "$N" = 1 ] && ok || bad "D2 catalog/rules-pack.tsv must carry one discipline-dupes tree builtin row (got $N)"
# The pack judges a tree component at HEAD and, if red, again at the fork; a
# duplicate that main does not have is a finding.
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_AUTHOR_DATE="@1700000000 +0000" GIT_COMMITTER_DATE="@1700000000 +0000"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
tree d2p '- **D1 One.** x' '- **D2 Two.** y'
git init -q -b main "$R"; git -C "$R" add -A; git -C "$R" commit -qm base; BASE=$(git -C "$R" rev-parse HEAD)
printf '%s\n' '- **D2 Again.** z' >> "$R/$F"; git -C "$R" commit -qam dupe
mkdir -p "$T/nolg"
env HARNESS="$T/nolg" bash "$DIR/bin/rules-pack.sh" --tree "$R" --base "$BASE" --runner local \
  --out "$T/o2" --only discipline-dupes >"$T/pack.out" 2>"$T/pack.err"; RC=$?
[ "$RC" = 1 ] && ok || bad "D2 pack rc $RC (want 1), err [$(tail -3 "$T/pack.err")]"
[ "$(cat "$T/pack.out")" = "discipline-dupes: $F:3: duplicate D2 (first at line 2)" ] && ok \
  || bad "D2 pack stdout [$(cat "$T/pack.out")]"

# ── D3 gaps and order are not judged ──────────────────────────────────────────
tree d3 '- **D1 a.** x' '- **D2 b.** x' '- **D5 c.** x' '- **D4 d.** x'
lint
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "D3 a gap and an out-of-order pair must be clean, rc $RC out [$OUT]"

# ── D4 D6 vs D60, prose mentions, no file, three openers ──────────────────────
tree d4 '- **D6 Record true exit codes.** x' '- **D60 A test reads nothing that moves.** x'
lint
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "D4 D6 and D60 are distinct, rc $RC out [$OUT]"
tree d4p '- **D64 Fixtures look fake.** See D64.' 'Prose that cites D64 twice: D64.' '  - **D64 indented is not an opener** x'
lint
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "D4 D64 in prose is not an opener, rc $RC out [$OUT]"
R="$T/d4none"; mkdir -p "$R"
lint
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "D4 a tree with no $F must be clean, rc $RC out [$OUT]"
tree d4t '- **D7 a.** x' '- **D7 b.** x' '- **D7 c.** x'
lint
[ "$RC" = 1 ] && [ "$OUT" = "$F:2: duplicate D7 (first at line 1)
$F:3: duplicate D7 (first at line 1)" ] && ok || bad "D4 three openers must be two findings, rc $RC out [$OUT]"

echo "discipline-dupes.bh-5788: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
