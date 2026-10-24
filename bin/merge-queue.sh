#!/bin/bash
# SCALE-PLAN wave 4a — merge queue. Serializes landings so cleared PRs never
# race each other onto main (the TK-105 sibling-conflict class).
# Queue entries: state/merge-queue/<project>/<pr-number> — written by
# run-build.sh (tier-1 merge conflict), review-prs.sh (external APPROVE
# conflict), or the orchestrator (tier-2 on the operator's word). FIFO by file mtime.
# Per PR (on BOTH landing paths — the union merge train and the serial loop):
# head-bound approval check (SDLC item 1), clean-rebase onto fresh main
# if needed (typecheck gate when the rebase changed anything), squash-merge,
# verify MERGED, hand off to the deploy train / deploy-verify. A rebase that
# CONFLICTS is handed on with one beat — the queue never guesses at semantic
# resolutions, and the merge conductor then parks it conflict-unresolvable for
# bin/blocked-resolver.sh to rebuild fresh against current main. HEADBOUND_ENFORCE=1 (default) blocks a queue entry whose
# PR head is not the sha the review approved; 0 downgrades that to a log line and lands the entry not bound to the
# reviewed sha — pinned instead to the head this pass read (BH-1606) — so the switch merges rather than collecting a 409.
# usage: merge-queue.sh <project>   (cron per box + invoked after enqueue)
set -uo pipefail
PROJECT="${1:?project}"
# Overridable so this queue can be DRIVEN against a scratch tree — the same
# change bin/merge-sweep.sh and bin/review-prs.sh took in phase 4. Cron sets it
# nowhere, so production resolves to exactly the path it always has.
HARNESS="${HARNESS:-/root/harness}"
export BASE_BRANCH="${BASE_BRANCH:-main}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$HARNESS")
set -a; . "$HENV/global.env" 2>/dev/null; . "$HENV/$PROJECT.env" 2>/dev/null; set +a

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-merge-queue
# (or its project row) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off merge-queue <project>.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit merge-queue "$PROJECT"
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    merge-queue "$PROJECT"
# slug_for <project> — the GitHub repo for a fleet project. fleet.conf is the
# registry (bin/fleet-conf.sh), and the only one: the four literal rows that
# used to back it up are gone (BH-4080), so no row means no slug, never a
# guess. An unknown project used to leave SLUG empty and every gh call below
# failed quietly (project-7, 2026-09-10).
slug_for() {
  local p="$1" s
  s=$("${HARNESS:-/root/harness}/bin/fleet-conf.sh" "$p" repo 2>/dev/null)
  [ -n "$s" ] || return 1
  printf '%s' "$s"
}
SLUG=$(slug_for "$PROJECT") || { echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [$PROJECT] merge-queue: no repo slug in fleet.conf — refusing" >> "$HARNESS/logs/merge-queue.log"; exit 0; }
Q="$HARNESS/state/merge-queue/$PROJECT"; mkdir -p "$Q"
# MOVED UP FROM THE FLOCK BELOW (BH-1026.2): the queue read now happens BEFORE
# the early exit, and a read that could not reach the rows has to be able to say
# so. Both were plain definitions; nothing between here and their old position
# used either.
LOG="$HARNESS/logs/merge-queue.log"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }

# --- The queue comes from the ROWS too (2026-09-10) ---------------------------
# Entries reached this directory two ways: written locally, or `touch`ed into it
# over ssh by bin/fly-pool.sh / bin/fly-results-ingest.sh — a hub or a fly
# machine reaching INTO this box because the queue a tier-1 APPROVE must join
# lives here. Those two now write a `merge_queue` row as well, and this
# materialises the queued ones into the SAME empty files the rest of this script
# reads. Only the SOURCE of the file changes: every gate, the merge train, the
# blocked convention and the FIFO below are untouched.
#
# In enqueued_at order and one `touch` at a time, because `ls -tr` orders this
# queue by mtime and creating a batch in the wrong order would reorder landings.
#
# Fail-open: no client, no worker, no rows, and this reads exactly the directory
# it always did.
# shellcheck source=/dev/null
[ -r "$HARNESS/bin/jobs-client.sh" ] && . "$HARNESS/bin/jobs-client.sh"
# One owner per ticket (BH-1526): the merge-time HOLD and one-PR-per-ticket.
# shellcheck source=bin/lib/ticket-ownership.sh
[ -r "$HARNESS/bin/lib/ticket-ownership.sh" ] && . "$HARNESS/bin/lib/ticket-ownership.sh"
# BH-1026.2: with `merge_queue_rows_only` on, the ROWS are the queue and the
# directory is only a fallback. Read through `command -v` because the flag's
# own definition ships with the coordination client: a box whose client predates
# it resolves MQROWS=0 and every path below is this file byte for byte as it was.
MQROWS=0
command -v merge_queue_rows_only_on >/dev/null 2>&1 && merge_queue_rows_only_on && MQROWS=1
MQROW() { # MQROW <pr> <status> [reason] — mirror a terminal decision onto the row
  command -v merge_queue_set >/dev/null 2>&1 || return 0
  local mrc
  merge_queue_set "$PROJECT" "$1" "$2" "${3:-}" >/dev/null 2>&1; mrc=$?
  [ "$mrc" -eq 0 ] && return 0
  # rc 2 is a 404: this PR reached the queue as a FILE (run-build.sh's tier-1
  # conflict path, review-prs.sh, a hand `touch`) and has no row yet. Dropping
  # the outcome there would make the ledger quietly incomplete in exactly the
  # cases a human goes looking for — a PR that blocked, on a box whose producer
  # has not moved to rows. Create the row, then record the outcome on it.
  [ "$mrc" -eq 2 ] || return 0
  # …but only while the FILES are the queue. With the rows as the queue there is
  # no row-less producer left to heal for, and a PUT here would put a `queued`
  # row back under a PR this queue just finished with (BH-1026.2).
  [ "${MQROWS:-0}" = 1 ] && return 0
  merge_queue_put "$PROJECT" "$1" "" "recorded on close by the merge queue" >/dev/null 2>&1 || return 0
  merge_queue_set "$PROJECT" "$1" "$2" "${3:-}" >/dev/null 2>&1 || true
  return 0
}

# mq_park <pr> <reason> — park this PR where an operator can read WHY.
#
# A `<pr>.blocked` FILENAME says a human was asked to look and cannot say at
# what: the five sentences below travelled only into this box's log. With the
# rows as the queue the reason rides on the row and the plain file is removed;
# every call site hands over the SAME string it hands MQROW today, so nothing an
# operator reads changes wording.
#
# THE FILE IS STILL THE FALLBACK, and it is written even when there is no plain
# file to rename — a row-only entry whose PATCH was refused would otherwise be
# parked nowhere and re-offered on every tick. The plain file is removed only
# AFTER the PATCH returned 0: a park that half-happened leaves the PR queued and
# re-asked, never parked without a reason.
#
# `${MQROWS:-0}` and not `$MQROWS`: tests/head-bound-approval-test.sh lifts this
# function beside the `# >>> head-bound approval` block and runs the pair under
# `set -u`. An unset flag means the FILE path — fail-closed, and identical to
# what this queue did before the flag existed.
mq_park() {
  if [ "${MQROWS:-0}" = 1 ] && command -v merge_queue_set >/dev/null 2>&1 \
     && merge_queue_set "$PROJECT" "$1" blocked "$2" >/dev/null 2>&1; then
    rm -f "$Q/$1"
    return 0
  fi
  mv "$Q/$1" "$Q/$1.blocked" 2>/dev/null || : > "$Q/$1.blocked"
  MQROW "$1" blocked "$2"
}
if [ "$MQROWS" = 0 ] && command -v merge_queue_list >/dev/null 2>&1; then
  while IFS="$(printf '\t')" read -r _MP MPR _MST _MRE _MBY _MAT _MRS; do
    case "${MPR:-}" in ''|*[!0-9]*) continue ;; esac
    [ -f "$Q/$MPR" ] && continue
    # A row this box has already parked stays parked: the .blocked sibling is
    # this queue's own record and re-materialising over it would re-offer a PR
    # a human was asked to look at.
    [ -f "$Q/$MPR.blocked" ] && continue
    touch "$Q/$MPR" && echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [$PROJECT] #$MPR taken from the coordination DB (no ssh touch)" >> "$HARNESS/logs/merge-queue.log"
  done <<MQFEED
$(merge_queue_list "$PROJECT" queued 2>/dev/null)
MQFEED
fi

