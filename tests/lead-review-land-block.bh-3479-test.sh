#!/bin/bash
# tests/lead-review-land-block.bh-3479-test.sh — BH-3547 (BH-3479.3): the two
# additions to the hub land lane, bin/lead-review-land.sh, run WHOLE against a
# scratch harness carrying the real jobs client, bin/lib/jobs/*.sh,
# bin/lead-verdict.sh and the libs, with only these stubbed:
#   * curl — a stateful jobs worker (lead-reviews list, verdicts rows, the
#            /promoted stamp) plus GET /api/jobs/<job>/artifacts, answered from
#            $T/artifacts-<job>.json (500 when $T/art500 exists);
#   * gh   — GitHub: pulls/<n> answers the head ($T/head-<n>, else $SHA);
#            TEST-CHANGE (BH-5213): a posted review is authored by the hub App,
#            cromford[bot] (type Bot), as on GitHub (#4952 review
#            5435677059); it was operator/User, and step 2d now dismisses only
#            the lane's own bot review, so the old fixture would read as a
#            person's review the lane must never touch.
#            pulls/<n>/reviews GET answers $T/reviews-<n>.json (500 on
#            $T/revget500); a reviews POST appends a cromford[bot] review to that
#            file (status from $T/review-status, default 200; $T/review422 makes
#            REQUEST_CHANGES answer 422 while COMMENT answers 200); a
#            reviews/<id>/dismissals PUT marks that review DISMISSED (status
#            from $T/dismiss-status, default 200);
#   * bin/lane-alert.sh — appends its args to $T/log/alerts.
# Every worker and gh call also lands in $T/log/seq, so order across the two is
# readable.
#   T3.1  L1 L1b L1c L2 L2b L3 L4 L5 L6 L7 + a failed row (findings on BLOCK)
#   T3.2  L8 L9 L10                                    (MERGE spot-check)
#   L11   a later lead MERGE dismisses the older lead BLOCK review, never a
#         person's (review finding 1: Mergify's changes-requested gate)
#   L12   a stamp-only BLOCK retry after the PR moved posts nothing (finding 2)
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-review-land-block.bh-3479-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

SHA=$(printf 'a%.0s' {1..40})
SHA2=$(printf 'b%.0s' {1..40})
SLUG=example-org/demo-os

