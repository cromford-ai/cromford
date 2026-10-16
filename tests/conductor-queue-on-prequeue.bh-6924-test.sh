#!/bin/bash
# tests/conductor-queue-on-prequeue.bh-6924-test.sh — BH-6924 item 2: the
# conductor queues a READY head on a green pre-queue verdict for that head, and
# a run another worker dispatched counts as if this worker had dispatched it.
#
# WHY. A verdict lived only in the cache of the worker that dispatched the run.
# A lane-run machine has its own state dir, so the hub saw a miss, dispatched
# the same (PR, head, main) again, and never queued on the first green.
#
#   Q1  approved, green checks, CLEAN, a green verdict on the current head in
#       the cache: enqueued, with no PREQUEUE decision line; a second tick does
#       not ask again
#   Q2  an empty cache, and the run list holds a completed run with the exact
#       title and one green verdict: no dispatch, enqueued once, one
#       `PREQUEUE adopt ... -> proceed` line, the entry is green
#   Q3  a green verdict and a run for an OLDER head only, and a run for another
#       PR with this head: not enqueued, one dispatch for this head, held; the
#       dispatch argv carries the seeded learned suite (item 3, L5)
#   Q4  a HOLD on the thread (to_lane_hold answers held): not enqueued, no dispatch
#   Q5  the run with the exact title is in_progress: held, no dispatch, the
#       entry is `pending <the run's created epoch> <run id>`
#   Q6  that run is older than MC_PREQUEUE_DEADLINE_S and still in progress:
#       could-not-run, one warn alert over two ticks, enqueued
#
# Driven, not grepped: every case runs bin/merge-conductor.sh WHOLE in a
# scratch tree with the real tracer, dispatch.sh and adopt.sh. GitHub is a stub;
# its run list, jobs and annotations are the shapes pq_read_run reads.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/conductor-queue-on-prequeue.bh-6924-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq    >/dev/null || { echo "jq missing — skipping";    exit 0; }
command -v git   >/dev/null || { echo "git missing — skipping";   exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }
# shellcheck source=tests/lib/gh-list-bridge.sh
. "$DIR/tests/lib/gh-list-bridge.sh" || exit 1
# shellcheck source=tests/lib/verdict-fixture.sh
. "$DIR/tests/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
[ -f "$DIR/bin/lib/mc-prequeue.d/adopt.sh" ] && [ -f "$DIR/bin/lib/mc-prequeue.d/dispatch.sh" ] && [ -f "$DIR/bin/merge-conductor.sh" ] || exit 1   # impact: bin/lib/mc-prequeue.d/adopt.sh bin/lib/mc-prequeue.d/dispatch.sh bin/merge-conductor.sh

