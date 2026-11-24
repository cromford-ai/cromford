#!/bin/bash
# tests/plan-collisions-prefilter.bh-9944-test.sh — BH-9944: the open-PR half of
# the design-collision check reads each PR ONE time and runs the per-symbol git
# reads only for a symbol the PR can touch. The COLLISION rows are the same as
# the old loop's.
#
# THE BUG (pool machines, 2026-11-23). pc_pr_hits called pc_hit for every
# symbol and every open PR: 40 symbols x 51 PRs, 2 to 4 whole-tree git greps a
# call. The PLAN stage of cromford waited 2 to 6 hours there and hit its
# cap (BH-9268 after 23,526 s, BH-9312 after 21,682 s, BH-9935 after 8,015 s).
#
#   P1  the rows with the pre-filter on are byte-equal to the rows with it off,
#       over 6 PRs: a changed body whose patch does not hold the name, a removed
#       function, a function moved to a new file, a route text match, a body
#       changed and then reverted, and a PR that touches no symbol
#   P2  each of the 5 touching PRs has its expected row (the fixture is not
#       trivially empty), and the PR that touches nothing has none
#   P3  with the pre-filter on, the PR that touches no symbol makes 0 pc_hit
#       calls; with it off, 1 call a symbol
#   P4  over the 6 PRs the pre-filter makes fewer calls than the old loop
#   P5  the knob: 0, off, FALSE turn it off; an unknown value keeps it on
#   P6  a PR range that cannot be read falls back to the old loop for that PR
#
# WHAT IS DRIVEN. The real bin/plan-collisions.sh and bin/lib/plan-collisions.sh
# from a scratch_install_closure tree, against a scratch git repo with a local
# bare origin (the rig of tests/plan-collisions.bh-5791-test.sh). No vendor is
# called (BH-7563): gh is a local stub that answers the open-PR list.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/plan-collisions-prefilter.bh-9944-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$T/fakebin" "$T/calls"
scratch_install_closure bin/plan-collisions.sh "$H" >/dev/null || bad "P0: closure install failed for bin/plan-collisions.sh"

cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
echo "$*" >> "$CALLS/gh"
printf 'HTTP/2.0 200 OK\r\nContent-Type: application/json\r\n\r\n'
cat "$PULLS"
SH
chmod +x "$T/fakebin/gh"
export CALLS="$T/calls" PULLS="$T/pulls.json" GH_ETAG=0 HARNESS="$H"

# ── the git fixture ──────────────────────────────────────────────────────────
G() { git -c user.email=t@example.com -c user.name=tester -c commit.gpgsign=false "$@"; }
O="$T/origin.git"; R="$T/repo"
git init -q --bare -b main "$O"
git init -q -b main "$R"
cd "$R" || exit 1
git remote add origin "$O"
mkdir -p lib
# fn <name> — a 13-line function. An edit of its `tail` line leaves the def
# line outside the 3 context lines of the hunk, and the unindented pad line is
# what git prints as the hunk header, so the patch does not hold the name.
fn() {
  printf '%s() {\n' "$1"
  printf 'pad_marker=1\n'
  printf '  local a=1\n  local b=2\n  local c=3\n  local d=4\n  local e=5\n  local f=6\n  local g=7\n'
  printf '  echo "tail %s"\n' "${2:-one}"
  printf '  local h=8\n  local i=9\n}\n'
}
{ printf '#!/bin/bash\n'; fn big_fn; fn gone_fn; fn move_fn; fn flip_fn; fn quiet_fn; } > lib/core.sh
cat > lib/api.js <<'JS'
export function handle(req) {
  if (req.route === 'GET /api/flags') return 1;
  return 0;
}
JS
printf 'nothing here\n' > lib/other.txt
G add -A && G commit -qm "base" && G push -q origin main 2>/dev/null
BASE_SHA=$(git rev-parse HEAD)
push_pr() { G push -q -f origin "HEAD:refs/pull/$1/head" 2>/dev/null; git rev-parse --short=12 HEAD > "$T/pr$1.sha"; }

