#!/bin/bash
# bin/lib/prr-shadow.d/overlap-guard.sh — the prr-shadow seam of bin/overlap-guard.sh (BH-10218 W4).
# Sourced by bin/overlap-guard.sh (og_prr_arm) and prr_seam_load overlap-guard, never executed.
#
# overlap-guard is not a registered lane. Its knob GH_SOURCE is registered as
# lib id overlap-guard (catalog/lanes.d/_lib.overlap-guard.json), settings row
# lib.overlap-guard.gh_source, default shadow. bin/overlap-guard.sh resolves it
# once with lib_env_apply and pins it with prr_pin overlap-guard.
#
#   og_open_record <file> <owner/repo> <window-n>
#       The --refresh open list from the PR record: pr_record_open_rest <repo>
#       <file> <window-n>, the REST pulls shape (number, html_url, draft,
#       user.login, head.{ref,sha}). The window is the newest n by created,
#       the rows gh_rest_pr_list_all <repo> open <n> reads. A miss prints the
#       pr_record_open_rest word (pr_record_list's words, malformed,
#       field:default_branch) and returns 1; no lib is `unreadable`.
#   og_open_github <file> <owner/repo> <window-n>
#       Today's read: gh_rest_pr_list_all <repo> open <n>. Its rc.
#   og_open_norm <file>
#       [{n, h: head sha lowercase, r: head ref, d: draft}] sorted by n.
#
#   og_check_record <file> <owner/repo> <limit>
#       The launch check list asks for `files`: each PR's changed files with
#       additions and deletions, GitHub's pulls/<n>/files rows. The record list
#       holds no files, and the record's per-PR files are paths only, so this
#       answer is always the miss field:files, with no jobs read. Step record
#       therefore reads GitHub on this path; the PRR_MISS line says why.
#   og_check_github <file> <owner/repo> <limit>
#       Today's read: harness_pr_list <repo> open number,url,headRefName,isDraft,files <limit>.
#   og_check_norm <file>
#       [{n, r: headRefName, d: isDraft}] sorted by n.
if ! command -v pr_record_open_rest >/dev/null 2>&1 && [ -r "${BASH_SOURCE[0]%/*}/../pr-record.sh" ]; then
  # shellcheck source=bin/lib/pr-record.sh
  . "${BASH_SOURCE[0]%/*}/../pr-record.sh"
fi

og_open_record() {
  local f="${1:-}" repo="${2:-}" win="${3:-}" why rc=0
  [ -n "$f" ] || return 2
  command -v pr_record_open_rest >/dev/null 2>&1 || { echo unreadable; return 1; }
  why=$(pr_record_open_rest "$repo" "$f" "$win") || rc=$?
  [ "$rc" = 0 ] && return 0
  : > "$f" 2>/dev/null
  echo "${why:-unreadable}"; return 1
}

og_open_github() {
  local rc=0
  gh_rest_pr_list_all "${2:-}" open "${3:-}" > "${1:-/dev/null}" || rc=$?
  return "$rc"
}

og_open_norm() {
  jq -c '[.[] | {n: .number, h: ((.head.sha // "") | ascii_downcase), r: (.head.ref // ""), d: (.draft // false)}] | sort_by(.n)' "${1:-}" 2>/dev/null
}

og_check_record() {
  [ -n "${1:-}" ] || return 2
  echo field:files; return 1
}

og_check_github() {
  local rc=0
  harness_pr_list "${2:-}" open "number,url,headRefName,isDraft,files" "${3:-}" > "${1:-/dev/null}" 2>/dev/null || rc=$?
  return "$rc"
}

og_check_norm() {
  jq -c '[.[] | {n: .number, r: (.headRefName // ""), d: (.isDraft // false)}] | sort_by(.n)' "${1:-}" 2>/dev/null
}
