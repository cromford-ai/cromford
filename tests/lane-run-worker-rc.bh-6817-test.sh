#!/bin/bash
# tests/lane-run-worker-rc.bh-6817-test.sh — BH-6817 item 2: a lane run with
# rc != 0 ends `failed` (the jobs worker's answer), with its rc and the first
# stderr line in the stored prof; rc 126/127 is `command-missing`, the worker
# never starts a command that is not in its harness, and it writes at most one
# alert per lane per lane_run.command_missing_alert_s (default 3600).
#
# Driven through the REAL bin/lane-run-worker.sh --once over real curl against
# the REAL jobs worker (tests/lib/lane-runs-worker.bh-6124.mjs). lane-alert.sh
# is a stub that records each call, so the count is the worker's own throttle.
#
#   R1  args bin/absent.sh -> not started; D1 rc 127, attempts 1, by-prefix
#       failed command-missing, prof names the command; a second --once does
#       not run it again
#   R2  a script that prints boom on stderr and exits 3 -> failed rc 3
#       exit-nonzero, prof `<its PROF line> rc=3 reason=exit-nonzero err=boom`,
#       stdout then stderr in logs/<lane>-cron.log
#   R3  a script that exits 0 -> done, prof is its PROF line, no suffix
#   R4  one alert per lane per hour: a second lane-a row in the hour, and at
#       3599 s, write none; at 3600 s a second; lane-b its own
#   R5  a script that is present but not executable -> command-missing, not run
#   R6  a script that runs and exits 126 itself -> command-missing
#
# Run from anywhere: tests/lane-run-worker-rc.bh-6817-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
[ -f "$DIR/catalog/lanes.json" ] || HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --write >/dev/null \
  || { echo "FAIL: cannot compose catalog/lanes.json"; exit 1; }
SRV="$DIR/tests/lib/lane-runs-worker.bh-6124.mjs"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 \
  || { echo "SKIP: node, jq or flock missing"; exit 0; }

H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/locks" "$H/state" "$H/env" "$H/flags"
for L in bin/lane-run-worker.sh bin/project-lane-run.sh bin/fleet-conf.sh bin/jobs-client.sh bin/lib/gh-app-auth.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null 2>&1 || bad "setup: could not install $L"
done
chmod +x "$H/bin/"*.sh 2>/dev/null
printf 'p1 o/p1 - - 2 box-p1 192.0.2.1\n' > "$H/fleet.conf"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts.txt"\nexit 0\n' "$T" > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/lane-alert.sh"
: > "$T/alerts.txt"
cat > "$H/bin/boom.sh" <<'EOF'
#!/bin/bash
echo "PROF boom x=1"
echo "some stdout"
echo "" >&2
echo "boom" >&2
echo "second stderr line" >&2
exit 3
EOF
cat > "$H/bin/okay.sh" <<'EOF'
#!/bin/bash
echo "PROF okay x=2"
exit 0
EOF
cat > "$H/bin/noexec.sh" <<EOF
#!/bin/bash
touch "$T/noexec-ran"
EOF
cat > "$H/bin/self126.sh" <<'EOF'
#!/bin/bash
echo "cannot execute helper" >&2
exit 126
EOF
chmod +x "$H/bin/boom.sh" "$H/bin/okay.sh" "$H/bin/self126.sh"
chmod -x "$H/bin/noexec.sh"

export HARNESS="$H" FLEET_CONF="$H/fleet.conf"
export HARNESS_SECRET=fixture-harness-secret GH_TOKEN=tok-fixture-default
export JOBS_SETTINGS_CACHE_S=0 JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 BOX_NAME=fixture-box
NOW0=1791000000

PID=""
: > "$T/w.log"; : > "$T/w.port"
node "$SRV" "$T/w.log" > "$T/w.port" 2> "$T/w.err" &
PID=$!
trap 'kill "$PID" 2>/dev/null' EXIT
for _ in $(seq 1 200); do [ -s "$T/w.port" ] && break; kill -0 "$PID" 2>/dev/null || break; sleep 0.05; done
PORT=$(head -1 "$T/w.port")
if [ -z "$PORT" ]; then wait "$PID"; [ "$?" = 3 ] && { echo "SKIP: node:sqlite unavailable in this runtime"; exit 0; }; echo "setup: worker did not start: $(cat "$T/w.err")"; exit 1; fi
export JOBS_URL="http://127.0.0.1:$PORT"