# build <scratch-root> — a fresh scratch harness under <root>; sets H.
build() {
  H="$1/h"; mkdir -p "$H/bin/lib/jobs" "$H/state" "$H/logs"
  cp "$DIR/bin/jobs-client.sh" "$DIR/bin/lead-verdict.sh" "$H/bin/"
  cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
  for f in env-path lead-reviews verdicts hub-box lane-gate gh-rest gh-app-auth verdict-status; do cp "$DIR/bin/lib/$f.sh" "$H/bin/lib/"; done
  # TEST-CHANGE (BH-3683): the lane requires bin/lib/lead-authority.sh and its
  # catalog; demo-os is not governed, so nothing this suite pins moves.
  mkdir -p "$H/catalog"; cp "$DIR/bin/lib/lead-authority.sh" "$H/bin/lib/"; cp "$DIR/catalog/lead-protected-paths.tsv" "$H/catalog/"
  cp "$DIR/bin/lead-review-land.sh" "$H/bin/"
  # BH-5213: step 2d's own-review rule lives in bin/lib/lead-stale-review.sh.
  scratch_install_closure bin/lead-review-land.sh "$H" >/dev/null || { echo "closure install of bin/lead-review-land.sh failed"; exit 1; }
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"\nexit 0\n' "$T/log/alerts" > "$H/bin/lane-alert.sh"
  chmod +x "$H/bin/lane-alert.sh"
  echo box-hub > "$H/state/box-name"
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
  "GET /api/lead-reviews"*) out=$(cat "@T@/requests.json") ;;
  "POST /api/lead-reviews/"*/promoted)
    if [ "$lead" != 1 ]; then code=403; out='{"error":"needs the lead token"}'
    else out='{"request":{"promoted_verdict_at":"2026-09-29T00:00:00Z"}}'; fi ;;
  "GET /api/jobs/"*/artifacts)
    j="${p#/api/jobs/}"; j="${j%/artifacts}"
    if [ -e "@T@/art500" ]; then code=500; out='{"error":"boom"}'
    elif [ -f "@T@/artifacts-$j.json" ]; then out=$(cat "@T@/artifacts-$j.json")
    else out='{"artifacts":[]}'; fi ;;
  "POST /api/verdicts")
    n=$(jq length "@T@/vrows.json")
    row=$(jq -c --argjson id "$((n + 1))" '. + {id:$id, created_at:"2026-09-29T00:00:00Z"}' <<<"$body")
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
printf '%s %s event=%s commit_id=%s\n' "$m" "$path" "$ev" "$cid" >> "@T@/log/gh"
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
  "POST repos/"*"/pulls/"*"/reviews")
    printf '%s' "$body" > "@T@/log/body-$n-$(wc -l < "@T@/log/gh" | tr -d ' ')"
    if [ -e "@T@/review422" ] && [ "$ev" = REQUEST_CHANGES ]; then reply 422 '{"message":"Unprocessable Entity"}'; fi
    st=200; [ -f "@T@/review-status" ] && st=$(cat "@T@/review-status")
    case "$st" in 2*) ;; *) reply "$st" '{"message":"boom"}' ;; esac
    case "$ev" in REQUEST_CHANGES) s=CHANGES_REQUESTED ;; COMMENT) s=COMMENTED ;; APPROVE) s=APPROVED ;; *) s=PENDING ;; esac
    [ -f "$rf" ] || echo '[]' > "$rf"
    jq -c --arg c "$cid" --arg s "$s" --arg b "$body" \
      '. + [{id:(length + 1), user:{login:"cromford[bot]",type:"Bot"}, author_association:"NONE", commit_id:$c, state:$s, body:$b}]' \
      "$rf" > "$rf.tmp" && mv "$rf.tmp" "$rf"
    reply 200 '{"id":1}' ;;
  "GET repos/"*"/pulls/"*"/reviews"*)
    [ -e "@T@/revget500" ] && reply 500 '{"message":"boom"}'
    [ -e "@T@/fullpages" ] || case "$path" in *"page=1"|*"page=1&"*) ;; *) reply 200 '[]' ;; esac
    if [ -f "$rf" ]; then reply 200 "$(cat "$rf")"; else reply 200 '[]'; fi ;;
  "GET repos/"*"/pulls/"*)
    h="@SHA@"; [ -f "@T@/head-$n" ] && h=$(cat "@T@/head-$n")
    reply 200 "{\"head\":{\"sha\":\"$h\"}}" ;;
  "POST repos/"*"/statuses/"*) reply 201 '{"id":1}' ;;
esac
exit 0
EOF
sed -i "s#@T@#$T#g; s#@SHA@#$SHA#g" "$T/fakebin/curl" "$T/fakebin/gh"
chmod +x "$T/fakebin/curl" "$T/fakebin/gh"

export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
  JOBS_RETRIES=0 TMPDIR="$T/tmp" LANE_GATE_DISABLE=1 LEAD_VERDICT_TOKEN_FILE="$T/cfg/token" GH_ETAG=0
unset BOX_NAME JOBS_BOX LEAD_REVIEW_OVERDUE_MIN HUB_BOX_NAME LEAD_REVIEW_SPOTCHECK_PCT

# req <id> <status> <verdict|null> [pr] [head] [job_id] -> one request object
req() {
  jq -nc --arg i "$1" --arg s "$2" --arg v "$3" --argjson pr "${4:-7}" --arg h "${5:-$SHA}" --arg j "${6-j1}" \
    '{id:$i, repo:"example-org/demo-os", pr:$pr, head_sha:$h, status:$s,
      verdict:(if $v == "null" then null else $v end), reviewer_model:"stub-model",
      report_ref:("state/lead-reviews/lr-\($pr)-" + $h[0:12] + ".md"), promoted_verdict_at:null,
      job_id:(if $j == "" then null else $j end), box:"box-demo",
      detail:null, created_at:"2026-09-29T00:00:00Z", updated_at:"2026-09-29T00:00:00Z"}'
}
setreqs() { printf '%s\n' "$@" | jq -sc '{requests:., truncated:false}' > "$T/requests.json"; }
# art <job> <body> [truncated] — the lead_review_report artifact, its detail a JSON string (lr_detail's shape)
art() {
  jq -nc --arg b "$2" --arg t "${3:-}" '{body:$b, path:"state/lead-reviews/report.md", verdict:"BLOCK"}
    + (if $t == "" then {} else {truncated:true} end)' \
    | jq -Rc --arg j "$1" '{artifacts:[{artifact_kind:"lead_review_report", artifact_ref:"state/lead-reviews/report.md", phase_id:null, detail:.}]}' \
    > "$T/artifacts-$1.json"
}
# TEST-CHANGE (BH-6090): the finding is a `- [BLOCK]` line, the shape
# bin/lead-review.sh stores. The lane no longer posts a BLOCK report with no
# `- [BLOCK` line (tests/lead-review-postscript.bh-6090-test.sh L1), so the old
# `- finding X:` line would make every case here a withheld review. The
# `finding X` text every assertion greps for is unchanged.
REPORT="# Lead review lr-7-${SHA:0:12} ($SLUG#7 at $SHA)

