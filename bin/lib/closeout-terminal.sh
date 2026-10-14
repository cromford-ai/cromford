#!/bin/bash
# bin/lib/closeout-terminal.sh — is a build record still owed a board close-out?
#
# Two lanes ask the same question and used to answer it differently.
# bin/pipeline-health.sh checks 4 and 5 counted every uncommented RESULT older
# than an hour as a debt, with no ceiling and no consult of the ledger, so a
# July record paged every TTL window forever (398 project-1 records, oldest at
# 652h, plus three EMPTY-URL dirs from July and August). bin/sweep-stale-builds.sh
# had no notion of "the ledger already says this build is over" at all.
#
# Two answers live here, and both lanes use them:
#   TERMINAL — the ticket's PR is merged, or was closed unmerged, or the dir
#     carries a SUPERSEDED marker. Nobody owes a close-out on work that is over.
#   AGED OUT — the RESULT is older than CLOSEOUT_AGE_OUT_H (default 168h). Not a
#     verdict about the work, a verdict about the alert: a page nobody acted on
#     in a week is not going to be acted on now.
#
# AN OUTAGE IS NOT TERMINAL. job_ledger_get and job_pr_facts both answer rc 1
# for "the API is unusable" and rc 2 for "no such row". Neither is terminal
# here: fail-open means keep alerting. A helper that went quiet when the
# coordination DB blinked would hide the exact wedge these checks exist to find.
#
# AGE-OUT IS RECORDED, NOT SILENT. closeout_record_aged appends one row per
# build dir to state/closeout-aged-out.tsv (project, build dir, RESULT first
# line, reason) so the count in the summary line can be read back. The file is a
# set keyed on the build dir: re-running adds nothing.
#
# AND THE SET LIVES IN THE DATABASE (BH-1033). Precisely what the tsv is, and
# what it is not: it is the AUDIT set — which dirs the fleet has already decided
# are too old to page about — and it is NOT the paging gate. Nothing reads it to
# decide whether to alert: bin/pipeline-health.sh:190 compares the RESULT's own
# mtime against CLOSEOUT_AGE_S and `continue`s, and that is unchanged by this
# slice. So losing the file does not page anything; it loses the RECORD of the
# decision, and the next sweep re-appends a row for every aged dir still under
# builds/ — an audit refill.
#
# What the table changes is that the set stops being one box's file. A box
# rebuild, a state restore, a rotation or an operator clearing the tsv no longer
# erases which records the fleet aged out, and the write-through below stops
# (rc 3, "already recorded") rather than growing the file back. It is also
# fleet-wide where the file is per box, so a dir relayed between boxes is one
# decision rather than two. With the flag off, or the worker unreachable, this
# file is the whole mechanism exactly as it has been.
#
# THE DEDUPE READ IS ONE PROCESS, NOT A PIPELINE (BH-1044 fix round). It used to
# be `cut -f2 "$tsv" | grep -qxF "$dir"`. grep exits at the first match, so on a
# file bigger than the 64 KB pipe buffer cut died of SIGPIPE, and bin/
# pipeline-health.sh runs `set -uo pipefail`, which the subshell inherits: the
# pipeline returned 141, the `&& exit 0` was not taken and the row was appended
# AGAIN. Every 10 minutes, for every dir recorded near the top of the file. That
# is what grew the hub's copy to 45 MB. awk reads the file itself, so there is no
# pipe to break and rc is the answer to the question.
#
# Pure bash, set -u safe, no writes except the audit append.

# closeout_pr_url <RESULT first line> — the PR url on that line, or nothing.
# Covers "PR_CREATED <url>", "PR_MERGED <url>" and any other shape that carries
# one; a line with no url prints nothing and the caller does no lookup.
closeout_pr_url() {
  printf '%s' "${1:-}" \
    | grep -oE 'https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/pull/[0-9]+' \
    | head -1
}

# closeout_terminal <pr-url> <build-dir> — prints the terminal status and
# returns 0, or returns 1 for "still owed a close-out, or unknown".
#   pr_merged   the merge ledger says merged, or the PR facts carry a merge_sha
#   superseded  the merge sweep recorded the PR closed unmerged, or the build
#               dir carries a SUPERSEDED marker (what bin/remediations/
#               health-uncommented.sh already treats as an end state)
#   abandoned   the merge ledger says so. Nothing writes that status through a
#               PR url today; the branch exists so the vocabulary matches the
#               one the console build rows use, and costs one case arm.
# Either argument may be empty. A missing jobs-client means no lookup and rc 1.
closeout_terminal() {
  local url="${1:-}" dir="${2:-}" st row sha
  if [ -n "$dir" ] && [ -f "$dir/SUPERSEDED" ]; then printf 'superseded'; return 0; fi
  [ -n "$url" ] || return 1
  if type job_ledger_get >/dev/null 2>&1; then
    if st=$(job_ledger_get merge "$url" 2>/dev/null); then
      case "$st" in
        merged)    printf 'pr_merged';  return 0 ;;
        closed)    printf 'superseded'; return 0 ;;
        abandoned) printf 'abandoned';  return 0 ;;
      esac
    fi
  fi
  if type job_pr_facts >/dev/null 2>&1; then
    if row=$(job_pr_facts "$url" 2>/dev/null); then
      sha=$(printf '%s' "$row" | cut -f5)
      case "$sha" in ''|'-') ;; *) printf 'pr_merged'; return 0 ;; esac
    fi
  fi
  return 1
}

