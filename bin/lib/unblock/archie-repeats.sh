#!/bin/bash
# shellcheck shell=bash
# bin/lib/unblock/archie-repeats.sh — BH-8817: the rule miner's read of
# Archie's card answers. Sourced by bin/rule-miner.sh (source (g)) and the
# suite; nothing here runs on source.
#
#   uar_list <since-iso> <min> <limit>
#     GET /api/unblock/cards/repeats?since=&min=&limit= (one aggregate over
#     the unblock_decisions rows with answer_source='archie'). One TSV line per
#     group on stdout, most first:
#       <project> <stall_class|-> <answer> <lever|-> <n> <last_id>
#     A tab or a newline inside a field is a space. rc 1 = no _jobs_req, bad
#     input, or the read failed or did not answer {repeats: [...]}: the caller
#     mines nothing from this source and says so.
#
# WHY. Archie answers the same kind of card the same way again and again. A
# group that crosses the miner's threshold is a candidate rule for
# catalog/unblock-rules.d: Tackler then decides that stall itself, with no
# card and no model call.
# gh-rest: no-graphql

uar_list() {
  local since="${1:-}" min="${2:-}" limit="${3:-}" body
  [[ $since =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 1
  [[ $min =~ ^[0-9]{1,3}$ ]] && [[ $limit =~ ^[0-9]{1,3}$ ]] || return 1
  declare -F _jobs_req >/dev/null || return 1
  body=$(_jobs_req GET "/api/unblock/cards/repeats?since=$since&min=$min&limit=$limit") || return 1
  jq -e '(.repeats | type) == "array"' >/dev/null 2>&1 <<<"$body" || return 1
  jq -r '.repeats[] | [(.project // "-"), (.stall_class // "-"), (.answer // "-"),
      (if (.lever // "") == "" then "-" else .lever end), (.n | tostring), (.last_id | tostring)]
    | map(tostring | gsub("[\t\r\n]+"; " ")) | @tsv' <<<"$body"
}
