#!/bin/bash
# shellcheck shell=bash
# bin/lib/lead-gates.d/30-silence.sh — gate 9, the silence check (BH-5797),
# ported from bin/lead-review-enqueue.sh (BH-5878). It runs BEFORE 60-risk.sh,
# so a low-tier sign-off never skips it. ss_gate (bin/lib/silence-scan.sh)
# judges the head's compare:
#   human route  a public-leak allow-list line: the needs-human label and one
#                comment (ss_gate's, once per fingerprint), then rc 10 and one
#                `[skip silence]` line. No review.
#   lead route   any other allow-list line or marker: rc 0. The markers ride in
#                the review's scope notes (field silence_note, ss_note), for the
#                lead to judge, as the enqueue's request notes carried them.
#                Gate 60 signs no such head off.
# State is the enqueue's own, at the same paths: state/lead-review-enqueue/
# silence/ (the ss_gate row, the note, the scanned-<repo_>-<n>-<sha12> marker
# that stops a second scan). No check, rc 0: LEAD_REVIEW_SILENCE_CHECK=0, no
# rules file, or no bin/lib/silence-scan.sh. A compare, PR or label read that
# failed, or no harness root, is rc 11. Sourced by bin/lib/lead-gates.sh.

# shellcheck source=bin/lib/silence-scan.sh
. "${BASH_SOURCE[0]%/*}/../silence-scan.sh" 2>/dev/null || true
# shellcheck source=bin/lib/lead-gates-compare.sh
. "${BASH_SOURCE[0]%/*}/../lead-gates-compare.sh" 2>/dev/null || true

lg_gate_silence() {
  local slug="$1" n="$2" head="$3" h12="${3:0:12}" root="${HARNESS:-${H:-}}" sd mk prf rc note
  command -v ss_gate >/dev/null 2>&1 || return 0
  [ "${LEAD_REVIEW_SILENCE_CHECK:-}" = 0 ] && return 0
  if [ -z "$root" ]; then _lgt_log "no harness root; $slug#$n @$h12 held"; return 11; fi
  [ -r "${SS_RULES:-$root/catalog/silence-markers.tsv}" ] || return 0
  sd="$root/state/lead-review-enqueue/silence"
  mk="$sd/scanned-${slug//\//_}-$n-$h12"
  if [ ! -e "$mk" ]; then
    if ! command -v lgc_compare >/dev/null 2>&1 || ! lgc_compare "$slug" "$n" "$head"; then
      _lgt_log "$slug#$n @$h12: silence check: compare unreadable (rc ${LGC_RC:-none}); held"; return 11
    fi
    prf=/dev/null
    # ss_gate reads the PR's labels only for a row it labelled before.
    if [ "$(cut -f2 "$sd/${slug//\//_}-$n" 2>/dev/null)" = labelled ]; then
      prf="${LGC_FILE%.json}.pr"
      if ! gh_rest GET "repos/$slug/pulls/$n" > "$prf" 2>/dev/null; then
        _lgt_log "$slug#$n @$h12: silence check: PR labels unreadable (HTTP ${GH_REST_STATUS:-000}); held"; return 11
      fi
    fi
    rc=0; ss_gate "$slug" "$n" "$head" "$LGC_FILE" "$prf" "$sd" || rc=$?
    case "$rc" in
      0) mkdir -p "$sd" 2>/dev/null; : > "$mk" 2>/dev/null ;;
      1) _lgt_log "[skip silence] $slug#$n @$h12: needs-human; not reviewed"; return 10 ;;
      *) _lgt_log "$slug#$n @$h12: silence check unreadable (rc $rc); held"; return 11 ;;
    esac
  fi
  note=$(ss_note "$sd" "$slug" "$n" "$head")
  [ -n "$note" ] && _lgt_log "$slug#$n @$h12: silence markers for the lead to judge; they ride in the review notes"
  return 0
}

# lg_field_silence_note — the lead-route markers of this head (ss_note), if any.
lg_field_silence_note() {
  local root="${HARNESS:-${H:-}}"
  command -v ss_note >/dev/null 2>&1 && [ -n "$root" ] || return 0
  [ "${LEAD_REVIEW_SILENCE_CHECK:-}" = 0 ] && return 0
  ss_note "$root/state/lead-review-enqueue/silence" "$1" "$2" "$(printf '%s' "$3" | tr 'A-F' 'a-f')"
  return 0
}
