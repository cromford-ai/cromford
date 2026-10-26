#!/bin/bash
# tests/review-prs-stale-cr.bh-5396-test.sh — BH-5396: a new head on an
# EXTERNAL PR that carries this lane's REQUEST_CHANGES on an older head is
# reviewed by this lane and the verdict is posted on GitHub. It is never settled
# from another lane's verdict with nothing posted (project-3 #481: agent/TK-303 by
# collaborator-1, CHANGES_REQUESTED on A, fix head B never judged on the PR).
# The whole bin/review-prs.sh runs from a scratch harness with its real bin/lib
# closure, through its production entry point. Stubbed: gh (behind
# tests/lib/gh-list-bridge.sh), the jobs functions (BASH_ENV), and
# bin/agent-call.sh (records each call's guard fingerprint; answers a verdict,
# or a before-billing refusal when $T/ac74 exists).
#   S1  #481 shape, no ledger row: one call on review:<slug>#481@B~stalecr, one
#       `gh pr review` carrying this lane's marker at B, the verdict at B.
#   S2  another lane's rrverdict BLOCK at B (mc_rereview): still one call, one
#       review posted, no review_skip_unchanged, a REREVIEW_REASON=stalecr line.
#   S3  a D1 /api/verdict row at B (a foreign build/rescue row): still one call,
#       no "the jobs ledger already holds" line.
#   S4  the call-guard refuses (rc 74): tick 1 logs the refusal and starts the
#       clock; 13h later tick 2 alerts once, quoting rc=74; tick 3 is silent.
#       S4i: the same through the inline loop (no review-pool lib on the box).
#   S5  unchanged: a harness-authored PR (a), an APPROVE on record (b), a first
#       review (c), this lane's marker already at B on GitHub (d), and the same
#       head already recorded (e) buy nothing.
#   S6  no stale-head alert for a CI-deferred head (a; the CI path alerts) or
#       under 12h (b). S6d: a head deferred on CI once, then refused (rc 74)
#       after CI went green, still alerts once after 12h (S6di: inline loop).
#   S7  CI pending on B in the stale-CR shape: no call, the deferred line.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/review-prs-stale-cr.bh-5396-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
. "$(dirname "$0")/lib/model-route-stub.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }

PROJECT=project-1
SLUG=example-org/project-1
A=1d5131c5aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
B=5c975224bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
H="$T/h"
STATE="$H/state/$PROJECT.pr-reviews.json"
LOG="$H/logs/pr-reviews.log"
MARKER="Automated harness review (Fable) of"
mkdir -p "$T/fakebin" "$T/log"
cp "$SRC/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"

cat > "$T/fakebin/gh" <<'STUB'
#!/bin/bash
case "$*" in
  *"/pulls -f state=open"*) case "$*" in *"page=1"|*"page=1 "*) restpr --raw 200 "$(cat "$TEST_ROOT/prs.json")" ;;
      *) restpr --raw 200 '[]' ;; esac ;;
  *"pr diff"*"name-only"*) printf 'f.txt\n' ;;
  *"pr diff"*) printf 'diff --git a/f.txt b/f.txt\n+line 10 CHANGED BY PR\n' ;;
  *"pr view"*"state,mergeStateStatus"*) printf '{"state":"OPEN","mergeStateStatus":"BLOCKED"}\n' ;;
  *"pr view"*) printf '{"body":"test body","comments":[],"reviews":[]}\n' ;;
  *"pr review"*|*"pr comment"*) printf 'WRITE %s\n' "$*" >> "$TEST_ROOT/gh-writes.log" ;;
  *"pr merge"*) : ;;
  *actions/runs*) if [ -e "$TEST_ROOT/ci-pending" ]; then printf '{"s":"in_progress","c":null,"n":"CI"}\n'
      else printf '{"s":"completed","c":"success","n":"CI"}\n'; fi ;;
  *"/reviews"*)
    n=$(printf '%s' "$*" | sed -E 's|.*pulls/([0-9]+)/reviews.*|\1|')
    [ -f "$TEST_ROOT/reviews.$n" ] && cat "$TEST_ROOT/reviews.$n" ;;
  *) : ;;
