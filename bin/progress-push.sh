#!/bin/bash
# bin/progress-push.sh — hub cron (*/10): K2, the OUTSIDE dead-man's input.
#
# The watchdog worker only checked LIVENESS (pings, the status push). Nothing
# outside the fleet checked PROGRESS, so silent stops went unpaged: the 09-19
# hub-lease outage stopped orchestration for 29 min, the merge conductor merged
# 0 for hours when its GraphQL budget ran out, the share mirror froze for two
# days, fleet-slo.sh was never scheduled, and project-9 spent $643 in a week with
# no merge. This lane pushes the watchdog what it needs to see that:
#
#   * per-project progress stamps (last triage row, build result, review
#     verdict, merge, priced cost row), spend in the short window and in each
#     no-merge window, and queued work — ONE read of the jobs worker's
#     GET /api/progress/stamps, rows the fleet already writes, no GitHub call;
#   * each detector lane's own last run (lane_ticks) — watch the watchers — and
#     which of them are hub-scoped (catalog/lanes.json `.scope`), so the worker
#     judges a hub detector by its newest row and not a standby's stale one;
#   * the hub-local facts the database does not hold: held build rows
#     (state/pool/<p>/*.held, BH-1461), tickets owed (state/stale-owed.json),
#     pause flags;
#   * the THRESHOLDS, as `cfg`, from this lane's settings rows (the knobs below,
#     catalog/lanes.d/progress-push.json). The worker clamps them and holds none
#     of its own.
#
# The watchdog judges it on ITS cron (worker/watchdog/src/progress.js) and pages
# Telegram directly: no LLM and no fleet box in the paging path. If this lane
# stops (lease, cron, disk), the push goes stale and the watchdog pages for that.
# Under flags/all-off it still pushes, but only an all-off MARKER, so the page
# says "fleet all-off" rather than blaming the hub lease.
#
#   bin/progress-push.sh             push (the cron line)
#   bin/progress-push.sh --dry-run   ask the watchdog what this live snapshot
#                                    WOULD page, print it, store and page nothing.
#                                    Runs even with the lane switched off: it is
#                                    how the thresholds are checked before arming.
#
# FAIL-OPEN, NEVER FAIL-HEALTHY. An unreachable jobs worker still pushes, with
# `errors: ["jobs-unreachable"]` and the database halves of pending as null; the
# watchdog pages the unknown and holds every rule that reads it. A fabricated 0
# here would read as "nothing waiting" forever.
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1
DRY=0
[ "${1:-}" = --dry-run ] && DRY=1
H=/root/harness
[ -n "${HARNESS:-}" ] && H="$HARNESS"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")
set -a; . "$HENV/global.env" 2>/dev/null; set +a

# >>> lane gate (BH-1165) — this lane's settings rows as env first (the all-off
# marker below carries the thresholds too), then the off-switch. A dry run is
# never gated: it pages nothing, and checking thresholds before arming is its job.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply progress-push

# The watchdog credential, looked up exactly as bin/watchdog-ping.sh does: the
# dedicated env/.watchdog-secret wins, HARNESS_SECRET is the fallback. The jobs
# read below is the jobs worker's own bearer (bin/jobs-client.sh), not this.
WD_S=""
[ -r "$HENV/.watchdog-secret" ] && WD_S=$(tr -d '\r\n' < "$HENV/.watchdog-secret" 2>/dev/null)
[ -n "$WD_S" ] || WD_S="${HARNESS_SECRET:-}"
[ -n "$WD_S" ] || exit 0

# An unreadable fleet.conf yields no projects: say nothing and let the push go
# stale, which is what the watchdog pages on (same rule as fleet-status-push).
FLEET_PROJECTS=$("$H/bin/fleet-conf.sh" --projects 2>/dev/null)
[ -n "$FLEET_PROJECTS" ] || exit 0

