#!/bin/bash
# tests/mc/prequeue-isolation.bh-4545-test.sh — BH-4545: the pre-queue
# isolation gate. Before a READY head is marked ready or enqueued, the conductor
# asks pq_gate (bin/lib/mc-prequeue.sh). It reads a per-(PR, head, main tip)
# verdict file and parks the row prequeue-red on a cached red that names a
# suite. With no entry and no pq_resolve hook it proceeds, so nothing changes
# until a sibling drops a hook into bin/lib/mc-prequeue.d/.
#
# Driven, not grepped: every case runs bin/merge-conductor.sh WHOLE in a scratch
# tree against a stub gh. The verdict fixtures are written with the lib's own
# pq_key/pq_cache_put. Assertions read the sinks: the enqueue/label/merge argv
# ($T/c-enq.txt), the main-tip reads ($T/tip-calls.txt), the row table,
# logs/merge-conductor.log, logs/ALERTS.log and the ready-why note.
# Siblings append their cases (E10+) to this file.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/mc/prequeue-isolation.bh-4545-test.sh
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
mkdir -p "$T/h/bin/lib/mc" "$T/h/bin/lib/jobs" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" \
         "$T/h/env" "$T/h/tmp" "$T/fakebin"
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" \
   "$DIR/bin/lib/gh-rest-list.sh" "$DIR/bin/lib/gh-repo-token.sh" "$DIR/bin/lib/autoenqueue.sh" "$DIR/bin/lib/hold.sh" \
   "$DIR/bin/lib/mc-hold-comment.sh" "$DIR/bin/lib/lane-switch.sh" "$T/h/bin/lib/" || exit 1
cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/" || exit 1
cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/" || exit 1
cp "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$T/h/bin/" || exit 1
# The lib under test, and its (empty) hook dir. Absent on main: the red this opens on.
mkdir -p "$T/h/bin/lib/mc-prequeue.d"
[ -r "$DIR/bin/lib/mc-prequeue.sh" ] && cp "$DIR/bin/lib/mc-prequeue.sh" "$T/h/bin/lib/"
printf 'to_lane_hold() { return 1; }\nto_lane_lead_fence() { TO_LEAD_CLEARED=0; return 1; }\n' > "$T/h/bin/lib/ticket-ownership.sh"
printf 'demo %s - - 2 box-demo\n' "$SLUG" > "$T/h/fleet.conf"; export FLEET_CONF="$T/h/fleet.conf"
: > "$T/h/env/global.env"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"
for s in agent-call beat deploy-request pre-arm-guards codegraph-ensure; do printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/$s.sh"; chmod +x "$T/h/bin/$s.sh"; done
REC="$T/h/builds/pool-demo-BH-20-202610050001"; mkdir -p "$REC"
MGFY_YML=$(printf 'queue_rules:\n  - name: default\n    merge_method: squash\n' | base64 | tr -d '\n')
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
# The stub. The main-tip read answers {"sha":$M}, or a 500 while $T/tip-down
# exists; every such read is recorded in $T/tip-calls.txt. Enqueues
# (`@mergifyio queue`), label writes and merges land in $T/c-enq.txt.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"api -i -X GET repos/$SLUG/commits/main"|*"api -i -X GET repos/$SLUG/commits/main "*)
    printf '%s\n' "\$*" >> "$T/tip-calls.txt"
    if [ -e "$T/tip-down" ]; then restpr --raw 500 '{"message":"Server Error"}'; else restpr --raw 200 '{"sha":"$M"}'; fi ;;
  *"api -i -X GET repos/$SLUG/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/contents/.mergify.yml"*) restpr --raw 200 '{"content":"$MGFY_YML"}' ;;
  *"actions/runs?head_sha="*) restpr --raw 200 '{"workflow_runs":[{"id":1,"name":"CI","status":"completed","conclusion":"success","run_started_at":"2026-10-05T01:00:00Z"}]}' ;;
  *"check-runs?check_name="*) restpr --raw 200 '{"check_runs":[{"name":"Build + Unit tests","status":"completed","conclusion":"success","started_at":"2026-10-05T01:00:00Z"}]}' ;;
  *"api -i -X GET repos/"*"/commits/"*"/check-runs"*) restpr --raw 200 '{"total_count":1,"check_runs":[{"name":"Build + Unit tests","status":"completed","conclusion":"success","started_at":"2026-10-05T01:00:00Z"}]}' ;;
  *"api -i -X POST repos/$SLUG/issues/41/comments -f body=@mergifyio"*) printf '%s\n' "\$*" >> "$T/c-enq.txt"; restpr --raw 201 '{"id":901}' ;;
  *"/issues/"*"/labels"*) printf '%s\n' "\$*" >> "$T/c-enq.txt" ;;
  *"api -X POST repos/"*"/issues/"*"/comments"*) case "\$*" in *mergifyio*) printf '%s\n' "\$*" >> "$T/c-enq.txt" ;; esac ;;
  *"pr merge"*) printf '%s\n' "\$*" >> "$T/c-enq.txt"; exit 0 ;;
  *"/pulls/"*"/merge"|*"/pulls/"*"/merge "*) printf '%s\n' "\$*" >> "$T/c-enq.txt"; restpr --raw 200 '{"merged":true}' ;;
  *"api -i -X POST repos/"*"/issues/"*"/comments"*) restpr --raw 201 '{"id":1}' ;;
  *"api -i -X GET repos/"*"/issues/"*"/comments"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/pulls -f state="*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/pulls/41"*"v3.diff"*) restpr --diff ;;
  *"api -i -X GET repos/"*"/pulls/"*"/files"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/pulls/41"*) restpr OPEN "\$(cat "$T/head41")" ticket/bh-20 main "" MERGEABLE CLEAN operator "" "Closes #20" ;;
  *"api repos/$SLUG -q .id"*) echo 1 ;;
  *"pr list -R $SLUG --state open"*) cat "$T/list.json" ;;
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

