#!/bin/bash
# tests/lead-review-lane.bh-2202-test.sh — BH-2202: a lead review is paid for
# once. When the result post fails after a verdict, the watchdog retry replays
# the report already on disk (state/lead-reviews/<key>.md) and makes no agent
# call; when the answer was billed but had no verdict, a <key>.empty marker
# makes the retry terminal with no call. rc 74..79 (nothing billed) writes no
# marker, so the next tick may call. bin/lead-review.sh tick is run WHOLE
# against the same scratch harness as tests/lead-review-lane.bh-1950-test.sh
# (real jobs/lead-reviews/model-route/verdict-parse/gh-rest clients; curl, gh
# and bin/agent-call.sh stubbed; real git).
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-review-lane.bh-2202-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# BH-4956: these cases review one PR more than the per-PR-day tripwire allows
# (LEAD_REVIEW_MAX_PER_PR_DAY, default 4, state/lead-review/started.tsv).
export LEAD_REVIEW_MAX_PER_PR_DAY=50
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"; mkdir -p "$H/bin/lib/jobs" "$H/prompts" "$H/catalog/lanes.d" "$H/state" "$T/fakebin" "$T/log" "$T/repos" "$T/tmp"
cp "$DIR/bin/jobs-client.sh" "$DIR/bin/box-for.sh" "$DIR/bin/fleet-conf.sh" "$H/bin/"
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
for f in env-path lead-reviews verdicts model-route verdict-parse gh-rest hub-box lane-gate review-pool lead-worklist; do
  cp "$DIR/bin/lib/$f.sh" "$H/bin/lib/"
done
cp "$DIR/catalog/lanes.d/_lib.json" "$H/catalog/lanes.d/"
[ -f "$DIR/prompts/lead-review.md" ] && cp "$DIR/prompts/lead-review.md" "$H/prompts/"
[ -f "$DIR/prompts/lead-review-checklist.md" ] && cp "$DIR/prompts/lead-review-checklist.md" "$H/prompts/"
[ -f "$DIR/bin/lead-review.sh" ] && cp "$DIR/bin/lead-review.sh" "$H/bin/"
# TEST-CHANGE (BH-6293): bin/lead-review.sh loads its modules from bin/lib/lead-review/.
scratch_install_closure bin/lib/lead-review/load.sh "$H" >/dev/null || { echo "closure install of bin/lib/lead-review failed"; exit 1; }
# TEST-CHANGE (BH-7455): bin/lead-review.sh loads its optional libs from bin/lib/lead-review/libs.d/.
cp -R "$DIR/bin/lib/lead-review/libs.d" "$H/bin/lib/lead-review/"
echo box-demo > "$H/state/box-name"
cat > "$H/fleet.conf" <<'EOF'
# project repo prod board offset box
demo-os   example-org/demo-os   https://demo.test  /api/board 1 box-demo
bare-os   example-org/bare-os   https://bare.test  /api/board 2 box-demo
other-os  example-org/other-os  https://other.test /api/board 3 box-other
EOF

# ── the git fixtures: origin with main + a PR head at refs/pull/<pr>/head ──
# mk_repo <project> <pr> <claude-md-body> -> prints the PR head sha
mk_repo() {
  local p="$1" pr="$2" o="$T/origin/$1.git" w="$T/work/$1"
  git init -q --bare -b main "$o"; git init -q -b main "$w"
  printf '%s\n' "$3" > "$w/CLAUDE.md"; echo one > "$w/a.txt"
  git -C "$w" add -A; git -C "$w" -c user.email=t@t -c user.name=t commit -qm base
  git -C "$w" push -q "$o" main
  echo two >> "$w/a.txt"; git -C "$w" -c user.email=t@t -c user.name=t commit -qam "pr change"
  git -C "$w" push -q "$o" "HEAD:refs/pull/$pr/head"
  git clone -q "$o" "$T/repos/$p"
  git -C "$w" rev-parse HEAD
}
CONTRACT=$'# demo\n\n## Verification Contract\n\n```bash\n# the suite\nexit 3\n```\n'
SHA=$(mk_repo demo-os 41 "$CONTRACT")
BSHA=$(mk_repo bare-os 7 $'# bare\n\nNo contract here.\n')
SHA12=${SHA:0:12}

