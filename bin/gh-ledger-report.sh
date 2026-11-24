#!/bin/bash
# bin/gh-ledger-report.sh — BH-4477: which caller spends this box's GitHub REST
# requests, on which endpoint shape, over the last N hours or minutes.
#
#   bin/gh-ledger-report.sh [--last <N>h|<N>m] [--top <N>] [--dir <path>] [--per-merged-pr [--by-repo [--fleet]]]
#
#   --last  the window, ending now (default 1h). <N> is a positive integer.
#   --top   ranked rows to print (default 10, 0 = all). TOTAL always sums all.
#   --dir   the ledger directory (default $HARNESS/state/gh-rest-ledger).
#   --per-merged-pr  add one line: counted requests / PRs merged in the window.
#   --by-repo  then one per_merged_pr_repo= line per registry repo.
#   --fleet    count from the fleet table (D1), not this box's hour files.
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
# Reads files only: no API call without --per-merged-pr, no write. GH_LEDGER_REPORT_NOW (an epoch) pins
# the clock for tests.
#
# --per-merged-pr (BH-9455, BH-9417's observable outcome). After the report,
# ONE more line: the window's TOTAL counted divided by the PRs merged in the
# same window over every registry repo (bin/fleet-conf.sh --projects, field
# repo, owner/repo shapes, deduplicated):
#   per_merged_pr=<n> counted=<c> merged=<m>      n = c / m, rounded half up
#   per_merged_pr=n/a (0 merged) counted=<c> merged=0
#   per_merged_pr=unknown (<why>)                 a repo, the registry or the
#                                                 seam file could not be read
# A number is printed only when EVERY repo's count is known: a ratio over a
# partial count is wrong, not rough. The merged count is one gh_rest read per
# repo (GET search/issues ... is:merged merged:<since>..<now>, .total_count;
# rc != 0, no numeric total_count or incomplete_results => unknown), after
# gh_repo_use_token arms the credential that can see the repo. That read is the
# ONLY API call this script makes, and only with the flag. Test seam:
# GH_LEDGER_REPORT_MERGED_FILE, `repo<TAB>count` lines, read instead of GitHub
# and the registry; a count that is not digits marks that repo unreadable.
# Without the flag the output is byte-identical to the report before BH-9455.
#
# --by-repo (BH-9933, only with --per-merged-pr). After the total line, one
# line per registry repo, sorted by name, then one for the rest:
#   per_merged_pr_repo=<repo> counted=<c> merged=<m> per_merged_pr=<n>
#   per_merged_pr_repo=<repo> counted=<c> merged=0 per_merged_pr=n/a
#   per_merged_pr_repo=<repo> counted=<c> merged=? per_merged_pr=unknown (<repo> unreadable)
#   per_merged_pr_repo=<repo> counted=? merged=<m> per_merged_pr=unknown (ambiguous fold)
#   per_merged_pr_repo=(other) counted=<c>          only when c > 0
#   per_merged_pr_repo=unknown (<why>)              no repo set at all
# A ledger row belongs to a repo when its path class is repos/<owner>/<repo>/...
# (leading / optional). The ledger folds digit runs to N, so the match folds
# the registry name the same way and ignores case. Two registry repos that fold
# to one name cannot be split: both print `unknown (ambiguous fold)`. Rows with
# no registry repo (graphql, search/..., another repo) are `(other)`. Every
# repo's merged count is read, so one unreadable repo leaves the others' numbers.
#
# --fleet (BH-9933, only with --by-repo). The counted numbers come from the
# fleet table, one harness-jobs read GET /api/metrics/gh-ledger?since=<hour>
# &group=repo (REST rows, cache rows out, 14-day retention), from the start
# hour of the window. The local table is not printed. A failed read, an answer
# with no `group` echo or a `truncated` answer prints
# `per_merged_pr_repo=unknown (fleet ledger: <why>)` and rc 0, and never a
# local-file number: the hour files are swept at 48 h, so a 168 h window over
# them is a wrong number. Test seam: GH_LEDGER_REPORT_FLEET_FILE, a saved
# group=repo answer, read instead of the worker.
#
# Exit: 0 report printed (including an empty window), 2 bad arguments or an
# unreadable ledger directory.
set -uo pipefail
H="${HARNESS:-/root/harness}"

usage() {
  sed -n '5,12p' "$0" | sed 's/^# \{0,1\}//' >&2
}

