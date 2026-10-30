#!/bin/bash
# tests/mc-lifecycle-tick.bh-8735-test.sh — BH-8735 through the production
# entry point: one real bin/merge-conductor.sh tick writes the ticket phase the
# conductor owns, through the lifecycle API of #8731.
#
# The scaffold is tests/conductor-machine-lands-nothing.bh-6495-test.sh's K1
# fixture (one READY PR #31 on a Mergify repo, green checks, a green
# lead-verdict status, a green pre-queue entry), plus QUEUED rows for the settle
# pass as tests/mc-eject-cause.bh-6161-test.sh builds them. The fragment
# bin/merge-conductor.d/bh-8735-lifecycle.sh is installed in the scratch
# harness, and bin/lib/jobs/lifecycle.sh there is a stub that records every
# lifecycle_transition call.
#
#   K1  a READY approved PR is enqueued: exactly one in_queue call (actor
#       conductor, key MG-31, pr 31)
#   K2  the enqueue gets no Mergify witness (rc 3): no call
#   K3  a QUEUED row whose Mergify queue check failed: one ejected call in the
#       same tick; the reason names the failing check
#   K4  the `merging` arm and a first-sight `nowitness`: no call
#   K5  a QUEUED row GitHub reports MERGED, with a merged pr_record: one merged
#       call
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/mc-lifecycle-tick.bh-8735-test.sh
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
mkdir -p "$KH/bin/lib/jobs" "$KH/logs" "$KH/state" "$KH/flags" "$KH/locks" "$KH/builds" "$KH/env" "$KH/tmp" "$KB" "$KT/ck" "$KT/cm"
scratch_install_closure bin/merge-conductor.sh "$KH" >/dev/null || { echo "setup: closure failed"; exit 1; }
cp "$DIR/bin/fleet-conf.sh" "$KH/bin/fleet-conf.sh"
mkdir -p "$KH/catalog"; cp "$DIR/catalog/lead-protected-paths.seed.tsv" "$KH/catalog/"
scratch_install_closure bin/jobs-client.sh "$KH" >/dev/null || { echo "setup: closure jobs failed"; exit 1; }
scratch_install_closure bin/lib/mc-eject-cause.sh "$KH" >/dev/null || { echo "setup: closure eject-cause failed"; exit 1; }
# The unit under test: the fragment (the driver globs bin/merge-conductor.d/).
[ -f "$DIR/bin/merge-conductor.d/bh-8735-lifecycle.sh" ] \
  && { scratch_install_closure bin/merge-conductor.d/bh-8735-lifecycle.sh "$KH" >/dev/null || { echo "setup: closure fragment failed"; exit 1; }; }