# ── the stub worker ──
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
m=GET; body=""; url=""; prev=""
for a in "\$@"; do
  case "\$prev" in -X) m="\$a" ;; --data-binary) body="\$a" ;; esac
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
case "\$body" in @*) body=\$(cat "\${body#@}") ;; esac
p="\${url#https://jobs.test}"
printf '%s %s %s\n' "\$m" "\$p" "\$body" >> "$T/log/worker"
code=200; out='{}'
case "\$m \$p" in
  "GET /api/lead-reviews"*)
    if [ -e "$T/lr404" ]; then code=404; out='{"error":"unknown endpoint","worker":"harness-jobs"}'
    else out=\$(cat "$T/requests.json"); fi ;;
  "POST /api/jobs")
    st=\$(cat "$T/jobstate" 2>/dev/null)
    if [ "\$st" = running ]; then code=409; out='{"job":{"id":"job-7","box":"box-other"}}'
    else echo running > "$T/jobstate"; out='{"job":{"id":"job-7"}}'; fi ;;
  "PATCH /api/jobs/"*)
    s=\$(printf '%s' "\$body" | jq -r '.status // empty'); [ -n "\$s" ] && echo "\$s" > "$T/jobstate" ;;
  "POST /api/lead-reviews/"*/claim) [ -e "$T/claim409" ] && { code=409; out='{"error":"claimed"}'; } ;;
  "POST /api/lead-reviews/"*/result) [ -e "$T/result500" ] && { code=500; out='{"error":"boom"}'; } ;;
  "GET /api/model-routes/"*)
    if [ -e "$T/noroute" ]; then out='{"ladder":[],"source":"none"}'
    else out='{"ladder":[{"position":0,"model":"stub-model","runner":"claude"}],"source":"hub"}'; fi ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"-i -X GET repos/"*"/pulls/"*)
    [ -e "$T/ghfail" ] && exit 1
    printf 'HTTP/2 200\r\n\r\n'
    jq -nc --arg s "\$(cat "$T/livehead")" '{head:{sha:\$s},base:{ref:"main"},title:"Add the thing",body:"PR body text"}' ;;
esac
exit 0
EOF
cat > "$H/bin/agent-call.sh" <<EOF2
#!/bin/bash
echo x >> "$T/log/agent-count"; n=\$(wc -l < "$T/log/agent-count")
[ -e "$T/rc75" ] && exit 75
if [ -f "$T/answer.\$n" ]; then cp "$T/answer.\$n" "\$5"; else cp "$T/answer" "\$5"; fi
exit 0
EOF2
chmod +x "$T/fakebin/curl" "$T/fakebin/gh" "$H/bin/agent-call.sh"

export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
  JOBS_RETRIES=0 JOBS_BEAT_SECS=1 TMPDIR="$T/tmp" REPOS_ROOT="$T/repos" FLEET_CONF="$H/fleet.conf" \
  LANE_GATE_DISABLE=1 GH_ETAG=0
unset BOX_NAME JOBS_BOX LEAD_REVIEW_MAX_PER_TICK LEAD_REVIEW_DEADLINE_S VERDICT_WINDOW_LINES _VP_WINDOW

