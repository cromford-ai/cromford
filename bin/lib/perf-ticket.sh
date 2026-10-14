#!/bin/bash
# bin/lib/perf-ticket.sh — is a ticket a perf/cost ticket, and what target does
# it name (BH-6372). Sourced, or run as a CLI. The rule set is data:
# catalog/perf-ticket.tsv (its header has the format).
#
# pt_classify <ticket-file> <title> <labels-csv>
#   perf when (1) a label equals a `label` row, (2) the title or the body
#   matches a `phrase` row, or (3) the body has a `Target metric:` line or a
#   `## Target metric` heading. The first rule that hits prints
#   `perf <rule>:<evidence>`, rc 0. Else `no`, rc 1. A missing ticket file is an
#   empty body. An unreadable catalog prints nothing, rc 3 (unknown): a missing
#   rule set is never `no`.
# pt_classify_issue <repo> <n>
#   One gh_rest read of the issue, then pt_classify. On `no`, ONE parent hop:
#   the title `BH-<p>.<k>:`, else the first `Part of #<p>` in the body. The
#   parent gets rules 1-3 only, never a hop: `perf parent:#<p>`, rc 0. A failed
#   REST read or unreadable JSON on either issue is rc 3, never `no`.
# pt_parse_target <body-file>
#   Prints `<id> <from> <to>` from the first line `Target metric: <id> from <n>
#   to <n> [<unit>]` (id `^[a-z0-9][a-z0-9-]*$`, numbers verbatim), rc 0.
#   rc 1 when the file or a parseable line is absent.
# CLI: perf-ticket.sh classify-issue <repo> <n> | parse-target <file>
# shellcheck shell=bash

[ -n "${_PT_LIB_LOADED:-}" ] && return 0
_PT_LIB_LOADED=1
_PT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

pt_classify() {
  local f="${1:-}" title="${2:-}" cf kind val l m
  local -a labs=() phrs=() have=()
  cf="${PERF_TICKET_CATALOG:-$_PT_DIR/../../catalog/perf-ticket.tsv}"
  [ -r "$cf" ] || { echo "perf-ticket: unknown (catalog $cf unreadable)" >&2; return 3; }
  while IFS=$'\t' read -r kind val _; do
    case "$kind" in
      label) labs+=("${val,,}") ;;
      phrase) phrs+=("$val") ;;
    esac
  done < "$cf"
  [ -r "$f" ] || f=/dev/null
  IFS=, read -ra have <<< "${3:-}"
  for l in "${have[@]}"; do
    l="${l#"${l%%[![:space:]]*}"}"; l="${l%"${l##*[![:space:]]}"}"; l="${l,,}"
    for val in "${labs[@]}"; do [ -n "$l" ] && [ "$l" = "$val" ] && { echo "perf label:$l"; return 0; }; done
  done
  for val in "${phrs[@]}"; do
    m=$({ printf '%s\n' "$title"; cat -- "$f"; } | grep -oiE -- "$val" | head -1)
    [ -n "$m" ] && { m="${m,,}"; echo "perf phrase:${m//[[:space:]]/_}"; return 0; }
  done
  grep -qiE '^[[:space:]]*target metric:' "$f" && { echo "perf target:line"; return 0; }
  grep -qiE '^##[[:space:]]+target metric' "$f" && { echo "perf target:heading"; return 0; }
  echo no; return 1
}

# _pt_read <repo> <n> <dir> — the issue's title, body and labels CSV into
# <dir>/t, <dir>/b, <dir>/l. rc 3 on any failure.
_pt_read() {
  gh_rest GET "repos/$1/issues/$2" > "$3/j" || { echo "perf-ticket: unknown (#$2 HTTP $GH_REST_STATUS $GH_REST_REASON)" >&2; return 3; }
  jq -r '.title // ""' "$3/j" > "$3/t" 2>/dev/null && jq -r '.body // ""' "$3/j" > "$3/b" 2>/dev/null \
    && jq -r '[.labels[]?.name] | join(",")' "$3/j" > "$3/l" 2>/dev/null \
    || { echo "perf-ticket: unknown (#$2 unreadable JSON)" >&2; return 3; }
}

_pt_issue_in() { # _pt_issue_in <repo> <n> <dir>
  local d="$3" out rc t p=""
  _pt_read "$1" "$2" "$d" || return 3
  t=$(cat "$d/t")
  out=$(pt_classify "$d/b" "$t" "$(cat "$d/l")"); rc=$?
  [ "$rc" = 1 ] || { [ -n "$out" ] && echo "$out"; return "$rc"; }
  if [[ $t =~ ^BH-([0-9]+)\.[0-9]+: ]]; then p="${BASH_REMATCH[1]}"
  else p=$(grep -oiE 'part of #[0-9]+' "$d/b" | head -1 | grep -oE '[0-9]+$'); fi
  [ -n "$p" ] && [ "$p" != "$2" ] || { echo no; return 1; }
  _pt_read "$1" "$p" "$d" || return 3
  out=$(pt_classify "$d/b" "$(cat "$d/t")" "$(cat "$d/l")"); rc=$?
  case "$rc" in
    0) echo "perf parent:#$p"; return 0 ;;
    1) echo no; return 1 ;;
  esac
  return 3
}

pt_classify_issue() {
  local d rc
  declare -F gh_rest >/dev/null || . "$_PT_DIR/gh-rest.sh" || return 3
  d=$(mktemp -d) || return 3
  _pt_issue_in "${1:-}" "${2:-}" "$d"; rc=$?
  rm -rf "$d"
  return "$rc"
}

pt_parse_target() {
  local re='^[[:space:]]*(- )?Target metric:[[:space:]]*([a-z0-9][a-z0-9-]*)[[:space:]]+from[[:space:]]+(-?[0-9]+(\.[0-9]+)?)[[:space:]]+to[[:space:]]+(-?[0-9]+(\.[0-9]+)?)([[:space:]]+[^[:space:]].*)?[[:space:]]*$' line
  [ -r "${1:-}" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    [[ $line =~ $re ]] && { echo "${BASH_REMATCH[2]} ${BASH_REMATCH[3]} ${BASH_REMATCH[5]}"; return 0; }
  done < "$1"
  return 1
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}:$#" in
    classify-issue:3) pt_classify_issue "$2" "$3"; exit $? ;;
    parse-target:2) pt_parse_target "$2"; exit $? ;;
  esac
  echo "usage: perf-ticket.sh classify-issue <repo> <n> | parse-target <file>" >&2
  exit 2
fi
