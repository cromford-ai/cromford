#!/bin/bash
# tests/orphan-reconcile-phase-gate.bh-9457-test.sh — BH-9457: both modes of
# bin/orphan-reconcile.sh (the triage tick and `--stranded`) decide a relaunch
# from the ticket's build_queue phase, through the pool's own spawn gate
# (bin/lib/plan-blocked-stop.sh pbs_stop_check). The issue thread and the
# queue reason decide nothing, and the STRANDED_SKIP_PLAN_BLOCKED knob is gone.
#
#   G1-G2  phase plan_blocked plus a human answer after the block: skipped in
#          both modes as `<KEY>:phase-plan_blocked` (no launch, no POST, no
#          re-offer count, no alert, no NEEDS_HUMAN)
#   G3     phase abandoned: skipped in both modes
#   G4     phase NULL, reason PLAN_BLOCKED, only our bot's notice: launched
#   G5     phase planned / no row / GET 503 launch; phase in_queue skips
#   G6     STRANDED_SKIP_PLAN_BLOCKED changes nothing
#   G7     the worker's 409 phase_refused on the re-offer is a phase skip
#   G8     a phase skip takes no cap slot
#   G9     static: no pb_stranded_skip, no STRANDED_SKIP_PLAN_BLOCKED reader
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
         bin/lib/plan-blocked.sh bin/lib/plan-blocked-stop.sh bin/lib/pool-lifecycle.sh; do
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
# fixture/queue-K.json (none -> no row; the file `queue-down` -> 503). Every
# POST to /api/queue is recorded; the file `post-409` makes the worker answer
# its BH-9160 phase refusal instead of taking the row.
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
  "POST "*/api/queue*)
    printf '%s\n' "$BODY" >> "$HARNESS/queue-posts.log"
    if [ -e "$HARNESS/post-409" ]; then printf '{"error":"phase_refused","phase":"plan_blocked"}\n409\n'
    else printf '{"ok":true}\n200\n'; fi ;;
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
# The gate's knob is the fly-pool lane's; this lane reads its default (1).
unset POOL_PLAN_BLOCKED_STOP STRANDED_SKIP_PLAN_BLOCKED