- [BLOCK] a.sh:3 finding X: the retry loop never stops
VERDICT: BLOCK"
reset() {
  scratch_rm "$T/log"; rm -f "$T"/{art500,revget500,review-status,review422,fullpages,vrows.json,dismiss-status} "$T"/reviews-*.json "$T"/artifacts-*.json "$T"/head-*
  mkdir -p "$T/log"; : > "$T/log/gh"; : > "$T/log/worker"; : > "$T/log/alerts"; : > "$T/log/seq"
  rm -f "$H/logs/lead-review-land.log" "$H/logs/ALERTS.log"
  scratch_rm "$H/state/lead-review-land"
  setreqs "$(req lr-1 done BLOCK)"
  art j1 "$REPORT"
}
tick() { ( cd "$T" && bash "$H/bin/lead-review-land.sh" ) > "$T/out" 2>&1; RC=$?; }
rposts()  { grep -c "^POST repos/$SLUG/pulls/${1:-7}/reviews " "$T/log/gh" 2>/dev/null; }
rposts_ev() { grep -c "^POST repos/$SLUG/pulls/${1:-7}/reviews event=$2 " "$T/log/gh" 2>/dev/null; }
stamps() { grep -c "^POST /api/lead-reviews/${1:-lr-1}/promoted " "$T/log/worker" 2>/dev/null; }
beats()  { grep -c -- '--id lead-spotcheck-' "$T/log/alerts" 2>/dev/null; }
lastbody() { local f; f=$(ls -1 "$T/log" 2>/dev/null | grep '^body-7-' | sort -t- -k3 -n | tail -1); [ -n "$f" ] && cat "$T/log/$f"; }
LOGF() { cat "$H/logs/lead-review-land.log" 2>/dev/null; }

# ── L1: a done BLOCK -> one REQUEST_CHANGES review on the head, before the stamp ──
reset; tick
[ "$RC" = 0 ] && ok || bad "L1 rc=$RC out=$(cat "$T/out")"
[ "$(rposts)" = 1 ] && ok || bad "L1 want exactly one reviews POST, got $(rposts): $(cat "$T/log/gh" 2>/dev/null)"
[ "$(rposts_ev 7 REQUEST_CHANGES)" = 1 ] && grep -q "^POST repos/$SLUG/pulls/7/reviews event=REQUEST_CHANGES commit_id=$SHA\$" "$T/log/gh" \
  && ok || bad "L1 the POST is not REQUEST_CHANGES bound to $SHA: $(grep reviews "$T/log/gh")"
