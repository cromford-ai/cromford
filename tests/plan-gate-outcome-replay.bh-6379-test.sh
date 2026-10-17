#!/bin/bash
# tests/plan-gate-outcome-replay.bh-6379-test.sh — BH-6379 (BH-6372.1): the
# plan validator (bin/plan-gate.sh) refuses a perf/cost plan that does not state
# a target metric and an outcome-replay acceptance test. Every case runs the
# real gate on a mutation of tests/fixtures/bh-6372/plan-perf-complete.md.
#
#   P1  PLAN_GATE_PERF=1, no `Target metric:` line: rc 2, gap named, missing
#   P2  `from 1 to 1`: rc 2, "no direction"
#   P3  no acceptance item names an outcome replay: rc 2
#   P4  "top miss" removed: rc 2, that gap only
#   P5  "hit rate" removed: rc 2, that gap only
#   P6  the complete plan, PLAN_GATE_PERF=1: rc 0, ok, PLAN_TRACE: ok
#   P7  no `## Target metric` heading, PLAN_GATE_PERF unset, prose with the
#       words: n/a, rc 0
#   P8  PLAN_GATE_PERF=1 on a plan the trace parser cannot read (rc 3): stays 3
#   P9  the gap line rides the plan.sh PG_LIST sed and pt_repair_note
#   P10 the heading alone opts in (PLAN_GATE_PERF unset): rc 2
#   P11 `from 1 to 1.0`: rc 2
#   P12 terms split across two items, or in a fenced block only: rc 2;
#       `Outcome-Replay` (hyphen, title case) in a full item: rc 0
#   P13 a `###` sub-heading inside Acceptance tests ends the item: a hit rate
#       under it is not part of the replay item
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/plan-gate-outcome-replay.bh-6379-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

GATE="$DIR/bin/plan-gate.sh"
LIB="$DIR/bin/lib/perf-plan-rule.sh"
FX="$DIR/tests/fixtures/bh-6372/plan-perf-complete.md"
[ -r "$FX" ] || { echo "fixture missing: $FX"; exit 1; }
unset PLAN_GATE_PERF PLAN_GATE_HOTSPOTS PLAN_FAILURE_MODES_CATALOG OUTCOME_REPLAY_N

# gate <plan> [VAR=value ...] — runs the real gate; sets G (output) and GRC.
gate() { local p="$1"; shift; G=$(env "$@" "$GATE" "$p" 2>&1); GRC=$?; }
mut() { sed "$2" "$FX" > "$T/$1.md"; }   # mut <name> <sed script>

# P1 — the target line deleted. Red on main: the gate has no such block there.
mut p1 '/^Target metric:/d'
gate "$T/p1.md" PLAN_GATE_PERF=1
[ "$GRC" = 2 ] && ok || bad "P1: no Target metric line must be rc 2 (got $GRC: $G)"
grep -q "^  UNTRACED: outcome replay — no 'Target metric:" <<<"$G" && ok || bad "P1: the gap must be named: $G"
grep -qx 'PLAN_OUTCOME_REPLAY: missing' <<<"$G" && ok || bad "P1: PLAN_OUTCOME_REPLAY: missing expected: $G"
[ "$(tail -1 <<<"$G")" = "PLAN_TRACE: untraced" ] && ok || bad "P1: PLAN_TRACE: untraced must stay the last line: $G"
P1OUT=$G

# P2 — no direction.
mut p2 's/^Target metric:.*/Target metric: mq-full-share from 1 to 1/'
gate "$T/p2.md" PLAN_GATE_PERF=1
[ "$GRC" = 2 ] && ok || bad "P2: from 1 to 1 must be rc 2 (got $GRC: $G)"
grep -q 'UNTRACED: outcome replay — Target metric mq-full-share from 1 to 1 has no direction' <<<"$G" && ok || bad "P2: 'no direction' gap expected: $G"

# P3 — the replay item deleted.
mut p3 '/R1: the outcome replay/,/measured:/d'
gate "$T/p3.md" PLAN_GATE_PERF=1
[ "$GRC" = 2 ] && ok || bad "P3: no replay item must be rc 2 (got $GRC: $G)"
grep -q "UNTRACED: outcome replay — no '## Acceptance tests' item names an outcome replay" <<<"$G" && ok || bad "P3: gap expected: $G"

# P4 — "top miss" removed.
mut p4 's/, and lists the top miss reasons//'
grep -qi 'top miss' "$T/p4.md" && bad "P4: mutation did not remove 'top miss'"
gate "$T/p4.md" PLAN_GATE_PERF=1
[ "$GRC" = 2 ] && ok || bad "P4: no top miss must be rc 2 (got $GRC: $G)"
grep -q 'UNTRACED: outcome replay — the outcome-replay acceptance item does not name the top miss reasons' <<<"$G" && ok || bad "P4: top-miss gap expected: $G"
grep -q 'does not name a hit rate' <<<"$G" && bad "P4: no hit-rate gap expected: $G" || ok

# P5 — "hit rate" removed.
mut p5 's/It names the hit rate of the fallback path/It names the fallback path/'
grep -qi 'hit rate' "$T/p5.md" && bad "P5: mutation did not remove 'hit rate'"
gate "$T/p5.md" PLAN_GATE_PERF=1
[ "$GRC" = 2 ] && ok || bad "P5: no hit rate must be rc 2 (got $GRC: $G)"
grep -q 'UNTRACED: outcome replay — the outcome-replay acceptance item does not name a hit rate' <<<"$G" && ok || bad "P5: hit-rate gap expected: $G"
grep -q 'top miss reasons' <<<"$G" && bad "P5: no top-miss gap expected: $G" || ok

