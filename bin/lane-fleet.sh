#!/bin/bash
# bin/lane-fleet.sh tick — the lane-run Fly fleet autoscaler (BH-6126,
# BH-6047 part 3 of 5). Hub cron, every minute, behind the hub lease.
#
# Lanes placed `fly` queue as lane_runs rows (BH-6124). Machines in the Fly app
# `lane-run` run bin/lane-run-worker.sh and claim them. One tick:
#
#   1. gate      lane_gate_or_exit lane-fleet; flock -n locks/lane-fleet.lock
#                (held = exit 0, one log line). JOBS_URL empty = "not
#                configured", exit 0, no Fly call.
#   2. knobs     settings rows lane_fleet.* through setting_get; a missing or
#                out-of-range row uses the code default: warm_floor 1 (0..100),
#                scale_up_wait_s 60 (0..86400), idle_stop_s 600 (60..86400),
#                max_machines 0 (0..1000, 0 = no ceiling), vm_size
#                shared-cpu-2x, vm_memory_mb 2048 (256..65536), start_grace_s
#                180 (30..3600), failed_start_backoff_s 900 (60..86400),
#                image registry.fly.io/lane-run:latest. The image row must name
#                a tag or digest of registry.fly.io/lane-run: the machine gets
#                the lane-run Fly secrets, so any other image uses the default.
#   3. read      GET /api/lane-runs/stats (W = the largest oldest_queued_wait_s;
#                none when no lane is queued), `flyctl machine list -a lane-run
#                --json`, GET /api/lane-fleet/machines. A failed read does
#                nothing else this tick (no start, no stop) and writes one
#                ALERTS line per read kind per UTC day.
#   4. adopt     a Fly `started` machine with no starting/started row is
#                recorded: `starting` when Fly's updated_at is younger than
#                start_grace_s (a lost record write), else `started`.
#      reconcile a `started` row whose machine Fly lists as stopped, or does
#                not list, is marked stopped (destroyed when Fly lists it
#                destroyed or not at all) at Fly's updated_at, then gets its
#                last cost rows up to that time. At most 20 per tick.
#      failed    a `starting` row (no claim since its started_at) that is past
#                start_grace_s, or whose machine Fly lists stopped/destroyed, is
#                a failed start, except a busy row (a live claim) and a row Fly
#                lists `started` while no queued run waited its whole life
#                (W none or W < its age): that one is promoted to `started`.
#                A failed start is: one ALERTS line per UTC day, `machine stop`
#                when Fly still runs it, the row marked stopped (destroyed when
#                Fly lists it destroyed or not at all) with failed:true and
#                Fly's stop time, then its last cost rows. A failed stop keeps
#                the row `starting`, so the next tick tries again. At most 20
#                per tick.
#   5. count     INFLIGHT = rows the worker answers in_flight, Fly machines in
#                created|starting, and the adopted lost-record machines. LIVE
#                = Fly `started` machines that are not in flight. A failed
#                start counts in neither.
#   6. decide    lf_decide: in flight -> none; a failed start this tick, or a
#                last_failed_at younger than failed_start_backoff_s -> none
#                (a start that never claims is not retried every minute); max
#                set and LIVE+INFLIGHT >= max -> none; LIVE < floor -> start;
#                W > scale_up_wait_s -> start (equal is not over). Only when no
#                start is due and W is none (no queued run a stop could kill):
#                lf_pick_stop stops the not-busy, not-in-flight machine with
#                the largest idle_s > idle_stop_s, and only while LIVE > floor.
#                At most one start or one stop per tick.
#   7. start     a Fly `stopped` machine is reused (`machine start`); a failed
#                reuse destroys it (not found = gone) and starts nothing this
#                tick. Else `machine run` with the size rows; the id comes
#                from the `Machine ID:` line only. The id is recorded as
#                `starting`, with started_at = the tick's decision time, before
#                the tick exits. No id = nothing recorded,
#                one ALERTS line per UTC day, retried next tick.
#   8. stop      last cost rows first, then `machine stop`, then the row is
#                marked stopped. A failed stop changes no row and writes one
#                ALERTS line per machine per UTC day.
#   9. cost      for each Fly `started` machine with a row: POST
#                /api/lane-fleet/cost through the current minute, priced by
#                fly_price_per_s on the listing's config.guest (unknown size =
#                usd_per_s null, an UNPRICED row, never $0).
#  10. log       one line in logs/lane-fleet.log:
#                tick wait=<W|none> live=<n> inflight=<n> floor=<n> max=<n|none>
#                action=<start <mid> <reason>|stop <mid> idle=<s>|none <reason>>
#                cost=<written>/<already>
#
# Exit 0 on every path but a usage error (2). Seams for tests: LANE_FLEET_NOW
# (epoch), LANE_FLEET_FLY (the flyctl binary; empty uses fly_bin from
# bin/lib/fly-bin.sh: PATH, then $FLYCTL_INSTALL/bin, $HOME/.fly/bin,
# ${FLY_BIN_DIR:-/root/.fly/bin}, so cron's bare PATH still finds it). No flyctl
# = one log line and one fly-missing ALERTS line per UTC hour. Sourcing this
# file defines the pure lf_decide / lf_pick_stop and runs nothing.
set -uo pipefail

