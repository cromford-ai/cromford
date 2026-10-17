#!/bin/bash
# tests/perf-plan-rule.bh-6379-test.sh — BH-6379 (BH-6372.1): the plan prompt
# asks a perf/cost ticket for a target metric and an outcome replay, and the
# plan stage tells the gate which tickets are perf.
#
#   N1-N5  pt_replay_n: settings row, else env, else 50; a bad value is 50
#          plus one stderr line
#   R1-R5  pt_plan_rule: text only for a perf ticket, the right words, the
#          replay count, and the format it prints passes pt_plan_check
#   W1     pt_build_perf on a build dir: PLAN_GATE_PERF and the evidence,
#          from ticket-body.md or, when that is absent, pt-ticket-body.md
#   W2     bin/lib/rb/plan.sh: PG_RUN passes PLAN_GATE_PERF to the gate, the
#          plan prompt carries pt_plan_rule, the repair prompt pt_repair_note
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/perf-plan-rule.bh-6379-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/bin/lib/perf-plan-rule.sh"
PLANSH="$DIR/bin/lib/rb/plan.sh"
FXD="$DIR/tests/fixtures/bh-6372"
[ -r "$LIB" ] && bash -n "$LIB" && ok || bad "bin/lib/perf-plan-rule.sh is missing or does not parse"
for n in 5354 6049 5797 5591 5544; do [ -r "$FXD/issue-$n.json" ] || { echo "fixture missing: issue-$n.json"; exit 1; }; done
unset OUTCOME_REPLAY_N PLAN_GATE_PERF PERF_TICKET_CATALOG
mkdir -p "$T/root"

# lib <snippet> [VAR=value ...] — runs <snippet> in a fresh bash with the lib sourced, HARNESS
# on a scratch root with no settings answer.
lib() { local s="$1"; shift; env HARNESS="$T/root" "$@" bash -c '. "$1" || exit 9; shift; eval "$1"' _ "$LIB" "$s"; }

# N1 — unset: 50, silent.
O=$(lib 'pt_replay_n' 2>"$T/e"); [ "$O" = 50 ] && [ ! -s "$T/e" ] && ok || bad "N1: unset must print 50 silently (got '$O', stderr $(cat "$T/e"))"
# N2 — env 120.
O=$(OUTCOME_REPLAY_N=120 lib 'pt_replay_n' 2>"$T/e"); [ "$O" = 120 ] && [ ! -s "$T/e" ] && ok || bad "N2: 120 expected (got '$O')"
# N3 — not an integer.
O=$(OUTCOME_REPLAY_N=abc lib 'pt_replay_n' 2>"$T/e")
[ "$O" = 50 ] && ok || bad "N3: abc must give 50 (got '$O')"
[ "$(wc -l < "$T/e")" = 1 ] && grep -q "OUTCOME_REPLAY_N='abc'" "$T/e" && ok || bad "N3: exactly one stderr line naming OUTCOME_REPLAY_N: $(cat "$T/e")"
# N4 — the settings row wins over env.
O=$(OUTCOME_REPLAY_N=120 lib 'lib_env_apply() { [ "$1" = perf-ticket ] && export OUTCOME_REPLAY_N=200; }; pt_replay_n' 2>"$T/e")
[ "$O" = 200 ] && ok || bad "N4: the settings answer 200 must win over env 120 (got '$O')"
O=$(OUTCOME_REPLAY_N=120 HARNESS= H= bash -c '. "$1"; lib_env_apply() { export OUTCOME_REPLAY_N=200; }; pt_replay_n' _ "$LIB" 2>/dev/null)
[ "$O" = 120 ] && ok || bad "N4: with no harness root no settings row is read (got '$O')"
# N5 — out of range.
for v in 4 501; do
  O=$(OUTCOME_REPLAY_N=$v lib 'pt_replay_n' 2>"$T/e")
  [ "$O" = 50 ] && [ "$(wc -l < "$T/e")" = 1 ] && ok || bad "N5: $v must give 50 plus one stderr line (got '$O', $(cat "$T/e"))"
