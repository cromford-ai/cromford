#!/bin/bash
# bin/repo-activity.sh — BH-8417 (scope F): what happened in a repo, read from
# GitHub, not from our own logs.
#
#   repo-activity.sh <owner/repo> [--since <iso|Nh>]      (default --since 6h)
#
# the operator, 2026-10-26: "These reports are simply not true ... you can look at the
# repos directly for activity." This prints one line per event, oldest first:
#
#   <iso> <kind> #<n> <sha8> <detail>
#
#   merged  <merged_at>  #<pr> <merge_commit_sha8> <title>
#   opened  <created_at> #<pr> <head sha8>         <title>
#   closed  <closed_at>  #<pr> <head sha8>         <title>      (closed, not merged)
#   push    <updated_at> #<pr> <new head sha8>     from <old sha8> <title>
#   ci      <updated_at> #<pr|-> <head_sha8>       <workflow name> <conclusion>
#
# SOURCES. Two REST reads per page, both through gh_rest (bin/lib/gh-rest.sh),
# so a repeat read inside the ETag cache is a 304 that costs no rate limit:
#   repos/<r>/pulls?state=all&sort=updated&direction=desc&per_page=100, paged
#     until a page ends with updated_at < since or is short;
#   repos/<r>/actions/runs?created=>=<since>&status=completed&per_page=100,
#     paged until a page is short. A run maps to the first entry of its
#     pull_requests[], else `#-` (a push to main, or a fork PR GitHub hides).
#
# PUSH. GitHub REST has no "head moved" event on a PR, so the head is compared
# with state/repo-activity/<owner>_<repo>.heads (one line per PR:
# `<n> <head sha> <previous sha|-> <iso the change was first seen|->`, written
# tmp+mv). A PR with no line is a BASELINE: recorded, no push printed, because
# a push we did not see is not a claim we can make. A head that differs from
# its line is a push, timed at the PR's updated_at when it was first seen; the
# line keeps that time, so the push prints again on every run while it is
# inside --since (the same window gives the same lines). Retention: a line is
# dropped when its PR is read closed and its change time is outside --since,
# so the file holds about the open PRs.
#
# FAILURE IS NEVER AN EMPTY LIST (D9, D11). A read that is not 2xx (or a 304
# the cache answered) prints `UNREADABLE <endpoint> HTTP <code>` and NO event
# line, writes no heads state, and exits 75. A 2xx body that is not the shape
# asked for is `UNREADABLE <endpoint> HTTP <code> (unparseable)`, same exit.
# A page cap prints `INCOMPLETE <endpoint> pages=<n>` before the events (D12):
# the events older than the last page read are not listed.
#
# KNOB: REPO_ACTIVITY_MAX_PAGES (default 5, registry
# catalog/lanes.d/_lib.repo-activity.json, settings row
# lib.repo-activity.repo_activity_max_pages). Not an integer 1..50 = the default
# and one stderr line.
#
# EXIT: 0 read (events, or none), 75 a read failed, 2 usage.
# CLOCK: REPO_ACTIVITY_NOW (epoch seconds), honoured only under
# HARNESS_TEST_SANDBOX=1.
# Reader: archie_repo_activity_block (bin/lib/archie-repo-activity.sh).
# Test: tests/repo-activity.bh-8417-test.sh.
# gh-rest: no-graphql
set -uo pipefail
H="${HARNESS:-/root/harness}"
export HARNESS="$H"
SELF="$(cd "$(dirname "$0")" && pwd)"

