#!/bin/bash
# tests/mc/prequeue-verdict-status.bh-5429-test.sh — BH-5441 (#5429 child 4):
# every pq_gate decision publishes a `prequeue-verdict` commit status, through
# bin/lib/mc-prequeue.d/status.sh. A red is failure, a proceed is success with
# the reason in the description, a hold is nothing. pq_status_ensure (the TTL
# and rebind arms) publishes success only on a head with no status and no red.
#
# Driven, not grepped: K7, K8, K9 and K11 run bin/merge-conductor.sh WHOLE in a
# scratch tree against a stub gh. The verdict fixtures are written with the
# lib's own pq_cache_put. dispatch.sh is NOT installed, so every verdict comes
# from a fixture. The stub writes `statuses <sha> <state> <context> <desc>` for
# each status POST that answered 201 and `enqueue <argv>` for each
# `@mergifyio queue` comment into ONE ordered sink, $T/sink.txt. A status GET
# answers from $T/status-<sha>.json. K10 sources the libs and calls
# pq_status_ensure and mc_vs_ttl_republish directly, against the same stub.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/mc/prequeue-verdict-status.bh-5429-test.sh
set -uo pipefail
. "$(dirname "$0")/../lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/../.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
# shellcheck source=tests/lib/gh-list-bridge.sh
. "$DIR/tests/lib/gh-list-bridge.sh" || exit 1
# shellcheck source=tests/lib/verdict-fixture.sh
. "$DIR/tests/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1

SLUG=example-org/demo-os
K41="$SLUG#41"
H1=$(printf 'a%.0s' $(seq 40))
H2=$(printf 'b%.0s' $(seq 40))
M=$(printf 'c%.0s' $(seq 40))
M_OLD=$(printf 'd%.0s' $(seq 40))
U="https://github.com/$SLUG/pull"
export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib/mc" "$T/h/bin/lib/jobs" "$T/h/bin/lib/mc-prequeue.d" "$T/h/logs" "$T/h/state" "$T/h/flags" \
         "$T/h/locks" "$T/h/builds" "$T/h/env" "$T/h/tmp" "$T/fakebin"
# scratch-closure-allow: pins the conductor's minimal lib set (the 4545/4596 shape); the closure also installs GitHub App auth and dispatch.sh, which move every gh call and every verdict off this fixture's stub
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" \
   "$DIR/bin/lib/gh-rest-list.sh" "$DIR/bin/lib/gh-rest-etag.sh" "$DIR/bin/lib/gh-budget.sh" "$DIR/bin/lib/gh-repo-token.sh" \
   "$DIR/bin/lib/autoenqueue.sh" "$DIR/bin/lib/hold.sh" "$DIR/bin/lib/mc-hold-comment.sh" "$DIR/bin/lib/lane-switch.sh" \
   "$DIR/bin/lib/verdict-status.sh" "$DIR/bin/lib/mc-prequeue.sh" "$T/h/bin/lib/" || exit 1
cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/" || exit 1
cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/" || exit 1
cp "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$T/h/bin/" || exit 1
# The lib under test. Absent on the merge base: the red this opens on.
[ -r "$DIR/bin/lib/mc-prequeue.d/status.sh" ] && cp "$DIR/bin/lib/mc-prequeue.d/status.sh" "$T/h/bin/lib/mc-prequeue.d/"
printf 'to_lane_hold() { return 1; }\nto_lane_lead_fence() { TO_LEAD_CLEARED=0; return 1; }\n' > "$T/h/bin/lib/ticket-ownership.sh"
printf 'demo %s - - 2 box-demo\n' "$SLUG" > "$T/h/fleet.conf"; export FLEET_CONF="$T/h/fleet.conf"
: > "$T/h/env/global.env"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"
for s in agent-call beat deploy-request pre-arm-guards codegraph-ensure; do printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/$s.sh"; chmod +x "$T/h/bin/$s.sh"; done
REC="$T/h/builds/pool-demo-BH-20-202610050001"; mkdir -p "$REC"
MGFY_YML=$(printf 'queue_rules:\n  - name: default\n    merge_method: squash\n' | base64 | tr -d '\n')
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
# The stub. The main-tip read answers {"sha":$M}, or a 500 while $T/tip-down
# exists. A status POST answers 500 while $T/vs-fail exists (recorded in
# $T/vs-500.txt), else 201 and one sink line.
{ printf '#!/bin/bash\nT=%q\nSLUG=%q\nM=%q\nMGFY_YML=%q\n' "$T" "$SLUG" "$M" "$MGFY_YML"; cat <<'SHIM'
case "$*" in
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"api -i -X GET repos/$SLUG/commits/main"|*"api -i -X GET repos/$SLUG/commits/main "*)
    if [ -e "$T/tip-down" ]; then restpr --raw 500 '{"message":"Server Error"}'; else restpr --raw 200 "{\"sha\":\"$M\"}"; fi ;;
  *"api -i -X POST repos/"*"/statuses/"*)
    sha=$(sed -n 's|.*/statuses/\([0-9a-f]*\).*|\1|p' <<<"$*"); st=""; cx=""; ds=""
    prev=""; for a in "$@"; do
      if [ "$prev" = -f ]; then case "$a" in state=*) st="${a#state=}" ;; context=*) cx="${a#context=}" ;; description=*) ds="${a#description=}" ;; esac; fi
      prev="$a"; done
    if [ -e "$T/vs-fail" ]; then printf '%s %s %s\n' "$sha" "$st" "$cx" >> "$T/vs-500.txt"; restpr --raw 500 '{"message":"Server Error"}'
    else printf 'statuses %s %s %s %s\n' "$sha" "$st" "$cx" "$ds" >> "$T/sink.txt"; restpr --raw 201 '{"id":1}'; fi ;;
  *"api -i -X GET repos/"*"/commits/"*"/status"*)
    sha=$(sed -n 's|.*/commits/\([0-9a-f]*\)/status.*|\1|p' <<<"$*")
    if [ -r "$T/status-$sha.json" ]; then restpr --raw 200 "$(cat "$T/status-$sha.json")"
    else restpr --raw 200 '{"state":"pending","statuses":[]}'; fi ;;
  *"api -i -X GET repos/$SLUG/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/contents/.mergify.yml"*) restpr --raw 200 "{\"content\":\"$MGFY_YML\"}" ;;
  *"actions/runs?head_sha="*) restpr --raw 200 '{"workflow_runs":[{"id":1,"name":"CI","status":"completed","conclusion":"success","run_started_at":"2026-10-05T01:00:00Z"}]}' ;;
  *"check-runs?check_name="*) restpr --raw 200 '{"check_runs":[{"name":"Build + Unit tests","status":"completed","conclusion":"success","started_at":"2026-10-05T01:00:00Z"}]}' ;;
  *"api -i -X GET repos/"*"/commits/"*"/check-runs"*) restpr --raw 200 '{"total_count":1,"check_runs":[{"name":"Build + Unit tests","status":"completed","conclusion":"success","started_at":"2026-10-05T01:00:00Z"}]}' ;;
  *"api -i -X POST repos/$SLUG/issues/41/comments -f body=@mergifyio"*) printf 'enqueue %s\n' "$*" >> "$T/sink.txt"; restpr --raw 201 '{"id":901}' ;;
  *"/issues/"*"/labels"*) printf 'label %s\n' "$*" >> "$T/sink.txt" ;;
  *"api -X POST repos/"*"/issues/"*"/comments"*) case "$*" in *mergifyio*) printf 'enqueue %s\n' "$*" >> "$T/sink.txt" ;; esac ;;
  *"api -i -X POST repos/"*"/issues/"*"/comments"*) restpr --raw 201 '{"id":1}' ;;
  *"api -i -X GET repos/"*"/issues/"*"/comments"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/pulls -f state="*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/pulls/41"*"v3.diff"*) restpr --diff ;;
  *"api -i -X GET repos/"*"/pulls/"*"/files"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/pulls/41"*) restpr OPEN "$(cat "$T/head41")" ticket/bh-20 main "" MERGEABLE CLEAN operator "" "Closes #20" ;;
  *"api repos/$SLUG -q .id"*) echo 1 ;;
  *"pr list -R $SLUG --state open"*) cat "$T/list.json" ;;
  *"pr list"*"--state closed"*) : ;;
esac
exit 0
SHIM
} > "$T/fakebin/gh"
chmod +x "$T/fakebin/gh"
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
URL="\${!#}"; M=GET
while [ \$# -gt 0 ]; do case "\$1" in -X) M="\$2"; shift 2 ;; *) shift ;; esac; done
case "\$M \$URL" in
  "PUT "*) printf '{"ok":true}\n200\n' ;;
  "GET "*/api/verdicts\?*) printf '{"standing":null}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"

