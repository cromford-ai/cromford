#!/bin/bash
# tests/lead-review-land-reland.bh-5400-test.sh — BH-5400: a lead review request
# that is reset and re-reviewed lands its NEW verdict. bin/lead-review-land.sh
# runs WHOLE against a scratch harness carrying the real lane, the real
# bin/lead-verdict.sh, bin/jobs-client.sh and their bin/lib closure, and the
# real br_lead_pick from bin/blocked-resolver.sh. Only these are stubbed:
#   * curl — a stateful jobs worker: the lead-reviews list ($T/requests.json),
#            verdict rows ($T/vrows.json), the /promoted stamp (409 when
#            $T/promoted409 exists), the /reset route (status from
#            $T/reset-status, default 200) and the report artifacts
#            ($T/artifacts-<job>.json);
#   * gh   — GitHub: pulls/<n> answers $SHA; reviews GET/POST over
#            $T/reviews-<n>.json; a dismissals PUT marks the review DISMISSED
#            (status from $T/dismiss-status, default 200); a statuses POST is
#            logged with its state;
#   * bin/lane-alert.sh — appends its args to $T/log/alerts.
#   R1  BLOCK, reset, re-review MERGE: new row supersedes, status success, old review dismissed
#   R2  BLOCK, reset, re-review BLOCK with new findings: new review, old one dismissed after it
#   R3  landed once, never reset: no repost (job-keyed, stamp-lost replay, legacy landing)
#   R4  a BLOCK always lands a REQUEST_CHANGES with its findings (#5273 shape included)
#   R5  a legacy landing with a recorded reset re-lands
#   R6  a failed dismissal on a BLOCK re-land is no stamp, and heals next tick
#   R7  failed/overdue alerts after a reset
#   R8  bin/lead-verdict.sh reset
#   R9  the stamp is bound to the job
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-review-land-reland.bh-5400-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lpp-stub.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

SHA=$(printf 'a%.0s' {1..40})
SLUG=example-org/demo-os
ST="" # the lane's state dir, set by build

build() {
  H="$1/h"; mkdir -p "$H/state" "$H/logs" "$H/catalog"
  scratch_install_closure bin/lead-review-land.sh "$H" >/dev/null || { echo "closure install failed (lane)"; exit 1; }
  scratch_install_closure bin/lead-verdict.sh "$H" >/dev/null || { echo "closure install failed (lead-verdict)"; exit 1; }
  scratch_install_closure bin/jobs-client.sh "$H" >/dev/null || { echo "closure install failed (jobs-client)"; exit 1; }
  # TEST-CHANGE BH-4148 (merge of main): the lead protected paths come from the
  # lead_protected_paths rows (tests/lib/lpp-stub.sh), not the deleted TSV. The rows
  # are the cromford globs the TSV held (the fixture).
  LPPF="$T/lpp.json"; LPPDOWN="$T/lpp-down"
  set -f; lpp_set "$LPPF" example-org/cromford $(cat "$DIR/tests/fixtures/lead-protected-paths.bh-4148.txt"); set +f
  lpp_install "$T/fakebin" "$LPPF" "$LPPDOWN"
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"\nexit 0\n' "$T/log/alerts" > "$H/bin/lane-alert.sh"
  chmod +x "$H/bin/lane-alert.sh"
  echo box-hub > "$H/state/box-name"
  ST="$H/state/lead-review-land"
}
mkdir -p "$T/fakebin" "$T/log" "$T/tmp" "$T/cfg"
printf 'lead-test-token\n' > "$T/cfg/token"; chmod 600 "$T/cfg/token"
build "$T"

