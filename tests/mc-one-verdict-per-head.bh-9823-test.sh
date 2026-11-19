#!/bin/bash
# tests/mc-one-verdict-per-head.bh-9823-test.sh — BH-9823: one review verdict
# of record per head, and no queue while a lead review of that head is pending.
#
# THE DEFECT (PR #9811, 2026-11-18). The conductor consumed the >12h autopilot
# MERGE on a moved head (headbound_review, bin/lib/mc/classify.sh) while a lead
# review of the same head was running, rebound the approval and enqueued. The
# rebound builder APPROVE put the head on the lead lane's worklist, gate 10
# passed it, and the lead lane bought a second review. Its BLOCK dequeued the
# PR: 2 cycles, 0 CI runs.
#
#   C1   HEAD_MOVED, box MERGE-WITH-NOTES, lead request running: the row waits
#        (WAIT_LEAD_REVIEW), 0 comments, 0 queue calls, review_source=lead-pending
#   C1b  READY with a lead request requested: WAIT_LEAD, 0 queue calls
#   C2   C1, then the lead MERGE lands: 1 rebind comment naming the lead review,
#        1 queue call, review_source=lead
#   C3   C1, then the lead BLOCK lands: parked head-not-reapproved, the
#        br_handoff_lines line, 0 queue calls
#   C4   box MERGE, no lead request: today's consume, review_source=autopilot;
#        gate 12 then refuses a lead review of that head
#   C5   lead request running past MC_LEAD_REVIEW_WAIT_S: 1 alert across two
#        ticks, then the autopilot path, review_source=autopilot-after-lead-limit
#   C6   every queue decision line of C1-C5 carries review_source=<word>
#   D1-D11  mc_ovh_decide, the decision table
#   G1-G10  lg_gate_autopilot_bound, the gate table, and the load order
#   R1   the attempts marks round-trip across processes
#   K1   the built lane registry carries MC_LEAD_REVIEW_WAIT_S
#
# Every case has its own PR number and head (no shared rows). The jobs worker
# and GitHub are local stubs: 0 network calls.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/mc-one-verdict-per-head.bh-9823-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 || { echo "SKIP: jq or flock missing"; exit 0; }
NOW=$(date +%s)
iso() { date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ'; }

# ---------------------------------------------------------------------------
# The scratch harness: tests/mc-lifecycle-tick.bh-8735-test.sh's K1 fixture (a
# Mergify repo, green checks, a green pre-queue entry), with the PR, the
# verdict rows and the lead review requests per case.
# ---------------------------------------------------------------------------
KT="$T/k"; KH="$KT/h"; KB="$KT/fakebin"
mkdir -p "$KH/bin/lib/jobs" "$KH/logs" "$KH/state" "$KH/flags" "$KH/locks" "$KH/builds" "$KH/env" "$KH/tmp" "$KB" "$KT/pr" "$KT/bodies"
scratch_install_closure bin/merge-conductor.sh "$KH" >/dev/null || { echo "setup: closure failed"; exit 1; }
cp "$DIR/bin/fleet-conf.sh" "$KH/bin/fleet-conf.sh"
mkdir -p "$KH/catalog"; cp "$DIR/catalog/lead-protected-paths.seed.tsv" "$KH/catalog/"
scratch_install_closure bin/jobs-client.sh "$KH" >/dev/null || { echo "setup: closure jobs failed"; exit 1; }
# The unit under test: the fragment (the driver globs bin/merge-conductor.d/).
# It is absent on the merge base, which is the red proof.
[ -f "$DIR/bin/merge-conductor.d/bh-9823-one-verdict.sh" ] \
  && { scratch_install_closure bin/merge-conductor.d/bh-9823-one-verdict.sh "$KH" >/dev/null || { echo "setup: closure fragment failed"; exit 1; }; }
for s in agent-call beat deploy-request pre-arm-guards codegraph-ensure; do printf '#!/bin/bash\nexit 0\n' > "$KH/bin/$s.sh"; done
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts.txt"\nexit 0\n' "$KT" > "$KH/bin/lane-alert.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts.txt"\nexit 0\n' "$KT" > "$KH/bin/alert-line.sh"
chmod +x "$KH/bin/"*.sh
cp "$DIR/tests/lib/rest-emit.sh" "$KB/restpr"; chmod +x "$KB/restpr"
# shellcheck source=tests/lib/verdict-fixture.sh
. "$DIR/tests/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
KSLUG=example-org/mgfy-os; KMAIN=$(printf 'd%.0s' {1..40}); KU="https://github.com/$KSLUG/pull"
printf 'mgfy %s - - 2 box-m\n' "$KSLUG" > "$KH/fleet.conf"
: > "$KH/env/global.env"
MGFY_YML=$(printf 'queue_rules:\n  - name: default\n    merge_method: squash\n' | base64 | tr -d '\n')
echo '[]' > "$KT/vrows.json"; echo '[]' > "$KT/lrq.json"

# gh: the PR read answers the head in $KT/pr/<num>; every POST is recorded in
# cmds.txt, and a comment body (body=@file) is copied to bodies/<num>.txt.
cat > "$KB/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$KT/calls.txt"
shopt -s nocasematch
GHA='{"name":"Build + Unit tests","status":"completed","conclusion":"success","started_at":"2026-10-11T10:00:00Z","app":{"slug":"github-actions"}}'
num_of() { sed -En 's#.*/(issues|pulls)/([0-9]+).*#\2#p' <<<"\$*"; }
case "\$*" in
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"auth token"*) echo fixture-token ;;
  *"api -i -X GET repos/$KSLUG/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$KSLUG/contents/.mergify.yml"*) restpr --raw 200 '{"content":"$MGFY_YML"}' ;;
  *"api -i -X GET repos/$KSLUG/commits/main"*|*"api -i -X GET repos/$KSLUG/git/ref/heads/main"*) restpr --raw 200 '{"sha":"$KMAIN","object":{"sha":"$KMAIN"}}' ;;
  *"check-runs?check_name="*) restpr --raw 200 "{\"check_runs\":[\$GHA]}" ;;
  *"api -i -X GET repos/"*"/commits/"*"/check-runs"*)
    restpr --raw 200 "{\"total_count\":2,\"check_runs\":[\$GHA,{\"name\":\"Mergify Merge Queue\",\"status\":\"in_progress\",\"conclusion\":null,\"output\":{\"title\":\"In merge queue\"},\"app\":{\"slug\":\"mergify\"}}]}" ;;
  *"actions/runs?head_sha="*)
    restpr --raw 200 '{"total_count":1,"workflow_runs":[{"id":900,"name":"Harness CI","run_started_at":"2026-10-11T10:00:00Z","run_attempt":1,"status":"completed","conclusion":"success"}]}' ;;
  *"api -i -X GET repos/"*"/commits/"*"/status"*) restpr --raw 200 '{"state":"success","statuses":[{"context":"lead-verdict","state":"success"}]}' ;;
  *"api -i -X GET repos/"*"/commits/"*) restpr --raw 200 '{"commit":{"committer":{"date":"2026-10-05T20:00:00Z"}}}' ;;
  *"api -i -X POST repos/"*"/statuses/"*) printf '%s\n' "\$*" >> "$KT/statuses.txt"; restpr --raw 201 '{"id":1}' ;;
  *"-X POST repos/"*"/issues/"*"/comments"*)
    printf '%s\n' "\$*" >> "$KT/cmds.txt"
    N=\$(num_of "\$*")
    for a in "\$@"; do case "\$a" in body=@/*) { cat "\${a#body=@}"; echo; echo '----'; } >> "$KT/bodies/\$N.txt" ;; body=*) { printf '%s\n' "\${a#body=}"; echo '----'; } >> "$KT/bodies/\$N.txt" ;; esac; done
    case "\$*" in *" -i "*) restpr --raw 201 '{"id":1}' ;; esac ;;
  *"api -X POST repos/"*"/issues/"*"/labels"*|*"api -i -X POST repos/"*"/issues/"*"/labels"*)
    printf '%s\n' "\$*" >> "$KT/cmds.txt"
    case "\$*" in *" -i "*) restpr --raw 200 '[]' ;; esac ;;
  *"api -X DELETE repos/"*"/labels/"*) printf '%s\n' "\$*" >> "$KT/cmds.txt" ;;
  *"pr merge"*|*"/pulls/"*"/merge"*) printf '%s\n' "\$*" >> "$KT/merges.txt"; exit 1 ;;
  *"issue close"*|*"-X PATCH repos/"*"/issues/"*) printf '%s\n' "\$*" >> "$KT/closes.txt" ;;
  *"api -i -X GET repos/$KSLUG/issues/"*"/comments"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/issues/"*) restpr --raw 200 '{"state":"open"}' ;;
  *"api -i -X GET repos/$KSLUG/pulls/"*"v3.diff"*) restpr --diff ;;
  *"api --paginate repos/"*"/comments"*|*"api --paginate repos/"*"/reviews"*) echo '[]' ;;
  *"api repos/"*"/comments --paginate"*) : ;;
  *"api repos/$KSLUG/issues/"*) printf '{"number":%s,"state":"open","labels":[],"body":""}\n' "\$(num_of "\$*")" ;;
  *"api -i -X GET repos/"*"/pulls/"*"/files"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$KSLUG/pulls?state=open"*) restpr --raw 200 "\$(cat "$KT/rest-list.json")" ;;
  *"api -i -X GET repos/"*"/pulls?state=open"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/pulls -f state="*|*"api -i -X GET repos/"*"/pulls?state=closed"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$KSLUG/pulls/"*)
    N=\$(num_of "\$*"); restpr OPEN "\$(cat "$KT/pr/\$N")" "ticket/mg-\$N" main "" MERGEABLE CLEAN operator "" "" ;;
  *"api repos/$KSLUG -q .id"*) echo 1 ;;
  *"pr list -R $KSLUG --state open"*) cat "$KT/list.json" ;;
  *"pr list"*) echo '[]' ;;
esac
exit 0
EOF
chmod +x "$KB/gh"

# The jobs worker. /api/verdicts answers $KT/vrows.json the worker's way
# (`standing` = the newest lead/human row on the head; a box row never
# stands). /api/lead-reviews answers $KT/lrq.json filtered by repo and pr ONLY:
# the status filter is NOT applied, so a `done` row on the head reaches the
# client and the client must re-check the status itself (failure mode 7).
# $KT/lrq-down makes the lead-reviews route answer 503.
cat > "$KB/curl" <<EOF
#!/bin/bash
URL="\${!#}"
printf '%s\n' "\$URL" >> "$KT/curl.txt"
qp() { printf '%s' "\${URL#*\?}" | tr '&' '\n' | sed -n "s/^\$1=//p" | head -1; }
case "\$URL" in
  */api/lead-protected-paths*) "$KB/lpp-answer" GET "\$URL"; exit 0 ;;
  */api/verdicts\?*)
    [ -e "$KT/vd-down" ] && { printf '{"error":"down"}\n503\n'; exit 0; }
    jq -c --arg r "\$(qp repo)" --argjson pr "\$(qp pr)" --arg h "\$(qp head)" '
      [.[] | select(.repo == \$r and .pr == \$pr)] | sort_by(-.id) as \$rows
      | {repo:\$r, pr:\$pr, head:\$h,
         standing:([\$rows[] | select(.head_sha == \$h and (.source == "lead" or .source == "human"))] | first),
         rows:\$rows, truncated:false}' "$KT/vrows.json"
    printf '\n200\n' ;;
  */api/lead-reviews\?*)
    [ -e "$KT/lrq-down" ] && { printf '{"error":"down"}\n503\n'; exit 0; }
    jq -c --arg r "\$(qp repo)" --arg pr "\$(qp pr)" \
      '{requests:[.[] | select(.repo == \$r and ((.pr|tostring) == \$pr))], truncated:false}' "$KT/lrq.json"
    printf '\n200\n' ;;
  */api/settings/lead_pr_authors) printf '{"setting":{"key":"lead_pr_authors","value":"lead-fixture-bot"}}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$KB/curl"