B=$(lastbody)
[ "$(head -1 <<<"$B")" = '<!-- lead-review:lr-1 -->' ] && ok || bad "L1 line 1 is not the marker: $(head -2 <<<"$B")"
grep -qF "Lead review (automated lead-review lane, stub-model) of ${SHA:0:12}" <<<"$B" && ok || bad "L1 no framing line: $B"
grep -qF 'finding X' <<<"$B" && ok || bad "L1 the report body is not in the review: $B"
grep -qF 'Report truncated here' <<<"$B" && bad "L1 an untruncated report got the truncated line" || ok
order=$(awk '/^gh POST .*\/reviews$/{print "review"} /^worker POST \/api\/lead-reviews\/lr-1\/promoted$/{print "stamp"} /^worker POST \/api\/verdicts$/{print "row"}' "$T/log/seq" | paste -sd' ')
[ "$order" = "row review stamp" ] && ok || bad "L1 order '$order' (want row review stamp)"
[ -e "$H/state/lead-review-land/findings-lr-1" ] && ok || bad "L1 no findings flag"
: > "$T/log/gh"; tick
[ "$(rposts)" = 0 ] && ok || bad "L1 a second tick posted again ($(rposts))"
cp "$T/reviews-7.json" "$T/l1-reviews.json"
# ...and with the flag gone, the marker on GitHub is still the dedupe.
rm -f "$H/state/lead-review-land/findings-lr-1"; : > "$T/log/gh"; tick
[ "$(rposts)" = 0 ] && ok || bad "L1 the marker on GitHub did not stop a second POST ($(rposts))"

# ── L1b: a truncated artifact -> the pointer to the whole report ──
reset; art j1 "$REPORT" truncated; tick
grep -qF 'Report truncated here; the full report is on box box-demo at state/lead-reviews/report.md' <<<"$(lastbody)" \
  && ok || bad "L1b no truncated line: $(lastbody)"

# ── L1c: no artifact (rc 3), no job id, another head's report -> the report_ref line ──
for c in noart nojob foreign; do
  reset
  case "$c" in
    noart) rm -f "$T/artifacts-j1.json" ;;
    nojob) setreqs "$(req lr-1 done BLOCK 7 "$SHA" "")" ;;
    foreign) art j1 "# Lead review lr-7-${SHA2:0:12} ($SLUG#7 at $SHA2)
- finding FOREIGN
VERDICT: BLOCK" ;;
  esac
  tick
  B=$(lastbody)
  grep -qF "Full report: state/lead-reviews/lr-7-${SHA:0:12}.md on box box-demo" <<<"$B" && ok || bad "L1c/$c no report_ref line: $B"
  grep -qF 'finding' <<<"$B" && bad "L1c/$c carried findings it should not: $B" || ok
  [ "$(rposts_ev 7 REQUEST_CHANGES)" = 1 ] && [ "$(stamps)" = 1 ] && ok || bad "L1c/$c posts=$(rposts) stamps=$(stamps)"
done
# ...but an UNREADABLE worker is not "no artifact": nothing posted, nothing stamped.
reset; : > "$T/art500"; tick
[ "$(rposts)" = 0 ] && [ "$(stamps)" = 0 ] && ok || bad "L1c art500 posted/stamped (posts=$(rposts) stamps=$(stamps))"
[ -e "$H/state/lead-review-land/findings-lr-1" ] && bad "L1c art500 wrote the flag" || ok

# ── L2: the reviews POST answers 500 -> row recorded, no flag, no stamp; then heals ──
reset; echo 500 > "$T/review-status"; tick
[ "$(grep -c '^POST /api/verdicts ' "$T/log/worker")" = 1 ] && ok || bad "L2 the verdict row was not recorded first"
[ "$(stamps)" = 0 ] && ok || bad "L2 stamped after a failed findings POST"
[ -e "$H/state/lead-review-land/findings-lr-1" ] && bad "L2 flag written after a failed POST" || ok
LOGF | grep -q 'lead review lr-1: findings review NOT posted (HTTP 500' && ok || bad "L2 the failure is not logged: $(LOGF | tail -2)"
rm -f "$T/review-status"; : > "$T/log/worker"; tick
[ "$(jq length "$T/reviews-7.json")" = 1 ] && ok || bad "L2 want one review on GitHub, got $(jq length "$T/reviews-7.json" 2>/dev/null)"
[ "$(stamps)" = 1 ] && ok || bad "L2 tick 2 did not stamp once ($(stamps))"
[ "$(grep -c '^POST /api/verdicts ' "$T/log/worker")" = 0 ] && ok || bad "L2 tick 2 posted a second verdict row"

