#!/bin/bash
# tests/lead-review-lane.bh-1950-test.sh — BH-1950 (BH-1525.2): the lead review
# job lane, bin/lead-review.sh tick, run WHOLE against a scratch harness that
# carries the real jobs client, lead-reviews client, model-route, verdict-parse,
# gh-rest, hub-box, box-for and fleet-conf, with only these stubbed:
#   * curl  — the jobs worker: lead-review list/claim/result, job rows (a row
#             that is `running` answers 409 IN_FLIGHT, one that is absent or
#             `queued_for_retry` answers the same job id), artifacts, model routes;
#   * gh    — the REST PR read (`gh api -i`), head sha from $T/livehead;
#   * bin/agent-call.sh — counts calls, keeps each prompt, writes $T/answer.
# The PR repos are real git: a bare origin with refs/pull/<n>/head.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-review-lane.bh-1950-test.sh
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
cat > "$H/bin/agent-call.sh" <<EOF
#!/bin/bash
echo x >> "$T/log/agent-count"; n=\$(wc -l < "$T/log/agent-count")
case "\$6" in @/*) cat "\${6#@}" ;; *) printf '%s' "\$6" ;; esac > "$T/log/prompt.\$n"
printf '%s %s %s\n' "\${AGENT_CALL_ROLE:-}" "\$1" "\$3" >> "$T/log/agent-argv"
# BH-5284: the review runs in a worker subshell of the tick, so "the tick is
# killed mid-review" is the worker (PPID) and the tick (its parent), both -9.
[ -e "$T/killme" ] && { tk=\$(ps -o ppid= -p \$PPID | tr -d ' '); kill -9 \$PPID \$tk; }
if [ -f "$T/answer.\$n" ]; then cp "$T/answer.\$n" "\$5"; else cp "$T/answer" "\$5"; fi
exit 0
EOF
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
  rm -f "$T/log"/* "$T"/{lr404,jobstate,claim409,result500,noroute,ghfail,killme,answer.*} "$H/logs/lead-review.log"
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
REPORT="$H/state/lead-reviews/lr-41-$SHA12.md"


# (a) BLOCK answer: report, artifact, result done, job done — in that order
reset; tick
[ "$RC" -eq 0 ] && ok || bad "a rc=$RC out=$(cat "$T/out")"
grep -q '^VERDICT: BLOCK' "$REPORT" 2>/dev/null && ok || bad "a report has no VERDICT: BLOCK"
grep -q 'host suite: exit 3 rc=3' "$REPORT" 2>/dev/null && ok || bad "a report lacks the suite's true rc=3: $(grep 'host suite' "$REPORT" 2>/dev/null)"
order=$(wlog | awk '
  /^POST \/api\/lead-reviews\/lr-1\/claim .*"job_id":"job-7"/ {print "claim"}
  /^PUT \/api\/jobs\/job-7\/artifacts .*"artifact_kind":"lead_review_report"/ {print "artifact"}
  /^POST \/api\/lead-reviews\/lr-1\/result .*"outcome":"done"/ && /"verdict":"BLOCK"/ {print "result"}
  /^PATCH \/api\/jobs\/job-7 .*"status":"done"/ {print "done"}' | paste -sd' ')
[ "$order" = "claim artifact result done" ] && ok || bad "a worker order '$order' (want claim artifact result done); log: $(wlog)"
has "artifacts .*\"artifact_ref\":\"$REPORT\"" && ok || bad "a artifact ref is not the report path"
has "/result .*\"reviewer_model\":\"stub-model\"" && ok || bad "a result carries no reviewer_model from the route"
has "^POST /api/jobs .*\"ticket_id\":\"lr-41-$SHA12\".*\"lane\":\"lead-review\"" && ok || bad "a job_open key/lane wrong: $(wlog | grep '^POST /api/jobs ')"
grep -q '^lead.review lead-review stub-model$' "$T/log/agent-argv" 2>/dev/null && ok || bad "a agent-call argv/role: $(cat "$T/log/agent-argv" 2>/dev/null)"
ls -d "$H"/tmp/lead-review-* >/dev/null 2>&1 && bad "a scratch worktree left behind" || ok
[ "$(git -C "$T/repos/demo-os" worktree list | wc -l)" -eq 1 ] && ok || bad "a git still lists the worktree"
grep -q 'seen=1 owned=1 done=1' "$H/logs/lead-review.log" && ok || bad "a summary line: $(tail -1 "$H/logs/lead-review.log" 2>/dev/null)"

# (g) the prompt: begins with the prompt file's exact bytes, carries the sections
n=$(wc -c < "$H/prompts/lead-review.md")
cmp -s -n "$n" "$H/prompts/lead-review.md" "$T/log/prompt.1" && ok || bad "g prompt does not start with prompts/lead-review.md"
for s in '## PR' '## Scope notes' '## Prior verdict' '## Host suite' '## Diff'; do
  grep -qx "$s" "$T/log/prompt.1" && ok || bad "g prompt lacks section '$s'"
done
grep -q 'only the lane' "$T/log/prompt.1" && grep -q 'verdict-9' "$T/log/prompt.1" && grep -q 'PR body text' "$T/log/prompt.1" \
  && ok || bad "g scope notes / prior verdict / PR body not in the prompt"
grep -q '^+two' "$T/log/prompt.1" && ok || bad "g the diff is not in the prompt"
grep -q 'rc=3' "$T/log/prompt.1" && ok || bad "g the suite rc is not in the prompt"

# (b) live head moved: superseded, no model call, job done
reset; echo "$(printf 'b%.0s' {1..40})" > "$T/livehead"; tick
[ "$RC" -eq 0 ] && ok || bad "b rc=$RC"
has '/result .*"outcome":"superseded"' && ok || bad "b no superseded result: $(wlog)"
[ "$(agents)" = 0 ] && ok || bad "b the agent was called $(agents) time(s)"
has '^PATCH /api/jobs/job-7 .*"status":"done"' && ok || bad "b job not closed done"

# (b2) the live head is unreadable: no superseded, no model call, job failed
reset; : > "$T/ghfail"; tick
has 'superseded' && bad "b2 posted superseded on an unknown head" || ok
has '/result' && bad "b2 posted a result on an unknown head" || ok
[ "$(agents)" = 0 ] && ok || bad "b2 agent called"
has '^PATCH /api/jobs/job-7 .*"status":"failed"' && ok || bad "b2 job not failed"

# (c) killed mid-run -> watchdog requeues -> the next tick re-takes the same job id
reset; : > "$T/killme"; tick
[ "$RC" -ne 0 ] && ok || bad "c the first tick was not killed (rc=$RC)"
has '/result' && bad "c a result was posted by the killed tick" || ok
[ "$(cat "$T/jobstate")" = running ] && ok || bad "c job state after kill: $(cat "$T/jobstate")"
# a concurrent tick while the row is still running skips it (the dedupe)
rm -f "$T/killme"; tick
has 'claim .*' && [ "$(wlog | grep -c '/claim')" = 1 ] && ok || bad "c a tick re-claimed a running row"
echo queued_for_retry > "$T/jobstate"   # what bin/jobs-watchdog.sh does to it
tick
[ "$RC" -eq 0 ] && ok || bad "c retake rc=$RC out=$(cat "$T/out")"
[ "$(wlog | grep -c '^POST /api/lead-reviews/lr-1/claim .*"job_id":"job-7"')" = 2 ] && ok || bad "c the same job id was not claimed twice: $(wlog | grep claim)"
has '/result .*"outcome":"done".*"verdict":"BLOCK"' && ok || bad "c the retake did not finish"
[ "$(cat "$T/jobstate")" = "done" ] && ok || bad "c job not done after retake"

# (d) no model route: no job, no claim, no call, the request stays requested
reset; : > "$T/noroute"; tick
[ "$RC" -eq 0 ] && ok || bad "d rc=$RC"
has '^POST /api/jobs' && bad "d a job was opened" || ok
has '/claim' && bad "d the request was claimed" || ok
[ "$(agents)" = 0 ] && ok || bad "d agent called"
grep -q 'no model route for lead.review' "$H/logs/lead-review.log" && ok || bad "d no log line"

# (e) the hub: rc 0, one line, never asks for the list
reset; echo box-hub > "$H/state/box-name"; tick
[ "$RC" -eq 0 ] && ok || bad "e rc=$RC"
has 'lead-reviews' && bad "e the hub read the request list" || ok
[ "$(agents)" = 0 ] && ok || bad "e agent called on the hub"
[ "$(grep -c 'hub runs no agent work' "$H/logs/lead-review.log" 2>/dev/null)" = 1 ] && ok || bad "e hub log line: $(cat "$H/logs/lead-review.log" 2>/dev/null)"

# (f) another box holds the job: rc 0, skip, never claims
reset; echo running > "$T/jobstate"; tick
[ "$RC" -eq 0 ] && ok || bad "f rc=$RC"
has '/claim' && bad "f claimed a job another box holds" || ok
[ "$(agents)" = 0 ] && ok || bad "f agent called"
grep -q "skip lr-41-$SHA12: IN_FLIGHT" "$H/logs/lead-review.log" && ok || bad "f no skip line: $(cat "$H/logs/lead-review.log")"

# (h) the routes are not deployed: rc 0, no job
reset; : > "$T/lr404"; tick
[ "$RC" -eq 0 ] && ok || bad "h rc=$RC"
has '^POST /api/jobs' && bad "h opened a job" || ok
grep -q 'lead-review routes not deployed' "$H/logs/lead-review.log" && ok || bad "h no log line"

# (i) a repo this box does not own, and one no fleet.conf row names: skipped
reset; setreqs "$(req lr-2 example-org/other-os 5 "$SHA")" "$(req lr-3 example-org/nobody 6 "$SHA")"; tick
[ "$RC" -eq 0 ] && ok || bad "i rc=$RC"
has '^POST /api/jobs' && bad "i opened a job for a foreign repo" || ok
grep -q 'seen=2 owned=0' "$H/logs/lead-review.log" && ok || bad "i summary: $(tail -1 "$H/logs/lead-review.log")"

# (j) two owned requests: both start in one tick (BH-4956 removed the per-tick
# start cap, so a leftover LEAD_REVIEW_MAX_PER_TICK=1 changes nothing)
reset; setreqs "$(req lr-1 example-org/demo-os 41 "$SHA")" "$(req lr-4 example-org/bare-os 7 "$BSHA")"
LEAD_REVIEW_MAX_PER_TICK=1 tick
[ "$(wlog | grep -c '^POST /api/jobs ')" = 2 ] && ok || bad "j job_open count $(wlog | grep -c '^POST /api/jobs ') (want 2: no start cap)"

# (k) no contract: the report says so and never rc=0
reset; echo "$BSHA" > "$T/livehead"; setreqs "$(req lr-4 example-org/bare-os 7 "$BSHA")"; tick
R="$H/state/lead-reviews/lr-7-${BSHA:0:12}.md"
grep -q 'host suite: no host suite declared' "$R" 2>/dev/null && ok || bad "k report: $(grep 'host suite' "$R" 2>/dev/null)"
grep -q 'rc=0' "$R" 2>/dev/null && bad "k report claims rc=0" || ok
grep -q 'no host suite declared' "$T/log/prompt.1" && ok || bad "k prompt does not say no host suite"

# (l) empty answer: one retry, then failed detail=empty, job failed
reset; : > "$T/answer"; tick
[ "$(agents)" = 2 ] && ok || bad "l agent called $(agents) time(s) (want 2)"
has '/result .*"outcome":"failed".*"detail":"empty"' && ok || bad "l no failed/empty result: $(wlog | grep result)"
has '^PATCH /api/jobs/job-7 .*"status":"failed"' && ok || bad "l job not failed"
# (l2) the retry answers: one retry, then done
# TEST-CHANGE (BH-6090): the retry answer carries a Findings block. A bare
# `VERDICT: MERGE` is now unreadable by design (lr_has_findings: a verdict with
# no findings is a postscript, failed detail=empty), so the old fixture no
# longer describes a readable review. What l2 pins (the retry's answer is used)
# is unchanged.
reset; : > "$T/answer.1"; printf 'Findings\n- none\n\nVERDICT: MERGE\n' > "$T/answer.2"; tick
[ "$(agents)" = 2 ] && has '"verdict":"MERGE"' && ok || bad "l2 retry answer not used"
# (l3) an echoed template line is no verdict: one retry, then failed, never MERGE
reset; printf 'Findings\n- none\n\nVERDICT: MERGE|MERGE-WITH-NOTES|BLOCK\n' > "$T/answer"; tick
[ "$(agents)" = 2 ] && ok || bad "l3 agent called $(agents) time(s) (want 2)"
has '"verdict":"MERGE"' && bad "l3 echoed template posted as MERGE" || ok
has '/result .*"outcome":"failed".*"detail":"empty"' && ok || bad "l3 no failed/empty result"

# (m) a result post that fails leaves the job open (never stamped done)
reset; : > "$T/result500"; tick
has '^PATCH /api/jobs/job-7 .*"status":"done"' && bad "m job stamped done without a result" || ok
# (n) a refused claim: job failed, no call
reset; : > "$T/claim409"; tick
[ "$(agents)" = 0 ] && ok || bad "n agent called after a refused claim"
has '^PATCH /api/jobs/job-7 .*"status":"failed"' && ok || bad "n job not failed on refused claim"

# ── the verdict gate: negatives parse as no verdict ──
. "$DIR/bin/lib/verdict-parse.sh"
sed -n '/^lr_verdict() {/,/^}/p' "$DIR/bin/lead-review.sh" > "$T/lv.sh"
[ -s "$T/lv.sh" ] && ok || bad "could not extract lr_verdict from bin/lead-review.sh"
. "$T/lv.sh"
vp() { printf '%s' "$1" > "$T/v"; lr_verdict "$T/v"; }
for neg in $'Findings\n- none\n\nI would BLOCK this.' \
           $'```\nVERDICT: MERGE\n```\n\nNothing else to say.' \
           $'VERDICT: APPROVE' '' $'verdict: merge' \
           $'Findings\n- none\n\nVERDICT: MERGE|MERGE-WITH-NOTES|BLOCK' \
           $'Findings\n- none\n\nVERDICT: MERGE.'; do
  [ "$(vp "$neg")" = unknown ] && ok || bad "parser read a verdict from: $neg"
done
[ "$(vp $'x\n\nVERDICT: MERGE-WITH-NOTES')" = MERGE-WITH-NOTES ] && ok || bad "parser MERGE-WITH-NOTES"
[ "$(vp $'x\n\n**VERDICT:** BLOCK')" = BLOCK ] && ok || bad "parser bold BLOCK"
[ "$(vp $'x\n\nVERDICT: MERGE  \r\n\n')" = MERGE ] && ok || bad "parser MERGE with trailing blanks / CRLF"

# ── verify-cmd parity with bin/batch-resolve.sh (A3) ──
F="$T/fx"; mkdir -p "$F"
printf '## Verification Contract\n\n```bash\nnpm run check\n```\n' > "$F/1.md"
printf '# x\n### Verification contract\n\n```\n# comment\n  make test  \n```\n' > "$F/2.md"
printf '## Verification Contract\ntext\n```sh\nbash t.sh && echo ok\nsecond\n```\n## Next\n```\nno\n```\n' > "$F/3.md"
sed -n '/^verify_cmd() {/,/^}/p' "$DIR/bin/batch-resolve.sh" > "$T/br.sh"
sed -n '/^lr_verify_cmd() {/,/^}/p' "$DIR/bin/lead-review.sh" > "$T/lr.sh"
[ -s "$T/br.sh" ] && [ -s "$T/lr.sh" ] && ok || bad "parity: could not extract both readers"
for i in 1 2 3; do
  a=$( show_base() { cat "$F/$i.md"; }; . "$T/br.sh"; verify_cmd )
  b=$( . "$T/lr.sh"; lr_verify_cmd "$F/$i.md" )
  [ -n "$b" ] && [ "$a" = "$b" ] && ok || bad "parity fixture $i: batch-resolve '$a' vs lead-review '$b'"
done
printf '# none\n' > "$F/4.md"
b=$( . "$T/lr.sh"; lr_verify_cmd "$F/4.md" ); rc=$?
[ "$rc" -eq 1 ] && [ -z "$b" ] && ok || bad "no contract must be rc 1 and empty (got rc=$rc '$b')"

echo "lead-review-lane: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
