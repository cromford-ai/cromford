#!/bin/bash
# gh-identity: raw-by-design — sourced by bin/pipeline-health.sh, whose stale-parent loop has ALREADY armed the identity that can see this repo (gh_repo_use_token "$SLUG"); a second mint here would override that choice.
# bin/lib/stale-parent-rest.sh — the stale-parent check without a checkout
# (BH-6892). Sourced, never executed: no `set -e`, no `exit`, no output at
# source time.
#
# WHY. bin/lib/stale-parent.sh sp_stale_commits reads a local clone. On a
# lane-run machine (LANE_RUN_ID set) there is no /root/repos checkout, so the
# check went blind there. This file is its REST twin: it reads the PR commit
# list, the base commit list and the commit diffs from GitHub REST, and takes
# each patch-id from `git patch-id --stable` over the REST diff (stdin only, no
# repo needed). Both sides of every comparison come from the same GitHub diff
# format (application/vnd.github.diff), so the patch-ids are comparable with
# each other. They are NOT mixed with patch-ids from a local `git show`.
#
#   spr_budget_init                          SPR_LEFT from the knob; counters 0
#   spr_pid <slug> <sha> <cache>             rc 0 + pid · 1 no pid · 3 budget spent
#   spr_cum_pid <slug> <from> <to> <cache>   the same, over compare from...to
#   spr_base_pids <slug> <branch> <since-epoch> <cache>
#                                            "pid<TAB>sha" per non-merge commit;
#                                            rc 0 · 1 read failure · 2 page cut
#                                            (over 3 pages) · 3 budget spent
#   spr_stale_commits <slug> <base> <num> <cache>
#                                            TSV child_sha, main_sha, subject;
#                                            rc 0 with or without rows · 1 read
#                                            failure · 2 page cut · 3 budget
#                                            spent (stdout empty on 1/2/3)
#   spr_cache_save <cache>                   tmp + mv, with retention
#
# GLOBALS. SPR_LEFT: diff calls still allowed this run. SPR_FETCHED: diff calls
# made (a failed call counts). SPR_CACHED: patch-ids answered from the cache.
# Only a call in the CURRENT shell updates them and the in-memory cache: call
# spr_pid / spr_base_pids with a redirect, never inside $(...), when the
# counters matter. spr_stale_commits uses the internal setters, so a plain
# `rows=$(spr_stale_commits ...)` loses them too: send its stdout to a file.
#
# BUDGET. A miss with SPR_LEFT at 0 makes no call and answers rc 3; one rc 3
# ends spr_stale_commits with rc 3 and no rows, so a half-read map never reports
# a false "no stale commit". Knob STALE_PARENT_REST_DIFF_MAX (default 120,
# catalog/lanes.d/_lib.stale-parent.json), an integer 1..1000; anything else is
# 120. sp_knob passes an unknown knob through raw, so this file validates it.
#
# CACHE. One TSV file per caller, `key<TAB>pid<TAB>last-used-epoch`; the key is
# a sha (spr_pid) or `<from>..<to>` (spr_cum_pid). A sha's diff never changes,
# so a hit is never re-checked. A failed or empty read is never cached. It is
# loaded once per path into _SPR_C / _SPR_T; loading another path drops the
# unsaved rows of the first, so save before you switch. spr_stale_commits never
# saves: the caller saves once (bin/pipeline-health.sh, once per project).
# Retention on save: rows not used for 14 days go, then the newest 1800 by
# last-used stay. Clock seam: SPR_NOW (default `date +%s`).
#
# Root: ${HARNESS:-${H:-}}, nothing else; without one spr_budget_init and
# spr_stale_commits answer rc 1. GitHub reads are `gh api` only. No `git -C`.

_SPR_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=stale-parent.sh
command -v sp_knob >/dev/null 2>&1 || . "$_SPR_LIB/stale-parent.sh"

declare -gA _SPR_C=() _SPR_T=()
_SPR_CF=""

_spr_root() { printf '%s' "${HARNESS:-${H:-}}"; }
_spr_now()  { printf '%s' "${SPR_NOW:-$(date +%s)}"; }
_spr_hex()  { case "${1:-}" in ''|*[!0-9a-f]*) return 1 ;; esac; [ "${#1}" -ge 7 ] && [ "${#1}" -le 64 ]; }

