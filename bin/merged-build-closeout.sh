#!/bin/bash
# bin/merged-build-closeout.sh [--apply] [--project P] [--since ISO]
#
# BH-7731: a one-time (and safely re-runnable) backfill. It finds open
# `ai-build` issues whose build PR already merged, and closes the ones that the
# merge delivered. It is NOT a cron lane; an operator runs it on the hub. The
# recurring retry is the `issue-close-owed` marker that bin/lib/mc/settle.sh and
# bin/merge-sweep.sh share.
#
#   dry run (default) : reads and decides, writes only the log.
#   --apply           : closes each `close` verdict through issue_close_shipped
#                       (comment, close, strip `ai-build`), one CLOSED audit
#                       line per close in the log.
#   --project P       : only project P (it must be issue-driven, board prefix -).
#   --since ISO       : merged PRs from this UTC time on, as
#                       YYYY-MM-DDTHH:MM:SSZ (default: MBC_SINCE_DAYS, 14,
#                       days before now).
#
# Per project (every fleet-conf row with board prefix `-`, or --project):
#   1. One paged read of open `ai-build` issues.
#   2. One paged read of closed PRs, newest update first, stopped at the first
#      page that reaches back past --since. MBC_PR_PAGE_CAP (10) full pages is a capped read:
#      every issue of that project is `skip:capped`, never "no PR".
#   3. Per issue #n, key <PREFIX>-n (the prefix from the title `^<PREFIX>-n:`,
#      else from prompts/<project>.md's launch line): the newest merged PR whose
#      title starts `<KEY>:` (any case; `<KEY>.2:`, `<KEY>0:` and two-key titles
#      do not match) or whose head ref is `ticket/<key>` or `ticket/<key>-r<N>`.
#   4. A PR whose every file is `*.md` or under `docs/` is `keep:docs-only`.
#   5. issue_close_guard (bin/lib/issue-state-lib.sh) decides. A title alone
#      never closes: `close` needs a closing keyword for #n and no open child.
#
# Verdicts: close | keep:<why> (no-pr, docs-only, slice:<guard word>) |
#   skip:<why> (no-key, capped, files-read, files-capped, the guard's unknown
#   word, already-closed, close-deferred). With --apply a landed close is
#   `closed`. Only `close` is ever written to GitHub.
#
# Output: one TSV line per open issue, on stdout and in
# logs/merged-build-closeout.log:
#   <stamp> <project> #<n> <KEY> <verdict> <pr-url|->
# then one summary line in the same six fields:
#   <stamp> <project|all> summary - checked N, close C, keep K, skip S, closed X (dry-run|apply) -
# --apply writes one jobs-DB ledger row per posted comment, kind
# `mbc-issue-commented`, key `<slug>#<n>@pr<prn>`, so a re-run never comments
# twice. A ledger read that cannot answer is `skip:ledger-read`: no comment, no
# close (fail closed, never a second comment).
#
# Exit: 0 the run finished; 1 a list read failed for every project; 2 bad
# arguments.
#
# gh-rest: no-graphql
set -uo pipefail

HARNESS="${HARNESS:-/root/harness}"
APPLY=0; PROJECT=""; SINCE=""
usage() { echo "usage: merged-build-closeout.sh [--apply] [--project P] [--since YYYY-MM-DDTHH:MM:SSZ]" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --project) [ $# -ge 2 ] && [ -n "$2" ] || usage; PROJECT="$2"; shift 2 ;;
    --since) [ $# -ge 2 ] || usage; SINCE="$2"; shift 2 ;;
    -h|--help) sed -n '2,48p' "$0"; exit 0 ;;
    *) usage ;;
  esac
done
command -v jq >/dev/null 2>&1 || { echo "merged-build-closeout: jq missing" >&2; exit 2; }

LIB="$HARNESS/bin/lib"
# shellcheck source=bin/lib/gh-rest-list.sh
. "$LIB/gh-rest-list.sh" 2>/dev/null
# shellcheck source=bin/lib/issue-state-lib.sh
. "$LIB/issue-state-lib.sh" 2>/dev/null
command -v gh_rest_issue_list >/dev/null 2>&1 && command -v issue_close_guard >/dev/null 2>&1 \
  || { echo "merged-build-closeout: bin/lib/gh-rest-list.sh or bin/lib/issue-state-lib.sh missing" >&2; exit 2; }
