#!/bin/bash
# tests/mc/queue-return-decide.bh-10201-test.sh — BH-10201: the PURE functions
# of bin/merge-conductor.d/bh-10201-queue-return.sh, as tables, and mc_qr_owe /
# _mc_qr_tell over stubbed verbs.
#
# The fragment keeps a record of a PR that left the merge queue and tells one
# person when it does not come back. It never puts a PR in the queue: the
# re-entry arm and the READY arm of the conductor own that, with their gates.
#   D1-D16  mc_qr_decide, one case per rule and per rule order
#   S1-S7   mc_qr_owe_status
#   E1-E8   mc_qr_events_read
#   O1-O6   mc_qr_owe: the row, the told heads carried over, the kill knob
#   C1-C8   mc_qr_clears: the hold and the one action that clears it
#   T1-T3   _mc_qr_tell: the mark before the alert; no mark, no alert
#   Z1      the fragment names no requeue or enqueue verb
#
# MUTATIONS this suite must catch (each makes at least one case red):
#   M1 answer `stale-alert` before `done`              -> D2, D3, D4
#   M2 ignore the told flag                            -> D8
#   M10 send the stale alert again on each tick        -> D17
#   M3 alert while main is red                         -> D9, D10
#   M4 treat a bot's label removal as a person's       -> E3
#   M5 a red batch gets status owed                    -> S1, S2, S3
#   M6 drop the told heads at a second leave           -> O3
#   M7 send the alert before the told mark is written  -> T2
#   M8 ignore MC_QUEUE_RETURN=0                        -> O5
#   M9 call mc_requeue_mergify from the fragment       -> Z1
# No clock, no network: mc_now is a stub. Each case seeds its own state.
# Run from anywhere: tests/mc/queue-return-decide.bh-10201-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/../lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/../.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }
command -v jq >/dev/null || { echo "FAIL: jq missing"; exit 1; }
unset MC_QUEUE_RETURN MC_QUEUE_RETURN_ALERT_MIN MC_MERGIFY_LABEL

FRAG="$DIR/bin/merge-conductor.d/bh-10201-queue-return.sh"
[ -r "$FRAG" ] || { echo "FAIL: $FRAG is missing"; exit 1; }
# shellcheck source=/dev/null
. "$FRAG" || { echo "FAIL: the fragment did not source"; exit 1; }
TAB=$'\t'

# ============================================================================
# D — mc_qr_decide <pr-state> <in-queue> <row-state> <hold> <main-red>
#                  <ready-why-kind> <age-min> <alert-min> <told>
# ============================================================================
d() { mc_qr_decide "$@"; }
eq "D1 merged PR"                         "$(d MERGED 0 WAIT_CI 0 0 '' 99 30 0)" done
eq "D2 closed PR, even when stale"        "$(d CLOSED 0 WAIT_CI 0 0 lead-held 99 30 0)" done
eq "D3 a queue label is back"             "$(d OPEN 1 READY 0 0 lead-held 99 30 0)" done
eq "D4 the conductor row is QUEUED"       "$(d OPEN 0 QUEUED 0 0 '' 99 30 0)" done
eq "D5 the PR could not be read"          "$(d '' 0 WAIT_CI 0 0 lead-held 99 30 0)" wait
eq "D6 a hold beats every alert"          "$(d OPEN 0 READY 1 0 lead-held 99 30 0)" released
eq "D7 a hold beats the told flag"        "$(d OPEN 0 READY 1 0 '' 99 30 1)" released
eq "D8 a told head gets nothing more"     "$(d OPEN 0 READY 0 0 lead-held 99 30 1)" told
eq "D9 main red: no lead alert"           "$(d OPEN 0 READY 0 1 lead-held 99 30 0)" wait
eq "D10 main red: no stale alert"         "$(d OPEN 0 WAIT_CI 0 1 '' 99 30 0)" wait
# The #10134 shape: the head moved, the lane approved it, the lead fence holds it.
eq "D11 lead-held on the live head"       "$(d OPEN 0 READY 0 0 lead-held 0 30 0)" lead-alert
eq "D12 not due yet"                      "$(d OPEN 0 HEAD_MOVED 0 0 '' 29 30 0)" wait
eq "D13 due at the limit"                 "$(d OPEN 0 HEAD_MOVED 0 0 '' 30 30 0)" stale-alert
eq "D14 another hold kind waits, then stale" "$(d OPEN 0 READY 0 0 dep-hold 45 30 0)" stale-alert
eq "D15 alert-min 0 switches the stale alert off" "$(d OPEN 0 WAIT_CI 0 0 '' 9999 0 0)" wait
eq "D17 the stale alert of this leave was sent"    "$(d OPEN 0 WAIT_CI 0 0 '' 99 30 0 1)" wait
eq "D18 a later head the lead fence holds is told again" "$(d OPEN 0 READY 0 0 lead-held 99 30 0 1)" lead-alert
eq "D16 a bad age and a bad limit read as 0 and 30" "$(d OPEN 0 WAIT_CI 0 0 '' x y 0)" wait

