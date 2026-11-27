#!/bin/bash
# bin/lib/review-verdict-status.sh — BH-9994: the PR review lane publishes the
# verdict commit status on the exact head it approved or blocked, for PRs the
# harness did not build. Sourced by bin/review-prs.sh, never executed.
#
# WHY (example-org/project-2, 2026-11-24). The Mergify queue there needs
# `check-success~=^(lead-verdict|harness-verdict)$`. The review lane APPROVED
# #868 and #878 (peer harness) and #891 (human) on their heads, and nothing
# wrote a status: mc_enqueue_mergify (bin/lib/mc/queue.sh) publishes on the
# harness PRs it enqueues, and bin/lead-verdict.sh post on a lead row. Every
# other PR waited for ever on the one condition left.
#
# WHO PUBLISHES WHAT (docs/notes/2026-11-24-BH-9994-review-verdict-status.md):
#   harness-authored PR       mc_enqueue_mergify, after its own head-bound gates
#   lead or human verdict     bin/lead-verdict.sh post
#   any other PR (this file)  rvs_publish, after the review lane's verdict
# The author test (harness_pr_author_match) keeps the first and the last apart:
# the two never write one PR.
#
# rvs_publish <num> <sha> <APPROVE|REQUEST_CHANGES> <author> <served>
#   Reads the caller's SLUG, STATE, LOG, PROJECT and RP_ADVISORY. In order:
#   1. RP_ADVISORY=1 or another verdict: rc 0, nothing written.
#   2. A harness author: rc 0, nothing written.
#   3. The state row's vs_sha is <sha> already: rc 0 (one write per head).
#   4. mc_queue_conductor_only rc 1 (no Mergify queue; a missing function
#      reads as "queue"): rc 0, nothing written, so a queue restored later is
#      backfilled on the next tick.
#   5. APPROVE: a fallback-served verdict records withheld-provenance;
#      la_decide rc 1 records withheld-authority, rc 2 records nothing (asked
#      again next tick); lr_required rc 0 with no lead MERGE standing records
#      withheld-lead-required, rc 2 records nothing. Else success on the
#      lr_clear_context context (lead-verdict only when a lead or human MERGE
#      stands, else harness-verdict).
#   6. REQUEST_CHANGES: a lead or human MERGE standing on <sha> outranks the
#      lane, so nothing is published (rc 0, nothing written). Else failure on
#      vs_builder_context (harness-verdict).
#   7. vs_publish rc 0: the row gets {vs_sha, vs_state, vs_ctx} (a merge
#      write) and one `verdict status ... published` log line. Any other rc:
#      one `verdict status NOT published` line quoting vs_publish's stderr,
#      no record, rc 1. merge_retry calls this again next tick.
#   A withheld state is recorded with vs_sha, so it is decided once per head.
# gh-rest: no-graphql
command -v vs_publish >/dev/null 2>&1 || { [ -r "${BASH_SOURCE[0]%/*}/verdict-status.sh" ] && . "${BASH_SOURCE[0]%/*}/verdict-status.sh"; }
command -v lr_clear_context >/dev/null 2>&1 || { [ -r "${BASH_SOURCE[0]%/*}/lead-required.sh" ] && . "${BASH_SOURCE[0]%/*}/lead-required.sh"; }

# _rvs_log <line> — one line in the lane log.
_rvs_log() {
  [ -n "${LOG:-}" ] || return 0
  printf '%s [%s] %s\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "${PROJECT:-?}" "$1" >> "$LOG"
}

# _rvs_record <num> <sha> <state> <ctx> — the merge write on the state row.
_rvs_record() {
  command -v rp_state_write >/dev/null 2>&1 || return 1
  rp_state_write --arg n "$1" --arg s "$2" --arg st "$3" --arg c "$4" \
    '.[$n] = ((.[$n] // {}) + {vs_sha:$s, vs_state:$st, vs_ctx:$c})'
}

