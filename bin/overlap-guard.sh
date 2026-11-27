#!/bin/bash
# bin/overlap-guard.sh <project> <KEY> — MAY THIS TICKET START BUILDING NOW, or
# would it land on files something else is already holding?
#
# THE NUMBER THIS EXISTS FOR (2026-09-15). In 24h logs/merge-conductor.log holds
# ~144 DIRTY/conflict events and 33 rebases on project-5 against ~100 merges,
# and bin/blocked-resolver.sh ran 121 rebuilds. That is not a merge problem. It
# is a SCHEDULING problem: parallel builds on one hot repo are handed the same
# files, they each write a correct diff, and the second one to reach main pays
# for it — a rebase, a moved head, a re-review, and often a rebuild from scratch.
# Every one of those is bought AFTER the money was spent on the build.
#
# So the question is asked BEFORE the build is launched, when the answer costs
# one tick of delay instead of one wasted session. The pre-plan stage already
# wrote down what a ticket intends to touch (bin/run-preplan.sh ->
# plans/<project>-<KEY>/planned-files.txt, via bin/lib/preplan-lib.sh's
# preplan_record and bin/planned-files.sh), so the list is free to read.
#
# WHAT IT COMPARES AGAINST — two sets, and the second is the new one:
#   1. every ticket of this project with a RUNNING row in the jobs ledger
#      (bin/jobs-client.sh, /api/jobs?status=running) — fleet-wide, so a sibling
#      building on another box or a Fly machine counts.
#   2. every OPEN harness-authored PR on this project's repo, and the files it
#      actually changed (bin/lib/gh-pr-list.sh). When the snapshot is fresh it
#      came from `--refresh` (BH-9440, below): every author's open PR, plus
#      main@<sha12> rows for recent commits on the default branch.
# (2) is the half nothing had before. bin/conflict-check.sh and
# bin/plan-overlap.sh both ask (1) in their own way, at PLAN time, inside
# bin/run-build.sh — but an approved PR that has not merged yet still owns its
# files, and a build launched onto them conflicts with a diff that is already
# written. Most of those 144 DIRTY events are exactly that shape.
#
# HOW IT ANSWERS:
#   rc 0, stdout "LAUNCH <KEY> ..."   — go. Also the answer to every error.
#   rc 1, stdout "DEFER <KEY> vs <other> jaccard=<x> files=[a,b,c]"
#                                     — the caller must NOT launch and must
#      re-offer the ticket next tick, the same "not now, not a failure"
#      semantics as BUILD_DEFERRED (CLAUDE.md; docs/RUN-BUILD-GRAPH.md rows 7-9).
#      NOTHING HERE QUEUES ANYTHING — locks and deferrals in this harness are
#      dedupe, never a queue (the operator, 2026-09-13).
#   rc 1, stdout "DEFER <KEY> gh unknown (HTTP <s>) open-PR list unreadable, no
#      cache; re-offered next tick"   — the ONE non-fail-open verdict, below.
#   rc 1, stdout "DEFER <KEY> open-PR snapshot incomplete (<why>); re-offered
#      next tick"                     — BH-9440: the last --refresh hit
#      OVERLAP_REFRESH_PR_LIMIT (marker state/overlap-guard/<p>-prs.incomplete).
#
# FAIL-OPEN, WITH ONE EXCEPTION. No pre-plan, no ledger, no gh binary, a bad
# config, an unreadable file: LAUNCH, with a line in logs/overlap-guard.log
# saying which question could not be asked. A missed overlap costs one rebase —
# which is what today already costs — and a fabricated one costs a build that
# never runs.
#
# THE EXCEPTION (BH-782): the open-PR list came back UNREADABLE and there is no
# cached copy. That is not the same as the other unanswerable questions, because
# the half that went missing is the one holding work ALREADY WRITTEN: under the
# #768 rate limit the list answered empty, "empty" read as "no overlap", and
# this guard launched builds on top of live PRs. So that one case DEFERs and the
# ticket is re-offered next tick. A cache — even a stale one — is still used:
# stale-but-real beats none. The cache is NEVER overwritten by a failed read.
# That arm is also the only one here that HOLDS work, so it writes one
# ALERTS.log line per project per UTC day naming what is stuck and what would
# unstick it — on a box with no cache it stops every launch for the project,
# and a stop nobody is told about is indistinguishable from silence.
#
# This file makes no `gh` call of its own; it rides bin/lib/gh-pr-list.sh, which
# still uses the per-author GraphQL list for `files` (a GraphQL-only LIST
# field). Riding GraphQL is not the same as reading an outage as empty: since
# BH-782 an author that exits 0 and prints nothing counts as a FAILED author, so
# the #768 shape arrives here as a non-zero rc rather than as an empty list.
#
# gh-rest: no-graphql
#
# KILL FLAG: flags/overlap-guard-off (fleet-wide, from the console, or the
# `switch.overlap-guard-off` settings row),
# flags/overlap-guard-off-<project> (one project), and OVERLAP_GUARD=0 in the
# environment. Any of them makes this exit 0 having read nothing, so the launch
# path is byte-for-byte what it was before.
#
# Config (flags/scheduler.conf, defaults in bin/lib/scheduler-conf.sh and
# docs/SCHEDULER.md): OVERLAP_THRESHOLD, OVERLAP_IGNORE, OVERLAP_PR_LIMIT,
# OVERLAP_PR_CACHE_SECS, OVERLAP_LEDGER_LIMIT.
set -uo pipefail
PROJECT="${1:-}"; KEY="${2:-}"
HARNESS="${HARNESS:-/root/harness}"
LOG="$HARNESS/logs/overlap-guard.log"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
say() { mkdir -p "$HARNESS/logs" 2>/dev/null; echo "$(STAMP) [$PROJECT/$KEY] $*" >> "$LOG"; }
# EVERY fail-open path goes through here, and every one of them writes its line:
# a guard that stopped being able to ask a question must leave the reason in the
# log, or a conflict that lands anyway is indistinguishable from a gate that
# quietly stopped running.
launch() { say "LAUNCH — $1"; printf 'LAUNCH %s %s\n' "$KEY" "$1"; exit 0; }

