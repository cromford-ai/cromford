#!/bin/bash
# bin/staff/millwright-lever.sh — the millwright staff agent's metric and its
# one lever (BH-10124, C3 of #9423). Hub only, hourly at :37
# (cron/lanes/787-staff-millwright-lever.cron). No LLM call, no GitHub call,
# no Fly call.
#
# WHY. The staff contract (BH-9187, C0) says every staff agent owns ONE metric
# and is judged by whether it moved. Millwright owns
# failed_bakes_and_broken_boxes: failed pool image bakes plus boxes with a
# broken resolv.conf, a full /tmp or a stale bin (bin/lib/millwright-read.sh).
# Its lever re-runs a failed bake ONCE per bake id (<project>:<sha12>). The
# rest is filed by the staff tick (bin/staff.sh with millwright-collect.sh) at
# level file.
#
# WHAT, in order (each step that stops writes one log line and exits 0):
#   1  load the libs; no jq, jobs client, staff-contract.sh,
#      millwright-read.sh or HARNESS_SECRET = `not-configured (<what>)`.
#   2  KILL, before any request: STAFF_ENABLED=0, then the flags staff-off-all,
#      staff-kill-all, staff-off-millwright, staff-kill-millwright =
#      `killed by <flag>`.
#   3  flock -n locks/staff-millwright-lever.lock.
#   4  GET /api/staff/agent?name=millwright: millwright must be active.
#   5  METRIC: mw_metric. Unreadable = value=unreadable, no sample, no action
#      (an unreadable count is never 0).
#   6  SAMPLE: POST /api/staff/levers/metric. A failure: sample=failed, the run
#      goes on.
#   7  GATE: act only at level act (staff_level millwright; anything else, the
#      fallback included, is no action).
#   8  CAP: GET /api/staff/levers/scorecard?agent=millwright&days=1 .actions.
#      Unreadable = cap-unreadable, no action. Room =
#      staff.millwright.bake_rerun_max_day (fallback 2) minus .actions.
#   9  Per failed bake with no retry queued, in project order, while room:
#      RE-CHECK it is still a failed bake at the same sha with no mark (else
#      skipped=<p>:fixed|queued). RECORD BEFORE ACT: POST
#      /api/staff/levers/actions key bake-rerun:<p>:<sha12>. Only a new row
#      acts; existing or 409 = taken; anything else = failed. ACT: write
#      state/fly/<p>.image-dirty with the sha (tmp file + mv -n, never over a
#      mark that appeared meanwhile). The next bin/fleet-propagate.sh tick
#      drains it as one bake under its own bake lock and debounce.
#  10  One summary line in logs/staff-millwright-lever.log:
#      level=<L> value=<n|unreadable> sample=<ok|failed|-> action=<none|
#      recorded:<n>|taken:<n>|failed:<n>|cap-reached|cap-unreadable> marks=<n>
#      detail=<..> [skipped=<p>:<why>,..]
#
# KNOBS (settings rows): staff.millwright.level (observe),
# staff.millwright.bake_rerun_max_day (2). The read knobs are lib rows
# lib.staff-millwright.* (catalog/lanes.d/_lib.staff-millwright.json). Env
# STAFF_ENABLED (0 = off). Seed:
# worker/jobs/schema.d/202611252036-bh-10124-millwright-lever.sql.
#
# EXIT. 0 every run that finished; 2 bad arguments.
# Test seams (HARNESS_TEST_SANDBOX=1 only): MWL_NOW (epoch), MW_FIXTURE (a file
# sourced after the libs); MWL_LIB_ONLY=1 loads mwl_action_verdict and returns.
# OFF: flags/lane-off-staff-millwright-lever (bin/harness-ctl.sh off
# staff-millwright-lever), or any staff kill flag above.
# Registry: catalog/lanes.d/staff-millwright-lever.json.
# Doc: docs/notes/2026-11-25-BH-10124-millwright.md.
set -uo pipefail