# ── thresholds: this lane's settings rows (code defaults are the fallback) ──
# Seeded per the #2289 review: triage is not a silent-stop lane (its owed
# tickets already page through stale-owed, and a finished triage job exists
# only when the gate runs); merge 60 until merge_queue rows are proven to reach
# landed/dropped; fleet-slo and pipeline-health at 15 because they tick in the
# same minute as this push; share-mirror out until its stamp credential exists
# (then share-mirror:1440 with publish-cromford.yml's daily trigger, armed); a
# daily and a weekly no-merge window; lead-review judged against any progress.
PROGRESS_SPEND_WINDOW_MIN="${PROGRESS_SPEND_WINDOW_MIN:-60}"
PROGRESS_SPEND_MIN_USD="${PROGRESS_SPEND_MIN_USD:-5}"
PROGRESS_SPEND_QUIET_MIN="${PROGRESS_SPEND_QUIET_MIN:-180}"
PROGRESS_NOMERGE="${PROGRESS_NOMERGE:-1440:50,10080:250}"
PROGRESS_SILENT_MULT="${PROGRESS_SILENT_MULT:-2}"
PROGRESS_DETECTOR_MULT="${PROGRESS_DETECTOR_MULT:-2}"
PROGRESS_REPAGE_MIN="${PROGRESS_REPAGE_MIN:-360}"
PROGRESS_LOOKBACK_H="${PROGRESS_LOOKBACK_H:-168}"
PROGRESS_LANE_CADENCE="${PROGRESS_LANE_CADENCE:-build:120,merge:60}"
PROGRESS_STAGE_LANES="${PROGRESS_STAGE_LANES:-triage:triage,plan:build,execute:build,fix:build,preplan:build,feature-map-draft:build,review:review,lead-review:any}"
PROGRESS_DETECTORS="${PROGRESS_DETECTORS:-fleet-slo:15,pipeline-health:15,cost-rollup:60,alert-warn-flush:30,ci-minutes-watch:360,progress-push:10}"
# BH-3322: no default host; post_wd skips the POST when WATCHDOG_URL is unset.
. "$H/bin/lib/watchdog-url.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/watchdog-url.sh" 2>/dev/null || watchdog_url() { return 1; }
LOG="$H/logs/progress-push.log"
mkdir -p "$H/logs" 2>/dev/null

