#!/bin/bash
# tests/perf-probe-warm.bh-9792-test.sh — BH-9792: the post-deploy warm-up lane
# bin/perf-probe-warm.sh. It runs the REAL lane of a scratch harness against
# the fake app (tests/fixtures/perf-probe-fake-server.bh-9786.py), a gh stub on
# PATH (the GitHub deployments and statuses reads, 0 network), and a jobs stub
# that runs the routes' own SQL on a scratch D1. Clock pinned by PERF_PROBE_NOW.
#
#   C1   the client verbs warm-get / warm-put: path, body, rc 0/1/4, and the
#        real bin/jobs-client.sh against the fake worker route
#   L1   the lane registry entry perf-probe-warm and its 4 knob defaults
#   P12a new deployment + success: one warm-up, 1 warmed row
#   P12b the same id after POLL_MIN: 0 app requests, no new row, 1 gh call (P22a)
#   P12c failure / P12e error, inactive: 0 app requests, 1 deploy-failed row
#   P12d in_progress / P12f pending, queued, []: 0 app requests, 0 rows
#   P12g deployments []: 1 gh call, 0 app requests
#   P12h gh 403 rate limit: 0 rows, one `deployments unreadable` line, stamped
#   P12i warm-get rc 1: no warm-up, one `warm-get rc=1` line
#   P12j a deployment id with a space: 0 app requests, 0 rows
#   P13a pass-2 rows: kind post-deploy, run_key = the id; keepwarm reset
#   P13b-g the pass-2 outcome table (500/200, 500/500, timeout/200, 404, 302,
#        over budget) and a results-put failure
#   P14  health 503 the whole wait: no session, no route, no row, 1 line;
#        health 200 on the 2nd poll: the warm-up runs
#   P15a one session POST per warm-up; P15b lock held: 0 gh calls, not stamped
#   P22b a tick inside POLL_MIN: 0 gh calls, 0 jobs calls
#   P8w  every app request is a GET except the session POST; only the row's
#        routes, the health path and the session path are requested
#   P0   PERF_PROBE_WARM_ENABLED=0 and the lane-off flag: 0 gh calls
#   O1   the observable outcome of the ticket, end to end
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/perf-probe-warm.bh-9792-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/perf-probe-warm.bh-9792.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }
trap 'ppt_server_stop' EXIT
SESSION=/api/internal/e2e/session
sess_ok='{"status":200,"set_cookie":"pp_sid=fixture-session-cookie; Path=/; HttpOnly","json":{"ok":true}}'
DEP='[{"id":4242,"environment":"Production"}]'
LATER=2026-11-18T06:22:00Z   # PPT_NOW + POLL_MIN (5 min)
for f in bin/perf-probe-warm.sh catalog/lanes.d/perf-probe-warm.json cron/lanes/785-perf-probe-warm.cron \
         bin/jobs-client.d/bh-9792-perf-probe-warm-get.sh bin/jobs-client.d/bh-9792-perf-probe-warm-put.sh worker/jobs/src/routes/perf-probe-warm.js; do
  [ -f "$REPO/$f" ] || bad "missing $f"
done

# row <project> <routes-json> [extra jq] — a valid enabled row with a repo.
row() {
  jq -cn --arg p "$1" --arg b "$PPT_BASE" --argjson r "$2" \
    '{project:$p, enabled:true, base_url:$b, session_path:"/api/internal/e2e/session", signin_path:"/sign-in",
      roles:["admin"], routes:$r, budgets:{}, repo:"acme/app"}' | jq -c "${3:-.}"
}
wlog() { cat "$PPT_H/logs/perf-probe-warm.log" 2>/dev/null; }
wlines() { grep -c " perf-probe-warm $1 " "$PPT_H/logs/perf-probe-warm.log" 2>/dev/null; }
appreqs() { ppt_count '.'; }
# setup <case> <project> <state-json> <routes-json> [extra jq]
setup() {
  pwt_tree "$1" || exit 1; pwt_server "$1" || exit 1; ppt_env_token "$2"
  ppt_state "$3"
  ppt_row "$2" "$(row "$2" "$4" "${5:-.}")"
}
st3="{\"paths\":{\"$SESSION\":$sess_ok,\"/a\":{\"status\":200},\"/b\":{\"status\":200},\"/c\":{\"status\":200}}}"

