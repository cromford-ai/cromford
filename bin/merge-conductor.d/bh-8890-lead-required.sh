# shellcheck shell=bash
# bin/merge-conductor.d/bh-8890-lead-required.sh - A BUILDER APPROVE ALONE IS
# NOT READY ON A LEAD-REQUIRED REPO (BH-8890). Sourced by bin/merge-conductor.sh
# (the BH-7453 fragment block).
#
# mc_lead_req_hold — pr_worker calls it right after mc_mig_hold, with
# pr_worker's STATE, WHY, SLUG, NUM, KEY, HEAD, VERDICT, ACTIONS and KILL in
# scope, above every arm that labels, asks Mergify or merges. Every READY source
# (the builder's ledger APPROVE, the mc_lead_ready rebind, a patch-id rebind)
# passes here. On a repo whose lead_required.<owner>.<name> row is 1, a READY
# row needs a lead or human MERGE / MERGE-WITH-NOTES standing on HEAD
# (bin/lib/lead-required.sh). Without one the row is WAIT_LEAD:
#   * the row cannot be read, or the verdict cannot be read: held, no ask;
#   * another lead or human word stands (a BLOCK): held, no ask — a lead
#     already answered this head, and the block gate owns a BLOCK;
#   * nothing stands: held, and ONE lead review is asked per (PR, head)
#     through bin/lead-verdict.sh request. The attempts mark `leadreq <key>
#     <head>` is written BEFORE the ask, so a crash costs one ask, never a
#     storm. A failed ask is logged and not retried on that head; the hub lane
#     bin/lead-review-enqueue.sh stays the backstop.
# Observe mode or the kill switch: held, a WOULD line, no mark, no ask.
# The row is re-derived every tick, so the tick after the lead's MERGE is READY.
# shellcheck source=bin/lib/lead-required.sh
[ -r "$H/bin/lib/lead-required.sh" ] && . "$H/bin/lib/lead-required.sh"

mc_lead_req_hold() {
  [ "${STATE:-}" = READY ] || return 0
  [ -n "${KEY:-}" ] && [ -n "${HEAD:-}" ] && [ -n "${SLUG:-}" ] && [ -n "${NUM:-}" ] || return 0
  command -v lr_required >/dev/null 2>&1 && command -v lr_lead_stands >/dev/null 2>&1 || return 0
  command -v mc_step >/dev/null 2>&1 && mc_step lead-required
  local h8="${HEAD:0:8}" rrc=0 lrc=0 other out rc
  lr_required "$SLUG" || rrc=$?
  case "$rrc" in
    1) return 0 ;;
    0) ;;
    *) STATE=WAIT_LEAD
       WHY="WAIT_LEAD lead_required unreadable for $SLUG: held this tick, no lead review asked"
       mc_log "$KEY WAIT_LEAD on $h8: the lead_required row of $SLUG could not be read (or is not 0/1) — held this tick, nothing asked"
       return 0 ;;
  esac
  other=$(lr_lead_stands "$KEY" "$SLUG" "$NUM" "$HEAD") || lrc=$?
  case "$lrc" in
    0) if ! mc_attempt_has "leadreqok $KEY $HEAD" 2>/dev/null; then
         mc_attempt_put "leadreqok $KEY $HEAD"
         mc_log "$KEY LEAD_REQUIRED_OK on $h8: a lead or human MERGE stands on this head; READY"
       fi
       return 0 ;;
    1) ;;
    *) STATE=WAIT_LEAD
       WHY="WAIT_LEAD lead_required=1: lead verdict unreadable on $h8, held this tick"
       mc_log "$KEY WAIT_LEAD on $h8: the lead verdict could not be read — held this tick, nothing asked"
       return 0 ;;
  esac
  STATE=WAIT_LEAD
  if [ -n "$other" ]; then
    WHY="WAIT_LEAD lead_required=1: lead ${other%% *} stands on $h8 (source ${other#* }), no MERGE"
    case "${other%% *}" in BLOCK) WHY="WAIT_LEAD lead_required=1: lead BLOCK stands on $h8 (source ${other#* })" ;; esac
    mc_log "$KEY $WHY — no lead review asked, a lead already answered this head"
    return 0
  fi
  WHY="WAIT_LEAD lead_required=1: builder ${VERDICT:--} on $h8, no lead or human MERGE on this head"
  if [ "${ACTIONS:-0}" != 1 ] || [ "${KILL:-0}" = 1 ]; then
    mc_log "$KEY WOULD request a lead review of $h8 (lead_required=1, observe mode: nothing sent)"
    return 0
  fi
  mc_attempt_has "leadreq $KEY $HEAD" 2>/dev/null && return 0
  # The mark before the send: a crash costs one ask, never a storm.
  mc_attempt_put "leadreq $KEY $HEAD"
  out=$("$H/bin/lead-verdict.sh" request "$SLUG" "$NUM" "$HEAD" \
          --notes "auto: lead_required=1, builder ${VERDICT:--} on ${HEAD:0:12}" 2>&1); rc=$?
  out="${out%%$'\n'*}"; out="${out//[$'\t\r']/ }"
  if [ "$rc" = 0 ]; then
    mc_log "$KEY LEAD_REQUESTED on $h8: ${out:-no output} (lead_required=1, builder ${VERDICT:--} alone does not clear it)"
  else
    mc_log "$KEY LEAD_REQUEST_FAILED rc=$rc on $h8: ${out:-no output} — not retried on this head; bin/lead-review-enqueue.sh is the backstop"
  fi
  return 0
}
