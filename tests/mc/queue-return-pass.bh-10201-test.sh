#!/bin/bash
# tests/mc/queue-return-pass.bh-10201-test.sh — BH-10201: the REAL conductor
# tick (bin/merge-conductor.sh) with the queue-return fragment, over a stub gh
# and a fake jobs-ledger worker (a `curl` on PATH that keeps kind queue_return
# in files and answers 404 for every other route).
#
# A QUEUED row whose PR left the queue is recorded at the label removal. The
# pass at the end of the tick closes the row when the PR is back, releases it
# for a hold, and tells one person, one time, when it is not back.
#   P1 the settle arm removes the label: ONE row, status owed, with the cause
#      and the head; the same tick sends no alert
#   P2 not back after the limit: ONE alert and ONE PR comment in 4 ticks, the
#      row keeps the told head, and the tick puts nothing in the queue
#   P3 the lead fence holds the head (ready-why kind lead-held): ONE alert and
#      ONE comment at once, in 3 ticks
#   P4 MC_QUEUE_RETURN=0: no row at the leave; an owed row gets no alert
#   P5 main red: 0 alerts; green on the next tick: 1 alert
#   P6 the label is back: the row is done, 0 alerts
#   P7 a hold label: the row is released, 0 alerts
#   P8 a person removed the label: the row is released at the leave
#   P9 actions off (observe mode): the pass writes nothing
#   R  #10134 replayed in its real event order, push guard off
#
# MUTATIONS this suite must catch (each makes at least one case red):
#   M1 drop the mc_qr_owe call from the settle arm       -> P1, P8
#   M2 drop the mc_qr_pass call from the tick             -> P2, P3, P6, P7
#   M3 alert on every tick (no told head, no stale flag)   -> P2, P3
#   M4 ignore the kill knob                               -> P4
#   M5 ignore the main-red flag                           -> P5
#   M6 run the pass in observe mode                       -> P9
#   M7 read a row in the tick that made its leave         -> P1
# The clock is not read here: a row is made old by its left_at (0), and young
# by a left_at in the far future. Each case has its own row, ledger and head.
# Run from anywhere: tests/mc/queue-return-pass.bh-10201-test.sh  (exit 0 = all pass)
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
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }
command -v jq >/dev/null || { echo "FAIL: jq missing"; exit 1; }
unset MC_QUEUE_RETURN MC_QUEUE_RETURN_ALERT_MIN

export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib/mc" "$T/h/bin/lib/jobs" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" \
         "$T/h/builds" "$T/h/env" "$T/h/tmp" "$T/fakebin" "$T/ledger"
scratch_install_closure bin/merge-conductor.sh "$T/h" >/dev/null || exit 1
scratch_install_closure bin/jobs-client.sh "$T/h" >/dev/null || exit 1
mkdir -p "$T/h/bin/merge-conductor.d"
cp "$DIR/bin/merge-conductor.d/bh-10201-queue-return.sh" "$T/h/bin/merge-conductor.d/" \
  || { echo "FAIL: bin/merge-conductor.d/bh-10201-queue-return.sh is missing"; exit 1; }
[ -e "$T/h/bin/merge-sweep.sh" ] || scratch_install_closure bin/merge-sweep.sh "$T/h" >/dev/null || exit 1
[ -e "$T/h/bin/fleet-conf.sh" ] || scratch_install_closure bin/fleet-conf.sh "$T/h" >/dev/null || exit 1
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
: > "$T/h/env/global.env"
printf 'mgfy example-org/mgfy-os - - 2 box-m\n' > "$T/h/fleet.conf"
export FLEET_CONF="$T/h/fleet.conf"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"
for s in beat pre-arm-guards codegraph-ensure deploy-request; do printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/$s.sh"; done
printf '#!/bin/bash\necho "$*" >> "%s/alerts.txt"\n' "$T" > "$T/h/bin/lane-alert.sh"
chmod +x "$T/h/bin/"*.sh

MGFY_YML=$(printf 'queue_rules:\n  - name: default\n    merge_method: squash\n' | base64 | tr -d '\n')

