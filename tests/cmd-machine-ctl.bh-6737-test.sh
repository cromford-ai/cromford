#!/bin/bash
# tests/cmd-machine-ctl.bh-6737-test.sh — BH-6737: the console's machine_ctl
# command and the `destroy` verb it adds to bin/fly-api.sh.
#
# bin/cmd-machine-ctl.sh <project> <payload-json> <command_id> runs
# bin/fly-api.sh <project> start|stop|destroy <machine-id>. A destroy is refused
# BEFORE any Fly call when a state/fly-pool/<p>/ record names the machine (the
# box_ops_fly_destroy rule), and bin/fly-api.sh itself refuses to destroy the
# builder machine. The ack carries the state fly-api.sh printed after the op.
#
# M1 start/stop through a stub fly-api.sh, M2 the live-claim guard, M3 a real
# DELETE through the real fly-api.sh and a stub curl, M4 bad op / id, M5 the
# builder machine, M6 404 = already gone, M7 a two-arg fly-api.sh call is
# unchanged.
# Run from anywhere: tests/cmd-machine-ctl.bh-6737-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/flags" "$H/env" "$H/logs" "$H/state/fly" "$H/state/fly-pool/pa" "$T/stub"
for s in bin/cmd-machine-ctl.sh bin/fly-api.sh bin/fleet-conf.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || bad "install $s"
done
cat > "$H/fleet.conf" <<'EOF'
# fixture
pa example-org/fixture-pa - - 1 hub
EOF
printf '{"app":"pa-builder","machine_id":"b1234567"}\n' > "$H/state/fly/pa.json"
printf 'FLY_API_TOKEN_PA=tok-fixture-1\n' > "$H/env/fly.env"
printf 'pa-pool\n' > "$H/flags/fly-pool-app-pa"
cp "$H/bin/fly-api.sh" "$T/fly-api.real"

# Stub curl: one log line per call; -w '%{http_code}' answers CURL_CODE, any
# other call answers a stopped machine.
cat > "$T/stub/curl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$CURL_LOG"
case " $* " in *" -w "*) printf '%s' "${CURL_CODE:-200}" ;; *) printf '{"state":"stopped"}\n' ;; esac
EOF
chmod 755 "$T/stub/curl"

# Stub fly-api.sh: logs its argv, prints STUB_STATE, exits STUB_RC.
stub_flyapi() {
  cat > "$H/bin/fly-api.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$FLYAPI_LOG"
printf '%s\n' "${STUB_STATE:-started}"
exit "${STUB_RC:-0}"
EOF
  chmod 755 "$H/bin/fly-api.sh"
}
real_flyapi() { cp "$T/fly-api.real" "$H/bin/fly-api.sh"; chmod 755 "$H/bin/fly-api.sh"; }

run_env() {
  env PATH="$T/stub:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" CURL_LOG="$T/curl.log" \
    FLYAPI_LOG="$T/flyapi.log" ENDPOINT_FLY_MACHINES=https://machines.fixture.example \
    HARNESS_ENV_DIR="$H/env" "$@"
}
# mc <project> <payload> -> OUT RC; the logs are cleared first
mc() {
  : > "$T/curl.log"; : > "$T/flyapi.log"
  OUT=$(run_env bash "$H/bin/cmd-machine-ctl.sh" "$1" "$2" 51 2>"$T/err"); RC=$?
}
jf() { jq -r "$1" <<<"$OUT" 2>/dev/null; }

