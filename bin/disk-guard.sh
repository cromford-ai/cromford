#!/bin/bash
# bin/disk-guard.sh — the root disk watcher on every board box and the hub
# (BH-1123, cron */10).
#
# Reads `df -P /` once and raises at most two conditions through
# bin/lane-alert.sh, each with a stable id so the alert state machine sends it
# once and reminds on its own throttle:
#   disk-high-<host>    warn,     at or over DISK_ALERT_PCT (default 85)
#   disk-refuse-<host>  critical, at or over DISK_BUILD_REFUSE_PCT (default 92),
#                       the line where bin/run-build.sh's `# >>> disk gate`
#                       stops starting builds on this box.
# Each one is resolved when the disk is back under its line. Both numbers are
# knobs on this lane (catalog/lanes.d/disk-guard.json): bin/harness-ctl.sh set
# disk-guard DISK_ALERT_PCT <n>, or the console's settings page.
#
# An unreadable df is unknown: one log line an hour, no alert, no resolve.
# Quiet under the alert line. Off: flags/lane-off-disk-guard (the build gate
# still reads its knob; set DISK_BUILD_REFUSE_PCT to 100 to stop refusing).
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$HARNESS")
set -a; . "$HENV/global.env" 2>/dev/null; set +a

# >>> lane gate (BH-1165) — flags/all-off or flags/lane-off-disk-guard exits 0
# here; lane_env_apply puts this lane's settings rows into the environment.
# Both fail OPEN. Registry: catalog/lanes.json.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit disk-guard
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    disk-guard

# shellcheck source=bin/lib/disk-guard.sh
. "$HARNESS/bin/lib/disk-guard.sh" 2>/dev/null || . "$(dirname "$0")/lib/disk-guard.sh" 2>/dev/null || exit 0
# shellcheck source=bin/lib/alert-state.sh
. "$HARNESS/bin/lib/alert-state.sh" 2>/dev/null || . "$(dirname "$0")/lib/alert-state.sh" 2>/dev/null || true

LOG="$HARNESS/logs/disk-guard.log"
LA="$HARNESS/bin/lane-alert.sh"
HOST=$(hostname)
ADIR="$HARNESS/state/alerts"
[ -n "${ALERT_STATE_DIR-}" ] && ADIR="$ALERT_STATE_DIR"
mkdir -p "$HARNESS/logs" "$HARNESS/state/disk-guard" 2>/dev/null
log() { printf '%s %s\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "$*" >> "$LOG" 2>/dev/null; }

PCT=$(disk_used_pct /)
if [ -z "$PCT" ]; then
  STAMPF="$HARNESS/state/disk-guard/.unreadable"
  if [ -z "$(find "$STAMPF" -mmin -60 2>/dev/null)" ]; then
    log "disk / on $HOST unreadable (df gave no Use%) — unknown, no alert and no resolve"
    : > "$STAMPF" 2>/dev/null
  fi
  exit 0
fi
ALERT=$(disk_guard_knob DISK_ALERT_PCT 85)
REFUSE=$(disk_guard_knob DISK_BUILD_REFUSE_PCT 92)
FREE=$(disk_free_mb /); FREE="${FREE:-?}"
SAY="disk / on $HOST at $PCT% ($FREE MB free; alert at $ALERT%, builds refused at $REFUSE%)"
NEXT="bin/disk-clean.sh runs at 04:47Z; the usual suspects are stale ticket/* worktrees with node_modules, .next caches and docker layers"

# top_dirs — "top dirs: <path> <size>, ..." for the 5 largest directories at
# depth 2 under / on the root filesystem (BH-4440), so the alert says where the
# space went. Bounded: `du` runs under nice and DISK_TOP_DIRS_TIMEOUT_S
# (default 120), and its answer is cached in state/disk-guard/top-dirs for
# DISK_TOP_DIRS_TTL_MIN (default 60), so a box that stays over the line runs it
# at most once an hour. A du that timed out or printed nothing reads
# "unavailable", never a partial list.
top_dirs() {
  local f="$HARNESS/state/disk-guard/top-dirs" ttl to raw rc list
  ttl="${DISK_TOP_DIRS_TTL_MIN:-60}"; to="${DISK_TOP_DIRS_TIMEOUT_S:-120}"
  case "$ttl" in ''|*[!0-9]*) ttl=60 ;; esac
  case "$to" in ''|*[!0-9]*) to=120 ;; esac
  [ "$((10#$ttl))" -ge 10 ] || ttl=60
  [ "$((10#$to))" -ge 1 ] || to=120
  if [ -s "$f" ] && [ -n "$(find "$f" -mmin -"$((10#$ttl))" 2>/dev/null)" ]; then
    cat "$f"; return 0
  fi
  raw=$(timeout "$((10#$to))" nice du -xk -d 2 / 2>/dev/null); rc=$?
  list=""
  # rc 1 is du's "some entry was unreadable", the list is still whole; a
  # timeout (124/137) is not.
  if [ "$rc" -le 1 ]; then
    list=$(printf '%s\n' "$raw" \
      | awk -F'\t' '$2 ~ /^\/[^\/]+\/[^\/]+$/ && $1 ~ /^[0-9]+$/ { print $1 "\t" $2 }' \
      | sort -t"$(printf '\t')" -k1,1nr \
      | awk -F'\t' 'NR <= 5 { kb = $1
          if (kb >= 1048576) s = sprintf("%.1fG", kb / 1048576)
          else if (kb >= 1024) s = sprintf("%dM", kb / 1024)
          else s = kb "K"
          out = out (NR > 1 ? ", " : "") $2 " " s }
        END { print out }')
  fi
  if [ -n "$list" ]; then
    printf 'top dirs: %s' "$list" > "$f.tmp" 2>/dev/null && mv -f "$f.tmp" "$f" 2>/dev/null
    printf 'top dirs: %s' "$list"
  else
    # cached too, so a slow disk is not walked again every ten minutes
    local why="du gave no listing, rc=$rc"
    [ "$rc" -ge 124 ] && why="du timed out"
    printf 'top dirs: unavailable (%s)' "$why" > "$f.tmp" 2>/dev/null && mv -f "$f.tmp" "$f" 2>/dev/null
    printf 'top dirs: unavailable (%s)' "$why"
  fi
}

# resolve <id> <text> — only a condition that is open, so a healthy box does
# not write a resolve-silent line every ten minutes. With flags/alerts-db on the
# `alerts` row answers (BH-7802); otherwise any state file counts, as before (a
# resolve on a closed id is silent anyway).
command -v alert_state_open >/dev/null 2>&1 || alert_state_open() { [ -e "$ADIR/$1.json" ]; }
resolve() { alert_state_open "$1" --file-exists && "$LA" --resolve --id "$1" disk-guard "$2" >/dev/null 2>&1; return 0; }

if [ "$PCT" -ge "$ALERT" ]; then
  "$LA" --id "disk-high-$HOST" --severity warn disk-guard "$SAY. $NEXT. $(top_dirs)." >/dev/null 2>&1 || true
else
  resolve "disk-high-$HOST" "$SAY, back under $ALERT%."
fi
if [ "$PCT" -ge "$REFUSE" ]; then
  "$LA" --id "disk-refuse-$HOST" --severity critical disk-guard \
    "$SAY: builds on this box are now refused. $NEXT." >/dev/null 2>&1 || true
else
  resolve "disk-refuse-$HOST" "$SAY, back under $REFUSE%; builds start again."
fi
[ "$PCT" -ge "$ALERT" ] && log "$SAY"
exit 0
