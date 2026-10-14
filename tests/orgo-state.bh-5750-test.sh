#!/bin/bash
# tests/orgo-state.bh-5750-test.sh — the hub's Orgo live-state lane (BH-5750,
# C4): bin/orgo-state.sh reads GET /computers for each Orgo account in
# catalog/orgo-plans.json and PUTs the list to the jobs worker's
# /api/orgo-computers, which the /machines ORGO STATE column reads.
#
# Runs the REAL bin/orgo-state.sh with its whole source closure (the real
# orgo() seam in bin/lib/restore-drill-orgo.sh, the real bin/jobs-client.sh)
# in a scratch harness root. Stubbed: curl (answers the Orgo API by the bearer
# key it is handed, and the worker by path) and bin/hub-lease.sh.
#
#   S1  a configured account: one PUT {account, ok:true, complete:true, computers}.
#   S2  a missing key: no Orgo call and no PUT for that account, one log line, no ALERT.
#   S3  an HTTP 500: PUT ok:false complete:false computers:[] (a failed read
#       tombstones nothing), no ALERT.
#   S4  an unreadable 2xx body is a failed read too; {computers:[…]} is read.
#   S5  more than 500 computers: the first 500, complete:false, the count in detail.
#   S6  secret-looking keys never leave the box; the key is never logged or PUT.
#   G1  not the hub / lane off / lock held: no Orgo call, no PUT, exit 0.
#   K1  a bad timeout knob: one ALERT, exit 1, nothing called.
#   W1  the route answers 404: one log line, exit 0, no ALERT.
#   N1  the worker route's own node suite passes (when node is installed).
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 tests/orgo-state.bh-5750-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# The worker imports catalog/lanes.json and catalog/llm-sites.json, both
# generated and git-ignored: render them first (as box-commands-worker.bh-2518).
HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --root "$DIR" --write >/dev/null 2>&1 || { echo "FAIL: cannot render catalog/lanes.json"; exit 1; }
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LANE="$DIR/bin/orgo-state.sh"
ROUTE="$DIR/worker/jobs/src/routes/orgo-computers.js"
[ -f "$LANE" ] || { echo "FAIL: missing bin/orgo-state.sh"; exit 1; }
[ -f "$ROUTE" ] || { echo "FAIL: missing worker/jobs/src/routes/orgo-computers.js"; exit 1; }

H="$T/h"
mkdir -p "$H/logs" "$H/flags" "$H/locks" "$H/state" "$H/env" "$H/catalog" "$T/fakebin"
for f in bin/orgo-state.sh bin/jobs-client.sh bin/alert-line.sh; do
  scratch_install_closure "$f" "$H" >/dev/null || { echo "FAIL: cannot install the closure of $f"; exit 1; }
done
cat > "$H/bin/hub-lease.sh" <<'EOF'
#!/bin/bash
[ "${1:-}" = check ] || exit 2
exit "${LEASE_RC:-0}"
EOF
chmod +x "$H/bin/hub-lease.sh"
: > "$H/env/global.env"

# The Orgo API answers by the bearer key (read from the -H @file the orgo()
# seam hands curl, so the key is never in argv); the worker answers by path.
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
method=GET; body=""; url=""; prev=""; key=""
for a in "$@"; do
  case "$prev" in
    -X) method=$a ;;
    --data-binary|-d) body=$a ;;
    -H) case "$a" in @*) key=$(sed -n 's/^Authorization: Bearer //p' "${a#@}") ;; esac ;;
  esac
  case "$a" in http*://*) url=$a ;; esac
  prev=$a
done
case "$body" in @*) body=$(cat "${body#@}") ;; esac
case "$url" in
  https://orgo.test/*)
    printf '%s %s key=%s\n' "$method" "${url#https://orgo.test/api}" "$key" >> "$STUB_DIR/orgo.log"
    case "$key" in
      key-fixture-a) printf '%s\n200' '[{"id":"oc-1","name":"fixture-box-a1","status":"running","cpu":4,"ram":16,"disk":100,"vnc_password":"pw-fixture","api_token":"tok-fixture-1"},{"id":"oc-2","name":"fixture-box-a2","status":"stopped","cpu":2,"ram":8,"disk":50}]' ;;
      key-fixture-c) printf '%s\n500' '{"error":"fixture upstream"}' ;;
      key-fixture-d) printf '%s\n200' '{"unexpected":"fixture"}' ;;
      key-fixture-e) printf '%s\n200' '{"computers":[{"id":7,"name":"fixture-box-e7","status":"running","cpu":4,"ram":16,"disk":100}]}' ;;
      key-fixture-big) jq -nc '[range(501) | {id:"oc-\(.)", name:"n\(.)", status:"running", cpu:1, ram:4, disk:10}]'; printf '\n200' ;;
      *) printf '%s\n401' '{"error":"unauthorized"}' ;;
    esac ;;
  https://jobs.test/api/orgo-computers)
    printf '%s\n' "$body" >> "$STUB_DIR/puts.log"
    printf '%s\n%s' '{"ok":true,"upserted":0,"tombstoned":0}' "${PUT_CODE:-200}" ;;
  *)
    printf '%s %s\n' "$method" "$url" >> "$STUB_DIR/other.log"
    printf '%s\n%s' '{}' 404 ;;
