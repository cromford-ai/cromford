#!/bin/bash
# bin/lib/ci-test-value/followup.sh — the shared reads and predicates of the
# order, follow-up and batch-fix rules (rules.d/30, 40, 60). Owner: BH-6618.2.
# Sourced by those three rule files only, never run.
#
#   ctv_followup_files <red_head> <red_base> <green_head> <green_base>
#       The follow-up set: the paths of compare(red_head...green_head) minus the
#       paths of compare(red_base...green_base), one per line, sorted. rc 0 with
#       no output is a rebase only. rc 1 when a sha is bad or a compare is
#       unread, 404, or at GitHub's caps (300 files, 250 commits): not decided,
#       never an empty set.
#   ctv_reaches <unit> <path...>
#       rc 0 a `select --why` row names the unit with a kind other than
#       `always` or `full`; rc 1 no such row; rc 2 cannot tell (no map, the
#       unit is not a suite of the map, the select failed, or a path has no
#       known reach and no row names the unit).
#
# Every GitHub read goes through _ctv_rr_get (rules.d/20-flake.sh), so it is in
# the rule read ledger. Only a compare of two fixed shas goes to <out>/cache/.

[ -n "${_CTV_FOLLOWUP_SH:-}" ] && return 0
_CTV_FOLLOWUP_SH=1

_CTV_FU_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
# shellcheck source=bin/lib/dequeue-watch/attribute.sh
. "$_CTV_FU_ROOT/bin/lib/dequeue-watch/attribute.sh"

_ctv_fu_sha() { [[ "${1:-}" =~ ^[0-9a-f]{40}$ ]]; }

