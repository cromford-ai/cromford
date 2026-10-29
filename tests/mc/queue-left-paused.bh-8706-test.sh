#!/bin/bash
# tests/mc/queue-left-paused.bh-8706-test.sh — BH-8706: a PR the main-red breaker
# paused is NOT an ejection.
#
# bin/main-red-breaker.sh labels every queued PR `merge-queue-paused` while main
# is red. Mergify's rule stops matching and Mergify dequeues the PR. Counted as
# an ejection, two of those would park the PR BLOCKED_HUMAN. mc_queue_left_why
# answers `paused` for an OPEN PR with the exact pause label, and the conductor's
# settle arm keeps the row QUEUED with one qpaused mark and one log line per head.
#
# L1-L5 call the real mc_queue_left_why (bin/lib/mc/queue.sh) with mc_pr_view
# and mc_mergify_check faked; L-EMPTY: no knob resolvable is not paused. L6 drives the real bin/merge-conductor.sh over two
# ticks against a stub gh, main red. L7: the label on a GREEN main sends one
# stranded warn. L8: after a breaker resume, one tick of grace, then the usual
# ejection count.
# Run from anywhere: tests/mc/queue-left-paused.bh-8706-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/../lib/scratch.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/../.." && pwd)
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/../lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
NOW=$(date -u +%s)

export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib/mc" "$T/h/bin/lib/jobs" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" \
         "$T/h/builds" "$T/h/env" "$T/h/tmp" "$T/fakebin"
scratch_install_closure bin/merge-conductor.sh "$T/h" >/dev/null || exit 1
scratch_install_closure bin/jobs-client.sh "$T/h" >/dev/null || exit 1
mkdir -p "$T/h/bin/merge-conductor.d"
cp "$DIR/bin/merge-conductor.d/bh-8706-queue-paused.sh" "$T/h/bin/merge-conductor.d/" || exit 1
[ -e "$T/h/bin/merge-sweep.sh" ] || scratch_install_closure bin/merge-sweep.sh "$T/h" >/dev/null || exit 1
[ -e "$T/h/bin/fleet-conf.sh" ] || scratch_install_closure bin/fleet-conf.sh "$T/h" >/dev/null || exit 1
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
: > "$T/h/env/global.env"
printf 'mgfy example-org/mgfy-os - - 2 box-m\n' > "$T/h/fleet.conf"
export FLEET_CONF="$T/h/fleet.conf"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"
for s in beat pre-arm-guards codegraph-ensure deploy-request; do printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/$s.sh"; done
chmod +x "$T/h/bin/"*.sh

H1=aaaaaaaa11112222333344445555666677778888
MGFY_YML=$(printf 'queue_rules:\n  - name: default\n    merge_method: squash\n' | base64 | tr -d '\n')

# ---- the stub gh: $T/labels is the PR's comma label list, $T/checks the check runs.
{ printf '#!/bin/bash\nT=%s\nMGFY_YML=%s\nH1=%s\n' "$T" "$MGFY_YML" "$H1"; cat <<'SHIM'
printf '%s\n' "$*" >> "$T/gh-calls.txt"
LBL=$(cat "$T/labels" 2>/dev/null)
case "$*" in
  *"api -i -X GET repos/example-org/mgfy-os/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/example-org/mgfy-os/contents/.mergify.yml"*) restpr --raw 200 "{\"content\":\"$MGFY_YML\"}" ;;
  *"api -i -X GET repos/"*"/check-runs"*) restpr --raw 200 "{\"check_runs\":[$(cat "$T/checks" 2>/dev/null)]}" ;;
  *"api -X DELETE repos/"*"/labels/"*) printf '%s\n' "$*" >> "$T/label-removes.txt"; exit 0 ;;
  *"api -X POST repos/"*|*"api -X PATCH repos/"*) printf '%s\n' "$*" >> "$T/writes.txt"; exit 0 ;;
  *"pr merge"*) printf '%s\n' "$*" >> "$T/merges.txt"; exit 0 ;;
  *"v3.diff"*) restpr --diff ;;
  *"/pulls/"*"/files"*|*"/pulls/"*"/commits"*|*"/pulls/"*"/reviews"*|*"/pulls/"*"/comments"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/pulls/"[0-9]*)
    PN=$(sed -n "s|.*/pulls/\([0-9]*\).*|\1|p" <<<"$*")
    restpr OPEN "$H1" "ticket/mg-$PN" main "$LBL" MERGEABLE CLEAN operator ;;
  *"actions/runs?head_sha="*) restpr --runs 'completed|success' ;;
  *"pr list"*) echo "[]" ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
