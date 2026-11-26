#!/bin/bash
# bin/lib/prr-shadow.d/pr-state-reconcile.sh — the prr-shadow seam of lane pr-state-reconcile (BH-9926).
# Sourced by bin/pr-state-reconcile.sh (and prr_seam_load pr-state-reconcile), never executed.
#
# BH-9937 (wave 5). The knob GH_SOURCE (settings row
# lane.pr-state-reconcile.gh_source, default shadow) is registered in
# catalog/lanes.d/pr-state-reconcile.knobs.d/. The lane's GitHub side,
# psr_list_github and psr_state_github, lives in bin/pr-state-reconcile.sh
# beside the reads it replaces, so the lane still runs when this file cannot
# be read. Two reads move:
#
#   psr_list_record <file> <owner/repo>
#       The repo's open PRs from the PR record: pr_record_list <repo> open
#       <tmp> head_sha,base_ref,url, mapped to the lane's harness_pr_list shape
#       [{number, url, isDraft, baseRefName, headRefOid, updatedAt}]. A miss
#       prints the pr_record_list miss word and returns 1; no lib is
#       `unreadable`.
#   psr_list_norm <file>
#       The compare form: [{n, h: head lowercase, d: isDraft}] sorted by n.
#       url and updatedAt move on events that change no fact, so neither counts.
#
#   psr_state_record <file> <owner/repo> <number>
#       The state of one PR from the record: pr_record_peek, one jobs GET, no
#       GitHub call. Writes {"number": n, "state": "open"|"closed"}; the
#       record's `merged` is GitHub's REST state `closed`. A peek miss prints
#       unknown and returns 1, as does a row with no state word.
#   psr_state_norm <file>
#       [{n: "state", s: <state>}]. The PR number is in the prr_read key
#       (<repo>#<n>@state), and GitHub's body is not required to carry it.
if ! command -v pr_record_list >/dev/null 2>&1 && [ -r "${BASH_SOURCE[0]%/*}/../pr-record.sh" ]; then
  # shellcheck source=bin/lib/pr-record.sh
  . "${BASH_SOURCE[0]%/*}/../pr-record.sh"
fi

psr_list_record() {
  local f="${1:-}" repo="${2:-}" tmp why rc
  [ -n "$f" ] || return 2
  command -v pr_record_list >/dev/null 2>&1 || { echo unreadable; return 1; }
  tmp=$(mktemp "${TMPDIR:-/tmp}/psr-open.XXXXXX") || { echo unreadable; return 1; }
  why=$(pr_record_list "$repo" open "$tmp" head_sha,base_ref,url); rc=$?
  if [ "$rc" != 0 ]; then
    rm -f "$tmp" "$tmp.sync"
    echo "${why:-unreadable}"; return 1
  fi
  if ! jq -c '[.[] | {number, url: (.url // ""), isDraft: (.draft == true or .draft == 1),
        baseRefName: (.base_ref // "main"), headRefOid: (.head_sha // ""), updatedAt: (.updated_at // "")}]' "$tmp" > "$f" 2>/dev/null; then
    rm -f "$tmp" "$tmp.sync"; : > "$f"
    echo malformed; return 1
  fi
  rm -f "$tmp" "$tmp.sync"
  return 0
}

psr_list_norm() {
  jq -c '[.[] | {n: .number, h: ((.headRefOid // "") | ascii_downcase), d: (.isDraft == true)}] | sort_by(.n)' "${1:-}" 2>/dev/null
}

psr_state_record() {
  local f="${1:-}" repo="${2:-}" n="${3:-}" row
  [ -n "$f" ] || return 2
  command -v pr_record_peek >/dev/null 2>&1 || { echo unreadable; return 1; }
  row=$(pr_record_peek "$repo" "$n") || { echo unknown; return 1; }
  jq -ce --argjson n "$n" '.state | if . == "merged" then "closed" else . end
      | select(. == "open" or . == "closed") | {number: $n, state: .}' <<<"$row" > "$f" 2>/dev/null \
    || { : > "$f"; echo unknown; return 1; }
  return 0
}

psr_state_norm() {
  jq -c 'select(type == "object" and (.state | type) == "string") | [{n: "state", s: .state}]' "${1:-}" 2>/dev/null
}