# ── L2b: the reviews READ fails -> no POST, no stamp ──
reset; : > "$T/revget500"; tick
[ "$(rposts)" = 0 ] && [ "$(stamps)" = 0 ] && ok || bad "L2b posted/stamped blind (posts=$(rposts) stamps=$(stamps))"
# ...and a 10th full page is not a complete read either.
reset
jq -nc '[range(100) | {id:., user:{login:"x",type:"User"}, author_association:"NONE", commit_id:"c", state:"COMMENTED", body:"x"}]' > "$T/reviews-7.json"
: > "$T/fullpages"; tick
[ "$(rposts)" = 0 ] && [ "$(stamps)" = 0 ] && ok || bad "L2b 10 full pages must defer (posts=$(rposts) stamps=$(stamps))"
[ "$(grep -c "^GET repos/$SLUG/pulls/7/reviews" "$T/log/gh")" = 10 ] && ok || bad "L2b want 10 page reads, got $(grep -c "^GET repos/$SLUG/pulls/7/reviews" "$T/log/gh")"

# ── L3: the marker is already on GitHub (any author) and no flag -> flag, no POST, stamp ──
reset
jq -nc --arg c "$SHA" '[{id:1, user:{login:"someone",type:"User"}, author_association:"NONE", commit_id:$c, state:"COMMENTED", body:"<!-- lead-review:lr-1 -->\nold"}]' > "$T/reviews-7.json"
tick
[ "$(rposts)" = 0 ] && ok || bad "L3 posted over an existing marker"
[ -e "$H/state/lead-review-land/findings-lr-1" ] && ok || bad "L3 flag not written from the marker"
[ "$(stamps)" = 1 ] && ok || bad "L3 not stamped ($(stamps))"
# ...a near-miss marker is not it.
reset
jq -nc --arg c "$SHA" '[{id:1, user:{login:"x",type:"User"}, author_association:"NONE", commit_id:$c, state:"COMMENTED", body:"<!-- lead-review:lr-10 -->"}]' > "$T/reviews-7.json"
tick
[ "$(rposts)" = 1 ] && ok || bad "L3 lr-10's marker counted as lr-1's"

# ── L4: REQUEST_CHANGES refused 422 -> one COMMENT, one nobrief warn, stamp ──
reset; : > "$T/review422"; tick
[ "$(rposts_ev 7 REQUEST_CHANGES)" = 1 ] && [ "$(rposts_ev 7 COMMENT)" = 1 ] && ok || bad "L4 want one RC then one COMMENT: $(grep reviews "$T/log/gh")"
grep -q "^POST repos/$SLUG/pulls/7/reviews event=COMMENT commit_id=$SHA\$" "$T/log/gh" && ok || bad "L4 the COMMENT is not bound to the head"
[ "$(grep -c -- '--severity warn --id lead-block-nobrief-lr-1 lead-review-land' "$T/log/alerts" 2>/dev/null)" = 1 ] && ok || bad "L4 want one nobrief warn: $(cat "$T/log/alerts" 2>/dev/null)"
grep -qF "https://github.com/$SLUG/pull/7" "$T/log/alerts" && ok || bad "L4 the warn has no PR link"
[ "$(stamps)" = 1 ] && [ -e "$H/state/lead-review-land/findings-lr-1" ] && ok || bad "L4 not stamped/flagged"
# ...and a COMMENT that fails too is no stamp.
reset; : > "$T/review422"; echo 500 > "$T/review-status"; tick
[ "$(stamps)" = 0 ] && ok || bad "L4 stamped with both POSTs failed"
[ -s "$T/log/alerts" ] && bad "L4 warned with nothing posted" || ok

# ── L5: MERGE / MERGE-WITH-NOTES -> no review ──
reset; setreqs "$(req lr-1 done MERGE)" "$(req lr-2 done MERGE-WITH-NOTES 8)"; tick
[ "$(grep -c '/reviews' "$T/log/gh")" = 0 ] && ok || bad "L5 a MERGE touched reviews: $(cat "$T/log/gh")"
[ "$(stamps lr-1)" = 1 ] && [ "$(stamps lr-2)" = 1 ] && ok || bad "L5 MERGE rows not stamped"

# ── L6: the head moved (post rc 3) -> no review, stamped as today ──
reset; echo "$SHA2" > "$T/head-7"; tick
[ "$(grep -c '/reviews' "$T/log/gh")" = 0 ] && ok || bad "L6 a moved head touched reviews: $(cat "$T/log/gh")"
[ "$(stamps)" = 1 ] && ok || bad "L6 want one stamp, got $(stamps)"

