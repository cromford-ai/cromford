#!/bin/bash
# gh-identity: raw-by-design — a shared helper that runs on the identity its caller armed (GH_TOKEN in the caller's env); arming here would replace a caller's repo-scoped token with another one.
# bin/lib/tracker/gh-issue-create.sh — file one GitHub issue over REST.
#
#   gh_issue_create <owner/repo> <title> <body-file> [labels...]
#
# `gh issue create` is GraphQL, and the fleet's accounts hit the GraphQL rate
# limit mid-run. This is the REST create:
#   gh api -X POST repos/<repo>/issues -f title=<t> -F body=@<file> -f labels[]=<l> ...
#
# rc 0: the issue's .html_url on stdout; GH_ISSUE_NUMBER and GH_ISSUE_URL set
#       from the JSON answer (.number, .html_url), never from URL text.
# rc 1: one line on stderr (the API .message, else gh's first stderr line);
#       GH_ISSUE_NUMBER and GH_ISSUE_URL empty. Bad args send no request.
# A response with no positive .number or no .html_url is a failure, so a
# caller never records an issue it cannot name.
#
# GH_ISSUE_CREATE_TIMEOUT_S (opt-in, unset = no bound): a positive integer runs
# the call under `timeout`, for a caller that bounded its create before.
#
# Sourced, never executed: no `set -e`, no `exit`, nothing at source time.
[ -n "${GH_ISSUE_CREATE_LIB:-}" ] && return 0
GH_ISSUE_CREATE_LIB=1

gh_issue_create() {
  GH_ISSUE_NUMBER=""; GH_ISSUE_URL=""
  local repo="${1:-}" title="${2:-}" bodyfile="${3:-}" l out err rc=0 n u msg
  shift 3 2>/dev/null || shift "$#"
  if ! [[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
    echo "gh_issue_create: bad args (repo)" >&2; return 1
  fi
  [ -n "$title" ] || { echo "gh_issue_create: bad args (title)" >&2; return 1; }
  { [ -n "$bodyfile" ] && [ -f "$bodyfile" ] && [ -r "$bodyfile" ]; } \
    || { echo "gh_issue_create: bad args (body)" >&2; return 1; }
  local args=(-X POST "repos/$repo/issues" -f "title=$title" -F "body=@$bodyfile")
  for l in "$@"; do
    [ -n "$l" ] && args+=(-f "labels[]=$l")
  done
  out=$(mktemp 2>/dev/null) || { echo "gh_issue_create: no temp file" >&2; return 1; }
  err=$(mktemp 2>/dev/null) || { rm -f "$out"; echo "gh_issue_create: no temp file" >&2; return 1; }
  if [[ "${GH_ISSUE_CREATE_TIMEOUT_S:-}" =~ ^[1-9][0-9]*$ ]]; then
    timeout "$GH_ISSUE_CREATE_TIMEOUT_S" gh api "${args[@]}" > "$out" 2> "$err" || rc=$?
  else
    gh api "${args[@]}" > "$out" 2> "$err" || rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    msg=$(jq -r '.message // empty' "$out" 2>/dev/null || true)
    [ -n "$msg" ] || msg=$(head -1 "$err" | tr -d '\r' | cut -c1-200)
    rm -f "$out" "$err"
    echo "${msg:-gh_issue_create: gh api failed (rc $rc)}" >&2
    return 1
  fi
  n=$(jq -r '.number // empty' "$out" 2>/dev/null || true)
  u=$(jq -r '.html_url // empty' "$out" 2>/dev/null || true)
  rm -f "$out" "$err"
  if ! [[ "$n" =~ ^[1-9][0-9]*$ ]] || [ -z "$u" ]; then
    echo "gh_issue_create: no issue number in the response" >&2
    return 1
  fi
  GH_ISSUE_NUMBER="$n"; GH_ISSUE_URL="$u"
  printf '%s\n' "$u"
  return 0
}