# closeout_age_out_s — the age ceiling in seconds. CLOSEOUT_AGE_OUT_H is a hub
# knob in env/global.env; a non-numeric value is a typo, not an instruction, so
# it falls back to the documented 168h rather than disabling the check.
closeout_age_out_s() {
  local h="${CLOSEOUT_AGE_OUT_H:-168}"
  case "$h" in ''|*[!0-9]*) h=168 ;; esac
  printf '%s' $(( h * 3600 ))
}

# closeout_record_aged <tsv> <lock> <project> <build-dir> <RESULT first line> <reason>
# Appends one row if this build dir is not already recorded. The read and the
# append happen under the same short flock — a few milliseconds on a local file,
# never held across a network call — so two overlapping pipeline-health runs
# cannot both decide the row is missing. Failure to append is not fatal: the dir
# is still counted as aged out this run and the row is re-attempted next run,
# because nothing here is a done-stamp.
closeout_record_aged() {
  local tsv="${1:-}" lock="${2:-}" proj="${3:-}" dir="${4:-}" line="${5:-}" reason="${6:-}" rc
  [ -n "$tsv" ] && [ -n "$dir" ] || return 1
  line=$(printf '%s' "$line" | tr '\t\n' '  ')
  reason=$(printf '%s' "$reason" | tr '\t\n' '  ')
  # >>> closeout aged rows (BH-1033; tests/closeout-aged-table-test.sh drives this)
  # THE DEDUPE MOVES TO THE TABLE, and only the dedupe. The tsv is still written
  # for the whole transition — but it is a file on one box, and the moment it is
  # lost (a rebuild, a restore, a rotation, an operator clearing it) the fleet
  # forgets which records it has already aged out and this sweep re-appends a
  # row for every aged dir still under builds/. Not an alert storm — the alert
  # decision is the RESULT's mtime and this lane never reads the file for it —
  # but a decision the fleet has already made must not be unmade by a missing
  # file, and the audit is the only place it is written down.
  #
  # rc 3 from the put is "already recorded", which is the whole point: it stops
  # the append below, so an emptied tsv is not refilled and the set stays what
  # the fleet decided. rc 0 is a NEW decision and the file is written to match.
  # ANY OTHER rc — flag off, no client, an outage — leaves the tsv path below
  # exactly as it has always been, because keeping the alert is the fail-open
  # direction here.
  if type closeout_aged_table_on >/dev/null 2>&1 && closeout_aged_table_on \
     && type closeout_aged_put >/dev/null 2>&1; then
    closeout_aged_put "$proj" "$dir" "$line" "$reason" >/dev/null 2>&1; rc=$?
    [ "$rc" = 3 ] && return 0
  fi
  # <<< closeout aged rows
  mkdir -p "$(dirname "$tsv")" 2>/dev/null
  ( if [ -n "$lock" ] && command -v flock >/dev/null 2>&1; then
      mkdir -p "$(dirname "$lock")" 2>/dev/null
      exec 9>"$lock" 2>/dev/null && flock -w 5 9 2>/dev/null
    fi
    [ -f "$tsv" ] || : > "$tsv"
    awk -F'\t' -v d="$dir" '$2 == d { seen = 1; exit } END { exit !seen }' \
      "$tsv" 2>/dev/null && exit 0
    printf '%s\t%s\t%s\t%s\n' "$proj" "$dir" "$line" "$reason" >> "$tsv" )
}

# >>> closeout skip set (BH-5941)
# NOT READ AGAIN. Checks 4 and 5 of bin/pipeline-health.sh used to visit every
# aged dir on every tick: a stat, a head, a grep, a fork of
# bin/queued-fly-relayed.sh and a closeout_record_aged call (an awk over the
# audit tsv and, with the BH-1033 flag on, a worker call answering rc 3). On
# project-1 that was 386 dirs every ten minutes, to reach the same answer.
#
# The skip set is one file per project, state/pipeline-health/<p>/closeout-aged.tsv,
# one line per decided dir: dir<TAB>RESULT mtime<TAB>kind (aged | emptyurl). A
# dir is skipped only while its RESULT mtime is the one recorded AND that mtime
# is still past the current ceiling: a rewritten RESULT or a raised
# CLOSEOUT_AGE_OUT_H is judged again. A line is written only after
# closeout_record_aged returned 0, so a failed record is retried next tick.
# Everything here fails open: a lost or junk file means the dirs are judged once
# more, which is the cost of one tick as it was before.
#
# Pure bash and one stat. The caller passes the harness root; nothing here
# defaults it.