# ── failed row (negative): no review, its ALERTS line unchanged ──
reset; setreqs "$(req lr-1 failed null)"; tick
[ "$(grep -c '/reviews' "$T/log/gh" 2>/dev/null)" = 0 ] && ok || bad "failed row touched reviews"
grep -q 'lead review lr-1 failed' "$H/logs/ALERTS.log" 2>/dev/null && ok || bad "failed row: ALERTS line missing"

# ── L7: the posted review is what the fix round's REAL br_lead_pick briefs ──
BR="$DIR/bin/blocked-resolver.sh"
lift() { awk -v n="$1" '$0 ~ "^"n"\\(\\) \\{" {f=1} f{print} f&&/^}/{exit}' "$BR"; }
{ grep -E '^(BR_REVIEW_FOOTER|BR_LEAD_HDR)=' "$BR"; lift br_lead_pick; } > "$T/pick.sh"
grep -q '^br_lead_pick() {' "$T/pick.sh" && ok || bad "L7 br_lead_pick could not be lifted"
ROWS=$(jq -c '[ .[] | {l:(.user.login // ""), t:(.user.type // ""), a:(.author_association // ""), c:(.commit_id // ""), s:(.state // ""), b:(.body // "")} ]' "$T/l1-reviews.json")
# TEST-CHANGE (BH-5213): the posted review is now the hub App's (cromford[bot]),
# as on GitHub, so the marker review is matched through harness_verdict_author_match
# the way blocked-resolver.sh matches it (it sources bin/lib/gh-pr-list.sh).
OUT=$(bash -c '. "$5" 2>/dev/null; . "$1"; br_lead_pick "$2" "$3" "$4"' _ "$T/pick.sh" "$SLUG" "$SHA" "$ROWS" "$DIR/bin/lib/gh-pr-list.sh"); PRC=$?
[ "$PRC" = 0 ] && ok || bad "L7 br_lead_pick rc=$PRC on the posted review"
DEC=$(printf '%s' "$OUT" | base64 -d 2>/dev/null)
[ "$(head -1 <<<"$DEC")" = 'LEAD FINDINGS — every item must be addressed in code' ] && ok || bad "L7 not framed as a lead brief: $(head -2 <<<"$DEC")"
grep -qF 'finding X' <<<"$DEC" && ok || bad "L7 the brief lacks the finding"

# ── L8: pct=100 -> one beat per MERGE / MERGE-WITH-NOTES, none for BLOCK ──
reset; setreqs "$(req lr-1 done MERGE)" "$(req lr-2 done MERGE-WITH-NOTES 8)" "$(req lr-3 done BLOCK 9)"
LEAD_REVIEW_SPOTCHECK_PCT=100 tick
[ "$(beats)" = 2 ] && ok || bad "L8 want 2 beats, got $(beats): $(cat "$T/log/alerts" 2>/dev/null)"
grep -q -- '--id lead-spotcheck-lr-3 ' "$T/log/alerts" 2>/dev/null && bad "L8 a BLOCK was spot-checked" || ok
grep -q -- "--severity warn --id lead-spotcheck-lr-1 lead-review-land spot-check: $SLUG#7 @${SHA:0:12} lead MERGE by stub-model: https://github.com/$SLUG/pull/7 report " "$T/log/alerts" \
  && ok || bad "L8 the lr-1 beat is not the documented line: $(grep lr-1 "$T/log/alerts")"
grep -qF "https://github.com/$SLUG/pull/8" "$T/log/alerts" && ok || bad "L8 the lr-2 beat has no PR link"
# a stamp-only retry (row already recorded) does not beat again
: > "$T/log/alerts"; setreqs "$(req lr-1 done MERGE)"; LEAD_REVIEW_SPOTCHECK_PCT=100 tick
[ "$(beats)" = 0 ] && ok || bad "L8 a stamp-only retry beat again"
# a bad knob is off, logged, never clamped
for v in 101 abc -5; do
  reset; setreqs "$(req lr-1 done MERGE)"; LEAD_REVIEW_SPOTCHECK_PCT=$v tick
  [ "$(beats)" = 0 ] && ok || bad "L8 pct='$v' beat"
  [ "$(LOGF | grep -c "LEAD_REVIEW_SPOTCHECK_PCT='$v' is not 0..100")" = 1 ] && ok || bad "L8 pct='$v' not logged once"
