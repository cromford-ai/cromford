#!/bin/bash
# tests/lead-review-enqueue-low-small.bh-7041-test.sh — BH-7041: the low-small
# class inside the hub trigger lane (rt_low_small_apply after rt_classify). "$DIR/bin/lead-review-enqueue.sh" runs
# WHOLE (`tick`) against a scratch harness carrying its real bin closure, the
# real "$DIR/bin/lib/risk-tier.sh" included. The scaffolding is the one of
# tests/lead-review-enqueue-risk.bh-5022-test.sh: a stateful jobs worker
# (curl), gh (the PR list, the head, the compare from $T/cmp/<head>.json, the
# .mergify.yml and a green CI check run), and a stub bin/lead-verdict.sh that
# records its argv and exits $T/lvrc (default 0). risk_tier.mode for the repo
# is enforce in every case, as on the hub; the in-build grace row is 0 so a
# medium head is requested on its first tick.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-review-enqueue-low-small.bh-7041-test.sh
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
scratch_install_closure bin/lead-review.sh "$H" >/dev/null || exit 1
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

printf 'queue_rules:\n  - name: default\n    queue_conditions:\n      - check-success = "CI"\n' | base64 | tr -d '\n' > "$T/mergify.b64"

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
  *"-X GET repos/example-org/"*"/contents/.mergify.yml"*)
    printf 'HTTP/2 200\r\n\r\n'; jq -nc --arg c "\$(cat "$T/mergify.b64")" '{content:\$c, encoding:"base64"}' ;;
  *"-X GET repos/example-org/"*"/commits/"*"/check-runs"*)
    a="\$*"; h="\${a##*/commits/}"; h="\${h%%/*}"
    printf 'HTTP/2 200\r\n\r\n'
    jq -nc --arg h "\$h" '{total_count:1, check_runs:[{name:"CI", head_sha:\$h, status:"completed", conclusion:"success", app:{slug:"github-actions"}}]}' ;;
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

# cmpo <head> <json array of {f, a, d, s?, p?}> — a compare answer with GitHub's field names
cmpo() {
  jq -nc --argjson f "$2" '{total_commits:1, commits:[{parents:[{sha:"p"}], commit:{message:"feat: x"}}],
    files:[$f[] | {filename:.f, additions:.a, deletions:.d, status:(.s // "modified")} + (if has("p") then {patch:.p} else {} end)]}' > "$T/cmp/$1.json"
}
# lspr [low_small_mode] — PR 41 at $SHA, approved, a 180-code-line + 200-line-plan head
SMALL='[{"f":"bin/foo.sh","a":150,"d":30},{"f":".harness/specs/BH-1/plan.md","a":200,"d":0,"s":"added"}]'
lspr() {
  reset; echo enforce > "$T/mode"; printf '0' > "$T/set/risk_tier.inbuild_grace_s"
  [ -n "${1:-}" ] && printf '%s' "$1" > "$T/set/risk_tier.low_small_mode"
  pr 41 "$SHA"; approve 41 "$SHA"; cmpo "$SHA" "$SMALL"
}
RISKF="$H/state/lead-review-enqueue/risk.tsv"
wouldn() { grep -c 'risk-tier WOULD sign off (low-small:' "$LOGF" 2>/dev/null; }

# ── E1: no low_small row (shadow): one WOULD line, the lead review requested, nothing posted ──
lspr; tick
[ "$RC" -eq 0 ] && ok || bad "E1 rc=$RC out=$(cat "$T/out")"
[ "$(wouldn)" = 1 ] && ok || bad "E1 want one low-small WOULD line, got $(wouldn): $(grep -i 'low-small' "$LOGF")"
grep -q "example-org/cromford#41 @$SHA12: risk-tier WOULD sign off (low-small: 180 code lines" "$LOGF" && ok || bad "E1 the WOULD line text: $(grep WOULD "$LOGF")"
[ "$(lvn)" = 0 ] && ok || bad "E1 shadow called lead-verdict.sh: $(cat "$T/log/lv")"
[ "$(posts)" = 1 ] && ok || bad "E1 want one lead request, got $(posts): $(summ)"
has risk_medium=1 && ok || bad "E1 summary: $(summ)"
[ "$(awk -F'\t' '$3 == 41 {print $5}' "$RISKF" | tail -1)" = medium ] && ok || bad "E1 risk.tsv tier: $(cat "$RISKF")"

# ── E2: a second tick: no second WOULD line, no second compare read ──
C2=$(cmpn "$SHA"); tick
[ "$(wouldn)" = 1 ] && ok || bad "E2 a second WOULD line: $(grep WOULD "$LOGF")"
[ "$(cmpn "$SHA")" = "$C2" ] && ok || bad "E2 the compare was read again ($C2 -> $(cmpn "$SHA"))"
[ "$(lvn)" = 0 ] && ok || bad "E2 lead-verdict.sh ran"

# ── E3: enforce: one risk-tier MERGE with the low-small note, no lead request ──
lspr enforce; tick
[ "$(lvn)" = 1 ] && ok || bad "E3 want one lead-verdict.sh call, got $(lvn): $(cat "$T/log/lv" 2>/dev/null) $(summ)"
LV=$(head -1 "$T/log/lv" 2>/dev/null)
case "$LV" in "post example-org/cromford 41 $SHA MERGE --source risk-tier --reviewer risk-tier:"*"--note low risk: low-small: 180 code lines"*) ok ;; *) bad "E3 lead-verdict argv: $LV" ;; esac
[ "$(posts)" = 0 ] && ok || bad "E3 a lead review was requested: $(summ)"
has risk_signed=1 && has risk_low=1 && ok || bad "E3 summary: $(summ)"
[ "$(awk -F'\t' '$3 == 41 {print $5}' "$RISKF" | tail -1)" = low ] && ok || bad "E3 risk.tsv col 5: $(cat "$RISKF")"
case "$(awk -F'\t' '$3 == 41 {print $6}' "$RISKF" | tail -1)" in low-small:*) ok ;; *) bad "E3 risk.tsv col 6: $(cat "$RISKF")" ;; esac
[ "$(awk -F'\t' '$3 == 41 {print $8}' "$RISKF" | tail -1)" = low-small ] && ok || bad "E3 risk.tsv col 8: $(cat "$RISKF")"
RB=$(wlog | sed -n 's#^POST /api/risk-tiers \(.*\) lead=.$#\1#p' | head -1)
[ "$(jq -r '.tier + " " + .action' <<<"$RB" 2>/dev/null)" = "low sign-off" ] && ok || bad "E3 risk-tiers body: $RB"
grep -q 'WOULD sign off (low-small' "$LOGF" && bad "E3 enforce logged a shadow WOULD line" || ok
# ...the next tick reads low + low-small from risk.tsv, with no second compare read
lspr enforce; echo 3 > "$T/lvrc"; tick; rm -f "$T/lvrc"
C3=$(cmpn "$SHA"); tick
[ "$(lvn)" = 2 ] && ok || bad "E3 tick 2 did not sign off from the cache: lv $(lvn) $(summ)"
[ "$(cmpn "$SHA")" = "$C3" ] && ok || bad "E3 tick 2 read the compare again ($C3 -> $(cmpn "$SHA"))"
case "$(tail -1 "$T/log/lv" 2>/dev/null)" in *"--note low risk: low-small: "*) ok ;; *) bad "E3 tick 2 note: $(tail -1 "$T/log/lv")" ;; esac

