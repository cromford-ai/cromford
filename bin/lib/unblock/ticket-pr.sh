#!/bin/bash
# shellcheck shell=bash
# bin/lib/unblock/ticket-pr.sh — the unblock tick's ticket PR resolve
# (BH-9446). Sourced by bin/unblock.sh, never run. On source it only loads
# bin/lib/unblock/prr.sh (functions only) and defines functions.
#
# WHY. A ticket-subject record (the infra reach and starve records, the
# lifecycle records) did not know the ticket's open PR. Its has_pr was null
# and its head empty, so a PR lever (fix_round, re_review) did "not fit" and
# the card went to the operator while the PR was open (BH-9335 and PR #9372).
#
#   ub_ticket_pr_enrich <project> <repo>  < records.jsonl  > records.jsonl
#     Run it in the tick's shell with redirects (not in a pipe), so the
#     per-tick memo stays. Every line comes out, in order. Per line:
#       - not JSON, not a ticket subject, or has_pr false: unchanged.
#         A ticket subject is ticket:<project>:<KEY>, or <project>:<KEY> with
#         <project> the record's project; KEY matches UB_TICKET_RE (act.sh).
#       - a numeric pr, a 40-hex head and pr_state "open" (or has_pr already
#         true): has_pr true, no read.
#       - else _ubt_pr_resolve, once per ticket and repo per call:
#           found  pr, head, pr_url, pr_source (ledger|rest), has_pr true,
#                  has_pr out of unknown. A record whose own pr is another
#                  number keeps its pr and head, and is not changed.
#           none   has_pr false, has_pr out of unknown.
#           unread has_pr null, has_pr in unknown (once).
#     rc 0 always.
#
#   _ubt_pr_resolve <project> <repo> <KEY> — sets _UBT_R to one of
#     `found <n> <head> <url> <ledger|rest>`, `none` or `unread`:
#       1. LEDGER: job_artifact_feed pr_url <project> "" UNBLOCK_PR_URL_FEED_LIMIT,
#          read once per call of ub_ticket_pr_enrich. The newest row (by
#          updated_at) whose ticket_id is KEY (case-blind, whole value) and
#          whose ref is https://github.com/<repo>/pull/<n>. Then one
#          gh_rest GET repos/<repo>/pulls/<n>: open with a 40-hex head = found.
#       2. BRANCH, when step 1 found nothing open (no row, a closed PR, an
#          unread feed or pull): one gh_rest GET
#          repos/<repo>/pulls?state=open&head=<owner>:ticket/<key lc>&per_page=10.
#          The newest by updated_at = found; [] = none; an error or a
#          non-array = unread.
#     Each ticket costs at most 2 GitHub reads per tick, and the feed 1 jobs read.
#     BH-10158: both reads go through ubp_read (bin/lib/unblock/prr.sh) under
#     the lane's step (lane.unblock.gh_source): step 1 is T-PULL (key
#     <repo>#<n>@pull:ticket-pr), step 2 is T-BRANCH (key
#     <repo>#branch:ticket/<key>@ticket-pr). In step record the PR record
#     answers and a miss reads GitHub; pr_source keeps the words ledger and rest.
#
# Knob (catalog/lanes.d/unblock.knobs.d/):
#   UNBLOCK_PR_URL_FEED_LIMIT (200, 1..500)  the pr_url rows read per tick
#
# NO ROOT DEFAULT (D43): gh-rest.sh is loaded from $HARNESS, then $H; with
# neither and no gh_rest loaded, every GitHub read is unread.
# gh-rest: no-graphql

# The record reads (BH-10158). No lib: today's GitHub reads, nothing else.
# shellcheck source=bin/lib/unblock/prr.sh
. "${BASH_SOURCE[0]%/*}/prr.sh" 2>/dev/null || true
declare -F ubp_read >/dev/null || ubp_read() { local o="$2" g="$4"; shift 5; "$g" "$o" "$@"; }

