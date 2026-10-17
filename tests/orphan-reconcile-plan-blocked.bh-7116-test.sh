#!/bin/bash
# tests/orphan-reconcile-plan-blocked.bh-7116-test.sh — BH-7116 part 2: the
# stranded-ticket watch (`orphan-reconcile.sh --stranded`) does not re-offer a
# ticket whose last build ended PLAN_BLOCKED, unless a human comment arrived
# after that build ended.
#
# On 2026-10-16 the watch re-offered eight PLAN_BLOCKED tickets every idle
# window; the planner blocked each one again (BH-6865 and BH-5430: 6 spawns each).
#
#   S1-S10 pb_stranded_skip on the decision table: the skip side, the re-offer
#          side and the fail-open (unknown) side
#   R1-R5  the real bin/orphan-reconcile.sh against a scratch HARNESS, fake gh
#          and curl: skip, a human comment re-opens, a bot comment does not,
#          the knob turns it off, the triage-tick mode is unchanged
#
# The rig is tests/stranded-watch.bh-5967-test.sh's. Run from anywhere (exit 0 = pass).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq      >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }
# ONE clock read for the file (bin/test-determinism-lint.sh).
NOW=$(date -u +%s)

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/locks" "$H/flags" "$H/env" \
         "$H/prompts" "$H/builds" "$H/fixture" "$T/fakebin"
export HARNESS="$H"
P=project-5
for L in bin/orphan-reconcile.sh bin/jobs-client.sh bin/lib/preplan-lib.sh bin/lib/gh-budget.sh bin/lib/hold.sh \
         bin/lib/closeout-overdue.sh bin/lib/gh-rest.sh bin/lib/gh-rest-var.sh bin/lib/gh-rest-list.sh bin/fleet-conf.sh \
         bin/lib/plan-blocked.sh; do
  [ -f "$DIR/$L" ] || { bad "setup: $L is not in the tree"; continue; }
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
for L in $(cd "$DIR" && printf '%s ' bin/lib/jobs/*.sh); do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
export FLEET_CONF="$DIR/fleet.conf"
echo 'setsid /root/harness/bin/run-build.sh project-5 <issue-number> TK-<issue-number> > x' > "$H/prompts/$P.md"
printf 'HARNESS_SECRET=fixture-secret\nJOBS_URL=https://jobs.test\n' > "$H/env/global.env"
printf '%s\n' '#!/bin/bash' 'printf "%s\n" "$*" >> "$HARNESS/launches.log"' > "$H/bin/run-build.sh"
printf '%s\n' '#!/bin/bash' 'printf "%s\n" "$*" >> "$HARNESS/alerts-called.log"' > "$H/bin/lane-alert.sh"
printf '%s\n' '#!/bin/bash' 'printf "%s\n" "$*" >> "$HARNESS/needs-human.log"' 'exit 0' > "$H/bin/needs-human-hold.sh"
chmod +x "$H/bin/"*.sh

cat > "$T/fakebin/gh" <<'SH'
ARGS="$*"
SEND() { printf 'HTTP/2 %s\r\nserver: x\r\n\r\n%s' "$1" "$2"; exit 0; }
PAGE=$(printf '%s' "$ARGS" | sed -nE 's/.*page=([0-9]+).*/\1/p'); PAGE="${PAGE:-1}"
[ "$PAGE" = 1 ] || SEND 200 '[]'
case "$ARGS" in
  "api repos/example-org/project-5 -q .id") echo 1; exit 0 ;;
  *"api rate_limit"*) exit 1 ;;
  *"/issues/"*"/comments"*)
    n=$(printf '%s' "$ARGS" | sed -nE 's#.*/issues/([0-9]+)/comments.*#\1#p')
    SEND 200 "$(jq -c --argjson n "$n" '[ .[] | select(.number==$n) | (.comments // [])[] ]' "$HARNESS/fixture/open.json")" ;;
  *"/pulls"*) SEND 200 '[]' ;;
  *"/issues"*"state=all"*)
    SEND 200 "$(jq -c '[ .[] | {number, state:"open", closed_at:null} ]' "$HARNESS/fixture/open.json")" ;;
  *"/issues"*)
    SEND 200 "$(jq -c '[ .[] | {number, title, body, comments:((.comments // [])|length), updated_at:.updatedAt} ]' "$HARNESS/fixture/open.json")" ;;
  *) exit 1 ;;
