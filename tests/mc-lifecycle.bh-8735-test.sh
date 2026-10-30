#!/bin/bash
# tests/mc-lifecycle.bh-8735-test.sh — BH-8735 (lifecycle 5/6): the conductor
# writes the ticket phases it owns (in_queue, ejected, merged) through the
# lifecycle API of #8731 (lifecycle_transition), with actor `conductor`.
#
# WHAT RUNS. The shipped fragment bin/merge-conductor.d/bh-8735-lifecycle.sh,
# the real bin/lib/mc-stale-dequeue.sh (sdq_arm), the real conductor_settle
# (bin/lib/mc/settle.sh) and mc_ticket_of_branch, all from a scratch harness.
# Stubs: lifecycle_transition (records its args, answers a scripted rc and
# body), pr_record_get, sdq_payload_last, vd_standing, mc_requeue_mergify.
# A fake gh and curl count any call that would leave the box.
#
#   L1      mclc_put sends project, ticket key, phase, actor, reason, pr
#   L2-L4   sdq_arm: a Mergify `dequeued` payload with the merge-queue label
#           still on writes `ejected` once per payload comment (the decision
#           table in the plan's Failure modes, cases a-j)
#   L5      the branch table: a non-build branch makes no call
#   L6      no lifecycle API (#8731 not merged): rc 0, 0 calls, 0 log lines
#   L7      the rc map: refused (once per key, phase, head), current == to,
#           no row, unreachable; STATE and WHY do not change
#   L8      MC_LIFECYCLE_WRITE=0 writes nothing; unset is on
#   L9      a 700-character reason with tabs goes as 500 characters, no tab;
#           MC_LIFECYCLE_REASON_MAX sets the cut; 0 gh/curl calls in the suite
#   L10-L12 conductor_settle writes `merged` only with a merged pr_record
#   L15     a record that says open (the conductor's own queue_state PUT made
#           it look new) is read once more with PR_RECORD_FRESH=1; GitHub's
#           merged writes the phase
#   L16     mc_transition in the same state mirrors a new reason or head into
#           the pr_state ledger (no event row); an unchanged row writes none
#   L13     sdq_arm's own requeue writes `in_queue` after the `ejected`
#   L14     the lifecycle lib is sourced from $H/bin/lib/jobs/lifecycle.sh
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/mc-lifecycle.bh-8735-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }
command -v jq >/dev/null 2>&1 || { echo "mc-lifecycle: jq missing — skipping"; exit 0; }

FRAG="$DIR/bin/merge-conductor.d/bh-8735-lifecycle.sh"
[ -f "$FRAG" ] || { bad "the fragment bin/merge-conductor.d/bh-8735-lifecycle.sh does not exist"; echo "mc-lifecycle (BH-8735): $PASS passed, $FAIL failed"; exit 1; }

H="$T/h"
mkdir -p "$H/logs" "$H/state" "$H/flags" "$H/locks" "$H/env" "$H/tmp" "$T/fakebin"
scratch_install_closure bin/merge-conductor.sh "$H" >/dev/null || { echo "FAIL: closure of bin/merge-conductor.sh"; exit 1; }
scratch_install_closure bin/merge-conductor.d/bh-8735-lifecycle.sh "$H" >/dev/null || { echo "FAIL: closure of the fragment"; exit 1; }
: > "$H/env/global.env"
for w in gh curl; do
  printf '#!/bin/bash\nprintf "%s %%s\\n" "$*" >> "%s/vendor.log"\nexit 1\n' "$w" "$T" > "$T/fakebin/$w"
  chmod +x "$T/fakebin/$w"
done
export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=x JOBS_URL=http://worker.test
# shellcheck source=/dev/null
. "$H/bin/lib/merge-conductor-lib.sh" || { echo "FAIL: merge-conductor-lib.sh does not source"; exit 1; }
mc_init
# shellcheck source=/dev/null
. "$H/bin/lib/mc-stale-dequeue.sh" || { echo "FAIL: mc-stale-dequeue.sh does not source"; exit 1; }
# shellcheck source=bin/merge-conductor.d/bh-8735-lifecycle.sh
. "$H/bin/merge-conductor.d/bh-8735-lifecycle.sh" || { echo "FAIL: the fragment does not source"; exit 1; }
CLOG="$MC_LOG"
: > "$T/vendor.log"

