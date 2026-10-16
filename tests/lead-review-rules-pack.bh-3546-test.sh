#!/bin/bash
# tests/lead-review-rules-pack.bh-3546-test.sh — BH-3546 (BH-3479.2): the box
# lead review lane reads a versioned checklist, the PR's `Closes #<n>` ticket
# thread, and runs the rules pack FIRST. Drives the REAL bin/lead-review.sh tick
# against a scratch harness built the way tests/lead-review-lane.bh-1950-test.sh
# builds one, with these stubbed:
#   * curl  — the jobs worker (list/claim/result, job rows, artifacts, routes)
#   * gh    — the REST reads: pulls/<n>, issues/42, issues/42/comments
#   * bin/agent-call.sh — counts calls, keeps each prompt and its AGENT_CALL_* env
#   * bin/rules-pack.sh — logs its argv, prints $T/pack.stdout, exits $T/pack.rc
# Covers R1-R9 and the M1 mutation (the rules-pack BLOCK makes no agent call).
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-review-rules-pack.bh-3546-test.sh
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
NOW=$(date +%s)

H="$T/h"; mkdir -p "$H/bin/lib/jobs" "$H/prompts" "$H/catalog/lanes.d" "$H/state" "$T/fakebin" "$T/log" "$T/repos" "$T/tmp"
cp "$DIR/bin/jobs-client.sh" "$DIR/bin/box-for.sh" "$DIR/bin/fleet-conf.sh" "$H/bin/"
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
for f in env-path lead-reviews verdicts model-route verdict-parse gh-rest hub-box lane-gate review-pool review-env-fail lead-worklist; do
  cp "$DIR/bin/lib/$f.sh" "$H/bin/lib/"
done
cp "$DIR/catalog/lanes.d/_lib.json" "$H/catalog/lanes.d/"
cp "$DIR/prompts/lead-review.md" "$H/prompts/"
[ -f "$DIR/prompts/lead-review-checklist.md" ] && cp "$DIR/prompts/lead-review-checklist.md" "$H/prompts/"
cp "$DIR/bin/lead-review.sh" "$H/bin/"
# TEST-CHANGE (BH-6293): bin/lead-review.sh loads its modules from bin/lib/lead-review/.
scratch_install_closure bin/lib/lead-review/load.sh "$H" >/dev/null || { echo "closure install of bin/lib/lead-review failed"; exit 1; }
echo box-demo > "$H/state/box-name"
cat > "$H/fleet.conf" <<'EOF'
# project repo prod board offset box
cromford example-org/cromford https://bh.test    /api/board 1 box-demo
other-os      example-org/other         https://other.test /api/board 2 box-demo
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
# The host suite only leaves a mark, so R4 can prove it never ran.
CONTRACT=$'# bh\n\n## Verification Contract\n\n```bash\ntouch '"$T"$'/suite-ran\n```\n'
SHA=$(mk_repo cromford 41 "$CONTRACT")
OSHA=$(mk_repo other-os 5 "$CONTRACT")
SHA12=${SHA:0:12}

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
  "PATCH /api/jobs/"*)
    s=\$(printf '%s' "\$body" | jq -r '.status // empty'); [ -n "\$s" ] && echo "\$s" > "$T/jobstate" ;;
  "POST /api/lead-reviews/"*/result) [ -e "$T/result500" ] && { code=500; out='{"error":"boom"}'; } ;;
  "GET /api/model-routes/"*) out='{"ladder":[{"position":0,"model":"stub-model","runner":"claude"}],"source":"hub"}' ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
echo "\$*" >> "$T/log/gh"
case "\$*" in
  *"-X GET repos/"*"/pulls/"*)
    printf 'HTTP/2 200\r\n\r\n'
    jq -nc --arg s "\$(cat "$T/livehead")" --arg b "\$(cat "$T/prbody")" '{head:{sha:\$s},base:{ref:"main"},title:"Add the thing",body:\$b}' ;;
  *"-X GET repos/"*"/issues/42/comments"*)
    if [ -e "$T/issuefail" ]; then printf 'HTTP/2 502\r\n\r\n{"message":"bad gateway"}\n'; exit 1; fi
    printf 'HTTP/2 200\r\n\r\n'; cat "$T/comments.json" ;;
  *"-X GET repos/"*"/issues/42"*)
    if [ -e "$T/issuefail" ]; then printf 'HTTP/2 502\r\n\r\n{"message":"bad gateway"}\n'; exit 1; fi
    printf 'HTTP/2 200\r\n\r\n'; cat "$T/issue.json" ;;
