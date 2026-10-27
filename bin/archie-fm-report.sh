#!/bin/bash
# bin/archie-fm-report.sh — BH-4588 (BH-4574.6): Archie's daily factory report
# and the stop-the-line beat. A hub lane, every 15 minutes.
#
#   archie-fm-report.sh [tick]        the cron line
#   archie-fm-report.sh render <day>  prints the report text for <day>
#                                     (YYYY-MM-DD); sends nothing, no lock
#   archie-fm-report.sh stl --dry-list
#                                     one TSV line per open stop-the-line
#                                     incident that is due (first_seen epoch,
#                                     incident, class, age min, alert id,
#                                     line); sends nothing
#
# TICK, in this order:
#   1. lane_gate_or_exit / lane_env_apply archie-fm-report; ARCHIE_FMR_ENABLED=0
#      exits before any read; flock -n locks/archie-fm-report.lock (held =
#      skip). The outer `timeout` (ARCHIE_FMR_TICK_CEILING_S, 600 s) is the
#      backstop. NOW is read once
#      (ARCHIE_FMR_NOW only under HARNESS_TEST_SANDBOX=1).
#   2. the mode: afm_mode hub (archie.manage.hub > archie.manage > on).
#   3. STOP THE LINE (bin/lib/archie-fm-report/stl.sh): the open alerts,
#      classified by catalog/archie-stop-the-line.tsv, aged against the
#      archie.stl.*_min rows. ONE beat per incident (<alert-id>@<first_seen
#      epoch>) through archie-tg-send.sh "stl:<incident>", at most
#      archie.stl.beats_per_tick a tick; the rest wait. Not held for quiet
#      hours. Mode off or unreadable: no beat.
#   4. THE REPORT, from the first tick at or after archie.report.send_hour_utc:
#      yesterday (UTC) from GET /api/archie/factory-report, rendered by
#      afr_render (bin/lib/archie-fm-report/render.sh), sent ONCE through
#      archie-tg-send.sh "fm-report:<day>". Mode off still sends it, and its
#      first line says Archie is off. A failed read sends nothing; the next
#      tick retries.
#   One line in logs/archie-fm-report.log per thing done or failed.
#
# The ONLY side effect is a Telegram send through archie-tg-send.sh, whose
# archie_tg ledger row is the exactly-once record. This lane writes no
# archie_actions row, no marker and no state file, and it never acks an alert.
# NEVER: a git command, a GitHub write, a model call.
#
# OFF: ARCHIE_FMR_ENABLED=0, flags/lane-off-archie-fm-report or
# bin/harness-ctl.sh off archie-fm-report. Registry:
# catalog/lanes.d/archie-fm-report.json.
# Note: docs/notes/2026-10-23-BH-4588-manager-authority-report.md.
set -uo pipefail
H="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "$0")" && pwd)"
CMD=tick; R_DAY=""
case "${1:-}" in
  ''|tick) ;;
  render)
    CMD=render; R_DAY="${2:-}"
    [[ $R_DAY =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo "usage: archie-fm-report.sh render <YYYY-MM-DD>" >&2; exit 2; } ;;
  stl)
    [ "${2:-}" = --dry-list ] || { echo "usage: archie-fm-report.sh stl --dry-list" >&2; exit 2; }
    CMD=stl-dry ;;
  *) echo "usage: archie-fm-report.sh [tick] | render <YYYY-MM-DD> | stl --dry-list" >&2; exit 2 ;;
esac
. "$H/bin/lib/env-path.sh" 2>/dev/null || . "$SELF/lib/env-path.sh" 2>/dev/null \
  || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }
HENV=$(harness_env_dir "$H")
# shellcheck disable=SC1091
[ -r "$HENV/global.env" ] && { set -a; . "$HENV/global.env" 2>/dev/null; set +a; }
if [ "$CMD" = tick ] && [ "${ARCHIE_FMR_TIMED:-}" != 1 ] && command -v timeout >/dev/null 2>&1; then
  # The backstop: knobs ARCHIE_FMR_TICK_CEILING_S and ARCHIE_FMR_TICK_KILL_S
  # (catalog/lanes.d/archie-fm-report.json). 600 and 30 are the documented
  # fallbacks when the lane-gate lib is missing or a value is not a number.
  CEIL=600; KILL=30
  # shellcheck disable=SC1091
  . "$H/bin/lib/lane-gate.sh" 2>/dev/null || . "$SELF/lib/lane-gate.sh" 2>/dev/null || true
  if command -v lane_knob >/dev/null 2>&1; then
    v=$(lane_knob archie-fm-report ARCHIE_FMR_TICK_CEILING_S); [[ $v =~ ^[1-9][0-9]*$ ]] && CEIL=$v
    v=$(lane_knob archie-fm-report ARCHIE_FMR_TICK_KILL_S); [[ $v =~ ^[1-9][0-9]*$ ]] && KILL=$v
  fi
  ARCHIE_FMR_TIMED=1 exec timeout -k "$KILL" "$CEIL" bash "$0"
fi
# shellcheck disable=SC1091
{
  . "$H/bin/lib/lane-gate.sh" 2>/dev/null || . "$SELF/lib/lane-gate.sh" 2>/dev/null || true
  . "$SELF/jobs-client.sh" 2>/dev/null || true
  . "$SELF/lib/archie-fm.sh" 2>/dev/null || true
  . "$SELF/lib/archie-fm-report/render.sh" 2>/dev/null || true
  . "$SELF/lib/archie-fm-report/stl.sh" 2>/dev/null || true
}
# The suite's seam. Sandbox only, and settable:false in the registry.
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [ -n "${ARCHIE_FMR_FIXTURE:-}" ]; then
  # shellcheck disable=SC1090
  . "$ARCHIE_FMR_FIXTURE"
