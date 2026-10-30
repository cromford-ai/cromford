# shellcheck shell=bash
# bin/merge-conductor.d/bh-8735-lifecycle.sh - THE CONDUCTOR WRITES THE TICKET
# PHASES IT OWNS (BH-8735, lifecycle 5/6). Sourced by bin/merge-conductor.sh
# (the BH-7453 fragment block), before the first tick.
#
# The ticket lifecycle (#8731) keeps one phase per ticket in the jobs DB. The
# conductor owns three of them: in_queue (the PR entered the merge queue),
# ejected (Mergify dequeued it) and merged (it landed). This file holds the
# only code that sends them, through lifecycle_transition
# (bin/lib/jobs/lifecycle.sh) with actor `conductor`. The call sites are one
# guarded line each:
#   in_queue  pr_worker's enqueue rc 0, the re-entry requeue rc 0|2, and
#             sdq_arm's requeue rc 0|2 (bin/lib/mc-stale-dequeue.sh)
#   ejected   the settle pass's ejection (tick_project), and sdq_arm on a
#             Mergify `dequeued` payload with the merge-queue label still on
#   merged    conductor_settle (bin/lib/mc/settle.sh), only when the PR
#             record says merged
# in_queue and merged come after the conductor's own write (the enqueue, the
# requeue post, the MERGED row), so those phases never run ahead of the queue.
# The settle-pass ejected call comes BEFORE its mc_transition (WAIT_CI or
# BLOCKED_HUMAN). A crash between the two leaves phase ejected on a QUEUED
# row; the next tick sees the same ejection and its second call answers rc 9
# current == to, which is silent.
#
# FAIL-OPEN, ALWAYS rc 0. A lifecycle failure never changes STATE, WHY, the
# row or the tick. No lifecycle lib (#8731 not merged), MC_LIFECYCLE_WRITE=0,
# a branch with no ticket key or no build_queue row (rc 2): nothing at all.
# A refused move (rc 9) is one LIFECYCLE_REFUSED line per (PR, phase, head),
# through the attempts line `lcrefused <slug#n> <phase> <head>`; rc 9 with
# current == to (already there) is silent. rc 1 or 3 is one
# LIFECYCLE_UNREACHABLE line. The Tackler's /stuck read (#8736) is the
# backstop for a write that did not land.

# _mclc_knob <ENV> <fallback> — lane.merge-conductor[.<p>].<env>, else the env
# var, else the fallback (the bin/lib/mc-failed-batch.sh _fbh_knob shape).
_mclc_knob() {
  local v=""
  if command -v lane_knob >/dev/null 2>&1; then v=$(lane_knob merge-conductor "$1" "${P:-}" 2>/dev/null); fi
  [ -n "$v" ] || v="${!1:-}"
  [ -n "$v" ] || v="$2"
  printf '%s' "$v"
}

# _mclc_api — rc 0 when lifecycle_transition is defined, sourcing
# bin/lib/jobs/lifecycle.sh first when it is not.
_mclc_api() {
  local root="${HARNESS:-${H:-}}" lib
  command -v lifecycle_transition >/dev/null 2>&1 && return 0
  [ -n "$root" ] || return 1
  # Optional until #8731 merges, so the path is a variable: a scratch closure
  # copies the lib when it exists and does not require it when it does not.
  lib="$root/bin/lib/jobs/lifecycle.sh"
  [ -r "$lib" ] || return 1
  # shellcheck source=/dev/null
  . "$lib" >/dev/null 2>&1 || return 1
  command -v lifecycle_transition >/dev/null 2>&1
}

# mclc_put <phase> <project> <owner/repo> <branch> <pr-num> <head> <reason>
mclc_put() {
  local phase="${1:-}" proj="${2:-}" slug="${3:-}" br="${4:-}" num="${5:-}" head="${6:-}" reason="${7:-}"
  local tkey pkey max out rc err cur to
  [ "$(_mclc_knob MC_LIFECYCLE_WRITE 1)" = 0 ] && return 0
  _mclc_api || return 0
  command -v mc_ticket_of_branch >/dev/null 2>&1 || return 0
  tkey=$(mc_ticket_of_branch "$br" 2>/dev/null) || return 0
  [ -n "$tkey" ] || return 0
  pkey="$slug#$num"
  # Knob: catalog/lanes.d/merge-conductor.knobs.d/MC_LIFECYCLE_REASON_MAX.json.
  # 500 is the lifecycle route's own reason cap (#8731) and the fallback.
  max=$(_mclc_knob MC_LIFECYCLE_REASON_MAX 500)
  [[ $max =~ ^[0-9]{1,3}$ ]] && [ "$((10#$max))" -ge 1 ] && [ "$((10#$max))" -le 500 ] || max=500
  reason="${reason//[$'\t\r\n']/ }"
  reason="${reason:0:$((10#$max))}"
  out=$(lifecycle_transition "$proj" "$tkey" "$phase" conductor "$reason" "$num" 2>/dev/null); rc=$?
  case "$rc" in
    0) mc_log "LIFECYCLE $pkey $tkey -> $phase" ;;
    2) ;;
    9)
      IFS=$'\t' read -r err cur to < <(jq -r '[(.error // "-"), (.current // "-"), (.to // "-")] | map(tostring) | @tsv' <<<"$out" 2>/dev/null)
      if [ -n "${cur:-}" ] && [ "$cur" != - ] && [ "$cur" = "${to:-}" ]; then return 0; fi
      if ! mc_attempt_has "lcrefused $pkey $phase $head" 2>/dev/null; then
        mc_attempt_put "lcrefused $pkey $phase $head"
        mc_log "LIFECYCLE_REFUSED $pkey $tkey $phase ${err:--} current=${cur:--}"
      fi ;;
    *) mc_log "LIFECYCLE_UNREACHABLE $pkey $tkey $phase (rc $rc) — the phase is not written; the row is unchanged" ;;
  esac
  return 0
}