# ══ L1 the lane registry ═════════════════════════════════════════════════════
L=$REPO/catalog/lanes.d/perf-probe-warm.json
got=$(jq -c '[.id,.scope,.cadence,.boxes,.switch.name,.wired,.script,.stats.log]' "$L" 2>/dev/null)
[ "$got" = '["perf-probe-warm","hub","* * * * *",["hub"],"lane-off-perf-probe-warm",true,"bin/perf-probe-warm.sh","logs/perf-probe-warm.log"]' ] \
  && ok || bad "L1 lane entry: $got"
got=$(jq -c '[.knobs[] | select(.type=="int") | [.env,.default]]' "$L" 2>/dev/null)
[ "$got" = '[["PERF_PROBE_WARM_ENABLED",1],["PERF_PROBE_WARM_POLL_MIN",5],["PERF_PROBE_HEALTH_WAIT_S",180],["PERF_PROBE_HEALTH_POLL_S",10]]' ] \
  && ok || bad "L1 knobs: $got"
grep -qE '^\* \* \* \* \* /root/harness/bin/hub-lease.sh check && /root/harness/bin/perf-probe-warm.sh >> /root/harness/logs/perf-probe-warm.log 2>&1$' \
  "$REPO/cron/lanes/785-perf-probe-warm.cron" && grep -q '^# @hub-lanes' "$REPO/cron/lanes/785-perf-probe-warm.cron" \
  && ok || bad "L1 cron fragment"

# ══ O1 / P12a / P13a / P15a / P8w / P12b / P22a: a new deployment is warmed ═══
setup o1 pp-o1 "$st3" '["/a","/b","/c"]'
pwt_gh deployments 200 "$DEP"; pwt_gh statuses 200 '[{"state":"success"}]'
printf '{"fails":2,"paused":true}\n' | { mkdir -p "$PPT_H/state/perf-probe/pp-o1"; cat > "$PPT_H/state/perf-probe/pp-o1/keepwarm.json"; }
pwt_lane perf-probe-warm.sh; rc=$?
[ "$rc" = 0 ] && ok || bad "O1 lane rc=$rc"
for r in /a /b /c; do
  [ "$(ppt_count ".method==\"GET\" and .path==\"$r\"")" = 2 ] && ok || bad "O1 route $r want 2 loads: $(ppt_reqs "select(.path==\"$r\")")"
done
[ "$(ppt_count ".method==\"POST\" and .path==\"$SESSION\"")" = 1 ] && ok || bad "P15a want 1 session POST: $(ppt_reqs 'select(.method=="POST")')"
[ "$(ppt_count '.path=="/api/health" and .method=="GET"')" = 1 ] && ok || bad "O1 want 1 health GET: $(ppt_reqs 'select(.path=="/api/health")')"
# P8w: GET everywhere but the session; only the row's paths
[ "$(ppt_count ".method!=\"GET\" and .path!=\"$SESSION\"")" = 0 ] && ok || bad "P8w a non-GET app request: $(ppt_reqs)"
[ "$(ppt_count ".path!=\"/a\" and .path!=\"/b\" and .path!=\"/c\" and .path!=\"/api/health\" and .path!=\"$SESSION\"")" = 0 ] \
  && ok || bad "P8w a request outside the row's paths: $(ppt_reqs)"
[ "$(ppt_count '.cookie==true and .path=="/api/health"')" = 0 ] && ok || bad "P8w the health read sent the session cookie"
[ "$(pwt_gh_calls | paste -sd' ')" = "repos/acme/app/deployments?environment=Production&per_page=1 repos/acme/app/deployments/4242/statuses?per_page=1" ] \
  && ok || bad "P12a gh calls: $(pwt_gh_calls | paste -sd' ')"
