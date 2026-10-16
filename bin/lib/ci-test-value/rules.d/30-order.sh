#!/bin/bash
# bin/lib/ci-test-value/rules.d/30-order.sh — rule group order O1. Owner: BH-6618.2.
#   O1.batch-member-added-suite  a batch row (merge_group, gh-readonly-queue or
#     a mergify/merge-queue/ branch) whose title names 2 or more PRs, and one
#     member A (sorted, at most 10 read) lists the unit in pulls/A/files as
#     added, modified or renamed, and A's own last run of the same workflow
#     before the batch run, on A's current head, completed green. The suite
#     passed alone and failed only beside another member: an order effect.
#   A batch of one, a title with no #N, a red or absent own run: no decision.
# Reads go through _ctv_rr_get (20-flake.sh); helpers are in ../followup.sh.

# shellcheck source=bin/lib/ci-test-value/followup.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/followup.sh" || return 1

ctv_rule_order() {
  local R="${CTV_REPO:-}" W="${CTV_WORKFLOW_ID:-}" run="${CTV_RUN_ID:-}" unit="${CTV_UNIT:-}"
  local d f members m n k=0 st hs pick
  _ctv_fu_is_batch && _ctv_fu_ready || return 1
  members=$(_ctv_fu_members) || return 1
  n=$(grep -c . <<<"$members")
  [ "$n" -ge 2 ] || return 1
  d=$(_ctv_rr_dir) || return 1
  f="$d/o1.$BASHPID"
  while IFS= read -r m; do
    k=$((k + 1)); [ "$k" -le 10 ] || break
    _ctv_fu_pr_files "$m" > "$f.files" || continue
    st=$(awk -F'\t' -v u="$unit" '($1 == "added" || $1 == "modified" || $1 == "renamed") && $2 == u { print $1; exit }' "$f.files")
    [ -n "$st" ] || continue
    _ctv_fu_pull "$m" "$f.pull" || continue
    hs=$(jq -r '.head.sha // empty' "$f.pull" 2>/dev/null)
    _ctv_fu_sha "$hs" || continue
    _ctv_rr_get "repos/$R/actions/runs?head_sha=$hs&event=pull_request&per_page=100" - "fu-head-$hs" > "$f.runs" || continue
    pick=$(jq -r --argjson w "$W" --argjson run "$run" --arg hs "$hs" '
      [.workflow_runs[]? | select(.id < $run and .workflow_id == $w and .head_sha == $hs and .status == "completed")]
      | sort_by(.id) | last // empty | "\(.id) \(.conclusion)"' "$f.runs" 2>/dev/null)
    [ "${pick#* }" = success ] || continue
    rm -f "$f".*
    printf 'order\tO1.batch-member-added-suite\t#%s %s %s; its run %s was green on %s; %s other member(s)\n' \
      "$m" "$st" "$unit" "${pick% *}" "${hs:0:12}" "$((n - 1))"
    return 0
  done <<<"$members"
  rm -f "$f".*
  return 1
}
