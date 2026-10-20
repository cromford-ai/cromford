#!/bin/bash
# bin/unblock-metrics.sh — BH-7728 (UNB-6): the Tackler metrics lane. A hub
# lane with no model call.
#
#   unblock-metrics.sh overrides   one override pass (bin/lib/unblock/override.sh uo_scan)
#   unblock-metrics.sh daily       one metrics line per active project
#   unblock-metrics.sh tick        the cron line, hourly at :17: overrides, then
#                                  daily once per UTC day, then the weekly report
#
# OVERRIDES: a person's reversal of a Tackler act inside UNBLOCK_OVERRIDE_WINDOW_H
# demotes the rule's staff class to ask_first and stamps override_* on the
# ledger row (see the header of bin/lib/unblock/override.sh).
#
# DAILY: for each project whose settings row unblock.project.<p>.mode is shadow
# or act, GET /api/unblock/metrics?project=<p>&days=7&to=<today>, then one line
# in logs/unblock-metrics.log (and on stdout):
#   tackler <p> <yesterday>: decisions <n>, would <n>, escalations <n>,
#     overrides <n>, stall median <m>m p95 <m>m; 7d decisions/day <x>,
#     escalations/day <y>, override rate <r>%, stall median <m>m p95 <m>m
# A metric with no value prints n/a. An unreadable project is one line
# `tackler <p>: metrics unreadable`; the other projects are still written.
#
# TICK: the daily step runs when job ledger unblock_metrics daily-<today> is not
# `sent`, and puts it `sent` after; an unreadable ledger skips the step (one
# line, the next tick tries again). Then bin/staff/tackler-report.sh run, which
# sends only on its weekday.
#
# ORDER, every verb: UNBLOCK_METRICS_ENABLED=0 exits 0 before any read; the
# switch staff-off-tackler (lane_switch) exits 0; then lane_gate_or_exit (the
# lane switch lane-off-unblock-metrics) and lane_env_apply unblock-metrics
# (ENABLED is read again after); then flock -n
# locks/unblock-metrics.lock (held = one line, exit 0, never wait). The
# override pass stops at a 480 s deadline; the weekly report runs under
# timeout 300.
#
# OFF: UNBLOCK_METRICS_ENABLED=0, flags/lane-off-unblock-metrics,
# bin/harness-ctl.sh off unblock-metrics, flags/staff-off-tackler.
# Registry: catalog/lanes.d/unblock-metrics.json.
# Cron: cron/lanes/418-unblock-metrics.cron.
# gh-rest: no-graphql
set -uo pipefail
H="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "$0")" && pwd)"
VERB="${1:-}"
case "$VERB" in
  overrides|daily|tick) ;;
  *) echo "usage: unblock-metrics.sh overrides|daily|tick" >&2; exit 2 ;;
esac
# The env kill switch first: no read of any kind behind it.
[ "${UNBLOCK_METRICS_ENABLED:-1}" = 0 ] && exit 0
. "$H/bin/lib/env-path.sh" 2>/dev/null || . "$SELF/lib/env-path.sh" 2>/dev/null \
  || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }
HENV=$(harness_env_dir "$H")
# shellcheck disable=SC1091
[ -r "$HENV/global.env" ] && { set -a; . "$HENV/global.env" 2>/dev/null; set +a; }
# shellcheck disable=SC1091
{
  . "$H/bin/lib/lane-gate.sh" 2>/dev/null || . "$SELF/lib/lane-gate.sh" 2>/dev/null || true
  . "$SELF/lib/lane-switch.sh" 2>/dev/null || true
  . "$SELF/jobs-client.sh" 2>/dev/null || true
  . "$SELF/lib/gh-rest.sh" 2>/dev/null || true
}
# shellcheck source=bin/lib/unblock/override.sh
. "$SELF/lib/unblock/override.sh" || { echo "unblock-metrics: bin/lib/unblock/override.sh missing" >&2; exit 1; }
command -v _jobs_req >/dev/null 2>&1 && command -v gh_rest >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 \
  || { echo "unblock-metrics: jobs-client, gh-rest or jq missing" >&2; exit 1; }
