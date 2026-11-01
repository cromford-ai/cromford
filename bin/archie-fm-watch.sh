#!/bin/bash
# bin/archie-fm-watch.sh — BH-4586 (BH-4574.4): Archie's whole-factory watch. A
# hub lane that reads the factory beyond PRs and pulls ONE lever per incident,
# or files ONE ticket when the lever did not take (bin/lib/archie-fm-watch/).
#
#   archie-fm-watch.sh [tick] [--class <class>] [--dry-list]
#     no argument is a tick: the cron line, every 10 minutes (7-57/10, off the
#     queue doctor's minute). A tick acts only once per archie.watch.interval_min
#     (default 20, so :07, :27 and :47); the other ticks exit before any lock.
#     --class narrows one tick to one finding class.
#     --dry-list prints the findings (one TSV line each) and acts on nothing:
#     no row, no lever.
#
# FINDINGS come from the alerts that already exist (the open rows of the jobs-DB
# alerts table) and four sweeps where no alert covers the case:
#   class             source                                    lever
#   build-stuck       alert stuck-work                          ack_alert (routed)
#   review-unrescued  alert lane-reaper_*, sweep builds/*/RESULT kick_lane review-rescue (RESCUE_ONLY=<p>)
#   pool-idle         alert [fly-idle] ...                      file_ticket
#   disk              alert disk-high/disk-refuse/ph-tmpfull,   run_cleanup on this box (bin/disk-clean.sh),
#                     sweep df -iP / /tmp                       ack_alert for another box
#   cron-install      alert fleet-propagate / CRONTAB lines,    kick_lane fleet-propagate
#                     sweep lanes.d vs crontab -l
#   deploy-drift      alert ph-deployworkers_*,                 rerun_deploy (REST rerun-failed-jobs),
#                     ph-consolepagesdrift_hub                  bin/console-pages-deploy.sh (or file_ticket)
#   main-red          alert main-red-<slug>                     kick_lane main-red-bisect
#   pause-waiting     sweep state/pauses.json + ready work      file_ticket (never unpause)
#   triage-skip       alert untriaged-digest_* / untriaged lines kick_lane triage (box command run_triage)
#   cost-anomaly      alert ph-cost*/ph-overcap/budget-stop/    kick_lane cost-rollup (stale rollup),
#                     cost-reconcile/gh-quota                   ack_alert otherwise
#   owed-overdue      sweep OWED TO OPERATOR lines in STATE.md       note (one row; the model session
#                     past their expected-by                    tells the operator)
#   metric-unreadable sweep active initiatives whose last       note (one row per initiative)
#                     check was unreadable (/api/initiatives)
# An incident still open archie.watch.escalate_s after its lever ran gets ONE
# watch-ticket row and one unlabelled issue on example-org/cromford.
#
# TICK, in this order:
#   1. lane_gate_or_exit / lane_env_apply archie-fm-watch; ARCHIE_FMW_ENABLED=0
#      exits; flock -n locks/archie-fm-watch.lock (held = skip, never wait); NOW
#      read once (ARCHIE_FMW_NOW only under HARNESS_TEST_SANDBOX=1). The outer
#      `timeout` (1860 s) is the backstop; the tick's own deadline is 1500 s, and
#      bin/disk-clean.sh (timeout 900) starts only with 960 s left. A TERM trap
#      closes this tick's `started` row failed; a tick killed outright leaves it
#      `started`, and the next tick past ARCHIE_FMW_RETRY_S closes it failed with
#      one alert (wave 2's afq_claim).
#   2. collect the findings (afw_collect); a read that fails is logged and the
#      summary says incomplete=1, never "nothing found".
#   3. per finding: the mode from archie.manage.<project> > archie.manage > on
#      (fleet-scope findings read project `hub`); off skips it; then afw_handle.
#   4. one line in logs/archie-fm-watch.log on EVERY acting tick, a quiet one
#      too (BH-8417: a quiet tick is still a line, so bin/log-freshness.sh can
#      tell a live lane from a dead log):
#      <ts> tick findings=<n> pulled=<n> tickets=<n> would=<n> capped=<n> skipped=<n> failed=<n> incomplete=<0|1> sessions=<n> route_absent=<0|1>
#
# ROUTE ABSENT vs ROW MISS (BH-8417). The real _jobs_req prints nothing on a
# 404 and keeps the body in JOBS_BODY_FILE (set for the tick). A 404 whose body
# is the worker's {"error":"archie action not found"} is a ROW miss: on the
# ledger read it is "no row yet"; anywhere else it fails that one finding, with
# one log line, and the loop goes on (afw_route_absent). Any other 404 is the
# route absent: the tick stops, and ONE ALERTS line a UTC day says so (marker
# state/archie-fm-watch/route-absent-<yyyymmdd>; only the newest is kept).
#
# EVERY LEVER PULL AND EVERY TICKET IS AN archie_actions ROW
# (worker/jobs/src/routes/archie-actions.js, playbooks watch-<class> and
# watch-ticket, pr 0), claimed before the lever runs, keyed on the incident, with
# a per-playbook day cap (settings archie.cap.watch-*). Observe mode writes
# would_* rows and nothing else.
#
# MODEL SESSION (afw_session, the operator 2026-10-06): after the loop, a plain tick
# starts at most ONE agent-call (stage archie), only when this tick created a
# row (something new) or once per UTC 3h block (the owed walk), under the day
# cap archie.cap.watch-session. It needs catalog/prompts/archie-watch.md
# (BH-4760). A non-blank answer goes to the operator through bin/archie-tg-send.sh.
#
# NEVER: a merge, a push, a deploy outside the two deploy re-runs, an unpause, a
# machine stop, a model call outside afw_session, an alert of its own other
# than the route-absent line, or a state file other than its day marker.
#
# OFF: ARCHIE_FMW_ENABLED=0, flags/lane-off-archie-fm-watch,
# bin/harness-ctl.sh off archie-fm-watch, or archie.manage[.<project>]=off.
# Registry: catalog/lanes.d/archie-fm-watch.json.
# Note: docs/notes/2026-10-05-BH-4586-archie-fm-watch.md.
# gh-rest: no-graphql
set -uo pipefail
H="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "$0")" && pwd)"
[ "${1:-}" = tick ] && shift
ONLY_CLASS=""; DRY_LIST=0
while [ $# -gt 0 ]; do
  case "$1" in
    --class) ONLY_CLASS="${2:-}"; shift 2 ;;
    --dry-list) DRY_LIST=1; shift ;;
    *) echo "usage: archie-fm-watch.sh [tick] [--class <class>] [--dry-list]" >&2; exit 2 ;;
  esac