SHIM
} > "$T/fakebin/gh"
chmod +x "$T/fakebin/gh"
printf '#!/bin/bash\nprintf '"'"'{"error":"not found"}\\n404\\n'"'"'\n' > "$T/fakebin/curl"; chmod +x "$T/fakebin/curl"
export PATH="$T/fakebin:$PATH"
# shellcheck source=/dev/null
. "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init
command -v mc_queue_left_why >/dev/null 2>&1 || { echo "FAIL: mc_queue_left_why is not defined"; exit 1; }
# The pause label is a registry knob (MAIN_RED_BREAKER_PAUSE_LABEL, default
# merge-queue-paused): the composed registry and the real lane_knob resolve it,
# here and in the conductor ticks below (LANE_REGISTRY is exported).
"$DIR/bin/lanes-build.sh" --root "$DIR" --to "$T/lanes.json" >/dev/null 2>&1 || { echo "FAIL: lanes-build.sh could not compose the registry"; exit 1; }
export LANE_REGISTRY="$T/lanes.json"
unset MAIN_RED_BREAKER_PAUSE_LABEL
# shellcheck source=/dev/null
. "$DIR/bin/lib/lane-gate.sh" || { echo "FAIL: bin/lib/lane-gate.sh did not source"; exit 1; }
[ "$(lane_knob main-red-breaker MAIN_RED_BREAKER_PAUSE_LABEL)" = merge-queue-paused ] || { echo "FAIL: lane_knob does not resolve MAIN_RED_BREAKER_PAUSE_LABEL"; exit 1; }

# ============================================================================
# L1-L5 — the real mc_queue_left_why, its two reads faked.
# ============================================================================
FAKE_ST=OPEN; FAKE_LBL=""; CHK_CALLS="$T/chk-calls.txt"; : > "$CHK_CALLS"
mc_pr_view() { printf '%s %s\n' "$FAKE_ST" "$FAKE_LBL"; }
mc_mergify_check() { echo x >> "$CHK_CALLS"; printf 'Mergify Merge Queue|completed|failure|Dequeued\n'; }
U=https://github.com/example-org/mgfy-os/pull/31
why() { FAKE_ST="$1"; FAKE_LBL="$2"; mc_queue_left_why example-org/mgfy-os "$U" "$H1"; }