# ---- the lifecycle API stub (#8731's documented contract) -----------------
# lifecycle_transition <project> <ticket_key> <to_phase> <actor> <reason> [pr] [question]
#   rc 0 moved, 9 = 409, 2 = no build_queue row, 1 = transport, 3 = bad args;
#   the answer body on stdout.
lifecycle_transition() {
  local IFS=$'\t'
  printf '%s\n' "$*" >> "$T/lc.calls"
  [ -f "$T/lc.body" ] && cat "$T/lc.body"
  return "$(cat "$T/lc.rc" 2>/dev/null || echo 0)"
}
lc_reset() { : > "$T/lc.calls"; echo 0 > "$T/lc.rc"; printf '{"ok":true}' > "$T/lc.body"; : > "$CLOG"; : > "$MC_ATTEMPTS"; }
calls() { grep -c . "$T/lc.calls" | tr -d ' '; }
call_of() { sed -n "${1}p" "$T/lc.calls"; }
logn() { grep -c -- "$1" "$CLOG" | tr -d ' '; }

SHA1=1111111111111111111111111111111111111111
SHA2=2222222222222222222222222222222222222222

# ============================================================================
# L1 — the call.
# ============================================================================
lc_reset
mclc_put in_queue cromford example-org/cromford ticket/bh-9001 9001 "$SHA1" x; RC=$?
eq "L1 rc" "$RC" 0
eq "L1 one call" "$(calls)" 1
eq "L1 the args" "$(call_of 1)" "$(printf 'cromford\tBH-9001\tin_queue\tconductor\tx\t9001')"
eq "L1 one LIFECYCLE line" "$(logn "LIFECYCLE example-org/cromford#9001 BH-9001 -> in_queue")" 1

# ============================================================================
# L2-L4 — sdq_arm on a dequeued payload.
# ============================================================================
# sdq <payload-line|rc1|rc2> <labels> — one sdq_arm call as pr_worker makes it:
# no fresh verdict, so sdq_decide answers none and the row is left alone.
sdq() {
  SDQ_PL="$1"
  sdq_payload_last() { case "$SDQ_PL" in rc1) return 1 ;; rc2) return 2 ;; esac; printf '%s\n' "$SDQ_PL"; }
  vd_standing() { return 1; }
  P=cromford SLUG=example-org/cromford NUM=9002 KEY='example-org/cromford#9002' HEAD="$SHA1"
  URL=https://github.com/example-org/cromford/pull/9002 BR=ticket/bh-9002 RAWLBL="$2"
  VERDICT="" REVIEWED="" MERGES=1 MGABLE=MERGEABLE MSTATE=CLEAN CI=green STATE=QUEUED WHY=w0
  sdq_arm
}
PT=1792497600
lc_reset
sdq "$(printf 'dequeued\t%s\t501' "$PT")" merge-queue
eq "L2 (a) dequeued + merge-queue: one call" "$(calls)" 1
eq "L2 the phase is ejected, actor conductor, pr 9002" "$(call_of 1 | cut -f2-4,6)" "$(printf 'BH-9002\tejected\tconductor\t9002')"
case "$(call_of 1 | cut -f5)" in
  "mergify dequeued at "*"merge-queue label still on"*) ok ;;
  *) bad "L2 the reason names the dequeue: $(call_of 1 | cut -f5)" ;;
