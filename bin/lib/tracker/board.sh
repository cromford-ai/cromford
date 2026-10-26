#!/bin/bash
# bin/lib/tracker/board.sh — the in-app product board adapter of the tracker
# contract (bin/lib/tracker.sh, BH-4075). Functions trk_board_*, context
# TRK_BOARD_BASE / TRK_BOARD_TOKEN / TRK_BOARD_TOKEN_VAR. The routes are the
# ones docs/BOARD-API-CONTRACT.md documents, under the project's own base.
#
# Sourced, never executed: no `set -e`, no `exit`, nothing at source time.
#
# THE TOKEN never reaches a log, a file or a body: it is handed to curl on its
# command line, and the logged command names its variable instead.
#
# What the board contract has no route for answers 3 (UNSUPPORTED) and sends
# nothing: label_add and label_remove. link_pr is a comment with the link.

# _trk_board_curl <GET|POST> <url> [<json file> [<idempotency key>]] — one board
# call (moved verbatim from bin/lib/fc-board.sh's _fcb_curl). The command is
# logged first (token as its variable name). In a dry run it is printed and not
# sent, and the answer is empty with rc 0. Otherwise the answer is on stdout and
# a curl failure (including HTTP >= 400, `-f`) is the rc.
_trk_board_curl() {
  local method="$1" url="$2" data="${3:-}" idem="${4:-}" line
  local args=(-sS -f --max-time 30 -H "User-Agent: curl/8")
  line="curl -sS -f --max-time 30 -H \"Authorization: Bearer \$${TRK_BOARD_TOKEN_VAR:-TOKEN}\""
  if [ "$method" = POST ]; then
    args+=(-X POST -H "Content-Type: application/json")
    line="$line -X POST -H 'Content-Type: application/json'"
    [ -n "$idem" ] && { args+=(-H "Idempotency-Key: $idem"); line="$line -H $(_trk_sq "Idempotency-Key: $idem")"; }
    args+=(--data-binary "@$data"); line="$line --data-binary @$(_trk_sq "$data")"
  fi
  line="$line $(_trk_sq "$url")"
  _trk_logw "$line"
  _trk_dry && return 0
  curl "${args[@]}" -H "Authorization: Bearer ${TRK_BOARD_TOKEN:-}" "$url" 2>>"${TRK_ERR:-/dev/null}"
}

_trk_board_ok() { # _trk_board_ok <id> — a base to call and an id that is one path segment
  [ -n "${TRK_BOARD_BASE:-}" ] && [[ "${1:-}" =~ ^[A-Za-z0-9_.:-]+$ ]]
}

# _trk_board_req — the request file: TRK_REQ_FILE, or a temp file the verb
# removes (_trk_board_req_done).
_trk_board_req() {
  if [ -n "${TRK_REQ_FILE:-}" ]; then printf '%s' "$TRK_REQ_FILE"
  else mktemp "${TMPDIR:-/tmp}/trk-board.XXXXXX"; fi
}
_trk_board_req_done() { [ -n "${TRK_REQ_FILE:-}" ] || rm -f "${1:-}"; }

