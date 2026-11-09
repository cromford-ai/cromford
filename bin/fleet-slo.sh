#!/bin/bash
# bin/fleet-slo.sh — fleet SLO detectors (hub cron */10).
#
# Why (2026-09-15): at 12:27Z a lane hot-patched bin/queue-line-drop.sh on the
# hub and all 8 boxes, and context-gate then refused EVERY box-side build
# fleet-wide for 77 minutes. The fleet had stopped. What that produced was four
# unrelated "BUILD REFUSED" lines in four project logs — no incident, nobody
# paged, and the only way to notice was to read four files and join them.
#
# Every individual layer was working. pipeline-health watches queues, machines
# and spend; the lanes row watches boxes; jobs-watchdog watches rows. Nothing
# watched the RATES — the fleet-level questions "what fraction of builds are we
# refusing", "what fraction of lanes are dying", "how many rows say running that
# nothing is running", "how many boxes have gone quiet". A failure that hits
# everything at once shows up in a rate long before anyone reads a log.
#
# So: five SLOs, each computed from evidence the hub already holds, each with a
# threshold in flags/slo.conf, each firing ONE incident alert on the way in and
# ONE resolve on the way out.
#
#   build_refusal   refusals / launches over the window        (the incident above)
#   lane_death      settled lanes that produced no RESULT / lanes started
#   stale_running   ledger rows still "running" past a TTL
#   box_silent      boxes whose every lane has stopped ticking
#   main_red        flags/main-red-<slug> markers another lane wrote
#
# READ-ONLY about the world. It reads logs, build dirs, state/, flags/ and the
# jobs ledger over GET; it writes only its own state/slo/ markers, its own log,
# and alerts. It never creates or clears a main-red marker, never touches the
# ledger, never pauses anything — a detector that could act on its own findings
# would be a second, unreviewed control path.
#
# EVERY SLO FAILS QUIET, NOT LOUD, ON MISSING EVIDENCE. An unreadable ledger
# reports "unknown" and fires nothing: the alternative is a detector that pages
# when it breaks, which is how a channel gets muted. What makes that safe is
# that each SLO's evidence is also written by something else that alerts on its
# own absence (the lanes row for boxes, jobs-watchdog for rows).
#
# usage: fleet-slo.sh [--dry-run]     --dry-run measures and prints, no alerts,
#                                     no markers, no status.json
# exit 0 = every SLO inside its threshold   1 = at least one incident open
#
# Kill switch: the settings row switch.fleet-slo-off[.<box>], or
# /root/harness/flags/fleet-slo-off when no row.
# Overridable for TESTS only: HARNESS, SLO_CONF (cron sets neither).
set -uo pipefail
H="${HARNESS:-/root/harness}"
# >>> lane gate (K1, 2026-09-24) — the lane is scheduled now (cron/lanes/
# 716-fleet-slo.cron), so it takes the registry's off-switch like every other
# lane: flags/all-off or flags/lane-off-fleet-slo. switch.fleet-slo-off
# below (row, then flags/fleet-slo-off) still works. Fails OPEN: no lane-gate
# lib, the lane runs as before.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
# shellcheck source=lib/lane-switch.sh
. "${HARNESS:-/root/harness}/bin/lib/lane-switch.sh" 2>/dev/null || true
command -v lane_switch >/dev/null 2>&1 || lane_switch() { [ -f "$H/flags/$1" ]; }   # no lib: the file, as before
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit fleet-slo
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    fleet-slo
STATE="$H/state/slo"
LOG="$H/logs/fleet-slo.log"
CONF="${SLO_CONF:-$H/flags/slo.conf}"
DRY=""; [ "${1:-}" = "--dry-run" ] && DRY=1
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
mkdir -p "$STATE" "$(dirname "$LOG")" 2>/dev/null

lane_switch fleet-slo-off file && { echo "fleet-slo disabled by flag"; exit 0; }