# mwl_action_verdict <http-code> <body-file> <rc> — the answer of
# POST /api/staff/levers/actions -> run | taken | failed. Only a new row is
# run (D9): existing or 409 is the bake id already taken, anything else fails
# closed.
mwl_action_verdict() {
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

[ "${MWL_LIB_ONLY:-}" = 1 ] && return 0 2>/dev/null

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) sed -n '2,58p' "$0"; exit 0 ;;
    *) echo "millwright-lever: unknown argument '$1'" >&2; exit 2 ;;
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
LOG="$H/logs/staff-millwright-lever.log"
NOW=$(date -u +%s)
[ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [[ ${MWL_NOW:-} =~ ^[0-9]+$ ]] && NOW=$MWL_NOW
TS=$(date -u -d "@$NOW" +%FT%TZ)
log() { printf '%s %s\n' "$TS" "$*" >> "$LOG"; }

# shellcheck disable=SC1091
. "$H/bin/lib/lane-gate.sh" 2>/dev/null || . "$LIBD/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit staff-millwright-lever
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply staff-millwright-lever

# ── 1 libs ────────────────────────────────────────────────────────────────────
command -v jq >/dev/null 2>&1 || { log "not-configured (no jq)"; exit 0; }
# shellcheck source=bin/jobs-client.sh
. "$H/bin/jobs-client.sh" 2>/dev/null || . "$LIBD/jobs-client.sh" 2>/dev/null
# shellcheck source=bin/lib/staff-contract.sh
. "$H/bin/lib/staff-contract.sh" 2>/dev/null || . "$LIBD/lib/staff-contract.sh" 2>/dev/null
# shellcheck source=bin/lib/millwright-read.sh
. "$H/bin/lib/millwright-read.sh" 2>/dev/null || . "$LIBD/lib/millwright-read.sh" 2>/dev/null
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [ -n "${MW_FIXTURE:-}" ]; then
  # shellcheck disable=SC1090
  . "$MW_FIXTURE"
fi
for fn in _jobs_req _jobs_req_file flag_active setting_get; do
  command -v "$fn" >/dev/null 2>&1 || { log "not-configured (no bin/jobs-client.sh: $fn)"; exit 0; }
done
command -v staff_action_post >/dev/null 2>&1 || { log "not-configured (no bin/lib/staff-contract.sh)"; exit 0; }
command -v mw_metric >/dev/null 2>&1 || { log "not-configured (no bin/lib/millwright-read.sh)"; exit 0; }
[ -n "${HARNESS_SECRET:-}" ] || { log "not-configured (no HARNESS_SECRET)"; exit 0; }

# ── 2 kill, before any request ────────────────────────────────────────────────
[ "${STAFF_ENABLED:-1}" = 0 ] && { log "killed by STAFF_ENABLED=0"; exit 0; }
for f in staff-off-all staff-kill-all staff-off-millwright staff-kill-millwright; do
  if flag_active "$f"; then log "killed by $f"; exit 0; fi
done

# ── 3 lock ────────────────────────────────────────────────────────────────────
exec 9>"$H/locks/staff-millwright-lever.lock" || { log "lock file unwritable - not running"; exit 0; }
flock -n 9 || { log "another millwright-lever run is running"; exit 0; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/mw-lever.XXXXXX") || { log "worker-failed (mktemp)"; exit 0; }
trap 'rm -rf "$WORK"' EXIT
command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply staff-millwright

# ── 4 roster ──────────────────────────────────────────────────────────────────
row=$(_jobs_req GET "/api/staff/agent?name=millwright" 9>&-); rc=$?
[ "$rc" = 0 ] || { log "roster row unreadable or absent (rc=$rc); nothing ran"; exit 0; }
[ "$(jq -r '.agent.status // ""' <<<"$row" 2>/dev/null)" = active ] || { log "millwright is not active on the roster; nothing ran"; exit 0; }

L=- V=unreadable SAMPLE=- ACTION=none MARKS=0 DETAIL=- SKIPPED=""
summary() { log "level=$L value=$V sample=$SAMPLE action=$ACTION marks=$MARKS detail=$DETAIL${SKIPPED:+ skipped=${SKIPPED#,}}"; }

# ── 5 metric ──────────────────────────────────────────────────────────────────
MW_NOW="$NOW" mw_metric "$H" "$WORK/m" > "$WORK/metric.json" 9>&-; mrc=$?
if [ "$mrc" != 0 ] || ! V=$(jq -er '.value | select(type == "number" and . >= 0 and . == floor) | tostring' "$WORK/metric.json" 2>/dev/null); then
  V=unreadable
  log "metric unreadable (rc=$mrc $(cat "$WORK/m/counts" 2>/dev/null)); no sample, no action"
  summary; exit 0
fi
DETAIL=$(jq -r '"bakes=\(.bakes) boxes=\(.boxes) resolv=\(.resolv) tmp=\(.tmp) stale=\(.stale) unreachable=\(.unreachable)"' "$WORK/metric.json")

# ── 6 sample ──────────────────────────────────────────────────────────────────
jq -n --argjson v "$V" --arg d "$DETAIL" \
  '{agent:"millwright", metric:"failed_bakes_and_broken_boxes", value:$v, detail:$d}' > "$WORK/sample.json"
if staff_metric_post "$WORK/sample.json" > "$WORK/sample.out" 2>/dev/null 9>&-; then SAMPLE=ok; else SAMPLE=failed; fi

# ── 7 gate ────────────────────────────────────────────────────────────────────
L=$(staff_level millwright 2>/dev/null) || true
[ -n "$L" ] || L=observe
[ "$L" = act ] || { summary; exit 0; }

# ── 8 cap ─────────────────────────────────────────────────────────────────────
MAXD=$(staff_knob millwright bake_rerun_max_day 2)   # fallback 2; row staff.millwright.bake_rerun_max_day
sc=$(JOBS_ALERT=0 _jobs_req GET "/api/staff/levers/scorecard?agent=millwright&days=1" 9>&-) || sc=""
DONE=$(jq -er '.actions | select(type == "number" and . >= 0 and . == floor) | tostring' <<<"$sc" 2>/dev/null) || DONE=""
if ! [[ $DONE =~ ^[0-9]+$ ]]; then ACTION=cap-unreadable; summary; exit 0; fi
ROOM=$((MAXD - DONE))

# ── 9 re-check, record before act, act ───────────────────────────────────────
NREC=0 NTAKEN=0 NFAIL=0 CAPPED=0
while IFS=$'\t' read -r p sha _at reason q; do
  [ "$q" = 0 ] || continue
  if [ "$ROOM" -le 0 ]; then CAPPED=1; break; fi
  # Still needed? Read again: the same sha still failed, and no mark.
  MW_NOW="$NOW" mw_bakes "$H" > "$WORK/recheck.tsv" 2>/dev/null || : > "$WORK/recheck.tsv"
  cur=$(awk -F'\t' -v p="$p" '$1 == p { print $2 "\t" $5 }' "$WORK/recheck.tsv")
  if [ "$cur" != "$sha"$'\t'0 ]; then
    why=fixed; [ "${cur#*$'\t'}" = 1 ] && [ "${cur%%$'\t'*}" = "$sha" ] && why=queued
    SKIPPED="$SKIPPED,$p:$why"; continue
  fi
  jq -n --argjson m "$V" --arg p "$p" --arg k "bake-rerun:$p:${sha:0:12}" --arg d "reason=$reason" \
    '{agent:"millwright", lever:"bake-rerun", target:$p, dryRun:false, metric:"failed_bakes_and_broken_boxes",
      metricBefore:$m, key:$k, detail:$d}' > "$WORK/action.json"
  JOBS_HTTP=""
  staff_action_post "$WORK/action.json" > "$WORK/action.out" 2>/dev/null 9>&-; arc=$?
  case "$(mwl_action_verdict "${JOBS_HTTP:-}" "$WORK/action.out" "$arc")" in
    run) ;;
    taken) NTAKEN=$((NTAKEN+1)); continue ;;
    *) NFAIL=$((NFAIL+1)); log "lever action for $p not recorded (rc=$arc HTTP ${JOBS_HTTP:-none}); no re-run"; continue ;;
  esac
  ROOM=$((ROOM-1)); NREC=$((NREC+1))
  M="$H/state/fly/$p.image-dirty"
  if mkdir -p "$H/state/fly" 2>/dev/null && printf '%s\n' "$sha" > "$M.mwl.$$" 2>/dev/null \
     && mv -n "$M.mwl.$$" "$M" 2>/dev/null && [ "$(head -1 "$M" 2>/dev/null)" = "$sha" ] && [ ! -e "$M.mwl.$$" ]; then
    MARKS=$((MARKS+1))
  else
    rm -f "$M.mwl.$$" 2>/dev/null
    log "mark=failed for $p at ${sha:0:12}: the action row is recorded, the re-run is not queued"
  fi
done < "$WORK/m/bakes.tsv"

if [ "$NREC" -gt 0 ]; then ACTION="recorded:$NREC"
elif [ "$NTAKEN" -gt 0 ]; then ACTION="taken:$NTAKEN"
elif [ "$NFAIL" -gt 0 ]; then ACTION="failed:$NFAIL"
elif [ "$CAPPED" = 1 ]; then ACTION=cap-reached
fi
summary
exit 0
