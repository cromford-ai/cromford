#!/bin/bash
# tests/patch-same-replay.bh-9066-test.sh — bin/patch-same-replay.sh (BH-9066 T6,
# acceptance test 6) over a REAL fixture remote and clone, reads stubbed through
# the PSR_GH_FN / PSR_VERDICTS_FN seams (exported functions). No network.
# Every PR lands on main through a real merge commit, so each pair is compared
# against main as it was before that PR landed, never against today's main.
#
#   PR 1  reviewed R1, head H1 = R1 + a clean merge of main; landed by its own
#         merge commit (base = <merge>^1)                         -> main-merge
#   PR 2  reviewed R2, head H2 = R2 + one more code line          -> full review, "code changed"
#   PR 3  reviewed R3 adds worker/jobs/schema.d/202611041200-bh-1-a.sql and a file
#         naming it; H3 = R3 rebased onto a newer main, the fragment `git mv`d to
#         202611051300-bh-1-a.sql and the reference rewritten -> restamp-rebase
#   PR 4  the verdict read fails                                  -> "verdict read failed"
#   PR 5  batch: H5 = R5 + a clean main merge landed by a train merge L; the PR's
#         own merge commit comes later and its first parent already holds H5
#         (base = L^1)                                           -> main-merge
#   PR 6  reviewed R6 is a commit main already held (an empty diff) -> "base unresolved"
#   PR 7  heads never on main; the merge commit sha cannot be fetched -> "base unresolved"
#   PR 8  R8 adds a fragment; H8 = rebased, restamped, one more code line
#                                                                 -> "restamp plus code change"
#   PR 9  R9 adds a fragment only; H9 renames its suffix          -> "fragment order or suffix changed"
#   PR 1 also carries rows the replay must ignore: a repeated lead row on R1, a
#   human row, a lead-replay: row, a retracted lead row.
#   U1-U6 usage: no --last, a bad --last, no --repo, an unknown flag, no --clone,
#         a --clone that is not a git clone -> exit 2
#   E3    every verdict read fails                                 -> exit 3
#   J1    --json carries the same numbers
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
# Fixed dates: commit shas do not depend on the wall clock.
export GIT_AUTHOR_DATE='2026-11-01T00:00:00Z' GIT_COMMITTER_DATE='2026-11-01T00:00:00Z'
export HARNESS="$DIR"
SCRIPT="$DIR/bin/patch-same-replay.sh"

REMOTE="$T/remote.git"; WK="$T/work"; CL="$T/clone"
w() { git -C "$WK" "$@"; }
commit() { w add -A; w commit -qm "$1"; w rev-parse HEAD; }
land() { w checkout -q main; w merge -q --no-ff --no-edit "$1" >/dev/null; w rev-parse HEAD; }

git init -q --bare -b main "$REMOTE"
git init -q -b main "$WK"
mkdir -p "$WK/worker/jobs/schema.d" "$WK/docs"
seq 1 30 | sed 's/^/line /' > "$WK/f.txt"
printf 'CREATE TABLE IF NOT EXISTS t (id INTEGER);\n' > "$WK/worker/jobs/schema.d/0000-base.sql"
printf 'CREATE TABLE IF NOT EXISTS u (id INTEGER);\n' > "$WK/worker/jobs/schema.d/202611010000-bh-0-base.sql"
M0=$(commit base)
w remote add origin "$REMOTE"; w push -q origin main
# The clone sees only the base main; every PR head reaches it through patch_same_fetch.
git clone -q "$REMOTE" "$CL"

