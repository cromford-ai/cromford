#!/bin/bash
# bin/harness-sync-timer.sh — EVERY box that runs harness code, every 5 min
# (BH-7303, BH-7191.1): run `bin/harness-sync.sh deploy` when the last good
# sync is older than HARNESS_SYNC_PERIOD_MIN.
#
# Why: a box synced only by update-runners (05:17Z) and fleet-propagate lags
# main by up to a day when a propagate does not reach it. The version check
# (bin/fleet-version-check.sh) alerts at 30 min of lag.
#
# DUE when both of these are at least one period old (by file mtime; a missing
# file or an mtime in the future counts as old):
#   state/harness-sync-last-success     written by harness-sync.sh only
#   state/harness-sync-timer-last-attempt  written here, before each call
# So a sync that keeps failing runs at most once per period, not every tick.
#
# NEVER WAITS: flock -n on locks/harness-sync-timer.lock (two ticks never
# overlap), then a flock -n probe of locks/harness-sync.lock. A sync that is
# running already is a skip with one log line, and no attempt is stamped.
# rc 0 = not due, skipped or synced; rc 1 = harness-sync.sh failed (its own
# alert is already written). This script never writes last-success.
#
# Knob: HARNESS_SYNC_PERIOD_MIN (settings row
# lane.harness-sync-timer.harness_sync_period_min), default 15, min 5, max 240.
# A value that is not a whole number is 15, with one log line.
# Off: bin/harness-ctl.sh off harness-sync-timer. Log: logs/harness-sync-timer.log.
# Test seams: HARNESS, HARNESS_SYNC_TIMER_NOW (epoch). Never set these in cron.
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-harness-sync-timer
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off harness-sync-timer.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit harness-sync-timer
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    harness-sync-timer

LOG="$HARNESS/logs/harness-sync-timer.log"
log() { echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') harness-sync-timer: $*" >> "$LOG"; }
mkdir -p "$HARNESS/locks" "$HARNESS/logs" "$HARNESS/state"
exec 9>"$HARNESS/locks/harness-sync-timer.lock"
flock -n 9 || exit 0

P="${HARNESS_SYNC_PERIOD_MIN:-15}"
case "$P" in
  ''|*[!0-9]*) log "HARNESS_SYNC_PERIOD_MIN=$P is not a whole number; using 15"; P=15 ;;
esac
P=$(( 10#$P ))
[ "$P" -ge 5 ] || P=5
[ "$P" -le 240 ] || P=240
NOW="${HARNESS_SYNC_TIMER_NOW:-$(date +%s)}"
ATTEMPT="$HARNESS/state/harness-sync-timer-last-attempt"

# old <file> — rc 0 when the file is at least one period old, missing, or in the future.
old() {
  local m
  m=$(stat -c %Y "$1" 2>/dev/null) || return 0
  [ "$m" -le "$NOW" ] || return 0
  [ $(( NOW - m )) -ge $(( P * 60 )) ]
}
old "$HARNESS/state/harness-sync-last-success" || exit 0
old "$ATTEMPT" || exit 0

if ! flock -n "$HARNESS/locks/harness-sync.lock" true 9>&-; then
  log "skip: harness-sync running (locks/harness-sync.lock held)"
  exit 0
fi

touch -d "@$NOW" "$ATTEMPT"
OUT=$("$HARNESS/bin/harness-sync.sh" deploy 9>&- 2>&1); RC=$?
if [ "$RC" -eq 0 ]; then
  log "synced rc=0 (period ${P}m)"
  exit 0
fi
log "failed rc=$RC (period ${P}m; next try in ${P}m): $(printf '%s' "$OUT" | tail -3 | tr '\n' ' ' | head -c 300)"
exit 1
