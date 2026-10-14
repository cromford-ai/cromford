#!/bin/bash
# gh-identity: raw-by-design — same shape as lib/block-gate.sh: its reads run INSIDE a lane that has ALREADY armed the identity that can see this repo (the conductor per project, pipeline-health per repo), and a second mint here would override that choice.
# bin/lib/mc-stale-dequeue.sh — A STALE MERGIFY DEQUEUE GOES BACK IN ONCE A
# FRESH VERDICT BINDS THE NEW HEAD (BH-3480). Sourced by bin/merge-conductor.sh
# and bin/pipeline-health.sh, never executed.
#
# THE CASE (#3396, 2026-09-29). Mergify dequeued the PR for a failing check at
# 02:03 and said so in its payload comment. A fix was pushed at 03:36 and
# re-approved, and the PR still carried our merge-queue label, so the conductor
# read the row as QUEUED (mc_mergify_inqueue: our label plus a row that was
# QUEUED last tick). Mergify ignores a plain `@mergifyio queue` on a dequeued
# PR, and nothing posted `@mergifyio requeue` until a person did at 03:45.
#
# THE RULE. A PR carrying merge-queue (and neither of Mergify's own queued /
# checking labels), whose newest Mergify payload says `dequeued`, is requeued
# ONCE per (PR, head) when a verdict newer than the dequeue binds its current
# head: a lead/human MERGE or MERGE-WITH-NOTES row on HEAD created after it, or
# the conductor's own head-bound approval on a head committed after it. The
# one-per-head fact is BH-636's `requeued <key> <head>` mark, so the two arms
# share one requeue per head. A head dequeued AGAIN after its requeue goes to
# the blocked-resolver (BLOCKED_HUMAN queue-ejected-twice), never another post.
#
# THE DEQUEUE TIME. The payload carries no sha and no timestamp of its own, so
# the time is the payload comment's updated_at. The comment is chosen by
# (created_at, id), the order bin/triage-state-pr.py uses: Mergify EDITS an
# older status comment after a newer one exists (#3396's dequeued comment got
# its "Requeued — continues in" link at 03:45:49), so updated_at cannot pick
# the newest one.
#
# No root, no paths, no clock of its own: everything is gh and the mc_* verbs.

SDQ_PAYLOAD_RE='-\*- Mergify Payload -\*-(?<p>[\s\S]*?)-\*- Mergify Payload End -\*-'

