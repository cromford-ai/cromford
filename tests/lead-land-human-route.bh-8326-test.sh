#!/bin/bash
# tests/lead-land-human-route.bh-8326-test.sh — BH-8326: a lead BLOCK with no
# `- [BLOCK` finding line must not park a PR.
#   - A BLOCK report whose only BLOCK-level items are `[HUMAN ...]` lines (the
#     #8170 shape) is NOT empty: its row is posted, the report goes to the PR
#     as a COMMENT review (never REQUEST_CHANGES) whose third line names each
#     decision, and ONE warn lane-alert names them. No fix round is briefed.
#   - A second empty BLOCK on a head (BH-8476 already re-requested it once)
#     records NEEDS_HUMAN: a needs-human hold on the ticket, the
#     lead_empty_block ledger row moved to status needs-human, and ONE ALERTS
#     line that says NEEDS_HUMAN.
#
# Every case runs the REAL bin/lead-review-land.sh in a scratch harness
# (scratch_install_closure). Fakes: curl (the jobs worker), gh (pulls,
# reviews; the review state follows the posted event), bin/lane-alert.sh,
# bin/needs-human-hold.sh (logs its args; rc from a fixture file) and
# bin/fleet-conf.sh (one project, repo example-org/demo-os, board_prefix -).
#   C1-C14  the classifier decision table (by its effect) and the decision text
#   H1-H6   the go-live-only BLOCK route
#   N1-N6   the second empty BLOCK: NEEDS_HUMAN
#   V1      0 calls outside the fakes
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-land-human-route.bh-8326-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lpp-stub.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }
unset BOX_NAME JOBS_BOX LEAD_REVIEW_OVERDUE_MIN HUB_BOX_NAME LEAD_REVIEW_SPOTCHECK_PCT GH_TOKEN GITHUB_TOKEN
unset LEAD_REVIEW_EMPTY_CAPTURE_BYTES LEAD_REVIEW_EMPTY_KEEP_DAYS LEAD_REVIEW_LAND_RERUN_MAX

POSTSCRIPT='The monitor expired after it delivered all 10 results. The review above is final.

VERDICT: BLOCK'

L="$T/l"; HL="$L/h"; ST="$HL/state/lead-review-land"
mkdir -p "$HL/state" "$HL/logs" "$L/fakebin" "$L/log" "$L/tmp" "$L/cfg"
scratch_install_closure bin/lead-review-land.sh "$HL" >/dev/null || bad "closure of bin/lead-review-land.sh"
scratch_install_closure bin/lead-verdict.sh "$HL" >/dev/null || bad "closure of bin/lead-verdict.sh"
scratch_install_closure bin/jobs-client.sh "$HL" >/dev/null || bad "closure of bin/jobs-client.sh"
[ -r "$HL/bin/lib/needs-human.sh" ] && ok || bad "the closure has no bin/lib/needs-human.sh (the hold route needs nh_fingerprint)"
lpp_install "$L/fakebin" "$L/lpp.json" "$L/lpp-down"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"\nexit 0\n' "$L/log/alerts" > "$HL/bin/lane-alert.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"\nexit "$(cat "%s" 2>/dev/null || echo 0)"\n' "$L/log/holds" "$L/hold-rc" > "$HL/bin/needs-human-hold.sh"
printf '#!/bin/bash\ncase "$1" in --projects) echo demo-os ;; demo-os) case "$2" in repo) echo example-org/demo-os ;; board_prefix) echo - ;; esac ;; esac\n' > "$HL/bin/fleet-conf.sh"
chmod +x "$HL/bin/lane-alert.sh" "$HL/bin/needs-human-hold.sh" "$HL/bin/fleet-conf.sh"
echo box-hub > "$HL/state/box-name"
printf 'lead-test-token-fixture\n' > "$L/cfg/token"; chmod 600 "$L/cfg/token"
LSHA=$(printf 'c%.0s' {1..40}); OSHA=$(printf 'd%.0s' {1..40}); SLUG=example-org/demo-os
MARK="$SLUG#41@$LSHA"
RID=lr-8326

