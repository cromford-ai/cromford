#!/bin/bash
# bin/fly-idle-check.sh — say so, once a day, when a Fly machine has been running
# for hours doing nothing the harness knows of (BH-4020, split child 3 of #3989).
# Hub cron, daily at 06:37Z.
#
# WHY. The 2026-10-03 cost report counted 42 machines in the org, 25 of them
# started, and nothing told anyone which of those were idle until the spend had
# already happened. vendor-spend-pull.sh prices what ran; this lane names what
# is running for no reason, while it is still running.
#
# WHAT IT DOES. Lists every app in FLY_ORG (GET /v1/apps?org_slug=), then each
# app's machines (GET /v1/apps/<app>/machines), and flags a machine when ALL of:
#   - its state is `started`;
#   - it started more than FLY_IDLE_HOURS ago (default 2) — "started" is the
#     newest start event, else updated_at; with neither it is counted as
#     age-unknown and never flagged;
#   - nothing active claims it: no state/fly-pool/<p>/<mid>.json (a pool
#     build), no state/fly/<p>.json naming it with a <p>-active.json beside it
#     (a dispatcher job), and no claimed harness-jobs queue row carrying it
#     (read once per run; an unreadable queue only removes that one reason).
# Flagged machines are ONE logs/ALERTS.log line per UTC day (marker
# state/fly-idle-check/<YYYYMMDD>, written BEFORE the alert), each with its
# hourly burn from bin/lib/fly-cost-row.sh's fly_price_per_s x 3600 — or
# `burn unpriced` when the size is unknown. At most 20 are listed, then
# `... and K more`. Apps past FLY_IDLE_MAX_APPS, or whose machines could not be
# read, are named as `partial: K apps not checked`, also when nothing was idle.
# Every run writes one line to logs/fly-idle-check.log.
#
# FAILURE. No FLY_API_TOKEN: one log line `not configured`, rc 0, no alert. A
# token with no FLY_ORG: one log line and one ALERTS line naming FLY_ORG, rc 1,
# no Fly call; the org never defaults to `personal`. The apps read failing
# (non-2xx, unparseable) or no fly-machines endpoint: one log line and one
# ALERTS line naming why, rc 1, no marker — never "0 idle".
#
# WHAT IT NEVER DOES. It sends GET requests only. It never stops, destroys or
# POSTs to a machine; the alert names app/mid so a person can. The token is
# read by name, sent only in the Authorization header and never logged.
#
# Knobs (catalog/lanes.d/fly-idle-check.json): FLY_IDLE_HOURS,
# FLY_IDLE_IGNORE_APPS (comma list of app names), FLY_IDLE_MAX_APPS,
# FLY_IDLE_HTTP_TIMEOUT, FLY_PRICES, FLY_IDLE_NOW (epoch seconds; test seam).
# Off with flags/lane-off-fly-idle-check or bin/harness-ctl.sh off fly-idle-check.
#
# Usage: bin/fly-idle-check.sh [--help]
set -uo pipefail
case "${1:-}" in -h|--help) sed -n '2,44p' "$0"; exit 0 ;; esac
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")

# >>> lane gate (BH-1165). Registry: catalog/lanes.d/fly-idle-check.json.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit fly-idle-check
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    fly-idle-check
# global.env is sourced HERE because cron does not; applied again below it so a
# settings row is not dropped by a knob the file also sets.
set -a +u; # shellcheck disable=SC1090,SC1091
. "$HENV/global.env" 2>/dev/null; set +a -u
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    fly-idle-check

LOG="$H/logs/fly-idle-check.log"
SDIR="$H/state/fly-idle-check"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
mkdir -p "$H/logs" "$H/locks" 2>/dev/null
say() { echo "$(STAMP) $*" >> "$LOG" 2>/dev/null; }
alert() { HARNESS="$H" ALERT_LINE_STAMP="$(STAMP)" "$(dirname "$0")/alert-line.sh" "[fly-idle] $*"; }

