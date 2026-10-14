#!/bin/bash
# tests/pr-self-check-foreign-commits.bh-6394-test.sh — BH-6394: a PR carries
# only its own ticket's commits (D66, enforced). The pre-review self-check
# (bin/pr-self-check.sh, bin/lib/pr-self-check.sh, rule `foreign-commits` in
# catalog/pr-self-check.tsv) refuses a PR whose first-parent, non-merge commits
# in base..head lead with another ticket's key, unless the base is that
# ticket's branch or the PR is stacked and the conductor holds THIS head as
# STACKED_WAIT. #6355 (ticket/bh-5905-r3, base main) carried 3 BH-6308 commits.
#
#   F1  base main, `BH-100: x` on a BH-200 PR: REFUSE, names BH-100 and its sha
#   F2  base ticket/bh-100 (commit in base, and a copy not in base): pass
#   F3  `Stacked on #7` + conductor STACKED_WAIT for this head: pass
#   F4  `BH-200: read the BH-100 rows` (key inside the text): silent
#   F5  a BH-100 commit that came in through a merge of main: pass
#   F6  `fix(BH-100): x`: REFUSE        F7  `spec(BH-100.2): plan`: REFUSE
#   F8  base ticket/bh-100, a `BH-300: z` commit: REFUSE names BH-300 only
#   F9  own slice `BH-200.1: y`         F10 body `Ticket BH-200 — BH-150.1: x`
#   F11 `UTF-8: decode`                 F12 `fix(ci-plan): x (BH-100)`  — all pass
#   F13 `Stacked on #7`, STACKED_WAIT row for an older head: REFUSE
#   F14 base ticket/bh-100-r2: pass
#   F15 no key anywhere, a `BH-100: x` commit: one NOTE, rc 0
#   F16 the row set to `off`: F1 passes
#   F17 `Revert "BH-100: x"`: pass
#   F18 a gh_rest stub names #7; without it the line names ticket/bh-100
#   F19 two BH-100 commits: two REFUSE lines
#   R1  the plan's REPRO through the CLI as delivered (repo catalog): rc 1
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/pr-self-check-foreign-commits.bh-6394-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset PSC_PR_KEY PSC_CONDUCTOR_ROWS
H="$T/h"; mkdir -p "$H"
scratch_install_closure bin/pr-self-check.sh "$H" >/dev/null || { echo "FAIL: closure of bin/pr-self-check.sh"; exit 1; }
cp "$DIR/catalog/pr-self-check.tsv" "$T/catalog.tsv" 2>/dev/null || : > "$T/catalog.tsv"
export PR_SELF_CHECK_ONLY='^foreign-commits$'
# D60: the conductor rows are a scratch file, never the box's state/.
export PSC_CONDUCTOR_ROWS="$T/pr-state.tsv"; : > "$PSC_CONDUCTOR_ROWS"

R="$T/repo"; mkdir -p "$R"
git -C "$R" init -q -b main
git -C "$R" commit -q --allow-empty -m M0
c() { git -C "$R" commit -q --allow-empty -m "$1"; }
# br <name> [<from>] — a new branch off <from> (default main)
br() { git -C "$R" checkout -q "${2:-main}"; git -C "$R" checkout -qb "$1"; }
sha() { git -C "$R" rev-parse "$1"; }
check() { # check <base> <head> <body-text> [extra args] — sets RC and OUT
  local b="$1" h="$2" bt="$3"; shift 3
  printf '%s\n' "$bt" > "$T/body.md"
  OUT=$(PR_SELF_CHECK_CATALOG="${CAT:-$T/catalog.tsv}" bash "$H/bin/pr-self-check.sh" check \
          --repo "$R" --base "$b" --head "$h" --body "$T/body.md" "$@" 2>&1); RC=$?
}
has() { case "$OUT" in *"$1"*) return 0 ;; esac; return 1; }
nlines() { grep -c "^$1" <<<"$OUT"; }
BODY='Ticket BH-200 — y'

# ── fixtures ──
br ticket/bh-100; c "BH-100: x"; P100=$(sha HEAD)
# A copy, not the same commit: an identical empty commit would have the parent's sha.
br f1; c "BH-100: x, copied"; F1X=$(sha HEAD); c "BH-200: y"
[ "$F1X" != "$P100" ] && ok || bad "fixture: the copied BH-100 commit must not be the base's own commit"
br f2a ticket/bh-100; c "BH-200: y"
br f4; c "BH-200: read the BH-100 rows"
br f6; c "fix(BH-100): x"; c "BH-200: y"
br f7; c "spec(BH-100.2): plan"
br f8 ticket/bh-100; c "BH-300: z"; c "BH-200: y"
br f9; c "BH-200.1: y"
br f10; c "BH-150.1: y"
br f11; c "UTF-8: decode the body"
br f12; c "fix(ci-plan): x (BH-100)"
br f17; c 'Revert "BH-100: x"'
br f19; c "BH-100: a"; c "BH-100: b"; c "BH-200: y"
git -C "$R" branch -q ticket/bh-100-r2 ticket/bh-100
# F5: main gains a BH-100 commit after the branch started; the branch merges main.
br f5; c "BH-200: y"
git -C "$R" checkout -q main; c "BH-100: m"
git -C "$R" checkout -q f5; git -C "$R" merge -q --no-edit main; c "BH-200: z"