# spr_budget_init — SPR_LEFT from STALE_PARENT_REST_DIFF_MAX, SPR_FETCHED and
# SPR_CACHED to 0. No root: SPR_LEFT=0 (every miss is rc 3) and rc 1.
spr_budget_init() {
  local v
  SPR_FETCHED=0; SPR_CACHED=0; SPR_LEFT=0
  [ -n "$(_spr_root)" ] || return 1
  v=$(sp_knob STALE_PARENT_REST_DIFF_MAX)
  case "$v" in ''|*[!0-9]*) v=120 ;; esac
  [ "${#v}" -le 4 ] || v=120
  v=$((10#$v))
  { [ "$v" -ge 1 ] && [ "$v" -le 1000 ]; } || v=120
  SPR_LEFT=$v
}

# _spr_cache_load <cache> — read the file into _SPR_C / _SPR_T, once per path.
_spr_cache_load() {
  local f="$1" k p t
  [ "$_SPR_CF" = "$f" ] && return 0
  _SPR_C=(); _SPR_T=(); _SPR_CF="$f"
  [ -r "$f" ] || return 0
  while IFS=$'\t' read -r k p t; do
    [ -n "$k" ] && [ -n "$p" ] || continue
    case "$t" in ''|*[!0-9]*) t=0 ;; esac
    _SPR_C[$k]=$p; _SPR_T[$k]=$t
  done < "$f"
}

# _spr_fetch_pid <key> <rest-path> <cache> — sets _SPR_R to the patch-id of the
# diff at <rest-path>, from the cache when it holds <key>. rc 0 · 1 · 3.
_spr_fetch_pid() {
  local key="$1" path="$2" cache="$3" p
  _SPR_R=""
  _spr_cache_load "$cache"
  if [ -n "${_SPR_C[$key]+x}" ]; then
    _SPR_R=${_SPR_C[$key]}
    _SPR_T[$key]=$(_spr_now)
    SPR_CACHED=$(( ${SPR_CACHED:-0} + 1 ))
    return 0
  fi
  [ -n "${SPR_LEFT+x}" ] || spr_budget_init
  [ "${SPR_LEFT:-0}" -gt 0 ] 2>/dev/null || return 3
  SPR_LEFT=$((SPR_LEFT - 1)); SPR_FETCHED=$(( ${SPR_FETCHED:-0} + 1 ))
  p=$(set -o pipefail
      gh api -H 'Accept: application/vnd.github.diff' "$path" 2>/dev/null \
        | git patch-id --stable 2>/dev/null | awk 'NR == 1 {print $1}') || return 1
  [ -n "$p" ] || return 1
  _SPR_C[$key]=$p; _SPR_T[$key]=$(_spr_now)
  _SPR_R=$p
}

# spr_pid <slug> <sha> <cache> — the stable patch-id of one commit's diff.
spr_pid() {
  _spr_hex "${2:-}" || return 1
  _spr_fetch_pid "$2" "repos/$1/commits/$2" "$3" || return $?
  printf '%s\n' "$_SPR_R"
}

# spr_cum_pid <slug> <from> <to> <cache> — the patch-id of everything from
# <from> to <to>: what a squash of the commits after <from> would carry.
spr_cum_pid() {
  _spr_hex "${2:-}" && _spr_hex "${3:-}" || return 1
  _spr_fetch_pid "$2..$3" "repos/$1/compare/$2...$3" "$4" || return $?
  printf '%s\n' "$_SPR_R"
}

# _spr_base_r <slug> <branch> <since-epoch> <cache> — sets _SPR_MAP to
# "pid<TAB>sha" lines for every non-merge commit on <branch> committed since
# <since> less an hour (the slack _sp_base_pids gives a committer clock that
# ran behind). Three pages of 100 at most: a fourth would be needed → rc 2, as
# a map that may miss the copy proves nothing. A commit with no patch-id (an
# empty diff, a failed read) is left out; rc 3 when the budget runs out.
_spr_base_r() {
  local slug="$1" br="$2" since="$3" cache="$4" enc iso page body n shas="" s rows=""
  _SPR_MAP=""
  case "$since" in ''|*[!0-9]*) return 1 ;; esac
  enc=$(jq -rn --arg r "$br" '$r|@uri' 2>/dev/null)
  [ -n "$enc" ] || return 1
  iso=$(date -u -d "@$((since - 3600))" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) || return 1
  for page in 1 2 3; do
    body=$(gh api "repos/$slug/commits?sha=$enc&since=$iso&per_page=100&page=$page" 2>/dev/null) || return 1
    n=$(jq -r 'if type == "array" then length else empty end' <<<"$body" 2>/dev/null)
    case "${n:-x}" in ''|*[!0-9]*) return 1 ;; esac
    shas+=$(jq -r '.[] | select((.parents | length) <= 1) | .sha' <<<"$body" 2>/dev/null)$'\n'
    [ "$n" -lt 100 ] && break
    [ "$page" = 3 ] && return 2
  done
  while IFS= read -r s; do
    _spr_hex "$s" || continue
    _spr_fetch_pid "$s" "repos/$slug/commits/$s" "$cache"
    case $? in
      0) rows+="$_SPR_R"$'\t'"$s"$'\n' ;;
      3) return 3 ;;
    esac
  done <<<"$shas"
  _SPR_MAP=$rows
}

# spr_base_pids <slug> <branch> <since-epoch> <cache> — _spr_base_r, printed.
spr_base_pids() {
  _spr_base_r "$@" || return $?
  printf '%s' "$_SPR_MAP"
}