exec 9>"$H/locks/fly-idle-check.lock" || { say "cannot open locks/fly-idle-check.lock — skipped"; exit 0; }
flock -n 9 2>/dev/null || { command -v flock >/dev/null 2>&1 && exit 0; }

# Read by NAME, trimmed but not squeezed: a Fly token is "FlyV1 fm2_..." with
# a space inside it (same reader as bin/vendor-spend-pull.sh's env_get).
env_get() { # env_get <VAR_NAME> -> prints the value, or nothing
  local want="$1" f val
  case "$want" in *[!A-Z0-9_]*) return 1 ;; esac
  for f in "$HENV/global.env" "$HENV"/*.env; do
    [ -r "$f" ] || continue
    val=$(sed -n "s/^\(export \)\{0,1\}$want=//p" "$f" 2>/dev/null | head -1 \
      | tr -d "\"'" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -n "$val" ] && { printf '%s' "$val"; return 0; }
  done
  return 1
}
TOK=$(env_get FLY_API_TOKEN) || { say "not configured: FLY_API_TOKEN unset"; exit 0; }
ORG=$(env_get FLY_ORG) || {
  say "FLY_ORG unset in env/: no Fly org to check (never defaults to personal)"
  alert "FLY_ORG is not set in env/; idle Fly machines not checked. Set FLY_ORG to your Fly org."
  echo "fly-idle-check: FLY_ORG is not set" >&2
  exit 1
}

. "${HARNESS:-/root/harness}/bin/lib/endpoints.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/endpoints.sh" 2>/dev/null
if ! FLY_BASE=$(endpoint_url fly-machines 2>/dev/null); then
  say "no fly-machines endpoint (ENDPOINT_FLY_MACHINES: no env, no registry default) — nothing checked"
  alert "no fly-machines endpoint (ENDPOINT_FLY_MACHINES unset, no registry default); idle machines not checked"
  exit 1
fi

HOURS="${FLY_IDLE_HOURS:-2}"
case "$HOURS" in ''|*[!0-9]*|0) say "FLY_IDLE_HOURS='${HOURS:0:16}' is not a positive int — using 2"; HOURS=2 ;; esac
MAXAPPS="${FLY_IDLE_MAX_APPS:-60}"
case "$MAXAPPS" in ''|*[!0-9]*|0) MAXAPPS=60 ;; esac
IGNORE="${FLY_IDLE_IGNORE_APPS:-}"
HTTP_TIMEOUT="${FLY_IDLE_HTTP_TIMEOUT:-25}"
case "$HTTP_TIMEOUT" in ''|*[!0-9]*|0) HTTP_TIMEOUT=25 ;; esac
PRICES="${FLY_PRICES:-$H/catalog/fly-prices.json}"
NOW="${FLY_IDLE_NOW:-$(date -u +%s)}"
case "$NOW" in ''|*[!0-9]*) NOW=$(date -u +%s) ;; esac
LIMIT=$((HOURS * 3600))
DAY=$(date -u -d "@$NOW" +%Y%m%d)
# shellcheck source=bin/lib/fly-cost-row.sh
. "$(dirname "$0")/lib/fly-cost-row.sh" 2>/dev/null || true

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fly-idle-check.XXXXXX") || { say "mktemp failed — skipped"; exit 1; }
trap 'rm -rf "$WORK"' EXIT

# GET only: no -X, no -d. `curl` unqualified so a test stub can stand in.
api_get() { # api_get <url> <outfile> -> prints the HTTP status (000 = transport)
  local code
  : > "$2"
  code=$(curl -sS -m "$HTTP_TIMEOUT" --connect-timeout 5 \
    -H "Authorization: Bearer $TOK" -o "$2" -w '%{http_code}' "$1" 2>/dev/null)
  case "$code" in ''|*[!0-9]*) code=000 ;; esac
  printf '%s' "$code"
}

# ── apps ─────────────────────────────────────────────────────────────────────
code=$(api_get "$FLY_BASE/v1/apps?org_slug=$ORG" "$WORK/apps.json")
why=""
case "$code" in
  2??) jq -e '.apps | type == "array"' "$WORK/apps.json" >/dev/null 2>&1 || why="unparseable" ;;
  *)   why="HTTP $code" ;;
esac
if [ -n "$why" ]; then
  say "apps read failed: $why — nothing checked"
  alert "cannot read Fly apps for org $ORG: $why; idle machines not checked"
  exit 1
fi

TOTAL=0; IGNORED=0; SKIPPED=0; APP_ERR=0
: > "$WORK/apps.txt"
while IFS= read -r app; do
  [ -n "$app" ] || continue
  case ",$IGNORE," in *",$app,"*) IGNORED=$((IGNORED + 1)); continue ;; esac
  TOTAL=$((TOTAL + 1))
  if [ "$TOTAL" -gt "$MAXAPPS" ]; then SKIPPED=$((SKIPPED + 1)); continue; fi
  printf '%s\n' "$app" >> "$WORK/apps.txt"
done < <(jq -r '.apps[]?.name // empty' "$WORK/apps.json" 2>/dev/null)

# ── machines: app<TAB>mid<TAB>started_since|-<TAB>kind<TAB>cpus<TAB>mem ─────
: > "$WORK/started.tsv"
while IFS= read -r app; do
  f="$WORK/m.json"
  code=$(api_get "$FLY_BASE/v1/apps/$app/machines" "$f")
  case "$code" in 2??) : ;; *) APP_ERR=$((APP_ERR + 1)); continue ;; esac
  jq -r --arg app "$app" '
    if type == "array" then .[] else error("not an array") end
    | select(.state == "started")
    | ([.events[]? | select(.type == "start" or .status == "started") | .timestamp | numbers] | max) as $ev
    | (if $ev != null then ($ev / 1000 | floor | tostring)
       else (try (.updated_at | sub("\\.[0-9]+"; "") | fromdateiso8601 | tostring) catch "-") end) as $since
    | [$app, (.id // "-"), $since, (.guest.cpu_kind // ""), (.guest.cpus // "" | tostring),
       (.guest.memory_mb // "" | tostring)] | @tsv' "$f" >> "$WORK/started.tsv" 2>/dev/null \
    || APP_ERR=$((APP_ERR + 1))
done < "$WORK/apps.txt"

# ── what the harness says is busy ────────────────────────────────────────────
: > "$WORK/disp.txt"
for f in "$H"/state/fly/*.json; do
  [ -f "$f" ] || continue
  case "$f" in *-active.json) continue ;; esac
  [ -e "${f%.json}-active.json" ] || continue
  jq -r '.machine_id // empty' "$f" >> "$WORK/disp.txt" 2>/dev/null
done
: > "$WORK/claimed.txt"
QSTATE="read"
queue_read() {
  local JC n
  for JC in "$H/bin/jobs-client.sh" "$(dirname "$0")/jobs-client.sh"; do
    # shellcheck disable=SC1090
    [ -r "$JC" ] && [ -r "${JC%/*}/lib/jobs/req.sh" ] && { . "$JC" >/dev/null 2>&1; break; }
  done
  command -v _jobs_req >/dev/null 2>&1 || { QSTATE="unread(no jobs-client)"; return; }
  [ -n "${HARNESS_SECRET:-}" ] && [ -n "${JOBS_URL:-}" ] || { QSTATE="unread(not configured)"; return; }
  JOBS_ALERT=0 _jobs_req GET "/api/queue?status=claimed&limit=500" > "$WORK/q.json" 2>/dev/null \
    || { QSTATE="unread(http ${JOBS_HTTP:-000})"; return; }
  jq -e '.queue | type == "array"' "$WORK/q.json" >/dev/null 2>&1 || { QSTATE="unread(unparseable)"; return; }
  jq -r '.queue[]?.machine // empty' "$WORK/q.json" > "$WORK/claimed.txt" 2>/dev/null
  n=$(jq '.queue | length' "$WORK/q.json" 2>/dev/null)
  [ "${n:-0}" -ge 500 ] && QSTATE=truncated
}
queue_read

is_active() { # is_active <mid> -> 0 when a pool build, dispatcher job or queue claim holds it
  local mid="$1" f
  for f in "$H"/state/fly-pool/*/"$mid".json; do [ -e "$f" ] && return 0; done
  grep -qxF -- "$mid" "$WORK/disp.txt" && return 0
  grep -qxF -- "$mid" "$WORK/claimed.txt" && return 0
  return 1
}

