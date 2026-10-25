#!/bin/bash
# tests/lead-gates-traced-ports.bh-7236-test.sh — the traced hold gate
# bin/lib/lead-gates.d/57-traced-hold.sh, driven by bin/lead-review.sh tick
# WHOLE over the worklist fixture (tests/lib/lead-worklist-fixture.bh-4956.sh,
# lead-gates-fixture.bh-5875.sh, lead-gates-fixture.bh-5876.sh).
#   T1  base feat-x, every traced job skipped: no job, one dispatch, the
#       `[skip traced]` line says the traced jobs are skipped.
#   T8  base feat-x, a traced job still queued: no job, the line says
#       `still queued or running`.
#   T9  a DIRTY head on main, LEAD_REVIEW_REBASE_HOLD=0, a traced job
#       completed green: a job, no dispatch.
#   D2  base feat-x, the dispatch POST fails: no job, the failed-dispatch line.
#   D3  LEAD_REVIEW_TRACED_MAX_WAIT_MIN=0, base feat-x, traced skipped: a job,
#       no dispatch.
#   D4  base feat-x, no traced job, an unfinished pull_request run of
#       harness-ci.yml on the head: no dispatch, no job, the not-dispatched line.
#   D4b a DIRTY head, LEAD_REVIEW_REBASE_HOLD=0, traced skipped, a COMPLETED
#       pull_request run: one dispatch, no job, no not-dispatched line.
#   B2  LEAD_REVIEW_TRACED_MAX_WAIT_MIN=5: a marker 6 minutes old gets a job;
#       a marker 4 minutes old is held.
#   M1  the gate counts completed pull_request runs too: D4b dispatches nothing.
#   M2  the gate dispatches with the bound 0: D3 dispatches.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-gates-traced-ports.bh-7236-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lead-worklist-fixture.bh-4956.sh" || exit 1
. "$(dirname "$0")/lib/lead-gates-fixture.bh-5875.sh" || exit 1
. "$(dirname "$0")/lib/lead-gates-fixture.bh-5876.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }
unset LEAD_REVIEW_TRACED_WAIT LEAD_REVIEW_TRACED_JOB LEAD_REVIEW_TRACED_MAX_WAIT_MIN LEAD_REVIEW_REBASE_HOLD
lwf_setup
lgf_setup
lg6_setup
GATE="$H/bin/lib/lead-gates.d/57-traced-hold.sh"
[ -r "$GATE" ] && ok || bad "setup: 57-traced-hold.sh not installed"
H1=$(printf '%040d' 104); H12=${H1:0:12}
TF="$H/state/lead-review-enqueue/traced-example-org_cromford-104-$H12"
PFX="example-org/cromford#104 @$H12"

# fresh <base> [mergeable_state] — PR 104 on head H1, its own state only.
fresh() {
  lg6_reset; lgf_needs "104:$H1"
  echo "$1" > "$FX/base.104"; echo ticket/bh-104 > "$FX/ref.104"; echo "${2:-clean}" > "$FX/ms.104"
}
# traced <conclusion skipped|success|queued> — CI green plus one traced shard on H1.
traced() {
  jq -nc --arg s "$H1" --arg c "$1" '[{name:"Tests", head_sha:$s, status:"completed", conclusion:"success", app:{slug:"github-actions"}}]
    + [if $c == "queued" then {name:"Tests, traced (shard 0/1)", head_sha:$s, status:"queued", conclusion:null, app:{slug:"github-actions"}}
       else {name:"Tests, traced (shard 0/1)", head_sha:$s, status:"completed", conclusion:$c, app:{slug:"github-actions"}} end]
    | {total_count:length, check_runs:.}' > "$FX/checks.$H1"
}
# prrun <status> — one pull_request run of harness-ci.yml on the head.
prrun() {
  jq -nc --arg st "$1" '{total_count:1, workflow_runs:[{path:".github/workflows/harness-ci.yml", event:"pull_request", status:$st}
    + (if $st == "completed" then {conclusion:"success"} else {} end)]}' > "$FX/runs.json"
}
# aged <minutes> — the hold marker, started that long ago, already dispatched.
aged() { mkdir -p "${TF%/*}"; printf '%s\ndispatch ok harness-ci.yml ticket/bh-104\n' "$(( $(date +%s) - $1 * 60 ))" > "$TF"; }
jobs() { lgf_jobs 104; }
disp() { lg6_dispatches; }

case_t1()  { fresh feat-x; traced skipped; lwf_tick; }
case_d3()  { fresh feat-x; traced skipped; LEAD_REVIEW_TRACED_MAX_WAIT_MIN=0 lwf_tick; }
case_d4b() { fresh main dirty; traced skipped; prrun completed; LEAD_REVIEW_REBASE_HOLD=0 lwf_tick; }

