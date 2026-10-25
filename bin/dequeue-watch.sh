#!/bin/bash
# bin/dequeue-watch.sh — BH-3719: the dequeue-watch hub lane. Every */5 on the
# hub (cron/lanes/415-dequeue-watch.cron) it finds each PR Mergify dequeued,
# decides culprit or bystander, classifies the failure and acts ONCE per
# (pr, head, class): requeue a bystander or a flake, ask the lead for a verdict
# on a stale status, wait out a red main, queue a bounded fix round for a real
# break, or hold it for a person. It pages when a dequeued head stays unowned.
#
# THREE MODES (BH-5944, the per-project runner bin/lib/project-lanes.sh):
#   dequeue-watch.sh --dispatch   the cron line. Starts one detached
#       `dequeue-watch.sh <project>` per fleet project (pl_lane_dispatch, a 50 s
#       window) and returns. The observe tick below runs here, once per dispatch.
#   dequeue-watch.sh <project>    one project's tick. Its lock is
#       locks/dequeue-watch-<project>.lock (the runner's fd 9) plus
#       locks/dequeue-watch.lock SHARED; either held = summary `locked`. Its
#       summary line ends ` project=<project>`.
#   dequeue-watch.sh              the whole-fleet tick, as before (hand runs).
#
# One tick: gates → flock dedupe → libs (fail-open: a missing one is one warn
# and ` lib-missing`) → ` gh-budget` when GitHub is low → per Mergify project in
# fleet.conf: the open merge-queue/dequeued PRs (unread list = skip the project,
# never "none"), capped at DEQUEUE_WATCH_PR_CAP → per PR: dqw_gather_pr
# (bin/lib/dequeue-watch/gather.sh; its pulls/<n> read goes to the PR record
# first, bin/lib/ph-pr-record.sh), dqw_classify, dqw_llm_classify on an
# unclassified dequeue with FAIL lines, dqw_event_state, dqw_act, dqw_watchdog →
# dqw_mainred_recheck and dqw_gather_resolve → in observe mode,
# observe_report_tick (bin/lib/observe-report.sh). The whole tick runs under
# `timeout 240` in a child; when the timeout kills it, this wrapper writes
# ` tick timed-out` in its place (BH-3859).
#
# Summary line, one per tick, in logs/dequeue-watch.log:
#   <ts> tick projects=<n> dequeued=<n> recorded=<n> acted=<n> would=<n> owned=<n> unread=<n> stale=<n> skipped=<n>[ page-cut][ err=<word,...>]
#   <ts> off | disabled | locked | gh-budget | lib-missing <names> | tick timed-out
# acted= counts only real actions (act mode 1, a side effect started); would=
# the WOULD_ lines of observe mode; owned= a claim another row already held;
# unread= a fix-round count or claim that could not be read. skipped= is every
# PR gather skipped, its already-owned skips included.
# Per-PR detail lines (stale-event, event-record-failed, already-owned, WOULD_*)
# go to the same file.
#
# OFF: settings row / flags/dequeue-watch-off (lane_switch), flags/lane-off-dequeue-watch
# (bin/harness-ctl.sh off dequeue-watch), or DEQUEUE_WATCH=0. Ships
# observe-only (DEQUEUE_WATCH_ACT=0, BH-3859): after DEQUEUE_WATCH_OBSERVE_TICKS
# full observe ticks it posts ONE warn (observe-report:dequeue-watch) with what
# it would have done and the command that lets it act; it never flips itself.
# Registry: catalog/lanes.d/dequeue-watch.json. Notes:
# docs/notes/2026-09-30-BH-3719-dequeue-watch.md,
# docs/notes/2026-10-03-BH-3859-dequeue-watch-ship-dark.md.
#
# gh-identity: app-token
# gh-rest: no-graphql
set -uo pipefail
H="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "$0")" && pwd)"
# Arguments, checked before the timeout re-exec and any worker request.
usage() { echo "usage: dequeue-watch.sh [--dispatch | <project>]" >&2; exit 2; }
RUN_MODE=fleet; ONLY_P=""
case "$#" in
  0) ;;
  1) case "$1" in --dispatch) RUN_MODE=dispatch ;; -*|''|.*|*[!A-Za-z0-9._-]*) usage ;; *) RUN_MODE=project; ONLY_P=$1 ;; esac ;;
  *) usage ;;
esac
# shellcheck source=bin/lib/project-lanes.sh
[ -r "$H/bin/lib/project-lanes.sh" ] && . "$H/bin/lib/project-lanes.sh"
if [ "$RUN_MODE" = project ] && ! { command -v pl_project_known >/dev/null 2>&1 && pl_project_known "$ONLY_P"; }; then
  echo "dequeue-watch: fleet.conf names no project '$ONLY_P' (or bin/lib/project-lanes.sh is missing)" >&2; exit 2