usage() { echo "usage: repo-activity.sh <owner/repo> [--since <YYYY-MM-DDTHH:MM:SSZ|<n>h>]" >&2; exit 2; }
SLUG="${1:-}"
[[ $SLUG =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage
shift
SINCE_ARG=6h
while [ $# -gt 0 ]; do
  case "$1" in
    --since) [ $# -ge 2 ] || usage; SINCE_ARG=$2; shift 2 ;;
    *) usage ;;
  esac
done

NOW=""
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [[ ${REPO_ACTIVITY_NOW:-} =~ ^[0-9]+$ ]]; then NOW=$REPO_ACTIVITY_NOW; fi
[ -n "$NOW" ] || NOW=$(date -u +%s)
if [[ $SINCE_ARG =~ ^([0-9]{1,4})h$ ]]; then
  SINCE=$((NOW - 10#${BASH_REMATCH[1]} * 3600))
elif [[ $SINCE_ARG =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
  [ -n "$SINCE_ARG" ] || usage
  SINCE=$(date -u -d "$SINCE_ARG" +%s 2>/dev/null) || usage
else
  usage
fi
SINCE_ISO=$(date -u -d "@$SINCE" +%Y-%m-%dT%H:%M:%SZ)

# shellcheck source=bin/lib/gh-rest.sh
. "$SELF/lib/gh-rest.sh" 2>/dev/null
command -v gh_rest >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 \
  || { echo "UNREADABLE repos/$SLUG gh_rest or jq missing"; exit 75; }
# shellcheck source=bin/lib/lane-gate.sh
. "$SELF/lib/lane-gate.sh" 2>/dev/null || true
command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply repo-activity >/dev/null 2>&1
# Fallback 5 = the registry default of REPO_ACTIVITY_MAX_PAGES in
# catalog/lanes.d/_lib.repo-activity.json (row lib.repo-activity.repo_activity_max_pages).
MAX_PAGES="${REPO_ACTIVITY_MAX_PAGES:-5}"
if ! [[ $MAX_PAGES =~ ^[0-9]{1,2}$ ]] || [ "$((10#$MAX_PAGES))" -lt 1 ] || [ "$((10#$MAX_PAGES))" -gt 50 ]; then
  echo "repo-activity: REPO_ACTIVITY_MAX_PAGES=$MAX_PAGES is outside 1..50; using the default 5" >&2
  MAX_PAGES=5
fi
MAX_PAGES=$((10#$MAX_PAGES))

W=$(mktemp -d "${TMPDIR:-/tmp}/repo-activity.XXXXXX") || { echo "UNREADABLE repos/$SLUG no temp dir"; exit 75; }
trap 'rm -rf "$W"' EXIT
NOTES="$W/notes"; : > "$NOTES"

# read_pages <endpoint> <kind pulls|runs> <out jsonl> [-f/-F args...]
# Appends every row of every page to <out jsonl>. rc 0 read, 75 failed (the
# UNREADABLE line is printed here and the caller prints nothing else).
read_pages() {
  local ep=$1 kind=$2 out=$3 page=1 rc n last
  shift 3
  : > "$out"
  while :; do
    if [ "$page" -gt "$MAX_PAGES" ]; then
      printf 'INCOMPLETE %s pages=%s\n' "$ep" "$MAX_PAGES" >> "$NOTES"
      return 0
    fi
    rc=0
    gh_rest GET "$ep" "$@" -F per_page=100 -F "page=$page" > "$W/page" || rc=$?
    if [ "$rc" != 0 ]; then
      printf 'UNREADABLE %s HTTP %s\n' "$ep" "${GH_REST_STATUS:-000}"
      return 75
    fi
    if [ "$kind" = runs ]; then
      jq -c '.workflow_runs | if type=="array" then .[] else error("shape") end' "$W/page" > "$W/rows" 2>/dev/null || rc=1
    else
      jq -c 'if type=="array" then .[] else error("shape") end' "$W/page" > "$W/rows" 2>/dev/null || rc=1
    fi
    if [ "$rc" != 0 ]; then
      printf 'UNREADABLE %s HTTP %s (unparseable)\n' "$ep" "${GH_REST_STATUS:-000}"
      return 75
    fi
    cat "$W/rows" >> "$out"
    n=$(wc -l < "$W/rows")
    [ "$n" -lt 100 ] && return 0
    if [ "$kind" = pulls ]; then
      last=$(tail -n 1 "$W/rows" | jq -r '.updated_at // ""')
      [[ "$last" < "$SINCE_ISO" ]] && return 0
    fi
    page=$((page + 1))
  done
}

read_pages "repos/$SLUG/pulls" pulls "$W/pulls" -f state=all -f sort=updated -f direction=desc || exit 75
read_pages "repos/$SLUG/actions/runs" runs "$W/runs" -f "created=>=$SINCE_ISO" -f status=completed || exit 75

# One TSV row per PR in the window: n, state, head, updated, created, closed, merged, merge sha, title.
jq -r --arg s "$SINCE_ISO" 'select((.updated_at // "") >= $s)
  | [ (.number|tostring), .state, (.head.sha // "-"), .updated_at, (.created_at // ""), (.closed_at // ""),
      (.merged_at // ""), (.merge_commit_sha // "-"), ((.title // "") | gsub("[\t\r\n]"; " ") | .[0:80]) ] | @tsv' \
  "$W/pulls" > "$W/prs.tsv" 2>/dev/null || { echo "UNREADABLE repos/$SLUG/pulls HTTP 200 (unparseable)"; exit 75; }

EV="$W/events"; : > "$EV"
awk -F'\t' -v s="$SINCE_ISO" '
  $7 != "" && $7 >= s            { printf "%s\tmerged\t#%s\t%s\t%s\n", $7, $1, substr($8,1,8), $9 }
  $5 != "" && $5 >= s            { printf "%s\topened\t#%s\t%s\t%s\n", $5, $1, substr($3,1,8), $9 }
  $6 != "" && $6 >= s && $7 == "" { printf "%s\tclosed\t#%s\t%s\t%s\n", $6, $1, substr($3,1,8), $9 }
' "$W/prs.tsv" >> "$EV"

# Push: merge the read into the heads file, then print every change in window.
SD="$H/state/repo-activity"
HEADS="$SD/${SLUG//\//_}.heads"
mkdir -p "$SD" 2>/dev/null
[ -r "$HEADS" ] && cp "$HEADS" "$W/heads.old" || : > "$W/heads.old"
awk -F'\t' -v s="$SINCE_ISO" '
  FILENAME == OLD { split($0, f, " "); if (f[1] != "") { sha[f[1]] = f[2]; prv[f[1]] = f[3]; at[f[1]] = f[4] } next }
  {
    n = $1; h = $3
    if (!(n in sha))      { sha[n] = h; prv[n] = "-"; at[n] = "-" }
    else if (sha[n] != h) { prv[n] = sha[n]; sha[n] = h; at[n] = $4 }
    title[n] = $9; seen[n] = 1
    if ($2 == "closed" && (at[n] == "-" || at[n] < s)) drop[n] = 1
  }
  END {
    for (n in sha) {
      if (n in drop) continue
      printf "%s %s %s %s\n", n, sha[n], prv[n], at[n] > HF
      if ((n in seen) && prv[n] != "-" && at[n] != "-" && at[n] >= s)
        printf "%s\tpush\t#%s\t%s\tfrom %s %s\n", at[n], n, substr(sha[n],1,8), substr(prv[n],1,8), title[n]
    }
  }
' HF="$W/heads.new" OLD="$W/heads.old" "$W/heads.old" "$W/prs.tsv" >> "$EV"
sort -n "$W/heads.new" > "$W/heads.sorted" 2>/dev/null || cp "$W/heads.new" "$W/heads.sorted"

# CI: completed runs created inside the window.
jq -r --arg s "$SINCE_ISO" 'select((.created_at // "") >= $s)
  | [ (.updated_at // .created_at), "ci",
      (if ((.pull_requests // []) | length) > 0 then "#" + (.pull_requests[0].number|tostring) else "#-" end),
      ((.head_sha // "-")[0:8]),
      (((.name // "?") | gsub("[\t\r\n]"; " ")) + " " + (.conclusion // "none")) ] | @tsv' \
  "$W/runs" >> "$EV" 2>/dev/null || { echo "UNREADABLE repos/$SLUG/actions/runs HTTP 200 (unparseable)"; exit 75; }

# Every read is in: now the heads state may move (a failed run never moves it).
if ! { cp "$W/heads.sorted" "$HEADS.tmp.$$" && mv -f "$HEADS.tmp.$$" "$HEADS"; } 2>/dev/null; then
  rm -f "$HEADS.tmp.$$"
  echo "repo-activity: cannot write $HEADS; push lines are not tracked this run" >&2
fi

cat "$NOTES"
LC_ALL=C sort -t $'\t' -s -k1,1 "$EV" | awk -F'\t' '{ printf "%s %s %s %s %s\n", $1, $2, $3, $4, $5 }' | sed 's/ $//'
exit 0
