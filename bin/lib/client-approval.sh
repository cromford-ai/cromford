# shellcheck shell=bash
# bin/lib/client-approval.sh — BH-9887 slice C0: ask the product board for the
# client's approval of a PR head that client mode withholds, and tell the
# client on the ticket. Sourced, never executed: no `set -e`, no `exit`,
# nothing at source time.
#
# Readers: bin/merge-conductor.d/bh-9887-client-approval.sh (mc_ca_withheld,
# the conductor hook) and bin/client-approval-request.sh (the detached
# per-(project, PR, head) request). Slices C1/C2 read the marker through
# ca_mark_read.
#
# THE SWITCH. Settings row client_approval_board.<owner>.<name> (lowercased).
#   Only the value `on` (after trim + lowercase) is on. No row, any other value
#   and an unreadable row are off. The global key `client_approval_board` alone
#   is never read.
# THE KNOBS. Settings rows client_approval_board.<name>, seeded by
#   worker/jobs/schema.d/202611220800-bh-9887-client-approval-board-seed.sql.
#   Each code fallback below names its row.
# THE MARKER (format v1). state/client-approval/<project>/<pr>-<head40>.json,
#   written atomically (tmp + mv) by ca_mark_write only:
#   {v:1, project, repo, pr, head, ticket_id, status, attempts, last_http,
#    checked_at, request_id, approvers:[], comment, comment_attempts, updated_at}
#   status: failed|sent|done|absent-route|cap-spent|no-ticket|not-board
#   comment: pending|posted|cap-spent
#   It is a box-local cache of the call. The board holds the approval record.

_ca_root() { printf '%s' "${HARNESS:-${MC_H:-${H:-}}}"; }

# _ca_key <owner/repo> — `owner.name`, lowercased; rc 2 when it is not a repo
#   slug or the switch key built on it would not be a legal settings key.
_ca_key() {
  local k
  [[ "${1:-}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 2
  k=$(printf '%s' "$1" | tr 'A-Z/' 'a-z.')
  [ $(( ${#k} + 22 )) -le 64 ] || return 2
  printf '%s' "$k"
}

# ca_enabled <owner/repo> — rc 0 only for the value `on`. Sets CA_SWITCH to
#   on | off | none (no row) | unreadable (an outage, a bad key, no reader).
ca_enabled() {
  local k v rc=0
  CA_SWITCH=unreadable
  k=$(_ca_key "${1:-}") || return 1
  command -v setting_get >/dev/null 2>&1 || return 1
  v=$(setting_get "client_approval_board.$k" 2>/dev/null) || rc=$?
  case "$rc" in
    0) ;;
    2) CA_SWITCH=none; return 1 ;;
    *) CA_SWITCH=unreadable; return 1 ;;
  esac
  v=$(printf '%s' "$v" | tr -d '[:space:]' | tr 'A-Z' 'a-z')
  if [ "$v" = on ]; then CA_SWITCH=on; return 0; fi
  CA_SWITCH=off
  return 1
}

# ca_knob <name> <fallback> — the positive integer in settings row
#   client_approval_board.<name>, else <fallback> (no row, an outage, or a value
#   that is not a positive integer). Always rc 0.
ca_knob() {
  local v=""
  command -v setting_get >/dev/null 2>&1 && v=$(setting_get "client_approval_board.$1" 2>/dev/null) || v=""
  v=$(printf '%s' "$v" | tr -d '[:space:]')
  case "$v" in ''|*[!0-9]*|0) v="$2" ;; esac
  printf '%s' "$v"
}
# Code fallbacks. Each equals its seed row (tests/client-approval-request
# D1 pins that).
CA_RETRY_MAX_DEFAULT=5        # row client_approval_board.retry_max
CA_TIMEOUT_S_DEFAULT=15       # row client_approval_board.timeout_s
CA_ABSENT_RECHECK_S_DEFAULT=3600  # row client_approval_board.absent_recheck_s
CA_MARKER_KEEP_D_DEFAULT=90   # row client_approval_board.marker_keep_d
CA_PRUNE_MAX_DEFAULT=200      # row client_approval_board.prune_max
CA_SUMMARY_MAX_CHARS_DEFAULT=500  # row client_approval_board.summary_max_chars
CA_APPROVER_NAME_MAX_DEFAULT=80   # row client_approval_board.approver_name_max
CA_APPROVERS_MAX_DEFAULT=10       # row client_approval_board.approvers_max

# ca_mark_file <project> <pr> <head> — the marker path for that head. rc 1 and
#   no output when the harness root is empty: never a path under `/`.
ca_mark_file() {
  local r
  r=$(_ca_root)
  [ -n "$r" ] || return 1
  printf '%s/state/client-approval/%s/%s-%s.json' "$r" "$1" "$2" "$(printf '%s' "$3" | tr 'A-F' 'a-f')"
}

# ca_mark_read <file> — prints the marker JSON (one line). rc 1 when there is
#   no file, or it is not a v1 marker object (then it reads as no marker).
ca_mark_read() {
  [ -r "${1:-}" ] || return 1
  jq -ce 'select(type == "object" and .v == 1 and (.status | type) == "string")' "$1" 2>/dev/null
}

# ca_mark_settled <file> [<absent_recheck_s>] — rc 0 when the head needs no new
#   attempt: a terminal status (done, cap-spent, no-ticket, not-board), or
#   absent-route checked less than <absent_recheck_s> ago. rc 1 otherwise (no
#   marker, failed, sent with the comment still due, an old absent-route).
ca_mark_settled() {
  local m s c now win="${2:-$CA_ABSENT_RECHECK_S_DEFAULT}"
  m=$(ca_mark_read "${1:-}") || return 1
  s=$(printf '%s' "$m" | jq -r '.status')
  case "$s" in
    done|cap-spent|no-ticket|not-board) return 0 ;;
    absent-route)
      c=$(printf '%s' "$m" | jq -r '.checked_at // 0 | floor? // 0' 2>/dev/null)
      case "$c" in ''|*[!0-9]*) return 1 ;; esac
      now=$(date -u +%s)
      [ $(( now - c )) -lt "$win" ] && return 0
      return 1 ;;
  esac
  return 1
}

