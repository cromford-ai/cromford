#!/bin/bash
# tests/perf-probe.bh-9786-test.sh — BH-9786 (slice C0 of #9791): the daily
# perf probe tracer. It runs the REAL bin/perf-probe.sh of a scratch harness
# against the fake app (tests/fixtures/perf-probe-fake-server.bh-9786.py) with
# a scratch D1 behind the jobs-client stub, the pinned clock
# PERF_PROBE_NOW=2026-11-18T06:17:00Z and the fixture token.
#
#   P3   tracer: 1 session POST, 2 GETs, 2 daily D1 rows, 1 complete line
#   P3b  a rerun on the same day still 2 rows, with the rerun's values
#   P7a  the session POST has auth and {"role":"<roles[0]>"}; GETs send the cookie
#   P7b  an unexpired expiresAt: the second run makes 0 POSTs
#   P7c  session 401 / P7d 404: 1 POST, 0 GETs, 1 skip line, no jar left
#   P7e  roles [] : 0 requests, 1 skip line
#   P7f  a 2xx with no cookie: skip, no jar left
#   P8a  every request except the session POST is a GET
#   P8b  the token is in no log, run dir, fake log or curl argv; jar is 0600
#   P21  enabled false: 1 skip line, 0 requests; lane-off flag: 0 requests, no line
#   P24  every repo catalog/perf-probe.d/*.json passes pp_row_valid
#   P25  every request the fake app saw came from 127.0.0.1
#   V1-V11 pp_row_valid decision table
#   B1-B8  pp_route_verdict decision table (the tracer budget)
#   L1   ppio_load prints <status> <ttfb_ms> <total_ms> <bytes> <location|->
#   L2   a 302 is not followed (0 requests to the Location)
#   L3   lock busy: 1 skip line, 0 requests
#   R1   lane level: a 302 route is not followed; a loopback row without the
#        flag is refused with 0 requests
#   E1   a 401 route load: ppio_on_ended (no-op rc 1) stops the project, incomplete
#   M1   a !incomplete marker from pp_routes makes the run incomplete
#   C3a-e the jobs-client verb: rc 0 / 1 / 4, op dispatch to a later fragment,
#        and the real bin/jobs-client.sh against the fake worker route
#   C4   the client fails: a results-put rc line, the run line says incomplete
#   S1   each seam's default answer; S2 a later seam file wins in name order;
#   S3   ppio_state_put/get round trip, keepwarm {"fails":0}
#   F1   a fake handler module's answer wins before the 404
#   K1   the lane reads PERF_PROBE_PAUSE_MS through lane_knob (registry default)
#   Z1   no agent call in the lane files
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/perf-probe.bh-9786-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/perf-probe.bh-9786.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }
trap 'ppt_server_stop' EXIT
SESSION=/api/internal/e2e/session
# The lane files this suite pins by path (and Z1 scans).
LANE_FILES=("$REPO/bin/perf-probe.sh" "$REPO/bin/lib/perf-probe.sh" "$REPO/bin/lib/perf-probe-io.sh"
  "$REPO/bin/lib/perf-probe/budget.sh" "$REPO/bin/lib/perf-probe/routes.sh" "$REPO/bin/lib/perf-probe/session-end.sh"
  "$REPO/bin/lib/perf-probe/statements.sh" "$REPO/bin/lib/perf-probe/ticket.sh")
JC_FRAG="$REPO/bin/jobs-client.d/bh-9786-perf-probe.sh"
for f in "${LANE_FILES[@]}" "$JC_FRAG"; do [ -f "$f" ] || bad "missing $f"; done

# row <project> <routes-json> [extra jq] — a valid enabled row on the fake app.
row() {
  jq -cn --arg p "$1" --arg b "$PPT_BASE" --argjson r "$2" \
    '{project:$p, enabled:true, base_url:$b, session_path:"/api/internal/e2e/session", signin_path:"/sign-in",
      roles:["admin"], routes:$r, budgets:{}}' | jq -c "${3:-.}"
}
sess_ok='{"status":200,"set_cookie":"pp_sid=fixture-session-cookie; Path=/; HttpOnly","json":{"ok":true}}'
loglines() { grep -c " perf-probe $1 " "$PPT_H/logs/perf-probe.log" 2>/dev/null; }

