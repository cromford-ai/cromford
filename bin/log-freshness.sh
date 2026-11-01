#!/bin/bash
# bin/log-freshness.sh — BH-8417 (Scope E): the dead-log lane. A hub lane,
# every 15 minutes. One ALERTS line when a log that a prompt or a report reads
# has had no line for longer than LOG_FRESHNESS_MULT x its expected cadence.
#
#   log-freshness.sh            a tick (the cron line)
#   log-freshness.sh --check    parse every fragment, print one `row ...` line
#                               each, check that each owning lane is registered
#                               (catalog/lanes.d/<lane>.json); write nothing.
#                               rc 0 clean, rc 1 a bad row or an unreadable dir.
#
# WHY. logs/archie-fm-watch.log stopped on 2026-10-19 03:24Z and the Archie
# turn rule read it for seven days as "nothing found". A log that stops is
# silent by nature; only something that knows its cadence can say it stopped.
#
# THE LIST is one fragment per log, catalog/log-freshness.d/<log-name>.tsv
# (never a shared list): `#` comments, and rows of four TAB-separated fields
#   <log path relative to the harness root> <expected cadence s> <owning lane id> <reader>
# The path is relative, with no `..`; the cadence is a whole number > 0.
#
# THE JUDGE. A log's time is the leading timestamp of its newest stamped line
# (the last 200 lines are read). Accepted: 2026-10-26T07:22:47Z,
# `2026-10-26 07:22:47Z` (bin/alert-line.sh), an optional `[`, fractions and
# a +hh:mm offset; no zone is UTC. No stamped line: the file mtime. A touched
# file with no new line is judged by its line, not its mtime.
#   fresh   age <= MULT x cadence
#   stale   age >  MULT x cadence: ONE ALERTS line per (log, stale-since day),
#           naming the owning lane and the newest line time it read
#   absent  no file: ONE ALERTS line per (log, day)
# The dedup marker is state/log-freshness/alerted-<log-name>-<yyyymmdd>, the
# stale-since day (absent: today), written after the line. Markers older than
# LOG_FRESHNESS_KEEP_D days (by mtime) are deleted every run.
#
# OUTPUT. One line per run in logs/log-freshness.log:
#   <ts> logs=<n> fresh=<n> stale=<n> absent=<n> alerted=<n> bad_rows=<n> pruned=<n> mult=<m>
# rc 0 on every path but one: rc 1 when the fragment dir is unreadable.
# The lane reads only. It takes no lock, and it writes only its log, its
# markers and the ALERTS line (through bin/alert-line.sh).
#
# KNOBS (registry catalog/lanes.d/log-freshness.json; a settings row
# lane.log-freshness.<env lowercased> wins, through lane_env_apply):
#   LOG_FRESHNESS_MULT    3 (1..100)  stale past MULT x cadence
#   LOG_FRESHNESS_KEEP_D  7 (1..365)  marker retention, days
# A value outside its range is one warn line and the default (D11).
#
# OFF: flags/lane-off-log-freshness, or bin/harness-ctl.sh off log-freshness.
# Test seam: LOG_FRESHNESS_NOW (epoch), only under HARNESS_TEST_SANDBOX=1.
set -uo pipefail
H="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "$0")" && pwd)"
CHECK=0
case "${1:-}" in
  "") ;;
  --check) CHECK=1 ;;
  *) echo "usage: log-freshness.sh [--check]" >&2; exit 2 ;;
esac
FR="$H/catalog/log-freshness.d"