api() { curl -sS -X "$1" -H "authorization: Bearer $HARNESS_SECRET" -H 'content-type: application/json' ${3:+-d "$3"} "$JOBS_URL$2"; }
enq() { api POST /api/lane-runs "$(jq -nc --arg l "$1" --arg p "$2" --arg c "$3" '{lane:$l,project:$p,args:[$c]}')" | jq -r .id; }
# work [now] — one --once machine, the clock pinned.
work() { LANE_RUN_NOW="${1:-$NOW0}" "$H/bin/lane-run-worker.sh" --once --machine m1 > "$T/work.out" 2>&1; WRC=$?; }
drow() { curl -sS "$JOBS_URL/__lane_runs" | jq -c --argjson id "$1" '.rows[] | select(.id == $id)'; }
prow() { api GET "/api/lane-runs/by-prefix?lane=$1&project_prefix=$2" | jq -c --argjson id "$3" '.rows[] | select(.id == $id)'; }
nalert() { grep -c -- "--id lane-run-command-missing-$1 " "$T/alerts.txt"; }

# ============================================================================
echo "R1: a command that is not in the harness is not started"
ID=$(enq lane-a p1 bin/absent.sh)
work
[ "$WRC" = 0 ] && ok "R1 the loop exits 0" || bad "R1 rc=$WRC $(cat "$T/work.out")"
D=$(drow "$ID"); P=$(prow lane-a p1 "$ID")
[ "$(jq -r .status <<<"$D")" = done ] && [ "$(jq -r .rc <<<"$D")" = 127 ] && [ "$(jq -r .attempts <<<"$D")" = 1 ] \
  && ok "R1 D1 row done rc 127, attempts 1" || bad "R1 D1 row: $D"
[ "$(jq -r .status <<<"$P")" = failed ] && [ "$(jq -r .reason <<<"$P")" = command-missing ] \
  && ok "R1 by-prefix failed command-missing" || bad "R1 by-prefix: $P"
case "$(jq -r .prof_line <<<"$D")" in
  "PROF lane-run rc=127 reason=command-missing err=bin/absent.sh not in harness unknown") ok "R1 prof names the command and the commit" ;;
  *) bad "R1 prof: $(jq -r .prof_line <<<"$D")" ;;
esac
grep -q "run $ID lane-a/p1: bin/absent.sh is not an executable file in the harness; not run" "$H/logs/lane-run-worker.log" \
  && ok "R1 the worker log says it was not run" || bad "R1 log: $(tail -3 "$H/logs/lane-run-worker.log")"
work
[ "$(jq -r .attempts <<<"$(drow "$ID")")" = 1 ] && [ "$(curl -sS "$JOBS_URL/__lane_runs" | jq '[.rows[] | select(.lane == "lane-a")] | length')" = 1 ] \
  && ok "R1 terminal: a second --once does not re-claim it" || bad "R1 row after a second run: $(drow "$ID")"
[ "$(nalert lane-a)" = 1 ] && ok "R1 one alert for lane-a" || bad "R1 alerts: $(cat "$T/alerts.txt")"
grep -q -- "--severity warn --id lane-run-command-missing-lane-a lane-a " "$T/alerts.txt" \
  && ok "R1 the alert is warn, keyed by the lane" || bad "R1 alert: $(cat "$T/alerts.txt")"

# ============================================================================
echo "R2: a run that exits 3 is failed, with rc and the first stderr line"
ID=$(enq lane-b p1 bin/boom.sh)
work
D=$(drow "$ID"); P=$(prow lane-b p1 "$ID")
[ "$(jq -r .rc <<<"$D")" = 3 ] && [ "$(jq -r .status <<<"$P")" = failed ] && [ "$(jq -r .reason <<<"$P")" = exit-nonzero ] \
  && ok "R2 failed rc 3 exit-nonzero" || bad "R2 row: $D / $P"
[ "$(jq -r .prof_line <<<"$D")" = "PROF boom x=1 rc=3 reason=exit-nonzero err=boom" ] \
  && ok "R2 prof = its PROF line + rc, reason and the first non-empty stderr line" || bad "R2 prof: $(jq -r .prof_line <<<"$D")"
[ "$(grep -n 'some stdout\|^boom$' "$H/logs/lane-b-cron.log" | cut -d: -f2 | tr '\n' '|')" = "some stdout|boom|" ] \
  && ok "R2 stdout then stderr in logs/lane-b-cron.log" || bad "R2 cron log: $(cat "$H/logs/lane-b-cron.log")"
