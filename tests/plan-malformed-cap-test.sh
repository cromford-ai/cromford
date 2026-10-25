#!/bin/bash
# tests/plan-malformed-cap-test.sh — a ticket held after two malformed plans
# never buys a third plan session.
#
# WHY (BH-657). PM_TERMINAL has written `requeued` on a ticket's first malformed
# plan and `held` on its second since 2026-09-12, and nothing read those rows
# BEFORE a plan was bought. So "held" was a RESULT string and a ledger row, never
# a gate: the triage sweep's relaunch, an unscoped tick that still sees the
# `ai-build` label, and bin/blocked-resolver.sh's rebuild-fresh rung each paid
# for a full Fable plan that died at the same gate. HC-10 bought three of them
# 30 minutes apart on 2026-09-17 (15:55Z, 16:25Z, 16:55Z — the triage cadence,
# not the resolver's 90-minute floor, which is what proved the choke point is
# run-build.sh itself rather than one launcher).
#
# WHAT IS UNDER TEST. The shipped fresh-plan launch region of bin/run-build.sh,
# lifted verbatim by its markers and driven with the model call, the beat, the
# ledger and RESULT/exit stubbed. The assertions are artifacts — cc.log (did a
# planner get called at all), the RESULT line, logs/ALERTS.log,
# state/plan-malformed.txt, $BUILD/pipeline.log — never a grep over the script.
#
# The NEGATIVES carry the weight here, because a wrong hold costs a ticket that
# never ships while a wrong launch costs one plan session: one `requeued` row, no
# rows, a `released` row, a neighbour ticket's rows, and a ledger outage must all
# still launch.
#
# No network, no model call, no secrets. Run from anywhere:
#   HARNESS_TEST_SANDBOX=1 tests/plan-malformed-cap-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
mkdir -p "$T/h/state" "$T/h/logs" "$T/old"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
# TEST-CHANGE (BH-7970): the driven review/plan code sources $HARNESS/bin/lib/stage-prompt.sh and renders prompts/stages/*.md; the scratch harness carries both, as a synced box does.
scratch_install_closure bin/lib/stage-prompt.sh "$T/h" >/dev/null || bad "could not install bin/lib/stage-prompt.sh into the scratch harness"
mkdir -p "$T/h/prompts/stages"; cp "$DIR"/prompts/stages/*.md "$T/h/prompts/stages/"

# The region by its markers, and — only when they are absent — by the anchors
# that bounded the same lines before this change. The fallback is deliberate: it
# is what makes this suite red at the merge base for the TRUE reason (those lines
# launch a planner without ever reading the plan-malformed state) instead of red
# because an extraction came back empty, which proves nothing about the pipeline.
awk '/^# >>> plan launch/{f=1;next} /^# <<< plan launch/{exit} f' \
  "$RB_ALL" > "$T/launch.sh"
if [ -s "$T/launch.sh" ]; then
  ok
else
  bad "the fresh-plan launch must live in its own '# >>> plan launch' region"
  sed -n '/^BB planning$/,/^CC plan "\$PLAN_MODEL" 1200/p' \
    "$RB_ALL" > "$T/launch.sh"
fi
[ -s "$T/launch.sh" ] && ok || bad "could not extract the fresh-plan launch at all"
grep -q 'CC plan' "$T/launch.sh" \
  && ok || bad "the extracted region does not call the planner — wrong lines"
bash -n "$T/launch.sh" 2>/dev/null \
  && ok || bad "the extracted launch region does not parse on its own"

# Drive the shipped lines. LEDGER_RC/LEDGER_STATUS stand in for job_ledger_get's
# rc contract (0 = row exists and its status is printed, 1 = outage, 2 = no row).
drive() { # drive [env...] ; stdout of the region, cc.log = the planner calls
  rm -rf "$T/b"; mkdir -p "$T/b"
  : > "$T/cc.log"
  ( env HARNESS="$T/h" BUILD="$T/b" PROJECT=widget-os KEY=WD-9 TICKET=tkt-1 \
        PLAN_MODEL=stub-model ALERTS="$T/h/logs/ALERTS.log" CCLOG="$T/cc.log" \
        LSINK="$T/ledger.log" LEDGER_RC=2 LEDGER_STATUS="" FP_BEFORE="" REPO="$T" \
        PLAN_AMBIGUITY_RULE="" KIND_HINT_LINE="" CARRIED_NOTE_LINE="" "$@" \
    bash -c 'set -uo pipefail
             STAMP() { echo TS; }
             RESULT() { echo "RESULT=$*"; }
             BB() { echo "BB=$1"; }
             CC() { echo "$1" >> "$CCLOG"; }
             job_ledger_get() { [ -n "$LEDGER_STATUS" ] && printf "%s\n" "$LEDGER_STATUS"; return "$LEDGER_RC"; }
             job_ledger_put() { echo "LEDGER=$1|$2|$3" >> "$LSINK"; }
             . "$0"; echo LAUNCHED' "$T/launch.sh" 2>&1 )
}
# grep -c prints its count and exits 1 when that count is zero, so every counter
# here swallows the rc and keeps the number — `|| echo 0` would print it twice.
planned()  { grep -c . "$T/cc.log" 2>/dev/null || true; }
alerts()   { grep -c . "$T/h/logs/ALERTS.log" 2>/dev/null || true; }
rows()     { grep -c "^widget-os WD-9 $1 " "$T/h/state/plan-malformed.txt" 2>/dev/null || true; }
ART="$T/old/size-gate.txt"

# A. TWO malformed plans on the record: the launch is skipped before the planner.
#    Zero model spend, rc 4 (the code the existing held terminal and PLAN_BLOCKED
#    already use, so every consumer reads it as parked rather than failed), one
#    ALERTS line that names the ticket AND its artifact, and the skip recorded on
#    the box as its own row.
: > "$T/h/logs/ALERTS.log"
printf 'widget-os WD-9 requeued TS\nwidget-os WD-9 held TS %s\n' "$ART" \
  > "$T/h/state/plan-malformed.txt"
OUT=$(drive); RC=$?
[ "$(planned)" = 0 ] && ok || bad "A: a held ticket must not buy a plan session (cc.log: $(cat "$T/cc.log"))"
[ "$RC" = 4 ] && ok || bad "A: the skip must exit 4 like the held terminal (got rc=$RC: $OUT)"
grep -q LAUNCHED <<<"$OUT" && bad "A: the skip must exit, not fall through (got: $OUT)" || ok
grep -q '^RESULT=PLAN_MALFORMED' <<<"$OUT" \
  && ok || bad "A: the terminal must stay PLAN_MALFORMED (got: $OUT)"
grep -q 'RESULT=.*held for a human' <<<"$OUT" \
  && ok || bad "A: the RESULT must carry the phrase the sweep SOPs act on (got: $OUT)"
grep -q 'RESULT=.*no plan session spent' <<<"$OUT" \
  && ok || bad "A: the RESULT must say no plan session was spent (got: $OUT)"
grep -q "RESULT=.*$ART" <<<"$OUT" \
  && ok || bad "A: the RESULT must name the artifact from the held row (got: $OUT)"
grep -q 'BB=plan_malformed' <<<"$OUT" \
  && ok || bad "A: the skip must beat the stage the console parks on (got: $OUT)"
[ "$(alerts)" = 1 ] \
  && ok || bad "A: exactly one ALERTS line, got $(alerts): $(cat "$T/h/logs/ALERTS.log")"
grep -q 'WD-9' "$T/h/logs/ALERTS.log" \
  && ok || bad "A: the ALERTS line must name the ticket: $(cat "$T/h/logs/ALERTS.log")"
grep -q 'size-gate.txt' "$T/h/logs/ALERTS.log" \
  && ok || bad "A: the ALERTS line must name the artifact: $(cat "$T/h/logs/ALERTS.log")"
grep -q 'Release:' "$T/h/logs/ALERTS.log" \
  && ok || bad "A: a hold with no documented way out is a ticket nobody can release: $(cat "$T/h/logs/ALERTS.log")"
[ "$(rows skipped)" = 1 ] \
  && ok || bad "A: the skip must be recorded as its own row: $(cat "$T/h/state/plan-malformed.txt")"
[ "$(awk '$3=="skipped"{print $5}' "$T/h/state/plan-malformed.txt")" = "$ART" ] \
  && ok || bad "A: the skipped row must carry the artifact in field 5: $(cat "$T/h/state/plan-malformed.txt")"
grep -q 'LEDGER=plan_malformed|widget-os WD-9|skipped' "$T/ledger.log" \
  && ok || bad "A: the skip must reach the D1 ledger: $(cat "$T/ledger.log" 2>/dev/null)"
grep -q 'no plan session spent' "$T/b/pipeline.log" \
  && ok || bad "A: the skip must leave a pipeline.log line: $(cat "$T/b/pipeline.log" 2>/dev/null)"
grep -q 'PLAN (' "$T/b/pipeline.log" \
  && bad "A: a skipped launch must not claim a PLAN stage ran: $(cat "$T/b/pipeline.log")" || ok

# B. ...and the SECOND skip is silent. One ALERTS entry per held ticket, because
#    the line is written on the `held` -> `skipped` transition and the row is
#    what remembers it — not this process.
: > "$T/ledger.log"
OUT=$(drive); RC=$?
[ "$(planned)" = 0 ] && ok || bad "B: a later launch must still spend nothing (cc.log: $(cat "$T/cc.log"))"
[ "$RC" = 4 ] && ok || bad "B: a later skip must still exit 4 (got rc=$RC: $OUT)"
[ "$(alerts)" = 1 ] \
  && ok || bad "B: the second skip must add no ALERTS line, got $(alerts): $(cat "$T/h/logs/ALERTS.log")"
[ "$(rows skipped)" = 1 ] \
  && ok || bad "B: the second skip must add no row: $(cat "$T/h/state/plan-malformed.txt")"
[ ! -s "$T/ledger.log" ] \
  && ok || bad "B: the second skip must write no ledger row: $(cat "$T/ledger.log")"
grep -q 'no plan session spent' "$T/b/pipeline.log" \
  && ok || bad "B: a silent skip is still logged in the build dir: $(cat "$T/b/pipeline.log" 2>/dev/null)"

# C. ONE malformed plan is not the cap. The requeue the sweep relaunches has to
#    reach a planner, or the cap of 2 becomes a cap of 1 and every first refusal
#    strands its ticket.
: > "$T/h/logs/ALERTS.log"
printf 'widget-os WD-9 requeued TS\n' > "$T/h/state/plan-malformed.txt"
OUT=$(drive); RC=$?
[ "$(planned)" = 1 ] && ok || bad "C: one requeued row must still buy exactly one plan (cc.log: $(cat "$T/cc.log"))"
[ "$RC" = 0 ] && ok || bad "C: a launched build must not terminate here (got rc=$RC: $OUT)"
grep -q 'RESULT=' <<<"$OUT" && bad "C: a relaunch must write no terminal (got: $OUT)" || ok
[ "$(alerts)" = 0 ] && ok || bad "C: a relaunch must raise no alert: $(cat "$T/h/logs/ALERTS.log")"
[ "$(rows skipped)" = 0 ] \
  && ok || bad "C: a relaunch must write no skipped row: $(cat "$T/h/state/plan-malformed.txt")"

# D. THE LEDGER IS THE REAL RECORD. A box whose state dir was rebuilt, or a
#    second malformed plan that ran on a Fly machine, leaves the hold in the D1
#    ledger only — and it must still hold.
: > "$T/h/logs/ALERTS.log"
rm -f "$T/h/state/plan-malformed.txt"
OUT=$(drive LEDGER_RC=0 LEDGER_STATUS=held); RC=$?
[ "$(planned)" = 0 ] && ok || bad "D: a ledger-only hold must skip the planner (cc.log: $(cat "$T/cc.log"))"
[ "$RC" = 4 ] && ok || bad "D: a ledger-only hold must exit 4 (got rc=$RC: $OUT)"
[ "$(alerts)" = 1 ] && ok || bad "D: a ledger-only hold raises one alert: $(cat "$T/h/logs/ALERTS.log")"
grep -q 'no artifact recorded' "$T/h/logs/ALERTS.log" \
  && ok || bad "D: with no row to read, the alert must say so rather than invent a path: $(cat "$T/h/logs/ALERTS.log")"

# E. A RELEASE IS A WAY OUT. Last row wins, so an operator's `released` row
#    hands the ticket back to the planner — which is what makes "held" a state
#    somebody can leave.
: > "$T/h/logs/ALERTS.log"
printf 'widget-os WD-9 requeued TS\nwidget-os WD-9 held TS %s\nwidget-os WD-9 released TS\n' "$ART" \
  > "$T/h/state/plan-malformed.txt"
OUT=$(drive); RC=$?
[ "$(planned)" = 1 ] && ok || bad "E: a released ticket must plan again (cc.log: $(cat "$T/cc.log"))"
[ "$RC" = 0 ] && ok || bad "E: a released ticket must not terminate (got rc=$RC: $OUT)"
[ "$(alerts)" = 0 ] && ok || bad "E: a release must raise no alert: $(cat "$T/h/logs/ALERTS.log")"
#    ...and a ticket that goes malformed twice AFTER a release is held again.
printf 'widget-os WD-9 released TS\nwidget-os WD-9 held TS %s\n' "$ART" \
  > "$T/h/state/plan-malformed.txt"
OUT=$(drive)
[ "$(planned)" = 0 ] && ok || bad "E: a hold after a release must hold again (cc.log: $(cat "$T/cc.log"))"

# F. A NEIGHBOUR'S HISTORY IS NOT THIS TICKET'S. The key is `<project> <key>`,
#    and a prefix match on the wrong ticket would hold whole boards.
printf 'widget-os WD-10 requeued TS\nwidget-os WD-10 held TS %s\n' "$ART" \
  > "$T/h/state/plan-malformed.txt"
OUT=$(drive)
[ "$(planned)" = 1 ] && ok || bad "F: WD-10's hold must not hold WD-9 (cc.log: $(cat "$T/cc.log"))"
#    ...and the reverse: WD-9 held must not hold WD-90 either.
printf 'widget-os WD-9 requeued TS\nwidget-os WD-9 held TS %s\n' "$ART" \
  > "$T/h/state/plan-malformed.txt"
OUT=$(drive KEY=WD-90)
[ "$(planned)" = 1 ] && ok || bad "F: a longer key must not match the held prefix (cc.log: $(cat "$T/cc.log"))"

# G. FAIL OPEN ON SPEND. A ledger outage (rc 1) and an honest "no row" (rc 2)
#    with no local file are the same decision here: launch. The property this
#    pins is that only the literal statuses hold — nothing else may.
rm -f "$T/h/state/plan-malformed.txt"
OUT=$(drive LEDGER_RC=1 LEDGER_STATUS="")
[ "$(planned)" = 1 ] && ok || bad "G: a ledger outage must not hold a ticket (cc.log: $(cat "$T/cc.log"))"
OUT=$(drive LEDGER_RC=2 LEDGER_STATUS="")
[ "$(planned)" = 1 ] && ok || bad "G: no row anywhere must launch (cc.log: $(cat "$T/cc.log"))"
OUT=$(drive LEDGER_RC=1 LEDGER_STATUS=held)
[ "$(planned)" = 1 ] && ok || bad "G: an outage that also printed something must not hold (cc.log: $(cat "$T/cc.log"))"
OUT=$(drive LEDGER_RC=0 LEDGER_STATUS=banana)
[ "$(planned)" = 1 ] && ok || bad "G: an unknown status is not a hold (cc.log: $(cat "$T/cc.log"))"
printf 'widget-os WD-9 requeued TS\n' > "$T/h/state/plan-malformed.txt"
OUT=$(drive LEDGER_RC=0 LEDGER_STATUS=held)
[ "$(planned)" = 1 ] \
  && ok || bad "G: the box's own file is its word — a local requeue outranks a ledger hold (cc.log: $(cat "$T/cc.log"))"

# H. LEGACY ROWS STILL HOLD. Rows written before this change carry four fields;
#    the missing artifact is named as missing, and the hold applies anyway.
: > "$T/h/logs/ALERTS.log"
printf 'widget-os WD-9 requeued TS\nwidget-os WD-9 held TS\n' > "$T/h/state/plan-malformed.txt"
OUT=$(drive); RC=$?
[ "$(planned)" = 0 ] && ok || bad "H: a legacy held row must still hold (cc.log: $(cat "$T/cc.log"))"
[ "$RC" = 4 ] && ok || bad "H: a legacy held row must exit 4 (got rc=$RC: $OUT)"
grep -q 'no artifact recorded' "$T/h/logs/ALERTS.log" \
  && ok || bad "H: a 4-field row must read as no artifact, not as a blank path: $(cat "$T/h/logs/ALERTS.log")"

echo "plan-malformed-cap-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
