#!/bin/bash
# gh-identity: raw-pat (BH-2006) — the PR-lane slice of the App-token rollout: it reads, comments on and lands the PRs of one merge train. It arrived after the census, BH-439 shipped that slice without it, and the parent #425 closed without converting it, so BH-2006 owns it now.
# bin/batch-resolve.sh <project> — BH-498. Land approved siblings whose ONLY
# conflicts are in files the repo itself marks machine-written as ONE merge-time
# train: one union branch, one regenerate, one verification run, one queue entry.
#
# THE POLICY, VERBATIM AND FIRST, because every line below is downstream of it:
# **one ticket, one PR, one review, always; batching is a merge-time
# optimization, never a review-time one** (the operator, 2026-09-16). PRs are never
# combined BEFORE review — a BLOCK on one would hold its siblings hostage, the
# review prompt would blow the 128 KB argv limit on every batch, and the
# per-ticket ledger (cost per PR, iron-law attribution, close-out comment,
# revert unit) would lose its key. So this lane only ever sees PRs that already
# carry their own head-bound APPROVE, and the union branch it builds is never
# reviewed by anything: it is a merge artifact, not a change.
#
# THE TAIL IT EXISTS FOR. One night's conflict tail on one repo was almost
# entirely registry and doc files — a generated import set, a generated guard
# list, wave docs, migration directories — and the conductor cleared it ONE PR
# every fifteen minutes, each with a full rebase, a full CI run and, when the
# push moved the head, a paid re-review. Mergify's batch queue already runs CI
# once over a combined tree, but it only accepts PRs that are already CLEAN
# against main and each other; a set of approved siblings that are DIRTY on a
# registry file never reaches it. This is the step that makes them clean, once,
# together.
#
# WHAT `merge=union` ACTUALLY DOES, since the design turns on it: git honours a
# `merge=union` attribute in BOTH `git merge` and `git merge-tree --write-tree`
# (probed on git 2.55), so a union-marked registry file is concatenated silently
# and never surfaces as a conflict at all. There is therefore NO union resolver
# in here — writing one would be dead code. The union paths are read anyway and
# kept in the allow-list, because that is what makes the rule true on a box
# whose git does not apply the attribute; and if such a path DOES conflict (a
# modify/delete, which the union driver cannot answer) it is treated like any
# other unhandled conflict: that PR drops out of the batch.
#
# DEFAULT ON ONLY WHERE THE REPO HAS DECLARED ITS GENERATED FILES. Without that
# table every conflict is a source conflict and this lane has nothing to do, so
# a repo that declares none exits 0 having done nothing at all.
#
# FLAGS
#   flags/batch-resolve-off      kill switch (a train already pushed is still settled)
#   BATCH_RESOLVE=0              the same, per project (the project's env file)
#   flags/automerge-disabled     the fleet kill switch: nothing at all
#   BATCH_SPLIT_MAX (2)          levels of binary split a red union may buy
#   BATCH_MAX_MEMBERS (8)        members one train may carry
#   BATCH_TRAIN_TTL (21600)      seconds a train may sit in flight before it is
#                                closed, its members released and one alert raised
#   BATCH_TRAIN_MIN (1)          members a train needs. 1 = a lone approved PR
#                                rides immediately instead of waiting for a
#                                partner (BH-1269)
#   BATCH_OWN_CI_RED (1)         read each candidate's OWN CI before building the
#                                union, and rebase an inherited red
#   BATCH_REBASE_MAX (2)         inherited-red rebases one PR may buy
#   BATCH_PREEMPT_LATE_RED (1)   close and re-form a train when a member's own CI
#                                goes red AFTER the train was built
#   BATCH_MAIN_RED_CLEAR (1)     a merged fix-main-red PR lifts the freeze here
#   BATCH_TOKEN_MIN_LIFE (600)  seconds of life the App token must still
#                                have before a union is pushed (BH-1630)
#   <state>/train-skip.txt       one PR number per line, read LIVE: an operator
#                                parks a member without restarting anything
#
# usage: batch-resolve.sh <project>   (invoked by the merge-conductor tick after
# classification, and safe to run by hand). exit 0 always: this is a cron lane,
# and a refusal is a log line, never a failing exit that a wrapper would retry.
#
# gh-rest: no-graphql
#
set -uo pipefail
PROJECT="${1:?project}"
H="${HARNESS:-/root/harness}"
export HARNESS="$H"
[ -f "$H/fleet.conf" ] && export FLEET_CONF="${FLEET_CONF:-$H/fleet.conf}"
mkdir -p "$H/logs" "$H/state" "$H/flags" "$H/locks" 2>/dev/null
# The env directory is RESOLVED, never spelled: it moved to /etc/harness/env and
# the old path is a compat symlink for one release (tests/env-path-test.sh scans
# bin/ for anything that spells it out).
# shellcheck source=bin/lib/env-path.sh
. "$H/bin/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "$H/env"; }
HENV=$(harness_env_dir)
set -a; . "$HENV/global.env" 2>/dev/null; . "$HENV/$PROJECT.env" 2>/dev/null; set +a
# shellcheck source=/dev/null
[ -r "$H/bin/jobs-client.sh" ] && . "$H/bin/jobs-client.sh"
# shellcheck source=bin/lib/ledger-twin.sh
[ -r "$H/bin/lib/ledger-twin.sh" ] && . "$H/bin/lib/ledger-twin.sh"
# A box mid-sync can carry this script without the library; every verb then
# answers "no row", which is today's behaviour exactly.
declare -F lt_on >/dev/null 2>&1 || { lt_on() { return 1; }; lt_get() { return 1; }; lt_read() { LT_VAL=""; return 1; }; lt_seen() { return 1; }; lt_put() { return 0; }; }
# shellcheck source=bin/lib/gh-repo-token.sh
[ -r "$H/bin/lib/gh-repo-token.sh" ] && . "$H/bin/lib/gh-repo-token.sh"
# shellcheck source=bin/lib/gh-pr-list.sh
[ -r "$H/bin/lib/gh-pr-list.sh" ] && . "$H/bin/lib/gh-pr-list.sh"
# The REST contract the settle path reads and writes GitHub through (#768):
# rc 0 = act on the body, rc 44 = an affirmative 404, rc 75 = UNVERIFIABLE.
# shellcheck source=bin/lib/gh-rest.sh
[ -r "$H/bin/lib/gh-rest.sh" ] && . "$H/bin/lib/gh-rest.sh"
# shellcheck source=bin/lib/merge-conductor-lib.sh
. "$H/bin/lib/merge-conductor-lib.sh"
# shellcheck source=bin/lib/hotfix-lib.sh
[ -r "$H/bin/lib/hotfix-lib.sh" ] && . "$H/bin/lib/hotfix-lib.sh"
# A tree with no hotfix-lib answers "not a hotfix" to everything, which is this
# script's behaviour before BH-370.2, line for line.
command -v hotfix_pr_is >/dev/null 2>&1 || hotfix_pr_is() { return 1; }
# THE TICKET HOLD AND THE LEAD-PR FENCE (BH-1526, BH-1558), asked of every train
# member in br_member_fenced below (BH-1630).
# shellcheck source=bin/lib/ticket-ownership.sh
[ -r "$H/bin/lib/ticket-ownership.sh" ] && . "$H/bin/lib/ticket-ownership.sh"
mc_init

# THE FLEET OFF-SWITCH (BH-1132), read the way every wired lane reads it: the
# D1 pause row is reconciled into flags/lane-off-batch-resolve[-<project>] and
# then the file is tested, so an operator can stop this lane fleet-wide or on
# one project without ssh-ing to the hub. Fail-open, and a gated tick exits 0.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off batch-resolve <project>.
# shellcheck disable=SC1091
. "${H}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit batch-resolve "$PROJECT"
# BH-2435: batch-resolve-off is a settings row before it is a file (lane-switch.sh).
. "${H}/bin/lib/lane-switch.sh" 2>/dev/null || true
command -v lane_switch >/dev/null 2>&1 || lane_switch() { [ -f "${H}/flags/$1" ]; }
# AND BELOW THE ENV LOAD, never above it: lane_env_apply exports this lane's
# settings rows into the environment its own ${KNOB:-default} reads use, and
# env/global.env would otherwise re-assign every one of them a line later.
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    batch-resolve "$PROJECT"
# BH-4659 (BH-4656.1): the open list reads the shared PR snapshot. The train
# re-reads (gh pr view, gh_rest_pr_state_var) do not go through it and stay live.
# shellcheck source=bin/lib/pr-snapshot.sh
. "${H}/bin/lib/pr-snapshot.sh" 2>/dev/null || true
command -v prs_open_list >/dev/null 2>&1 && export HPL_SNAPSHOT=1

# BH-1269's train helpers. A MODULE of bin/lib/mc/ and not a block in the lib,
# because that lib is being thinned to a shim (BH-477 / #1191). Sourced here
# rather than from the lib because this lane is its only caller; a tree without
# it runs every pre-BH-1269 path unchanged, which is what each `command -v`
# guard below falls back to.
#
# AND IT IS SOURCED BELOW lane_env_apply, NOT ABOVE IT (#1287). The module fixes
# MC_TRAIN_CI_IGNORE / MC_TRAIN_CI_WORKFLOW / MC_TRAIN_CI_REQUIRED —  and now
# MC_TRAIN_MODULE_DIRS — at SOURCE time from `${BATCH_*:-default}`. Sourced
# above the apply, those four read the box's environment and could never see a
# `lane.batch-resolve.*` settings row: the registry called them settable, the
# console wrote the row, the row was exported a line too late, and the lane went
# on logging the default value back at the operator who had just changed it.
# The env-file path worked throughout, which is exactly why nothing errored.
# shellcheck source=bin/lib/mc/train.sh
[ -r "$H/bin/lib/mc/train.sh" ] && . "$H/bin/lib/mc/train.sh"

LOG="$H/logs/batch-resolve.log"
STATE="$H/state/batch-resolve/$PROJECT"
# One PR number per line, read LIVE on every candidate (BH-1269). An operator
# who wants a member out of the next train appends a line; nothing restarts,
# no flag is flipped, and removing the line puts it back.
SKIPFILE="$STATE/train-skip.txt"
say() { echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [$PROJECT] $*" >> "$LOG"; }
# member_excluded <num> <head> [only-status] — has this (PR, head) already been
#   dealt with by a train? The three per-member files answer first, exactly as
#   they always have; when they have nothing, the ROW TWIN answers (BH-1036).
#   That is the case the ticket is about: the state directory lives on one
#   machine, so a wiped hub re-batches PRs it has already closed and re-comments
#   on them. Three files, one key: (PR, head), so a push to a member makes it a
#   candidate again the moment something has actually changed.
#   With `only-status` given only that one file — and only that one status — is
#   accepted, because the settle guard asks a narrower question than the
#   candidate filter: a `red` row must NOT read as "already landed".
member_excluded() {
  local num="$1" head="$2" only="${3:-}" f st files="landed red abandoned"
  [ -n "$only" ] && files="$only"
  for f in $files; do
    grep -qxF "$num $head" "$STATE/$f.txt" 2>/dev/null && return 0
  done
  lt_on || return 1
  # lt_read, not `$(lt_get ...)`: this runs once per candidate, and the library's
  # outage breaker can only latch in a shell that survives the call (BH-1036 r1).
  lt_read batch_member "$SLUG#$num@$head" || return 1
  st="$LT_VAL"
  if [ -n "$only" ]; then [ "$st" = "$only" ]; return; fi
  case "$st" in landed|red|abandoned) return 0 ;; esac
  return 1
}
SPLIT_MAX="${BATCH_SPLIT_MAX:-2}"
MAX_MEMBERS="${BATCH_MAX_MEMBERS:-8}"
# How long a train may sit in flight before it is abandoned and its members
# released. Six hours is far past any queue's own patience; the cost of
# waiting longer is that this lane is disabled for the project the whole time.
TRAIN_TTL="${BATCH_TRAIN_TTL:-21600}"
# MEMBERS A TRAIN NEEDS (BH-1269). One, by default: a train of one costs exactly
# the CI run a direct merge costs, and it keeps everything a train is for — the
# merge-tree probe against the base, the regenerate over the result, and the
# post-merge closure that marks every member merged by ancestry. Waiting for a
# partner bought none of that and cost hours. Raise it to 2 for the pre-BH-1269
# behaviour. bin/lib/mc/queue.sh:mc_batch_should_spawn reads the same knob, or
# the conductor would never spawn the lane for a lone candidate.
TRAIN_MIN="${BATCH_TRAIN_MIN:-1}"
case "$TRAIN_MIN" in ''|*[!0-9]*|0) TRAIN_MIN=1 ;; esac
OWN_CI_RED="${BATCH_OWN_CI_RED:-1}"
REBASE_MAX="${BATCH_REBASE_MAX:-2}"
case "$REBASE_MAX" in ''|*[!0-9]*) REBASE_MAX=2 ;; esac
PREEMPT_LATE_RED="${BATCH_PREEMPT_LATE_RED:-1}"
# HOW MUCH LIFE THE APP TOKEN MUST STILL HAVE before a union is pushed (BH-1630,
# #1624 round 4). The push is followed by `gh pr create` on that token; a token
# that dies in between leaves a pushed union with no train PR. The mint is asked
# for this much life (a short cached token is re-minted), and the cached expiry
# is then read back and checked. An installation token lives 3600s.
TRAIN_TOKEN_MIN_LIFE="${BATCH_TOKEN_MIN_LIFE:-600}"
case "$TRAIN_TOKEN_MIN_LIFE" in ''|*[!0-9]*) TRAIN_TOKEN_MIN_LIFE=600 ;; esac
MAIN_RED_CLEAR="${BATCH_MAIN_RED_CLEAR:-1}"
# An OUTPUT of bin/lib/mc/train.sh, not a knob: it carries the reason a freeze
# still stands out to the one log line below. Initialised HERE so a tree whose
# harness sync has not landed that module yet does not die on an unbound
# variable under `set -u` — and so it is not read as a `${KNOB:-default}` the
# registry owes a row for (tests/lanes-registry-test.sh case 7, MRG_FLAG's case).
MRT_FIX_WHY=""
# TRAINS IN FLIGHT AT ONCE (BH-1270), and the CI capacity that bounds it.
# One train in flight bounds the base branch's merge rate at one CI run, and
# nothing about that wait is a safety property: two unions cut from the same
# base only meet if they touch the same files. So the candidates are partitioned
# into groups that cannot meet and one train per group is opened in one tick.
# TRAIN_PARALLEL=1 is BH-1269's behaviour, byte for byte — one group, every
# candidate in it, in the order the pass found them.
TRAIN_PARALLEL="${TRAIN_PARALLEL:-2}"
case "$TRAIN_PARALLEL" in ''|*[!0-9]*|0) TRAIN_PARALLEL=1 ;; esac
# THE POOL'S DECLARED SIZE, and what one run of this repo's workflow occupies of
# it. N trains in flight raise N concurrent runs; a repo whose run is 8 shard
# jobs wide cannot have two of them on a pool of 8 runners without the second
# one's shards QUEUEING, and a queued job is indistinguishable from a slow one
# (docs/CI-RUNNERS.md) — so the lane would buy latency, not throughput. 0
# runners means nobody has declared a pool size, which is this fleet's honest
# state: CI runs on `vars.CI_RUNNER`, hosted by default, whose concurrency is
# the account's and not ours to count. Then only TRAIN_PARALLEL binds.
CI_RUNNERS="${BATCH_CI_RUNNERS:-0}"
CI_SHARDS="${BATCH_CI_SHARDS:-8}"
PARALLEL_CAP=1
command -v mrt_parallel_cap >/dev/null 2>&1 \
  && PARALLEL_CAP=$(mrt_parallel_cap "$TRAIN_PARALLEL" "$CI_RUNNERS" "$CI_SHARDS")
case "$PARALLEL_CAP" in ''|*[!0-9]*|0) PARALLEL_CAP=1 ;; esac
# RE-FORMS ONE TRAIN MAY BUY (BH-1270). When a sibling group's train lands, this
# one's union no longer merges onto the new tip — its members are unchanged, so
# the fix is to rebuild the union on the new tip and force-push the SAME branch:
# no re-review, because nothing any verdict is bound to has moved. Bounded
# because a repo whose base moves faster than a union verifies would otherwise
# re-form for ever and never reach its own queue.
REFORM_MAX="${BATCH_REFORM_MAX:-3}"
case "$REFORM_MAX" in ''|*[!0-9]*) REFORM_MAX=3 ;; esac
# Trains this pass has pushed, the slots it may still fill, and whether THIS
# group has had its one train. A group pushes at most one train (a red union's
# second half is the next pass's candidate set, exactly as before); the pass
# pushes at most TRAIN_SLOTS.
TRAINS_PUSHED=0
TRAIN_SLOTS=1
GROUP_PUSHED=0
TRAIN_GROUP=0
# The candidate maps, declared HERE rather than beside the candidate loop: the
# settle pass now re-forms a train, and a re-form builds a union out of the
# record's own members, which needs all three (BH-1270).
# APPROVEDOF is the sha each member's APPROVE is bound to (BH-5804). The record
# carries it as `approved`, and the train PR body names it beside the sha the
# union actually merged.
declare -A HEADOF URLOF BRANCHOF RECOF APPROVEDOF
# THE MEMBERS A TRAIN LEFT OUT (BH-5804), one `num<TAB>branch<TAB>approved<TAB>
# now<TAB>reason` line each, for the train PR body. Reset per attempt and per
# re-form. No field is ever empty (`-` for an unknown sha), so a tab read keeps
# every field in place.
DROPPED_ROWS=""

flag_on() { # the file is the flag; flag_active reconciles it from the DB row first
  if command -v flag_active >/dev/null 2>&1; then flag_active "$1"; else [ -f "$H/flags/$1" ]; fi
}

# THE FLEET KILL SWITCH STOPS EVERYTHING, including the settle: while it is on
# nothing in the fleet writes to GitHub, and closing a member PR is a write.
flag_on automerge-disabled && { say "flags/automerge-disabled is on — batch-resolve does nothing"; exit 0; }
# This board's own auto-merge toggle (#2322) stops this project's trains the same way.
flag_on "automerge-disabled-$PROJECT" && { say "flags/automerge-disabled-$PROJECT is on — batch-resolve does nothing for $PROJECT"; exit 0; }

GATED=0; GATE=""
if lane_switch batch-resolve-off; then
  GATED=1; GATE=$(lane_switch_src batch-resolve-off 2>/dev/null) || GATE="flags/batch-resolve-off"