# mq_queue_list — THE QUEUE, in FIFO order, whatever it is made of.
#
#   MQROWS=0: exactly the directory read this script has always done.
#   MQROWS=1: the `queued` rows (the API returns them by enqueued_at, which is
#     the order `ls -tr` gave the directory) UNION whatever files are still on
#     disk, minus any PR whose row is `blocked` and minus any `<n>.blocked`.
#
# THE UNION, NOT A BARE ROW READ. Two producers still write only a file — the
# tier-1 conflict arm of bin/run-build.sh and merge_step's queue arm in
# bin/review-prs.sh — and a rows-only read would strand both. It is also what
# makes ".blocked files that already exist on a live box are read one more
# cycle" true by construction: no migration, no hand step.
#
# AN UNREADABLE ROW LIST IS NOT AN EMPTY QUEUE (D11/D12). Every failed read
# writes a line naming the rc and falls back to the files, which is exactly what
# the box had before the flag.
mq_queue_list() {
  local tsv rc want blocked f n
  if [ "${MQROWS:-0}" = 0 ] || ! command -v merge_queue_list >/dev/null 2>&1; then
    ls -tr "$Q" 2>/dev/null | grep -v '\.absent$' | grep -v '\.blocked$' || true
    return 0
  fi
  tsv=$(merge_queue_list "$PROJECT" 2>/dev/null); rc=$?
  if [ "$rc" != 0 ]; then
    # Every failed read says so — this runs inside `$(…)`, so a once-per-process
    # marker would die with the subshell and the outage would be silent.
    echo "$(STAMP) [$PROJECT] merge-queue rows could not be read (rc $rc) — falling back to the files on disk this tick" >> "$LOG"
    ls -tr "$Q" 2>/dev/null | grep -v '\.absent$' | grep -v '\.blocked$' || true
    return 0
  fi
  want=$(printf '%s\n' "$tsv" | awk -F'\t' '$3 == "queued" && $2 ~ /^[0-9]+$/ { print $2 }')
  blocked=$(printf '%s\n' "$tsv" | awk -F'\t' '$3 == "blocked" && $2 ~ /^[0-9]+$/ { print $2 }')
  for f in $(ls -tr "$Q" 2>/dev/null | grep -v '\.absent$' | grep -v '\.blocked$' || true); do
    case "$f" in ''|*[!0-9]*) continue ;; esac
    grep -qxF "$f" <<<"$want" || want=$(printf '%s\n%s' "$want" "$f")
  done
  for n in $want; do
    grep -qxF "$n" <<<"$blocked" && continue
    [ -e "$Q/$n.blocked" ] && continue
    printf '%s\n' "$n"
  done
}

[ -n "$(mq_queue_list)" ] || exit 0
exec 8>"$HARNESS/locks/merge-queue-$PROJECT.lock"; flock -w 900 8 || exit 0
# >>> pause guards (BH-1285; BH-1370 shape: flag_active decides when present)
mq_pause_on() { if command -v flag_active >/dev/null 2>&1; then flag_active "$1"
  else [ -f "$HARNESS/flags/$1" ]; fi; }
for MQ_AM in automerge-disabled "automerge-disabled-$PROJECT"; do # the fleet switch, then this board's toggle (#2322)
  if mq_pause_on "$MQ_AM"; then
    echo "$(STAMP) [$PROJECT] merge-queue stood down: flags/$MQ_AM is on — no merges this pass" >> "$LOG"; exit 0
  fi
done
if mq_pause_on "paused-$PROJECT"; then
  echo "$(STAMP) [$PROJECT] merge-queue stood down: flags/paused-$PROJECT is on — no merges for this project this pass" >> "$LOG"; exit 0
fi
# <<< pause guards
# A repo behind GitHub's NATIVE merge queue is not this queue's to land. Every
# path below assumes `gh pr merge` either merges or fails; there it ENQUEUES and
# exits 0, so the PR stays OPEN, the entry file is never dropped, and this cron
# re-enqueues the same PR every 20 minutes forever while the merge conductor is
# already settling it. The repo capability is the switch (no flag to forget):
# remove the ruleset rule and this queue owns its merges again on the next tick.
# shellcheck source=bin/lib/merge-conductor-lib.sh
# That lib also brings bin/lib/gh-rest.sh, which every read below goes through:
# rc 0 acted on, 44 ABSENT, 75 UNVERIFIABLE (#768). A tree with neither keeps
# the shims, and mq_pr then answers nothing, which every gate here reads as
# "skip this row" — the fail-closed side.
# gh-rest: no-graphql
if [ -r "$HARNESS/bin/lib/merge-conductor-lib.sh" ]; then . "$HARNESS/bin/lib/merge-conductor-lib.sh"
else mc_queue_enabled() { return 1; }; mc_pr_view() { return 75; }; mc_rest_status() { printf '?'; }; fi
# WHICH IDENTITY GOT REFUSED, AND HOW MANY CALLS THIS LANE MAKES (BH-426). This
# lane was one of two on the merge path that never sourced the logger, so a
# rate-limit 403 here named nothing and its calls were invisible to the
# top-callers list in the quota alert. Guarded and fail-open: a box whose sync
# has not landed the lib runs exactly as it does today.
# shellcheck source=bin/lib/gh-limit-logger.sh
[ -r "$HARNESS/bin/lib/gh-limit-logger.sh" ] && . "$HARNESS/bin/lib/gh-limit-logger.sh"
# mq_pr <pr-number> <jq-expr> — this queue's one read. The URL is the same one
# it has always built for the beats below.
mq_pr() { mc_pr_view "https://github.com/$SLUG/pull/${1:?num}" "${2:?expr}"; }
# The landings below go over REST (BH-892): `gh pr merge` is a GraphQL mutation,
# and a GraphQL bucket that is empty has nothing to say about whether a PR can
# merge. Guarded — a tree without the lib lands exactly as it did before.
# shellcheck source=bin/lib/gh-pr-merge.sh
[ -r "$HARNESS/bin/lib/gh-pr-merge.sh" ] && . "$HARNESS/bin/lib/gh-pr-merge.sh"
# Arm the per-repo App token before the first gh call — every one of them is
# below this line. Guarded and `|| true`: an unarmed box, or one whose lib
# predates the wrapper, keeps running on the fleet PAT exactly as before. The
# early `exit 0` paths above and below do not reset; there is nothing to reset
# to, because the exported token dies with the process.
command -v mc_use_token >/dev/null 2>&1 && mc_use_token "$SLUG" || true
if mc_queue_enabled "$SLUG"; then
  echo "$(STAMP) [$PROJECT] queue held: $SLUG main is behind a native merge queue — the merge conductor owns merges on queue repos" >> "$LOG"
  exit 0
fi
# SDLC item 2: the review gate. bin/review-tighten.sh parks a repo whose
# trailing-window revert/reopen rate crossed its threshold; while it is parked
# nothing here lands, the queue entries simply WAIT (they are never deleted, so
# they land the moment the gate clears or the operator merges them by judgement).
# This is the per-box merge path, so it needs the same gate bin/merge-sweep.sh
# has — a steering rule that stops one of two merge paths is not a steering
# rule. Fail-open like every other flag read: no client, or an unreachable
# worker with no local flag file, and the queue behaves exactly as it does now.
if [ -f "$HARNESS/bin/jobs-client.sh" ]; then # shellcheck source=/dev/null
  . "$HARNESS/bin/jobs-client.sh"; fi
# flags/conductor-owns-merges: ONE merger for the fleet (docs/MERGE-CONDUCTOR.md
# section 9, phase C). While it is on, bin/merge-conductor.sh is the only thing
# that lands a harness PR, and this per-box queue stands down — its entries are
# left where they are, never deleted, so removing the flag hands them straight
# back. Read through flag_active so a console flip reaches every box; with no
# client the bare file is the flag, exactly like the kill switch above.
if command -v flag_active >/dev/null 2>&1 && flag_active conductor-owns-merges \
   || [ -f "$HARNESS/flags/conductor-owns-merges" ]; then
  echo "$(STAMP) [$PROJECT] queue held: flags/conductor-owns-merges is on — bin/merge-conductor.sh owns merges; entries kept" >> "$LOG"
  exit 0
fi
if command -v review_tighten_active >/dev/null 2>&1 && review_tighten_active "$SLUG"; then
  echo "$(STAMP) [$PROJECT] queue held: $SLUG review gate is TIGHTENED (bin/review-tighten.sh) — waiting for a judged merge" >> "$LOG"
  exit 0
