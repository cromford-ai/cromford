#!/bin/bash
# bin/main-red-recheck.sh — re-check every repo with a main-red freeze up, every
# 5 minutes (BH-6502). No arguments.
#
# WHY. bin/main-red-detector.sh judges every repo inside the merge conductor's
# full tick, and that tick runs once an hour (CADENCE_BACKSTOP_MIN_MERGE_CONDUCTOR,
# BH-5521). On 2026-10-13 example-org/project-6 went green at 12:30Z and again
# after 15:26Z, and each time its freeze stayed up until an operator ran the
# detector by hand. Every minute a freeze stays up on a green main is a minute
# no PR merges in that repo.
#
# WHAT. When at least one flags/main-red-<owner>-<repo> freeze is up (the two
# switch files main-red-detector-off and main-red-pr-pair-off are not freezes)
# and the cadence allows it, this lane writes state/main-red/recheck.last and
# runs `bin/main-red-detector.sh --flagged-only`: the same decision code as the
# hourly pass, on the flagged repos only. The hourly pass is unchanged.
#
# COST. No freeze up: no GitHub read and no detector start. A freeze up: one
# Actions runs read per flagged repo, plus the detector's existing extra reads in
# their existing cases. The detector logs the real count as
# `recheck: <n> flagged repo(s), <r> Actions read(s)` in logs/main-red.log.
#
# KNOB. MAIN_RED_RECHECK_MIN [5] minutes between rechecks; 0 = off; a value that
# is not a whole number is 5. Settings row
# lane.main-red-recheck.main_red_recheck_min > env > 5. The cron line is */5, so
# a value under 5 runs every tick. A run is allowed 30 s early (cron jitter).
# The stamp is written BEFORE the detector starts: a detector that fails waits
# one cadence, it is not retried every tick.
#
# Kill switch: bin/harness-ctl.sh off main-red-recheck (flags/lane-off-main-red-recheck)
# Tests: tests/main-red-flagged-recheck.bh-6502-test.sh
set -uo pipefail
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")
export HARNESS="$H"
# >>> lane gate (BH-1165)
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit main-red-recheck
if [ -f "$HENV/global.env" ]; then set -a; # shellcheck disable=SC1091
  . "$HENV/global.env"; set +a; fi
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply main-red-recheck

MIN="${MAIN_RED_RECHECK_MIN:-5}"
case "$MIN" in ''|*[!0-9]*) MIN=5 ;; esac
MIN=$((10#$MIN))
[ "$MIN" = 0 ] && exit 0

# Any freeze up? The same list as the detector's mr_flag_files.
up=0
for f in "$H"/flags/main-red-*; do
  [ -f "$f" ] || continue
  case "$(basename "$f")" in main-red-detector-off|main-red-pr-pair-off) continue ;; esac
  up=1; break
done
[ "$up" = 1 ] || exit 0

STAMPF="$H/state/main-red/recheck.last"
now=$(date +%s)
last=$(tr -dc '0-9' < "$STAMPF" 2>/dev/null)
if [ -n "$last" ] && [ $(( now - last )) -ge 0 ] && [ $(( now - last )) -lt $(( MIN * 60 - 30 )) ]; then
  exit 0
fi
mkdir -p "$H/state/main-red" 2>/dev/null
printf '%s\n' "$now" > "$STAMPF"
exec "$H/bin/main-red-detector.sh" --flagged-only