. "$DIR/tests/lib/lpp-stub.sh" || exit 1
lpp_set "$KT/lpp.json" "$KSLUG"
lpp_install "$KB" "$KT/lpp.json" "$KT/lpp-down"
touch "$KH/flags/merge-conductor-actions" "$KH/flags/merge-conductor-merge"
KLOG="$KH/logs/merge-conductor.log"
PRS="$KH/state/merge-conductor/pr-state.tsv"
ATT="$KH/state/merge-conductor/attempts.txt"
: > "$KT/cmds.txt"; : > "$KT/alerts.txt"; : > "$KT/calls.txt"; : > "$KLOG"
mkdir -p "$KH/state/merge-conductor/prequeue"

sha() { printf "$1%.0s" {1..40}; }
# mkpr <num> <head> <reviewed-sha> — the open PR, its build record (builder
# APPROVE bound to <reviewed-sha>) and its green pre-queue entry.
mkpr() {
  local n="$1" h="$2" r="$3" rec="$KH/builds/pool-mgfy-MG-$1-202611190001"
  printf '%s' "$h" > "$KT/pr/$n"
  mkdir -p "$rec"; echo "PR_CREATED $KU/$n" > "$rec/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$rec/review.md"; echo "$r" > "$rec/reviewed-sha"; : > "$rec/pipeline.log"
  printf 'green %s 1 -\n' "$NOW" > "$KH/state/merge-conductor/prequeue/example-org_mgfy-os_${n}_${h}_${KMAIN}"
  jq -nc --argjson n "$n" --arg u "$KU/$n" --arg h "$h" \
    '[{number:$n,url:$u,headRefOid:$h,headRefName:("ticket/mg-"+($n|tostring)),baseRefName:"main",isDraft:false,mergeStateStatus:"CLEAN",mergeable:"MERGEABLE",state:"OPEN",isInMergeQueue:false,labels:[]}]' > "$KT/list.json"
  jq -nc --arg r "$KSLUG" --argjson n "$n" --arg h "$h" '[{number:$n, html_url:("https://github.com/"+$r+"/pull/"+($n|tostring)), title:"t", draft:false, state:"open",
    updated_at:"2026-11-18T00:00:00Z", created_at:"2026-11-17T00:00:00Z", labels:[], user:{login:"operator",type:"User"},
    head:{sha:$h, ref:("ticket/mg-"+($n|tostring)), repo:{full_name:$r}}, base:{ref:"main", repo:{full_name:$r}}}]' > "$KT/rest-list.json"
}
# vrow <num> <head> <verdict> <source> — one verdicts row.
vrow() { jq -c --argjson n "$1" --arg h "$2" --arg v "$3" --arg s "$4" --arg r "$KSLUG" \
  '. + [{id:(length + 1), repo:$r, pr:$n, head_sha:$h, verdict:$v, source:$s, created_at:"2026-11-18T20:00:00Z"}]' \
  "$KT/vrows.json" > "$KT/v.tmp" && mv "$KT/v.tmp" "$KT/vrows.json"; }