# ══ P3 / P3b / P7a / P8a / P25 the tracer ═══════════════════════════════════
ppt_tree p3 || exit 1; ppt_server_start p3 || exit 1
ppt_env_token pp-p3
ppt_state "{\"paths\":{\"$SESSION\":$sess_ok,\"/\":{\"status\":200,\"size\":100},\"/reports\":{\"status\":200,\"size\":200}}}"
ppt_row pp-p3 "$(row pp-p3 '["/","/reports"]')"
ppt_lane; rc=$?
[ "$rc" = 0 ] && ok || bad "P3 lane rc=$rc"
np=$(ppt_count ".method==\"POST\" and .path==\"$SESSION\""); ng=$(ppt_count '.method=="GET"')
[ "$np" = 1 ] && [ "$ng" = 2 ] && [ "$(ppt_count '.')" = 3 ] && ok || bad "P3 want 1 session POST + 2 GETs, got POST=$np GET=$ng: $(ppt_reqs)"
got=$(ppt_d1 "SELECT route,kind,run_key,day,status,bytes,(ttfb_ms IS NOT NULL),(total_ms IS NOT NULL),over_budget,outcome,loads,breaks FROM perf_probe_results WHERE project='pp-p3' ORDER BY route")
want=$'/|daily|daily|2026-11-18|200|100|1|1|0|pass|1|0\n/reports|daily|daily|2026-11-18|200|200|1|1|0|pass|1|0'
[ "$got" = "$want" ] && ok || bad "P3 D1 rows: got '$got'"
[ "$(loglines pp-p3)" = 1 ] && grep -qE "^[0-9TZ:-]+ perf-probe pp-p3 routes=2 over=0 stmts_new=0 ticket=none complete$" "$PPT_H/logs/perf-probe.log" \
  && ok || bad "P3 log: $(cat "$PPT_H/logs/perf-probe.log" 2>/dev/null)"
# P7a: the session POST carries the token header and the first role; the GETs the cookie
[ "$(ppt_count ".method==\"POST\" and .auth==true and .body==\"{\\\"role\\\":\\\"admin\\\"}\"")" = 1 ] \
  && ok || bad "P7a session POST: $(ppt_reqs "select(.method==\"POST\")")"
[ "$(ppt_count '.method=="GET" and .cookie==true and .auth==false')" = 2 ] && ok || bad "P7a GETs must send the jar cookie and no token: $(ppt_reqs)"
# P3b rerun on the same day: still 2 rows, the rerun's bytes
ppt_state "{\"paths\":{\"$SESSION\":$sess_ok,\"/\":{\"status\":200,\"size\":300},\"/reports\":{\"status\":200,\"size\":200}}}"
ppt_lane >/dev/null 2>&1
got=$(ppt_d1 "SELECT route,bytes FROM perf_probe_results WHERE project='pp-p3' ORDER BY route")
[ "$got" = $'/|300\n/reports|200' ] && ok || bad "P3b rerun: got '$got'"
[ "$(loglines pp-p3)" = 2 ] && ok || bad "P3b want a second line"
# A8: no expiresAt in the session answer, so the rerun mints a new session.
[ "$(ppt_count ".method==\"POST\" and .path==\"$SESSION\"")" = 2 ] && ok || bad "P3b a session with no expiresAt must not be reused: $(ppt_reqs 'select(.method=="POST")')"
[ "$(jq -r '.minted_at == .expires_at' "$PPT_H/state/perf-probe/pp-p3/session.json" 2>/dev/null)" = true ] && ok || bad "P3b session.json: $(cat "$PPT_H/state/perf-probe/pp-p3/session.json" 2>/dev/null)"
ALL_LOGS=("$PPT_LOG")
P3_H=$PPT_H

# ══ P7b an unexpired session is reused ══════════════════════════════════════
ppt_tree p7b || exit 1; ppt_server_start p7b || exit 1; ppt_env_token pp-p7b
ppt_state "{\"paths\":{\"$SESSION\":{\"status\":200,\"set_cookie\":\"pp_sid=x; Path=/\",\"json\":{\"expiresAt\":\"2026-11-18T09:00:00Z\"}},\"/\":{\"status\":200}}}"
ppt_row pp-p7b "$(row pp-p7b '["/"]')"
ppt_lane >/dev/null 2>&1; ppt_lane >/dev/null 2>&1
[ "$(ppt_count '.method=="POST"')" = 1 ] && [ "$(ppt_count '.method=="GET"')" = 2 ] && ok || bad "P7b want 1 POST over 2 runs: $(ppt_reqs)"
[ "$(jq -r .expires_at "$PPT_H/state/perf-probe/pp-p7b/session.json" 2>/dev/null)" = 2026-11-18T09:00:00Z ] && ok || bad "P7b session.json: $(cat "$PPT_H/state/perf-probe/pp-p7b/session.json" 2>/dev/null)"
# an expired one is minted again
ppt_lane >/dev/null 2>&1 PERF_PROBE_NOW=2026-11-18T10:00:00Z
[ "$(ppt_count '.method=="POST"')" = 2 ] && ok || bad "P7b an expired session must be minted again: $(ppt_reqs)"
ALL_LOGS+=("$PPT_LOG")

