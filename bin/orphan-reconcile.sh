#!/bin/bash
# bin/orphan-reconcile.sh <project> [--explain]
#
# EVENTS ARE HINTS, RECONCILIATION IS TRUTH (the operator, 2026-09-15).
#
# Every launch path in this harness is EDGE-TRIGGERED. A ticket becomes
# buildable because something named it: a webhook wrote its key into
# state/wake-keys-<project>, a board diff carried its line, a close-out in a
# sweep released its child. Each of those is a message, and a message that is
# never sent is indistinguishable from a board with nothing on it. On
# 2026-09-15 three project-5 tickets sat for hours for exactly that reason:
#
#   #670 closed -> #671 was never keyed into a wake, so no tick ever scoped it
#   #719 merged -> #721 was never re-scoped, so nothing re-read its thread
#   PR #1045 went red -> nobody re-kicked TK-989
#
# and through all of it the box logged `rc=skip :: gate no-change (103 tickets)`
# every ten minutes, which was TRUE: nothing had changed since the last consumed
# tick. The gate answers "did the board move"; nobody was answering "is every
# open ticket actually being worked".
#
# This script answers that, from scratch, every tick. It holds no state about
# what it decided last time (beyond a grace marker, below), reads no diff, and
# trusts no event: it lists the OPEN ai-build issues and, for each one, names
# its OWNER. An issue with no owner is an ORPHAN and is enqueued.
#
# THE OWNER RULE (docs/EVENTS.md §5.4 carries this verbatim). An open ai-build
# issue has exactly ONE owner, and it is the first of these that matches:
#
#   (a) LEDGER   — a job or queue row for its key in status queued/claimed/
#                  running. Something is building it right now. A row that says
#                  `running` but stopped beating is NOT this script's problem:
#                  bin/jobs-watchdog.sh flips it to failed within JOBS_ORPHAN_MIN
#                  minutes, and the next pass through here then sees the ticket
#                  with no owner and launches it. Two scripts, one fact each.
#   (b) PR       — an OPEN pull request whose head branch, title or closing
#                  keyword carries its key — including the FULL child key the
#                  ISSUE's own title LEADS with (`TK-2416.0: ...` on a decompose
#                  child; its PR never carries the issue number). Only the
#                  leading key counts: a title that merely MENTIONS another
#                  ticket's key (`TK-910: follow-up to TK-902`) is not owned by
#                  that ticket's PR. An open PR means the
#                  merge conductor owns it, whatever state that PR is in: red
#                  CI, a provenance hold and a clean green all read the same
#                  here, because all three are the conductor's job and none of
#                  them is a reason to build the ticket a second time.
#   (c) BLOCKER  — an open `Blocked-by: #M` parent, or an open CHILD that names
#                  it in a `Part of #N` line. A decompose parent whose children
#                  are open is owned BY its children and is never launchable.
#   (d) HOLD     — a human said not yet, and THE NEWEST WORD IN THE THREAD WINS:
#                  the first decisive comment walking backwards decides (a lift
#                  — `RESUME`/`UNHOLD`/"hold lifted" — clears it, `HOLD` holds
#                  it), and only when no comment decides do the title, the body
#                  and a hold/on-hold label get a say. project-5 #14 (title) and
#                  #887/#888 (a comment from the operator) are today's.
#                  The reading is bin/lib/hold.sh's hold_classify — the one
#                  bin/run-build.sh refuses by — so bot comments never decide
#                  and the `hold` label holds (2026-09-27).
#   (f) REFUSED  — not an owner, a guard rail at launch: a ticket run-build
#                  would answer SKIP_ABANDONED for (the `abandoned` ledger row,
#                  or the queue row's ABANDONED reason), or one the resolver
#                  resolved as already merged, is skipped and named in the run
#                  summary. Launching it only made a BUILD_REFUSED record, and
#                  that record moved bin/triage-gate.sh's queue fingerprint.
#   (e) GRACE    — an owner that ended less than ORPHAN_GRACE_MIN (default 12)
#                  minutes ago: a terminal ledger row, a blocker that just
#                  closed, board activity on the thread itself, or this
#                  script's own enqueue marker. The event path gets first claim
#                  on everything fresh; reconciliation is the BACKSTOP, not a
#                  competitor, and this window is what keeps the two from
#                  launching the same build twice.
#
# Cheap by construction: three REST list reads, two ledger reads, no model call,
# and no per-issue read except the two the classifier ASKS for — a blocker the
# ai-build list does not carry (the de-labelled decompose parent, project-5
# #667) and the comment thread of an issue that is still ownerless after the
# ledger and the PR list have had their say. It can run on every tick.
#
# EVERY GITHUB READ HERE IS REST (BH-1163), through bin/lib/gh-rest.sh and its
# rc 0/44/75 contract. `gh issue list`, `gh issue view` and `gh pr list` speak
# GraphQL and draw on the 5000/h bucket the whole hub shares — the bucket that
# emptied on 2026-09-18 (#768) and made the dependency gate read silence as
# fact. This file runs on EVERY tick of every GitHub-Issues project, so it was
# the hottest spender on the bucket with no headroom. The marker line below
# `set -uo pipefail` opts this file into
# tests/gh-no-graphql-decision-guard-test.sh, which keeps those three verbs out
# of here from now on.
#
# THE CLASSIFIER RUNS TWICE, and that is what makes the REST conversion cheap.
# `gh issue list --json comments` returned every comment BODY in one GraphQL
# answer; REST's list gives a comment COUNT. Fetching every open issue's thread
# would be ~76 extra reads a tick on a board this size, so pass 1 (`needs`)
# runs owner classes (a) and (b) and prints what it cannot decide without
# another read; bash fetches exactly those, capped; pass 2 (`decide`) reads the
# answers off disk. Pass 1 deliberately skips class (c) so its need set is a
# SUPERSET of pass 2's — a thread nobody asked for is a thread pass 2 cannot
# read, and an unread thread parks a ticket (below).
#
# FAIL CLOSED, NOT FAIL OPEN, and that is the opposite of most scripts here. A
# list read that answers 44 or 75, a ledger that cannot be reached, a project
# whose key prefix cannot be read: every one of those means "we do not know who
# owns these tickets", and the honest answer to that is to enqueue NOTHING and
# say so. The two per-issue reads fail closed the same way — an unreadable
# blocker reads OPEN, and an issue whose thread could not be read is OWNED
# (`unverifiable:thread`) rather than launched under a HOLD nobody could see.
# A reconciler that guesses storms the pool.
#
# Kill switch: ORPHAN_RECONCILE=0 in env/global.env, or flags/orphan-reconcile-off (or the `switch.orphan-reconcile-off` settings row).
# Launches: no cap by default (the operator, unlimited concurrency, 2026-10-11). Every
#       ownerless ticket launches in the run that finds it. ORPHAN_MAX_PER_RUN
#       (unset = no cap; 0 = launch none) is a brake an operator may set, not a
#       running limit. The old default of 5 named 34 tickets `:cap` in 24 h.
#       STRANDED_MAX_PER_RUN (the stranded-watch lane row, default 0 = no cap)
#       is the same brake for --stranded.
# Read caps (GitHub quota, kept): ORPHAN_BLOCKER_FETCH_MAX (default 20) blocker
#       reads, ORPHAN_THREAD_FETCH_MAX (default 200, a settings row since
#       BH-8497) comment-thread reads. They bound one tick's REST reads on a
#       board that has gone quiet everywhere. A thread the bound cuts is read
#       on the next run (the thread cursor), and a cut writes one ALERT a day.
#
# GitHub-Issues boards only (board_prefix "-" in fleet.conf): the in-app boards
# have no `ai-build` label and no Blocked-by convention. Never merges, never
# comments, never closes anything.
#
# gh-rest: no-graphql
set -uo pipefail
# THE STRANDED WATCH (BH-5967) is this same owner rule run from the hub, one run
# per project on the shared lane runner (bin/stranded-watch.sh, BH-5913), as
# `orphan-reconcile.sh --stranded <project>`. Three things differ, and nothing
# else: the grace window is STRANDED_IDLE_MIN (default 60: no build attempt in
# the last hour), the launch is a fresh queue row (queue_put, never a build on
# the hub), and every re-offer is counted. A ticket re-offered
# STRANDED_REOFFER_MAX times (default 3) in STRANDED_REOFFER_WINDOW_H hours
# (default 24) with no PR gets a NEEDS-HUMAN: marker (bin/needs-human-hold.sh)
# instead of a fourth row. On 2026-10-10 the triage-tick reconcile found 34
# orphans every tick and launched none: each was held back as
# awaiting-closeout by a QUEUED_FLY routing stub nothing ever closes.
# The fourth difference (BH-7116): a ticket whose queue row says its last build
# ended PLAN_BLOCKED, with no human comment created or edited since, is skipped
# as `<KEY>:plan-blocked` (bin/lib/plan-blocked.sh pb_stranded_skip). It is not
# counted toward NEEDS_HUMAN: the builder's notice on the ticket is the ask.
# STRANDED_SKIP_PLAN_BLOCKED=0 (the lane row) re-offers it as before. On
# 2026-10-16 the watch re-offered eight such tickets 2-6 times each.
EXPLAIN=0; STRANDED_MODE=0; PROJECT=""
for _arg in "$@"; do
  case "$_arg" in
    --explain)  EXPLAIN=1 ;;
    --stranded) STRANDED_MODE=1 ;;
    *)          [ -n "$PROJECT" ] || PROJECT="$_arg" ;;
  esac
done
unset _arg
[ -n "$PROJECT" ] || { echo "usage: orphan-reconcile.sh [--stranded] <project> [--explain]" >&2; exit 2; }
HARNESS="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s
' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$HARNESS")
# Lock hygiene (BH-651): this script runs INSIDE a triage tick, so it inherits
# the tick's per-project flock on fd 9, and it takes its own reconcile lock on
# fd 8 below. Both detached children here (run-build.sh, pr-owner-sweep.sh)
# outlive the tick, so they are spawned through lock_spawn_unheld, which closes
# fd 8 and fd 9 in the child before it execs. The fallback keeps a box that has
# not received bin/lib/lock-hygiene.sh yet closing the fds all the same.
# shellcheck source=bin/lib/lock-hygiene.sh
[ -r "$HARNESS/bin/lib/lock-hygiene.sh" ] && . "$HARNESS/bin/lib/lock-hygiene.sh"
if ! command -v lock_spawn_unheld >/dev/null 2>&1; then
  lock_spawn_unheld() { [ $# -gt 0 ] || return 0; ( exec 8>&- 9>&-; exec "$@" ) & }
fi
LOG="$HARNESS/logs/$PROJECT.log"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
log() { echo "$(STAMP) [$PROJECT] $*" >> "$LOG"; }

mkdir -p "$HARNESS/logs" "$HARNESS/locks" 2>/dev/null

# Its own switch read, not an inherited environment: this runs from a tick, by
# hand and from the fixtures.
if [ -f "$HENV/global.env" ]; then set -a
  # shellcheck disable=SC1091
  . "$HENV/global.env" 2>/dev/null; set +a; fi
# The stranded watch's knobs are its lane's settings rows (BH-5967). Applied
# after the env file, which would otherwise re-assign any name it carries.
if [ "$STRANDED_MODE" = 1 ]; then
  [ -r "$HARNESS/bin/lib/lane-gate.sh" ] && . "$HARNESS/bin/lib/lane-gate.sh" 2>/dev/null
  command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply stranded-watch
fi
[ "${ORPHAN_RECONCILE:-1}" = 0 ] && exit 0
command -v lane_switch >/dev/null 2>&1 || . "$(dirname "${BASH_SOURCE[0]}")/lib/lane-switch.sh" 2>/dev/null || lane_switch() { [ -e "${HARNESS:-${H:-/root/harness}}/flags/$1" ]; }
lane_switch orphan-reconcile-off file && exit 0

GRACE_MIN="${ORPHAN_GRACE_MIN:-12}"
case "$GRACE_MIN" in ''|*[!0-9]*) GRACE_MIN=12 ;; esac
# Empty MAX_RUN = no cap.
MAX_RUN="${ORPHAN_MAX_PER_RUN:-}"
case "$MAX_RUN" in *[!0-9]*) log "reconcile: ORPHAN_MAX_PER_RUN='$MAX_RUN' is not a whole number; no launch cap"; MAX_RUN="" ;; esac
BLOCKER_FETCH_MAX="${ORPHAN_BLOCKER_FETCH_MAX:-20}"
case "$BLOCKER_FETCH_MAX" in ''|*[!0-9]*) BLOCKER_FETCH_MAX=20 ;; esac
# The comment threads pass 1 may ask for. Only issues with no ledger row, no
# open PR and at least one comment ever reach this, so on a healthy board it is
# a handful; the cap is what stops a board that has gone quiet everywhere from
# turning one tick into hundreds of reads. Past the cap a ticket is OWNED, not
# launched — the fail-closed direction.
# The bound is the settings row lib.orphan-reconcile.<project>.orphan_thread_fetch_max
# (then lib.orphan-reconcile.orphan_thread_fetch_max), env ORPHAN_THREAD_FETCH_MAX,
# registered in catalog/lanes.d/_lib.orphan-reconcile.json (BH-8497). Code
# fallback 200: one project-6 board (131 open ai-build, 2026-10-26) fits in one
# run. Past the bound, the thread cursor (below) reads the rest on the next run.
# Resolved in a subshell, so a fail-closed exit there never stops this lane.
_OR_TFM=$(
  exec 3>&1
  trap 'printf "%s" "${ORPHAN_THREAD_FETCH_MAX:-}" >&3' EXIT
  command -v lib_env_apply >/dev/null 2>&1 || . "$HARNESS/bin/lib/lane-gate.sh" >/dev/null 2>&1 || exit 0
  lib_env_apply orphan-reconcile "$PROJECT" >/dev/null 2>&1)
