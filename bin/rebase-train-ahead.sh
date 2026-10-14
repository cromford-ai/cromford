#!/bin/bash
# bin/rebase-train-ahead.sh [project ...] — THE TARGETED REBASE TRAIN. Every few
# minutes it asks one question per repo: "what merged into main since I last
# looked, and which open harness PRs touch those files?" — and it merges main
# into exactly those branches, before GitHub ever marks them DIRTY.
#
# HOW THIS DIFFERS FROM bin/rebase-train.sh, which stays exactly as it is.
# That train is the CURE: it wakes for a PR that is ALREADY DIRTY, on a project
# cron at :11/:41, budget 2 per run, and it un-DIRTIES what it can. By then the
# PR has already been classified NEEDS_REBASE, its head is about to move, and
# its approval has to be rebound. This one is the PREVENTION: it runs off the
# merge event rather than off the damage, and it refreshes ONLY the PRs whose
# own changed files intersect what just landed. A PR that shares no file with
# the merge is left alone — refreshing it would move its head, and a moved head
# costs a re-review under the head-bound approval rule (CLAUDE.md guardrail 1).
#
# THE NUMBER (2026-09-15): ~144 DIRTY/conflict events and 33 rebases on
# project-5 in 24h against ~100 merges, plus 121 blocked-resolver rebuilds.
# Those merges were knowable one tick earlier in every case.
#
# THE REFRESH IS mc_rebase, borrowed whole from bin/lib/merge-conductor-lib.sh —
# the conductor's own authed clone/worktree, its deterministic conflict classes
# (package.json token union, markdown both-sides append), its typecheck+unit
# gate, its --force-with-lease on the sha THIS tick read, and its approval
# rebind. Writing a second one would mean two answers to "is this branch safe to
# push", and the sweep is head-bound: an un-rebound push parks the PR.
# bin/merge-conductor.sh is NOT touched, and nothing here writes conductor state.
#
# WHAT IT REFUSES TO TOUCH: drafts; PRs whose base is not the repo's base
# branch; PRs the conductor has already taken custody of (its pr-state.tsv says
# QUEUED / REBASING / NEEDS_REBASE / BLOCKED_HUMAN / a terminal), read-only;
# PRs with a detached conductor rebase job in flight; and anything already DIRTY
# — that is the conductor's lane and doing it here would race its lease.
#
# THE DIRTY FILTER IS BELT, NOT BRACES, and it is worth saying which is which.
# `gh pr list --json mergeStateStatus` answers UNKNOWN for most rows (GitHub
# computes mergeability lazily and a list call does not wait for it), so that
# filter only fires when GitHub happens to have the value cached. What ACTUALLY
# keeps this train out of the conductor's way is the pr-state.tsv custody check
# below — NEEDS_REBASE is the conductor's own word for DIRTY and it is in
# REBASE_TRAIN_SKIP_STATES by default. Both are kept: the cheap one costs
# nothing when it does answer.
#
# Kill switch: the settings row switch.rebase-train-off[.<box>] (lane_switch,
# bin/lib/lane-switch.sh); with no row, flag_active rebase-train-off, or the
# bare file when the jobs client cannot be loaded. Config (flags/scheduler.conf, defaults in
# bin/lib/scheduler-conf.sh and docs/SCHEDULER.md): REBASE_TRAIN_MAX,
# REBASE_TRAIN_COMMITS, REBASE_TRAIN_PR_LIMIT, REBASE_TRAIN_REPOS,
# REBASE_TRAIN_SKIP_STATES.
#
# ONE LOG LINE PER REFRESH -> logs/rebase-train-ahead.log. A LANE ALERT only on
# a REAL conflict (rc 1: the merge hit a class nothing resolves deterministically)
# — that is a human-shaped fact with a PR url, and it is --critical because the
# orchestrator monitor is what would otherwise relay it. A gate red, a lost
# lease or a setup failure is a log line: the next tick retries it, and paging
# on work that retries itself is how an alert log stops being read.
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$HARNESS")
LOG="$HARNESS/logs/rebase-train-ahead.log"
MARKDIR="$HARNESS/state/rebase-train"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
say() { mkdir -p "$HARNESS/logs" 2>/dev/null; echo "$(STAMP) [rebase-train-ahead${1:+/$1}] ${2:-$1}" >> "$LOG"; }

