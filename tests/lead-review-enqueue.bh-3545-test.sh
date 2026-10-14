#!/bin/bash
# tests/lead-review-enqueue.bh-3545-test.sh — BH-3545 (BH-3479.1): the hub
# trigger lane, bin/lead-review-enqueue.sh, run WHOLE (`tick`) against a
# scratch harness carrying the real jobs client and the real libs it sources:
# "$DIR/bin/lib/lead-reviews.sh", "$DIR/bin/lib/verdicts.sh",
# "$DIR/bin/lib/gh-rest.sh", "$DIR/bin/lib/gh-pr-list.sh",
# "$DIR/bin/lib/gh-budget.sh", "$DIR/bin/lib/hub-box.sh",
# "$DIR/bin/lib/lane-gate.sh" and "$DIR/bin/lib/env-path.sh". Stubbed:
#   * curl — a small STATEFUL jobs worker. GET /api/verdict?pr= answers
#            $T/jv/<n>.json (missing = 404 = job_verdict rc 2); GET
#            /api/verdicts?..standing_only=1 answers `standing` from
#            $T/standing/<n>; POST /api/lead-reviews is keyed on repo+pr+head in
#            $T/lrrows.json: new = 201, same notes = 200 existing:true, other
#            notes = 409; $T/force201 makes it answer 201 regardless.
#   * gh   — the PR list, the single-PR head read ($T/head/<n>, a 500 when
#            $T/head500/<n> exists), the compare ($T/cmp/<head>.json, a 500 on
#            $T/cmp500) and a healthy rate_limit.
#   * bin/lane-alert.sh and bin/agent-call.sh — record their argv.
# Every worker request is logged "<METHOD> <path> <body> lead=<0|1>".
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-review-enqueue.bh-3545-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-6052: the day stamp below is read by the code and again here; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 63 || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/rendered.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"; mkdir -p "$H/bin/lib/jobs" "$H/state" "$H/logs" "$T/fakebin" "$T/log" "$T/tmp" "$T/cfg"
cp "$DIR/bin/jobs-client.sh" "$H/bin/"
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
cp "$DIR/bin/lib/env-path.sh" "$DIR/bin/lib/lane-gate.sh" "$DIR/bin/lib/hub-box.sh" "$H/bin/lib/"
cp "$DIR/bin/lib/lead-reviews.sh" "$DIR/bin/lib/verdicts.sh" "$H/bin/lib/"
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/gh-budget.sh" "$H/bin/lib/"
[ -f "$DIR/bin/lead-review-enqueue.sh" ] && cp "$DIR/bin/lead-review-enqueue.sh" "$H/bin/"
printf 'lead-test-token\n' > "$T/cfg/token"; chmod 600 "$T/cfg/token"
printf 'demo-os example-org/demo-os https://demo.test /api 3 box-hub\n' > "$H/fleet.conf"

SHA=$(printf 'a%.0s' {1..40}); SHA12=${SHA:0:12}
OLD=$(printf 'c%.0s' {1..40})
S42=$(printf 'd%.0s' {1..40}); S43=$(printf 'e%.0s' {1..40})

cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
m=GET; body=""; url=""; prev=""; hdrs=""
for a in "\$@"; do
  case "\$prev" in
    -X) m="\$a" ;;
    --data-binary|-d|--data) body="\$a" ;;
    -H) case "\$a" in @*) hdrs="\$hdrs\$(cat "\${a#@}")"\$'\n' ;; *) hdrs="\$hdrs\$a"\$'\n' ;; esac ;;
  esac
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
case "\$body" in @*) body=\$(cat "\${body#@}") ;; esac
lead=0; grep -q '^x-lead-verdict-token: lead-test-token' <<<"\$hdrs" && lead=1
p="\${url#https://jobs.test}"
printf '%s %s %s lead=%s\n' "\$m" "\$p" "\$body" "\$lead" >> "$T/log/worker"
[ -f "$T/lrrows.json" ] || echo '[]' > "$T/lrrows.json"
qp() { printf '%s' "\${p#*\?}" | tr '&' '\n' | sed -n "s/^\$1=//p" | head -1; }
code=200; out='{}'
case "\$m \$p" in
  "GET /api/verdict?pr="*)
    n="\${p##*%2F}"
    if [ -f "$T/jv/\$n.json" ]; then out=\$(cat "$T/jv/\$n.json"); else code=404; out='{"error":"no job for this pr"}'; fi ;;
  "GET /api/verdicts?"*)
    n=\$(qp pr)
    if [ -f "$T/standing/\$n" ]; then st=\$(cat "$T/standing/\$n"); else st=null; fi
    out=\$(jq -nc --argjson s "\$st" '{standing:\$s, rows:[], truncated:false}') ;;
  "POST /api/lead-reviews")
    if [ "\$lead" != 1 ]; then code=403; out='{"error":"needs the lead token"}'
    else
      r=\$(jq -r .repo <<<"\$body"); pr=\$(jq -r .pr <<<"\$body"); h=\$(jq -r .head_sha <<<"\$body"); nt=\$(jq -r '.scope_notes // ""' <<<"\$body")
      have=\$(jq -c --arg r "\$r" --argjson p "\$pr" --arg h "\$h" '[.[] | select(.repo == \$r and .pr == \$p and .head_sha == \$h)] | first // empty' "$T/lrrows.json")
      if [ -n "\$have" ] && [ ! -e "$T/force201" ]; then
        if [ "\$(jq -r '.scope_notes // ""' <<<"\$have")" = "\$nt" ]; then out=\$(jq -c '{request:., existing:true}' <<<"\$have")
        else code=409; out=\$(jq -c '{error:"a request for this head exists with other notes", request:.}' <<<"\$have"); fi
      else
        n=\$(jq length "$T/lrrows.json")
        row=\$(jq -c --arg id "lr-\$((n + 1))" '. + {id:\$id, status:"requested"}' <<<"\$body")
        jq -c --argjson r "\$row" '. + [\$r]' "$T/lrrows.json" > "$T/lrrows.tmp" && mv "$T/lrrows.tmp" "$T/lrrows.json"
        code=201; out=\$(jq -c '{request:.}' <<<"\$row")
      fi
    fi ;;
  *) code=404; out='{"error":"unknown endpoint","worker":"harness-jobs"}' ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/log/gh"
case "\$*" in
  *"api rate_limit"*)
    echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"-X GET repos/example-org/demo-os/pulls?"*)
    printf 'HTTP/2 200\r\n\r\n'; cat "$T/prs.json" ;;
  *"-X GET repos/example-org/demo-os/pulls/"*)
    a="\$*"; n="\${a##*/pulls/}"; n="\${n%% *}"
    if [ -e "$T/head500/\$n" ]; then printf 'HTTP/2 500\r\n\r\n{"message":"boom"}\n'
    else printf 'HTTP/2 200\r\n\r\n'; jq -nc --arg s "\$(cat "$T/head/\$n")" '{head:{sha:\$s},base:{ref:"main"}}'; fi ;;
  *"-X GET repos/example-org/demo-os/compare/"*)
    a="\$*"; h="\${a##*...}"; h="\${h%% *}"
    if [ -e "$T/cmp500" ]; then printf 'HTTP/2 500\r\n\r\n{"message":"boom"}\n'
    elif [ -f "$T/cmp/\$h.json" ]; then printf 'HTTP/2 200\r\n\r\n'; cat "$T/cmp/\$h.json"
    else printf 'HTTP/2 200\r\n\r\n{"total_commits":1,"commits":[{"parents":[{"sha":"p"}],"commit":{"message":"feat: the thing"}}]}\n'; fi ;;
esac
exit 0
EOF
cat > "$H/bin/lane-alert.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/log/alerts"
exit 0
EOF
cat > "$H/bin/agent-call.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/log/agent"
exit 0
EOF
chmod +x "$T/fakebin/curl" "$T/fakebin/gh" "$H/bin/lane-alert.sh" "$H/bin/agent-call.sh"

export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
  JOBS_RETRIES=0 TMPDIR="$T/tmp" LANE_GATE_DISABLE=1 LEAD_VERDICT_TOKEN_FILE="$T/cfg/token" \
  FLEET_CONF="$H/fleet.conf" GH_ETAG=0 LEAD_REVIEW_AUTO_REPOS=example-org/demo-os \
  LEAD_REVIEW_ENQUEUE_MAX_PER_TICK=5 LEAD_REVIEW_MAX_PER_PR_DAY=4
unset BOX_NAME JOBS_BOX HUB_BOX_NAME