NOW=$(date +%s)
SLUG=example-org/demo-os
U="https://github.com/$SLUG/pull"
NUM=41
iso() { date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ'; }

# ── a real origin that never leaves this box ─────────────────────────────────
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.email t@example.com
git config --global user.name  t
git config --global init.defaultBranch main
git config --global commit.gpgsign false
git config --global protocol.file.allow always
git config --global "url.$T/origin.git.insteadOf" "https://x-access-token@github.com/$SLUG.git"
git config --global "url.$T/origin.git.insteadOf" "https://github.com/$SLUG.git" --add
S="$T/seed"; git init -q --bare "$T/origin.git"; git init -q "$S"
printf 'one\ntwo\n' > "$S/x.txt"; git -C "$S" add -A; git -C "$S" commit -qm A; MA=$(git -C "$S" rev-parse HEAD)
echo y > "$S/y.txt"; git -C "$S" add -A; git -C "$S" commit -qm old; HOLD=$(git -C "$S" rev-parse HEAD)
echo z > "$S/y.txt"; git -C "$S" add -A; git -C "$S" commit -qm new; HNEW=$(git -C "$S" rev-parse HEAD)
git -C "$S" push -q "$T/origin.git" "$MA:refs/heads/main" "$HNEW:refs/pull/41/head" || exit 1

# ── the scratch harness: the conductor's whole closure, two libs stubbed ─────
export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" \
         "$T/h/env" "$T/h/tmp" "$T/fakebin" "$T/repos"
# The HOLD reader answers held while $T/held exists.
cat > "$T/h/bin/lib/ticket-ownership.sh" <<EOF
to_lane_hold() { [ -e "$T/held" ]; }
to_lane_lead_fence() { TO_LEAD_CLEARED=0; return 1; }
to_lead_merge_hold() { return 1; }
EOF
cat > "$T/h/bin/lib/block-gate.sh" <<EOF
bg_enforce() { return 0; }
bg_scan_read() { return 0; }
bg_scan() { return 0; }
bg_why() { echo "BLOCK by operator"; }
bg_reason() { echo "BLOCK by operator"; }
bg_refuse() { return 0; }
EOF
: > "$T/h/bin/lib/pr-snapshot.sh"
scratch_install_closure bin/merge-conductor.sh "$T/h" >/dev/null || exit 1
scratch_install_closure bin/jobs-client.sh "$T/h" >/dev/null || exit 1
# The learned list (item 3): the real bin/prequeue-learned.sh and one seed
# fragment naming a suite in this harness, so a dispatch carries it.
scratch_install_closure bin/prequeue-learned.sh "$T/h" >/dev/null || exit 1
mkdir -p "$T/h/tests" "$T/h/catalog/prequeue-learned-seed.d"
printf '#!/bin/bash\nexit 0\n' > "$T/h/tests/seeded.sh"
printf '# fixture seed\ntests/seeded.sh\n' > "$T/h/catalog/prequeue-learned-seed.d/fixture.txt"
scratch_rm "$T/h/bin/lib/gh-limit-logger.sh"
cp "$DIR/bin/fleet-conf.sh" "$T/h/bin/" || exit 1
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr" && chmod +x "$T/fakebin/restpr" || exit 1
for s in agent-call beat deploy-request pre-arm-guards codegraph-ensure; do printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/$s.sh"; chmod +x "$T/h/bin/$s.sh"; done
printf '#!/bin/bash\necho "[lane-alert] $*" >> "%s/h/logs/ALERTS.log"\n' "$T" > "$T/h/bin/lane-alert.sh"; chmod +x "$T/h/bin/lane-alert.sh"
printf 'demo %s - - 2 box-demo\n' "$SLUG" > "$T/h/fleet.conf"; export FLEET_CONF="$T/h/fleet.conf"
: > "$T/h/env/global.env"
REC="$T/h/builds/pool-demo-BH-20-202610050001"; mkdir -p "$REC"
MGFY_YML=$(printf 'queue_rules:\n  - name: default\n    merge_method: squash\n' | base64 | tr -d '\n')
MCD="$T/h/state/merge-conductor"

# The stub gh. The prequeue run list is $T/runs.json (none: no runs); run
# <id>'s jobs are job <id>0, whose annotations are $T/ann.<id>.json.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
N=$NUM; HD=\$(cat "$T/head"); MN=\$(cat "$T/main")
case "\$*" in
  *"auth token"*) echo faketoken-fixture ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  "workflow run prequeue-gate.yml"*) printf '%s\n' "\$*" >> "$T/dispatch.txt"; exit 0 ;;
  *"api -i -X GET repos/$SLUG/actions/workflows/prequeue-gate.yml/runs?"*)
    echo runs >> "$T/runs-reads.txt"
    if [ -s "$T/runs.json" ]; then restpr --raw 200 "\$(cat "$T/runs.json")"; else restpr --raw 200 '{"workflow_runs":[]}'; fi ;;
  *"api -i -X GET repos/$SLUG/actions/runs/"*"/jobs"*)
    id=\$(printf '%s' "\$*" | sed -n 's|.*actions/runs/\([0-9]*\)/jobs.*|\1|p'); restpr --raw 200 "{\"jobs\":[{\"id\":\${id}0}]}" ;;
  *"api -i -X GET repos/$SLUG/check-runs/"*"/annotations"*)
    j=\$(printf '%s' "\$*" | sed -n 's|.*check-runs/\([0-9]*\)0/annotations.*|\1|p'); restpr --raw 200 "\$(cat "$T/ann.\$j.json" 2>/dev/null || echo '[]')" ;;
  *"api -i -X GET repos/$SLUG/actions/workflows/prequeue-gate.yml"|*"api -i -X GET repos/$SLUG/actions/workflows/prequeue-gate.yml "*)
    restpr --raw 200 '{"id":5,"path":".github/workflows/prequeue-gate.yml"}' ;;
  *"api -i -X GET repos/$SLUG/commits/main"|*"api -i -X GET repos/$SLUG/commits/main "*) restpr --raw 200 "{\"sha\":\"\$MN\"}" ;;
  *"api -i -X GET repos/$SLUG/compare/"*) restpr --raw 200 '{"status":"ahead","ahead_by":1}' ;;
  *"api -i -X GET repos/$SLUG/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/contents/.mergify.yml"*) restpr --raw 200 '{"content":"$MGFY_YML"}' ;;
  *"actions/runs?head_sha="*) restpr --raw 200 '{"workflow_runs":[{"id":1,"name":"CI","status":"completed","conclusion":"success","run_started_at":"2026-10-05T01:00:00Z"}]}' ;;
  *"check-runs?check_name="*) restpr --raw 200 '{"check_runs":[{"name":"Build + Unit tests","status":"completed","conclusion":"success","started_at":"2026-10-05T01:00:00Z"}]}' ;;
  *"api -i -X GET repos/"*"/commits/"*"/check-runs"*) restpr --raw 200 '{"total_count":1,"check_runs":[{"name":"Build + Unit tests","status":"completed","conclusion":"success","started_at":"2026-10-05T01:00:00Z"}]}' ;;
  *"api -i -X POST repos/$SLUG/issues/\$N/comments -f body=@mergifyio"*) printf '%s\n' "\$*" >> "$T/c-enq.txt"; restpr --raw 201 '{"id":901}' ;;
  *"/issues/"*"/labels"*) printf '%s\n' "\$*" >> "$T/c-enq.txt" ;;
  *"api -X POST repos/"*"/issues/"*"/comments"*) case "\$*" in *mergifyio*) printf '%s\n' "\$*" >> "$T/c-enq.txt" ;; esac ;;
  *"pr merge"*) printf '%s\n' "\$*" >> "$T/c-enq.txt"; exit 0 ;;
  *"/pulls/"*"/merge"|*"/pulls/"*"/merge "*) printf '%s\n' "\$*" >> "$T/c-enq.txt"; restpr --raw 200 '{"merged":true}' ;;
  *"api -i -X POST repos/"*"/issues/"*"/comments"*) restpr --raw 201 '{"id":1}' ;;
  *"api -i -X GET repos/"*"/issues/"*"/comments"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/pulls -f state="*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/pulls/\$N"*"v3.diff"*) restpr --diff ;;
  *"api -i -X GET repos/"*"/pulls/"*"/files"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/pulls/\$N"*) restpr OPEN "\$HD" ticket/bh-20 main "" MERGEABLE CLEAN operator "" "Closes #20" ;;
  *"api repos/$SLUG -q .id"*) echo 1 ;;
  *"pr list -R $SLUG --state open"*)
    printf '[{"number":%s,"url":"$U/%s","headRefOid":"%s","headRefName":"ticket/bh-20","baseRefName":"main","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","isInMergeQueue":false,"labels":[]}]\n' "\$N" "\$N" "\$HD" ;;
  *"pr list"*"--state closed"*) : ;;
