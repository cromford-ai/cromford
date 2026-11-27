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
#
#   tsp_ref_states <file> <owner/repo> <ref>...
#       BH-10217: the closed and merged PR record rows of those head refs. ONE
#       jobs GET /api/pr-record-refs?repo=<lower>&refs=<JSON array>, never a
#       GitHub call, never a write. rc 0: <file> holds the rows array
#       [{number, state, head_ref, merged_at}] (an empty array is a real "no
#       closed or merged row"). Else rc 1, <file> is empty, stdout is one miss
#       word, and logs/pr-record.log gets `refs <repo> miss=<word>`:
#         unreadable   no jobs client, or the GET failed (a 404 from a worker
#                      without the route, a 400 too_many, a 503, no answer)
#         malformed    the body has no rows array or no truncated boolean
#         truncated    the worker cut the rows at pr_records.list_limit
#       rc 2 on bad args. The lane bin/tickets-snapshot-push.sh treats any miss
#       as unknown: it reads GitHub as before and writes no cache row.
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

tsp_ref_states() {
  local f="${1:-}" repo="${2:-}" lr enc out why=""
  [ -n "$f" ] && [ "$#" -ge 3 ] || return 2
  [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 2
  shift 2
  : > "$f" || return 2
  lr=$(printf '%s' "$repo" | tr 'A-Z' 'a-z')
  enc=$(jq -rn '$ARGS.positional | tojson | @uri' --args "$@" 2>/dev/null)
  if [ -z "$enc" ] || ! command -v _prr_client >/dev/null 2>&1 || ! _prr_client \
     || ! out=$(_jobs_req GET "/api/pr-record-refs?repo=$lr&refs=$enc"); then
    why=unreadable
  elif ! jq -e '(.rows | type) == "array" and (.truncated | type) == "boolean"' <<<"$out" >/dev/null 2>&1; then
    why=malformed
  elif jq -e '.truncated' <<<"$out" >/dev/null 2>&1; then
    why=truncated
  elif ! jq -c '.rows' <<<"$out" > "$f" 2>/dev/null || [ ! -s "$f" ]; then
    why=malformed
  fi
  [ -z "$why" ] && return 0
  : > "$f"
  command -v _prr_log >/dev/null 2>&1 && _prr_log "refs $lr miss=$why"
  printf '%s\n' "$why"
  return 1
}
