#!/bin/bash
# bin/archie-fm.sh — BH-4583 (BH-4574.1): Archie, factory manager. A hub lane
# that reads every project's open PRs, finds the ones stuck in a known way, and
# runs ONE playbook for each. Two are known: a PR stacked on a parent that
# merged (stacked-parent-merged, bin/lib/archie-fm.sh), and a conductor park a
# merge of main could not get past (rebase-repair, bin/lib/archie-fm-repair.sh,
# BH-4585): append-only unions, regenerated drift, a flaky suite re-run once,
# else a fix round with Archie's diagnosis as its brief.
#
#   archie-fm.sh [tick] [--project <p>] [--pr <owner/repo#n>] | --dispatch
#     --dispatch is the cron line, every 10 minutes (BH-5944): it starts one
#     detached `archie-fm.sh tick --project <p>` per fleet project through the
#     per-project runner (bin/lib/project-lanes.sh, a 300 s window) and returns.
#     --project <p> alone is one project's tick: its lock is
#     locks/archie-fm-<p>.lock (the runner's fd 9) plus locks/archie-fm.lock
#     SHARED, and ARCHIE_FM_PROJECTS_PER_TICK does not apply. No argument (a
#     whole-fleet tick) and --pr keep the exclusive locks/archie-fm.lock.
#     --pr narrows one tick to one PR (the entrypoint a wake-up can call).
#
# TICK, in this order:
#   1. lane_gate_or_exit / lane_env_apply archie-fm; ARCHIE_FM_ENABLED=0 exits;
#      flock -n locks/archie-fm.lock (held = skip, never wait); NOW read once
#      (ARCHIE_FM_NOW only under HARNESS_TEST_SANDBOX=1).
#      THE TICK'S TIME (D21). The deadline is derived from the suite bound:
#      start + ARCHIE_FM_SUITE_TIMEOUT_S + 2 x AFM_TICK_SLACK_S (300 s). An
#      on-mode action starts only while a whole suite bound plus the slack is
#      left (else the PR waits for the next tick, no row), and a suite is
#      bounded by its knob or the time left, whichever is less, so the knob's
#      own "deferred, could not run" is what a slow suite meets. The outer
#      `timeout` is only the backstop for a hang: 4320 s, above the deadline at
#      the knob's maximum (3600 + 600 + 120), with a TERM trap (afm_on_term)
#      that undoes a half-done action and closes its row deferred.
#   2. per project (bin/fleet-conf.sh --projects, at most
#      ARCHIE_FM_PROJECTS_PER_TICK, starting one slot further round the list
#      each tick; a repo of `-` is skipped): the mode from the
#      settings rows archie.manage.<project> > archie.manage > `on`
#      (afm_mode). off = nothing else is read. Settings unreadable = the
#      project is skipped this tick, one log line.
#   3. ONE open-PR list read (100 a page; a full page logs `truncated` and
#      only what was read is acted on, so a cut list never reads as "nothing
#      stuck"); the conductor's row (pr-state.tsv) is carried as evidence and a
#      MERGED / CLOSED / ABANDONED row is skipped.
#   4. afm_classify; a PR that is not stacked-parent-merged is first looked
#      up by afm_recover_classify in the killed-tick ledger (mode on:
#      afm_recover_load reads today's and yesterday's started/deferred
#      restack rows once per project): a PR a tick retargeted and was killed
#      before pushing goes through the same claim and playbook as any stuck
#      PR (BH-4784). Otherwise it goes to afm_rr_classify (a
#      conflict-unresolvable / rebase-gate-red conductor park on its current
#      head, not a stacked child's), which runs afm_rr_one: the same skips as
#      5 and the rebase-repair playbook. Rebase-repair goes first: a parked PR
#      cannot merge, and a repair moves the head the data lane is bound to.
#      What that does not take goes to the data-lane playbook (dl_one_pr,
#      BH-4927), and what that does not take is only counted
#      (`unclassified`). dl_one_pr: the url from the conductor row
#      (else the list's), a MERGED / CLOSED / ABANDONED row is not a candidate;
#      afm_classify_data_lane; then skips, no row: a fork head, not a harness
#      build branch, a HOLD, the data-lane lane paused (lane_paused), and in
#      mode on less than AFM_DL_BOUND_S + the slack left in the tick. The PR
#      lock and a resolver hand-off are NOT skips: the lane pushes nothing, and
#      every BLOCKed PR is the resolver's. Then afm_dl_act.
#   5. skips, no row: a fork head, a HOLD (mc_hold_keeps_pr), a conductor
#      stack-follow record (the conductor owns it), the conductor's PR lock
#      held (flock -n: the conductor is working it; this lane never waits).
#      The PR lock is then held for the whole action.
#   6. afm_act: the day cap (mode on), the claim of the archie_actions row
#      BEFORE any write, then observe or the playbook, then the row closed.
#   7. one line in logs/archie-fm.log per tick that found a stuck PR:
#      <ts> projects=<n> prs=<n> stuck=<n> unclassified=<n> restacked=<n> fix_rounds=<n> would=<n> deferred=<n> skipped=<n> failed=<n> repaired=<n>
#      and one more per tick that found a data-lane candidate:
#      <ts> data_lane candidates=<n> applied=<n> would=<n> deferred=<n> skipped=<n> escalated=<n> failed=<n>
#
# NEVER: a merge, a push to main (hold_push refuses main/master/HEAD as the
# destination), a model call, or a state file of its own. PR code (suites,
# regenerators) runs only as `nobody` in a snapshot (afm_isolated). Every
# action is an archie_actions row (worker/jobs/src/routes/archie-actions.js).
#
# OFF: ARCHIE_FM_ENABLED=0, flags/lane-off-archie-fm, bin/harness-ctl.sh off
# archie-fm, or the settings row archie.manage=off (per project:
# archie.manage.<project>=off). Registry: catalog/lanes.d/archie-fm.json.
# Notes: docs/notes/2026-10-05-BH-4583-archie-fm-tracer.md,
# docs/notes/2026-10-05-BH-4585-archie-fm-playbooks.md.
# gh-rest: no-graphql
set -uo pipefail
H="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "$0")" && pwd)"
DISPATCH=0
[ "${1:-}" = --dispatch ] && [ $# = 1 ] && { DISPATCH=1; shift; }
[ "${1:-}" = tick ] && shift
ONLY_PROJECT=""; ONLY_PR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --project) ONLY_PROJECT="${2:-}"; shift 2 ;;
    --pr) ONLY_PR="${2:-}"; shift 2 ;;
    *) echo "usage: archie-fm.sh [tick] [--project <p>] [--pr <owner/repo#n>] | --dispatch" >&2; exit 2 ;;
  esac