fi
for f in afm_mode afm_log _afm_req _jobs_req setting_get alerts_list job_ledger_get afr_render afr_stl_scan afr_stl_tick; do
  command -v "$f" >/dev/null 2>&1 || { echo "archie-fm-report: $f is not defined (a lib is missing)" >&2; exit 1; }
done
command -v jq >/dev/null 2>&1 || { echo "archie-fm-report: jq missing" >&2; exit 1; }

NOW=""
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [[ ${ARCHIE_FMR_NOW:-} =~ ^[0-9]+$ ]]; then NOW=$ARCHIE_FMR_NOW; fi
[ -n "$NOW" ] || NOW=$(date -u +%s)
AFR_TG_SEND="$H/bin/archie-tg-send.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/afr.XXXXXX") || { echo "archie-fm-report: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT
AFR_STL_DUE="$WORK/stl.tsv"; : > "$AFR_STL_DUE"
mkdir -p "$H/logs" "$H/locks" 2>/dev/null
AFM_LOG="$H/logs/archie-fm-report.log"

# afr_mode -> on | observe | off | unknown (unknown: the settings could not be read).
afr_mode() { afm_mode hub 2>/dev/null || printf unknown; }

# afr_fetch <day> <out-file> -> rc 0 with the report in the file; else rc 1
#   and one log line naming the failure.
afr_fetch() {
  local day="$1" out="$2" rc
  _afm_req GET "/api/archie/factory-report?day=$day" > "$out"; rc=$?
  if [ "$rc" != 0 ] || ! jq -e '.ok == true' "$out" >/dev/null 2>&1; then
    afm_log "report $day: GET /api/archie/factory-report failed (rc=$rc http=${JOBS_HTTP:-none}); nothing sent, retried next tick"
    return 1
  fi
}

if [ "$CMD" = render ]; then
  AFM_LOG=""
  afr_fetch "$R_DAY" "$WORK/report.json" || { echo "archie-fm-report: the report for $R_DAY could not be read" >&2; exit 1; }
  afr_stl_scan >/dev/null 2>&1 || : > "$AFR_STL_DUE"
  afr_render "$WORK/report.json" "$(afr_mode)" "$AFR_STL_DUE"
  exit $?
fi
if [ "$CMD" = stl-dry ]; then
  AFM_LOG=""
  afr_stl_scan || { echo "archie-fm-report: the open alerts could not be read" >&2; exit 1; }
  cat "$AFR_STL_DUE"
  exit 0
fi

command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit archie-fm-report
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply archie-fm-report
case "${ARCHIE_FMR_ENABLED:-1}" in
  0) exit 0 ;;
  1) ;;
  *) afm_log "warn: ARCHIE_FMR_ENABLED=${ARCHIE_FMR_ENABLED} is not 0 or 1; using the default 1" ;;
esac
exec 9>"$H/locks/archie-fm-report.lock" || exit 0
flock -n 9 || exit 0

MODE=$(afr_mode)
# 3. stop the line.
case "$MODE" in
  off) ;;
  unknown) afm_log "stl: archie.manage could not be read; no beat this tick" ;;
  *) afr_stl_tick ;;
esac

# 4. the daily report.
HOUR=$((10#$(date -u -d "@$NOW" +%H)))
SEND_H=$(setting_get archie.report.send_hour_utc); rc=$?
case "$rc" in
  0) SEND_H=$(printf '%s' "$SEND_H" | tr -d '[:space:]') ;;
  2) SEND_H=7 ;;   # the code fallback of the settings row archie.report.send_hour_utc
  *) afm_log "report: archie.report.send_hour_utc could not be read (rc=$rc); no report this tick"; exit 0 ;;
esac
if ! [[ $SEND_H =~ ^[0-9]{1,2}$ ]] || [ "$((10#$SEND_H))" -gt 23 ]; then
  afm_log "warn: archie.report.send_hour_utc='$SEND_H' is not an hour 0-23; no report this tick"; exit 0
fi
[ "$HOUR" -ge "$((10#$SEND_H))" ] || exit 0
DAY=$(date -u -d "@$(( NOW - 86400 ))" +%F)
AKEY="fm-report:$DAY"
st=$(job_ledger_get archie_tg "$AKEY" 2>/dev/null); rc=$?
case "$rc" in
  0) [ "$st" = sent ] && exit 0 ;;
  2) ;;
  *) afm_log "report $DAY: the archie_tg ledger did not answer; nothing sent, retried next tick"; exit 0 ;;
esac
afr_fetch "$DAY" "$WORK/report.json" || exit 0
[ "$MODE" = off ] || afr_stl_scan >/dev/null 2>&1 || : > "$AFR_STL_DUE"
[ "$MODE" = off ] && : > "$AFR_STL_DUE"
if ! TEXT=$(afr_render "$WORK/report.json" "$MODE" "$AFR_STL_DUE") || [ -z "${TEXT//[[:space:]]/}" ]; then
  afm_log "report $DAY: the answer could not be rendered; nothing sent"; exit 0
fi
rc=0; "$AFR_TG_SEND" "$AKEY" "$TEXT" >/dev/null 2>&1 || rc=$?
case "$rc" in
  0) afm_log "sent $AKEY (mode $MODE)" ;;
  2) if ! grep -qF "report $DAY: not sent: archie-tg-send is not configured" "$AFM_LOG" 2>/dev/null; then
       afm_log "report $DAY: not sent: archie-tg-send is not configured (rc 2); retried each tick"
     fi ;;
  *) afm_log "report $DAY: not sent (archie-tg-send rc $rc); retried next tick" ;;
esac
exit 0
