#!/bin/bash
# tests/lead-review-land-retry.bh-5773-test.sh — BH-5773: bin/lead-review-land.sh
# retries a lead verdict POST that answered 503 in the SAME tick, after 2 s, 5 s
# and 10 s, re-reading the row before each retry so a 503 that came after the
# INSERT is never written twice. The lane runs WHOLE against a scratch harness
# carrying its real closure, bin/lead-verdict.sh and bin/jobs-client.sh. Stubbed:
#   * curl  — a stateful jobs worker (the bh-1951 shape). POST /api/verdicts
#             answers 503 while $T/v503 holds N > 0 (and decrements it), writing
#             no row unless $T/v503-after-insert exists; $T/v500 answers 500;
#   * gh    — GitHub: every pulls/<n> is at $SHA; reviews and statuses answer;
#   * sleep — appends its argument to $T/log/sleep and returns at once.
#   R1  503 twice, then 201: one row, three posts, stamped, sleeps 2 5
#   R2  a BLOCK after one 503: one row, its findings review posted
#   R3  503 for ever on two requests: the first uses 2 5 10, the second posts once
#   R4  503 after the INSERT: the re-read finds the row, no second post, stamped
#   R5  a 500 is not retried
#   R6  LEAD_REVIEW_LAND_POST_RETRIES=1 and =0
#   R7  LEAD_REVIEW_LAND_POST_RETRIES=x is logged and reads 3
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-review-land-retry.bh-5773-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lpp-stub.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"; mkdir -p "$H/state" "$H/logs" "$H/catalog" "$T/fakebin" "$T/log" "$T/tmp" "$T/cfg"
scratch_install_closure bin/lead-review-land.sh "$H" >/dev/null || { echo "closure install failed (lane)"; exit 1; }
scratch_install_closure bin/lead-verdict.sh "$H" >/dev/null || { echo "closure install failed (lead-verdict)"; exit 1; }
scratch_install_closure bin/jobs-client.sh "$H" >/dev/null || { echo "closure install failed (jobs-client)"; exit 1; }
# TEST-CHANGE BH-4148 (merge of main): the lead protected paths come from the
# lead_protected_paths rows (tests/lib/lpp-stub.sh), not the deleted TSV. The rows
# are the cromford globs the TSV held (the fixture).
LPPF="$T/lpp.json"; LPPDOWN="$T/lpp-down"
set -f; lpp_set "$LPPF" example-org/cromford $(cat "$DIR/tests/fixtures/lead-protected-paths.bh-4148.txt"); set +f
lpp_install "$T/fakebin" "$LPPF" "$LPPDOWN"
printf 'lead-test-token\n' > "$T/cfg/token"; chmod 600 "$T/cfg/token"

SHA=$(printf 'a%.0s' {1..40})
NOW=$(date +%s)
AT=$(date -u -d "@$((NOW - 1800))" +%Y-%m-%dT%H:%M:%SZ)

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
[ -f "@T@/vrows.json" ] || echo '[]' > "@T@/vrows.json"
qp() { printf '%s' "${p#*\?}" | tr '&' '\n' | sed -n "s/^$1=//p" | head -1; }
append() {
  n=$(jq length "@T@/vrows.json")
  row=$(jq -c --argjson id "$((n + 1))" '. + {id:$id, created_at:"2026-10-09T20:00:00Z"}' <<<"$body")
  jq -c --argjson r "$row" '. + [$r]' "@T@/vrows.json" > "@T@/vrows.tmp" && mv "@T@/vrows.tmp" "@T@/vrows.json"
}
code=200; out='{}'
case "$m $p" in
  *"/api/lead-protected-paths"*) lpp-answer "$m" "$url" "$body"; exit 0 ;;
  "GET /api/lead-reviews"*) out=$(cat "@T@/requests.json") ;;
  "POST /api/lead-reviews/"*/promoted) out='{"request":{"promoted_verdict_at":"2026-10-09T20:00:00Z"}}' ;;
  "POST /api/verdicts")
    n503=$(cat "@T@/v503" 2>/dev/null || echo 0)
    if [ -e "@T@/v500" ]; then code=500; out='{"error":"boom"}'
    elif [ "$n503" -gt 0 ]; then
      echo $((n503 - 1)) > "@T@/v503"
      [ -e "@T@/v503-after-insert" ] && append
      code=503; out='{"error":"verdicts unavailable","detail":"D1_ERROR: D1 DB is overloaded. Requests queued for too long."}'
    else
      append; code=201; out=$(jq -c '{verdict:.}' <<<"$row")
    fi ;;
  "GET /api/verdicts?"*)
    out=$(jq -c --arg r "$(qp repo)" --argjson pr "$(qp pr)" --arg h "$(qp head)" '
      [.[] | select(.repo == $r and .pr == $pr)] | sort_by(-.id) as $rows
      | {repo:$r, pr:$pr, head:(if $h == "" then null else $h end),
         standing:([$rows[] | select(.head_sha == $h and (.source == "lead" or .source == "human"))] | first),
         rows:$rows, truncated:false}' "@T@/vrows.json") ;;
  *) code=404; out='{"error":"unknown endpoint","worker":"harness-jobs"}' ;;
