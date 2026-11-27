#!/bin/bash
# bin/lib/prr-shadow.d/unblock.sh — the prr-shadow seam of lane unblock (BH-9926).
# Sourced by bin/lib/unblock/prr.sh (prr_seam_load unblock), never executed.
#
# BH-10158 (wave 5, slice C2 of #9937). The knob GH_SOURCE (settings row
# lane.unblock.gh_source, default shadow) is registered in
# catalog/lanes.d/unblock.knobs.d/. The lane's GitHub side of each read stays
# in the file of the read it replaces (bin/lib/unblock/ticket-pr.sh and
# bin/lib/unblock/collectors/*.sh), so the lane still reads GitHub when this
# file cannot be read. This file makes NO GitHub call: record and compare
# functions only. Each record function writes the SAME shape as the GitHub
# read it replaces, so the caller's jq does not change, and on a miss prints
# one word and returns 1 (prr_read then reads GitHub).
#
#   ub_open_record <file> <owner/repo>
#       T-OPEN. pulls?state=open&per_page=100: pr_record_list <repo> open
#       <tmp> head_sha,labels 100 (the newest 100 by created_at), mapped to
#       [{number, state, draft, head: {sha, ref}, base: {ref}, labels: [{name}],
#       html_url, updated_at, created_at}], created_at descending (GitHub's
#       order). Misses: the pr_record_list words; field:head_sha (not 40 hex)
#       or field:labels (not a list) on a row.
#   ub_open_norm <file>      [{n, h: head lowercase, d: draft, l: label names sorted}] by n
#
#   ub_pull_record <file> <owner/repo> <number> [need-csv]
#       T-PULL. pulls/<n>: pr_record_peek, mapped to {number, state: open|closed,
#       merged, merged_at, merge_commit_sha: null, head: {sha, ref}, base: {ref},
#       labels: [{name}], mergeable_state, html_url, draft}. The record's state
#       merged is REST state closed with merged true. Misses: unknown (no row,
#       a failed read), field:state, field:head_sha (not 40 hex), and
#       field:<f> for a need that is null. The record holds no merge commit,
#       so need merge_commit_sha is field:merge_commit_sha on a merged PR.
#   ub_pull_norm <file>      [{n, s: state, m: merged, h: head lowercase, l: labels sorted}]
#                            (mergeable_state is not compared: GitHub computes it lazily)
#
#   ub_branch_record <file> <owner/repo> <branch>
#       T-BRANCH. pulls?state=open&head=<owner>:<branch>: the record's whole
#       open list (pr_record_list <repo> open <tmp> head_sha,head_ref, read
#       once per tick through the memo dir UBP_MEMO_DIR) filtered to rows whose
#       head_ref is <branch> byte for byte. [{number, head: {sha, ref},
#       html_url, updated_at}]. A list miss is a miss, never [].
#   ub_branch_norm <file>    [{n, h}] by n
#
#   ub_cr_record <file> <owner/repo>
#       T-CR. search/issues?...review:changes_requested: the record's whole
#       open list with need reviews (memo as above). A PR is in the set when a
#       login's stored latest review is CHANGES_REQUESTED. Writes
#       {"incomplete_results": false, "items": [{"number": n}]}. A row whose
#       reviews is not an object is field:reviews.
#   ub_cr_norm <file>        [{n}] by n
#
#   ub_ci_record <file> <owner/repo> <number> <head>
#       T-CI. commits/<head>/check-runs reduced by _ubq_checks: PRR_CI_GUARD=0
#       prr_ci_state. green -> green, red -> red, pending -> running, else the
#       miss ci:unknown. Writes {"word": <w>}.
#   ub_ci_norm <file>        [{n: "ci", w}]; nothing for a null word
#
# Keys of the PRR_SHADOW and PRR_MISS lines (prr_read's <key>):
#   <repo>#open@review  <repo>#open@queue  <repo>#cr  <repo>#<n>@pull:<site>
#   <repo>#branch:<ref>@<site>  <repo>#<n>@ci
if ! command -v pr_record_list >/dev/null 2>&1 && [ -r "${BASH_SOURCE[0]%/*}/../pr-record.sh" ]; then
  # shellcheck source=bin/lib/pr-record.sh
  . "${BASH_SOURCE[0]%/*}/../pr-record.sh"
