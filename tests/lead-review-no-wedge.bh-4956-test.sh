#!/bin/bash
# tests/lead-review-no-wedge.bh-4956-test.sh — BH-4956: no PR wedges the lead
# review lane. bin/lead-review.sh tick runs WHOLE against a scratch harness
# (tests/lib/lead-worklist-fixture.bh-4956.sh).
#   N1  /start takes over a `running` request whose job is gone: the /start body
#       carries repo, pr, head_sha, the lr-<pr>-<sha12> job and this box, and the
#       review makes one agent call.
#   N2  /start answers 409 with a live holder: no agent call, the job is closed.
#   N3  the live head is unreadable on 3 ticks (a 200 with no head sha, a
#       counted cause): attempts lead-review-1..3 are
#       PUT, then outcome=failed detail="attempts-exhausted: live head
#       unreadable" and one review_failed_sha gate fact.
#   N4  a 4th tick makes no /start for that head.
#   N4b in ONE tick, PR-A goes terminal and PR-B still starts and is reviewed.
#   N5  an agent call refused before billing (rc 75): no attempt, no failed
#       result, and the release marker lead-review-free is PUT.
#   N5b a `running` request row under a dead claim, the agent at rc 75 on 3
#       ticks: only the first takeover (the dead claim) is counted, there is
#       no failed result, each later takeover consumes the release marker,
#       and a 4th tick with the agent back is done.
#   N5c a worklist item refused at rc 75, then listed as its `running` row on
#       the next tick: the takeover is not counted.
#   N3b a worklist item whose live head is unreadable, listed as its `running`
#       row on ticks 2 and 3: one count a tick (1, 2, 3), the terminal on the
#       third tick, never two counts in one tick.
#   N3c a GitHub rate limit (403 "rate limit") on the live-head read on 3
#       ticks: no attempt, no failed result.
#   N3d a GitHub 5xx, and a transport failure (no HTTP status), on the
#       live-head read on 3 ticks: no attempt, no failed result, the release
#       marker each tick. A failed git fetch on 3 ticks: the same. (Lead
#       review of #5890 at 3c76810ce: an outage must not strand a head.)
# TEST-CHANGE (lead review at 3c76810ce): N3, N3b, N4 and N4b used the 500
# fixture for "live head unreadable". A 5xx is no longer counted (N3d), so they
# use ghbad (a 200 with no head sha), which still is. Every assertion is the same.
#   N6  a `running` row whose head moved, under a stale claim, is superseded by
#       the janitor with no agent call.
#   N7  LEAD_REVIEW_MAX_PER_PR_DAY=1: a second head of the same PR on the same
#       UTC day gets no /start, and the summary says capped=1. The trip is ONE
#       lane-alert warn (id lead-trip-example-org_demo-os-101-<day>), and a third
#       capped tick alerts no more.
#   N8  the default tripwire (4) counts reviews the model answered: 4 ticks at
#       rc 75, then a 5th tick still starts, reaches the agent and is done.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-review-no-wedge.bh-4956-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lead-worklist-fixture.bh-4956.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }
lwf_setup
export LEAD_REVIEW_AUTO_REPOS="example-org/demo-os"
S12=${SHA:0:12}
startbody() { grep "^POST /api/lead-reviews/start " "$T/log/worker" 2>/dev/null | sed 's/^POST \/api\/lead-reviews\/start //' | jq -c "select(.pr == $1)"; }
nstarts() { local n; n=$(startbody "$1" | grep -c .); echo "${n:-0}"; }
# The counted attempts (lead-review-<n>), and the release markers, PUT for a PR.
attempt_puts() { grep '^PUT /api/pr-attempts ' "$T/log/worker" 2>/dev/null | sed 's/^PUT \/api\/pr-attempts //' | jq -r "select(.number == $1 and (.kind | test(\"^lead-review-[0-9]+$\"))) | .kind" | paste -sd' ' -; }
free_puts() { local n; n=$(grep '^PUT /api/pr-attempts ' "$T/log/worker" 2>/dev/null | sed 's/^PUT \/api\/pr-attempts //' | jq -r "select(.number == $1 and .kind == \"lead-review-free\") | .kind" | grep -c .); echo "${n:-0}"; }
free_dels() { lwf_cnt "^DELETE /api/pr-attempts?.*number=$1&kind=lead-review-free" "$T/log/worker"; }
running_row() { jq -nc --arg s "$SHA" --argjson n "$1" '[{id:("r-" + ($n|tostring)), repo:"example-org/demo-os", pr:$n, head_sha:$s, status:"running",
  job_id:"job-gone", created_at:"2026-10-10 03:00:00", scope_notes:null, requested_by:"lead-verdict"}]' > "$FX/rows.json"; }

