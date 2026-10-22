#!/bin/bash
# bin/test-impact-mix.sh [--last <n>] [--ranges <file>] [--impact <script>]
#   [--root <dir>] [--map <file>] [--batch]
#   — WHY DOES A MERGE SELECT WHAT IT SELECTS? (BH-8050)
#
# For each of the last <n> first-parent merges on origin/main (default 30),
# or each `<base>..<head>` line of --ranges, it runs
#
#   <impact> --root <root> --map <map> select <base>..<head> --why
#
# (with TI_BATCH_SELECT=1 under --batch, the merge-queue batch's select) and
# prints one markdown row per range, newest merge first:
#
#   | pr | sha | files | suites | self | reads | named | source | learned | regression | closure | always | full |
#
# Each kind column counts DISTINCT suites with at least one row of that kind,
# so a suite picked for two reasons counts in both. `files` is the changed
# path count of the range, `suites` the distinct suites. A merge range is
# `<sha>^1..<sha>`; its pr is the `#N` of the subject `Merge pull request #N`,
# or `-`. A --ranges row has pr `-`. After the table: `median: <m>` and
# `max: <x>` of the suite counts.
#
#   rc 0  every range got an answer
#   rc 1  a select failed (non-zero rc or no `impact:` line): its row prints
#         `error` in the suites column and the select's stderr is passed on;
#         every other row still prints, and median/max count the good rows
#   rc 2  bad arguments, no ranges, or the map could not be built
#
# Defaults: --impact is this tree's bin/test-impact.sh, --root is this tree.
# With no --map the map is built once (`<impact> --root <root> map --out`).
# Before and after a selector change, over the same 30 merges, from the root:
#
#   git show origin/main:bin/test-impact.sh > /tmp/main-ti/bin/test-impact.sh
#   (with its bin/lib/test-impact-*.sh next to it), then
#   bin/test-impact-mix.sh --last 30 --impact /tmp/main-ti/bin/test-impact.sh
#   bin/test-impact-mix.sh --last 30
#
# It reads local git and files only: no network, no gh, and no write outside
# its own mktemp -d.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"
IMPACT="$SELF_DIR/test-impact.sh"
LAST=30; RANGES=""; MAP=""; BATCH=0
while [ $# -gt 0 ]; do
  case "$1" in
    --last)   [ $# -ge 2 ] || { echo "test-impact-mix: --last needs a number" >&2; exit 2; }; LAST="$2"; shift ;;
    --ranges) [ $# -ge 2 ] || { echo "test-impact-mix: --ranges needs a file" >&2; exit 2; }; RANGES="$2"; shift ;;
    --impact) [ $# -ge 2 ] || { echo "test-impact-mix: --impact needs a script" >&2; exit 2; }; IMPACT="$2"; shift ;;
    --root)   [ $# -ge 2 ] || { echo "test-impact-mix: --root needs a directory" >&2; exit 2; }; ROOT="$2"; shift ;;
    --map)    [ $# -ge 2 ] || { echo "test-impact-mix: --map needs a file" >&2; exit 2; }; MAP="$2"; shift ;;
    --batch)  BATCH=1 ;;
    -h|--help) sed -n '2,37p' "$0"; exit 0 ;;
    *) echo "test-impact-mix: unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done
[[ $LAST =~ ^[1-9][0-9]*$ ]] || { echo "test-impact-mix: --last must be a positive integer (got '$LAST')" >&2; exit 2; }
[ -d "$ROOT" ] || { echo "test-impact-mix: no such root: $ROOT" >&2; exit 2; }
[ -r "$IMPACT" ] || { echo "test-impact-mix: no such impact script: $IMPACT" >&2; exit 2; }

W=$(mktemp -d "${TMPDIR:-/tmp}/test-impact-mix.XXXXXX") || { echo "test-impact-mix: cannot make a temp dir" >&2; exit 2; }
trap 'rm -rf "$W"' EXIT