done
case "$ONLY_CLASS" in
  ''|build-stuck|review-unrescued|pool-idle|disk|cron-install|deploy-drift|main-red|pause-waiting|triage-skip|cost-anomaly|owed-overdue|metric-unreadable) ;;
  *) echo "archie-fm-watch: --class wants one of build-stuck review-unrescued pool-idle disk cron-install deploy-drift main-red pause-waiting triage-skip cost-anomaly owed-overdue metric-unreadable, got '$ONLY_CLASS'" >&2; exit 2 ;;
esac
if [ "${ARCHIE_FMW_TIMED:-}" != 1 ] && command -v timeout >/dev/null 2>&1; then
  CEIL=1860
  if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [[ ${ARCHIE_FMW_TICK_CEILING_S:-} =~ ^[0-9]+$ ]]; then CEIL=$ARCHIE_FMW_TICK_CEILING_S; fi
  DL=(); [ "$DRY_LIST" = 1 ] && DL=(--dry-list)
  ARCHIE_FMW_TIMED=1 exec timeout -k 60 "$CEIL" bash "$0" tick ${ONLY_CLASS:+--class "$ONLY_CLASS"} ${DL[@]+"${DL[@]}"}
fi
. "$H/bin/lib/env-path.sh" 2>/dev/null || . "$SELF/lib/env-path.sh" 2>/dev/null \
  || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }
HENV=$(harness_env_dir "$H")
# shellcheck disable=SC1091
[ -r "$HENV/global.env" ] && { set -a; . "$HENV/global.env" 2>/dev/null; set +a; }
# BH-4080: HARNESS_REPO's default lives in the deployment defaults home.
# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-$SELF/lib/deployment.sh}" || exit 1
# shellcheck disable=SC1091
{
  . "$H/bin/lib/lane-gate.sh" 2>/dev/null || . "$SELF/lib/lane-gate.sh" 2>/dev/null || true
  . "$SELF/jobs-client.sh" 2>/dev/null || true
  . "$SELF/lib/jobs/box-console-commands.sh" 2>/dev/null || true
  . "$SELF/lib/gh-rest.sh" 2>/dev/null || true
  . "$SELF/lib/pause.sh" 2>/dev/null || true
  . "$SELF/lib/ready-queue.sh" 2>/dev/null || true
  . "$SELF/lib/verdict-parse.sh" 2>/dev/null || true
  . "$SELF/lib/merge-conductor-lib.sh" 2>/dev/null || true
  . "$SELF/lib/archie-fm.sh" 2>/dev/null || true
  . "$SELF/lib/lane-model.sh" 2>/dev/null || true
  . "$SELF/lib/archie-fm-queue/common.sh" 2>/dev/null || true
  . "$SELF/lib/archie-fm-watch/common.sh" 2>/dev/null || true
  . "$SELF/lib/archie-fm-watch/sources.sh" 2>/dev/null || true
  . "$SELF/lib/archie-fm-watch/levers.sh" 2>/dev/null || true
}
# The suite's seam. Sandbox only, and settable:false in the registry.
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [ -n "${ARCHIE_FMW_FIXTURE:-}" ]; then
  # shellcheck disable=SC1090
  . "$ARCHIE_FMW_FIXTURE"
