#!/bin/bash
# bin/lane-snapshot-publish.sh [--lane L] [project...] — the hub side of a lane
# that runs on Fly lane machines (BH-6128, BH-6047 part 5 of 5).
#
# A machine running blocked-resolver has no hub files. Before each dispatch
# (cron 2,12,... ; the dispatch is 4,14,...) this script, for each project in
# fleet.conf (or the projects named) whose name is path-safe:
#
#   1. applies the write-backs the machines posted (lri_apply_pending), always,
#      so a lane moved back to the hub never strands a machine's writes;
#   2. publishes the project's snapshot (lri_publish), only when lp_decide
#      places the lane on fly;
#
# and then, once per tick for every lane (BH-6889):
#
#   3. replays the alert lines lane-run machines posted to the jobs API into
#      logs/ALERTS.log and marks them applied (alr_apply,
#      bin/lib/alert-line-remote.sh). A second apply adds nothing.
#
# It prints ONE line:
#   lane-snapshot-publish: <n> published, <u> unchanged, <a> write-backs
#   applied, <c> conflicts, <r> rejected, <f> failed (<why>); <lane> placed
#   <place> (<why>); alert lines: <r> replayed, <s> already applied, ack <...>
# and pages through bin/lane-alert.sh with lane-level ids, so each pages once
# per episode and names its projects: lane-snapshot-publish (f > 0),
# lane-snapshot-oversize, lane-snapshot-conflict, lane-snapshot-rejected, and
# lane-snapshot-alert-lines (step 3 failed; resolved on the next good tick).
# A step 3 failure does not change the exit code.
# A run longer than its cron period (settings row lane_snapshot.run_alert_s,
# code fallback 600 s = the 10-min cadence; 0 reads as missing) pages
# lane-snapshot-slow-<lane> once per episode; the next run for that lane inside
# the period resolves it (BH-7437). The id is per lane: each lane has its own
# run. Runs that
# outlast the period stack, and the machines then refuse the stale snapshots.
# The log line (not stdout) ends with `; run <s>s`.
# The knobs are settings rows (lane_snapshot.*, bin/lib/lane-run-inputs.sh).
# Off: flags/lane-off-lane-snapshot-publish. The lane is in
# catalog/lanes.d/lane-snapshot-publish.json; the note is
# docs/notes/2026-10-12-BH-6128-blocked-resolver-offhub.md.
set -uo pipefail
H="${HARNESS:-/root/harness}"
export HARNESS="$H"
LOG="$H/logs/lane-snapshot-publish.log"
mkdir -p "$H/logs" 2>/dev/null
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
START_S=$(date -u +%s)

# shellcheck disable=SC1091
. "$H/bin/lib/lane-gate.sh" 2>/dev/null || true
# One cron line per published lane (plain = blocked-resolver, and --lane
# pipeline-health): the lane is the one-run key (BH-7422).
LANE_RUN_KEY=blocked-resolver; [ "${1:-}" = --lane ] && LANE_RUN_KEY=${2:-}
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit lane-snapshot-publish
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    lane-snapshot-publish

# shellcheck source=bin/jobs-client.sh
. "$H/bin/jobs-client.sh" || exit 1
# shellcheck source=bin/lib/project-lanes.sh
. "$H/bin/lib/project-lanes.sh" || exit 1
# shellcheck source=bin/lib/lane-placement.sh
. "$H/bin/lib/lane-placement.sh" || exit 1
# shellcheck source=bin/lib/lane-run-inputs.sh
. "$H/bin/lib/lane-run-inputs.sh" || exit 1
# shellcheck source=bin/lib/alert-line-remote.sh
. "$H/bin/lib/alert-line-remote.sh" || exit 1

LANE=blocked-resolver
if [ "${1:-}" = --lane ]; then LANE="${2:-}"; shift 2 || { echo "usage: lane-snapshot-publish.sh [--lane L] [project...]" >&2; exit 2; }; fi
pl_name_ok "$LANE" || { echo "lane-snapshot-publish: lane '$LANE' is not a path-safe name" >&2; exit 2; }
if [ "$#" -gt 0 ]; then PROJECTS=("$@")
else mapfile -t PROJECTS < <("$H/bin/fleet-conf.sh" --projects 2>/dev/null); fi

