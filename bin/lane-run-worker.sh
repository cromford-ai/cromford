#!/bin/bash
# bin/lane-run-worker.sh [--once] [--machine ID] — the machine loop of the
# lane-run queue (BH-6124, BH-6047 part 1 of 5).
#
# pl_dispatch enqueues one lane_runs row per project for a lane placed `fly`
# (bin/lib/lane-placement.sh). This loop, on a machine, takes one row at a
# time and runs it exactly as the hub would:
#
#   1. claim     POST /api/lane-runs/claim {machine}. 204 = the queue is empty:
#                sleep lane_run.poll_s (1..300, fallback 15), or with --once
#                exit 0. A transport failure logs one line; --once exits 1.
#   2. check     lane and project are path-safe names and args[0] is a path
#                under bin/ with no `..`. A bad row is logged and NOT run and
#                NOT reported: its lease runs out and the row is re-claimed.
#   3. inputs    lri_fetch <lane> <project> <state dir> (lib/lane-run-inputs.sh).
#                A non-zero rc does NOT run the lane: the row is reported rc 66
#                with prof `PROF lri_fetch rc=<n> <lane>/<project>`, and the
#                first such failure of a lane in this process writes ONE
#                `lane-alert.sh --id lane-inputs-<lane>` line naming the project.
#   4. run       LANE_RUN_ID=<id> setsid -w bin/project-lane-run.sh <lane>
#                <project> 0 $H/<args[0]> <args[1..]>, with lrh_start/lrh_stop
#                (lib/lane-run-heartbeat.sh) around the wait. Its output goes to
#                logs/<lane>-cron.log, as on the hub.
#   5. write     unless lrh_lost: lri_checkpoint <lane> <project> posts what the
#      back      run changed since its last checkpoint. A failure reports rc 75
#                (EX_TEMPFAIL), never the run's own rc.
#   6. report    unless lrh_lost: POST /api/lane-runs/<id>/report {machine, rc,
#                prof}. rc is the run's real exit status (127 when it could not
#                start); prof is the run's last line that starts `PROF `,
#                at most 512 bytes. A failed report logs one line, and the
#                lease re-runs the row.
#
# --once drains the queue: it loops until a claim comes back empty, then exits
# 0. The machine id is --machine, else FLY_MACHINE_ID, else this box's name; it
# must be a path-safe name, else exit 2. Log lines go to
# logs/lane-run-worker.log, stamped from LANE_RUN_NOW (epoch) when it is set.
# Contract: docs/notes/2026-10-12-BH-6124-lane-runs.md.
set -uo pipefail
H="${HARNESS:-$(cd "$(dirname "$0")/.." && pwd)}"
export HARNESS="$H"
# shellcheck source=bin/jobs-client.sh
. "$H/bin/jobs-client.sh" || exit 1
# shellcheck source=bin/lib/project-lanes.sh
. "$H/bin/lib/project-lanes.sh" || exit 1
# shellcheck source=bin/lib/lane-run-heartbeat.sh
. "$H/bin/lib/lane-run-heartbeat.sh" || exit 1
# shellcheck source=bin/lib/lane-run-inputs.sh
. "$H/bin/lib/lane-run-inputs.sh" || exit 1

ONCE=0; MACHINE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --once) ONCE=1; shift ;;
    --machine) MACHINE="${2:-}"; shift 2 || { echo "usage: lane-run-worker.sh [--once] [--machine ID]" >&2; exit 2; } ;;
    *) echo "usage: lane-run-worker.sh [--once] [--machine ID]" >&2; exit 2 ;;
  esac
done
[ -n "$MACHINE" ] || MACHINE="${FLY_MACHINE_ID:-$(_jobs_box_name)}"
pl_name_ok "$MACHINE" || { echo "lane-run-worker: machine id '$MACHINE' is not a path-safe name" >&2; exit 2; }

mkdir -p "$H/logs" "$H/state/lane-run-worker" 2>/dev/null
WLOG="$H/logs/lane-run-worker.log"
lw_log() {
  local ts
  if [ -n "${LANE_RUN_NOW:-}" ]; then ts=$(date -u -d "@$LANE_RUN_NOW" '+%F %TZ' 2>/dev/null); else ts=$(date -u '+%F %TZ'); fi
  echo "$ts [lane-run-worker] $MACHINE: $*" >> "$WLOG"
}

lw_poll_s() {
  local v
  v=$(setting_get lane_run.poll_s 2>/dev/null) || v=""
  case "$v" in ''|*[!0-9]*) v=15 ;; esac
  [ "$v" -ge 1 ] && [ "$v" -le 300 ] || v=15
  printf '%s' "$v"
}

RESP="$H/state/lane-run-worker/claim-$$.json"
trap 'rm -f "$RESP"' EXIT
declare -A LW_ALERTED=()

