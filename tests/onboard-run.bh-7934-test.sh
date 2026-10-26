#!/bin/bash
# tests/onboard-run.bh-7934-test.sh — BH-7934.2 (#7949): bin/onboard-run.sh,
# the onboarding runner lane. The REAL script (installed with its source
# closure in a scratch harness) talks over real curl to the REAL jobs worker
# (tests/lib/onboarding-worker.bh-7949.mjs) on node:sqlite with the composed
# schema. The station lib is tests/lib/onboard-stations-stub.bh-7949.sh; gh,
# lane-alert.sh, fleet-conf.sh, postmerge-qa.sh and healthcheck.sh are stubs.
# Each case creates its own run with its own Idempotency-Key.
#
#   A  all pass: stations in order, beats in order, run done, `done` log line
#   D  idle: no queued run -> exit 0, `idle`, no beat
#   B  fail at label with HTTP 403 -> exit 1, app_no_issues_write, later skipped
#   C  retry of B -> label box clone only, run done
#   E  claim 409 -> exit 0, claim-lost, no station
#   F  cancel mid-run at box -> exit 0, run cancelled, clone not called
#   G  worker down -> exit 2 after ONBOARD_RUN_TRIES attempts, 1 unreachable alert
#   H  lane off -> exit 0, no request
#   I  not configured -> exit 2, no request, 1 not-configured alert
#   K  obs_label undefined -> label failed station_failed, never done
#   L  obs_smoke checks
#   M  obs_error_code table, near misses included
#   N  tracker=board -> tracker failed tracker_not_built
#   P  bad argument -> exit 64, no request
#   J  stale running run -> the same stale_run id on two ticks; 29 min -> none
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/onboard-run.bh-7934-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib/worker-catalogs.sh
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
worker_catalogs "$DIR" || exit 1
"$DIR/bin/context-budgets-build.sh" --compose >/dev/null || { echo "setup: cannot compose catalog/context-budgets.json"; exit 1; }
SRV="$DIR/tests/lib/onboarding-worker.bh-7949.mjs"
SCRIPT="$DIR/bin/onboard-run.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 \
  || { echo "SKIP: node, jq or curl missing"; exit 0; }
[ -f "$SCRIPT" ] || { echo "FAIL setup: $SCRIPT missing"; exit 1; }

H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/state" "$H/env" "$H/flags" "$H/catalog" "$H/prompts" "$T/stub"
: > "$H/env/global.env"
for L in bin/onboard-run.sh bin/jobs-client.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null 2>&1 || bad "setup: could not install $L"
done
cp "$DIR/catalog/lanes.json" "$H/catalog/lanes.json"
# lane-alert.sh: one line per call, the args as given.
cat > "$H/bin/lane-alert.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/alerts.log"
EOF
cat > "$H/bin/fleet-conf.sh" <<EOF
#!/bin/bash
echo "fleet-conf \$*" >> "$T/calls.log"; [ "\$2" = offset ] && echo "\${STUB_OFFSET-3}"
EOF
cat > "$H/bin/postmerge-qa.sh" <<EOF
#!/bin/bash
echo "postmerge-qa \$*" >> "$T/calls.log"; exit "\${STUB_PMQA_RC:-0}"
EOF
cat > "$H/bin/healthcheck.sh" <<EOF
#!/bin/bash
echo "healthcheck \$*" >> "$T/calls.log"; exit 0
EOF
cat > "$T/stub/gh" <<EOF
#!/bin/bash
echo "gh \$*" >> "$T/gh.log"; [ "\${STUB_GH_RC:-0}" = 0 ] || exit "\$STUB_GH_RC"; printf 'HTTP/1.1 200 OK\\r\\n\\r\\n[]\\n'
EOF
chmod +x "$H/bin/"*.sh "$T/stub/gh"
for p in acme-os acme-b acme-c acme-f acme-k acme-n; do echo "# $p" > "$H/prompts/$p.md"; done
export PATH="$T/stub:$PATH"
export HARNESS="$H" HARNESS_ENV_DIR="$H/env" BOX_NAME=hub
export HARNESS_SECRET=tok-fixture-bh7949
export JOBS_RETRY_SLEEP=0 JOBS_OVERLOAD_RETRIES=0 JOBS_TIMEOUT=10
export ONBOARD_STATIONS_LIB="$DIR/tests/lib/onboard-stations-stub.bh-7949.sh"
export OBS_CALLS="$T/obs.calls"