[ "$(pwt_warm_rows pp-o1)" = "4242|warmed|3|0" ] && ok || bad "P12a warm row: '$(pwt_warm_rows pp-o1)'"
got=$(ppt_d1 "SELECT route,kind,run_key,day,status,outcome,loads,breaks,over_budget FROM perf_probe_results WHERE project='pp-o1' ORDER BY route")
want=$'/a|post-deploy|4242|2026-11-18|200|pass|1|0|0\n/b|post-deploy|4242|2026-11-18|200|pass|1|0|0\n/c|post-deploy|4242|2026-11-18|200|pass|1|0|0'
[ "$got" = "$want" ] && ok || bad "P13a result rows: '$got'"
[ "$(ppt_d1 "SELECT count(*) FROM perf_probe_results WHERE kind='daily'")" = 0 ] && ok || bad "P13a a daily row was written"
[ "$(jq -c . "$PPT_H/state/perf-probe/pp-o1/keepwarm.json" 2>/dev/null)" = '{"fails":0}' ] && ok || bad "P13a keepwarm not reset: $(cat "$PPT_H/state/perf-probe/pp-o1/keepwarm.json")"
[ "$(wlines pp-o1)" = 1 ] && grep -qE "^[0-9TZ:-]+ perf-probe-warm pp-o1 deployment=4242 routes=3 over=0 recovered=0 results=ok warm=ok$" "$PPT_H/logs/perf-probe-warm.log" \
  && ok || bad "O1 log: $(wlog)"
[ -n "$(jq -r '.last_poll_at // empty' "$PPT_H/state/perf-probe/pp-o1/warm.json" 2>/dev/null)" ] && ok || bad "O1 warm.json not stamped"
# P22b: a tick inside POLL_MIN makes 0 gh calls and 0 jobs calls
: > "$PWT_GH/calls"; : > "$PWT_JC.calls"; : > "$PPT_LOG"
pwt_lane perf-probe-warm.sh PERF_PROBE_NOW=2026-11-18T06:19:00Z
[ -z "$(pwt_gh_calls)" ] && [ ! -s "$PWT_JC.calls" ] && [ "$(appreqs)" = 0 ] && ok || bad "P22b a tick inside POLL_MIN: gh=$(pwt_gh_calls) jobs=$(cat "$PWT_JC.calls")"
# P12b / P22a: after POLL_MIN the same id: 1 gh call, 0 app requests, no new row
pwt_lane perf-probe-warm.sh PERF_PROBE_NOW=$LATER
[ "$(pwt_gh_calls | grep -c .)" = 1 ] && ok || bad "P22a want exactly 1 gh call: $(pwt_gh_calls)"
[ "$(appreqs)" = 0 ] && ok || bad "P12b the same deployment was warmed again: $(ppt_reqs)"
[ "$(pwt_warm_rows pp-o1)" = "4242|warmed|3|0" ] && ok || bad "P12b rows: $(pwt_warm_rows pp-o1)"
[ "$(wlines pp-o1)" = 1 ] && ok || bad "P12b a line for a known deployment: $(wlog)"

# ══ P12c / P12e terminal failure states ══════════════════════════════════════
for s in failure error inactive; do
  setup "p12-$s" "pp-$s" "$st3" '["/a"]'
  pwt_gh deployments 200 "$DEP"; pwt_gh statuses 200 "[{\"state\":\"$s\"}]"
  pwt_lane perf-probe-warm.sh
  [ "$(appreqs)" = 0 ] && ok || bad "P12 $s: app requests $(ppt_reqs)"
  [ "$(pwt_warm_rows "pp-$s")" = "4242|deploy-failed|0|0" ] && ok || bad "P12 $s rows: '$(pwt_warm_rows "pp-$s")'"
  grep -q "perf-probe-warm pp-$s deploy-failed 4242 $s$" "$PPT_H/logs/perf-probe-warm.log" && ok || bad "P12 $s log: $(wlog)"
  # no results-put ran, so the scratch D1 has no results table (empty) or 0 rows
  case "$(ppt_d1 "SELECT count(*) FROM perf_probe_results")" in ''|0) ok ;; *) bad "P12 $s result rows" ;; esac
  grep -q "results-put" "$PWT_JC.calls" 2>/dev/null && bad "P12 $s called results-put" || ok
done