esac
exit 0
EOF
cat > "$H/bin/agent-call.sh" <<EOF
#!/bin/bash
echo x >> "$T/log/agent-count"; n=\$(wc -l < "$T/log/agent-count")
case "\$6" in @/*) cat "\${6#@}" ;; *) printf '%s' "\$6" ;; esac > "$T/log/prompt.\$n"
env | grep '^AGENT_CALL_' >> "$T/log/agent-env"
cp "$T/answer" "\$5"
exit 0
EOF
cat > "$T/rules-pack.sh" <<EOF
#!/bin/bash
echo "\$*" >> "$T/log/pack"
cat "$T/pack.stdout"
echo boom >&2
exit "\$(cat "$T/pack.rc")"
EOF
chmod +x "$T/fakebin/curl" "$T/fakebin/gh" "$H/bin/agent-call.sh" "$T/rules-pack.sh"

export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
  JOBS_RETRIES=0 JOBS_BEAT_SECS=1 TMPDIR="$T/tmp" REPOS_ROOT="$T/repos" FLEET_CONF="$H/fleet.conf" \
  LANE_GATE_DISABLE=1 GH_ETAG=0
unset BOX_NAME JOBS_BOX LEAD_REVIEW_MAX_PER_TICK LEAD_REVIEW_DEADLINE_S VERDICT_WINDOW_LINES _VP_WINDOW

req() { jq -nc --arg i "$1" --arg r "$2" --argjson p "$3" --arg s "$4" \
  '{id:$i,repo:$r,pr:$p,head_sha:$s,scope_notes:"only the lane",prior_verdict_ref:"verdict-9",status:"requested"}'; }
setreqs() { printf '%s\n' "$@" | jq -sc '{requests:., truncated:false}' > "$T/requests.json"; }
reset() {
  rm -f "$T/log"/* "$T"/{jobstate,result500,issuefail,suite-ran} "$H/logs/lead-review.log"
  scratch_rm "$H/state/lead-reviews"; scratch_rm "$H/state/model-routes"
  cp "$T/rules-pack.sh" "$H/bin/rules-pack.sh"
  cp "$DIR/prompts/lead-review-checklist.md" "$H/prompts/" 2>/dev/null
  cp "$DIR/bin/lead-review.sh" "$H/bin/"
  echo "$SHA" > "$T/livehead"
  echo 'PR body text. Closes #42' > "$T/prbody"
  jq -nc '{number:42,title:"The ask",body:"spec text"}' > "$T/issue.json"
  jq -nc '[{user:{login:"operator"},created_at:"2026-09-29T10:00:00Z",body:"first-comment-body"},
           {user:{login:"client"},created_at:"2026-09-29T11:00:00Z",body:"second-comment-body"}]' > "$T/comments.json"
  echo 0 > "$T/pack.rc"; : > "$T/pack.stdout"
  setreqs "$(req lr-1 example-org/cromford 41 "$SHA")"
  printf 'Findings\n- [NOTE] a.txt:2: fine\n\nVERDICT: MERGE-WITH-NOTES\n' > "$T/answer"
  export LEAD_REVIEW_THREAD_MAX_BYTES=60000
}
tick() { ( cd "$T" && bash "$H/bin/lead-review.sh" tick ) > "$T/out" 2>&1; RC=$?; }
agents() { [ -f "$T/log/agent-count" ] && wc -l < "$T/log/agent-count" | tr -d ' ' || echo 0; }
wlog() { cat "$T/log/worker" 2>/dev/null; }
has() { wlog | grep -qE "$1"; }
P1="$T/log/prompt.1"
REPORT="$H/state/lead-reviews/lr-41-$SHA12.md"
# section <heading> <next heading> — the prompt's lines strictly between the two
section() { awk -v a="$1" -v b="$2" '$0 == a {f=1; next} $0 == b {f=0} f' "$P1"; }

# The version the checklist names on line 1; the report and prompt must match it.
CKV=$(sed -n '1s/^Checklist-Version: *\([0-9][0-9]*\)$/\1/p' "$DIR/prompts/lead-review-checklist.md")
[ -n "$CKV" ] && ok || bad "prompts/lead-review-checklist.md line 1 has no Checklist-Version"

# ── R1: the checklist follows prompts/lead-review.md, before ## PR ──
reset; tick
[ "$RC" -eq 0 ] && ok || bad "R1 rc=$RC out=$(cat "$T/out")"
n=$(wc -c < "$DIR/prompts/lead-review.md")
cmp -s -n "$n" "$DIR/prompts/lead-review.md" "$P1" && ok || bad "R1 prompt does not start with prompts/lead-review.md"
first=$(tail -c +"$((n + 1))" "$P1" 2>/dev/null | awk 'NF {print; exit}')
[ "$first" = "Checklist-Version: $CKV" ] && ok || bad "R1 first non-blank line after lead-review.md is '$first'"
grep -q 'D42' "$P1" 2>/dev/null && grep -q 'D43' "$P1" 2>/dev/null && ok || bad "R1 prompt lacks the D42/D43 items"
cv=$(grep -n "^Checklist-Version: $CKV\$" "$P1" 2>/dev/null | head -n 1 | cut -d: -f1)
wl=$(grep -n '^## What to look for$' "$P1" 2>/dev/null | head -n 1 | cut -d: -f1)
pl=$(grep -n '^## PR$' "$P1" 2>/dev/null | head -n 1 | cut -d: -f1)
[ -n "$cv" ] && [ -n "$wl" ] && [ -n "$pl" ] && [ "$cv" -gt "$wl" ] && [ "$pl" -gt "$cv" ] \
  && ok || bad "R1 order: What-to-look-for=$wl Checklist-Version=$cv ## PR=$pl"
[ -e "$T/suite-ran" ] && ok || bad "R1 the host suite did not run on a clean pack"

# ── R2a: the report header names the checklist version ──
line1=$(head -n 1 "$REPORT" 2>/dev/null)
[ "$line1" = "# Lead review lr-41-$SHA12 (example-org/cromford#41 at $SHA)" ] && ok || bad "R2a line 1: $line1"
after=$(awk 'p {print; exit} /^- reviewer model: stub-model$/ {p=1}' "$REPORT" 2>/dev/null)
[ "$after" = "- checklist: v$CKV" ] && ok || bad "R2a line after reviewer model: '$after'"

# ── R2b: an OLD report (no checklist / rules pack line) still replays ──
reset; mkdir -p "$H/state/lead-reviews"
printf '# Lead review %s (%s#%s at %s)\n\n- verdict: MERGE\n- host suite: bash t.sh rc=0\n- reviewer model: old-model\n\nFindings\n- none\n\nVERDICT: MERGE\n' \
  "lr-41-$SHA12" example-org/cromford 41 "$SHA" > "$REPORT"
tick
[ "$(agents)" = 0 ] && ok || bad "R2b agent called $(agents) time(s) on a paid-already report"
has '/result .*"outcome":"done".*"verdict":"MERGE".*"reviewer_model":"old-model"' && ok || bad "R2b replay result: $(wlog | grep result)"
has '^PATCH /api/jobs/job-7 .*"status":"done"' && ok || bad "R2b job not done"
[ -s "$T/log/pack" ] && bad "R2b the pack re-ran on a replay" || ok

# ── R3a: the Closes #42 thread is in the prompt, in order ──
reset; tick
grep -qx '## Ticket thread' "$P1" 2>/dev/null && ok || bad "R3a no ## Ticket thread section"
th=$(section '## Ticket thread' '## Scope notes')
grep -q 'spec text' <<<"$th" && ok || bad "R3a thread lacks the issue body: $th"
grep -q '^#42 The ask' <<<"$th" && ok || bad "R3a thread lacks '#42 The ask'"
a=$(grep -n 'first-comment-body' <<<"$th" | cut -d: -f1); b=$(grep -n 'second-comment-body' <<<"$th" | cut -d: -f1)
[ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ] && ok || bad "R3a comments missing or out of order ($a,$b)"
grep -q '^### client at 2026-09-29T11:00:00Z$' <<<"$th" && ok || bad "R3a comment header shape"
tl=$(grep -n '^## Ticket thread$' "$P1" | cut -d: -f1); pl=$(grep -n '^## PR$' "$P1" | cut -d: -f1)
[ -n "$tl" ] && [ -n "$pl" ] && [ "$tl" -gt "$pl" ] && ok || bad "R3a thread is not after ## PR"
[ "$(grep -cE 'issues/42( |$)' "$T/log/gh" 2>/dev/null)" = 1 ] && [ "$(grep -c 'issues/42/comments?per_page=100' "$T/log/gh" 2>/dev/null)" = 1 ] \
  && ok || bad "R3a gh reads: $(grep issues "$T/log/gh" 2>/dev/null)"
has '/result .*"outcome":"done"' && ok || bad "R3a no done result"

# ── R3b: a failed thread read says so and the review still runs ──
reset; : > "$T/issuefail"; tick
grep -qF '(the ticket thread could not be read: HTTP 502)' "$P1" 2>/dev/null && ok || bad "R3b prompt: $(section '## Ticket thread' '## Scope notes' 2>/dev/null)"
grep -q 'spec text' "$P1" 2>/dev/null && bad "R3b a partial thread was printed" || ok
[ "$(agents)" = 1 ] && ok || bad "R3b agent count $(agents)"
has '/result .*"outcome":"done"' && [ -s "$REPORT" ] && ok || bad "R3b not finished"

# ── R3c: over the cap, keep the head and the tail, mark the middle cut ──
reset; export LEAD_REVIEW_THREAD_MAX_BYTES=1000
big="$(head -c 5000 /dev/zero | tr '\0' 'x')NEWEST-END"
jq -nc --arg b "$big" '[{user:{login:"operator"},created_at:"2026-09-29T10:00:00Z",body:"first-comment-body"},
                         {user:{login:"client"},created_at:"2026-09-29T11:00:00Z",body:$b}]' > "$T/comments.json"
tick
th=$(section '## Ticket thread' '## Scope notes')
grep -q '^(ticket thread cut: ' <<<"$th" && ok || bad "R3c no cut marker"
grep -q 'LEAD_REVIEW_THREAD_MAX_BYTES=1000)' <<<"$th" && ok || bad "R3c marker does not name the cap"
grep -q 'spec text' <<<"$th" && ok || bad "R3c the spec head was dropped"
grep -q 'NEWEST-END' <<<"$th" && ok || bad "R3c the newest tail was dropped"
kept=$(grep -v '^(ticket thread cut: ' <<<"$th" | wc -c)
[ "$kept" -le 1010 ] && ok || bad "R3c thread kept $kept bytes past a 1000-byte cap"

# ── R3d: no Closes line = no reads, and the prompt says so ──
reset; echo 'PR body text, no ticket named.' > "$T/prbody"; tick
grep -qF '(no Closes #<n> line in the PR body)' "$P1" 2>/dev/null && ok || bad "R3d prompt lacks the no-Closes line"
grep -q 'issues/' "$T/log/gh" 2>/dev/null && bad "R3d read an issue with no Closes line" || ok
# another repo's Closes is not this ticket
reset; echo 'Closes other-org/other#42' > "$T/prbody"; tick
grep -q 'issues/' "$T/log/gh" 2>/dev/null && bad "R3d read a thread for another repo's Closes" || ok
grep -qF '(no Closes #<n> line in the PR body)' "$P1" 2>/dev/null && ok || bad "R3d foreign Closes not reported as none"
# the same repo named in full (any case) is this ticket
reset; echo 'closes example-org/Cromford#42' > "$T/prbody"; tick
grep -q 'spec text' "$P1" 2>/dev/null && ok || bad "R3d owner/repo#n for this repo was not read"

# ── R4: pack rc 1 = a BLOCK with no agent call and no suite ──
r4() {
  reset; echo 1 > "$T/pack.rc"; echo 'ratchet-x: bin/foo.sh:3 bad default' > "$T/pack.stdout"; tick
}
r4
[ "$RC" -eq 0 ] && ok || bad "R4 rc=$RC out=$(cat "$T/out")"
[ -f "$T/log/agent-count" ] && bad "R4 the agent was called on a rules-pack red" || ok
order=$(wlog | awk '
  /^POST \/api\/lead-reviews\/lr-1\/result .*"outcome":"done"/ && /"verdict":"BLOCK"/ && /"reviewer_model":"rules-pack"/ {print "result"}
  /^PATCH \/api\/jobs\/job-7 .*"status":"done"/ {print "done"}' | paste -sd' ')
[ "$order" = "result done" ] && ok || bad "R4 worker order '$order': $(wlog | grep -e result -e PATCH)"
for l in '- verdict: BLOCK' '- rules pack: red' '- reviewer model: rules-pack' '- [BLOCK] ratchet-x: bin/foo.sh:3 bad default'; do
  grep -qxF -- "$l" "$REPORT" 2>/dev/null && ok || bad "R4 report lacks '$l'"
done
[ "$(awk 'NF {l=$0} END {print l}' "$REPORT" 2>/dev/null)" = "VERDICT: BLOCK" ] && ok || bad "R4 report last line"
grep -q '^- checklist:\|^- host suite:' "$REPORT" 2>/dev/null && bad "R4 report claims a checklist or suite that never ran" || ok
[ -e "$T/suite-ran" ] && bad "R4 the host suite ran after a rules-pack red" || ok

# R4b: rc 1 with no finding line is still a BLOCK
reset; echo 1 > "$T/pack.rc"; tick
[ "$(agents)" = 0 ] && ok || bad "R4b agent called $(agents) time(s)"
has '/result .*"verdict":"BLOCK".*"reviewer_model":"rules-pack"' && ok || bad "R4b not a BLOCK: $(wlog | grep result)"
grep -q '^- \[BLOCK\] rules pack exited 1 with no finding line' "$REPORT" 2>/dev/null && ok || bad "R4b no synthetic finding"

# R4c: a failed result post, then the retry replays the BLOCK with no pack or agent
reset; echo 1 > "$T/pack.rc"; echo 'ratchet-x: bin/foo.sh:3 bad default' > "$T/pack.stdout"; : > "$T/result500"; tick
has '^PATCH /api/jobs/job-7 .*"status":"done"' && bad "R4c job done without a result" || ok
rm -f "$T/result500"; echo queued_for_retry > "$T/jobstate"; tick
[ "$(agents)" = 0 ] && ok || bad "R4c agent called on the retry"
[ "$(wc -l < "$T/log/pack")" = 1 ] && ok || bad "R4c pack ran $(wc -l < "$T/log/pack") times across two ticks"
[ "$(wlog | grep -c '/result .*"outcome":"done".*"verdict":"BLOCK".*"reviewer_model":"rules-pack"')" = 2 ] \
  && ok || bad "R4c the retry did not re-post BLOCK/rules-pack"
[ "$(cat "$T/jobstate")" = "done" ] && ok || bad "R4c job not done after the replay"

# ── R10 (BH-5793): an ENVIRONMENT failure in the pack is review-failed, never a BLOCK ──
# "repo setup failed" (a suite's own scratch repo) and a suite the PR head does
# not carry are not findings about the code. The request is failed with a
# `review-failed: env:` detail that bin/lead-review-land.sh requeues, no
# verdict is recorded, and no model is paid.
for envline in 'gh-graphql-reads-lint: FAIL: 3 (x): repo setup failed' \
               'rules-pack: suite missing at the PR head: tests/new-suite.bh-9999-test.sh' \
               'share-mirror-clean: bash: tests/share-mirror-clean-test.sh: No such file or directory'; do
  reset; echo 1 > "$T/pack.rc"; printf '%s\n' "$envline" > "$T/pack.stdout"; tick
  has '/result .*"verdict":"BLOCK"' && bad "R10 an env-only pack red wrote a BLOCK ($envline): $(wlog | grep result)" || ok
  has '/result .*"outcome":"failed".*"detail":"review-failed: env: ' && ok \
    || bad "R10 no review-failed env result ($envline): $(wlog | grep result)"
  [ "$(agents)" = 0 ] && ok || bad "R10 the agent was called on an env-only pack red ($envline)"
  [ -e "$T/suite-ran" ] && bad "R10 the host suite ran after an env-only pack red" || ok
done
# R11: a real finding beside an env line is still a BLOCK, on the real finding only
reset; echo 1 > "$T/pack.rc"
printf '%s\n' 'ratchet-x: bin/foo.sh:3 bad default' 'gh-graphql-reads-lint: FAIL: 3 (x): repo setup failed' > "$T/pack.stdout"; tick
has '/result .*"outcome":"done".*"verdict":"BLOCK".*"reviewer_model":"rules-pack"' && ok || bad "R11 a real finding is still a BLOCK: $(wlog | grep result)"
grep -qxF -- '- [BLOCK] ratchet-x: bin/foo.sh:3 bad default' "$REPORT" 2>/dev/null && ok || bad "R11 the real finding is in the report"
grep -q '^- \[BLOCK\].*repo setup failed' "$REPORT" 2>/dev/null && bad "R11 the env line was reported as a BLOCK finding" || ok
grep -q '^- \[NOTE\] .*repo setup failed' "$REPORT" 2>/dev/null && ok || bad "R11 the env line is a NOTE in the report"

# ── R5: pack rc 0 = clean, one call, the lane env intact ──
reset; tick
[ "$(agents)" = 1 ] && ok || bad "R5 agent count $(agents)"
rp=$(section '## Rules pack' '## Host suite' | awk 'NF')
[ "$rp" = clean ] && ok || bad "R5 rules pack section '$rp'"
grep -qx -- '- rules pack: clean' "$REPORT" 2>/dev/null && ok || bad "R5 report lacks '- rules pack: clean'"
hdr=$(sed -n '3,7p' "$REPORT" 2>/dev/null | sed 's/:.*//' | paste -sd'|')
[ "$hdr" = "- verdict|- host suite|- rules pack|- reviewer model|- checklist" ] && ok || bad "R5 header order '$hdr'"
grep -qx 'AGENT_CALL_ROLE=lead.review' "$T/log/agent-env" 2>/dev/null && grep -qx 'AGENT_CALL_LANE=lead-review' "$T/log/agent-env" \
  && ok || bad "R5 agent env: $(cat "$T/log/agent-env" 2>/dev/null)"
