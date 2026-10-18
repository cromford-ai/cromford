#!/bin/bash
# bin/lib/fleet-version-sink.sh — sourced by bin/fleet-version-check.sh, never
# executed. fvc_sink reads the full fvc_decide output on stdin, after the lane
# wrote its alerts.
#
# fvc_sink — stores the lag of each box for the console Machines view
# (BH-7191.4). A row comes from two line shapes only (20-lag.sh writes them;
# the trailing `m` is optional):
#   OK <box> lag=<n>m
#   ALERT <box> lag lag=<n>m sha=<8>
# Every other line is not a row: `lag>=<n>m` (a lower bound, not the lag),
# `lag unreadable`, `sha not on main`, nosha, SKIP. The last line for a box
# wins. At most 200 boxes (the route cap).
#
# With rows: ONE `POST /api/boxes/lag {rows:[{box,lag_min}]}`, never retried,
# and ONE log line: `posted <n> lag rows`, `lag post failed (http <code|none>)`
# or `jobs client not loaded`. With no rows: no POST and no line. The line goes
# to $LOG (the lane sets it), else $HARNESS/logs/fleet-version-check.log, else
# stderr. Always rc 0 and nothing on stdout: the alerts are already written.
_fvc_sink_log() {
  local line
  line="$(date -u '+%Y-%m-%dT%H:%M:%SZ') fvc_sink: $*"
  if [ -n "${LOG:-}" ]; then
    { echo "$line" >> "$LOG"; } 2>/dev/null && return 0
  elif [ -n "${HARNESS:-}" ]; then
    { echo "$line" >> "$HARNESS/logs/fleet-version-check.log"; } 2>/dev/null && return 0
  fi
  echo "$line" >&2
}

fvc_sink() {
  local tsv n body rc
  tsv=$(awk '
    function keep(box, v) {
      if (box !~ /^[A-Za-z0-9._-]+$/ || length(box) > 64) return
      sub(/^lag=/, "", v); sub(/m$/, "", v)
      if (!(box in val)) { if (count >= 200) return; order[++count] = box }
      val[box] = v + 0
    }
    $1 == "OK" && $3 ~ /^lag=[0-9]+m?$/ { keep($2, $3); next }
    $1 == "ALERT" && $3 == "lag" && $4 ~ /^lag=[0-9]+m?$/ { keep($2, $4); next }
    END { for (i = 1; i <= count; i++) printf "%s\t%d\n", order[i], val[order[i]] }
  ')
  [ -n "$tsv" ] || return 0
  n=$(printf '%s\n' "$tsv" | grep -c .)
  if ! command -v _jobs_req >/dev/null 2>&1; then
    _fvc_sink_log "jobs client not loaded"; return 0
  fi
  body=$(printf '%s\n' "$tsv" | jq -Rnc '{rows: [inputs | split("\t") | {box: .[0], lag_min: (.[1] | tonumber)}]}') \
    || { _fvc_sink_log "lag post failed (no body)"; return 0; }
  JOBS_HTTP=""
  JOBS_RETRIES=0 _jobs_req POST /api/boxes/lag "$body" >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq 0 ]; then
    _fvc_sink_log "posted $n lag rows"
  else
    _fvc_sink_log "lag post failed (http ${JOBS_HTTP:-none})"
  fi
  return 0
}