# shellcheck source=bin/jobs-client.sh
[ -r "$HARNESS/bin/jobs-client.sh" ] && . "$HARNESS/bin/jobs-client.sh" 2>/dev/null
# shellcheck source=lib/lane-switch.sh
. "$(dirname "$0")/lib/lane-switch.sh" || exit 1
lane_switch rebase-train-off && exit 0
# The conductor's own kill switch stops this too: a refresh exists only to keep
# the merge funnel moving, so a fleet that has stopped merging must not be
# pushing branches around.
if command -v flag_active >/dev/null 2>&1; then flag_active automerge-disabled && exit 0
else [ -e "$HARNESS/flags/automerge-disabled" ] && exit 0; fi
command -v jq >/dev/null 2>&1 || { say "" "jq missing — nothing to do"; exit 0; }
command -v gh >/dev/null 2>&1 || { say "" "gh missing — nothing to do"; exit 0; }

# DEDUPE, NEVER A QUEUE (the operator, 2026-09-13). A tick that finds the previous one
# still running exits; it does not wait, and the next cron minute re-offers the
# same work.
mkdir -p "$HARNESS/locks" "$MARKDIR" 2>/dev/null
exec 9>"$HARNESS/locks/rebase-train-ahead.lock" || exit 0
flock -n 9 || exit 0

# shellcheck source=bin/lib/scheduler-conf.sh
. "$(dirname "$0")/lib/scheduler-conf.sh" 2>/dev/null || exit 0
# The scheduler rows once, into this shell (BH-2478): each sched_* below runs in `$( )`.
command -v conf_rows_preload >/dev/null 2>&1 && conf_rows_preload scheduler "$HARNESS"
MAX=$(sched_num REBASE_TRAIN_MAX 3 "$HARNESS")
NCOMMITS=$(sched_num REBASE_TRAIN_COMMITS 20 "$HARNESS")
PR_LIMIT=$(sched_num REBASE_TRAIN_PR_LIMIT 40 "$HARNESS")
SKIP_STATES=$(sched_conf REBASE_TRAIN_SKIP_STATES 'QUEUED REBASING NEEDS_REBASE BLOCKED_HUMAN MERGED CLOSED ABANDONED' "$HARNESS")

# shellcheck source=bin/lib/gh-repo-token.sh
[ -r "$HARNESS/bin/lib/gh-repo-token.sh" ] && . "$HARNESS/bin/lib/gh-repo-token.sh" 2>/dev/null
# shellcheck source=bin/lib/gh-app-auth.sh
[ -r "$HARNESS/bin/lib/gh-app-auth.sh" ] && . "$HARNESS/bin/lib/gh-app-auth.sh"   # App token per repo (#425); unarmed box untouched
# shellcheck source=bin/lib/gh-pr-list.sh
[ -r "$HARNESS/bin/lib/gh-pr-list.sh" ] && . "$HARNESS/bin/lib/gh-pr-list.sh" 2>/dev/null
# shellcheck source=bin/lib/merge-conductor-lib.sh
if [ -r "$HARNESS/bin/lib/merge-conductor-lib.sh" ]; then
  . "$HARNESS/bin/lib/merge-conductor-lib.sh" 2>/dev/null
else
  say "" "bin/lib/merge-conductor-lib.sh missing — no refresh helper, nothing to do"; exit 0
fi
type mc_rebase >/dev/null 2>&1 || { say "" "mc_rebase not available — nothing to do"; exit 0; }
# The conductor's rows are READ here and never written; its log is its own, so
# this train's mc_log lines land in this train's log.
# Defaulted rather than assumed: this lane must not die on `set -u` because a
# conductor lib grew or lost a variable name.
MC_ROWS_RO="${MC_ROWS:-$HARNESS/state/merge-conductor/pr-state.tsv}"
MC_RB_DIR="${MC_RB_DIR:-$HARNESS/state/merge-conductor/rebase}"
MC_LOG="$LOG"

PROJECTS="$*"
if [ -z "$PROJECTS" ]; then
  PROJECTS=$(sched_conf REBASE_TRAIN_REPOS '' "$HARNESS")
  [ -n "$PROJECTS" ] || PROJECTS=$("$HARNESS/bin/fleet-conf.sh" --projects 2>/dev/null)
fi
[ -n "$PROJECTS" ] || { say "" "no projects resolved (fleet.conf unreadable?) — nothing to do"; exit 0; }

PUSHED=0

# base_branch <project> — env/<project>.env's BASE_BRANCH, else main. READ, not
# sourced: this lane must not inherit a project's secrets to learn a branch name.
base_branch() {
  local b
  b=$(sed -n 's/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}BASE_BRANCH=//p' \
      "$HENV/$1.env" 2>/dev/null | tr -d "\"' " | tail -1)
  printf '%s\n' "${b:-main}"
}