# ══ P7c / P7d / P7f the session is refused ══════════════════════════════════
for c in 401 404 nocookie; do
  ppt_tree "p7-$c" || exit 1; ppt_server_start "p7-$c" || exit 1; ppt_env_token "pp-p7-$c"
  if [ "$c" = nocookie ]; then s='{"status":200,"json":{"ok":true}}'; want="skip: session 200-no-cookie"
  else s="{\"status\":$c}"; want="skip: session $c"; fi
  ppt_state "{\"paths\":{\"$SESSION\":$s,\"/\":{\"status\":200}}}"
  ppt_row "pp-p7-$c" "$(row "pp-p7-$c" '["/"]')"
  ppt_lane >/dev/null 2>&1
  [ "$(ppt_count '.method=="POST"')" = 1 ] && [ "$(ppt_count '.method=="GET"')" = 0 ] && ok || bad "P7 $c: want 1 POST 0 GETs: $(ppt_reqs)"
  [ "$(loglines "pp-p7-$c")" = 1 ] && grep -q "perf-probe pp-p7-$c $want\$" "$PPT_H/logs/perf-probe.log" && ok || bad "P7 $c log: $(cat "$PPT_H/logs/perf-probe.log" 2>/dev/null)"
  [ ! -e "$PPT_H/state/perf-probe/pp-p7-$c/session.jar" ] && [ ! -e "$PPT_H/state/perf-probe/pp-p7-$c/session.json" ] && ok || bad "P7 $c: a refused session left a jar or session.json"
  [ -z "$(ppt_d1 "SELECT 1 FROM perf_probe_results")" ] && ok || bad "P7 $c: rows written"
  ALL_LOGS+=("$PPT_LOG")
done

# ══ P7e roles [] / no token ══════════════════════════════════════════════════
ppt_tree p7e || exit 1; ppt_server_start p7e || exit 1; ppt_env_token pp-p7e
ppt_state "{\"paths\":{\"$SESSION\":$sess_ok,\"/\":{\"status\":200}}}"
ppt_row pp-p7e "$(row pp-p7e '["/"]' '.roles=[]')"
ppt_row pp-p7e2 "$(row pp-p7e2 '["/"]')"   # no env file: no token
ppt_lane >/dev/null 2>&1
[ "$(ppt_count '.')" = 0 ] && ok || bad "P7e want 0 requests: $(ppt_reqs)"
grep -q "perf-probe pp-p7e skip: session no-roles$" "$PPT_H/logs/perf-probe.log" && ok || bad "P7e log: $(cat "$PPT_H/logs/perf-probe.log")"
grep -q "perf-probe pp-p7e2 skip: session no-token$" "$PPT_H/logs/perf-probe.log" && ok || bad "P7e no-token log: $(cat "$PPT_H/logs/perf-probe.log")"

# ══ P8b the token never leaves the session request ═══════════════════════════
ppt_tree p8 || exit 1; ppt_server_start p8 || exit 1; ppt_env_token pp-p8
ppt_state "{\"paths\":{\"$SESSION\":$sess_ok,\"/\":{\"status\":200}}}"
ppt_row pp-p8 "$(row pp-p8 '["/"]')"
WRAP="$T/p8/wrapbin"; mkdir -p "$WRAP"
real_curl=$(command -v curl)
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"\nexec "%s" "$@"\n' "$T/p8/curl-argv.log" "$real_curl" > "$WRAP/curl"; chmod +x "$WRAP/curl"
ppt_lane >/dev/null 2>&1 PATH="$WRAP:$PATH"
[ -s "$T/p8/curl-argv.log" ] && grep -q -- '-K -' "$T/p8/curl-argv.log" && ok || bad "P8b the curl wrapper saw no session call: $(cat "$T/p8/curl-argv.log" 2>/dev/null)"
leak=$(grep -rl -- "$PPT_TOKEN" "$PPT_H/logs" "$PPT_H/state/perf-probe/pp-p8/run" "$PPT_LOG" "$T/p8/curl-argv.log" 2>/dev/null)
[ -z "$leak" ] && ok || bad "P8b the token leaked into: $leak"
grep -q "session.jar" "$PPT_H/logs/perf-probe.log" && bad "P8b the jar path is in the log" || ok
[ "$(stat -c %a "$PPT_H/state/perf-probe/pp-p8/session.jar" 2>/dev/null)" = 600 ] && ok || bad "P8b jar mode $(stat -c %a "$PPT_H/state/perf-probe/pp-p8/session.jar" 2>&1)"
ALL_LOGS+=("$PPT_LOG")

