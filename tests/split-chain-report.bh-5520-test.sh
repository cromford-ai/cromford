#!/bin/bash
# tests/split-chain-report.bh-5520-test.sh — bin/split-chain-report.sh, the
# one-shot operator report that measures split against unsplit lead time and
# the real product size of merged split children (BH-5520, Task 1).
#
# R1  the median / percentile helpers on known arrays (odd, even, n=1, n=0).
# R2  title -> ticket key, body -> parent, body -> size budget.
# R3  the CLI over a gh stub: 3 children of #10 (2 merged, 10 h apart) and 6
#     unsplit PRs -> split.n=1, split.median_h=10, unsplit.n=6.
# R4  a child's merge commit adds bin/x.sh (+30) and tests/x-test.sh (+200) ->
#     lines_p50=30, because bin/size-scope.sh --filter drops the test.
# R5  a merge sha the clone lacks and cannot fetch -> unmeasured=1, not 0 lines.
# R6  the gh stub exits 75 on page 2 -> INCOMPLETE on stdout, exit 2, and the
#     JSON carries no decision.
# R8  (lead BLOCK on 95d38af8) no --slug: the default slug from
#     bin/lib/deployment.sh applies (HARNESS_DEPLOYMENT_FILE stub), exit 0 and
#     the same report as R3; a deployment file with no usable HARNESS_REPO is
#     exit 2, and a malformed --slug is still a usage error.
# R7  Rule A: n<5 on either side -> "no change:"; a CLI fixture with n=5 on
#     both sides proposes; and the pure decision helper over the plan's table.
#
# No network: gh is a stub in $T/bin, the repo is a scratch git repo with no
# remote, and the clock is pinned through SPLIT_CHAIN_NOW.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SCR="$DIR/bin/split-chain-report.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: want [$3] got [$2]"; fi; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "git missing — skipping"; exit 0; }

# The pinned clock: 2026-10-11T00:00:00Z.
NOW=1791676800
export SPLIT_CHAIN_NOW="$NOW"
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

# ---------------------------------------------------------------------------
# R1 / R2 — the pure helpers, sourced. Sourcing must run nothing.
# ---------------------------------------------------------------------------
if [ -r "$SCR" ]; then
  # shellcheck source=/dev/null
  SRC_OUT=$( (. "$SCR" </dev/null; echo "sourced-rc=$?") 2>&1 )
  eq "R1 sourcing runs no body" "$SRC_OUT" "sourced-rc=0"
  # shellcheck source=/dev/null
  . "$SCR"
fi
if command -v split_chain_median >/dev/null 2>&1; then
  eq "R1 median odd"   "$(split_chain_median 3 1 2)" "2"
  eq "R1 median even"  "$(split_chain_median 4 1 3 2)" "2.5"
  eq "R1 median n=1"   "$(split_chain_median 7)" "7"
  eq "R1 median n=0"   "$(split_chain_median)" ""
  eq "R1 p75 of 1..8"  "$(split_chain_pct 75 8 7 6 5 4 3 2 1)" "6"
  eq "R1 p90 of 1..10" "$(split_chain_pct 90 1 2 3 4 5 6 7 8 9 10)" "9"
  eq "R1 p75 n=1"      "$(split_chain_pct 75 1180)" "1180"
  eq "R1 p75 n=0"      "$(split_chain_pct 75)" ""
else
  bad "R1 split_chain_median/split_chain_pct are not defined"
fi
if command -v split_chain_title_key >/dev/null 2>&1; then
  eq "R2 title key plain"   "$(split_chain_title_key 'BH-5520: x')" "5520"
  eq "R2 title key bracket" "$(split_chain_title_key '[BH-12] y')" "12"
  eq "R2 title key first"   "$(split_chain_title_key 'BH-7: fold BH-8')" "7"
  eq "R2 title key none"    "$(split_chain_title_key 'chore: bump deps')" ""
  eq "R2 body parent" "$(split_chain_body_parent "$(printf 'Some text\nPart of #4985\nOrder: 2 of 3\n')")" "4985"
  eq "R2 body parent none" "$(split_chain_body_parent 'no parent here')" ""
  eq "R2 body budget" "$(split_chain_body_budget "$(printf 'x\nSize budget: at most 700 lines of product code across 20 files.\n')")" "700 20"
  eq "R2 body budget none" "$(split_chain_body_budget 'no budget')" ""
