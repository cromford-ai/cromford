#!/bin/bash
# bin/lane-reaper.sh — every-box cron (*/10): kill a run-build.sh lane that is
# still ALIVE long past its deadline, or whose checkout has been deleted under
# it, and close the record it was holding.
#
# THE GAP (#643). Two BH-42 lanes ran for 21 hours out of a /tmp checkout that
# no longer existed. Nothing on the box had the job: bin/resume-dead-builds.sh
# only looks at builds whose process is GONE (a free key lock on a quiet dir),
# and bin/jobs-watchdog.sh judges LEDGER ROWS and executes nothing. A lane that
# is alive and useless sits between the two, holding its claim, its key lock and
# its build slot, until a human notices. This is the third lane: alive, late,
# and killed.
#
# THE ORDER IS THE CONTRACT, and it is this way round for one reason:
# run-build.sh installs an EXIT trap (_job_finish) that runs on SIGTERM while
# it waits on a child, and that trap closes the ledger row against whatever
# $BUILD/RESULT says. So the verdict is written FIRST, before any signal — a
# RESULT written after the kill is a row closed against nothing.
#   1. RESULT  "ABANDONED_TIMEOUT <why>"   (only if absent — never overwrite)
#   2. SIGTERM the lane's process group, wait, then SIGKILL. A pid that
#      survives SIGKILL is logged and left: NOT marked, NOT announced, retried.
#   3. release the claim (state/claims/<project>/<KEY>)
#   4. close the ledger row (job_update status=failed), fail-open
#   5. touch REAPED — "the kill landed and the claim is gone"
#   6. exactly ONE bin/lane-alert.sh line, LAST, quoting the RESULT actually on
#      disk (a lane that concluded on its own inside the TERM grace keeps its
#      own verdict, and the alert says so).
# A crash between any two steps costs at most one missing alert: it never costs
# a second kill, a second alert, or a REAPED dir whose process is still running.
#
# FINISHING A REAP WE DID NOT FINISH. A dir with OUR verdict and no REAPED is a
# kill we started and did not confirm: a SIGKILL that landed after our poll gave
# up, or a tick that died (reboot) between steps 1 and 5. SIGKILL runs no EXIT
# trap and a reboot runs nothing, so nobody else releases that claim or closes
# that row. So when we re-enter such a dir and the process it named is gone (or
# its pid has been reused), the kill HAS landed and we run steps 3-6. Without
# that, "retried" above would only ever work while the lane still breathed, and
# a dead one sat forever, claim held, nobody told.
#
# WHO ACTS ON IT: the results sweep in prompts/*.md, on `ABANDONED_TIMEOUT` with
# a REAPED marker present. A verdict with no REAPED is a kill that has not
# landed yet — the next tick finishes it.
#
# THE DEADLINE IS PER LANE (BH-1770, the operator 2026-09-24). A run is late when it
# has lived longer than LANE_REAP_DEADLINE_SECS since job.json's started_at. The
# knob is registered on this lane (catalog/lanes.d/lane-reaper.json, default
# 16200 = the old flat 4h30m) and resolved PER BUILD LANE through lane_knob:
#   lane.lane-reaper.<project>.lane_reap_deadline_secs   that project's builds
#   lane.lane-reaper.lane_reap_deadline_secs             every other build
#   LANE_REAP_DEADLINE_SECS in the env                    then the registry default
# A row is clamped to the registry's min/max. An operator who had tuned the
# old pair keeps that total as the env tier: when LANE_EXPECTED_SECS +
# LANE_REAP_GRACE_SECS is not 16200 and the env names no deadline, the sum is
# exported as it (a settings row still beats it). A dir with no usable
# started_at (absent, or 0 — no build writes that) predates this and keeps the
# old rule, expected_by + LANE_REAP_GRACE_SECS.
#
# WHO RELAUNCHES A REAPED RUN: bin/blocked-resolver.sh, and only it
# (br_from_builds' `abandoned-timeout`, on its capped rebuild ladder; ABANDONED
# with one alert once that is spent). The sweep closes the dir out and never
# relaunches it. The alert below says so.
#
# KNOBS (env -> flags/scheduler.conf -> the default here, via bin/lib/scheduler-conf.sh):
#   LANE_REAP_GRACE_SECS  1800   how long past expected_by before we act (legacy
#                                dirs only, see above)
#   LANE_REAP_MAX         20     reaps per tick; over the cap a dir is DEFERRED
#                                (no marker, re-offered next tick), never dropped
#   LANE_REAP_KILL_WAIT_S 30     TERM->KILL wait. A signal-delivery seam, not a
#                                business knob: env only, lowered by the suite.
# Kill switch: flags/lane-reaper-off (or the `switch.lane-reaper-off` settings
# row; answered before the lock and before any
# write). Self-overlap: flock -n on locks/lane-reaper.lock — a tick that finds
# the lock held exits 0 and waits for nobody.
#
# HUB AND FLY: no-op by construction. Hub build dirs are ingested from other
# boxes, so their pids are either dead here or belong to some unrelated local
# process — the cmdline and pgid checks refuse both. pool-* and fly-* dirs are
# skipped outright. Fly machines run no cron/*.cron at all.
set -uo pipefail
export PATH="/usr/local/bin:$PATH"   # cron PATH lacks it; the review-rescue scar
H="${HARNESS:-/root/harness}"

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-lane-reaper
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off lane-reaper.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit lane-reaper
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    lane-reaper
LOG="$H/logs/lane-reaper.log"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
log() { echo "$(STAMP) $*" >> "$LOG"; }

