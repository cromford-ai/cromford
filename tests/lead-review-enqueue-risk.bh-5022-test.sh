#!/bin/bash
# tests/lead-review-enqueue-risk.bh-5022-test.sh — BH-5022 (BH-4973.1): the
# risk tier inside the hub trigger lane. "$DIR/bin/lead-review-enqueue.sh" runs
# WHOLE (`tick`) against a scratch harness carrying its real bin closure, the
# real "$DIR/bin/lib/risk-tier.sh" included. Stubbed:
#   * curl — a STATEFUL jobs worker, the tests/lead-review-enqueue.bh-3545-test.sh
#            one plus GET /api/settings/risk_tier.mode.example-org.cromford from
#            $T/mode (absent = 404 = no row), any other settings key from
#            $T/set/<key> (absent = 404)
#            and POST /api/risk-tiers (recorded, 201).
#   * gh   — the PR list, the head read, the compare ($T/cmp/<head>.json: its
#            files[] and commits[]; a 500 on $T/cmp500) and POST statuses (201).
#   * bin/lead-verdict.sh — records its argv, exits $T/lvrc (default 0).
#   * bin/lane-alert.sh and bin/agent-call.sh — record their argv.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-review-enqueue-risk.bh-5022-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lpp-stub.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"; mkdir -p "$H/state" "$H/logs" "$T/fakebin" "$T/log" "$T/tmp" "$T/cfg" "$T/repos"
scratch_install_closure bin/jobs-client.sh "$H" >/dev/null || exit 1
scratch_install_closure bin/lead-review-enqueue.sh "$H" >/dev/null || exit 1
[ -f "$H/bin/lib/risk-tier.sh" ] || echo "note: bin/lib/risk-tier.sh is not in the lane's closure"
# TEST-CHANGE BH-4148 (merge of main): globs come from the DB, not the TSV.
# The protected paths are lead_protected_paths rows the lead-authority lib reads
# from the worker (tests/lib/lpp-stub.sh), seeded with the cromford globs of
# the deleted TSV; unreadable rows make every head "protected paths unreadable" (medium).
LPPF="$T/lpp.json"; DOWNF="$T/lpp-down"
lpp_install "$T/fakebin" "$LPPF" "$DOWNF"
set -f; lpp_set "$LPPF" example-org/cromford $(cat "$DIR/tests/fixtures/lead-protected-paths.bh-4148.txt"); set +f
printf 'lead-test-token\n' > "$T/cfg/token"; chmod 600 "$T/cfg/token"
printf 'cromford example-org/cromford https://demo.test /api 3 box-hub\n' > "$H/fleet.conf"
printf 'demo-os example-org/demo-os https://demo.test /api 3 box-hub\n' >> "$H/fleet.conf"

