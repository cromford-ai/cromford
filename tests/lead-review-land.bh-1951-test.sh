#!/bin/bash
# tests/lead-review-land.bh-1951-test.sh — BH-1951 (BH-1525.3): the hub
# promotion lane, bin/lead-review-land.sh, run WHOLE against a scratch harness
# carrying the real jobs client, bin/lib/lead-reviews.sh, bin/lib/verdicts.sh,
# bin/lib/hub-box.sh and bin/lead-verdict.sh, with only these stubbed:
#   * curl — a small STATEFUL jobs worker: GET /api/lead-reviews answers
#            $T/requests.json; POST /api/verdicts appends to $T/vrows.json and
#            GET /api/verdicts answers from it (rows id DESC, `standing` = the
#            newest lead/human row on the head, the worker's SQL rule), so the
#            end-to-end case reads back exactly what the lane wrote;
#            GET /api/lead-protected-paths is tests/lib/lpp-stub.sh (no rows:
#            demo-os is not governed);
#   * ssh  — records any call (there must be none).
# Every request is logged to $T/log/worker as "<METHOD> <path> <body> lead=<0|1>".
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-review-land.bh-1951-test.sh
# TEST-CHANGE BH-4140: globs come from the DB, not the TSV
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lpp-stub.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"; mkdir -p "$H/bin/lib/jobs" "$H/state" "$H/logs" "$T/fakebin" "$T/log" "$T/tmp" "$T/cfg"
cp "$DIR/bin/jobs-client.sh" "$DIR/bin/lead-verdict.sh" "$H/bin/"
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
# TEST-CHANGE (BH-3348): lead-verdict.sh post reads the PR head and publishes
# the lead-verdict status through gh-rest / gh-app-auth / verdict-status.
for f in env-path lead-reviews verdicts hub-box lane-gate gh-rest gh-app-auth verdict-status; do cp "$DIR/bin/lib/$f.sh" "$H/bin/lib/"; done
# TEST-CHANGE (BH-3683, BH-4140): the lane requires bin/lib/lead-authority.sh, which
# reads the lead_protected_paths rows from the worker (demo-os has none, so it is
# not governed and nothing else moves).
# scratch-closure-allow: BH-4148 kept main's one-lib copy beside this hand-built harness and only dropped the deleted TSV from the line; the reader is the subject, its jobs read is stubbed
cp "$DIR/bin/lib/lead-authority.sh" "$H/bin/lib/"
LPPF="$T/lpp.json"; DOWNF="$T/lpp-down"
lpp_install "$T/fakebin" "$LPPF" "$DOWNF"
[ -f "$DIR/bin/lead-review-land.sh" ] && cp "$DIR/bin/lead-review-land.sh" "$H/bin/"
printf 'lead-test-token\n' > "$T/cfg/token"; chmod 600 "$T/cfg/token"

SHA=$(printf 'a%.0s' {1..40})
SHA2=$(printf 'b%.0s' {1..40})

cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
m=GET; body=""; url=""; prev=""; hdrs=""
for a in "\$@"; do
  case "\$prev" in
    -X) m="\$a" ;;
    --data-binary) body="\$a" ;;
    -H) case "\$a" in @*) hdrs="\$hdrs\$(cat "\${a#@}")"\$'\n' ;; *) hdrs="\$hdrs\$a"\$'\n' ;; esac ;;
  esac
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
case "\$body" in @*) body=\$(cat "\${body#@}") ;; esac
lead=0; grep -q '^x-lead-verdict-token: lead-test-token' <<<"\$hdrs" && lead=1
p="\${url#https://jobs.test}"
printf '%s %s %s lead=%s\n' "\$m" "\$p" "\$body" "\$lead" >> "$T/log/worker"
[ -f "$T/vrows.json" ] || echo '[]' > "$T/vrows.json"
qp() { printf '%s' "\${p#*\?}" | tr '&' '\n' | sed -n "s/^\$1=//p" | head -1; }
code=200; out='{}'
case "\$m \$p" in
$(lpp_curl_case m url body)
  "GET /api/lead-reviews"*)
    if [ -e "$T/lr404" ]; then code=404; out='{"error":"unknown endpoint","worker":"harness-jobs"}'
    elif [ -e "$T/lr500" ]; then code=500; out='{"error":"boom"}'
    else out=\$(cat "$T/requests.json"); fi ;;
  "POST /api/lead-reviews/"*/reset)
    if [ "\$lead" != 1 ]; then code=403; out='{"error":"needs the lead token"}'
    else out='{"request":{"status":"requested"}}'; fi ;;
  "POST /api/lead-reviews/"*/promoted)
    if [ -e "$T/p500" ]; then code=500; out='{"error":"boom"}'
    elif [ "\$lead" != 1 ]; then code=403; out='{"error":"needs the lead token"}'
    else out='{"request":{"promoted_verdict_at":"2026-09-26T00:00:00Z"}}'; fi ;;
  "POST /api/verdicts")
    if [ -e "$T/v500" ]; then code=500; out='{"error":"boom"}'
    elif [ "\$(jq -r .source <<<"\$body")" != box ] && [ "\$lead" != 1 ]; then code=403; out='{"error":"needs the lead token"}'
    else
      n=\$(jq length "$T/vrows.json")
      row=\$(jq -c --argjson id "\$((n + 1))" '. + {id:\$id, created_at:"2026-09-26T00:00:00Z"}' <<<"\$body")
      jq -c --argjson r "\$row" '. + [\$r]' "$T/vrows.json" > "$T/vrows.tmp" && mv "$T/vrows.tmp" "$T/vrows.json"
      code=201; out=\$(jq -c '{verdict:.}' <<<"\$row")
    fi ;;
  "GET /api/verdicts?"*)
    if [ -e "$T/vget500" ]; then code=500; out='{"error":"boom"}'
    else
      out=\$(jq -c --arg r "\$(qp repo)" --argjson pr "\$(qp pr)" --arg h "\$(qp head)" '
        [.[] | select(.repo == \$r and .pr == \$pr)] | sort_by(-.id) as \$rows
        | {repo:\$r, pr:\$pr, head:(if \$h == "" then null else \$h end),
           standing:([\$rows[] | select(.head_sha == \$h and (.source == "lead" or .source == "human"))] | first),
           rows:\$rows, truncated:false}' "$T/vrows.json")
    fi ;;
  *) code=404; out='{"error":"unknown endpoint","worker":"harness-jobs"}' ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"\nexit 0\n' "$T/log/ssh" > "$T/fakebin/ssh"
# BH-3348: GitHub for post's head check (PR 41 is at $SHA) and the status POST.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
case "\$*" in
  # TEST-CHANGE: BH-3547 — the lane now posts a BLOCK's findings as a PR review
  # before the stamp, so the fixture's GitHub answers the reviews read and post.
  # Above the pulls/41 arm, which would otherwise match the reviews path too.
  *"-X GET repos/"*"/pulls/41/reviews"*) printf 'HTTP/1.1 200 OK\r\n\r\n[]\n' ;;
  *"-X POST repos/"*"/pulls/41/reviews"*) printf 'HTTP/1.1 200 OK\r\n\r\n{"id":1}\n' ;;
  *"-X GET repos/"*"/pulls/41"*) printf 'HTTP/1.1 200 OK\r\n\r\n{"head":{"sha":"$SHA"}}\n' ;;
  *"-X POST repos/"*"/statuses/"*) printf 'HTTP/1.1 201 Created\r\n\r\n{"id":1}\n' ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/curl" "$T/fakebin/ssh" "$T/fakebin/gh"

export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
  JOBS_RETRIES=0 TMPDIR="$T/tmp" LANE_GATE_DISABLE=1 LEAD_VERDICT_TOKEN_FILE="$T/cfg/token"
unset BOX_NAME JOBS_BOX LEAD_REVIEW_OVERDUE_MIN HUB_BOX_NAME

