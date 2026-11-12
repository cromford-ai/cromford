#!/bin/bash
# tests/pool-wait-gates.bh-9283-test.sh — BH-9283 slice C0: the pool's
# defer-after stop (bin/lib/defer-after-stop.sh) sees stack-wait and
# Blocked-by deferrals, re-checks a waiting row on growing delays, releases it
# at a time limit with one alert, and marks it held for the fleet page.
#
# THE INCIDENT. project-6 TK-3660 stood down `BUILD_DEFERRED stack-wait: parent
# branch ticket/TK-3659 is still open ...` and the pool spawned a machine for
# it every tick (6 spawns 22:10Z-23:00Z on 2026-11-06): _dfs_blocker read only
# `After: KEY` and OVERLAP_DEFER. TK-3577 waited 5498 min on an After wait with
# no limit and no alert, and the fleet page counted it as queued.
#
#   P1-P14 the parser table (defer_wait_key and _dfs_blocker, direct calls)
#   W1     the wait line round-trips 6 fields; a new blocker restarts the clock
#   S1     a stack-wait record: 6 ticks, 0 machines, 2 open-list reads
#   S2     the parent PR goes: held until the next due re-check, then spawns
#          and removes .dfs-wait and .held
#   R1     re-check reads at minutes 0, 10, 30, 70, 150, 310, 550 only
#   R2     a not-due tick: 0 open-list reads, 0 machines, the skip line
#   R3-R5  POOL_WAIT_RECHECK_MIN=0 / =x / POOL_WAIT_RECHECK_MAX_MIN=30
#   L1-L5  the time limit and its one alert
#   H1-H4  the .held marker, the fleet page, a foreign marker, an unreadable list
#   E1     the knob off writes no state
#   G      every gh and fly call is a fake
#
# Driven through bin/fly-pool.sh against a scratch HARNESS, a fake flyctl, a
# fake gh and a recording jobs client (the tests/pool-defer-after-stop.bh-8880
# rig). The gate's clock is DFS_NOW; the file reads the real clock once.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/pool-wait-gates.bh-9283-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
bad(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
# ONE clock read for the file (bin/test-determinism-lint.sh).
NOW=$(date -u +%s)
iso() { date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ'; }

P=project-6
H="$T/h"
mkdir -p "$H/bin/lib/jobs" "$H/logs" "$H/flags" "$H/locks" "$H/env" "$H/fly" \
         "$H/state/fly" "$H/state/fly-pool/$P" \
         "$H/state/build-queue/$P" "$H/state/remote-results/$P" \
         "$H/state/pool/$P" "$H/builds" "$T/fakebin"
printf 'FLY_API_TOKEN_project-6=fixture-fly-token\n' > "$H/env/fly.env"
: > "$H/env/global.env"
printf '%s example-org/%s - - 0 local\n' "$P" "$P" > "$H/fleet.conf"
printf '3\n' > "$H/flags/fly-pool-$P"
printf 'pool-%s\n' "$P" > "$H/flags/fly-pool-app-$P"
printf '{"app":"pool-%s"}\n' "$P" > "$H/state/fly/$P.json"
printf 'registry.fly.io/pool-%s:deploy-01\n' "$P" > "$H/state/fly/$P.image"
for L in bin/result-prefix-ok.sh bin/fleet-conf.sh bin/alert-line.sh bin/lib/hold.sh bin/lib/deferral-after.sh \
         bin/lib/defer-after-stop.sh bin/lib/plan-blocked.sh bin/lib/tracker.sh bin/lib/gh-rest.sh \
         bin/lib/pool-hold-cache.sh bin/lib/stack-wait.sh; do
  [ -f "$DIR/$L" ] || { bad "$L is missing"; continue; }
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
printf '#!/bin/bash\nmkdir -p "$2"; : > "$2/global.env"; : > "$2/$1.env"; exit 0\n' > "$H/bin/fly-envbundle.sh"
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/fakebin/timeout"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/sleep"
cat > "$H/bin/jobs-client.sh" <<JC
[ "\${BASH_SOURCE[0]}" = "\$0" ] && exit 1
queue_put()  { printf 'put %s\n' "\$*" >> "$T/q.log"; echo queued; }
queue_done() { printf 'done %s\n' "\$*" >> "$T/q.log"; return 0; }
JC
cat > "$T/fakebin/base64" <<'B64'
#!/bin/bash
REAL=/usr/bin/base64; [ -x "$REAL" ] || REAL=/bin/base64
DEC=0; W0=0; FILE=""
for a in "$@"; do
  case "$a" in
    -d|-D)  DEC=1 ;;
    -w0|-w) W0=1 ;;
    0)      ;;
    -*)     ;;
    *)      FILE="$a" ;;
  esac