MCD="$T/h/state/merge-conductor"
MCLOG="$T/h/logs/merge-conductor.log"
ROWS="$MCD/pr-state.tsv"
SINK="$T/sink.txt"
# reset — a fresh harness state with #41 approved and green at H1.
reset() {
  rm -f "$SINK" "$T/tick.err" "$T/tip-down" "$T/vs-fail" "$T/vs-500.txt" "$T"/status-*.json "$T/h/bin/lib/mc-prequeue.d/stub.sh"
  : > "$SINK"
  scratch_rm "$MCD"; scratch_rm "$T/h/state/tier2-autoenqueue.txt"
  rm -f "$T/h/logs/"*.log; mkdir -p "$MCD"; : > "$ROWS"
  echo "$H1" > "$T/head41"
  echo "PR_CREATED $U/41" > "$REC/RESULT"; printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"
  echo "$H1" > "$REC/reviewed-sha"; : > "$REC/pipeline.log"
  cat > "$T/list.json" <<J
[{"number":41,"url":"$U/41","headRefOid":"$H1","headRefName":"ticket/bh-20","baseRefName":"main","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","isInMergeQueue":false,"labels":[]}]
J
  touch "$T/h/flags/merge-conductor-actions" "$T/h/flags/merge-conductor-merge"
}
tick() {
  ( cd "$T" && env PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x JOBS_URL=http://worker.test GH_TOKEN=pat-default \
    MC_MERGE_BUDGET=0 MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 MC_MAIN_RED_DETECT=0 \
    MC_DETACHED_REBASE=0 "$@" bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) || { echo "tick rc=$? stderr:"; tail -5 "$T/tick.err"; }
}
# put <num> <head> <main> <state> [suites] [run_id] — one verdict, through the lib's own writer.
put() {
  ( MC_STATE_DIR="$MCD" P=demo
    . "$T/h/bin/lib/mc-prequeue.sh" || exit 1
    pq_cache_put "$(pq_key "$SLUG" "$1" "$2" "$3")" "$4" 1759626000 "${6:--}" "${5:-}" ) || bad "fixture: pq_cache_put failed for $*"
}
pqpath() { printf '%s/prequeue/%s_%s_%s_%s' "$MCD" "${SLUG//\//_}" "$1" "$2" "$3"; }
# pqs [state] — the prequeue-verdict sink lines (for one state).
pqs() { grep -E "^statuses $H1 ${1:-[a-z]+} prequeue-verdict( |$)" "$SINK" 2>/dev/null; }
npqs() { pqs "${1:-}" | grep -c . ; }
nenq() { grep -c '^enqueue ' "$SINK" 2>/dev/null; }
clog() { grep -F "$K41" "$MCLOG" 2>/dev/null | tail -"${1:-6}"; }
sinkdump() { tr '\n' '|' < "$SINK" | cut -c1-600; }

# ============================================================================
# K7. A cached red naming a suite: ONE failure status, described by its suites.
# ============================================================================
reset; put 41 "$H1" "$M" red tests/a.sh; tick
[ "$(npqs failure)" = 1 ] && ok || bad "K7 one prequeue-verdict failure on the head (sink: $(sinkdump); err: $(tail -3 "$T/tick.err"))"
[ "$(pqs failure)" = "statuses $H1 failure prequeue-verdict suites: tests/a.sh" ] && ok || bad "K7 the description is 'suites: tests/a.sh' (got '$(pqs failure)')"
[ "$(npqs success)" = 0 ] && ok || bad "K7 a red publishes no success (sink: $(sinkdump))"
[ "$(nenq)" = 0 ] && ok || bad "K7 a red is not enqueued (sink: $(sinkdump))"
# A parked red is sticky, so pq_gate is not asked again; with the sticky hand-off
# off it IS asked again (the 4545 E1b shape), and the pqst marker holds.
tick MC_STICKY_HANDOFF=0
grep -q "$K41 PREQUEUE_RED" "$MCLOG" && ok || bad "K7 setup: the row parked prequeue-red (log: $(clog))"
[ "$(npqs failure)" = 1 ] && ok || bad "K7 a re-asked tick re-posts no failure (sink: $(sinkdump))"