esac
eq "L2 sdq_arm leaves STATE and WHY" "$STATE/$WHY" "QUEUED/w0"
grep -qxF "lcdequeue example-org/cromford#9002 $SHA1 501" "$MC_ATTEMPTS" && ok || bad "L2 the lcdequeue mark: $(cat "$MC_ATTEMPTS")"
# L3 — the same comment id again: no second call. A new id: one more.
sdq "$(printf 'dequeued\t%s\t501' "$PT")" merge-queue
eq "L3 (h) the same comment id: no second call" "$(calls)" 1
sdq "$(printf 'dequeued\t%s\t777' "$((PT+600))")" merge-queue
eq "L3 (c) a new comment id on the same head: one more call" "$(calls)" 2
lc_reset
sdq "$(printf 'dequeued\t%s\t502' "$PT")" merge-queue,dequeued
eq "L2 (b) dequeued + merge-queue,dequeued: one call" "$(calls)" 1
# L4 — the negatives.
for c in "d|dequeued|merge-queue,queued" "e|dequeued|merge-queue,checking" "f1|queued|merge-queue" "f2|checking|merge-queue" \
         "f3|merged|merge-queue" "g|dequeued|dequeued" "j|Dequeued|merge-queue"; do
  IFS='|' read -r id st lbl <<<"$c"
  lc_reset
  sdq "$(printf '%s\t%s\t60%s' "$st" "$PT" "${#id}")" "$lbl"
  eq "L4 ($id) payload $st, labels $lbl: no call" "$(calls)" 0
done
for c in rc1 rc2; do
  lc_reset; sdq "$c" merge-queue
  eq "L4 (i) sdq_payload_last $c: no call" "$(calls)" 0
done

# ============================================================================
# L5 — the branch table.
# ============================================================================
lc_reset
mclc_put in_queue cromford example-org/cromford ticket/bh-8735-r3 8735 "$SHA1" x
eq "L5 ticket/bh-8735-r3 is BH-8735" "$(call_of 1 | cut -f2)" BH-8735
for br in mergify/merge-queue/x design/foo main ""; do
  lc_reset
  mclc_put in_queue cromford example-org/cromford "$br" 1 "$SHA1" x; RC=$?
  eq "L5 branch '$br': rc 0 and no call" "$RC/$(calls)" "0/0"
done

# ============================================================================
# L6 — no lifecycle API and no lib file.
# ============================================================================
lc_reset
OUT=$( unset -f lifecycle_transition; rm -f "$H/bin/lib/jobs/lifecycle.sh"
       mclc_put in_queue cromford example-org/cromford ticket/bh-9006 9006 "$SHA1" x; echo "rc=$?" )
eq "L6 no API: rc 0" "$OUT" "rc=0"
eq "L6 no API: 0 calls" "$(calls)" 0
eq "L6 no API: 0 log lines" "$(grep -c . "$CLOG" | tr -d ' ')" 0

# ============================================================================
# L7 — the rc map.
# ============================================================================
lc_reset
STATE=READY; WHY=keep
echo 9 > "$T/lc.rc"; printf '{"error":"wrong_owner","current":"pr_open","to":"in_queue"}' > "$T/lc.body"
for _ in 1 2 3; do mclc_put in_queue cromford example-org/cromford ticket/bh-9007 9007 "$SHA1" x; done
eq "L7 refused: three calls" "$(calls)" 3
eq "L7 refused: exactly one LIFECYCLE_REFUSED line" "$(logn 'LIFECYCLE_REFUSED example-org/cromford#9007 BH-9007 in_queue wrong_owner current=pr_open')" 1
eq "L7 refused: no LIFECYCLE success line" "$(logn 'LIFECYCLE example-org')" 0
grep -qxF "lcrefused example-org/cromford#9007 in_queue $SHA1" "$MC_ATTEMPTS" && ok || bad "L7 the lcrefused mark: $(cat "$MC_ATTEMPTS")"
mclc_put in_queue cromford example-org/cromford ticket/bh-9007 9007 "$SHA2" x
eq "L7 refused on a new head: one more line" "$(logn 'LIFECYCLE_REFUSED example-org/cromford#9007')" 2
: > "$CLOG"
printf '{"error":"illegal","current":"in_queue","to":"in_queue"}' > "$T/lc.body"
mclc_put in_queue cromford example-org/cromford ticket/bh-9008 9008 "$SHA1" x
eq "L7 current == to: no line" "$(grep -c . "$CLOG" | tr -d ' ')" 0
echo 2 > "$T/lc.rc"; printf '{"error":"no row"}' > "$T/lc.body"
mclc_put in_queue cromford example-org/cromford ticket/bh-9009 9009 "$SHA1" x
eq "L7 rc 2 (no build_queue row): no line" "$(grep -c . "$CLOG" | tr -d ' ')" 0
echo 1 > "$T/lc.rc"; : > "$T/lc.body"
mclc_put in_queue cromford example-org/cromford ticket/bh-9010 9010 "$SHA1" x; RC=$?
eq "L7 rc 1: rc 0 and one LIFECYCLE_UNREACHABLE line" "$RC/$(logn 'LIFECYCLE_UNREACHABLE example-org/cromford#9010 BH-9010 in_queue')" "0/1"
echo 3 > "$T/lc.rc"
mclc_put in_queue cromford example-org/cromford ticket/bh-9011 9011 "$SHA1" x
eq "L7 rc 3: one LIFECYCLE_UNREACHABLE line" "$(logn 'LIFECYCLE_UNREACHABLE example-org/cromford#9011')" 1
eq "L7 STATE and WHY do not change" "$STATE/$WHY" "READY/keep"
eq "L7 no alert line" "$(grep -ci 'alert' "$CLOG" | tr -d ' ')" 0

# ============================================================================
# L8 — the knob.
# ============================================================================
lc_reset
MC_LIFECYCLE_WRITE=0 mclc_put in_queue cromford example-org/cromford ticket/bh-9012 9012 "$SHA1" x
eq "L8 MC_LIFECYCLE_WRITE=0: 0 calls" "$(calls)" 0
( unset MC_LIFECYCLE_WRITE; mclc_put in_queue cromford example-org/cromford ticket/bh-9012 9012 "$SHA1" x )
eq "L8 unset: on (1 call)" "$(calls)" 1

# ============================================================================
# L9 — the reason.
# ============================================================================
lc_reset
LONG=$(printf 'a\tb%.0s' $(seq 1 234))   # 702 characters, 234 tabs
mclc_put ejected cromford example-org/cromford ticket/bh-9013 9013 "$SHA1" "$LONG"$'\nline2'
R=$(call_of 1 | cut -f5- | rev | cut -f2- | rev)   # the reason field: everything between actor and pr
eq "L9 the reason is cut to 500 characters" "${#R}" 500
case "$R" in *$'\t'*|*$'\n'*) bad "L9 the reason holds a tab or newline" ;; *) ok ;; esac
eq "L9 the pr field is still the last one" "$(call_of 1 | awk -F'\t' '{print $NF}')" 9013
lc_reset
MC_LIFECYCLE_REASON_MAX=40 mclc_put ejected cromford example-org/cromford ticket/bh-9013 9013 "$SHA1" "$LONG"
eq "L9 MC_LIFECYCLE_REASON_MAX=40" "$(call_of 1 | cut -f5 | wc -c | tr -d ' ')" 41
lc_reset
MC_LIFECYCLE_REASON_MAX=abc mclc_put ejected cromford example-org/cromford ticket/bh-9013 9013 "$SHA1" "$LONG"
eq "L9 a bad MC_LIFECYCLE_REASON_MAX is 500" "$(call_of 1 | cut -f5 | wc -c | tr -d ' ')" 501