# ── T1: every traced job skipped on a stacked base: held, said ──
case_t1
[ "$(jobs)" = 0 ] && ok || bad "T1 a job with every traced job skipped: $(cat "$L")"
[ "$(disp)" = 1 ] && ok || bad "T1 dispatches=$(disp)"
grep -qF "[skip traced] $PFX not requested: base feat-x is not main and every 'Tests, traced' job on this head is skipped (1)" "$L" \
  && ok || bad "T1 line: $(grep skip "$L")"

# ── T8: a traced job still queued: held ──
fresh feat-x; traced queued; lwf_tick
[ "$(jobs)" = 0 ] && ok || bad "T8 a job with a traced job still queued: $(cat "$L")"
grep -qF "[skip traced] $PFX not requested: base feat-x is not main and 1 'Tests, traced' job(s) on this head are still queued or running" "$L" \
  && ok || bad "T8 line: $(grep skip "$L")"

# ── T9: DIRTY, the rebase hold off, a traced run completed green: released ──
fresh main dirty; traced success; LEAD_REVIEW_REBASE_HOLD=0 lwf_tick
[ "$(jobs)" = 1 ] && ok || bad "T9 no job for a DIRTY head with a green traced run: $(cat "$L")"
[ "$(disp)" = 0 ] && ok || bad "T9 dispatches=$(disp)"

# ── D2: a failed dispatch: logged, held ──
fresh feat-x; traced skipped; : > "$FX/dispfail"; lwf_tick
[ "$(jobs)" = 0 ] && ok || bad "D2 a job after a failed dispatch: $(cat "$L")"
grep -qF "$PFX: dispatch of harness-ci.yml scope=impact on ticket/bh-104 failed" "$L" && ok || bad "D2 no failed-dispatch line: $(tail -5 "$L")"

# ── D3: the bound 0: a job at once, no dispatch ──
case_d3
[ "$(jobs)" = 1 ] && ok || bad "D3 no job with the bound 0: $(cat "$L")"
[ "$(disp)" = 0 ] && ok || bad "D3 dispatches=$(disp)"

# ── D4: an unfinished pull_request run on the head: no dispatch ──
fresh feat-x; prrun queued; lwf_tick
[ "$(disp)" = 0 ] && ok || bad "D4 dispatches=$(disp)"
[ "$(jobs)" = 0 ] && ok || bad "D4 a job: $(cat "$L")"
grep -qF "$PFX: not dispatched: a pull_request run of harness-ci.yml is still running on this head" "$L" && ok || bad "D4 no not-dispatched line: $(tail -5 "$L")"

# ── D4b: a completed pull_request run, traced skipped: dispatched ──
case_d4b
[ "$(disp)" = 1 ] && ok || bad "D4b dispatches=$(disp): $(tail -5 "$L")"
[ "$(jobs)" = 0 ] && ok || bad "D4b a job: $(cat "$L")"
grep -qF "$PFX: not dispatched: " "$L" && bad "D4b a not-dispatched line: $(grep 'not dispatched' "$L")" || ok

# ── B2: the knob sets the bound ──
fresh feat-x; traced skipped; aged 6; LEAD_REVIEW_TRACED_MAX_WAIT_MIN=5 lwf_tick
[ "$(jobs)" = 1 ] && ok || bad "B2 bound 5m: no job for a 6m hold: $(cat "$L")"
fresh feat-x; traced skipped; aged 4; LEAD_REVIEW_TRACED_MAX_WAIT_MIN=5 lwf_tick
[ "$(jobs)" = 0 ] && ok || bad "B2 bound 5m: a job for a 4m hold: $(cat "$L")"

# mutate <sed expr> — edit the scratch gate; rc 1 when the file did not change.
mutate() {
  cp "$GATE" "$T/57.orig"
  sed -i "$1" "$GATE"
  ! cmp -s "$GATE" "$T/57.orig"
}
restore() { cp "$T/57.orig" "$GATE"; }

# ── M1: completed pull_request runs count as unfinished: D4b goes red ──
if mutate 's#| select((.status // "") != "completed")]#]#'; then
  ok; case_d4b
  [ "$(disp)" = 0 ] && ok || bad "M1 D4b still dispatches under the mutation: dispatches=$(disp)"
else bad "M1 the mutation did not change the gate"; fi
restore

# ── M2: the bound 0 still dispatches: D3 goes red ──
if mutate 's#"\$LGK_TMAX" -gt 0 \]#"$LGK_TMAX" -ge 0 ]#'; then
  ok; case_d3
  [ "$(disp)" = 1 ] && ok || bad "M2 D3 still dispatches nothing under the mutation: dispatches=$(disp)"
else bad "M2 the mutation did not change the gate"; fi
restore

echo "lead-gates-traced-ports.bh-7236: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