grep -qE "^--tree $H/tmp/lead-review-lr-41-$SHA12-[0-9]+ --base origin/main --out $H/tmp/lead-review-lr-41-$SHA12-[0-9]+\.rp$" "$T/log/pack" 2>/dev/null \
  && ok || bad "R5 pack argv: $(cat "$T/log/pack" 2>/dev/null)"

# ── R6: pack rc 125 = could not run, stderr tail, the review still runs ──
reset; echo 125 > "$T/pack.rc"; tick
[ "$(agents)" = 1 ] && ok || bad "R6 agent count $(agents)"
rp=$(section '## Rules pack' '## Host suite')
grep -qx 'could not run (rc 125)' <<<"$rp" && grep -qx 'boom' <<<"$rp" && ok || bad "R6 rules pack section: $rp"
grep -qx -- '- rules pack: could not run (rc 125)' "$REPORT" 2>/dev/null && ok || bad "R6 report header"

# ── R7: no bin/rules-pack.sh on this box ──
reset; rm -f "$H/bin/rules-pack.sh"; tick
[ "$(agents)" = 1 ] && ok || bad "R7 agent count $(agents)"
[ "$(section '## Rules pack' '## Host suite' | awk 'NF')" = 'not installed on this box' ] && ok || bad "R7 prompt"
grep -qx -- '- rules pack: not installed on this box' "$REPORT" 2>/dev/null && ok || bad "R7 report header"
[ -s "$T/log/pack" ] && bad "R7 a pack ran" || ok