esac
SH
# curl: the jobs ledger and the queue. GET /api/queue?…key=K answers the row in
# fixture/queue-K.json (none -> no row); every POST to /api/queue is recorded.
cat > "$T/fakebin/curl" <<'SH'
URL="${!#}"; METHOD=GET; BODY=""
prev=""
for a in "$@"; do
  [ "$prev" = -X ] && METHOD="$a"
  [ "$prev" = --data-binary ] && BODY="$a"
  prev="$a"
done
case "$BODY" in @*) BODY=$(cat "${BODY#@}" 2>/dev/null) ;; esac
case "$METHOD $URL" in
  "POST "*/api/queue*) printf '%s\n' "$BODY" >> "$HARNESS/queue-posts.log"; printf '{"ok":true}\n200\n' ;;
  "GET "*/api/queue*"key="*)
    [ -e "$HARNESS/queue-down" ] && { printf 'boom\n503\n'; exit 0; }
    k=$(printf '%s' "$URL" | sed -nE 's/.*key=([^&]+).*/\1/p')
    if [ -s "$HARNESS/fixture/queue-$k.json" ]; then printf '{"queue":[%s]}\n200\n' "$(cat "$HARNESS/fixture/queue-$k.json")"
    else printf '{"queue":[]}\n200\n'; fi ;;
  "GET "*/api/queue*) printf '{"queue":[]}\n200\n' ;;
  "GET "*/api/jobs*) printf '%s\n200\n' "$(cat "$HARNESS/fixture/jobs.json")" ;;
  *) printf '{"ok":true}\n200\n' ;;
esac
SH
chmod +x "$T/fakebin/gh" "$T/fakebin/curl"
export PATH="$T/fakebin:$PATH"

