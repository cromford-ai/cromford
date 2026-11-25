#!/bin/bash
# bin/staff/watchman-metric.sh — Watchman's metric, live_unrotated_secrets
# (BH-9423, watchman v2). Hub only, hourly at :52
# (cron/lanes/782-staff-watchman-metric.cron). No LLM call, no GitHub call,
# no lever action.
#
# WHY. The staff contract (BH-9187, C0) says every staff agent owns ONE metric
# and is judged by whether it moved. Watchman owns live_unrotated_secrets
# (settings row staff.watchman.metric). The collector (bin/staff/watchman-
# collect.sh) makes no request on a quiet tick, so the metric is its own lane.
#
# METRIC = A + B:
#   A  the locations in state/staff/watchman/leaks/*.jsonl and base/*.jsonl
#      that are NOT allowlisted (bin/lib/watchman-allow.sh, the collector's
#      own knobs) and are live: the agent-core fingerprint of the location is
#      an open watchman finding (GET /api/staff/findings?agent=watchman; a row
#      with `state` off is not open), OR the collector never printed it (no
#      nonzero time in state/staff/watchman/printed.tsv). A printed location
#      whose finding is not open is closed: rotated, rejected or noise.
#   B  the credentials in catalog/staff-rotations.d/*.json past their due date
#      + 1 day (the collector's rotation-due rule), valid files only.
#
# WHAT, in order (each step that stops writes one log line and exits 0):
#   1  load the libs; no jq, node, jobs client, staff-contract.sh or
#      watchman-allow.sh = `not-configured (<what>)`.
#   2  KILL, before any request: STAFF_ENABLED=0, then the flags staff-off-all,
#      staff-kill-all, staff-off-watchman, staff-kill-watchman = `killed by <flag>`.
#   3  flock -n locks/staff-watchman-metric.lock.
#   4  GET /api/staff/agent?name=watchman: watchman must be active.
#   5  GET /api/staff/findings?agent=watchman, ONCE. A failed read, an answer
#      that is not a list, or `truncated` = live_unrotated_secrets=unreadable,
#      no sample (an unreadable count is never 0).
#   6  ONE node call fingerprints every non-allowlisted location.
#   7  SAMPLE: POST /api/staff/levers/metric {agent:watchman,
#      metric:live_unrotated_secrets, value, detail}. That call settles
#      watchman's due lever actions (C0).
#
# WRITES. One line per run in logs/staff-watchman-metric.log:
#   <ts> live_unrotated_secrets=<n> history=<A> rotation=<B> allowlisted=<n> sample=<ok|failed>
# `sample=ok` only after staff_metric_post returns rc 0. The row:
# staff_metric_samples through the C0 route. No state/ file.
#
# EXIT. 0 every run that finished; 2 bad arguments.
# Env (sandbox test seams, HARNESS_TEST_SANDBOX=1 only): WM_METRIC_NOW (epoch
#   seconds), WM_METRIC_FIXTURE (a file sourced after the libs),
#   WM_METRIC_LIB_ONLY=1 (load wmm_rotation_due and return).
# OFF: flags/lane-off-staff-watchman-metric (bin/harness-ctl.sh off
#   staff-watchman-metric), or any staff kill flag above. Registry:
#   catalog/lanes.d/staff-watchman-metric.json.
# Doc: docs/notes/2026-11-12-BH-9423-watchman-v2.md.
set -uo pipefail

# wmm_rotation_due <register rows file> <now epoch> — the count of rows
# ({id, where, owner, due}, from wm_register_read) with now >= due + 1 day.
wmm_rotation_due() {
  local f="${1:-}" now="${2:-}"
  [[ $now =~ ^[0-9]+$ ]] || return 1
  [ -s "$f" ] || { printf '0\n'; return 0; }
  jq -s --argjson now "$now" '[.[] | select((.due + "T00:00:00Z" | fromdateiso8601) + 86400 <= $now)] | length' "$f"
}