# ── F1 ──
check main f1 "$BODY" --key BH-200
[ "$RC" = 1 ] && has "REFUSE foreign-commits:" && has "BH-100" && has "${F1X:0:12}" && ok \
  || bad "F1: a BH-100 commit on a BH-200 PR based on main must refuse with its sha (rc=$RC) [$OUT]"
[ "$(nlines REFUSE)" = 1 ] && ok || bad "F1: only the BH-100 commit refuses, not the own BH-200 one [$OUT]"
has "ticket/bh-100" && ok || bad "F1: the refusal names the parent branch or PR [$OUT]"

# ── F2: base is the parent's branch ──
check ticket/bh-100 f1 "$BODY" --key BH-200
[ "$RC" = 0 ] && ! has REFUSE && ok || bad "F2: base ticket/bh-100 passes a copied BH-100 commit (rc=$RC) [$OUT]"
check ticket/bh-100 f2a "$BODY" --key BH-200
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "F2: base ticket/bh-100 with the commit in base is silent (rc=$RC) [$OUT]"
# The enqueue passes origin/<base ref>.
git -C "$R" update-ref refs/remotes/origin/ticket/bh-100 "$P100"
check origin/ticket/bh-100 f1 "$BODY" --key BH-200
[ "$RC" = 0 ] && ok || bad "F2: the enqueue's origin/ticket/bh-100 base form passes (rc=$RC) [$OUT]"

# ── F3 / F13: stacked + conductor row for this head ──
put_row() { # the mc_row_put column order: key state since head reviewed alerted reason url
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "o/r#9" STACKED_WAIT 2026-10-13T00:00:00Z "$1" - - "parent open" \
    "https://github.com/o/r/pull/9" > "$PSC_CONDUCTOR_ROWS"
}
put_row "$(sha f1)"
check main f1 $'Ticket BH-200 — y\n\nStacked on #7' --key BH-200
[ "$RC" = 0 ] && ! has REFUSE && ok || bad "F3: Stacked on #7 + STACKED_WAIT for this head passes (rc=$RC) [$OUT]"
check main f1 $'Ticket BH-200 — y\n\nSTACKED on `ticket/bh-100` (#7)' --key BH-200
[ "$RC" = 0 ] && ok || bad "F3: the build's own STACKED banner counts as the stack line (rc=$RC) [$OUT]"
check main f1 "$BODY" --key BH-200
[ "$RC" = 1 ] && ok || bad "F3: a STACKED_WAIT row with no stack line in the body still refuses (rc=$RC) [$OUT]"
put_row "$(sha f1~1)"
check main f1 $'Ticket BH-200 — y\n\nStacked on #7' --key BH-200
[ "$RC" = 1 ] && has "REFUSE foreign-commits:" && ok || bad "F13: a STACKED_WAIT row for an older head refuses (rc=$RC) [$OUT]"
: > "$PSC_CONDUCTOR_ROWS"

# ── F4, F5 ──
check main f4 "$BODY" --key BH-200
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "F4: a key inside the subject text is silent (rc=$RC) [$OUT]"
check main f5 "$BODY" --key BH-200
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "F5: a BH-100 commit through a merge of main is not foreign (rc=$RC) [$OUT]"
# F5 on a base the merged commit is NOT in: the walk is first-parent, so still not foreign.
check main~1 f5 "$BODY" --key BH-200
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "F5: the merged-in BH-100 commit is off the first-parent walk (rc=$RC) [$OUT]"

# ── F6, F7, F8 ──
check main f6 "$BODY" --key BH-200
[ "$RC" = 1 ] && has "BH-100" && ok || bad "F6: fix(BH-100): x refuses (rc=$RC) [$OUT]"
check main f7 "$BODY" --key BH-200
[ "$RC" = 1 ] && has "BH-100.2" && ok || bad "F7: spec(BH-100.2): plan refuses (rc=$RC) [$OUT]"
check ticket/bh-100 f8 "$BODY" --key BH-200
[ "$RC" = 1 ] && has "BH-300" && [ "$(nlines REFUSE)" = 1 ] && ok || bad "F8: base ticket/bh-100 still refuses a BH-300 commit, only that one (rc=$RC) [$OUT]"

