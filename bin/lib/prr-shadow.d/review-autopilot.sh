#!/bin/bash
# bin/lib/prr-shadow.d/review-autopilot.sh — the prr-shadow seam of lane review-autopilot (BH-10218 W4).
# Sourced by bin/review-autopilot.sh (prr_seam_load review-autopilot), never executed.
#
# The knob GH_SOURCE (settings row lane.review-autopilot.gh_source, default
# shadow) is registered in catalog/lanes.d/review-autopilot.knobs.d/. One read
# moves: the per-project open list harness_pr_list <repo> open
# number,createdAt,headRefOid,title,isDraft,baseRefName (bin/lib/gh-pr-list.sh,
# the REST rung: the newest GH_PR_LIST_REST_PAGES x 100 open PRs by created,
# then the harness authors, then the first <limit>).
#
#   ra_open_record <file> <owner/repo> <fields> <limit>
#       pr_record_open_rest <repo> <tmp> <pages x 100> (the same window), then
#       the same mapping harness_pr_list makes (_hpl_map_rows with the harness
#       author set, then .[:limit]). A row with a null draft or created_at is
#       the miss field:draft / field:created_at: the autopilot reads isDraft
#       and createdAt, and a null would read as "not a draft" or break the age
#       filter. A miss prints the word and returns 1; no lib (pr-record.sh or
#       gh-pr-list.sh) is `unreadable`.
#   ra_open_github <file> <owner/repo> <fields> <limit>
#       Today's read: harness_pr_list <repo> open <fields> <limit>. Its rc.
#   ra_open_norm <file>
#       [{n, h: headRefOid lowercase, d: isDraft, b: baseRefName}] sorted by n.
if ! command -v pr_record_open_rest >/dev/null 2>&1 && [ -r "${BASH_SOURCE[0]%/*}/../pr-record.sh" ]; then
  # shellcheck source=bin/lib/pr-record.sh
  . "${BASH_SOURCE[0]%/*}/../pr-record.sh"
fi

ra_open_record() {
  local f="${1:-}" repo="${2:-}" fields="${3:-}" limit="${4:-100}" tmp why rc=0 win bare req a fld
  [ -n "$f" ] && [ -n "$fields" ] || return 2
  case "$limit" in ''|*[!0-9]*) return 2 ;; esac
  for fld in pr_record_open_rest _hpl_map_rows harness_pr_authors _hpl_bare; do
    command -v "$fld" >/dev/null 2>&1 || { echo unreadable; return 1; }
  done
  win=$(( ${GH_PR_LIST_REST_PAGES:-3} * ${_HPL_REST_PAGE_MAX:-100} ))
  tmp=$(mktemp "${TMPDIR:-/tmp}/ra-open.XXXXXX") || { echo unreadable; return 1; }
  why=$(pr_record_open_rest "$repo" "$tmp" "$win") || rc=$?
  if [ "$rc" != 0 ]; then rm -f "$tmp"; echo "${why:-unreadable}"; return 1; fi
  for fld in draft created_at; do
    if ! jq -e --arg k "$fld" 'all(.[]; .[$k] != null)' "$tmp" >/dev/null 2>&1; then
      rm -f "$tmp"; : > "$f"; echo "field:$fld"; return 1
    fi
  done
  bare=$(for a in $(harness_pr_authors); do printf '%s\n' "$(_hpl_bare "$a")"; done | jq -R . | jq -sc .)
  req=$(printf '%s' "$fields" | jq -R 'split(",")')
  # The record window is ordered created DESC, number DESC (routes/pr-records.js);
  # GitHub's page is sort=created&direction=desc. The sort makes the order explicit.
  if ! jq -c 'sort_by(.created_at, .number) | reverse' "$tmp" > "$tmp.s" 2>/dev/null \
     || ! _hpl_map_rows open "$bare" "$req" "$tmp.s" | jq ".[:$limit]" > "$f" 2>/dev/null; then
    rm -f "$tmp" "$tmp.s"; : > "$f"; echo malformed; return 1
  fi
  rm -f "$tmp" "$tmp.s"
  return 0
}

ra_open_github() {
  local rc=0
  harness_pr_list "${2:-}" open "${3:-}" "${4:-100}" > "${1:-/dev/null}" 2>/dev/null || rc=$?
  return "$rc"
}

ra_open_norm() {
  jq -c '[.[] | {n: .number, h: ((.headRefOid // "") | ascii_downcase), d: .isDraft, b: .baseRefName}] | sort_by(.n)' "${1:-}" 2>/dev/null
}
