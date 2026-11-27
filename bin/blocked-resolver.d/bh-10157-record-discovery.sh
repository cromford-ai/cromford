# shellcheck shell=bash
# bin/blocked-resolver.d/bh-10157-record-discovery.sh — BH-10157 (BH-9937 C1,
# BH-9926 wave 5): two of the resolver's discovery reads move onto the PR
# record.
#
# THE STEP. The knob GH_SOURCE (settings row lane.blocked-resolver.gh_source,
# catalog/lanes.d/blocked-resolver.knobs.d/GH_SOURCE.json, default shadow) is
# resolved ONCE, when this file is sourced, by prr_pin (bin/lib/prr-shadow.sh).
# Each prr_read call below then reads the pinned $GH_SOURCE, with no settings
# read:
#   off     GitHub only: today's reads, 0 jobs reads.
#   shadow  the lane acts on GitHub, and a record answer that differs writes
#           one PRR_SHADOW line in logs/prr-shadow.log.
#   record  the record. A miss reads GitHub and logs PRR_MISS.
# The record side is the seam bin/lib/prr-shadow.d/blocked-resolver.sh
# (brs_*). The GitHub side is here (brd_open_github, brd_state_array,
# brd_state_rest).
#
# TWO READS MOVE.
#   1. br_open_prs (driver): the repo's open list. brd_open_read.
#   2. bcr_load_one / bcr_is_closed (bh-9369 fragment): in step record no
#      closed-list page is read (brd_closed_pages_off), and the state of a
#      candidate row's PR comes from the record: one peek per row whose PR is
#      not in the open list, not a rebuild-* row, of a repo this run loaded
#      (brd_row_word). A peek miss reads pulls/<n> once. In step shadow the
#      lane acts on this tick's closed pages, and the record is compared.
# The per-PR reviews read of br_from_reviews stays on GitHub in every step.
#
# FAIL OPEN. With no bin/lib/prr-shadow.sh, or no seam, _brd_on is rc 1 and
# every brd_* function does today's read. BR_OPT_OFF=bh-10157-record-discovery
# does not source this file: each hook is then `command -v` false.
# Call sites, one guarded line each: br_open_prs (brd_open_read), and in the
# bh-9369 fragment bcr_load_one (brd_closed_pages_off) and bcr_is_closed
# (brd_row_word).
if [ -n "${H:-}" ] && [ -r "$H/bin/lib/prr-shadow.sh" ]; then
  # shellcheck source=bin/lib/prr-shadow.sh
  . "$H/bin/lib/prr-shadow.sh"
fi
if command -v prr_seam_load >/dev/null 2>&1 && prr_seam_load blocked-resolver \
   && command -v prr_read >/dev/null 2>&1 && command -v brs_open_record >/dev/null 2>&1; then
  declare -F prr_pin >/dev/null && prr_pin blocked-resolver
fi

# _brd_on — rc 0 when the lib and the seam are loaded (the record can be read).
_brd_on() {
  command -v prr_read >/dev/null 2>&1 && command -v prr_step >/dev/null 2>&1 \
    && command -v brs_open_record >/dev/null 2>&1 && command -v brs_state_record >/dev/null 2>&1
}

# brd_open_github <file> <owner/repo> — today's open-list read.
brd_open_github() {
  harness_pr_list "${2:-}" open number,url,headRefOid,headRefName,baseRefName,isDraft,updatedAt > "${1:-/dev/null}" 2>/dev/null
}

# brd_open_read <owner/repo> — the open list on stdout, from the source the
#   step names. rc is the rc of the source whose value is printed.
brd_open_read() {
  local slug="${1:-}" f rc
  _brd_on && f=$(mktemp "${TMPDIR:-/tmp}/brd-open.XXXXXX") \
    || { harness_pr_list "$slug" open number,url,headRefOid,headRefName,baseRefName,isDraft,updatedAt 2>/dev/null; return $?; }
  prr_read blocked-resolver "$slug#open" "$f" brs_open_record brd_open_github brs_open_norm "$slug"; rc=$?
  [ "$rc" = 0 ] && cat "$f"
  rm -f "$f"
  return "$rc"
}

