#!/bin/bash
# bin/pr-owner-sweep.sh [--explain] [--repo <owner/repo>] [<project> ...]
#
# EVERY OPEN PR HAS AN OWNER STATE, OR IT IS CLOSED (the operator, 2026-09-15).
#
# bin/orphan-reconcile.sh answers "is every open TICKET being worked". This
# answers the other half, and the fleet had no answer for it at all:
#
#   example-org/project-7 #323, #324, #325, #326, #327 — opened in JUNE
#   example-org/project-7 #359                          — opened in AUGUST
#   example-org/project-1 #630                       — head DIRTY since 2026-08-30
#
# Six of those are harness-authored. Not one has a ledger row, a merge-conductor
# state, a park or a close. Nobody rebases them, nobody closes them, nobody
# reports them — they are simply there, and have been for three months, and no
# log line in this harness has ever mentioned them. The reconciler cannot see
# them either: to IT an open PR is a reason a ticket is owned (owner class (b)),
# so an abandoned PR does not just go unhandled, it actively holds its ticket
# hostage.
#
# A 400-person org has one rule about this, and it is the rule here:
#
#   AN OPEN PR IS EITHER OWNED, EXTERNAL, PARKED WITH AN EXPIRY, OR CLOSED.
#
# THE FOUR CLASSES, decided in this order (docs/PR-OWNERSHIP.md carries the
# same list; the first match wins):
#
#   EXTERNAL — the author is not one of ours (bin/lib/gh-pr-list.sh's author
#              set). That PR belongs to bin/review-prs.sh, which reviews it and
#              posts findings. This lane records it and, while the knob
#              pr_owner.enroll_external is 1, enrolls it (below) — and nothing
#              else: never a comment, never a label, and above all never a close. A
#              sweep that can close a customer's or a contractor's PR because
#              our ledger has no row for it is a sweep that will eventually do
#              exactly that.
#   OWNED    — a live ledger row (queued/claimed/running) for its key, or a
#              merge-conductor row for `<slug>#<num>` in a non-terminal state.
#              Something is building it, or the conductor is landing it. The
#              rows come from po_mc_read (bin/lib/pr-owner/mc-read.sh): the D1
#              pr_state view, or pr-state.tsv only on the conductor's box and
#              only while fresh (BH-5124).
#   PARKED   — a human said "later, and here is when": the `parked` label, or a
#              `Parked: <reason> until YYYY-MM-DD` line in the body. An EXPIRED
#              expiry is not a park — the whole point of writing a date is that
#              the park ends — so it falls through to ORPHAN.
#   ORPHAN   — harness-authored, no owner, no park. The class this lane exists
#              for, and the only one it acts on.
#   UNREAD   — what would be ORPHAN when the conductor's rows could not be
#              read (BH-5124). "No owner" is then not a fact we have, so it is
#              never acted on; one `conductor rows unusable` line per repo says
#              why, and the summary counts it `conductor-unread=`.
#
# WHAT IT DOES WITH AN ORPHAN, at most PR_OWNER_MAX_ACTIONS per repo per run:
#
#   close-duplicate  another PR for the SAME ticket key MERGED AFTER this PR was
#                    opened. The work shipped; this branch is a leftover.
#                    Closed with a comment naming the newest such merge. A PR
#                    opened after every merge of its key is a later part of the
#                    ticket, not a leftover (BH-6717): it falls through to the
#                    arms below and the summary lists it as `spared-later=`.
#                    An unreadable createdAt proves no order, so it closes
#                    nothing.
#                    Only through po_done_close_guard (bin/lib/pr-owner/
#                    shipped.sh): held, armed, recent or not on main stays open.
#   stale-conflict   the head has been CONFLICTING for more than
#                    PR_OWNER_STALE_DAYS. One comment, the `stale-conflict`
#                    label, and the label is the memory: a PR that already
#                    carries it is never commented on again. ONE alert per
#                    repo lists every PR newly labelled this run — never one
#                    alert per PR, which is how an alert channel becomes noise
#                    nobody reads (docs/ALERT-REMEDIATION.md).
#   handback         the ticket is still live and nothing is building it, so
#                    the key goes back to the box that owns the project, the
#                    way bin/blocked-resolver.sh's br_enqueue_fresh does it:
#                    clear the ledgers(kind=commented) row `blocked <project>
#                    <KEY>` (BH-2317; a cleared row outvotes any stamp left on
#                    the box) and the box's next triage tick re-claims the
#                    ticket. When the jobs DB does not take that write,
#                    nothing is handed back: the PR is held
#                    `handback-failed` and the next sweep tries again. A
#                    pool-routed project is held `pool-routed`, a repo with no
#                    fleet project `no-project`; those refusals write nothing
#                    and spend no action (BH-5124).
#
# ENROLL (BH-3933, bin/lib/pr-owner/enroll.sh). An ORPHAN — and an EXTERNAL PR
# when the D1 knob pr_owner.enroll_external is 1 — with no owner gets a
# merge-conductor row: READY when its head is APPROVEd, CI green and clean (the
# `enrolled` attempt row written first), WAIT_CI otherwise. Every READY key of
# the tick goes to ONE keyed conductor run (MC_ONLY_PR), which merges or not on
# its own gates. Only a fleet-wide run enrolls; a --repo run records only.
# OWNERLESS: what is still unowned after the hooks is counted on the lane tick
# (hb_tick), and a repo whose count stays above zero for
# pr_owner.ownerless_alert_hours gets ONE alert (ph_streak, a settings row).
#
# WHAT IT NEVER DOES: merge, push, approve, or close an EXTERNAL PR that has no
# merge-conductor row (the age ladder in bin/lib/pr-owner/stale.sh closes only an
# enrolled one, BH-3935). It is a release-management sweep, not a merger.
#
# FAIL CLOSED, per repo. A gh list that fails, a ledger that cannot be read, a
# repo no token can see: each of those means "we cannot name these PRs' owners",
# and the honest response is to record nothing and act on nothing for that repo
# while the OTHER repos are still swept. A sweep that guesses closes PRs.
#
# STATE: the D1 `pr_owners` rows (repo, number; `closed_at` tombstones) are the
# record of which PRs are owned and since when (BH-5003). The file
# state/pr-owners/<owner_repo>.json is their local mirror and write-behind
# queue: one row per open PR (number, state, since, reason), which is what makes
# "since" mean the first tick this PR read this way rather than "now", plus
# `push_pending:true` while the last PUT of it has not landed. It is written on
# every run, even one that takes no action, and the next PUT is that file.
#   PR_OWNERS_ROWS_RECORD=1 (default): a file entry D1 holds no open row for is
#   dropped before the verdicts, so the file can never resurrect a PR (and its
#   old `since`) that D1 closed. 0 = the pre-BH-5003 `file + fresh rows` merge.
#
# Kill switch: PR_OWNER_SWEEP=0 in env/global.env, or the settings row
#              switch.pr-owner-sweep-off.<box> or switch.pr-owner-sweep-off
#              (1 = off), read by lane_switch (bin/lib/lane-switch.sh);
#              flags/pr-owner-sweep-off decides only when neither row exists.
# Dry run:     PR_OWNER_DRY_RUN=1 — every decision logged, nothing written to
#              GitHub and no marker cleared on any box.
set -uo pipefail
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")
export HARNESS="$H"
[ -f "$H/fleet.conf" ] && export FLEET_CONF="${FLEET_CONF:-$H/fleet.conf}"
mkdir -p "$H/logs" "$H/locks" "$H/state/pr-owners" "$H/flags" 2>/dev/null

EXPLAIN=0; ONLY_REPO=""; ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --explain) EXPLAIN=1 ;;
    --repo)    ONLY_REPO="${2:-}"; shift ;;
    --repo=*)  ONLY_REPO="${1#--repo=}" ;;
    *)         ARGS+=("$1") ;;
  esac
  shift
done

if [ -f "$HENV/global.env" ]; then set -a
  # shellcheck disable=SC1091
  . "$HENV/global.env" 2>/dev/null; set +a; fi
[ "${PR_OWNER_SWEEP:-1}" = 0 ] && exit 0
# shellcheck source=lib/lane-switch.sh
. "$(dirname "$0")/lib/lane-switch.sh" || exit 1
lane_switch pr-owner-sweep-off && exit 0
# BH-3932: the registry's gate (catalog/lanes.d/pr-owner-sweep.json). flags/all-off,
# lane-off-pr-owner-sweep or its D1 pause row stop this run too, and
# lane_env_apply lets a lane.pr-owner-sweep.* row reach the ${KNOB:-} reads below.
# shellcheck disable=SC1091
. "${HARNESS}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit pr-owner-sweep
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    pr-owner-sweep
# THE HOOKS (BH-3932). Each one declines (rc 2) until its own ticket fills it in;
# a missing one is a broken install, so the run stops before anything leaves the box.
# shellcheck source=lib/pr-health.sh
. "$(dirname "$0")/lib/pr-health.sh" || exit 1
# shellcheck source=lib/pr-owner/superseded.sh
. "$(dirname "$0")/lib/pr-owner/superseded.sh" || exit 1
# shellcheck source=lib/pr-owner/dup-guard.sh
. "$(dirname "$0")/lib/pr-owner/dup-guard.sh" || exit 1
# shellcheck source=lib/pr-owner/enroll.sh
. "$(dirname "$0")/lib/pr-owner/enroll.sh" || exit 1
# shellcheck source=lib/pr-owner/stale.sh
. "$(dirname "$0")/lib/pr-owner/stale.sh" || exit 1
# shellcheck source=lib/pr-owner/health.sh
. "$(dirname "$0")/lib/pr-owner/health.sh" || exit 1
# shellcheck source=lib/pr-owner/mc-read.sh
. "$(dirname "$0")/lib/pr-owner/mc-read.sh" || exit 1
# shellcheck source=lib/pr-owner/shipped.sh
. "$(dirname "$0")/lib/pr-owner/shipped.sh" || exit 1
# The PR record first, GitHub on a miss (BH-8270). Without bin/lib/pr-record.sh
# it defines nothing and every read goes to GitHub, as before.
# shellcheck source=lib/pr-owner/prr.sh
. "$(dirname "$0")/lib/pr-owner/prr.sh" || exit 1