# lrq <num> <head> <status> <age-s> — one lead_review_requests row (replaces
# any row of that (pr, head)).
lrq() { jq -c --argjson n "$1" --arg h "$2" --arg st "$3" --arg at "$(iso $(( $(date +%s) - $4 )))" --arg r "$KSLUG" \
  '[.[] | select((.pr == $n and .head_sha == $h) | not)] + [{id:("lr-"+($n|tostring)+"-"+$h[0:6]), repo:$r, pr:$n, head_sha:$h, status:$st, created_at:$at}]' \
  "$KT/lrq.json" > "$KT/l.tmp" && mv "$KT/l.tmp" "$KT/lrq.json"; }
ktick() { local n="$1"; shift
  ( cd "$KT" && env PATH="$KB:$PATH" HARNESS="$KH" HARNESS_SECRET=x JOBS_URL=http://worker.test GH_TOKEN=pat-fixture \
    MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 MC_MAIN_RED_DETECT=0 \
    MC_REHYDRATE=0 LAND_FIRE=0 PR_SNAPSHOT=0 MC_TICK_SECS=0 MC_MERGE_TREE=0 FLEET_CONF="$KH/fleet.conf" MC_ONLY_PR="$KSLUG#$n" "$@" \
    bash "$KH/bin/merge-conductor.sh" >/dev/null 2>"$KT/tick.err" ); }
