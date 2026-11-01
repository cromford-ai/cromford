#!/bin/bash
# tests/mc-replay-1026.bh-8417-test.sh — BH-8417: the 2026-10-26 facts,
# replayed through the WHOLE bin/merge-conductor.sh (the production entry
# point) in a scratch tree, with the two fragments
# bin/merge-conductor.d/bh-8417-head-clock.sh and bh-8417-repo-truth.sh.
#
# The facts (GitHub REST vs logs/ALERTS.log, 07:2xZ):
#   #7750  the row has waited in one state since 2026-10-21T20:34Z (6408m);
#          its head was committed 898m ago; its Harness CI run started 895m
#          ago and is still in_progress.
#   #7646  the row is QUEUED (our merge-queue label, sticky since the row was
#          QUEUED last tick); Mergify's merge-queue/status does not list it;
#          CI green.
#
#   R1  #7750 pages `STUCK: 89xm` (within 10 min of 898m), not 6408m
#   R2  the #7750 page carries `CI run <id> hung` and the `github:` facts
#   R3  one cancel POST for the hung run
#   R4  #7646 pages `not in Mergify queue`, and exactly ONE @mergifyio requeue
#   R5  the #7646 row carries the DISAGREES line in the log
#   R6  a second tick: no second requeue, no second cancel, no second page
#   R7  the read budget: on a tick where no arm acts, the GitHub GETs are the
#       same list with the fragments as without them; on the acting tick the
#       actions/runs read is still one per PR
#   R8  without the fragments (the code as on main) R1/R2/R4 do not hold
#
# 0 network calls: the fake gh and curl are first on PATH.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/mc-replay-1026.bh-8417-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: mc-replay-1026: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
unset GH_TOKEN GITHUB_TOKEN GH_TOKEN_INSTALLATION_ID MC_CI_HUNG_AFTER_S MC_QUEUE_ABSENT_AFTER_S MC_QUEUE_STATUS_STALE_S
for f in bin/merge-conductor.d/bh-8417-head-clock.sh bin/merge-conductor.d/bh-8417-repo-truth.sh; do
  [ -r "$DIR/$f" ] || { echo "FAIL: mc-replay-1026: $f is missing"; exit 1; }
done

# The conductor reads the wall clock (mc_now has no seam), so the facts are
# laid out relative to one NOW taken here, with the 10-26 ages.
NOW=$(date -u +%s) # determinism: ok the whole tick reads the wall clock; every fixture time is NOW minus a 10-26 age
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
SLUG=example-org/cromford
H50=fe37f152fe37f152fe37f152fe37f152fe37f152
H46=c0194621c0194621c0194621c0194621c0194621
U="https://github.com/$SLUG/pull"

# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
# shellcheck source=tests/lib/verdict-fixture.sh
. "$DIR/tests/lib/verdict-fixture.sh" || exit 1
# shellcheck source=tests/lib/gh-list-bridge.sh
. "$DIR/tests/lib/gh-list-bridge.sh" || exit 1
vpf_export || exit 1
C="$T/w"; CH="$C/h"; FX="$C/fx"
fx_mc_harness "$DIR" "$C" || exit 1
fx_conductor_tick "$DIR" "$C" || exit 1
( cd "$DIR" && for s in bin/lib/autoenqueue.sh bin/lib/mc-hold-comment.sh bin/lib/gh-repo-token.sh; do scratch_install_closure "$s" "$CH" >/dev/null || exit 1; done ) || exit 1
FRAGS=(bin/merge-conductor.d/bh-8417-head-clock.sh bin/merge-conductor.d/bh-8417-repo-truth.sh)
frags_on()  { ( cd "$DIR" && for f in "${FRAGS[@]}"; do scratch_install_closure "$f" "$CH" >/dev/null || exit 1; done ) || exit 1; }
frags_off() { rm -f "$CH"/bin/merge-conductor.d/bh-8417-*.sh; }
cat > "$CH/bin/lib/ticket-ownership.sh" <<'EOF2'
to_lane_hold() { return 1; }
to_lane_lead_fence() { TO_LEAD_CLEARED=0; return 1; }
EOF2
printf 'pdg_hold() { return 1; }\n' > "$CH/bin/lib/pr-dep-gate.sh"
printf 'cromford %s - - 2 box-m\n' "$SLUG" > "$CH/fleet.conf"
: > "$CH/env/global.env"
for s in agent-call beat deploy-request pre-arm-guards codegraph-ensure; do printf '#!/bin/bash\nexit 0\n' > "$CH/bin/$s.sh"; chmod +x "$CH/bin/$s.sh"; done
YML=$(printf 'queue_rules:\n  - name: default\n    merge_method: squash\n' | base64 | tr -d '\n')
mkdir -p "$C/fakebin"
# The fake curl: the jobs worker (a standing lead verdict; every write 200).
cat > "$C/fakebin/curl" <<EOF
#!/bin/bash
out=""; w=""; M=GET; URL=""
while [ \$# -gt 0 ]; do case "\$1" in
  -o) out="\$2"; shift 2 ;; -w) w="\$2"; shift 2 ;; -X) M="\$2"; shift 2 ;;
  -m|-H|--connect-timeout|--data-binary|-d|--max-time) shift 2 ;;
  -*) shift ;; *) URL="\$1"; shift ;;