# PR 1: one code line.
w checkout -qb p1; sed -i '10s/.*/line 10 PR1/' "$WK/f.txt"; R1=$(commit pr1)
# PR 2: a new file, then one more code line on top.
w checkout -q main; w checkout -qb p2; printf 'a\n' > "$WK/c2.txt"; R2=$(commit pr2)
printf 'b\n' >> "$WK/c2.txt"; H2=$(commit pr2-more)
# PR 3: a fragment plus a file that names it.
w checkout -q main; w checkout -qb p3
printf 'CREATE TABLE IF NOT EXISTS a (id INTEGER);\n' > "$WK/worker/jobs/schema.d/202611041200-bh-1-a.sql"
printf 'See worker/jobs/schema.d/202611041200-bh-1-a.sql\n' > "$WK/docs/a.md"
R3=$(commit pr3)
# PR 5: one code line.
w checkout -q main; w checkout -qb p5; sed -i '5s/.*/line 5 PR5/' "$WK/f.txt"; R5=$(commit pr5)
# PR 8: a fragment plus a file that names it.
w checkout -q main; w checkout -qb p8; mkdir -p "$WK/docs"
printf 'CREATE TABLE IF NOT EXISTS b (id INTEGER);\n' > "$WK/worker/jobs/schema.d/202611041300-bh-8-b.sql"
printf 'See worker/jobs/schema.d/202611041300-bh-8-b.sql\n' > "$WK/docs/b.md"
R8=$(commit pr8)
# PR 9: a fragment only.
w checkout -q main; w checkout -qb p9
printf 'CREATE TABLE IF NOT EXISTS c (id INTEGER);\n' > "$WK/worker/jobs/schema.d/202611041400-bh-9-c.sql"
R9=$(commit pr9)
# main moves: a far code line and a newer fragment.
w checkout -q main; sed -i '25s/.*/line 25 MAIN/' "$WK/f.txt"
printf 'CREATE TABLE IF NOT EXISTS x (id INTEGER);\n' > "$WK/worker/jobs/schema.d/202611051200-bh-2-x.sql"
M1=$(commit main-2)
# PR 1 head: a clean merge of main. PR 5 head: the same.
w checkout -q p1; w merge -q --no-edit main >/dev/null; H1=$(w rev-parse HEAD)
w checkout -q p5; w merge -q --no-edit main >/dev/null; H5=$(w rev-parse HEAD)
# PR 3 head: rebased onto main, then the fragment restamped past main's newest.
w checkout -q -b p3h "$R3"; w rebase -q main
w mv worker/jobs/schema.d/202611041200-bh-1-a.sql worker/jobs/schema.d/202611051300-bh-1-a.sql
sed -i 's/202611041200-bh-1-a.sql/202611051300-bh-1-a.sql/' "$WK/docs/a.md"
H3=$(commit restamp)
# PR 8 head: the same restamp, plus one code line.
w checkout -q -b p8h "$R8"; w rebase -q main
w mv worker/jobs/schema.d/202611041300-bh-8-b.sql worker/jobs/schema.d/202611051300-bh-8-b.sql
sed -i 's/202611041300-bh-8-b.sql/202611051300-bh-8-b.sql/' "$WK/docs/b.md"
sed -i '15s/.*/line 15 PR8/' "$WK/f.txt"
H8=$(commit restamp-and-code)
# PR 9 head: the fragment suffix renamed (no file names it).
w checkout -q -b p9h "$R9"
w mv worker/jobs/schema.d/202611041400-bh-9-c.sql worker/jobs/schema.d/202611041400-bh-9-renamed.sql
H9=$(commit suffix)
# PR 7: never on main (its merge sha is not fetchable), two code heads.
w checkout -q -b p7 "$M1"; printf 'seven\n' > "$WK/c7.txt"; R7=$(commit pr7)
printf 'more\n' >> "$WK/c7.txt"; H7=$(commit pr7-more)
# PR 6: reviewed R6 = M0, a commit main already held; head one code line.
w checkout -q -b p6 "$M1"; printf 'six\n' > "$WK/c6.txt"; H6=$(commit pr6); R6=$M0

# Land on main. PR 1, 2, 3, 6, 8, 9 by their own merge commits.
MC1=$(land p1); MC2=$(land p2); MC3=$(land p3h); MC6=$(land p6); MC8=$(land p8h); MC9=$(land p9h)
# PR 5: a train branch merges p5, the train lands as L, main moves on (Y), and
# the PR's own merge commit (parents Y and H5) comes last.
w checkout -q -b train main; w merge -q --no-ff --no-edit p5 >/dev/null
L=$(land train)
w checkout -q main; printf 'y\n' > "$WK/y.txt"; Y=$(commit after-train)
MC5=$(w commit-tree "$Y^{tree}" -p "$Y" -p "$H5" -m "Merge pull request #5")
w merge -q --ff-only "$MC5"
w push -q origin main p1 p2 p3 p3h p5 p6 p7 p8 p8h p9h
[ -n "$L" ] && [ "$(git -C "$CL" cat-file -t "$H3" 2>/dev/null)" != commit ] && ok \
  || bad "precondition: the clone must not hold H3 before the replay fetches it"
git -C "$WK" merge-base --is-ancestor "$H5" "$MC5^1" && ok || bad "precondition: PR 5's merge^1 must already hold H5"
MISSING=0123456789abcdef0123456789abcdef01234567