# _mclc_state <owner/repo> <pr-num> [fresh] — the PR record's state, or
# `unreadable`. With `fresh`, pr_record_get reads GitHub once (PR_RECORD_FRESH)
# and writes what it read into the record with source github.
_mclc_state() {
  local row st=unreadable fresh=0
  [ "${3:-}" = fresh ] && fresh=1
  if command -v pr_record_get >/dev/null 2>&1 && row=$(PR_RECORD_FRESH=$fresh pr_record_get "$1" "$2" state 2>/dev/null); then
    st=$(jq -r 'if type == "object" then (.state // "null") | tostring else "unreadable" end' <<<"$row" 2>/dev/null) || st=unreadable
    [ -n "$st" ] || st=unreadable
  fi
  printf '%s' "$st"
}

# mclc_merged <project> <owner/repo> <pr-num> <branch> <head> <reason> — the
# merged phase, only when the PR record (bin/lib/pr-record.sh) says merged.
# The conductor's own merge call PUTs queue_state into the record one call
# earlier, so a stale `open` row looks new (age 0) and is served as is. On any
# answer but merged, the gate reads once more with the GitHub read forced.
# The conductor never PUTs `merged` itself: GitHub's answer is the proof.
mclc_merged() {
  local proj="${1:-}" slug="${2:-}" num="${3:-}" br="${4:-}" head="${5:-}" why="${6:-}" st
  [ "$(_mclc_knob MC_LIFECYCLE_WRITE 1)" = 0 ] && return 0
  # shellcheck source=bin/lib/pr-record.sh
  command -v pr_record_get >/dev/null 2>&1 || { [ -n "${HARNESS:-${H:-}}" ] && . "${HARNESS:-${H:-}}/bin/lib/pr-record.sh" 2>/dev/null; }
  st=$(_mclc_state "$slug" "$num")
  [ "$st" = merged ] || st=$(_mclc_state "$slug" "$num" fresh)
  if [ "$st" = merged ]; then
    mclc_put merged "$proj" "$slug" "$br" "$num" "$head" "$why"
  else
    mc_log "LIFECYCLE_MERGED_UNPROVEN $slug#$num state=$st — the PR record does not say merged; the merged phase is not written"
  fi
  return 0
}

# mclc_dequeued <project> <owner/repo> <branch> <pr-num> <head> <labels-csv>
#   <payload-comment-id> <dequeue-epoch> — sdq_arm's call on a Mergify
#   `dequeued` payload. Writes `ejected` once per payload comment, and only
#   while our merge-queue label is still on and Mergify's queued/checking labels
#   are not (U4 skips such a PR, so nothing else sees this ejection). The mark
#   is written BEFORE the call: a crash costs one write, never a loop.
mclc_dequeued() {
  local proj="${1:-}" slug="${2:-}" br="${3:-}" num="${4:-}" head="${5:-}" lbl="${6:-}" cid="${7:-}" pt="${8:-}" why="" at
  grep -qE "(^|,)${MC_MERGIFY_LABEL:-merge-queue}(,|\$)" <<<"$lbl" || return 0
  grep -qE '(^|,)(queued|checking)(,|$)' <<<"$lbl" && return 0
  [[ $cid =~ ^[0-9]+$ ]] || return 0
  mc_attempt_has "lcdequeue $slug#$num $head $cid" 2>/dev/null && return 0
  mc_attempt_put "lcdequeue $slug#$num $head $cid"
  command -v ec_head_why >/dev/null 2>&1 && why=$(ec_head_why "$slug" "$num" "$head" 2>/dev/null)
  at=$(date -u -d "@$pt" +%H:%MZ 2>/dev/null) || at="?"
  mclc_put ejected "$proj" "$slug" "$br" "$num" "$head" "mergify dequeued at $at, merge-queue label still on${why:+; $why}"
  return 0
}
