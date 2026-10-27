#!/bin/bash
# shellcheck shell=bash
# bin/lib/archie-fm-report/stl.sh — BH-4588 (BH-4574.6): the stop-the-line
# beat. Sourced by bin/archie-fm-report.sh, never run.
#
#   afr_stl_class <alert-id>   -> the class on stdout, rc 0; rc 1 no event.
#                                 Reads catalog/archie-stop-the-line.tsv; the
#                                 first matching row wins, a `-` class is an
#                                 exclusion. rc 3: the table is unreadable.
#   afr_stl_scan               -> AFR_STL_DUE (a file): one line per open alert
#                                 that is an event and old enough, oldest
#                                 first: first_seen-epoch \t incident \t class
#                                 \t age-min \t alert-id \t line. rc 1: the
#                                 alerts or a knob could not be read (never
#                                 "no events"); one log line says which.
#   afr_stl_tick               -> sends ONE beat per due incident not yet sent,
#                                 at most archie.stl.beats_per_tick per tick,
#                                 through archie-tg-send.sh "stl:<incident>".
#                                 The rest wait for the next tick. Its archie_tg
#                                 ledger row is the exactly-once record; this
#                                 lane writes no marker of its own.
#
# Root: ${HARNESS:-${H:-}} only (D43). An empty root is rc 3 (no table).

AFR_STL_STATES="new triaged parked"
# Alerts read per state: the knob ARCHIE_FMR_ALERT_LIMIT (catalog/lanes.d/archie-fm-report.json), default 500.

afr_stl_root() { printf '%s' "${HARNESS:-${H:-}}"; }

afr_stl_class() {
  local id="$1" r f cls glob key
  r=$(afr_stl_root); [ -n "$r" ] || return 3
  f="$r/catalog/archie-stop-the-line.tsv"
  [ -r "$f" ] || return 3
  while IFS=$'\t' read -r cls glob key; do
    case "$cls" in ''|'#'*) continue ;; esac
    [ -n "$glob" ] || continue
    # shellcheck disable=SC2254 # the glob column is a glob on purpose
    case "$id" in
      $glob) [ "$cls" = - ] && return 1; printf '%s\t%s' "$cls" "$key"; return 0 ;;
    esac
  done < "$f"
  return 1
}

# afr_stl_min <settings-key> -> whole minutes on stdout. The settings row
#   wins; no row is the code fallback below (the seeded values). A junk row
#   or an unreadable store is rc 1.
afr_stl_min() {
  local k="$1" v rc
  v=$(setting_get "$k"); rc=$?
  case "$rc" in
    0) ;;
    2) case "$k" in
         archie.stl.main_red_min) v=60 ;;       # fallback of the row archie.stl.main_red_min
         archie.stl.queue_stall_min) v=60 ;;    # fallback of the row archie.stl.queue_stall_min
         archie.stl.box_down_min) v=15 ;;       # fallback of the row archie.stl.box_down_min
         archie.stl.spend_spike_min) v=0 ;;     # fallback of the row archie.stl.spend_spike_min
         archie.stl.beats_per_tick) v=3 ;;      # fallback of the row archie.stl.beats_per_tick
         *) return 1 ;;
       esac ;;
    *) return 1 ;;
  esac
  v=$(printf '%s' "$v" | tr -d '[:space:]')
  [[ $v =~ ^[0-9]{1,6}$ ]] || { afm_log "warn: $k='$v' is not a whole number; no stop-the-line beat this tick"; return 1; }
  printf '%s' "$((10#$v))"
}

