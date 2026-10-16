#!/bin/bash
# bin/pr-owner-close-replay.sh [--days N] [--repo <owner/repo>]...
#
# Replay the done-ticket closes bin/pr-owner-sweep.sh made in the last N days
# (default 7) and print which ones the done-ticket close guard
# (bin/lib/pr-owner/shipped.sh, docs/PR-OWNERSHIP.md §11) would have kept open.
# Read-only: GitHub REST reads, no write, no state file. Repos: every --repo,
# else every repo in fleet.conf plus PR_OWNER_EXTRA_REPOS.
#
# A close is a PR comment with the sweep footer `_bin/pr-owner-sweep.sh` and one
# of the close texts: superseded rule 1 (rule=merged), rule 2 (rule=ticket), the
# ORPHAN close-duplicate arm (rule=close-dup), or rule 3 (rule=duplicate, never
# guarded, would=n/a). For each guarded close at time T it rebuilds the inputs:
#   labels       issue events labeled/unlabeled up to T
#   activity     the latest of the PR's created_at, its newest commit with a
#                committer date up to T, and its newest comment before T that
#                is not the sweep's
#   main         the newest default-branch commit up to T (commits?until=T)
#   shipped      po_shipped on the PR's CURRENT head against that main
#   conductor    no history, so not replayed (never counted)
# Per PR it reads one page (100) of events, commits and comments; the header
# says so.
# and calls the lane's own po_done_skip_reason and po_shipped, so the replay
# and the lane cannot drift. The knobs are the lane's (lane.pr-owner-sweep.*
# settings rows, then the env, then the defaults).
#
# OUTPUT: `#` header lines, then one TSV row per close:
#   <repo> #<n> closed_at=<T> rule=<r> now=<open|closed|merged|-> would=<skip|close|n/a|unreadable> reasons=<r,...|->
# and last `replay: days=N closes=C would_skip=S would_close=K n/a=A unreadable=U`.
# C counts every close row. U counts the repos whose comments could not be read
# plus the closes whose inputs could not be read (would=unreadable). Exit 0.
set -uo pipefail
H="${HARNESS:-/root/harness}"
. "$H/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")
export HARNESS="$H"
[ -f "$H/fleet.conf" ] && export FLEET_CONF="${FLEET_CONF:-$H/fleet.conf}"

DAYS=7; REPOS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --days)   DAYS="${2:-}"; shift ;;
    --days=*) DAYS="${1#--days=}" ;;
    --repo)   REPOS+=("${2:-}"); shift ;;
    --repo=*) REPOS+=("${1#--repo=}") ;;
    -h|--help) awk 'NR > 1 { if ($0 !~ /^#/) exit; print }' "$0"; exit 0 ;;
    *) echo "pr-owner-close-replay.sh: unexpected argument $1" >&2; exit 2 ;;
  esac
  shift
done
[[ $DAYS =~ ^[0-9]+$ ]] && [ "$DAYS" -gt 0 ] || { echo "pr-owner-close-replay.sh: --days takes a whole number above 0" >&2; exit 2; }

if [ -f "$HENV/global.env" ]; then set -a
  # shellcheck disable=SC1091
  . "$HENV/global.env" 2>/dev/null; set +a; fi
# shellcheck disable=SC1091
. "$H/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply pr-owner-sweep 2>/dev/null
# shellcheck source=bin/lib/gh-rest.sh
. "$(dirname "$0")/lib/gh-rest.sh" || exit 1
# shellcheck source=bin/lib/pr-owner/shipped.sh
. "$(dirname "$0")/lib/pr-owner/shipped.sh" || exit 1
# shellcheck source=bin/lib/gh-repo-token.sh
[ -r "$H/bin/lib/gh-repo-token.sh" ] && . "$H/bin/lib/gh-repo-token.sh" 2>/dev/null
# shellcheck source=bin/lib/gh-app-auth.sh
[ -r "$H/bin/lib/gh-app-auth.sh" ] && . "$H/bin/lib/gh-app-auth.sh"
command -v jq >/dev/null 2>&1 || { echo "pr-owner-close-replay.sh: jq missing" >&2; exit 1; }

