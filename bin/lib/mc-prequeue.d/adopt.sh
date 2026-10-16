#!/bin/bash
# gh-identity: app-token
# bin/lib/mc-prequeue.d/adopt.sh — A PRE-QUEUE RUN ANOTHER WORKER DISPATCHED
# COUNTS HERE TOO (BH-6924). Sourced by bin/lib/mc-prequeue.sh's hook loop,
# never executed; no side effect at source time.
#
# WHY. A verdict lived only in $MC_STATE_DIR/prequeue/ of the worker that
# dispatched the run. A lane-run machine (MC_ON_MACHINE=1) has its own state
# dir, so the hub, or the next machine, saw a miss and dispatched the same
# (PR, head, main) again, and never read the green the first run gave.
#
# THE RULE. On a miss, before any reuse rule pays for a new run, pq_resolve
# asks pq_adopt_run. The run list of prequeue-gate.yml is the store every worker
# shares, and the run title `prequeue pr=<n> head=<h> main=<m>` is its key. A
# run with that exact title is written into this worker's cache as
# `pending <created_epoch> <run_id>` (under the pq_dispatch lock, and only into
# an empty entry), and pq_settle reads it as it reads a run this worker
# dispatched: completed with one verdict is that verdict, still running is a
# hold aged from the run's own created time (MC_PREQUEUE_DEADLINE_S still
# bounds it), anything else is could-not-run with its one alert.
#
#   pq_find_run <slug> <title>    `<id> <status> <created_epoch>` of the newest
#                                 run with that exact title; nothing when none;
#                                 rc 75 when the list could not be read
#   pq_adopt_run <slug> <num> <url> <head> <main> <path>
#                                 rc 0 and _pq_word set (proceed, red, hold)
#                                 when a run was adopted or another worker holds
#                                 the key; rc 1 when there is no run to adopt

# pq_find_run <slug> <title> — one read of the run list, memoised per tick and
#   repo in MC_TICK_DIR (the list pq_read_run reads, the same 30 runs).
pq_find_run() {
  local slug="$1" t="$2" raw="" memo=""
  [ -n "${MC_TICK_ID:-}" ] && [ -n "${MC_TICK_DIR:-}" ] && memo="$MC_TICK_DIR/$(mc_safe_name "$MC_TICK_ID").pq-runs.${slug//\//_}"
  if [ -n "$memo" ] && [ -s "$memo" ]; then raw=$(cat "$memo" 2>/dev/null)
  else
    mc_rest_var raw gh_rest GET "repos/$slug/actions/workflows/$PQ_WF/runs?event=workflow_dispatch&per_page=30" || return 75
    jq -e '.workflow_runs | type == "array"' >/dev/null 2>&1 <<<"$raw" || return 75
    [ -n "$memo" ] && mkdir -p "$MC_TICK_DIR" 2>/dev/null && printf '%s\n' "$raw" > "$memo" 2>/dev/null
  fi
  jq -r --arg t "$t" '[.workflow_runs[]? | select(.display_title == $t)] | sort_by(.created_at) | last // empty
    | "\(.id) \(.status) \((.created_at // "") | (try fromdateiso8601 catch 0))"' <<<"$raw" 2>/dev/null
  return 0
}

# pq_adopt_run <slug> <num> <url> <head> <main> <path> — see the header.
pq_adopt_run() {
  local slug="$1" num="$2" url="$3" head="$4" main="$5" path="$6" r id st at lk rc=0
  _pq_word=""
  [ -n "${MC_H:-}" ] && [ -n "$path" ] || return 1
  r=$(pq_find_run "$slug" "$(pq_run_title "$num" "$head" "$main")") || return 1
  read -r id st at <<<"$r"
  [[ "$id" =~ ^[0-9]+$ ]] && [[ "$at" =~ ^[0-9]+$ ]] && [ "$at" -gt 0 ] || return 1
  lk="$MC_H/locks/prequeue-${slug//\//_}-$num-$head.lock"
  mkdir -p "${lk%/*}" 2>/dev/null; { : >> "$lk"; } 2>/dev/null || return 1
  (
    flock -n 9 || exit 3
    [ -n "$(pq_cache_get "$path")" ] && exit 3
    pq_cache_put "$path" pending "$at" "$id" "" || exit 4
    exit 0
  ) 9>"$lk" || rc=$?
  case "$rc" in
    0) ;;
    3) _pq_word=hold; PQ_WHY="prequeue run $id for ${head:0:8} is in another worker's hands"
       mc_log "PREQUEUE adopt #$num head=${head:0:12} main=${main:0:12} run=$id -> hold (busy)"; return 0 ;;
    *) mc_log "$slug#$num prequeue: could not record the adopted run $id for ${head:0:8} on main ${main:0:12}"; return 1 ;;
  esac
  pq_settle "$slug" "$num" "$url" "$head" "$main" "$path" "$at"
  [ "$_pq_word" = hold ] && PQ_WHY="prequeue run $id for main ${main:0:12} (dispatched by another worker, status $st) still running; its verdict is read on a later tick"
  mc_log "PREQUEUE adopt #$num head=${head:0:12} main=${main:0:12} run=$id -> $_pq_word"
  return 0
}
