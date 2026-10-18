#!/bin/bash
# bin/fleet-version-check.sh — hub lane fleet-version-check (BH-7191, tracer BH-7302).
# Every 10 min (cron/lanes/335-fleet-version-check.cron): one ALERTS line for a
# box whose harness checkout lags main by more than harness_version.max_lag_min.
# Alert only: never stops work, writes no flag, no pause and no setting, exit 0.
#
# One tick:
#   1. lane_gate_or_exit / lane_env_apply fleet-version-check; locks/
#      fleet-version-check.lock is a dedupe (flock -n, a held lock skips).
#   2. Thresholds: env HARNESS_VERSION_MAX_LAG_MIN / HARNESS_VERSION_MAX_BEAT_GAP_MIN
#      win, else the settings rows harness_version.max_lag_min /
#      harness_version.max_beat_gap_min, else 30.
#   3. GET /api/registry and GET /api/boxes in parallel. Either unreadable:
#      one log line "fleet-version-check: registry unreadable (<which>)", exit 0.
#   4. git fetch origin main in HARNESS_CHECKOUT (a failure is a log line), then
#      fvc_main_log. Empty: "fleet-version-check: main unreadable", exit 0.
#   5. Each registry box takes the newest-reported box_status row that is
#      named like it or whose cron box id (bin/lib/cron-lines.sh) is its
#      box_id. No row: "SKIP <box> no box_status row". A box_status row that
#      answers for no registry box: "SKIP <box> not in registry". The lag is
#      measured as of the row's report time (lane-gate resends the sha hourly).
#   6. fvc_decide over one TSV row per registry box (bin/lib/fleet-version-decide.sh).
#   7. Each ALERT with no open marker state/fleet-version-check/open/<kind>.<box>
#      goes to bin/alert-line.sh --id fleet-version:<kind>:<box>, then the
#      marker is touched. With a marker: "still open". An OK box clears its lag
#      and nosha markers ("cleared"). A fresh flags/orchestrator-sync-in-progress
#      (< 2700 s) logs ALERTs as "suppressed" and sends none.
#   8. fvc_sink gets the full decide output; exit 0.
# Log: logs/fleet-version-check.log. Test seam: FVC_NOW pins the clock.
set -uo pipefail
H="${HARNESS:-/root/harness}"
LANE="fleet-version-check"
LOG="$H/logs/fleet-version-check.log"
OPEN="$H/state/fleet-version-check/open"
mkdir -p "$H/logs" "$H/locks" "$OPEN" 2>/dev/null
log() { echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') $*" >> "$LOG"; }

# shellcheck source=bin/jobs-client.sh
. "$H/bin/jobs-client.sh" || { log "$LANE: cannot load bin/jobs-client.sh"; exit 0; }
# shellcheck source=bin/lib/lane-gate.sh
. "$H/bin/lib/lane-gate.sh" || { log "$LANE: cannot load bin/lib/lane-gate.sh"; exit 0; }
lane_gate_or_exit fleet-version-check
lane_env_apply fleet-version-check
# shellcheck source=bin/lib/cron-lines.sh
. "$H/bin/lib/cron-lines.sh" || { log "$LANE: cannot load bin/lib/cron-lines.sh"; exit 0; }
# shellcheck source=bin/lib/fleet-version-decide.sh
. "$H/bin/lib/fleet-version-decide.sh" || { log "$LANE: cannot load bin/lib/fleet-version-decide.sh"; exit 0; }
# shellcheck source=bin/lib/fleet-version-sink.sh
. "$H/bin/lib/fleet-version-sink.sh" || { log "$LANE: cannot load bin/lib/fleet-version-sink.sh"; exit 0; }
# Without the lib FLEET_PATHS is empty and every main commit counts (stricter).
unset FLEET_PATHS
# shellcheck source=bin/lib/fleet-paths.sh
. "$H/bin/lib/fleet-paths.sh" 2>/dev/null || true

exec 8>"$H/locks/$LANE.lock"
if ! flock -n 8; then log "skip: already running"; exit 0; fi

NOW="${FVC_NOW:-$(date +%s)}"
export FVC_NOW="$NOW"

# fvc_knob <env name> <settings key> — env wins, then the settings row, then 30.
fvc_knob() {
  local v="${!1:-}"
  [ -n "$v" ] || v=$(setting_get "$2" 2>/dev/null) || v=""
  printf '%s' "${v:-30}"
}
FVC_MAX_LAG_MIN=$(fvc_knob HARNESS_VERSION_MAX_LAG_MIN harness_version.max_lag_min)
FVC_MAX_BEAT_GAP_MIN=$(fvc_knob HARNESS_VERSION_MAX_BEAT_GAP_MIN harness_version.max_beat_gap_min)
export FVC_MAX_LAG_MIN FVC_MAX_BEAT_GAP_MIN

T=$(mktemp -d "${TMPDIR:-/tmp}/fleet-version-check.XXXXXX") || { log "$LANE: mktemp failed"; exit 0; }
trap 'rm -rf "$T"' EXIT

# 3. The two reads are independent: run them in parallel.
( _jobs_req GET /api/registry > "$T/reg" ) & P_REG=$!
( _jobs_req GET /api/boxes > "$T/boxes" ) & P_BOX=$!
BAD=""
wait "$P_REG" && jq -e '.boxes | type == "array"' "$T/reg" >/dev/null 2>&1 || BAD="registry"
wait "$P_BOX" && jq -e '.boxes | type == "array"' "$T/boxes" >/dev/null 2>&1 || BAD="${BAD:+$BAD,}boxes"
if [ -n "$BAD" ]; then
  log "fleet-version-check: registry unreadable ($BAD)"
  exit 0
fi

# 4. First-parent main from the hub checkout.
HCO="${HARNESS_CHECKOUT:-/root/harness-checkout}"
timeout 60 git -C "$HCO" fetch origin main -q 2>/dev/null || log "fleet-version-check: git fetch failed in $HCO; using the ref it has"
if ! fvc_main_log "$HCO" > "$T/main" || [ ! -s "$T/main" ]; then
  log "fleet-version-check: main unreadable"
  exit 0
fi
TIP8=$(head -1 "$T/main" | cut -c1-8)
export FVC_CHECKOUT="$HCO"

# 5. Join registry boxes to box_status rows.
jq -r '.boxes[] | [.box, (.box_id // ""), (.role // "build")] | @tsv' "$T/reg" > "$T/reg.tsv" 2>/dev/null
jq -r '.boxes[] | [.box, (.harness_commit // ""), (.harness_reported_at // ""),
  (.last_beat_at // "" | tostring), (.sync_timer // "" | tostring), (.harness_synced_at // "")]
  | map(gsub("[\t\n]"; " ")) | @tsv' "$T/boxes" > "$T/status.tsv" 2>/dev/null
declare -A SID=() USED=() REPORTED=()
while IFS= read -r line; do
  sb=${line%%$'\t'*}
  [ -n "$sb" ] && SID[$sb]=$(cron_box_id_for "$sb")
done < "$T/status.tsv"

: > "$T/decide.tsv"
while IFS=$'\037' read -r RB RID RROLE; do
  [ -n "$RB" ] || continue
  # Every row named like the box, or with its box id (an older machine
  # generation included), answers for it; the newest report wins.
  pick=""; pickat=""
  for sb in "${!SID[@]}"; do
    [ "$sb" = "$RB" ] || { [ -n "$RID" ] && [ "${SID[$sb]}" = "$RID" ]; } || continue
    USED[$sb]=1
    row=$(awk -F'\t' -v b="$sb" '$1 == b { print; exit }' "$T/status.tsv")
    at=$(cut -f3 <<<"$row")
    if [ -z "$pick" ] || [[ "$at" > "$pickat" ]]; then pick=$row; pickat=$at; fi
  done
  if [ -z "$pick" ]; then log "SKIP $RB no box_status row"; continue; fi
  IFS=$'\037' read -r SB SSHA SAT SBEAT STIMER SSYNC <<<"$(tr '\t' '\037' <<<"$pick")"
  USED[$SB]=1
  REP=""; [ -n "$SAT" ] && { REP=$(date -u -d "$SAT" +%s 2>/dev/null) || REP=""; }
  REPORTED[$RB]=$SAT
  LAG=""; [ -n "$SSHA" ] && LAG=$(fvc_lag_min "$SSHA" "$T/main" "${REP:-$NOW}")
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$RB" "$RROLE" "$SSHA" "$REP" "$LAG" "$SBEAT" "$STIMER" "$SSYNC" >> "$T/decide.tsv"
done < <(tr '\t' '\037' < "$T/reg.tsv")
for sb in "${!SID[@]}"; do
  [ -n "${USED[$sb]:-}" ] || log "SKIP $sb not in registry"
done

# 6. Decide.
fvc_decide < "$T/decide.tsv" > "$T/out"

# 7. Alerts, markers, log.
OSYNC=0
if [ -f "$H/flags/orchestrator-sync-in-progress" ]; then
  OTS=$(stat -c %Y "$H/flags/orchestrator-sync-in-progress" 2>/dev/null || echo 0)
  [ $(( NOW - OTS )) -lt 2700 ] && OSYNC=1
fi
mk() { printf '%s/%s.%s' "$OPEN" "$1" "$(printf '%s' "$2" | tr -c 'A-Za-z0-9._-' '_')"; }
while IFS= read -r line; do
  read -r word box kind detail <<<"$line"
  case "$word" in
    ALERT)
      m=$(mk "$kind" "$box")
      if [ "$OSYNC" = 1 ]; then log "suppressed (orchestrator sync in progress): $line"
      elif [ -e "$m" ]; then log "still open: $line"
      else
        "$H/bin/alert-line.sh" --id "fleet-version:$kind:$box" \
          "fleet-version $box $kind $detail (reported ${REPORTED[$box]:-never}, main $TIP8)"
        touch "$m"
        log "$line"
      fi ;;
    OK)
      for k in lag nosha; do
        m=$(mk "$k" "$box")
        [ -e "$m" ] && rm -f "$m" && log "cleared $k $box"
      done
      log "$line" ;;
    *) log "$line" ;;
  esac
done < "$T/out"

# 8. The console sink (BH-7191.4).
fvc_sink < "$T/out"
exit 0
