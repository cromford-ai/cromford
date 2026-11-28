#!/bin/bash
# bin/lib/prr-shadow.d/blocked-resolver.sh — the prr-shadow seam of lane blocked-resolver (BH-9926).
# Sourced by prr_seam_load blocked-resolver (bin/lib/prr-shadow.sh), never executed.
#
# BH-10157 (BH-9937 C1, wave 5). The knob GH_SOURCE (settings row
# lane.blocked-resolver.gh_source, default shadow) is registered in
# catalog/lanes.d/blocked-resolver.knobs.d/. The lane's GitHub side
# (brd_open_github, brd_state_array, brd_state_rest) lives in
# bin/blocked-resolver.d/bh-10157-record-discovery.sh beside the hooks that
# call prr_read, so the lane still runs when this file cannot be read. This
# file makes no GitHub call. Two discovery reads move:
#
#   brs_open_record <file> <owner/repo>
#       The repo's open PRs from the PR record: pr_record_list <repo> open
#       <tmp> head_sha,head_ref,base_ref,url,updated_at,author (no window:
#       the open list must be whole). Only the rows whose author is one of
#       ours (harness_pr_authors_json, bin/lib/gh-pr-list.sh) are kept, the
#       filter harness_pr_list applies. Mapped to the harness_pr_list shape
#       br_open_prs answers with: [{number, url, headRefOid, headRefName,
#       baseRefName, isDraft, updatedAt}]. updated_at and author are need
#       fields, so a null is a miss and the lane reads GitHub. A miss prints
#       the pr_record_list miss word and returns 1 with an empty <file>; no
#       lib, or no author set, is `unreadable`.
#   brs_open_norm <file>
#       The compare form: [{n, h: head lowercase, d: isDraft}] sorted by n.
#       url and updatedAt move on events that change no fact, so neither counts.
#
#   brs_state_record <file> <owner/repo> <number>
#       The state of one PR from the record: pr_record_peek, one jobs GET.
#       Writes {"number": n, "state": "merged"|"closed"|"open", "at":
#       <merged_at for merged, else updated_at, else "">}. A peek miss prints
#       unknown and returns 1, as does a row with no state word.
#   brs_state_norm <file>
#       [{n: "state", s: merged|closed|other}]. open, none (the closed pages
#       have no row) and any other word are `other`: "the record says open"
#       and "no closed page lists it" are the same answer, not a mismatch.
#
# BH-10350. A third read moves: the merged-PR lookup br_merged_prs_for (lane
# side in bin/blocked-resolver.d/bh-10350-merged-record.sh).
#   brs_merged_record <file> <owner/repo> <ticket-key> <since-epoch>
#       The repo's merged PRs updated since the park, from the record:
#       pr_record_list <repo> merged <tmp> head_ref,merged_at,url,title "" ""
#       <since-iso>. A row counts when merged_at is after <since-epoch> and it
#       names the ticket: head ref ticket/<lk> or ticket/<lk>-*, a branch path
#       segment <lk> or <lk>-r<k>, or the whole key in the title (the rule of
#       br_merged_prs_for). Writes the TSV url<TAB>merged_at<TAB>head_ref,
#       sorted by url (empty = no merged PR since the park), rc 0. Misses:
#       no-since (no park time), unknown (a bad key), unreadable (no lib),
#       the pr_record_list word, field:merged_at (a null merge time), and
#       malformed (a url that is not this repo's pull URL).
#       The retention window (lead review of #10389): the worker deletes a
#       merged row once its refreshed_at is older than the window, while the
#       list stamp stays fresh. So a park at or before now minus
#       brs_merged_max_age is the miss too-old (the record may have lost the
#       merge), and a window it cannot read is window-unread. Now is
#       PR_RECORD_NOW (the epoch test seam of bin/lib/pr-record.sh) or the
#       box clock; the 1-day margin covers the skew to the worker clock.
#   brs_merged_max_age
#       The seconds back from now that the record still holds every merged
#       row, on stdout, or `unlimited`. The window is the smaller non-zero of
#       the settings rows retention.pr_records.closed_days (fallback 14) and
#       retention.pr_records.days (fallback 90), the rows the worker's
#       retention reads (worker/jobs/src/routes/retention.d/
#       bh-8067-pr-records.js), parsed as it parses them (digits, at most
#       3650, else the fallback; 0 = that rule off). Then minus 1 day of
#       margin. No row, or no setting_get, is the fallback. An unreadable
#       row is rc 1 (the window is unknown).
#   brs_merged_norm <file>
#       [{n}] of the TSV rows merged after $_BRMR_SINCE, sorted by n. GitHub's
#       search answers all time, and the record answers since the park.
if ! command -v pr_record_list >/dev/null 2>&1 && [ -r "${BASH_SOURCE[0]%/*}/../pr-record.sh" ]; then
  # shellcheck source=bin/lib/pr-record.sh
  . "${BASH_SOURCE[0]%/*}/../pr-record.sh"