LF_APP=lane-run

# lf_decide <W|none> <LIVE> <INFLIGHT> <FLOOR> <UPWAIT> <MAX> [HOLD]
#   prints `start <reason>` or `none <reason>`. W none (or empty) = no queue.
#   HOLD > 0 = a failed start this tick or inside the backoff: no start.
lf_decide() {
  local w="${1:-none}" live="$2" inflight="$3" floor="$4" up="$5" max="$6" hold="${7:-0}"
  [ -n "$w" ] || w=none
  if [ "$inflight" -gt 0 ]; then echo "none start-in-flight"; return 0; fi
  if [ "$hold" -gt 0 ]; then echo "none failed-start-hold"; return 0; fi
  if [ "$max" -gt 0 ] && [ $((live + inflight)) -ge "$max" ]; then echo "none at-max"; return 0; fi
  if [ "$live" -lt "$floor" ]; then echo "start below-floor"; return 0; fi
  if [ "$w" != none ] && [ "$w" -gt "$up" ]; then echo "start queue-wait"; return 0; fi
  echo "none wait-under-threshold"
}

# lf_pick_stop <LIVE> <FLOOR> <IDLE_S> <machines json array>
#   prints the machine_id of the not-busy, not-in-flight machine with the
#   largest idle_s > IDLE_S, or nothing when LIVE <= FLOOR or none qualifies.
lf_pick_stop() {
  local live="$1" floor="$2" idle="$3" ms="${4:-[]}"
  [ "$live" -gt "$floor" ] || return 0
  printf '%s' "$ms" | jq -r --argjson t "$idle" '
    [ .[] | select((.busy != true) and (.in_flight != true) and ((.idle_s // 0) > $t)) ]
    | sort_by(-(.idle_s), .machine_id) | .[0].machine_id // empty' 2>/dev/null
}

[ "${BASH_SOURCE[0]}" = "$0" ] || return 0

case "${1:-}" in
  tick) ;;
  *) echo "usage: lane-fleet.sh tick" >&2; exit 2 ;;
esac

H="${HARNESS:-$(cd "$(dirname "$0")/.." && pwd)}"
export HARNESS="$H"
mkdir -p "$H/logs" "$H/locks" "$H/flags" "$H/state/lane-fleet" 2>/dev/null
LOG="$H/logs/lane-fleet.log"
NOW="${LANE_FLEET_NOW:-$(date -u +%s)}"
DAY=$(date -u -d "@$NOW" +%Y%m%d)
lf_log() { echo "$(date -u -d "@$NOW" '+%F %TZ') [lane-fleet] $*" >> "$LOG"; }
# lf_epoch <iso> — epoch seconds; rc 1 and nothing printed on an empty or bad stamp.
lf_epoch() { [ -n "${1:-}" ] || return 1; date -u -d "$1" +%s 2>/dev/null; }

# shellcheck source=bin/lib/lane-gate.sh
. "$H/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit lane-fleet
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply lane-fleet

exec 9>"$H/locks/lane-fleet.lock"
flock -n 9 || { lf_log "lock held; another tick is running"; exit 0; }

# shellcheck source=bin/jobs-client.sh
. "$H/bin/jobs-client.sh" || exit 0
# shellcheck source=bin/lib/fly-cost-row.sh
. "$H/bin/lib/fly-cost-row.sh" || exit 0
# shellcheck source=bin/lib/fly-bin.sh
. "$H/bin/lib/fly-bin.sh" 2>/dev/null || true
[ -n "${JOBS_URL:-}" ] || { lf_log "not configured (JOBS_URL empty); no Fly call"; exit 0; }

# lf_alert <kind> <text> [hour] — one ALERTS line per kind per UTC day; with
# `hour`, one per UTC hour, and the kind's flags of earlier hours are removed.
lf_alert() {
  local b="$DAY"
  [ "${3:-}" = hour ] && b=$(date -u -d "@$NOW" +%Y%m%d%H)
  local f="$H/flags/alerted-lane-fleet-$1-$b"
  [ -f "$f" ] && return 0
  [ "${3:-}" = hour ] && find "$H/flags" -maxdepth 1 -type f -name "alerted-lane-fleet-$1-*" ! -name "*-$b" -delete 2>/dev/null
  touch "$f" 2>/dev/null
  HARNESS="$H" "$H/bin/alert-line.sh" "[lane-fleet] $2"
}

# lf_int <key> <fallback> <min> <max> — the lw_poll_s shape.
lf_int() {
  local v
  v=$(setting_get "lane_fleet.$1" 2>/dev/null) || v=""
  case "$v" in ''|*[!0-9]*) v=$2 ;; esac
  [ "${#v}" -le 6 ] && [ "$v" -ge "$3" ] && [ "$v" -le "$4" ] || v=$2
  printf '%s' "$((10#$v))"
}
lf_str() {
  local v
  v=$(setting_get "lane_fleet.$1" 2>/dev/null) || v=""
  [[ "$v" =~ $3 ]] || v=$2
  printf '%s' "$v"
}

FLOOR=$(lf_int warm_floor 1 0 100)
UPWAIT=$(lf_int scale_up_wait_s 60 0 86400)
IDLE=$(lf_int idle_stop_s 600 60 86400)
MAX=$(lf_int max_machines 0 0 1000)
GRACE=$(lf_int start_grace_s 180 30 3600)
BACKOFF=$(lf_int failed_start_backoff_s 900 60 86400)
MEM=$(lf_int vm_memory_mb 2048 256 65536)
SIZE=$(lf_str vm_size shared-cpu-2x '^[a-z0-9-]{1,40}$')
# Pinned to the app's own repository: Fly gives every machine in lane-run the
# app secrets (the GitHub App key among them), so a settings row must never
# choose an image from another registry.
IMAGE=$(lf_str image registry.fly.io/lane-run:latest '^registry\.fly\.io/lane-run[:@][A-Za-z0-9._:-]{1,128}$')

FLY="${LANE_FLEET_FLY:-$(fly_bin 2>/dev/null || true)}"
[ -n "$FLY" ] || { lf_log "flyctl not found (PATH, \$HOME/.fly/bin, \${FLY_BIN_DIR:-/root/.fly/bin}); nothing done"; lf_alert fly-missing "flyctl not found on $(hostname 2>/dev/null) (PATH, \$HOME/.fly/bin, \${FLY_BIN_DIR:-/root/.fly/bin}); the lane-run fleet starts and stops no machine" hour; exit 0; }

# ---- the Fly token (BH-6741) -----------------------------------------------
# env/fly.env, loaded the way bin/fly-pool.sh loads it. The lane-run app's own
# token wins, else the org token. flyctl reads FLY_ACCESS_TOKEN; with no token it
# falls back to the interactive login in ~/.fly/config.yml, which expires (the
# hub tick of 2026-10-14 17:52Z: "your flyctl session has expired"). So with no
# token there is no Fly call at all, and one ALERTS line per UTC hour.
# shellcheck source=bin/lib/env-path.sh
. "$H/bin/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }
HENV=$(harness_env_dir "$H")
# shellcheck disable=SC1091
set -a; . "$HENV/fly.env" 2>/dev/null; set +a
# The app token's name follows bin/fly-pool.sh's rule: FLY_API_TOKEN_<APP>,
# here FLY_API_TOKEN_LANE_RUN. A credential, so it is not a registry knob.
TV="FLY_API_TOKEN_$(echo "$LF_APP" | tr '[:lower:].-' '[:upper:]__')"
FLY_ACCESS_TOKEN="${!TV:-${FLY_API_TOKEN:-}}"
if [ -z "$FLY_ACCESS_TOKEN" ]; then
  lf_log "Fly token missing for $LF_APP (no FLY_API_TOKEN_LANE_RUN or FLY_API_TOKEN in $HENV/fly.env); no Fly call, no start, no stop"
  lf_alert fly-token-missing "Fly token missing for $LF_APP: $HENV/fly.env has no FLY_API_TOKEN_LANE_RUN or FLY_API_TOKEN; the lane-run fleet starts and stops no machine" hour
  exit 0
fi
export FLY_ACCESS_TOKEN FLY_API_TOKEN="$FLY_ACCESS_TOKEN"

W_DIR="$H/state/lane-fleet"
STATS="$W_DIR/stats.json"; LIST="$W_DIR/fly-list.json"; ROWS="$W_DIR/machines.json"

# ---- read (any failure: no action) ------------------------------------------
lf_read_fail() { lf_log "tick read failed: $1 ($2); no start, no stop"; lf_alert "$1" "$1 read failed ($2); no machine is started or stopped until it answers"; exit 0; }
_jobs_req GET /api/lane-runs/stats > "$STATS" || lf_read_fail stats "http ${JOBS_HTTP:-none}"
jq -e '.lanes | type == "array"' "$STATS" >/dev/null 2>&1 || lf_read_fail stats "no lanes array"
W=$(jq -r '[.lanes[].oldest_queued_wait_s | select(type == "number")] | max // "none" | tostring' "$STATS")
case "$W" in none) ;; *[!0-9]*|'') lf_read_fail stats "bad wait '$W'" ;; esac
if ! timeout 30 "$FLY" machine list -a "$LF_APP" --json > "$LIST" 2> "$LIST.err"; then
  FERR=$(tr '\n' ' ' < "$LIST.err" | cut -c1-200)
  # An auth answer is the token, not Fly: name the cause (BH-6741).
  if grep -qiE 'unauthori[sz]ed|not authorized|session has expired|\b401\b|(invalid|expired|bad) (access )?token|token (is )?(invalid|expired|not valid)' <<<"$FERR"; then
    lf_log "tick read failed: Fly token rejected for $LF_APP ($FERR); no start, no stop"
    lf_alert fly-token-rejected "Fly token rejected for $LF_APP ($FERR); renew FLY_API_TOKEN_LANE_RUN or FLY_API_TOKEN in $HENV/fly.env; no machine is started or stopped until it works" hour
    exit 0
  fi
  lf_read_fail fly-list "$FERR"
