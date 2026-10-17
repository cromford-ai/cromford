#!/bin/bash
# tests/lead-gates-caps.bh-5870-test.sh — BH-5876 (BH-5870.3): gate 13 of the
# enqueue, the caps and the tripwire, as the worklist gate
# bin/lib/lead-gates.d/90-caps.sh (knobs read by bin/lib/lead-gates-knobs.sh),
# with the reclaim (95-retry-reclaim.sh) and the doorbell (97-doorbell.sh) seen
# from the same ticks. Every case drives bin/lead-review.sh tick WHOLE over the
# worklist fixture (tests/lib/lead-worklist-fixture.bh-4956.sh, then
# tests/lib/lead-gates-fixture.bh-5875.sh, then
# tests/lib/lead-gates-fixture.bh-5876.sh).
#   C1  LEAD_REVIEW_MAX_PER_PR_DAY=3, a lead token: four ticks, each on a new
#       head of PR 104: 3 lr-104 jobs, one `[skip pr-day-cap]` line, 4
#       reclaim-stale calls, 3 lead-review rings, one lead-trip lane-alert.
#   C1b a 5th tick on the 4th head: still one `[skip pr-day-cap]` line.
#   C2  LEAD_REVIEW_ENQUEUE_MAX_PER_TICK=2, three PRs in one tick: 2 jobs,
#       held=1, one `[skip deferred]` line; the next tick starts the third.
#   C3  a registry that declares the per-tick knob required with no default,
#       and an empty env: the tick exits 75 (the lane fails closed), no job.
#   C4  LEAD_REVIEW_MAX_PER_PR_DAY empty, or 0, and the per-tick knob empty:
#       each holds, no job.
#   C5  started.tsv lines dated yesterday do not count.
#   M1  90-caps.sh removed: C1 makes 4 jobs. M2  95 removed: no reclaim-stale
#       call. M3  97 removed: no lead-review ring.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-gates-caps.bh-5870-test.sh
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
lwf_setup
lgf_setup
lg6_setup
GD="$H/bin/lib/lead-gates.d"
SRC="$LWF_SRC"
for f in bin/lib/lead-gates.d/90-caps.sh bin/lib/lead-gates.d/95-retry-reclaim.sh bin/lib/lead-gates.d/97-doorbell.sh bin/lib/lead-gates-knobs.sh; do
  [ -r "$SRC/$f" ] && [ -r "$H/$f" ] && ok || bad "setup: $f not in the repo or not installed by the closure"
done
hd() { printf '%040d' "$1"; }
DAY=$(TZ=UTC0 date +%Y%m%d)
summ() { lwf_summary; }

# Four real heads of PR 104 (the review checks each one out).
for i in 1 2 3 4; do C1H[$i]=$(lg6_head 104 "c1/f$i.txt" "c1 head $i") || bad "setup: head $i of PR 104"; done
# c1 — four ticks, one on each head of PR 104, at PR-day 3
c1() {
  local i
  lg6_reset
  for i in 1 2 3 4; do
    lgf_needs "104:${C1H[$i]}"
    LEAD_REVIEW_MAX_PER_PR_DAY=3 lwf_tick
  done
}

# ── C1: the per-PR-day tripwire, the reclaim and the ring on the same ticks ──
c1
[ "$(lgf_jobs 104)" = 3 ] && ok || bad "C1 jobs=$(lgf_jobs 104): $(cat "$L")"
[ "$(lg6_skips pr-day-cap)" = 1 ] && ok || bad "C1 pr-day-cap lines=$(lg6_skips pr-day-cap)"
grep -qF "[skip pr-day-cap] example-org/cromford#104 @${C1H[4]:0:12} 3 lead reviews of this PR today (LEAD_REVIEW_MAX_PER_PR_DAY=3); not started" "$L" \
  && ok || bad "C1 the cap line: $(grep 'skip' "$L")"
