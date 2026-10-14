#!/bin/bash
# tests/lead-review-spend-cap.bh-4956-test.sh — BH-4956: the settings row
# lead_review.daily_spend_usd caps what the lead review lane starts in a UTC
# day (bin/lib/lead-worklist.sh lw_spend_ok, checked before every start).
# bin/lead-review.sh tick runs WHOLE against a scratch harness
# (tests/lib/lead-worklist-fixture.bh-4956.sh).
#   S1  spend 5.00 and the row 5: no /start and no agent call on two ticks,
#       and exactly ONE lane-alert, id lead-spend-cap-<UTC day>.
#   S2  the row raised to 10: the next tick starts the review.
#   S3  the spend reaches the cap after the first start: the second item never
#       starts, and the first finishes and records.
#   S4  a cap row with the spend read failing (500): no /start, no alert. The
#       cap row itself unreadable (500): the same. No cap row (404): reviews run.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-review-spend-cap.bh-4956-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-6052: the day stamp below is read by the code and again here; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 34 || exit 1
. "$(dirname "$0")/lib/lead-worklist-fixture.bh-4956.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }
lwf_setup
export LEAD_REVIEW_AUTO_REPOS="example-org/demo-os"
DAY=$(date -u +%Y%m%d)
starts() { lwf_cnt '^POST /api/lead-reviews/start ' "$T/log/worker"; }
alerts() { lwf_cnt "--id lead-spend-cap-$DAY lead-review" "$T/log/lane-alert"; }

# ── S1: at the cap ──
lwf_reset
lwf_needs example-org/demo-os 101
echo 5 > "$FX/settings/lead_review.daily_spend_usd"; echo 5.00 > "$FX/spend.usd"
lwf_tick; lwf_tick
[ "$(starts)" = 0 ] && ok || bad "S1 /start calls=$(starts) at the cap"
[ "$(lwf_agents)" = 0 ] && ok || bad "S1 agent calls=$(lwf_agents) at the cap"
[ "$(alerts)" = 1 ] && ok || bad "S1 alerts=$(alerts) over two ticks (want 1): $(cat "$T/log/lane-alert" 2>/dev/null)"
grep -q -- '--severity warn' "$T/log/lane-alert" && grep -q '5.00 of 5 USD' "$T/log/lane-alert" && ok || bad "S1 alert text: $(cat "$T/log/lane-alert" 2>/dev/null)"
grep -q 'spend=lead-review\|stage=lead-review.*lane=lead-review' "$T/log/worker" && ok || bad "S1 no lead-review spend read: $(grep llm-spend "$T/log/worker")"
[[ "$(lwf_summary)" == *" capped=1 "* && "$(lwf_summary)" == *" deferred=1 "* ]] && ok || bad "S1 summary: $(lwf_summary)"
grep -q 'lead_review.daily_spend_usd reached (5.00 of 5 USD)' "$L" && ok || bad "S1 no cap line: $(cat "$L")"

# ── S2: the row is raised; the next tick starts ──
echo 10 > "$FX/settings/lead_review.daily_spend_usd"
lwf_tick
[ "$(starts)" = 1 ] && ok || bad "S2 /start calls=$(starts) after the raise"
[ "$(lwf_agents)" = 1 ] && ok || bad "S2 agent calls=$(lwf_agents) after the raise"
[ "$(alerts)" = 1 ] && ok || bad "S2 a second alert: $(alerts)"

# ── S3: the cap is reached after the first start ──
lwf_reset
lwf_needs example-org/demo-os 101 102
echo 5 > "$FX/settings/lead_review.daily_spend_usd"; printf '4.10\n5.20\n' > "$FX/spend.seq"
echo 1 > "$FX/settings/lead_review.concurrency"
lwf_tick
[ "$(starts)" = 1 ] && ok || bad "S3 /start calls=$(starts) (want 1)"
grep -q '"pr":102' <<<"$(grep '^POST /api/lead-reviews/start ' "$T/log/worker")" && bad "S3 the second item started past the cap" || ok
[ "$(lwf_cnt '"outcome":"done"' "$T/log/worker")" = 1 ] && ok || bad "S3 the first review did not record"
[ "$(alerts)" = 1 ] && ok || bad "S3 alerts=$(alerts)"

# ── S4: unreadable is never "go" ──
lwf_reset
lwf_needs example-org/demo-os 101
echo 5 > "$FX/settings/lead_review.daily_spend_usd"; : > "$FX/spend.fail"
lwf_tick
[ "$(starts)" = 0 ] && [ "$(lwf_agents)" = 0 ] && ok || bad "S4 the spend read failed and a review started"
[ "$(alerts)" = 0 ] && ok || bad "S4 an alert on an unreadable spend"
grep -q "the day's lead-review spend is unreadable (cap 5 USD); no new review starts this tick" "$L" && ok || bad "S4 no log line: $(cat "$L")"
lwf_reset
lwf_needs example-org/demo-os 101
echo FAIL > "$FX/settings/lead_review.daily_spend_usd"; echo 1 > "$FX/spend.usd"
lwf_tick
[ "$(starts)" = 0 ] && [ "$(lwf_agents)" = 0 ] && ok || bad "S4b the cap read failed and a review started"
[ "$(alerts)" = 0 ] && ok || bad "S4b an alert on an unreadable cap"
grep -q 'lead_review.daily_spend_usd unreadable; no new review starts this tick' "$L" && ok || bad "S4b no log line: $(cat "$L")"
lwf_reset
lwf_needs example-org/demo-os 101
echo 999 > "$FX/spend.usd"
lwf_tick
[ "$(starts)" = 1 ] && [ "$(lwf_agents)" = 1 ] && ok || bad "S4c no cap row and nothing started: $(cat "$L")"
[ "$(alerts)" = 0 ] && ok || bad "S4c an alert with no cap row"

echo "lead-review-spend-cap.bh-4956: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
