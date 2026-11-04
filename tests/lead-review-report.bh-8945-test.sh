#!/bin/bash
# tests/lead-review-report.bh-8945-test.sh — BH-8945: a pool lead review report
# stays readable after the machine is gone.
#   R1  ephemeral tick, short report: report_ref is artifact:<job>/lead_review_report;
#       with the disk report deleted, bin/lead-review-report.sh <id> and <ref>
#       print it byte for byte, rc 0.
#   R2  ephemeral tick, ~12000-unit report: the script prints the WHOLE body
#       from the transcript; with the transcript slot empty, the prefix and rc 2.
#   R3  ephemeral, the first transcript POST is a 500: 2 POSTs, 1 log line with
#       the PR and the head, 0 alerts, result done.
#   R3b ephemeral, the POST is a 200 but the hub keeps an older body: no
#       "stored" line, 2 POSTs, 1 alert (the read-back is the proof).
#   R4  ephemeral, every POST a 500 (attempts 3, backoff 0): 3 POSTs, 3 log
#       lines, exactly 1 alert naming PR, head and job; result done; 1 agent call.
#   R5  no env, long report, POST fails: disk report_ref, 1 POST, 0 alerts.
#   R6  the script's answers: unknown id rc 3; no job_id rc 3; worker down
#       rc 1; ../x rc 64 with no request; artifact:j/other rc 64.
#   R7  run_leadreview_job hands the lane LEAD_REVIEW_EPHEMERAL=1.
#   R8  ephemeral stored-artifact replay: 0 transcript POSTs, 0 alerts.
#   R9  zero vendor calls in the whole file.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-review-report.bh-8945-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"; mkdir -p "$H/bin" "$H/prompts" "$H/catalog/lanes.d" "$H/state" "$H/env" "$T/fakebin" "$T/log" "$T/repos" "$T/tmp"
# The stubs go in first: scratch_install_closure never overwrites them.
cat > "$H/bin/agent-call.sh" <<EOF2
#!/bin/bash
echo x >> "$T/log/agent-count"
cp "$T/answer" "\$5"
exit 0
EOF2
cat > "$H/bin/alert-line.sh" <<EOF2
#!/bin/bash
printf '%s\n' "\$*" >> "$T/log/alerts"
exit 0
EOF2
chmod +x "$H/bin/agent-call.sh" "$H/bin/alert-line.sh"
for s in bin/lead-review.sh bin/jobs-client.sh bin/box-for.sh bin/fleet-conf.sh \
         bin/transcript-push.sh bin/transcript-scrub.sh bin/transcript-render.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || { echo "could not install $s"; exit 1; }
done
# The reader under test: copied from the tree, so on main it is absent and R1 is red.
if [ -f "$DIR/bin/lead-review-report.sh" ]; then
  scratch_install_closure bin/lead-review-report.sh "$H" >/dev/null || { echo "could not install bin/lead-review-report.sh"; exit 1; }
fi
cp "$DIR/catalog/lanes.d/_lib.json" "$H/catalog/lanes.d/"
[ -f "$DIR/prompts/lead-review.md" ] && cp "$DIR/prompts/lead-review.md" "$H/prompts/"
[ -f "$DIR/prompts/lead-review-checklist.md" ] && cp "$DIR/prompts/lead-review-checklist.md" "$H/prompts/"
printf 'HARNESS_SECRET=fixture-secret-8945\n' > "$H/env/global.env"
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