fi
REPO_DIR="/root/repos/$PROJECT"

# >>> head-bound approval
# SDLC item 1, the same rule the hub's merge sweep applies, on the per-box merge
# path: a steering rule that stops one of two merge paths is not a steering
# rule. bin/run-build.sh binds its approval to a sha; commits landed after it
# (security, refuter or QA fix rounds) are code no reviewer and no suite read,
# and this queue would land them on the strength of a verdict that predates
# them. FUNCTIONS, not an inline block, because this queue has TWO landing
# paths: the union merge train below (which is the busy one — every approved
# tier-2 PR is enqueued in one pass) and the serial loop after it. A gate on
# only the serial path leaves the hole open on the path that actually merges.
#
# FAIL-OPEN on absence throughout: no ledger row, no reviewed sha on it, or no
# worker, and the queue behaves exactly as it did.

# hb_sha <num> — the sha the review bound its approval to, "" when the ledger
#   makes no claim about this PR.
hb_sha() {
  local num="$1" row sha
  type job_verdict >/dev/null 2>&1 || return 0
  row=$(job_verdict "https://github.com/$SLUG/pull/$num") || return 0
  sha=$(cut -f6 <<<"$row")
  case "$sha" in ""|"-") return 0 ;; esac
  printf '%s' "$sha"
}

# >>> conductor verdict gate
# mq_conductor_hold <num> [head] — rc 0 when the merge conductor's verdict for
#   this PR's head says NOT to merge it (BH-5914). rc 1 = no objection.
#   The rule lives in bin/lib/conductor-verdict.sh (cv_hold), shared with
#   bin/review-prs.sh and the run-build tier-1 merge; its header has the
#   incident (project-6 #27: the conductor refused a head and this queue merged
#   it twenty seconds later on another box). mq_land calls this, so the union
#   train and the serial loop both ask it.
#   A HEAD THIS PASS COULD NOT READ holds the entry for this pass (it stays
#   queued), as hb_blocked and mq_lead_hold do. A worker outage and a box with
#   no ledger client land as before (cv_hold logs the outage).
# Sourced HERE, inside the block the suites extract and run.
# shellcheck source=bin/lib/conductor-verdict.sh
[ -r "$HARNESS/bin/lib/conductor-verdict.sh" ] && . "$HARNESS/bin/lib/conductor-verdict.sh"
mq_conductor_hold() {
  local num="$1" head="${2:-}"
  command -v cv_hold >/dev/null 2>&1 && command -v job_ledger_row >/dev/null 2>&1 || return 1
  if [ -z "$head" ]; then
    head=$(mq_pr "$num" .head.sha 2>/dev/null) || head=""
    case "$head" in ''|null)
      echo "$(STAMP) [$PROJECT] #$num not landed this pass: its head could not be read (HTTP $(mc_rest_status 2>/dev/null)) — the conductor verdict cannot be checked, the entry stays queued" >> "$LOG"
      return 0 ;;
    esac
  fi
  cv_hold "$SLUG" "$num" "$head" "$LOG" "$(STAMP) [$PROJECT] #$num" || return 1
  echo "$(STAMP) [$PROJECT] #$num the entry stays queued; it lands when the conductor clears head ${head:0:8}" >> "$LOG"
  return 0
}
# <<< conductor verdict gate

# >>> pre-merge guard
# The last check before a merge (BH-6428): the head is the reviewed sha, its CI
# is green, and the merge conductor has not parked the PR. The rule lives in
# bin/lib/mq-premerge.sh (pmg_check), whose header has the project-6 #216
# incident. mq_land asks it before every merge rung, so the union train and the
# serial loop both ask it. A box whose sync has not landed the lib answers ok,
# as mq_conductor_hold does.
# shellcheck source=bin/lib/mq-premerge.sh
[ -r "$HARNESS/bin/lib/mq-premerge.sh" ] && . "$HARNESS/bin/lib/mq-premerge.sh"
# mq_enqueued_epoch <num> — when the entry was enqueued: the queued row's
#   enqueued_at, else the queue file's mtime, else nothing. The row comes first
#   because a row-only entry gets its file when this box materialises it, so
#   the mtime would make an old enqueue look new.
mq_enqueued_epoch() {
  local num="$1" at e
  if command -v merge_queue_list >/dev/null 2>&1; then
    at=$(merge_queue_list "$PROJECT" 2>/dev/null | awk -F'\t' -v n="$num" '$2 == n { print $6; exit }')
    e=$(command -v pmg_epoch >/dev/null 2>&1 && pmg_epoch "$at")
    [ -n "$e" ] && { printf '%s' "$e"; return 0; }
  fi
  stat -c %Y "$Q/$num" 2>/dev/null || true
}
# mq_reviewed_sha <num> — the sha the review approved: hb_sha (the job_verdict
#   row), else reviewed_sha on the conductor's pr_state row, else nothing.
mq_reviewed_sha() {
  local num="$1" sha row
  sha=$(hb_sha "$num" 2>/dev/null)
  [ -n "$sha" ] && { printf '%s' "$sha"; return 0; }
  command -v job_ledger_row >/dev/null 2>&1 || return 0
  row=$(job_ledger_row pr_state "$SLUG#$num" 2>/dev/null) || return 0
  jq -r '.detail | (if type == "string" then (fromjson? // {}) elif type == "object" then . else {} end)
         | .reviewed_sha // "" | select(. != "-")' <<<"$row" 2>/dev/null || true
}
# mq_premerge_guard <num> <head> — prints pmg_check's answer: ok, hold <reason>
#   or handback <reason>.
mq_premerge_guard() {
  local num="$1" head="${2:-}"
  command -v pmg_check >/dev/null 2>&1 || { printf 'ok\n'; return 0; }
  pmg_check "$SLUG" "$num" "$head" "$(mq_reviewed_sha "$num")" "$(mq_enqueued_epoch "$num")" \
    "$LOG" "$(STAMP) [$PROJECT] #$num"
}
# mq_refused <num> <handback|hold> <reason> — act on a guard refusal that
#   mq_land printed. handback: the entry leaves this queue and its row is
#   dropped with the reason; the merge conductor lands every READY PR itself,
#   and a fresh APPROVE re-queues it. hold: nothing; the entry stays queued and
#   pmg_check already wrote the log line.
mq_refused() {
  [ "${2:-}" = handback ] || return 0
  rm -f "$Q/$1" "$Q/$1.absent"
  MQROW "$1" dropped "MERGE_REFUSED ${3:-} — handed back to the merge conductor"
  echo "$(STAMP) [$PROJECT] #$1 handed back to the merge conductor: ${3:-}" >> "$LOG"
}
# <<< pre-merge guard

# >>> mq_land
# BH-8150: the PR record writer (bin/lib/pr-record-write.sh); the shim above
# loads it. Without it the merge verb and the rebase push run as before.
# shellcheck source=bin/lib/pr-record-write.sh
command -v prr_write >/dev/null 2>&1 || . "$(dirname "${BASH_SOURCE[0]}")/lib/pr-record-write.sh" 2>/dev/null \
  || { prr_write() { shift 4; "$@"; }; prr_note_push() { return 0; }; prr_now() { return 0; }; }
