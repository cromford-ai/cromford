#!/bin/bash
# tests/spend-lane-push.bh-6174-test.sh — the hub pushes each lane's p99 line
# to D1 for Mission Control (BH-6174, BH-5526 slice C4). bin/spend-lane-push.sh
# writes one `ledgers` row per lane (kind spend_p99, key <lane>, status <day>,
# detail `p99=<p> days=<d> mult=<m> alert=<a>`); GET /api/metrics/lane-spend
# reads them back beside the lane's spend today and its ceiling.
#
#   P1  the filter: lane axis, p99 > 0, a registry id or a stage-<s> id only
#   P2  the detail line and the stdout line for one lane
#   P3  status evidence: a PUT answered with another day is `error`, rc 1; an
#       empty registry is rc 1 with 0 PUTs; no --day is rc 2
#   P4  the `# >>> spend lane push` block on a failed day: no marker, one
#       spendlanepush:fleet alert (TTL 86400); the retry pushes and adds none
#   P5  the block on a good day: the marker, the older marker removed, the log
#       line, a second drive makes 0 requests, no settings or flags write; no
#       baseline today makes 0 requests
#   P6  the multiplier: no knob row is 1.5, a knob row 2 is 2; --dry-run
#   R1  round trip: the real pusher over real curl into the REAL worker, read
#       back through GET /api/metrics/lane-spend
#
# Drives the real pusher and jobs client against a fake curl worker (P1-P6)
# and the real worker on node:sqlite (R1); asserts on artifacts only.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/spend-lane-push.bh-6174-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
NOW=$(date -u +%s)
DAYC=$(date -u -d "@$NOW" +%Y%m%d)
DAYD=$(date -u -d "@$NOW" +%F)

# --- fixture -----------------------------------------------------------------
mkdir -p "$T/fakebin" "$T/flags" "$T/bin/lib/jobs" "$T/logs" "$T/state/spend-alerts" "$T/catalog"
scratch_install_closure bin/jobs-client.sh "$T" >/dev/null || { echo "cannot install the closure of bin/jobs-client.sh"; exit 1; }
PUSHER_OK=0
if [ -f "$DIR/bin/spend-lane-push.sh" ]; then
  scratch_install_closure bin/spend-lane-push.sh "$T" >/dev/null && PUSHER_OK=1
fi
[ "$PUSHER_OK" = 1 ] && ok || bad "bin/spend-lane-push.sh is missing or its closure cannot be installed"
PUSH="$T/bin/spend-lane-push.sh"
cat > "$T/catalog/lanes.json" <<'EOF'
{"version":1,"lanes":[{"id":"fly-pool"},{"id":"alert-triage"}]}
EOF
printf 'lane\tfly-pool\t100.00\t14\nlane\tstage-review\t3.10\t9\nproject\tacme\t40.00\t14\nlane\talert-triage\t0.00\t12\nlane\texecute\t7.00\t14\nlane\tBad Lane\t5.00\t14\n' > "$T/base.tsv"
# The worker.
#   PUT /api/ledger -> answers the row it was sent; $T/wrongday holding a key
#                      answers that key with status 20200101; $T/down: 500
# Every request goes to $REQ_LOG, every PUT body to $PUT_LOG.
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; M=GET; BODY=""
while [ $# -gt 0 ]; do
  case "$1" in -X) M="$2"; shift ;; --data-binary) BODY="$2"; shift ;; esac
  shift
done
printf '%s %s\n' "$M" "$URL" >> "$REQ_LOG"
D=$(dirname "$REQ_LOG")
case "$M $URL" in
  "PUT "*/api/ledger)
    printf '%s\n' "$BODY" >> "$PUT_LOG"
    [ -e "$D/down" ] && { printf '{"error":"fixture down"}\n500\n'; exit 0; }
    k=$(printf '%s' "$BODY" | jq -r .key)
    if grep -qxF "$k" "$D/wrongday" 2>/dev/null; then
      printf '%s' "$BODY" | jq -c '{ledger:{kind, key, status:"20200101", detail, actor}}'
    else
      printf '%s' "$BODY" | jq -c '{ledger:{kind, key, status, detail, actor}}'
    fi
    echo 200 ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/"*