for s in agent-call beat deploy-request pre-arm-guards codegraph-ensure; do printf '#!/bin/bash\nexit 0\n' > "$KH/bin/$s.sh"; done
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts.txt"\nexit 0\n' "$KT" > "$KH/bin/lane-alert.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts.txt"\nexit 0\n' "$KT" > "$KH/bin/alert-line.sh"
chmod +x "$KH/bin/"*.sh
# #8731's API, as a stub that records each call (one tab-separated line).
cat > "$KH/bin/lib/jobs/lifecycle.sh" <<EOF
lifecycle_transition() { local IFS=\$'\\t'; printf '%s\\n' "\$*" >> "$KT/lc.calls"; printf '{"ok":true}'; return 0; }
EOF
cp "$DIR/tests/lib/rest-emit.sh" "$KB/restpr"; chmod +x "$KB/restpr"
# shellcheck source=tests/lib/verdict-fixture.sh
. "$DIR/tests/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
KSLUG=example-org/mgfy-os; KHEAD=$(printf 'a%.0s' {1..40}); KMAIN=$(printf 'd%.0s' {1..40}); KU="https://github.com/$KSLUG/pull"
H41=$(printf '4%.0s' {1..40}); H42=$(printf 'b%.0s' {1..40}); H43=$(printf 'c%.0s' {1..40}); H44=$(printf 'e%.0s' {1..40}); M44=$(printf 'f%.0s' {1..40})
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
# The check-runs answer is per head: $KT/ck/<sha> holds a mode word.
#   running (default)  green CI + Mergify's queue check in progress (the witness)
#   none               green CI only: Mergify acknowledged nothing
#   failed             Mergify's queue check failed
#   merging            Mergify's queue check titled merged, not merged on GitHub
# $KT/cm/<num>.json is that PR's comment list.
cat > "$KB/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$KT/calls.txt"
shopt -s nocasematch   # pr_record_get asks GitHub for the repo in lower case
GHA='{"name":"Build + Unit tests","status":"completed","conclusion":"success","started_at":"2026-10-11T10:00:00Z","app":{"slug":"github-actions"}}'
case "\$*" in
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"auth token"*) echo fixture-token ;;
  *"api -i -X GET repos/$KSLUG/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$KSLUG/contents/.mergify.yml"*) restpr --raw 200 '{"content":"$MGFY_YML"}' ;;
  *"api -i -X GET repos/$KSLUG/commits/main"*|*"api -i -X GET repos/$KSLUG/git/ref/heads/main"*) restpr --raw 200 '{"sha":"$KMAIN","object":{"sha":"$KMAIN"}}' ;;
  *"check-runs?check_name="*) restpr --raw 200 "{\"check_runs\":[\$GHA]}" ;;
  *"api -i -X GET repos/"*"/commits/"*"/check-runs"*)
    SHA=\$(sed -n 's|.*/commits/\([0-9a-f]*\)/check-runs.*|\1|p' <<<"\$*")
    case "\$(cat "$KT/ck/\$SHA" 2>/dev/null || echo running)" in
      none)    restpr --raw 200 "{\"total_count\":1,\"check_runs\":[\$GHA]}" ;;
      failed)  restpr --raw 200 "{\"total_count\":2,\"check_runs\":[\$GHA,{\"name\":\"Mergify Merge Queue\",\"status\":\"completed\",\"conclusion\":\"failure\",\"output\":{\"title\":\"\"},\"app\":{\"slug\":\"mergify\"}}]}" ;;
      merging) restpr --raw 200 "{\"total_count\":2,\"check_runs\":[\$GHA,{\"name\":\"Mergify Merge Queue\",\"status\":\"completed\",\"conclusion\":\"cancelled\",\"output\":{\"title\":\"The pull request has been merged automatically\"},\"app\":{\"slug\":\"mergify\"}}]}" ;;
      *)       restpr --raw 200 "{\"total_count\":2,\"check_runs\":[\$GHA,{\"name\":\"Mergify Merge Queue\",\"status\":\"in_progress\",\"conclusion\":null,\"output\":{\"title\":\"In merge queue\"},\"app\":{\"slug\":\"mergify\"}}]}" ;;
    esac ;;
  *"api -i -X GET repos/"*"/commits/"*"/status"*) restpr --raw 200 '{"state":"success","statuses":[{"context":"lead-verdict","state":"success"}]}' ;;
  *"api -i -X GET repos/"*"/commits/"*) restpr --raw 200 '{"commit":{"committer":{"date":"2026-10-05T20:00:00Z"}}}' ;;
  *"api -i -X POST repos/"*"/statuses/"*) printf '%s\n' "\$*" >> "$KT/statuses.txt"; restpr --raw 201 '{"id":1}' ;;
  *"api -X POST repos/"*"/issues/"*"/comments"*|*"api -X POST repos/"*"/issues/"*"/labels"*) printf '%s\n' "\$*" >> "$KT/cmds.txt" ;;
  *"api -i -X POST repos/"*"/issues/"*"/comments"*) printf '%s\n' "\$*" >> "$KT/cmds.txt"; restpr --raw 201 '{"id":1}' ;;
  *"api -X DELETE repos/"*"/labels/"*) printf '%s\n' "\$*" >> "$KT/cmds.txt" ;;
  *"pr merge"*|*"/pulls/"*"/merge"*) printf '%s\n' "\$*" >> "$KT/merges.txt"; exit 1 ;;
  *"issue close"*|*"-X PATCH repos/"*"/issues/"*) printf '%s\n' "\$*" >> "$KT/closes.txt" ;;
  *"api -i -X GET repos/$KSLUG/issues/"*"/comments"*)
    N=\$(sed -n 's|.*/issues/\([0-9]*\)/comments.*|\1|p' <<<"\$*")
    restpr --raw 200 "\$(cat "$KT/cm/\$N.json" 2>/dev/null || echo '[]')" ;;
  *"api -i -X GET repos/"*"/issues/"*) restpr --raw 200 '{"state":"open"}' ;;
  *"api -i -X GET repos/$KSLUG/pulls/31"*"v3.diff"*) restpr --diff ;;
  *"api --paginate repos/$KSLUG/issues/"*"/comments"*)
    N=\$(sed -n 's|.*/issues/\([0-9]*\)/comments.*|\1|p' <<<"\$*")
    cat "$KT/cm/\$N.json" 2>/dev/null || echo '[]' ;;
  *"api --paginate repos/"*"/comments"*|*"api --paginate repos/"*"/reviews"*) echo '[]' ;;
  *"api repos/"*"/comments --paginate"*) : ;;
  *"api repos/$KSLUG/issues/31"*) printf '{"number":31,"state":"open","labels":[],"body":""}\n' ;;
  *"api -i -X GET repos/"*"/pulls/"*"/files"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$KSLUG/pulls/31"*) restpr OPEN "$KHEAD" ticket/mg-31 main "" MERGEABLE CLEAN operator "" "" ;;
  *"api -i -X GET repos/$KSLUG/pulls/41"*) restpr OPEN "$H41" ticket/mg-41 main merge-queue MERGEABLE CLEAN operator "" "" ;;
  *"api -i -X GET repos/$KSLUG/pulls/42"*) restpr OPEN "$H42" ticket/mg-42 main "" MERGEABLE CLEAN operator "" "" ;;
  *"api -i -X GET repos/$KSLUG/pulls/43"*) restpr OPEN "$H43" ticket/mg-43 main "" MERGEABLE CLEAN operator "" "" ;;
  *"api -i -X GET repos/$KSLUG/pulls/44"*) restpr MERGED "$H44" ticket/mg-44 main "" MERGEABLE CLEAN operator "$M44" "" ;;
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
# The jobs worker: every route 404s (no pr_record, no verdict row), except the
# lead protected paths and the reads the K1 fixture needs.
cat > "$KB/curl" <<EOF
#!/bin/bash
URL="\${!#}"
printf '%s\n' "\$URL" >> "$KT/curl.txt"
case "\$URL" in
  */api/lead-protected-paths*) "$KB/lpp-answer" GET "\$URL"; exit 0 ;;
  */api/verdicts\?*) printf '{"standing":null}\n200\n' ;;
  */api/settings/lead_pr_authors) printf '{"setting":{"key":"lead_pr_authors","value":"lead-fixture-bot"}}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$KB/curl"