esac
exit 0
EOF
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

MCLOG="$T/h/logs/merge-conductor.log"
ALERTS="$T/h/logs/ALERTS.log"
ROWS="$MCD/pr-state.tsv"
PQD="$MCD/prequeue"
# reset <head> — #41 approved and green at <head> on main A, a fresh state, no
# runs, no dispatches, no HOLD.
reset() {
  rm -f "$T/tick.err" "$T/held" "$T/runs.json" "$T/ann."*.json
  : > "$T/c-enq.txt"; : > "$T/dispatch.txt"; : > "$T/runs-reads.txt"
  scratch_rm "$MCD"; scratch_rm "$T/h/state/tier2-autoenqueue.txt"; scratch_rm "$T/h/tmp/conductor"
  rm -f "$T/h/logs/"*.log; mkdir -p "$MCD"; : > "$ROWS"
  echo "$1" > "$T/head"; echo "$MA" > "$T/main"
  echo "PR_CREATED $U/$NUM" > "$REC/RESULT"; printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"
  echo "$1" > "$REC/reviewed-sha"; : > "$REC/pipeline.log"
  touch "$T/h/flags/merge-conductor-actions" "$T/h/flags/merge-conductor-merge"
}
tick() {
  ( cd "$T" && env PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x JOBS_URL=http://worker.test GH_TOKEN=pat-default \
    MC_REPOS="$T/repos" MC_MERGE_BUDGET=5 MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 \
    MC_MAIN_RED_DETECT=0 MC_DETACHED_REBASE=0 PR_DEP_GATE_TICKET=0 "$@" bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) \
    || { echo "tick rc=$? stderr:"; tail -5 "$T/tick.err"; }
}
# seed <head> <state> — a cache entry for (#41, <head>, main A) read 2 min ago.
seed() {
  local f
  f=$( MC_STATE_DIR="$MCD" P=demo
    . "$T/h/bin/lib/mc-prequeue.sh" >/dev/null 2>&1 || exit 1
    f=$(pq_key "$SLUG" "$NUM" "$1" "$MA")
    pq_cache_put "$f" "$2" "$((NOW - 300))" 555 "" && printf '%s' "$f" ) || { bad "fixture: pq_cache_put failed for $*"; return 1; }
  touch -d "@$((NOW - 120))" "$f"
}
# run <id> <pr> <head> <status> <conclusion> <created_age_s> — one run in the list.
run() {
  local r
  r=$(jq -n -c --argjson id "$1" --arg t "prequeue pr=$2 head=$3 main=$MA" --arg st "$4" --arg c "$5" --arg at "$(iso $((NOW - $6)))" \
    '{id:$id, display_title:$t, status:$st, conclusion:(if $c == "-" then null else $c end), created_at:$at}')
  jq -c --argjson r "$r" '.workflow_runs += [$r]' "$T/runs.json" 2>/dev/null > "$T/runs.n" || printf '{"workflow_runs":[%s]}\n' "$r" > "$T/runs.n"
  mv -f "$T/runs.n" "$T/runs.json"
}
# green_ann <id> <head> — run <id>'s one prequeue-verdict annotation: green.
green_ann() { jq -n -c --arg m "green main=$MA head=$2 suites=tests/a.sh" '[{title:"prequeue-verdict", message:$m}]' > "$T/ann.$1.json"; }
K() { printf '%s#%s' "$SLUG" "$NUM"; }
state()  { awk -F'\t' -v k="$(K)" '$1==k {print $2}' "$ROWS"; }
enq()    { grep -c "issues/$NUM/comments\|issues/$NUM/labels\|pulls/$NUM/merge\|pr merge $U/$NUM" "$T/c-enq.txt" 2>/dev/null || true; }
ndisp()  { grep -c '^workflow run prequeue-gate.yml' "$T/dispatch.txt" 2>/dev/null || true; }
why()    { cat "$MCD/ready-why/"* 2>/dev/null; }
whykind() { why | awk -F'\t' -v h="$(cat "$T/head")" '$2==h {print $3}' | tail -1; }
pqlog()  { grep PREQUEUE "$MCLOG" 2>/dev/null; }
entry()  { cat "$PQD/example-org_demo-os_41_$(cat "$T/head")_$MA" 2>/dev/null; }
adopt_lines() { grep -c 'PREQUEUE adopt #41' "$MCLOG" 2>/dev/null || true; }
nalerts() { grep -c 'prequeue gate could-not-run' "$ALERTS" 2>/dev/null || true; }