cat > "$T/fakebin/curl" <<'EOF'
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
lead=0; grep -q '^x-lead-verdict-token: lead-test-token' <<<"$hdrs" && lead=1
p="${url#https://jobs.test}"
printf '%s %s %s lead=%s\n' "$m" "$p" "$body" "$lead" >> "@T@/log/worker"
printf 'worker %s %s\n' "$m" "${p%%\?*}" >> "@T@/log/seq"
[ -f "@T@/vrows.json" ] || echo '[]' > "@T@/vrows.json"
qp() { printf '%s' "${p#*\?}" | tr '&' '\n' | sed -n "s/^$1=//p" | head -1; }
code=200; out='{}'
case "$m $p" in
  *"/api/lead-protected-paths"*) lpp-answer "$m" "$url" "$body"; exit 0 ;;
  "GET /api/lead-reviews"*) out=$(cat "@T@/requests.json") ;;
  "POST /api/lead-reviews/"*/promoted)
    if [ "$lead" != 1 ]; then code=403; out='{"error":"needs the lead token"}'
    elif [ -e "@T@/promoted409" ]; then code=409; out='{"error":"the request now holds job j9; this stamp is for j2"}'
    else out='{"request":{"promoted_verdict_at":"2026-10-08T00:00:00Z"}}'; fi ;;
  "POST /api/lead-reviews/"*/reset)
    i="${p#/api/lead-reviews/}"; i="${i%/reset}"
    st=200; [ -f "@T@/reset-status" ] && st=$(cat "@T@/reset-status")
    if [ "$lead" != 1 ]; then code=403; out='{"error":"needs the lead token"}'
    elif [ "$st" = 200 ]; then out="{\"request\":{\"id\":\"$i\",\"status\":\"requested\",\"reset_count\":1}}"
    else code="$st"; out='{"error":"lead review request is running (job j7); only a finished request can be reset"}'; fi ;;
  "GET /api/jobs/"*/artifacts)
    j="${p#/api/jobs/}"; j="${j%/artifacts}"
    if [ -f "@T@/artifacts-$j.json" ]; then out=$(cat "@T@/artifacts-$j.json")
    else out='{"artifacts":[]}'; fi ;;
  "POST /api/verdicts")
    n=$(jq 'map(.id) | max // 0' "@T@/vrows.json")
    row=$(jq -c --argjson id "$((n + 1))" '. + {id:$id, created_at:"2026-10-08T00:00:00Z"}' <<<"$body")
    jq -c --argjson r "$row" '. + [$r]' "@T@/vrows.json" > "@T@/vrows.tmp" && mv "@T@/vrows.tmp" "@T@/vrows.json"
    code=201; out=$(jq -c '{verdict:.}' <<<"$row") ;;
  "GET /api/verdicts?"*)
    out=$(jq -c --arg r "$(qp repo)" --argjson pr "$(qp pr)" --arg h "$(qp head)" '
      [.[] | select(.repo == $r and .pr == $pr)] | sort_by(-.id) as $rows
      | {repo:$r, pr:$pr, head:$h, standing:([$rows[] | select(.head_sha == $h and .source == "lead")] | first),
         rows:$rows, truncated:false}' "@T@/vrows.json") ;;
  *) code=404; out='{"error":"unknown endpoint","worker":"harness-jobs"}' ;;
esac
printf '%s\n%s' "$out" "$code"
EOF