# ---- the stub gh: $T/labels is the PR's comma label list, $T/checks the check
# runs, $T/events the issue events, $T/head the PR head.
{ printf '#!/bin/bash\nT=%s\nMGFY_YML=%s\n' "$T" "$MGFY_YML"; cat <<'SHIM'
printf '%s\n' "$*" >> "$T/gh-calls.txt"
LBL=$(cat "$T/labels" 2>/dev/null)
HEAD=$(cat "$T/head" 2>/dev/null)
case "$*" in
  *"api -i -X GET repos/example-org/mgfy-os/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/example-org/mgfy-os/contents/.mergify.yml"*) restpr --raw 200 "{\"content\":\"$MGFY_YML\"}" ;;
  *"api -i -X GET repos/"*"/check-runs"*) restpr --raw 200 "{\"check_runs\":[$(cat "$T/checks" 2>/dev/null)]}" ;;
  *"api -i -X GET repos/"*"/issues/"*"/events"*) restpr --raw 200 "$(cat "$T/events" 2>/dev/null || echo '[]')" ;;
  *"api -X DELETE repos/"*"/labels/"*) printf '%s\n' "$*" >> "$T/label-removes.txt"; exit 0 ;;
  *"-X POST repos/"*"/issues/"*"/comments"*)
    BF=$(sed -n 's|.*body=@\([^ ]*\).*|\1|p' <<<"$*")
    printf '%s %s\n' "$*" "$(cat "$BF" 2>/dev/null | tr '\n' ' ')" >> "$T/writes.txt"; restpr --raw 201 '{"id":1}' ;;
  *"api -X POST repos/"*|*"api -X PATCH repos/"*) printf '%s\n' "$*" >> "$T/writes.txt"; exit 0 ;;
  *"pr merge"*) printf '%s\n' "$*" >> "$T/merges.txt"; exit 0 ;;
  *"v3.diff"*) restpr --diff ;;
  *"/pulls/"*"/files"*|*"/pulls/"*"/commits"*|*"/pulls/"*"/reviews"*|*"/pulls/"*"/comments"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/pulls/"[0-9]*)
    PN=$(sed -n "s|.*/pulls/\([0-9]*\).*|\1|p" <<<"$*")
    restpr OPEN "$HEAD" "ticket/mg-$PN" main "$LBL" MERGEABLE CLEAN operator ;;
  *"actions/runs?head_sha="*) restpr --runs 'completed|success' ;;
  *"pr list"*) echo "[]" ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
SHIM
} > "$T/fakebin/gh"
chmod +x "$T/fakebin/gh"

# ---- the fake jobs worker: /api/ledger for kind queue_return, in $T/ledger/.
{ printf '#!/bin/bash\nT=%s\n' "$T"; cat <<'SHIM'
method=GET; url=""; data=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    --data-binary) data="$2"; shift 2 ;;
    -m|--connect-timeout|-w|-H) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