done
if [ -n "$ONLY_PR" ] && ! [[ $ONLY_PR =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+$ ]]; then
  echo "archie-fm: --pr wants <owner/repo#n>, got '$ONLY_PR'" >&2; exit 2
fi
# shellcheck source=bin/lib/project-lanes.sh
[ -r "$H/bin/lib/project-lanes.sh" ] && . "$H/bin/lib/project-lanes.sh"
# One project's tick (BH-5944): --project with no --pr, on the runner's locks.
PROJECT_RUN=0
if [ -n "$ONLY_PROJECT" ] && [ -z "$ONLY_PR" ]; then
  command -v pl_project_known >/dev/null 2>&1 && pl_project_known "$ONLY_PROJECT" || {
    echo "archie-fm: fleet.conf names no project '$ONLY_PROJECT' (or bin/lib/project-lanes.sh is missing)" >&2; exit 2; }
  PROJECT_RUN=1
fi
if [ "$DISPATCH" = 0 ] && [ "${ARCHIE_FM_TIMED:-}" != 1 ] && command -v timeout >/dev/null 2>&1; then
  CEIL=4320
  # The suite's seam for a tick that outlives its backstop. Sandbox only.
  if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [[ ${ARCHIE_FM_TICK_CEILING_S:-} =~ ^[0-9]+$ ]]; then CEIL=$ARCHIE_FM_TICK_CEILING_S; fi
  ARCHIE_FM_TIMED=1 exec timeout -k 60 "$CEIL" bash "$0" tick ${ONLY_PROJECT:+--project "$ONLY_PROJECT"} ${ONLY_PR:+--pr "$ONLY_PR"}
