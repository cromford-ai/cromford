#!/bin/bash
# bin/lib/tracker/github-issues.sh — the GitHub Issues adapter of the tracker
# contract (bin/lib/tracker.sh, BH-4075). Functions trk_gh_*, context TRK_SLUG.
# Every call goes through bin/lib/gh-rest.sh, so its three rcs (0, 44 absent,
# 75 unverifiable) reach the caller and a rate limit is never read as absent.
#
# Sourced, never executed: no `set -e`, no `exit`, nothing at source time but
# the guarded source of the REST helpers it needs.
#
# What GitHub does not have, the adapter says so rather than inventing it:
# waitingOn and triageVerdict are null, a comment is never internal, the key is
# GitHub's own `#<n>` reference, and link_pr is a `PR: <url>` comment (the REST
# issue API has no PR-link field; the PR body's `#n` is GitHub's own link).
_trk_gh_here="$(dirname "${BASH_SOURCE[0]}")"
if ! command -v gh_rest >/dev/null 2>&1 && [ -r "$_trk_gh_here/../gh-rest.sh" ]; then
  # shellcheck source=bin/lib/gh-rest.sh
  . "$_trk_gh_here/../gh-rest.sh"
fi
if ! command -v gh_rest_issue_list >/dev/null 2>&1 && [ -r "$_trk_gh_here/../gh-rest-list.sh" ]; then
  # shellcheck source=bin/lib/gh-rest-list.sh
  . "$_trk_gh_here/../gh-rest-list.sh"
fi
unset _trk_gh_here

# The labels expression bin/lib/fc-issues.sh and bin/kind-gate.sh read with:
# gh's [{"name":"x"}] and a bare ["x"] both.
_TRK_GH_LABELS='[(.labels // [])[]? | if type=="object" then (.name // "") else tostring end]'

_trk_gh_ok() { # _trk_gh_ok <num> — slug and number well-formed
  command -v gh_rest >/dev/null 2>&1 || return 1
  [[ "${TRK_SLUG:-}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] && [[ "${1:-}" =~ ^[0-9]+$ ]]
}

# _trk_gh_fail <gh_rest rc> — a failed call onto the contract. 44 is 1 (the
# ticket is not there). A 4xx GitHub answered on purpose (422, a 403 that is not
# a rate limit) is 1. Everything else gh_rest calls 75 stays 75: a rate limit, a
# 5xx, no answer at all.
_trk_gh_fail() {
  case "${1:-1}" in
    44) return 1 ;;
    75)
      case "${GH_REST_STATUS:-000}:${GH_REST_REASON:-}" in
        429:*|403:rate-limit) return 75 ;;
        4??:*) return 1 ;;
      esac
      return 75 ;;
  esac
  return 1
}

