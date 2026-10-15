# shellcheck shell=bash
# bin/lib/mc/fly-workers.sh — BH-6495 (BH-6047.5): the conductor's per-PR
# workers placed on lane-run machines. Sourced by bin/merge-conductor.sh and
# bin/merge-conductor-pr.sh, never run.
#
# With the switch on, the hub's tick_project does not start a local pr_worker
# for a PR. It enqueues ONE lane_runs row (lane merge-conductor-pr, project
# <project>.<pr>.<head12>), and a machine running bin/lane-run-worker.sh claims
# it and runs bin/merge-conductor-pr.sh, which is today's keyed tick for that
# one PR. The partial unique index lane_runs_live is the dedupe of a key.
#
#   mc_fly_workers_on <project>
#       rc 0 = on. conductor_workers_on_fly.<project> wins when it has a row,
#       else the fleet row conductor_workers_on_fly. Only the trimmed value 1
#       is on. No row, any other value or a settings outage is off.
#   mc_fly_run_key <project> <pr> <head>
#       prints <project>.<pr>.<head12>. rc 1 when the pr is not a number, the
#       head is not 12+ lower-case hex, or the key is not a lane name
#       ([A-Za-z0-9._-]{1,64}).
#   mc_fly_deferred_for <rows-json> <key>
#       rc 0 + the word(s) when the newest `done` row of <key> in a prefix-read
#       answer carries a PROF line with deferred=<x>, x not `-`: the machine
#       left that PR's work to the hub (bin/merge-conductor-pr.sh).
#   mc_fly_failed_for <rows-json> <key>
#       rc 0 + a word (died | command-missing | rc=<n> | no-prof) when the
#       NEWEST row of <key> is finished and failed: status died, status failed
#       (the jobs worker's answer for rc != 0; rc 126/127 is command-missing),
#       a done row with an rc that is not 0 (75 = UNVERIFIABLE included; a
#       worker that still answers done), or no `PROF mc-pr` line. A machine that cannot
#       run the worker fails the same way on every try, so the hub must run
#       that head itself (lead review of #6624). rc 1 otherwise: no row, a live
#       newest row, or a clean run.
#   mc_fly_stale_for <rows-json> <key> <now-epoch> <stale-s>
#       rc 0 + the age in seconds when the NEWEST row of <key> is queued and was
#       enqueued <stale-s> or more seconds ago: no machine took it (no
#       capacity, no fleet). rc 1 otherwise. MC_FLY_QUEUE_STALE_S is the knob
#       (default 600, the ticket's "unclaimed for 10 min" rollback line).
#   mc_fly_enqueue <project> <slug> <pr> <head>
#       sets MC_FLY_KEY. rc 0 = enqueued (201), 3 = already live (409),
#       4 = a row of another head of this PR is live (MC_FLY_OTHER names it),
#       5 = the machine deferred this head (MC_FLY_DEFERRED), 6 = no valid key,
#       7 = the machine run of this head failed (MC_FLY_FAILED), 8 = its row
#       waits unclaimed past MC_FLY_QUEUE_STALE_S (MC_FLY_STALE), 1 = the read
#       or the enqueue failed. Only rc 0 and 3 mean a row exists.
#   mc_fly_arm <project> <slug> <list-row>
#       the launch-loop decision for one row. rc 0 = handled here (enqueued or
#       skipped, accounted in fan-in): start no local worker. rc 1 = run the
#       local worker as today, after one `fallback=<word>` line. Reads
#       LAND_FIRE; counts into MC_FLY_N_ENQ, MC_FLY_N_SKIP and MC_FLY_N_FB,
#       and appends enq|skip|fb to MC_FLY_COUNT_FILE when it is set.
#   mc_fly_launch <project> <slug> <list-row>
#       one row, for a `&` in the launch loop: mc_fly_arm, and when it answers
#       rc 1 the local worker (fanin_run_sub … mc_worker_bounded), as today.
#       Run in the background, the jobs-worker reads of N rows overlap inside
#       the same pr_slot_wait bound, instead of 2 reads per PR in sequence.
#
# The root is ${HARNESS:-${H:-}}. Defines functions only. Nothing runs on
# source; the jobs client and bin/lib/lane-placement.sh load on first use.

MC_FLY_LANE=merge-conductor-pr

_mc_fly_root() { printf '%s' "${HARNESS:-${H:-}}"; }

# _mc_fly_client — rc 0 when lp_enqueue, setting_get and _jobs_req exist.
_mc_fly_client() {
  local root
  if ! command -v lp_enqueue >/dev/null 2>&1; then
    root=$(_mc_fly_root)
    [ -n "$root" ] && [ -r "$root/bin/lib/lane-placement.sh" ] || return 1
    # shellcheck source=bin/lib/lane-placement.sh
    . "$root/bin/lib/lane-placement.sh" || return 1
  fi
  _lp_client
}

