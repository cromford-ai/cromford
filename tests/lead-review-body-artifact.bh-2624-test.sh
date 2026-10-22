#!/bin/bash
# tests/lead-review-body-artifact.bh-2624-test.sh — BH-2624 (BH-2532.2): the lead
# review BODY rides in the lead_review_report artifact's detail, so a retry that
# lands where the disk report is gone still makes no agent call. The detail is
# {body,path,verdict[,truncated]} capped at the worker's 4000 UTF-16 units and
# still valid JSON; a billed answer with no verdict is also an artifact,
# {empty:true,path,model}. The replay reads the artifact first and the disk
# report second (on rc 1, rc 3, a truncated body or a header naming another
# sha). bin/lead-review.sh tick is run WHOLE against the scratch harness of
# tests/lead-review-lane.bh-2202-test.sh; the stub worker here also keeps the
# artifacts it is sent, like the real one.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-review-body-artifact.bh-2624-test.sh
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
EOF

mk_repo() { # mk_repo <project> <pr> <claude-md-body> -> prints the PR head sha
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
SHA=$(mk_repo demo-os 41 $'# demo\n\n## Verification Contract\n\n```bash\nexit 3\n```\n')
SHA12=${SHA:0:12}
OTHER=$(printf '0%.0s' {1..40})

# ── the stub worker: an artifact PUT is kept (upserted by kind) in artifacts.json
# and served back by GET /api/jobs/job-7/artifacts; art500 makes that GET a 500 ──
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
  "GET /api/lead-reviews"*) out=\$(cat "$T/requests.json") ;;
  "POST /api/jobs")
    st=\$(cat "$T/jobstate" 2>/dev/null)
    if [ "\$st" = running ]; then code=409; out='{"job":{"id":"job-7","box":"box-other"}}'
    else echo running > "$T/jobstate"; out='{"job":{"id":"job-7"}}'; fi ;;
  "GET /api/jobs/job-7/artifacts")
    if [ -e "$T/art500" ]; then code=500; out='{"error":"boom"}'
    else out=\$(cat "$T/artifacts.json" 2>/dev/null || echo '{"artifacts":[]}'); fi ;;
  "PUT /api/jobs/job-7/artifacts")
    printf '%s' "\$body" > "$T/artifact.put"
    cur=\$(cat "$T/artifacts.json" 2>/dev/null || echo '{"artifacts":[]}')
    jq -c --argjson b "\$body" '.artifacts |= ([.[] | select(.artifact_kind != \$b.artifact_kind)] + [\$b])' <<<"\$cur" > "$T/artifacts.json.n" \
      && mv "$T/artifacts.json.n" "$T/artifacts.json" ;;
  "PATCH /api/jobs/"*)
    s=\$(printf '%s' "\$body" | jq -r '.status // empty'); [ -n "\$s" ] && echo "\$s" > "$T/jobstate" ;;
  "POST /api/lead-reviews/"*/result) [ -e "$T/result500" ] && { code=500; out='{"error":"boom"}'; } ;;
  "GET /api/model-routes/"*) out='{"ladder":[{"position":0,"model":"stub-model","runner":"claude"}],"source":"hub"}' ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"-i -X GET repos/"*"/pulls/"*)
    printf 'HTTP/2 200\r\n\r\n'
    jq -nc --arg s "$SHA" '{head:{sha:\$s},base:{ref:"main"},title:"Add the thing",body:"PR body text"}' ;;
esac
exit 0
EOF
cat > "$H/bin/agent-call.sh" <<EOF2
#!/bin/bash
echo x >> "$T/log/agent-count"; n=\$(wc -l < "$T/log/agent-count")
if [ -f "$T/answer.\$n" ]; then cp "$T/answer.\$n" "\$5"; else cp "$T/answer" "\$5"; fi
exit 0
EOF2
chmod +x "$T/fakebin/curl" "$T/fakebin/gh" "$H/bin/agent-call.sh"

export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
  JOBS_RETRIES=0 JOBS_BEAT_SECS=1 TMPDIR="$T/tmp" REPOS_ROOT="$T/repos" FLEET_CONF="$H/fleet.conf" \
  LANE_GATE_DISABLE=1 GH_ETAG=0
unset BOX_NAME JOBS_BOX LEAD_REVIEW_MAX_PER_TICK LEAD_REVIEW_DEADLINE_S VERDICT_WINDOW_LINES _VP_WINDOW

