#!/bin/bash
# bin/lib/project-ceiling.sh — the per-project daily spend ceiling. Sourced,
# never executed; defines functions only.
#
# WHY. One busy project can spend the whole fleet budget: the fleet ceiling
# (cost_budget_ceiling) is one number for every project, and the per-PR budget
# bounds a unit price, not a day. A project's pool cap is raised only with a
# ceiling of its own behind it.
#
# THE CEILING is cost_budget_daily <project> (bin/lib/cost-budget.sh): the
# settings row conf.cost-caps.<project>.daily_usd (box row first) over a
# `daily <project> <usd>` line of cost-caps.conf. A project with neither has
# no ceiling, and nothing here reads its spend.
# THE SPEND is the project's cost_rows for the worker's current UTC day, the
# same GET /api/metrics/llm-spend?project=<p> read as _bs_spend
# (bin/lib/budget-stop.sh); idx_cost_rows_project_ts serves it.
#
#   pc_eval <project>            rc 0 known: PC_SPENT (2 decimals), PC_CEIL,
#                                PC_PCT (floor), PC_STATE under|warn|over;
#                                rc 1 no ceiling (or the kill switch, or a bad
#                                slug): no read; rc 2 spend unreadable
#                                (PC_REASON); rc 3 no jobs client: no read
#   pc_launch_check <p> <0|1>    the launch gate (bin/lib/rb/gates.sh). rc 0
#                                start, rc 1 over (PC_LINE), rc 2 unreadable
#                                (PC_REASON). A hotfix (1) always starts; when
#                                it would have been refused PC_NOTE says why.
#   pc_stage_note <p> <stage>    bin/agent-call.sh, before a paid call of a
#                                PC_STAGES stage: alerts, never refuses, rc 0.
#
# ALERTS. At cost_budget_daily_warn_pct (default 80) of the ceiling, one warn
# alert per project per UTC day; at 100%, one over alert per project per UTC
# day, and no warn follows the over alert that day (the warn reads the over
# marker).
# Dedup is _bs_alert_once's flags/alerted-<id>.
#
# NOT A REFUSAL MID-BUILD. Only a new build is stopped. A running build, a
# resume of an admitted build and every stage call go on: the ticket says
# running builds finish. BH-4489's budget.project.<p>.day_usd is a different
# cap (it refuses calls) and is not read here.
#
# Kill switch: lane_switch project-ceiling-off (row switch.project-ceiling-off,
# else flags/project-ceiling-off).

_PC_LIB=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)
PC_STAGES="plan execute review lead-review"
PC_SPENT=""; PC_CEIL=""; PC_PCT=""; PC_STATE=""; PC_REASON=""; PC_LINE=""; PC_NOTE=""
# Sourced here, at the top level, never inside a function: cost-budget.sh
# declares its tables with `declare -A`, which inside a function is local.
# shellcheck source=bin/lib/cost-budget.sh
command -v cost_budget_daily >/dev/null 2>&1 || . "$_PC_LIB/cost-budget.sh" 2>/dev/null || true
# shellcheck source=bin/lib/budget-stop.sh
command -v _bs_spend >/dev/null 2>&1 || . "$_PC_LIB/budget-stop.sh" 2>/dev/null || true

_pc_root() { printf '%s' "${HARNESS:-${H:-}}"; }
# The UTC day of the alert ids. PROJECT_CEILING_DAY pins it in tests.
_pc_day() { printf '%s' "${PROJECT_CEILING_DAY:-$(date -u +%Y%m%d)}"; }

_pc_off() {
  if ! command -v lane_switch >/dev/null 2>&1; then
    # shellcheck source=bin/lib/lane-switch.sh
    [ -r "$_PC_LIB/lane-switch.sh" ] && { . "$_PC_LIB/lane-switch.sh" 2>/dev/null || true; }
    command -v lane_switch >/dev/null 2>&1 \
      || lane_switch() { [ -n "$(_pc_root)" ] && [ -f "$(_pc_root)/flags/$1" ]; }
  fi
  lane_switch project-ceiling-off file >/dev/null 2>&1
}