[ "$(nalert lane-b)" = 0 ] && ok "R2 exit-nonzero sends no command-missing alert" || bad "R2 alerts: $(cat "$T/alerts.txt")"

# ============================================================================
echo "R3: a run that exits 0 is done"
ID=$(enq lane-c p1 bin/okay.sh)
work
D=$(drow "$ID"); P=$(prow lane-c p1 "$ID")
[ "$(jq -r .rc <<<"$D")" = 0 ] && [ "$(jq -r .status <<<"$P")" = done ] && [ "$(jq -r .reason <<<"$P")" = null ] \
  && ok "R3 done rc 0" || bad "R3 row: $D / $P"
[ "$(jq -r .prof_line <<<"$D")" = "PROF okay x=2" ] && ok "R3 prof is the PROF line alone" || bad "R3 prof: $(jq -r .prof_line <<<"$D")"

# ============================================================================
echo "R4: one command-missing alert per lane per hour"
enq lane-a p2 bin/absent.sh >/dev/null; work "$NOW0"
[ "$(nalert lane-a)" = 1 ] && ok "R4 a second lane-a row in the same second: still 1" || bad "R4 alerts: $(nalert lane-a)"
enq lane-a p3 bin/absent.sh >/dev/null; work $((NOW0 + 3599))
[ "$(nalert lane-a)" = 1 ] && ok "R4 at 3599 s: still 1" || bad "R4 3599: $(nalert lane-a)"
enq lane-a p4 bin/absent.sh >/dev/null; work $((NOW0 + 3600))
[ "$(nalert lane-a)" = 2 ] && ok "R4 at 3600 s: 2" || bad "R4 3600: $(nalert lane-a)"
enq lane-d p1 bin/absent.sh >/dev/null; work $((NOW0 + 3600))
[ "$(nalert lane-d)" = 1 ] && [ "$(nalert lane-a)" = 2 ] && ok "R4 lane-d gets its own alert" || bad "R4 lane-d: $(cat "$T/alerts.txt")"
curl -sS -X PUT "$JOBS_URL/__setting" -d '{"key":"lane_run.command_missing_alert_s","value":"60"}' >/dev/null
enq lane-a p5 bin/absent.sh >/dev/null; work $((NOW0 + 3660))
[ "$(nalert lane-a)" = 3 ] && ok "R4 the window is the settings row (60 s)" || bad "R4 row 60: $(nalert lane-a)"

# ============================================================================
echo "R5: a file that is not executable is command-missing"
ID=$(enq lane-e p1 bin/noexec.sh)
work
D=$(drow "$ID"); P=$(prow lane-e p1 "$ID")
[ "$(jq -r .rc <<<"$D")" = 127 ] && [ "$(jq -r .reason <<<"$P")" = command-missing ] && [ ! -e "$T/noexec-ran" ] \
  && ok "R5 rc 127 command-missing, not run" || bad "R5 row: $D / $P"

# ============================================================================
echo "R6: a run that exits 126 itself is command-missing"
ID=$(enq lane-f p1 bin/self126.sh)
work
D=$(drow "$ID"); P=$(prow lane-f p1 "$ID")
[ "$(jq -r .rc <<<"$D")" = 126 ] && [ "$(jq -r .reason <<<"$P")" = command-missing ] \
  && [ "$(jq -r .prof_line <<<"$D")" = "PROF lane-run rc=126 reason=command-missing err=cannot execute helper" ] \
  && ok "R6 rc 126 command-missing, prof with the stderr line" || bad "R6 row: $D / $P"
[ "$(nalert lane-f)" = 1 ] && ok "R6 one alert for lane-f" || bad "R6 alerts: $(cat "$T/alerts.txt")"

# ============================================================================
echo "R7: the worker's status rule, worker/jobs/src/lib/lane-run-status.js"
STATUS_JS="$DIR/worker/jobs/src/lib/lane-run-status.js"
GOT=$(node --input-type=module -e "
  const { runStatus, failReason } = await import('$STATUS_JS');
  const rows = [['done', 0], ['done', 127], ['done', 3], ['died', 137], ['claimed', null]];
  console.log(rows.map(([s, rc]) => runStatus({ status: s, rc }) + '/' + failReason(rc)).join(' '));" 2>&1)
[ "$GOT" = "done/null failed/command-missing failed/exit-nonzero died/exit-nonzero claimed/null" ] \
  && ok "R7 runStatus/failReason over the stored row shapes" || bad "R7 got: $GOT"

echo "lane-run-worker-rc: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