# K7a. The .why sidecar, when present, is the description.
reset; put 41 "$H1" "$M" red tests/a.sh; printf 'invariant:x\nmore\n' > "$(pqpath 41 "$H1" "$M").why"; tick
[ "$(pqs failure)" = "statuses $H1 failure prequeue-verdict invariant:x" ] && ok || bad "K7a the .why first line is the description (got '$(pqs failure)')"

# K7b. A refused POST writes no marker, and the next tick POSTs again.
# A parked red is re-asked only with the sticky hand-off off (see K7).
reset; put 41 "$H1" "$M" red tests/a.sh; touch "$T/vs-fail"; tick MC_STICKY_HANDOFF=0
[ "$(grep -c " failure prequeue-verdict" "$T/vs-500.txt" 2>/dev/null)" = 1 ] && ok || bad "K7b the failure POST was asked once (500s: $(cat "$T/vs-500.txt" 2>/dev/null))"
grep -q '^pqst ' "$MCD/attempts.txt" 2>/dev/null && bad "K7b a 500 writes no pqst marker ($(grep '^pqst ' "$MCD/attempts.txt"))" || ok
grep -q "prequeue-verdict=failure NOT published" "$MCLOG" && ok || bad "K7b the refusal is logged (log: $(grep -i prequeue "$MCLOG" | tail -3))"
rm -f "$T/vs-fail"; tick MC_STICKY_HANDOFF=0
[ "$(npqs failure)" = 1 ] && ok || bad "K7b the next tick POSTs the failure (sink: $(sinkdump))"
grep -qxF "pqst $SLUG $H1 failure" "$MCD/attempts.txt" && ok || bad "K7b the landed POST writes its marker ($(cat "$MCD/attempts.txt" 2>/dev/null))"

# ============================================================================
# K8. A green verdict: ONE success, posted BEFORE the enqueue.
# ============================================================================
reset; put 41 "$H1" "$M" green; tick
[ "$(pqs success)" = "statuses $H1 success prequeue-verdict green on main ${M:0:12}" ] && ok || bad "K8 one success 'green on main ${M:0:12}' (got '$(pqs success)'; sink: $(sinkdump); err: $(tail -3 "$T/tick.err"))"
[ "$(nenq)" -ge 1 ] && ok || bad "K8 the head is enqueued (sink: $(sinkdump); log: $(clog))"
s=$(grep -n "^statuses $H1 success prequeue-verdict" "$SINK" | head -1 | cut -d: -f1); e=$(grep -n '^enqueue ' "$SINK" | head -1 | cut -d: -f1)
[ -n "$s" ] && [ -n "$e" ] && [ "$s" -lt "$e" ] && ok || bad "K8 the success comes before the enqueue (status line ${s:-none}, enqueue line ${e:-none})"
# K8b. A second tick on the same head re-posts nothing.
n=$(grep -c '^statuses ' "$SINK"); tick
[ "$(npqs)" = 1 ] && ok || bad "K8b a second tick adds no prequeue-verdict line (sink: $(sinkdump))"
[ "$(grep -c "^statuses $H1 [a-z]* prequeue-verdict" "$SINK")" -le "$n" ] && ok || bad "K8b no status line of this context was added"

# K8c. A red that names no suite proceeds: success, never failure.
reset; put 41 "$H1" "$M" red ""; tick
[ "$(pqs success)" = "statuses $H1 success prequeue-verdict could-not-run (red without suites): enqueued without it" ] && ok \
  || bad "K8c success 'could-not-run (red without suites)' (got '$(pqs)')"
[ "$(npqs failure)" = 0 ] && ok || bad "K8c no failure (sink: $(sinkdump))"

# K8d. The other proceed words carry their own reason.
reset; put 41 "$H1" "$M" no-selection; tick
[ "$(pqs success)" = "statuses $H1 success prequeue-verdict no-selection on main ${M:0:12}" ] && ok || bad "K8d no-selection (got '$(pqs)')"
reset; put 41 "$H1" "$M" could-not-run "" deadline; tick
[ "$(pqs success)" = "statuses $H1 success prequeue-verdict could-not-run (deadline): enqueued without it" ] && ok || bad "K8d could-not-run (got '$(pqs)')"
reset; tick
[ "$(pqs success)" = "statuses $H1 success prequeue-verdict no pre-queue workflow" ] && ok || bad "K8d no entry, no resolver (got '$(pqs)')"

