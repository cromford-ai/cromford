# shellcheck shell=bash
# bin/merge-conductor.d/bh-9823-one-verdict.sh - ONE REVIEW VERDICT OF RECORD
# PER HEAD, AND NO QUEUE WHILE A LEAD REVIEW OF THAT HEAD IS PENDING (BH-9823).
# Sourced by bin/merge-conductor.sh (the BH-7453 fragment block).
#
# THE DEFECT (PR #9811, 2026-11-18). On a HEAD_MOVED head the conductor
# consumed the >12h autopilot MERGE (headbound_review, bin/lib/mc/classify.sh)
# while a lead review of the same head was running. The rebind moved the
# builder APPROVE onto the head, the head went READY and was enqueued, and the
# lead BLOCK that came 10 minutes later dequeued it: two verdicts on one head,
# 2 queue cycles, 0 CI runs. The lead lane half of the fix is gate 12
# (bin/lib/lead-gates.d/12-autopilot-bound.sh).
#
# THE RULE. A lead_review_requests row on THIS exact head with status
# `requested` or `running` is a pending lead review. While one is pending and
# younger than MC_LEAD_REVIEW_WAIT_S:
#   * HEAD_MOVED (mc_ovh_moved_hold, before headbound_review): the row stays
#     HEAD_MOVED with a WAIT_LEAD_REVIEW why. No autopilot consume, no rebind,
#     no comment, no re-review bought, no budget unit.
#   * READY (mc_ovh_ready_hold, after mc_lead_req_hold): the row is WAIT_LEAD.
#     No queue call, no merge unit.
# When the request ends, on a head the conductor waited on, the lead verdict
# is the verdict of record: a lead/human MERGE rebinds (hb_approve_bind) with a
# comment that names the lead review, a lead/human BLOCK parks the row
# head-not-reapproved for bin/blocked-resolver.sh (hb_block_park). A request
# that ended with no verdict takes today's path.
# Past the limit: ONE warn alert per (PR, head) (mark `ovhlimit`, written
# before the alert), then today's path with the autopilot verdict.
# An unreadable request list is fail OPEN: today's path, one log line per
# (PR, head) (mark `ovhunread`). A hold on every worker outage would stop every
# enqueue of the fleet.
# Every queue decision line carries `review_source=<word>` (mc_ovh_source).
#
# Attempts marks (mc_attempt_put, `<kind> <key> <head>`): ovhwait (the
# conductor waited on this head), ovhwaitlog (the wait line was logged),
# ovhlimit (the overdue alert was sent), ovhunread (the unread line was
# logged), ovhlead (a lead verdict was applied on this head).

# mc_ovh_wait_s — the wait limit in seconds. Knob MC_LEAD_REVIEW_WAIT_S
# (catalog/lanes.d/merge-conductor.knobs.d/MC_LEAD_REVIEW_WAIT_S.json, settings
# row lane.merge-conductor.mc_lead_review_wait_s). 0 = off. Not a whole number:
# the fallback 2700, which is MC_REREVIEW_TIMEOUT_SECS, the conductor's own
# limit for a head-bound read. The knob is `required`, so lane_env_apply
# exports its registry default; 2700 here is only the documented fallback for
# an unset or non-number value.
mc_ovh_wait_s() {
  local v="${MC_LEAD_REVIEW_WAIT_S:-}"
  case "$v" in ''|*[!0-9]*) v=2700 ;; esac
  printf '%s' "$((10#$v))"
}

