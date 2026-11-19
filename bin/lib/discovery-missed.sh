#!/bin/bash
# bin/lib/discovery-missed.sh — BH-9795: the missed-run check of the
# discovery-daily lane. Sourced by bin/pipeline-health.sh (hub-only section),
# never executed. The caller defines alert <ttl> <key> <line> (pipeline-health's
# own, deduped by key), lane_paused and lane_knob (bin/lib/lane-gate.sh) and job_ledger_row
# (bin/jobs-client.sh).
#
#   dd_missed_check <now-epoch>
#
# Skip when lane_paused discovery-daily (all-off, lane-off-discovery-daily);
# a project paused on the lane gets no alert. For each
# fleet.conf project whose DISCOVERY_SOURCES knob is non-empty:
#   - no discovery-daily-since/<p> row: no alert (the lane never ran there; the
#     day of the switch-on raises nothing);
#   - since >= yesterday: no alert;
#   - else discovery-daily-run/<p>/<yesterday>: done -> a missed-ok marker, and
#     no more reads for that day; anything else or absent -> ONE alert
#     discovery-missed:<p>:<yesterday> (86400 s dedup) and a missed-alerted
#     marker, so a later tick of the same day raises nothing more.
# A ledger outage is one log line and no alert (pipeline-health owns the
# ledger alert). Markers live in state/discovery-daily/ and are deleted after
# DISCOVERY_MARKER_KEEP_D days (default 30). Reads per tick: at most 2 ledger GETs per on-project, 0 after the
# day's marker.

_ddm_log() {
  local r="${HARNESS:-${H:-}}"; [ -n "$r" ] || return 0
  printf '%s discovery-missed %s\n' "$(date -u +%FT%TZ)" "$*" >> "$r/logs/pipeline-health.log" 2>/dev/null
}

dd_missed_check() {
  local now=${1:-} root="${HARNESS:-${H:-}}" fc yday p src row rc since st mdir keep
  [[ $now =~ ^[0-9]+$ ]] || return 0
  [ -n "$root" ] || return 0
  command -v lane_paused >/dev/null 2>&1 && command -v lane_knob >/dev/null 2>&1 \
    && command -v job_ledger_row >/dev/null 2>&1 || return 0
  # The lane's own switches (all-off, lane-off-discovery-daily), read by the gate.
  HARNESS="$root" lane_paused discovery-daily && return 0
  fc="${FLEET_CONF:-$root/fleet.conf}"
  [ -r "$fc" ] || return 0
  yday=$(date -u -d "@$((now - 86400))" +%F) || return 0
  mdir="$root/state/discovery-daily"
  mkdir -p "$mdir" 2>/dev/null
  # Marker retention: knob DISCOVERY_MARKER_KEEP_D (catalog/lanes.d/discovery-daily.json);
  # 30 is the fallback when the knob reads empty or outside 1..365.
  keep=$(lane_knob discovery-daily DISCOVERY_MARKER_KEEP_D 2>/dev/null)
  if ! [[ $keep =~ ^[0-9]+$ ]] || [ "$((10#$keep))" -lt 1 ] || [ "$((10#$keep))" -gt 365 ]; then
    [ -z "$keep" ] || _ddm_log "warn: DISCOVERY_MARKER_KEEP_D=$keep is outside 1..365; using the default 30"
    keep=30
  fi
  find "$mdir" -maxdepth 1 -type f -name 'missed-*' -mtime "+$((10#$keep))" -delete 2>/dev/null
  while IFS= read -r p; do
    [[ $p =~ ^[a-z0-9-]+$ ]] || continue
    [ -e "$mdir/missed-ok-$p-$yday" ] || [ -e "$mdir/missed-alerted-$p-$yday" ] && continue
    src=$(lane_knob discovery-daily DISCOVERY_SOURCES "$p" 2>/dev/null)
    [ -n "$src" ] || continue
    rc=0; row=$(job_ledger_row discovery-daily-since "$p") || rc=$?
    case "$rc" in
      0) ;;
      2) continue ;;
      *) _ddm_log "[$p] the since row is unreadable; no check this tick"; continue ;;
    esac
    since=$(jq -r '.detail | if type == "string" then (fromjson? // {}) else . end | .since // ""' <<<"$row" 2>/dev/null)
    [[ $since =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || continue
    [[ $since < $yday ]] || continue
    rc=0; row=$(job_ledger_row discovery-daily-run "$p/$yday") || rc=$?
    st=""
    case "$rc" in
      0) st=$(jq -r '.status // ""' <<<"$row" 2>/dev/null) ;;
      2) st=absent ;;
      *) _ddm_log "[$p] the run row of $yday is unreadable; no check this tick"; continue ;;
    esac
    if [ "$st" = done ]; then : > "$mdir/missed-ok-$p-$yday"; continue; fi
    # A project paused on this lane (lane-off-discovery-daily-<p>) is not missed.
    HARNESS="$root" lane_paused discovery-daily "$p" && continue
    alert 86400 "discovery-missed:$p:$yday" "discovery-daily: project $p has no done run for $yday (run row: $st). Read logs/discovery-daily.log on the hub; bin/discovery-daily.sh $p runs it by hand."
    : > "$mdir/missed-alerted-$p-$yday"
  done < <(awk 'NF && $1 !~ /^#/ {print $1}' "$fc")
  return 0
}
