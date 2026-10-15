#!/bin/bash
# shellcheck shell=bash
# bin/lib/warm-bust.sh — BH-6710: the warm-layer bust key. Sourced, never run.
#
# fly/Dockerfile's warm stage (clone + install + warm `next build`) is cached
# by the WARM_BUST build arg. The key used to be $(date -u +%F), so every warm
# layer went cold at 00:00Z and the first propagate tick after midnight rebuilt
# every pool in the serial cold lane. Now the nightly bin/fly-image-refresh.sh
# rolls the key when it starts, and every reader uses the rolled key.
#
# FORMAT  <fly-state-dir>/warm-bust, one line: "<YYYY-MM-DD> <epoch>\n", the
#         UTC date of <epoch> and the epoch the refresh rolled it at.
# CONTRACT (no wall clock inside: every caller passes its own epoch)
#   warm_bust_roll <fly-state-dir> <now-epoch>
#       writes the line for <now-epoch> (tmp + mv). rc 0 written, 1 not.
#   warm_bust_read <fly-state-dir> <now-epoch>
#       prints "<date> <epoch>" and returns 0 when the line parses, <date> is
#       the UTC date of <epoch>, <epoch> is not after <now-epoch>, and <date>
#       is today or yesterday. Anything else prints nothing and returns 1, and
#       the caller uses the date rule ($(date -u +%F)), as before this file.

warm_bust_roll() {
  local dir="${1:-}" now="${2:-}" day tmp
  [ -n "$dir" ] || return 1
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  day=$(date -u -d "@$now" +%F 2>/dev/null) || return 1
  mkdir -p "$dir" 2>/dev/null || return 1
  tmp="$dir/warm-bust.tmp.$$"
  if printf '%s %s\n' "$day" "$now" > "$tmp" 2>/dev/null && mv -f "$tmp" "$dir/warm-bust" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  return 1
}

warm_bust_read() {
  local dir="${1:-}" now="${2:-}" d="" e="" extra="" today yday
  [ -n "$dir" ] && [ -r "$dir/warm-bust" ] || return 1
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  read -r d e extra < "$dir/warm-bust" || [ -n "$d" ] || return 1
  [ -z "$extra" ] || return 1
  case "$d" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;; *) return 1 ;; esac
  case "$e" in ''|*[!0-9]*) return 1 ;; esac
  [ "$e" -le "$now" ] || return 1
  [ "$(date -u -d "@$e" +%F 2>/dev/null)" = "$d" ] || return 1
  today=$(date -u -d "@$now" +%F 2>/dev/null) || return 1
  yday=$(date -u -d "@$(( now - 86400 ))" +%F 2>/dev/null) || return 1
  [ "$d" = "$today" ] || [ "$d" = "$yday" ] || return 1
  printf '%s %s\n' "$d" "$e"
}