# lw_report <id> <lane> <project> <rc> <prof> — step 6.
lw_report() {
  local id="$1" lane="$2" project="$3" rc="$4" prof="$5" body
  body=$(jq -nc --arg m "$MACHINE" --argjson rc "$rc" --arg p "$prof" \
    '{machine:$m, rc:$rc} + (if $p == "" then {} else {prof:$p} end)')
  if _jobs_req POST "/api/lane-runs/$id/report" "$body" > /dev/null; then
    lw_log "run $id $lane/$project rc $rc: reported"
  else
    lw_log "run $id $lane/$project rc $rc: report failed (http ${JOBS_HTTP:-none}); the lease re-runs it"
  fi
}

# lw_run <claim payload file> — steps 2-6 for one claimed row.
lw_run() {
  local f="$1" id lane project n out pid rc prof fo frc
  local -a args=()
  id=$(jq -r '.id // empty' "$f" 2>/dev/null)
  lane=$(jq -r '.lane // empty' "$f" 2>/dev/null)
  project=$(jq -r '.project // empty' "$f" 2>/dev/null)
  n=$(jq -r '.args | length' "$f" 2>/dev/null)
  mapfile -d '' -t args < <(jq -j '.args[] | ., "\u0000"' "$f" 2>/dev/null)
  case "$id" in ''|*[!0-9]*) lw_log "claim answer without an id: $(head -c 200 "$f")"; return 0 ;; esac
  if ! pl_name_ok "$lane" || ! pl_name_ok "$project" || [ "${#args[@]}" -lt 1 ] || [ "${#args[@]}" != "$n" ]; then
    lw_log "run $id: bad lane, project or args; not run, not reported"; return 0
  fi
  if ! [[ ${args[0]} =~ ^bin/[A-Za-z0-9._/-]+$ ]] || [[ /${args[0]}/ == */../* ]]; then
    lw_log "run $id: args[0] '${args[0]}' is not a path under bin/; not run, not reported"; return 0
  fi
  fo=$(lri_fetch "$lane" "$project" "$H/state/$lane/$project" 2>&1); frc=$?
  if [ "$frc" != 0 ]; then
    lw_log "run $id: lri_fetch $lane $project rc $frc ($(printf '%s' "$fo" | tail -n 1)); not run"
    if [ -z "${LW_ALERTED[$lane]:-}" ]; then
      LW_ALERTED[$lane]=1
      [ -x "$H/bin/lane-alert.sh" ] && "$H/bin/lane-alert.sh" --severity warn --id "lane-inputs-$lane" "$lane" \
        "lane machine $MACHINE could not fetch the hub inputs for $lane/$project (lri_fetch rc $frc: $(printf '%s' "$fo" | tail -n 1)); the run was not started and is reported rc 66. Check bin/lane-snapshot-publish.sh on the hub." \
        >/dev/null 2>&1
    fi
    lw_report "$id" "$lane" "$project" 66 "PROF lri_fetch rc=$frc $lane/$project"
    return 0
  fi
  [ -z "$fo" ] || lw_log "run $id $lane/$project: $fo"
  out="$H/state/lane-run-worker/run-$id.out"
  if command -v setsid >/dev/null 2>&1; then
    LANE_RUN_ID="$id" setsid -w "$H/bin/project-lane-run.sh" "$lane" "$project" 0 "$H/${args[0]}" "${args[@]:1}" \
      > "$out" 2>&1 < /dev/null &
  else
    LANE_RUN_ID="$id" "$H/bin/project-lane-run.sh" "$lane" "$project" 0 "$H/${args[0]}" "${args[@]:1}" \
      > "$out" 2>&1 < /dev/null &
  fi
  pid=$!
  lrh_start "$id" "$pid"
  wait "$pid"; rc=$?
  lrh_stop
  cat "$out" >> "$H/logs/$lane-cron.log" 2>/dev/null
  prof=$(grep '^PROF ' "$out" 2>/dev/null | tail -n 1 | head -c 512)
  rm -f "$out"
  if lrh_lost; then
    lw_log "run $id $lane/$project rc $rc: lease lost; not reported"; return 0
  fi
  if ! fo=$(LANE_RUN_ID="$id" lri_checkpoint "$lane" "$project" 2>&1); then
    lw_log "run $id $lane/$project rc $rc: the final write-back failed ($(printf '%s' "$fo" | tail -n 1)); reported rc 75"
    rc=75; prof="PROF lri_checkpoint failed $lane/$project"
  fi
  lw_report "$id" "$lane" "$project" "$rc" "$prof"
  return 0
}

while :; do
  # Into a file, not $( ): JOBS_HTTP must survive the call to tell 204 apart.
  _jobs_req POST /api/lane-runs/claim "$(jq -nc --arg m "$MACHINE" '{machine:$m}')" > "$RESP"; crc=$?
  if [ "$crc" != 0 ]; then
    lw_log "claim failed (rc $crc, http ${JOBS_HTTP:-none})"
    [ "$ONCE" = 1 ] && exit 1
    sleep "$(lw_poll_s)"; continue
  fi
  if [ "$JOBS_HTTP" = 204 ] || [ ! -s "$RESP" ]; then
    [ "$ONCE" = 1 ] && exit 0
    sleep "$(lw_poll_s)"; continue
  fi
  lw_run "$RESP"
done