command -v jq      >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0
command -v gh      >/dev/null 2>&1 || exit 0

# Every threshold is config with a documented default (CLAUDE.md: no bare
# constants). env/global.env overrides any of them fleet-wide.
num_or() { case "${1:-}" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac; }
STALE_DAYS=$(num_or "${PR_OWNER_STALE_DAYS:-}" 14)   # CONFLICTING for longer than this = stale
GRACE_MIN=$(num_or "${PR_OWNER_GRACE_MIN:-}" 30)     # a PR that JUST moved belongs to the event path
MAX_ACTIONS=$(num_or "${PR_OWNER_MAX_ACTIONS:-}" 5)  # writes per repo per run
PR_LIMIT=$(num_or "${PR_OWNER_PR_LIMIT:-}" 200)      # gh pr list --limit
DRY=$(num_or "${PR_OWNER_DRY_RUN:-}" 0)
# The checkouts po_dup_guard asks `git merge-base --is-ancestor` (BH-6929);
# a repo with no checkout here is compared over REST.
PR_OWNER_REPO_ROOT="${PR_OWNER_REPO_ROOT:-/root/repos}"
# The done-ticket close guard (bin/lib/pr-owner/shipped.sh) reads these three.
PO_DONE_RECENT_MIN=$(num_or "${PR_OWNER_DONE_RECENT_MIN:-}" 120)    # 0 = no recency check
PO_SHIPPED_MAX_FILES=$(num_or "${PR_OWNER_SHIPPED_MAX_FILES:-}" 60)  # more files = unknown, kept
PO_DONE_SKIP_LABELS="${PR_OWNER_DONE_SKIP_LABELS:-hold merge-queue queue-solo fix-main-red}"
# THE ROWS ARE THE RECORD (BH-5003). 1 = a state-file entry with no open D1 row
# is dropped; 0 = the file + fresh-rows merge this lane ran before. Anything
# else is the default, said once in the log rather than silently.
PO_ROWS_RECORD="${PR_OWNERS_ROWS_RECORD:-1}"
PO_ROWS_RECORD_BAD=""
[[ $PO_ROWS_RECORD =~ ^[01]$ ]] || { PO_ROWS_RECORD_BAD="$PO_ROWS_RECORD"; PO_ROWS_RECORD=1; }
# The pr-owners route's own ceiling (worker/jobs/src/routes/pr-owners.js orders
# by number and LIMITs 500). Not a tunable: an answer this long may be cut, so
# a PR missing from it proves nothing and nothing is dropped on it.
PO_D1_ROW_CAP=500
# Repos this fleet owns PRs on that fleet.conf does not list. example-org/project-7
# IS listed (project `project-7`), so this is empty by default and exists for the
# next repo that is ours before it is a project.
EXTRA_REPOS="${PR_OWNER_EXTRA_REPOS:-}"
# The merge conductor's terminal states. Not a threshold — the conductor's own
# vocabulary (docs/MERGE-CONDUCTOR.md); a row in any OTHER state is a live owner.
MC_TERMINAL="MERGED CLOSED ABANDONED"

LOG="$H/logs/pr-owner-sweep.log"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
say() { echo "$(STAMP) $*" >> "$LOG"; }
[ -n "$PO_ROWS_RECORD_BAD" ] && \
  say "PR_OWNERS_ROWS_RECORD='$PO_ROWS_RECORD_BAD' is not 0 or 1 — using the default 1 (rows are the record)"

# THE LOCK IS DEDUPE, NEVER A QUEUE (CLAUDE.md). The hub cron and a box's own
# triage tick can both reach this for the same repo in the same minute; the
# second one does not run, it does not wait.
if command -v flock >/dev/null 2>&1; then
  exec 8>"$H/locks/pr-owner-sweep${ONLY_REPO:+-${ONLY_REPO//\//_}}.lock"
  flock -n 8 || exit 0
fi

# WHOSE PRs ARE OURS — the author SET, never a hardcoded login (bin/lib/
# gh-pr-list.sh: an App-authored PR and a PAT-authored one are both ours).
# shellcheck source=bin/lib/gh-pr-list.sh
[ -r "$H/bin/lib/gh-pr-list.sh" ] && . "$H/bin/lib/gh-pr-list.sh" 2>/dev/null
if command -v harness_pr_authors_csv >/dev/null 2>&1; then
  AUTHORS=$(harness_pr_authors_csv)
else
  say "bin/lib/gh-pr-list.sh missing — cannot tell our PRs from anyone else's, swept nothing"
  exit 0
fi

