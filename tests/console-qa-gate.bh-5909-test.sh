#!/bin/bash
# tests/console-qa-gate.bh-5909-test.sh — BH-5909 slice 2: the lead gate for
# console UI changes. A harness PR that changes console-ui/src/ with no QA: PASS
# comment naming its head gets a lead BLOCK that names the head and the missing
# comment, and a QA: PASS posted later clears it with no push (cqg_clear_block,
# Q9; the hub reconcile sweep that calls it is pinned by
# tests/lead-hub-reconcile.bh-7235-test.sh Q1-Q2).
#   Q1-Q9   bin/lib/console-qa-gate.sh itself, with gh_rest, _jobs_req and
#           lr_post_lead as shell stubs
#   L1-L5   the REAL bin/lead-review.sh tick, built the way
#           tests/lead-review-rules-pack.bh-3546-test.sh builds it (curl, gh,
#           agent-call and rules-pack stubbed)
#   B1-B2   the REAL br_lead_pick, lifted from bin/blocked-resolver.sh the way
#           tests/lead-block-fix-round.bh-3780-test.sh lifts it
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/console-qa-gate.bh-5909-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
export LEAD_REVIEW_MAX_PER_PR_DAY=50
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
LIB="$DIR/bin/lib/console-qa-gate.sh"
HR=example-org/cromford
HEAD=$(printf 'a%.0s' {1..40}); OTHER=$(printf 'b%.0s' {1..40})

# ── comment fixtures ──
# cm <login> <type> <assoc> <body> — one REST issue comment
cm() { jq -nc --arg l "$1" --arg t "$2" --arg a "$3" --arg b "$4" --arg u "https://github.com/$HR/pull/7#issuecomment-$(printf '%s%s' "$1" "$4" | cksum | cut -d' ' -f1)" \
  '{user:{login:$l,type:$t},author_association:$a,body:$b,html_url:$u}'; }
LANE_BODY() { # the comment bin/console-preview-deploy.sh posts for <sha> <result>
  printf 'Console preview: https://bh-7.console.example.pages.dev\n\n```\nSCREEN / 1440 ok\nSCREEN / 390 ok\nQA COVERAGE: screens=1 flows=0 shots=2\nQA: %s\n```\n\nQA: %s for head %s. Screenshots: state/console-preview-qa/7-x on the hub.\n<!-- console-preview sha=%s url=https://bh-7.console.example.pages.dev -->\n<!-- console-qa sha=%s result=%s -->\n' \
    "$2" "$2" "$1" "$1" "$1" "$2"
}
HAND_BODY() { printf 'Browser QA at 1440 and 390.\nQA COVERAGE: screens=%s flows=1 shots=%s\nQA: PASS for head %s\n' "$2" "$3" "$1"; }

