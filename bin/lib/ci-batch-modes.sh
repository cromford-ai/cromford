#!/bin/bash
# bin/lib/ci-batch-modes.sh — merge-queue batches per UTC day, full mode vs
# batch-selected, read from the answer of GET /api/ci-batches. Sourced by
# bin/pipeline-health.sh. Pure: no network, no files, no harness root.
#
# #6371 found 12 of 13 batches ran the whole corpus after #5454, and nothing
# counted it. This is the count. It is a measurement only: nobody has decided
# what full share is too high, so it never pages.
#
# ci_batch_modes_eval <ci-batches-json> <since YYYY-MM-DD> <today YYYY-MM-DD>
#   stdout, one line, every UTC day from since to today, oldest first:
#     <day> full F selected S other O  [two spaces]  <day> ...  total full F selected S other O
#   A day with no batches prints zeros. The day is the first 10 chars of
#   completed_at; a row outside [since, today] or with no completed_at is not
#   counted. mode "full" is full, "batch-selected" is selected, any other mode
#   (full-legacy, null) is other.
#   rc 0 on a parsed answer, also with no rows. rc 2 when the answer says
#   truncated: a partial count is never printed. rc 1 on bad arguments, no jq,
#   or an answer that is not an object with a rows array.
ci_batch_modes_eval() {
  local j="${1:-}" since="${2:-}" today="${3:-}" re='^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
  [[ $since =~ $re && $today =~ $re ]] || return 1
  [[ ! $since > $today ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  local out rc
  out=$(printf '%s' "$j" | jq -r --arg since "$since" --arg today "$today" '
    if type == "object" and (.rows | type) == "array" then . else error("not a ci-batches list") end
    | if .truncated == true then "TRUNCATED" else
        ($since | strptime("%Y-%m-%d") | mktime) as $s
        | ($today | strptime("%Y-%m-%d") | mktime) as $t
        | [ range($s; $t + 1; 86400) | strftime("%Y-%m-%d") ] as $days
        | (reduce $days[] as $d ({}; .[$d] = {f: 0, s: 0, o: 0})) as $zero
        | (reduce (.rows[] | select(type == "object")) as $r ($zero;
            ((($r.completed_at // "") | tostring)[0:10]) as $d
            | if has($d) then
                (if $r.mode == "full" then "f" elif $r.mode == "batch-selected" then "s" else "o" end) as $b
                | .[$d][$b] += 1
              else . end)) as $c
        | ([ $days[] | "\(.) full \($c[.].f) selected \($c[.].s) other \($c[.].o)" ]
           + [ "total full \([$c[].f] | add) selected \([$c[].s] | add) other \([$c[].o] | add)" ])
        | join("  ")
      end
  ' 2>/dev/null); rc=$?
  [ "$rc" = 0 ] && [ -n "$out" ] || return 1
  [ "$out" = TRUNCATED ] && return 2
  printf '%s\n' "$out"
}