# ============================================================================
# K9. The gate switched off: success "gate off", and the enqueue happens.
# ============================================================================
reset; put 41 "$H1" "$M" red tests/a.sh; tick MC_PREQUEUE_GATE=0 MC_PREQUEUE_FALLBACK=0
[ "$(pqs)" = "statuses $H1 success prequeue-verdict gate off" ] && ok || bad "K9 one success 'gate off' (got '$(pqs)')"
[ "$(nenq)" -ge 1 ] && ok || bad "K9 the head is enqueued (sink: $(sinkdump))"

# ============================================================================
# K11. A hold (main tip unreadable): nothing published, nothing enqueued.
# ============================================================================
reset; touch "$T/tip-down"; put 41 "$H1" "$M" green; tick
[ "$(npqs)" = 0 ] && ok || bad "K11 a hold publishes nothing (sink: $(sinkdump))"
[ "$(nenq)" = 0 ] && ok || bad "K11 a hold enqueues nothing (sink: $(sinkdump))"
# The PR-level stdout contract stays one word (the 4545 suite pins this too).
grep -q "PQ_STATUS_PUBLISHED" "$MCLOG" && bad "K11 no PQ_STATUS_PUBLISHED line on a hold" || ok
# K11b-d. A resolver's rebase (BH-5572: a reused green that conflicts with
# main), defer (a later READY check refuses the head) or hold (a run dispatched
# or still pending) publishes nothing either: none of them enqueues this tick.
for w in rebase defer hold; do
  reset; printf 'pq_resolve() { PQ_WHY=stub; echo %s; }\n' "$w" > "$T/h/bin/lib/mc-prequeue.d/stub.sh"; tick
  [ "$(npqs)" = 0 ] && ok || bad "K11 a resolver $w publishes nothing (sink: $(sinkdump))"
  [ "$(nenq)" = 0 ] && ok || bad "K11 a resolver $w enqueues nothing (sink: $(sinkdump))"
  grep -q "PQ_STATUS_PUBLISHED" "$MCLOG" && bad "K11 no PQ_STATUS_PUBLISHED line on a resolver $w" || ok
done
# The resolver stub is live: the same stub answering proceed publishes (so the
# three negatives above are not a stub that never loaded).
reset; printf 'pq_resolve() { PQ_WHY=stub; echo proceed; }\n' > "$T/h/bin/lib/mc-prequeue.d/stub.sh"; tick
[ "$(pqs success)" = "statuses $H1 success prequeue-verdict proceed on main ${M:0:12}" ] && ok \
  || bad "K11 control: a resolver proceed publishes 'proceed on main ${M:0:12}' (got '$(pqs)'; sink: $(sinkdump))"

# ============================================================================
# K10. pq_status_ensure and the TTL arm, the libs sourced, against the same stub.
# ============================================================================
# lib <cmd...> — run <cmd> in a shell that loaded the conductor's libs.
lib() {
  ( export PATH="$T/fakebin:$PATH" MC_H="$T/h" HARNESS="$T/h" GH_TOKEN=pat-default
    cd "$T" || exit 1
    . "$T/h/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1
    . "$T/h/bin/lib/mc-prequeue.sh" || exit 1
    mkdir -p "$MC_STATE_DIR"; : >> "$MC_ATTEMPTS"
    "$@" )
}
status_is() { printf '{"state":"%s","statuses":[{"context":"prequeue-verdict","state":"%s"}]}' "$2" "$2" > "$T/status-$1.json"; }

# K10a. A green entry, no status: one success.
reset; put 41 "$H1" "$M" green
lib pq_status_ensure "$SLUG" "$H1" "$U/41" "QUEUED past its QUEUED TTL"
[ "$(pqs success)" = "statuses $H1 success prequeue-verdict no red pre-queue verdict on this head: QUEUED past its QUEUED TTL" ] && ok \
  || bad "K10a one success on a green head (got '$(pqs)'; sink: $(sinkdump))"
lib pq_status_ensure "$SLUG" "$H1" "$U/41" "again"
[ "$(npqs)" = 1 ] && ok || bad "K10a a second ensure posts nothing more (sink: $(sinkdump))"

# K10b. A red entry on ANOTHER main blocks it.
reset; put 41 "$H1" "$M" green; put 41 "$H1" "$M_OLD" red tests/a.sh
lib pq_status_ensure "$SLUG" "$H1" "$U/41" "x"
[ "$(npqs)" = 0 ] && ok || bad "K10b any red entry for the head blocks the ensure (sink: $(sinkdump))"