# ══ P21 disabled row, lane flag ═════════════════════════════════════════════
ppt_tree p21 || exit 1; ppt_server_start p21 || exit 1; ppt_env_token pp-p21
ppt_state "{\"paths\":{\"$SESSION\":$sess_ok,\"/\":{\"status\":200}}}"
ppt_row pp-p21 "$(row pp-p21 '["/"]' '.enabled=false')"
ppt_lane >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(ppt_count '.')" = 0 ] && ok || bad "P21 disabled: rc=$rc reqs=$(ppt_reqs)"
[ "$(loglines pp-p21)" = 1 ] && grep -q "perf-probe pp-p21 skip: disabled$" "$PPT_H/logs/perf-probe.log" && ok || bad "P21 log: $(cat "$PPT_H/logs/perf-probe.log")"
[ ! -e "$PPT_H/locks/perf-probe-pp-p21.lock" ] && ok || bad "P21 a disabled row took the lock"
ppt_row pp-p21 "$(row pp-p21 '["/"]')"
touch "$PPT_H/flags/lane-off-perf-probe"
: > "$PPT_H/logs/perf-probe.log"
ppt_lane >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(ppt_count '.')" = 0 ] && ok || bad "P21 flag: rc=$rc reqs=$(ppt_reqs)"
[ "$(loglines pp-p21)" = 0 ] && ok || bad "P21 flag: the lane wrote a line: $(cat "$PPT_H/logs/perf-probe.log")"
rm -f "$PPT_H/flags/lane-off-perf-probe"
ppt_lane >/dev/null 2>&1
[ "$(ppt_count '.method=="GET"')" = 1 ] && ok || bad "P21 the flag removed: the lane must run again (the gate read the file): $(ppt_reqs)"

# ══ L3 lock busy ═════════════════════════════════════════════════════════════
ppt_tree l3 || exit 1; ppt_server_start l3 || exit 1; ppt_env_token pp-l3
ppt_state "{\"paths\":{\"$SESSION\":$sess_ok,\"/\":{\"status\":200}}}"
ppt_row pp-l3 "$(row pp-l3 '["/"]')"
lockf="$PPT_H/locks/perf-probe-pp-l3.lock"
flock "$lockf" sleep 20 >/dev/null 2>&1 & holder=$!
i=0; while flock -n "$lockf" true 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i+1)); done
ppt_lane >/dev/null 2>&1 PERF_PROBE_LOCK_WAIT_S=0
pkill -P "$holder" 2>/dev/null; kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
[ "$(ppt_count '.')" = 0 ] && ok || bad "L3 lock busy: want 0 requests: $(ppt_reqs)"
grep -q "perf-probe pp-l3 skip: lock busy$" "$PPT_H/logs/perf-probe.log" && ok || bad "L3 log: $(cat "$PPT_H/logs/perf-probe.log")"

# ══ R1 / E1 / M1 / C4 lane paths ════════════════════════════════════════════
ppt_tree r1 || exit 1; ppt_server_start r1 || exit 1
for p in pp-r1 pp-r1b pp-e1 pp-m1 pp-c4; do ppt_env_token "$p"; done
ppt_state "{\"paths\":{\"$SESSION\":$sess_ok,\"/\":{\"status\":200},\"/moved\":{\"status\":302,\"location\":\"$PPT_BASE/elsewhere\"},\"/gone\":{\"status\":401}}}"
ppt_row pp-r1 "$(row pp-r1 '["/moved"]')"
ppt_lane >/dev/null 2>&1
[ "$(ppt_count '.path=="/elsewhere"')" = 0 ] && [ "$(ppt_count '.path=="/moved"')" = 1 ] && ok || bad "R1 a 302 route was followed: $(ppt_reqs)"
[ "$(ppt_d1 "SELECT status,outcome FROM perf_probe_results WHERE project='pp-r1'")" = "302|pass" ] && ok || bad "R1 row: $(ppt_d1 "SELECT * FROM perf_probe_results WHERE project='pp-r1'")"
rm -f "$PPT_H/catalog/perf-probe.d/pp-r1.json"; : > "$PPT_LOG"
ppt_row pp-r1b "$(row pp-r1b '["/"]')"
ppt_lane >/dev/null 2>&1 PERF_PROBE_ALLOW_LOOPBACK=0
[ "$(ppt_count '.')" = 0 ] && ok || bad "R1 a loopback row without the flag sent requests: $(ppt_reqs)"
grep -q "perf-probe pp-r1b skip: invalid row base_url" "$PPT_H/logs/perf-probe.log" && ok || bad "R1 log: $(cat "$PPT_H/logs/perf-probe.log")"
rm -f "$PPT_H/catalog/perf-probe.d/pp-r1b.json"
# E1: a 401 on a route load stops the project (the no-op seam answers rc 1)
ppt_row pp-e1 "$(row pp-e1 '["/","/gone","/"]')"
: > "$PPT_LOG"; ppt_lane >/dev/null 2>&1
[ "$(ppt_count '.path=="/gone"')" = 1 ] && [ "$(ppt_count '.method=="GET"')" = 2 ] && ok || bad "E1 the project must stop at the 401 (no retry, no later route): $(ppt_reqs)"
grep -q "perf-probe pp-e1 stop: session ended$" "$PPT_H/logs/perf-probe.log" \
  && grep -qE "perf-probe pp-e1 routes=1 over=0 stmts_new=0 ticket=none incomplete$" "$PPT_H/logs/perf-probe.log" \
  && ok || bad "E1 log: $(cat "$PPT_H/logs/perf-probe.log")"