# ── N1: a dead claim is taken over through /start ──
lwf_reset
lwf_needs example-org/demo-os 101
echo "running job-lr-101-dead" > "$FX/start.101.$S12"
lwf_tick
B=$(startbody 101)
[ "$(jq -r '.repo' <<<"$B")" = example-org/demo-os ] && [ "$(jq -r '.head_sha' <<<"$B")" = "$SHA" ] \
  && [ "$(jq -r '.job_id' <<<"$B")" = "job-lr-101-$S12" ] && [ "$(jq -r '.box' <<<"$B")" = box-demo ] \
  && ok || bad "N1 /start body: $B"
[ "$(lwf_agents)" = 1 ] && ok || bad "N1 agent calls=$(lwf_agents) (want 1): $(cat "$L")"
grep -q "^POST /api/lead-reviews/s-101-$S12/result .*\"outcome\":\"done\"" "$T/log/worker" && ok || bad "N1 no done result on the taken row"

# ── N2: a live holder ──
lwf_reset
lwf_needs example-org/demo-os 101
echo live > "$FX/start.101.$S12.force"
lwf_tick
[ "$(lwf_agents)" = 0 ] && ok || bad "N2 agent calls=$(lwf_agents) with a live holder"
grep -q "^PATCH /api/jobs/job-lr-101-$S12 .*\"status\":\"done\"" "$T/log/worker" && ok || bad "N2 the job was not closed: $(grep PATCH "$T/log/worker")"
grep -q "skip lr-101-$S12: a live job holds its request" "$L" && ok || bad "N2 no skip line: $(cat "$L")"
[[ "$(lwf_summary)" == *" skipped=1 "* ]] && ok || bad "N2 summary: $(lwf_summary)"

# ── N3: the live head is unreadable on three ticks ──
lwf_reset
lwf_needs example-org/demo-os 101
: > "$FX/ghbad.101"
lwf_tick; lwf_tick
[ "$(attempt_puts 101)" = "lead-review-1 lead-review-2" ] && ok || bad "N3 attempts after 2 ticks: '$(attempt_puts 101)'"
grep -q '"outcome":"failed"' "$T/log/worker" && bad "N3 failed before the third attempt" || ok
lwf_tick
[ "$(attempt_puts 101)" = "lead-review-1 lead-review-2 lead-review-3" ] && ok || bad "N3 attempts after 3 ticks: '$(attempt_puts 101)'"
[ "$(lwf_cnt "^POST /api/lead-reviews/s-101-$S12/result .*\"outcome\":\"failed\".*\"detail\":\"attempts-exhausted: live head unreadable\"" "$T/log/worker")" = 1 ] \
  && ok || bad "N3 no attempts-exhausted result: $(grep result "$T/log/worker")"
[ "$(lwf_cnt "^POST /api/pr-state-events .*\"review_failed_sha\":\"$SHA\"" "$T/log/worker")" = 1 ] && ok || bad "N3 review_failed_sha events: $(grep pr-state-events "$T/log/worker")"
grep -q "^PATCH /api/jobs/job-lr-101-$S12 .*\"status\":\"failed\"" "$T/log/worker" && ok || bad "N3 the job was not failed"
[ "$(lwf_agents)" = 0 ] && ok || bad "N3 agent calls=$(lwf_agents)"
# ── N4: a 4th tick makes no /start for that head ──
n0=$(nstarts 101)
lwf_tick
[ "$(nstarts 101)" = "$n0" ] && ok || bad "N4 a 4th-tick /start: $(nstarts 101) (was $n0)"
grep -q "skip lr-101-$S12: 3 counted attempts on this head" "$L" && ok || bad "N4 no skip line: $(tail -3 "$L")"