# ── the stub jobs worker (the BH-5915 one, plus the lead-review read by id).
# tr500 holds how many transcript POSTs answer 500 ("all" = every one); down
# makes curl a transport failure; a curl to any other host is a vendor call.
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
m=GET; body=""; url=""; prev=""
for a in "\$@"; do
  case "\$prev" in -X) m="\$a" ;; --data-binary) body="\$a" ;; esac
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
case "\$url" in https://jobs.test/*) ;; *) echo "curl \$url" >> "$T/log/vendor"; exit 7 ;; esac
[ -e "$T/down" ] && exit 7
case "\$body" in @*) body=\$(cat "\${body#@}") ;; esac
p="\${url#https://jobs.test}"
printf '%s %s %s\n' "\$m" "\$p" "\$body" >> "$T/log/worker"
code=200; out='{}'
case "\$m \$p" in
  "GET /api/lead-reviews/lr-1")
    ref=\$(grep '^POST /api/lead-reviews/lr-1/result ' "$T/log/worker" | tail -1 | sed 's/^[^{]*//' | jq -r '.report_ref // ""')
    out=\$(jq -nc --arg r "\$ref" '{request:{id:"lr-1",status:"done",job_id:"job-7",report_ref:\$r}}') ;;
  "GET /api/lead-reviews/lr-nojob") out='{"request":{"id":"lr-nojob","status":"requested","job_id":null}}' ;;
  "GET /api/lead-reviews/"*) code=404; out='{"error":"not found"}' ;;
  "GET /api/lead-reviews"*) out=\$(cat "$T/requests.json") ;;
  "POST /api/jobs")
    st=\$(cat "$T/jobstate" 2>/dev/null)
    if [ "\$st" = running ]; then code=409; out='{"job":{"id":"job-7","box":"box-other"}}'
    else echo running > "$T/jobstate"; out='{"job":{"id":"job-7"}}'; fi ;;
  "GET /api/jobs/job-7/artifacts")
    out=\$(cat "$T/artifacts.json" 2>/dev/null || echo '{"artifacts":[]}') ;;
  "GET /api/jobs/"*"/artifacts") out='{"artifacts":[]}' ;;
  "PUT /api/jobs/job-7/artifacts")
    printf '%s' "\$body" > "$T/artifact.put"
    cur=\$(cat "$T/artifacts.json" 2>/dev/null || echo '{"artifacts":[]}')
    jq -c --argjson b "\$body" '.artifacts |= ([.[] | select(.artifact_kind != \$b.artifact_kind)] + [\$b])' <<<"\$cur" > "$T/artifacts.json.n" \
      && mv "$T/artifacts.json.n" "$T/artifacts.json" ;;
  "POST /api/jobs/job-7/transcript")
    n=\$(( \$(cat "$T/tr-count" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "$T/tr-count"
    lim=\$(cat "$T/tr500" 2>/dev/null || echo 0)
    if [ "\$lim" = all ] || [ "\$n" -le "\$lim" ] 2>/dev/null; then code=500; out='{"error":"boom"}'
    elif [ -e "$T/tr-stale" ]; then out='{"transcript":{}}'   # a 200 that keeps the older body
    else printf '%s' "\$body" > "$T/transcript.json"; out='{"transcript":{}}'; fi ;;
  "GET /api/jobs/job-7/transcripts")
    if [ -s "$T/transcript.json" ]; then
      out=\$(jq -c '{transcripts:[{phase_id:(.phase_id // 0),attempt:(.attempt // 1),stage:.stage,runner:.runner,source:.source,bytes:(.body|length)}]}' "$T/transcript.json")
    else out='{"transcripts":[]}'; fi ;;
  "GET /api/jobs/job-7/transcript?phase_id=0&attempt=100")
    if [ -s "$T/transcript.json" ]; then out=\$(jq -c '{transcript:{body:.body,source:.source,truncated:(.truncated // 0)}}' "$T/transcript.json")
    else code=404; out='{"error":"no transcript for this attempt"}'; fi ;;
  "PATCH /api/jobs/"*)
    s=\$(printf '%s' "\$body" | jq -r '.status // empty'); [ -n "\$s" ] && echo "\$s" > "$T/jobstate" ;;
  "GET /api/model-routes/"*) out='{"ladder":[{"position":0,"model":"stub-model","runner":"claude"}],"source":"hub"}' ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