THREAD_FETCH_MAX="${_OR_TFM:-200}"
case "$THREAD_FETCH_MAX" in ''|*[!0-9]*) THREAD_FETCH_MAX=200 ;; esac
unset _OR_TFM
if [ "$STRANDED_MODE" = 1 ]; then
  GRACE_MIN="${STRANDED_IDLE_MIN:-60}"
  case "$GRACE_MIN" in ''|*[!0-9]*) GRACE_MIN=60 ;; esac
  # The lane row's 0 (its default) is no cap.
  MAX_RUN="${STRANDED_MAX_PER_RUN:-0}"
  case "$MAX_RUN" in
    ''|0) MAX_RUN="" ;;
    *[!0-9]*) log "stranded-watch: STRANDED_MAX_PER_RUN='$MAX_RUN' is not a whole number; no cap"; MAX_RUN="" ;;
  esac
  REOFFER_MAX="${STRANDED_REOFFER_MAX:-3}"
  case "$REOFFER_MAX" in ''|*[!0-9]*) REOFFER_MAX=3 ;; esac
  REOFFER_WIN_H="${STRANDED_REOFFER_WINDOW_H:-24}"
  case "$REOFFER_WIN_H" in ''|*[!0-9]*) REOFFER_WIN_H=24 ;; esac
  SKIP_PB="${STRANDED_SKIP_PLAN_BLOCKED:-1}"
  case "$SKIP_PB" in
    0|1) ;;
    *) log "stranded-watch: STRANDED_SKIP_PLAN_BLOCKED='$SKIP_PB' is not 0 or 1; read as 1"; SKIP_PB=1 ;;
  esac
fi

command -v jq >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0
# The classifier below is written to $TD and RUN BY PATH, so this file is a
# python call site under the BH-1138 rule (tests/pycache-untracked.bh-1138-test.sh
# finds it by that property, not from a list) and carries the export itself.
export PYTHONDONTWRITEBYTECODE=1

# THE BOARD HAS TO BE GITHUB ISSUES. Same reading bin/triage-gate.sh and
# bin/unblocked-children.sh make: board_prefix "-" IS the marker.
# This is the in-app no-op guard (BH-411): in-app product boards are gated at
# dispatch time by bin/triage-gate.sh --buildable, so this reconciler never
# needs to enqueue them. If that ever changes, gate each orphan here too.
#
# AND THE NO-OP IS NOT A GAP — IT HAS AN OWNER (BH-815). On an in-app board a
# master does not need finding: the board itself carries the edge, as
# `children[]` on the parent and `dependsOn` / `blocked` on the child
# (docs/BOARD-API-CONTRACT.md, "Dependencies"). So the three jobs this script
# does for GitHub are already done elsewhere there, and doing them twice would
# be two lanes racing one ticket:
#   * "is this child held?" is bin/triage-gate.sh --buildable, which answers
#     BLOCKED dependencies <keys> while any dependency is unfinished;
#   * "has it been released?" is the fingerprint diff, named into the tick's
#     scope by the `# >>> inapp dependency release` block of bin/run-triage.sh;
#   * "who closes the master?" is the in-app lane of
#     bin/decompose-parent-close.sh, once every child is done.
# So: do NOT "fix" this no-op into a launcher. An orphan on an in-app board is
# either already gated or already scoped, and a reconciler that enqueued it
# would be launching work the gate is holding on purpose.
REPO="${GH_ISSUES_REPO:-}"
if [ -z "$REPO" ]; then
  BP=$("$HARNESS/bin/fleet-conf.sh" "$PROJECT" board_prefix 2>/dev/null || true)
  [ "$BP" = "-" ] || exit 0
  REPO=$("$HARNESS/bin/fleet-conf.sh" "$PROJECT" repo 2>/dev/null || true)
fi
[ -n "$REPO" ] && [ "$REPO" != "-" ] || exit 0

# THE LOCK IS DEDUPE, NEVER A QUEUE (the operator, 2026-09-13). Two ticks reconciling
# one project in the same instant would both see the same orphan and both
# enqueue it; the second one simply does not run.
if command -v flock >/dev/null 2>&1; then
  exec 8>"$HARNESS/locks/orphan-reconcile-$PROJECT.lock"
  flock -n 8 || exit 0
fi

# preplan_key_prefix: the KEY a build is filed under is <PREFIX>-<issue-number>,
# and the prefix lives in prompts/<project>.md (`TK-<issue-number>`). Without it
# every lookup below would be against a name nothing else uses, so no prefix is
# a clean exit, not a guess.
# shellcheck source=bin/lib/preplan-lib.sh
[ -r "$HARNESS/bin/lib/preplan-lib.sh" ] && . "$HARNESS/bin/lib/preplan-lib.sh" 2>/dev/null
command -v preplan_key_prefix >/dev/null 2>&1 || exit 0
PFX=$(preplan_key_prefix "$HARNESS" "$PROJECT" 2>/dev/null) || exit 0
[ -n "$PFX" ] || exit 0

# THE HOLD VOCABULARY, shared with bin/blocked-resolver.sh (bin/lib/hold.sh):
# the same three regexes, exported into the classifier's environment below, so
# "what counts as a hold" cannot drift between the two lanes that re-enqueue
# builds. A box mid-sync without the lib falls back to the literals the
# classifier has always used — see the os.environ.get defaults.
# shellcheck source=bin/lib/hold.sh
[ -r "$HARNESS/bin/lib/hold.sh" ] && . "$HARNESS/bin/lib/hold.sh" 2>/dev/null
# shellcheck source=bin/lib/closeout-overdue.sh
[ -r "$HARNESS/bin/lib/closeout-overdue.sh" ] && . "$HARNESS/bin/lib/closeout-overdue.sh" 2>/dev/null
# The stranded watch's PLAN_BLOCKED skip (BH-7116). Optional: without it the
# watch re-offers exactly as before.
# shellcheck source=bin/lib/plan-blocked.sh
[ -r "$HARNESS/bin/lib/plan-blocked.sh" ] && . "$HARNESS/bin/lib/plan-blocked.sh" 2>/dev/null

# Whichever token can SEE this repo (the hub's default PAT 404s on
# example-org/project-5, and an empty issue list there reads exactly like a board
# with nothing on it).
# shellcheck source=bin/lib/gh-repo-token.sh
[ -r "$HARNESS/bin/lib/gh-repo-token.sh" ] && . "$HARNESS/bin/lib/gh-repo-token.sh" 2>/dev/null
command -v gh_repo_use_token >/dev/null 2>&1 && { gh_repo_use_token "$REPO" || exit 0; }
# shellcheck source=bin/lib/gh-app-auth.sh
[ -r "$HARNESS/bin/lib/gh-app-auth.sh" ] && . "$HARNESS/bin/lib/gh-app-auth.sh"   # App token per repo (#425); unarmed box untouched

# THE REST CONTRACT every read below goes through (BH-1163): rc 0 act on the
# body, rc 44 the thing is ABSENT, rc 75 GitHub did not answer. NOT optional,
# unlike the libs above it: a reconciler whose readers are undefined functions
# answers rc 127 on every one of them, and 127 is neither 44 nor 75. Rather
# than let a box mid-sync read that as an empty board, it says so and stops.
# shellcheck source=bin/lib/gh-rest-list.sh
[ -r "$HARNESS/bin/lib/gh-rest-list.sh" ] && . "$HARNESS/bin/lib/gh-rest-list.sh" 2>/dev/null
if ! command -v gh_rest_issue_list >/dev/null 2>&1; then
  log "reconcile: bin/lib/gh-rest.sh has no gh_rest_issue_list — cannot read the board, enqueued nothing"
  exit 0
fi

# The GitHub-budget reader (#372). OPTIONAL BY DESIGN.
# shellcheck source=bin/lib/gh-budget.sh
[ -r "$HARNESS/bin/lib/gh-budget.sh" ] && . "$HARNESS/bin/lib/gh-budget.sh" 2>/dev/null

TD=$(mktemp -d) || exit 0
trap 'rm -rf "$TD"' EXIT

# Skip non-essential reads when the GitHub API budget is low this tick.
if command -v gh_budget_low >/dev/null 2>&1 && gh_budget_low orphan-reconcile; then
  exit 0
fi

# ---- the three REST list reads ---------------------------------------------
# Each one is paged to 200 rows (REST caps per_page at 100, the CLI's --limit
# was 200) and each is reshaped by jq into the SAME field names the classifier
# has always read, so the JSON contract between these reads and the python
# below is unchanged and only the transport moved. `.pull_request` is dropped
# in gh_rest_issue_list: GET /issues returns pull requests as issues and
# `gh issue list` did not, and a PR read as a ticket is a ticket with no owner.
#
# OPEN issues carry the bodies (the Blocked-by evidence) and a comment COUNT;
# the thread itself is fetched later and only for the issues that need it. The
# state=all list is number/state/closed_at only, because it exists to answer
# "is blocker #M still open, and if not when did it close".
command -v gh_auth_for >/dev/null 2>&1 && gh_auth_for "$REPO" || true

# WHY A FUNCTION AND NOT A `$( )`: GH_REST_STATUS is set in the shell that CALLS
# the helper, and every read below is a plain command with `> file` so the
# status that produced the decline is still readable here (bin/lib/gh-rest.sh
# header, BH-781).
rest_decline() { # rest_decline <what> <rc>
  case "$2" in
    44) log "reconcile: $1 answered HTTP 404 — the board or its label is absent here, enqueued nothing" ;;
    *)  log "reconcile: $1 unverifiable (HTTP ${GH_REST_STATUS}${GH_REST_REASON:+ $GH_REST_REASON}) — enqueued nothing"
        command -v gh_rest_alert >/dev/null 2>&1 \
          && gh_rest_alert "$PROJECT" orphan-reconcile "$1" || true ;;
  esac
}

