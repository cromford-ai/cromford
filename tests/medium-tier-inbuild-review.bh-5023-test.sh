#!/bin/bash
# tests/medium-tier-inbuild-review.bh-5023-test.sh — BH-5023 (BH-4973.2): a
# medium-risk PR is reviewed lead-grade INSIDE the build that pushed it, and
# the hub's lead lane is left the high ones.
#
# Everything runs as shipped, against two scratch harnesses that carry their
# real bin closures:
#   BOX (box-demo)  "$DIR/bin/inbuild-lead-review.sh" and
#                             "$DIR/bin/lead-review.sh" one <id>, with the real
#                             prompts and a real git origin for the PR
#   HUB (box-hub)     "$DIR/bin/lead-review-land.sh" and
#                             "$DIR/bin/lead-review-enqueue.sh" tick
#   the hook                  the `# >>> inbuild lead review` block of
#                             bin/run-build.sh, extracted from the
#                             pipeline's flatten (tests/lib/rb-all.sh) and run
# Stubbed: curl (ONE stateful jobs worker both harnesses talk to, so the box's
# request rows are what the hub reads), gh (the PR, its compare, reviews and
# statuses), bin/agent-call.sh (records the prompt, answers $T/answer),
# bin/lead-verdict.sh and bin/lane-alert.sh on the hub (record argv).
#
# D1 mutations this suite was checked against: delete the hook's call line in
# run-build.sh (hook goes red), drop the inbuild: approve check in land
# (L-noapprove goes red), let the script post on a moved head (C2 goes red),
# drop the grace `continue` in the enqueue (G1 goes red).
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/medium-tier-inbuild-review.bh-5023-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lpp-stub.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

BH="$T/box"; HH="$T/hub"
mkdir -p "$BH/state" "$BH/logs" "$BH/prompts" "$BH/catalog/lanes.d" "$HH/state" "$HH/logs" "$HH/catalog" \
  "$T/fakebin" "$T/log" "$T/tmp" "$T/cfg" "$T/repos" "$T/build"
INB_OK=1
for s in bin/inbuild-lead-review.sh bin/lead-review.sh bin/jobs-client.sh bin/box-for.sh bin/fleet-conf.sh; do
  scratch_install_closure "$s" "$BH" >/dev/null || { INB_OK=0; echo "note: no closure for $s"; }
done
for s in bin/lead-review-land.sh bin/lead-review-enqueue.sh bin/jobs-client.sh bin/fleet-conf.sh; do
  scratch_install_closure "$s" "$HH" >/dev/null || exit 1
done
cp "$DIR/prompts/lead-review.md" "$DIR/prompts/lead-review-checklist.md" "$BH/prompts/"
cp "$DIR/catalog/lanes.d/_lib.json" "$BH/catalog/lanes.d/"
# TEST-CHANGE BH-4148 (merge of main): the lead protected paths come from the
# lead_protected_paths rows (tests/lib/lpp-stub.sh), not the deleted TSV. The rows
# are the cromford globs the TSV held (the fixture).
LPPF="$T/lpp.json"; LPPDOWN="$T/lpp-down"
set -f; lpp_set "$LPPF" example-org/cromford $(cat "$DIR/tests/fixtures/lead-protected-paths.bh-4148.txt"); set +f
lpp_install "$T/fakebin" "$LPPF" "$LPPDOWN"
echo box-demo > "$BH/state/box-name"
echo box-hub > "$HH/state/box-name"
printf 'cromford example-org/cromford https://demo.test /api/board 1 box-demo\n' > "$BH/fleet.conf"
cp "$BH/fleet.conf" "$HH/fleet.conf"
printf 'lead-test-token\n' > "$T/cfg/token"; chmod 600 "$T/cfg/token"

