#!/bin/bash
# bin/lib/prr-shadow.d/scheduler.sh — the prr-shadow seam of lane scheduler (BH-10218 W4).
# Sourced by bin/scheduler.sh (prr_seam_load scheduler), never executed.
#
# The knob GH_SOURCE (settings row lane.scheduler.gh_source, default shadow)
# is registered in catalog/lanes.d/scheduler.knobs.d/. One read moves: the
# stack parent lookup sw_parent_pr <slug> <branch> (bin/lib/stack-wait.sh,
# not edited), one REST `pulls?state=all&head=<owner>:<branch>` per parent.
#
#   sched_parent_record <file> <owner/repo> <branch>
#       From the PR record's trusted open list (pr_record_list <repo> open
#       <tmp> head_ref, the whole list: truncated is a miss). An open PR whose
#       head_ref is <branch> answers `open <n> <url>` (the highest number,
#       sw_parent_pr's "open wins" rule). A branch that is not in the open list
#       is the miss field:head: merged, closed or absent is only known to
#       GitHub's state=all read, and the record's merged and closed lists are
#       windows, so "not found" there would be wrong data. A list miss prints
#       pr_record_list's word. rc 1 on any miss; no lib is `unreadable`.
#   sched_parent_github <file> <owner/repo> <branch>
#       Today's read: sw_parent_pr's line into <file>. rc 75 when that line is
#       `unreadable ...` or `unchecked` (so no compare is made), else 0. The
#       line is in <file> either way, so the lane reads it as before.
#   sched_parent_norm <file>
#       [{n, s: state}] for an open|merged|closed line, else [].
#
# BH-10351, the parent memo. Before it, the same 7 parent branches of
# cromford (no open PR: 3 merged, 4 never had one) read GitHub on every
# tick, 70 reads an hour, with no change behind any of them.
#   sched_parent_note <file> <github-rc> <why> <owner/repo> <branch>
#       prr_read's write-back (step record, after a miss). Only for the miss
#       field:head and a GitHub answer `none`, `merged <n> <url>` or
#       `closed <n> <url>`: it writes one memo row (owner/repo, branch,
#       fingerprint, answer). The fingerprint is the record's closed and
#       merged rows of the branch (tsp_ref_states, one jobs GET):
#       `<n>:<state>` sorted and comma-joined, `-` for none. A failed refs
#       read, an `open` answer (the record lacks an open PR GitHub has) or any
#       other answer writes nothing.
#   sched_parent_record, after field:head: a memo row of the branch whose
#       fingerprint is today's answers it (rc 0). The answer can change only
#       when a PR of the branch opens (then the open list holds it) or closes
#       or merges (then the fingerprint changes): a change mark from the
#       record, never an age. A memo row whose fingerprint moved, or no row,
#       is the miss field:head as before.
#   sched_parent_memo_gc <owner/repo> <branches-file>
#       bin/scheduler.sh, once per project tick: the memo keeps only that
#       repo's rows whose branch is in <branches-file> (this tick's parent
#       branches). An unreadable file keeps every row.
# The memo is state/prr-memo/scheduler-parents.tsv (catalog/state-paths.d/10351-prr-memo.json),
# written tmp + mv. Losing it costs one GitHub read per parent branch.
if ! command -v pr_record_list >/dev/null 2>&1 && [ -r "${BASH_SOURCE[0]%/*}/../pr-record.sh" ]; then
  # shellcheck source=bin/lib/pr-record.sh
  . "${BASH_SOURCE[0]%/*}/../pr-record.sh"
fi
if ! command -v tsp_ref_states >/dev/null 2>&1 && [ -r "${BASH_SOURCE[0]%/*}/tickets-snapshot-push.sh" ]; then
  # shellcheck source=bin/lib/prr-shadow.d/tickets-snapshot-push.sh
  . "${BASH_SOURCE[0]%/*}/tickets-snapshot-push.sh"
fi

