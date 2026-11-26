#!/bin/bash
# bin/lib/prr-shadow.d/main-red-pr-pair.sh — the prr-shadow seam of lane main-red-pr-pair (BH-9926).
# Sourced by bin/main-red-pr-pair.sh (and prr_seam_load main-red-pr-pair), never executed.
#
# BH-9937 (wave 5). The knob GH_SOURCE (settings row
# lane.main-red-pr-pair.gh_source, default shadow) is registered in
# catalog/lanes.d/main-red-pr-pair.knobs.d/. The lane's GitHub side,
# mrp_list_github, lives in bin/main-red-pr-pair.sh beside the read it
# replaces, so the lane still runs when this file cannot be read. One read
# moves; the runs, jobs, logs and check-runs of a head stay on GitHub (the
# record holds no run ids and no log lines):
#
#   mrp_list_record <file> <owner/repo>
#       The repo's open PRs from the PR record: pr_record_list <repo> open
#       <tmp> head_sha 100, the newest 100 by created, the window
#       harness_pr_list <repo> open ... 100 reads. Rows mapped to the lane's
#       shape [{number, headRefOid, updatedAt}]. A miss prints the
#       pr_record_list miss word and returns 1; no lib is `unreadable`.
#   mrp_list_norm <file>
#       The compare form: [{n, h: head lowercase}] sorted by n. updatedAt moves
#       on events that change no head, so it does not count.
if ! command -v pr_record_list >/dev/null 2>&1 && [ -r "${BASH_SOURCE[0]%/*}/../pr-record.sh" ]; then
  # shellcheck source=bin/lib/pr-record.sh
  . "${BASH_SOURCE[0]%/*}/../pr-record.sh"
fi

mrp_list_record() {
  local f="${1:-}" repo="${2:-}" tmp why rc
  [ -n "$f" ] || return 2
  command -v pr_record_list >/dev/null 2>&1 || { echo unreadable; return 1; }
  tmp=$(mktemp "${TMPDIR:-/tmp}/mrp-open.XXXXXX") || { echo unreadable; return 1; }
  why=$(pr_record_list "$repo" open "$tmp" head_sha 100); rc=$?
  if [ "$rc" != 0 ]; then
    rm -f "$tmp" "$tmp.sync"
    echo "${why:-unreadable}"; return 1
  fi
  if ! jq -c '[.[] | {number, headRefOid: (.head_sha // ""), updatedAt: (.updated_at // "")}]' "$tmp" > "$f" 2>/dev/null; then
    rm -f "$tmp" "$tmp.sync"; : > "$f"
    echo malformed; return 1
  fi
  rm -f "$tmp" "$tmp.sync"
  return 0
}

mrp_list_norm() {
  jq -c '[.[] | {n: .number, h: ((.headRefOid // "") | ascii_downcase)}] | sort_by(.n)' "${1:-}" 2>/dev/null
}