. "$DIR/tests/lib/lpp-stub.sh" || exit 1
lpp_set "$KT/lpp.json" "$KSLUG"
lpp_install "$KB" "$KT/lpp.json" "$KT/lpp-down"
touch "$KH/flags/merge-conductor-actions" "$KH/flags/merge-conductor-merge"
ktick() {
  ( cd "$KT" && env PATH="$KB:$PATH" HARNESS="$KH" HARNESS_SECRET=x JOBS_URL=http://worker.test GH_TOKEN=pat-fixture \
    MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 MC_MAIN_RED_DETECT=0 \
    MC_REHYDRATE=0 LAND_FIRE=0 PR_SNAPSHOT=0 MC_TICK_SECS=0 FLEET_CONF="$KH/fleet.conf" MC_ONLY_PR="$KSLUG#31" "$@" \
    bash "$KH/bin/merge-conductor.sh" >/dev/null 2>"$KT/tick.err" ); }
KLOG="$KH/logs/merge-conductor.log"
PRS="$KH/state/merge-conductor/pr-state.tsv"
kreset() {
  scratch_rm "$KH/state/merge-conductor"
  mkdir -p "$KH/state/merge-conductor/prequeue"
  printf 'green %s 1 -\n' "$NOW" > "$KH/state/merge-conductor/prequeue/example-org_mgfy-os_31_${KHEAD}_${KMAIN}"
  : > "$KLOG"; : > "$KT/calls.txt"; : > "$KT/lc.calls"
  rm -f "$KT/cmds.txt" "$KT/merges.txt" "$KT/closes.txt" "$KT/alerts.txt" "$KT/ck/"* "$KT/cm/"*
}
klog() { tail -8 "$KLOG" 2>/dev/null; }
lcn() { grep -c . "$KT/lc.calls" | tr -d ' '; }
lcof() { awk -F'\t' -v k="$1" -v p="$2" '$2 == k && $3 == p' "$KT/lc.calls"; }
# queued <num> <head> — a QUEUED row for <num>, as the enqueue tick left it.
queued() { mkdir -p "$KH/state/merge-conductor"
  printf '%s#%s\tQUEUED\t%s\t%s\t%s\t-\tenqueued at %s\t%s/%s\n' "$KSLUG" "$1" "$((NOW-300))" "$2" "$2" "${2:0:8}" "$KU" "$1" >> "$PRS"; }
