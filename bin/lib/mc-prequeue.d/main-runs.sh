#!/bin/bash
# gh-identity: app-token
# bin/lib/mc-prequeue.d/main-runs.sh — THE RUNS OF ONE MAIN ARE READ BY THE
# MAIN SHA (BH-8152). Sourced by bin/lib/mc-prequeue.sh's hook loop, never
# executed; the only effect at source time is the two knob defaults.
#
# WHY. pq_find_run (adopt) and pq_read_run (settle) read only the 30 newest
# runs of prequeue-gate.yml. One main gets 15-20 runs, so after 30-60 min a
# run is past them: a worker with no cache entry dispatched the same title
# again (8 duplicate titles in 24 h, 2026-10-22/23), and a pending run that
# finished was not read until MC_PREQUEUE_DEADLINE_S.
#
# THE RULE. Every gate run is dispatched with `--ref main`, so its head_sha is
# the main of its title. One read of
# `runs?event=workflow_dispatch&head_sha=<main>` lists every run for that main,
# and every READY PR on that main shares it (memoised per tick, repo and main
# in MC_TICK_DIR). pq_find_run and pq_read_run look up the exact title there
# first and fall back to the 30-run list on a miss. pq_dispatch reads it again
# with no memo, under its lock, before it pays: a run with the exact title in
# any state is recorded `pending <created> <run_id>` and nothing is dispatched.
# Only the first page is read: a miss there (more than PAGE runs on one main,
# or a run whose head_sha is not its title's main) is a miss, never a proof.
#
# THE KNOBS (lane merge-conductor). MC_PREQUEUE_MAIN_RUNS 1 on, 0 = the rule
# before BH-8152 (no head_sha read). MC_PREQUEUE_MAIN_RUNS_PAGE the page size,
# 1..100 (the API maximum); any other value is 100.
#
#   pq_main_runs <slug> <main> [fresh]
#       sets _pq_mr to the run-list JSON of that main. rc 1 when the knob is 0
#       or main is not 40 hex, rc 75 when the read failed or is not a
#       workflow_runs array. fresh skips the memo and rewrites it.
#   pq_main_run_find <slug> <title> [fresh]
#       `<id> <status> <conclusion|-> <created_epoch>` of the newest run with
#       exactly that title on its main; nothing when none; rc 1 or 75 as above.

PQ_KNOB_DEFAULTS="$PQ_KNOB_DEFAULTS MC_PREQUEUE_MAIN_RUNS=1 MC_PREQUEUE_MAIN_RUNS_PAGE=100"

pq_main_runs() {
  local slug="$1" main="$2" fresh="${3:-}" memo="" raw="" page
  _pq_mr=""
  [ "$(pq_knob MC_PREQUEUE_MAIN_RUNS)" = 0 ] && return 1
  [[ "$main" =~ ^[0-9a-f]{40}$ ]] || return 1
  [ -n "${MC_TICK_ID:-}" ] && [ -n "${MC_TICK_DIR:-}" ] && memo="$MC_TICK_DIR/$(mc_safe_name "$MC_TICK_ID").pq-main-runs.${slug//\//_}.$main"
  if [ -z "$fresh" ] && [ -n "$memo" ] && [ -s "$memo" ]; then _pq_mr=$(cat "$memo" 2>/dev/null); [ -n "$_pq_mr" ] && return 0; fi
  page=$(pq_knob MC_PREQUEUE_MAIN_RUNS_PAGE)
  [ "$page" -ge 1 ] 2>/dev/null && [ "$page" -le 100 ] || page=100
  mc_rest_var raw gh_rest GET "repos/$slug/actions/workflows/$PQ_WF/runs?event=workflow_dispatch&head_sha=$main&per_page=$page" || return 75
  jq -e '.workflow_runs | type == "array"' >/dev/null 2>&1 <<<"$raw" || return 75
  _pq_mr="$raw"
  if [ -n "$memo" ] && mkdir -p "$MC_TICK_DIR" 2>/dev/null; then
    printf '%s\n' "$raw" > "$memo.tmp.$$" 2>/dev/null && mv -f "$memo.tmp.$$" "$memo" 2>/dev/null || rm -f "$memo.tmp.$$" 2>/dev/null
  fi
  return 0
}

pq_main_run_find() {
  local slug="$1" t="$2" rc=0
  pq_main_runs "$slug" "${t##* main=}" "${3:-}" || rc=$?
  [ "$rc" = 0 ] || return "$rc"
  jq -r --arg t "$t" '[.workflow_runs[]? | select(.display_title == $t)] | sort_by(.created_at) | last // empty
    | "\(.id) \(.status) \(.conclusion // "-") \((.created_at // "") | (try fromdateiso8601 catch 0))"' <<<"$_pq_mr" 2>/dev/null
  return 0
}
