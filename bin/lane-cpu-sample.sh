#!/bin/bash
# bin/lane-cpu-sample.sh — CPU share per lane over a short window (BH-6173).
#
#   bin/lane-cpu-sample.sh [--seconds N] [--interval I] [--proc-root DIR] [--lane NAME] [--max-pct P]
#   bin/lane-cpu-sample.sh --snapshot [--proc-root DIR]
#   bin/lane-cpu-sample.sh --diff A B [C ...] [--lane NAME] [--max-pct P]
#
# A read-only operator tool. It proves acceptance bullet 3 of #6173 on the hub:
# "state-backup and its zstd under 2% across one 15-minute cycle". Run it once
# with --seconds 900 --interval 5 from minute 4 of an hour (docs/RESTORE.md,
# "Measuring the backup's CPU on the hub").
#
# Default mode: a snapshot every --interval seconds (default: --seconds, so two
# snapshots) across --seconds (20), each pair diffed and added up. Ticks are
# utime + stime (fields 14 and 15 of <proc-root>/<pid>/stat, split after the
# LAST ") " so a comm with ") " in it still parses). Each process counts under
# the nearest ancestor (itself included) whose cmdline names bin/<name>.sh, so
# the tar and zstd that bin/state-backup.sh starts count as "state-backup". A
# process with no such ancestor counts as "other". A script under /bin, /sbin
# or /usr is never a lane, and the helpers jobs-client, lane-alert, alert-line,
# beat and hub-lease are not lanes either: they count for the lane that
# started them.
#
# EXITED PROCESSES COUNT (lead review lr-6328 of 8aea09438). When a child
# exits and is reaped, the kernel adds its ticks to the parent's cutime +
# cstime (fields 16 and 17), the 5th snapshot column. A parent's growth there
# counts for the lane of the child it reaped: a child that is in snapshot A
# but not in B, its lane read in A's tree. So the tar, zstd, find and aws runs
# that start and stop inside the window, and a whole state-backup run that
# ends inside it (cron reaps it), count for state-backup. The reaped total is
# the child's whole life, so what snapshot A already showed of that child
# (its ticks and its own reaped ticks) comes off: earlier intervals counted
# it, and each tick counts once (lead review lr-6328 of d3288ba23).
#
# Output: one "<share>\t<lane>" row per lane, share = 100 * lane / total with
# one decimal, largest first. A last line "<lane> share=S% PASS|FAIL (limit P%)"
# follows. --lane defaults to state-backup and --max-pct to 2; each one works
# alone. PASS means the printed share is under P; equal is FAIL. A lane not in
# the sample has share 0.0.
#
# Limit: a run that starts AND ends inside one --interval, under a parent that
# is not a lane (cron), counts as that parent's lane ("other"). A short
# interval bounds that: at --interval 5 the most it can miss is 5 s per run.
#
# --snapshot prints "<pid>\t<ppid>\t<ticks>\t<lane or ->\t<reaped ticks>"
# per process. --diff also reads 4-column rows (reaped ticks 0).
# --diff A B: a pid only in B counts from 0; a pid with fewer ticks in B than
# in A (reused pid) counts its B ticks; the lane walk follows ppid in B (A for
# a reaped child), at most 64 hops.
#
# Exit: 0 table and PASS; 1 table and FAIL (share at or over the limit);
# 2 total ticks 0, so there is no share and no verdict; 64 bad arguments or
# bad input. Writes nothing but its two temp snapshots, named lcs.<pid>.XXXXXX
# (removed by the trap, also on SIGTERM, also one mktemp made before the
# script knew its name). Starts mktemp and sleep, and forks subshells for its own arithmetic; its
# own CPU counts under the lane "lane-cpu-sample" (about 1% on the hub).
set -uo pipefail

usage() {
  echo "usage: lane-cpu-sample.sh [--seconds N] [--interval I] [--proc-root DIR] [--lane NAME] [--max-pct P] | --snapshot [--proc-root DIR] | --diff A B [C ...] [--lane NAME] [--max-pct P]" >&2
  [ -n "${1:-}" ] && echo "lane-cpu-sample: $1" >&2
  exit 64
}