# --- --refresh <project> (BH-9440) ----------------------------------------------
# THE HUB PR SNAPSHOT, EVERY AUTHOR. state/overlap-guard/<p>-prs.json was
# written only when this guard ran a launch check, and the pool path never runs
# one on the hub. So bin/sibling-serial.sh read no snapshot and noted
# `prs=unread` on every tick. bin/fly-pool.sh now calls `--refresh <project>`
# once per project per tick when the file is older than OVERLAP_PR_CACHE_SECS.
# It writes the same JSON shape the guard writes, for EVERY open PR (a client's
# or a person's PR owns its files as much as a harness PR does):
#   {number, url, headRefName, isDraft, author, files:[{path}]}
# and, when OVERLAP_MAIN_RECENT_MIN > 0 (default 60; settings row
# lib.sibling-serial.overlap_main_recent_min, or conf.scheduler.*), one row per
# non-merge commit on the default branch in that window:
#   {number:0, headRefName:"main@<sha12>", author:"main", files:[...]}
# The guard judges a main@ row as an owner (`DEFER <K> vs main@<sha12>`). The
# branch name carries `@`, so the sibling-key and stack-branch readers
# (sibling-serial, overlap-schedule: ^[A-Za-z0-9._/-]+$) skip it by
# construction.
# Every read goes through the REST seam (bin/lib/gh-rest.sh, gh-rest-list.sh).
# A PR's file list is cached under state/overlap-guard/<p>-files/<n>.<head sha>
# and a commit's under main.<sha>, so a tick reads only the PR list, the commit
# list and what changed. The cache is pruned to the PRs and commits of the
# snapshot just written.
# A FAILED READ keeps the old snapshot (never written over by a partial one) and
# writes ONE ALERTS line per project per UTC day (marker
# state/overlap-guard/<p>.alerted-<YYYY-MM-DD>; markers older than 2 days are
# deleted here). stdout: one `REFRESH <p> ok prs=<n> main=<m>` or
# `REFRESH <p> failed ...` line. rc 0 always.
# EVERY OPEN PR, NOT 30 (BH-9440 review). The list is read up to
# OVERLAP_REFRESH_PR_LIMIT rows in total (default 500, capped at 999 by the
# seam's 10-page stop). OVERLAP_PR_LIMIT keeps its per-author meaning for the
# guard's own list. The refresh asks for one row more than the cap. If that row
# comes back, the snapshot holds the first <cap> PRs and the marker
# state/overlap-guard/<p>-prs.incomplete is written; while it exists the launch
# check DEFERs every ticket (fail closed, never "no overlap"), one ALERTS line
# per project per UTC day. A complete refresh deletes the marker.
# og_prr_arm — BH-10218 W4: load bin/lib/prr-shadow.sh and this guard's seam
# (bin/lib/prr-shadow.d/overlap-guard.sh) and pin the step once. overlap-guard
# is not a lane, so its knob GH_SOURCE is the lib row lib.overlap-guard.gh_source
# (catalog/lanes.d/_lib.overlap-guard.json, default shadow), resolved with
# lib_env_apply in a subshell. A GH_SOURCE a parent lane pinned for itself
# (GH_SOURCE_LANE=<parent>) is not this guard's step. rc 1 = no seam: the
# caller makes today's read.
OG_PRR=""
og_prr_arm() {
  local v _d
  [ -n "$OG_PRR" ] && { [ "$OG_PRR" = 1 ]; return; }
  OG_PRR=0
  _d=$(dirname "$0")
  # shellcheck source=bin/lib/prr-shadow.sh
  . "$_d/lib/prr-shadow.sh" 2>/dev/null && prr_seam_load overlap-guard 2>/dev/null || return 1
  if [ -n "${GH_SOURCE_LANE:-}" ] && [ "$GH_SOURCE_LANE" != overlap-guard ]; then unset GH_SOURCE GH_SOURCE_LANE; fi
  v=$(
    unset GH_SOURCE
    command -v lib_env_apply >/dev/null 2>&1 || . "$_d/lib/lane-gate.sh" >/dev/null 2>&1 || exit 0
    lib_env_apply overlap-guard >/dev/null 2>&1
    printf '%s' "${GH_SOURCE:-}")
  [ -n "$v" ] && GH_SOURCE="$v"
  prr_pin overlap-guard && OG_PRR=1
  [ "$OG_PRR" = 1 ]
}