# closeout_skip_file <harness> <project> — the project's skip file path.
closeout_skip_file() {
  [ -n "${1:-}" ] && [ -n "${2:-}" ] || return 1
  printf '%s/state/pipeline-health/%s/closeout-aged.tsv' "$1" "$2"
}

# closeout_mtimes <RESULT path or glob>... — fills CO_MT[<build dir>]=<mtime>
# with ONE stat. A glob that matched nothing reaches stat as itself and fails
# for that argument only, so stat's rc is not read.
closeout_mtimes() {
  declare -gA CO_MT=()
  local t n
  [ "$#" -gt 0 ] || return 0
  while IFS=$'\t' read -r t n; do
    [ -n "$n" ] || continue
    n="${n%/RESULT}"
    CO_MT["${n##*/}"]="$t"
  done < <(stat -c $'%Y\t%n' -- "$@" 2>/dev/null)
  return 0
}

# closeout_skip_load <file> — fills CO_SKIP[<dir>]="<mtime><TAB><kind>". A line
# with no dir, a non-numeric mtime or an unknown kind is ignored. No file, an
# empty set.
closeout_skip_load() {
  declare -gA CO_SKIP=()
  local f="${1:-}" d m k
  [ -n "$f" ] && [ -r "$f" ] || return 0
  while IFS=$'\t' read -r d m k || [ -n "$d" ]; do
    [ -n "$d" ] || continue
    case "$m" in ''|*[!0-9]*) continue ;; esac
    case "$k" in aged|emptyurl) ;; *) continue ;; esac
    CO_SKIP["$d"]="$m"$'\t'"$k"
  done < "$f"
  return 0
}

# closeout_skip_hit <dir> <now> <age-s> — prints the kind and returns 0 when the
# dir is in the set, its RESULT mtime is the recorded one, and that mtime is
# still older than <age-s>. Anything else is rc 1: judge the dir.
closeout_skip_hit() {
  local d="${1:-}" now="${2:-}" age="${3:-}" e m
  [ -n "$d" ] || return 1
  declare -p CO_SKIP >/dev/null 2>&1 && declare -p CO_MT >/dev/null 2>&1 || return 1
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  case "$age" in ''|*[!0-9]*) return 1 ;; esac
  e="${CO_SKIP[$d]:-}"; [ -n "$e" ] || return 1
  m="${e%%$'\t'*}"
  [ "$m" = "${CO_MT[$d]:-}" ] || return 1
  [ $(( now - m )) -gt "$age" ] || return 1
  printf '%s' "${e#*$'\t'}"
}

# closeout_skip_add <file> <dir> <mtime> <kind> — appends one line and adds the
# dir to CO_SKIP. A failed append is ignored: the next tick judges it again.
closeout_skip_add() {
  local f="${1:-}" d="${2:-}" m="${3:-}" k="${4:-}"
  [ -n "$f" ] && [ -n "$d" ] || return 1
  case "$m" in ''|*[!0-9]*) return 1 ;; esac
  case "$k" in aged|emptyurl) ;; *) return 1 ;; esac
  [ -d "${f%/*}" ] || mkdir -p "${f%/*}" 2>/dev/null
  { printf '%s\t%s\t%s\n' "$d" "$m" "$k" >> "$f"; } 2>/dev/null || return 0
  declare -gA CO_SKIP
  CO_SKIP["$d"]="$m"$'\t'"$k"
  return 0
}

# closeout_skip_prune <file> — when an entry's dir is gone or its RESULT was
# rewritten (no CO_MT entry with the same mtime), rewrite the file with only
# the live entries. When every entry is live, write nothing.
closeout_skip_prune() {
  local f="${1:-}" d e stale=0
  [ -n "$f" ] && [ -f "$f" ] || return 0
  declare -p CO_SKIP >/dev/null 2>&1 || return 0
  declare -gA CO_MT
  for d in "${!CO_SKIP[@]}"; do
    e="${CO_SKIP[$d]}"
    [ "${e%%$'\t'*}" = "${CO_MT[$d]:-}" ] && continue
    stale=1; unset 'CO_SKIP[$d]'
  done
  [ "$stale" = 1 ] || return 0
  { for d in "${!CO_SKIP[@]}"; do printf '%s\t%s\n' "$d" "${CO_SKIP[$d]}"; done; } \
    > "$f.tmp.$$" 2>/dev/null && mv -f "$f.tmp.$$" "$f" 2>/dev/null || rm -f "$f.tmp.$$"
  return 0
}
# <<< closeout skip set