ago() { date -u -d "-$1 minutes" +%Y-%m-%dT%H:%M:%SZ; }
# req <id> <status> <verdict|null> [created_at] [head] [detail] -> one request object
req() {
  jq -nc --arg i "$1" --arg s "$2" --arg v "$3" --arg c "${4:-$(ago 30)}" --arg h "${5:-$SHA}" --arg d "${6:-}" \
    '{id:$i, repo:"example-org/demo-os", pr:41, head_sha:$h, status:$s,
      verdict:(if $v == "null" then null else $v end), reviewer_model:"stub-model",
      report_ref:"state/lead-reviews/lr-41-aaaaaaaaaaaa.md", promoted_verdict_at:null,
      detail:(if $d == "" then null else $d end), created_at:$c, updated_at:$c}'
}
setreqs() { printf '%s\n' "$@" | jq -sc '{requests:., truncated:false}' > "$T/requests.json"; }
reset() {
  rm -f "$T/log"/* "$T"/{lr404,lr500,p500,v500,vget500,vrows.json} "$H/logs/lead-review-land.log" "$H/logs/ALERTS.log"
  scratch_rm "$H/state/lead-review-land"
  echo box-hub > "$H/state/box-name"
  setreqs "$(req lr-1 done BLOCK)"
}
tick() { ( cd "$T" && bash "$H/bin/lead-review-land.sh" ) > "$T/out" 2>&1; RC=$?; }
wlog() { cat "$T/log/worker" 2>/dev/null; }
posts() { wlog | grep -c '^POST /api/verdicts ' ; }
stamps() { wlog | grep -c '^POST /api/lead-reviews/lr-1/promoted ' ; }
alerts() { [ -f "$H/logs/ALERTS.log" ] && grep -c 'lead-review-land' "$H/logs/ALERTS.log" || echo 0; }

[ -f "$DIR/bin/lead-review-land.sh" ] && ok || bad "bin/lead-review-land.sh does not exist"

# ── L1: a done BLOCK request -> one lead row, then one stamp, in that order ──
reset; tick
[ "$RC" -eq 0 ] && ok || bad "L1 rc=$RC out=$(cat "$T/out")"
wlog | grep -q '^GET /api/lead-reviews?status=done,failed,requested,running&promoted=0 ' && ok || bad "L1 the list call is not the one query with promoted=0: $(wlog | grep lead-reviews | head -1)"
[ "$(posts)" = 1 ] && ok || bad "L1 want exactly one POST /api/verdicts, got $(posts): $(wlog)"
ROW=$(wlog | sed -n 's#^POST /api/verdicts \(.*\) lead=\(.\)$#\1#p' | head -1)
[ "$(jq -r .source <<<"$ROW" 2>/dev/null)" = lead ] && ok || bad "L1 the row is not source=lead: $ROW"
[ "$(jq -r .reviewer <<<"$ROW" 2>/dev/null)" = box:box-hub ] && ok || bad "L1 reviewer is not box:<hub>: $ROW"
[ "$(jq -r .reviewer_model <<<"$ROW" 2>/dev/null)" = stub-model ] && ok || bad "L1 reviewer_model not passed through: $ROW"
[ "$(jq -r .verdict <<<"$ROW" 2>/dev/null)" = BLOCK ] && [ "$(jq -r .head_sha <<<"$ROW" 2>/dev/null)" = "$SHA" ] && ok || bad "L1 verdict/head wrong: $ROW"
jq -r .note <<<"$ROW" 2>/dev/null | grep -qE '(^| )lead-review:lr-1( |$)' && ok || bad "L1 note lacks lead-review:lr-1: $ROW"
jq -r .note <<<"$ROW" 2>/dev/null | grep -q 'report:state/lead-reviews/lr-41-aaaaaaaaaaaa.md' && ok || bad "L1 a non-https report_ref must ride in the note: $ROW"
wlog | grep -q '^POST /api/verdicts .* lead=1$' && ok || bad "L1 the row was not sent with the lead token"
[ "$(stamps)" = 1 ] && ok || bad "L1 want one /promoted stamp, got $(stamps)"
order=$(wlog | awk '/^POST \/api\/verdicts /{print "row"} /^POST \/api\/lead-reviews\/lr-1\/promoted /{print "stamp"}' | paste -sd' ')
[ "$order" = "row stamp" ] && ok || bad "L1 order '$order' (want row stamp)"
grep -q 'seen=1 promoted=1 stamped=1 alerted=0' "$H/logs/lead-review-land.log" && ok || bad "L1 summary: $(tail -1 "$H/logs/lead-review-land.log" 2>/dev/null)"
grep -q 'test-secret\|lead-test-token' "$H/logs/lead-review-land.log" && bad "L1 a secret reached the log" || ok

# ── L8 (end to end): the promoted row is what the block gate reads ──
vread() { ( . "$H/bin/jobs-client.sh"; . "$H/bin/lib/verdicts.sh"; "$@" ); }
OUT=$(vread vd_block_line example-org/demo-os 41 https://github.com/example-org/demo-os/pull/41 "$SHA"); VRC=$?
[ "$VRC" = 0 ] && grep -q 'lead-verdict' <<<"$OUT" && ok || bad "L8 vd_block_line on the head must answer rc 0 with the lead BLOCK (rc $VRC: '$OUT')"
vread vd_block_line example-org/demo-os 41 https://github.com/example-org/demo-os/pull/41 "$SHA2" >/dev/null; VRC=$?
[ "$VRC" = 1 ] && ok || bad "L8 the promoted BLOCK must not stand on another head (rc $VRC)"

# ── L2: the stamp fails -> next tick finds the row and only stamps ──
reset; : > "$T/p500"; tick
[ "$(posts)" = 1 ] && [ "$(stamps)" = 1 ] && ok || bad "L2 tick 1: posts=$(posts) stamps=$(stamps)"
grep -q 'promoted stamp failed' "$H/logs/lead-review-land.log" && ok || bad "L2 the failed stamp is not logged"
rm -f "$T/p500" "$T/log/worker"; tick
[ "$(posts)" = 0 ] && ok || bad "L2 tick 2 posted a second row ($(posts)): $(wlog)"
[ "$(stamps)" = 1 ] && ok || bad "L2 tick 2 must stamp once, got $(stamps)"
grep -q 'already recorded; stamping only' "$H/logs/lead-review-land.log" && ok || bad "L2 no 'stamping only' line"

# ── L3: the row POST fails -> no stamp ──
reset; : > "$T/v500"; tick
[ "$RC" -eq 0 ] && ok || bad "L3 rc=$RC"
[ "$(stamps)" = 0 ] && ok || bad "L3 stamped after a failed row post"
grep -q 'verdict row NOT posted' "$H/logs/lead-review-land.log" && ok || bad "L3 the failed post is not logged"
# ...and a failed verdicts READ is not a post either (never post blind)
reset; : > "$T/vget500"; tick
[ "$(posts)" = 0 ] && [ "$(stamps)" = 0 ] && ok || bad "L3 an unreadable verdicts read must post and stamp nothing (posts=$(posts) stamps=$(stamps))"

# ── L4: superseded, done+null, done+APPROVE -> nothing posted ──
reset
setreqs "$(req lr-1 superseded BLOCK)" "$(req lr-2 done null "" "$SHA2")" "$(req lr-3 done APPROVE "" "$SHA2")"
tick
[ "$(posts)" = 0 ] && ok || bad "L4 posted $(posts) row(s) for superseded/null/APPROVE: $(wlog)"
grep -q '/promoted' <<<"$(wlog)" && bad "L4 stamped a request that was never promoted" || ok
grep -q "lr-3 is done with verdict 'APPROVE'" "$H/logs/lead-review-land.log" && ok || bad "L4 the unknown verdict is not logged"

# ── L5: a requested row 3h old -> ONE ALERTS line, deduped; a bigger knob -> none ──
reset; setreqs "$(req lr-5 requested null "$(ago 180)")"; tick
[ "$(alerts)" = 1 ] && ok || bad "L5 want one ALERTS line, got $(alerts): $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
grep -q "example-org/demo-os#41 @${SHA:0:12} lead review lr-5 requested: requested for 18[0-9] min" "$H/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "L5 the line must name repo#pr, head12, id and the reason: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
tick
[ "$(alerts)" = 1 ] && ok || bad "L5 tick 2 alerted again ($(alerts))"
reset; setreqs "$(req lr-5 requested null "$(ago 180)")"
LEAD_REVIEW_OVERDUE_MIN=500 tick
[ "$(alerts)" = 0 ] && ok || bad "L5 LEAD_REVIEW_OVERDUE_MIN=500 must not alert a 180-min request"
reset; setreqs "$(req lr-5 running null "$(ago 30)")"; tick
[ "$(alerts)" = 0 ] && ok || bad "L5 a 30-min running request is not overdue at the 120 default"

# ── L6: a failed row -> one ALERTS line carrying detail ──
reset; setreqs "$(req lr-6 failed null "$(ago 10)" "$SHA" "empty answer twice")"; tick
[ "$(alerts)" = 1 ] && grep -q 'lead review lr-6 failed: empty answer twice' "$H/logs/ALERTS.log" && ok \
  || bad "L6 the failed row's ALERTS line: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
[ "$(posts)" = 0 ] && ok || bad "L6 a failed row posted a verdict"

# ── L6b-L6d (BH-5793): an ENVIRONMENT failure is requeued, never left to a person ──
# The review lane fails a request it could not do (checkout, no clone, a model
# that answered nothing, a rules pack that failed on its own environment) and
# records no verdict. Land sends it back to `requested` (POST /<id>/reset, the
# lead token) until reset_count reaches LEAD_REVIEW_ENV_RETRY_MAX (default 3);
# only then does a person get the ALERTS line.
for d in 'review-failed: env: gh-graphql-reads-lint: FAIL: 3 (x): repo setup failed' checkout no-checkout empty; do
  reset; setreqs "$(req lr-6 failed null "$(ago 10)" "$SHA" "$d")"; tick
  grep -q '^POST /api/lead-reviews/lr-6/reset' <<<"$(wlog)" && ok || bad "L6b '$d' was not requeued: $(wlog | grep lead-reviews)"
  [ "$(alerts)" = 0 ] && ok || bad "L6b '$d' paged a person on its first env failure: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
  [ "$(posts)" = 0 ] && ok || bad "L6b '$d' posted a verdict"
  grep -q "lr-6 .*requeued" "$H/logs/lead-review-land.log" && ok || bad "L6b '$d' requeue not logged"
done
# L6c: at the cap the request stays failed and a person is told
reset; setreqs "$(req lr-6 failed null "$(ago 10)" "$SHA" checkout | jq -c '. + {reset_count:3}')"; tick
grep -q '^POST /api/lead-reviews/lr-6/reset' <<<"$(wlog)" && bad "L6c requeued past the cap" || ok
[ "$(alerts)" = 1 ] && grep -q 'lead review lr-6 failed: checkout' "$H/logs/ALERTS.log" && ok || bad "L6c no ALERTS line at the cap"
# L6d: a failure that is not an environment one is never requeued
reset; setreqs "$(req lr-6 failed null "$(ago 10)" "$SHA" "empty answer twice")"; tick
grep -q '^POST /api/lead-reviews/lr-6/reset' <<<"$(wlog)" && bad "L6d a non-env failure was requeued" || ok

# ── L7: the list route is not deployed -> rc 0, no POSTs, no ALERTS ──
reset; : > "$T/lr404"; tick
[ "$RC" -eq 0 ] && ok || bad "L7 rc=$RC"
grep -q '^POST' <<<"$(wlog)" && bad "L7 posted with the route missing" || ok
[ "$(alerts)" = 0 ] && ok || bad "L7 alerted on a missing route"
grep -q 'not deployed' "$H/logs/lead-review-land.log" && ok || bad "L7 no log line"
reset; : > "$T/lr500"; tick
[ "$RC" -eq 0 ] && ! grep -q '^POST' <<<"$(wlog)" && ok || bad "L7 a 500 list must be rc 0 with no POSTs"

# ── L10: a near-miss existing row is NOT "already recorded" ──
for near in '{"source":"lead","note":"lead-review:lr-1X"}' '{"source":"box","note":"lead-review:lr-1"}' '{"source":"human","note":"lead-review:lr-1"}'; do
  reset
  jq -nc --argjson n "$near" --arg h "$SHA" '[{id:1, repo:"example-org/demo-os", pr:41, head_sha:$h, verdict:"BLOCK", created_at:"x"} + $n]' > "$T/vrows.json"
  tick
  [ "$(posts)" = 1 ] && ok || bad "L10 $near must not count as the lead row: posts=$(posts)"
done
# ...and the exact one does (with a neighbouring token on the note).
reset
jq -nc --arg h "$SHA" '[{id:1, repo:"example-org/demo-os", pr:41, head_sha:$h, verdict:"BLOCK", source:"lead", note:"lead-review:lr-1 report:x", created_at:"x"}]' > "$T/vrows.json"
tick
[ "$(posts)" = 0 ] && [ "$(stamps)" = 1 ] && ok || bad "L10 the exact lead row must mean stamp-only (posts=$(posts) stamps=$(stamps))"
# ...but the same row on ANOTHER head is not it.
reset
jq -nc --arg h "$SHA2" '[{id:1, repo:"example-org/demo-os", pr:41, head_sha:$h, verdict:"BLOCK", source:"lead", note:"lead-review:lr-1", created_at:"x"}]' > "$T/vrows.json"
tick
[ "$(posts)" = 1 ] && ok || bad "L10 a lead row on another head must not count: posts=$(posts)"

# ── the guards: no lead token, not the hub, truncated list ──
reset; LEAD_VERDICT_TOKEN_FILE="$T/cfg/missing" tick
[ "$RC" -eq 0 ] && [ ! -s "$T/log/worker" ] && ok || bad "no token: rc=$RC, calls: $(wlog)"
[ "$(alerts)" = 1 ] && grep -q 'LEAD_VERDICT_TOKEN_FILE' "$H/logs/ALERTS.log" && ok || bad "no token: want one ALERTS line naming LEAD_VERDICT_TOKEN_FILE"
LEAD_VERDICT_TOKEN_FILE="$T/cfg/missing" tick
[ "$(alerts)" = 1 ] && ok || bad "no token: alerted twice in one day"
reset; echo box-demo > "$H/state/box-name"; tick
[ "$RC" -eq 0 ] && [ ! -s "$T/log/worker" ] && ok || bad "off the hub the lane must make no call (rc=$RC): $(wlog)"
grep -q 'hub only' "$H/logs/lead-review-land.log" && ok || bad "off the hub: no log line"
reset; jq -c '.truncated = true' "$T/requests.json" > "$T/r.tmp" && mv "$T/r.tmp" "$T/requests.json"; tick; tick
[ "$(grep -c 'truncated' "$H/logs/ALERTS.log" 2>/dev/null)" = 1 ] && ok || bad "a truncated list must be ONE ALERTS line per day: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"

# ── L9: no SSH, anywhere ──
[ ! -s "$T/log/ssh" ] && ok || bad "L9 ssh was called: $(cat "$T/log/ssh")"
grep -q . <<<"$(grep -nE '(^|[^a-z_])(ssh|scp)( |$)' "$DIR/bin/lead-review-land.sh" | grep -v '^[0-9]*: *#')" && bad "L9 bin/lead-review-land.sh names ssh/scp on a code line" || ok

echo "lead-review-land.bh-1951: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