: > "$T/srv.log"; : > "$T/srv.port"; : > "$T/alerts.log"; : > "$T/calls.log"; : > "$T/gh.log"
node "$SRV" "$T/srv.log" > "$T/srv.port" 2> "$T/srv.err" &
SPID=$!
for _ in $(seq 1 200); do [ -s "$T/srv.port" ] && break; kill -0 "$SPID" 2>/dev/null || break; sleep 0.05; done
PORT=$(head -1 "$T/srv.port")
if [ -z "$PORT" ]; then
  wait "$SPID"; [ "$?" = 3 ] && { echo "SKIP: node:sqlite unavailable in this runtime"; exit 0; }
  echo "setup: worker did not start: $(cat "$T/srv.err")"; exit 1
fi
export JOBS_URL="http://127.0.0.1:$PORT"
trap 'kill "$SPID" 2>/dev/null; __scratch_exit_trap' EXIT

AUTH="authorization: Bearer $HARNESS_SECRET"
# create <key> <project> [extra-json] — a run through the contract's POST; prints its id.
create() {
  local body
  body=$(jq -nc --arg p "$2" --argjson x "${3:-{\}}" '{repo:("example-org/"+$p), project:$p, tracker:"github-issues", box:"shared"} + $x')
  curl -sS -X POST -H "$AUTH" -H "idempotency-key: $1" -H 'content-type: application/json' -d "$body" "$JOBS_URL/api/onboarding/runs" | jq -r .id
}
getrun() { curl -sS -H "$AUTH" "$JOBS_URL/api/onboarding/runs/$1"; }
hook() { curl -sS -X POST -d "$2" "$JOBS_URL/$1" >/dev/null; }
runstate() { getrun "$1" | jq -r .run.state; }
stepf() { getrun "$1" | jq -r --arg s "$2" --arg f "$3" '.steps[] | select(.station == $s) | .[$f] // "null"'; }
calls() { tr '\n' ' ' < "$OBS_CALLS" 2>/dev/null | sed 's/ $//'; }
# runner [args] — the installed script; rc returned, stdout+stderr in $T/out.
runner() { : > "$OBS_CALLS"; bash "$H/bin/onboard-run.sh" "$@" > "$T/out" 2>&1; }
LOG="$H/logs/onboard-run.log"
lastlog() { tail -1 "$LOG" 2>/dev/null | cut -d' ' -f2-; }
mark() { wc -l < "$T/srv.log"; }
since() { tail -n +"$(( $1 + 1 ))" "$T/srv.log"; }

