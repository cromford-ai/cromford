#!/bin/bash
# bin/project-21-daily.sh — the daily project-21 check failure rate of this box (BH-8079).
#
# Each build writes one `<stamp> [<project>/<KEY>] project-21 state=<s> ...` line to
# its pipeline.log (bin/lib/rb/pr.sh, project-21_log_line in bin/lib/project-21.example). This
# lane reads the LAST such line of each $HARNESS/builds/*/pipeline.log and counts
# the builds whose line is stamped within project-21_DAILY_WINDOW_H hours (24). A
# build whose state is off is not counted. Pool builds count on the hub, which
# fly-results-ingest.sh copies their pipeline.log to.
#
#   failed x 100 > project-21_DAILY_FAIL_PCT (50) x counted  -> one warn lane-alert,
#                                                           id project-21-check-failing
#   counted >= 1 and at or under it                      -> --resolve that id
#   counted = 0                                          -> a log line only
#
# One summary line per run to logs/project-21-daily.log. Exit 0 always.
# OFF: flags/lane-off-project-21-daily (bin/harness-ctl.sh off project-21-daily).
# Registry: catalog/lanes.d/project-21-daily.json. Run by hand: bin/project-21-daily.sh
set -uo pipefail
H="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "$0")" && pwd)"
. "$H/bin/lib/env-path.sh" 2>/dev/null || . "$SELF/lib/env-path.sh" 2>/dev/null \
  || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }
HENV=$(harness_env_dir "$H")
# shellcheck disable=SC1091
[ -r "$HENV/global.env" ] && { set -a; . "$HENV/global.env" 2>/dev/null; set +a; }

# shellcheck disable=SC1091
. "$H/bin/lib/lane-gate.sh" 2>/dev/null || . "$SELF/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit project-21-daily
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply project-21-daily

PCT="${project-21_DAILY_FAIL_PCT:-50}"   # lane.project-21-daily.project-21_daily_fail_pct
WIN="${project-21_DAILY_WINDOW_H:-24}"   # lane.project-21-daily.project-21_daily_window_h
[[ "$PCT" =~ ^[1-9][0-9]*$ ]] && [ "$PCT" -le 100 ] || PCT=50
[[ "$WIN" =~ ^[1-9][0-9]*$ ]] || WIN=24
NOW="${project-21_DAILY_NOW:-}"
[[ "$NOW" =~ ^[1-9][0-9]*$ ]] || NOW=$(date +%s)
BOX="${JOBS_BOX:-$(hostname -s 2>/dev/null || echo unknown)}"

mkdir -p "$H/logs" 2>/dev/null
LOG="$H/logs/project-21-daily.log"
line() { printf '%s %s\n' "$(date -u -d "@$NOW" +%FT%TZ)" "$1" >> "$LOG"; }

if [ ! -d "$H/builds" ] || [ ! -r "$H/builds" ]; then
  line "no readable $H/builds; nothing counted"
  exit 0
fi

# Bounded: only pipeline.log files modified within the window plus a day.
DAYS=$(( (WIN + 23) / 24 + 1 ))
FAILED=0; COUNTED=0
while IFS= read -r -d '' f; do
  l=$(grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8}Z \[[^]]*\] project-21 state=' "$f" 2>/dev/null | tail -1)
  [ -n "$l" ] || continue
  ts=$(date -u -d "${l:0:20}" +%s 2>/dev/null) || continue
  [ $((NOW - ts)) -le $((WIN * 3600)) ] && [ "$ts" -le "$NOW" ] || continue
  st=$(sed -n 's/.* project-21 state=\([a-z]*\).*/\1/p' <<<"$l")
  case "$st" in
    off|"") continue ;;
    failed) FAILED=$((FAILED + 1)) ;;
  esac
  COUNTED=$((COUNTED + 1))
done < <(find "$H/builds" -mindepth 2 -maxdepth 2 -name pipeline.log -mtime "-$DAYS" -print0 2>/dev/null)

line "failed=$FAILED counted=$COUNTED window=${WIN}h threshold=${PCT}%"
if [ "$COUNTED" -ge 1 ] && [ $((FAILED * 100)) -gt $((PCT * COUNTED)) ]; then
  "$SELF/lane-alert.sh" --id project-21-check-failing --severity warn project-21-daily \
    "project-21: the dependency check failed on $FAILED of $COUNTED builds in the last ${WIN}h on $BOX (over ${PCT}%); see logs/project-21-daily.log" >/dev/null 2>&1 || true
elif [ "$COUNTED" -ge 1 ]; then
  "$SELF/lane-alert.sh" --resolve --id project-21-check-failing project-21-daily \
    "project-21: the dependency check failed on $FAILED of $COUNTED builds in the last ${WIN}h on $BOX (at or under ${PCT}%)" >/dev/null 2>&1 || true
fi
exit 0
