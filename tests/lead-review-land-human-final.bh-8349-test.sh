#!/bin/bash
# tests/lead-review-land-human-final.bh-8349-test.sh — BH-8349: a human verdict
# on a head is final for that head. bin/lead-review-land.sh runs WHOLE against
# a scratch harness carrying the real lane, the real bin/lead-verdict.sh,
# bin/jobs-client.sh and their bin/lib closure. Only these are stubbed:
#   * curl — a stateful jobs worker: the lead-reviews list ($T/requests.json),
#            verdict rows ($T/vrows.json), the /promoted stamp, the settings
#            row lead_authority_mode=human (so a la_human_needed call is an
#            alert), and the protected paths (tests/lib/lpp-stub.sh). Its POST
#            /api/verdicts applies the worker's BH-8349 rule: a source=lead row
#            on a head whose newest row of source=human exists gets the note
#            token human-final:#<id> and the answer human_final:{id,verdict};
#   * gh   — pulls/<n> answers $SHA; files []; reviews; statuses (logged);
#   * bin/lane-alert.sh — appends its args to $T/log/alerts.
#   L1  first landing of a BLOCK on a head with a human MERGE: advice, one
#       `is final on this head` log line, no findings review, no human beat
#   L2  this request's row already stored with human-final:#<id> (the stamp
#       was lost): stamp only, no findings review, no human beat
#   L3  a reset result (supersedes lead row #1) on a head with a newer human
#       row #2: nothing posted, one `re-landing skipped` line, stamped
#   L4  a reset result: (a) a newer box row on the head skips; (b) newer rows
#       only on another head post; (c) a human row older than the superseded
#       row posts, and the worker makes the post advice
#   L5  an authority withhold (exit 5, BH-3683) still asks a human
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-review-land-human-final.bh-8349-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lpp-stub.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

SHA=$(printf 'a%.0s' {1..40})
OTHER=$(printf 'e%.0s' {1..40})
SLUG=example-org/demo-os
H="$T/h"; mkdir -p "$H/state" "$H/logs" "$H/catalog" "$T/fakebin" "$T/log" "$T/tmp" "$T/cfg"
for s in bin/lead-review-land.sh bin/lead-verdict.sh bin/jobs-client.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || { echo "closure install of $s failed"; exit 1; }
done
LPPF="$T/lpp.json"; LPPDOWN="$T/lpp-down"
lpp_set "$LPPF" example-org/demo-os
lpp_install "$T/fakebin" "$LPPF" "$LPPDOWN"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"\nexit 0\n' "$T/log/alerts" > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/lane-alert.sh"
echo box-hub > "$H/state/box-name"
printf 'lead-fixture-token\n' > "$T/cfg/token"; chmod 600 "$T/cfg/token"

cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
m=GET; body=""; url=""; prev=""
for a in "$@"; do
  case "$prev" in -X) m="$a" ;; --data-binary) body="$a" ;; esac
  case "$a" in http*) url="$a" ;; esac
  prev="$a"
