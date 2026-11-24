# shellcheck shell=bash
# bin/blocked-resolver.d/bh-9943-phase-uneject.sh — BH-9943: a resolver re-plan of a ticket in
# lifecycle phase `ejected` moves the phase to `pr_open`, so the pool's spawn
# gate lets the fresh build start. A resolver fragment (BH-7450): sourced,
# never run, and defining functions is its only effect at source time.
# BR_OPT_OFF=bh-9943-phase-uneject does not source it: a re-plan then leaves
# the phase alone, as before BH-9943.
#
# Call site, in br_enqueue_fresh (bin/blocked-resolver.sh), after a pool
# `queued` or `duplicate` answer:
#   command -v br_phase_uneject >/dev/null 2>&1 && ! br_phase_uneject ... \
#     && { BR_ENQUEUE_WHY="$PU_WHY"; return 1; }
#
# WHY. hub, 2026-11-23: the stale-replan rung enqueued fresh builds of BH-9453,
# BH-9465, BH-9693 and BH-9075 and counted the re-plans. Their phase stayed
# `ejected`, and bin/lib/plan-blocked-stop.sh (pbs_stop_check) refused every
# spawn. The 4 queue rows waited 6 to 12 days for a hand move.
#
# THE ACTOR is `lifecycle`. worker/jobs/src/lib/lifecycle.js makes it the only
# owner of a move out of `ejected` to a phase that is not abandoned or closed
# (the re-entry rule, BH-8736), and `ejected -> pr_open` is a legal move. This
# lib acts only on phase `ejected`, so who may leave plan_blocked or abandoned
# does not change.
#
# br_phase_uneject <project> <key> <reason>  rc 0 = nothing more to do (moved,
#   not ejected, no row, no jobs client, or the phase was unreadable: the spawn
#   gate fails open on an unreadable phase too, so this does the same); rc 1 =
#   the move did not land, and PU_WHY says why. One read (pool_phase_get) and
#   at most one POST (lifecycle_transition). No retry here: the caller's next
#   tick is the retry. A lane job key (RB-, RR-, LR-, FXR-, CP-) is rc 0 with
#   no read.

_pu_say() { declare -F say >/dev/null 2>&1 && say "$*"; return 0; }

br_phase_uneject() { # br_phase_uneject <project> <key> <reason>
  local p="${1:-}" key="${2:-}" why="${3:-re-plan}" row rc ph out err cur
  PU_WHY=""
  [ -n "$p" ] && [ -n "$key" ] && [ "$key" != - ] || return 0
  case "$key" in RB-*|RR-*|LR-*|FXR-*|CP-*) return 0 ;; esac
  # No jobs client on this box: the pool gate here cannot read a phase either.
  declare -F _jobs_req >/dev/null 2>&1 || return 0
  # shellcheck source=bin/lib/pool-lifecycle.sh
  declare -F pool_phase_get >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/../lib/pool-lifecycle.sh" 2>/dev/null
  # shellcheck source=bin/lib/jobs/lifecycle.sh
  declare -F lifecycle_transition >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/../lib/jobs/lifecycle.sh" 2>/dev/null
  if ! declare -F pool_phase_get >/dev/null 2>&1 || ! declare -F lifecycle_transition >/dev/null 2>&1; then
    PU_WHY="bin/lib/pool-lifecycle.sh or bin/lib/jobs/lifecycle.sh is missing on this box"
    return 1
  fi
  row=$(pool_phase_get "$p" "$key"); rc=$?
  case "$rc" in
    0) ;;
    2) return 0 ;;
    *) _pu_say "$key: phase unreadable — not moved this tick"; return 0 ;;
  esac
  IFS=$'\t' read -r ph _ <<<"$row"
  [ "$ph" = ejected ] || return 0
  out=$(lifecycle_transition "$p" "$key" pr_open lifecycle "blocked-resolver: $why" 2>/dev/null); rc=$?
  case "$rc" in
    0)
      _pu_say "$key: phase ejected -> pr_open (actor lifecycle, $why)"
      return 0 ;;
    9)
      cur=$(jq -r '.current // "-"' <<<"$out" 2>/dev/null); cur="${cur:--}"
      # A retrying caller reads `current == to` as already done (lifecycle.js).
      [ "$cur" = pr_open ] && return 0
      err=$(jq -r '.error // "refused"' <<<"$out" 2>/dev/null); err="${err:-refused}"
      PU_WHY="the phase move ejected -> pr_open was refused ($err; current $cur)" ;;
    2) PU_WHY="the phase move ejected -> pr_open found no build_queue row" ;;
    *) PU_WHY="the phase move ejected -> pr_open did not land (lifecycle DB unreadable)" ;;
  esac
  return 1
}