fi
[ "${BATCH_RESOLVE:-1}" = 0 ] && { GATED=1; GATE="BATCH_RESOLVE=0"; }
# NO NEW TRAIN INTO A RED MAIN (BH-945). A train PR is unlabelled and is not a
# test-only diff, so no lane could land it while the freeze is on anyway — this
# gate just stops building one that nothing can merge, and stops the fetch,
# clone and union typecheck that would buy it. It is a GATE and not a member
# filter on purpose: the settle pass below still finishes a train that is
# already pushed, which is this script's own rule.
if command -v main_red_flag >/dev/null 2>&1; then
  BR_SLUG=$("$H/bin/fleet-conf.sh" "$PROJECT" repo 2>/dev/null)
  if BR_RED=$(main_red_flag "$PROJECT" "${BR_SLUG:-}"); then
    # A MERGED fix-main-red PR IS MAIN'S NEXT STATE (BH-1269). Its own CI ran on
    # the merge ref — i.e. on main-with-the-fix — so once it merges green the
    # hold is over at that instant, not at bin/main-red-detector.sh's next pass
    # over main. On 2026-09-21 that wait cost ~20 minutes per red episode, three
    # times in one day, with every merge lane in the fleet stopped throughout.
    #
    # It is a FACT-ONLY lift: the PR must carry the fleet's fix label
    # (MC_MAIN_RED_LABEL / MAIN_RED_LABEL, never a literal), must have merged
    # SINCE this box learned the freeze was on (the flag file's own mtime), and
    # its head must be GREEN — a concluded success, which is not the same thing
    # as "nothing has failed yet" (mrt_head_green). An unreadable answer changes
    # nothing. flag_set clears the D1 pause row and the file in
    # the same call, so a box that only sees the row does not re-materialise it.
    if [ "$MAIN_RED_CLEAR" = 1 ] && [ -n "${BR_SLUG:-}" ] && [ "$BR_SLUG" != "-" ] \
       && command -v mrt_main_red_fixed >/dev/null 2>&1; then
      command -v use_token >/dev/null 2>&1 && { use_token "$BR_SLUG" >/dev/null 2>&1 || true; }
      # NOT inside $( ): mrt_main_red_fixed leaves the PR it picked AND the
      # reason a freeze still stands in the calling shell, and a memo written in
      # a command substitution dies with the subshell (main-red-gate.sh's
      # MRG_FLAG, same trap). The printed answer is the same; these are read.
      if mrt_main_red_fixed "$BR_SLUG" "$H/flags/$BR_RED" >/dev/null; then
        BR_FIX_NUM="$MRT_FIX_NUM"; BR_FIX_HEAD="$MRT_FIX_HEAD"
        if command -v flag_set >/dev/null 2>&1; then
          flag_set "$BR_RED" off "the fix PR #$BR_FIX_NUM merged with its merge-ref CI concluded green (batch-resolve, BH-1269)" >/dev/null 2>&1 \
            || rm -f "$H/flags/$BR_RED" 2>/dev/null
        else
          rm -f "$H/flags/$BR_RED" 2>/dev/null
        fi
        command -v main_red_forget >/dev/null 2>&1 && main_red_forget
        say "flags/$BR_RED CLEARED — the fix PR #$BR_FIX_NUM (carrying the fleet's fix label) merged and its own CI on the merge ref ${BR_FIX_HEAD:0:12} CONCLUDED success, so that commit IS main's next state; the freeze and its D1 pause row are lifted now rather than at the detector's next main run"
        BR_RED=""
      elif [ -n "$MRT_FIX_WHY" ]; then
        # A FREEZE THAT STANDS BECAUSE THE FIX IS NOT GREEN YET IS NOT SILENCE.
        # Without this the log says only "main is red", and the operator cannot
        # tell "nobody has landed a fix" from "the fix landed and its run has
        # not concluded" from "the fix landed with no run at all" — which is the
        # shape an App-token push produces here, and the one BATCH_CI_RUN_REQUIRED
        # exists to refuse.
        say "flags/$BR_RED STANDS — $MRT_FIX_WHY"
      fi
    fi
    if [ -n "$BR_RED" ]; then
      GATED=1
      GATE="flags/$BR_RED (main is red — no new train while the freeze is on; a train already pushed is still settled)"
    fi
  fi
fi
# A GATE STOPS NEW BATCHES; A TRAIN ALREADY PUSHED IS ALWAYS FINISHED. Flipping
# the flag while a train is in flight must not strand approved PRs whose commits
# are already in the base branch with their rows still open — so the gate is
# checked again after the settle pass. The test for "is there a train" is a glob,
# not `-d`, because the state directory outlives the trains in it: a gated
# project whose last train landed a week ago must go no further than this line,
# and in particular must not reach the token probe below.
have_trains() {
  local f
  for f in "$STATE"/train-*.json; do
    [ -f "$f" ] || continue
    case "$(jq -r '.status // "open"' "$f" 2>/dev/null)" in open|creating) return 0 ;; esac
  done
  return 1
}
if [ "$GATED" = 1 ] && ! have_trains; then
  say "$GATE — nothing to do"
  exit 0
fi

# DEDUPE, NEVER A QUEUE. A second invocation while one is working exits at once;
# it never waits, because the work it would do is the same work.
exec 9>"$H/locks/batch-resolve-$PROJECT.lock"
flock -n 9 || exit 0

SLUG=$("$H/bin/fleet-conf.sh" "$PROJECT" repo 2>/dev/null)
[ -n "$SLUG" ] && [ "$SLUG" != "-" ] || { say "no repo slug in fleet.conf — refusing"; exit 0; }
if command -v use_token >/dev/null 2>&1; then
  use_token "$SLUG" >/dev/null 2>&1 || { say "$SLUG: no token this box can use — nothing read, nothing written"; exit 0; }
fi
PBASE=$(mc_project_base "$PROJECT")

# ---------------------------------------------------------------------------
# The repo checkout. Same resolution and the same credential path mc_rebase
# takes — the hub clone when there is one (it is what makes the verification
# contract runnable, because node_modules is next to it), a scratch clone
# otherwise. mc_git_auth is what chooses the token that can actually FETCH,
# which is not always the token that can read the repo's metadata.
# ---------------------------------------------------------------------------
REPO=""; REMOTE=""
repo_ready() {
  mc_git_auth "$SLUG" || { say "$SLUG: no configured token can read the remote — see merge-conductor.log"; return 1; }
  REMOTE="$MC_REMOTE"
  REPO="${MC_REPOS:-/root/repos}/$PROJECT"
  if [ -d "$REPO/.git" ]; then
    git -C "$REPO" remote set-url origin "$REMOTE" >/dev/null 2>&1 || true
  else
    REPO="$H/tmp/batch-resolve/${SLUG//\//_}"
    mkdir -p "$(dirname "$REPO")"
    if [ ! -d "$REPO/.git" ]; then
      git -c credential.helper= clone -q --filter=blob:none "$REMOTE" "$REPO" >/dev/null 2>&1 || { say "clone of $SLUG failed"; return 1; }
    else
      git -C "$REPO" remote set-url origin "$REMOTE" >/dev/null 2>&1 || true
    fi
  fi
  git -C "$REPO" -c credential.helper= fetch -q origin "$PBASE" >/dev/null 2>&1 || { say "fetch of $PBASE failed"; return 1; }
  return 0
}

# ---------------------------------------------------------------------------
# What the REPO says about itself. Both reads are `git show` against the base
# branch rather than a working-tree read: the answer must be the one that holds
# for the tree the train will be cut from, not for whatever a stale checkout has.
# ---------------------------------------------------------------------------
show_base() { git -C "$REPO" show "origin/$PBASE:$1" 2>/dev/null; }

# regen_table -> "<path-or-glob>\t<command>" per line, from the repo's own
#   "generated files" table. THREE homes, in order: AGENT_ARCHITECTURE.md (where
#   the fleet's repos keep it), docs/verification-map/README.md (a target repo
#   that still commits its index) and docs/verification-map/index/tail.md.
#   Cells are markdown, so the backticks come off; a separator row, a header row
#   and any row whose first cell is not path-shaped are skipped.
#
#   THE THIRD HOME IS WHY THIS LANE IS STILL ON (BH-1175). cromford stopped
#   committing its generated README, and `git show origin/main:<that path>`
#   answers nothing for a file that is not in the tree — so this table came back
#   EMPTY and bin/batch-resolve.sh's own rule ("a repo that declares nothing
#   exits having done nothing") turned the batch train off for this repo,
#   silently, on the one repo whose conflict tail the lane was built for. The
#   table's SOURCE is index/tail.md; the README only ever carried a copy of it.
#   Deduped, because a repo that has both files would otherwise declare each row
#   twice.
regen_table() {
  local f
  for f in AGENT_ARCHITECTURE.md docs/verification-map/README.md docs/verification-map/index/tail.md; do
    show_base "$f" | awk '
      tolower($0) ~ /^#+[ \t]*.*generated files/ { sec=1; next }
      sec && /^#+ / { exit }
      sec && /^\|/ {
        line = $0
        sub(/^\|/, "", line)
        n = split(line, c, "|")
        if (n < 2) next
        p = c[1]; cmd = c[2]
        gsub(/`/, "", p);   gsub(/^[ \t]+|[ \t]+$/, "", p)
        gsub(/`/, "", cmd); gsub(/^[ \t]+|[ \t]+$/, "", cmd)
        if (p == "" || cmd == "") next
        if (p ~ /^-+$/ || cmd ~ /^-+$/) next
        if (p !~ /[\/.]/) next
        print p "\t" cmd
      }'
  done | awk 'NF && !seen[$0]++'
}

# regen_homes_declare_heading -> rc 0 when ANY of the three homes carries a
#   `generated files` heading at the base branch. It is the difference between
#   "this repo never declared a table" (off by design, quiet) and "the
#   declaration is right there and the parser read zero rows out of it" (the
#   lane switching itself off, which must page).
regen_homes_declare_heading() {
  local f
  for f in AGENT_ARCHITECTURE.md docs/verification-map/README.md docs/verification-map/index/tail.md; do
    show_base "$f" | grep -qiE '^#+[[:space:]]*.*generated files' && return 0
  done
  return 1
}

# union_paths -> the patterns this repo has told git to union-merge.
union_paths() { show_base .gitattributes | awk '$0 !~ /^#/ && /merge=union/ {print $1}'; }

# verify_cmd -> the repo's Verification Contract command, or `npm test`.
#   The first non-comment line of the first fenced block under the contract
#   heading. A repo that states no contract gets the fleet default, and the
#   choice is LOGGED either way — "we ran the wrong suite" must never be a thing
#   somebody has to guess about afterwards.
verify_cmd() {
  local c
  c=$(show_base CLAUDE.md | awk '
    /^##+[ \t]*[Vv]erification [Cc]ontract/ { sec=1; next }
    sec && /^## / { exit }
    sec && /^```/ { fence = 1 - fence; next }
    sec && fence && NF && $0 !~ /^[ \t]*#/ { print; exit }')
  c=$(printf '%s' "$c" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [ -n "$c" ] || c="npm test"
  printf '%s' "$c"
}

# path_allowed <path> — rc 0 when the repo has declared this file machine-written
#   (regenerable) or union-mergeable. Everything else is a SOURCE conflict and
#   takes today's path, which is the whole safety property of this lane.
path_allowed() {
  local f="$1" p
  [ -n "$(regen_cmd_for "$f")" ] && return 0
  # The patterns are gitattributes globs and are MEANT to be globs here, which is
  # what both disables below say: `tests/*.txt` has to match a path, and a
  # pattern with no slash matches at any depth, the way git reads it.
  # ONE PATTERN PER LINE, never word-split: a gitattributes pattern may contain
  # a space (escaped or quoted), and `for p in $UNION_PATHS` would turn one such
  # pattern into two that match nothing.
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    # shellcheck disable=SC2254
    case "$f" in $p) return 0 ;; esac
    # shellcheck disable=SC2254
    case "$p" in */*) ;; *) case "${f##*/}" in $p) return 0 ;; esac ;; esac
  done <<<"$UNION_PATHS"
  return 1
}

# regen_cmd_for <path> — the command that rebuilds it, or nothing.
regen_cmd_for() {
  local f="$1" p c
  while IFS=$'\t' read -r p c; do
    [ -n "$p" ] || continue
    [ "$p" = "$f" ] && { printf '%s' "$c"; return 0; }
    # shellcheck disable=SC2254
    case "$f" in $p) printf '%s' "$c"; return 0 ;; esac
  done <<<"$REGEN_TABLE"
  return 1
}

# br_member_fenced <num> <head> <author> — rc 0 when this PR must NOT enter a
# union this pass: its ticket is on HOLD, or it is a lead PR with no lead/human
# MERGE row standing on <head>, or either question could not be answered
# (BH-1630).
#
# THIS LANE IS A LANDING PATH, and until BH-1630 it asked neither question. The
# train PR it opens is the App's, so every merge lane's lead fence passes the
# TRAIN, and each member reaches main by ancestry when the train lands. A lead
# PR with a box record and a box APPROVE (the #1547 shape) and a pool PR on a
# ticket the lead had held both rode a train on the three gates above alone.
#
# THE SAME TWO CALLS EVERY OTHER MERGE LANE MAKES, never a second reader:
# to_lane_hold (a held ticket's PR does not merge; a lead PR is exempt) and
# to_lane_lead_fence (a lead PR merges only on a lead/human MERGE row on this
# exact head; a box APPROVE is never a clearance). Each writes its one deduped
# MERGE_HELD line into this lane's log.
#
# FAIL CLOSED. An unreadable PR, hold, lead_pr_authors row or verdicts table
# keeps the PR out this pass and marks nothing red: the next pass asks again.
# The lead-row and verdicts outages feed the block gate's streak, which raises
# ONE lane-wide alert per outage window (bg_streak_note).
#
# The lead list is read ONCE per pass into this shell (to_lead_authors fills
# its memo on the first call and answers from it after), not once per
# candidate: to_lane_lead_hold asks inside `$( )`, where a memo would die.
#
# THE SETTLE AND RE-FORM PATHS ASK IT TOO (BH-1934): a HOLD or a withdrawn lead
# row that lands after a train opened ejects that member (fence_eject,
# reform_train), so it is defined here, ahead of the top-level settle_trains.
#
# No ownership library on this box: admitted as before, the answer every other
# lane gives (merge-queue's mq_lead_hold, review-prs's rp_ticket_fence).
br_member_fenced() {
  local num="$1" head="$2" who="$3"
  [ "$who" = - ] && who=""
  command -v to_lane_lead_fence >/dev/null 2>&1 || return 1
  to_lead_authors >/dev/null
  to_lane_hold "$PROJECT" "$SLUG" "$num" "$LOG" && return 0
  to_lane_lead_fence "$PROJECT" "$SLUG" "$num" "$head" "$who" "$LOG"
  [ "$?" = 1 ] && return 1
  return 0
}

# ---------------------------------------------------------------------------
# The settle pass. A train lands minutes to hours after it is pushed, out of a
# queue this lane never watches, so the landing is read on a LATER invocation —
# the same shape the conductor's QUEUED pass has, and for the same reason.
# ---------------------------------------------------------------------------
settle_trains() {
  local f
  for f in "$STATE"/train-*.json; do
    [ -f "$f" ] || continue
    settle_train "$f"
  done
}

train_status_set() { # train_status_set <file> <status> [merge-sha] [detail]
  local f="$1" st="$2" sha="${3:-}" detail="${4:-}" br
  jq -c --arg s "$st" --arg m "$sha" '.status=$s | (if $m == "" then . else .merge_sha=$m end)' \
    "$f" > "$f.tmp" 2>/dev/null && mv -f "$f.tmp" "$f"
  # THE ROW FOLLOWS THE FILE, never the other way round (BH-1269). The file is
  # what this lane reads and what its own correctness depends on; the row is
  # what Mission Control shows and what lets a rebuilt box find a train it did
  # not push. mrt_row_put fails open, so a worker outage costs a row and
  # changes not one decision here.
  br=$(jq -r '.train_branch // ""' "$f" 2>/dev/null)
  [ -n "$br" ] && train_row "$f" "$st" "$sha" "$detail"
  return 0
}

# train_row <file> <outcome> [merge-sha] [detail] — the D1 row for a train,
#   assembled from the file record so the two can never disagree about who was
#   in it. The CI run id is read ONCE, when the train concludes: that is the one
#   run a train buys, and it is the number a human chasing a red union wants.
train_row() {
  local f="$1" outcome="$2" msha="${3:-}" detail="${4:-}" br pr mem cnt usha rid="" grp
  command -v mrt_row_put >/dev/null 2>&1 || return 0
  br=$(jq -r '.train_branch // ""' "$f" 2>/dev/null); [ -n "$br" ] || return 0
  # THE GROUP RIDES THE ROW (BH-1270). With N trains in flight, "which trains
  # were running beside this one" is the first question a reader of a red union
  # asks, and a row that cannot answer it makes every parallel train look like
  # a serial one that happened to be quick.
  grp=$(jq -r '.train_group // ""' "$f" 2>/dev/null)
  pr=$(jq -r '.train_url // ""' "$f" 2>/dev/null); pr="${pr##*/}"
  case "$pr" in ''|*[!0-9]*) pr="" ;; esac
  mem=$(jq -r '[.members[]?.num] | join(",")' "$f" 2>/dev/null)
  cnt=$(jq -r '.members | length' "$f" 2>/dev/null)
  usha=$(jq -r '.union_sha // ""' "$f" 2>/dev/null)
  case "$outcome" in
    landed|abandoned|red)
      [ -n "$usha" ] && command -v mrt_run_id >/dev/null 2>&1 \
        && rid=$(mrt_run_id "$SLUG" "$usha" 2>/dev/null) ;;
  esac
  mrt_row_put "$PROJECT" "$br" "$outcome" "repo=$SLUG" "train_pr=${pr:-}" \
    "members=${mem:-}" "member_count=${cnt:-}" "union_sha=${usha:-}" \
    "run_id=${rid:-}" "merge_sha=${msha:-}" "train_group=${grp:-}" "detail=${detail:-}"
  return 0
}
# train_release_all <file> — every member's hold comes off AND every member is
#   excluded at the head it was in the train with.
#
#   THE EXCLUSION IS WHAT STOPS THE LOOP. Releasing the holds alone let the very
#   same pass rebuild an identical train from the same PRs, which for a train
#   that can NEVER merge — a required check the queue never satisfies, a paused
#   queue, branch protection the token cannot meet — meant a new train PR and a
#   fresh alert every BATCH_TRAIN_TTL, for ever, on a client's repo. It is keyed
#   on (PR, head) like every other marker here, so a push to any member makes it
#   a candidate again the moment something has actually changed.
#   WITH A SECOND ARGUMENT, ONLY THAT MEMBER IS EXCLUDED (BH-1269). A train that
#   was PRE-EMPTED is a different case from one that was closed or aged out:
#   exactly one member is known bad and the rest are untouched and still green,
#   so the next union — which no longer contains that member — is a DIFFERENT
#   union and the "do not rebuild the identical train" rule does not apply to
#   it. Excluding them all is what stopped the re-form from happening at all.
train_release_all() { # train_release_all <file> [only-exclude-this-num]
  local n hd only="${2:-}"
  mkdir -p "$STATE" 2>/dev/null
  while IFS=$'\t' read -r n hd; do
    [ -n "$n" ] || continue
    mc_batch_release "$SLUG" "$n"
    [ -n "$only" ] && [ "$n" != "$only" ] && continue
    if [ -n "$hd" ] && [ "$hd" != "-" ]; then
      ! grep -qxF "$n $hd" "$STATE/abandoned.txt" 2>/dev/null \
        && echo "$n $hd" >> "$STATE/abandoned.txt"
      lt_put batch_member "$SLUG#$n@$hd" abandoned
    fi
  done < <(jq -r '.members[]? | [.num,.head] | @tsv' "$1" 2>/dev/null)
  return 0
}

# delete_train_branch <branch> — take a dead train's branch off the remote. The
#   settle pass runs before the checkout exists, so it asks for one; a branch
#   left behind is litter on somebody else's repo and, with the name carrying a
#   timestamp, litter that accumulates.
delete_train_branch() {
  local br="$1"
  [ -n "$br" ] || return 0
  [ -n "$REPO" ] || repo_ready || { say "the dead train branch $br could not be deleted — the repo was not reachable this pass"; return 1; }
  git -C "$REPO" -c credential.helper= push -q "$REMOTE" --delete "$br" >/dev/null 2>&1 \
    && say "the dead train branch $br is deleted from the remote" \
    || say "the dead train branch $br could not be deleted — harmless, but stale"
}