# ============================================================================
# L10-L12 — conductor_settle and the merged gate.
# ============================================================================
mc_stack_children() { :; }
mc_alert() { :; }
settle() { # settle <num> — one conductor_settle of a queue landing
  conductor_settle "example-org/cromford#$1" "https://github.com/example-org/cromford/pull/$1" cromford \
    example-org/cromford "ticket/bh-$1" "" job-1 "$SHA1" "$SHA1" APPROVE CLEAN "by:conductor (merge queue)"
}
lc_reset
pr_record_get() { printf '%s %s %s\n' "$@" >> "$T/prr.calls"; printf '{"state":"merged","head_sha":"%s"}\n' "$SHA1"; }
MERGES=0 settle 9014
eq "L10 a merged record: one call" "$(calls)" 1
eq "L10 the phase is merged, key BH-9014, pr 9014" "$(call_of 1 | cut -f2,3,4,6)" "$(printf 'BH-9014\tmerged\tconductor\t9014')"
grep -qx 'example-org/cromford 9014 state' "$T/prr.calls" && ok || bad "L10 pr_record_get asked for the state: $(cat "$T/prr.calls")"
eq "L10 the MERGED row is written" "$(awk -F'\t' '$1 == "example-org/cromford#9014" {print $2}' "$MC_ROWS")" MERGED
for c in "open|0" "closed|0" "null|0" "-|75" "-|44" "-|2" "notjson|0"; do
  IFS='|' read -r st rc <<<"$c"
  lc_reset
  PRR_ST="$st" PRR_RC="$rc"
  pr_record_get() { [ "$PRR_RC" = 0 ] || return "$PRR_RC"
    case "$PRR_ST" in notjson) echo 'not json' ;; null) echo '{"state":null}' ;; *) printf '{"state":"%s"}\n' "$PRR_ST" ;; esac; }
  MERGES=0 settle 9015
  eq "L11 record state=$st rc=$rc: no call" "$(calls)" 0
  eq "L11 record state=$st rc=$rc: one LIFECYCLE_MERGED_UNPROVEN line" "$(logn 'LIFECYCLE_MERGED_UNPROVEN example-org/cromford#9015')" 1
