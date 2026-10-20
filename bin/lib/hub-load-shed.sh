#!/bin/bash
# bin/lib/hub-load-shed.sh — the hub load verdict: one writer, one reader.
#
# bin/hub-load-sample.sh (every 10 min, hub only) writes state/hub-load/verdict
# with hls_write. The spawners (bin/mc-keyed-pool.sh drain, bin/fly-pool.sh
# SPAWN, bin/fly-pool-tick.sh, bin/project-lane-run.sh) read it with hls_over
# before they fork, and start no new worker while it says over.
#
# The file is one line of TAB-separated key=value fields, written by tmp + mv:
#   v=1 at=<epoch> runnable=<x|NA> p90=<x|NA> max=<n>
#   state=<over|under|insufficient> max_age_s=<n> shed=<1|0>
#   [lanes=<id,id,...> lanes_src=<row|env|catalog|default>]
# shed=0 is the operator's kill switch (settings row hub_load.shed=off). It
# travels in the file, so a reader makes no settings call. lanes= is the shed
# lane list the sampler resolved (settings row hub_load.shed_lanes, env
# HUB_LOAD_SHED_LANES, the catalog's `"sheds": true` lanes, HLS_SPAWN_LANES).
# The two lanes fields are optional and still v=1: a reader ignores keys it
# does not know, and a bad lanes= field is ignored, not malformed.
#
# The reader FAILS OPEN: no file, a malformed or stale line, shed=0, or any
# state but over means "do not shed", and the spawner runs as before. A box
# with no sampler (every box but the hub, every Fly machine) has no file.
#
# Only lanes that fork builds or agent sessions shed (hls_lane_sheds). A lane
# that only reads state (fleet-status-push, dequeue-watch, archie-fm, ...)
# keeps running while over. bin/lane-sheds-lint.sh refuses a spawning project
# lane with no `sheds` field in its catalog/lanes.d file.
#
# Sourcing this file has no side effects. Root: the argument, else
# ${HARNESS:-${H:-}}; with no root the reader answers no-file.
# Doc: docs/notes/2026-10-19-BH-7509-hub-load-shed.md,
# docs/notes/2026-10-20-BH-7659-hub-load-shed-knobs.md.

# hls_lanes_ok <list> — rc 0 when <list> (comma or space separated) holds
# 1..64 lane ids, each ^[a-z0-9][a-z0-9._-]{0,63}$. One bad id refuses all.
# The character check comes first, so the unquoted split below never globs.
hls_lanes_ok() {
  local l n=0
  [[ "${1:-}" =~ ^[a-z0-9,._\ -]+$ ]] || return 1
  for l in ${1//,/ }; do
    [[ "$l" =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]] || return 1
    n=$((n + 1))
  done
  [ "$n" -ge 1 ] && [ "$n" -le 64 ]
}

# hls_write <file> <at> <runnable> <p90> <max> <state> <max_age_s> <shed>
#           [<lanes> <lanes_src>]
# rc 0 when the line is in place, rc 1 on bad input or a failed write. The
# lanes pair is both or neither; lanes is written comma separated.
hls_write() {
  [ "$#" -eq 8 ] || [ "$#" -eq 10 ] || return 1
  local f="$1" tmp extra="" l lanes=""
  [ -n "$f" ] || return 1
  [[ "$2" =~ ^[0-9]+$ ]] && [[ "$5" =~ ^[0-9]+$ ]] && [[ "$7" =~ ^[0-9]+$ ]] || return 1
  case "$6" in over|under|insufficient) ;; *) return 1 ;; esac
  case "$8" in 0|1) ;; *) return 1 ;; esac
  if [ "$#" -eq 10 ]; then
    hls_lanes_ok "$9" || return 1
    case "${10}" in row|env|catalog|default) ;; *) return 1 ;; esac
    for l in ${9//,/ }; do lanes="${lanes:+$lanes,}$l"; done
    extra=$(printf '\tlanes=%s\tlanes_src=%s' "$lanes" "${10}")
  fi
  tmp="$f.tmp.$$"
  if { printf 'v=1\tat=%s\trunnable=%s\tp90=%s\tmax=%s\tstate=%s\tmax_age_s=%s\tshed=%s%s\n' \
         "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$extra" > "$tmp"; } 2>/dev/null && mv -f "$tmp" "$f" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  return 1
}