# gh is the local PR fake (the BH-5915 one: the lane reads the PR head, every
# other read is empty); flyctl and claude are vendors: a call records and fails (R9).
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"-i -X GET repos/"*"/pulls/"*)
    printf 'HTTP/2 200\r\n\r\n'
    jq -nc --arg s "$SHA" '{head:{sha:\$s},base:{ref:"main"},title:"Add the thing",body:"PR body text"}' ;;
esac
exit 0
EOF
for v in flyctl claude; do printf '#!/bin/bash\necho "%s $*" >> "%s/log/vendor"\nexit 1\n' "$v" "$T" > "$T/fakebin/$v"; done
chmod +x "$T/fakebin/curl" "$T/fakebin/gh" "$T/fakebin/flyctl" "$T/fakebin/claude"

export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_ENV_DIR="$H/env" HARNESS_SECRET=fixture-secret-8945 \
  JOBS_URL=https://jobs.test JOBS_RETRIES=0 JOBS_BEAT_SECS=1 TMPDIR="$T/tmp" REPOS_ROOT="$T/repos" \
  FLEET_CONF="$H/fleet.conf" LANE_GATE_DISABLE=1 GH_ETAG=0 CLAUDE_PROJECTS_DIR="$T/no-sessions" \
  LEAD_REVIEW_MAX_PER_PR_DAY=100   # this file ticks one PR more than the default 4 times
unset BOX_NAME JOBS_BOX JOB_ID JOB_PHASE_ID TRANSCRIPT_SOURCE LEAD_REVIEW_MAX_PER_TICK LEAD_REVIEW_DEADLINE_S VERDICT_WINDOW_LINES _VP_WINDOW \
  LEAD_REVIEW_EPHEMERAL LEAD_REVIEW_REPORT_PUSH_ATTEMPTS LEAD_REVIEW_REPORT_PUSH_BACKOFF_S

jq -nc --arg s "$SHA" '{requests:[{id:"lr-1",repo:"example-org/demo-os",pr:41,head_sha:$s,status:"requested"}],truncated:false}' > "$T/requests.json"
KEY="lr-41-$SHA12"
PRURL="https://github.com/example-org/demo-os/pull/41"
REPORT="$H/state/lead-reviews/$KEY.md"
LOGF="$H/logs/lead-review.log"
AREF="artifact:job-7/lead_review_report"
reset() {
  rm -f "${T:?}/log"/{worker,agent-count,alerts} "${T:?}"/{jobstate,tr500,tr-count,tr-stale,down,artifacts.json,artifact.put,transcript.json,saved.md} "$LOGF"
  scratch_rm "$H/state/lead-reviews"; scratch_rm "$H/state/model-routes"
}
tick() { ( cd "$T" && bash "$H/bin/lead-review.sh" tick ) > "$T/out" 2>&1; RC=$?; }
etick() { ( export LEAD_REVIEW_EPHEMERAL=1; tick; exit "$RC" ); RC=$?; }
wlog() { cat "$T/log/worker" 2>/dev/null; }
tr_posts() { wlog | grep -c '^POST /api/jobs/job-7/transcript ' ; }
alerts() { [ -s "$T/log/alerts" ] && wc -l < "$T/log/alerts" | tr -d ' ' || echo 0; }
posted_ref() { wlog | grep '^POST /api/lead-reviews/lr-1/result ' | tail -1 | sed 's/^[^{]*//' | jq -r '.report_ref // ""'; }
done_posted() { wlog | grep -q '^POST /api/lead-reviews/lr-1/result .*"outcome":"done"'; }
rr() { # rr <arg> — run the reader; stdout to $T/rr.out, stderr to $T/rr.err, rc in RRC
  ( cd "$T" && bash "$H/bin/lead-review-report.sh" "$@" ) > "$T/rr.out" 2> "$T/rr.err"; RRC=$?
}
long_answer() {
  { printf 'Findings\n'
    for i in $(seq 1 15); do
      printf -- '- [BLOCK] a.txt:%s — item %s breaks é 😀\n' "$i" "$i"
      for j in $(seq 1 12); do printf -- '  context line %s.%s: the change reads the wrong field here 😀\n' "$i" "$j"; done
    done
    printf -- '- [BLOCK] a.txt:99 — the last finding, past the cap\n'
    printf '\nVERDICT: BLOCK\n'; } > "$T/answer"
}
short_answer() { printf 'Findings\n- [BLOCK] a.txt:2 — it breaks\n\nVERDICT: BLOCK\n' > "$T/answer"; }
retry_lines() { grep -c "full report for $KEY (PR $PRURL head $SHA12) not on the hub after attempt" "$LOGF" 2>/dev/null; }