done
case "$body" in @*) body=$(cat "${body#@}") ;; esac
p="${url#https://jobs.test}"
printf '%s %s %s\n' "$m" "$p" "$body" >> "@T@/log/worker"
[ -f "@T@/vrows.json" ] || echo '[]' > "@T@/vrows.json"
qp() { printf '%s' "${p#*\?}" | tr '&' '\n' | sed -n "s/^$1=//p" | head -1; }
code=200; out='{}'
case "$m $p" in
  *"/api/lead-protected-paths"*) lpp-answer "$m" "$url" "$body"; exit 0 ;;
  "GET /api/settings/lead_authority_mode") out='{"setting":{"key":"lead_authority_mode","value":"human"}}' ;;
  "GET /api/settings/"*) code=404; out='{"error":"no such setting"}' ;;
  "GET /api/lead-reviews"*) out=$(cat "@T@/requests.json") ;;
  "POST /api/lead-reviews/"*/promoted) out='{"request":{"promoted_verdict_at":"2026-10-25T00:00:00Z"}}' ;;
  "GET /api/jobs/"*/artifacts) out='{"artifacts":[]}' ;;
  "POST /api/verdicts")
    n=$(jq 'map(.id) | max // 0' "@T@/vrows.json")
    # The worker's BH-8349 rule, in its exact note format.
    hf=$(jq -c --argjson b "$body" '[.[] | select(.repo == $b.repo and .pr == $b.pr and .head_sha == $b.head_sha and .source == "human")]
      | max_by(.id) | if . == null or $b.source != "lead" then null else {id, verdict} end' "@T@/vrows.json")
    row=$(jq -c --argjson id "$((n + 1))" --argjson hf "$hf" '. + {id:$id, created_at:"2026-10-25T00:00:00Z"}
      | if $hf == null then . else .note = ((if (.note // "") == "" then "" else .note + " " end) + "human-final:#\($hf.id)") end' <<<"$body")
    jq -c --argjson r "$row" '. + [$r]' "@T@/vrows.json" > "@T@/vrows.tmp" && mv "@T@/vrows.tmp" "@T@/vrows.json"
    code=201; out=$(jq -c --argjson hf "$hf" '{verdict:., human_final:$hf}' <<<"$row") ;;
  "GET /api/verdicts?"*)
    out=$(jq -c --arg r "$(qp repo)" --argjson pr "$(qp pr)" --arg h "$(qp head)" '
      [.[] | select(.repo == $r and .pr == $pr)] | sort_by(-.id) as $rows
      | {repo:$r, pr:$pr, head:$h, rows:$rows, truncated:false,
         standing:([$rows[] | select(.head_sha == $h and .source == "human")] + [$rows[] | select(.head_sha == $h and .source == "lead")] | first)}' "@T@/vrows.json") ;;
  *) code=404; out='{"error":"unknown endpoint","worker":"harness-jobs"}' ;;
esac
printf '%s\n%s' "$out" "$code"
EOF

cat > "$T/fakebin/gh" <<'EOF'
#!/bin/bash
m=GET; path=""; prev=""; ev=""; state=""
for a in "$@"; do
  case "$prev" in
    -X) m="$a" ;;
    -f|-F) case "${a%%=*}" in event) ev="${a#*=}" ;; state) state="${a#*=}" ;; esac ;;
  esac
  case "$a" in repos/*) path="$a" ;; esac
  prev="$a"
done
printf '%s %s event=%s state=%s\n' "$m" "$path" "$ev" "$state" >> "@T@/log/gh"
reply() { printf 'HTTP/1.1 %s X\r\n\r\n%s\n' "$1" "$2"; exit 0; }
case "$m $path" in
  "POST repos/"*"/pulls/"*"/reviews") reply 200 '{"id":1}' ;;
  "GET repos/"*"/pulls/"*"/reviews"*) reply 200 '[]' ;;
  "GET repos/"*"/pulls/"*"/files"*) reply 200 '[]' ;;
  "GET repos/"*"/pulls/"*) reply 200 "{\"head\":{\"sha\":\"@SHA@\",\"ref\":\"ticket/bh-1\"}}" ;;
  "POST repos/"*"/statuses/"*) reply 201 '{"id":1}' ;;
esac
reply 404 '{"message":"Not Found"}'
EOF
sed -i "s#@T@#$T#g; s#@SHA@#$SHA#g" "$T/fakebin/curl" "$T/fakebin/gh"
chmod +x "$T/fakebin/curl" "$T/fakebin/gh"

export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=fixture-secret JOBS_URL=https://jobs.test \
  JOBS_RETRIES=0 TMPDIR="$T/tmp" LANE_GATE_DISABLE=1 LEAD_VERDICT_TOKEN_FILE="$T/cfg/token" GH_ETAG=0 GH_APP_TOKENS=0
unset BOX_NAME JOBS_BOX LEAD_REVIEW_OVERDUE_MIN HUB_BOX_NAME LEAD_REVIEW_SPOTCHECK_PCT GH_TOKEN

# req <id> <verdict> <job> [reset_count] -> one done request object on PR 7 @ $SHA
req() {
  jq -nc --arg i "$1" --arg v "$2" --arg j "$3" --argjson rc "${4:-0}" \
    '{id:$i, repo:"example-org/demo-os", pr:7, head_sha:"'"$SHA"'", status:"done", verdict:$v,
      reviewer_model:"stub-model", report_ref:"state/lead-reviews/lr-7.md", promoted_verdict_at:null,
      job_id:$j, box:"box-fixture", detail:null, reset_count:$rc,
      created_at:"2026-10-25T00:00:00Z", updated_at:"2026-10-25T00:00:00Z"}'
}
setreqs() { printf '%s\n' "$@" | jq -sc '{requests:., truncated:false}' > "$T/requests.json"; }
# vr <id> <source> <verdict> <head> [note] -> one stored verdict row on PR 7
vr() {
  jq -nc --argjson i "$1" --arg s "$2" --arg v "$3" --arg h "$4" --arg n "${5:-}" \
    '{id:$i, repo:"example-org/demo-os", pr:7, head_sha:$h, verdict:$v, source:$s,
      note:(if $n == "" then null else $n end), created_at:"2026-10-25T00:00:00Z"}'
}
setrows() { printf '%s\n' "$@" | jq -sc . > "$T/vrows.json"; }
reset() {
  scratch_rm "$T/log"; rm -f "$T/vrows.json" "$LPPDOWN"; mkdir -p "$T/log"
  : > "$T/log/gh"; : > "$T/log/worker"; : > "$T/log/alerts"
  rm -f "$H/logs/lead-review-land.log"; scratch_rm "$H/state/lead-review-land"; scratch_rm "$H/state/lead-authority"
}
tick() { ( cd "$T" && bash "$H/bin/lead-review-land.sh" ) > "$T/out" 2>&1; RC=$?; }
LOGF()    { cat "$H/logs/lead-review-land.log" 2>/dev/null; }
vposts()  { grep -c '^POST /api/verdicts ' "$T/log/worker"; }
rposts()  { grep -c "^POST repos/$SLUG/pulls/7/reviews " "$T/log/gh"; }
statuses() { grep -c "^POST repos/$SLUG/statuses/" "$T/log/gh"; }
stamps()  { grep -c '^POST /api/lead-reviews/lr-1/promoted ' "$T/log/worker"; }
beats()   { grep -c 'lead-human-needed' "$T/log/alerts"; }
summary() { LOGF | grep -o 'seen=.*' | tail -1; }

# ── L1: first landing of a BLOCK on a head with a human MERGE ──
reset; setrows "$(vr 1 human MERGE "$SHA")"; setreqs "$(req lr-1 BLOCK j1)"; tick
[ "$RC" = 0 ] && ok || bad "L1 rc=$RC $(cat "$T/out")"
[ "$(vposts)" = 1 ] && ok || bad "L1 want one verdict POST (the advice row), got $(vposts)"
jq -r '.[] | select(.id == 2) | .note' "$T/vrows.json" | tr ' ' '\n' | grep -qx 'human-final:#1' \
  && ok || bad "L1 the lead row is not advice: $(cat "$T/vrows.json")"
[ "$(LOGF | grep -c 'is final on this head')" = 1 ] && ok || bad "L1 want one 'is final on this head' line: $(LOGF)"
LOGF | grep -q "lead review lr-1: BLOCK recorded as advice; human verdict #1 is final on this head, status not changed" \
  && ok || bad "L1 the log line must name the human row: $(LOGF)"
[ "$(rposts)" = 0 ] && ok || bad "L1 a human-final head gets no findings review, got $(rposts)"
[ "$(statuses)" = 0 ] && ok || bad "L1 no status is published, got $(statuses)"
[ "$(beats)" = 0 ] && ok || bad "L1 a human already decided: no human-needed beat: $(cat "$T/log/alerts")"
[ "$(stamps)" = 1 ] && ok || bad "L1 want one stamp, got $(stamps)"
[ "$(summary)" = "seen=1 promoted=1 stamped=1 alerted=0 rung=0" ] && ok || bad "L1 summary: $(summary)"

# ── L2: this request's advice row is already stored (stamp lost) ──
reset
setrows "$(vr 1 human MERGE "$SHA")" "$(vr 2 lead BLOCK "$SHA" "lead-review:lr-1 lead-job:j1 report:state/lead-reviews/lr-7.md human-final:#1")"
setreqs "$(req lr-1 BLOCK j1)"; tick
[ "$RC" = 0 ] && ok || bad "L2 rc=$RC $(cat "$T/out")"
[ "$(vposts)" = 0 ] && [ "$(rposts)" = 0 ] && [ "$(statuses)" = 0 ] && ok \
  || bad "L2 stamp only: rows=$(vposts) reviews=$(rposts) statuses=$(statuses)"
[ "$(beats)" = 0 ] && ok || bad "L2 no human-needed beat: $(cat "$T/log/alerts")"
[ "$(stamps)" = 1 ] && ok || bad "L2 want one stamp, got $(stamps)"
[ "$(summary)" = "seen=1 promoted=0 stamped=1 alerted=0 rung=0" ] && ok || bad "L2 summary: $(summary)"

# ── L3: a reset result over a newer human row: nothing posted ──
reset
setrows "$(vr 1 lead BLOCK "$SHA" "lead-review:lr-1 lead-job:j1")" "$(vr 2 human MERGE "$SHA")"
setreqs "$(req lr-1 BLOCK j2 1)"; tick
[ "$RC" = 0 ] && ok || bad "L3 rc=$RC $(cat "$T/out")"
[ "$(vposts)" = 0 ] && ok || bad "L3 a re-landing over a newer row posts nothing, got $(vposts): $(LOGF)"
[ "$(LOGF | grep -c 're-landing skipped: row #2 on this head is newer than lead row #1; nothing posted')" = 1 ] \
  && ok || bad "L3 want one re-landing skipped line: $(LOGF)"
grep -q 're-landing: newer result' <<<"$(LOGF)" && bad "L3 must not log the re-landing it skipped: $(LOGF)" || ok
[ "$(rposts)" = 0 ] && [ "$(statuses)" = 0 ] && [ "$(beats)" = 0 ] && ok \
  || bad "L3 reviews=$(rposts) statuses=$(statuses) beats=$(beats)"
[ "$(stamps)" = 1 ] && ok || bad "L3 want one stamp, got $(stamps)"
[ "$(summary)" = "seen=1 promoted=0 stamped=1 alerted=0 rung=0" ] && ok || bad "L3 summary: $(summary)"

# ── L4a: a newer box row on the head also stops the re-landing ──
reset
setrows "$(vr 1 lead BLOCK "$SHA" "lead-review:lr-1 lead-job:j1")" "$(vr 2 box MERGE "$SHA")"
setreqs "$(req lr-1 MERGE j2 1)"; tick
[ "$(vposts)" = 0 ] && LOGF | grep -q 're-landing skipped: row #2 on this head is newer than lead row #1' \
  && ok || bad "L4a a newer box row skips the re-landing: rows=$(vposts) $(LOGF)"

# ── L4b: newer rows only on another head: the re-landing posts ──
reset
setrows "$(vr 1 lead BLOCK "$SHA" "lead-review:lr-1 lead-job:j1")" "$(vr 2 human MERGE "$OTHER")" "$(vr 3 box MERGE "$OTHER")"
setreqs "$(req lr-1 MERGE j2 1)"; tick
[ "$(vposts)" = 1 ] && ok || bad "L4b a row on another head does not stop the re-landing: rows=$(vposts) $(LOGF)"
jq -r '.[] | select(.id == 4) | .note' "$T/vrows.json" | tr ' ' '\n' | grep -qx 'supersedes:1' \
  && ok || bad "L4b the re-landed row supersedes #1: $(cat "$T/vrows.json")"
grep -q 're-landing skipped' <<<"$(LOGF)" && bad "L4b skipped: $(LOGF)" || ok
[ "$(statuses)" = 1 ] && ok || bad "L4b the re-landed MERGE publishes its status, got $(statuses)"

# ── L4c: a human row OLDER than the superseded row: posts, as advice ──
reset
setrows "$(vr 1 human MERGE "$SHA")" "$(vr 2 lead BLOCK "$SHA" "lead-review:lr-1 lead-job:j1 human-final:#1")"
setreqs "$(req lr-1 BLOCK j2 1)"; tick
[ "$(vposts)" = 1 ] && ok || bad "L4c an older human row does not stop the re-landing: rows=$(vposts) $(LOGF)"
jq -r '.[] | select(.id == 3) | .note' "$T/vrows.json" | tr ' ' '\n' | grep -qx 'human-final:#1' \
  && ok || bad "L4c the re-landed row is advice: $(cat "$T/vrows.json")"
[ "$(rposts)" = 0 ] && [ "$(statuses)" = 0 ] && [ "$(beats)" = 0 ] && ok \
  || bad "L4c reviews=$(rposts) statuses=$(statuses) beats=$(beats)"

# ── L5: an authority withhold (BH-3683) still asks a human ──
reset; : > "$LPPDOWN"   # the protected paths cannot be read: la_decide withholds
setreqs "$(req lr-1 MERGE j1)"; tick
[ "$(vposts)" = 1 ] && ok || bad "L5 the advice row is posted, got $(vposts)"
LOGF | grep -q 'lead-verdict status withheld' && ok || bad "L5 the authority withhold is logged: $(LOGF)"
grep -q 'is final on this head' <<<"$(LOGF)" && bad "L5 an authority withhold is not a human-final one: $(LOGF)" || ok
[ "$(beats)" = 1 ] && ok || bad "L5 an authority withhold still asks a human, beats=$(beats): $(cat "$T/log/alerts") $(LOGF)"
[ "$(statuses)" = 0 ] && ok || bad "L5 no status, got $(statuses)"

echo "lead-review-land-human-final.bh-8349: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
