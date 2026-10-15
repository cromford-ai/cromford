#!/bin/bash
# shellcheck shell=bash

# Thin wrappers over /api/conductor/held; every verb returns _jobs_req's rc verbatim.

# conductor_mode_publish <mode> <held-summary> — two settings rows, so readers use the 60s settings cache.
conductor_mode_publish() {
  local mode="${1:-}" summary="${2:-}" rc
  [ -n "$mode" ] || return 1
  setting_set merge-conductor.mode "$mode" "BH-1201: written by the conductor every tick"; rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  # Nothing held publishes "0" (setting_set refuses empty).
  summary="${summary:-0}"
  # Truncate to the 256-char column so the busiest tick is not refused.
  summary="${summary:0:256}"
  setting_set merge-conductor.held_pages "$summary"
}

# held_page_put <repo> <num> <state> <head> <kind> <text> <mark> <mode>
held_page_put() {
  local repo="${1:-}" num="${2:-}" state="${3:-}" head="${4:-}" kind="${5:-}" \
        text="${6:-}" mark="${7:-}" mode="${8:-}" body
  [ -n "$repo" ] && [ -n "$num" ] && [ -n "$state" ] && [ -n "$head" ] \
    && [ -n "$kind" ] && [ -n "$text" ] && [ -n "$mode" ] || return 1
  body=$(jq -nc --arg repo "$repo" --arg num "$num" --arg state "$state" \
    --arg head "$head" --arg kind "$kind" --arg text "$text" --arg mark "$mark" \
    --arg mode "$mode" \
    '{repo:$repo}
     + (if ($num|test("^[0-9]+$")) then {number:($num|tonumber)} else {number:$num} end)
     + {state:$state, head:$head, kind:$kind, text:$text, mode:$mode}
     + (if $mark == "" then {} else {mark:$mark} end)' 2>/dev/null) || return 1
  _jobs_req PUT /api/conductor/held "$body" >/dev/null
}

# held_pages_list [limit] — TSV, oldest first:
held_pages_list() {
  local limit="${1:-100}" resp rc rows
  resp=$(_jobs_req GET "/api/conductor/held?limit=$limit"); rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  # A non-JSON 200 is an outage, not an empty table.
  rows=$(printf '%s' "$resp" | jq -r '.rows[]? | [
    .repo, .number, .state, .head, .kind,
    (.text // ""),
    (.mark // ""), .mode, .first_held_at, .last_seen_at ] | @tsv' 2>/dev/null) || return 1
  [ -n "$rows" ] && printf '%s\n' "$rows"
  return 0
}

# held_pages_whole [limit] — held_pages_list's TSV, but only for a WHOLE list
# (BH-2361): rc 0 when the rows returned equal n_total (no output = nothing held),
# rc 3 truncated, rc 1 unparseable or no n_total, _jobs_req's rc otherwise.
held_pages_whole() {
  local limit="${1:-500}" resp rc rows
  resp=$(_jobs_req GET "/api/conductor/held?limit=$limit"); rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  printf '%s' "$resp" | jq -e '(.n_total|type) == "number" and (.rows|type) == "array"' >/dev/null 2>&1 || return 1
  printf '%s' "$resp" | jq -e '(.rows|length) == .n_total' >/dev/null 2>&1 || return 3
  rows=$(printf '%s' "$resp" | jq -r '.rows[] | [
    .repo, .number, .state, .head, .kind,
    (.text // ""),
    (.mark // ""), .mode, .first_held_at, .last_seen_at ] | @tsv' 2>/dev/null) || return 1
  [ -n "$rows" ] && printf '%s\n' "$rows"
  return 0
}

# held_page_release <repo> <num> <state> <head> <kind> <why>
held_page_release() {
  local repo="${1:-}" num="${2:-}" state="${3:-}" head="${4:-}" kind="${5:-}" \
        why="${6:-}" body resp rc out
  # why is required; refuse here since fail-open hides a 400.
  [ -n "$repo" ] && [ -n "$num" ] && [ -n "$state" ] && [ -n "$head" ] \
    && [ -n "$kind" ] && [ -n "$why" ] || return 1
  body=$(jq -nc --arg repo "$repo" --arg num "$num" --arg state "$state" \
    --arg head "$head" --arg kind "$kind" --arg why "$why" \
    '{repo:$repo}
     + (if ($num|test("^[0-9]+$")) then {number:($num|tonumber)} else {number:$num} end)
     + {state:$state, head:$head, kind:$kind, why:$why}' 2>/dev/null) || return 1
  resp=$(_jobs_req POST /api/conductor/held/release "$body"); rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  out=$(printf '%s' "$resp" | jq -r '.released // 0' 2>/dev/null) || return 1
  printf '%s\n' "$out"
}

# pr_attempt_batch <repo> <out-tsv> <covered-file> <n…> — the `pr_attempts`
#   rows of many PRs of one repo, one GET /api/conductor-state per 200 numbers
#   (BH-4156: the merge conductor's one attempt read per repo per tick).
#   Writes `<number>\t<kind>\t<sha>` lines to <out-tsv> in the route's order
#   (number ascending, newest first inside one number) and one COVERED number
#   per line to <covered-file>. Only a covered number is answered: a number the
#   route left out (its row cap) is not in the file, and its reader asks per PR.
#   A row whose kind or sha holds a tab or a line break cannot be a TSV field,
#   so its number is left out of <covered-file> too.
#   rc 0 every chunk answered | rc 2 the route answered 404 (a box synced before
#   the worker deploy), nothing written | rc 1 an outage or a 200 without the
#   `numbers` and `attempts` arrays, in some chunk: that chunk adds nothing,
#   and the chunks that did answer stay in the files.
pr_attempt_batch() {
  local repo="${1:-}" out="${2:-}" cov="${3:-}" n i q resp rc lines fail=0 answered=0 chunk
  local -a nums=()
  [ -n "$repo" ] && [ -n "$out" ] && [ -n "$cov" ] && [ $# -ge 4 ] || return 1
  shift 3
  for n in "$@"; do case "$n" in ''|*[!0-9]*) return 1 ;; esac; nums+=("$n"); done
  { : > "$out" && : > "$cov"; } 2>/dev/null || return 1
  for (( i = 0; i < ${#nums[@]}; i += 200 )); do
    chunk=$(printf '%s\n' ${nums[@]+"${nums[@]}"} | sed -n "$((i + 1)),$((i + 200))p" | paste -sd, -)
    q=$(jq -nr --arg r "$repo" --arg n "$chunk" '"repo="+($r|@uri)+"&numbers="+($n|@uri)') || return 1
    resp=$(_jobs_req GET "/api/conductor-state?$q"); rc=$?
    if [ "$rc" = 2 ] && [ "$answered" = 0 ]; then : > "$out"; : > "$cov"; return 2; fi
    [ "$rc" = 0 ] || { fail=1; continue; }
    # C = a covered number, A = a row, X = a number whose row cannot be a line.
    lines=$(printf '%s' "$resp" | jq -r '
      if (.numbers|type) == "array" and (.attempts|type) == "array"
         and all(.numbers[]; type == "number")
         and all(.attempts[]; (.number|type) == "number" and (.kind|type) == "string" and (.sha|type) == "string")
      then (.numbers[] | "C\t\(.)"),
           (.attempts[] | if (.kind + .sha | test("[\t\n\r]")) then "X\t\(.number)"
                          else "A\t\(.number)\t\(.kind)\t\(.sha)" end)
      else error("no arrays") end' 2>/dev/null) || { fail=1; continue; }
    answered=1
    printf '%s\n' "$lines" | awk -F'\t' -v out="$out" -v cov="$cov" '
      { l[NR] = $0; t[NR] = $1; num[NR] = $2 }
      $1 == "X" { bad[$2] = 1 }
      $1 == "C" { c[$2] = 1 }
      END {
        for (i = 1; i <= NR; i++) {
          if (t[i] == "A" && (num[i] in c) && !(num[i] in bad)) { s = l[i]; sub(/^A\t/, "", s); print s >> out }
          if (t[i] == "C" && !(num[i] in bad)) print num[i] >> cov
        }
      }'
  done
  [ "$fail" = 0 ] || return 1
  return 0
}