# mq_land <num> — land ONE PR (BH-892). Prints `MERGED <sha>` when GitHub's own
#   REST answer says the merge happened (the sha may be empty when the 200 did
#   not carry one), `REFUSED <hold|handback> <reason>` when the pre-merge guard
#   refused the head (no rung ran; the caller hands it to mq_refused), and
#   nothing at all otherwise.
#
#   THE TWO LANDING PATHS SHARE THIS, for the same reason hb_blocked is a
#   function: the union merge train and the serial loop both merge, and a change
#   applied to one of them is not a change to this lane.
#
#   The reviewed sha rides on the PUT, so a head that moved between the gate and
#   the landing is refused by GitHub (409) instead of merged blind. A terminal
#   refusal (405/409/422) is logged and NOT retried over GraphQL — the entry is
#   left queued and the next pass asks again. Only "no REST rung answered" falls
#   through to the `gh pr merge` line this lane has always run.
#   THE PIN (BH-1606). <pin-head> is the head mq_lead_hold read this pass — the
#   head the lead verdict, if any, stands on. With no reviewed sha (or the
#   switch below off) the landing is pinned to it; a reviewed sha that is not
#   that head is two different heads cleared by two different reads, and
#   nothing lands this pass.
mq_land() { # mq_land <num> [pin-head]
  local num="$1" pin="${2:-}" out rc sha
  # BH-5914: the conductor's per-head verdict, asked before anything is spent.
  if command -v mq_conductor_hold >/dev/null 2>&1 && mq_conductor_hold "$num" "$pin"; then return 0; fi
  # BH-6428: reviewed sha, CI and conductor park state, before any merge rung.
  if command -v mq_premerge_guard >/dev/null 2>&1; then
    local ghead="$pin" verdict
    [ -n "$ghead" ] || ghead=$(mq_pr "$num" .head.sha 2>/dev/null) || ghead=""
    verdict=$(mq_premerge_guard "$num" "$ghead")
    case "$verdict" in ok) ;; *) printf 'REFUSED %s\n' "${verdict:-hold no-answer}"; return 0 ;; esac
  fi
  sha=$(hb_sha "$num" 2>/dev/null)
  # hb_blocked says "land it" when HEADBOUND_ENFORCE is off, and a PUT still
  # bound to the reviewed sha would answer 409 to the very head that switch
  # just waved through. Off means not bound to the REVIEWED sha — still pinned.
  if [ -n "$sha" ] && [ "${HEADBOUND_ENFORCE:-1}" != 1 ]; then
    echo "$(STAMP) [$PROJECT] #$num HEADBOUND_ENFORCE=0 — the merge is not bound to the reviewed sha $sha (pinned to ${pin:-no} head)" >> "$LOG"
    sha=""
  fi
  if [ -n "$sha" ] && [ -n "$pin" ] && [ "$sha" != "$pin" ]; then
    echo "$(STAMP) [$PROJECT] #$num not landed this pass: the reviewed sha $sha is not the head $pin this pass read — the entry stays queued" >> "$LOG"
    return 0
  fi
  [ -n "$sha" ] || sha="$pin"
  if command -v gh_pr_merge_rest >/dev/null 2>&1; then
    out=$(gh_pr_merge_rest "$SLUG" "$num" "$sha" \
            "$HARNESS/logs/merge-queue-gh.err" "$LOG" "merge-queue #$num"); rc=$?
    case "$rc" in
      0) printf 'MERGED %s\n' "$out"; return 0 ;;
      2) : ;;
      *) echo "$(STAMP) [$PROJECT] #$num REST merge refused (rc $rc): $out — the entry stays queued, the next pass asks again" >> "$LOG"
         return 0 ;;
    esac
  fi
  # THE METHOD COMES FROM THE REPO (BH-1313). `--squash` when the lib is absent
  # is this line byte for byte as it was, and it is also what the helper answers
  # for a repo whose settings do not read.
  local mflag=--squash
  command -v gh_pr_merge_flag >/dev/null 2>&1 \
    && mflag=$(gh_pr_merge_flag "$SLUG" "$num" "$LOG" "merge-queue #$num")
  local pinarg=(); [ -n "$sha" ] && pinarg=(--match-head-commit "$sha")   # BH-1606
  prr_write "$SLUG" "$num" none '{"queue_state":"merge_requested"}' gh pr merge "$num" -R "$SLUG" "$mflag" ${pinarg[@]+"${pinarg[@]}"} >/dev/null 2>&1 || true  # gh-guard-allow: gated merge verb, out of BH-770 scope
}
# <<< mq_land

# >>> lead fence
# mq_lead_hold <num> — rc 0 when this queue must NOT land the entry this pass
#   (BH-1606): a LEAD PR with no lead/human MERGE row standing on its live head,
#   or a fence that could not be read. rc 1 = land it. Sets MQ_LEAD_HEAD to the
#   head it read, which the landing below is pinned to (mq_land's 2nd arg), and
#   MQ_LEAD_CLEARED=1 for a lead PR cleared on that head (it must not then be
#   rewritten by this queue's rebase or the lander).
#   to_lane_hold exempts a lead PR, so without this a lead PR reached main from
#   this queue on any box APPROVE. ALL THREE landing paths ask it — the serial
#   path ONCE, at the top of the entry, before any rebase or push (#1624 I2) —
#   ahead of bg_queue_hold, whose clean scan would restart the outage alert's
#   count, and the entry is never moved aside: the hold ends by itself when the
#   lead's verdict lands on this head.
#   No ownership lib on this box: land as before (every to_lane_hold site here
#   reads the same way). A PR that cannot be read: held, left queued.
mq_lead_hold() {
  local num="$1" st who head
  MQ_LEAD_HEAD=""; MQ_LEAD_CLEARED=0
  command -v to_lane_lead_fence >/dev/null 2>&1 || return 1
  st=$(mq_pr "$num" '"\(.user.login) \(.head.sha)"' 2>/dev/null) || st=""
  read -r who head <<<"$st"
  if [ -z "${head:-}" ] || [ "$head" = null ] || [ -z "${who:-}" ] || [ "$who" = null ]; then
    echo "$(STAMP) [$PROJECT] #$num not landed this pass: its author and head could not be read (HTTP $(mc_rest_status)) — the lead fence cannot be asked, the entry stays queued" >> "$LOG"
    return 0
  fi
  MQ_LEAD_HEAD="$head"
  to_lane_lead_fence "$PROJECT" "$SLUG" "$num" "$head" "$who" "$LOG"
  [ "$?" = 1 ] || return 0
  MQ_LEAD_CLEARED="$TO_LEAD_CLEARED"   # 1 = a lead PR cleared on this head (to_lane_lead_hold always sets it)
  return 1
}
# <<< lead fence

# hb_blocked <num> — rc 0 when this queue must NOT land this PR on this tick:
#   either the head is NOT the sha the review approved (the entry has been moved
#   aside and paged), or the head could not be READ at all (the entry is left
#   exactly where it is, for the next tick).
#   rc 1 = land it (head matches, no claim, or the kill switch is off).
#   Called BEFORE this queue's own rebase, which rewrites the head by design —
#   that rebase is this lane's mechanical work and rebinds itself below.
#
# AN UNREADABLE HEAD IS NOT A MATCHING HEAD (BH-784). The read used to answer an
# empty string when GitHub refused, and `[ -n "$head" ] && …` then returned 1 —
# "land it" — so a rate limit landed the PR with the reviewed sha never compared.
# Neither merge verb below carries --match-head-commit, which makes this one
# comparison the only thing standing in front of code no reviewer saw, so it
# cannot be skipped on silence. Unreadable: leave the row queued and re-read next
# pass — the same answer bh_held gives to the same silence. Deliberately NOT
# .blocked and NOT paged: a rate limit is not code a reviewer missed, and parking
# the entry would need a hand to put it back.
hb_blocked() {
  local num="$1" sha head hrc
  sha=$(hb_sha "$num"); [ -n "$sha" ] || return 1
  head=$(mq_pr "$num" .head.sha 2>/dev/null); hrc=$?
  if [ "$hrc" != 0 ] || [ -z "$head" ]; then
    # The kill switch downgrades this gate to a log line, and that has to cover
    # the case where it cannot see the head either — or HEADBOUND_ENFORCE=0 would
    # start holding rows, which is the opposite of what it means.
    if [ "${HEADBOUND_ENFORCE:-1}" != 1 ]; then
      echo "$(STAMP) [$PROJECT] #$num head unreadable (gh_rest rc $hrc) — reviewed sha $sha not checked (HEADBOUND_ENFORCE=0 — warn only)" >> "$LOG"
      return 1
    fi
    echo "$(STAMP) [$PROJECT] #$num head read UNVERIFIABLE (gh_rest rc $hrc) — reviewed sha $sha unchecked, left queued this tick" >> "$LOG"
    return 0
  fi
  [ "$sha" != "$head" ] || return 1
  if [ "${HEADBOUND_ENFORCE:-1}" != 1 ]; then
    echo "$(STAMP) [$PROJECT] #$num head $head is not the reviewed sha $sha (HEADBOUND_ENFORCE=0 — warn only)" >> "$LOG"
    return 1
  fi
  mq_park "$num" "head $head is not the reviewed sha $sha"
  echo "$(STAMP) [$PROJECT] #$num head $head is not the reviewed sha $sha — blocked (code no reviewer saw)" >> "$LOG"
  "$HARNESS/bin/beat.sh" "$(jq -nc --arg p "$PROJECT" --arg akey "mq-headbound:$PROJECT:$num" --arg l "Merge queue: #$num head is not the sha the review approved — commits landed after the approval, so nobody has read the code that would merge: https://github.com/$SLUG/pull/$num" '{kind:"fleet_alert",project:$p,akey:$akey,line:$l}')" >/dev/null 2>&1
  return 0
}