PAGE_CAP=10   # comment pages per repo (100 each); a full last page is reported
NOW=$(_po_sh_num "${PR_OWNER_NOW:-}" "$(date -u +%s)")
SINCE=$(date -u -d "@$(( NOW - DAYS * 86400 ))" '+%Y-%m-%dT%H:%M:%SZ')
PO_SHIPPED_MEMO=0   # the memo is the lane's; a replay never writes one
TD=$(mktemp -d) || exit 1
trap 'rm -rf "$TD"' EXIT

if [ "${#REPOS[@]}" = 0 ]; then
  for P in $("$H/bin/fleet-conf.sh" --projects 2>/dev/null); do
    S=$("$H/bin/fleet-conf.sh" "$P" repo 2>/dev/null) || continue
    [ -n "$S" ] && [ "$S" != - ] && REPOS+=("$S")
  done
  for S in ${PR_OWNER_EXTRA_REPOS:-}; do REPOS+=("$S"); done
fi

# get <out> <path> — one REST read into a file; rc is gh_rest's.
get() { gh_rest GET "$2" > "$1" </dev/null; }

echo "# replay of bin/pr-owner-sweep.sh done-ticket closes since $SINCE (days=$DAYS), read-only"
echo "# approximations: labels from issue events up to T; activity = max(PR created_at, newest PR commit dated <= T, newest non-sweep PR comment before T);"
echo "# main = newest default-branch commit dated <= T; shipped = the PR's CURRENT head files against that main; conductor state at T is not replayed;"
echo "# per PR only the first page (100) of events, commits and comments is read"
printf 'repo\tpr\tclosed_at\trule\tnow\twould\treasons\n'

