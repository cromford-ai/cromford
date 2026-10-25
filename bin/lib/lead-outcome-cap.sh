#!/bin/bash
# bin/lib/lead-outcome-cap.sh — the lead review's outcome cap (BH-6372.3,
# BH-8338). An INCONCLUSIVE claim row in a PR's evidence table is an unproven
# outcome claim. The cap writes ONE finding line that names the claims and the
# fix. It is a BLOCK only when the ticket asked for proof (the `perf-gate`
# label) or the knob says all; a perf/cost ticket without the label gets a NOTE
# and MERGE-WITH-NOTES. Sourced by bin/lead-review.sh.
#
# loc_inconclusive_rows <body-file>
#   Prints each evidence row `| claim <n>: … | INCONCLUSIVE …` (the row
#   bin/evidence-summary.sh writes). Anchored at the row start, case-sensitive,
#   and the second cell must START with INCONCLUSIVE: the settled-tier row, a
#   `REBASE_VERIFY_INCONCLUSIVE` note, prose, a blockquoted row and a CONFIRMED
#   row whose note says "inconclusive" are not rows. rc 0 = rows found, 1 = none,
#   2 = the file is unreadable.
# loc_class <ticket-file> <title> <labels-csv> [<repo> <n>]
#   Prints `perf <rule>:<evidence>` (rc 0), `no` (rc 1) or `unknown` (rc 3, the
#   reason on stderr). pt_classify on the ticket text; when that says no and the
#   ticket names a parent (`BH-<p>.<k>:` title, `Part of #<p>`), or there is no
#   ticket text at all, pt_classify_issue <repo> <n> (one read, one parent hop).
#   Unknown is never `no` (D11).
# loc_cap <verdict> <body-file> <ticket-file> <title> <labels-csv> [<repo> <n>]
#   rc 0 = capped: line 1 is the verdict to record (BLOCK or MERGE-WITH-NOTES),
#   line 2 the reason, line 3 the finding line (loc_finding). rc 1 = not capped:
#   line 1 is the verdict given. A note (perf class unknown, a bad knob value)
#   goes to stderr, one line each. With a ticket file the labels CSV is the
#   ticket's labels; with none, ONE read of #<n> gives the labels and the text.
#   Knob LEAD_REVIEW_INCONCLUSIVE_BLOCK: perf (default; BLOCK when the ticket
#   the PR closes carries the `perf-gate` label, no parent hop; else a NOTE when
#   loc_class says perf; else not capped) | all (BLOCK on any PR) | off (never).
#   Another value reads as perf.
# loc_labels <labels-csv> — rc 0 when one entry (trimmed, any case) is exactly
#   `perf-gate`, else rc 1.
# loc_finding <BLOCK|NOTE> <k> <names> <knob> — the one finding line.
# loc_demote <file>
#   Prints the file with each line that could read as a verdict line (it starts
#   with `verdict`, any case, after `#`, `>`, `*`, `_` or blanks) turned into a
#   `> ` blockquote. A capped report keeps the agent's words but its one anchored
#   verdict is the trailing `VERDICT: <capped verdict>`: bin/lib/verdict-parse.sh reads two
#   disagreeing anchored lines as no verdict at all.
# shellcheck shell=bash

[ -n "${_LOC_LIB_LOADED:-}" ] && return 0
_LOC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/lib/perf-ticket.sh
. "$_LOC_DIR/perf-ticket.sh" || return 1
_LOC_LIB_LOADED=1

# The label that makes the cap a BLOCK. A label name, not a limit: the switch
# is the knob LEAD_REVIEW_INCONCLUSIVE_BLOCK.
_LOC_GATE_LABEL=perf-gate
_LOC_ROW_RE='^\|[[:space:]]*claim[[:space:]]+[^|:]+:[^|]*\|[[:space:]]*INCONCLUSIVE([[:space:]]|$)'

loc_inconclusive_rows() {
  [ -r "${1:-}" ] || return 2
  grep -E -- "$_LOC_ROW_RE" "$1"
}

loc_class() {
  local f="${1:-}" t="${2:-}" l="${3:-}" repo="${4:-}" n="${5:-}" out rc
  if [ -n "$f" ] && [ -r "$f" ]; then
    out=$(pt_classify "$f" "$t" "$l"); rc=$?
    case "$rc" in
      0) echo "$out"; return 0 ;;
      1) if [ -z "$repo" ] || [ -z "$n" ] \
           || ! { [[ $t =~ ^BH-[0-9]+\.[0-9]+: ]] || grep -qiE 'part of #[0-9]+' "$f"; }; then
           echo no; return 1
         fi ;;
      *) echo unknown; return 3 ;;
    esac
  elif [ -z "$repo" ] || [ -z "$n" ]; then
    echo "lead-outcome-cap: no ticket text and no ticket number" >&2
    echo unknown; return 3
  fi
  out=$(pt_classify_issue "$repo" "$n"); rc=$?
  case "$rc" in
    0) echo "$out"; return 0 ;;
    1) echo no; return 1 ;;
  esac
  echo unknown; return 3
}