fi
if ! command -v prr_ci_state >/dev/null 2>&1 && [ -r "${BASH_SOURCE[0]%/*}/../prr-ci-state.sh" ]; then
  # shellcheck source=bin/lib/prr-ci-state.sh
  . "${BASH_SOURCE[0]%/*}/../prr-ci-state.sh"
fi

# _ub_list <owner/repo> <need-csv> <window|-> <out> — pr_record_list of the
# open list, through the per-tick memo UBP_MEMO_DIR when it is a directory (a
# miss is memoized too, so a tick asks once). Prints the miss word, rc 1.
_ub_list() {
  local repo="$1" need="$2" win="$3" out="$4" m="" why rc
  command -v pr_record_list >/dev/null 2>&1 || { echo unreadable; return 1; }
  if [ -n "${UBP_MEMO_DIR:-}" ] && [ -d "$UBP_MEMO_DIR" ]; then
    m="$UBP_MEMO_DIR/list-$(printf '%s' "$repo" | tr 'A-Z/' 'a-z_')-${need//,/+}-$win"
    if [ -s "$m.miss" ]; then cat "$m.miss"; return 1; fi
    if [ -s "$m.json" ] && cp "$m.json" "$out" 2>/dev/null; then return 0; fi
  fi
  if [ "$win" = - ]; then why=$(pr_record_list "$repo" open "$out" "$need"); rc=$?
  else why=$(pr_record_list "$repo" open "$out" "$need" "$win"); rc=$?; fi
  rm -f "$out.sync"
  if [ "$rc" != 0 ]; then
    : > "$out"; why="${why:-unreadable}"
    [ -z "$m" ] || printf '%s\n' "$why" > "$m.miss" 2>/dev/null
    echo "$why"; return 1
  fi
  [ -z "$m" ] || cp "$out" "$m.json" 2>/dev/null || true
  return 0
}

# _ub_tmp — a temp file for one record read.
_ub_tmp() { mktemp "${TMPDIR:-/tmp}/ub-prr.XXXXXX"; }

