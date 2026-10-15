#!/bin/bash
# tests/silence-before-risk.bh-5797-test.sh — BH-5797, lead review
# lr-5811-82fcc1df2aa1: the silence check runs BEFORE the risk tier. A head the
# risk tier calls low (new tests only) must never be signed off past a public
# leak marker, and the lead must see a lead-route marker. The rig is
# tests/lead-review-enqueue-risk.bh-5022-test.sh's (risk_tier.mode enforce on
# example-org/cromford, the real bin/lib/risk-tier.sh), with the compare's
# files carrying a patch and gh answering the label and comment POSTs.
#
#   L1  enforce, a new suite with a gitleaks marker: needs-human label, one
#       comment, NO risk-tier sign-off, no lead review, skipped_silence=1
#   L2  enforce, a new suite with a determinism marker and its reason: no
#       risk-tier sign-off; the lead review is requested with the marker in
#       its notes
#   L3  control: the same new suite with no marker is signed off as low
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/silence-before-risk.bh-5797-test.sh
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
# The protected-paths catalog is data the lead-authority lib reads beside bin/;
# without it every head reads "protected paths unreadable" (medium).
mkdir -p "$H/catalog"; cp "$DIR/catalog/silence-markers.tsv" "$H/catalog/"
# TEST-CHANGE BH-4148 (merge of main): the lead protected paths come from the
# lead_protected_paths rows (tests/lib/lpp-stub.sh), not the deleted TSV. The rows
# are the cromford globs the TSV held (the fixture).
LPPF="$T/lpp.json"; LPPDOWN="$T/lpp-down"
set -f; lpp_set "$LPPF" example-org/cromford $(cat "$DIR/tests/fixtures/lead-protected-paths.bh-4148.txt"); set +f
lpp_install "$T/fakebin" "$LPPF" "$LPPDOWN"
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
  *"-X POST repos/example-org/"*"/issues/41/labels"*)
    echo label >> "$T/log/labels"; printf 'HTTP/2 200\r\n\r\n[{"name":"needs-human"}]\n' ;;
  *"-X POST repos/example-org/"*"/issues/41/comments"*)
    echo comment >> "$T/log/comments"; printf 'HTTP/2 201\r\n\r\n{"id":1}\n' ;;
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
  jq -nc --arg s "$2" '{verdict:"APPROVE", tier:"2", provenance:"-", merge_sha:null, job_id:"job-1", reviewed_sha:$s,
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


GL="gitleaks:""allow"; DOK="determinism: ""ok"
# cmpp <head> <path> <added line> — one new file with a patch
cmpp() {
  jq -nc --arg p "$2" --arg l "$3" '{total_commits:1, commits:[{parents:[{sha:"p"}], commit:{message:"feat: x"}}],
    files:[{filename:$p, status:"added", additions:2, deletions:0, patch:("@@ -0,0 +1,2 @@\n+#!/bin/bash\n+" + $l)}]}' > "$T/cmp/$1.json"
}
lowtest() { reset; echo enforce > "$T/mode"; pr 41 "$SHA"; approve 41 "$SHA"; cmpp "$SHA" tests/foo-test.sh "$1"; }
labels() { [ -f "$T/log/labels" ] && wc -l < "$T/log/labels" | tr -d ' ' || echo 0; }

# ── L1: a gitleaks marker in a new suite ──
lowtest "TOKEN=xyz # $GL"; tick
[ "$(lvn)" = 0 ] && ok || bad "L1 a leak marker was signed off by the risk tier: $(cat "$T/log/lv" 2>/dev/null)"
[ "$(labels)" = 1 ] && ok || bad "L1 no needs-human label: $(cat "$T/log/gh" | grep -c labels)"
[ "$(posts)" = 0 ] && ok || bad "L1 a lead review was requested past the label"
has skipped_silence=1 && ok || bad "L1 summary: $(summ)"

# ── L2: a lead-route marker with its reason ──
lowtest "sleep 1 # $DOK — a bounded wait for the child"; tick
[ "$(lvn)" = 0 ] && ok || bad "L2 a lead marker was signed off by the risk tier: $(cat "$T/log/lv" 2>/dev/null)"
[ "$(posts)" = 1 ] && grep -q 'silence markers for the lead to judge' <<<"$(LRBODY)" && ok \
  || bad "L2 the lead review was not requested with the marker in its notes: $(LRBODY)"
grep -q 'risk tier low, but the diff adds silence markers' "$LOGF" && ok || bad "L2 no log line saying why low was not signed: $(tail -3 "$LOGF")"

# ── L3: control: no marker, signed off ──
lowtest "echo plain"; tick
[ "$(lvn)" = 1 ] && [ "$(posts)" = 0 ] && ok || bad "L3 a plain new suite was not signed off as low: lv $(lvn) posts $(posts) $(tail -3 "$LOGF")"

echo "silence-before-risk.bh-5797: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