done

# ── L9: pct=0 -> no beats ──
reset; setreqs "$(req lr-1 done MERGE)"; LEAD_REVIEW_SPOTCHECK_PCT=0 tick
[ "$(beats)" = 0 ] && ok || bad "L9 pct=0 beat $(beats) time(s)"
[ "$(stamps)" = 1 ] && ok || bad "L9 not stamped"
# the bucket is strictly below pct: find a head whose bucket is exactly B, run pct=B -> no beat, pct=B+1 -> beat
HB=$(printf '%s' "$SLUG#7@$SHA" | cksum | awk '{print $1 % 100}')
if [ "$HB" -gt 0 ]; then
  reset; setreqs "$(req lr-1 done MERGE)"; LEAD_REVIEW_SPOTCHECK_PCT=$HB tick
  [ "$(beats)" = 0 ] && ok || bad "L9 bucket $HB fired at pct=$HB (must be strictly below)"
fi
reset; setreqs "$(req lr-1 done MERGE)"; LEAD_REVIEW_SPOTCHECK_PCT=$((HB + 1)) tick
[ "$(beats)" = 1 ] && ok || bad "L9 bucket $HB did not fire at pct=$((HB + 1))"

# ── L10: pct=10 over 200 MERGE rows -> 5..40 beats, the same set on a fresh scratch ──
l10() {
  local i rows=() h
  reset
  for i in $(seq 1 200); do
    h=$(printf '%s' "h$i" | sha1sum | awk '{print $1}')
    printf '%s' "$h" > "$T/head-$i"
    rows+=("$(req "lr-m$i" done MERGE "$i" "$h")")
  done
  setreqs "${rows[@]}"
  LEAD_REVIEW_SPOTCHECK_PCT=10 tick
  grep -o -- '--id lead-spotcheck-[^ ]*' "$T/log/alerts" 2>/dev/null | sort
}
IDS1=$(l10); N1=$(grep -c . <<<"$IDS1")
[ "$N1" -ge 5 ] && [ "$N1" -le 40 ] && ok || bad "L10 want 5..40 beats over 200 rows, got $N1"
OLDH="$H"; T0="$T"; mkdir -p "$T/second"; build "$T/second"; export HARNESS="$H"
IDS2=$(l10)
[ -n "$IDS1" ] && [ "$IDS1" = "$IDS2" ] && ok || bad "L10 the sample differs on a rerun (first $N1, second $(grep -c . <<<"$IDS2"))"
[ "$H" != "$OLDH" ] && [ "$T" = "$T0" ] && ok || bad "L10 the second run was not on a fresh scratch harness"

# ── L11: BLOCK on $SHA, fix pushed, lead MERGE on $SHA2 -> the marker review is dismissed ──
dismissals() { grep -c "^PUT repos/$SLUG/pulls/7/reviews/[0-9]*/dismissals " "$T/log/gh" 2>/dev/null; }
l11_block() {
  reset; tick
  # a person's CHANGES_REQUESTED on the same old head, which the lane must never dismiss
  jq -c --arg c "$SHA" '. + [{id:99, user:{login:"operator",type:"User"}, author_association:"OWNER", commit_id:$c, state:"CHANGES_REQUESTED", body:"please rename this"}]' \
    "$T/reviews-7.json" > "$T/r.tmp" && mv "$T/r.tmp" "$T/reviews-7.json"
  echo "$SHA2" > "$T/head-7"; : > "$T/log/gh"; : > "$T/log/worker"
}
l11_block; setreqs "$(req lr-2 done MERGE 7 "$SHA2")"; tick
[ "$(dismissals)" = 1 ] && grep -q "^PUT repos/$SLUG/pulls/7/reviews/1/dismissals " "$T/log/gh" \
  && ok || bad "L11 want one dismissal of the marker review 1: $(grep PUT "$T/log/gh")"
