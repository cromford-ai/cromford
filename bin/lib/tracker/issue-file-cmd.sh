#!/bin/bash
# gh-identity: app-token
# bin/lib/tracker/issue-file-cmd.sh — the hub side of the console's file_issue
# command (BH-9014). Sourced, never executed; bin/poll-commands.sh runs it from
# its `# >>> file_issue handler` arm. The MCP `file_issue` tool queues the row
# (console-ui/functions/_lib/board-commands.js).
#
#   ifcmd_run <project> <payload-json> <command-id>
#     payload {title, body?, actor}. Prints ONE result line.
#     rc 0 OK (filed, or filed before), 1 failed and retryable, 3 refused (the
#     line starts `refused:`). The comment_issue shape (bin/lib/issue-comment-cmd.sh).
#
# ONLY AS THE APP. An issue filed on the PAT reads as a human action to
# hold_classify (bin/lib/hold.sh), and every other console write of the hub is
# App-only. A box with no App token answers rc 1 and files nothing.
#
# ONLY A GITHUB-ISSUES BOARD (fleet.conf board_prefix `-`). Any other project is
# `refused:`. The create is REST (bin/lib/tracker/gh-issue-create.sh), never
# `gh issue create` (GraphQL). The issue carries no label, so no build lane
# picks it up.
#
# EXACTLY ONCE PER COMMAND ID. The issue body ends with `<!-- mc-command:<id> -->`.
# Before it files, the lib reads ONE page of the repo's newest issues
# (state=all, sort=created, desc) and an issue whose body carries the marker
# means a lost ack or an expired lease ran this command before: nothing is
# filed again, and the result names that issue. A failed read files nothing
# (rc 1). LIMIT: the page is FILE_ISSUE_LOOKBACK issues (default 100,
# GitHub's page maximum). If more issues than that are filed between a first
# attempt and its retry, the retry files a duplicate. A retry comes within one
# lease window (minutes), so one page is the accepted bound.
#
# The body text never goes on argv and never reaches a log.

[ -n "${ISSUE_FILE_CMD_LIB:-}" ] && return 0
ISSUE_FILE_CMD_LIB=1

_ifcmd_here="${BASH_SOURCE[0]%/*}"
# shellcheck source=bin/lib/gh-app-auth.sh
[ -r "$_ifcmd_here/../gh-app-auth.sh" ] && . "$_ifcmd_here/../gh-app-auth.sh"
# shellcheck source=bin/lib/tracker/gh-issue-create.sh
[ -r "$_ifcmd_here/gh-issue-create.sh" ] && . "$_ifcmd_here/gh-issue-create.sh"

# Fallback of the poll-commands lane knob FILE_ISSUE_LOOKBACK
# (catalog/lanes.d/poll-commands.knobs.d/FILE_ISSUE_LOOKBACK.json; its settings
# row reaches this env through lane_env_apply in bin/poll-commands.sh). Used
# when the knob is unset, not a whole number, or out of 1..100.
IFCMD_LOOKBACK_DEFAULT=100

ifcmd_run() {
  local rc
  ifcmd__run "$@"; rc=$?
  command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset
  return "$rc"
}

# ifcmd__err <file> — the first line of a stderr file, one line, 200 chars.
ifcmd__err() { head -n 1 "$1" 2>/dev/null | tr -d '\r\t' | cut -c1-200; }

# ifcmd__lookback — the per_page of the dedup read.
ifcmd__lookback() {
  local v="${FILE_ISSUE_LOOKBACK:-}"
  [[ "$v" =~ ^([1-9][0-9]?|100)$ ]] || v="$IFCMD_LOOKBACK_DEFAULT"
  printf '%s' "$v"
}