state_of() { awk -F'\t' -v k="$KSLUG#$1" '$1==k {print $2}' "$PRS"; }
why_of()   { awk -F'\t' -v k="$KSLUG#$1" '$1==k {print $7}' "$PRS"; }
# qn <num> — queue calls (the Mergify enqueue label POST) for that PR.
qn() { grep -c "issues/$1/labels" "$KT/cmds.txt" | tr -d ' '; }
# cn <num> — comment POSTs for that PR.
cn() { grep -c "issues/$1/comments" "$KT/cmds.txt" | tr -d ' '; }
plog() { grep -F "$KSLUG#$1 " "$KLOG"; }
klog() { plog "$1" | tail -6; }

# ============================================================================
# THE FULL TICK (bin/merge-conductor.sh, the production entry point)
# ============================================================================
echo "C1: HEAD_MOVED, box MERGE-WITH-NOTES, a lead review running -> wait, no rebind, no queue"
N=41; H1=$(sha 1); mkpr $N "$H1" "$(sha 0)"
vrow $N "$H1" MERGE-WITH-NOTES box
lrq $N "$H1" running 120
ktick $N
[ "$(state_of $N)" = HEAD_MOVED ] && ok "C1 the row stays HEAD_MOVED" || bad "C1 state $(state_of $N): $(klog $N) $(tail -3 "$KT/tick.err")"
case "$(why_of $N)" in "WAIT_LEAD_REVIEW ${H1:0:8} "*) ok "C1 the why is WAIT_LEAD_REVIEW" ;; *) bad "C1 why: $(why_of $N)" ;; esac
[ "$(cn $N)" = 0 ] && ok "C1 no comment (no rebind)" || bad "C1 comments $(cn $N): $(cat "$KT/bodies/$N.txt" 2>/dev/null)"
grep -qx "apverdict $KSLUG#$N $H1" "$ATT" && bad "C1 the autopilot verdict was consumed" || ok "C1 no apverdict mark"
ktick $N
[ "$(qn $N)" = 0 ] && ok "C1 no queue call over two ticks" || bad "C1 queue calls $(qn $N): $(klog $N)"
[ "$(cn $N)" = 0 ] && ok "C1 still no comment on tick 2" || bad "C1 tick 2 comments $(cn $N)"
plog $N | grep -q "WAIT_LEAD_REVIEW.*review_source=lead-pending" && ok "C1 the wait line names review_source=lead-pending" || bad "C1 log: $(klog $N)"
[ "$(plog $N | grep -c "WAIT_LEAD_REVIEW on ${H1:0:8}")" = 1 ] && ok "C1 the wait is logged once per head" || bad "C1 wait lines: $(plog $N | grep -c "WAIT_LEAD_REVIEW on ${H1:0:8}")"

