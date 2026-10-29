#!/bin/bash
# bin/lib/web-task/route.sh — the build pipeline's web-task dispatch (BH-7594).
#
# A ticket of kind web-task asks the harness to do a task in a website. It is
# never planned, built or turned into a PR: the `# >>> web-task hook (BH-7594)`
# block in bin/lib/rb/plan.sh calls wt_route after the untrusted input gate
# (so an injection-shaped ticket under block mode is refused before any web
# spend) and before any plan model call, and writes the answer as the build's
# RESULT.
#
#   wt_route <project> <ticket> <KEY> <job-id> <kind-hint> <kind-hint-source>
#     Sets WT_LINE and returns:
#       0  WT_LINE is the RESULT: WEBTASK_QUEUED (one lane_runs row for the
#          web-task lane, bin/web-task.sh <ticket> <KEY> <job-id>) or
#          WEBTASK_FAILED <why> (not placed on fly, no placement lib, the
#          enqueue failed). The build exits 0.
#       3  WT_LINE is BUILD_DEFERRED (a web-task run of this project is
#          already live, the jobs worker's one live row per lane and project,
#          fleet.conf could not be read, the lane is paused or factory-stop
#          is on: nothing is enqueued and the next tick re-offers the ticket)
#          or BUILD_REFUSED (an in-app board project, or no repo).
#          The build exits 3.
#       1  not a web-task: WT_LINE is empty and the plan path runs as before.
#
# ONLY THE BOARD SAYS web-task: the hint must come from a board type field or a
# GitHub label (bin/kind-gate.sh's `type=` / `label=` sources). A title prefix
# is the weakest evidence the board has, and a wrong route spends money and
# posts a comment on a client's ticket, so a title never routes here.
#
# ONLY A GITHUB-ISSUE PROJECT, IN S1: the lane reads the ticket and posts its
# result as GitHub issue <ticket> of the project's repo. An in-app board
# project (fleet.conf board-api-prefix not "-") numbers its tickets on its own
# board, so issue <ticket> of its repo is some other issue. wt_issue_project
# answers which kind a project is, through the tracker seam (tracker_kind in
# bin/lib/tracker.sh, BH-7919): a Linear or Jira project also says "-" in
# fleet.conf, and it is no GitHub-issue project either. An in-app board project gets BUILD_REFUSED,
# the word every in-app prompt already closes with one ALERTS line and no
# comment, so the WEBTASK_* words only ever reach a GitHub-issue project.
#
# ONLY FLY RUNS IT: the lane-run image is the one image that carries the browser
# and the playwright module. Any placement but fly is WEBTASK_FAILED, never an
# inline run on this box.
#
# Root: ${HARNESS:-${H:-}} only (BH-2613).
# shellcheck shell=bash