og_refresh() {
  local slug lim mainmin cdir cf fdir t rc=0 n sha ref draft who url ff nm=0 np=0 day af cut bucket since got inc=""
  slug=$("$HARNESS/bin/fleet-conf.sh" "$PROJECT" repo 2>/dev/null)
  case "$slug" in ''|-|*[!A-Za-z0-9._/-]*) echo "REFRESH $PROJECT skipped: no repo slug"; return 0 ;; esac
  command -v jq >/dev/null 2>&1 || { echo "REFRESH $PROJECT skipped: no jq"; return 0; }
  # shellcheck source=bin/lib/scheduler-conf.sh
  . "$(dirname "$0")/lib/scheduler-conf.sh" 2>/dev/null || { echo "REFRESH $PROJECT skipped: no scheduler-conf"; return 0; }
  # shellcheck source=bin/lib/preplan-lib.sh
  [ -r "$(dirname "$0")/lib/preplan-lib.sh" ] && . "$(dirname "$0")/lib/preplan-lib.sh" 2>/dev/null
  command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply sibling-serial "$PROJECT" >/dev/null 2>&1
  # OVERLAP_REFRESH_PR_LIMIT: knob row
  # catalog/lanes.d/_lib.sibling-serial.knobs.d/OVERLAP_REFRESH_PR_LIMIT.json;
  # 500 is its documented fallback. 999 is the seam's 10-page stop minus the
  # one probe row.
  lim=$(sched_num OVERLAP_REFRESH_PR_LIMIT 500 "$HARNESS")
  case "$lim" in ''|*[!0-9]*|0) lim=500 ;; esac
  [ "$lim" -gt 999 ] && lim=999
  # OVERLAP_MAIN_RECENT_MIN: the knob row lives in
  # catalog/lanes.d/_lib.sibling-serial.json; 60 is its documented fallback.
  mainmin=$(sched_num OVERLAP_MAIN_RECENT_MIN 60 "$HARNESS")
  # shellcheck source=bin/lib/gh-rest-list.sh
  . "$(dirname "$0")/lib/gh-rest-list.sh" 2>/dev/null
  command -v _gh_rest_list >/dev/null 2>&1 || { echo "REFRESH $PROJECT skipped: no gh-rest seam"; return 0; }
  for _P in "$(dirname "$0")/lib/gh-repo-token.sh" "$HARNESS/bin/lib/gh-repo-token.sh"; do
    # shellcheck source=bin/lib/gh-repo-token.sh
    [ -r "$_P" ] && { . "$_P" 2>/dev/null; break; }
  done
  # BH-10218: the visibility probe answers from the repo-meta memo until a push
  # or repository wake (or REPO_META_BACKSTOP_S). Fail-open: no lib = no memo.
  { . "$(dirname "$0")/lib/repo-meta.sh" && repo_meta_arm; } 2>/dev/null || :
  command -v gh_repo_use_token >/dev/null 2>&1 && { gh_repo_use_token "$slug" >/dev/null 2>&1 || :; }
  cdir="$HARNESS/state/overlap-guard"; cf="$cdir/$PROJECT-prs.json"; fdir="$cdir/$PROJECT-files"
  mkdir -p "$fdir" 2>/dev/null || { echo "REFRESH $PROJECT skipped: $fdir not writable"; return 0; }
  t=$(mktemp -d "${TMPDIR:-/tmp}/og-refresh-XXXXXX") || return 0
  : > "$t/rows.jsonl"; : > "$t/keep"
  if og_prr_arm; then
    prr_read overlap-guard "$slug#open" "$t/list" og_open_record og_open_github og_open_norm "$slug" "$((lim + 1))" || rc=$?
  else
    gh_rest_pr_list_all "$slug" open "$((lim + 1))" > "$t/list" || rc=$?
  fi
  if [ "$rc" = 0 ]; then
    got=$(jq 'length' "$t/list" 2>/dev/null) || rc=75
    case "$got" in ''|*[!0-9]*) rc=75 ;; esac
  fi
  if [ "$rc" = 0 ] && [ "$got" -gt "$lim" ]; then
    inc="more than $lim open PRs on $slug (OVERLAP_REFRESH_PR_LIMIT=$lim)"
    jq -c ".[:$lim]" "$t/list" > "$t/list.cut" 2>/dev/null && mv -f "$t/list.cut" "$t/list" || rc=75
  fi
  if [ "$rc" = 0 ]; then
    jq -r '.[]? | [(.number|tostring), (.head.sha // ""), (.head.ref // ""), ((.draft // false)|tostring),
                   (.user.login // ""), (.html_url // "")] | @tsv' "$t/list" > "$t/prs" 2>/dev/null || rc=75
  fi
  while [ "$rc" = 0 ] && IFS=$'\t' read -r n sha ref draft who url; do
    case "$n" in ''|*[!0-9]*) continue ;; esac
    case "$sha" in ''|*[!0-9a-f]*) sha=nosha ;; esac
    ff="$fdir/$n.$sha"
    if [ ! -s "$ff" ] || [ "$sha" = nosha ]; then
      _gh_rest_list "$slug" "pulls/$n/files" 3000 '.filename' > "$t/f" || { rc=$?; break; }
      jq -c '[.[] | strings]' "$t/f" > "$ff.tmp" 2>/dev/null && mv -f "$ff.tmp" "$ff" || { rm -f "$ff.tmp"; rc=75; break; }
    fi
    printf '%s\n' "$(basename "$ff")" >> "$t/keep"
    jq -c --argjson n "$n" --arg u "$url" --arg r "$ref" --arg d "$draft" --arg a "$who" \
      '{number:$n, url:$u, headRefName:$r, isDraft:($d == "true"), author:$a, files:map({path:.})}' "$ff" \
      >> "$t/rows.jsonl" 2>/dev/null || { rc=75; break; }
    np=$((np + 1))
  done < <([ "$rc" = 0 ] && cat "$t/prs")
  # C2: recent non-merge commits on the default branch are owners too. The
  # commit list's `since` is rounded down to 10 minutes so its ETag repeats
  # (an unchanged answer is a free 304); the window is cut exactly below.
  if [ "$rc" = 0 ] && [ "$mainmin" -gt 0 ]; then
    cut=$(( $(date -u +%s) - mainmin * 60 )); bucket=$(( cut / 600 * 600 ))
    since=$(date -u -d "@$bucket" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
    gh_rest GET "repos/$slug/commits" -f "since=$since" -F per_page=100 > "$t/commits" || rc=$?
    if [ "$rc" = 0 ]; then
      jq -r --arg c "$(date -u -d "@$cut" +%Y-%m-%dT%H:%M:%SZ)" \
        '.[]? | select(((.parents // []) | length) < 2)
              | select((.commit.committer.date // .commit.author.date // "") >= $c) | .sha // empty' \
        "$t/commits" > "$t/shas" 2>/dev/null || rc=75
    fi
    while [ "$rc" = 0 ] && IFS= read -r sha; do
      case "$sha" in ''|*[!0-9a-f]*) continue ;; esac
      ff="$fdir/main.$sha"
      if [ ! -s "$ff" ]; then
        gh_rest GET "repos/$slug/commits/$sha" > "$t/one" || { rc=$?; break; }
        jq -c '[(.files // [])[] | .filename // empty]' "$t/one" > "$ff.tmp" 2>/dev/null && mv -f "$ff.tmp" "$ff" || { rm -f "$ff.tmp"; rc=75; break; }
      fi
      printf '%s\n' "main.$sha" >> "$t/keep"
      jq -c --arg b "main@${sha:0:12}" \
        '{number:0, url:"", headRefName:$b, isDraft:false, author:"main", files:map({path:.})}' "$ff" \
        >> "$t/rows.jsonl" 2>/dev/null || { rc=75; break; }
      nm=$((nm + 1))
    done < <([ "$rc" = 0 ] && cat "$t/shas")
  fi
  if [ "$rc" = 0 ] && jq -s -c '.' "$t/rows.jsonl" > "$cf.new" 2>/dev/null; then
    mv -f "$cf.new" "$cf"
    for ff in "$fdir"/*; do
      [ -f "$ff" ] || continue
      grep -qxF "$(basename "$ff")" "$t/keep" || rm -f "$ff"
    done
    rm -rf "$t"
    if [ -z "$inc" ]; then
      rm -f "$cdir/$PROJECT-prs.incomplete"
      say "REFRESH ok prs=$np main=$nm (OVERLAP_MAIN_RECENT_MIN=$mainmin)"
      echo "REFRESH $PROJECT ok prs=$np main=$nm"; return 0
    fi
    printf '%s\n' "$inc" > "$cdir/$PROJECT-prs.incomplete"
    say "REFRESH incomplete prs=$np main=$nm — $inc; launches DEFER until a refresh reads every open PR"
    day=$(date -u +%F); af="$cdir/$PROJECT.alerted-incomplete-$day"
    find "$cdir" -maxdepth 1 -name "$PROJECT.alerted-incomplete-*" -mtime +1 -delete 2>/dev/null
    if [ ! -e "$af" ] && HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" --severity warn --id "overlap-refresh-incomplete-$PROJECT-$day" --project "$PROJECT" \
         "[overlap-guard/$PROJECT] the open-PR snapshot is INCOMPLETE: $inc. Every launch check on $PROJECT DEFERs until a refresh reads every open PR. Needs: raise OVERLAP_REFRESH_PR_LIMIT (max 999), or close open PRs." >/dev/null 2>&1; then
      : > "$af" 2>/dev/null
    fi
    echo "REFRESH $PROJECT incomplete prs=$np main=$nm"; return 0
  fi
  rm -f "$cf.new"; rm -rf "$t"
  [ "$rc" = 0 ] && rc=75
  say "REFRESH failed rc=$rc HTTP ${GH_REST_STATUS:-000} ${GH_REST_REASON:-} — old snapshot kept"
  day=$(date -u +%F); af="$cdir/$PROJECT.alerted-$day"
  find "$cdir" -maxdepth 1 -name "$PROJECT.alerted-*" -mtime +1 -delete 2>/dev/null
  if [ ! -e "$af" ]; then
    : > "$af" 2>/dev/null
    HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" --severity warn --id "overlap-refresh-$PROJECT-$day" --project "$PROJECT" \
      "[overlap-guard/$PROJECT] the open-PR snapshot refresh failed (HTTP ${GH_REST_STATUS:-000}, rc $rc). The old $cf is kept; when it is older than OVERLAP_SNAPSHOT_MAX_AGE, sibling-serial notes prs=unread. Needs: a gh token that can list PRs and commits on $slug." >/dev/null 2>&1 || :
  fi
  echo "REFRESH $PROJECT failed rc=$rc (old snapshot kept)"; return 0
}
if [ "$PROJECT" = --refresh ]; then
  PROJECT="${2:-}"; KEY=refresh
  [[ "$PROJECT" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || { echo "usage: overlap-guard.sh --refresh <project>" >&2; exit 0; }
  og_refresh; exit 0
fi

[ -n "$PROJECT" ] && [ -n "$KEY" ] || { echo "usage: overlap-guard.sh <project> <KEY>" >&2; exit 0; }
case "$(printf '%s' "${OVERLAP_GUARD:-1}" | tr '[:upper:]' '[:lower:]')" in
  0|off|false|no) exit 0 ;;
esac
command -v lane_switch >/dev/null 2>&1 || . "$(dirname "${BASH_SOURCE[0]}")/lib/lane-switch.sh" 2>/dev/null || lane_switch() { [ -e "${HARNESS:-${H:-/root/harness}}/flags/$1" ]; }
lane_switch overlap-guard-off file && exit 0
# PER PROJECT, TOO (BH-782 review r2). The DEFER arm below is the one verdict
# in this file that holds work back, and it holds back a WHOLE PROJECT. Its
# remedy must not be "turn the guard off for the entire fleet".
[ -e "$HARNESS/flags/overlap-guard-off-$PROJECT" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

# shellcheck source=bin/lib/scheduler-conf.sh
. "$(dirname "$0")/lib/scheduler-conf.sh" 2>/dev/null || exit 0
# The pre-plan vocabulary, for files_of's second source. Sourced HERE because
# the first files_of call is the candidate's own list, before the ledger read
# below; absent, files_of simply skips that source (fail-open, as ever).
# shellcheck source=bin/lib/preplan-lib.sh
[ -r "$(dirname "$0")/lib/preplan-lib.sh" ] && . "$(dirname "$0")/lib/preplan-lib.sh" 2>/dev/null
# The test-home contract (#583): what a test path is, what a PER-TICKET test
# path is, the record format and the kill switch. Optional on purpose — a box
# whose bin/ predates it has no th_* functions, the partition below never fires,
# and this guard answers exactly what it answered before.
for _P in "$(dirname "$0")/lib/test-home-lib.sh" "$HARNESS/bin/lib/test-home-lib.sh"; do
  # shellcheck source=bin/lib/test-home-lib.sh
  [ -r "$_P" ] && { . "$_P" 2>/dev/null; break; }
done
# The scheduler rows once, into this shell (BH-2478): each sched_* below runs in `$( )`.
command -v conf_rows_preload >/dev/null 2>&1 && conf_rows_preload scheduler "$HARNESS"
THRESH=$(sched_frac OVERLAP_THRESHOLD 0 "$HARNESS")
PR_LIMIT=$(sched_num OVERLAP_PR_LIMIT 30 "$HARNESS")
PR_CACHE=$(sched_num OVERLAP_PR_CACHE_SECS 120 "$HARNESS")
LED_LIMIT=$(sched_num OVERLAP_LEDGER_LIMIT 50 "$HARNESS")
# The paths the merge conductor's rebase already union-resolves deterministically
# (mc_resolve_package_json, mc_resolve_md_union) are NOT a scheduling conflict:
# every sibling build appends its own line to package.json's test script and its
# own section to a markdown file, and that class is mechanically fixed without a
# re-review. Deferring on them would serialize the whole repo behind its most
# boring file. Space-separated globs.
IGNORE=$(sched_conf OVERLAP_IGNORE 'package.json package-lock.json *.md' "$HARNESS")

TMP=$(mktemp -d "${TMPDIR:-/tmp}/overlap-guard-XXXXXX") || exit 0
trap 'rm -rf "$TMP"' EXIT

# READ-MOSTLY PATHS (BH-6299): the paths this project's builds plan but almost
# never edit, from bin/lib/read-mostly.sh — the one rule bin/overlap-schedule.sh
# reads too. prune() drops them by exact path. Absent lib = empty set.
: > "$TMP/rm"
# shellcheck source=bin/lib/read-mostly.sh
[ -r "$(dirname "$0")/lib/read-mostly.sh" ] && . "$(dirname "$0")/lib/read-mostly.sh" 2>/dev/null
command -v read_mostly_list >/dev/null 2>&1 && read_mostly_list "$PROJECT" "$HARNESS" > "$TMP/rm" 2>/dev/null

# --- the file lists ----------------------------------------------------------
# The ignore globs are split with `read -a`, NEVER with an unquoted `for g in
# $IGNORE`: word splitting is followed by PATHNAME EXPANSION, so `*.md` in that
# loop silently becomes the markdown files of whatever directory the caller
# happened to be standing in — which is how this guard first refused to ignore
# docs/NOTES.md while running from a repo root that had its own *.md files.
IGNORE_PATS=()
IFS=' ' read -r -a IGNORE_PATS <<<"$IGNORE"
# AUTO-MERGE PATHS (BH-9426): a `## Generated files` row of the target repo or a
# `merge=union` path is resolved by the merge itself, so prune() drops it too.
# The repo is $PLAN_OVERLAP_REPO, else $REPOS_ROOT/<project>; absent lib or
# repo dir = every path kept, as before.
# shellcheck source=bin/lib/automerge-paths.sh
. "$(dirname "$0")/lib/automerge-paths.sh" 2>/dev/null || amp_filter() { cat; }
AMP_REPO="${PLAN_OVERLAP_REPO:-${REPOS_ROOT:-/root/repos}/$PROJECT}"

# prune <src> <dst> — drop the auto-resolvable classes, the auto-merge paths,
# blank lines and dupes.
#
# ...AND THE `SOURCE:` HEADER (BH-499). bin/planned-files-cheap.sh writes which
# tier produced a list as its first line, into the same
# plans/<project>-<KEY>/planned-files.txt this reads. Left in it is not a
# harmless stray: it is an entry two cheap lists SHARE, so two unrelated
# children would be reported as colliding on `SOURCE: ticket-body` and one of
# them held. bin/lib/dep-verify-lib.sh:dep_norm drops it for the same reason —
# this is the only other direct reader of that file.
prune() {
  local f g keep
  : > "$2"; : > "$2.rm"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in SOURCE:*|source:*) continue ;; esac
    keep=1
    grep -qxF -- "$f" "$TMP/rm" && { keep=0; printf '%s\n' "$f" >> "$2.rm"; }
    for g in ${IGNORE_PATS+"${IGNORE_PATS[@]}"}; do
      # shellcheck disable=SC2254
      case "$f" in $g|*/$g) keep=0; break ;; esac
    done
    [ "$keep" = 1 ] && printf '%s\n' "$f"
  done < "$1" | sort -u | amp_filter "$AMP_REPO" > "$2"
}