# ── classify and price: burn<TAB>mid<TAB>entry ───────────────────────────────
STARTED=0; ACTIVE=0; IDLE=0; NOAGE=0; UNPRICED=0
: > "$WORK/idle.tsv"
while IFS=$'\t' read -r app mid since kind cpus mem; do
  [ -n "$app" ] || continue
  STARTED=$((STARTED + 1))
  if is_active "$mid"; then ACTIVE=$((ACTIVE + 1)); continue; fi
  case "$since" in ''|*[!0-9]*) NOAGE=$((NOAGE + 1)); continue ;; esac
  up=$((NOW - since))
  [ "$up" -gt "$LIMIT" ] || continue
  IDLE=$((IDLE + 1))
  rate=""
  command -v fly_price_per_s >/dev/null 2>&1 && rate=$(fly_price_per_s "$PRICES" "$kind" "$cpus" "$mem" 2>/dev/null | awk '{print $1}')
  if [ -n "$rate" ]; then
    burn=$(awk -v r="$rate" 'BEGIN{printf "%.2f", r*3600}'); btxt="\$$burn/h"
  else
    burn=-1; btxt="burn unpriced"; UNPRICED=$((UNPRICED + 1))
  fi
  printf '%s\t%s\t%s/%s (%s-%s/%sMB, up %dh, %s)\n' "$burn" "$mid" "$app" "$mid" \
    "${kind:-?}" "${cpus:-?}" "${mem:-?}" $((up / 3600)) "$btxt" >> "$WORK/idle.tsv"