# ── the PR: a bare origin, two heads of PR 41 (H, then a push H2) ──
O="$T/origin.git"; W="$T/work"
git init -q --bare -b main "$O"; git init -q -b main "$W"
printf '# demo\n\nNo contract here.\n' > "$W/CLAUDE.md"; echo one > "$W/a.txt"
git -C "$W" add -A; git -C "$W" -c user.email=t@t -c user.name=t commit -qm base; git -C "$W" push -q "$O" main
echo two >> "$W/a.txt"; git -C "$W" -c user.email=t@t -c user.name=t commit -qam "pr change"; SHA=$(git -C "$W" rev-parse HEAD)
echo three >> "$W/a.txt"; git -C "$W" -c user.email=t@t -c user.name=t commit -qam "pr push"; SHA2=$(git -C "$W" rev-parse HEAD)
git -C "$W" push -q "$O" "HEAD:refs/pull/41/head"
git clone -q "$O" "$T/repos/cromford"
OTHER=$(printf 'c%.0s' {1..40})

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
R="$T/lrrows.json"; [ -f "\$R" ] || echo '[]' > "\$R"
qp() { printf '%s' "\${p#*\?}" | tr '&' '\n' | sed -n "s/^\$1=//p" | head -1; }
upd() { jq -c --arg id "\$1" "map(if .id == \\\$id then \$2 else . end)" "\$R" > "\$R.tmp" && mv "\$R.tmp" "\$R"; }
row() { jq -c --arg id "\$1" '[.[] | select(.id == \$id)] | first // empty' "\$R"; }
code=200; out='{}'
case "\$m \$p" in
$(lpp_curl_case m url body)
  "GET /api/settings/"*)
    k="\${p#/api/settings/}"
    if [ -f "$T/set/\$k" ]; then out=\$(jq -nc --arg k "\$k" --arg v "\$(cat "$T/set/\$k")" '{setting:{key:\$k,value:\$v}}')
    else code=404; out='{"error":"no such setting"}'; fi ;;
  "GET /api/model-routes/"*) out='{"ladder":[{"position":0,"model":"stub-model","runner":"claude"}],"source":"hub"}' ;;
  "POST /api/jobs") t=\$(jq -r '.ticket_id // "x"' <<<"\$body"); out=\$(jq -nc --arg t "\$t" '{job:{id:("job-"+\$t)}}') ;;
  "POST /api/lead-reviews")
    by=\$(jq -r '.requested_by // ""' <<<"\$body"); pri=\$(jq -r '.priority // 0' <<<"\$body")
    if [ "\$lead" != 1 ] && ! { [[ "\$by" =~ ^inbuild:[A-Za-z0-9._-]+:[A-Za-z0-9._-]+\$ ]] && [ "\$pri" = 0 ]; }; then
      code=403; out='{"error":"creating a lead review request needs the lead verdict token"}'
    else
      r=\$(jq -r .repo <<<"\$body"); pr=\$(jq -r .pr <<<"\$body"); h=\$(jq -r .head_sha <<<"\$body"); nt=\$(jq -r '.scope_notes // ""' <<<"\$body")
      have=\$(jq -c --arg r "\$r" --argjson p "\$pr" --arg h "\$h" '[.[] | select(.repo == \$r and .pr == \$p and .head_sha == \$h)] | first // empty' "\$R")
      if [ -n "\$have" ]; then
        if [ "\$(jq -r '.scope_notes // ""' <<<"\$have")" = "\$nt" ]; then out=\$(jq -c '{request:., existing:true}' <<<"\$have")
        else code=409; out=\$(jq -c '{error:"a lead review request for this repo, pr and head_sha already exists with different scope_notes", request:.}' <<<"\$have"); fi
      else
        n=\$(jq length "\$R")
        nr=\$(jq -c --arg id "lr-\$((n + 1))" '. + {id:\$id, status:"requested", promoted_verdict_at:null, created_at:"2026-10-07T00:00:00Z"}' <<<"\$body")
        jq -c --argjson r "\$nr" '. + [\$r]' "\$R" > "\$R.tmp" && mv "\$R.tmp" "\$R"
        code=201; out=\$(jq -c '{request:.}' <<<"\$nr")
      fi
    fi ;;
  "GET /api/lead-reviews?"*)
    st=\$(qp status); pro=\$(qp promoted)
    out=\$(jq -c --arg s "\$st" --arg pro "\$pro" '[.[] | select(.status as \$x | (\$s == "" or ((\$s | split(",")) | index(\$x) != null))
      and (\$pro != "0" or .promoted_verdict_at == null))] | {requests:., truncated:false}' "\$R") ;;
  "POST /api/lead-reviews/"*/claim)
    id="\${p#/api/lead-reviews/}"; id="\${id%/claim}"; j=\$(jq -r .job_id <<<"\$body"); b=\$(jq -r .box <<<"\$body")
    if [ "\$(row "\$id" | jq -r .status)" = requested ]; then
      upd "\$id" ".status = \"running\" | .job_id = \"\$j\" | .box = \"\$b\""; out=\$(row "\$id" | jq -c '{request:.}')
    else code=409; out=\$(row "\$id" | jq -c '{error:"not requested", request:.}'); fi ;;
  "POST /api/lead-reviews/"*/result)
    id="\${p#/api/lead-reviews/}"; id="\${id%/result}"
    upd "\$id" ". + (\$body | {status:.outcome, verdict:(.verdict // null), reviewer_model:(.reviewer_model // null), report_ref:(.report_ref // null), detail:(.detail // null)})"
    out=\$(row "\$id" | jq -c '{request:.}') ;;
  "POST /api/lead-reviews/"*/promoted)
    id="\${p#/api/lead-reviews/}"; id="\${id%/promoted}"
    if [ "\$lead" != 1 ]; then code=403; out='{"error":"needs the lead token"}'
    else upd "\$id" '.promoted_verdict_at = "2026-10-07T01:00:00Z"'; out=\$(row "\$id" | jq -c '{request:.}'); fi ;;
  "GET /api/lead-reviews/"*)
    id="\${p#/api/lead-reviews/}"; rw=\$(row "\$id")
    if [ -n "\$rw" ]; then out=\$(jq -c '{request:.}' <<<"\$rw"); else code=404; out='{"error":"no such lead review request"}'; fi ;;
  "GET /api/verdict?pr="*)
    n="\${p##*%2F}"
    if [ -f "$T/jv/\$n.json" ]; then out=\$(cat "$T/jv/\$n.json"); else code=404; out='{"error":"no job for this pr"}'; fi ;;
  "GET /api/verdicts?"*)
    n=\$(qp pr)
    if [ -f "$T/standing/\$n" ]; then st=\$(cat "$T/standing/\$n"); else st=null; fi
    out=\$(jq -nc --argjson s "\$st" '{standing:\$s, rows:[], truncated:false}') ;;
  "POST /api/risk-tiers") code=201; out='{"ok":true,"id":1}' ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/log/gh"