MODE=sample; SECONDS_N=20; INTERVAL_N=""; PROC_ROOT=/proc
LANE=state-backup; MAXPCT=2; LANE_GIVEN=0; DIFF_FILES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --seconds)   [ $# -ge 2 ] || usage "--seconds needs a value"; SECONDS_N="$2"; shift 2 ;;
    --interval)  [ $# -ge 2 ] || usage "--interval needs a value"; INTERVAL_N="$2"; shift 2 ;;
    --proc-root) [ $# -ge 2 ] || usage "--proc-root needs a value"; PROC_ROOT="$2"; shift 2 ;;
    --lane)      [ $# -ge 2 ] || usage "--lane needs a value"; LANE="$2"; LANE_GIVEN=1; shift 2 ;;
    --max-pct)   [ $# -ge 2 ] || usage "--max-pct needs a value"; MAXPCT="$2"; LANE_GIVEN=1; shift 2 ;;
    --snapshot)  MODE=snapshot; shift ;;
    --diff)      MODE="diff"; shift
                 while [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; do DIFF_FILES+=("$1"); shift; done
                 [ "${#DIFF_FILES[@]}" -ge 2 ] || usage "--diff needs at least two files" ;;
    *)           usage "unknown argument: $1" ;;
  esac
done
case "$SECONDS_N" in ''|*[!0-9]*|0) usage "--seconds must be a whole number above 0" ;; esac
[ -n "$INTERVAL_N" ] || INTERVAL_N=$SECONDS_N
case "$INTERVAL_N" in ''|*[!0-9]*|0) usage "--interval must be a whole number above 0" ;; esac
[ -d "$PROC_ROOT" ] || usage "--proc-root $PROC_ROOT is not a directory"
[ "$MODE" != snapshot ] || [ "$LANE_GIVEN" = 0 ] || usage "--snapshot takes no --lane or --max-pct"
[[ "$LANE" =~ ^[A-Za-z0-9._-]+$ ]] || usage "bad lane name: $LANE"
[[ "$MAXPCT" =~ ^[0-9]+(\.[0-9])?$ ]] || usage "--max-pct must be a number with at most one decimal"
if [ "$MODE" = diff ]; then
  for f in "${DIFF_FILES[@]}"; do [ -r "$f" ] && [ -f "$f" ] || usage "cannot read $f"; done
fi