# parse_rows — every row of every fragment as `<file>:<n>\t<path>\t<cad>\t<lane>\t<reader>`
#   on stdout, or `BAD <file>:<n> <why>` for a row that does not parse.
parse_rows() {
  local f n line path cad lane reader rest
  for f in "$FR"/*.tsv; do
    [ -f "$f" ] || continue
    n=0
    while IFS= read -r line || [ -n "$line" ]; do
      n=$((n + 1))
      case "$line" in ''|'#'*) continue ;; esac
      IFS=$'\t' read -r path cad lane reader rest <<<"$line"
      if [ -z "${path:-}" ] || [ -z "${cad:-}" ] || [ -z "${lane:-}" ] || [ -z "${reader:-}" ] || [ -n "${rest:-}" ]; then
        printf 'BAD %s:%s not four TAB-separated fields\n' "${f##*/}" "$n"; continue
      fi
      case "$path" in /*|..|../*|*/..|*/../*) printf 'BAD %s:%s path %s is not relative to the harness root\n' "${f##*/}" "$n" "$path"; continue ;; esac
      if ! [[ $cad =~ ^[0-9]+$ ]] || [ "$((10#$cad))" -le 0 ]; then
        printf 'BAD %s:%s cadence %s is not a whole number of seconds > 0\n' "${f##*/}" "$n" "$cad"; continue
      fi
      [[ $lane =~ ^[A-Za-z0-9_.-]+$ ]] || { printf 'BAD %s:%s lane id %s\n' "${f##*/}" "$n" "$lane"; continue; }
      printf '%s:%s\t%s\t%s\t%s\t%s\n' "${f##*/}" "$n" "$path" "$((10#$cad))" "$lane" "$reader"
    done < "$f"
  done
}

if [ "$CHECK" = 1 ]; then
  [ -d "$FR" ] && [ -r "$FR" ] || { echo "log-freshness: $FR is unreadable"; exit 1; }
  bad=0
  while IFS= read -r r; do
    case "$r" in
      BAD\ *) echo "$r"; bad=$((bad + 1)); continue ;;
    esac
    IFS=$'\t' read -r _ path cad lane reader <<<"$r"
    if [ ! -f "$H/catalog/lanes.d/$lane.json" ]; then
      echo "BAD ${r%%$'\t'*} lane $lane has no catalog/lanes.d/$lane.json"; bad=$((bad + 1)); continue
    fi
    echo "row $path $cad $lane $reader"
  done < <(parse_rows)
  [ "$bad" = 0 ]; exit $?
fi

. "$H/bin/lib/env-path.sh" 2>/dev/null || . "$SELF/lib/env-path.sh" 2>/dev/null \
  || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }
HENV=$(harness_env_dir "$H")
# shellcheck disable=SC1091
[ -r "$HENV/global.env" ] && { set -a; . "$HENV/global.env" 2>/dev/null; set +a; }
# shellcheck source=bin/lib/lane-gate.sh
. "$H/bin/lib/lane-gate.sh" 2>/dev/null || . "$SELF/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit log-freshness
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply log-freshness

NOW=""
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [[ ${LOG_FRESHNESS_NOW:-} =~ ^[0-9]+$ ]]; then NOW=$LOG_FRESHNESS_NOW; fi
[ -n "$NOW" ] || NOW=$(date -u +%s)
mkdir -p "$H/logs" 2>/dev/null
LOG="$H/logs/log-freshness.log"
SD="$H/state/log-freshness"
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
log() { printf '%s %s\n' "$(iso "$NOW")" "$*" >> "$LOG"; }

# knob_int <ENV> <default> <min> <max> — out of range is one warn line and the
# default, never a silent clamp (D11).
knob_int() {
  local v="${!1:-}"
  [ -n "$v" ] || { printf '%s' "$2"; return 0; }
  if [[ $v =~ ^[0-9]+$ ]] && [ "$((10#$v))" -ge "$3" ] && [ "$((10#$v))" -le "$4" ]; then
    printf '%s' "$((10#$v))"
  else
    log "warn: $1=$v is outside $3..$4; using the default $2"
    printf '%s' "$2"
  fi
}
# Fallbacks: rows lane.log-freshness.log_freshness_mult and
# lane.log-freshness.log_freshness_keep_d (catalog/lanes.d/log-freshness.json).
MULT=$(knob_int LOG_FRESHNESS_MULT 3 1 100)
KEEP_D=$(knob_int LOG_FRESHNESS_KEEP_D 7 1 365)

if ! { [ -d "$FR" ] && [ -r "$FR" ] && [ -x "$FR" ]; }; then
  log "the fragment dir catalog/log-freshness.d is unreadable; nothing judged"
  exit 1
fi

