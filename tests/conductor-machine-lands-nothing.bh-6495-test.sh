#!/bin/bash
# tests/conductor-machine-lands-nothing.bh-6495-test.sh — BH-6495 review F1
# and refute F1: a lane-run machine (MC_ON_MACHINE=1) lands nothing. The hub
# owns every enqueue, merge and settle, because the machine has no builds/
# record (no BH-4585 CONTRADICTION check) and its flock serialises against
# nobody.
#
# Driven through the WHOLE bin/merge-conductor.sh keyed tick on the K1 fixture
# of tests/conductor-events.bh-5521-test.sh: one READY PR #31 on a Mergify
# repo (green checks, a green lead-verdict status, a green pre-queue entry,
# flags merge-conductor-actions + merge-conductor-merge). A `curl` stub serves
# the jobs ledger's /api/verdict answer from $KT/ledger.json.
#
#   L1  control: a hub keyed tick enqueues #31 (the fixture reaches a landing)
#   L2  control: ledger APPROVE + record BLOCK on the hub parks #31 as a
#       verdict contradiction and enqueues nothing
#   L3  the same ledger APPROVE on a machine, which has no builds/ record:
#       no enqueue line, no Mergify label or comment, no merge, the row is not
#       QUEUED, the deferred file says `land`, and one machine line is logged
#   L4  a QUEUED row of #40 that GitHub reports MERGED: a machine keyed tick
#       of #31 does not settle it (no MERGED line, no MERGED row, no deployreq
#       line, no issue close, no alert, no `settle` or `dv` word), and the
#       hub's next keyed tick of #31 settles it
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/conductor-machine-lands-nothing.bh-6495-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 || { echo "SKIP: jq or flock missing"; exit 0; }
NOW=$(date +%s)

KT="$T/k"; KH="$KT/h"; KB="$KT/fakebin"
mkdir -p "$KH/bin/lib" "$KH/logs" "$KH/state" "$KH/flags" "$KH/locks" "$KH/builds" "$KH/env" "$KH/tmp" "$KB"
scratch_install_closure bin/merge-conductor.sh "$KH" >/dev/null || { echo "setup: closure failed"; exit 1; }
cp "$DIR/bin/fleet-conf.sh" "$KH/bin/fleet-conf.sh"
mkdir -p "$KH/catalog"; cp "$DIR/catalog/lead-protected-paths.seed.tsv" "$KH/catalog/"
scratch_install_closure bin/jobs-client.sh "$KH" >/dev/null || { echo "setup: closure jobs failed"; exit 1; }
for s in agent-call beat deploy-request pre-arm-guards codegraph-ensure; do printf '#!/bin/bash\nexit 0\n' > "$KH/bin/$s.sh"; done
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts.txt"\nexit 0\n' "$KT" > "$KH/bin/lane-alert.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts.txt"\nexit 0\n' "$KT" > "$KH/bin/alert-line.sh"
chmod +x "$KH/bin/"*.sh
cp "$DIR/tests/lib/rest-emit.sh" "$KB/restpr"; chmod +x "$KB/restpr"
# shellcheck source=tests/lib/verdict-fixture.sh
. "$DIR/tests/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
KSLUG=example-org/mgfy-os; KHEAD=$(printf 'a%.0s' {1..40}); KMAIN=$(printf 'd%.0s' {1..40}); KU="https://github.com/$KSLUG/pull"
H40=$(printf 'e%.0s' {1..40}); M40=$(printf 'f%.0s' {1..40})
printf 'mgfy %s - - 2 box-m\n' "$KSLUG" > "$KH/fleet.conf"
: > "$KH/env/global.env"
REC="$KH/builds/pool-mgfy-MG-31-202610110001"; mkdir -p "$REC"
echo "PR_CREATED $KU/31" > "$REC/RESULT"; printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"
echo "$KHEAD" > "$REC/reviewed-sha"; : > "$REC/pipeline.log"
cat > "$KT/list.json" <<J
[{"number":31,"url":"$KU/31","headRefOid":"$KHEAD","headRefName":"ticket/mg-31","baseRefName":"main","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","isInMergeQueue":false,"labels":[]}]
J
jq -nc --arg r "$KSLUG" --arg h "$KHEAD" '[{number:31, html_url:("https://github.com/"+$r+"/pull/31"), title:"t", draft:false, state:"open",
  updated_at:"2026-10-11T00:00:00Z", created_at:"2026-10-10T00:00:00Z", labels:[], user:{login:"operator",type:"User"},
  head:{sha:$h, ref:"ticket/mg-31", repo:{full_name:$r}}, base:{ref:"main", repo:{full_name:$r}}}]' > "$KT/rest-list.json"
