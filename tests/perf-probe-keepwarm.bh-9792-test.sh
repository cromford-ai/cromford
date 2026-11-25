#!/bin/bash
# tests/perf-probe-keepwarm.bh-9792-test.sh — BH-9792: the keep-warm lane
# bin/perf-probe-keepwarm.sh. It runs the REAL lane of a scratch harness
# against the fake app with a 12-route row and a session that answers an
# expiresAt one day ahead. Clock pinned by PERF_PROBE_NOW.
#
#   L2   the lane registry entry perf-probe-keepwarm, its 3 knob defaults,
#        zero_means off on PERF_PROBE_KEEPWARM_MIN
#   P16a no knob row, ticks at T and T+5 min: each GETs the first 10 routes
#        once (routes 11, 12: 0); 1 session POST; 0 result rows (O2)
#   P16b PERF_PROBE_KEEPWARM_MIN=0: 0 requests
#   P16c keepwarm:false: 0 requests; P16i keepwarm:true and absent: runs
#   P16d a tick at T+2 min: 0 requests
#   P16e every route 503, 3 ticks: one `keepwarm paused` line; 4th tick 0 requests
#   P16f ppio_keepwarm_reset, then a tick: 10 requests again
#   P16g one 2xx of 10: the round passed, fails 0
#   P16h session 403: fails 1, 0 route requests
#   P16j lock held: 0 requests, state unchanged
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/perf-probe-keepwarm.bh-9792-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/perf-probe-warm.bh-9792.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }
trap 'ppt_server_stop' EXIT
SESSION=/api/internal/e2e/session
for f in bin/perf-probe-keepwarm.sh catalog/lanes.d/perf-probe-keepwarm.json cron/lanes/786-perf-probe-keepwarm.cron; do
  [ -f "$REPO/$f" ] || bad "missing $f"
