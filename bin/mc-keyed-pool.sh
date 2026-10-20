#!/bin/bash
# bin/mc-keyed-pool.sh — BH-7139: the bounded pool for keyed conductor ticks.
#
# WHY. kw_conductor (bin/lib/keyed-wake.sh) started one detached
# `MC_ONLY_PR=<slug>#<n> bin/merge-conductor.sh` per call, with no bound on how
# many ran at once. On 2026-10-16 the hub (8 CPUs) ran load 171-238 with 26-112
# keyed ticks alive at one time; each tick got slower, so more overlapped.
#
# A QUEUE, NOT A DROP. kw_conductor writes one entry per PR into
# state/merge-conductor/keyed-queue/ (a second wake for a PR that is still
# queued folds into that entry) and starts `mc-keyed-pool.sh drain` detached.
# Every entry runs, oldest first. Nothing is ever dropped by a cap.
#
#   drain   take a free slot (locks/mc-keyed-slot-<i>.lock, flock -n, i < N),
#           pop the oldest entry, run its keyed tick in the foreground under
#           that slot, pop the next one when it ends. No free slot: exit 0, the
#           entry stays queued (a slot holder or the next start takes it). A
#           holder that releases its slot looks at the queue again, so an entry
#           written while every slot was busy is never stranded.
#           bin/merge-conductor-wake.sh starts one drain every minute as the
#           backstop.
#   status  one line: queued=<n> running=<n> slots=<N>.
#
# LOAD SHED (BH-7509). While state/hub-load/verdict says the hub is over
# hub_load.max_runnable (bin/lib/hub-load-shed.sh hls_over), the pool shrinks
# to a FLOOR OF ONE slot (slot 0), so merges never stop while the hub is over:
# a drain logs one `load-shed p90=<n> max=<n> — 1 slot floor, <q> queued`
# line and takes slot 0 only; slot 0 busy means exit 0, the entries stay
# queued. A holder of any other slot checks before each next pop and stops
# between entries. Pool off (N=0) while over: no detached start, the drain
# runs as N=1. status is unchanged. No verdict file, or a stale one, means no
# shed.
#
# N = MC_KEYED_MAX_PARALLEL (settings row lane.merge-conductor.mc_keyed_max_parallel,
# code default 4, catalog/lanes.d/merge-conductor.knobs.d). 0 = the pool is
# off: every queued entry starts detached at once, the behaviour before BH-7139.
#
# Queue entry: one file per PR, `<owner>+<repo>#<n>`, one TSV line:
#   <enqueued epoch> TAB <owner/repo> TAB <n> TAB <solo> TAB <lock-wait-s> TAB <why>
# Log: logs/merge-conductor-keyed-pool.log, one line per run and per full pool.
set -uo pipefail
H="${MC_H:-${HARNESS:-/root/harness}}"
Q="$H/state/merge-conductor/keyed-queue"
SCRIPT="$H/bin/merge-conductor.sh"
LOG="$H/logs/merge-conductor-keyed-pool.log"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
say() { mkdir -p "$H/logs" 2>/dev/null; echo "$(STAMP) [mc-keyed-pool] $*" >> "$LOG"; }

# The slot count. The settings row through lane_knob when the lane gate loads,
# else the environment, else 4. A value that is not a number is 4, with a line.
slots() {
  local v=""
  if [ -z "${_KP_GATE:-}" ]; then
    _KP_GATE=1
    # shellcheck source=bin/lib/lane-gate.sh
    . "$H/bin/lib/lane-gate.sh" 2>/dev/null || true
  fi
  if command -v lane_knob >/dev/null 2>&1; then v=$(lane_knob merge-conductor MC_KEYED_MAX_PARALLEL)
  else v="${MC_KEYED_MAX_PARALLEL:-}"; fi
  case "$v" in
    '') v=4 ;;
    *[!0-9]*) say "MC_KEYED_MAX_PARALLEL='$v' is not a number — using 4"; v=4 ;;
  esac
  printf '%s' "$v"
}

# shellcheck source=bin/lib/hub-load-shed.sh
. "$H/bin/lib/hub-load-shed.sh" 2>/dev/null || . "$(dirname "$0")/lib/hub-load-shed.sh" 2>/dev/null \
  || hls_over() { return 1; }
# shed — rc 0 (with one log line) when the hub is over its load limit.
shed() { hls_over "$H" || return 1; say "$HLS_LINE — 1 slot floor, $(queued) queued"; }

qlock() { exec 4>>"$Q/.lock" && flock -w 10 4; }
qunlock() { flock -u 4 2>/dev/null; exec 4>&-; }

# queued — the number of entries.
queued() { find "$Q" -maxdepth 1 -type f -name '*#*' 2>/dev/null | grep -c .; }