fi
for f in afm_mode afm_cap_ok afm_close _afm_req _jobs_req setting_get alerts_list gh_rest box_ccmd_forward mc_init \
         afq_claim afq_close afq_setting_secs afq_rows_of afw_collect afw_handle afw_pull afw_lever afw_match afw_session; do
  command -v "$f" >/dev/null 2>&1 || { echo "archie-fm-watch: $f is not defined (a lib is missing)" >&2; exit 1; }
done
command -v jq >/dev/null 2>&1 || { echo "archie-fm-watch: jq missing" >&2; exit 1; }

NOW=""
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [[ ${ARCHIE_FMW_NOW:-} =~ ^[0-9]+$ ]]; then NOW=$ARCHIE_FMW_NOW; fi
[ -n "$NOW" ] || NOW=$(date -u +%s)
DAY=$(date -u -d "@$NOW" +%F)
mkdir -p "$H/logs" "$H/locks" 2>/dev/null
AFM_LOG="$H/logs/archie-fm-watch.log"
AFM_H="$H"
AFQ_ACTOR=archie-fm-watch
AFW_HENV="$HENV"
AFW_CO="${HARNESS_CHECKOUT:-/root/harness-checkout}"
AFW_STATE_MD="${ARCHIE_FMW_STATE_MD:-/root/orchestrator/STATE.md}"
AFW_HOSTS="$(hostname 2>/dev/null) $(hostname -s 2>/dev/null)"
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [ -n "${ARCHIE_FMW_HOST:-}" ]; then AFW_HOSTS=$ARCHIE_FMW_HOST; fi
AFW_ONLY_CLASS=$ONLY_CLASS

# knob_int <name> <value> <default> <min> <max>: out of range is one warn line
# and the default, never a silent clamp (D11).
knob_int() {
  local v=$2
  if [[ $v =~ ^[0-9]+$ ]] && [ "$((10#$v))" -ge "$4" ] && [ "$((10#$v))" -le "$5" ]; then
    printf '%s' "$((10#$v))"
  else
    afw_log "warn: $1=$v is outside $4..$5; using the default $3"
    printf '%s' "$3"
  fi
}

command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit archie-fm-watch
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply archie-fm-watch
case "${ARCHIE_FMW_ENABLED:-1}" in
  0) exit 0 ;;
  1) ;;
  *) afw_log "warn: ARCHIE_FMW_ENABLED=${ARCHIE_FMW_ENABLED} is not 0 or 1; using the default 1" ;;
esac
# THE INTERVAL (the operator, 2026-10-06): cron fires every 10 minutes, and a plain
# tick runs only when it is the first tick of its archie.watch.interval_min
# window of epoch minutes (default 20: the ticks at :07, :27 and :47). The
# window is arithmetic on NOW, so no state file. --class and --dry-list run.
if [ -z "$ONLY_CLASS" ] && [ "$DRY_LIST" = 0 ]; then
  IV=$(setting_get archie.watch.interval_min); rc=$?
  case "$rc" in
    0) IV=$(printf '%s' "$IV" | tr -d '[:space:]') ;;
    2) IV=20 ;;
    *) afw_log "archie.watch.interval_min unreadable (rc=$rc); using the default 20"; IV=20 ;;
  esac
  IV=$(knob_int archie.watch.interval_min "$IV" 20 10 1440)
  [ "$(( (NOW / 60) % IV ))" -lt 10 ] || exit 0
fi
exec 9>"$H/locks/archie-fm-watch.lock" || exit 0
flock -n 9 || exit 0

AFQ_RETRY_S=$(knob_int ARCHIE_FMW_RETRY_S "${ARCHIE_FMW_RETRY_S:-1800}" 1800 60 86400)
AFW_DEADLINE=$(( $(date +%s) + 1500 ))
afw_on_term() {
  trap - TERM INT HUP
  if [ -n "$AFM_ROW" ] && [ "$(jq -r .outcome <<<"$AFM_ROW" 2>/dev/null)" = started ]; then
    afm_close failed "" "the tick was stopped mid-action (its backstop or a signal); not retried on this key" \
      && afw_log "$(jq -r .dedupe_key <<<"$AFM_ROW"): the tick was stopped mid-action; the row is failed"
  fi
}
trap 'afw_on_term; exit 143' TERM INT HUP
mc_init