ub_open_record() {
  local f="${1:-}" repo="${2:-}" tmp why
  [ -n "$f" ] || return 2
  tmp=$(_ub_tmp) || { echo unreadable; return 1; }
  why=$(_ub_list "$repo" head_sha,labels 100 "$tmp") || { rm -f "$tmp"; : > "$f"; echo "$why"; return 1; }
  why=$(jq -r 'if type != "array" then "malformed"
      elif any(.[]; ((.head_sha // "") | test("^[0-9a-fA-F]{40}$")) | not) then "field:head_sha"
      elif any(.[]; (.labels | type) != "array") then "field:labels"
      else "" end' "$tmp" 2>/dev/null) || why=malformed
  if [ -n "$why" ]; then rm -f "$tmp"; : > "$f"; echo "$why"; return 1; fi
  if ! jq -c 'sort_by([(.created_at // ""), .number]) | reverse
      | [.[] | {number, state: "open", draft: (.draft == true or .draft == 1),
                head: {sha: .head_sha, ref: .head_ref}, base: {ref: .base_ref},
                labels: [.labels[] | if type == "object" then {name: .name} else {name: .} end],
                html_url: .url, updated_at, created_at}]' "$tmp" > "$f" 2>/dev/null; then
    rm -f "$tmp"; : > "$f"; echo malformed; return 1
  fi
  rm -f "$tmp"
  return 0
}

ub_open_norm() {
  jq -c 'select(type == "array") | [.[] | {n: .number, h: ((.head.sha // "") | ascii_downcase),
      d: (.draft == true), l: ([(.labels // [])[] | .name] | sort)}] | sort_by(.n)' "${1:-}" 2>/dev/null
}

ub_pull_record() {
  local f="${1:-}" repo="${2:-}" n="${3:-}" need="${4:-}" row why
  [ -n "$f" ] || return 2
  command -v pr_record_peek >/dev/null 2>&1 || { echo unreadable; return 1; }
  row=$(pr_record_peek "$repo" "$n") || { : > "$f"; echo unknown; return 1; }
  why=$(jq -r --arg need "$need" '
      if type != "object" then "unknown"
      elif ((.state // "") | IN("open", "closed", "merged") | not) then "field:state"
      elif ((.head_sha // "") | test("^[0-9a-fA-F]{40}$") | not) then "field:head_sha"
      else . as $r
        | [$need | split(",")[] | select(. != "")
           | select(if . == "merge_commit_sha" then $r.state == "merged" else $r[.] == null end)]
        | if length > 0 then "field:" + .[0] else "" end end' <<<"$row" 2>/dev/null) || why=unknown
  if [ -n "$why" ]; then : > "$f"; echo "$why"; return 1; fi
  if ! jq -c --argjson n "$n" '{number: $n, state: (if .state == "merged" then "closed" else .state end),
        merged: (.state == "merged"), merged_at: (.merged_at // null), merge_commit_sha: null,
        head: {sha: .head_sha, ref: (.head_ref // null)}, base: {ref: (.base_ref // null)},
        labels: (if (.labels | type) == "array" then [.labels[] | if type == "object" then {name: .name} else {name: .} end] else [] end),
        mergeable_state: (.mergeable_state // null), html_url: (.url // null),
        draft: (.draft == true or .draft == 1)}' <<<"$row" > "$f" 2>/dev/null; then
    : > "$f"; echo unknown; return 1
  fi
  return 0
}

ub_pull_norm() {
  jq -c 'select(type == "object" and (.state | type) == "string")
      | [{n: .number, s: .state, m: (.merged == true), h: ((.head.sha // "") | ascii_downcase),
          l: ([(.labels // [])[] | .name] | sort)}]' "${1:-}" 2>/dev/null
}

ub_branch_record() {
  local f="${1:-}" repo="${2:-}" br="${3:-}" tmp why
  [ -n "$f" ] && [ -n "$br" ] || return 2
  tmp=$(_ub_tmp) || { echo unreadable; return 1; }
  why=$(_ub_list "$repo" head_sha,head_ref - "$tmp") || { rm -f "$tmp"; : > "$f"; echo "$why"; return 1; }
  if ! jq -c --arg b "$br" 'if type != "array" then error("x") else . end
      | [.[] | select(.head_ref == $b)
         | {number, head: {sha: .head_sha, ref: .head_ref}, html_url: .url, updated_at}]' "$tmp" > "$f" 2>/dev/null; then
    rm -f "$tmp"; : > "$f"; echo malformed; return 1
  fi
  rm -f "$tmp"
  return 0
}

ub_branch_norm() {
  jq -c 'select(type == "array") | [.[] | {n: .number, h: ((.head.sha // "") | ascii_downcase)}] | sort_by(.n)' "${1:-}" 2>/dev/null
}

ub_cr_record() {
  local f="${1:-}" repo="${2:-}" tmp why
  [ -n "$f" ] || return 2
  tmp=$(_ub_tmp) || { echo unreadable; return 1; }
  why=$(_ub_list "$repo" reviews - "$tmp") || { rm -f "$tmp"; : > "$f"; echo "$why"; return 1; }
  if jq -e 'type != "array" or any(.[]; (.reviews | type) != "object")' "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"; : > "$f"; echo field:reviews; return 1
  fi
  if ! jq -c '{incomplete_results: false,
      items: [.[] | select(any(.reviews[]; (type == "object") and .state == "CHANGES_REQUESTED")) | {number}] | sort_by(.number)}' \
      "$tmp" > "$f" 2>/dev/null; then
    rm -f "$tmp"; : > "$f"; echo malformed; return 1
  fi
  rm -f "$tmp"
  return 0
}

ub_cr_norm() {
  jq -c 'select(type == "object" and (.items | type) == "array") | [.items[] | {n: .number}] | sort_by(.n)' "${1:-}" 2>/dev/null
}

ub_ci_record() {
  local f="${1:-}" repo="${2:-}" n="${3:-}" head="${4:-}" w
  [ -n "$f" ] || return 2
  command -v prr_ci_state >/dev/null 2>&1 || { echo ci:unknown; return 1; }
  w=$(PRR_CI_GUARD=0 prr_ci_state "$repo" "$n" "$head" 2>/dev/null)
  case "$w" in
    green|red) ;;
    pending) w=running ;;
    *) : > "$f"; echo ci:unknown; return 1 ;;
  esac
  printf '{"word":"%s"}\n' "$w" > "$f"
  return 0
}

ub_ci_norm() {
  jq -c 'select(type == "object" and (.word | type) == "string") | [{n: "ci", w: .word}]' "${1:-}" 2>/dev/null
}