lp_decide "$LANE"
PUB=0; UNCH=0; APPLIED=0; CONFL=0; REJ=0; FAILED=0
WHY=(); OVER=(); CPROJ=(); RPROJ=()
for p in "${PROJECTS[@]}"; do
  pl_name_ok "$p" || continue
  out=$(lri_apply_pending "$LANE" "$p" 2>&1); arc=$?
  a=$(sed -nE 's/.*applied=([0-9]+).*/\1/p' <<<"$out" | tail -1)
  c=$(sed -nE 's/.*conflicts=([0-9]+).*/\1/p' <<<"$out" | tail -1)
  r=$(sed -nE 's/.*rejected=([0-9]+).*/\1/p' <<<"$out" | tail -1)
  APPLIED=$((APPLIED + ${a:-0})); CONFL=$((CONFL + ${c:-0})); REJ=$((REJ + ${r:-0}))
  [ "${c:-0}" = 0 ] || CPROJ+=("$p")
  [ "${r:-0}" = 0 ] || RPROJ+=("$p")
  if [ "$arc" != 0 ]; then FAILED=$((FAILED + 1)); WHY+=("$p: apply"); continue; fi
  [ "$LP_PLACE" = fly ] || continue
  out=$(lri_publish "$LANE" "$p" 2>&1); prc=$?
  case "$prc:$out" in
    0:published*) PUB=$((PUB + 1)) ;;
    0:unchanged*) UNCH=$((UNCH + 1)) ;;
    3:*) FAILED=$((FAILED + 1)); OVER+=("$p ${out##* } bytes"); WHY+=("$p: oversize") ;;
    *) FAILED=$((FAILED + 1)); WHY+=("$p: publish") ;;
  esac
done

LINE="lane-snapshot-publish: $PUB published, $UNCH unchanged, $APPLIED write-backs applied, $CONFL conflicts, $REJ rejected, $FAILED failed"
[ "${#WHY[@]}" = 0 ] || LINE="$LINE (${WHY[*]})"
LINE="$LINE; $LANE placed $LP_PLACE ($LP_WHY)"
ALR=$(alr_apply 2>/dev/null); ALRC=$?
LINE="$LINE; ${ALR:-alert lines: no answer}"
RUN_S=$(( $(date -u +%s) - START_S ))
echo "$(STAMP) $LINE; run ${RUN_S}s" >> "$LOG"
echo "$LINE"
# The cron period, from the settings row; a missing or non-number row is 600.
SLOW_S=$(setting_get lane_snapshot.run_alert_s 2>/dev/null | tr -d '[:space:]' || :)
case "$SLOW_S" in ''|*[!0-9]*|0) SLOW_S=600 ;; esac

ALERT="$H/bin/lane-alert.sh"
if [ -x "$ALERT" ]; then
  [ "$FAILED" = 0 ] || "$ALERT" --severity warn --id lane-snapshot-publish lane-snapshot-publish \
    "$FAILED project(s) did not publish or apply their $LANE snapshot: ${WHY[*]}. A machine refuses a snapshot older than lane_snapshot.max_age_s, so those runs report rc 66 until this clears." >/dev/null 2>&1
  [ "${#OVER[@]}" = 0 ] || "$ALERT" --severity warn --id lane-snapshot-oversize lane-snapshot-publish \
    "$LANE snapshot over lane_snapshot.max_bytes: ${OVER[*]}. Raise the settings row or shrink lane_snapshot.builds_days." >/dev/null 2>&1
  [ "$CONFL" = 0 ] || "$ALERT" --severity warn --id lane-snapshot-conflict lane-snapshot-publish \
    "$CONFL write-back file(s) kept the hub's copy because the hub changed it after the machine's snapshot: ${CPROJ[*]}." >/dev/null 2>&1
  [ "$REJ" = 0 ] || "$ALERT" --severity warn --id lane-snapshot-rejected lane-snapshot-publish \
    "$REJ write-back(s) rejected (sha mismatch or a member outside the allow-list): ${RPROJ[*]}." >/dev/null 2>&1
  if [ "$RUN_S" -gt "$SLOW_S" ]; then
    "$ALERT" --severity warn --id "lane-snapshot-slow-$LANE" lane-snapshot-publish \
      "lane-snapshot-publish took ${RUN_S}s, longer than its cron period (lane_snapshot.run_alert_s=${SLOW_S}s), for ${#PROJECTS[@]} project(s). Runs stack and the $LANE snapshots go stale; a machine refuses a snapshot older than lane_snapshot.max_age_s (rc 66)." >/dev/null 2>&1
  else
    "$ALERT" --resolve --id "lane-snapshot-slow-$LANE" lane-snapshot-publish "lane-snapshot-publish runs inside its cron period again: ${RUN_S}s <= ${SLOW_S}s" >/dev/null 2>&1
  fi
  if [ "$ALRC" = 0 ]; then
    "$ALERT" --resolve --id lane-snapshot-alert-lines lane-snapshot-publish "alert lines from lane-run machines replay again: ${ALR:-}" >/dev/null 2>&1
  else
    "$ALERT" --severity warn --id lane-snapshot-alert-lines lane-snapshot-publish \
      "the hub did not replay or ack the alert lines lane-run machines posted (${ALR:-no answer}). Those lines wait in the jobs table alert_lines (GET /api/alert-lines?unapplied=1) and reach logs/ALERTS.log on the next good tick." >/dev/null 2>&1
  fi
fi
[ "$FAILED" = 0 ]