command -v lane_switch >/dev/null 2>&1 || . "$(dirname "${BASH_SOURCE[0]}")/lib/lane-switch.sh" 2>/dev/null || lane_switch() { [ -e "${HARNESS:-${H:-/root/harness}}/flags/$1" ]; }
lane_switch lane-reaper-off && exit 0
mkdir -p "$H/logs" "$H/locks" 2>/dev/null
if command -v flock >/dev/null 2>&1; then
  exec 9>"$H/locks/lane-reaper.lock"
  flock -n 9 || exit 0
fi

# Leaked session dbus-daemons (2026-11-09: 3,705 on small, OOM three times). One
# line in the log when it killed any. Its own switch: flags/dbus-orphan-reap-off.
_DBR=$(HARNESS="$H" bash "$(dirname "${BASH_SOURCE[0]}")/dbus-orphan-reap.sh" 2>/dev/null) || true
[ -n "$_DBR" ] && log "$_DBR"

GRACE=1800; MAX=20
# shellcheck source=bin/lib/scheduler-conf.sh
[ -r "$H/bin/lib/scheduler-conf.sh" ] && . "$H/bin/lib/scheduler-conf.sh" 2>/dev/null
if command -v sched_num >/dev/null 2>&1; then
  # The scheduler rows once, into this shell (BH-2478): each sched_* below runs in `$( )`.
  command -v conf_rows_preload >/dev/null 2>&1 && conf_rows_preload scheduler "$H"
  GRACE=$(sched_num LANE_REAP_GRACE_SECS 1800 "$H")
  MAX=$(sched_num LANE_REAP_MAX 20 "$H")
fi
case "$GRACE" in ''|*[!0-9]*) GRACE=1800 ;; esac
case "$MAX"   in ''|*[!0-9]*) MAX=20 ;; esac
# THE LEGACY TOTAL (BH-1770). A box that tuned LANE_EXPECTED_SECS or
# LANE_REAP_GRACE_SECS meant a different deadline than 4h30m; that sum becomes
# the new knob's env tier, below any settings row, so nothing about that box
# changes on the day this lands. A total of exactly 16200 IS the default and
# exports nothing, which leaves the registry default in charge.
LEGACY_EXP=14400
command -v sched_num >/dev/null 2>&1 && LEGACY_EXP=$(sched_num LANE_EXPECTED_SECS 14400 "$H")
case "$LEGACY_EXP" in ''|*[!0-9]*) LEGACY_EXP=14400 ;; esac
if [ -z "${LANE_REAP_DEADLINE_SECS:-}" ] && [ "$(( LEGACY_EXP + GRACE ))" != 16200 ]; then
  export LANE_REAP_DEADLINE_SECS=$(( LEGACY_EXP + GRACE ))
  log "LANE_EXPECTED_SECS + LANE_REAP_GRACE_SECS = $LANE_REAP_DEADLINE_SECS on this box: used as LANE_REAP_DEADLINE_SECS (a settings row still wins). Move it to the knob: bin/harness-ctl.sh set lane-reaper LANE_REAP_DEADLINE_SECS $LANE_REAP_DEADLINE_SECS"