rvs_publish() {
  local num="${1:-}" sha="${2:-}" verdict="${3:-}" author="${4:-}" served="${5:-}"
  local url state ctx desc err rc=0 lac=0 lrc=0 have
  [ "${RP_ADVISORY:-0}" = 1 ] && return 0
  case "$verdict" in APPROVE|REQUEST_CHANGES) ;; *) return 0 ;; esac
  [ -n "$num" ] && [ -n "$sha" ] && [ -n "${SLUG:-}" ] || return 0
  command -v harness_pr_author_match >/dev/null 2>&1 && harness_pr_author_match "$author" && return 0
  command -v vs_publish >/dev/null 2>&1 || { _rvs_log "#$num @${sha:0:7} verdict status not published: bin/lib/verdict-status.sh is not loaded"; return 1; }
  if [ -n "${STATE:-}" ] && [ -r "$STATE" ]; then
    have=$(jq -r --arg n "$num" '.[$n].vs_sha // ""' "$STATE" 2>/dev/null)
    [ "$have" = "$sha" ] && return 0
  fi
  if command -v mc_queue_conductor_only >/dev/null 2>&1; then
    mc_queue_conductor_only "$SLUG" || return 0
  fi
  url="https://github.com/$SLUG/pull/$num"
  if [ "$verdict" = APPROVE ]; then
    if ! { command -v rp_prov_is_claude >/dev/null 2>&1 && rp_prov_is_claude "$served"; }; then
      _rvs_log "#$num @${sha:0:7} verdict status withheld: the APPROVE was served by '${served:-unknown}', not the primary lane"
      _rvs_record "$num" "$sha" withheld-provenance ""
      return 0
    fi
    if command -v la_decide >/dev/null 2>&1; then
      la_decide "$SLUG" "$num" "$sha" conductor || lac=$?
      case "$lac" in
        0) ;;
        1) _rvs_log "#$num @${sha:0:7} verdict status withheld: a human verdict publishes it (${LA_REASON:-no reason given})"
           _rvs_record "$num" "$sha" withheld-authority ""
           return 0 ;;
        *) _rvs_log "#$num @${sha:0:7} verdict status not published this tick: the lead authority could not be decided (${LA_REASON:-no reason given})"
           return 1 ;;
      esac
    fi
    if command -v lr_required >/dev/null 2>&1; then
      lr_required "$SLUG" || lrc=$?
      case "$lrc" in
        0) if ! lr_lead_stands - "$SLUG" "$num" "$sha" >/dev/null 2>&1; then
             _rvs_log "#$num @${sha:0:7} verdict status withheld: $SLUG requires a lead verdict (lead_required) and none stands on this head"
             _rvs_record "$num" "$sha" withheld-lead-required ""
             return 0
           fi ;;
        1) ;;
        *) _rvs_log "#$num @${sha:0:7} verdict status not published this tick: the lead_required row of $SLUG could not be read"
           return 1 ;;
      esac
    fi
    LR_CTX=$(vs_builder_context)
    command -v lr_clear_context >/dev/null 2>&1 && lr_clear_context "$SLUG" "$num" "$sha"
    ctx="$LR_CTX"; state=success; desc="review lane approved ${sha:0:12}"
  else
    if command -v lr_lead_stands >/dev/null 2>&1 && lr_lead_stands - "$SLUG" "$num" "$sha" >/dev/null 2>&1; then
      _rvs_log "#$num @${sha:0:7} verdict status failure not published: a lead or human MERGE stands on this head and outranks the lane"
      return 0
    fi
    ctx=$(vs_builder_context); state=failure; desc="review lane requested changes on ${sha:0:12}"
  fi
  # stderr to a file, never a $( ): vs_publish's one line is the reason.
  err=$(mktemp "${TMPDIR:-/tmp}/rvs.XXXXXX") || return 1
  LEAD_VERDICT_CONTEXT="$ctx" vs_publish "$SLUG" "$sha" "$state" "$desc" "$url" 2>"$err" || rc=$?
  if [ "$rc" = 0 ]; then
    rm -f "$err"
    _rvs_record "$num" "$sha" "$state" "$ctx"
    _rvs_log "#$num @${sha:0:7} verdict status $state $ctx published on ${sha:0:12}"
    return 0
  fi
  _rvs_log "#$num @${sha:0:7} verdict status NOT published ($state $ctx, rc $rc): $(head -1 "$err" 2>/dev/null) — retried next tick"
  rm -f "$err"
  return 1
}