done
GNU=0; printf 'eA==' | "$REAL" -d >/dev/null 2>&1 && GNU=1
FLAGS=()
if [ "$DEC" = 1 ]; then
  [ "$GNU" = 1 ] && FLAGS+=(-d) || FLAGS+=(-D)
elif [ "$W0" = 1 ]; then
  [ "$GNU" = 1 ] && FLAGS+=(-w0) || FLAGS+=(-b 0)
fi
if [ -n "$FILE" ]; then exec "$REAL" "${FLAGS[@]}" < "$FILE"; fi
exec "$REAL" "${FLAGS[@]}"
B64
cat > "$T/fakebin/fly" <<FLY
#!/bin/bash
echo "\$*" >> "$T/fly-calls"
case "\$*" in
  *"machine status"*) echo "State: started" ;;
  *"machines list"*) echo '[]' ;;
  *"machine run"*) printf 'Machine ID: 1234567890abcd\\n' ;;
esac
exit 0
FLY
# gh: the 8880 fake on example-org/project-6, issues 3577 3578 3659 3660.
cat > "$T/fakebin/gh" <<GH
#!/bin/bash
echo "\$*" >> "$T/gh-calls"
a="\$*"
if [[ "\$a" == *"--paginate"*"comments"* ]]; then echo '[]'; exit 0; fi
if [[ "\$a" != *"-i"* ]]; then
  if [[ "\$a" =~ issues/([0-9]+) ]]; then
    echo '{"state":"open","labels":[{"name":"ai-build"}],"title":"MK fixture","body":""}'; exit 0
  fi
  echo "\$a" >> "$T/realgh.log"; exit 1
fi
case "\$a" in
  *"pulls?state=open"*"head="*) printf 'HTTP/1.1 200 OK\\n\\n[]\\n' ;;
  *"pulls?state=open"*)
    if [ -e "$T/open-prs.502" ]; then printf 'HTTP/1.1 502 Bad Gateway\\n\\n{}\\n'
    else printf 'HTTP/1.1 200 OK\\n\\n'; cat "$T/open-prs.json"; fi ;;
  *"issues?state=open"*"labels=ai-build"*)
    printf 'HTTP/1.1 200 OK\\n\\n'
    for n in 3577 3578 3659 3660; do
      jq -nc --argjson n "\$n" --arg u "\$(cat "$T/upd-\$n" 2>/dev/null || echo 2026-10-20T00:00:00Z)" \
        '{number:\$n,updated_at:\$u,comments:0,state:"open",title:"MK fixture",body:"",labels:[{name:"ai-build"}]}'
    done | jq -sc . ;;
  *"issues/"*"/comments?since="*)
    n=\$(sed -nE 's#.*issues/([0-9]+)/comments.*#\\1#p' <<<"\$a")
    printf 'HTTP/1.1 200 OK\\n\\n'; cat "$T/comments-\$n.json" 2>/dev/null || echo '[]' ;;
  *"repos/example-org/project-6 "*|*"repos/example-org/project-6") printf 'HTTP/1.1 200 OK\\n\\n{"full_name":"example-org/project-6"}\\n' ;;
  *) echo "\$a" >> "$T/realgh.log"; printf 'HTTP/1.1 404 Not Found\\n\\n{}\\n' ;;