fi

# reap_deadline <project> — prints "<seconds>\t<source>" for one build lane.
# lane_knob answers the project row, then the fleet row, then the env, then the
# registry default, clamped. Without the gate lib (a box mid-sync) it is the
# env, then 16200. Never empty, never zero.
declare -A DEADLINE_MEMO=()
reap_deadline() {
  local pj="${1:-}" v src
  if [ -n "${DEADLINE_MEMO[$pj]+x}" ]; then printf '%s' "${DEADLINE_MEMO[$pj]}"; return 0; fi
  if command -v lane_knob >/dev/null 2>&1; then
    v=$(lane_knob lane-reaper LANE_REAP_DEADLINE_SECS "$pj" 2>/dev/null)
    src="lane.lane-reaper[.$pj].lane_reap_deadline_secs, else the env, else the registry default"
  else
    v="${LANE_REAP_DEADLINE_SECS:-16200}"; src="the env, else 16200 (no lane gate on this box)"
  fi
  case "$v" in ''|*[!0-9]*|0) v=16200; src="16200 (the resolved value was not a positive number)" ;; esac
  DEADLINE_MEMO[$pj]="$v"$'\t'"$src"
  printf '%s' "${DEADLINE_MEMO[$pj]}"
}
KILL_WAIT="${LANE_REAP_KILL_WAIT_S:-30}"
case "$KILL_WAIT" in ''|*[!0-9]*) KILL_WAIT=30 ;; esac

NOW=$(date +%s)
# Field 5 of /proc/<pid>/stat is the process group; split AFTER the closing
# paren of comm, never on whitespace from the start (run-build.sh does the same).
SELF_PGID=$(sed 's/^.*) //' "/proc/$$/stat" 2>/dev/null | awk '{print $3}')

# A pid that exists AND is not a zombie. An already-collected lane still has a
# process-table entry until its parent reaps it, and "still listed" is not
# "still running" — signalling it would be pointless and marking it dead twice.
proc_alive() {
  kill -0 "$1" 2>/dev/null || return 1
  [ "$(sed 's/^.*) //' "/proc/$1/stat" 2>/dev/null | awk '{print $1}')" != Z ]
}