# abandon_train <file> <url> <log-why> <alert-why> [row-detail]
#   Everything a train owes when it is taken out of the queue for good: the PR
#   is closed, every member released AND excluded at the head it rode with, the
#   branch deleted, the record and its D1 row marked abandoned, and ONE alert
#   raised. It was the tail of the age-budget arm below and is factored out
#   because BH-1306 gave it a second caller — a train that is BEHIND the base
#   tip and either red there or out of re-form budget — and the two must not be
#   able to drift apart.
#
#   A REFUSED CLOSE STILL RELEASES, which is the age budget's own rule kept
#   verbatim: the members are what matters, and a record nothing owns holding
#   eight PRs is how this lane disables itself for a whole project. Nothing here
#   can stamp an unverified union as landed either — `landed` is only ever
#   written by the MERGED arm.
abandon_train() {
  local f="$1" turl="$2" logwhy="$3" alertwhy="$4" detail="${5:-}" cerr
  cerr=$(gh api -X PATCH "repos/$SLUG/pulls/${turl##*/}" -f state=closed 2>&1 >/dev/null) \
    && say "train $turl closed: $logwhy" \
    || say "train $turl is being taken out of the queue ($logwhy) and the close was REFUSED — ${cerr:-no stderr}; its members are released anyway"
  train_release_all "$f"
  delete_train_branch "$(jq -r '.train_branch // ""' "$f" 2>/dev/null)"
  train_status_set "$f" abandoned "" "$detail"
  say "train $turl ABANDONED: $logwhy — its members are released to the ordinary one-at-a-time path and excluded at these heads, so nothing rebuilds the same train until one of them is pushed to"
  # ONE ALERT PER STUCK SET, not one per tick. The key carries the train's
  # number, which changes every rebuild — so before the exclusion above this
  # paged afresh every six hours for ever about the same problem.
  mc_alert "$SLUG#${turl##*/}" READY "$alertwhy: $turl" 2>/dev/null || true
  return 0
}

# train_behind <file> — rc 0 when the union branch on the remote does NOT
#   contain the CURRENT $PBASE tip, i.e. the train was verified on a base that
#   something has landed on since. rc 1 = it contains it, or the answer could
#   not be read — and an unreadable answer is never read as "behind", because
#   the consequence of being wrong about it is closing a landable train.
#
#   GIT ANSWERS THIS, NOT GITHUB. `mergeStateStatus=BEHIND` is only reported
#   under strict required status checks, and this repo's branch protection
#   declares none (`required_status_checks: null`) — which is exactly why the
#   gap exists at all. So the tip and the union branch are fetched into the hub
#   clone and `merge-base --is-ancestor` is asked directly.
train_behind() {
  local f="$1" br tip
  br=$(jq -r '.train_branch // ""' "$f" 2>/dev/null); [ -n "$br" ] || return 1
  reform_ready || {
    say "train $br: the repo could not be prepared to ask whether it is behind the $PBASE tip — it is left where it is this pass"
    return 1; }
  git -C "$REPO" -c credential.helper= fetch -q origin "$br" >/dev/null 2>&1 || {
    say "train $br could not be fetched to ask whether it is behind the $PBASE tip — it is left where it is this pass"
    return 1; }
  tip=$(git -C "$REPO" rev-parse "origin/$PBASE" 2>/dev/null); [ -n "$tip" ] || return 1
  git -C "$REPO" merge-base --is-ancestor "$tip" "origin/$br" >/dev/null 2>&1 && return 1
  return 0
}

settle_train() {
  local f="$1" url st sha n hd j stat unsettled=0 age created mstate
  stat=$(jq -r '.status // "open"' "$f" 2>/dev/null)
  case "$stat" in
    creating) reconcile_creating "$f"; return 0 ;;
    open) ;;
    *) return 0 ;;
  esac
  url=$(jq -r '.train_url // ""' "$f" 2>/dev/null)
  [ -n "$url" ] || { reconcile_creating "$f"; return 0; }
  # `mergeable` and `mergeStateStatus` ride the SAME read (BH-1270): with N
  # trains in flight, "a sibling group landed and this union no longer merges"
  # is the ordinary case, not an exception, and asking for it separately would
  # be one more GitHub call per open train per */5 tick.
  j=$(gh pr view "$url" --json state,mergeCommit,mergeable,mergeStateStatus 2>/dev/null)   # gh-guard-allow: read not converted by BH-770.1; #770 tracks it
  st=$(jq -r '.state // ""' <<<"$j" 2>/dev/null)
  sha=$(jq -r '.mergeCommit.oid // ""' <<<"$j" 2>/dev/null)
  mstate=$(jq -r '[(.mergeable // ""), (.mergeStateStatus // "")] | join(" ")' <<<"$j" 2>/dev/null)
  case "$st" in
    MERGED)
      [ -n "$sha" ] || { say "train $url is MERGED but GitHub has not published its merge commit — settling on the next pass"; return 0; }
      # A MEMBER THAT DID NOT SETTLE KEEPS THE TRAIN OPEN. The log used to say
      # "the next pass retries the close" while this line flipped the train to
      # `landed` regardless, so the next pass returned at the status check and
      # the retry never existed. The words and the code agree now.
      while IFS=$'\t' read -r n _u _br hd; do
        [ -n "$n" ] || continue
        settle_member "$n" "$sha" "$url" "$hd" || unsettled=$((unsettled + 1))
      done < <(jq -r '.members[]? | [.num,.url,.branch,.head] | @tsv' "$f" 2>/dev/null)
      if [ "$unsettled" -gt 0 ]; then
        say "train $url landed as ${sha:0:12} but $unsettled member(s) still owe their close-out — the train stays OPEN and the next pass retries exactly those"
        return 0
      fi
      train_status_set "$f" landed "$sha"
      say "train $url LANDED as ${sha:0:12} — $(jq -r '.members|length' "$f" 2>/dev/null) member PRs closed, ledgered and closed out"
      ;;
    CLOSED)
      # Nothing was done to the members, so there is nothing to undo: they are
      # still open, still approved, and the ordinary path owns them again. They
      # are excluded at these heads for the same reason the age budget excludes
      # them: rebuilding the identical train that somebody just closed achieves
      # nothing until one of them changes.
      train_release_all "$f"
      delete_train_branch "$(jq -r '.train_branch // ""' "$f" 2>/dev/null)"
      train_status_set "$f" abandoned
      say "train $url was CLOSED without merging — its members are released to the ordinary one-at-a-time path and excluded at these heads until one of them is pushed to"
      ;;
    *)
      # A BODY THE LAST RE-FORM COULD NOT WRITE IS WRITTEN NOW (BH-5804). The
      # record keeps the body text; one PATCH per pass until GitHub takes it.
      [ "$(jq -r '.body_stale // false' "$f" 2>/dev/null)" = true ] && train_body_retry "$f" "$url"
      # A MEMBER PUT ON HOLD, OR STRIPPED OF ITS LEAD ROW, AFTER THE TRAIN WAS
      # BUILT IS EJECTED (BH-1934). The candidate loop asked br_member_fenced
      # when the member was admitted, and nothing asked again: bin/merge-queue.sh
      # lands a train PR with no member fence, so the held PR reached main by
      # ancestry. Asked FIRST, ahead of the pre-emption: a HOLD is the stronger
      # stop, and a re-form around a member that has also gone red is still
      # caught by preempt_late_red on the next tick.
      fence_eject "$f" "$url" && return 0
      # A MEMBER THAT WENT RED AFTER THE TRAIN WAS BUILT PRE-EMPTS IT (BH-1269).
      # The candidate filter reads each head's own CI before the union is built,
      # but a job can conclude minutes later — and once it has, this train is
      # going to fail its one run, get closed, and buy a binary split to
      # rediscover which member it was. The split costs a full CI run per half
      # and lands nothing. Closing the train NOW and letting the next pass
      # re-form it without that member costs one run, total, and every other
      # member keeps its place in the very next train.
      #
      # The red member is excluded at THAT head (abandoned.txt, the same key
      # every other exclusion here uses), so a push to it makes it a candidate
      # again and nothing else does.
      if [ "$PREEMPT_LATE_RED" = 1 ] && command -v mrt_own_red >/dev/null 2>&1; then
        preempt_late_red "$f" "$url" && return 0
      fi
      # A SIBLING GROUP'S TRAIN LANDED UNDER THIS ONE (BH-1270, widened by
      # BH-1306). That is the ordinary cost of running N trains at once, and it
      # is NOT a reason to re-review anything: every member is still sitting at the head
      # its own APPROVE is bound to, and the union branch is a merge artifact
      # that was never reviewed in the first place. So the union is rebuilt on
      # the NEW tip and force-pushed to the SAME branch — same PR, same queue
      # entry, same D1 row, a fresh CI run. Re-reading the members' verdicts,
      # re-running the block gate or opening a second train PR would all be work
      # bought by main having moved, which is the thing this lane exists to stop
      # charging for.
      #
      # It is tried AFTER the pre-emption above, deliberately: re-forming a
      # union around a member that is already red buys a red run twice.
      #
      # AND "NO LONGER MERGES" IS ONLY HALF OF IT (BH-1306). When the sibling
      # lands, this train's union usually still merges cleanly — its merge base
      # is the OLD tip, so GitHub says MERGEABLE/CLEAN and the DIRTY case below
      # never fires. Nothing downstream re-verifies the two together:
      # bin/merge-queue.sh lands a train PR without reading any CI, and this
      # repo's branch protection declares no required checks. So the union that
      # lands is one whose verify_union ran on a base that is gone — reviewer
      # probe P7, and a concrete red-main path. The second trigger is therefore
      # BEHIND: the union on the remote does not contain the current tip. It is
      # asked SECOND, because a DIRTY train is also behind and the dirty arm is
      # the one whose log line and failure semantics are right for it.
      #
      # AND NEVER UNDER A GATE. Settling a train that has already landed is
      # finishing work the fleet already committed to; re-forming one is a
      # clone, a fetch, a union build, a verification run and a PUSH — exactly
      # the spend BH-945's freeze exists to refuse, and exactly what
      # flags/batch-resolve-off means. A gated pass leaves the train where it
      # is and the age budget is the backstop, as it was before BH-1270.
      if [ "$GATED" != 1 ] && [ "$REFORM_MAX" -gt 0 ] && command -v mrt_carry_ok >/dev/null 2>&1; then
        case "$mstate" in
          *CONFLICTING*|*DIRTY*) reform_train "$f" "$url" dirty && return 0 ;;
          # ONLY WHEN GITHUB ANSWERED, AND ANSWERED "OPEN". A `mergeable` of
          # CONFLICTING cannot be read out of a failed call, so the dirty arm is
          # guarded by its own value — this one is not, and an unread `gh pr
          # view` lands here with everything empty. A train that has in fact
          # MERGED reads as "behind" by construction (the tip contains the
          # union, not the reverse), so a read failure would re-form, or even
          # close, a train that is already landed. Absent is not behind.
          *) [ "$st" = OPEN ] && train_behind "$f" && reform_train "$f" "$url" behind && return 0 ;;
        esac
      fi
      # A TRAIN THAT NEVER MERGES IS ABANDONED, NOT LEFT IN FLIGHT. A queue that
      # never took it, or a red batch build, would otherwise hold its members
      # until the seven-day gc AND keep the in-flight guard on, which disables
      # this lane for the whole project in the meantime. Same shape as the
      # conductor's own state budgets: one deadline, one alert, one next move.
      created=$(jq -r '.created_at // 0' "$f" 2>/dev/null)
      case "$created" in ''|null|*[!0-9]*) created=0 ;; esac
      age=$(( $(date -u +%s) - created ))
      [ "$created" -gt 0 ] && [ "$age" -ge "$TRAIN_TTL" ] || return 0
      abandon_train "$f" "$url" \
        "$((age / 60))m in flight without merging (age budget ${TRAIN_TTL}s, BATCH_TRAIN_TTL)" \
        "a batch train sat $((age / 60))m without merging and was abandoned — its members went back to the ordinary merge path and will not be batched again at these heads. Check whether the queue took it and whether its build went red"
      ;;
  esac
}

# preempt_late_red <file> <train-url> — rc 0 when a member's OWN CI has
#   concluded failure since the train was built and the train has therefore been
#   closed, its members released and the red one excluded at its head. rc 1 =
#   nothing to do (no member is red, or none could be read).
#
#   THE COST IS N READS PER SETTLE TICK of an open train, N = its members, and
#   it stops at the first red one. Capped by BATCH_MAX_MEMBERS (8) against a
#   train that lives minutes to hours, so it is single digits per train per
#   tick — against a binary split, which is a full CI run per half.
#
#   ONLY A CONCLUDED FAILURE COUNTS. A pending job is the ordinary state of a
#   train's members while the union builds, and an unreadable answer is not a
#   verdict: both leave the train exactly where it is, which is what the age
#   budget below is for.
preempt_late_red() {
  local f="$1" turl="$2" n hd why red="" redhead="" usha rid=""
  while IFS=$'\t' read -r n hd; do
    [ -n "$n" ] && [ -n "$hd" ] && [ "$hd" != "-" ] || continue
    why=$(mrt_own_red "$SLUG" "$hd") || continue
    red="$n"; redhead="$hd"; break
  done < <(jq -r '.members[]? | [.num,.head] | @tsv' "$f" 2>/dev/null)
  [ -n "$red" ] || return 1
  if ! gh api -X PATCH "repos/$SLUG/pulls/${turl##*/}" -f state=closed >/dev/null 2>&1; then
    say "train $turl carries #$red, whose own CI has since gone red ($why), but the train PR could not be closed — it is left in flight and the next pass retries; the age budget is the backstop"
    return 1
  fi
  # ONLY the red member is excluded; every other member is released clean and
  # is a candidate for the very next union, which is the whole saving here.
  train_release_all "$f" "$red"
  # AND THE UNION'S OWN RUN IS CANCELLED. The train PR is closed and its branch
  # is about to be deleted, so nothing will ever read that run's answer — but it
  # keeps a pool runner busy testing a branch that no longer exists until it
  # finishes. Best effort: a refusal is not worth a line.
  usha=$(jq -r '.union_sha // ""' "$f" 2>/dev/null)
  if [ -n "$usha" ] && command -v mrt_run_id >/dev/null 2>&1; then
    rid=$(mrt_run_id "$SLUG" "$usha" 2>/dev/null) \
      && command -v mrt_run_cancel >/dev/null 2>&1 && mrt_run_cancel "$SLUG" "$rid"
  fi
  delete_train_branch "$(jq -r '.train_branch // ""' "$f" 2>/dev/null)"
  train_status_set "$f" abandoned "" "pre-empted: #$red went red after the train formed ($why)"
  say "train $turl PRE-EMPTED — #$red's own CI concluded failure after the train was built ($why), so the train is closed before it buys a red run and the split that would rediscover it; its other members are released and ride the next train, and #$red is excluded at ${redhead:0:12} until it is pushed to"
  return 0
}

# fence_eject <file> <train-url> — rc 0 when a member is now on HOLD or
#   lead-fenced (br_member_fenced, at the head it rode with) and the train has
#   therefore been re-formed without it, or closed. rc 1 = no member is fenced,
#   or the close was refused and the train is left for the next pass.
#
#   RE-FORM FIRST, CLOSE AS THE FALLBACK. The clear members are still at the
#   heads their APPROVEs name, so the same PR carries a union without the held
#   one (reform_train `fenced`, one unit of BATCH_REFORM_MAX). When that cannot
#   happen — a gated pass, a zero or spent budget, too few members left, a union
#   that will not build or verify, a refused push — the train is CLOSED, because
#   the queue lander would otherwise merge it with the held member inside.
#
#   NOBODY IS EXCLUDED. A hold is not a verdict on the code: `-` matches no
#   member, so train_release_all releases every one and writes nothing to
#   abandoned.txt, and a RESUME is all it takes to ride again. An unreadable
#   fence ejects too (br_member_fenced fails closed) and, being unmarked, comes
#   back when the read recovers. No alert: a HOLD is an operator's act.
#
#   A REFUSED CLOSE RELEASES NOTHING. Unlike the age budget, the train still
#   exists and still holds its members; the next pass asks again.
fence_eject() {
  local f="$1" turl="$2" n hd fenced="" usha rid=""
  while IFS=$'\t' read -r n hd; do
    [ -n "$n" ] && [ -n "$hd" ] && [ "$hd" != "-" ] || continue
    br_member_fenced "$n" "$hd" - </dev/null && fenced="${fenced:+$fenced }#$n"
  done < <(jq -r '.members[]? | [.num,.head] | @tsv' "$f" 2>/dev/null)
  [ -n "$fenced" ] || return 1
  if [ "$GATED" != 1 ] && [ "$REFORM_MAX" -gt 0 ] && command -v mrt_carry_ok >/dev/null 2>&1; then
    reform_train "$f" "$turl" fenced && return 0
  fi
  if ! gh api -X PATCH "repos/$SLUG/pulls/${turl##*/}" -f state=closed >/dev/null 2>&1; then
    say "train $turl carries $fenced, now held or lead-fenced, but the train PR could not be closed (the close was REFUSED) — nothing is released, it is left in flight and the next pass retries; the age budget is the backstop"
    return 1
  fi
  train_release_all "$f" -
  usha=$(jq -r '.union_sha // ""' "$f" 2>/dev/null)
  if [ -n "$usha" ] && command -v mrt_run_id >/dev/null 2>&1; then
    rid=$(mrt_run_id "$SLUG" "$usha" 2>/dev/null) \
      && command -v mrt_run_cancel >/dev/null 2>&1 && mrt_run_cancel "$SLUG" "$rid"
  fi
  delete_train_branch "$(jq -r '.train_branch // ""' "$f" 2>/dev/null)"
  train_status_set "$f" abandoned "" "ejected: $fenced held or lead-fenced after the train formed"
  say "train $turl CLOSED — $fenced ejected: held or lead-fenced after the train formed, and the train could not be re-formed without it $([ "$GATED" = 1 ] && printf 'on a gated pass (%s)' "$GATE" || printf 'this pass'); every member is released and NONE is marked red or excluded, so the clear ones ride the next train and a held one rides again once its hold lifts"
  return 0
}

# reform_ready — everything a union needs, set up lazily for the SETTLE pass.
#   The pass itself sets these up after its own gate checks; the settle runs
#   before any of that and needs no git at all when there is no open train.
#
#   WHAT IT COSTS SINCE BH-1306, stated plainly because the old comment claimed
#   the opposite: an ungated tick that has an OPEN, non-dirty train DOES pay for
#   a checkout, because train_behind has to ask git whether the union contains
#   the tip. That is one auth + the base fetch here + one fetch of the union
#   branch, per open non-dirty train, per tick. It is memoised, so a tick pays
#   the auth and the base fetch once however many trains it settles, and a GATED
#   tick still pays nothing at all — the behind check sits inside the same guard
#   BH-945's freeze does.
#   A repo that declares no generated files refuses here exactly as the pass
#   refuses below — without the table every conflict is a source conflict and
#   this lane has nothing it may resolve.
REFORM_READY=0
reform_ready() {
  [ "$REFORM_READY" = 1 ] && return 0
  repo_ready || return 1
  REGEN_TABLE=$(regen_table)
  [ -n "$REGEN_TABLE" ] || return 1
  UNION_PATHS=$(union_paths)
  VERIFY=$(verify_cmd)
  QPROV=$(mc_queue_provider "$SLUG")
  REFORM_READY=1
  return 0
}

# reform_failed <file> <url> <why> <what> <alert-why> <row-detail>
#   A re-form that cannot happen, answered by the TRIGGER rather than by the
#   arm it failed in. `dirty`: say it and let the age budget own the train,
#   which is exactly what every one of those arms did before BH-1306 — nobody
#   anywhere can land a union that does not merge, so a stuck DIRTY train is a
#   waste of a queue slot and nothing worse. `behind`: the union DOES merge,
#   bin/merge-queue.sh lands it without reading any CI, and its verification
#   covered a base that is gone — so the same outcome would be a merge of a
#   tree nothing ever judged. The train is closed and its members released.
#   `fenced` (BH-1934): rc 1 and nothing else — fence_eject closes the train
#   itself, and abandon_train would exclude the held member it exists to spare.
#   rc 0 = the caller is done with this train; rc 1 = it is left where it was.
reform_failed() {
  local f="$1" turl="$2" why="$3" what="$4" alertwhy="$5" detail="$6"
  if [ "$why" = fenced ]; then
    say "train $turl could not be re-formed without its held or lead-fenced member(s) — $what; nothing was pushed"
    return 1
  fi
  if [ "$why" = behind ]; then
    abandon_train "$f" "$turl" \
      "BEHIND the $PBASE tip — its base no longer contains the tip, and $what. It is LANDABLE and unverified there, and the queue lander reads no CI, so it is closed rather than left in the queue" \
      "$alertwhy" "$detail"
    return 0
  fi
  say "train $turl could not be re-formed onto the new $PBASE tip — a sibling train landed under it and its union stopped merging, and $what; nothing was pushed and its age budget owns it"
  return 1
}