# --- config ---------------------------------------------------------------
# The settings row `conf.slo.<key lowercased>[.<box>]` (BH-2411,
# bin/lib/conf-row.sh; not read when $SLO_CONF names a fixture), then
# flags/slo.conf, then an environment variable of the same name, then the
# fallback here. A row is read the way the file's line is: its first word. The
# fallbacks are duplicated in flags/slo.conf's comments on purpose: a box with
# no conf file must measure what the repo documents.
# shellcheck source=lib/conf-row.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/conf-row.sh" 2>/dev/null || true
# shellcheck source=lib/rr-relay.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/rr-relay.sh" 2>/dev/null || true
conf() { # conf <KEY> <fallback>
  local v="" k
  if [ -z "${SLO_CONF:-}" ] && command -v conf_row >/dev/null 2>&1; then
    k=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    if v=$(conf_row slo "$k" "$H"); then
      v=$(printf '%s\n' "$v" | awk '{print $1; exit}')
      [ -n "$v" ] && conf_row_note_file slo "$CONF" "$k"
    else
      v=""
    fi
  fi
  [ -n "$v" ] || v=$(awk -v k="$1" '$1==k && NF>=2 {print $2; exit}' "$CONF" 2>/dev/null)
  [ -n "$v" ] || v="${!1:-}"
  printf '%s' "${v:-$2}"
}
# The rows once, into this shell (BH-2478): every conf() below runs in `$( )`.
[ -z "${SLO_CONF:-}" ] && command -v conf_rows_preload >/dev/null 2>&1 && conf_rows_preload slo "$H"
WINDOW_MIN=$(conf SLO_WINDOW_MIN 60)
REFUSAL_RATE=$(conf SLO_REFUSAL_RATE 0.25)
REFUSAL_MIN=$(conf SLO_REFUSAL_MIN_LAUNCHES 4)
REFUSAL_RE=$(conf SLO_REFUSAL_RE '[]].BUILD.REFUSED')
LANE_RATE=$(conf SLO_LANE_DEATH_RATE 0.30)
LANE_MIN=$(conf SLO_LANE_MIN_LANES 4)
LANE_SETTLE_MIN=$(conf SLO_LANE_SETTLE_MIN 90)
# Lane deaths get their OWN, longer window: a lane is only judged once it has
# settled, so a window shorter than the settle time could never contain a single
# judgeable lane and the SLO would read 0.00 forever.
LANE_WINDOW_MIN=$(conf SLO_LANE_WINDOW_MIN 360)
LANE_DEATH_RE=$(conf SLO_LANE_DEATH_RE '(BUILD_FAILED|EXECUTE_EMPTY|EXECUTE_FAILED|PLAN_FAILED|REVIEW_FAILED|LANE_FAILED|MAX_TURNS|max.turns)')
STALE_TTL_MIN=$(conf SLO_STALE_RUNNING_TTL_MIN 180)
STALE_MAX=$(conf SLO_STALE_RUNNING_MAX 3)
STALE_LIMIT=$(conf SLO_STALE_RUNNING_LIMIT 200)
BOX_SILENT_MIN=$(conf SLO_BOX_SILENT_MIN 60)
BOX_SILENT_MAX=$(conf SLO_BOX_SILENT_MAX 1)
MAIN_RED_MAX=$(conf SLO_MAIN_RED_MAX 1)
# 200 is the fallback of the fleet-slo knob SLO_RELAY_ROWS_LIMIT; 0 = no read.
RELAY_ROWS=$(conf SLO_RELAY_ROWS_LIMIT 200)

NOW=$(date +%s)
CUT=$(( NOW - WINDOW_MIN * 60 ))
# Log lines start "YYYY-MM-DD HH:MM:SSZ" (STAMP) or the ISO "…T…Z" variant, so
# the first 19 characters compare as strings once T is normalised to a space.
CUTS=$(date -u -d "@$CUT" '+%Y-%m-%d %H:%M:%S')
LANE_CUT=$(( NOW - LANE_WINDOW_MIN * 60 ))