afr_stl_scan() {
  local st out rc all="" id fs line opened ck cls key need age
  : > "$AFR_STL_DUE"
  command -v alerts_list >/dev/null 2>&1 || { afm_log "stl: alerts_list is not loaded; no beat this tick"; return 1; }
  for st in $AFR_STL_STATES; do
    rc=0; out=$(alerts_list --state "$st" --limit "${ARCHIE_FMR_ALERT_LIMIT:-500}") || rc=$?
    if [ "$rc" != 0 ]; then
      afm_log "stl: the open alerts (state $st) could not be read (rc=$rc http=${JOBS_HTTP:-none}); no beat this tick"
      return 1
    fi
    grep -qx '#truncated' <<<"$out" && afm_log "stl: the $st alerts are a full page (${ARCHIE_FMR_ALERT_LIMIT:-500}); only what was read is checked"
    all+="$out"$'\n'
  done
  # id family box project state count first_seen last_seen claimed_by claimed_at notified_at severity line
  while IFS=$'\x1f' read -r id fs line; do
    [ -n "$id" ] || continue
    ck=$(afr_stl_class "$id"); rc=$?
    [ "$rc" = 3 ] && { afm_log "stl: catalog/archie-stop-the-line.tsv is unreadable; no beat this tick"; return 1; }
    [ "$rc" = 0 ] || continue
    cls=${ck%%$'\t'*}; key=${ck#*$'\t'}
    opened=""
    [ -z "$fs" ] || opened=$(date -u -d "$fs" +%s 2>/dev/null)
    [[ $opened =~ ^[0-9]+$ ]] || { afm_log "stl: alert $id: first_seen '$fs' is unreadable; no beat"; continue; }
    need=$(afr_stl_min "$key") || { afm_log "stl: $key could not be read; no beat for $id"; continue; }
    age=$(( (NOW - opened) / 60 ))
    [ "$age" -ge "$need" ] || continue
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$opened" "$id@$opened" "$cls" "$age" "$id" "$line"
  done < <(awk -F'\t' 'NF >= 13 && $1 != "#truncated" {
      l = $13; for (i = 14; i <= NF; i++) l = l "\t" $i
      printf "%s\x1f%s\x1f%s\n", $1, $7, l }' <<<"$all" | LC_ALL=C sort -u) \
    | LC_ALL=C sort -t$'\t' -k1,1n -k2,2 > "$AFR_STL_DUE"
  return 0
}

# afr_stl_text <class> <age-min> <alert-id> <line> -> the beat text.
afr_stl_text() {
  local what
  case "$1" in
    main-red) what="main has been red for $2 min" ;;
    queue-stalled) what="the merge queue has been stalled for $2 min" ;;
    box-down) what="a pool box has been down for $2 min" ;;
    spend-spike) what="spend spiked ($2 min ago)" ;;
    *) what="$1 for $2 min" ;;
  esac
  printf 'Stop the line: %s. Alert %s: %s\n' "$what" "$3" "$4"
}

afr_stl_tick() {
  local cap sent=0 waiting=0 opened inc cls age id line st rc
  cap=$(afr_stl_min archie.stl.beats_per_tick) || { afm_log "stl: archie.stl.beats_per_tick could not be read; no beat this tick"; return 0; }
  afr_stl_scan || return 0
  while IFS=$'\t' read -r opened inc cls age id line; do
    [ -n "$inc" ] || continue
    # The dedupe read first, so an incident already beaten never takes a slot.
    st=$(job_ledger_get archie_tg "stl:$inc" 2>/dev/null); rc=$?
    case "$rc" in
      0) [ "$st" = sent ] && continue ;;
      2) ;;
      *) afm_log "stl: the archie_tg ledger did not answer for stl:$inc; no beat this tick"; return 0 ;;
    esac
    if [ "$sent" -ge "$cap" ]; then waiting=$((waiting + 1)); continue; fi
    rc=0; "$AFR_TG_SEND" "stl:$inc" "$(afr_stl_text "$cls" "$age" "$id" "$line")" >/dev/null 2>&1 || rc=$?
    sent=$((sent + 1))
    case "$rc" in
      0) afm_log "stl: beat stl:$inc ($cls, open $age min)" ;;
      2) afm_log "stl: stl:$inc not sent: archie-tg-send is not configured (rc 2); retried next tick" ;;
      *) afm_log "stl: stl:$inc not sent (archie-tg-send rc $rc); retried next tick" ;;
    esac
  done < "$AFR_STL_DUE"
  [ "$waiting" -gt 0 ] && afm_log "stl: $waiting more incident(s) wait for the next tick (archie.stl.beats_per_tick=$cap)"
  return 0
}