# reform_train <file> <train-url> <why> — rebuild this train's union on the
#   CURRENT base tip and force-push it to the SAME branch. <why> is `dirty` (the
#   union stopped merging), `behind` (it still merges, but its base no longer
#   contains the tip) or `fenced` (a member went on HOLD or lost its lead row
#   after the train formed, BH-1934 — rc 1 then means fence_eject closes it). rc 0 = the caller is done with this train for the pass —
#   it was re-formed, or it was taken out of the queue; rc 1 = nothing was done
#   and the age budget below owns it exactly as it did before.
#
#   THE TWO WHYS FAIL DIFFERENTLY, AND THAT IS THE POINT (BH-1306). A DIRTY
#   train cannot be landed by anybody, so when its re-form cannot happen —
#   budget spent, red on the new tip — leaving it to the age budget costs
#   nothing but time. A BEHIND train IS landable: bin/merge-queue.sh reads no
#   CI and would merge it on the next tick, and what it would merge is a union
#   whose verification ran on a base that is gone. So on the behind path a spent
#   budget and a red re-verify both CLOSE the train, which is the only way this
#   lane can stop the landing.
#
#   WHY THIS IS NOT A RE-REVIEW, stated once because it is the whole ticket:
#   the members are unchanged. Each one is still at the head its own head-bound
#   APPROVE names, so nothing any verdict is bound to has moved and there is no
#   carry to make — mrt_carry_ok's question does not even arise. What moved is
#   the BASE, and the union branch is a merge artifact cut from the base that
#   nothing ever reviewed. Rebuilding it is the same act as building it.
#
#   A MEMBER WHOSE BRANCH HAS MOVED IS DROPPED, not carried: its approval no
#   longer binds to what is on the remote, which is the same rule the candidate
#   filter and settle_member's head re-read apply. If too few survive, nothing
#   is pushed and the ordinary age budget closes the train.
#
#   SO IS A MEMBER THAT IS NOW HELD OR LEAD-FENCED (BH-1934), on every trigger:
#   br_member_fenced is asked at the head the member rode with, the same
#   question the candidate loop asked when it was admitted. It is released, not
#   excluded — a RESUME or a new lead row brings it back.
#
#   AND THE PUSH IS `--force-with-lease` ON THE UNION SHA THE RECORD REMEMBERS.
#   A train branch nobody else should be writing to is still a branch, and a
#   blind force would discard whatever wrote to it — the one thing a lane that
#   exists to avoid losing work must not do.
reform_train() {
  local f="$1" turl="$2" why="${3:-dirty}" br old rn n u b hd ap now perr usha rid="" moved bf=""
  local tip="the new $PBASE tip" owns="nothing was pushed and its age budget owns it"
  local -a kept=()
  DROPPED_ROWS=""
  # The one sentence that goes in every line this function writes, so a reader
  # of the log never has to guess which trigger fired.
  case "$why" in
    behind) moved="its base no longer contains the $PBASE tip, so its verification did not cover what landed under it" ;;
    fenced) moved="a member was put on HOLD or lead-fenced after the train formed"
            tip="the current $PBASE tip"
            owns="nothing was pushed, so the train is closed instead: a held member must not land" ;;
    *)      moved="a sibling train landed under it and its union stopped merging onto $PBASE" ;;
  esac
  br=$(jq -r '.train_branch // ""' "$f" 2>/dev/null); [ -n "$br" ] || return 1
  old=$(jq -r '.union_sha // ""' "$f" 2>/dev/null); [ -n "$old" ] || return 1
  rn=$(jq -r '.reform_n // 0' "$f" 2>/dev/null)
  case "$rn" in ''|null|*[!0-9]*) rn=0 ;; esac
  if [ "$rn" -ge "$REFORM_MAX" ]; then
    if [ "$why" = behind ]; then
      abandon_train "$f" "$turl" \
        "BEHIND the $PBASE tip — $moved, and it has already been re-formed $rn time(s) (BATCH_REFORM_MAX=$REFORM_MAX). It is LANDABLE and unverified on the tip, and the queue lander reads no CI, so leaving it to its age budget is leaving it in the queue" \
        "a batch train was BEHIND the $PBASE tip with its re-form budget spent (BATCH_REFORM_MAX=$REFORM_MAX), so it was closed rather than left landable on a base its verification never covered. Its members went back to the ordinary merge path" \
        "BEHIND the $PBASE tip and out of re-form budget ($rn of $REFORM_MAX)"
      return 0
    fi
    if [ "$why" = fenced ]; then
      say "train $turl carries a held or lead-fenced member and has already been re-formed $rn time(s) (BATCH_REFORM_MAX=$REFORM_MAX) — it cannot be re-formed without it, so it is closed instead"
      return 1
    fi
    say "train $turl no longer merges onto $PBASE and has already been re-formed $rn time(s) (BATCH_REFORM_MAX=$REFORM_MAX) — it is left to its age budget rather than chasing a base that moves faster than the union verifies"
    return 1
  fi
  reform_ready || {
    say "train $turl: $moved, but the repo could not be prepared to re-form it this pass — $([ "$why" = fenced ] && printf '%s' "$owns" || printf 'retried next pass')"
    return 1; }
  # Every drop below is also a row for the PR body (BH-5804): the re-formed
  # train's body must not name a member its union no longer carries.
  while IFS=$'\t' read -r n u b hd ap; do
    [ -n "$n" ] && [ -n "$hd" ] && [ "$hd" != "-" ] || continue
    case "$ap" in ''|-|null) ap="$hd" ;; esac
    if ! git -C "$REPO" -c credential.helper= fetch -q origin "$b" >/dev/null 2>&1; then
      say "train $turl re-form: #$n's branch $b could not be fetched — it is dropped from the re-formed union and the ordinary path owns it"
      train_drop_row "$n" "$b" "$ap" - "branch could not be fetched"
      mc_batch_release "$SLUG" "$n"; continue
    fi
    now=$(git -C "$REPO" rev-parse "origin/$b" 2>/dev/null)
    if [ "$now" != "$ap" ]; then
      say "train $turl re-form: #$n dropped, head moved after approval: approved at ${ap:0:12}, head now ${now:0:12}. Its head-bound APPROVE no longer binds to what is on the remote, so it goes back to review on the new head; it is NOT marked red"
      train_drop_row "$n" "$b" "$ap" "${now:--}" "head moved after approval; back to review"
      mc_batch_release "$SLUG" "$n"; continue
    fi
    br_member_fenced "$n" "$hd" - </dev/null && {
      say "train $turl re-form: #$n is held or lead-fenced on ${hd:0:12} — ejected from the re-formed union, NOT marked red; it rides again once the hold lifts"
      train_drop_row "$n" "$b" "$ap" "$hd" "held or lead-fenced"
      mc_batch_release "$SLUG" "$n"; continue; }
    HEADOF[$n]="$hd"; URLOF[$n]="$u"; BRANCHOF[$n]="$b"; APPROVEDOF[$n]="$ap"
    kept+=("$n")
  done < <(jq -r '.members[]? | [.num,.url,.branch,.head,(.approved // .head)] | @tsv' "$f" 2>/dev/null)
  if [ "${#kept[@]}" -lt "$TRAIN_MIN" ]; then
    reform_failed "$f" "$turl" "$why" \
      "fewer than $TRAIN_MIN member(s) still sit at the head their verdict is bound to, clear of a HOLD and the lead fence, so it can never be re-formed" \
      "a batch train was BEHIND the $PBASE tip and could not be re-formed — fewer than $TRAIN_MIN of its members still sit at the head their verdict is bound to. It was closed rather than left landable on a base its verification never covered" \
      "BEHIND the $PBASE tip with too few members left to re-form"
    return $?
  fi
  # A UNION THAT WILL NOT BUILD, AND A PUSH THAT IS REFUSED, ARE "COULD NOT DO
  # THE WORK" AND NOT A VERDICT — so both retry next pass on both triggers.
  # Neither says anything about whether the train is fit to land, and the behind
  # check is asked again on the very next tick.
  build_union "$br" "${kept[@]}" || {
    union_cleanup
    say "train $turl could not be re-formed onto $tip ($moved) — the union would not build there; $owns"
    return 1; }
  # shellcheck disable=SC2086
  set -- $UNION_MEMBERS
  if [ "$#" -lt "$TRAIN_MIN" ]; then
    union_cleanup
    reform_failed "$f" "$turl" "$why" \
      "too many members now conflict with the new tip in files this repo does not mark regenerable, so it can never be re-formed" \
      "a batch train was BEHIND the $PBASE tip and could not be re-formed — too many of its members now conflict with what landed, in files this repo does not mark regenerable. It was closed rather than left landable on a base its verification never covered" \
      "BEHIND the $PBASE tip and unbuildable there"
    return $?
  fi
  local -a in=("$@")
  train_union_left_out "${kept[@]}"
  if ! verify_union; then
    union_cleanup
    reform_failed "$f" "$turl" "$why" \
      "the union of its members and what landed on $PBASE since is RED against the repo's verification contract — this is the two-green-trains red-main case, and nothing downstream would have caught it" \
      "a batch train was BEHIND the $PBASE tip and its union with what landed since is RED against the repo's verification contract — each train was green alone and their union is not. It was closed before it could land unverified; check whether the two changes are genuinely compatible" \
      "BEHIND the $PBASE tip and RED when re-verified there"
    return $?
  fi
  UNION_SHA=$(git -C "$WT" rev-parse HEAD 2>/dev/null)
  if ! perr=$(git -C "$WT" -c credential.helper= push -q \
        --force-with-lease="$br:$old" "$REMOTE" "HEAD:refs/heads/$br" 2>&1 >/dev/null); then
    union_cleanup
    say "train $turl re-formed green onto $tip but the force-push was REFUSED — $(head -1 <<<"${perr:-no stderr}" | sed 's/github_pat_[A-Za-z0-9_]*/<redacted>/g') — nothing changed and $([ "$why" = fenced ] && printf 'the train is closed instead' || printf 'the next pass retries')"
    return 1
  fi
  # The body is written while $WT still holds the union: each included sha is
  # proved against it. The trailer is applied the same way land_union does.
  bf=$(mktemp "${TMPDIR:-/tmp}/batch-body-XXXX") && train_body_write "$bf" "$br" "${in[@]}" || bf=""
  [ -r "${H:-}/bin/lib/pr-trailers.sh" ] && . "$H/bin/lib/pr-trailers.sh"
  if [ -n "$bf" ] && command -v pr_trailers_apply >/dev/null 2>&1; then
    pr_trailers_apply "$bf" "train:$br" none "$br $(printf '#%s ' ${TRAIN_BODY_IN+"${TRAIN_BODY_IN[@]}"})" \
      || say "pr trailers: could not write $bf — the re-formed train body goes without trailers"
  fi
  union_cleanup
  # AND THE SUPERSEDED RUN IS CANCELLED. The force-push raises a fresh run on
  # the new union; the old one is testing a tree nothing will ever merge and
  # holds a pool runner until it finishes. Best effort, never load-bearing.
  usha="$old"
  if command -v mrt_run_id >/dev/null 2>&1; then
    rid=$(mrt_run_id "$SLUG" "$usha" 2>/dev/null) \
      && command -v mrt_run_cancel >/dev/null 2>&1 && mrt_run_cancel "$SLUG" "$rid"
  fi
  # The record keeps its identity — same PR, same branch, same created_at and
  # therefore the same age budget — and gains the new union sha, the surviving
  # members and one more re-form.
  jq -c --arg us "$UNION_SHA" --argjson r "$((rn + 1))" \
     --argjson m "$(for n in "${in[@]}"; do jq -nc --arg n "$n" --arg u "${URLOF[$n]}" --arg br "${BRANCHOF[$n]}" --arg h "${HEADOF[$n]}" --arg a "${APPROVEDOF[$n]:-${HEADOF[$n]}}" '{num:$n,url:$u,branch:$br,head:$h,approved:$a}'; done | jq -sc '.')" \
     '.union_sha=$us | .reform_n=$r | .members=$m' "$f" > "$f.tmp" 2>/dev/null \
    && mv -f "$f.tmp" "$f"
  # THE BODY FOLLOWS THE UNION (BH-5804). A re-form that left the old body in
  # place kept naming a member the union no longer carried (#5674), and the
  # lead review BLOCKed the train for it. A refused write is recorded and
  # retried by the next settle pass; the train itself is not held for it.
  if [ -n "$bf" ]; then
    train_body_patch "$f" "$turl" "$bf"
    rm -f "$bf"
  else
    say "train $turl: the re-formed PR body could not be composed (no temp file), so the body could not be written and still names the old members; the lead review blocks such a body"
  fi
  for n in "${in[@]}"; do mc_batch_hold "$SLUG" "$n" "${HEADOF[$n]}" "$turl"; done
  train_row "$f" open "" "re-formed onto $tip (${UNION_SHA:0:12}) because $why, re-form $((rn + 1)) of $REFORM_MAX"
  say "train $turl RE-FORMED onto $tip as ${UNION_SHA:0:12} with ${#in[@]} member(s) (${in[*]}) — $moved; every member is still at the head its own APPROVE names, so NOTHING was re-reviewed and the same PR carries the new union (re-form $((rn + 1)) of $REFORM_MAX)"
  return 0
}

# reconcile_creating <file> — the crash window between pushing the branch and
#   recording the PR. Ask GitHub what exists for that branch: a PR means the
#   create DID land and we adopt it; no PR means the branch is an orphan and is
#   deleted. Either way the members stop being held by a record nothing owns.
reconcile_creating() {
  local f="$1" br url
  br=$(jq -r '.train_branch // ""' "$f" 2>/dev/null)
  [ -n "$br" ] || { train_status_set "$f" abandoned; return 0; }
  # The answer is only adopted when it IS a PR url. `null`, an empty array and
  # anything else gh may print are all "no PR", and adopting one of them would
  # park a train on a url that can never be read — the settle would then poll a
  # nonexistent PR until the age budget abandoned it.
  url=$(gh pr list -R "$SLUG" --head "$br" --state all --json url -q '.[0].url' 2>/dev/null | grep -oE 'https://github\.com/[^ "]+/pull/[0-9]+' | head -1)   # gh-guard-allow: read not converted by BH-770.1; #770 tracks it
  if [ -n "$url" ]; then
    jq -c --arg u "$url" '.train_url=$u | .status="open"' "$f" > "$f.tmp" 2>/dev/null && mv -f "$f.tmp" "$f"
    say "reconciled a train left mid-creation: $br already has $url — adopted, and it settles from here like any other"
    return 0
  fi
  # The settle pass runs BEFORE the checkout is set up (it needs no git at all
  # in the ordinary case), so the delete has to ask for one. Without this the
  # push ran in whatever directory the lane started in and the orphan branch was
  # never actually deleted — the log said "could not be deleted" every pass, for
  # ever, which is a stale branch and a lie in the same line.
  [ -n "$REPO" ] || repo_ready || {
    say "a train was left mid-creation on $br and no PR was ever opened for it, but the repo could not be reached to delete the branch — retried next pass"
    return 0; }
  git -C "$REPO" -c credential.helper= push -q "$REMOTE" --delete "$br" >/dev/null 2>&1 \
    && say "reconciled a train left mid-creation: no PR was ever opened for $br — the orphan branch is deleted" \
    || say "reconciled a train left mid-creation: no PR was ever opened for $br and the branch could not be deleted — it is harmless but stale"
  train_release_all "$f"
  train_status_set "$f" abandoned
}