# conductor_holds <slug> <num> — rc 0 when the conductor owns this PR right now.
conductor_holds() {
  local st s
  st=$(awk -F'\t' -v k="$1#$2" '$1==k {print $2; exit}' "$MC_ROWS_RO" 2>/dev/null)
  for s in $SKIP_STATES; do [ "$st" = "$s" ] && return 0; done
  # A detached conductor rebase for this PR that is still RUNNING.
  # THE FILE'S EXISTENCE IS NOT THE ANSWER. mc_rebase_run leaves its job file
  # behind with status `done` — 35 of them on the hub on 2026-09-15, some days
  # old — so testing for the file alone would exclude every PR the conductor has
  # EVER rebased, permanently, and the train would quietly do less and less work
  # on exactly the repos that need it most. mc_rb_state is the conductor's own
  # reading (it ages a stalled job out via MC_REBASE_TIMEOUT_SECS); the jq line
  # is the fallback for a lib that does not export it.
  local f
  for f in "$MC_RB_DIR/${1//\//_}_$2"_*.json; do
    [ -f "$f" ] || continue
    if type mc_rb_state >/dev/null 2>&1; then
      [ "$(mc_rb_state "$f")" = running ] && return 0
    else
      [ "$(jq -r '.status // ""' "$f" 2>/dev/null)" = running ] && return 0
    fi
  done
  return 1
}

