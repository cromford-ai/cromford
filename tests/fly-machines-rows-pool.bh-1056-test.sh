#!/bin/bash
# tests/fly-machines-rows-pool.bh-1056-test.sh — bin/fly-pool.sh writes Fly
# machine registry rows when fly_machines_rows is on, fail-open otherwise.
#
# Drives the REAL bin/fly-pool.sh against a scratch $HARNESS with stubbed
# flyctl, curl, sleep and timeout. Assertions are on request logs, artifact
# files and fly-pool.log lines.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
unset POOL_AUTOSCALE POOL_CAP_MAX POOL_STOPPED_TTL_S POOL_SWEEP_MAX_DESTROY
NOW=$(date +%s)
OLD=$(date -u -d "@$((NOW - 1000))" +%Y-%m-%dT%H:%M:%SZ)
MID1="00000000000001"
MID2="00000000000002"
MID3="00000000000003"
MID4="00000000000004"
IMAGE="registry.fly.io/pool-tproj:deadbeef"

H="$T/h"
mkdir -p "$H/bin" "$H/bin/lib" "$H/logs" "$H/flags" "$H/locks" "$H/env" \
         "$H/state/fly" "$H/state/fly-pool/tproj" "$H/state/build-queue/tproj" \
         "$H/builds" "$T/fakebin"
cp "$DIR/bin/pool-cap.sh" "$DIR/bin/result-prefix-ok.sh" "$H/bin/"
cp "$DIR/bin/lib/env-path.sh" "$H/bin/lib/env-path.sh"
cp "$DIR/bin/jobs-client.sh" "$H/bin/jobs-client.sh"
mkdir -p "$H/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
: > "$H/env/fly.env"
printf 'HARNESS_SECRET=test-secret\nJOBS_URL=https://jobs.invalid\n' > "$H/env/global.env"
printf '10\n' > "$H/flags/fly-pool-tproj"
printf 'pool-tproj\n' > "$H/flags/fly-pool-app-tproj"
printf '{"app":"builder-tproj"}\n' > "$H/state/fly/tproj.json"
printf '%s\n' "$IMAGE" > "$H/state/fly/tproj.image"
printf 'testbox\n' > "$H/state/box-name"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
cat > "$H/bin/fly-envbundle.sh" <<'BUNDLE'
#!/bin/bash
P="$1"; D="$2"
mkdir -p "$D"
printf 'CONSOLE_URL=https://console.test\nCLAUDE_CODE_OAUTH_TOKEN=project-6\nGH_TOKEN=gh-fixture\nRUNNER_EXECUTE=claude\n' > "$D/global.env"
printf 'BOARD_TOKEN=boardtok\n' > "$D/$P.env"
chmod 600 "$D/global.env" "$D/$P.env"
BUNDLE
chmod +x "$H/bin/fly-envbundle.sh"

printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/fakebin/timeout"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/sleep"

cat > "$T/fakebin/fly" <<'STUB'
#!/bin/bash
[ -n "${FLY_CALLS:-}" ] && printf '%s\n' "$*" >> "$FLY_CALLS"
case "$*" in
  *"agent start"*) exit 0 ;;
  *"machines list"*)
    if [ -f "$FIX/list-rc1" ]; then echo "boom" >&2; exit 1; fi
    if [ -f "$FIX/list-junk" ]; then echo "not a json array"; exit 0; fi
    cat "$FIX/listing.json" 2>/dev/null || echo '[]'
    ;;
  *"machine status"*)
    MID=""; for a in "$@"; do case "$a" in -*|status|machine) ;; *) MID="$a"; break ;; esac; done
    cat "$FIX/status.${MID:-none}" 2>/dev/null
    ;;
  *"machine destroy"*)
    MID=""; for a in "$@"; do case "$a" in -*|destroy|machine) ;; *) MID="$a"; break ;; esac; done
    if grep -qx "$MID" "$FIX/destroy-fail" 2>/dev/null; then
      echo "Error: could not destroy machine $MID: rate limited by the Fly API" >&2; exit 1
    fi
    if grep -qx "$MID" "$FIX/destroy-gone" 2>/dev/null; then
      echo "Error: machine $MID was not found in app pool-tproj" >&2; exit 1
    fi
    ;;
  *"machine run"*)
    n=$(cat "$FIX/mid-counter" 2>/dev/null || echo 100)
    printf 'Machine ID: %014d\n' "$n"
    echo $((n+1)) > "$FIX/mid-counter"
    ;;
  *"ssh console"*)
    # The RESULT probe is the only console call that answers anything. Matching
    # on `head` as well as the path keeps the reuse path's `rm -f
    # /run/harness/RESULT` and the full-RESULT `base64 -w0` silent, which is
    # what a real machine does once the runner's RESULT has been cleared.
    case "$*" in
      *head*/run/harness/RESULT*) cat "$FIX/result.txt" 2>/dev/null ;;
      *) : ;;
    esac
    ;;
  *"ssh"*) exit 0 ;;
  *"sftp"*) exit 0 ;;
  *) exit 0 ;;