# ============================================================================
echo "A: all stations pass, picked from the queue"
A=$(create key-fixture-a acme-os '{"prod":"https://acme.example.test","base":"main"}')
M0=$(mark)
runner; RC=$?
[ "$RC" = 0 ] && ok "A exit 0" || bad "A rc=$RC out=$(cat "$T/out")"
[ "$(calls)" = "register prompt label box clone" ] && ok "A stations called in ord" || bad "A calls: $(calls)"
WANT="claim register:running register:done prompt:running prompt:done label:running label:done box:running box:done clone:running clone:done smoke:running smoke:done ready:running ready:done"
GOT=$(since "$M0" | grep "/api/onboarding/runs/$A/beat 200" | awk '{print $4}' | tr '\n' ' ' | sed 's/ $//')
[ "$GOT" = "$WANT" ] && ok "A the worker saw claim then running/done per station in ord" || bad "A beats: $GOT"
J=$(getrun "$A")
[ "$(jq -r .run.state <<<"$J")" = "done" ] && [ "$(jq -r .run.finished_at <<<"$J")" != null ] && ok "A GET shows the run done" || bad "A run: $(jq -c .run <<<"$J")"
[ "$(jq '[.steps[] | select(.state == "done" and .started_at <= .finished_at)] | length' <<<"$J")" = 7 ] && ok "A 7 steps done, started_at <= finished_at" || bad "A steps: $(jq -c '[.steps[]|.state]' <<<"$J")"
grep -q "^[0-9TZ:-]* done $A acme-os$" "$LOG" && ok "A log has 'done $A acme-os'" || bad "A log: $(cat "$LOG")"
EX=$(jq -r '.steps[] | select(.station == "register") | .log_excerpt' <<<"$J")
[ "$EX" = "obs_register project=acme-os slug=example-org/acme-os repo=example-org/acme-os box=box-small prefix=AO base=main prod=https://acme.example.test" ] \
  && ok "A the inputs became the station globals (shared box, derived prefix)" || bad "A excerpt: $EX"
grep -q "healthcheck acme-os" "$T/calls.log" && grep -q "postmerge-qa acme-os --dry-run" "$T/calls.log" && grep -q "gh api -i -X GET repos/example-org/acme-os/issues -f state=open -F per_page=100 -F page=1" "$T/gh.log" \
  && ok "A smoke ran its checks" || bad "A smoke calls: $(cat "$T/calls.log" "$T/gh.log")"
grep -q 'step '"$A"' smoke done rc=0 secs=[0-9]*$' "$LOG" && ok "A step log line" || bad "A step lines: $(grep step "$LOG")"

echo "D: idle"
M0=$(mark)
runner; RC=$?
[ "$RC" = 0 ] && [ "$(lastlog)" = idle ] && ok "D exit 0, idle" || bad "D rc=$RC last=$(lastlog)"
grep -q /beat <<<"$(since "$M0")" && bad "D a beat was sent" || ok "D no beat"
[ ! -s "$OBS_CALLS" ] && ok "D no station" || bad "D calls: $(calls)"

echo "B: label fails with HTTP 403"
B=$(create key-fixture-b acme-b)
OBS_FAIL=label OBS_FAIL_LINE='HTTP 403: Resource not accessible by integration (POST /repos/x/labels)' runner "$B"; RC=$?
[ "$RC" = 1 ] && ok "B exit 1" || bad "B rc=$RC out=$(cat "$T/out")"
[ "$(calls)" = "register prompt label" ] && ok "B box never called" || bad "B calls: $(calls)"
J=$(getrun "$B")
[ "$(jq -r .run.state <<<"$J")/$(jq -r .run.station <<<"$J")" = failed/label ] && ok "B run failed at label" || bad "B run: $(jq -c .run <<<"$J")"
[ "$(stepf "$B" label state)/$(stepf "$B" label error_code)" = failed/app_no_issues_write ] && ok "B label failed app_no_issues_write" || bad "B label: $(stepf "$B" label state) $(stepf "$B" label error_code)"
grep -q 'Resource not accessible by integration (POST /repos/x/labels)' <<<"$(stepf "$B" label log_excerpt)" && ok "B excerpt holds the stub's stderr" || bad "B excerpt: $(stepf "$B" label log_excerpt)"
[ "$(jq -r '[.steps[] | select(.ord > 3) | .state] | join(" ")' <<<"$J")" = "skipped skipped skipped skipped" ] && ok "B box..ready skipped" || bad "B later: $(jq -c '[.steps[]|.state]' <<<"$J")"
[ "$(lastlog)" = "failed $B at label code=app_no_issues_write" ] && ok "B log line" || bad "B last=$(lastlog)"