C=0; S=0; K=0; A=0; U=0
# unread <why> — a close whose inputs could not be read: printed, counted in U.
unread() { printf '%s\t#%s\tclosed_at=%s\trule=%s\tnow=%s\twould=unreadable\treasons=%s\n' "$SLUG" "$NUM" "$T" "$RULE" "${NOWST:--}" "$1"; U=$((U+1)); }
declare -A SEEN
for SLUG in "${REPOS[@]}"; do
  [ -n "$SLUG" ] && [ -z "${SEEN[$SLUG]:-}" ] || continue
  SEEN[$SLUG]=1
  if command -v gh_repo_use_token >/dev/null 2>&1 && ! gh_repo_use_token "$SLUG" </dev/null >/dev/null 2>&1; then
    echo "# $SLUG: unreadable (no token can see it)"; U=$((U+1)); continue
  fi
  command -v gh_auth_for >/dev/null 2>&1 && { gh_auth_for "$SLUG" </dev/null >/dev/null 2>&1 || true; }
  echo '[]' > "$TD/all.json"; bad=0; pg=1; full=0
  while [ "$pg" -le "$PAGE_CAP" ]; do
    get "$TD/page.json" "repos/$SLUG/issues/comments?since=$SINCE&per_page=100&page=$pg" || { bad=1; break; }
    n=$(jq -r 'if type == "array" then length else "!" end' "$TD/page.json" 2>/dev/null) || n="!"
    [[ $n =~ ^[0-9]+$ ]] || { bad=1; break; }
    jq -s '.[0] + .[1]' "$TD/all.json" "$TD/page.json" > "$TD/next.json" && mv "$TD/next.json" "$TD/all.json"
    full=0; [ "$n" -ge 100 ] && full=1
    [ "$full" = 1 ] || break
    pg=$((pg+1))
  done
  if [ "$bad" = 1 ]; then echo "# $SLUG: unreadable (issue comments since $SINCE, HTTP ${GH_REST_STATUS:-000})"; U=$((U+1)); continue; fi
  [ "$full" = 1 ] && echo "# $SLUG: more than $((PAGE_CAP * 100)) comments since $SINCE; only the first $PAGE_CAP pages are replayed"
  jq -r '.[] | select((.html_url // "") | test("/pull/[0-9]+"))
         | select((.body // "") | contains("_bin/pr-owner-sweep.sh"))
         | .body as $b
         | (if ($b | test("is marked (done|rejected) on the board")) then "ticket"
            elif ($b | test("Closing this one: \\*\\*.* already shipped in #[0-9]+\\*\\*")) then "close-dup"
            elif ($b | test("already shipped in #[0-9]+, so this branch is a leftover")) then "merged"
            elif ($b | test("that we.re landing, so this one is a duplicate")) then "duplicate"
            else empty end) as $r
         | [(.issue_url | split("/") | last), .created_at, $r] | @tsv' "$TD/all.json" 2>/dev/null \
    | sort -t$'\t' -k2,2 > "$TD/closes.tsv"
  while IFS=$'\t' read -r NUM T RULE; do
    [ -n "$NUM" ] || continue
    C=$((C+1))
    if [ "$RULE" = duplicate ]; then
      printf '%s\t#%s\tclosed_at=%s\trule=%s\tnow=-\twould=n/a\treasons=-\n' "$SLUG" "$NUM" "$T" "$RULE"; A=$((A+1)); continue
    fi
    NOWST=""
    get "$TD/pr.json" "repos/$SLUG/pulls/$NUM" || { unread "pr-read"; continue; }
    NOWST=$(jq -r 'if .merged_at then "merged" else (.state // "-") end' "$TD/pr.json" 2>/dev/null)
    HEAD=$(jq -r '.head.sha // ""' "$TD/pr.json" 2>/dev/null)
    CREATED=$(jq -r '.created_at // ""' "$TD/pr.json" 2>/dev/null)
    [ -n "$HEAD" ] && [ -n "$CREATED" ] || { unread "pr-fields"; continue; }
    get "$TD/ev.json" "repos/$SLUG/issues/$NUM/events?per_page=100" || { unread "events-read"; continue; }
    LABELS=$(jq -r --arg t "$T" '[.[] | select(.created_at <= $t and (.event == "labeled" or .event == "unlabeled"))]
               | reduce .[] as $e ({}; if $e.event == "labeled" then .[$e.label.name] = 1 else del(.[$e.label.name]) end)
               | keys[]' "$TD/ev.json" 2>/dev/null) || { unread "events-parse"; continue; }
    get "$TD/cm.json" "repos/$SLUG/pulls/$NUM/commits?per_page=100" || { unread "commits-read"; continue; }
    LC=$(jq -r --arg t "$T" '[.[] | .commit.committer.date // empty | select(. <= $t)] | max // ""' "$TD/cm.json" 2>/dev/null)
    get "$TD/th.json" "repos/$SLUG/issues/$NUM/comments?per_page=100" || { unread "comments-read"; continue; }
    LT=$(jq -r --arg t "$T" '[.[] | select(.created_at < $t and ((.body // "") | contains("_bin/pr-owner-sweep.sh") | not)) | .created_at] | max // ""' "$TD/th.json" 2>/dev/null)
    ACT=$(printf '%s\n' "$CREATED" "$LC" "$LT" | sort | tail -n 1)
    get "$TD/main.json" "repos/$SLUG/commits?until=$T&per_page=1" || { unread "main-read"; continue; }
    MAIN=$(jq -r '.[0].sha // ""' "$TD/main.json" 2>/dev/null)
    [[ $MAIN =~ ^[0-9a-f]{40}$ ]] || { unread "main-sha"; continue; }
    TE=$(jq -rn --arg t "$T" '$t | fromdateiso8601' 2>/dev/null)
    [[ $TE =~ ^[0-9]+$ ]] || { unread "closed_at"; continue; }
    REASONS=""
    R1=$(po_done_skip_reason "$LABELS" - "$ACT" "$TE") && REASONS="$R1"
    OUT=$(po_shipped "$SLUG" "$NUM" "$HEAD" "$MAIN"); SRC=$?
    case "$SRC" in
      0) ;;
      1) REASONS="${REASONS:+$REASONS,}unshipped:${OUT#unshipped }" ;;
      *) REASONS="${REASONS:+$REASONS,}shipped-unknown:${OUT#unknown }" ;;
    esac
    if [ -n "$REASONS" ]; then W=skip; S=$((S+1)); else W=close; K=$((K+1)); fi
    printf '%s\t#%s\tclosed_at=%s\trule=%s\tnow=%s\twould=%s\treasons=%s\n' "$SLUG" "$NUM" "$T" "$RULE" "${NOWST:--}" "$W" "${REASONS:--}"
  done < "$TD/closes.tsv"
  command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset
done
echo "replay: days=$DAYS closes=$C would_skip=$S would_close=$K n/a=$A unreadable=$U"
exit 0