done < "$WORK/started.tsv"

PARTIAL=0; NOTCHK=$((SKIPPED + APP_ERR))
[ "$NOTCHK" -gt 0 ] && PARTIAL="$NOTCHK apps not checked (cap $SKIPPED, errors $APP_ERR)"
SUMMARY="apps=$TOTAL ignored=$IGNORED started=$STARTED active=$ACTIVE idle=$IDLE age-unknown=$NOAGE partial=$PARTIAL queue=$QSTATE"

# ── one ALERTS line per UTC day, marker first ────────────────────────────────
TEXT=""
if [ "$IDLE" -gt 0 ]; then
  total=$(awk -F'\t' '$1 >= 0 { s += $1 } END { printf "%.2f", s }' "$WORK/idle.tsv")
  list=$(LC_ALL=C sort -t$'\t' -k1,1gr -k2,2 "$WORK/idle.tsv" | head -n 20 | cut -f3 | paste -sd ';' | sed 's/;/; /g')
  TEXT="$IDLE started machines idle >${HOURS}h, \$$total/h total"
  [ "$UNPRICED" -gt 0 ] && TEXT="$TEXT ($UNPRICED unpriced)"
  TEXT="$TEXT: $list"
  [ "$IDLE" -gt 20 ] && TEXT="$TEXT ... and $((IDLE - 20)) more"
  [ "$NOTCHK" -gt 0 ] && TEXT="$TEXT; partial: $NOTCHK apps not checked"
elif [ "$NOTCHK" -gt 0 ]; then
  TEXT="partial: $NOTCHK apps not checked, no idle machine in the rest"
fi

if [ -z "$TEXT" ]; then
  say "$SUMMARY none idle"
elif [ -e "$SDIR/$DAY" ]; then
  say "$SUMMARY already alerted"
elif mkdir -p "$SDIR" 2>/dev/null && : > "$SDIR/$DAY" 2>/dev/null; then
  alert "$TEXT"
  say "$SUMMARY alerted"
else
  say "$SUMMARY marker write failed (state/fly-idle-check/$DAY) — not alerting"
  exit 1
fi
exit 0