ENVS=(REQ_LOG="$T/req.log" PUT_LOG="$T/put.log" PATH="$T/fakebin:$PATH" HARNESS="$T" HOME="$T"
      HARNESS_SECRET=fixture-secret JOBS_URL=https://jobs.invalid JOBS_RETRIES=0 JOBS_BOX=hub)
reset() { : > "$T/req.log"; : > "$T/put.log"; rm -f "$T/wrongday" "$T/down"; }
push() { # push [args...] -> stdout of the real pusher; rc in $T/push.rc
  ( export "${ENVS[@]}"; bash "$PUSH" --baseline "$T/base.tsv" --registry "$T/catalog/lanes.json" "$@" 2>"$T/push.err" )
  echo $? > "$T/push.rc"
}
keys() { jq -r '.key' "$T/put.log" 2>/dev/null | LC_ALL=C sort | paste -sd, -; }
detail_of() { jq -r --arg k "$1" 'select(.key==$k) | .detail' "$T/put.log" 2>/dev/null | tail -1; }
nledger() { grep -c '/api/ledger' "$T/req.log"; }

# =============================================================================
# P1 — the filter
# =============================================================================
reset; OUT=$(push --day "$DAYC" --mult 1.5)
[ "$(cat "$T/push.rc")" = 0 ] && ok || bad "P1 pusher rc=$(cat "$T/push.rc") ($(cat "$T/push.err" 2>/dev/null))"
[ "$(keys)" = "fly-pool,stage-review" ] && ok || bad "P1 PUT keys [$(keys)], want fly-pool,stage-review"
[ "$(jq -r '"\(.kind) \(.status) \(.actor)"' "$T/put.log" 2>/dev/null | sort -u)" = "spend_p99 $DAYC hub" ] && ok \
  || bad "P1 PUT kind/status/actor: $(jq -c '{kind,status,actor}' "$T/put.log" 2>/dev/null)"
grep -q 'acme\|alert-triage\|execute\|Bad' "$T/put.log" && bad "P1 a non-candidate was pushed: $(cat "$T/put.log")" || ok

# P2 — the detail
[ "$(detail_of fly-pool)" = "p99=100.00 days=14 mult=1.5 alert=150.00" ] && ok || bad "P2 fly-pool detail: '$(detail_of fly-pool)'"
[ "$(detail_of stage-review)" = "p99=3.10 days=9 mult=1.5 alert=4.65" ] && ok || bad "P2 stage-review detail: '$(detail_of stage-review)'"
grep -qx 'pushed fly-pool alert=150.00' <<<"$OUT" && ok || bad "P2 stdout: [$OUT]"

# =============================================================================
# P3 — status evidence, bad input
# =============================================================================
reset; echo fly-pool > "$T/wrongday"; OUT=$(push --day "$DAYC" --mult 1.5)
[ "$(cat "$T/push.rc")" = 1 ] && ok || bad "P3 a PUT answered with another day: rc=$(cat "$T/push.rc"), want 1"
grep -qx 'error fly-pool ledger-write' <<<"$OUT" && ok || bad "P3 stdout: [$OUT]"
grep -q '^pushed fly-pool' <<<"$OUT" && bad "P3 claimed a write that did not land: [$OUT]" || ok
grep -q '^pushed stage-review' <<<"$OUT" && ok || bad "P3 the other lane was not pushed: [$OUT]"
reset; echo '{}' > "$T/empty-reg.json"
( export "${ENVS[@]}"; bash "$PUSH" --baseline "$T/base.tsv" --day "$DAYC" --mult 1.5 --registry "$T/empty-reg.json" >/dev/null 2>&1 ); RC=$?
[ "$RC" = 1 ] && [ "$(nledger)" = 0 ] && ok || bad "P3 empty registry: rc=$RC requests=$(nledger), want 1 and 0"
( export "${ENVS[@]}"; bash "$PUSH" --baseline "$T/base.tsv" --mult 1.5 --registry "$T/catalog/lanes.json" >/dev/null 2>&1 ); RC=$?
[ "$RC" = 2 ] && ok || bad "P3 no --day: rc=$RC, want 2"
( export "${ENVS[@]}"; bash "$PUSH" --baseline "$T/base.tsv" --day 2026-10-12 --mult 1.5 --registry "$T/catalog/lanes.json" >/dev/null 2>&1 ); RC=$?
[ "$RC" = 2 ] && ok || bad "P3 a dashed --day: rc=$RC, want 2"
( export "${ENVS[@]}"; bash "$PUSH" --baseline "$T/base.tsv" --day "$DAYC" --mult x --registry "$T/catalog/lanes.json" >/dev/null 2>&1 ); RC=$?
[ "$RC" = 2 ] && ok || bad "P3 --mult x: rc=$RC, want 2"
( export "${ENVS[@]}"; bash "$PUSH" --baseline "$T/nope.tsv" --day "$DAYC" --mult 1.5 --registry "$T/catalog/lanes.json" >/dev/null 2>&1 ); RC=$?
[ "$RC" = 1 ] && [ "$(nledger)" = 0 ] && ok || bad "P3 unreadable baseline: rc=$RC requests=$(nledger), want 1 and 0"

# =============================================================================
# P6 — dry run (the knob half is driven through the block below)
# =============================================================================
reset; OUT=$(push --day "$DAYC" --mult 1.5 --dry-run)
[ "$(cat "$T/push.rc")" = 0 ] && [ "$(nledger)" = 0 ] && ok || bad "P6 --dry-run: rc=$(cat "$T/push.rc") requests=$(nledger)"
grep -qx 'would-push fly-pool alert=150.00 p99=100.00 days=14' <<<"$OUT" && ok || bad "P6 --dry-run stdout: [$OUT]"
grep -q '^pushed' <<<"$OUT" && bad "P6 --dry-run claimed a write: [$OUT]" || ok

# --- the pipeline-health block -----------------------------------------------
H="$T"
awk '/^# >>> spend lane push/{f=1;next} /^# <<< spend lane push/{exit} f' "$DIR/bin/pipeline-health.sh" > "$H/blk.sh"
[ -s "$H/blk.sh" ] && ok || bad "no '# >>> spend lane push' block in bin/pipeline-health.sh"
awk '/^sa_knob\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$DIR/bin/pipeline-health.sh" > "$H/sa-knob.sh"
cat > "$H/bin/ph-driver.sh" <<'SH'
#!/bin/bash
set -uo pipefail
H="$HARNESS"; NOW=$(date -u +%s)
STAMP() { date -u -d "@$NOW" '+%Y-%m-%d %H:%M:%SZ'; }
alert() { printf '%s\t%s\t%s\n' "$2" "$1" "$3" >> "$H/alerts.rec"; }
lane_knob() { [ "$1" = pipeline-health ] || return 0; awk -F= -v k="$2" '$1==k{print $2}' "$H/knobs" 2>/dev/null; }
. "$H/sa-knob.sh"
. "$H/blk.sh"
SH
chmod +x "$H/bin/ph-driver.sh"
drive() { ( unset SPEND_ALERT_P99_MULT; export "${ENVS[@]}" LANE_REGISTRY= "$@"; bash "$H/bin/ph-driver.sh" >/dev/null 2>&1 ); }
MARK="$H/state/spend-alerts/lane-pushed-$DAYC"
blk_reset() { reset; : > "$H/alerts.rec"; : > "$H/knobs"; : > "$H/logs/pipeline-health.log"; scratch_rm "$T/state/spend-alerts"; scratch_rm "$T/flags"; mkdir -p "$H/state/spend-alerts" "$H/flags"; cp "$T/base.tsv" "$H/state/spend-alerts/baseline-$DAYC.tsv"; }

# P5 — a good day
blk_reset; touch "$H/state/spend-alerts/lane-pushed-20200101"; drive
[ "$(keys)" = "fly-pool,stage-review" ] && ok || bad "P5 PUT keys [$(keys)]"
[ -f "$MARK" ] && ok || bad "P5 the marker was not written"
[ ! -e "$H/state/spend-alerts/lane-pushed-20200101" ] && ok || bad "P5 an older marker was kept"
grep -q 'spend lane push: pushed fly-pool alert=150.00' "$H/logs/pipeline-health.log" && ok \
  || bad "P5 no pipeline-health.log line: $(cat "$H/logs/pipeline-health.log")"
[ ! -s "$H/alerts.rec" ] && ok || bad "P5 a good day raised an alert: $(cat "$H/alerts.rec")"
grep -q '/api/settings\|/api/flags' "$T/req.log" && bad "P5 the block touched settings or flags: $(cat "$T/req.log")" || ok
[ -z "$(ls -A "$H/flags")" ] && ok || bad "P5 the block wrote under flags/: $(ls "$H/flags")"
: > "$T/req.log"; drive
[ "$(nledger)" = 0 ] && ok || bad "P5 a second drive the same day made $(nledger) ledger requests"
# No baseline today: nothing runs.
blk_reset; rm -f "$H/state/spend-alerts/baseline-$DAYC.tsv"; drive
[ "$(nledger)" = 0 ] && [ ! -f "$MARK" ] && ok || bad "P5 no baseline today: requests=$(nledger) marker=$([ -f "$MARK" ] && echo yes)"

# P4 — a failed day alerts once, the retry pushes every lane
blk_reset; touch "$T/down"; drive
[ ! -f "$MARK" ] && ok || bad "P4 the marker was written after a failure"
[ "$(grep -c . "$H/alerts.rec")" = 1 ] && ok || bad "P4 alerts: $(cat "$H/alerts.rec")"
[ "$(cut -f1,2 "$H/alerts.rec")" = "spendlanepush:fleet	86400" ] && ok || bad "P4 alert key/TTL: $(cut -f1,2 "$H/alerts.rec")"
grep -q 'error fly-pool ledger-write' "$H/alerts.rec" && ok || bad "P4 the alert does not name the error: $(cat "$H/alerts.rec")"
rm -f "$T/down"; : > "$T/put.log"; drive
[ "$(keys)" = "fly-pool,stage-review" ] && ok || bad "P4 retry PUT keys [$(keys)]"
[ -f "$MARK" ] && ok || bad "P4 the retry did not write the marker"
[ "$(grep -c . "$H/alerts.rec")" = 1 ] && ok || bad "P4 the retry added an alert: $(cat "$H/alerts.rec")"

# P6 — the multiplier
blk_reset; drive
[ "$(detail_of fly-pool)" = "p99=100.00 days=14 mult=1.5 alert=150.00" ] && ok || bad "P6 no knob row: '$(detail_of fly-pool)'"
blk_reset; echo SPEND_ALERT_P99_MULT=2 > "$H/knobs"; drive
[ "$(detail_of fly-pool)" = "p99=100.00 days=14 mult=2 alert=200.00" ] && ok || bad "P6 knob row 2: '$(detail_of fly-pool)'"

# =============================================================================
# R1 — round trip: the real pusher over real curl into the real worker
# =============================================================================
R1_SKIP=""
command -v node >/dev/null || R1_SKIP="node missing"
[ -z "$R1_SKIP" ] && [ ! -f "$DIR/catalog/lanes.json" ] && { (cd "$DIR" && bin/lanes-build.sh --write >/dev/null 2>&1) || R1_SKIP="catalog/lanes.json could not be built"; }
SRV_PID=""
trap '[ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null' EXIT
if [ -z "$R1_SKIP" ]; then
  : > "$T/srv.port"
  node "$DIR/tests/lib/lane-spend-worker.bh-6174.mjs" "$T/srv.log" > "$T/srv.port" 2> "$T/srv.err" &
  SRV_PID=$!
  for _ in $(seq 1 200); do [ -s "$T/srv.port" ] && break; kill -0 "$SRV_PID" 2>/dev/null || break; sleep 0.05; done
  PORT=$(head -1 "$T/srv.port")
  if [ -z "$PORT" ]; then
    wait "$SRV_PID"; SRC=$?; SRV_PID=""
    if [ "$SRC" = 3 ]; then R1_SKIP="node:sqlite unavailable"; else bad "R1 the worker did not start: $(cat "$T/srv.err")"; R1_SKIP=failed; fi
  fi
fi
if [ -z "$R1_SKIP" ]; then
  U="http://127.0.0.1:$PORT"
  FX=$( curl -sS -X POST "$U/__cost_row" -d "{\"lane_id\":\"fly-pool\",\"cost_usd\":160,\"ts\":\"${DAYD}T00:30:00Z\"}"
        curl -sS -X POST "$U/__cost_row" -d "{\"lane_id\":\"stage-review\",\"cost_usd\":1,\"ts\":\"${DAYD}T00:30:00Z\"}"
        curl -sS -X PUT "$U/__setting" -d '{"key":"spend.ceiling.fly-pool.day_usd","value":"300"}' )
  [ "$FX" = '{"ok":true}{"ok":true}{"ok":true}' ] && ok || bad "R1 the fixture rows were not written: $FX"
  REG=$(jq -c '{version:1, lanes:[.lanes[] | {id}]}' "$DIR/catalog/lanes.json")
  printf '%s\n' "$REG" > "$T/real-lanes.json"
  OUT=$( export HARNESS="$T" HOME="$T" HARNESS_SECRET=fixture-harness-secret JOBS_URL="$U" JOBS_RETRIES=0 JOBS_BOX=hub
         bash "$PUSH" --baseline "$T/base.tsv" --day "$DAYC" --mult 1.5 --registry "$T/real-lanes.json" 2>&1 ); RC=$?
  [ "$RC" = 0 ] && ok || bad "R1 the pusher against the real worker: rc=$RC [$OUT]"
  G=$(curl -sS -H "authorization: Bearer fixture-harness-secret" "$U/api/metrics/lane-spend?day=$DAYD")
  FP=$(printf '%s' "$G" | jq -c '.lanes[] | select(.lane=="fly-pool") | [.alert_usd, .p99_usd, .p99_days, .ceiling_usd, .today_usd, .over_alert, .over_ceiling]' 2>/dev/null)
  [ "$FP" = "[150,100,14,300,160,true,false]" ] && ok || bad "R1 fly-pool read back: $FP (payload: $(head -c 600 < <(printf '%s' "$G")))"
  [ "$(printf '%s' "$G" | jq -r .p99_day 2>/dev/null)" = "$DAYD" ] && ok || bad "R1 p99_day: $(printf '%s' "$G" | jq -r .p99_day 2>/dev/null)"
  SR=$(printf '%s' "$G" | jq -c '.lanes[] | select(.lane=="stage-review") | [.alert_usd, .today_usd, .registered]' 2>/dev/null)
  [ "$SR" = "[4.65,1,false]" ] && ok || bad "R1 stage-review read back: $SR"
elif [ "$R1_SKIP" != failed ]; then
  echo "SKIP: R1 round trip: $R1_SKIP"
fi

echo "spend-lane-push.bh-6174: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
