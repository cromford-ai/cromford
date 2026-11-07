#!/bin/bash
# bin/orc-monitor.sh — the orchestrator monitor lane, run from the repo
# (BH-9074, BH-9067.2; docs/events-bh-9067/2-wake-pollers.bh-9074.md). The
# hub's no-AI 5-minute status monitor lives in the orchestrator tree,
# ${ORC:-/root/orchestrator}/bin/orc-monitor.sh, which this repo does not ship.
# This file is the gate in front of it, so the lane has the same switches and
# the same lane wake gate as every repo lane. The orchestrator's own kill,
# $ORC/flags/monitor-off, is read by the hub script itself (the cron line ran
# it directly before this wrapper existed), so it is not read twice here.
#
#   1. lane_gate_or_exit orc-monitor      exit 0 on flags/lane-off-orc-monitor,
#      or a pause row; with the contract (#9122) and
#      catalog/lane-wakes.d/orc-monitor.json, also on wake mode `on` with no ring
#   2. lane_env_apply orc-monitor         the settings rows of its knobs
#   3. lane_switch monitor-off            exit 0 (flags/monitor-off or the row switch.monitor-off)
#   4. exec $ORC/bin/orc-monitor.sh "$@"  the monitor's work, unchanged
#
# A missing hub script is one line in logs/orc-monitor.log per hour
# (state/orc-monitor/missing.at) and exit 0. A hub path that resolves to this
# file is refused (no exec loop).
# Cron: cron/lanes/620-orc-monitor.cron, */5 behind bin/lib/cadence-backstop.sh.
set -uo pipefail
H="${HARNESS:-/root/harness}"
ORC="${ORC:-/root/orchestrator}"
LOG="$H/logs/orc-monitor.log"
say() { mkdir -p "$H/logs" 2>/dev/null; printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >> "$LOG" 2>/dev/null; return 0; }

# shellcheck source=bin/lib/lane-gate.sh
. "$H/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit orc-monitor
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    orc-monitor
# monitor-off is also the harness switch (flags/monitor-off or the row
# switch.monitor-off): bin/lane-alert.sh reads it as "the monitor is down" and
# sends a critical alert itself, so the monitor must then not run.
# shellcheck source=bin/lib/lane-switch.sh
. "$H/bin/lib/lane-switch.sh" 2>/dev/null || true
command -v lane_switch >/dev/null 2>&1 && lane_switch monitor-off file && exit 0

TARGET="$ORC/bin/orc-monitor.sh"
if [ ! -x "$TARGET" ] || [ -d "$TARGET" ]; then
  st="$H/state/orc-monitor/missing.at"
  now=$(date -u +%s); last=$(tr -dc '0-9' < "$st" 2>/dev/null)
  if [ -z "$last" ] || [ $((now - last)) -ge 3600 ] || [ $((now - last)) -lt 0 ]; then
    say "orc-monitor: hub script $TARGET missing — nothing run"
    mkdir -p "${st%/*}" 2>/dev/null && printf '%s\n' "$now" > "$st.$$" 2>/dev/null && mv -f "$st.$$" "$st" 2>/dev/null
  fi
  exit 0
fi
if [ "$(readlink -f "$TARGET" 2>/dev/null)" = "$(readlink -f "$0" 2>/dev/null)" ]; then
  say "orc-monitor: hub script is this file — refusing to exec itself"
  exit 0
fi
exec "$TARGET" "$@"