# A Mergify dequeue comment naming the failing check (cut from #4049, as in
# tests/mc-eject-cause.bh-6161-test.sh).
dqbody() {
  printf '%s\n' '<!---' 'DO NOT EDIT' '-*- Mergify Payload -*-' \
    '{"version": 1, "state": "dequeued", "queue_rule_name": "default"}' '-*- Mergify Payload End -*-' '-->' '' \
    '# Merge Queue Status' '' \
    '- ✅ **Entered queue** — `2026-10-05 22:40 UTC` · Rule: `default`' \
    '- ❌ **Checks failed** — `2026-10-05 23:10 UTC` · on draft #4801'
  printf -- '- 🚫 **Left the queue** — `2026-10-05 23:18 UTC` · at `%s`\n' "$1"
  printf '\n## Reason\n\n%s\n' 'The merge conditions cannot be satisfied due to failing checks

Failing checks:
- ❌ [`Pure-logic gate fixtures`](https://github.com/example-org/cromford/actions/runs/37180690428/job/111374696421)'
  printf '%s\n' '' '## Hint' '' 'You may have to fix your CI before adding the pull request to the queue again.'
}

# ============================================================================
echo "K1: a READY PR is enqueued -> one in_queue call"
kreset
ktick
grep -q "$KSLUG#31 enqueued in the mergify merge queue at ${KHEAD:0:8}" "$KLOG" && ok "K1 the fixture enqueues #31" \
  || bad "K1 not enqueued: $(klog) $(tail -3 "$KT/tick.err")"
[ "$(lcn)" = 1 ] && ok "K1 exactly one lifecycle call" || bad "K1 calls: $(cat "$KT/lc.calls")"
[ "$(lcof MG-31 in_queue | cut -f1,4,6)" = "$(printf 'mgfy\tconductor\t31')" ] && ok "K1 in_queue for MG-31: project mgfy, actor conductor, pr 31" \
  || bad "K1 the call: $(cat "$KT/lc.calls")"
grep -q "LIFECYCLE $KSLUG#31 MG-31 -> in_queue" "$KLOG" && ok "K1 one LIFECYCLE line" || bad "K1 log: $(grep LIFECYCLE "$KLOG")"

# ============================================================================
echo "K2: the enqueue has no Mergify witness (rc 3) -> no call"
kreset
echo none > "$KT/ck/$KHEAD"
ktick
grep -q "$KSLUG#31 enqueued in the" "$KLOG" && bad "K2 the fixture must not enqueue: $(klog)" || ok "K2 not enqueued"
grep -qi "acknowledged nothing" "$KLOG" && ok "K2 the rc 3 arm ran" || bad "K2 no rc 3 line: $(klog)"
[ "$(lcn)" = 0 ] && ok "K2 no lifecycle call" || bad "K2 calls: $(cat "$KT/lc.calls")"

# ============================================================================
echo "K3: a QUEUED row whose Mergify queue check failed -> one ejected call this tick"
kreset
queued 41 "$H41"; echo failed > "$KT/ck/$H41"
dqbody "$H41" | jq -Rsc '[{id: 4101, user: {login: "mergify[bot]", type: "Bot"}, created_at: "2026-10-05T23:18:00Z", updated_at: "2026-10-05T23:18:00Z", body: .}]' > "$KT/cm/41.json"
ktick
grep -q "$KSLUG#41 ejected from the merge queue on ${H41:0:8}" "$KLOG" && ok "K3 the settle pass ejects #41" \
  || bad "K3 no ejection: $(grep '#41' "$KLOG" | tail -5) $(tail -3 "$KT/tick.err")"
[ "$(lcof MG-41 ejected | grep -c .)" = 1 ] && ok "K3 exactly one ejected call for MG-41" || bad "K3 calls: $(cat "$KT/lc.calls")"
R41=$(lcof MG-41 ejected | cut -f5)
case "$R41" in
  "mergify dequeue: "*"checks: "*"Pure-logic gate fixtures"*) ok "K3 the reason: the dequeue and the failing check" ;;
  *) bad "K3 the reason: '$R41'" ;;