# Whichever token can SEE each repo. The hub's default PAT 404s on
# example-org/project-5 and example-org/project-7, and an empty PR list there reads
# exactly like a repo with no open PRs (the 2026-09-12 project-5 silence).
# shellcheck source=bin/lib/gh-repo-token.sh
[ -r "$H/bin/lib/gh-repo-token.sh" ] && . "$H/bin/lib/gh-repo-token.sh" 2>/dev/null
# shellcheck source=bin/lib/gh-app-auth.sh
[ -r "$H/bin/lib/gh-app-auth.sh" ] && . "$H/bin/lib/gh-app-auth.sh"   # App token per repo (#425); unarmed box untouched
# shellcheck source=/dev/null
[ -r "$H/bin/jobs-client.sh" ] && . "$H/bin/jobs-client.sh" 2>/dev/null
# The wake backstop (BH-6976): the open and merged lists below are reused while
# no `pr` wake says they changed. OPTIONAL: without it every list is read.
# shellcheck source=bin/lib/wake-backstop.sh
[ -r "$H/bin/lib/wake-backstop.sh" ] && . "$H/bin/lib/wake-backstop.sh" 2>/dev/null
# shellcheck source=bin/lib/comment-mark.sh
[ -r "$H/bin/lib/comment-mark.sh" ] && . "$H/bin/lib/comment-mark.sh"
# Every GitHub WRITE goes through the REST contract (comment, close, label).
# shellcheck source=bin/lib/gh-rest.sh
[ -r "$H/bin/lib/gh-rest.sh" ] && . "$H/bin/lib/gh-rest.sh"
# shellcheck source=bin/lib/heartbeat.sh
[ -r "$H/bin/lib/heartbeat.sh" ] && . "$H/bin/lib/heartbeat.sh"
# The keyed conductor run outlives this sweep, so it must not inherit fd 8 (the
# sweep's dedupe lock): lock_spawn_unheld closes it in the child.
# shellcheck source=bin/lib/lock-hygiene.sh
[ -r "$H/bin/lib/lock-hygiene.sh" ] && . "$H/bin/lib/lock-hygiene.sh"
if ! command -v lock_spawn_unheld >/dev/null 2>&1; then
  lock_spawn_unheld() { [ $# -gt 0 ] || return 0; ( exec 8>&- 9>&-; exec "$@" ) & }
fi
# Where the merge conductor runs (BH-5124). Missing = po_mc_read refuses the file.
# shellcheck source=bin/lib/hub-box.sh
[ -r "$H/bin/lib/hub-box.sh" ] && . "$H/bin/lib/hub-box.sh"

# THE HOOK KNOBS, once per run (BH-3932). The D1 settings row wins, then the env,
# then the default (ph_knob); 0 turns a rung off. The hooks read these vars,
# never the env. A settings outage is one stderr line each, in this lane's log.
PO_STALE_REBASE_H=$(ph_knob pr_stale.rebase_hours PR_STALE_REBASE_HOURS 24 2>>"$LOG")
PO_STALE_REPLAN_D=$(ph_knob pr_stale.replan_days PR_STALE_REPLAN_DAYS 5 2>>"$LOG")
PO_STALE_CLOSE_D=$(ph_knob pr_stale.close_days PR_STALE_CLOSE_DAYS 10 2>>"$LOG")
PO_ENROLL_EXTERNAL=$(ph_knob pr_owner.enroll_external PR_OWNER_ENROLL_EXTERNAL 1 2>>"$LOG")
PO_OWNERLESS_ALERT_H=$(ph_knob pr_owner.ownerless_alert_hours PR_OWNER_OWNERLESS_ALERT_HOURS 24 2>>"$LOG")
# BH-5124: how old the conductor's file may be before po_mc_read refuses it (2 ticks).
PO_MC_MAX_AGE_S=$(ph_knob pr_owner.mc_max_age_s PR_OWNER_MC_MAX_AGE_S 900 2>>"$LOG")
command -v routing_sync_all >/dev/null 2>&1 && { routing_sync_all >/dev/null 2>&1 || true; }

# shellcheck source=bin/lib/gh-budget.sh
[ -r "$H/bin/lib/gh-budget.sh" ] && . "$H/bin/lib/gh-budget.sh" 2>/dev/null

# ONE CLOCK READ PER RUN. Every repo, the classifier and the ownerless clock
# (ph_streak reads PH_NOW, never the clock) see the same second.
# PR_OWNER_NOW pins it when it is all digits (a test seam, like HUB_LEASE_NOW
# and TRIAGE_NOW). Ungated: CI's traced shards run without the sandbox flag,
# which only the two root guards may read (BH-3933 r3).
NOW=$(num_or "${PR_OWNER_NOW:-}" "$(date -u +%s)"); PH_NOW="$NOW"
# Enroll, spawn and the ownerless streak are the fleet-wide run's. A --repo run
# (bin/orphan-reconcile.sh on a box) records only: the conductor and its rows
# live on the hub.
PO_ENROLL_LIVE=0; [ -z "$ONLY_REPO" ] && PO_ENROLL_LIVE=1
PO_DRY="$DRY"; PO_MAX_ACTIONS="$MAX_ACTIONS"; PO_ENROLLED_KEYS=""
# WHO OWNS A PR, ON THE CONDUCTOR'S SIDE (BH-5124): po_mc_read
# (bin/lib/pr-owner/mc-read.sh) reads the D1 pr_state view when the
# pr-state-rows flag is up, else the conductor's pr-state.tsv only on its
# box and only while fresh. OWNER_SRC is the configured source, logged once.
OWNER_SRC=tsv
command -v pr_rows_on >/dev/null 2>&1 && command -v pr_state_page >/dev/null 2>&1 && pr_rows_on && OWNER_SRC=d1
say "owner-source=$OWNER_SRC"
declare -A MC_STATE_OF MC_REASON_OF MC_HEAD_OF MC_SINCE_OF
T_REPOS=0; T_OPEN=0; T_OWNED=0; T_EXT=0; T_ENR=0; T_OWNERLESS=0; T_SUP=0; T_STALE=0

TD=$(mktemp -d) || exit 0
trap 'rm -rf "$TD"' EXIT

# ---- which repos ------------------------------------------------------------
# fleet.conf is the registry (tests/fleet-projects-not-hardcoded-test.sh): a
# project list in here would go quietly wrong the next time the fleet grows.
PAIRS=""   # "<project> <slug>" lines; project "-" for a repo with no project
add_pair() {
  case "$PAIRS" in *" $2"$'\n'*) return 0 ;; esac
  PAIRS="$PAIRS$1 $2"$'\n'
}
if [ -n "$ONLY_REPO" ]; then
  P=$(awk -v s="$ONLY_REPO" '!/^[[:space:]]*(#|$)/ && $2==s {print $1; exit}' \
      "${FLEET_CONF:-$H/fleet.conf}" 2>/dev/null)
  add_pair "${P:--}" "$ONLY_REPO"
else
  if [ "${#ARGS[@]}" -gt 0 ]; then PROJECTS="${ARGS[*]}"
  else PROJECTS=$("$H/bin/fleet-conf.sh" --projects 2>/dev/null); fi
  for P in $PROJECTS; do
    SLUG=$("$H/bin/fleet-conf.sh" "$P" repo 2>/dev/null) || continue
    [ -n "$SLUG" ] && [ "$SLUG" != "-" ] || continue
    add_pair "$P" "$SLUG"
  done
  for SLUG in $EXTRA_REPOS; do add_pair "-" "$SLUG"; done
fi
[ -n "$PAIRS" ] || exit 0

# ---- the actions ------------------------------------------------------------
# STDIN IS CLOSED ON EVERY CHILD IN HERE, and that is not tidiness. The per-repo
# loop below is fed by a here-string, and any child that reads stdin would
# swallow the rest of the fleet's repos: the sweep would end after the repo it
# happened to act on first, silently and differently every run.
# EVERY WRITE IS REST and goes through one of these three, so PR_OWNER_DRY_RUN
# is one decision. rc 0 only when GitHub took the write (gh_rest_close: only when
# a fresh read says closed).
po_comment() { # po_comment <num> <text>
  if [ "$DRY" = 1 ]; then say "DRY-RUN would: comment on $SLUG#$1"; return 0; fi
  command -v gh_rest_comment >/dev/null 2>&1 || return 1
  printf '%s\n' "$2" > "$TD/comment.md" || return 1
  gh_rest_comment "$SLUG" "$1" "$TD/comment.md" >/dev/null 2>&1 </dev/null
}
po_close() { # po_close <num>
  if [ "$DRY" = 1 ]; then say "DRY-RUN would: close $SLUG#$1"; return 0; fi
  command -v gh_rest_close >/dev/null 2>&1 || return 1
  gh_rest_close "$SLUG" "$1" pulls >/dev/null 2>&1 </dev/null
}
po_label() { # po_label <num> <label>
  if [ "$DRY" = 1 ]; then say "DRY-RUN would: label $SLUG#$1 $2"; return 0; fi
  command -v gh_rest >/dev/null 2>&1 || return 1
  gh_rest POST "repos/$SLUG/issues/$1/labels" -f "labels[]=$2" >/dev/null 2>&1 </dev/null
}

# The hand-back, the way bin/blocked-resolver.sh's br_enqueue_fresh does it for a
# box project: the `blocked` row that says "this ticket is finished" is cleared,
# and that is what lets the box's next triage tick re-claim the ticket. A pool
# project's re-offer is a queue row with attempt counters behind it, which is
# the resolver's rung and not this lane's — named, not guessed.
# BH-1372: the routing contract when the client is loaded, the bare file otherwise.
pos_pool_routed() { if command -v routing_builder >/dev/null 2>&1; then [ "$(routing_builder "$1" 2>/dev/null)" = pool ]; else ( . "$H/bin/lib/flag-on.sh" 2>/dev/null || flag_on() { [ -f "$H/flags/$1-$2" ]; }; flag_on fly-pool "$1" ); fi; }
handback() { # handback <project> <key>
  local p="$1" k="$2" box
  [ -n "$k" ] && [ "$k" != "-" ] || return 4
  if [ -z "$p" ] || [ "$p" = "-" ]; then
    say "$k has no fleet project (a PR_OWNER_EXTRA_REPOS repo) — no box owns this key, recorded only"
    return 4
  fi
  if pos_pool_routed "$p"; then
    say "$p/$k: pool-routed — its re-offer is a queue row, which bin/blocked-resolver.sh owns; not handed back here"
    return 3
  fi
  box=$("$H/bin/box-for.sh" "$p" 2>/dev/null) || box=""
  # THE ROW IS THE HAND-BACK (BH-2317): a cleared `blocked` row outvotes any
  # stamp left on the box, and cm_clear also removes this box's own stamps.
  if [ "$DRY" = 1 ]; then say "DRY-RUN would: clear row blocked $p $k"; return 0; fi
  if cm_clear "blocked $p $k" "$H/state/blocked-commented-$p-$k-*" 2>/dev/null; then
    say "$p/$k: cleared row commented 'blocked $p $k' — ${box:-its box}'s stamps no longer count"
    return 0
  fi
  say "$p/$k: row not written; jobs DB unreachable; the hand-back is retried next sweep"
  return 1
}

# ---- the open and merged lists, reused (BH-8270) -----------------------------
# The PR record (bin/lib/pr-record.sh) has no list route and no title, author,
# body or review fields, so the two list reads stay on GitHub, and their last
# answer is reused the bin/orphan-reconcile.sh way (BH-8271). The pair is kept
# in state/pr-owner-sweep/<owner>_<repo>/{openlist,mergedlist}.{json,meta} and
# used instead of a read only while all of these hold: the wake backstop is
# loaded and on, the knob is above 0, both halves are there with one epoch,
# the copy is no older than PR_RECORD_MAX_AGE_S and not stamped in the future,
# and no `pr` wake for ANY PR of the repo arrived since it was read (a feed
# that cannot tell is a read). Every list read logs one `PRR_MISS <repo>#list
# why=<no-row|stale>` line. A title or body edit rings no wake: the knob bounds
# that staleness. wb_gc drops copies older than 3 days.
PL_ON=0
command -v wb_cache_get >/dev/null 2>&1 && command -v wb_cache_put >/dev/null 2>&1 && PL_ON=1
PL_MAX=""
command -v pr_record_max_age >/dev/null 2>&1 && PL_MAX=$(pr_record_max_age 2>/dev/null)
# The knob is PR_RECORD_MAX_AGE_S in catalog/lanes.d/_lib.pr-record.json. Its
# one reader is pr_record_max_age (row, then env, then 900). Fallback only, for
# a box without bin/lib/pr-record.sh: 900, the lib's own default.
[[ "$PL_MAX" =~ ^[0-9]{1,9}$ ]] || PL_MAX=900
PL_MAX=$((10#$PL_MAX))
# wb_due raises a backstop under its floor (WB_FLOOR_S) to the floor and logs
# that once a day, so it is given at least the floor. The age bound that
# counts is PL_MAX, checked before wb_cache_get.
PL_BACK="$PL_MAX"
# WB_FLOOR_S is the lib's constant, not a knob: set whenever PL_ON=1.
[ "$PL_ON" = 1 ] && [[ "${WB_FLOOR_S-}" =~ ^[0-9]+$ ]] && [ "$PL_BACK" -lt "$WB_FLOOR_S" ] && PL_BACK="$WB_FLOOR_S"
[ "$PL_ON" = 1 ] && wb_gc "$H/state/pr-owner-sweep"
po_lists_now() { if command -v _wb_now >/dev/null 2>&1; then _wb_now; else date +%s; fi; }
# po_lists_reuse — rc 0 when $OPENF and $MERGEDF were filled from the copy.
#   Else rc 1: the caller reads GitHub. With PL_ON=1 that miss logs one PRR_MISS
#   line; with no wake backstop no copy is kept, so nothing is missed.
po_lists_reuse() {
  local e now why=stale b
  PL_DIR="$H/state/pr-owner-sweep/${SLUG//\//_}"
  [ "$PL_ON" = 1 ] || return 1
  # WAKE_BACKSTOP=0 makes wb_cache_get answer rc 1, so the switch is a read too.
  if [ "$PL_MAX" -gt 0 ]; then
    e=$(cut -f2 "$PL_DIR/openlist.meta" 2>/dev/null); now=$(po_lists_now)
    if [[ "$e" =~ ^[0-9]{1,12}$ ]] && [ "$((now - 10#$e))" -ge 0 ] && [ "$((now - 10#$e))" -le "$PL_MAX" ] \
       && [ "$(cut -f2 "$PL_DIR/mergedlist.meta" 2>/dev/null)" = "$e" ] \
       && wb_cache_get "$PL_DIR/openlist" "$SLUG" pr - "$PL_BACK" - \
       && cp "$PL_DIR/openlist.json" "$OPENF" 2>/dev/null && [ -s "$OPENF" ] \
       && cp "$PL_DIR/mergedlist.json" "$MERGEDF" 2>/dev/null && [ -s "$MERGEDF" ]; then
      return 0
    fi
  fi
  why=no-row
  for b in openlist.json openlist.meta mergedlist.json mergedlist.meta; do [ -e "$PL_DIR/$b" ] && why=stale; done
  say "PRR_MISS $SLUG#list why=$why"
  return 1
}

# ---- per repo ---------------------------------------------------------------
SWEPT=0
PO_TICK_NOW=$(date -u +%s)   # one clock per run, read by the health rollup
while read -r PROJECT SLUG; do
  [ -n "${SLUG:-}" ] || continue
  if command -v gh_repo_use_token >/dev/null 2>&1; then
    gh_repo_use_token "$SLUG" || {
      command -v gh_repo_invisible_alert >/dev/null 2>&1 &&
        gh_repo_invisible_alert pr-owner-sweep "$SLUG" "its open PRs were not classified — every one of them is unowned as far as this sweep can tell"
      continue; }
  fi

  # Skip non-essential GitHub reads this tick when the API budget is low.
  if command -v gh_budget_low >/dev/null 2>&1; then
    if gh_budget_low pr-owner-sweep >/dev/null 2>&1; then
      continue
    fi
  fi

  command -v gh_auth_for >/dev/null 2>&1 && gh_auth_for "$SLUG" || true
  OPENF="$TD/open.json"; MERGEDF="$TD/merged.json"
  if ! po_lists_reuse; then
    PL_T=$(po_lists_now)
    if ! gh pr list -R "$SLUG" --state open --limit "$PR_LIMIT" \
         --json number,title,headRefName,headRefOid,baseRefName,author,labels,body,mergeable,updatedAt,createdAt,url,isDraft,latestReviews \
         > "$OPENF" 2>/dev/null || [ ! -s "$OPENF" ]; then
      command -v gh_repo_list_failed >/dev/null 2>&1 &&
        gh_repo_list_failed pr-owner-sweep "$SLUG" "no open PR was classified this run"
      continue
    fi
    # The MERGED list is what makes "this ticket already shipped" provable rather
    # than assumed. Same limit: a key merged further back than that is a key whose
    # orphan we simply do not close, which is the safe direction.
    PL_MRC=0
    gh pr list -R "$SLUG" --state merged --limit "$PR_LIMIT" \
      --json number,title,headRefName,url,mergedAt,author > "$MERGEDF" 2>/dev/null || PL_MRC=1
    [ "$PL_MRC" = 0 ] && [ -s "$MERGEDF" ] || { PL_MRC=1; echo '[]' > "$MERGEDF"; }
    # Only a pair that both read rc 0 is kept; a failed merged read is [] for
    # this run only.
    if [ "$PL_MRC" = 0 ] && [ "$PL_ON" = 1 ]; then
      wb_cache_put "$PL_DIR/openlist" "-"$'\t'"$PL_T" < "$OPENF" \
        && wb_cache_put "$PL_DIR/mergedlist" "-"$'\t'"$PL_T" < "$MERGEDF" || true
    fi
  fi

  # THE LEDGER IS OWNER CLASS (a) AND IT IS NOT FAIL-OPEN. A ledger we cannot
  # read is a set of PRs whose owners we cannot name, and the only honest thing
  # to do with those is nothing.
  echo '{"jobs":[]}' > "$TD/jobs.json"; : > "$TD/queue.tsv"
  if [ "$PROJECT" != "-" ]; then
    if ! command -v _jobs_req >/dev/null 2>&1 || ! command -v queue_list >/dev/null 2>&1; then
      say "$SLUG: no jobs client — cannot name any PR's owner, swept nothing"; continue; fi
    if ! JROWS=$(_jobs_req GET "/api/jobs?project=$PROJECT&limit=200" 2>/dev/null); then
      say "$SLUG: jobs ledger unreachable — cannot name any PR's owner, swept nothing"; continue; fi
    printf '%s' "$JROWS" > "$TD/jobs.json"
    if ! QROWS=$(queue_list "$PROJECT" 2>/dev/null); then
      say "$SLUG: build queue unreachable — cannot name any PR's owner, swept nothing"; continue; fi
    printf '%s\n' "$QROWS" > "$TD/queue.tsv"
  fi

  # The conductor's rows for THIS repo, read-only (BH-5124): the D1 view, or
  # state/merge-conductor/pr-state.tsv on the conductor's box while fresh.
  # The third arg gets key, state, reason, head, since for the enroll hook.
  # With the view configured and neither answering, the repo's owners cannot
  # be named: sweep nothing for it (fail closed, BH-3933). Otherwise no PR is
  # OWNED or ORPHAN by the conductor's say-so: the ones with no other owner
  # read UNREAD and nothing acts on them.
  if po_mc_read "$SLUG" "$TD/mc.tsv" "$TD/mc-detail.tsv"; then PO_MC_OK=1; MC_SRC="$PO_MC_SRC"
  elif [ "$OWNER_SRC" = d1 ]; then
    say "$SLUG: conductor rows unreadable (D1 pr_state) — swept nothing (${PO_MC_WHY:-unknown})"; continue
  else PO_MC_OK=0; MC_SRC=unread; : > "$TD/mc-detail.tsv"; fi
  MC_STATE_OF=(); MC_REASON_OF=(); MC_HEAD_OF=(); MC_SINCE_OF=()
  while IFS=$'\t' read -r MK MS MR MH MT; do
    [ -n "$MK" ] && { MC_STATE_OF["$MK"]="$MS"; MC_REASON_OF["$MK"]="${MR:--}"; MC_HEAD_OF["$MK"]="${MH:--}"; MC_SINCE_OF["$MK"]="${MT:--}"; }
  done < "$TD/mc-detail.tsv"

  STATEF="$H/state/pr-owners/${SLUG//\//_}.json"
  [ -f "$STATEF" ] || echo '{}' > "$STATEF"

  # THE D1 ROWS ARE THE RECORD; THIS FILE IS THEIR MIRROR (BH-435, BH-5003).
  # Which PRs are owned is D1's answer: with PR_OWNERS_ROWS_RECORD=1, a full
  # answer (rc 0, under the route's 500-row cap) and the last push landed (no
  # `push_pending`), a file entry survives only when D1 holds an open row for
  # that PR — so a reopened PR, or a stale file bin/restore-merge.sh put back,
  # cannot hand an old `since` to a PR D1 closed. Every other case keeps the
  # merge below exactly as it was: rc 2 (D1 has nothing to say), rc 1 (outage),
  # the cap (PRs past row 500 keep their file clocks), `push_pending` (this
  # file holds a push D1 never took, and its new PRs keep their `since`), knob
  # 0. A D1 row present but stale still keeps its file entry. A row overlays a
  # PR only when the WORKER stamped it at or after OUR LAST PUSH AS THE WORKER
  # RECORDED IT — `synced_as_of`, written below from the answer the PUT came
  # back with. Both sides of that `>=` are then the worker's own clock, which is
  # the only way the comparison means anything: `generated_at` is this BOX's
  # write time, and a box running days ahead of the worker (BH-1042, audit fact
  # #28) threw away every row the worker had just stamped — so a PR another box
  # closed stayed OWNED here forever. `generated_at` is still the fallback for
  # the one tick after an outage, when no worker stamp was ever offered.
  # A file written after a failed PUT is still never reverted by the stale row
  # that PUT did not replace: that file carries the PREVIOUS push's worker
  # stamp (or the GET's), and the row the PUT failed to replace is older still.
  # An absent file is `{}`, both stamps are "", and every row is >= "" — which
  # is exactly the back-fill a rebuilt box wants.
  # rc 1 = outage (one degraded line here, one ALERTS line a day from the
  # client). rc 2 = D1 has no rows for this repo, which is silent and normal.
  if type pr_owners_list >/dev/null 2>&1; then
    pr_owners_list "$SLUG" > "$TD/d1-owners.json" 2>/dev/null
    PO_LIST_RC=$?
    if [ "$PO_LIST_RC" -eq 0 ]; then
      PO_DROP=0
      if [ "$PO_ROWS_RECORD" = 1 ]; then
        PO_D1_N=$(jq -r '(.prs // {}) | length' "$TD/d1-owners.json" 2>/dev/null) || PO_D1_N=""
        PO_PENDING=$(jq -r '.push_pending // false' "$STATEF" 2>/dev/null) || PO_PENDING=""
        if ! [[ $PO_D1_N =~ ^[0-9]+$ ]]; then
          say "$SLUG: pr-owners rows from D1 could not be counted — merge mode, no file-only PR dropped"
        elif [ "$PO_D1_N" -ge "$PO_D1_ROW_CAP" ]; then
          say "$SLUG: pr-owners D1 answered $PO_D1_N rows, the route's $PO_D1_ROW_CAP-row cap — merge mode, no file-only PR dropped"
        elif [ "$PO_PENDING" = true ]; then
          say "$SLUG: pr-owners last push has not landed (push_pending, write-behind) — merge mode, no file-only PR dropped"
        else
          PO_DROP=1
        fi
      fi
      PO_DROPPED=0
      if [ "$PO_DROP" = 1 ]; then
        PO_DROPPED=$(jq -r --slurpfile d1 "$TD/d1-owners.json" '
             (($d1[0] // {}).prs // {}) as $rows
             | [(.prs // {}) | keys[] | select(. as $k | $rows | has($k) | not)] | length' \
           "$STATEF" 2>/dev/null) || PO_DROPPED=0
      fi
      if jq -c --slurpfile d1 "$TD/d1-owners.json" --argjson drop "$PO_DROP" '
             ((.synced_as_of // .generated_at) // "") as $g
             | (($d1[0] // {}).prs // {}) as $rows
             | .prs = ((.prs // {})
                       | if $drop == 1 then with_entries(select(.key as $k | $rows | has($k))) else . end)
                      + ($rows | with_entries(select((.value.updated_at // "") >= $g)))' \
           "$STATEF" > "$TD/owners-merged.json" 2>/dev/null && [ -s "$TD/owners-merged.json" ]; then
        mv -f "$TD/owners-merged.json" "$STATEF"
        [ "${PO_DROPPED:-0}" -gt 0 ] 2>/dev/null && \
          say "$SLUG: pr-owners: $PO_DROPPED file-only PR(s) dropped — D1 holds no open row for them (rows are the record)"
      else
        say "$SLUG: pr-owners rows from D1 could not be merged — using state/pr-owners file alone"
      fi
    elif [ "$PO_LIST_RC" -eq 1 ]; then
      say "$SLUG: pr-owners ledger unreachable — using state/pr-owners file alone (degraded)"
    fi
  fi

  PO_SLUG="$SLUG" PO_PROJECT="$PROJECT" PO_AUTHORS="$AUTHORS" PO_NOW="$NOW" \
  PO_STALE_S="$((STALE_DAYS * 86400))" PO_MC_TERMINAL="$MC_TERMINAL" \
  PO_GRACE_S="$((GRACE_MIN * 60))" PO_MC_OK="$PO_MC_OK" PO_MC_WHY="${PO_MC_WHY:-}" \
  python3 - "$OPENF" "$MERGEDF" "$TD/jobs.json" "$TD/queue.tsv" "$TD/mc.tsv" \
    "$STATEF" "$TD/new-state.json" "$TD/spared-later.txt" > "$TD/verdicts.tsv" <<'PYEOF' 2>/dev/null
import json, os, re, sys
from datetime import datetime, timezone

def load(p, dflt):
    try:
        with open(p) as f:
            return json.load(f)
    except Exception:
        return dflt

prs    = load(sys.argv[1], None)
merged = load(sys.argv[2], [])
jobs   = load(sys.argv[3], {})
prev   = load(sys.argv[6], {})
prev   = prev.get("prs") if isinstance(prev, dict) else {}
if not isinstance(prs, list):
    sys.exit(1)                       # a malformed answer is not an empty repo
if not isinstance(merged, list): merged = []
if not isinstance(prev, dict):   prev = {}   # the state file's own `prs` map

SLUG    = os.environ["PO_SLUG"]
PROJECT = os.environ["PO_PROJECT"]
NOW     = int(os.environ["PO_NOW"])
STALE_S = int(os.environ["PO_STALE_S"])
GRACE_S = int(os.environ["PO_GRACE_S"])
TERMINAL = set(os.environ["PO_MC_TERMINAL"].split())
# BH-5124: 0 = the conductor's rows could not be read from anywhere trustworthy.
MC_OK   = os.environ.get("PO_MC_OK") == "1"
MC_WHY  = os.environ.get("PO_MC_WHY") or "unknown"
# Every spelling of every harness author (app/x, x[bot], x), bare-compared —
# the same stripping bin/lib/gh-pr-list.sh's _hpl_bare does, PREFIX and SUFFIX
# only, because GraphQL, REST and a git author name each pick a different one.
def bare(l):
    v = str(l or "").strip().lower()
    if v.startswith("app/"): v = v[4:]
    if v.endswith("[bot]"):  v = v[:-5]
    return v
OURS = {bare(a) for a in os.environ["PO_AUTHORS"].split(",") if a.strip()}

def ts(s):
    try:
        return int(datetime.strptime(str(s), "%Y-%m-%dT%H:%M:%SZ")
                   .replace(tzinfo=timezone.utc).timestamp())
    except Exception:
        return 0

# THE TICKET KEY OF A PR. THIS IS THE SAME SHAPE bin/blocked-resolver.sh's
# br_key_shape uses (#358, merged 2026-09-15): letters 2-8, a dash, digits 1-6,
# at the FRONT of the last branch segment or of the title, upper-cased, no zero
# stripping. Two lanes that both close PRs must agree on which ticket a PR is,
# or one of them closes the wrong one; that function is not sourceable from a
# script, so the shape is copied deliberately and named here rather than
# reinvented — the day these drift is the day this lane closes somebody's work.
#
# It is deliberately anchored, too. A loose `[A-Z]+-[0-9]+` anywhere in the text
# would read a ticket out of the middle of a title, and a key mid-title is
# usually a reference to a different ticket ("supersedes TK-700"). Anchoring is
# NOT enough on its own, though: the last segment of `fix/utf-8-encoding` is
# `utf-8-encoding`, so this still reads `UTF-8`, and a dependency bump reads
# `VITEST-4` out of `vitest-4.1.2`. KEY only feeds the ORPHAN arms, which touch
# harness-authored PRs alone; the superseded hook's EKEY, which reaches every
# class, is gated on TICKET_PREFIXES below (BH-3936). No key is a fine answer:
# it costs the PR the close-duplicate and hand-back arms and nothing else.
seg_re   = re.compile(r"^([A-Za-z]{2,8})-(\d{1,6})($|[^0-9])")
title_re = re.compile(r"^[\s\[(]*([A-Za-z]{2,8})-(\d{1,6})($|[^0-9])")

def key_of(head, title):
    seg = str(head or "").rstrip("/").split("/")[-1]
    m = seg_re.match(seg) or title_re.match(str(title or ""))
    if not m:
        return "-"
    return "%s-%s" % (m.group(1).upper(), m.group(2))

# ---- the merged keys: proof that a ticket already shipped -------------------
merged_all = {}   # every merged PR per key: close-duplicate and the superseded hook (BH-3936)
for p in merged:
    if not isinstance(p, dict) or "number" not in p:
        continue
    k = key_of(p.get("headRefName"), p.get("title"))
    if k != "-":
        merged_all.setdefault(k, []).append(p)

# ---- the ticket prefixes this repo's own harness PRs use (BH-3936) ----------
# A key whose prefix no harness-authored PR here (open or merged) has ever used
# is a package version or a word, not a ticket, and the superseded hook never
# acts on it: `WRANGLER-3` from a dependabot branch must not close a bump as
# "already shipped", and on an issues board it must not read issue #3. A
# merged PR with no author field counts for nothing, which is the safe side.
def login_of(p):
    a = p.get("author") if isinstance(p.get("author"), dict) else {}
    return a.get("login"), bool(a.get("is_bot"))
TICKET_PREFIXES = set()
for p in merged + prs:
    if not isinstance(p, dict) or bare(login_of(p)[0]) not in OURS:
        continue
    k = key_of(p.get("headRefName"), p.get("title"))
    if k != "-":
        TICKET_PREFIXES.add(k.split("-")[0])

# ---- owner class (a): the ledger --------------------------------------------
LIVE = ("queued", "claimed", "running")
live_keys = {}
for j in (jobs.get("jobs") if isinstance(jobs, dict) else []) or []:
    if not isinstance(j, dict):
        continue
    meta = j.get("meta")
    if isinstance(meta, str):
        try: meta = json.loads(meta)
        except Exception: meta = {}
    if not isinstance(meta, dict): meta = {}
    if str(j.get("status") or "").lower() not in LIVE:
        continue
    for t in {str(j.get("ticket_id") or ""), str(meta.get("key") or "")}:
        if t:
            live_keys.setdefault(t.upper(), "ledger job %s" % (j.get("id") or "?"))
try:
    with open(sys.argv[4]) as f:
        qlines = f.read().splitlines()
except Exception:
    qlines = []
for ln in qlines:
    c = ln.split("\t")
    if len(c) < 8 or c[3].lower() not in LIVE:
        continue
    for t in (c[1], c[2]):
        if t and t != "-":
            live_keys.setdefault(t.upper(), "queue row %s" % c[3])

# ---- owner class (b): the merge conductor's own row for <slug>#<num> --------
mc = {}
try:
    with open(sys.argv[5]) as f:
        for ln in f:
            c = ln.rstrip("\n").split("\t")
            if len(c) >= 2:
                mc[c[0]] = c[1]
except Exception:
    pass

# ---- PARKED: the label, or `Parked: … until YYYY-MM-DD` ---------------------
park_re = re.compile(r"^[\s>*_\-#]*parked\s*:(.*)$", re.IGNORECASE | re.MULTILINE)
date_re = re.compile(r"(\d{4})-(\d{2})-(\d{2})")

def park_of(labels, body):
    """-> (reason, expiry_epoch|0) or None. An EXPIRED expiry is not a park."""
    m = park_re.search(str(body or ""))
    if m:
        d = date_re.search(m.group(1))
        if d:
            exp = ts("%s-%s-%sT23:59:59Z" % d.groups())
            if exp and exp < NOW:
                return None                      # the park ran out — it is an orphan now
            return ("park: %s (expires %s)" % (m.group(1).strip()[:80], "-".join(d.groups())), exp)
        return ("park: %s (no expiry date)" % m.group(1).strip()[:80], 0)
    if "parked" in labels:
        return ("park: `parked` label (no expiry date)", 0)
    if "data-lane-pending" in labels:
        return ("park: data-lane-pending (waits on a migration apply, review-rescue owns it)", 0)
    return None

# STACKED (BH-6814): the open PRs based on each branch. A PR another open PR is
# based on is not a duplicate to close: closing it strands that PR on a branch
# that never merges. A list without baseRefName stacks nothing.
stacked_on = {}
for p in prs:
    b = str(p.get("baseRefName") or "")
    if b:
        stacked_on.setdefault(b, []).append(str(p.get("number")))

rows, out, spared = [], {}, []
for p in sorted(prs, key=lambda x: int(x.get("number", 0) or 0)):
    if not isinstance(p, dict) or "number" not in p:
        continue
    n = int(p["number"])
    sn = str(n)
    labels = {str((l or {}).get("name") or "").lower() for l in (p.get("labels") or [])
              if isinstance(l, dict)}
    author = bare(((p.get("author") or {}) if isinstance(p.get("author"), dict) else {}).get("login"))
    key = key_of(p.get("headRefName"), p.get("title"))
    mergeable = str(p.get("mergeable") or "UNKNOWN").upper()
    pv = prev.get(sn) if isinstance(prev.get(sn), dict) else {}

    state, reason, action = "ORPHAN", "no owner, no park", "none"
    if author not in OURS:
        # EXTERNAL FIRST, unconditionally. bin/review-prs.sh owns these, and no
        # later branch may close, label or comment on one.
        state, reason = "EXTERNAL", "author @%s is not a harness identity — bin/review-prs.sh owns it" % (author or "?")
    elif key != "-" and key.upper() in live_keys:
        state, reason = "OWNED", "ledger:%s" % live_keys[key.upper()]
    elif mc.get("%s#%d" % (SLUG, n)) and mc["%s#%d" % (SLUG, n)] not in TERMINAL:
        state, reason = "OWNED", "conductor:%s" % mc["%s#%d" % (SLUG, n)]
    else:
        park = park_of(labels, p.get("body"))
        moved = max(ts(p.get("updatedAt")), ts(p.get("createdAt")))
        if park:
            state, reason = "PARKED", park[0]
        elif moved and NOW - moved < GRACE_S:
            # GRACE. The event path gets first claim on everything fresh. A PR
            # opened four minutes ago has no conductor row yet because the
            # conductor has not ticked yet, and that is not the same fact as
            # "nobody owns this" — the merge conductor runs every 5 minutes and
            # the build that opened the PR may still be closing its ledger row.
            # This lane is the BACKSTOP, not a competitor, and this window is
            # what keeps it from closing a PR out from under a live lane.
            state = "OWNED"
            reason = "grace: the PR moved %dm ago — the conductor's next tick gets first claim" % ((NOW - moved) // 60)
        elif not MC_OK:
            # UNREAD (BH-5124). No ledger owner, and the conductor's rows could
            # not be read, so "no owner" is not a fact we have. Never acted on.
            state, reason = "UNREAD", "no ledger owner; conductor rows unusable: %s" % MC_WHY

    # DIRTY-SINCE IS REMEMBERED, not recomputed. The first tick that sees a
    # CONFLICTING head with no record of one falls back to updatedAt — which is
    # what makes project-1 #630 (dirty since 2026-08-30) actionable on the
    # first run instead of PR_OWNER_STALE_DAYS after it.
    dirty_since = 0
    if mergeable == "CONFLICTING":
        dirty_since = int(pv.get("dirty_since") or 0) or ts(p.get("updatedAt")) or NOW

    created = ts(p.get("createdAt"))
    if state == "ORPHAN":
        # ALREADY SHIPPED means merged AFTER this PR was opened (BH-6717), the
        # same rule as MERGED_DUP below. #6328 (ticket/bh-6173-r2) was opened 1h46m
        # after #6195 merged BH-6173; it is a later part, not a leftover. The
        # newest such merge is the one named, whatever order gh listed them in.
        keyed = [m for m in merged_all.get(key, [])
                 if int(m.get("number", 0) or 0) != n] if key != "-" else []
        after = [m for m in keyed if created and ts(m.get("mergedAt")) > created]
        dup = max(after, key=lambda m: ts(m.get("mergedAt"))) if after else None
        if keyed and created and not after:
            spared.append(n)
        if dup:
            reason = "superseded: %s already merged in #%s" % (key, dup.get("number"))
            action = "close-duplicate:%s" % dup.get("number")
        elif dirty_since and (NOW - dirty_since) >= STALE_S:
            days = (NOW - dirty_since) // 86400
            reason = "head has been CONFLICTING for %dd (limit %dd)" % (days, STALE_S // 86400)
            action = "none" if "stale-conflict" in labels else "stale-conflict:%d" % days
        elif key != "-":
            reason = "no owner, no park — the key goes back to its box"
            action = "handback:%s" % key

    since = pv.get("since") if pv.get("state") == state and pv.get("since") else \
        datetime.fromtimestamp(NOW, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    # `draft` is RECORDED and never branched on. The one lane that opens a
    # draft (bin/lib/data-lane-pending.sh) labels it data-lane-pending, which
    # park_of reads; any other draft is a human's hand-made branch, and the
    # question this lane asks — who owns it — has the same answer either way.
    # An operator reading the state file wants to know.
    out[sn] = {"number": n, "state": state, "since": since, "reason": reason,
               "key": key, "url": p.get("url") or "", "author": author,
               "draft": bool(p.get("isDraft"))}
    if dirty_since:
        out[sn]["dirty_since"] = dirty_since
    # The hook context (BH-3932) rides as five trailing columns. An empty field
    # is `-`, because IFS=tab collapses empty fields and would shift the rest.
    dash = lambda v: str(v) if v not in (None, "") else "-"
    # BH-3936: four more for the superseded hook, then the branch (BH-3933) and STACKED (BH-6814). EKEY is the branch/title key,
    # else the body's FIRST line read with the same anchored title_re, so an
    # external branch name still resolves and "UTF-8" mid-sentence still cannot.
    # The key must carry a prefix this repo's harness PRs use, and a bot that
    # is not ours (dependabot, renovate) never has one: its branch names are
    # package versions, whatever they happen to spell.
    ekey = key
    if ekey == "-":
        m = title_re.match((str(p.get("body") or "").splitlines() or [""])[0])
        if m:
            ekey = "%s-%s" % (m.group(1).upper(), m.group(2))
    rawl, isbot = login_of(p)
    rawl = str(rawl or "").strip().lower()
    if state == "EXTERNAL" and (isbot or rawl.startswith("app/") or rawl.endswith("[bot]")):
        ekey = "-"
    if ekey != "-" and ekey.split("-")[0] not in TICKET_PREFIXES:
        ekey = "-"
    # MERGED_DUP only for a merge AFTER this PR was opened, and only while no
    # build job for the key is live. A PR opened after its key merged is a
    # reopened ticket's rebuild (same key, nothing mints a fresh one), and a
    # live job is somebody building it right now; neither is a leftover. An
    # unreadable createdAt proves nothing came first, so it closes nothing.
    later = [m for m in merged_all.get(ekey, [])
             if int(m.get("number", 0) or 0) != n and created and ts(m.get("mergedAt")) > created] \
        if ekey != "-" and ekey.upper() not in live_keys else []
    mdup = str(max(later, key=lambda m: ts(m.get("mergedAt"))).get("number")) if later else "-"
    rows.append([str(n), state, action, key, reason, dash(p.get("url")),
                 dash(author), dash(p.get("createdAt")), "1" if p.get("isDraft") else "0",
                 dash(mergeable), dash(p.get("headRefOid")),
                 ekey, mdup, "-", dash(mc.get("%s#%d" % (SLUG, n))),
                 dash(p.get("headRefName")),
                 ",".join(x for x in stacked_on.get(str(p.get("headRefName") or ""), []) if x != sn) or "-"])

# KEEPER (BH-3936, D4): for a key with 2+ open PRs, the one that stays is the
# highest-numbered member the conductor has READY/QUEUED/MERGING, else the
# highest-numbered harness (non-EXTERNAL) member, else the highest-numbered
# member. A PARKED PR is never the keeper: nobody is landing it. Every other
# member is its older duplicate.
groups = {}
for r in rows:
    if r[11] != "-":
        groups.setdefault(r[11], []).append(r)
for g in groups.values():
    cand = [r for r in g if r[1] != "PARKED"]
    if len(g) < 2 or not cand:
        continue
    live = [r for r in cand if r[14] in ("READY", "QUEUED", "MERGING")]
    ours = [r for r in cand if r[1] != "EXTERNAL"]
    keeper = max(live or ours or cand, key=lambda r: int(r[0]))[0]
    for r in g:
        r[13] = keeper

with open(sys.argv[7], "w") as f:
    json.dump({"repo": SLUG, "project": PROJECT,
               "generated_at": datetime.fromtimestamp(NOW, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
               "prs": out}, f, indent=1, sort_keys=True)
# Always written, empty when nothing was spared, so no earlier repo's list
# carries into this repo's summary.
with open(sys.argv[8], "w") as f:
    f.write("".join("%d\n" % x for x in spared))
print("\n".join("\t".join(r) for r in rows))
PYEOF
  PY_RC=$?
  if [ "$PY_RC" -ne 0 ] || [ ! -f "$TD/new-state.json" ]; then
    say "$SLUG: could not classify its open PRs (rc=$PY_RC) — nothing recorded, nothing acted on"
    continue
  fi
  mv -f "$TD/new-state.json" "$STATEF"
  # FILE FIRST, ROW SECOND, STAMP THIRD (bin/merge-sweep.sh's sweep_record
  # shape). The PUT body IS this file, so "stamped in D1 without a file" cannot
  # happen, and a PUT that fails leaves a NEWER file behind — which the
  # overlay's `>=` rule above then protects from the row it did not replace.
  # The worker stamps updated_at; this box never writes it. A dry run mirrors
  # too: withholding the GitHub writes is the point of dry-run, not withholding
  # the record.
  #
  # THE STAMP IS THE DELIVERY'S OWN ANSWER, never a clock. `synced_as_of` is
  # the `as_of` the PUT came back with, so "stamped without delivery" cannot
  # happen either. When the PUT failed but this tick's GET answered, the GET's
  # `as_of` is the next best honest reading of where the worker's clock is
  # (pr_owners_list surfaces it as that payload's `generated_at`). When neither
  # answered — the worker is down — nothing is written and the overlay falls
  # back to `generated_at` for that one tick, exactly as it behaved before
  # BH-1042. The Python above writes a fresh object every run, so a stale
  # `synced_as_of` can never outlive the run that earned it.
  #
  # THE WRITE-BEHIND FLAG (BH-5003). `push_pending:true` is this PUT's real rc
  # (non-zero), never a clock; a PUT that lands removes it. While it is set the
  # overlay above keeps merge mode, because D1 has not seen this file yet.
  if type pr_owners_put >/dev/null 2>&1; then
    PO_PUT_OUT=$(pr_owners_put "$SLUG" "$PROJECT" "$STATEF" 2>/dev/null); PO_PUT_RC=$?
    [ "$PO_PUT_RC" -eq 0 ] || PO_PUT_OUT=""
    PO_AS_OF=$(jq -r '.as_of // empty' <<<"$PO_PUT_OUT" 2>/dev/null) || PO_AS_OF=""
    if [ -z "$PO_AS_OF" ] && [ "${PO_LIST_RC:-1}" -eq 0 ]; then
      PO_AS_OF=$(jq -r '.generated_at // empty' "$TD/d1-owners.json" 2>/dev/null) || PO_AS_OF=""
    fi
    if [ -n "$PO_AS_OF" ]; then
      jq --arg t "$PO_AS_OF" '.synced_as_of = $t' "$STATEF" > "$TD/stamped.json" 2>/dev/null \
        && [ -s "$TD/stamped.json" ] && mv -f "$TD/stamped.json" "$STATEF"
    fi
    if [ "$PO_PUT_RC" -eq 0 ]; then
      jq 'del(.push_pending)' "$STATEF" > "$TD/pending.json" 2>/dev/null \
        && [ -s "$TD/pending.json" ] && mv -f "$TD/pending.json" "$STATEF"
    else
      jq '.push_pending = true' "$STATEF" > "$TD/pending.json" 2>/dev/null \
        && [ -s "$TD/pending.json" ] && mv -f "$TD/pending.json" "$STATEF"
    fi
  fi
  SWEPT=$((SWEPT+1))
  [ "$EXPLAIN" = 1 ] && { printf '# %s\n' "$SLUG"; cat "$TD/verdicts.tsv"; }

  N_OPEN=$(grep -c . "$TD/verdicts.tsv" || true)
  N_OWNED=$(awk -F'\t' '$2=="OWNED"' "$TD/verdicts.tsv" | grep -c . || true)
  N_EXT=$(awk -F'\t' '$2=="EXTERNAL"' "$TD/verdicts.tsv" | grep -c . || true)
  N_PARK=$(awk -F'\t' '$2=="PARKED"' "$TD/verdicts.tsv" | grep -c . || true)
  N_ORPH=$(awk -F'\t' '$2=="ORPHAN"' "$TD/verdicts.tsv" | grep -c . || true)
  N_UNREAD=$(awk -F'\t' '$2=="UNREAD"' "$TD/verdicts.tsv" | grep -c . || true)
  # ONE line per repo per run when the conductor read failed, and no alert: off
  # the conductor's box this is the normal state (docs/ALERT-REMEDIATION.md).
  [ "$PO_MC_OK" = 1 ] ||
    say "$SLUG: conductor rows unusable — ${PO_MC_WHY:-unknown}; $N_UNREAD PR(s) with no ledger owner counted conductor-unread, no orphan action this run"

  CLOSED=""; STALE=""; HANDED=""; HELD=""; N_ACT=0
  PO_ENROLL_N=0; PO_REPO_UNREAD=0; OWNERLESS_NUMS=""
  # UNREAD conductor rows (BH-5124): no owner fact, so no enroll and the
  # ownerless clock neither advances nor resets for this repo.
  [ "$PO_MC_OK" = 1 ] || PO_REPO_UNREAD=1
  R_OWNED=0; R_ENR=0; R_OWNERLESS=0; R_SUP=0; R_STALE=0
  while IFS=$'\t' read -r NUM STATE ACTION KEY REASON URL AUTHOR CREATED DRAFT MERGEABLE HEAD EKEY MERGED_DUP KEEPER MCSTATE BRANCH STACKED; do
    # THE HOOKS (BH-3932), on every PR whatever its class: superseded first (rc 0
    # = it closed the PR, nothing else runs for it), then enroll, stale, health.
    PO_PROJECT="$PROJECT" PO_SLUG="$SLUG" PO_NUM="$NUM" PO_HEAD="$HEAD" PO_AUTHOR="$AUTHOR"
    PO_CLASS="$STATE" PO_KEY="$KEY" PO_CREATED="$CREATED" PO_DRAFT="$DRAFT" PO_MERGEABLE="$MERGEABLE"
    PO_URL="$URL" PO_BRANCH="$BRANCH" PO_GRACE_S="$((GRACE_MIN * 60))"
    PO_MC_STATE="${MC_STATE_OF["$SLUG#$NUM"]:--}"; PO_MC_REASON="${MC_REASON_OF["$SLUG#$NUM"]:--}"
    PO_MC_HEAD="${MC_HEAD_OF["$SLUG#$NUM"]:--}"; PO_MC_SINCE="${MC_SINCE_OF["$SLUG#$NUM"]:--}"
    PO_OWNED=0; [ "$STATE" = OWNED ] && PO_OWNED=1
    PO_EKEY="${EKEY:--}" PO_MERGED_DUP="${MERGED_DUP:--}" PO_KEEPER="${KEEPER:--}" PO_STACKED="${STACKED:--}"
    # The conductor detail map above is the same mc read; its column only fills a gap.
    [ "$PO_MC_STATE" = - ] && PO_MC_STATE="${MCSTATE:--}"
    # The classifier calls every outside author EXTERNAL before it looks at the
    # conductor; a live conductor row still owns that PR — except one the kill
    # switch withdrew, which nothing drives.
    if [ "$STATE" = EXTERNAL ] && [ "$PO_MC_STATE" != - ] && [ "$PO_MC_REASON" != enroll-withdrawn ]; then
      case " $MC_TERMINAL " in *" $PO_MC_STATE "*) ;; *) PO_OWNED=1 ;; esac
    fi
    # stdin closed, as on every child here: a hook that read it would eat the PR list.
    if po_superseded </dev/null 2>>"$LOG"; then R_SUP=$((R_SUP+1)); continue; fi
    [ "$PO_MC_OK" = 1 ] && po_enroll </dev/null 2>>"$LOG" && R_ENR=$((R_ENR+1))
    po_stale </dev/null 2>>"$LOG" && R_STALE=$((R_STALE+1))
    po_health_add </dev/null || true
    # OWNERLESS: no owner after the hooks. PARKED has one (a human, with a date),
    # and an EXTERNAL PR under pr_owner.enroll_external=0 is bin/review-prs.sh's.
    if [ "$PO_OWNED" = 1 ]; then R_OWNED=$((R_OWNED+1))
    elif [ "$STATE" = ORPHAN ] || { [ "$STATE" = EXTERNAL ] && [ "$PO_ENROLL_EXTERNAL" = 1 ]; }; then
      R_OWNERLESS=$((R_OWNERLESS+1)); OWNERLESS_NUMS="${OWNERLESS_NUMS:+$OWNERLESS_NUMS, }#$NUM"
    fi
    [ "$STATE" = ORPHAN ] || continue
    case "$ACTION" in none|'') continue ;; esac
    # An ORPHAN the enroll hook just gave a conductor row is owned now: handing
    # its key back as well would have the box rebuild a ticket being landed.
    case "$PO_OWNED:$ACTION" in 1:handback:*) continue ;; esac
    if [ "$N_ACT" -ge "$MAX_ACTIONS" ]; then HELD="${HELD:+$HELD,}#$NUM:cap"; continue; fi
    case "$ACTION" in
      close-duplicate:*)
        DUP="${ACTION#close-duplicate:}"
        if po_dup_guard </dev/null 2>>"$LOG"; then continue; fi
        # Read-only, so it runs in a dry run too; a skip writes nothing and spends no action.
        PO_OPENF="$OPENF" po_done_close_guard "close-duplicate:#$DUP" </dev/null || continue
        N_ACT=$((N_ACT+1))
        if ! po_comment "$NUM" \
"Closing this one: **$KEY already shipped in #$DUP**, so this branch is a leftover from an earlier attempt at the same ticket.

Nothing here is lost — if something in this diff did not make it into #$DUP, reopen and say so and we will fold it in.

_bin/pr-owner-sweep.sh — every open PR is owned, parked with an expiry, or closed._" \
           || ! po_close "$NUM"; then
          HELD="${HELD:+$HELD,}#$NUM:write-failed"
          say "$SLUG#$NUM: ORPHAN close-duplicate not written (GitHub refused the comment or the close) — retried next sweep"
          continue
        fi
        CLOSED="${CLOSED:+$CLOSED,}#$NUM(dup of #$DUP)"
        say "$SLUG#$NUM: ORPHAN closed — $KEY already merged in #$DUP" ;;
      stale-conflict:*)
        DAYS="${ACTION#stale-conflict:}"
        N_ACT=$((N_ACT+1))
        if ! po_comment "$NUM" \
"This branch has been conflicting with \`main\` for ${DAYS} days and nothing is working it. Labelling it \`stale-conflict\` so it stops being invisible.

Two ways out: push a rebase and it goes back in the normal queue, or add a \`Parked: <reason> until YYYY-MM-DD\` line to the description and this sweep will leave it alone until that date. If neither happens it stays exactly as it is — we will not close a PR out from under you.

_bin/pr-owner-sweep.sh_" \
           || ! po_label "$NUM" stale-conflict; then
          HELD="${HELD:+$HELD,}#$NUM:write-failed"
          say "$SLUG#$NUM: ORPHAN stale-conflict not written (GitHub refused the comment or the label) — retried next sweep"
          continue
        fi
        STALE="${STALE:+$STALE,}#$NUM(${DAYS}d)"
        say "$SLUG#$NUM: ORPHAN labelled stale-conflict — head dirty ${DAYS}d" ;;
      handback:*)
        HK="${ACTION#handback:}"
        # rc 3 pool-routed and rc 4 no project are refusals: nothing was
        # written, so they spend none of PR_OWNER_MAX_ACTIONS (BH-5124).
        handback "$PROJECT" "$HK"
        case $? in
          0) HANDED="${HANDED:+$HANDED,}#$NUM($HK)"
             say "$SLUG#$NUM: ORPHAN — $HK handed back to $PROJECT's box (its next triage tick re-claims the ticket)"
             N_ACT=$((N_ACT+1)) ;;
          3) HELD="${HELD:+$HELD,}#$NUM:pool-routed" ;;
          4) HELD="${HELD:+$HELD,}#$NUM:no-project" ;;
          *) HELD="${HELD:+$HELD,}#$NUM:handback-failed"
             N_ACT=$((N_ACT+1)) ;;
        esac ;;
    esac
  done < "$TD/verdicts.tsv"

  DRYNOTE=""; [ "$DRY" = 1 ] && DRYNOTE=" (DRY RUN — nothing was written)"
  # spared-later: orphans a merge of their key did NOT close, because every
  # such merge came before the PR was opened (BH-6717).
  SPARED=$(sed 's/^/#/' "$TD/spared-later.txt" 2>/dev/null | paste -sd, -)
  say "$SLUG: open=$N_OPEN owned=$N_OWNED external=$N_EXT parked=$N_PARK orphans=$N_ORPH conductor-unread=$N_UNREAD conductor=$MC_SRC closed=${CLOSED:--} stale=${STALE:--} handed-back=${HANDED:--} held=${HELD:--} spared-later=${SPARED:--}$DRYNOTE"
  po_health_flush "$PROJECT" "$SLUG" </dev/null || true
  T_REPOS=$((T_REPOS+1)); T_OPEN=$((T_OPEN+N_OPEN)); T_OWNED=$((T_OWNED+R_OWNED)); T_EXT=$((T_EXT+N_EXT))
  T_ENR=$((T_ENR+R_ENR)); T_OWNERLESS=$((T_OWNERLESS+R_OWNERLESS)); T_SUP=$((T_SUP+R_SUP)); T_STALE=$((T_STALE+R_STALE))
  [ "$R_OWNERLESS" -gt 0 ] && say "$SLUG: ownerless=$R_OWNERLESS ($OWNERLESS_NUMS)"

  # THE OWNERLESS CLOCK, per repo, on the fleet-wide run only. A repo GitHub
  # could not be read for this tick neither advances nor resets it.
  if [ "$PO_ENROLL_LIVE" = 1 ] && [ "$PO_REPO_UNREAD" = 0 ]; then
    OL_ACTIVE=0; [ "$R_OWNERLESS" -gt 0 ] && OL_ACTIVE=1
    if ph_streak "pr-owner-ownerless:$SLUG" "$OL_ACTIVE" "$PO_OWNERLESS_ALERT_H" 2>>"$LOG"; then
      if "$H/bin/lane-alert.sh" --id "pr-owner-ownerless:$SLUG" pr-owner-sweep \
           "$SLUG has had ownerless open PR(s) for ${PO_OWNERLESS_ALERT_H}h+: $OWNERLESS_NUMS. Nothing is building, landing or parking them; owner states are in state/pr-owners/${SLUG//\//_}.json and the rule is docs/PR-OWNERSHIP.md." \
           </dev/null >/dev/null 2>&1; then
        ph_streak_fired "pr-owner-ownerless:$SLUG" 2>>"$LOG" \
          || say "$SLUG: ownerless alert sent but its streak row was not stamped — the --id dedupe holds a repeat"
      fi
    fi
  fi

  # ONE ALERT PER REPO, and only when this run actually did something. A sweep
  # that pages on every quiet tick is a sweep nobody reads — "every PR has an
  # owner" is the normal, silent shape.
  # A duplicate close makes it critical (BH-6929): Telegram now, not the digest.
  DUPCLOSED=$(po_dup_closed); ASEV=()
  [ -n "$DUPCLOSED" ] && ASEV=(--severity critical --id "pr-owner-dup-close:$SLUG:$DUPCLOSED")
  if [ -n "$CLOSED$STALE$HANDED" ] && [ -x "$H/bin/lane-alert.sh" ]; then
    "$H/bin/lane-alert.sh" ${ASEV[@]+"${ASEV[@]}"} "pr-owner-sweep/$SLUG" \
      "$SLUG had $N_ORPH open PR(s) with no owner state.${DUPCLOSED:+ Closed as duplicate: $DUPCLOSED. Each PR got a comment that says to reopen it if it has something the other PR does not, and a reopen stops the sweep for that PR.}${CLOSED:+ Closed (shipped elsewhere or superseded): $CLOSED.}${STALE:+ Labelled stale-conflict (head conflicting past ${STALE_DAYS}d, one comment each): $STALE.}${HANDED:+ Key handed back to the box: $HANDED.}${HELD:+ Held back: $HELD.} Owner states are in state/pr-owners/${SLUG//\//_}.json; the rule is docs/PR-OWNERSHIP.md." \
      >/dev/null 2>&1 || true
  fi
  command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset
done <<< "$PAIRS"

[ "$SWEPT" = 0 ] && say "swept no repo this run (nothing visible, or every ledger read failed)"
command -v hb_tick >/dev/null 2>&1 && hb_tick pr-owner-sweep \
  "repos=$T_REPOS open=$T_OPEN owned=$T_OWNED external=$T_EXT enrolled=$T_ENR ownerless=$T_OWNERLESS superseded=$T_SUP stale_rungs=$T_STALE"
# ONE keyed conductor run per tick for every PR enrolled READY. It merges or not
# on its own gates; a spawn that never ran is the backstop's (READY rows with
# head = reviewed, every 5 minutes).
if [ -n "$PO_ENROLLED_KEYS" ] && [ "$PO_ENROLL_LIVE" = 1 ]; then
  MC_ONLY_PR="$PO_ENROLLED_KEYS" lock_spawn_unheld timeout 240 "$H/bin/merge-conductor.sh" \
    </dev/null >>"$H/logs/merge-conductor-cron.log" 2>&1
  say "keyed conductor run spawned: $PO_ENROLLED_KEYS"
fi
exit 0
