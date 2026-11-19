#!/bin/bash
# bin/lib/discovery-missed.sh — BH-9795: the missed-run check of the
# discovery-daily lane. Sourced by bin/pipeline-health.sh (hub-only section),
# never executed. The caller defines alert_digest <ttl> <key> <line>
# (pipeline-health's warn digest, deduped by key, BH-9820), lane_paused and
# lane_knob (bin/lib/lane-gate.sh) and job_ledger_row (bin/jobs-client.sh).
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
#     no more reads for that day; anything else or absent -> a missed-alerted
#     marker (it holds the run row status), and no more reads for that day.
# Then the open alerts (BH-9820): each missed-alerted-<p>-<D> marker is ONE
# warn through alert_digest, key discovery-missed:<p>:<D>, every tick while it
# is open, so the key is in pipeline-health's fired set and the TTL dedupe
# keeps it to one beat. The key holds the day, so the dedupe window is the
# marker life: DISCOVERY_MARKER_KEEP_D days (x 86400 s per day), no literal TTL.
# An alert of day D CLOSES when a done run row of a later day exists: a
# missed-ok-<p>-<D'> marker with D' > D, else a read of today's run row (done
# -> a missed-ok marker for today). Closed: the marker becomes
# missed-closed-<p>-<D> and the key is not fired again, so the epilogue of
# bin/pipeline-health.sh retracts it (discovery-missed is in RETRACT_NS). A
# today read that does not answer holds the alert open (fired), never closes it.
# A ledger outage is one log line and no new alert (pipeline-health owns the
# ledger alert). Markers live in state/discovery-daily/ and are deleted after
# DISCOVERY_MARKER_KEEP_D days (default 30); an alert whose marker is deleted
# is no longer fired and retracts. Reads per tick: at most 2 ledger GETs per
# on-project for yesterday (0 after the day's marker) and at most 1 for today
# while an alert of the project is open.

_ddm_log() {
  local r="${HARNESS:-${H:-}}"; [ -n "$r" ] || return 0
  printf '%s discovery-missed %s\n' "$(date -u +%FT%TZ)" "$*" >> "$r/logs/pipeline-health.log" 2>/dev/null
}

# _ddm_open <p> <today>: fire or close each open alert of project <p>. Uses
# mdir and keep (dd_missed_check's locals). Today's run row is read at most
# once per call.
_ddm_open() {
  local p=$1 today=$2 m d st f od later rc row tst=""
  for m in "$mdir/missed-alerted-$p-"*; do
    [ -f "$m" ] || continue
    d=${m##*/missed-alerted-"$p"-}
    [[ $d =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || continue
    # A done run row of a later day: a missed-ok marker after d, else today's row.
    later=""
    for f in "$mdir/missed-ok-$p-"*; do
      od=${f##*/missed-ok-"$p"-}
      [[ $od =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && [[ $od > $d ]] && { later=$od; break; }
    done
    if [ -z "$later" ] && [ -z "$tst" ] && [[ $today > $d ]]; then
      rc=0; row=$(job_ledger_row discovery-daily-run "$p/$today") || rc=$?
      case "$rc" in
        0) tst=$(jq -r '.status // ""' <<<"$row" 2>/dev/null); [ -n "$tst" ] || tst=unknown ;;
        2) tst=absent ;;
        *) tst=unreadable; _ddm_log "[$p] the run row of $today is unreadable; open alerts held" ;;
      esac
      [ "$tst" = done ] && { : > "$mdir/missed-ok-$p-$today"; later=$today; }
    fi
    if [ -n "$later" ]; then
      mv -f "$m" "$mdir/missed-closed-$p-$d" 2>/dev/null || rm -f "$m"
      _ddm_log "[$p] missed run of $d closed: the run of $later is done"
      continue
    fi
    st=$(head -c 40 "$m" 2>/dev/null | tr -cd 'a-z-'); [ -n "$st" ] || st=absent
    # TTL: the key holds the day, so the dedupe lasts the marker life
    # (DISCOVERY_MARKER_KEEP_D days; 86400 is seconds per day, not a limit).
    alert_digest "$((10#$keep * 86400))" "discovery-missed:$p:$d" "discovery-daily: project $p has no done run for $d (run row: $st). Read logs/discovery-daily.log on the hub; bin/discovery-daily.sh $p runs it by hand."
  done
}

# _ddm_yday <p>: yesterday's check of project <p>. Writes at most one marker:
# missed-ok (the run is done) or missed-alerted (it is not; the marker holds
# the run row status). Uses dd_missed_check's locals.
_ddm_yday() {
  local p=$1
  [ -e "$mdir/missed-ok-$p-$yday" ] || [ -e "$mdir/missed-alerted-$p-$yday" ] || [ -e "$mdir/missed-closed-$p-$yday" ] && return 0
  rc=0; row=$(job_ledger_row discovery-daily-since "$p") || rc=$?
  case "$rc" in
    0) ;;
    2) return 0 ;;
    *) _ddm_log "[$p] the since row is unreadable; no check this tick"; return 0 ;;
  esac
  since=$(jq -r '.detail | if type == "string" then (fromjson? // {}) else . end | .since // ""' <<<"$row" 2>/dev/null)
  [[ $since =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 0
  [[ $since < $yday ]] || return 0
  rc=0; row=$(job_ledger_row discovery-daily-run "$p/$yday") || rc=$?
  st=""
  case "$rc" in
    0) st=$(jq -r '.status // ""' <<<"$row" 2>/dev/null) ;;
    2) st=absent ;;
    *) _ddm_log "[$p] the run row of $yday is unreadable; no check this tick"; return 0 ;;
  esac
  if [ "$st" = done ]; then : > "$mdir/missed-ok-$p-$yday"; return 0; fi
  # A project paused on this lane (lane-off-discovery-daily-<p>) is not missed.
  HARNESS="$root" lane_paused discovery-daily "$p" && return 0
  # The alert itself is _ddm_open's, this tick and every tick until it closes.
  printf '%s' "${st:0:40}" > "$mdir/missed-alerted-$p-$yday"
}

dd_missed_check() {
  local now=${1:-} root="${HARNESS:-${H:-}}" fc yday today p src row rc since st mdir keep
  [[ $now =~ ^[0-9]+$ ]] || return 0
  [ -n "$root" ] || return 0
  command -v lane_paused >/dev/null 2>&1 && command -v lane_knob >/dev/null 2>&1 \
    && command -v job_ledger_row >/dev/null 2>&1 && command -v alert_digest >/dev/null 2>&1 || return 0
  # The lane's own switches (all-off, lane-off-discovery-daily), read by the gate.
  HARNESS="$root" lane_paused discovery-daily && return 0
  fc="${FLEET_CONF:-$root/fleet.conf}"
  [ -r "$fc" ] || return 0
  yday=$(date -u -d "@$((now - 86400))" +%F) || return 0
  today=$(date -u -d "@$now" +%F) || return 0
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
    src=$(lane_knob discovery-daily DISCOVERY_SOURCES "$p" 2>/dev/null)
    [ -n "$src" ] || continue
    _ddm_yday "$p"
    _ddm_open "$p" "$today"
  done < <(awk 'NF && $1 !~ /^#/ {print $1}' "$fc")
  return 0
}