# snapshot: one row per readable pid. A pid that vanishes mid-read is skipped.
snapshot() {
  local d pid raw rest lane a
  local -a f args
  for d in "$PROC_ROOT"/[0-9]*; do
    pid=${d##*/}
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    raw=""
    IFS= read -r -d '' raw 2>/dev/null < "$d/stat"
    [ -n "$raw" ] || continue
    rest=${raw##*) }
    [ "$rest" != "$raw" ] || continue
    read -r -a f <<< "$rest"
    # f[0] is field 3 (state): ppid is f[1], utime f[11], stime f[12],
    # cutime f[13], cstime f[14].
    [[ "${f[1]:-}" =~ ^[0-9]+$ && "${f[11]:-}" =~ ^[0-9]+$ && "${f[12]:-}" =~ ^[0-9]+$ ]] || continue
    [[ "${f[13]:-}" =~ ^[0-9]+$ ]] || f[13]=0
    [[ "${f[14]:-}" =~ ^[0-9]+$ ]] || f[14]=0
    lane=-
    args=()
    mapfile -d '' -t args 2>/dev/null < "$d/cmdline"
    for a in "${args[@]}"; do
      case "$a" in /bin/*|/sbin/*|/usr/*) continue ;; esac
      if [[ "$a" =~ (^|/)bin/([A-Za-z0-9._-]+)\.sh$ ]]; then
        case "${BASH_REMATCH[2]}" in jobs-client|lane-alert|alert-line|beat|hub-lease) continue ;; esac
        lane=${BASH_REMATCH[2]}; break
      fi
    done
    printf '%s\t%s\t%s\t%s\t%s\n' "$pid" "${f[1]}" $(( f[11] + f[12] )) "$lane" $(( f[13] + f[14] ))
  done
}

# accumulate A B: add the ticks between two snapshots to SUM[lane] and TOTAL.
declare -A SUM=(); TOTAL=0
accumulate() {
  local -A ticks_a=() ppid_a=() lane_a=() ctk_a=() ticks_b=() ppid_b=() lane_b=() ctk_b=()
  local pid ppid tk ln ck n delta cd name kid
  n=0
  while IFS=$'\t' read -r pid ppid tk ln ck; do
    n=$((n+1))
    [[ "$pid" =~ ^[0-9]+$ && "$ppid" =~ ^[0-9]+$ && "$tk" =~ ^[0-9]+$ && -n "$ln" && "${ck:-0}" =~ ^[0-9]+$ ]] || usage "$1:$n is not a snapshot row"
    ticks_a[$pid]=$tk; ppid_a[$pid]=$ppid; lane_a[$pid]=$ln; ctk_a[$pid]=${ck:-0}
  done < "$1"
  n=0
  while IFS=$'\t' read -r pid ppid tk ln ck; do
    n=$((n+1))
    [[ "$pid" =~ ^[0-9]+$ && "$ppid" =~ ^[0-9]+$ && "$tk" =~ ^[0-9]+$ && -n "$ln" && "${ck:-0}" =~ ^[0-9]+$ ]] || usage "$2:$n is not a snapshot row"
    ticks_b[$pid]=$tk; ppid_b[$pid]=$ppid; lane_b[$pid]=$ln; ctk_b[$pid]=${ck:-0}
  done < "$2"
  # lane_of <pid> <a|b>: the nearest lane up the ppid chain of that snapshot.
  lane_of() {
    local c="$1" h=0 l p
    while [ "$h" -le 64 ]; do
      if [ "$2" = a ]; then l=${lane_a[$c]:-}; p=${ppid_a[$c]:-}; else l=${lane_b[$c]:-}; p=${ppid_b[$c]:-}; fi
      [ -n "$l" ] || break
      [ "$l" = - ] || { printf '%s' "$l"; return; }
      c=$p; h=$((h+1))
    done
    printf other
  }
  # seen_a <pid>: the ticks snapshot A already showed of <pid> and of every
  # descendant (in A's tree) that is gone at B: their own ticks plus their
  # reaped ticks at A. A reaper's growth includes all of them.
  seen_a() {
    local root="$1" n=0 c todo=("$1") k
    while [ "${#todo[@]}" -gt 0 ]; do
      c=${todo[0]}; todo=("${todo[@]:1}")
      n=$(( n + ${ticks_a[$c]:-0} + ${ctk_a[$c]:-0} ))
      for k in "${!ppid_a[@]}"; do
        [ "${ppid_a[$k]}" = "$c" ] && [ "$k" != "$root" ] && [ -z "${ticks_b[$k]+x}" ] && todo+=("$k")
      done
      [ "${#todo[@]}" -le 4096 ] || break
    done
    printf '%s' "$n"
  }
  for pid in "${!ticks_b[@]}"; do
    delta=$(( ticks_b[$pid] - ${ticks_a[$pid]:-0} ))
    [ "$delta" -ge 0 ] || delta=${ticks_b[$pid]}
    if [ "$delta" -gt 0 ]; then
      name=$(lane_of "$pid" b)
      SUM[$name]=$(( ${SUM[$name]:-0} + delta ))
      TOTAL=$(( TOTAL + delta ))
    fi
    # Reaped ticks: counted for the lane of a child that A had under this pid
    # and B does not (it exited inside the window), else for this pid's lane.
    # The reaped total is the child's WHOLE life, and A already showed part of
    # it (its own ticks and its reaped ticks at A), which earlier intervals
    # counted. So that part comes off, clamped at 0: only the child's last,
    # unseen interval counts here (lead review lr-6328 of d3288ba23).
    cd=$(( ctk_b[$pid] - ${ctk_a[$pid]:-0} ))
    [ "$cd" -ge 0 ] || cd=${ctk_b[$pid]}
    [ "$cd" -gt 0 ] || continue
    name=""
    for kid in "${!ppid_a[@]}"; do
      [ "${ppid_a[$kid]}" = "$pid" ] && [ -z "${ticks_b[$kid]+x}" ] || continue
      cd=$(( cd - $(seen_a "$kid") ))
      [ -n "$name" ] && [ "$name" != other ] && continue
      name=$(lane_of "$kid" a)
    done
    [ "$cd" -gt 0 ] || continue
    [ -n "$name" ] && [ "$name" != other ] || name=$(lane_of "$pid" b)
    SUM[$name]=$(( ${SUM[$name]:-0} + cd ))
    TOTAL=$(( TOTAL + cd ))
  done
}

# report: the share table over SUM, then the verdict line for --lane.
report() {
  local name i j tmp t10 m10 verdict total=$TOTAL
  local -A sum=()
  for name in "${!SUM[@]}"; do sum[$name]=${SUM[$name]}; done
  if [ "$total" -eq 0 ]; then echo "LCS total 0 ticks"; return 2; fi
  # Sort lanes by ticks, largest first, then by name: a handful of lanes, so
  # an insertion sort in the shell beats starting sort(1).
  local -a order=()
  for name in "${!sum[@]}"; do
    order+=("$name")
    i=$(( ${#order[@]} - 1 ))
    while [ "$i" -gt 0 ]; do
      j=$((i-1))
      if [ "${sum[${order[$j]}]}" -lt "${sum[${order[$i]}]}" ] ||
         { [ "${sum[${order[$j]}]}" -eq "${sum[${order[$i]}]}" ] && [[ "${order[$j]}" > "${order[$i]}" ]]; }; then
        tmp=${order[$j]}; order[j]=${order[$i]}; order[i]=$tmp; i=$j
      else break; fi
    done
  done
  # share10: the share in tenths of a percent, rounded half up.
  share10() { echo $(( ($1 * 1000 * 2 + total) / (total * 2) )); }
  for name in "${order[@]}"; do
    t10=$(share10 "${sum[$name]}")
    printf '%d.%d\t%s\n' $((t10 / 10)) $((t10 % 10)) "$name"
  done
  t10=$(share10 "${sum[$LANE]:-0}")
  case "$MAXPCT" in *.*) m10=$(( 10#${MAXPCT%.*} * 10 + 10#${MAXPCT#*.} )) ;; *) m10=$(( 10#$MAXPCT * 10 )) ;; esac
  verdict=PASS; [ "$t10" -lt "$m10" ] || verdict=FAIL
  printf '%s share=%d.%d%% %s (limit %s%%)\n' "$LANE" $((t10 / 10)) $((t10 % 10)) "$verdict" "$MAXPCT"
  [ "$verdict" = PASS ]
}

case "$MODE" in
  snapshot) snapshot; exit 0 ;;
  diff)     for ((k = 1; k < ${#DIFF_FILES[@]}; k++)); do accumulate "${DIFF_FILES[k-1]}" "${DIFF_FILES[k]}"; done
            report; exit $? ;;
esac

SNAP_A="" SNAP_B="" SLEEPER=""
cleanup() {
  [ -n "$SLEEPER" ] && kill "$SLEEPER" 2>/dev/null
  [ -n "$SNAP_A" ] && rm -f -- "$SNAP_A"
  [ -n "$SNAP_B" ] && rm -f -- "$SNAP_B"
  # A TERM between mktemp and the assignment leaves a file with no name here.
  rm -f -- "${TMPDIR:-/tmp}/lcs.$$."*
}
trap cleanup EXIT
SNAP_A=$(mktemp "${TMPDIR:-/tmp}/lcs.$$.XXXXXX") || { echo "lane-cpu-sample: mktemp failed" >&2; exit 64; }
SNAP_B=$(mktemp "${TMPDIR:-/tmp}/lcs.$$.XXXXXX") || { echo "lane-cpu-sample: mktemp failed" >&2; exit 64; }
snapshot > "$SNAP_A"
# One snapshot every --interval seconds across --seconds, each pair added up:
# a process seen in any snapshot is counted when it exits (its reaper's ticks
# go to its lane), so only a run that starts and ends inside ONE interval can
# be missed.
left=$SECONDS_N
while [ "$left" -gt 0 ]; do
  step=$INTERVAL_N; [ "$step" -le "$left" ] || step=$left
  # In the background and waited on, so a SIGTERM runs the trap at once.
  sleep "$step" & SLEEPER=$!
  wait "$SLEEPER"; SLEEPER=""
  snapshot > "$SNAP_B"
  accumulate "$SNAP_A" "$SNAP_B"
  swap=$SNAP_A; SNAP_A=$SNAP_B; SNAP_B=$swap
  left=$(( left - step ))
done
report
exit $?
