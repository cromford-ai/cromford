#!/bin/bash
# tests/lead-review-worklist.bh-4956-test.sh — BH-4956: bin/lead-review.sh tick
# reads the needs-review worklist (pr_needs_review, GET /api/pr-state/needs-review)
# FIRST, for every LEAD_REVIEW_AUTO_REPOS repo this box owns, and keeps the
# request-row list as the second input. The tick runs WHOLE against a scratch
# harness (tests/lib/lead-worklist-fixture.bh-4956.sh).
#   W1  no rows, needs-review answers 101 102 103: three /start calls in that
#       order, three agent calls, `worklist=3` and `started=3`, and no open-PR
#       list read from GitHub builds the worklist.
#   W2  an item that matches a requested row is claimed through /claim <id>
#       once, with no /start; a row no item matches is reviewed after the items.
#   W3  needs-review answers 500 for one repo: no /start for it, the log names
#       it, and the second auto repo's item still starts.
#   W4  LEAD_REVIEW_AUTO_REPOS unset: no needs-review read; both rows reviewed
#       in one tick (no per-tick start cap).
#   W5  an auto repo another box owns gets no needs-review read.
#   W6  bin/lead-verdict.sh request: one POST /api/lead-reviews, one
#       nudged_sha gate event, one lead-review doorbell; with the event route
#       down it still exits 0 and says `nudge not recorded`.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-review-worklist.bh-4956-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lead-worklist-fixture.bh-4956.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }
lwf_setup
starts() { grep '^POST /api/lead-reviews/start ' "$T/log/worker" 2>/dev/null | sed 's/^POST \/api\/lead-reviews\/start //' | jq -r '.pr' | paste -sd' ' -; }
needs_reads() { lwf_cnt '^GET /api/pr-state/needs-review' "$T/log/worker"; }

# ── W1: the worklist alone, in route order ──
lwf_reset
lwf_needs example-org/demo-os 101 102 103
echo 1 > "$FX/settings/lead_review.concurrency"
LEAD_REVIEW_AUTO_REPOS="example-org/demo-os" lwf_tick
[ "$RC" -eq 0 ] && ok || bad "W1 rc=$RC $(cat "$T/out")"
[ "$(starts)" = "101 102 103" ] && ok || bad "W1 /start order='$(starts)' (want 101 102 103): $(cat "$L" 2>/dev/null)"
[ "$(lwf_agents)" = 3 ] && ok || bad "W1 agent calls=$(lwf_agents) (want 3)"
[ "$(paste -sd' ' "$T/log/agent-prs" 2>/dev/null)" = "101 102 103" ] && ok || bad "W1 agent order: $(paste -sd' ' "$T/log/agent-prs" 2>/dev/null)"
S=$(lwf_summary)
[[ "$S" == *" worklist=3"* && "$S" == *" started=3 "* ]] && ok || bad "W1 summary: $S"
grep -q 'GET /api/pr-state/needs-review?repo=example-org%2Fdemo-os' "$T/log/worker" && ok || bad "W1 no needs-review read for demo-os"
grep -q 'pulls .*state=open\|pulls?.*state=open' "$T/log/gh" 2>/dev/null && bad "W1 an open-PR list was read: $(cat "$T/log/gh")" || ok
[ "$(lwf_cnt '"outcome":"done"' "$T/log/worker")" = 3 ] && ok || bad "W1 done results=$(lwf_cnt '"outcome":"done"' "$T/log/worker")"
grep -q '"reviewing_sha":"'"$SHA"'"' "$T/log/worker" && ok || bad "W1 no reviewing_sha gate event"

# ── W2: an item that has a request row is claimed by id, once ──
lwf_reset
lwf_needs example-org/demo-os 101 102
jq -nc --arg s "$SHA" '[{id:"r-5", repo:"example-org/demo-os", pr:5, head_sha:$s, status:"requested", created_at:"2026-10-10 03:00:00", scope_notes:null, requested_by:"lead-verdict"},
  {id:"r-101", repo:"example-org/demo-os", pr:101, head_sha:$s, status:"requested", created_at:"2026-10-10 03:00:01", scope_notes:null, requested_by:"lead-verdict"}]' > "$FX/rows.json"
echo 1 > "$FX/settings/lead_review.concurrency"
LEAD_REVIEW_AUTO_REPOS="example-org/demo-os" lwf_tick
[ "$(lwf_cnt '^POST /api/lead-reviews/r-101/claim' "$T/log/worker")" = 1 ] && ok || bad "W2 r-101 claims=$(lwf_cnt '^POST /api/lead-reviews/r-101/claim' "$T/log/worker")"
[ "$(starts)" = "102" ] && ok || bad "W2 /start='$(starts)' (want 102 only)"
[ "$(paste -sd' ' "$T/log/agent-prs" 2>/dev/null)" = "101 102 5" ] && ok || bad "W2 agent order: $(paste -sd' ' "$T/log/agent-prs" 2>/dev/null) (want 101 102 5): $(cat "$L")"
S=$(lwf_summary)
[[ "$S" == *" worklist=2"* && "$S" == *" started=3 "* ]] && ok || bad "W2 summary: $S"