[ "$(jq -r '.[] | select(.id == 1) | .state' "$T/reviews-7.json")" = DISMISSED ] && ok || bad "L11 the lead review is not dismissed"
[ "$(jq -r '.[] | select(.id == 99) | .state' "$T/reviews-7.json")" = CHANGES_REQUESTED ] && ok || bad "L11 a person's review was dismissed"
[ "$(stamps lr-2)" = 1 ] && [ -e "$H/state/lead-review-land/dismissed-lr-2" ] && ok || bad "L11 not stamped/flagged ($(stamps lr-2))"
order=$(awk '/^gh PUT .*\/dismissals$/{print "dismiss"} /^worker POST \/api\/lead-reviews\/lr-2\/promoted$/{print "stamp"} /^worker POST \/api\/verdicts$/{print "row"}' "$T/log/seq" | tail -3 | paste -sd' ')
[ "$order" = "row dismiss stamp" ] && ok || bad "L11 order '$order' (want row dismiss stamp)"
# a rerun with the flag gone dismisses nothing more (review 1 is DISMISSED now)
rm -f "$H/state/lead-review-land/dismissed-lr-2"; : > "$T/log/gh"; tick
[ "$(dismissals)" = 0 ] && ok || bad "L11 a rerun dismissed again ($(dismissals))"
# ...a failed dismissal is no stamp, and the next tick heals it
l11_block; setreqs "$(req lr-2 done MERGE-WITH-NOTES 7 "$SHA2")"; echo 500 > "$T/dismiss-status"; tick
[ "$(stamps lr-2)" = 0 ] && ok || bad "L11 stamped after a failed dismissal"
[ -e "$H/state/lead-review-land/dismissed-lr-2" ] && bad "L11 flagged after a failed dismissal" || ok
LOGF | grep -q 'dismissing lead review 1 FAILED (HTTP 500' && ok || bad "L11 the failed dismissal is not logged: $(LOGF | tail -2)"
rm -f "$T/dismiss-status"; : > "$T/log/worker"; tick
[ "$(stamps lr-2)" = 1 ] && [ "$(jq -r '.[] | select(.id == 1) | .state' "$T/reviews-7.json")" = DISMISSED ] \
  && ok || bad "L11 the retry did not dismiss and stamp (stamps=$(stamps lr-2))"
# ...an unreadable reviews list is no stamp
l11_block; setreqs "$(req lr-2 done MERGE 7 "$SHA2")"; : > "$T/revget500"; tick
[ "$(dismissals)" = 0 ] && [ "$(stamps lr-2)" = 0 ] && ok || bad "L11 revget500 dismissed/stamped blind"
# ...a MERGE on the SAME head as the BLOCK dismisses nothing
reset; tick; : > "$T/log/gh"; setreqs "$(req lr-2 done MERGE 7 "$SHA")"; tick
[ "$(dismissals)" = 0 ] && [ "$(stamps lr-2)" = 1 ] && ok || bad "L11 a same-head MERGE dismissed ($(dismissals))"
# ...a stamp-only MERGE retry after the PR moved past it dismisses nothing and stamps
l11_block; setreqs "$(req lr-2 done MERGE 7 "$SHA2")"; echo 500 > "$T/dismiss-status"; tick
rm -f "$T/dismiss-status"; printf 'c%.0s' {1..40} > "$T/head-7"; : > "$T/log/gh"; : > "$T/log/worker"; tick
[ "$(dismissals)" = 0 ] && [ "$(stamps lr-2)" = 1 ] && ok || bad "L11 a MERGE on a dead head dismissed ($(dismissals)) or did not stamp ($(stamps lr-2))"

# ── L12: the findings POST failed, then the PR moved: the retry posts nothing, stamps ──
reset; echo 500 > "$T/review-status"; tick
rm -f "$T/review-status"; echo "$SHA2" > "$T/head-7"; : > "$T/log/gh"; : > "$T/log/worker"; tick
[ "$(rposts)" = 0 ] && ok || bad "L12 posted REQUEST_CHANGES on a dead head: $(grep reviews "$T/log/gh")"
[ "$(stamps)" = 1 ] && ok || bad "L12 not stamped ($(stamps))"
[ -e "$H/state/lead-review-land/findings-lr-1" ] && bad "L12 flagged findings that were never posted" || ok
LOGF | grep -q "lead review lr-1: the PR head moved to ${SHA2:0:12}; findings not posted" && ok || bad "L12 not logged: $(LOGF | tail -2)"

echo "lead-review-land-block.bh-3479: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