esac
exit 0
STUB
chmod +x "$T/fakebin/gh"
printf 'MemTotal: 67108864 kB\nMemAvailable: 67108864 kB\n' > "$T/meminfo"
# The jobs functions. The three review_bought reads answer "no row" unless a
# case appends its own hit below; job_verdict exists only where a case adds it.
cat > "$T/stub.sh" <<EOF
job_lane_open() { JOB_ID="job-\$2"; export JOB_ID; return 0; }
job_lane_close() { JOB_ID=""; export JOB_ID; return 0; }
job_artifact_put() { return 0; }
job_event() { return 0; }
job_heartbeat() { return 0; }
job_update() { return 0; }
job_phase_open() { return 0; }
job_verdict_rebind() { return 0; }
_jobs_req() { case "\$2" in /api/verdicts*) printf '{"rows":[]}' ;; *) printf '{"rounds":[]}' ;; esac; return 0; }
job_verdict_history() { return 2; }
pr_attempt_list() { return 0; }
EOF

# fresh <state-json> [author] — scratch harness, the #481 PR at head B, this
# lane's CHANGES_REQUESTED on A on GitHub, green CI.
fresh() {
  scratch_rm "$H" 2>/dev/null
  rm -f "$T/log"/* "$T/gh-writes.log" "$T"/reviews.* "$T/ac74" "$T/ci-pending"
  mkdir -p "$H/bin" "$H/state" "$H/logs" "$H/locks" "$H/env" "$H/builds" "$H/tmp"
  mkdir -p "$H/catalog/lanes.d"; cp "$SRC/catalog/lanes.d/_lib.json" "$H/catalog/lanes.d/"
  cp "$SRC/bin/review-prs.sh" "$SRC/bin/fleet-conf.sh" "$H/bin/"
  scratch_install_closure bin/review-prs.sh "$H" >/dev/null || { echo "closure install failed"; exit 1; }
  mrs_fixture "$H" "$PROJECT"
  cp "$T/stub.sh" "$H/bin/stub.sh"
  for b in beat.sh deploy-request.sh merge-queue.sh; do printf '#!/bin/bash\nexit 0\n' > "$H/bin/$b"; chmod +x "$H/bin/$b"; done
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/log/alerts"\n' "$T" > "$H/bin/alert-line.sh"; chmod +x "$H/bin/alert-line.sh"
  cat > "$H/bin/agent-call.sh" <<EOF
#!/bin/bash
printf '%s\n' "\${AGENT_CALL_FP:-}" >> "$T/log/sink"
if [ -e "$T/ac74" ]; then
  printf 'AGENT_CALL_REFUSED call-guard: %s already charged today\n' "\${AGENT_CALL_FP:-}" > "\$5"
  exit 74
fi
printf 'claude\n' > "\$5.runner"; printf 'claude-fable-5-1\n' > "\$5.model"
printf 'Static review.\nTIER: 2\nVERDICT: REQUEST_CHANGES\n' > "\$5"
exit 0
EOF
  chmod +x "$H/bin/agent-call.sh"
  printf '%s\n' "$1" > "$STATE"
  jq -nc --arg h "$B" --arg u "${2:-collaborator-1}" '[{number:481, head:{sha:$h,ref:"agent/TK-303"}, base:{ref:"main"},
     user:{login:$u,type:"User"}, title:"TK-303 fix", draft:false, state:"open", labels:[]}]' > "$T/prs.json"
  : > "$T/log/sink"
  review_on 481 "$A" CHANGES_REQUESTED
}
# review_on <pr> <sha> <state> — this lane's review (its footer marker) of <sha>.
# BH-8419: the lane's review is the App's (cromford[bot]); operator is a person.
review_on() {
  printf '%s\t%s\t%s\n' 'cromford[bot]' "$3" \
    "$(printf 'Findings.\nVERDICT: REQUEST_CHANGES\n\n---\n_%s %s. Static review._' "$MARKER" "$2" | base64 -w0)" >> "$T/reviews.$1"
}
stub_add() { printf '%s\n' "$1" >> "$H/bin/stub.sh"; }
RR_HIT="pr_attempt_list() { printf '%s BLOCK %s claude\n' \"$B\" \"\$(date +%s)\"; return 0; }"
run_rp() {
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$SRC/fleet.conf" TEST_ROOT="$T" \
      REPOS_ROOT="$T/no-repos" BASH_ENV="$H/bin/stub.sh" REVIEW_LIVE_CI=0 REVIEW_CONCURRENCY=1 \
      REVIEW_POOL_MEMINFO="$T/meminfo" REVIEW_POOL_POLL_S=0.05 TMPDIR="$T/tmp-$1"
    mkdir -p "$TMPDIR"
    unset JOB_ID JOB_BEAT JOB_INFLIGHT JOB_REFUSED REVIEW_BOX_MAX REVIEW_TMP_MIN_MB REVIEW_POOL_TMP_PATH \
      REVIEW_DEDUPE REVIEW_CI_STALE_SECS
    bash "$H/bin/review-prs.sh" "$PROJECT" > "$T/out.$1" 2>&1 )
}
cnt() { local n; n=$(grep -c -- "$1" "$2" 2>/dev/null); echo "${n:-0}"; }
calls() { cnt . "$T/log/sink"; }
writes() { cnt '^WRITE pr review 481' "$T/gh-writes.log"; }
alerts() { cnt . "$T/log/alerts"; }
st() { jq -r --arg n 481 ".[\$n]$1 // \"\"" "$STATE"; }
RC_STATE=$(jq -nc --arg a "$A" '{"481":{sha:$a,verdict:"REQUEST_CHANGES",tier:"2",served:"claude"}}')
FP_STALE="review:$SLUG#481@$B~stalecr"

# ── S1: the bare #481 shape ──
fresh "$RC_STATE"
run_rp s1
[ "$(calls)" = 1 ] && ok || bad "S1 calls=$(calls) (want 1): $(tail -5 "$LOG")"
grep -qxF "$FP_STALE" "$T/log/sink" && ok || bad "S1 guard key is not $FP_STALE: $(cat "$T/log/sink")"
[ "$(writes)" = 1 ] && grep -q "$MARKER $B" "$T/gh-writes.log" && ok || bad "S1 no review of B posted: $(cat "$T/gh-writes.log" 2>/dev/null)"
[ "$(st .sha)" = "$B" ] && [ "$(st .verdict)" = REQUEST_CHANGES ] && ok || bad "S1 verdict not at B: $(cat "$STATE")"

# ── S2: another lane's rrverdict at B (P1) ──
fresh "$RC_STATE"; stub_add "$RR_HIT"
run_rp s2
[ "$(calls)" = 1 ] && ok || bad "S2 calls=$(calls) (want 1): $(tail -5 "$LOG")"
[ "$(writes)" = 1 ] && grep -q "$MARKER $B" "$T/gh-writes.log" && ok || bad "S2 no review of B posted: $(cat "$T/gh-writes.log" 2>/dev/null)"
grep -q "review_skip_unchanged $SLUG#481@" "$LOG" && bad "S2 B settled from another lane's verdict: $(grep review_skip "$LOG")" || ok
grep -q "#481 @${B:0:7} new head after this lane's REQUEST_CHANGES on ${A:0:7} (external PR).*REREVIEW_REASON=stalecr" "$LOG" \
  && ok || bad "S2 no stale-CR line: $(tail -5 "$LOG")"
[ -z "$(st .reused_from)" ] && ok || bad "S2 state records a reuse: $(cat "$STATE")"

# ── S3: a D1 /api/verdict row at B (P2) ──
fresh "$RC_STATE"
stub_add "job_verdict() { printf 'BLOCK\t2\tclaude\t-\tjob-x\t%s\n' '$B'; return 0; }"
run_rp s3
[ "$(calls)" = 1 ] && ok || bad "S3 calls=$(calls) (want 1): $(tail -5 "$LOG")"
grep -q 'not re-reviewed: the jobs ledger already holds' "$LOG" && bad "S3 B rehydrated from a foreign D1 row" || ok
[ "$(writes)" = 1 ] && ok || bad "S3 writes=$(writes) (want 1)"
# D1 down in the stale-CR shape does not HOLD: GitHub alone answers.
fresh "$RC_STATE"
stub_add "job_verdict() { return 1; }"; stub_add "jobs_configured() { return 0; }"
run_rp s3b
[ "$(calls)" = 1 ] && ok || bad "S3b D1 down held a stale-CR head: calls=$(calls): $(tail -3 "$LOG")"

# ── S4: a call-guard refusal, and the 12h clock ──
s4() { # s4 <tag>
  local tag="$1" since
  : > "$T/ac74"
  run_rp "${tag}1"
  grep -q "#481 @${B:0:7} agent-call returned before billing (rc=74" "$LOG" && ok || bad "$tag tick1 no refusal line: $(tail -3 "$LOG")"
  [ "$(st .stale_head_sha)" = "$B" ] && [ -n "$(st .stale_head_since)" ] && ok || bad "$tag tick1 clock not started: $(cat "$STATE")"
  [ "$(alerts)" = 0 ] && ok || bad "$tag tick1 alerted early: $(cat "$T/log/alerts")"
  since=$(( $(date -u +%s) - 13 * 3600 ))
  jq --argjson s "$since" '.["481"].stale_head_since = $s' "$STATE" > "$STATE.t" && mv "$STATE.t" "$STATE"
  run_rp "${tag}2"
  [ "$(alerts)" = 1 ] && ok || bad "$tag tick2 alerts=$(alerts) (want 1): $(cat "$T/log/alerts" 2>/dev/null)"
  grep -q "#481 @${B:0:7}" "$T/log/alerts" 2>/dev/null && grep -q 'rc=74' "$T/log/alerts" && ok \
    || bad "$tag alert does not name the head and the reason: $(cat "$T/log/alerts" 2>/dev/null)"
  [ "$(st .stale_head_since)" = "$since" ] && ok || bad "$tag tick2 restarted the clock: $(cat "$STATE")"
  run_rp "${tag}3"
  [ "$(alerts)" = 1 ] && ok || bad "$tag tick3 alerted again: $(cat "$T/log/alerts")"
  # A verdict at B clears the clock.
  rm -f "$T/ac74"; run_rp "${tag}4"
  [ "$(st .sha)" = "$B" ] && [ -z "$(st .stale_head_since)" ] && ok || bad "$tag the verdict at B kept the clock: $(cat "$STATE")"
}
fresh "$RC_STATE"; s4 S4
fresh "$RC_STATE"; rm -f "$H/bin/lib/review-pool.sh"; s4 S4i

# ── S5: the shapes that must not re-buy ──
fresh "$(jq -nc --arg a "$A" '{"481":{sha:$a,verdict:"REQUEST_CHANGES",tier:"2",served:"claude"}}')" operator
stub_add "$RR_HIT"; run_rp s5a
[ "$(calls)" = 0 ] && ok || bad "S5a harness-authored PR bought: $(cat "$T/log/sink")"
grep -q "review_skip_unchanged $SLUG#481@" "$LOG" && ok || bad "S5a no skip line: $(tail -3 "$LOG")"
fresh "$(jq -nc --arg a "$A" '{"481":{sha:$a,verdict:"APPROVE",tier:"2",served:"claude"}}')"
stub_add "$RR_HIT"; run_rp s5b
[ "$(calls)" = 0 ] && ok || bad "S5b APPROVE on record bought: $(cat "$T/log/sink")"
fresh '{}'; stub_add "$RR_HIT"; run_rp s5c
[ "$(calls)" = 0 ] && ok || bad "S5c first review with a hit bought: $(cat "$T/log/sink")"
fresh "$RC_STATE"; review_on 481 "$B" CHANGES_REQUESTED; run_rp s5d
[ "$(calls)" = 0 ] && ok || bad "S5d this lane's review at B already on GitHub, bought again: $(cat "$T/log/sink")"
grep -q "#481 @${B:0:7} not re-reviewed: $SLUG already carries this lane's review" "$LOG" && ok || bad "S5d not rehydrated: $(tail -3 "$LOG")"
fresh "$(jq -nc --arg b "$B" '{"481":{sha:$b,verdict:"REQUEST_CHANGES",tier:"2",served:"claude"}}')"; run_rp s5e
[ "$(calls)" = 0 ] && ok || bad "S5e the recorded head bought again: $(cat "$T/log/sink")"
[ "$(cnt REREVIEW_REASON=stalecr "$LOG")" = 0 ] && ok || bad "S5e a recorded head read as stale-CR"

# ── S6: no stale-head alert where the CI path owns the wait, or under 12h ──
fresh "$(jq -nc --arg a "$A" --arg b "$B" --argjson at "$(( $(date -u +%s) - 13 * 3600 ))" \
  '{"481":{sha:$a,verdict:"REQUEST_CHANGES",tier:"2",served:"claude",deferred_sha:$b,deferred_at:$at}}')"
: > "$T/ci-pending"; run_rp s6a
[ "$(alerts)" = 1 ] && grep -q 'waited at least 43200s for green CI' "$T/log/alerts" && ok \
  || bad "S6a want exactly the CI alert: $(cat "$T/log/alerts" 2>/dev/null)"
[ -z "$(st .stale_head_since)" ] && ok || bad "S6a a CI-deferred head started the stale-head clock: $(cat "$STATE")"
fresh "$(jq -nc --arg a "$A" --arg b "$B" --argjson s "$(( $(date -u +%s) - 3600 ))" \
  '{"481":{sha:$a,verdict:"REQUEST_CHANGES",tier:"2",served:"claude",stale_head_sha:$b,stale_head_since:$s}}')"
: > "$T/ac74"; run_rp s6b
[ "$(alerts)" = 0 ] && ok || bad "S6b alerted under 12h: $(cat "$T/log/alerts")"

# S6d: a head the CI debounce deferred once, then skipped after CI went green
# (rc 74), still gets the stale-head clock and its one alert. The row keeps
# deferred_sha=B, so the watch must not read that as "the CI path owns it".
s6d() { # s6d <tag>
  local tag="$1" since
  : > "$T/ci-pending"; run_rp "${tag}1"
  [ "$(st .deferred_sha)" = "$B" ] && ok || bad "$tag tick1 not deferred: $(cat "$STATE")"
  [ -z "$(st .stale_head_since)" ] && ok || bad "$tag tick1 a CI-deferred pass started the clock: $(cat "$STATE")"
  rm -f "$T/ci-pending"; : > "$T/ac74"; run_rp "${tag}2"
  grep -q "#481 @${B:0:7} agent-call returned before billing (rc=74" "$LOG" && ok || bad "$tag tick2 no refusal line: $(tail -3 "$LOG")"
  [ "$(st .deferred_sha)" = "$B" ] && [ "$(st .stale_head_sha)" = "$B" ] && [ -n "$(st .stale_head_since)" ] && ok \
    || bad "$tag tick2 green-CI skip did not start the clock: $(cat "$STATE")"
  since=$(( $(date -u +%s) - 13 * 3600 ))
  jq --argjson s "$since" '.["481"].stale_head_since = $s' "$STATE" > "$STATE.t" && mv "$STATE.t" "$STATE"
  run_rp "${tag}3"
  [ "$(alerts)" = 1 ] && grep -q "#481 @${B:0:7} has had no verdict" "$T/log/alerts" && ok \
    || bad "$tag tick3 want exactly one stale-head alert: $(cat "$T/log/alerts" 2>/dev/null)"
}
fresh "$RC_STATE"; s6d S6d
fresh "$RC_STATE"; rm -f "$H/bin/lib/review-pool.sh"; s6d S6di

# ── S7: green CI first ──
fresh "$RC_STATE"; : > "$T/ci-pending"; run_rp s7
[ "$(calls)" = 0 ] && ok || bad "S7 bought before CI went green: $(cat "$T/log/sink")"
grep -q "#481 @${B:0:7} re-review deferred — CI not green" "$LOG" && ok || bad "S7 no deferred line: $(tail -3 "$LOG")"

echo "review-prs-stale-cr.bh-5396: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