esac; done
emit() {
  if [ -n "\$out" ]; then printf '%s' "\$2" > "\$out"; else printf '%s' "\$2"; fi
  case "\$w" in '') ;; \$'\n'*) printf '\n%s' "\$1" ;; *) printf '%s' "\$1" ;; esac
}
case "\$M \$URL" in
  "GET "*/api/verdicts\?*) emit 200 '{"standing":{"verdict":"MERGE","source":"lead","id":7001,"created_at":"2026-10-22T18:00:00Z","report_url":"-","reviewer":"lead"}}' ;;
  "PUT "*|"POST "*) emit 200 '{"ok":true}' ;;
  *) emit 404 '{"error":"not found"}' ;;
esac
exit 0
EOF
chmod +x "$C/fakebin/curl"
# runs50 / runs46 — the actions/runs bodies, in GitHub's shape.
run_body() { # run_body <id> <status> <conclusion> <started-epoch> <head> <head-commit-epoch>
  jq -nc --argjson id "$1" --arg s "$2" --arg c "$3" --arg t "$(iso "$4")" --arg h "$5" --arg hc "$(iso "$6")" \
    '{total_count: 1, workflow_runs: [{id: $id, name: "Harness CI", status: $s, conclusion: (if $c == "" then null else $c end),
      run_started_at: $t, created_at: $t, run_attempt: 1, head_sha: $h, head_commit: {id: $h, timestamp: $hc}}]}'; }
cat > "$C/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$FX/calls.txt"
case "\$*" in
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"actions/runs/"*"/cancel"*) printf '%s\n' "\$*" >> "$FX/cancels.txt"; restpr --raw 202 '{}' ;;
  *"run rerun"*|*"actions/runs/"*"/rerun"*) printf '%s\n' "\$*" >> "$FX/reruns.txt"; restpr --raw 201 '{}' ;;
  *"actions/runs?head_sha=$H50"*) restpr --raw 200 "\$(cat "$FX/runs50.json")" ;;
  *"actions/runs?head_sha=$H46"*) restpr --raw 200 "\$(cat "$FX/runs46.json")" ;;
  *"api -i -X GET repos/$SLUG/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/contents/.mergify.yml"*) restpr --raw 200 "{\"content\":\"$YML\"}" ;;
  *"api -i -X GET repos/"*"/commits/"*"/check-runs"*) restpr --raw 200 '{"total_count":0,"check_runs":[]}' ;;
  *"issues/7646/comments -f body=@mergifyio"*) printf '%s\n' "\$*" >> "$FX/queue-posts.txt"; restpr --raw 201 '{"id":901}' ;;
  *"issues/"*"/labels"*) printf '%s\n' "\$*" >> "$FX/label-writes.txt"; restpr --raw 200 '[]' ;;
  *"pr merge"*) printf '%s\n' "\$*" >> "$FX/merges.txt"; exit 0 ;;
  *"api -i -X POST repos/"*"/issues/"*"/comments"*) printf '%s\n' "\$*" >> "$FX/comment-posts.txt"; restpr --raw 201 '{"id":1}' ;;
  *"api -i -X POST "*|*"api -X POST "*) printf '%s\n' "\$*" >> "$FX/other-posts.txt"; restpr --raw 201 '{}' ;;
  *"api -i -X GET repos/"*"/issues/"*"/comments"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/issues/"*) restpr --raw 200 '{"state":"open"}' ;;
  *"api -i -X GET repos/"*"/pulls/"*"/files"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/pulls/7750"*) restpr OPEN "$H50" ticket/bh-7700 main "" MERGEABLE BLOCKED operator "" "" ;;
  *"api -i -X GET repos/$SLUG/pulls/7646"*) restpr OPEN "$H46" ticket/bh-7600 main "merge-queue,hotfix" MERGEABLE CLEAN operator "" "" ;;
  *"api -i -X GET repos/"*"/pulls -f state="*) restpr --raw 200 '[]' ;;
  *"api repos/$SLUG -q .id"*) echo 1 ;;
  *"pr list -R $SLUG --state open"*) cat "$C/list.json" ;;
  *"pr list"*"--state closed"*) : ;;