# The jobs worker. Every call is logged with its full URL (V1).
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
printf '%s\n' "$url" >> "@L@/log/urls"
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
    out=$(jq -c --arg k "$k" --arg v "$v" '.[$k + " " + $v] // empty | {ledger:.}' "@L@/ledger.json")
    [ -n "$out" ] || { code=404; out='{"error":"not found"}'; } ;;
  "PUT /api/ledger")
    [ -f "@L@/ledger.json" ] || echo '{}' > "@L@/ledger.json"
    jq -c --argjson r "$body" '. + {($r.kind + " " + $r.key): $r}' "@L@/ledger.json" > "@L@/ledger.tmp" && mv "@L@/ledger.tmp" "@L@/ledger.json"
    out=$(jq -c '{ledger:.}' <<<"$body") ;;
  "GET /api/lead-reviews"*) out=$(cat "@L@/requests.json") ;;
  "POST /api/lead-reviews/"*/promoted)
    if [ "$lead" != 1 ]; then code=403; out='{"error":"needs the lead token"}'
    else out='{"request":{"promoted_verdict_at":"2026-10-27T00:00:00Z"}}'; fi ;;
  "POST /api/lead-reviews/"*/reset)
    if [ "$lead" != 1 ]; then code=403; out='{"error":"needs the lead token"}'
    else out='{"request":{"id":"lr-8326","status":"requested","reset_count":1}}'; fi ;;
  "GET /api/jobs/"*/artifacts)
    j="${p#/api/jobs/}"; j="${j%/artifacts}"
    if [ -f "@L@/artifacts-$j.json" ]; then out=$(cat "@L@/artifacts-$j.json")
    else out='{"artifacts":[]}'; fi ;;
  "POST /api/verdicts")
    n=$(jq 'map(.id) | max // 0' "@L@/vrows.json")
    row=$(jq -c --argjson id "$((n + 1))" '. + {id:$id, created_at:"2026-10-27T00:00:00Z"}' <<<"$body")
    jq -c --argjson r "$row" '. + [$r]' "@L@/vrows.json" > "@L@/vrows.tmp" && mv "@L@/vrows.tmp" "@L@/vrows.json"
    code=201; out=$(jq -c '{verdict:.}' <<<"$row") ;;
  "GET /api/verdicts?"*)
    out=$(jq -c --arg r "$(qp repo)" --argjson pr "$(qp pr)" --arg h "$(qp head)" '
      [.[] | select(.repo == $r and .pr == $pr)] | sort_by(-.id) as $rows
      | {repo:$r, pr:$pr, head:$h,
         standing:([$rows[] | select(.head_sha == $h)] | first),
         rows:[$rows[] | {retracted_at:null} + .], truncated:false}' "@L@/vrows.json") ;;
  *) code=404; out='{"error":"unknown endpoint","worker":"harness-jobs"}' ;;