# ══ R1: a short report, read by id after the machine is gone ════════════════
reset; short_answer; etick
[ "$RC" -eq 0 ] && ok || bad "R1 rc=$RC out=$(cat "$T/out")"
[ "$(posted_ref)" = "$AREF" ] && ok || bad "R1 THE POINT: report_ref is '$(posted_ref)' (want $AREF)"
cp "$REPORT" "$T/saved.md" 2>/dev/null; rm -f "$REPORT"   # the machine is gone
rr lr-1
[ "$RRC" = 0 ] && ok || bad "R1 THE POINT: lead-review-report.sh lr-1 rc=$RRC err=$(cat "$T/rr.err")"
cmp -s "$T/rr.out" "$T/saved.md" && ok || bad "R1 the read is not the report byte for byte"
rr "$(posted_ref)"
[ "$RRC" = 0 ] && cmp -s "$T/rr.out" "$T/saved.md" && ok || bad "R1 the read by the posted ref: rc=$RRC err=$(cat "$T/rr.err")"
[ "$(alerts)" = 0 ] && ok || bad "R1 alerts: $(cat "$T/log/alerts")"

# ══ R2: a long report comes back whole; a missing transcript is rc 2 ═══════
reset; long_answer; etick
[ "$(tr_posts)" = 1 ] && ok || bad "R2 transcript POSTs: $(tr_posts)"
cp "$REPORT" "$T/saved.md" 2>/dev/null; rm -f "$REPORT"
rr lr-1
[ "$RRC" = 0 ] && ok || bad "R2 rc=$RRC err=$(cat "$T/rr.err")"
cmp -s "$T/rr.out" "$T/saved.md" && ok || bad "R2 the read is not the whole report ($(wc -c < "$T/rr.out") vs $(wc -c < "$T/saved.md"))"
[ "$(alerts)" = 0 ] && ok || bad "R2 alerts: $(cat "$T/log/alerts")"
rm -f "$T/transcript.json"; rr lr-1
[ "$RRC" = 2 ] && ok || bad "R2 no transcript: rc=$RRC (want 2)"
[ -s "$T/rr.out" ] && head -c "$(wc -c < "$T/rr.out")" "$T/saved.md" | cmp -s - "$T/rr.out" && ok || bad "R2 no transcript: stdout is not the report's prefix"
[ "$(wc -l < "$T/rr.err" | tr -d ' ')" = 1 ] && grep -qi 'truncated' "$T/rr.err" && ok || bad "R2 no transcript: stderr '$(cat "$T/rr.err")'"

# ══ R3: one failed copy, then stored ════════════════════════════════════════
reset; long_answer; echo 1 > "$T/tr500"
( export LEAD_REVIEW_REPORT_PUSH_BACKOFF_S=0; etick; exit "$RC" ); RC=$?
[ "$(tr_posts)" = 2 ] && ok || bad "R3 transcript POSTs: $(tr_posts) (want 2)"
[ "$(retry_lines)" = 1 ] && ok || bad "R3 THE POINT: retry log lines with PR and head: $(retry_lines) log: $(grep 'full report' "$LOGF")"
[ "$(alerts)" = 0 ] && ok || bad "R3 alerts: $(cat "$T/log/alerts")"
done_posted && ok || bad "R3 no done result"
[ "$(cat "$T/jobstate")" = done ] && ok || bad "R3 job not done"