# files_of <key> <dst> -> rc 0 when a files-to-touch list was found for that key
#   The pre-plan is preferred (it is what the launcher is about to hand the
#   builder); a live build dir's own list is the fallback for a ticket that was
#   launched before the pre-plan lane existed, or whose plan was made in-build.
#
#   THREE SOURCES, IN THE ORDER THE BUILDER WILL SEE THEM (BH-658). The local
#   plans/ dir is empty on the HUB by design — the hub is forbidden to pre-plan
#   — and the hub is exactly where bin/fly-dispatch.sh calls this guard from, so
#   every Fly candidate answered "no files-to-touch list" and the guard could
#   not judge. The published row is the same list, readable from here. On a
#   watcher box the local file wins and this costs no request at all.
files_of() {
  local k="$1" dst="$2" p d l
  p="$HARNESS/plans/$PROJECT-$k/planned-files.txt"
  if [ -s "$p" ]; then prune "$p" "$dst"; [ -s "$dst" ] && return 0; fi
  if type preplan_planned_files >/dev/null 2>&1 \
     && l=$(preplan_planned_files "$HARNESS" "$PROJECT" "$k" 2>/dev/null) && [ -n "$l" ]; then
    printf '%s\n' "$l" > "$TMP/pf-$k"
    prune "$TMP/pf-$k" "$dst"; [ -s "$dst" ] && return 0
  fi
  # Newest build dir for that key, local or relayed from the pool.
  for d in $(ls -1dt "$HARNESS/builds/$PROJECT-$k-"* "$HARNESS/builds/pool-$PROJECT-$k-"* 2>/dev/null); do
    [ -s "$d/planned-files.txt" ] || continue
    prune "$d/planned-files.txt" "$dst"; [ -s "$dst" ] && return 0
  done
  return 1
}