fi

brs_open_record() {
  local f="${1:-}" repo="${2:-}" tmp why rc au
  [ -n "$f" ] || return 2
  : > "$f" 2>/dev/null
  command -v pr_record_list >/dev/null 2>&1 || { echo unreadable; return 1; }
  command -v harness_pr_authors_json >/dev/null 2>&1 || { echo unreadable; return 1; }
  au=$(harness_pr_authors_json 2>/dev/null)
  jq -e 'type == "array" and length > 0 and all(.[]; type == "string" and length > 0)' <<<"$au" >/dev/null 2>&1 \
    || { echo unreadable; return 1; }
  tmp=$(mktemp "${TMPDIR:-/tmp}/brs-open.XXXXXX") || { echo unreadable; return 1; }
  why=$(pr_record_list "$repo" open "$tmp" head_sha,head_ref,base_ref,url,updated_at,author); rc=$?
  if [ "$rc" != 0 ]; then
    rm -f "$tmp" "$tmp.sync"
    echo "${why:-unreadable}"; return 1
  fi
  if ! jq -c --argjson au "$au" '[.[] | select((.author // "") as $a | $au | index($a))
        | {number, url: (.url // ""), headRefOid: (.head_sha // ""), headRefName: (.head_ref // ""),
           baseRefName: (.base_ref // "main"), isDraft: (.draft == true or .draft == 1), updatedAt: (.updated_at // "")}]' \
        "$tmp" > "$f" 2>/dev/null; then
    rm -f "$tmp" "$tmp.sync"; : > "$f"
    echo malformed; return 1
  fi
  rm -f "$tmp" "$tmp.sync"
  return 0
}

brs_open_norm() {
  jq -c '[.[] | {n: .number, h: ((.headRefOid // "") | ascii_downcase), d: (.isDraft == true)}] | sort_by(.n)' "${1:-}" 2>/dev/null
}

brs_state_record() {
  local f="${1:-}" repo="${2:-}" n="${3:-}" row
  [ -n "$f" ] || return 2
  : > "$f" 2>/dev/null
  [[ "$n" =~ ^[1-9][0-9]{0,9}$ ]] || { echo unknown; return 1; }
  command -v pr_record_peek >/dev/null 2>&1 || { echo unreadable; return 1; }
  row=$(pr_record_peek "$repo" "$n") || { echo unknown; return 1; }
  jq -ce --argjson n "$n" 'select((.state | type) == "string" and (.state == "merged" or .state == "closed" or .state == "open"))
      | {number: $n, state: .state, at: ((if .state == "merged" then .merged_at else null end) // .updated_at // "")}' \
      <<<"$row" > "$f" 2>/dev/null \
    || { : > "$f"; echo unknown; return 1; }
  return 0
}

brs_state_norm() {
  jq -c 'select(type == "object" and (.state | type) == "string")
    | [{n: "state", s: (if .state == "merged" or .state == "closed" then .state else "other" end)}]' "${1:-}" 2>/dev/null
}

# _brs_days <key> <fallback> — one retention row, parsed the worker's way
#   (intSetting: digits, 0..3650, else the fallback). rc 1 = unreadable.
_brs_days() {
  local v rc
  command -v setting_get >/dev/null 2>&1 || { printf '%s' "$2"; return 0; }
  v=$(setting_get "$1" 2>/dev/null); rc=$?
  case "$rc" in
    0) ;;
    2) printf '%s' "$2"; return 0 ;;
    *) return 1 ;;
  esac
  v="${v//[[:space:]]/}"
  if [[ "$v" =~ ^[0-9]{1,4}$ ]] && [ "$((10#$v))" -le 3650 ]; then printf '%s' "$((10#$v))"; else printf '%s' "$2"; fi
}

brs_merged_max_age() {
  local a b d
  a=$(_brs_days retention.pr_records.closed_days 14) || return 1
  b=$(_brs_days retention.pr_records.days 90) || return 1
  d=$a
  { [ "$d" = 0 ] || { [ "$b" != 0 ] && [ "$b" -lt "$d" ]; }; } && d=$b
  [ "$d" = 0 ] && { echo unlimited; return 0; }
  echo "$(( (d - 1) * 86400 ))"
}

brs_merged_record() {
  local f="${1:-}" repo="${2:-}" tkey="${3:-}" since="${4:-}" lk siso tmp why rc maxage now
  [ -n "$f" ] || return 2
  : > "$f" 2>/dev/null
  [[ "$since" =~ ^[1-9][0-9]{0,11}$ ]] || { echo no-since; return 1; }
  [[ "$tkey" =~ ^[A-Za-z][A-Za-z0-9]*-[0-9]+$ ]] || { echo unknown; return 1; }
  command -v pr_record_list >/dev/null 2>&1 || { echo unreadable; return 1; }
  siso=$(date -u -d "@$since" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) || { echo no-since; return 1; }
  maxage=$(brs_merged_max_age) || { echo window-unread; return 1; }
  if [ "$maxage" != unlimited ]; then
    now="${PR_RECORD_NOW:-}"
    [[ "$now" =~ ^[0-9]{1,12}$ ]] || now=$(date -u +%s)
    [ "$((now - since))" -lt "$maxage" ] || { echo too-old; return 1; }
  fi
  lk=$(printf '%s' "$tkey" | tr '[:upper:]' '[:lower:]')
  tmp=$(mktemp "${TMPDIR:-/tmp}/brs-merged.XXXXXX") || { echo unreadable; return 1; }
  why=$(pr_record_list "$repo" merged "$tmp" head_ref,merged_at,url,title "" "" "$siso"); rc=$?
  if [ "$rc" != 0 ]; then
    rm -f "$tmp" "$tmp.sync"
    echo "${why:-unreadable}"; return 1
  fi
  # A null merge time the worker did not name is still a miss: the row cannot
  # be placed before or after the park.
  if jq -e 'any(.[]; (.merged_at | type) != "string")' "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp" "$tmp.sync"; echo field:merged_at; return 1
  fi
  # A url that is not this repo's pull URL is no answer to trust.
  if ! jq -e --arg r "$(printf '%s' "$repo" | tr '[:upper:]' '[:lower:]')" \
        'all(.[]; (.url | type) == "string" and ((.url | ascii_downcase) | test("^https://github\\.com/" + ($r | gsub("\\."; "\\.")) + "/pull/[1-9][0-9]*$")))' \
        "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp" "$tmp.sync"; echo malformed; return 1
  fi
  if ! jq -r --arg lk "$lk" --arg k "$tkey" --argjson s "$since" '
      def ep: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
      [ .[] | select((.merged_at | ep) > $s)
        | ((.head_ref // "") | ascii_downcase) as $h
        | select($h == "ticket/" + $lk or ($h | startswith("ticket/" + $lk + "-"))
                 or any($h | split("/")[]; . == $lk or test("^" + $lk + "-r[0-9]+$"))
                 or ((.title // "") | ascii_upcase | test("(^|[^A-Z0-9])" + $k + "([^0-9]|$)")))
        | [.url, .merged_at, (.head_ref // "-")] ]
      | sort_by(.[0])[] | @tsv' "$tmp" > "$f" 2>/dev/null; then
    rm -f "$tmp" "$tmp.sync"; : > "$f"; echo malformed; return 1
  fi
  rm -f "$tmp" "$tmp.sync"
  return 0
}

brs_merged_norm() {
  jq -cR -s --arg s "${_BRMR_SINCE:-}" '
    [ split("\n")[] | select(length > 0) | split("\t")
      | select(($s == "") or ((.[1] // "") | (try (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) catch 0)) > ($s | tonumber))
      | {n: ((.[0] // "") | capture("/pull/(?<n>[0-9]+)$").n | tonumber)} ]
    | unique_by(.n) | sort_by(.n)' "${1:-}" 2>/dev/null
}