done

# issue <n> — <n>.body, <n>.title, <n>.labels in $T from the fixture.
issue() {
  jq -r '.body // ""' "$FXD/issue-$1.json" > "$T/$1.body"
  jq -r '.title // ""' "$FXD/issue-$1.json" > "$T/$1.title"
  jq -r '[.labels[]?.name] | join(",")' "$FXD/issue-$1.json" > "$T/$1.labels"
}
rule() { issue "$1"; R=$(lib 'pt_plan_rule "$PB" "$PT" "$PL"' PB="$T/$1.body" PT="$(cat "$T/$1.title")" PL="$(cat "$T/$1.labels")"); RRC=$?; }

# R1 — a perf ticket gets the rule with the classifier's evidence.
rule 5354
[ "$RRC" = 0 ] && grep -q '^PERF/COST TICKET' <<<"$R" && ok || bad "R1: #5354 must get the rule (rc $RRC: $R)"
grep -qE 'classifier said (phrase|label):' <<<"$R" && ok || bad "R1: the classifier evidence must be in the text: $R"
R1=$R
# R2 — negatives: nothing.
for n in 6049 5797 5591 5544; do
  rule "$n"
  [ "$RRC" = 0 ] && [ -z "$R" ] && ok || bad "R2: #$n must get no rule (rc $RRC: $R)"
done
# R3 — the words.
for w in "'## Target metric'" "'Target metric: <metric-id> from" "outcome replay" "top miss" "hit rate" "'## Outcome replay'"; do
  grep -qF -- "$w" <<<"$R1" && ok || bad "R3: the rule must name $w: $R1"
done
grep -q 'the last 50 real inputs' <<<"$R1" && ok || bad "R3: default replay count 50 expected: $R1"
# R4 — the count follows the knob.
issue 5354
R=$(lib 'pt_plan_rule "$PB" "$PT" "$PL"' OUTCOME_REPLAY_N=120 PB="$T/5354.body" PT="$(cat "$T/5354.title")" PL="$(cat "$T/5354.labels")")
grep -q 'the last 120 real inputs' <<<"$R" && ok || bad "R4: OUTCOME_REPLAY_N=120 must reach the text: $R"
# R5 — the writer's format passes the reader.
FMT=$(grep -o "'Target metric: <metric-id> from <current number> to <target number> \[<unit>\]'" <<<"$R1" | tr -d "'")
[ -n "$FMT" ] && ok || bad "R5: the rule must print the exact Target metric format: $R1"
L=$(sed 's/<metric-id>/review-p50-min/; s/<current number>/42/; s/<target number>/20/; s/ \[<unit>\]/ minutes/' <<<"$FMT")
printf '# P\n\n## Target metric\n%s\n\n## Acceptance tests\n- outcome replay over the last 50 real inputs: the metric, the top miss reasons, the hit rate of the fallback.\n' "$L" > "$T/r5.md"
O=$(lib 'pt_plan_check "$P"' PLAN_GATE_PERF=1 P="$T/r5.md"); RC=$?
[ "$RC" = 0 ] && grep -qx 'PLAN_OUTCOME_REPLAY: ok' <<<"$O" && ok || bad "R5: a plan from the rule's own format must pass (rc $RC: $O; line: $L)"

# W1 — pt_build_perf on a build dir.
build() { # build <dir> <n> — ticket-meta.json from the fixture, ticket-body.md
  mkdir -p "$1"; cp "$FXD/issue-$2.json" "$1/ticket-meta.json"
  jq -r '.body // ""' "$1/ticket-meta.json" > "$1/ticket-body.md"
}
W='pt_build_perf "$B"; printf "%s|%s|%s|%s\n" "$PLAN_GATE_PERF" "$PT_EVIDENCE" "$PT_BODY" "$PT_LABELS"'
build "$T/b1" 5354
O=$(lib "$W" B="$T/b1")
[ "${O%%|*}" = 1 ] && ok || bad "W1: #5354 must set PLAN_GATE_PERF=1 (got $O)"
grep -qE '^1\|perf (phrase|label):' <<<"$O" && ok || bad "W1: the evidence must be the classifier's own: $O"
grep -q "|$T/b1/ticket-body.md|" <<<"$O" && ok || bad "W1: PT_BODY must be ticket-body.md: $O"
build "$T/b2" 6049
O=$(lib "$W" B="$T/b2"); [ "${O%%|*}" = 0 ] && ok || bad "W1: #6049 must set PLAN_GATE_PERF=0 (got $O)"
for n in 5797 5591 5544; do
  build "$T/bn$n" "$n"; O=$(lib "$W" B="$T/bn$n"); [ "${O%%|*}" = 0 ] && ok || bad "W1: #$n must set PLAN_GATE_PERF=0 (got $O)"