# ── E4: enforce, but no builder APPROVE on the head (REQFOR): no post, requested ──
lspr enforce; rm -f "$T/jv/41.json"; tick
[ "$(lvn)" = 0 ] && ok || bad "E4 an unapproved low-small head was signed off: $(cat "$T/log/lv")"
[ "$(posts)" = 1 ] && ok || bad "E4 the unapproved head was not requested: posts $(posts) $(summ)"
grep -q 'no reviewer approved this head' "$LOGF" && ok || bad "E4 no REQFOR refusal line: $(grep '#41' "$LOGF" | tail -5)"

# ── E5: enforce, a head that deletes an ok line from an existing test: medium, requested ──
lspr enforce
cmpo "$SHA" '[{"f":"bin/foo.sh","a":20,"d":0},{"f":"tests/a-test.sh","a":0,"d":1,"p":"@@ -1,2 +1,1 @@\n x=1\n-ok \"x\""}]'; tick
[ "$(lvn)" = 0 ] && ok || bad "E5 a test that lost an ok line was signed off: $(cat "$T/log/lv")"
[ "$(posts)" = 1 ] && has risk_medium=1 && ok || bad "E5 not requested as medium: posts $(posts) $(summ)"
grep -q 'WOULD sign off' "$LOGF" && bad "E5 a WOULD line for a weakened test" || ok
grep -q "#41 @$SHA12: low-small no (" "$LOGF" && ok || bad "E5 no low-small no line: $(grep '#41' "$LOGF" | tail -3)"
# ── E6: a high head is untouched by low-small ──
lspr enforce; cmpo "$SHA" '[{"f":".mergify.yml","a":2,"d":1}]'; tick
[ "$(lvn)" = 0 ] && has risk_high=1 && ok || bad "E6 high: lv $(lvn) $(summ)"
grep -q 'low-small' "$LOGF" && bad "E6 a high head was low-small checked: $(grep low-small "$LOGF")" || ok

# ── off: the row reads off -> no WOULD line, nothing changes ──
lspr off; tick
[ "$(wouldn)" = 0 ] && [ "$(lvn)" = 0 ] && [ "$(posts)" = 1 ] && ok || bad "off: would $(wouldn) lv $(lvn) posts $(posts)"

echo "lead-review-enqueue-low-small.bh-7041: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
