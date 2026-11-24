#!/bin/bash
# bin/lib/prr-shadow.d/tickets-snapshot-push.sh — the prr-shadow seam of lane
# tickets-snapshot-push (BH-9926 wave 1). Sourced by prr_seam_load, never
# executed. The lane's GitHub side, tsp_open_github, lives in
# bin/tickets-snapshot-push.sh beside the read it replaces.
#
#   tsp_open_record <file> <owner/repo> <limit>
#       The repo's open PRs from the PR record: pr_record_list <repo> open
#       <tmp> - <limit>, the newest <limit> by created, the set GitHub's first
#       `pulls?state=open&per_page=<limit>` page holds. Rows mapped to the
#       lane's shape [{n, br, by, up, url, t}]. A miss prints the
#       pr_record_list miss word and returns 1; no lib is `unreadable`.
#
#   tsp_open_norm <file>
#       The compare form: [{n, br, by, t}] sorted by n. `up` moves on events
#       that change no record field, and `url` follows from the number, so
#       neither is compared.
if ! command -v pr_record_list >/dev/null 2>&1 && [ -r "${BASH_SOURCE[0]%/*}/../pr-record.sh" ]; then
  # shellcheck source=bin/lib/pr-record.sh
  . "${BASH_SOURCE[0]%/*}/../pr-record.sh"
fi

tsp_open_record() {
  local f="${1:-}" repo="${2:-}" lim="${3:-}" tmp why rc
  [ -n "$f" ] || return 2
  command -v pr_record_list >/dev/null 2>&1 || { echo unreadable; return 1; }
  tmp=$(mktemp "${TMPDIR:-/tmp}/tsp-open.XXXXXX") || { echo unreadable; return 1; }
  why=$(pr_record_list "$repo" open "$tmp" - "$lim"); rc=$?
  if [ "$rc" != 0 ]; then
    rm -f "$tmp" "$tmp.sync"
    echo "${why:-unreadable}"; return 1
  fi
  if ! jq -c '[.[] | {n: .number, br: .head_ref, by: .author, up: .updated_at, url: .url, t: .title}]' "$tmp" > "$f" 2>/dev/null; then
    rm -f "$tmp" "$tmp.sync"; : > "$f"
    echo malformed; return 1
  fi
  rm -f "$tmp" "$tmp.sync"
  return 0
}

tsp_open_norm() {
  jq -c '[.[] | {n, br, by, t}] | sort_by(.n)' "${1:-}" 2>/dev/null
}
