#!/bin/bash
# tests/orgo-state-workspaces.bh-9068-test.sh — BH-9068: bin/orgo-state.sh reads
# the Orgo desktop list from GET /workspaces (workspaces[].desktops[]), because
# GET /computers answers 405. The PUT body to /api/orgo-computers keeps its shape.
#
# Runs the REAL bin/orgo-state.sh with its source closure in a scratch harness
# root (the rig of tests/orgo-state.bh-5750-test.sh). Stubbed: curl (the Orgo
# API answers by bearer key and records the path; the worker answers by path)
# and bin/hub-lease.sh.
#
#   W1  the fixture (3 workspaces, 9 desktops): GET /workspaces, one PUT with
#       9 computers, complete:true, ok=1 in the counter line, rc 0
#   W2  secret-looking keys inside a desktop never reach the PUT
#   W3  a workspace with no desktops key counts 0; workspaces:[] is 0, complete
#   W4  the old shapes (a bare array, {computers:[...]}) are still read
#   W5  workspaces as an object, or no workspaces key: failed, ok:false PUT, rc 0
# Run from anywhere: HARNESS_TEST_SANDBOX=1 tests/orgo-state-workspaces.bh-9068-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
FX="$DIR/tests/fixtures/orgo-workspaces.bh-9068.json"
[ -f "$DIR/bin/orgo-state.sh" ] || { echo "FAIL: missing bin/orgo-state.sh"; exit 1; }
[ -f "$FX" ] || { echo "FAIL: missing tests/fixtures/orgo-workspaces.bh-9068.json"; exit 1; }

H="$T/h"
mkdir -p "$H/logs" "$H/flags" "$H/locks" "$H/state" "$H/env" "$H/catalog" "$T/fakebin"
for f in bin/orgo-state.sh bin/jobs-client.sh bin/alert-line.sh; do
  scratch_install_closure "$f" "$H" >/dev/null || { echo "FAIL: cannot install the closure of $f"; exit 1; }
done
printf '#!/bin/bash\n[ "${1:-}" = check ] || exit 2\nexit 0\n' > "$H/bin/hub-lease.sh"; chmod +x "$H/bin/hub-lease.sh"
: > "$H/env/global.env"

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
    printf '%s %s\n' "$method" "${url#https://orgo.test/api}" >> "$STUB_DIR/orgo.log"
    case "$key" in
      key-fixture-ws)    cat "$FX_FILE"; printf '\n200' ;;
      key-fixture-empty) printf '%s\n200' '{"workspaces":[]}' ;;
      key-fixture-arr)   printf '%s\n200' '[{"id":"oc-1","name":"fixture-box-1","status":"running"}]' ;;
      key-fixture-comp)  printf '%s\n200' '{"computers":[{"id":"oc-2","name":"fixture-box-2","status":"stopped"}]}' ;;
      key-fixture-obj)   printf '%s\n200' '{"workspaces":{"id":"ws-fixture","desktops":[]}}' ;;
      key-fixture-none)  printf '%s\n200' '{"items":[]}' ;;
      *) printf '%s\n401' '{"error":"unauthorized"}' ;;
    esac ;;
  https://jobs.test/api/orgo-computers)
    printf '%s\n' "$body" >> "$STUB_DIR/puts.log"
    printf '%s\n%s' '{"ok":true,"upserted":0,"tombstoned":0}' 200 ;;
  *) printf '%s\n%s' '{}' 404 ;;
esac
EOF
chmod +x "$T/fakebin/curl"
export STUB_DIR="$T" FX_FILE="$FX" PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=secret-fixture
export JOBS_URL=https://jobs.test JOBS_RETRIES=0 ORGO_API_BASE=https://orgo.test/api

one() { # one <key>: one account "acct" with that key; run the lane
  jq -n '{_comment:["fixture"], accounts:{acct:{plan:"startup_v2", key_env:"ORGO_KEY_X"}}}' > "$H/catalog/orgo-plans.json"
  rm -f "$T/orgo.log" "$T/puts.log" "$H/logs/orgo-state.log"
  ORGO_KEY_X="$1" bash "$H/bin/orgo-state.sh" > "$T/out" 2>&1; RC=$?
  P=$(tail -1 "$T/puts.log" 2>/dev/null)
}

# W1 ---------------------------------------------------------------------------
one key-fixture-ws
[ "$RC" = 0 ] && ok || bad "W1 rc=$RC ($(cat "$T/out"))"
[ "$(cat "$T/orgo.log" 2>/dev/null)" = "GET /workspaces" ] && ok || bad "W1 the lane did not call GET /workspaces: $(cat "$T/orgo.log" 2>/dev/null)"
[ "$(jq -c '[.ok, .complete, (.computers | length)]' <<<"$P")" = '[true,true,9]' ] && ok || bad "W1 want ok, complete, 9 computers: $P"
[ "$(jq -c '[.computers[].id]' <<<"$P")" = '["dk-1","dk-2","dk-3","dk-4","dk-5","dk-6","dk-7","dk-8","dk-9"]' ] && ok || bad "W1 ids: $P"
[ "$(jq -c '.computers[2] | [.name, .status, .cpu, .ram, .disk]' <<<"$P")" = '["fixture-desk-3","stopped",2,8,50]' ] && ok || bad "W1 desktop fields: $P"
grep -q 'checked=1 ok=1 failed=0' "$H/logs/orgo-state.log" && ok || bad "W1 counter line: $(cat "$H/logs/orgo-state.log")"

# W2 ---------------------------------------------------------------------------
grep -q 'pw-fixture\|tok-fixture-9' "$T/puts.log" && bad "W2 a secret-looking value reached the PUT" || ok

# W3 ---------------------------------------------------------------------------
one key-fixture-empty
[ "$(jq -c '[.ok, .complete, (.computers | length)]' <<<"$P")" = '[true,true,0]' ] && ok || bad "W3 workspaces:[] want ok, complete, 0: $P"

# W4 ---------------------------------------------------------------------------
one key-fixture-arr
[ "$(jq -c '[.ok, [.computers[].id]]' <<<"$P")" = '[true,["oc-1"]]' ] && ok || bad "W4 a bare array is no longer read: $P"
one key-fixture-comp
[ "$(jq -c '[.ok, [.computers[].id]]' <<<"$P")" = '[true,["oc-2"]]' ] && ok || bad "W4 {computers:[...]} is no longer read: $P"

# W5 ---------------------------------------------------------------------------
for k in key-fixture-obj key-fixture-none; do
  one "$k"
  [ "$RC" = 0 ] && ok || bad "W5 $k rc=$RC"
  [ "$(jq -c '[.ok, .complete, .computers]' <<<"$P")" = '[false,false,[]]' ] && ok || bad "W5 $k want a failed read: $P"
  jq -r '.detail' <<<"$P" | grep -q 'unreadable' && ok || bad "W5 $k detail: $P"
  grep -q 'failed=1' "$H/logs/orgo-state.log" && ok || bad "W5 $k counter: $(cat "$H/logs/orgo-state.log")"
done

echo "orgo-state-workspaces.bh-9068: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
