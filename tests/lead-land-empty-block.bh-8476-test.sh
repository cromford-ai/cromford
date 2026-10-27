#!/bin/bash
# tests/lead-land-empty-block.bh-8476-test.sh — BH-8476: a lead BLOCK whose
# report has no `- [BLOCK` line is INCONCLUSIVE. The hub land lane reads the
# report BEFORE it posts a BLOCK row. An empty one posts no row and no status,
# re-requests the review once per head and alerts. A row that already stands
# is retracted with `bin/lead-verdict.sh retract <id> --reason empty-report`,
# which republishes lead-verdict from the newest remaining row.
#
# Part E runs the REAL bin/lead-review-land.sh against a scratch harness
# (scratch_install_closure), with curl (the jobs worker), gh and
# bin/lane-alert.sh stubbed:
#   E1  first empty BLOCK: 0 verdict posts, 0 statuses, 1 reset, the log line,
#       the lead_empty_block ledger row (no state/ file), 1 ALERTS line, a
#       400-byte capture of a 1000-byte report
#   E2  the re-review is empty again: no second reset, stamped, alerted
#   E3  a report with a `- [BLOCK]` line posts as before
#   E4  a MERGE with no finding line posts as before
#   E5  the artifact answers 500: nothing posted, reset or stamped
#   E6  the PR head moved: nothing posted or reset, stamped
#   E7  the reset answers 409: no ledger row, no stamp; the next tick resets once
#   E8  second empty, ALERTS.log not writable: not stamped
#   ET  the decision table (a)-(n) of the plan's Failure modes
#   E9  LEAD_REVIEW_EMPTY_CAPTURE_BYTES=0: no capture file
#   E10 captures older than LEAD_REVIEW_EMPTY_KEEP_DAYS go
#   E11 a retracted row of this request is absent: the lane posts a new row
#   E12 an empty BLOCK row an earlier tick recorded: no review, no reset, the
#       alert names `bin/lead-verdict.sh retract <row>`, stamped
#   E13 the lead_empty_block ledger answers 500: nothing reset, posted or stamped
# Part R runs the REAL bin/lead-verdict.sh retract:
#   R1  #1 BLOCK lead retracted, #2 MERGE human stands: status success
#   R2  only #1: status pending
#   R3  the standing row is a withheld lead MERGE: status pending
#   R4  the worker refuses (409): exit 1, no status
#   R5  a bad reason or id: exit 2, no worker call
#   R6  the status POST fails: exit 4
# The worker half (route, standing filter, EXPLAIN) is
# worker/jobs/test/verdict-retract.bh-8476.test.js, which serves
# worker/jobs/src/routes/verdict-retractions.js; Part W runs it when node is here.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-land-empty-block.bh-8476-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lpp-stub.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
DIR="$SRC"
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
worker_catalogs "$DIR" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }
unset BOX_NAME JOBS_BOX LEAD_REVIEW_OVERDUE_MIN HUB_BOX_NAME LEAD_REVIEW_SPOTCHECK_PCT
unset LEAD_REVIEW_EMPTY_CAPTURE_BYTES LEAD_REVIEW_EMPTY_KEEP_DAYS LEAD_REVIEW_LAND_RERUN_MAX

POSTSCRIPT='The monitor expired after it delivered all 10 results, so I do not need it again. The review above is final and does not change.

VERDICT: BLOCK'

L="$T/l"; HL="$L/h"; ST="$HL/state/lead-review-land"
mkdir -p "$HL/state" "$HL/logs" "$HL/catalog" "$L/fakebin" "$L/log" "$L/tmp" "$L/cfg"
scratch_install_closure bin/lead-review-land.sh "$HL" >/dev/null || bad "closure of bin/lead-review-land.sh"
scratch_install_closure bin/lead-verdict.sh "$HL" >/dev/null || bad "closure of bin/lead-verdict.sh"
scratch_install_closure bin/jobs-client.sh "$HL" >/dev/null || bad "closure of bin/jobs-client.sh"
lpp_install "$L/fakebin" "$L/lpp.json" "$L/lpp-down"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"\nexit 0\n' "$L/log/alerts" > "$HL/bin/lane-alert.sh"
chmod +x "$HL/bin/lane-alert.sh"
echo box-hub > "$HL/state/box-name"
printf 'lead-test-token-fixture\n' > "$L/cfg/token"; chmod 600 "$L/cfg/token"
LSHA=$(printf 'a%.0s' {1..40}); OSHA=$(printf 'b%.0s' {1..40}); SLUG=example-org/demo-os
# The once-per-head re-request marker: a lead_empty_block ledger row (BH-4159:
# no new state/ file). The stub worker keeps ledger rows in ledger.json.
MARK="$SLUG#7@$LSHA"
CAP="$HL/logs/lead-review-empty/lr-1.txt"

# The jobs worker. Rows live in vrows.json; a retraction sets retracted_at.
cat > "$L/fakebin/curl" <<'EOF'
#!/bin/bash
m=GET; body=""; url=""; prev=""; hdrs=""
for a in "$@"; do
  case "$prev" in
    -X) m="$a" ;;
    --data-binary) body="$a" ;;
    -H) case "$a" in @*) hdrs="$hdrs$(cat "${a#@}")"$'\n' ;; *) hdrs="$hdrs$a"$'\n' ;; esac ;;
  esac
  case "$a" in http*) url="$a" ;; esac
  prev="$a"