[ "$(lg6_reclaims)" = 4 ] && ok || bad "C1 reclaim-stale calls=$(lg6_reclaims)"
[ "$(lg6_rings)" = 3 ] && ok || bad "C1 lead-review rings=$(lg6_rings)"
[ "$(lwf_cnt "--id lead-trip-example-org_cromford-104-$DAY lead-review " "$T/log/lane-alert")" = 1 ] && ok \
  || bad "C1 trip alerts: $(cat "$T/log/lane-alert" 2>/dev/null)"
[ "$(awk -F'\t' '$3 == 104' "$H/state/lead-review/started.tsv" | wc -l | tr -d ' ')" = 3 ] && ok \
  || bad "C1 started.tsv: $(cat "$H/state/lead-review/started.tsv")"
[[ "$(summ)" == *" skipped=1 "* ]] && ok || bad "C1 the 4th tick's summary: $(summ)"

# ── C1b: the same 4th head again: no second line, no second alert ──
LEAD_REVIEW_MAX_PER_PR_DAY=3 lwf_tick
[ "$(lg6_skips pr-day-cap)" = 1 ] && ok || bad "C1b pr-day-cap lines=$(lg6_skips pr-day-cap)"
[ "$(lgf_jobs 104)" = 3 ] && ok || bad "C1b jobs=$(lgf_jobs 104)"
[ "$(lwf_cnt "lead-trip-" "$T/log/lane-alert")" = 1 ] && ok || bad "C1b trip alerts: $(cat "$T/log/lane-alert")"

# ── C2: the per-tick cap holds the overflow; the next tick takes it ──
lg6_reset
lgf_needs "101:$(hd 101)" "102:$(hd 102)" "103:$(hd 103)"
LEAD_REVIEW_ENQUEUE_MAX_PER_TICK=2 lwf_tick
[ "$(lgf_jobs 101)$(lgf_jobs 102)$(lgf_jobs 103)" = 110 ] && ok || bad "C2 jobs 101/102/103=$(lgf_jobs 101)/$(lgf_jobs 102)/$(lgf_jobs 103)"
[[ "$(summ)" == *" held=1 "* ]] && ok || bad "C2 summary: $(summ)"
[ "$(lg6_skips deferred)" = 1 ] && ok || bad "C2 deferred lines=$(lg6_skips deferred)"
grep -qF "[skip deferred] example-org/cromford#103 @$(hd 103 | cut -c1-12) LEAD_REVIEW_ENQUEUE_MAX_PER_TICK=2 reached; offered next tick" "$L" \
  && ok || bad "C2 the deferred line: $(grep skip "$L")"
# The route stops listing a head once it is reviewed.
lgf_needs "103:$(hd 103)"
LEAD_REVIEW_ENQUEUE_MAX_PER_TICK=2 lwf_tick
[ "$(lgf_jobs 103)" = 1 ] && ok || bad "C2 the next tick did not start 103: $(tail -5 "$L")"

# ── C3: a registry outage (required knob, no default, empty env) holds every head ──
# TEST-CHANGE BH-5878: the knob is the lead-review lane's own now (it was the
# enqueue lane's), so the dispatcher's own lane_env_apply fails closed first:
# the whole tick exits 75 and starts nothing, before any gate runs.
lg6_reset
lgf_needs "101:$(hd 101)" "102:$(hd 102)"
jq -nc '{lanes:[{id:"lead-review", knobs:[{env:"LEAD_REVIEW_ENQUEUE_MAX_PER_TICK", required:true}]}], libs:[]}' > "$T/lanes-c3.json"
LANE_REGISTRY="$T/lanes-c3.json" LEAD_REVIEW_ENQUEUE_MAX_PER_TICK= lwf_tick
[ "$(lgf_jobs 101)$(lgf_jobs 102)" = 00 ] && ok || bad "C3 a job on a registry outage: $(cat "$L")"
[ "$RC" = 75 ] && ok || bad "C3 the tick exited $RC (want 75, the lane failing closed): $(cat "$T/out")"
[ "$(lwf_agents)" = 0 ] && ok || bad "C3 agent calls=$(lwf_agents)"