esac
printf '%s\n%s' "$out" "$code"
EOF
# GitHub. A posted review's state follows its event (COMMENT -> COMMENTED).
cat > "$L/fakebin/gh" <<'EOF'
#!/bin/bash
m=GET; path=""; prev=""; ev=""; cid=""; body=""
for a in "$@"; do
  case "$prev" in
    -X) m="$a" ;;
    -f|-F) v="${a#*=}"; case "$v" in @*) v=$(cat "${v#@}") ;; esac
           case "${a%%=*}" in event) ev="$v" ;; commit_id) cid="$v" ;; body) body="$v" ;; esac ;;
  esac
  case "$a" in repos/*) path="$a" ;; esac
  prev="$a"
done
printf '%s %s event=%s commit_id=%s\n' "$m" "$path" "$ev" "$cid" >> "@L@/log/gh"
reply() { printf 'HTTP/1.1 %s X\r\n\r\n%s\n' "$1" "$2"; exit 0; }
n=$(printf '%s' "$path" | sed -nE 's#^repos/[^/]+/[^/]+/pulls/([0-9]+).*#\1#p')
rf="@L@/reviews-$n.json"
case "$m $path" in
  "POST repos/"*"/pulls/"*"/reviews")
    c=$(cat "@L@/review-code" 2>/dev/null || echo 200)
    [ "$c" = 200 ] || reply "$c" '{"message":"fixture failure"}'
    st=CHANGES_REQUESTED; [ "$ev" = COMMENT ] && st=COMMENTED
    [ -f "$rf" ] || echo '[]' > "$rf"
    jq -c --arg c "$cid" --arg b "$body" --arg s "$st" \
      '. + [{id:(length + 1), user:{login:"cromford[bot]",type:"Bot"}, author_association:"NONE", commit_id:$c, state:$s, body:$b}]' \
      "$rf" > "$rf.tmp" && mv "$rf.tmp" "$rf"
    printf '%s' "$body" > "@L@/log/review-body"
    reply 200 '{"id":1}' ;;
  "GET repos/"*"/pulls/"*"/reviews"*)
    case "$path" in *"page=1"|*"page=1&"*) ;; *) reply 200 '[]' ;; esac
    if [ -f "$rf" ]; then reply 200 "$(cat "$rf")"; else reply 200 '[]'; fi ;;
  "GET repos/"*"/pulls/"*)
    reply 200 "{\"head\":{\"sha\":\"$(cat "@L@/livehead")\",\"ref\":\"$(cat "@L@/branch")\"}}" ;;
  "POST repos/"*"/statuses/"*) reply 201 '{"id":1}' ;;
esac
exit 0
EOF
sed -i "s#@L@#$L#g" "$L/fakebin/curl" "$L/fakebin/gh"
chmod +x "$L/fakebin/curl" "$L/fakebin/gh"

# lreq <job> [reset_count] [verdict] -> request $RID on PR 41 @ $LSHA
lreq() {
  jq -nc --arg i "$RID" --arg v "${3:-BLOCK}" --arg j "$1" --arg rc "${2:-}" --arg h "$LSHA" \
    '{id:$i, repo:"example-org/demo-os", pr:41, head_sha:$h, status:"done", verdict:$v, reviewer_model:"stub-model",
      report_ref:"state/lead-reviews/lr-41.md", promoted_verdict_at:null, box:"box-demo", job_id:$j,
      detail:null, created_at:"2026-10-27T00:00:00Z", updated_at:"2026-10-27T00:00:00Z"}
     + (if $rc == "" then {} else {reset_count:($rc|tonumber)} end)'
}
lsetreq() { lreq "$@" | jq -sc '{requests:., truncated:false}' > "$L/requests.json"; }
# lart <job> <report-body> [truncated]
lart() {
  jq -nc --arg b "$2" --arg t "${3:-}" '{body:$b, path:"state/lead-reviews/lr-41.md", verdict:"BLOCK"}
    + (if $t == "" then {} else {truncated:true} end)' \
    | jq -Rc '{artifacts:[{artifact_kind:"lead_review_report", artifact_ref:"state/lead-reviews/lr-41.md", phase_id:null, detail:.}]}' \
    > "$L/artifacts-$1.json"
}
# lreport <text> [head] — the header bin/lead-review.sh writes, then <text>
lreport() { local h="${2:-$LSHA}"; printf '# Lead review lr-41-%s (%s#41 at %s)\n\n- verdict: BLOCK\n\n%s\n' "${h:0:12}" "$SLUG" "$h" "$1"; }
lreset() {
  scratch_rm "$L/log"; mkdir -p "$L/log"
  : > "$L/log/gh"; : > "$L/log/worker"; : > "$L/log/alerts"; : > "$L/log/holds"; : > "$L/log/urls"
  rm -f "$L/ledger.json" "$L/vrows.json" "$L"/reviews-*.json "$L"/artifacts-*.json "$L/review-code" "$L/hold-rc" "$HL/logs/lead-review-land.log"
  echo "$LSHA" > "$L/livehead"; echo "ticket/BH-41" > "$L/branch"
  scratch_rm "$HL/logs/ALERTS.log"; scratch_rm "$HL/logs/lead-review-empty"; scratch_rm "$ST"
  lsetreq j1
}
ltick() {
  ( cd "$L" && env "$@" PATH="$L/fakebin:$PATH" HARNESS="$HL" HARNESS_SECRET=test-secret-fixture JOBS_URL=https://jobs.test \
      JOBS_RETRIES=0 TMPDIR="$L/tmp" LANE_GATE_DISABLE=1 LEAD_VERDICT_TOKEN_FILE="$L/cfg/token" GH_ETAG=0 MC_KEYED_WAKE=0 \
      bash "$HL/bin/lead-review-land.sh" ) > "$L/out" 2>&1; LRC=$?
}
vposts()  { grep -c '^POST /api/verdicts ' "$L/log/worker"; }
rposts()  { grep -c "^POST repos/$SLUG/pulls/41/reviews " "$L/log/gh"; }
comments(){ grep -c "^POST repos/$SLUG/pulls/41/reviews event=COMMENT " "$L/log/gh"; }
rchanges(){ grep -c "^POST repos/$SLUG/pulls/41/reviews event=REQUEST_CHANGES " "$L/log/gh"; }
resets()  { grep -c "^POST /api/lead-reviews/$RID/reset " "$L/log/worker"; }
stamps()  { grep -c "^POST /api/lead-reviews/$RID/promoted " "$L/log/worker"; }
alerts_n(){ cat "$HL/logs/ALERTS.log" 2>/dev/null | grep -c "lead review $RID"; }
golive_n(){ grep -c 'lead-golive-block-' "$L/log/alerts"; }
holds_n() { grep -c . "$L/log/holds"; }
llog()    { cat "$HL/logs/lead-review-land.log" 2>/dev/null; }
mstatus() { jq -r --arg k "lead_empty_block $MARK" '.[$k].status // ""' "$L/ledger.json" 2>/dev/null; }
gstatus() { jq -r --arg k "lead_golive_block $MARK" '.[$k].status // ""' "$L/ledger.json" 2>/dev/null; }
mark_seed() { jq -nc --arg k "$MARK" '{("lead_empty_block " + $k): {kind:"lead_empty_block", key:$k, status:"rerequested", detail:"lead-review:lr-8326 r0"}}' > "$L/ledger.json"; }

# ── C1-C13: the classifier. empty = 0 rows + 1 reset; golive = 1 row + 1
#    COMMENT + 0 REQUEST_CHANGES; findings = 1 row + 1 REQUEST_CHANGES ──
while IFS='|' read -r case want art; do
  [ -n "$case" ] || continue
  lreset
  case "$art" in
    trunc:*) lart j1 "$(lreport "$(printf '%b' "${art#trunc:}")")" truncated ;;
    other:*) lart j1 "$(lreport "$(printf '%b' "${art#other:}")" "$OSHA")" ;;
    *) lart j1 "$(lreport "$(printf '%b' "$art")")" ;;
  esac
  ltick
  got="other($(vposts) rows, $(resets) resets, $(comments) comments, $(rchanges) request-changes)"
  [ "$(vposts)" = 0 ] && [ "$(resets)" = 1 ] && [ "$(rposts)" = 0 ] && got=empty
  [ "$(vposts)" = 1 ] && [ "$(resets)" = 0 ] && [ "$(comments)" = 1 ] && [ "$(rchanges)" = 0 ] && got=golive
  [ "$(vposts)" = 1 ] && [ "$(resets)" = 0 ] && [ "$(comments)" = 0 ] && [ "$(rchanges)" = 1 ] && got=findings
  [ "$got" = "$want" ] && ok || bad "$case want $want, got $got: $(llog | tail -2)"
done <<'TABLE'
C1|empty|The review above is final.\n\nVERDICT: BLOCK
C2|empty|Findings\n- [NOTE] x\n\nVERDICT: BLOCK
C3|empty|Findings\n- [NOTE] the [HUMAN go-live] step is in docs\n\nVERDICT: BLOCK
C4|empty|HUMAN go-live: set DNS\n\nVERDICT: BLOCK
C5|golive|Findings\n- [HUMAN go-live] set the DNS record\n\nVERDICT: BLOCK
C6|golive|[HUMAN go-live] set DNS\n\nVERDICT: BLOCK
C7|golive|Findings\n- **[HUMAN go-live]** add the Stripe key\n\nVERDICT: BLOCK
C8|golive|Findings\n- [human decision] pick the vendor tier\n\nVERDICT: BLOCK
C9|findings|Findings\n- [HUMAN go-live] x\n- [BLOCK] a.sh:3 y\n\nVERDICT: BLOCK
C10|findings|Findings\n- [BLOCK needs-human] x\n\nVERDICT: BLOCK
C11|findings|trunc:Findings\n- [HUMAN go-live] x
C12|findings|other:Findings\n- [HUMAN go-live] x\n\nVERDICT: BLOCK
C13|golive|Findings\r\n- [HUMAN go-live] x\r\n\r\nVERDICT: BLOCK\r
TABLE
# C7's decision text drops the bold and the tag.
lreset; lart j1 "$(lreport $'Findings\n- **[HUMAN go-live]** add the Stripe key\n\nVERDICT: BLOCK')"; ltick
[ "$(sed -n 3p "$L/log/review-body" 2>/dev/null)" = "Human decision needed before this PR can merge: add the Stripe key" ] && ok \
  || bad "C7 decision line: '$(sed -n 3p "$L/log/review-body" 2>/dev/null)'"
# C13: no carriage return rides into the decision text.
lreset; lart j1 "$(lreport $'Findings\r\n- [HUMAN go-live] set DNS\r\n\r\nVERDICT: BLOCK\r')"; ltick
[ "$(sed -n 3p "$L/log/review-body" 2>/dev/null)" = "Human decision needed before this PR can merge: set DNS" ] && ok \
  || bad "C13 decision line: '$(sed -n 3p "$L/log/review-body" 2>/dev/null | od -c | head -3)'"
# Two decisions: both named, in report order, joined by '; '; a ';' inside one stays as written.
lreset; lart j1 "$(lreport $'Findings\n- [HUMAN go-live] set DNS;TTL 300\n1. [HUMAN decision] pick the tier\n\nVERDICT: BLOCK')"; ltick
[ "$(sed -n 3p "$L/log/review-body" 2>/dev/null)" = "Human decision needed before this PR can merge: set DNS;TTL 300; pick the tier" ] && ok \
  || bad "C14 decision line: '$(sed -n 3p "$L/log/review-body" 2>/dev/null)'"

# ── H1: a go-live-only BLOCK: the row, one COMMENT, no reset, stamped ──
DEC="set the DNS record for demo.example.com"
GOLIVE=$(lreport "Findings
- [HUMAN go-live] $DEC

VERDICT: BLOCK")
lreset; lart j1 "$GOLIVE"; ltick
[ "$LRC" = 0 ] && ok || bad "H1 rc=$LRC $(cat "$L/out")"
[ "$(vposts)" = 1 ] && grep -q '^POST /api/verdicts .*"verdict":"BLOCK"' "$L/log/worker" && ok || bad "H1 want 1 BLOCK row, got $(vposts)"
[ "$(resets)" = 0 ] && ok || bad "H1 reset a go-live-only BLOCK ($(resets))"
[ "$(comments)" = 1 ] && ok || bad "H1 want 1 COMMENT review, got $(comments): $(cat "$L/log/gh")"
[ "$(rchanges)" = 0 ] && ok || bad "H1 posted $(rchanges) REQUEST_CHANGES review(s)"
grep -q "event=COMMENT commit_id=$LSHA" "$L/log/gh" && ok || bad "H1 the COMMENT is not bound to the head"
[ "$(stamps)" = 1 ] && ok || bad "H1 want 1 stamp, got $(stamps)"
[ "$(holds_n)" = 0 ] && ok || bad "H1 placed a hold: $(cat "$L/log/holds")"
# H1: the posted comment is a lead_golive_block ledger row, never a state/ flag (BH-4159).
[ "$(gstatus)" = commented ] && ok || bad "H1 lead_golive_block ledger status '$(gstatus)', want commented: $(cat "$L/ledger.json" 2>/dev/null)"
[ -e "$ST/findings-$RID" ] && bad "H1 wrote the state/ findings flag for a go-live COMMENT" || ok
# ── H3: the decision line and the one warn alert ──
[ "$(sed -n 3p "$L/log/review-body")" = "Human decision needed before this PR can merge: $DEC" ] && ok \
  || bad "H3 line 3 of the body: '$(sed -n 3p "$L/log/review-body")'"
grep -qF -- "- [HUMAN go-live] $DEC" "$L/log/review-body" && ok || bad "H3 the report is not in the body"
[ "$(golive_n)" = 1 ] && ok || bad "H3 want 1 lead-golive-block alert, got $(golive_n): $(cat "$L/log/alerts")"
grep 'lead-golive-block-' "$L/log/alerts" | grep -qF "$DEC" && ok || bad "H3 the alert does not name the decision"
grep 'lead-golive-block-' "$L/log/alerts" | grep -qF "bin/lead-verdict.sh post $SLUG 41 $LSHA" && ok || bad "H3 the alert does not name bin/lead-verdict.sh post"
grep 'lead-golive-block-' "$L/log/alerts" | grep -q -- '--severity warn' && ok || bad "H3 the alert is not a warn"
# ── H6: the land log never says the U13-EMPTY text ──
grep -q 'BLOCK report has no finding line' <<<"$(llog)" && bad "H6 the log says 'BLOCK report has no finding line' (U13-EMPTY would reset it)" || ok
grep -q 'go-live-only BLOCK; decision comment posted, no fix round briefed' <<<"$(llog)" && ok || bad "H6 no go-live log line: $(llog | tail -2)"
# ── H5: the REAL br_lead_pick briefs nothing from that COMMENT ──
BRSRC="$SRC/bin/blocked-resolver.sh"
plift() { awk -v n="$1" '$0 ~ "^"n"\\(\\) \\{" {f=1} f{print} f&&/^}/{exit}' "$BRSRC"; }
{ grep -E '^(BR_REVIEW_FOOTER|BR_LEAD_HDR)=' "$BRSRC"; plift br_lead_merges_only; plift br_lead_pick; } > "$L/pick.sh"
grep -q '^br_lead_pick()' "$L/pick.sh" && ok || bad "H5 could not lift br_lead_pick"
PH="$L/ph"; mkdir -p "$PH/env" "$PH/logs" "$PH/state/gh-etag"
printf 'gh_rest() { return 75; }\n' > "$L/pick-stubs.sh"
PICK() { HARNESS="$PH" bash -c '. "$1/bin/lib/gh-pr-list.sh"; . "$2"; . "$3"; br_lead_pick o/demo "$4" "$5"' \
  _ "$SRC" "$L/pick-stubs.sh" "$L/pick.sh" "$LSHA" "$1" > "$L/pick.out" 2>/dev/null; echo $?; }
CROWS=$(jq -c '[.[] | {l:.user.login, t:.user.type, a:.author_association, c:.commit_id, s:.state, b:.body}]' "$L/reviews-41.json" 2>/dev/null)
[ "$(jq -r '.[0].s' <<<"$CROWS")" = COMMENTED ] && ok || bad "H5 fixture: the posted review is not COMMENTED: $CROWS"
[ "$(PICK "$CROWS")" = 1 ] && [ ! -s "$L/pick.out" ] && ok || bad "H5 br_lead_pick briefed a fix round from a go-live COMMENT"
[ "$(PICK "$(jq -c 'map(.s = "CHANGES_REQUESTED")' <<<"$CROWS")")" = 0 ] && ok || bad "H5 control: the same body as CHANGES_REQUESTED must brief (the lift works)"
# ── H2: a second tick: nothing posted, nothing alerted ──
: > "$L/log/gh"; : > "$L/log/alerts"; ltick
[ "$(rposts)" = 0 ] && ok || bad "H2 posted $(rposts) review(s) on a rerun"
[ "$(golive_n)" = 0 ] && ok || bad "H2 alerted again on a rerun"

# ── H4: the COMMENT POST answers 500: no flag, no alert, no stamp; next tick posts once ──
lreset; lart j1 "$GOLIVE"; echo 500 > "$L/review-code"; ltick
[ "$(vposts)" = 1 ] && ok || bad "H4 the row was not posted ($(vposts))"
[ "$(stamps)" = 0 ] && ok || bad "H4 stamped after a failed COMMENT"
[ "$(golive_n)" = 0 ] && ok || bad "H4 alerted after a failed COMMENT"
[ -e "$ST/findings-$RID" ] && bad "H4 wrote the findings flag after a failed COMMENT" || ok
[ -z "$(gstatus)" ] && ok || bad "H4 wrote the lead_golive_block ledger row after a failed COMMENT"
rm -f "$L/review-code"; : > "$L/log/gh"; : > "$L/log/worker"; ltick
[ "$(comments)" = 1 ] && [ "$(stamps)" = 1 ] && [ "$(golive_n)" = 1 ] && ok \
  || bad "H4 the retry tick: comments=$(comments) stamps=$(stamps) alerts=$(golive_n)"

# ── N1: the first empty BLOCK: re-requested once, no hold ──
lreset; lart j1 "$(lreport "$POSTSCRIPT")"; ltick
[ "$(vposts)" = 0 ] && [ "$(resets)" = 1 ] && ok || bad "N1 posts=$(vposts) resets=$(resets)"
[ "$(mstatus)" = rerequested ] && ok || bad "N1 ledger status '$(mstatus)', want rerequested"
[ "$(holds_n)" = 0 ] && ok || bad "N1 placed a hold on the first empty BLOCK"
# ── N2: the re-review is empty again: NEEDS_HUMAN ──
: > "$L/log/worker"; A0=$(alerts_n)
lart j2 "$(lreport "$POSTSCRIPT")"; lsetreq j2 1; ltick
[ "$(vposts)" = 0 ] && [ "$(resets)" = 0 ] && ok || bad "N2 posts=$(vposts) resets=$(resets)"
[ "$(stamps)" = 1 ] && ok || bad "N2 want 1 stamp, got $(stamps)"
[ "$(holds_n)" = 1 ] && ok || bad "N2 want 1 hold call, got $(holds_n)"
grep -qE '^demo-os 41 [0-9a-f]{12} .+ lead-review$' "$L/log/holds" && ok || bad "N2 placer args: $(cat "$L/log/holds")"
[ "$(mstatus)" = needs-human ] && ok || bad "N2 ledger status '$(mstatus)', want needs-human"
[ "$(( $(alerts_n) - A0 ))" = 1 ] && ok || bad "N2 want exactly 1 new ALERTS line, got $(( $(alerts_n) - A0 ))"
tail -1 "$HL/logs/ALERTS.log" | grep -q 'NEEDS_HUMAN' && ok || bad "N2 the ALERTS line does not say NEEDS_HUMAN: $(tail -1 "$HL/logs/ALERTS.log")"
tail -1 "$HL/logs/ALERTS.log" | grep -qF 'a needs-human hold is on demo-os#41' && ok || bad "N2 the ALERTS line does not name the hold"
tail -1 "$HL/logs/ALERTS.log" | grep -qF 'a re-review was already requested once for this head' && ok || bad "N2 the BH-8476 phrase is gone"
grep -qF "lead-review: empty BLOCK on $SLUG#41 @${LSHA:0:12}: no verdict recorded, already re-requested once for this head; NEEDS_HUMAN" <<<"$(llog)" && ok || bad "N2 log line: $(llog | tail -2)"
# ── N3: a third tick on the same request writes no new line ──
A1=$(alerts_n); ltick
[ "$(alerts_n)" = "$A1" ] && ok || bad "N3 a rerun wrote $(( $(alerts_n) - A1 )) new ALERTS line(s)"

# ── N4: the placer cannot read the thread (rc 75): nothing written ──
lreset; lart j1 "$(lreport "$POSTSCRIPT")"; mark_seed; echo 75 > "$L/hold-rc"; ltick
[ "$(stamps)" = 0 ] && ok || bad "N4 stamped on placer rc 75"
[ "$(mstatus)" = rerequested ] && ok || bad "N4 ledger status '$(mstatus)', want rerequested"
[ "$(alerts_n)" = 0 ] && ok || bad "N4 wrote $(alerts_n) ALERTS line(s) on placer rc 75"

# ── N5: ALERTS.log not writable: not stamped ──
lreset; lart j1 "$(lreport "$POSTSCRIPT")"; mark_seed; mkdir -p "$HL/logs/ALERTS.log"; ltick
[ "$(stamps)" = 0 ] && [ "$(vposts)" = 0 ] && ok || bad "N5 stamps=$(stamps) posts=$(vposts)"
scratch_rm "$HL/logs/ALERTS.log"

# ── N6: a branch with no ticket: no hold, the alert says why, stamped ──
lreset; lart j1 "$(lreport "$POSTSCRIPT")"; mark_seed; echo feature/x > "$L/branch"; ltick
[ "$(holds_n)" = 0 ] && ok || bad "N6 placed a hold with no ticket"
grep -qF "NEEDS_HUMAN: no hold can be placed (branch 'feature/x' names no ticket)" "$HL/logs/ALERTS.log" 2>/dev/null && ok \
  || bad "N6 ALERTS line: $(cat "$HL/logs/ALERTS.log" 2>/dev/null)"
[ "$(stamps)" = 1 ] && ok || bad "N6 want 1 stamp, got $(stamps)"
[ "$(mstatus)" = needs-human ] && ok || bad "N6 ledger status '$(mstatus)'"

# ── V1: 0 calls outside the fakes ──
[ "$(grep -vc '^https://jobs.test' "$L/log/urls")" = 0 ] && ok || bad "V1 a curl call left the fake: $(grep -v '^https://jobs.test' "$L/log/urls" | head -3)"
[ "$(PATH="$L/fakebin:$PATH" command -v gh)" = "$L/fakebin/gh" ] && ok || bad "V1 the fake gh is not first on PATH"

echo "lead-land-human-route.bh-8326: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
