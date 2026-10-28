#!/bin/bash
# bin/lib/ticket-state.sh — is a ticket open or closed, one read through the
# tracker contract (bin/lib/tracker.sh). Read by bin/builds-retention.sh (rule
# 2, `settled`). Reads only: no tracker write verb is called. A board
# project's base and token come from tracker_context (BH-8682): this file never
# reads fleet.conf column 4 itself.
#
# Sourced, never executed: no `set -e`, no `exit`, no output at source time.
#
#   tks_state <harness-root> <project> <ticket_id>
#       prints `open` or `closed`, rc 0
#       rc 1   unreadable: no id, an unknown project, a jira/linear/unset
#              adapter, a board with no base or token, a failed read, an answer
#              with no status
#       rc 75  rate limited (passed through from the adapter); stop reading
#
# Closed: GitHub `.status` closed; a board status done, closed, archived,
# cancelled or canceled (the set bin/lib/lookback-board.sh reads). Any other
# non-empty status is open. A GitHub read runs with GH_REST_OPTIONAL=1, so the
# shared quota reserve refuses it first (rc 75) and the lane stops reading.
#
# TEST SEAM (the local fake, BH-7563): when BUILDS_RETENTION_TICKET_STATE_FILE
# is set, tks_state reads only that TSV, `<project> TAB <id> TAB
# <open|closed|unreadable|ratelimited>`, and makes no network call. An id that
# is not in the file is rc 1.

_tks_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)
if ! command -v tracker_adapter >/dev/null 2>&1 && [ -r "$_tks_dir/tracker.sh" ]; then
  # shellcheck source=bin/lib/tracker.sh
  . "$_tks_dir/tracker.sh"
fi

tks_state() {
  local r="${1:-}" p="${2:-}" id="${3:-}" v ad t rc=0 st TRK_CTX_MISSING=""
  [ -n "$r" ] && [ -n "$p" ] && [ -n "$id" ] && [ "$id" != - ] || return 1
  if [ -n "${BUILDS_RETENTION_TICKET_STATE_FILE:-}" ]; then
    v=$(awk -F'\t' -v p="$p" -v i="$id" '$1 == p && $2 == i { print $3; exit }' \
      "$BUILDS_RETENTION_TICKET_STATE_FILE" 2>/dev/null)
    case "$v" in
      open|closed) printf '%s\n' "$v"; return 0 ;;
      ratelimited) return 75 ;;
    esac
    return 1
  fi
  command -v tracker_adapter >/dev/null 2>&1 || return 1
  local TRK_ADAPTER="" TRK_SLUG="" TRK_BOARD_BASE="" TRK_BOARD_TOKEN="" TRK_BOARD_TOKEN_VAR="" \
        TRK_LOG="" TRK_ERR="" TRK_DRY=0 TRK_REQ_FILE="" GH_REST_OPTIONAL=1
  ad=$(tracker_adapter "$p" 2>/dev/null) || return 1
  case "$ad" in
    github-issues)
      [[ $id =~ ^[0-9]+$ ]] || return 1
      TRK_SLUG=$("$r/bin/fleet-conf.sh" "$p" repo 2>/dev/null) || return 1
      ;;
    board) HARNESS="$r" tracker_context "$p" builds-retention 2>/dev/null || return 1 ;;
    *) return 1 ;;
  esac
  tracker_load "$ad" 2>/dev/null || return 1
  t=$(tracker_read "$id" 2>/dev/null) || rc=$?
  [ "$rc" = 75 ] && return 75
  [ "$rc" = 0 ] || return 1
  st=$(jq -r '.status // empty' <<<"$t" 2>/dev/null | tr '[:upper:]' '[:lower:]')
  case "$ad:$st" in
    *:) return 1 ;;
    github-issues:closed) printf 'closed\n' ;;
    board:done|board:closed|board:archived|board:cancelled|board:canceled) printf 'closed\n' ;;
    *) printf 'open\n' ;;
  esac
  return 0
}