# hb_lander_blocked <num> <why> — rc 0 when the LANDER must not run on this PR.
#   bin/lander.sh resolves a conflict by writing code with an agent, and a PR
#   whose approval is bound to a sha would be blocked on that resolution the
#   very next pass. Spending a model call to produce a head we have already
#   decided not to merge is waste with a misleading alert on the end of it, so
#   block here and name the real reason.
hb_lander_blocked() {
  local num="$1" why="$2" sha
  [ "${HEADBOUND_ENFORCE:-1}" = 1 ] || return 1
  sha=$(hb_sha "$num"); [ -n "$sha" ] || return 1
  mq_park "$num" "$why; approval head-bound to $sha, lander skipped"
  echo "$(STAMP) [$PROJECT] #$num $why — lander skipped: the approval is bound to $sha, so an agent-written resolution would be code no reviewer saw" >> "$LOG"
  "$HARNESS/bin/beat.sh" "$(jq -nc --arg p "$PROJECT" --arg akey "mq-hb-lander:$PROJECT:$num" --arg l "Merge queue: #$num $why, and its approval is head-bound ($sha) — the lander was skipped because an agent-written resolution would be code no reviewer saw. Needs a hand: https://github.com/$SLUG/pull/$num" '{kind:"fleet_alert",project:$p,akey:$akey,line:$l}')" >/dev/null 2>&1
  return 0
}

# hb_rebind <num> <sha> — carry a head-bound approval onto a head THIS lane
#   produced by rebasing the reviewed tree onto main and typechecking it. Same
#   rule bin/run-build.sh applies to its own pre-PR rebase and bin/rebase-train.sh
#   to its push: a mechanical rebase is not unreviewed code, and without the
#   rebind the queue would block on the next pass on a head it created itself.
#   Silent when the row makes no head-bound claim (job_verdict_rebind rc 2).
hb_rebind() {
  local num="$1" sha="$2"
  [ -n "$sha" ] || return 0
  type job_verdict_rebind >/dev/null 2>&1 || return 0
  if job_verdict_rebind "https://github.com/$SLUG/pull/$num" "$sha"; then
    echo "$(STAMP) [$PROJECT] #$num approval rebound to the rebased head $sha" >> "$LOG"
  fi
  return 0
}
# <<< head-bound approval

# >>> batch-hold gate
# BH-576. A PR that bin/batch-resolve.sh has put into a live merge-time train is
# landed BY the train and only by it (docs/MERGE-CONDUCTOR.md §15). The
# conductor's pr_worker already skips a held member; this queue is the second
# landing path and bin/merge-sweep.sh the third, and all three must read
# the same marker or a member lands twice: the train's settle then closes a PR
# GitHub already merged, or the train goes red on a phantom conflict. The hold
# is keyed on (PR, head), so a push to the member's branch ends it by
# construction. A FUNCTION, not an inline block, for the same reason hb_blocked
# is: this queue has TWO landing paths and a gate on one of them is not a gate.
# The entry is KEPT — never dropped, never .blocked — so the train's landing or
# a push hands it straight back to this queue.
# FAIL-OPEN on absence: an older lib without mc_batch_held, or no marker, and
# the queue behaves exactly as it did. Marker present but head unreadable is
# HELD: a train owns this PR and nothing proves the head moved.
bh_held() {
  local num="$1" head url; url="https://github.com/$SLUG/pull/$num"
  type mc_batch_held >/dev/null 2>&1 || return 1
  [ -s "$(mc_batch_file "$SLUG" "$num")" ] || return 1
  head=$(mq_pr "$num" .head.sha 2>/dev/null)
  if [ -z "$head" ]; then
    echo "$(STAMP) [$PROJECT] #$num HELD — a batch-hold marker exists and the head could not be read; left to its train: $url" >> "$LOG"
    return 0
  fi
  if TRAINURL=$(mc_batch_held "$SLUG" "$num" "$head"); then
    echo "$(STAMP) [$PROJECT] #$num HELD on ${head:0:8} — this approved head is a member of the batch train ${TRAINURL:-?}; bin/batch-resolve.sh closes it out when the train lands: $url" >> "$LOG"
    return 0
  fi
  return 1
}
# <<< batch-hold gate

# >>> block gate
# bg_queue_hold <num> — rc 0 when a human BLOCK on the thread holds this entry
# (BH-762). BOTH landing paths call it, for the same reason hb_blocked is a
# function: a gate on only the serial path leaves the hole open on the path that
# actually merges. The PR conversation and its review bodies are the sources —
# the projects this queue serves keep their tickets on an in-app board, so there
# is no GitHub issue thread to read.
#
# THE ENTRY IS NOT MOVED ASIDE. Unlike the head-bound block, nothing here needs
# a human to put it back: the hold ends by itself the moment a newer commit
# lands or the blocking author posts UNBLOCK, and the next pass lands it.
bg_queue_hold() {
  local num="$1" url sha out rc
  command -v bg_scan >/dev/null 2>&1 || return 1
  url="https://github.com/$SLUG/pull/$num"
  sha=$(mq_pr "$num" .head.sha 2>/dev/null)
  out=$(bg_scan "$SLUG" "$num" "$url" "${sha:-}"); rc=$?
  [ "$rc" = 0 ] && return 1
  if ! bg_enforce; then
    echo "$(STAMP) [$PROJECT] #$num block gate WARN-ONLY (BLOCK_GATE_ENFORCE=0): $(bg_reason "$rc" "$out" "${sha:-}") — landing as it would have before the gate" >> "$LOG"
    return 1
  fi
  if [ "$rc" = 1 ]; then
    echo "$(STAMP) [$PROJECT] #$num MERGE_REFUSED block-gate: $(bg_why "$out" "${sha:-}") — the entry stays queued and lands when a newer commit arrives or that author clears it" >> "$LOG"
    bg_refuse "$SLUG" "$num" "$url" "${sha:-}" "$out" merge-queue \
      || echo "$(STAMP) [$PROJECT] #$num block gate could not post the refusal comment — the merge is refused either way and the next pass retries the post" >> "$LOG"
  else
    echo "$(STAMP) [$PROJECT] #$num not landed this pass: block gate could not read $out — nothing written, the next pass tries again" >> "$LOG"
  fi
  return 0
}
# <<< block gate

# >>> dep gate
# AN OPEN DECLARED DEPENDENCY HOLDS THE LANDING (BH-629), asked on both landing
# paths for the reason the `:326-333` comment already gives: the batch is
# assembled minutes before it lands.
#
# A WRAPPER RATHER THAN A BARE pdg_queue_hold CALL, and that is the whole point
# of this function: the gate's rc contract is 0 = hold, 1 = pass, 2 = COULD NOT
# READ, and rc 2 must hold. `pdg_queue_hold "$F" && continue` would land the PR
# on rc 2, which is the shape of the incident this gate exists for.
#
# THE ENTRY IS NOT MOVED ASIDE, exactly as the block above: nobody has to put it
# back, the hold ends by itself when the dependency closes and the next pass
# lands it.
dep_queue_hold() { # dep_queue_hold <num> — rc 0 while the entry's declared dependency is open (or unreadable)
  local num="$1" out rc
  command -v pdg_queue_hold >/dev/null 2>&1 || return 1
  out=$(pdg_queue_hold "$num"); rc=$?
  [ "$rc" = 1 ] && return 1
  if [ "$rc" = 0 ]; then
    echo "$(STAMP) [$PROJECT] #$num HELD by the PR-dependency gate: it declares ${out:-a dependency} that is still open — the entry stays queued and lands when that closes" >> "$LOG"
  else
    echo "$(STAMP) [$PROJECT] #$num not landed this pass: the PR-dependency gate could not read its dependency — the entry stays queued" >> "$LOG"
  fi
  return 0
}
# <<< dep gate

