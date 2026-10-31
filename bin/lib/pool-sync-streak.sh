#!/bin/bash
# bin/lib/pool-sync-streak.sh — the pool stops its destroy loop after N push-path
# harness syncs in a row fail for one pool project (BH-8780).
#
# On 2026-10-29 05:00Z-12:10Z the hub's Fly tunnel was down. Every launch booted
# a machine, failed the harness sftp, destroyed the machine and put the row back,
# and the next tick did it again for every queued row: 996 times, with no alert.
# spawn_one runs in the background, so every row of a tick starts before any
# sync result returns. The streak therefore lives in a file across ticks:
#   state/pool-sync-streak/<p>.streak   one line: count \t epoch \t key \t mid \t why
#   state/pool-sync-streak/<p>.alerted  exists while this episode is alerted
# NOT in state/fly-pool/<p>: the pool counts every file there as a live machine.
#
#   pss_max [-q]                 the max from SYNC_FAIL_STREAK_MAX (0 = off);
#                                -q: no line for a bad value (the per-row reads)
#   pss_count <p>                the streak now (0 for a missing or bad file)
#   pss_note fail <p> <key> <mid> <why>
#                                +1; at count >= max, ONE alert per episode
#   pss_note ok <p> <key> <mid>  a push-path sync passed: the streak is 0 again
#   pss_tick_gate                caller's shell: a tick that starts tripped
#                                launches one probe machine (BUDGET 1, no hotfix
#                                exemption). Sets PSS_TICK_TRIPPED.
#   pss_stop_due                 rc 0 when the streak reached the max during
#                                THIS tick: the walk stops at the next row.
#
# A state dir the lib cannot write is no stop and no alert, never a failed tick.
# No root (HARNESS and H both empty): pss_note and pss_count return 1, and
# pss_count prints 0, so the gate and the stop read "no streak".
# Needs from the caller: HARNESS (or H), P (for the gate and the stop), say
# (optional).

_PSS_STOP_SAID=0

_pss_say() { if declare -F say >/dev/null 2>&1; then say "$@"; else echo "$*" >&2; fi; }

# The root is ${HARNESS:-${H:-}} and nothing else (D43): an empty root is a
# refusal (rc 1), never a path built from "".
_pss_dir() {
  local root="${HARNESS:-${H:-}}"
  [ -n "$root" ] || return 1
  printf '%s/state/pool-sync-streak' "$root"
}

pss_max() {
  # Settings row lane.fly-pool.sync_fail_streak_max
  # (catalog/lanes.d/fly-pool.knobs.d/SYNC_FAIL_STREAK_MAX.json); 5 is its
  # documented fallback.
  local v="${SYNC_FAIL_STREAK_MAX:-}" quiet=0
  [ "${1:-}" = -q ] && quiet=1
  [ -n "$v" ] || { echo 5; return 0; }
  case "$v" in
    *[!0-9]*) v="" ;;
    *) if [ "${#v}" -gt 3 ] || [ "$((10#$v))" -gt 100 ]; then v=""; else v=$((10#$v)); fi ;;
  esac
  if [ -z "$v" ]; then
    [ "$quiet" = 1 ] || _pss_say "SYNC_FAIL_STREAK_MAX=$SYNC_FAIL_STREAK_MAX is not a number of failures (0-100) — using 5"
    v=5
  fi
  echo "$v"
}

pss_count() {
  local d f n
  d=$(_pss_dir) || { echo 0; return 1; }
  f="$d/${1:-}.streak"
  [ -r "$f" ] || { echo 0; return 0; }
  n=$(head -n1 "$f" 2>/dev/null | cut -f1)
  case "$n" in ''|*[!0-9]*) echo 0 ;; *) if [ "${#n}" -gt 9 ]; then echo 0; else echo $((10#$n)); fi ;; esac
}

# _pss_write <p> <line> — tmp + mv, so a reader never sees half a line.
_pss_write() {
  local d; d=$(_pss_dir) || return 1
  printf '%s\n' "$2" > "$d/$1.streak.tmp" 2>/dev/null && mv -f "$d/$1.streak.tmp" "$d/$1.streak" 2>/dev/null
}

pss_note() {
  local what="${1:-}" p="${2:-}" key="${3:-}" mid="${4:-}" why="${5:-}" d n m rc=0
  [ -n "$p" ] || return 0
  d=$(_pss_dir) || return 1
  mkdir -p "$d" 2>/dev/null || return 0
  [ -w "$d" ] || return 0
  m=$(pss_max -q)
  # One field per value: a tab or a newline in the reason is a space.
  why=$(printf '%s' "$why" | tr '\t\r\n' '   ')
  [ -n "$why" ] || why="(no reason)"
  {
    command -v flock >/dev/null 2>&1 && flock -x 9
    n=$(pss_count "$p")
    case "$what" in
      fail)
        n=$((n + 1))
        _pss_write "$p" "$(printf '%s\t%s\t%s\t%s\t%s' "$n" "$(date +%s)" "$key" "$mid" "$why")"
        if [ "$m" -gt 0 ] && [ "$n" -ge "$m" ] && [ ! -e "$d/$p.alerted" ]; then
          # Alert first, marker only on a delivered alert: a failed alert is
          # tried again on the next failure.
          if HARNESS="${d%/state/pool-sync-streak}" "${d%/state/pool-sync-streak}/bin/alert-line.sh" --id "pool-sync-streak-$p" --project "$p" \
               "[pool/$p] harness sync failed $n times in a row (lane.fly-pool.sync_fail_streak_max=$m), last for $key to $mid: $why. The pool now launches one probe machine per tick until a sync passes. Check the hub's Fly WireGuard tunnel to the pool app's org (fly ssh sftp put to a started machine, the wire_guard_state peer in ~/.fly/config.yml, the count of flyctl agent processes)." \
               >/dev/null 2>&1; then
            : > "$d/$p.alerted" 2>/dev/null
          fi
        fi ;;
      ok)
        if [ "$n" -gt 0 ]; then
          _pss_write "$p" "$(printf '0\t%s\t%s\t%s\t%s' "$(date +%s)" "$key" "$mid" "sync passed")"
          if [ -e "$d/$p.alerted" ]; then
            rm -f "$d/$p.alerted"
            _pss_say "harness sync passed for $key on $mid: the streak of $n failures ends"
          fi
        fi ;;
      *) rc=2 ;;
    esac
  } 9>"$d/$p.lock"
  return "$rc"
}

pss_tick_gate() {
  local m n
  PSS_TICK_TRIPPED=0; _PSS_STOP_SAID=0
  m=$(pss_max); n=$(pss_count "${P:-}")
  [ "$m" -gt 0 ] && [ "$n" -ge "$m" ] || return 0
  PSS_TICK_TRIPPED=1
  # One probe machine: the definition of a probe, not a tunable cap.
  [ "${BUDGET:-0}" -gt 1 ] 2>/dev/null && BUDGET=1
  HOTFIX_EXTRA=0
  _pss_say "harness sync: $n failures in a row (sync_fail_streak_max=$m) — one probe launch this tick, the other rows stay queued"
  return 0
}

pss_stop_due() {
  local m n
  [ "${PSS_TICK_TRIPPED:-0}" = 0 ] || return 1
  m=$(pss_max -q); n=$(pss_count "${P:-}")
  [ "$m" -gt 0 ] && [ "$n" -ge "$m" ] || return 1
  if [ "$_PSS_STOP_SAID" = 0 ]; then
    _PSS_STOP_SAID=1
    _pss_say "harness sync: streak reached $n during this tick — no more launches this tick"
  fi
  return 0
}