# ca_mark_write <file> <json> — writes the marker atomically, stamping
#   updated_at. rc 1 when the JSON is not an object or the write fails.
ca_mark_write() {
  local f="${1:-}" tmp
  [ -n "$f" ] || return 1
  mkdir -p "${f%/*}" 2>/dev/null || return 1
  tmp=$(mktemp "${f%/*}/.ca-mark.XXXXXX" 2>/dev/null) || return 1
  if printf '%s' "${2:-}" | jq -ce --argjson now "$(date -u +%s)" 'select(type == "object") | .v = 1 | .updated_at = $now' > "$tmp" 2>/dev/null \
     && mv -f "$tmp" "$f" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  return 1
}

# ca_paths_json "<LA_PROTECTED_PATHS>" — the paths as a JSON array of at most 5
#   strings. la_decide joins them with ", " and ends a longer list with
#   ", +N more"; that item is dropped. A path cannot hold a comma (globs and git
#   paths of catalog/lead-protected-paths.seed.tsv hold none).
ca_paths_json() {
  printf '%s' "${1:-}" | jq -Rsc 'split(", ") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0 and (test("^\\+[0-9]+ more$") | not))) | .[:5]'
}

# ca_reason <paths_json> — the fixed client-safe sentence for the request.
ca_reason() {
  printf '%s' "${1:-[]}" | jq -r 'if length > 0 then "This change touches parts of the app that members see: \(join(", ")). It needs approval before it goes live."
    else "This change touches parts of the app that members see. It needs approval before it goes live." end'
}

# ca_request_body <slug> <pr> <head> <paths_json> <summary|""> <previewUrl|"">
#   — the approval-request body (one JSON line).
ca_request_body() {
  local reason
  reason=$(ca_reason "$4") || return 1
  jq -nc --arg slug "$1" --argjson pr "$2" --arg head "$3" --argjson paths "$4" \
    --arg summary "$5" --arg preview "$6" --arg reason "$reason" \
    '{prNumber: $pr, prUrl: "https://github.com/\($slug)/pull/\($pr)", headSha: $head,
      reason: $reason, paths: $paths,
      summary: (if $summary == "" then null else $summary end),
      previewUrl: (if $preview == "" then null else $preview end)}'
}

# ca_summary <record-dir> [<max-chars>] — the build record's what.txt as one
#   line: non-blank lines, a leading "<KEY>: " stripped, joined by "; ", at most
#   <max-chars> chars (default CA_SUMMARY_MAX_CHARS_DEFAULT; the caller reads
#   row summary_max_chars). Empty when there is none.
ca_summary() {
  local f="${1:-}/what.txt" max="${2:-$CA_SUMMARY_MAX_CHARS_DEFAULT}"
  [ -n "${1:-}" ] && [ -r "$f" ] || return 0
  case "$max" in ''|*[!0-9]*|0) max=$CA_SUMMARY_MAX_CHARS_DEFAULT ;; esac
  jq -Rsr --argjson max "$max" '[split("\n")[] | gsub("^\\s+|\\s+$"; "") | sub("^[A-Za-z]+-[0-9]+(\\.[0-9]+)?:\\s*"; "") | select(length > 0)] | join("; ") | .[:$max]' "$f" 2>/dev/null
}

