#!/bin/bash
# tests/dbus-session-leak-test.sh — the 2026-11-09 dbus-daemon leak (box-small
# OOM three times; 3,705 orphan session buses). Proves the three parts of the fix:
#   1. bin/gh-ledger/gh exports DBUS_SESSION_BUS_ADDRESS=disabled: when it is unset,
#      and keeps a bus the box already set.
#   2. every cron/boxes/*/000-path.cron sets DBUS_SESSION_BUS_ADDRESS=disabled:.
#   3. bin/dbus-orphan-reap.sh kills an old orphan `dbus-daemon --session` and keeps
#      a young one (Linux with /proc only; skipped elsewhere).
set -u
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# ---- 1. shim ------------------------------------------------------------------
mkdir -p "$T/real" "$T/h/flags"
cat > "$T/real/gh" <<'STUB'
#!/bin/bash
printf '%s' "${DBUS_SESSION_BUS_ADDRESS-<unset>}"
STUB
chmod +x "$T/real/gh"
OUT=$(env -u DBUS_SESSION_BUS_ADDRESS HARNESS="$T/h" GH_LEDGER_OFF=1 GH_LEDGER_REAL="$T/real/gh" \
  PATH="$DIR/bin/gh-ledger:/usr/bin:/bin" gh auth token 2>/dev/null)
[ "$OUT" = "disabled:" ] && ok || bad "1a unset bus: real gh saw '$OUT', want 'disabled:'"
OUT=$(DBUS_SESSION_BUS_ADDRESS="unix:path=/tmp/x" HARNESS="$T/h" GH_LEDGER_OFF=1 GH_LEDGER_REAL="$T/real/gh" \
  PATH="$DIR/bin/gh-ledger:/usr/bin:/bin" gh auth token 2>/dev/null)
[ "$OUT" = "unix:path=/tmp/x" ] && ok || bad "1b existing bus: real gh saw '$OUT', want it kept"

# ---- 2. cron ------------------------------------------------------------------
N=0
for f in "$DIR"/cron/boxes/*/000-path.cron; do
  N=$((N+1))
  grep -qx 'DBUS_SESSION_BUS_ADDRESS=disabled:' "$f" && ok || bad "2 $f has no DBUS_SESSION_BUS_ADDRESS=disabled: line"
  [ "$(grep -v '^#' "$f" | head -1 | cut -c1-5)" = "PATH=" ] && ok || bad "2 $f: PATH= is no longer the first setting"
done
[ "$N" -ge 5 ] && ok || bad "2 vacuous: only $N 000-path.cron files"

# ---- 3. reaper ----------------------------------------------------------------
# A fake `ps` on PATH lists three `sleep` processes as orphan session buses, so
# the test kills only its own sleeps and never a real dbus-daemon. A fake uptime
# file (DBUS_REAP_UPTIME_FILE) makes the result independent of how long the host
# has been up: a fresh runner has a short uptime, and OLD (7200 s) would then
# count as a boot-time bus (lead review of #9603).
if true; then
  UPT=100000
  printf '%s.00 0.00\n' "$UPT" > "$T/uptime"
  sleep 300 & OLD=$!
  sleep 300 & YOUNG=$!
  sleep 300 & BOOT=$!
  mkdir -p "$T/fakebin"
  cat > "$T/fakebin/ps" <<FAKE
#!/bin/bash
echo "\$\$ 1 5 /usr/bin/bash"
echo "$OLD 1 7200 /usr/bin/dbus-daemon --syslog --fork --print-pid 4 --print-address 6 --session"
echo "$YOUNG 1 10 /usr/bin/dbus-daemon --syslog --fork --print-pid 4 --print-address 6 --session"
echo "$BOOT 1 $((UPT - 5)) /usr/bin/dbus-daemon --syslog --fork --print-pid 4 --print-address 6 --session"
echo "1 0 $UPT dbus-daemon --system --fork"
FAKE
  chmod +x "$T/fakebin/ps"
  reap() { env PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_TEST_SANDBOX=1 DBUS_REAP_UPTIME_FILE="$T/uptime" "$@" bash "$DIR/bin/dbus-orphan-reap.sh" 2>/dev/null; }
  # 3a: a floor above OLD's age (env, read through the knob) kills nothing.
  OUT=$(reap DBUS_REAP_MIN_AGE_S=10000)
  kill -0 "$OLD" 2>/dev/null && ok || bad "3a OLD killed under a 10000 s floor"
  # 3b: the off switch.
  touch "$T/h/flags/dbus-orphan-reap-off"
  OUT=$(reap)
  { [ -z "$OUT" ] && kill -0 "$OLD" 2>/dev/null; } && ok || bad "3b the off switch did not stop the reaper: '$OUT'"
  rm -f "$T/h/flags/dbus-orphan-reap-off"
  # 3c: the defaults (3600 s floor, 600 s boot grace) kill OLD only.
  OUT=$(reap); sleep 0.3
  kill -0 "$OLD" 2>/dev/null && bad "3c OLD (7200 s) survived" || ok
  kill -0 "$YOUNG" 2>/dev/null && ok || bad "3c YOUNG (10 s) was killed"
  kill -0 "$BOOT" 2>/dev/null && ok || bad "3c the boot-time bus was killed"
  grep -q '^dbus-orphan-reap: killed 1 .*kept 1 boot-time' <<<"$OUT" && ok || bad "3c summary line: '$OUT'"
  # 3d: an out-of-range value falls back to the default (min 300).
  sleep 300 & OLD2=$!
  sed "s/^echo \"$OLD /echo \"$OLD2 /" "$T/fakebin/ps" > "$T/ps.new" && cat "$T/ps.new" > "$T/fakebin/ps"
  OUT=$(reap DBUS_REAP_MIN_AGE_S=5); sleep 0.3
  kill -0 "$YOUNG" 2>/dev/null && ok || bad "3d MIN_AGE=5 was obeyed (below min 300): YOUNG killed"
  kill "$YOUNG" "$BOOT" "$OLD2" 2>/dev/null; wait 2>/dev/null
fi
bash -n "$DIR/bin/dbus-orphan-reap.sh" && ok || bad "3 syntax"

echo "dbus-session-leak: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
