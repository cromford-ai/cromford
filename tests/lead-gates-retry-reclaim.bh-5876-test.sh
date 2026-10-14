#!/bin/bash
# tests/lead-gates-retry-reclaim.bh-5876-test.sh — BH-5876 (BH-5870.3): gate 11
# of the enqueue (BH-5779), the reclaim of stale running rows and the bounded
# retry of a failed lead review, as bin/lib/lead-gates.d/95-retry-reclaim.sh
# (lg_tick_reclaim, lg_gate_retry). Every case drives bin/lead-review.sh tick
# WHOLE over the worklist fixture (tests/lib/lead-worklist-fixture.bh-4956.sh,
# lead-gates-fixture.bh-5875.sh, lead-gates-fixture.bh-5876.sh).
#   F0  no failed row: a job, no reset.
#   F1  a failed row (review-failed: timeout): one reset POST, then the job;
#       failed-retry.tsv gets one `reset` row in the enqueue's format.
#   F2  two `reset` rows already in the ledger (LEAD_REVIEW_FAILED_RETRY_MAX=2):
#       no reset, no job, ONE lane-alert lead-failed-*, and two ticks write
#       ONE `[skip failed-exhausted]` line and one `alerted` row.
#   F3  detail `empty` while the land lane registers LEAD_REVIEW_ENV_RETRY_MAX:
#       `[skip env-failed]`, no reset. F3b without it: a reset.
#   F4  the failed list answers 500: held, no job, no reset.
#   F5  the reset answers 409: held, `[skip reset-refused]`.
#   F6  no lead token: held, one reset-failed line.
#   F7  ledger rows older than 30 days are dropped (and no longer count).
#   RC1 reclaim answers two rows: two reclaimed lines, and one call per tick
#       with two worklist repos.
#   RC2 reclaim answers 500: one `not answered` line, and the tick still starts F0's head.
#   M1  95-retry-reclaim.sh removed: F1 makes no reset and no reclaim call (D1).
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-gates-retry-reclaim.bh-5876-test.sh
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
[ -r "$SRC/bin/lib/lead-gates.d/95-retry-reclaim.sh" ] && [ -r "$GD/95-retry-reclaim.sh" ] && ok || bad "setup: 95-retry-reclaim.sh not installed"
H1=$(printf '%040d' 101); H12=${H1:0:12}
FR="$H/state/lead-review-enqueue/failed-retry.tsv"
summ() { lwf_summary; }
# failed <detail> — one failed lead review row for PR 101 at H1
failed() {
  jq -nc --arg h "$H1" --arg d "$1" '[{id:"r-f1", repo:"example-org/cromford", pr:101, head_sha:$h, status:"failed",
    detail:$d, created_at:"2026-10-10 03:00:00"}]' > "$FX/failed.json"
}
one() { lg6_reset; lgf_needs "101:$H1"; }

# ── F0: no failed row ──
one
lwf_tick
[ "$(lgf_jobs 101)" = 1 ] && ok || bad "F0 no job: $(cat "$L")"
[ "$(lg6_resets)" = 0 ] && ok || bad "F0 resets=$(lg6_resets)"
grep -q '^GET /api/lead-reviews?status=failed&repo=example-org%2Fcromford' "$T/log/worker" && ok || bad "F0 no failed-list read: $(grep lead-reviews "$T/log/worker")"

# ── F1: a failed row under budget: reset, then the job ──
one; failed "review-failed: timeout"
lwf_tick
[ "$(lg6_resets)" = 1 ] && ok || bad "F1 resets=$(lg6_resets): $(cat "$L")"
grep -q '^POST /api/lead-reviews/r-f1/reset ' "$T/log/worker" && ok || bad "F1 not the row's reset"
[ "$(lgf_jobs 101)" = 1 ] && ok || bad "F1 no job after the reset"
grep -qP "^[0-9]+\texample-org/cromford\t101\t$H1\tr-f1\treset\treview-failed: timeout$" "$FR" && ok || bad "F1 ledger: $(cat "$FR" 2>/dev/null)"
[ "$(grep -c . "$FR")" = 1 ] && ok || bad "F1 ledger rows: $(cat "$FR")"
grep -qF "example-org/cromford#101 @$H12: lead review r-f1 failed (review-failed: timeout); reset 1/2 for a new review" "$L" && ok || bad "F1 line: $(cat "$L")"
# The reset is before the claim: the /start comes after it.
r=$(grep -n '/r-f1/reset ' "$T/log/worker" | cut -d: -f1); s=$(grep -n '^POST /api/lead-reviews/start ' "$T/log/worker" | head -1 | cut -d: -f1)
[ -n "$r" ] && [ -n "$s" ] && [ "$r" -lt "$s" ] && ok || bad "F1 order reset=$r start=$s"