esac
exit 0
STUB

cat > "$T/fakebin/curl" <<'CURL'
#!/bin/bash
URL="${!#}"; BODY=""; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in
    -X) METHOD="$2"; shift 2;;
    --data-binary) BODY="$2"; case "$BODY" in @*) BODY=$(cat "${BODY#@}");; esac; shift 2;;
    *) shift;;
  esac
done
if [ "${CURL_MODE:-ok}" = "down" ]; then exit 7; fi
# FILE FIRST IS PINNED HERE, AT REQUEST TIME. The whole contract of this slice
# is that the pool writes its own json and THEN tells the worker about it, so
# the stub records whether the machine json named in this very request exists
# on disk at the moment the request is made — not afterwards, when a passing
# assertion would prove nothing about the order.
RMID=""
case "$METHOD $URL" in
  "PUT "*/api/machines)     RMID=$(printf '%s' "$BODY" | sed -n 's/.*"machine_id":"\([^"]*\)".*/\1/p') ;;
  "PATCH "*/api/machines/*) RMID="${URL##*/}" ;;
esac
RFILE="-"
if [ -n "$RMID" ]; then
  if [ -f "${POOLDIR:-/nonexistent}/$RMID.json" ]; then RFILE=yes; else RFILE=no; fi
fi
# file= goes BEFORE the body: a destroy_failed detail carries flyctl's error
# text, spaces and all, so only a fixed-position field can be read back.
[ -n "${REQ_SINK:-}" ] && printf '%s %s file=%s %s\n' "$METHOD" "$URL" "$RFILE" "$BODY" >> "$REQ_SINK"
case "$METHOD $URL" in
  "GET "*/api/machines?project=tproj*)
    if [ -s "$FIX/live-rows.json" ]; then cat "$FIX/live-rows.json"; else printf '{"machines":[]}'; fi
    printf '\n200\n'
    ;;
  "PUT "*/api/machines)
    printf '{"ok":true}\n200\n'
    ;;
  "PUT "*/api/machines/observe)
    printf '{"ok":true,"received":0}\n200\n'
    ;;
  "PATCH "*/api/machines/*)
    printf '{"ok":true}\n200\n'
    ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
CURL
chmod +x "$H/bin/pool-cap.sh" "$H/bin/result-prefix-ok.sh" "$H/bin/lib/env-path.sh" "$H/bin/jobs-client.sh" "$H/bin/fly-envbundle.sh" "$T/fakebin"/*

q() { jq -nc --arg k "$1" --arg t "$2" '{key:$k,ticket_id:$t,attempt:0,deferrals:0,deaths:0}'; }
track() { jq -nc --arg m "$1" --arg k "$2" --arg t "$3" '{machine:$m,key:$k,ticket_id:$t,attempt:0,deferrals:0,deaths:0}' > "$H/state/fly-pool/tproj/$1.json"; }
mklist() { printf '%s\n' "$1" > "$T/listing.json"; }
reset() {
  rm -f "$H/state/fly-pool/tproj"/*.json "$H/state/fly-pool/tproj/.sweep.json"
  rm -f "$H/state/fly-pool-listing/tproj.json"   # BH-9407 saved list
  rm -f "$H/state/build-queue/tproj"/*.json "$H/state/build-queue/tproj"/*.json.bad "$H/flags"/alerted-pool-*
  rm -f "$T/listing.json" "$T/live-rows.json" "$T/destroy-fail" "$T/destroy-gone"
  rm -f "$T/list-rc1" "$T/list-junk" "$T/status".* "$T/mid-counter" "$T/result.txt"
  rm -f "$T/req.log" "$T/tick.rc" "$T/fly-calls.log"
  : > "$H/logs/fly-pool.log"; : > "$H/logs/ALERTS.log"; : > "$H/logs/jobs-client.log"; : > "$T/req.log"
  printf '100\n' > "$T/mid-counter"
}
tick() {
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" FLY_BIN_DIR="$T/fakebin" \
           FLY_API_TOKEN_TPROJ=tok FLY_CALLS="$T/fly-calls.log" FIX="$T" \
           BOX_NAME=testbox REQ_SINK="$T/req.log" POOL_STOPPED_TTL_S=600 \
           POOL_SWEEP_MAX_DESTROY=25 POOLDIR="$H/state/fly-pool/tproj" \
           POOL_LIST_RETRY_BACKOFF_S="0 0 0"   # BH-9407: retries without the waits
    env "$@" bash "$DIR/bin/fly-pool.sh" tproj >/dev/null 2>&1
    echo $? > "$T/tick.rc" )
}
reqs() { grep '/api/machines' "$T/req.log" 2>/dev/null | wc -l | tr -d ' '; }
observes() { grep 'PUT .*/api/machines/observe ' "$T/req.log" 2>/dev/null | wc -l | tr -d ' '; }
patches() { grep 'PATCH .*/api/machines/' "$T/req.log" 2>/dev/null | wc -l | tr -d ' '; }
puts() { grep 'PUT .*/api/machines ' "$T/req.log" 2>/dev/null | wc -l | tr -d ' '; }
gets() { grep 'GET .*/api/machines' "$T/req.log" 2>/dev/null | wc -l | tr -d ' '; }
# `METHOD URL file=X BODY` — the body is field 4 onward, because a
# destroy_failed detail has spaces in it.
body_of() { printf '%s' "$1" | cut -d' ' -f4-; }
file_of() { printf '%s' "$1" | cut -d' ' -f3 | sed 's/^file=//'; }
observe_line() { grep -m1 'PUT .*/api/machines/observe ' "$T/req.log" 2>/dev/null; }
patch_line() { grep -m1 "PATCH .*/api/machines/$1 " "$T/req.log" 2>/dev/null; }
put_line() { grep "PUT .*/api/machines " "$T/req.log" 2>/dev/null | sed -n "${1}p"; }
observe_body() { body_of "$(observe_line)"; }
patch_body() { body_of "$(patch_line "$1")"; }
put_body() { body_of "$(put_line "$1")"; }