# ── R8: another repo = not applicable, the pack never runs ──
reset; echo "$OSHA" > "$T/livehead"; setreqs "$(req lr-2 example-org/other 5 "$OSHA")"; echo 1 > "$T/pack.rc"; tick
[ -s "$T/log/pack" ] && bad "R8 the pack ran for example-org/other" || ok
[ "$(agents)" = 1 ] && ok || bad "R8 agent count $(agents)"
[ "$(section '## Rules pack' '## Host suite' | awk 'NF')" = 'not applicable to example-org/other' ] && ok || bad "R8 prompt"

# ── R9: the checklist is a required module ──
reset; rm -f "$H/prompts/lead-review-checklist.md"; tick
[ "$RC" -eq 0 ] && ok || bad "R9 rc=$RC"
grep -q 'missing prompts/lead-review-checklist.md; lead-review tick skipped' "$H/logs/lead-review.log" 2>/dev/null \
  && ok || bad "R9 log: $(cat "$H/logs/lead-review.log" 2>/dev/null)"
has '/claim' && bad "R9 claimed without the checklist" || ok

# ── M1: remove the return after the rules-pack finish_done; R4 must go red ──
reset
sed 's/; return  *\(# rules-pack BLOCK: no agent call\)/ \1/' "$DIR/bin/lead-review.sh" > "$T/mut.sh"
if cmp -s "$T/mut.sh" "$DIR/bin/lead-review.sh"; then
  bad "M1 the mutation anchor '# rules-pack BLOCK: no agent call' is missing"
else
  echo 1 > "$T/pack.rc"; echo 'ratchet-x: bin/foo.sh:3 bad default' > "$T/pack.stdout"
  cp "$T/mut.sh" "$H/bin/lead-review.sh"; tick
  [ "$(agents)" -ge 1 ] && ok || bad "M1 R4 stayed green with the return removed (agent count $(agents))"
fi
cp "$DIR/bin/lead-review.sh" "$H/bin/"

[ "$(( $(date +%s) - NOW ))" -ge 0 ] || bad "clock went backwards"
echo "lead-review-rules-pack: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