MGFY_YML=$(printf 'queue_rules:\n  - name: default\n    merge_method: squash\n' | base64 | tr -d '\n')
cat > "$KB/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$KT/calls.txt"
case "\$*" in
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"auth token"*) echo fixture-token ;;
  *"api -i -X GET repos/$KSLUG/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$KSLUG/contents/.mergify.yml"*) restpr --raw 200 '{"content":"$MGFY_YML"}' ;;
  *"api -i -X GET repos/$KSLUG/commits/main"*|*"api -i -X GET repos/$KSLUG/git/ref/heads/main"*) restpr --raw 200 '{"sha":"$KMAIN","object":{"sha":"$KMAIN"}}' ;;
  *"check-runs?check_name="*) restpr --raw 200 '{"check_runs":[{"name":"Build + Unit tests","status":"completed","conclusion":"success","started_at":"2026-10-11T10:00:00Z"}]}' ;;
  *"api -i -X GET repos/"*"/commits/"*"/check-runs"*) restpr --raw 200 '{"total_count":2,"check_runs":[{"name":"Build + Unit tests","status":"completed","conclusion":"success","started_at":"2026-10-11T10:00:00Z"},{"name":"Mergify Merge Queue","status":"in_progress","conclusion":null,"output":{"title":"In merge queue"},"app":{"slug":"mergify"}}]}' ;;
  *"api -i -X GET repos/"*"/commits/"*"/status"*) restpr --raw 200 '{"state":"success","statuses":[{"context":"lead-verdict","state":"success"}]}' ;;
  *"api -i -X POST repos/"*"/statuses/"*) printf '%s\n' "\$*" >> "$KT/statuses.txt"; restpr --raw 201 '{"id":1}' ;;
  *"api -X POST repos/"*"/issues/"*"/comments"*|*"api -X POST repos/"*"/issues/"*"/labels"*) printf '%s\n' "\$*" >> "$KT/cmds.txt" ;;
  *"api -i -X POST repos/"*"/issues/"*"/comments"*) printf '%s\n' "\$*" >> "$KT/cmds.txt"; restpr --raw 201 '{"id":1}' ;;
  *"pr merge"*|*"/pulls/"*"/merge"*) printf '%s\n' "\$*" >> "$KT/merges.txt"; exit 1 ;;
  *"issue close"*|*"-X PATCH repos/"*"/issues/"*) printf '%s\n' "\$*" >> "$KT/closes.txt" ;;
  *"api -i -X GET repos/$KSLUG/issues/31/comments"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/issues/"*) restpr --raw 200 '{"state":"open"}' ;;
  *"api -i -X GET repos/$KSLUG/pulls/31"*"v3.diff"*) restpr --diff ;;
  *"api --paginate repos/"*"/comments"*|*"api --paginate repos/"*"/reviews"*) echo '[]' ;;
  *"api repos/"*"/comments --paginate"*) : ;;
  *"api repos/$KSLUG/issues/31"*) printf '{"number":31,"state":"open","labels":[],"body":""}\n' ;;
  *"api -i -X GET repos/"*"/pulls/"*"/files"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$KSLUG/pulls/31"*) restpr OPEN "$KHEAD" ticket/mg-31 main "" MERGEABLE CLEAN operator "" "" ;;
  *"api -i -X GET repos/$KSLUG/pulls/40"*) restpr MERGED "$H40" ticket/mg-40 main "" MERGEABLE CLEAN operator "$M40" "" ;;
  *"api -i -X GET repos/$KSLUG/pulls?state=open"*) restpr --raw 200 "\$(cat "$KT/rest-list.json")" ;;
  *"api -i -X GET repos/"*"/pulls?state=open"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/pulls -f state="*|*"api -i -X GET repos/"*"/pulls?state=closed"*) restpr --raw 200 '[]' ;;
  *"api repos/$KSLUG -q .id"*) echo 1 ;;
  *"pr list -R $KSLUG --state open"*) cat "$KT/list.json" ;;
  *"pr list"*) echo '[]' ;;