jq -nc --arg s "$SHA" '{requests:[{id:"lr-1",repo:"example-org/demo-os",pr:41,head_sha:$s,status:"requested"}],truncated:false}' > "$T/requests.json"
REPORT="$H/state/lead-reviews/lr-41-$SHA12.md"
EMPTY="$H/state/lead-reviews/lr-41-$SHA12.empty"
LOGF="$H/logs/lead-review.log"
reset() {
  rm -f "${T:?}/log"/* "${T:?}"/{jobstate,result500,art500,artifacts.json,artifact.put,answer.*} "$LOGF"
  scratch_rm "$H/state/lead-reviews"; scratch_rm "$H/state/model-routes"
  printf 'Findings\n- [BLOCK] a.txt:2 — it breaks\n\nVERDICT: BLOCK\n' > "$T/answer"
}
tick() { ( cd "$T" && bash "$H/bin/lead-review.sh" tick ) > "$T/out" 2>&1; RC=$?; }
retake() { rm -f "${T:?}/result500" "${T:?}/log/worker" "${T:?}/artifact.put"; echo queued_for_retry > "$T/jobstate"; tick; }
agents() { [ -f "$T/log/agent-count" ] && wc -l < "$T/log/agent-count" | tr -d ' ' || echo 0; }
wlog() { cat "$T/log/worker" 2>/dev/null; }
has() { wlog | grep -qE "$1"; }
put() { jq -r "$1" "$T/artifact.put" 2>/dev/null; }          # put <jq> — on the captured PUT body
det() { jq -r ".detail | fromjson | $1" "$T/artifact.put" 2>/dev/null; } # det <jq> — on its parsed detail
u16() { jq -r '.detail | explode | map(if . > 65535 then 2 else 1 end) | add' "$T/artifact.put"; }
report_body() { # report_body <sha in header> <verdict> <model> -> a report as the lane writes it
  printf '# Lead review lr-41-%s (example-org/demo-os#41 at %s)\n\n- verdict: %s\n- host suite: exit 3 rc=3\n- reviewer model: %s\n\nFindings\n- none\n\nVERDICT: %s\n' \
    "$SHA12" "$1" "$2" "$3" "$2"
}
seed_art() { # seed_art <detail-json> — the worker already holds this lead_review_report
  jq -nc --arg d "$1" --arg r "$REPORT" '{artifacts:[{artifact_kind:"lead_review_report",artifact_ref:$r,detail:$d}]}' > "$T/artifacts.json"
}

# (B1) a fresh review: the artifact carries the body, ref stays the path
reset; tick
[ "$RC" -eq 0 ] && ok || bad "B1 rc=$RC out=$(cat "$T/out")"
[ "$(put .artifact_ref)" = "$REPORT" ] && ok || bad "B1 artifact_ref '$(put .artifact_ref)' (want $REPORT)"
[ "$(det 'type')" = object ] && ok || bad "B1 detail is not a JSON object: $(put .detail)"
det .body | head -n 1 | grep -qxF "# Lead review lr-41-$SHA12 (example-org/demo-os#41 at $SHA)" && ok || bad "B1 body header: $(det .body | head -n 1)"
cmp -s <(jq -j '.detail | fromjson | .body' "$T/artifact.put") "$REPORT" && ok || bad "B1 body does not round-trip the report file"
[ "$(det .path)" = "$REPORT" ] && ok || bad "B1 detail.path '$(det .path)'"
[ "$(det .verdict)" = BLOCK ] && ok || bad "B1 detail.verdict '$(det .verdict)'"
[ "$(det 'has("truncated")')" = false ] && ok || bad "B1 a small body is flagged truncated"
[ -f "$REPORT" ] && ok || bad "B1 the disk report is gone"
[ "$(cat "$T/jobstate")" = done ] && ok || bad "B1 job not done: $(cat "$T/jobstate")"
order=$(wlog | awk '
  /^PUT \/api\/jobs\/job-7\/artifacts / {print "artifact"}
  /^POST \/api\/lead-reviews\/lr-1\/result .*"outcome":"done"/ {print "result"}
  /^PATCH \/api\/jobs\/job-7 .*"status":"done"/ {print "done"}' | paste -sd' ')
[ "$order" = "artifact result done" ] && ok || bad "B1 order '$order'"
B1LEN=$(u16)

# (B1e) the retry the artifact exists for: result post failed, disk report gone
reset; : > "$T/result500"; tick
[ "$(cat "$T/jobstate")" = done ] && bad "B1e tick 1 stamped done without a result" || ok
rm -f "$REPORT"; retake
[ "$(agents)" = 1 ] && ok || bad "B1e the retake paid again with the artifact held: agents=$(agents)"
has '/result .*"outcome":"done","verdict":"BLOCK".*"reviewer_model":"stub-model"' && ok || bad "B1e retake result: $(wlog | grep /result)"
[ "$(cat "$T/jobstate")" = done ] && ok || bad "B1e job not done after the retake"

# (B2) a long answer with quotes, backslashes, é and an astral char: capped, valid, flagged
reset
{ printf 'Findings\n'
  for i in $(seq 1 300); do printf -- '- [NOTE] "q" \\ back é %s 😀\n' "$i"; done
  printf '\nVERDICT: BLOCK\n'; } > "$T/answer"
tick
[ "$(put .detail | jq -e 'type == "object"' 2>/dev/null)" = true ] && ok || bad "B2 detail is not valid JSON: $(put .detail | head -c 200)"
[ "$(det .truncated)" = true ] && ok || bad "B2 not flagged truncated"
n=$(u16); [ "$n" -le 4000 ] && [ "$n" -ge 3990 ] && ok || bad "B2 detail length $n UTF-16 units (want 3990..4000)"
[ "$(wc -c < "$REPORT")" -gt 9000 ] && ok || bad "B2 the fixture report is only $(wc -c < "$REPORT") bytes"
jq -j '.detail | fromjson | .body' "$T/artifact.put" > "$T/b2.body"
[ -s "$T/b2.body" ] && [ "$(head -c "$(wc -c < "$T/b2.body")" "$REPORT" | cmp -s - "$T/b2.body" && echo y)" = y ] && ok || bad "B2 body is not a prefix of the report"
[ "$(det .verdict)" = BLOCK ] && ok || bad "B2 verdict lost: $(det .verdict)"

# (B2b) the boundary: exactly 4000 units is stored whole, one more is truncated
pad() { # pad <n> -> the BLOCK answer with n more ASCII chars in its findings
  printf 'Findings\n- [BLOCK] a.txt:2 — it breaks %s\n\nVERDICT: BLOCK\n' "$(head -c "$1" /dev/zero | tr '\0' a)" > "$T/answer"
}
reset; pad $((4000 - B1LEN - 1)); tick
[ "$(u16)" = 4000 ] && ok || bad "B2b fixture missed the boundary: $(u16) units"
[ "$(det 'has("truncated")')" = false ] && ok || bad "B2b a detail of exactly 4000 units was truncated"
reset; pad $((4000 - B1LEN)); tick
[ "$(det .truncated)" = true ] && ok || bad "B2b 4001 units stored untruncated"
[ "$(u16)" -le 4000 ] && ok || bad "B2b over the cap: $(u16)"

# (B3) the artifact alone answers the retry: no agent call, no PUT, its verdict
reset; seed_art "$(jq -nc --arg b "$(report_body "$SHA" MERGE-WITH-NOTES old-model)" --arg p "$REPORT" '{body:$b,path:$p,verdict:"MERGE-WITH-NOTES"}')"
tick
[ "$(agents)" = 0 ] && ok || bad "B3 agents=$(agents) (want 0)"
has '/result .*"outcome":"done","verdict":"MERGE-WITH-NOTES".*"reviewer_model":"old-model"' && ok || bad "B3 result: $(wlog | grep /result)"
has "/result .*\"report_ref\":\"$REPORT\"" && ok || bad "B3 report_ref is not the disk path"
has '^PUT /api/jobs/job-7/artifacts' && bad "B3 the replay re-PUT the artifact" || ok
[ "$(cat "$T/jobstate")" = done ] && ok || bad "B3 job not done"
grep -q "reusing artifact lead_review_report for lr-41-$SHA12; no agent call" "$LOGF" && ok || bad "B3 no reuse log line: $(cat "$LOGF")"

# (B3b) the artifact read fails (rc 1): the disk report is replayed, never "absent -> call"
reset; mkdir -p "$(dirname "$REPORT")"; report_body "$SHA" MERGE old-model > "$REPORT"; : > "$T/art500"; tick
[ "$(agents)" = 0 ] && ok || bad "B3b agents=$(agents)"
has '/result .*"outcome":"done","verdict":"MERGE"' && ok || bad "B3b result: $(wlog | grep /result)"
grep -q "artifact for lr-41-$SHA12 unavailable (rc=1); reading disk" "$LOGF" && ok || bad "B3b no rc=1 log line"
grep -q "reusing $REPORT for lr-41-$SHA12; no agent call" "$LOGF" && ok || bad "B3b disk not replayed"

# (B3c) truncated artifact + disk report: the disk is authoritative
trunc() { # trunc <verdict> -> a truncated detail whose body is the header only
  jq -nc --arg b "$(report_body "$SHA" "$1" old-model | head -n 5)" --arg p "$REPORT" --arg v "$1" '{body:$b,path:$p,verdict:$v,truncated:true}'
}
reset; mkdir -p "$(dirname "$REPORT")"; report_body "$SHA" BLOCK disk-model > "$REPORT"; seed_art "$(trunc MERGE)"; tick
[ "$(agents)" = 0 ] && ok || bad "B3c agents=$(agents)"
has '/result .*"verdict":"BLOCK".*"reviewer_model":"disk-model"' && ok || bad "B3c posted the artifact's verdict over the disk's: $(wlog | grep /result)"

# (B3c2) truncated artifact, no disk: its verdict word, no second paid call
reset; seed_art "$(trunc MERGE)"; tick
[ "$(agents)" = 0 ] && ok || bad "B3c2 agents=$(agents)"
has '/result .*"outcome":"done","verdict":"MERGE".*"reviewer_model":"old-model"' && ok || bad "B3c2 result: $(wlog | grep /result)"

# (B3c3) truncated artifact whose verdict is not exactly one word: terminal empty, not MERGE
reset; seed_art "$(trunc MERGE | jq -c '.verdict = "MERGE."')"; tick
[ "$(agents)" = 0 ] && ok || bad "B3c3 agents=$(agents)"
has '/result .*"outcome":"failed".*"detail":"empty"' && ok || bad "B3c3 result: $(wlog | grep /result)"
has '"outcome":"done"' && bad "B3c3 read 'MERGE.' as a verdict" || ok

# (B3d) an artifact whose header names another sha is never replayed
reset; seed_art "$(jq -nc --arg b "$(report_body "$OTHER" MERGE old-model)" '{body:$b,verdict:"MERGE"}')"; tick
[ "$(agents)" = 1 ] && ok || bad "B3d agents=$(agents) (want 1)"
has '/result .*"verdict":"BLOCK"' && ok || bad "B3d posted the stale verdict: $(wlog | grep /result)"

# (B4) billed with no verdict: an empty artifact too, and it alone makes the retry terminal
reset; : > "$T/answer"; : > "$T/result500"; tick
[ "$(agents)" = 2 ] && ok || bad "B4 tick 1 agents=$(agents)"
[ "$(det .empty)" = true ] && ok || bad "B4 no empty artifact: $(cat "$T/artifact.put" 2>/dev/null)"
[ "$(put .artifact_ref)" = "$EMPTY" ] && ok || bad "B4 empty artifact_ref '$(put .artifact_ref)'"
[ "$(det .model)" = stub-model ] && ok || bad "B4 empty artifact model '$(det .model)'"
[ -f "$EMPTY" ] && ok || bad "B4 the .empty marker file is gone"
rm -f "$EMPTY"; retake
[ "$(agents)" = 2 ] && ok || bad "B4 the retake paid again: agents=$(agents)"
has '/result .*"outcome":"failed".*"detail":"empty".*"reviewer_model":"stub-model"' && ok || bad "B4 retake result: $(wlog | grep /result)"
[ "$(cat "$T/jobstate")" = failed ] && ok || bad "B4 job not failed: $(cat "$T/jobstate")"
grep -q "billed with no verdict earlier for lr-41-$SHA12 (artifact); no agent call" "$LOGF" && ok || bad "B4 no artifact marker log line"

# (B5) no model id added to the lane
if git -C "$DIR" rev-parse -q --verify origin/main >/dev/null 2>&1; then
  git -C "$DIR" diff origin/main -- bin/lead-review.sh | grep -E '^\+.*claude-[a-z0-9-]*' && bad "B5 a model id was added" || ok
fi

echo "lead-review-body-artifact.bh-2624: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