fi
# Bounded (D21): the whole tick inside 4 minutes, well inside its */5. Not an
# exec: a tick the timeout kills writes no summary, so this wrapper writes it.
# DEQUEUE_WATCH_TICK_TIMEOUT_S is a sandbox-only test seam; prod is always 240.
if [ "${DQW_TIMED:-}" != 1 ] && command -v timeout >/dev/null 2>&1; then
  secs=240
  [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [[ "${DEQUEUE_WATCH_TICK_TIMEOUT_S:-}" =~ ^[1-9][0-9]*$ ]] \
    && secs="$DEQUEUE_WATCH_TICK_TIMEOUT_S"
  DQW_TIMED=1 timeout "$secs" bash "$0" "$@"; rc=$?
  if [ "$rc" = 124 ]; then
    mkdir -p "$H/logs" 2>/dev/null
    printf '%s tick timed-out\n' "$(date -u +%FT%TZ)" >> "$H/logs/dequeue-watch.log" 2>/dev/null
  fi
  exit 0
fi
TICK_START=$(date -u '+%Y-%m-%d %H:%M:%SZ')
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
}

command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit dequeue-watch
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply dequeue-watch
command -v lane_switch >/dev/null 2>&1 || lane_switch() { [ -f "$H/flags/$1" ]; }

mkdir -p "$H/logs" "$H/locks" 2>/dev/null
LOG="$H/logs/dequeue-watch.log"
summary() { printf '%s%s\n' "$(date -u +%FT%TZ)" "${1:+ $1}" >> "$LOG"; }
note() { echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') $*" >> "$LOG"; }
warn() { "$H/bin/lane-alert.sh" --severity warn --id "$1" dequeue-watch "$2" >/dev/null 2>&1 || true; }

if lane_switch dequeue-watch-off file; then summary off; exit 0; fi
[ "${DEQUEUE_WATCH:-1}" = 0 ] && { summary disabled; exit 0; }
if [ "$RUN_MODE" = dispatch ]; then
  if ! command -v pl_lane_dispatch >/dev/null 2>&1; then
    echo "$(date -u +%FT%TZ) dequeue-watch dispatch: bin/lib/project-lanes.sh is not loaded — no project run started"
    exit 1
  fi
  rc=0; line=$(pl_lane_dispatch dequeue-watch 50 "$H/bin/dequeue-watch.sh") || rc=$?
  echo "$(date -u +%FT%TZ) $line"
  # Ship dark (BH-3859): a dispatch is one observe tick, whatever its project count.
  # shellcheck disable=SC1091
  [ -r "$SELF/lib/observe-report.sh" ] && . "$SELF/lib/observe-report.sh" 2>/dev/null
  if [ "$rc" = 0 ] && [ "${DEQUEUE_WATCH_ACT:-0}" != 1 ] && declare -F observe_report_tick >/dev/null; then
    OBS="${DEQUEUE_WATCH_OBSERVE_TICKS:-12}"
    if ! [[ "$OBS" =~ ^[0-9]+$ ]] || [ "$OBS" -lt 1 ]; then
      note "DEQUEUE_WATCH_OBSERVE_TICKS='$OBS' is not a positive integer, using 12"
      OBS=12
    fi
    observe_report_tick dequeue-watch "$OBS" "$LOG" "bin/harness-ctl.sh set dequeue-watch DEQUEUE_WATCH_ACT 1" "$TICK_START" || true
  fi
  exit "$rc"
fi
# Dedupe, not a queue: a tick still running owns this one; the lock goes with the process.
if [ "$RUN_MODE" = project ]; then
  pl_lane_lock dequeue-watch "$ONLY_P" || { summary "locked project=$ONLY_P"; exit 0; }
else
  exec 9>"$H/locks/dequeue-watch.lock" || { summary locked; exit 0; }
  flock -n 9 || { summary locked; exit 0; }
fi

export HARNESS="$H"
# shellcheck disable=SC1091
{
  . "$SELF/lib/gh-budget.sh" 2>/dev/null || true
  . "$SELF/lib/gh-rest.sh" 2>/dev/null || true
  [ -r "$SELF/lib/merge-conductor-lib.sh" ] && . "$SELF/lib/merge-conductor-lib.sh" 2>/dev/null
  for _l in verdicts mc-stale-dequeue fix-round-queue needs-human hub-box ph-pr-record \
            dequeue-watch/attribute dequeue-watch/classify dequeue-watch/act dequeue-watch/llm dequeue-watch/gather; do
    [ -r "$SELF/lib/$_l.sh" ] && . "$SELF/lib/$_l.sh" 2>/dev/null
  done
  unset _l
  # Not in MISSING below: without the report the watch still runs.
  [ -r "$SELF/lib/observe-report.sh" ] && . "$SELF/lib/observe-report.sh" 2>/dev/null
}
# The suite's seam. Sandbox only, and settable:false in the registry.
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [ -n "${DEQUEUE_WATCH_FIXTURE:-}" ]; then
  # shellcheck disable=SC1090
  . "$DEQUEUE_WATCH_FIXTURE"
fi
MISSING=""
for f in gh_rest sdq_payload_last vd_standing mc_queue_provider dqw_event_record dqw_event_state \
         dqw_parse_payload_md dqw_attribute dqw_classify dqw_parse_log dqw_brief dqw_hint dqw_act \
         dqw_watchdog dqw_mainred_recheck dqw_llm_classify dqw_gather_dequeued dqw_gather_pr dqw_gather_resolve; do
  declare -F "$f" >/dev/null || MISSING="$MISSING $f"
done
if [ -n "$MISSING" ]; then
  warn dqw-lib-missing "dequeue-watch did not run: these functions are not loaded:$MISSING. Check bin/lib/ on the hub."
  summary "lib-missing${MISSING}"
  exit 0
fi
PROJECTS=$(awk -v only="$ONLY_P" '$1 !~ /^#/ && NF >= 2 && (only == "" || $1 == only) { print $1, $2 }' "$H/fleet.conf" 2>/dev/null)
# No project, no GitHub read at all, the budget probe included.
if [ -n "$PROJECTS" ] && declare -F gh_budget_low >/dev/null; then
  gh_budget_low dequeue-watch; [ $? = 0 ] && { summary gh-budget; exit 0; }
fi

DQW_TMP=$(mktemp -d "${TMPDIR:-/tmp}/dequeue-watch.XXXXXX") || { summary "tick projects=0 dequeued=0 recorded=0 acted=0 would=0 owned=0 unread=0 stale=0 skipped=0 err=mktemp"; exit 0; }
export DQW_TMP
trap 'rm -rf "$DQW_TMP"' EXIT
CAP="${DEQUEUE_WATCH_PR_CAP:-20}"
[[ "$CAP" =~ ^[0-9]+$ ]] && [ "$CAP" -ge 1 ] || CAP=20
NP=0 ND=0 NR=0 NA=0 NW=0 NO=0 NU=0 NS=0 NK=0 CUT="" ERR=""
err() { case ",$ERR," in *",$1,"*) ;; *) ERR="${ERR:+$ERR,}$1" ;; esac; }