echo "--- M1: start and stop go through fly-api.sh with the machine id"
stub_flyapi
STUB_STATE=started mc pa '{"machine_id":"m1234567","op":"start"}'
[ "$RC" = 0 ] && ok || bad "M1 start rc $RC (out=$OUT err=$(cat "$T/err"))"
[ "$(cat "$T/flyapi.log")" = "pa start m1234567" ] && ok || bad "M1 start argv '$(cat "$T/flyapi.log")'"
[ "$(jf .result)" = ok ] && ok || bad "M1 start .result (out=$OUT)"
[ "$(jf .state)" = started ] && ok || bad "M1 start .state (out=$OUT)"
[ "$(jf .machine_id)" = m1234567 ] && [ "$(jf .op)" = start ] && ok || bad "M1 .machine_id/.op (out=$OUT)"
export STUB_STATE=stopped
mc pa '{"machine_id":"m1234567","op":"stop"}'
{ [ "$RC" = 0 ] && [ "$(cat "$T/flyapi.log")" = "pa stop m1234567" ] && [ "$(jf .state)" = stopped ]; } \
  && ok || bad "M1 stop rc $RC log '$(cat "$T/flyapi.log")' out=$OUT"
unset STUB_STATE
STUB_RC=1 STUB_STATE=starting mc pa '{"machine_id":"m1234567","op":"start"}'
{ [ "$RC" = 1 ] && [ "$(jf .result)" = failed ] && [ "$(jf .state)" = starting ]; } \
  && ok || bad "M1 fly-api rc 1 is failed, never ok (rc $RC out=$OUT)"
STUB_RC=2 mc pa '{"machine_id":"m1234567","op":"destroy"}'
{ [ "$RC" = 3 ] && [ "$(jf .result)" = refused ]; } && ok || bad "M1 fly-api rc 2 is refused (rc $RC out=$OUT)"

echo "--- M2: destroy is refused while a pool record names the machine"
printf '{"key":"PA-7","machine":"m1234567"}\n' > "$H/state/fly-pool/pa/x.json"
mc pa '{"machine_id":"m1234567","op":"destroy"}'
{ [ "$RC" = 3 ] && [ "$(jf .result)" = refused ]; } && ok || bad "M2 .machine match rc $RC (out=$OUT)"
jf .reason | grep -q 'live pool job' && ok || bad "M2 reason (out=$OUT)"
[ ! -s "$T/flyapi.log" ] && ok || bad "M2 fly-api.sh was called: $(cat "$T/flyapi.log")"
rm -f "$H/state/fly-pool/pa/x.json"
printf '{"key":"PA-8"}\n' > "$H/state/fly-pool/pa/m1234567.json"
mc pa '{"machine_id":"m1234567","op":"destroy"}'
{ [ "$RC" = 3 ] && [ ! -s "$T/flyapi.log" ]; } && ok || bad "M2 file-name match rc $RC (out=$OUT)"
rm -f "$H/state/fly-pool/pa/m1234567.json"
printf 'not json' > "$H/state/fly-pool/pa/broken.json"
mc pa '{"machine_id":"m1234567","op":"destroy"}'
{ [ "$RC" = 3 ] && [ ! -s "$T/flyapi.log" ]; } && ok || bad "M2 unreadable record fails closed rc $RC (out=$OUT)"
rm -f "$H/state/fly-pool/pa/broken.json"
# A record for ANOTHER machine, and a dot file, do not block it.
printf '{"key":"PA-9","machine":"m7654321"}\n' > "$H/state/fly-pool/pa/y.json"
printf '{"machine":"m1234567"}\n' > "$H/state/fly-pool/pa/.sweep.json"
STUB_STATE=destroyed mc pa '{"machine_id":"m1234567","op":"destroy"}'
{ [ "$RC" = 0 ] && [ "$(cat "$T/flyapi.log")" = "pa destroy m1234567" ]; } && ok || bad "M2 other machine's record does not block (rc $RC out=$OUT)"
rm -f "$H/state/fly-pool/pa/y.json" "$H/state/fly-pool/pa/.sweep.json"

echo "--- M3: destroy through the real fly-api.sh sends exactly one DELETE"
real_flyapi
CURL_CODE=200 mc pa '{"machine_id":"m1234567","op":"destroy"}'
[ "$RC" = 0 ] && ok || bad "M3 rc $RC (out=$OUT err=$(cat "$T/err"))"
[ "$(wc -l < "$T/curl.log")" = 1 ] && ok || bad "M3 curl calls: $(cat "$T/curl.log")"
grep -q -- '-X DELETE' "$T/curl.log" && ok || bad "M3 no -X DELETE: $(cat "$T/curl.log")"
grep -qF 'https://machines.fixture.example/v1/apps/pa-pool/machines/m1234567?force=true' "$T/curl.log" \
  && ok || bad "M3 DELETE url: $(cat "$T/curl.log")"