echo "C: retry of B starts at label"
hook __retry "{\"id\":\"$B\"}"
runner "$B"; RC=$?
[ "$RC" = 0 ] && [ "$(calls)" = "label box clone" ] && ok "C exit 0, only label box clone" || bad "C rc=$RC calls: $(calls) out=$(cat "$T/out")"
[ "$(runstate "$B")" = "done" ] && [ "$(stepf "$B" label retries)" = 1 ] && ok "C run done, label retried once" || bad "C state=$(runstate "$B") retries=$(stepf "$B" label retries)"

echo "E: claim lost"
E=$(create key-fixture-e acme-e)
curl -sS -X POST -H "$AUTH" -d '{"claim":true}' "$JOBS_URL/api/onboarding/runs/$E/beat" > /dev/null
runner "$E"; RC=$?
[ "$RC" = 0 ] && [ "$(lastlog)" = "claim-lost $E" ] && [ ! -s "$OBS_CALLS" ] && ok "E exit 0, claim-lost, no station" || bad "E rc=$RC last=$(lastlog) calls=$(calls)"
hook __cancel "{\"id\":\"$E\"}"

echo "F: cancel mid-run at box"
F=$(create key-fixture-f acme-f)
OBS_CANCEL_AT=box runner "$F"; RC=$?
[ "$RC" = 0 ] && ok "F exit 0" || bad "F rc=$RC out=$(cat "$T/out")"
[ "$(runstate "$F")" = cancelled ] && ok "F run cancelled" || bad "F state=$(runstate "$F")"
[ "$(calls)" = "register prompt label box" ] && ok "F clone never called" || bad "F calls: $(calls)"
[ "$(stepf "$F" box state)" != "done" ] && ok "F box not done ($(stepf "$F" box state))" || bad "F box done"
[ "$(lastlog)" = "cancelled $F at box" ] && ok "F log line" || bad "F last=$(lastlog)"

echo "G: the worker is down"
CLOSED=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
: > "$T/alerts.log"; : > "$H/logs/jobs-client.log"
JOBS_URL="http://127.0.0.1:$CLOSED" runner; RC=$?
[ "$RC" = 2 ] && ok "G exit 2" || bad "G rc=$RC out=$(cat "$T/out")"
[ "$(grep -c . "$T/alerts.log")" = 1 ] && grep -q -- '--id onboard-run:unreachable --severity warn onboard-run' "$T/alerts.log" \
  && ok "G exactly one alert, onboard-run:unreachable" || bad "G alerts: $(cat "$T/alerts.log")"
grep -q "after 3 attempt(s)" "$H/logs/jobs-client.log" && ok "G 3 attempts" || bad "G client log: $(cat "$H/logs/jobs-client.log")"
[ ! -s "$OBS_CALLS" ] && ok "G no station" || bad "G calls: $(calls)"
: > "$H/logs/jobs-client.log"
JOBS_URL="http://127.0.0.1:$CLOSED" ONBOARD_RUN_TRIES=2 runner; RC=$?
[ "$RC" = 2 ] && grep -q "after 2 attempt(s)" "$H/logs/jobs-client.log" && ok "G ONBOARD_RUN_TRIES=2 -> 2 attempts" || bad "G tries=2 rc=$RC $(cat "$H/logs/jobs-client.log")"

echo "H: lane off"
touch "$H/flags/lane-off-onboard-run"
M0=$(mark)
runner; RC=$?
[ "$RC" = 0 ] && [ "$(mark)" = "$M0" ] && ok "H exit 0, 0 requests" || bad "H rc=$RC requests: $(since "$M0")"
rm -f "$H/flags/lane-off-onboard-run"

echo "I: not configured"
: > "$T/alerts.log"
M0=$(mark)
HARNESS_SECRET='' runner; RC=$?
[ "$RC" = 2 ] && ok "I exit 2" || bad "I rc=$RC out=$(cat "$T/out")"
grep -q /api/onboarding <<<"$(since "$M0")" && bad "I a request was sent: $(since "$M0")" || ok "I 0 onboarding requests"
[ "$(grep -c . "$T/alerts.log")" = 1 ] && grep -q -- '--id onboard-run:not-configured' "$T/alerts.log" && ok "I one not-configured alert" || bad "I alerts: $(cat "$T/alerts.log")"
grep -q "not-configured (no-secret)" "$LOG" && ok "I log line" || bad "I last=$(lastlog)"

