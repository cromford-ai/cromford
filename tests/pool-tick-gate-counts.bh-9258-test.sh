#!/bin/bash
# tests/pool-tick-gate-counts.bh-9258-test.sh — BH-9258 (#9061 Fix 4): the hub
# lane bin/pool-tick-summary.sh adds today's selection-gate counts to each pool
# project's row (gates_today), read from builds/pool-<P>-*/gate.txt by
# bin/lib/sg-day-counts.sh.
#
# DRIVEN, NOT GREPPED. Every case runs the shipped script in a scratch harness
# with a stub curl that records every request. No network.
#   P1  the POSTed row of pool project p carries gates_today equal to the seeded
#       gate.txt files; project q (no file) carries zeros; the whole body equals
#       the committed fixture the worker test POSTs
#       (tests/fixtures/pool-tick-gate-counts.bh-9258/post.json)
#   P2  the run log line carries gates=<sum> unattributed=<sum>
#   P3  with bin/lib/sg-day-counts.sh removed the row carries gates_today null
#       and the POST still goes
# Run: HARNESS_TEST_SANDBOX=1 bash tests/pool-tick-gate-counts.bh-9258-test.sh   (exit 0 = pass)
# Rewrite the fixture after a deliberate format change:
#   PTG_WRITE_FIXTURE=1 HARNESS_TEST_SANDBOX=1 bash tests/pool-tick-gate-counts.bh-9258-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
FIX="$DIR/tests/fixtures/pool-tick-gate-counts.bh-9258/post.json"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "pool-tick-gate-counts.bh-9258-test: SKIPPED — jq missing"; exit 0; }
command -v flock >/dev/null || { echo "pool-tick-gate-counts.bh-9258-test: SKIPPED — flock missing"; exit 0; }

FB="$T/fakebin"; mkdir -p "$FB"
cat > "$FB/curl" <<'CURL'
#!/bin/bash
URL="${!#}"; BODY=""; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in -X) METHOD="$2"; shift 2;; --data-binary) BODY="$2"; shift 2;; *) shift;; esac
done
case "$BODY" in @*) BODY=$(cat "${BODY#@}") ;; esac
printf '%s %s %s\n' "$METHOD" "$URL" "$BODY" >> "$REQ_SINK"
printf '{"written":2,"rejected":0}\n200\n'
CURL
chmod +x "$FB/curl"

NOW=$(date -u -d '2026-11-08 12:00:00' +%s)
HN=0
new_harness() { # new_harness project... -> H
  HN=$((HN+1)); H="$T/h$HN"
  mkdir -p "$H/logs" "$H/env" "$H/locks" "$H/flags" "$H/builds" "$H/bin/lib"
  for S in bin/pool-tick-summary.sh bin/jobs-client.sh bin/alert-line.sh; do
    scratch_install_closure "$S" "$H" >/dev/null || { bad "scratch_install_closure $S failed"; return 1; }
  done
  echo "HARNESS_SECRET=sec-fixture-9258" > "$H/env/global.env"
  local p; for p in "$@"; do touch "$H/flags/fly-pool-$p"; done
  : > "$T/req.log"
}
gate() { # gate <dir name> <touch date> <gate.txt line>...
  local d="$H/builds/$1" when="$2"; shift 2
  mkdir -p "$d"; printf '%s\n' "head: 0000000000000000000000000000000000000000" "$@" > "$d/gate.txt"
  touch -d "$when" "$d/gate.txt"
}
run_lane() {
  env PATH="$FB:$PATH" HARNESS="$H" JOBS_URL="http://jobs.fixture.test" HARNESS_SECRET="sec-fixture-9258" \
    LANE_GATE_DISABLE=1 POOL_TICK_SUMMARY_NOW="$NOW" REQ_SINK="$T/req.log" \
    bash "$H/bin/pool-tick-summary.sh" </dev/null >/dev/null 2>&1
  RC=$?
}
posts() { grep -c '^POST [^ ]*/api/pool/tick-summary ' "$T/req.log"; }
body() { grep '^POST [^ ]*/api/pool/tick-summary ' "$T/req.log" | tail -1 | cut -d' ' -f3-; }
gt() { jq -c --arg p "$1" '.rows[] | select(.project == $p) | .gates_today' <<<"$(body)"; }

seed() {
  gate pool-p-BH-1-202611080100 '2026-11-08 01:00:00Z' 'rc: 0' 'red: -'
  gate pool-p-BH-2-202611080200 '2026-11-08 02:00:00Z' 'rc: 1' 'red: tests/a.sh'
  gate pool-p-BH-3-202611080300 '2026-11-08 03:00:00Z' 'rc: 1' 'red: tests/a.sh' 'unattributed: tests/a.sh'
  gate pool-p-BH-4-202611080400 '2026-11-08 04:00:00Z' 'rc: could-not-run' 'red: -'
  gate pool-p-BH-5-202611072359 '2026-11-07 23:59:59Z' 'rc: 1' 'unattributed: tests/b.sh'
}

# ---- P1 P2 ----
new_harness p q
seed
run_lane
[ "$RC" = 0 ] && ok || bad "P1 rc=$RC"
[ "$(posts)" = 1 ] && ok || bad "P1 posts=$(posts)"
[ "$(gt p)" = '{"day":"2026-11-08","gates":4,"rc0":1,"rc1_attributed":1,"rc1_unattributed":1,"could_not_run":1}' ] \
  && ok || bad "P1 p gates_today: $(gt p)"
[ "$(gt q)" = '{"day":"2026-11-08","gates":0,"rc0":0,"rc1_attributed":0,"rc1_unattributed":0,"could_not_run":0}' ] \
  && ok || bad "P1 q gates_today: $(gt q)"
if [ "${PTG_WRITE_FIXTURE:-0}" = 1 ]; then
  mkdir -p "$(dirname "$FIX")"; body | jq -S . > "$FIX"; echo "wrote $FIX"
fi
if [ -f "$FIX" ] && [ "$(body | jq -S -c .)" = "$(jq -S -c . "$FIX")" ]; then ok
else bad "P1 the POST body differs from $FIX: $(body)"; fi
grep -q 'projects=2 ticks=0 decisions=0 POST rc=0 http=200 gates=4 unattributed=1$' "$H/logs/pool-tick-summary.log" \
  && ok || bad "P2 log: $(cat "$H/logs/pool-tick-summary.log" 2>/dev/null)"

# ---- P3 ----
new_harness p
seed
rm -f "$H/bin/lib/sg-day-counts.sh"
run_lane
[ "$RC" = 0 ] && ok || bad "P3 rc=$RC"
[ "$(posts)" = 1 ] && ok || bad "P3 posts=$(posts)"
[ "$(gt p)" = null ] && ok || bad "P3 gates_today with no lib: $(gt p)"
jq -e '.rows[0] | has("gates_today")' <<<"$(body)" >/dev/null && ok || bad "P3 the row has no gates_today key: $(body)"
grep -q 'gates=- unattributed=-' "$H/logs/pool-tick-summary.log" && ok || bad "P3 log: $(cat "$H/logs/pool-tick-summary.log" 2>/dev/null)"

echo "pool-tick-gate-counts.bh-9258-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
