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

#   BH-10351: more refs than the worker's ref_read_max (its 400
#   {"error":"too_many","max":M}, M = the settings row pr_records.ref_read_max)
#   are asked again in chunks of M, and the rows are joined. Before this, a
#   repo with more branch-only tickets than M (project-9 140, 2026-11-27)
#   was `unreadable` on every tick, and each of its branches read GitHub.
#   Any chunk that misses makes the whole answer that miss.

# _tsp_refs_get <lower-repo> <out-file> <ref>... — ONE GET. rc 0: the rows
# array in <out-file>. Else one word on stdout and rc 1: unreadable,
# malformed, truncated, or too_many:<M> (a 400 too_many with its max M).
_tsp_refs_get() {
  local lr="$1" f="$2" enc out bf m
  shift 2
  enc=$(jq -rn '$ARGS.positional | tojson | @uri' --args "$@" 2>/dev/null)
  [ -n "$enc" ] || { echo unreadable; return 1; }
  bf=$(mktemp "${TMPDIR:-/tmp}/tsp-refs-body.XXXXXX") || { echo unreadable; return 1; }
  if ! out=$(JOBS_BODY_FILE="$bf" _jobs_req GET "/api/pr-record-refs?repo=$lr&refs=$enc"); then
    m=$(jq -r 'select(.error == "too_many") | .max | numbers' "$bf" 2>/dev/null)
    rm -f "$bf"
    if [[ "$m" =~ ^[1-9][0-9]{0,3}$ ]] && [ "$#" -gt "$m" ]; then echo "too_many:$m"; else echo unreadable; fi
    return 1
  fi
  rm -f "$bf"
  if ! jq -e '(.rows | type) == "array" and (.truncated | type) == "boolean"' <<<"$out" >/dev/null 2>&1; then
    echo malformed; return 1
  fi
  jq -e '.truncated' <<<"$out" >/dev/null 2>&1 && { echo truncated; return 1; }
  jq -c '.rows' <<<"$out" > "$f" 2>/dev/null && [ -s "$f" ] || { echo malformed; return 1; }
}

tsp_ref_states() {
  local f="${1:-}" repo="${2:-}" lr why="" m i part refs
  [ -n "$f" ] && [ "$#" -ge 3 ] || return 2
  [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 2
  shift 2
  : > "$f" || return 2
  lr=$(printf '%s' "$repo" | tr 'A-Z' 'a-z')
  refs=("$@")
  if ! command -v _prr_client >/dev/null 2>&1 || ! _prr_client; then
    why=unreadable
  else
    why=$(_tsp_refs_get "$lr" "$f" "${refs[@]}") && why=""
    if [[ "$why" =~ ^too_many:([0-9]+)$ ]]; then
      m="${BASH_REMATCH[1]}"; why=""
      echo '[]' > "$f"
      part="$f.part"
      for ((i = 0; i < ${#refs[@]}; i += m)); do
        why=$(_tsp_refs_get "$lr" "$part" "${refs[@]:i:m}") && why=""
        # A chunk the worker still calls too many (its row moved down) is unreadable.
        case "$why" in '') ;; too_many:*) why=unreadable; break ;; *) break ;; esac
        jq -c --slurpfile p "$part" '. + $p[0]' "$f" > "$f.join" 2>/dev/null && mv -f "$f.join" "$f" \
          || { why=malformed; break; }
      done
      rm -f "$part" "$f.join"
    fi
  fi
  [ -z "$why" ] && return 0
  : > "$f"
  command -v _prr_log >/dev/null 2>&1 && _prr_log "refs $lr miss=$why"
  printf '%s\n' "$why"
  return 1
}
