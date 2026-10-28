#!/bin/bash
# tests/orphan-reconcile-triage-plan-blocked.bh-8707-test.sh — BH-8707: the
# triage-tick reconcile (`orphan-reconcile.sh <project>`, no `--stranded`) does
# not relaunch a ticket whose last build ended PLAN_BLOCKED, unless a human
# comment arrived after that build ended. Before BH-8707 only the stranded watch
# ran the BH-7116 guard (bin/lib/plan-blocked.sh pb_stranded_skip).
#
# On 2026-10-27/28 box-small relaunched BH-8467 five times in one
# night; each build blocked again, and each relaunch fired a critical
# "reconciliation enqueued" alert. BH-8634, BH-8646 and BH-8666 hit the pool
# spawn cap the same way.
#
#   P1-P7  the guard in triage mode: skip, a human comment (created or edited)
#          re-opens, an older human comment does not, the queue down fails open,
#          another reason launches, a skip takes no cap slot
#   K1-K2  the knob STRANDED_SKIP_PLAN_BLOCKED: unset = 1, 0 = off, junk = 1
#   A1-A2  the "reconciliation enqueued" alert counts enqueues only
#
# The rig is tests/orphan-reconcile-plan-blocked.bh-7116-test.sh's. Run from
# anywhere (exit 0 = pass).
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
# board <comments-101-json> [comments-102-json]: issue 101, and 102 when given.
board() {
  jq -nc --argjson c "$1" --argjson d "${2:-null}" --arg u "$(ISO 8000)" '
    [{number:101,title:"TK-101 blocked once",body:"## Scope",comments:$c,updatedAt:$u}]
    + (if $d == null then [] else [{number:102,title:"TK-102 plain",body:"## Scope",comments:$d,updatedAt:$u}] end)' > "$H/fixture/open.json"
  jq -nc --arg u "$(ISO "$TB")" \
    '{jobs:[{id:"build-project-5-TK-101-0",ticket_id:"TK-101",kind:"build",status:"failed",updated_at:$u,meta:"{\"ticket_id\":\"101\"}"}]}' > "$H/fixture/jobs.json"
}
reset() {
  scratch_rm "$H/state"; scratch_rm "$H/logs"; mkdir -p "$H/state" "$H/logs"
  rm -f "$H/launches.log" "$H/queue-posts.log" "$H/needs-human.log" "$H/alerts-called.log" "$H/queue-down" "$H/fixture/queue-"*.json
}
# The triage tick. The launch is detached: wait for the expected launch count,
# at most 2 s (a run that launches nothing is proven by its summary line).
tick() {
  "$H/bin/orphan-reconcile.sh" "$P" 2>/dev/null
  local want="${WANT:-1}" _w
  for _w in 1 2 3 4 5 6 7 8 9 10; do
    [ "$(nlaunch)" -ge "$want" ] && break; sleep 0.2
  done
}
summary() { grep 'reconcile: open=' "$H/logs/$P.log" | tail -1; }
nlaunch() { local n; n=$(grep -c . "$H/launches.log" 2>/dev/null); echo "${n:-0}"; }
nalerts() { local n; n=$(grep -c . "$H/alerts-called.log" 2>/dev/null); echo "${n:-0}"; }
launched() { grep -q "project-5 $1 TK-$1" "$H/launches.log" 2>/dev/null; }
MARK() { find "$H/state" -name "TK-$1.enqueued" 2>/dev/null | grep -q .; }
BOTN=$(cmt 'cromford-board[bot]' Bot $((TB - 60)))   # our notice, newer than the block

# ── P1: THE POINT. The block is the newest human word; only our own bot notice
# is newer. The triage tick skips it: no launch, no marker, no alert.
reset; board "[$BOTN]"; qrow TK-101 done "$REASON"
WANT=0 tick
grep -q 'skipped=[^ ]*TK-101:plan-blocked' <<<"$(summary)" && ok || bad "P1: TK-101 is in the skip list as plan-blocked: $(summary)"
grep -q 'enqueued=- ' <<<"$(summary)" && ok || bad "P1: nothing is enqueued: $(summary)"
[ "$(nlaunch)" = 0 ] && ok || bad "P1: no run-build.sh launch: $(cat "$H/launches.log" 2>/dev/null)"
MARK 101 && bad "P1: no TK-101.enqueued marker is written" || ok
grep -q "reconcile: TK-101 (issue #101) skip :: last build ended PLAN_BLOCKED at $TBISO and no human comment since" "$H/logs/$P.log" && ok \
  || bad "P1: one line names the block time: $(grep 'TK-101' "$H/logs/$P.log" | tail -2)"
[ "$(nalerts)" = 0 ] && ok || bad "P1: no alert line: $(cat "$H/alerts-called.log" 2>/dev/null)"

# ── P2: a human comment created after the block -> launched.
reset; board "[$BOTN,$(cmt client-fixture User $((TB - 120)))]"; qrow TK-101 done "$REASON"
tick
launched 101 && ok || bad "P2: a human answer after the block relaunches it: $(summary)"

