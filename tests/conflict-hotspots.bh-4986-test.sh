#!/bin/bash
# tests/conflict-hotspots.bh-4986-test.sh — BH-4986 (BH-4975.1): which files
# cause merge conflicts and rebases?
#
# Driven, not grepped: every case runs the shipped bin/conflict-hotspots.sh
# through its CLI against a fixture git repo built here with real `git merge`.
# PRs land as merge commits on main, and a branch is brought up to date by
# merging main into it (the harness's mc_rebase does exactly that), so the
# fixture's conflicted sync merges are real ones. The assertions are on the
# TSV rows, the markdown table, the footer and the rc.
#
# The clock: NOW is read ONCE below and every commit date is derived from it,
# and the CLI is always called with --now "$NOW", so nothing here depends on
# what day the suite runs.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/conflict-hotspots.bh-4986-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
CLI="$DIR/bin/conflict-hotspots.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }

NOW=$(date +%s)
mkdir -p "$T/tmp"
export TMPDIR="$T/tmp"

# at <days-ago> <git args...>: run git in $R with both dates pinned.
at() {
  local d=$1; shift
  GIT_AUTHOR_DATE="@$((NOW - d*86400)) +0000" GIT_COMMITTER_DATE="@$((NOW - d*86400)) +0000" \
    git -C "$R" "$@" >/dev/null 2>&1
}
newrepo() {
  R=$1
  git init -q -b main "$R"
  git -C "$R" config user.name fixture
  git -C "$R" config user.email fixture@example.invalid
  git -C "$R" config commit.gpgsign false
}
SYNC="Merge remote-tracking branch 'origin/main' into HEAD"

# --- fixture 1 -------------------------------------------------------------
newrepo "$T/repo"
# d41..d39, outside a 30-day window: O conflicts on aold.txt, syncs, merges.
echo base > "$R/aold.txt"; at 41 add -A; at 41 commit -q -m init
at 41 checkout -q -b O; echo O >> "$R/aold.txt"; at 41 commit -q -am "O edits aold"
at 41 checkout -q main; echo M >> "$R/aold.txt"; at 41 commit -q -am "main edits aold"
at 40 checkout -q O; at 40 merge -q main
printf 'base\nO\nM\n' > "$R/aold.txt"; at 40 add aold.txt; at 40 commit -q -m "$SYNC"
at 39 checkout -q main; at 39 merge -q --no-ff O -m "Merge pull request #9 from x/O"
# d10 base
echo hot > "$R/hot.txt"; echo cold > "$R/caold.txt"; echo '{}' > "$R/reg.json"
at 10 add -A; at 10 commit -q -m "base files"
# d9 branches. A touches hot.txt AND reg.json: reg.json is then on the main
# side of B's sync and on neither branch, so it is one-sided.
at 9 checkout -q -b A main; echo A >> "$R/hot.txt"; echo '{"a":1}' > "$R/reg.json"; at 9 commit -q -am "A"
at 9 checkout -q -b B main; echo B >> "$R/hot.txt"; at 9 commit -q -am "B"
at 9 checkout -q -b C main; echo cold2 >> "$R/caold.txt"; at 9 commit -q -am "C"
at 9 checkout -q -b D main; echo D >> "$R/hot.txt"; at 5 commit -q -am "D"
# d8: A merges.
at 8 checkout -q main; at 8 merge -q --no-ff A -m "Merge pull request #1 from x/A"
# d7: B syncs and conflicts on hot.txt; C syncs clean.
at 7 checkout -q B; at 7 merge -q main
printf 'hot\nA\nB\n' > "$R/hot.txt"; at 7 add hot.txt; at 7 commit -q -m "$SYNC"
at 7 checkout -q C; at 7 merge -q --no-edit main
# d6: B and C merge.
at 6 checkout -q main; at 6 merge -q --no-ff B -m "Merge pull request #2 from x/B"
at 6 merge -q --no-ff C -m "C title (#3)"

fixture_ok=1
[ "$(git -C "$R" log --first-parent --merges --format=%s main | wc -l)" -eq 4 ] || fixture_ok=0
[ "$(git -C "$R" rev-list --merges main | wc -l)" -eq 7 ] || fixture_ok=0
[ -z "$(git -C "$R" status --porcelain)" ] || fixture_ok=0
check "fixture repo built as designed" '[ "$fixture_ok" = 1 ]'