CAND="$TMP/cand"
# OVERLAP_CAND_FILE (BH-9440): the caller hands the candidate list over. A
# build whose diff left its declared list (bin/lib/claim-drift.sh) is judged on
# the union it re-claimed, not on the plan it started from.
if [ -n "${OVERLAP_CAND_FILE:-}" ] && [ -s "$OVERLAP_CAND_FILE" ]; then
  prune "$OVERLAP_CAND_FILE" "$CAND"
  [ -s "$CAND" ] || launch "the handed-in list for $KEY is empty after the prune — cannot judge, not a reason to hold"
else
  files_of "$KEY" "$CAND" || launch "no files-to-touch list for $KEY — cannot judge, not a reason to hold"
fi
# Said in the log, so a launch past a shared path is not mistaken for a guard
# that missed it. prune() leaves the read-mostly paths it dropped in <dst>.rm.
RMN=$(sort -u "$CAND.rm" 2>/dev/null | grep -c .)
[ "${RMN:-0}" -gt 0 ] && say "read-mostly: $RMN path(s) not judged"

# --- the overlap rule --------------------------------------------------------
# Two plans collide when any path of one equals, or is a path-prefix of, a path
# of the other (file == file, dir contains file) — bin/conflict-check.sh's rule,
# with bin/plan-overlap.sh's prune in front of it: a bare directory entry that
# the SAME list also names a file under is dropped, because it is where that
# file lives and not a second claim.
#
# Prints: "<hits> <union> <first three colliding paths, comma separated>".
# Jaccard is hits/union over the pruned sets — reported on EVERY decision, so an
# operator raising OVERLAP_THRESHOLD is reading the same number the guard did.
#
# It also leaves the EXACT-EQUAL hits in $TMP/hits, one per line, for the reroute
# partition in judge(): only a path both lists name identically can be renamed
# out of the way. A dir-contains-file hit is deliberately absent from that file —
# the per-ticket target would still live under the directory the other side holds.
# The file is truncated on every call, so a label never inherits the previous
# label's hits.
#
# FILE-LEVEL ONLY AGAINST AN OPEN PR (2026-09-28). With OVERLAP_EXACT=1 only an
# exact path match is a hit. judge() sets it for an open PR, whose list is the
# files it REALLY changed: a planned directory entry such as
# tests/fixtures/root-fallback-baseline was a prefix of every fixture any PR
# touched under it and held the ticket against all of them. Two PLANS (a
# running sibling) keep the prefix rule — both are intentions, and a directory
# one of them claims is a real claim (tests/overlap-guard.bh-580-test.sh, 9).
OVERLAP_EXACT=0
overlap() {
  : > "$TMP/hits"
  awk -v hf="$TMP/hits" -v exact="${OVERLAP_EXACT:-0}" 'NR==FNR{a[++na]=$0;next}
    {b[++nb]=$0}
    END{
      for(i=1;i<=na;i++) for(j=1;j<=na;j++) if(index(a[j],a[i]"/")==1){da[i]=1;break}
      for(i=1;i<=nb;i++) for(j=1;j<=nb;j++) if(index(b[j],b[i]"/")==1){db[i]=1;break}
      ca=0; for(i=1;i<=na;i++) if(!da[i]) ca++
      cb=0; for(i=1;i<=nb;i++) if(!db[i]) cb++
      hit=0; np=0; pairs=""
      for(i=1;i<=na;i++){
        if(da[i])continue
        for(j=1;j<=nb;j++){
          if(db[j])continue
          p=a[i]; q=b[j]
          if(q==p||(exact!=1&&(index(q,p"/")==1||index(p,q"/")==1))){
            hit++
            if(q==p) print p > hf
            if(np<3){ pairs = pairs (np?",":"") p; np++ }
            break
          }
        }
      }
      close(hf)
      u=ca+cb-hit; if(u<1)u=1
      printf "%d %d %s\n", hit, u, pairs
    }' "$1" "$2" 2>/dev/null
}