MCD="$T/h/state/merge-conductor"
MCLOG="$T/h/logs/merge-conductor.log"
ALERTS="$T/h/logs/ALERTS.log"
ROWS="$MCD/pr-state.tsv"
# reset [head] — a fresh harness state with #41 approved and green at <head>.
reset() {
  local h="${1:-$H1}"
  rm -f "$T/c-enq.txt" "$T/tip-calls.txt" "$T/tick.err" "$T/tip-down" "$T/h/bin/lib/mc-prequeue.d/"*.sh
  : > "$T/c-enq.txt"; : > "$T/tip-calls.txt"
  scratch_rm "$MCD"; scratch_rm "$T/h/state/tier2-autoenqueue.txt"
  rm -f "$T/h/logs/"*.log; mkdir -p "$MCD"; : > "$ROWS"
  echo "$h" > "$T/head41"
  echo "PR_CREATED $U/41" > "$REC/RESULT"; printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"
  echo "$h" > "$REC/reviewed-sha"; : > "$REC/pipeline.log"
  cat > "$T/list.json" <<J
[{"number":41,"url":"$U/41","headRefOid":"$h","headRefName":"ticket/bh-20","baseRefName":"main","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","isInMergeQueue":false,"labels":[]}]
J
  touch "$T/h/flags/merge-conductor-actions" "$T/h/flags/merge-conductor-merge"
}
tick() {
  ( cd "$T" && env PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x JOBS_URL=http://worker.test GH_TOKEN=pat-default \
    MC_MERGE_BUDGET=0 MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 MC_MAIN_RED_DETECT=0 \
    MC_DETACHED_REBASE=0 "$@" bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) || { echo "tick rc=$? stderr:"; tail -5 "$T/tick.err"; }
}
# put <slug> <num> <head> <main> <state> [suites] — one verdict, through the lib's own writer.
put() {
  ( MC_STATE_DIR="$MCD" P=demo
    . "$T/h/bin/lib/mc-prequeue.sh" || exit 1
    pq_cache_put "$(pq_key "$1" "$2" "$3" "$4")" "$5" 1759626000 - "${6:-}" ) || bad "fixture: pq_cache_put failed for $*"
}
state41()  { awk -F'\t' -v k="$K41" '$1==k {print $2}' "$ROWS"; }
reason41() { awk -F'\t' -v k="$K41" '$1==k {print $7}' "$ROWS"; }
enq()  { grep -c "issues/41/comments\|issues/41/labels\|pulls/41/merge\|pr merge $U/41" "$T/c-enq.txt" 2>/dev/null || true; }
clog() { grep -F "$K41" "$MCLOG" 2>/dev/null | tail -"${1:-6}"; }
why41() { cat "$MCD/ready-why/"* 2>/dev/null; }
# display <state> <reason> — the word a person reads for this row (mc_state_display).
display() { ( . "$T/h/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1; mc_state_display "$1" "$2" ); }
enqueued() { # enqueued <case>
  [ "$(enq)" -ge 1 ] && ok || bad "$1: the head must be enqueued (argv: $(cat "$T/c-enq.txt"); state '$(state41)'; log: $(clog))"
  [ "$(state41)" != BLOCKED_HUMAN ] && ok || bad "$1: the row must not be parked (reason '$(reason41)')"
}

# ============================================================================
# E1. A cached red naming a suite, for THIS head on THIS main: parked, not enqueued.
# ============================================================================
reset; put "$SLUG" 41 "$H1" "$M" red tests/a.sh
tick
[ "$(enq)" = 0 ] && ok || bad "E1 no enqueue, no label write, no merge on a cached red (argv: $(cat "$T/c-enq.txt"))"
[ "$(state41)" = BLOCKED_HUMAN ] && ok || bad "E1 the row must be parked (state '$(state41)'; log: $(clog))"
[ "$(display "$(state41)" "$(reason41)")" = BLOCKED_AGENT ] && ok \
  || bad "E1 the park must read BLOCKED_AGENT, a resolver hand-off (got '$(display "$(state41)" "$(reason41)")')"
case "$(reason41)" in
  "prequeue-red: tests/a.sh on main ${M:0:12} — the head merged onto current main fails them") ok ;;
  *) bad "E1 the reason names the suite and main (got '$(reason41)')" ;;
