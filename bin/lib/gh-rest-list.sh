#!/bin/bash
# bin/lib/gh-rest-list.sh — paged REST LIST reads, on top of bin/lib/gh-rest.sh.
# Sourced, never executed.
#
# WHY A SECOND FILE AND NOT THREE MORE FUNCTIONS IN gh-rest.sh. That file is a
# CONTRACT: the three exit codes, the status variables, one `gh api` at one
# command position, and tests/gh-rest-lib-test.sh holds it to its contract
# functions (a code-line ceiling until BH-5228) so the next caller-conversion cannot quietly grow a
# contract file into a lane. These list readers are a lane's worth of code
# (paging, a jq shape filter, a row cap), so they live next to it instead of
# inside it. Sourcing this file sources gh-rest.sh, so a caller needs one line.
#
# WHY THEY EXIST (BH-1163). gh_rest_pr_list answers ONE page and is frozen —
# #781..#784 read it that way. The lanes BH-1163 converts each replace a
# `gh … list --limit 200`, and REST caps per_page at 100, so a one-page helper
# would silently halve the board they reconcile.
#
# A PARTIAL LIST IS NEVER RETURNED AS FACT. If any page answers 44 or 75 the
# whole read carries that rc and prints nothing: half a board read as the board
# is the #768 bug with a longer fuse. An empty `[]` under rc 0 stays what
# gh-rest.sh's header says it is — a real "nothing there".
#
# gh-rest: no-graphql
#
# No `set -e`, no `exit`, no side effect at source time, and every fallible call
# is `cmd || rc=$?` — the same rules gh-rest.sh states and for the same reason.
if [ -n "${GH_REST_LIST_LIB:-}" ]; then return 0 2>/dev/null; fi
GH_REST_LIST_LIB=1
# shellcheck source=bin/lib/gh-rest.sh
if ! command -v gh_rest >/dev/null 2>&1; then
  . "$(dirname "${BASH_SOURCE[0]}")/gh-rest.sh" 2>/dev/null || return 0 2>/dev/null
fi

_gh_rest_list() { # _gh_rest_list <slug> <sub> <max> <jq filter> [extra -f/-F args...]
  local slug="$1" sub="$2" max="$3" filt="$4" page=1 rc=0 n=0 have=0 raw acc merged
  shift 4
  case "$max" in ''|*[!0-9]*) _gh_rest_bad_args; return 75 ;; esac
  raw=$(mktemp "${TMPDIR:-/tmp}/gh-rest.XXXXXX") || return 75
  acc=$(mktemp "${TMPDIR:-/tmp}/gh-rest.XXXXXX") || { rm -f "$raw"; return 75; }
  printf '[]' > "$acc"
  # Ten pages is 1000 rows and a hard stop: a `Link: next` that never ends
  # (a proxy, a mirrored API) must not become an unbounded spend.
  while [ "$page" -le 10 ]; do
    rc=0
    # A plain command with `> file`, never `$( )`: the status this read produced
    # has to still be in the CALLER's shell when the caller alerts (see header).
    gh_rest GET "repos/$slug/$sub" "$@" -F per_page=100 -F "page=$page" > "$raw" || rc=$?
    if [ "$rc" != 0 ]; then rm -f "$raw" "$acc"; return "$rc"; fi
    rc=0
    n=$(jq 'if type=="array" then length else -1 end' "$raw" 2>/dev/null) || rc=$?
    # A 2xx body that is not an array is not an empty list, it is an answer
    # nobody can act on.
    if [ "$rc" != 0 ] || [ -z "$n" ] || [ "$n" = -1 ]; then
      rm -f "$raw" "$acc"; GH_REST_REASON=empty; return 75
    fi
    rc=0
    # Slurped from two FILES, never through --argjson: a 200-issue page with
    # bodies is megabytes, and argv is not where megabytes go.
    merged=$(jq -c -s ".[0] + ([.[1][] | $filt] | map(select(. != null)))" "$acc" "$raw" 2>/dev/null) || rc=$?
    if [ "$rc" != 0 ] || [ -z "$merged" ]; then
      rm -f "$raw" "$acc"; GH_REST_REASON=empty; return 75
    fi
    printf '%s' "$merged" > "$acc"
    if [ "$n" -lt 100 ]; then break; fi
    have=$(jq 'length' "$acc" 2>/dev/null) || have=0
    case "$have" in ''|*[!0-9]*) have=0 ;; esac
    if [ "$have" -ge "$max" ]; then break; fi
    page=$((page+1))
  done
  rm -f "$raw"
  rc=0
  merged=$(jq -c ".[:$max]" "$acc" 2>/dev/null) || rc=$?
  rm -f "$acc"
  if [ "$rc" != 0 ] || [ -z "$merged" ]; then GH_REST_REASON=empty; return 75; fi
  printf '%s\n' "$merged"
  return 0
}

# THE `.pull_request` FILTER IS NOT COSMETIC. GET /repos/{slug}/issues returns
# pull requests as issues; `gh issue list` did not. A lane that reconciles
# TICKETS would otherwise read its own PRs as tickets with no owner.
gh_rest_issue_list() { # gh_rest_issue_list <slug> <state> [label] [max]
  local -a a
  if ! _gh_rest_args_ok "${1:-}" || [ -z "${2:-}" ]; then _gh_rest_bad_args; return 75; fi
  a=(-f "state=$2")
  if [ -n "${3:-}" ]; then a+=(-f "labels=$3"); fi
  _gh_rest_list "$1" issues "${4:-200}" 'select(.pull_request == null)' "${a[@]}"
}

gh_rest_pr_list_all() { # gh_rest_pr_list_all <slug> <state> [max]
  if ! _gh_rest_args_ok "${1:-}" || [ -z "${2:-}" ]; then _gh_rest_bad_args; return 75; fi
  _gh_rest_list "$1" pulls "${3:-200}" '.' -f "state=$2"
}

gh_rest_issue_comments() { # gh_rest_issue_comments <slug> <num> [max]
  if ! _gh_rest_args_ok "${1:-}" "${2:-}"; then _gh_rest_bad_args; return 75; fi
  _gh_rest_list "$1" "issues/$2/comments" "${3:-200}" '.'
}

# The label, review-request and close events of an issue or a PR, oldest first
# (BH-10201: who put a label on and who took it off).
gh_rest_issue_events() { # gh_rest_issue_events <slug> <num> [max]
  if ! _gh_rest_args_ok "${1:-}" "${2:-}"; then _gh_rest_bad_args; return 75; fi
  _gh_rest_list "$1" "issues/$2/events" "${3:-200}" '.'
}