LAST=1h TOP=10 DIR="" PER_MERGED=0 BY_REPO=0 FLEET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --last) [ $# -ge 2 ] || { usage; exit 2; }; LAST="$2"; shift 2 ;;
    --top)  [ $# -ge 2 ] || { usage; exit 2; }; TOP="$2"; shift 2 ;;
    --dir)  [ $# -ge 2 ] || { usage; exit 2; }; DIR="$2"; shift 2 ;;
    --per-merged-pr) PER_MERGED=1; shift ;;
    --by-repo) BY_REPO=1; shift ;;
    --fleet) FLEET=1; shift ;;
    -h|--help) usage 2>&1; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done
DIR="${DIR:-$H/state/gh-rest-ledger}"
if { [ "$BY_REPO" = 1 ] && [ "$PER_MERGED" != 1 ]; } || { [ "$FLEET" = 1 ] && [ "$BY_REPO" != 1 ]; }; then
  usage; exit 2
fi

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

if [ "$FLEET" != 1 ] && { [ ! -d "$DIR" ] || [ ! -r "$DIR" ] || [ ! -x "$DIR" ]; }; then
  echo "gh-ledger-report: ledger directory $DIR is missing or unreadable" >&2
  exit 2
fi

since_iso=$(date -u -d "@$SINCE" '+%Y-%m-%dT%H:%M:%SZ')
now_iso=$(date -u -d "@$NOW" '+%Y-%m-%dT%H:%M:%SZ')

# The live merged read's libraries, sourced at top level: gh-repo-token.sh
# declares its caches with `declare -A`, which a function would make local.
GH_LIB_WHY=""
if [ "$PER_MERGED" = 1 ] && [ -z "${GH_LEDGER_REPORT_MERGED_FILE:-}" ]; then
  # shellcheck source=bin/lib/gh-rest.sh
  . "$H/bin/lib/gh-rest.sh" 2>/dev/null || GH_LIB_WHY="bin/lib/gh-rest.sh unreadable"
  # shellcheck source=bin/lib/gh-repo-token.sh
  [ -n "$GH_LIB_WHY" ] || . "$H/bin/lib/gh-repo-token.sh" 2>/dev/null || GH_LIB_WHY="bin/lib/gh-repo-token.sh unreadable"
fi

# The fleet read's client (--fleet only), at top level for the same reason.
# Only a client with its modules beside it: jobs-client.sh EXITS the shell
# that sources it otherwise (the bin/gh-budget-report.sh guard).
if [ "$FLEET" = 1 ] && [ -z "${GH_LEDGER_REPORT_FLEET_FILE:-}" ]; then
  for JC in "$H/bin/jobs-client.sh" "$(dirname "$0")/jobs-client.sh"; do
    # shellcheck source=bin/jobs-client.sh
    [ -r "$JC" ] && [ -r "${JC%/*}/lib/jobs/req.sh" ] && { . "$JC"; break; }
  done
fi