else
  bad "R2 split_chain_title_key/body_parent/body_budget are not defined"
fi

# ---------------------------------------------------------------------------
# Fixtures for the CLI: a scratch repo with two merge commits, a gh stub.
# ---------------------------------------------------------------------------
REPO="$T/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email fixture@example.invalid
git -C "$REPO" config user.name fixture
echo base > "$REPO/README.txt"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m base
# Merge 1: bin/x.sh +30, tests/x-test.sh +200.
git -C "$REPO" checkout -q -b f1
mkdir -p "$REPO/bin" "$REPO/tests"
seq 1 30 > "$REPO/bin/x.sh"
seq 1 200 > "$REPO/tests/x-test.sh"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m f1
git -C "$REPO" checkout -q main
git -C "$REPO" merge -q --no-ff -m "merge f1" f1
SHA1=$(git -C "$REPO" rev-parse HEAD)
# Merge 2: bin/y.sh +50 across one product file.
git -C "$REPO" checkout -q -b f2
seq 1 50 > "$REPO/bin/y.sh"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m f2
git -C "$REPO" checkout -q main
git -C "$REPO" merge -q --no-ff -m "merge f2" f2
SHA2=$(git -C "$REPO" rev-parse HEAD)
GONE=0123456789abcdef0123456789abcdef01234567

mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'STUB'
#!/bin/bash
# gh stub: `gh api <path>` -> $FX/<pulls|issues>-<page>.json, or [] past the end.
printf '%s\n' "$*" >> "$FX/gh.log"
[ "${1:-}" = api ] || exit 1
p="${2:-}"
case "$p" in
  repos/*/pulls\?*) kind=pulls ;;
  repos/*/issues\?*) kind=issues ;;
  *) exit 1 ;;
esac
page=$(printf '%s' "$p" | sed -n 's/.*[?&]page=\([0-9][0-9]*\).*/\1/p')
[ -n "$page" ] || page=1
[ -e "$FX/fail-$kind-$page" ] && exit 75
f="$FX/$kind-$page.json"
if [ -r "$f" ]; then cat "$f"; else echo '[]'; fi
STUB
chmod +x "$T/bin/gh"

# pr <num> <title> <created_epoch> <merged_epoch|null> <sha>
pr() {
  local m=null
  [ "$4" != null ] && m="\"$(iso "$4")\""
  jq -n --argjson n "$1" --arg t "$2" --arg c "$(iso "$3")" --argjson m "$m" --arg s "$5" \
    '{number:$n,title:$t,created_at:$c,updated_at:($m // $c),merged_at:$m,merge_commit_sha:$s}'
}
# issue <num> <body>
issue() { jq -n --argjson n "$1" --arg b "$2" '{number:$n,title:"fixture",body:$b}'; }
BUDGET='Size budget: at most 700 lines of product code across 20 files.'
H1=3600

# run_cli <fixture dir> [args...] -> sets OUT, RC; JSON at $1/out.json
run_cli() {
  local fx="$1"; shift
  OUT=$(FX="$fx" PATH="$T/bin:$PATH" HARNESS="$T/h" bash "$SCR" --slug demo-org/demo --days 14 \
        --repo "$REPO" --json "$fx/out.json" "$@" 2>"$fx/stderr")
  RC=$?
}