# "a:1,b:2" -> {"a":1,"b":2}; "a:b" -> {"a":"b"} with --strings. A malformed
# pair is DROPPED (and counted in the log line), never guessed at: the worker
# validates the whole cfg and keeps its last good copy if this one is wrong.
DROPPED=0
map_json() { # map_json <csv> [--strings]
  local csv="$1" mode="${2:-}" out='{}' pair k v
  local IFS=','
  for pair in $csv; do
    k=${pair%%:*}; v=${pair#*:}
    if [ "$k" = "$pair" ] || ! [[ $k =~ ^[a-z0-9][a-z0-9_-]{0,63}$ ]]; then DROPPED=$((DROPPED+1)); continue; fi
    if [ "$mode" = --strings ]; then
      [[ $v =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]] || { DROPPED=$((DROPPED+1)); continue; }
      out=$(printf %s "$out" | jq -c --arg k "$k" --arg v "$v" '.[$k]=$v')
    else
      [[ $v =~ ^[0-9]+$ ]] && [ "$v" -gt 0 ] || { DROPPED=$((DROPPED+1)); continue; }
      out=$(printf %s "$out" | jq -c --arg k "$k" --argjson v "$v" '.[$k]=$v')
    fi
  done
  printf '%s' "$out"
}
DET_JSON=$(map_json "$PROGRESS_DETECTORS")
CAD_JSON=$(map_json "$PROGRESS_LANE_CADENCE")
STG_JSON=$(map_json "$PROGRESS_STAGE_LANES" --strings)
NOM_JSON=$(map_json "$PROGRESS_NOMERGE")
# Hub-scope detectors, from the lane registry, resolved through the ONE loader
# (bin/lib/lanes-registry.sh lanes_json_path: it renders catalog/lanes.json
# from catalog/lanes.d/ when missing or stale) — LANE_REGISTRY overrides, as it
# does for lane-gate. Unreadable is SAID, never silently "every detector is
# per box": `registry` goes into the push's errors (the watchdog pages it as a
# source) and ONE warn line goes to ALERTS, re-armed only after it recovers.
REG="${LANE_REGISTRY:-}"
if [ -z "$REG" ] && [ -r "$H/bin/lib/lanes-registry.sh" ]; then
  # shellcheck source=bin/lib/lanes-registry.sh
  . "$H/bin/lib/lanes-registry.sh" 2>/dev/null && REG=$(lanes_json_path "$H" 2>/dev/null)
fi
REG_ERR='[]'
HUB_JSON=""
[ -n "$REG" ] && [ -r "$REG" ] && HUB_JSON=$(jq -c --argjson det "$DET_JSON" \
  '[.lanes[] | select(.scope == "hub") | .id | select(. as $i | $det | has($i))] | unique' "$REG" 2>/dev/null)
REG_MARK="$H/flags/warned-progress-push-registry"
if [ -z "$HUB_JSON" ]; then
  HUB_JSON='[]'; REG_ERR='["registry"]'
  if [ "$DRY" = 0 ] && [ ! -e "$REG_MARK" ]; then
    mkdir -p "$H/flags" 2>/dev/null; touch "$REG_MARK" 2>/dev/null
    if [ -x "$H/bin/lane-alert.sh" ]; then
      "$H/bin/lane-alert.sh" --severity warn --id progress-push-registry progress-push \
        "lane registry unreadable (${REG:-no path}): hub-scope detectors cannot be told apart" >/dev/null 2>&1 || true
    else
      echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [progress-push] WARN lane registry unreadable (${REG:-no path}): hub-scope detectors cannot be told apart" >> "$H/logs/ALERTS.log"
    fi
  fi
else
  rm -f "$REG_MARK" 2>/dev/null
fi
# A number that does not parse travels as null, so the worker rejects the whole
# cfg by name rather than this script inventing a value.
CFG=$(jq -nc \
  --arg sw "$PROGRESS_SPEND_WINDOW_MIN" --arg su "$PROGRESS_SPEND_MIN_USD" --arg sq "$PROGRESS_SPEND_QUIET_MIN" \
  --arg sm "$PROGRESS_SILENT_MULT" --arg dm "$PROGRESS_DETECTOR_MULT" --arg rp "$PROGRESS_REPAGE_MIN" \
  --argjson det "$DET_JSON" --argjson cad "$CAD_JSON" --argjson stg "$STG_JSON" \
  --argjson nom "$NOM_JSON" --argjson hub "$HUB_JSON" \
  '{spend_window_min:($sw|tonumber? // null), spend_min_usd:($su|tonumber? // null),
    spend_quiet_min:($sq|tonumber? // null), nomerge:$nom, silent_mult:($sm|tonumber? // null),
    detector_mult:($dm|tonumber? // null), repage_min:($rp|tonumber? // null),
    lane_cadence_min:$cad, stage_lanes:$stg, detectors:$det, detector_hub:$hub}')

# shellcheck source=/dev/null
[ -r "$H/bin/jobs-client.sh" ] && . "$H/bin/jobs-client.sh"
# BH-5001: held counts as pool_holds rows, while pool_state_rows is on.
# shellcheck source=bin/lib/pool-state-rows.sh
. "$H/bin/lib/pool-state-rows.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/pool-state-rows.sh" 2>/dev/null || true

post_wd() { # post_wd <path> <body> — prints the watchdog's answer
  local wd
  wd=$(watchdog_url progress-push "$H") || { printf 'skipped: WATCHDOG_URL not set'; return 0; }
  printf %s "$2" | curl -sS -m 15 -X POST "$wd$1?s=$WD_S" \
    -H 'content-type: application/json' --data-binary @- 2>/dev/null
}

# ── the gate, and the one thing that passes it: the all-off marker ─────────
# lane_gate_or_exit exits silently under all-off, and a silent push reads at
# the watchdog exactly like a dead hub lease. So the gate's own predicate
# (lane_paused, which reconciles the pause_flags row into the file) is asked
# first: when the answer is the FLEET master switch, the gate is skipped only
# to push a marker saying so, and nothing else runs. A lane-off-progress-push
# switch still exits at the gate (and the watchdog pages the stale push, which
# is what switching the watcher off should do). A dry run is never gated.
ALLOFF=0
if [ "$DRY" = 0 ]; then
  if command -v lane_paused >/dev/null 2>&1; then
    lane_paused progress-push && [ "${LANE_PAUSED_FLAG:-}" = all-off ] && ALLOFF=1
  else
    [ -e "$H/flags/all-off" ] && ALLOFF=1
  fi
fi
[ "${ALLOFF:-0}" = 1 ] || [ "${DRY:-0}" = 1 ] || { command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit progress-push; }
if [ "$ALLOFF" = 1 ]; then
  RESP=$(post_wd /api/progress "$(jq -nc --argjson cfg "$CFG" '{v:1, all_off:true, cfg:$cfg}')") || RESP="post failed"
  echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [progress-push] all-off marker pushed watchdog=$(head -c 120 <<<"$RESP")" >> "$LOG"
  exit 0
fi

# ── the stamps: one read of the jobs worker ─────────────────────────────────
# `progress-push` is this push itself (the watchdog times it on receipt), so it
# is the one detector not asked of lane_ticks.
DET_Q=$(printf %s "$DET_JSON" | jq -r '[keys[] | select(. != "progress-push")] | join(",")')
LONG_Q=$(printf %s "$NOM_JSON" | jq -r '[keys[] | tonumber] | sort | map(tostring) | join(",")')
RAW=""
if command -v _jobs_req >/dev/null 2>&1; then
  RAW=$(_jobs_req GET "/api/progress/stamps?spend_min=$PROGRESS_SPEND_WINDOW_MIN&long_min=$LONG_Q&lookback_h=$PROGRESS_LOOKBACK_H&detectors=$DET_Q" 2>/dev/null) || RAW=""
fi
printf %s "$RAW" | jq -e 'type=="object" and (.projects|type)=="object"' >/dev/null 2>&1 || RAW=""

# ── the hub-local half, per declared project ────────────────────────────────
OWED="$H/state/stale-owed.json"
LOCAL='{}'
for P in $FLEET_PROJECTS; do
  # >>> held count (BH-5001)
  # The pool_holds rows when pool_state_rows is on and the worker answered (a
  # hold marked on any hub); the <KEY>.held markers otherwise, as before.
  HELD=0; HK=""; HR=0
  if command -v psr_on >/dev/null 2>&1 && psr_on && psr_load "$P" "$(date +%s)"; then
    HK=$(psr_held_keys) && HR=1
  fi
  if [ "$HR" = 1 ]; then
    HELD=$(printf '%s\n' "$HK" | grep -c . || true)
  else
    for M in "$H/state/pool/$P/"*.held; do [ -e "$M" ] && HELD=$((HELD+1)); done
  fi
  # <<< held count (BH-5001)
  OWN=$(jq -r --arg p "$P" '.[$p].count // 0 | tonumber? // 0' "$OWED" 2>/dev/null); case "$OWN" in ''|*[!0-9]*) OWN=0 ;; esac
  # BH-4153: the paused-<P> row through flag_active; the file only with no client.
  PAUSED=false
  if command -v flag_active >/dev/null 2>&1; then flag_active "paused-$P" >/dev/null 2>&1 && PAUSED=true
  elif [ -e "$H/flags/paused-$P" ]; then PAUSED=true; fi
  LOCAL=$(printf %s "$LOCAL" | jq -c --arg p "$P" --argjson h "$HELD" --argjson o "$OWN" --argjson pz "$PAUSED" \
    '.[$p]={held:$h, owed:$o, paused:$pz}')
done

if [ -n "$RAW" ]; then SRC="$RAW"; ERR_EXTRA='[]'; else SRC='{"projects":{},"detectors":[],"errors":[]}'; ERR_EXTRA='["jobs-unreachable"]'; fi
ERR_EXTRA=$(jq -nc --argjson a "$ERR_EXTRA" --argjson b "$REG_ERR" '$a + $b')
BODY=$(printf %s "$SRC" | jq -c --argjson local "$LOCAL" --argjson cfg "$CFG" --argjson xe "$ERR_EXTRA" '
  (.projects // {}) as $db
  | ($xe | index("jobs-unreachable") != null) as $down
  | {v: 1, as_of: (.as_of // null), cfg: $cfg,
     detectors: (if $down then [] else .detectors end),
     errors: (((.errors // []) + $xe) | unique),
     projects: ($local | with_entries(.key as $p | .value as $l | ($db[$p] // {}) as $d | .value = {
        stamps: ($d.stamps // {}),
        spend: (if $down then null elif $d == {} then {} else $d.spend end),
        spend_long: (if $down then null elif $d == {} then {} else $d.spend_long end),
        pending: {
          build: (if $down or ($d != {} and $d.queued == null) then null
                  else ([(($d.queued.build // 0) - $l.held), 0] | max) end),
          merge: (if $down or ($d != {} and $d.queued == null) then null else ($d.queued.merge // 0) end),
          triage: $l.owed},
        paused: $l.paused}))}')
if [ -z "$BODY" ]; then
  [ "$DRY" = 1 ] && { echo "progress-push --dry-run: could not build the payload"; exit 1; }
  echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [progress-push] could not build the payload — nothing pushed" >> "$LOG"
  exit 0
fi

if [ "$DRY" = 1 ]; then
  RESP=$(post_wd /api/progress/dry-run "$BODY")
  if ! printf %s "$RESP" | jq -e 'type=="object"' >/dev/null 2>&1; then
    echo "progress-push --dry-run: the watchdog did not answer (got: $(head -c 200 <<<"$RESP"))"; exit 1
  fi
  printf %s "$RESP" | jq -r --argjson e "$(printf %s "$BODY" | jq -c '.errors')" '
    "progress-push --dry-run (nothing stored, nothing paged)",
    "cfg: " + (if .cfg_ok then "ok" else "REJECTED: " + (.cfg_error // "?") end)
      + (if (.clamped // []) | length > 0 then " · clamped: " + (.clamped | join(", ")) else "" end),
    "source errors: " + ($e | if length == 0 then "none" else join(", ") end),
    "would page \(.incidents | length) incident(s); \(.note)",
    (.incidents[] | "  [\(.key)]\(if .open then " (open now)" elif .cooling then " (cooling)" else "" end) \(.text)")'
  exit 0
fi

RESP=$(post_wd /api/progress "$BODY") || RESP="post failed"
echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [progress-push] projects=$(printf %s "$BODY" | jq '.projects|length') errors=$(printf %s "$BODY" | jq -c '.errors') dropped_knob_pairs=$DROPPED watchdog=$(head -c 120 <<<"$RESP")" >> "$LOG"
exit 0