[ "$(why OPEN merge-queue,merge-queue-paused)" = paused ] && ok || bad "L1: merge-queue,merge-queue-paused must answer paused (got $(why OPEN merge-queue,merge-queue-paused))"
: > "$CHK_CALLS"; why OPEN merge-queue,merge-queue-paused >/dev/null
[ ! -s "$CHK_CALLS" ] && ok || bad "L1: paused is answered before the check-runs read"
[ "$(why OPEN merge-queue-paused,dequeued)" = paused ] && ok || bad "L2: the pause beats dequeued (got $(why OPEN merge-queue-paused,dequeued))"
[ "$(why MERGED merge-queue-paused)" = merged ] && ok || bad "L3: merged beats the pause (got $(why MERGED merge-queue-paused))"
[ "$(why OPEN merge-queue-paused-old,merge-queue)" = ejected ] && ok || bad "L4: a partial label match is not paused (got $(why OPEN merge-queue-paused-old,merge-queue))"
[ "$(why OPEN x-merge-queue-paused)" = ejected ] && ok || bad "L4: a suffix match is not paused (got $(why OPEN x-merge-queue-paused))"
[ "$(why OPEN '')" = ejected ] && ok || bad "L5: no labels gives today's answer (got $(why OPEN ''))"
[ "$(why CLOSED merge-queue-paused)" = unknown ] && ok || bad "L5: a CLOSED PR stays unknown (got $(why CLOSED merge-queue-paused))"
[ "$(MAIN_RED_BREAKER_PAUSE_LABEL=hold-it why OPEN merge-queue,hold-it)" = paused ] && ok || bad "L5: the knob names the label"
[ "$(MAIN_RED_BREAKER_PAUSE_LABEL=hold-it why OPEN merge-queue,merge-queue-paused)" = ejected ] && ok || bad "L5: with the knob set the default label is not the pause"
# L-EMPTY: no lane_knob and no env: no label is the pause, the Mergify check decides.
: > "$CHK_CALLS"
[ "$( unset -f lane_knob; why OPEN merge-queue,merge-queue-paused )" = ejected ] && ok || bad "L-EMPTY: no knob resolvable must not answer paused"
[ -s "$CHK_CALLS" ] && ok || bad "L-EMPTY: with no knob the check-runs read decides"
[ "$( unset -f lane_knob; MAIN_RED_BREAKER_PAUSE_LABEL=merge-queue-paused why OPEN merge-queue,merge-queue-paused )" = paused ] && ok || bad "L-EMPTY: no lane_knob, the env names the label"
unset -f mc_pr_view mc_mergify_check

# ============================================================================
# L6 — the real conductor settle arm, two ticks, one QUEUED row with one strike.
# ============================================================================
A="$T/h/state/merge-conductor/attempts.txt"
CLOG="$T/h/logs/merge-conductor.log"
touch "$T/h/flags/merge-conductor-actions" "$T/h/flags/merge-conductor-merge"
K31='example-org/mgfy-os#31'
d="$T/h/builds/pool-mgfy-X-31-202610050000"; mkdir -p "$d"
echo "PR_CREATED $U" > "$d/RESULT"
printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$d/review.md"
echo "$H1" > "$d/reviewed-sha"; : > "$d/pipeline.log"
: > "$A"; : > "$CLOG"; for f in gh-calls label-removes writes merges; do : > "$T/$f.txt"; done
: > "$T/h/state/merge-conductor/pr-state.tsv"
mc_row_put "$K31" QUEUED $((NOW-300)) "$H1" "$H1" - "in the merge queue" "$U"
echo "ejected $K31 $H1" >> "$A"
echo "requeued $K31 $H1 $((NOW-600))" >> "$A"
# Mergify dequeued it for the pause: its check is cancelled and it stamped `dequeued`.
printf 'merge-queue-paused,dequeued' > "$T/labels"
printf '%s' '{"name":"Mergify Merge Queue","status":"completed","conclusion":"cancelled","output":{"title":"The pull request has been removed from the queue"}}' > "$T/checks"
run_tick() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x \
  MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 \
  MC_MERGE_TREE=0 MC_DETACHED_REBASE=0 MC_DETACHED_DEPLOY_VERIFY=0 MC_MAIN_RED_TEST_PATHS="tests/*" \
  bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) || { echo "tick rc=$? stderr:"; tail -5 "$T/tick.err"; }; }
