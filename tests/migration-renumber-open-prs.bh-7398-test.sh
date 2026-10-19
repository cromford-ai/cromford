#!/bin/bash
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# tests/migration-renumber-open-prs.bh-7398-test.sh — BH-7398: a migration
# number another OPEN PR holds is renumbered too (pre-PR, and at every rebase
# where the older PR keeps it), a bare self-reference (RAISE text, a test's
# '0270: ...') moves with the file, and a lock key that is not the file's own
# is reported.
#
#   O  the open-PR taken set and the tie-break (O1-O16).
#   R  bare-number references, map kind B (R1-R8).
#   L  mnr_lock_notes (L1-L8).
#   C  the callers: the pr.sh block (C1), a real mc_rebase (C2, C4), the pool
#      twin rebase_job_run (C3).
#   X  the replay of the 16 PRs the ticket lists (X0 without, X1 with).
#   S  the composed worker/jobs schema reads the seeded rows (S1).
#
# Run from anywhere: bash tests/migration-renumber-open-prs.bh-7398-test.sh   (exit 0 = all pass)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v git  >/dev/null || { echo "git missing — skipping";  exit 0; }
command -v jq   >/dev/null || { echo "jq missing — skipping";   exit 0; }
command -v perl >/dev/null || { echo "perl missing — skipping"; exit 0; }
LIB="$DIR/bin/lib/migration-renumber.sh"
RB="$DIR/bin/lib/rb/pr.sh"
REALGIT=$(command -v git)
SLUG=example-org/demo-os
GHURL="https://github.com/$SLUG.git"
TOKURL="https://x-access-token:tok-fixture-secret@github.com/$SLUG.git"

export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.email t@example.com
git config --global user.name  t
git config --global init.defaultBranch main
git config --global commit.gpgsign false
git config --global protocol.file.allow always
git config --global advice.detachedHead false
git config --global "url.$T/origin.git.insteadOf" "https://x-access-token@github.com/$SLUG.git"
git config --global "url.$T/origin.git.insteadOf" "$GHURL" --add
git config --global "url.$T/origin.git.insteadOf" "$TOKURL" --add
unset MNR_DIR MNR_MODE MNR_LOCK_PREFIX MNR_OPEN_PRS MNR_OPEN_PRS_MAX
export T

lk() { ( . "$LIB" 2>/dev/null; mnr_lock_int "$1" ) 2>/dev/null; }
S="$T/seed"; U="$T/u"; OJ="$T/open.json"; export OJ U

