#!/bin/bash
# bin/lib/triage-board-pages.sh — the paged OPEN ai-build issue read behind the
# GitHub-Issues board fingerprint (bin/triage-gate.sh fetch_fingerprint).
# Sourced, never executed.
#
# WHY (BH-8497). The fingerprint read ONE page of `state=all` (100 rows). On a
# board with more ai-build issues than that, the page held the newest 100, and
# an old open ticket was not in the fingerprint at all: project-6-os had 131
# open and triage saw 13. This reads every page of `state=open` up to a cap.
#
# Each page is its own gh_rest GET, so each page has its own ETag cache entry
# (`page` is in the args the key hashes): an unchanged board answers 304s.
#
# A PARTIAL LIST IS NEVER RETURNED AS FACT (the bin/lib/gh-rest-list.sh rule).
# Any page that answers non-zero, or a 2xx body that is not an array, fails the
# whole read and writes nothing. The one exception is the cap: when the last
# page the cap allows is full, the rows read are returned with TBP_CAPPED=1, and
# the caller writes the ALERT (_tbp_alert). That is a known, named truncation.
#
# No `set -e`, no `exit`, no side effect at source time.
if [ -n "${TRIAGE_BOARD_PAGES_LIB:-}" ]; then return 0 2>/dev/null; fi
TRIAGE_BOARD_PAGES_LIB=1
# shellcheck source=bin/lib/gh-rest.sh
if ! command -v gh_rest >/dev/null 2>&1; then
  . "$(dirname "${BASH_SOURCE[0]}")/gh-rest.sh" 2>/dev/null || return 0 2>/dev/null
fi
# The page GET goes through the tracker seam's GitHub Issues adapter (BH-7919
# ratchet: no script outside the allowlist calls the issues API directly).
# shellcheck source=bin/lib/tracker/github-issues.sh
if ! command -v trk_gh_issue_page >/dev/null 2>&1; then
  . "$(dirname "${BASH_SOURCE[0]}")/tracker/github-issues.sh" 2>/dev/null || return 0 2>/dev/null
fi

# tbp_issue_pages <slug> <max_pages> <outfile> — every open ai-build issue (PRs
# included, as /issues returns them; the caller filters) as ONE JSON array in
# <outfile>. rc 0 = the list. Any other rc = no list (outfile removed). Sets
# TBP_CAPPED (1 when page <max_pages> was full) and TBP_SEEN (rows read).
tbp_issue_pages() {
  local slug="${1:-}" max="${2:-}" out="${3:-}" pg=1 rc n raw acc
  TBP_CAPPED=0; TBP_SEEN=0
  [ -n "$slug" ] && [ -n "$out" ] || return 75
  case "$max" in ''|*[!0-9]*|0) return 75 ;; esac
  raw=$(mktemp "${TMPDIR:-/tmp}/tbp.XXXXXX") || return 75
  acc=$(mktemp "${TMPDIR:-/tmp}/tbp.XXXXXX") || { rm -f "$raw"; return 75; }
  printf '[]' > "$acc"
  rm -f "$out"
  while [ "$pg" -le "$max" ]; do
    rc=0
    # `> file`, never `$( )`: the status has to survive into this shell.
    TRK_SLUG="$slug" trk_gh_issue_page "$pg" > "$raw" || rc=$?
    if [ "$rc" != 0 ]; then rm -f "$raw" "$acc"; return "$rc"; fi
    n=$(jq 'if type == "array" then length else -1 end' "$raw" 2>/dev/null)
    case "$n" in ''|-1|*[!0-9]*) rm -f "$raw" "$acc"; return 75 ;; esac
    # Merged through FILES, never argv: a page with bodies is large.
    jq -c -s '.[0] + .[1]' "$acc" "$raw" > "$acc.t" 2>/dev/null && mv -f "$acc.t" "$acc" \
      || { rm -f "$raw" "$acc" "$acc.t"; return 75; }
    TBP_SEEN=$((TBP_SEEN + n))
    # A short page is the last page. A PR row counts toward the 100 here: the
    # page is full as GitHub sent it, whatever the caller filters later.
    [ "$n" -lt 100 ] && break
    [ "$pg" -eq "$max" ] && { TBP_CAPPED=1; break; }
    pg=$((pg + 1))
  done
  rm -f "$raw"
  mv -f "$acc" "$out" || { rm -f "$acc"; return 75; }
  return 0
}

# tbp_max_pages <project> — the page cap. Settings row
# lib.triage-state.<project>.triage_state_board_max_pages (then
# lib.triage-state.triage_state_board_max_pages), env TRIAGE_STATE_BOARD_MAX_PAGES.
# Code fallback 20 (2000 open issues). Unset or junk is 20; clamped to 1..100.
tbp_max_pages() {
  local v="${TRIAGE_STATE_BOARD_MAX_PAGES:-}" lg
  if [ -z "$v" ]; then
    lg="$(dirname "${BASH_SOURCE[0]}")/lane-gate.sh"
    v=$( if ! command -v lib_env_apply >/dev/null 2>&1; then
           # shellcheck source=bin/lib/lane-gate.sh
           [ -r "$lg" ] && . "$lg" >/dev/null 2>&1
         fi
         command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply triage-state "${1:-}" >/dev/null 2>&1
         printf '%s' "${TRIAGE_STATE_BOARD_MAX_PAGES:-}" ) 2>/dev/null
  fi
  case "$v" in ''|*[!0-9]*) v=20 ;; esac
  [ "$v" -lt 1 ] && v=1
  [ "$v" -gt 100 ] && v=100
  printf '%s' "$v"
}

# _tbp_alert <project> <seen> <max_pages> — ONE ALERTS line per project per UTC
# day when the cap cut the read, through bin/alert-line.sh. The day flag goes
# through bin/lib/flags.sh (flag_has --cached / flag_set; the file
# flags/alerted-triage-board-cap-<project>-<YYYYMMDD>), set before the line;
# bin/alerts-groom.sh prunes old alerted-* days. No flags lib, no ALERT: a line
# that cannot be deduplicated would repeat on every tick.
_tbp_alert() {
  local h="${HARNESS:-${H:-}}" flag
  [ -n "$h" ] || return 1
  # shellcheck source=bin/lib/flags.sh
  command -v flag_set >/dev/null 2>&1 || HARNESS="$h" . "$(dirname "${BASH_SOURCE[0]}")/flags.sh" 2>/dev/null
  command -v flag_set >/dev/null 2>&1 || return 1
  flag="alerted-triage-board-cap-$(printf '%s' "${1:-}" | tr -c 'A-Za-z0-9._-' '_')-$(date -u +%Y%m%d)"
  flag_has --cached "$flag" 2>/dev/null && return 0
  flag_set "$flag" on "triage: board page cap alert sent" >/dev/null 2>&1
  HARNESS="$h" "$h/bin/alert-line.sh" --id "triage-board-cap:$1" --project "$1" \
    "[run-triage] $1: triage board snapshot hit the page cap ($3 pages, $2 open ai-build issues read); raise lib.triage-state.$1.triage_state_board_max_pages" \
    >/dev/null 2>&1 || true
  return 0
}