# pr_tick <P> <slug> <num> — one dequeued PR, gather to act.
pr_tick() {
  local P="$1" slug="$2" num="$3" f="$DQW_TMP/pr-$3.tsv" head url age attr how mergeable stale rerun red verdict ref run run_url draft checks dir
  local cls chow rid suites ans brief hint ctx
  DQW_G_WATCH="" DQW_G_STALE="" DQW_G_RECORDED="" DQW_G_CLASS="" DQW_A_CLASS="" DQW_A_OUTCOME=""
  if dqw_gather_pr "$P" "$slug" "$num" > "$f"; then
    IFS=$'\t' read -r head url age attr how mergeable stale rerun red verdict ref run run_url draft checks dir < "$f"
    [ "$ref" = - ] && ref=""; [ "$verdict" = - ] && verdict=""
    IFS=$'\t' read -r cls chow rid <<<"$(dqw_classify main_red="$red" mergeable="$mergeable" stale="$stale" \
      checks="$checks" rerun_green="$rerun" attribution="$attr" parsed="$dir/parsed")"
    suites=$(awk -F'\t' '$1 != "-" { print $1 }' "$dir/parsed" | sort -u | paste -sd' ' -)
    if [ "$cls" = unclassified ] && [ -s "$dir/fail" ] && [ "${DEQUEUE_WATCH_LLM:-1}" = 1 ]; then
      ans=$(dqw_llm_classify "$P" "$slug" "$num" "$head" "$run" "${suites:--}" "$dir/fail")
      [[ "$ans" =~ ^[a-z-]+$ ]] && { cls="$ans"; chow=llm; }
    fi
    dqw_event_state "$slug" "$num" "$head" "$run" "$(jq -nc --arg a "$attr" --arg ah "$how" --arg c "$cls" \
        --arg ch "$chow" --arg r "$rid" --arg s "${suites:-}" --rawfile fl "$dir/fail" \
        '{attribution: $a, attribution_how: $ah, class: $c, class_how: $ch, rule_id: $r, suites: $s, fail_lines: $fl}')" >/dev/null \
      || note "$slug#$num ${head:0:12} event-state write failed, acting anyway"
    hint=$(dqw_hint "$cls" "$rid") || hint=""
    brief=$(dqw_brief "$cls" "$rid" "${suites%% *}" "$dir/parsed" "$run_url")
    [ -s "$dir/parsed" ] || brief="$brief"$'\n'"$(sed -E 's/^/- /; s/([0-9a-f]{12})[0-9a-f]{28,}/\1/g' "$dir/fail")"
    ctx=$(jq -nc --arg rid "$rid" --arg s "${suites%% *}" --rawfile fl "$dir/fail" --arg hint "$hint" --arg b "$brief" \
      --arg run "$run" --arg ru "$run_url" --arg d "$draft" --arg ref "$ref" --arg v "$verdict" \
      '{rule_id: $rid, suite: $s, fail_lines: $fl, hint: $hint, brief: $b, run_id: $run, run_url: $ru,
        draft: $d, head_ref: $ref, verdict_word: $v}')
    dqw_act "$P" "$slug" "$num" "$url" "$head" "$cls" "$ctx"
    case "$DQW_A_OUTCOME" in
      acted) NA=$((NA + 1)) ;;
      would) NW=$((NW + 1)) ;;
      owned) NO=$((NO + 1)) ;;
      unread) NU=$((NU + 1)) ;;
    esac
  else
    NK=$((NK + 1))
    [ -n "$DQW_G_STALE" ] && NS=$((NS + 1))
  fi
  [ -n "$DQW_G_RECORDED" ] && NR=$((NR + 1))
  # The watchdog after the act, so a claim made this tick already owns the head.
  # It looks for the class this tick claimed under (or gather found owned): a
  # second class on the same head is not resolved off the first one's row.
  # No class known (gather skipped before classifying) = any class owns it.
  if [ -n "$DQW_G_WATCH" ]; then
    read -r head age <<<"$DQW_G_WATCH"
    dqw_watchdog "$P" "$slug" "$num" "$head" "$age" "https://github.com/$slug/pull/$num" "${DQW_A_CLASS:-${DQW_G_CLASS:-}}"
  fi
}