for P in $PROJECTS; do
  [ "$PUSHED" -lt "$MAX" ] || break
  SLUG=$("$HARNESS/bin/fleet-conf.sh" "$P" repo 2>/dev/null)
  [ -n "$SLUG" ] || continue
  BASE=$(base_branch "$P")
  MARK="$MARKDIR/${SLUG//\//_}.last"

  # Token routing per repo, exactly as bin/merge-conductor.sh does it: the hub's
  # default PAT cannot see every repo in the fleet.
  type gh_repo_use_token >/dev/null 2>&1 && gh_repo_use_token "$SLUG" >/dev/null 2>&1
  command -v gh_auth_for >/dev/null 2>&1 && gh_auth_for "$SLUG" || true

  SHAS=$(gh api "repos/$SLUG/commits?sha=$BASE&per_page=$NCOMMITS" --jq '.[].sha' 2>/dev/null)
  [ -n "$SHAS" ] || { say "$P" "could not read $BASE's commits — retrying next tick"; continue; }
  NEWEST=$(head -1 <<<"$SHAS")
  LAST=$(cat "$MARK" 2>/dev/null)
  if [ -z "$LAST" ]; then
    # FIRST SIGHT OF A REPO PLANTS THE MARK AND DOES NOTHING ELSE. Treating an
    # absent mark as "everything in the window is new" would push every open PR
    # on the repo in one tick — on a fresh box, on a restored state dir, or the
    # first time this lane runs at all.
    printf '%s\n' "$NEWEST" > "$MARK"
    say "$P" "first tick — mark planted at ${NEWEST:0:8}, no refresh"
    continue
  fi
  [ "$LAST" = "$NEWEST" ] && continue

  # Everything merged since the mark, newest first, stopping at the mark. A mark
  # that has fallen out of the window (more than $NCOMMITS merges since) takes
  # the whole window: a partial answer refreshes the PRs it can see and the mark
  # moves, rather than the lane silently doing nothing forever.
  NEW=$(printf '%s\n' "$SHAS" | awk -v m="$LAST" '$0==m{exit} {print}')
  [ -n "$NEW" ] || { printf '%s\n' "$NEWEST" > "$MARK"; continue; }
  NNEW=$(printf '%s\n' "$NEW" | wc -l | tr -d ' ')

  MERGED=$(for S in $NEW; do gh api "repos/$SLUG/commits/$S" --jq '.files[].filename' 2>/dev/null; done | sort -u)
  if [ -z "$MERGED" ]; then
    printf '%s\n' "$NEWEST" > "$MARK"
    say "$P" "$NNEW new commit(s) on $BASE, no file list readable — mark advanced, no refresh"
    continue
  fi
  MF=$(mktemp "${TMPDIR:-/tmp}/rta-merged-XXXXXX") || continue
  printf '%s\n' "$MERGED" > "$MF"
  NMERGED=$(wc -l < "$MF" | tr -d ' ')

  PRJSON=""
  type harness_pr_list >/dev/null 2>&1 && \
    PRJSON=$(harness_pr_list "$SLUG" open "number,url,headRefName,headRefOid,isDraft,mergeStateStatus,baseRefName,files" "$PR_LIMIT" 2>/dev/null)
  if [ -z "$PRJSON" ]; then
    rm -f "$MF"
    say "$P" "$NNEW new commit(s) on $BASE but the open-PR list was unreadable — mark NOT advanced, retrying next tick"
    continue
  fi

  # BH-1585 (review round 2): a row whose merge state could not be read this tick
  # (UNVERIFIABLE — bin/lib/gh-pr-list.sh's per-PR degradation) is neither
  # refreshed nor passed over: the mark stays where it is, so the next tick
  # looks at the same merged commits again instead of advancing past a PR it
  # never judged.
  UNVER=$(printf '%s' "$PRJSON" | jq -r --arg b "$BASE" '[.[]? | select((.isDraft // false) | not)
      | select((.baseRefName // "-") == $b and .mergeStateStatus == "UNVERIFIABLE") | "#\(.number)"] | join(" ")' 2>/dev/null)
  REFRESHED=0
  while IFS=$'\t' read -r NUM URL BR HEAD FILES; do
    [ -n "${NUM:-}" ] || continue
    [ "$PUSHED" -lt "$MAX" ] || { say "$P" "at REBASE_TRAIN_MAX=$MAX pushes this tick — the rest are re-offered next tick"; break; }
    conductor_holds "$SLUG" "$NUM" && continue
    # Does this PR touch anything that just landed?
    HITS=$(printf '%s\n' "$FILES" | tr ',' '\n' | sort -u | comm -12 - "$MF" | head -3 | tr '\n' ',' | sed 's/,*$//')
    [ -n "$HITS" ] || continue
    OUT=$(mc_rebase "$SLUG" "$P" "$BR" "$HEAD" "$URL"); RC=$?
    case "$RC" in
      0) PUSHED=$((PUSHED+1)); REFRESHED=$((REFRESHED+1))
         say "$P" "$URL refreshed onto $BASE (${HEAD:0:8} -> ${OUT:0:8}) — merged files it shares: $HITS" ;;
      5) PUSHED=$((PUSHED+1)); REFRESHED=$((REFRESHED+1))
         say "$P" "$URL pushed (${OUT:0:8}) but the approval rebind FAILED — the conductor will re-review it; shares: $HITS" ;;
      1) say "$P" "$URL CONFLICTS with $BASE outside the deterministic classes ($(printf '%s' "$OUT" | tr '\n' ' ')) — left for the conductor"
         "$HARNESS/bin/lane-alert.sh" --critical rebase-train-ahead \
           "$URL conflicts with $BASE on $(printf '%s' "$OUT" | tr '\n' ' ') — the targeted rebase train cannot resolve it; bin/merge-conductor.sh will class it NEEDS_REBASE and bin/blocked-resolver.sh takes it from there" \
           >/dev/null 2>&1 || true ;;
      2) say "$P" "$URL refresh gate RED (typecheck/unit) — not pushed, shares: $HITS" ;;
      3) say "$P" "$URL head moved under the lease — not pushed, retrying next tick" ;;
      *) say "$P" "$URL refresh setup failed (rc $RC) — retrying next tick" ;;
    esac
  done < <(printf '%s' "$PRJSON" | jq -r '.[]? | select((.isDraft // false) | not)
      | [(.number|tostring), (.url // "-"), (.headRefName // "-"), (.headRefOid // "-"),
         (.baseRefName // "-"), (.mergeStateStatus // "-"),
         ((.files // []) | map(.path // .filename // empty) | join(","))] | @tsv' 2>/dev/null \
      | awk -F'\t' -v b="$BASE" '$5==b && $6!="DIRTY" && $6!="UNVERIFIABLE" {print $1"\t"$2"\t"$3"\t"$4"\t"$7}')

  rm -f "$MF"
  if [ -n "$UNVER" ]; then
    say "$P" "$NNEW new commit(s) on $BASE — the merge state of $UNVER was unverifiable this tick; refreshed $REFRESHED PR(s), mark NOT advanced, retrying next tick"
    command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset
    continue
  fi
  printf '%s\n' "$NEWEST" > "$MARK"
  say "$P" "$NNEW new commit(s) on $BASE touching $NMERGED file(s) — refreshed $REFRESHED PR(s), mark -> ${NEWEST:0:8}"
  command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset
done

type mc_git_auth_clear >/dev/null 2>&1 && mc_git_auth_clear
exit 0