esac
exit 0
EOF
chmod +x "$KB/gh"
cat > "$KB/curl" <<EOF
#!/bin/bash
URL="\${!#}"
case "\$URL" in
  */api/lead-protected-paths*) "$KB/lpp-answer" GET "\$URL"; exit 0 ;;
  */api/verdict\?*) if [ -s "$KT/ledger.json" ]; then printf '%s\n200\n' "\$(cat "$KT/ledger.json")"; else printf '{"error":"not found"}\n404\n'; fi ;;
  */api/verdicts\?*) printf '{"standing":null}\n200\n' ;;
  */api/settings/lead_pr_authors) printf '{"setting":{"key":"lead_pr_authors","value":"lead-fixture-bot"}}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$KB/curl"
# TEST-CHANGE BH-4148: the lead reads protected paths from the jobs route, not
# catalog/lead-protected-paths.tsv; the fixture repo has no rows, so it is not
# governed, as under the old catalog file.
. "$DIR/tests/lib/lpp-stub.sh" || exit 1
lpp_set "$KT/lpp.json" "$KSLUG"
lpp_install "$KB" "$KT/lpp.json" "$KT/lpp-down"
touch "$KH/flags/merge-conductor-actions" "$KH/flags/merge-conductor-merge"
ktick() {
  ( cd "$KT" && env PATH="$KB:$PATH" HARNESS="$KH" HARNESS_SECRET=x JOBS_URL=http://worker.test GH_TOKEN=pat-fixture \
    MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 MC_MAIN_RED_DETECT=0 \
    MC_REHYDRATE=0 LAND_FIRE=0 PR_SNAPSHOT=0 MC_TICK_SECS=0 FLEET_CONF="$KH/fleet.conf" MC_ONLY_PR="$KSLUG#31" "$@" \
    bash "$KH/bin/merge-conductor.sh" >/dev/null 2>"$KT/tick.err" ); }
# A machine keyed tick, as bin/merge-conductor-pr.sh starts it.
mtick() { : > "$KT/def.txt"; ktick MC_FANIN_SOLO_RUN=1 MC_ON_MACHINE=1 MC_PR_DEFERRED_FILE="$KT/def.txt"; }
kreset() {
  scratch_rm "$KH/state/merge-conductor"
  mkdir -p "$KH/state/merge-conductor/prequeue"
  printf 'green %s 1 -\n' "$NOW" > "$KH/state/merge-conductor/prequeue/example-org_mgfy-os_31_${KHEAD}_${KMAIN}"
  : > "$KH/logs/merge-conductor.log"; : > "$KT/calls.txt"
  rm -f "$KT/cmds.txt" "$KT/merges.txt" "$KT/closes.txt" "$KT/alerts.txt" "$KT/ledger.json" "$KT/def.txt"
}
KLOG="$KH/logs/merge-conductor.log"
PRS="$KH/state/merge-conductor/pr-state.tsv"
klog() { tail -8 "$KLOG" 2>/dev/null; }
rowstate() { awk -F'\t' -v k="$KSLUG#$1" '$1 == k { r = $2 } END { print r }' "$PRS" 2>/dev/null; }
ledger() { jq -nc --arg v "$1" --arg h "$KHEAD" '{verdict:$v, tier:"2", provenance:"-", merge_sha:"-", job_id:"job-31", reviewed_sha:$h, artifacts:[]}' > "$KT/ledger.json"; }
nolanding() { # nolanding <case> — no enqueue, no label or comment, no merge
  ! grep -q "$KSLUG#31 enqueued in the" "$KLOG" && ok "$1 no enqueue line" || bad "$1 enqueued: $(klog)"
  [ ! -s "$KT/cmds.txt" ] && ok "$1 no Mergify label or comment" || bad "$1 writes: $(cat "$KT/cmds.txt")"
  [ ! -s "$KT/merges.txt" ] && ok "$1 no merge call" || bad "$1 merges: $(cat "$KT/merges.txt")"
  [ "$(rowstate 31)" != QUEUED ] && ok "$1 #31 is not QUEUED ($(rowstate 31))" || bad "$1 #31 is QUEUED"
}