fi
jq -e 'type == "array"' "$LIST" >/dev/null 2>&1 || lf_read_fail fly-list "not a JSON array"
_jobs_req GET /api/lane-fleet/machines > "$ROWS" || lf_read_fail machines "http ${JOBS_HTTP:-none}"
jq -e '.machines | type == "array"' "$ROWS" >/dev/null 2>&1 || lf_read_fail machines "no machines array"

# lf_record <mid> <state> [started_at|stopped_at] [cpu_kind cpus memory_mb] [failed]
#   the third field is started_at for starting|started, stopped_at otherwise.
lf_record() {
  local b
  b=$(jq -nc --arg m "$1" --arg s "$2" --arg at "${3:-}" --arg k "${4:-}" --arg c "${5:-}" --arg mb "${6:-}" --arg f "${7:-}" '
    {machine_id:$m, state:$s, box:"lane-fleet"}
    + (if $at == "" then {} elif ($s == "starting" or $s == "started") then {started_at:$at} else {stopped_at:$at} end)
    + (if $f == "failed" then {failed:true} else {} end)
    + (if $k == "" then {} else {cpu_kind:$k} end)
    + (if ($c | test("^[0-9]+$")) then {cpus:($c|tonumber)} else {} end)
    + (if ($mb | test("^[0-9]+$")) then {memory_mb:($mb|tonumber)} else {} end)')
  _jobs_req POST /api/lane-fleet/machines "$b" > /dev/null
}
# lf_guest <mid> -> "<cpu_kind> <cpus> <memory_mb>" from the listing.
lf_guest() {
  jq -r --arg m "$1" '.[] | select(.id == $m) | .config.guest // {}
    | "\(.cpu_kind // "") \(.cpus // "") \(.memory_mb // "")"' "$LIST" | head -1
}
COST_W=0; COST_A=0
# lf_cost <mid> — post this machine's minutes through the current minute.
lf_cost() {
  local kind cpus mem rate _src b out
  read -r kind cpus mem <<<"$(lf_guest "$1")"
  if read -r rate _src < <(fly_price_per_s "$H/catalog/fly-prices.json" "$kind" "$cpus" "$mem") && [ -n "$rate" ]; then :; else rate=null; fi
  b=$(jq -nc --arg m "$1" --arg th "$(date -u -d "@$(( NOW / 60 * 60 ))" +%Y-%m-%dT%H:%M:%SZ)" --argjson r "$rate" \
        --arg k "$kind" --arg c "$cpus" --arg mb "$mem" '
    {machine_id:$m, through:$th, usd_per_s:$r}
    + (if ($k | test("^[a-z0-9-]{1,32}$")) then {cpu_kind:$k} else {} end)
    + (if ($c | test("^[0-9]+$")) then {cpus:($c|tonumber)} else {} end)
    + (if ($mb | test("^[0-9]+$")) then {memory_mb:($mb|tonumber)} else {} end)')
  if out=$(_jobs_req POST /api/lane-fleet/cost "$b"); then
    COST_W=$(( COST_W + $(jq -r '.written // 0' <<<"$out") ))
    COST_A=$(( COST_A + $(jq -r '.already // 0' <<<"$out") ))
  else
    lf_log "cost $1 failed (http ${JOBS_HTTP:-none}); the next tick resumes from costed_until"
  fi
}

# ---- adopt and reconcile ----------------------------------------------------
FLY_STARTED=$(jq -c '[.[] | select(.state == "started") | .id]' "$LIST")
ROW_IDS=$(jq -c '[.machines[].machine_id]' "$ROWS")
LOST=0
while IFS=$'\t' read -r mid upd; do
  [ -n "$mid" ] || continue
  read -r kind cpus mem <<<"$(lf_guest "$mid")"
  age=$(( NOW - $(lf_epoch "$upd" || echo 0) ))
  if [ "$age" -lt "$GRACE" ]; then
    LOST=$((LOST + 1)); lf_record "$mid" starting "$upd" "$kind" "$cpus" "$mem" \
      || lf_log "adopt $mid failed (http ${JOBS_HTTP:-none})"
  else
    lf_record "$mid" started "$upd" "$kind" "$cpus" "$mem" || lf_log "adopt $mid failed (http ${JOBS_HTTP:-none})"
  fi
  lf_log "adopted $mid (Fly started, no row; updated ${age}s ago)"
done < <(jq -r --argjson rows "$ROW_IDS" '.[] | select(.state == "started" and (.id as $i | $rows | index($i) | not))
  | [.id, (.updated_at // .created_at // "")] | @tsv' "$LIST" | head -50)
# lf_fly_state <mid> -> "<Fly state|absent> <updated_at|->" from the listing.
lf_fly_state() {
  jq -r --arg m "$1" '(map(select(.id == $m)) | .[0]) as $x
    | "\(($x.state // "absent")) \(($x.updated_at // "-"))"' "$LIST"
}
# lf_stop_at <Fly updated_at|-> — Fly's stop time as an ISO stamp, or nothing.
lf_stop_at() {
  local e
  e=$(lf_epoch "$1") || return 0
  [ "$e" -le "$NOW" ] || e=$NOW
  date -u -d "@$e" +%Y-%m-%dT%H:%M:%SZ
}
# The row is stopped at Fly's stop time BEFORE its cost, so the cost route
# caps the bill there, not at the minute the tick noticed it.
while IFS=$'\t' read -r mid; do
  [ -n "$mid" ] || continue
  read -r fst fupd <<<"$(lf_fly_state "$mid")"
  st=stopped; [ "$fst" = absent ] || [ "$fst" = destroyed ] && st=destroyed
  if lf_record "$mid" "$st" "$(lf_stop_at "$fupd")"; then
    lf_log "reconciled $mid: Fly $fst, row $st"; lf_cost "$mid"
  else
    lf_log "reconcile $mid failed (http ${JOBS_HTTP:-none})"
  fi
done < <(jq -r --slurpfile l "$LIST" '.machines[] | select(.state == "started") | .machine_id as $i
  | (($l[0] | map(select(.id == $i)) | .[0].state) // "absent") as $s
  | select($s == "stopped" or $s == "destroyed" or $s == "absent") | $i' "$ROWS" | head -20)

# ---- failed starts ----------------------------------------------------------
# A `starting` row has made no claim since its started_at (the first claim
# promotes it). Past grace, or with its machine already exited, it never will:
# stop it, alert, and hold every start for the backoff (lf_decide HOLD).
# Two cases are NOT failed starts (re-review of 2c0d0898, findings 1 and 2):
#   - a row whose machine holds a live claim (busy): it is working, and a stop
#     would kill its run;
#   - a row past grace whose machine Fly lists `started` while no queued run
#     waited for the machine's whole life (W none, or W < its age): a healthy
#     idle machine with nothing to claim, the warm floor's normal state. It is
#     promoted to `started` (proof of life), so the floor holds.
FAILED=0; FAILED_IDS="[]"
while IFS=$'\t' read -r mid inf sa busy; do
  [ -n "$mid" ] || continue
  [ "$busy" = true ] && continue
  read -r fst fupd <<<"$(lf_fly_state "$mid")"
  case "$inf:$fst" in
    true:stopped|true:destroyed|false:*) ;;
    *) continue ;;
  esac
  age=$(( NOW - $(lf_epoch "$sa" || echo "$NOW") ))
  if [ "$inf:$fst" = false:started ] && { [ "$W" = none ] || [ "$W" -lt "$age" ]; }; then
    read -r kind cpus mem <<<"$(lf_guest "$mid")"
    if lf_record "$mid" started "$sa" "$kind" "$cpus" "$mem"; then
      lf_log "promoted $mid to started: Fly started, ${age}s old, no run waited for it (wait $W)"
    else
      lf_log "promote $mid failed (http ${JOBS_HTTP:-none})"
    fi
    continue
  fi
  FAILED=$((FAILED + 1)); FAILED_IDS=$(jq -c --arg m "$mid" '. + [$m]' <<<"$FAILED_IDS")
  lf_log "start $mid made no claim in ${age}s (Fly $fst); stopping it, no start for ${BACKOFF}s"
  lf_alert no-claim "start $mid made no claim in ${age}s (Fly $fst); the fleet starts nothing for ${BACKOFF}s after each such start; check the machine log (flyctl logs -a $LF_APP -i $mid)"
  st=stopped; at=""
  case "$fst" in
    stopped) at=$(lf_stop_at "$fupd") ;;
    destroyed|absent) st=destroyed; at=$(lf_stop_at "$fupd") ;;
    *)
      if ! out=$(timeout 120 "$FLY" machine stop "$mid" -a "$LF_APP" 2>&1); then
        lf_log "machine stop $mid failed: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"
        lf_alert "stop-$mid" "machine stop $mid in $LF_APP failed; it made no claim and still runs; the next tick retries"
        continue
      fi ;;
  esac
  if lf_record "$mid" "$st" "$at" "" "" "" failed; then lf_cost "$mid"
  else lf_log "record of failed start $mid failed (http ${JOBS_HTTP:-none})"; fi
done < <(jq -r '.machines[] | select(.state == "starting") | [.machine_id, (.in_flight == true | tostring), .started_at, (.busy == true | tostring)] | @tsv' "$ROWS" | head -20)
HOLD=$FAILED
LASTF=$(jq -r '.last_failed_at // empty' "$ROWS")
if [ "$HOLD" = 0 ] && [ -n "$LASTF" ] && lf_epoch "$LASTF" >/dev/null; then
  [ $(( NOW - $(lf_epoch "$LASTF") )) -lt "$BACKOFF" ] && HOLD=1
fi

# ---- count ------------------------------------------------------------------
INFL_IDS=$(jq -c --slurpfile l "$LIST" --argjson fl "$FAILED_IDS" '
  ($l[0] | map({(.id): .state}) | add // {}) as $fs
  | [ (.machines[] | select(.in_flight == true and (($fs[.machine_id] // "absent") | IN("stopped","destroyed") | not)) | .machine_id),
      ($l[0][] | select(.state == "created" or .state == "starting") | .id) ]
  | map(select(. as $i | $fl | index($i) | not)) | unique' "$ROWS")
INFLIGHT=$(( $(jq 'length' <<<"$INFL_IDS") + LOST ))
LIVE=$(jq --argjson inf "$INFL_IDS" --argjson fl "$FAILED_IDS" '[.[] | select(. as $i | ($inf | index($i) | not) and ($fl | index($i) | not))] | length' <<<"$FLY_STARTED")
LIVE=$(( LIVE - LOST )); [ "$LIVE" -ge 0 ] || LIVE=0
# The stop candidates: rows Fly reports `started`.
CANDS=$(jq -c --argjson fs "$FLY_STARTED" --argjson fl "$FAILED_IDS" '[.machines[] | select(.machine_id as $i | ($fs | index($i)) and ($fl | index($i) | not))]' "$ROWS")

# ---- decide -----------------------------------------------------------------
read -r DEC WHY <<<"$(lf_decide "$W" "$LIVE" "$INFLIGHT" "$FLOOR" "$UPWAIT" "$MAX" "$HOLD")"
ACTION="none $WHY"
STOPPED=""
if [ "$DEC" = start ]; then
  # The start is recorded at the tick's decision time, before `machine start`
  # or `machine run`, never at the POST time: a machine that claims a run
  # before the POST lands still counts that claim (re-review finding 2).
  DECIDED_AT=$(date -u -d "@$NOW" +%Y-%m-%dT%H:%M:%SZ)
  REUSE=$(jq -r '[.[] | select(.state == "stopped") | .id] | sort | .[0] // empty' "$LIST")
  if [ -n "$REUSE" ]; then
    if out=$(timeout 120 "$FLY" machine start "$REUSE" -a "$LF_APP" 2>&1); then
      read -r kind cpus mem <<<"$(lf_guest "$REUSE")"
      lf_record "$REUSE" starting "$DECIDED_AT" "$kind" "$cpus" "$mem" || {
        lf_log "record of start $REUSE failed (http ${JOBS_HTTP:-none}); Fly's state holds the next tick back"
        lf_alert record "machine $REUSE started but its row was not written (http ${JOBS_HTTP:-none})"; }
      ACTION="start $REUSE $WHY"
    else
      lf_log "machine start $REUSE failed: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200); destroying it"
      dout=$(timeout 60 "$FLY" machine destroy "$REUSE" -a "$LF_APP" --force 2>&1); drc=$?
      case "$drc:$dout" in
        0:*|*"not found"*|*"Could not find"*) lf_record "$REUSE" destroyed >/dev/null; lf_log "destroyed $REUSE" ;;
        *) lf_log "destroy $REUSE FAILED rc=$drc: $(printf '%s' "$dout" | tr '\n' ' ' | cut -c1-200)"
           lf_alert "destroy-$REUSE" "machine destroy $REUSE FAILED rc=$drc; it is still in $LF_APP and the next tick retries the reuse" ;;
      esac
      ACTION="none reuse-failed $REUSE"
    fi
  else
    kind=""; cpus=""
    [[ "$SIZE" =~ ^(shared-cpu|performance)-([0-9]+)x$ ]] && { kind=${BASH_REMATCH[1]%-cpu}; cpus=${BASH_REMATCH[2]}; }
    out=$(timeout 180 "$FLY" machine run "$IMAGE" --app "$LF_APP" --detach --restart no \
            --vm-size "$SIZE" --vm-memory "$MEM" -e LANE_RUN=1 2>&1)
    # The id comes off the "Machine ID:" line ONLY (fly-pool.sh: the first bare
    # hex run can be the image digest).
    mid=$(printf '%s\n' "$out" | sed -n 's/.*[Mm]achine ID:[[:space:]]*\([0-9a-z]\{8,32\}\).*/\1/p' | head -1)
    if [ -z "$mid" ]; then
      lf_log "machine run gave no Machine ID: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"
      lf_alert start "flyctl machine run in $LF_APP gave no machine id; nothing recorded, the next tick retries"
      ACTION="none start-failed"
    else
      lf_record "$mid" starting "$DECIDED_AT" "$kind" "$cpus" "$MEM" || {
        lf_log "record of start $mid failed (http ${JOBS_HTTP:-none}); Fly's state holds the next tick back"
        lf_alert record "machine $mid started but its row was not written (http ${JOBS_HTTP:-none})"; }
      ACTION="start $mid $WHY"
    fi
  fi
elif [ "$W" = none ]; then
  SMID=$(lf_pick_stop "$LIVE" "$FLOOR" "$IDLE" "$CANDS")
  if [ -n "$SMID" ]; then
    sidle=$(jq -r --arg m "$SMID" '.[] | select(.machine_id == $m) | .idle_s' <<<"$CANDS")
    lf_cost "$SMID"
    if out=$(timeout 120 "$FLY" machine stop "$SMID" -a "$LF_APP" 2>&1); then
      lf_record "$SMID" stopped || lf_log "record of stop $SMID failed (http ${JOBS_HTTP:-none})"
      ACTION="stop $SMID idle=$sidle"; STOPPED="$SMID"
    else
      lf_log "machine stop $SMID failed: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"
      lf_alert "stop-$SMID" "machine stop $SMID in $LF_APP failed; the next tick retries"
      ACTION="none stop-failed $SMID"
    fi
  fi
fi

# ---- cost -------------------------------------------------------------------
while read -r mid; do
  [ -n "$mid" ] && [ "$mid" != "$STOPPED" ] && lf_cost "$mid"
done < <(jq -r --argjson fl "$FAILED_IDS" '.[] | select(. as $i | $fl | index($i) | not)' <<<"$FLY_STARTED" | head -500)

MAXS=$MAX; [ "$MAX" = 0 ] && MAXS=none
lf_log "tick wait=$W live=$LIVE inflight=$INFLIGHT floor=$FLOOR max=$MAXS action=$ACTION cost=$COST_W/$COST_A"
exit 0