# ── Q: the lib, with stubs ──
Q="$T/q"; mkdir -p "$Q/state"
cat > "$Q/stubs.sh" <<EOF
export HARNESS_SELF_APPS=cromford
gh_rest() {
  echo "\$*" >> "$Q/gh.log"
  [ -e "$Q/ghfail" ] && { GH_REST_STATUS=502; return 1; }
  case "\$2" in
    */issues/*/comments*) cat "$Q/comments.json" ;;
    *) return 75 ;;
  esac
}
_jobs_req() { echo "\$*" >> "$Q/jobs.log"; cat "$Q/standing.json"; }
lr_post_lead() { echo "\$*" >> "$Q/reset.log"; [ -e "$Q/resetfail" ] && return 1; echo '{"request":{"status":"requested"}}'; }
EOF
qrun() { bash -c '. "$1"; . "$2"; shift 2; "$@"' _ "$Q/stubs.sh" "$LIB" "$@" 2>/dev/null; }
qreset() { rm -f "$Q"/*.log "$Q/ghfail" "$Q/resetfail"; scratch_rm "$Q/state"; mkdir -p "$Q/state"; echo '[]' > "$Q/comments.json"; }
comments() { printf '%s\n' "$@" | jq -sc . > "$Q/comments.json"; }
first() { awk '{print $1}' <<<"$1"; }

[ -f "$LIB" ] && ok || bad "Q0 bin/lib/console-qa-gate.sh does not exist"

# Q1: no comment -> MISSING
qreset
[ "$(qrun cqg_head_verdict "$HR" 7 "$HEAD")" = MISSING ] && ok || bad "Q1 no comment: $(qrun cqg_head_verdict "$HR" 7 "$HEAD")"
# Q2: the lane's own comment (the App, author_association NONE) for this head -> PASS <url>
qreset; comments "$(cm 'cromford[bot]' Bot NONE "$(LANE_BODY "$HEAD" PASS)")"
v=$(qrun cqg_head_verdict "$HR" 7 "$HEAD")
[ "$(first "$v")" = PASS ] && grep -q 'issuecomment-' <<<"$v" && ok || bad "Q2 the lane's PASS comment: '$v'"
# Q3: a writer's hand comment naming a 9-hex prefix -> PASS
qreset; comments "$(cm operator User OWNER "$(HAND_BODY "${HEAD:0:9}" 2 2)")"
[ "$(first "$(qrun cqg_head_verdict "$HR" 7 "$HEAD")")" = PASS ] && ok || bad "Q3 a writer's 9-hex PASS: $(qrun cqg_head_verdict "$HR" 7 "$HEAD")"
# Q4: a PASS for another head -> STALE <sha12> <url>
qreset; comments "$(cm 'cromford[bot]' Bot NONE "$(LANE_BODY "$OTHER" PASS)")"
v=$(qrun cqg_head_verdict "$HR" 7 "$HEAD")
[ "$(awk '{print $1, $2}' <<<"$v")" = "STALE ${OTHER:0:12}" ] && ok || bad "Q4 a PASS for another head: '$v'"
# Q5: what is not a PASS: the lane's FAIL, no screenshots, no screens, an
# outsider, an 8-hex prefix, and a PASS line with a QA: FAIL line in the body
qreset; comments "$(cm 'cromford[bot]' Bot NONE "$(LANE_BODY "$HEAD" FAIL)")" \
  "$(cm operator User OWNER "$(HAND_BODY "$HEAD" 1 0)")" \
  "$(cm operator User OWNER "$(HAND_BODY "$HEAD" 0 2)")" \
  "$(cm stranger User NONE "$(HAND_BODY "$HEAD" 1 2)")" \
  "$(cm someone-bot Bot NONE "$(HAND_BODY "$HEAD" 1 2)")" \
  "$(cm operator User OWNER "$(HAND_BODY "${HEAD:0:8}" 1 2)")" \
  "$(cm operator User MEMBER "$(HAND_BODY "$HEAD" 1 2; echo 'QA: FAIL at 390')")"
[ "$(qrun cqg_head_verdict "$HR" 7 "$HEAD")" = MISSING ] && ok || bad "Q5 none of these is a PASS: $(qrun cqg_head_verdict "$HR" 7 "$HEAD")"
# Q6: an unreadable thread is COULD NOT READ, never MISSING and never PASS
qreset; touch "$Q/ghfail"
v=$(qrun cqg_head_verdict "$HR" 7 "$HEAD")
case "$v" in "COULD NOT READ:"*"HTTP 502"*) ok ;; *) bad "Q6 a failed read: '$v'" ;; esac
# Q7: cqg_verdict: another repo, or no console-ui/src/ path, is NOT-APPLICABLE with no read
qreset; printf 'console-ui/src/app.js\nbin/x.sh\n' > "$Q/files"; printf 'console-ui/functions/a.js\nbin/x.sh\n' > "$Q/files2"
[ "$(qrun cqg_verdict example-org/other 7 "$HEAD" "$Q/files" "$HR")" = NOT-APPLICABLE ] && ok || bad "Q7 another repo"
[ "$(qrun cqg_verdict "$HR" 7 "$HEAD" "$Q/files2" "$HR")" = NOT-APPLICABLE ] && ok || bad "Q7 no console-ui/src/ path"
[ -s "$Q/gh.log" ] && bad "Q7 read the thread for a NOT-APPLICABLE head: $(cat "$Q/gh.log")" || ok
[ "$(qrun cqg_verdict "$HR" 7 "$HEAD" "$Q/files" "$HR")" = MISSING ] && ok || bad "Q7 a console-ui/src/ head with no comment"
case "$(qrun cqg_verdict "$HR" 7 "$HEAD" "$Q/nope" "$HR")" in "COULD NOT READ:"*) ok ;; *) bad "Q7 an unreadable file list" ;; esac
# Q8: the BLOCK report names the head and the comment that clears it
qrun cqg_report "lr-7-${HEAD:0:12}" "$HR" 7 "$HEAD" MISSING "" > "$Q/report"
[ "$(head -n 1 "$Q/report")" = "# Lead review lr-7-${HEAD:0:12} ($HR#7 at $HEAD)" ] && ok || bad "Q8 report line 1: $(head -n 1 "$Q/report")"
grep -qF -- "- [BLOCK console-qa] This PR changes console-ui/src/, and no \`QA: PASS\` comment names head $HEAD." "$Q/report" && ok || bad "Q8 the BLOCK line does not name the head: $(cat "$Q/report")"
grep -qF -- "\`QA: PASS for head $HEAD\`" "$Q/report" && ok || bad "Q8 the report does not name the comment that clears it"
grep -qF 'No push is needed.' "$Q/report" && ok || bad "Q8 the report does not say no push is needed"
[ "$(awk 'NF' "$Q/report" | tail -n 1)" = "VERDICT: BLOCK" ] && ok || bad "Q8 the report does not end VERDICT: BLOCK"
grep -q '^- reviewer model: console-qa-gate$' "$Q/report" && ok || bad "Q8 reviewer model line"
qrun cqg_report k "$HR" 7 "$HEAD" "STALE ${OTHER:0:12} https://x/1" "" | grep -qF "names head ${OTHER:0:12} (https://x/1), not this head" \
  && ok || bad "Q8 a STALE report must name the head the old PASS is for"
# Q9: cqg_clear_block resets the gate BLOCK's request once a PASS names the head, once
GATE_ROW=$(jq -nc '{standing:{verdict:"BLOCK",source:"lead",reviewer_model:"console-qa-gate",note:"lead-review:lr-9 lead-job:job-3 report:x"}}')
qreset; echo "$GATE_ROW" > "$Q/standing.json"
qrun cqg_clear_block "$HR" 7 "$HEAD" "$Q/state" >/dev/null; rc=$?
[ "$rc" = 1 ] && [ ! -s "$Q/reset.log" ] && ok || bad "Q9a no PASS yet: no reset (rc $rc): $(cat "$Q/reset.log" 2>/dev/null)"
comments "$(cm 'cromford[bot]' Bot NONE "$(LANE_BODY "$HEAD" PASS)")"
out=$(qrun cqg_clear_block "$HR" 7 "$HEAD" "$Q/state"); rc=$?
[ "$rc" = 0 ] && [ "$(cat "$Q/reset.log" 2>/dev/null)" = "/lr-9/reset {}" ] && ok || bad "Q9b PASS posted: want one reset of lr-9 (rc $rc): $(cat "$Q/reset.log" 2>/dev/null)"
grep -q "lead review lr-9 reset" <<<"$out" && grep -q "${HEAD:0:12}" <<<"$out" && ok || bad "Q9b the line: $out"
grep -q "standing_only=1" "$Q/jobs.log" && grep -q "head=$HEAD" "$Q/jobs.log" && ok || bad "Q9b the standing read: $(cat "$Q/jobs.log")"
qrun cqg_clear_block "$HR" 7 "$HEAD" "$Q/state" >/dev/null; rc=$?
[ "$rc" = 1 ] && [ "$(wc -l < "$Q/reset.log")" = 1 ] && ok || bad "Q9c the same PASS must not reset twice: $(cat "$Q/reset.log")"
qreset; echo "$GATE_ROW" > "$Q/standing.json"; comments "$(cm 'cromford[bot]' Bot NONE "$(LANE_BODY "$HEAD" PASS)")"; touch "$Q/resetfail"
out=$(qrun cqg_clear_block "$HR" 7 "$HEAD" "$Q/state"); rc=$?
[ "$rc" = 1 ] && grep -q 'reset of lead review lr-9 failed' <<<"$out" && [ -z "$(ls "$Q/state")" ] && ok || bad "Q9d a failed reset: rc $rc '$out', marker: $(ls "$Q/state")"
qreset; jq -nc '{standing:{verdict:"BLOCK",source:"lead",reviewer_model:"stub-model",note:"lead-review:lr-9"}}' > "$Q/standing.json"
comments "$(cm 'cromford[bot]' Bot NONE "$(LANE_BODY "$HEAD" PASS)")"
qrun cqg_clear_block "$HR" 7 "$HEAD" "$Q/state" >/dev/null; rc=$?
[ "$rc" = 1 ] && [ ! -s "$Q/reset.log" ] && [ ! -s "$Q/gh.log" ] && ok || bad "Q9e a model's BLOCK is never reset, and costs no thread read"
# Q10: cqg_replay_hold holds a console-ui/src/ head with no PASS, from the clone's diff
qreset; W="$T/qrepo"; git init -q -b main "$W"; echo a > "$W/a.txt"
git -C "$W" add -A; git -C "$W" -c user.email=t@t -c user.name=t commit -qm base
git -C "$W" update-ref refs/remotes/origin/main HEAD
mkdir -p "$W/console-ui/src"; echo x > "$W/console-ui/src/app.js"; git -C "$W" add -A
git -C "$W" -c user.email=t@t -c user.name=t commit -qm ui; UIH=$(git -C "$W" rev-parse HEAD)
out=$(qrun cqg_replay_hold "$HR" 7 "$UIH" "$W" origin/main "$HR"); rc=$?
[ "$rc" = 0 ] && [ "$out" = "console QA: MISSING" ] && ok || bad "Q10a hold a console head with no PASS (rc $rc '$out')"
comments "$(cm 'cromford[bot]' Bot NONE "$(LANE_BODY "$UIH" PASS)")"
qrun cqg_replay_hold "$HR" 7 "$UIH" "$W" origin/main "$HR" >/dev/null && bad "Q10b a PASS head must replay" || ok
qrun cqg_replay_hold example-org/other 7 "$UIH" "$W" origin/main "$HR" >/dev/null && bad "Q10c another repo must replay" || ok

# ============================================================================
# L — the real bin/lead-review.sh
# ============================================================================
H="$T/h"; mkdir -p "$H/bin/lib/jobs" "$H/prompts" "$H/catalog/lanes.d" "$H/state" "$T/fakebin" "$T/log" "$T/repos" "$T/tmp"
cp "$DIR/bin/box-for.sh" "$DIR/bin/fleet-conf.sh" "$H/bin/"
cp "$DIR/catalog/lanes.d/_lib.json" "$H/catalog/lanes.d/"
cp "$DIR/prompts/lead-review.md" "$DIR/prompts/lead-review-checklist.md" "$H/prompts/"
echo box-demo > "$H/state/box-name"
printf 'cromford example-org/cromford https://bh.test /api/board 1 box-demo\n' > "$H/fleet.conf"
O="$T/origin.git"; WK="$T/work"
git init -q --bare -b main "$O"; git init -q -b main "$WK"
printf '# bh\n' > "$WK/CLAUDE.md"; mkdir -p "$WK/console-ui/src"; echo one > "$WK/console-ui/src/app.js"
git -C "$WK" add -A; git -C "$WK" -c user.email=t@t -c user.name=t commit -qm base; git -C "$WK" push -q "$O" main
echo two >> "$WK/console-ui/src/app.js"; git -C "$WK" -c user.email=t@t -c user.name=t commit -qam "ui change"
git -C "$WK" push -q "$O" "HEAD:refs/pull/41/head"; git clone -q "$O" "$T/repos/cromford"
SHA=$(git -C "$WK" rev-parse HEAD); SHA12=${SHA:0:12}
git -C "$WK" checkout -q -b other HEAD~1; echo doc > "$WK/notes.md"; git -C "$WK" add -A
git -C "$WK" -c user.email=t@t -c user.name=t commit -qm "doc change"; git -C "$WK" push -q "$O" "HEAD:refs/pull/42/head"
DSHA=$(git -C "$WK" rev-parse HEAD)
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
  "POST /api/jobs") echo running > "$T/jobstate"; out='{"job":{"id":"job-7"}}' ;;
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
    jq -nc --arg s "\$(cat "$T/livehead")" '{head:{sha:\$s},base:{ref:"main"},title:"UI",body:"no ticket"}' ;;
  *"-X GET repos/"*"/issues/41/comments"*)
    if [ -e "$T/ghfail" ]; then printf 'HTTP/2 502\r\n\r\n{"message":"bad gateway"}\n'; exit 1; fi
    printf 'HTTP/2 200\r\n\r\n'; cat "$T/prcomments.json" ;;
esac
exit 0
EOF
cat > "$H/bin/agent-call.sh" <<EOF
#!/bin/bash
echo x >> "$T/log/agent-count"
printf 'Findings\n- none\n\nVERDICT: MERGE\n' > "\$5"
exit 0
EOF
cat > "$H/bin/rules-pack.sh" <<EOF
#!/bin/bash
echo "\$*" >> "$T/log/pack"
exit 0
EOF
chmod +x "$T/fakebin/curl" "$T/fakebin/gh" "$H/bin/agent-call.sh" "$H/bin/rules-pack.sh"
# The stubs above are kept: the closure install never overwrites a file.
scratch_install_closure bin/lead-review.sh "$H" >/dev/null || bad "closure of bin/lead-review.sh"
scratch_install_closure bin/jobs-client.sh "$H" >/dev/null || bad "closure of bin/jobs-client.sh"
lreset() {
  rm -f "$T/log"/* "$T"/{jobstate,ghfail} "$H/logs/lead-review.log"
  scratch_rm "$H/state/lead-reviews"
  echo "$SHA" > "$T/livehead"; echo '[]' > "$T/prcomments.json"
  jq -nc --arg s "$SHA" '{requests:[{id:"lr-1",repo:"example-org/cromford",pr:41,head_sha:$s,scope_notes:"",status:"requested",requested_by:"operator"}],truncated:false}' > "$T/requests.json"
}
ltick() { ( cd "$T" && env PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=fixture-secret JOBS_URL=https://jobs.test \
  JOBS_RETRIES=0 JOBS_BEAT_SECS=1 TMPDIR="$T/tmp" REPOS_ROOT="$T/repos" FLEET_CONF="$H/fleet.conf" \
  LANE_GATE_DISABLE=1 GH_ETAG=0 HARNESS_SELF_APPS=cromford "$@" bash "$H/bin/lead-review.sh" tick ) > "$T/out" 2>&1; RC=$?; }
agents() { [ -f "$T/log/agent-count" ] && wc -l < "$T/log/agent-count" | tr -d ' ' || echo 0; }
results() { grep '/result ' "$T/log/worker" 2>/dev/null; }
REPORT="$H/state/lead-reviews/lr-41-$SHA12.md"

# L1: gate on, no QA comment -> BLOCK, reviewer model console-qa-gate, no model
# call, no rules pack; the report names the head and the comment that clears it
lreset; ltick LEAD_REVIEW_CONSOLE_QA_GATE=1
[ "$RC" = 0 ] && ok || bad "L1 rc=$RC $(cat "$T/out")"
results | grep -q '"outcome":"done".*"verdict":"BLOCK".*"reviewer_model":"console-qa-gate"' && ok || bad "L1 want a console-qa-gate BLOCK result: $(results) log: $(tail -5 "$H/logs/lead-review.log" 2>/dev/null)"
[ "$(agents)" = 0 ] && ok || bad "L1 the model was called $(agents) time(s)"
[ -s "$T/log/pack" ] && bad "L1 the rules pack ran before the gate" || ok
grep -qF "no \`QA: PASS\` comment names head $SHA" "$REPORT" 2>/dev/null && ok || bad "L1 the report does not name the head: $(cat "$REPORT" 2>/dev/null)"
grep -q 'issues/41/comments' "$T/log/gh" && ok || bad "L1 the PR thread was not read"
# L2: gate on, the lane's PASS for this head -> the review runs as before
lreset; jq -nc --arg b "$(LANE_BODY "$SHA" PASS)" '[{user:{login:"cromford[bot]",type:"Bot"},author_association:"NONE",body:$b,html_url:"https://github.com/x/pull/41#issuecomment-1"}]' > "$T/prcomments.json"
ltick LEAD_REVIEW_CONSOLE_QA_GATE=1
[ "$(agents)" = 1 ] && ok || bad "L2 a PASS head must get its model review ($(agents) calls): $(tail -5 "$H/logs/lead-review.log" 2>/dev/null)"
results | grep -q '"verdict":"MERGE".*"reviewer_model":"stub-model"' && ok || bad "L2 result: $(results)"
# L3: gate off (the default): no thread read, the review runs as before
lreset; ltick
[ "$(agents)" = 1 ] && ok || bad "L3 gate off: the model review must run ($(agents) calls)"
grep -q 'console qa' "$H/logs/lead-review.log" 2>/dev/null && bad "L3 gate off ran the console QA check: $(grep 'console qa' "$H/logs/lead-review.log")" || ok
# L4: gate on, the thread does not read -> no result, the job fails, the request waits
lreset; touch "$T/ghfail"; ltick LEAD_REVIEW_CONSOLE_QA_GATE=1
results >/dev/null && bad "L4 an unreadable thread posted a result: $(results)" || ok
[ "$(agents)" = 0 ] && ok || bad "L4 the model was called on an unreadable thread"
grep -q 'console qa for lr-41-.* unreadable' "$H/logs/lead-review.log" && ok || bad "L4 log: $(tail -3 "$H/logs/lead-review.log")"
grep -q '"status":"failed"' "$T/log/worker" && ok || bad "L4 the job was not failed"
# L5: gate on, a PASS for an OLDER head only -> BLOCK naming that head
lreset; jq -nc --arg b "$(LANE_BODY "$OTHER" PASS)" '[{user:{login:"cromford[bot]",type:"Bot"},author_association:"NONE",body:$b,html_url:"https://github.com/x/pull/41#issuecomment-2"}]' > "$T/prcomments.json"
ltick LEAD_REVIEW_CONSOLE_QA_GATE=1
results | grep -q '"verdict":"BLOCK".*"reviewer_model":"console-qa-gate"' && grep -qF "names head ${OTHER:0:12}" "$REPORT" 2>/dev/null \
  && ok || bad "L5 a PASS for another head is a BLOCK naming it: $(cat "$REPORT" 2>/dev/null)"

# L6: gate on, a head that changes no console-ui/src/ path -> reviewed as before, no thread read
lreset; echo "$DSHA" > "$T/livehead"
jq -nc --arg s "$DSHA" '{requests:[{id:"lr-2",repo:"example-org/cromford",pr:42,head_sha:$s,scope_notes:"",status:"requested",requested_by:"operator"}],truncated:false}' > "$T/requests.json"
ltick LEAD_REVIEW_CONSOLE_QA_GATE=1
[ "$(agents)" = 1 ] && ok || bad "L6 a head with no console change must get its model review ($(agents) calls): $(tail -4 "$H/logs/lead-review.log" 2>/dev/null)"
grep -q 'console qa NOT-APPLICABLE' "$H/logs/lead-review.log" && ok || bad "L6 log: $(grep 'console qa' "$H/logs/lead-review.log")"
# L7: gate on, the lib missing -> a console head waits, a doc head is reviewed
lreset; mv "$H/bin/lib/console-qa-gate.sh" "$T/cqg.away"
ltick LEAD_REVIEW_CONSOLE_QA_GATE=1
[ "$(agents)" = 0 ] && ! results >/dev/null && ok || bad "L7 a console head with the lib missing must wait ($(agents) calls): $(results)"
lreset; echo "$DSHA" > "$T/livehead"
jq -nc --arg s "$DSHA" '{requests:[{id:"lr-2",repo:"example-org/cromford",pr:42,head_sha:$s,scope_notes:"",status:"requested",requested_by:"operator"}],truncated:false}' > "$T/requests.json"
ltick LEAD_REVIEW_CONSOLE_QA_GATE=1
[ "$(agents)" = 1 ] && ok || bad "L7 a doc head with the lib missing must still be reviewed ($(agents) calls)"
mv "$T/cqg.away" "$H/bin/lib/console-qa-gate.sh"

# ============================================================================
# B — the blocked-resolver briefs no fix round from a console-qa BLOCK
# ============================================================================
# Lifted straight from the lane's source; the lane itself never runs here.
BRSRC="$DIR/bin/blocked-resolver.sh"
plift() { awk -v n="$1" '$0 ~ "^"n"\\(\\) \\{" {f=1} f{print} f&&/^}/{exit}' "$BRSRC"; }
{ grep -E '^(BR_REVIEW_FOOTER|BR_LEAD_HDR)=' "$BRSRC"; plift br_lead_merges_only; plift br_lead_pick; } > "$T/pick.sh"
PH="$T/ph"; mkdir -p "$PH/env" "$PH/logs" "$PH/state/gh-etag"
printf 'gh_rest() { return 75; }\n' > "$T/pick-stubs.sh"
PICK_RC() { HARNESS="$PH" bash -c '. "$1/bin/lib/gh-pr-list.sh"; . "$2"; . "$3"; br_lead_pick o/demo "$4" "$5"' \
  _ "$DIR" "$T/pick-stubs.sh" "$T/pick.sh" "$1" "$2" >/dev/null 2>&1; echo $?; }
ROW() { jq -nc --arg c "$1" --arg b "$2" '[{l:"cromford[bot]",t:"Bot",a:"NONE",c:$c,s:"CHANGES_REQUESTED",b:$b}]'; }
QB=$(printf '<!-- lead-review:lr-9 -->\nLead review (automated lead-review lane, console-qa-gate) of %s\n\n%s' "${HEAD:0:12}" "$(cat "$Q/report")")
[ "$(PICK_RC "$HEAD" "$(ROW "$HEAD" "$QB")")" = 1 ] && ok || bad "B1 a console-qa BLOCK must brief no fix round"
MB=$(printf '<!-- lead-review:lr-8 -->\nLead review of %s\n\nFindings\n- [BLOCK] a.sh:3: the loop never stops\n\nVERDICT: BLOCK\n' "${HEAD:0:12}")
[ "$(PICK_RC "$HEAD" "$(ROW "$HEAD" "$MB")")" = 0 ] && ok || bad "B2 a model's lead BLOCK must still brief a fix round"

echo "console-qa-gate.bh-5909: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