# brd_closed_pages_off — rc 0 in step record: bcr_load_one reads no page of
#   the closed list, and the stored set and the watermark stay.
brd_closed_pages_off() { _brd_on && [ "$(prr_step blocked-resolver)" = record ]; }

# brd_state_array <file> <owner/repo> <number> — the GitHub side of a row's
#   state in step shadow: the word this tick's closed pages gave
#   ($_BRD_ARRAY_WORD), no API call. state none = no page listed the PR.
brd_state_array() {
  jq -nc --argjson n "${3:-0}" --arg s "${_BRD_ARRAY_WORD:-none}" '{number: $n, state: $s}' > "${1:-/dev/null}" 2>/dev/null
}

# brd_state_rest <file> <owner/repo> <number> — the GitHub side in step
#   record, on a record miss only: one pulls/<n> read.
brd_state_rest() {
  local f="${1:-}" slug="${2:-}" n="${3:-}" rc=0
  command -v gh_rest >/dev/null 2>&1 || return 1
  # A plain call into a file (tests/gh-rest-no-subshell-lint.sh): inside $( )
  # the helper's GH_REST_STATUS and GH_REST_REASON die with the subshell.
  gh_rest GET "repos/$slug/pulls/$n" > "$f.body" 2>/dev/null || rc=$?
  if [ "$rc" != 0 ]; then rm -f "$f.body"; return "$rc"; fi
  jq -ce --argjson n "$n" 'select(type == "object" and (.state | type) == "string")
      | {number: $n, state: (if .merged_at != null then "merged" else .state end),
         at: ((.merged_at // .closed_at // .updated_at) // "")}' "$f.body" > "$f" 2>/dev/null || rc=1
  rm -f "$f.body"
  return "$rc"
}

# brd_row_word <pr url> <closed-pages word> — the row's state word for
#   bcr_is_closed. $_BRD_WORD is merged, closed or empty; $_BRD_ROW_AT is an
#   ISO time when the word came from the record or pulls/<n> (empty else).
#   off: the closed-pages word, no call. shadow: the closed-pages word, plus
#   one peek and a compare. record: the record; a miss reads pulls/<n>.
#   Called after the url, open-veto and rebuild-* checks, so a PR in the open
#   list is never peeked.
brd_row_word() {
  local url="${1:-}" w="${2:-}" step slug n f gfn rc s at
  _BRD_WORD="$w"; _BRD_ROW_AT=""
  _brd_on || return 0
  step=$(prr_step blocked-resolver)
  [ "$step" != off ] || return 0
  [[ "$url" =~ ^https://github\.com/([^/]+/[^/]+)/pull/([1-9][0-9]*)$ ]] || return 0
  slug="${BASH_REMATCH[1]}"; n="${BASH_REMATCH[2]}"
  f=$(mktemp "${TMPDIR:-/tmp}/brd-state.XXXXXX") || return 0
  gfn=brd_state_array; [ "$step" = record ] && gfn=brd_state_rest
  _BRD_ARRAY_WORD="$w" prr_read blocked-resolver "$slug#$n@state" "$f" brs_state_record "$gfn" brs_state_norm "$slug" "$n"; rc=$?
  if [ "$step" = record ]; then
    _BRD_WORD=""
    if [ "$rc" = 0 ]; then
      s=$(jq -r '.state // ""' "$f" 2>/dev/null)
      case "$s" in
        merged|closed)
          _BRD_WORD="$s"
          at=$(jq -r '.at // ""' "$f" 2>/dev/null)
          case "$at" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T*Z) ;; *) at=$(date -u '+%Y-%m-%dT%H:%M:%SZ') ;; esac
          _BRD_ROW_AT="${at%%.*}"; [[ "$_BRD_ROW_AT" == *Z ]] || _BRD_ROW_AT="${_BRD_ROW_AT}Z" ;;
      esac
    fi
  fi
  rm -f "$f"
  return 0
}