cat > "$T/fakebin/gh" <<'EOF'
#!/bin/bash
m=GET; path=""; prev=""; ev=""; cid=""; body=""; state=""
for a in "$@"; do
  case "$prev" in
    -X) m="$a" ;;
    -f|-F) v="${a#*=}"; case "$v" in @*) v=$(cat "${v#@}") ;; esac
           case "${a%%=*}" in event) ev="$v" ;; commit_id) cid="$v" ;; body) body="$v" ;; state) state="$v" ;; esac ;;
  esac
  case "$a" in repos/*) path="$a" ;; esac
  prev="$a"
done
printf '%s %s event=%s commit_id=%s state=%s\n' "$m" "$path" "$ev" "$cid" "$state" >> "@T@/log/gh"
printf 'gh %s %s\n' "$m" "${path%%\?*}" >> "@T@/log/seq"
reply() { printf 'HTTP/1.1 %s X\r\n\r\n%s\n' "$1" "$2"; exit 0; }
n=$(printf '%s' "$path" | sed -nE 's#^repos/[^/]+/[^/]+/pulls/([0-9]+).*#\1#p')
rf="@T@/reviews-$n.json"
case "$m $path" in
  "PUT repos/"*"/pulls/"*"/reviews/"*"/dismissals")
    rid=$(printf '%s' "$path" | sed -nE 's#.*/reviews/([0-9]+)/dismissals$#\1#p')
    st=200; [ -f "@T@/dismiss-status" ] && st=$(cat "@T@/dismiss-status")
    case "$st" in 2*) ;; *) reply "$st" '{"message":"boom"}' ;; esac
    jq -c --argjson i "$rid" 'map(if .id == $i then .state = "DISMISSED" else . end)' "$rf" > "$rf.tmp" && mv "$rf.tmp" "$rf"
    reply 200 '{"state":"DISMISSED"}' ;;
  # TEST-CHANGE (BH-5213 merged with BH-5400): a review this lane posts is
  # recorded as the hub App that posts it (cromford[bot], a Bot), the
  # identity the legacy fixtures below already use. Step 2d now dismisses only
  # the lane's OWN reviews (bin/lib/lead-stale-review.sh: a bot author AND the
  # lead-review marker), so a review recorded as a User is a person's and stays.
  "POST repos/"*"/pulls/"*"/reviews")
    [ -f "$rf" ] || echo '[]' > "$rf"
    printf '%s' "$body" > "@T@/log/body-$n-$(( $(jq length "$rf") + 1 ))"
    case "$ev" in REQUEST_CHANGES) s=CHANGES_REQUESTED ;; COMMENT) s=COMMENTED ;; *) s=PENDING ;; esac
    jq -c --arg c "$cid" --arg s "$s" --arg b "$body" \
      '. + [{id:(length + 1), user:{login:"cromford[bot]",type:"Bot"}, author_association:"OWNER", commit_id:$c, state:$s, body:$b}]' \
      "$rf" > "$rf.tmp" && mv "$rf.tmp" "$rf"
    reply 200 '{"id":1}' ;;
  "GET repos/"*"/pulls/"*"/reviews"*)
    case "$path" in *"page=1"|*"page=1&"*) ;; *) reply 200 '[]' ;; esac
    if [ -f "$rf" ]; then reply 200 "$(cat "$rf")"; else reply 200 '[]'; fi ;;
  "GET repos/"*"/pulls/"*)
    reply 200 "{\"head\":{\"sha\":\"@SHA@\",\"ref\":\"ticket/bh-1\"}}" ;;
  "POST repos/"*"/statuses/"*) reply 201 '{"id":1}' ;;
esac
exit 0
EOF
sed -i "s#@T@#$T#g; s#@SHA@#$SHA#g" "$T/fakebin/curl" "$T/fakebin/gh"
chmod +x "$T/fakebin/curl" "$T/fakebin/gh"

export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
  JOBS_RETRIES=0 TMPDIR="$T/tmp" LANE_GATE_DISABLE=1 LEAD_VERDICT_TOKEN_FILE="$T/cfg/token" GH_ETAG=0
unset BOX_NAME JOBS_BOX LEAD_REVIEW_OVERDUE_MIN HUB_BOX_NAME LEAD_REVIEW_SPOTCHECK_PCT