echo "K: obs_label is not defined"
K=$(create key-fixture-k acme-k)
OBS_UNDEF=label runner "$K"; RC=$?
[ "$RC" = 1 ] && [ "$(stepf "$K" label state)/$(stepf "$K" label error_code)" = failed/station_failed ] \
  && ok "K label failed station_failed" || bad "K rc=$RC label=$(stepf "$K" label state)/$(stepf "$K" label error_code)"
grep -q 'obs_label is not defined' <<<"$(stepf "$K" label log_excerpt)" && ok "K excerpt names the missing function" || bad "K excerpt: $(stepf "$K" label log_excerpt)"
grep -q "/api/onboarding/runs/$K/beat 200 label:done" "$T/srv.log" && bad "K label was beaten done" || ok "K label never done"

echo "L: obs_smoke"
smoke() { ( export ONBOARD_RUN_LIB_ONLY=1 ROOT="$H" PROJECT="$1" SLUG="example-org/$1" PROD="$2"; . "$H/bin/onboard-run.sh"; obs_smoke ) > "$T/smoke.out" 2>&1; }
: > "$T/calls.log"
smoke acme-os https://acme.example.test; RC=$?
[ "$RC" = 0 ] && grep -q "healthcheck acme-os" "$T/calls.log" && ok "L all pass with prod: rc 0, healthcheck called" || bad "L rc=$RC $(cat "$T/smoke.out")"
[ "$(grep -c '^smoke ok' "$T/smoke.out")" = 5 ] && ok "L one line per check" || bad "L out: $(cat "$T/smoke.out")"
: > "$T/calls.log"
smoke acme-os -; RC=$?
[ "$RC" = 0 ] && ! grep -q healthcheck "$T/calls.log" && ok "L no prod: healthcheck not called" || bad "L no-prod rc=$RC $(cat "$T/calls.log")"
smoke acme-none -; RC=$?
[ "$RC" = 1 ] && grep -q 'smoke FAIL: prompts/acme-none.md is missing' "$T/smoke.out" && grep -q "postmerge-qa acme-none --dry-run" "$T/calls.log" \
  && ok "L no prompt file: rc 1, the other checks still run" || bad "L no-prompt rc=$RC $(cat "$T/smoke.out")"
STUB_GH_RC=1 smoke acme-os -; RC=$?
[ "$RC" = 1 ] && grep -q 'smoke FAIL: REST issue list example-org/acme-os' "$T/smoke.out" && ok "L gh rc 1: rc 1" || bad "L gh rc=$RC $(cat "$T/smoke.out")"
STUB_OFFSET=x smoke acme-os -; RC=$?
[ "$RC" = 1 ] && ok "L a non-integer offset: rc 1" || bad "L offset rc=$RC"
STUB_PMQA_RC=1 smoke acme-os -; RC=$?
[ "$RC" = 1 ] && ok "L postmerge-qa rc 1: rc 1" || bad "L pmqa rc=$RC"

echo "M: obs_error_code"
code() { ( export ONBOARD_RUN_LIB_ONLY=1; . "$H/bin/onboard-run.sh"; printf '%b' "$1" | obs_error_code ); }
while IFS='|' read -r want text; do
  [ -n "$want" ] || continue
  got=$(code "$text")
  [ "$got" = "$want" ] && ok "M [$text] -> $want" || bad "M [$text] -> $got, want $want"