esac
printf '%s\n%s' "$out" "$code"
EOF
sed -i "s#@T@#$T#g" "$T/fakebin/curl"
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/log/gh"
case "\$*" in
  *"-X GET repos/"*"/reviews"*) printf 'HTTP/1.1 200 OK\r\n\r\n[]\n' ;;
  *"-X POST repos/"*"/reviews"*) printf 'HTTP/1.1 200 OK\r\n\r\n{"id":1}\n' ;;
  *"-X GET repos/"*"/pulls/"*) printf 'HTTP/1.1 200 OK\r\n\r\n{"head":{"sha":"$SHA"}}\n' ;;
  *"-X POST repos/"*"/statuses/"*) printf 'HTTP/1.1 201 Created\r\n\r\n{"id":1}\n' ;;
esac
exit 0
EOF
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "%s"\nexit 0\n' "$T/log/sleep" > "$T/fakebin/sleep"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"\nexit 0\n' "$T/log/alerts" > "$H/bin/lane-alert.sh"
chmod +x "$T/fakebin/curl" "$T/fakebin/gh" "$T/fakebin/sleep" "$H/bin/lane-alert.sh"

export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
  JOBS_RETRIES=0 TMPDIR="$T/tmp" LANE_GATE_DISABLE=1 LEAD_VERDICT_TOKEN_FILE="$T/cfg/token"
unset BOX_NAME JOBS_BOX LEAD_REVIEW_OVERDUE_MIN HUB_BOX_NAME LEAD_REVIEW_LAND_POST_RETRIES