esac
EOF
chmod +x "$T/fakebin/curl"

export STUB_DIR="$T" PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=secret-fixture
export JOBS_URL=https://jobs.test JOBS_RETRIES=0 ORGO_API_BASE=https://orgo.test/api

plans() { # plans <account>:<key_env> ... — write catalog/orgo-plans.json
  local a json='{}'
  for a in "$@"; do json=$(jq -c --arg a "${a%%:*}" --arg k "${a#*:}" '.[$a] = {plan:"startup_v2", key_env:$k}' <<<"$json"); done
  jq -n --argjson a "$json" '{_comment:["fixture"], accounts:$a}' > "$H/catalog/orgo-plans.json"
}
reset() {
  rm -f "$T"/orgo.log "$T"/puts.log "$T"/other.log "$H/logs/orgo-state.log" "$H/flags/lane-off-orgo-state"
  : > "$H/logs/ALERTS.log"
  unset PUT_CODE ORGO_STATE_CALL_TIMEOUT_S ORGO_KEY_A ORGO_KEY_B ORGO_KEY_C ORGO_KEY_D ORGO_KEY_E ORGO_KEY_BIG
  export LEASE_RC=0
}
run() { bash "$H/bin/orgo-state.sh" > "$T/out" 2>&1; RC=$?; }
nputs()  { [ -s "$T/puts.log" ] && wc -l < "$T/puts.log" || echo 0; }
norgo()  { [ -s "$T/orgo.log" ] && wc -l < "$T/orgo.log" || echo 0; }
putfor() { jq -c --arg a "$1" 'select(.account == $a)' "$T/puts.log" 2>/dev/null; }
alerts() { grep -c . "$H/logs/ALERTS.log" || true; }

# ── S1 + S2 + S3: a configured account, an unset key, an upstream 500 ───
reset; plans acct-a:ORGO_KEY_A acct-b:ORGO_KEY_B acct-c:ORGO_KEY_C
export ORGO_KEY_A=key-fixture-a ORGO_KEY_C=key-fixture-c
run
[ "$RC" = 0 ] && ok || bad "S1 rc=$RC ($(cat "$T/out"))"
P=$(putfor acct-a)
[ "$(jq -r '[.ok, .complete] | map(tostring) | join(",")' <<<"$P")" = "true,true" ] && ok || bad "S1 acct-a not ok+complete: $P"
[ "$(jq -c '[.computers[].id]' <<<"$P")" = '["oc-1","oc-2"]' ] && ok || bad "S1 acct-a ids: $P"
[ "$(jq -c '.computers[0] | [.name, .status, .cpu, .ram, .disk]' <<<"$P")" = '["fixture-box-a1","running",4,16,100]' ] && ok \
  || bad "S1 the entry is not passed in the Orgo shape: $P"
[ -z "$(putfor acct-b)" ] && ok || bad "S2 PUT for an account with no key: $(putfor acct-b)"
grep -q 'key=$' "$T/orgo.log" && bad "S2 an Orgo call went out with an empty bearer: $(cat "$T/orgo.log")" || ok
[ "$(grep -c 'acct-b' "$H/logs/orgo-state.log")" = 1 ] && grep 'acct-b' "$H/logs/orgo-state.log" | grep -q 'not configured' && ok \
  || bad "S2 want one 'not configured' log line for acct-b: $(cat "$H/logs/orgo-state.log")"
P=$(putfor acct-c)
[ "$(jq -c '[.ok, .complete, .computers]' <<<"$P")" = '[false,false,[]]' ] && ok || bad "S3 acct-c a 500 must PUT ok:false complete:false computers:[]: $P"
jq -r '.detail' <<<"$P" | grep -q 'HTTP 500' && ok || bad "S3 detail lacks the HTTP code: $P"
[ "$(nputs)" = 2 ] && ok || bad "S1-S3 want 2 PUTs, got $(nputs)"
[ "$(alerts)" = 0 ] && ok || bad "S2/S3 raised an ALERT: $(cat "$H/logs/ALERTS.log")"
# S6: secret-looking fields and the key never leave the box.
grep -q 'pw-fixture\|tok-fixture-1\|key-fixture' "$T/puts.log" && bad "S6 a secret reached the PUT body" || ok
grep -q 'key-fixture\|pw-fixture' "$H/logs/orgo-state.log" "$T/out" && bad "S6 a secret reached the log" || ok
[ "$(jq -c '.computers[0] | has("vnc_password"), has("api_token")' <<<"$(putfor acct-a)" | tr '\n' ' ')" = 'false false ' ] && ok \
  || bad "S6 secret-looking keys kept: $(putfor acct-a)"