# >>> test-file reroute (BH-584, part of #580)
# A SHARED TEST FILE IS NOT A REASON TO HOLD A TICKET. It is the fleet's largest
# merge-conflict surface — 20 of 24 unresolvable conductor cases were two
# siblings appending cases to the same tests/<tier>/<area>.test.ts — and the fix
# is that a ticket writes its cases to its OWN file. So instead of deferring, the
# guard renames the path out of the way: it records `REROUTE tests: <shared> ->
# <per-ticket>` where the executor will read it, rewrites the pre-plan list, and
# drops the path from the hit set. Everything LEFT in that set is judged by the
# same jaccard against the same threshold as before.
#
# The record is written BEFORE the list is swapped, never after: a swapped list
# with no record would tell a builder to write to a file nothing recorded.
REROUTED=0
RR_LABELS=""
# rr_swap <pairs-file> <dst> — $CAND with each pair's shared path replaced by its
# per-ticket target. Whole-line only, the same match th_apply uses on the list.
rr_swap() {
  local s t
  cp "$CAND" "$2" 2>/dev/null || return 1
  while IFS=$'\t' read -r s t; do
    [ -n "$s" ] && [ -n "$t" ] || continue
    awk -v s="$s" -v t="$t" '{print ($0==s ? t : $0)}' "$2" > "$2.n" 2>/dev/null \
      && mv -f "$2.n" "$2"
  done < "$1"
  return 0
}
# <<< test-file reroute

# judge <other-label> <other-list> — DEFERs and exits 1 when the pair collides.
judge() {
  local label="$1" other="$2" hits union pairs j
  local p t b rec j2 h2 u2 p2 n
  read -r hits union pairs <<<"$(overlap "$CAND" "$other")"
  case "${hits:-0}" in ''|*[!0-9]*) return 0 ;; esac
  [ "$hits" -gt 0 ] || return 0
  # --- the reroute partition (see the block above) ---------------------------
  if type th_is_test_path >/dev/null 2>&1 && th_enabled "$HARNESS"; then
    : > "$TMP/rr"
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      # A bare directory entry has no target: `tests/level2-unit` is where a
      # sibling's files live, not a file this ticket can rename.
      b="${p##*/}"; case "$b" in *.*) ;; *) continue ;; esac
      th_is_test_path "$p" || continue
      # Somebody's per-ticket file — ours (then it is not a collision at all) or
      # a sibling's (then it is a real one). Never rerouted either way.
      th_is_per_ticket "$p" && continue
      t=$(th_per_ticket_path "$p" "$KEY") || continue
      [ -n "$t" ] && [ "$t" != "$p" ] || continue
      printf '%s\t%s\n' "$p" "$t" >> "$TMP/rr"
    done < "$TMP/hits"
    if [ -s "$TMP/rr" ]; then
      rr_swap "$TMP/rr" "$TMP/cand.rr"
      read -r h2 u2 p2 <<<"$(overlap "$TMP/cand.rr" "$other")"
      case "$h2" in ''|*[!0-9]*) h2=$hits; u2=$union; p2=$pairs ;; esac
      j2=$(awk -v h="$h2" -v u="$u2" 'BEGIN{printf "%.2f", h/u}')
      if [ "$h2" -gt 0 ] && awk -v j="$j2" -v t="$THRESH" 'BEGIN{exit !(j>=t)}'; then
        # The remainder holds this ticket anyway. Record NOTHING: a deferred
        # ticket that carries a reroute would hand its test file away for a
        # build that never ran, and files=[...] must name the real conflict.
        hits=$h2; union=$u2; pairs=$p2
      else
        rec=$(th_record_path "$HARNESS" "$PROJECT" "$KEY")
        : > "$TMP/rr.ok"
        while IFS=$'\t' read -r p t; do
          if th_record_add "$rec" "$p" "$t"; then
            say "REROUTE vs $label: $p -> $t"
            printf '%s\t%s\n' "$p" "$t" >> "$TMP/rr.ok"
          else
            # rc 1 is "not rerouted" (D9/D11): the path stays a hit and this
            # ticket is judged exactly as it was before the partition existed.
            say "REROUTE record unwritable for $p — deferring as today"
          fi
        done < "$TMP/rr"
        if ! cmp -s "$TMP/rr" "$TMP/rr.ok"; then
          rr_swap "$TMP/rr.ok" "$TMP/cand.rr"
          read -r h2 u2 p2 <<<"$(overlap "$TMP/cand.rr" "$other")"
          case "$h2" in ''|*[!0-9]*) h2=$hits; u2=$union; p2=$pairs ;; esac
        fi
        if [ -s "$TMP/rr.ok" ]; then
          mv -f "$TMP/cand.rr" "$CAND"   # later labels judge the swapped list
          th_apply "$rec" "$HARNESS/plans/$PROJECT-$KEY/planned-files.txt"
          n=$(wc -l < "$TMP/rr.ok"); REROUTED=$((REROUTED + n))
          RR_LABELS="$RR_LABELS, $label"
        fi
        hits=$h2; union=$u2; pairs=$p2
      fi
      [ "$hits" -gt 0 ] || return 0
    fi
  fi
  j=$(awk -v h="$hits" -v u="$union" 'BEGIN{printf "%.2f", h/u}')
  # THRESHOLD 0 IS "ANY OVERLAP DEFERS", the default: one shared source file is
  # one conflict, and the tickets that share a whole area are exactly the ones
  # whose rebase then fails outside the deterministic classes. A box that finds
  # this too tight raises OVERLAP_THRESHOLD rather than switching the guard off.
  if awk -v j="$j" -v t="$THRESH" 'BEGIN{exit !(j>=t)}'; then
    say "DEFER vs $label jaccard=$j hits=$hits/$union files=[${pairs:-?}]"
    printf 'DEFER %s vs %s jaccard=%s files=[%s]\n' "$KEY" "$label" "$j" "${pairs:-?}"
    exit 1
  fi
  say "allowed past $label jaccard=$j < threshold $THRESH files=[${pairs:-?}]"
  return 0
}

# --- 1. tickets this project already has building, fleet-wide ----------------
UNJUDGED=""
LEDGER=skip
if [ -r "$HARNESS/bin/jobs-client.sh" ]; then
  # shellcheck source=/dev/null
  . "$HARNESS/bin/jobs-client.sh" 2>/dev/null || true
fi
if type _jobs_req >/dev/null 2>&1; then
  if ROWS=$(_jobs_req GET "/api/jobs?project=$PROJECT&status=running&limit=$LED_LIMIT" 2>/dev/null); then
    LEDGER=ok
    printf '%s' "$ROWS" \
      | jq -r '.jobs[]? | select((.kind // "build") == "build") | .ticket_id // empty' 2>/dev/null \
      | sort -u > "$TMP/running"
  else
    LEDGER=outage
  fi