# §2 flag off: zero machine-row API requests; tick still runs as today.
reset
q "SP-1" "2" > "$H/state/build-queue/tproj/SP-1.json"
tick FLY_MACHINES_ROWS=off
[ "$(cat "$T/tick.rc")" = "0" ] && ok || bad "§2 tick exit rc=$(cat "$T/tick.rc")"
[ "$(reqs)" -eq 0 ] && ok || bad "§2 expected zero /api/machines* requests, got $(reqs): $(cat "$T/req.log")"

# §3 flag on, spawn: two machine jsons and two PUT /api/machines with role pool.
reset
q "SP-1" "2" > "$H/state/build-queue/tproj/SP-1.json"
q "SP-2" "3" > "$H/state/build-queue/tproj/SP-2.json"
tick FLY_MACHINES_ROWS=on
[ "$(cat "$T/tick.rc")" = "0" ] && ok || bad "§3 tick exit rc=$(cat "$T/tick.rc")"
NP="$(puts)"
[ "$NP" -eq 2 ] && ok || bad "§3 expected 2 PUT /api/machines, got $NP: $(cat "$T/req.log")"
NO="$(observes)"
[ "$NO" -eq 1 ] && ok || bad "§3 expected 1 observe, got $NO"
for i in 1 2; do
  KEY=$(jq -r '.key' <<<"$(put_body $i)")
  ROLE=$(jq -r '.role' <<<"$(put_body $i)")
  [ "$ROLE" = "pool" ] && ok || bad "§3 put $i role=$ROLE"
  [ "$(jq -r '.state' <<<"$(put_body $i)")" = "spawned" ] && ok || bad "§3 put $i state=$(jq -r '.state' <<<"$(put_body $i)")"
  # FILE FIRST: the stub recorded this at request time, so a `yes` here is the
  # ordering itself, not a file that happened to exist by the end of the tick.
  [ "$(file_of "$(put_line $i)")" = "yes" ] && ok || bad "§3 put $i was sent before its machine json existed (file=$(file_of "$(put_line $i)"))"
  [ -f "$H/state/fly-pool/tproj/$(jq -r '.machine_id' <<<"$(put_body $i)").json" ] && ok || bad "§3 put $i missing local file for key=$KEY"
