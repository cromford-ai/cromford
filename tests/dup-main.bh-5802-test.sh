#!/bin/bash
# tests/dup-main.bh-5802-test.sh — BH-5802: plans and the pre-review check see
# work that is already on main.
#
# Three BLOCKs found a PR that duplicated main (#4701 would have deleted the
# cromford guardrails c139f7b87 shipped; #4342 re-added BH-4329's check, looser;
# #4332 carried worker files #4883 had shipped). bin/lib/dup-main.sh, driven on
# a real git fixture:
#   P1  dup_main_ticket names the main commit that names the key, since the
#       ticket was filed; not one before it, not BH-770 for BH-77
#   P2  dup_main_plan_note says how to stop (the parked marker) and names the
#       sha; with nothing naming the key it still asks for the file and symbol
#       search; with no filing time, nothing
#   P3  a plan whose first line is that marker stops the build (PLAN_IS_BLOCKED,
#       extracted from the pipeline through tests/lib/rb-all.sh)
#   P4  the PLAN prompt in bin/lib/rb/plan.sh carries the note
#   D1  a PR that re-adds a file main already shipped is a duplicate of that
#       commit (it merges clean, so merge-tree alone never sees it)
#   D2  5 identical added lines in a file both changed: a duplicate
#   D3-D5 not duplicates: an unrelated PR, a file only the PR adds, shared
#       trivial lines (blank, fi, done, braces)
#   D6  a head the clone does not have: rc 2, nothing printed
#   D2 also pins the sha: the commit that added the shared lines, not a later
#       main commit that touched the same file (lead NOTE on ddb6e4664)
#   D8  a file main added and then deleted again is not a duplicate
#   L1  the lead review checklist asks about duplication
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/dup-main.bh-5802-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
LIB="$DIR/bin/lib/dup-main.sh"
[ -r "$LIB" ] && bash -n "$LIB" && ok || bad "bin/lib/dup-main.sh is missing or does not parse"

