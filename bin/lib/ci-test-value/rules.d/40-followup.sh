#!/bin/bash
# bin/lib/ci-test-value/rules.d/40-followup.sh — rule group follow-ups T1/R1/T2/R2. Owner: BH-6618.2.
# A pull_request row that is not a batch row (T1, R1): the next green run of
# the same workflow for the same PR, on another head (the smallest run id above
# the row's). The follow-up set is ctv_followup_files(red head, red base, green
# head, green base). An empty, unread, 404 or capped set decides nothing.
#   T1.followup-tests-only    every path of the set is a test path.
#   R1.followup-reaches-suite the set's non-test paths reach the unit
#                             (ctv_reaches rc 0).
# A push row on main (T2, R2): the next green push run of the same workflow on
# main (the F2 pick), and the compare from the red sha to its sha, which must
# be `ahead` and under GitHub's caps. Each `Merge pull request #N` commit of it
# (at most 20, in commit order) is a candidate: pulls/N must be merged and its
# title or body must name the unit's file name or the red run id as a whole
# number. The first candidate that decides wins:
#   T2.main-fix-tests-only    every file of pulls/N/files is a test path.
#   R2.main-fix-pr            its non-test paths reach the unit.
# The main compare is read under F2's cache key and memo (50-main-flake.sh), so
# F2 does not read it again.

# shellcheck source=bin/lib/ci-test-value/followup.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/followup.sh" || return 1

_ctv_followup_pr() {
  local W="$CTV_WORKFLOW_ID" run="$CTV_RUN_ID" unit="$CTV_UNIT" hs="${CTV_HEAD_SHA:-}" bs="${CTV_BASE_SHA:-}"
  local n d f nx gid gsha gbase
  local -a paths
  n=${CTV_PR_NUMBERS:-}; n=${n%%,*}
  [[ "$n" =~ ^[0-9]+$ ]] && _ctv_fu_sha "$hs" && _ctv_fu_sha "$bs" || return 1
  d=$(_ctv_rr_dir) || return 1
  f="$d/fu1.$BASHPID"
  _ctv_fu_branch_runs "$W" "${CTV_HEAD_BRANCH:-}" "$f.runs" || return 1
  nx=$(_ctv_fu_next_green "$f.runs" "$W" "$run" "$hs" "$n") || { rm -f "$f".*; return 1; }
  read -r gid gsha gbase <<<"$nx"
  ctv_followup_files "$hs" "$bs" "$gsha" "$gbase" > "$f.set" && [ -s "$f.set" ] || { rm -f "$f".*; return 1; }
  _ctv_fu_code_paths "$f.set" > "$f.code"
  if [ ! -s "$f.code" ]; then
    printf 'test-defect\tT1.followup-tests-only\tnext green head %s (run %s) changed only test paths: %s\n' \
      "${gsha:0:12}" "$gid" "$(_ctv_fu_first3 "$f.set")"
    rm -f "$f".*; return 0
  fi
  mapfile -t paths < "$f.code"
  if ctv_reaches "$unit" "${paths[@]}"; then
    printf 'real-pr\tR1.followup-reaches-suite\tnext green head %s (run %s) changed %s which reaches %s\n' \
      "${gsha:0:12}" "$gid" "$(_ctv_fu_first3 "$f.code")" "$unit"
    rm -f "$f".*; return 0
  fi
  rm -f "$f".*
  return 1
}

_ctv_followup_main() {
  local R="$CTV_REPO" W="$CTV_WORKFLOW_ID" run="$CTV_RUN_ID" unit="$CTV_UNIT" sha="${CTV_HEAD_SHA:-}" day="${CTV_DAY:-}"
  local ub=${CTV_UNIT##*/} day2 d f pick gid gsha n text name
  local -a paths
  _ctv_fu_sha "$sha" && [[ "$day" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
  day2=$(date -u -d "$day +1 day" +%F 2>/dev/null) || return 1
  d=$(_ctv_rr_dir) || return 1
  f="$d/fu2.$BASHPID"
  # The next green push run of this workflow on main, at another sha (F2's read).
  _ctv_rr_get "repos/$R/actions/workflows/$W/runs?branch=main&event=push&status=success&created=$day..$day2&per_page=100" \
    - "f2-green-$W-$day" > "$f.json" || { rm -f "$f".*; return 1; }
  pick=$(jq -r --argjson w "$W" --argjson run "$run" --arg sha "$sha" '
    [.workflow_runs[]? | select(.id > $run and .workflow_id == $w and .head_branch == "main" and .event == "push"
      and .status == "completed" and .conclusion == "success" and .head_sha != $sha)] | sort_by(.id) | first // empty
    | "\(.id) \(.head_sha)"' "$f.json" 2>/dev/null)
  read -r gid gsha <<<"$pick"
  [[ "$gid" =~ ^[0-9]+$ ]] && _ctv_fu_sha "$gsha" || { rm -f "$f".*; return 1; }
  _ctv_rr_get "repos/$R/compare/$sha...$gsha" "f2/compare-$sha-$gsha.json" "f2-compare-$sha-$gsha" > "$f.json" \
    || { rm -f "$f".*; return 1; }
  jq -e '.status == "ahead" and .behind_by == 0 and (.commits | type) == "array"
    and (.total_commits | type) == "number" and .total_commits <= 250' "$f.json" > /dev/null 2>&1 || { rm -f "$f".*; return 1; }
  jq -r '.commits[] | (.commit.message // "") | capture("^Merge pull request #(?<n>[0-9]+)").n' "$f.json" 2>/dev/null \
    | awk '!seen[$0]++' | awk 'NR <= 20' > "$f.prs"
  while IFS= read -r n; do
    _ctv_fu_pull "$n" "$f.pull" || continue
    text=$(jq -r 'select(.merged_at != null) | "\(.title // "")\n\(.body // "")"' "$f.pull" 2>/dev/null)
    [ -n "$text" ] || continue
    name=
    if [ -n "$ub" ] && [[ "$text" == *"$ub"* ]]; then name=$ub
    elif [[ "$text" =~ (^|[^0-9])$run([^0-9]|$) ]]; then name="run $run"
    fi
    [ -n "$name" ] || continue
    _ctv_fu_pr_files "$n" | cut -f2 | LC_ALL=C sort -u > "$f.files"
    [ "${PIPESTATUS[0]}" = 0 ] && [ -s "$f.files" ] || continue
    _ctv_fu_code_paths "$f.files" > "$f.code"
    if [ ! -s "$f.code" ]; then
      printf 'test-defect\tT2.main-fix-tests-only\t#%s merged between %s and %s, names %s, changed only test paths\n' \
        "$n" "${sha:0:12}" "${gsha:0:12}" "$name"
      rm -f "$f".*; return 0
    fi
    mapfile -t paths < "$f.code"
    if ctv_reaches "$unit" "${paths[@]}"; then
      printf 'real-main\tR2.main-fix-pr\t#%s merged between %s and %s, names %s, changed %s which reaches %s\n' \
        "$n" "${sha:0:12}" "${gsha:0:12}" "$name" "$(_ctv_fu_first3 "$f.code")" "$unit"
      rm -f "$f".*; return 0
    fi
  done < "$f.prs"
  rm -f "$f".*
  return 1
}

ctv_rule_followup() {
  _ctv_fu_ready || return 1
  if [ "${CTV_EVENT:-}" = pull_request ]; then
    _ctv_fu_is_batch && return 1
    _ctv_followup_pr
  elif [ "${CTV_EVENT:-}" = push ] && [ "${CTV_HEAD_BRANCH:-}" = main ]; then
    _ctv_followup_main
  else
    return 1
  fi
}