esac
[ "$(lcof MG-41 ejected | cut -f4,6)" = "$(printf 'conductor\t41')" ] && ok "K3 actor conductor, pr 41" || bad "K3 the call: $(lcof MG-41 ejected)"

# ============================================================================
echo "K4: merging and a first-sight nowitness -> no call"
kreset
queued 42 "$H42"; echo merging > "$KT/ck/$H42"
queued 43 "$H43"; echo none > "$KT/ck/$H43"
ktick
grep -q "$KSLUG#42 still QUEUED: Mergify's check says merged" "$KLOG" && ok "K4 #42 takes the merging arm" || bad "K4 #42: $(grep '#42' "$KLOG" | tail -3)"
grep -q "$KSLUG#43 left the merge queue on ${H43:0:8} with no stated reason" "$KLOG" && ok "K4 #43 takes the first-sight nowitness arm" \
  || bad "K4 #43: $(grep '#43' "$KLOG" | tail -3)"
[ -z "$(awk -F'\t' '$2 == "MG-42" || $2 == "MG-43"' "$KT/lc.calls")" ] && ok "K4 no call for #42 or #43" || bad "K4 calls: $(cat "$KT/lc.calls")"

# ============================================================================
echo "K5: a QUEUED row GitHub reports MERGED -> one merged call"
kreset
queued 44 "$H44"
ktick
grep -q "MERGED $KSLUG#44 by conductor" "$KLOG" && ok "K5 the settle pass settles #44" || bad "K5 #44: $(grep '#44' "$KLOG" | tail -3)"
[ "$(lcof MG-44 merged | grep -c .)" = 1 ] && ok "K5 one merged call for MG-44" \
  || bad "K5 calls: $(cat "$KT/lc.calls") log: $(grep -E 'LIFECYCLE|#44' "$KLOG" | tail -3)"

[ -n "${MCLC_KEEP:-}" ] && cp -r "$KT" "$MCLC_KEEP"
echo "mc-lifecycle-tick (BH-8735): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
