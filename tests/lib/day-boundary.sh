#!/bin/bash
# tests/lib/day-boundary.sh — clear_boundary: never start a timed case on the
# wrong side of a UTC period boundary. Sourced, never executed.
#
# Why: the #6049 audit found 63 suites that compute `date -u` day stamps
# (%Y%m%d, %F, %Y-%m-%d). The code under test reads the day, then the suite
# reads it again to build the expected value. A run that straddles 00:00Z reads
# two different days and goes red on a correct build.
#
#   clear_boundary <period_s> <margin_s>
#
# If the next multiple of <period_s> on the epoch clock is <margin_s> seconds
# away or less, sleep until 1 s past it, with one line to stderr that says why.
# Otherwise return at once, silent. `epoch % 86400 == 0` is exactly 00:00:00Z,
# so `clear_boundary 86400 <margin>` keeps the next <margin> seconds of the run
# inside one UTC day. The margin must cover the run time of the cases that read
# the day. rc 0 on every valid call; rc 2 (no sleep) when an argument is not a
# positive integer or <margin_s> >= <period_s>.
#
# Use it the same way in every suite:
#   . "$(dirname "$0")/lib/day-boundary.sh" || exit 1
#   clear_boundary 86400 <margin> || exit 1
#
# #6049 adds a clear_boundary of its own in tests/lib/wait-for.sh. If one is
# already defined when this file is sourced, this file defines nothing, so the
# first definition wins.

if declare -F clear_boundary >/dev/null; then
  return 0
fi

clear_boundary() {
  local period=${1:-} margin=${2:-} now left
  case "$period" in ''|0*|*[!0-9]*) echo "clear_boundary: bad args" >&2; return 2 ;; esac
  case "$margin" in ''|0*|*[!0-9]*) echo "clear_boundary: bad args" >&2; return 2 ;; esac
  if [ "$#" -ne 2 ] || [ "$margin" -ge "$period" ]; then
    echo "clear_boundary: bad args" >&2
    return 2
  fi
  now=$(date -u +%s) || return 2
  case "$now" in ''|*[!0-9]*) echo "clear_boundary: unreadable clock '$now'" >&2; return 2 ;; esac
  left=$(( period - now % period ))
  if [ "$left" -le "$margin" ]; then
    echo "clear_boundary: waiting $(( left + 1 ))s for the ${period}s boundary" >&2
    sleep "$(( left + 1 ))"
  fi
  return 0
}