# ── F2: the budget used: one alert, one skip line over two ticks ──
one; failed "review-failed: timeout"
mkdir -p "${FR%/*}"
# The ledger keeps 30 days (header), and the gate reads the wall clock: recent rows.
E=$(( $(date +%s) - 600 ))
printf '%s\t%s\t%s\t%s\t%s\treset\t%s\n' "$E" example-org/cromford 101 "$H1" r-f1 x "$((E + 60))" example-org/cromford 101 "$H1" r-f1 x > "$FR"
lwf_tick; lwf_tick
[ "$(lg6_resets)" = 0 ] && ok || bad "F2 resets=$(lg6_resets)"
[ "$(lgf_jobs 101)" = 0 ] && ok || bad "F2 a job for an exhausted head"
[ "$(lwf_cnt "--severity warn --id lead-failed-example-org_cromford-101-$H12 lead-review " "$T/log/lane-alert")" = 1 ] && ok || bad "F2 alerts: $(cat "$T/log/lane-alert" 2>/dev/null)"
[ "$(lg6_skips failed-exhausted)" = 1 ] && ok || bad "F2 failed-exhausted lines=$(lg6_skips failed-exhausted)"
[ "$(awk -F'\t' '$6 == "alerted"' "$FR" | wc -l | tr -d ' ')" = 1 ] && ok || bad "F2 alerted rows: $(cat "$FR")"
[[ "$(summ)" == *" skipped=1 "* ]] && ok || bad "F2 summary: $(summ)"

# ── F3: an environment failure the land lane owns: no reset ──
one; failed empty
printf '{"id":"lead-review-land","knobs":[{"env":"LEAD_REVIEW_ENV_RETRY_MAX","default":2}]}\n' > "$H/catalog/lanes.d/lead-review-land.json"
lwf_tick
[ "$(lg6_resets)" = 0 ] && ok || bad "F3 resets=$(lg6_resets) for an env failure the land lane owns"
[ "$(lg6_skips env-failed)" = 1 ] && ok || bad "F3 env-failed lines=$(lg6_skips env-failed)"
[ "$(lgf_jobs 101)" = 0 ] && ok || bad "F3 a job"
rm -f "$H/catalog/lanes.d/lead-review-land.json"
# ── F3b: no land-lane registration: the env failure is reset here ──
one; failed empty
lwf_tick
[ "$(lg6_resets)" = 1 ] && ok || bad "F3b resets=$(lg6_resets) without the land lane"

# ── F4: the failed list unreadable: held ──
one; echo on > "$FX/failed.fail"
lwf_tick
[ "$(lgf_jobs 101)" = 0 ] && ok || bad "F4 a job on an unreadable failed list"
[[ "$(summ)" == *" held=1 "* ]] && ok || bad "F4 summary: $(summ)"
grep -qF 'failed lead reviews of example-org/cromford unreadable' "$L" && ok || bad "F4 line: $(cat "$L")"

# ── F5: the reset refused (409): held, one skip line ──
one; failed "review-failed: timeout"; echo 409 > "$FX/reset.r-f1"
lwf_tick
[ "$(lgf_jobs 101)" = 0 ] && ok || bad "F5 a job after a refused reset"
[ "$(lg6_skips reset-refused)" = 1 ] && ok || bad "F5 reset-refused lines=$(lg6_skips reset-refused)"
[[ "$(summ)" == *" held=1 "* ]] && ok || bad "F5 summary: $(summ)"
[ -s "$FR" ] && bad "F5 a refused reset was recorded: $(cat "$FR")" || ok