# 21: a changed body; the patch does not hold the name big_fn.
G checkout -q -B pr21 "$BASE_SHA"
awk 'BEGIN{n=0} /echo "tail one"/ { n++; if (n == 1) { sub(/tail one/, "tail two") } } { print }' lib/core.sh > "$T/x" && cp "$T/x" lib/core.sh
G commit -qam "pr 21: big_fn body" && push_pr 21
G show --format= HEAD > "$T/pr21.patch"
[ -s "$T/pr21.patch" ] && ! grep -q big_fn "$T/pr21.patch" && ok || bad "P0: the pr 21 patch must not hold the name big_fn (the fixture is too weak)"
# 22: gone_fn removed.
G checkout -q -B pr22 "$BASE_SHA"
{ printf '#!/bin/bash\n'; fn big_fn; fn move_fn; fn flip_fn; fn quiet_fn; } > lib/core.sh
G commit -qam "pr 22: gone_fn removed" && push_pr 22
# 23: move_fn moved to a new file, with a new body.
G checkout -q -B pr23 "$BASE_SHA"
{ printf '#!/bin/bash\n'; fn big_fn; fn gone_fn; fn flip_fn; fn quiet_fn; } > lib/core.sh
{ printf '#!/bin/bash\n'; fn move_fn moved; } > lib/moved.sh
G add -A && G commit -qm "pr 23: move_fn moved" && push_pr 23
# 24: the route text changes inside handle.
G checkout -q -B pr24 "$BASE_SHA"
sed -i "s/'GET \/api\/flags') return 1/'GET \/api\/flags') return 2/" lib/api.js
G commit -qam "pr 24: route" && push_pr 24
# 25: flip_fn body changed, then changed back (the net diff is empty).
G checkout -q -B pr25 "$BASE_SHA"
awk 'BEGIN{n=0} /echo "tail one"/ { n++; if (n == 4) { sub(/tail one/, "tail flip") } } { print }' lib/core.sh > "$T/x" && cp "$T/x" lib/core.sh
G commit -qam "pr 25: flip_fn body"
git show "$BASE_SHA:lib/core.sh" > lib/core.sh
G commit -qam "pr 25: flip_fn back" && push_pr 25
[ -z "$(git diff --name-only "$BASE_SHA" HEAD)" ] || bad "P0: the pr 25 net diff must be empty"
# 26: touches no symbol.
G checkout -q -B pr26 "$BASE_SHA"
printf 'still nothing\n' > lib/other.txt
G commit -qam "pr 26: other" && push_pr 26
G checkout -q -B ticket/bh-9944 "$BASE_SHA"
G fetch -q origin 2>/dev/null

pulls() { # pulls <n>... — the open-PR list
  local n sep="" out="["
  for n in "$@"; do out="$out$sep{\"number\":$n,\"title\":\"X-$n: a change\",\"head\":{\"ref\":\"feature-$n\"}}"; sep=","; done
  printf '%s]\n' "$out" > "$PULLS"
}
cat > "$T/plan.md" <<'MD'
# BH-9944 fixture plan

## Changed symbols

- function `big_fn`: changes.
- function `gone_fn`: changes.
- function `move_fn`: changes.
- function `flip_fn`: changes.
- function `quiet_fn`: changes.
- function `handle`: changes.
- route `GET /api/flags`: answers 2.
- verb `flags-cli.sh`: a new verb.
MD
NSYM=8

# pc <prefilter value> — run the CLI; RC, $T/col.txt, $T/pc.err, ROWS, LINE
pc() {
  ( cd "$R" && PLAN_COLLISION_PREFILTER="$1" PATH="$T/fakebin:$PATH" "$H/bin/plan-collisions.sh" --plan "$T/plan.md" \
      --repo "$R" --base "$BASE_SHA" --main origin/main --slug o/r --self-branch ticket/bh-9944 --self-key BH-9944 \
      --out "$T/col.txt" >"$T/pc.out" 2>"$T/pc.err" ); RC=$?
  ROWS=$(grep '^COLLISION' "$T/col.txt" 2>/dev/null | LC_ALL=C sort)
  LINE=$(grep '^plan-collisions: open PRs read=' "$T/pc.err" | tail -1)
}
field() { printf '%s\n' "$LINE" | sed -nE "s/.*(^| )$1=([0-9]+).*/\2/p"; }
TAB=$'\t'
has() { grep -qF -e "$1" <<<"$ROWS"; }

# ============================================================================
# P1 + P2 + P4. Six PRs, pre-filter off and on.
# ============================================================================
pulls 21 22 23 24 25 26
pc 0
OFF_ROWS="$ROWS"; OFF_CALLS=$(field calls); OFF_SKIP=$(field skipped)
[ "$(field read)" = 6 ] && ok || bad "P1: the old loop reads 6 PRs ($LINE; $(cat "$T/pc.err"))"
[ "$OFF_CALLS" = $((6 * NSYM)) ] && [ "$OFF_SKIP" = 0 ] && ok || bad "P1: the old loop makes 6 x $NSYM calls and skips 0 ($LINE)"
[ "$(field prefilter)" = 0 ] && ok || bad "P1: the line says prefilter=0 ($LINE)"
pc 1
ON_ROWS="$ROWS"; ON_CALLS=$(field calls); ON_SKIP=$(field skipped)
[ -n "$OFF_ROWS" ] && [ "$ON_ROWS" = "$OFF_ROWS" ] && ok \
  || bad "P1: THE CONTRACT: the rows differ. off: $(printf '%s' "$OFF_ROWS" | tr '\n' '|') on: $(printf '%s' "$ON_ROWS" | tr '\n' '|')"