# ca_approvers <answer-file> [<name-max> [<list-max>]] — the names in
#   .approvers[] (or .request.approvers), each `.name` or a string, trimmed, at
#   most <name-max> chars each (default CA_APPROVER_NAME_MAX_DEFAULT, row
#   approver_name_max), at most <list-max> names (default
#   CA_APPROVERS_MAX_DEFAULT, row approvers_max).
ca_approvers() {
  local nmax="${2:-$CA_APPROVER_NAME_MAX_DEFAULT}" lmax="${3:-$CA_APPROVERS_MAX_DEFAULT}"
  case "$nmax" in ''|*[!0-9]*|0) nmax=$CA_APPROVER_NAME_MAX_DEFAULT ;; esac
  case "$lmax" in ''|*[!0-9]*|0) lmax=$CA_APPROVERS_MAX_DEFAULT ;; esac
  jq -c --argjson nmax "$nmax" --argjson lmax "$lmax" '[((.approvers // .request.approvers // []) | if type == "array" then .[] else empty end)
          | if type == "object" then (.name // "") elif type == "string" then . else "" end
          | tostring | gsub("^\\s+|\\s+$"; "") | .[:$nmax] | select(length > 0)] | .[:$lmax]' "${1:-/dev/null}" 2>/dev/null || echo '[]'
}

# ca_request_id <answer-file> — `.id // .request.id` when it matches
#   ^[A-Za-z0-9_-]{1,64}$, else empty.
ca_request_id() {
  local id
  id=$(jq -r '(.id // .request.id // empty) | tostring' "${1:-/dev/null}" 2>/dev/null) || id=""
  [[ "$id" =~ ^[A-Za-z0-9_-]{1,64}$ ]] && printf '%s' "$id"
  return 0
}

# ca_comment_body <prUrl> <pr> <summary|""> <previewUrl|""> <approvers_json>
#   — the fixed client-safe ticket comment, HTML, every inserted value escaped.
ca_comment_body() {
  jq -nr --arg url "$1" --arg pr "$2" --arg summary "$3" --arg preview "$4" --argjson names "${5:-[]}" '
    def who: if length == 0 then "Someone on your team with approval rights can approve it."
             elif length == 1 then "\(.[0] | @html) can approve it."
             else "\(.[:-1] | map(@html) | join(", ")) or \(.[-1] | @html) can approve it." end;
    "<p>This one is built and ready: <a href=\"\($url | @html)\">pull request #\($pr | @html)</a>.</p>"
    + (if $summary == "" then "" else
        "<p>What changes:</p><ul>" + ($summary | split("; ") | map("<li>\(@html)</li>") | join("")) + "</ul>" end)
    + (if $preview == "" then "" else
        "<p>You can try it here: <a href=\"\($preview | @html)\">\($preview | @html)</a></p>" end)
    + "<p>It changes parts of the app that members see, so it goes live only after a named approval. \($names | who)</p>"
    + "<p>The Approve button is on this ticket. Once it is approved, we merge it and it moves toward live.</p>"'
}

# ca_board_post <url> <body-file> <idempotency-key> <timeout-s> <answer-file>
#   — one POST to the board; prints the HTTP status (000 when curl got no
#   answer). The token (TRK_BOARD_TOKEN) is only on curl's argv, never in a
#   log or a file. This is the board seam for the request route.
ca_board_post() {
  local code
  code=$(curl -sS -o "$5" -w '%{http_code}' --max-time "$4" -X POST \
    -H "User-Agent: curl/8" -H "Content-Type: application/json" -H "Idempotency-Key: $3" \
    -H "Authorization: Bearer ${TRK_BOARD_TOKEN:-}" --data-binary "@$2" "$1" 2>/dev/null) || true
  [[ "$code" =~ ^[0-9]{3}$ ]] || code=000
  printf '%s' "$code"
}

# ca_prune <project> [<keep_d> [<max>]] — deletes the project's marker files older than
#   <keep_d> days (row client_approval_board.marker_keep_d), at most <max>
#   (row client_approval_board.prune_max) per run. Prints the count.
ca_prune() {
  local d keep="${2:-$CA_MARKER_KEEP_D_DEFAULT}" max="${3:-$CA_PRUNE_MAX_DEFAULT}" n=0 f
  d="$(_ca_root)/state/client-approval/${1:-}"
  [ -n "${1:-}" ] && [ -d "$d" ] || { echo 0; return 0; }
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rm -f "$f" 2>/dev/null && n=$((n + 1))
  done < <(find "$d" -maxdepth 1 -type f -name '*.json' -mtime +"$keep" 2>/dev/null | head -n "$max")
  echo "$n"
}