log() { echo "$(STAMP) $*" >> "$LOG"; }
# Count files under <dir> whose mtime is inside the window. -newermt @epoch
# rather than -mmin, so the window and the log cutoff are the same instant.
newer_count() { # newer_count <dir> <name-glob> <maxdepth>
  [ -d "$1" ] || { echo 0; return; }
  find "$1" -maxdepth "${3:-2}" -type f -name "$2" -newermt "@$CUT" 2>/dev/null | wc -l | tr -dc '0-9'
}
# Rates are compared at the 2 decimals they are REPORTED at, so the number in
# the alert is the number that tripped it. That rounds toward alerting (0.2549
# reads 0.25 and breaches a 0.25 threshold), which is the direction to be wrong in.
rate() { awk -v n="${1:-0}" -v d="${2:-0}" 'BEGIN{ printf "%.2f", (d>0 ? n/d : 0) }'; }
ge()   { awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN{ exit !(a+0 >= b+0) }'; }

# --- remote lanes the hub holds no copy of (BH-8364) ---------------------
# Each sent relay json has an rr-relay row (bin/lib/rr-relay.sh). A row whose
# hub build dir builds/<build-id> and hub json state/remote-results/<p>/<KEY>.json
# are both gone is a lane the file loops below cannot see, so it adds to SLO 1
# (created inside the window) and SLO 2 (created inside the lane window; a
# death when its result matches SLO_LANE_DEATH_RE). A row with either hub copy
# is the file loops' own. One list call per run. SLO 1 and SLO 2 are computed
# here, before the second lane_env_apply below, so the knob is the conf read
# above (the first lane_env_apply already put a settings row in the env). The
# jobs client reads its own secret and url (bin/jobs-client.sh). No lib, no
# client, an outage or a body with no rows adds nothing.
RR_LAUNCHES=0; RR_LANES=0; RR_DEATHS=0; RR_DEAD_NAMES=""
if [[ $RELAY_ROWS =~ ^[0-9]+$ ]] && [ "$RELAY_ROWS" -gt 0 ] && command -v rrr_list >/dev/null 2>&1; then
  if ! declare -F _jobs_req >/dev/null 2>&1 && [ -r "$H/bin/jobs-client.sh" ]; then # shellcheck source=/dev/null
    . "$H/bin/jobs-client.sh" 2>/dev/null
  fi
  if declare -F _jobs_req >/dev/null 2>&1; then
    while IFS=$'\t' read -r RP RK RB _ RC RR; do
      [ -n "$RB" ] || continue
      [ -e "$H/builds/$RB" ] && continue
      [ -e "$H/state/remote-results/$RP/$RK.json" ] && continue
      [ -n "$RC" ] && [ "$RC" != - ] || continue
      RE=$(date -u -d "$RC" +%s 2>/dev/null) || continue
      [ "$RE" -ge "$CUT" ] && RR_LAUNCHES=$(( RR_LAUNCHES + 1 ))
      [ "$RE" -ge "$LANE_CUT" ] || continue
      RR_LANES=$(( RR_LANES + 1 ))
      if grep -qE "$LANE_DEATH_RE" <<<"$RR"; then
        RR_DEATHS=$(( RR_DEATHS + 1 )); RR_DEAD_NAMES="$RR_DEAD_NAMES $RK(row)"
      fi
    done < <(rrr_list "$RELAY_ROWS" 2>/dev/null)
  fi
fi

# --- SLO 1: build refusal rate --------------------------------------------
# Refusals from the hub-visible log set: its own ALERTS.log (hub-side gates) and
# fleet-alerts.log (historic: bin/fleet-heartbeat.sh filled it with lines it read
# off the boxes until BH-1031 deleted that lane; the file is still read, never
# required). Launches from the context.json every context-gate run writes into the
# build dir, plus the remote results the hub ingested for box/pool builds.
#
# The denominator is max(launches, refusals): a fleet-wide refusal storm reaches
# the hub as refusal lines LONG before their build dirs do, and dividing by a
# launch count that never arrived would read 0.00 through the whole outage. The
# sample-size floor below is what keeps that from firing on one stray line.
REFUSALS=0
for F in "$H/logs/ALERTS.log" "$H/logs/fleet-alerts.log"; do
  [ -f "$F" ] || continue
  N=$(awk -v cut="$CUTS" -v re="$REFUSAL_RE" '
        { ts=substr($0,1,19); gsub(/T/," ",ts); if (ts >= cut && $0 ~ re) n++ }
        END { print n+0 }' "$F" 2>/dev/null)
  REFUSALS=$(( REFUSALS + ${N:-0} ))
done
LAUNCHES=$(( $(newer_count "$H/builds" context.json 2>/dev/null) + $(newer_count "$H/state/remote-results" '*.json' 2>/dev/null) + RR_LAUNCHES ))
DENOM=$LAUNCHES; [ "$REFUSALS" -gt "$DENOM" ] && DENOM=$REFUSALS
REFUSAL_VAL=$(rate "$REFUSALS" "$DENOM")
REFUSAL_BREACH=0
if [ "$DENOM" -ge "$REFUSAL_MIN" ] && ge "$REFUSAL_VAL" "$REFUSAL_RATE"; then REFUSAL_BREACH=1; fi
REFUSAL_DETAIL="$REFUSALS of $DENOM build attempts refused in the last ${WINDOW_MIN}m — builds are being turned away before they start, not failing. Read the refusal lines in logs/ALERTS.log: context drift (bin or rules vs the box's checkout) refuses every project on the box at once."

# --- SLO 2: lane death rate -----------------------------------------------
# A lane is "started" once its build dir has a context.json, and "settled" once
# that is SLO_LANE_SETTLE_MIN old — anything younger is working, not dead.
# Dead means: no RESULT at all (what a max-turns kill leaves behind), a RESULT
# whose first line is not a canonical prefix (bin/result-prefix-ok.sh — flyctl
# panics land there), or an explicitly failed outcome. BUILD_REFUSED is NOT
# counted here; SLO 1 owns it, and paging twice for one cause is how an operator
# learns to skim.
LANES=0; DEATHS=0; DEAD_NAMES=""
SETTLE_S=$(( LANE_SETTLE_MIN * 60 ))
while IFS= read -r CJ; do
  [ -n "$CJ" ] || continue
  D=$(dirname "$CJ")
  MT=$(stat -c %Y "$CJ" 2>/dev/null || echo "$NOW")
  [ $(( NOW - MT )) -ge "$SETTLE_S" ] || continue
  LANES=$(( LANES + 1 ))
  DEAD=""
  if [ ! -s "$D/RESULT" ]; then
    DEAD="no RESULT"
  else
    L1=$(head -1 "$D/RESULT" 2>/dev/null)
    if [ -x "$H/bin/result-prefix-ok.sh" ] && ! "$H/bin/result-prefix-ok.sh" "$L1" >/dev/null 2>&1; then
      DEAD="non-canonical RESULT"
    elif grep -qE "$LANE_DEATH_RE" <<<"$L1"; then
      DEAD="failed outcome"
    fi
  fi
  [ -n "$DEAD" ] && { DEATHS=$(( DEATHS + 1 )); DEAD_NAMES="$DEAD_NAMES $(basename "$D")($DEAD)"; }
done < <(find "$H/builds" -maxdepth 2 -type f -name context.json -newermt "@$LANE_CUT" 2>/dev/null)
while IFS= read -r RJ; do
  [ -n "$RJ" ] || continue
  LANES=$(( LANES + 1 ))
  RES=$(jq -r '.result // ""' "$RJ" 2>/dev/null | head -1)
  if grep -qE "$LANE_DEATH_RE" <<<"$RES"; then
    DEATHS=$(( DEATHS + 1 )); DEAD_NAMES="$DEAD_NAMES $(basename "$RJ" .json)(remote)"
  fi
done < <(find "$H/state/remote-results" -maxdepth 2 -type f -name '*.json' -newermt "@$LANE_CUT" 2>/dev/null)
LANES=$(( LANES + RR_LANES )); DEATHS=$(( DEATHS + RR_DEATHS )); DEAD_NAMES="$DEAD_NAMES$RR_DEAD_NAMES"
LANE_VAL=$(rate "$DEATHS" "$LANES")
LANE_BREACH=0
if [ "$LANES" -ge "$LANE_MIN" ] && ge "$LANE_VAL" "$LANE_RATE"; then LANE_BREACH=1; fi
LANE_DETAIL="$DEATHS of $LANES lanes that started in the last ${LANE_WINDOW_MIN}m died without a usable RESULT —$(printf '%.180s' "${DEAD_NAMES:- (none named)}"). A lane with no RESULT at all is a max-turns kill or a reaped machine: check the build dir and logs/fly-pool.log before relaunching."

# --- SLO 3: stale running ledger rows -------------------------------------
# GET only. An unreadable ledger is "unknown" and fires nothing (jobs-watchdog
# alerts on the ledger itself; this lane must not page for its own blindness).
# shellcheck disable=SC1091
. "$H/bin/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "$H/env"; }
HENV=$(harness_env_dir)
if [ -f "$HENV/global.env" ]; then set -a; # shellcheck disable=SC1091
  . "$HENV/global.env" 2>/dev/null; set +a; fi
# Again below the env load (the pipeline-health rule, lanes-registry §16):
# `set -a; . global.env` re-assigns every name it carries.
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply fleet-slo
STALE_VAL=unknown; STALE_BREACH=0; STALE_NAMES=""
if [ -r "$H/bin/jobs-client.sh" ]; then # shellcheck source=/dev/null
  . "$H/bin/jobs-client.sh" 2>/dev/null
  if declare -F _jobs_req >/dev/null 2>&1; then
    J=$(_jobs_req GET "/api/jobs?status=running&limit=$STALE_LIMIT" 2>/dev/null)
    if [ -n "$J" ] && jq -e '.jobs' >/dev/null 2>&1 <<<"$J"; then
      TTL_S=$(( STALE_TTL_MIN * 60 ))
      STALE_VAL=$(jq -r --argjson t "$TTL_S" '[.jobs[]? | select((.age_s // 0) > $t)] | length' <<<"$J" 2>/dev/null)
      STALE_NAMES=$(jq -r --argjson t "$TTL_S" '[.jobs[]? | select((.age_s // 0) > $t) | .id] | .[0:5] | join(" ")' <<<"$J" 2>/dev/null)
      case "$STALE_VAL" in ''|*[!0-9]*) STALE_VAL=unknown ;; esac
    fi
  fi
fi
[ "$STALE_VAL" != unknown ] && ge "$STALE_VAL" "$STALE_MAX" && STALE_BREACH=1
STALE_DETAIL="$STALE_VAL ledger rows still say running past ${STALE_TTL_MIN}m — ${STALE_NAMES:-(none listed)}. Nothing will close these on its own: a row whose machine is gone keeps a build slot and hides a dead lane behind a green status."

# --- SLO 4: boxes whose every lane has gone silent ------------------------
# THE ROW IS THE EVIDENCE, AND THE ONLY EVIDENCE (BH-1031, state→DB slice 6).
# This used to read state/fleet-heartbeat/alerts-<box>, which bin/fleet-heartbeat.sh
# rewrote every 15 minutes. That lane is deleted in this slice, so nothing
# writes those files any more: reading their mtimes would report a permanently
# silent fleet off files that stopped moving for a reason that has nothing to do
# with the boxes — the worst shape a detector can take, because it looks like
# evidence. The fallback is gone with the producer (round 1 on #1150); the
# leftover directory is read by nothing.
#
# What replaces it is the fact the boxes write for themselves: every lane ticks
# its own row every ten minutes (bin/run-triage.sh -> lane_tick) and the WORKER
# decides stale on each lane's own cadence. A box is "lost sight of" when EVERY
# lane fleet.conf routes to it is stale AND the quietest of them has been quiet
# longer than SLO_BOX_SILENT_MIN — one dead lane is a lane problem that
# bin/jobs-watchdog.sh already names, all of them is a box, and the extra floor
# keeps this SLO strictly behind the per-lane detector so the two cannot page
# for the same event.
#
# ONLY boxes fleet.conf still names. Retired boxes keep their rows (as they kept
# their files): measured on the hub 2026-09-15, box-project-3-1 (replaced by
# project-3-2 on 08-10) and box-project-10-1 (retired 08-24) were both
# still present, so an unfiltered count would have paged about two machines that
# do not exist, every ten minutes, until someone muted it. No readable
# fleet.conf means we cannot tell a ghost from a box — and no answer from the
# ledger means we have no evidence at all — so the SLO reports `unknown` and
# fires nothing, the failure mode this file already chose.
SILENT_BOXES=""; SILENT=unknown; BOX_BREACH=0
FLEET_BOXES=$(awk '!/^[[:space:]]*(#|$)/ && NF>=6 {print $6}' "$H/fleet.conf" 2>/dev/null | sort -u | tr '\n' ' ')
if [ -n "$FLEET_BOXES" ] && command -v lanes_list >/dev/null 2>&1; then
  LROWS=$(lanes_list 2>/dev/null) || LROWS=""
  if [ -n "$LROWS" ]; then
    SILENT=0
    for B in $FLEET_BOXES; do
      LTOT=$(awk -F'\t' -v b="$B" '$2==b && $3!="retired" {n++} END{print n+0}' <<<"$LROWS")
      case "$LTOT" in ''|0|*[!0-9]*) continue ;; esac
      LSTL=$(awk -F'\t' -v b="$B" '$2==b && $3=="stale" {n++} END{print n+0}' <<<"$LROWS")
      [ "$LSTL" = "$LTOT" ] || continue
      # The quietest lane on the box, in seconds. -1 = it has never ticked at
      # all, which is not an argument for the box being alive.
      LMIN=$(awk -F'\t' -v b="$B" '$2==b && $3!="retired" && $5+0 >= 0 {if (m=="" || $5+0 < m+0) m=$5} END{print (m==""? -1 : m)}' <<<"$LROWS")
      case "$LMIN" in ''|*[!0-9-]*) LMIN=-1 ;; esac
      { [ "$LMIN" -lt 0 ] || [ "$LMIN" -ge $(( BOX_SILENT_MIN * 60 )) ]; } || continue
      SILENT_BOXES="$SILENT_BOXES $B"
    done
    SILENT=$(wc -w <<<"$SILENT_BOXES" | tr -dc '0-9'); SILENT="${SILENT:-0}"
    ge "$SILENT" "$BOX_SILENT_MAX" && BOX_BREACH=1
  fi