# newest_ts <file> — the epoch of the newest stamped line's leading timestamp
#   on stdout, rc 0; rc 1 when none of the last 200 lines carries one.
newest_ts() {
  local s t
  s=$(tail -n 200 "$1" 2>/dev/null | grep -aoE '^\[?[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:?[0-9]{2})?' | tail -n 1)
  [ -n "$s" ] || return 1
  s=${s#[}
  case "$s" in *Z|*+[0-9][0-9]*|*-[0-9][0-9]:[0-9][0-9]|*-[0-9][0-9][0-9][0-9]) ;; *) s="${s}Z" ;; esac
  t=$(date -u -d "${s/ /T}" +%s 2>/dev/null) || return 1
  [[ $t =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$t"
}

# alert_once <log-name> <yyyymmdd> <text> — one ALERTS line per marker.
alert_once() {
  local m="$SD/alerted-$1-$2"
  [ -e "$m" ] && return 1
  mkdir -p "$SD" 2>/dev/null || { log "warn: $SD could not be made; no alert for $1 this run"; return 1; }
  ALERT_LINE_STAMP="$(date -u -d "@$NOW" '+%F %TZ')" HARNESS="$H" \
    "$H/bin/alert-line.sh" --severity warn --id "log-freshness:$1" "$3" >/dev/null 2>&1 || true
  : > "$m" && touch -d "@$NOW" "$m" 2>/dev/null \
    || log "warn: marker $m could not be written; the next run may alert again"
  return 0
}

N=0; FRESH=0; STALE=0; ABSENT=0; ALERTED=0; BAD=0; PRUNED=0
while IFS= read -r r; do
  case "$r" in BAD\ *) log "$r"; BAD=$((BAD + 1)); continue ;; esac
  IFS=$'\t' read -r _ path cad lane reader <<<"$r"
  N=$((N + 1))
  f="$H/$path"
  name=${path##*/}; name=${name%.log}; name=$(printf '%s' "$name" | tr -c 'A-Za-z0-9_.-' '_')
  lim=$(( MULT * cad ))
  if [ ! -e "$f" ]; then
    ABSENT=$((ABSENT + 1))
    alert_once "$name" "$(date -u -d "@$NOW" +%Y%m%d)" \
      "[log-freshness] $path is absent: expected a line every ${cad}s. Owning lane: $lane. Read by: $reader. Check the lane runs (bin/harness-ctl.sh show $lane) and writes this file." \
      && ALERTED=$((ALERTED + 1))
    continue
  fi
  src=line
  ts=$(newest_ts "$f") || { src=mtime; ts=$(stat -c %Y "$f" 2>/dev/null); }
  [[ ${ts:-} =~ ^[0-9]+$ ]] || { log "$path: no timestamp and no mtime could be read; not judged"; continue; }
  age=$(( NOW - ts ))
  if [ "$age" -le "$lim" ]; then FRESH=$((FRESH + 1)); continue; fi
  STALE=$((STALE + 1))
  what="newest line $(iso "$ts")"; [ "$src" = mtime ] && what="no timestamped line; file mtime $(iso "$ts")"
  alert_once "$name" "$(date -u -d "@$(( ts + lim ))" +%Y%m%d)" \
    "[log-freshness] $path is stale: $what, $((age / 60))m ago, past ${MULT} x ${cad}s. Owning lane: $lane. Read by: $reader. Until it writes again, a reader of this log sees old news, not \"nothing found\"." \
    && ALERTED=$((ALERTED + 1))
done < <(parse_rows)

if [ -d "$SD" ]; then
  cut=$(( NOW - KEEP_D * 86400 ))
  for m in "$SD"/alerted-*; do
    [ -f "$m" ] || continue
    mt=$(stat -c %Y "$m" 2>/dev/null) || continue
    if [ "$mt" -lt "$cut" ]; then rm -f "$m" && PRUNED=$((PRUNED + 1)); fi
  done
fi

log "logs=$N fresh=$FRESH stale=$STALE absent=$ABSENT alerted=$ALERTED bad_rows=$BAD pruned=$PRUNED mult=$MULT"
exit 0