# The ranges, as `<pr>\t<base>\t<head>` rows.
if [ -n "$RANGES" ]; then
  [ -r "$RANGES" ] || { echo "test-impact-mix: cannot read --ranges $RANGES" >&2; exit 2; }
  awk 'NF && $1 !~ /^#/ { i = index($1, ".."); if (i > 1) print "-\t" substr($1, 1, i - 1) "\t" substr($1, i + 2) }' "$RANGES" > "$W/ranges"
else
  git -C "$ROOT" log --first-parent --merges --format='%H%x09%s' -n "$LAST" origin/main > "$W/log" 2> "$W/log.err" || {
    echo "test-impact-mix: cannot read the merges of origin/main: $(cat "$W/log.err")" >&2; exit 2; }
  awk -F'\t' '{ pr = "-"; if (match($2, /^Merge pull request #[0-9]+/)) { pr = substr($2, RSTART, RLENGTH); sub(/^Merge pull request /, "", pr) }
                print pr "\t" $1 "^1\t" $1 }' "$W/log" > "$W/ranges"
fi
[ -s "$W/ranges" ] || { echo "test-impact-mix: no ranges to measure" >&2; exit 2; }

if [ -z "$MAP" ]; then
  MAP="$W/map"
  bash "$IMPACT" --root "$ROOT" map --out "$MAP" 2> "$W/map.err" && [ -s "$MAP" ] || {
    echo "test-impact-mix: the map could not be built: $(cat "$W/map.err")" >&2; exit 2; }
fi
[ -r "$MAP" ] || { echo "test-impact-mix: no such map: $MAP" >&2; exit 2; }

KINDS="self reads named source learned regression closure always full"
echo "| pr | sha | files | suites | $(printf '%s | ' $KINDS)" | sed 's/ $//'
echo "|---|---|---:|---:|$(printf -- '---:|%.0s' $KINDS)"
RC=0; : > "$W/counts"
while IFS=$'\t' read -r pr base head; do
  sha=$(git -C "$ROOT" rev-parse "$head" 2>/dev/null) || sha="$head"
  files=$(git -C "$ROOT" diff --name-only "$base" "$head" 2>/dev/null | grep -c .)
  if [ "$BATCH" = 1 ]; then
    TI_BATCH_SELECT=1 bash "$IMPACT" --root "$ROOT" --map "$MAP" select "$base..$head" --why > "$W/why" 2> "$W/err"; src=$?
  else
    env -u TI_BATCH_SELECT bash "$IMPACT" --root "$ROOT" --map "$MAP" select "$base..$head" --why > "$W/why" 2> "$W/err"; src=$?
  fi
  if [ "$src" != 0 ] || ! grep -q '^impact:' "$W/err"; then
    cat "$W/err" >&2
    echo "| $pr | ${sha:0:8} | $files | error |$(printf ' - |%.0s' $KINDS)"
    RC=1; continue
  fi
  awk -F'\t' -v pr="$pr" -v sha="${sha:0:8}" -v files="$files" -v kinds="$KINDS" '
    { s[$1] = 1; k[$2 SUBSEP $1] = 1 }
    END {
      n = 0; for (x in s) n++
      row = "| " pr " | " sha " | " files " | " n " |"
      m = split(kinds, K, " ")
      for (i = 1; i <= m; i++) { c = 0; for (y in k) { split(y, p, SUBSEP); if (p[1] == K[i]) c++ }; row = row " " c " |" }
      print row
    }' "$W/why"
  cut -f1 "$W/why" | LC_ALL=C sort -u | grep -c . >> "$W/counts"
done < "$W/ranges"

sort -n "$W/counts" | awk '{ v[NR] = $1 } END {
  if (NR == 0) { print "median: -"; print "max: -"; exit }
  if (NR % 2) m = v[(NR + 1) / 2]; else m = (v[NR / 2] + v[NR / 2 + 1]) / 2
  print "median: " m; print "max: " v[NR] }'
exit "$RC"