# ============================================================================
# Q1. A green verdict on the current head: enqueued once, then not again.
# ============================================================================
reset "$HNEW"; seed "$HNEW" green; tick
[ "$(enq)" -ge 1 ] && ok || bad "Q1: enqueued (state '$(state)'; why $(why); log $(pqlog); err $(tail -3 "$T/tick.err"))"
[ "$(ndisp)" = 0 ] && ok || bad "Q1: no dispatch (got $(cat "$T/dispatch.txt"))"
# The stub's queue never acknowledges (MC_MERGIFY_WAIT_S=0, mc_enqueue rc 3),
# so the row stays READY; the ask mark is what keeps it to one request.
grep -q "PREQUEUE" "$MCLOG" 2>/dev/null && bad "Q1: a cache hit asks nothing (log $(pqlog))" || ok
: > "$T/c-enq.txt"; tick
[ "$(enq)" = 0 ] && ok || bad "Q1 second tick: not enqueued again (argv $(cat "$T/c-enq.txt"))"
[ "$(ndisp)" = 0 ] && ok || bad "Q1 second tick: no dispatch"

# ============================================================================
# Q2. Nothing in this worker's cache; another worker's run with the exact title
# completed green: adopted, no dispatch, enqueued once.
# ============================================================================
reset "$HNEW"; run 9101 41 "$HNEW" completed success 900; green_ann 9101 "$HNEW"; tick
[ "$(ndisp)" = 0 ] && ok || bad "Q2: no dispatch (got $(cat "$T/dispatch.txt"); log $(pqlog))"
[ "$(enq)" -ge 1 ] && ok || bad "Q2: enqueued (state '$(state)'; why $(why); log $(pqlog); err $(tail -3 "$T/tick.err"))"
[ "$(adopt_lines)" = 1 ] && grep -q "PREQUEUE adopt #41 head=${HNEW:0:12} main=${MA:0:12} run=9101 -> proceed" "$MCLOG" && ok || bad "Q2: one adopt line -> proceed (log $(pqlog))"
case "$(entry)" in "green $((NOW - 900)) 9101 tests/a.sh") ok ;; *) bad "Q2: the entry is the run's green, aged from its created time (got '$(entry)')" ;; esac
: > "$T/c-enq.txt"; tick
[ "$(enq)" = 0 ] && [ "$(ndisp)" = 0 ] && ok || bad "Q2 second tick: no second enqueue, no dispatch (enq $(cat "$T/c-enq.txt"); disp $(cat "$T/dispatch.txt"))"

