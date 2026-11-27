#!/bin/bash
# shellcheck shell=bash
# bin/lib/mc/external-enqueue.sh — BH-4580 (BH-4572.1): an approved, green,
# clean PR from an EXTERNAL author on a Mergify repo asks Mergify to queue it.
# Sourced by bin/merge-conductor.sh, never run.
#
# WHY IT EXISTS. On 2026-10-05 project-4 had 19 PRs from its engineer, each one
# APPROVED by bin/review-prs.sh on its current head and mergeable_state clean,
# none merged. review-prs hands every Mergify-repo APPROVE to the conductor
# (mc_queue_conductor_only), but the conductor lists only HARNESS_PR_AUTHORS'
# PRs (harness_pr_list, mc_is_harness_pr), so nothing consumed the hand-off.
# Those two stay as they are: every lane reads them. This is a second,
# additive enumeration.
#
# xe_project <project> <slug> <provider> <pbase>
#   Called right after ae_project, once per project per conductor tick. ONE REST
#   page of open PRs; each row whose author is NOT harness_pr_author_match goes
#   through bin/lib/autoenqueue.sh's _ae_offer with AE_EXTERNAL=1: the same
#   gates (G1 draft/base/queued/hold labels, G2 per-head ledger, G3 review-prs'
#   APPROVE bound to this head or a standing MERGE, G4 checks, G5 clean, G7
#   fences and main-red freeze and block gate, G6 kill switches), with the
#   iron-law scan (IL) in place of the conductor's READY mark, the same
#   per-tick MC_AUTOENQUEUE_CAP (AE_POSTED carries over from ae_project) and the
#   same write -> send -> confirm `@mergifyio queue`. No tier is read here.
#   A list read answering 75 is rate limited or unreachable: the tick is
#   skipped, never read as "no PRs" (#768).
#
# It never merges and never labels. Its only write is _ae_send's comment.
#
# xe_status_check <num> <pr-url> <head> (BH-9994) — for a row that passed
#   every gate: does the head carry the verdict status the repo's
#   .mergify.yml waits on? The review lane publishes it (bin/review-prs.sh,
#   rvs_publish); when it is missing, ONE alert per head
#   (mc_status_unpublished_alert with <head>), in this tick, not once a day.
#   - .mergify.yml names neither harness-verdict nor lead-verdict
#     (vs_mergify_names rc 1 on both): no read, no alert.
#   - the head was alerted already (`status-unpublished <slug> <head>`): no read.
#   - the combined-status read fails: one conductor log line, no alert, no mark.
#   - vs_clear_row says success: nothing. Else the alert.
#   No write of its own except that alert's ledger mark.
# gh-rest: no-graphql

