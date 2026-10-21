#!/bin/bash
# shellcheck shell=bash
# bin/lib/mc/tick-scope.sh — the conductor's tick scope: which PRs this run
# ticks, and what it may do to them. Sourced by bin/merge-conductor.sh only,
# never run, and deliberately not a module: it has no module header, so
# mm_load never loads it and the scripts that source
# bin/lib/merge-conductor-lib.sh never see its functions.
# The driver refuses the tick when this file is missing or unusable.
#
# mc_keyed_tick_parse
#   Reads MC_ONLY_PR and sets MC_ONLY_KEYS (globals, no `local`: the driver and
#   bin/lib/mc/classify.sh's mc_only_slug read them after the call). Needs
#   mc_log. On a keyed tick it replaces mc_tick_metrics with a no-op for the
#   rest of the process.
#
# mc_full_tick_window
#   Reads MC_ONLY_KEYS (so it runs after mc_keyed_tick_parse),
#   MC_WORKERS_DONE_BY and MC_FULL_TICK_BUDGET_S. On an unkeyed tick with no
#   caller window it sets MC_WORKERS_DONE_BY and MC_WINDOW_NEXT (globals, no
#   `local`, never exported). Needs mc_log.
#
# mc_keyed_deadline_floor (BH-7376)
#   On a keyed tick whose launcher set MC_KEYED_READY_FLOOR=1, sets
#   MC_WORKER_DEADLINE_MIN_S to MC_KEYED_READY_ARM_S (global, not exported)
#   unless the caller set it, so a READY row's worker can run the whole READY
#   arm. Runs after mc_keyed_tick_parse.
#
# mc_ready_first <slug> <row>... (BH-7376)
#   The open-list rows with the READY rows (MC_ROWS) first, one a line.
#
# mc_tick_mode
#   Reads the four fleet flags through flag_on (defined by the driver, which
#   BH-685 keeps there, so this runs after flag_on is defined) and the fleet
#   merges pause through pause_active. Sets KILL, ACTIONS, MERGES and MODE
#   (globals, no `local`, never exported) and the exported MC_MODE. Needs
#   mc_log.
#
# mc_tick_prelude
#   Sets the tick's spend budgets (REBASE_BUDGET, REREVIEW_BUDGET,
#   MERGE_BUDGET), the isInMergeQueue knobs (MC_LIST_INQUEUE,
#   MC_INQUEUE_PROBE_TTL_SECS, MC_INQUEUE_STATES), REREVIEW_CAP and CAPFILE
#   (it touches the day's cap file) and MC_TICK_ID. All are globals, no
#   `local`. It exports MC_TICK_ID and the knobs the detached lanes re-read.
#   Reads MC_STATE_DIR, so it runs after mc_init. Needs mc_tick_id.
#
# THE KEYED TICK (BH-1387). bin/wake-loop.sh may hand this run the PR keys it
# drained, as MC_ONLY_PR=owner/repo#n[,owner/repo#n…]; the run then does only
# those PRs and none of the fleet sweeps, which stay the cron tick's. Parsed
# ONCE, with `read -a` so a key crossing the process boundary is never globbed
# against the cwd. Empty = today's tick. A value with no valid key is a full
# tick plus one line: wake-loop never writes one, and doing everything is what
# an unkeyed launch does anyway. Keys are lowercased and deduped on that form
# (BH-1841: GitHub slugs are case-insensitive); the log line shows each key as
# the caller first spelled it.
mc_keyed_tick_parse() {
MC_ONLY_KEYS=""; _mc_only_shown=""
if [ -n "${MC_ONLY_PR:-}" ]; then
  IFS=, read -r -a _mc_only_toks <<<"$MC_ONLY_PR"
  for _t in "${_mc_only_toks[@]}"; do
    [[ "$_t" =~ ^[^#[:space:]]+#[0-9]+$ ]] || continue
    case "$MC_ONLY_KEYS" in
      *" ${_t,,} "*) ;;
      *) MC_ONLY_KEYS="${MC_ONLY_KEYS:- }${_t,,} "; _mc_only_shown="${_mc_only_shown:+$_mc_only_shown,}$_t" ;;
    esac
  done
  if [ -z "$MC_ONLY_KEYS" ]; then
    mc_log "MC_ONLY_PR ignored: '$MC_ONLY_PR' holds no owner/repo#number key — running the full tick"
  else
    _k="${MC_ONLY_KEYS# }"; _k="${_k% }"; _n=$(wc -w <<<"$_k")
    mc_log "keyed tick: $_n key(s) — $_mc_only_shown"
    # tick-<p>.json is the cadence hold's clock (BH-1486): a keyed tick reads the
    # hold and never restarts it, or every wake would push back that project's
    # full sweep.
    mc_tick_metrics() { :; }
  fi
fi
}
# >>> full-tick window (BH-5521)
# The full tick is the hourly safety sweep, and it is BOUNDED: a worker starts
# only while MC_FULL_TICK_BUDGET_S (default 1500 s, 0 = no bound) has room for
# it, through the BH-4842 window (mc_window_cap). A PR that does not fit is
# accounted deferred:window and logged; the next wake for it or the next sweep
# takes it. A caller's own window (the keyed backstop) wins. Plain assignment,
# never exported: a detached lane must not inherit this tick's deadline.
mc_full_tick_window() {
if [ -z "$MC_ONLY_KEYS" ] && ! [[ "${MC_WORKERS_DONE_BY:-}" =~ ^[0-9]+$ ]]; then
  _mc_ftb="${MC_FULL_TICK_BUDGET_S:-1500}"
  [[ "$_mc_ftb" =~ ^[0-9]+$ ]] || _mc_ftb=1500
  if [ "$_mc_ftb" -gt 0 ]; then
    MC_WORKERS_DONE_BY=$(( $(date +%s) + _mc_ftb ))
    MC_WINDOW_NEXT="the next hourly sweep or a wake for this PR takes it"
    export -n MC_WORKERS_DONE_BY MC_WINDOW_NEXT 2>/dev/null
    mc_log "full tick: worker window ${_mc_ftb}s (MC_FULL_TICK_BUDGET_S) — a PR that does not fit is deferred, not started"
  fi
fi
}
# <<< full-tick window (BH-5521)
# >>> keyed READY-arm floor (BH-7376)
# A keyed run is how one READY PR gets merged: the backstop fire, the wake lane
# and the READY re-kick past its TTL all start one. Its PR worker must have time
# for the whole READY arm (dep-gate, ticket-hold, prequeue, state-guard,
# enqueue). On the hub (2026-10-17/18) prequeue alone took up to 265 s on
# cromford and 290 s on project-5, and enqueue 90 s, while the worker
# deadline was 180 s: #7361 was killed in prequeue on every run for 316 min.
# MC_KEYED_READY_ARM_S (lane merge-conductor, default 490 s: prequeue p95 ~290 s
# + the enqueue step floor 130 s + 70 s for the other steps) is the floor of a
# keyed run's worker deadline (MC_WORKER_DEADLINE_MIN_S) and of its prequeue
# step's timeout, read by mc_worker_deadline_s and mc_step_timeout_s.
# OPT-IN (BH-7376 review): only a launcher that sets MC_KEYED_READY_FLOOR=1
# gets it. Those are the backstop (its timeout and cap are sized from the same
# knob), the keyed pool and kw_conductor's direct launch (no `timeout` over
# them). pr-owner-sweep and the archie queue kick run keyed under `timeout 240`
# with no cap: a 490 s worker there would outlive the timeout, which then kills
# the whole group (BH-4918). The floor applies only to a READY row
# (_mc_floor_row). A full tick is unchanged. Plain assignments, never exported:
# a run this one starts opts in, or not, on its own.
mc_keyed_ready_arm_s() {
  local v="${MC_KEYED_READY_ARM_S:-490}"
  [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -gt 0 ] || v=490
  printf '%s\n' "$v"
}
mc_keyed_deadline_floor() {
  local opt="${MC_KEYED_READY_FLOOR:-}"
  export -n MC_KEYED_READY_FLOOR 2>/dev/null
  [ "$opt" = 1 ] && [ -n "${MC_ONLY_KEYS:-}" ] || return 0
  [[ "${MC_WORKER_DEADLINE_MIN_S:-}" =~ ^[0-9]+$ ]] && return 0
  MC_WORKER_DEADLINE_MIN_S=$(mc_keyed_ready_arm_s)
  export -n MC_WORKER_DEADLINE_MIN_S 2>/dev/null
  return 0
}
# <<< keyed READY-arm floor (BH-7376)
# >>> READY first (BH-7376)
# mc_ready_first <slug> <row>... — prints the open-list rows, one a line, with
# every row whose pr-state.tsv state is READY first, then the rest, each group
# in its list order. The full tick's worker window (MC_FULL_TICK_BUDGET_S) ran
# out before it reached READY rows (137-151 WINDOW_DEFERRED lines an hour on
# 2026-10-17): a merge must never wait behind WAIT_CI and HEAD_MOVED re-reads.
# One read of MC_ROWS; no file or no READY row keeps the order as it is.
mc_ready_first() {
  local slug="$1" ready r; shift
  local -a first=() rest=()
  ready=" $(awk -F'\t' -v p="${slug,,}#" 'index(tolower($1), p) == 1 && $2 == "READY" { print substr($1, length(p) + 1) }' \
    "${MC_ROWS:-/dev/null}" 2>/dev/null | tr '\n' ' ')"
  for r in "$@"; do
    [ -n "$r" ] || continue
    if [[ "$ready" == *" ${r%%$'\t'*} "* ]]; then first+=("$r"); else rest+=("$r"); fi
  done
  [ "${#first[@]}" -eq 0 ] || printf '%s\n' "${first[@]}"
  [ "${#rest[@]}" -eq 0 ] || printf '%s\n' "${rest[@]}"
}
# <<< READY first (BH-7376)
# >>> tick mode (BH-1201, BH-1672)
mc_tick_mode() {
KILL=0;    flag_on automerge-disabled && KILL=1
ACTIONS=0; flag_on merge-conductor-actions && ACTIONS=1
MERGES=0;  flag_on merge-conductor-merge && MERGES=1
if flag_on merge-conductor-observe; then ACTIONS=0; MERGES=0; fi
# BH-4156: bin/mc-state-drill.sh runs one tick with MC_DRILL=1. It must not be
# able to rebase, review or merge, whatever the flags say.
if [ "${MC_DRILL:-0}" = 1 ]; then ACTIONS=0; MERGES=0; fi
if [ "$KILL" = 1 ]; then ACTIONS=0; MERGES=0; fi
if [ "$MERGES" = 1 ] && [ "$ACTIONS" = 0 ]; then MERGES=0; mc_log "merge flag set without the actions flag — merges refused this tick"; fi
# A FLEET MERGES PAUSE (BH-1672) LOWERS MERGES AND NOTHING ELSE. It never sets
# KILL: rebases, re-reviews and every other action go on, and MODE, derived
# below from the lowered MERGES, reads `actions` rather than `kill-switch`.
# Every merge and enqueue path this tick forks reads MERGES (the merge arm, the
# requeue, the tier-2 enqueue, the settle and the stacked merge), so this one
# line covers them all. tick_project asks again per project (a fleet row
# matches there too), which is where a project row is honoured.
if pause_active fleet merges; then
  MERGES=0; mc_log "PAUSED(merges) fleet — no PR merges or enters a merge queue this tick; rebases and actions continue"
fi
MODE=observe; [ "$ACTIONS" = 1 ] && MODE=actions; [ "$MERGES" = 1 ] && MODE=merge; [ "$KILL" = 1 ] && MODE="kill-switch"
# THE MODE REACHES THE LIB (BH-1201). The two age pagers hold their pages under
# kill-switch/observe instead of sending them, and they live in bin/lib/mc/, in
# pr_worker subshells this process forks — so the word travels as an exported
# variable rather than an argument. EXPORTED FROM HERE AND NOWHERE ELSE: the
# five other lanes that source the lib (merge-sweep, blocked-resolver,
# review-prs, batch-resolve, run-build) leave it unset and page exactly as they
# do today.
MC_MODE="$MODE"; export MC_MODE
}
# <<< tick mode (BH-1201, BH-1672)
# >>> tick prelude (BH-6518)
mc_tick_prelude() {
REBASE_BUDGET="${MC_REBASE_BUDGET:-2}"; REREVIEW_BUDGET="${MC_REREVIEW_BUDGET:-2}"; MERGE_BUDGET="${MC_MERGE_BUDGET:-5}"
# --- isInMergeQueue: ask gh ONCE whether it accepts the field (2026-09-15) ----
# mergeStateStatus has no QUEUED value, so isInMergeQueue is the only witness of
# GitHub's native queue — but this gh's `--json` allowlist REFUSES it in list
# mode, and the open pass asked for it on every repo on every tick anyway. That
# is 411 lines of "gh refused --json isInMergeQueue — reading it per PR this
# tick" in 24 hours, one wasted list call per repo per tick behind each of them,
# and a per-PR read for every open PR on the repo whether or not the answer
# could matter.
#
# So the refusal is REMEMBERED (state/merge-conductor/gh-no-inqueue) instead of
# rediscovered: while the marker is fresh the list does not ask for the field at
# all, and the field is read per PR only for PRs whose merge state is one where
# being in the queue changes the answer. The marker ages out after
# MC_INQUEUE_PROBE_TTL_SECS so a gh upgrade is picked up on its own — a
# capability cache that can never expire is a capability cache that is wrong
# after the next `npm i -g`.
#   MC_LIST_INQUEUE   auto (default) | 1 always ask | 0 never ask
MC_LIST_INQUEUE="${MC_LIST_INQUEUE:-auto}"
MC_INQUEUE_PROBE_TTL_SECS="${MC_INQUEUE_PROBE_TTL_SECS:-86400}"
# The merge states in which "is this PR in the queue" changes what the tick does.
# A PR that is DIRTY, BLOCKED or UNSTABLE is not about to be merged by anything,
# and GitHub does not hold it in a queue either.
MC_INQUEUE_STATES="${MC_INQUEUE_STATES:-CLEAN QUEUED}"

# --- MAIN-RED FREEZE (2026-09-15) --------------------------------------------
# bin/main-red-detector.sh writes flags/main-red-<slug> when the repo's own main
# is red (the flag body carries the content sha, the workflow and since when).
# While it is there this conductor merges NOTHING in that repo — because every
# merge on a red main is a merge whose CI signal is worthless, and because the
# queue will eject everything behind it anyway — with two exceptions that are
# the way OUT of a red main:
#   * a PR carrying the fix label (MC_MAIN_RED_LABEL, default fix-main-red);
#   * a PR whose whole diff is test files (MC_MAIN_RED_TEST_PATHS), which cannot
#     be what broke production main and is frequently the quarantine that
#     unblocks it.
# The flag is read under both spellings a detector might use — the PROJECT name
# and the owner-repo slug — because a flag name cannot contain a slash.
#
# MC_MAIN_RED_LABEL, MC_MAIN_RED_TEST_PATHS, main_red_flag, main_red_test_path
# and main_red_exempt now live in bin/lib/main-red-gate.sh (BH-945), sourced by
# bin/lib/merge-conductor-lib.sh above. They moved because they were PRIVATE to
# this script, which is how #931 and #942 merged into a red main through box
# lanes on 2026-09-18 while this conductor logged the freeze every tick. Same
# names, same behaviour, six more callers. The two call sites below are
# unchanged and guard on `command -v main_red_flag`.
# THE DAILY RE-REVIEW CAP IS OFF BY DEFAULT (2026-09-14). It was a spend guard
# from when one re-review blocked the whole tick; with the review detached the
# thing worth bounding is how many run AT ONCE (MC_REREVIEW_PARALLEL), not how
# many a project may buy in a day — and the cap of 6 is what left seven
# approved project-5 PRs waiting overnight. 0 = unlimited; an operator who sets
# MC_REREVIEW_DAILY_CAP=<n> still gets exactly the old behaviour.
REREVIEW_CAP="${MC_REREVIEW_DAILY_CAP:-0}"
CAPFILE="$MC_STATE_DIR/rereviews-$(date -u +%Y%m%d).txt"; touch "$CAPFILE"
export MC_REREVIEW_PARALLEL MC_REREVIEW_TIMEOUT_SECS MC_RR_PATH
# The detached lanes re-source the lib in a fresh shell, so their knobs have to
# be in the ENVIRONMENT, not just in this process.
export MC_REBASE_PARALLEL MC_REBASE_TIMEOUT_SECS MC_DETACHED_REBASE
export MC_DV_TIMEOUT_SECS MC_DETACHED_DEPLOY_VERIFY
export MC_PR_PARALLEL MC_MERGE_LOCK_WAIT
# ONE ID FOR THE WHOLE TICK, exported so every PR worker of every project shares
# it. It keys this tick's spend-budget counters (so they start at zero without a
# reset) and it is the `tick=` field of the metrics line each project logs.
# Minted here and never inherited: a tick that reused the last one's id would
# inherit its spent budgets. Two OVERLAPPING ticks therefore have separate
# budgets, which is the same thing as saying each tick may spend its own.
MC_TICK_ID=$(mc_tick_id); export MC_TICK_ID
}
# <<< tick prelude (BH-6518)