done <<'EOF'
app_no_issues_write|HTTP 403: Resource not accessible by integration (POST .../labels)
app_no_issues_write|gh: http 403 creating issues for the repo
app_no_issues_write|Resource not accessible by integration (createLabel)
box_unreachable|ssh: Could not resolve hostname box-x: Name or service not known
registry_token_missing|FATAL: REGISTRY_SOURCE=db and REGISTRY_ADMIN_TOKEN is unset — cannot write
prompt_push_rejected|! [rejected] main -> main (fetch first)
prompt_push_rejected|error: failed to push some refs to 'github.com:o/r.git'
repo_not_found|GraphQL: Could not resolve to a Repository with the name 'o/r'
repo_not_found|remote: Repository not found.
station_failed|label "ai-build" already exists
station_failed|API rate limit exceeded for installation ID 123
station_failed|ssh: connect to host 192.0.2.5 port 22: Connection timed out
station_failed|HTTP 403: Forbidden (GET /user)
station_failed|resolved hostname ok
station_failed|
box_unreachable|✓ Label created\nssh: Could not resolve hostname x
station_failed|HTTP 403 forbidden\nlabel list ok
EOF

echo "N: tracker=board"
N=$(create key-fixture-n acme-n '{"tracker":"board"}')
runner "$N"; RC=$?
[ "$RC" = 1 ] && [ "$(stepf "$N" tracker state)/$(stepf "$N" tracker error_code)" = failed/tracker_not_built ] \
  && ok "N tracker failed tracker_not_built" || bad "N rc=$RC tracker=$(stepf "$N" tracker state)/$(stepf "$N" tracker error_code)"
[ "$(runstate "$N")" = failed ] && [ "$(getrun "$N" | jq -r .run.station)" = tracker ] && [ "$(calls)" = "register prompt" ] \
  && ok "N run failed at tracker, label never called" || bad "N state=$(runstate "$N") calls=$(calls)"

echo "P: bad arguments"
M0=$(mark)
for a in ob_XYZ "ob_0123456789abcdef012" "x y"; do
  # shellcheck disable=SC2086
  runner $a; RC=$?
  [ "$RC" = 64 ] && grep -q '^usage: onboard-run.sh' "$T/out" && ok "P [$a] exit 64" || bad "P [$a] rc=$RC $(cat "$T/out")"
done
grep -q /api/onboarding <<<"$(since "$M0")" && bad "P a request was sent" || ok "P no onboarding request"

echo "J: a stale running run"
J1=$(create key-fixture-j1 acme-j1); J2=$(create key-fixture-j2 acme-j2)
for id in "$J1" "$J2"; do curl -sS -X POST -H "$AUTH" -d '{"claim":true}' "$JOBS_URL/api/onboarding/runs/$id/beat" > /dev/null; done
# The clock is pinned: ONBOARD_RUN_NOW is 2026-10-20T16:00:00Z.
hook __age "{\"id\":\"$J1\",\"at\":\"2026-10-20T15:29:00Z\"}"
hook __age "{\"id\":\"$J2\",\"at\":\"2026-10-20T15:31:00Z\"}"
: > "$T/alerts.log"
ONBOARD_RUN_NOW=1792512000 runner; R1=$?; ONBOARD_RUN_NOW=1792512000 runner; R2=$?
DAY=2026-10-20
[ "$R1/$R2" = 0/0 ] && ok "J two ticks exit 0" || bad "J rc=$R1/$R2"
[ "$(grep -c -- "--id onboard-run:stale_run:$J1:$DAY --severity warn onboard-run Onboarding run $J1 (acme-j1) has been running at claim since 2026-10-20T15:29:00Z with no beat." "$T/alerts.log")" = 2 ] \
  && ok "J the same stale_run id on both ticks" || bad "J alerts: $(cat "$T/alerts.log")"
grep -q "$J2" "$T/alerts.log" && bad "J a 29-minute run was called stale" || ok "J 29 minutes -> no stale call"
[ "$(grep -c "stale $J1" "$LOG")" = 2 ] && ok "J log has 'stale $J1' per tick" || bad "J log: $(grep stale "$LOG")"

echo "onboard-run.bh-7934: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