# ============================================================================
# Q3. A green verdict and a run for an older head, and a run for #42 with this
# head: neither counts. One dispatch for this head, held.
# ============================================================================
reset "$HNEW"; seed "$HOLD" green
run 9102 41 "$HOLD" completed success 900; green_ann 9102 "$HOLD"
run 9103 42 "$HNEW" completed success 900; green_ann 9103 "$HNEW"
tick
[ "$(enq)" = 0 ] && ok || bad "Q3: not enqueued (argv $(cat "$T/c-enq.txt"))"
[ "$(ndisp)" = 1 ] && grep -q -- "-f head=$HNEW" "$T/dispatch.txt" && ok || bad "Q3: one dispatch for the current head (got $(cat "$T/dispatch.txt"))"
[ "$(whykind)" = prequeue-pending ] && ok || bad "Q3: held prequeue-pending (why $(why))"
grep -q -- "-f learned=tests/seeded.sh" "$T/dispatch.txt" && ok || bad "Q3 (item 3): the dispatch carries the seed suite (got $(cat "$T/dispatch.txt"))"
[ "$(adopt_lines)" = 0 ] && ok || bad "Q3: nothing adopted (log $(pqlog))"

# ============================================================================
# Q4. A HOLD: not enqueued, no dispatch, even with a green verdict.
# ============================================================================
reset "$HNEW"; seed "$HNEW" green; touch "$T/held"; tick
[ "$(enq)" = 0 ] && ok || bad "Q4: not enqueued (argv $(cat "$T/c-enq.txt"))"
[ "$(ndisp)" = 0 ] && ok || bad "Q4: no dispatch (got $(cat "$T/dispatch.txt"))"
[ "$(whykind)" = ticket-hold ] && ok || bad "Q4: held ticket-hold (why $(why))"
reset "$HNEW"; run 9104 41 "$HNEW" completed success 900; green_ann 9104 "$HNEW"; touch "$T/held"; tick
[ "$(enq)" = 0 ] && [ "$(ndisp)" = 0 ] && ok || bad "Q4 with a run: not enqueued, no dispatch (enq $(cat "$T/c-enq.txt"); disp $(cat "$T/dispatch.txt"))"