# A test path is a path under tests/ or catalog/fixtures/.
_ctv_fu_is_test_path() {
  case "${1:-}" in tests/*|catalog/fixtures/*) return 0 ;; esac
  return 1
}

# A batch row: the driver's merge_group / gh-readonly-queue flag, or a Mergify
# merge queue draft branch (this repo batches through Mergify).
_ctv_fu_is_batch() {
  [ "${CTV_IS_BATCH:-0}" = 1 ] || [[ "${CTV_HEAD_BRANCH:-}" == mergify/merge-queue/* ]]
}

# _ctv_fu_ready — the row vars every rule here needs, and the read helper.
_ctv_fu_ready() {
  [ -n "${CTV_OUT:-}" ] && [[ "${CTV_REPO:-}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
    && [[ "${CTV_WORKFLOW_ID:-}" =~ ^[0-9]+$ ]] && [[ "${CTV_RUN_ID:-}" =~ ^[0-9]+$ ]] && [ -n "${CTV_UNIT:-}" ] \
    && declare -F _ctv_rr_get > /dev/null
}

# _ctv_fu_members — the batch members (`#N` in the row's title), sorted, one per
# line. rc 1 when the title names no PR. No read.
_ctv_fu_members() {
  local d f rc=0
  d=$(_ctv_rr_dir) || return 1
  f="$d/fu-title.$BASHPID.json"
  jq -n --argjson id "${CTV_RUN_ID:-0}" --arg t "${CTV_DISPLAY_TITLE:-}" \
    '{workflow_runs: [{id: $id, display_title: $t}]}' > "$f" 2>/dev/null || { rm -f "$f"; return 1; }
  dqw_batch_members "$f" "$CTV_RUN_ID" || rc=1
  rm -f "$f"
  return "$rc"
}

# _ctv_fu_compare_files <a> <b> <out-file> — the file names (and previous
# names) of compare(a...b), sorted, into <out-file>. rc 1 unread, 404 or capped.
_ctv_fu_compare_files() {
  local a="$1" b="$2" out="$3"
  _ctv_rr_get "repos/$CTV_REPO/compare/$a...$b" "fu/compare-$a-$b.json" "fu-compare-$a-$b" > "$out.json" \
    || { rm -f "$out.json"; return 1; }
  if ! jq -e '(.files | type) == "array" and (.files | length) < 300
      and (.total_commits | type) == "number" and .total_commits <= 250' "$out.json" > /dev/null 2>&1; then
    rm -f "$out.json"; return 1
  fi
  jq -r '.files[] | .filename, (.previous_filename // empty)' "$out.json" 2>/dev/null | LC_ALL=C sort -u > "$out" \
    || { rm -f "$out.json" "$out"; return 1; }
  rm -f "$out.json"
}

ctv_followup_files() {
  local rh="${1:-}" rb="${2:-}" gh="${3:-}" gb="${4:-}" d f
  _ctv_fu_sha "$rh" && _ctv_fu_sha "$rb" && _ctv_fu_sha "$gh" && _ctv_fu_sha "$gb" || return 1
  [ -n "${CTV_OUT:-}" ] && [[ "${CTV_REPO:-}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
    && declare -F _ctv_rr_get > /dev/null || return 1
  d=$(_ctv_rr_dir) || return 1
  f="$d/fu-set.$BASHPID"
  _ctv_fu_compare_files "$rh" "$gh" "$f.a" || { rm -f "$f".*; return 1; }
  if [ "$rb" = "$gb" ]; then
    : > "$f.b"
  else
    _ctv_fu_compare_files "$rb" "$gb" "$f.b" || { rm -f "$f".*; return 1; }
  fi
  LC_ALL=C comm -23 "$f.a" "$f.b"
  rm -f "$f".*
  return 0
}

# _ctv_fu_map — print the impact map path for this run; rc 1 when there is none.
# Built once per run into <out>/cache/impact-map.tsv, stamped with the run id.
# CTV_IMPACT_MAP=<file> replaces it in the sandbox (HARNESS_TEST_SANDBOX=1) only.
_ctv_fu_map() {
  local d runid map stamp tmp
  if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [ -n "${CTV_IMPACT_MAP:-}" ]; then
    [ -r "$CTV_IMPACT_MAP" ] || return 1
    printf '%s\n' "$CTV_IMPACT_MAP"; return 0
  fi
  d=$(_ctv_rr_dir) || return 1
  [ -e "$d/memo/fu-map-failed" ] && return 1
  runid=${d##*/}; map="$CTV_OUT/cache/impact-map.tsv"; stamp="$CTV_OUT/cache/impact-map.stamp"
  if [ -s "$map" ] && [ "$(cat "$stamp" 2>/dev/null)" = "$runid" ]; then printf '%s\n' "$map"; return 0; fi
  tmp="$map.tmp.$$"
  if mkdir -p "$CTV_OUT/cache" && "$_CTV_FU_ROOT/bin/test-impact.sh" map --out "$tmp" > /dev/null 2>&1 \
     && [ -s "$tmp" ] && mv -f "$tmp" "$map" && printf '%s\n' "$runid" > "$stamp"; then
    printf '%s\n' "$map"; return 0
  fi
  rm -f "$tmp"
  : > "$d/memo/fu-map-failed"
  return 1
}