# ============================================================================
# S — mc_qr_owe_status <cause> <person-removed>
# ============================================================================
eq "S1 failing checks stay with the ladder" "$(mc_qr_owe_status checks 0)" ladder
eq "S2 a red merge_group build"             "$(mc_qr_owe_status batch-red 0)" ladder
eq "S3 a checks timeout"                    "$(mc_qr_owe_status timeout 0)" ladder
eq "S4 the head moved"                      "$(mc_qr_owe_status head-moved 0)" owed
eq "S5 a base conflict"                     "$(mc_qr_owe_status conflict 0)" owed
eq "S6 a standing changes-requested review" "$(mc_qr_owe_status review 0)" released
eq "S7 a person removed the label"          "$(mc_qr_owe_status head-moved 1)" released
eq "S7 no cause named"                      "$(mc_qr_owe_status '' 0)" owed

# ============================================================================
# E — mc_qr_events_read <label>, stdin the issue events
# ============================================================================
ev() { # ev <event> <label> <login> <type> <at>
  printf '{"event":"%s","label":{"name":"%s"},"actor":{"login":"%s","type":"%s"},"created_at":"%s"}' "$@"
}
er() { mc_qr_events_read merge-queue <<<"$1"; }
P_ON=$(ev labeled merge-queue operator User 2026-11-25T21:28:00Z)
B_ON=$(ev labeled merge-queue 'cromford[bot]' Bot 2026-11-25T21:28:00Z)
B_OFF=$(ev unlabeled merge-queue 'cromford[bot]' Bot 2026-11-25T23:12:52Z)
P_OFF=$(ev unlabeled merge-queue operator User 2026-11-25T23:12:00Z)
P_ON2=$(ev labeled merge-queue operator User 2026-11-25T23:30:00Z)
OTHER=$(ev unlabeled hotfix operator User 2026-11-25T23:40:00Z)
eq "E1 a person queued it, the conductor removed the label" "$(er "[$P_ON,$B_OFF]")" "0${TAB}person:operator"
eq "E2 the conductor queued it and removed the label"       "$(er "[$B_ON,$B_OFF]")" "0${TAB}conductor"
eq "E3 a bot removal is never a person's"                   "$(er "[$B_ON,$B_OFF,$OTHER]")" "0${TAB}conductor"
eq "E4 a person removed the label"                          "$(er "[$B_ON,$P_OFF]")" "1${TAB}conductor"
eq "E5 a person removed it and put it back"                 "$(er "[$B_ON,$P_OFF,$P_ON2]")" "0${TAB}person:operator"
eq "E6 no label event"                                      "$(er "[$OTHER]")" "0${TAB}unknown"
eq "E7 not an array"                                        "$(er '{"message":"boom"}')" "0${TAB}unknown"
FULL=$(jq -nc --argjson e "$P_OFF" '[range(0;300) | $e]')
eq "E8 a read cut at its limit is not the whole thread"     "$(er "$FULL")" "0${TAB}unknown"
eq "E8 the same events under the limit are read"            "$(jq -nc --argjson e "$P_OFF" '[range(0;299) | $e]' | mc_qr_events_read merge-queue 300)" "1${TAB}unknown"