# spr_stale_commits <slug> <base-branch> <num> <cache> — sp_stale_commits over
# REST: one TSV row per commit PR <num> carries that is ALREADY on the base
# under another sha, `child_sha<TAB>main_sha<TAB>subject`. The child list is
# the PR's commits (GitHub lists them oldest first), merges left out, capped at
# STALE_PARENT_SCAN_MAX. The window starts at the first child's committer date.
# When no single commit matches, the longest leading run whose cumulative diff
# (compare from the first child's parent) is one base commit is reported
# against that commit, as in sp_stale_commits. A base sha equal to the child
# commit itself is never a copy, in either pass.
spr_stale_commits() {
  local slug="${1:-}" base="${2:-}" num="${3:-}" cache="${4:-}" body max list
  local c par d subj first_par="" since="" p m i rc rows=""
  [ -n "$(_spr_root)" ] || return 1
  case "$slug" in */*) ;; *) return 1 ;; esac
  case "$num" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$base" ] && [ -n "$cache" ] || return 1
  body=$(gh api "repos/$slug/pulls/$num/commits?per_page=100" 2>/dev/null) || return 1
  jq -e 'type == "array"' >/dev/null 2>&1 <<<"$body" || return 1
  max=$(sp_knob STALE_PARENT_SCAN_MAX)
  case "$max" in ''|*[!0-9]*) max=20 ;; esac
  # @tsv escapes a tab or backslash in a subject; a subject is display text.
  list=$(jq -r --argjson max "$max" '[.[] | select((.parents | length) <= 1)] | .[:$max][]
           | [.sha, (.parents[0].sha // ""), (.commit.committer.date // ""),
              ((.commit.message // "") | split("\n")[0])] | @tsv' <<<"$body" 2>/dev/null) || return 1
  [ -n "$list" ] || return 0
  local -a commits=() subjects=()
  while IFS=$'\t' read -r c par d subj; do
    _spr_hex "$c" || return 1
    if [ "${#commits[@]}" = 0 ]; then
      first_par=$par
      [ -n "$d" ] || return 1
      since=$(date -u -d "$d" +%s 2>/dev/null) || return 1
    fi
    commits+=("$c"); subjects+=("$subj")
  done <<<"$list"
  _spr_base_r "$slug" "$base" "$since" "$cache" || return $?
  [ -n "$_SPR_MAP" ] || return 0
  for ((i = 0; i < ${#commits[@]}; i++)); do
    c=${commits[$i]}
    _spr_fetch_pid "$c" "repos/$slug/commits/$c" "$cache"; rc=$?
    [ "$rc" = 3 ] && return 3
    [ "$rc" = 0 ] || continue
    p=$_SPR_R
    m=$(awk -F'\t' -v p="$p" '$1 == p {print $2; exit}' <<<"$_SPR_MAP")
    [ -n "$m" ] && [ "$m" != "$c" ] || continue
    rows+="$c"$'\t'"$m"$'\t'"${subjects[$i]}"$'\n'
  done
  if [ -z "$rows" ] && _spr_hex "$first_par"; then
    local endi=-1 endm=""
    for ((i = 0; i < ${#commits[@]}; i++)); do
      c=${commits[$i]}
      _spr_fetch_pid "$first_par..$c" "repos/$slug/compare/$first_par...$c" "$cache"; rc=$?
      [ "$rc" = 3 ] && return 3
      [ "$rc" = 0 ] || continue
      p=$_SPR_R
      m=$(awk -F'\t' -v p="$p" '$1 == p {print $2; exit}' <<<"$_SPR_MAP")
      [ -n "$m" ] && [ "$m" != "$c" ] && { endi=$i; endm=$m; }
    done
    for ((i = 0; i <= endi; i++)); do
      rows+="${commits[$i]}"$'\t'"$endm"$'\t'"${subjects[$i]}"$'\n'
    done
  fi
  printf '%s' "$rows"
}

# spr_cache_save <cache> — write the loaded cache back: tmp + mv, rows unused
# for 14 days dropped, then the newest 1800 by last-used kept. A path that was
# never loaded is loaded first, so retention still runs on it.
spr_cache_save() {
  local f="${1:-}" now cut tmp k
  [ -n "$f" ] || return 1
  _spr_cache_load "$f"
  now=$(_spr_now); cut=$((now - 14 * 86400))
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 1
  tmp=$(mktemp "$f.XXXXXX" 2>/dev/null) || return 1
  # awk, not head: it reads all of sort's output, so a caller's pipefail never
  # sees a SIGPIPE from sort.
  for k in "${!_SPR_C[@]}"; do
    [ "${_SPR_T[$k]:-0}" -ge "$cut" ] || continue
    printf '%s\t%s\t%s\n' "$k" "${_SPR_C[$k]}" "${_SPR_T[$k]}"
  done | sort -t$'\t' -k3,3nr -k1,1 | awk 'NR <= 1800' > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$f" || { rm -f "$tmp"; return 1; }
}