# One ticket, as the list and read routes return it (`.ticket // .`), normalized.
# shellcheck disable=SC2016
_TRK_BOARD_ROW='(.ticket // .) | {id: (.id | tostring), key: (.key // null),
  title: (.title // ""), status: (.status // null),
  labels: [(.labels // [])[]? | if type=="object" then (.name // "") else tostring end],
  waitingOn: ((.waitingOn // .waiting_on) | if . == null or . == "" then null else tostring end),
  triageVerdict: ((.triageVerdict // .triage_verdict) | if . == null or . == "" then null else tostring end),
  url: (.url // .href // null)}'

# The three keys only a LIST row carries (bin/lib/tracker.sh): updatedAt from
# lastActivityAt (else updatedAt), state closed for the closed words the gate's
# keymap uses, commentCount only when the board sent a number.
# shellcheck disable=SC2016
_TRK_BOARD_LIST_KEYS='(.ticket // .) | {updatedAt: ((.lastActivityAt // .updatedAt) | trk_iso),
  state: (((.status // "") | tostring | ascii_downcase) as $s
          | if (["done","closed","cancelled","canceled","archived"] | index($s)) != null then "closed" else "open" end),
  commentCount: (.commentCount | if type == "number" then . else null end)}'

# trk_board_ticket_raw <id> — the ONE ticket GET, raw answer, curl's rc. Honours
# TRK_DRY like every call here: bin/lib/fc-board.sh prints it in a dry run.
trk_board_ticket_raw() {
  _trk_board_ok "${1:-}" || return 1
  _trk_board_curl GET "$TRK_BOARD_BASE/tickets/$1"
}

trk_board_list() {
  local TRK_DRY=0 boards bid rows
  [ -n "${TRK_BOARD_BASE:-}" ] || return 1
  boards=$(_trk_board_curl GET "$TRK_BOARD_BASE/boards") || return 1
  bid=$(printf '%s' "$boards" | jq -r '(.boards? // .) | if type == "array" then (.[0].id // empty | tostring) else empty end' 2>/dev/null)
  [[ "$bid" =~ ^[A-Za-z0-9_.:-]+$ ]] || return 1
  rows=$(_trk_board_curl GET "$TRK_BOARD_BASE/boards/$bid/tickets") || return 1
  printf '%s' "$rows" | jq -ce "${_TRK_ISO_JQ:-} (.tickets? // .) | if type == \"array\" then [.[] | ($_TRK_BOARD_ROW) + ($_TRK_BOARD_LIST_KEYS)] else error end" 2>/dev/null || return 1
}

# trk_board_read <id> — always SENT, even under TRK_DRY: a read writes nothing.
trk_board_read() {
  local TRK_DRY=0 raw
  raw=$(trk_board_ticket_raw "${1:-}") || return 1
  printf '%s' "$raw" | jq -ce "select(((.ticket // .) | type) == \"object\" and ((.ticket // .) | has(\"id\")))
    | . as \$r | ($_TRK_BOARD_ROW) + {body: ((\$r.ticket // \$r) | (.description // .body // \"\")),
      comments: [((\$r.comments // \$r.ticket.comments // [])[]? | {
        author: (.author | if type == \"object\" then (.name // .userId // null) elif type == \"string\" then . else null end),
        body: (.body // \"\"), createdAt: (.createdAt // .created_at // null), internal: (.isInternal == true)})]}" 2>/dev/null \
    || return 1
}

trk_board_comment() {
  local id="${1:-}" f="${2:-}" req rc=0
  _trk_board_ok "$id" && [ -r "$f" ] || return 1
  req=$(_trk_board_req) || return 1
  jq -n --rawfile body "$f" '{body: $body}' > "$req" 2>/dev/null || { _trk_board_req_done "$req"; return 1; }
  _trk_board_curl POST "$TRK_BOARD_BASE/tickets/$id/comments" "$req" || rc=1
  _trk_board_req_done "$req"
  return "$rc"
}

# trk_board_transition <id> <todo|in_progress|review|done|closed> — prints the
# board's answer. rc 0 only when curl succeeded AND the answer names the target
# status: a 200 that did not move the ticket is a failure. TRK_CURL_RC is left
# in the caller's shell with curl's own rc, for a caller whose log names it.
trk_board_transition() {
  local id="${1:-}" s="${2:-}" req resp
  TRK_CURL_RC=0
  case "$s" in todo|in_progress|review|done|closed) ;; *) return 3 ;; esac
  _trk_board_ok "$id" || return 1
  req=$(_trk_board_req) || return 1
  printf '{"toStatus":"%s","sortOrder":999999}\n' "$s" > "$req" || { _trk_board_req_done "$req"; return 1; }
  if _trk_dry; then
    _trk_board_curl POST "$TRK_BOARD_BASE/tickets/$id/move" "$req"
    _trk_board_req_done "$req"; return 0
  fi
  resp=$(_trk_board_curl POST "$TRK_BOARD_BASE/tickets/$id/move" "$req") || TRK_CURL_RC=$?
  _trk_board_req_done "$req"
  [ -n "$resp" ] && printf '%s\n' "$resp"
  [ "$TRK_CURL_RC" = 0 ] && grep -q "\"$s\"" <<<"$resp" || return 1
  return 0
}

trk_board_label_add()    { return 3; }
trk_board_label_remove() { return 3; }

trk_board_link_pr() {
  local id="${1:-}" url="${2:-}" f rc=0 esc
  [[ "$url" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+$ ]] || return 1
  _trk_board_ok "$id" || return 1
  f=$(mktemp "${TMPDIR:-/tmp}/trk-board.XXXXXX") || return 1
  esc=$(printf '%s' "$url" | sed -e 's/&/\&amp;/g' -e 's/"/\&quot;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')
  printf '<p>PR: <a href="%s">%s</a></p>' "$esc" "$esc" > "$f"
  trk_board_comment "$id" "$f" || rc=$?
  rm -f "$f"
  return "$rc"
}

# trk_board_close_out <id> <bodyfile> [<status>] — the comment, THEN the move.
# `review` is the contract's terminal default, never `done` unless asked.
trk_board_close_out() {
  trk_board_comment "${1:-}" "${2:-}" || return 1
  trk_board_transition "${1:-}" "${3:-review}"
}