done
lc_reset
OUT=$( unset -f pr_record_get; HARNESS="" H=""; MERGES=0 settle 9016; calls )
eq "L11 no pr_record_get and no lib to load: no call" "$OUT" 0
eq "L11 no pr_record_get: state=unreadable" "$(logn 'LIFECYCLE_MERGED_UNPROVEN example-org/cromford#9016 state=unreadable')" 1
lc_reset
pr_record_get() { printf '{"state":"merged"}\n'; }
MC_ON_MACHINE=1 MERGES=0 settle 9017
eq "L12 MC_ON_MACHINE=1: no call" "$(calls)" 0

# ============================================================================
# L15 — the stale `open` row after the conductor's own PUT: one forced read.
# ============================================================================
lc_reset; : > "$T/prr.calls"
pr_record_get() { printf '%s %s %s fresh=%s\n' "$@" "${PR_RECORD_FRESH:-0}" >> "$T/prr.calls"
  if [ "${PR_RECORD_FRESH:-0}" = 1 ]; then echo '{"state":"merged"}'; else echo '{"state":"open"}'; fi; }
MERGES=0 settle 9020
eq "L15 two reads: the record, then GitHub forced" "$(cat "$T/prr.calls")" \
  "$(printf 'example-org/cromford 9020 state fresh=0\nexample-org/cromford 9020 state fresh=1')"
eq "L15 the merged phase is written" "$(call_of 1 | cut -f2,3)" "$(printf 'BH-9020\tmerged')"
eq "L15 no LIFECYCLE_MERGED_UNPROVEN line" "$(logn 'LIFECYCLE_MERGED_UNPROVEN example-org/cromford#9020')" 0
lc_reset; : > "$T/prr.calls"
pr_record_get() { printf 'x\n' >> "$T/prr.calls"; echo '{"state":"merged"}'; }
MERGES=0 settle 9021
eq "L15 a merged record: one read, no forced read" "$(grep -c . "$T/prr.calls" | tr -d ' ')" 1