done
case "$body" in @*) body=$(cat "${body#@}") ;; esac
lead=0; grep -q '^x-lead-verdict-token: lead-test-token-fixture' <<<"$hdrs" && lead=1
p="${url#https://jobs.test}"
printf '%s %s %s lead=%s\n' "$m" "$p" "$body" "$lead" >> "@L@/log/worker"
[ -f "@L@/vrows.json" ] || echo '[]' > "@L@/vrows.json"
qp() { printf '%s' "${p#*\?}" | tr '&' '\n' | sed -n "s/^$1=//p" | head -1; }
code=200; out='{}'
case "$m $p" in
  *"/api/lead-protected-paths"*) lpp-answer "$m" "$url" "$body"; exit 0 ;;
  "GET /api/ledger?"*)
    [ -f "@L@/ledger.json" ] || echo '{}' > "@L@/ledger.json"
    k=$(qp kind); v=$(qp key); v=$(printf '%b' "${v//%/\\x}")
    if [ -f "@L@/ledger-code" ]; then code=$(cat "@L@/ledger-code"); out='{"error":"d1 overloaded"}'
    else
      out=$(jq -c --arg k "$k" --arg v "$v" '.[$k + " " + $v] // empty | {ledger:.}' "@L@/ledger.json")
      [ -n "$out" ] || { code=404; out='{"error":"not found"}'; }
    fi ;;
  "PUT /api/ledger")
    [ -f "@L@/ledger.json" ] || echo '{}' > "@L@/ledger.json"
    jq -c --argjson r "$body" '. + {($r.kind + " " + $r.key): $r}' "@L@/ledger.json" > "@L@/ledger.tmp" && mv "@L@/ledger.tmp" "@L@/ledger.json"
    out=$(jq -c '{ledger:.}' <<<"$body") ;;
  "GET /api/lead-reviews"*) out=$(cat "@L@/requests.json") ;;
  "POST /api/lead-reviews/"*/promoted)
    if [ "$lead" != 1 ]; then code=403; out='{"error":"needs the lead token"}'
    else out='{"request":{"promoted_verdict_at":"2026-10-26T00:00:00Z"}}'; fi ;;
  "POST /api/lead-reviews/"*/reset)
    code=$(cat "@L@/reset-code" 2>/dev/null || echo 200)
    if [ "$lead" != 1 ]; then code=403; out='{"error":"needs the lead token"}'
    elif [ "$code" = 200 ]; then out='{"request":{"id":"lr-1","status":"requested","reset_count":1}}'
    else out='{"error":"the request is running"}'; fi ;;
  "GET /api/jobs/"*/artifacts)
    j="${p#/api/jobs/}"; j="${j%/artifacts}"
    if [ -f "@L@/art-code-$j" ]; then code=$(cat "@L@/art-code-$j"); out='{"error":"d1 overloaded"}'
    elif [ -f "@L@/artifacts-$j.json" ]; then out=$(cat "@L@/artifacts-$j.json")
    else out='{"artifacts":[]}'; fi ;;
  "POST /api/verdicts")
    n=$(jq 'map(.id) | max // 0' "@L@/vrows.json")
    row=$(jq -c --argjson id "$((n + 1))" '. + {id:$id, created_at:"2026-10-26T00:00:00Z"}' <<<"$body")
    jq -c --argjson r "$row" '. + [$r]' "@L@/vrows.json" > "@L@/vrows.tmp" && mv "@L@/vrows.tmp" "@L@/vrows.json"
    code=201; out=$(jq -c '{verdict:.}' <<<"$row") ;;
  "POST /api/verdicts/"*/retract)
    vid="${p#/api/verdicts/}"; vid="${vid%/retract}"
    row=$(jq -c --argjson i "$vid" 'map(select(.id == $i)) | first // empty' "@L@/vrows.json")
    if [ "$lead" != 1 ]; then code=403; out='{"error":"needs the lead token"}'
    elif [ -z "$row" ]; then code=404; out='{"error":"no such verdict"}'
    elif [ "$(jq -r '.source + " " + .verdict' <<<"$row")" != "lead BLOCK" ]; then code=409; out='{"error":"only a lead BLOCK row can be retracted"}'
    elif [ "$(jq -r '.retracted_at // ""' <<<"$row")" != "" ]; then
      out=$(jq -c --arg r "$(jq -r .reason <<<"$body")" '{retraction:{verdict_id:.id, reason:.retract_reason, created_at:.retracted_at}, verdict:., existing:true}' <<<"$row")
    else
      jq -c --argjson i "$vid" --arg r "$(jq -r .reason <<<"$body")" \
        'map(if .id == $i then . + {retracted_at:"2026-10-26T01:00:00Z", retract_reason:$r} else . end)' "@L@/vrows.json" > "@L@/vrows.tmp" && mv "@L@/vrows.tmp" "@L@/vrows.json"
      code=201; out=$(jq -c --arg r "$(jq -r .reason <<<"$body")" '{retraction:{verdict_id:.id, reason:$r, created_at:"2026-10-26T01:00:00Z"}, verdict:., existing:false}' <<<"$row")
    fi ;;
  "GET /api/verdicts?"*)
    out=$(jq -c --arg r "$(qp repo)" --argjson pr "$(qp pr)" --arg h "$(qp head)" '
      [.[] | select(.repo == $r and .pr == $pr)] | sort_by(-.id) as $rows
      | {repo:$r, pr:$pr, head:$h,
         standing:([$rows[] | select(.head_sha == $h and (.source == "lead" or .source == "human") and (.retracted_at // null) == null)] | first),
         rows:[$rows[] | {retracted_at:null, retract_reason:null} + .], truncated:false}' "@L@/vrows.json") ;;
  *) code=404; out='{"error":"unknown endpoint","worker":"harness-jobs"}' ;;
esac
printf '%s\n%s' "$out" "$code"
EOF
cat > "$L/fakebin/gh" <<'EOF'
#!/bin/bash
m=GET; path=""; prev=""; ev=""; cid=""; body=""; st=""
for a in "$@"; do
  case "$prev" in
    -X) m="$a" ;;
    -f|-F) v="${a#*=}"; case "$v" in @*) v=$(cat "${v#@}") ;; esac
           case "${a%%=*}" in event) ev="$v" ;; commit_id) cid="$v" ;; body) body="$v" ;; state) st="$v" ;; esac ;;
  esac
  case "$a" in repos/*) path="$a" ;; esac
  prev="$a"
done
printf '%s %s event=%s commit_id=%s state=%s\n' "$m" "$path" "$ev" "$cid" "$st" >> "@L@/log/gh"
reply() { printf 'HTTP/1.1 %s X\r\n\r\n%s\n' "$1" "$2"; exit 0; }
n=$(printf '%s' "$path" | sed -nE 's#^repos/[^/]+/[^/]+/pulls/([0-9]+).*#\1#p')
rf="@L@/reviews-$n.json"
case "$m $path" in
  "POST repos/"*"/pulls/"*"/reviews")
    [ -f "$rf" ] || echo '[]' > "$rf"
    jq -c --arg c "$cid" --arg b "$body" \
      '. + [{id:(length + 1), user:{login:"cromford[bot]",type:"Bot"}, author_association:"NONE", commit_id:$c, state:"CHANGES_REQUESTED", body:$b}]' \
      "$rf" > "$rf.tmp" && mv "$rf.tmp" "$rf"
    reply 200 '{"id":1}' ;;
  "GET repos/"*"/pulls/"*"/reviews"*)
    case "$path" in *"page=1"|*"page=1&"*) ;; *) reply 200 '[]' ;; esac
    if [ -f "$rf" ]; then reply 200 "$(cat "$rf")"; else reply 200 '[]'; fi ;;
  "GET repos/"*"/pulls/"*)
    reply 200 "{\"head\":{\"sha\":\"$(cat "@L@/livehead")\",\"ref\":\"ticket/bh-1\"}}" ;;
  "POST repos/"*"/statuses/"*) reply "$(cat "@L@/status-code" 2>/dev/null || echo 201)" '{"id":1}' ;;
esac
exit 0
EOF
sed -i "s#@L@#$L#g" "$L/fakebin/curl" "$L/fakebin/gh"
chmod +x "$L/fakebin/curl" "$L/fakebin/gh"

# lreq <id> <status> <verdict> <job> [reset_count] -> one request on PR 7 @ $LSHA
lreq() {
  jq -nc --arg i "$1" --arg s "$2" --arg v "$3" --arg j "$4" --arg rc "${5:-}" --arg h "$LSHA" \
    '{id:$i, repo:"example-org/demo-os", pr:7, head_sha:$h, status:$s, verdict:$v, reviewer_model:"stub-model",
      report_ref:"state/lead-reviews/lr-7.md", promoted_verdict_at:null, box:"box-demo",
      detail:null, created_at:"2026-10-26T00:00:00Z", updated_at:"2026-10-26T00:00:00Z"}
     + (if $j == "" then {} else {job_id:$j} end)
     + (if $rc == "" then {} else {reset_count:($rc|tonumber)} end)'
}
lsetreqs() { printf '%s\n' "$@" | jq -sc '{requests:[.[] | select(. != null)], truncated:false}' > "$L/requests.json"; }
# lart <job> <report-body> [truncated]
lart() {
  jq -nc --arg b "$2" --arg t "${3:-}" '{body:$b, path:"state/lead-reviews/lr-7.md", verdict:"BLOCK"}
    + (if $t == "" then {} else {truncated:true} end)' \
    | jq -Rc '{artifacts:[{artifact_kind:"lead_review_report", artifact_ref:"state/lead-reviews/lr-7.md", phase_id:null, detail:.}]}' \
    > "$L/artifacts-$1.json"
}
# lreport <text> [head] — the stored report: the header lead-review.sh writes, then <text>
lreport() { local h="${2:-$LSHA}"; printf '# Lead review lr-7-%s (%s#7 at %s)\n\n- verdict: BLOCK\n- rules pack: red\n\n%s\n' "${h:0:12}" "$SLUG" "$h" "$1"; }
lreset() {
  scratch_rm "$L/log"; mkdir -p "$L/log"; : > "$L/log/gh"; : > "$L/log/worker"; : > "$L/log/alerts"
  rm -f "$L/ledger.json" "$L/ledger-code" "$L/vrows.json" "$L"/reviews-*.json "$L"/artifacts-*.json "$L"/art-code-* "$L/reset-code" "$L/status-code" "$HL/logs/lead-review-land.log"
  echo "$LSHA" > "$L/livehead"
  scratch_rm "$HL/logs/ALERTS.log"; scratch_rm "$HL/logs/lead-review-empty"
  scratch_rm "$ST"; scratch_rm "$HL/state/lead-review"
  lsetreqs "$(lreq lr-1 done BLOCK j1)"
}
# ltick [VAR=value ...] — one land tick; extra knobs ride in front.
ltick() {
  ( cd "$L" && env "$@" PATH="$L/fakebin:$PATH" HARNESS="$HL" HARNESS_SECRET=test-secret-fixture JOBS_URL=https://jobs.test \
      JOBS_RETRIES=0 TMPDIR="$L/tmp" LANE_GATE_DISABLE=1 LEAD_VERDICT_TOKEN_FILE="$L/cfg/token" GH_ETAG=0 MC_KEYED_WAKE=0 \
      bash "$HL/bin/lead-review-land.sh" ) > "$L/out" 2>&1; LRC=$?
}
vposts()   { grep -c '^POST /api/verdicts ' "$L/log/worker"; }
statuses() { grep -c "^POST repos/$SLUG/statuses/" "$L/log/gh"; }
rposts()   { grep -c "^POST repos/$SLUG/pulls/7/reviews " "$L/log/gh"; }
resets()   { grep -c '^POST /api/lead-reviews/lr-1/reset ' "$L/log/worker"; }
stamps()   { grep -c '^POST /api/lead-reviews/lr-1/promoted ' "$L/log/worker"; }
alerts_n() { grep -c "lead review lr-1" "$HL/logs/ALERTS.log" 2>/dev/null; }
llog()     { cat "$HL/logs/lead-review-land.log" 2>/dev/null; }
# marked — rc 0 when the lead_empty_block ledger row for PR 7 @ $LSHA exists
marked()   { [ -f "$L/ledger.json" ] && jq -e --arg k "lead_empty_block $MARK" 'has($k)' "$L/ledger.json" >/dev/null; }
# mark_seed — that row, as a tick that re-requested once already left it
mark_seed() { jq -nc --arg k "$MARK" '{("lead_empty_block " + $k): {kind:"lead_empty_block", key:$k, status:"rerequested", detail:"lead-review:lr-1 r0"}}' > "$L/ledger.json"; }
REQ_LINE="lead-review: empty BLOCK on $SLUG#7 @${LSHA:0:12}: no verdict recorded, re-requested"
ONCE_LINE="lead-review: empty BLOCK on $SLUG#7 @${LSHA:0:12}: no verdict recorded, already re-requested once for this head"

# ── E1: the first empty BLOCK on a head ──
lreset
FILLER=$(for i in $(seq 1 12); do printf 'The run summary line %02d says nothing a person can fix in this pull request.\n' "$i"; done)
BODY1=$(lreport "$FILLER
$POSTSCRIPT")
BODY1=${BODY1:0:1000}
lart j1 "$BODY1"
[ "${#BODY1}" = 1000 ] && ok || bad "E1 fixture: the report is ${#BODY1} bytes, want 1000"
ltick
[ "$LRC" = 0 ] && ok || bad "E1 rc=$LRC $(cat "$L/out")"
[ "$(vposts)" = 0 ] && ok || bad "E1 posted $(vposts) verdict row(s) for an empty BLOCK: $(grep '^POST /api/verdicts ' "$L/log/worker")"
[ "$(statuses)" = 0 ] && ok || bad "E1 published $(statuses) status(es): $(grep statuses "$L/log/gh")"
[ "$(rposts)" = 0 ] && ok || bad "E1 posted $(rposts) review(s)"
[ "$(resets)" = 1 ] && ok || bad "E1 want exactly 1 reset, got $(resets)"
[ "$(stamps)" = 0 ] && ok || bad "E1 stamped $(stamps) time(s) (the reset already cleared it)"
llog | grep -qF "$REQ_LINE" && ok || bad "E1 no '$REQ_LINE' log line: $(llog | tail -3)"
marked && ok || bad "E1 no lead_empty_block ledger row for $MARK: $(cat "$L/ledger.json" 2>/dev/null)"
grep -q '^PUT /api/ledger .*"kind":"lead_empty_block".*"status":"rerequested"' "$L/log/worker" && ok || bad "E1 no PUT of the lead_empty_block row: $(grep ledger "$L/log/worker")"
[ -e "$HL/state/lead-review" ] && bad "E1 wrote a file under state/lead-review (BH-4159: the marker is a ledger row)" || ok
[ "$(alerts_n)" = 1 ] && ok || bad "E1 want 1 ALERTS line, got $(alerts_n): $(cat "$HL/logs/ALERTS.log" 2>/dev/null)"
grep -q 'NO verdict row was recorded' "$HL/logs/ALERTS.log" 2>/dev/null && ok || bad "E1 the ALERTS line does not say no row was recorded"
grep -qF 'logs/lead-review-empty/lr-1.txt' "$HL/logs/ALERTS.log" 2>/dev/null && ok || bad "E1 the ALERTS line does not name the capture"
[ "$(wc -c < "$CAP" 2>/dev/null | tr -d ' ')" = 400 ] && ok || bad "E1 the capture is $(wc -c < "$CAP" 2>/dev/null) bytes, want 400"
[ "$(cat "$CAP" 2>/dev/null)" = "${BODY1:0:400}" ] && ok || bad "E1 the capture is not the first 400 bytes of the report"

# ── E2: the re-review (job j2, reset_count 1) is empty again ──
: > "$L/log/worker"; : > "$L/log/gh"
lart j2 "$(lreport "$POSTSCRIPT")"; lsetreqs "$(lreq lr-1 done BLOCK j2 1)"; ltick
[ "$(resets)" = 0 ] && ok || bad "E2 re-requested again on the same head ($(resets))"
[ "$(vposts)" = 0 ] && ok || bad "E2 posted $(vposts) verdict row(s)"
[ "$(statuses)" = 0 ] && ok || bad "E2 published a status"
[ "$(stamps)" = 1 ] && ok || bad "E2 want 1 stamp, got $(stamps)"
llog | grep -qF "$ONCE_LINE" && ok || bad "E2 no 'already re-requested' log line: $(llog | tail -3)"
[ "$(alerts_n)" = 2 ] && ok || bad "E2 want a second ALERTS line (generation r1), got $(alerts_n)"
grep -q 'a re-review was already requested once for this head' "$HL/logs/ALERTS.log" 2>/dev/null && ok || bad "E2 the ALERTS line does not say a re-review was already requested"

# ── E3: a finding line posts the row and the review ──
lreset; lart j1 "$(lreport $'Findings\n- [BLOCK] a.sh:3 the guard is inverted\n\nVERDICT: BLOCK')"; ltick
[ "$(vposts)" = 1 ] && grep -q '^POST /api/verdicts .*"verdict":"BLOCK"' "$L/log/worker" && ok || bad "E3 want 1 BLOCK row, got $(vposts)"
[ "$(rposts)" = 1 ] && grep -q "event=REQUEST_CHANGES" "$L/log/gh" && ok || bad "E3 want 1 REQUEST_CHANGES review: $(cat "$L/log/gh")"
[ "$(resets)" = 0 ] && ok || bad "E3 reset a real BLOCK"
[ -e "$CAP" ] && bad "E3 captured a report with a finding" || ok

# ── E4: a MERGE needs no finding line ──
lreset; lsetreqs "$(lreq lr-1 done MERGE j1)"; lart j1 "$(lreport $'Looks good.\n\nVERDICT: MERGE')"; ltick
[ "$(vposts)" = 1 ] && grep -q '^POST /api/verdicts .*"verdict":"MERGE"' "$L/log/worker" && ok || bad "E4 want 1 MERGE row, got $(vposts): $(llog | tail -3)"
[ "$(resets)" = 0 ] && ok || bad "E4 reset a MERGE"

# ── E5: the artifact cannot be read: nothing happens this tick ──
lreset; lart j1 "$(lreport "$POSTSCRIPT")"; echo 500 > "$L/art-code-j1"; ltick
[ "$(vposts)" = 0 ] && [ "$(resets)" = 0 ] && [ "$(stamps)" = 0 ] && ok || bad "E5 posts=$(vposts) resets=$(resets) stamps=$(stamps)"
marked && bad "E5 wrote the ledger row on an unread report" || ok
llog | grep -q 'could not be read' && ok || bad "E5 no unreadable log line: $(llog | tail -2)"

# ── E6: the PR has left the head: stamped, nothing re-requested ──
lreset; lart j1 "$(lreport "$POSTSCRIPT")"; echo "$OSHA" > "$L/livehead"; ltick
[ "$(vposts)" = 0 ] && [ "$(resets)" = 0 ] && ok || bad "E6 posts=$(vposts) resets=$(resets)"
[ "$(stamps)" = 1 ] && ok || bad "E6 want 1 stamp, got $(stamps)"
llog | grep -q 'the PR head moved; nothing re-requested' && ok || bad "E6 no head-moved log line: $(llog | tail -2)"

# ── E7: the reset is refused, then accepted ──
lreset; lart j1 "$(lreport "$POSTSCRIPT")"; echo 409 > "$L/reset-code"; ltick
[ "$(vposts)" = 0 ] && [ "$(stamps)" = 0 ] && [ "$(resets)" = 1 ] && ok || bad "E7 posts=$(vposts) stamps=$(stamps) resets=$(resets)"
marked && bad "E7 wrote the ledger row for a refused reset" || ok
grep -qF "$REQ_LINE" <<<"$(llog)" && bad "E7 logged 're-requested' for a refused reset" || ok
rm -f "$L/reset-code"; : > "$L/log/worker"; ltick
[ "$(resets)" = 1 ] && marked && ok || bad "E7 the next tick did not reset once: resets=$(resets)"

# ── E8: second empty result, ALERTS.log not writable: not stamped ──
lreset; lart j1 "$(lreport "$POSTSCRIPT")"; mark_seed
mkdir -p "$HL/logs/ALERTS.log"; ltick
[ "$(stamps)" = 0 ] && [ "$(vposts)" = 0 ] && [ "$(resets)" = 0 ] && ok || bad "E8 stamps=$(stamps) posts=$(vposts) resets=$(resets)"
scratch_rm "$HL/logs/ALERTS.log"

# ── ET: the decision table. inconclusive = 0 rows + 1 reset; posted = 1 row + 0 resets ──
while IFS='|' read -r case want verdict job art; do
  [ -n "$case" ] || continue
  lreset
  lsetreqs "$(lreq lr-1 done "$verdict" "$job")"
  case "$art" in
    trunc:*) lart j1 "$(lreport "$(printf '%b' "${art#trunc:}")")" truncated ;;
    other:*) lart j1 "$(lreport "$(printf '%b' "${art#other:}")" "$OSHA")" ;;
    none) ;;
    marker:*) lart j1 "$(lreport "$(printf '%b' "${art#marker:}")")"; mark_seed ;;
    *) lart j1 "$(lreport "$(printf '%b' "$art")")" ;;
  esac
  ltick
  got="other($(vposts) rows, $(resets) resets)"
  [ "$(vposts)" = 0 ] && [ "$(resets)" = 1 ] && got=inconclusive
  [ "$(vposts)" = 0 ] && [ "$(resets)" = 0 ] && [ "$(stamps)" = 1 ] && got=inconclusive-again
  [ "$(vposts)" = 1 ] && [ "$(resets)" = 0 ] && got=posted
  [ "$got" = "$want" ] && ok || bad "ET ($case) want $want, got $got: $(llog | tail -2)"
done <<'TABLE'
a|inconclusive|BLOCK|j1|The monitor expired. The review above is final.\n\nVERDICT: BLOCK
b|inconclusive|BLOCK|j1|Findings\n- [NOTE] b.sh:1 rename it\n\nVERDICT: BLOCK
c|inconclusive|BLOCK|j1|Findings\n  - [BLOCK] x\n\nVERDICT: BLOCK
d|inconclusive|BLOCK|j1|Findings\n* [BLOCK] x\n\nVERDICT: BLOCK
e|inconclusive|BLOCK|j1|Findings\n- [block] x\n\nVERDICT: BLOCK
f|inconclusive-again|BLOCK|j1|marker:Findings\n- [NOTE] n\n\nVERDICT: BLOCK
g|posted|BLOCK|j1|Findings\n- [BLOCK] a.sh:3 x\n\nVERDICT: BLOCK
h|posted|BLOCK|j1|Findings\n- [BLOCK needs-human] cfg.sh:1 which vendor tier\n\nVERDICT: BLOCK
i|posted|BLOCK|j1|Findings\r\n- [BLOCK] x\r\n\r\nVERDICT: BLOCK\r\n
j|posted|BLOCK|j1|trunc:Findings\n- [NOTE] b.sh:1 a long note
k|posted|BLOCK||none
l|posted|BLOCK|j1|other:Findings\n- [NOTE] n\n\nVERDICT: BLOCK
m|posted|MERGE|j1|Looks good.\n\nVERDICT: MERGE
n|posted|MERGE-WITH-NOTES|j1|VERDICT: MERGE-WITH-NOTES
TABLE

# ── E9: the capture knob at 0 writes no file; the rest is as E1 ──
lreset; lart j1 "$(lreport "$POSTSCRIPT")"; ltick LEAD_REVIEW_EMPTY_CAPTURE_BYTES=0
[ -e "$CAP" ] && bad "E9 wrote a capture with the knob at 0" || ok
[ "$(vposts)" = 0 ] && [ "$(resets)" = 1 ] && marked && ok || bad "E9 posts=$(vposts) resets=$(resets)"
# an out-of-range knob reads the default (400) and says so
lreset; lart j1 "$(lreport "$FILLER")"; ltick LEAD_REVIEW_EMPTY_CAPTURE_BYTES=999999
[ "$(wc -c < "$CAP" 2>/dev/null | tr -d ' ')" = 400 ] && ok || bad "E9 a bad knob did not read 400: $(wc -c < "$CAP" 2>/dev/null)"
llog | grep -q "LEAD_REVIEW_EMPTY_CAPTURE_BYTES='999999' is not 0..65536; using 400" && ok || bad "E9 no bad-knob log line"

# ── E10: retention of captures (the marker is a ledger row, not a file) ──
lreset; lsetreqs
mkdir -p "$HL/logs/lead-review-empty"
: > "$HL/logs/lead-review-empty/old.txt"; touch -d '40 days ago' "$HL/logs/lead-review-empty/old.txt"
: > "$HL/logs/lead-review-empty/new.txt"; touch -d '1 day ago' "$HL/logs/lead-review-empty/new.txt"
ltick
[ ! -e "$HL/logs/lead-review-empty/old.txt" ] && ok || bad "E10 the 40-day-old capture stayed"
[ -e "$HL/logs/lead-review-empty/new.txt" ] && ok || bad "E10 a 1-day-old capture was deleted"
touch -d '10 days ago' "$HL/logs/lead-review-empty/new.txt"; ltick LEAD_REVIEW_EMPTY_KEEP_DAYS=5
[ ! -e "$HL/logs/lead-review-empty/new.txt" ] && ok || bad "E10 LEAD_REVIEW_EMPTY_KEEP_DAYS=5 kept a 10-day-old capture"

# ── E11: this request's own row was retracted: it is absent, a new row is posted ──
lreset; lart j1 "$(lreport $'Findings\n- [BLOCK] a.sh:3 x\n\nVERDICT: BLOCK')"
jq -nc --arg h "$LSHA" '[{id:1, repo:"example-org/demo-os", pr:7, head_sha:$h, verdict:"BLOCK", source:"lead",
  note:"lead-review:lr-1 lead-job:j1", created_at:"2026-10-25T00:00:00Z", retracted_at:"2026-10-26T01:00:00Z", retract_reason:"empty-report"}]' > "$L/vrows.json"
ltick
[ "$(vposts)" = 1 ] && ok || bad "E11 want 1 new row over the retracted one, got $(vposts): $(llog | tail -2)"
# the re-review of a reset request does not name the retracted row as superseded
lreset; lart j2 "$(lreport $'Findings\n- [BLOCK] a.sh:3 x\n\nVERDICT: BLOCK')"; lsetreqs "$(lreq lr-1 done BLOCK j2 1)"
jq -nc --arg h "$LSHA" '[{id:1, repo:"example-org/demo-os", pr:7, head_sha:$h, verdict:"BLOCK", source:"lead",
  note:"lead-review:lr-1 lead-job:j1", created_at:"2026-10-25T00:00:00Z", retracted_at:"2026-10-26T01:00:00Z", retract_reason:"empty-report"}]' > "$L/vrows.json"
ltick
[ "$(vposts)" = 1 ] && ok || bad "E11b want 1 row, got $(vposts)"
grep -q 'supersedes:1' <<<"$(grep '^POST /api/verdicts ' "$L/log/worker")" && bad "E11b the new row supersedes the retracted row #1" || ok

# ── E12: the row was recorded on an earlier tick (before BH-8476, or a lost stamp) ──
lreset; lart j1 "$(lreport "$POSTSCRIPT")"
jq -nc --arg h "$LSHA" '[{id:4057, repo:"example-org/demo-os", pr:7, head_sha:$h, verdict:"BLOCK", source:"lead",
  note:"lead-review:lr-1 lead-job:j1", created_at:"2026-10-25T19:47:37Z"}]' > "$L/vrows.json"
ltick
[ "$(vposts)" = 0 ] && [ "$(rposts)" = 0 ] && [ "$(resets)" = 0 ] && ok || bad "E12 posts=$(vposts) reviews=$(rposts) resets=$(resets)"
[ "$(stamps)" = 1 ] && ok || bad "E12 want 1 stamp, got $(stamps)"
grep -qF 'retract it with bin/lead-verdict.sh retract 4057 --reason empty-report' "$HL/logs/ALERTS.log" 2>/dev/null && ok || bad "E12 the alert does not name the retract command: $(cat "$HL/logs/ALERTS.log" 2>/dev/null)"

# ── E13: the lead_empty_block ledger cannot be read: no reset, no row, no stamp ──
lreset; lart j1 "$(lreport "$POSTSCRIPT")"; echo 500 > "$L/ledger-code"; ltick
[ "$(resets)" = 0 ] && [ "$(vposts)" = 0 ] && [ "$(stamps)" = 0 ] && [ "$(statuses)" = 0 ] && ok || bad "E13 resets=$(resets) posts=$(vposts) stamps=$(stamps) statuses=$(statuses)"
llog | grep -q 'the lead_empty_block ledger row could not be read; nothing re-requested, not stamped' && ok || bad "E13 no unreadable-ledger log line: $(llog | tail -2)"
rm -f "$L/ledger-code"; : > "$L/log/worker"; ltick
[ "$(resets)" = 1 ] && marked && ok || bad "E13 the next tick did not reset once: resets=$(resets)"

# ════════════════════════════ Part R: bin/lead-verdict.sh retract ═══════════
# rrows <json-array> — the verdict rows on PR 7
rrows() { printf '%s' "$1" > "$L/vrows.json"; }
ROW1=$(jq -nc --arg h "$LSHA" '{id:1, repo:"example-org/demo-os", pr:7, head_sha:$h, verdict:"BLOCK", source:"lead", reviewer:"box:hub", note:"lead-review:lr-1 lead-job:j1", created_at:"2026-10-25T19:47:37Z"}')
ROW2=$(jq -nc --arg h "$LSHA" '{id:2, repo:"example-org/demo-os", pr:7, head_sha:$h, verdict:"MERGE", source:"human", reviewer:"operator", created_at:"2026-10-25T19:29:00Z"}')
ROW3=$(jq -nc --arg h "$LSHA" '{id:3, repo:"example-org/demo-os", pr:7, head_sha:$h, verdict:"MERGE", source:"lead", reviewer:"box:hub", note:"lead-review:lr-0 authority:human-required", created_at:"2026-10-25T19:00:00Z"}')
rrun() {
  : > "$L/log/worker"; : > "$L/log/gh"
  ( cd "$L" && PATH="$L/fakebin:$PATH" HARNESS="$HL" HARNESS_SECRET=test-secret-fixture JOBS_URL=https://jobs.test \
      JOBS_RETRIES=0 TMPDIR="$L/tmp" LEAD_VERDICT_TOKEN_FILE="$L/cfg/token" GH_ETAG=0 LV_REVIEWER=hub \
      bash "$HL/bin/lead-verdict.sh" retract "$@" ) > "$L/rout" 2>&1; RRC=$?
}
st_state() { sed -n "s#^POST repos/$SLUG/statuses/$LSHA .* state=##p" "$L/log/gh" | head -1; }

# ── R1: #1 (empty lead BLOCK) retracted, #2 (human MERGE) stands: success ──
lreset; rrows "[$ROW1,$ROW2]"; rrun 1 --reason empty-report
[ "$RRC" = 0 ] && ok || bad "R1 rc=$RRC $(cat "$L/rout")"
grep -q '^POST /api/verdicts/1/retract .*"reason":"empty-report".* lead=1$' "$L/log/worker" && ok || bad "R1 no retract POST with the lead token: $(cat "$L/log/worker")"
[ "$(statuses)" = 1 ] && [ "$(st_state)" = success ] && ok || bad "R1 want 1 success status, got $(statuses): $(cat "$L/log/gh")"
grep -qF "retracted verdict #1 (empty-report); lead-verdict=success on $SLUG@${LSHA:0:12} (standing: #2 MERGE)" "$L/rout" && ok || bad "R1 the output line: $(cat "$L/rout")"
# a retry of the same retraction says so and republishes
rrun 1 --reason empty-report
[ "$RRC" = 0 ] && grep -q 'already retracted' "$L/rout" && [ "$(statuses)" = 1 ] && ok || bad "R1 retry rc=$RRC statuses=$(statuses): $(cat "$L/rout")"

# ── R2: the only row retracted: pending ──
lreset; rrows "[$ROW1]"; rrun 1 --reason empty-report
[ "$RRC" = 0 ] && [ "$(st_state)" = pending ] && ok || bad "R2 rc=$RRC state=$(st_state): $(cat "$L/rout")"
grep -qF "lead-verdict=pending on $SLUG@${LSHA:0:12} (standing: none)" "$L/rout" && ok || bad "R2 the output line: $(cat "$L/rout")"

# ── R3: the row left standing is a withheld lead MERGE: pending, never success ──
lreset; rrows "[$ROW1,$ROW3]"; rrun 1 --reason empty-report
[ "$RRC" = 0 ] && [ "$(st_state)" = pending ] && ok || bad "R3 rc=$RRC state=$(st_state): $(cat "$L/rout")"

# ── R4: a human row cannot be retracted ──
lreset; rrows "[$ROW1,$ROW2]"; rrun 2 --reason empty-report
[ "$RRC" = 1 ] && [ "$(statuses)" = 0 ] && ok || bad "R4 rc=$RRC statuses=$(statuses): $(cat "$L/rout")"
grep -q 'only a lead BLOCK row can be retracted' "$L/rout" && ok || bad "R4 the worker message is not printed: $(cat "$L/rout")"

# ── R5: usage ──
lreset; rrows "[$ROW1]"
for args in "1 --reason other" "abc --reason empty-report" "0 --reason empty-report" "1" "1 --reason"; do
  # shellcheck disable=SC2086
  rrun $args
  [ "$RRC" = 2 ] && [ ! -s "$L/log/worker" ] && ok || bad "R5 '$args' rc=$RRC worker calls: $(cat "$L/log/worker")"
done

# ── R6: the status POST fails: exit 4, no lead-verdict= line ──
lreset; rrows "[$ROW1,$ROW2]"; echo 500 > "$L/status-code"; rrun 1 --reason empty-report
[ "$RRC" = 4 ] && ok || bad "R6 rc=$RRC (want 4): $(cat "$L/rout")"
grep -q '^retracted verdict #1 .*lead-verdict=' "$L/rout" && bad "R6 printed a lead-verdict= line for an unpublished status" || ok

# ════════════════════════════ Part W: the worker half ═══════════════════════
# worker/jobs/src/routes/verdict-retractions.js and the standing filter.
if command -v node >/dev/null 2>&1 && [ -d "$SRC/worker/jobs/node_modules" ] && [ -f "$SRC/worker/jobs/src/routes/verdict-retractions.js" ]; then
  if ( cd "$SRC/worker/jobs" && node --test test/verdict-retract.bh-8476.test.js ) > "$L/wout" 2>&1; then ok
  else bad "W worker/jobs/test/verdict-retract.bh-8476.test.js failed: $(tail -20 "$L/wout")"; fi
elif [ ! -f "$SRC/worker/jobs/src/routes/verdict-retractions.js" ]; then
  bad "W worker/jobs/src/routes/verdict-retractions.js is missing"
else
  echo "note: node or worker/jobs/node_modules missing; Part W skipped (CI runs it in the worker suite)"
fi

echo "lead-land-empty-block.bh-8476: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