rm -f "$PPT_H/catalog/perf-probe.d/pp-e1.json"
# M1: a !incomplete marker from the route seam
ppt_row pp-m1 "$(row pp-m1 '["/"]')"
printf '# owner: test\npp_routes_expand() { jq -r ".routes[]" "$2"; echo "!incomplete cap"; }\n' > "$PPT_H/bin/lib/perf-probe/zz-m1.sh"
: > "$PPT_LOG"; ppt_lane >/dev/null 2>&1
rm -f "$PPT_H/bin/lib/perf-probe/zz-m1.sh"
[ "$(ppt_count '.path=="!incomplete cap"')" = 0 ] && [ "$(ppt_count '.method=="GET"')" = 1 ] && ok || bad "M1 the marker was loaded as a route: $(ppt_reqs)"
grep -qE "perf-probe pp-m1 routes=1 over=0 stmts_new=0 ticket=none incomplete$" "$PPT_H/logs/perf-probe.log" && ok || bad "M1 log: $(cat "$PPT_H/logs/perf-probe.log")"
rm -f "$PPT_H/catalog/perf-probe.d/pp-m1.json"
# C4: the client fails
ppt_row pp-c4 "$(row pp-c4 '["/"]')"
ppt_lane >/dev/null 2>&1 PPT_JOBS_RC=1; rc=$?
[ "$rc" = 0 ] && grep -q "perf-probe pp-c4 results-put rc=1$" "$PPT_H/logs/perf-probe.log" \
  && grep -qE "perf-probe pp-c4 routes=1 over=0 stmts_new=0 ticket=none incomplete$" "$PPT_H/logs/perf-probe.log" \
  && ok || bad "C4 rc=$rc log: $(cat "$PPT_H/logs/perf-probe.log")"
ALL_LOGS+=("$PPT_LOG")

# ══ K1 the pause comes from lane_knob ════════════════════════════════════════
ppt_tree k1 || exit 1; ppt_server_start k1 || exit 1; ppt_env_token pp-k1
ppt_state "{\"paths\":{\"$SESSION\":$sess_ok,\"/a\":{\"status\":200},\"/b\":{\"status\":200}}}"
ppt_row pp-k1 "$(row pp-k1 '["/a","/b"]')"
# A registry default (700) that is not the code fallback (500): only a lane_knob read gives it.
jq '(.lanes[0].knobs[] | select(.env=="PERF_PROBE_PAUSE_MS") | .default) = 700' "$PPT_H/lanes.json" > "$PPT_H/lanes.k1" && mv "$PPT_H/lanes.k1" "$PPT_H/lanes.json"
PPT_PAUSE_MS=unset ppt_lane >/dev/null 2>&1
gap=$(jq -s '[.[] | select(.method=="GET")] | (.[1].t_ms - .[0].t_ms)' "$PPT_LOG" 2>/dev/null)
[ -n "$gap" ] && [ "$gap" -ge 700 ] 2>/dev/null && ok || bad "K1 gap between GETs ${gap}ms, want >= 700 (registry default via lane_knob)"

# ══ P8a / P25 over every fake log ═══════════════════════════════════════════
nreq=0; nbad=0; nhost=0
for lf in "${ALL_LOGS[@]}"; do
  nreq=$((nreq + $(grep -c . "$lf")))
  nbad=$((nbad + $(jq -c "select(.method!=\"GET\" and (.method!=\"POST\" or .path!=\"$SESSION\"))" "$lf" | grep -c .)))
  nhost=$((nhost + $(jq -c 'select(.host!="127.0.0.1")' "$lf" | grep -c .)))