ctv_reaches() {
  local unit="${1:-}" map d f rc=0
  shift || return 2
  [ -n "$unit" ] && [ $# -gt 0 ] && [ -n "${CTV_OUT:-}" ] || return 2
  map=$(_ctv_fu_map) || return 2
  awk -F'\t' -v u="$unit" '$1 == u { found = 1; exit } END { exit !found }' "$map" || return 2
  d=$(_ctv_rr_dir) || return 2
  f="$d/fu-reach.$BASHPID"
  printf '%s\n' "$@" > "$f.changed"
  # The `impact:` reason line goes to stderr.
  "$_CTV_FU_ROOT/bin/test-impact.sh" select --changed "$f.changed" --map-only --map "$map" --why \
    > "$f.why" 2> "$f.err" || rc=$?
  if [ "$rc" != 0 ]; then rm -f "$f".*; return 2; fi
  if awk -F'\t' -v u="$unit" '$1 == u && $2 != "always" && $2 != "full" { found = 1; exit } END { exit !found }' "$f.why"; then
    rc=0
  elif grep -q 'full:' "$f.err"; then
    rc=2
  else
    rc=1
  fi
  rm -f "$f".*
  return "$rc"
}

# _ctv_fu_pr_files <n> — `status\tfilename` rows of pulls/<n>/files, plus a
# `renamed-from\t<previous_filename>` row for a rename. Pages 1 to 3; a third
# full page is rc 1 (too large to decide), as is any unread page.
_ctv_fu_pr_files() {
  local n="${1:-}" p d f c
  [[ "$n" =~ ^[0-9]+$ ]] || return 1
  d=$(_ctv_rr_dir) || return 1
  f="$d/fu-prf.$BASHPID.json"
  for p in 1 2 3; do
    _ctv_rr_get "repos/$CTV_REPO/pulls/$n/files?per_page=100&page=$p" - "fu-pr-$n-files-p$p" > "$f" || { rm -f "$f"; return 1; }
    c=$(jq -er 'if type == "array" then length else error("not a list") end' "$f" 2>/dev/null) || { rm -f "$f"; return 1; }
    jq -r '.[] | "\(.status)\t\(.filename)", (.previous_filename // empty | "renamed-from\t\(.)")' "$f" 2>/dev/null \
      || { rm -f "$f"; return 1; }
    if [ "$c" -lt 100 ]; then rm -f "$f"; return 0; fi
  done
  rm -f "$f"
  return 1
}

# _ctv_fu_pull <n> <out-file> — pulls/<n> into <out-file>. Memo only: an open
# PR can still change.
_ctv_fu_pull() {
  [[ "${1:-}" =~ ^[0-9]+$ ]] || return 1
  _ctv_rr_get "repos/$CTV_REPO/pulls/$1" - "fu-pull-$1" > "$2" || { rm -f "$2"; return 1; }
}

# _ctv_fu_branch_runs <W> <branch> <out-file> — the pull_request runs of one
# workflow on one branch, latest 100. Memo only.
_ctv_fu_branch_runs() {
  local w="${1:-}" b="${2:-}" out="${3:-}" key
  [[ "$w" =~ ^[0-9]+$ ]] && [[ "$b" =~ ^[A-Za-z0-9._/-]+$ ]] && [ -n "$out" ] || return 1
  key=$(printf '%s' "$b" | md5sum | cut -c1-16)
  _ctv_rr_get "repos/$CTV_REPO/actions/workflows/$w/runs?branch=$b&event=pull_request&per_page=100" - \
    "fu-br-$w-$key" > "$out" || { rm -f "$out"; return 1; }
}

# _ctv_fu_next_green <runs-file> <W> <after_run_id> <not_sha> <pr> — prints
# `id head_sha base_sha` of the smallest run id above <after_run_id> of that
# workflow that is completed, success, on another head than <not_sha>, and
# lists <pr> in pull_requests. rc 1 when there is none.
_ctv_fu_next_green() {
  local out id hs bs
  out=$(jq -r --argjson w "${2:-0}" --argjson after "${3:-0}" --arg not "${4:-}" --argjson pr "${5:-0}" '
    [.workflow_runs[]? | select(.id > $after and .workflow_id == $w and .status == "completed"
      and .conclusion == "success" and .head_sha != $not and any(.pull_requests[]?; .number == $pr))]
    | sort_by(.id) | first // empty
    | "\(.id) \(.head_sha) \([.pull_requests[] | select(.number == $pr) | .base.sha][0] // "")"' "${1:-}" 2>/dev/null) || return 1
  read -r id hs bs <<<"$out"
  [[ "$id" =~ ^[0-9]+$ ]] && _ctv_fu_sha "$hs" && _ctv_fu_sha "$bs" || return 1
  printf '%s %s %s\n' "$id" "$hs" "$bs"
}

# _ctv_fu_first3 <file> — the first three lines, space-joined.
_ctv_fu_first3() { awk 'NR <= 3 { printf "%s%s", (NR > 1 ? " " : ""), $0 }' "$1"; }

# _ctv_fu_code_paths <file> — the lines of <file> that are not test paths.
_ctv_fu_code_paths() {
  local p
  while IFS= read -r p; do
    [ -n "$p" ] && ! _ctv_fu_is_test_path "$p" && printf '%s\n' "$p"
  done < "$1"
  return 0
}