fi
. "$H/bin/lib/env-path.sh" 2>/dev/null || . "$SELF/lib/env-path.sh" 2>/dev/null \
  || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }
HENV=$(harness_env_dir "$H")
# shellcheck disable=SC1091
[ -r "$HENV/global.env" ] && { set -a; . "$HENV/global.env" 2>/dev/null; set +a; }
# shellcheck disable=SC1091
{
  . "$H/bin/lib/lane-gate.sh" 2>/dev/null || . "$SELF/lib/lane-gate.sh" 2>/dev/null || true
  . "$SELF/jobs-client.sh" 2>/dev/null || true
  . "$SELF/lib/gh-rest.sh" 2>/dev/null || true
  . "$SELF/lib/merge-conductor-lib.sh" 2>/dev/null || true
  . "$SELF/lib/flaky.sh" 2>/dev/null || true
  . "$SELF/lib/archie-fm.sh" 2>/dev/null || true
  . "$SELF/lib/archie-fm-repair.sh" 2>/dev/null || true
  # Optional: a tree without the data-lane contract still restacks, and simply
  # finds no data-lane candidates (afm_classify_data_lane answers rc 1).
  . "$SELF/lib/data-lane.sh" 2>/dev/null || true
}
# The suite's seam. Sandbox only, and settable:false in the registry.
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [ -n "${ARCHIE_FM_FIXTURE:-}" ]; then
  # shellcheck disable=SC1090
  . "$ARCHIE_FM_FIXTURE"
fi
for f in afm_act afm_on_term afm_fork_point afm_recover_load afm_recover_classify afm_rr_one afm_rr_classify _jobs_req setting_get gh_rest_pr_list_var mc_init mc_transition mc_retarget_base; do
  command -v "$f" >/dev/null 2>&1 || { echo "archie-fm: $f is not defined (a lib is missing)" >&2; exit 1; }
done
command -v jq >/dev/null 2>&1 || { echo "archie-fm: jq missing" >&2; exit 1; }

NOW=""
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [[ ${ARCHIE_FM_NOW:-} =~ ^[0-9]+$ ]]; then NOW=$ARCHIE_FM_NOW; fi
[ -n "$NOW" ] || NOW=$(date -u +%s)
DAY=$(date -u -d "@$NOW" +%F)
mkdir -p "$H/logs" "$H/locks" 2>/dev/null
AFM_LOG="$H/logs/archie-fm.log"
AFM_H="$H"
log() { afm_log "$@"; }

# knob_int <name> <value> <default> <min> <max>: out of range is one warn line
# and the default, never a silent clamp (D11).
knob_int() {
  local v=$2
  if [[ $v =~ ^[0-9]+$ ]] && [ "$((10#$v))" -ge "$4" ] && [ "$((10#$v))" -le "$5" ]; then
    printf '%s' "$((10#$v))"
  else
    log "warn: $1=$v is outside $4..$5; using the default $3"
    printf '%s' "$3"
  fi
}

command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit archie-fm
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply archie-fm
case "${ARCHIE_FM_ENABLED:-1}" in
  0) exit 0 ;;
  1) ;;
  *) log "warn: ARCHIE_FM_ENABLED=${ARCHIE_FM_ENABLED} is not 0 or 1; using the default 1" ;;
esac
if [ "$DISPATCH" = 1 ]; then
  if ! command -v pl_lane_dispatch >/dev/null 2>&1; then
    echo "$(date -u +%FT%TZ) archie-fm dispatch: bin/lib/project-lanes.sh is not loaded — no project run started"
    exit 1
  fi
  rc=0; line=$(pl_lane_dispatch archie-fm 300 "$H/bin/archie-fm.sh" tick --project) || rc=$?
  echo "$(date -u +%FT%TZ) $line"
  exit "$rc"
