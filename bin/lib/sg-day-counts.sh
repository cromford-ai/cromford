#!/bin/bash
# bin/lib/sg-day-counts.sh — sourced, never executed (BH-9258, #9061 Fix 4).
# One UTC day of pre-PR selection-gate outcomes per pool project, read from the
# gate.txt copies the hub reap writes to builds/pool-<P>-*/ (bin/fly-pool.sh,
# POOL_RECORD_FILES). bin/pool-tick-summary.sh posts the result as each row's
# gates_today; the project page and the MCP pool_status tool read it back.
#
# sg_day_counts <builds-dir> <day-start-epoch> <project>...
#   Prints ONE JSON object keyed by project:
#     {"<P>": {day, gates, rc0, rc1_attributed, rc1_unattributed, could_not_run}}
#   A file counts for day D when its mtime t is D0 <= t < D0 + 86400.
#   Only <builds-dir>/pool-<P>-*/gate.txt counts (depth 2; a local build dir
#   <P>-* and a deeper gate.txt do not). A dir maps to the LONGEST project P
#   for which its name starts with pool-P-, so pool-project-6-os-… is never
#   counted for a project project-6. A dir that maps to no project is skipped.
#   The class of one gate.txt (its `rc:` and `unattributed:` lines, each a line
#   of its own; bin/selection-gate.sh OUTPUT, bin/lib/selection-gate.sh
#   sg_unattributed):
#     rc: 0                                   rc0
#     rc: 1, no unattributed: or `-`          rc1_attributed (GATE_RED)
#     rc: 1, unattributed: <suite list>       rc1_unattributed
#     rc: could-not-run[...]                  could_not_run
#     anything else (off, no-selection, none) gates only
#   Every file counts in gates. A project with no file gets zeros.
#   A missing or unreadable builds dir, or a bad epoch: prints {} (the caller
#   then sends gates_today null). Always returns 0.
#   Cost: one find at depth 2 and one awk pass over the day's files.
sg_day_counts() {
  local dir="${1:-}" d0="${2:-}" day
  shift 2 2>/dev/null || { echo '{}'; return 0; }
  case "$d0" in ''|*[!0-9]*) echo '{}'; return 0 ;; esac
  if [ ! -d "$dir" ] || [ ! -r "$dir" ] || [ ! -x "$dir" ]; then echo '{}'; return 0; fi
  day=$(date -u -d "@$d0" '+%Y-%m-%d' 2>/dev/null) || { echo '{}'; return 0; }
  find "$dir" -mindepth 2 -maxdepth 2 -name gate.txt -path "$dir/pool-*/gate.txt" -printf '%T@\t%p\n' 2>/dev/null \
    | awk -F'\t' -v projects="$*" -v d0="$d0" -v d1="$((d0 + 86400))" -v day="$day" -v root="$dir/" '
BEGIN { np = split(projects, PL, " ") }
{
  t = $1 + 0; if (t < d0 || t >= d1) next
  f = $2; name = substr(f, length(root) + 1); sub(/\/gate\.txt$/, "", name)
  best = ""
  for (i = 1; i <= np; i++) {
    pre = "pool-" PL[i] "-"
    if (substr(name, 1, length(pre)) == pre && length(PL[i]) > length(best)) best = PL[i]
  }
  if (best == "") next
  rc = ""; un = ""; seen_rc = 0
  while ((getline line < f) > 0) {
    if (!seen_rc && substr(line, 1, 4) == "rc: ") { rc = substr(line, 5); seen_rc = 1 }
    else if (substr(line, 1, 14) == "unattributed: ") un = substr(line, 15)
  }
  close(f)
  gsub(/^[ \t]+|[ \t\r]+$/, "", rc); gsub(/^[ \t]+|[ \t\r]+$/, "", un)
  G[best]++
  if (rc == "0") R0[best]++
  else if (rc == "1") { if (un != "" && un != "-") RU[best]++; else RA[best]++ }
  else if (rc ~ /^could-not-run/) CN[best]++
}
END {
  printf "{"
  for (i = 1; i <= np; i++) {
    p = PL[i]
    printf "%s\"%s\":{\"day\":\"%s\",\"gates\":%d,\"rc0\":%d,\"rc1_attributed\":%d,\"rc1_unattributed\":%d,\"could_not_run\":%d}", \
      (i > 1 ? "," : ""), p, day, G[p] + 0, R0[p] + 0, RA[p] + 0, RU[p] + 0, CN[p] + 0
  }
  print "}"
}'
  return 0
}