SHA=$(printf 'a%.0s' {1..40}); SHA12=${SHA:0:12}
H2=$(printf 'b%.0s' {1..40})
S42=$(printf 'd%.0s' {1..40})

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
$(lpp_curl_case m url body)
  "GET /api/settings/risk_tier.mode.example-org.cromford")
    if [ -f "$T/mode" ]; then out=\$(jq -nc --arg v "\$(cat "$T/mode")" '{setting:{key:"risk_tier.mode.example-org.cromford",value:\$v}}')
    else code=404; out='{"error":"no such setting"}'; fi ;;
  "GET /api/settings/"*)
    k="\${p#/api/settings/}"
    if [ -f "$T/set/\$k" ]; then out=\$(jq -nc --arg k "\$k" --arg v "\$(cat "$T/set/\$k")" '{setting:{key:\$k,value:\$v}}')
    else code=404; out='{"error":"no such setting"}'; fi ;;
  "GET /api/verdict?pr="*)
    n="\${p##*%2F}"
    if [ -f "$T/jv/\$n.json" ]; then out=\$(cat "$T/jv/\$n.json"); else code=404; out='{"error":"no job for this pr"}'; fi ;;
  "GET /api/verdicts?"*)
    n=\$(qp pr)
    if [ -f "$T/standing/\$n" ]; then st=\$(cat "$T/standing/\$n"); else st=null; fi
    out=\$(jq -nc --argjson s "\$st" '{standing:\$s, rows:[], truncated:false}') ;;
  "POST /api/risk-tiers") code=201; out='{"ok":true,"id":1}' ;;
  "POST /api/lead-reviews")
    if [ "\$lead" != 1 ]; then code=403; out='{"error":"needs the lead token"}'
    else
      r=\$(jq -r .repo <<<"\$body"); pr=\$(jq -r .pr <<<"\$body"); h=\$(jq -r .head_sha <<<"\$body"); nt=\$(jq -r '.scope_notes // ""' <<<"\$body")
      have=\$(jq -c --arg r "\$r" --argjson p "\$pr" --arg h "\$h" '[.[] | select(.repo == \$r and .pr == \$p and .head_sha == \$h)] | first // empty' "$T/lrrows.json")
      if [ -n "\$have" ]; then
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
  *"-X GET repos/example-org/"*"/pulls?"*)
    printf 'HTTP/2 200\r\n\r\n'; cat "$T/prs.json" ;;
  *"-X GET repos/example-org/"*"/pulls/"*)
    a="\$*"; n="\${a##*/pulls/}"; n="\${n%% *}"
    printf 'HTTP/2 200\r\n\r\n'; jq -nc --arg s "\$(cat "$T/head/\$n")" --arg u "\$(cat "$T/author/\$n" 2>/dev/null || echo "cromford[bot]")" \
      '{head:{sha:\$s},base:{ref:"main"},user:{login:\$u}}' ;;
  *"-X GET repos/example-org/"*"/compare/"*)
    a="\$*"; h="\${a##*...}"; h="\${h%% *}"
    if [ -e "$T/cmp500" ]; then printf 'HTTP/2 500\r\n\r\n{"message":"boom"}\n'
    elif [ -f "$T/cmp/\$h.json" ]; then printf 'HTTP/2 200\r\n\r\n'; cat "$T/cmp/\$h.json"
    else printf 'HTTP/2 200\r\n\r\n{"total_commits":1,"commits":[{"parents":[{"sha":"p"}],"commit":{"message":"feat: x"}}],"files":[{"filename":"bin/lib/thing.sh","additions":10,"deletions":0}]}\n'; fi ;;
  *"-X POST repos/example-org/"*"/statuses/"*)
    printf 'HTTP/2 201\r\n\r\n{"state":"success"}\n' ;;
esac
exit 0
EOF
cat > "$H/bin/lead-verdict.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/log/lv"
exit \$(cat "$T/lvrc" 2>/dev/null || echo 0)
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
chmod +x "$T/fakebin/curl" "$T/fakebin/gh" "$H/bin/lead-verdict.sh" "$H/bin/lane-alert.sh" "$H/bin/agent-call.sh"

export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
  JOBS_RETRIES=0 TMPDIR="$T/tmp" LANE_GATE_DISABLE=1 LEAD_VERDICT_TOKEN_FILE="$T/cfg/token" \
  FLEET_CONF="$H/fleet.conf" GH_ETAG=0 LEAD_REVIEW_AUTO_REPOS=example-org/cromford \
  LEAD_REVIEW_ENQUEUE_MAX_PER_TICK=5 LEAD_REVIEW_MAX_PER_PR_DAY=4 REPOS_ROOT="$T/repos"
unset BOX_NAME JOBS_BOX HUB_BOX_NAME

