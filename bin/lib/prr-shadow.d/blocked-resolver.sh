#!/bin/bash
# bin/lib/prr-shadow.d/blocked-resolver.sh — the prr-shadow seam of lane blocked-resolver (BH-9926).
# Sourced by prr_seam_load blocked-resolver (bin/lib/prr-shadow.sh), never executed.
#
# BH-10157 (BH-9937 C1, wave 5). The knob GH_SOURCE (settings row
# lane.blocked-resolver.gh_source, default shadow) is registered in
# catalog/lanes.d/blocked-resolver.knobs.d/. The lane's GitHub side
# (brd_open_github, brd_state_array, brd_state_rest) lives in
# bin/blocked-resolver.d/bh-10157-record-discovery.sh beside the hooks that
# call prr_read, so the lane still runs when this file cannot be read. This
# file makes no GitHub call. Two discovery reads move:
#
#   brs_open_record <file> <owner/repo>
#       The repo's open PRs from the PR record: pr_record_list <repo> open
#       <tmp> head_sha,head_ref,base_ref,url,updated_at,author (no window:
#       the open list must be whole). Only the rows whose author is one of
#       ours (harness_pr_authors_json, bin/lib/gh-pr-list.sh) are kept, the
#       filter harness_pr_list applies. Mapped to the harness_pr_list shape
#       br_open_prs answers with: [{number, url, headRefOid, headRefName,
#       baseRefName, isDraft, updatedAt}]. updated_at and author are need
#       fields, so a null is a miss and the lane reads GitHub. A miss prints
#       the pr_record_list miss word and returns 1 with an empty <file>; no
#       lib, or no author set, is `unreadable`.
#   brs_open_norm <file>
#       The compare form: [{n, h: head lowercase, d: isDraft}] sorted by n.
#       url and updatedAt move on events that change no fact, so neither counts.
#
#   brs_state_record <file> <owner/repo> <number>
#       The state of one PR from the record: pr_record_peek, one jobs GET.
#       Writes {"number": n, "state": "merged"|"closed"|"open", "at":
#       <merged_at for merged, else updated_at, else "">}. A peek miss prints
#       unknown and returns 1, as does a row with no state word.
#   brs_state_norm <file>
#       [{n: "state", s: merged|closed|other}]. open, none (the closed pages
#       have no row) and any other word are `other`: "the record says open"
#       and "no closed page lists it" are the same answer, not a mismatch.
if ! command -v pr_record_list >/dev/null 2>&1 && [ -r "${BASH_SOURCE[0]%/*}/../pr-record.sh" ]; then
  # shellcheck source=bin/lib/pr-record.sh
  . "${BASH_SOURCE[0]%/*}/../pr-record.sh"
fi

brs_open_record() {
  local f="${1:-}" repo="${2:-}" tmp why rc au
  [ -n "$f" ] || return 2
  : > "$f" 2>/dev/null
  command -v pr_record_list >/dev/null 2>&1 || { echo unreadable; return 1; }
  command -v harness_pr_authors_json >/dev/null 2>&1 || { echo unreadable; return 1; }
  au=$(harness_pr_authors_json 2>/dev/null)
  jq -e 'type == "array" and length > 0 and all(.[]; type == "string" and length > 0)' <<<"$au" >/dev/null 2>&1 \
    || { echo unreadable; return 1; }
  tmp=$(mktemp "${TMPDIR:-/tmp}/brs-open.XXXXXX") || { echo unreadable; return 1; }
  why=$(pr_record_list "$repo" open "$tmp" head_sha,head_ref,base_ref,url,updated_at,author); rc=$?
  if [ "$rc" != 0 ]; then
    rm -f "$tmp" "$tmp.sync"
    echo "${why:-unreadable}"; return 1
  fi
  if ! jq -c --argjson au "$au" '[.[] | select((.author // "") as $a | $au | index($a))
        | {number, url: (.url // ""), headRefOid: (.head_sha // ""), headRefName: (.head_ref // ""),
           baseRefName: (.base_ref // "main"), isDraft: (.draft == true or .draft == 1), updatedAt: (.updated_at // "")}]' \
        "$tmp" > "$f" 2>/dev/null; then
    rm -f "$tmp" "$tmp.sync"; : > "$f"
    echo malformed; return 1
  fi
  rm -f "$tmp" "$tmp.sync"
  return 0
}

brs_open_norm() {
  jq -c '[.[] | {n: .number, h: ((.headRefOid // "") | ascii_downcase), d: (.isDraft == true)}] | sort_by(.n)' "${1:-}" 2>/dev/null
}

brs_state_record() {
  local f="${1:-}" repo="${2:-}" n="${3:-}" row
  [ -n "$f" ] || return 2
  : > "$f" 2>/dev/null
  [[ "$n" =~ ^[1-9][0-9]{0,9}$ ]] || { echo unknown; return 1; }
  command -v pr_record_peek >/dev/null 2>&1 || { echo unreadable; return 1; }
  row=$(pr_record_peek "$repo" "$n") || { echo unknown; return 1; }
  jq -ce --argjson n "$n" 'select((.state | type) == "string" and (.state == "merged" or .state == "closed" or .state == "open"))
      | {number: $n, state: .state, at: ((if .state == "merged" then .merged_at else null end) // .updated_at // "")}' \
      <<<"$row" > "$f" 2>/dev/null \
    || { : > "$f"; echo unknown; return 1; }
  return 0
}

brs_state_norm() {
  jq -c 'select(type == "object" and (.state | type) == "string")
    | [{n: "state", s: (if .state == "merged" or .state == "closed" then .state else "other" end)}]' "${1:-}" 2>/dev/null
}