# reset_origin — a bare origin whose main holds 0001, 0213 and 0269 (the
# ticket's "main ends at 0269"); no open PR.
reset_origin() {
  local f
  rm -rf "$T/origin.git" "$S"; printf '[]' > "$OJ"; rm -f "$T/list.rc" "$T/list-args"
  "$REALGIT" init -q --bare "$T/origin.git"
  "$REALGIT" clone -q "$T/origin.git" "$S" 2>/dev/null
  mkdir -p "$S/prisma/sql"
  for f in 0001_init.sql 0213_project-5_import.sql 0269_last.sql; do
    printf -- '-- migration:%s base\nSELECT pg_advisory_xact_lock(%s);\n' "${f%%_*}" "$(lk mk0003)" > "$S/prisma/sql/$f"
  done
  "$REALGIT" -C "$S" add -A && "$REALGIT" -C "$S" commit -qm base
  "$REALGIT" -C "$S" push -q origin main 2>/dev/null
}
# jadd <n> <head-ref> [draft] [base] — one row in the stubbed open PR list.
jadd() {
  jq -c --argjson n "$1" --arg h "$2" --argjson d "${3:-false}" --arg b "${4:-main}" \
    '. + [{number:$n, head:{ref:$h}, draft:$d, base:{ref:$b}}]' "$OJ" > "$OJ.n" && mv "$OJ.n" "$OJ"
}
# opr <n> <head-ref> <file...> — an open PR: a branch off main that ADDS the
# files (a bare name goes under prisma/sql/), published as refs/pull/<n>/head.
opr() {
  local n="$1" h="$2" f p; shift 2
  "$REALGIT" -C "$S" checkout -q -B "$h" origin/main 2>/dev/null || "$REALGIT" -C "$S" checkout -q -B "$h" main
  for f in "$@"; do
    case "$f" in */*) p="$f" ;; *) p="prisma/sql/$f" ;; esac
    mkdir -p "$S/$(dirname "$p")"; printf -- '-- pr %s\n' "$n" > "$S/$p"
  done
  "$REALGIT" -C "$S" add -A && "$REALGIT" -C "$S" commit -qm "pr $n" --allow-empty
  "$REALGIT" -C "$S" push -q -f origin "$h" 2>/dev/null
  "$REALGIT" -C "$T/origin.git" update-ref "refs/pull/$n/head" "$("$REALGIT" -C "$S" rev-parse HEAD)"
  "$REALGIT" -C "$S" checkout -q main
  jadd "$n" "$h" "${OPR_DRAFT:-false}" "${OPR_BASE:-main}"
}
# mig <path> <NNNN> [extra text] — a branch migration in project-6's shape.
mig() {
  mkdir -p "$U/$(dirname "$1")"
  printf -- '-- migration:%s lock "mk%s"\nSELECT pg_advisory_xact_lock(%s);\n%s\n' "$2" "$2" "$(lk "mk$2")" "${3:-}" > "$U/$1"
}
# selfb <branch> — the PR branch under test: a clone of origin (url as given,
# so `remote.origin.url` is the github url), on <branch> off origin/main.
selfb() {
  scratch_rm "$U" || exit 1
  "$REALGIT" clone -q "${SELF_URL:-$GHURL}" "$U" 2>/dev/null
  "$REALGIT" -C "$U" checkout -q -b "$1" origin/main
}
commitb() { git -C "$U" add -A && git -C "$U" commit -qm "${1:-branch}"; }
# fix <self-branch> <self-pr> [env...] — mnr_fix over $U with the stubbed list.
fix() {
  local sb="$1" sp="$2"; shift 2
  ( cd "$T" && env MNR_DIR=prisma/sql MNR_LOCK_PREFIX=mk MNR_OPEN_PRS="${MNR_OPEN_PRS-1}" SB="$sb" SP="$sp" "$@" bash -c '
      gh_rest_pr_list_all() { printf "%s\n" "$*" >> "$T/list-args"
        if [ -s "$T/list.rc" ]; then GH_REST_REASON=rate_limited; return "$(cat "$T/list.rc")"; fi
        cat "$OJ"; }
      . "$0" || exit 9; mnr_fix "$U" origin/main tproj "$SB" "$SP"' "$LIB" ) > "$T/out" 2>"$T/err"
  RC=$?
}
files() { git -C "$U" ls-files prisma/sql | sed 's|^prisma/sql/||' | tr '\n' ' '; }
has()   { git -C "$U" ls-files --error-unmatch "$1" >/dev/null 2>&1; }
# pr-scoped: ok $U is a fixture repo this test builds; its origin/main is a fixture ref, not the PR range
nc()    { git -C "$U" rev-list --count origin/main..HEAD; }
norefs() { [ -z "$(git -C "$U" for-each-ref refs/mnr-open/)" ]; }

# ============================================================================
# O. the open-PR taken set
# ============================================================================
# O1 — self #20, the older open #10 adds 0270_a: self moves above it.
reset_origin; opr 10 ticket/bh-10 0270_a.sql
selfb ticket/bh-20; mig prisma/sql/0270_b.sql 0270; commitb; fix ticket/bh-20 20
[ "$RC" = 0 ] && has prisma/sql/0271_b.sql && ! has prisma/sql/0270_b.sql && ok || bad "O1: 0270_b -> 0271_b (rc $RC, files: $(files), err: $(cat "$T/err"))"
grep -qxF "0270 is taken by open PR #10 (0270_a.sql); this PR's number is 0271 (prisma/sql/0270_b.sql -> prisma/sql/0271_b.sql)" "$T/out" \
  && ok || bad "O1: the open-PR message (got: $(cat "$T/out"))"
grep -qxF 'Union-resolved: prisma/sql/0270_b.sql -> prisma/sql/0271_b.sql (BH-7365, migration renumbered)' <(git -C "$U" log -1 --format=%B) \
  && ok || bad "O1: the trailer (got: $(git -C "$U" log -1 --format=%B))"
grep -qF 'migration:0271 lock "mk0271"' "$U/prisma/sql/0271_b.sql" && ok || bad "O1: the moved file's own references (got: $(head -1 "$U/prisma/sql/0271_b.sql"))"
# O15 (part) — no fetched ref is left after a read.
norefs && ok || bad "O15: refs/mnr-open/ must be empty after O1 (got: $(git -C "$U" for-each-ref refs/mnr-open/))"

# O2 — pre-PR (no self PR): every open PR counts, even a newer number.
reset_origin; opr 30 ticket/bh-30 0270_a.sql
selfb ticket/bh-20; mig prisma/sql/0270_b.sql 0270; commitb; fix ticket/bh-20 ""
[ "$RC" = 0 ] && has prisma/sql/0271_b.sql && ok || bad "O2: pre-PR yields to open #30 (rc $RC, files: $(files))"
grep -qF "taken by open PR #30 (0270_a.sql)" "$T/out" && ok || bad "O2: names #30 (got: $(cat "$T/out"))"

# O3 — a draft open PR counts.
reset_origin; OPR_DRAFT=true opr 10 ticket/bh-10 0270_a.sql
selfb ticket/bh-20; mig prisma/sql/0270_b.sql 0270; commitb; fix ticket/bh-20 20
[ "$RC" = 0 ] && has prisma/sql/0271_b.sql && ok || bad "O3: a draft counts (rc $RC, files: $(files))"

# O4 — an open PR stacked on another branch counts.
reset_origin; OPR_BASE=ticket/parent opr 10 ticket/bh-10 0270_a.sql
selfb ticket/bh-20; mig prisma/sql/0270_b.sql 0270; commitb; fix ticket/bh-20 20
[ "$RC" = 0 ] && has prisma/sql/0271_b.sql && ok || bad "O4: a stacked open PR counts (rc $RC, files: $(files))"

# O5 — 150 open PRs, two REST pages; the hit is #149, on page 2. The real
# gh_rest_pr_list_all pages; only gh_rest answers from page files.
reset_origin
for n in $(seq 1 150); do
  [ "$n" = 149 ] && continue
  "$REALGIT" -C "$T/origin.git" update-ref "refs/pull/$n/head" "$("$REALGIT" -C "$T/origin.git" rev-parse main)"
  jadd "$n" "feature/p$n"
done
opr 149 feature/p149 0270_a.sql
jq -c 'sort_by(.number) | .[0:100]' "$OJ" > "$T/page1.json"; jq -c 'sort_by(.number) | .[100:]' "$OJ" > "$T/page2.json"
selfb ticket/bh-200; mig prisma/sql/0270_b.sql 0270; commitb
( cd "$T" && env MNR_DIR=prisma/sql MNR_LOCK_PREFIX=mk MNR_OPEN_PRS=1 bash -c '
    _gh_rest_args_ok() { return 0; }; _gh_rest_bad_args() { return 0; }
    gh_rest() { local p=1 a; for a in "$@"; do case "$a" in page=*) p=${a#page=} ;; esac; done
      printf "%s\n" "$p" >> "$T/pages"; if [ -f "$T/page$p.json" ] && [ "$p" -le 2 ]; then cat "$T/page$p.json"; else printf "[]"; fi; }
    . "$1" || exit 9; . "$0" || exit 9; mnr_fix "$U" origin/main tproj ticket/bh-200 200' "$LIB" "$DIR/bin/lib/gh-rest-list.sh" ) > "$T/out" 2>"$T/err"; RC=$?
[ "$RC" = 0 ] && has prisma/sql/0271_b.sql && grep -qF "taken by open PR #149 (0270_a.sql)" "$T/out" && ok \
  || bad "O5: the hit on page 2 counts (rc $RC, files: $(files), out: $(cat "$T/out"), err: $(cat "$T/err"))"
grep -qx 2 "$T/pages" 2>/dev/null && ok || bad "O5: page 2 was read (pages: $(tr '\n' ' ' < "$T/pages" 2>/dev/null))"

# O6 — self #20, the NEWER open #30 adds 0270_a: self keeps its number.
reset_origin; opr 30 ticket/bh-30 0270_a.sql
selfb ticket/bh-20; mig prisma/sql/0270_b.sql 0270; commitb; fix ticket/bh-20 20
[ "$RC" = 0 ] && [ ! -s "$T/out" ] && [ "$(nc)" = 1 ] && has prisma/sql/0270_b.sql && ok || bad "O6: the older PR keeps its number (rc $RC, files: $(files), out: $(cat "$T/out"))"

# O7 — the open PR whose head is the self branch is not taken.
reset_origin; opr 10 ticket/bh-20 0270_a.sql
selfb ticket/bh-20; mig prisma/sql/0270_b.sql 0270; commitb; fix ticket/bh-20 20
[ "$RC" = 0 ] && [ ! -s "$T/out" ] && [ "$(nc)" = 1 ] && ok || bad "O7: self head is not taken (rc $RC, out: $(cat "$T/out"))"

# O8 — a PR of the same ticket (ticket/bh-1-r2 while self is ticket/bh-1).
reset_origin; opr 10 ticket/bh-1-r2 0270_a.sql
selfb ticket/bh-1; mig prisma/sql/0270_b.sql 0270; commitb; fix ticket/bh-1 20
[ "$RC" = 0 ] && [ ! -s "$T/out" ] && [ "$(nc)" = 1 ] && ok || bad "O8: the same ticket's PR is not taken (rc $RC, out: $(cat "$T/out"))"

# O9 — an open PR that carries this branch's own file (a stacked child).
reset_origin; opr 10 ticket/bh-10 0270_b.sql
selfb ticket/bh-20; mig prisma/sql/0270_b.sql 0270; commitb; fix ticket/bh-20 20
[ "$RC" = 0 ] && [ ! -s "$T/out" ] && [ "$(nc)" = 1 ] && ok || bad "O9: the same basename is not taken (rc $RC, out: $(cat "$T/out"))"

# O10 — an open PR that MODIFIES main's 0269_last.sql adds no number: a
# collision with main still lands on 0270, not above 0269 "taken" twice.
reset_origin
"$REALGIT" -C "$S" checkout -q -B ticket/bh-10 main; printf -- '-- edited\n' >> "$S/prisma/sql/0269_last.sql"
"$REALGIT" -C "$S" commit -qam 'pr 10'; "$REALGIT" -C "$S" push -q -f origin ticket/bh-10 2>/dev/null
"$REALGIT" -C "$T/origin.git" update-ref refs/pull/10/head "$("$REALGIT" -C "$S" rev-parse HEAD)"; "$REALGIT" -C "$S" checkout -q main; jadd 10 ticket/bh-10
selfb ticket/bh-20; mig prisma/sql/0270_b.sql 0270; commitb; fix ticket/bh-20 20
[ "$RC" = 0 ] && [ ! -s "$T/out" ] && [ "$(nc)" = 1 ] && ok || bad "O10: a modified file is not taken (rc $RC, out: $(cat "$T/out"))"

# O11 — names that are not one-level migrations are not taken.
reset_origin; opr 10 ticket/bh-10 prisma/sql/sub/0270_x.sql prisma/sql/0270-x.sql prisma/sql/0270_x.sql.bak
selfb ticket/bh-20; mig prisma/sql/0270_b.sql 0270; commitb; fix ticket/bh-20 20
[ "$RC" = 0 ] && [ ! -s "$T/out" ] && [ "$(nc)" = 1 ] && ok || bad "O11: non-migration names are not taken (rc $RC, out: $(cat "$T/out"))"

# O12 — the knob off (no env, no row): main only, the list is never read.
reset_origin; opr 10 ticket/bh-10 0270_a.sql
selfb ticket/bh-20; mig prisma/sql/0270_b.sql 0270; commitb; MNR_OPEN_PRS="" fix ticket/bh-20 20
[ "$RC" = 0 ] && [ ! -s "$T/out" ] && [ "$(nc)" = 1 ] && [ ! -e "$T/list-args" ] && ok || bad "O12: knob off = main only (rc $RC, out: $(cat "$T/out"), list read: $([ -e "$T/list-args" ] && echo yes || echo no))"
# O12 (row) — the setting row turns it on, and open_prs_max reaches the list.
( cd "$T" && env MNR_DIR=prisma/sql bash -c '
    setting_get() { case "$1" in migration_renumber.open_prs.tproj) printf 1 ;; migration_renumber.open_prs_max) printf 7 ;; *) return 2 ;; esac; }
    gh_rest_pr_list_all() { printf "%s\n" "$*" >> "$T/list-args"; cat "$OJ"; }
    . "$0" || exit 9; mnr_fix "$U" origin/main tproj ticket/bh-20 20' "$LIB" ) > "$T/out" 2>"$T/err"; RC=$?
[ "$RC" = 0 ] && has prisma/sql/0271_b.sql && ok || bad "O12: the open_prs.<project> row turns it on (rc $RC, files: $(files), err: $(cat "$T/err"))"
grep -qxF "$SLUG open 7" "$T/list-args" && ok || bad "O12: open_prs_max is the list cap (args: $(cat "$T/list-args"))"
# A bad max reads as 200, with one warning.
reset_origin; opr 10 ticket/bh-10 0270_a.sql
selfb ticket/bh-20; mig prisma/sql/0270_b.sql 0270; commitb; fix ticket/bh-20 20 MNR_OPEN_PRS_MAX=5000
grep -qxF "$SLUG open 200" "$T/list-args" && grep -q 'open_prs_max' "$T/err" && ok || bad "O12: a bad max = 200 + a warning (args: $(cat "$T/list-args"), err: $(cat "$T/err"))"

# O13 — a read that fails: one stderr line, main only, rc as main-only.
reset_origin; opr 10 ticket/bh-10 0270_a.sql; echo 75 > "$T/list.rc"
selfb ticket/bh-20; mig prisma/sql/0213_x.sql 0213; mig prisma/sql/0270_b.sql 0270; commitb; fix ticket/bh-20 20
[ "$RC" = 0 ] && has prisma/sql/0270_x.sql && has prisma/sql/0271_b.sql && ok || bad "O13: rate limited = the main-only answer (rc $RC, files: $(files))"
[ "$(grep -c . "$T/err")" = 1 ] && grep -qxF 'migration renumber: open PRs not read (rate limited) — main only' "$T/err" && ok || bad "O13: one stderr line (got: $(cat "$T/err"))"
rm -f "$T/list.rc"
# no slug: the origin is a plain path.
SELF_URL="$T/origin.git" selfb ticket/bh-20; mig prisma/sql/0270_b.sql 0270; commitb; fix ticket/bh-20 20
[ "$RC" = 0 ] && [ "$(nc)" = 1 ] && grep -qxF 'migration renumber: open PRs not read (no repo slug) — main only' "$T/err" && ok || bad "O13: no slug (rc $RC, err: $(cat "$T/err"))"
# fetch fails: the list names #11 whose ref does not exist.
jadd 11 ticket/bh-11
selfb ticket/bh-20; mig prisma/sql/0270_b.sql 0270; commitb; fix ticket/bh-20 20
[ "$RC" = 0 ] && [ "$(nc)" = 1 ] && grep -qxF 'migration renumber: open PRs not read (fetch failed) — main only' "$T/err" && ok || bad "O13: fetch failed (rc $RC, err: $(cat "$T/err"))"
norefs && ok || bad "O15: refs/mnr-open/ must be empty after a failed fetch (got: $(git -C "$U" for-each-ref refs/mnr-open/))"

# O14 — self #20 collides with main; the newer open #30 holds 0275: the move
# lands above every open PR's number.
reset_origin; opr 30 ticket/bh-30 0275_a.sql
selfb ticket/bh-20; mig prisma/sql/0213_x.sql 0213; commitb; fix ticket/bh-20 20
[ "$RC" = 0 ] && has prisma/sql/0276_x.sql && ok || bad "O14: 0213_x -> 0276_x (rc $RC, files: $(files), out: $(cat "$T/out"))"

# O16 — a token in the origin url is never printed.
reset_origin; opr 10 ticket/bh-10 0270_a.sql
SELF_URL="$TOKURL" selfb ticket/bh-20; mig prisma/sql/0270_b.sql 0270; commitb; fix ticket/bh-20 20
[ "$RC" = 0 ] && has prisma/sql/0271_b.sql && ok || bad "O16: the token url still reads the slug (rc $RC, files: $(files), err: $(cat "$T/err"))"
echo 75 > "$T/list.rc"; SELF_URL="$TOKURL" selfb ticket/bh-21; mig prisma/sql/0270_c.sql 0270; commitb; fix ticket/bh-21 21; rm -f "$T/list.rc"
jadd 12 ticket/bh-12; SELF_URL="$TOKURL" selfb ticket/bh-22; mig prisma/sql/0270_d.sql 0270; commitb; fix ticket/bh-22 22
grep -q 'tok-fixture-secret' "$T/out" "$T/err" && bad "O16: the token is printed" || ok

# ============================================================================
# R. bare-number references (map kind B)
# ============================================================================
reset_origin
printf 'idx\n' > "$S/docs.md"; "$REALGIT" -C "$S" add -A; "$REALGIT" -C "$S" commit -qm docs; "$REALGIT" -C "$S" push -q origin main 2>/dev/null
selfb ticket/bh-20
mig prisma/sql/0100_k.sql 0100 "-- after 0213 on main"
mig prisma/sql/0213_x.sql 0213 "RAISE EXCEPTION 'apply 0213 as the project-5 import';
SELECT '0213: project-6_app grant';
-- near: 02130 10213 0213x x0213 213 0213_other"
mkdir -p "$U/tests" "$U/docs"
printf 'const f = "prisma/sql/0213_x.sql";\nexpect(msg).toContain("0213: project-6_app");\n' > "$U/tests/x.test.ts"
printf 'main has 0213 already\n' > "$U/docs/note.md"
printf 'see 0213 and 0213_x\n' >> "$U/docs.md"
commitb
fix ticket/bh-20 20 MNR_OPEN_PRS=0
M="$U/prisma/sql/0270_x.sql"
[ "$RC" = 0 ] && [ -f "$M" ] && ok || bad "R0: 0213_x -> 0270_x (rc $RC, files: $(files), err: $(cat "$T/err"))"
grep -qxF "RAISE EXCEPTION 'apply 0270 as the project-5 import';" "$M" && ok || bad "R1: RAISE text moves (got: $(cat "$M"))"
grep -qxF "SELECT '0270: project-6_app grant';" "$M" && ok || bad "R2: '0213: ...' moves (got: $(cat "$M"))"
grep -qxF 'expect(msg).toContain("0270: project-6_app");' "$U/tests/x.test.ts" && grep -qF '"prisma/sql/0270_x.sql"' "$U/tests/x.test.ts" \
  && ok || bad "R3: an added test that names the stem gets the bare number (got: $(cat "$U/tests/x.test.ts"))"
grep -qxF 'main has 0213 already' "$U/docs/note.md" && ok || bad "R4: an added note without the stem is unchanged (got: $(cat "$U/docs/note.md"))"
grep -qxF 'see 0213 and 0270_x' <(tail -1 "$U/docs.md") && ok || bad "R5: a modified file keeps the bare number (got: $(tail -1 "$U/docs.md"))"
grep -qxF -- '-- after 0213 on main' "$U/prisma/sql/0100_k.sql" && ok || bad "R6: a kept migration is unchanged (got: $(cat "$U/prisma/sql/0100_k.sql"))"
grep -qxF -- '-- near: 02130 10213 0213x x0213 213 0213_other' "$M" && ok || bad "R7: near misses are unchanged (got: $(cat "$M"))"

# R8 — a chain: 0213 -> 0270 while the branch's own 0270 -> 0271. One pass,
# so no token moves twice (bare, migration:, the stem).
reset_origin; selfb ticket/bh-20
mig prisma/sql/0213_x.sql 0213 "RAISE EXCEPTION 'apply 0213';"
mig prisma/sql/0270_y.sql 0270 "SELECT '0270: y';"
mkdir -p "$U/tests"; printf 'a "0213_x" b "0270_y"\nc "0213: a" d "0270: b"\n' > "$U/tests/chain.test.ts"
commitb; fix ticket/bh-20 20 MNR_OPEN_PRS=0
[ "$RC" = 0 ] && has prisma/sql/0270_x.sql && has prisma/sql/0271_y.sql && ok || bad "R8: 0270_x, 0271_y (rc $RC, files: $(files))"
grep -qxF "RAISE EXCEPTION 'apply 0270';" "$U/prisma/sql/0270_x.sql" && grep -qF 'migration:0270 lock "mk0270"' "$U/prisma/sql/0270_x.sql" \
  && ok || bad "R8: 0270_x names 0270 once moved (got: $(cat "$U/prisma/sql/0270_x.sql"))"
grep -qxF "SELECT '0271: y';" "$U/prisma/sql/0271_y.sql" && grep -qF 'migration:0271 lock "mk0271"' "$U/prisma/sql/0271_y.sql" \
  && ok || bad "R8: 0271_y names 0271 (got: $(cat "$U/prisma/sql/0271_y.sql"))"
[ "$(cat "$U/tests/chain.test.ts")" = 'a "0270_x" b "0271_y"
c "0270: a" d "0271: b"' ] && ok || bad "R8: the added test maps each token once (got: $(cat "$U/tests/chain.test.ts"))"

# ============================================================================
# L. mnr_lock_notes
# ============================================================================
notes() { # notes [env...] — mnr_lock_notes over $U; RC, $T/out
  ( cd "$T" && env MNR_DIR=prisma/sql MNR_LOCK_PREFIX="${MNR_LOCK_PREFIX-mk}" "$@" bash -c '. "$0" || exit 9; mnr_lock_notes "$U" origin/main tproj' "$LIB" ) > "$T/out" 2>"$T/err"
  RC=$?
}
lmig() { mkdir -p "$U/prisma/sql"; printf '%s\n' "$2" > "$U/prisma/sql/$1"; }
reset_origin
L270=$(lk mk0270); L293=$(lk mk0293); L003=$(lk mk0003)
# L1
selfb ticket/bh-30; lmig 0293_x.sql "SELECT pg_advisory_xact_lock($L270);"; commitb; notes
[ "$RC" = 0 ] && [ "$(cat "$T/out")" = "prisma/sql/0293_x.sql takes lock mk0270 ($L270), not its own mk0293 ($L293): a shared lock is legal, a stale one is not" ] \
  && ok || bad "L1: the note (rc $RC, got: $(cat "$T/out"))"
# L2
selfb ticket/bh-30; lmig 0293_x.sql "SELECT pg_advisory_lock( $L270 );"; commitb; notes
grep -qF 'takes lock mk0270' "$T/out" && ok || bad "L2: pg_advisory_lock is read too (got: $(cat "$T/out"))"
# L3
selfb ticket/bh-30; lmig 0293_x.sql "SELECT pg_advisory_xact_lock($L293);"; commitb; notes
[ "$RC" = 0 ] && [ ! -s "$T/out" ] && ok || bad "L3: its own key = no note (got: $(cat "$T/out"))"
# L4
selfb ticket/bh-30; lmig 0293_x.sql "SELECT pg_advisory_xact_lock($L293);
SELECT pg_advisory_xact_lock($L003);"; commitb; notes
[ ! -s "$T/out" ] && ok || bad "L4: own + a shared mk0003 = no note (got: $(cat "$T/out"))"
# L5
selfb ticket/bh-30; lmig 0293_x.sql "SELECT pg_advisory_xact_lock(755000820082);"; commitb; notes
[ ! -s "$T/out" ] && ok || bad "L5: a key not in prefix form = no note (got: $(cat "$T/out"))"
# L6
selfb ticket/bh-30; lmig 0293_x.sql "-- was: SELECT pg_advisory_xact_lock($L270);
SELECT 1;"; commitb; notes
[ ! -s "$T/out" ] && ok || bad "L6: a key inside a -- comment = no note (got: $(cat "$T/out"))"
selfb ticket/bh-30; lmig 0293_x.sql "SELECT pg_advisory_xact_lock($L293); -- not $L270 any more
SELECT pg_advisory_xact_lock($L270) -- x"; commitb; notes
[ ! -s "$T/out" ] && ok || bad "L6: a comment key next to its own real key = no note (got: $(cat "$T/out"))"
# L7
selfb ticket/bh-30; lmig 0293_x.sql "SELECT pg_advisory_xact_lock($L270);"; commitb; notes MNR_LOCK_PREFIX=""
[ "$RC" = 0 ] && [ ! -s "$T/out" ] && ok || bad "L7: no prefix = off (got: $(cat "$T/out"))"
# L8 — base files carry mk0003; a modified file with a foreign key.
selfb ticket/bh-30; printf 'SELECT pg_advisory_xact_lock(%s);\n' "$L270" >> "$U/prisma/sql/0269_last.sql"; commitb; notes
[ "$RC" = 0 ] && [ ! -s "$T/out" ] && ok || bad "L8: base and modified files = no note (got: $(cat "$T/out"))"

# ============================================================================
# C1. the builder's pre-PR block, lifted from bin/lib/rb/pr.sh
# ============================================================================
awk 'index($0,"# >>> migration renumber (BH-7365)")==1{f=1} f{print} index($0,"# <<< migration renumber (BH-7365)")==1{exit}' "$RB" > "$T/mnr-block.sh"
[ -s "$T/mnr-block.sh" ] && bash -n "$T/mnr-block.sh" && ok || bad "C1: could not lift the migration renumber block"
reset_origin; opr 10 ticket/bh-10 0270_a.sql
selfb ticket/bh-20; mig prisma/sql/0270_b.sql 0270; lmig 0100_k.sql "SELECT pg_advisory_xact_lock($(lk mk0050));"; commitb
mkdir -p "$T/build"; : > "$T/build/pipeline.log"
( cd "$U" && env BUILD="$T/build" PROJECT=tproj KEY=BH-20 BASE=main BRANCH=ticket/bh-20 STACK_ON="" PREPR_SECTION="" \
    MNR_DIR=prisma/sql MNR_LOCK_PREFIX=mk MNR_OPEN_PRS=1 bash -c '
    gh_rest_pr_list_all() { cat "$OJ"; }
    . "$1" || exit 9
    STAMP() { echo TS; }; RESULT() { echo "$*" > "$0.result"; }; . "$0"; printf "%s" "$PREPR_SECTION"' "$T/mnr-block.sh" "$LIB" ) > "$T/sec" 2>"$T/b.err"
has prisma/sql/0271_b.sql && ok || bad "C1: the block renumbers against open #10 (files: $(files); err: $(cat "$T/b.err"); log: $(cat "$T/build/pipeline.log"))"
grep -qxF -- "- 0270 is taken by open PR #10 (0270_a.sql); this PR's number is 0271 (prisma/sql/0270_b.sql -> prisma/sql/0271_b.sql)" "$T/sec" \
  && ok || bad "C1: the section lists the move (got: $(cat "$T/sec"))"
grep -qxF -- "- prisma/sql/0100_k.sql takes lock mk0050 ($(lk mk0050)), not its own mk0100 ($(lk mk0100)): a shared lock is legal, a stale one is not" "$T/sec" \
  && ok || bad "C1: the section carries the lock note (got: $(cat "$T/sec"))"
[ "$(grep -c '^## Migration numbers (BH-7365)$' "$T/sec")" = 1 ] && ok || bad "C1: one section heading (got: $(cat "$T/sec"))"
[ ! -e "$T/mnr-block.sh.result" ] && ok || bad "C1: the block never calls RESULT"
# C1b — no move, one lock note: the section still carries it.
reset_origin; selfb ticket/bh-20; lmig 0100_k.sql "SELECT pg_advisory_xact_lock($(lk mk0050));"; commitb
( cd "$U" && env BUILD="$T/build" PROJECT=tproj KEY=BH-20 BASE=main BRANCH=ticket/bh-20 STACK_ON="" PREPR_SECTION="" \
    MNR_DIR=prisma/sql MNR_LOCK_PREFIX=mk bash -c '. "$1" || exit 9
    STAMP() { echo TS; }; RESULT() { :; }; . "$0"; printf "%s" "$PREPR_SECTION"' "$T/mnr-block.sh" "$LIB" ) > "$T/sec" 2>"$T/b.err"
grep -qxF '## Migration numbers (BH-7365)' "$T/sec" && grep -qF -- '- prisma/sql/0100_k.sql takes lock mk0050' "$T/sec" && ok || bad "C1b: a lock note alone makes the section (got: $(cat "$T/sec"))"

# ============================================================================
# C2-C4. a real mc_rebase and rebase_job_run against the origin
# ============================================================================
export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" \
         "$T/h/env" "$T/h/tmp" "$T/fakebin" "$T/repos" "$T/wt"
scratch_install_closure bin/merge-conductor.sh "$T/h" >/dev/null || exit 1
scratch_install_closure bin/lib/rebase-job.sh "$T/h" >/dev/null || exit 1
: > "$T/h/env/global.env"
printf 'demo-os %s - - 2 box-d\n' "$SLUG" > "$T/h/fleet.conf"
export FLEET_CONF="$T/h/fleet.conf"
cat > "$T/h/bin/jobs-client.sh" <<EOF
job_verdict_rebind() { printf '%s\n' "\$*" >> "$T/rebinds.txt"; return 0; }
job_ledger_put() { return 0; }
EOF
. "$DIR/tests/lib/hold-fixture.sh" || exit 1
hold_fixture_answer_lib "$T/holdfx" || exit 1
export HOLD_FX_ANSWER="$T/holdfx/hold-answer.sh"
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
[ -n "\${HOLD_FX_ANSWER:-}" ] && . "\$HOLD_FX_ANSWER" && hold_answer "\$@" && exit 0
case "\$*" in
  *"auth token"*) echo faketoken-fixture ;;
  *"rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"pr list"*) echo "[]" ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
export PATH="$T/fakebin:$PATH"
LOG="$T/h/logs/merge-conductor.log"
# cfix <open-pr> — origin: main + PR branch ticket/bh-9002 that adds 0270_b;
# then main moves (a doc) and open PR <open-pr> adds 0270_a.
cfix() {
  reset_origin
  rm -rf "$T/h/tmp/conductor" "$T/machine"; : > "$T/rebinds.txt"; : > "$LOG"
  "$REALGIT" -C "$S" checkout -q -b ticket/bh-9002 main
  printf -- '-- migration:0270 branch\n' > "$S/prisma/sql/0270_b.sql"
  "$REALGIT" -C "$S" add -A && "$REALGIT" -C "$S" commit -qm branch
  CHEAD=$("$REALGIT" -C "$S" rev-parse HEAD)
  "$REALGIT" -C "$S" checkout -q main; printf 'doc\n' > "$S/doc.md"
  "$REALGIT" -C "$S" add -A && "$REALGIT" -C "$S" commit -qm 'main moves'
  "$REALGIT" -C "$S" push -q origin main ticket/bh-9002 2>/dev/null
  opr "$1" "ticket/bh-$1" 0270_a.sql
}
origin_rev() { "$REALGIT" -C "$T/origin.git" rev-parse "$1" 2>/dev/null; }
otree() { "$REALGIT" -C "$T/origin.git" ls-tree --name-only "$(origin_rev ticket/bh-9002)" prisma/sql/ 2>/dev/null | sed 's|^prisma/sql/||' | tr '\n' ' '; }
arun() { # arun <pr-url> — mc_rebase in a fresh subshell; rc to $T/arc
  ( . "$T/h/bin/lib/gh-rest-list.sh"; . "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init; MC_REPOS="$T/repos"
    gh_rest_pr_list_all() { cat "$OJ"; }
    MNR_DIR=prisma/sql MNR_OPEN_PRS=1 mc_rebase "$SLUG" demo-os ticket/bh-9002 "$CHEAD" "$1" > /dev/null 2>&1; echo $? > "$T/arc" )
}
# C2 — self #20, the older open #10 holds 0270: renumbered, logged, rc 5.
cfix 10; arun "https://github.com/$SLUG/pull/20"; RC=$(cat "$T/arc")
[ "$(otree)" = "0001_init.sql 0213_project-5_import.sql 0269_last.sql 0271_b.sql " ] && ok || bad "C2: the pushed head has 0271_b (rc $RC, got: $(otree); log: $(tail -3 "$LOG"))"
[ "$RC" = 5 ] && [ ! -s "$T/rebinds.txt" ] && ok || bad "C2: rc 5 and no rebind (rc $RC, rebinds: $(cat "$T/rebinds.txt"))"
grep -qF "migration renumbered — 0270 is taken by open PR #10 (0270_a.sql); this PR's number is 0271" "$LOG" && ok || bad "C2: the log names open PR #10 (got: $(cat "$LOG"))"
# C4 — self #10, the newer open #30 holds 0270: no move, rc 0, a rebind.
cfix 30; arun "https://github.com/$SLUG/pull/10"; RC=$(cat "$T/arc")
[ "$RC" = 0 ] && [ -s "$T/rebinds.txt" ] && ok || bad "C4: the older PR keeps 0270 (rc $RC, log: $(tail -3 "$LOG"))"
[ "$(otree)" = "0001_init.sql 0213_project-5_import.sql 0269_last.sql 0270_b.sql " ] && ok || bad "C4: the pushed head keeps 0270_b (got: $(otree))"
# C3 — the pool twin: REBASE_JOB_URL names #20; the UNION line carries the move.
cfix 10
"$REALGIT" clone -q "$GHURL" "$T/machine" 2>/dev/null
# gh-rest-list.sh first: its include guard keeps the stub below when the
# twin's own libs source it again.
( cd "$T" && . "$T/h/bin/lib/gh-rest-list.sh" && . "$T/h/bin/lib/rebase-job.sh"
  gh_rest_pr_list_all() { cat "$OJ"; }
  REBASE_WT_DIR="$T/wt" MNR_DIR=prisma/sql MNR_OPEN_PRS=1 PROJECT=demo-os REBASE_JOB_URL="https://github.com/$SLUG/pull/20" \
    rebase_job_run "$T/machine" "$SLUG" ticket/bh-9002 "$CHEAD" main "$T/RESULT" "$T/h" ) >/dev/null 2>&1
grep -qxF 'UNION: prisma/sql/0270_b.sql -> prisma/sql/0271_b.sql (BH-7365, migration renumbered)' "$T/RESULT" && ok || bad "C3: the UNION line (got: $(cat "$T/RESULT" 2>/dev/null))"

# ============================================================================
# X. the replay of the ticket's PRs (main ends at 0269)
# ============================================================================
# <pr>:<numbers> in PR-number order, from the ticket body.
REPLAY="1653:0270 1663:0279 1664:0270 1665:0270 1666:0270 1667:0270 1673:0275 1675:0275 1677:0279 1682:0279 1707:0279 1710:0281 1712:0281 1713:0281 1714:0281 1724:0282,0283"
MERGE_ORDER="1707 1653 1724 1666 1675 1712 1663 1714 1665 1682 1673 1710 1664 1713 1677 1667"
X="$T/x"
xfix() { # xfix <self-branch> <self-pr> <on:0|1> — mnr_fix over $X
  ( cd "$T" && env MNR_DIR=prisma/sql MNR_LOCK_PREFIX=mk MNR_OPEN_PRS="$3" bash -c '
      gh_rest_pr_list_all() { cat "$OJ"; }
      . "$0" || exit 9; mnr_fix "$1" origin/main tproj "$2" "$3"' "$LIB" "$X" "$1" "$2" ) >> "$T/x.out" 2>>"$T/x.err"
}
# open_phase <on> — every PR opened in order, each after its pre-PR check.
# Prints the number of repeated numbers across the open PRs.
open_phase() {
  local e n nums f
  reset_origin; scratch_rm "$X" || exit 1; : > "$T/x.out"; : > "$T/x.err"
  "$REALGIT" clone -q "$GHURL" "$X" 2>/dev/null
  for e in $REPLAY; do
    n=${e%%:*}; nums=${e#*:}
    "$REALGIT" -C "$X" checkout -q -B "ticket/bh-$n" origin/main
    for f in ${nums//,/ }; do printf -- '-- migration:%s pr %s\n' "$f" "$n" > "$X/prisma/sql/${f}_pr$n.sql"; done
    "$REALGIT" -C "$X" add -A && "$REALGIT" -C "$X" commit -qm "pr $n"
    xfix "ticket/bh-$n" "" "$1"
    "$REALGIT" -C "$X" push -q -f origin "ticket/bh-$n" 2>/dev/null
    "$REALGIT" -C "$T/origin.git" update-ref "refs/pull/$n/head" "$("$REALGIT" -C "$X" rev-parse HEAD)"
    jadd "$n" "ticket/bh-$n"
  done
  for e in $REPLAY; do
    n=${e%%:*}
    # Each replay file is <number>_pr<n>.sql, and a renumber keeps the slug.
    "$REALGIT" -C "$X" ls-tree --name-only "ticket/bh-$n" prisma/sql/ | grep "_pr$n\.sql\$"
  done | sed 's|^prisma/sql/||; s|_.*||' | sort | uniq -d | wc -l
}
# X0 — without the open-PR check the replay reproduces the incident.
X0=$(open_phase 0)
[ "$X0" -ge 4 ] && ok || bad "X0: the replay data must collide without the check (repeated numbers: $X0)"
# X1 — with it: pre-PR numbers are unique, then every PR merges through the
# rebase check (its own PR number, the rest still open) and main stays unique.
X1=$(open_phase 1)
[ "$X1" = 0 ] && ok || bad "X1: pre-PR numbers repeat across open PRs ($X1; out: $(cat "$T/x.out"))"
for n in $MERGE_ORDER; do
  "$REALGIT" -C "$X" fetch -q origin
  "$REALGIT" -C "$X" checkout -q -B "ticket/bh-$n" "origin/ticket/bh-$n"
  "$REALGIT" -C "$X" merge -q --no-edit origin/main >/dev/null 2>&1 || bad "X1: merge of main into #$n"
  xfix "ticket/bh-$n" "$n" 1
  "$REALGIT" -C "$X" push -q origin "HEAD:main" 2>/dev/null || bad "X1: #$n did not land on main"
  jq -c --argjson n "$n" 'map(select(.number != $n))' "$OJ" > "$OJ.n" && mv "$OJ.n" "$OJ"
done
"$REALGIT" -C "$X" fetch -q origin
XN=$("$REALGIT" -C "$X" ls-tree --name-only origin/main prisma/sql/ | sed 's|^prisma/sql/||' | grep -c '_pr')
XD=$("$REALGIT" -C "$X" ls-tree --name-only origin/main prisma/sql/ | sed 's|^prisma/sql/||; s|_.*||' | sort | uniq -d | wc -l)
if [ "$X1" = 0 ] && [ "$XD" = 0 ] && [ "$XN" = 17 ]; then
  echo "replay: 0 collisions"; ok
else
  bad "X1: main after the merges: $XN replay files, $XD repeated numbers (want 17, 0)"
fi

# ============================================================================
# S. the seed rows, through the composed schema
# ============================================================================
if command -v python3 >/dev/null && python3 -c 'import sqlite3' 2>/dev/null; then
  HARNESS_TEST_SANDBOX=1 "$DIR/bin/schema-build.sh" --to "$T/schema.sql" >/dev/null 2>"$T/s.err" || bad "S1: schema-build --to failed ($(head -2 "$T/s.err"))"
  S1=$(python3 -I -c '
import sqlite3, sys
db = sqlite3.connect(":memory:")
db.executescript(open(sys.argv[1]).read())
for k in ("migration_renumber.open_prs.project-6-os", "migration_renumber.open_prs_max"):
    r = db.execute("SELECT value FROM settings WHERE key = ?", (k,)).fetchone()
    print(k + " = " + (r[0] if r else "-"))
' "$T/schema.sql" 2>"$T/s.err")
  grep -qxF 'migration_renumber.open_prs.project-6-os = 1' <<<"$S1" && ok || bad "S1: migration_renumber.open_prs.project-6-os = 1 (got: $S1 $(head -2 "$T/s.err"))"
  grep -qxF 'migration_renumber.open_prs_max = 200' <<<"$S1" && ok || bad "S1: migration_renumber.open_prs_max = 200 (got: $S1)"
  echo "$S1"
else
  echo "S1: python3 sqlite3 missing — skipped"
fi

echo "migration-renumber-open-prs.bh-7398-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