# K10c. A standing failure is never overwritten; nor is any other read state.
for s in failure success pending error; do
  reset; put 41 "$H1" "$M" green; status_is "$H1" "$s"
  lib pq_status_ensure "$SLUG" "$H1" "$U/41" "x"
  [ "$(npqs)" = 0 ] && ok || bad "K10c status $s: the ensure posts nothing (sink: $(sinkdump))"
done
# An unreadable status (no JSON array) posts nothing either.
reset; printf '{"message":"x"}' > "$T/status-$H1.json"
lib pq_status_ensure "$SLUG" "$H1" "$U/41" "x"
[ "$(npqs)" = 0 ] && ok || bad "K10c an unread status posts nothing (sink: $(sinkdump))"
# The context read is prequeue-verdict, not lead-verdict: a lead-verdict
# success alone leaves prequeue-verdict absent, so the ensure publishes.
reset; printf '{"state":"success","statuses":[{"context":"lead-verdict","state":"success"}]}' > "$T/status-$H1.json"
lib pq_status_ensure "$SLUG" "$H1" "$U/41" "x"
[ "$(npqs success)" = 1 ] && ok || bad "K10c a lead-verdict success does not count as prequeue-verdict (sink: $(sinkdump))"

# K10d. The TTL arm: APPROVE bound to H1, Mergify, actions and merges on.
reset; put 41 "$H1" "$M" green
ACTIONS=1 MERGES=1 lib mc_vs_ttl_republish "$K41" QUEUED "$SLUG" 41 "$U/41" "$H1" APPROVE "$H1" mergify
[ "$(pqs success)" = "statuses $H1 success prequeue-verdict no red pre-queue verdict on this head: QUEUED past its QUEUED TTL" ] && ok \
  || bad "K10d the TTL arm publishes prequeue-verdict success (got '$(pqs)'; sink: $(sinkdump); log: $(tail -3 "$MCLOG" 2>/dev/null))"
grep -q "^statuses $H1 success lead-verdict " "$SINK" && ok || bad "K10d the lead-verdict republish is unchanged (sink: $(sinkdump))"
# With merges off the TTL arm ensures nothing.
reset; put 41 "$H1" "$M" green
ACTIONS=1 MERGES=0 lib mc_vs_ttl_republish "$K41" QUEUED "$SLUG" 41 "$U/41" "$H1" APPROVE "$H1" mergify
[ "$(npqs)" = 0 ] && ok || bad "K10d merges off: no prequeue-verdict POST (sink: $(sinkdump))"

# K10e. The rebind arm: a published lead-verdict carry to H2 also ensures
# prequeue-verdict success on H2. A red entry on H2 stops the ensure, never the carry.
pq2() { grep -E "^statuses $H2 [a-z]+ prequeue-verdict" "$SINK" 2>/dev/null; }
reset; printf '{"state":"success","statuses":[{"context":"lead-verdict","state":"success"}]}' > "$T/status-$H1.json"
PROVIDER=mergify ACTIONS=1 MERGES=1 lib mc_rebind_publish "$K41" demo "$SLUG" 41 "$U/41" "$H2" "$H1"
grep -q "^statuses $H2 success lead-verdict " "$SINK" && ok || bad "K10e setup: the rebind carries lead-verdict to H2 (sink: $(sinkdump); log: $(tail -2 "$MCLOG" 2>/dev/null))"
[ "$(pq2)" = "statuses $H2 success prequeue-verdict no red pre-queue verdict on this head: rebound from ${H1:0:12}" ] && ok \
  || bad "K10e the rebind arm ensures prequeue-verdict success on H2 (got '$(pq2)'; sink: $(sinkdump))"
reset; printf '{"state":"success","statuses":[{"context":"lead-verdict","state":"success"}]}' > "$T/status-$H1.json"
put 41 "$H2" "$M" red tests/a.sh
PROVIDER=mergify ACTIONS=1 MERGES=1 lib mc_rebind_publish "$K41" demo "$SLUG" 41 "$U/41" "$H2" "$H1"
grep -q "^statuses $H2 success lead-verdict " "$SINK" && ok || bad "K10e the carry still lands with a red entry (sink: $(sinkdump))"
[ -z "$(pq2)" ] && ok || bad "K10e a red entry on H2 stops the ensure (got '$(pq2)')"

echo "prequeue-verdict-status.bh-5429: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