# mc_ovh_lead_pending <slug> <num> <head> — ONE GET /api/lead-reviews?repo=&pr=
# &status=requested,running (LR_LIST_PR_SQL, the UNIQUE(repo, pr, head_sha)
# autoindex). The status is checked again here, on the row of THIS head.
#   rc 0 + `<status>\t<age_s>\t<id>` | rc 1 no pending row on this head |
#   rc 2 unreadable (no client, a failed read, no .requests array).
# Memoised per (num, head) in this process (_MC_OVH_MEMO_K/_RC/_V, set on the
# first call; a fragment sets no top-level variable, BH-7453).
mc_ovh_lead_pending() {
  local slug="$1" num="$2" head resp row st at id ts age rc=0
  head=$(printf '%s' "${3:-}" | tr 'A-F' 'a-f')
  if [ "${_MC_OVH_MEMO_K:-}" = "$slug#$num $head" ]; then
    [ -n "$_MC_OVH_MEMO_V" ] && printf '%s\n' "$_MC_OVH_MEMO_V"
    return "$_MC_OVH_MEMO_RC"
  fi
  if ! command -v _jobs_req >/dev/null 2>&1; then
    rc=2
  elif ! resp=$(JOBS_ALERT=0 _jobs_req GET "/api/lead-reviews?repo=$slug&pr=$num&status=requested,running" 2>/dev/null </dev/null) \
       || ! printf '%s' "$resp" | jq -e '.requests | type == "array"' >/dev/null 2>&1; then
    rc=2
  else
    row=$(printf '%s' "$resp" | jq -r --arg h "$head" '
      [.requests[] | select(((.head_sha // "") | ascii_downcase) == $h and (.status == "requested" or .status == "running"))]
      | first // empty | [.status, (.created_at // ""), (.id // "-" | tostring)] | @tsv' 2>/dev/null) || rc=2
    if [ "$rc" = 0 ] && [ -z "$row" ]; then rc=1; fi
  fi
  _MC_OVH_MEMO_V=""
  if [ "$rc" = 0 ]; then
    IFS=$'\t' read -r st at id <<<"$row"
    # An unreadable created_at reads as past the limit: a wait must end.
    # GNU date reads "" as today 00:00Z, so an empty created_at is guarded first.
    if [ -n "$at" ] && ts=$(date -u -d "$at" +%s 2>/dev/null); then age=$(( $(date -u +%s) - ts )); [ "$age" -ge 0 ] || age=0
    else age=999999999; fi
    _MC_OVH_MEMO_V=$(printf '%s\t%s\t%s' "$st" "$age" "${id:--}")
    printf '%s\n' "$_MC_OVH_MEMO_V"
  fi
  _MC_OVH_MEMO_K="$slug#$num $head"; _MC_OVH_MEMO_RC="$rc"
  return "$rc"
}

# mc_ovh_decide <key> <slug> <num> <head> <url> <state> — the one decision
# rule for both holds. Sets MC_OVH_WHY (wait|none|unread|limit|off),
# MC_OVH_ST, MC_OVH_AGE, MC_OVH_ID, MC_OVH_LIM, and MC_OVH_SRC (the source of
# record this tick, when the decision fixes it; else empty) for (key, head) in
# MC_OVH_FOR. rc 0 = WAIT, rc 1 = GO.
mc_ovh_decide() {
  local key="$1" slug="$2" num="$3" head="$4" url="$5" state="$6" out rc=0
  MC_OVH_FOR="$key $head"; MC_OVH_WHY=""; MC_OVH_SRC=""; MC_OVH_ST=""; MC_OVH_AGE=""; MC_OVH_ID=""
  MC_OVH_LIM=$(mc_ovh_wait_s)
  if [ "$MC_OVH_LIM" = 0 ]; then MC_OVH_WHY=off; return 1; fi
  # Not in a $( ): the memo must live in this shell.
  mc_ovh_lead_pending "$slug" "$num" "$head" >/dev/null || rc=$?
  out="$_MC_OVH_MEMO_V"
  case "$rc" in
    0) IFS=$'\t' read -r MC_OVH_ST MC_OVH_AGE MC_OVH_ID <<<"$out" ;;
    1) MC_OVH_WHY=none; return 1 ;;
    *) MC_OVH_WHY=unread; MC_OVH_SRC="+lead-unread"
       if ! mc_attempt_has "ovhunread $key $head" 2>/dev/null; then
         mc_attempt_put "ovhunread $key $head"
         mc_log "$key lead review requests of ${head:0:8} could not be read — today's path this tick, nothing held (BH-9823)"
       fi
       return 1 ;;
  esac
  if [ "$MC_OVH_AGE" -ge "$MC_OVH_LIM" ] 2>/dev/null; then
    MC_OVH_WHY=limit; MC_OVH_SRC=autopilot-after-lead-limit
    if ! mc_attempt_has "ovhlimit $key $head" 2>/dev/null; then
      # The mark before the alert: a crash costs one alert, never a storm.
      mc_attempt_put "ovhlimit $key $head"
      mc_log "$key LEAD_REVIEW_OVERDUE on ${head:0:8}: lead review $MC_OVH_ST (request $MC_OVH_ID) for ${MC_OVH_AGE}s, limit ${MC_OVH_LIM}s — the conductor stops waiting and uses the autopilot verdict review_source=$MC_OVH_SRC"
      mc_alert "$key" "$state" "LEAD_REVIEW_OVERDUE: the lead review of ${head:0:12} is $MC_OVH_ST (request $MC_OVH_ID) for ${MC_OVH_AGE}s, past MC_LEAD_REVIEW_WAIT_S=${MC_OVH_LIM}s; the conductor now uses the autopilot verdict: $url"
    fi
    return 1
  fi
  MC_OVH_WHY=wait; MC_OVH_SRC=lead-pending
  mc_attempt_has "ovhwait $key $head" 2>/dev/null || mc_attempt_put "ovhwait $key $head"
  if ! mc_attempt_has "ovhwaitlog $key $head" 2>/dev/null; then
    mc_attempt_put "ovhwaitlog $key $head"
    mc_log "$key WAIT_LEAD_REVIEW on ${head:0:8}: lead review $MC_OVH_ST (request $MC_OVH_ID, ${MC_OVH_AGE}s of ${MC_OVH_LIM}s) — no rebind and no queue until its verdict lands review_source=$MC_OVH_SRC"
  fi
  return 0
}

# mc_ovh_moved_hold — pr_worker's HEAD_MOVED arm, before headbound_review, with
# KEY SLUG NUM P URL REC HEAD REVIEWED VERDICT MSTATE CI in scope.
# rc 0 = this tick is done with the PR; rc 1 = go on to headbound_review.
mc_ovh_moved_hold() {
  [ -n "${KEY:-}" ] && [ -n "${HEAD:-}" ] && [ -n "${SLUG:-}" ] && [ -n "${NUM:-}" ] || return 1
  local h8="${HEAD:0:8}" h12="${HEAD:0:12}" line vrc=0 v src
  if mc_ovh_decide "$KEY" "$SLUG" "$NUM" "$HEAD" "${URL:-}" HEAD_MOVED; then
    mc_transition "$KEY" HEAD_MOVED "WAIT_LEAD_REVIEW $h8 (lead review $MC_OVH_ST, ${MC_OVH_AGE}s of ${MC_OVH_LIM}s) review_source=lead-pending" \
      "$HEAD" "${REVIEWED:-}" "${URL:-}" "${VERDICT:-}" "${MSTATE:-}" "${REC:-}" >/dev/null
    return 0
  fi
  # GO. Only a head the conductor waited on, whose request ended, reads the
  # lead verdict here; everything else is today's path.
  [ "$MC_OVH_WHY" = none ] || return 1
  mc_attempt_has "ovhwait $KEY $HEAD" 2>/dev/null || return 1
  command -v vd_standing >/dev/null 2>&1 || return 1
  line=$(vd_standing "$SLUG" "$NUM" "$HEAD" 2>/dev/null) || vrc=$?
  if [ "$vrc" != 0 ]; then
    mc_log "$KEY the lead review of $h8 ended and no lead verdict stands on it (verdicts read rc $vrc) — today's path"
    return 1
  fi
  IFS=$'\t' read -r v src _ <<<"$line"
  case "$src" in lead|human) ;; *) return 1 ;; esac
  case "$v" in
    BLOCK)
      hb_block_park "$KEY" "${URL:-}" "${REC:-}" "$HEAD" "${REVIEWED:-}" "${MSTATE:-}" \
        "$(printf '_Merge conductor: the %s review of %s verdicted BLOCK on this exact head; that is the verdict of record. Parked as head-not-reapproved and handed to bin/blocked-resolver.sh. The autopilot verdict was not used._' "$src" "$h12")" \
        "the $src review of $h12 verdicted BLOCK on this exact head after the conductor waited for it review_source=$src"
      return 0 ;;
    MERGE|MERGE-WITH-NOTES)
      [ "${CI:-}" = green ] || return 1
      if mc_attempt_has "ovhlead $KEY $HEAD" 2>/dev/null; then
        # Applied on an earlier tick and the row is HEAD_MOVED again: re-bind, say nothing new.
        hb_approve_bind moved "$KEY" "$SLUG" "${P:-}" "$NUM" "${URL:-}" "${REC:-}" "$HEAD" "${MSTATE:-}" ""
        return 0
      fi
      mc_attempt_put "ovhlead $KEY $HEAD"
      mc_log "$KEY LEAD_VERDICT applied: $v by $src on $h8 after the conductor waited for it — approval rebound, the autopilot verdict was not used review_source=$src"
      hb_approve_bind moved "$KEY" "$SLUG" "${P:-}" "$NUM" "${URL:-}" "${REC:-}" "$HEAD" "${MSTATE:-}" \
        "$(printf '_Merge conductor: the %s review of %s verdicted %s on this exact head; that is the verdict of record. Approval rebound; the autopilot verdict was not used._' "$src" "$h12" "$v")"
      return 0 ;;
  esac
  return 1
}