# ---- verdict fixtures
V="$T/v"; mkdir -p "$V"
row() { # row <id> <head> <source> <verdict> <note> [retracted]
  jq -nc --argjson id "$1" --arg h "$2" --arg s "$3" --arg v "$4" --arg n "$5" --arg r "${6:-}" \
    '{id:$id, head_sha:$h, source:$s, verdict:$v, note:$n, review_mode:"full", retracted_at:(if $r == "" then null else $r end)}'
}
rows() { jq -sc '{rows: .}'; }
{ row 1 "$R1" lead MERGE "lead-review: r1"
  row 2 "$R1" lead MERGE "lead-review: r1 again"
  row 3 "$M1" human MERGE "a person"
  row 4 "$H1" lead MERGE "lead-review: h1"
  row 5 "$H1" lead MERGE "lead-replay: main-merge"
  row 6 "$M1" lead BLOCK "lead-review: retracted" "2026-11-02T00:00:00Z"; } | rows > "$V/1.json"
# Rows out of id order on purpose: the replay orders by id.
{ row 12 "$H2" lead MERGE "lead-review: h2"; row 11 "$R2" lead BLOCK "lead-review: r2"; } | rows > "$V/2.json"
{ row 21 "$R3" lead MERGE "lead-review: r3"; row 22 "$H3" lead MERGE "lead-review: h3"; } | rows > "$V/3.json"
{ row 51 "$R5" lead BLOCK "lead-review: r5"; row 52 "$H5" lead MERGE "lead-review: h5"; } | rows > "$V/5.json"
{ row 61 "$R6" lead BLOCK "lead-review: r6"; row 62 "$H6" lead MERGE "lead-review: h6"; } | rows > "$V/6.json"
{ row 71 "$R7" lead BLOCK "lead-review: r7"; row 72 "$H7" lead MERGE "lead-review: h7"; } | rows > "$V/7.json"
{ row 81 "$R8" lead BLOCK "lead-review: r8"; row 82 "$H8" lead MERGE "lead-review: h8"; } | rows > "$V/8.json"
{ row 91 "$R9" lead BLOCK "lead-review: r9"; row 92 "$H9" lead MERGE "lead-review: h9"; } | rows > "$V/9.json"
export V
printf '9\t%s\n8\t%s\n7\t%s\n6\t%s\n5\t%s\n3\t%s\n2\t%s\n1\t%s\n4\t%s\n' \
  "$MC9" "$MC8" "$MISSING" "$MC6" "$MC5" "$MC3" "$MC2" "$MC1" "$MC2" > "$T/merged.tsv"
export MERGED="$T/merged.tsv"
psr_gh() { cat "$MERGED"; }
psr_verdicts() { [ -r "$V/$2.json" ] || return 1; cat "$V/$2.json"; }
psr_vfail() { return 1; }
export -f psr_gh psr_verdicts psr_vfail

run() { PSR_GH_FN=psr_gh PSR_VERDICTS_FN="${VFN:-psr_verdicts}" "$SCRIPT" "$@"; }

OUT=$(VFN=psr_verdicts run --repo Fixture/repo --last 9 --clone "$CL" 2>"$T/err"); rc=$?
[ "$rc" = 0 ] && ok || bad "main run: rc=$rc, want 0; stderr: $(head -3 "$T/err")"

# TSV rows: one per pair, rung per pair.
want_row() { # <label> <expected line>
  grep -qxF "$2" <<<"$OUT" && ok || bad "$1: missing row '$2'; got:
$(grep -P '^\d+\t' <<<"$OUT")"
}
want_row "PR1 merged, base merge^1, main-merge" "$(printf '1\t%s\t%s\tmain-merge\tmain-merge\t-' "$R1" "$H1")"
want_row "PR2 code change" "$(printf '2\t%s\t%s\t-\t-\tcode changed' "$R2" "$H2")"
want_row "PR3 restamp-rebase" "$(printf '3\t%s\t%s\t-\trestamp-rebase\t-' "$R3" "$H3")"
want_row "PR5 batch, base before the landing commit" "$(printf '5\t%s\t%s\tmain-merge\tmain-merge\t-' "$R5" "$H5")"
want_row "PR6 empty diff" "$(printf '6\t%s\t%s\t-\t-\tbase unresolved' "$R6" "$H6")"
want_row "PR7 merge not fetchable" "$(printf '7\t%s\t%s\t-\t-\tbase unresolved' "$R7" "$H7")"
want_row "PR8 restamp plus code" "$(printf '8\t%s\t%s\t-\t-\trestamp plus code change' "$R8" "$H8")"
want_row "PR9 suffix renamed" "$(printf '9\t%s\t%s\t-\t-\tfragment order or suffix changed' "$R9" "$H9")"
n=$(grep -cP '^\d+\t' <<<"$OUT")
[ "$n" = 8 ] && ok || bad "want exactly 8 pair rows (ignored rows must not add pairs), got $n"
# A "base unresolved" pair is never a hit and never "code changed".
grep -qP '^[67]\t.*\t(identical|main-merge|patch-id|restamp|restamp-rebase)\t' <<<"$OUT" \
  && bad "a base-unresolved pair carries a rung" || ok

