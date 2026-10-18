#!/bin/bash
# tests/fleet-version-sink.bh-7191-test.sh — BH-7306 (BH-7191.4): the console
# sink of the fleet version check. fvc_sink (bin/lib/fleet-version-sink.sh)
# reads the fvc_decide output on stdin and sends ONE POST /api/boxes/lag per
# tick (worker/jobs/src/routes/boxes-lag.js). The console Machines view reads
# the stored lag back through console-ui/src/lib/boxes-version-api.js.
#
#   S1     the real decide shapes (lag=<n>m) give one POST, rows a=0 b=40
#   S2     the bare lag=<n> form gives the same rows
#   S3     the line table: only OK and ALERT lag lag=<n> lines are rows
#   S4     failure paths: one log line, rc 0, empty stdout; the log target
#   S5     the round trip against the REAL jobs worker; a down worker
#   S6     the lane bin/fleet-version-check.sh end to end stores the lag
#   C1     console-ui/src/lib/boxes-version-api.js pure helpers, driven
#   C2     the console node suite, when the console-ui deps are installed
#
# Run from anywhere: tests/fleet-version-sink.bh-7191-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
SRV="$REPO/tests/lib/fleet-version-worker.bh-7191.mjs"
VAPI="$REPO/console-ui/src/lib/boxes-version-api.js"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: want [$3] got [$2]"; fi; }
has() { if grep -qE -- "$3" <<<"$2"; then ok "$1"; else bad "$1: no /$3/ in [$2]"; fi; }
hasnt() { if grep -qE -- "$3" <<<"$2"; then bad "$1: unexpected /$3/ in [$2]"; else ok "$1"; fi; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 \
  && command -v git >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 \
  || { echo "SKIP: node, jq, flock, git or curl missing"; exit 0; }

H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/locks" "$H/state" "$H/flags" "$H/catalog"
for L in bin/fleet-version-check.sh bin/jobs-client.sh bin/alert-line.sh; do
  ( cd "$REPO" && scratch_install_closure "$L" "$H" ) >/dev/null 2>&1 || bad "setup: could not install $L"
done
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "%s/beat.payloads"\nexit 0\n' "$T" > "$H/bin/beat.sh"
chmod +x "$H/bin/"*.sh 2>/dev/null
SINK="$H/bin/lib/fleet-version-sink.sh"
cmp -s "$REPO/bin/lib/fleet-version-sink.sh" "$SINK" && ok "closure installs the sink as shipped" || bad "closure lacks the sink"

# sink <stub-mode> — runs fvc_sink in a subshell on stdin. Stub modes: ok
# (rc 0, http 200), fail (rc 1, JOBS_HTTP empty), http500 (rc 1, JOBS_HTTP 500),
# none (no _jobs_req at all). The stub keeps each call (method, path, the
# JOBS_RETRIES it saw, the body) in $T/calls. stdout and rc go to $T/sink.out.
sink() {
  local mode=$1
  : > "$T/calls"; : > "$T/sink.log"
  (
    unset -f _jobs_req
    unset HARNESS
    export LOG="$T/sink.log"
    # shellcheck source=bin/lib/fleet-version-sink.sh
    . "$SINK" || exit 7
    case "$mode" in
      ok)      _jobs_req() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "${JOBS_RETRIES:-unset}" "$3" >> "$T/calls"; JOBS_HTTP=200; echo '{"updated":1}'; return 0; } ;;
      fail)    _jobs_req() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "${JOBS_RETRIES:-unset}" "$3" >> "$T/calls"; JOBS_HTTP=""; return 1; } ;;
      http500) _jobs_req() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "${JOBS_RETRIES:-unset}" "$3" >> "$T/calls"; JOBS_HTTP=500; echo '{"error":"x"}'; return 1; } ;;
    esac
    fvc_sink
    echo "rc=$?"
  ) > "$T/sink.out" 2> "$T/sink.err"
}
calls() { grep -c . "$T/calls" 2>/dev/null || true; }
rowsof() { awk -F'\t' 'NR==1 { print $4 }' "$T/calls" | jq -r '.rows | map("\(.box)=\(.lag_min)") | join(",")'; }

