# shellcheck shell=bash
# bin/lib/mc-merged-live.sh — BH-9897: count the live merge-conductor rows
# whose PR the closed-watch memo already records as merged.
#
# On 2026-11-22, 962 of 1,133 live conductor rows belonged to PRs that were
# merged or closed: the off-list settle read only READY and WAIT_CI rows, and
# nothing counted the rest. bin/pipeline-health.sh reads this count once a
# fleet run and alerts when it stands above 0 (PH_MC_MERGED_LIVE_ALERT_MIN).
#
#   mc_merged_live_count <rows-file> <closed-watch-dir>
#     rows-file         state/merge-conductor/pr-state.tsv (TSV: col 1
#                       `slug#num`, col 2 the state)
#     closed-watch-dir  state/merge-conductor/closed-watch; the memo of a PR
#                       is <dir>/<safe slug>/<num>, one line, field 1 the state
#                       (open|closed|merged|gone), TAB-separated
#   A row counts when its state is not MERGED, CLOSED or ABANDONED and field 1
#   of its memo is exactly `merged`. The safe slug is mc_safe_name's rule
#   (bin/lib/mc/locks.sh): every char outside [A-Za-z0-9._-] becomes `_`.
#   Prints `<total>\t<slug>=<n>,<slug>=<n>` (slugs sorted; empty second field
#   at 0). rc 0; rc 1 (no output) when the rows file is not a readable file.
#
# One awk pass over the rows; one getline per live row. No side effect when
# sourced.

mc_merged_live_count() {
  local rows="${1:-}" dir="${2:-}"
  [ -f "$rows" ] && [ -r "$rows" ] || return 1
  LC_ALL=C awk -F'\t' -v dir="$dir" '
    $2 == "" || $2 == "MERGED" || $2 == "CLOSED" || $2 == "ABANDONED" { next }
    {
      i = index($1, "#"); if (i < 2) next
      slug = substr($1, 1, i - 1); num = substr($1, i + 1)
      if (num == "" || num ~ /[^0-9]/) next
      safe = slug; gsub(/[^A-Za-z0-9._-]/, "_", safe)
      f = dir "/" safe "/" num; line = ""
      if ((getline line < f) > 0) {
        split(line, m, "\t")
        if (m[1] == "merged") { n[slug]++; total++ }
      }
      close(f)
    }
    END {
      k = 0
      for (s in n) keys[++k] = s
      for (a = 2; a <= k; a++) { v = keys[a]; for (b = a - 1; b >= 1 && keys[b] > v; b--) keys[b + 1] = keys[b]; keys[b + 1] = v }
      out = ""
      for (a = 1; a <= k; a++) out = out (a > 1 ? "," : "") keys[a] "=" n[keys[a]]
      printf "%d\t%s\n", total + 0, out
    }' "$rows"
}
