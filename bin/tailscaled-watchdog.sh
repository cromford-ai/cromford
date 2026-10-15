#!/bin/bash
# bin/tailscaled-watchdog.sh — start tailscaled again when it is gone (BH-6693).
#
# WHY. On 2026-10-14 the OOM killer took tailscaled on box-small at
# 10:48Z. Only the @reboot crontab line starts it, so the box stayed off the
# tailnet for ~1 h 50 m: the hub could not ssh to it, and the cromford
# pool could not bundle env for a build (11 `ssh env extract ... failed`).
#
# EVERY 2 MINUTES ON EVERY BOX (cron/lanes/261-tailscaled-watchdog.cron):
#   1. `pgrep -x tailscaled` finds nothing and the binary is on the box: run
#      the start command (TSD_START, bin/lib/tailscaled-start.sh — the string
#      bin/box-launch.sh sends to a new box) and log one line.
#   2. Set oom_score_adj to -900 for each tailscaled pid whose value is not
#      -900 yet, and log one line when any changed. The OOM killer then picks a
#      build process before the box's way in.
#      sshd is NOT adjusted: children inherit oom_score_adj at fork, so -900 on
#      the sshd listener passes to every ssh session and every build started
#      over ssh (bin/up10-lane.sh, the medic relaunch, the pool push). Those
#      builds would become the processes the OOM killer avoids. The boxes start
#      sshd as bare /usr/sbin/sshd and tailscaled from cron, not systemd, so a
#      systemd OOMScoreAdjust drop-in would not apply here.
# A box with no /usr/sbin/tailscaled does nothing. A running tailscaled is
# never started twice. Off: flags/lane-off-tailscaled-watchdog.
# Log: logs/tailscaled-watchdog.log.
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"

# >>> lane gate (BH-1165) — flags/all-off or flags/lane-off-tailscaled-watchdog
# exits 0 here; lane_env_apply puts this lane's settings rows into the
# environment. Both fail OPEN. Registry: catalog/lanes.json.
# shellcheck source=bin/lib/lane-gate.sh
. "$HARNESS/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit tailscaled-watchdog
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    tailscaled-watchdog

# shellcheck source=bin/lib/tailscaled-start.sh
. "$HARNESS/bin/lib/tailscaled-start.sh" 2>/dev/null || . "$(dirname "$0")/lib/tailscaled-start.sh" 2>/dev/null || exit 0

# Test seams, not knobs: the binary the box must hold, and the /proc root.
TSW_TAILSCALED="${TSW_TAILSCALED:-/usr/sbin/tailscaled}"
TSW_PROC="${TSW_PROC:-/proc}"
LOG="$HARNESS/logs/tailscaled-watchdog.log"
mkdir -p "$HARNESS/logs" 2>/dev/null
log() { printf '%s %s %s\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "$(hostname 2>/dev/null)" "$*" >> "$LOG" 2>/dev/null; }

# 1. Start tailscaled when it is gone.
if [ -x "$TSW_TAILSCALED" ] && ! pgrep -x tailscaled >/dev/null 2>&1; then
  if eval "$TSD_START"; then
    log "tailscaled was not running; started it (bin/lib/tailscaled-start.sh)"
  else
    log "tailscaled was not running; the start command failed (rc $?)"
  fi
fi

# 2. Keep the box's way in out of the OOM killer's first picks.
changed=""
for pid in $(pgrep -x tailscaled 2>/dev/null); do
  f="$TSW_PROC/$pid/oom_score_adj"
  [ -w "$f" ] || continue
  [ "$(cat "$f" 2>/dev/null)" = -900 ] && continue
  echo -900 > "$f" 2>/dev/null && changed="$changed tailscaled:$pid"
done
[ -z "$changed" ] || log "oom_score_adj set to -900 for$changed"
exit 0
