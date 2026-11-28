#!/bin/bash
# shellcheck shell=bash
# bin/lib/merged-advance-key-pr.sh — THE KEY PR OF A TICKET (BH-10236). Sourced
# by bin/merged-ticket-advance.sh, never executed. Functions only, pure: no
# network, no file, no clock.
#
# WHY. project-3, 2026-11-26: TK-837, TK-834 and TK-852 showed `todo` while their
# work had been on main for 2 days (#1411, #1414, #1371). No fleet box built
# those PRs, and their addresses were not in the ticket threads. Each PR title
# starts with its ticket key: `TK-837: member Settings ...`.
#
# THE RULE. A merged PR whose title starts with `<KEY>`, then `:` or ` (`, is a
# PR of that ticket. A title that says slice, part <number or letter>,
# phase <n>, step <n> or <n> of <m> is ONE SLICE of the
# ticket: it never stands for the whole ticket. The key is matched whole and
# without case (TK-83 is not TK-837).
#
#   mka_key_prs   stdin: one page of GET pulls?state=closed (a JSON array).
#                 stdout: `<KEY>\t<number>\t<merged_at>\t<slice 0|1>` for each
#                 MERGED PR whose title starts with a key. A body that is not
#                 an array prints nothing and returns 1.
#   mka_moved_after <merged_at>   stdin: the ticket JSON of the board (GET
#                 tickets/<id>; its `activities` or `activity` rows, also under `.ticket`).
#                 rc 0 and the time on stdout when a `status_change` row is
#                 later than <merged_at>: a person or the app moved the ticket
#                 after the merge, so the lane must not move it again. rc 1
#                 = the rows were read and none is later. rc 2 = UNKNOWN: no
#                 `activities` array, a body that is not JSON, or a time that
#                 is not read. The caller must not move on rc 2.
#   mka_key_pick <KEY>   stdin: those rows. stdout: the number of the newest
#                 merged PR of <KEY> that is not a slice, or nothing.

mka_key_prs() {
  jq -r 'if type != "array" then error("not an array") else .[] end
    | select(type == "object" and (.merged_at // null) != null)
    | (.title // "" | tostring) as $t
    | ($t | capture("^(?<k>[A-Za-z][A-Za-z0-9]*-[0-9]+)(?<sep>:| \\()")? // null) as $c
    | select($c != null)
    | [ ($c.k | ascii_upcase), (.number | tostring), (.merged_at | tostring),
        (if ($t | test("\\bslice\\b|\\bpart ([0-9]+|[a-z])\\b|\\b(phase|step) [0-9]+\\b|\\b[0-9]+ of [0-9]+\\b"; "i")) then "1" else "0" end) ]
    | @tsv' 2>/dev/null
}

mka_key_pick() {
  local key
  key=$(printf '%s' "${1:-}" | tr '[:lower:]' '[:upper:]')
  [ -n "$key" ] || return 0
  awk -F'\t' -v k="$key" '$1 == k && $4 == "0" && $2 ~ /^[0-9]+$/ && ($3 > at || n == "") { at = $3; n = $2 } END { if (n != "") print n }'
}

mka_moved_after() {
  local out
  out=$(jq -r --arg m "${1:-}" '
    def ep: (tostring | sub("\\.[0-9]+Z$"; "Z") | try fromdateiso8601 catch null);
    ($m | ep) as $me
    | ([.activities?, .activity?, .ticket.activities?, .ticket.activity?] | map(select(type == "array")) | first // null) as $a
    | if $me == null or ($a | type) != "array" then "unknown" else
        [ $a[] | select(type == "object" and .type == "status_change") | {at: (.createdAt // ""), e: ((.createdAt // "") | ep)} ] as $r
        | if any($r[]; .e == null) then "unknown"
          else ([ $r[] | select(.e > $me) | .at ] | sort | last // "none") end
      end' 2>/dev/null) || out=unknown
  case "$out" in
    ''|unknown) return 2 ;;
    none) return 1 ;;
    *) printf '%s\n' "$out"; return 0 ;;
  esac
}