# Summary lines.
want_line() { grep -qxF "$2" <<<"$OUT" && ok || bad "$1: missing line '$2'"; }
want_line "target"   "Target metric: lead-review-heads-per-merged-pr-p90"
want_line "measured" "measured: 2"
want_line "measured stats" "lead-review heads per merged PR measured: median=2 p90=2 max=2"
want_line "replayed stats" "lead-review heads per merged PR replayed: median=2 p90=2 max=2"
want_line "rung identical"      "rung identical: hits=0 rate=0.0%"
want_line "rung main-merge"     "rung main-merge: hits=2 rate=25.0%"
want_line "rung patch-id"       "rung patch-id: hits=0 rate=0.0%"
want_line "rung restamp"        "rung restamp: hits=0 rate=0.0%"
want_line "rung restamp-rebase" "rung restamp-rebase: hits=1 rate=12.5%"
want_line "rung full-review"    "rung full-review: hits=5 rate=62.5%"
want_line "miss header" "top miss reasons:"
want_line "miss base unresolved" "  2 base unresolved"
want_line "miss code changed" "  1 code changed"
want_line "miss fragment" "  1 fragment order or suffix changed"
want_line "miss restamp plus code" "  1 restamp plus code change"
first=$(grep -n '^Target metric:' <<<"$OUT" | cut -d: -f1); last_row=$(grep -nP '^\d+\t' <<<"$OUT" | tail -1 | cut -d: -f1)
[ -n "$first" ] && [ "$first" -gt "${last_row:-0}" ] && [ "$(sed -n "$((first+1))p" <<<"$OUT")" = "measured: 2" ] && ok \
  || bad "the summary must start with the Target metric line, then the measured line, after the rows"
# The replay writes its bases under refs/psr/ in the clone it is given.
[ "$(git -C "$CL" rev-parse -q --verify refs/psr/base/1)" = "$(git -C "$WK" rev-parse "$MC1^1")" ] && ok \
  || bad "refs/psr/base/1 must be PR 1's merge^1"
[ "$(git -C "$CL" rev-parse -q --verify refs/psr/base/5)" = "$(git -C "$WK" rev-parse "$L^1")" ] && ok \
  || bad "refs/psr/base/5 must be the parent of the train landing commit"

# J1: --json, the same numbers.
J=$(VFN=psr_verdicts run --repo Fixture/repo --last 9 --clone "$CL" --json 2>/dev/null); rc=$?
[ "$rc" = 0 ] && jq -e '.target_metric == "lead-review-heads-per-merged-pr-p90" and .measured == 2
  and .replayed_heads == {median:2, p90:2, max:2} and .rungs["restamp-rebase"].hits == 1
  and .rungs["main-merge"].hits == 2 and .rungs["full-review"].hits == 5 and (.rows | length) == 8
  and any(.top_miss_reasons[]; . == {count:2, reason:"base unresolved"})' <<<"$J" >/dev/null && ok \
  || bad "J1 --json: rc=$rc out=$(head -c 400 <<<"$J")"

# U1-U4: usage.
VFN=psr_verdicts run --repo Fixture/repo --clone "$CL" >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok || bad "U1 no --last: rc=$rc, want 2"
VFN=psr_verdicts run --repo Fixture/repo --last 0 --clone "$CL" >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok || bad "U2 --last 0: rc=$rc, want 2"
VFN=psr_verdicts run --last 4 --clone "$CL" >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok || bad "U3 no --repo: rc=$rc, want 2"
VFN=psr_verdicts run --repo Fixture/repo --last 4 --clone "$CL" --bogus >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok || bad "U4 unknown flag: rc=$rc, want 2"
VFN=psr_verdicts run --repo Fixture/repo --last 4 >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok || bad "U5 no --clone: rc=$rc, want 2"
mkdir -p "$T/notaclone"
VFN=psr_verdicts run --repo Fixture/repo --last 4 --clone "$T/notaclone" >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok || bad "U6 --clone not a git clone: rc=$rc, want 2"

# E3: every verdict read fails.
VFN=psr_vfail run --repo Fixture/repo --last 4 --clone "$CL" >/dev/null 2>&1; rc=$?
[ "$rc" = 3 ] && ok || bad "E3 every verdict read failed: rc=$rc, want 3"

echo "patch-same-replay.bh-9066: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