fi
if [ "$PROJECT_RUN" = 1 ]; then
  # The runner already holds fd 9; it is never re-opened here.
  pl_lane_lock archie-fm "$ONLY_PROJECT" || exit 0
else
  exec 9>"$H/locks/archie-fm.lock" || exit 0
  flock -n 9 || exit 0
fi

AFM_RETRY_S=$(knob_int ARCHIE_FM_RETRY_S "${ARCHIE_FM_RETRY_S:-1800}" 1800 60 86400)
AFM_MAX_ATT=$(knob_int ARCHIE_FM_MAX_ATTEMPTS "${ARCHIE_FM_MAX_ATTEMPTS:-3}" 3 1 10)
AFM_SUITE_TIMEOUT_S=$(knob_int ARCHIE_FM_SUITE_TIMEOUT_S "${ARCHIE_FM_SUITE_TIMEOUT_S:-900}" 900 60 3600)
MAXP=$(knob_int ARCHIE_FM_PROJECTS_PER_TICK "${ARCHIE_FM_PROJECTS_PER_TICK:-0}" 0 0 100)
AFM_DEADLINE=$(( $(date +%s) + AFM_SUITE_TIMEOUT_S + 2 * AFM_TICK_SLACK_S ))
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [[ ${ARCHIE_FM_DEADLINE:-} =~ ^[0-9]+$ ]]; then AFM_DEADLINE=$ARCHIE_FM_DEADLINE; fi
trap 'afm_on_term; exit 143' TERM INT HUP
mc_init

NPROJ=0; NPRS=0; STUCK=0; UNCL=0; RESTACKED=0; FIXR=0; WOULD=0; DEFER=0; SKIPPED=0; FAILED=0; REPAIRED=0
DL_CAND=0; DL_APPLIED=0; DL_WOULD=0; DL_DEFER=0; DL_SKIP=0; DL_ESC=0; DL_FAILED=0

# count_result — the tick's counters from AFM_RESULT.
count_result() {
  case "$AFM_RESULT" in
    restacked) RESTACKED=$((RESTACKED + 1)) ;;
    repaired) REPAIRED=$((REPAIRED + 1)) ;;
    fix_round) FIXR=$((FIXR + 1)) ;;
    would) WOULD=$((WOULD + 1)) ;;
    deferred) DEFER=$((DEFER + 1)) ;;
    failed) FAILED=$((FAILED + 1)) ;;
    noop) ;;
    *) SKIPPED=$((SKIPPED + 1)) ;;
  esac
}