echo "S1: the real decide shapes"
printf '%s\n' "OK a lag=0m" "ALERT b lag lag=40m sha=abcd1234" | sink ok
eq "S1 one POST" "$(calls)" 1
eq "S1 POST /api/boxes/lag" "$(awk -F'\t' '{print $1, $2}' "$T/calls")" "POST /api/boxes/lag"
eq "S1 rows a=0, b=40" "$(rowsof)" "a=0,b=40"
eq "S1 lag_min is a number" "$(awk -F'\t' '{print $4}' "$T/calls" | jq -r '[.rows[].lag_min | type] | unique | join(",")')" "number"
eq "S1 the POST is never retried (JOBS_RETRIES=0)" "$(awk -F'\t' '{print $3}' "$T/calls")" 0
eq "S1 stdout is only the rc" "$(cat "$T/sink.out")" "rc=0"
eq "S1 one log line" "$(grep -c . "$T/sink.log")" 1
has "S1 it says posted 2 lag rows" "$(cat "$T/sink.log")" "^[0-9T:-]+Z fvc_sink: posted 2 lag rows$"

echo "S2: the bare lag=<n> form"
printf '%s\n' "OK a lag=0" "ALERT b lag lag=40" | sink ok
eq "S2 one POST" "$(calls)" 1
eq "S2 rows a=0, b=40" "$(rowsof)" "a=0,b=40"

echo "S3: the line table"
NO=(
  "ALERT c lag lag>=500m sha=abcd1234"
  "ALERT c lag lag unreadable (x) sha=abcd1234"
  "ALERT c lag sha not on main sha=abcd1234"
  "ALERT d nosha no sha reported"
  "ALERT d nosha report stale (2026-10-17T00:00:00Z)"
  "SKIP e no box_status row"
  "OK f lag=-3m"
  "OK f lag=3x"
  "XOK g lag=1m"
  "OK"
  ""
)
for l in "${NO[@]}"; do
  printf '%s\n' "$l" "OK z lag=1m" | sink ok
  eq "S3 [$l] is not a row" "$(rowsof)" "z=1"
done
printf '%s\n' "OK a lag=5m" "ALERT b lag lag=40m sha=abcd1234" "OK a lag=0m" | sink ok
eq "S3 the same box twice: one row, the last value wins" "$(rowsof)" "a=0,b=40"
printf '%s\n' "${NO[@]}" | sink ok
eq "S3 only non-row lines: no POST" "$(calls)" 0
eq "S3 only non-row lines: no log line" "$(grep -c . "$T/sink.log")" 0
eq "S3 only non-row lines: rc 0, no stdout" "$(cat "$T/sink.out")" "rc=0"
: | sink ok
eq "S3 empty stdin: no POST" "$(calls)" 0
for i in $(seq 1 205); do echo "OK box-$i lag=${i}m"; done | sink ok
eq "S3 205 boxes: one POST capped at 200 rows (the route cap)" "$(awk -F'\t' '{print $4}' "$T/calls" | jq '.rows | length')" 200

echo "S4: failure paths"
printf '%s\n' "OK a lag=0m" "ALERT b lag lag=40m sha=abcd1234" | sink fail
eq "S4 a failed POST: rc 0 and no stdout" "$(cat "$T/sink.out")" "rc=0"
eq "S4 a failed POST: one attempt" "$(calls)" 1
eq "S4 a failed POST: one log line" "$(grep -c . "$T/sink.log")" 1
has "S4 it names no http status" "$(cat "$T/sink.log")" "fvc_sink: lag post failed \\(http none\\)$"
hasnt "S4 no posted line" "$(cat "$T/sink.log")" "posted"
printf '%s\n' "OK a lag=0m" | sink http500
has "S4 an http 500 is named" "$(cat "$T/sink.log")" "fvc_sink: lag post failed \\(http 500\\)$"
eq "S4 an http 500: rc 0 and no stdout" "$(cat "$T/sink.out")" "rc=0"
printf '%s\n' "OK a lag=0m" | sink none
eq "S4 no jobs client: one log line" "$(grep -c . "$T/sink.log")" 1
has "S4 no jobs client: it says so" "$(cat "$T/sink.log")" "fvc_sink: jobs client not loaded$"
eq "S4 no jobs client: rc 0 and no stdout" "$(cat "$T/sink.out")" "rc=0"
# The log target: LOG unset and HARNESS set -> $HARNESS/logs/fleet-version-check.log.
mkdir -p "$T/h2/logs"
o=$( unset LOG; export HARNESS="$T/h2"; . "$SINK"; echo "OK a lag=0m" | fvc_sink; echo "rc=$?" )
eq "S4 LOG unset: rc 0, no stdout" "$o" "rc=0"
has "S4 LOG unset: the line goes to \$HARNESS/logs/fleet-version-check.log" "$(cat "$T/h2/logs/fleet-version-check.log" 2>/dev/null)" "fvc_sink: jobs client not loaded$"
o=$( unset LOG HARNESS; . "$SINK"; echo "OK a lag=0m" | fvc_sink 2>&1 >/dev/null )
has "S4 LOG and HARNESS unset: the line goes to stderr" "$o" "fvc_sink: jobs client not loaded$"

