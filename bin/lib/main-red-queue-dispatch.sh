#!/bin/bash
# gh-identity: raw-by-design — sourced by bin/main-red-detector.sh after it has armed the repo's identity
# bin/lib/main-red-queue-dispatch.sh — BH-3891 (4 of 5 of BH-3886): ONE
# workflow_dispatch of the frozen workflow on main per merge-queue freeze.
#
# A reason=queue freeze clears on a green batch newer than it, or on a green
# workflow_dispatch run on main newer than it. When the queue is empty no batch
# ever runs, and until now the way out was a human dispatching Harness CI on
# main by hand. This lib does that once: when the freeze has held for
# $MR_QUEUE_SELF_DISPATCH_MIN minutes and main's own push runs of that workflow
# are green, it dispatches the workflow named by the flag's path= on main.
#
# THE GATES, CHEAPEST FIRST; the first one that fails returns:
#   1. the flag says reason=queue                         (silent)
#   2. the knob is a whole number above 0                 (silent; no read at all)
#   3. the flag has since= (the episode key), a path= that is a workflow file,
#      and raised= (or a legacy detected=) that parses   (logged)
#   4. the freeze has held >= the knob in minutes         (silent)
#   5. the ledger row main_red_qdispatch <owner>/<repo>#<since> was READ and is
#      ABSENT (rc 2). Present — requested or refused — is "not again"; a failed
#      read is no dispatch this tick, because never twice outranks thaw.
#   6. one GET of that workflow's runs on main: nothing in flight, and the
#      newest completed push run is success
#   7. --explain: WOULD SELF-DISPATCH, nothing written, nothing posted
#   8. the row is WRITTEN (dispatch=requested at=<stamp>) BEFORE the POST, and a
#      write that fails is no POST: a dispatch that cannot be recorded could
#      repeat. A process that dies between the write and the POST costs the
#      episode its one dispatch and nothing else — the freeze stands as it
#      would without this lib.
#   9. the POST. Refused: the row becomes dispatch=refused, ONE warn names the
#      manual step, and it is never retried and never logged as SELF-DISPATCH:.
#
# Sourced, never executed. No set -e and no exit: every path returns 0, and the
# detector ignores the rc anyway. It reads $NOW, $EXPLAIN,
# $MR_QUEUE_SELF_DISPATCH_MIN, log, alert, STAMP and job_ledger_get/put from the
# detector it is sourced into.

# _mrqd_fl <key> <flagfile> — one flag line's value.
_mrqd_fl() { sed -n "s/^$1=//p" "$2" 2>/dev/null | head -1; }

# mrqd_self_dispatch <slug> <flagfile>
mrqd_self_dispatch() {
  local slug="${1:-}" flag="${2:-}" min="${MR_QUEUE_SELF_DISPATCH_MIN:-}"
  local since="" path="" wf="" r="" e="" held="" key="" st="" rc=0 runs="" fly="" c="" out="" first=""
  [ "$(_mrqd_fl reason "$flag")" = queue ] || return 0
  case "$min" in ''|*[!0-9]*) return 0 ;; esac
  [ "$((10#$min))" -gt 0 ] || return 0
  min=$((10#$min))

  since=$(_mrqd_fl since "$flag")
  [ -n "$since" ] || { log "self-dispatch: $slug flag has no since= — no episode key, no dispatch"; return 0; }
  path=$(_mrqd_fl path "$flag"); wf="${path##*/}"
  [[ "$wf" =~ ^[A-Za-z0-9._-]+\.ya?ml$ ]] \
    || { log "self-dispatch: $slug flag's path= ('$path') names no workflow file — no dispatch"; return 0; }
  r=$(_mrqd_fl raised "$flag"); [ -n "$r" ] || r=$(_mrqd_fl detected "$flag")
  [ -n "$r" ] && e=$(date -u -d "$r" +%s 2>/dev/null)
  [ -n "$e" ] || { log "self-dispatch: $slug flag's raised=/detected= ('$r') does not parse — no dispatch"; return 0; }
  held=$(( (${NOW:-$(date +%s)} - e) / 60 ))
  [ "$held" -ge "$min" ] || return 0

  key="$slug#$since"
  if type job_ledger_get >/dev/null 2>&1; then
    st=$(job_ledger_get main_red_qdispatch "$key" 2>/dev/null); rc=$?
  else rc=1; fi
  case "$rc" in
    0) log "self-dispatch: $slug already requested for the episode since $since ($st) — not again"; return 0 ;;
    2) ;;
    *) log "self-dispatch: $slug could not read the dispatch ledger — no dispatch this tick (never-twice outranks thaw)"; return 0 ;;
  esac

  runs=$(gh api -X GET "repos/$slug/actions/workflows/$wf/runs" -f branch=main -f per_page=20 \
           -q '[.workflow_runs[]? | {e:.event, s:.status, c:.conclusion, t:.created_at, id:.id}]' 2>/dev/null) \
    && jq -e 'type == "array"' >/dev/null 2>&1 <<<"$runs" \
    || { log "self-dispatch: $slug could not read main's runs of $wf — no dispatch this tick"; return 0; }
  fly=$(jq -r '[.[] | select(.s != "completed") | .id] | first // empty' <<<"$runs" 2>/dev/null)
  [ -z "$fly" ] || { log "self-dispatch: $slug $wf has a run in flight on main ($fly) — no dispatch"; return 0; }
  c=$(jq -r '[.[] | select(.e == "push" and .s == "completed")] | max_by(.t) | .c // "absent"' <<<"$runs" 2>/dev/null)
  [ "$c" = success ] || { log "self-dispatch: $slug main's newest push run of $wf is ${c:-absent} — no dispatch"; return 0; }

  if [ "${EXPLAIN:-0}" = 1 ]; then
    log "WOULD SELF-DISPATCH $slug $wf on main — queue freeze held $held min, main's newest push run is green"
    return 0
  fi

  { type job_ledger_put >/dev/null 2>&1 \
      && job_ledger_put main_red_qdispatch "$key" "dispatch=requested at=$(STAMP)" >/dev/null 2>&1; } \
    || { log "self-dispatch: $slug could not write the dispatch ledger row — no dispatch (a dispatch that cannot be recorded could repeat)"; return 0; }

  if out=$(gh api -X POST "repos/$slug/actions/workflows/$wf/dispatches" -f ref=main 2>&1); then
    log "SELF-DISPATCH: $slug $wf on main — queue freeze held $held min, main's newest push run is green; one dispatch for this episode"
    return 0
  fi
  first=$(head -1 <<<"$out" | cut -c1-200)
  job_ledger_put main_red_qdispatch "$key" "dispatch=refused at=$(STAMP)" >/dev/null 2>&1 \
    || log "self-dispatch: $slug could not mark the dispatch refused — the row still reads requested, so it is not retried either"
  log "self-dispatch: $slug $wf dispatch REFUSED: $first"
  alert warn "$slug: the merge-queue freeze has held $held min with main's push runs green, and the one self-dispatch of $wf on main was refused ($first). Dispatch it on main by hand: gh workflow run $wf -R $slug --ref main. It will not be retried this episode."
  return 0
}