[ "$(field prefilter)" = 1 ] && [ "$(field read)" = 6 ] && ok || bad "P1: the line says prefilter=1 read=6 ($LINE)"
[ "$((ON_CALLS + ON_SKIP))" = $((6 * NSYM)) ] && ok || bad "P1: calls + skipped is every (PR, symbol) pair ($LINE)"
has "COLLISION${TAB}listed${TAB}big_fn${TAB}#21${TAB}$(cat "$T/pr21.sha")${TAB}body or signature changed" && ok \
  || bad "P2: pr 21 changed the body of big_fn and its patch does not hold the name: $(printf '%s' "$ON_ROWS" | tr '\n' '|')"
has "COLLISION${TAB}listed${TAB}gone_fn${TAB}#22${TAB}" && ok || bad "P2: pr 22 removed gone_fn"
has "COLLISION${TAB}listed${TAB}move_fn${TAB}#23${TAB}" && ok || bad "P2: pr 23 moved move_fn"
has "COLLISION${TAB}listed${TAB}GET /api/flags${TAB}#24${TAB}" && ok || bad "P2: pr 24 changed the route text"
has "COLLISION${TAB}listed${TAB}handle${TAB}#24${TAB}" && ok || bad "P2: pr 24 changed the body of handle"
has "COLLISION${TAB}listed${TAB}flip_fn${TAB}#25${TAB}" && ok || bad "P2: pr 25 changed flip_fn and changed it back (the net diff is empty)"
has "${TAB}#26${TAB}" && bad "P2: pr 26 touches no symbol and must have no row" || ok
has "${TAB}quiet_fn${TAB}" && bad "P2: no PR touches quiet_fn" || ok
[ "$ON_CALLS" -lt "$OFF_CALLS" ] && ok || bad "P4: the pre-filter makes fewer pc_hit calls ($ON_CALLS vs $OFF_CALLS)"

# ============================================================================
# P3. One PR that touches no symbol: 0 calls.
# ============================================================================
pulls 26
pc 1
[ "$(field calls)" = 0 ] && [ "$(field skipped)" = "$NSYM" ] && [ -z "$ROWS" ] && [ "$RC" = 0 ] && ok \
  || bad "P3: THE BUG: a PR that touches no symbol must cost 0 pc_hit calls ($LINE rc=$RC)"
pc 0
[ "$(field calls)" = "$NSYM" ] && [ -z "$ROWS" ] && ok || bad "P3: the old loop makes $NSYM calls for it ($LINE)"

# ============================================================================
# P5. The knob.
# ============================================================================
pulls 21 26
for v in off FALSE no; do
  pc "$v"
  [ "$(field prefilter)" = 0 ] && [ "$(field skipped)" = 0 ] && ok || bad "P5: PLAN_COLLISION_PREFILTER=$v turns it off ($LINE)"
done
pc maybe
[ "$(field prefilter)" = 1 ] && [ "$(field skipped)" -gt 0 ] && ok || bad "P5: an unknown value keeps the pre-filter on ($LINE)"

# ============================================================================
# P6. A range that cannot be read: the old loop for that PR, the same rows.
# ============================================================================
pulls 21 26
pc 1; WANT="$ROWS"
mkdir -p "$T/gitwrap"
cat > "$T/gitwrap/git" <<SH
#!/bin/bash
# fails the one read _pc_pr_text starts with; every other git call passes.
for a in "\$@"; do [ "\$a" = --no-ext-diff ] && exit 1; done
exec "$(command -v git)" "\$@"
SH
chmod +x "$T/gitwrap/git"
( cd "$R" && PLAN_COLLISION_PREFILTER=1 PATH="$T/gitwrap:$T/fakebin:$PATH" "$H/bin/plan-collisions.sh" --plan "$T/plan.md" \
    --repo "$R" --base "$BASE_SHA" --main origin/main --slug o/r --self-branch ticket/bh-9944 --self-key BH-9944 \
    --out "$T/col.txt" >"$T/pc.out" 2>"$T/pc.err" )
ROWS=$(grep '^COLLISION' "$T/col.txt" 2>/dev/null | LC_ALL=C sort)
LINE=$(grep '^plan-collisions: open PRs read=' "$T/pc.err" | tail -1)
[ "$ROWS" = "$WANT" ] && [ -n "$ROWS" ] && ok || bad "P6: an unreadable range must give the same rows ($(printf '%s' "$ROWS" | tr '\n' '|'))"
[ "$(field calls)" = $((2 * NSYM)) ] && [ "$(field skipped)" = 0 ] && ok || bad "P6: an unreadable range falls back to every symbol ($LINE)"

echo "plan-collisions-prefilter.bh-9944-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
