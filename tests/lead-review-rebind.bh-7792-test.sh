#!/bin/bash
# tests/lead-review-rebind.bh-7792-test.sh — BH-7792: a finished paid lead
# review is never lost to a rebind. bin/lead-review.sh tick runs WHOLE against a
# scratch harness (tests/lib/lead-worklist-fixture.bh-4956.sh).
#   R1  a second tick on the SAME box while the first review is in its paid
#       call: job_open hands it the running worker's own job (a same-box
#       resume), it loses the per-key lock, and it leaves that job OPEN (the
#       old path closed it, so /start read the request's job as not live and a
#       second box rebound the request). The first review then posts its done
#       result under its own job, with 1 agent call in total.
#   R2  an agent call refused by the call-guard (rc 74, nothing billed) gives
#       its claim back: POST /api/lead-reviews/<id>/release with its job id,
#       one `claim released` line, no result post, and the job failed.
#   R3  (#7792 comment 6309315490) a request whose head already has paid 1/1 on
#       its lead-head guard key: a read-only GET /api/call-guard with that same
#       key (the key R3b's agent call carries), then the claim is released, with
#       no worktree, no rules pack, no host suite, no agent call and no result.
#       R3b: with no paid row the review runs as before (1 agent call).
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-review-rebind.bh-7792-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lead-worklist-fixture.bh-4956.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }
lwf_setup
export LEAD_REVIEW_CONCURRENCY=4
S12=${SHA:0:12}; KEY="lr-101-$S12"; JOB="job-$KEY"

# ── R1: a same-box second dispatcher never closes the running review's job ──
lwf_reset
lwf_rows requested 101
: > "$FX/block"
lwf_tick_bg; P1=$TICK_PID
lwf_wait 60 grep -q . "$T/log/agent-prs" || bad "R1 tick 1 never reached its agent call: $(cat "$L" 2>/dev/null)"
: > "$FX/jobs.resume"
( cd "$T" && HARNESS="$H" FLEET_CONF="$H/fleet.conf" bash "$H/bin/lead-review.sh" tick ) > "$T/out2" 2>&1
grep -q "skip $KEY: another worker holds locks/lead-review-$KEY.lock" "$L" && ok || bad "R1 tick 2 did not lose the key lock: $(cat "$L")"
grep -q "skip $KEY: job $JOB is the lock holder's; left open" "$L" && ok || bad "R1 no left-open line: $(grep "$KEY" "$L")"
grep -q "^PATCH /api/jobs/$JOB .*key held" "$T/log/worker" && bad "R1 tick 2 closed the running review's job: $(grep "^PATCH /api/jobs/$JOB" "$T/log/worker")" || ok
[ -d "$T/jobs/$KEY" ] && ok || bad "R1 the running review's job is not open while its paid call runs"
: > "$FX/release.all"
wait "$P1" 2>/dev/null
[ "$(lwf_agents)" = 1 ] && ok || bad "R1 agent calls=$(lwf_agents) (want 1)"
grep -q "^POST /api/lead-reviews/r-101/result .*\"job_id\":\"$JOB\".*\"outcome\":\"done\"" "$T/log/worker" && ok \
  || bad "R1 the first review's result was not posted under its own job: $(grep result "$T/log/worker")"
grep -q "done $KEY: VERDICT MERGE" "$L" && ok || bad "R1 no done line: $(grep "$KEY" "$L")"

# ── R2: a call-guard refusal releases the claim ──
lwf_reset
lwf_rows requested 101
echo 74 > "$FX/agentrc.101"
lwf_tick
grep -q "agent-call refused $KEY (rc=74, nothing billed)" "$L" && ok || bad "R2 no refusal line: $(cat "$L")"
grep -q "^POST /api/lead-reviews/r-101/release .*\"job_id\":\"$JOB\"" "$T/log/worker" && ok \
  || bad "R2 the refused run did not release its claim: $(grep r-101 "$T/log/worker")"
grep -q "$KEY: claim released (request r-101 back to requested)" "$L" && ok || bad "R2 no claim-released line: $(grep "$KEY" "$L")"
grep -q "^POST /api/lead-reviews/r-101/result " "$T/log/worker" && bad "R2 a refused run posted a result" || ok
grep -q "^PATCH /api/jobs/$JOB .*\"status\":\"failed\"" "$T/log/worker" && ok || bad "R2 the refused run's job was not failed"
[ "$(lwf_cnt "^POST /api/lead-reviews/r-101/release " "$T/log/worker")" = 1 ] && ok || bad "R2 release posts=$(lwf_cnt "^POST /api/lead-reviews/r-101/release " "$T/log/worker") (want 1)"

# ── R3: a spent lead-head guard key is seen before the rules pack ──
enc() { jq -rn --arg v "$1" '$v|@uri'; }
lwf_reset
lwf_rows requested 101
lwf_tick
FP=$(awk '$1 == "lead-head" {print $2; exit}' "$T/log/agent-fps" 2>/dev/null)
[ "$(lwf_agents)" = 1 ] && [ -n "$FP" ] && ok || bad "R3b no paid row: agent calls=$(lwf_agents) fp='$FP'"
grep -q "^GET /api/call-guard?.*stage=lead-head.*&fp=$(enc "$FP")" "$T/log/worker" && ok \
  || bad "R3b the peek did not read the agent call's guard key $FP: $(grep '/api/call-guard' "$T/log/worker")"
lwf_reset
lwf_rows requested 101
echo 1 > "$FX/callguard.paid"
lwf_tick
[ "$(lwf_agents)" = 0 ] && ok || bad "R3 agent calls=$(lwf_agents) (want 0)"
grep -q "$KEY: lead-head call-guard paid 1/1 on $FP; no rules pack, no host suite, no agent call" "$L" && ok \
  || bad "R3 no guard line: $(grep "$KEY" "$L")"
grep -q "$KEY: host suite\|$KEY: rules pack\|$KEY: full review\|$KEY: conflict hotspots" "$L" && bad "R3 the run went on past the guard: $(grep "$KEY" "$L")" || ok
grep -q "^POST /api/lead-reviews/r-101/release .*\"job_id\":\"$JOB\".*call-guard: lead-head paid 1/1" "$T/log/worker" && ok \
  || bad "R3 the claim was not released: $(grep r-101 "$T/log/worker")"
grep -q "$KEY: claim released (request r-101 back to requested)" "$L" && ok || bad "R3 no claim-released line"
grep -q "^POST /api/lead-reviews/r-101/result " "$T/log/worker" && bad "R3 a result was posted" || ok
grep -q "^POST /api/call-guard/claim" "$T/log/worker" && bad "R3 the peek claimed a guard slot" || ok

echo "lead-review-rebind.bh-7792: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