req() { # req <id> <repo> <pr> <sha> -> one request object
  jq -nc --arg i "$1" --arg r "$2" --argjson p "$3" --arg s "$4" \
    '{id:$i,repo:$r,pr:$p,head_sha:$s,scope_notes:"only the lane",prior_verdict_ref:"verdict-9",status:"requested"}'
}
setreqs() { printf '%s\n' "$@" | jq -sc '{requests:., truncated:false}' > "$T/requests.json"; }
reset() {
  rm -f "${T:?}/log"/* "${T:?}"/{lr404,jobstate,claim409,result500,noroute,ghfail,rc75,answer.*} "${H:?}/logs/lead-review.log"
  scratch_rm "$H/state/lead-reviews"; scratch_rm "$H/state/model-routes"; scratch_rm "$H/flags"
  echo box-demo > "$H/state/box-name"
  echo "$SHA" > "$T/livehead"
  setreqs "$(req lr-1 example-org/demo-os 41 "$SHA")"
  printf 'Findings\n- [BLOCK] a.txt:2 — it breaks\n\nVERDICT: BLOCK\n' > "$T/answer"
}
tick() { ( cd "$T" && bash "$H/bin/lead-review.sh" tick ) > "$T/out" 2>&1; RC=$?; }
agents() { [ -f "$T/log/agent-count" ] && wc -l < "$T/log/agent-count" | tr -d ' ' || echo 0; }
wlog() { cat "$T/log/worker" 2>/dev/null; }
has() { wlog | grep -qE "$1"; }
# retake: what bin/jobs-watchdog.sh does to an open job, then the next tick
retake() { rm -f "${T:?}/result500" "${T:?}/log/worker"; echo queued_for_retry > "$T/jobstate"; tick; }
REPORT="$H/state/lead-reviews/lr-41-$SHA12.md"
EMPTY="$H/state/lead-reviews/lr-41-$SHA12.empty"
seed_report() { # seed_report <sha in header> <verdict> <model>
  mkdir -p "$H/state/lead-reviews"
  printf '# Lead review lr-41-%s (example-org/demo-os#41 at %s)\n\n- verdict: %s\n- host suite: exit 3 rc=3\n- reviewer model: %s\n\nFindings\n- none\n\nVERDICT: %s\n' \
    "$SHA12" "$1" "$2" "$3" "$2" > "$REPORT"
}

# (R1) verdict on disk, result post failed -> the retake replays it, no call
reset; : > "$T/result500"; tick
[ -f "$REPORT" ] && ok || bad "R1 tick 1 wrote no report"
has '/result .*"outcome":"done"' && ok || bad "R1 tick 1 did not try the done post"
[ "$(cat "$T/jobstate")" = done ] && bad "R1 tick 1 stamped done without a delivered result" || ok
[ "$(agents)" = 1 ] && ok || bad "R1 tick 1 agent calls $(agents) (want 1)"
retake
[ "$RC" -eq 0 ] && ok || bad "R1 retake rc=$RC out=$(cat "$T/out")"
[ "$(agents)" = 1 ] && ok || bad "R1 the retake paid for another call: agents=$(agents) (want 1)"
has "/result .*\"outcome\":\"done\",\"verdict\":\"BLOCK\",\"report_ref\":\"$REPORT\",\"reviewer_model\":\"stub-model\"" \
  && ok || bad "R1 the retake's result post: $(wlog | grep /result)"
order=$(wlog | awk '
  /^PUT \/api\/jobs\/job-7\/artifacts .*"artifact_kind":"lead_review_report"/ {print "artifact"}
  /^POST \/api\/lead-reviews\/lr-1\/result .*"outcome":"done"/ {print "result"}
  /^PATCH \/api\/jobs\/job-7 .*"status":"done"/ {print "done"}' | paste -sd' ')
[ "$order" = "artifact result done" ] && ok || bad "R1 retake order '$order' (want artifact result done)"
[ "$(cat "$T/jobstate")" = done ] && ok || bad "R1 job not done after the retake: $(cat "$T/jobstate")"
grep -q "reusing $REPORT for lr-41-$SHA12; no agent call" "$H/logs/lead-review.log" && ok || bad "R1 no reuse log line: $(cat "$H/logs/lead-review.log")"

# (R1b) a report for the key whose header names another sha is never reused
reset; seed_report "$(printf '0%.0s' {1..40})" MERGE old-model; tick
[ "$(agents)" = 1 ] && ok || bad "R1b agents=$(agents) (want 1: a mismatched report must not be reused)"
head -1 "$REPORT" | grep -qF "(example-org/demo-os#41 at $SHA)" && ok || bad "R1b report header not rewritten: $(head -1 "$REPORT")"
has '/result .*"verdict":"BLOCK"' && ok || bad "R1b posted the stale verdict: $(wlog | grep /result)"

# (R2) billed, no verdict, post failed -> the retake is terminal, no call
reset; : > "$T/answer"; : > "$T/result500"; tick
[ "$(agents)" = 2 ] && ok || bad "R2 tick 1 agents=$(agents) (want 2: one format retry)"
[ -f "$EMPTY" ] && ok || bad "R2 no .empty marker after a billed empty answer"
retake
[ "$(agents)" = 2 ] && ok || bad "R2 the retake paid again: agents=$(agents) (want 2)"
has '/result .*"outcome":"failed".*"detail":"empty"' && ok || bad "R2 retake result: $(wlog | grep /result)"
has '/result .*"reviewer_model":"stub-model"' && ok || bad "R2 retake result carries no model from the marker"
[ "$(cat "$T/jobstate")" = failed ] && ok || bad "R2 job not failed: $(cat "$T/jobstate")"
grep -q "billed with no verdict earlier for lr-41-$SHA12; no agent call" "$H/logs/lead-review.log" && ok || bad "R2 no marker log line"
grep -qx 'reset=0' "$EMPTY" && ok || bad "R2 the marker does not name the reset it was written on: $(cat "$EMPTY")"

# (R2b) BH-5793 lead BLOCK lr-5809-b2360d16170d: lead-review-land requeued the
# empty request (POST /reset, reset_count 1). The marker belongs to reset 0, so
# the requeue gets a real review, not a replay of the old empty.
setreqs "$(req lr-1 example-org/demo-os 41 "$SHA" | jq -c '.reset_count=1')"
printf 'Findings\n- none\n\nVERDICT: MERGE\n' > "$T/answer"
retake
[ "$(agents)" = 3 ] && ok || bad "R2b the requeued request was not reviewed again: agents=$(agents) (want 3)"
has '/result .*"outcome":"done","verdict":"MERGE"' && ok || bad "R2b result after the requeue: $(wlog | grep /result)"
[ -e "$EMPTY" ] && bad "R2b the reset-0 marker is still on disk after the real review" || ok
grep -q "empty marker for lr-41-$SHA12 is from reset 0; the request is at reset 1" "$H/logs/lead-review.log" \
  && ok || bad "R2b no log line for the stale marker: $(cat "$H/logs/lead-review.log")"

# (R3) rc 75 = nothing billed: no marker, no report, the next tick calls
reset; : > "$T/rc75"; tick
[ -e "$EMPTY" ] && bad "R3 an unbilled refusal wrote a .empty marker" || ok
[ -e "$REPORT" ] && bad "R3 an unbilled refusal wrote a report" || ok
[ "$(cat "$T/jobstate")" = failed ] && ok || bad "R3 job not failed: $(cat "$T/jobstate")"
[ "$(agents)" = 1 ] && ok || bad "R3 tick 1 agents=$(agents)"
rm -f "${T:?}/rc75"; tick
[ "$(agents)" = 2 ] && ok || bad "R3 the next tick did not call: agents=$(agents) (want 2)"
has '/result .*"outcome":"done","verdict":"BLOCK"' && ok || bad "R3 next tick did not finish"

# (R4) a report on disk and a moved live head: superseded, no call
reset; seed_report "$SHA" MERGE old-model; echo "$(printf 'b%.0s' {1..40})" > "$T/livehead"; tick
has '/result .*"outcome":"superseded"' && ok || bad "R4 no superseded: $(wlog | grep /result)"
has '"outcome":"done"' && bad "R4 posted the old verdict on a moved head" || ok
[ "$(agents)" = 0 ] && ok || bad "R4 agents=$(agents)"

# (R5) a report on disk and a refused claim: no result, no call, job failed
reset; seed_report "$SHA" MERGE old-model; : > "$T/claim409"; tick
has '/result' && bad "R5 a result was posted without a claim" || ok
[ "$(agents)" = 0 ] && ok || bad "R5 agents=$(agents)"
[ "$(cat "$T/jobstate")" = failed ] && ok || bad "R5 job not failed: $(cat "$T/jobstate")"

# (R6) a seeded matching report is posted with ITS verdict and model
reset; seed_report "$SHA" MERGE-WITH-NOTES old-model; tick
[ "$(agents)" = 0 ] && ok || bad "R6 agents=$(agents) (want 0)"
has '/result .*"outcome":"done","verdict":"MERGE-WITH-NOTES".*"reviewer_model":"old-model"' && ok || bad "R6 result: $(wlog | grep /result)"
has '/claim' && ok || bad "R6 the reuse skipped the claim"

# (R7) BH-5793 lead BLOCK lr-5809-1a62fbb06f34: a report or marker on disk is
# replayed only when it was written at or after the request's latest start
# (reset_at, else created_at). A report from an earlier request on the same head
# (the conductor's new request, the env sweep's reset) gets a real review.
OLD=202610070000; REQ_AT=2026-10-09T00:00:00Z
# R7a: an old BLOCK report, a NEW request on the same head -> a real review
reset; seed_report "$SHA" BLOCK old-model; touch -t "$OLD" "$REPORT"
setreqs "$(req lr-2 example-org/demo-os 41 "$SHA" | jq -c --arg c "$REQ_AT" '.created_at=$c')"
printf 'Findings\n- none\n\nVERDICT: MERGE\n' > "$T/answer"; tick
[ "$(agents)" = 1 ] && ok || bad "R7a an old report was replayed for a new request: agents=$(agents) (want 1)"
has '/result .*"outcome":"done","verdict":"MERGE"' && ok || bad "R7a result: $(wlog | grep /result)"
grep -q "report for lr-41-$SHA12 predates request lr-2" "$H/logs/lead-review.log" && ok || bad "R7a no log line: $(cat "$H/logs/lead-review.log")"
# R7b: the env sweep reset the request (reset_at after the report) -> a real review
reset; seed_report "$SHA" BLOCK old-model; touch -t "$OLD" "$REPORT"
setreqs "$(req lr-1 example-org/demo-os 41 "$SHA" | jq -c --arg c 2026-10-06T00:00:00Z --arg r "$REQ_AT" '.created_at=$c | .reset_at=$r | .reset_count=1')"
printf 'Findings\n- none\n\nVERDICT: MERGE\n' > "$T/answer"; tick
[ "$(agents)" = 1 ] && ok || bad "R7b a reset request replayed the old report: agents=$(agents)"
# R7c: a report written after the request started (a retake of the same claim) -> replayed, no call
reset; seed_report "$SHA" MERGE-WITH-NOTES old-model
setreqs "$(req lr-1 example-org/demo-os 41 "$SHA" | jq -c --arg c 2026-10-06T00:00:00Z '.created_at=$c')"
tick
[ "$(agents)" = 0 ] && has '"verdict":"MERGE-WITH-NOTES"' && ok || bad "R7c a fresh report was not replayed: agents=$(agents)"
# R7d: an old .empty marker, a NEW request -> a real review
reset; mkdir -p "$H/state/lead-reviews"; printf 'stub-model\nreset=0\n' > "$EMPTY"; touch -t "$OLD" "$EMPTY"
setreqs "$(req lr-3 example-org/demo-os 41 "$SHA" | jq -c --arg c "$REQ_AT" '.created_at=$c')"
printf 'Findings\n- none\n\nVERDICT: MERGE\n' > "$T/answer"; tick
[ "$(agents)" = 1 ] && ok || bad "R7d an old empty marker was replayed for a new request: agents=$(agents)"

echo "lead-review-lane.bh-2202: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