done

# §3b flag on, REUSE: a tracked machine with a canonical RESULT and another job
# already queued is handed that job instead of being destroyed, and the registry
# gets a state=started row for the NEW key. This is the path that has to run
# through the real script to mean anything: the reuse write lives inside
# next_job_or_destroy, which the function-alone suites can never reach past the
# `command -v machines_row` guard.
reset
: > "$H/flags/pool-halt-tproj"   # keep the tick's spawn half out of these counts
track "$MID1" "RE-1" "4"
mklist "[{\"id\":\"$MID1\",\"state\":\"started\",\"updated_at\":\"$OLD\"}]"
printf 'BUILD_DEFERRED: pool slot busy\n' > "$T/result.txt"
q "RE-2" "5" > "$H/state/build-queue/tproj/RE-2.json"
tick FLY_MACHINES_ROWS=on
[ "$(cat "$T/tick.rc")" = "0" ] && ok || bad "§3b reuse tick exit rc=$(cat "$T/tick.rc")"
grep -q "reused $MID1 for RE-2 (was RE-1)" "$H/logs/fly-pool.log" && ok \
  || bad "§3b the reuse must complete: $(cat "$H/logs/fly-pool.log")"
[ "$(jq -r '.key' "$H/state/fly-pool/tproj/$MID1.json" 2>/dev/null)" = "RE-2" ] && ok \
  || bad "§3b machine json must carry the reused key, got $(jq -r '.key // "none"' "$H/state/fly-pool/tproj/$MID1.json" 2>/dev/null)"
[ ! -f "$H/state/build-queue/tproj/RE-2.json" ] && ok || bad "§3b the handed job must leave the queue"
RL=$(grep "PUT .*/api/machines " "$T/req.log" 2>/dev/null | grep -m1 '"state":"started"')
[ -n "$RL" ] && ok || bad "§3b expected a PUT /api/machines with state started: $(cat "$T/req.log")"
[ "$(jq -r '.machine_id' <<<"$(body_of "$RL")")" = "$MID1" ] && ok || bad "§3b reuse row machine_id=$(jq -r '.machine_id' <<<"$(body_of "$RL")")"
[ "$(jq -r '.key' <<<"$(body_of "$RL")")" = "RE-2" ] && ok || bad "§3b reuse row key=$(jq -r '.key' <<<"$(body_of "$RL")")"
[ "$(jq -r '.role' <<<"$(body_of "$RL")")" = "pool" ] && ok || bad "§3b reuse row role=$(jq -r '.role' <<<"$(body_of "$RL")")"
[ "$(file_of "$RL")" = "yes" ] && ok || bad "§3b the machine json must exist when the reuse row is sent (file=$(file_of "$RL"))"
# IMAGE belongs to the SPAWN half of the tick and is unassigned here — naming it
# killed the whole tick under `set -u`, after the queue file was consumed.
[ "$(jq -r 'has("image")' <<<"$(body_of "$RL")")" = "false" ] && ok || bad "§3b reuse row must carry no image field: $(body_of "$RL")"
[ "$(patches)" -eq 0 ] && ok || bad "§3b a reused machine must not be closed: $(cat "$T/req.log")"
rm -f "$H/flags/pool-halt-tproj"