done
[ "$nreq" -gt 10 ] && [ "$nbad" = 0 ] && ok || bad "P8a $nbad of $nreq requests are not a GET or the session POST"
[ "$nreq" -gt 10 ] && [ "$nhost" = 0 ] && ok || bad "P25 $nhost of $nreq requests not from 127.0.0.1"

# ══ library cases: source the scratch tree's libs ════════════════════════════
LIBH=$P3_H
lib() { HARNESS="$LIBH" bash -c '. "$HARNESS/bin/lib/perf-probe.sh" || exit 99; . "$HARNESS/bin/lib/perf-probe-io.sh" || exit 98; '"$1" _ "${@:2}"; }

# ── V1-V11 pp_row_valid ──────────────────────────────────────────────────────
VD="$T/v"; mkdir -p "$VD"
vrow() { printf '%s\n' "$2" > "$VD/$1.json"; }
base='{"project":"P","enabled":true,"base_url":"https://os.example.com","session_path":"/api/internal/e2e/session","signin_path":"/sign-in","roles":["admin"],"routes":["/"],"budgets":{}}'
vcase() { # <id> <want ok|refused> <jq edit> [env]
  local id="$1" want="$2" ed="$3" p="v-${1,,}" out rc
  vrow "$p" "$(jq -c --arg p "$p" ".project=\$p | $ed" <<<"$base")"
  out=$(env ${4:-} HARNESS="$LIBH" bash -c '. "$HARNESS/bin/lib/perf-probe.sh" || exit 99; pp_row_valid "$1"' _ "$VD/$p.json"); rc=$?
  case "$want" in
    ok) [ "$rc" = 0 ] && ok || bad "$id want valid, rc=$rc: $out" ;;
    *)  [ "$rc" = 1 ] && [ -n "$out" ] && ok || bad "$id want refused with a reason, rc=$rc out='$out'" ;;
  esac
}
vcase V1 ok '.'
vcase V2 refused '.base_url="http://127.0.0.1:8080"'
vcase V3 ok '.base_url="http://127.0.0.1:8080"' PERF_PROBE_ALLOW_LOOPBACK=1
vcase V4 refused '.base_url="http://example.com"' PERF_PROBE_ALLOW_LOOPBACK=1
vcase V5 refused '.base_url="xhttps://a.example.com"'
vcase V6 refused '.project="someone-else"'
vcase V7 refused '.routes=["/","clients"]'
vcase V8 refused '.roles="admin"'
vcase V9 refused '.roles=[1]'
vcase V10 ok '.roles=[]'
vcase V11 refused '.routes="/"'
vcase V12 refused '.session_path="api/x"'
vcase V13 refused '.base_url="http://127.0.0.1.evil.com"' PERF_PROBE_ALLOW_LOOPBACK=1
vcase V14 refused '.base_url="https://a.example.com/path"'