case "\$*" in
  *"api rate_limit"*)
    echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"-X GET repos/example-org/cromford/pulls?"*)
    printf 'HTTP/2 200\r\n\r\n'
    jq -nc --arg h "\$(cat "$T/livehead")" '[{number:41, html_url:"https://github.com/example-org/cromford/pull/41", title:"t", draft:false,
      state:"open", user:{login:"cromford[bot]",type:"Bot"}, head:{sha:\$h,ref:"ticket/bh-41"}, base:{ref:"main"}}]' ;;
  *"-X GET repos/example-org/cromford/pulls/41/reviews"*) printf 'HTTP/2 200\r\n\r\n[]\n' ;;
  *"-X POST repos/example-org/cromford/pulls/41/reviews"*) printf '%s\n' "\$*" >> "$T/log/ghreview"; printf 'HTTP/2 200\r\n\r\n{"id":1}\n' ;;
  *"-X GET repos/example-org/cromford/pulls/41"*)
    [ -e "$T/pr500" ] && { printf 'HTTP/2 500\r\n\r\n{"message":"boom"}\n'; exit 0; }
    printf 'HTTP/2 200\r\n\r\n'
    jq -nc --arg s "\$(cat "$T/livehead")" '{head:{sha:\$s,ref:"ticket/bh-41"},base:{ref:"main"},user:{login:"cromford[bot]"},title:"Add the thing",body:"PR body text"}' ;;
  *"-X GET repos/example-org/cromford/compare/"*)
    a="\$*"; h="\${a##*...}"; h="\${h%% *}"
    if [ -e "$T/cmp500" ]; then printf 'HTTP/2 500\r\n\r\n{"message":"boom"}\n'
    else printf 'HTTP/2 200\r\n\r\n'; cat "$T/cmp/\$h.json" 2>/dev/null || cat "$T/cmp/default.json"; fi ;;
  *"-X POST repos/example-org/cromford/statuses/"*) printf 'HTTP/2 201\r\n\r\n{"state":"success"}\n' ;;