# merged_count [continue] — sets MERGED (digits) or MERGED_WHY (the
# `unknown (...)` text), and per repo MERGED_OF[<repo>] (digits, or ? when
# unreadable) and MERGED_REPOS (every repo it tried). Never prints. Without
# `continue` it stops at the first repo it cannot read; with it, it reads every
# repo, and MERGED_WHY still names the first failure.
declare -A MERGED_OF=()
MERGED_REPOS=()
merged_count() {
  MERGED=0; MERGED_WHY=""; MERGED_OF=(); MERGED_REPOS=()
  local mode="${1:-}" repo n f="${GH_LEDGER_REPORT_MERGED_FILE:-}" repos p r body
  if [ -n "$f" ]; then
    [ -f "$f" ] && [ -r "$f" ] || { MERGED_WHY="merged file unreadable"; return 0; }
    while IFS=$'\t' read -r repo n || [ -n "$repo" ]; do
      [ -n "$repo" ] || continue
      MERGED_REPOS+=("$repo")
      case "$n" in ''|*[!0-9]*)
        MERGED_OF[$repo]="?"; [ -n "$MERGED_WHY" ] || MERGED_WHY="$repo unreadable"
        [ "$mode" = continue ] && continue; return 0 ;;
      esac
      MERGED_OF[$repo]=$(( 10#$n ))
      MERGED=$(( MERGED + 10#$n ))
    done < "$f"
    return 0
  fi
  p=$("$H/bin/fleet-conf.sh" --projects 2>/dev/null) || { MERGED_WHY="registry unreadable"; return 0; }
  repos=$(for r in $p; do "$H/bin/fleet-conf.sh" "$r" repo 2>/dev/null; echo; done \
    | awk '$0 ~ /^[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+$/' | LC_ALL=C sort -u)
  [ -n "$repos" ] || { MERGED_WHY="registry unreadable"; return 0; }
  [ -z "$GH_LIB_WHY" ] || { MERGED_WHY="$GH_LIB_WHY"; return 0; }
  body=$(mktemp "${TMPDIR:-/tmp}/gh-ledger-report.XXXXXX") || { MERGED_WHY="mktemp failed"; return 0; }
  for repo in $repos; do
    MERGED_REPOS+=("$repo"); n=x
    # Plain command with `> file` (bin/lib/gh-rest.sh READING THE STATUS).
    if gh_repo_use_token "$repo" \
       && gh_rest GET "search/issues?q=repo:$repo+is:pr+is:merged+merged:$since_iso..$now_iso&per_page=1" > "$body" 2>/dev/null; then
      n=$(jq -r 'if (.total_count | type) == "number" and (.incomplete_results != true) then .total_count else "x" end' "$body" 2>/dev/null)
    fi
    case "$n" in ''|*[!0-9]*)
      MERGED_OF[$repo]="?"; [ -n "$MERGED_WHY" ] || MERGED_WHY="$repo unreadable"
      [ "$mode" = continue ] && continue; break ;;
    esac
    MERGED_OF[$repo]=$n
    MERGED=$(( MERGED + n ))
  done
  rm -f "$body"
  return 0
}
# per_merged_line <counted> [continue] — the --per-merged-pr line.
per_merged_line() {
  local c=$1
  merged_count "${2:-}"
  if [ -n "$MERGED_WHY" ]; then echo "per_merged_pr=unknown ($MERGED_WHY)"
  elif [ "$MERGED" -eq 0 ]; then echo "per_merged_pr=n/a (0 merged) counted=$c merged=0"
  else echo "per_merged_pr=$(( (2 * c + MERGED) / (2 * MERGED) )) counted=$c merged=$MERGED"
  fi
}

# fold_repo <owner/repo> — the ledger's repo key: digit runs -> N, lower case.
fold_repo() { printf '%s' "$1" | sed -E 's/[0-9]+/N/g' | tr 'A-Z' 'a-z'; }

# by_repo_lines <agg-file> — the --by-repo lines, after merged_count ran.
# <agg-file>: `<folded owner/repo | (other)><TAB><counted>` lines.
by_repo_lines() {
  local agg="$1" r k c m other
  local -A key_of=() nkey=() cnt=()
  if [ "${#MERGED_REPOS[@]}" -eq 0 ]; then
    echo "per_merged_pr_repo=unknown (${MERGED_WHY:-no registry repo})"; return 0
  fi
  for r in "${MERGED_REPOS[@]}"; do
    [ -z "${key_of[$r]:-}" ] || continue
    k=$(fold_repo "$r"); key_of[$r]=$k; nkey[$k]=$(( ${nkey[$k]:-0} + 1 ))
  done
  while IFS=$'\t' read -r k c; do
    [ -n "$k" ] || continue
    case "$c" in ''|*[!0-9]*) continue ;; esac
    cnt[$k]=$(( ${cnt[$k]:-0} + c ))
  done < "$agg"
  other=0
  for k in "${!cnt[@]}"; do
    [ "$k" = "(other)" ] || [ -z "${nkey[$k]:-}" ] && other=$(( other + cnt[$k] ))
  done
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    k=${key_of[$r]}; m=${MERGED_OF[$r]:-?}
    if [ "${nkey[$k]}" -gt 1 ]; then
      echo "per_merged_pr_repo=$r counted=? merged=$m per_merged_pr=unknown (ambiguous fold)"; continue
    fi
    c=${cnt[$k]:-0}
    if [ "$m" = "?" ]; then echo "per_merged_pr_repo=$r counted=$c merged=? per_merged_pr=unknown ($r unreadable)"
    elif [ "$m" -eq 0 ]; then echo "per_merged_pr_repo=$r counted=$c merged=0 per_merged_pr=n/a"
    else echo "per_merged_pr_repo=$r counted=$c merged=$m per_merged_pr=$(( (2 * c + m) / (2 * m) ))"
    fi
  done <<<"$(printf '%s\n' "${MERGED_REPOS[@]}" | LC_ALL=C sort -u)"
  [ "$other" -gt 0 ] && echo "per_merged_pr_repo=(other) counted=$other"
  return 0
}

# local_agg <file>... — the --by-repo counts of the hour files: the window, the
# column count and the cache rule of the report itself.
local_agg() {
  [ "$#" -gt 0 ] || return 0
  awk -F'\t' -v since="$since_iso" -v now="$now_iso" '
    NF >= 7 && $1 >= since && $1 <= now && $6 != "cache" {
      p = $5; sub(/^\//, "", p); n = split(p, seg, "/")
      if (seg[1] == "repos" && n >= 3 && seg[2] != "" && seg[3] != "") {
        k = seg[2] "/" seg[3]; gsub(/[0-9]+/, "N", k); k = tolower(k)
      } else k = "(other)"
      c[k] += ($7 + 0)
    }
    END { for (k in c) printf "%s\t%d\n", k, c[k] }' "$@"
}

# fleet_read <agg-out> — the fleet group=repo read. rc 0 writes the agg file
# and sets FLEET_TOTAL; rc 1 sets FLEET_WHY.
fleet_read() {
  local out="$1" ans="$1.json" f="${GH_LEDGER_REPORT_FLEET_FILE:-}" hour
  FLEET_WHY=""; FLEET_TOTAL=0
  hour=$(date -u -d "@$SINCE" '+%Y-%m-%dT%H')
  if [ -n "$f" ]; then
    [ -f "$f" ] && [ -r "$f" ] && cp "$f" "$ans" 2>/dev/null || { FLEET_WHY="unreadable answer"; return 1; }
  else
    command -v _jobs_req >/dev/null 2>&1 || { FLEET_WHY="no jobs client"; return 1; }
    JOBS_ALERT=0 _jobs_req GET "/api/metrics/gh-ledger?since=$hour&group=repo" > "$ans" 2>/dev/null \
      || { FLEET_WHY="http=${JOBS_HTTP:-none}"; return 1; }
  fi
  jq -e '.rows | type == "array"' "$ans" >/dev/null 2>&1 || { FLEET_WHY="unparseable answer"; return 1; }
  jq -e '.group == "repo"' "$ans" >/dev/null 2>&1 || { FLEET_WHY="no group echo"; return 1; }
  jq -e '.truncated != true' "$ans" >/dev/null 2>&1 || { FLEET_WHY="truncated"; return 1; }
  FLEET_TOTAL=$(jq -r '(.totals.rest_counted // ([.rows[].counted] | add) // 0) | if type == "number" then floor else "x" end' "$ans" 2>/dev/null)
  case "$FLEET_TOTAL" in ''|*[!0-9]*) FLEET_WHY="unparseable answer"; return 1 ;; esac
  jq -r '.rows[] | [(.repo // "(no repo)"), ((.counted // 0) | tostring)] | @tsv' "$ans" 2>/dev/null \
    | awk -F'\t' '{ k = $1
        if (k == "(no repo)" || k !~ /^[^\/]+\/[^\/]+$/) k = "(other)"
        else { gsub(/[0-9]+/, "N", k); k = tolower(k) }
        printf "%s\t%s\n", k, $2 }' > "$out" || { FLEET_WHY="unparseable answer"; return 1; }
  return 0
}