# settle_member <pr-number> <train-sha> <train-url> <member-head>
#   Everything one member owes once the train has landed. The comment goes FIRST
#   and the close second, always: a PR closed without an explanation tells the
#   next reader nothing, which is the lesson mc_close_for_rebuild carries.
#
#   THE LEDGER ROW IS THE DURABLE RECORD. The conductor's own row for this PR
#   will later be rewritten to CLOSED by its closed-unmerged pass, which is
#   literally true of the member PR — it was closed, not merged. Where the WORK
#   landed is what `pr_merged … merged_via=batch:<sha>` says, and it says it in
#   the ledger, which outlives every file mirror here.
#   rc 0 = this member is done with (settled, or deliberately left open because
#   its head moved). rc 1 = it still owes something, and the caller must keep the
#   train OPEN so the next pass retries exactly this member.
settle_member() {
  local num="$1" sha="$2" turl="$3" head="${4:--}" rec issue body url now err w bf _st
  url="https://github.com/$SLUG/pull/$num"
  # IDEMPOTENT PER MEMBER, checked BEFORE anything is written. A kill part-way
  # through a settle used to leave the train open with no per-member record, so
  # the next pass re-commented on already-closed PRs and wrote a second ledger
  # row for each. The marker is the same (PR, head) key the candidate filter
  # reads, so one file answers both questions.
  if member_excluded "$num" "$head" landed; then
    mc_batch_release "$SLUG" "$num"
    return 0
  fi
  rec=$(mc_record_for "$url" || true)
  # THE HEAD IS RE-READ, NEVER ASSUMED. The conductor side of the hold is keyed
  # on the head; this side was not, so anything that pushed to a member branch
  # while the train was in flight — a human, a fix round, a rebase spawned
  # before the hold existed — had its commits closed away in silence. The train
  # landed the head it was built from and nothing else.
  now=$(gh pr view "$url" --json headRefOid -q .headRefOid 2>/dev/null | tr -d '[:space:]')   # gh-guard-allow: read not converted by BH-770.1; #770 tracks it
  if [ -n "$now" ] && [ "$head" != "-" ] && [ "$now" != "$head" ]; then
    body="The batch train $turl landed as \`$sha\`, but it was built from \`${head:0:12}\` and this PR's head is now \`${now:0:12}\`.

So the train carries the older head only. This PR is deliberately left OPEN: the commits pushed since are NOT in \`$PBASE\`, and closing it would discard them silently. What it needs now is a rebase onto \`$PBASE\` and a review of whatever is left once the landed part is subtracted — its ticket stays open too."
    # The body goes by FILE (BH-781): it already carries PR urls and shas, and
    # nothing this lane writes belongs on a process list.
    bf=$(mktemp "${TMPDIR:-/tmp}/batch-note.XXXXXX") && printf '%s\n' "$body" > "$bf"
    gh_rest_comment "$SLUG" "$num" "$bf" \
      || say "#$num: the head-moved notice could not be posted — HTTP ${GH_REST_STATUS:-000}"
    rm -f "$bf"
    mc_batch_release "$SLUG" "$num"
    mkdir -p "$STATE" 2>/dev/null
    echo "$num $head" >> "$STATE/landed.txt"
    lt_put batch_member "$SLUG#$num@$head" landed
    say "#$num NOT closed: the train landed an older head (${head:0:12}); the PR is now on ${now:0:12} and stays open with its issue, commented"
    return 0
  fi
  body="This landed in the batch train $turl, merged as $sha.

Nothing here was re-reviewed: this PR's own APPROVE is what let it into the train, and the train is a merge artifact — a union branch cut from \`$PBASE\` with each approved sibling merged into it, the repo's generated files regenerated once, and the repo's verification contract run once over the result. One ticket, one PR, one review; the batching is only in how it merged.

Closing this PR because its commits are already in \`$PBASE\` under that merge."
  # SOMEONE ELSE MAY HAVE SETTLED IT ALREADY, so read before writing. This is
  # the one state gh_rest_close cannot reach: its verifying re-read answers
  # `merged` for a PR with a merged_at, `merged` is not the literal `closed` it
  # demands, so it returns 75 forever. A member Mergify or a human merged while
  # the train was in flight — head unchanged, so the head-moved arm above does
  # not catch it — would then re-post this close-out comment on every */5 pass
  # and return 1 every time, holding the train open until the age budget
  # abandoned it. The raw PATCH path this replaced just landed it. One read
  # settles it: no comment, no close, and the ledger row and done-marker below
  # are written exactly as they are for a close this pass performed, because
  # the fact they record — "this PR's commits are in $PBASE" — is true either
  # way. An unreadable state (rc 44/75) is NOT "already settled": it falls
  # through to the normal path, which is the conservative reading.
  # BH-1485: the `_var` variant. The capture decided correctly and lost the
  # status, so the "fell through to the normal path" line below could not say
  # whether GitHub refused (403) or simply had not answered (000).
  _st=""
  gh_rest_pr_state_var _st "$SLUG" "$num" 2>/dev/null || _st=""
  [ -n "$_st" ] || say "#$num pre-settle state read UNVERIFIABLE (HTTP ${GH_REST_STATUS:-000}${GH_REST_REASON:+ $GH_REST_REASON}) — treated as not-yet-settled, which is the conservative reading"
  case "$_st" in
    merged|closed)
      say "#$num was already $_st before the train came to settle it — no comment and no close were sent; the ledger row and the done-marker are written as usual" ;;
    *)
  # THE COMMENT IS THE GATE ON THE CLOSE, which is what the log always claimed
  # and the code never did: a PR closed with no explanation tells the next
  # reader nothing, so a failed comment means the PR is genuinely left open and
  # this member is retried next pass. Every gh failure carries the vendor's own
  # first line: an error body sent to /dev/null is how a 403 becomes silence.
  #
  # AND IT IS POSTED EXACTLY ONCE ACROSS PASSES. The comment and the close are
  # two calls now, so a POST that landed under a PATCH that was refused has to
  # be remembered or the next */5 pass says the same sentence again on the same
  # client-visible PR, every pass, until the close goes through (TK-88). The
  # marker is the same `$num $head` key as landed.txt, in its own file, and it
  # follows the POST rather than the attempt.
  if ! grep -qxF "$num $head" "$STATE/closeout-commented.txt" 2>/dev/null; then
    bf=$(mktemp "${TMPDIR:-/tmp}/batch-closeout.XXXXXX") || {
      say "#$num: no temp file for the close-out comment — the PR is left OPEN and the next pass retries it"
      return 1; }
    printf '%s\n' "$body" > "$bf"
    if ! gh_rest_comment "$SLUG" "$num" "$bf"; then
      say "#$num: the batch close-out comment could not be posted — HTTP ${GH_REST_STATUS:-000}${GH_REST_REASON:+ ($GH_REST_REASON)} — the PR is left OPEN and the next pass retries it"
      rm -f "$bf"
      return 1
    fi
    rm -f "$bf"
    mkdir -p "$STATE" 2>/dev/null
    echo "$num $head" >> "$STATE/closeout-commented.txt"
  fi
  # rc 0 ONLY after a fresh read says `closed` (bin/lib/gh-rest.sh): "stamped
  # closed without being closed" is impossible by construction, so a refusal
  # writes no ledger row and no done-marker and the next pass retries it.
  if ! gh_rest_close "$SLUG" "$num" pulls; then
    say "#$num: the REST close was refused — HTTP ${GH_REST_STATUS:-000}${GH_REST_REASON:+ ($GH_REST_REASON)} — no ledger row is written and the next pass retries the close"
    return 1
  fi ;;
  esac
  type job_ledger_put >/dev/null 2>&1 \
    && job_ledger_put pr_merged "$url" merged "merged_via=batch:$sha" >/dev/null 2>&1 || true
  mkdir -p "$H/state" 2>/dev/null
  grep -qxF "$url" "$H/state/merge-sweep-done.txt" 2>/dev/null || echo "$url" >> "$H/state/merge-sweep-done.txt"
  # BH-1643: closed-by-batch, so bin/pipeline-health.sh re-reads it if it is reopened.
  grep -qxF "$url" "$H/state/batch-closed.txt" 2>/dev/null || echo "$url" >> "$H/state/batch-closed.txt"
  # The ticket close-out, exactly as the conductor does it for a normal merge:
  # issue-driven projects get the issue commented and closed; board projects are
  # closed out by the path that already owns their board comment.
  if [ "$("$H/bin/fleet-conf.sh" "$PROJECT" board_prefix 2>/dev/null)" = "-" ]; then
    issue=$(mc_issue_of "$rec" "")
    if [ -n "$issue" ]; then
      # Comment, close, and take `ai-build` off in that order (BH-637 §3b) — a
      # shipped issue still carrying the handoff label is what re-offers
      # finished work to every selector in the fleet. The helper leaves its last
      # stderr in ISSUE_CLOSE_ERR, which is what this lane reports.
      # With the PR url and the record the helper leaves a merge that only
      # SLICED the issue open (BH-2477) and says so in its word.
      if w=$(issue_close_shipped "$SLUG" "$issue" "Merged in $url, landed in the batch train $turl as $sha. Closing this issue." "$H" "$url" "$rec"); then
        case "$w" in
          kept-slice*) say "#$num left issue #$issue open, slice delivered ($w)" ;;
          *)           say "#$num closed issue #$issue (ai-build: $w)" ;;
        esac
      else
        say "#$num merged in the train but issue #$issue could not be closed — ${ISSUE_CLOSE_ERR:-no stderr} — bin/reconcile-prs.sh picks it up"
      fi
    fi
  fi
  mc_batch_release "$SLUG" "$num"
  # KEYED ON THE HEAD, not on the train's merge sha, because what it has to
  # answer is "has this PR at this head already gone through a train". GitHub's
  # open-PR list is eventually consistent, so a PR closed a second ago can still
  # come back as open on the very next read — and without this it would be
  # batched again, into a train whose diff is already in the base branch.
  echo "$num $head" >> "$STATE/landed.txt"
  lt_put batch_member "$SLUG#$num@$head" landed
  # The commented-marker's whole job is "a close-out comment is already on this
  # PR and the close has not landed yet". The member is settled, so it is
  # dropped — landed.txt is the durable record from here, and the marker file
  # would otherwise grow one line per member of every train forever.
  if [ -f "$STATE/closeout-commented.txt" ]; then
    grep -vxF "$num $head" "$STATE/closeout-commented.txt" > "$STATE/closeout-commented.t" 2>/dev/null || true
    mv -f "$STATE/closeout-commented.t" "$STATE/closeout-commented.txt" 2>/dev/null || true
  fi
  say "#$num settled: closed against the train $turl (merge ${sha:0:12}), ledger pr_merged merged_via=batch:$sha"
}

# ---------------------------------------------------------------------------
# Candidate selection.
# ---------------------------------------------------------------------------
# mt_conflicts <a> <b> — the paths `git merge-tree --write-tree` says would
#   conflict, one per line. rc 0 clean | 1 conflict (paths on stdout) | 2 could
#   not tell. `--name-only` puts the conflicted paths between the tree oid and
#   the first blank line; the informational block after it is for humans.
mt_conflicts() {
  local out rc
  out=$(git -C "$REPO" merge-tree --write-tree --name-only "$1" "$2" 2>/dev/null); rc=$?
  case "$rc" in
    0) return 0 ;;
    1) printf '%s\n' "$out" | awk 'NR>1 && /^$/{exit} NR>1{print}'; return 1 ;;
    *) return 2 ;;
  esac
}

# classify_pair <a> <b> — how two trees meet, as one word and an optional path:
#     clean            they merge with no conflict at all
#     allowed <paths>  they conflict ONLY in files the repo declares generated
#                      or union-mergeable — which is what a train is for
#     blocked <path>   the first conflicting file that is none of those
#     unknown          git could not tell, which is never read as clean
#   It PRINTS rather than sets a variable because every caller runs it in a
#   command substitution, and an assignment inside one of those is made in a
#   subshell and lost — which is exactly how a "did anything conflict" counter
#   would silently read zero for ever.
classify_pair() {
  local out rc f allowed=""
  out=$(mt_conflicts "$1" "$2"); rc=$?
  [ "$rc" = 0 ] && { printf 'clean'; return 0; }
  [ "$rc" = 2 ] && { printf 'unknown'; return 0; }
  while read -r f; do
    [ -n "$f" ] || continue
    path_allowed "$f" || { printf 'blocked %s' "$f"; return 0; }
    allowed="${allowed:+$allowed }$f"
  done <<<"$out"
  printf 'allowed %s' "$allowed"
}

# ---------------------------------------------------------------------------
# The union branch.
# ---------------------------------------------------------------------------
# batch_branch_name — sets $BRANCH_NAME to `batch/<project>/<UTC stamp>-<pid>-<n>`.
#
#   IT SETS A GLOBAL AND PRINTS NOTHING, which is the whole fix. This was a
#   counter incremented inside a function every caller ran as
#   `br=$(batch_branch_name)` — so the increment died in the subshell and every
#   branch of a pass was named the same thing. The second push of a pass was
#   then refused non-fast-forward and its GREEN members were marked red under a
#   log line blaming the push. It is the same trap the classify_pair and
#   build_union comments in this file already spell out; the answer is the same.
#
#   All three components earn their place: the stamp is what a human reads, the
#   pid separates concurrent passes (which the flock already prevents, but a
#   name must not depend on that), and the counter separates the two or three
#   attempts ONE pass makes inside the same second.
BRANCH_N=0
BRANCH_NAME=""
batch_branch_name() {
  BRANCH_NAME="batch/$PROJECT/$(date -u +%Y%m%dT%H%M%SZ)-$$-$BRANCH_N"
  BRANCH_N=$((BRANCH_N + 1))
}

# build_union <branch> <num...> — merge each member into a scratch worktree cut
#   from the base branch, in PR-age order. It sets two GLOBALS rather than
#   printing: $WT (the worktree the caller verifies, pushes and removes) and
#   $UNION_MEMBERS (the members that actually made it). A printed answer would
#   have to be read in a command substitution, and a subshell's $WT is lost the
#   moment it exits — which is a worktree leaked and a `cd` into nothing.
#   rc 1 = setup failed and nothing was built.
#
#   THE REGENERATE IS DEFERRED ON PURPOSE. A conflict in a generated file takes
#   THEIRS and records the command; every distinct command then runs ONCE, over
#   the finished union, after the last merge. Running it per conflict would buy
#   N runs of a command whose whole job is to be a pure function of the final
#   tree — and the intermediate answers would all be thrown away.

# deleted_ignored <path> — rc 0 when this unmerged path in $WT was DELETED by
#   one side and is GIT-IGNORED in the merged tree, having resolved it by taking
#   the deletion. The twin of mc_resolve_deleted_ignored in
#   bin/lib/merge-conductor-lib.sh (the rebase paths); the two must not drift.
#   The merged tree's own .gitignore is the whole authority: a modify/delete on a
#   TRACKED path is left alone and stays a real conflict.
deleted_ignored() {
  local f="$1" stages
  [ -n "$WT" ] || return 1
  stages=$(git -C "$WT" ls-files -u -- "$f" 2>/dev/null | awk '{print $3}' | sort -u | tr '\n' ' ')
  [ -n "${stages// /}" ] || return 1
  # ORIENTATION, AND IT IS THE OPPOSITE WAY ROUND FROM THE REBASE TWIN. The
  # union worktree IS the base branch and each member is merged INTO it, so here
  # OURS (stage 2) is the base and THEIRS (stage 3) is the member. A base-side
  # deletion is therefore stage 2 ABSENT — the reverse of
  # mc_resolve_deleted_ignored, where the branch is ours. Requiring the wrong
  # one would silently drop a member's edit to a file the base still carries.
  case " $stages " in *" 2 "*) return 1 ;; esac
  case " $stages " in *" 3 "*) ;; *) return 1 ;; esac
  git -C "$WT" check-ignore -q --no-index -- "$f" 2>/dev/null || return 1
  git -C "$WT" rm -q --cached -- "$f" >/dev/null 2>&1 || return 1
  rm -f "$WT/$f"
  return 0
}

WT=""; UNION_MEMBERS=""; UNION_SHA=""; EXCL_FILE=""; REGEN_FILE=""
build_union() {
  local br="$1"; shift
  local -a mem=("$@")
  local n head conf f cmd drop out pend="" kept=""
  local req="" allcmd="" tailmsg="" fpaths="" fp rp
  UNION_MEMBERS=""
  WT=$(mktemp -d "${TMPDIR:-/tmp}/batch-resolve-XXXX") || return 1
  git -C "$REPO" worktree add -f "$WT" "origin/$PBASE" >/dev/null 2>&1 || { rm -rf "$WT"; WT=""; return 1; }
  git -C "$WT" checkout -q -B "$br" >/dev/null 2>&1 || { union_cleanup; return 1; }
  for n in "${mem[@]}"; do
    head="${HEADOF[$n]}"
    if git -C "$WT" merge -q --no-edit -m "batch: merge #$n (${BRANCHOF[$n]})" "$head" >/dev/null 2>&1; then
      kept="${kept:+$kept }$n"; continue
    fi
    conf=$(git -C "$WT" diff --name-only --diff-filter=U)
    drop=""
    if [ -z "$conf" ]; then drop="the merge failed with no conflicted paths"; fi
    while read -r f; do
      [ -n "$f" ] || continue
      [ -n "$drop" ] && break
      # A DELETED, IGNORED PATH IS NOT A SIDE TO PICK (BH-1175). A generated
      # file the base branch took OUT of git meets a member that still commits
      # it as a modify/delete. `checkout --theirs` on that has no theirs to take
      # — it silently leaves OUR copy — and the `add` then RE-TRACKS a path the
      # repo ignores, so the regenerate below rewrites it, `add -A` stages it
      # (a tracked path ignores .gitignore), and verify_union's very first
      # command refuses the union it just built: "TRACKED in git and also
      # git-ignored". Every batch containing any such member would go red, split
      # in half, and hand both halves back — for a file nothing may commit.
      if deleted_ignored "$f"; then
        say "#$n: $f was deleted on $PBASE and is git-ignored there — taking the deletion into the union (BH-1175)"
        continue
      fi
      cmd=$(regen_cmd_for "$f")
      if [ -n "$cmd" ]; then
        git -C "$WT" checkout --theirs -- "$f" >/dev/null 2>&1 && git -C "$WT" add -- "$f" >/dev/null 2>&1 \
          || { drop="$f could not be resolved by taking the incoming copy"; break; }
        # $'\n' on BOTH sides: every entry in $pend ends with a newline, so
        # prefixing one anchors the match at an entry boundary. A bare
        # *"$cmd"$'\n'* is a SUBSTRING test — `gen.sh` reads as already pending
        # when `bin/gen.sh` is, and the command never runs.
        case $'\n'"$pend" in *$'\n'"$cmd"$'\n'*) ;; *) pend="$pend$cmd"$'\n' ;; esac
      else
        drop="$f, which this repo does not mark regenerable or union-mergeable"
      fi
    done <<<"$conf"
    if [ -z "$drop" ]; then
      git -C "$WT" -c commit.gpgsign=false commit -q --no-edit >/dev/null 2>&1 \
        || drop="the resolved merge would not commit"
    fi
    if [ -n "$drop" ]; then
      git -C "$WT" merge --abort >/dev/null 2>&1
      say "#$n dropped from the batch — it conflicts with a sibling in $drop (a source conflict is today's one-PR-at-a-time path)"
      continue
    fi
    kept="${kept:+$kept }$n"
  done
  # BH-969: the regenerate runs for EVERY command the table declares, not only
  # the ones a conflict happened to record. A train whose members touch disjoint
  # source files conflicts nowhere and used to leave `pend` empty — so the union
  # was pushed with its generated files stale, which is the drift failure this
  # lane exists to prevent.
  #
  # TWO SETS, because a FAILING command means two different things:
  #   $req      a conflict in that command's file was resolved by taking THEIRS,
  #             and only the regenerate makes that resolution correct. The union
  #             otherwise carries one member's copy of a file both touched, so a
  #             failure abandons the batch — the behaviour this lane has always
  #             had, unchanged.
  #   the rest  ran only because the table declares them. A failure there leaves
  #             the union exactly as stale as it was before BH-969, which is
  #             strictly better than dropping every member of every train on one
  #             project because a docs generator had a bad day. Logged, its
  #             partial writes dropped, and the batch keeps going — the same
  #             contract its rebase twin holds to (mc_regen_generated is always
  #             rc 0; see docs/verification-map/regen-on-rebase.md).
  # Widening the set must not widen the blast radius: that is what $req pins.
  req="$pend"
  allcmd=$(printf '%s\n' "$REGEN_TABLE" | cut -f2- | awk 'NF && !seen[$0]++')
  pend="${allcmd:+$allcmd$'\n'}"

  # The deferred regenerate, once per distinct command.
  if [ -n "$pend" ]; then
    # node_modules BEFORE the regenerate, not after it in verify_union's gate
    # block: a generator is as likely to need the repo's deps as the typecheck
    # is, and one that cannot find them fails for a reason that has nothing to
    # do with the union. Both twins link it first (bin/lib/rebase-job.sh step
    # 6b, mc_rebase) and docs/verification-map/regen-on-rebase.md says so under
    # "What must never regress". verify_union's own link is [ ! -e ]-guarded, so
    # it stays a no-op second call.
    [ -d "$REPO/node_modules" ] && [ ! -e "$WT/node_modules" ] \
      && ln -s "$REPO/node_modules" "$WT/node_modules" 2>/dev/null

    while read -r cmd; do
      [ -n "$cmd" ] || continue
      # `eval` of a string out of the repo's own markdown is the same trust
      # level as running that repo's test suite, which this lane does two
      # functions down; both are the repo telling us how to build it.
      out=$(mktemp "${TMPDIR:-/tmp}/batch-regen-XXXX")
      # 9>&- : the dedupe flock lives on fd 9 and a repo command that leaves a
      # background process behind would hold it for that process's whole life,
      # and this lane would never run for the project again.
      # </dev/null : this loop reads $pend on stdin, so a generator that reads
      # stdin at all would swallow the remaining rows and they would silently
      # never run.
      if ! ( cd "$WT" && eval "$cmd" ) >"$out" 2>&1 9>&- </dev/null; then
        tailmsg=$(tail -3 "$out" | tr '\n' ' ' | cut -c1-300)
        rm -f "$out"
        # Anchored on both sides for the reason the dedupe above is: a
        # SUBSTRING test lets a command that merely shares a suffix with a
        # conflict-recorded one (`bin/gen.sh` vs `E=1 bin/gen.sh`) take the
        # fatal arm and abandon a train it has no claim on. Pinned by R9c.
        case $'\n'"$req" in
          *$'\n'"$cmd"$'\n'*)
            say "the repo's own regenerate command FAILED on the union: $cmd — $tailmsg — a member conflicted in its files and only this command resolves that, so this batch is abandoned and nothing was pushed"
            union_cleanup; return 1 ;;
        esac
        say "the repo's own regenerate command FAILED on the union: $cmd — $tailmsg — nothing conflicted in its files, so the batch keeps going and its generated files stay as the members left them"
        # Restore only THIS command's declared paths. A blanket `git checkout --
        # .` would also throw away an EARLIER command's good output, which is
        # still uncommitted at this point in the loop; leaving them would let the
        # `git add -A` below commit a half-written generated file, which is worse
        # than a stale one.
        fpaths=$(printf '%s\n' "$REGEN_TABLE" \
          | awk -v c="$cmd" 'BEGIN{FS="\t"} NF>=2 { p=$1; r=$0; sub(/^[^\t]*\t/,"",r); if (r==c) print p }')
        while IFS= read -r fp; do
          [ -n "$fp" ] || continue
          git -C "$WT" checkout -q -- "$fp" >/dev/null 2>&1 || true
        done <<<"$fpaths"
        continue
      fi
      rm -f "$out"
      say "regenerated the union once with: $cmd"
    done <<<"$pend"
    # Only the DECLARED paths are staged. `git add -A` here swept whatever a
    # generator happened to leave next to its output — a cache, a lockfile, a
    # log — into a commit whose PR is gated by verify_cmd and the members'
    # approvals and which nobody reviewed for that file. Its rebase twin has
    # always staged per declared path (mc_regen_generated), and
    # docs/verification-map/regen-on-rebase.md states the invariant for all
    # three entry points; BH-969 made this loop run on EVERY train, so the gap
    # went from unreachable to once per train per project. Pinned by R9a.
    while IFS= read -r rp; do
      [ -n "$rp" ] || continue
      git -C "$WT" add -A -- "$rp" >/dev/null 2>&1 || true
    done <<<"$(printf '%s\n' "$REGEN_TABLE" | cut -f1 | awk 'NF && !seen[$0]++')"
    if ! git -C "$WT" diff --cached --quiet; then
      git -C "$WT" -c user.name="${MC_GIT_NAME:-$HARNESS_MERGE_GIT_NAME}" -c user.email="${MC_GIT_EMAIL:-$HARNESS_GIT_EMAIL}" \
        -c commit.gpgsign=false commit -q -m "batch: regenerate the repo's generated files over the union" >/dev/null 2>&1 \
        || { say "the regenerated union would not commit — abandoning this batch"; union_cleanup; return 1; }
    fi
  fi
  UNION_MEMBERS="$kept"
  return 0
}