esac
exit 0
EOF
cat > "$BH/bin/agent-call.sh" <<EOF
#!/bin/bash
echo x >> "$T/log/agent-count"; n=\$(wc -l < "$T/log/agent-count")
case "\$6" in @/*) cat "\${6#@}" ;; *) printf '%s' "\$6" ;; esac > "$T/log/prompt.\$n"
printf '%s %s %s\n' "\${AGENT_CALL_ROLE:-}" "\$1" "\$3" >> "$T/log/agent-argv"
cp "$T/answer" "\$5"
exit 0
EOF
cat > "$HH/bin/lead-verdict.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/log/lv"
exit 0
EOF
cat > "$HH/bin/lane-alert.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/log/alerts"
exit 0
EOF
chmod +x "$T/fakebin/curl" "$T/fakebin/gh" "$BH/bin/agent-call.sh" "$HH/bin/lead-verdict.sh" "$HH/bin/lane-alert.sh"

export PATH="$T/fakebin:$PATH" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test JOBS_RETRIES=0 \
  JOBS_BEAT_SECS=1 TMPDIR="$T/tmp" REPOS_ROOT="$T/repos" LANE_GATE_DISABLE=1 GH_ETAG=0 \
  LEAD_VERDICT_TOKEN_FILE="$T/cfg/token"
unset BOX_NAME JOBS_BOX HUB_BOX_NAME LEAD_REVIEW_MAX_PER_TICK LEAD_REVIEW_DEADLINE_S VERDICT_WINDOW_LINES _VP_WINDOW

# cmpx <head|default> <files json: [[name, add, del]...]>
cmpx() {
  jq -nc --argjson f "$2" '{total_commits:1, commits:[{parents:[{sha:"p"}], commit:{message:"feat: x"}}],
    files:[$f[] | {filename:.[0], status:"modified", additions:.[1], deletions:.[2]}]}' > "$T/cmp/$1.json"
}
MED='[["bin/lib/thing.sh",40,10]]'; LOW='[["docs/a.md",30,0]]'; HIGH='[[".mergify.yml",1,1]]'
approve() { # approve <pr> <reviewed sha> [headbound]
  # TEST-CHANGE (BH-5740): the grace now needs a running build job bound to the
  # head; the real /api/verdict answer carries .job.
  jq -nc --arg s "$2" --arg hb "${3:-n/a}" '{verdict:"APPROVE", tier:"2", provenance:"claude", merge_sha:null, job_id:"job-b", reviewed_sha:$s, job:{id:"job-b", kind:"build", status:"running"},
    artifacts:[{artifact_kind:"verdict", detail:({tier:"2", headbound:$hb, reviewed_sha:$s, settled:true}|tojson)}]}' > "$T/jv/$1.json"
}
seedrow() { # seedrow <id> <head> <status> <requested_by> <notes> [verdict]
  jq -c --arg i "$1" --arg h "$2" --arg s "$3" --arg b "$4" --arg n "$5" --arg v "${6:-}" '. + [{id:$i, repo:"example-org/cromford", pr:41,
    head_sha:$h, status:$s, requested_by:$b, scope_notes:$n, verdict:(if $v == "" then null else $v end), job_id:"job-x", box:"box-demo",
    reviewer_model:"stub-model", report_ref:"state/lead-reviews/x.md", promoted_verdict_at:null, created_at:"2026-10-07T00:00:00Z"}]' \
    "$T/lrrows.json" > "$T/lrrows.tmp" && mv "$T/lrrows.tmp" "$T/lrrows.json"
}
reset() {
  rm -f "$T/log"/* "$T"/{cmp500,pr500,lrrows.json} "$BH/logs"/* "$HH/logs"/*
  for d in "$BH/state/lead-reviews" "$BH/locks" "$HH/state/lead-review-land" "$HH/state/lead-review-enqueue" \
           "$T/jv" "$T/standing" "$T/cmp" "$T/set" "$T/build"; do scratch_rm "$d"; done
  mkdir -p "$T/jv" "$T/standing" "$T/cmp" "$T/set" "$T/build"
  echo '[]' > "$T/lrrows.json"
  echo enforce > "$T/set/risk_tier.mode.example-org.cromford"
  printf 'operator' > "$T/set/lead_pr_authors"
  echo "$SHA" > "$T/livehead"
  git --git-dir="$O" update-ref refs/pull/41/head "$SHA"
  cmpx default "$MED"
  approve 41 "$SHA"
  printf 'Findings\n- none\n\nVERDICT: MERGE\n' > "$T/answer"
}
inbuild() { # inbuild <sha> — the box half, as the hook calls it
  ( cd "$T" && HARNESS="$BH" FLEET_CONF="$BH/fleet.conf" KEY=BH-77 bash "$BH/bin/inbuild-lead-review.sh" \
      cromford example-org/cromford 41 "$1" "$T/build" ) > "$T/out" 2>&1; RC=$?
}
land() { ( cd "$T" && HARNESS="$HH" FLEET_CONF="$HH/fleet.conf" bash "$HH/bin/lead-review-land.sh" ) > "$T/lout" 2>&1; LRC=$?; }
enqueue() {
  ( cd "$T" && HARNESS="$HH" FLEET_CONF="$HH/fleet.conf" LEAD_REVIEW_AUTO_REPOS=example-org/cromford \
      LEAD_REVIEW_ENQUEUE_MAX_PER_TICK=5 LEAD_REVIEW_MAX_PER_PR_DAY=4 bash "$HH/bin/lead-review-enqueue.sh" tick ) > "$T/eout" 2>&1; ERC=$?
}
wlog() { cat "$T/log/worker" 2>/dev/null; }
creates() { wlog | grep -c '^POST /api/lead-reviews {' ; }
claims() { wlog | grep -c '^POST /api/lead-reviews/[^ ]*/claim ' ; }
agents() { [ -f "$T/log/agent-count" ] && wc -l < "$T/log/agent-count" | tr -d ' ' || echo 0; }
lvn() { [ -f "$T/log/lv" ] && wc -l < "$T/log/lv" | tr -d ' ' || echo 0; }
rowof() { jq -c --arg h "$1" '[.[] | select(.head_sha == $h)] | first // empty' "$T/lrrows.json"; }
txt() { sed -n "s/^$1=//p" "$T/build/inbuild-lead-review.txt" 2>/dev/null | head -1; }
ELOG="$HH/logs/lead-review-enqueue.log"
esumm() { grep ' tick repos=' "$ELOG" 2>/dev/null | tail -1; }

[ "$INB_OK" = 1 ] && [ -f "$DIR/bin/inbuild-lead-review.sh" ] && ok || bad "bin/inbuild-lead-review.sh does not exist"

# ── one: the subcommand's argument handling ──
( HARNESS="$BH" bash "$BH/bin/lead-review.sh" one ) >/dev/null 2>&1; [ "$?" = 2 ] && ok || bad "one with no id is not a usage error (rc 2)"
( HARNESS="$BH" bash "$BH/bin/lead-review.sh" one 'a/b' ) >/dev/null 2>&1; [ "$?" = 2 ] && ok || bad "one with an id that is not [A-Za-z0-9._-] is not a usage error"
( HARNESS="$BH" bash "$BH/bin/lead-review.sh" bogus ) >/dev/null 2>&1; [ "$?" = 2 ] && ok || bad "an unknown subcommand is not rc 2"

