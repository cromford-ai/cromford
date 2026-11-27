#!/bin/bash
# bin/lib/prr-shadow.d/scheduler.sh — the prr-shadow seam of lane scheduler (BH-10218 W4).
# Sourced by bin/scheduler.sh (prr_seam_load scheduler), never executed.
#
# The knob GH_SOURCE (settings row lane.scheduler.gh_source, default shadow)
# is registered in catalog/lanes.d/scheduler.knobs.d/. One read moves: the
# stack parent lookup sw_parent_pr <slug> <branch> (bin/lib/stack-wait.sh,
# not edited), one REST `pulls?state=all&head=<owner>:<branch>` per parent.
#
#   sched_parent_record <file> <owner/repo> <branch>
#       From the PR record's trusted open list (pr_record_list <repo> open
#       <tmp> head_ref, the whole list: truncated is a miss). An open PR whose
#       head_ref is <branch> answers `open <n> <url>` (the highest number,
#       sw_parent_pr's "open wins" rule). A branch that is not in the open list
#       is the miss field:head: merged, closed or absent is only known to
#       GitHub's state=all read, and the record's merged and closed lists are
#       windows, so "not found" there would be wrong data. A list miss prints
#       pr_record_list's word. rc 1 on any miss; no lib is `unreadable`.
#   sched_parent_github <file> <owner/repo> <branch>
#       Today's read: sw_parent_pr's line into <file>. rc 75 when that line is
#       `unreadable ...` or `unchecked` (so no compare is made), else 0. The
#       line is in <file> either way, so the lane reads it as before.
#   sched_parent_norm <file>
#       [{n, s: state}] for an open|merged|closed line, else [].
if ! command -v pr_record_list >/dev/null 2>&1 && [ -r "${BASH_SOURCE[0]%/*}/../pr-record.sh" ]; then
  # shellcheck source=bin/lib/pr-record.sh
  . "${BASH_SOURCE[0]%/*}/../pr-record.sh"
fi

sched_parent_record() {
  local f="${1:-}" repo="${2:-}" br="${3:-}" tmp why rc=0 line
  [ -n "$f" ] && [ -n "$br" ] || return 2
  command -v pr_record_list >/dev/null 2>&1 || { echo unreadable; return 1; }
  tmp=$(mktemp "${TMPDIR:-/tmp}/sched-parent.XXXXXX") || { echo unreadable; return 1; }
  why=$(pr_record_list "$repo" open "$tmp" head_ref) || rc=$?
  if [ "$rc" != 0 ]; then rm -f "$tmp" "$tmp.sync"; echo "${why:-unreadable}"; return 1; fi
  line=$(jq -r --arg b "$br" '[.[] | select(.head_ref == $b)] | sort_by(.number) | last
          | if . == null then "" else "open \(.number) \(.url // "")" end' "$tmp" 2>/dev/null) || line=""
  rm -f "$tmp" "$tmp.sync"
  [ -n "$line" ] || { : > "$f"; echo field:head; return 1; }
  printf '%s\n' "$line" > "$f"
}

sched_parent_github() {
  local out
  out=$(sw_parent_pr "${2:-}" "${3:-}")
  printf '%s\n' "$out" > "${1:-/dev/null}"
  case "$out" in unreadable*|unchecked|'') return 75 ;; esac
  return 0
}

sched_parent_norm() {
  local s n
  read -r s n _ < "${1:-/dev/null}" 2>/dev/null || { echo '[]'; return 0; }
  case "$s:$n" in
    open:[0-9]*|merged:[0-9]*|closed:[0-9]*) jq -nc --arg s "$s" --argjson n "$n" '[{n: $n, s: $s}]' ;;
    *) echo '[]' ;;
  esac
}