# req <id> <verdict> [pr] -> one done request object on $SHA
req() {
  jq -nc --arg i "$1" --arg v "$2" --argjson pr "${3:-41}" --arg c "$AT" --arg h "$SHA" \
    '{id:$i, repo:"example-org/demo-os", pr:$pr, head_sha:$h, status:"done", verdict:$v,
      reviewer_model:"stub-model", report_ref:"state/lead-reviews/lr-41-aaaaaaaaaaaa.md",
      promoted_verdict_at:null, detail:null, created_at:$c, updated_at:$c}'
}
setreqs() { printf '%s\n' "$@" | jq -sc '{requests:., truncated:false}' > "$T/requests.json"; }
reset() {
  rm -f "$T/log"/* "$T"/{v500,v503,v503-after-insert,vrows.json} "$H/logs/lead-review-land.log" "$H/logs/ALERTS.log"
  scratch_rm "$H/state/lead-review-land"
  echo box-hub > "$H/state/box-name"
  setreqs "$(req lr-1 MERGE)"
}
tick() { ( cd "$T" && bash "$H/bin/lead-review-land.sh" ) > "$T/out" 2>&1; RC=$?; }
wlog() { cat "$T/log/worker" 2>/dev/null; }
posts() { wlog | grep -c "^POST /api/verdicts ${1:-}"; }
stamps() { wlog | grep -c '^POST /api/lead-reviews/.*/promoted '; }
sleeps() { paste -sd' ' "$T/log/sleep" 2>/dev/null; }
rows() { jq length "$T/vrows.json" 2>/dev/null || echo 0; }
llog() { cat "$H/logs/lead-review-land.log" 2>/dev/null; }
lcount() { llog | grep -c -- "$1"; }

# ── R1: 503 twice, then 201: posted in the same tick, three calls ──
reset; echo 2 > "$T/v503"; tick
[ "$RC" -eq 0 ] && ok || bad "R1 rc=$RC out=$(cat "$T/out")"
[ "$(posts)" = 3 ] && ok || bad "R1 want 3 POST /api/verdicts, got $(posts): $(wlog)"
[ "$(rows)" = 1 ] && ok || bad "R1 want 1 row, got $(rows)"
jq -r '.[0].note' "$T/vrows.json" 2>/dev/null | grep -qE '(^| )lead-review:lr-1( |$)' && ok || bad "R1 the row note lacks lead-review:lr-1: $(cat "$T/vrows.json")"
[ "$(stamps)" = 1 ] && ok || bad "R1 want 1 stamp, got $(stamps)"
[ "$(sleeps)" = "2 5" ] && ok || bad "R1 sleeps '$(sleeps)' (want '2 5')"
[ "$(lcount 'answered 503; retry')" = 2 ] && ok || bad "R1 want 2 retry lines: $(llog)"
[ "$(lcount 'posted as a source=lead row')" = 1 ] && ok || bad "R1 no 'posted' line: $(llog)"
[ "$(lcount 'NOT posted')" = 0 ] && ok || bad "R1 logged NOT posted: $(llog)"

# ── R2: a BLOCK after one 503: the 2b findings review still runs ──
reset; setreqs "$(req lr-1 BLOCK)"; echo 1 > "$T/v503"; tick
[ "$(posts)" = 2 ] && [ "$(rows)" = 1 ] && ok || bad "R2 posts=$(posts) rows=$(rows)"
grep -q -- '-X POST repos/example-org/demo-os/pulls/41/reviews' "$T/log/gh" 2>/dev/null && ok || bad "R2 the findings review was not posted: $(cat "$T/log/gh" 2>/dev/null)"
[ "$(stamps)" = 1 ] && ok || bad "R2 want 1 stamp, got $(stamps)"

# ── R3: 503 for ever, two requests: the first spends the retries, the second posts once ──
reset; setreqs "$(req lr-1 MERGE 41)" "$(req lr-2 MERGE 42)"; echo 99 > "$T/v503"; tick
[ "$RC" -eq 0 ] && ok || bad "R3 rc=$RC"
[ "$(posts '.*"pr":41')" = 4 ] && ok || bad "R3 want 4 posts for lr-1, got $(posts '.*"pr":41'): $(wlog)"
[ "$(posts '.*"pr":42')" = 1 ] && ok || bad "R3 want 1 post for lr-2, got $(posts '.*"pr":42')"
[ "$(sleeps)" = "2 5 10" ] && ok || bad "R3 sleeps '$(sleeps)' (want '2 5 10')"
[ "$(lcount 'NOT posted')" = 2 ] && ok || bad "R3 want 2 NOT posted lines: $(llog)"
[ "$(stamps)" = 0 ] && [ "$(rows)" = 0 ] && ok || bad "R3 stamps=$(stamps) rows=$(rows)"

# ── R4: a 503 after the INSERT: found on re-read, never written twice ──
reset; echo 1 > "$T/v503"; : > "$T/v503-after-insert"; tick
[ "$(posts)" = 1 ] && ok || bad "R4 want 1 post, got $(posts): $(wlog)"
[ "$(rows)" = 1 ] && ok || bad "R4 want exactly 1 row, got $(rows)"
[ "$(stamps)" = 1 ] && ok || bad "R4 want 1 stamp, got $(stamps)"
[ "$(lcount 'recorded by attempt 1 despite its 503')" = 1 ] && ok || bad "R4 no rc-4 arm line: $(llog)"
[ "$(lcount 'NOT posted')" = 0 ] && ok || bad "R4 logged NOT posted: $(llog)"

# ── R5: a 500 is a refusal, not a slow moment: one post, no sleep ──
reset; : > "$T/v500"; tick
[ "$(posts)" = 1 ] && [ -z "$(sleeps)" ] && ok || bad "R5 posts=$(posts) sleeps='$(sleeps)'"
[ "$(lcount 'NOT posted')" = 1 ] && [ "$(stamps)" = 0 ] && ok || bad "R5 want NOT posted and no stamp: $(llog)"

# ── R6: the knob bounds the retries; 0 is off ──
reset; echo 2 > "$T/v503"; LEAD_REVIEW_LAND_POST_RETRIES=1 tick
[ "$(posts)" = 2 ] && [ "$(sleeps)" = 2 ] && ok || bad "R6 =1: posts=$(posts) sleeps='$(sleeps)'"
[ "$(lcount 'NOT posted')" = 1 ] && ok || bad "R6 =1: want NOT posted: $(llog)"
reset; echo 1 > "$T/v503"; LEAD_REVIEW_LAND_POST_RETRIES=0 tick
[ "$(posts)" = 1 ] && [ -z "$(sleeps)" ] && ok || bad "R6 =0: posts=$(posts) sleeps='$(sleeps)'"

# ── R7: a bad knob is logged and reads 3 ──
reset; echo 1 > "$T/v503"; LEAD_REVIEW_LAND_POST_RETRIES=x tick
[ "$(lcount 'is not 0..3; using 3')" = 1 ] && ok || bad "R7 the bad knob is not logged: $(llog)"
[ "$(posts)" = 2 ] && [ "$(rows)" = 1 ] && ok || bad "R7 posts=$(posts) rows=$(rows)"

echo "lead-review-land-retry.bh-5773: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