grep -qF 'Bearer tok-fixture-1' "$T/curl.log" && ok || bad "M3 token not sent"
[ "$(jf .state)" = destroyed ] && [ "$(jf .result)" = ok ] && ok || bad "M3 .state (out=$OUT)"
CURL_CODE=500 mc pa '{"machine_id":"m1234567","op":"destroy"}'
{ [ "$RC" = 1 ] && [ "$(jf .result)" = failed ] && [ "$(jf .state)" = "failed http=500" ]; } \
  && ok || bad "M3 http 500 is failed (rc $RC out=$OUT)"

echo "--- M4: a bad op or machine id runs nothing"
stub_flyapi
for p in '{"machine_id":"m1234567","op":"reboot"}' '{"machine_id":"../x","op":"stop"}' \
         '{"machine_id":"ABCDEFGH1","op":"stop"}' '{"machine_id":"m123","op":"stop"}' \
         '{"machine_id":12345678,"op":"stop"}' '{"op":"stop"}' 'nope'; do
  mc pa "$p"
  { [ "$RC" = 3 ] && [ "$(jf .result)" = refused ] && [ ! -s "$T/flyapi.log" ]; } && ok || bad "M4 $p rc $RC (out=$OUT)"
done
mc zz '{"machine_id":"m1234567","op":"stop"}'
{ [ "$RC" = 3 ] && [ ! -s "$T/flyapi.log" ]; } && ok || bad "M4 unknown project rc $RC"

echo "--- M5: the real fly-api.sh refuses to destroy the builder machine"
real_flyapi
: > "$T/curl.log"
run_env bash "$H/bin/fly-api.sh" pa destroy b1234567 >"$T/m5.out" 2>"$T/m5.err"; M5=$?
[ "$M5" = 2 ] && ok || bad "M5 rc $M5 (err=$(cat "$T/m5.err"))"
[ ! -s "$T/curl.log" ] && ok || bad "M5 curl was called: $(cat "$T/curl.log")"
mc pa '{"machine_id":"b1234567","op":"destroy"}'
{ [ "$RC" = 3 ] && [ "$(jf .result)" = refused ] && [ ! -s "$T/curl.log" ]; } && ok || bad "M5 via cmd rc $RC (out=$OUT)"

echo "--- M6: 404 is already gone"
: > "$T/curl.log"
M6=$(run_env CURL_CODE=404 bash "$H/bin/fly-api.sh" pa destroy m1234567 2>/dev/null); M6RC=$?
{ [ "$M6RC" = 0 ] && [ "$M6" = "already gone" ]; } && ok || bad "M6 rc $M6RC out '$M6'"
run_env bash "$H/bin/fly-api.sh" pa destroy 'bad/id' >/dev/null 2>&1; M6B=$?
[ "$M6B" != 0 ] && ok || bad "M6 a bad id is not accepted"

echo "--- M7: a two-arg call still reads the builder machine"
: > "$T/curl.log"
M7=$(run_env bash "$H/bin/fly-api.sh" pa state 2>/dev/null)
{ [ "$M7" = stopped ] && grep -qF '/apps/pa-builder/machines/b1234567' "$T/curl.log"; } && ok || bad "M7 out '$M7' log $(cat "$T/curl.log")"
: > "$T/curl.log"
run_env bash "$H/bin/fly-api.sh" pa state m1234567 >/dev/null 2>&1
grep -qF '/apps/pa-pool/machines/m1234567' "$T/curl.log" && ok || bad "M7 a pool id reads the pool app: $(cat "$T/curl.log")"

echo "cmd-machine-ctl: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