# ── F6: no lead token: held, one line ──
one; failed "review-failed: timeout"; rm -f "$FX/lead-token"
lwf_tick
[ "$(lgf_jobs 101)" = 0 ] && ok || bad "F6 a job with no token"
[ "$(lwf_cnt "example-org/cromford#101 @$H12: reset of r-f1 failed (lead-reviews: lead token file" "$L")" = 1 ] && ok || bad "F6 line: $(cat "$L")"
[ -s "$FR" ] && bad "F6 a reset recorded with no token" || ok

# ── F7: the ledger drops rows older than 30 days, once a tick ──
one; failed "review-failed: timeout"; mkdir -p "${FR%/*}"
E=$(( $(date +%s) - 600 ))
printf '%s\t%s\t%s\t%s\t%s\treset\t%s\n' "$((E - 2592000))" example-org/cromford 101 "$H1" r-f1 old "$((E - 2592000 + 60))" example-org/cromford 101 "$H1" r-f1 old \
  "$E" example-org/cromford 9 "$H1" r-9 kept > "$FR"
lwf_tick
[ "$(awk -F'\t' '$7 == "old"' "$FR" | wc -l | tr -d ' ')" = 0 ] && ok || bad "F7 old rows kept: $(cat "$FR")"
[ "$(awk -F'\t' '$7 == "kept"' "$FR" | wc -l | tr -d ' ')" = 1 ] && ok || bad "F7 the recent row dropped: $(cat "$FR")"
[ "$(lg6_resets)" = 1 ] && ok || bad "F7 the pruned resets still counted: resets=$(lg6_resets)"

# ── RC1: reclaimed rows are logged; one call a tick across repos ──
one
jq -nc '{reclaimed:[{id:"r-a", repo:"example-org/cromford", pr:7, head_sha:"aaaaaaaaaaaaaaaa", to:"requested", last_beat:"2026-10-10 03:00:00"},
  {id:"r-b", repo:"example-org/cromford", pr:8, head_sha:"bbbbbbbbbbbbbbbb", to:"failed", last_beat:"never"}], deadline_s:1800}' > "$FX/reclaim.json"
lwf_needs example-org/demo-os 101
LEAD_REVIEW_AUTO_REPOS="example-org/cromford example-org/demo-os" lwf_tick
[ "$(lg6_reclaims)" = 1 ] && ok || bad "RC1 reclaim calls=$(lg6_reclaims) with two repos"
grep -qF "example-org/cromford#7 @aaaaaaaaaaaa: lead review r-a ran with no heartbeat since 2026-10-10 03:00:00; reclaimed to requested (deadline 1800 s)" "$L" && ok || bad "RC1 r-a line: $(cat "$L")"
grep -qF "example-org/cromford#8 @bbbbbbbbbbbb: lead review r-b ran with no heartbeat since never; reclaimed to failed (deadline 1800 s)" "$L" && ok || bad "RC1 r-b line"
lwf_tick
[ "$(lg6_reclaims)" = 2 ] && ok || bad "RC1 the second tick made no reclaim call: $(lg6_reclaims)"

# ── RC2: reclaim down: one line, the head still starts ──
one; echo on > "$FX/reclaim.fail"
lwf_tick
[ "$(lwf_cnt 'reclaim-stale not answered (HTTP 500); stale running rows are not reclaimed this tick' "$L")" = 1 ] && ok || bad "RC2 line: $(cat "$L")"
[ "$(lgf_jobs 101)" = 1 ] && ok || bad "RC2 no job with reclaim down"

# ── M1: no retry/reclaim gate: no reset, no reclaim ──
mv "$GD/95-retry-reclaim.sh" "$T/95.off"
one; failed "review-failed: timeout"
lwf_tick
[ "$(lg6_resets)" = 0 ] && ok || bad "M1 resets=$(lg6_resets) with 95 gone"
[ "$(lg6_reclaims)" = 0 ] && ok || bad "M1 reclaim calls=$(lg6_reclaims) with 95 gone"
mv "$T/95.off" "$GD/95-retry-reclaim.sh"

echo "lead-gates-retry-reclaim.bh-5876: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
