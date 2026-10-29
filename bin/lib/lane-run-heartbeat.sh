# shellcheck shell=bash
# bin/lib/lane-run-heartbeat.sh — the heartbeat a machine keeps on a claimed
# lane_runs row while the run lives. bin/lane-run-worker.sh calls these around
# every run, from the claim on (BH-8745: the pre-run steps beat too).
# Contract: docs/notes/2026-10-12-BH-6125-lane-run-lease.md.
#
#   lrh_start <run_id> <pgid> [max_s]
#                              start a background loop: every
#                              lane_run.heartbeat_s (1..300, fallback 30) it
#                              POSTs /api/lane-runs/<id>/heartbeat {machine}.
#                              On 409 `lost` it marks the run lost, then TERMs
#                              the run's process group <pgid> and KILLs it 5 s
#                              later. Any other failure is logged and the run
#                              goes on: an outage is not a lost lease. With
#                              max_s (a whole number 1..86400; the pre-run
#                              form, pgid "") the loop stops beating after
#                              max_s seconds, logs one line and kills nothing,
#                              so the lease runs out as it would; a lost lease
#                              only marks the run lost and logs `lease lost
#                              (<reason>) before the run started`.
#   lrh_stop                   end the loop
#   lrh_lost                   rc 0 when the lease was lost (another machine
#                              re-claimed the row), so the run must not report;
#                              rc 1 = not lost. Still answers after lrh_stop.
#
# The machine id is the caller's MACHINE, else FLY_MACHINE_ID, else
# _jobs_box_name. Needs _jobs_req and setting_get (bin/jobs-client.sh) from the
# caller. A pgid that is not a positive integer, is 1, or is this shell's own
# pid or process group is never signalled. Defines functions only. Nothing runs
# on source.
LRH_PID=""; LRH_ID=""; LRH_LOST_FILE=""; LRH_RESP=""

_lrh_log() {
  if declare -F lw_log >/dev/null; then lw_log "$*"; else echo "lane-run-heartbeat: $*" >&2; fi
}

# _lrh_kill <pgid> — TERM the group (the leader alone when the group kill
# fails), and KILL the group 5 s later from a detached child, so lrh_stop
# ending the loop cannot cancel it. rc 1 = refused, nothing signalled.
_lrh_kill() {
  local g="$1" own
  own=$(ps -o pgid= -p "$$" 2>/dev/null | tr -d ' ')
  if ! [[ $g =~ ^[1-9][0-9]*$ ]] || [ "$g" = 1 ] || [ "$g" = "$$" ] || [ "$g" = "$own" ]; then
    _lrh_log "run $LRH_ID: not killed: bad pgid '$g'"
    return 1
  fi
  kill -TERM -- "-$g" 2>/dev/null || kill -TERM "$g" 2>/dev/null
  ( sleep 5; kill -KILL -- "-$g" 2>/dev/null || kill -KILL "$g" 2>/dev/null ) < /dev/null > /dev/null 2>&1 &
  return 0
}

# _lrh_loop <id> <pgid> <seconds> <machine> [max_s] — runs in the background
# subshell.
_lrh_loop() {
  local id="$1" pgid="$2" hb="$3" body sp="" rc reason max="${5:-}" t0
  body=$(jq -nc --arg m "$4" '{machine:$m}')
  trap '[ -z "$sp" ] || kill "$sp" 2>/dev/null; exit 0' TERM
  t0=$(date +%s)
  while :; do
    sleep "$hb" & sp=$!
    wait "$sp"; sp=""
    # The worker that owns the run is gone: stop, so the lease can run out.
    kill -0 "$$" 2>/dev/null || exit 0
    if [ -n "$max" ] && [ $(( $(date +%s) - t0 )) -ge "$max" ]; then
      _lrh_log "run $id: pre-run heartbeat stopped after ${max}s"
      exit 0
    fi
    # Into a file, not $( ): JOBS_HTTP must survive the call.
    _jobs_req POST "/api/lane-runs/$id/heartbeat" "$body" > "$LRH_RESP"; rc=$?
    [ "$rc" = 0 ] && continue
    if [ "$rc" = 9 ] && [ "${JOBS_HTTP:-}" = 409 ] && [ "$(jq -r '.error // empty' "$LRH_RESP" 2>/dev/null)" = lost ]; then
      reason=$(jq -r '.reason // "unknown"' "$LRH_RESP" 2>/dev/null)
      : > "$LRH_LOST_FILE"
      if [ -z "$pgid" ] && [ -n "$max" ]; then
        _lrh_log "run $id: lease lost ($reason) before the run started"
        exit 0
      fi
      _lrh_log "run $id: lease lost ($reason); killing process group $pgid"
      _lrh_kill "$pgid"
      exit 0
    fi
    _lrh_log "run $id: heartbeat failed (rc $rc, http ${JOBS_HTTP:-none}); the run goes on"
  done
}

lrh_start() {
  local id="${1:-}" pgid="${2:-}" max="${3:-}" root="${HARNESS:-${H:-}}" hb m
  [[ $max =~ ^[1-9][0-9]{0,4}$ ]] && [ "$max" -le 86400 ] || max=""
  [ -z "$LRH_LOST_FILE" ] || rm -f "$LRH_LOST_FILE"
  LRH_ID="$id"; LRH_LOST_FILE=""; LRH_RESP=""
  if [ -z "$root" ] || ! mkdir -p "$root/state/lane-run-worker" 2>/dev/null; then
    _lrh_log "run $id: no harness root; not beating"
    return 1
  fi
  LRH_LOST_FILE="$root/state/lane-run-worker/lost-$$-$id"
  LRH_RESP="$root/state/lane-run-worker/heartbeat-$$-$id.json"
  rm -f "$LRH_LOST_FILE"
  if ! [[ $id =~ ^[0-9]+$ ]]; then
    _lrh_log "run '$id': not a run id; not beating"
    return 0
  fi
  m="${MACHINE:-${FLY_MACHINE_ID:-}}"
  [ -n "$m" ] || ! declare -F _jobs_box_name >/dev/null || m=$(_jobs_box_name)
  if [ -z "$m" ] || ! declare -F _jobs_req >/dev/null; then
    _lrh_log "run $id: no machine id or no jobs client; not beating"
    return 0
  fi
  hb=""
  ! declare -F setting_get >/dev/null || hb=$(setting_get lane_run.heartbeat_s 2>/dev/null) || hb=""
  [[ $hb =~ ^[0-9]+$ ]] && [ "$hb" -ge 1 ] && [ "$hb" -le 300 ] || hb=30
  _lrh_loop "$id" "$pgid" "$hb" "$m" "$max" &
  LRH_PID=$!
  return 0
}

lrh_stop() {
  if [ -n "$LRH_PID" ]; then
    kill "$LRH_PID" 2>/dev/null
    wait "$LRH_PID" 2>/dev/null
  fi
  LRH_PID=""
  [ -z "$LRH_RESP" ] || rm -f "$LRH_RESP"
  return 0
}

lrh_lost() {
  [ -n "$LRH_LOST_FILE" ] && [ -f "$LRH_LOST_FILE" ]
}