union_cleanup() {
  [ -n "$WT" ] || return 0
  git -C "$REPO" worktree remove -f "$WT" >/dev/null 2>&1
  rm -rf "$WT"; WT=""
}
# A worktree left behind is a repo that slowly fills with them, and a credential
# helper left behind is a temp file per tick. Both go on EVERY exit, including
# the ones nobody planned.
trap 'union_cleanup; rm -f "${EXCL_FILE:-}" "${REGEN_FILE:-}" 2>/dev/null; [ -n "${SETDIR:-}" ] && rm -rf "$SETDIR" 2>/dev/null; mc_git_auth_clear >/dev/null 2>&1 || true' EXIT

# verify_union — the repo's Verification Contract, run ONCE over the union.
#   node_modules is borrowed from the hub clone exactly as mc_rebase borrows it.
#   The output goes to a file and only its TAIL reaches the log on a failure: a
#   whole test run appended to a lane log on every red union is how a log stops
#   being read, and a red union with nothing said about WHY is unactionable.
verify_union() {
  local out rc
  [ -d "$REPO/node_modules" ] && [ ! -e "$WT/node_modules" ] && ln -s "$REPO/node_modules" "$WT/node_modules" 2>/dev/null
  out=$(mktemp "${TMPDIR:-/tmp}/batch-verify-XXXX")
  # 9>&- for the reason the regenerate closes it: a suite that leaves a server
  # or a watcher running must not inherit the lane's dedupe lock.
  ( cd "$WT" && eval "$VERIFY" ) >"$out" 2>&1 9>&-; rc=$?
  [ "$rc" = 0 ] || say "the verification contract ($VERIFY) failed on the union: $(tail -5 "$out" | tr '\n' ' ' | cut -c1-400)"
  rm -f "$out"
  return "$rc"
}

# ---------------------------------------------------------------------------
# MEMBER HEADS AND THE TRAIN PR BODY (BH-5804). Train #5674 was BLOCKed because
# its body named #5535, and #5535 was not in the union: its head moved after its
# approval, the re-form dropped it, and nothing rewrote the body. The first
# build had the same gap: nothing re-read a member's head between the candidate
# loop and build_union, and the partition and the other groups' verification
# runs sit in between.
# ---------------------------------------------------------------------------

# train_drop_row <num> <branch> <approved> <now> <reason> — one member the train
#   left out, for the PR body's "Dropped from this train" section.
train_drop_row() {
  DROPPED_ROWS="${DROPPED_ROWS}${1}"$'\t'"${2:--}"$'\t'"${3:--}"$'\t'"${4:--}"$'\t'"${5:--}"$'\n'
}

# train_heads_current <num...> — fetch each member's branch and compare its tip
#   with the sha its APPROVE is bound to, just before the union is built. Sets
#   TRAIN_CURRENT to the members still at that sha.
#   A MOVED member is dropped: released, logged with both shas, given a body
#   row, and NOT marked red or excluded. Its verdict is bound to the old head,
#   so the conductor sends it to re-review, and the candidate gate
#   (REVIEWED == HEAD) keeps it out of every train until a new APPROVE exists.
#   A branch that cannot be fetched says nothing about the head: deferred.
train_heads_current() {
  local n ap now
  TRAIN_CURRENT=()
  for n in "$@"; do
    [ -n "$n" ] || continue
    ap="${APPROVEDOF[$n]:-${HEADOF[$n]}}"
    if ! git -C "$REPO" -c credential.helper= fetch -q origin "${BRANCHOF[$n]}" >/dev/null 2>&1; then
      defer_members "${BRANCHOF[$n]} could not be fetched to check its head just before the build" "$n"
      continue
    fi
    now=$(git -C "$REPO" rev-parse "origin/${BRANCHOF[$n]}" 2>/dev/null)
    if [ "$now" != "$ap" ]; then
      mc_batch_release "$SLUG" "$n"
      train_drop_row "$n" "${BRANCHOF[$n]}" "$ap" "${now:--}" "head moved after approval; back to review"
      say "#$n dropped from the train before the build, head moved after approval: approved at ${ap:0:12}, head now ${now:0:12}. Its APPROVE does not bind to the new head, so it goes back to review there; it is NOT marked red, and the rest of the train goes ahead"
      continue
    fi
    TRAIN_CURRENT+=("$n")
  done
  return 0
}

# train_union_left_out <num...> — a body row for each member build_union was
#   given and did not merge (a source conflict with a sibling or the base).
train_union_left_out() {
  local n
  for n in "$@"; do
    case " $UNION_MEMBERS " in *" $n "*) continue ;; esac
    train_drop_row "$n" "${BRANCHOF[$n]}" "${APPROVEDOF[$n]:-${HEADOF[$n]}}" "${HEADOF[$n]}" "would not merge onto the base"
  done
}

# train_body_write <body-file> <branch> <num...> — the train PR body, without
#   trailers. One line per member with the sha its APPROVE names and the sha the
#   union merged; "included" is proved against $WT with merge-base, never
#   assumed. A member that fails that proof is listed as dropped instead (it
#   must not happen). DROPPED_ROWS become the "Dropped from this train" section,
#   which is absent when nothing was dropped. Sets TRAIN_BODY_IN to the members
#   the body lists as included, for the Harness-Train trailer.
train_body_write() {
  local bf="$1" br="$2" n ap lines="" drops="" dn db da dw dr; shift 2
  local rows="$DROPPED_ROWS"
  TRAIN_BODY_IN=()
  for n in "$@"; do
    ap="${APPROVEDOF[$n]:-${HEADOF[$n]}}"
    if [ -n "$WT" ] && git -C "$WT" merge-base --is-ancestor "${HEADOF[$n]}" HEAD >/dev/null 2>&1; then
      lines="$lines- #$n (\`${BRANCHOF[$n]}\`): approved at \`${ap:0:12}\`, included at \`${HEADOF[$n]:0:12}\`"$'\n'
      TRAIN_BODY_IN+=("$n")
    else
      rows="$rows$n"$'\t'"${BRANCHOF[$n]:--}"$'\t'"${ap:--}"$'\t'"${HEADOF[$n]:--}"$'\t'"not an ancestor of the union"$'\n'
    fi
  done
  while IFS=$'\t' read -r dn db da dw dr; do
    [ -n "$dn" ] || continue
    drops="$drops- #$dn (\`$db\`): approved at \`${da:0:12}\`, head now \`${dw:0:12}\` — not included, $dr"$'\n'
  done <<<"$rows"
  {
    printf 'Merge-time batch of %s approved PRs whose only conflicts were in files this repo declares generated or union-mergeable.\n\n' "${#TRAIN_BODY_IN[@]}"
    printf 'Members, each of which was reviewed on its own and carries its own head-bound APPROVE:\n\n%s' "$lines"
    [ -n "$drops" ] && printf '\nDropped from this train. These are not in the union and are not closed when it lands:\n\n%s' "$drops"
    printf '\nOne ticket, one PR, one review, always. Batching is a merge-time optimization, never a review-time one: this branch was not reviewed and is not a change. It is `%s` with each member merged into it, the repo'"'"'s generated files regenerated once over the result, and the repo'"'"'s verification contract run once over that.\n\n' "$PBASE"
    printf 'When this lands, every member PR above is closed against this train'"'"'s merge sha, gets its ledger row (`pr_merged`, `merged_via=batch:<sha>`) and gets its ticket close-out.\n'
  } > "$bf"
}

# train_body_patch <record> <train-url> <body-file> — write the body to the
#   train PR (REST). Success clears body_stale; a refusal keeps the body text in
#   the record, sets body_stale=true, and settle_train retries next pass. A
#   stale body only makes the lead review block the train, so it fails safe.
train_body_patch() {
  local f="$1" turl="$2" bf="$3"
  if gh_rest PATCH "repos/$SLUG/pulls/${turl##*/}" -F "body=@$bf" >/dev/null 2>&1; then
    jq -c '.body_stale=false | del(.body_pending)' "$f" > "$f.tmp" 2>/dev/null && mv -f "$f.tmp" "$f"
    say "train $turl: the PR body now lists the members of the re-formed union"
    return 0
  fi
  jq -c --rawfile b "$bf" '.body_stale=true | .body_pending=$b' "$f" > "$f.tmp" 2>/dev/null && mv -f "$f.tmp" "$f"
  say "train $turl: the PR body could not be written (HTTP ${GH_REST_STATUS:-000}); the record is marked body_stale and the next pass retries"
  return 1
}

# train_body_retry <record> <train-url> — one retry of a body a re-form could
#   not write, from the text the record kept.
train_body_retry() {
  local f="$1" turl="$2" bf
  bf=$(mktemp "${TMPDIR:-/tmp}/batch-body-XXXX") || return 1
  if ! jq -er '.body_pending // empty' "$f" > "$bf" 2>/dev/null; then
    rm -f "$bf"
    say "train $turl is marked body_stale but its record keeps no body text, so nothing can be retried; the next re-form writes the body"
    return 1
  fi
  train_body_patch "$f" "$turl" "$bf"
  rm -f "$bf"
}

