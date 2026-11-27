#!/bin/bash
# bin/lib/prr-shadow.d/utilization-push.sh — the prr-shadow seam of lane utilization-push (BH-10218 W4).
# Sourced by bin/lib/utilization/section-tickets.sh (prr_seam_load utilization-push), never executed.
#
# The knob GH_SOURCE (settings row lane.utilization-push.gh_source, default
# shadow) is registered in catalog/lanes.d/utilization-push.knobs.d/. One read
# moves: the tickets section's open PR list, of which it uses only head.ref.
# The GitHub side, util_heads_github, lives in section-tickets.sh beside the
# read it replaces (_ut_pages).
#
#   util_heads_record <file> <owner/repo>
#       pr_record_list <repo> open <tmp> head_ref (the whole list: truncated is
#       a miss), mapped to [head_ref lowercase]. GitHub's read stops at
#       UTIL_TICKETS_PAGES pages of 100 and fails on a last page that is still
#       full, so a record list of that many rows or more is the miss
#       `truncated` too (the fallback then fails as today). A miss prints the
#       word and returns 1; no lib is `unreadable`.
#   util_heads_norm <file>
#       [{n: head}] unique by n (the heads are only ever tested for membership).
if ! command -v pr_record_list >/dev/null 2>&1 && [ -r "${BASH_SOURCE[0]%/*}/../pr-record.sh" ]; then
  # shellcheck source=bin/lib/pr-record.sh
  . "${BASH_SOURCE[0]%/*}/../pr-record.sh"
fi

util_heads_record() {
  local f="${1:-}" repo="${2:-}" tmp why rc=0 n cap
  [ -n "$f" ] || return 2
  command -v pr_record_list >/dev/null 2>&1 || { echo unreadable; return 1; }
  tmp=$(mktemp "${TMPDIR:-/tmp}/util-heads.XXXXXX") || { echo unreadable; return 1; }
  why=$(pr_record_list "$repo" open "$tmp" head_ref) || rc=$?
  if [ "$rc" != 0 ]; then rm -f "$tmp" "$tmp.sync"; echo "${why:-unreadable}"; return 1; fi
  cap=$(( ${UTIL_TICKETS_PAGES:-3} * 100 ))
  n=$(jq 'length' "$tmp" 2>/dev/null) || n=""
  case "$n" in ''|*[!0-9]*) rm -f "$tmp" "$tmp.sync"; echo malformed; return 1 ;; esac
  if [ "$n" -ge "$cap" ]; then rm -f "$tmp" "$tmp.sync"; echo truncated; return 1; fi
  if ! jq -c '[.[] | (.head_ref // "") | tostring | ascii_downcase]' "$tmp" > "$f" 2>/dev/null; then
    rm -f "$tmp" "$tmp.sync"; : > "$f"; echo malformed; return 1
  fi
  rm -f "$tmp" "$tmp.sync"
  return 0
}

util_heads_norm() {
  jq -c '[.[] | {n: .}] | unique_by(.n)' "${1:-}" 2>/dev/null
}