loc_labels() {
  local l
  local -a have=()
  IFS=, read -ra have <<< "${1:-}"
  for l in "${have[@]}"; do
    l="${l#"${l%%[![:space:]]*}"}"; l="${l%"${l##*[![:space:]]}"}"
    [ "${l,,}" = "$_LOC_GATE_LABEL" ] && return 0
  done
  return 1
}

loc_finding() {
  local tag="[NOTE]" k="${2:-0}" rs=rows rd=read bk=them tail
  [ "$k" = 1 ] && { rs=row; rd=reads; bk=it; }
  if [ "${1:-}" = BLOCK ]; then
    tag="[BLOCK wrong-data]"
    if [ "${4:-}" = all ]; then tail="This blocks: LEAD_REVIEW_INCONCLUSIVE_BLOCK=all blocks any PR with an unproven claim."
    else tail="This blocks: the ticket carries the $_LOC_GATE_LABEL label."; fi
  else tail="Not a BLOCK: the ticket has no $_LOC_GATE_LABEL label (LEAD_REVIEW_INCONCLUSIVE_BLOCK=${4:-perf})."
  fi
  printf -- '- %s outcome cap: %s claim %s in the PR body'"'"'s Evidence table %s INCONCLUSIVE (%s): no artifact line backs %s. Fix: for each claim, name the artifact line (validate.txt:<line>, a test output or a log line) in the Evidence table, then request a new review. %s\n' \
    "$tag" "$k" "$rs" "$rd" "${3:-}" "$bk" "$tail"
}

loc_cap() {
  local v="${1:-}" bf="${2:-}" knob="${LEAD_REVIEW_INCONCLUSIVE_BLOCK:-perf}" rows k names cls rc ef why d out=BLOCK
  case "$v" in MERGE|MERGE-WITH-NOTES) ;; *) printf '%s\n' "$v"; return 1 ;; esac
  rows=$(loc_inconclusive_rows "$bf") || { printf '%s\n' "$v"; return 1; }
  case "$knob" in
    off) printf '%s\n' "$v"; return 1 ;;
    all) cls="any PR" ;;
    perf) ;;
    *) echo "lead-outcome-cap: LEAD_REVIEW_INCONCLUSIVE_BLOCK='$knob' is not perf|all|off; using perf" >&2; knob=perf ;;
  esac
  k=$(grep -c . <<<"$rows")
  if [ "$knob" = perf ]; then
    ef=$(mktemp) || ef=/dev/null
    if { [ -n "${3:-}" ] && [ -r "${3:-}" ]; } || [ -z "${6:-}" ] || [ -z "${7:-}" ]; then
      if loc_labels "${5:-}"; then cls="label:$_LOC_GATE_LABEL"; rc=0
      else cls=$(loc_class "${3:-}" "${4:-}" "${5:-}" "${6:-}" "${7:-}" 2>"$ef"); rc=$?; out=MERGE-WITH-NOTES
      fi
    else
      # No ticket text: one read of #n gives the labels and the text; the
      # class (and its one parent hop) reads from that read.
      rc=3
      if { declare -F gh_rest >/dev/null || . "$_LOC_DIR/gh-rest.sh"; } && d=$(mktemp -d); then
        if _pt_read "$6" "$7" "$d" 2>"$ef"; then
          if loc_labels "$(cat "$d/l")"; then cls="label:$_LOC_GATE_LABEL"; rc=0
          else cls=$(_pt_classify_read "$6" "$7" "$d" 2>"$ef"); rc=$?; out=MERGE-WITH-NOTES
          fi
        fi
        rm -rf "$d"
      else echo "lead-outcome-cap: could not set up the ticket read" > "$ef"
      fi
    fi
    why=$(grep . "$ef" 2>/dev/null | tail -1); why="${why#perf-ticket: }"; why="${why#lead-outcome-cap: }"
    case "$why" in "unknown ("*")") why="${why#unknown (}"; why="${why%)}" ;; esac
    [ "$ef" = /dev/null ] || rm -f "$ef"
    case "$rc" in
      0) ;;
      1) printf '%s\n' "$v"; return 1 ;;
      *) echo "lead-outcome-cap: $k INCONCLUSIVE claim rows, perf class unknown (${why:-no reason given}); not capped" >&2
         printf '%s\n' "$v"; return 1 ;;
    esac
  fi
  names=$(sed -E 's/^\|[[:space:]]*(claim[[:space:]]+[^|:]+):.*/\1/; s/[[:space:]]+$//' <<<"$rows" | paste -sd, - | sed 's/,/, /g')
  printf '%s\n%s INCONCLUSIVE claim row%s (%s) on %s (LEAD_REVIEW_INCONCLUSIVE_BLOCK=%s); agent verdict %s\n' \
    "$out" "$k" "$([ "$k" = 1 ] || echo s)" "$names" "$cls" "$knob" "$v"
  if [ "$out" = BLOCK ]; then loc_finding BLOCK "$k" "$names" "$knob"; else loc_finding NOTE "$k" "$names" "$knob"; fi
  return 0
}

loc_demote() {
  awk '{ l = tolower($0) } l ~ /^[ \t#>*_]*verdict/ { print "> " $0; next } { print }' "${1:-/dev/null}"
}