# ---------------------------------------------------------------------------
# attempt <depth> <num...> — build, verify, land. A red union buys a binary
#   split, at most BATCH_SPLIT_MAX levels of it; a half that stays red, or a
#   half that has fallen below two members, is HANDED BACK: nothing was pushed
#   to any of its PRs, so the ordinary conductor path (and bin/blocked-resolver.sh
#   behind it) owns them again exactly as it did before this lane looked at them.
#   The hand-back is recorded per (PR, head) so the next tick does not rebuild
#   the same red union for ever — a push to the PR clears it by construction.
# ---------------------------------------------------------------------------
attempt() {
  local depth="$1"; shift
  local -a mem=("$@")
  local br half i
  # AT MOST ONE TRAIN IN FLIGHT PER PROJECT, AND THEREFORE ONE PER PASS. A red
  # union that splits into two GREEN halves used to push BOTH: two branches cut
  # from the same base, each regenerating the same registry, so the second is
  # permanently dirty the moment the first lands — and the in-flight guard then
  # blocks every future batch for that project for ever. The second half is not
  # red and has done nothing wrong, so it is DEFERRED, not handed back red: it
  # is simply the next pass's candidate set.
  # ...AND ONE PER GROUP (BH-1270). GROUP_PUSHED is the guard that used to be
  # TRAIN_PUSHED: a red union that splits into two GREEN halves still pushes
  # only the first, because both halves were cut from the same base and each
  # regenerates the same registry, so the second is permanently dirty the moment
  # the first lands. TRAIN_SLOTS is the SECOND, new bound — the whole pass may
  # not put more trains in flight than the CI pool can run at once.
  if [ "$GROUP_PUSHED" = 1 ]; then
    defer_members "a train from this group is already in flight; this half is the next pass's candidate set" "${mem[@]}"
    return 1
  fi
  if [ "$TRAINS_PUSHED" -ge "$TRAIN_SLOTS" ]; then
    defer_members "this pass has already filled its $TRAIN_SLOTS train slot(s) (TRAIN_PARALLEL=$TRAIN_PARALLEL, cap $PARALLEL_CAP); this group is the next pass's candidate set" "${mem[@]}"
    return 1
  fi
  # EVERY MEMBER'S HEAD, AGAIN, JUST BEFORE THE BUILD (BH-5804). The candidate
  # loop checked it, but minutes of partition and other groups' verification
  # runs lie between that check and this build.
  DROPPED_ROWS=""
  train_heads_current "${mem[@]}"
  if [ "${#TRAIN_CURRENT[@]}" -lt "${#mem[@]}" ] && [ "${#TRAIN_CURRENT[@]}" -lt "$TRAIN_MIN" ]; then
    if [ "${#TRAIN_CURRENT[@]}" -gt 0 ]; then
      defer_members "members of its group moved or could not be checked just before the build, and fewer than $TRAIN_MIN remain" "${TRAIN_CURRENT[@]}"
    else
      say "no train is built for [${mem[*]}]: no member is still at its approved head just before the build"
    fi
    return 1
  fi
  mem=(${TRAIN_CURRENT+"${TRAIN_CURRENT[@]}"})
  if [ "${#mem[@]}" -lt "$TRAIN_MIN" ]; then hand_back "a train needs $TRAIN_MIN member(s)" "${mem[@]}"; return 1; fi
  batch_branch_name; br="$BRANCH_NAME"
  build_union "$br" "${mem[@]}" || { hand_back "the union could not be built" "${mem[@]}"; return 1; }
  train_union_left_out "${mem[@]}"
  # shellcheck disable=SC2086
  set -- $UNION_MEMBERS
  if [ "$#" -lt "$TRAIN_MIN" ]; then
    union_cleanup
    hand_back "too many members dropped out of the union to make it a train (needs $TRAIN_MIN)" "${mem[@]}"
    return 1
  fi
  local -a in=("$@")
  if verify_union; then
    land_union "$br" "${in[@]}" && { TRAINS_PUSHED=$((TRAINS_PUSHED + 1)); GROUP_PUSHED=1; }
    union_cleanup
    return 0
  fi
  union_cleanup
  say "the union $br is RED against the repo's verification contract with ${#in[@]} members (${in[*]}) — depth $depth of $SPLIT_MAX"
  if [ "$depth" -ge "$SPLIT_MAX" ]; then
    hand_back "the union stayed red after $SPLIT_MAX splits" "${in[@]}"
    return 1
  fi
  # A SINGLE-MEMBER UNION HAS NOTHING TO SPLIT (BH-1269). With BATCH_TRAIN_MIN=1
  # a train of one is ordinary, and halving it would hand one empty set and one
  # identical set back to attempt(). The member's own PR is where a red belongs.
  if [ "${#in[@]}" -lt 2 ]; then
    hand_back "the union is red with one member, so the member itself is red — there is nothing to split" "${in[@]}"
    return 1
  fi
  # The FIRST half takes the extra member on an odd count. The members are in PR
  # age order, so the older half is the bigger one — and on a set of three where
  # the newest PR is the red one, that is the difference between two landing and
  # one landing.
  half=$(( ( ${#in[@]} + 1 ) / 2 ))
  local -a a=() b=()
  for (( i = 0; i < ${#in[@]}; i++ )); do
    if [ "$i" -lt "$half" ]; then a+=("${in[$i]}"); else b+=("${in[$i]}"); fi
  done
  say "binary split of the red union: [${a[*]}] and [${b[*]}]"
  attempt $((depth + 1)) "${a[@]}"
  attempt $((depth + 1)) "${b[@]}"
  return 0
}

# hand_back <why> <num...> — the union these PRs were in went RED. They go back
#   to the ordinary path AND are recorded per (PR, head) so the next tick does
#   not rebuild the same red union for ever; a push to the PR clears it.
hand_back() {
  local why="$1"; shift
  local n
  for n in "$@"; do
    [ -n "$n" ] || continue
    mc_batch_release "$SLUG" "$n"
    mkdir -p "$STATE" 2>/dev/null
    echo "$n ${HEADOF[$n]}" >> "$STATE/red.txt"
    lt_put batch_member "$SLUG#$n@${HEADOF[$n]}" red
    say "#$n goes back to the ordinary conductor + bin/blocked-resolver.sh path — $why; nothing was pushed to its branch and its approval is untouched"
  done
}

# defer_members <why> <num...> — released WITHOUT the red mark. These PRs are
#   not red and nothing is wrong with them: the pass simply ran out of room (a
#   train is already in flight) or an infrastructure step failed (a refused
#   push, a train PR that would not open). Marking those red would exclude a
#   perfectly good PR from every future batch until its head moved, which is
#   exactly what the branch-name collision used to do to two GREEN members.
defer_members() {
  local why="$1"; shift
  local n
  for n in "$@"; do
    [ -n "$n" ] || continue
    mc_batch_release "$SLUG" "$n"
    say "#$n deferred to the next pass — $why; nothing was pushed to its branch, its approval is untouched and it is NOT marked red"
  done
}

# br_train_identity — rc 0 when GH_TOKEN is now this repo's GitHub App
#   INSTALLATION token, the only identity a train PR may be opened under
#   (BH-1606). gh_app_only_for (the App-auth lib that merge-conductor-lib.sh
#   loads) answers rc 0 only for an installation token, never for the PAT a
#   failed mint hands back; a box without it cannot mint, so it refuses. The
#   rest of this lane's gh calls keep their identity (its raw-pat marker).
#   ARMED FOR ONE CALL (#1624 round 3): br_train_release puts the lane's own
#   identity back the moment that call returns, so nothing after it runs as
#   the App — the raw-pat marker above stays true for the rest of the pass.
#   AND A TOKEN THAT DIES BEFORE THE CREATE IS NO TOKEN (BH-1630, #1624 round
#   4). gh_app_only_for reads only the `ghs_` prefix, so an installation token
#   about to expire, or one this box's cache does not hold for $SLUG, passed it
#   and failed at `gh pr create` — after the union had been pushed. So the mint
#   is asked for TRAIN_TOKEN_MIN_LIFE (gh_app_premint: a shorter cached token is
#   re-minted), and gh_app_expires_at reads the cached expiry back: no expiry for
#   this repo, or one inside the knob, is a refusal. BR_TRAIN_WHY carries the
#   reason out. Both go through the App-auth lib, so this file never names the
#   minter itself and its raw-pat marker keeps its meaning.
br_train_identity() {
  local exp left
  BR_TRAIN_WHY="no GitHub App installation token could be minted for $SLUG"
  command -v gh_app_only_for >/dev/null 2>&1 || return 1
  command -v gh_app_premint >/dev/null 2>&1 && gh_app_premint "$SLUG" "$TRAIN_TOKEN_MIN_LIFE"
  gh_app_only_for "$SLUG" || return 1
  exp=""
  command -v gh_app_expires_at >/dev/null 2>&1 && { exp=$(gh_app_expires_at "$SLUG") || exp=""; }
  left=""
  if [ -n "$exp" ] && exp=$(date -u -d "$exp" +%s 2>/dev/null); then left=$((exp - $(date -u +%s))); fi
  if [ -z "$left" ]; then
    BR_TRAIN_WHY="the App token's expiry for $SLUG could not be read from this box's token cache, so it cannot be shown to outlive the push and the create"
  elif [ "$left" -le 0 ]; then
    BR_TRAIN_WHY="the App token for $SLUG has expired"
  elif [ "$left" -lt "$TRAIN_TOKEN_MIN_LIFE" ]; then
    BR_TRAIN_WHY="the App token for $SLUG expires in ${left}s, under BATCH_TOKEN_MIN_LIFE=${TRAIN_TOKEN_MIN_LIFE}s"
  else
    return 0
  fi
  gh_app_only_release
  return 1
}
br_train_release() { command -v gh_app_only_release >/dev/null 2>&1 && gh_app_only_release; return 0; }

# br_train_refuse <where> — the one line and the one alert for "this box cannot
#   open a train as the App". The alert id is per repo; br_train_opened resolves
#   it the first time a train does open, so it is never left open for ever.
br_train_refuse() {
  say "no train is opened $1: ${BR_TRAIN_WHY:-no GitHub App installation token could be minted for $SLUG}, and a train is never opened on the lead's PAT (it would be fenced as a lead PR) — nothing pushed, the members stay on the ordinary merge path"
  [ -x "$H/bin/lane-alert.sh" ] && "$H/bin/lane-alert.sh" --severity warn \
    --id "batch-train-no-app-token:$SLUG" batch-resolve \
    "$SLUG: merge trains are NOT being opened on $(hostname 2>/dev/null) because no usable GitHub App installation token is in hand: ${BR_TRAIN_WHY:-no token could be minted} (check the box's GitHub App env and token minter). A train on the lead's PAT would be fenced as a lead PR, so the lane refuses rather than falling back; approved PRs merge one by one meanwhile." >/dev/null 2>&1
  return 0
}
br_train_opened() {
  [ -x "$H/bin/lane-alert.sh" ] && "$H/bin/lane-alert.sh" --resolve \
    --id "batch-train-no-app-token:$SLUG" batch-resolve \
    "$SLUG: a merge train opened as the App — the no-App-token condition is over" >/dev/null 2>&1
  return 0
}

# land_union <branch> <num...> — push, open the train PR, enqueue it once,
#   record the members. NOTHING here merges: the train enters the same queue
#   every other landing does.
land_union() {
  local br="$1"; shift
  local -a in=("$@")
  local bf turl tnum n perr cerr QOUT QRC
  # >>> train identity (BH-1606)
  # A TRAIN OPENS ONLY AS THE APP, NEVER AS THE LEAD'S PAT. Every merge lane
  # fences a lead-authored PR until a lead verdict row stands on its head (the
  # train's shape is never a clearance — #1624 round 2), so a train opened on
  # the PAT would sit held with every member behind it. The pass already asked
  # at its top (before any union was built); asked AGAIN here, before the push,
  # the record and the holds, because a verification run is minutes long: a
  # refusal leaves nothing on the remote and the members go back to the
  # ordinary path, not marked red. The token is released at once — it is armed
  # again for the `gh pr create` alone, below.
  if br_train_identity; then br_train_release; else
    br_train_refuse "for the union $br"
    defer_members "no App token to open the train as" "${in[@]}"
    return 1
  fi
  # <<< train identity
  # The sha CI runs once over. Read BEFORE the push, because $WT is removed by
  # the caller the moment this returns and the D1 row wants it on every write.
  UNION_SHA=$(git -C "$WT" rev-parse HEAD 2>/dev/null)
  if ! perr=$(git -C "$WT" -c credential.helper= push -q "$REMOTE" "HEAD:refs/heads/$br" 2>&1 >/dev/null); then
    say "the union $br verified green but the push was REFUSED — $(head -1 <<<"${perr:-no stderr}" | sed 's/github_pat_[A-Za-z0-9_]*/<redacted>/g') — nothing landed"
    defer_members "the union branch could not be pushed" "${in[@]}"
    return 1
  fi
  bf=$(mktemp "${TMPDIR:-/tmp}/batch-body-XXXX")
  train_body_write "$bf" "$br" "${in[@]}"
  # THE RECORD AND THE HOLDS ARE WRITTEN BEFORE THE PR IS OPENED, and that
  # ordering is the whole point. A crash between `gh pr create` and the record
  # leaves a train PR on a client's repo that nothing on this box knows about:
  # nothing settles it, nothing closes it, and its members sit unheld under a
  # branch that is about to merge. Written first, the worst case is a `creating`
  # record with no url, which reconcile_creating below adopts or cleans up.
  write_train_state "$br" "" creating "${in[@]}"
  for n in "${in[@]}"; do mc_batch_hold "$SLUG" "$n" "${HEADOF[$n]}" "creating:$br"; done
  # THE APP TOKEN IS ARMED FOR THIS ONE CALL (BH-1606) and released right
  # after it. A mint that fails here, minutes after the check above, is the
  # same outcome as a create that fails: the `creating` record stays for the
  # reconcile and the members are deferred.
  # >>> pr trailers (BH-3987)
  # THE TRAIN SAYS IT IS A TRAIN: `train:<branch>` as the job, no one ticket,
  # and every member on the Harness-Train line. A failed write is one line and
  # the train opens untrailered.
  [ -r "${H:-}/bin/lib/pr-trailers.sh" ] && . "$H/bin/lib/pr-trailers.sh"
  if command -v pr_trailers_apply >/dev/null 2>&1; then
    pr_trailers_apply "$bf" "train:$br" none "$br $(printf '#%s ' "${in[@]}")" \
      || say "pr trailers: could not write $bf — the train PR opens without trailers"
  fi
  turl=""
  if br_train_identity; then
    turl=$(gh pr create -R "$SLUG" --base "$PBASE" --head "$br" --title "batch($PROJECT): land ${#in[@]} approved siblings as one train" --body-file "$bf" 2>"$bf.err" | grep -oE 'https://github.com/[^ ]+/pull/[0-9]+' | head -1)   # gh-guard-allow: a write, not a decision read
    br_train_release
  else
    printf '%s\n' "${BR_TRAIN_WHY:-no App installation token could be minted for the create}" > "$bf.err"
  fi
  # <<< pr trailers
  cerr=$(head -1 "$bf.err" 2>/dev/null); rm -f "$bf" "$bf.err"
  [ -n "$turl" ] && br_train_opened
  if [ -z "$turl" ]; then
    # The record STAYS, as `creating`: the branch is on the remote and a PR may
    # or may not exist for it, and only the reconcile can tell. The members are
    # released so the ordinary path owns them meanwhile.
    say "the union $br was pushed but the train PR could not be opened — ${cerr:-gh produced no PR url} — the next pass reconciles the branch"
    defer_members "the train PR could not be opened" "${in[@]}"
    return 1
  fi
  tnum="${turl##*/}"
  write_train_state "$br" "$turl" open "${in[@]}"
  for n in "${in[@]}"; do mc_batch_hold "$SLUG" "$n" "${HEADOF[$n]}" "$turl"; done
  # ONE train, ONE queue entry, through the path every other landing takes. The
  # ledger row is written either way so `merge_queue_list` shows the train.
  type merge_queue_put >/dev/null 2>&1 \
    && merge_queue_put "$PROJECT" "$tnum" "$SLUG" "batch train of ${#in[@]} approved PRs: ${in[*]}" >/dev/null 2>&1 || true
  if [ "$QPROV" = none ]; then
    # THE BOX QUEUE IS FED ONLY WHERE IT IS THE LANDER. On a repo behind Mergify
    # or GitHub's native queue, an entry here would let bin/merge-queue.sh
    # squash the train directly and bypass the batch verification the queue
    # exists for — the one thing a merge-time batch must never do.
    mkdir -p "$H/state/merge-queue/$PROJECT" 2>/dev/null
    touch "$H/state/merge-queue/$PROJECT/$tnum" 2>/dev/null
  else
    # rc 4 (BH-3806): BH-3683 withholds the lead-verdict status on the train's
    # head, so nothing was labelled or asked; the refusal names the command.
    QOUT=$(mc_enqueue "$turl" "$UNION_SHA" 2>/dev/null); QRC=$?
    case "$QRC" in
      0) say "train $turl enqueued in the $QPROV queue" ;;
      4) say "train $turl was NOT enqueued: $QOUT" ;;
      *) say "train $turl could NOT be enqueued in the $QPROV queue — it will sit until its age budget abandons it; check the queue config (docs/MERGIFY.md)" ;;
    esac
  fi
  say "train $turl pushed as $br with ${#in[@]} members (${in[*]}) — one CI run, one queue entry; the members are held until it lands"
  return 0
}

# write_train_state <branch> <train-url-or-empty> <status> <num...>
#   The record every later pass reads. `created_at` is what the age budget ages,
#   and it is set ONCE (a rewrite from creating to open keeps the original) so a
#   train cannot postpone its own deadline.
write_train_state() {
  local br="$1" turl="$2" st="$3"; shift 3
  local f created n reforms
  f="$STATE/train-${br##*/}.json"
  mkdir -p "$STATE" 2>/dev/null
  created=$(jq -r '.created_at // empty' "$f" 2>/dev/null)
  case "$created" in ''|null) created=$(date -u +%s) ;; esac
  # The re-form counter survives a rewrite for the same reason created_at does:
  # a train must not be able to reset its own budget by changing status.
  reforms=$(jq -r '.reform_n // empty' "$f" 2>/dev/null)
  case "$reforms" in ''|null|*[!0-9]*) reforms=0 ;; esac
  jq -nc --arg b "$br" --arg u "$turl" --arg p "$PROJECT" --arg s "$st" --argjson c "$created" \
     --arg us "${UNION_SHA:-}" --arg g "${TRAIN_GROUP:-0}" --argjson rn "$reforms" \
     --argjson m "$(for n in "$@"; do jq -nc --arg n "$n" --arg u "${URLOF[$n]}" --arg br "${BRANCHOF[$n]}" --arg h "${HEADOF[$n]}" --arg a "${APPROVEDOF[$n]:-${HEADOF[$n]}}" '{num:$n,url:$u,branch:$br,head:$h,approved:$a}'; done | jq -sc '.')" \
     '{project:$p,train_branch:$b,train_url:$u,status:$s,created_at:$c,union_sha:$us,
       train_group:$g,reform_n:$rn,members:$m}' > "$f.tmp" \
    && mv -f "$f.tmp" "$f"
  train_row "$f" "$st"
}

# ===========================================================================
# The pass itself.
# ===========================================================================
settle_trains
if [ "$GATED" = 1 ]; then
  say "$GATE — in-flight trains were settled, no new batch"
  exit 0
fi
# N TRAINS AT A TIME PER PROJECT, ON DISJOINT FILE SETS (BH-1270). A second
# union built while the first is in flight IS cut from a base that does not
# contain it — the pre-BH-1270 objection is true and unchanged. What makes it
# safe is not waiting but DISJOINTNESS: two unions that share no planned file
# and no module directory cannot meet, whichever lands first, and the one that
# lands second is re-formed on the new tip (reform_train) rather than re-merged
# or re-reviewed. So the in-flight trains are COUNTED here rather than being a
# full stop, and what they hold is subtracted from this pass's candidates below.
INFLIGHT=0
INFLIGHT_RECS=()
for f in "$STATE"/train-*.json; do
  [ -f "$f" ] || continue
  case "$(jq -r '.status // "open"' "$f" 2>/dev/null)" in open|creating) ;; *) continue ;; esac
  INFLIGHT=$((INFLIGHT + 1))
  INFLIGHT_RECS+=("$f")
done
TRAIN_SLOTS=$(( PARALLEL_CAP - INFLIGHT ))
if [ "$TRAIN_SLOTS" -le 0 ]; then
  say "$INFLIGHT train(s) already in flight and this lane may have $PARALLEL_CAP at once (TRAIN_PARALLEL=$TRAIN_PARALLEL, declared CI pool ${CI_RUNNERS:-0} runner(s) / $CI_SHARDS job(s) per run) — no new batch until one lands"
  exit 0
fi

repo_ready || exit 0
REGEN_TABLE=$(regen_table)
if [ -z "$REGEN_TABLE" ]; then
  # A repo that never declared a table is OFF by design and says so quietly.
  # A repo that ships a `## Generated files` HEADING and still produced zero
  # rows is a different animal: the declaration is there and the parser could
  # not read it, which is how this lane switches itself off without anybody
  # noticing (BH-1175 — the table's home moved when the generated README left
  # git, and a parser left pointing at the old home reads an absent path as an
  # empty table). That one ALERTS.
  if regen_homes_declare_heading; then
    say "a '## Generated files' heading is declared in $SLUG but the table parsed to ZERO rows — batch-resolve would switch itself off silently. Check the table in docs/verification-map/index/tail.md (or AGENT_ARCHITECTURE.md): the parser reads the first home that HAS the heading."
    "$H/bin/lane-alert.sh" batch-resolve "$SLUG: a generated-files heading is declared but the regenerate table parsed to zero rows — the batch merge train is OFF. The table's home is docs/verification-map/index/tail.md (BH-1175)." >/dev/null 2>&1 || true
  else
    say "no regenerate table in AGENT_ARCHITECTURE.md, docs/verification-map/README.md or docs/verification-map/index/tail.md — batch-resolve is off for $SLUG (without it every conflict is a source conflict)"
  fi
  mc_git_auth_clear
  exit 0
fi
UNION_PATHS=$(union_paths)
# THE PATHS A CARRY IGNORES (BH-1269). The repo's declared generated files are a
# function of the tree and are rebuilt on both sides of a rebase, so a change in
# one of them is not a change to the PATCH — and a carry that counted them would
# refuse every rebase of a repo that commits an index, which is the whole tail
# this lane exists for. Everything else is part of the patch's identity.
EXCL_FILE=$(mktemp "${TMPDIR:-/tmp}/batch-excl-XXXX") || EXCL_FILE=""
[ -n "$EXCL_FILE" ] && printf '%s\n' "$REGEN_TABLE" | cut -f1 | awk 'NF && !seen[$0]++' > "$EXCL_FILE"
# ...and the WHOLE table, for the render check a pure rebase owes. Excluding a
# generated file from the carry identity is right (it is a function of the
# tree); pushing a rebase whose union-merged render no longer BUILDS is not.
REGEN_FILE=$(mktemp "${TMPDIR:-/tmp}/batch-regen-XXXX") || REGEN_FILE=""
[ -n "$REGEN_FILE" ] && printf '%s\n' "$REGEN_TABLE" > "$REGEN_FILE"
# WHERE EVERY CANDIDATE'S PLANNED-FILE SET LIVES for this pass (BH-1270). One
# `<num>.files` and one `<num>.mods` per candidate, plus the union of what the
# in-flight trains already hold. Removed on every exit path with the two files
# above — a temp directory per */5 tick is a disk that fills in a week.
SETDIR=$(mktemp -d "${TMPDIR:-/tmp}/batch-sets-XXXX") || SETDIR=""
VERIFY=$(verify_cmd)
QPROV=$(mc_queue_provider "$SLUG")
# THE LANDER CHECK, BEFORE ANY WORK. On a repo with no provider queue the box
# merge queue is what lands a train, and it stands down entirely while
# flags/conductor-owns-merges is on — while the conductor ignores the train by
# design (it is not a harness PR: no ticket branch, no build record). Building a
# train nothing can land would leave an orphan PR on a client's repo.
if [ "$QPROV" = none ] && flag_on conductor-owns-merges; then
  say "$SLUG has no provider merge queue and flags/conductor-owns-merges is on, so nothing would land a train — no batch built"
  mc_git_auth_clear
  exit 0
fi

CONFLICTS_SEEN=0
# `labels` rides the list (BH-370.2): the hotfix migration-proof gate below needs
# the label csv, and asking for it per PR would be one extra API call each.
LIST=$(harness_pr_list "$SLUG" open \
  number,url,headRefOid,headRefName,baseRefName,isDraft,mergeStateStatus,mergeable,state,createdAt,labels,author 100 2>/dev/null)
if [ -z "$LIST" ]; then
  say "the open PR list could not be read this pass — nothing done"
  mc_git_auth_clear; exit 0