RC=0
gh_rest_issue_list "$REPO" open ai-build 200 > "$TD/open.raw.json" || RC=$?
if [ "$RC" != 0 ]; then rest_decline "the open ai-build list" "$RC"; exit 0; fi
# LABELS RIDE ALONG (2026-09-27). The reshape used to drop them, so a ticket
# carrying the `hold` label (BH-2504) — which bin/run-build.sh's hold check
# honours — read as an orphan here and was re-launched into a refusal on every
# tick. Names only, the shape bin/lib/hold.sh's hold_classify accepts.
jq -c '[ .[] | {number, title, body, commentCount: (.comments // 0), updatedAt: .updated_at,
               labels: [ (.labels // [])[] | if type == "object" then (.name // "") else tostring end ]} ]' \
  "$TD/open.raw.json" > "$TD/open.json" 2>/dev/null \
  || { log "reconcile: could not reshape the open ai-build list — enqueued nothing"; exit 0; }
[ -s "$TD/open.json" ] || exit 0

RC=0
gh_rest_issue_list "$REPO" all ai-build 200 > "$TD/states.raw.json" || RC=$?
if [ "$RC" != 0 ]; then rest_decline "the all-states ai-build list" "$RC"; exit 0; fi
jq -c '[ .[] | {number, state: ((.state // "") | ascii_upcase), closedAt: .closed_at} ]' \
  "$TD/states.raw.json" > "$TD/states.json" 2>/dev/null \
  || { log "reconcile: could not reshape the all-states ai-build list — enqueued nothing"; exit 0; }
[ -s "$TD/states.json" ] || exit 0

# shellcheck source=/dev/null
[ -r "$HARNESS/bin/jobs-client.sh" ] && . "$HARNESS/bin/jobs-client.sh"
# The wake backstop (BH-6976): the open PR list below and pass 1's per-issue
# reads are reused when no wake says they changed. OPTIONAL: without it every
# read happens, as before. The wake feed reads through the jobs client above.
# shellcheck source=bin/lib/wake-backstop.sh
[ -r "$HARNESS/bin/lib/wake-backstop.sh" ] && . "$HARNESS/bin/lib/wake-backstop.sh" 2>/dev/null
WB_ON=0; command -v wb_cache_get >/dev/null 2>&1 && WB_ON=1
WB_DIR="$HARNESS/state/orphan-reconcile/${REPO//\//_}"
WB_OBS=1800; [ "$WB_ON" = 1 ] && WB_OBS=$(wb_knob ORPHAN_WAKE_BACKSTOP_S)

# THE OPEN PR LIST IS REUSED (BH-8271). The last rc 0 list read is kept in
# $WB_DIR/prlist.{json,meta} and used instead of a GitHub read only while all
# of these hold: the copy is no older than PR_RECORD_MAX_AGE_S (the pr-record
# lib's knob, catalog/lanes.d/_lib.pr-record.json), no `pr` wake for ANY PR of
# the repo arrived since it was read (a PR opened, closed, reopened or pushed
# rings one), and the copy reshapes. Every GitHub list read logs one
# `PRR_MISS <repo>#list why=<no-row|stale>` line. A PR whose title or body is
# edited rings no wake, so the knob is what bounds that staleness.
# shellcheck source=bin/lib/pr-record.sh
[ -r "$HARNESS/bin/lib/pr-record.sh" ] && . "$HARNESS/bin/lib/pr-record.sh" 2>/dev/null
PRL_MAX=""
command -v pr_record_max_age >/dev/null 2>&1 && PRL_MAX=$(pr_record_max_age 2>/dev/null)
# Fallback only: the knob is PR_RECORD_MAX_AGE_S (default 900) in catalog/lanes.d/_lib.pr-record.json.
[[ "$PRL_MAX" =~ ^[0-9]{1,9}$ ]] || PRL_MAX="${PR_RECORD_MAX_AGE_S:-900}"
[[ "$PRL_MAX" =~ ^[0-9]{1,9}$ ]] || PRL_MAX=900
PRL_MAX=$((10#$PRL_MAX))
PRL=read
prl_reshape() { # prl_reshape <raw-json> — the classifier's PR fields into $TD/prs.json
  jq -c '[ .[] | {number, title, headRefName: (.head.ref // ""), body} ]' "$1" > "$TD/prs.json" 2>/dev/null \
    && [ -s "$TD/prs.json" ]
}
# THE PR RECORD FIRST (BH-8452). The jobs worker's record of the repo's open
# PRs is used when pr_record_list says it is complete: a full GitHub list
# write no older than PR_RECORD_LIST_MAX_AGE_S, an uncut page and a title,
# head_ref and body on every row, no record marked unknown by that write, AND
# the BH-8271 guard: no `pr` wake for any PR of the repo since the stamp. The
# webhook writes the record and the wake in two statements, and a failed record
# write still rings the wake, so the wake is what forces the GitHub read. With
# no wake feed (WB_ON=0, or wb_due cannot tell) the record is not used. A miss
# logs its reason to logs/pr-record.log and the flow below runs as before.
# After each GitHub list read the lane writes it back (pr_record_list_sync),
# which is what refreshes the stamp.
PRL_CAP=200
if [ "$WB_ON" = 1 ] && command -v pr_record_list >/dev/null 2>&1 \
   && pr_record_list "$REPO" open "$TD/prs.rec.json" title,head_ref,body >/dev/null 2>&1 \
   && [ -s "$TD/prs.rec.json.sync" ] \
   && PRL_SE=$(date -u -d "$(cat "$TD/prs.rec.json.sync" 2>/dev/null)" +%s 2>/dev/null) \
   && [[ "$PRL_SE" =~ ^[0-9]{1,12}$ ]] \
   && ! wb_due "$REPO" pr - "$PRL_SE" 0 "$WB_OBS" - >/dev/null 2>&1 \
   && jq -c '[ .[] | {number, title, headRefName: (.head_ref // ""), body} ]' "$TD/prs.rec.json" > "$TD/prs.json" 2>/dev/null \
   && [ -s "$TD/prs.json" ]; then
  PRL=record
fi
if [ "$PRL" = read ] && [ "$WB_ON" = 1 ] && [ "$PRL_MAX" -gt 0 ] && [ -r "$WB_DIR/prlist.json" ] && [ -r "$WB_DIR/prlist.meta" ]; then
  PRL_E=$(cut -f2 "$WB_DIR/prlist.meta" 2>/dev/null)
  PRL_NOW=$(command -v _wb_now >/dev/null 2>&1 && _wb_now || date +%s)
  if [[ "$PRL_E" =~ ^[0-9]{1,12}$ ]] && [ "$((PRL_NOW - 10#$PRL_E))" -ge 0 ] \
     && [ "$((PRL_NOW - 10#$PRL_E))" -le "$PRL_MAX" ] \
     && wb_cache_get "$WB_DIR/prlist" "$REPO" pr - "$WB_OBS" - \
     && prl_reshape "$WB_DIR/prlist.json"; then
    PRL=hit
  fi
fi
if [ "$PRL" = read ]; then
  PRL_WHY=stale
  [ -e "$WB_DIR/prlist.json" ] || [ -e "$WB_DIR/prlist.meta" ] || PRL_WHY=no-row
  # Only a lane that keeps a copy can miss one.
  [ "$WB_ON" = 1 ] && log "PRR_MISS $REPO#list why=$PRL_WHY"
  RC=0; PRL_T=$(date +%s)
  gh_rest_pr_list_all "$REPO" open "$PRL_CAP" > "$TD/prs.raw.json" || RC=$?
  if [ "$RC" != 0 ]; then rest_decline "the open PR list" "$RC"; exit 0; fi
  prl_reshape "$TD/prs.raw.json" \
    || { log "reconcile: could not reshape the open PR list — enqueued nothing"; exit 0; }
  if [ "$WB_ON" = 1 ]; then
    wb_cache_put "$WB_DIR/prlist" "-"$'\t'"$PRL_T" < "$TD/prs.raw.json" || true
  fi
  # A list at the read cap may be cut: it is not a full list, so it is not synced.
  if command -v pr_record_list_sync >/dev/null 2>&1 && [ "$(jq 'length' "$TD/prs.raw.json" 2>/dev/null)" -lt "$PRL_CAP" ] 2>/dev/null; then
    pr_record_list_sync "$REPO" open "$TD/prs.raw.json" "$(date -u -d "@$PRL_T" '+%Y-%m-%dT%H:%M:%SZ')" >/dev/null 2>&1 || true
  fi
fi

# ---- the two ledger reads ---------------------------------------------------
# NOT FAIL-OPEN. The ledger is owner class (a) — the only thing that knows a
# build is running on a pool machine two hops away — so a ledger we cannot read
# is a set of tickets whose owners we cannot name. Enqueue nothing and say why.
if ! command -v queue_list >/dev/null 2>&1 || ! command -v _jobs_req >/dev/null 2>&1; then
  log "reconcile: no jobs client — cannot name any ticket's owner, enqueued nothing"
  exit 0
fi
if ! JROWS=$(_jobs_req GET "/api/jobs?project=$PROJECT&limit=200" 2>/dev/null); then
  log "reconcile: jobs ledger unreachable — cannot name any ticket's owner, enqueued nothing"
  exit 0
fi
printf '%s' "$JROWS" > "$TD/jobs.json"
# THE OWNER-CLASS ROWS ONLY, BY STATUS (2026-09-28). An unfiltered queue_list
# is a page the worker orders `enqueued_at ASC LIMIT 200`
# (worker/jobs/src/routes/queue.js), so once a project's table held 200 old
# done/failed rows the page was ALL history and a queued or claimed row
# enqueued after them never reached this file: a ticket that WAS owned read as
# an orphan. Each status is asked for on its own (the route filters on one),
# at the route's ceiling. A queued or claimed page that comes back full may have
# been cut, and a ledger we may not have seen all of is one we cannot name
# owners from. `ready` is NOT an owner status (LIVE below is queued/claimed/
# running; a ready row only feeds grace), so a full ready page is taken as it
# is: the stale-owed sweep can leave 500+ of them, and failing safe on those
# would enqueue nothing on this project ever again.
# LIFECYCLE ORDER — ready, queued, claimed: a row that advances between two
# reads is then caught in its later status rather than missed by both.
QMAX=500
: > "$TD/queue.tsv"
for QST in ready queued claimed; do
  if ! QROWS=$(queue_list "$PROJECT" "$QST" "" "" "$QMAX" 2>/dev/null); then
    log "reconcile: build queue unreachable — cannot name any ticket's owner, enqueued nothing"
    exit 0
  fi
  if [ "$QST" != ready ] && [ -n "$QROWS" ] && [ "$(printf '%s\n' "$QROWS" | wc -l)" -ge "$QMAX" ]; then
    log "reconcile: $QMAX+ $QST queue rows — the page may be cut, cannot name every owner, enqueued nothing"
    exit 0
  fi
  [ -n "$QROWS" ] && printf '%s\n' "$QROWS" >> "$TD/queue.tsv"
done

# A QUEUED ROW NOTHING WILL CLAIM OWNS NOTHING (BH-3316). A `target=local` row
# on a fly1/pool-routed project (or a `fly` row while routing is halted) sits
# queued forever, and read as an owner it hid its ticket from this sweep for
# 6h. Such a row is rewritten to status `stranded`: not LIVE, so it does not own
# the ticket, and the classifier reports the ticket STRANDED (stranded-target)
# instead of launching it, because a launch would be a duplicate put against
# that same row. Routing is read once (queue_routing_facts: the D1 row, flags/
# as fallback); a routing read failure falls to the files, never to "stranded".
if command -v queue_routing_facts >/dev/null 2>&1 && [ -s "$TD/queue.tsv" ]; then
  RF=$(queue_routing_facts "$PROJECT" 2>/dev/null) || RF=""
  if [ -n "$RF" ]; then
    : > "$TD/queue.tsv.new"
    # Only column 4 of a stranded row changes; every other line is copied
    # byte for byte (a tab IFS would collapse an empty field).
    while IFS= read -r QLN; do
      IFS=$'\t' read -r Q1 Q2 Q3 Q4 Q5 _ <<<"$QLN"
      if [ "$Q4" = queued ] && queue_target_stranded "$RF" "$Q5" >/dev/null; then
        QLN="$Q1"$'\t'"$Q2"$'\t'"$Q3"$'\tstranded\t'"${QLN#*$'\t'*$'\t'*$'\t'*$'\t'}"
      fi
      printf '%s\n' "$QLN" >> "$TD/queue.tsv.new"
    done < "$TD/queue.tsv"
    mv "$TD/queue.tsv.new" "$TD/queue.tsv"
  fi
fi

# ---- classify ---------------------------------------------------------------
# One line per open issue: <KEY>\t<number>\t<verdict>\t<why>, verdict ORPHAN,
# OWNED or STRANDED (BH-3316, above). The reasons are the owner-rule words, so a log line and the --explain
# table say the same thing the doctrine does.
MARKDIR="$HARNESS/state/orphan-reconcile/$PROJECT"
mkdir -p "$MARKDIR" 2>/dev/null
# The grace markers this script wrote, as `<KEY> <epoch>` lines — its own
# enqueue is the freshest owner-end there is, and reading it here is what makes
# a second run one minute later a no-op even before the ledger row lands.
: > "$TD/marks.txt"
# Markers older than a week cannot affect any grace window and only make this
# loop longer every month. Pruned here rather than by a cron: the one place that
# writes them is also the one place that knows when they stop mattering.
find "$MARKDIR" -name '*.enqueued' -mtime +7 -delete 2>/dev/null || true
for M in "$MARKDIR"/*.enqueued; do
  [ -f "$M" ] || continue
  MK=$(basename "$M" .enqueued)
  printf '%s %s\n' "$MK" "$(stat -c %Y "$M" 2>/dev/null || stat -f %m "$M" 2>/dev/null || echo 0)" >> "$TD/marks.txt"
done

# THE CLASSIFIER, WRITTEN OUT ONCE AND RUN TWICE (BH-1163). Pass `needs` says
# what it cannot decide without another GitHub read; pass `decide` produces the
# verdicts from the answers. Same program both times — two copies of the owner
# rule that drifted would park or launch different tickets.
mkdir -p "$TD/extra" 2>/dev/null
cat > "$TD/classify.py" <<'PYEOF'
import json, os, re, sys
from datetime import datetime, timezone

def load(p, dflt):
    try:
        with open(p) as f:
            v = json.load(f)
        return v
    except Exception:
        return dflt

issues = load(sys.argv[1], None)
states = load(sys.argv[2], None)
prs    = load(sys.argv[3], [])
jobs   = load(sys.argv[4], {})
if not isinstance(issues, list) or not isinstance(states, list):
    sys.exit(1)          # a malformed answer is not an empty board
if not isinstance(prs, list):
    prs = []

PFX   = os.environ["ORPHAN_PFX"]
NOW   = int(os.environ["ORPHAN_NOW"])
GRACE = int(os.environ["ORPHAN_GRACE_S"])
REPO  = os.environ["ORPHAN_REPO"]
FETCH_MAX = int(os.environ["ORPHAN_FETCH_MAX"])
THREAD_MAX = int(os.environ.get("ORPHAN_THREAD_MAX") or 200)
# THE THREAD CURSOR (BH-8497): the issue number the last capped run read up to.
# The commented orphans are walked in issue-number order from the first one
# past it (wrapping), so a ticket the cap cut on one run is read on the next.
try:
    THREAD_CURSOR = int(os.environ.get("ORPHAN_THREAD_CURSOR") or 0)
except ValueError:
    THREAD_CURSOR = 0
# `needs` prints one `<kind>\t<number>` line per read it wants; `decide` reads
# those answers back out of ORPHAN_EXTRA and produces the verdicts.
MODE  = os.environ.get("ORPHAN_MODE") or "decide"
# 1 = bin/lib/hold.sh is loaded and bash answers every `hold` need with its
# hold_classify verdict; the regexes below are then only the unsynced-box
# fallback and decide nothing.
HOLD_LIB = os.environ.get("ORPHAN_HOLD_LIB") == "1"
EXTRA = os.environ.get("ORPHAN_EXTRA") or ""
NEEDS = []
THREAD_WANT = []   # needs mode: the commented orphans, in board order
HOLD_WANT = []     # needs mode: the hold answers, asked AFTER every thread read

def answer(kind, n):
    """The REST answer bash pre-fetched for <kind>-<n>, or None when the read
    was declined, capped or never asked for. None is always the fail-closed
    reading at every call site below — never an empty result."""
    if not EXTRA:
        return None
    try:
        with open(os.path.join(EXTRA, "%s-%d.json" % (kind, n))) as f:
            return json.load(f)
    except Exception:
        return None

def ts(s):
    try:
        return int(datetime.strptime(str(s), "%Y-%m-%dT%H:%M:%SZ")
                   .replace(tzinfo=timezone.utc).timestamp())
    except Exception:
        return 0

# THE FLEET'S DEFINITION OF A BLOCKER LINE, copied from
# bin/unblocked-children.sh on purpose and named as such: the day these two
# drift is the day a ticket is launched under a live blocker. The extra
# `<PFX>-N` spelling only ever ADDS blockers, which fails closed here.
line_re   = re.compile(r"^[\s>*_\-#]*blocked[- ]by\b(.*)$", re.IGNORECASE | re.MULTILINE)
part_re   = re.compile(r"^[\s>*_\-#]*part of\b(.*)$", re.IGNORECASE | re.MULTILINE)
num_re    = re.compile(r"#(\d+)")
keynum_re = re.compile(r"(?<![A-Za-z0-9])" + re.escape(PFX) + r"-0*(\d+)(?![0-9])", re.IGNORECASE)
# The FULL key, dot suffix included. A decompose child's TITLE spells its child
# key (`TK-2416.0` in project-5 #2566) and its build's PR claims exactly that
# key, never `TK-2566` the issue number. keynum_re above truncates at the dot
# and would even read the child PR as a claim on the PARENT number; fullkey_re
# is the spelling that can see the child-keyed owner (the 2026-09-19 #2566/
# #2579 re-launch loop). Leading zeros on the number are stripped on BOTH sides
# of the comparison, mirroring keynum_re, so `ticket/TK-02416.0` and
# `TK-2416.0` meet; fullkey() is the one normalised spelling.
fullkey_re = re.compile(r"(?<![A-Za-z0-9])" + re.escape(PFX)
                        + r"-0*(\d+(?:\.\d+)*)(?![A-Za-z0-9])", re.IGNORECASE)
def fullkey(m):
    return (PFX + "-" + m.group(1)).upper()
# THE HOLD VOCABULARY, from bin/lib/hold.sh through the environment so this
# classifier and bin/blocked-resolver.sh's gate read one definition (BH-408).
# HOLD as a WORD and in capitals: `HOLD —`, `(HOLD)`, `HOLD:`. Never `hold` in
# prose ("until the operator lifts the hold" is a description of one, not a new one).
# The fallbacks are what this script did before the lib existed: the same word
# regex, and NO lift vocabulary — `(?!)` never matches — so an unsynced box
# behaves exactly as it did rather than guessing at a lift.
hold_re   = re.compile(os.environ.get("HOLD_WORD_RE")
                       or r"(?<![A-Za-z])HOLD(?![A-Za-z])")
# THE BODY TAKES A LINE, NOT A WORD (BH-1461). A ticket BODY is where this
# harness documents itself, so the capital word appears in it as a NOUN all the
# time — "a per-project HOLD row", "after the operator HOLD (...)" — and the
# word regex owned every such ticket for ever. `(?m)` is required by BOTH
# engines: Python `re` and jq's Perl-syntax Oniguruma both anchor `^` to the
# string without it (bin/lib/hold.sh carries the measurement).
body_re   = re.compile(os.environ.get("HOLD_BODY_RE")
                       or "(?m)^HOLD[ \t]*(?:[:—–-]|\r?$)")
# A TITLE HOLDS ONLY IN THE IDIOM — `(HOLD)`/`(ON HOLD)`/`[HOLD]`, or a leading
# `[KEY: ][ON ]HOLD` then `:` or a dash —
# never on the word in a title that names the feature (bin/lib/hold.sh,
# HOLD_TITLE_RE, 2026-09-28). The fallback is the same string.
title_re  = re.compile(os.environ.get("HOLD_TITLE_RE")
                       or r"\((?:ON[ \t]+)?HOLD\)|\[(?:ON[ \t]+)?HOLD\]|^[ \t]*(?:[A-Z]+-[0-9]+(?:\.[0-9]+)*[: \t]+)?(?:ON[ \t]+)?HOLD(?![A-Za-z_])[ \t]*[:—–-]")
lift_re   = re.compile(os.environ.get("HOLD_LIFT_RE") or r"(?!)")
liftneg_re = re.compile(os.environ.get("HOLD_NEG_RE") or r"(?!)")
close_re  = re.compile(r"\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s+#(\d+)", re.IGNORECASE)

def refs(text):
    out = set()
    for m in num_re.finditer(text or ""):
        out.add(int(m.group(1)))
    for m in keynum_re.finditer(text or ""):
        out.add(int(m.group(1)))
    return out

# ---- state map: is blocker #M open, and when did it close -------------------
st, closed_at = {}, {}
for i in states:
    if not isinstance(i, dict) or "number" not in i:
        continue
    n = int(i["number"])
    st[n] = str(i.get("state") or "").upper()
    closed_at[n] = ts(i.get("closedAt"))

# A blocker the ai-build list does not carry is the de-labelled decompose parent
# (project-5 #667/#668 are OPEN and unlabelled). Missing used to read as CLOSED,
# which released a child under a live parent. Fetched by number, capped, and an
# unreadable one reads OPEN — the fail-closed direction.
wanted = set()
for i in issues:
    if not isinstance(i, dict):
        continue
    body = i.get("body") or ""
    for m in line_re.finditer(body):
        wanted |= refs(m.group(1))
missing = sorted(n for n in wanted if n not in st)[:FETCH_MAX]
for n in missing:
    if MODE == "needs":
        NEEDS.append("blocker\t%d" % n)
        continue
    d = answer("blocker", n)
    if isinstance(d, dict) and d.get("state"):
        st[n] = str(d.get("state") or "").upper()
        closed_at[n] = ts(d.get("closed_at"))
    else:
        # Declined (rc 44 or 75), capped, or a body nobody can act on: OPEN is
        # the fail-closed reading, exactly as the pre-REST `gh issue view`
        # failure was.
        st[n] = "OPEN"
        closed_at[n] = 0
for n in wanted:
    st.setdefault(n, "OPEN")

open_nums = {int(i["number"]) for i in issues
             if isinstance(i, dict) and "number" in i}

# ---- (c) children: an open issue that names this one in `Part of #N` --------
children = {}
for i in issues:
    if not isinstance(i, dict) or "number" not in i:
        continue
    kid = int(i["number"])
    for m in part_re.finditer(i.get("body") or ""):
        for parent in refs(m.group(1)):
            if parent != kid:
                children.setdefault(parent, []).append(kid)

# ---- (b) open PRs, by the key they carry -----------------------------------
pr_owns = {}
for p in prs:
    if not isinstance(p, dict):
        continue
    num = p.get("number")
    hay = " ".join(str(p.get(k) or "") for k in ("title", "headRefName"))
    claims = {int(m.group(1)) for m in keynum_re.finditer(hay)}
    claims |= {int(m.group(1)) for m in num_re.finditer(str(p.get("title") or ""))}
    # The BODY counts only through a closing keyword. A plan body that merely
    # lists `#672, #673` is a reading list, not a claim of ownership.
    claims |= {int(m.group(1)) for m in close_re.finditer(str(p.get("body") or ""))}
    for n in claims:
        pr_owns.setdefault(n, num)

# Child-keyed claims, by the FULL key. An open PR whose title or head branch
# spells `TK-2416.0` owns the issue whose OWN title spells that same key: the
# decompose-child shape, where the PR never carries the issue's number and
# pr_owns above cannot see it. Same conductor logic as class (b): an open PR
# is the merge conductor's property, whatever state it is in.
pr_keys = {}
for p in prs:
    if not isinstance(p, dict):
        continue
    num = p.get("number")
    hay = " ".join(str(p.get(k) or "") for k in ("title", "headRefName"))
    for m in fullkey_re.finditer(hay):
        pr_keys.setdefault(fullkey(m), num)

# ---- (a) + (e) the ledger ---------------------------------------------------
LIVE = ("queued", "claimed", "running")
live_keys, ended_at = {}, {}
# BH-3316: a queued row whose target nothing claims (the shell rewrote its
# status to `stranded`). It neither owns the ticket nor opens a grace window.
stranded_keys = {}

def note(tokens, status, when, label):
    keys = {t for t in tokens if t}
    for k in keys:
        if status in LIVE:
            live_keys.setdefault(k, label)
        elif status == "stranded":
            stranded_keys.setdefault(k, label)
        elif when:
            ended_at[k] = max(ended_at.get(k, 0), when)

for j in (jobs.get("jobs") if isinstance(jobs, dict) else []) or []:
    if not isinstance(j, dict):
        continue
    meta = j.get("meta")
    if isinstance(meta, str):
        try:
            meta = json.loads(meta)
        except Exception:
            meta = {}
    if not isinstance(meta, dict):
        meta = {}
    # A build row spells the ticket `TK-721` and a triage shard spells it `1149`,
    # and the meta carries the other half. Every spelling is noted, so a row
    # under any of them owns the ticket.
    toks = {str(j.get("ticket_id") or ""), str(meta.get("key") or ""),
            str(meta.get("ticket_id") or "")}
    note(toks, str(j.get("status") or "").lower(),
         ts(j.get("updated_at")) or ts(j.get("created_at")),
         "ledger job %s" % (j.get("id") or "?"))

try:
    with open(sys.argv[5]) as f:
        qlines = f.read().splitlines()
except Exception:
    qlines = []
for ln in qlines:
    c = ln.split("\t")
    if len(c) < 8:
        continue
    if c[3].lower() == "stranded":
        note({c[1], c[2]}, "stranded", 0, "queue row queued target=%s" % c[4])
        continue
    note({c[1], c[2]}, c[3].lower(), ts(c[7]), "queue row %s" % c[3])

# ---- (e) this script's own markers -----------------------------------------
try:
    with open(sys.argv[6]) as f:
        for ln in f:
            parts = ln.split()
            if len(parts) == 2 and parts[1].isdigit():
                ended_at[parts[0]] = max(ended_at.get(parts[0], 0), int(parts[1]))
except Exception:
    pass

def fresh(n, key):
    """The most recent moment an owner of this ticket stopped owning it."""
    best, why = 0, ""
    for tok in (key, str(n)):
        t = ended_at.get(tok, 0)
        if t > best:
            best, why = t, "a ledger row for %s ended" % tok
    return best, why

rows = []
for i in sorted(issues, key=lambda x: int(x.get("number", 0))):
    if not isinstance(i, dict) or "number" not in i:
        continue
    n = int(i["number"])
    key = "%s-%d" % (PFX, n)
    title = str(i.get("title") or "")
    body = str(i.get("body") or "")

    verdict, why = "ORPHAN", "no owner"
    blockers = set()
    # (a) ledger
    for tok in (key, str(n)):
        if tok in live_keys:
            verdict, why = "OWNED", "ledger:%s" % live_keys[tok]
            break
    # (b) an open PR
    if verdict == "ORPHAN" and n in pr_owns:
        verdict, why = "OWNED", "pr:#%s is open" % pr_owns[n]
    # (b2) an open PR that claims the full key the issue's OWN title LEADS
    #     with. A decompose child's PR carries the child key (`TK-2416.0`), so
    #     the number-key map above misses it and the backstop used to re-launch
    #     a ticket whose build was already green upstream. Only the LEADING key
    #     is the issue's own name (the decompose-child convention this rests
    #     on); a key mentioned later in the title (`TK-910: follow-up to
    #     TK-902`) is someone else's and must not park this ticket.
    if verdict == "ORPHAN":
        m = fullkey_re.match(title.lstrip())
        if m and fullkey(m) in pr_keys:
            tk = fullkey(m)
            verdict, why = "OWNED", "pr:#%s is open (title key %s)" % (pr_keys[tk], tk)
    # PASS 1 STOPS HERE, and stops BEFORE class (c) on purpose. A blocker whose
    # state this pass has not fetched yet could resolve either way, so asking
    # about (c) would hide the thread of a ticket pass 2 then has to judge — and
    # a thread nobody asked for is one pass 2 cannot read. The need set is a
    # superset by construction; the cost of the extra reads is the cap below.
    if MODE == "needs":
        if verdict == "ORPHAN" and int(i.get("commentCount") or 0) > 0:
            # THE CAP IS A DECISION, SO IT SAYS SO. Past THREAD_MAX the thread
            # is never asked for, pass 2 reads the missing answer as
            # `unverifiable:thread`, and the ticket is parked — the fail-closed
            # direction, but in the log it is indistinguishable from a board
            # nobody has anything to say about. `capped` is NOT a read request:
            # bash skips it in the fetch loop and only names it in one line, so
            # the operator can see which knob bound and on which tickets.
            # Which ones are read is decided after the loop (the cursor).
            THREAD_WANT.append(n)
        # The hold verdict is bin/lib/hold.sh's, computed in bash AFTER the
        # thread reads (the line order is the order bash works in).
        if verdict == "ORPHAN" and HOLD_LIB:
            HOLD_WANT.append(n)
        continue
    # (c) an open blocker, or open children of a decompose parent
    if verdict == "ORPHAN":
        blockers = set()
        for m in line_re.finditer(body):
            blockers |= refs(m.group(1))
        live = sorted(b for b in blockers if st.get(b, "OPEN") == "OPEN")
        if live:
            verdict, why = "OWNED", "blocker:#%s still open" % ",#".join(str(b) for b in live)
        else:
            kids = sorted(k for k in children.get(n, []) if k in open_nums)
            if kids:
                verdict, why = "OWNED", "children:#%s open (decompose parent)" % ",#".join(str(k) for k in kids)
    # (d) a hold — THE NEWEST HUMAN COMMENT WINS (BH-408). Any HOLD ever
    #     written used to hold the ticket for ever, so a ticket the operator later said
    #     RESUME on stayed parked with nothing to un-park it. The thread is
    #     walked newest-first (the list payload is oldest-first, so that is the
    #     last element), the first DECISIVE comment decides, and neutral
    #     comments — the harness's own close-outs — are skipped. Only when no
    #     comment decides do the title and body get a say.
    #
    #     No bot filter here, unlike bin/lib/hold.sh's REST reading: the list
    #     payload carries comment bodies without a usable `user.type`, and no
    #     bot in this fleet writes HOLD or RESUME. The gate that acts on an
    #     irreversible close does have one.
    #     The thread itself comes from the per-issue REST read pass 1 asked
    #     for (BH-1163). An issue with no comments needs no read at all; one
    #     whose read was declined or capped is OWNED rather than launched,
    #     because "nobody could see the thread" and "nobody held it" are
    #     different sentences and only one of them may spend a build.
    thread = []
    if verdict == "ORPHAN" and int(i.get("commentCount") or 0) > 0:
        cs = answer("thread", n)
        if isinstance(cs, list):
            thread = [str(c.get("body") or "") for c in cs if isinstance(c, dict)]
            # A READ THAT STOPPED SHORT IS NOT THE THREAD. The row cap in
            # gh_rest_issue_comments trims OLDEST-first, so a thread longer
            # than the cap loses its NEWEST comments — which are the decisive
            # end of this walk, and where a HOLD written today lives. The list
            # payload already carries the issue's own comment count, so "fewer
            # bodies than GitHub says there are" is knowable here, and it reads
            # the fail-closed way rather than as "nobody held it".
            if len(thread) < int(i.get("commentCount") or 0):
                verdict, why = "OWNED", "unverifiable:thread-truncated"
        else:
            verdict, why = "OWNED", "unverifiable:thread"
    #     THE LIB DECIDES WHEN IT IS HERE (2026-09-27). This classifier used
    #     to walk the thread with its own copy of the regexes and NO bot
    #     filter, so bin/run-build.sh's own close-out on a held ticket — "…;
    #     RESUME on the ticket lifts it", posted by the App — read as a LIFT of
    #     a title HOLD. The reconciler re-launched the ticket, run-build refused
    #     it hold:title, and the new RESULT moved bin/triage-gate.sh's queue
    #     fingerprint every tick. hold_classify is the reading run-build uses
    #     (bot comments skipped, the `hold` label, ABANDON), so both lanes now
    #     answer "is it held" from one definition. Its verdict came in as an
    #     answer file; a missing or unreadable one parks the ticket (the
    #     fail-closed direction every other read here takes).
    if verdict == "ORPHAN" and HOLD_LIB:
        hv = answer("hold", n)
        if not isinstance(hv, dict):
            verdict, why = "OWNED", "unverifiable:hold"
        elif int(hv.get("rc", 2)) == 1:
            v = str(hv.get("v") or "")
            verdict, why = "OWNED", (v.split("\t", 1)[1] if "\t" in v else "hold:?")
        elif int(hv.get("rc", 2)) != 0:
            verdict, why = "OWNED", "unverifiable:hold"
    elif verdict == "ORPHAN":
        held = None
        for c in reversed(thread):
            if lift_re.search(c) and not liftneg_re.search(c):
                held = False
                break
            if hold_re.search(c):
                held = True
                break
        if held is True:
            verdict, why = "OWNED", "hold:comment"
        elif held is None:
            if title_re.search(title):
                verdict, why = "OWNED", "hold:title"
            elif body_re.search(body):
                verdict, why = "OWNED", "hold:body"
    # (e) grace: an owner that ended a moment ago, or the board moving on the
    #     thread itself — either way the event path gets first claim.
    if verdict == "ORPHAN":
        when, gwhy = fresh(n, key)
        moved = ts(i.get("updatedAt"))
        if moved > when:
            when, gwhy = moved, "the thread itself moved"
        for b in sorted(blockers):
            if st.get(b) == "CLOSED" and closed_at.get(b, 0) > when:
                when, gwhy = closed_at[b], "blocker #%d closed" % b
        if when and NOW - when < GRACE:
            verdict = "OWNED"
            why = "grace:%s %dm ago" % (gwhy, (NOW - when) // 60)
    # BH-3316: no owner, and the one queued row it has will never be claimed.
    # Reported, not launched: the launch would be a duplicate put on that row.
    if verdict == "ORPHAN":
        for tok in (key, str(n)):
            if tok in stranded_keys:
                verdict, why = "STRANDED", "stranded-target:%s" % stranded_keys[tok]
                break

    rows.append("%s\t%d\t%s\t%s" % (key, n, verdict, why))

if MODE == "needs":
    # The cap takes THREAD_MAX threads in number order, starting past the
    # cursor and wrapping; the rest are `capped`. All thread lines come before
    # all hold lines, so every hold answer has its thread on disk.
    want = sorted(set(THREAD_WANT))
    k = next((j for j, x in enumerate(want) if x > THREAD_CURSOR), 0)
    want = want[k:] + want[:k]
    NEEDS += ["thread\t%d" % x for x in want[:THREAD_MAX]]
    NEEDS += ["capped\t%d" % x for x in sorted(want[THREAD_MAX:])]
    NEEDS += ["hold\t%d" % x for x in HOLD_WANT]
    print("\n".join(NEEDS))
    sys.exit(0)
print("\n".join(rows))
PYEOF

# bin/lib/hold.sh's classifier is THE hold reading when it is loaded; without
# it (a box mid-sync) the python regexes keep today's behaviour.
HOLD_LIB=0; command -v hold_classify >/dev/null 2>&1 && HOLD_LIB=1

# hold_answer <number> — hold_classify on the issue as the ai-build list served
# it plus the thread pass 1 fetched, written as the `hold` answer. The list is
# scoped state=open&labels=ai-build, so those two facts are true by
# construction and are stated rather than re-read. An issue with comments whose
# thread was not read gets NO answer: pass 2 has already parked it as
# unverifiable:thread, and a verdict over an empty thread would be a guess.
hold_answer() {
  local n="$1" ij cj cnt v rc
  ij=$(jq -c --argjson n "$n" 'first(.[] | select(.number == $n))
        | {state: "open", title: (.title // ""), body: (.body // ""),
           labels: (((.labels // []) + ["ai-build"]) | unique)}' "$TD/open.json" 2>/dev/null)
  [ -n "$ij" ] || return 0
  cnt=$(jq -r --argjson n "$n" 'first(.[] | select(.number == $n)) | .commentCount // 0' "$TD/open.json" 2>/dev/null)
  if [ -f "$TD/extra/thread-$n.json" ]; then cj="$TD/extra/thread-$n.json"
  elif [ "${cnt:-0}" = 0 ]; then cj='[]'
  else return 0; fi
  v=$(hold_classify "$ij" "$cj"); rc=$?
  jq -nc --arg v "$v" --argjson rc "$rc" '{v: $v, rc: $rc}' > "$TD/extra/hold-$n.json" 2>/dev/null \
    || rm -f "$TD/extra/hold-$n.json"
}

classify() { # classify <needs|decide> <outfile>
  ORPHAN_PFX="$PFX" ORPHAN_NOW="$(date -u +%s)" ORPHAN_GRACE_S="$((GRACE_MIN * 60))" \
  ORPHAN_REPO="$REPO" ORPHAN_FETCH_MAX="$BLOCKER_FETCH_MAX" \
  ORPHAN_THREAD_MAX="$THREAD_FETCH_MAX" ORPHAN_THREAD_CURSOR="$THREAD_CURSOR" \
  ORPHAN_MODE="$1" ORPHAN_EXTRA="$TD/extra" \
  ORPHAN_HOLD_LIB="$HOLD_LIB" \
  python3 "$TD/classify.py" "$TD/open.json" "$TD/states.json" "$TD/prs.json" \
    "$TD/jobs.json" "$TD/queue.tsv" "$TD/marks.txt" > "$2" 2>/dev/null
}

# ---- pass 1: the reads the owner rule cannot be applied without -------------
# Every one of them is OPTIONAL by construction: a read that answers 44 or 75
# leaves no file behind, and pass 2's `answer()` reads that absence as the
# fail-closed verdict (blocker OPEN, thread unverifiable). So a GitHub that has
# stopped answering costs this lane a quiet tick, never a wrong launch.
# THE THREAD CURSOR (BH-8497): the last thread number a capped run asked for,
# per repo and per mode. Pass 1 starts past it, so no commented orphan stays
# `unverifiable:thread` for more than one run while the board fits in two.
# The cursor is a `ledgers` row (kind orphan-thread-cursor, key
# "<owner>/<repo> <orphan|stranded>", status at, detail the issue number), so a
# rebuilt box keeps it and no state/ file is written. One row per repo and
# mode, overwritten in place. No row, an unreadable row or a worker outage
# reads 0: the walk starts at the first thread, the behaviour before the cursor.
TC_KIND=orphan-thread-cursor
TC_KEY="$REPO orphan"; [ "$STRANDED_MODE" = 1 ] && TC_KEY="$REPO stranded"
THREAD_CURSOR=""
command -v job_ledger_row >/dev/null 2>&1 \
  && THREAD_CURSOR=$(job_ledger_row "$TC_KIND" "$TC_KEY" 2>/dev/null | jq -r '.detail // "" | tostring' 2>/dev/null)
case "$THREAD_CURSOR" in ''|*[!0-9]*) THREAD_CURSOR=0 ;; esac
classify needs "$TD/needs.tsv" || true
CAPPED=""; LAST_THREAD=""; N_CAPPED=0
# THE WAKE BACKSTOP (BH-6976). A thread or blocker read is kept in
# state/orphan-reconcile/<owner>_<repo>/<kind>-N.{json,meta} and reused instead
# of a GitHub read only while wb_cache_get says so: no issue or pr wake for N
# since it was written, younger than ORPHAN_WAKE_BACKSTOP_S, and (thread) the
# open list's updatedAt for N unchanged. A hit is not a read, so the caps above
# are unchanged. Only an rc 0 read is cached. WB_ON, WB_DIR and WB_OBS are set
# above the open PR list read.
C_HITS=0; C_READS=0
while IFS=$'\t' read -r KIND NUM; do
  case "$NUM" in ''|*[!0-9]*) continue ;; esac
  # `capped` is not a read — it is pass 1 naming a thread it did not ask for
  # because ORPHAN_THREAD_FETCH_MAX bound. Collected, never fetched.
  case "$KIND" in
    capped) CAPPED="${CAPPED:+$CAPPED,}#$NUM"; N_CAPPED=$((N_CAPPED + 1)); continue ;;
    hold)   hold_answer "$NUM"; continue ;;   # no GitHub read: the thread is already here
    blocker) ;;
    thread) LAST_THREAD="$NUM" ;;
    *) continue ;;
  esac
  CU=-
  if [ "$WB_ON" = 1 ]; then
    [ "$KIND" = thread ] && CU=$(jq -r --argjson n "$NUM" 'first(.[] | select(.number == $n)) | .updatedAt // empty' "$TD/open.json" 2>/dev/null)
    if wb_cache_get "$WB_DIR/$KIND-$NUM" "$REPO" issue,pr "$NUM" "$WB_OBS" "$CU" \
       && cp "$WB_DIR/$KIND-$NUM.json" "$TD/extra/$KIND-$NUM.json" 2>/dev/null; then
      C_HITS=$((C_HITS + 1))
      continue
    fi
  fi
  RC=0; CT=$(date +%s); C_READS=$((C_READS + 1))
  if [ "$KIND" = thread ]; then
    gh_rest_issue_comments "$REPO" "$NUM" 200 > "$TD/extra/thread-$NUM.json" || RC=$?
  else
    gh_rest GET "repos/$REPO/issues/$NUM" > "$TD/extra/blocker-$NUM.json" || RC=$?
  fi
  if [ "$RC" = 0 ] && [ "$WB_ON" = 1 ] && [ -n "$CU" ]; then
    wb_cache_put "$WB_DIR/$KIND-$NUM" "$CU"$'\t'"$CT" < "$TD/extra/$KIND-$NUM.json" || true
  fi
  if [ "$RC" != 0 ]; then
    rm -f "$TD/extra/$KIND-$NUM.json"
    if [ "$RC" = 44 ]; then
      log "reconcile: the $KIND read for #$NUM answered HTTP 404 — absent, read the fail-closed way"
    else
      log "reconcile: the $KIND read for #$NUM unverifiable (HTTP ${GH_REST_STATUS}${GH_REST_REASON:+ $GH_REST_REASON}) — read the fail-closed way"
      command -v gh_rest_alert >/dev/null 2>&1 \
        && gh_rest_alert "$PROJECT" orphan-reconcile "$KIND #$NUM" || true
    fi
  fi
done < "$TD/needs.tsv"
[ "$WB_ON" = 1 ] && wb_gc "$WB_DIR"
if [ -n "$CAPPED" ]; then
  log "reconcile: ORPHAN_THREAD_FETCH_MAX=$THREAD_FETCH_MAX bound — $CAPPED parked unverifiable:thread; next run starts past #${LAST_THREAD:-0}"
  command -v job_ledger_put >/dev/null 2>&1 \
    && { job_ledger_put "$TC_KIND" "$TC_KEY" at "${LAST_THREAD:-0}" >/dev/null 2>&1 \
         || log "reconcile: thread cursor row NOT written (the next run starts at the first thread)"; }
  # ONE ALERT a project a UTC day names the count the bound cut. The day flag
  # goes through bin/lib/flags.sh (flag_has --cached / flag_set; the file
  # flags/alerted-orphan-thread-cap-<project>-<YYYYMMDD>); bin/alerts-groom.sh
  # prunes old alerted-* days.
  # shellcheck source=bin/lib/flags.sh
  command -v flag_set >/dev/null 2>&1 || . "$HARNESS/bin/lib/flags.sh" 2>/dev/null
  TC_FLAG="alerted-orphan-thread-cap-$(printf '%s' "$PROJECT" | tr -c 'A-Za-z0-9._-' '_')-$(date -u +%Y%m%d)"
  if command -v flag_set >/dev/null 2>&1 && ! flag_has --cached "$TC_FLAG" 2>/dev/null; then
    flag_set "$TC_FLAG" on "orphan-reconcile: thread cap alert sent" >/dev/null 2>&1
    "$HARNESS/bin/lane-alert.sh" --id "orphan-thread-cap:$PROJECT" --severity warn "orphan-reconcile/$PROJECT" \
      "ORPHAN_THREAD_FETCH_MAX=$THREAD_FETCH_MAX cut $N_CAPPED comment-thread read(s) this run; they are read on the next run. Raise lib.orphan-reconcile.$PROJECT.orphan_thread_fetch_max if this repeats." \
      >/dev/null 2>&1 || true
  fi
elif [ "$THREAD_CURSOR" != 0 ] && command -v job_ledger_put >/dev/null 2>&1; then
  # An uncut run resets the cursor, so the next capped run starts at the first thread.
  job_ledger_put "$TC_KIND" "$TC_KEY" at 0 >/dev/null 2>&1 \
    || log "reconcile: thread cursor row NOT reset (the next capped run starts past #$THREAD_CURSOR)"
fi

# ---- pass 2: the verdicts ---------------------------------------------------
classify decide "$TD/verdicts.tsv"
PY_RC=$?

if [ "$PY_RC" -ne 0 ] || [ ! -s "$TD/verdicts.tsv" ]; then
  log "reconcile: could not classify the open ai-build issues (rc=$PY_RC) — enqueued nothing"
  exit 0
fi

[ "$EXPLAIN" = 1 ] && cat "$TD/verdicts.tsv"

# A TICKET PARKED BECAUSE SOMETHING COULD NOT BE READ IS NOT A QUIET TICKET.
# The per-read declines above are logged as they happen, but a verdict reached
# on an absent answer (a capped thread, a truncated one, a blocker read that
# 404'd) otherwise only ever appears under --explain. Named here so the tick's
# own log says which tickets nobody could see, rather than just a lower count.
UNV=$(awk -F'\t' '$4 ~ /^unverifiable:/ {printf "%s%s(%s)", (n++ ? "," : ""), $1, $4}' "$TD/verdicts.tsv")
if [ -n "$UNV" ]; then log "reconcile: parked unread — $UNV"; fi
# >>> needs-human skip log (BH-3443)
# A ticket parked on a human step (bin/lib/hold.sh's hold:waiting-on-human) is
# named with the step it waits on, one line each, so the tick's own log says
# why it was left alone. The OWNED why already carries the token.
awk -F'\t' '$3=="OWNED" && $4 ~ /^hold:waiting-on-human / {w=$4; sub(/^hold:waiting-on-human [^ ]* ?/, "", w); print $2 "\t" w}' "$TD/verdicts.tsv" \
  | while IFS=$'\t' read -r NN NA; do log "reconcile: #$NN skip :: waiting on human: $NA"; done
# <<< needs-human skip log

OPEN_N=$(grep -c . "$TD/verdicts.tsv")
OWNED_N=$(awk -F'\t' '$3=="OWNED"' "$TD/verdicts.tsv" | grep -c . || true)
ORPHAN_N=$(awk -F'\t' '$3=="ORPHAN"' "$TD/verdicts.tsv" | grep -c . || true)
STRANDED_N=$(awk -F'\t' '$3=="STRANDED"' "$TD/verdicts.tsv" | grep -c . || true)
STRANDED=$(awk -F'\t' '$3=="STRANDED" {sub(/^stranded-target:/, "", $4); printf "%s%s(%s)", (n++ ? "," : ""), $1, $4}' "$TD/verdicts.tsv")
if [ -n "$STRANDED" ]; then
  log "reconcile: stranded-target — $STRANDED: queued on a target nothing claims (routing ${RF:-?} as builder|halted); not launched, retarget the row to fly"
fi

# ---- enqueue ----------------------------------------------------------------
# The SOP's own launch, detached, exactly as a triage session runs it: on a
# Fly-routed project bin/run-build.sh's first act is the queue row + a
# QUEUED_FLY result, and on a box project it is the build. Going through it
# rather than writing a row here is deliberate — it is where the build-key
# flock, the duplicate-work guard and the context gate live, and a second copy
# of that routing is a second thing to keep in step.
# refused_by_run_build <KEY> — prints why bin/run-build.sh would REFUSE this
# ticket as abandoned (or, a deliberate extra, superseded), rc 0; rc 1 when it
# would not (2026-09-27).
#
# THE SAME READS run-build's `abandoned ticket skip` makes (bin/lib/rb/gates.sh,
# tests/run-build-abandoned-skip-test.sh), in the same order and NO WIDER: the
# fleet ledger's `abandoned "<project> <KEY>"` row decides when it answers —
# `abandoned` refuses, anything else (`released`) builds, and the queue row is
# then not asked — and only when the ledger has no answer does the queue row
# speak, and then ONLY as `failed | ABANDONED by the blocked-resolver…`, the one
# row reason run-build refuses. Launching such a ticket bought nothing but a
# BUILD_REFUSED record, and that record is an input of bin/triage-gate.sh's
# queue fingerprint: nine of them re-launched every tick moved the fingerprint
# every tick and bought a paid triage session each time (~$830 in ~26h).
#
# NOT READ, ON PURPOSE (review of #3061): the resolver's "the ticket says
# ABANDON" row and an operator's pool abandon ("ABANDONED by an operator",
# bin/fly-pool.sh, BH-2406). run-build builds both. The first carries no ledger
# row and asks the human for RESUME; after it hold.sh reads the ticket clear,
# and a row-reason skip here would park the ticket forever. An ABANDON that was
# NOT lifted is already refused by hold.sh (owner class d) from the ticket.
#
# The queue row is THIS KEY'S row, read with queue_row exactly as run-build
# reads it (bin/lib/rb/gates.sh) — never looked up in queue.tsv. That file
# holds only the owner-class statuses, and before it did it was an
# oldest-first page of 200: 200 older done/failed rows pushed an ABANDONED
# row off it, the skip never fired, and the ticket was launched into a
# refusal every tick (2026-09-28). One queue GET and one ledger GET per
# ORPHAN, the reads run-build would have made. Either one not answering is
# run-build's fail-open too: nothing there means launch as today.
refused_by_run_build() {
  local key="$1" row="" qst qwhy st rc=2
  if command -v queue_row >/dev/null 2>&1; then
    row=$(queue_row "$PROJECT" "$key" 2>/dev/null) || row=""
  fi
  # queue_row: status, enqueued_at, claimed_by, requested_by, reason.
  qst=$(printf '%s' "$row" | cut -f1); qwhy=$(printf '%s' "$row" | cut -f5)
  # A DELIBERATE EXTRA, not a run-build read: the resolver resolved this park
  # as `done | ticket <KEY> already merged via …` (SUPERSEDED). The ticket has
  # landed, so nothing should build it; run-build itself does not check this.
  case "$qst|$qwhy" in
    "done|ticket $key already merged via "*) printf 'superseded'; return 0 ;;
  esac
  if command -v job_ledger_get >/dev/null 2>&1; then
    st=$(job_ledger_get abandoned "$PROJECT $key" 2>/dev/null); rc=$?
  fi
  if [ "$rc" = 0 ]; then
    [ "$st" = abandoned ] && { printf 'abandoned'; return 0; }
    return 1
  fi
  case "$qst|$qwhy" in
    "failed|ABANDONED by the blocked-resolver"*) printf 'abandoned'; return 0 ;;
  esac
  return 1
}

# stranded_push_rejected_reason <KEY> — the pool's push-rejected terminal reason
# for KEY into SPR_REASON (BH-7946): the pool_terminal row when
# bin/lib/pool-state-rows.sh is loaded and its knob is on, else the file
# state/pool/<project>/<KEY>.terminal. A read only: the pool owns both. rc 0
# read, 1 not readable (SPR_REASON empty).
SPR_REASON=""; SPR_PSR=""
stranded_push_rejected_reason() {
  local key="$1" row f="$HARNESS/state/pool/$PROJECT/$1.terminal"
  SPR_REASON=""
  if [ -z "$SPR_PSR" ]; then
    SPR_PSR=off
    # shellcheck source=bin/lib/pool-state-rows.sh
    command -v psr_terminal >/dev/null 2>&1 || { [ -r "$HARNESS/bin/lib/pool-state-rows.sh" ] && . "$HARNESS/bin/lib/pool-state-rows.sh" 2>/dev/null; }
    command -v psr_on >/dev/null 2>&1 && psr_on && psr_load "$PROJECT" && SPR_PSR=on
  fi
  if [ "$SPR_PSR" = on ] && row=$(psr_terminal "$key"); then
    SPR_REASON=$(jq -r '.reason // empty' <<<"$row" 2>/dev/null)
    [ -n "$SPR_REASON" ] && return 0
  fi
  [ -f "$f" ] && SPR_REASON=$(jq -r '.reason // empty' "$f" 2>/dev/null)
  [ -n "$SPR_REASON" ]
}

# stranded_reoffer <KEY> <issue> <why> — the stranded watch's launch (BH-5967).
# rc 0 when a fresh queue row went in, 1 otherwise (said). The ledger is
# state/stranded-watch/<project>/<KEY>.reoffers, one epoch per re-offer; the
# lines older than the window drop off. Past STRANDED_REOFFER_MAX in the window
# the ticket gets a NEEDS-HUMAN: marker with its last result instead of a row.
SW_DIR="$HARNESS/state/stranded-watch/$PROJECT"
# The push-rejected alert-once clock (BH-7946): box-local in
# catalog/state-paths.json; losing it costs one repeated alert line.
RJ_DIR="$HARNESS/state/stranded-push-rejected/$PROJECT"
stranded_reoffer() {
  local key="$1" num="$2" why="$3" led now cut n last row qst qwhy fp
  mkdir -p "$SW_DIR" 2>/dev/null
  led="$SW_DIR/$key.reoffers"; now=$(date -u +%s); cut=$(( now - REOFFER_WIN_H * 3600 ))
  if [ -f "$led" ]; then
    awk -v c="$cut" '$1 ~ /^[0-9]+$/ && $1 >= c' "$led" > "$led.tmp" 2>/dev/null && mv -f "$led.tmp" "$led"
  fi
  n=$(grep -c . "$led" 2>/dev/null); case "$n" in ''|*[!0-9]*) n=0 ;; esac
  row=""; command -v queue_row >/dev/null 2>&1 && row=$(queue_row "$PROJECT" "$key" 2>/dev/null)
  qst=$(printf '%s' "$row" | cut -f1); qwhy=$(printf '%s' "$row" | cut -f5)
  last="${qst:-no row}${qwhy:+: $qwhy}"
  # >>> push-rejected arm (BH-7946)
  # A pool push-rejected terminal is a branch question, not a re-offer one: a
  # re-offer runs into the same terminal. When the build's own RESULT line says
  # `branch-check=own`, `ancestor` or `ancestor-of-base` (bin/lib/rb/pr.sh), the
  # branch holds this ticket's own work or nothing past main, and the next pool
  # build resumes it (bin/lib/ticket-branch-resume.sh). A legacy reason with no
  # `branch-check=` token (from before BH-7946) is not held either, but its
  # alert says the branch was not checked. So these are not held: ONE ALERTS
  # line per key per window says how to recover. Every other verdict (foreign,
  # unreadable, open-pr, absent, tracked) and a reason nobody can read keeps
  # the hold, and its text names the branch head and the recovery step.
  local rj_br="" rj_head="" rj_first="" rj_mark rj_then rj_what hold_extra=""
  case "$last" in
    *"push to ticket/"*"rejected at"*)
      if [[ "$last" =~ push\ to\ ([^[:space:]]+)\ rejected\ at\ ([0-9a-f]{7,40}|unknown) ]]; then
        rj_br="${BASH_REMATCH[1]}"; rj_head="${BASH_REMATCH[2]}"
      fi
      if stranded_push_rejected_reason "$key" \
         && { [[ "$SPR_REASON" =~ branch-check=(own|ancestor|ancestor-of-base)([[:space:]]|$) ]] \
              || [[ "$SPR_REASON" != *"branch-check="* ]]; }; then
        if [[ "$SPR_REASON" == *"branch-check="* ]]; then
          rj_what="with no foreign commits — not held (BH-7946). Recover: comment RETRY on #$num; the next pool build resumes ${rj_br:-the branch} from its head"
        else
          rj_what="— branch not checked (a reason from before BH-7946), not held. Recover: read ${rj_br:-the branch}; if it is this ticket's work, comment RETRY on #$num"
        fi
        rj_mark="$RJ_DIR/$key.alerted"
        rj_then=$(head -n 1 "$rj_mark" 2>/dev/null); case "$rj_then" in ''|*[!0-9]*) rj_then=0 ;; esac
        if [ "$rj_then" -lt "$cut" ] \
           && "$HARNESS/bin/alert-line.sh" --project "$PROJECT" \
                "[stranded/$PROJECT] $key: push to ${rj_br:-its branch} rejected at ${rj_head:-unknown} $rj_what"; then
          mkdir -p "$RJ_DIR" 2>/dev/null; printf '%s\n' "$now" > "$rj_mark"
        fi
        log "stranded: $key (issue #$num) push-rejected on its own branch ${rj_br:-?} at ${rj_head:-unknown} — not held (BH-7946)"
        SKIP="${SKIP:+$SKIP,}$key:push-rejected-own"
        return 1
      fi
      [[ "$SPR_REASON" =~ (first=[0-9a-f]{7,40}\ by\ .*)$ ]] && rj_first="${BASH_REMATCH[1]}"
      hold_extra=" Branch ${rj_br:-?} head ${rj_head:-unknown}${rj_first:+: $rj_first}. Recover: if the branch is this ticket's work, open a PR from ${rj_br:-the branch}; otherwise move that work to another branch and comment RESUME."
      ;;
  esac
  # <<< push-rejected arm
  if [ "$n" -ge "$REOFFER_MAX" ]; then
    if [ -e "$SW_DIR/$key.needs-human" ]; then
      SKIP="${SKIP:+$SKIP,}$key:needs-human"; return 1
    fi
    fp=$(printf 'stranded %s %s' "$PROJECT" "$key" | cksum | awk '{printf "%08x", $1}')
    if "$HARNESS/bin/needs-human-hold.sh" "$PROJECT" "$num" "$fp" \
         "the stranded-ticket watch re-offered $key $n times in ${REOFFER_WIN_H}h and no PR came of it. Last result: $last. Read the newest build record for $key and decide; RESUME re-offers it.$hold_extra" \
         stranded-watch >/dev/null 2>&1; then
      printf '%s\t%s\n' "$now" "$last" > "$SW_DIR/$key.needs-human"
      log "stranded: $key (issue #$num) NEEDS_HUMAN — re-offered $n times in ${REOFFER_WIN_H}h with no PR; last result: $last"
    else
      log "stranded: $key (issue #$num) would be NEEDS_HUMAN ($n re-offers in ${REOFFER_WIN_H}h) but the marker could not be placed — retried next run"
    fi
    SKIP="${SKIP:+$SKIP,}$key:needs-human"
    return 1
  fi
  local qout=""
  if ! command -v queue_put >/dev/null 2>&1 \
     || ! qout=$(queue_put "$PROJECT" "$key" "$num" "" "" "$(jq -nc --argjson n "$((n + 1))" '{stranded_reoffer:$n}')" 2>/dev/null); then
    log "stranded: $key (issue #$num) is stranded ($why) but the queue did not take a row — retried next run"
    SKIP="${SKIP:+$SKIP,}$key:queue-unreachable"
    return 1
  fi
  # `duplicate` is rc 0 with nothing written: a row is already queued or
  # claimed. That is not a re-offer, so it is not counted toward NEEDS_HUMAN
  # (review of 99682a0c6).
  if [ "$qout" = duplicate ]; then
    log "stranded: $key (issue #$num) already has a queued or claimed row — nothing re-offered, nothing counted"
    SKIP="${SKIP:+$SKIP,}$key:already-queued"
    return 1
  fi
  printf '%s\n' "$now" >> "$led"
  : > "$MARKDIR/$key.enqueued" 2>/dev/null
  ENQ="${ENQ:+$ENQ,}$key"
  log "stranded: $key (issue #$num) re-offered with a fresh queue row ($((n + 1)) of $REOFFER_MAX in ${REOFFER_WIN_H}h) — stranded because: $why; last row: $last"
  return 0
}

# A TICKET THAT GOT ITS PR IS NOT STRANDED ANY MORE: its re-offer count and its
# NEEDS_HUMAN marker go, so a later strand starts a new count.
if [ "$STRANDED_MODE" = 1 ] && [ -d "$SW_DIR" ]; then
  awk -F'\t' '$3 == "OWNED" && $4 ~ /^pr:/ {print $1}' "$TD/verdicts.tsv" | while IFS= read -r _k; do
    rm -f "$SW_DIR/$_k.reoffers" "$SW_DIR/$_k.needs-human" 2>/dev/null
    rm -f "$RJ_DIR/$_k.alerted" 2>/dev/null
  done
fi

ENQ=""; SKIP=""; N_ENQ=0
while IFS=$'\t' read -r KEY NUM VERDICT WHY; do
  [ "$VERDICT" = ORPHAN ] || continue
  # GUARD RAIL: a ticket run-build refuses is not launched to be refused.
  if RB_WHY=$(refused_by_run_build "$KEY"); then
    SKIP="${SKIP:+$SKIP,}$KEY:$RB_WHY"
    continue
  fi
  # GUARD RAIL, not an owner class: a key whose build-key flock is HELD is
  # already building on this box, whatever the ledger says. Same lock
  # bin/run-build.sh takes for per-ticket dedupe (CLAUDE.md: locks are DEDUPE).
  if command -v preplan_held >/dev/null 2>&1 && preplan_held "$HARNESS/locks/build-key-$PROJECT-$KEY.lock"; then
    SKIP="${SKIP:+$SKIP,}$KEY:build-key-lock-held"
    continue
  fi
  # GUARD RAIL: a finished build whose board close-out has not been posted yet
  # is owned by the results sweep. Re-launching it would build a ticket whose
  # PLAN_BLOCKED questions nobody has answered.
  # NOT EVERY RESULT OWES A CLOSE-OUT (BH-5967). A `QUEUED_FLY <KEY>` dir is
  # run-build's routing stub: it is closed only when a newer pool result is
  # RELAYED, so a pool build that stood down, or a row that went FAILED, leaves
  # it open for ever. A stand-down (the DEFERRED sentinel or a BUILD_DEFERRED
  # head) owes nobody a close-out either (bin/pipeline-health.sh check 4 skips
  # the same two). On 2026-10-10 those dirs held back 34 cromford orphans
  # as awaiting-closeout on every tick. Neither shape is a result to post, and
  # this ticket is ownerless, so neither holds the relaunch.
  # A RELAYED dir is the hub's custody copy (BH-6956): the owning box's results
  # sweep writes COMMENTED on its own copy, so pipeline-health skips it too.
  UNSWEPT=0
  for D in "$HARNESS/builds/$PROJECT-$KEY-"*/ "$HARNESS/builds/pool-$PROJECT-$KEY-"*/; do
    [ -f "$D/RESULT" ] && [ ! -f "$D/COMMENTED" ] || continue
    [ -f "$D/RELAYED" ] && continue   # custody moved to the owning box's copy
    [ -f "$D/DEFERRED" ] && continue
    case "$(head -n 1 "$D/RESULT" 2>/dev/null)" in QUEUED_FLY*|BUILD_DEFERRED*) continue ;; esac
    UNSWEPT=1; break
  done
  if [ "$UNSWEPT" = 1 ]; then
    # BH-3953: a skip that repeats past CLOSEOUT_OVERDUE_S is a warn, not silence.
    command -v closeout_overdue_note >/dev/null 2>&1 && closeout_overdue_note "$HARNESS" "$PROJECT" "$KEY"
    SKIP="${SKIP:+$SKIP,}$KEY:awaiting-closeout"
    continue
  fi
  # GUARD RAIL, stranded watch only (BH-7116): the last build ended PLAN_BLOCKED
  # and nobody has answered since. A re-offer only blocks it again. Unknown
  # (rc 2: the queue or the thread could not be read) re-offers, as before.
  if [ "$STRANDED_MODE" = 1 ] && [ "${SKIP_PB:-1}" = 1 ] && command -v pb_stranded_skip >/dev/null 2>&1; then
    PB_CNT=$(jq -r --argjson n "$NUM" 'first(.[] | select(.number == $n)) | .commentCount // 0' "$TD/open.json" 2>/dev/null)
    PB_TH=""; [ -f "$TD/extra/thread-$NUM.json" ] && PB_TH="$TD/extra/thread-$NUM.json"
    if PB_AT=$(pb_stranded_skip "$PROJECT" "$KEY" "$PB_TH" "${PB_CNT:-0}"); then
      SKIP="${SKIP:+$SKIP,}$KEY:plan-blocked"
      log "stranded: $KEY (issue #$NUM) skip :: last build ended PLAN_BLOCKED at $PB_AT and no human comment since"
      continue
    fi
  fi
  if [ -n "$MAX_RUN" ] && [ "$N_ENQ" -ge "$MAX_RUN" ]; then
    SKIP="${SKIP:+$SKIP,}$KEY:cap"
    continue
  fi
  # The marker BEFORE the launch: it is the grace class's own input, so a run
  # that is killed between the two still leaves the next run standing down
  # instead of launching a second copy.
  if [ "$STRANDED_MODE" = 1 ]; then
    stranded_reoffer "$KEY" "$NUM" "$WHY" || continue
    N_ENQ=$((N_ENQ+1))
    continue
  fi
  : > "$MARKDIR/$KEY.enqueued" 2>/dev/null
  OUT="$HARNESS/logs/$PROJECT.$(printf '%s' "$KEY" | tr '[:upper:]' '[:lower:]')-reconcile.out"
  lock_spawn_unheld setsid "$HARNESS/bin/run-build.sh" "$PROJECT" "$NUM" "$KEY" > "$OUT" 2>&1
  ENQ="${ENQ:+$ENQ,}$KEY"
  N_ENQ=$((N_ENQ+1))
  log "reconcile: $KEY (issue #$NUM) had no owner — launched a build ($WHY)"
done < "$TD/verdicts.tsv"

if [ "$STRANDED_MODE" = 1 ]; then
  log "stranded-watch: open=$OPEN_N owned=$OWNED_N stranded=$ORPHAN_N reoffered=${ENQ:--} skipped=${SKIP:--} idle_min=$GRACE_MIN"
  # The count bin/pipeline-health.sh reads for its no-progress metric (BH-5967).
  mkdir -p "$SW_DIR" 2>/dev/null
  printf '%s\t%s\n' "$(date -u +%s)" "$ORPHAN_N" > "$SW_DIR/.count.tmp" 2>/dev/null && mv -f "$SW_DIR/.count.tmp" "$SW_DIR/.count"
  command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset
  exit 0
fi
log "reconcile: open=$OPEN_N owned=$OWNED_N orphans=$ORPHAN_N enqueued=${ENQ:--} skipped=${SKIP:--} cache=$C_HITS/$C_READS pl=$PRL stranded=$STRANDED_N"

# ---- the other half of the rule: every open PR has an owner too -------------
# Owner class (b) above reads an OPEN PR as proof that a ticket is owned, which
# is right while the merge conductor is working that PR and wrong the moment the
# PR itself has been abandoned: example-org/project-7 #323-#327 have been open since
# JUNE with no ledger row, no conductor state and no park, and every one of them
# has been holding its ticket hostage here for three months. bin/pr-owner-sweep.sh
# classifies the PRs the same way this script classifies tickets.
#
# DETACHED, because it makes its own gh calls and a triage tick must not grow a
# second network budget; and scoped to THIS repo, because the fleet-wide pass is
# a hub cron. This hook only ever reaches GitHub-Issues repos — the script above
# has already exited for an in-app board — so project-1/project-3/project-4/project-2 PRs
# are swept by the hub's cron alone, which is where the fleet-wide list lives.
if [ "${PR_OWNER_SWEEP:-1}" != 0 ] && ! lane_switch pr-owner-sweep-off file \
   && [ -x "$HARNESS/bin/pr-owner-sweep.sh" ]; then
  lock_spawn_unheld setsid "$HARNESS/bin/pr-owner-sweep.sh" --repo "$REPO" \
    > "$HARNESS/logs/$PROJECT.pr-owner-sweep.out" 2>&1
fi

# ONLY WHEN IT ENQUEUED SOMETHING. A reconciler that pages on every quiet tick
# is a reconciler nobody reads; the whole point is that "every ticket has an
# owner" is the normal, silent shape. An enqueue means the event path MISSED a
# ticket, which is a bug in the event path and is worth a line.
if [ -n "$ENQ" ]; then
  WHYS=$(awk -F'\t' '$3=="ORPHAN" {printf "%s (%s); ", $1, $4}' "$TD/verdicts.tsv" | sed 's/; $//')
  "$HARNESS/bin/lane-alert.sh" "orphan-reconcile/$PROJECT" \
    "reconciliation enqueued $N_ENQ ai-build issue(s) no event ever named: $ENQ. Each had no ledger row, no open PR, no open blocker, no hold and no fresh owner: $WHYS. The event-wake path missed them — check logs/$PROJECT.log for the gate reasons around now.${SKIP:+ Held back this run: $SKIP.}" \
    >/dev/null 2>&1 || true
fi
command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset
exit 0