# wt_issue_project <project> — rc 0 and the repo slug on stdout when the
# project's tickets are GitHub issues (tracker_kind is github-issues). rc 1 for
# any other tracker (an in-app board, Jira, Linear), rc 3 when fleet.conf names
# no valid repo, rc 2 when the tracker or the repo cannot be read.
wt_issue_project() {
  local p="${1:-}" root kind repo
  root="${HARNESS:-${H:-}}"
  [ -n "$root" ] && [ -x "$root/bin/fleet-conf.sh" ] || return 2
  if ! command -v tracker_kind >/dev/null 2>&1; then
    # shellcheck source=bin/lib/tracker.sh
    [ -r "$root/bin/lib/tracker.sh" ] && . "$root/bin/lib/tracker.sh"
  fi
  command -v tracker_kind >/dev/null 2>&1 || return 2
  kind=$(tracker_kind "$p" 2>/dev/null) || return 2
  repo=$("$root/bin/fleet-conf.sh" "$p" repo 2>/dev/null) || return 2
  [ "$kind" = github-issues ] || return 1
  [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 3
  printf '%s' "$repo"
}

wt_route() {
  local p="${1:-}" ticket="${2:-}" key="${3:-}" job="${4:-}" hint="${5:-}" src="${6:-}" root rc=0
  WT_LINE=""
  [ "$hint" = web-task ] || return 1
  case "$src" in label=*|type=*) ;; *) return 1 ;; esac
  root="${HARNESS:-${H:-}}"
  wt_issue_project "$p" >/dev/null; rc=$?
  case "$rc" in
    0) ;;
    1) WT_LINE="BUILD_REFUSED web-task: $p is an in-app board project, and web-task S1 answers on GitHub issues only — nothing was run"; return 3 ;;
    3) WT_LINE="BUILD_REFUSED web-task: fleet.conf names no repo for $p — nothing was run"; return 3 ;;
    *) WT_LINE="BUILD_DEFERRED web-task: cannot read fleet.conf for $p — the next tick re-offers $key"; return 3 ;;
  esac
  # A stopped lane enqueues nothing (BH-7594 fix round). lane_gate_or_exit in
  # bin/web-task.sh would stop the run, but only after a lane-run machine
  # booted, and ai-build stays on the issue, so every tick would pay one pool
  # build plus one machine boot. The operator's stop (all-off, lane-off-web-task,
  # lane-off-web-task-<p>) and switch.factory-stop (web-task is a factory_stop
  # launch lane) answer BUILD_DEFERRED here instead: no row, no machine. A box
  # without the libs reads as not stopped, the same fail-open as lane-gate.
  if ! command -v lane_paused >/dev/null 2>&1; then
    # shellcheck source=bin/lib/lane-gate.sh
    [ -n "$root" ] && [ -r "$root/bin/lib/lane-gate.sh" ] && . "$root/bin/lib/lane-gate.sh" >/dev/null 2>&1
  fi
  if command -v lane_paused >/dev/null 2>&1 && lane_paused web-task "$p"; then
    WT_LINE="BUILD_DEFERRED web-task: lane paused (${LANE_PAUSED_WHY:-lane-off}) — nothing was enqueued; the next tick re-offers $key"
    return 3
  fi
  if ! command -v factory_stopped >/dev/null 2>&1; then
    # shellcheck source=bin/lib/factory-stop.sh
    [ -n "$root" ] && [ -r "$root/bin/lib/factory-stop.sh" ] && . "$root/bin/lib/factory-stop.sh" >/dev/null 2>&1
  fi
  if command -v factory_stopped >/dev/null 2>&1 && factory_stopped; then
    WT_LINE="BUILD_DEFERRED web-task: factory-stop is on — nothing was enqueued; the next tick re-offers $key"
    return 3
  fi
  if ! command -v lp_decide >/dev/null 2>&1 || ! command -v lp_enqueue >/dev/null 2>&1; then
    # shellcheck source=bin/lib/lane-placement.sh
    [ -n "$root" ] && [ -r "$root/bin/lib/lane-placement.sh" ] && . "$root/bin/lib/lane-placement.sh"
  fi
  if ! command -v lp_decide >/dev/null 2>&1 || ! command -v lp_enqueue >/dev/null 2>&1; then
    WT_LINE="WEBTASK_FAILED the lane-placement lib is missing on $(hostname 2>/dev/null || echo this box)"
    return 0
  fi
  LP_PLACE=hub; LP_WHY=""
  lp_decide web-task "$p"
  if [ "$LP_PLACE" != fly ]; then
    WT_LINE="WEBTASK_FAILED lane web-task is not placed on fly for $p ($LP_WHY)"
    return 0
  fi
  lp_enqueue web-task "$p" "$root/bin/web-task.sh" "$ticket" "$key" "$job" || rc=$?
  case "$rc" in
    0) WT_LINE="WEBTASK_QUEUED lane-run row for $p/$key"; return 0 ;;
    3) WT_LINE="BUILD_DEFERRED web-task: a web-task run for $p is already live — the next tick re-offers $key"; return 3 ;;
    *) WT_LINE="WEBTASK_FAILED could not enqueue the lane-run row (lp_enqueue rc $rc)"; return 0 ;;
  esac
}