esac
exit 0
GH
chmod +x "$H/bin/"*.sh "$T/fakebin"/*

# run_pool <minute> [VAR=value...] — one pool tick with the gate clock at
# NOW + minute*60 (a minute may carry seconds as M:S).
run_pool() {
  local m="$1" s=0; shift
  case "$m" in *:*) s="${m#*:}"; m="${m%%:*}" ;; esac
  : > "$H/logs/fly-pool.log"; : > "$T/fly-calls"; : > "$T/q.log"; : > "$T/gh-calls"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" \
           FLY_API_TOKEN_project-6=fixture-fly-token FLY_BIN_DIR="$T/fakebin" \
           DFS_NOW=$((NOW + m * 60 + s)) "$@"
    bash "$DIR/bin/fly-pool.sh" "$P" >/dev/null 2>&1 )
}
reset_state() {
  local p
  for p in "$H/state/build-queue/$P"/*.json \
           "$H/state/fly-pool/$P"/*.json \
           "$H/state/pool/$P"/* "$H/builds"/* \
           "$T"/comments-*.json "$T"/upd-* "$T/open-prs.502"; do
    [ -e "$p" ] && scratch_rm "$p"
  done
  : > "$H/logs/ALERTS.log"
  return 0
}
# respawnable — drop the machine records so the row is offered again.
respawnable() { local p; for p in "$H/state/fly-pool/$P"/*.json; do [ -e "$p" ] && scratch_rm "$p"; done; return 0; }
open_prs() {
  local b n=3700
  for b in "$@"; do
    n=$((n + 1))
    jq -nc --arg r "ticket/$b" --argjson n "$n" \
      '{number:$n,title:"fixture",html_url:"https://github.com/example-org/project-6/pull/\($n)",head:{ref:$r,repo:{owner:{login:"example-org"}}}}'
  done | jq -sc . > "$T/open-prs.json"
}
qrow() {
  jq -nc --arg k "$1" --arg t "${1#TK-}" \
    '{ticket_id:$t,key:$k,attempt:1,deferrals:3,deaths:0,enqueued_at:"2026-11-06T13:00:00Z"}' \
    > "$H/state/build-queue/$P/$1.json"
}
# rec <key> <stamp> <age-s> <RESULT line 1> — one hub record, mtime NOW-age
# (a negative age is a record written later in the test).
rec() {
  local d="$H/builds/pool-$P-$1-$2"; mkdir -p "$d"
  printf '%s\n' "$4" > "$d/RESULT"
  touch -d "@$((NOW - $3))" "$d/RESULT"
}
recd() { printf '%s' "$H/builds/pool-$P-$1-$2"; }
spawned() { local c; c=$(grep -c 'machine run' "$T/fly-calls" 2>/dev/null); echo "${c:-0}"; }
lines() { local c; c=$(grep -cF "$1" "$H/logs/fly-pool.log" 2>/dev/null); echo "${c:-0}"; }
LREAD='pulls?state=open&per_page=100&page=1'
reads() { local c; c=$(grep -cF "${1:-$LREAD}" "$T/gh-calls" 2>/dev/null); echo "${c:-0}"; }
alerts() { local c; c=$(grep -cF "${1:-WAIT LIMIT}" "$H/logs/ALERTS.log" 2>/dev/null); echo "${c:-0}"; }
log_of() { grep -E "$1" "$H/logs/fly-pool.log" | tail -3 | tr '\n' '|'; }
WAITF="$H/state/pool/$P/TK-3660.dfs-wait"
HELDF="$H/state/pool/$P/TK-3660.held"
STACK="BUILD_DEFERRED stack-wait: parent branch ticket/TK-3659 is still open and TK-3660 has waited 0h of STACK_WAIT_CAP_H=24h — Blocked-by #3659; the child builds after the parent merges"
SKIP="skipping TK-3660: waits on TK-3659 PR open — no machine"
AFTER="BUILD_DEFERRED After: TK-3578 PR #3597 open — TK-3577 overlaps it on a non-splittable file and builds after it merges"

# ── P1-P14: the parser table ─────────────────────────────────────────────
parse() { # parse <fn> <own-key> <line> -> "<out>|rc"
  ( HARNESS="$H"; . "$DIR/bin/lib/deferral-after.sh"; . "$DIR/bin/lib/defer-after-stop.sh"
    if [ "$1" = dwk ]; then o=$(defer_wait_key "$3" "$2"); else o=$(_dfs_blocker "$2" "$3"); fi
    rc=$?; printf '%s|%s' "$(printf '%s' "$o" | tr '\t' ',')" "$rc" ) 2>/dev/null
}
pcase() { # pcase <id> <own> <line> <want _dfs_blocker> [<want defer_wait_key>]
  local g; g=$(parse dfb "$2" "$3")
  [ "$g" = "$4" ] && ok || bad "$1: _dfs_blocker $2 '${3:0:70}' wants '$4', got '$g'"
  if [ -n "${5:-}" ]; then g=$(parse dwk "$2" "$3")
    [ "$g" = "$5" ] && ok || bad "$1: defer_wait_key $2 '${3:0:70}' wants '$5', got '$g'"
  fi
}
pcase P1 TK-3786 "BUILD_DEFERRED After: TK-3785 PR #3958 open — x" "TK-3785,3958,after|0" "TK-3785,after|0"
pcase P2 TK-3660 "$STACK" "TK-3659,,stack|0" "TK-3659,stack|0"
pcase P3 TK-3660 "BUILD_DEFERRED stack-wait: parent branch ticket/TK-3659-r2 is still open and STACK_WAIT_PARENT_MERGE=all — the child builds after the parent merges" "TK-3659,,stack|0" "TK-3659,stack|0"
pcase P4 TK-3660 "BUILD_DEFERRED stack-wait: TK-3660's plan builds on open parent ticket/TK-3659 and files overlap — Blocked-by #3659; the child builds from main after the parent merges" "TK-3659,,stack|0" "TK-3659,stack|0"
pcase P5 TK-3660 "BUILD_DEFERRED stack-wait: the state of parent PR for branch ticket/TK-3659 could not be read (rc 75) — waiting; a merge is never assumed" "TK-3659,,stack|0" "TK-3659,stack|0"
pcase P6 TK-3660 "BUILD_DEFERRED waits on parent — Blocked-by #3659" "TK-3659,,blocked|0" "TK-3659,blocked|0"
pcase P7 TK-3786 "BUILD_DEFERRED OVERLAP_DEFER TK-3786 vs TK-3785-r2 files=[bin/x.sh]" "TK-3785,,after|0"
pcase P8 TK-3660 "BUILD_DEFERRED stack-wait: parent branch ticket/TK-3660 is still open" "|1" "|1"
pcase P9 TK-3660 "BUILD_DEFERRED stack-wait: parent branch feature/foo is still open" "|1" "|1"
pcase P10 TK-3660 "BUILD_DEFERRED stack-wait: parent branch ticket/TK-3659.2 is still open" "|1"
pcase P11 TK-3660 "PR_CREATED https://github.com/x/y/pull/1 — Blocked-by #3659" "|1"
pcase P12 TK-3660 "BUILD_DEFERRED hold unreadable at pr-open — retried" "|1" "|1"
pcase P13 TK-3660 "BUILD_DEFERRED not Blocked-by anything" "|1" "|1"
pcase P13b TK-3660 "BUILD_DEFERRED waits — Blocked-by #abc" "|1" "|1"
pcase P14 TK-3660 "BUILD_DEFERRED After: TK-3659 PR #1 open" "|1" "|1"

# ── W1: the wait line round-trips; a new blocker restarts the clock ──────
reset_state
W=$( ( HARNESS="$H"; . "$DIR/bin/lib/deferral-after.sh"; . "$DIR/bin/lib/defer-after-stop.sh"
       _dfs_wait_put "$P" TK-3660 TK-3659 stack 1000 3 4000 1500
       printf '%s|' "$(_dfs_wait_get "$P" TK-3660 | tr '\t' ',')"
       _dfs_wait_load "$P" TK-3660 TK-3659 stack 9000
       printf '%s,%s,%s,%s,%s|' "$_DFS_W_SINCE" "$_DFS_W_CHECKS" "$_DFS_W_NEXT" "$_DFS_W_ALERTED" "$_DFS_W_NEW"
       _dfs_wait_load "$P" TK-3660 TK-3001 after 9000
       printf '%s,%s,%s,%s,%s' "$_DFS_W_SINCE" "$_DFS_W_CHECKS" "$_DFS_W_NEXT" "$_DFS_W_ALERTED" "$_DFS_W_NEW" ) 2>&1)
[ "$W" = "TK-3659,stack,1000,3,4000,1500|1000,3,4000,1500,0|9000,0,0,,1" ] && ok \
  || bad "W1: the wait line wants 'TK-3659,stack,1000,3,4000,1500|1000,3,4000,1500,0|9000,0,0,,1', got '$W'"

# ── S1: the live case, red on main ────────────────────────────────────────
reset_state; open_prs TK-3659; qrow TK-3660; rec TK-3660 s1 600 "$STACK"
S1R=0; S1S=0
for m in 0 5 10 15 20 25; do
  run_pool "$m"
  S1R=$((S1R + $(reads))); S1S=$((S1S + $(spawned)))
  [ -e "$H/state/build-queue/$P/TK-3660.json" ] || bad "S1: minute $m: the queue file must stay"
  grep -q 'TK-3660' "$T/q.log" && bad "S1: minute $m: no QROW write for a held row ($(tr '\n' '|' < "$T/q.log"))"
  [ "$(lines 'skipping TK-3660: waits on TK-3659')" = 1 ] || bad "S1: minute $m wants one skip line: $(log_of TK-3660)"
done
[ "$S1S" = 0 ] && ok || bad "S1: THE BUG: $S1S machine(s) spawned for TK-3660 over 6 ticks while ticket/TK-3659 is open"
[ "$S1R" = 2 ] && ok || bad "S1: open-list reads at minutes 0 and 10 only, got $S1R"

# ── S2: the parent PR goes; released on the next due re-check ────────────
reset_state; open_prs TK-3659; qrow TK-3660; rec TK-3660 s1 600 "$STACK"
run_pool 0; run_pool 10
open_prs TK-9999
run_pool 20
[ "$(spawned)" = 0 ] && [ "$(reads)" = 0 ] && ok || bad "S2: minute 20 is not due (due at 30): held with no read ($(spawned) spawned, $(reads) reads)"
run_pool 30
[ "$(spawned)" = 1 ] && ok || bad "S2: minute 30 re-checks, the parent PR is gone, so TK-3660 spawns ($(spawned)): $(log_of TK-3660)"
[ ! -e "$WAITF" ] && [ ! -e "$HELDF" ] && ok || bad "S2: release removes .dfs-wait and .held"

# ── R1: the re-check schedule 10, 20, 40, 80, 160, 240 ───────────────────
# r1 <id> <reads-wanted minutes> <ticks...> [-- VAR=value]
r1() {
  local id="$1" want=" $2 " m got="" env=() ticks=()
  shift 2
  while [ $# -gt 0 ]; do [ "$1" = -- ] && { shift; env=("$@"); break; }; ticks+=("$1"); shift; done
  reset_state; open_prs TK-3659; qrow TK-3660; rec TK-3660 s1 600 "$STACK"
  for m in "${ticks[@]}"; do
    run_pool "$m" "${env[@]}"
    [ "$(spawned)" = 0 ] || bad "$id: minute $m spawned a machine"
    [ "$(reads)" -gt 0 ] && got="$got$m "
  done
  [ " $got" = "$want" ] && ok || bad "$id: reads wanted at minutes '$want', got ' $got'"
}
r1 R1 "0 10 30 70 150 310 550" 0 5 10 25 30 65 70 145 150 305 310 545 550 555

# ── R2: a not-due tick ────────────────────────────────────────────────────
reset_state; open_prs TK-3659; qrow TK-3660; rec TK-3660 s1 600 "$STACK"
run_pool 0; run_pool 5
[ "$(reads)" = 0 ] && [ "$(spawned)" = 0 ] && ok || bad "R2: a not-due tick: 0 reads and 0 machines ($(reads), $(spawned))"
grep -qE "^.*$SKIP; next re-check [0-9]{2}:[0-9]{2}Z$" "$H/logs/fly-pool.log" && ok \
  || bad "R2: the old skip text, then '; next re-check HH:MMZ': $(log_of TK-3660)"

# ── R3-R5: the two knobs ──────────────────────────────────────────────────
r1 R3 "0 5 10" 0 5 10 -- POOL_WAIT_RECHECK_MIN=0
r1 R4 "0 10 30" 0 5 10 25 30 -- POOL_WAIT_RECHECK_MIN=x
r1 R5 "0 10 30 60 90" 0 5 10 25 30 55 60 85 90 -- POOL_WAIT_RECHECK_MAX_MIN=30

# ── L1-L3: the After limit (POOL_AFTER_MAX_MIN, 360) ─────────────────────
reset_state; open_prs TK-3578; qrow TK-3577; rec TK-3577 s1 600 "$AFTER"
run_pool 0
[ "$(spawned)" = 0 ] && [ "$(alerts)" = 0 ] && ok \
  || bad "L3: the first tick holds with 0 alerts ($(spawned) spawned, $(alerts) alerts): $(log_of TK-3577)"
run_pool 359:59
[ "$(spawned)" = 0 ] && [ "$(alerts)" = 0 ] && ok \
  || bad "L1: 1 s before 360 min held with 0 alerts ($(spawned) spawned, $(alerts) alerts): $(log_of TK-3577)"
run_pool 360
[ "$(spawned)" = 1 ] && ok || bad "L2: at 360 min TK-3577 spawns ($(spawned)): $(log_of TK-3577)"
[ -e "$(recd TK-3577 s1)/defer-after.released" ] && ok || bad "L2: the released marker is written"
[ "$(alerts)" = 1 ] && grep -F 'WAIT LIMIT' "$H/logs/ALERTS.log" | grep -F 'TK-3578' | grep -qF '#3597' && ok \
  || bad "L2: exactly one ALERTS line naming TK-3578 and #3597: $(tr '\n' '|' < "$H/logs/ALERTS.log")"
[ "$(lines 'RELEASED TK-3577: wait limit')" = 1 ] && ok || bad "L2: the RELEASED line: $(log_of TK-3577)"
[ ! -e "$H/state/pool/$P/TK-3577.held" ] && ok || bad "L2: the limit release removes .held"
# L3 again: a record 5498 min old starts its clock at the first held tick.
reset_state; open_prs TK-3578; qrow TK-3577; rec TK-3577 s1 $((5498 * 60)) "$AFTER"
run_pool 0
[ "$(spawned)" = 0 ] && [ "$(alerts)" = 0 ] && ok \
  || bad "L3: a 5498-min-old record holds on the first tick with 0 alerts ($(spawned) spawned, $(alerts) alerts)"

# ── L4: the stack limit (STACK_WAIT_CAP_H, 24 h) and one alert per blocker
reset_state; open_prs TK-3659; qrow TK-3660; rec TK-3660 s1 600 "$STACK"
run_pool 0
run_pool 1439:59
[ "$(spawned)" = 0 ] && ok || bad "L4: 1 s before 24 h held ($(spawned))"
run_pool 1440
[ "$(spawned)" = 1 ] && [ "$(alerts)" = 1 ] && grep -F 'WAIT LIMIT' "$H/logs/ALERTS.log" | grep -qF 'TK-3659' && ok \
  || bad "L4: at 24 h 1 spawn and 1 alert naming TK-3659 ($(spawned), $(alerts)): $(tr '\n' '|' < "$H/logs/ALERTS.log")"
# The machine stands down again on the same blocker: a newer record.
respawnable; qrow TK-3660; rec TK-3660 s2 -60 "$STACK"
run_pool 1445
[ "$(spawned)" = 0 ] && ok || bad "L4: the new record on the same blocker holds again ($(spawned))"
run_pool 2885
[ "$(spawned)" = 1 ] && ok || bad "L4: a second 24 h releases again ($(spawned)): $(log_of TK-3660)"
[ "$(alerts)" = 1 ] && ok || bad "L4: the same blocker pages once, got $(alerts) WAIT LIMIT lines"

# ── L5: POOL_AFTER_MAX_MIN=0 is no limit ─────────────────────────────────
reset_state; open_prs TK-3578; qrow TK-3577; rec TK-3577 s1 600 "$AFTER"
run_pool 0 POOL_AFTER_MAX_MIN=0
run_pool 2000 POOL_AFTER_MAX_MIN=0
[ "$(spawned)" = 0 ] && [ "$(alerts)" = 0 ] && ok \
  || bad "L5: POOL_AFTER_MAX_MIN=0 holds at 2000 min with 0 alerts ($(spawned), $(alerts))"

# ── H1-H2: a held row counts as held on the fleet page ───────────────────
reset_state; open_prs TK-3659; qrow TK-3660; rec TK-3660 s1 600 "$STACK"
run_pool 0
W=$(jq -r '.why // empty' "$HELDF" 2>/dev/null)
case "$W" in "defer-after: waits on TK-3659 PR open (stack)") ok ;; *) bad "H1: .held why wants 'defer-after: waits on TK-3659 PR open (stack)', got '$W'" ;; esac
[ "$(jq -r '.key + "|" + .ticket_id' "$HELDF" 2>/dev/null)" = "TK-3660|3660" ] && ok || bad "H1: .held carries key and ticket_id"
[ -s "$WAITF" ] && ok || bad "H1/E2: a held tick writes .dfs-wait"
FS="$T/fs"; mkdir -p "$FS/bin/lib" "$FS/logs" "$FS/env" "$FS/fakebin" "$FS/state/build-queue/$P" "$FS/state/pool/$P"
cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/fleet-fly-block.sh" "$FS/bin/"
# The bh-1461 rig: only the push's URL lib, so the push takes the file path
# (no jobs client in the tree).
( cd "$DIR" && scratch_install_closure bin/lib/watchdog-url.sh "$FS" ) >/dev/null || bad "H2: setup: could not install bin/lib/watchdog-url.sh"
printf 'HARNESS_SECRET=test-secret\nCONSOLE_URL=http://console.invalid\nWATCHDOG_URL=http://watchdog.invalid\n' > "$FS/env/global.env"
printf '#!/bin/bash\nexit 0\n' > "$FS/bin/beat.sh"
printf '#!/bin/bash\ncat > %s/PUSH.json\n' "$FS" > "$FS/fakebin/curl"; chmod +x "$FS/bin/beat.sh" "$FS/fakebin/curl"
sed "s|^H=/root/harness|H=$FS|" "$DIR/bin/fleet-status-push.sh" > "$FS/fsp.sh"
printf '%s example-org/%s https://a.example /api/board 2 box-%s\n' "$P" "$P" "$P" > "$FS/fleet.conf"
echo "a recent triage line" > "$FS/logs/$P.log"
cp "$H/state/build-queue/$P/TK-3660.json" "$FS/state/build-queue/$P/"
touch -d "@$((NOW - 300 * 60))" "$FS/state/build-queue/$P/TK-3660.json"
jq -nc '{ticket_id:"3001",key:"TK-3001",attempt:1}' > "$FS/state/build-queue/$P/TK-3001.json"
touch -d "@$((NOW - 10 * 60))" "$FS/state/build-queue/$P/TK-3001.json"
cp "$HELDF" "$FS/state/pool/$P/" 2>/dev/null
# FLEET_CONF and file mode pin the fixture list: bin/fleet-conf.sh reads
# /root/harness/fleet.conf before a tree-local one, so with no FLEET_CONF the
# push would read this box's real fleet list.
( PATH="$FS/fakebin:$PATH" FLEET_CONF="$FS/fleet.conf" REGISTRY_SOURCE=file bash "$FS/fsp.sh" ) >/dev/null 2>&1
FH=$(jq -r ".projects.\"$P\".held // \"missing\"" "$FS/PUSH.json" 2>/dev/null)
FQ=$(jq -r ".projects.\"$P\".oldest_queued_min // \"missing\"" "$FS/PUSH.json" 2>/dev/null)
[ "$FH" = 1 ] && ok || bad "H2: the fleet page counts the dfs-held row as held (held=$FH)"
[ "$FQ" -lt 100 ] 2>/dev/null && ok || bad "H2: the 300-min held row leaves oldest_queued_min (got $FQ)"

# ── H3: a release leaves a marker another gate wrote ─────────────────────
# Direct: the pool's HOLD gate clear arm runs after a release and has its own
# rule, so the dfs cleanup is read on its own.
reset_state
H3=$( ( HARNESS="$H"; . "$DIR/bin/lib/deferral-after.sh"; . "$DIR/bin/lib/defer-after-stop.sh"
        printf '{"key":"TK-3660","why":"terminal: push rejected"}\n' > "$HELDF"
        _dfs_held_clear "$P" TK-3660; [ -e "$HELDF" ] && printf kept || printf gone; printf '|'
        printf '{"key":"TK-3660","why":"defer-after: waits on TK-3659 PR open (stack)"}\n' > "$HELDF"
        _dfs_held_clear "$P" TK-3660; [ -e "$HELDF" ] && printf kept || printf gone ) 2>&1)
[ "$H3" = "kept|gone" ] && ok || bad "H3: _dfs_held_clear keeps a foreign marker and removes its own (got '$H3')"
reset_state; open_prs TK-3659; qrow TK-3660; rec TK-3660 s1 600 "$STACK"
printf '{"key":"TK-3660","ticket_id":"3660","why":"terminal: push rejected","first_seen":"x","last_seen":"x"}\n' > "$HELDF"
run_pool 0
[ "$(jq -r '.why' "$HELDF" 2>/dev/null)" = "terminal: push rejected" ] && ok || bad "H3: a dfs hold does not overwrite a terminal .held marker"

# ── H4/E6: an unreadable open-PR list ────────────────────────────────────
reset_state; open_prs TK-3659; : > "$T/open-prs.502"; qrow TK-3660; rec TK-3660 s1 600 "$STACK"
run_pool 0
[ "$(spawned)" = 0 ] && [ ! -e "$HELDF" ] && [ ! -e "$WAITF" ] && ok \
  || bad "H4: unreadable on the first tick: held, no .held, no .dfs-wait ($(spawned))"
[ "$(lines 'skipping TK-3660: waits on TK-3659, and the open-PR list did not answer — retried next tick, no machine')" = 1 ] && ok \
  || bad "H4: the 8880 retry line: $(log_of TK-3660)"
scratch_rm "$T/open-prs.502"; run_pool 1
W0=$(cat "$WAITF" 2>/dev/null); M0=$(cat "$HELDF" 2>/dev/null)
: > "$T/open-prs.502"; run_pool 11
[ "$(spawned)" = 0 ] && [ "$(cat "$WAITF" 2>/dev/null)" = "$W0" ] && [ "$(cat "$HELDF" 2>/dev/null)" = "$M0" ] && [ -n "$M0" ] && ok \
  || bad "H4: an unreadable due tick keeps .held and leaves checks and next_at unchanged"
run_pool 12
[ "$(reads)" -gt 0 ] && ok || bad "H4: the next tick reads again after an unreadable one"

# ── E5: a person comment releases and removes .held ──────────────────────
reset_state; open_prs TK-3659; qrow TK-3660; rec TK-3660 s1 600 "$STACK"
run_pool 0
[ -e "$HELDF" ] || bad "E5: setup: the held tick writes .held"
iso $((NOW - 60)) > "$T/upd-3660"
jq -nc --arg c "$(iso $((NOW - 60)))" '[{user:{login:"client-fixture",type:"User"},created_at:$c,updated_at:$c,body:"go"}]' > "$T/comments-3660.json"
run_pool 5
[ "$(spawned)" = 1 ] && [ -e "$(recd TK-3660 s1)/defer-after.released" ] && [ ! -e "$HELDF" ] && ok \
  || bad "E5: a person comment on a not-due tick releases, writes the marker and removes .held ($(spawned)): $(log_of TK-3660)"

# ── E1: the knob off writes no state ─────────────────────────────────────
reset_state; open_prs TK-3659; qrow TK-3660; rec TK-3660 s1 600 "$STACK"
run_pool 0 POOL_DEFER_AFTER_STOP=0
[ "$(spawned)" = 1 ] && [ ! -e "$WAITF" ] && [ ! -e "$HELDF" ] && ok \
  || bad "E1: POOL_DEFER_AFTER_STOP=0 spawns and writes no state ($(spawned))"

# ── G: 0 real network ─────────────────────────────────────────────────────
[ ! -s "$T/realgh.log" ] && ok || bad "G: a gh call the fake does not know: $(head -3 "$T/realgh.log" | tr '\n' '|')"

echo "pool-wait-gates.bh-9283: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