# hls_over [harness-dir] — rc 0: shed now; sets HLS_P90, HLS_MAX and
# HLS_LINE="load-shed p90=<p90> max=<max>". rc 1: do not shed; sets HLS_WHY to
# no-file|malformed|stale|shed-off|under|insufficient.
# Every call also sets HLS_LANES (the line's lanes=, space separated) and
# HLS_LANES_SRC, or empties both when the line has no valid lanes field.
# Now = HUB_LOAD_SHED_NOW (test seam, digits only), else the clock. Stale: the
# line is older than its max_age_s, or more than 300 s in the future.
hls_over() {
  local root="${1:-${HARNESS:-${H:-}}}" f line kv now
  local v="" at="" p90="" max="" state="" age="" shed="" lanes="" lsrc=""
  HLS_P90=""; HLS_MAX=""; HLS_LINE=""; HLS_WHY=""; HLS_LANES=""; HLS_LANES_SRC=""
  f="$root/state/hub-load/verdict"
  if [ -z "$root" ] || [ ! -f "$f" ]; then HLS_WHY=no-file; return 1; fi
  line=""
  IFS= read -r line < "$f" 2>/dev/null
  local -a kvs=()
  IFS=$'\t' read -r -a kvs <<<"$line"
  for kv in "${kvs[@]}"; do
    case "$kv" in
      v=*) v=${kv#v=} ;;
      at=*) at=${kv#at=} ;;
      p90=*) p90=${kv#p90=} ;;
      max=*) max=${kv#max=} ;;
      state=*) state=${kv#state=} ;;
      max_age_s=*) age=${kv#max_age_s=} ;;
      shed=*) shed=${kv#shed=} ;;
      lanes=*) lanes=${kv#lanes=} ;;
      lanes_src=*) lsrc=${kv#lanes_src=} ;;
    esac
  done
  if [[ "$lanes" =~ ^[a-z0-9,._-]+$ ]] && hls_lanes_ok "$lanes"; then
    case "$lsrc" in row|env|catalog|default) HLS_LANES=${lanes//,/ }; HLS_LANES_SRC=$lsrc ;; esac
  fi
  if [ "$v" != 1 ] || ! [[ "$at" =~ ^[0-9]{1,12}$ ]] || ! [[ "$max" =~ ^[0-9]{1,9}$ ]] \
     || ! [[ "$age" =~ ^[0-9]{1,9}$ ]] || ! [[ "$shed" =~ ^[01]$ ]] \
     || ! [[ "$p90" =~ ^(NA|[0-9]+(\.[0-9]+)?)$ ]]; then
    HLS_WHY=malformed; return 1
  fi
  case "$state" in
    over) [ "$p90" != NA ] || { HLS_WHY=malformed; return 1; } ;;
    under|insufficient) ;;
    *) HLS_WHY=malformed; return 1 ;;
  esac
  if [[ "${HUB_LOAD_SHED_NOW:-}" =~ ^[0-9]+$ ]]; then now=$HUB_LOAD_SHED_NOW; else printf -v now '%(%s)T' -1; fi
  if [ $((now - at)) -gt "$age" ] || [ $((at - now)) -gt 300 ]; then HLS_WHY=stale; return 1; fi
  [ "$shed" = 1 ] || { HLS_WHY=shed-off; return 1; }
  [ "$state" = over ] || { HLS_WHY=$state; return 1; }
  HLS_P90=$p90; HLS_MAX=$max
  HLS_LINE="load-shed p90=$p90 max=$max"
  return 0
}

# HLS_SPAWN_LANES — the project lanes bin/project-lane-run.sh sheds: each one
# forks a build, a fix round or an agent session per project. The code
# fallback: the catalog's `"sheds": true` lanes are the source, and
# tests/lane-sheds-field.bh-7659-test.sh pins this list equal to them.
HLS_SPAWN_LANES="alert-triage alerts-medic blocked-resolver review-autopilot review-rescue stranded-watch watchdog-responder"

# hls_lane_sheds <lane> — rc 0 when <lane> is a spawning lane that sheds.
# The list: HLS_LANES (the verdict's lanes=, set by hls_over), else
# HUB_LOAD_SHED_LANES (space or comma separated), else HLS_SPAWN_LANES.
hls_lane_sheds() {
  local lane="${1:-}" l list="${HLS_LANES:-${HUB_LOAD_SHED_LANES:-$HLS_SPAWN_LANES}}"
  [ -n "$lane" ] || return 1
  for l in ${list//,/ }; do [ "$l" = "$lane" ] && return 0; done
  return 1
}
