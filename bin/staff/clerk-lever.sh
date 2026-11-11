#!/bin/bash
# bin/staff/clerk-lever.sh — the clerk staff agent's metric and its one lever
# (BH-9420, C2 of #9187). Hub only, hourly at :47
# (cron/lanes/780-staff-clerk-lever.cron). No LLM call, no GitHub call.
#
# WHY. The staff contract (BH-9187, C0) says every staff agent owns ONE metric
# and is judged by whether it moved. The clerk owns needs_count, the NEEDS
# count Mission Control NOW shows (target: below staff.clerk.target, 300). Its
# lever is the #9117 NEEDS sweep (bin/needs-sweep.sh), the same rules, run
# through the contract: one ledger row per action, and a later metric sample
# decides whether the count fell.
#
# WHAT, in order (each step that stops writes one log line and exits 0):
#   1  load the libs; no jobs client, staff-contract.sh, console-pages.sh,
#      HARNESS_SECRET or jq = `not-configured (<what>)`.
#   2  KILL, before any request: STAFF_ENABLED=0, then the flags staff-off-all,
#      staff-kill-all, staff-off-clerk, staff-kill-clerk = `killed by <flag>`.
#   3  flock -n locks/staff-clerk-lever.lock.
#   4  GET /api/staff/agent?name=clerk: the clerk must be active.
#   5  METRIC: GET <console_pages_url>/api/needs-sweep/count (bearer on stdin).
#      .needs.total must be a whole number; else needs=unreadable, no sample,
#      no action (an unreadable count is never 0).
#   6  SAMPLE: POST /api/staff/levers/metric {agent:clerk, metric:needs_count}.
#      That call settles the clerk's due actions (C0). A failure: sample=failed,
#      the run goes on.
#   7  GATE: act only at level act (staff_level clerk; anything else is
#      observe) and NEEDS >= staff.clerk.target.
#   8  MODE: dry unless the sweep's own row console.needs.sweep_dry_run is 0.
#   9  RECORD BEFORE ACT: POST /api/staff/levers/actions with
#      key needs-sweep:<window start>; the window is
#      staff.clerk.lever_every_hours long. Only a new row runs the sweep;
#      existing or 409 = action=window-taken; anything else = action=failed.
#      So the sweep never runs without its ledger row.
#  10  ACT: NS_TAG=clerk:<action key 12> bin/needs-sweep.sh [--dry-run]. The
#      sweep's own caps, lock and timeout rows bound it.
#
# KNOBS (settings rows): staff.clerk.level (observe), staff.clerk.target (300),
# staff.clerk.lever_every_hours (6), console.needs.sweep_dry_run (1 = dry),
# console.needs.sweep_http_timeout_s (30, the /count read). Env STAFF_ENABLED
# (0 = off). Seed: worker/jobs/schema.d/202611102231-bh-9420-clerk-lever.sql.
#
# WRITES. One summary line per run in logs/staff-clerk-lever.log:
#   <ts> level=<L> needs=<M> target=<T> sample=<ok|failed> action=<none|recorded|
#   window-taken|failed> dry=<0|1|-> sweep_rc=<rc|-> sweep=<sweep summary|->
# The rows: staff_metric_samples and staff_lever_actions through the C0 routes.
# The sweep writes its own log and ledger row (tagged). No state/ file.
#
# EXIT. 0 every run that finished; 2 bad arguments.
# Env (sandbox test seams, HARNESS_TEST_SANDBOX=1 only for the clock):
#   CLERK_NOW (epoch seconds), CLERK_LIB_ONLY=1 (load clerk_action_verdict
#   and return).
# OFF: flags/lane-off-staff-clerk-lever (bin/harness-ctl.sh off staff-clerk-lever),
#   or any staff kill flag above. Registry: catalog/lanes.d/staff-clerk-lever.json.
# Doc: docs/notes/2026-11-10-BH-9420-clerk-lever.md.
set -uo pipefail

# clerk_action_verdict <http-code> <body-file> <rc> — the answer of
# POST /api/staff/levers/actions -> run | window-taken | failed. Only a new
# row is run (D9): existing or 409 is the window's action already taken, and
# anything else fails closed.
clerk_action_verdict() {
  local code="${1:-}" f="${2:-}" rc="${3:-1}"
  if [ "$code" = 409 ]; then echo window-taken; return 0; fi
  if [ "$rc" = 0 ] && [[ "$code" == 2?? ]] && [ -s "$f" ]; then
    if jq -e '.ok == true and .existing == true' "$f" >/dev/null 2>&1; then echo window-taken; return 0; fi
    if jq -e '.ok == true and (.existing // false) == false and (.action.action_key | type) == "string"' "$f" >/dev/null 2>&1; then
      echo run; return 0
    fi
  fi
  echo failed
}