# ── N4b: one PR going terminal never holds another ──
lwf_reset
lwf_needs example-org/demo-os 101 102
: > "$FX/ghbad.101"
printf '101 lead-review-1 %s\n101 lead-review-2 %s\n' "$SHA" "$SHA" > "$FX/attempts"
echo 1 > "$FX/settings/lead_review.concurrency"
lwf_tick
grep -q '"detail":"attempts-exhausted: live head unreadable"' "$T/log/worker" && ok || bad "N4b PR-A did not go terminal"
[ "$(paste -sd' ' "$T/log/agent-prs" 2>/dev/null)" = 102 ] && ok || bad "N4b PR-B calls: '$(paste -sd' ' "$T/log/agent-prs" 2>/dev/null)' (want 102)"
grep -q "^POST /api/lead-reviews/s-102-$S12/result .*\"outcome\":\"done\"" "$T/log/worker" && ok || bad "N4b PR-B not done"
[ "$(grep -c ' tick seen=' "$L")" = 1 ] && ok || bad "N4b want one tick"
[[ "$(lwf_summary)" == *" failed=1 "* && "$(lwf_summary)" == *" done=1 "* ]] && ok || bad "N4b summary: $(lwf_summary)"

# ── N5: a refusal before billing is not an attempt ──
lwf_reset
lwf_needs example-org/demo-os 101
echo 75 > "$FX/agentrc.101"
lwf_tick
[ "$(lwf_agents)" = 1 ] && ok || bad "N5 agent calls=$(lwf_agents)"
[ -z "$(attempt_puts 101)" ] && ok || bad "N5 an attempt was counted: $(attempt_puts 101)"
grep -q '"outcome":"failed"' "$T/log/worker" && bad "N5 a failed result" || ok
grep -q "agent-call refused lr-101-$S12 (rc=75" "$L" && ok || bad "N5 no refusal line"
[ "$(free_puts 101)" = 1 ] && ok || bad "N5 release markers PUT=$(free_puts 101) (want 1)"

# ── N5b: refusals before billing on a running request row never go terminal ──
lwf_reset
running_row 5
echo 75 > "$FX/agentrc.5"
lwf_tick; lwf_tick; lwf_tick
[ "$(lwf_agents)" = 3 ] && ok || bad "N5b agent calls=$(lwf_agents) (want 3)"
[ "$(attempt_puts 5)" = "lead-review-1" ] && ok || bad "N5b counted attempts: '$(attempt_puts 5)' (want only the dead claim's)"
grep -q '"outcome":"failed"' "$T/log/worker" && bad "N5b a failed result: $(grep result "$T/log/worker")" || ok
[ "$(lwf_cnt "lr-5-$S12: the claim taken over was released by this lane; not counted" "$L")" = 2 ] && ok || bad "N5b release lines: $(grep -c released "$L")"
[ "$(free_dels 5)" = 2 ] && ok || bad "N5b release markers consumed=$(free_dels 5) (want 2)"
rm -f "$FX/agentrc.5"
lwf_tick
grep -q "^POST /api/lead-reviews/r-5/result .*\"outcome\":\"done\"" "$T/log/worker" && ok || bad "N5b the 4th tick is not done: $(tail -3 "$L")"
[ "$(attempt_puts 5)" = "lead-review-1" ] && ok || bad "N5b counted attempts after the 4th tick: '$(attempt_puts 5)'"

# ── N5c: a refused worklist item, then its running row, is not counted ──
lwf_reset
lwf_needs example-org/demo-os 101
echo 75 > "$FX/agentrc.101"
lwf_tick
running_row 101
lwf_tick
[ "$(lwf_agents)" = 2 ] && ok || bad "N5c agent calls=$(lwf_agents) (want 2)"
[ -z "$(attempt_puts 101)" ] && ok || bad "N5c an attempt was counted: '$(attempt_puts 101)'"
grep -q "^POST /api/lead-reviews/r-101/claim " "$T/log/worker" && ok || bad "N5c tick 2 did not claim the row"
grep -q "lr-101-$S12: the claim taken over was released by this lane; not counted" "$L" && ok || bad "N5c no release line: $(tail -5 "$L")"

