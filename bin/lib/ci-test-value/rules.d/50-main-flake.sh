#!/bin/bash
# bin/lib/ci-test-value/rules.d/50-main-flake.sh — rule group main flake F2. Owner: BH-6618.1.
#   F2.main-unrelated-green  a push run on main failed a tests/*.sh suite, and
#     the next green push run of the same workflow on main (the smallest run id
#     above the row's, created on the row's day or the next) is at a sha whose
#     commits since the red sha cannot reach that suite: the compare is
#     `ahead`, under GitHub's caps, and bin/test-impact.sh select over its
#     changed paths does not print the suite. Any doubt decides nothing: an
#     unread or 404 compare, a suite not in the map, a select that fails, or a
#     select whose reason line says CI would run the whole corpus (`full:`).
# Reads go through _ctv_rr_get (20-flake.sh). The impact map is built once per
# run into <out>/cache/impact-map-f2.tsv, stamped with the run id.

_CTV_F2_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)

# _ctv_f2_map — print the impact map path for this run; rc 1 when there is none.
# CTV_F2_IMPACT_MAP=<file> replaces it in the sandbox (HARNESS_TEST_SANDBOX=1) only.
_ctv_f2_map() {
  local d runid map stamp tmp
  if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [ -n "${CTV_F2_IMPACT_MAP:-}" ]; then
    [ -r "$CTV_F2_IMPACT_MAP" ] || return 1
    printf '%s\n' "$CTV_F2_IMPACT_MAP"; return 0
  fi
  d=$(_ctv_rr_dir) || return 1
  [ -e "$d/memo/f2-map-failed" ] && return 1
  runid=${d##*/}; map="$CTV_OUT/cache/impact-map-f2.tsv"; stamp="$CTV_OUT/cache/impact-map-f2.stamp"
  if [ -s "$map" ] && [ "$(cat "$stamp" 2>/dev/null)" = "$runid" ]; then printf '%s\n' "$map"; return 0; fi
  tmp="$map.tmp.$$"
  if mkdir -p "$CTV_OUT/cache" && "$_CTV_F2_ROOT/bin/test-impact.sh" map --out "$tmp" > /dev/null 2>&1 \
     && [ -s "$tmp" ] && mv -f "$tmp" "$map" && printf '%s\n' "$runid" > "$stamp"; then
    printf '%s\n' "$map"; return 0
  fi
  rm -f "$tmp"
  : > "$d/memo/f2-map-failed"
  return 1
}

ctv_rule_main_flake() {
  local R="${CTV_REPO:-}" sha="${CTV_HEAD_SHA:-}" W="${CTV_WORKFLOW_ID:-}" run="${CTV_RUN_ID:-}" day="${CTV_DAY:-}"
  local unit="${CTV_UNIT:-}" d f day2 pick gid gsha map n rc
  [ "${CTV_EVENT:-}" = push ] && [ "${CTV_HEAD_BRANCH:-}" = main ] && [ -n "${CTV_OUT:-}" ] \
    && [[ "$R" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] && [[ "$W" =~ ^[0-9]+$ ]] && [[ "$run" =~ ^[0-9]+$ ]] \
    && [[ "$sha" =~ ^[0-9a-f]{40}$ ]] && [[ "$day" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] \
    && [[ "$unit" =~ ^tests/(mc/)?[A-Za-z0-9._/-]+\.sh$ ]] && declare -F _ctv_rr_get > /dev/null || return 1
  day2=$(date -u -d "$day +1 day" +%F 2>/dev/null) || return 1
  d=$(_ctv_rr_dir) || return 1
  f="$d/f2.$BASHPID"
  # The next green push run of this workflow on main, at another sha.
  _ctv_rr_get "repos/$R/actions/workflows/$W/runs?branch=main&event=push&status=success&created=$day..$day2&per_page=100" \
    - "f2-green-$W-$day" > "$f.json" || { rm -f "$f.json"; return 1; }
  pick=$(jq -r --argjson w "$W" --argjson run "$run" --arg sha "$sha" '
    [.workflow_runs[]? | select(.id > $run and .workflow_id == $w and .head_branch == "main" and .event == "push"
      and .status == "completed" and .conclusion == "success" and .head_sha != $sha)] | sort_by(.id) | first // empty
    | "\(.id) \(.head_sha)"' "$f.json" 2>/dev/null)
  gid=${pick% *}; gsha=${pick#* }
  [[ "$gid" =~ ^[0-9]+$ ]] && [[ "$gsha" =~ ^[0-9a-f]{40}$ ]] || { rm -f "$f.json"; return 1; }
  # What changed between the red sha and the green sha.
  _ctv_rr_get "repos/$R/compare/$sha...$gsha" "f2/compare-$sha-$gsha.json" "f2-compare-$sha-$gsha" > "$f.json" \
    || { rm -f "$f.json"; return 1; }
  jq -e '.status == "ahead" and .behind_by == 0 and (.files | type) == "array" and (.files | length) < 300
    and (.total_commits | type) == "number" and .total_commits <= 250' "$f.json" > /dev/null 2>&1 || { rm -f "$f.json"; return 1; }
  jq -r '.files[] | .filename, (.previous_filename // empty)' "$f.json" > "$f.changed" 2>/dev/null || { rm -f "$f".*; return 1; }
  rm -f "$f.json"
  n=$(grep -c . "$f.changed")
  if grep -Fxq -e "$unit" "$f.changed"; then rm -f "$f".*; return 1; fi
  # The unit must be a suite the map knows, and the select must not print it.
  map=$(_ctv_f2_map) || { rm -f "$f".*; return 1; }
  if ! awk -F'\t' -v u="$unit" '$1 == u { found = 1; exit } END { exit !found }' "$map"; then rm -f "$f".*; return 1; fi
  rc=0
  # The `impact:` reason line goes to stderr.
  "$_CTV_F2_ROOT/bin/test-impact.sh" select --changed "$f.changed" --map-only --map "$map" > "$f.sel" 2> "$f.why" || rc=$?
  if [ "$rc" != 0 ] || grep -q 'full:' "$f.why" || grep -Fxq -e "$unit" "$f.sel"; then rm -f "$f".*; return 1; fi
  rm -f "$f".*
  printf 'flake\tF2.main-unrelated-green\tnext green push run %s at %s, %s changed path(s) do not reach %s\n' \
    "$gid" "${gsha:0:12}" "$n" "$unit"
  return 0
}