# ══ R3b: the worker answers 200 but keeps an older body: only the read-back sees it
reset; long_answer; : > "$T/tr-stale"
jq -nc '{source:"lead_report",attempt:100,body:"an older report\n"}' > "$T/transcript.json"
( export LEAD_REVIEW_REPORT_PUSH_ATTEMPTS=2 LEAD_REVIEW_REPORT_PUSH_BACKOFF_S=0; etick; exit "$RC" ); RC=$?
[ "$(tr_posts)" = 2 ] && ok || bad "R3b transcript POSTs: $(tr_posts) (want 2)"
[ "$(alerts)" = 1 ] && ok || bad "R3b THE POINT: a 200 with a stale body is not stored; alerts: $(alerts)"
grep -q "full report for $KEY stored on the hub" "$LOGF" && bad "R3b logged a stored report it never read back" || ok

# ══ R4: every copy fails: N lines, one alert, review still done ═════════════
reset; long_answer; echo all > "$T/tr500"
( export LEAD_REVIEW_REPORT_PUSH_ATTEMPTS=3 LEAD_REVIEW_REPORT_PUSH_BACKOFF_S=0; etick; exit "$RC" ); RC=$?
[ "$(tr_posts)" = 3 ] && ok || bad "R4 transcript POSTs: $(tr_posts) (want 3)"
[ "$(retry_lines)" = 3 ] && ok || bad "R4 retry log lines: $(retry_lines) (want 3)"
[ "$(alerts)" = 1 ] && ok || bad "R4 THE POINT: alert lines: $(alerts) (want 1)"
a=$(cat "$T/log/alerts" 2>/dev/null)
case "$a" in *"--id lead-report-push-job-7"*) ok ;; *) bad "R4 alert id: $a" ;; esac
case "$a" in *"$PRURL"*"$SHA12"*"job-7"*) ok ;; *) bad "R4 the alert does not name PR, head and job: $a" ;; esac
done_posted && ok || bad "R4 no done result"
[ "$(cat "$T/jobstate")" = done ] && ok || bad "R4 job not done"
[ "$(wc -l < "$T/log/agent-count" | tr -d ' ')" = 1 ] && ok || bad "R4 agent calls: $(cat "$T/log/agent-count" 2>/dev/null | wc -l)"

# ══ R5: a persistent box is unchanged ═══════════════════════════════════════
reset; long_answer; echo all > "$T/tr500"; tick
[ "$(posted_ref)" = "$REPORT" ] && ok || bad "R5 report_ref '$(posted_ref)' (want the disk path)"
[ "$(tr_posts)" = 1 ] && ok || bad "R5 transcript POSTs: $(tr_posts) (want 1)"
[ "$(alerts)" = 0 ] && ok || bad "R5 alerts: $(cat "$T/log/alerts")"
[ "$(retry_lines)" = 0 ] && ok || bad "R5 retry lines on a persistent box"
reset; short_answer; ( export LEAD_REVIEW_EPHEMERAL=yes; tick ); [ "$(posted_ref)" = "$REPORT" ] && ok || bad "R5 EPHEMERAL=yes turned it on"

