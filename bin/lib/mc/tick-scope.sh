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
# mc_tick_mode
#   Reads the four fleet flags through flag_on (defined by the driver, which
#   BH-685 keeps there, so this runs after flag_on is defined) and the fleet
#   merges pause through pause_active. Sets KILL, ACTIONS, MERGES and MODE
#   (globals, no `local`, never exported) and the exported MC_MODE. Needs
#   mc_log.
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
# >>> tick mode (BH-1201, BH-1672)
mc_tick_mode() {
KILL=0;    flag_on automerge-disabled && KILL=1
ACTIONS=0; flag_on merge-conductor-actions && ACTIONS=1
MERGES=0;  flag_on merge-conductor-merge && MERGES=1
if flag_on merge-conductor-observe; then ACTIONS=0; MERGES=0; fi
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