# pr <n> <head> [draft] — an open harness PR on example-org/demo-os at <head>
pr() {
  jq -c --argjson n "$1" --arg h "$2" --argjson d "${3:-false}" '. + [{number:$n, html_url:("https://github.com/example-org/demo-os/pull/"+($n|tostring)),
    title:"t", draft:$d, state:"open", user:{login:"operator",type:"User"}, head:{sha:$h,ref:("ticket/bh-"+($n|tostring))}, base:{ref:"main"}}]' \
    "$T/prs.json" > "$T/prs.tmp" && mv "$T/prs.tmp" "$T/prs.json"
  echo "$2" > "$T/head/$1"
}
# approve <n> <reviewed_sha> [headbound] — the builder's ledger verdict row
approve() {
  jq -nc --arg s "$2" --arg hb "${3:-n/a}" '{verdict:"APPROVE", tier:"2", provenance:"-", merge_sha:null, job_id:"job-1", reviewed_sha:$s,
    artifacts:[{artifact_kind:"verdict", detail:({tier:"2", headbound:$hb, reviewed_sha:$s, settled:true}|tojson)}]}' > "$T/jv/$1.json"
}
# commits <head> <json array of [parents, message]> — the compare answer for that head
commits() {
  jq -nc --argjson c "$2" '{total_commits:($c|length), commits:[$c[] | {parents:[range(.[0]) | {sha:"p"}], commit:{message:.[1]}}]}' > "$T/cmp/$1.json"
}
reset() {
  rm -f "$T/log"/* "$T"/{cmp500,force201,lrrows.json} "$H/logs"/*
  scratch_rm "$H/state"; mkdir -p "$H/state"
  for d in jv standing head head500 cmp; do scratch_rm "$T/$d"; mkdir -p "$T/$d"; done
  echo box-hub > "$H/state/box-name"
  echo '[]' > "$T/prs.json"
}
happy() { reset; pr 41 "$SHA"; approve 41 "$SHA"; }
tick() { ( cd "$T" && bash "$H/bin/lead-review-enqueue.sh" tick ) > "$T/out" 2>&1; RC=$?; }
wlog() { cat "$T/log/worker" 2>/dev/null; }
posts() { wlog | grep -c '^POST /api/lead-reviews ' ; }
summ() { grep ' tick repos=' "$H/logs/lead-review-enqueue.log" 2>/dev/null | tail -1; }
has() { summ | grep -qw -- "$1"; }
alines() { cat "$T/log/alerts" 2>/dev/null; }
acount() { alines | grep -c -- "$1"; }
LEDGER="$H/state/lead-review-enqueue/requested.tsv"
lrows() { jq length "$T/lrrows.json" 2>/dev/null || echo 0; }
lines() { [ -f "$1" ] && wc -l < "$1" | tr -d ' ' || echo 0; }

[ -f "$DIR/bin/lead-review-enqueue.sh" ] && ok || bad "bin/lead-review-enqueue.sh does not exist"

# ── E1: not the hub -> one log line, no worker call, no gh call ──
happy; echo box-demo > "$H/state/box-name"; tick
[ "$RC" -eq 0 ] && ok || bad "E1 rc=$RC out=$(cat "$T/out")"
grep -q 'runs on the hub only' "$H/logs/lead-review-enqueue.log" 2>/dev/null && ok || bad "E1 no 'runs on the hub only' line"
[ -s "$T/log/worker" ] && bad "E1 a worker call off the hub: $(wlog)" || ok
[ -s "$T/log/gh" ] && bad "E1 a gh call off the hub: $(cat "$T/log/gh")" || ok

# ── E2: no lead token -> one alert over two same-day ticks, no POST ──
happy; LEAD_VERDICT_TOKEN_FILE="$T/cfg/missing" tick; LEAD_VERDICT_TOKEN_FILE="$T/cfg/missing" tick
[ "$RC" -eq 0 ] && ok || bad "E2 rc=$RC"
[ "$(acount 'lead-review-enqueue')" = 1 ] && ok || bad "E2 want exactly one alert over two ticks, got: $(alines)"
alines | grep -q 'LEAD_VERDICT_TOKEN_FILE' && ok || bad "E2 the alert does not name LEAD_VERDICT_TOKEN_FILE: $(alines)"
[ "$(posts)" = 0 ] && ok || bad "E2 posted without a token: $(wlog)"

# ── E3: APPROVE on the live head, no verdict -> one request; tick 2 = existing ──
happy; tick
[ "$RC" -eq 0 ] && ok || bad "E3 rc=$RC out=$(cat "$T/out")"
[ "$(posts)" = 1 ] && ok || bad "E3 want one POST /api/lead-reviews, got $(posts): $(wlog)"
BODY=$(wlog | sed -n 's#^POST /api/lead-reviews \(.*\) lead=.$#\1#p' | head -1)
wlog | grep -q '^POST /api/lead-reviews .* lead=1$' && ok || bad "E3 the POST did not carry the lead token"
[ "$(jq -r .head_sha <<<"$BODY" 2>/dev/null)" = "$SHA" ] && [ "$(jq -r .pr <<<"$BODY" 2>/dev/null)" = 41 ] \
  && [ "$(jq -r .repo <<<"$BODY" 2>/dev/null)" = example-org/demo-os ] && ok || bad "E3 body repo/pr/head wrong: $BODY"
case "$(jq -r .scope_notes <<<"$BODY" 2>/dev/null)" in "auto: builder APPROVE on $SHA12"*) ok ;; *) bad "E3 scope_notes: $BODY" ;; esac
case "$(jq -r .requested_by <<<"$BODY" 2>/dev/null)" in lead-review-enqueue:box-hub) ok ;; *) bad "E3 requested_by: $BODY" ;; esac
has requested=1 && ok || bad "E3 summary: $(summ)"
[ "$(lines "$LEDGER")" = 1 ] && ok || bad "E3 requested.tsv has $(lines "$LEDGER") lines"
grep -q 'test-secret\|lead-test-token' "$H/logs/lead-review-enqueue.log" && bad "E3 a secret reached the log" || ok
rm -f "$T/log/worker"; tick
[ "$(posts)" = 1 ] && ok || bad "E3 tick 2 want one re-confirm POST, got $(posts)"
has existing=1 && has requested=0 && ok || bad "E3 tick 2 summary: $(summ)"
[ "$(lrows)" = 1 ] && ok || bad "E3 tick 2 the worker holds $(lrows) rows"
[ "$(lines "$LEDGER")" = 1 ] && ok || bad "E3 tick 2 requested.tsv has $(lines "$LEDGER") lines"
[ "$(acount lead-repeat)" = 0 ] && ok || bad "E3 an existing:true answer paged: $(alines)"

# ── E4: APPROVE bound to an older sha -> no request; reapproved@<head> -> one ──
# TEST-CHANGE (BH-5630): E4's first tick and E7's no-row tick pin the BUILDER GATE, which is
# LEAD_REVIEW_REQUIRE_BUILDER_APPROVE=1 since BH-5630 (the default 0 asks for a
# head with no builder APPROVE once its CI is green: tests/lead-enqueue-no-
# builder-gate.bh-5630-test.sh). They tick with the gate on. No case removed.
reset; pr 41 "$SHA"; approve 41 "$OLD"; LEAD_REVIEW_REQUIRE_BUILDER_APPROVE=1 tick
[ "$(posts)" = 0 ] && ok || bad "E4 posted on a stale approve: $(wlog)"
has skipped_no_approve=1 && ok || bad "E4 summary: $(summ)"
reset; pr 41 "$SHA"; approve 41 "$OLD" "reapproved@$SHA"; tick
[ "$(posts)" = 1 ] && ok || bad "E4 reapproved@<head> want one POST, got $(posts)"
reset; pr 41 "$SHA"; approve 41 "$OLD" "reapproved@$OLD"; tick
[ "$(posts)" = 0 ] && ok || bad "E4 reapproved@<another sha> posted: $(wlog)"
reset; pr 41 "$SHA"; approve 41 "-"; tick
[ "$(posts)" = 0 ] && ok || bad "E4 a '-' reviewed sha is no claim, but it posted"

# ── E5: the live head read fails -> no request, unreadable ──
happy; : > "$T/head500/41"; tick
[ "$(posts)" = 0 ] && ok || bad "E5 posted on an unread head"
has unreadable=1 && ok || bad "E5 summary: $(summ)"

# ── E6: a lead MERGE stands on the head -> no request ──
happy; jq -nc '{verdict:"MERGE",source:"lead",id:7,created_at:"2026-09-29T00:00:00Z",report_url:null,reviewer:"box:x"}' > "$T/standing/41"; tick
[ "$(posts)" = 0 ] && ok || bad "E6 posted over a standing MERGE: $(wlog)"
has skipped_verdict=1 && ok || bad "E6 summary: $(summ)"

# ── E7: no ledger row (job_verdict rc 2) -> no request ──
reset; pr 41 "$SHA"; LEAD_REVIEW_REQUIRE_BUILDER_APPROVE=1 tick
[ "$(posts)" = 0 ] && ok || bad "E7 posted with no builder verdict"
has skipped_no_approve=1 && ok || bad "E7 summary: $(summ)"
# ...and a non-APPROVE verdict is not an approval
reset; pr 41 "$SHA"; approve 41 "$SHA"; jq -c '.verdict = "BLOCK"' "$T/jv/41.json" > "$T/jv/x" && mv "$T/jv/x" "$T/jv/41.json"; tick
[ "$(posts)" = 0 ] && ok || bad "E7 posted on a builder BLOCK"

# ── E8: cap 1, three candidates -> 1 request, 2 deferred; next tick one more ──
happy; pr 42 "$S42"; approve 42 "$S42"; pr 43 "$S43"; approve 43 "$S43"
LEAD_REVIEW_ENQUEUE_MAX_PER_TICK=1 tick
[ "$(posts)" = 1 ] && ok || bad "E8 want one POST under cap 1, got $(posts)"
has deferred=2 && has requested=1 && ok || bad "E8 summary: $(summ)"
LEAD_REVIEW_ENQUEUE_MAX_PER_TICK=1 tick
[ "$(lrows)" = 2 ] && ok || bad "E8 tick 2 want 2 worker rows (deferred, not dropped), got $(lrows)"
has requested=1 && has existing=1 && has deferred=1 && ok || bad "E8 tick 2 summary: $(summ)"
# a draft is never a candidate
reset; pr 41 "$SHA" true; approve 41 "$SHA"; tick
[ "$(posts)" = 0 ] && ok || bad "E8 posted on a draft"

# ── E9: a Lead-Lane: trailer on a non-merge commit -> no request, one warn ──
happy; commits "$SHA" '[[1,"feat: x"],[1,"fix: lead edits\n\nLead-Lane: mac"]]'; tick; tick
[ "$(posts)" = 0 ] && ok || bad "E9 posted on the lead lane's own commit: $(wlog)"
has skipped_self=1 && ok || bad "E9 summary: $(summ)"
[ "$(acount "lead-self-example-org_demo-os-41-$SHA12")" = 1 ] && ok || bad "E9 want one lead-self alert over two ticks: $(alines)"
alines | grep "lead-self-" | grep -q -- '--severity warn' && ok || bad "E9 the alert is not warn: $(alines)"
alines | grep "lead-self-" | grep -qF "bin/lead-verdict.sh request example-org/demo-os 41 $SHA" && ok || bad "E9 the alert lacks the request command: $(alines)"

# ── E10: Lead-Lane: mid-line, or only on a merge commit -> one request ──
happy; commits "$SHA" '[[1,"docs: see Lead-Lane: mac in prose"]]'; tick
[ "$(posts)" = 1 ] && ok || bad "E10a a mid-line mention blocked the request"
happy; commits "$SHA" '[[1,"feat: x"],[2,"Merge main\n\nLead-Lane: mac"]]'; tick
[ "$(posts)" = 1 ] && ok || bad "E10b a merge-commit trailer blocked the request"
# a compare that did not list every commit is unreadable, not clean
happy; jq -nc '{total_commits:300, commits:[{parents:[{sha:"p"}],commit:{message:"x"}}]}' > "$T/cmp/$SHA.json"; tick
[ "$(posts)" = 0 ] && has unreadable=1 && ok || bad "E10c a truncated compare was read as clean: $(summ)"

# ── E11: the compare read fails -> no request, unreadable, no alert ──
happy; : > "$T/cmp500"; tick
[ "$(posts)" = 0 ] && ok || bad "E11 posted on an unread compare"
has unreadable=1 && ok || bad "E11 summary: $(summ)"
[ -s "$T/log/alerts" ] && bad "E11 alerted: $(alines)" || ok

# ── E12: 4 requests in 24h + a new head -> tripped, one warn; a 25h line ignored ──
NOW=$(date +%s); DAYZ=$(date -u +%Y%m%d)
seed() { mkdir -p "${LEDGER%/*}"; : > "$LEDGER"; for a in "$@"; do printf '%s\texample-org/demo-os\t41\t%s\tlr-x\n' "$((NOW - a))" "$(printf '%040d' "$a")" >> "$LEDGER"; done; }
happy; seed 3600 7200 10800 14400 90000; tick; tick
[ "$(posts)" = 0 ] && ok || bad "E12 posted past the per-PR tripwire: $(wlog)"
has tripped=1 && ok || bad "E12 summary: $(summ)"
[ "$(acount "lead-trip-example-org_demo-os-41-$DAYZ")" = 1 ] && ok || bad "E12 want one lead-trip alert over two ticks: $(alines)"
alines | grep "lead-trip-" | grep -q -- '--severity warn' && ok || bad "E12 the trip alert is not warn"
happy; seed 3600 7200 10800 90000; tick
[ "$(posts)" = 1 ] && ok || bad "E12 3 in 24h + a 25h-old line must still request, got $(posts)"

# ── E13: a 201 on a head already recorded -> one critical page, deduped ──
happy; mkdir -p "${LEDGER%/*}"; printf '%s\texample-org/demo-os\t41\t%s\tlr-0\n' "$(($(date +%s) - 60))" "$SHA" > "$LEDGER"; : > "$T/force201"; tick; tick
[ "$(acount "lead-repeat-example-org_demo-os-41-$SHA12")" = 1 ] && ok || bad "E13 want one lead-repeat alert over two ticks: $(alines)"
alines | grep "lead-repeat-" | grep -q -- '--critical' && alines | grep "lead-repeat-" | grep -q -- '--severity critical' && ok || bad "E13 not critical: $(alines)"

# ── E14: the ledger is pruned to 7 days ──
happy; seed 691200 3600; tick
grep -q "^$((NOW - 691200))	" "$LEDGER" && bad "E14 an 8-day-old line survived: $(cat "$LEDGER")" || ok
grep -q "^$((NOW - 3600))	" "$LEDGER" && ok || bad "E14 a 1h-old line was pruned"

# ── E17: empty AUTO_REPOS or an unreadable cap stops the tick; the list failing is unreadable ──
happy; LEAD_REVIEW_AUTO_REPOS="" tick
[ "$(posts)" = 0 ] && grep -q 'LEAD_REVIEW_AUTO_REPOS is empty' "$H/logs/lead-review-enqueue.log" && ok || bad "E17 empty AUTO_REPOS: posts=$(posts) $(tail -1 "$H/logs/lead-review-enqueue.log")"
happy; LEAD_REVIEW_ENQUEUE_MAX_PER_TICK=abc tick
[ "$(posts)" = 0 ] && ok || bad "E17 a garbage cap still posted"
happy; LEAD_REVIEW_MAX_PER_PR_DAY="" tick
[ "$(posts)" = 0 ] && ok || bad "E17 an empty tripwire still posted"
happy; echo '{"message":"nope"}' > "$T/prs.json"; tick
[ "$(posts)" = 0 ] && has unreadable=1 && ok || bad "E17 an unreadable PR list: $(summ)"

# ── E15: no model call anywhere ──
[ -s "$T/log/agent" ] && bad "E15 agent-call.sh ran: $(cat "$T/log/agent")" || ok
[ "$(grep -L agent-call "$DIR/bin/lead-review-enqueue.sh" 2>/dev/null)" = "$DIR/bin/lead-review-enqueue.sh" ] && ok || bad "E15 bin/lead-review-enqueue.sh names agent-call"

# ── E16: the registry and the hub cron render ──
LJ="$DIR/catalog/lanes.d/lead-review-enqueue.json"
K=$(jq -c '[.knobs[] | select(.env=="LEAD_REVIEW_ENQUEUE_MAX_PER_TICK" or .env=="LEAD_REVIEW_MAX_PER_PR_DAY") | [.env,.type,.default,.min,.max,.required]]' "$LJ" 2>/dev/null)
[ "$K" = '[["LEAD_REVIEW_ENQUEUE_MAX_PER_TICK","int",5,1,50,true],["LEAD_REVIEW_MAX_PER_PR_DAY","int",4,1,50,true]]' ] && ok || bad "E16 knobs: '$K'"
[ "$(jq -r '[.scope,.script,.cadence,(.boxes|join(",")),.switch.name,.wired]|join("|")' "$LJ" 2>/dev/null)" = 'hub|bin/lead-review-enqueue.sh|*/15 * * * *|hub|lane-off-lead-review-enqueue|true' ] \
  && ok || bad "E16 lane fields: $(jq -c . "$LJ" 2>/dev/null | head -c 300)"
REG=$(rendered_registry)
[ "$(jq -r '.lanes[] | select(.id=="lead-review-enqueue") | .script' "$REG" 2>/dev/null)" = bin/lead-review-enqueue.sh ] && ok || bad "E16 the rendered registry has no lead-review-enqueue lane"
HUBC=$(rendered_cron hub)
grep -qF '*/15 * * * * /root/harness/bin/hub-lease.sh check && /root/harness/bin/lead-review-enqueue.sh tick' "$HUBC" && ok || bad "E16 the hub cron does not run the lane behind hub-lease"

echo "lead-review-enqueue.bh-3545: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