pc_eval() {
  local p="${1:-}" sp usd warn
  PC_SPENT=""; PC_CEIL=""; PC_PCT=""; PC_STATE=""; PC_REASON=""
  case "$p" in ''|*[!a-z0-9_-]*) return 1 ;; esac
  _pc_off && return 1
  command -v cost_budget_daily >/dev/null 2>&1 || return 1
  # Loaded once in this shell, so the $(…) below runs no second jq.
  cost_budget_daily_warn_pct >/dev/null
  PC_CEIL=$(cost_budget_daily "$p") || { PC_CEIL=""; return 1; }
  command -v _jobs_req >/dev/null 2>&1 && [ -n "${HARNESS_SECRET:-}" ] && [ -n "${JOBS_URL:-}" ] || return 3
  command -v _bs_spend >/dev/null 2>&1 || { PC_REASON="project-ceiling-unreadable:$p"; return 2; }
  sp=$(_bs_spend "$p") || { PC_REASON="project-ceiling-unreadable:$p"; return 2; }
  usd="${sp% *}"
  warn=$(cost_budget_daily_warn_pct)
  read -r PC_SPENT PC_PCT PC_STATE < <(awk -v s="$usd" -v c="$PC_CEIL" -v w="$warn" 'BEGIN{
    st = (s + 0 >= c + 0) ? "over" : ((s * 100 >= c * w) ? "warn" : "under")
    printf "%.2f %d %s\n", s, int(s * 100 / c), st }')
  [ -n "$PC_STATE" ] || { PC_REASON="project-ceiling-unreadable:$p"; return 2; }
  return 0
}

# _pc_alerts <project> — the day's one alert for the state pc_eval left.
_pc_alerts() {
  local p="$1" d root
  d=$(_pc_day); root=$(_pc_root)
  command -v _bs_alert_once >/dev/null 2>&1 || return 0
  case "$PC_STATE" in
    over)
      _bs_alert_once "project-ceiling-over-$p-$d" "$p" \
        "[project-ceiling] $p has spent \$$PC_SPENT today (UTC), at or over its daily ceiling of \$$PC_CEIL. No new build starts for $p until 00:00Z; running builds finish; hotfix builds still run."
      ;;
    warn)
      # No warn after the day's over alert: _bs_alert_once's over marker is
      # read here, never a second marker written (no-flag-files L1).
      [ -n "$root" ] && [ -e "$root/flags/alerted-project-ceiling-over-$p-$d" ] && return 0
      _bs_alert_once "project-ceiling-warn-$p-$d" "$p" \
        "[project-ceiling] $p has spent \$$PC_SPENT today (UTC), $PC_PCT% of its daily ceiling of \$$PC_CEIL. At 100% no new build starts until 00:00Z."
      ;;
  esac
  return 0
}

pc_launch_check() {
  local p="${1:-}" hf="${2:-0}" rc=0
  PC_LINE=""; PC_NOTE=""
  pc_eval "$p" || rc=$?
  case "$rc" in
    0)
      _pc_alerts "$p"
      [ "$PC_STATE" = over ] || return 0
      PC_LINE="project-ceiling project=$p usd=$PC_SPENT/$PC_CEIL"
      [ "$hf" = 1 ] && { PC_NOTE="$PC_LINE"; return 0; }
      return 1 ;;
    2)
      [ "$hf" = 1 ] && { PC_NOTE="$PC_REASON"; return 0; }
      return 2 ;;
  esac
  return 0
}

pc_stage_note() {
  case " $PC_STAGES " in *" ${2:-} "*) ;; *) return 0 ;; esac
  pc_eval "${1:-}" && _pc_alerts "$1"
  return 0
}
