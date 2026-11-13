#!/bin/bash
# tests/orphan-reconcile-plan-blocked.bh-7116-test.sh — BH-7116 part 2, as
# BH-9457 changed it: the stranded-ticket watch (`orphan-reconcile.sh
# --stranded`) does not re-offer a ticket whose build_queue PHASE is
# plan_blocked. The queue reason and the issue thread decide nothing.
#
# On 2026-10-16 the watch re-offered eight PLAN_BLOCKED tickets every idle
# window; the planner blocked each one again (BH-6865 and BH-5430: 6 spawns each).
# BH-7116 skipped them from the queue reason plus a thread scan for a human
# answer. BH-9457 removed that scan and its knob STRANDED_SKIP_PLAN_BLOCKED:
# the pool's spawn gate (bin/lib/plan-blocked-stop.sh) decides, from the phase.
#
#   R1-R5  the real bin/orphan-reconcile.sh against a scratch HARNESS, fake gh
#          and curl: phase plan_blocked skips; a human comment does not lift
#          it; a PLAN_BLOCKED reason with phase NULL is re-offered whatever the
#          thread says; the triage-tick mode decides the same way
#   (The old S1-S10 unit of the thread-scan function and the R4 knob cases are
#   gone with the function and the knob. tests/orphan-reconcile-phase-gate.bh-9457-test.sh
#   pins the gate's full table.)
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
         bin/lib/plan-blocked-stop.sh bin/lib/pool-lifecycle.sh; do
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
qrow() { # qrow <KEY> <status> <reason> [phase]   (no phase = NULL, BH-9457)
  jq -nc --arg k "$1" --arg s "$2" --arg r "$3" --arg u "$TBISO" --arg ph "${4:-}" \
    '{project:"project-5",ticket_key:$k,status:$s,reason:$r,updated_at:$u,finished_at:$u,enqueued_at:$u,
      phase:(if $ph == "" then null else $ph end),phase_at:(if $ph == "" then null else $u end)}' > "$H/fixture/queue-$1.json"
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

# ══ R: the real script ══════════════════════════════════════════════════════
# R1: THE POINT. Phase plan_blocked; only our own Bot notice is on the thread.
reset; board "[$(cmt 'cromford-board[bot]' Bot $((TB + 60)))]"; qrow TK-101 done "$REASON" plan_blocked
watch
grep -q 'skipped=[^ ]*TK-101:phase-plan_blocked' <<<"$(summary)" && ok || bad "R1: TK-101 is skipped as phase-plan_blocked: $(summary)"
[ "$(nposts)" = 0 ] && ok || bad "R1: no queue row is written for it: $(cat "$H/queue-posts.log" 2>/dev/null)"
[ ! -e "$H/state/stranded-watch/$P/TK-101.reoffers" ] && ok || bad "R1: no re-offer is counted"
grep -q "stranded: TK-101 (issue #101) skip :: skipping TK-101: phase plan_blocked since $TBISO" "$H/logs/$P.log" && ok \
  || bad "R1: one line names the phase and its time: $(grep 'TK-101' "$H/logs/$P.log" | tail -2)"
[ ! -s "$H/needs-human.log" ] && ok || bad "R1: a skip is never a NEEDS_HUMAN"
# R1b: the same reason and thread with phase NULL is re-offered: the reason
# and the thread decide nothing (BH-9457).
reset; board "[$(cmt 'cromford-board[bot]' Bot $((TB + 60)))]"; qrow TK-101 done "$REASON"
watch
grep -q '"key":"TK-101"' "$H/queue-posts.log" 2>/dev/null && ok || bad "R1b: phase NULL with a PLAN_BLOCKED reason is re-offered: $(summary)"

# R2: a human answered after the block. The phase still holds it: re-entry is
# the lifecycle actor's move, not the thread's.
reset; board "[$(cmt 'cromford-board[bot]' Bot $((TB + 60))),$(cmt client-fixture User $((TB - 120)))]"; qrow TK-101 done "$REASON" plan_blocked
watch
grep -q 'TK-101:phase-plan_blocked' <<<"$(summary)" && [ "$(nposts)" = 0 ] && ok || bad "R2: a human comment does not lift a plan_blocked phase: $(summary)"

# R3: a bot comment after the block, phase NULL: re-offered.
reset; board "[$(cmt 'cromford-board[bot]' Bot $((TB - 120)))]"; qrow TK-101 done "$REASON"
watch
grep -q '"key":"TK-101"' "$H/queue-posts.log" 2>/dev/null && ok || bad "R3: phase NULL is re-offered whatever the thread says: $(summary)"

# R5: the triage-tick mode decides the same way (BH-8707, BH-9457;
# tests/orphan-reconcile-triage-plan-blocked.bh-8707-test.sh pins that mode in full).
reset; board '[]'; qrow TK-101 done "$REASON" plan_blocked
"$H/bin/orphan-reconcile.sh" "$P" 2>/dev/null
for _w in 1 2 3 4 5 6 7 8 9 10; do [ -s "$H/launches.log" ] && break; sleep 0.2; done   # the launch is detached
grep -q 'reconcile: open=.*skipped=[^ ]*TK-101:phase-plan_blocked' "$H/logs/$P.log" && ok || bad "R5: the triage-tick reconcile skips it as phase-plan_blocked: $(grep 'reconcile: open' "$H/logs/$P.log")"
grep -q 'project-5 101 TK-101' "$H/launches.log" 2>/dev/null && bad "R5: the triage tick does not launch it: $(cat "$H/launches.log")" || ok
reset; board '[]'; qrow TK-101 done "$REASON"
"$H/bin/orphan-reconcile.sh" "$P" 2>/dev/null
for _w in 1 2 3 4 5 6 7 8 9 10; do [ -s "$H/launches.log" ] && break; sleep 0.2; done
grep -q 'project-5 101 TK-101' "$H/launches.log" 2>/dev/null && ok || bad "R5: phase NULL: the triage tick launches it: $(grep 'reconcile: open' "$H/logs/$P.log")"

echo "orphan-reconcile-plan-blocked (BH-7116): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