ago() { date -u -d "-$1 min" '+%Y-%m-%dT%H:%M:%SZ'; }
# req <id> <status> <verdict|null> <job|""> [reset_count] [reset_at] -> one request object on PR 7 @ $SHA
req() {
  jq -nc --arg i "$1" --arg s "$2" --arg v "$3" --arg j "$4" --arg rc "${5:-}" --arg ra "${6:-}" \
    '{id:$i, repo:"example-org/demo-os", pr:7, head_sha:"'"$SHA"'", status:$s,
      verdict:(if $v == "null" then null else $v end), reviewer_model:"stub-model",
      report_ref:"state/lead-reviews/lr-7.md", promoted_verdict_at:null,
      job_id:(if $j == "" then null else $j end), box:"box-demo",
      detail:null, created_at:"2026-09-29T00:00:00Z", updated_at:"2026-09-29T00:00:00Z"}
     + (if $rc == "" then {} else {reset_count:($rc|tonumber)} end)
     + (if $ra == "" then {} else {reset_at:$ra} end)'
}
setreqs() { printf '%s\n' "$@" | jq -sc '{requests:., truncated:false}' > "$T/requests.json"; }
art() {
  jq -nc --arg b "$2" '{body:$b, path:"state/lead-reviews/report.md", verdict:"BLOCK"}' \
    | jq -Rc '{artifacts:[{artifact_kind:"lead_review_report", artifact_ref:"state/lead-reviews/report.md", phase_id:null, detail:.}]}' \
    > "$T/artifacts-$1.json"
}
report() { printf '# Lead review lr-7-%s (%s#7 at %s)\n\n- [BLOCK] %s\nVERDICT: BLOCK\n' "${SHA:0:12}" "$SLUG" "$SHA" "$1"; }
reset() {
  scratch_rm "$T/log"; rm -f "$T"/{vrows.json,dismiss-status,promoted409,reset-status} "$T"/reviews-*.json "$T"/artifacts-*.json
  mkdir -p "$T/log"; : > "$T/log/gh"; : > "$T/log/worker"; : > "$T/log/alerts"; : > "$T/log/seq"
  rm -f "$H/logs/lead-review-land.log" "$H/logs/ALERTS.log"
  scratch_rm "$ST"
  art j1 "$(report 'finding X: the retry loop never stops')"
  art j2 "$(report 'finding Y: the cache is never invalidated')"
}
tick() { ( cd "$T" && bash "$H/bin/lead-review-land.sh" ) > "$T/out" 2>&1; RC=$?; }
clearlogs() { : > "$T/log/gh"; : > "$T/log/worker"; : > "$T/log/seq"; }
rposts()  { grep -c "^POST repos/$SLUG/pulls/7/reviews " "$T/log/gh"; }
vposts()  { grep -c '^POST /api/verdicts ' "$T/log/worker"; }
stamps()  { grep -c '^POST /api/lead-reviews/lr-1/promoted ' "$T/log/worker"; }
dismissals() { grep -c "^PUT repos/$SLUG/pulls/7/reviews/[0-9]*/dismissals " "$T/log/gh"; }
rstate()  { jq -r --argjson i "$1" '.[] | select(.id == $i) | .state' "$T/reviews-7.json"; }
rbody()   { cat "$T/log/body-7-$1" 2>/dev/null; }
vrow()    { jq -c --argjson i "$1" '.[] | select(.id == $i)' "$T/vrows.json"; }
seqorder() { awk '/^worker POST \/api\/verdicts$/{print "row"} /^gh POST .*\/reviews$/{print "review"} /^gh PUT .*\/dismissals$/{print "dismiss"} /^worker POST \/api\/lead-reviews\/lr-1\/promoted$/{print "stamp"}' "$T/log/seq" | paste -sd' '; }
LOGF() { cat "$H/logs/lead-review-land.log" 2>/dev/null; }
# land_j1 — tick 1 of R1/R2/R4/R6: lr-1 lands BLOCK from job j1 (finding X).
land_j1() { reset; setreqs "$(req lr-1 done BLOCK j1)"; tick; }

# ── R1: BLOCK, reset, re-review MERGE ────────────────────────────────────────
land_j1
[ "$RC" = 0 ] && ok || bad "R1 tick 1 rc=$RC $(cat "$T/out")"
grep -q '"note":"lead-review:lr-1 lead-job:j1 report:state/lead-reviews/lr-7.md"' "$T/log/worker" \
  && ok || bad "R1 tick 1 row note lacks lead-job:j1: $(grep '^POST /api/verdicts' "$T/log/worker")"