fi
BOX_DETAIL="$SILENT box(es) fleet.conf still routes work to whose every lane has been silent for over ${BOX_SILENT_MIN}m —${SILENT_BOXES:- none}. Hub-dispatched work cannot reach them; their own cron may still be running, so check their PRs before concluding the lanes stopped."

# --- SLO 5: main red ------------------------------------------------------
# Read-only: the markers belong to whichever lane watches default branches.
RED_NAMES=""; RED=0
for F in "$H/flags"/main-red-*; do
  [ -f "$F" ] || continue
  RED=$(( RED + 1 )); RED_NAMES="$RED_NAMES $(basename "$F" | sed 's/^main-red-//')"
done
RED_BREACH=0
ge "$RED" "$MAIN_RED_MAX" && RED_BREACH=1
RED_DETAIL="$RED default branch(es) red —${RED_NAMES:- none}. Every build on a red main starts from broken code and every review reads a failure it did not cause."

# --- incidents ------------------------------------------------------------
# ONE alert in, ONE alert out, and a stable id that survives the whole incident:
# state/slo/<name>.open carries the id it was opened with, so the resolve names
# the same incident an operator already has in a thread. No re-fire while open —
# a rate that stays breached for an hour is one incident, not six pages.
# mktemp, not a fixed name under state/: ten lanes share /tmp on this box and a
# --dry-run must leave state/slo exactly as it found it.
ROWS=$(mktemp); : > "$ROWS"
OPEN_COUNT=0
incident() { # incident <name> <breach 0|1> <value> <threshold> <detail>
  local name=$1 br=$2 val=$3 thr=$4 detail=$5
  # A second `local`: under set -u, bash creates every name in one `local`
  # before assigning any of them, so open="$STATE/$name.open" on the line above
  # would read an unset $name.
  local open="$STATE/$name.open" id="" opened dur=0
  [ -f "$open" ] && id=$(jq -r '.incident // ""' "$open" 2>/dev/null)
  if [ "$br" = 1 ]; then
    OPEN_COUNT=$(( OPEN_COUNT + 1 ))
    if [ -n "$id" ]; then
      log "$name STILL BREACHED ($val vs $thr) — incident $id already open, not re-firing"
    else
      id="slo-$name-$(date -u -d "@$NOW" +%Y%m%dT%H%MZ)"
      if [ -z "$DRY" ]; then
        jq -nc --arg i "$id" --arg s "$name" --arg o "$(date -u -d "@$NOW" '+%Y-%m-%dT%H:%M:%SZ')" \
              --argjson e "$NOW" --arg v "$val" --arg t "$thr" --arg d "$detail" \
              '{incident:$i,slo:$s,opened_at:$o,opened_epoch:$e,value:$v,threshold:$t,detail:$d}' \
          > "$open.tmp" 2>/dev/null && mv -f "$open.tmp" "$open"
        "$H/bin/lane-alert.sh" --critical fleet-slo \
          "SLO BREACH [$id] $name = $val (threshold $thr, window ${WINDOW_MIN}m): $detail Thresholds live in flags/slo.conf; this incident will not re-fire while it is open, and clears itself with a RESOLVED line." >/dev/null 2>&1 || true
      fi
      log "BREACH $name $val vs $thr [$id] — $detail"
    fi
  else
    if [ -n "$id" ]; then
      opened=$(jq -r '.opened_epoch // 0' "$open" 2>/dev/null); case "$opened" in ''|*[!0-9]*) opened=$NOW ;; esac
      dur=$(( (NOW - opened) / 60 ))
      if [ -z "$DRY" ]; then
        "$H/bin/lane-alert.sh" fleet-slo \
          "SLO RESOLVED [$id] $name = $val, back under threshold $thr after ${dur}m." >/dev/null 2>&1 || true
        rm -f "$open"
      fi
      log "RESOLVED $name $val vs $thr [$id] after ${dur}m"
    fi
    id=""
  fi
  jq -nc --arg s "$name" --arg v "$val" --arg t "$thr" --argjson b "$([ "$br" = 1 ] && echo true || echo false)" \
        --arg i "$id" --arg d "$detail" \
        '{slo:$s,value:$v,threshold:$t,breached:$b,incident:(if $i=="" then null else $i end),detail:$d}' >> "$ROWS"
  printf '%-14s %-8s (threshold %-6s) %s\n' "$name" "$val" "$thr" "$([ "$br" = 1 ] && echo BREACH || echo ok)"
}