# sdq_payload_last <owner/repo> <num>
#   rc 0 -> prints state<TAB>updated_epoch<TAB>comment_id of the newest
#           mergify[bot] comment carrying a payload block
#   rc 1 -> no such comment
#   rc 2 -> the read failed, or that payload does not parse to a string state
sdq_payload_last() {
  local slug="$1" num="$2" raw line _s _t
  case "$num" in ''|*[!0-9]*) return 2 ;; esac
  raw=$(gh api --paginate "repos/$slug/issues/$num/comments?per_page=100" 2>/dev/null) || return 2
  line=$(printf '%s' "$raw" | jq -sr --arg re "$SDQ_PAYLOAD_RE" '
    [ .[] | if type == "array" then .[] else error("not a comment list") end
      | select(type == "object" and (.user.login // "") == "mergify[bot]"
               and ((.body // "") | type == "string") and ((.body // "") | test($re))) ]
    | sort_by([(.created_at // ""), (.id // 0)]) | last
    | if . == null then "NONE"
      else [ ((.body | capture($re).p | fromjson? | .state) // "-" | if type == "string" and . != "" then . else "-" end),
             ((.updated_at // .created_at // "") | sub("\\.[0-9]+"; "") | (fromdateiso8601? // "")),
             (.id | tostring) ] | @tsv end' 2>/dev/null) || return 2
  [ "$line" = NONE ] && return 1
  IFS=$'\t' read -r _s _t _ <<<"$line"
  [ "$_s" != - ] && [[ "$_t" =~ ^[0-9]+$ ]] || return 2
  printf '%s\n' "$line"
}

# sdq_head_pushed_epoch <owner/repo> <sha> — the head commit's committer date as
#   epoch seconds (rc 0), or rc 2 when it cannot be read.
sdq_head_pushed_epoch() {
  local d e
  d=$(gh api "repos/$1/commits/$2" --jq '.commit.committer.date' 2>/dev/null) || return 2
  [ -n "$d" ] && [ "$d" != null ] || return 2
  e=$(date -u -d "$d" +%s 2>/dev/null) || return 2
  [[ "$e" =~ ^[0-9]+$ ]] || return 2
  printf '%s' "$e"
}

# sdq_decide <state> <T> <head_epoch> <lead_word> <lead_epoch> <box_bound> <requeued_epoch> <labels-csv> [grace_s]
#   PURE. Prints one word: requeue | resolver | wait | none. `-` or empty is
#   "absent" for every epoch and word.
#   grace_s (default 300): a dequeue must be this much LATER than our requeue
#   to count as a second one. Mergify edits the old dequeued comment the moment
#   it takes a requeue (#3396: 03:45:49, the same second it answered), and a
#   read between that edit and its new status comment would otherwise look like
#   a re-dequeue. A real one needs a whole batch CI run, minutes not seconds.
sdq_decide() {
  local st="$1" t="$2" he="$3" lw="$4" le="$5" bb="$6" rq="$7" lbl="${8:-}" g="${9:-300}"
  local num='^[0-9]+$'
  [[ "$g" =~ $num ]] || g=300
  if ! grep -qE "(^|,)${MC_MERGIFY_LABEL:-merge-queue}(,|\$)" <<<"$lbl" || grep -qE '(^|,)(queued|checking)(,|$)' <<<"$lbl"; then
    echo none; return 0
  fi
  [ "$st" = dequeued ] && [[ "$t" =~ $num ]] || { echo none; return 0; }
  if [[ "$rq" =~ $num ]]; then
    if [ "$t" -gt $(( rq + g )) ]; then echo resolver; else echo wait; fi
    return 0
  fi
  [ "$lw" = BLOCK ] && { echo none; return 0; }
  case "$lw" in
    MERGE|MERGE-WITH-NOTES) [[ "$le" =~ $num ]] && [ "$le" -gt "$t" ] && { echo requeue; return 0; } ;;
  esac
  [ "$bb" = 1 ] && [[ "$he" =~ $num ]] && [ "$he" -gt "$t" ] && { echo requeue; return 0; }
  echo none
}

# sdq_arm — the conductor's call site. Reads the pr_worker's globals (SLUG NUM
# KEY HEAD URL P RAWLBL VERDICT REVIEWED MERGES MGABLE MSTATE CI) and may set
# STATE and WHY. The caller gates it (queue on Mergify, no CR hold, READY or
# QUEUED, labelled, not visibly queued), so this spends reads only on a PR the
# queue is not holding. Any read it cannot make leaves the row as it is.
sdq_arm() {
  local pl pst pt he="-" lw="-" le="-" bb=0 rq vline word rqerr rqrc
  pl=$(sdq_payload_last "$SLUG" "$NUM"); case $? in
    0) ;;
    1) return 0 ;;
    *) mc_log "$KEY stale-dequeue check: the Mergify payload could not be read on ${HEAD:0:8} — nothing done this tick"; return 0 ;;
  esac
  IFS=$'\t' read -r pst pt _ <<<"$pl"
  [ "$pst" = dequeued ] || return 0
  rq=$(mc_requeued_mark "$KEY" "$HEAD")
  if [ -z "$rq" ]; then
    command -v vd_standing >/dev/null 2>&1 || { [ -r "${BASH_SOURCE[0]%/*}/verdicts.sh" ] && . "${BASH_SOURCE[0]%/*}/verdicts.sh"; }
    if command -v vd_standing >/dev/null 2>&1; then
      vline=$(vd_standing "$SLUG" "$NUM" "$HEAD"); case $? in
        0) lw=$(cut -f1 <<<"$vline"); le=$(cut -f4 <<<"$vline")
           { [ -n "$le" ] && le=$(date -u -d "$le" +%s 2>/dev/null); } || le="-" ;;
        1) ;;
        *) mc_log "$KEY stale-dequeue check: the verdicts on ${HEAD:0:8} could not be read — nothing done this tick"; return 0 ;;
      esac
    fi
    if [ "${VERDICT:-}" = APPROVE ] && [ "${REVIEWED:-}" = "$HEAD" ]; then
      bb=1
      he=$(sdq_head_pushed_epoch "$SLUG" "$HEAD") \
        || { he="-"; mc_log "$KEY stale-dequeue check: the commit date of ${HEAD:0:8} could not be read — the approval is not counted as fresh this tick"; }
    fi
  fi
  word=$(sdq_decide "$pst" "$pt" "$he" "$lw" "$le" "$bb" "${rq:--}" "${RAWLBL:-}")
  # A VERDICT DOES NOT CLEAR A CULPRIT'S EJECTION (BH-5819, the operator 2026-10-08 on
  # #5430): at 06:28Z this arm put #5221/#5281/#5301 back in on verdicts
  # re-landed by hand on the SAME heads that had failed. Before a requeue the
  # head is asked the culprit question (mc_eject_culprit_mark: a `dqwculprit`
  # mark from dequeue-watch, a human dequeue, a failed solo check cached before
  # this tick's gate), and a culprit head (mc_ejected_hold) is never requeued
  # here; only a new head clears it. NOT gated on an `ejected` line: this arm is
  # for the ejection the conductor never saw, so there is none (lead review of
  # 2cc40e58). A bystander keeps this arm's requeue.
  if [ "$word" = requeue ] && command -v mc_ejected_hold >/dev/null 2>&1 \
     && { mc_eject_culprit_mark "$SLUG" "$NUM" "$KEY" "$HEAD" "${EJSOLO:-0}" >/dev/null 2>&1; mc_ejected_hold "$KEY" "$HEAD"; }; then
    STATE=WAIT_CI; WHY="ejected on ${HEAD:0:8} as the culprit: a verdict newer than the dequeue does not clear it; only a new head does"
    mc_attempt_has "sdqejectedlog $KEY $HEAD" 2>/dev/null || { mc_attempt_put "sdqejectedlog $KEY $HEAD"
      mc_log "STALE_DEQUEUE_EJECTED $KEY $HEAD — a verdict newer than the dequeue binds this head, but it is the culprit of its ejection: not requeued, only a new head clears it"; }
    return 0
  fi
  case "$word" in
    requeue)
      if [ "${MERGES:-0}" != 1 ]; then
        mc_log "STALE_DEQUEUE_WOULD_REQUEUE $KEY $HEAD (merge mode off) — Mergify dequeued it at $(date -u -d "@$pt" +%H:%MZ) and a verdict newer than that binds this head"
      elif [ "${MGABLE:-}" != MERGEABLE ] || [ "${MSTATE:-}" = DIRTY ] || [ "${CI:-}" = red ]; then
        mc_log "STALE_DEQUEUE_WAIT $KEY $HEAD — dequeued and freshly approved, but mergeable=${MGABLE:-?} state=${MSTATE:-?} ci=${CI:-?}; the rebase and red ladders own it"
      # BH-6161: the pre-queue gate first, on a run dispatched after the dequeue.
      elif command -v ec_requeue_gate >/dev/null 2>&1 \
           && ! ec_requeue_gate "$SLUG" "$NUM" "$URL" "$HEAD" "${PBASE:-}" "$pt"; then
        case "$EC_PQ_WORD" in
          red)    STATE=BLOCKED_HUMAN; WHY="$EC_PQ_WHY" ;;
          rebase) STATE=NEEDS_REBASE;  WHY="prequeue after ejection: $EC_PQ_WHY" ;;
          *)      STATE=WAIT_CI;       WHY="dequeued by Mergify; $EC_PQ_WHY" ;;
        esac
      elif ! mc_tick_budget_take "$P" requeue "${MC_REQUEUE_CAP:-5}"; then
        mc_log "$KEY REQUEUE_DEFERRED $KEY $HEAD — this project has spent its ${MC_REQUEUE_CAP:-5} re-queues for this tick; re-offered on the next one"
        STATE=WAIT_CI; WHY="dequeued by Mergify; requeue deferred to the next tick"
      else
        # The mark BEFORE the write, as in BH-636: a crash between the two costs
        # this head its one requeue, never a loop of posts.
        mc_requeued_record "$KEY" "$HEAD"
        rqerr=$(mc_requeue_mergify "$SLUG" "$URL" "$HEAD"); rqrc=$?
        case "$rqrc" in
          0|2) STATE=QUEUED; WHY="requeued on ${HEAD:0:8} after a stale Mergify dequeue"
               mc_count_inc "$P" staledequeue_requeue >/dev/null
               mc_log "STALE_DEQUEUE_REQUEUED $KEY $HEAD — Mergify dequeued it at $(date -u -d "@$pt" +%H:%MZ), a newer verdict binds this head, @mergifyio requeue posted and acknowledged" ;;
          3)   STATE=WAIT_CI; WHY="requeued on ${HEAD:0:8}, awaiting Mergify's witness"
               mc_log "REQUEUE_UNWITNESSED $KEY $HEAD — ${rqerr:-Mergify acknowledged nothing}. The row waits; it is NOT merged directly" ;;
          *)   STATE=WAIT_CI; WHY="dequeued by Mergify; the requeue was refused"
               mc_log "REQUEUE_FAILED $KEY $HEAD — ${rqerr:-the requeue was refused}; this head keeps its requeue mark and is not tried again" ;;
        esac
      fi ;;
    resolver)
      mc_attempt_has "reejected $KEY $HEAD" 2>/dev/null || mc_attempt_put "reejected $KEY $HEAD"
      STATE=BLOCKED_HUMAN; WHY="queue-ejected-twice"
      command -v ec_summary >/dev/null 2>&1 && vline=$(ec_summary "$SLUG" "$NUM") && [ -n "$vline" ] && WHY="queue-ejected-twice: $vline"
      mc_log "STALE_DEQUEUE_RESOLVER $KEY $HEAD — Mergify dequeued this head again after its one requeue; the blocked-resolver owns it" ;;
    wait)
      STATE=WAIT_CI; WHY="requeued on ${HEAD:0:8}, waiting for Mergify to acknowledge — never re-queued twice" ;;
  esac
  return 0
}