# ── the fixture: origin main, the hub clone, and PR branches ────────────────
R="$T/repo"; git init -q -b main "$R"
git -C "$R" config user.email t@t; git -C "$R" config user.name t
gc() { GIT_COMMITTER_DATE="$1" GIT_AUTHOR_DATE="$1" git -C "$R" commit -qm "$2"; }
printf 'line one\n' > "$R/base.txt"; git -C "$R" add -A; gc 2026-10-01T00:00:00Z "base"
BASE=$(git -C "$R" rev-parse HEAD)
# main, before the ticket was filed: names BH-77 but is old
printf 'old\n' > "$R/old.txt"; git -C "$R" add -A; gc 2026-10-02T00:00:00Z "BH-77: an older attempt"
# main, after the ticket (filed 2026-10-05): ships the guard file, and a commit naming BH-770
mkdir -p "$R/bin/lib"
cat > "$R/bin/lib/guard.sh" <<'EOF'
guard_check() {
  local path="$1"
  case "$path" in
    /root/*) return 1 ;;
  esac
  [ -n "$path" ] || return 1
  printf 'guard ok for %s\n' "$path"
}
EOF
printf 'shared one\nshared two\nshared three\nshared four\nshared five\n' >> "$R/base.txt"
git -C "$R" add -A; gc 2026-10-06T00:00:00Z "BH-77: ship the guard"
SHIP=$(git -C "$R" rev-parse HEAD)
printf 'x\n' > "$R/other.txt"; git -C "$R" add -A; gc 2026-10-07T00:00:00Z "BH-770: unrelated"
# main touches base.txt again later (D2 must still name SHIP, the commit that
# added the shared lines), and adds then deletes gone.sh (D8)
printf 'a later main edit\n' >> "$R/base.txt"; git -C "$R" commit -qam "later edit"
printf 'gone for good\n' > "$R/gone.sh"; git -C "$R" add -A; git -C "$R" commit -qm "add gone.sh"
git -C "$R" rm -q gone.sh; git -C "$R" commit -qm "drop gone.sh"
git -C "$R" branch -q -m main; git -C "$R" update-ref refs/remotes/origin/main HEAD
# PR D1: from BASE, re-adds the same guard file
git -C "$R" checkout -q -b d1 "$BASE"; mkdir -p "$R/bin/lib"; git -C "$R" show "$SHIP:bin/lib/guard.sh" > "$R/bin/lib/guard.sh"
git -C "$R" add -A; gc 2026-10-08T00:00:00Z "BH-80: add the guard"; D1=$(git -C "$R" rev-parse HEAD)
# PR D2: from BASE, appends the same 5 lines to base.txt
git -C "$R" checkout -q -b d2 "$BASE"; printf 'shared one\nshared two\nshared three\nshared four\nshared five\n' >> "$R/base.txt"
git -C "$R" commit -qam "BH-81: shared lines"; D2=$(git -C "$R" rev-parse HEAD)
# PR D3: unrelated change
git -C "$R" checkout -q -b d3 "$BASE"; printf 'mine\n' > "$R/mine.txt"; git -C "$R" add -A; git -C "$R" commit -qm "BH-82"; D3=$(git -C "$R" rev-parse HEAD)
# PR D5: shares only trivial lines with main's base.txt change
git -C "$R" checkout -q -b d5 "$BASE"; printf '\n}\nfi\ndone\n{\n\n' >> "$R/base.txt"; git -C "$R" commit -qam "BH-83"; D5=$(git -C "$R" rev-parse HEAD)
# PR D8: adds gone.sh, which main added and then deleted again
git -C "$R" checkout -q -b d8 "$BASE"; printf 'gone for good\n' > "$R/gone.sh"; git -C "$R" add -A; git -C "$R" commit -qm "BH-84"; D8=$(git -C "$R" rev-parse HEAD)
git -C "$R" checkout -q main

lib() { ( . "$LIB" && "$@" ); }

# ── P1 ──
out=$(lib dup_main_ticket "$R" origin/main BH-77 2026-10-05T00:00:00Z)
grep -q "^${SHIP:0:12} BH-77: ship the guard$" <<<"$out" && ok || bad "P1 the shipping commit is not named: '$out'"
grep -q "older attempt" <<<"$out" && bad "P1 a commit from before the ticket was named" || ok
grep -q "BH-770" <<<"$out" && bad "P1 BH-770 matched BH-77" || ok
[ -z "$(lib dup_main_ticket "$R" origin/main BH-99 2026-10-05T00:00:00Z)" ] && ok || bad "P1 a key main never names printed something"

# ── P2 ──
note=$(lib dup_main_plan_note "$R" origin/main BH-77 2026-10-05T00:00:00Z)
grep -qF "${SHIP:0:12}" <<<"$note" && grep -qF "BLOCKED: already done on main by" <<<"$note" && ok \
  || bad "P2 the note does not name the sha and the stop line: '$note'"
# With no commit naming the key, the note still asks for the file and symbol
# search (scope 1), but names no sha.
note=$(lib dup_main_plan_note "$R" origin/main BH-99 2026-10-05T00:00:00Z)
grep -qF "git log origin/main --since=2026-10-05T00:00:00Z" <<<"$note" && ! grep -qF "${SHIP:0:12}" <<<"$note" && ok \
  || bad "P2 with nothing naming the key, the note must still ask for the search and name no sha: '$note'"
[ -z "$(lib dup_main_plan_note "$R" origin/main BH-77 '')" ] && ok || bad "P2 no filing time must give no note (nothing is judged on a guess)"

# ── P3: the stop line parks the plan ──
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
awk '$0=="# >>> plan blocked marker"{f=1;next} $0=="# <<< plan blocked marker"{exit} f' "$RB_ALL" > "$T/pib.sh"
grep -q '^PLAN_IS_BLOCKED()' "$T/pib.sh" && ok || bad "P3 could not extract PLAN_IS_BLOCKED"
printf 'BLOCKED: already done on main by %s (BH-77: ship the guard)\n\nnothing to build\n' "${SHIP:0:12}" > "$T/plan.md"
( . "$T/pib.sh"; PLAN_IS_BLOCKED "$T/plan.md" ) && ok || bad "P3 the already-done line does not park the plan"

# ── P4: the plan prompt carries the note ──
# TEST-CHANGE (BH-7970): the call moved from the CC plan line to the SP_PLAN_DUP_MAIN precompute, and the template carries its token.
grep -q '^SP_PLAN_DUP_MAIN=.*dup_main_plan_note' "$DIR/bin/lib/rb/plan.sh" && grep -qF '${SP_PLAN_DUP_MAIN}' "$DIR/prompts/stages/plan.md" && ok || bad "P4 the plan prompt does not carry dup_main_plan_note"

# ── D1-D6 ──
out=$(lib dup_main_pr "$R" origin/main "$D1"); rc=$?
[ "$rc" = 0 ] && [ "$out" = "${SHIP:0:12} bin/lib/guard.sh" ] && ok || bad "D1 a re-added shipped file: rc $rc '$out'"
out=$(lib dup_main_pr "$R" origin/main "$D2"); rc=$?
[ "$rc" = 0 ] && [ "$out" = "${SHIP:0:12} base.txt" ] && ok || bad "D2 5 identical added lines: rc $rc '$out'"
out=$(lib dup_main_pr "$R" origin/main "$D3"); rc=$?
[ "$rc" = 1 ] && [ -z "$out" ] && ok || bad "D3 an unrelated PR was flagged: rc $rc '$out'"
out=$(lib dup_main_pr "$R" origin/main "$D5"); rc=$?
[ "$rc" = 1 ] && ok || bad "D5 shared trivial lines were flagged: rc $rc '$out'"
out=$(lib dup_main_pr "$R" origin/main "$(printf '0%.0s' {1..40})"); rc=$?
[ "$rc" = 2 ] && [ -z "$out" ] && ok || bad "D6 a missing head: rc $rc '$out'"

out=$(lib dup_main_pr "$R" origin/main "$D8"); rc=$?
[ "$rc" = 1 ] && [ -z "$out" ] && ok || bad "D8 a file main added and then deleted is not a duplicate: rc $rc '$out'"

# ── L1 ──
grep -qiE 'duplicat' "$DIR/prompts/lead-review-checklist.md" && grep -qF 'possible duplicate of' "$DIR/prompts/lead-review-checklist.md" \
  && ok || bad "L1 the lead review checklist does not ask about duplicates of main"

echo "dup-main.bh-5802: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
