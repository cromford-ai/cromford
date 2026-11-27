#!/bin/bash
# tests/box-watch-lever.bh-10231-test.sh — BH-10231 (ask 2 of BH-9889): the
# hourly Orgo lever check, `bin/box-watch.sh lever-check`. For each key_env in
# catalog/orgo-plans.json it checks the key is set and that GET /workspaces
# answers 2xx. If not, ONE warn alert through orgo_lever_alert
# (bin/lib/orgo-lever.sh): the same --id orgo-lever-<KEY> and text as
# bin/box-ops.sh. A 2xx retracts that alert. It never restarts anything.
#
# Runs the REAL bin/box-watch.sh, bin/lib/orgo-lever.sh and
# bin/lib/restore-drill-orgo.sh in a scratch harness. Stubbed: curl (Orgo
# answers $ORGO_CODE; ORGO_HANG=1 is a curl timeout, rc 28), alert-line.sh
# (records argv), box-ops (records any call). No network.
#   L1 ORGO_API_KEY unset: exactly 1 warn alert --id orgo-lever-ORGO_API_KEY
#      whose text equals `orgo_lever_text ORGO_API_KEY unset`; 0 Orgo calls
#   L2 key set, HTTP 401: 1 warn alert naming the key and HTTP 401
#   L3 key set, HTTP 200 (and 204): 0 warn alerts, 1 resolved retraction;
#      the call is GET /workspaces with curl -m 30 (box_watch.orgo_timeout_s)
#   L4 key set, curl timeout: 1 warn alert with HTTP 000
#   L5 no key value in any output, log, alert argv or curl argv
#   L6 flags/lane-off-box-watch: 0 Orgo calls, 0 alerts
#   L7 two accounts, ORGO_API_KEY answers 200 and the second key is unset:
#      1 warn alert for the second key only, 1 retraction for ORGO_API_KEY
#   Every case: 0 box-ops calls.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/box-watch-lever.bh-10231-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }
command -v jq >/dev/null || { echo "box-watch-lever.bh-10231-test: SKIPPED — jq missing"; exit 0; }
[ -f "$DIR/bin/box-watch.sh" ] || { echo "FAIL: missing bin/box-watch.sh"; exit 1; }

FB="$T/fakebin"; mkdir -p "$FB"
cat > "$FB/curl" <<'CURL'
#!/bin/bash
URL="${!#}"; METHOD=GET; M=""; ARGS="$*"
while [ $# -gt 0 ]; do case "$1" in -X) METHOD="$2"; shift 2;; -m) M="$2"; shift 2;; *) shift;; esac; done
printf '%s %s m=%s argv=%s\n' "$METHOD" "$URL" "$M" "$ARGS" >> "$CURL_LOG"
case "$URL" in
  *orgo.fixture*)
    [ "${ORGO_HANG:-0}" = 1 ] && exit 28
    printf '{"workspaces":[]}\n%s' "${ORGO_CODE:-200}" ;;
  *) printf '{"error":"not found"}\n404' ;;
esac
CURL
printf '#!/bin/bash\necho "$*" >> "$BOXOPS_LOG"\n' > "$FB/box-ops"
chmod +x "$FB/curl" "$FB/box-ops"
KEY=sk-fixture-orgo-lever-SECRET-10231
KEY2=sk-fixture-orgo-second-SECRET-10231

HN=0
new_harness() { # new_harness [two] -> H, C
  HN=$((HN+1)); H="$T/h$HN"; C="$T/c$HN"
  mkdir -p "$H/logs" "$H/state" "$H/env" "$H/flags" "$H/catalog" "$C"
  local S
  for S in bin/box-watch.sh bin/lib/orgo-lever.sh bin/lib/restore-drill-orgo.sh bin/lib/lane-gate.sh; do
    scratch_install_closure "$S" "$H" >/dev/null || { bad "scratch_install_closure $S failed"; return 1; }
  done
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$ALERT_LOG"\n' > "$H/bin/alert-line.sh"; chmod +x "$H/bin/alert-line.sh"
  : > "$H/env/global.env"
  if [ "${1:-}" = two ]; then
    echo '{"accounts":{"main":{"key_env":"ORGO_API_KEY"},"second":{"key_env":"FIXTURE_ORGO_KEY2"}}}' > "$H/catalog/orgo-plans.json"
  else
    echo '{"accounts":{"main":{"key_env":"ORGO_API_KEY"}}}' > "$H/catalog/orgo-plans.json"
  fi
  : > "$C/curl.log"; : > "$C/alert.log"; : > "$C/boxops.log"
}
run() { # run [VAR=value ...] -> RC; ORGO_API_KEY and FIXTURE_ORGO_KEY2 only as given
  env -u ORGO_API_KEY -u FIXTURE_ORGO_KEY2 PATH="$FB:$PATH" HARNESS="$H" HARNESS_TEST_SANDBOX=1 HOSTNAME=hub-fixture \
    ORGO_API_BASE=https://orgo.fixture/api LANE_GATE_DISABLE=1 BOX_WATCH_BOX_OPS="$FB/box-ops" \
    JOBS_URL= HARNESS_SECRET= CURL_LOG="$C/curl.log" ALERT_LOG="$C/alert.log" BOXOPS_LOG="$C/boxops.log" \
    "$@" bash "$H/bin/box-watch.sh" lever-check </dev/null >"$C/out" 2>&1
  RC=$?
  cat "$C/out" "$H/logs/box-watch.log" "$C/alert.log" "$C/curl.log" >> "$T/all-output" 2>/dev/null
}
n() { [ -s "$1" ] && grep -c . "$1" || echo 0; }
orgo_calls() { grep -c 'orgo.fixture' "$C/curl.log"; }
warns() { grep -c -- "^--severity warn --id orgo-lever-$1 " "$C/alert.log"; }
resolved() { grep -c -- "^--severity resolved --id orgo-lever-$1 " "$C/alert.log"; }
ctx() { echo "rc=$RC out=[$(cat "$C/out")] alerts=[$(cat "$C/alert.log")] curl=[$(cat "$C/curl.log")] log=[$(cat "$H/logs/box-watch.log" 2>/dev/null)]"; }
noboxops() { [ "$(n "$C/boxops.log")" = 0 ] && ok || bad "$1: box-ops was called: $(cat "$C/boxops.log")"; }