# ══ P12d / P12f not terminal yet: nothing ════════════════════════════════════
for s in in_progress pending queued none; do
  setup "p12-$s" "pp-n-${s//_/-}" "$st3" '["/a"]'
  pwt_gh deployments 200 "$DEP"
  if [ "$s" = none ]; then pwt_gh statuses 200 '[]'; else pwt_gh statuses 200 "[{\"state\":\"$s\"}]"; fi
  pwt_lane perf-probe-warm.sh
  [ "$(appreqs)" = 0 ] && [ -z "$(pwt_warm_rows "pp-n-${s//_/-}")" ] && ok || bad "P12 $s: want 0 requests 0 rows: $(ppt_reqs) / $(pwt_warm_rows "pp-n-${s//_/-}")"
  [ "$(pwt_gh_calls | grep -c .)" = 2 ] && ok || bad "P12 $s gh calls: $(pwt_gh_calls)"
  [ -z "$(wlog)" ] && ok || bad "P12 $s wrote a line: $(wlog)"
done

# ══ P12g no deployment ═══════════════════════════════════════════════════════
setup p12g pp-p12g "$st3" '["/a"]'
pwt_gh deployments 200 '[]'
pwt_lane perf-probe-warm.sh
[ "$(pwt_gh_calls | grep -c .)" = 1 ] && [ "$(appreqs)" = 0 ] && [ ! -s "$PWT_JC.calls" ] && ok || bad "P12g gh=$(pwt_gh_calls) app=$(ppt_reqs) jobs=$(cat "$PWT_JC.calls" 2>/dev/null)"

# ══ P12h a GitHub rate limit ═════════════════════════════════════════════════
setup p12h pp-p12h "$st3" '["/a"]'
pwt_gh deployments 403 '{"message":"API rate limit exceeded"}'
pwt_lane perf-probe-warm.sh
[ "$(appreqs)" = 0 ] && [ -z "$(pwt_warm_rows pp-p12h)" ] && [ ! -s "$PWT_JC.calls" ] && ok || bad "P12h: app=$(ppt_reqs) jobs=$(cat "$PWT_JC.calls" 2>/dev/null)"
[ "$(wlines pp-p12h)" = 1 ] && grep -q "perf-probe-warm pp-p12h deployments unreadable (403 rate-limit)$" "$PPT_H/logs/perf-probe-warm.log" && ok || bad "P12h log: $(wlog)"
[ "$(jq -r '.last_poll_at' "$PPT_H/state/perf-probe/pp-p12h/warm.json" 2>/dev/null)" = 2026-11-18T06:17:00Z ] && ok || bad "P12h warm.json: $(cat "$PPT_H/state/perf-probe/pp-p12h/warm.json" 2>/dev/null)"
# the next minute does not read GitHub again
pwt_lane perf-probe-warm.sh PERF_PROBE_NOW=2026-11-18T06:18:00Z
[ "$(pwt_gh_calls | grep -c .)" = 1 ] && ok || bad "P12h a failing read must wait POLL_MIN: $(pwt_gh_calls)"

# ══ P12i the watermark read fails ════════════════════════════════════════════
setup p12i pp-p12i "$st3" '["/a"]'
pwt_gh deployments 200 "$DEP"; pwt_gh statuses 200 '[{"state":"success"}]'
pwt_lane perf-probe-warm.sh PWT_RC_warm_get=1
[ "$(appreqs)" = 0 ] && [ -z "$(pwt_warm_rows pp-p12i)" ] && [ "$(pwt_gh_calls | grep -c .)" = 1 ] && ok || bad "P12i: app=$(ppt_reqs) gh=$(pwt_gh_calls)"
grep -q "perf-probe-warm pp-p12i warm-get rc=1$" "$PPT_H/logs/perf-probe-warm.log" && ok || bad "P12i log: $(wlog)"

# ══ P12j a deployment id outside the run_key rule ════════════════════════════
setup p12j pp-p12j "$st3" '["/a"]'
pwt_gh deployments 200 '[{"id":"d 42"}]'; pwt_gh statuses 200 '[{"state":"success"}]'
pwt_lane perf-probe-warm.sh
[ "$(appreqs)" = 0 ] && [ -z "$(pwt_warm_rows pp-p12j)" ] && [ "$(pwt_gh_calls | grep -c .)" = 1 ] && ok || bad "P12j: app=$(ppt_reqs) gh=$(pwt_gh_calls)"
[ "$(wlines pp-p12j)" = 1 ] && ok || bad "P12j log: $(wlog)"

# ══ P12k no repo on the row: one skip line, silent after ═════════════════════
setup p12k pp-p12k "$st3" '["/a"]' 'del(.repo)'
pwt_gh deployments 200 "$DEP"
pwt_lane perf-probe-warm.sh
pwt_lane perf-probe-warm.sh PERF_PROBE_NOW=$LATER
[ -z "$(pwt_gh_calls)" ] && [ "$(appreqs)" = 0 ] && ok || bad "P12k no repo: gh=$(pwt_gh_calls)"
[ "$(wlines pp-p12k)" = 1 ] && grep -q "perf-probe-warm pp-p12k skip: no repo$" "$PPT_H/logs/perf-probe-warm.log" && ok || bad "P12k log: $(wlog)"

# ══ P13 the pass-2 outcome table ═════════════════════════════════════════════
seq13='{"/b":[{"status":200},{"status":500},{"status":200}],"/c":[{"status":200},{"status":500}],"/d":[{"status":200},{"status":200,"delay_ms":2500},{"status":200}]}'
setup p13 pp-p13 "{\"paths\":{\"$SESSION\":$sess_ok,\"/e\":{\"status\":404},\"/f\":{\"status\":302,\"location\":\"/elsewhere\"},\"/g\":{\"status\":200,\"size\":2000}},\"seq\":$seq13}" '["/b","/c","/d","/e","/f","/g"]'
pwt_gh deployments 200 "$DEP"; pwt_gh statuses 200 '[{"state":"success"}]'
pwt_lane perf-probe-warm.sh PERF_PROBE_TIMEOUT_S=1 PERF_PROBE_BUDGET_BYTES=1000
got=$(ppt_d1 "SELECT route,outcome,loads,breaks,over_budget FROM perf_probe_results WHERE project='pp-p13' ORDER BY route")
want=$'/b|failed-then-recovered|2|1|0\n/c|fail|2|2|1\n/d|failed-then-recovered|2|1|0\n/e|unmeasured|1|0|0\n/f|unmeasured|1|0|0\n/g|fail|1|0|1'
[ "$got" = "$want" ] && ok || bad "P13 outcome rows: got
$got"
[ "$(ppt_count '.path=="/b"')" = 3 ] && [ "$(ppt_count '.path=="/c"')" = 3 ] && ok || bad "P13b/c one retry on a broken load: $(ppt_reqs 'select(.path=="/b" or .path=="/c")')"
[ "$(ppt_count '.path=="/e"')" = 2 ] && [ "$(ppt_count '.path=="/f"')" = 2 ] && [ "$(ppt_count '.path=="/elsewhere"')" = 0 ] && ok || bad "P13e/f a 4xx or 3xx is not retried: $(ppt_reqs)"
[ "$(pwt_warm_rows pp-p13)" = "4242|warmed|6|2" ] && ok || bad "P13 warm row: $(pwt_warm_rows pp-p13)"
grep -qE "perf-probe-warm pp-p13 deployment=4242 routes=6 over=2 recovered=2 results=ok warm=ok$" "$PPT_H/logs/perf-probe-warm.log" && ok || bad "P13 log: $(wlog)"

# ══ P13g results-put fails: the warm row is still written ════════════════════
setup p13g pp-p13g "$st3" '["/a"]'
pwt_gh deployments 200 "$DEP"; pwt_gh statuses 200 '[{"state":"success"}]'
pwt_lane perf-probe-warm.sh PWT_RC_results_put=1
[ "$(pwt_warm_rows pp-p13g)" = "4242|warmed|1|0" ] && ok || bad "P13g warm row: $(pwt_warm_rows pp-p13g)"
grep -qE "perf-probe-warm pp-p13g deployment=4242 routes=1 over=0 recovered=0 results=rc=1 warm=ok$" "$PPT_H/logs/perf-probe-warm.log" && ok || bad "P13g log: $(wlog)"
# warm-put fails: no row, the line says so, the next poll warms again
setup p13h pp-p13h "$st3" '["/a"]'
pwt_gh deployments 200 "$DEP"; pwt_gh statuses 200 '[{"state":"success"}]'
pwt_lane perf-probe-warm.sh PWT_RC_warm_put=1
grep -qE "perf-probe-warm pp-p13h deployment=4242 routes=1 over=0 recovered=0 results=ok warm=rc=1$" "$PPT_H/logs/perf-probe-warm.log" && ok || bad "P13h log: $(wlog)"
pwt_lane perf-probe-warm.sh PERF_PROBE_NOW=$LATER
[ "$(ppt_count '.path=="/a"')" = 4 ] && [ "$(pwt_warm_rows pp-p13h)" = "4242|warmed|1|0" ] && ok || bad "P13h the next poll must warm again: $(ppt_count '.path=="/a"') $(pwt_warm_rows pp-p13h)"

# ══ P14 the health preflight ═════════════════════════════════════════════════
setup p14 pp-p14 "{\"paths\":{\"$SESSION\":$sess_ok,\"/a\":{\"status\":200}},\"health\":{\"status\":503}}" '["/a"]'
pwt_gh deployments 200 "$DEP"; pwt_gh statuses 200 '[{"state":"success"}]'
pwt_lane perf-probe-warm.sh PERF_PROBE_HEALTH_WAIT_S=2 PERF_PROBE_HEALTH_POLL_S=1
nh=$(ppt_count '.path=="/api/health"')
[ "$nh" -ge 2 ] && [ "$nh" -le 4 ] && ok || bad "P14 health polls: $nh"
[ "$(ppt_count ".path==\"$SESSION\" or .path==\"/a\"")" = 0 ] && ok || bad "P14 health down: session or route requests: $(ppt_reqs)"
[ -z "$(pwt_warm_rows pp-p14)" ] && ok || bad "P14 a row with health down"
[ "$(wlines pp-p14)" = 1 ] && grep -q "perf-probe-warm pp-p14 health /api/health not 200 after 2s, deployment 4242 not warmed$" "$PPT_H/logs/perf-probe-warm.log" && ok || bad "P14 log: $(wlog)"
# health 200 on the 2nd poll, on the row's own health_path
setup p14b pp-p14b "{\"paths\":{\"$SESSION\":$sess_ok,\"/a\":{\"status\":200}},\"seq\":{\"/healthz\":[{\"status\":503},{\"status\":200}]}}" '["/a"]' '.health_path="/healthz"'
pwt_gh deployments 200 "$DEP"; pwt_gh statuses 200 '[{"state":"success"}]'
pwt_lane perf-probe-warm.sh PERF_PROBE_HEALTH_WAIT_S=5 PERF_PROBE_HEALTH_POLL_S=1
[ "$(ppt_count '.path=="/healthz"')" = 2 ] && [ "$(ppt_count '.path=="/a"')" = 2 ] && [ "$(pwt_warm_rows pp-p14b)" = "4242|warmed|1|0" ] \
  && ok || bad "P14b health 200 on poll 2: $(ppt_reqs) rows=$(pwt_warm_rows pp-p14b)"
# the fake's health handler answers the default path with 200
setup p14c pp-p14c "{\"paths\":{\"$SESSION\":$sess_ok,\"/a\":{\"status\":200}}}" '["/a"]'
c=$(curl -s -o /dev/null -w '%{http_code}' "$PPT_BASE/api/health")
[ "$c" = 200 ] && ok || bad "P14c health.py default answer $c"
ppt_state '{"health_path":"/hz","health":{"status":503}}'
c=$(curl -s -o /dev/null -w '%{http_code}' "$PPT_BASE/hz"); c2=$(curl -s -o /dev/null -w '%{http_code}' "$PPT_BASE/api/health")
[ "$c" = 503 ] && [ "$c2" = 404 ] && ok || bad "P14c health.py state.health_path: /hz=$c /api/health=$c2"

# ══ P14d the session is refused: no row ══════════════════════════════════════
setup p14d pp-p14d '{"paths":{"/api/internal/e2e/session":{"status":403},"/a":{"status":200}}}' '["/a"]'
pwt_gh deployments 200 "$DEP"; pwt_gh statuses 200 '[{"state":"success"}]'
pwt_lane perf-probe-warm.sh
[ "$(ppt_count '.path=="/a"')" = 0 ] && [ -z "$(pwt_warm_rows pp-p14d)" ] && grep -q "perf-probe-warm pp-p14d skip: session 403$" "$PPT_H/logs/perf-probe-warm.log" \
  && ok || bad "P14d session refused: $(ppt_reqs) $(wlog)"

# ══ P15b the lock is held ════════════════════════════════════════════════════
setup p15b pp-p15b "$st3" '["/a"]'
pwt_gh deployments 200 "$DEP"; pwt_gh statuses 200 '[{"state":"success"}]'
lockf="$PPT_H/locks/perf-probe-pp-p15b.lock"
flock "$lockf" sleep 20 >/dev/null 2>&1 & holder=$!
i=0; while flock -n "$lockf" true 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i+1)); done
pwt_lane perf-probe-warm.sh
pkill -P "$holder" 2>/dev/null; kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
[ -z "$(pwt_gh_calls)" ] && [ "$(appreqs)" = 0 ] && [ ! -e "$PPT_H/state/perf-probe/pp-p15b/warm.json" ] && ok || bad "P15b lock held: gh=$(pwt_gh_calls) app=$(ppt_reqs)"
pwt_lane perf-probe-warm.sh PERF_PROBE_NOW=2026-11-18T06:18:00Z
[ "$(pwt_warm_rows pp-p15b)" = "4242|warmed|1|0" ] && ok || bad "P15b the next minute must run: $(pwt_warm_rows pp-p15b)"