AFW_PROJECTS=$("$H/bin/fleet-conf.sh" --projects 2>/dev/null | tr '\n' ' ')
AFW_PROJECT_REPOS=""
for P in $AFW_PROJECTS; do
  SLUG=$("$H/bin/fleet-conf.sh" "$P" repo 2>/dev/null)
  case "$SLUG" in */*) AFW_PROJECT_REPOS+="$P $SLUG"$'\n' ;; esac
done
[ -n "$AFW_PROJECTS" ] || afw_log "warn: bin/fleet-conf.sh --projects answered nothing; project findings are skipped"

AFW_FINDINGS=$(mktemp "${TMPDIR:-/tmp}/afw-findings.XXXXXX") || { afw_log "mktemp failed; nothing read"; exit 0; }
trap 'rm -f "$AFW_FINDINGS" "$AFW_FINDINGS.u" "$AFW_FINDINGS.body"' EXIT
afw_settings_load
afw_collect
AFW_N_FINDINGS=$(grep -c . "$AFW_FINDINGS")

if [ "$DRY_LIST" = 1 ]; then
  cat "$AFW_FINDINGS"
  [ "$AFW_INCOMPLETE" = 1 ] && echo "# incomplete: a source could not be read in full (see logs/archie-fm-watch.log)" >&2
  exit 0
fi

# The newest jobs request's 404 body, readable after a $( ) (afw_route_absent).
# Not exported: a lever's child process never writes into it.
JOBS_BODY_FILE="$AFW_FINDINGS.body"
while IFS= read -r LINE; do
  [ -n "$LINE" ] || continue
  P=$(cut -f4 <<<"$LINE")
  if ! MODE=$(afm_mode "$P"); then
    afw_log "$P: the archie.manage settings could not be read; skipped this tick (no action without the ledger)"
    AFW_N_SKIPPED=$((AFW_N_SKIPPED + 1)); continue
  fi
  [ "$MODE" = off ] && continue
  rc=0; afw_handle "$LINE" "$MODE" || rc=$?
  if [ "$rc" = 2 ] || [ "$AFM_ROUTE_ABSENT" = 1 ]; then
    if afw_route_absent; then AFM_ROUTE_ABSENT=1; break; fi
    # A ROW miss, not the route: this finding failed; the next one is handled.
    AFM_ROUTE_ABSENT=0; AFM_ROW=""
    afw_log "$(cut -f1 <<<"$LINE") $(cut -f3 <<<"$LINE"): the jobs worker answered 404 'archie action not found' (a row miss, not the route); this finding failed, the loop goes on"
    AFW_N_FAILED=$((AFW_N_FAILED + 1))
  fi
  if [ "$(( AFW_DEADLINE - $(date +%s) ))" -le 0 ]; then
    afw_log "the tick's 1500 s deadline passed; the rest wait for the next tick"; AFW_INCOMPLETE=1; break
  fi
done < "$AFW_FINDINGS"
# afw_route_absent_alert — ONE ALERTS line per UTC day for an absent route
#   (BH-8417). The marker is written after the line; only today's is kept.
afw_route_absent_alert() {
  local d m body
  d="$H/state/archie-fm-watch"; m="$d/route-absent-$(date -u -d "@$NOW" +%Y%m%d)"
  [ -e "$m" ] && return 0
  mkdir -p "$d" 2>/dev/null || { afw_log "warn: $d could not be made; the route-absent alert is not sent this tick"; return 0; }
  body=$(head -c 120 "$JOBS_BODY_FILE" 2>/dev/null | tr -d '\n')
  afq_alert "archie_actions route absent: the jobs worker answered HTTP 404 for /api/archie/actions (body: ${body:-empty}), so the whole-factory watch did nothing this tick. Deploy worker/jobs (src/routes/archie-actions.js) or set the lane-off flag lane-off-archie-fm-watch. One line a day; logs/archie-fm-watch.log has every tick."
  : > "$m" || afw_log "warn: $m could not be written; the next tick may alert again"
  find "$d" -maxdepth 1 -name 'route-absent-*' ! -path "$m" -delete 2>/dev/null
  return 0
}
if [ "$AFM_ROUTE_ABSENT" = 1 ]; then
  afw_log "archie_actions route absent (HTTP 404 from the jobs worker); nothing done"
  afw_route_absent_alert
fi
[ -z "$ONLY_CLASS" ] && [ "$AFM_ROUTE_ABSENT" != 1 ] && afw_session
afw_log "tick findings=$AFW_N_FINDINGS pulled=$AFW_N_PULLED tickets=$AFW_N_TICKETS would=$AFW_N_WOULD capped=$AFW_N_CAPPED skipped=$AFW_N_SKIPPED failed=$AFW_N_FAILED incomplete=$AFW_INCOMPLETE sessions=$AFW_N_SESSIONS route_absent=$AFM_ROUTE_ABSENT"
exit 0