done
ROUTES='["/r1","/r2","/r3","/r4","/r5","/r6","/r7","/r8","/r9","/r10","/r11","/r12"]'
sess='{"status":200,"set_cookie":"pp_sid=kw; Path=/; HttpOnly","json":{"expiresAt":"2026-11-19T06:17:00Z"}}'
# state <status-of-each-route> [status of /r1]
state() {
  local i s="{\"paths\":{\"$SESSION\":$sess"
  for i in $(seq 1 12); do
    if [ "$i" = 1 ] && [ -n "${2:-}" ]; then s+=",\"/r$i\":{\"status\":$2}"; else s+=",\"/r$i\":{\"status\":$1}"; fi
  done
  printf '%s}}' "$s"
}
row() {
  jq -cn --arg p "$1" --arg b "$PPT_BASE" --argjson r "$ROUTES" \
    '{project:$p, enabled:true, base_url:$b, session_path:"/api/internal/e2e/session", signin_path:"/sign-in",
      roles:["admin"], routes:$r, budgets:{}}' | jq -c "${2:-.}"
}
setup() { # <case> <project> [row jq] [route status]
  pwt_tree "$1" || exit 1; pwt_server "$1" || exit 1; ppt_env_token "$2"
  ppt_state "$(state "${4:-200}")"
  ppt_row "$2" "$(row "$2" "${3:-.}")"
}
kw() { pwt_lane perf-probe-keepwarm.sh "$@"; }
klog() { cat "$PPT_H/logs/perf-probe-keepwarm.log" 2>/dev/null; }
kstate() { jq -c . "$PPT_H/state/perf-probe/$1/keepwarm.json" 2>/dev/null; }
gets() { ppt_count '.method=="GET"'; }
first10() { local i; for i in $(seq 1 10); do [ "$(ppt_count ".path==\"/r$i\"")" = "$1" ] || return 1; done; }

# ══ L2 the lane registry ═════════════════════════════════════════════════════
L=$REPO/catalog/lanes.d/perf-probe-keepwarm.json
got=$(jq -c '[.id,.scope,.cadence,.boxes,.switch.name,.wired,.script,.stats.log]' "$L" 2>/dev/null)
[ "$got" = '["perf-probe-keepwarm","hub","* * * * *",["hub"],"lane-off-perf-probe-keepwarm",true,"bin/perf-probe-keepwarm.sh","logs/perf-probe-keepwarm.log"]' ] \
  && ok || bad "L2 lane entry: $got"
got=$(jq -c '[.knobs[] | [.env,.default,.zero_means]]' "$L" 2>/dev/null)
[ "$got" = '[["PERF_PROBE_KEEPWARM_MIN",5,"off"],["PERF_PROBE_KEEPWARM_ROUTES",10,null],["PERF_PROBE_KEEPWARM_FAIL_MAX",3,null]]' ] \
  && ok || bad "L2 knobs: $got"
grep -qE '^\* \* \* \* \* /root/harness/bin/hub-lease.sh check && /root/harness/bin/perf-probe-keepwarm.sh >> /root/harness/logs/perf-probe-keepwarm.log 2>&1$' \
  "$REPO/cron/lanes/786-perf-probe-keepwarm.cron" && ok || bad "L2 cron fragment"

# ══ O2 / P16a / P16d two rounds 5 minutes apart, none in between ═════════════
setup p16a pp-p16a
kw; rc=$?
[ "$rc" = 0 ] && first10 1 && [ "$(ppt_count '.path=="/r11" or .path=="/r12"')" = 0 ] && ok || bad "P16a tick 1: want the first 10 routes once: $(ppt_reqs '.path' | paste -sd' ')"
[ "$(kstate pp-p16a)" = '{"last_at":"2026-11-18T06:17:00Z","fails":0}' ] && ok || bad "P16a state: $(kstate pp-p16a)"
kw PERF_PROBE_NOW=2026-11-18T06:19:00Z
[ "$(gets)" = 10 ] && ok || bad "P16d a tick inside MIN must not load: $(gets) GETs"
kw PERF_PROBE_NOW=2026-11-18T06:22:00Z
first10 2 && [ "$(ppt_count '.path=="/r11" or .path=="/r12"')" = 0 ] && ok || bad "P16a tick 2: $(ppt_reqs '.path' | paste -sd' ')"
[ "$(ppt_count ".method==\"POST\" and .path==\"$SESSION\"")" = 1 ] && ok || bad "O2 want 1 session POST over 2 rounds: $(ppt_reqs 'select(.method=="POST")')"
[ "$(ppt_count ".method!=\"GET\" and .path!=\"$SESSION\"")" = 0 ] && ok || bad "O2 a non-GET request: $(ppt_reqs)"
[ "$(ppt_d1 "SELECT count(*) FROM perf_probe_results")" = "" ] || [ "$(ppt_d1 "SELECT count(*) FROM perf_probe_results")" = 0 ] && ok || bad "P16a a result row was written"
[ ! -s "$PPT_STUB.calls" ] && [ ! -s "$PWT_JC.calls" ] && ok || bad "P16a the lane called the jobs client"
[ -z "$(klog)" ] && ok || bad "P16a a normal round wrote a line: $(klog)"

# ══ P16b MIN=0 is off ════════════════════════════════════════════════════════
setup p16b pp-p16b
kw PERF_PROBE_KEEPWARM_MIN=0
[ "$(ppt_count '.')" = 0 ] && [ -z "$(kstate pp-p16b)" ] && ok || bad "P16b MIN=0: $(ppt_reqs)"
touch "$PPT_H/flags/lane-off-perf-probe-keepwarm"; kw
[ "$(ppt_count '.')" = 0 ] && ok || bad "P16b flag: $(ppt_reqs)"

# ══ P16c / P16i the row's keepwarm field ═════════════════════════════════════
setup p16c pp-p16c '.keepwarm=false'
kw
[ "$(ppt_count '.')" = 0 ] && ok || bad "P16c keepwarm:false: $(ppt_reqs)"
ppt_row pp-p16c "$(row pp-p16c '.keepwarm=true')"
kw
[ "$(gets)" = 10 ] && ok || bad "P16i keepwarm:true: $(gets) GETs"

# ══ P16e / P16f three failed rounds pause; a reset resumes ═══════════════════
setup p16e pp-p16e . 503
for m in 17 22 27; do kw PERF_PROBE_NOW=2026-11-18T06:$m:00Z; done
[ "$(gets)" = 30 ] && ok || bad "P16e 3 rounds want 30 GETs: $(gets)"
[ "$(grep -c 'keepwarm paused' "$PPT_H/logs/perf-probe-keepwarm.log" 2>/dev/null)" = 1 ] \
  && grep -qE "^[0-9TZ:-]+ perf-probe-keepwarm pp-p16e keepwarm paused fails=3$" "$PPT_H/logs/perf-probe-keepwarm.log" && ok || bad "P16e log: $(klog)"
[ "$(jq -c '[.fails,.paused]' "$PPT_H/state/perf-probe/pp-p16e/keepwarm.json")" = '[3,true]' ] && ok || bad "P16e state: $(kstate pp-p16e)"
kw PERF_PROBE_NOW=2026-11-18T06:32:00Z
[ "$(gets)" = 30 ] && [ "$(grep -c 'keepwarm paused' "$PPT_H/logs/perf-probe-keepwarm.log")" = 1 ] && ok || bad "P16e a paused project must make 0 requests: $(gets)"
# P16f: the reset (the daily lane and the warm-up call it) resumes the rounds
HARNESS="$PPT_H" bash -c '. "$1/bin/lib/perf-probe-io.sh" || exit 99; ppio_keepwarm_reset pp-p16e' _ "$PPT_H"
ppt_state "$(state 200)"
kw PERF_PROBE_NOW=2026-11-18T06:33:00Z
[ "$(gets)" = 40 ] && [ "$(kstate pp-p16e)" = '{"last_at":"2026-11-18T06:33:00Z","fails":0}' ] && ok || bad "P16f after a reset: $(gets) GETs, state $(kstate pp-p16e)"

# ══ P16g one 2xx is a passed round ═══════════════════════════════════════════
setup p16g pp-p16g
ppt_state "$(state 503 200)"
mkdir -p "$PPT_H/state/perf-probe/pp-p16g"; printf '{"fails":2}\n' > "$PPT_H/state/perf-probe/pp-p16g/keepwarm.json"
kw
[ "$(jq -r .fails "$PPT_H/state/perf-probe/pp-p16g/keepwarm.json")" = 0 ] && ok || bad "P16g one 2xx: $(kstate pp-p16g)"

# ══ P16h the session is refused ══════════════════════════════════════════════
setup p16h pp-p16h
ppt_state "{\"paths\":{\"$SESSION\":{\"status\":403},\"/r1\":{\"status\":200}}}"
kw
[ "$(gets)" = 0 ] && [ "$(jq -r .fails "$PPT_H/state/perf-probe/pp-p16h/keepwarm.json" 2>/dev/null)" = 1 ] && ok || bad "P16h: $(gets) GETs state $(kstate pp-p16h)"
[ -z "$(klog)" ] && ok || bad "P16h one failed round writes no line: $(klog)"

# ══ P16j the lock is held ════════════════════════════════════════════════════
setup p16j pp-p16j
lockf="$PPT_H/locks/perf-probe-pp-p16j.lock"
flock "$lockf" sleep 20 >/dev/null 2>&1 & holder=$!
i=0; while flock -n "$lockf" true 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i+1)); done
kw
pkill -P "$holder" 2>/dev/null; kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
[ "$(ppt_count '.')" = 0 ] && [ -z "$(kstate pp-p16j)" ] && ok || bad "P16j lock held: $(ppt_reqs) state $(kstate pp-p16j)"

# ══ P16k the route cap is a knob ═════════════════════════════════════════════
setup p16k pp-p16k
kw PERF_PROBE_KEEPWARM_ROUTES=3
[ "$(gets)" = 3 ] && [ "$(ppt_count '.path=="/r4"')" = 0 ] && ok || bad "P16k ROUTES=3: $(gets) GETs"

hits=$(grep -nE 'agent-call|claude |pp_ticket_step|results-put' "$REPO/bin/perf-probe-keepwarm.sh" 2>/dev/null)
[ -z "$hits" ] && ok || bad "Z2 the keep-warm lane writes results, files a ticket or calls an agent: $hits"

echo "perf-probe-keepwarm.bh-9792: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