# ---------------------------------------------------------------------------
# R3 / R4 — split vs unsplit, and product-only child size.
# ---------------------------------------------------------------------------
FX3="$T/fx3"; mkdir -p "$FX3"
T0=$((NOW - 3*86400))
{
  pr 201 'BH-11: child one' "$T0" "$((T0 + 4*H1))" "$SHA1"
  pr 202 'BH-12: child two' "$((T0 + 2*H1))" "$((T0 + 10*H1))" "$SHA1"
  for k in 1 2 3 4 5 6; do
    pr "$((300 + k))" "BH-$((50 + k)): unsplit $k" "$((T0 + k*H1))" "$((T0 + k*H1 + 2*H1))" "$SHA2"
  done
  pr 399 'chore: no key' "$T0" "$((T0 + H1))" "$SHA2"
  pr 398 'BH-60: closed unmerged' "$T0" null ""
} | jq -s . > "$FX3/pulls-1.json"
{
  issue 10 'the parent'
  issue 11 "$(printf 'Part of #10\n%s\n' "$BUDGET")"
  issue 12 "$(printf 'Part of #10\n%s\n' "$BUDGET")"
  issue 13 "$(printf 'Part of #10\n%s\n' "$BUDGET")"
} | jq -s . > "$FX3/issues-1.json"
if [ -r "$SCR" ]; then run_cli "$FX3"; else OUT=""; RC=127; fi
eq "R3 exit" "$RC" "0"
J="$FX3/out.json"
eq "R3 split.n"         "$(jq -r '.split.n' "$J" 2>/dev/null)" "1"
eq "R3 split.median_h"  "$(jq -r '.split.median_h' "$J" 2>/dev/null)" "10"
eq "R3 unsplit.n"       "$(jq -r '.unsplit.n' "$J" 2>/dev/null)" "6"
eq "R3 unsplit.median_h" "$(jq -r '.unsplit.median_h' "$J" 2>/dev/null)" "2"
eq "R3 sources.prs_read" "$(jq -r '.sources.prs_read' "$J" 2>/dev/null)" "10"
eq "R3 decision n<5"    "$(jq -r '.decision' "$J" 2>/dev/null)" "no change: n<5"
eq "R4 children.n"      "$(jq -r '.children.n' "$J" 2>/dev/null)" "2"
eq "R4 lines_p50 (tests excluded)" "$(jq -r '.children.lines_p50' "$J" 2>/dev/null)" "30"
eq "R4 files_p75"       "$(jq -r '.children.files_p75' "$J" 2>/dev/null)" "1"
eq "R4 over_budget_n"   "$(jq -r '.children.over_budget_n' "$J" 2>/dev/null)" "0"
case "$OUT" in *"decision: no change: n<5"*) ok ;; *) bad "R3 stdout summary carries the decision: [$OUT]" ;; esac

# ---------------------------------------------------------------------------
# R5 — a merge sha the clone does not have and cannot fetch.
# ---------------------------------------------------------------------------
FX5="$T/fx5"; mkdir -p "$FX5"
{
  pr 211 'BH-21: child a' "$T0" "$((T0 + 3*H1))" "$SHA1"
  pr 212 'BH-22: child b' "$T0" "$((T0 + 5*H1))" "$GONE"
} | jq -s . > "$FX5/pulls-1.json"
{
  issue 21 "$(printf 'Part of #20\n%s\n' "$BUDGET")"
  issue 22 "$(printf 'Part of #20\n%s\n' "$BUDGET")"
} | jq -s . > "$FX5/issues-1.json"
if [ -r "$SCR" ]; then run_cli "$FX5"; else RC=127; fi
eq "R5 exit" "$RC" "0"
eq "R5 unmeasured" "$(jq -r '.children.unmeasured' "$FX5/out.json" 2>/dev/null)" "1"
eq "R5 measured n" "$(jq -r '.children.n' "$FX5/out.json" 2>/dev/null)" "1"
eq "R5 lines_p50 is the measured one, not 0" "$(jq -r '.children.lines_p50' "$FX5/out.json" 2>/dev/null)" "30"