# ── C4: an empty or 0 knob is a hold, never "no cap" ──
lg6_reset
lgf_needs "101:$(hd 101)"
LEAD_REVIEW_MAX_PER_PR_DAY= lwf_tick
[ "$(lgf_jobs 101)" = 0 ] && ok || bad "C4 a job with LEAD_REVIEW_MAX_PER_PR_DAY empty"
[[ "$(summ)" == *" held=1 "* ]] && ok || bad "C4 summary (empty): $(summ)"
grep -qF "LEAD_REVIEW_MAX_PER_PR_DAY='' unreadable" "$L" && ok || bad "C4 no line for the empty knob: $(cat "$L")"
LEAD_REVIEW_MAX_PER_PR_DAY=0 lwf_tick
[ "$(lgf_jobs 101)" = 0 ] && ok || bad "C4 a job with LEAD_REVIEW_MAX_PER_PR_DAY=0"
LEAD_REVIEW_ENQUEUE_MAX_PER_TICK= lwf_tick
[ "$(lgf_jobs 101)" = 0 ] && ok || bad "C4 a job with LEAD_REVIEW_ENQUEUE_MAX_PER_TICK empty"
LEAD_REVIEW_ENQUEUE_MAX_PER_TICK=0 lwf_tick
[ "$(lgf_jobs 101)" = 0 ] && ok || bad "C4 a job with LEAD_REVIEW_ENQUEUE_MAX_PER_TICK=0"
lwf_tick
[ "$(lgf_jobs 101)" = 1 ] && ok || bad "C4 no job once both knobs are set: $(tail -5 "$L")"

# ── C5: yesterday's started.tsv lines do not count ──
lg6_reset
lgf_needs "104:${C1H[1]}"
mkdir -p "$H/state/lead-review"
Y=$(TZ=UTC0 date -d '1 day ago' +%F)
for i in 1 2 3; do printf '%s\t%s\t%s\n' "$Y" example-org/cromford 104; done > "$H/state/lead-review/started.tsv"
LEAD_REVIEW_MAX_PER_PR_DAY=3 lwf_tick
[ "$(lgf_jobs 104)" = 1 ] && ok || bad "C5 yesterday's reviews counted: $(cat "$L")"
[ "$(lg6_skips pr-day-cap)" = 0 ] && ok || bad "C5 a pr-day-cap line"

# ── M1: no caps gate: C1 starts all four heads (D1) ──
mv "$GD/90-caps.sh" "$T/90.off"
c1
[ "$(lgf_jobs 104)" = 4 ] && ok || bad "M1 jobs=$(lgf_jobs 104) with 90-caps.sh gone (want 4)"
[ "$(lg6_skips pr-day-cap)" = 0 ] && ok || bad "M1 a pr-day-cap line with the gate gone"
mv "$T/90.off" "$GD/90-caps.sh"

# ── M2: no retry/reclaim gate: no reclaim-stale call ──
mv "$GD/95-retry-reclaim.sh" "$T/95.off"
lg6_reset; lgf_needs "101:$(hd 101)"; lwf_tick
[ "$(lg6_reclaims)" = 0 ] && ok || bad "M2 reclaim-stale calls=$(lg6_reclaims) with 95 gone"
mv "$T/95.off" "$GD/95-retry-reclaim.sh"

# ── M3: no doorbell gate: no lead-review ring ──
mv "$GD/97-doorbell.sh" "$T/97.off"
lg6_reset; lgf_needs "101:$(hd 101)"; lwf_tick
[ "$(lgf_jobs 101)" = 1 ] && ok || bad "M3 no job: $(tail -5 "$L")"
[ "$(lg6_rings)" = 0 ] && ok || bad "M3 lead-review rings=$(lg6_rings) with 97 gone"
mv "$T/97.off" "$GD/97-doorbell.sh"

echo "lead-gates-caps.bh-5870: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