esac
[ "$(grep -c "$K41 PREQUEUE_RED" "$MCLOG" 2>/dev/null)" = 1 ] && ok || bad "E1 exactly one PREQUEUE_RED line (log: $(clog))"
[ "$(grep -c 'budget' <<<"$(clog 40)")" = 0 ] && ok || bad "E1 a park spends and asks no merge budget (log: $(clog))"
tick
[ "$(enq)" = 0 ] && ok || bad "E1 tick 2: still not enqueued (argv: $(cat "$T/c-enq.txt"))"
[ "$(grep -c "$K41 PREQUEUE_RED" "$MCLOG")" = 1 ] && ok || bad "E1 tick 2: still exactly one PREQUEUE_RED line (got $(grep -c "$K41 PREQUEUE_RED" "$MCLOG"))"
[ "$(grep -c "$K41 BLOCKED_HUMAN -> READY" "$MCLOG")" = 0 ] && [ "$(state41)" = BLOCKED_HUMAN ] && ok \
  || bad "E1 tick 2: the park is sticky, it does not flip back to READY (state '$(state41)'; log: $(clog))"

# E1b. With the sticky hand-off switched off the row is re-asked every tick:
#      still never enqueued, and the PREQUEUE_RED line is still said once.
reset; put "$SLUG" 41 "$H1" "$M" red tests/a.sh
tick MC_STICKY_HANDOFF=0; tick MC_STICKY_HANDOFF=0
[ "$(enq)" = 0 ] && [ "$(state41)" = BLOCKED_HUMAN ] && ok || bad "E1b re-asked, still parked and not enqueued (argv: $(cat "$T/c-enq.txt"); state '$(state41)')"
[ "$(grep -c "$K41 PREQUEUE_RED" "$MCLOG")" = 1 ] && ok || bad "E1b one PREQUEUE_RED line per (PR, head, main) (got $(grep -c "$K41 PREQUEUE_RED" "$MCLOG"))"

# ============================================================================
# E2. Every non-red verdict proceeds: enqueued, never parked.
# ============================================================================
for st in green no-selection conflict could-not-run; do
  reset; put "$SLUG" 41 "$H1" "$M" "$st" tests/a.sh; tick
  enqueued "E2 $st"
done

# ============================================================================
# E3. A red that is not this key, or not a known word, never parks.
# ============================================================================
reset; put "$SLUG" 41 "$H2" "$M" red tests/a.sh; tick; enqueued "E3 red for another head"
reset; put "$SLUG" 41 "$H1" "$M_OLD" red tests/a.sh; tick; enqueued "E3 red for an older main"
reset; put "$SLUG" 41 "$H1" "$M" RED tests/a.sh; tick; enqueued "E3 RED is not red"
reset; put "$SLUG" 4541 "$H1" "$M" red tests/a.sh; tick; enqueued "E3 red under #4541 is not #41's"
reset; put "$SLUG" 4 "$H1" "$M" red tests/a.sh; tick; enqueued "E3 red under #4 is not #41's"

# ============================================================================
# E4. No entry, no hook: today's behaviour, and nobody is told anything.
# ============================================================================
reset; tick
enqueued "E4"
grep -qi prequeue "$ALERTS" 2>/dev/null && bad "E4 no prequeue alert (alerts: $(cat "$ALERTS"))" || ok
[ -s "$T/tip-calls.txt" ] && ok || bad "E4 the gate read the main tip on a merging tick (calls: none)"