while read -r P SLUG; do
  [ -n "$P" ] || continue
  NP=$((NP + 1))
  declare -F gh_auth_for >/dev/null && { gh_auth_for "$SLUG" || true; }   # rc 1 = the box's own identity, as every lane
  prov=$(mc_queue_provider "$SLUG" 2>/dev/null)
  case "$prov" in
    mergify) ;;
    unknown|'') err provider-unknown; continue ;;
    *) continue ;;
  esac
  if ! NUMS=$(dqw_gather_dequeued "$SLUG"); then
    note "$P: the merge-queue/dequeued lists of $SLUG are unread, project skipped"
    err skip-project; continue
  fi
  n=0
  for num in $NUMS; do
    n=$((n + 1))
    if [ "$n" -gt "$CAP" ]; then
      CUT=" page-cut"
      warn "dqw-page-cut:$P" "$P: $(( $(wc -w <<<"$NUMS") - CAP )) dequeued PRs on $SLUG were left for a later tick (DEQUEUE_WATCH_PR_CAP=$CAP)."
      break
    fi
    ND=$((ND + 1))
    pr_tick "$P" "$SLUG" "$num"
  done
  dqw_mainred_recheck "$P" "$SLUG"
  dqw_gather_resolve "$P" "$SLUG" "$NUMS"
done <<<"$PROJECTS"

summary "tick projects=$NP dequeued=$ND recorded=$NR acted=$NA would=$NW owned=$NO unread=$NU stale=$NS skipped=$NK$CUT${ERR:+ err=$ERR}${ONLY_P:+ project=$ONLY_P}"
# Ship dark (BH-3859): every full observe tick counts toward the one report. A
# project run is not a tick of its own: its dispatch counted it.
if [ "$RUN_MODE" = fleet ] && [ "${DEQUEUE_WATCH_ACT:-0}" != 1 ] && declare -F observe_report_tick >/dev/null; then
  OBS="${DEQUEUE_WATCH_OBSERVE_TICKS:-12}"
  if ! [[ "$OBS" =~ ^[0-9]+$ ]] || [ "$OBS" -lt 1 ]; then
    note "DEQUEUE_WATCH_OBSERVE_TICKS='$OBS' is not a positive integer, using 12"
    OBS=12
  fi
  observe_report_tick dequeue-watch "$OBS" "$LOG" "bin/harness-ctl.sh set dequeue-watch DEQUEUE_WATCH_ACT 1" "$TICK_START" || true
fi
exit 0