STATUS0=$(git -C "$R" status --porcelain; git -C "$R" for-each-ref)

run() { OUT=$("$CLI" "$@" 2>"$T/err"); RC=$?; }
row() { printf '%s\n' "$OUT" | awk -F'\t' -v p="$1" '$1 == p'; }
field() { row "$1" | cut -f"$2"; }

# 1. Two branches adding to the same file rank that file first.
run -C "$T/repo" --ref main --now "$NOW" --branches ''
OUT1=$OUT
check "case1 rc 0 (rc=$RC)" '[ "$RC" = 0 ]'
check "case1 header" '[ "$(printf "%s\n" "$OUT" | sed -n 1p)" = "$(printf "path\tconflicts\trebases\tprs")" ]'
check "case1 hot.txt first" '[ "$(printf "%s\n" "$OUT" | sed -n 2p | cut -f1)" = hot.txt ]'
check "case1 hot.txt conflicts=1" '[ "$(field hot.txt 2)" = 1 ]'
check "case1 hot.txt prs has #2" 'case ",$(field hot.txt 4)," in *",#2,"*) true ;; *) false ;; esac'

# 2. A clean sync is not a conflict.
check "case2 caold.txt never conflicts" '[ -z "$(printf "%s\n" "$OUT" | awk -F"\t" "\$1==\"caold.txt\" && \$2>0")" ]'
check "case2 #3 in no conflicting row" '[ -z "$(printf "%s\n" "$OUT" | awk -F"\t" "NR>1 && \$2>0 && (\",\" \$4 \",\") ~ /,#3,/")" ]'

# 3. The window is honoured.
check "case3 aold.txt absent at 30 days" '[ -z "$(row aold.txt)" ]'
run -C "$T/repo" --ref main --now "$NOW" --branches '' --days 60
check "case3 rc 0 at 60 days" '[ "$RC" = 0 ]'
check "case3 aold.txt conflicts=1 at 60 days" '[ "$(field aold.txt 2)" = 1 ]'
check "case3 aold.txt names #9" '[ "$(field aold.txt 4)" = "#9" ]'
# Rank: aold.txt and hot.txt tie on conflicts and rebases, so path order
# decides; with branch D, hot.txt has more conflicts and goes first.
paths() { printf '%s\n' "$OUT" | awk -F'\t' 'NR > 1 && !/^#/ { printf "%s ", $1 }'; }
check "case3 tie ranks by path" '[ "$(paths)" = "aold.txt hot.txt " ]'
run -C "$T/repo" --ref main --now "$NOW" --branches refs/heads/ --days 60
check "case3 conflicts rank first" '[ "$(paths)" = "hot.txt aold.txt " ]'

# 3b. A PR merged inside the window counts only its syncs committed inside it.
newrepo "$T/late"
echo e > "$R/early.txt"; at 40 add -A; at 40 commit -q -m base
at 38 checkout -q -b E; echo E >> "$R/early.txt"; at 38 commit -q -am E
at 37 checkout -q main; echo M >> "$R/early.txt"; at 37 commit -q -am "main moves"
at 35 checkout -q E; at 35 merge -q main
printf 'e\nE\nM\n' > "$R/early.txt"; at 35 add early.txt; at 35 commit -q -m "$SYNC"
at 25 checkout -q main; at 25 merge -q --no-ff E -m "Merge pull request #21 from x/E"
R="$T/repo"
run -C "$T/late" --ref main --now "$NOW" --branches ''
check "case3b old sync not counted" '[ -z "$(row early.txt)" ]'
check "case3b PR counted, sync not" 'printf "%s\n" "$OUT" | tail -n 1 | grep -q " pr_merges=1 sync_merges=0 "'
run -C "$T/late" --ref main --now "$NOW" --branches '' --days 60
check "case3b sync counted at 60 days" '[ "$(field early.txt 4)" = "#21" ]'