sched_parent_record() {
  local f="${1:-}" repo="${2:-}" br="${3:-}" tmp why rc=0 line
  [ -n "$f" ] && [ -n "$br" ] || return 2
  command -v pr_record_list >/dev/null 2>&1 || { echo unreadable; return 1; }
  tmp=$(mktemp "${TMPDIR:-/tmp}/sched-parent.XXXXXX") || { echo unreadable; return 1; }
  why=$(pr_record_list "$repo" open "$tmp" head_ref) || rc=$?
  if [ "$rc" != 0 ]; then rm -f "$tmp" "$tmp.sync"; echo "${why:-unreadable}"; return 1; fi
  line=$(jq -r --arg b "$br" '[.[] | select(.head_ref == $b)] | sort_by(.number) | last
          | if . == null then "" else "open \(.number) \(.url // "")" end' "$tmp" 2>/dev/null) || line=""
  rm -f "$tmp" "$tmp.sync"
  if [ -z "$line" ]; then
    : > "$f"
    line=$(_sched_memo_hit "$repo" "$br") && [ -n "$line" ] && { printf '%s\n' "$line" > "$f"; return 0; }
    echo field:head; return 1
  fi
  printf '%s\n' "$line" > "$f"
}

_sched_memo_file() {
  local root="${HARNESS:-${H:-}}"
  [ -n "$root" ] || return 1
  printf '%s/state/prr-memo/scheduler-parents.tsv\n' "$root"
}

# _sched_refs_fp <owner/repo> <branch> — the fingerprint on stdout, rc 1 when
# the record refs read missed.
_sched_refs_fp() {
  local t fp
  command -v tsp_ref_states >/dev/null 2>&1 || return 1
  t=$(mktemp "${TMPDIR:-/tmp}/sched-refs.XXXXXX") || return 1
  if ! tsp_ref_states "$t" "$1" "$2" >/dev/null 2>&1; then rm -f "$t"; return 1; fi
  fp=$(jq -r --arg b "$2" '[.[] | select(.head_ref == $b) | "\(.number):\(.state)"] | sort
        | if length > 0 then join(",") else "-" end' "$t" 2>/dev/null)
  rm -f "$t"
  [ -n "$fp" ] || return 1
  printf '%s\n' "$fp"
}

# _sched_memo_hit <owner/repo> <branch> — the memo answer when its
# fingerprint is today's, else nothing and rc 1.
_sched_memo_hit() {
  local mf row fp
  mf=$(_sched_memo_file) || return 1
  [ -s "$mf" ] || return 1
  row=$(awk -F'\t' -v r="$1" -v b="$2" '$1 == r && $2 == b {x = $3 "\t" $4} END {if (x != "") print x}' "$mf" 2>/dev/null)
  [ -n "$row" ] || return 1
  fp=$(_sched_refs_fp "$1" "$2") || return 1
  [ "$fp" = "${row%%$'\t'*}" ] || return 1
  printf '%s\n' "${row#*$'\t'}"
}

sched_parent_note() {
  local f="${1:-}" grc="${2:-}" why="${3:-}" repo="${4:-}" br="${5:-}" line fp mf
  [ "$grc" = 0 ] && [ "$why" = field:head ] && [ -n "$repo" ] && [ -n "$br" ] || return 0
  line=$(head -1 "$f" 2>/dev/null)
  [[ "$line" =~ ^(none|merged\ [0-9]+\ [^[:space:]]*|closed\ [0-9]+\ [^[:space:]]*)$ ]] || return 0
  [[ "$br" =~ ^[^[:space:]]+$ ]] || return 0
  fp=$(_sched_refs_fp "$repo" "$br") || return 0
  mf=$(_sched_memo_file) || return 0
  mkdir -p "${mf%/*}" 2>/dev/null || return 0
  { awk -F'\t' -v r="$repo" -v b="$br" '!($1 == r && $2 == b)' "$mf" 2>/dev/null
    printf '%s\t%s\t%s\t%s\n' "$repo" "$br" "$fp" "$line"; } > "$mf.tmp.$$" 2>/dev/null \
    && mv -f "$mf.tmp.$$" "$mf" 2>/dev/null
  rm -f "$mf.tmp.$$" 2>/dev/null
  return 0
}

sched_parent_memo_gc() {
  local mf
  mf=$(_sched_memo_file) || return 0
  [ -s "$mf" ] && [ -r "${2:-}" ] || return 0
  # -v keys, not a two-file NR == FNR: an empty branches file must drop only
  # this repo's rows.
  awk -F'\t' -v r="${1:-}" -v keys="$(tr '\n' '\t' < "$2")" \
    'BEGIN {n = split(keys, a, "\t"); for (i = 1; i <= n; i++) if (a[i] != "") k[a[i]] = 1}
     $1 != r || ($2 in k)' "$mf" > "$mf.tmp.$$" 2>/dev/null \
    && mv -f "$mf.tmp.$$" "$mf" 2>/dev/null
  rm -f "$mf.tmp.$$" 2>/dev/null
  return 0
}

sched_parent_github() {
  local out
  out=$(sw_parent_pr "${2:-}" "${3:-}")
  printf '%s\n' "$out" > "${1:-/dev/null}"
  case "$out" in unreadable*|unchecked|'') return 75 ;; esac
  return 0
}

sched_parent_norm() {
  local s n
  read -r s n _ < "${1:-/dev/null}" 2>/dev/null || { echo '[]'; return 0; }
  case "$s:$n" in
    open:[0-9]*|merged:[0-9]*|closed:[0-9]*) jq -nc --arg s "$s" --argjson n "$n" '[{n: $n, s: $s}]' ;;
    *) echo '[]' ;;
  esac
}