# ── C1: medium + MERGE on H: inbuild request, lead-grade review, land posts on H ──
reset; inbuild "$SHA"
[ "$RC" -eq 0 ] && ok || bad "C1 rc=$RC out=$(cat "$T/out")"
[ "$(creates)" = 1 ] && ok || bad "C1 want one request create, got $(creates): $(wlog | grep '^POST /api/lead-reviews ')"
CB=$(wlog | sed -n 's#^POST /api/lead-reviews \({.*}\) lead=\(.\)$#\1 \2#p' | head -1)
case "$CB" in *' 0') ok ;; *) bad "C1 the create carried the lead token: $CB" ;; esac
CJ=${CB% *}
[ "$(jq -r '.requested_by' <<<"$CJ" 2>/dev/null)" = "inbuild:box-demo:BH-77" ] && ok || bad "C1 requested_by: $CJ"
[ "$(jq -r '[.repo, (.pr|tostring), .head_sha] | join(" ")' <<<"$CJ" 2>/dev/null)" = "example-org/cromford 41 $SHA" ] && ok || bad "C1 the request is not for H: $CJ"
[ "$(jq -r '.priority // "none"' <<<"$CJ" 2>/dev/null)" = none ] && ok || bad "C1 the request carries a priority: $CJ"
case "$(jq -r '.scope_notes' <<<"$CJ" 2>/dev/null)" in "inbuild: builder APPROVE on ${SHA:0:12}, risk tier medium ("*")") ok ;; *) bad "C1 scope_notes: $CJ" ;; esac
[ "$(claims)" = 1 ] && ok || bad "C1 want one claim, got $(claims)"
RES=$(wlog | sed -n 's#^POST /api/lead-reviews/lr-1/result \({.*}\) lead=.$#\1#p' | head -1)
[ "$(jq -r '[.outcome, .verdict, .head_sha, .reviewer_model] | join(" ")' <<<"$RES" 2>/dev/null)" = "done MERGE $SHA stub-model" ] && ok || bad "C1 result: $RES"
[ "$(agents)" = 1 ] && ok || bad "C1 want one agent call, got $(agents)"
grep -q '^lead.review lead-review stub-model$' "$T/log/agent-argv" 2>/dev/null && ok || bad "C1 agent role/lane/model: $(cat "$T/log/agent-argv" 2>/dev/null)"
{ cat "$DIR/prompts/lead-review.md"; printf '\n'; cat "$DIR/prompts/lead-review-checklist.md"; } > "$T/want-prefix"
[ -f "$T/log/prompt.1" ] && cmp -s <(head -c "$(wc -c < "$T/want-prefix")" "$T/log/prompt.1") "$T/want-prefix" && ok \
  || bad "C1 the prompt does not open with prompts/lead-review.md + the checklist"
[ -e "$BH/locks/lead-review-tick.lock" ] && bad "C1 one took the tick lock" || ok
[ "$(txt tier)" = medium ] && [ "$(txt request)" = lr-1 ] && [ "$(txt rc)" = 0 ] && [ "$(txt verdict)" = MERGE ] && ok \
  || bad "C1 inbuild-lead-review.txt: $(tr '\n' ' ' < "$T/build/inbuild-lead-review.txt" 2>/dev/null)"
grep -q 'inbuild lead review' "$T/build/pipeline.log" 2>/dev/null && ok || bad "C1 no pipeline.log line"
# the hub promotes it: MERGE on H, note carries both tokens, stamped
land
[ "$(lvn)" = 1 ] && ok || bad "C1 land: want one lead-verdict.sh call, got $(lvn): $(cat "$T/log/lv" 2>/dev/null) $(cat "$HH/logs/lead-review-land.log" 2>/dev/null)"
LV=$(head -1 "$T/log/lv" 2>/dev/null)
case "$LV" in "post example-org/cromford 41 $SHA MERGE --source lead "*) ok ;; *) bad "C1 land argv: $LV" ;; esac
case "$LV" in *"--note lead-review:lr-1 inbuild:box-demo"*) ok ;; *) bad "C1 the note lacks lead-review:<id> and inbuild:<box>: $LV" ;; esac
grep -q "$OTHER\|$SHA2" "$T/log/lv" 2>/dev/null && bad "C1 a post named another sha" || ok
grep -q '^POST /api/lead-reviews/lr-1/promoted .*lead=1' <<<"$(wlog)" && ok || bad "C1 not stamped promoted"

# ── C2: a push to H2: nothing on H2 until the build reviews H2 ──
reset; echo "$SHA2" > "$T/livehead"; git --git-dir="$O" update-ref refs/pull/41/head "$SHA2"
inbuild "$SHA"
[ "$(creates)" = 0 ] && [ "$(agents)" = 0 ] && ok || bad "C2 a moved head was requested/reviewed: creates $(creates) agents $(agents)"
[ "$(txt result)" = head-moved ] && ok || bad "C2 inbuild-lead-review.txt result: $(txt result)"
approve 41 "$SHA2"; enqueue
[ "$(creates)" = 0 ] && ok || bad "C2 the enqueue requested H2 inside the grace: $(wlog | grep '^POST /api/lead-reviews ')"
grep -q "awaiting the in-build lead-grade review" "$ELOG" && ok || bad "C2 no awaiting line: $(cat "$ELOG")"
grep -qw 'risk_inbuild_wait=1' <<<"$(esumm)" && ok || bad "C2 summary: $(esumm)"
inbuild "$SHA2"
[ "$(creates)" = 1 ] && [ "$(jq -r .head_sha <<<"$(rowof "$SHA2")")" = "$SHA2" ] && ok || bad "C2 no request for H2: $(cat "$T/lrrows.json")"
[ "$(jq -r .verdict <<<"$(rowof "$SHA2")")" = MERGE ] && ok || bad "C2 H2 not reviewed MERGE: $(rowof "$SHA2")"
land
[ "$(lvn)" = 1 ] && grep -q "^post example-org/cromford 41 $SHA2 MERGE " "$T/log/lv" && ok || bad "C2 land on H2: $(cat "$T/log/lv" 2>/dev/null)"
grep -q " $SHA " "$T/log/lv" 2>/dev/null && bad "C2 a verdict was posted on the old head" || ok