[ "$(rstate 1)" = CHANGES_REQUESTED ] && ok || bad "R1 tick 1 no REQUEST_CHANGES review #1"
[ "$(rbody 1 | sed -n 1p)" = '<!-- lead-review:lr-1 -->' ] && [ "$(rbody 1 | sed -n 2p)" = '<!-- lead-job:j1 -->' ] \
  && ok || bad "R1 review #1 markers: $(rbody 1 | head -2)"
grep -q '^POST /api/lead-reviews/lr-1/promoted {"job_id":"j1"} lead=1$' "$T/log/worker" && ok || bad "R1 tick 1 stamp body: $(grep promoted "$T/log/worker")"
[ "$(cat "$ST/findings-lr-1" 2>/dev/null)" = j1 ] && ok || bad "R1 findings flag does not hold j1"
clearlogs; setreqs "$(req lr-1 done MERGE j2 1 "$(ago 5)")"; tick
[ "$RC" = 0 ] && ok || bad "R1 tick 2 rc=$RC"
[ "$(vposts)" = 1 ] && ok || bad "R1 want one new verdict row, got $(vposts): $(LOGF | tail -3)"
V2=$(vrow 2)
[ "$(jq -r .verdict <<<"$V2")" = MERGE ] && jq -r .note <<<"$V2" | tr ' ' '\n' | grep -qx 'lead-job:j2' \
  && jq -r .note <<<"$V2" | tr ' ' '\n' | grep -qx 'supersedes:1' && jq -r .note <<<"$V2" | tr ' ' '\n' | grep -qx 'lead-review:lr-1' \
  && ok || bad "R1 row #2 is not a MERGE superseding #1: $V2"
grep -q "^POST repos/$SLUG/statuses/$SHA .*state=success\$" "$T/log/gh" && ok || bad "R1 no lead-verdict success status: $(grep statuses "$T/log/gh")"
[ "$(rstate 1)" = DISMISSED ] && ok || bad "R1 review #1 not dismissed ($(rstate 1))"
STAND=$(curl -s "https://jobs.test/api/verdicts?repo=$SLUG&pr=7&head=$SHA" | head -1 | jq -r '.standing.id')
[ "$STAND" = 2 ] && ok || bad "R1 the standing row is #$STAND, not #2"
grep -q '^POST /api/lead-reviews/lr-1/promoted {"job_id":"j2"} lead=1$' "$T/log/worker" && ok || bad "R1 tick 2 stamp body: $(grep promoted "$T/log/worker")"
[ "$(seqorder)" = "row dismiss stamp" ] && ok || bad "R1 order '$(seqorder)' (want row dismiss stamp)"
LOGF | grep -q 're-landing: newer result job j2 replaces lead row #1' && ok || bad "R1 no re-landing log line: $(LOGF | tail -3)"

# ── R2: BLOCK, reset, re-review BLOCK with different findings ────────────────
land_j1
clearlogs; setreqs "$(req lr-1 done BLOCK j2 1 "$(ago 5)")"; tick
[ "$(rposts)" = 1 ] && grep -q "^POST repos/$SLUG/pulls/7/reviews event=REQUEST_CHANGES commit_id=$SHA " "$T/log/gh" \
  && ok || bad "R2 want one new REQUEST_CHANGES, got $(rposts): $(LOGF | tail -3)"
B2=$(rbody 2)
grep -qxF '<!-- lead-job:j2 -->' <<<"$B2" && grep -qF 'finding Y' <<<"$B2" && ! grep -qF 'finding X' <<<"$B2" \
  && ok || bad "R2 review #2 body is not the j2 findings: $B2"