grep -q 'checked=3' "$H/logs/orgo-state.log" && ok || bad "S1 no summary line: $(cat "$H/logs/orgo-state.log")"

# ── S4: an unreadable body is a failed read; {computers:[…]} is read ──────
reset; plans acct-d:ORGO_KEY_D acct-e:ORGO_KEY_E
export ORGO_KEY_D=key-fixture-d ORGO_KEY_E=key-fixture-e
run
[ "$RC" = 0 ] && ok || bad "S4 rc=$RC"
[ "$(jq -c '[.ok, .complete, .computers]' <<<"$(putfor acct-d)")" = '[false,false,[]]' ] && ok || bad "S4 unreadable body: $(putfor acct-d)"
[ "$(jq -c '[.ok, .complete, [.computers[].id]]' <<<"$(putfor acct-e)")" = '[true,true,[7]]' ] && ok || bad "S4 wrapped list: $(putfor acct-e)"

# ── S5: over the 500 bound → the first 500, complete:false ───────────────
reset; plans acct-big:ORGO_KEY_BIG; export ORGO_KEY_BIG=key-fixture-big
run
P=$(putfor acct-big)
[ "$(jq -c '[.ok, .complete, (.computers | length)]' <<<"$P")" = '[true,false,500]' ] && ok || bad "S5 cap: $(jq -c '[.ok, .complete, (.computers|length), .detail]' <<<"$P")"
jq -r '.detail' <<<"$P" | grep -q '501' && ok || bad "S5 detail lacks the real count: $(jq -r .detail <<<"$P")"

# ── G1: not the hub, lane off, lock held → nothing ───────────────────────
reset; plans acct-a:ORGO_KEY_A; export ORGO_KEY_A=key-fixture-a LEASE_RC=1
run
[ "$RC" = 0 ] && [ "$(norgo)" = 0 ] && [ "$(nputs)" = 0 ] && ok || bad "G1 not-hub rc=$RC orgo=$(norgo) puts=$(nputs)"
reset; plans acct-a:ORGO_KEY_A; export ORGO_KEY_A=key-fixture-a; touch "$H/flags/lane-off-orgo-state"
run
[ "$RC" = 0 ] && [ "$(norgo)" = 0 ] && [ "$(nputs)" = 0 ] && ok || bad "G1 lane-off rc=$RC orgo=$(norgo) puts=$(nputs)"
reset; plans acct-a:ORGO_KEY_A; export ORGO_KEY_A=key-fixture-a
exec 8>"$H/locks/orgo-state.lock"; flock -n 8 || bad "G1 test could not take the lock"
run
exec 8>&-
[ "$RC" = 0 ] && [ "$(norgo)" = 0 ] && [ "$(nputs)" = 0 ] && ok || bad "G1 locked rc=$RC orgo=$(norgo) puts=$(nputs)"

# ── K1: a bad knob is refused, never clamped ─────────────────────────────
for v in abc 0 -5; do
  reset; plans acct-a:ORGO_KEY_A; export ORGO_KEY_A=key-fixture-a ORGO_STATE_CALL_TIMEOUT_S=$v
  run
  [ "$RC" = 1 ] && ok || bad "K1 $v rc=$RC"
  [ "$(alerts)" = 1 ] && grep -q ORGO_STATE_CALL_TIMEOUT_S "$H/logs/ALERTS.log" && ok || bad "K1 $v ALERTS: $(cat "$H/logs/ALERTS.log")"
  [ "$(norgo)" = 0 ] && [ "$(nputs)" = 0 ] && ok || bad "K1 $v called out"
done

# ── W1: the route is not deployed → one log line, exit 0, no ALERT ───────
reset; plans acct-a:ORGO_KEY_A; export ORGO_KEY_A=key-fixture-a PUT_CODE=404
run
[ "$RC" = 0 ] && ok || bad "W1 rc=$RC"
grep 'acct-a' "$H/logs/orgo-state.log" | grep -q '404' && ok || bad "W1 no 404 log line: $(cat "$H/logs/orgo-state.log")"
[ "$(alerts)" = 0 ] && ok || bad "W1 ALERT on a 404: $(cat "$H/logs/ALERTS.log")"

# ── N1: the route's node suite ───────────────────────────────────────────
if command -v node >/dev/null 2>&1; then
  if NOUT=$(cd "$DIR/worker/jobs" && node --test test/orgo-computers.bh-5750.test.js 2>&1); then ok
  else bad "N1 worker/jobs/test/orgo-computers.bh-5750.test.js failed:"; printf '%s\n' "$NOUT" | tail -30
  fi
else
  echo "N1 SKIPPED — node is not installed on this box"
fi

echo "orgo-state.bh-5750: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