[ "${CLERK_LIB_ONLY:-}" = 1 ] && return 0 2>/dev/null

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) sed -n '2,55p' "$0"; exit 0 ;;
    *) echo "clerk-lever: unknown argument '$1'" >&2; exit 2 ;;
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
LOG="$H/logs/staff-clerk-lever.log"
NOW=$(date -u +%s)
[ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [[ ${CLERK_NOW:-} =~ ^[0-9]+$ ]] && NOW=$CLERK_NOW
TS=$(date -u -d "@$NOW" +%FT%TZ)
log() { printf '%s %s\n' "$TS" "$*" >> "$LOG"; }

# shellcheck disable=SC1091
. "$H/bin/lib/lane-gate.sh" 2>/dev/null || . "$LIBD/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit staff-clerk-lever
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply staff-clerk-lever

# ── 1 libs ────────────────────────────────────────────────────────────────────
command -v jq >/dev/null 2>&1 || { log "not-configured (no jq)"; exit 0; }
# shellcheck source=bin/jobs-client.sh
. "$H/bin/jobs-client.sh" 2>/dev/null || . "$LIBD/jobs-client.sh" 2>/dev/null
# shellcheck source=bin/lib/staff-contract.sh
. "$H/bin/lib/staff-contract.sh" 2>/dev/null || . "$LIBD/lib/staff-contract.sh" 2>/dev/null
# shellcheck source=bin/lib/console-pages.sh
. "$H/bin/lib/console-pages.sh" 2>/dev/null || . "$LIBD/lib/console-pages.sh" 2>/dev/null
for fn in _jobs_req _jobs_req_file flag_active setting_get; do
  command -v "$fn" >/dev/null 2>&1 || { log "not-configured (no bin/jobs-client.sh: $fn)"; exit 0; }
done
command -v staff_action_post >/dev/null 2>&1 || { log "not-configured (no bin/lib/staff-contract.sh)"; exit 0; }
command -v console_pages_url >/dev/null 2>&1 || { log "not-configured (no bin/lib/console-pages.sh)"; exit 0; }
[ -n "${HARNESS_SECRET:-}" ] || { log "not-configured (no HARNESS_SECRET)"; exit 0; }

# ── 2 kill, before any request ────────────────────────────────────────────────
[ "${STAFF_ENABLED:-1}" = 0 ] && { log "killed by STAFF_ENABLED=0"; exit 0; }
for f in staff-off-all staff-kill-all staff-off-clerk staff-kill-clerk; do
  if flag_active "$f"; then log "killed by $f"; exit 0; fi
done

# ── 3 lock ────────────────────────────────────────────────────────────────────
exec 9>"$H/locks/staff-clerk-lever.lock" || { log "lock file unwritable - not running"; exit 0; }
flock -n 9 || { log "another clerk-lever run is running"; exit 0; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/clerk-lever.XXXXXX") || { log "worker-failed (mktemp)"; exit 0; }
trap 'rm -rf "$WORK"' EXIT

# ── 4 roster ──────────────────────────────────────────────────────────────────
row=$(_jobs_req GET "/api/staff/agent?name=clerk"); rc=$?
[ "$rc" = 0 ] || { log "roster row unreadable or absent (rc=$rc); nothing ran"; exit 0; }
[ "$(jq -r '.agent.status // ""' <<<"$row" 2>/dev/null)" = active ] || { log "clerk is not active on the roster; nothing ran"; exit 0; }

L=- M=unreadable T=- SAMPLE=none ACTION=none DRY=- SWEEP_RC=- SWEEP=-
summary() { log "level=$L needs=$M target=$T sample=$SAMPLE action=$ACTION dry=$DRY sweep_rc=$SWEEP_RC sweep=$SWEEP"; }

# ── 5 metric ──────────────────────────────────────────────────────────────────
# fallback 30; row console.needs.sweep_http_timeout_s (the sweep's own console timeout)
HTTP_TIMEOUT=$(JOBS_ALERT=0 setting_get console.needs.sweep_http_timeout_s 2>/dev/null) || HTTP_TIMEOUT=""
[[ $HTTP_TIMEOUT =~ ^[0-9]+$ ]] && [ "$((10#$HTTP_TIMEOUT))" -gt 0 ] || HTTP_TIMEOUT=30
code=$(printf 'Authorization: Bearer %s\n' "$HARNESS_SECRET" \
  | curl -sS --max-time "$HTTP_TIMEOUT" -H @- -o "$WORK/count.json" -w '%{http_code}' \
      "$(console_pages_url)/api/needs-sweep/count" 2>/dev/null) || code="${code:-000}"
if [ "$code" = 200 ]; then
  M=$(jq -r '.needs.total | if type == "number" and . >= 0 and . == floor then tostring else empty end' "$WORK/count.json" 2>/dev/null) || M=""
fi
if ! [[ ${M:-} =~ ^[0-9]+$ ]]; then
  M=unreadable
  log "needs count unreadable (HTTP ${code:-000}); no sample, no action"
  summary; exit 0
fi

# ── 6 sample ──────────────────────────────────────────────────────────────────
jq -n --argjson v "$M" \
  --arg d "$(jq -r '.needs | "alerts=\(.alerts) builds=\(.builds) commands=\(.commands) proposals=\(.proposals)"' "$WORK/count.json")" \
  '{agent:"clerk", metric:"needs_count", value:$v, detail:$d}' > "$WORK/sample.json"
if staff_metric_post "$WORK/sample.json" > "$WORK/sample.out" 2>/dev/null; then SAMPLE=ok; else SAMPLE=failed; fi

# ── 7 gate ────────────────────────────────────────────────────────────────────
L=$(staff_level clerk 2>/dev/null) || true
[ -n "$L" ] || L=observe
T=$(staff_knob clerk target 300)               # fallback 300; row staff.clerk.target
W=$(staff_knob clerk lever_every_hours 6)      # fallback 6; row staff.clerk.lever_every_hours
if [ "$L" != act ] || [ "$M" -lt "$T" ]; then summary; exit 0; fi

# ── 8 mode ────────────────────────────────────────────────────────────────────
# The sweep's own dry row; a missing, non-numeric or unreadable value is dry.
DRY_ROW=$(JOBS_ALERT=0 setting_get console.needs.sweep_dry_run 2>/dev/null) || DRY_ROW=""
[[ $DRY_ROW =~ ^[0-9]+$ ]] || DRY_ROW=1      # fallback 1; row console.needs.sweep_dry_run
DRY=1; [ "$DRY_ROW" = 0 ] && DRY=0
MODE=dry; [ "$DRY" = 0 ] && MODE=apply

# ── 9 record before act ───────────────────────────────────────────────────────
WS=$(date -u -d "@$((NOW - NOW % (W * 3600)))" +%FT%TZ)
jq -n --argjson dry "$([ "$DRY" = 1 ] && echo true || echo false)" --argjson m "$M" \
  --arg k "needs-sweep:$WS" --arg d "needs-sweep $MODE window $WS" \
  '{agent:"clerk", lever:"needs-sweep", target:"console NEEDS", dryRun:$dry, metric:"needs_count",
    metricBefore:$m, key:$k, detail:$d}' > "$WORK/action.json"
JOBS_HTTP=""
staff_action_post "$WORK/action.json" > "$WORK/action.out" 2>/dev/null; arc=$?
case "$(clerk_action_verdict "${JOBS_HTTP:-}" "$WORK/action.out" "$arc")" in
  run) ACTION=recorded ;;
  window-taken) ACTION=window-taken; summary; exit 0 ;;
  *) ACTION=failed; log "lever action not recorded (rc=$arc HTTP ${JOBS_HTTP:-none}); no sweep"; summary; exit 0 ;;
esac
AKEY=$(jq -r '.action.action_key' "$WORK/action.out")

# ── 10 act ────────────────────────────────────────────────────────────────────
ARGS=(); [ "$DRY" = 1 ] && ARGS=(--dry-run)
NS_TAG="clerk:${AKEY:0:12}" "$H/bin/needs-sweep.sh" "${ARGS[@]}" > "$WORK/sweep.out" 2>&1; SWEEP_RC=$?
SWEEP=$(tail -1 "$WORK/sweep.out" | tr -d '\r' | head -c 600)
[ -n "$SWEEP" ] || SWEEP=-
summary
exit 0