echo "S5: the round trip against the real jobs worker"
PIDS=()
stop_all() { local p; for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; }
trap 'stop_all' EXIT
NOW=1792000000   # 2026-10-14T17:46:40Z
export FVC_NOW=$NOW LANE_GATE_NOW=$NOW
export HARNESS="$H" HARNESS_SECRET=fixture-harness-secret BOX_NAME=fixture-hub JOBS_BOX=fixture-hub
export JOBS_SETTINGS_CACHE_S=0 JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0
fresh() {
  local n=$((${#PIDS[@]} + 1)) i pid
  : > "$T/w$n.log"; : > "$T/w$n.port"
  node "$SRV" "$T/w$n.log" "$NOW" > "$T/w$n.port" 2> "$T/w$n.err" &
  pid=$!; PIDS+=("$pid"); WPID=$pid; WLOG="$T/w$n.log"
  for i in $(seq 1 200); do [ -s "$T/w$n.port" ] && break; kill -0 "$pid" 2>/dev/null || break; sleep 0.05; done
  PORT=$(head -1 "$T/w$n.port")
  [ -n "$PORT" ] || { echo "SKIP: the fixture worker did not start ($(head -3 "$T/w$n.err"))"; exit 0; }
  export JOBS_URL="http://127.0.0.1:$PORT"
  : > "$H/logs/ALERTS.log"; : > "$H/logs/fleet-version-check.log"
}
sql() { curl -sS -X POST "$JOBS_URL/__sql" -d "$(jq -nc --arg s "$1" '{sql:$s, params:$ARGS.positional}' --args "${@:2}")"; }
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
status() {
  sql "INSERT INTO box_status (box, harness_commit, harness_reported_at, updated_at) VALUES (?,?,?,?) ON CONFLICT(box) DO UPDATE SET harness_commit=excluded.harness_commit, harness_reported_at=excluded.harness_reported_at" "$1" "$2" "$3" "$3" \
    | jq -e '.rows' >/dev/null 2>&1 || bad "setup: box_status row $1 not written"
}
boxes() { curl -sS -H "authorization: Bearer $HARNESS_SECRET" "$JOBS_URL/api/boxes"; }
fresh
status a abcd1234abcd "$(iso "$NOW")"; status b abcd1234abcd "$(iso "$NOW")"
o=$( export LOG="$T/real.log"; . "$H/bin/jobs-client.sh"; . "$SINK"
     printf '%s\n' "OK a lag=0m" "ALERT b lag lag=40m sha=abcd1234" "OK zz lag=3m" | fvc_sink; echo "rc=$?" )
eq "S5 rc 0, no stdout" "$o" "rc=0"
eq "S5 one POST /api/boxes/lag 200" "$(grep -c '^POST /api/boxes/lag 200$' "$WLOG")" 1
has "S5 posted 3 lag rows" "$(cat "$T/real.log")" "fvc_sink: posted 3 lag rows$"
B=$(boxes)
eq "S5 GET /api/boxes: b harness_lag_min=40" "$(jq -r '.boxes[] | select(.box=="b") | .harness_lag_min' <<<"$B")" 40
eq "S5 GET /api/boxes: a harness_lag_min=0" "$(jq -r '.boxes[] | select(.box=="a") | .harness_lag_min' <<<"$B")" 0
eq "S5 lag_checked_at is the worker clock" "$(jq -r '.boxes[] | select(.box=="b") | .lag_checked_at' <<<"$B")" "$(iso "$NOW")"
eq "S5 the unknown box zz made no row" "$(jq -r '[.boxes[] | select(.box=="zz")] | length' <<<"$B")" 0
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
o=$( export LOG="$T/down.log"; . "$H/bin/jobs-client.sh"; . "$SINK"
     echo "OK a lag=0m" | fvc_sink; echo "rc=$?" )
eq "S5 worker down: rc 0, no stdout" "$o" "rc=0"
eq "S5 worker down: one log line" "$(grep -c . "$T/down.log")" 1
has "S5 worker down: lag post failed (http none)" "$(cat "$T/down.log")" "fvc_sink: lag post failed \\(http none\\)$"

echo "S6: the lane end to end"
G="$T/work"; ORIGIN="$T/origin.git"; HCO="$T/hco"
git init -q --bare -b main "$ORIGIN"; git init -q -b main "$G"
git -C "$G" config user.email fixture@example.invalid; git -C "$G" config user.name fixture
mkdir -p "$G/bin"; echo a > "$G/bin/a"; git -C "$G" add -A
GIT_AUTHOR_DATE="@$((NOW - 3600)) +0000" GIT_COMMITTER_DATE="@$((NOW - 3600)) +0000" git -C "$G" commit -qm C0
git -C "$G" push -q "$ORIGIN" main; git clone -q "$ORIGIN" "$HCO"
TIP=$(git -C "$G" rev-parse HEAD)
export HARNESS_CHECKOUT="$HCO"
fresh
sql "INSERT INTO registry_boxes (box, box_id, updated_at) VALUES ('box-current','current','2026-10-14T00:00:00Z')" | jq -e '.rows' >/dev/null 2>&1 \
  || bad "setup: registry_boxes row not written"
status box-current "$TIP" "$(iso $((NOW - 60)))"
"$H/bin/fleet-version-check.sh" > "$T/tick.out" 2>&1; rc=$?
eq "S6 the lane exits 0" "$rc" 0
LG=$(cat "$H/logs/fleet-version-check.log")
has "S6 the decide line is OK box-current lag=0m" "$LG" "OK box-current lag=0m"
has "S6 the sink posted 1 lag row" "$LG" "fvc_sink: posted 1 lag rows$"
eq "S6 GET /api/boxes: box-current harness_lag_min=0" "$(boxes | jq -r '.boxes[] | select(.box=="box-current") | .harness_lag_min')" 0

echo "C1: console-ui/src/lib/boxes-version-api.js, driven"
[ -f "$VAPI" ] && ok "boxes-version-api.js exists" || bad "missing $VAPI"
OUT=$(node --input-type=module -e "
const { shortSha, lagView, LAG_FRESH_MIN } = await import('$VAPI');
const now = Date.parse('2026-10-14T06:00:00Z');
const at = (m) => new Date(now - m * 60000).toISOString();
const say = (n, v) => console.log(n + '=' + JSON.stringify(v));
say('sha', shortSha('0123456789abcdef'));
say('fresh', LAG_FRESH_MIN);
say('cur', lagView({ harness_lag_min: 0, lag_checked_at: at(5) }, { ok: true, now, maxLagMin: 30 }).text);
say('old', lagView({ harness_lag_min: 0, lag_checked_at: at(20) }, { ok: true, now, maxLagMin: 30 }).text);
say('amber', lagView({ harness_lag_min: 40, lag_checked_at: at(1) }, { ok: true, now, maxLagMin: 30 }));
say('down', lagView({ harness_lag_min: 0, lag_checked_at: at(1) }, { ok: false, now, maxLagMin: 30 }).text);
" 2>&1)
has "C1 shortSha is 8 chars" "$OUT" '^sha="01234567"$'
has "C1 the fresh window is 20 min" "$OUT" '^fresh=20$'
has "C1 lag 0 checked 5 min ago is current" "$OUT" '^cur="current"$'
has "C1 lag 0 checked 20 min ago is unchecked" "$OUT" '^old="unchecked"$'
has "C1 lag 40 over 30 is amber" "$OUT" '^amber=\{"text":"40 min","tone":"warn","sort":40\}$'
has "C1 a failed feed is unavailable" "$OUT" '^down="unavailable"$'

echo "C2: the console node suite"
if [ ! -d "$REPO/console-ui/node_modules/preact" ]; then
  echo "  C2 SKIPPED: console-ui dependencies are not installed (the console-ui CI job runs it)"
elif NOUT=$(cd "$REPO/console-ui" && node --test tests/machines-version.bh-7191.test.js 2>&1); then
  ok "C2 console-ui/tests/machines-version.bh-7191.test.js passes"
else
  bad "C2 console-ui/tests/machines-version.bh-7191.test.js failed"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
fi

echo
echo "fleet-version-sink.bh-7191: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