# shellcheck source=bin/lib/gh-app-auth.sh
[ -r "$LIB/gh-app-auth.sh" ] && . "$LIB/gh-app-auth.sh" 2>/dev/null
# The comment-once marker is a ledger row, not a state/ file (docs/STATE-STORES.md).
# jobs-client.sh EXITS the shell that sources it without its modules.
# shellcheck source=bin/jobs-client.sh
[ -r "$HARNESS/bin/jobs-client.sh" ] && [ -r "$LIB/jobs/req.sh" ] && . "$HARNESS/bin/jobs-client.sh" 2>/dev/null

# Knobs: registry entry catalog/lanes.d/_lib.merged-build-closeout.json, rows
# lib.merged-build-closeout.<env>. lib_env_apply exports a row (clamped to the
# registry's min/max); with no row the env stays, else the fallback below.
# shellcheck source=bin/lib/lane-gate.sh
[ -r "$LIB/lane-gate.sh" ] && . "$LIB/lane-gate.sh" 2>/dev/null
command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply merged-build-closeout 2>/dev/null
# mbc_int <value> <fallback>: a whole number of at least 1, else the fallback.
mbc_int() { case "${1:-}" in ''|*[!0-9]*|0|0*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac; }
PR_PAGE_CAP=$(mbc_int "${MBC_PR_PAGE_CAP:-}" 10)        # 10: fallback of row lib.merged-build-closeout.mbc_pr_page_cap
FILES_PAGE_CAP=$(mbc_int "${MBC_FILES_PAGE_CAP:-}" 3)   # 3: fallback of row lib.merged-build-closeout.mbc_files_page_cap
ISSUE_CAP=$(mbc_int "${MBC_ISSUE_CAP:-}" 1000)          # 1000: fallback of row lib.merged-build-closeout.mbc_issue_cap
SINCE_DAYS=$(mbc_int "${MBC_SINCE_DAYS:-}" 14)          # 14: fallback of row lib.merged-build-closeout.mbc_since_days