[ "$(rstate 1)" = DISMISSED ] && [ "$(rstate 2)" = CHANGES_REQUESTED ] && ok || bad "R2 states #1=$(rstate 1) #2=$(rstate 2)"
V2=$(vrow 2)
[ "$(jq -r .verdict <<<"$V2")" = BLOCK ] && jq -r .note <<<"$V2" | tr ' ' '\n' | grep -qx 'supersedes:1' && ok || bad "R2 row #2: $V2"
grep -q "^POST repos/$SLUG/statuses/$SHA .*state=failure\$" "$T/log/gh" && ok || bad "R2 no failure status"
[ "$(seqorder)" = "row review dismiss stamp" ] && ok || bad "R2 order '$(seqorder)' (want row review dismiss stamp)"
LOGF | grep -q 'dismissed 1 earlier landing review(s) of lead review lr-1' && ok || bad "R2 no dismissal log line: $(LOGF | tail -3)"
# the fix round's REAL br_lead_pick briefs the NEW findings
BR="$DIR/bin/blocked-resolver.sh"
lift() { awk -v n="$1" '$0 ~ "^"n"\\(\\) \\{" {f=1} f{print} f&&/^}/{exit}' "$BR"; }
{ grep -E '^(BR_REVIEW_FOOTER|BR_LEAD_HDR)=' "$BR"; lift br_lead_pick; } > "$T/pick.sh"
ROWS=$(jq -c '[ .[] | {l:(.user.login // ""), t:(.user.type // ""), a:(.author_association // ""), c:(.commit_id // ""), s:(.state // ""), b:(.body // "")} ]' "$T/reviews-7.json")
# The lane's review is a Bot's (above), so br_lead_pick takes its lead-review
# path, which asks harness_verdict_author_match: the real one, from the lib
# bin/blocked-resolver.sh sources.
DEC=$(bash -c '. "$1"; . "$5"; br_lead_pick "$2" "$3" "$4"' _ "$T/pick.sh" "$SLUG" "$SHA" "$ROWS" "$DIR/bin/lib/gh-pr-list.sh" | base64 -d 2>/dev/null)
grep -qF 'finding Y' <<<"$DEC" && ! grep -qF 'finding X' <<<"$DEC" && ok || bad "R2 br_lead_pick did not brief finding Y: $DEC"

# ── R3: landed once, never reset -> no repost ───────────────────────────────
land_j1
clearlogs; tick
[ "$(vposts)" = 0 ] && [ "$(rposts)" = 0 ] && [ "$(dismissals)" = 0 ] && [ "$(stamps)" = 1 ] \
  && ok || bad "R3a second tick reposted (rows=$(vposts) reviews=$(rposts) dismissals=$(dismissals) stamps=$(stamps))"
# (b) the stamp-lost replay with the flag gone: the job marker on GitHub dedupes
rm -f "$ST/findings-lr-1"; clearlogs; tick
[ "$(vposts)" = 0 ] && [ "$(rposts)" = 0 ] && [ "$(stamps)" = 1 ] && ok || bad "R3b replay reposted (rows=$(vposts) reviews=$(rposts))"
[ "$(cat "$ST/findings-lr-1" 2>/dev/null)" = j1 ] && ok || bad "R3b the marker read did not re-flag j1"
# (c) a legacy landing (no lead-job token, legacy marker, empty flag), never reset
reset
jq -nc --arg h "$SHA" '[{id:1, repo:"example-org/demo-os", pr:7, head_sha:$h, verdict:"BLOCK", source:"lead", note:"lead-review:lr-1 report:state/lead-reviews/lr-7.md"}]' > "$T/vrows.json"
jq -nc --arg c "$SHA" '[{id:1, user:{login:"cromford[bot]",type:"Bot"}, author_association:"NONE", commit_id:$c, state:"CHANGES_REQUESTED", body:"<!-- lead-review:lr-1 -->\nold"}]' > "$T/reviews-7.json"
mkdir -p "$ST"; : > "$ST/findings-lr-1"
setreqs "$(req lr-1 done BLOCK j1 0)"; tick
[ "$(vposts)" = 0 ] && [ "$(rposts)" = 0 ] && [ "$(dismissals)" = 0 ] && [ "$(stamps)" = 1 ] \
  && ok || bad "R3c a legacy landing reposted (rows=$(vposts) reviews=$(rposts) dismissals=$(dismissals) stamps=$(stamps))"