# ---------------------------------------------------------------------------
# R6 — a failed read on page 2 is INCOMPLETE, exit 2, no decision.
# ---------------------------------------------------------------------------
FX6="$T/fx6"; mkdir -p "$FX6"
# A full first page (100 PRs, all inside the window) forces a page 2 read.
for k in $(seq 1 100); do
  pr "$((1000 + k))" "BH-$((2000 + k)): p$k" "$((NOW - 2*86400))" "$((NOW - 86400))" "$SHA2"
done | jq -s . > "$FX6/pulls-1.json"
echo '[]' > "$FX6/issues-1.json"
: > "$FX6/fail-pulls-2"
if [ -r "$SCR" ]; then run_cli "$FX6"; else OUT=""; RC=127; fi
eq "R6 exit" "$RC" "2"
case "$OUT" in INCOMPLETE:*) ok ;; *) bad "R6 stdout starts INCOMPLETE: [$OUT]" ;; esac
grep -q 'page=2' "$FX6/gh.log" 2>/dev/null && ok || bad "R6 the stub saw no page 2 read"
if [ -e "$FX6/out.json" ] && jq -e 'has("decision")' "$FX6/out.json" >/dev/null 2>&1; then
  bad "R6 an INCOMPLETE report carries a decision"
else ok; fi

# ---------------------------------------------------------------------------
# R7 — Rule A. n<5 (R3 above already asserted it on split n=1), the n=4 edge
# through the CLI, a CLI fixture that proposes at n=5, then the table.
# ---------------------------------------------------------------------------
# mk_rule_fx <dir> <split groups>: each group has 2 children merged 10 h after
# the first opened; 5 unsplit tickets each take 3 h.
mk_rule_fx() {
  local fx="$1" g="$2" i
  mkdir -p "$fx"
  {
    for i in $(seq 1 "$g"); do
      pr "$((500 + 2*i))" "BH-$((600 + 2*i)): c" "$T0" "$((T0 + 5*H1))" "$SHA2"
      pr "$((501 + 2*i))" "BH-$((601 + 2*i)): c" "$((T0 + H1))" "$((T0 + 10*H1))" "$SHA2"
    done
    for i in 1 2 3 4 5; do
      pr "$((700 + i))" "BH-$((800 + i)): u" "$T0" "$((T0 + 3*H1))" "$SHA2"
    done
  } | jq -s . > "$fx/pulls-1.json"
  {
    for i in $(seq 1 "$g"); do
      issue "$((600 + 2*i))" "$(printf 'Part of #%s\n%s\n' "$((900 + i))" "$BUDGET")"
      issue "$((601 + 2*i))" "$(printf 'Part of #%s\n%s\n' "$((900 + i))" "$BUDGET")"
    done
  } | jq -s . > "$fx/issues-1.json"
}
mk_rule_fx "$T/fx7a" 4
if [ -r "$SCR" ]; then run_cli "$T/fx7a"; else RC=127; fi
eq "R7 n=4 exit" "$RC" "0"
eq "R7 n=4 split.n" "$(jq -r '.split.n' "$T/fx7a/out.json" 2>/dev/null)" "4"
eq "R7 n=4 refuses" "$(jq -r '.decision' "$T/fx7a/out.json" 2>/dev/null)" "no change: n<5"
mk_rule_fx "$T/fx7b" 5
if [ -r "$SCR" ]; then run_cli "$T/fx7b"; else RC=127; fi
eq "R7 n=5 exit" "$RC" "0"
eq "R7 n=5 split.median_h" "$(jq -r '.split.median_h' "$T/fx7b/out.json" 2>/dev/null)" "10"
eq "R7 n=5 proposes" "$(jq -r '.decision' "$T/fx7b/out.json" 2>/dev/null)" "propose 1200/30"
# An empty window is n=0 and refuses, it is not INCOMPLETE.
mkdir -p "$T/fx7c"; echo '[]' > "$T/fx7c/pulls-1.json"; echo '[]' > "$T/fx7c/issues-1.json"
if [ -r "$SCR" ]; then run_cli "$T/fx7c"; else RC=127; fi
eq "R7 empty window exit" "$RC" "0"
eq "R7 empty window decision" "$(jq -r '.decision' "$T/fx7c/out.json" 2>/dev/null)" "no change: n<5"