# Is the recorded pid still a live instance of THIS lane? Sets IDENT_KIND and
# IDENT_WHY (the words for the log line) to one of three answers:
#   live          up, looks like this lane, and its group is ours to signal
#   gone          exited, or the number now belongs to something else
#   unsignalable  it does look like the lane, but the recorded group is one we
#                 must never signal (0/1, our own, or not a number at all), or
#                 it is a live lane of this KEY in a different group (a same-KEY
#                 rebuild on a reused pid) — alive either way (BH-1142)
# Only "gone" lets an unfinished reap finish: an unsignalable lane may still be
# running and we refuse to call a running lane dead.
lane_state() { # lane_state <pid> <pgid> <key>
  local pid="$1" pgid="$2" key="$3" cmd live
  IDENT_KIND=gone; IDENT_WHY=""
  proc_alive "$pid" || { IDENT_WHY="pid $pid has exited"; return 1; }
  # PID REUSE. After a reboot the number can belong to anything, so the live
  # process must carry a run-build.sh command line with THIS key as a whole
  # argument (never a prefix — BH-64 is not BH-648).
  cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
  case "$cmd" in
    *run-build.sh*) : ;;
    *) IDENT_WHY="pid $pid is alive but is not a run-build.sh lane (pid reuse)"; return 1 ;;
  esac
  case " $cmd " in
    *" $key "*) : ;;
    *) IDENT_WHY="pid $pid runs a different key (pid reuse)"; return 1 ;;
  esac
  # We signal a process GROUP, so the group had better be the one this build
  # recorded — and never group 0/1, and never our own.
  IDENT_KIND=unsignalable
  case "$pgid" in ''|*[!0-9]*) IDENT_WHY="recorded pgid '$pgid' is not a number"; return 1 ;; esac
  [ "$pgid" -le 1 ] && { IDENT_WHY="recorded pgid $pgid is not a lane group"; return 1; }
  [ -n "$SELF_PGID" ] && [ "$pgid" = "$SELF_PGID" ] &&
    { IDENT_WHY="recorded pgid $pgid is our own group"; return 1; }
  # A live pid in a different group is not the process this build recorded,
  # but its command line is a run-build.sh of THIS key, so it is a live lane of
  # the ticket and we may not call it dead: finishing the reap would release
  # the claim of a lane that is still running (BH-1142). Unsignalable, not gone.
  live=$(sed 's/^.*) //' "/proc/$pid/stat" 2>/dev/null | awk '{print $3}')
  if [ "$live" != "$pgid" ]; then
    IDENT_WHY="recorded pgid $pgid does not match the live process group $live of a live $key lane"
    return 1
  fi
  IDENT_KIND=live
  return 0
}

# Steps 3-6: the half of a reap that runs once the process is gone. Same order,
# same idempotence, whether the kill landed in this tick or an earlier one.
finish_reap() { # finish_reap <dir> <project> <key> <job_id> <reason> <alert line>
  local d="$1" pj="$2" key="$3" jobid="$4" reason="$5" line="$6" b arc
  b=$(basename "$d")
  # (3) the claim
  rm -f "$H/state/claims/$pj/$key"

  # (4) the ledger row, fail-open. The lane's own EXIT trap may have closed it
  # already, in which case the worker refuses this transition — that is a
  # failure here and is logged as one, never as "closed".
  if [ -n "$jobid" ]; then
    if [ -z "$JC_SOURCED" ] && [ -r "$H/bin/jobs-client.sh" ]; then
      # shellcheck source=bin/jobs-client.sh
      . "$H/bin/jobs-client.sh" 2>/dev/null
      JC_SOURCED=1
    fi
    if command -v job_update >/dev/null 2>&1; then
      if job_update "$jobid" status=failed "meta=ABANDONED_TIMEOUT $reason" >/dev/null 2>&1; then
        log "[$pj/$key] $b: ledger row $jobid closed as failed"
      else
        log "[$pj/$key] $b: job_update on ledger row $jobid failed, row left to bin/jobs-watchdog.sh"
      fi
    else
      log "[$pj/$key] $b: no jobs client on this box, ledger row $jobid left to bin/jobs-watchdog.sh"
    fi
  fi

  # (5) the marker, then (6) the one line anybody reads
  touch "$d/REAPED"
  if [ -x "$H/bin/lane-alert.sh" ]; then
    "$H/bin/lane-alert.sh" --id "lane-reaper:$pj:$key" lane-reaper "$line"
    arc=$?
    [ "$arc" = 0 ] || log "[$pj/$key] $b: bin/lane-alert.sh exited $arc, the reap is done but nobody was told"
  else
    log "[$pj/$key] $b: no bin/lane-alert.sh on this box, the reap is done but nobody was told"
  fi
}

