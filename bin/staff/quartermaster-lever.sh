#!/bin/bash
# bin/staff/quartermaster-lever.sh — the quartermaster staff agent's metric and
# its one lever (BH-10123, C2 of #9423). Hub only, hourly at :49
# (cron/lanes/787-staff-quartermaster-lever.cron). No LLM call, no GitHub call.
#
# WHY. The staff contract (BH-9187, C0) says every staff agent owns ONE metric
# and is judged by whether it moved. The quartermaster owns orphan_usd_day: the
# $/day of started Fly machines with no job row, plus the $/day of idle Orgo
# capacity (target staff.quartermaster.target, 0). Its lever is a stop of an
# orphan pool machine through bin/fly-idle-reaper.sh act, run through the
# contract: one ledger row before each stop, and a later sample decides
# whether the metric fell.
#
# WHAT, in order (each step that stops writes one log line and exits 0):
#   1  load the libs; no jq, jobs client, staff-contract.sh or HARNESS_SECRET
#      = `not-configured (<what>)`.
#   2  KILL, before any request: STAFF_ENABLED=0, then the flags staff-off-all,
#      staff-kill-all, staff-off-quartermaster, staff-kill-quartermaster.
#   3  flock -n locks/staff-quartermaster-lever.lock.
#   4  GET /api/staff/agent?name=quartermaster: the agent must be active.
#   5  FLY: GET /api/fly-idle (the reaper's snapshot). Readable = .machines is
#      an array and .pass.pass_at is at most staff.quartermaster.
#      snapshot_max_age_min old; else fly=unreadable|stale, no sample, no action.
#      An orphan is a machine with idle_state idle or over and a whole-number
#      idle_s MORE than idle_min*60 (the reaper's idle_s is the time with no
#      job row: its pool witness is the pool tracking file and claimed queue
#      rows). fly_usd_day = sum(usd_per_hour * 24) over priced orphans; an
#      unpriced orphan adds 0 (unpriced=N). unknown and nosignal machines are
#      not orphans (unsettled=N).
#   6  ORGO: each account of catalog/orgo-plans.json whose pool records a
#      number with a price. None: orgo=not-recorded, no read, 0. Else ONE read
#      of GET /api/orgo-computers; used = the account's computers with gone_at
#      null; idle $/day = sum max(pool - used, 0) * price / days in the UTC
#      month. A failed read, truncated:true, or a null spec that is needed on
#      a live computer = orgo=unreadable, no sample, no action.
#   7  SAMPLE: POST /api/staff/levers/metric {agent:quartermaster,
#      metric:orphan_usd_day}. It settles the agent's due actions (C0). A
#      failure: sample=failed, the run goes on.
#   8  GATE: act only at level act (staff_level quartermaster).
#   9  MODE: apply only when the row staff.quartermaster.lever_dry_run is
#      exactly 0 (trimmed); no row, an outage or any other value is dry.
#  10  CANDIDATES: orphans with source pool, a valid app and machine id, most
#      idle first, at most staff.quartermaster.stops_max_run (over_cap=N).
#  11  RECORD BEFORE ACT, per candidate: POST /api/staff/levers/actions with
#      key fly-stop:<dry|apply>:<app>/<mid>:<UTC hour>. Only a new row acts;
#      existing or 409 = taken; anything else = failed. So no stop runs
#      without its ledger row.
#  12  ACT: dry = bin/fly-idle-reaper.sh act probe <app> <mid> (read only);
#      apply = act stop <app> <mid> (the reaper probes again, and refuses a busy
#      machine). rc 0 stopped, rc 1 refused, other failed. Each call runs under
#      `timeout staff.quartermaster.act_timeout_s`.
#
# KNOBS (settings rows): staff.quartermaster.level (observe),
# staff.quartermaster.idle_min (60), .lever_dry_run (1 = dry),
# .stops_max_run (3), .snapshot_max_age_min (30), .act_timeout_s (180). Env
# STAFF_ENABLED (0 = off). Seed:
# worker/jobs/schema.d/202611252040-bh-10123-quartermaster-lever.sql.
#
# WRITES. In logs/staff-quartermaster-lever.log, one line per candidate:
#   <ts> <app>/<mid> idle_s=<s> action=<recorded|taken|failed> act=<probe:<ans>|stopped|refused|failed|->
# and one summary line per run:
#   <ts> level=<L> orphan_usd_day=<v|unreadable> fly=<ok|unreadable|stale>
#   orgo=<ok|not-recorded|unreadable|-> sample=<ok|failed|none> dry=<0|1|->
#   candidates=<n> recorded=<n> taken=<n> failed=<n> stopped=<n> refused=<n> over_cap=<n>
# The rows: staff_metric_samples and staff_lever_actions through the C0
# routes. A stop writes the reaper's own stop row and beat. No state/ file.
#
# EXIT. 0 every run that finished; 2 bad arguments.
# Env (sandbox test seams): QM_LEVER_NOW (epoch seconds, only with
#   HARNESS_TEST_SANDBOX=1), QM_LEVER_LIB_ONLY=1 (load qm_action_verdict,
#   qm_orphans, qm_candidates and return).
# OFF: flags/lane-off-staff-quartermaster-lever (bin/harness-ctl.sh off
#   staff-quartermaster-lever), or any staff kill flag above. Registry:
#   catalog/lanes.d/staff-quartermaster-lever.json.
# Doc: docs/notes/2026-11-25-BH-10123-quartermaster-lever.md.
set -uo pipefail