# ============================================================================
# L16 — the same-state ledger mirror.
# ============================================================================
OUT=$( job_ledger_put() { printf 'L %s %s %s %s\n' "$1" "$2" "$3" "$(jq -r '.reason + " " + .head_sha' <<<"$4")" >> "$T/jl.calls"; }
       mc_state_event_put() { printf 'E\n' >> "$T/jl.calls"; }
       : > "$T/jl.calls"
       K='example-org/cromford#9022'
       mc_transition "$K" BLOCKED_HUMAN conflict-unresolvable "$SHA1" "$SHA1" u APPROVE DIRTY - >/dev/null
       mc_transition "$K" BLOCKED_HUMAN conflict-unresolvable "$SHA1" "$SHA1" u APPROVE DIRTY - >/dev/null
       mc_transition "$K" BLOCKED_HUMAN head-not-reapproved "$SHA1" "$SHA1" u APPROVE DIRTY - >/dev/null
       mc_transition "$K" BLOCKED_HUMAN head-not-reapproved "$SHA2" "$SHA1" u APPROVE DIRTY - >/dev/null
       cat "$T/jl.calls" )
eq "L16 a change writes ledger + event; a no-op writes none; a re-reason and a new head write the ledger only" "$OUT" \
  "$(printf 'L pr_state example-org/cromford#9022 BLOCKED_HUMAN conflict-unresolvable %s\nE\nL pr_state example-org/cromford#9022 BLOCKED_HUMAN head-not-reapproved %s\nL pr_state example-org/cromford#9022 BLOCKED_HUMAN head-not-reapproved %s' "$SHA1" "$SHA1" "$SHA2")"

# ============================================================================
# L13 — sdq_arm's own requeue writes in_queue after the ejected.
# ============================================================================
lc_reset
sdq_head_pushed_epoch() { echo $((PT + 900)); }
mc_requeue_mergify() { return 0; }
mc_tick_budget_take() { return 0; }
mc_ejected_hold() { return 1; }
mc_eject_culprit_mark() { return 1; }
unset -f ec_requeue_gate 2>/dev/null
SDQ_PL="$(printf 'dequeued\t%s\t901' "$PT")"
sdq_payload_last() { printf '%s\n' "$SDQ_PL"; }
P=cromford SLUG=example-org/cromford NUM=9018 KEY='example-org/cromford#9018' HEAD="$SHA2"
URL=https://github.com/example-org/cromford/pull/9018 BR=ticket/bh-9018 RAWLBL=merge-queue
VERDICT=APPROVE REVIEWED="$SHA2" MERGES=1 MGABLE=MERGEABLE MSTATE=CLEAN CI=green STATE=READY WHY=w
sdq_arm
eq "L13 the requeue: STATE QUEUED" "$STATE" QUEUED
eq "L13 two calls: ejected, then in_queue" "$(cut -f3 "$T/lc.calls" | tr '\n' ' ')" "ejected in_queue "
lc_reset
mc_requeue_mergify() { return 3; }
mc_attempt_clear requeued "$KEY" "$SHA2" 2>/dev/null
HEAD="$SHA1" REVIEWED="$SHA1" STATE=READY
SDQ_PL="$(printf 'dequeued\t%s\t902' "$PT")"
sdq_arm
eq "L13 requeue rc 3 (no witness): no in_queue call" "$(cut -f3 "$T/lc.calls" | tr '\n' ' ')" "ejected "

# ============================================================================
# L14 — the lib file is sourced when the function is not defined.
# ============================================================================
mkdir -p "$H/bin/lib/jobs"
printf 'lifecycle_transition() { printf "lib %%s\\n" "$3" >> "%s/lib.calls"; return 0; }\n' "$T" > "$H/bin/lib/jobs/lifecycle.sh"
OUT=$( unset -f lifecycle_transition
       mclc_put merged cromford example-org/cromford ticket/bh-9019 9019 "$SHA1" x
       mclc_put ejected cromford example-org/cromford ticket/bh-9019 9019 "$SHA1" x
       cat "$T/lib.calls" 2>/dev/null )
eq "L14 the lib is sourced once and called twice" "$OUT" "$(printf 'lib merged\nlib ejected')"
rm -f "$H/bin/lib/jobs/lifecycle.sh"

eq "L9 0 gh/curl calls in the whole suite" "$(grep -c . "$T/vendor.log" | tr -d " ")" 0; [ -s "$T/vendor.log" ] && cat "$T/vendor.log"

echo "mc-lifecycle (BH-8735): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