# rvs_supersede <num> <sha> <author> — the lead overrides a lane BLOCK
#   (lead review of b4ad52d5). rvs_publish wrote harness-verdict=failure on
#   <sha>; a lead or human MERGE then lands on the SAME head. Mergify renders
#   `-check-failure=harness-verdict`, so that failure would veto the lead's
#   MERGE until the author pushed a new head. Called by merge_retry every tick
#   for a REQUEST_CHANGES row. It republishes harness-verdict as success ONLY
#   when all of these hold, else it writes nothing (rc 0):
#     - not advisory, not a harness author, a Mergify repo;
#     - the state row records THIS lane's own failure on <sha>
#       (vs_sha=<sha>, vs_state=failure, vs_ctx=vs_builder_context);
#     - lr_lead_stands rc 0 on <sha>: a lead or human MERGE stands on it.
#   The success says what it is ("superseded by lead MERGE"), and the row
#   records vs_state=superseded-by-lead, so it is written once per head. A
#   later lead BLOCK still vetoes through `-check-failure=lead-verdict`.
#   A failed POST records nothing: retried next tick, rc 1.
rvs_supersede() {
  local num="${1:-}" sha="${2:-}" author="${3:-}" ctx row err rc=0
  [ "${RP_ADVISORY:-0}" = 1 ] && return 0
  [ -n "$num" ] && [ -n "$sha" ] && [ -n "${SLUG:-}" ] && [ -n "${STATE:-}" ] && [ -r "$STATE" ] || return 0
  command -v harness_pr_author_match >/dev/null 2>&1 && harness_pr_author_match "$author" && return 0
  command -v vs_publish >/dev/null 2>&1 && command -v vs_builder_context >/dev/null 2>&1 || return 0
  command -v lr_lead_stands >/dev/null 2>&1 || return 0
  ctx=$(vs_builder_context)
  row=$(jq -r --arg n "$num" '.[$n] | "\(.vs_sha // "")\t\(.vs_state // "")\t\(.vs_ctx // "")"' "$STATE" 2>/dev/null) || return 0
  [ "$row" = "$sha"$'\t'"failure"$'\t'"$ctx" ] || return 0
  if command -v mc_queue_conductor_only >/dev/null 2>&1; then
    mc_queue_conductor_only "$SLUG" || return 0
  fi
  lr_lead_stands - "$SLUG" "$num" "$sha" >/dev/null 2>&1 || return 0
  err=$(mktemp "${TMPDIR:-/tmp}/rvs.XXXXXX") || return 1
  LEAD_VERDICT_CONTEXT="$ctx" vs_publish "$SLUG" "$sha" success "lane failure superseded by lead MERGE on ${sha:0:12}" \
    "https://github.com/$SLUG/pull/$num" 2>"$err" || rc=$?
  if [ "$rc" = 0 ]; then
    rm -f "$err"
    _rvs_record "$num" "$sha" superseded-by-lead "$ctx"
    _rvs_log "#$num @${sha:0:7} verdict status success $ctx published on ${sha:0:12}: the lane failure is superseded by a standing lead MERGE"
    return 0
  fi
  _rvs_log "#$num @${sha:0:7} verdict status supersede NOT published (success $ctx, rc $rc): $(head -1 "$err" 2>/dev/null) — retried next tick"
  rm -f "$err"
  return 1
}