incident build_refusal "$REFUSAL_BREACH" "$REFUSAL_VAL" "$REFUSAL_RATE" "$REFUSAL_DETAIL"
incident lane_death    "$LANE_BREACH"    "$LANE_VAL"    "$LANE_RATE"    "$LANE_DETAIL"
incident stale_running "$STALE_BREACH"   "$STALE_VAL"   "$STALE_MAX"    "$STALE_DETAIL"
incident box_silent    "$BOX_BREACH"     "$SILENT"      "$BOX_SILENT_MAX" "$BOX_DETAIL"
incident main_red      "$RED_BREACH"     "$RED"         "$MAIN_RED_MAX" "$RED_DETAIL"

# --- status.json for the console ------------------------------------------
# Small and flat on purpose: Mission Control reads it directly, so it carries
# the measured value, the threshold it was measured against, and the open
# incident id — never prose it would have to parse.
if [ -z "$DRY" ]; then
  jq -s --arg g "$(date -u -d "@$NOW" '+%Y-%m-%dT%H:%M:%SZ')" --arg h "$(hostname)" \
        --argjson w "$WINDOW_MIN" --argjson o "$OPEN_COUNT" \
     '{generated_at:$g, host:$h, window_min:$w, open_incidents:$o, slos:.}' "$ROWS" \
     > "$STATE/status.json.tmp" 2>/dev/null && mv -f "$STATE/status.json.tmp" "$STATE/status.json"
fi
rm -f "$ROWS"

log "fleet-slo: refusal=$REFUSAL_VAL lane_death=$LANE_VAL stale_running=$STALE_VAL box_silent=$SILENT main_red=$RED — $OPEN_COUNT breached (window ${WINDOW_MIN}m)"
[ "$OPEN_COUNT" -gt 0 ] && exit 1
exit 0
