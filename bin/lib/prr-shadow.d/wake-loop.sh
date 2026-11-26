#!/bin/bash
# bin/lib/prr-shadow.d/wake-loop.sh — the prr-shadow seam of lane wake-loop
# (BH-9926 wave 6, BH-9938). Sourced by prr_seam_load wake-loop
# (bin/lib/prr-shadow.sh), never executed. The pr-lead wake class
# (bin/lib/wake-class-pr-lead.sh) runs inside this lane, so its one GitHub read
# moves under this lane id: the step row is lane.wake-loop.gh_source.
#
#   wl_pr_record <file> <owner/repo> <n>
#       The PR from the PR record: pr_record_peek (ONE jobs GET, never a
#       GitHub call). A hit needs all of: age_s is a whole number and
#       <= pr_record_max_age; `state` is a string; `draft` is a boolean or the
#       worker's stored INTEGER 0/1; `head_sha` is 40 hex. It writes
#       {"state":..,"draft":<boolean>,"head":{"sha":..}}, the subset of the
#       REST pulls object the class reads. A record state `merged` is written
#       `closed`, the REST state of a merged PR. rc 0, nothing on stdout.
#       A miss prints one word and returns 1, with <file> empty:
#         off          pr_record_max_age is 0 (no request at all)
#         unreadable   no pr-record lib, or pr_record_peek rc 1. Peek's rc does
#                      not tell a failed read from no row; its own
#                      logs/pr-record.log line `peek <repo>#<n>
#                      miss=<unreadable|unknown>` does.
#         stale        age_s is not a whole number, or is over the knob
#         field:state | field:draft | field:head_sha   that field fails its check
#
#   wl_pr_github <file> <owner/repo> <n>
#       Today's read, moved verbatim: gh_rest_var GET repos/<slug>/pulls/<n>.
#       The body goes to <file>; the rc is gh_rest_var's (75 when gh_rest_var
#       is not defined). GH_REST_STATUS reaches the caller.
#
#   wl_pr_norm <file>
#       The compare form: [{n:"pr", state, draft, head}], head the lowercased
#       .head.sha and draft (.draft // false), as the class reads them.
if ! command -v pr_record_peek >/dev/null 2>&1 && [ -r "${BASH_SOURCE[0]%/*}/../pr-record.sh" ]; then
  # shellcheck source=bin/lib/pr-record.sh
  . "${BASH_SOURCE[0]%/*}/../pr-record.sh"
fi
if ! declare -F gh_rest_var >/dev/null 2>&1 && [ -r "${BASH_SOURCE[0]%/*}/../gh-rest.sh" ]; then
  # shellcheck source=bin/lib/gh-rest.sh
  . "${BASH_SOURCE[0]%/*}/../gh-rest.sh" 2>/dev/null || true
fi

wl_pr_record() {
  local f="${1:-}" slug="${2:-}" n="${3:-}" max row age sha
  [ -n "$f" ] || return 2
  : > "$f" 2>/dev/null || { echo unreadable; return 1; }
  if ! command -v pr_record_peek >/dev/null 2>&1 || ! command -v pr_record_max_age >/dev/null 2>&1; then
    echo unreadable; return 1
  fi
  max=$(pr_record_max_age)
  [[ "$max" =~ ^[0-9]+$ ]] || { echo unreadable; return 1; }
  [ "$max" != 0 ] || { echo off; return 1; }
  row=$(pr_record_peek "$slug" "$n") || { echo unreadable; return 1; }
  age=$(jq -r '.age_s | numbers' <<<"$row" 2>/dev/null)
  if ! [[ "$age" =~ ^[0-9]{1,12}$ ]] || [ "$age" -gt "$max" ]; then echo stale; return 1; fi
  jq -e '(.state | type) == "string"' <<<"$row" >/dev/null 2>&1 || { echo field:state; return 1; }
  jq -e '(.draft | type) == "boolean" or .draft == 0 or .draft == 1' <<<"$row" >/dev/null 2>&1 \
    || { echo field:draft; return 1; }
  sha=$(jq -r '.head_sha | strings' <<<"$row" 2>/dev/null)
  [[ "$sha" =~ ^[0-9a-fA-F]{40}$ ]] || { echo field:head_sha; return 1; }
  if ! jq -c '{state: (if .state == "merged" then "closed" else .state end),
               draft: (.draft == true or .draft == 1), head: {sha: .head_sha}}' <<<"$row" > "$f" 2>/dev/null \
     || ! [ -s "$f" ]; then
    : > "$f"; echo unreadable; return 1
  fi
  return 0
}

wl_pr_github() {
  local f="${1:-}" slug="${2:-}" n="${3:-}" wl_body="" rc=0
  [ -n "$f" ] || return 2
  if ! declare -F gh_rest_var >/dev/null 2>&1; then : > "$f"; return 75; fi
  # gh_rest_var, never $(gh_rest ...): a command substitution drops the
  # GH_REST_STATUS the helper sets (gh-rest-no-subshell-lint).
  gh_rest_var wl_body GET "repos/$slug/pulls/$n" || rc=$?
  printf '%s' "$wl_body" > "$f"
  return "$rc"
}

wl_pr_norm() {
  jq -c '[{n: "pr", state: (.state // ""), draft: (.draft // false),
           head: ((.head.sha // "") | ascii_downcase)}]' "${1:-}" 2>/dev/null
}