# ── C3: an in-build BLOCK holds the PR ──
reset; printf 'Findings\n- [BLOCK] a.txt:2 — it breaks\n\nVERDICT: BLOCK\n' > "$T/answer"; inbuild "$SHA"
[ "$(jq -r .verdict <<<"$(rowof "$SHA")")" = BLOCK ] && [ "$(txt verdict)" = BLOCK ] && ok || bad "C3 result not BLOCK: $(rowof "$SHA")"
land
grep -q "^post example-org/cromford 41 $SHA BLOCK --source lead " "$T/log/lv" 2>/dev/null && ok || bad "C3 no BLOCK post: $(cat "$T/log/lv" 2>/dev/null)"
grep -q ' MERGE ' "$T/log/lv" 2>/dev/null && bad "C3 a MERGE was posted" || ok
grep -q 'event=REQUEST_CHANGES' "$T/log/ghreview" 2>/dev/null && ok || bad "C3 no REQUEST_CHANGES review: $(cat "$T/log/ghreview" 2>/dev/null)"

# ── C4: the negatives: nothing requested, nothing reviewed ──
neg() { # neg <label> — no create, no claim, no agent call
  [ "$(creates)" = 0 ] && [ "$(claims)" = 0 ] && [ "$(agents)" = 0 ] && ok \
    || bad "$1 requested/reviewed: creates $(creates) claims $(claims) agents $(agents); $(cat "$T/out")"
}
reset; cmpx default "$LOW"; inbuild "$SHA"; neg "C4 low"; [ "$(txt tier)" = low ] && ok || bad "C4 low tier: $(txt tier)"
reset; cmpx default "$HIGH"; inbuild "$SHA"; neg "C4 high"; [ "$(txt tier)" = high ] && ok || bad "C4 high tier: $(txt tier)"
reset; rm -f "$T/set/risk_tier.mode.example-org.cromford"; inbuild "$SHA"; neg "C4 off"
grep -q 'compare/' "$T/log/gh" 2>/dev/null && bad "C4 off read the compare" || ok
[ "$(txt mode)" = off ] && ok || bad "C4 off: mode $(txt mode)"
reset; echo shadow > "$T/set/risk_tier.mode.example-org.cromford"; inbuild "$SHA"; neg "C4 shadow"
grep -q 'WOULD review in-build' "$T/build/pipeline.log" 2>/dev/null && ok || bad "C4 shadow: no WOULD line: $(cat "$T/build/pipeline.log" 2>/dev/null)"
reset; : > "$T/cmp500"; inbuild "$SHA"; neg "C4 compare unreadable"
reset; : > "$T/pr500"; inbuild "$SHA"; neg "C4 head unreadable"
reset; inbuild "not-a-sha"; neg "C4 a sha that is not 40 hex"
# already running under the lead lane: adopted, never reviewed twice
reset; seedrow lr-9 "$SHA" running lead-review-enqueue:box-hub "auto: builder APPROVE on ${SHA:0:12}"; inbuild "$SHA"
[ "$(claims)" = 0 ] && [ "$(agents)" = 0 ] && ok || bad "C4 already-running reviewed again: claims $(claims) agents $(agents)"
[ "$(txt result)" = "already running" ] && ok || bad "C4 already-running result: $(txt result)"
# a requested row the hub filed with other notes (409 + row): adopted and reviewed once
reset; seedrow lr-9 "$SHA" requested lead-review-enqueue:box-hub "auto: builder APPROVE on ${SHA:0:12}"; inbuild "$SHA"
[ "$(claims)" = 1 ] && [ "$(agents)" = 1 ] && [ "$(txt request)" = lr-9 ] && ok || bad "C4 adopt-409: claims $(claims) agents $(agents) request $(txt request)"
# an answer with no VERDICT line: no done result, nothing to promote
reset; printf 'Looks fine to me.\n' > "$T/answer"; inbuild "$SHA"
[ "$(jq -r .status <<<"$(rowof "$SHA")")" = failed ] && ok || bad "C4 no-verdict row: $(rowof "$SHA")"
land; [ "$(lvn)" = 0 ] && ok || bad "C4 no-verdict was posted: $(cat "$T/log/lv")"