fi
if [ -s "$TMP/running" ]; then
  while IFS= read -r OK; do
    [ -n "$OK" ] && [ "$OK" != "$KEY" ] || continue
    if files_of "$OK" "$TMP/other"; then
      judge "$OK(building)" "$TMP/other"
    else
      UNJUDGED="$UNJUDGED $OK"
    fi
  done < "$TMP/running"
fi

# --- 2. open harness PRs on this repo ---------------------------------------
# Cached per project for OVERLAP_PR_CACHE_SECS: the launch path runs this guard
# once per candidate ticket and the pool dispatcher ticks every two minutes, so
# an uncached read would be several `gh pr list` calls a minute on a repo whose
# answer changes on a merge. The cache is a file in state/, never the ledger.
SLUG=$("$HARNESS/bin/fleet-conf.sh" "$PROJECT" repo 2>/dev/null)
if [ -n "$SLUG" ] && command -v gh >/dev/null 2>&1; then
  CDIR="$HARNESS/state/overlap-guard"; mkdir -p "$CDIR" 2>/dev/null
  CF="$CDIR/$PROJECT-prs.json"
  FRESH=0
  if [ -s "$CF" ] && [ "$PR_CACHE" -gt 0 ]; then
    AGE=$(( $(date -u +%s) - $(stat -c %Y "$CF" 2>/dev/null || echo 0) ))
    [ "$AGE" -ge 0 ] && [ "$AGE" -lt "$PR_CACHE" ] && FRESH=1
  fi
  if [ "$FRESH" = 0 ]; then
    for _P in "$(dirname "$0")/lib/gh-pr-list.sh" "$HARNESS/bin/lib/gh-pr-list.sh"; do
      # shellcheck source=/dev/null
      [ -r "$_P" ] && { . "$_P"; break; }
    done
    # WHICH CREDENTIAL CAN SEE THIS REPO (BH-782 review r2). Until this line the
    # list ran on whatever GH_TOKEN the dispatcher happened to hold — the hub's
    # default PAT, which 404s on example-org/project-5. That was survivable while
    # every unreadable list fell open; it is not survivable now that an
    # unreadable list DEFERS, because a repo the default PAT cannot see would
    # defer every ticket of that project on every 2-minute tick for ever.
    # Sourcing this also arms harness_pr_list's one rate-limit retry, which
    # climbs a rung only when the CALLER has these functions.
    for _P in "$(dirname "$0")/lib/gh-repo-token.sh" "$HARNESS/bin/lib/gh-repo-token.sh"; do
      # shellcheck source=bin/lib/gh-repo-token.sh
      [ -r "$_P" ] && { . "$_P"; break; }
    done
    # yes | no | unknown: "no" means the ladder ran and NO rung could see the
    # repo. "unknown" means the lib is not on this box, so nobody asked — and an
    # unasked question must not be answered as though it had been.
    VISIBLE=unknown
    # BH-10218: the repo-meta memo for the ladder's visibility probe (fail-open).
    { . "$(dirname "$0")/lib/repo-meta.sh" && repo_meta_arm; } 2>/dev/null || :
    if command -v gh_repo_use_token >/dev/null 2>&1; then
      if gh_repo_use_token "$SLUG" >/dev/null 2>&1; then VISIBLE=yes; else VISIBLE=no; fi
    fi
    if type harness_pr_list >/dev/null 2>&1; then
      # `files` is a pr LIST field, so this is one call per author rather than
      # one `gh pr view` per PR — the token-discipline rule in CLAUDE.md, and the
      # difference between 2 calls and 30 on a busy repo.
      #
      # `> file`, not `$( )`: GH_REST_STATUS is set in the shell that CALLS the
      # helper, and a command substitution would leave the status behind in a
      # dead subshell — the DEFER line below would then name HTTP 000 for a 403.
      PRRC=0
      # The record cannot answer this list (it asks for files: og_check_record
      # is always field:files), so shadow has nothing to compare and makes
      # today's read with no log line; record logs its PRR_MISS and reads GitHub.
      if og_prr_arm && [ "${GH_SOURCE:-}" = record ]; then
        prr_read overlap-guard "$SLUG#check" "$TMP/prlist" og_check_record og_check_github og_check_norm "$SLUG" "$PR_LIMIT" || PRRC=$?
      else
        harness_pr_list "$SLUG" open "number,url,headRefName,isDraft,files" "$PR_LIMIT" \
          > "$TMP/prlist" 2>/dev/null || PRRC=$?
      fi
      if [ "$PRRC" = 0 ] && [ -s "$TMP/prlist" ]; then
        # WRITE ON SUCCESS ONLY. An unreadable read must never overwrite a
        # cache that still holds real PRs.
        cp "$TMP/prlist" "$CF.new" && mv -f "$CF.new" "$CF"
      elif [ ! -s "$CF" ]; then
        # Asked, could not read, and nothing to fall back on — the one DEFER
        # that is not about files. rc 44/75 came from the REST contract and
        # carry a status; rc 1 came from the per-author path, which saw no HTTP
        # status at all, and claiming one it never saw would be worse than
        # saying so (D26).
        case "$PRRC" in
          44|75) HST="${GH_REST_STATUS:-000}" ;;
          *)     HST="n/a" ;;
        esac
        # AN INVISIBLE REPO IS NOT AN OUTAGE (BH-782 review r2). #768's lie was a
        # read that FAILED and was reported as an empty list — weather, gone by
        # the next tick, so re-offering the ticket costs two minutes. "No
        # credential on this box can see this repo" is not weather: the next
        # tick asks the same question of the same three rungs and gets the same
        # 404, so DEFER here would mean the project never builds again and the
        # only way out is a flag somebody has to notice. That is exactly the
        # case this guard's FAIL-OPEN rule was written for. So: one alert naming
        # the rung to fix — gh_repo_invisible_alert is the fleet's one sentence
        # for it and dedupes per (lane, repo) per day — and LAUNCH.
        if [ "$VISIBLE" = no ]; then
          command -v gh_repo_invisible_alert >/dev/null 2>&1 \
            && gh_repo_invisible_alert overlap-guard "$SLUG" \
                 "the overlap guard cannot list its open PRs, so it is judging on the running-build ledger alone" \
            || true
          launch "no gh credential can see $SLUG (HTTP $HST, rc $PRRC) — alerted; judged on the ledger alone"
        fi
        say "DEFER — gh unknown (HTTP $HST, rc $PRRC): the open-PR list is unreadable and no cache exists"
        # STOPPING IS AN ALERT, NOT A WHISPER (CLAUDE.md). This arm is the only
        # verdict in this file that holds work back, and on a box with no cache
        # yet — a fresh box, a rebuilt one, a wiped state/ — it holds back EVERY
        # ticket of this project on EVERY tick for as long as the read fails.
        # logs/overlap-guard.log is a per-guard log nobody polls, so the first
        # signal would otherwise be somebody asking why nothing shipped.
        # ONE line per project per UTC day: the flag keeps a 2-minute cron from
        # turning an outage into a thousand-line ALERTS.log, and the day rolls
        # so a multi-day outage keeps saying so.
        AFLAG="$HARNESS/flags/alerted-overlap-gh-unknown-$PROJECT-$(date -u +%Y%m%d)"
        if [ ! -e "$AFLAG" ]; then
          mkdir -p "$HARNESS/flags" "$HARNESS/logs" 2>/dev/null
          : > "$AFLAG" 2>/dev/null
          printf '%s [overlap-guard/%s] the open-PR list is UNREADABLE (HTTP %s, rc %s) and %s holds no cached copy, so every ticket on this project DEFERS every tick until a read succeeds — no builds launch. Needs (operator): a gh token that can list PRs on this repo, or `touch %s/flags/overlap-guard-off-%s` to fall back to the pre-BH-782 fail-open for THIS project alone (flags/overlap-guard-off does the whole fleet).\n' \
            "$(STAMP)" "$PROJECT" "$HST" "$PRRC" "$CF" "$HARNESS" "$PROJECT" \
            >> "$HARNESS/logs/ALERTS.log" 2>/dev/null || true
        fi
        printf 'DEFER %s gh unknown (HTTP %s) open-PR list unreadable, no cache; re-offered next tick\n' \
          "$KEY" "$HST"
        exit 1
      else
        # A cache exists. Stale-but-real beats none: judge from it.
        say "open-PR list unreadable (rc $PRRC) — judging from the cached copy"
      fi
    fi
  fi
  if [ -s "$CF" ]; then
    # One TSV line per open PR: number, branch, then its changed files. A PR for
    # THIS ticket is skipped — a repair round on our own branch is the same work,
    # not a collision (the branch names carry the key: ticket/<key>-...).
    jq -r '.[]? | select((.isDraft // false) | not)
           | [(.number|tostring), (.headRefName // "-"),
              ((.files // []) | map(.path // .filename // empty) | join(","))] | @tsv' \
       "$CF" 2>/dev/null > "$TMP/prs"
    LKEY=$(printf '%s' "$KEY" | tr '[:upper:]' '[:lower:]')
    # THE STACK PARENT IS NOT A COLLISION (2026-09-28). A stacked child
    # (STACK_BASE, docs/BUILD-CONCURRENCY.md) builds ON its parent PR's branch,
    # so its plan overlaps that PR by construction — the overlap is WHY it is
    # stacked. Judged against it, the child deferred every tick until the parent
    # merged: the exact wait stacking exists to remove. The base branch comes
    # from the launcher's environment, else from the queue job file
    # bin/fly-dispatch.sh is about to hand over (the `stack_base` run-build and
    # fly-pool write). Only the PR whose HEAD is that branch is skipped; every
    # other PR is judged as before, so a real overlap still defers.
    PARENT_BR="${STACK_BASE:-}"
    [ -n "$PARENT_BR" ] || PARENT_BR=$(jq -r '.stack_base // empty' \
      "$HARNESS/state/build-queue/$PROJECT/$KEY.json" 2>/dev/null)
    case "$PARENT_BR" in *[!A-Za-z0-9._/-]*) PARENT_BR="" ;; esac
    # The stacked-builds KILL SWITCH, read exactly as bin/lib/rb/gates.sh reads
    # it: with it set the child builds on the project base and ignores
    # STACK_BASE, so its "parent" PR is somebody else's written diff again.
    # Through lane_switch (switch-ratchet BH-2320): a settings row, else the file.
    if [ "${STACKED_BUILDS:-1}" = 0 ] || lane_switch stacked-builds-off file; then
      PARENT_BR=""
    fi
    while IFS=$'\t' read -r NUM BR FILES; do
      [ -n "${FILES:-}" ] || continue
      case "$(printf '%s' "$BR" | tr '[:upper:]' '[:lower:]')" in *"$LKEY"*) continue ;; esac
      if [ -n "$PARENT_BR" ] && [ "$BR" = "$PARENT_BR" ]; then
        say "skipped PR#$NUM — it is this ticket's stack parent ($BR), not a collision"
        continue
      fi
      printf '%s\n' "$FILES" | tr ',' '\n' > "$TMP/prraw"
      prune "$TMP/prraw" "$TMP/other"
      [ -s "$TMP/other" ] || continue
      # A main@<sha12> row (BH-9440, --refresh) is a recent commit on the
      # default branch: an owner like an open PR, named by its commit.
      case "$BR" in main@*) OVERLAP_EXACT=1 judge "$BR" "$TMP/other" ;; *) OVERLAP_EXACT=1 judge "PR#$NUM" "$TMP/other" ;; esac
    done < "$TMP/prs"
  fi