# mc_ovh_ready_hold — right after mc_lead_req_hold in pr_worker, with STATE WHY
# KEY SLUG NUM URL HEAD in scope. Acts only on READY.
mc_ovh_ready_hold() {
  [ "${STATE:-}" = READY ] || return 0
  [ -n "${KEY:-}" ] && [ -n "${HEAD:-}" ] && [ -n "${SLUG:-}" ] && [ -n "${NUM:-}" ] || return 0
  if mc_ovh_decide "$KEY" "$SLUG" "$NUM" "$HEAD" "${URL:-}" READY; then
    STATE=WAIT_LEAD
    WHY="WAIT_LEAD one-verdict: lead review $MC_OVH_ST on ${HEAD:0:8} (request $MC_OVH_ID, ${MC_OVH_AGE}s of ${MC_OVH_LIM}s) review_source=lead-pending"
  fi
  return 0
}

# mc_ovh_source <key> <slug> <num> <head> — the review source of record for the
# head, one word: what this tick's decision fixed; else a lead/human MERGE
# standing on the head; else the attempts marks; else `builder`.
mc_ovh_source() {
  local key="$1" slug="$2" num="$3" head="$4" line src="" sfx=""
  if [ "${MC_OVH_FOR:-}" = "$key $head" ] && [ -n "${MC_OVH_SRC:-}" ]; then
    case "$MC_OVH_SRC" in +*) sfx="$MC_OVH_SRC" ;; *) printf '%s' "$MC_OVH_SRC"; return 0 ;; esac
  fi
  if command -v vd_standing >/dev/null 2>&1 && line=$(vd_standing "$slug" "$num" "$head" 2>/dev/null); then
    case "$(cut -f1,2 <<<"$line")" in
      MERGE$'\t'lead|MERGE-WITH-NOTES$'\t'lead) src=lead ;;
      MERGE$'\t'human|MERGE-WITH-NOTES$'\t'human) src=human ;;
    esac
  fi
  if [ -z "$src" ]; then
    if mc_attempt_has "ovhlead $key $head" 2>/dev/null; then src=lead
    elif mc_attempt_has "apverdict $key $head" 2>/dev/null; then src=autopilot
    elif mc_attempt_has "rbverdict $key $head" 2>/dev/null; then src=bound
    elif mc_attempt_has "rereviewdone $key $head" 2>/dev/null; then src=conductor-rereview
    else src=builder; fi
  fi
  printf '%s%s' "$src" "$sfx"
}