# ── L-noapprove: an inbuild row on a head with no builder APPROVE is never promoted ──
reset; seedrow lr-5 "$SHA" done inbuild:box-demo:BH-77 "inbuild: x" MERGE; approve 41 "$OTHER"; land
[ "$(lvn)" = 0 ] && ok || bad "L-noapprove a verdict was posted: $(cat "$T/log/lv")"
grep -q '^POST /api/lead-reviews/lr-5/promoted' <<<"$(wlog)" && bad "L-noapprove stamped promoted" || ok
[ "$(grep -c 'lead-inbuild-noapprove-lr-5' "$T/log/alerts" 2>/dev/null)" = 1 ] && grep -q -- '--critical' "$T/log/alerts" && ok \
  || bad "L-noapprove want one critical alert: $(cat "$T/log/alerts" 2>/dev/null)"
land; [ "$(grep -c 'lead-inbuild-noapprove-lr-5' "$T/log/alerts" 2>/dev/null)" = 1 ] && [ "$(lvn)" = 0 ] && ok || bad "L-noapprove second tick alerted again or posted"
# ...a reapproved@<head> rebind is an approval on that head
reset; seedrow lr-5 "$SHA" done inbuild:box-demo:BH-77 "inbuild: x" MERGE; approve 41 "$OTHER" "reapproved@$SHA"; land
[ "$(lvn)" = 1 ] && ok || bad "L-rebound not promoted: $(cat "$T/log/lv" 2>/dev/null)"
# ...and a row the enqueue filed is promoted as before, whatever job_verdict says
reset; seedrow lr-5 "$SHA" done lead-review-enqueue:box-hub "auto: x" MERGE; approve 41 "$OTHER"; land
[ "$(lvn)" = 1 ] && ! grep -q 'inbuild:' "$T/log/lv" && ok || bad "L-enqueue row: $(cat "$T/log/lv" 2>/dev/null)"

# ── G: the enqueue's grace for a medium head under enforce ──
MARK="$HH/state/lead-review-enqueue/inbuild-wait-example-org_cromford-41-${SHA:0:12}"
reset; enqueue
[ "$ERC" = 0 ] && [ "$(creates)" = 0 ] && ok || bad "G1 medium inside the grace: rc $ERC creates $(creates); $(cat "$ELOG")"
[ -f "$MARK" ] && ok || bad "G1 no grace marker"
grep -q "awaiting the in-build lead-grade review (3[0-9][0-9][0-9]s left)" "$ELOG" && ok || bad "G1 awaiting line: $(grep awaiting "$ELOG")"
touch -d '-2 hours' "$MARK"; enqueue
[ "$(creates)" = 1 ] && ok || bad "G2 grace spent: want 1 request, got $(creates)"
[ "$(wlog | grep '^POST /api/lead-reviews {' | grep -c 'lead=1')" = 1 ] && ok || bad "G2 the hub request lacks the lead token"
grep -q 'in-build grace spent' "$ELOG" && ok || bad "G2 no grace-spent line"
reset; cmpx default "$HIGH"; enqueue
[ "$(creates)" = 1 ] && [ "$(wlog | sed -n 's#^POST /api/lead-reviews \({.*}\) lead=.$#\1#p' | jq -r '.priority // 0')" = 1 ] && ok || bad "G3 high: $(wlog | grep '^POST /api/lead-reviews ')"
[ -f "$MARK" ] && bad "G3 a high head waited" || ok
reset; echo shadow > "$T/set/risk_tier.mode.example-org.cromford"; enqueue
[ "$(creates)" = 1 ] && ok || bad "G4 shadow medium was not requested: $(creates)"
reset; echo 60 > "$T/set/risk_tier.inbuild_grace_s"; enqueue; touch -d '-2 minutes' "$MARK"; enqueue
[ "$(creates)" = 1 ] && ok || bad "G5 a 60 s grace row did not override 3600: $(creates); $(grep -E 'awaiting|grace' "$ELOG")"
reset; enqueue; touch -d '-2 minutes' "$MARK"; enqueue
[ "$(creates)" = 0 ] && ok || bad "G5 control: a 2-minute-old marker under the 3600 s default requested"
reset; approve 41 "$OTHER" "reapproved@$SHA"; enqueue
[ "$(creates)" = 1 ] && [ ! -f "$MARK" ] && ok || bad "G6 a rebound head (no build will review it) waited: creates $(creates)"
# G8: a grace row of 0 is no hold at all, even when the marker is NEWER than the
# tick's start (its clock read). The marker is written seconds after the tick
# reads its clock, so `now - marker` was -1..-n there and `< 0` held the head:
# that made tests/jev-risk-shadow.bh-5024 B2/B5 flaky on main (976ce1e0a).
reset; echo 0 > "$T/set/risk_tier.inbuild_grace_s"; mkdir -p "$(dirname "$MARK")"; : > "$MARK"; touch -d '+1 minute' "$MARK"; enqueue
[ "$(creates)" = 1 ] && ok || bad "G8 a 0 s grace held a head whose marker is newer than the tick: creates $(creates); $(grep -E 'awaiting|grace' "$ELOG")"
reset; seedrow lr-1 "$SHA" done inbuild:box-demo:BH-77 "inbuild: x" MERGE
jq -nc '{verdict:"MERGE",source:"lead",id:9,created_at:"2026-10-07T00:00:00Z",report_url:null,reviewer:"box:hub"}' > "$T/standing/41"; enqueue
[ "$(creates)" = 0 ] && grep -qw 'skipped_verdict=1' <<<"$(esumm)" && ok || bad "G7 a head with the in-build lead verdict standing: $(esumm)"