# 4. Conflicted unmerged branches count.
run -C "$T/repo" --ref main --now "$NOW" --branches refs/heads/
check "case4 rc 0" '[ "$RC" = 0 ]'
check "case4 hot.txt conflicts=2" '[ "$(field hot.txt 2)" = 2 ]'
check "case4 hot.txt prs = #2,D" '[ "$(field hot.txt 4)" = "#2,D" ]'
check "case4 footer counts D" 'printf "%s\n" "$OUT" | tail -n 1 | grep -q " branches_conflicted=1"'
OUT=$OUT1
check "case4 back to 1 without branches" '[ "$(field hot.txt 2)" = 1 ]'

# 5. Rebase column.
check "case5 hot.txt rebases>=1" '[ "$(field hot.txt 3)" -ge 1 ] 2>/dev/null'
check "case5 reg.json absent" '[ -z "$(row reg.json)" ]'
check "case5 caold.txt absent" '[ -z "$(row caold.txt)" ]'

# 6. Footer.
check "case6 footer" 'printf "%s\n" "$OUT" | tail -n 1 | grep -Eq "^# ref=[0-9a-f]{12} .* pr_merges=3 sync_merges=2 conflicted_syncs=1 "'
check "case6 exactly one data row" '[ "$(printf "%s\n" "$OUT" | grep -vc "^#")" = 2 ]'

# 7. Merge-train attribution: the member's sync is the member's, not the train's.
newrepo "$T/train"
echo h > "$R/hot2.txt"; at 5 add -A; at 5 commit -q -m base
at 5 checkout -q -b m; echo m >> "$R/hot2.txt"; at 5 commit -q -am m
at 4 checkout -q main; echo main2 >> "$R/hot2.txt"; at 4 commit -q -am "main moves"
at 3 checkout -q m; at 3 merge -q main
printf 'h\nm\nmain2\n' > "$R/hot2.txt"; at 3 add hot2.txt; at 3 commit -q -m "$SYNC"
at 3 checkout -q -b T main
at 2 merge -q --no-ff m -m "Merge pull request #11 from x/m"
at 1 checkout -q main; at 1 merge -q --no-ff T -m "merge train: 1 approved PRs (#12)"
R="$T/repo"
run -C "$T/train" --ref main --now "$NOW" --branches ''
check "case7 rc 0" '[ "$RC" = 0 ]'
check "case7 hot2.txt conflicts=1" '[ "$(field hot2.txt 2)" = 1 ]'
check "case7 hot2.txt names #11 not #12" '[ "$(field hot2.txt 4)" = "#11" ]'
check "case7 train merges counted" 'printf "%s\n" "$OUT" | tail -n 1 | grep -q " pr_merges=1 sync_merges=1 conflicted_syncs=1 "'

# 8. Markdown.
run -C "$T/repo" --ref main --now "$NOW" --branches '' --markdown --top 1 --repo example-org/cromford
SHA12=$(git -C "$T/repo" rev-parse --short=12 main)
check "case8 rc 0" '[ "$RC" = 0 ]'
check "case8 table header" 'grep -qxF "| # | File | Conflicts | Rebases | PRs involved |" <<<"$OUT"'
DATA=$(printf '%s\n' "$OUT" | grep -E '^\| [0-9]+ \|')
check "case8 one data row" '[ "$(printf "%s\n" "$DATA" | grep -c .)" = 1 ]'
check "case8 row is hot.txt" 'grep -qF "hot.txt" <<<"$DATA"'
check "case8 row links #2" 'grep -qF "https://github.com/example-org/cromford/pull/2" <<<"$DATA"'
check "case8 generated by names sha" 'printf "%s\n" "$OUT" | grep -i "generated by" | grep -qF "$SHA12"'

# 9. Shallow repo refused.
git clone -q --depth 1 "file://$T/repo" "$T/shallow" 2>/dev/null
run -C "$T/shallow" --ref main --now "$NOW"
check "case9 shallow rc 3 (rc=$RC)" '[ "$RC" = 3 ]'
check "case9 shallow stdout empty" '[ -z "$OUT" ]'
check "case9 shallow says unshallow" 'grep -q unshallow "$T/err"'