# >>> main-red gate
# A RED MAIN FREEZES THIS QUEUE TOO (BH-945). The merge conductor has refused to
# merge into a red main since 2026-09-15, and on 2026-09-18 this lane landed two
# PRs into one anyway — the freeze was private to the conductor and nothing here
# read it. Asked on all three landing paths for the same reason the dep gate is:
# the batch is assembled minutes before it lands, and a main that goes red in
# that window is exactly the one that must stop the merge. Exactly what that
# window covers (BH-987): assembly reads the flag once, and each landing pass
# calls main_red_forget once so its re-ask reads the flag store again — a flag
# raised between assembly and landing HOLDS the member in this same run. A flag
# raised DURING a landing pass is seen by the next pass, not mid-pass: the read
# is one per flag spelling per pass, which is the memo's whole point.
#
# THE ENTRY IS NOT MOVED ASIDE and nothing is recorded: it is waiting for MAIN,
# not for a human. No .blocked file, no MQROW, no beat — the hold ends by itself
# when the flag clears and the next pass lands it.
#
# Asked AFTER the dep gate so a PR held for two reasons logs the earlier one and
# never buys this gate's GitHub read.
mr_queue_hold() { # mr_queue_hold <num> — rc 0 while this repo's main is red and the PR is not exempt
  local num="$1"
  command -v main_red_queue_hold >/dev/null 2>&1 || return 1
  main_red_queue_hold "$num" || return 1
  echo "$(STAMP) [$PROJECT] #$num HELD by the main-red freeze: $SLUG main is red (flags/${MRG_FLAG:-main-red}) — the entry stays queued and lands when the flag clears; a PR labelled ${MC_MAIN_RED_LABEL:-fix-main-red} or one whose whole diff is test files still lands" >> "$LOG"
  return 0
}
# <<< main-red gate