# ── the hook: the marked block of the pipeline (tests/lib/rb-all.sh's flatten) ──
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB=$(rb_all "$DIR" "$T/run-build.all.sh") || { bad "hook: the pipeline does not flatten"; RB=/dev/null; }
awk 'index($0, "# >>> inbuild lead review")==1 {f=1;next} index($0, "# <<< inbuild lead review")==1 {exit} f' "$RB" > "$T/hook.sh"
[ -s "$T/hook.sh" ] && ok || bad "hook: no '# >>> inbuild lead review' block in the pipeline"
# After rb_settle's last line, before rb_close_out's first block (its hotfix migrate stage).
awk '/^STAGE_END settle /{s=NR} /^# >>> inbuild lead review/{h=NR} /^# >>> hotfix migrate stage/{c=NR} END{exit !(s && h && c && s<h && h<c)}' "$RB" \
  && ok || bad "hook: the block is not between rb_settle and rb_close_out"
HK="$T/hk"; mkdir -p "$HK/bin" "$HK/build"
cat > "$HK/bin/inbuild-lead-review.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/log/hook-argv"
printf '%s\n' "\$(ps -o comm= -p \$PPID)" >> "$T/log/hook-parent"
[ -e /proc/self/fd/7 ] && echo fd7-open >> "$T/log/hook-fd"
printf 'KEY=%s\n' "\${KEY:-}" >> "$T/log/hook-env"
exit \$(cat "$T/hookrc" 2>/dev/null || echo 0)
EOF
chmod +x "$HK/bin/inbuild-lead-review.sh"
echo "$SHA" > "$HK/build/reviewed-sha"
hook() { # hook <PR_URL> <VERDICT_WORD>
  rm -f "$T/log"/hook-*
  ( exec 7>"$T/fd7"
    HARNESS="$HK"; BUILD="$HK/build"; PROJECT=cromford; KEY=BH-77; TIER=2; PR_URL="$1"; VERDICT_WORD="$2"
    set -uo pipefail
    . "$T/hook.sh"
    echo "after rc=$? TIER=$TIER" ) > "$T/hout" 2>&1
}
hn() { [ -f "$T/log/hook-argv" ] && wc -l < "$T/log/hook-argv" | tr -d ' ' || echo 0; }
hook https://github.com/example-org/cromford/pull/41 APPROVE
[ "$(hn)" = 1 ] && [ "$(cat "$T/log/hook-argv")" = "cromford example-org/cromford 41 $SHA $HK/build" ] && ok || bad "hook APPROVE: argv $(cat "$T/log/hook-argv" 2>/dev/null); $(cat "$T/hout")"
[ "$(cat "$T/log/hook-parent" 2>/dev/null)" = timeout ] && ok || bad "hook: the script does not run under timeout: $(cat "$T/log/hook-parent" 2>/dev/null)"
[ -s "$T/log/hook-fd" ] && bad "hook: fd 7 (the build-key lock) reached the script" || ok
grep -qx 'KEY=BH-77' "$T/log/hook-env" 2>/dev/null && ok || bad "hook: KEY not passed: $(cat "$T/log/hook-env" 2>/dev/null)"
grep -qx 'after rc=0 TIER=2' "$T/hout" && ok || bad "hook APPROVE: the shell after the block: $(cat "$T/hout")"
hook https://github.com/example-org/cromford/pull/41 BLOCK
[ "$(hn)" = 0 ] && grep -qx 'after rc=0 TIER=2' "$T/hout" && ok || bad "hook BLOCK called the script: $(hn)"
hook "" APPROVE
[ "$(hn)" = 0 ] && ok || bad "hook with no PR_URL called the script"
echo 1 > "$T/hookrc"; hook https://github.com/example-org/cromford/pull/41 APPROVE; rm -f "$T/hookrc"
[ "$(hn)" = 1 ] && grep -qx 'after rc=0 TIER=2' "$T/hout" && ok || bad "hook: a failing script changed the build shell: $(cat "$T/hout")"
( exec 7>"$T/fd7"; HARNESS="$HK"; BUILD="$HK/build"; PROJECT=cromford; KEY=BH-77; TIER=2; PR_URL=https://github.com/example-org/cromford/pull/41
  VERDICT_WORD=APPROVE; LEAD_REVIEW_DEADLINE_S=junk; set -uo pipefail; . "$T/hook.sh"; echo "after rc=$? TIER=$TIER" ) > "$T/hout" 2>&1
grep -qx 'after rc=0 TIER=2' "$T/hout" && ok || bad "hook: a junk LEAD_REVIEW_DEADLINE_S broke the build shell: $(cat "$T/hout")"

grep -q 'test-secret\|lead-test-token' "$BH/logs"/* "$HH/logs"/* "$T/build/pipeline.log" 2>/dev/null && bad "a secret reached a log" || ok

echo "medium-tier-inbuild-review.bh-5023: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