esac
exit 0
EOF
chmod +x "$C/fakebin/gh"
cat > "$C/list.json" <<J
[{"number":7750,"url":"$U/7750","headRefOid":"$H50","headRefName":"ticket/bh-7700","baseRefName":"main","isDraft":false,"mergeStateStatus":"BLOCKED","mergeable":"MERGEABLE","state":"OPEN","isInMergeQueue":false,"labels":[]},
 {"number":7646,"url":"$U/7646","headRefOid":"$H46","headRefName":"ticket/bh-7600","baseRefName":"main","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","isInMergeQueue":false,"labels":[{"name":"merge-queue"},{"name":"hotfix"}]}]
J
printf '#!/bin/bash\nexit 0\n' > "$C/fakebin/flock"; chmod +x "$C/fakebin/flock"
touch "$CH/flags/merge-conductor-actions" "$CH/flags/merge-conductor-merge"
CLOG="$CH/logs/merge-conductor.log"
ALERTS="$CH/logs/ALERTS.log"
RC50="$CH/builds/pool-cromford-BH-7700-202610250001"; RC46="$CH/builds/pool-cromford-BH-7600-202610220001"
fresh() {
  scratch_rm "$CH/state"; scratch_rm "$FX"; mkdir -p "$CH/state/merge-conductor" "$FX"
  : > "$CLOG"; : > "$ALERTS"; : > "$FX/calls.txt"
  run_body 18786401 in_progress "" "$((NOW - 895*60 - 13))" "$H50" "$((NOW - 898*60))" > "$FX/runs50.json"
  run_body 18700001 completed success "$((NOW - 3*86400))" "$H46" "$((NOW - 3*86400 - 300))" > "$FX/runs46.json"
  mkdir -p "$RC50" "$RC46"
  echo "PR_CREATED $U/7750" > "$RC50/RESULT"; printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$RC50/review.md"; echo "$H50" > "$RC50/reviewed-sha"; : > "$RC50/pipeline.log"
  echo "PR_CREATED $U/7646" > "$RC46/RESULT"; printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$RC46/review.md"; echo "$H46" > "$RC46/reviewed-sha"; : > "$RC46/pipeline.log"
  # The rows the 10-26 ticks left: #7750 in WAIT_CI since 10-21T20:34Z (6408m),
  # #7646 QUEUED since 10-22T18:50Z.
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$SLUG#7750" WAIT_CI "$((NOW - 6408*60))" "$H50" "$H50" - "checks pending" "$U/7750" \
    "$SLUG#7646" QUEUED "$((NOW - 5070*60))" "$H46" "$H46" - "queued" "$U/7646" > "$CH/state/merge-conductor/pr-state.tsv"
  # Mergify's merge-queue/status as bin/merge-queue-reconcile.sh keeps it, read
  # a minute ago: #7646 is in no batch and not waiting.
  mkdir -p "$CH/state/merge-queue-status"
  jq -nc --argjson t "$((NOW - 60))" '{batches: [{status: {code: "running"}, pull_requests: [{number: 7801}]}], waiting_pull_requests: [], fetched_at: $t}' \
    > "$CH/state/merge-queue-status/example-org_cromford.json"
  # The absent clock the earlier 10-26 ticks started (3.5 days of absence).
  mkdir -p "$CH/state/merge-conductor/queue-absent"
  printf '%s %s\n' "$((NOW - 5040*60))" "$H46" > "$CH/state/merge-conductor/queue-absent/example-org_cromford_7646_${H46:0:12}"
}
tick() {
  ( cd "$C" && env PATH="$C/fakebin:$PATH" HARNESS="$CH" HARNESS_ENV_DIR= HARNESS_SECRET=fixture-secret JOBS_URL=http://worker.test JOBS_RETRIES=0 GH_TOKEN=pat-fixture \
    MC_MERGE_BUDGET=0 MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 MC_MAIN_RED_DETECT=0 \
    "$@" bash "$CH/bin/merge-conductor.sh" >/dev/null 2>"$C/tick.err" ) || { echo "tick rc=$? stderr:"; tail -5 "$C/tick.err"; }
}
n() { if [ -f "$1" ]; then grep -c . "$1"; else echo 0; fi; }
gets() { grep -c "api -i -X GET repos/$SLUG/$1" "$FX/calls.txt" 2>/dev/null || true; }
page50() { grep "$SLUG#7750" "$ALERTS" | grep 'STUCK:' | head -1; }
page46() { grep "$SLUG#7646" "$ALERTS" | grep 'not in Mergify queue' | head -1; }