L="$T/ledger"
kf() { printf '%s/%s' "$L" "$(printf '%s' "$1" | tr '/#' '__')"; }
miss() { printf '{"error":"not found"}\n404\n'; exit 0; }
case "$method $url" in
  "PUT "*"/api/ledger")
    [ "$(jq -r '.kind // ""' <<<"$data")" = queue_return ] || miss
    key=$(jq -r '.key' <<<"$data"); f=$(kf "$key")
    old=""; [ -r "$f" ] && old=$(jq -r '.detail // ""' "$f")
    jq -c --arg old "$old" '{kind, key, status, detail: (.detail // $old), updated_at: "2026-11-26T00:00:00Z"}' <<<"$data" > "$f.tmp" && mv -f "$f.tmp" "$f"
    printf '%s %s\n' "$key" "$(jq -r .status "$f")" >> "$T/ledger-puts.txt"
    printf '{"ledger":%s}\n200\n' "$(cat "$f")" ;;
  "GET "*"/api/ledger?kind=queue_return&key="*)
    enc="${url##*&key=}"; key=$(printf '%b' "${enc//%/\\x}"); f=$(kf "$key")
    [ -r "$f" ] || miss
    printf '{"ledger":%s}\n200\n' "$(cat "$f")" ;;
  "GET "*"/api/ledger?kind=queue_return&status=owed&limit="*)
    echo list >> "$T/ledger-lists.txt"
    rows=$(cat "$L"/* 2>/dev/null | jq -sc '[.[] | select(.status == "owed")]')
    printf '{"ledgers":%s}\n200\n' "${rows:-[]}" ;;
  *) miss ;;
esac
exit 0
SHIM
} > "$T/fakebin/curl"
chmod +x "$T/fakebin/curl"
export PATH="$T/fakebin:$PATH"
# shellcheck source=/dev/null
. "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init
"$DIR/bin/lanes-build.sh" --root "$DIR" --to "$T/lanes.json" >/dev/null 2>&1 || { echo "FAIL: lanes-build.sh could not compose the registry"; exit 1; }
export LANE_REGISTRY="$T/lanes.json"
# shellcheck source=/dev/null
. "$DIR/bin/lib/lane-gate.sh" || { echo "FAIL: bin/lib/lane-gate.sh did not source"; exit 1; }
eq "K1 the kill knob is in the registry, default 1" "$(lane_knob merge-conductor MC_QUEUE_RETURN)" 1
eq "K2 the alert limit is in the registry, default 30" "$(lane_knob merge-conductor MC_QUEUE_RETURN_ALERT_MIN)" 30

A="$T/h/state/merge-conductor/attempts.txt"
CLOG="$T/h/logs/merge-conductor.log"
ROWS="$T/h/state/merge-conductor/pr-state.tsv"
SLUG=example-org/mgfy-os
EJECTED='{"name":"Mergify Merge Queue","status":"completed","conclusion":"cancelled","output":{"title":"The pull request has been removed from the queue"}}'
BOT_EVENTS='[{"event":"labeled","label":{"name":"merge-queue"},"actor":{"login":"operator","type":"User"},"created_at":"2026-11-25T21:28:00Z"},{"event":"unlabeled","label":{"name":"merge-queue"},"actor":{"login":"cromford[bot]","type":"Bot"},"created_at":"2026-11-25T23:12:52Z"}]'
PERSON_EVENTS='[{"event":"labeled","label":{"name":"merge-queue"},"actor":{"login":"cromford[bot]","type":"Bot"},"created_at":"2026-11-25T21:28:00Z"},{"event":"unlabeled","label":{"name":"merge-queue"},"actor":{"login":"operator","type":"User"},"created_at":"2026-11-25T23:12:00Z"}]'
touch "$T/h/flags/merge-conductor-actions" "$T/h/flags/merge-conductor-merge"

# fresh <num> <head> — an empty world for one case: no rows, no ledger, no marks.
fresh() {
  N="$1"; H="$2"; K="$SLUG#$N"; U="https://github.com/$SLUG/pull/$N"
  rm -rf "$T/ledger" "$T/h/state/merge-conductor/ready-why"; mkdir -p "$T/ledger"
  : > "$A"; : > "$CLOG"; : > "$ROWS"
  for f in gh-calls label-removes writes merges alerts ledger-puts ledger-lists; do : > "$T/$f.txt"; done
  rm -f "$T/h/flags/main-red-example-org-mgfy-os"
  touch "$T/h/flags/merge-conductor-actions" "$T/h/flags/merge-conductor-merge"
  printf '%s' "$H" > "$T/head"; printf '' > "$T/labels"; printf '' > "$T/checks"; printf '%s' "$BOT_EVENTS" > "$T/events"
  d="$T/h/builds/pool-mgfy-X-$N-202610050000"; mkdir -p "$d"
  echo "PR_CREATED $U" > "$d/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$d/review.md"
  echo "$H" > "$d/reviewed-sha"; : > "$d/pipeline.log"
}
lf() { printf '%s/%s' "$T/ledger" "$(printf '%s' "$1" | tr '/#' '__')"; }
st() { jq -r .status "$(lf "$K")" 2>/dev/null; }
det() { jq -r ".detail | fromjson | $1" "$(lf "$K")" 2>/dev/null; }
# owe <left-at> — an owed row for the case's PR, as mc_qr_owe writes it.
owe() {
  jq -nc --arg k "$K" --arg d "$(jq -nc --arg h "$H" --argjson at "$1" '{left_head: $h, cause: "head-moved", left_at: $at, queued_by: "person:operator", told: []}')" \
    '{kind: "queue_return", key: $k, status: "owed", detail: $d, updated_at: "2026-11-26T00:00:00Z"}' > "$(lf "$K")"
}
OLD=0; YOUNG=99999999999
alerts() { grep -c "$K QUEUE_RETURN" "$T/alerts.txt" || true; }
comments() { grep -c "repos/$SLUG/issues/$N/comments" "$T/writes.txt" || true; }
# A write that queues: the label, or a Mergify command. The pass's own comment
# quotes `@mergifyio queue` as the person's action, so it is left out.
queued_writes() { grep -v 'The merge conductor: this PR' "$T/writes.txt" | grep -cE 'labels\[\]=merge-queue|mergifyio' || true; }
run_tick() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x JOBS_URL=http://jobs.test \
  MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 \
  MC_MERGE_TREE=0 MC_DETACHED_REBASE=0 MC_DETACHED_DEPLOY_VERIFY=0 MC_MAIN_RED_TEST_PATHS="tests/*" \
  bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) || { echo "tick rc=$? stderr:"; tail -5 "$T/tick.err"; }; }

# ============================================================================
# P1 — the settle arm: a QUEUED row whose PR left the queue. Two sightings of
# the same head count the ejection (BH-4562); the label goes; ONE row.
# ============================================================================
fresh 31 aaaaaaaa11112222333344445555666677778888
mc_row_put "$K" QUEUED 1764000000 "$H" "$H" - "in the merge queue" "$U"
printf 'merge-queue' > "$T/labels"; printf '%s' "$EJECTED" > "$T/checks"
run_tick
[ -s "$T/label-removes.txt" ] && ok || bad "P1 fixture: the settle arm must remove the label (log: $(grep -o 'mgfy-os#31 .*' "$CLOG" | head -4))"
# The label read of that tick can be stale (the stub still answers merge-queue):
# the pass must not close the row as back in the queue in the tick of the leave.
eq "P1 the tick of the leave does not read the row" "$(st) $(grep -c "QUEUE_RETURN_CLOSED" "$CLOG" || true)" "owed 0"
printf '' > "$T/labels"; run_tick
eq "P1 one row, status owed" "$(st)" owed
eq "P1 the row names the head and who queued it" "$(det '[.left_head, .queued_by] | join(" ")')" "$H person:operator"
[ -n "$(det '.cause')" ] && ok || bad "P1 the row names a cause"
eq "P1 one OWED log line" "$(grep -c "QUEUE_RETURN_OWED $K ${H:0:8} owed" "$CLOG")" 1
eq "P1 the tick of the leave sends no alert" "$(alerts)" 0

# ============================================================================
# P2 — not back after the limit: ONE alert, ONE comment, in 4 ticks.
# ============================================================================
fresh 32 bbbbbbbb11112222333344445555666677778888
mc_row_put "$K" WAIT_CI 1764000000 "$H" "$H" - "queue-ejected: head-moved" "$U"
owe "$YOUNG"; run_tick
eq "P2 a young row waits" "$(st) $(alerts)" "owed 0"
owe "$OLD"; run_tick; run_tick; run_tick; run_tick
eq "P2 exactly one alert in 4 ticks" "$(alerts)" 1
eq "P2 exactly one PR comment in 4 ticks" "$(comments)" 1
eq "P2 the row stays owed, with the told head and the stale flag" "$(st) $(det '[(.told | join(",")), (.stale | tostring)] | join(" ")')" "owed $H 1"
grep -q "Held on head $H by no gate yet (conductor state WAIT_CI): queue-ejected: head-moved. What clears it: no action: the review lane and CI must pass on head $H" "$T/alerts.txt" && ok || bad "P2 the alert names the hold, the head and what clears it: $(cat "$T/alerts.txt")"
eq "P2 the pass puts nothing in the queue" "$(queued_writes)" 0
eq "P2 one TOLD log line" "$(grep -c "QUEUE_RETURN_TOLD $K ${H:0:8} stale-alert" "$CLOG")" 1

# ============================================================================
# P3 — the #10134 shape: the lead fence holds the live head. ONE alert, at once.
# ============================================================================
fresh 33 cccccccc11112222333344445555666677778888
mc_row_put "$K" READY 1764000000 "$H" "$H" - "held" "$U"
mkdir -p "$T/h/state/merge-conductor/ready-why"
printf '1764000000\t%s\tlead-held\tlead PR: merges only on a lead/human MERGE row on this head\n' "$H" \
  > "$T/h/state/merge-conductor/ready-why/$(mc_handoff_id "$K")"
owe "$YOUNG"; run_tick; run_tick; run_tick
eq "P3 exactly one alert in 3 ticks, before the limit" "$(alerts)" 1
eq "P3 exactly one PR comment" "$(comments)" 1
grep -q "Held on head $H by the lead fence (BH-1606)" "$T/alerts.txt" && ok || bad "P3 the alert names the gate and the head: $(cat "$T/alerts.txt")"
grep -qF "What clears it: a lead or human MERGE on head $H, then \`@mergifyio queue\` on the PR — a repo lead does both" "$T/alerts.txt" && ok || bad "P3 the alert names the one action and who: $(cat "$T/alerts.txt")"
grep -qF "a lead or human MERGE on head $H" "$T/writes.txt" && ok || bad "P3 the PR comment names the same action: $(cat "$T/writes.txt")"
eq "P3 the row stays owed, with the told head" "$(st) $(det '.told | join(",")')" "owed $H"
eq "P3 nothing is put in the queue" "$(queued_writes)" 0

# ============================================================================
# P4 — MC_QUEUE_RETURN=0: no row at the leave, no alert for an owed row.
# ============================================================================
fresh 34 dddddddd11112222333344445555666677778888
mc_row_put "$K" QUEUED 1764000000 "$H" "$H" - "in the merge queue" "$U"
printf 'merge-queue' > "$T/labels"; printf '%s' "$EJECTED" > "$T/checks"
export MC_QUEUE_RETURN=0; run_tick; printf '' > "$T/labels"; run_tick
[ -s "$T/label-removes.txt" ] && ok || bad "P4 fixture: the settle arm must remove the label"
[ ! -e "$(lf "$K")" ] && ok || bad "P4 MC_QUEUE_RETURN=0 must write no row"
printf '' > "$T/labels"; owe "$OLD"; run_tick
eq "P4 MC_QUEUE_RETURN=0 sends no alert and reads no list" "$(alerts) $(grep -c . "$T/ledger-lists.txt" || true)" "0 0"
unset MC_QUEUE_RETURN

# ============================================================================
# P5 — main red: nothing comes back, so nobody is told. Green: one alert.
# ============================================================================
fresh 35 eeeeeeee11112222333344445555666677778888
mc_row_put "$K" WAIT_CI 1764000000 "$H" "$H" - "queue-ejected: head-moved" "$U"
owe "$OLD"
printf 'sha=%s\nsince=2026-10-28T10:00:00Z\nreason=streak\n' "$H" > "$T/h/flags/main-red-example-org-mgfy-os"
run_tick; run_tick
eq "P5 main red: 0 alerts, the row stays owed" "$(alerts) $(st)" "0 owed"
rm -f "$T/h/flags/main-red-example-org-mgfy-os"
run_tick
eq "P5 main green again: 1 alert" "$(alerts)" 1

# ============================================================================
# P6 — the label is back (a person, or the conductor's own arm): done.
# ============================================================================
fresh 36 ffffffff11112222333344445555666677778888
mc_row_put "$K" WAIT_CI 1764000000 "$H" "$H" - "queue-ejected: head-moved" "$U"
owe "$OLD"; printf 'hotfix,queued' > "$T/labels"
run_tick
eq "P6 back in the queue: the row is done, 0 alerts" "$(st) $(alerts)" "done 0"
eq "P6 one CLOSED log line" "$(grep -c "QUEUE_RETURN_CLOSED $K done" "$CLOG")" 1

# ============================================================================
# P7 — a hold label: a person's hold is respected. No alert.
# ============================================================================
fresh 37 abababab11112222333344445555666677778888
mc_row_put "$K" WAIT_CI 1764000000 "$H" "$H" - "queue-ejected: head-moved" "$U"
owe "$OLD"; printf 'hold' > "$T/labels"
run_tick; run_tick
eq "P7 a held PR: the row is released, 0 alerts, 0 comments" "$(st) $(alerts) $(comments)" "released 0 0"

# ============================================================================
# P8 — a person removed the label themselves: released at the leave.
# ============================================================================
fresh 38 cdcdcdcd11112222333344445555666677778888
mc_row_put "$K" QUEUED 1764000000 "$H" "$H" - "in the merge queue" "$U"
printf '' > "$T/labels"; printf '%s' "$EJECTED" > "$T/checks"; printf '%s' "$PERSON_EVENTS" > "$T/events"
run_tick; run_tick; run_tick
eq "P8 a person's own removal is released, never chased" "$(st) $(alerts)" "released 0"

# ============================================================================
# P9 — observe mode (actions off): the pass reads and writes nothing.
# ============================================================================
fresh 39 efefefef11112222333344445555666677778888
mc_row_put "$K" WAIT_CI 1764000000 "$H" "$H" - "queue-ejected: head-moved" "$U"
owe "$OLD"; rm -f "$T/h/flags/merge-conductor-actions" "$T/h/flags/merge-conductor-merge"
run_tick
eq "P9 observe mode: owed, 0 alerts, 0 list reads" "$(st) $(alerts) $(grep -c . "$T/ledger-lists.txt" || true)" "owed 0 0"

# ============================================================================
# R — #10134 REPLAYED in its real event order, with the push guard OFF (knob 0,
# so the builder push reached the branch). tests/hold-push-queued R1 is the
# same replay with the guard ON: the push is refused and nothing below happens.
#   21:28Z a person queues the PR on head H1          -> a QUEUED row, label on
#   23:10Z a builder pushes: the head is now H2       -> Mergify dequeues it
#   23:12Z the conductor tick: the label is removed   -> ONE owed row, head-moved
#   23:17Z a tick before the review answers           -> 0 alerts
#   23:24Z the lane approves H2; the READY arm holds it at the lead fence and
#          writes its ready-why note (the arm's own write, seeded here: this
#          fixture's open list is empty)
#   the NEXT tick                                     -> ONE lead-alert, not
#          after MC_QUEUE_RETURN_ALERT_MIN; 2 more ticks add nothing
# ============================================================================
H2=2222222211112222333344445555666677778888
fresh 134 1111111111112222333344445555666677778888
mc_row_put "$K" QUEUED 1764106080 "$H" "$H" - "in the merge queue" "$U"          # 21:28Z
printf 'merge-queue,queued' > "$T/labels"
printf '%s' "$H2" > "$T/head"; printf 'merge-queue,dequeued' > "$T/labels"; printf '%s' "$EJECTED" > "$T/checks"   # 23:10Z
run_tick                                                                           # 23:12Z
[ -s "$T/label-removes.txt" ] && ok || bad "R fixture: the 23:12Z tick must remove the label (log: $(grep -o 'mgfy-os#134 .*' "$CLOG" | head -4))"
eq "R 23:12Z one owed row for the head that left, cause head-moved, queued by a person" \
  "$(st) $(det '[.left_head, .cause, .queued_by] | join(" ")')" "owed $H head-moved person:operator"
printf 'dequeued' > "$T/labels"
run_tick                                                                           # 23:17Z
eq "R 23:17Z no verdict yet: 0 alerts, still owed" "$(alerts) $(st)" "0 owed"
mkdir -p "$T/h/state/merge-conductor/ready-why"                                    # 23:24Z
mc_row_put "$K" READY 1764113040 "$H2" "$H2" - "lead-held" "$U"
printf '1764113040\t%s\tlead-held\tlead PR: merges only on a lead/human MERGE row on this head\n' "$H2" \
  > "$T/h/state/merge-conductor/ready-why/$(mc_handoff_id "$K")"
run_tick
eq "R one tick after 23:24Z: ONE lead-alert, ONE comment, far before the 30 minute limit" "$(alerts) $(comments)" "1 1"
grep -qF "Held on head $H2 by the lead fence (BH-1606)" "$T/alerts.txt" && ok || bad "R the alert names the new head and the gate: $(cat "$T/alerts.txt")"
grep -qF "a lead or human MERGE on head $H2, then \`@mergifyio queue\`" "$T/alerts.txt" && ok || bad "R the alert names the action: $(cat "$T/alerts.txt")"
run_tick; run_tick
eq "R 2 more ticks: still 1 alert and 1 comment; nothing was put in the queue" "$(alerts) $(comments) $(queued_writes)" "1 1 0"
# One more push: head H3, and the lead fence holds it too. The row is still
# owed, so the new head gets its own alert (a hold comment is one per PR).
H3=3333333311112222333344445555666677778888
printf '%s' "$H3" > "$T/head"
mc_row_put "$K" READY 1764116640 "$H3" "$H3" - "lead-held" "$U"
printf '1764116640\t%s\tlead-held\tlead PR: merges only on a lead/human MERGE row on this head\n' "$H3" \
  > "$T/h/state/merge-conductor/ready-why/$(mc_handoff_id "$K")"
run_tick; run_tick
eq "R a later held head: 1 more alert and 1 more comment in 2 ticks" "$(alerts) $(comments)" "2 2"
grep -qF "a lead or human MERGE on head $H3" "$T/alerts.txt" && ok || bad "R the second alert names head H3: $(cat "$T/alerts.txt")"

echo "queue-return-pass.bh-10201: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