# ============================================================================
# C — mc_qr_clears <row-state> <ready-why-kind> <head>: the exact hold and the
# ONE action that clears it, with who can do it.
# ============================================================================
CH=bbbbbbbb11112222333344445555666677778888
cg() { mc_qr_clears "$@" | cut -f1; }
cf() { mc_qr_clears "$@" | cut -f2; }
eq "C1 lead-held names the lead fence" "$(cg READY lead-held "$CH")" "the lead fence (BH-1606)"
eq "C1 lead-held names the action, the full head and who" "$(cf READY lead-held "$CH")" \
  "a lead or human MERGE on head $CH, then \`@mergifyio queue\` on the PR — a repo lead does both"
eq "C2 a dependency hold" "$(cg READY dep-hold "$CH")" "the PR-dependency gate"
eq "C3 the kind beats the row state" "$(cg BLOCKED_HUMAN iron-law "$CH")" "the iron-law scan"
eq "C4 no kind: a head that waits for review" "$(cg HEAD_MOVED '' "$CH")" "no gate yet (conductor state HEAD_MOVED)"
eq "C5 no kind: a park" "$(cg BLOCKED_HUMAN '' "$CH")" "a conductor park (state BLOCKED_HUMAN)"
eq "C6 no kind: READY" "$(cg READY '' "$CH")" "a READY-arm hold with no recorded kind"
eq "C7 no row at all" "$(cg '' '' "$CH")" "no conductor row for this PR (state none)"
for k in lead-held lead-unread dep-hold main-red iron-law migration provenance ''; do
  for r in HEAD_MOVED WAIT_CI BLOCKED_HUMAN STACKED_WAIT READY ''; do
    [ -n "$(cg "$r" "$k" "$CH")" ] && [ -n "$(cf "$r" "$k" "$CH")" ] && ok || bad "C8 ($r, $k) must name a hold and an action"
  done
done