ISO() { date -u -d "@$(( NOW - $1 ))" '+%Y-%m-%dT%H:%M:%SZ'; }
TB=9000                     # the block ended 2.5 h ago (T)
TBISO=$(ISO "$TB")
# The queue reason the fly-pool reap writes: `head -c 200` of a real-shape RESULT.
RES_LINE="PLAN_BLOCKED /data/harness/builds/project-5-TK-101-202610161100/plan.md$(printf ' | CLOSED-OUT: the builder posted the board close-out on %s' 'example-org/project-5#101')"
REASON=$(head -c 200 <<<"$RES_LINE
BUILD_DIR: /data/harness/builds/project-5-TK-101-202610161100")
qrow() { # qrow <KEY> <status> <reason> [updated_at]
  jq -nc --arg k "$1" --arg s "$2" --arg r "$3" --arg u "${4:-$TBISO}" \
    '{project:"project-5",ticket_key:$k,status:$s,reason:$r,updated_at:$u,finished_at:$u,enqueued_at:$u}' > "$H/fixture/queue-$1.json"
}
cmt() { # cmt <login> <type> <created-ago-s> [updated-ago-s]
  jq -nc --arg l "$1" --arg t "$2" --arg c "$(ISO "$3")" --arg u "$(ISO "${4:-$3}")" \
    '{body:"a comment",user:{login:$l,type:$t},created_at:$c,updated_at:$u}'
}
board() { # board <comments-json-array>
  jq -nc --argjson c "$1" --arg u "$(ISO 8000)" \
    '[{number:101,title:"TK-101 blocked once",body:"## Scope",comments:$c,updatedAt:$u}]' > "$H/fixture/open.json"
  jq -nc --arg u "$(ISO "$TB")" \
    '{jobs:[{id:"build-project-5-TK-101-0",ticket_id:"TK-101",kind:"build",status:"failed",updated_at:$u,meta:"{\"ticket_id\":\"101\"}"}]}' > "$H/fixture/jobs.json"
}
reset() {
  scratch_rm "$H/state"; scratch_rm "$H/logs"; mkdir -p "$H/state" "$H/logs"
  rm -f "$H/launches.log" "$H/queue-posts.log" "$H/needs-human.log" "$H/alerts-called.log" "$H/queue-down" "$H/fixture/queue-"*.json
}
watch() { "$H/bin/orphan-reconcile.sh" --stranded "$P" 2>/dev/null; }
summary() { grep 'stranded-watch: open=' "$H/logs/$P.log" | tail -1; }
nposts() { local n; n=$(grep -c . "$H/queue-posts.log" 2>/dev/null); echo "${n:-0}"; }

# ══ S: pb_stranded_skip, unit ═══════════════════════════════════════════════
LOADED=0
( . "$H/bin/jobs-client.sh" >/dev/null 2>&1; . "$H/bin/lib/plan-blocked.sh" 2>/dev/null; command -v pb_stranded_skip >/dev/null ) && LOADED=1
[ "$LOADED" = 1 ] && ok || bad "bin/lib/plan-blocked.sh does not load or defines no pb_stranded_skip"
TH="$T/thread.json"
skip() { # skip <comments-json|-> [count] -> rc and the printed iso, as "rc|out"
  local f="" n="${2:-}"
  if [ "$1" != - ]; then printf '%s' "$1" > "$TH"; f="$TH"; [ -n "$n" ] || n=$(jq length "$TH"); fi
  ( . "$H/bin/jobs-client.sh" >/dev/null 2>&1; . "$H/bin/lib/plan-blocked.sh" 2>/dev/null
    o=$(pb_stranded_skip "$P" TK-101 "$f" "${n:-0}" 2>/dev/null); printf '%s|%s' "$?" "$o" )
}
BOT=$(cmt 'cromford-board[bot]' Bot $((TB - 300)))
HUMAN_OLD=$(cmt operator-fixture User $((TB + 1)))
reset
qrow TK-101 done "PLAN_BLOCKED /data/harness/builds/x/plan.md"
[ "$(skip '[]')" = "0|$TBISO" ] && ok || bad "S1: PLAN_BLOCKED, no comments -> skip and print the block time (got $(skip '[]'))"
[ "$(skip "[$BOT,$(cmt 'intercom[bot]' Bot $((TB - 600)))]")" = "0|$TBISO" ] && ok || bad "S2: only Bot comments newer than the block -> still skip"
qrow TK-101 done "PLAN_BLOCKED cross-repo-read example-org/spec-fixture /x/plan.md | CLOSED-OUT: the builder posted the board close-out on example-org/project-5#101"
[ "$(skip "[$HUMAN_OLD]")" = "0|$TBISO" ] && ok || bad "S3: a human comment 1 s older than the block -> skip (got $(skip "[$HUMAN_OLD]"))"
qrow TK-101 done "PLAN_BLOCKED /x/plan.md"
[ "$(skip "[$(cmt operator-fixture User $((TB - 120)))]" | cut -d'|' -f1)" = 1 ] && ok || bad "S4: a human comment after the block -> re-offer"
[ "$(skip "[$(cmt client-fixture User $((TB + 600)) $((TB - 60)))]" | cut -d'|' -f1)" = 1 ] && ok || bad "S5: a human comment EDITED after the block -> re-offer"
qrow TK-101 done "PLAN_MALFORMED /x/plan.md"
[ "$(skip '[]' | cut -d'|' -f1)" = 1 ] && ok || bad "S6: PLAN_MALFORMED -> re-offer"
qrow TK-101 done "PLAN_BLOCKED_X /x/plan.md"
[ "$(skip '[]' | cut -d'|' -f1)" = 1 ] && ok || bad "S7: PLAN_BLOCKED_X -> re-offer"
qrow TK-101 failed "RESULT_UNVERIFIED PLAN_BLOCKED /x/plan.md"
[ "$(skip '[]' | cut -d'|' -f1)" = 1 ] && ok || bad "S7: RESULT_UNVERIFIED PLAN_BLOCKED -> re-offer"
qrow TK-101 failed "REVIEW_BLOCKED /x/review.md"
[ "$(skip '[]' | cut -d'|' -f1)" = 1 ] && ok || bad "S8: REVIEW_BLOCKED -> re-offer"
qrow TK-101 done "PLAN_BLOCKED /x/plan.md"
: > "$H/queue-down"
[ "$(skip '[]' | cut -d'|' -f1)" = 2 ] && ok || bad "S9: the queue does not answer -> unknown (rc 2)"
rm -f "$H/queue-down" "$H/fixture/queue-TK-101.json"
[ "$(skip '[]' | cut -d'|' -f1)" = 2 ] && ok || bad "S9: no queue row -> unknown (rc 2)"
qrow TK-101 done "PLAN_BLOCKED /x/plan.md" "not-a-time"
[ "$(skip '[]' | cut -d'|' -f1)" = 2 ] && ok || bad "S9: an updated_at that does not parse -> unknown (rc 2)"
qrow TK-101 done "PLAN_BLOCKED /x/plan.md" "${TBISO%Z}.123Z"
[ "$(skip '[]' | cut -d'|' -f1)" = 0 ] && ok || bad "S9: fractional seconds are stripped and still parse"
qrow TK-101 done "PLAN_BLOCKED /x/plan.md"
[ "$(skip - 2 | cut -d'|' -f1)" = 2 ] && ok || bad "S9: comments counted but no thread file -> unknown (rc 2)"
[ "$(skip '{"message":"x"}' 1 | cut -d'|' -f1)" = 2 ] && ok || bad "S9: a thread that is not an array -> unknown (rc 2)"
qrow TK-101 queued "PLAN_BLOCKED /x/plan.md"
[ "$(skip '[]' | cut -d'|' -f1)" = 1 ] && ok || bad "S10: a queued row is not this lane's to skip -> rc 1"

# ══ R: the real script ══════════════════════════════════════════════════════
# R1: the block is the newest word; only our own Bot notice is on the thread.
reset; board "[$(cmt 'cromford-board[bot]' Bot $((TB + 60)))]"; qrow TK-101 done "$REASON"
watch
grep -q 'skipped=[^ ]*TK-101:plan-blocked' <<<"$(summary)" && ok || bad "R1: THE POINT: TK-101 is skipped as plan-blocked: $(summary)"
[ "$(nposts)" = 0 ] && ok || bad "R1: no queue row is written for it: $(cat "$H/queue-posts.log" 2>/dev/null)"
[ ! -e "$H/state/stranded-watch/$P/TK-101.reoffers" ] && ok || bad "R1: no re-offer is counted"
grep -q "stranded: TK-101 (issue #101) skip :: last build ended PLAN_BLOCKED at $TBISO and no human comment since" "$H/logs/$P.log" && ok \
  || bad "R1: one line names the block time: $(grep 'TK-101' "$H/logs/$P.log" | tail -2)"
[ ! -s "$H/needs-human.log" ] && ok || bad "R1: a skip is never a NEEDS_HUMAN"

# R2: a human answered after the block -> re-offered.
reset; board "[$(cmt 'cromford-board[bot]' Bot $((TB + 60))),$(cmt client-fixture User $((TB - 120)))]"; qrow TK-101 done "$REASON"
watch
grep -q '"key":"TK-101"' "$H/queue-posts.log" 2>/dev/null && ok || bad "R2: THE POINT: a new human comment makes it eligible again: $(summary)"

# R3: a bot comment after the block is not an answer.
reset; board "[$(cmt 'cromford-board[bot]' Bot $((TB - 120)))]"; qrow TK-101 done "$REASON"
watch
grep -q 'TK-101:plan-blocked' <<<"$(summary)" && [ "$(nposts)" = 0 ] && ok || bad "R3: our own bot's newer comment keeps it skipped: $(summary)"

# R4: the knob turns the skip off.
reset; board "[$(cmt 'cromford-board[bot]' Bot $((TB + 60)))]"; qrow TK-101 done "$REASON"
STRANDED_SKIP_PLAN_BLOCKED=0 watch
grep -q '"key":"TK-101"' "$H/queue-posts.log" 2>/dev/null && ok || bad "R4: STRANDED_SKIP_PLAN_BLOCKED=0 re-offers as before: $(summary)"
reset; board '[]'; qrow TK-101 done "$REASON"
STRANDED_SKIP_PLAN_BLOCKED=maybe watch
grep -q 'TK-101:plan-blocked' <<<"$(summary)" && ok || bad "R4: a bad value is read as 1: $(summary)"
grep -q "STRANDED_SKIP_PLAN_BLOCKED='maybe'" "$H/logs/$P.log" && ok || bad "R4: a bad value is said once in the log"

# R5: the default (no settings row, no env) skips; the triage-tick mode does not.
reset; board '[]'; qrow TK-101 done "$REASON"
( unset STRANDED_SKIP_PLAN_BLOCKED; watch )
grep -q 'TK-101:plan-blocked' <<<"$(summary)" && ok || bad "R5: the default skips: $(summary)"
reset; board '[]'; qrow TK-101 done "$REASON"
"$H/bin/orphan-reconcile.sh" "$P" 2>/dev/null
for _w in 1 2 3 4 5 6 7 8 9 10; do [ -s "$H/launches.log" ] && break; sleep 0.2; done   # the launch is detached
grep -q 'plan-blocked' "$H/logs/$P.log" && bad "R5: the triage-tick reconcile is unchanged: $(grep -o 'skipped=[^ ]*' "$H/logs/$P.log")" || ok
grep -q 'project-5 101 TK-101' "$H/launches.log" 2>/dev/null && ok || bad "R5: the triage tick still launches it as today: $(grep 'reconcile: open' "$H/logs/$P.log")"

echo "orphan-reconcile-plan-blocked (BH-7116): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