echo "C2: C1, then the lead MERGE lands -> the lead verdict is of record, then 1 queue call"
vrow $N "$H1" MERGE lead
lrq $N "$H1" done 60
ktick $N
[ "$(state_of $N)" = WAIT_REVIEW ] && ok "C2 the lead MERGE rebinds (WAIT_REVIEW)" || bad "C2 state $(state_of $N): $(klog $N) $(tail -3 "$KT/tick.err")"
[ "$(cn $N)" = 1 ] && ok "C2 one rebind comment" || bad "C2 comments $(cn $N)"
grep -q "the lead review of ${H1:0:12} verdicted MERGE" "$KT/bodies/$N.txt" 2>/dev/null && ok "C2 the comment names the lead review" || bad "C2 body: $(cat "$KT/bodies/$N.txt" 2>/dev/null)"
grep -q 'autopilot review of' "$KT/bodies/$N.txt" 2>/dev/null && bad "C2 the autopilot verdict was posted as well" || ok "C2 no autopilot rebind comment"
ktick $N
[ "$(qn $N)" = 1 ] && ok "C2 one queue call" || bad "C2 queue calls $(qn $N): $(klog $N)"
plog $N | grep -q "enqueued in the mergify merge queue at ${H1:0:8} .*review_source=lead\$" && ok "C2 the enqueue line names review_source=lead" \
  || bad "C2 enqueue line: $(plog $N | grep enqueued)"

echo "C1b: READY on a bound builder APPROVE, a lead review requested -> WAIT_LEAD, no queue"
N=42; H2=$(sha 2); mkpr $N "$H2" "$H2"
lrq $N "$H2" requested 0
ktick $N
[ "$(state_of $N)" = WAIT_LEAD ] && ok "C1b the row is WAIT_LEAD" || bad "C1b state $(state_of $N): $(klog $N) $(tail -3 "$KT/tick.err")"
[ "$(qn $N)" = 0 ] && ok "C1b no queue call" || bad "C1b queue calls $(qn $N)"
plog $N | grep -q "WAIT_LEAD one-verdict: lead review requested on ${H2:0:8}.*review_source=lead-pending" && ok "C1b the hold line names review_source=lead-pending" || bad "C1b log: $(klog $N)"
lrq $N "$H2" done 0
ktick $N
[ "$(qn $N)" = 1 ] && ok "C1b the request ended -> one queue call" || bad "C1b after: queue calls $(qn $N): $(klog $N)"
plog $N | grep -q "enqueued in the mergify merge queue at ${H2:0:8} .*review_source=builder\$" && ok "C1b review_source=builder" \
  || bad "C1b enqueue line: $(plog $N | grep enqueued)"

echo "C3: C1, then the lead BLOCK lands -> parked for the blocked-resolver, no queue"
N=43; H3=$(sha 3); mkpr $N "$H3" "$(sha 0)"
vrow $N "$H3" MERGE-WITH-NOTES box
lrq $N "$H3" running 30
ktick $N
case "$(why_of $N)" in WAIT_LEAD_REVIEW*) ok "C3 waits first" ;; *) bad "C3 why: $(why_of $N)" ;; esac
vrow $N "$H3" BLOCK lead
lrq $N "$H3" done 0
ktick $N
[ "$(state_of $N)" = BLOCKED_HUMAN ] && [ "$(why_of $N)" = head-not-reapproved ] && ok "C3 parked head-not-reapproved" || bad "C3 state $(state_of $N) why $(why_of $N): $(klog $N)"
HO=$(sed -nE 's#^([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8})Z ([^ ]+) (BLOCKED_AGENT|RED_TWICE) ([^ :]+).*(https://github\.com/[^ ]+)$#\2 \4#p' "$KLOG" | grep -c "^$KSLUG#$N head-not-reapproved$")
[ "$HO" = 1 ] && ok "C3 one br_handoff_lines line" || bad "C3 hand-off lines $HO: $(plog $N | grep BLOCKED_AGENT)"
plog $N | grep -q "BLOCKED_AGENT head-not-reapproved: the lead review of ${H3:0:12} verdicted BLOCK.*review_source=lead — handed to bin/blocked-resolver.sh" \
  && ok "C3 the park names review_source=lead" || bad "C3 park line: $(plog $N | grep BLOCKED_AGENT)"
grep -q 'autopilot review of' "$KT/bodies/$N.txt" 2>/dev/null && bad "C3 the autopilot verdict was posted" || ok "C3 no autopilot rebind comment"
ktick $N
[ "$(qn $N)" = 0 ] && ok "C3 no queue call" || bad "C3 queue calls $(qn $N)"

echo "C4: box MERGE, no lead request -> today's consume and enqueue; review_source=autopilot"
N=44; H4=$(sha 4); mkpr $N "$H4" "$(sha 0)"
vrow $N "$H4" MERGE box
ktick $N
[ "$(state_of $N)" = WAIT_REVIEW ] && ok "C4 the autopilot MERGE is consumed (WAIT_REVIEW)" || bad "C4 state $(state_of $N): $(klog $N) $(tail -3 "$KT/tick.err")"
[ "$(cn $N)" = 1 ] && ok "C4 one rebind comment" || bad "C4 comments $(cn $N)"
grep -q 'autopilot review of' "$KT/bodies/$N.txt" 2>/dev/null && ok "C4 the comment names the autopilot review" || bad "C4 body: $(cat "$KT/bodies/$N.txt" 2>/dev/null)"
ktick $N
[ "$(qn $N)" = 1 ] && ok "C4 one queue call" || bad "C4 queue calls $(qn $N): $(klog $N)"
plog $N | grep -q "enqueued in the mergify merge queue at ${H4:0:8} .*review_source=autopilot\$" && ok "C4 the enqueue line names review_source=autopilot" \
  || bad "C4 enqueue line: $(plog $N | grep enqueued)"
