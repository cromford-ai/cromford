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
#   Reads MC_STATE_DIR, so it runs after mc_init. Needs mc_tick_id. BH-8457:
#   it also sets the per-tick permission memo dir (BG_PERM_MEMO_DIR, exported)
#   and the repo probe memo (_GHRT_PROBE_MEMO_DIR, _GHRT_PROBE_MEMO_TTL_S).
#
# mc_lazy_only_nums, mc_lazy_scoped (BH-8457)
#   The open list of tick_project. On a keyed tick, its merge-state reads go
#   to the woken PRs of that repo only (HPL_LAZY_ONLY).
#
# mc_tick_fanout (BH-7879)
#   The per-project fan-out: the held-page flush before the first worker forks
#   (BH-1201, BH-1840), the project gate (BH-6890), then one backgrounded
#   subshell per fleet.conf project that takes the full-tick lock (BH-5463),
#   runs tick_project and logs its PR-SNAPSHOT and ETag lines, and a final
#   wait. Reads MC_FLEET_SWEEPS, MC_ONLY_KEYS, MC_ONLY_PROJECT, MC_ON_MACHINE,
#   MC_PROJ_TAKEBACK, MC_FULL_TICK_SINGLE, MC_TICK_DIR and MC_LOCK_DIR. Calls
#   tick_project (defined by the driver, which BH-685 keeps there), so it runs
#   after the driver defines it. Sets MC_PROJ_GATE (tick_project reads it), P
#   and PIDS as globals, no `local`.
#
# mc_tick_main_red (BH-7879)
#   Sets MC_FLEET_SWEEPS (global, no `local`: the driver and mc_tick_fanout read
#   it) to 1, or to 0 on a keyed (MC_ONLY_KEYS) or one-project (MC_ONLY_PROJECT)
#   tick. On a fleet-sweep tick with MC_MAIN_RED_DETECT not 0 it runs
#   bin/main-red-detector.sh once under locks/main-red-detect-tick.lock
#   (MC_LOCK_DIR). Runs after mc_keyed_tick_parse and before the driver's parent
#   GH_ETAG_COUNT_FILE export. Needs mc_log.
#
# mc_tick_sweeps (BH-7879)
#   The fleet sweeps: the 14 housekeeping calls from mc_rereview_gc to
#   mc_dv_reap (bin/lib/mc/{rebase,classify,queue,locks}.sh,
#   bin/lib/pr-snapshot.sh). Reads MC_RB_DIR. The driver calls it after
#   mc_tick_fanout, on a fleet-sweep tick only.
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
# BH-8457: the two read memos of a tick. The collaborator-permission read
# (bg_reviewer_can_write, bin/lib/block-gate.sh) is kept for THIS tick only, in
# a dir the parent's EXIT trap removes and mc_tick_gc prunes. The repo
# visibility probe (bin/lib/gh-repo-token.sh) is kept across ticks for
# MC_REPO_PROBE_TTL_S (settings row lane.merge-conductor.mc_repo_probe_ttl_s;
# 300 is the fallback; 0 = probe every tick).
# Both are derived from what the prelude already reads (MC_STATE_DIR, the tick
# id), so the prelude still runs sourced alone, with no locks.sh and no H.
# No harness root = no probe memo dir = no memo.
BG_PERM_MEMO_DIR="${MC_TICK_DIR:-$MC_STATE_DIR/tick}/perm-${MC_TICK_ID//[^A-Za-z0-9._-]/_}"; export BG_PERM_MEMO_DIR
_MC_ROOT="${HARNESS:-${H:-}}"; _GHRT_PROBE_MEMO_DIR="${_MC_ROOT:+$_MC_ROOT/state/gh-repo-probe}"
_GHRT_PROBE_MEMO_TTL_S="${MC_REPO_PROBE_TTL_S:-300}"
}
# <<< tick prelude (BH-6518)
# >>> open list scope (BH-8457)
# mc_lazy_only_nums <slug> — the PR numbers of MC_ONLY_KEYS on <slug>, space
#   separated (empty when none is). Keys are lower case (mc_keyed_tick_parse).
mc_lazy_only_nums() {
  local k s out=""
  s=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
  for k in $MC_ONLY_KEYS; do [ "${k%#*}" = "$s" ] && out="$out ${k##*#}"; done
  printf '%s' "${out# }"
}
# mc_lazy_scoped <slug> <command...> — runs <command> (the driver's
#   harness_pr_list open-list call, spelled out in the driver so the lanes'
#   field sets stay readable there, tests/graphql-cuts.bh-1585-test.sh). On a
#   keyed tick the per-PR merge-state reads go to the woken PRs only
#   (HPL_LAZY_ONLY, bin/lib/gh-pr-list.sh): every other row reads UNKNOWN, and
#   the driver drops those rows from ROWS right after. A full tick reads every
#   row.
mc_lazy_scoped() {
  local s=$1; shift
  if [ -n "$MC_ONLY_KEYS" ]; then
    HPL_LAZY_ONLY="$(mc_lazy_only_nums "$s")" "$@"
  else
    "$@"
  fi
}
# <<< open list scope (BH-8457)
# >>> per-project fan-out (BH-7879)
mc_tick_fanout() {
# THE HELD PAGES, BEFORE THE FIRST WORKER FORKS (BH-1201). This reads what the
# conductor is holding into a tick-keyed cache and — when the mode has come back
# to merge/actions — sends the oldest MC_FLUSH_MAX of them. It has to run HERE,
# in the main process ahead of the fan-out: every pager below runs inside a
# tick_project subshell and reads that cache to know which rows the flush owns.
# `command -v`-guarded like mc_pr_files_gc below, so a box mid-sync with an older
# lib runs exactly as it does today.
# A keyed tick (BH-1387) skips the flush: it is a fleet sweep and the cron tick's alone.
# It still LOADS the cache (BH-1840), so a woken PR's held row is paged by the cron
# tick's capped flush with its held-since text, not directly by its own pager. The
# `declare -f` guard keeps a box whose older lib ignores the flag off a full flush.
if [ "$MC_FLEET_SWEEPS" = 1 ]; then
  command -v mc_hold_tick_begin >/dev/null 2>&1 && mc_hold_tick_begin
elif declare -f mc_hold_tick_begin 2>/dev/null | grep -q -- '--load-only'; then
  mc_hold_tick_begin --load-only
fi

# THE PROJECT GATE, ONCE (BH-6890). One read of the box settings cache: when
# no merge-conductor placement row is fly, no tick_project below reads a
# placement row (MC_PROJ_GATE=0). A machine is never gated.
MC_PROJ_GATE=1
if [ "${MC_ON_MACHINE:-}" = 1 ] || [ "${MC_PROJ_TAKEBACK:-}" = 1 ]; then MC_PROJ_GATE=0
elif command -v mc_fly_project_none >/dev/null 2>&1 && mc_fly_project_none; then MC_PROJ_GATE=0; fi
PIDS=()
for P in $("$H/bin/fleet-conf.sh" --projects 2>/dev/null); do
  if [ -n "$MC_ONLY_KEYS" ]; then mc_only_slug "$("$H/bin/fleet-conf.sh" "$P" repo 2>/dev/null)" || continue; fi
  [ -n "${MC_ONLY_PROJECT:-}" ] && [ "$P" != "$MC_ONLY_PROJECT" ] && continue
  # BH-1295: the ETag counters live in a FILE now (mc_pr_view's return value
  # is its whole point, so its callers are all `$( )`, and no shell variable
  # survives that) — GH_ETAG_COUNT_FILE names which one. tick_project
  # backgrounds into its own subshell per project, so a distinct, exported
  # file per project (never the bare `$$` default, which is the SAME across
  # every one of these subshells) keeps one project's reads from being summed
  # into another's report line.
  # BH-1322: `$BASHPID` — the subshell's OWN pid — is both the uniqueness and
  # what the counts sweep judges liveness by, so a killed project subshell's
  # file is removable by the next report. The trap inside the subshell fires
  # for that subshell only and expands the re-exported value, never the
  # parent's.
  # BH-4659: PRS_COUNT_FILE collects this project's snapshot HIT/MISS words for
  # its one PR-SNAPSHOT line. SLUG is cleared first: a project held or with no
  # repo never sets it, and logs nothing.
  ( export GH_ETAG_COUNT_FILE="$H/state/gh-etag/counts/merge-conductor.$P.$BASHPID"
    export PRS_COUNT_FILE="$MC_TICK_DIR/prs-count.$P.$BASHPID"
    trap 'rm -f "$GH_ETAG_COUNT_FILE" "$PRS_COUNT_FILE"' EXIT
    mkdir -p "$MC_TICK_DIR" 2>/dev/null; SLUG=""
    # >>> full-tick lock (BH-5463)
    # ONE FULL TICK PER PROJECT AT A TIME. This subshell holds the lock on fd 5
    # and only waits; tick_project runs in the inner subshell with fd 5 closed,
    # so no lane it detaches can hold the lock. A keyed tick never takes it.
    if [ -z "$MC_ONLY_KEYS" ] && [ "${MC_FULL_TICK_SINGLE:-1}" != 0 ]; then
      mkdir -p "$MC_LOCK_DIR" 2>/dev/null
      exec 5>"$MC_LOCK_DIR/merge-conductor-$(mc_safe_name "$P")-fulltick.lock"
      flock -n 5 || { mc_log "TICK $P skipped: another full tick of $P is still running (locks/merge-conductor-$(mc_safe_name "$P")-fulltick.lock) — keyed ticks still run (decision=skipped-tick-running)"; exit 0; }
    fi
    # <<< full-tick lock
    ( exec 5>&-
      tick_project "$P"
      # BH-6890: the hub mark of a take-back tick ends with the tick.
      command -v mc_proj_hub_unmark >/dev/null 2>&1 && mc_proj_hub_unmark "$P"
      if [ -n "$SLUG" ] && [ "$SLUG" != - ] && [ -f "$PRS_COUNT_FILE" ]; then
        mc_log "$SLUG PR-SNAPSHOT hit=$(grep -c '^HIT ' "$PRS_COUNT_FILE") miss=$(grep -c '^MISS ' "$PRS_COUNT_FILE")"
        # BH-8457: the PR record's answers to the same reads (pr-record-serve.sh).
        grep -qE '^R(SERVED|MISS) ' "$PRS_COUNT_FILE" \
          && mc_log "$SLUG PR-RECORD served=$(grep -c '^RSERVED ' "$PRS_COUNT_FILE") miss=$(grep -c '^RMISS ' "$PRS_COUNT_FILE")"
      fi
      command -v gh_rest_etag_report >/dev/null 2>&1 && gh_rest_etag_report "merge-conductor:$P" )
  ) & PIDS+=("$!")
done
[ "${#PIDS[@]}" -gt 0 ] && wait "${PIDS[@]}"
}
# <<< per-project fan-out (BH-7879)
# >>> fleet sweeps (BH-7879)
mc_tick_main_red() {
# ---- is MAIN itself red? (BH-636) -------------------------------------------
# bin/main-red-detector.sh has existed, with its own suite, since 2026-09-15 and
# NOTHING called it: no cron line, no caller, only comments. cromford's own
# main was red for two runs on 2026-09-17 and no flag was ever raised, so the
# freeze every project tick below reads (main_red_flag) could never engage.
#
# It runs HERE, before the first project ticks, so that flag is at most one tick
# old when it is read. The lock is a DEDUPE and never a queue (the operator, 2026-09-13):
# held means another tick is already doing it, and this one simply does not.
# It is its OWN lock file, not the detector's — the detector takes
# locks/main-red-detector.lock itself, and taking that one here would make every
# invocation skip. A detector that fails, or is absent (every conductor fixture
# copies the script into a scratch bin/ without it), never touches the tick.
# ONE PROJECT (BH-6890): bin/merge-conductor-project.sh runs a full tick of
# MC_ONLY_PROJECT only, on a lane-run machine. The fleet sweeps (this detector,
# the held-page flush, the *_gc housekeeping) stay the hub's.
MC_FLEET_SWEEPS=1
{ [ -n "$MC_ONLY_KEYS" ] || [ -n "${MC_ONLY_PROJECT:-}" ]; } && MC_FLEET_SWEEPS=0
if [ "$MC_FLEET_SWEEPS" = 1 ] && [ "${MC_MAIN_RED_DETECT:-1}" != 0 ] && [ -x "$H/bin/main-red-detector.sh" ]; then
  ( flock -n 9 || { mc_log "main-red detector: another tick holds the lock — skipped (dedupe, never a queue)"; exit 0; }
    mc_log "main-red detector: reading every repo's main before the project ticks"
    "$H/bin/main-red-detector.sh" >> "$H/logs/main-red-detector.log" 2>&1 || true
  ) 9>"$MC_LOCK_DIR/main-red-detect-tick.lock" || true
fi
}

