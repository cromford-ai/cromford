#!/bin/bash
# tests/box-ssh-probe.bh-7710-test.sh — BH-7710: the hub lane bin/box-ssh-probe.sh
# ssh's every registry box with a tailnet IP once (`ssh root@<ip> true` under
# timeout), counts the pool env bundle ssh failures in
# state/pool-tailnet/<ip>.fails inside the window, and POSTs one row per box
# to /api/box-ssh.
#
# DRIVEN, NOT GREPPED. Every case runs the shipped script in a scratch harness
# (scratch_install_closure: the real jobs client, registry lib and lane gate),
# with a stub curl that records every request, a stub ssh that answers per IP
# from a map file, and a stub timeout that records its first argument. No real
# ssh and no network: the stubs are the only ssh and curl on PATH.
#   L1 two boxes, rc 0 and 255, no knob set: one POST, 2 rows, timeout 15
#   L2 a .fails file: 3 epochs inside 900 s and 2 outside -> lane_fails 3
#   L3 a bad timeout knob: exactly 1 ALERTS line, exit 1, 0 probes, 0 POSTs
#   L4 flags/lane-off-box-ssh-probe: exit 0, 0 probes
#   L5 no registry: exit 0, 1 log line, 0 POSTs
#   L6 the hub row and a box with no tailnet IP are not probed
#   L7 an ssh that hangs past the timeout: rc 124
#   L8 a held lock: exit 0, 0 probes
#   L9 the POST body rows carry the keys of the worker test's fixture
#   L10 the hub crontab renders the lane behind the hub lease
# Run: HARNESS_TEST_SANDBOX=1 bash tests/box-ssh-probe.bh-7710-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LANE="$DIR/bin/box-ssh-probe.sh"
FIX="$DIR/worker/jobs/test/fixtures/box-ssh-post.bh-7710.json"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "box-ssh-probe.bh-7710-test: SKIPPED — jq missing"; exit 0; }
command -v flock >/dev/null || { echo "box-ssh-probe.bh-7710-test: SKIPPED — flock missing"; exit 0; }
[ -f "$LANE" ] || { echo "FAIL: missing $LANE"; exit 1; }

FB="$T/fakebin"; mkdir -p "$FB"
# The stub curl: records "<METHOD> <URL> <BODY>" to $REQ_SINK and answers 200.
cat > "$FB/curl" <<'CURL'
#!/bin/bash
URL="${!#}"; BODY=""; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in -X) METHOD="$2"; shift 2;; --data-binary) BODY="$2"; shift 2;; *) shift;; esac
done
case "$BODY" in @*) BODY=$(cat "${BODY#@}") ;; esac
printf '%s %s %s\n' "$METHOD" "$URL" "$BODY" >> "$REQ_SINK"
printf '{"written":1,"rejected":0}\n200\n'
CURL
# The stub ssh: one line per call to $SSH_LOG, then the rc the map gives the
# IP ("<ip> <rc>" or "<ip> hang"). An IP not in the map is 255.
cat > "$FB/ssh" <<'SSH'
#!/bin/bash
for a in "$@"; do case "$a" in root@*) ip="${a#root@}" ;; esac; done
echo "${ip:-none} $*" >> "$SSH_LOG"
v=$(awk -v ip="${ip:-}" '$1 == ip {print $2}' "$SSH_MAP")
# The sleep IS the hang under test: timeout must kill it.
[ "$v" = hang ] && exec sleep 30   # determinism: ok race-sleep the stub simulates a hung ssh; timeout kills it
exit "${v:-255}"
SSH
# The stub timeout: records the seconds it was given, then runs the real one.
REAL_TIMEOUT=$(command -v timeout)
cat > "$FB/timeout" <<TO
#!/bin/bash
echo "\$1" >> "\$TIMEOUT_LOG"
exec "$REAL_TIMEOUT" "\$@"
TO
chmod +x "$FB/curl" "$FB/ssh" "$FB/timeout"

NOW=1792500000   # a fixed clock: 2026-10-20T12:40:00Z
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