# ...and the lead lane does not start a review of that head (gate 12).
: > "$KT/gate.log"
( cd "$KT"; export PATH="$KB:$PATH" HARNESS="$KH" HARNESS_SECRET=x JOBS_URL=http://worker.test JOBS_RETRIES=0
  _lgt_log() { printf '%s\n' "$*" >> "$KT/gate.log"; }
  lr_required() { return 1; }
  . "$DIR/bin/lib/lead-gates.d/05-skip-ledger.sh"
  . "$DIR/bin/lib/lead-gates.d/12-autopilot-bound.sh" 2>/dev/null
  lg_gate_autopilot_bound "$KSLUG" "$N" "$H4" ) >/dev/null 2>&1; GRC=$?
[ "$GRC" = 10 ] && ok "C4 gate 12 refuses a lead review of the autopilot-bound head (rc 10)" || bad "C4 gate rc $GRC"
grep -q "\[skip autopilot-bound\] $KSLUG#$N @${H4:0:12} " "$KT/gate.log" && ok "C4 [skip autopilot-bound] is logged" || bad "C4 gate log: $(cat "$KT/gate.log")"

echo "C5: a lead review running past MC_LEAD_REVIEW_WAIT_S -> 1 alert, then the autopilot verdict"
N=45; H5=$(sha 5); mkpr $N "$H5" "$(sha 0)"
vrow $N "$H5" MERGE box
lrq $N "$H5" running 2701
ktick $N
ktick $N
[ "$(grep -c LEAD_REVIEW_OVERDUE "$KT/alerts.txt")" = 1 ] && ok "C5 exactly one LEAD_REVIEW_OVERDUE alert across two ticks" || bad "C5 alerts: $(grep -c LEAD_REVIEW_OVERDUE "$KT/alerts.txt")"
grep -q -- '--critical' <<<"$(grep LEAD_REVIEW_OVERDUE "$KT/alerts.txt")" && bad "C5 the alert is critical" || ok "C5 the alert is a warn"
grep -q 'autopilot review of' "$KT/bodies/$N.txt" 2>/dev/null && ok "C5 the autopilot verdict is used past the limit" || bad "C5 body: $(cat "$KT/bodies/$N.txt" 2>/dev/null)"
[ "$(qn $N)" = 1 ] && ok "C5 one queue call" || bad "C5 queue calls $(qn $N): $(klog $N)"
plog $N | grep -q "enqueued in the mergify merge queue at ${H5:0:8} .*review_source=autopilot-after-lead-limit\$" \
  && ok "C5 review_source=autopilot-after-lead-limit" || bad "C5 enqueue line: $(plog $N | grep enqueued)"

echo "C6: every queue decision line names its review source"
DEC=$(grep -E "$KSLUG#4[1-5] (WAIT_LEAD_REVIEW|WAIT_LEAD one-verdict|enqueued in the |BLOCKED_AGENT head-not-reapproved)" "$KLOG")
[ "$(grep -c . <<<"$DEC")" -ge 7 ] && ok "C6 $(grep -c . <<<"$DEC") decision lines" || bad "C6 decision lines: $DEC"
MISS=$(grep -vE 'review_source=[a-z][a-z+-]*' <<<"$DEC")
[ -z "$MISS" ] && ok "C6 each one carries review_source=<word>" || bad "C6 lines without the field: $MISS"

# ============================================================================
# D. mc_ovh_decide, the decision table (stubbed reads, the fragment itself)
# ============================================================================
HD=$(sha a); HOLD=$(sha b)
# udec <lrq-json|rc22|nonjson|nokey> [env...] — one mc_ovh_decide call in a
# fresh subshell; prints `rc=<rc> why=<why> src=<src> gets=<n>`.
udec() { local fx="$1"; shift
  ( unset MC_LEAD_REVIEW_WAIT_S; [ $# -gt 0 ] && export "$@"
    UATT="$KT/u-att.txt"; : > "$KT/u-gets"
    mc_log() { printf '%s\n' "$*" >> "$KT/u.log"; }
    mc_attempt_put() { printf '%s\n' "$1" >> "$UATT"; }
    mc_attempt_has() { grep -qxF "$1" "$UATT" 2>/dev/null; }
    mc_alert() { printf '%s\n' "$*" >> "$KT/u-alerts.txt"; }
    _jobs_req() { echo x >> "$KT/u-gets"
      case "$fx" in rc22) return 22 ;; nonjson) echo 'not json'; return 0 ;; nokey) echo '{"rows":[]}'; return 0 ;; esac
      printf '%s' "$fx"; }
    . "$DIR/bin/merge-conductor.d/bh-9823-one-verdict.sh" 2>/dev/null || { echo "rc=nofrag"; exit 0; }
    rc=0; mc_ovh_decide "$KSLUG#91" "$KSLUG" 91 "$HD" "$KU/91" HEAD_MOVED || rc=$?
    echo "rc=$rc why=${MC_OVH_WHY:-} src=${MC_OVH_SRC:-} gets=$(grep -c . "$KT/u-gets")" ) 2>/dev/null; }
