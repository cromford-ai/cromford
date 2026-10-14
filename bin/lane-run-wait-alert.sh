#!/bin/bash
# bin/lane-run-wait-alert.sh — BH-6127 (BH-6047 part 4 of 5): the lane-run
# queue-wait alert. Hub only, every minute
# (cron/lanes/730-lane-run-wait-alert.cron). One tick per run, no LLM call.
#
# One run:
#   1. POST /api/lane-runs/wait-tick {box, load1}. The worker decides, in D1
#      (table lane_run_wait_alerts): a lane is over when its oldest queued run
#      waited more than the settings row lane_run.wait_alert_min (default 10)
#      minutes, and it FIRES on its 2nd consecutive over tick. load1 is the
#      first field of /proc/loadavg; Mission Control shows it as the hub load.
#   2. Per `fire` lane: bin/lane-alert.sh --id lane-run-wait:<lane> --severity
#      warn, then POST /api/lane-runs/wait-ack {lane}, which latches the lane
#      until its wait drops under the limit. A lost ack re-fires next tick, and
#      the same --id dedupes that send.
#   3. Per `resolve` lane (every fired lane whose wait drained, acked or not):
#      bin/lane-alert.sh --resolve --id lane-run-wait:<lane>.
#   A lane name that is not ^[A-Za-z0-9._-]{1,64}$ is logged and skipped.
#
# Exit 0 on every path:
#   no JOBS_URL or no HARNESS_SECRET: `not-configured`, no request, no alert.
#   the worker does not answer 2xx: ONE warn alert, id
#     lane-run-wait-alert:unreachable (the id dedupes repeats), no tick counted.
#   a good answer resolves that id.
#
# Summary line (logs/lane-run-wait-alert.log):
#   <ts> over=<n> fired=<n> acked=<n> resolved=<n> load1=<x|null>
#   | <ts> not-configured (<no-url|no-secret>)
#   | <ts> worker-failed (<http=<c>|curl_rc=<n>>)
#
# Env: LANE_RUN_LOADAVG_FILE (default /proc/loadavg) and LANE_RUN_NOW (epoch
# seconds that stamp the log line) are test seams.
#
# OFF: flags/lane-off-lane-run-wait-alert (bin/harness-ctl.sh off
# lane-run-wait-alert, read by lane_gate_or_exit).
# Registry: catalog/lanes.d/lane-run-wait-alert.json.
# Doc: docs/notes/2026-10-12-BH-6127-lane-run-metrics.md.
set -uo pipefail
H="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "$0")" && pwd)"
. "$H/bin/lib/env-path.sh" 2>/dev/null || . "$SELF/lib/env-path.sh" 2>/dev/null \
  || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }
HENV=$(harness_env_dir "$H")
# shellcheck disable=SC1091
[ -r "$HENV/global.env" ] && { set -a; . "$HENV/global.env" 2>/dev/null; set +a; }

# shellcheck disable=SC1091
. "$H/bin/lib/lane-gate.sh" 2>/dev/null || . "$SELF/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit lane-run-wait-alert
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply lane-run-wait-alert

mkdir -p "$H/logs" 2>/dev/null
LOG="$H/logs/lane-run-wait-alert.log"
stamp() {
  if [[ "${LANE_RUN_NOW:-}" =~ ^[0-9]+$ ]]; then date -u -d "@$LANE_RUN_NOW" +%FT%TZ; else date -u +%FT%TZ; fi
}
summary() { printf '%s %s\n' "$(stamp)" "$1" >> "$LOG"; }
alert() { "$SELF/lane-alert.sh" "$@" >/dev/null 2>&1 || true; }

# shellcheck source=bin/jobs-client.sh
. "$SELF/jobs-client.sh" || { summary "worker-failed (jobs-client did not load)"; exit 0; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/lrwa.XXXXXX") || { summary "worker-failed (mktemp)"; exit 0; }
trap 'rm -rf "$TMP"' EXIT

LOAD1=$(awk 'NR==1{print $1}' "${LANE_RUN_LOADAVG_FILE:-/proc/loadavg}" 2>/dev/null)
[[ "$LOAD1" =~ ^[0-9]+(\.[0-9]+)?$ ]] || LOAD1=null
BOX=$(_jobs_box_name 2>/dev/null)
[[ "$BOX" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || BOX=hub
BODY=$(jq -nc --arg b "$BOX" --argjson l "$LOAD1" '{box:$b, load1:$l}')

export JOBS_STATUS_FILE="$TMP/status"
if ! _jobs_req POST /api/lane-runs/wait-tick "$BODY" > "$TMP/tick.json" \
   || ! jq -e '(.fire|type) == "array" and (.resolve|type) == "array"' "$TMP/tick.json" >/dev/null 2>&1; then
  ST=$(cat "$TMP/status" 2>/dev/null)
  case "$ST" in
    no-url|no-secret) summary "not-configured ($ST)"; exit 0 ;;
  esac
  alert --id lane-run-wait-alert:unreachable --severity warn lane-run-wait-alert \
    "The lane-run wait tick failed (${ST:-no answer}). The queue-wait alert did not run."
  summary "worker-failed (${ST:-no answer})"
  exit 0
fi
alert --resolve --id lane-run-wait-alert:unreachable lane-run-wait-alert "The lane-run wait tick answers again."

LANE_RE='^[A-Za-z0-9._-]{1,64}$'
N=$(jq -r '.threshold_min' "$TMP/tick.json")
[[ "$N" =~ ^[0-9]+$ ]] || N="?"
OVER=$(jq -r '.over | length' "$TMP/tick.json")
FIRED=0; ACKED=0; RESOLVED=0
while IFS=$'\t' read -r lane wait_s queued; do
  [ -n "$lane" ] || continue
  if ! [[ "$lane" =~ $LANE_RE ]]; then summary "skipped unsafe lane name in fire"; continue; fi
  [[ "$wait_s" =~ ^[0-9]+$ ]] || wait_s=0
  [[ "$queued" =~ ^[0-9]+$ ]] || queued="?"
  alert --id "lane-run-wait:$lane" --severity warn lane-run-wait-alert \
    "Lane $lane: the oldest queued run waited $((wait_s / 60)) min. The limit is $N min (settings row lane_run.wait_alert_min). $queued runs are queued."
  FIRED=$((FIRED + 1))
  A=$(_jobs_req POST /api/lane-runs/wait-ack "$(jq -nc --arg l "$lane" '{lane:$l}')") \
    && [ "$(printf '%s' "$A" | jq -r '.acked' 2>/dev/null)" = 1 ] && ACKED=$((ACKED + 1))
done < <(jq -r '.fire[] | [.lane, (.wait_s|tostring), (.queued|tostring)] | @tsv' "$TMP/tick.json")
while read -r lane; do
  [ -n "$lane" ] || continue
  if ! [[ "$lane" =~ $LANE_RE ]]; then summary "skipped unsafe lane name in resolve"; continue; fi
  alert --resolve --id "lane-run-wait:$lane" lane-run-wait-alert "Lane $lane: the queue wait is under $N min again."
  RESOLVED=$((RESOLVED + 1))
done < <(jq -r '.resolve[]' "$TMP/tick.json")
summary "over=$OVER fired=$FIRED acked=$ACKED resolved=$RESOLVED load1=$LOAD1"
exit 0