# ── N3b: one counted failure is counted once, never again as a takeover ──
lwf_reset
lwf_needs example-org/demo-os 101
: > "$FX/ghbad.101"
lwf_tick
[ "$(attempt_puts 101)" = "lead-review-1" ] && ok || bad "N3b attempts after tick 1: '$(attempt_puts 101)'"
running_row 101
lwf_tick
[ "$(attempt_puts 101)" = "lead-review-1 lead-review-2" ] && ok || bad "N3b attempts after tick 2: '$(attempt_puts 101)'"
grep -q '"outcome":"failed"' "$T/log/worker" && bad "N3b terminal after 2 ticks" || ok
lwf_tick
[ "$(attempt_puts 101)" = "lead-review-1 lead-review-2 lead-review-3" ] && ok || bad "N3b attempts after tick 3: '$(attempt_puts 101)'"
grep -q '^POST /api/lead-reviews/r-101/result .*"detail":"attempts-exhausted: live head unreadable"' "$T/log/worker" && ok || bad "N3b no terminal on tick 3"

# ── N3c: a GitHub rate limit on the live-head read is not counted ──
lwf_reset
lwf_needs example-org/demo-os 101
: > "$FX/ghrl.101"
lwf_tick; lwf_tick; lwf_tick
[ -z "$(attempt_puts 101)" ] && ok || bad "N3c a rate limit was counted: '$(attempt_puts 101)'"
grep -q '"outcome":"failed"' "$T/log/worker" && bad "N3c a failed result" || ok
[ "$(free_puts 101)" = 3 ] && ok || bad "N3c release markers PUT=$(free_puts 101) (want 3)"

# ── N3d: a GitHub 5xx, a transport failure or a failed fetch is not counted ──
for fx in ghfail ghdown; do
  lwf_reset
  lwf_needs example-org/demo-os 101
  : > "$FX/$fx.101"
  lwf_tick; lwf_tick; lwf_tick
  [ -z "$(attempt_puts 101)" ] && ok || bad "N3d $fx was counted: '$(attempt_puts 101)'"
  grep -q '"outcome":"failed"' "$T/log/worker" && bad "N3d $fx: a failed result: $(grep result "$T/log/worker")" || ok
  [ "$(free_puts 101)" = 3 ] && ok || bad "N3d $fx: release markers PUT=$(free_puts 101) (want 3)"
  [ "$(lwf_agents)" = 0 ] && ok || bad "N3d $fx: agent calls=$(lwf_agents)"
done
lwf_reset
lwf_needs example-org/demo-os 909   # no refs/pull/909/head in the fixture origin: the fetch fails
lwf_tick; lwf_tick; lwf_tick
[ -z "$(attempt_puts 909)" ] && ok || bad "N3d a failed fetch was counted: '$(attempt_puts 909)'"
grep -q '"outcome":"failed"' "$T/log/worker" && bad "N3d fetch: a failed result: $(grep result "$T/log/worker")" || ok
grep -q "lr-909-$S12 failed (fetch); lr-909-$S12 left for the next tick, not counted" "$L" && ok || bad "N3d fetch: no not-counted line: $(grep 909 "$L" | tail -3)"

# ── N6: the janitor supersedes a running row whose head moved ──
lwf_reset
jq -nc --arg s "$SHA" '[{id:"r-5", repo:"example-org/demo-os", pr:5, head_sha:$s, status:"running", job_id:"job-gone",
  created_at:"2026-10-10 03:00:00", scope_notes:null, requested_by:"lead-verdict"}]' > "$FX/rows.json"
printf '%040d\n' 7 > "$FX/head.5"
lwf_tick
grep -q '^POST /api/lead-reviews/r-5/result .*"outcome":"superseded".*"detail":"head moved to 000000000000"' "$T/log/worker" && ok || bad "N6 not superseded: $(grep r-5 "$T/log/worker")"
[ "$(lwf_agents)" = 0 ] && ok || bad "N6 agent calls=$(lwf_agents)"
[[ "$(lwf_summary)" == *" superseded=1 "* ]] && ok || bad "N6 summary: $(lwf_summary)"