# The GitHub side of the two reads (prr_read's github-fn), in the caller's shell.
_ubt_pull_gh() { gh_rest GET "repos/$2/pulls/$3" > "$1" 2>/dev/null; }
_ubt_branch_gh() { gh_rest GET "repos/$2/pulls?state=open&head=${2%%/*}:$3&per_page=10" > "$1" 2>/dev/null; }

declare -gA _UBT_MEMO=()
_UBT_FEED_READ="" _UBT_FEED_OK=0 _UBT_TMP="" _UBT_R=""

_ubt_root() { printf '%s' "${HARNESS:-${H:-}}"; }

# _ubt_feed_limit — UNBLOCK_PR_URL_FEED_LIMIT, 1..500, else the fallback 200
# (the knob default, catalog/lanes.d/unblock.knobs.d/UNBLOCK_PR_URL_FEED_LIMIT.json).
_ubt_feed_limit() {
  local v="${UNBLOCK_PR_URL_FEED_LIMIT:-}"
  if [[ $v =~ ^[1-9][0-9]{0,2}$ ]] && [ "$v" -le 500 ]; then printf '%s' "$v"; else printf '200'; fi
}

# _ubt_pull_found <file> — the found line of one pulls/<n> answer that is open
# with a 40-hex head, else nothing.
_ubt_pull_found() {
  jq -r 'if type == "object" and .state == "open" and (.number | type) == "number"
      and ((.head.sha // "") | test("^[0-9a-f]{40}$"))
    then "found \(.number) \(.head.sha) \(.html_url // "-")" else empty end' "$1" 2>/dev/null
}

_ubt_pr_resolve() {
  local p="$1" repo="$2" key="$3" kl mk n url rc ans
  kl=$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')
  mk="$repo|$kl"
  if [ -n "${_UBT_MEMO[$mk]+x}" ]; then _UBT_R=${_UBT_MEMO[$mk]}; return 0; fi
  _UBT_R=unread
  # 1. the ledger: the build row's pr_url
  if [ -z "$_UBT_FEED_READ" ]; then
    _UBT_FEED_READ=1 _UBT_FEED_OK=0
    if declare -F job_artifact_feed >/dev/null \
       && job_artifact_feed pr_url "$p" "" "$(_ubt_feed_limit)" > "$_UBT_TMP/feed.tsv" 2>/dev/null; then
      _UBT_FEED_OK=1
    fi
  fi
  ans=""
  if [ "$_UBT_FEED_OK" = 1 ]; then
    n=$(awk -F'\t' -v k="$kl" -v pre="https://github.com/$(printf '%s' "$repo" | tr '[:upper:]' '[:lower:]')/pull/" '
      tolower($4) == k && index(tolower($2), pre) == 1 {
        n = substr($2, length(pre) + 1)
        if (n ~ /^[1-9][0-9]*$/ && ($5 > best || best == "")) { best = $5; num = n }
      }
      END { if (num != "") print num }' "$_UBT_TMP/feed.tsv" 2>/dev/null)
    if [[ $n =~ ^[1-9][0-9]*$ ]] && declare -F gh_rest >/dev/null; then
      rc=0; ubp_read "$repo#$n@pull:ticket-pr" "$_UBT_TMP/pull.json" ub_pull_record _ubt_pull_gh ub_pull_norm "$repo" "$n" || rc=$?
      [ "$rc" = 0 ] && ans=$(_ubt_pull_found "$_UBT_TMP/pull.json")
      [ -n "$ans" ] && ans="$ans ledger"
    fi
  fi
  # 2. one read by branch
  if [ -z "$ans" ] && declare -F gh_rest >/dev/null; then
    rc=0
    ubp_read "$repo#branch:ticket/$kl@ticket-pr" "$_UBT_TMP/branch.json" ub_branch_record _ubt_branch_gh ub_branch_norm "$repo" "ticket/$kl" || rc=$?
    if [ "$rc" = 0 ]; then
      ans=$(jq -r 'if type != "array" then "unread"
          elif length == 0 then "none"
          else (sort_by(.updated_at // "") | last) as $q
            | if ($q.number | type) == "number" and (($q.head.sha // "") | test("^[0-9a-f]{40}$"))
              then "found \($q.number) \($q.head.sha) \($q.html_url // "-") rest" else "unread" end end' \
        "$_UBT_TMP/branch.json" 2>/dev/null) || ans=unread
    fi
  fi
  [ -n "$ans" ] || ans=unread
  _UBT_R=$ans
  _UBT_MEMO[$mk]=$ans
  return 0
}

ub_ticket_pr_enrich() {
  local p="${1:-}" repo="${2:-}" line info key rrepo root out
  local -a r=()
  _UBT_MEMO=() _UBT_FEED_READ="" _UBT_FEED_OK=0
  root=$(_ubt_root)
  # shellcheck disable=SC1091
  declare -F gh_rest >/dev/null || { [ -n "$root" ] && . "$root/bin/lib/gh-rest.sh" 2>/dev/null; } || true
  _UBT_TMP=$(mktemp -d "${TMPDIR:-/tmp}/ubt.XXXXXX") || { cat; return 0; }
  while IFS= read -r line || [ -n "$line" ]; do
    info=$(jq -r --arg p "$p" --arg repo "$repo" --arg tre "${UB_TICKET_RE:-^[A-Z][A-Z0-9]*-[0-9]+([.][0-9]+)?$}" '
      if type != "object" then "skip" else
        (.subject // "" | tostring) as $s | (.project // $p | tostring) as $pj
        | ((first($s | capture("^ticket:[^:]+:(?<k>.+)$")) | .k)
           // (if ($pj != "" and ($s | startswith($pj + ":"))) then $s[(($pj | length) + 1):] else null end)) as $k0
        | (.repo // $repo | tostring) as $rr
        | if $k0 == null or ($k0 | test($tre) | not) then "skip"
          elif .has_pr == false then "skip"
          elif ((.pr | type) == "number" and ((.head // "") | tostring | test("^[0-9a-f]{40}$"))
                and (.pr_state == "open" or .has_pr == true)) then "fast"
          elif ($rr | test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$") | not) then "skip"
          else "resolve \($k0) \($rr)" end end' <<<"$line" 2>/dev/null) || info=skip
    case "$info" in
      fast)
        out=$(jq -c '. + {has_pr: true, unknown: ((.unknown // []) - ["has_pr"])}' <<<"$line" 2>/dev/null) || out=$line ;;
      "resolve "*)
        read -r _ key rrepo <<<"$info"
        _ubt_pr_resolve "$p" "$rrepo" "$key"
        read -r -a r <<<"$_UBT_R"
        case "${r[0]:-}" in
          found)
            out=$(jq -c --argjson n "${r[1]}" --arg h "${r[2]}" --arg u "${r[3]}" --arg s "${r[4]}" '
              if (.pr | type) == "number" and .pr != $n then .
              else . + {pr: $n, head: $h, pr_url: (if $u == "-" then null else $u end), pr_source: $s, has_pr: true,
                        unknown: ((.unknown // []) - ["has_pr"])} end' <<<"$line" 2>/dev/null) || out=$line ;;
          none)
            out=$(jq -c '. + {has_pr: false, unknown: ((.unknown // []) - ["has_pr"])}' <<<"$line" 2>/dev/null) || out=$line ;;
          *)
            out=$(jq -c '. + {has_pr: null, unknown: (((.unknown // []) - ["has_pr"]) + ["has_pr"])}' <<<"$line" 2>/dev/null) || out=$line ;;
        esac ;;
      *) out=$line ;;
    esac
    printf '%s\n' "$out"
  done
  rm -rf "$_UBT_TMP"
  return 0
}