HN=0
new_harness() { # new_harness -> H, a scratch harness with the lane's closure and a registry cache
  HN=$((HN+1)); H="$T/h$HN"
  mkdir -p "$H/logs" "$H/state/registry" "$H/state/pool-tailnet" "$H/env" "$H/locks" "$H/flags"
  # The lane, the jobs client it posts with and the alert writer it calls.
  for S in bin/box-ssh-probe.sh bin/jobs-client.sh bin/alert-line.sh; do
    scratch_install_closure "$S" "$H" >/dev/null || { bad "scratch_install_closure $S failed"; return 1; }
  done
  echo "HARNESS_SECRET=sec-fixture-7710" > "$H/env/global.env"
  cat > "$H/state/registry/registry.json" <<'JSON'
{"version":3,"boxes":[
 {"box":"watcher-alpha","box_id":"alpha","tailnet_ip":"192.0.2.11"},
 {"box":"watcher-bravo","box_id":"bravo","tailnet_ip":"192.0.2.12"},
 {"box":"watcher-hub","box_id":"hub","tailnet_ip":"192.0.2.10","role":"hub"},
 {"box":"watcher-noip","box_id":"noip","tailnet_ip":null},
 {"box":"watcher-old","box_id":"old","tailnet_ip":"192.0.2.13","role":"retired"}
]}
JSON
  printf 'x  o/x  -  -  1  watcher-alpha 192.0.2.11\n' > "$H/state/registry/fleet.conf"
  printf '192.0.2.11 0\n192.0.2.12 255\n' > "$T/ssh.map"
  : > "$T/req.log"; : > "$T/ssh.log"; : > "$T/timeout.log"
}
run_lane() { # run_lane [VAR=value ...] -> RC
  env PATH="$FB:$PATH" HARNESS="$H" JOBS_URL="http://jobs.fixture.test" HARNESS_SECRET="sec-fixture-7710" \
    REGISTRY_CACHE_TTL_S=999999999 LANE_GATE_DISABLE=1 BOX_SSH_PROBE_NOW="$NOW" \
    REQ_SINK="$T/req.log" SSH_LOG="$T/ssh.log" SSH_MAP="$T/ssh.map" TIMEOUT_LOG="$T/timeout.log" \
    "$@" bash "$H/bin/box-ssh-probe.sh" </dev/null >/dev/null 2>&1
  RC=$?
}
posts() { grep -c '^POST [^ ]*/api/box-ssh ' "$T/req.log"; }
body() { grep '^POST [^ ]*/api/box-ssh ' "$T/req.log" | tail -1 | cut -d' ' -f3-; }
probes() { grep -c . "$T/ssh.log"; }
alerts() { grep -c . "$H/logs/ALERTS.log" 2>/dev/null || echo 0; }

# ---- L1 ----
new_harness
run_lane
[ "$RC" = 0 ] && ok || bad "L1 rc=$RC"
[ "$(posts)" = 1 ] && ok || bad "L1 posts=$(posts): $(cat "$T/req.log")"
B=$(body)
[ "$(jq -r '.rows | length' <<<"$B")" = 2 ] && ok || bad "L1 rows: $B"
[ "$(jq -r '[.rows[] | "\(.box)=\(.rc)"] | sort | join(",")' <<<"$B")" = "watcher-alpha=0,watcher-bravo=255" ] && ok || bad "L1 rcs: $B"
[ "$(jq -r '.rows[] | select(.box=="watcher-alpha") | .ip' <<<"$B")" = 192.0.2.11 ] && ok || bad "L1 ip: $B"
[ "$(sort -u "$T/timeout.log")" = 15 ] && ok || bad "L1 timeout given: $(cat "$T/timeout.log")"
grep -q 'BatchMode=yes' "$T/ssh.log" && grep -q ' true$' "$T/ssh.log" && ok || bad "L1 ssh command: $(cat "$T/ssh.log")"
grep -q 'probed 2, answered 1' "$H/logs/box-ssh-probe.log" && ok || bad "L1 log: $(cat "$H/logs/box-ssh-probe.log" 2>/dev/null)"
[ "$(alerts)" = 0 ] && ok || bad "L1 alerts: $(cat "$H/logs/ALERTS.log")"

# ---- L2 ----
new_harness
printf '%s\n' $((NOW - 2000)) $((NOW - 1000)) $((NOW - 800)) $((NOW - 300)) $((NOW - 60)) > "$H/state/pool-tailnet/192.0.2.12.fails"
run_lane
B=$(body)
[ "$(jq -r '.rows[] | select(.box=="watcher-bravo") | .lane_fails' <<<"$B")" = 3 ] && ok || bad "L2 lane_fails: $B"
[ "$(jq -r '.rows[] | select(.box=="watcher-bravo") | .lane_last_fail_at' <<<"$B")" = "$(iso $((NOW - 60)))" ] && ok || bad "L2 last: $B"
[ "$(jq -r '.rows[] | select(.box=="watcher-bravo") | .lane_window_s' <<<"$B")" = 900 ] && ok || bad "L2 window: $B"
[ "$(jq -r '.rows[] | select(.box=="watcher-alpha") | "\(.lane_fails) \(.lane_last_fail_at)"' <<<"$B")" = "0 null" ] && ok || bad "L2 no file: $B"
run_lane POOL_TAILNET_WINDOW_S=1500
B=$(body)
[ "$(jq -r '.rows[] | select(.box=="watcher-bravo") | "\(.lane_fails) \(.lane_window_s)"' <<<"$B")" = "4 1500" ] && ok || bad "L2 window knob: $B"