# 10. Bad input.
run -C "$T/repo" --ref main --now "$NOW" --days x
check "case10 --days x rc 2 (rc=$RC)" '[ "$RC" = 2 ]'
run -C "$T/repo" --ref main --now "$NOW" --repo 'not a slug'
check "case10 --repo bad rc 2 (rc=$RC)" '[ "$RC" = 2 ]'
mkdir -p "$T/notgit"
run -C "$T/notgit" --ref main --now "$NOW"
check "case10 not a repo rc 1 (rc=$RC)" '[ "$RC" = 1 ]'
check "case10 not a repo stdout empty" '[ -z "$OUT" ]'
run -C "$T/repo" --ref nosuchref --now "$NOW"
check "case10 bad ref rc 1 (rc=$RC)" '[ "$RC" = 1 ]'
check "case10 bad ref stdout empty" '[ -z "$OUT" ]'

# 12. A replay reads .gitattributes from the merge's own commit, not the
# working tree. u.txt was merge=union when P synced, so that sync merged
# clean; main dropped the union line afterwards, and the checkout the CLI
# runs in has no union line at all. Still not a conflict, still a rebase.
newrepo "$T/attrs"
echo u > "$R/u.txt"; echo 'u.txt merge=union' > "$R/.gitattributes"
at 9 add -A; at 9 commit -q -m base
at 8 checkout -q -b P; echo P >> "$R/u.txt"; at 8 commit -q -am P
at 7 checkout -q main; echo M >> "$R/u.txt"; at 7 commit -q -am "main edits u"
at 6 checkout -q P; at 6 merge -q --no-edit main
at 5 checkout -q main; : > "$R/.gitattributes"; at 5 commit -q -am "main drops the union line"
at 4 merge -q --no-ff P -m "Merge pull request #31 from x/P"
attrs_ok=1
[ "$(git -C "$R" log --merges --format=%s main | wc -l)" -eq 2 ] || attrs_ok=0
[ -z "$(git -C "$R" status --porcelain)" ] || attrs_ok=0
[ -s "$R/.gitattributes" ] && attrs_ok=0
check "case12 fixture built as designed" '[ "$attrs_ok" = 1 ]'
R="$T/repo"
run -C "$T/attrs" --ref main --now "$NOW" --branches ''
check "case12 rc 0 (rc=$RC)" '[ "$RC" = 0 ]'
check "case12 union-at-the-time is not a conflict" '[ "$(field u.txt 2)" = 0 ]'
check "case12 still a rebase for #31" '[ "$(field u.txt 3)" = 1 ] && [ "$(field u.txt 4)" = "#31" ]'
check "case12 footer no conflicted sync" 'printf "%s\n" "$OUT" | tail -n 1 | grep -q " sync_merges=1 conflicted_syncs=0 "'

# 13. An unmerged branch is replayed against the ref as it stood at its tip,
# not today. S and F both edit s.txt from base; F's tip comes after main
# changed s.txt (it is dirty), S's tip comes before (only a later main made it
# dirty, which is staleness, not a hotspot).
newrepo "$T/stale"
echo s > "$R/s.txt"; at 9 add -A; at 9 commit -q -m base
at 8 checkout -q -b S; echo S >> "$R/s.txt"; at 8 commit -q -am S
at 6 checkout -q main; echo M >> "$R/s.txt"; at 6 commit -q -am "main edits s"
at 9 checkout -q -b F main~1; echo F >> "$R/s.txt"; at 4 commit -q -am F
at 2 checkout -q main; echo M2 > "$R/other.txt"; at 2 add -A; at 2 commit -q -m "main moves on"
R="$T/repo"
run -C "$T/stale" --ref main --now "$NOW" --branches refs/heads/
check "case13 rc 0 (rc=$RC)" '[ "$RC" = 0 ]'
check "case13 s.txt names F only" '[ "$(field s.txt 2)" = 1 ] && [ "$(field s.txt 4)" = F ]'
check "case13 footer scans both, F conflicts" 'printf "%s\n" "$OUT" | tail -n 1 | grep -q " branches_scanned=2 branches_conflicted=1 "'

# 11. Read-only.
STATUS1=$(git -C "$T/repo" status --porcelain; git -C "$T/repo" for-each-ref)
check "case11 repo unchanged" '[ "$STATUS0" = "$STATUS1" ]'
check "case11 no work dir left" '[ -z "$(find "$T/tmp" -maxdepth 1 -name "conflict-hotspots.*")" ]'

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
