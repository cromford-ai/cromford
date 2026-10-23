#!/bin/bash
# bin/gh-ledger-report.sh — BH-4477: which caller spends this box's GitHub REST
# requests, on which endpoint shape, over the last N hours or minutes.
#
#   bin/gh-ledger-report.sh [--last <N>h|<N>m] [--top <N>] [--dir <path>]
#
#   --last  the window, ending now (default 1h). <N> is a positive integer.
#   --top   ranked rows to print (default 10, 0 = all). TOTAL always sums all.
#   --dir   the ledger directory (default $HARNESS/state/gh-rest-ledger).
#
# WHY. the operator's 2026-10-04 diagnosis of the hub's gh api volume was done by hand
# over state/gh-rest-ledger/2026-10-04T19.tsv. bin/gh-quota-report.sh shows the
# caller and the path class as two SEPARATE blocks and only whole hour files;
# the question "who reads what, how often" needs the cross product over an
# exact window, and #4477's done-when is a before/after reading of it.
#
# WHAT IT COUNTS. The rows bin/lib/gh-rest-ledger.sh gh_ledger_append writes:
# one row per HTTP request, so each page of a paginated read is its own row
# and CALLS already counts pages. Grouped by caller ($2) and method + path
# class ($4 $5; the writer already turned ids into N and 40-hex shas into SHA,
# and this report does it again for any row that was not). COUNTED sums the
# writer's counted column; UNCOUNTED is the rest (304s answered from the ETag
# cache, 000s that never reached GitHub). Rows with fewer than 7 columns are
# torn appends and are skipped. A swept hour file (older than 48h) is simply
# absent, so the header names how many hour files were actually read.
#
# Reads files only: no API call, no write. GH_LEDGER_REPORT_NOW (an epoch) pins
# the clock for tests.
#
# Exit: 0 report printed (including an empty window), 2 bad arguments or an
# unreadable ledger directory.
set -uo pipefail
H="${HARNESS:-/root/harness}"

usage() {
  sed -n '5,9p' "$0" | sed 's/^# \{0,1\}//' >&2
}

LAST=1h TOP=10 DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --last) [ $# -ge 2 ] || { usage; exit 2; }; LAST="$2"; shift 2 ;;
    --top)  [ $# -ge 2 ] || { usage; exit 2; }; TOP="$2"; shift 2 ;;
    --dir)  [ $# -ge 2 ] || { usage; exit 2; }; DIR="$2"; shift 2 ;;
    -h|--help) usage 2>&1; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done
DIR="${DIR:-$H/state/gh-rest-ledger}"

case "$LAST" in
  [1-9]*h) n=${LAST%h}; unit=3600 ;;
  [1-9]*m) n=${LAST%m}; unit=60 ;;
  *) echo "gh-ledger-report: --last '$LAST' is not <N>h or <N>m with N >= 1" >&2; exit 2 ;;
esac
case "$n" in *[!0-9]*) echo "gh-ledger-report: --last '$LAST' is not <N>h or <N>m with N >= 1" >&2; exit 2 ;; esac
case "$TOP" in ''|*[!0-9]*) echo "gh-ledger-report: --top '$TOP' is not a non-negative integer" >&2; exit 2 ;; esac
WINDOW=$(( 10#$n * unit ))

NOW="${GH_LEDGER_REPORT_NOW:-$(date -u +%s)}"
case "$NOW" in ''|*[!0-9]*) echo "gh-ledger-report: GH_LEDGER_REPORT_NOW '$NOW' is not an epoch" >&2; exit 2 ;; esac
SINCE=$(( NOW - WINDOW ))

if [ ! -d "$DIR" ] || [ ! -r "$DIR" ] || [ ! -x "$DIR" ]; then
  echo "gh-ledger-report: ledger directory $DIR is missing or unreadable" >&2
  exit 2
fi

since_iso=$(date -u -d "@$SINCE" '+%Y-%m-%dT%H:%M:%SZ')
now_iso=$(date -u -d "@$NOW" '+%Y-%m-%dT%H:%M:%SZ')

# The hour files whose hour overlaps [since, now]; the ts filter trims the ends.
files=()
for (( h = SINCE / 3600 * 3600; h <= NOW; h += 3600 )); do
  f="$DIR/$(date -u -d "@$h" '+%Y-%m-%dT%H').tsv"
  [ -r "$f" ] && files+=("$f")
done

echo "gh-ledger-report: $DIR window $since_iso..$now_iso ($LAST) — ${#files[@]} hour file(s)"

# One line per caller x endpoint: calls TAB counted TAB caller TAB endpoint,
# sorted calls desc, then caller, then endpoint, so ties never reorder. A
# status `cache` row (BH-8066: the gh shim answered from disk) is not a call.
groups=""
if [ "${#files[@]}" -gt 0 ]; then
  groups=$(awk -F'\t' -v since="$since_iso" -v now="$now_iso" '
    NF >= 7 && $1 >= since && $1 <= now && $6 != "cache" {
      n = split($5, seg, "/"); path = ""
      for (i = 1; i <= n; i++) {
        s = seg[i]
        if (s ~ /^[0-9a-f]+$/ && length(s) == 40) s = "SHA"
        else gsub(/[0-9]+/, "N", s)
        path = path (i > 1 ? "/" : "") s
      }
      k = $2 "\t" $4 " " path
      calls[k]++; counted[k] += ($7 + 0)
    }
    END { for (k in calls) printf "%d\t%d\t%s\n", calls[k], counted[k], k }
  ' "${files[@]}" | LC_ALL=C sort -t "$(printf '\t')" -k1,1nr -k3,3 -k4,4)
fi
if [ -z "$groups" ]; then
  echo "no ledger rows in window"
  exit 0
fi
printf '%s\n' "$groups" | awk -F'\t' -v window="$WINDOW" -v top="$TOP" '
  { c[NR] = $1; k[NR] = $2; who[NR] = $3; ep[NR] = $4; tc += $1; tk += $2 }
  END {
    printf "TOTAL  calls=%d  counted=%d  uncounted=%d  per_hour=%d\n", tc, tk, tc - tk, int(tc * 3600 / window)
    printf "%4s  %6s  %7s  %9s  %-30s  %s\n", "RANK", "CALLS", "COUNTED", "UNCOUNTED", "CALLER", "ENDPOINT"
    for (i = 1; i <= NR && (top == 0 || i <= top); i++)
      printf "%4d  %6d  %7d  %9d  %-30s  %s\n", i, c[i], k[i], c[i] - k[i], who[i], ep[i]
  }'
exit 0
