#!/bin/bash
# bin/dbus-orphan-reap.sh — kill leaked dbus-daemon --session processes on a box.
# Called from bin/lane-reaper.sh (every 10 min, every box). Linux only.
#
# THE INCIDENT (2026-11-01, 11-04, 11-09). box-small ran out of memory
# three times. Each `gh` call from cron had no DBUS_SESSION_BUS_ADDRESS, so gh's
# keyring lookup auto-launched its own dbus-daemon, and that daemon never exited
# (~100 an hour). On 11-09 the box held 3,705 of them (7.5 GB of 16 GB). The same
# leak was on project-6-os (2,476), project-3-2 (1,492), project-9 (782), project-5 and review-2.
# The prevention is DBUS_SESSION_BUS_ADDRESS=disabled: in bin/gh-ledger/gh and in
# cron/boxes/*/000-path.cron. This script removes the daemons that already leaked
# and any a caller outside those two paths still leaks.
#
# WHAT IT KILLS: a `dbus-daemon ... --session` process whose parent is pid 1 (an
# orphan), that is older than DBUS_REAP_MIN_AGE_S (default 3600 s), and that did
# NOT start within DBUS_REAP_BOOT_GRACE_S (default 600 s) of boot. The boot
# exception keeps a shared session bus that a boot script started on purpose
# (Orgo's /etc/cron.d/orgo-session-bus). It never touches `dbus-daemon --system`.
#
# rc 0 always. Prints one summary line when it killed something.
# Switch: lane_switch dbus-orphan-reap-off (settings row switch.dbus-orphan-reap-off, or flags/dbus-orphan-reap-off).
set -u
export HARNESS="${HARNESS:-/root/harness}"   # lane-switch.sh and lane-gate.sh read it
# The switch is read through lane_switch (a settings row first, then the file).
# shellcheck source=bin/lib/lane-switch.sh
. "$(dirname "$0")/lib/lane-switch.sh" 2>/dev/null || exit 0
lane_switch dbus-orphan-reap-off file && exit 0
# Test seam only (not a tuning knob): tests point it at a fake uptime file.
UPTIME_FILE="${DBUS_REAP_UPTIME_FILE:-/proc/uptime}"
[ -r "$UPTIME_FILE" ] || exit 0

# The three limits are knobs of the lane-reaper lane (catalog/lanes.d/lane-reaper.knobs.d/):
# a settings row first (lane_knob), then the env, then the registry default. The
# literals below are only the documented fallback when the lane gate cannot load.
# shellcheck source=bin/lib/lane-gate.sh
. "$(dirname "$0")/lib/lane-gate.sh" 2>/dev/null || true
# knob <ENV> <default> <min> <max> — a value that is not a whole number in [min, max] is the default.
knob() {
  local v=""
  if command -v lane_knob >/dev/null 2>&1; then v=$(lane_knob lane-reaper "$1" 2>/dev/null); fi
  [ -n "$v" ] || v="${!1:-}"
  case "$v" in ''|*[!0-9]*) v="$2" ;; esac
  { [ "${#v}" -le 6 ] && [ "$v" -ge "$3" ] && [ "$v" -le "$4" ]; } || v="$2"
  printf '%s' "$v"
}
MIN_AGE=$(knob DBUS_REAP_MIN_AGE_S 3600 300 86400)
BOOT_GRACE=$(knob DBUS_REAP_BOOT_GRACE_S 600 0 3600)
MAX=$(knob DBUS_REAP_MAX 5000 1 20000)

UP=$(cut -d. -f1 "$UPTIME_FILE")
N=0; KEPT=0
while read -r PID PPID_ AGE ARGS; do
  case "$ARGS" in *dbus-daemon*--session*) : ;; *) continue ;; esac
  [ "$PPID_" = 1 ] || continue
  [ "$AGE" -ge "$MIN_AGE" ] || continue
  if [ $(( UP - AGE )) -le "$BOOT_GRACE" ]; then KEPT=$((KEPT + 1)); continue; fi
  kill -TERM "$PID" 2>/dev/null && N=$((N + 1))
  [ "$N" -ge "$MAX" ] && break
done < <(ps -eo pid=,ppid=,etimes=,args= 2>/dev/null)

[ "$N" -gt 0 ] && echo "dbus-orphan-reap: killed $N orphan session dbus-daemon(s) older than ${MIN_AGE}s, kept $KEPT boot-time bus(es)"
exit 0
