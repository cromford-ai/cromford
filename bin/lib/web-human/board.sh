#!/bin/bash
# gh-identity: app-token
# bin/lib/web-human/board.sh — BH-7598: the board (GitHub issue) seam of the
# web-task human step (bin/lib/web-human.sh). Sourced, never run; functions
# only. The one place this lane calls GitHub, through `gh api`.
#
#   whb_post <owner/repo> <issue> <body>
#     ONE comment on the issue; the body goes to gh on stdin.
#     rc 0: `posted <comment_id> <created_at>`; rc 1: `failed <why>`.
#
#   whb_done_after <owner/repo> <issue> <since-iso> <logins-csv>
#     ONE read of the comments since <since-iso> (per_page 100). The newest
#     comment created after <since-iso>, by a login in <logins-csv> (case
#     folded), not a bot (user.type Bot or a [bot] login), whose FIRST line
#     starts `HUMAN-STEP-DONE:`. A marker mid-text, in a code block or on a
#     later line does not count.
#     rc 0: the text after the marker, trimmed, on stdout.
#     rc 1: no such comment.
#     rc 2: the read failed or was not a comment list (never read as "none").
#
# Each gh call runs on the repo's App installation token when this box mints
# one (bin/lib/gh-app-auth.sh: gh_auth_for, then gh_auth_reset); an unarmed box
# keeps the identity gh already has.

__whb_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if ! declare -F gh_auth_for >/dev/null; then
  # shellcheck source=bin/lib/gh-app-auth.sh
  . "$__whb_dir/../gh-app-auth.sh" || { echo "web-human: bin/lib/gh-app-auth.sh did not load" >&2; return 1; }
fi

whb_post() {
  local repo="${1:-}" num="${2:-}" body="${3:-}" out hit
  [ -n "$repo" ] && [ -n "$num" ] && [ -n "$body" ] || { echo "failed usage"; return 1; }
  gh_auth_for "$repo" || true
  out=$(printf '%s' "$body" | gh api -X POST "repos/$repo/issues/$num/comments" -F body=@- 2>/dev/null) \
    || { gh_auth_reset; echo "failed gh"; return 1; }
  gh_auth_reset
  hit=$(printf '%s' "$out" | jq -r 'if (.id | type) == "number" and (.created_at | type) == "string" then "\(.id) \(.created_at)" else empty end' 2>/dev/null)
  [ -n "$hit" ] || { echo "failed no comment id"; return 1; }
  echo "posted $hit"
}

# GitHub's maximum page size for issue comments: an API format bound, not a
# tunable limit, so it has no settings row.
WHB_PAGE_SIZE=100

# The compare is strict (created_at > since) at 1-second resolution: a reply
# posted in the same second as the hold comment is not read. A person cannot
# read the hold comment and answer it in under a second.
whb_done_after() {
  local repo="${1:-}" num="${2:-}" since="${3:-}" logins="${4:-}" out hit
  [ -n "$repo" ] && [ -n "$num" ] && [ -n "$since" ] || return 2
  gh_auth_for "$repo" || true
  out=$(gh api "repos/$repo/issues/$num/comments?since=$since&per_page=$WHB_PAGE_SIZE" 2>/dev/null) || { gh_auth_reset; return 2; }
  gh_auth_reset
  printf '%s' "$out" | jq -e 'type == "array"' >/dev/null 2>&1 || return 2
  hit=$(printf '%s' "$out" | jq -r --arg since "$since" --arg logins "$logins" '
    ($logins | ascii_downcase | split(",") | map(select(length > 0))) as $ok
    | [ .[]
        | select((.created_at // "") > $since)
        | select((.user.type // "") != "Bot" and ((.user.login // "") | endswith("[bot]") | not))
        | select(((.user.login // "") | ascii_downcase) as $l | any($ok[]; . == $l))
        | ((.body // "") | split("\n")[0] | sub("\r$"; "")) as $first
        | select($first | startswith("HUMAN-STEP-DONE:"))
        | {at: .created_at, v: ($first | sub("^HUMAN-STEP-DONE:[ \t]*"; "") | sub("[ \t]+$"; ""))} ]
    | sort_by(.at) | last | .v // empty' 2>/dev/null) || return 2
  [ -n "$hit" ] || return 1
  printf '%s' "$hit"
}