state_of() { awk -F'\t' -v k="$1" '$1==k {print $2}' "$T/h/state/merge-conductor/pr-state.tsv"; }
# Main is red: the breaker's flag is up, so the pause is expected.
printf 'sha=%s\nsince=2026-10-28T10:00:00Z\nreason=streak\n' "$H1" > "$T/h/flags/main-red-example-org-mgfy-os"
run_tick; run_tick
[ "$(state_of "$K31")" = QUEUED ] && ok || bad "L6: a paused PR stays QUEUED (got $(state_of "$K31"); log: $(grep -o 'mgfy-os#31 .*' "$CLOG" | head -3))"
[ "$(grep -cxF "qpaused $K31 $H1" "$A")" = 1 ] && ok || bad "L6: exactly one qpaused mark over 2 ticks (attempts: $(cat "$A"))"
[ "$(grep -cE "^(ejected|reejected) $K31 " "$A")" = 1 ] && ok || bad "L6: no new ejected/reejected line (attempts: $(cat "$A"))"
[ "$(grep -cF "$K31 left the merge queue PAUSED by the main-red breaker on ${H1:0:8} — not an ejection, no strike (BH-8706)" "$CLOG")" = 1 ] \
  && ok || bad "L6: the PAUSED line once over 2 ticks ($(grep -o 'mgfy-os#31 .*' "$CLOG" | head -4))"
grep -q "EJECTED from the merge queue" "$CLOG" && bad "L6: nothing may say EJECTED" || ok
[ ! -s "$T/label-removes.txt" ] && ok || bad "L6: no label DELETE ($(cat "$T/label-removes.txt"))"
grep -q '^qgone ' "$A" && bad "L6: no qgone hold mark either" || ok
grep -q '^qpaused\(green\|warn\) ' "$A" && bad "L6: a red main sends no stranded warn ($(cat "$A"))" || ok

# ============================================================================
# L7 — STRANDED: the pause label on a GREEN main (the breaker lane is off).
# The first green tick marks it, the second sends ONE warn, the third none.
# ============================================================================
rm -f "$T/h/flags/main-red-example-org-mgfy-os"
: > "$T/h/logs/ALERTS.log" 2>/dev/null
cp "$DIR/bin/lane-alert.sh" "$T/h/bin/lane-alert.sh" 2>/dev/null
printf '#!/bin/bash\necho "$*" >> "%s/alerts.txt"\n' "$T" > "$T/h/bin/lane-alert.sh"; chmod +x "$T/h/bin/lane-alert.sh"; : > "$T/alerts.txt"
run_tick
[ "$(grep -cxF "qpausedgreen $K31 $H1" "$A")" = 1 ] && [ ! -s "$T/alerts.txt" ] && ok || bad "L7: tick 1 on green marks and does not warn (alerts: $(cat "$T/alerts.txt"))"
run_tick; run_tick
[ "$(grep -c "carries merge-queue-paused on ${H1:0:8} but main on example-org/mgfy-os is green" "$T/alerts.txt")" = 1 ] && ok \
  || bad "L7: exactly one stranded warn over ticks 2-3 (alerts: $(cat "$T/alerts.txt"))"
[ "$(state_of "$K31")" = QUEUED ] && ok || bad "L7: the row stays QUEUED (got $(state_of "$K31"))"

# ============================================================================
# L8 — RESUMED: the breaker took the label off and asked Mergify to requeue.
# Mergify's check still says removed. A qpaused mark on the head buys ONE
# tick; the next sighting counts as an ejection, as before.
# ============================================================================
printf 'merge-queue' > "$T/labels"
: > "$CLOG"
run_tick
[ "$(grep -cxF "qresumed $K31 $H1" "$A")" = 1 ] && ok || bad "L8: tick 1 writes the qresumed mark (attempts: $(cat "$A"))"
[ "$(grep -cE "^(ejected|reejected) $K31 " "$A")" = 1 ] && ok || bad "L8: tick 1 counts no ejection (attempts: $(cat "$A"))"
grep -qF "$K31 left the merge queue on ${H1:0:8} after a main-red pause — held one tick" "$CLOG" && ok || bad "L8: the hold line ($(grep -o 'mgfy-os#31 .*' "$CLOG" | head -3))"
[ "$(state_of "$K31")" = QUEUED ] && ok || bad "L8: tick 1 keeps the row QUEUED (got $(state_of "$K31"))"
run_tick
grep -qE "^reejected $K31 $H1" "$A" && ok || bad "L8: tick 2 counts the ejection as before (attempts: $(cat "$A"))"

echo "queue-left-paused.bh-8706: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