# ============================================================================
echo "L1: control — the hub enqueues the READY PR"
kreset
ktick
grep -q "$KSLUG#31 enqueued in the mergify merge queue at ${KHEAD:0:8}" "$KLOG" && ok "L1 the hub enqueues #31" \
  || bad "L1 not enqueued: $(klog) $(tail -3 "$KT/tick.err")"

# ============================================================================
echo "L2: control — ledger APPROVE + record BLOCK on the hub is a contradiction park"
kreset
ledger APPROVE
printf 'findings\nTIER: 2\nVERDICT: BLOCK\n' > "$REC/review.md"
ktick
grep -q "$KSLUG#31 .*-> BLOCKED_HUMAN .*verdict-contradiction" "$KLOG" && ok "L2 the hub parks #31 on the contradiction" \
  || bad "L2 no park: $(klog)"
nolanding L2

# ============================================================================
echo "L3: the same ledger APPROVE on a machine with no builds/ record"
kreset
ledger APPROVE
mv "$KH/builds" "$KH/builds.hub"; mkdir -p "$KH/builds"   # the lane-run image has no builds/
mtick
nolanding L3
[ "$(sort -u "$KT/def.txt" | tr '\n' ' ')" = "land " ] && ok "L3 the deferred file says land" \
  || bad "L3 words: '$(tr '\n' ' ' < "$KT/def.txt")'; log: $(klog)"
grep -q "$KSLUG#31 READY at ${KHEAD:0:8} on a lane-run machine" "$KLOG" && ok "L3 one machine line is logged" || bad "L3 log: $(klog)"
scratch_rm "$KH/builds"; mv "$KH/builds.hub" "$KH/builds"
printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"

# ============================================================================
echo "L4: another PR's queue landing is settled by the hub, never by a machine"
q40() { mkdir -p "$KH/state/merge-conductor"
  printf '%s#40\tQUEUED\t%s\t%s\t%s\t-\tenqueued\t%s/40\n' "$KSLUG" "$NOW" "$H40" "$H40" "$KU" >> "$PRS"; }
kreset; q40
mtick
! grep -q "MERGED $KSLUG#40" "$KLOG" && ok "L4 the machine logs no MERGED line for #40" || bad "L4 machine settled: $(grep '#40' "$KLOG")"
[ "$(rowstate 40)" = QUEUED ] && ok "L4 #40's row is still QUEUED" || bad "L4 #40 row: $(rowstate 40)"
! grep -rqs "deployreq $KSLUG#40" "$KH/state/merge-conductor" && ok "L4 no deployreq line" \
  || bad "L4 deployreq: $(grep -rs deployreq "$KH/state/merge-conductor")"
[ ! -s "$KT/closes.txt" ] && ok "L4 no issue close" || bad "L4 closes: $(cat "$KT/closes.txt")"
[ ! -s "$KT/alerts.txt" ] && ok "L4 no alert" || bad "L4 alerts: $(cat "$KT/alerts.txt")"
! grep -qE '^(settle|dv)$' "$KT/def.txt" && ok "L4 no settle or dv word for #31" || bad "L4 words: $(tr '\n' ' ' < "$KT/def.txt")"
ktick
grep -q "MERGED $KSLUG#40 by conductor" "$KLOG" && ok "L4 the hub's next keyed tick settles #40" || bad "L4 hub: $(grep '#40' "$KLOG" | tail -3)"
[ "$(rowstate 40)" = MERGED ] && ok "L4 #40's row is MERGED on the hub" || bad "L4 hub row: $(rowstate 40)"

echo "conductor-machine-lands-nothing.bh-6495: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