ISO() { date -u -d "@$(( NOW - $1 ))" '+%Y-%m-%dT%H:%M:%SZ'; }
TB=9000                     # the block ended 2.5 h ago
TBISO=$(ISO "$TB")
REASON="PLAN_BLOCKED /data/harness/builds/project-5-TK-0-202611110100/plan.md"
qrow() { # qrow <KEY> <phase|-> <reason>   (- = phase NULL)
  jq -nc --arg k "$1" --arg ph "$2" --arg r "$3" --arg u "$TBISO" '
    {project:"project-5",ticket_key:$k,status:"done",reason:$r,updated_at:$u,finished_at:$u,enqueued_at:$u,
     phase:(if $ph == "-" then null else $ph end),phase_at:(if $ph == "-" then null else $u end),
     question:(if $ph == "plan_blocked" then "Which fee rule applies?" else null end)}' > "$H/fixture/queue-$1.json"
}
cmt() { # cmt <login> <type> <created-ago-s>
  jq -nc --arg l "$1" --arg t "$2" --arg c "$(ISO "$3")" \
    '{body:"a comment",user:{login:$l,type:$t},created_at:$c,updated_at:$c}'
}
BOTN=$(cmt 'cromford-board[bot]' Bot $((TB - 60)))    # our notice, newer than the block
HUMAN=$(cmt client-fixture User $((TB - 120)))              # a human answer after the block
# board <n> <comments-json> [<n2> <comments-json>]: open issues TK-<n>, each with
# one failed build job that ended at the block time.
board() {
  local issues='[]' jobs='[]'
  while [ $# -ge 2 ]; do
    issues=$(jq -c --argjson n "$1" --argjson c "$2" --arg u "$(ISO 8000)" \
      '. + [{number:$n,title:("TK-\($n) gate case"),body:"## Scope",comments:$c,updatedAt:$u}]' <<<"$issues")
    jobs=$(jq -c --argjson n "$1" --arg u "$TBISO" \
      '. + [{id:"build-project-5-TK-\($n)-0",ticket_id:"TK-\($n)",kind:"build",status:"failed",updated_at:$u,meta:("{\"ticket_id\":\"\($n)\"}")}]' <<<"$jobs")
    shift 2
  done
  printf '%s\n' "$issues" > "$H/fixture/open.json"
  jq -nc --argjson j "$jobs" '{jobs:$j}' > "$H/fixture/jobs.json"
}
reset() {
  scratch_rm "$H/state"; scratch_rm "$H/logs"; mkdir -p "$H/state" "$H/logs"
  rm -f "$H/launches.log" "$H/queue-posts.log" "$H/needs-human.log" "$H/alerts-called.log" \
        "$H/queue-down" "$H/post-409" "$H/fixture/queue-"*.json
}
nlaunch() { local n; n=$(grep -c . "$H/launches.log" 2>/dev/null); echo "${n:-0}"; }
nalerts() { local n; n=$(grep -c . "$H/alerts-called.log" 2>/dev/null); echo "${n:-0}"; }
launched() { grep -q "project-5 $1 TK-$1" "$H/launches.log" 2>/dev/null; }
posted() { grep -q "\"key\":\"TK-$1\"" "$H/queue-posts.log" 2>/dev/null; }
# The triage tick. The launch is detached: wait for WANT launches, at most 2 s.
tick() {
  "$H/bin/orphan-reconcile.sh" "$P" 2>/dev/null
  local want="${WANT:-1}" _w
  for _w in 1 2 3 4 5 6 7 8 9 10; do
    [ "$(nlaunch)" -ge "$want" ] && break; sleep 0.2
  done
}
watch() { "$H/bin/orphan-reconcile.sh" --stranded "$P" 2>/dev/null; }
tsum() { grep 'reconcile: open=' "$H/logs/$P.log" | tail -1; }
ssum() { grep 'stranded-watch: open=' "$H/logs/$P.log" | tail -1; }

# ── G1: THE POINT, triage tick. Phase plan_blocked; a human answered after the
# block. Before BH-9457 the thread scan read that answer and relaunched it.
reset; board 201 "[$BOTN,$HUMAN]"; qrow TK-201 plan_blocked "$REASON"
WANT=0 tick
grep -q 'skipped=[^ ]*TK-201:phase-plan_blocked' <<<"$(tsum)" && ok || bad "G1: TK-201 is skipped as phase-plan_blocked: $(tsum)"
[ "$(nlaunch)" = 0 ] && ok || bad "G1: no run-build.sh launch: $(cat "$H/launches.log" 2>/dev/null)"
grep -q "reconcile: TK-201 (issue #201) skip :: skipping TK-201: phase plan_blocked since $TBISO" "$H/logs/$P.log" && ok \
  || bad "G1: one line quotes the gate: $(grep TK-201 "$H/logs/$P.log" | tail -2)"
[ "$(nalerts)" = 0 ] && ok || bad "G1: no reconciliation alert: $(cat "$H/alerts-called.log" 2>/dev/null)"
[ -z "$(find "$H/state" -name 'TK-201.enqueued' 2>/dev/null)" ] && ok || bad "G1: no .enqueued marker"

# ── G2: the same fixture, stranded watch.
reset; board 202 "[$BOTN,$HUMAN]"; qrow TK-202 plan_blocked "$REASON"
watch
grep -q 'skipped=[^ ]*TK-202:phase-plan_blocked' <<<"$(ssum)" && ok || bad "G2: TK-202 is skipped as phase-plan_blocked: $(ssum)"
posted 202 && bad "G2: no POST /api/queue: $(cat "$H/queue-posts.log")" || ok
[ ! -e "$H/state/stranded-watch/$P/TK-202.reoffers" ] && ok || bad "G2: no re-offer is counted"
grep -q "stranded: TK-202 (issue #202) skip :: skipping TK-202: phase plan_blocked since $TBISO" "$H/logs/$P.log" && ok \
  || bad "G2: one stranded line quotes the gate: $(grep TK-202 "$H/logs/$P.log" | tail -2)"
[ ! -s "$H/needs-human.log" ] && ok || bad "G2: a skip is never NEEDS_HUMAN"

# ── G3: phase abandoned, both modes.
reset; board 203 '[]'; qrow TK-203 abandoned "ABANDONED ladder ran out"
WANT=0 tick
grep -q 'TK-203:phase-abandoned' <<<"$(tsum)" && [ "$(nlaunch)" = 0 ] && ok || bad "G3: triage tick skips phase-abandoned: $(tsum)"
reset; board 203 '[]'; qrow TK-203 abandoned "ABANDONED ladder ran out"
watch
grep -q 'TK-203:phase-abandoned' <<<"$(ssum)" && ! posted 203 && ok || bad "G3: stranded watch skips phase-abandoned: $(ssum)"

# ── G4: phase NULL, reason PLAN_BLOCKED, only our bot notice. The old thread
# scan skipped this; the phase is the only decider now.
reset; board 204 "[$BOTN]"; qrow TK-204 - "$REASON"
tick
launched 204 && ok || bad "G4: the triage tick launches it: $(tsum)"
grep -q 'TK-204:plan-blocked' "$H/logs/$P.log" && bad "G4: no plan-blocked skip token: $(tsum)" || ok
reset; board 204 "[$BOTN]"; qrow TK-204 - "$REASON"
watch
posted 204 && ok || bad "G4: the stranded watch re-offers it: $(ssum)"

# ── G5: passes. planned with a PLAN_BLOCKED reason; no row; the GET 503.
reset; board 205 "[$BOTN]"; qrow TK-205 planned "$REASON"
tick
launched 205 && ok || bad "G5: phase planned launches: $(tsum)"
reset; board 205 "[$BOTN]"
tick
launched 205 && ok || bad "G5b: no queue row launches: $(tsum)"
reset; board 205 "[$BOTN]"; qrow TK-205 plan_blocked "$REASON"; : > "$H/queue-down"
tick
launched 205 && ok || bad "G5c: a queue outage fails open (launch): $(tsum)"
[ "$(grep -c 'TK-205 (issue #205) TK-205: phase unreadable' "$H/logs/$P.log")" = 1 ] && ok \
  || bad "G5c: the outage is said in one line: $(grep TK-205 "$H/logs/$P.log")"
reset; board 205 '[]'; qrow TK-205 in_queue "$REASON"
WANT=0 tick
grep -q 'TK-205:phase-in_queue' <<<"$(tsum)" && [ "$(nlaunch)" = 0 ] && ok || bad "G5d: phase in_queue skips: $(tsum)"

# ── G6: the removed knob changes nothing.
reset; board 206 '[]'; qrow TK-206 plan_blocked "$REASON"
STRANDED_SKIP_PLAN_BLOCKED=0 WANT=0 tick
grep -q 'TK-206:phase-plan_blocked' <<<"$(tsum)" && [ "$(nlaunch)" = 0 ] && ok || bad "G6: =0 does not lift a plan_blocked phase: $(tsum)"
reset; board 206 '[]'; qrow TK-206 - "$REASON"
STRANDED_SKIP_PLAN_BLOCKED=1 tick
launched 206 && ok || bad "G6: =1 does not skip a NULL phase: $(tsum)"
grep -q 'STRANDED_SKIP_PLAN_BLOCKED' "$H/logs/$P.log" && bad "G6: the knob is not read or named: $(grep STRANDED_SKIP "$H/logs/$P.log")" || ok

# ── G7: the GET reads phase NULL, the worker refuses the POST (409). The
# reason is not PLAN_BLOCKED, so nothing before the POST holds it back.
reset; board 207 '[]'; qrow TK-207 - "REVIEW_BLOCKED /x/review.md"; : > "$H/post-409"
watch
grep -q 'skipped=[^ ]*TK-207:phase-plan_blocked' <<<"$(ssum)" && ok || bad "G7: the refusal is a phase skip: $(ssum)"
grep -q 'TK-207:queue-unreachable' <<<"$(ssum)" && bad "G7: not queue-unreachable: $(ssum)" || ok
[ -s "$H/state/stranded-watch/$P/TK-207.reoffers" ] && bad "G7: no re-offer is counted" || ok
grep -q "stranded: TK-207 (issue #207) skip :: ticket phase plan_blocked; only the lifecycle actor re-enters it" "$H/logs/$P.log" && ok \
  || bad "G7: one line names the phase: $(grep TK-207 "$H/logs/$P.log" | tail -2)"

# ── G8: cap 1; TK-208 phase plan_blocked, TK-209 phase NULL. The skip takes no slot.
reset; board 208 '[]' 209 '[]'; qrow TK-208 plan_blocked "$REASON"
STRANDED_MAX_PER_RUN=1 watch
posted 209 && ok || bad "G8: TK-209 is re-offered inside the cap of 1: $(ssum)"
grep -q 'TK-209:cap' <<<"$(ssum)" && bad "G8: TK-209 is not held by the cap: $(ssum)" || ok
posted 208 && bad "G8: TK-208 is not re-offered" || ok

# ── G9: static. Nothing reads the thread-scan function or the knob.
H9=$(cd "$DIR" && grep -rln 'pb_stranded_skip' bin 2>/dev/null)
[ -z "$H9" ] && ok || bad "G9: pb_stranded_skip is gone from bin/: $H9"
H9=$(cd "$DIR" && grep -rln 'STRANDED_SKIP_PLAN_BLOCKED' bin catalog 2>/dev/null)
[ -z "$H9" ] && ok || bad "G9: STRANDED_SKIP_PLAN_BLOCKED is gone from bin/ and catalog/: $H9"

echo "orphan-reconcile-phase-gate (BH-9457): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