# ── P24 every repo row is valid ─────────────────────────────────────────────
n=0
for f in "$REPO"/catalog/perf-probe.d/*.json; do
  [ -f "$f" ] || continue; n=$((n+1))
  out=$(HARNESS="$LIBH" bash -c '. "$HARNESS/bin/lib/perf-probe.sh" || exit 99; pp_row_valid "$1"' _ "$f") && ok || bad "P24 $(basename "$f"): $out"
done
[ "$n" -ge 1 ] && ok || bad "P24 no repo row"
jq -e '.project=="project-2" and .enabled==false and .roles==[] and .routes==["/"]' "$REPO/catalog/perf-probe.d/project-2.json" >/dev/null \
  && ok || bad "P24 project-2 row is not the shipped default"

# ── B1-B8 pp_route_verdict ───────────────────────────────────────────────────
bcase() { # <id> <load line> <want>
  printf '%s\n' "$2" > "$T/b.loads"
  local got; got=$(lib 'pp_route_verdict /dev/null / "$1"' "$T/b.loads")
  [ "${got%% *}" = "$3" ] && ok || bad "$1 '$2': want $3, got '$got'"
}
bcase B1 '200 999 999 100 -' under
bcase B2 '200 1000 1000 100 -' under
bcase B3 '200 1001 1001 100 -' over
bcase B3b '200 10 1001 100 -' over
bcase B4 '500 10 10 10 -' over
bcase B5 '000 0 0 0 -' over
bcase B6 '404 10 10 10 -' under
bcase B7 '200 10 10 512000 -' under
bcase B8 '200 10 10 512001 -' over
: > "$T/b.loads"; got=$(lib 'pp_route_verdict /dev/null / "$1"' "$T/b.loads")
[ "$got" = unmeasured ] && ok || bad "B9 no load line: want unmeasured, got '$got'"
printf '200 10 10 10 -\n' > "$T/b.loads"
got=$(PERF_PROBE_BUDGET_MS=5 lib 'pp_route_verdict /dev/null / "$1"' "$T/b.loads")
[ "$got" = over ] && ok || bad "B10 the budget knob: PERF_PROBE_BUDGET_MS=5 must make 10 ms over, got '$got'"

# ── L1 / L2 ppio_load ────────────────────────────────────────────────────────
ppt_server_start lib || exit 1
ppt_state "{\"paths\":{\"/l1\":{\"status\":200,\"size\":1234},\"/l2\":{\"status\":302,\"location\":\"$PPT_BASE/l2-target\"}}}"
line=$(PERF_PROBE_PAUSE_MS=0 lib 'ppio_load "$1" /dev/null' "$PPT_BASE/l1")
[[ $line =~ ^200\ [0-9]+\ [0-9]+\ 1234\ -$ ]] && ok || bad "L1 load line '$line'"
line=$(PERF_PROBE_PAUSE_MS=0 lib 'ppio_load "$1" /dev/null' "$PPT_BASE/l2")
[[ $line =~ ^302\ [0-9]+\ [0-9]+\ [0-9]+\ http://127\.0\.0\.1:[0-9]+/l2-target$ ]] && ok || bad "L2 load line '$line'"
[ "$(ppt_count '.path=="/l2-target"')" = 0 ] && ok || bad "L2 the redirect was followed"
line=$(PERF_PROBE_PAUSE_MS=0 lib 'ppio_load "$1" /dev/null' "http://127.0.0.1:1/none")
[[ $line =~ ^000\ [0-9]+\ [0-9]+\ 0\ -$ ]] && ok || bad "L1b no answer: '$line'"

# ── F1 a handler module answers before the 404 ───────────────────────────────
HD="$T/f1-handlers"; mkdir -p "$HD"
cp "$REPO"/tests/fixtures/perf-probe-fake.d/*.py "$HD/"
printf 'def handle(req, state):\n    if req["path"] == "/f1":\n        return {"status": 299, "body": "from f1"}\n    return None\n' > "$HD/zz_f1.py"
PPT_HANDLERS="$HD" ppt_server_start f1 || exit 1
c1=$(curl -s -o /dev/null -w '%{http_code}' "$PPT_BASE/f1"); c2=$(curl -s -o /dev/null -w '%{http_code}' "$PPT_BASE/other")
[ "$c1" = 299 ] && [ "$c2" = 404 ] && ok || bad "F1 handler answer: /f1=$c1 /other=$c2"
for m in board statements health; do
  head -1 "$REPO/tests/fixtures/perf-probe-fake.d/$m.py" | grep -qE '^# owner: BH-9786\.[0-9]$' && ok || bad "F1 $m.py has no owner line"
done

# ── S1 seam defaults / S2 name order / S3 state ──────────────────────────────
printf '{"routes":["/a","/b"]}\n' > "$T/s1.json"
got=$(lib 'printf "%s|" "$(pp_loads_per_route)" "$(pp_routes p "$1" | paste -sd,)" "$(pp_statements_run p "$1" /tmp 2026-11-18)" "$(pp_findings_extra p)" "$(pp_ticket_step p "$1" 2026-11-18 /tmp)"; pp_budgets_valid "$1"; printf "%s|" "$?"; ppio_on_ended p "$1"; printf "%s" "$?"' "$T/s1.json")
[ "$got" = "1|/a,/b|stmts_new=0||ticket=none|0|1" ] && ok || bad "S1 seam defaults: '$got'"
for f in budget routes session-end statements ticket; do
  head -1 "$REPO/bin/lib/perf-probe/$f.sh" | grep -qE '^# owner: BH-9786\.[1-5]$' && ok || bad "S1 $f.sh first line is not an owner line"
done
printf '# owner: test\npp_loads_per_route() { echo 3; }\n' > "$LIBH/bin/lib/perf-probe/zz-s2.sh"
got=$(lib 'pp_loads_per_route')
rm -f "$LIBH/bin/lib/perf-probe/zz-s2.sh"
[ "$got" = 3 ] && ok || bad "S2 a later seam file must win in name order, got '$got'"
printf 'return 1\n' > "$LIBH/bin/lib/perf-probe/zz-s2b.sh"
lib 'true'; rc=$?
rm -f "$LIBH/bin/lib/perf-probe/zz-s2b.sh"
[ "$rc" = 99 ] && ok || bad "S2b a seam that fails to load must fail the lib source, rc=$rc"
got=$(lib 'printf "{\"a\":1}\n" | ppio_state_put pp-s3 thing && ppio_state_get pp-s3 thing && ppio_keepwarm_reset pp-s3 && ppio_state_get pp-s3 keepwarm')
[ "$(jq -c . <<<"$got" | paste -sd' ')" = '{"a":1} {"fails":0}' ] && ok || bad "S3 state round trip: '$got'"
[ -f "$LIBH/state/perf-probe/pp-s3/thing.json" ] && ok || bad "S3 state file path"

# ── C3 the jobs-client verb ──────────────────────────────────────────────────
c3() { # <unused> <unused> [JOBS_URL]; FAKE_HTTP and FAKE_RC set the fake _jobs_req -> rc of jc_verb_perf_probe results-put
  JOBS_URL="${3-http://jobs.test}" HARNESS_SECRET=fixture-secret bash -c '
    _jobs_req() { JOBS_HTTP=$FAKE_HTTP; printf "%s %s %s\n" "$1" "$2" "$3" > "$CALLS"; return "$FAKE_RC"; }
    . "$1" || exit 99; jc_verb_perf_probe results-put "{\"project\":\"x\"}" >/dev/null' _ "$JC_FRAG"
}
export CALLS="$T/c3.calls"
FAKE_HTTP=200 FAKE_RC=0 c3; rc=$?; [ "$rc" = 0 ] && grep -q '^POST /api/perf-probe/results {"project":"x"}$' "$CALLS" && ok || bad "C3a 2xx rc=$rc calls=$(cat "$CALLS" 2>/dev/null)"
FAKE_HTTP= FAKE_RC=1 c3; rc=$?; [ "$rc" = 1 ] && ok || bad "C3b transport rc=$rc"
FAKE_HTTP=503 FAKE_RC=1 c3; rc=$?; [ "$rc" = 1 ] && ok || bad "C3b 5xx rc=$rc"
FAKE_HTTP=400 FAKE_RC=1 c3; rc=$?; [ "$rc" = 4 ] && ok || bad "C3c 4xx rc=$rc"
rm -f "$CALLS"; FAKE_HTTP=200 FAKE_RC=0 c3 - - ""; rc=$?; [ "$rc" = 4 ] && [ ! -e "$CALLS" ] && ok || bad "C3c not configured rc=$rc (want 4, no request)"
got=$(bash -c '. "$1" || exit 99; jc_verb_perf_probe_zz_op() { printf "zz:%s\n" "$*"; }; jc_verb_perf_probe zz-op a b' _ "$JC_FRAG"); rc=$?
[ "$rc" = 0 ] && [ "$got" = "zz:a b" ] && ok || bad "C3d an op from a later fragment: rc=$rc got='$got'"
bash -c '. "$1" || exit 99; jc_verb_perf_probe no-such-op x' _ "$JC_FRAG" >/dev/null 2>&1; rc=$?
[ "$rc" = 4 ] && ok || bad "C3d an unknown op: rc=$rc, want 4"
# C3e the real client against the fake worker route (the production entry point)
ppt_server_start c3e || exit 1
ppt_state '{"paths":{"/api/perf-probe/results":{"status":200,"json":{"written":1}}}}'
mkdir -p "$T/c3e/h/env"
out=$(HARNESS="$T/c3e/h" JOBS_URL="$PPT_BASE" HARNESS_SECRET=fixture-secret JOBS_RETRIES=0 bash "$REPO/bin/jobs-client.sh" perf-probe results-put '{"project":"pp-c3e"}'); rc=$?
[ "$rc" = 0 ] && [ "$out" = '{"written": 1}' ] && [ "$(ppt_count '.method=="POST" and .path=="/api/perf-probe/results" and .auth==true and .body=="{\"project\":\"pp-c3e\"}"')" = 1 ] \
  && ok || bad "C3e real client 200: rc=$rc out='$out' reqs=$(ppt_reqs)"
ppt_state '{"paths":{"/api/perf-probe/results":{"status":400,"json":{"error":"rows"}}}}'
HARNESS="$T/c3e/h" JOBS_URL="$PPT_BASE" HARNESS_SECRET=fixture-secret JOBS_RETRIES=0 bash "$REPO/bin/jobs-client.sh" perf-probe results-put '{"project":"pp-c3e"}' >/dev/null 2>&1; rc=$?
[ "$rc" = 4 ] && ok || bad "C3e real client 400: rc=$rc, want 4"

# ── Z1 deterministic: no agent call ──────────────────────────────────────────
hits=$(grep -nE 'agent-call|claude ' "${LANE_FILES[@]}" 2>/dev/null)
[ -z "$hits" ] && ok || bad "Z1 agent call in the lane: $hits"

echo "perf-probe.bh-9786: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
