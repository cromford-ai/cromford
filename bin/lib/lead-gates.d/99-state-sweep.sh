#!/bin/bash
# shellcheck shell=bash
# bin/lib/lead-gates.d/99-state-sweep.sh — BH-7235: the retention of the
# worklist gates' per-head state in state/lead-review-enqueue/ (gates 15, 20,
# 30, 57, 60, 70, 78 and bin/lib/lead-gates-selfcheck.sh write it on every
# box). bin/lead-review-enqueue.sh pruned that dir, on the hub only, and
# nothing starts it since BH-7235. Gates 50 and 95 prune their own ledgers
# (delta.tsv, modes.tsv, failed-retry.tsv) on every tick, so this file leaves
# them alone. It defines no gate. Sourced by bin/lib/lead-gates.sh, never run.
#   lg_tick_state_sweep <slug>   once a process, and at most once in 24 h a box
#       (stamp state/lead-review-gates/state-sweep.stamp). The first run on a
#       box (no stamp) is a dry run: it counts and deletes nothing. A later run
#       deletes, older than LEAD_REVIEW_GATE_STATE_KEEP_DAYS:
#         the files risk-pub-* inbuild-wait-* traced-* alerted-* selfcheck-*
#         review-tier-* (-maxdepth 1) and silence/note-* silence/scanned-*;
#         the rows of risk.tsv, requested.tsv and merge-carry.tsv (gate
#         07, BH-8705). Column 1 is the epoch; a row
#         whose column 1 is not all digits is kept.
#       The window is a required registry knob (lane lead-review, default 7);
#       0 = off. A value that is not a whole number (or unset: the registry
#       was not read) deletes nothing and logs one line.
#       One audit line a run: `state-sweep: dry-run|deleted files=<n> rows=<n>
#       keep=<d>d`. No state dir = nothing, no line. Always rc 0.

declare -g _LGSS_DONE=""

# _lgss_rows <file> <cut epoch> <mode> — prints the count of rows older than
#   <cut>; in mode deleted, rewrites the file without them (<file>.tmp + mv).
#   A rewrite that fails counts 0.
_lgss_rows() {
  local f="$1" cut="$2" mode="$3" n
  [ -f "$f" ] || { echo 0; return 0; }
  n=$(awk -F'\t' -v c="$cut" '$1 ~ /^[0-9]+$/ && $1 < c' "$f" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$mode" = deleted ] && [ "${n:-0}" -gt 0 ]; then
    if ! { awk -F'\t' -v c="$cut" '!($1 ~ /^[0-9]+$/ && $1 < c)' "$f" > "$f.tmp" 2>/dev/null && mv -f "$f.tmp" "$f" 2>/dev/null; }; then
      rm -f "$f.tmp" 2>/dev/null; n=0
    fi
  fi
  echo "${n:-0}"
}

lg_tick_state_sweep() {
  local root="${HARNESS:-${H:-}}" st keep stamp mode=deleted files=0 rows=0 cut f p
  [ -n "$_LGSS_DONE" ] && return 0
  _LGSS_DONE=1
  [ -n "$root" ] || return 0
  st="$root/state/lead-review-enqueue"
  [ -d "$st" ] || return 0
  keep="${LEAD_REVIEW_GATE_STATE_KEEP_DAYS:-}"
  if ! [[ "$keep" =~ ^[0-9]{1,4}$ ]]; then
    _lgt_log "state-sweep: LEAD_REVIEW_GATE_STATE_KEEP_DAYS='$keep' is not a whole number; nothing deleted"
    return 0
  fi
  [ "$keep" = 0 ] && return 0
  stamp="$root/state/lead-review-gates/state-sweep.stamp"
  if [ ! -e "$stamp" ]; then mode=dry-run
  elif [ -n "$(find "$stamp" -mmin -1440 2>/dev/null)" ]; then return 0; fi
  while IFS= read -r -d '' f; do
    if [ "$mode" = dry-run ]; then files=$((files + 1)); else rm -f -- "$f" 2>/dev/null && files=$((files + 1)); fi
  done < <(find "$st" -maxdepth 1 -type f \( -name 'risk-pub-*' -o -name 'inbuild-wait-*' -o -name 'traced-*' \
             -o -name 'alerted-*' -o -name 'selfcheck-*' -o -name 'review-tier-*' \) -mmin +$((keep * 1440)) -print0 2>/dev/null
           find "$st/silence" -maxdepth 1 -type f \( -name 'note-*' -o -name 'scanned-*' \) -mmin +$((keep * 1440)) -print0 2>/dev/null)
  cut=$(( $(date +%s) - keep * 86400 ))
  for p in risk.tsv requested.tsv merge-carry.tsv; do
    rows=$((rows + $(_lgss_rows "$st/$p" "$cut" "$mode")))
  done
  mkdir -p "${stamp%/*}" 2>/dev/null && : > "$stamp" 2>/dev/null
  _lgt_log "state-sweep: $mode files=$files rows=$rows keep=${keep}d"
  return 0
}