# ══ R6: the reader's answers ════════════════════════════════════════════════
reset
rr lr-unknown; [ "$RRC" = 3 ] && [ ! -s "$T/rr.out" ] && ok || bad "R6 unknown id rc=$RRC (want 3) out=$(head -c 80 "$T/rr.out")"
rr lr-nojob;   [ "$RRC" = 3 ] && [ ! -s "$T/rr.out" ] && ok || bad "R6 no job_id rc=$RRC (want 3)"
rr artifact:job-none/lead_review_report; [ "$RRC" = 3 ] && ok || bad "R6 a job with no report rc=$RRC (want 3)"
: > "$T/down"; rr lr-1; [ "$RRC" = 1 ] && [ ! -s "$T/rr.out" ] && ok || bad "R6 worker down rc=$RRC (want 1)"; rm -f "$T/down"
: > "$T/log/worker"
rr ../x; [ "$RRC" = 64 ] && ok || bad "R6 ../x rc=$RRC (want 64)"
rr "";   [ "$RRC" = 64 ] && ok || bad "R6 empty id rc=$RRC (want 64)"
rr artifact:j/other; [ "$RRC" = 64 ] && ok || bad "R6 artifact:j/other rc=$RRC (want 64)"
rr 'artifact:../j/lead_review_report'; [ "$RRC" = 64 ] && ok || bad "R6 artifact:../j rc=$RRC (want 64)"
[ ! -s "$T/log/worker" ] && ok || bad "R6 a bad id made a request: $(cat "$T/log/worker")"

# ══ R7: the pool machine marks the lane ephemeral ═══════════════════════════
awk '/^run_leadreview_job\(\) \{/,/^\}/; /^leadreview_setup_result\(\) \{/,/^\}/' "$DIR/fly/builder-runner.sh" > "$T/runner-fns.sh"
mkdir -p "$T/m/bin"
cat > "$T/m/bin/lead-review.sh" <<EOF
#!/bin/bash
printf '%s\n' "\${LEAD_REVIEW_EPHEMERAL:-unset}" > "$T/m/env-seen"
echo done > "\$5"
EOF
jq -nc '{leadreview:{url:"https://github.com/example-org/demo-os/pull/41",head:"abc",mode:"full",item:{}}}' > "$T/m/job.json"
( JOB="$T/m/job.json" RESULT_FILE="$T/m/RESULT" HARNESS="$T/m" PROJECT=demo-os REPO="$T/repos/demo-os" ENVDIR="$T/env"
  unset LEAD_REVIEW_EPHEMERAL
  log() { :; }; beat() { :; }; warm_up() { return 0; }
  # shellcheck source=/dev/null
  . "$T/runner-fns.sh"; run_leadreview_job LR-41-abc ) >/dev/null 2>&1
[ "$(cat "$T/m/env-seen" 2>/dev/null)" = 1 ] && ok || bad "R7 the lane saw LEAD_REVIEW_EPHEMERAL=$(cat "$T/m/env-seen" 2>/dev/null)"
[ "$(head -1 "$T/m/RESULT" 2>/dev/null)" = "LEAD_REVIEWED done" ] && ok || bad "R7 RESULT: $(cat "$T/m/RESULT" 2>/dev/null)"

# ══ R8: the stored-artifact replay copies nothing ═══════════════════════════
reset
hdr=$(printf '# Lead review %s (example-org/demo-os#41 at %s)\n\n- verdict: BLOCK\n- host suite: exit 3 rc=3\n- reviewer model: old-model' "$KEY" "$SHA")
jq -nc --arg b "$hdr" --arg p "$REPORT" '{artifacts:[{artifact_kind:"lead_review_report",artifact_ref:$p,
  detail:({body:$b,path:$p,verdict:"BLOCK",truncated:true}|tojson)}]}' > "$T/artifacts.json"
etick
[ -f "$T/log/agent-count" ] && bad "R8 the replay paid an agent call" || ok
done_posted && ok || bad "R8 no done result"
[ "$(tr_posts)" = 0 ] && ok || bad "R8 the replay pushed a transcript"
[ "$(alerts)" = 0 ] && ok || bad "R8 alerts: $(cat "$T/log/alerts")"

# ══ R9: zero vendor calls ═══════════════════════════════════════════════════
[ ! -s "$T/log/vendor" ] && ok || bad "R9 vendor calls: $(cat "$T/log/vendor")"

echo "lead-review-report.bh-8945: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