# ══ P16x a 401 route: ppio_on_ended once, then stop with no row ══════════════
setup p401 pp-p401 "{\"paths\":{\"$SESSION\":$sess_ok,\"/a\":{\"status\":401}}}" '["/a"]'
pwt_gh deployments 200 "$DEP"; pwt_gh statuses 200 '[{"state":"success"}]'
pwt_lane perf-probe-warm.sh
[ "$(ppt_count '.path=="/a"')" = 1 ] && [ -z "$(pwt_warm_rows pp-p401)" ] && grep -q "perf-probe-warm pp-p401 stop: session ended$" "$PPT_H/logs/perf-probe-warm.log" \
  && ok || bad "P401: $(ppt_reqs) $(wlog)"

# ══ P0 the lane is off ═══════════════════════════════════════════════════════
setup p0 pp-p0 "$st3" '["/a"]'
pwt_gh deployments 200 "$DEP"; pwt_gh statuses 200 '[{"state":"success"}]'
pwt_lane perf-probe-warm.sh PERF_PROBE_WARM_ENABLED=0
[ -z "$(pwt_gh_calls)" ] && [ "$(appreqs)" = 0 ] && ok || bad "P0 ENABLED=0: gh=$(pwt_gh_calls)"
touch "$PPT_H/flags/lane-off-perf-probe-warm"
pwt_lane perf-probe-warm.sh
[ -z "$(pwt_gh_calls)" ] && [ "$(appreqs)" = 0 ] && ok || bad "P0 flag: gh=$(pwt_gh_calls)"
rm -f "$PPT_H/flags/lane-off-perf-probe-warm"
pwt_lane perf-probe-warm.sh
[ "$(pwt_warm_rows pp-p0)" = "4242|warmed|1|0" ] && ok || bad "P0 the flag removed: the lane must run: $(pwt_warm_rows pp-p0)"
# a disabled row: silent, 0 requests
setup p0b pp-p0b "$st3" '["/a"]' '.enabled=false'
pwt_gh deployments 200 "$DEP"
pwt_lane perf-probe-warm.sh
[ -z "$(pwt_gh_calls)" ] && [ -z "$(wlog)" ] && ok || bad "P0b disabled row: gh=$(pwt_gh_calls) log=$(wlog)"