# The plan's Rule A table, through the decision helper:
# split_chain_decide <split median h> <unsplit median h> <child lines p75> <child files p90> <n split> <n unsplit>
if command -v split_chain_decide >/dev/null 2>&1; then
  eq "R7 table proposes"          "$(split_chain_decide 25.2 2.7 900 22 115 210)" "propose 1200/30"
  eq "R7 table edge p75=1200 n=5" "$(split_chain_decide 10 3 1200 30 5 5)" "propose 1200/30"
  eq "R7 table no lead gap"       "$(split_chain_decide 2.0 2.7 900 22 115 210)" "no change: split not slower"
  eq "R7 table equal lead"        "$(split_chain_decide 2.7 2.7 900 22 115 210)" "no change: split not slower"
  eq "R7 table child p75 1201"    "$(split_chain_decide 25 3 1201 22 115 210)" "no change: child p75 > 1200"
  eq "R7 table child files p90 31" "$(split_chain_decide 25 3 900 31 115 210)" "no change: child files p90 > 30"
  eq "R7 table n=4 split"         "$(split_chain_decide 25 3 900 22 4 210)" "no change: n<5"
  eq "R7 table n=4 unsplit"       "$(split_chain_decide 25 3 900 22 115 4)" "no change: n<5"
  eq "R7 table no measured child" "$(split_chain_decide 25 3 '' '' 115 210)" "no change: no measured child"
else
  bad "R7 split_chain_decide is not defined"
fi

# ---------------------------------------------------------------------------
# R8 — the default slug (no --slug), the documented operator command.
# ---------------------------------------------------------------------------
printf 'HARNESS_REPO=demo-org/demo\n' > "$T/deploy-ok.sh"
printf 'HARNESS_REPO=\n' > "$T/deploy-empty.sh"
if [ -r "$SCR" ]; then
  OUT=$(FX="$FX3" PATH="$T/bin:$PATH" HARNESS="$T/h" HARNESS_DEPLOYMENT_FILE="$T/deploy-ok.sh" \
        bash "$SCR" --days 14 --repo "$REPO" --json "$FX3/out8.json" 2>"$FX3/stderr8"); RC=$?
else OUT=""; RC=127; fi
eq "R8 no --slug exit" "$RC" "0"
eq "R8 no --slug split.n" "$(jq -r '.split.n' "$FX3/out8.json" 2>/dev/null)" "1"
eq "R8 no --slug unsplit.n" "$(jq -r '.unsplit.n' "$FX3/out8.json" 2>/dev/null)" "6"
if [ -r "$SCR" ]; then
  FX="$FX3" PATH="$T/bin:$PATH" HARNESS="$T/h" HARNESS_DEPLOYMENT_FILE="$T/deploy-empty.sh" \
    bash "$SCR" --days 14 --repo "$REPO" >/dev/null 2>&1; RC=$?
else RC=127; fi
eq "R8 an empty default slug is exit 2" "$RC" "2"
if [ -r "$SCR" ]; then
  FX="$FX3" PATH="$T/bin:$PATH" HARNESS="$T/h" bash "$SCR" --slug 'not a slug' --days 14 >/dev/null 2>&1; RC=$?
else RC=127; fi
eq "R8 a malformed --slug is a usage error" "$RC" "1"

# Usage error is exit 1.
if [ -r "$SCR" ]; then
  bash "$SCR" --days abc >/dev/null 2>&1; eq "usage exit" "$?" "1"
else bad "usage: $SCR is missing"; fi

echo "split-chain-report.bh-5520: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