_mc_fly_trim() { printf '%s' "${1:-}" | tr -d '[:space:]'; }

mc_fly_workers_on() {
  local p="${1:-}" v rc
  _mc_fly_client || return 1
  if [ -n "$p" ] && _setting_key_ok "conductor_workers_on_fly.$p"; then
    v=$(setting_get "conductor_workers_on_fly.$p"); rc=$?
    case "$rc" in
      0) [ "$(_mc_fly_trim "$v")" = 1 ]; return ;;
      2) ;;
      *) return 1 ;;
    esac
  fi
  v=$(setting_get conductor_workers_on_fly) || return 1
  [ "$(_mc_fly_trim "$v")" = 1 ]
}

mc_fly_run_key() {
  local p="${1:-}" n="${2:-}" head="${3:-}" key
  [[ $n =~ ^[0-9]+$ ]] && [[ $head =~ ^[0-9a-f]{12} ]] || return 1
  key="$p.$n.${head:0:12}"
  [[ $key =~ ^[A-Za-z0-9._-]{1,64}$ ]] || return 1
  printf '%s' "$key"
}

mc_fly_deferred_for() {
  local d
  d=$(printf '%s' "${1:-}" | jq -r --arg k "${2:-}" \
    'first(.rows[]? | select(.project == $k and .status == "done")) | .prof_line // ""
     | capture("(^| )deferred=(?<d>[^ ]+)").d // ""' 2>/dev/null) || return 1
  [ -n "$d" ] && [ "$d" != - ] || return 1
  printf '%s' "$d"
}

mc_fly_failed_for() {
  local d
  d=$(printf '%s' "${1:-}" | jq -r --arg k "${2:-}" '
    first(.rows[]? | select(.project == $k)) // {} |
    if (.status // "") == "died" then "died"
    elif (.status // "") == "failed" then
      (if (.rc == 126 or .rc == 127) then "command-missing" else "rc=\(.rc)" end)
    elif (.status // "") != "done" then ""
    elif (.rc != null and .rc != 0) then "rc=\(.rc)"
    elif ((.prof_line // "") | test("(^| )PROF mc-pr ")) | not then "no-prof"
    else "" end' 2>/dev/null) || return 1
  [ -n "$d" ] || return 1
  printf '%s' "$d"
}

mc_fly_stale_for() {
  local a
  a=$(printf '%s' "${1:-}" | jq -r --arg k "${2:-}" --argjson now "${3:-0}" --argjson st "${4:-600}" '
    first(.rows[]? | select(.project == $k)) // {} |
    if (.status // "") != "queued" then ""
    else ((.enqueued_at // "") | try fromdateiso8601 catch null) as $t |
      if $t == null then "" elif ($now - $t) >= $st then ($now - $t | tostring) else "" end
    end' 2>/dev/null) || return 1
  [ -n "$a" ] || return 1
  printf '%s' "$a"
}

mc_fly_enqueue() {
  local p="${1:-}" slug="${2:-}" n="${3:-}" head="${4:-}" root rows rc
  MC_FLY_KEY=""; MC_FLY_OTHER=""; MC_FLY_DEFERRED=""; MC_FLY_FAILED=""; MC_FLY_STALE=""
  MC_FLY_KEY=$(mc_fly_run_key "$p" "$n" "$head") || return 6
  _mc_fly_client || return 1
  root=$(_mc_fly_root)
  # One read of this PR's rows, newest first. The trailing dot keeps #12 from
  # matching #123.
  rows=$(_jobs_req GET "/api/lane-runs/by-prefix?lane=$MC_FLY_LANE&project_prefix=$p.$n.&limit=50") || return 1
  printf '%s' "$rows" | jq -e '.rows | type == "array"' >/dev/null 2>&1 || return 1
  # A failed run first: its row is terminal, so lp_enqueue would add a new one
  # and the next machine fails the same way, tick after tick, with nobody told.
  if MC_FLY_FAILED=$(mc_fly_failed_for "$rows" "$MC_FLY_KEY"); then return 7; fi
  if MC_FLY_DEFERRED=$(mc_fly_deferred_for "$rows" "$MC_FLY_KEY"); then return 5; fi
  # No machine took the row in time (no capacity, or no fleet at all): the hub
  # works the PR rather than leave it waiting. A machine that claims the row
  # later lands nothing (MC_ON_MACHINE), so the overlap is reads, not a merge.
  local st="${MC_FLY_QUEUE_STALE_S:-600}"
  [[ $st =~ ^[0-9]+$ ]] || st=600
  if MC_FLY_STALE=$(mc_fly_stale_for "$rows" "$MC_FLY_KEY" "$(date -u +%s)" "$st"); then return 8; fi
  # A cut answer could hide a live row: ask again for the live rows alone,
  # which the index holds to one per key.
  if [ "$(printf '%s' "$rows" | jq -r '.truncated' 2>/dev/null)" != false ]; then
    rows=$(_jobs_req GET "/api/lane-runs/by-prefix?lane=$MC_FLY_LANE&project_prefix=$p.$n.&live=1&limit=50") || return 1
    [ "$(printf '%s' "$rows" | jq -r '.truncated' 2>/dev/null)" = false ] || return 1
  fi
  MC_FLY_OTHER=$(printf '%s' "$rows" | jq -r --arg k "$MC_FLY_KEY" \
    'first(.rows[] | select((.status == "queued" or .status == "claimed") and .project != $k)) | .project' 2>/dev/null)
  [ -n "$MC_FLY_OTHER" ] && return 4
  lp_enqueue "$MC_FLY_LANE" "$MC_FLY_KEY" "$root/bin/merge-conductor-pr.sh" "$p" "$slug#$n" "$head"; rc=$?
  case "$rc" in 0|3) return "$rc" ;; esac
  return 1
}

mc_fly_arm() {
  local p="$1" slug="$2" row="$3" num head why rc
  MC_FLY_DEFERRED=""; MC_FLY_FAILED=""; MC_FLY_STALE=""
  num="${row%%$'\t'*}"
  head=$(printf '%s' "$row" | cut -f3)
  if [ "${LAND_FIRE:-0}" = 1 ]; then
    # The land fan-out records its sha only when every worker of this tick
    # answered (BH-870), so a land-fire tick stays whole on the hub.
    why=land-fire
  else
    mc_fly_enqueue "$p" "$slug" "$num" "$head"; rc=$?
    case "$rc" in
      0|3)
        fanin_account "$slug#$num" enqueued:fly
        if [ "$rc" = 3 ]; then
          mc_log "$slug#$num enqueued merge-conductor-pr $MC_FLY_KEY (already live) — no local worker this tick"
        else
          mc_log "$slug#$num enqueued merge-conductor-pr $MC_FLY_KEY — no local worker this tick"
        fi
        hotfix_pending_is "$p" "$num" 2>/dev/null && hotfix_pending_drop "$p" "$num"
        MC_FLY_N_ENQ=$(( ${MC_FLY_N_ENQ:-0} + 1 )); _mc_fly_count enq
        return 0 ;;
      4)
        fanin_account "$slug#$num" skipped:fly-live-other-head
        mc_log "$slug#$num skipped:fly-live-other-head — $MC_FLY_OTHER is still live, so ${head:0:12} is enqueued after it is done; no local worker this tick"
        hotfix_pending_is "$p" "$num" 2>/dev/null && hotfix_pending_drop "$p" "$num"
        MC_FLY_N_SKIP=$(( ${MC_FLY_N_SKIP:-0} + 1 )); _mc_fly_count skip
        return 0 ;;
      5) why=machine-deferred ;;
      6) why=key-too-long ;;
      7) why=machine-failed ;;
      8) why=no-capacity ;;
      *) why=enqueue-failed ;;
    esac
  fi
  MC_FLY_N_FB=$(( ${MC_FLY_N_FB:-0} + 1 )); _mc_fly_count fb
  mc_log "$slug#$num fallback=$why${MC_FLY_DEFERRED:+ ($MC_FLY_DEFERRED)}${MC_FLY_FAILED:+ ($MC_FLY_FAILED at ${MC_FLY_KEY:-?})}${MC_FLY_STALE:+ (${MC_FLY_KEY:-?} unclaimed for ${MC_FLY_STALE}s)} — this PR runs on the hub this tick"
  return 1
}

# _mc_fly_count enq|skip|fb — one word per row into MC_FLY_COUNT_FILE, the
# tally a backgrounded mc_fly_launch cannot return through a variable.
_mc_fly_count() {
  [ -n "${MC_FLY_COUNT_FILE:-}" ] || return 0
  printf '%s\n' "$1" >> "$MC_FLY_COUNT_FILE" 2>/dev/null
  return 0
}

mc_fly_launch() {
  local p="$1" slug="$2" row="$3"
  mc_fly_arm "$p" "$slug" "$row" && return 0
  fanin_run_sub "$slug#${row%%$'\t'*}" mc_fanin_outcome mc_worker_bounded "$row"
}