# §3c the same reuse with the flag OFF: identical file outcome, zero requests.
# This is the "byte-for-byte as today" claim, checked rather than asserted.
reset
: > "$H/flags/pool-halt-tproj"
track "$MID1" "RE-1" "4"
mklist "[{\"id\":\"$MID1\",\"state\":\"started\",\"updated_at\":\"$OLD\"}]"
printf 'BUILD_DEFERRED: pool slot busy\n' > "$T/result.txt"
q "RE-2" "5" > "$H/state/build-queue/tproj/RE-2.json"
tick FLY_MACHINES_ROWS=off
[ "$(cat "$T/tick.rc")" = "0" ] && ok || bad "§3c flag-off reuse tick exit rc=$(cat "$T/tick.rc")"
grep -q "reused $MID1 for RE-2 (was RE-1)" "$H/logs/fly-pool.log" && ok \
  || bad "§3c the reuse must complete with the flag off: $(cat "$H/logs/fly-pool.log")"
[ "$(jq -r '.key' "$H/state/fly-pool/tproj/$MID1.json" 2>/dev/null)" = "RE-2" ] && ok \
  || bad "§3c machine json must carry the reused key with the flag off"
[ "$(reqs)" -eq 0 ] && ok || bad "§3c expected zero /api/machines* requests, got $(reqs): $(cat "$T/req.log")"
rm -f "$H/flags/pool-halt-tproj"

# §4 flag on, tracked m1 absent from listing: original file removed, PATCH gone,
# exactly one observe whose machines list lacks m1, requeue recorded.
reset
track "$MID1" "RE-1" "4"
mklist "[{\"id\":\"smoke\",\"state\":\"started\",\"updated_at\":\"$OLD\"}]"
printf '%s\n' "$MID1" > "$T/destroy-gone"
tick FLY_MACHINES_ROWS=on
[ "$(cat "$T/tick.rc")" = "0" ] && ok || bad "§4 tick exit rc=$(cat "$T/tick.rc")"
[ "$(observes)" -eq 1 ] && ok || bad "§4 expected exactly one observe, got $(observes)"
! grep -q "\"$MID1\"" <<<"$(observe_body)" && ok || bad "§4 observe list must not include $MID1"
[ "$(patches)" -ge 1 ] && ok || bad "§4 expected at least one PATCH, got $(patches)"
[ "$(jq -r '.state' <<<"$(patch_body $MID1)")" = "gone" ] && ok || bad "§4 PATCH state=$(jq -r '.state' <<<"$(patch_body $MID1)")"
[ ! -f "$H/state/fly-pool/tproj/$MID1.json" ] && ok || bad "§4 original tracking file must be removed"
grep -q "POST .*/api/queue.*RE-1" "$T/req.log" && ok || bad "§4 requeue for RE-1 not recorded in req.log: $(cat "$T/req.log")"

# §5 flag on, listing [m1 started] with empty RESULT: observe sent, NO patch, file kept.
reset
track "$MID1" "RE-1" "4"
mklist "[{\"id\":\"$MID1\",\"state\":\"started\",\"updated_at\":\"$OLD\"}]"
tick FLY_MACHINES_ROWS=on
[ "$(cat "$T/tick.rc")" = "0" ] && ok || bad "§5 tick exit rc=$(cat "$T/tick.rc")"
[ "$(observes)" -eq 1 ] && ok || bad "§5 expected one observe, got $(observes)"
[ "$(patches)" -eq 0 ] && ok || bad "§5 expected zero PATCH, got $(patches): $(cat "$T/req.log")"
[ -f "$H/state/fly-pool/tproj/$MID1.json" ] && ok || bad "§5 tracking file must be kept"
[ "$(ls -1 "$H/state/build-queue/tproj"/*.json 2>/dev/null | wc -l | tr -d ' ')" = "0" ] && ok || bad "§5 job must not be requeued"