# ── P3: a human comment EDITED after the block -> launched.
reset; board "[$(cmt client-fixture User $((TB + 600)) $((TB - 60)))]"; qrow TK-101 done "$REASON"
tick
launched 101 && ok || bad "P3: a human comment edited after the block relaunches it: $(summary)"

# ── P4: a human comment 1 s OLDER than the block -> still skipped.
reset; board "[$(cmt operator-fixture User $((TB + 1)))]"; qrow TK-101 done "$REASON"
WANT=0 tick
grep -q 'TK-101:plan-blocked' <<<"$(summary)" && [ "$(nlaunch)" = 0 ] && ok || bad "P4: an older human comment is not an answer: $(summary)"

# ── P5: the queue does not answer -> unknown -> launched (fail-open, as before).
reset; board "[$BOTN]"; qrow TK-101 done "$REASON"; : > "$H/queue-down"
tick
launched 101 && ok || bad "P5: the queue down fails open (launch): $(summary)"

# ── P6: another block reason -> launched.
reset; board "[$BOTN]"; qrow TK-101 failed "REVIEW_BLOCKED /x/review.md"
tick
launched 101 && ok || bad "P6: REVIEW_BLOCKED is not this guard's: $(summary)"
reset; board "[$BOTN]"; qrow TK-101 failed "RESULT_UNVERIFIED PLAN_BLOCKED /x/plan.md"
tick
launched 101 && ok || bad "P6: PLAN_BLOCKED not as the first word is not this guard's: $(summary)"

# ── P7: a skip takes no cap slot. Cap 1, TK-101 plan-blocked, TK-102 plain.
reset; board "[$BOTN]" '[]'; qrow TK-101 done "$REASON"
ORPHAN_MAX_PER_RUN=1 tick
launched 102 && ok || bad "P7: TK-102 is launched inside the cap of 1: $(summary)"
grep -q 'TK-102:cap' <<<"$(summary)" && bad "P7: TK-102 is not held back by the cap: $(summary)" || ok
launched 101 && bad "P7: TK-101 is not launched" || ok

# ── K1: no env, no settings row -> the code fallback 1 skips.
reset; board '[]'; qrow TK-101 done "$REASON"
( unset STRANDED_SKIP_PLAN_BLOCKED; WANT=0 tick )
grep -q 'TK-101:plan-blocked' <<<"$(summary)" && [ "$(nlaunch)" = 0 ] && ok || bad "K1: the default skips: $(summary)"

# ── K2: 0 turns the skip off; a junk value is read as 1 with one log line.
reset; board '[]'; qrow TK-101 done "$REASON"
STRANDED_SKIP_PLAN_BLOCKED=0 tick
launched 101 && ok || bad "K2: STRANDED_SKIP_PLAN_BLOCKED=0 launches as before: $(summary)"
reset; board '[]'; qrow TK-101 done "$REASON"
STRANDED_SKIP_PLAN_BLOCKED=maybe WANT=0 tick
grep -q 'TK-101:plan-blocked' <<<"$(summary)" && ok || bad "K2: a bad value is read as 1: $(summary)"
[ "$(grep -c "reconcile: STRANDED_SKIP_PLAN_BLOCKED='maybe'" "$H/logs/$P.log")" = 1 ] && ok \
  || bad "K2: a bad value is said once, with the reconcile prefix: $(grep STRANDED_SKIP "$H/logs/$P.log")"

# ── A1: the only orphan is skipped -> no lane-alert.sh call at all.
reset; board '[]'; qrow TK-101 done "$REASON"
WANT=0 tick
[ "$(nalerts)" = 0 ] && ok || bad "A1: a skip alone never pages: $(cat "$H/alerts-called.log" 2>/dev/null)"

# ── A2: TK-101 skipped, TK-102 launched -> one alert that names TK-102 only.
reset; board '[]' '[]'; qrow TK-101 done "$REASON"
tick
MSG=$(cat "$H/alerts-called.log" 2>/dev/null)
[ "$(nalerts)" = 1 ] && ok || bad "A2: one alert call: $MSG"
grep -q 'enqueued 1 ai-build issue(s)' <<<"$MSG" && ok || bad "A2: the alert counts 1 enqueue: $MSG"
EACH=$(sed -n 's/.*Each had\(.*\)The event-wake.*/\1/p' <<<"$MSG")
grep -q 'TK-102 (' <<<"$EACH" && ok || bad "A2: the per-key list names TK-102: $MSG"
grep -q 'TK-101 (' <<<"$EACH" && bad "A2: the per-key list does not name the skipped TK-101: $EACH" || ok
grep -q 'Held back this run: TK-101:plan-blocked' <<<"$MSG" && ok || bad "A2: the skip is named as held back: $MSG"

echo "orphan-reconcile-triage-plan-blocked (BH-8707): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