# ── W3: one repo's needs-review is down ──
lwf_reset
: > "$FX/needs.example-org_demo-os.fail"
lwf_needs example-org/demo2-os 103
LEAD_REVIEW_AUTO_REPOS="example-org/demo-os example-org/demo2-os" lwf_tick
grep -q '"repo":"example-org/demo-os"' <<<"$(grep '^POST /api/lead-reviews/start ' "$T/log/worker" 2>/dev/null)" && bad "W3 /start for the repo whose read failed" || ok
grep -q 'needs-review.*example-org/demo-os.*unreadable\|example-org/demo-os.*needs-review.*unreadable' "$L" && ok || bad "W3 no log line naming demo-os: $(cat "$L")"
grep '^POST /api/lead-reviews/start ' "$T/log/worker" 2>/dev/null | grep -q '"repo":"example-org/demo2-os"' && ok || bad "W3 demo2-os item not started"
[ "$(lwf_agents)" = 1 ] && ok || bad "W3 agent calls=$(lwf_agents) (want 1)"

# ── W4: not configured = the row path alone, every row in one tick ──
lwf_reset
lwf_rows requested 1 2
lwf_tick
[ "$(needs_reads)" = 0 ] && ok || bad "W4 needs-review read with no auto repos"
[ "$(lwf_agents)" = 2 ] && ok || bad "W4 agent calls=$(lwf_agents) (want 2, no start cap): $(cat "$L")"
[ "$(starts)" = "" ] && ok || bad "W4 /start on the row path: $(starts)"

# ── W5: another box owns the auto repo ──
lwf_reset
lwf_needs example-org/other-os 101
LEAD_REVIEW_AUTO_REPOS="example-org/other-os" lwf_tick
[ "$(needs_reads)" = 0 ] && ok || bad "W5 needs-review read for a repo this box does not own"
[ "$(lwf_agents)" = 0 ] && ok || bad "W5 agent calls=$(lwf_agents)"

# ── W6: the nudge ──
lwf_reset
echo tok-fixture > "$T/leadtok"
( cd "$T" && HARNESS="$H" LEAD_VERDICT_TOKEN_FILE="$T/leadtok" bash "$H/bin/lead-verdict.sh" request example-org/demo-os 7 "$SHA" ) > "$T/w6.out" 2> "$T/w6.err"; RC=$?
[ "$RC" -eq 0 ] && ok || bad "W6 rc=$RC $(cat "$T/w6.err")"
[ "$(lwf_cnt '^POST /api/lead-reviews ' "$T/log/worker")" = 1 ] && ok || bad "W6 request posts=$(lwf_cnt '^POST /api/lead-reviews ' "$T/log/worker")"
grep '^POST /api/pr-state-events ' "$T/log/worker" 2>/dev/null | grep -q '"number":7.*"nudged_sha":"'"$SHA"'"' && ok || bad "W6 no nudged_sha event: $(grep pr-state-events "$T/log/worker")"
[ "$(lwf_cnt '^POST /api/wakes/lane .*"kind":"lead-review"' "$T/log/worker")" = 1 ] && ok || bad "W6 lead-review rings=$(lwf_cnt '^POST /api/wakes/lane .*"kind":"lead-review"' "$T/log/worker"): $(grep wakes "$T/log/worker")"
lwf_reset
: > "$FX/events.fail"
( cd "$T" && HARNESS="$H" LEAD_VERDICT_TOKEN_FILE="$T/leadtok" bash "$H/bin/lead-verdict.sh" request example-org/demo-os 7 "$SHA" ) > "$T/w6.out" 2> "$T/w6.err"; RC=$?
[ "$RC" -eq 0 ] && ok || bad "W6b rc=$RC with the event route down"
grep -q 'nudge not recorded' "$T/w6.err" && ok || bad "W6b stderr: $(cat "$T/w6.err")"
[ "$(lwf_cnt '^POST /api/wakes/lane .*"kind":"lead-review"' "$T/log/worker")" = 1 ] && ok || bad "W6b the doorbell still rings"
sed -n '/^# usage:/,/^#         --source human verdict/p' "$H/bin/lead-verdict.sh" | grep 'request' | grep -qi nudge && ok || bad "W6 usage does not say nudge"

# ── W7: LEAD_REVIEW_WORKLIST=0 (a settings row; the default is 1 since BH-5878) ──
# #4956 option (b): bin/lead-review-enqueue.sh's holds write no gate fact, so
# with the worklist off a needs-review item the enqueue did not request is NOT
# started; only the request rows are reviewed.
lwf_reset
lwf_needs example-org/demo-os 101
lwf_rows requested 1 2
LEAD_REVIEW_WORKLIST=0 LEAD_REVIEW_AUTO_REPOS="example-org/demo-os" lwf_tick
[ "$(needs_reads)" = 0 ] && ok || bad "W7 needs-review read with LEAD_REVIEW_WORKLIST=0"
[ "$(starts)" = "" ] && ok || bad "W7 /start with the worklist off: $(starts)"
[ "$(lwf_agents)" = 2 ] && ok || bad "W7 agent calls=$(lwf_agents) (want 2: the two request rows)"
lwf_reset
lwf_needs example-org/demo-os 101
LEAD_REVIEW_WORKLIST=yes LEAD_REVIEW_AUTO_REPOS="example-org/demo-os" lwf_tick
[ "$(needs_reads)" = 0 ] && ok || bad "W7b a junk LEAD_REVIEW_WORKLIST must read no worklist"
grep -q "LEAD_REVIEW_WORKLIST='yes' is not 0 or 1" "$L" && ok || bad "W7b no log line for the junk value: $(cat "$L")"
lwf_reset
lwf_needs example-org/demo-os 101
( unset LEAD_REVIEW_WORKLIST; LEAD_REVIEW_AUTO_REPOS="example-org/demo-os" lwf_tick )
[ "$(needs_reads)" = 1 ] && ok || bad "W7c unset LEAD_REVIEW_WORKLIST (the default 1, BH-5878) must read the worklist once (reads=$(needs_reads))"

echo "lead-review-worklist.bh-4956: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
