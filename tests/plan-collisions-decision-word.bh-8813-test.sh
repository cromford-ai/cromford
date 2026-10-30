#!/bin/bash
# tests/plan-collisions-decision-word.bh-8813-test.sh — pc_resolved reads the
# decision word only (BH-8813). The first word after the backticked name on a
# `## Design collisions` line decides; the same word later on the line does not.
# On BH-7305 a resolved `combine` line that mentioned "the earlier needs-human
# stop" read as needs-human, and the ticket looped through 37 PLAN_BLOCKED builds.
#
#   D1-D14  pc_resolved rc per line shape (0 combine, 1 unresolved, 2 needs-human)
#   N1-N2   pc_note, the production reader, writes the matching Resolution
#
# PC_LIB overrides the lib path (default "$DIR/bin/lib/plan-collisions.sh"), so
# the suite can run against main's lib to show D1 is red there.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/plan-collisions-decision-word.bh-8813-test.sh
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

D1='- `x`: combine. Keep both guards in one body. This answers the earlier needs-human stop.'
D5='- `x`: needs-human: which PR ships'

rc D1 0 "$(plan "$D1")" x
rc D2 0 "$(plan '- `x`: combine — keep the new arg and default it to the old value')" x
rc D3 0 "$(plan '- `x` — combine — keep the new arg and default it to the old value')" x
rc D4 0 "$(plan '- `x`: **combine** — keep the new arg and default it to the old value')" x
rc D5 2 "$(plan "$D5")" x
rc D6 2 "$(plan '- `x`: Needs-Human — main and ours disagree')" x
rc D7 2 "$(plan '- `x`: needs-human — we could combine them if the flag stays')" x
rc D8 1 "$(plan '- `x`: combine — short')" x
rc D9 1 "$(plan '- `x`: we should look at this later')" x
rc D10 1 "$(plan '- `x`: sequence — ship after the other PR, it changes the needs-human path')" x
rc D11 1 "$(plan '- `a`: combine — keep both, unlike `x`, which needs-human review')" x
n=$((n + 1)); printf '# Plan\n\n## Scope\n\nx\n\n## Size\n\nKIND: bug\n' > "$T/plan-$n.md"
rc D12 1 "$T/plan-$n.md" x
rc D13 2 "$(plan "$D1" "$D5")" x
rc D14 1 "$(plan '- `x`: unsure, we could combine the two designs if the flag stays')" x

# N1-N2: pc_note is the production reader that turns the rc into the plan note.
col="$T/collisions.txt"
printf 'SYMBOLS: listed=1 derived=0 dropped=0 cap=40\nMAIN: checked a..b\nOPEN_PRS: checked 0\nSYMBOL\tlisted\tx\tfunction\nCOLLISION\tlisted\tx\tmain\tabc123\tchanged after the base\n' > "$col"
note() { # note <id> <want-text> <plan>
  pc_note "$3" "$col" >/dev/null 2>&1
  if grep -qF -- "$2" "$3"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL $1: plan note has no '$2'" >&2; sed -n '/Design collision check/,$p' "$3" >&2; fi
}
note N1 'Resolution: combine.' "$(plan "$D1")"
note N2 'Resolution: needs-human.' "$(plan "$D5")"

echo "plan-collisions-decision-word: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