# pop — print the oldest entry's line and remove it. rc 1 when the queue is empty.
pop() {
  local f line
  qlock || return 1
  f=$(for e in "$Q"/*#*; do
        [ -f "$e" ] || continue
        printf '%s\t%s\n' "$(cut -f1 "$e" 2>/dev/null | head -1)" "$e"
      done | sort -n -k1,1 | head -1 | cut -f2-)
  if [ -z "$f" ]; then qunlock; return 1; fi
  line=$(head -1 "$f" 2>/dev/null); rm -f "$f"
  qunlock
  printf '%s\n' "$line"
}

# run_entry <line> <mode> — mode fg (under a slot) or bg (pool off).
run_entry() {
  local at slug num solo wait why waited
  IFS=$'\t' read -r at slug num solo wait why <<<"$1"
  [[ "$slug" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] && [[ "$num" =~ ^[0-9]+$ ]] || { say "bad entry dropped: $1"; return 0; }
  case "$at" in ''|*[!0-9]*) at=$(date +%s) ;; esac
  waited=$(( $(date +%s) - at ))
  [ "$solo" = - ] && solo=""
  [ "$wait" = - ] && wait=""
  [ "$why" = - ] && why=""
  # The same environment kw_conductor always gave a keyed tick: every lock fd
  # closed (fd 5 is this drain's slot), the backstop's window cleared.
  # MC_KEYED_READY_FLOOR=1 (BH-7376): no `timeout` runs over a pool run, so a
  # READY row's worker may take the whole READY arm (mc_keyed_deadline_floor).
  if [ "$2" = fg ]; then
    say "run $slug#$num slot=$SLOT waited_s=$waited queued=$(queued)${why:+ ($why)}"
    MC_ONLY_PR="$slug#$num" WAKE_LAUNCH=1 MC_KEYED_READY_FLOOR=1 MC_FANIN_SOLO_RUN="$solo" MC_PR_LOCK_WAIT_S="$wait" \
      MC_WORKERS_DONE_BY='' MC_WINDOW_DEFER_FILE='' "$SCRIPT" </dev/null >/dev/null 2>&1 9>&- 8>&- 7>&- 6>&- 5>&- 4>&-
  else
    say "run $slug#$num pool=off waited_s=$waited${why:+ ($why)}"
    ( MC_ONLY_PR="$slug#$num" WAKE_LAUNCH=1 MC_KEYED_READY_FLOOR=1 MC_FANIN_SOLO_RUN="$solo" MC_PR_LOCK_WAIT_S="$wait" \
      MC_WORKERS_DONE_BY='' MC_WINDOW_DEFER_FILE='' setsid "$SCRIPT" </dev/null >/dev/null 2>&1 9>&- 8>&- 7>&- 6>&- 5>&- 4>&- & ) 2>/dev/null
  fi
}

# take_slot <N> — hold one free slot on fd 5, SLOT=<i>. rc 1 when all are busy.
take_slot() {
  local i=0
  mkdir -p "$H/locks" 2>/dev/null
  while [ "$i" -lt "$1" ]; do
    if exec 5>>"$H/locks/mc-keyed-slot-$i.lock" && flock -n 5; then SLOT=$i; return 0; fi
    exec 5>&-
    i=$((i + 1))
  done
  return 1
}

# running <N> — slots held right now.
running() {
  local i=0 n=0
  while [ "$i" -lt "$1" ]; do
    [ -e "$H/locks/mc-keyed-slot-$i.lock" ] && ! flock -n "$H/locks/mc-keyed-slot-$i.lock" true 2>/dev/null && n=$((n + 1))
    i=$((i + 1))
  done
  printf '%s' "$n"
}

mkdir -p "$Q" 2>/dev/null
case "${1:-}" in
  status)
    N=$(slots)
    echo "queued=$(queued) running=$(running "$N") slots=$N"
    exit 0 ;;
  drain) ;;
  *) echo "usage: mc-keyed-pool.sh drain|status" >&2; exit 2 ;;
esac

[ -x "$SCRIPT" ] || { say "bin/merge-conductor.sh not executable — the queue waits"; exit 0; }
N=$(slots)
if [ "$N" = 0 ]; then
  while [ "$(queued)" -gt 0 ] && ! hls_over "$H" && L=$(pop); do run_entry "$L" bg; done
  # Over with entries left: the floor slot runs them in the foreground.
  [ "$(queued)" -gt 0 ] && hls_over "$H" || exit 0
  N=1
fi
SLOT=""
while :; do
  [ "$(queued)" -gt 0 ] || exit 0
  NT=$N
  if shed; then NT=1; fi
  if ! take_slot "$NT"; then
    say "full: $(queued) queued, $NT of $NT slots busy — the queue waits for a free slot"
    exit 0
  fi
  RAN=0; SHED=0
  while :; do
    # Slot 0 is the floor: it keeps popping while over; any other slot stops.
    if [ "$SLOT" != 0 ] && shed; then SHED=1; break; fi
    L=$(pop) || break
    run_entry "$L" fg; RAN=$((RAN + 1))
  done
  flock -u 5 2>/dev/null; exec 5>&-
  [ "$SHED" = 0 ] || exit 0
  # The queue lock did not answer: stop here, the next start drains it.
  [ "$RAN" -gt 0 ] || { say "queue lock busy — $(queued) queued wait for the next drain"; exit 0; }
  # Released: look again, so an entry written while this slot was busy runs.
done