[ -n "$SINCE" ] || SINCE=$(date -u -d "$SINCE_DAYS days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
[[ "$SINCE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
  || { echo "merged-build-closeout: --since needs YYYY-MM-DDTHH:MM:SSZ, got '$SINCE'" >&2; exit 2; }

FC="$HARNESS/bin/fleet-conf.sh"
if [ -n "$PROJECT" ]; then
  [ "$("$FC" "$PROJECT" board_prefix 2>/dev/null)" = - ] \
    || { echo "merged-build-closeout: $PROJECT is not an issue-driven project (board prefix is not -)" >&2; exit 2; }
  PROJECTS="$PROJECT"
else
  PROJECTS=""
  for p in $("$FC" --projects 2>/dev/null); do
    [ "$("$FC" "$p" board_prefix 2>/dev/null)" = - ] && PROJECTS="$PROJECTS $p"
  done
fi

LOG="$HARNESS/logs/merged-build-closeout.log"
LEDGER_KIND=mbc-issue-commented
mkdir -p "$HARNESS/logs" || { echo "merged-build-closeout: cannot create $HARNESS/logs" >&2; exit 2; }
MODE=dry-run; [ "$APPLY" = 1 ] && MODE=apply
WORK=$(mktemp -d "${TMPDIR:-/tmp}/mbc.XXXXXX") || exit 2
trap 'rm -rf "$WORK"' EXIT
stamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }
# line <project> <#n> <key> <verdict> <url>: the one TSV shape, stdout and log.
line() {
  local l
  l=$(printf '%s\t%s\t%s\t%s\t%s\t%s' "$(stamp)" "$1" "$2" "$3" "$4" "${5:--}")
  printf '%s\n' "$l"; printf '%s\n' "$l" >> "$LOG"
}
# mbc_mark_commented <ledger-key> <pr-url>: write the comment-once row. A put
# that fails leaves one LEDGER-PUT-FAILED log line (a re-run can comment again).
mbc_mark_commented() {
  command -v job_ledger_put >/dev/null 2>&1 \
    && job_ledger_put "$LEDGER_KIND" "$1" commented "pr=$2" >/dev/null 2>&1 </dev/null && return 0
  printf '%s LEDGER-PUT-FAILED %s %s\n' "$(stamp)" "$LEDGER_KIND" "$1" >> "$LOG"
}
mbc_auth() {
  if command -v gh_default_auth_for_slug >/dev/null 2>&1; then gh_default_auth_for_slug "$1" >/dev/null 2>&1 || true; fi
}

# mbc_prefix <project>: the key prefix from the launch line in prompts/<project>.md
# (the read bin/lib/preplan-lib.sh:preplan_key_prefix does). Nothing when absent.
mbc_prefix() {
  grep -ohE '\b[A-Z]{1,6}-<issue-number>' "$HARNESS/prompts/$1.md" 2>/dev/null | head -1 | cut -d- -f1
}

# mbc_closed_prs <slug> <out-file>: closed PRs, newest update first, merged on or
# after SINCE, as a JSON array. rc 0 read to its end, 1 a page failed, 3 capped
# (MBC_PR_PAGE_CAP full pages).
mbc_closed_prs() {
  local slug="$1" out="$2" p=1 n oldest
  printf '[]' > "$out"
  while [ "$p" -le "$PR_PAGE_CAP" ]; do
    gh_rest GET "repos/$slug/pulls?state=closed&sort=updated&direction=desc&per_page=100&page=$p" > "$WORK/page.json" || return 1
    n=$(jq 'if type == "array" then length else -1 end' "$WORK/page.json" 2>/dev/null) || return 1
    [ "${n:--1}" -ge 0 ] || return 1
    jq -c -s --arg s "$SINCE" '.[0] + [.[1][] | select(type == "object" and (.merged_at // "") >= $s)
        | {number, html_url, title: (.title // ""), ref: (.head.ref // ""), merged_at}]' \
      "$out" "$WORK/page.json" > "$out.tmp" 2>/dev/null && mv -f "$out.tmp" "$out" || return 1
    [ "$n" -lt 100 ] && return 0
    oldest=$(jq -r '.[-1].updated_at // ""' "$WORK/page.json")
    [ -n "$oldest" ] && [[ "$oldest" < "$SINCE" ]] && return 0
    p=$((p + 1))
  done
  return 3
}

# mbc_match <prs-file> <key>: the newest merged PR for <key>, as "<number> <url>".
mbc_match() {
  local k K
  k=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]'); K=$(printf '%s' "$2" | tr '[:lower:]' '[:upper:]')
  jq -r --arg k "$k" --arg K "$K" '
    [ .[] | select((.title | ascii_upcase | startswith($K + ":"))
                   or (.ref | ascii_downcase | test("^ticket/" + $k + "(-r[0-9]+)?$"))) ]
    | sort_by(.merged_at) | last // empty | "\(.number) \(.html_url)"' "$1" 2>/dev/null
}

# mbc_docs_only <slug> <pr-number>: rc 0 every file is *.md or under docs/,
# 1 a code file is there, 2 the read failed, 3 MBC_FILES_PAGE_CAP (3) full pages (capped).
mbc_docs_only() {
  local p=1 n
  : > "$WORK/files.txt"
  while [ "$p" -le "$FILES_PAGE_CAP" ]; do
    gh_rest GET "repos/$1/pulls/$2/files?per_page=100&page=$p" > "$WORK/files.json" || return 2
    n=$(jq 'if type == "array" then length else -1 end' "$WORK/files.json" 2>/dev/null) || return 2
    [ "${n:--1}" -ge 0 ] || return 2
    jq -r '.[].filename // empty' "$WORK/files.json" >> "$WORK/files.txt"
    grep -qvE '(^docs/|\.md$)' "$WORK/files.txt" && return 1
    [ "$n" -lt 100 ] && { [ -s "$WORK/files.txt" ] && return 0; return 1; }
    p=$((p + 1))
  done
  return 3
}

CHECKED=0; NCLOSE=0; NKEEP=0; NSKIP=0; NCLOSED=0; TRIED=0; READ_OK=0
for P in $PROJECTS; do
  TRIED=$((TRIED + 1))
  SLUG=$("$FC" "$P" repo 2>/dev/null)
  [ -n "$SLUG" ] || { line "$P" - - skip:no-repo -; continue; }
  mbc_auth "$SLUG"
  if ! gh_rest_issue_list "$SLUG" open ai-build "$ISSUE_CAP" > "$WORK/issues.json"; then
    line "$P" - - "skip:issue-list-read" -; continue
  fi
  PRC=0; mbc_closed_prs "$SLUG" "$WORK/prs.json" || PRC=$?
  if [ "$PRC" = 1 ]; then line "$P" - - "skip:pr-list-read" -; continue; fi
  READ_OK=$((READ_OK + 1))
  PFX=$(mbc_prefix "$P")
  while IFS=$'\t' read -r N TITLE; do
    [ -n "$N" ] || continue
    CHECKED=$((CHECKED + 1))
    KEY=$(printf '%s' "$TITLE" | grep -oE "^[A-Z]+-$N:" | head -1); KEY="${KEY%:}"
    [ -n "$KEY" ] || { [ -n "$PFX" ] && KEY="$PFX-$N"; }
    if [ -z "$KEY" ]; then NSKIP=$((NSKIP + 1)); line "$P" "#$N" - skip:no-key -; continue; fi
    if [ "$PRC" = 3 ]; then NSKIP=$((NSKIP + 1)); line "$P" "#$N" "$KEY" skip:capped -; continue; fi
    M=$(mbc_match "$WORK/prs.json" "$KEY")
    if [ -z "$M" ]; then NKEEP=$((NKEEP + 1)); line "$P" "#$N" "$KEY" keep:no-pr -; continue; fi
    PRN="${M%% *}"; URL="${M#* }"
    DRC=0; mbc_docs_only "$SLUG" "$PRN" || DRC=$?
    case "$DRC" in
      0) NKEEP=$((NKEEP + 1)); line "$P" "#$N" "$KEY" keep:docs-only "$URL"; continue ;;
      2) NSKIP=$((NSKIP + 1)); line "$P" "#$N" "$KEY" skip:files-read "$URL"; continue ;;
      3) NSKIP=$((NSKIP + 1)); line "$P" "#$N" "$KEY" skip:files-capped "$URL"; continue ;;
    esac
    G=$(issue_close_guard "$SLUG" "$N" "$URL" "" "$HARNESS")
    case "$G" in
      close) ;;
      slice:*) NKEEP=$((NKEEP + 1)); line "$P" "#$N" "$KEY" "keep:$G" "$URL"; continue ;;
      *) NSKIP=$((NSKIP + 1)); line "$P" "#$N" "$KEY" "skip:${G#unknown:}" "$URL"; continue ;;
    esac
    NCLOSE=$((NCLOSE + 1))
    if [ "$APPLY" != 1 ]; then line "$P" "#$N" "$KEY" close "$URL"; continue; fi
    # ── apply: re-read the issue, then comment, close, strip ──────────────────
    # A plain call into a file, not $( ): the helper's status stays in this shell
    # (tests/gh-rest-no-subshell-lint.sh).
    ST=""; gh_rest_issue_state "$SLUG" "$N" > "$WORK/state.txt" 2>/dev/null && ST=$(head -n 1 "$WORK/state.txt")
    if [ "$ST" = closed ]; then NSKIP=$((NSKIP + 1)); line "$P" "#$N" "$KEY" skip:already-closed "$URL"; continue; fi
    if [ "$ST" != open ]; then NSKIP=$((NSKIP + 1)); line "$P" "#$N" "$KEY" skip:issue-read "$URL"; continue; fi
    # The comment-once row: rc 0 = the comment already posted, rc 2 = no row,
    # anything else = the ledger cannot answer, so skip (fail closed).
    MKEY="$SLUG#$N@pr$PRN"; LRC=1
    command -v job_ledger_get >/dev/null 2>&1 && { job_ledger_get "$LEDGER_KIND" "$MKEY" >/dev/null 2>&1 </dev/null; LRC=$?; }
    BODY="Merged in $URL, but the issue stayed open. Closing it now (BH-7731 backfill)."
    case "$LRC" in
      0) BODY="" ;;
      2) ;;
      *) NSKIP=$((NSKIP + 1)); line "$P" "#$N" "$KEY" skip:ledger-read "$URL"; continue ;;
    esac
    if W=$(issue_close_shipped "$SLUG" "$N" "$BODY" "$HARNESS" "$URL" ""); then
      [ -n "$BODY" ] && case "$W" in *comment-failed*) ;; *) mbc_mark_commented "$MKEY" "$URL" ;; esac
      NCLOSED=$((NCLOSED + 1))
      line "$P" "#$N" "$KEY" closed "$URL"
      printf '%s CLOSED %s #%s by %s (%s)\n' "$(stamp)" "$P" "$N" "$URL" "$W" >> "$LOG"
    else
      # A close that failed after the comment posted still paid the comment.
      [ -n "$BODY" ] && case "$W" in close-failed) mbc_mark_commented "$MKEY" "$URL" ;; esac
      NSKIP=$((NSKIP + 1)); line "$P" "#$N" "$KEY" skip:close-deferred "$URL"
      printf '%s DEFERRED %s #%s by %s (%s)\n' "$(stamp)" "$P" "$N" "$URL" "${W:-no answer}" >> "$LOG"
    fi
  done < <(jq -r '.[] | select(type == "object") | "\(.number)\t\(.title // "" | gsub("[\t\n]"; " "))"' "$WORK/issues.json" 2>/dev/null)
done

line "${PROJECT:-all}" summary - "checked $CHECKED, close $NCLOSE, keep $NKEEP, skip $NSKIP, closed $NCLOSED ($MODE)" -
[ "$TRIED" -gt 0 ] && [ "$READ_OK" = 0 ] && exit 1
exit 0
