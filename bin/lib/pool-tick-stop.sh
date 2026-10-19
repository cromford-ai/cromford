#!/bin/bash
# bin/lib/pool-tick-stop.sh — the row-boundary stop rule for a pool tick (BH-7475).
#
# A fly-pool.sh tick holds locks/fly-pool-<p>.lock for its whole process life.
# On 2026-10-19 a project-6-os tick that started on old code at 01:53Z held it
# for 5.5 h, and every tick on the new code exited "already running". The tick
# now calls pts_stop_due at each row boundary of its REAP and SPAWN walks, and
# stops (rc 0 from pts_stop_due) when:
#   age   the tick has run POOL_TICK_MAX_AGE_S or more seconds since it took the
#         lock (settings row lane.fly-pool.pool_tick_max_age_s, code default
#         1200, 0 = off). One log line and ONE ALERTS line per tick.
#   code  the files this tick loaded (its own script and every lib/<name>.sh it
#         names) have a different stat fingerprint from the one at tick start.
#         rsync and lrc_sync replace a file by rename, so a new inode is new
#         code. One log line, no alert. An empty start fingerprint turns the
#         code check off (fail open).
# If both are true, the tick reports age. After a stop every later call returns
# 0 and writes nothing.
#
# The root is ${HARNESS:-${H:-}}. With no root, pts_init returns 1 and sets no
# start time, so pts_stop_due never stops the tick (fail open).
#
#   pts_init       call right after the lock is taken, from the tick's top level
#   pts_code_fp    print the fingerprint of the files in PTS_FILES
#   pts_stop_due   rc 0 = stop at this row boundary; PTS_STOP = age|code
# PTS_NOW (epoch seconds) replaces the clock; tests use it.

_pts_now() { printf '%s\n' "${PTS_NOW:-$(date +%s)}"; }

pts_init() {
  local root self dir n f seen=" "
  PTS_STOP=""; PTS_T0=""; PTS_FP0=""; PTS_FILES=()
  root="${HARNESS:-${H:-}}"
  [ -n "$root" ] || return 1
  PTS_ROOT="$root"
  PTS_T0=$(_pts_now)
  self="${BASH_SOURCE[1]:-$0}"
  PTS_SELF="$self"
  dir=$(dirname "$self")
  PTS_FILES=("$self")
  for n in $(grep -oE 'lib/[a-z0-9._-]+\.sh' "$self" 2>/dev/null | sort -u); do
    n="${n#lib/}"
    for f in "$root/bin/lib/$n" "$dir/lib/$n"; do
      case "$seen" in *" $f "*) ;; *) PTS_FILES+=("$f"); seen="$seen$f " ;; esac
    done
  done
  PTS_FP0=$(pts_code_fp)
  return 0
}

pts_code_fp() {
  [ "${#PTS_FILES[@]}" -gt 0 ] || return 0
  stat -L -c '%n %i %s %Y' "${PTS_FILES[@]}" 2>/dev/null | cksum | tr -d ' \n'
}

_pts_say() {
  echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [pool/$P] $*" >> "$PTS_ROOT/logs/fly-pool.log"
}

pts_stop_due() {
  [ -n "${PTS_STOP:-}" ] && return 0
  [ -n "${PTS_T0:-}" ] && [ -n "${PTS_ROOT:-}" ] || return 1
  local max age fp
  max=$(printf '%s' "${POOL_TICK_MAX_AGE_S:-1200}" | tr -dc '0-9')
  [ -n "$max" ] || max=1200
  if [ "${#max}" -gt 5 ]; then max=86400; else max=$((10#$max)); [ "$max" -gt 86400 ] && max=86400; fi
  age=$(( $(_pts_now) - PTS_T0 ))
  if [ "$max" -gt 0 ] && [ "$age" -ge "$max" ]; then
    PTS_STOP=age
    _pts_say "tick stopped at a row boundary: it has run ${age}s, past POOL_TICK_MAX_AGE_S=${max}s; the lock is released and the remaining rows wait for the next tick"
    HARNESS="$PTS_ROOT" "$PTS_ROOT/bin/alert-line.sh" --id "pool-tick-max-age-$P" --project "$P" \
      "[pool/$P] tick ran ${age}s, past POOL_TICK_MAX_AGE_S=${max}s: it stopped at a row boundary and released the lock; check logs/fly-pool.log" >/dev/null 2>&1 || true
    return 0
  fi
  [ -n "${PTS_FP0:-}" ] || return 1
  fp=$(pts_code_fp)
  if [ "$fp" != "$PTS_FP0" ]; then
    PTS_STOP=code
    _pts_say "tick stopped at a row boundary: the deployed pool code changed since the tick started (fp $PTS_FP0 -> $fp); the lock is released and the next tick runs the new code"
    return 0
  fi
  return 1
}