# ============================================================================
# O — mc_qr_owe over stubbed verbs. The ledger is one file per key.
# ============================================================================
K='example-org/demo-os#134'; H1=aaaaaaaa11112222333344445555666677778888; H2=bbbbbbbb11112222333344445555666677778888
LED="$T/ledger"; LOG="$T/mc.log"; PUT_RC=0
fresh() { rm -rf "$T/ledger"; mkdir -p "$LED"; : > "$LOG"; : > "$T/alerts.txt"; : > "$T/writes.txt"; : > "$T/order.txt"; PUT_RC=0; EVENTS="[$P_ON,$B_OFF]"; }
lf() { printf '%s/%s' "$LED" "$(printf '%s' "$1" | tr '/#' '__')"; }
mc_log() { printf '%s\n' "$*" >> "$LOG"; }
mc_now() { printf '1764100000'; }
mc_rest_var() { printf -v "$1" '%s' "$EVENTS"; return 0; }
gh_rest_issue_events() { :; }
job_ledger_put() { # <kind> <key> <status> <detail>
  [ "$PUT_RC" = 0 ] || return "$PUT_RC"
  echo "put $3" >> "$T/order.txt"
  jq -nc --arg s "$3" --arg d "$4" '{status: $s, detail: $d}' > "$(lf "$2")"
}
job_ledger_row() { [ -r "$(lf "$2")" ] || return 2; cat "$(lf "$2")"; }
mc_alert() { echo "alert" >> "$T/order.txt"; printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$T/alerts.txt"; }
mc_issue_comment() { echo "comment" >> "$T/order.txt"; printf '%s#%s\t%s\n' "$1" "$2" "$3" >> "$T/writes.txt"; }
st() { jq -r .status "$(lf "$K")" 2>/dev/null; }
det() { jq -r ".detail | fromjson | $1" "$(lf "$K")" 2>/dev/null; }

fresh; mc_qr_owe example-org/demo-os "$K" "$H1" head-moved
eq "O1 the row is owed" "$(st)" owed
eq "O1 the row names the head, the cause, the time and who queued it" \
  "$(det '[.left_head, .cause, (.left_at | tostring), .queued_by, (.told | length | tostring)] | join(" ")')" \
  "$H1 head-moved 1764100000 person:operator 0"
eq "O1 one log line" "$(grep -c "^QUEUE_RETURN_OWED $K ${H1:0:8} owed " "$LOG")" 1

fresh; mc_qr_owe example-org/demo-os "$K" "$H1" checks
eq "O2 a red batch is recorded for the ladder" "$(st)" ladder

fresh
jq -nc --arg d "$(jq -nc --arg h "$H1" '{left_head: $h, cause: "head-moved", left_at: 1, queued_by: "conductor", told: [$h]}')" \
  '{status: "told", detail: $d}' > "$(lf "$K")"
mc_qr_owe example-org/demo-os "$K" "$H2" conflict
eq "O3 a second leave is owed again" "$(st)" owed
eq "O3 the told heads survive the second leave" "$(det '.told | join(",")')" "$H1"
eq "O3 the new leave replaces the head and the cause" "$(det '[.left_head, .cause] | join(" ")')" "$H2 conflict"

fresh; EVENTS="[$B_ON,$P_OFF]"; mc_qr_owe example-org/demo-os "$K" "$H1" unknown
eq "O4 a person's own removal is released at once" "$(st)" released

fresh; MC_QUEUE_RETURN=0 mc_qr_owe example-org/demo-os "$K" "$H1" head-moved
[ ! -e "$(lf "$K")" ] && ok || bad "O5 MC_QUEUE_RETURN=0 must write no row"
[ ! -s "$LOG" ] && ok || bad "O5 MC_QUEUE_RETURN=0 must log nothing: $(cat "$LOG")"

fresh; PUT_RC=1; mc_qr_owe example-org/demo-os "$K" "$H1" head-moved; RC=$?
eq "O6 a ledger that does not answer never fails the settle arm" "$RC" 0
eq "O6 and the log says the leave is not watched" "$(grep -c "QUEUE_RETURN_OWED $K ${H1:0:8} NOT recorded" "$LOG")" 1

# ============================================================================
# T — _mc_qr_tell <slug> <key> <live-head> <word> <detail-json> <text>
# ============================================================================
D0=$(jq -nc --arg h "$H1" '{left_head: $h, cause: "head-moved", left_at: 1, queued_by: "person:operator", told: []}')
fresh; _mc_qr_tell example-org/demo-os "$K" "$H2" lead-alert "$D0" "left the merge queue and is held"
eq "T1 the row stays owed, with the told head and no stale flag" "$(st) $(det '[(.told | join(",")), (.stale // 0 | tostring)] | join(" ")')" "owed $H2 0"
eq "T1 one alert, kind QUEUE_RETURN" "$(cut -f1,2 "$T/alerts.txt")" "$K${TAB}QUEUE_RETURN"
eq "T1 one PR comment on the PR" "$(grep -c '^example-org/demo-os#134' "$T/writes.txt")" 1
eq "T2 the mark is written before the alert and the comment" "$(paste -sd' ' "$T/order.txt")" "put owed alert comment"
fresh; PUT_RC=1; _mc_qr_tell example-org/demo-os "$K" "$H2" stale-alert "$D0" "left the merge queue"
fresh; _mc_qr_tell example-org/demo-os "$K" "$H2" stale-alert "$D0" "left the merge queue"
eq "T2 a stale alert sets the stale flag of this leave" "$(det '.stale')" 1
fresh; PUT_RC=1; _mc_qr_tell example-org/demo-os "$K" "$H2" stale-alert "$D0" "left the merge queue"
[ ! -s "$T/alerts.txt" ] && [ ! -s "$T/writes.txt" ] && ok || bad "T3 no told mark, no alert and no comment"
eq "T3 the log says it asks again" "$(grep -c 'the told mark was not recorded' "$LOG")" 1

# ============================================================================
# Z — the fragment keeps a record and tells. It queues nothing.
# ============================================================================
Z=$(grep -vE '^[[:space:]]*#' "$FRAG" | grep -cE 'mc_requeue_mergify|mc_enqueue|mc_mergify_command|labels\[\]=|(^|[^_a-z])gh[[:space:]]' || true)
eq "Z1 no requeue, enqueue, label write or raw gh call in the fragment's code" "$Z" 0

echo "queue-return-decide.bh-10201: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