[ "${WM_METRIC_LIB_ONLY:-}" = 1 ] && return 0 2>/dev/null

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) sed -n '2,53p' "$0"; exit 0 ;;
    *) echo "watchman-metric: unknown argument '$1'" >&2; exit 2 ;;
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
LOG="$H/logs/staff-watchman-metric.log"
NOW=$(date -u +%s)
[ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [[ ${WM_METRIC_NOW:-} =~ ^[0-9]+$ ]] && NOW=$WM_METRIC_NOW
TS=$(date -u -d "@$NOW" +%FT%TZ)
log() { printf '%s %s\n' "$TS" "$*" >> "$LOG"; }

# shellcheck disable=SC1091
. "$H/bin/lib/lane-gate.sh" 2>/dev/null || . "$LIBD/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit staff-watchman-metric
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply staff-watchman-metric
# The collector's own knobs: the allowlist and the repos root.
command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply staff-watchman

# ── 1 libs ────────────────────────────────────────────────────────────────────
command -v jq >/dev/null 2>&1 || { log "not-configured (no jq)"; exit 0; }
command -v node >/dev/null 2>&1 || { log "not-configured (no node)"; exit 0; }
# shellcheck source=bin/jobs-client.sh
. "$H/bin/jobs-client.sh" 2>/dev/null || . "$LIBD/jobs-client.sh" 2>/dev/null
# shellcheck source=bin/lib/staff-contract.sh
. "$H/bin/lib/staff-contract.sh" 2>/dev/null || . "$LIBD/lib/staff-contract.sh" 2>/dev/null
# shellcheck source=bin/lib/watchman-allow.sh
. "$H/bin/lib/watchman-allow.sh" 2>/dev/null || . "$LIBD/lib/watchman-allow.sh" 2>/dev/null
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [ -n "${WM_METRIC_FIXTURE:-}" ]; then
  # shellcheck disable=SC1090
  . "$WM_METRIC_FIXTURE"
fi
for fn in _jobs_req _jobs_req_file flag_active; do
  command -v "$fn" >/dev/null 2>&1 || { log "not-configured (no bin/jobs-client.sh: $fn)"; exit 0; }
done
command -v staff_metric_post >/dev/null 2>&1 || { log "not-configured (no bin/lib/staff-contract.sh)"; exit 0; }
command -v wm_allow_split >/dev/null 2>&1 || { log "not-configured (no bin/lib/watchman-allow.sh)"; exit 0; }
CORE="$LIBD/../agent-core/src/index.js"
[ -r "$CORE" ] || { log "not-configured (no agent-core)"; exit 0; }

# ── 2 kill, before any request ────────────────────────────────────────────────
[ "${STAFF_ENABLED:-1}" = 0 ] && { log "killed by STAFF_ENABLED=0"; exit 0; }
for f in staff-off-all staff-kill-all staff-off-watchman staff-kill-watchman; do
  if flag_active "$f"; then log "killed by $f"; exit 0; fi
done

# ── 3 lock ────────────────────────────────────────────────────────────────────
exec 9>"$H/locks/staff-watchman-metric.lock" || { log "lock file unwritable - not running"; exit 0; }
flock -n 9 || { log "another watchman-metric run is running"; exit 0; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/watchman-metric.XXXXXX") || { log "worker-failed (mktemp)"; exit 0; }
trap 'rm -rf "$WORK"' EXIT

# ── 4 roster ──────────────────────────────────────────────────────────────────
row=$(_jobs_req GET "/api/staff/agent?name=watchman"); rc=$?
[ "$rc" = 0 ] || { log "roster row unreadable or absent (rc=$rc); nothing ran"; exit 0; }
[ "$(jq -r '.agent.status // ""' <<<"$row" 2>/dev/null)" = active ] || { log "watchman is not active on the roster; nothing ran"; exit 0; }

# ── 5 the open findings, once ─────────────────────────────────────────────────
WHY=""
if ! _jobs_req GET "/api/staff/findings?agent=watchman" > "$WORK/findings.json" 2>/dev/null; then
  WHY="read failed"
elif ! jq -e '.findings | type == "array"' "$WORK/findings.json" >/dev/null 2>&1; then
  WHY="not a list"
elif [ "$(jq -r '.truncated // false' "$WORK/findings.json")" != false ]; then
  WHY="truncated"
fi
if [ -n "$WHY" ]; then
  log "live_unrotated_secrets=unreadable (findings list $WHY); no sample"
  exit 0
fi
jq -r '.findings[] | select(type == "object" and (.state // "") != "off") | .fingerprint // empty' "$WORK/findings.json" \
  | LC_ALL=C sort -u > "$WORK/open"

# ── 6 history: non-allowlisted, live locations ────────────────────────────────
WMS="$H/state/staff/watchman"
ROOT="${WM_REPOS_ROOT:-/root/repos}"
wm_allow_load 2> "$WORK/allow.warn"
while IFS= read -r l; do log "${l#watchman-allow: }"; done < "$WORK/allow.warn"
: > "$WORK/locs"
for cf in "$WMS/leaks"/*.jsonl "$WMS/base"/*.jsonl; do
  [ -s "$cf" ] && cat "$cf" >> "$WORK/locs"
done
LC_ALL=C sort -u "$WORK/locs" -o "$WORK/locs"
wm_allow_split "$WORK/locs" "$WORK/hits" "$ROOT"
ALLOWED=$((WM_ALLOW_N_PATH + WM_ALLOW_N_DUMMY))
A=0
if [ -s "$WORK/hits" ]; then
  # One node call: the fingerprint the staff lane claims each line under.
  if ! node --input-type=module -e "
    import { readFileSync } from 'node:fs';
    import { fingerprint } from '$CORE';
    for (const l of readFileSync(process.argv[1], 'utf8').split('\n')) if (l) console.log(fingerprint(JSON.parse(l)));
  " "$WORK/hits" > "$WORK/fps" 2>/dev/null || [ "$(grep -c . "$WORK/fps")" != "$(grep -c . "$WORK/hits")" ]; then
    log "live_unrotated_secrets=unreadable (fingerprint failed); no sample"
    exit 0
  fi
  # The printed key is the sha256 of the line, as the collector writes it.
  while IFS= read -r it; do printf '%s' "$it" | sha256sum | cut -c1-64; done < "$WORK/hits" > "$WORK/keys"
  A=$(paste -d'\t' "$WORK/fps" "$WORK/keys" | awk -F'\t' -v op="$WORK/open" -v pr="$WMS/printed.tsv" '
    BEGIN {
      while ((getline l < op) > 0) open[l] = 1
      while ((getline l < pr) > 0) { split(l, a, "\t"); if (a[2] ~ /^[0-9]+$/ && a[2] + 0 > 0) printed[a[1]] = 1 }
    }
    ($1 in open) || !($2 in printed) { n++ }
    END { print n + 0 }')
fi

# ── rotation register ─────────────────────────────────────────────────────────
wm_register_read "$H/catalog/staff-rotations.d" "$WORK/reg" 2> "$WORK/reg.bad"
while IFS= read -r l; do log "register $l; not counted"; done < "$WORK/reg.bad"
B=$(wmm_rotation_due "$WORK/reg" "$NOW") || B=""
[[ $B =~ ^[0-9]+$ ]] || { log "live_unrotated_secrets=unreadable (register count failed); no sample"; exit 0; }

# ── 7 sample ──────────────────────────────────────────────────────────────────
V=$((A + B))
DETAIL="history=$A rotation=$B allowlisted=$ALLOWED"
jq -n --argjson v "$V" --arg d "$DETAIL" \
  '{agent:"watchman", metric:"live_unrotated_secrets", value:$v, detail:$d}' > "$WORK/sample.json"
if staff_metric_post "$WORK/sample.json" > "$WORK/sample.out" 2>/dev/null; then SAMPLE=ok; else SAMPLE=failed; fi
log "live_unrotated_secrets=$V $DETAIL sample=$SAMPLE"
exit 0