# _trk_gh_norm <issue file> <comments file> — the normalized ticket.
_trk_gh_norm() {
  jq -c --slurpfile cs "$2" "{id: (.number | tostring), key: (\"#\" + (.number | tostring)),
      title: (.title // \"\"), body: (.body // \"\"), status: (.state // null),
      state: (if .state == \"closed\" then \"closed\" else \"open\" end),
      labels: $_TRK_GH_LABELS, waitingOn: null, triageVerdict: null, url: (.html_url // null),
      comments: [(\$cs[0] // [])[] | {author: (.user.login // null), body: (.body // \"\"),
                 createdAt: (.created_at // null), internal: false}]}" "$1" 2>/dev/null
}

# trk_gh_issue_raw <n> — the ONE issue GET, raw body on stdout, gh_rest's rc.
trk_gh_issue_raw() {
  _trk_gh_ok "${1:-}" || return 1
  gh_rest GET "repos/$TRK_SLUG/issues/$1"
}

# trk_gh_labels <n> — the issue's label names, one per line, from the single
# GET (no comment read: bin/lib/fc-issues.sh's parent-label read must not cost
# a second call). Prints nothing on a failed read; rc as trk_gh_issue_raw.
trk_gh_labels() {
  local t rc=0
  t=$(mktemp "${TMPDIR:-/tmp}/trk-gh.XXXXXX") || return 1
  trk_gh_issue_raw "${1:-}" > "$t" || rc=$?
  [ "$rc" = 0 ] && jq -r "$_TRK_GH_LABELS | .[]" "$t" 2>/dev/null
  rm -f "$t"
  return "$rc"
}

# trk_gh_list — the issues list. TRK_LIST_STATE / TRK_LIST_LABEL /
# TRK_LIST_SINCE (bin/lib/tracker.sh) become the state, labels and since
# params; with none set it is the request of today (open, ai-build). The same
# list helper and 200-row max gh_rest_issue_list uses.
trk_gh_list() {
  local t rc=0
  local -a a
  [[ "${TRK_SLUG:-}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] && command -v _gh_rest_list >/dev/null 2>&1 || return 1
  a=(-f "state=${TRK_LIST_STATE:-open}" -f "labels=${TRK_LIST_LABEL:-ai-build}")
  [ -n "${TRK_LIST_SINCE:-}" ] && a+=(-f "since=$TRK_LIST_SINCE")
  t=$(mktemp "${TMPDIR:-/tmp}/trk-gh.XXXXXX") || return 1
  _gh_rest_list "$TRK_SLUG" issues 200 'select(.pull_request == null)' "${a[@]}" > "$t" || rc=$?
  if [ "$rc" != 0 ]; then rm -f "$t"; _trk_gh_fail "$rc"; return $?; fi
  jq -c "${_TRK_ISO_JQ:-} [.[] | {id: (.number | tostring), key: (\"#\" + (.number | tostring)), title: (.title // \"\"),
      status: (.state // null), labels: $_TRK_GH_LABELS, waitingOn: null, triageVerdict: null,
      url: (.html_url // null), updatedAt: (.updated_at | trk_iso),
      state: (if .state == \"closed\" then \"closed\" else \"open\" end),
      commentCount: (.comments | if type == \"number\" then . else null end)}]" "$t" 2>/dev/null || rc=1
  rm -f "$t"
  return "$rc"
}

# trk_gh_read <n> — the issue and its whole thread. A thread at the comment
# cap is a PARTIAL read and answers 1: never decide on a truncated thread.
trk_gh_read() {
  local n="${1:-}" t c rc=0 cnt cap=200
  _trk_gh_ok "$n" && command -v gh_rest_issue_comments >/dev/null 2>&1 || return 1
  t=$(mktemp "${TMPDIR:-/tmp}/trk-gh.XXXXXX") || return 1
  c=$(mktemp "${TMPDIR:-/tmp}/trk-gh.XXXXXX") || { rm -f "$t"; return 1; }
  gh_rest GET "repos/$TRK_SLUG/issues/$n" > "$t" || rc=$?
  [ "$rc" = 0 ] && { gh_rest_issue_comments "$TRK_SLUG" "$n" "$cap" > "$c" || rc=$?; }
  if [ "$rc" != 0 ]; then rm -f "$t" "$c"; _trk_gh_fail "$rc"; return $?; fi
  cnt=$(jq 'length' "$c" 2>/dev/null)
  case "$cnt" in ''|*[!0-9]*) rm -f "$t" "$c"; return 1 ;; esac
  if [ "$cnt" -ge "$cap" ]; then
    printf 'tracker: #%s has %s+ comments, the thread was not read to the end\n' "$n" "$cnt" >&2
    rm -f "$t" "$c"; return 1
  fi
  _trk_gh_norm "$t" "$c" || rc=1
  rm -f "$t" "$c"
  return "$rc"
}

trk_gh_comment() {
  local n="${1:-}" f="${2:-}" rc=0
  _trk_gh_ok "$n" && [ -r "$f" ] || return 1
  _trk_logw "gh api -X POST repos/$TRK_SLUG/issues/$n/comments -F body=@$f"
  _trk_dry && return 0
  gh_rest POST "repos/$TRK_SLUG/issues/$n/comments" -F "body=@$f" >/dev/null || rc=$?
  [ "$rc" = 0 ] || { _trk_gh_fail "$rc"; return $?; }
  return 0
}

# trk_gh_transition <n> <open|closed> — rc 0 only when GitHub's answer says the
# issue is now in that state: a 200 that did not move it is a failure.
trk_gh_transition() {
  local n="${1:-}" s="${2:-}" t rc=0 seen
  case "$s" in open|closed) ;; *) return 3 ;; esac
  _trk_gh_ok "$n" || return 1
  _trk_logw "gh api -X PATCH repos/$TRK_SLUG/issues/$n -f state=$s"
  _trk_dry && return 0
  t=$(mktemp "${TMPDIR:-/tmp}/trk-gh.XXXXXX") || return 1
  gh_rest PATCH "repos/$TRK_SLUG/issues/$n" -f "state=$s" > "$t" || rc=$?
  if [ "$rc" != 0 ]; then rm -f "$t"; _trk_gh_fail "$rc"; return $?; fi
  seen=$(jq -r '.state // empty' "$t" 2>/dev/null); rm -f "$t"
  [ "$seen" = "$s" ] || return 1
  return 0
}

_trk_gh_label_ok() { [ -n "${1:-}" ] && [ "${#1}" -le 100 ]; }

trk_gh_label_add() {
  local n="${1:-}" l="${2:-}" rc=0
  _trk_gh_ok "$n" && _trk_gh_label_ok "$l" || return 1
  _trk_logw "gh api -X POST repos/$TRK_SLUG/issues/$n/labels -f labels[]=$l"
  _trk_dry && return 0
  gh_rest POST "repos/$TRK_SLUG/issues/$n/labels" -f "labels[]=$l" >/dev/null || rc=$?
  [ "$rc" = 0 ] || { _trk_gh_fail "$rc"; return $?; }
  return 0
}

# trk_gh_label_remove <n> <label> — gh_rest's rc UNCHANGED: 44 is "it was not
# there", which two callers read as success and log differently.
trk_gh_label_remove() {
  local n="${1:-}" l="${2:-}" enc rc=0
  _trk_gh_ok "$n" && _trk_gh_label_ok "$l" || return 1
  enc=$(jq -rn --arg l "$l" '$l | @uri') || return 1
  _trk_logw "gh api -X DELETE repos/$TRK_SLUG/issues/$n/labels/$enc"
  _trk_dry && return 0
  gh_rest DELETE "repos/$TRK_SLUG/issues/$n/labels/$enc" >/dev/null || rc=$?
  return "$rc"
}

trk_gh_link_pr() {
  local n="${1:-}" url="${2:-}" f rc=0
  [[ "$url" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+$ ]] || return 1
  _trk_gh_ok "$n" || return 1
  f="${TRK_REQ_FILE:-}"
  [ -n "$f" ] || { f=$(mktemp "${TMPDIR:-/tmp}/trk-gh.XXXXXX") || return 1; }
  printf 'PR: %s\n' "$url" > "$f" || return 1
  trk_gh_comment "$n" "$f" || rc=$?
  [ -n "${TRK_REQ_FILE:-}" ] || rm -f "$f"
  return "$rc"
}

# trk_gh_close_out <n> <bodyfile> [<status>] — the what-shipped comment, THEN
# the close. A comment that did not post stops it: a closed issue with no
# comment saying what shipped is the thing the SOP forbids.
trk_gh_close_out() {
  local rc=0
  trk_gh_comment "${1:-}" "${2:-}" || return $?
  trk_gh_transition "${1:-}" "${3:-closed}" || rc=$?
  return "$rc"
}
