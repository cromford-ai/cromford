#!/bin/bash
# bin/settings-jq-sample.sh — how many jq processes read the settings cache, and
# their CPU seconds per hour, over a short window (BH-7717).
#
#   bin/settings-jq-sample.sh [--seconds N] [--interval-ms M] [--proc-root DIR]
#
# A read-only operator tool. Defaults: --seconds 60, --interval-ms 50,
# --proc-root /proc. Every --interval-ms it runs ONE grep over
# <proc-root>/[0-9]*/cmdline for the text settings-cache.json, then reads each
# candidate's cmdline once and keeps the pid when its argv0 basename is
# exactly `jq` and an argument names settings-cache.json. Per pid it keeps the highest
# utime + stime it saw (fields 14 and 15 of <proc-root>/<pid>/stat, split after
# the LAST ") "). CLK_TCK is getconf CLK_TCK (100 if that fails); test seam
# SJS_CLK_TCK (digits only, else ignored).
#
# Output, one line:
#   settings_jq pids=<n> per_min=<n*60/N> cpu_s_per_h=<ticks*3600/(CLK_TCK*N)> window_s=<N> interval_ms=<M> (lower bound: ...)
# Both rates are a LOWER BOUND: a jq that starts and ends between two polls is
# not seen, and a jq's ticks after its last poll are not counted.
#
# Hub before/after proof (BH-7717): run the same command before and after the
# merge reaches the hub, and compare the two lines:
#   /root/harness/bin/settings-jq-sample.sh --seconds 900 --interval-ms 50
#
# Exit: 0 one line printed; 64 bad arguments or an unreadable --proc-root.
# Writes nothing.
set -uo pipefail

usage() {
  echo "usage: settings-jq-sample.sh [--seconds N] [--interval-ms M] [--proc-root DIR]" >&2
  [ -n "${1:-}" ] && echo "settings-jq-sample: $1" >&2
  exit 64
}

SECS=60; IVMS=50; ROOT=/proc
while [ $# -gt 0 ]; do
  case "$1" in
    --seconds)     [ $# -ge 2 ] || usage "--seconds needs a value"; SECS="$2"; shift 2 ;;
    --interval-ms) [ $# -ge 2 ] || usage "--interval-ms needs a value"; IVMS="$2"; shift 2 ;;
    --proc-root)   [ $# -ge 2 ] || usage "--proc-root needs a value"; ROOT="$2"; shift 2 ;;
    -h|--help)     usage ;;
    *)             usage "unknown argument: $1" ;;
  esac
done
case "$SECS" in ''|*[!0-9]*|0*) usage "--seconds must be a positive integer" ;; esac
case "$IVMS" in ''|*[!0-9]*|0*) usage "--interval-ms must be a positive integer" ;; esac
[ -d "$ROOT" ] && [ -r "$ROOT" ] || usage "--proc-root $ROOT is not a readable directory"

CLK=""
case "${SJS_CLK_TCK:-}" in ''|*[!0-9]*|0*) ;; *) CLK=$SJS_CLK_TCK ;; esac
[ -n "$CLK" ] || CLK=$(getconf CLK_TCK 2>/dev/null)
case "$CLK" in ''|*[!0-9]*|0*) CLK=100 ;; esac

now_ms() {
  local t
  if [ -n "${EPOCHREALTIME:-}" ]; then t=${EPOCHREALTIME/[.,]/}; NOW_MS=$(( 10#$t / 1000 ))
  else NOW_MS=$(( $(date +%s%N) / 1000000 )); fi
}
SLEEP=$(printf '%d.%03d' "$((IVMS / 1000))" "$((IVMS % 1000))")

declare -A TICKS=()
# poll — one pass over <proc-root>: record the highest ticks per matching jq pid.
poll() {
  local cf d pid a hit line rest f t
  local -a av
  while IFS= read -r cf; do
    d=${cf%/cmdline}; pid=${d##*/}
    # The grep only finds candidates. A pid can exec between the grep and this
    # read (a bash child whose cmdline named the cache becomes a jq over
    # another file), so both rules are decided from this one read.
    av=(); mapfile -t -d '' av 2>/dev/null < "$cf" || continue
    [ "${#av[@]}" -gt 1 ] && [ "${av[0]##*/}" = jq ] || continue
    hit=""
    for a in "${av[@]:1}"; do case "$a" in *settings-cache.json*) hit=1; break ;; esac; done
    [ -n "$hit" ] || continue
    line=""; IFS= read -r line 2>/dev/null < "$d/stat" || :
    case "$line" in *") "*) ;; *) continue ;; esac
    rest=${line##*) }
    read -r -a f <<<"$rest"
    case "${f[11]:-}${f[12]:-}" in ''|*[!0-9]*) continue ;; esac
    t=$(( f[11] + f[12] ))
    [ "${TICKS[$pid]:--1}" -ge "$t" ] || TICKS[$pid]=$t
  done < <(grep -l -a -F settings-cache.json "$ROOT"/[0-9]*/cmdline 2>/dev/null)
}

now_ms; END=$(( NOW_MS + SECS * 1000 ))
while :; do
  poll
  now_ms; [ "$NOW_MS" -lt "$END" ] || break
  sleep "$SLEEP"
done

N=${#TICKS[@]}; SUM=0
for pid in "${!TICKS[@]}"; do SUM=$(( SUM + TICKS[$pid] )); done
awk -v n="$N" -v s="$SUM" -v w="$SECS" -v c="$CLK" -v iv="$IVMS" 'BEGIN{
  printf "settings_jq pids=%d per_min=%.1f cpu_s_per_h=%.1f window_s=%d interval_ms=%d (lower bound: a jq that starts and ends between two polls is not seen)\n",
    n, n * 60 / w, s * 3600 / (c * w), w, iv }'