# qm_action_verdict <http-code> <body-file> <rc> — the answer of
# POST /api/staff/levers/actions -> run | taken | failed. Only a new row is
# run (D9): existing or 409 is this hour's action already taken, and anything
# else fails closed.
qm_action_verdict() {
  local code="${1:-}" f="${2:-}" rc="${3:-1}"
  if [ "$code" = 409 ]; then echo taken; return 0; fi
  if [ "$rc" = 0 ] && [[ "$code" == 2?? ]] && [ -s "$f" ]; then
    if jq -e '.ok == true and .existing == true' "$f" >/dev/null 2>&1; then echo taken; return 0; fi
    if jq -e '.ok == true and (.existing // false) == false and (.action.action_key | type) == "string"' "$f" >/dev/null 2>&1; then
      echo run; return 0
    fi
  fi
  echo failed
}

# qm_orphans <snapshot-file> <idle_min> — one JSON object:
#   {orphans:[machine...], fly_usd_day, unpriced, unsettled}
# An orphan: idle_state idle or over, and idle_s a whole number MORE than
# idle_min * 60. A string idle_s is not a number.
qm_orphans() {
  jq -c --argjson lim "$(( ${2:-60} * 60 ))" '
    [.machines[] | select(type == "object")] as $m
    | [$m[] | select((.idle_state == "idle" or .idle_state == "over")
        and (.idle_s | type) == "number" and .idle_s == (.idle_s | floor) and .idle_s > $lim)] as $o
    | {orphans: $o,
       fly_usd_day: ([$o[] | .usd_per_hour | select(type == "number") | . * 24] | add // 0),
       unpriced: ([$o[] | select((.usd_per_hour | type) != "number")] | length),
       unsettled: ([$m[] | select(.idle_state == "unknown" or .idle_state == "nosignal")] | length)}' "$1"
}

# qm_candidates <orphans-json> <max> — the lever targets, one TSV line each:
# app mid idle_s usd_per_hour|unpriced. Source pool only (the registry source,
# never the app name), a valid app and machine id, most idle first. The line
# `over_cap <n>` comes last.
qm_candidates() {
  jq -r --argjson max "${2:-3}" '
    [.orphans[] | select(.source == "pool"
        and ((.app // "") | test("^[a-z0-9][a-z0-9-]{0,62}$"))
        and ((.machine_id // "") | test("^[0-9a-f]{6,32}$")))]
    | sort_by([-.idle_s, .app, .machine_id]) as $c
    | ($c[:$max][] | [.app, .machine_id, (.idle_s | tostring),
        (if (.usd_per_hour | type) == "number" then (.usd_per_hour | tostring) else "unpriced" end)] | @tsv),
      "over_cap\t\([($c | length) - $max, 0] | max)"' <<<"$1"
}

[ "${QM_LEVER_LIB_ONLY:-}" = 1 ] && return 0 2>/dev/null

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) sed -n '2,76p' "$0"; exit 0 ;;
    *) echo "quartermaster-lever: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

H="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "$0")" && pwd)"
LIBD="$(cd "$SELF/.." && pwd)"
. "$H/bin/lib/env-path.sh" 2>/dev/null || . "$LIBD/lib/env-path.sh" 2>/dev/null \
  || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }
HENV=$(harness_env_dir "$H")
# shellcheck disable=SC1091
[ -r "$HENV/global.env" ] && { set -a; . "$HENV/global.env" 2>/dev/null; set +a; }

mkdir -p "$H/logs" "$H/locks" 2>/dev/null
LOG="$H/logs/staff-quartermaster-lever.log"
NOW=$(date -u +%s)
[ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [[ ${QM_LEVER_NOW:-} =~ ^[0-9]+$ ]] && NOW=$QM_LEVER_NOW
TS=$(date -u -d "@$NOW" +%FT%TZ)
log() { printf '%s %s\n' "$TS" "$*" >> "$LOG"; }

# shellcheck disable=SC1091
. "$H/bin/lib/lane-gate.sh" 2>/dev/null || . "$LIBD/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit staff-quartermaster-lever
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply staff-quartermaster-lever

# ── 1 libs ────────────────────────────────────────────────────────────────────
command -v jq >/dev/null 2>&1 || { log "not-configured (no jq)"; exit 0; }
# shellcheck source=bin/jobs-client.sh
. "$H/bin/jobs-client.sh" 2>/dev/null || . "$LIBD/jobs-client.sh" 2>/dev/null
# shellcheck source=bin/lib/staff-contract.sh
. "$H/bin/lib/staff-contract.sh" 2>/dev/null || . "$LIBD/lib/staff-contract.sh" 2>/dev/null
for fn in _jobs_req _jobs_req_file flag_active setting_get; do
  command -v "$fn" >/dev/null 2>&1 || { log "not-configured (no bin/jobs-client.sh: $fn)"; exit 0; }
done
command -v staff_action_post >/dev/null 2>&1 || { log "not-configured (no bin/lib/staff-contract.sh)"; exit 0; }
[ -n "${HARNESS_SECRET:-}" ] || { log "not-configured (no HARNESS_SECRET)"; exit 0; }

# ── 2 kill, before any request ────────────────────────────────────────────────
[ "${STAFF_ENABLED:-1}" = 0 ] && { log "killed by STAFF_ENABLED=0"; exit 0; }
for f in staff-off-all staff-kill-all staff-off-quartermaster staff-kill-quartermaster; do
  if flag_active "$f"; then log "killed by $f"; exit 0; fi
done

# ── 3 lock ────────────────────────────────────────────────────────────────────
exec 9>"$H/locks/staff-quartermaster-lever.lock" || { log "lock file unwritable - not running"; exit 0; }
flock -n 9 || { log "another quartermaster-lever run is running"; exit 0; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/qm-lever.XXXXXX") || { log "worker-failed (mktemp)"; exit 0; }
trap 'rm -rf "$WORK"' EXIT

# ── 4 roster ──────────────────────────────────────────────────────────────────
row=$(_jobs_req GET "/api/staff/agent?name=quartermaster"); rc=$?
[ "$rc" = 0 ] || { log "roster row unreadable or absent (rc=$rc); nothing ran"; exit 0; }
[ "$(jq -r '.agent.status // ""' <<<"$row" 2>/dev/null)" = active ] || { log "quartermaster is not active on the roster; nothing ran"; exit 0; }

L=- V=unreadable FLYS=- ORGOS=- SAMPLE=none DRY=-
NC=0 NREC=0 NTAKEN=0 NFAIL=0 NSTOP=0 NREF=0 OVER=0
summary() {
  log "level=$L orphan_usd_day=$V fly=$FLYS orgo=$ORGOS sample=$SAMPLE dry=$DRY candidates=$NC recorded=$NREC taken=$NTAKEN failed=$NFAIL stopped=$NSTOP refused=$NREF over_cap=$OVER"
}

IDLE_MIN=$(staff_knob quartermaster idle_min 60)               # fallback 60; row staff.quartermaster.idle_min
MAXRUN=$(staff_knob quartermaster stops_max_run 3)             # fallback 3; row staff.quartermaster.stops_max_run
MAXAGE=$(staff_knob quartermaster snapshot_max_age_min 30)     # fallback 30; row staff.quartermaster.snapshot_max_age_min
ACT_TIMEOUT=$(staff_knob quartermaster act_timeout_s 180)      # fallback 180; row staff.quartermaster.act_timeout_s

# ── 5 fly ─────────────────────────────────────────────────────────────────────
FLYS=unreadable
if JOBS_ALERT=0 _jobs_req GET /api/fly-idle > "$WORK/fly.json" 2>/dev/null \
   && jq -e '(.machines | type) == "array"' "$WORK/fly.json" >/dev/null 2>&1; then
  PASS_AT=$(jq -r '.pass.pass_at // empty' "$WORK/fly.json" 2>/dev/null)
  PASS_S=""
  if [ -n "$PASS_AT" ] && [[ $PASS_AT =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
    PASS_S=$(date -u -d "$PASS_AT" +%s 2>/dev/null)
  fi
  if [[ ${PASS_S:-} =~ ^[0-9]+$ ]]; then
    if [ "$((NOW - PASS_S))" -le "$((MAXAGE * 60))" ]; then FLYS=ok; else FLYS=stale; fi
  fi
fi
if [ "$FLYS" != ok ]; then
  log "fly-idle snapshot $FLYS (max age ${MAXAGE} min); no sample, no action"
  summary; exit 0
fi
qm_orphans "$WORK/fly.json" "$IDLE_MIN" > "$WORK/orphans.json" 2>/dev/null \
  || { FLYS=unreadable; log "fly-idle snapshot does not parse; no sample, no action"; summary; exit 0; }
FLY_USD=$(jq -r '.fly_usd_day' "$WORK/orphans.json")

# ── 6 orgo ────────────────────────────────────────────────────────────────────
CAT="$H/catalog/orgo-plans.json"; [ -r "$CAT" ] || CAT="$LIBD/../catalog/orgo-plans.json"
# The accounts whose pool records at least one number that has a price.
# pool key -> price key: computers->computer, vcpus->vcpu, ram_gb, disk_gb.
jq -c '[{p: "computers", c: "computer"}, {p: "vcpus", c: "vcpu"}, {p: "ram_gb", c: "ram_gb"}, {p: "disk_gb", c: "disk_gb"}] as $keys
  | [(.accounts // {}) | to_entries[]
    | (.value.pool // {}) as $pool | (.value.prices_usd_mo // {}) as $price
    | {account: .key,
       need: [$keys[] | select(($pool[.p] | type) == "number" and ($price[.c] | type) == "number")
              | {key: .p, pool: $pool[.p], price: $price[.c]}]}
    | select(.need | length > 0)]' "$CAT" > "$WORK/orgo-need.json" 2>/dev/null; crc=$?
ORGO_USD=0
# A catalog that does not parse is unreadable, never "not recorded" (D11).
if [ "$crc" != 0 ]; then
  ORGOS=unreadable
  log "catalog/orgo-plans.json does not parse; no sample, no action"
  summary; exit 0
fi
if [ "$(jq 'length' "$WORK/orgo-need.json")" = 0 ]; then
  ORGOS=not-recorded
else
  ORGOS=unreadable
  DAYS=$(date -u -d "$(date -u -d "@$NOW" +%Y-%m-01) +1 month -1 day" +%d 2>/dev/null)
  if [[ ${DAYS:-} =~ ^[0-9]+$ ]] && JOBS_ALERT=0 _jobs_req GET /api/orgo-computers > "$WORK/orgo.json" 2>/dev/null \
     && jq -e '(.computers | type) == "array" and .truncated != true' "$WORK/orgo.json" >/dev/null 2>&1; then
    # A needed spec that is null on a live computer is unreadable (never 0).
    ORGO_USD=$(jq -r --slurpfile need "$WORK/orgo-need.json" --argjson days "$((10#$DAYS))" '
      .computers as $all
      | [$need[0][] | .account as $a
         | [$all[] | select(.account == $a and .gone_at == null)] as $live
         | .need[] | .key as $k
         | (if $k == "computers" then ($live | length)
            else ([$live[] | (if $k == "vcpus" then .cpu else .[$k] end)]) as $v
                 | if ($v | all(type == "number")) then ($v | add // 0) else null end end) as $used
         | if $used == null then null else ([.pool - $used, 0] | max) * .price / $days end]
      | if any(. == null) then "null" else (add // 0 | tostring) end' "$WORK/orgo.json" 2>/dev/null) || ORGO_USD=null
    [ -n "$ORGO_USD" ] && [ "$ORGO_USD" != null ] && ORGOS=ok
  fi
  if [ "$ORGOS" != ok ]; then
    log "orgo capacity unreadable (recorded pool, no usable GET /api/orgo-computers); no sample, no action"
    summary; exit 0
  fi
fi

V=$(jq -rn --argjson f "$FLY_USD" --argjson o "$ORGO_USD" '($f + $o) * 100 | round / 100')
FLY2=$(jq -rn --argjson f "$FLY_USD" '$f * 100 | round / 100')
ORGO_D=not-recorded
[ "$ORGOS" = ok ] && ORGO_D=$(jq -rn --argjson o "$ORGO_USD" '$o * 100 | round / 100')

# ── 7 sample ──────────────────────────────────────────────────────────────────
jq -n --argjson v "$V" --arg d "$(jq -r --arg o "$ORGO_D" --arg m "$IDLE_MIN" --arg f "$FLY2" \
    '"fly_usd_day=\($f) orphans=\(.orphans | length) unpriced=\(.unpriced) unsettled=\(.unsettled) orgo_usd_day=\($o) idle_min=\($m)"' \
    "$WORK/orphans.json")" \
  '{agent:"quartermaster", metric:"orphan_usd_day", value:$v, detail:$d}' > "$WORK/sample.json"
if staff_metric_post "$WORK/sample.json" > "$WORK/sample.out" 2>/dev/null; then SAMPLE=ok; else SAMPLE=failed; fi

# ── 8 gate ────────────────────────────────────────────────────────────────────
L=$(staff_level quartermaster 2>/dev/null) || true
[ -n "$L" ] || L=observe
if [ "$L" != act ]; then summary; exit 0; fi

# ── 9 mode ────────────────────────────────────────────────────────────────────
# Only the exact value 0 applies; no row, an outage or any other value is dry.
DRY_ROW=$(JOBS_ALERT=0 setting_get staff.quartermaster.lever_dry_run 2>/dev/null) || DRY_ROW=""
DRY_ROW="${DRY_ROW#"${DRY_ROW%%[![:space:]]*}"}"; DRY_ROW="${DRY_ROW%"${DRY_ROW##*[![:space:]]}"}"
DRY=1; [ "$DRY_ROW" = 0 ] && DRY=0    # fallback 1 (dry); row staff.quartermaster.lever_dry_run
MODE=dry; [ "$DRY" = 0 ] && MODE=apply
HOUR=$(date -u -d "@$NOW" +%Y-%m-%dT%H)

# ── 10 candidates ─────────────────────────────────────────────────────────────
qm_candidates "$(cat "$WORK/orphans.json")" "$MAXRUN" > "$WORK/cand.tsv" 2>/dev/null || : > "$WORK/cand.tsv"
OVER=$(awk -F'\t' '$1 == "over_cap" { print $2 }' "$WORK/cand.tsv"); [[ ${OVER:-} =~ ^[0-9]+$ ]] || OVER=0

# ── 11 record before act, 12 act ──────────────────────────────────────────────
while IFS=$'\t' read -r app mid idle usd; do
  [ "$app" = over_cap ] && continue
  [ -n "$mid" ] || continue
  NC=$((NC + 1))
  jq -n --argjson dry "$([ "$DRY" = 1 ] && echo true || echo false)" --argjson m "$V" \
    --arg t "$app/$mid" --arg k "fly-stop:$MODE:$app/$mid:$HOUR" --arg d "idle_s=$idle usd_per_hour=$usd" \
    '{agent:"quartermaster", lever:"fly-stop", target:$t, dryRun:$dry, metric:"orphan_usd_day",
      metricBefore:$m, key:$k, detail:$d}' > "$WORK/action.json"
  JOBS_HTTP=""
  staff_action_post "$WORK/action.json" > "$WORK/action.out" 2>/dev/null; arc=$?
  A=-; ACTED=-
  case "$(qm_action_verdict "${JOBS_HTTP:-}" "$WORK/action.out" "$arc")" in
    run) A=recorded; NREC=$((NREC + 1)) ;;
    taken) A=taken; NTAKEN=$((NTAKEN + 1)) ;;
    *) A=failed; NFAIL=$((NFAIL + 1)) ;;
  esac
  if [ "$A" = recorded ]; then
    if [ "$DRY" = 1 ]; then
      ans=$(timeout "$ACT_TIMEOUT" "$H/bin/fly-idle-reaper.sh" act probe "$app" "$mid" 2>/dev/null </dev/null)
      ans=$(awk 'NR == 1 { print $1 }' <<<"$ans")
      case "$ans" in busy|idle|unknown) ;; *) ans=unknown ;; esac
      ACTED="probe:$ans"
    else
      timeout "$ACT_TIMEOUT" "$H/bin/fly-idle-reaper.sh" act stop "$app" "$mid" \
        "quartermaster lever: no job row for ${idle}s" > "$WORK/act.out" 2>&1 </dev/null; src=$?
      case "$src" in
        0) ACTED=stopped; NSTOP=$((NSTOP + 1)) ;;
        1) ACTED=refused; NREF=$((NREF + 1)) ;;
        *) ACTED=failed ;;
      esac
    fi
  fi
  log "$app/$mid idle_s=$idle action=$A act=$ACTED"
done < "$WORK/cand.tsv"

summary
exit 0