# ── R4: a BLOCK always gives REQUEST_CHANGES with its findings ──────────────
land_j1
grep -q "^POST repos/$SLUG/pulls/7/reviews event=REQUEST_CHANGES commit_id=$SHA " "$T/log/gh" && grep -qF 'finding X' <<<"$(rbody 1)" \
  && ok || bad "R4a the first landing is not a REQUEST_CHANGES with its findings"
# (b) #5273: the old review was dismissed by hand, the flag holds j1
jq -c 'map(.state = "DISMISSED")' "$T/reviews-7.json" > "$T/r.tmp" && mv "$T/r.tmp" "$T/reviews-7.json"
clearlogs; setreqs "$(req lr-1 done BLOCK j2 1 "$(ago 5)")"; tick
[ "$(grep -c "^POST repos/$SLUG/pulls/7/reviews event=REQUEST_CHANGES commit_id=$SHA " "$T/log/gh")" = 1 ] && grep -qF 'finding Y' <<<"$(rbody 2)" \
  && ok || bad "R4b the re-review BLOCK was not posted as REQUEST_CHANGES (posts=$(rposts)): $(LOGF | tail -3)"
[ "$(stamps)" = 1 ] && ok || bad "R4b not stamped ($(stamps))"
# (c) an empty legacy flag with a recorded reset is not "posted"
reset
jq -nc --arg h "$SHA" '[{id:1, repo:"example-org/demo-os", pr:7, head_sha:$h, verdict:"BLOCK", source:"lead", note:"lead-review:lr-1"}]' > "$T/vrows.json"
jq -nc --arg c "$SHA" '[{id:1, user:{login:"cromford[bot]",type:"Bot"}, author_association:"NONE", commit_id:$c, state:"DISMISSED", body:"<!-- lead-review:lr-1 -->\nold"}]' > "$T/reviews-7.json"
mkdir -p "$ST"; : > "$ST/findings-lr-1"
setreqs "$(req lr-1 done BLOCK j2 1 "$(ago 5)")"; tick
[ "$(rposts)" = 1 ] && grep -qF 'finding Y' <<<"$(rbody 2)" && ok || bad "R4c no new review after a recorded reset (posts=$(rposts))"

# ── R5: a legacy landing with a recorded reset re-lands ─────────────────────
reset
jq -nc --arg h "$SHA" '[{id:4, repo:"example-org/demo-os", pr:7, head_sha:$h, verdict:"BLOCK", source:"lead", note:"lead-review:lr-1 report:state/lead-reviews/lr-7.md"}]' > "$T/vrows.json"
jq -nc --arg c "$SHA" '[{id:1, user:{login:"cromford[bot]",type:"Bot"}, author_association:"NONE", commit_id:$c, state:"CHANGES_REQUESTED", body:"<!-- lead-review:lr-1 -->\nold"}]' > "$T/reviews-7.json"
setreqs "$(req lr-1 done MERGE j2 1 "$(ago 5)")"; tick
[ "$(vposts)" = 1 ] && jq -r .note <<<"$(vrow 5)" | tr ' ' '\n' | grep -qx 'supersedes:4' && ok || bad "R5 no superseding row (rows=$(vposts)): $(vrow 5)"
[ "$(rstate 1)" = DISMISSED ] && [ "$(stamps)" = 1 ] && ok || bad "R5 legacy review not dismissed ($(rstate 1)) or not stamped ($(stamps))"

