#!/bin/bash
# tests/plan-collisions-paren-prefix.bh-8899-test.sh — pc_resolved reads the
# decision word past a parenthetical (BH-8899). The planner and its repair pass
# write "- `name` (PR #N sha): combine — ...". The `(` cut the decision word to
# "", so the line read unresolved, and BH-6025, BH-7877, BH-8364 and BH-8848
# stopped PLAN_BLOCKED with every collision answered.
#
#   P1-P10  pc_resolved rc per line shape (0 combine, 1 unresolved, 2 needs-human)
#   L1-L4   the 4 stuck keys, one fixture each in the "(PR #N sha): combine" shape
#   N1      pc_note, the production reader, writes the matching Resolution
#
# PC_LIB overrides the lib path (default "$DIR/bin/lib/plan-collisions.sh"), so
# the suite can run against main's lib to show P1 is red there.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/plan-collisions-paren-prefix.bh-8899-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "${PC_LIB:-$DIR/bin/lib/plan-collisions.sh}" || exit 1

PASS=0 FAIL=0
n=0

# plan <lines...> — a plan.md in $T with the lines under `## Design collisions`.
plan() {
  n=$((n + 1))
  local f="$T/plan-$n.md"
  { printf '# Plan\n\n## Scope\n\nx\n\n## Design collisions\n\n'
    printf '%s\n' "$@"
    printf '\n## Size\n\nKIND: bug\n'; } > "$f"
  printf '%s' "$f"
}

# rc <id> <want> <plan> <name>
rc() {
  local got
  pc_resolved "$3" "$4"; got=$?
  if [ "$got" = "$2" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL $1: want rc $2, got rc $got" >&2; fi
}

P1='- `spawn_one` (PR #8351 abc123): combine — additive, keep both call sites'

rc P1 0 "$(plan "$P1")" spawn_one
rc P2 0 "$(plan '- `x`: combine — keep the new arg and default it to the old value')" x
rc P3 2 "$(plan '- `x` (PR #1): needs-human: which ships')" x
rc P4 1 "$(plan '- `x` (PR #1) see below')" x
rc P5 1 "$(plan '- `x` (PR #1): combine — short')" x
rc P6 0 "$(plan '- `x` (PR #1, main def456): **combine** — keep both guards in one body')" x
rc P7 0 "$(plan '- `x` — combine: keep the new arg and default it to the old value')" x
rc P8 0 "$(plan '- `x` (PR #1): combine — one body; this answers the earlier needs-human stop')" x
rc P9 1 "$(plan '- `x` (PR #1): sequence — ship after the other PR lands')" x
rc P10 1 "$(plan '- `x` and `y` differ: combine — keep both in one body today')" x

# L1-L4: one line per stuck key, in the shape the ticket quotes from their plans.
rc L1 0 "$(plan '- `pc_check` (PR #6021 4f1e2a9): combine — keep the new cap and the old fallback in one body')" pc_check
rc L2 0 "$(plan '- `queue_put` (PR #7870 9b03c1d): combine — additive, both PRs add one flag each to the same case')" queue_put
rc L3 0 "$(plan '- `review_level` (PR #8360 77ad0e2): **combine** — the other PR adds a level, ours reads it; keep both')" review_level
rc L4 0 "$(plan '- `spawn_one` (PR #8351 abc123): combine — additive, keep both call sites and the new flag')" spawn_one

# N1: pc_note is the production reader that turns the rc into the plan note.
col="$T/collisions.txt"
printf 'SYMBOLS: listed=1 derived=0 dropped=0 cap=40\nMAIN: checked a..b\nOPEN_PRS: checked 1\nSYMBOL\tlisted\tspawn_one\tfunction\nCOLLISION\tlisted\tspawn_one\t#8351\tabc123\tchanged in the PR\n' > "$col"
f=$(plan "$P1")
pc_note "$f" "$col" >/dev/null 2>&1
if grep -qF -- 'Resolution: combine.' "$f"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL N1: plan note has no 'Resolution: combine.'" >&2; sed -n '/Design collision check/,$p' "$f" >&2; fi

echo "plan-collisions-paren-prefix: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