# P6 — complete.
gate "$FX" PLAN_GATE_PERF=1
[ "$GRC" = 0 ] && ok || bad "P6: the complete plan must be rc 0 (got $GRC: $G)"
grep -qx 'PLAN_OUTCOME_REPLAY: ok' <<<"$G" && ok || bad "P6: PLAN_OUTCOME_REPLAY: ok expected: $G"
grep -qx 'PLAN_TRACE: ok' <<<"$G" && ok || bad "P6: PLAN_TRACE: ok expected: $G"
P6OUT=$G

# P7 — non-perf: no heading, no env, prose that names the words.
mut p7 '/^## Target metric$/d; /^Target metric:/d; s/^Cut the merge-queue run time\./Cut the merge-queue run time. The target metric is the queue share; an outcome replay is not needed./'
grep -qi 'target metric' "$T/p7.md" && ok || bad "P7: the prose must still name the words"
gate "$T/p7.md"
[ "$GRC" = 0 ] && ok || bad "P7: a non-perf plan must keep rc 0 (got $GRC: $G)"
grep -qx 'PLAN_OUTCOME_REPLAY: n/a' <<<"$G" && ok || bad "P7: PLAN_OUTCOME_REPLAY: n/a expected: $G"
gate "$T/p7.md" PLAN_GATE_PERF=0
grep -qx 'PLAN_OUTCOME_REPLAY: n/a' <<<"$G" && [ "$GRC" = 0 ] && ok || bad "P7: PLAN_GATE_PERF=0 with no heading must be n/a, rc 0 (got $GRC: $G)"

# P8 — rc 3 stays 3.
printf '# WD-9\nProse with no task blocks.\n\n## Acceptance tests\n- tests/x.test.ts — VALIDATE: `npm test`, SATISFIES: criterion 1\nSIZE: S\n' > "$T/p8.md"
gate "$T/p8.md" PLAN_GATE_PERF=1
[ "$GRC" = 3 ] && ok || bad "P8: an unavailable plan must stay rc 3 (got $GRC: $G)"
grep -qx 'PLAN_OUTCOME_REPLAY: missing' <<<"$G" && ok || bad "P8: the block still reports its gaps: $G"
[ "$(tail -1 <<<"$G")" = "PLAN_TRACE: unavailable" ] && ok || bad "P8: verdict must be unavailable: $G"

# P9 — round-trip into the plan.sh repair pass.
L=$(sed -n 's/^  UNTRACED: //p' <<<"$P1OUT")
grep -q '^outcome replay — ' <<<"$L" && ok || bad "P9: PG_LIST sed must carry the gap: $L"
printf '%s\n' "$P1OUT" > "$T/p1-gate.txt"; printf '%s\n' "$P6OUT" > "$T/p6-gate.txt"
N=$(bash -c '. "$1" && pt_repair_note "$2"' _ "$LIB" "$T/p1-gate.txt")
grep -q "Target metric: <id> from <n> to <n>" <<<"$N" && ok || bad "P9: pt_repair_note must name the Target metric line: $N"
N=$(bash -c '. "$1" && pt_repair_note "$2"' _ "$LIB" "$T/p6-gate.txt")
[ -z "$N" ] && ok || bad "P9: pt_repair_note on a clean gate output must print nothing: $N"

# P10 — the heading opts in.
mut p10 '/^Target metric:/d'
gate "$T/p10.md"
[ "$GRC" = 2 ] && ok || bad "P10: a ## Target metric heading must opt in (got $GRC: $G)"
grep -q "UNTRACED: outcome replay — no 'Target metric:" <<<"$G" && ok || bad "P10: gap expected: $G"

# P11 — 1 and 1.0 are the same number.
mut p11 's/^Target metric:.*/Target metric: mq-full-share from 1 to 1.0/'
gate "$T/p11.md" PLAN_GATE_PERF=1
[ "$GRC" = 2 ] && ok || bad "P11: from 1 to 1.0 must be rc 2 (got $GRC: $G)"
grep -q 'has no direction' <<<"$G" && ok || bad "P11: 'no direction' gap expected: $G"

# P12 — split terms and fenced terms do not count; hyphen + case does.
mut p12 's/^  It names the hit rate of the fallback path (a full run when the ledger is unreachable)\./  ```\n  hit rate: 0.4\n  ```/; s/^## QA screens/- tests\/x-test.sh H1: the hit rate of the fallback path.\n\n## QA screens/'
grep -c 'hit rate' "$T/p12.md" | grep -qx 2 && ok || bad "P12: the mutation must leave hit rate in a fence and a second item"
gate "$T/p12.md" PLAN_GATE_PERF=1
[ "$GRC" = 2 ] && ok || bad "P12: split terms must be rc 2 (got $GRC: $G)"
grep -q 'does not name a hit rate' <<<"$G" && ok || bad "P12: hit-rate gap expected: $G"
mut p12b 's/R1: the outcome replay/R1: the Outcome-Replay/'
gate "$T/p12b.md" PLAN_GATE_PERF=1
[ "$GRC" = 0 ] && ok || bad "P12: 'Outcome-Replay' must match (got $GRC: $G)"

# P13 — a sub-heading ends the item.
mut p13 's/^  It names the hit rate of the fallback path (a full run when the ledger is unreachable)\./\n### Fallbacks\nThe hit rate of the fallback path is reported./'
grep -q '^### Fallbacks' "$T/p13.md" && ok || bad "P13: the mutation must add the sub-heading"
gate "$T/p13.md" PLAN_GATE_PERF=1
[ "$GRC" = 2 ] && ok || bad "P13: a hit rate under a sub-heading is not in the item (got $GRC: $G)"
grep -q 'does not name a hit rate' <<<"$G" && ok || bad "P13: hit-rate gap expected: $G"

echo "plan-gate-outcome-replay.bh-6379: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