xe_project() {
  command -v _ae_init >/dev/null 2>&1 || return 0
  : "${AE_POSTED:=0}" "${AE_DEFERRED:=0}"
  _ae_init "${1:-}" "${2:-}" "${3:-}" "${4:-}" || return 0
  # No author test = no way to tell an external PR from ours: post nothing.
  command -v harness_pr_author_match >/dev/null 2>&1 \
    || { _ae_log "$AE_SLUG external: no author test on this box (harness_pr_author_match) — no external PR offered"; return 0; }
  [ "$AE_CAP" -gt 0 ] || return 0
  local t rc line login num rows=() d0="$AE_DEFERRED" checked=0
  t=$(mktemp "${TMPDIR:-/tmp}/xe.XXXXXX") || return 0
  # BH-9938 C1: through prr_read and the conductor seam when it is loaded
  # (the record's window of 100 in step record); today's read otherwise.
  rc=0
  if declare -F prr_read >/dev/null 2>&1 && declare -F mc_xe_record >/dev/null 2>&1; then
    prr_read merge-conductor "$AE_SLUG#open:100" "$t" mc_xe_record mc_xe_github mc_open_norm "$AE_SLUG" || rc=$?
  else
    gh_rest GET "repos/$AE_SLUG/pulls?state=open&per_page=100" > "$t" || rc=$?
  fi
  if [ "$rc" = 75 ]; then
    rm -f "$t"; _ae_log "$AE_SLUG external list rate limited or unreachable (75, HTTP ${GH_REST_STATUS:-000}) — skipped this tick, not read as no PRs"; return 0
  fi
  if [ "$rc" != 0 ] || ! jq -e 'type == "array"' "$t" >/dev/null 2>&1; then
    rm -f "$t"; _ae_log "$AE_SLUG external list unread (rc $rc, HTTP ${GH_REST_STATUS:-000}) — skipped this tick, not read as no PRs"; return 0
  fi
  [ "$(jq 'length' "$t")" -ge 100 ] \
    && _ae_log "$AE_SLUG external list: first page only (100 open PRs) — any PR past it is offered when the list shrinks"
  # The conductor's 13-column row (bin/merge-conductor.sh ROWS), then the author.
  mapfile -t rows < <(jq -r '.[] | [ (.number|tostring), .html_url, .head.sha, (.head.ref // "-"),
      ((.draft // false)|tostring), "UNKNOWN", "UNKNOWN", "OPEN", "false",
      (((.labels // []) | map(.name) | join(",")) | if . == "" then "-" else . end),
      ((.base.ref // "") | if . == "" then "-" else . end),
      ((.updated_at // "") | if . == "" then "-" else . end),
      (if .head.repo == null then "-" else ((.head.repo.full_name // "") != (.base.repo.full_name // "") | tostring) end),
      (.user.login // "-") ] | @tsv' "$t" 2>/dev/null)
  rm -f "$t"
  [ "${#rows[@]}" -gt 0 ] || return 0
  for line in "${rows[@]}"; do
    login="${line##*$'\t'}"; line="${line%$'\t'*}"; num="${line%%$'\t'*}"
    harness_pr_author_match "$login" && continue
    command -v mc_only_has >/dev/null 2>&1 && ! mc_only_has "$AE_SLUG#$num" && continue
    # The repo's required checks, read once and only when a row is offered.
    [ "$checked" = 1 ] || { AE_CHECKS=$(_ae_required_checks "$AE_SLUG") || AE_CHECKS=""; checked=1; }
    # BH-9994: _ae_gates sets AE_NUM only when every gate passed. Such a head
    # is approved, green and clean, so a missing verdict status is the one
    # thing a Mergify queue still waits on: alert in this tick.
    AE_NUM=""
    AE_EXTERNAL=1 _ae_offer "$line"
    [ "$AE_NUM" = "$num" ] && xe_status_check "$num" "$(cut -f2 <<<"$line")" "$(cut -f3 <<<"$line")"
  done
  [ "$AE_DEFERRED" -gt "$d0" ] \
    && _ae_log "$AE_SLUG DEFERRED $((AE_DEFERRED - d0)) external PR(s) over MC_AUTOENQUEUE_CAP=$AE_CAP — re-offered next tick"
  return 0
}

xe_status_check() {
  local num="${1:-}" url="${2:-}" head="${3:-}" ctx t rc=0 row st
  [[ "$head" =~ ^[0-9a-f]{40}$ ]] && [ -n "${AE_SLUG:-}" ] || return 0
  command -v vs_mergify_names >/dev/null 2>&1 && command -v vs_clear_row >/dev/null 2>&1 \
    && command -v mc_status_unpublished_alert >/dev/null 2>&1 || return 0
  ctx=$(vs_builder_context)
  if ! vs_mergify_names "$AE_SLUG" "$ctx"; then
    ctx=lead-verdict
    vs_mergify_names "$AE_SLUG" "$ctx" || return 0
  fi
  command -v mc_attempt_has >/dev/null 2>&1 && mc_attempt_has "status-unpublished $AE_SLUG $head" 2>/dev/null && return 0
  t=$(mktemp "${TMPDIR:-/tmp}/xe-status.XXXXXX") || return 0
  gh_rest GET "repos/$AE_SLUG/commits/$head/status" > "$t" || rc=$?
  if [ "$rc" != 0 ]; then
    rm -f "$t"
    _ae_log "$AE_SLUG#$num @${head:0:8} verdict status unread (rc $rc, HTTP ${GH_REST_STATUS:-000}) — no alert this tick"
    return 0
  fi
  row=$(vs_clear_row "$t") || row=""
  rm -f "$t"
  [ -n "$row" ] || { _ae_log "$AE_SLUG#$num @${head:0:8} verdict status unparseable — no alert this tick"; return 0; }
  st="${row%%$'\t'*}"
  [ "$st" = success ] && return 0
  [ "$st" = - ] && st=none
  mc_status_unpublished_alert "$AE_SLUG" "$url" \
    "approved head ${head:0:12} carries no lead-verdict or harness-verdict status ($st); the review lane publishes it (bin/review-prs.sh, BH-9994)" \
    "$ctx" "$head"
  return 0
}