# ---- L3 ----
for v in abc 0 -5; do
  new_harness
  run_lane BOX_SSH_PROBE_TIMEOUT_S="$v"
  [ "$RC" = 1 ] && ok || bad "L3 $v rc=$RC"
  [ "$(alerts)" = 1 ] && ok || bad "L3 $v alerts=$(alerts)"
  grep -q 'BOX_SSH_PROBE_TIMEOUT_S' "$H/logs/ALERTS.log" && ok || bad "L3 $v alert text: $(cat "$H/logs/ALERTS.log")"
  [ "$(probes)" = 0 ] && [ "$(posts)" = 0 ] && ok || bad "L3 $v probes=$(probes) posts=$(posts)"
done

# ---- L4 ----
new_harness
touch "$H/flags/lane-off-box-ssh-probe"
run_lane LANE_GATE_DISABLE=0 LANE_START_SPREAD_S=0
[ "$RC" = 0 ] && ok || bad "L4 rc=$RC"
[ "$(probes)" = 0 ] && [ "$(posts)" = 0 ] && ok || bad "L4 probes=$(probes) posts=$(posts)"

# ---- L5 ----
new_harness
rm -f "$H/state/registry/registry.json" "$H/state/registry/fleet.conf"
run_lane JOBS_URL=
[ "$RC" = 0 ] && ok || bad "L5 rc=$RC"
[ "$(probes)" = 0 ] && [ "$(posts)" = 0 ] && ok || bad "L5 probes=$(probes) posts=$(posts)"
[ "$(grep -c 'registry' "$H/logs/box-ssh-probe.log" 2>/dev/null)" = 1 ] && ok || bad "L5 log: $(cat "$H/logs/box-ssh-probe.log" 2>/dev/null)"

# ---- L6 ----
new_harness
run_lane
grep -q '192.0.2.10' "$T/ssh.log" && bad "L6 the hub was probed" || ok
grep -q '192.0.2.13' "$T/ssh.log" && bad "L6 a retired box was probed" || ok
[ "$(probes)" = 2 ] && ok || bad "L6 probes=$(probes): $(cat "$T/ssh.log")"
jq -e '.rows | map(.box) | index("watcher-noip") == null and index("watcher-hub") == null' <<<"$(body)" >/dev/null && ok || bad "L6 rows: $(body)"

# ---- L7 ----
new_harness
printf '192.0.2.11 0\n192.0.2.12 hang\n' > "$T/ssh.map"
S0=$(date +%s)
run_lane BOX_SSH_PROBE_TIMEOUT_S=1
S1=$(date +%s)
[ "$(jq -r '.rows[] | select(.box=="watcher-bravo") | .rc' <<<"$(body)")" = 124 ] && ok || bad "L7 rc: $(body)"
[ $((S1 - S0)) -lt 15 ] && ok || bad "L7 took $((S1 - S0)) s"

# ---- L8 ----
new_harness
exec 8>"$H/locks/box-ssh-probe.lock"; flock -n 8
run_lane
exec 8>&-
[ "$RC" = 0 ] && [ "$(probes)" = 0 ] && [ "$(posts)" = 0 ] && ok || bad "L8 rc=$RC probes=$(probes) posts=$(posts)"

# ---- L9 ----
new_harness
run_lane
WANT=$(jq -c '[.rows[0] | keys[]] | sort' "$FIX")
GOT=$(jq -c '[.rows[] | keys | sort] | unique' <<<"$(body)")
[ "$GOT" = "[$WANT]" ] && ok || bad "L9 row keys $GOT, fixture $WANT"

# ---- L10 ----
LINE=$(HARNESS_TEST_SANDBOX=1 "$DIR/bin/render-cron.sh" hub 2>/dev/null | grep -v '^[[:space:]]*#' | grep 'box-ssh-probe')
[ "$(grep -c . <<<"$LINE")" = 1 ] && ok || bad "L10 hub lines: $LINE"
grep -q '^\*/2 \* \* \* \* .*hub-lease.sh check && .*/bin/box-ssh-probe.sh' <<<"$LINE" && ok || bad "L10 line: $LINE"

echo "box-ssh-probe.bh-7710-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
