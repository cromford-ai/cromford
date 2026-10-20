#!/bin/bash
# tests/pool-idle-knob.bh-7656-test.sh — BH-7656: a pool machine's idle window
# before autostop is a settings row, not the fixed 600 s. _pool_idle_timeout is
# lifted verbatim out of fly/builder-runner.sh and driven against a stub
# bin/jobs-client.sh that answers `setting-get` from files.
#
#   K1  env POOL_IDLE_TIMEOUT_S=900 -> 900, no settings read
#   K2  project row 1200 over lane row 900 -> 1200
#   K3  lane row only, 900 -> 900
#   K4  no rows -> 600
#   K5  row `abc` -> 600 and one log line
#   K6  row `30` and row `7201` -> 600 and one log line each; 60 and 7200 pass
#   K7  the settings read fails (rc 1 from the client) -> 600
#   K8  the main loop calls _pool_idle_timeout before the idle wait
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/pool-idle-knob.bh-7656-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
RUNNER="$DIR/fly/builder-runner.sh"
[ -f "$RUNNER" ] || { echo "FAIL: fly/builder-runner.sh is missing"; exit 1; }

H="$T/h"; mkdir -p "$H/bin" "$T/settings"
# The jobs client: `setting-get <key>` prints the file's value (rc 0), a missing
# file is rc 2 (a 404), and the marker settings-down is a transport failure.
cat > "$H/bin/jobs-client.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/calls"
[ "\$1" = setting-get ] || exit 1
[ -e "$T/settings-down" ] && exit 1
[ -f "$T/settings/\$2" ] || { echo; exit 2; }
cat "$T/settings/\$2"; echo
EOF
chmod +x "$H/bin/jobs-client.sh"

awk '/^_pool_idle_timeout\(\) \{/,/^\}/' "$RUNNER" > "$T/idle.sh"
grep -q '^_pool_idle_timeout()' "$T/idle.sh" || { echo "FAIL: could not lift _pool_idle_timeout out of fly/builder-runner.sh"; exit 1; }

# idle [env-value] — prints the window; the log goes to $T/log.
idle() {
  : > "$T/calls"
  ( HARNESS="$H"; PROJECT=demo-os; IDLE_TIMEOUT_DEFAULT=600
    if [ -n "${1:-}" ]; then export POOL_IDLE_TIMEOUT_S="$1"; else unset POOL_IDLE_TIMEOUT_S; fi
    log() { echo "$*" >> "$T/log"; }
    # shellcheck source=/dev/null
    . "$T/idle.sh"
    _pool_idle_timeout 2>/dev/null )
}
row()   { printf '%s' "$2" > "$T/settings/$1"; }
reset() { rm -f "$T/settings/"* "$T/settings-down"; : > "$T/log"; }
logs()  { wc -l < "$T/log" | tr -d ' '; }
PK=lane.fly-pool.demo-os.pool_idle_timeout_s
LK=lane.fly-pool.pool_idle_timeout_s

# K1
reset; row "$PK" 1200
[ "$(idle 900)" = 900 ] && ok || bad "K1 env 900 wins (got $(idle 900))"
[ ! -s "$T/calls" ] && ok || bad "K1 env set: no settings read ($(cat "$T/calls"))"

# K2
reset; row "$PK" 1200; row "$LK" 900
[ "$(idle)" = 1200 ] && ok || bad "K2 the project row wins over the lane row (got $(idle))"

# K3
reset; row "$LK" 900
[ "$(idle)" = 900 ] && ok || bad "K3 the lane row (got $(idle))"
grep -q "setting-get $PK" "$T/calls" && grep -q "setting-get $LK" "$T/calls" \
  && ok || bad "K3 the project row is read first, then the lane row ($(cat "$T/calls"))"

# K4
reset
[ "$(idle)" = 600 ] && ok || bad "K4 no rows -> 600 (got $(idle))"
[ "$(logs)" = 0 ] && ok || bad "K4 no log line ($(cat "$T/log"))"

# K5
reset; row "$PK" abc
[ "$(idle)" = 600 ] && ok || bad "K5 abc -> 600 (got $(idle))"
reset; row "$PK" abc; idle >/dev/null
[ "$(logs)" = 1 ] && grep -q 'idle window abc out of range — using 600' "$T/log" \
  && ok || bad "K5 one log line ($(cat "$T/log"))"

# K6
for v in 30 7201 99999999999999999999; do
  reset; row "$PK" "$v"
  out=$(idle)
  [ "$out" = 600 ] && [ "$(logs)" = 1 ] && grep -q "idle window $v out of range" "$T/log" \
    && ok || bad "K6 $v -> 600 and one log line (got $out; log: $(cat "$T/log"))"
done
for v in 60 7200; do
  reset; row "$PK" "$v"
  out=$(idle)
  [ "$out" = "$v" ] && [ "$(logs)" = 0 ] && ok || bad "K6 the bound $v is taken (got $out)"
done
reset
out=$(idle 30)
[ "$out" = 600 ] && [ "$(logs)" = 1 ] && ok || bad "K6 an out-of-range env value is refused too (got $out)"

# K7
reset; row "$PK" 1200; : > "$T/settings-down"
out=$(idle)
[ "$out" = 600 ] && ok || bad "K7 settings read fails -> 600 (got '$out')"

# K8 — the main loop reads the window before every idle wait, and nothing reads
# the old constant.
grep -q '^IDLE_TIMEOUT=600' "$RUNNER" && bad "K8 the fixed IDLE_TIMEOUT=600 is still there" || ok
awk '/^while true; do/,0' "$RUNNER" | grep -q 'IDLE_TIMEOUT=$(_pool_idle_timeout)' \
  && ok || bad "K8 the main loop does not call _pool_idle_timeout"

echo "pool-idle-knob: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
