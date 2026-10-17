# shellcheck shell=bash
# bin/lib/mc-tick-clock.sh — BH-7139: the wall clock of the merge conductor's
# full (cron) tick. Sourced, never run. Defines functions only.
#
# WHY. On 2026-10-16 one cron full tick was 51 minutes old on a */30 cron and
# nothing said so. A full tick now writes a start stamp, logs its wall time when
# it ends, and the minute lane (bin/merge-conductor-wake.sh) alerts ONCE when a
# live full tick is older than 2 cron periods. Alerts only: nothing is killed.
#
#   mc_tick_clock_start  in bin/merge-conductor.sh after the keyed-tick parse.
#                        A full tick (MC_ONLY_KEYS empty) writes
#                        state/merge-conductor/full-tick/<pid>.start (epoch).
#                        A keyed tick writes nothing.
#   mc_tick_clock_end    before the full tick's last hb_done: one line
#                        `FULL_TICK wall_s=<n>` (mc_log) and the stamp removed.
#   mc_tick_clock_check <home> <period-s> — for each stamp: a pid that is gone
#                        (or is not a merge-conductor process) -> the stamp is
#                        removed with one line; a live one older than
#                        2 x <period-s> -> ONE alert (bin/alert-line.sh --id
#                        mc-full-tick-slow) and a `.alerted` marker, so later
#                        checks stay quiet for that tick. Prints its lines on
#                        stdout.
# Period: MC_FULL_TICK_PERIOD_S (settings row lane.merge-conductor.mc_full_tick_period_s,
# code default 1800 = the */30 cron line, catalog/lanes.d/merge-conductor.knobs.d).

_mc_clock_dir() { printf '%s/full-tick' "${MC_STATE_DIR:-${MC_H:-${HARNESS:-${H:-}}}/state/merge-conductor}"; }

mc_tick_clock_start() {
  [ -z "${MC_ONLY_KEYS:-}" ] || return 0
  local d; d=$(_mc_clock_dir)
  mkdir -p "$d" 2>/dev/null || return 0
  _MC_CLOCK_T0=$(date +%s)
  printf '%s\n' "$_MC_CLOCK_T0" > "$d/$$.start" 2>/dev/null || true
  return 0
}

mc_tick_clock_end() {
  [ -n "${_MC_CLOCK_T0:-}" ] || return 0
  local d wall line
  d=$(_mc_clock_dir)
  wall=$(( $(date +%s) - _MC_CLOCK_T0 ))
  line="FULL_TICK wall_s=$wall pid=$$ (BH-7139: the cron full tick's wall time)"
  if command -v mc_log >/dev/null 2>&1; then mc_log "$line"; else echo "$line"; fi
  rm -f "$d/$$.start" "$d/$$.start.alerted" 2>/dev/null
  _MC_CLOCK_T0=""
  return 0
}

# _mc_clock_live <pid> — rc 0 when <pid> runs and is a merge-conductor process.
_mc_clock_live() {
  kill -0 "$1" 2>/dev/null || return 1
  [ -r "/proc/$1/cmdline" ] || return 0
  tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null | grep -q 'merge-conductor'
}

mc_tick_clock_check() {
  local home="${1:-${HARNESS:-${H:-}}}" period="${2:-1800}" d f pid t0 age lim now
  [ -n "$home" ] || return 0
  case "$period" in ''|*[!0-9]*) period=1800 ;; esac
  [ "$period" -gt 0 ] || period=1800
  lim=$(( 2 * period ))
  d="$home/state/merge-conductor/full-tick"
  [ -d "$d" ] || return 0
  now=$(date +%s)
  for f in "$d"/*.start; do
    [ -f "$f" ] || continue
    pid=$(basename "$f" .start)
    case "$pid" in ''|*[!0-9]*) rm -f "$f"; continue ;; esac
    if ! _mc_clock_live "$pid"; then
      rm -f "$f" "$f.alerted"
      echo "FULL_TICK pid=$pid is gone — its start stamp removed (no end line: the tick was killed or exited early)"
      continue
    fi
    t0=$(head -1 "$f" 2>/dev/null); case "$t0" in ''|*[!0-9]*) continue ;; esac
    age=$(( now - t0 ))
    [ "$age" -gt "$lim" ] || continue
    [ -e "$f.alerted" ] && continue
    "$home/bin/alert-line.sh" --severity warn --id mc-full-tick-slow \
      "[merge-conductor] the cron full tick pid=$pid has run ${age}s, more than 2 cron periods (2 x ${period}s, MC_FULL_TICK_PERIOD_S). Nothing is stopped. Check the hub load and logs/merge-conductor-cron.log (BH-7139)" \
      >/dev/null 2>&1 || true
    : > "$f.alerted"
    echo "FULL_TICK pid=$pid age_s=$age > ${lim}s — one alert written"
  done
  return 0
}