# --- SCALE-PLAN-2 merge train (2026-07-31): with 2+ queued PRs, validate the
# UNION once — merge all branches into one candidate worktree off fresh main,
# typecheck the union, then land members serially (cheap gh merges; the
# expensive validation ran once). A PR whose branch won't merge into the
# candidate drops out to the serial path below. Union typecheck failure falls
# back to the serial per-PR gate, which isolates the culprit.
QUEUED=$(mq_queue_list)
NQ=$(echo $QUEUED | wc -w)
if [ "$NQ" -ge 2 ]; then
  WT=$(mktemp -d /tmp/mqtrain-XXXX)
  if (cd "$REPO_DIR" && git fetch -q origin && git worktree add -f "$WT" origin/main >/dev/null 2>&1); then
    BATCH=""
    # >>> head-bound train members
    for F in $QUEUED; do
      ST=$(mq_pr "$F" '"\(.STATE) \(.head.ref) \(.base.ref)"' 2>/dev/null) || {
        echo "$(STAMP) [$PROJECT] #$F read UNVERIFIABLE (HTTP $(mc_rest_status)) — member skipped this tick" >> "$LOG"; continue; }
      [ "$(cut -d' ' -f1 <<<"$ST")" = "OPEN" ] || continue
      BR=$(cut -d' ' -f2 <<<"$ST")
      BASE=$(cut -d' ' -f3 <<<"$ST")
      if [ "${BASE:-}" != "${BASE_BRANCH:-main}" ] || case "$BR" in train/*) true ;; *) false ;; esac; then
        if [ "${BASE:-}" != "${BASE_BRANCH:-main}" ]; then
          echo "$(STAMP) [$PROJECT] #$F HELD: base is ${BASE:-unknown}, not ${BASE_BRANCH:-main} — left queued" >> "$LOG"
        else
          echo "$(STAMP) [$PROJECT] #$F HELD: head branch $BR starts with train/ — merge-train PRs are never eligible" >> "$LOG"
        fi
        continue
      fi
      # A member of a live batch train (BH-576) never enters the union: the
      # train carries this work already, and a second landing re-dirties every
      # sibling in it. Before hb_blocked, which would otherwise park a held
      # member .blocked and page on a PR this lane does not own.
      bh_held "$F" && continue
      # SDLC item 1 on the BUSY path: a drifted head never enters the union,
      # so it is neither typechecked into the candidate nor landed by the
      # cheap gh merges below.
      hb_blocked "$F" && continue
      mq_lead_hold "$F" && continue   # BH-1606: a lead PR lands only on a lead verdict on this head
      bg_queue_hold "$F" && continue
      dep_queue_hold "$F" && continue
      mr_queue_hold "$F" && continue
      command -v to_lane_hold >/dev/null 2>&1 && to_lane_hold "$PROJECT" "$SLUG" "$F" "$LOG" && continue   # BH-1526: a held ticket's PR does not merge
      if (cd "$WT" && git fetch -q origin "$BR" 2>/dev/null && git merge -q --no-edit FETCH_HEAD >/dev/null 2>&1); then
        BATCH="$BATCH $F"
      else
        (cd "$WT" && git merge --abort >/dev/null 2>&1)
      fi
    done
    # <<< head-bound train members
    NB=$(echo $BATCH | wc -w)
    if [ "$NB" -ge 2 ]; then
      TC=ok
      if (cd "$WT" && jq -e '.scripts.typecheck' package.json >/dev/null 2>&1); then
        (cd "$WT" && [ -d "$REPO_DIR/node_modules" ] && ln -s "$REPO_DIR/node_modules" node_modules 2>/dev/null; NODE_OPTIONS=--max-old-space-size=12288 npm run typecheck >/dev/null 2>&1) || TC=fail
      fi
      if [ "$TC" = ok ]; then
        LANDED=0; LAST_SHA=""
        # >>> train landing
        # One flag-store re-read for this whole pass: drop the memo the assembly
        # loop above filled, so the re-asks below see a freeze raised since then.
        command -v main_red_forget >/dev/null 2>&1 && main_red_forget
        for F in $BATCH; do
          # ASKED AGAIN, HERE, AND NOT ONLY WHERE THE BATCH WAS ASSEMBLED. The
          # union fetch, the merge rounds and the union typecheck above run for
          # minutes on a real repo, and a BLOCK posted inside that window is
          # exactly the one that must land in time — the serial path below
          # re-reads for the same reason. These are the cheap merges: the read
          # costs two API calls against an irreversible push to main.
          mq_lead_hold "$F" && continue   # BH-1606, re-asked: the verdict must stand on the head landed
          bg_queue_hold "$F" && continue
          dep_queue_hold "$F" && continue
          mr_queue_hold "$F" && continue
          command -v to_lane_hold >/dev/null 2>&1 && to_lane_hold "$PROJECT" "$SLUG" "$F" "$LOG" && continue   # BH-1526
          read -r MQST MQSHA < <(mq_land "$F" "${MQ_LEAD_HEAD:-}")
          [ "${MQST:-}" = REFUSED ] && { mq_refused "$F" "${MQSHA%% *}" "${MQSHA#* }"; continue; }
          [ "${MQST:-}" = MERGED ] || sleep 4
          # "landed" is a word this queue may only write off an answer (BH-784):
          # GitHub's own 200 from mq_land, or the REST re-read. An unreadable
          # state here is neither landed nor failed: the row stays exactly where
          # it is and the next pass asks again.
          TST=MERGED; TRC=0
          [ "${MQST:-}" = MERGED ] || { TST=$(mq_pr "$F" .STATE 2>/dev/null); TRC=$?; }
          if [ "$TRC" != 0 ]; then
            echo "$(STAMP) [$PROJECT] #$F landed? read UNVERIFIABLE (HTTP $(mc_rest_status)) — row left queued, re-read next tick" >> "$LOG"
          elif [ "$TST" = "MERGED" ]; then
            rm -f "$Q/$F" "$Q/$F.absent"; MQROW "$F" landed "landed via the merge train"; LANDED=$((LANDED+1))
            LAST_SHA="${MQSHA:-}"
            [ -n "$LAST_SHA" ] || LAST_SHA=$(mq_pr "$F" '.merge_commit_sha // ""' 2>/dev/null)
            echo "$(STAMP) [$PROJECT] #$F LANDED via merge train" >> "$LOG"
          fi
        done
        # <<< train landing
        if [ -n "$LAST_SHA" ]; then
          MQDIR="$HARNESS/builds/mq-$PROJECT-train-$(date -u +%m%d%H%M)"; mkdir -p "$MQDIR"
          "$HARNESS/bin/deploy-request.sh" "$PROJECT" "$SLUG" "$LAST_SHA" "$MQDIR"
        fi
        echo "$(STAMP) [$PROJECT] merge train: $LANDED/$NB landed, union typechecked once" >> "$LOG"
      else
        echo "$(STAMP) [$PROJECT] merge train union typecheck FAILED — serial per-PR gate will isolate it" >> "$LOG"
      fi
    fi
    (cd "$REPO_DIR" && git worktree remove -f "$WT" >/dev/null 2>&1)
  fi
  rm -rf "$WT"
  [ -n "$(mq_queue_list)" ] || exit 0
fi

for F in $(mq_queue_list); do
  NUM="$F"
  # A ROW IS ONLY EVER DEQUEUED ON AN ANSWER (BH-784). This read used to leave
  # STATE empty when GitHub refused, and the branch below then dropped the entry
  # and wrote "dequeued: PR state=" into the ledger — a rate limit turning into a
  # permanent claim about a PR. An unreadable row stays queued and is re-read on
  # the next pass.
  #
  # 404 IS NOT 403, AND NEITHER IS A DEQUEUE. A 404 on a PR this queue is holding
  # means one of three things — the PR was deleted, the repo went invisible to
  # this box's token, or the row was written with a number that never existed —
  # and none of them is knowable from one tick. So the row stays, the consecutive
  # count goes in a side file beside it, and at MQ_ABSENT_ALERT_AFTER this box
  # writes ONE ALERTS line naming the row, because a queue entry nobody can read
  # is exactly the kind of stuck work that otherwise waits for someone to ask.
  # Any answer at all clears the counter.
  ST=$(mq_pr "$NUM" '"\(.STATE) \(.MERGEABLE) \(.head.ref) \(.base.ref)"' 2>/dev/null); MQRC=$?
  if [ "$MQRC" = 44 ]; then
    MQ_N=$(( $(cat "$Q/$F.absent" 2>/dev/null || echo 0) + 1 )); echo "$MQ_N" > "$Q/$F.absent"
    echo "$(STAMP) [$PROJECT] #$NUM ABSENT (HTTP 404) — left queued this tick ($MQ_N consecutive)" >> "$LOG"
    if [ "$MQ_N" -eq "${MQ_ABSENT_ALERT_AFTER:-3}" ]; then
      HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[merge-queue] $PROJECT #$NUM has answered HTTP 404 on $MQ_N consecutive ticks — the queue row $Q/$F is still there and will not land until someone says whether the PR was deleted or the repo is invisible to this box's token: https://github.com/$SLUG/pull/$NUM"
    fi
    continue
  elif [ "$MQRC" != 0 ]; then
    echo "$(STAMP) [$PROJECT] #$NUM read UNVERIFIABLE (HTTP $(mc_rest_status)) — left queued this tick" >> "$LOG"; continue
  fi
  rm -f "$Q/$F.absent"
  STATE=$(cut -d' ' -f1 <<<"$ST"); MERGEABLE=$(cut -d' ' -f2 <<<"$ST"); BR=$(cut -d' ' -f3 <<<"$ST"); BASE=$(cut -d' ' -f4 <<<"$ST")
  if [ "$STATE" != "OPEN" ]; then
    rm -f "$Q/$F" "$Q/$F.absent"; MQROW "$NUM" dropped "dequeued: PR state=$STATE"
    echo "$(STAMP) [$PROJECT] #$NUM dequeued (state=$STATE)" >> "$LOG"; continue
  fi
  # BH-1285: after the not-OPEN dequeue, so a stacked PR that merged into its
  # parent (or was closed) still leaves the queue. A train/* head can never
  # become eligible, so it is dropped; a stacked PR can be retargeted to main
  # later, so it stays queued (a null base reads as "not main": held).
  case "$BR" in train/*)
    rm -f "$Q/$F" "$Q/$F.absent"; MQROW "$NUM" dropped "merge-train PR (train/*) is never eligible for the box queue"
    echo "$(STAMP) [$PROJECT] #$NUM dropped: head branch $BR starts with train/ — merge-train PRs are never eligible" >> "$LOG"; continue ;;
  esac
  if [ "${BASE:-}" != "${BASE_BRANCH:-main}" ]; then
    echo "$(STAMP) [$PROJECT] #$NUM HELD: base is ${BASE:-unknown}, not ${BASE_BRANCH:-main} — left queued" >> "$LOG"; continue
  fi

  # After the not-OPEN dequeue above (a train that landed and closed its member
  # must still leave this queue) and before hb_blocked and the rebase below —
  # rebasing a held member would rewrite the head the train was built from.
  bh_held "$NUM" && continue

  hb_blocked "$NUM" && continue

  # >>> serial lead fence
  # ASKED ONCE, HERE, BEFORE ANYTHING BELOW CAN REWRITE THE BRANCH (BH-1606,
  # #1624 review I2). The rebase + force-push and the lander rounds below write
  # new commits to the PR; done to a lead PR they replace the head the lead is
  # judging, and whatever verdict stands on it dies with it. A held lead PR is
  # therefore left exactly as it is, and a CLEARED one that would need a rewrite
  # is left for the lead: its verdict stands on this head only. MQ_PIN is the
  # head the landing is pinned to — this read, or the head this pass's own
  # rebase produced (only a non-lead PR is ever rebased here).
  mq_lead_hold "$NUM" && continue
  MQ_PIN="${MQ_LEAD_HEAD:-}"
  if [ "${MQ_LEAD_CLEARED:-0}" = 1 ] && [ "$MERGEABLE" = "CONFLICTING" ]; then
    echo "$(STAMP) [$PROJECT] #$NUM lead PR cleared on ${MQ_PIN:0:12} but it conflicts with main — NOT rebased or handed to the lander (a rewrite would void the lead's verdict); left for the lead, the entry stays queued" >> "$LOG"
    continue
  fi
  # <<< serial lead fence

  if [ "$MERGEABLE" = "CONFLICTING" ]; then
    WT=$(mktemp -d /tmp/mq-XXXX); REBASED=no
    (cd "$REPO_DIR" && git fetch -q origin && git worktree add -f "$WT" "origin/$BR" >/dev/null 2>&1) && \
    (cd "$WT" && git checkout -qB "$BR" "origin/$BR" && git rebase -q origin/main >/dev/null 2>&1) && REBASED=yes
    # The head the rebase started from (origin/$BR, which a local rebase does
    # not move) is the push's lease (BH-2504).
    MQ_LEASE=$(git -C "$WT" rev-parse --verify -q "origin/$BR" 2>/dev/null)
    if [ "$REBASED" = yes ]; then
      # Rebase changed history — cheap sanity gate before force-push when available.
      TC=ok
      if (cd "$WT" && jq -e '.scripts.typecheck' package.json >/dev/null 2>&1); then
        (cd "$WT" && [ -d "$REPO_DIR/node_modules" ] && ln -s "$REPO_DIR/node_modules" node_modules 2>/dev/null; NODE_OPTIONS=--max-old-space-size=12288 npm run typecheck >/dev/null 2>&1) || TC=fail
      fi
      if [ "$TC" = ok ]; then
        # Never a plain force (BH-2504): the ticket's hold is re-read at the
        # push, and a branch that moved since the rebase began is not overwritten.
        # shellcheck source=bin/lib/hold-push.sh
        command -v hold_push >/dev/null 2>&1 || . "$(dirname "${BASH_SOURCE[0]}")/lib/hold-push.sh" 2>/dev/null || . "$HARNESS/bin/lib/hold-push.sh" 2>/dev/null
        MQ_PRAT=$(prr_now)
        if [ -n "${MQ_LEASE:-}" ] && HOLD_PUSH_LOG="$LOG" hold_push "$PROJECT" - "$WT" origin "$BR" "$BR" "$MQ_LEASE" 2>/dev/null; then
          prr_note_push "$SLUG" "$NUM" "$MQ_PRAT" "$WT" "$BR" "$MQ_LEASE"
          echo "$(STAMP) [$PROJECT] #$NUM rebased onto main (clean)" >> "$LOG"
          MQ_PIN=$(cd "$WT" && git rev-parse HEAD 2>/dev/null)   # BH-1606: land the head this rebase pushed
          hb_rebind "$NUM" "$MQ_PIN"
        fi
        sleep 8
      else
        (cd "$WT" && git rebase --abort >/dev/null 2>&1)
        if hb_lander_blocked "$NUM" "rebase typecheck FAILED"; then
          (cd "$REPO_DIR" && git worktree remove -f "$WT" >/dev/null 2>&1); rm -rf "$WT"; continue
        fi
        # LANDER (wave 4a+, 2026-08-13): one agent-resolution attempt before a human.
        if "$HARNESS/bin/lander.sh" "$PROJECT" "$NUM" >> "$LOG" 2>&1; then
          echo "$(STAMP) [$PROJECT] #$NUM lander resolved (tc path) — retrying next pass" >> "$LOG"
          (cd "$REPO_DIR" && git worktree remove -f "$WT" >/dev/null 2>&1); rm -rf "$WT"; continue
        fi
        mq_park "$NUM" "rebase typecheck FAILED, lander also failed"
        "$HARNESS/bin/beat.sh" "$(jq -nc --arg p "$PROJECT" --arg akey "mq-tc:$PROJECT:$NUM" --arg l "Merge queue: #$NUM rebase typecheck FAILED (lander also failed) — needs a hand: https://github.com/$SLUG/pull/$NUM" '{kind:"fleet_alert",project:$p,akey:$akey,line:$l}')" >/dev/null 2>&1
        (cd "$REPO_DIR" && git worktree remove -f "$WT" >/dev/null 2>&1); rm -rf "$WT"; continue
      fi
    else
      (cd "$WT" && git rebase --abort >/dev/null 2>&1)
      if hb_lander_blocked "$NUM" "rebase CONFLICTS with main"; then
        (cd "$REPO_DIR" && git worktree remove -f "$WT" >/dev/null 2>&1); rm -rf "$WT"; continue
      fi
      # LANDER (wave 4a+, 2026-08-13): agent merge-resolution before a human.
      if "$HARNESS/bin/lander.sh" "$PROJECT" "$NUM" >> "$LOG" 2>&1; then
        echo "$(STAMP) [$PROJECT] #$NUM lander resolved conflict — retrying next pass" >> "$LOG"
        (cd "$REPO_DIR" && git worktree remove -f "$WT" >/dev/null 2>&1); rm -rf "$WT"; continue
      fi
      mq_park "$NUM" "rebase CONFLICTS with main, lander declined"
      echo "$(STAMP) [$PROJECT] #$NUM rebase CONFLICTS — lander could not resolve, blocked for human" >> "$LOG"
      "$HARNESS/bin/beat.sh" "$(jq -nc --arg p "$PROJECT" --arg akey "mq-conflict:$PROJECT:$NUM" --arg l "Merge queue: #$NUM has a semantic conflict with main (lander attempted and declined) — needs a hand: https://github.com/$SLUG/pull/$NUM" '{kind:"fleet_alert",project:$p,akey:$akey,line:$l}')" >/dev/null 2>&1
      (cd "$REPO_DIR" && git worktree remove -f "$WT" >/dev/null 2>&1); rm -rf "$WT"; continue
    fi
    (cd "$REPO_DIR" && git worktree remove -f "$WT" >/dev/null 2>&1); rm -rf "$WT"
  fi

  # Semantic-staleness gate (2026-08-01, project-3 #173): a PR can be textually
  # MERGEABLE yet type-broken against a main that moved since it branched
  # (TK-45 landed against pre-TK-46 types; Vercel build failed; train rolled
  # back). If main advanced past the branch point, typecheck the UNION before
  # landing. Skipped when the repo has no typecheck script.
  if [ "$MERGEABLE" != "CONFLICTING" ]; then
    (cd "$REPO_DIR" && git fetch -q origin "$BR" 2>/dev/null)
    MB=$(cd "$REPO_DIR" && git merge-base "origin/$BR" origin/main 2>/dev/null)
    MAIN=$(cd "$REPO_DIR" && git rev-parse origin/main 2>/dev/null)
    if [ -n "$MB" ] && [ "$MB" != "$MAIN" ] && (cd "$REPO_DIR" && jq -e '.scripts.typecheck' package.json >/dev/null 2>&1); then
      WTU=$(mktemp -d /tmp/mqu-XXXX); TCU=ok
      (cd "$REPO_DIR" && git worktree add -f "$WTU" origin/main >/dev/null 2>&1) &&       (cd "$WTU" && git merge -q --no-edit "origin/$BR" >/dev/null 2>&1 && { [ -d "$REPO_DIR/node_modules" ] && ln -s "$REPO_DIR/node_modules" node_modules 2>/dev/null; NODE_OPTIONS=--max-old-space-size=12288 npm run typecheck >/dev/null 2>&1; }) || TCU=fail
      (cd "$REPO_DIR" && git worktree remove -f "$WTU" >/dev/null 2>&1); rm -rf "$WTU"
      if [ "$TCU" = fail ]; then
        hb_lander_blocked "$NUM" "union typecheck vs moved main FAILED" && continue
        # BH-1606: the lander writes into the branch — never on a cleared lead PR.
        if [ "${MQ_LEAD_CLEARED:-0}" = 1 ]; then
          echo "$(STAMP) [$PROJECT] #$NUM lead PR cleared on ${MQ_PIN:0:12} fails typecheck against moved main — NOT handed to the lander (a rewrite would void the lead's verdict); left for the lead" >> "$LOG"
          continue
        fi
        # LANDER (wave 4a+): a stale-semantics PR is a conflict in type space.
        if "$HARNESS/bin/lander.sh" "$PROJECT" "$NUM" >> "$LOG" 2>&1; then
          echo "$(STAMP) [$PROJECT] #$NUM lander resolved staleness — retrying next pass" >> "$LOG"
          continue
        fi
        mq_park "$NUM" "union typecheck vs moved main FAILED (stale semantics)"
        echo "$(STAMP) [$PROJECT] #$NUM union typecheck vs moved main FAILED — blocked (stale semantics)" >> "$LOG"
        "$HARNESS/bin/beat.sh" "$(jq -nc --arg p "$PROJECT" --arg akey "mq-stale:$PROJECT:$NUM" --arg l "Merge queue: #$NUM typechecks against ITS base but fails against current main (semantic staleness) — needs a rebase fix: https://github.com/$SLUG/pull/$NUM" '{kind:"fleet_alert",project:$p,akey:$akey,line:$l}')" >/dev/null 2>&1
        continue
      fi
    fi
  fi
  # The thread is re-read here and not only at the top of the loop: this queue's
  # own rebase, typecheck and lander rounds above can take minutes, and a BLOCK
  # posted in the middle of them is exactly the one that must land in time. The
  # main-red memo is dropped for the same reason, so the re-ask below reads the
  # flag store rather than answering from assembly time.
  command -v main_red_forget >/dev/null 2>&1 && main_red_forget
  bg_queue_hold "$NUM" && continue
  dep_queue_hold "$NUM" && continue
  mr_queue_hold "$NUM" && continue
  command -v to_lane_hold >/dev/null 2>&1 && to_lane_hold "$PROJECT" "$SLUG" "$NUM" "$LOG" && continue   # BH-1526
  # Pinned to MQ_PIN (BH-1606): the head the serial lead fence above read, or
  # the one this pass's own rebase pushed. A push by anyone else since is a
  # head nothing here read, and GitHub refuses it.
  read -r MQST MQSHA < <(mq_land "$NUM" "${MQ_PIN:-}")
  [ "${MQST:-}" = REFUSED ] && { mq_refused "$NUM" "${MQSHA%% *}" "${MQSHA#* }"; continue; }
  [ "${MQST:-}" = MERGED ] || sleep 5
  # Same rule as the train above: "still open" is a claim about the PR, and this
  # queue may not make it off a read that did not answer. mq_land's own 200 is
  # an answer; anything else is re-read over REST.
  SST=MERGED; SRC=0
  [ "${MQST:-}" = MERGED ] || { SST=$(mq_pr "$NUM" .STATE 2>/dev/null); SRC=$?; }
  if [ "$SRC" != 0 ]; then
    echo "$(STAMP) [$PROJECT] #$NUM landed? read UNVERIFIABLE (HTTP $(mc_rest_status)) — row left queued, re-read next tick" >> "$LOG"
  elif [ "$SST" = "MERGED" ]; then
    rm -f "$Q/$F" "$Q/$F.absent"
    MSHA="${MQSHA:-}"
    [ -n "$MSHA" ] || MSHA=$(mq_pr "$NUM" '.merge_commit_sha // ""' 2>/dev/null)
    MQROW "$NUM" landed "landed${MSHA:+ as $MSHA}"
    echo "$(STAMP) [$PROJECT] #$NUM LANDED ($MSHA)" >> "$LOG"
    MQDIR="$HARNESS/builds/mq-$PROJECT-pr$NUM"; mkdir -p "$MQDIR"
    [ -n "$MSHA" ] && "$HARNESS/bin/deploy-request.sh" "$PROJECT" "$SLUG" "$MSHA" "$MQDIR"
    sleep 10   # let main + CI settle before the next landing
  else
    echo "$(STAMP) [$PROJECT] #$NUM merge attempt failed (still open) — retrying next pass" >> "$LOG"
  fi
done
command -v mc_reset_token >/dev/null 2>&1 && mc_reset_token
exit 0