# ── R6: a failed dismissal on a BLOCK re-land ───────────────────────────────
land_j1
clearlogs; echo 500 > "$T/dismiss-status"; setreqs "$(req lr-1 done BLOCK j2 1 "$(ago 5)")"; tick
[ "$(rposts)" = 1 ] && [ "$(stamps)" = 0 ] && ok || bad "R6 want the new review posted and no stamp (posts=$(rposts) stamps=$(stamps))"
[ -e "$ST/superseded-lr-1" ] && bad "R6 superseded flag written after a failed dismissal" || ok
rm -f "$T/dismiss-status"; clearlogs; tick
[ "$(rposts)" = 0 ] && [ "$(vposts)" = 0 ] && [ "$(stamps)" = 1 ] && [ "$(rstate 1)" = DISMISSED ] && [ "$(rstate 2)" = CHANGES_REQUESTED ] \
  && ok || bad "R6 heal tick: posts=$(rposts) rows=$(vposts) stamps=$(stamps) #1=$(rstate 1) #2=$(rstate 2)"

# ── R7: alerts after a reset ─────────────────────────────────────────────────
alines() { cat "$H/logs/ALERTS.log" 2>/dev/null | grep -c 'lead review lr-1'; }
reset; mkdir -p "$ST"; : > "$ST/alerted-lr-1"
setreqs "$(req lr-1 requested null "" 1 "$(ago 10)")"; tick
[ "$(alines)" = 0 ] && ok || bad "R7 alerted 10 min after a reset"
reset; setreqs "$(req lr-1 requested null "" 1 "$(ago 10)")"; tick
[ "$(alines)" = 0 ] && ok || bad "R7 judged overdue from created_at, not reset_at"
reset; mkdir -p "$ST"; : > "$ST/alerted-lr-1"
setreqs "$(req lr-1 requested null "" 1 "$(ago 200)")"; tick
[ "$(alines)" = 1 ] && [ "$(cat "$ST/alerted-lr-1" 2>/dev/null)" = r1 ] && ok || bad "R7 overdue after a reset: lines=$(alines) flag='$(cat "$ST/alerted-lr-1" 2>/dev/null)'"
tick
[ "$(alines)" = 1 ] && ok || bad "R7 a second tick alerted again"
reset; mkdir -p "$ST"; : > "$ST/alerted-lr-1"
setreqs "$(req lr-1 failed null j2 1 "$(ago 5)")"; tick
[ "$(alines)" = 1 ] && ok || bad "R7 a failed re-review did not alert"

# ── R8: bin/lead-verdict.sh reset ───────────────────────────────────────────
reset
OUT=$(bash "$H/bin/lead-verdict.sh" reset lr-1 2>&1); RRC=$?
[ "$RRC" = 0 ] && grep -q '^POST /api/lead-reviews/lr-1/reset .* lead=1$' "$T/log/worker" && ok || bad "R8 reset rc=$RRC out=$OUT worker=$(cat "$T/log/worker")"
grep -q 'requested' <<<"$OUT" && grep -q 'reset_count 1' <<<"$OUT" && ok || bad "R8 output: $OUT"
echo 409 > "$T/reset-status"
OUT=$(bash "$H/bin/lead-verdict.sh" reset lr-1 2>&1); RRC=$?
[ "$RRC" = 1 ] && grep -q 'only a finished request can be reset' <<<"$OUT" && ok || bad "R8 409 rc=$RRC out=$OUT"
bash "$H/bin/lead-verdict.sh" reset >/dev/null 2>&1; RRC=$?
[ "$RRC" = 2 ] && ok || bad "R8 no id rc=$RRC"

# ── R9: the stamp is bound to the job ────────────────────────────────────────
reset; : > "$T/promoted409"; setreqs "$(req lr-1 done MERGE j2)"; tick
[ "$RC" = 0 ] && ok || bad "R9 rc=$RC"
LOGF | grep -q 'newer result on the request; next tick lands it' && ok || bad "R9 no log line: $(LOGF | tail -2)"
LOGF | grep -q 'stamped=0' && ok || bad "R9 counted a refused stamp: $(LOGF | tail -1)"

echo "lead-review-land-reland.bh-5400: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