# dl_one_pr <project> <slug> <mode> <pr-json> -> rc 0 when the data-lane
#   playbook took the PR (acted on it, or skipped it with a log line), rc 1
#   when it is not a data-lane candidate. Reads the conductor row; writes no
#   conductor, resolver or build state.
dl_one_pr() {
  local p="$1" slug="$2" mode="$3" pr="$4" n br hrepo row cst url rc dir file head left
  n=$(jq -r .number <<<"$pr"); br=$(jq -r '.head.ref // ""' <<<"$pr")
  hrepo=$(jq -r '.head.repo.full_name // ""' <<<"$pr")
  row=$(mc_row_get "$slug#$n"); cst=$(cut -f2 <<<"$row")
  case "$cst" in MERGED|CLOSED|ABANDONED) return 1 ;; esac
  url=$(cut -f8 <<<"$row"); [ -n "$url" ] || url=$(jq -r '.html_url // ""' <<<"$pr")
  [ -n "$url" ] || return 1
  rc=0; afm_classify_data_lane "$p" "$slug" "$pr" "$url" || rc=$?
  case "$rc" in
    0) ;;
    2) log "$slug#$n: data-lane: the PR file list could not be read (HTTP ${GH_REST_STATUS:-000}); skipped this tick"
       DL_SKIP=$((DL_SKIP + 1)); return 0 ;;
    *) return 1 ;;
  esac
  DL_CAND=$((DL_CAND + 1))
  IFS=$'\t' read -r dir file head <<<"$AFM_DL"
  if [ "$hrepo" != "$slug" ]; then
    log "$slug#$n: data-lane: the head lives in ${hrepo:-an unknown repo}, not $slug; not Archie's"
    DL_SKIP=$((DL_SKIP + 1)); return 0
  fi
  if ! afm_harness_branch "$br"; then
    log "$slug#$n: data-lane: $br is not a harness build branch; not Archie's"
    DL_SKIP=$((DL_SKIP + 1)); return 0
  fi
  if mc_hold_keeps_pr "$slug" "$n"; then
    log "$slug#$n: data-lane: the ticket is on HOLD; nothing done"; DL_SKIP=$((DL_SKIP + 1)); return 0
  fi
  # lane-gate's own read of the data-lane switch (all-off, lane-off-data-lane,
  # their settings rows), the one bin/data-lane-apply.sh exits on.
  if command -v lane_paused >/dev/null 2>&1 && lane_paused data-lane; then
    log "$slug#$n: data-lane: the data-lane lane is off (${LANE_PAUSED_WHY:-paused}); nothing done"
    DL_SKIP=$((DL_SKIP + 1)); return 0
  fi
  left=$(afm_time_left)
  if [ "$mode" = on ] && [ "$left" -lt $(( AFM_DL_BOUND_S + AFM_TICK_SLACK_S )) ]; then
    log "$slug#$n: data-lane: ${left}s left in this tick, under an apply bound + slack ($((AFM_DL_BOUND_S + AFM_TICK_SLACK_S))s); waits for the next tick"
    DL_SKIP=$((DL_SKIP + 1)); return 0
  fi
  afm_dl_act "$p" "$slug" "$n" "$mode" "$head" "$dir" "$file"
  case "$AFM_RESULT" in
    applied) DL_APPLIED=$((DL_APPLIED + 1)) ;;
    would) DL_WOULD=$((DL_WOULD + 1)) ;;
    deferred) DL_DEFER=$((DL_DEFER + 1)) ;;
    escalated) DL_ESC=$((DL_ESC + 1)) ;;
    failed) DL_FAILED=$((DL_FAILED + 1)) ;;
    *) DL_SKIP=$((DL_SKIP + 1)) ;;
  esac
  return 0
}