WORK=""
if [ "$BY_REPO" = 1 ]; then
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/gh-ledger-report.XXXXXX") || { echo "gh-ledger-report: mktemp failed" >&2; exit 2; }
  trap 'rm -rf "$WORK"' EXIT
fi

if [ "$FLEET" = 1 ]; then
  echo "gh-ledger-report: fleet gh_ledger (D1) window $(date -u -d "@$SINCE" '+%Y-%m-%dT%H'):00:00Z..$now_iso ($LAST)"
  if fleet_read "$WORK/agg.tsv"; then
    per_merged_line "$FLEET_TOTAL" continue
    by_repo_lines "$WORK/agg.tsv"
  else
    echo "per_merged_pr=unknown (fleet ledger: $FLEET_WHY)"
    echo "per_merged_pr_repo=unknown (fleet ledger: $FLEET_WHY)"
  fi
  exit 0
fi

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
  if [ "$BY_REPO" = 1 ]; then
    per_merged_line 0 continue
    : > "$WORK/agg.tsv"; by_repo_lines "$WORK/agg.tsv"
  elif [ "$PER_MERGED" = 1 ]; then
    per_merged_line 0
  fi
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
if [ "$BY_REPO" = 1 ]; then
  per_merged_line "$(printf '%s\n' "$groups" | awk -F'\t' '{ s += $2 } END { printf "%d", s }')" continue
  local_agg "${files[@]}" > "$WORK/agg.tsv"
  by_repo_lines "$WORK/agg.tsv"
elif [ "$PER_MERGED" = 1 ]; then
  per_merged_line "$(printf '%s\n' "$groups" | awk -F'\t' '{ s += $2 } END { printf "%d", s }')"
fi
exit 0