# ══ C1 the client verbs ══════════════════════════════════════════════════════
c1() { # <op> <arg> [JOBS_URL]; FAKE_HTTP and FAKE_RC set the fake _jobs_req
  JOBS_URL="${3-http://jobs.test}" HARNESS_SECRET=fixture-secret bash -c '
    _jobs_req() { JOBS_HTTP=$FAKE_HTTP; printf "%s %s %s\n" "$1" "$2" "${3:-}" > "$CALLS"; printf "{}"; return "$FAKE_RC"; }
    . "$1" || exit 99; . "$2" || exit 99; . "$3" || exit 99; jc_verb_perf_probe "$4" "$5" >/dev/null' _ "$REPO/bin/jobs-client.d/bh-9786-perf-probe.sh" \
    "$REPO/bin/jobs-client.d/bh-9792-perf-probe-warm-get.sh" "$REPO/bin/jobs-client.d/bh-9792-perf-probe-warm-put.sh" "$1" "$2"
}
export CALLS="$T/c1.calls"
FAKE_HTTP=200 FAKE_RC=0 c1 warm-get pp-c1; rc=$?
[ "$rc" = 0 ] && [ "$(cat "$CALLS")" = "GET /api/perf-probe/warm?project=pp-c1 " ] && ok || bad "C1 warm-get rc=$rc calls=$(cat "$CALLS" 2>/dev/null)"
FAKE_HTTP=200 FAKE_RC=0 c1 warm-put '{"project":"pp-c1"}'; rc=$?
[ "$rc" = 0 ] && [ "$(cat "$CALLS")" = 'POST /api/perf-probe/warm {"project":"pp-c1"}' ] && ok || bad "C1 warm-put rc=$rc calls=$(cat "$CALLS" 2>/dev/null)"
FAKE_HTTP=503 FAKE_RC=1 c1 warm-get pp-c1; rc=$?; [ "$rc" = 1 ] && ok || bad "C1 5xx rc=$rc"
FAKE_HTTP=400 FAKE_RC=1 c1 warm-put '{}'; rc=$?; [ "$rc" = 4 ] && ok || bad "C1 4xx rc=$rc"
rm -f "$CALLS"; FAKE_HTTP=200 FAKE_RC=0 c1 warm-get pp-c1 ""; rc=$?; [ "$rc" = 4 ] && [ ! -e "$CALLS" ] && ok || bad "C1 no JOBS_URL rc=$rc"
FAKE_HTTP=200 FAKE_RC=0 c1 warm-get ""; rc=$?; [ "$rc" = 4 ] && ok || bad "C1 empty argument rc=$rc"
# the real client against the fake worker route (the production entry point)
pwt_tree c1e || exit 1; ppt_server_start c1e || exit 1
ppt_state '{"paths":{"/api/perf-probe/warm":{"status":200,"json":{"row":null}}}}'
mkdir -p "$T/c1e/h/env"
out=$(HARNESS="$T/c1e/h" JOBS_URL="$PPT_BASE" HARNESS_SECRET=fixture-secret JOBS_RETRIES=0 bash "$REPO/bin/jobs-client.sh" perf-probe warm-get pp-c1e); rc=$?
[ "$rc" = 0 ] && [ "$(jq -c . <<<"$out" 2>/dev/null)" = '{"row":null}' ] && [ "$(ppt_count '.method=="GET" and .path=="/api/perf-probe/warm" and .auth==true')" = 1 ] \
  && ok || bad "C1e real client warm-get: rc=$rc out='$out' reqs=$(ppt_reqs)"
out=$(HARNESS="$T/c1e/h" JOBS_URL="$PPT_BASE" HARNESS_SECRET=fixture-secret JOBS_RETRIES=0 bash "$REPO/bin/jobs-client.sh" perf-probe warm-put '{"project":"pp-c1e"}'); rc=$?
[ "$rc" = 0 ] && [ "$(ppt_count '.method=="POST" and .path=="/api/perf-probe/warm" and .body=="{\"project\":\"pp-c1e\"}"')" = 1 ] && ok || bad "C1e real client warm-put: rc=$rc reqs=$(ppt_reqs)"

# ══ Z1 no ticket, no agent call ══════════════════════════════════════════════
hits=$(grep -nE 'agent-call|claude |pp_ticket_step|tracker|board-api' "$REPO/bin/perf-probe-warm.sh" 2>/dev/null)
[ -z "$hits" ] && ok || bad "Z1 the warm lane files a ticket or calls an agent: $hits"

echo "perf-probe-warm.bh-9792: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