pr() {
  jq -c --argjson n "$1" --arg h "$2" '[.[] | select(.number != $n)] + [{number:$n, html_url:("https://github.com/example-org/cromford/pull/"+($n|tostring)),
    title:"t", draft:false, state:"open", user:{login:"cromford[bot]",type:"Bot"}, head:{sha:$h,ref:("ticket/bh-"+($n|tostring))}, base:{ref:"main"}}]' \
    "$T/prs.json" > "$T/prs.tmp" && mv "$T/prs.tmp" "$T/prs.json"
  echo "$2" > "$T/head/$1"
}
approve() {
  # TEST-CHANGE (BH-5740): the grace now needs a running build job bound to the
  # head; the real /api/verdict answer carries .job.
  jq -nc --arg s "$2" '{verdict:"APPROVE", tier:"2", provenance:"-", merge_sha:null, job_id:"job-1", reviewed_sha:$s, job:{id:"job-1", kind:"build", status:"running"},
    artifacts:[{artifact_kind:"verdict", detail:({tier:"2", headbound:"n/a", reviewed_sha:$s, settled:true}|tojson)}]}' > "$T/jv/$1.json"
}
# cmpx <head> <files json: [[name, add, del]...]> [commits json: [[parents, msg]...]]
cmpx() {
  jq -nc --argjson f "$2" --argjson c "${3:-[[1,\"feat: x\"]]}" '{total_commits:($c|length),
    commits:[$c[] | {parents:[range(.[0]) | {sha:"p"}], commit:{message:.[1]}}],
    files:[$f[] | {filename:.[0], additions:.[1], deletions:.[2]}]}' > "$T/cmp/$1.json"
}
stand_risk() { jq -nc '{verdict:"MERGE",source:"risk-tier",id:9,created_at:"2026-10-07T00:00:00Z",report_url:null,reviewer:"risk-tier:hub"}' > "$T/standing/$1"; }
reset() {
  rm -f "$T/log"/* "$T"/{cmp500,lrrows.json,mode,lvrc} "$H/logs"/*
  scratch_rm "$H/state"; mkdir -p "$H/state"
  for d in jv standing head cmp set author; do scratch_rm "$T/$d"; mkdir -p "$T/$d"; done
  printf 'operator' > "$T/set/lead_pr_authors"
  echo box-hub > "$H/state/box-name"
  echo '[]' > "$T/prs.json"
}
DOCS='[["docs/a.md",30,12]]'
lowpr() { reset; echo "${1:-enforce}" > "$T/mode"; pr 41 "$SHA"; approve 41 "$SHA"; cmpx "$SHA" "$DOCS"; }
tick() { ( cd "$T" && bash "$H/bin/lead-review-enqueue.sh" tick ) > "$T/out" 2>&1; RC=$?; }
wlog() { cat "$T/log/worker" 2>/dev/null; }
posts() { wlog | grep -c '^POST /api/lead-reviews ' ; }
rposts() { wlog | grep -c '^POST /api/risk-tiers ' ; }
lvn() { [ -f "$T/log/lv" ] && wc -l < "$T/log/lv" | tr -d ' ' || echo 0; }
cmpn() { grep -c "compare/.*\.\.\.$1" "$T/log/gh" 2>/dev/null; }
LOGF="$H/logs/lead-review-enqueue.log"
summ() { grep ' tick repos=' "$LOGF" 2>/dev/null | tail -1; }
has() { summ | grep -qw -- "$1"; }
LRBODY() { wlog | sed -n 's#^POST /api/lead-reviews \(.*\) lead=.$#\1#p' | head -1; }
MARK="$H/state/lead-review-enqueue/risk-pub-example-org_cromford-41-$SHA12"

[ -f "$DIR/bin/lib/risk-tier.sh" ] && ok || bad "bin/lib/risk-tier.sh does not exist"

# ── B1: enforce + docs only -> risk-tier MERGE, no request, no model call ──
lowpr; tick
[ "$RC" -eq 0 ] && ok || bad "B1 rc=$RC out=$(cat "$T/out")"
[ "$(lvn)" = 1 ] && ok || bad "B1 want one lead-verdict.sh call, got $(lvn): $(cat "$T/log/lv" 2>/dev/null)"
LV=$(head -1 "$T/log/lv" 2>/dev/null)
case "$LV" in "post example-org/cromford 41 $SHA MERGE --source risk-tier "*"--note low risk: "*) ok ;; *) bad "B1 lead-verdict argv: $LV" ;; esac
case "$LV" in *"docs, screens or new tests only, 42 lines"*) ok ;; *) bad "B1 the note lacks the reasons: $LV" ;; esac
[ "$(posts)" = 0 ] && ok || bad "B1 a lead review was requested: $(wlog)"
[ "$(rposts)" = 1 ] && ok || bad "B1 want one POST /api/risk-tiers, got $(rposts)"
RB=$(wlog | sed -n 's#^POST /api/risk-tiers \(.*\) lead=.$#\1#p' | head -1)
[ "$(jq -r '[.tier,.mode,.action,.head_sha,(.pr|tostring),(.lines|tostring),(.files|tostring)]|join(" ")' <<<"$RB" 2>/dev/null)" = "low enforce sign-off $SHA 41 42 1" ] && ok || bad "B1 risk-tiers body: $RB"
has risk_signed=1 && has requested=0 && has risk_low=1 && ok || bad "B1 summary: $(summ)"
[ -s "$T/log/agent" ] && bad "B1 agent-call.sh ran" || ok
grep -q "	low	" "$H/state/lead-review-enqueue/risk.tsv" 2>/dev/null && ok || bad "B1 no risk.tsv line"

# ── B5: same head, the risk-tier row now stands -> no second post, no compare read ──
C1=$(cmpn "$SHA"); stand_risk 41; tick
[ "$(lvn)" = 1 ] && ok || bad "B5 a second lead-verdict.sh call: $(cat "$T/log/lv")"
has skipped_verdict=1 && ok || bad "B5 summary: $(summ)"
[ "$(cmpn "$SHA")" = "$C1" ] && ok || bad "B5 the compare was read again ($C1 -> $(cmpn "$SHA"))"

# ── B6: a new head on the same PR is classified again, never reused ──
rm -f "$T/standing/41"; pr 41 "$H2"; approve 41 "$H2"; cmpx "$H2" '[[".mergify.yml",1,1]]'; tick
[ "$(cmpn "$H2")" -ge 1 ] && ok || bad "B6 no compare read for the new head"
[ "$(lvn)" = 1 ] && ok || bad "B6 the new (high) head was signed off: $(cat "$T/log/lv")"
[ "$(posts)" = 1 ] && ok || bad "B6 want one lead request for the new head, got $(posts)"
[ "$(jq -r '.head_sha + " " + (.priority|tostring)' <<<"$(LRBODY)" 2>/dev/null)" = "$H2 1" ] && ok || bad "B6 request body: $(LRBODY)"

# ── B2: enforce + .mergify.yml -> a request flagged to go first ──
reset; echo enforce > "$T/mode"; pr 41 "$SHA"; approve 41 "$SHA"; cmpx "$SHA" '[[".mergify.yml",2,1],["docs/x.md",1,0]]'; tick
[ "$(lvn)" = 0 ] && ok || bad "B2 a high PR was signed off"
[ "$(posts)" = 1 ] && ok || bad "B2 want one request, got $(posts)"
[ "$(jq -r '.priority' <<<"$(LRBODY)" 2>/dev/null)" = 1 ] && ok || bad "B2 request lacks priority 1: $(LRBODY)"
has risk_high=1 && has requested=1 && ok || bad "B2 summary: $(summ)"
# ...and its re-confirm next tick still carries the priority, with no second compare read
C2=$(cmpn "$SHA"); rm -f "$T/log/worker"; tick
[ "$(jq -r '.priority' <<<"$(LRBODY)" 2>/dev/null)" = 1 ] && has existing=1 && ok || bad "B2 tick 2: $(LRBODY) $(summ)"
[ "$(cmpn "$SHA")" = "$C2" ] && ok || bad "B2 tick 2 read the compare again"

# ── B3: a medium diff -> a request with no priority ──
# TEST-CHANGE (BH-5023): under enforce a medium head is first held for the
# in-build lead-grade review (risk_tier.inbuild_grace_s); this case now ends the
# grace by backdating its marker, and asserts the held tick asked for nothing.
reset; echo enforce > "$T/mode"; pr 41 "$SHA"; approve 41 "$SHA"; cmpx "$SHA" '[["bin/lib/thing.sh",40,10]]'; tick
[ "$(posts)" = 0 ] && ok || bad "B3 a medium head was requested inside the in-build grace"
touch -d '-2 hours' "$H/state/lead-review-enqueue/inbuild-wait-example-org_cromford-41-$SHA12"; tick
[ "$(lvn)" = 0 ] && ok || bad "B3 a medium PR was signed off"
[ "$(posts)" = 1 ] && ok || bad "B3 want one request, got $(posts)"
[ "$(jq -r '.priority // 0' <<<"$(LRBODY)" 2>/dev/null)" = 0 ] && ok || bad "B3 a medium request carries priority: $(LRBODY)"
has risk_medium=1 && ok || bad "B3 summary: $(summ)"

# ── B4: shadow + docs only -> nothing posted, one WOULD line, requested as today ──
lowpr shadow; tick; tick
[ "$(lvn)" = 0 ] && ok || bad "B4 shadow called lead-verdict.sh: $(cat "$T/log/lv")"
[ "$(grep -c 'WOULD sign off' "$LOGF")" = 1 ] && ok || bad "B4 want exactly one WOULD line over two ticks: $(grep 'WOULD' "$LOGF")"
[ "$(posts)" -ge 1 ] && [ "$(jq length "$T/lrrows.json")" = 1 ] && ok || bad "B4 the lead review was not requested as today"
grep -q '^POST /api/verdicts' <<<"$(wlog)" && bad "B4 shadow posted a verdict" || ok
grep -q 'statuses/' "$T/log/gh" 2>/dev/null && bad "B4 shadow wrote a status" || ok
has risk_shadow=1 && ok || bad "B4 summary: $(summ)"

# ── B7: post rc 4 -> marker; next tick (risk-tier stands) publishes once, marker gone ──
lowpr; echo 4 > "$T/lvrc"; tick
[ -f "$MARK" ] && ok || bad "B7 no risk-pub marker after rc 4"
[ "$(cat "$MARK" 2>/dev/null)" = "low risk: docs, screens or new tests only, 42 lines" ] && ok || bad "B7 marker content: $(cat "$MARK" 2>/dev/null)"
has risk_signed=1 && has requested=0 && ok || bad "B7 summary: $(summ)"
stand_risk 41; tick
[ "$(grep -c "statuses/$SHA" "$T/log/gh")" = 1 ] && ok || bad "B7 want one statuses POST, got: $(grep statuses "$T/log/gh")"
grep "statuses/$SHA" "$T/log/gh" | grep -q 'description=low risk: docs, screens or new tests only' && grep "statuses/$SHA" "$T/log/gh" | grep -q 'state=success' && ok || bad "B7 status fields: $(grep statuses "$T/log/gh")"
[ -f "$MARK" ] && bad "B7 the marker survived a published status" || ok
tick; [ "$(grep -c "statuses/$SHA" "$T/log/gh")" = 1 ] && ok || bad "B7 published again with no marker"

# ── B8: no mode row -> today's order: the compare is read only after the cap ──
reset; pr 41 "$SHA"; approve 41 "$SHA"; pr 42 "$S42"; approve 42 "$S42"; cmpx "$SHA" "$DOCS"; cmpx "$S42" "$DOCS"
LEAD_REVIEW_ENQUEUE_MAX_PER_TICK=1 tick
[ "$(grep -c 'compare/' "$T/log/gh")" = 1 ] && ok || bad "B8 want one compare read under cap 1, got: $(grep compare "$T/log/gh")"
[ "$(rposts)" = 0 ] && [ "$(lvn)" = 0 ] && ok || bad "B8 mode off still classified: risk posts $(rposts), lv $(lvn)"
has requested=1 && has deferred=1 && ok || bad "B8 summary: $(summ)"
# ...and enforce signs off BOTH low heads in the same tick (the backfill), cap or not
reset; echo enforce > "$T/mode"; pr 41 "$SHA"; approve 41 "$SHA"; pr 42 "$S42"; approve 42 "$S42"; cmpx "$SHA" "$DOCS"; cmpx "$S42" "$DOCS"
LEAD_REVIEW_ENQUEUE_MAX_PER_TICK=1 tick
[ "$(lvn)" = 2 ] && has risk_signed=2 && ok || bad "B8 backfill: lv $(lvn), $(summ)"

# ── B9: a Lead-Lane: commit with a docs-only diff -> skipped_self, never signed ──
lowpr; cmpx "$SHA" "$DOCS" '[[1,"feat: x"],[1,"fix: y\n\nLead-Lane: mac"]]'; tick
[ "$(lvn)" = 0 ] && ok || bad "B9 a lead-lane commit was signed off"
has skipped_self=1 && [ "$(posts)" = 0 ] && ok || bad "B9 summary: $(summ)"
[ "$(grep -c 'compare/' "$T/log/gh")" = 1 ] && ok || bad "B9 the self check read the compare a second time"

# ── B10: the compare read fails -> no sign-off, unreadable, no request ──
lowpr; : > "$T/cmp500"; tick
[ "$(lvn)" = 0 ] && [ "$(posts)" = 0 ] && ok || bad "B10 lv $(lvn) posts $(posts)"
has unreadable=1 && ok || bad "B10 summary: $(summ)"
[ "$(rposts)" = 0 ] && ok || bad "B10 an unread compare was classified"

# ── B11: post rc 5 (authority withheld) -> falls through to a request; rc 3 -> nothing ──
lowpr; echo 5 > "$T/lvrc"; tick
[ "$(posts)" = 1 ] && ok || bad "B11 rc 5 did not fall through to a request: $(summ)"
# ...first in the queue (a withheld sign-off is a protected path or an authority question)
[ "$(jq -r '.priority' <<<"$(LRBODY)" 2>/dev/null)" = 1 ] && ok || bad "B11 the rc 5 request lacks priority 1: $(LRBODY)"
# ...and the withheld result is recorded: nothing stands (rc 5 writes no row),
# but the next tick does NOT post the sign-off again (no second lead-verdict.sh
# call, no GitHub reads); it re-confirms the same request, priority 1, spending nothing
grep -q "	withheld	" "$H/state/lead-review-enqueue/risk.tsv" 2>/dev/null && ok || bad "B11 no withheld line in risk.tsv"
rm -f "$T/log/worker"; C11=$(cmpn "$SHA"); tick
[ "$(lvn)" = 1 ] && [ "$(posts)" = 1 ] && has existing=1 && ok || bad "B11 tick 2 after rc 5: lv $(lvn), posts $(posts), $(summ)"
[ "$(jq -r '.priority' <<<"$(LRBODY)" 2>/dev/null)" = 1 ] && ok || bad "B11 tick 2 re-confirm lost priority 1: $(LRBODY)"
[ "$(cmpn "$SHA")" = "$C11" ] && ok || bad "B11 tick 2 read the compare again"
lowpr; echo 3 > "$T/lvrc"; tick
[ "$(posts)" = 0 ] && grep -q 'head moved' "$LOGF" && ok || bad "B11 rc 3: posts $(posts), $(summ)"

# ── B12: a junk mode row is off for the tick, with one log line ──
lowpr; echo maybe > "$T/mode"; tick
[ "$(lvn)" = 0 ] && [ "$(rposts)" = 0 ] && ok || bad "B12 a junk mode classified"
grep -q "risk_tier.mode.example-org.cromford reads 'maybe'" "$LOGF" && ok || bad "B12 no log line for the junk mode"

# ── B13: a rules row changed after a head was classified -> the cached tier is not reused ──
lowpr shadow; tick
[ "$(rposts)" = 1 ] && grep -q '	low	' "$H/state/lead-review-enqueue/risk.tsv" && ok || bad "B13 first classification: $(rposts) $(cat "$H/state/lead-review-enqueue/risk.tsv")"
tick; [ "$(rposts)" = 1 ] && ok || bad "B13 the same rules reclassified the head: $(rposts)"
printf 'prompts/*' > "$T/set/risk_tier.low_globs"; tick
[ "$(rposts)" = 2 ] && ok || bad "B13 a low_globs row did not reclassify the cached head: $(rposts)"
RB=$(wlog | sed -n 's#^POST /api/risk-tiers \(.*\) lead=.$#\1#p' | tail -1)
[ "$(jq -r .tier <<<"$RB" 2>/dev/null)" = medium ] && ok || bad "B13 the tightened rule did not apply: $RB"
# ...and in enforce, the tightened rule stops a cached low head being signed off
lowpr; echo 4 > "$T/lvrc"; tick; rm -f "$T/lvrc"
[ "$(lvn)" = 1 ] && ok || bad "B13 enforce setup: lv $(lvn)"
printf 'prompts/*' > "$T/set/risk_tier.low_globs"; tick
# TEST-CHANGE (BH-5023): the now-medium head is held for the in-build review
# first; past the grace it is requested, and it is never signed off.
touch -d '-2 hours' "$H/state/lead-review-enqueue/inbuild-wait-example-org_cromford-41-$SHA12"; tick
[ "$(lvn)" = 1 ] && [ "$(posts)" = 1 ] && ok || bad "B13 a cached low head was signed off under tightened rules: lv $(lvn) posts $(posts)"

# ── B14: wave 1 honours risk_tier.mode for cromford only. Another repo
# with an enforce row (its own and the global) is off: nothing is classified or
# signed off, and the lead review is requested as before. ──
lowpr; rm -f "$T/mode"
printf 'enforce' > "$T/set/risk_tier.mode.example-org.demo-os"; printf 'enforce' > "$T/set/risk_tier.mode"
LEAD_REVIEW_AUTO_REPOS=example-org/demo-os tick
[ "$(lvn)" = 0 ] && [ "$(rposts)" = 0 ] && [ "$(posts)" = 1 ] && ok || bad "B14 another repo was risk-tiered: lv $(lvn) rposts $(rposts) posts $(posts) $(summ)"
grep -q "example-org/demo-os risk tier: wave 1 honours risk_tier.mode only for" "$LOGF" && ok || bad "B14 no off line for the other repo"

# ── B15: a lead-authored PR (lead_pr_authors, the row the merge fence reads)
# is never risk-tiered: no sign-off, no risk-tiers row, and the lead review is
# requested as before, so the fence's lead MERGE can still come. ──
lowpr; echo operator > "$T/author/41"; tick
[ "$(lvn)" = 0 ] && [ "$(rposts)" = 0 ] && ok || bad "B15 a lead PR was risk-tiered: lv $(lvn) rposts $(rposts)"
[ "$(posts)" = 1 ] && has requested=1 && has risk_lead=1 && ok || bad "B15 the lead PR was not requested: posts $(posts) $(summ)"
grep -q 'risk tier skipped (lead-authored (operator)' "$LOGF" && ok || bad "B15 no skip line"
# ...the [bot]/app spelling is the same actor
lowpr; echo 'app/operator' > "$T/author/41"; tick
[ "$(lvn)" = 0 ] && [ "$(posts)" = 1 ] && ok || bad "B15 app/ spelling: lv $(lvn) posts $(posts)"
# ...and an unreadable lead row is never low either
lowpr; rm -f "$T/set/lead_pr_authors"; tick
[ "$(lvn)" = 0 ] && [ "$(posts)" = 1 ] && has risk_lead=1 && grep -q 'lead_pr_authors row unreadable' "$LOGF" \
  && ok || bad "B15 unreadable lead row: lv $(lvn) posts $(posts) $(summ)"

# ── B16: a head that never classifies (a Lead-Lane commit) is cached: a later
# tick that defers it at the cap does not read its compare again. ──
reset; echo enforce > "$T/mode"
pr 42 "$S42"; approve 42 "$S42"; pr 41 "$SHA"; approve 41 "$SHA"
cmpx "$SHA" "$DOCS" '[[1,"fix: y\n\nLead-Lane: mac"]]'
# TEST-CHANGE (BH-5023): medium heads 42/43 are past the in-build grace, so
# they are requested and spend the cap that defers 41, as before the grace.
touch -d '-2 hours' "$H/state/lead-review-enqueue/inbuild-wait-example-org_cromford-42-${S42:0:12}"
LEAD_REVIEW_ENQUEUE_MAX_PER_TICK=1 tick
grep -q "	41	$SHA	unclassified	" "$H/state/lead-review-enqueue/risk.tsv" && ok || bad "B16 no unclassified line: $(cat "$H/state/lead-review-enqueue/risk.tsv")"
C16=$(cmpn "$SHA"); pr 43 "$H2"; approve 43 "$H2"; pr 41 "$SHA"
touch -d '-2 hours' "$H/state/lead-review-enqueue/inbuild-wait-example-org_cromford-43-${H2:0:12}"
LEAD_REVIEW_ENQUEUE_MAX_PER_TICK=1 tick
[ "$(cmpn "$SHA")" = "$C16" ] && has deferred=1 && ok || bad "B16 the unclassified head's compare was read again: $C16 -> $(cmpn "$SHA") $(summ)"
[ "$(lvn)" = 0 ] && ok || bad "B16 an unclassified head was signed off"

# ── no model call anywhere, no secret in the log ──
[ -s "$T/log/agent" ] && bad "agent-call.sh ran: $(cat "$T/log/agent")" || ok
grep -q 'test-secret\|lead-test-token' "$LOGF" && bad "a secret reached the log" || ok

echo "lead-review-enqueue-risk.bh-5022: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