row() { jq -nc --arg h "$1" --arg st "$2" --arg at "$(iso $(( $(date +%s) - $3 )))" '{id:"lr-x", repo:"example-org/mgfy-os", pr:91, head_sha:$h, status:$st, created_at:$at}'; }
reqs() { printf '{"requests":[%s],"truncated":false}' "$(IFS=,; echo "$*")"; }
ucase() { local label="$1" want="$2" got; shift 2; : > "$KT/u-att.txt"; : > "$KT/u-alerts.txt"; got=$(udec "$@")
  case "$got" in $want) ok "$label ($got)" ;; *) bad "$label: got '$got', want '$want'" ;; esac; }
ucase "D1 running on this head, 60s"        'rc=0 why=wait *'  "$(reqs "$(row "$HD" running 60)")"
ucase "D2 requested on this head, 0s"       'rc=0 why=wait *'  "$(reqs "$(row "$HD" requested 0)")"
ucase "D3 head_sha in upper case"           'rc=0 why=wait *'  "$(reqs "$(row "$(tr a-f A-F <<<"$HD")" running 60)")"
ucase "D4 pending here, running on an older head" 'rc=0 why=wait *' "$(reqs "$(row "$HOLD" running 30)" "$(row "$HD" requested 10)")"
ucase "D5 no rows"                          'rc=1 why=none *'  "$(reqs)"
ucase "D6 running on an older head only"    'rc=1 why=none *'  "$(reqs "$(row "$HOLD" running 60)")"
ucase "D7 done on this head (client re-checks the status)" 'rc=1 why=none *' "$(reqs "$(row "$HD" done 60)")"
ucase "D8a superseded on this head"         'rc=1 why=none *'  "$(reqs "$(row "$HD" superseded 60)")"
ucase "D8b failed on this head"             'rc=1 why=none *'  "$(reqs "$(row "$HD" failed 60)")"
ucase "D9a the read fails (rc 22)"          'rc=1 why=unread src=*+lead-unread *' rc22
ucase "D9b the answer is not JSON"          'rc=1 why=unread src=*+lead-unread *' nonjson
ucase "D9c no .requests array"              'rc=1 why=unread src=*+lead-unread *' nokey
ucase "D10 2700s exactly is past the limit" 'rc=1 why=limit src=autopilot-after-lead-limit *' "$(reqs "$(row "$HD" running 2700)")"
[ "$(grep -c LEAD_REVIEW_OVERDUE "$KT/u-alerts.txt")" = 1 ] && ok "D10 one alert" || bad "D10 alerts: $(cat "$KT/u-alerts.txt")"
grep -qx "ovhlimit $KSLUG#91 $HD" "$KT/u-att.txt" && ok "D10 the ovhlimit mark is written" || bad "D10 marks: $(cat "$KT/u-att.txt")"
udec "$(reqs "$(row "$HD" running 2800)")" >/dev/null
[ "$(grep -c LEAD_REVIEW_OVERDUE "$KT/u-alerts.txt")" = 1 ] && ok "D10 a second call past the limit sends no second alert" || bad "D10 alerts after 2: $(cat "$KT/u-alerts.txt")"
# (2600, not 2699: a second can pass between the fixture and the read. row() reads
# the clock per call; a suite-start NOW was ~130 s stale here and read 2600 as 2730.)
ucase "D10b 2600s is still a wait"          'rc=0 why=wait *'  "$(reqs "$(row "$HD" running 2600)")" MC_LEAD_REVIEW_WAIT_S=2700
ucase "D11 the limit 0 is off, nothing read" 'rc=1 why=off * gets=0' "$(reqs "$(row "$HD" running 60)")" MC_LEAD_REVIEW_WAIT_S=0
ucase "D11b a non-number limit reads as 2700" 'rc=0 why=wait *' "$(reqs "$(row "$HD" running 2000)")" MC_LEAD_REVIEW_WAIT_S=abc

# ============================================================================
# G. lg_gate_autopilot_bound, the gate table (the real vd_box_word over the
#    fixture verdicts table; lr_required stubbed)
# ============================================================================
GN=92; GH=$(sha 6); GOLD=$(sha 7)
# ugate <lr_required-rc> <head> — prints the gate's rc.
ugate() { : > "$KT/gate.log"
  ( cd "$KT"; export PATH="$KB:$PATH" HARNESS="$KH" HARNESS_SECRET=x JOBS_URL=http://worker.test JOBS_RETRIES=0
    _lgt_log() { printf '%s\n' "$*" >> "$KT/gate.log"; }
    LRRC="$1"; lr_required() { return "$LRRC"; }
    . "$DIR/bin/lib/lead-gates.d/05-skip-ledger.sh"
    . "$DIR/bin/lib/lead-gates.d/12-autopilot-bound.sh" 2>/dev/null || { echo nofrag; exit 0; }
    rc=0; lg_gate_autopilot_bound "$KSLUG" "$GN" "$2" || rc=$?; echo "$rc" ) 2>/dev/null; }
