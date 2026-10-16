#!/bin/bash
# bin/lib/ci-test-value/rules.d/60-batch-fix.sh — rule group batch fix B1. Owner: BH-6618.2.
#   B1.batch-member-fix  a batch row whose title names a member M (sorted, at
#     most 10 read) that later merged, and M got a new head after the batch:
#     h0 = M's last run of the same workflow before the batch run, h1 = M's
#     next green run of that workflow after it, on another head. The follow-up
#     set ctv_followup_files(h0, h0's base, h1, h1's base) must reach the unit:
#     a non-test path that reaches it -> real-pr; only test paths, and they
#     reach it -> test-defect.
#   A member that never merged, no new head, a 404 or capped compare, an empty
#   set, or a set that does not reach the unit: no decision.

# shellcheck source=bin/lib/ci-test-value/followup.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/followup.sh" || return 1

ctv_rule_batch_fix() {
  local W="${CTV_WORKFLOW_ID:-}" run="${CTV_RUN_ID:-}" unit="${CTV_UNIT:-}"
  local d f members m k=0 ref pre h0 b0 nx h1 b1 _id
  local -a paths
  _ctv_fu_is_batch && _ctv_fu_ready || return 1
  members=$(_ctv_fu_members) || return 1
  d=$(_ctv_rr_dir) || return 1
  f="$d/b1.$BASHPID"
  while IFS= read -r m; do
    k=$((k + 1)); [ "$k" -le 10 ] || break
    _ctv_fu_pull "$m" "$f.pull" || continue
    ref=$(jq -r 'select(.merged_at != null) | .head.ref // empty' "$f.pull" 2>/dev/null)
    [ -n "$ref" ] || continue
    _ctv_fu_branch_runs "$W" "$ref" "$f.runs" || continue
    # M's head at batch time: its last run of this workflow before the batch.
    pre=$(jq -r --argjson w "$W" --argjson run "$run" --argjson pr "$m" '
      [.workflow_runs[]? | select(.id < $run and .workflow_id == $w and .status == "completed"
        and any(.pull_requests[]?; .number == $pr))] | sort_by(.id) | last // empty
      | "\(.head_sha) \([.pull_requests[] | select(.number == $pr) | .base.sha][0] // "")"' "$f.runs" 2>/dev/null)
    read -r h0 b0 <<<"$pre"
    _ctv_fu_sha "$h0" && _ctv_fu_sha "$b0" || continue
    nx=$(_ctv_fu_next_green "$f.runs" "$W" "$run" "$h0" "$m") || continue
    read -r _id h1 b1 <<<"$nx"
    ctv_followup_files "$h0" "$b0" "$h1" "$b1" > "$f.set" || continue
    [ -s "$f.set" ] || continue
    _ctv_fu_code_paths "$f.set" > "$f.code"
    if [ -s "$f.code" ]; then
      mapfile -t paths < "$f.code"
      ctv_reaches "$unit" "${paths[@]}" || continue
      printf 'real-pr\tB1.batch-member-fix\t#%s new head %s after the batch changed %s which reaches %s\n' \
        "$m" "${h1:0:12}" "$(_ctv_fu_first3 "$f.code")" "$unit"
    else
      mapfile -t paths < "$f.set"
      ctv_reaches "$unit" "${paths[@]}" || continue
      printf 'test-defect\tB1.batch-member-fix\t#%s new head %s after the batch changed only test paths that reach %s\n' \
        "$m" "${h1:0:12}" "$unit"
    fi
    rm -f "$f".*
    return 0
  done <<<"$members"
  rm -f "$f".*
  return 1
}