reset
# §6 worker/transport down: tick exit 0, file lifecycle identical to §4 minus
# requests, one "machines row:" log line.
# Halt spawns for §6 so the requeued job stays on disk for the assertion.
: > "$H/flags/pool-halt-tproj"
track "$MID1" "RE-1" "4"
mklist "[{\"id\":\"smoke\",\"state\":\"started\",\"updated_at\":\"$OLD\"}]"
printf '%s\n' "$MID1" > "$T/destroy-gone"
tick FLY_MACHINES_ROWS=on CURL_MODE=down
[ "$(cat "$T/tick.rc")" = "0" ] && ok || bad "§6 tick exit rc=$(cat "$T/tick.rc")"
[ "$(reqs)" -eq 0 ] && ok || bad "§6 expected zero /api/machines* requests, got $(reqs): $(cat "$T/req.log")"
[ ! -f "$H/state/fly-pool/tproj/$MID1.json" ] && ok || bad "§6 tracking file must be removed"
[ -f "$H/state/build-queue/tproj/RE-1.json" ] && ok || bad "§6 job must be requeued"
grep -q 'machines row:' "$H/logs/fly-pool.log" && ok || bad "§6 expected a 'machines row:' log line: $(cat "$H/logs/fly-pool.log")"
[ "$(grep -c 'machines row:' "$H/logs/fly-pool.log")" -eq 1 ] && ok || bad "§6 expected exactly one 'machines row:' line, got $(grep -c 'machines row:' "$H/logs/fly-pool.log")"
rm -f "$H/flags/pool-halt-tproj"

# §6b listing rc 1 / junk / empty-beside-tracked: NO observe in all three cases.
reset
track "$MID1" "RE-1" "4"
touch "$T/list-rc1"
tick FLY_MACHINES_ROWS=on
[ "$(observes)" -eq 0 ] && ok || bad "§6b rc1 expected zero observe, got $(observes): $(cat "$T/req.log")"
reset
track "$MID1" "RE-1" "4"
touch "$T/list-junk"
tick FLY_MACHINES_ROWS=on
[ "$(observes)" -eq 0 ] && ok || bad "§6b junk expected zero observe, got $(observes): $(cat "$T/req.log")"
reset
track "$MID1" "RE-1" "4"
mklist "[]"
tick FLY_MACHINES_ROWS=on
[ "$(observes)" -eq 0 ] && ok || bad "§6b empty-beside-tracked expected zero observe, got $(observes): $(cat "$T/req.log")"

# §6c (BH-9407) listing rc 1 with a fresh saved list: the sweep destroys from it,
# and still NO observe: a saved list is never sent as this tick's listing.
reset
track "$MID1" "RE-1" "4"
mkdir -p "$H/state/fly-pool-listing"
jq -nc --arg u "$OLD" \
  '[{id:"m6csaved",state:"stopped",region:"ewr",created_at:$u,updated_at:$u}]' \
  > "$H/state/fly-pool-listing/tproj.json"   # stopped 1000 s: past the 600 s TTL
touch "$T/list-rc1"
tick FLY_MACHINES_ROWS=on
[ "$(observes)" -eq 0 ] && ok || bad "§6c saved list expected zero observe, got $(observes): $(cat "$T/req.log")"
grep -q 'machine destroy m6csaved' "$T/fly-calls.log" && ok \
  || bad "§6c the saved list must drive the sweep: $(cat "$T/fly-calls.log")"