# ── F9-F12, F14, F17 ──
check main f9 "$BODY" --key BH-200
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "F9: an own slice commit is silent (rc=$RC) [$OUT]"
check main f10 $'Ticket BH-200 — BH-150.1: x' --key BH-200
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "F10: the body's second first-line key is an own key (rc=$RC) [$OUT]"
check main f10 "$BODY" --key BH-200
[ "$RC" = 1 ] && ok || bad "F10: without the second key, BH-150.1 is foreign (rc=$RC) [$OUT]"
check main f11 "$BODY" --key BH-200
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "F11: UTF-8: is not a ticket key of this prefix (rc=$RC) [$OUT]"
check main f12 "$BODY" --key BH-200
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "F12: fix(ci-plan): x (BH-100) does not lead with a key (rc=$RC) [$OUT]"
check ticket/bh-100-r2 f1 "$BODY" --key BH-200
[ "$RC" = 0 ] && ok || bad "F14: base ticket/bh-100-r2 passes (rc=$RC) [$OUT]"
check main f17 "$BODY" --key BH-200
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "F17: a Revert subject is not foreign (rc=$RC) [$OUT]"

# ── F15: no own key ──
check main f1 'no ticket line here'
[ "$RC" = 0 ] && [ "$(nlines 'NOTE foreign-commits:')" = 1 ] && ! has REFUSE && ok \
  || bad "F15: no own key gives one NOTE and rc 0 (rc=$RC) [$OUT]"
# The body's first line alone is the key when --key is absent.
check main f1 "$BODY"
[ "$RC" = 1 ] && ok || bad "F15: the body's Ticket BH-200 line is the own key (rc=$RC) [$OUT]"

# ── F16: the row off ──
sed 's/^foreign-commits\trefuse\t/foreign-commits\toff\t/' "$T/catalog.tsv" > "$T/catalog-off.tsv"
grep -q $'^foreign-commits\toff\t' "$T/catalog-off.tsv" && ok || bad "F16: the catalog has no foreign-commits refuse row to turn off"
CAT="$T/catalog-off.tsv" check main f1 "$BODY" --key BH-200
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "F16: the row off passes F1 (rc=$RC) [$OUT]"

# ── F18: the owner PR in the message ──
git -C "$R" remote add origin https://github.com/o/r.git
# The stub runs inside the CLI's own bash, where $T is not set: bake the path in.
# gh_rest_var <var> GET <path> (the lib never calls $(gh_rest ...), BH-1585 lint).
eval "gh_rest_var() { local v=\"\$1\"; shift; echo \"\$*\" >> '$T/gh-calls'; printf -v \"\$v\" '%s' '[{\"number\":7}]'; }"
export -f gh_rest_var
: > "$T/gh-calls"
check main f19 "$BODY" --key BH-200
has "(#7)" && ok || bad "F18: the gh_rest lookup names #7 [$OUT]"
grep -qF 'repos/o/r/pulls?state=all&head=o:ticket/bh-100&per_page=1' "$T/gh-calls" && ok \
  || bad "F18: one pulls lookup by head ticket/bh-100 [$(cat "$T/gh-calls")]"
[ "$(wc -l < "$T/gh-calls")" = 1 ] && ok || bad "F18: one lookup per key root, not per commit [$(wc -l < "$T/gh-calls")]"
gh_rest_var() { return 75; }
export -f gh_rest_var
check main f1 "$BODY" --key BH-200
[ "$RC" = 1 ] && has "ticket/bh-100" && ! has "(#7)" && ok || bad "F18: a failed lookup falls back to the branch name (rc=$RC) [$OUT]"
unset -f gh_rest_var
check main f1 "$BODY" --key BH-200
[ "$RC" = 1 ] && has "the PR of ticket/bh-100" && ok || bad "F18: without gh_rest the line names ticket/bh-100 [$OUT]"
check main f1 $'Ticket BH-200 — y\n\nStacked on #7' --key BH-200
has "#7" && ok || bad "F18: without gh_rest, the body's Stacked on #7 is named [$OUT]"

# ── F19 ──
check main f19 "$BODY" --key BH-200
[ "$RC" = 1 ] && [ "$(nlines 'REFUSE foreign-commits:')" = 2 ] && ok || bad "F19: two BH-100 commits give two REFUSE lines (rc=$RC) [$OUT]"

# ── R1: the plan's REPRO, through the repo's own CLI and catalog ──
Q="$T/q"; g="git -C $Q"
mkdir -p "$Q"; $g init -q -b main && $g commit -q --allow-empty -m M0 && $g checkout -qb ticket/bh-200 \
  && $g commit -q --allow-empty -m "BH-100: x" && $g commit -q --allow-empty -m "BH-200: y"
printf 'Ticket BH-200 — y\n' > "$Q.body"
OUT=$(bash "$DIR/bin/pr-self-check.sh" check --repo "$Q" --base main --head HEAD --body "$Q.body" --key BH-200 --only '^foreign-commits$' 2>&1); RC=$?
[ "$RC" = 1 ] && has "REFUSE foreign-commits:" && ok || bad "R1: the REPRO refuses with the shipped catalog (rc=$RC) [$OUT]"

echo "pr-self-check-foreign-commits.bh-6394: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