# one_pr <project> <slug> <mode> <pr-json>
one_pr() {
  local p="$1" slug="$2" mode="$3" pr="$4" n br head hrepo row cst rc pn purl phead target obase left rsn
  n=$(jq -r .number <<<"$pr"); br=$(jq -r '.head.ref // ""' <<<"$pr"); head=$(jq -r '.head.sha // ""' <<<"$pr")
  hrepo=$(jq -r '.head.repo.full_name // ""' <<<"$pr")
  [[ $n =~ ^[0-9]+$ ]] || return 0
  [ -z "$ONLY_PR" ] || [ "$ONLY_PR" = "$slug#$n" ] || return 0
  NPRS=$((NPRS + 1))
  rc=0; afm_classify "$p" "$slug" "$pr" || rc=$?
  if [ "$rc" = 1 ] && afm_recover_classify "$pr"; then
    log "$slug#$n: retargeted to $(jq -r '.base.ref' <<<"$pr") by a tick that died before its push; replaying it"
    rc=0
  fi
  case "$rc" in
    0) ;;
    1) # Not a stacked child: a conductor park this lane repairs (BH-4585)?
       if afm_rr_classify "$p" "$slug" "$pr"; then
         STUCK=$((STUCK + 1))
         afm_rr_one "$p" "$slug" "$n" "$mode" "$br" "$head" "$hrepo"
         count_result; return 0
       fi
       # Then a data-lane migration this lane applies ahead of merge (BH-4927).
       dl_one_pr "$p" "$slug" "$mode" "$pr" && return 0
       UNCL=$((UNCL + 1)); return 0 ;;
    *) log "$slug#$n: the parent PR could not be read (HTTP ${GH_REST_STATUS:-000}); skipped this tick"
       SKIPPED=$((SKIPPED + 1)); return 0 ;;
  esac
  STUCK=$((STUCK + 1))
  IFS=$'\t' read -r pn purl phead target <<<"$AFM_PARENT"
  obase="$AFM_CHILD_BASE"
  row=$(mc_row_get "$slug#$n"); cst=$(cut -f2 <<<"$row"); cst=${cst:--}
  case "$cst" in
    MERGED|CLOSED|ABANDONED) log "$slug#$n: the conductor row says $cst; skipped"; SKIPPED=$((SKIPPED + 1)); return 0 ;;
  esac
  # The blocked-resolver's hand-offs are its own (review I4, 2026-10-06): a fix
  # round already running on this branch would only lose its push to our lease.
  rsn=$(cut -f7 <<<"$row")
  if [ -n "$rsn" ] && mc_handoff_owns "$rsn"; then
    log "$slug#$n: bin/blocked-resolver.sh owns this PR ($rsn); not Archie's"
    SKIPPED=$((SKIPPED + 1)); return 0
  fi
  if [ "$hrepo" != "$slug" ]; then
    log "$slug#$n: the head lives in ${hrepo:-an unknown repo}, not $slug; this lane does not push it"
    SKIPPED=$((SKIPPED + 1)); return 0
  fi
  if ! [[ $head =~ ^[0-9a-f]{40}$ ]] || [ -z "$br" ]; then
    log "$slug#$n: the list read had no head sha or branch; skipped"; SKIPPED=$((SKIPPED + 1)); return 0
  fi
  # Harness-built PRs only (review B1/I1, 2026-10-06). Both this PR's head and
  # the merged parent's head (this PR's base) must be harness build branches,
  # ticket/<key>[-rN]. A person's branch (agent/TK-340, a developer's own) or a
  # long-lived base (develop, staging) never matches, so Archie never rewrites,
  # retargets or parks a PR the harness did not build.
  if ! afm_harness_branch "$br" || ! afm_harness_branch "$obase"; then
    log "$slug#$n: $br on $obase is not a harness build branch pair; not Archie's to restack"
    SKIPPED=$((SKIPPED + 1)); return 0
  fi
  if mc_stack_pending_get "$slug" "$n" >/dev/null 2>&1; then
    log "$slug#$n: the conductor owes this child a stack-follow; it is the conductor's"
    SKIPPED=$((SKIPPED + 1)); return 0
  fi
  if mc_hold_keeps_pr "$slug" "$n"; then
    log "$slug#$n: the ticket is on HOLD; nothing done"; SKIPPED=$((SKIPPED + 1)); return 0
  fi
  # The push guard's own hold read, which fails CLOSED (review I3): this lane
  # writes (a retarget, a park) before and after the push, so an unreadable
  # hold is no hold-free pass here, unlike mc_hold_keeps_pr's fail-open read.
  rc=0; { { command -v hold_push_verdict >/dev/null 2>&1 || mc_hold_push_load; } && hold_push_verdict "$p" - "$br" >/dev/null 2>&1; } || rc=$?
  if [ "$rc" != 0 ]; then
    log "$slug#$n: the hold read says $([ "$rc" = 1 ] && echo held || echo unreadable) (rc=$rc); nothing done"
    SKIPPED=$((SKIPPED + 1)); return 0
  fi
  # An on-mode action starts only with a whole suite bound and the slack left;
  # anything later waits for the next tick, before any row is claimed.
  left=$(afm_time_left)
  if [ "$mode" = on ] && [ "$left" -lt $(( AFM_SUITE_TIMEOUT_S + AFM_TICK_SLACK_S )) ]; then
    log "$slug#$n: ${left}s left in this tick, under a suite bound + slack ($((AFM_SUITE_TIMEOUT_S + AFM_TICK_SLACK_S))s); waits for the next tick"
    SKIPPED=$((SKIPPED + 1)); return 0
  fi
  # >>> pr lock
  # The conductor's own PR lock, taken with -n and held for the whole action:
  # the conductor's worker skips this PR meanwhile, and this lane never waits.
  exec 8>"$(mc_pr_lock "$p" "$n")" || { SKIPPED=$((SKIPPED + 1)); return 0; }
  if ! flock -n 8; then
    exec 8>&-
    log "$slug#$n: the conductor holds its PR lock; skipped this tick"; SKIPPED=$((SKIPPED + 1)); return 0
  fi
  afm_act "$p" "$slug" "$n" "$mode" "$br" "$head" "$pn" "$purl" "$phead" "$target" "$cst" "$obase"
  flock -u 8; exec 8>&-
  # <<< pr lock
  count_result
}