fi
# The label csv is APPENDED, never inserted, so the positional read below keeps
# every existing field where it was. It emits `-` rather than an empty string for
# a PR with no labels: TAB is an IFS whitespace character, so an empty column in
# the middle of a row slides every later field one to the left.
mapfile -t ROWS < <(printf '%s' "$LIST" | jq -r '
  sort_by(.createdAt // "") | .[] |
  [ .number, .url, .headRefOid, .headRefName, ((.baseRefName // "-")), ((.isDraft|tostring)),
    ((.mergeStateStatus // "UNKNOWN")),
    ((((.labels // []) | map(.name) | join(",")) // "") | if . == "" then "-" else . end),
    ((.author.login // "") | if . == "" then "-" else . end) ] | @tsv' 2>/dev/null)

# >>> block gate
# bg_batch_hold <num> <url> <head> <branch> <record> — rc 0 when a human BLOCK
# on the thread keeps this PR out of the train (BH-762).
#
# WHY THIS LANE NEEDS ITS OWN CALL. A member never reaches the conductor's READY
# arm while a train carrying it is in flight, and the train is a NEW PR whose own
# thread is empty — so without this the three gates above (a head-bound APPROVE,
# a tier, a mergeable pair) are the whole of what puts somebody's code on main,
# and not one of them has ever read a comment. That is the incident shape through
# a second door: reviewer posts BLOCK on #41, the next conductor tick spawns this
# lane, #41 rides a union branch into the queue, and the block is never read.
#
# THE REFUSAL IS THE SAME REFUSAL. One log line naming the comment, one comment
# on the PR saying so, and the PR simply stays a non-candidate — no exclusion
# file, no abandoned row: the moment a newer commit lands or the author clears
# it, the next pass batches it like any other approved sibling.
bg_batch_hold() {
  local num="$1" url="$2" head="$3" br="$4" rec="$5" issue="" out rc
  command -v bg_scan >/dev/null 2>&1 || return 1
  [ "$("$H/bin/fleet-conf.sh" "$PROJECT" board_prefix 2>/dev/null)" = "-" ] \
    && issue=$(mc_issue_of "$rec" "$br")
  out=$(bg_scan "$SLUG" "$num" "$url" "$head" "$issue"); rc=$?
  [ "$rc" = 0 ] && return 1
  if ! bg_enforce; then
    say "#$num block gate WARN-ONLY (BLOCK_GATE_ENFORCE=0): $(bg_reason "$rc" "$out" "$head") — batching it as this lane would have before the gate"
    return 1
  fi
  if [ "$rc" = 1 ]; then
    say "#$num MERGE_REFUSED block-gate: $(bg_why "$out" "$head") — not batched, and it rides the next train once a newer commit lands or that author clears it"
    bg_refuse "$SLUG" "$num" "$url" "$head" "$out" batch-resolve \
      || say "#$num block gate could not post the refusal comment — it is out of the train either way and the next pass retries the post"
  else
    say "#$num not batched this pass: the block gate could not read $out — nothing written, the next pass tries again"
  fi
  return 0
}
# <<< block gate

CAND=()
# >>> batch candidates
for ROW in "${ROWS[@]:-}"; do
  [ -n "$ROW" ] || continue
  IFS=$'\t' read -r NUM URL HEAD BR BASE DRAFT MSTATE RAWLBL AUTHOR <<<"$ROW"
  [ -n "$NUM" ] || continue
  [ "$DRAFT" = true ] && continue
  [ "$BASE" = "$PBASE" ] || continue
  # Landed, red, or a member of a train that ended without merging. Same
  # (PR, head) key for all three: the PR is a candidate again the moment it is
  # pushed to, and never before.
  member_excluded "$NUM" "$HEAD" && continue
  # Parked because its OWN CI is red at this head and a rebase is no longer on
  # the table (BH-1269). Same (PR, head) key as every other exclusion: a push
  # makes it a candidate again, and nothing else does.
  grep -qxF "$NUM $HEAD" "$STATE/own-red.txt" 2>/dev/null && continue
  # ALREADY RIDING A TRAIN (BH-1270). Before parallel trains this line could not
  # be reached — the pass stopped dead at the first in-flight train — and the
  # hold was read only by the conductor. Now a pass builds group 2 while group 1
  # is in flight, so this lane has to honour its own hold or it would batch a
  # member into a second union whose base does not contain the first.
  if command -v mc_batch_held >/dev/null 2>&1 \
     && HELDBY=$(mc_batch_held "$SLUG" "$NUM" "$HEAD"); then
    say "#$NUM is already held by the train ${HELDBY:-(unnamed)} — not a candidate for another one"
    continue
  fi
  # AN OPERATOR'S OWN PARK, read live from a file. Tested here, before any
  # network call, so a parked member costs nothing at all.
  if mrt_skip_listed "${SKIPFILE:-}" "$NUM" 2>/dev/null; then
    say "#$NUM is listed in ${SKIPFILE:-train-skip.txt} — not batched this pass (remove the line to put it back; nothing restarts)"
    continue
  fi
  REC=$(mc_record_for "$URL" || true)
  mc_is_harness_pr "$BR" "$REC" || continue
  IFS=$'\t' read -r VERDICT PROV REVIEWED _JOB _HB <<<"$(mc_verdict "$URL" "$REC")"
  # THE THREE GATES THE POLICY RESTS ON. Nothing else may reach a union branch.
  [ "$VERDICT" = APPROVE ] || continue
  [ "$REVIEWED" = "$HEAD" ] || continue
  if mc_prov_held "$PROV" && ! mc_prov_cleared "$SLUG#$NUM" "$HEAD"; then continue; fi
  TIER=""
  if type job_verdict >/dev/null 2>&1; then TIER=$(job_verdict "$URL" 2>/dev/null | cut -f2); fi
  case "$TIER" in ''|'-') TIER=$(sed -nE 's/^TIER:[[:space:]]*([0-9]+).*/\1/p' "$REC/review.md" 2>/dev/null | tail -1) ;; esac
  case "$TIER" in 1|2) ;; *) say "#$NUM is approved but states no mergeable tier — not batched"; continue ;; esac
  # A HOTFIX WHOSE MIGRATION SQL HAS NO ACCEPTED PROOF IS NOT A TRAIN MEMBER
  # (BH-370.2). The train is the THIRD way a PR's commits reach main: the
  # conductor's guard sits in pr_worker, and a train never goes through
  # pr_worker — it is a new PR of its own, with no hotfix label, landed by
  # mc_enqueue or the box queue. Without this line a hotfix held in
  # `WAIT_CI hotfix migration proof missing` would ride into main inside a
  # union branch, which is the exact failure the gate exists to prevent.
  # Same reads, same fail-closed answers as the conductor's copy, and nothing
  # for a PR that is not a labelled hotfix.
  if hotfix_pr_is "$RAWLBL" "$REC"; then
    HP=$(mc_hotfix_proof "$SLUG" "$NUM" "$RAWLBL" "$REC" "$PROJECT")
    case "$HP" in
      ok|n/a) ;;
      *) say "#$NUM is a hotfix whose migration proof reads $HP — not batched; it waits for bin/hotfix-migrate.sh to post a proof for the SQL this head carries"
         continue ;;
    esac
  fi
  # A HELD TICKET, AND A LEAD PR WITH NO LEAD ROW ON THIS HEAD, IS NOT A MEMBER
  # (BH-1630): the same two questions every other merge lane asks, pinned to
  # $HEAD — the sha the fetch below must still find and build_union merges.
  # AHEAD of the block gate, whose clean scan would restart the fence's outage
  # count.
  br_member_fenced "$NUM" "$HEAD" "${AUTHOR:-}" && continue
  # A human's BLOCK outranks the APPROVE this loop just read. Asked here, after
  # the cheap local filters and before any fetch, so only a PR that would really
  # have ridden the train costs the two reads.
  bg_batch_hold "$NUM" "$URL" "$HEAD" "$BR" "$REC" && continue
  git -C "$REPO" -c credential.helper= fetch -q origin "$BR" >/dev/null 2>&1 || {
    say "#$NUM: $BR could not be fetched — not batched this pass"; continue; }
  [ "$(git -C "$REPO" rev-parse "origin/$BR" 2>/dev/null)" = "$HEAD" ] || {
    say "#$NUM: $BR moved between the PR list and the fetch — not batched this pass"; continue; }
  # A MEMBER WHOSE OWN HEAD IS RED SINKS THE WHOLE TRAIN (BH-1269). At 04:08Z on
  # 2026-09-21 one PR's replay-evals job — red on a dead credential, nothing to
  # do with its diff — took ten PRs down with it, and the lane spent a binary
  # split to find out which one. One check-runs read per candidate is cheaper
  # than one CI run per half.
  #
  # AND AN INHERITED RED IS REBASED, NEVER RERUN. When main is red every open
  # PR's own CI is red too: it ran against that main. GitHub PINS a workflow run
  # to the merge commit it was created for, so `rerun-failed-jobs` re-tests the
  # same stale union and comes back red every time (#1238/#1239/#1235, 13:54Z).
  # Only a rebase onto current main makes a fresh merge ref and therefore a
  # fresh run. Once per head, at most BATCH_REBASE_MAX per PR, and the verdict
  # travels only when the patch's own +/- lines are identical — mrt_rebase_pure
  # decides that in its worktree and pushes NOTHING when it does not hold.
  if [ "${OWN_CI_RED:-1}" = 1 ] && command -v mrt_own_red >/dev/null 2>&1; then
    if OWNRED=$(mrt_own_red "$SLUG" "$HEAD"); then
      RBM="$STATE/rebased.txt"
      RBN=$(grep -c "^$NUM " "$RBM" 2>/dev/null) || RBN=0
      case "$RBN" in ''|*[!0-9]*) RBN=0 ;; esac
      if [ "$(git -C "$REPO" rev-list --count "$HEAD..origin/$PBASE" 2>/dev/null || echo 0)" -gt 0 ] \
         && ! grep -qxF "$NUM $HEAD" "$RBM" 2>/dev/null && [ "$RBN" -lt "$REBASE_MAX" ]; then
        mkdir -p "$STATE" 2>/dev/null
        NEWHEAD=$(mrt_rebase_pure "$REPO" "$REMOTE" "origin/$PBASE" "$BR" "$HEAD" "$EXCL_FILE" "$REGEN_FILE" "$PROJECT" "$URL"); RBRC=$?
        # The rebase budget is spent AFTER the attempt, and never on rc 4
        # (BH-8623): Mergify held the PR and nothing was pushed. Recording it
        # after the call, not before and then deleting it, adds no state write.
        [ "$RBRC" = 4 ] || echo "$NUM $HEAD" >> "$RBM"
        case "$RBRC" in
          0) mrt_carry_verdict "$REC" "$SLUG" "$PROJECT" "$NUM" "$URL" "$NEWHEAD" "$PROV" "$SLUG#$NUM"
             say "#$NUM own CI is red on ${HEAD:0:12} ($OWNRED) and the head is behind $PBASE — that red was INHERITED from the base, and a rerun would re-test the same pinned merge ref. Rebased purely onto $PBASE (${NEWHEAD:0:12}); the patch's added/removed lines are identical and the repo's generated files still build from the result, so the head-bound verdict is CARRIED and a fresh CI run is raised. It rides the next train." ;;
          2) say "#$NUM own CI is red on ${HEAD:0:12} ($OWNRED) and it rebases cleanly onto $PBASE, but the rebased patch is NOT the same patch (a commit landed upstream, or a hunk was auto-merged) — nothing was pushed and a re-review is genuinely owed, so the ordinary conductor path owns it" ;;
          3) say "#$NUM own CI is red on ${HEAD:0:12} ($OWNRED) and it rebases cleanly onto $PBASE, but the repo's generated files do not SETTLE on the result (${NEWHEAD:-?} still move after a regenerate and a commit) — a render with no fixed point is a real conflict wearing a clean rebase's clothes, and pushing it would make this PR red for a NEW reason on a head that is no longer behind $PBASE. Nothing was pushed; the conductor's own rebase path owns it" ;;
          4) # BH-8623: nothing was pushed, so the rebase budget is not spent.
             say "#$NUM own CI is red on ${HEAD:0:12} ($OWNRED) but Mergify holds it ($NEWHEAD) — nothing was pushed: a push would dequeue it and dissolve its batch. Not batched this pass; the rebase is not spent" ;;
          *) say "#$NUM own CI is red on ${HEAD:0:12} ($OWNRED) and the rebase onto $PBASE did not happen (conflict, worktree or push) — nothing was pushed and it is not batched this pass" ;;
        esac
        continue
      fi
      mkdir -p "$STATE" 2>/dev/null
      echo "$NUM $HEAD" >> "$STATE/own-red.txt"
      say "#$NUM PARKED at ${HEAD:0:12} — its own CI concluded failure ($OWNRED) and a rebase is no longer on the table (behind-$PBASE=$(git -C "$REPO" rev-list --count "$HEAD..origin/$PBASE" 2>/dev/null || echo 0), rebases so far $RBN of $REBASE_MAX). It is not a train member until something is pushed to it."
      continue
    fi
  fi
  read -r VERD BAD <<<"$(classify_pair "origin/$PBASE" "$HEAD")"
  case "$VERD" in
    blocked)
      say "#$NUM is not a batch candidate — it conflicts with $PBASE in $BAD, which this repo does not mark regenerable or union-mergeable (a source conflict is today's path)"
      continue ;;
    unknown)
      say "#$NUM: git could not compare ${HEAD:0:8} with $PBASE — not batched this pass"
      continue ;;
    allowed) CONFLICTS_SEEN=1 ;;
  esac
  # GitHub's own verdict counts too: a PR it calls DIRTY cannot reach a provider
  # batch queue whatever git says locally, and getting it there is the point.
  [ "$MSTATE" = DIRTY ] && CONFLICTS_SEEN=1
  HEADOF[$NUM]="$HEAD"; URLOF[$NUM]="$URL"; BRANCHOF[$NUM]="$BR"; RECOF[$NUM]="$REC"
  APPROVEDOF[$NUM]="$REVIEWED"
  CAND+=("$NUM")
done
# <<< batch candidates

# Siblings against each other. The younger PR of a disallowed pair drops out, so
# the answer is the same whichever order the list arrives in.
KEEP=()
for I in "${CAND[@]:-}"; do
  [ -n "$I" ] || continue
  DROP=""
  for J in "${KEEP[@]:-}"; do
    [ -n "$J" ] || continue
    read -r VERD BAD <<<"$(classify_pair "${HEADOF[$J]}" "${HEADOF[$I]}")"
    case "$VERD" in
      blocked) DROP="#$J in $BAD"; break ;;
      unknown) DROP="#$J (git could not compare the two heads)"; break ;;
      allowed) CONFLICTS_SEEN=1 ;;
    esac
  done
  if [ -n "$DROP" ]; then
    say "#$I is not a batch candidate — it conflicts with $DROP, which this repo does not mark regenerable or union-mergeable"
    continue
  fi
  KEEP+=("$I")
done

if [ "${#KEEP[@]}" -lt "$TRAIN_MIN" ]; then
  say "fewer than $TRAIN_MIN candidate(s) (${#KEEP[@]}) — nothing to batch; the ordinary one-PR-at-a-time path owns them"
  mc_git_auth_clear; exit 0
fi
if [ "$CONFLICTS_SEEN" != 1 ]; then
  say "${#KEEP[@]} approved siblings and not one conflict between them — they merge one at a time today with no rebase, so there is nothing a train would save"
  mc_git_auth_clear; exit 0
fi
# ---------------------------------------------------------------------------
# THE PARTITION (BH-1270). Every candidate's planned-file set, then the groups
# that cannot meet each other, then one train per group.
# ---------------------------------------------------------------------------
# set_of <num> — the candidate's files and the module directories they reach.
#   An UNJUDGED candidate (no plan, no record list, no readable diff) leaves an
#   empty file set, which _mrt_pair_conflicts reads as "conflicts with
#   everything" — so it lands in one component with the rest and the pass falls
#   back to a single train. Said out loud: the same fact bin/overlap-schedule.sh
#   prints as OVERLAP_UNJUDGED, for the same reason — a candidate nobody can
#   judge must never be silently treated as disjoint.
set_of() {
  local num="$1"
  [ -n "${SETDIR:-}" ] || return 1
  if mrt_planned_files "$H" "$PROJECT" "${RECOF[$num]:-}" "${BRANCHOF[$num]}" \
       "$REPO" "origin/$PBASE" "${HEADOF[$num]}" "$SETDIR/$num.files" "${EXCL_FILE:-}"; then
    mrt_modules_of "$SETDIR/$num.files" "$SETDIR/$num.mods"
    return 0
  fi
  : > "$SETDIR/$num.mods" 2>/dev/null
  say "#$num states no files it would touch (no pre-plan list, no build-record list, no readable diff against $PBASE) — it is UNJUDGED, so it may not ride a train beside another one and every candidate of this pass rides with it"
  return 1
}
if [ -n "${SETDIR:-}" ] && command -v mrt_planned_files >/dev/null 2>&1; then
  for I in "${KEEP[@]:-}"; do
    [ -n "$I" ] || continue
    set_of "$I" && say "#$I claims $(grep -c . "$SETDIR/$I.files") file(s) from $MRT_PF_SOURCE$( [ -s "$SETDIR/$I.mods" ] && printf ' in module(s) %s' "$(tr '\n' ' ' < "$SETDIR/$I.mods")")"
  done
fi

# WHAT THE TRAINS ALREADY IN FLIGHT HOLD. A new union must not touch a file a
# live train carries: that train's members are about to land and the new one
# would be cut from a base that does not contain them. One UNJUDGED in-flight
# member is enough to stand the whole pass down — the honest answer to "I cannot
# tell what that train holds" is the pre-BH-1270 behaviour, not a guess.
INFLIGHT_UNJUDGED=0
if [ -n "${SETDIR:-}" ] && [ "$INFLIGHT" -gt 0 ] && command -v mrt_planned_files >/dev/null 2>&1; then
  : > "$SETDIR/inflight.files"; : > "$SETDIR/inflight.mods"
  for f in ${INFLIGHT_RECS+"${INFLIGHT_RECS[@]}"}; do
    while IFS=$'\t' read -r IN_N IN_U IN_B IN_H; do
      [ -n "$IN_N" ] && [ -n "$IN_H" ] && [ "$IN_H" != "-" ] || continue
      IN_REC=$(mc_record_for "$IN_U" || true)
      if mrt_planned_files "$H" "$PROJECT" "$IN_REC" "$IN_B" "$REPO" "origin/$PBASE" \
           "$IN_H" "$SETDIR/inflight-$IN_N.files" "${EXCL_FILE:-}"; then
        cat "$SETDIR/inflight-$IN_N.files" >> "$SETDIR/inflight.files"
      else
        INFLIGHT_UNJUDGED=1
        say "the train in flight carries #$IN_N and nothing here can say what files it touches — no new train is built beside it this pass"
      fi
    done < <(jq -r '.members[]? | [.num,.url,.branch,.head] | @tsv' "$f" 2>/dev/null)
  done
  LC_ALL=C sort -u "$SETDIR/inflight.files" -o "$SETDIR/inflight.files" 2>/dev/null || true
  mrt_modules_of "$SETDIR/inflight.files" "$SETDIR/inflight.mods"
fi
if [ "$INFLIGHT" -gt 0 ] && [ "$INFLIGHT_UNJUDGED" = 1 ]; then
  say "$INFLIGHT train(s) in flight and at least one of their members is unjudged — standing down to the one-train-at-a-time behaviour for this pass"
  mc_git_auth_clear; exit 0
fi
if [ "$INFLIGHT" -gt 0 ] && [ -s "${SETDIR:-/nonexistent}/inflight.files" ]; then
  FREE=()
  for I in "${KEEP[@]:-}"; do
    [ -n "$I" ] || continue
    # AN UNJUDGED CANDIDATE IS NOT DISJOINT FROM ANYTHING, and that includes a
    # train already in flight. mrt_sets_overlap answers "no" for an empty set —
    # correctly, it is a question about two sets — so the CALLER has to say what
    # an empty one means, and here it means what it means in the partition: it
    # rides with everything, which beside a live train is nothing at all.
    if [ ! -s "$SETDIR/$I.files" ]; then
      say "#$I is not batched this pass — nothing here can say what files it would touch and a train is already in flight, so it cannot be shown to be disjoint from it"
      continue
    fi
    if mrt_sets_overlap "$SETDIR/$I.files" "$SETDIR/inflight.files" \
       || mrt_sets_overlap "$SETDIR/$I.mods" "$SETDIR/inflight.mods"; then
      say "#$I is not batched this pass — the files it claims meet a train that is already in flight, and a union cut from a base that does not contain that train would meet it as a conflict"
      continue
    fi
    FREE+=("$I")
  done
  KEEP=()
  for I in ${FREE+"${FREE[@]}"}; do KEEP+=("$I"); done
  if [ "${#KEEP[@]}" -lt "$TRAIN_MIN" ]; then
    say "every remaining candidate meets a train already in flight — nothing to batch beside it this pass"
    mc_git_auth_clear; exit 0
  fi
fi

# >>> train identity preflight (BH-1606, #1624 round 3)
# ASKED HERE, BEFORE ANY UNION IS BUILT. A box that cannot mint the App token can
# never open a train, and finding that out in land_union costs a full union +
# regenerate + verification-contract run every pass, for nothing. The token is
# released at once: this only proves a mint works.
if br_train_identity; then br_train_release; else
  br_train_refuse "this pass"
  mc_git_auth_clear; exit 0
fi
# <<< train identity preflight

# THE GROUPS. mrt_group_plan unions every pair that could ever conflict, so a
# component is indivisible and two groups can never meet; TRAIN_SLOTS bounds how
# many groups there are and BATCH_MAX_MEMBERS bounds each one. With
# TRAIN_PARALLEL=1 this is one group holding every candidate in the order the
# pass found them, capped at BATCH_MAX_MEMBERS — the pre-BH-1270 answer exactly.
PLAN=""
if command -v mrt_group_plan >/dev/null 2>&1 && [ -n "${SETDIR:-}" ]; then
  PLAN=$(mrt_group_plan "$TRAIN_SLOTS" "$MAX_MEMBERS" "$SETDIR" "${KEEP[@]}")
fi
if [ -z "$PLAN" ]; then
  # No module on this box: one train, capped, exactly as before.
  if [ "${#KEEP[@]}" -gt "$MAX_MEMBERS" ]; then
    say "capping the train at $MAX_MEMBERS of ${#KEEP[@]} candidates (BATCH_MAX_MEMBERS) — the rest ride the next one"
    KEEP=("${KEEP[@]:0:$MAX_MEMBERS}")
  fi
  PLAN=$(printf '0\t%s\n' "${KEEP[@]}")
fi
NGROUPS=$(printf '%s\n' "$PLAN" | cut -f1 | sort -u | grep -c .)
DROPPED=$(( ${#KEEP[@]} - $(printf '%s\n' "$PLAN" | grep -c .) ))
[ "$DROPPED" -gt 0 ] && say "capping each train at $MAX_MEMBERS members (BATCH_MAX_MEMBERS) — $DROPPED candidate(s) ride the next pass"
say "partitioned ${#KEEP[@]} approved siblings into $NGROUPS train(s) on disjoint planned-file sets (TRAIN_PARALLEL=$TRAIN_PARALLEL, cap $PARALLEL_CAP, $TRAIN_SLOTS slot(s) free) — verification contract: $VERIFY"
while read -r G; do
  [ -n "$G" ] || continue
  MEM=()
  while IFS=$'\t' read -r GG NN; do
    [ "$GG" = "$G" ] && [ -n "$NN" ] && MEM+=("$NN")
  done <<<"$PLAN"
  [ "${#MEM[@]}" -ge "$TRAIN_MIN" ] || continue
  TRAIN_GROUP="$G"; GROUP_PUSHED=0
  say "group $G: building a train of ${#MEM[@]} approved siblings (${MEM[*]})"
  attempt 0 "${MEM[@]}"
done < <(printf '%s\n' "$PLAN" | cut -f1 | sort -un)
# The two append-only exclusion files are keyed on (PR, head) and a head is dead
# the moment it moves, so the tail is all that can ever match. Trimmed here
# rather than never: on a busy repo these grow a line per member per pass for
# ever, and every candidate read greps them.
for f in "$STATE/landed.txt" "$STATE/red.txt" "$STATE/abandoned.txt" \
         "$STATE/own-red.txt" "$STATE/rebased.txt"; do
  [ -s "$f" ] || continue
  [ "$(grep -c . "$f")" -gt "${BATCH_EXCLUDE_KEEP:-2000}" ] || continue
  tail -n "${BATCH_EXCLUDE_KEEP:-2000}" "$f" > "$f.tmp" && mv -f "$f.tmp" "$f"
done
# Settled train records the same way: the live ones are open or creating.
find "$STATE" -maxdepth 1 -name 'train-*.json' -mtime +14 -delete 2>/dev/null
mc_git_auth_clear
exit 0