mc_tick_sweeps() {
# Detached re-review jobs for PRs that have long since merged or closed.
mc_rereview_gc
# The rebase and deploy-verify lanes are read HERE, after every project tick has
# released its lock: a lane that can hold a project lock is the 03:54-04:02Z
# project-5 stall this whole change exists to kill.
mc_lane_gc "$MC_RB_DIR"
# Hand-off and release markers for PRs settled a fortnight ago, and the stuck
# detector's one-alert-per-(PR, state, head) markers on the same rule.
mc_handoff_gc
mc_stuck_gc
mc_resolver_claim_gc
# Batch holds for trains that never settled: a stale hold is a PR nothing merges.
mc_batch_gc
# This tick's budget and metrics counters are keyed by tick id, so yesterday's
# are dead weight the moment the day turns.
mc_tick_gc
# One lock file per PR the conductor has ever seen lives in locks/ for ever
# otherwise; each is removed under its own lock, so a live worker keeps its file.
mc_pr_lock_gc
# Cached PR file lists (the overlap re-review test) keyed on heads long gone.
type mc_pr_files_gc >/dev/null 2>&1 && mc_pr_files_gc
# Cross-tick read memos (BH-1486) on the same three-day rule and for the same
# reason: the head they are keyed on is long gone.
read_memo_gc
# The PR snapshot's per-PR bodies (BH-4659) on the same three-day rule.
command -v prs_gc >/dev/null 2>&1 && prs_gc
# Head-lag state (BH-1529) for PRs that merged or closed while lagging.
head_lag_gc
# UNVERIFIABLE streaks (BH-1634) for PRs that merged or closed mid-streak.
unverif_gc
mc_dv_reap
}
# <<< fleet sweeps (BH-7879)