done
build "$T/b3" 5354; rm -f "$T/b3/ticket-body.md"
O=$(lib "$W" B="$T/b3")
[ "${O%%|*}" = 1 ] && grep -q "|$T/b3/pt-ticket-body.md|" <<<"$O" && ok || bad "W1: no ticket-body.md must read pt-ticket-body.md (got $O)"
[ -s "$T/b3/pt-ticket-body.md" ] && [ ! -e "$T/b3/ticket-body.md" ] && ok || bad "W1: pt-ticket-body.md must be written and ticket-body.md left alone"
O=$(lib "$W" B="$T/none"); [ "${O%%|*}" = 0 ] && ok || bad "W1: no ticket-meta.json must be PLAN_GATE_PERF=0 (got $O)"

# W2 — the wiring in bin/lib/rb/plan.sh, driven where it can be.
PGL=$(grep -m1 '^PG_RUN() {' "$PLANSH")
[ -n "$PGL" ] && ok || bad "W2: PG_RUN not found in plan.sh"
mkdir -p "$T/h/bin" "$T/bw"
printf '#!/bin/bash\necho "PERF=${PLAN_GATE_PERF-unset}"\n' > "$T/h/bin/plan-gate.sh"; chmod +x "$T/h/bin/plan-gate.sh"
O=$(HARNESS="$T/h" BUILD="$T/bw" bash -c 'eval "$1"; PLAN_GATE_PERF=1; PG_RUN; cat "$BUILD/plan-gate.txt"' _ "$PGL")
[ "$O" = "PERF=1" ] && ok || bad "W2: PG_RUN must pass PLAN_GATE_PERF=1 to the gate (got $O)"
O=$(HARNESS="$T/h" BUILD="$T/bw" bash -c 'eval "$1"; unset PLAN_GATE_PERF; PG_RUN; cat "$BUILD/plan-gate.txt"' _ "$PGL")
[ "$O" = "PERF=0" ] && ok || bad "W2: PG_RUN with PLAN_GATE_PERF unset must pass 0 (got $O)"
[ "$(grep -c 'pt_plan_rule "$PT_BODY" "$PT_TITLE" "$PT_LABELS"' "$PLANSH")" = 1 ] && ok || bad "W2: the plan prompt must carry pt_plan_rule once"
grep -q 'pt_repair_note "$BUILD/plan-gate.txt"' "$PLANSH" && ok || bad "W2: the repair prompt must carry pt_repair_note"
grep -q '^\[ -r "$HARNESS/bin/lib/perf-plan-rule.sh" \] && \. "$HARNESS/bin/lib/perf-plan-rule.sh"' "$PLANSH" && ok || bad "W2: plan.sh must source perf-plan-rule.sh"
LB=$(grep -n '^  pt_build_perf "$BUILD"$' "$PLANSH" | cut -d: -f1); LC=$(grep -n '^# Checkpoint: a valid non-BLOCKED plan' "$PLANSH" | cut -d: -f1)
[ -n "$LB" ] && [ -n "$LC" ] && [ "$LB" -lt "$LC" ] && ok || bad "W2: plan.sh must call pt_build_perf above the plan checkpoint, so a reused plan is gated too (call line ${LB:-none}, checkpoint ${LC:-none})"

echo "perf-plan-rule.bh-6379: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