# §7 advisory: live row for TK-1 with no file -> tick still spawns and logs it;
# row absent -> no line; flag off -> no GET /api/machines.
reset
q "TK-1" "7" > "$H/state/build-queue/tproj/TK-1.json"
printf '{"machines":[{"machine_id":"livem","project":"tproj","app":"pool-tproj","role":"pool","key":"TK-1","ticket":"7","state":"started","spawned_at":"%s","last_seen":"%s"}]}' "$OLD" "$OLD" > "$T/live-rows.json"
tick FLY_MACHINES_ROWS=on
[ "$(cat "$T/tick.rc")" = "0" ] && ok || bad "§7 advisory tick exit rc=$(cat "$T/tick.rc")"
grep -q 'row says TK-1 is live on livem and no file says so — spawning anyway this cycle' "$H/logs/fly-pool.log" && ok \
  || bad "§7 advisory line missing: $(cat "$H/logs/fly-pool.log")"
[ "$(gets)" -eq 1 ] && ok || bad "§7 expected one GET /api/machines, got $(gets)"
[ "$(ls -1 "$H/state/fly-pool/tproj"/*.json 2>/dev/null | wc -l | tr -d ' ')" -ge 1 ] && ok || bad "§7 spawn must create at least one local tracking file"
reset
q "TK-1" "7" > "$H/state/build-queue/tproj/TK-1.json"
tick FLY_MACHINES_ROWS=on
[ "$(ls -1 "$H/state/fly-pool/tproj"/*.json 2>/dev/null | wc -l | tr -d ' ')" -ge 1 ] && ok || bad "§7 no-row spawn must create at least one tracking file"
! grep -q 'row says TK-1 is live' "$H/logs/fly-pool.log" && ok || bad "§7 no-row case must not log advisory: $(cat "$H/logs/fly-pool.log")"
reset
q "TK-1" "7" > "$H/state/build-queue/tproj/TK-1.json"
tick FLY_MACHINES_ROWS=off
[ "$(gets)" -eq 0 ] && ok || bad "§7 flag-off expected zero GET /api/machines, got $(gets): $(cat "$T/req.log")"

# §11 sweep: untracked stopped machine older than TTL -> PATCH state destroyed;
# destroy refused -> destroy_failed with flyctl error in detail.
reset
mklist "[{\"id\":\"$MID2\",\"state\":\"stopped\",\"updated_at\":\"$OLD\"}]"
tick FLY_MACHINES_ROWS=on
[ "$(cat "$T/tick.rc")" = "0" ] && ok || bad "§11 sweep tick exit rc=$(cat "$T/tick.rc")"
[ "$(observes)" -eq 1 ] && ok || bad "§11 expected one observe, got $(observes)"
[ "$(patches)" -eq 1 ] && ok || bad "§11 expected one PATCH for destroyed sweep, got $(patches)"
[ "$(jq -r '.state' <<<"$(patch_body $MID2)")" = "destroyed" ] && ok || bad "§11 PATCH state=$(jq -r '.state' <<<"$(patch_body $MID2)")"
reset
mklist "[{\"id\":\"$MID3\",\"state\":\"stopped\",\"updated_at\":\"$OLD\"}]"
printf '%s\n' "$MID3" > "$T/destroy-fail"
tick FLY_MACHINES_ROWS=on
[ "$(cat "$T/tick.rc")" = "0" ] && ok || bad "§11 refused sweep tick exit rc=$(cat "$T/tick.rc")"
[ "$(patches)" -eq 1 ] && ok || bad "§11 refused expected one PATCH, got $(patches)"
[ "$(jq -r '.state' <<<"$(patch_body $MID3)")" = "destroy_failed" ] && ok || bad "§11 refused PATCH state=$(jq -r '.state' <<<"$(patch_body $MID3)")"
DETAIL=$(jq -r '.detail' <<<"$(patch_body $MID3)")
[ -n "$DETAIL" ] && ok || bad "§11 refused PATCH detail empty"
case "$DETAIL" in *"rate limited"*) ok ;; *) bad "§11 refused PATCH detail missing flyctl error: $DETAIL" ;; esac

echo "fly-machines-rows-pool.bh-1056: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