ifcmd__run() {
  local project="${1:-}" payload="${2:-}" id="${3:-}"
  local pjs slug bp title actor marker n errf lj hit bodyf
  local root="${HARNESS:-${H:-}}"

  # Project: in fleet.conf, and a GitHub-issues board (no board-API prefix).
  # A read that failed is retryable, never `refused:` (BH-2009).
  [[ "$project" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "refused: $project is not a GitHub-issues board"; return 3; }
  [ -n "$root" ] || { echo "issue not filed: no harness root; retry"; return 1; }
  if ! pjs=$("$root/bin/fleet-conf.sh" --projects 2>/dev/null) || [ -z "${pjs//[[:space:]]/}" ]; then
    echo "issue not filed: fleet-conf --projects could not be read; retry"; return 1
  fi
  grep -qxF -- "$project" <<<"$pjs" || { echo "refused: $project is not a GitHub-issues board"; return 3; }
  if ! slug=$("$root/bin/fleet-conf.sh" "$project" repo 2>/dev/null) \
     || ! bp=$("$root/bin/fleet-conf.sh" "$project" board_prefix 2>/dev/null); then
    echo "issue not filed: fleet-conf $project could not be read; retry"; return 1
  fi
  if [ "$bp" != "-" ] || [ "$slug" = "-" ] || ! [[ "$slug" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
    echo "refused: $project is not a GitHub-issues board"; return 3
  fi

  # Payload. A non-string title or body refuses; nothing is coerced.
  jq -e 'type=="object"' >/dev/null 2>&1 <<<"$payload" || { echo "refused: bad payload"; return 3; }
  jq -e '(.title|type)=="string" and (.title|test("\\S"))' >/dev/null 2>&1 <<<"$payload" \
    || { echo "refused: empty title"; return 3; }
  jq -e '(has("body")|not) or (.body == null) or ((.body|type)=="string")' >/dev/null 2>&1 <<<"$payload" \
    || { echo "refused: bad body"; return 3; }
  [[ "$id" =~ ^[1-9][0-9]*$ ]] || { echo "refused: bad command id"; return 3; }
  title=$(jq -r '.title' <<<"$payload")
  actor=$(jq -r 'if (.actor|type)=="string" then .actor else "" end' <<<"$payload" | tr -cd 'A-Za-z0-9@._+-' | cut -c1-100)
  marker="<!-- mc-command:$id -->"

  command -v gh_issue_create >/dev/null 2>&1 \
    || { echo "issue not filed: tracker/gh-issue-create.sh not loaded"; return 1; }
  command -v gh_auth_for >/dev/null 2>&1 && { gh_auth_for "$slug" || true; }
  case "${GH_TOKEN:-}" in ghs_*) ;; *) echo "issue not filed: no App token on this box; retry"; return 1 ;; esac

  n=$(ifcmd__lookback)
  errf=$(mktemp) || { echo "issue not filed: no temp file; retry"; return 1; }
  # gh's own exit code is read before jq sees the page, so a failed read is
  # never an empty list.
  if ! lj=$(gh api "repos/$slug/issues?state=all&sort=created&direction=desc&per_page=$n" 2>"$errf") \
     || ! jq -e 'type=="array"' >/dev/null 2>&1 <<<"$lj"; then
    echo "issue not filed: issue list read failed on $slug ($(ifcmd__err "$errf")); retry"; rm -f "$errf"; return 1
  fi
  hit=$(jq -r --arg m "$marker" \
    'first(.[] | select((has("pull_request")|not) and ((.body // "")|type=="string") and ((.body // "")|contains($m))) | .html_url) // empty' \
    <<<"$lj" 2>/dev/null)
  if [ -n "$hit" ]; then
    rm -f "$errf"; echo "issue already filed: $hit (command $id)"; return 0
  fi

  bodyf=$(mktemp) || { rm -f "$errf"; echo "issue not filed: no temp file; retry"; return 1; }
  if ! jq -j --arg m "$marker" '(.body // "") as $b | (if $b == "" then "" else $b + "\n\n" end) + $m' \
       <<<"$payload" > "$bodyf"; then
    rm -f "$errf" "$bodyf"; echo "issue not filed: body not written; retry"; return 1
  fi
  if ! gh_issue_create "$slug" "$title" "$bodyf" >/dev/null 2>"$errf"; then
    local e; e=$(ifcmd__err "$errf"); rm -f "$errf" "$bodyf"
    # GitHub's 422 message is exactly this; the same payload never passes.
    [ "$e" = "Validation Failed" ] && { echo "refused: GitHub refused the issue (Validation Failed)"; return 3; }
    echo "issue not filed on $slug ($e)"; return 1
  fi
  rm -f "$errf" "$bodyf"
  echo "filed #$GH_ISSUE_NUMBER $GH_ISSUE_URL as the App (command $id, actor ${actor:-unknown})"
  return 0
}