fi
# FAIL CLOSED ON A CUT SNAPSHOT (BH-9440 review). The last --refresh hit
# OVERLAP_REFRESH_PR_LIMIT, so some open PRs were not judged. "No overlap"
# against a partial list is the #768 lie again, so every launch DEFERs.
if [ -s "$HARNESS/state/overlap-guard/$PROJECT-prs.incomplete" ]; then
  INC=$(head -n 1 "$HARNESS/state/overlap-guard/$PROJECT-prs.incomplete" 2>/dev/null)
  say "DEFER — open-PR snapshot incomplete: $INC"
  printf 'DEFER %s open-PR snapshot incomplete (%s); re-offered next tick\n' "$KEY" "$INC"
  exit 1
fi

# Said out loud, never counted as disjoint: a running key whose file list never
# reached this box is a question we could not ask, and a conflict that lands
# anyway deserves a written reason rather than looking like a gate that failed.
NOTE="ledger=$LEDGER"
[ -n "$UNJUDGED" ] && NOTE="$NOTE unjudged=$(printf '%s' "$UNJUDGED" | tr ' ' ',' | sed 's/^,//')"
FINAL="no collision above threshold $THRESH ($NOTE)"
# The launch line carries the reroutes because this stdout is what
# bin/fly-dispatch.sh logs and what the triage SOP reads: a ticket that launched
# because its test path was renamed must not look like a ticket that never
# collided. The early fail-open launches above cannot have rerouted anything —
# there was no candidate list to swap.
[ "$REROUTED" -gt 0 ] && FINAL="rerouted $REROUTED test path(s) vs ${RR_LABELS#, }; $FINAL"
launch "$FINAL"