# ── N7: the per-PR-day tripwire ──
lwf_reset
lwf_needs example-org/demo-os 101
LEAD_REVIEW_MAX_PER_PR_DAY=1 lwf_tick
[ "$(nstarts 101)" = 1 ] && ok || bad "N7 first head starts=$(nstarts 101)"
SHA2=$(printf '%040d' 2)
lwf_needs_at example-org/demo-os "$SHA2" 101
# TEST-CHANGE (BH-5874): the PR's own head moves too. Gate 16 now holds a
# worklist head the PR body does not name (lead BLOCK at 19019cf2e), so a
# fixture that moved only the worklist would test that hold, not the cap.
echo "$SHA2" > "$FX/head.101"
LEAD_REVIEW_MAX_PER_PR_DAY=1 lwf_tick
[ "$(nstarts 101)" = 1 ] && ok || bad "N7 the second head started: $(startbody 101)"
# TEST-CHANGE (BH-5876): gate 13 (bin/lib/lead-gates.d/90-caps.sh) now stops a
# worklist head at the per-PR-day cap BEFORE job_open, so the summary counts it
# skipped=1 (not capped=1), the line is the gate's `[skip pr-day-cap]`, and no
# lead_review job is opened for it. The cap, the started.tsv count and the ONE
# trip alert are the same.
[[ "$(lwf_summary)" == *" skipped=1 "* ]] && ok || bad "N7 summary: $(lwf_summary)"
grep -qF "[skip pr-day-cap] example-org/demo-os#101 @${SHA2:0:12} 1 lead reviews of this PR today (LEAD_REVIEW_MAX_PER_PR_DAY=1); not started" "$L" && ok || bad "N7 no cap line: $(tail -3 "$L")"
[ "$(lwf_cnt "^POST /api/jobs .*\"ticket_id\":\"lr-101-${SHA2:0:12}\"" "$T/log/worker")" = 0 ] && ok || bad "N7 a job was opened for the capped head"
[ "$(awk -F'\t' '$3 == 101' "$H/state/lead-review/started.tsv" | wc -l | tr -d ' ')" = 1 ] && ok || bad "N7 started.tsv: $(cat "$H/state/lead-review/started.tsv")"
DAY=$(TZ=UTC0 date +%Y%m%d)
[ "$(lwf_cnt "--severity warn --id lead-trip-example-org_demo-os-101-$DAY lead-review " "$T/log/lane-alert")" = 1 ] && ok || bad "N7 trip alerts: $(cat "$T/log/lane-alert" 2>/dev/null)"
LEAD_REVIEW_MAX_PER_PR_DAY=1 lwf_tick
[ "$(nstarts 101)" = 1 ] && ok || bad "N7 the third tick started"
[ "$(grep -c . "$T/log/lane-alert" 2>/dev/null)" = 1 ] && ok || bad "N7 the third tick alerted again: $(cat "$T/log/lane-alert")"

# ── N8: the tripwire counts reviews the model answered, not refused claims ──
lwf_reset
lwf_needs example-org/demo-os 101
echo 75 > "$FX/agentrc.101"
lwf_tick; lwf_tick; lwf_tick; lwf_tick
[ "$(lwf_agents)" = 4 ] && ok || bad "N8 agent calls after 4 refused ticks=$(lwf_agents)"
[ ! -s "$H/state/lead-review/started.tsv" ] && ok || bad "N8 refused claims were marked: $(cat "$H/state/lead-review/started.tsv")"
rm -f "$FX/agentrc.101"; rm -f "$FX/start.101.$S12"
lwf_tick
[ "$(lwf_agents)" = 5 ] && ok || bad "N8 the 5th tick made no agent call: $(tail -3 "$L")"
grep -q "^POST /api/lead-reviews/s-101-$S12/result .*\"outcome\":\"done\"" "$T/log/worker" && ok || bad "N8 the 5th tick is not done"
grep -q 'per-pr-day cap' "$T/log/worker" && bad "N8 the tripwire fired" || ok

echo "lead-review-no-wedge.bh-4956: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