# ---- L1 unset ----
new_harness
run
[ "$RC" = 0 ] && ok || bad "L1 rc $(ctx)"
[ "$(n "$C/alert.log")" = 1 ] && [ "$(warns ORGO_API_KEY)" = 1 ] && ok || bad "L1 exactly one warn orgo-lever-ORGO_API_KEY $(ctx)"
WANT=$(HOSTNAME=hub-fixture bash -c '. "$1"; orgo_lever_text ORGO_API_KEY unset' _ "$H/bin/lib/orgo-lever.sh")
GOT=$(sed 's/^--severity warn --id orgo-lever-ORGO_API_KEY //' "$C/alert.log")
[ "$GOT" = "$WANT" ] && ok || bad "L1 text equals orgo_lever_text: got [$GOT] want [$WANT]"
[ "$(orgo_calls)" = 0 ] && ok || bad "L1 no Orgo call with the key unset"
noboxops L1

# ---- L2 401 ----
new_harness
run ORGO_API_KEY="$KEY" ORGO_CODE=401
[ "$(warns ORGO_API_KEY)" = 1 ] && [ "$(resolved ORGO_API_KEY)" = 0 ] && ok || bad "L2 one warn $(ctx)"
grep -q 'ORGO_API_KEY answered HTTP 401 on GET /workspaces' "$C/alert.log" && ok || bad "L2 text names the key and HTTP 401: $(cat "$C/alert.log")"
noboxops L2

# ---- L3 200 / 204 ----
for CODE in 200 204; do
  new_harness
  run ORGO_API_KEY="$KEY" ORGO_CODE=$CODE
  [ "$(warns ORGO_API_KEY)" = 0 ] && [ "$(resolved ORGO_API_KEY)" = 1 ] && ok || bad "L3[$CODE] no warn, one retraction $(ctx)"
  [ "$(orgo_calls)" = 1 ] && grep -q '^GET https://orgo.fixture/api/workspaces m=30 ' "$C/curl.log" && ok || bad "L3[$CODE] one GET /workspaces with -m 30: $(cat "$C/curl.log")"
  noboxops "L3[$CODE]"
done
# The settings row box_watch.orgo_timeout_s sets curl -m.
new_harness
jq -nc --argjson fa "$(date -u +%s)" '{fetched_at:$fa, values:{"box_watch.orgo_timeout_s":"7"}, seeded:{}}' > "$H/state/settings-cache.json"
run ORGO_API_KEY="$KEY" LANE_GATE_CACHE_S=999999999
grep -q 'm=7 ' "$C/curl.log" && ok || bad "L3 row orgo_timeout_s 7: $(cat "$C/curl.log")"

# ---- L4 timeout ----
new_harness
run ORGO_API_KEY="$KEY" ORGO_HANG=1
[ "$(warns ORGO_API_KEY)" = 1 ] && grep -q 'answered HTTP 000 on GET /workspaces' "$C/alert.log" && ok || bad "L4 timeout = one warn with HTTP 000 $(ctx)"
noboxops L4

# ---- L6 kill flag ----
new_harness
touch "$H/flags/lane-off-box-watch"
run ORGO_API_KEY="$KEY" LANE_GATE_DISABLE=0 LANE_START_SPREAD_S=0
[ "$(orgo_calls)" = 0 ] && [ "$(n "$C/alert.log")" = 0 ] && ok || bad "L6 kill flag: no call, no alert $(ctx)"
noboxops L6

# ---- L7 two accounts ----
new_harness two
run ORGO_API_KEY="$KEY" ORGO_CODE=200
[ "$(warns FIXTURE_ORGO_KEY2)" = 1 ] && [ "$(warns ORGO_API_KEY)" = 0 ] && [ "$(resolved ORGO_API_KEY)" = 1 ] && ok || bad "L7 one warn for the second key only $(ctx)"
new_harness two
run ORGO_API_KEY="$KEY" FIXTURE_ORGO_KEY2="$KEY2" ORGO_CODE=200
[ "$(grep -c -- '--severity warn' "$C/alert.log")" = 0 ] && [ "$(orgo_calls)" = 2 ] && ok || bad "L7 both keys fine: no warn, two reads $(ctx)"
noboxops L7

# ---- L5 no key value anywhere ----
if grep -q -e "$KEY" -e "$KEY2" "$T/all-output"; then bad "L5 a key value reached an output: $(grep -o -e "$KEY" -e "$KEY2" "$T/all-output" | sort | uniq -c)"; else ok; fi

echo "box-watch-lever.bh-10231-test: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