# ---------------------------------------------------------------------------
# R8 first — the code as on main (no fragments): the old clock, no queue truth.
# mc_ci_state and mc_stuck_check are the lib's own, so the base clock is what
# the head-clock half of the fix changes; this run pins the base behaviour.
frags_off; fresh; tick
B_GETS50=$(gets "actions/runs?head_sha=$H50"); B_GETS46=$(gets "actions/runs?head_sha=$H46")
getlist() { grep -- '-X GET ' "$FX/calls.txt" | sort; }
B_LIST=$(getlist)
[ "$(n "$FX/queue-posts.txt")" = 0 ] && [ -z "$(page46)" ] && ok || bad "R8 without the fragments #7646 gets no requeue and no queue page (posts $(n "$FX/queue-posts.txt"))"
[ "$(n "$FX/cancels.txt")" = 0 ] && ok || bad "R8 without the fragments nothing is cancelled"

# R7 — the read budget, on a tick where neither arm acts (both knobs past
# the facts, set in the env, which lane_knob does not clamp): the fragments
# add no GitHub GET at all, per PR or per repo.
frags_on; fresh; tick MC_CI_HUNG_AFTER_S=86400 MC_QUEUE_ABSENT_AFTER_S=999999
[ "$(getlist)" = "$B_LIST" ] && ok || bad "R7 the same GETs as the code on main: $(diff <(printf '%s\n' "$B_LIST") <(getlist) | head -6)"
grep -q "$SLUG#7750 WAIT_CI github: " "$CLOG" && ok || bad "R7 the fragments did run on that tick"

# ---------------------------------------------------------------------------
fresh; tick
P50=$(page50)
[[ "$P50" =~ STUCK:\ (89[0-9]|90[0-8])m\ in\ one\ state ]] && ok || bad "R1 #7750 pages ~898m, from its head commit (page: ${P50:-none}; log: $(grep '#7750' "$CLOG" | tail -4))"
[[ "$P50" != *"STUCK: 640"* ]] && ok || bad "R1 not the old-state clock 6408m (page: $P50)"
[[ "$P50" == *"CI run 18786401 hung 895m"* ]] && ok || bad "R2 the page names the hung run (page: $P50)"
[[ "$P50" == *"github: open mergeState=BLOCKED head=fe37f152@"*" as of "* ]] && ok || bad "R2 the page carries the github facts (page: $P50)"
[ "$(n "$FX/cancels.txt")" = 1 ] && grep -q "actions/runs/18786401/cancel" "$FX/cancels.txt" && ok || bad "R3 one cancel POST for run 18786401 ($(cat "$FX/cancels.txt" 2>/dev/null))"
P46=$(page46)
[[ "$P46" == *"not in Mergify queue 5040m (label merge-queue present, Mergify status "* ]] && ok || bad "R4 #7646 pages not in Mergify queue (page: ${P46:-none}; log: $(grep '#7646' "$CLOG" | tail -6))"
[ "$(n "$FX/queue-posts.txt")" = 1 ] && grep -q "@mergifyio requeue" "$FX/queue-posts.txt" && ok || bad "R4 exactly one @mergifyio requeue ($(cat "$FX/queue-posts.txt" 2>/dev/null))"
grep -q "$SLUG#7646 ROW DISAGREES WITH GITHUB: queue" "$CLOG" && ok || bad "R5 the DISAGREES line"
grep -q "$SLUG#7750 WAIT_CI github: open mergeState=BLOCKED head=fe37f152@" "$CLOG" && ok || bad "R5 the WAIT_CI log line carries the github facts"
# R7b — and on the acting tick, still one actions/runs read per PR.
[ "$(gets "actions/runs?head_sha=$H50")" = "$B_GETS50" ] && [ "$(gets "actions/runs?head_sha=$H46")" = "$B_GETS46" ] && ok \
  || bad "R7b no new actions/runs read (#7750 $(gets "actions/runs?head_sha=$H50") vs $B_GETS50, #7646 $(gets "actions/runs?head_sha=$H46") vs $B_GETS46)"
# R6 — the second tick.
P1=$(grep -c . "$ALERTS"); tick
[ "$(n "$FX/queue-posts.txt")" = 1 ] && [ "$(n "$FX/cancels.txt")" = 1 ] && ok || bad "R6 tick 2: no second requeue or cancel ($(n "$FX/queue-posts.txt")/$(n "$FX/cancels.txt"))"
[ "$(grep -c 'not in Mergify queue' "$ALERTS")" = 1 ] && [ "$(grep -c "$SLUG#7750.*STUCK:" "$ALERTS")" = 1 ] && ok || bad "R6 tick 2: no second page (alerts $P1 -> $(grep -c . "$ALERTS"))"

echo "mc-replay-1026.bh-8417: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