read -r -a PROJS <<<"$("$H/bin/fleet-conf.sh" --projects 2>/dev/null | tr '\n' ' ')"
if [ "${#PROJS[@]}" = 0 ]; then
  log "warn: bin/fleet-conf.sh --projects answered nothing; nothing read"
  exit 0
fi
# Each tick starts one slot further round the list, so a per-tick cap below the
# project count still reaches every project in turn instead of starving the
# tail of fleet.conf.
START=$(( (NOW / 600) % ${#PROJS[@]} ))
for P in "${PROJS[@]:$START}" "${PROJS[@]:0:$START}"; do
  [ -z "$ONLY_PROJECT" ] || [ "$ONLY_PROJECT" = "$P" ] || continue
  SLUG=$("$H/bin/fleet-conf.sh" "$P" repo 2>/dev/null)
  case "$SLUG" in */*) ;; *) continue ;; esac
  [ -z "$ONLY_PR" ] || [ "${ONLY_PR%#*}" = "$SLUG" ] || continue
  if [ "$PROJECT_RUN" = 0 ] && [ "$MAXP" -gt 0 ] && [ "$NPROJ" -ge "$MAXP" ]; then
    log "ARCHIE_FM_PROJECTS_PER_TICK=$MAXP reached; $P and the rest wait for the next tick"; break
  fi
  if ! MODE=$(afm_mode "$P"); then
    log "$P: the archie.manage settings could not be read; skipped this tick (no action without the ledger)"
    continue
  fi
  [ "$MODE" = off ] && continue
  NPROJ=$((NPROJ + 1))
  rc=0; gh_rest_pr_list_var LIST "$SLUG" open "" 100 || rc=$?
  if [ "$rc" != 0 ] || ! jq -e 'type == "array"' <<<"$LIST" >/dev/null 2>&1; then
    log "$P: the open PR list could not be read (rc=$rc HTTP ${GH_REST_STATUS:-000}); skipped this tick"
    continue
  fi
  [ "$(jq length <<<"$LIST")" -ge 100 ] && log "$P: the open PR list is a full page (100), truncated; only what was read is acted on"
  AFM_OPEN_LIST="$LIST"; AFM_RECOVER=""
  [ "$MODE" = on ] && { afm_recover_load "$P" || true; }
  while IFS= read -r PR; do
    [ "$AFM_ROUTE_ABSENT" = 1 ] && break
    one_pr "$P" "$SLUG" "$MODE" "$PR"
  done < <(jq -c '.[]' <<<"$LIST")
  [ "$AFM_ROUTE_ABSENT" = 1 ] && break
done
[ "$AFM_ROUTE_ABSENT" = 1 ] && log "archie_actions route absent (HTTP 404 from the jobs worker); nothing done"
[ $((DL_CAND + DL_SKIP)) -gt 0 ] && log "data_lane candidates=$DL_CAND applied=$DL_APPLIED would=$DL_WOULD deferred=$DL_DEFER skipped=$DL_SKIP escalated=$DL_ESC failed=$DL_FAILED"
[ "$STUCK" -gt 0 ] && log "projects=$NPROJ prs=$NPRS stuck=$STUCK unclassified=$UNCL restacked=$RESTACKED fix_rounds=$FIXR would=$WOULD deferred=$DEFER skipped=$SKIPPED failed=$FAILED repaired=$REPAIRED"
exit 0