# ============================================================================
# E5. The main tip cannot be read: held READY, said why, nothing enqueued.
# ============================================================================
reset; touch "$T/tip-down"; put "$SLUG" 41 "$H1" "$M" green; tick
[ "$(enq)" = 0 ] && ok || bad "E5 an unreadable tip enqueues nothing (argv: $(cat "$T/c-enq.txt"))"
[ "$(state41)" = READY ] && ok || bad "E5 the row stays READY (state '$(state41)')"
grep -q "	$H1	prequeue-pending	main tip unreadable, asked next tick" <<<"$(why41)" && ok \
  || bad "E5 the ready-why note says prequeue-pending / main tip unreadable (note: $(why41))"
grep -qi prequeue "$ALERTS" 2>/dev/null && bad "E5 no alert for an unreadable tip (alerts: $(cat "$ALERTS"))" || ok
[ "$(grep -c 'budget' <<<"$(clog 40)")" = 0 ] && ok || bad "E5 a hold asks no merge budget (log: $(clog))"
rm -f "$T/tip-down"; tick
[ "$(enq)" -ge 1 ] && ok || bad "E5 the next tick with a readable tip enqueues (argv: $(cat "$T/c-enq.txt"); log: $(clog))"

# ============================================================================
# E6. A red that names no suite never parks.
# ============================================================================
reset; put "$SLUG" 41 "$H1" "$M" red ""; tick
enqueued "E6"

# ============================================================================
# E7. The gate switched off: a cached red is not read.
# ============================================================================
reset; put "$SLUG" 41 "$H1" "$M" red tests/a.sh; tick MC_PREQUEUE_GATE=0
enqueued "E7"
[ -s "$T/tip-calls.txt" ] && bad "E7 the gate off reads no main tip (calls: $(cat "$T/tip-calls.txt"))" || ok

# ============================================================================
# E8. Observe (no merge flag): the gate is never consulted.
# ============================================================================
reset; rm -f "$T/h/flags/merge-conductor-merge"; tick
[ -s "$T/tip-calls.txt" ] && bad "E8 observe mode reads no main tip (calls: $(cat "$T/tip-calls.txt"))" || ok
[ -e "$MCD/prequeue" ] && bad "E8 observe mode creates no prequeue dir" || ok
[ "$(state41)" = READY ] && ok || bad "E8 setup: #41 reaches READY under observe (state '$(state41)'; err: $(tail -3 "$T/tick.err"))"

# ============================================================================
# E9. A hook in mc-prequeue.d/ answers a miss: hold is obeyed, junk proceeds.
# ============================================================================
reset
printf 'pq_resolve() { PQ_WHY=stub; echo hold; }\n' > "$T/h/bin/lib/mc-prequeue.d/stub.sh"
tick
[ "$(enq)" = 0 ] && ok || bad "E9 a hook's hold enqueues nothing (argv: $(cat "$T/c-enq.txt"))"
grep -q "	prequeue-pending	stub$" <<<"$(why41)" && ok || bad "E9 the hook's PQ_WHY is the note (note: $(why41))"
reset
printf 'pq_resolve() { echo bogus; }\n' > "$T/h/bin/lib/mc-prequeue.d/stub.sh"
tick; enqueued "E9 a hook's unknown word proceeds"
reset
printf 'pq_resolve() { PQ_SUITES=; echo red; }\n' > "$T/h/bin/lib/mc-prequeue.d/stub.sh"
tick; enqueued "E9 a hook's red with no suite proceeds"
reset
printf 'pq_resolve() { echo x >> "%s/resolve-calls"; PQ_SUITES=tests/b.sh; echo red; }\n' "$T" > "$T/h/bin/lib/mc-prequeue.d/stub.sh"
rm -f "$T/resolve-calls"; tick
[ "$(state41)" = BLOCKED_HUMAN ] && [ "$(reason41)" = "prequeue-red: tests/b.sh on main ${M:0:12} — the head merged onto current main fails them" ] && ok \
  || bad "E9 a hook's red with a suite parks naming it (state '$(state41)', reason '$(reason41)')"
[ "$(wc -l < "$T/resolve-calls" 2>/dev/null)" = 1 ] && ok || bad "E9 the hook runs once per gate call (got $(wc -l < "$T/resolve-calls" 2>/dev/null))"

echo "prequeue-isolation.bh-4545: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