# The one sentence every reap alert ends with: who picks the ticket up (BH-1770).
RELAUNCH="bin/blocked-resolver.sh relaunches it on its capped rebuild ladder (the sweep does not), and pages ABANDONED if that ladder is spent."
REAPS=0; DEFERRED=0; JC_SOURCED=""
IDENT_KIND=""; IDENT_WHY=""
for D in "$H"/builds/*/; do
  D="${D%/}"; [ -d "$D" ] || continue
  B=$(basename "$D")
  # pool-* is the fly pool's bookkeeping; fly-* dirs are results ingested from a
  # machine that is not this one. Neither holds a pid we may signal.
  case "$B" in pool-*|fly-*) continue ;; esac
  [ -f "$D/job.json" ] || continue
  [ -f "$D/REAPED" ] && continue
  RETRY=""; VERDICT=""
  if [ -f "$D/RESULT" ]; then
    # A terminal verdict belongs to the sweep. The ONE exception is our own
    # unfinished reap (verdict written, kill not confirmed): that one we retry.
    VERDICT=$(head -1 "$D/RESULT" 2>/dev/null)
    case "$VERDICT" in
      ABANDONED_TIMEOUT*) RETRY=1 ;;
      *) continue ;;
    esac
  fi

  PJ=$(jq -r '.project // ""' "$D/job.json" 2>/dev/null)
  KEY=$(jq -r '.key // ""' "$D/job.json" 2>/dev/null)
  # A dir predating the lane declaration says nothing about who it is.
  [ -n "$PJ" ] && [ -n "$KEY" ] || continue
  PID=$(jq -r '.pid // ""' "$D/job.json" 2>/dev/null)
  PGID=$(jq -r '.pgid // ""' "$D/job.json" 2>/dev/null)
  SCRIPT=$(jq -r '.script // ""' "$D/job.json" 2>/dev/null)
  EXP=$(jq -r '.expected_by // ""' "$D/job.json" 2>/dev/null)
  STARTED=$(jq -r '.started_at // ""' "$D/job.json" 2>/dev/null)
  JOBID=$(jq -r '.job_id // ""' "$D/job.json" 2>/dev/null)

  # ABSENT IS NOT ZERO. A null pid is not pid 0 and a missing expected_by is not
  # "due in 1970" — both are unknown, and unknown is never a reason to kill. A
  # retry needs only the pid: the deadline was judged by the tick that wrote the
  # verdict, and the pid is what says whether the kill landed.
  # A started_at of 0 is not a start (no build writes it): that dir is judged
  # by the legacy expected_by rule, and then it is expected_by that must be known.
  case "$STARTED" in ''|*[!0-9]*|0) STARTED="" ;; esac
  UNKNOWN=""
  case "$PID" in ''|*[!0-9]*) UNKNOWN=1 ;; esac
  if [ -z "$RETRY" ] && [ -z "$STARTED" ]; then case "$EXP" in ''|*[!0-9]*) UNKNOWN=1 ;; esac; fi
  if [ -n "$UNKNOWN" ]; then
    log "[$PJ/$KEY] $B: pid or expected_by unknown in job.json (pid='$PID' expected_by='$EXP'), not reaped"
    continue
  fi

  lane_state "$PID" "$PGID" "$KEY"
  if [ "$IDENT_KIND" = unsignalable ]; then
    # We can neither signal it nor call it dead. It takes a hand-edited
    # job.json, or a live same-KEY lane in another process group, to get here,
    # so say so every tick. A retry dir stays unfinished: claim, ledger row and
    # REAPED are left alone until the pid is gone.
    log "[$PJ/$KEY] $B: $IDENT_WHY, not reaped"
    continue
  fi
  if [ "$IDENT_KIND" = gone ]; then
    if [ -z "$RETRY" ]; then
      # A dead pid is bin/resume-dead-builds.sh's lane and is skipped in silence
      # (every finished build on a box has one, and none of them are news). Pid
      # reuse gets a line, because it is not.
      case "$IDENT_WHY" in *"pid reuse"*) log "[$PJ/$KEY] $B: $IDENT_WHY, not reaped" ;; esac
      continue
    fi
    # Our verdict is on disk and the process it named is gone: the kill landed
    # after an earlier tick stopped watching. Finish what that tick started.
    if [ "$REAPS" -ge "$MAX" ]; then DEFERRED=$((DEFERRED + 1)); continue; fi
    REAPS=$((REAPS + 1))
    REASON="${VERDICT#ABANDONED_TIMEOUT }"
    [ "$REASON" = "$VERDICT" ] && REASON="no reason recorded in RESULT"
    log "[$PJ/$KEY] $B: finishing a reap an earlier tick started ($IDENT_WHY), $REASON"
    finish_reap "$D" "$PJ" "$KEY" "$JOBID" "$REASON" \
      "we killed the $PJ $KEY build lane in $B: $REASON. The kill landed after the tick that sent it had gone ($IDENT_WHY), so we have released its claim now and RESULT reads: $VERDICT. $RELAUNCH"
    continue
  fi

  if [ -n "$RETRY" ]; then
    # The reason was judged by the tick that wrote the verdict; this tick's only
    # job is to land the kill it could not confirm.
    REASON="${VERDICT#ABANDONED_TIMEOUT }"
    [ "$REASON" = "$VERDICT" ] && REASON="no reason recorded in RESULT"
  # Two reasons, and only these two.
  elif [ -n "$SCRIPT" ] && [ ! -e "$SCRIPT" ]; then
    REASON="script path gone ($SCRIPT)"
  elif [ -n "$STARTED" ]; then
    DL=$(reap_deadline "$PJ"); DLS="${DL%%$'\t'*}"; DLSRC="${DL#*$'\t'}"
    [ "$NOW" -gt "$(( STARTED + DLS ))" ] || continue
    REASON="past its $(( DLS / 60 ))m deadline (LANE_REAP_DEADLINE_SECS=$DLS for $PJ, from $DLSRC) by $(( (NOW - STARTED - DLS) / 60 ))m"
  elif [ "$NOW" -gt "$(( EXP + GRACE ))" ]; then
    REASON="past expected-by by $(( (NOW - EXP) / 60 ))m (a legacy dir with no started_at: expected_by + LANE_REAP_GRACE_SECS)"
  else
    continue
  fi

  # Over the cap the dir keeps NO marker: next tick offers it again.
  if [ "$REAPS" -ge "$MAX" ]; then DEFERRED=$((DEFERRED + 1)); continue; fi

  # (1) the verdict, before the signal, and never over somebody else's
  [ -f "$D/RESULT" ] || echo "ABANDONED_TIMEOUT $REASON" > "$D/RESULT"
  log "[$PJ/$KEY] $B: reaping pid $PID (pgid $PGID), $REASON"
  REAPS=$((REAPS + 1))

  # (2) the kill: TERM the group, give it $KILL_WAIT seconds to run its own EXIT
  # trap, then KILL. Bounded both times; we never wait on a lane forever.
  kill -TERM -- "-$PGID" 2>/dev/null
  I=0; N=$(( KILL_WAIT * 5 ))
  while proc_alive "$PID" && [ "$I" -lt "$N" ]; do sleep 0.2; I=$((I + 1)); done
  if proc_alive "$PID"; then
    kill -KILL -- "-$PGID" 2>/dev/null
    I=0; while proc_alive "$PID" && [ "$I" -lt 25 ]; do sleep 0.2; I=$((I + 1)); done
  fi
  if proc_alive "$PID"; then
    log "[$PJ/$KEY] $B: pid $PID survived SIGKILL, not marked REAPED and not announced, retried next tick"
    continue
  fi

  VERDICT=$(head -1 "$D/RESULT" 2>/dev/null)
  case "$VERDICT" in
    ABANDONED_TIMEOUT*) : ;;
    *) log "[$PJ/$KEY] $B: the lane wrote its own verdict during the grace, keeping it: $VERDICT" ;;
  esac

  finish_reap "$D" "$PJ" "$KEY" "$JOBID" "$REASON" \
    "we killed the $PJ $KEY build lane in $B: $REASON. Pid $PID is gone, its claim is released, and RESULT now reads: $VERDICT. $RELAUNCH"
done

[ "$DEFERRED" -gt 0 ] && log "cap reached: $REAPS reaped this tick, $DEFERRED deferred to the next one (LANE_REAP_MAX=$MAX)"
exit 0