# Archie's Overlooker pauses a staff agent with flags/staff-off-<agent>.
command -v lane_switch >/dev/null 2>&1 || lane_switch() { [ -f "$H/flags/$1" ]; }   # no lib: the file
lane_switch staff-off-tackler file && exit 0

NOW=""
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [[ ${UNBLOCK_NOW:-} =~ ^[0-9]+$ ]]; then NOW=$UNBLOCK_NOW; fi
[ -n "$NOW" ] || NOW=$(date -u +%s)
UO_NOW=$NOW
mkdir -p "$H/logs" "$H/locks" 2>/dev/null
LOG="$H/logs/unblock-metrics.log"
log() { printf '%s %s\n' "$(date -u -d "@$NOW" +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG"; }

command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit unblock-metrics
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply unblock-metrics
[ "$(_uo_int UNBLOCK_METRICS_ENABLED "${UNBLOCK_METRICS_ENABLED:-1}" 1 0 1)" = 0 ] && exit 0

exec 9>"$H/locks/unblock-metrics.lock" || exit 0
flock -n 9 || { log "lock held (locks/unblock-metrics.lock); skipped"; exit 0; }

TODAY=$(date -u -d "@$NOW" +%Y-%m-%d)

daily() {
  local projects p resp line
  projects=$(uo_active_projects) || { log "daily: settings unreadable; no line written"; return 0; }
  [ -n "$projects" ] || { log "daily: no project has unblock mode shadow or act"; return 0; }
  while IFS= read -r p; do
    resp=$(_jobs_req GET "/api/unblock/metrics?project=$p&days=7&to=$TODAY") \
      && jq -e '(.daily | type == "array" and length > 0) and (.totals | type == "object")' <<<"$resp" >/dev/null 2>&1 \
      || { log "tackler $p: metrics unreadable (http ${JOBS_HTTP:-none})"; continue; }
    line=$(jq -r --arg p "$p" '
      def v($u): if . == null then "n/a" else (tostring + $u) end;
      .daily[-1] as $d | .totals as $t |
      "tackler \($p) \($d.day): decisions \($d.decisions), would \($d.would), escalations \($d.escalations), overrides \($d.overrides), stall median \($d.stall_median_min | v("m")) p95 \($d.stall_p95_min | v("m")); 7d decisions/day \($t.decisions_per_day), escalations/day \($t.escalations_per_day), override rate \(if $t.override_rate == null then "n/a" else ((($t.override_rate * 1000 | round) / 10 | tostring) + "%") end), stall median \($t.stall_median_min | v("m")) p95 \($t.stall_p95_min | v("m"))"' <<<"$resp")
    log "$line"
    printf '%s\n' "$line"
  done <<<"$projects"
}

overrides() {
  UO_DEADLINE=$(( $(date -u +%s) + 480 )) uo_scan
}

case "$VERB" in
  overrides) overrides ;;
  daily) daily ;;
  tick)
    overrides
    st=$(job_ledger_get unblock_metrics "daily-$TODAY" 2>/dev/null); rc=$?
    case "$rc" in
      0|2) if [ "$rc" = 2 ] || [ "$st" != sent ]; then
             daily >/dev/null
             job_ledger_put unblock_metrics "daily-$TODAY" sent >/dev/null 2>&1 \
               || log "warn: daily $TODAY written but could not be marked sent"
           fi ;;
      *) log "daily $TODAY: ledger unreadable; not written, the next tick tries again" ;;
    esac
    TACKLER_NOW="${TACKLER_NOW:-$NOW}" timeout 300 "$SELF/staff/tackler-report.sh" run \
      || log "weekly report exited rc $?"
    ;;
esac
exit 0