# ============================================================================
# Q5. The run with the exact title is still in progress: held, no dispatch.
# ============================================================================
reset "$HNEW"; run 9105 41 "$HNEW" in_progress - 300; tick
[ "$(ndisp)" = 0 ] && ok || bad "Q5: no dispatch (got $(cat "$T/dispatch.txt"); log $(pqlog))"
[ "$(enq)" = 0 ] && ok || bad "Q5: not enqueued (argv $(cat "$T/c-enq.txt"))"
[ "$(whykind)" = prequeue-pending ] && ok || bad "Q5: held prequeue-pending (why $(why))"
case "$(entry)" in "pending $((NOW - 300)) 9105"*) ok ;; *) bad "Q5: the entry is pending at the run's created time (got '$(entry)')" ;; esac
grep -q "PREQUEUE adopt #41 head=${HNEW:0:12} main=${MA:0:12} run=9105 -> hold" "$MCLOG" && ok || bad "Q5: the adopt line -> hold (log $(pqlog))"
# The same run completes green on a later tick: the pending entry settles.
run 9105 41 "$HNEW" completed success 300
jq -c '.workflow_runs |= (map(select(.id != 9105 or .status == "completed")))' "$T/runs.json" > "$T/runs.n" && mv -f "$T/runs.n" "$T/runs.json"
green_ann 9105 "$HNEW"; : > "$T/c-enq.txt"; tick
[ "$(enq)" -ge 1 ] && [ "$(ndisp)" = 0 ] && ok || bad "Q5 later tick: settled green, enqueued, no dispatch (enq $(cat "$T/c-enq.txt"); disp $(cat "$T/dispatch.txt"); entry '$(entry)')"

# ============================================================================
# Q6. The adopted run is past MC_PREQUEUE_DEADLINE_S and still in progress.
# ============================================================================
reset "$HNEW"; run 9106 41 "$HNEW" in_progress - 3000; tick
[ "$(ndisp)" = 0 ] && ok || bad "Q6: no dispatch (got $(cat "$T/dispatch.txt"))"
case "$(entry)" in "could-not-run $((NOW - 3000)) deadline alerted"*) ok ;; *) bad "Q6: could-not-run alerted (got '$(entry)')" ;; esac
[ "$(enq)" -ge 1 ] && ok || bad "Q6: proceeds, enqueued (state '$(state)'; log $(pqlog))"
reset_keep_alerts=$(nalerts)
: > "$T/c-enq.txt"; scratch_rm "$MCD/pr-state.tsv"; : > "$ROWS"; tick
[ "$reset_keep_alerts" = 1 ] && [ "$(nalerts)" = 1 ] && ok || bad "Q6: one warn alert over two ticks (first $reset_keep_alerts, after $(nalerts))"
[ "$(ndisp)" = 0 ] && ok || bad "Q6 second tick: no dispatch"

echo "conductor-queue-on-prequeue.bh-6924: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