gcase() { local label="$1" want="$2" got; got=$(ugate "$3" "$4")
  [ "$got" = "$want" ] && ok "$label (rc $got)" || bad "$label: rc '$got', want $want; log: $(cat "$KT/gate.log")"; }
gvreset() { jq -c --argjson n "$GN" '[.[] | select(.pr != $n)]' "$KT/vrows.json" > "$KT/v.tmp" && mv "$KT/v.tmp" "$KT/vrows.json"
  scratch_rm "$KH/state/lead-review/gate-skip"; }
gvreset; vrow $GN "$GH" MERGE box;             gcase "G1 box MERGE on this head"            10 1 "$GH"
grep -q '\[skip autopilot-bound\]' "$KT/gate.log" && ok "G1 [skip autopilot-bound] logged" || bad "G1 log: $(cat "$KT/gate.log")"
gvreset; vrow $GN "$GH" MERGE-WITH-NOTES box;  gcase "G2 box MERGE-WITH-NOTES on this head" 10 1 "$GH"
gvreset; vrow $GN "$GH" BLOCK box;             gcase "G3 box BLOCK on this head is not bound" 0 1 "$GH"
gvreset; vrow $GN "$GOLD" MERGE box;           gcase "G4 box MERGE on an older head only"   0 1 "$GH"
gvreset; vrow $GN "$GH" APPROVE box;           gcase "G5 box word APPROVE"                  0 1 "$GH"
gvreset;                                       gcase "G6 no box row"                        0 1 "$GH"
gvreset; vrow $GN "$GH" MERGE box; touch "$KT/vd-down"
                                               gcase "G7 the verdicts read is unreadable"   0 1 "$GH"
rm -f "$KT/vd-down"
gvreset; vrow $GN "$GH" MERGE box;             gcase "G8 a lead_required repo (rc 0)"       0 0 "$GH"
gvreset; vrow $GN "$GH" MERGE box;             gcase "G9 lead_required unreadable (rc 2)"   0 2 "$GH"
gvreset; vrow $GN "$GH" MERGE lead;            gcase "G10 a lead MERGE, no box row"         0 1 "$GH"
gvreset
ORDER=$( cd "$KT"; export HARNESS="$KH"; _lgt_log() { :; }
  . "$DIR/bin/lib/lead-gates.sh" >/dev/null 2>&1; _lgt_load >/dev/null 2>&1; printf '%s ' "${_LGT_GATES[@]}" )
case "$ORDER" in *"lg_gate_builder "*"lg_gate_autopilot_bound "*) ok "G11 _lgt_load runs gate 12 after gate 10" ;; *) bad "G11 gate order: $ORDER" ;; esac

# ============================================================================
# R. the attempts marks round-trip across processes (the real conductor lib)
# ============================================================================
RH=$(sha 8)
mcl() { ( cd "$KT"; export PATH="$KB:$PATH" HARNESS="$KH" HARNESS_SECRET=x JOBS_URL=http://worker.test JOBS_RETRIES=0
  bash -c '. "$HARNESS/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1; mc_init >/dev/null 2>&1; '"$1" ) 2>/dev/null; }
for k in ovhwait ovhwaitlog ovhlimit ovhunread ovhlead; do mcl "mc_attempt_put '$k $KSLUG#93 $RH'"; done
GOT=$(mcl "for k in ovhwait ovhwaitlog ovhlimit ovhunread ovhlead; do mc_attempt_has \"\$k $KSLUG#93 $RH\" && printf '%s ' \$k; done")
[ "$GOT" = "ovhwait ovhwaitlog ovhlimit ovhunread ovhlead " ] && ok "R1 five marks written in one process, read in another" || bad "R1 read back: '$GOT'"
GOT=$(mcl "mc_attempt_has 'ovhwait $KSLUG#93 $(sha 9)' && echo yes || echo no")
[ "$GOT" = no ] && ok "R1 a mark is bound to its head" || bad "R1 other head: $GOT"

# ============================================================================
# K. the knob in the built lane registry
# ============================================================================
REG="$T/lanes.json"
( cd "$DIR" && bin/lanes-build.sh --to "$REG" >/dev/null 2>&1 )
KN=$(jq -c '.lanes[] | select(.id == "merge-conductor") | .knobs[] | select(.env == "MC_LEAD_REVIEW_WAIT_S") | [.default, .required, .zero_means, .read_in]' "$REG" 2>/dev/null)
[ "$KN" = '[2700,true,"off","bin/merge-conductor.d/bh-9823-one-verdict.sh"]' ] && ok "K1 MC_LEAD_REVIEW_WAIT_S default 2700, required, 0 = off" || bad "K1 registry row: '$KN'"
[ -n "${BH9823_KEEP:-}" ] && cp -r "$KT" "$BH9823_KEEP"
echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
