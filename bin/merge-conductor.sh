#!/bin/bash
# bin/merge-conductor.sh — hub cron (*/5): ONE owner for every harness PR from
# open to merged. Design and the why: docs/MERGE-CONDUCTOR.md.
#
# EACH PROJECT TICKS IN ITS OWN BACKGROUND SUBSHELL (2026-09-14): a slow authed
# rebase clone on one repo no longer holds every other project's PRs behind it,
# and the head-bound re-review is no longer run inline at all — it is a DETACHED
# per-PR job and the tick only reads its result (mc_rereview_spawn /
# mc_rr_state).
#
# AND EACH PR OF A PROJECT NOW TICKS UNDER ITS OWN LOCK (2026-09-15). The tick
# used to take one flock for the whole project and `flock -n || skipped`, which
# cost a busy repo its next one to three ticks in full: 102 skipped project
# ticks in the two hours of 2026-09-15 21:00-23:00Z. pr_worker holds
# locks/merge-conductor-<project>-<pr>.lock for one PR's work, the merge call
# alone is serialised on locks/merge-conductor-<project>-merge.lock
# (mc_merge_locked), the spend budgets became flock'd per-tick counter files, and
# each project logs ONE metrics line plus state/merge-conductor/tick-<p>.json
# saying how long its tick took and what it did. MC_PR_PARALLEL caps the
# workers; docs/MERGE-CONDUCTOR.md section 2.
#
# A FULL-TICK LOCK IS BACK, FOR UNKEYED TICKS ONLY (BH-5463, 2026-10-08).
# Overlapping full ticks doubled the API and re-review spend: the second one
# counted locked=82 of 100. locks/merge-conductor-<project>-fulltick.lock is
# held by a holder subshell that tick_project cannot see; keyed ticks skip it.
#
# THE REBASE AND THE DEPLOY VERIFIER ARE THE SAME SHAPE (2026-09-14, the operator).
# Both used to run from inside the tick, which holds the project's flock on
# fd 9 — the rebase for the minutes a clone + typecheck + push takes, the
# verifier for the twenty a deploy poll takes (a verifier spawned at 03:54Z on
# project-5 held that lock until 04:02Z and every tick in between skipped the
# project). Each is now its own detached lane with its own state dir and result
# file, spawned with the tick's lock fd CLOSED, and the tick only ever reads a
# result: mc_rebase_spawn / mc_rb_state, mc_dv_spawn / mc_dv_reap.
#
# FOUR WAYS A PR GOT STRANDED, ALL CLOSED 2026-09-14 (the operator, "fix the conductor
# problems"). Every one of them ended the same way — a row nothing moved and no
# alert that said so — and three of the four never reached an action at all:
#   1. mc_classify tested CI before DIRTY, and GitHub runs no pull_request
#      workflow on a conflicted PR, so every DIRTY PR answered `WAIT_CI checks
#      none` for ever and none ever reached mc_rebase (project-5 #799 4h,
#      #826/#838/#863 the same). The classifier now rebases a conflicted head
#      whatever CI says. See the DIRTY clause in the lib.
#   2. A PR parked on `provenance` never consumed the head-bound re-review it
#      had already bought (#864 APPROVE at 20:34Z, merged by hand at 20:45Z;
#      #867, #865, #866 the same). The done-job handling was the HEAD_MOVED
#      arm's alone; it is headbound_review now, and the provenance block below
#      calls it with the same four answers.
#   3. The stacked-child block never fired ON ANY PR, because `IFS=$'\t' read`
#      collapses an empty field (tab is IFS whitespace) and a PR with no labels
#      slid baseRefName into the labels variable: #868 sat an hour after its
#      parent merged with no retarget, #848/#850/#852 were never STACKED_WAIT.
#      The tsv emits `-` for every column that can be empty.
#   4. The tick bought a Fable review of a PR whose OWN build was still running
#      and about to review it (mc_job_running — a bounded wait, not a park).
#
# Every open harness PR in every fleet.conf repo (plus recently closed-unmerged
# ones) is put in exactly one named state — WAIT_CI, WAIT_REVIEW, HEAD_MOVED,
# NEEDS_REBASE, REBASING, BLOCKED_HUMAN, RED_TWICE, READY, QUEUED, MERGED, CLOSED —
# persisted as a jobs-ledger row (kind=pr_state) with a file mirror, aged against
# a budget, and moved forward by this script or handed to bin/blocked-resolver.sh.
# One log line per transition, one alert per PR per state — except the
# BLOCKED_HUMAN reasons the resolver owns (mc_resolver_owns), which log and do
# NOT page: the resolver drains them on an agent ladder and alerts once, on
# ABANDONED.
#
# NO STATE WITHOUT A NEXT MOVE, AND NOTHING SITS IN ONE FOR EVER (2026-09-15,
# the operator). Two halves, both here:
#   * THE RED LADDER. `WAIT_CI checks red once` had no next transition — the
#     red-twice park counts reds on DIFFERENT heads — so project-5 #1045 went
#     red at 02:04Z, was logged once, and was untouched for ten hours until it
#     was closed by hand. A red now buys ONE `gh run rerun --failed` of its
#     failing runs (mc_red_rerun, the flake path's mechanics for every red,
#     flake forgiveness unchanged) and a head that is still red after it is
#     RED_TWICE, which bin/blocked-resolver.sh owns like every BLOCKED_AGENT
#     reason.
#   * THE STUCK DETECTOR. Every state has a TTL (mc_ttl, MC_TTL_<STATE>), and a
#     PR past its state's TTL raises ONE alert per (PR, state, head) naming what
#     it is waiting on and takes the deterministic re-kick for that state where
#     one exists (stuck_rekick). #1124/#1136 parked for hours with no owner and
#     nothing said so.
#
# A REFUSED HEAD IS RE-REVIEWED BEFORE IT IS PARKED (2026-09-16, the operator's
# project-5 acceleration, lever 2). A moved head the patch-id rebind and the
# no-overlap rebind could not vouch for used to have two fates, and they were
# decided by WHO HAD ALREADY SPOKEN. With no head-bound word it went HEAD_MOVED
# and bought a detached Claude read; with the BUILD's own gate saying
# `blocked@<this head>` it went straight to BLOCKED_HUMAN `head-not-reapproved`
# and bin/blocked-resolver.sh owed it a FULL agent fix round — 61 of those on
# project-5 on 2026-09-16, each one a lane, a branch and a park, for a refusal
# authored by whatever runner that build's survival ladder happened to reach.
#
# Both fates are the same one now: BUY THE READ FIRST. The row stays HEAD_MOVED
# while the detached head-bound re-review runs (the tick waits for nothing, as
# ever), and what our own read answers decides it —
#   APPROVE   the approval is rebound to the new head and the PR merges as
#             normal, with no fix round and no park at all.
#   BLOCK     NOW the BLOCKED_HUMAN `head-not-reapproved` hand-off, with the
#             findings posted on the PR, exactly as it reads today. The refusal
#             is recorded per (PR, head) (mc_hb_refuse), so every later tick of
#             that head agrees and the row cannot oscillate.
#   no answer a LANE failure, not a verdict: the job file is forgotten and ONE
#             more read is bought (rereview_lane_retry), then today's
#             `no-verdict` park. Nothing here is on a clock — the retry fires on
#             the event of a dead job and the park on the event of a second one.
# MC_REREVIEW_ON_MOVE=0 restores the immediate park, byte-for-byte. A DIRTY or
# CONFLICTING head still parks on sight whatever the knob says: GitHub runs no
# workflow on a head that cannot merge, so the CI-green debounce would defer
# that read for ever (BH-491). docs/MERGE-CONDUCTOR.md section 4.
#
# FLAGS (docs section 8). Absent = observe-only: classify, rows, alerts, no
# gh write, no push.
#   flags/merge-conductor-actions   rebase DIRTY PRs, buy the head-bound re-review
#   flags/merge-conductor-merge     merge READY PRs (needs -actions too)
#   flags/merge-conductor-observe   pins observe-only even with the two above
#   flags/automerge-disabled        the fleet kill switch: states+alerts only
# Every gh call runs on a repo-scoped GitHub App installation token when this box
# has one (bin/lib/gh-app-auth.sh), otherwise on the PAT bin/lib/gh-repo-token.sh
# picks for the repo (project-5 and project-7 need the admin PAT); a repo no token
# can see is an alert, never an empty loop. No token value ever reaches a log.
set -uo pipefail
# BH-7635: the PR keys of a take-back tick, set by mc_proj_gate
# (bin/lib/mc/project-placement.sh); empty = the whole project.
MC_PROJ_TAKEBACK_KEYS=""
# BH-2303: every model call this lane makes names the lane, so its cost rows
# carry lane_id and its LLM_* knobs (on/off, runners, daily cap) bind it alone.
export AGENT_CALL_LANE=merge-conductor
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")
export HARNESS="$H"
# fleet-conf.sh prefers /root/harness/fleet.conf; point it at THIS tree's registry
# so a scratch HARNESS (the fixtures) drives a scratch fleet. Identical in prod.
[ -f "$H/fleet.conf" ] && export FLEET_CONF="${FLEET_CONF:-$H/fleet.conf}"
mkdir -p "$H/logs" "$H/locks" "$H/state" "$H/flags" 2>/dev/null
if [ -f "$HENV/global.env" ]; then set -a; # shellcheck disable=SC1091
  . "$HENV/global.env"; set +a; fi
# shellcheck source=/dev/null
[ -r "$H/bin/jobs-client.sh" ] && . "$H/bin/jobs-client.sh"
# Carry an iron-law acceptance across heads (BH-4474). Missing, ilc_covered is
# undefined and the per-head marker is the only acceptance, as before.
# shellcheck source=bin/lib/ironlaw-carry.sh
[ -r "$H/bin/lib/ironlaw-carry.sh" ] && . "$H/bin/lib/ironlaw-carry.sh"
# One owner per ticket (BH-1526): the merge-time HOLD and one-PR-per-ticket.
# shellcheck source=bin/lib/ticket-ownership.sh
[ -r "$H/bin/lib/ticket-ownership.sh" ] && . "$H/bin/lib/ticket-ownership.sh"

# --- BH-1132: the lane's one off-switch -------------------------------------
# flags/all-off, flags/lane-off-merge-conductor, or the D1 pause_flags row of the
# same name stops this tick (exit 0 — a paused lane is not a failure). With no
# flag and no row this returns immediately and the lane behaves exactly as it
# always has, and an unreachable worker fails OPEN to the last cached answer.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off merge-conductor.
# shellcheck disable=SC1091
. "${H}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit merge-conductor
# THE KNOBS, BELOW THE ENV LOAD (BH-1165). The gate above stops this lane; this
# is what lets a settings row reach its own unmodified ${KNOB:-default} reads.
# It is BELOW `set -a; . env/global.env` on purpose: above it, the env file
# re-assigns every name and the row silently loses. Fails open — with no row,
# nothing is exported and the lane behaves byte-for-byte as it does today.
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    merge-conductor
# BH-4659 (BH-4656.1): the open list and its per-PR merge-state reads come from
# the shared snapshot (bin/lib/gh-pr-list.sh reads HPL_SNAPSHOT). The decision
# and readback reads (mc_pr_view, mc_rest_pr_json, mc_pr_live_head) stay live.
# shellcheck source=bin/lib/pr-snapshot.sh
. "$H/bin/lib/pr-snapshot.sh" 2>/dev/null || true
command -v prs_open_list >/dev/null 2>&1 && export HPL_SNAPSHOT=1

# shellcheck source=bin/lib/gh-repo-token.sh
[ -r "$H/bin/lib/gh-repo-token.sh" ] && . "$H/bin/lib/gh-repo-token.sh"
# shellcheck source=bin/lib/gh-app-auth.sh
[ -r "$H/bin/lib/gh-app-auth.sh" ] && . "$H/bin/lib/gh-app-auth.sh"
# shellcheck source=bin/lib/gh-limit-logger.sh
[ -r "$H/bin/lib/gh-limit-logger.sh" ] && . "$H/bin/lib/gh-limit-logger.sh"
# shellcheck source=bin/lib/gh-budget.sh
[ -r "$H/bin/lib/gh-budget.sh" ] && . "$H/bin/lib/gh-budget.sh"
# shellcheck source=bin/lib/gh-pr-list.sh
[ -r "$H/bin/lib/gh-pr-list.sh" ] && . "$H/bin/lib/gh-pr-list.sh"
# shellcheck source=bin/lib/merge-conductor-lib.sh
# The lib sources bin/lib/gh-rest.sh, which is what every decision read below
# goes through — 0 acted on, 44 ABSENT, 75 UNVERIFIABLE (#768). The marker is
# what tests/gh-no-graphql-decision-guard-test.sh scans this file for.
# gh-rest: no-graphql
. "$H/bin/lib/merge-conductor-lib.sh"
# >>> tick scope (BH-6518)
# The keyed-tick parse, the full-tick window, the tick mode, the tick
# prelude, the main-red detector call, the per-project fan-out and the fleet
# sweeps live in bin/lib/mc/tick-scope.sh, a
# driver-only file (no module header, so the lib's other users never load
# it). A box mid-sync can see
# this script new and that file missing or old: the tick refuses, before any
# GitHub read, rather than run a scope it cannot parse.
# shellcheck source=bin/lib/mc/tick-scope.sh
if ! . "$H/bin/lib/mc/tick-scope.sh" || ! declare -F mc_keyed_tick_parse >/dev/null || ! declare -F mc_full_tick_window >/dev/null || ! declare -F mc_tick_mode >/dev/null || ! declare -F mc_tick_prelude >/dev/null || ! declare -F mc_tick_fanout >/dev/null || ! declare -F mc_tick_main_red >/dev/null || ! declare -F mc_tick_sweeps >/dev/null; then
  HARNESS="$H" "$H/bin/alert-line.sh" --id conductor-module-missing "CONDUCTOR MODULE MISSING: bin/lib/mc/tick-scope.sh is missing or unusable on $(hostname) — the box's bin/ is half-synced; no PR was ticked this tick" 2>/dev/null || true
  mc_log "bin/lib/mc/tick-scope.sh is missing or unusable — refusing the tick"
  exit 1
fi
# <<< tick scope (BH-6518)
# The REST contract the review poster's comment goes out on (BH-783): sourcing
# it costs no API budget and has no side effect, and without it rp_post can only
# answer "not posted".
# shellcheck source=bin/lib/gh-rest.sh
[ -r "$H/bin/lib/gh-rest.sh" ] && . "$H/bin/lib/gh-rest.sh"
# The review poster (BH-641): renders the findings a review carries into the
# body it posts, and writes the review + its raw envelope into the build record
# BEFORE the network call.
# shellcheck source=bin/lib/review-post.sh
[ -r "$H/bin/lib/review-post.sh" ] && . "$H/bin/lib/review-post.sh"
# A box mid-sync can carry this script with the old bin/lib — the same staggered
# sync every other gate here degrades for. With no renderer the comment is the
# agent's stdout, which is this script's behaviour before BH-641, line for line:
# unrendered is bad, and losing the comment entirely would be worse.
# mc_pr_comment (bin/lib/mc/classify.sh) is the REST writer BH-783/784 moved
# this lane's comments onto — sourced by the lib two lines above, body by
# file, no GraphQL (this file carries BH-784's `# gh-rest: no-graphql`
# marker). It already returns 75 on anything that did not land — a bad token,
# bad args, or a real HTTP failure — so there is no "not attempted" rc left to
# retry through a second channel; that retry is how a PR got two copies of
# one review.
command -v rp_post >/dev/null 2>&1 || rp_post() {
  local body rc
  printf -- '-\n'
  body=$(printf '%s\n\n---\n%s\n' "$(cat "$3" 2>/dev/null)" "$5")
  mc_pr_comment "$4" "$body"; rc=$?
  return "$rc"
}
# shellcheck source=bin/lib/hotfix-lib.sh
[ -r "$H/bin/lib/hotfix-lib.sh" ] && . "$H/bin/lib/hotfix-lib.sh"
# The self-enqueue (BH-1668): an approved, green, clean PR on a Mergify
# repo gets one `@mergifyio queue` per head, posted with a PAT. Optional like
# the libs above: a tree without it runs this tick exactly as before.
# shellcheck source=bin/lib/autoenqueue.sh
[ -r "$H/bin/lib/autoenqueue.sh" ] && . "$H/bin/lib/autoenqueue.sh"
# shellcheck source=bin/lib/mc-hold-comment.sh
[ -r "$H/bin/lib/mc-hold-comment.sh" ] && . "$H/bin/lib/mc-hold-comment.sh"
# The external-author enqueue (BH-4580), same optional rule: it rides on
# autoenqueue.sh's gates and send, and does nothing without them.
# shellcheck source=bin/lib/mc/external-enqueue.sh
[ -r "$H/bin/lib/mc/external-enqueue.sh" ] && . "$H/bin/lib/mc/external-enqueue.sh"
# The landing contract's shadow decisions (BH-6744), same optional rule: a tree
# without it ticks exactly as before, and its default mode `queue` reads nothing.
# shellcheck source=bin/lib/mc/landing.sh
[ -r "$H/bin/lib/mc/landing.sh" ] && . "$H/bin/lib/mc/landing.sh"
# The per-PR workers on lane-run machines (BH-6495), same optional rule: a
# tree without it starts every worker on this box, as before.
# shellcheck source=bin/lib/mc/fly-workers.sh
[ -r "$H/bin/lib/mc/fly-workers.sh" ] && . "$H/bin/lib/mc/fly-workers.sh"
# The stale-dequeue requeue (BH-3480). Optional like the libs above: a tree
# without it ticks exactly as before.
# shellcheck source=bin/lib/mc-stale-dequeue.sh
[ -r "$H/bin/lib/mc-stale-dequeue.sh" ] && . "$H/bin/lib/mc-stale-dequeue.sh"
# The batch-reset classifier (BH-5372): observe only. A tree without it ticks
# exactly as before.
# shellcheck source=bin/lib/mc-batch-reset.sh
[ -r "$H/bin/lib/mc-batch-reset.sh" ] && . "$H/bin/lib/mc-batch-reset.sh"
# The queue waste ledger (BH-5374): CI minutes per batch draft run. A tree
# without it ticks exactly as before.
# shellcheck source=bin/lib/mc-batch-minutes.sh
[ -r "$H/bin/lib/mc-batch-minutes.sh" ] && . "$H/bin/lib/mc-batch-minutes.sh"
# The `full` label runs one batch (BH-7290): taken off after a completed batch.
# A tree without it ticks exactly as before.
# shellcheck source=bin/lib/mc-full-label-expiry.sh
[ -r "$H/bin/lib/mc-full-label-expiry.sh" ] && . "$H/bin/lib/mc-full-label-expiry.sh"
# The foreign-red attribution for the BH-636 re-entry arm (BH-3776). A tree
# without it gates re-entry on the raw merge state alone, as before.
# shellcheck source=bin/lib/mc-foreign-red.sh
[ -r "$H/bin/lib/mc-foreign-red.sh" ] && . "$H/bin/lib/mc-foreign-red.sh"
command -v fr_reentry_gate >/dev/null 2>&1 || {
  fr_reentry_gate() { FR_WHY=""; FR_LINE=""; [ "$6" = CLEAN ]; }
  fr_requeue_note() { :; }
}
# Mergify's own culprit/bystander verdict for the same arm (BH-4428): wraps
# fr_reentry_gate. A tree without it gates re-entry exactly as above.
# shellcheck source=bin/lib/mc-batch-eject.sh
[ -r "$H/bin/lib/mc-batch-eject.sh" ] && . "$H/bin/lib/mc-batch-eject.sh"
# Why a head left the queue, and the pre-queue gate before its requeue
# (BH-6161). A tree without it ejects and requeues exactly as before.
# shellcheck source=bin/lib/mc-eject-cause.sh
[ -r "$H/bin/lib/mc-eject-cause.sh" ] && . "$H/bin/lib/mc-eject-cause.sh"
# The stuck-PR timers (BH-7241): CI never started, a failed rebase, red on two
# heads. A tree without it ticks exactly as before. MC_FIX_NOW_ON is NOT
# exported: only this process launches a resolver from mc_transition.
# shellcheck source=bin/lib/mc-stuck-timers.sh
[ -r "$H/bin/lib/mc-stuck-timers.sh" ] && . "$H/bin/lib/mc-stuck-timers.sh"
MC_FIX_NOW_ON=1
# The pre-queue isolation gate (BH-4545). A tree without it enqueues a READY
# head exactly as before.
# shellcheck source=bin/lib/mc-prequeue.sh
[ -r "$H/bin/lib/mc-prequeue.sh" ] && . "$H/bin/lib/mc-prequeue.sh"
# The lead-cleared head (BH-3778). Optional like the libs above: a tree
# without it ticks exactly as before.
# shellcheck source=bin/lib/mc-lead-ready.sh
[ -r "$H/bin/lib/mc-lead-ready.sh" ] && . "$H/bin/lib/mc-lead-ready.sh"
# The ci-timeout budget (BH-3775). Optional like the libs above: a tree without
# it ticks exactly as before.
# shellcheck source=bin/lib/mc-ci-timeout.sh
[ -r "$H/bin/lib/mc-ci-timeout.sh" ] && . "$H/bin/lib/mc-ci-timeout.sh"
# The fast parent merge (BH-5520). Optional: a tree without it ticks as before.
# shellcheck source=bin/lib/mc-stack-fast.sh
[ -r "$H/bin/lib/mc-stack-fast.sh" ] && . "$H/bin/lib/mc-stack-fast.sh"
# The Sentry reporter (BH-5617): the WORKER_DEADLINE and autoenqueue-ledger
# events. Optional like the libs above: without it, the `command -v
# sentry_report` guards are false and the tick runs as before.
# shellcheck source=bin/lib/sentry-report.sh
[ -r "$H/bin/lib/sentry-report.sh" ] && . "$H/bin/lib/sentry-report.sh"
# ph_knob for the pr_owner.enroll_external kill switch (BH-3933). A tree
# without it reads the switch as off, so no enrolled external PR is evaluated.
# shellcheck source=bin/lib/pr-health.sh
[ -r "$H/bin/lib/pr-health.sh" ] && . "$H/bin/lib/pr-health.sh"
# >>> merge-conductor.d fragments (BH-7453)
# A new optional lib is its own file, bin/merge-conductor.d/<key>-<name>.sh,
# not one more source line above: bin/list-file-lint.sh refuses that. Each
# regular *.sh there is sourced once, in LC_ALL=C name order, after the in-file
# libs. A fragment that fails to source is one log line, and the tick goes on.
mapfile -t _mc_frags < <(set +f; for _f in "$H"/bin/merge-conductor.d/*.sh; do [ -f "$_f" ] && printf '%s\n' "$_f"; done | LC_ALL=C sort)
for _mc_frag in "${_mc_frags[@]}"; do
  # shellcheck source=/dev/null
  . "$_mc_frag" || mc_log "merge-conductor.d: ${_mc_frag##*/} failed to source (rc $?); skipped this tick"
done
unset _mc_frags _mc_frag
# <<< merge-conductor.d fragments (BH-7453)
# The fan-in assertion (BH-186): every PR a project tick launches a worker for is
# accounted when the worker returns, and a tick that lost one says so. A tree
# without the lib ticks exactly as before: no ledger, and the worker runs bare.
# shellcheck source=bin/lib/fanin.sh
. "$H/bin/lib/fanin.sh" 2>/dev/null || {
  fanin_begin() { :; }; fanin_enumerate() { :; }; fanin_end() { :; }
  fanin_run_sub() { shift 2; "$@"; }
  fanin_trap_run() { :; }; fanin_streak() { echo 0; }; mc_fanin_solo() { return 1; }; fanin_account() { :; }
  mc_worker_bounded() { pr_worker "$@"; }
  mc_window_cap() { :; }; mc_window_defer() { :; }; mc_fanin_mark_locked() { :; }
  mc_step() { :; }
}
# Lane liveness (BH-638). Optional exactly like the libs above: a box whose
# harness sync has not landed bin/lib/heartbeat.sh runs this tick byte-for-byte
# as it did before, because the three calls become no-ops.
# shellcheck source=bin/lib/heartbeat.sh
[ -r "$H/bin/lib/heartbeat.sh" ] && . "$H/bin/lib/heartbeat.sh"
command -v hb_tick >/dev/null 2>&1 || { hb_start(){ :; }; hb_tick(){ :; }; hb_done(){ :; }; }
# shellcheck source=bin/lib/gh-push-identity.sh
[ -r "$H/bin/lib/gh-push-identity.sh" ] && . "$H/bin/lib/gh-push-identity.sh"
# A conductor running out of a tree that has no hotfix-lib (the neighbouring
# fixtures copy two libs and nothing else) answers "not a hotfix" to everything,
# which is this script's behaviour before BH-369, line for line.
command -v hotfix_pr_is >/dev/null 2>&1 || hotfix_pr_is() { return 1; }
# PAUSES (BH-1672 / BH-1684). A merges pause is a row in the jobs worker's
# `pauses` table, mirrored into state/pauses.json; bin/lib/pause.sh is the one
# reader. Optional like the libs above: a tree without it answers "not paused"
# to everything, which is this lane before BH-1672, line for line.
# shellcheck source=bin/lib/pause.sh
[ -r "$H/bin/lib/pause.sh" ] && . "$H/bin/lib/pause.sh"
command -v pause_active >/dev/null 2>&1 || {
  pause_active() { return 1; }; pause_label() { :; }; pause_refresh() { return 0; }; pause_env_shapes() { :; }; }
mc_init
# Once per tick, before anything reads the cache. Bounded, and it keeps the last
# cache on an outage, so a worker that is down never stops the tick.
pause_refresh || true
# THE KEYED TICK (BH-1387, BH-1841): MC_ONLY_PR -> MC_ONLY_KEYS. The parse is
# mc_keyed_tick_parse, in bin/lib/mc/tick-scope.sh (BH-6518).
mc_keyed_tick_parse
# THE FULL-TICK WINDOW (BH-5521): MC_FULL_TICK_BUDGET_S -> MC_WORKERS_DONE_BY.
# The window is mc_full_tick_window, in bin/lib/mc/tick-scope.sh (BH-6518).
mc_full_tick_window
# THE KEYED READY-ARM FLOOR (BH-7376): when the launcher opted in
# (MC_KEYED_READY_FLOOR=1), a READY row's PR worker gets at least
# MC_KEYED_READY_ARM_S, so one READY PR can go through prequeue AND enqueue.
command -v mc_keyed_deadline_floor >/dev/null 2>&1 && mc_keyed_deadline_floor
# THE FULL-TICK CLOCK (BH-7139): a full tick stamps its start and logs
# FULL_TICK wall_s= at its end; bin/merge-conductor-wake.sh alerts once on a
# full tick older than 2 cron periods. Optional: a tree without the lib ticks
# as before.
# shellcheck source=bin/lib/mc-tick-clock.sh
[ -r "$H/bin/lib/mc-tick-clock.sh" ] && . "$H/bin/lib/mc-tick-clock.sh"
command -v mc_tick_clock_start >/dev/null 2>&1 && mc_tick_clock_start
# NO GLOBAL LOCK (2026-09-14), AND SINCE 2026-09-15 NO PROJECT LOCK EITHER. The
# parallelism boundary and the single-instance guard are now the per-PR lock
# pr_worker takes (mc_pr_lock): two overlapping ticks can never handle the same
# PR at once, and they no longer need to agree about a whole repo to do it.
# BH-5463 adds back ONE project lock, for full (unkeyed) ticks only: see the
# `>>> full-tick lock` block in mc_tick_fanout (bin/lib/mc/tick-scope.sh).

flag_on() { # the file is the flag; flag_active reconciles it from the DB row first
  if command -v flag_active >/dev/null 2>&1; then flag_active "$1"; else [ -f "$H/flags/$1" ]; fi
}
# THE TICK MODE (BH-1201, BH-1672): the fleet flags and the fleet merges pause
# -> KILL, ACTIONS, MERGES, MODE and the exported MC_MODE. The rule is
# mc_tick_mode, in bin/lib/mc/tick-scope.sh (BH-6518). It calls flag_on, so the
# call stays after the flag_on definition above.
mc_tick_mode
# The cron line is */30 since C2, and bin/merge-conductor-backstop.sh runs keyed
# ticks every 5 minutes under `timeout 240`, so the rhythm is 300 and the
# expected-by is 30 minutes. A killed tick is normal: as a `cron` lane (BH-4717)
# it is judged by its last completed tick, the stamp hb_done writes.
hb_start merge-conductor 300 1800 "PR merges fleet-wide" "" cron

# THE TICK PRELUDE: the spend budgets, the isInMergeQueue knobs, the re-review
# cap file, the knobs the detached lanes inherit and the tick id. They are set
# by mc_tick_prelude, in bin/lib/mc/tick-scope.sh (BH-6518). It reads
# MC_STATE_DIR, so the call stays after mc_init.
mc_tick_prelude

use_token() { # use_token <slug> — rc 1 when no token can see the repo (already alerted)
  # TOKEN RESOLUTION ONLY; every caller and every gh call below is unchanged.
  # A repo-scoped App installation token first (2026-09-14, the operator: one PAT is one
  # 5000/h bucket for the whole fleet, which is the ceiling at 4000 builders, and
  # one leak is fleet-wide forever). An installation token that minted is a token
  # that can see the repo by construction, so the invisible-repo probe and its
  # alert are not needed for it — they stay exactly as they are for the PAT path,
  # which is what an unarmed box takes.
  # The default-identity helper (#469) is ONE call for both halves: the App
  # token when this box can mint one for the repo, today's PAT probe when it
  # cannot, and GH_LIMIT_IDENTITY tagged either way so a rate-limit refusal says
  # which bucket ran out. A box mid-harness-sync still has the old lib, which is
  # what the command -v guard is for — its two branches below are unchanged.
  #
  # WHICH CREDENTIAL ANSWERED IS LOGGED (BH-597, ticket item 2), once per tick
  # per slug — tick_project calls this once per project, so the line needs no
  # dedupe file of its own. The WORDS app/default/admin and never a token value.
  # #469's own tag (GH_LIMIT_IDENTITY, "app:<slug>" or "pat:<slug>") already
  # says which bucket answered, so the log line asks gh_limit_identity_label
  # (bin/lib/gh-app-auth.sh) for it rather than reading the tag itself — GH_
  # LIMIT_IDENTITY is auth plumbing that file owns, not a knob this script
  # reads and never assigns (tests/lanes-registry-test.sh section 7).
  if command -v gh_default_auth_for_slug >/dev/null 2>&1; then
    if gh_default_auth_for_slug "$1"; then
      case "$(gh_limit_identity_label)" in
        app) mc_log "$1: github auth: App installation token (this tick's gh calls bill the installation)" ;;
        *)   mc_log "$1: github auth: default PAT" ;;
      esac
      return 0
    fi
    command -v gh_repo_invisible_alert >/dev/null 2>&1 && gh_repo_invisible_alert merge-conductor "$1" "conductor cannot list its PRs"
    return 1
  fi
  if command -v gh_auth_for >/dev/null 2>&1 && gh_auth_for "$1"; then
    mc_log "$1: github auth: App installation token (this tick's gh calls bill the installation)"
    return 0
  fi
  if command -v gh_repo_use_token >/dev/null 2>&1; then
    gh_repo_use_token "$1" || { gh_repo_invisible_alert merge-conductor "$1" "conductor cannot list its PRs"; return 1; }
    # `app` IS ONE OF THE FOUR ANSWERS HERE. gh_auth_for above refuses on an
    # empty mint, but gh-repo-token.sh's own App rung mints again with
    # --min-life and verifies the repo is visible, so this ladder can hand back
    # an installation token after the rung above declined it. Printing
    # "$(gh_repo_token_for) PAT" would then log "app PAT" — a credential that
    # does not exist, in the one line an operator reads to know what a tick
    # spent. `none` cannot reach here: gh_repo_use_token returns 1 for it and
    # the alert above already fired.
    local _mc_tok; _mc_tok=$(gh_repo_token_for "$1")
    case "$_mc_tok" in
      app) mc_log "$1: github auth: App installation token (this tick's gh calls bill the installation)" ;;
      *)   mc_log "$1: github auth: $_mc_tok PAT" ;;
    esac
  else
    mc_log "$1: github auth: default PAT"
  fi
  return 0
}
# Both resets run: gh_auth_reset restores the GH_TOKEN this process started with
# whichever of the two paths above exported something, and gh_repo_token_reset is
# unchanged for the boxes that have no App configured.
reset_token() {
  command -v gh_default_auth_reset >/dev/null 2>&1 && gh_default_auth_reset
  command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset
  command -v gh_repo_token_reset >/dev/null 2>&1 && gh_repo_token_reset
  return 0
}

# ---- closed-unmerged discovery from the harness's OWN records (BH-1592) -----
# The settle used to page the repo's raw closed list (3 x 100, author-filtered
# on the client). On a repo where another author closes most PRs, that cap is
# reached before any of ours: project-9 had 11 harness PRs in its last 300
# closed, and one closed a little later than it was created was never seen.
# So the candidates are PR numbers the harness already knows are its own — this
# slug's non-terminal pr-state rows, its build records, and a closed-watch memo
# written the first time the open list shows a PR (drafts and record-less
# ticket/* PRs have neither of the other two) — and each is read by number,
# through gh_rest and so with If-None-Match. At most GH_PR_LIST_REST_PAGES
# reads a tick, which is what the walk it replaces cost.
#
# The memo is state/merge-conductor/closed-watch/<safe-slug>/<num>, one line:
# state (open|closed|merged|gone) TAB last-probe epoch TAB url TAB branch.
# It is a memo, never the record of a settle: the CLOSED row is. Losing it
# costs one re-probe per candidate.
MC_CLOSED_WATCH_DIR="$MC_STATE_DIR/closed-watch"

# ---- a PR whose head LAGS its branch tip (BH-1529) --------------------------
# 2026-09-22, #1480: the branch was pushed to b3bd7457 and GitHub's PR object
# kept answering head 1cfafae7 for ~20 minutes. The pushed head had zero check
# runs and nothing moved until the lead closed and reopened the PR by hand.
# ci_absent_kick and the retarget kick both act on a head the PR object KNOWS
# about; this is the shape where the PR object has not heard of the head at all.
#
# So each tick compares the list's head sha with the branch tip (REST branches
# endpoint: ETag-cached, so an unchanged branch is a 304 that costs no counted
# read, and memoised per tick). A mismatch older than MC_HEAD_LAG_MINS is closed
# and reopened ONCE per tip — the attempt is in the PR's state file, so no tick
# after it can loop — and a mismatch that outlives the reopen by the same window
# pages ONCE. Fork PRs (their head ref names a branch in someone else's repo) and
# a tip that cannot be read are skipped: unverifiable is never a mismatch.
#
# The state file, one line:
#   <head> <tip> <since> <spent-at|0> <alerted 0|1> <outcome> <refused-closes> <held-at|0>
# where outcome is `-` (not spent), `pending` (written before the kick, so a
# kick that dies half-way still counts as spent), `reopened`, `closed` (LEFT
# CLOSED, mc_kick_ci already paged) or `refused` (GitHub refused the close on
# MC_KICK_REOPEN_TRIES ticks; nothing on GitHub changed), and held-at is when a
# hold last kept this tip from its kick (cached for
# MC_HEAD_LAG_HELD_RECHECK_MINS). Since BH-1564 that file is a read-through
# cache: every change is also a `headlag` pr_attempts row (behind the
# pr-state-rows flag), and a file that does not hold the tip reads the record
# back from the rows — so a wiped state dir or a hub move cannot buy a tip a
# second reopen or a second page. bin/lib/mc/rebase.sh lists the row facts.

# pr_worker <tsv-row> — ONE open PR of the project ticking, from the classifier
#   to the action, under that PR's own lock. Called with `&` from tick_project,
#   so it is a subshell: nothing it assigns is visible to the tick or to the
#   other PRs, which is precisely why the spend budgets are files now.
#
#   It reads the project's context (SLUG, QUEUE, PROVIDER, PBASE, TIGHT,
#   INQ_IN_LIST, MAIN_RED, P) from the tick that forked it, and the flag globals
#   (ACTIONS, MERGES, MODE) from the script. It writes nothing shared except
#   through functions that take their own lock: mc_row_put, the counters, and
#   the append-only attempts/cap files.
pr_worker() {
  local ROW="$1"
  # 1 from the READY transition on: every later mc_step logs STEP_START/STEP_END
  # (BH-6351, THE STEP LINES at bin/lib/fanin.sh mc_step).
  local MC_STEP_LOG=0
  IFS=$'\t' read -r NUM URL HEAD BR DRAFT MSTATE MGABLE PSTATE RAWINQ RAWLBL BASEREF UPDATED CROSS <<<"$ROW"
  # The placeholders come straight back off again: every consumer below was
  # written against "" for absent, and `-` is a tsv concern, not theirs.
  [ "$RAWLBL" = "-" ] && RAWLBL=""
  [ "$BASEREF" = "-" ] && BASEREF=""
  [ "${UPDATED:--}" = "-" ] && UPDATED=""
  [ -n "$NUM" ] || return 0
  # One la_decide per (PR, head) per tick (BH-3806, mc_la_decide): the memo is
  # this worker's, and a stale key from the forking shell must never answer.
  MC_LA_MEMO_KEY=""
  # The per-PR tick as well as the per-project one: a tick whose project list is
  # short but whose PRs are slow is alive, and the heartbeat has to say so.
  hb_tick merge-conductor "pr $NUM"
  [ "$DRAFT" = true ] && return 0
  KEY="$SLUG#$NUM"
  # BH-1585 (review round 1): the open list reads each PR's merge state over
  # REST, and a read that failed marks ONLY that row UNVERIFIABLE instead of
  # blinding the repo. Such a row is not a state to classify: this PR's row is
  # left exactly as it is and the PR waits for the next tick, the same answer an
  # unverifiable decision read below gives. Every other PR proceeds.
  # BH-1634: the skip counts toward the PR's streak, and the count rides the
  # same single log line.
  if [ "$MSTATE" = UNVERIFIABLE ]; then
    local uc; uc=$(unverif_note "$P" "$KEY" "$URL")
    mc_log "$KEY merge state UNVERIFIABLE this tick (the list's per-PR read failed) — row left as-is, retried next tick (unverifiable $uc/$(unverif_ticks_for "$P") ticks)"
    return 0
  fi
  unverif_clear "$KEY"
  mc_count_inc "$P" prs >/dev/null
  # THIS TICK'S HOTFIX CLEARS ITS OWN LINE, on every exit path (BH-369): the PR
  # that turns out not to be READY, the one whose lock another tick holds, the
  # one whose merge fails. A marker that outlives its worker would defer the
  # repo's plain PRs behind a PR nothing is merging. The answer comes from the
  # marker the tick wrote before any worker started, so the parent and the
  # worker cannot disagree about which PR is the emergency.
  mc_step lock-probe
  HOTFIX_THIS=0
  if hotfix_pending_is "$P" "$NUM"; then HOTFIX_THIS=1; trap 'hotfix_pending_drop "$P" "$NUM"' EXIT; fi
  # THE LOCK IS THIS PR'S, NOT THE PROJECT'S (2026-09-15). Everything below —
  # the verdict read, the classifier, the rebase spawn, the re-review dispatch,
  # the deploy-verify read — is about PR $NUM and nothing else, so it is guarded
  # by PR $NUM's own flock. A worker of an earlier tick that is still here costs
  # this PR one tick and costs the rest of the repo NOTHING; the whole-project
  # skip it replaces cost 102 PR-ticks in the two hours of 2026-09-15 21:00Z.
  # The fd is released by the kernel when this worker exits, so there is nothing
  # to expire and no way to wedge a PR — provided no detached child inherits it,
  # which is what the 9>&- on every setsid line in the lib is for.
  exec 9>"$(mc_pr_lock "$P" "$NUM")"
  mc_pr_lock_take || { mc_count_inc "$P" locked >/dev/null
    # A PR another worker holds is a PR this tick's land fan-out did not reach,
    # so the base sha must not be recorded as handled over it (BH-870).
    [ "${LAND_FIRE:-0}" = 1 ] && mc_count_inc "$P" landdeferred >/dev/null
    mc_log "$KEY: an earlier conductor worker still holds this PR's lock — skipped (every other PR of $P carries on)"
    # Fan-in reads this as skipped:locked, which keeps the PR's streak (BH-4842).
    mc_fanin_mark_locked
    [ "$(mc_row_field "$KEY" 2 2>/dev/null)" = READY ] && mc_ready_why "$KEY" "$HEAD" worker-locked "an earlier conductor worker still holds this PR's lock — skipped this tick" logged
    return 0; }
  REC=$(mc_record_for "$URL" || true)
  # A PR bin/pr-owner-sweep.sh enrolled on this head is evaluated as ours
  # (BH-3933). The check WRAPS the probe instead of joining its test: the marker
  # lines stay at column 2 because tests/pr-dep-gate-rest.bh-994-test.sh extracts
  # the block between them verbatim and runs it with no HEAD in scope.
  if mc_enrolled_pr "$REC" "$BR" "$SLUG" "$NUM" "$HEAD"; then
    mc_attempt_has "enrolled-pr $KEY $HEAD" || { mc_attempt_put "enrolled-pr $KEY $HEAD"; mc_log "$KEY enrolled by pr-owner-sweep on ${HEAD:0:7}: evaluated as ours"; }
  else
  # >>> harness pr probe
  # THE BODY PROBE IS REST, NEVER `gh pr view` (BH-994, 2026-09-19). This is the
  # tick's SECOND GraphQL body read per PR — the dep gate's was the first — and
  # together they emptied the App installation's 6600 points/h GraphQL budget
  # while its REST budget sat at 3141/6600. Between 17:53Z and 18:04Z every
  # READY cromford row was held with merges=0 on four consecutive ticks;
  # `gh pr view` answered "GraphQL: API rate limit already exceeded for
  # installation ID 161623167" and the holds cleared by themselves when the
  # window reset at 18:04:42Z. A GraphQL failure HERE is worse than a dep-gate
  # hold: an unreadable body reads as "not a harness PR", so the tick writes the
  # not-harness line and walks away from a PR that is ours.
  #
  # The read is pr_body_read -> mc_pr_view -> bin/lib/gh-rest.sh: the same REST
  # contract every other decision read in this file goes through, so BH-994's
  # endpoint is reached by ONE implementation, not a second `gh api` spelling.
  # mc_is_harness_pr runs it only when the two cheap tests both miss (a build
  # record, a ticket/* branch), so the common harness PR still costs no read at
  # all — the same laziness as before, over the budget that has room.
  #
  # "NO MARKER" MUST MEAN WE LOOKED (BH-784). The body read is the last of the
  # three tests and it is LAZY — most PRs never reach it — so the rc cannot be
  # taken before the call, and mc_is_harness_pr runs it down a pipe where a
  # variable set in the subshell dies. The flag file is how the rc gets back:
  # pr_body_read writes it when GitHub refused, and the log line then says the
  # body was unread instead of claiming the marker is absent from a body nobody
  # saw. The decision is unchanged either way — no marker we can see, no build.
  BODY_UNREAD="${TMPDIR:-/tmp}/mc-body-unread.$$.$NUM"; rm -f "$BODY_UNREAD"
  if ! mc_is_harness_pr "$BR" "$REC" pr_body_read "$URL" "$BODY_UNREAD"; then
    if [ -f "$BODY_UNREAD" ]; then WHYNH="body unread (HTTP $(mc_rest_status)) — asked again next tick"; NHKEY="not-harness-unread"
    else WHYNH="no marker"; NHKEY="not-harness"; fi
    rm -f "$BODY_UNREAD"
    # Two dedupe keys, because they are two different sentences: the refused
    # read gets ONE line while the outage lasts, and the real "no marker" still
    # gets its own line when the body finally reads.
    mc_attempt_has "$NHKEY $KEY" || { mc_attempt_put "$NHKEY $KEY"; mc_log "$KEY not a harness PR (branch $BR, no record, $WHYNH) — ignored"; }
    return 0
  fi
  rm -f "$BODY_UNREAD"
  # <<< harness pr probe
  fi
  # THE LANE'S HEALTH IS OBSERVED BEFORE ANY RETURN (BH-1019 review round 2).
  # mc_lane_epoch is a LATCH: it compares the lane's condition now against the
  # one last written and bumps on a change. A row that returns before reading it
  # never observes the transition — and the sticky return below is exactly such
  # a return, about five hundred lines above where MC_HB_PARKED is computed. So
  # a no-verdict park, still sticky, sat through the whole down->up recovery
  # without the epoch ever moving, and the release this change exists to give it
  # depended on some OTHER lane (br_rereview, per resolver tick) happening to
  # read the latch first. Read here, the observation is this row's own.
  # THE OLD head-lag SPAN IS FOUR STEPS (BH-6670): lane-epoch, head-lag,
  # handoff-sticky, park-holds. A kill names the one that was running, and the
  # trail times each. bin/lib/fanin.sh holds a step timeout in a read-only one.
  mc_step lane-epoch
  MC_LANE_EPOCH=$(mc_lane_epoch)
  # A HEAD THE PR OBJECT HAS NOT CAUGHT UP WITH (BH-1529) is read before every
  # other arm — they would all be judging a head GitHub is still reporting
  # wrong — and AFTER the lane-epoch observation above, which must see every
  # row before any return (BH-1019).
  # BH-6810: head-lag logs STEP_START/STEP_END on every run (knob
  # MC_STEP_LOG_HEAD_LAG, default 1, 0 = only when slow), so the next slow read
  # shows where the time went. The flag is restored for the steps after it.
  local mc_sl0="$MC_STEP_LOG"
  [ "${MC_STEP_LOG_HEAD_LAG:-1}" = 0 ] || MC_STEP_LOG=1
  mc_step head-lag
  MC_STEP_LOG="$mc_sl0"
  head_lag_check "$P" "$KEY" "$SLUG" "$NUM" "$URL" "$HEAD" "$BR" "${CROSS:--}" && return 0
  # A HAND-OFF TO THE RESOLVER IS STICKY (2026-09-14). This row is parked with
  # bin/blocked-resolver.sh and nothing this tick can do moves it, so the tick
  # does nothing at all with it: no verdict read, no merge-tree test, no rebase
  # spawn, no re-review, no merge, and — the part that matters — no
  # re-classification. Re-classifying is what flipped project-5 #759 out of
  # BLOCKED_HUMAN 22 seconds after the hand-off and made it invisible to the
  # lane that owns it. See mc_handoff_sticky for how the park ends.
  # THE ONE WAY A PERSON ENDS A PARK (BH-292): the release label on the PR. The
  # labels are already in this row (RAWLBL, off the same list read), so it costs
  # nothing to ask, and a release is honoured ONCE per (PR, head) — a label that
  # stays on the PR (observe mode never removes it, and a removal can fail) must
  # not release every re-park on that head and recreate the oscillation.
  mc_step handoff-sticky
  if mc_handoff_sticky "$KEY" "$HEAD"; then
    # A PARK ON OUR OWN RE-REVIEW BLOCK IS RE-CHECKED FOR A NEWER HUMAN MERGE
    # (BH-3814). A lead/human MERGE row on this exact head, newer than the
    # BLOCK, ends the park: the approval is rebound and the resolver's fix round
    # is never bought. rc 1 and rc 2 (verdicts unreadable) keep the park.
    case "$(mc_row_field "$KEY" 7)" in head-not-reapproved*)
      if [ "$ACTIONS" = 1 ] && command -v mc_hv_override >/dev/null 2>&1 && mc_hv_override "$KEY" "$HEAD"; then
        mc_attempt_put "hvoverride $KEY $HEAD"
        mc_attempt_clear hbrefused "$KEY" "$HEAD"
        mc_handoff_release "$KEY" human-verdict
        mc_log "$KEY human verdict #$MC_HV_ID overrides re-review BLOCK on ${HEAD:0:8} — park released, approval rebound; bin/blocked-resolver.sh starts no fix round: $URL"
        hb_approve_bind moved "$KEY" "$SLUG" "$P" "$NUM" "$URL" "$REC" "$HEAD" "$MSTATE" \
          "$(printf '_Merge conductor: human verdict #%s (%s, %s) on %s is newer than the re-review BLOCK of this head, so it stands. Park released, approval rebound, no agent fix round._' "$MC_HV_ID" "$MC_HV_VERDICT" "$MC_HV_AT" "${HEAD:0:12}")" \
          "" "human verdict #$MC_HV_ID overrides re-review BLOCK on ${HEAD:0:8}; reclassify next tick"
        return 0
      fi ;;
    esac
    if mc_handoff_human_release "$KEY" "$HEAD" "${RAWLBL:-}" "$URL"; then
      mc_log "$KEY RELEASED by the $MC_RELEASE_LABEL label on ${HEAD:0:8} ($(mc_row_field "$KEY" 7)) — this head's rebase attempt is forgotten and the PR classifies again now; the label works once per head, so a fresh park on this same head stays parked until the head moves: $URL"
      # Observe mode releases the park locally (classifying a row is not a
      # GitHub write) and leaves the label where the person put it.
      if [ "$ACTIONS" = 1 ]; then
        mc_label_remove "$URL" "$MC_RELEASE_LABEL" \
          || mc_log "$KEY the $MC_RELEASE_LABEL label could not be removed — take it off by hand (gh pr edit $URL --remove-label $MC_RELEASE_LABEL) or it releases the next park on the next head: $URL"  # gh-guard-allow: prose in a log line, not a call
      fi
      # ...and fall through: this PR classifies exactly like any un-parked one.
    else
      mc_handoff_sticky_log "$KEY" "$URL" "$HEAD"
      return 0
    fi
  fi
  # A MEMBER OF A LIVE BATCH TRAIN IS LEFT ALONE (BH-498). bin/batch-resolve.sh
  # has this PR's approved head merged into a union branch that is on its way
  # through the queue; merging it here as well would land the same work twice
  # and re-dirty every sibling in that train, which is the tail the train exists
  # to end. The hold is keyed on the HEAD, so a push to this branch ends it by
  # construction and the PR comes straight back to this lane. One line per
  # (PR, head), like every other marker.
  mc_step park-holds
  if TRAINURL=$(mc_batch_held "$SLUG" "$NUM" "$HEAD"); then
    # COUNTED BEFORE THE RETURN. The batch lane is spawned off this counter, and
    # a held member is exactly a PR that lane owns — counting it only after the
    # early return meant a repo whose every approved PR was in a train scored
    # ZERO, the lane was never spawned, and nothing read the train's landing.
    mc_count_inc "$P" batchable >/dev/null
    mc_attempt_has "batchheld $KEY $HEAD" 2>/dev/null \
      || { mc_attempt_put "batchheld $KEY $HEAD"
           mc_log "$KEY HELD on ${HEAD:0:8} — this approved head is a member of the batch train ${TRAINURL:-?}; bin/batch-resolve.sh closes it out when the train lands: $URL"; }
    return 0
  fi
  # A LOSER OF A CONTESTED HOLD IS PARKED, NOT MERGED (BH-589). bin/blocked-resolver.sh
  # wrote a hold naming who WON a path this PR also rewrites, and merging the loser
  # first is the rebuild-on-the-same-conflict tail #579 exists to end. Same shape
  # as the batch hold above: no gh write, no page (contested is in
  # mc_resolver_owns), one attempts line per (PR, hold), and it sits BEFORE the
  # verdict read so a parked loser buys no re-review and no rebase either.
  #
  # IT IS DELIBERATELY NOT STICKY (contested is not in mc_handoff_owns): a hold
  # that vanishes without a release — expired, deleted by hand — lets the row
  # fall straight back to ordinary classification on the next tick instead of
  # freezing on a fact that is no longer true.
  if CL=$(mc_contested_loser "$P" "$SLUG" "$NUM"); then
    # One hold at a time: several holds can name this PR a loser, and the first
    # one is enough to park it. The next tick re-parks on whatever is still live.
    CL=$(head -1 <<<"$CL"); CPATH=$(cut -f1 <<<"$CL"); CWIN=$(cut -f2 <<<"$CL")
    CWHY="contested:$CPATH (winner $CWIN)"
    CHASH=$(basename "$(mc_contested_file "$P" "$CPATH")")
    if [ "$(mc_row_field "$KEY" 2)" != BLOCKED_HUMAN ] || [ "$(mc_row_field "$KEY" 7)" != "$CWHY" ]; then
      CREV=$(mc_row_field "$KEY" 5)
      mc_transition "$KEY" BLOCKED_HUMAN "$CWHY" "$HEAD" "${CREV:--}" "$URL" "-" "$MSTATE" "$REC" >/dev/null
    fi
    mc_attempt_has "contested $KEY $CHASH" 2>/dev/null \
      || { mc_attempt_put "contested $KEY $CHASH"
           mc_log "$KEY PARKED on ${HEAD:0:8} — loser of the contested hold on $CPATH (winner $CWIN); bin/blocked-resolver.sh owns it and nothing here merges it until the winner lands or the hold expires: $URL"; }
    return 0
  fi
  mc_step verdict-read
  command -v mc_vr_begin >/dev/null 2>&1 && mc_vr_begin
  # HEADBOUND is the head-bound gate's answer BOUND TO THE HEAD IT JUDGED:
  # `n/a` bare, or `<word>@<sha>` for reapproved|blocked|no-verdict, or "-" for
  # a record written before it existed. It only steers a PR whose head MOVED,
  # and only when the sha it names IS that head — `blocked@<this head>` is a
  # reviewer who already read exactly this code.
  IFS=$'\t' read -r VERDICT PROV REVIEWED JOB HEADBOUND <<<"$(mc_verdict "$URL" "$REC")"
  # A CONTRADICTION (BH-4585): on an older head it is head-moved (mc_classify),
  # on this head it parks quoting both verdicts.
  MC_CONTRA=""
  if [ "$VERDICT" = CONTRADICTION ]; then
    if [ -n "$REVIEWED" ] && [ "$REVIEWED" != "-" ] && [ "$REVIEWED" != "$HEAD" ]; then
      mc_log "$KEY verdict contradiction is on ${REVIEWED:0:8}, not the head ${HEAD:0:8}: treated as head-moved, the head-bound re-review decides"
    else
      MC_CONTRA=$(mc_contradiction_words "$URL" "$REC")
    fi
  fi
  # The audit of a base-conflict rebase whose push GitHub already lists
  # (BH-1677); rebase_consume below audits the one it reads itself.
  mc_vr_run -w eject-rebased eject_rebased_moved "$KEY" "$SLUG" "$NUM" "$URL" "$HEAD"
  # A cut verdict read (BH-8020) decides nothing on this PR this tick.
  command -v mc_vr_end >/dev/null 2>&1 && ! mc_vr_end && return 0
  mc_step rebase-result
  # A FINISHED DETACHED REBASE IS READ FIRST (2026-09-14). Its result is the
  # newest fact about this PR, and applying it is this tick's whole business
  # with that PR — exactly as the inline rebase was.
  rebase_consume "$KEY" "$SLUG" "$NUM" "$URL" "$REC" "$HEAD" "$REVIEWED" "$VERDICT" "$MSTATE" && return 0
  # AN OWED lead-verdict PUBLISH IS RETRIED HERE (BH-4596). A rebind whose
  # status POST failed (or ran with merges off) left a vs-owed file; it is paid
  # on the first LATER tick its head is still the head and still approved, and
  # voided otherwise. Before the rebind block on purpose: a rebind this tick
  # has just tried, and a second POST in the same tick is not a retry. No owed
  # file = one stat, no gh call. See mc_rebind_publish.
  if [ "$ACTIONS" = 1 ]; then
    if [ "$VERDICT" = APPROVE ] && [ "$REVIEWED" = "$HEAD" ]; then
      mc_rebind_publish "$KEY" "$P" "$SLUG" "$NUM" "$URL" "$HEAD" || true
    else
      mc_rebind_publish "$KEY" "$P" "$SLUG" "$NUM" "$URL" "$HEAD" - || true
    fi
  fi
  # PATCH-ID APPROVAL REBIND, before anything classifies. Two halves of one
  # rule: remember the patch of an approved head while it IS the head, and
  # when the head has moved, rebind the approval if the patch is the same
  # one. A DIRTY PR is excluded — it needs the rebase first, and mc_rebase
  # rebinds on its own push. See rebind_patch_id above.
  if [ "$ACTIONS" = 1 ] && [ "$VERDICT" = APPROVE ] && [ -n "$REVIEWED" ] && [ "$REVIEWED" != "-" ]; then
    if [ "$REVIEWED" = "$HEAD" ]; then
      mc_git_locked "$P" mc_patch_id_remember "$REC" "$SLUG" "$P" "$NUM" "$HEAD" || true
    elif [ "$MSTATE" != DIRTY ] && rebind_patch_id "$KEY" "$P" "$SLUG" "$NUM" "$URL" "$REC" "$REVIEWED" "$HEAD"; then
      REVIEWED="$HEAD"
    # THE OVERLAP REBIND IS THE SECOND CHANCE (W2-D, 2026-09-14), on exactly
    # the heads patch-id could not vouch for: the merge that moved this PR's
    # base touched no file this PR touches, so nothing a reviewer read has
    # changed. Same guards as the line above — approved, a real reviewed sha,
    # not DIRTY — and the same consequence, a rebind instead of a Fable call.
    # MC_OVERLAP_REREVIEW=0 removes this arm and the elif chain is the one it
    # was before.
    elif [ "${MC_OVERLAP_REREVIEW:-1}" != 0 ] && [ "$MSTATE" != DIRTY ] && \
         rebind_no_overlap "$KEY" "$P" "$SLUG" "$NUM" "$URL" "$REC" "$REVIEWED" "$HEAD"; then
      REVIEWED="$HEAD"
    fi
  fi
  # A STANDING LEAD MERGE ON THIS HEAD IS AN APPROVAL BOUND TO IT (BH-3778).
  # On a governed repo, a lead/human MERGE or MERGE-WITH-NOTES row on the live
  # head that la_decide lets the lane clear stands in for a builder APPROVE the
  # head has moved past (or never had). Never over a builder BLOCK. Everything
  # below is unchanged: the stacked park, CI, the block gate, the budget and
  # mc_enqueue_mergify's per-head ask. See bin/lib/mc-lead-ready.sh.
  if command -v mc_lead_ready >/dev/null 2>&1 \
     && mc_lead_ready "$KEY" "$SLUG" "$NUM" "$HEAD" "$VERDICT" "$REVIEWED" "$HEADBOUND"; then
    VERDICT=APPROVE; REVIEWED="$HEAD"
  fi
  mc_step ci-read
  # THE CHECK-RUN READ IS MEMOISED ACROSS TICKS (BH-1486), on terminal answers
  # only. The fingerprint is computed BEFORE the read on purpose: everything
  # below that touches CI on this head — the red mark a few lines down, a
  # flake kick, a rerun — appends to $MC_ATTEMPTS, so the number the NEXT tick
  # compares against is already different and the memo is invalid by
  # construction. A hit feeds the same `$CI` variable every arm below reads,
  # so the classifier's inputs are the same words a fresh read would give.
  MC_MEMO_FP=$(read_memo_fp "$KEY" "$HEAD")
  # BH-6346: MC_CI_READ_HELD=1 tells mc_classify this tick's CI read was cut
  # at its bound, so the row stays WAIT_CI and is never READY on an unread CI.
  MC_CI_READ_HELD=0
  if CIMEMO=$(read_memo_get ci "$KEY" "$HEAD" "$UPDATED" "$MC_MEMO_FP"); then
    CI="$CIMEMO"; mc_count_inc "$P" cimemo >/dev/null
  else
    # BH-6346: a plain command into a tick file, never $( ), so mc_ci_state's
    # MC_CI_READ_HELD reaches this worker. A read cut by MC_CI_READ_TIMEOUT_S is
    # `unavailable`, as any failed read, plus one CI_READ_HELD line per
    # (PR, head): no alert, no Sentry, no memo, the next tick reads again.
    CIF="$MC_TICK_DIR/ci-state.$BASHPID"; mkdir -p "$MC_TICK_DIR" 2>/dev/null
    mc_ci_state "$SLUG" "$HEAD" > "$CIF" 2>/dev/null || true
    CI=$(cat "$CIF" 2>/dev/null); rm -f "$CIF"; [ -n "$CI" ] || CI=unavailable
    [ "$CI" = unavailable ] || MC_CI_READ_HELD=0
    if [ "$MC_CI_READ_HELD" = 1 ] && ! mc_attempt_has "cireadheld $KEY $HEAD"; then
      mc_attempt_put "cireadheld $KEY $HEAD"
      mc_log "$KEY CI_READ_HELD reason=read-timeout on ${HEAD:0:8} (bound $(mc_ci_read_timeout_s)s): the actions/runs read passed its bound; the row stays WAIT_CI this tick, no alert, the next tick reads again"
    fi
    case "$CI" in green|red) read_memo_put ci "$KEY" "$HEAD" "$UPDATED" "$MC_MEMO_FP" "$CI" ;; esac
  fi
  # A non-required check does not hold a PR (BH-8012): pending/red becomes
  # green when every required check is green (fragment bh-8012-required-ci).
  MC_CI_REQUIRED_GREEN=0; command -v mc_cireq_apply >/dev/null 2>&1 && mc_cireq_apply
  # The strike ledger: one `red <key> <head>` per DIFFERENT head of this PR
  # that went red, not the same red seen on two ticks. Since BH-1671 it is a
  # record only — mc_classify no longer parks on it (`red-ci-twice` counted
  # across heads); a red head is judged on its own ladder below.
  # A red whose failing tests are ALL known flakes (the ci_flakes ledger:
  # >= FLAKY_MIN distinct heads each inside the window) buys ONE
  # `gh run rerun --failed` per (PR, head) INSTEAD of a strike — see
  # mc_flake_rerun, docs/FLAKY-TESTS.md. The STRIKE bookkeeping is unchanged:
  # every other red still records its strike on sight, and the second red on
  # the same head still counts.
  #
  # AND EVERY RED NOW CLIMBS A LADDER (2026-09-15, project-5 #1045). The line
  # above forgives a flake; this one gives a REAL red its next transition,
  # which `checks red once` never had — #1045 went red at 02:04Z, was logged
  # once, and was still in WAIT_CI ten hours later because the strike counter
  # only moves when a NEW head goes red. mc_red_rung is where this (PR, head)
  # stands: 0 nothing tried, 1 one rerun of the failed jobs in flight,
  # 2 red again on the same head — and 2 is RED_TWICE, which the resolver owns.
  # A push resets the ladder by construction: the mark is keyed on the head.
  REDS=0; MC_RED_RUNG=0
  # RED ON TWO CONSECUTIVE SETTLED HEADS (BH-7241) skips the one-rerun rung:
  # MC_RED_CONSEC is what mc_classify reads to answer RED_TWICE at once. The
  # logic is bin/lib/mc-stuck-timers.sh's; without it the variable stays empty.
  MC_RED_CONSEC=""
  case "$CI" in green|red) command -v mst_cihead_put >/dev/null 2>&1 && mst_cihead_put "$KEY" "$HEAD" "$CI" ;; esac
  if [ "$CI" = red ]; then
    MC_RED_RUNG=$(mc_red_rung "$KEY" "$HEAD")
    [ "$ACTIONS" = 1 ] && [ "$MC_RED_RUNG" = 0 ] && command -v mst_red_known >/dev/null 2>&1 && MC_RED_CONSEC=$(mst_red_known "$KEY" "$HEAD")
    if [ -z "$MC_RED_CONSEC" ] && [ "$ACTIONS" = 1 ] && [ "$MC_RED_RUNG" = 0 ] && mc_flake_rerun "$SLUG" "$KEY" "$HEAD"; then
      MC_RED_RUNG=1
    else
      mc_attempt_has "red $KEY $HEAD" || mc_attempt_put "red $KEY $HEAD"; REDS=$(mc_attempt_count red "$KEY")
      if [ "$ACTIONS" = 1 ] && [ "$MC_RED_RUNG" = 0 ] && [ -z "$MC_RED_CONSEC" ]; then
        command -v mst_red_consec >/dev/null 2>&1 && MC_RED_CONSEC=$(mst_red_consec "$SLUG" "$KEY" "$HEAD")
        if [ -z "$MC_RED_CONSEC" ]; then
          mc_red_rerun "$SLUG" "$KEY" "$HEAD" || true
          MC_RED_RUNG=$(mc_red_rung "$KEY" "$HEAD")
        fi
      fi
    fi
  fi
  # ---- the flake ladder (BH-636) ------------------------------------------
  # A KILLED RUNNER IS NOT A CODE FAILURE, and it is not an idle head either.
  # mc_ci_state now drops `timed_out` with `cancelled`, which is right and which
  # on its own would leave those heads sitting in `checks none` waiting for a run
  # nobody is going to start. This is the other half: the runs that died are
  # named, re-run ONCE in full, and said out loud.
  #
  # ASKED FOR TWO SHAPES ONLY, because it is one extra API read per row:
  #   ci=none              every run we can see was cancelled/timed_out
  #   ci=green + BLOCKED/UNSTABLE   every run we can SEE passed, but a required
  #                        context is not green — i.e. the run that would have
  #                        reported it was the one that died
  # and never on a DIRTY/CONFLICTING head, where GitHub runs nothing by design
  # and the rebase owns the row.
  #
  # The rung is the RED ladder's mark (`cirerun`), shared on purpose: one rerun
  # per head whoever buys it. Rung 2 is not RED_TWICE here — the resolver's
  # ladder ends in a fresh rebuild, and rebuilding a ticket because a runner was
  # OOM-killed twice is the exact waste this exists to stop. It is one ALERTS
  # line with an owner, and the row stays WAIT_CI.
  mc_step identity
  # >>> identity block
  # BEFORE THE FLAKE LADDER, BECAUSE THE LADDER IS THE BURNED RETRY (BH-800,
  # 2026-09-18). `green:BLOCKED` is one of the two shapes the ladder answers, so
  # a PR blocked on a PUSH PERMISSION bought a second actions/runs read every
  # tick and, at rung 0, a full CI re-run — neither of which can add this token
  # to a branch's push allow-list. One protection read per (repo, base) per
  # tick, cached in a file because the workers are subshells; a box without
  # bin/lib/gh-push-identity.sh behaves as it always did, and so does every
  # verdict the read could not settle.
  MC_IDENTITY_BLOCKED=0; MC_IDENTITY_WORD=""
  if [ "$MSTATE" = BLOCKED ] && [ "$CI" != red ] && [ "$MGABLE" != CONFLICTING ] \
     && [ -n "${BASEREF:-}" ] && command -v gh_push_blocked_verdict >/dev/null 2>&1; then
    IDVF=$(identity_verdict_file "$SLUG $BASEREF"); mkdir -p "$MC_TICK_DIR" 2>/dev/null
    # READ-OR-COMPUTE IS ONE CRITICAL SECTION, because MC_PR_PARALLEL defaults to
    # 0 = unlimited: every PR of a repo reaches this line inside the same second.
    # Unlocked, each would see no file and buy its own protection read (42 PRs =
    # the spend this ticket exists to stop), and a worker reading the file
    # mid-truncate would get nothing back and run the flake ladder after all. The
    # file is its own lock, the way mc_count_file is; fd 9 is opened by the
    # SUBSHELL only, so the PR lock pr_worker holds on fd 9 is untouched.
    IDVLINE=$(
      ( flock 9 2>/dev/null
        if [ ! -s "$IDVF" ]; then
          IFS=$'\t' read -r IDPST IDPJSON <<<"$(gh_branch_protection "$SLUG" "$BASEREF")"
          if [ "$IDPST" = ok ]; then
            IDWORD=$(gh_token_identity)
            printf '%s\t%s\t%s\n' "$(gh_push_blocked_verdict "$IDPJSON" "$IDWORD")" "$IDWORD" \
              "$(gh_push_allowlist_summary "$IDPJSON")" > "$IDVF"
          else
            printf '%s\t-\t-\n' "$IDPST" > "$IDVF"
          fi
        fi
        cat "$IDVF" ) 9>>"$IDVF" 2>/dev/null )
    IFS=$'\t' read -r IDV IDWORD IDLIST <<<"$IDVLINE"
    if [ "$IDV" = identity ]; then
      MC_IDENTITY_BLOCKED=1; MC_IDENTITY_WORD="$IDWORD"
      mc_log "$KEY IDENTITY_NOT_PERMITTED $SLUG $MC_IDENTITY_WORD: mergeState BLOCKED on $BASEREF with no required checks and no required reviews — this identity cannot push (push allow-list: $IDLIST); no flake rerun, no re-review, no merge attempt on it: $URL"
      # ONE page per (repo, identity, day) across every worker of the repo, so
      # the check and the append are one critical section too — this marker is
      # the only one in MC_ATTEMPTS that is not keyed by PR, so it is the only
      # one two workers can race for. Same lock file mc_attempt_clear takes.
      IDDAY=$(date -u +%Y%m%d)
      IDOWN=$( ( flock 9 2>/dev/null
        grep -qxF "identityalert $SLUG $MC_IDENTITY_WORD $IDDAY" "$MC_ATTEMPTS" 2>/dev/null && exit 0
        echo "identityalert $SLUG $MC_IDENTITY_WORD $IDDAY" >> "$MC_ATTEMPTS"; printf 1
      ) 9>>"$MC_ATTEMPTS.lock" 2>/dev/null )
      if [ "$IDOWN" = 1 ]; then
        mc_alert "$KEY" WAIT_CI "IDENTITY_NOT_PERMITTED $SLUG $MC_IDENTITY_WORD — add it to repos/$SLUG/branches/$BASEREF/protection/restrictions (a repo admin; this box cannot). Every approved PR on $SLUG is held until then: $URL"
      fi
    fi
  fi
  # <<< identity block
  MC_FLAKE=""; MC_CI_FLAKE=0; MC_FLAKE_RUNG=0; MC_CI_TIMEOUT_FIRING=0; MC_CI_TIMEOUT_CHECK=""; MC_CI_TIMEOUT_T=""; CIT_RUNS_LEFT=""; CIT_SKIP_RUNG=0
  if [ "$MC_IDENTITY_BLOCKED" != 1 ] && [ "$MSTATE" != DIRTY ] && [ "$MGABLE" != CONFLICTING ]; then
    # BH-8012: green:UNSTABLE:1 = every required check passed and only
    # non-required ones are not green, so a cancelled run buys no rerun.
    case "$CI:$MSTATE:${MC_CI_REQUIRED_GREEN:-0}" in
      green:UNSTABLE:1) ;;
      none:*|green:BLOCKED:*|green:UNSTABLE:*) MC_FLAKE=$(mc_ci_flake_runs "$SLUG" "$HEAD") ;;
    esac
  fi
  if [ -n "$MC_FLAKE" ]; then
    MC_CI_FLAKE=1
    # BH-3775: the ci-timeout budget sees the flake list first and answers what
    # is left for the rungs below. MC_FLAKE itself is never changed here.
    CIT_RUNS_LEFT=$MC_FLAKE
    if command -v cit_assess >/dev/null 2>&1; then
      cit_assess "$SLUG" "$KEY" "$HEAD" "${BASEREF:-}" "$NUM" "$MC_FLAKE"
      MC_CI_TIMEOUT_FIRING=$CIT_FIRING; MC_CI_TIMEOUT_CHECK=$CIT_CHECK; MC_CI_TIMEOUT_T=$CIT_T
    fi
    if [ "${CIT_SKIP_RUNG:-0}" != 1 ] && [ -n "$CIT_RUNS_LEFT" ]; then
      MC_FLAKE_RUNG=$(mc_red_rung "$KEY" "$HEAD")
      FLAKENAMES=$(cut -d'|' -f2 <<<"$CIT_RUNS_LEFT" | tr '\n' ';' | sed 's/;$//')
      case "$MC_FLAKE_RUNG" in
        0) if [ "$ACTIONS" = 1 ]; then
             mc_flake_kick "$SLUG" "$KEY" "$HEAD" "$CIT_RUNS_LEFT" || true
             MC_FLAKE_RUNG=$(mc_red_rung "$KEY" "$HEAD")
           else
             mc_log "$KEY would re-run $(wc -l <<<"$CIT_RUNS_LEFT") cancelled/timed_out run(s) on ${HEAD:0:8} ($FLAKENAMES) — observe mode: nothing written"
           fi ;;
        1) mc_log "$KEY flake rerun in flight on ${HEAD:0:8} ($FLAKENAMES) — waiting for the fresh run to report" ;;
        *) if ! mc_attempt_has "flakealert $KEY $HEAD" 2>/dev/null; then
             mc_attempt_put "flakealert $KEY $HEAD"
             mc_alert "$KEY" WAIT_CI "CI_FLAKE_TWICE: $FLAKENAMES cancelled/timed out again on ${HEAD:0:8} after one full rerun — a killed runner is not a code failure, so nothing here will park this PR for you; check the runner (OOM on a 16GB hosted runner?) or re-run it by hand: $URL"
             mc_log "$KEY CI_FLAKE_TWICE $KEY $HEAD ($FLAKENAMES) — one full rerun spent and the runs died again; alerted once, row stays WAIT_CI"
           fi ;;
      esac
    fi
  fi
  EFF=$(mc_discount "$SLUG" "$MSTATE" "$CI")
  PREV=$(mc_row_field "$KEY" 2)
  # In the queue? Never asked at all on a repo that has no queue.
  #   github   isInMergeQueue, from the list when gh gave us the field and per
  #            PR (mc_inqueue) when its --json allowlist refused it.
  #   mergify  the trigger label, from the list. HEALTH is not asked here: a
  #            labelled PR whose batch has gone red is still QUEUED this tick
  #            and the settle pass above ejects it on the next one, which runs
  #            BEFORE the list is read — so it converges in one tick and the
  #            open pass stays one API call per repo instead of two per PR.
  MC_INQUEUE=0
  if [ "$QUEUE" = 1 ]; then
    case "$PROVIDER" in
      github)
        # From the list when gh gave us the field; otherwise ONE read per PR,
        # and only for a PR in a merge state where the queue can be holding it
        # (inq_matters). Asking it for every open PR on the repo was one API
        # call per PR per tick to learn `false` about a DIRTY head.
        if [ "$INQ_IN_LIST" = 1 ]; then [ "${RAWINQ:-false}" = true ] && MC_INQUEUE=1
        # NO LIST FIELD AND NO REST FIELD EITHER (BH-784): a row THIS conductor
        # put in QUEUED stays queued. mc_inqueue now answers `unknown` -> false
        # for a native-queue PR, so without this the row would classify READY and
        # be re-enqueued every tick — two strikes and the PR is BLOCKED_AGENT for
        # a queue that was holding it correctly. The opposite error (a genuinely
        # ejected PR sitting QUEUED until the settle pass or a hand moves it) is
        # the cheaper one, and neither arises on a gh that carries the field —
        # 2.97 does, so this is the shim path only. Also one read fewer.
        elif [ "${PREV:-}" = QUEUED ]; then MC_INQUEUE=1
        elif inq_matters "$MSTATE" "${PREV:-}"; then mc_inqueue "$URL" && MC_INQUEUE=1; fi ;;
      mergify)
        # Our own label is NOT enough on its own — after an rc-3 enqueue it is
        # deliberately left on a PR the queue never took. mc_mergify_inqueue
        # wants Mergify's own label, or a row already QUEUED, or a check run;
        # and an ejected head is never queued whatever the label says.
        mc_mergify_inqueue "$SLUG" "$KEY" "$URL" "$HEAD" "${RAWLBL:-}" "${PREV:-}" && MC_INQUEUE=1
        # LABELLED BEFORE THE GATE EXISTED (BH-3806). A row the enqueue labelled
        # while BH-3683 withheld its status (#3798, #3799) wins here as QUEUED and
        # never reaches the BH-3777 gate below. With no lead-verdict success on
        # the head and la_decide rc 1, our label comes off once per (PR, head)
        # and the row falls through to the gate, which makes it
        # NEEDS_HUMAN_VERDICT in this same tick.
        [ "$MC_INQUEUE" = 1 ] && mc_nhv_unqueue "$SLUG" "$KEY" "$URL" "$NUM" "$HEAD" "${RAWLBL:-}" "$MERGES" && MC_INQUEUE=0 ;;
    esac
  fi
  # ---- the NATIVE queue's ejection witness now lives here (BH-784) ----------
  # `isInMergeQueue` is GraphQL-only and has no REST field, so mc_queue_state —
  # which the settle pass above uses — answers `unknown` for a native-queue PR
  # and can no longer tell "still queued" from "ejected". It must not guess: an
  # ejection invented out of a rate limit costs a PR its place in the queue.
  # The LIST still carries the field (bin/lib/gh-pr-list.sh, untouched by the
  # REST conversion), and here it is: a row THIS conductor put in QUEUED whose
  # list row says the queue no longer holds it has been ejected. Recorded in the
  # same place the settle pass recorded it, so the strike count and the
  # "an ejected head is not READY" guard below keep working unchanged — without
  # it an ejected PR would classify READY and be re-enqueued every five minutes,
  # which is the forever-loop the guard exists to stop.
  if [ "$PROVIDER" = github ] && [ "$INQ_IN_LIST" = 1 ] && [ "$MC_INQUEUE" = 0 ] \
     && [ "${PREV:-}" = QUEUED ] && [ "${PSTATE:-}" = OPEN ]; then
    mc_attempt_has "ejected $KEY $HEAD" 2>/dev/null \
      || mc_attempt_put "ejected $KEY $HEAD"
  fi
  # ---- stacked child PRs (2026-09-14) -------------------------------------
  # This PR's base is not $PBASE, so it was built on another PR's branch. Ask
  # what that parent is doing, and answer in one of three ways:
  #   MERGED  GitHub should have retargeted this PR to $PBASE when the parent's
  #           branch was deleted. On a repo that keeps merged branches it did
  #           not, so we do it ourselves — a gh WRITE, so only in actions mode;
  #           in observe mode the row simply stays STACKED_WAIT and says why.
  #   CLOSED  the parent was closed WITHOUT merging (a resolver rebuild, or a
  #           hand close): the base branch is dead. Since 2026-09-16 that is an
  #           EVENT with two answers rather than a park — the branch is read,
  #           and a child that carries nothing of the dead parent is retargeted
  #           to $PBASE like the MERGED case, while one that does is handed to
  #           bin/blocked-resolver.sh. See the arm itself.
  #   else    keep waiting (this is the ordinary, healthy case).
  # Kill flag: STACKED_BUILDS=0 / flags/stacked-builds-off stops stacked builds
  # being CREATED; this classification is about PRs that already exist and is
  # deliberately not behind it — parking a PR whose base is a feature branch is
  # correct whether or not this fleet still opens them.
  # ---- a parent the conductor merged owes this child a restack (BH-1670) ----
  # conductor_settle follows each child at once unless the child's worker (this
  # one) held the PR lock; then the owed follow waits here, and this worker
  # already holds the lock. A settle that pushed this child EARLIER IN THIS TICK
  # left a `.pushed` marker: this worker's list row predates that push, so every
  # field above is stale. Both cases end the worker for this tick; the next tick
  # classifies the new head on the new base from fresh reads (CI included).
  SFMARK="$(mc_stack_pending_file "$SLUG" "$NUM").pushed"
  if [ -s "$SFMARK" ]; then
    IFS=$'\t' read -r SFTICK SFNEW < "$SFMARK"
    rm -f "$SFMARK"
    if [ "$SFTICK" = "${MC_TICK_ID:-notick}" ] && [ "$SFNEW" != "$HEAD" ]; then
      mc_log "$KEY was restacked to ${SFNEW:0:8} earlier this tick; this row read ${HEAD:0:8} — classified on the next tick"
      return 0
    fi
  fi
  if SFPEND=$(mc_stack_pending_get "$SLUG" "$NUM"); then
    IFS=$'\t' read -r SFPN SFPURL SFPBR SFPHEAD SFBASE _ _ <<<"$SFPEND"
    SFOUT=$(mc_stack_follow "$P" "$SLUG" "$NUM" "$SFPN" "$SFPURL" "$SFPBR" "$SFPHEAD" "$SFBASE"); SFRC=$?
    rm -f "$SFMARK"
    case "$SFRC" in
      0) [ -n "$SFOUT" ] && return 0 ;;
      1) return 0 ;;
    esac
  fi
  # A fast-tracked child whose parent left the queue unmerged goes back onto the parent's branch (BH-5520).
  # An owed Depends-On removal is retried first; a closed parent whose branch
  # refuses the child parks it on the resolver-owned orphan reason.
  MSF_ORPHAN=""
  command -v msf_depends_settle >/dev/null 2>&1 && msf_depends_settle "$SLUG" "$KEY" "$NUM" "$ACTIONS"
  if command -v msf_eligible >/dev/null 2>&1 && [ -n "$PBASE" ] && [ "${BASEREF:-}" = "$PBASE" ] \
     && msf_check_revoke "$SLUG" "$KEY" "$NUM" "$URL" "$HEAD" "$ACTIONS"; then BASEREF="$MSF_BASE"; fi
  MC_STACK=""; MC_STACK_BASE=""; MC_RT_THIS_TICK=0
  [ -n "${MSF_ORPHAN:-}" ] && { MC_STACK=parent-closed-orphan; MC_STACK_BASE="$MSF_ORPHAN"; }
  if [ -n "$PBASE" ] && [ -n "${BASEREF:-}" ] && [ "$BASEREF" != "$PBASE" ]; then
    MC_STACK=wait; MC_STACK_BASE="$BASEREF"
    # ONE read per (repo, parent branch) per tick (BH-1486): N children of one
    # parent used to buy N copies of the same list. stack_parent_memo never
    # stores NONE — a parent read that failed and a parent PR that does not
    # exist are the same word, and caching either would keep a child waiting on
    # a refusal for the rest of the tick.
    # The read's own answer for the NONE arm (BH-3950): see mc_stack_parent.
    MC_STACK_PARENT_ANS=$(mktemp "${TMPDIR:-/tmp}/mc-stackans.XXXXXX" 2>/dev/null) || MC_STACK_PARENT_ANS=""
    IFS=$'\t' read -r PARSTATE PARURL <<<"$(stack_parent_memo "$P" "$SLUG" "$BASEREF")"
    NANS=""; [ -n "$MC_STACK_PARENT_ANS" ] && { NANS=$(cat "$MC_STACK_PARENT_ANS" 2>/dev/null); rm -f "$MC_STACK_PARENT_ANS"; }
    MC_STACK_PARENT_ANS=""
    case "${PARSTATE:-NONE}" in
      # A parent waiting on a human verdict (BH-3777) is the child's real wait:
      # say so in the child's reason, or four children read "waiting for the
      # parent to merge" while the parent waits on a person.
      OPEN*)
        PN=$(mc_nhv_parent_note "$SLUG" "${PARURL:-}")
        [ -n "$PN" ] && MC_STACK_BASE="$BASEREF; $PN"
        # A CONFLICTED CHILD OF AN OPEN PARENT GETS THE PARENT MERGED IN
        # (BH-5519). mc_classify parks every stacked child STACKED_WAIT ahead of
        # its DIRTY clause, so nothing else merges anything into this branch
        # until the parent lands. The merge is the parent branch, never main
        # (main's diff would ride into a PR read against the parent), one try
        # per child head, on the rebase budget. A conflict stays STACKED_WAIT:
        # the fix round merges origin/main, which is wrong for a stacked child,
        # and mc_stack_follow hands it over once the parent merges.
        #
        # AND A CHILD OF A PARENT THAT MOVED GETS IT TOO, DIRTY OR NOT (BH-5796).
        # A parent rebuilt or fixed while the child waits leaves a CLEAN child on
        # the old parent commits; 14 review BLOCKs found that by hand. So the
        # parent's tip is read (mc_stack_parent_moved, one fetch) and, when it
        # is not in the child's history, the same parent merge runs, once per
        # (child head, parent tip). MC_STACK_PARENT_FOLLOW=0 turns that half off;
        # MC_STACK_PARENT_MERGE=0 still turns every parent merge off.
        # A CONFLICT IS A FIX ROUND NOW, not a wait: the child is parked
        # conflict-unresolvable, and bin/blocked-resolver.sh's round merges the
        # PR's own base (the parent branch) for a stacked child, never main.
        SMWHY=""; SMKEY=""; SMRC=""
        if [ "$ACTIONS" = 1 ] && [ "${CROSS:--}" = false ]; then
          if [ "${MC_STACK_PARENT_MERGE:-1}" != 0 ] && { [ "$MSTATE" = DIRTY ] || [ "$MGABLE" = CONFLICTING ]; }; then
            SMWHY=dirty; SMKEY="stackmerge $KEY $HEAD"
          elif [ "${MC_STACK_PARENT_MERGE:-1}" != 0 ] && [ "${MC_STACK_PARENT_FOLLOW:-1}" != 0 ]; then
            SMPH=$(mc_stack_parent_moved "$SLUG" "$P" "$BR" "$HEAD" "$BASEREF"); SMPRC=$?
            case "$SMPRC" in
              0) SMWHY=moved; SMKEY="stackmerge $KEY $HEAD $SMPH" ;;
              1) : ;;
              *) mc_log "$KEY stacked parent tip of $BASEREF unreadable ($SMPH) — not followed this tick" ;;
            esac
          fi
        fi
        if [ -n "$SMKEY" ] && ! mc_attempt_has "$SMKEY" 2>/dev/null; then
          if mc_tick_budget_take "$P" rebase "$REBASE_BUDGET"; then
            mc_attempt_put "$SMKEY"; mc_count_inc "$P" rebases >/dev/null
            SMOUT=$(mc_rebase "$SLUG" "$P" "$BR" "$HEAD" "$URL" "$BASEREF"); SMRC=$?
            case "$SMRC" in
              5) if [ "$SMWHY" = moved ]; then
                   mc_log "$KEY STACK_PARENT_MOVED ${SMOUT:0:8}: merged the new tip ${SMPH:0:8} of $BASEREF, approval not rebound"
                 else
                   mc_log "$KEY STACK_PARENT_MERGED ${SMOUT:0:8} from $BASEREF, approval not rebound"
                 fi
                 MC_STACK_BASE="$MC_STACK_BASE; parent branch merged in as ${SMOUT:0:8}" ;;
              1) SMOUT=$(printf '%s' "$SMOUT" | tr '\n' ' ' | sed 's/ *$//')
                 mc_log "$KEY STACK_PARENT_CONFLICT $SMOUT — parked conflict-unresolvable for bin/blocked-resolver.sh's fix round (it merges $BASEREF, not main)"
                 mc_transition "$KEY" BLOCKED_HUMAN "conflict-unresolvable: stacked child of $BASEREF (parent ${PARURL:-?}) — merging the parent's tip conflicts in: $SMOUT" \
                   "$HEAD" "$REVIEWED" "$URL" "$VERDICT" "$MSTATE" "$REC" >/dev/null
                 return 0 ;;
              *) mc_log "$KEY stacked parent merge from $BASEREF: not merged this tick (rc $SMRC)" ;;
            esac
          else
            budget_spent "$P" rebase "$KEY"
          fi
        fi
        # A child of a QUEUED parent joins the parent's batch (BH-5520, bin/lib/mc-stack-fast.sh).
        if command -v msf_eligible >/dev/null 2>&1 && [ "${SMRC:-}" != 5 ] && [ "${CROSS:--}" = false ] \
           && msf_try "$SLUG" "$P" "$KEY" "$NUM" "${PARURL:-}" "$HEAD" "$REVIEWED" "$VERDICT" "$CI" "$MSTATE" "$MGABLE" "$BASEREF" "$BR" "$PBASE" "$ACTIONS"; then
          MC_STACK=""; MC_STACK_BASE=""; BASEREF="$PBASE"
        fi ;;
      MERGED)
        if [ "$ACTIONS" = 1 ] && mc_retarget_base "$SLUG" "$NUM" "$PBASE"; then
          # AND THE RETARGET NEEDS A CI KICK (2026-09-15, project-5
          # #913/#943/#1011/#1020/#1021). The base change fires no
          # `pull_request` workflow — the default activity types are
          # opened|synchronize|reopened — so this head still carries the runs
          # it had, which for a child cut from a feature branch is none. The
          # row would classify `WAIT_CI checks none` and stay there for ever
          # with the required check never reporting. mc_kick_ci is the
          # close/reopen that fires it; a FAILED kick must not undo the
          # retarget, so it is logged and the generic kick below picks the PR
          # up on a later tick.
          #
          # ONLY WHEN THE HEAD HAS NO RUNS AT ALL (review of #352). Not every
          # repo in the fleet leaves a stacked child unbuilt: project-2
          # (migration-sql-gate.yml, verification-map-freshness.yml) and
          # project-4 (typecheck.yml) trigger on a bare `pull_request`, so their
          # children DO have runs on the head by the time the parent merges.
          # Closing and reopening one of those cancels whatever is in flight
          # through the repo's own cancel-in-progress concurrency group and
          # buys a duplicate build for nothing. CI was read at the top of this
          # iteration; `none` is the only state a kick answers.
          if [ "$CI" != none ]; then
            mc_log "$KEY parent ${PARURL:-?} merged but GitHub left this PR based on $BASEREF — retargeted to $PBASE; CI is already $CI on ${HEAD:0:8}, so no kick (a close/reopen would cancel it)"
            MC_STACK=""; MC_STACK_BASE=""
          elif mc_kick_ci "$SLUG" "$NUM" "$HEAD"; then
            mc_attempt_has "cikick $KEY $HEAD" 2>/dev/null || mc_attempt_put "cikick $KEY $HEAD"
            mc_log "$KEY parent ${PARURL:-?} merged but GitHub left this PR based on $BASEREF — retargeted to $PBASE and CI kicked (close/reopen); it classifies normally from here"
            MC_STACK=""; MC_STACK_BASE=""
          else
            mc_log "$KEY parent ${PARURL:-?} merged but GitHub left this PR based on $BASEREF — retargeted to $PBASE; the CI kick FAILED and the retarget stands — the generic kick retries on a later tick"
            MC_STACK=""; MC_STACK_BASE=""
          fi
          # THE LIST'S BASE IS STALE FROM HERE ON, AND THE READY ARM READS IT
          # (BH-410). GitHub has this PR on $PBASE from this PATCH on; the
          # BASEREF this worker read at the top of the tick still names the
          # parent branch, and the merge guard's list-side check would refuse a
          # PR that is now correctly based. It is refreshed AFTER the log lines
          # above on purpose — every one of them reports the base the PR was
          # moved OFF, and that is the fact an operator reading the line wants.
          BASEREF="$PBASE"
        else
          MC_STACK_BASE="$BASEREF (parent ${PARURL:-?} MERGED; the retarget to $PBASE has not landed — observe-only tick, or the PATCH was refused)"
        fi ;;
      NONE)
        # NO PARENT PR AT ALL (BH-3950). project-4 #1778 sat on agent/TK-2102 for
        # 4.6 days: nothing ever opened a PR on that branch, this word had no
        # arm, and the stuck detector paged the row every tick. NONE is a failed
        # read OR an empty list, so the read's own answer (NANS, written by
        # mc_stack_parent) decides, and only a VERIFIED `none` goes on — no
        # second list read. Then the branch: gone (404), or still there,
        # PR-less and past the STACKED_WAIT TTL, is a parent nothing will ever
        # merge, and the child takes the CLOSED arm's orphan path below. Every
        # unreadable answer keeps it waiting (D9/D11).
        NWHY=""
        if [ "$NANS" != none ]; then
          mc_attempt_has "nonepunread $KEY $HEAD" 2>/dev/null || { mc_attempt_put "nonepunread $KEY $HEAD"
            mc_log "$KEY no parent PR read for $BASEREF is UNVERIFIABLE (${NANS:-no answer recorded}) — keeps waiting"; }
        else
          BRC=0; mc_branch_exists "$SLUG" "$BASEREF" || BRC=$?
          case "$BRC" in
            1) NWHY=gone ;;
            0)
              NSINCE=$(mc_row_field "$KEY" 3); NTTL=$(mc_ttl STACKED_WAIT)
              if [ "$(mc_row_field "$KEY" 2)" = STACKED_WAIT ] && [[ "$NSINCE" =~ ^[0-9]+$ ]] && [[ "$NTTL" =~ ^[0-9]+$ ]] \
                 && [ $(( $(mc_now) - NSINCE )) -ge "$NTTL" ]; then
                NWHY=ttl
              else
                MC_STACK_BASE="$BASEREF (no parent PR; branch present, inside the STACKED_WAIT TTL)"
              fi ;;
            *)
              mc_attempt_has "nonebunread $KEY $HEAD" 2>/dev/null || { mc_attempt_put "nonebunread $KEY $HEAD"
                mc_log "$KEY no PR on $BASEREF, but the branch read is UNVERIFIABLE (HTTP ${GH_REST_STATUS:-000}${GH_REST_REASON:+ $GH_REST_REASON}) — keeps waiting"; } ;;
          esac
        fi
        # The parent TICKET may be open under the other head shape (agent/<KEY>
        # vs ticket/<key>): open_pr_for_key, the BH-3948 contract. Open or
        # unreadable keeps the child waiting; no derivable key skips the guard.
        if [ -n "$NWHY" ]; then
          PKEY=$(mc_stack_parent_key "$BASEREF"); PRC=1; POPEN=""
          [ -n "$PKEY" ] && { POPEN=$(mc_parent_pr_open "$SLUG" "$PKEY"); PRC=$?; }
          case "$PRC" in
            0) MC_STACK_BASE="$BASEREF (no PR on it; parent ticket $PKEY is open as $POPEN)"; NWHY="" ;;
            1) ;;
            *) mc_attempt_has "nonekunread $KEY $HEAD" 2>/dev/null || { mc_attempt_put "nonekunread $KEY $HEAD"
                 mc_log "$KEY no PR on $BASEREF, but whether parent ticket $PKEY has an open PR is UNVERIFIABLE — keeps waiting"; }
               NWHY="" ;;
          esac
        fi
        # open_pr_for_key sees agent/<KEY> and ticket/<key> only. A parent
        # REBUILT as ticket/<key>-rN is the CLOSED arm's mc_retry_pr probe; an
        # open rebuild is still the parent, so the child keeps waiting on it.
        if [ -n "$NWHY" ]; then
          IFS=$'\t' read -r RSTATE RURL RBR <<<"$(mc_retry_pr "$SLUG" "$BASEREF")"
          [ "${RSTATE:-NONE}" = OPEN ] && { MC_STACK_BASE="$BASEREF (no PR on it; the parent's rebuild ${RURL:-?} on $RBR is open)"; NWHY=""; }
        fi
        if [ -n "$NWHY" ] && { [ "$ACTIONS" != 1 ] || [ "${MC_ORPHAN_RETARGET:-1}" = 0 ]; }; then
          if [ "$ACTIONS" != 1 ]; then
            mc_log "$KEY would retarget to $PBASE — no parent PR on $BASEREF (branch $NWHY) (observe mode: nothing written)"
          else
            mc_attempt_has "noneparked $KEY $HEAD" 2>/dev/null || { mc_attempt_put "noneparked $KEY $HEAD"
              mc_log "$KEY no parent PR on $BASEREF (branch $NWHY) — parked (MC_ORPHAN_RETARGET=0)"; }
          fi
        elif [ -n "$NWHY" ]; then
          NOLD="$BASEREF"
          # carry=0 (judge a gone parent on the conflict half alone) ONLY while
          # the owed re-review stands: it is what reads the parent's commits the
          # child brings along. With MC_RETARGET_REREVIEW=0 nothing would read
          # them, so the full check runs and a gone parent parks orphaned-child.
          NCARRY=1; [ "$NWHY" = gone ] && [ "$MC_RETARGET_REREVIEW" != 0 ] && NCARRY=0
          OWHY=$(mc_orphan_clean "$SLUG" "$P" "$PBASE" "$BASEREF" "$HEAD" "$NCARRY"); ORC=$?
          case "$ORC" in
            0)
              stack_orphan_retarget \
                "$KEY no parent PR on $BASEREF (branch $NWHY) — $OWHY, so this PR was retargeted to $PBASE" \
                "$KEY no parent PR on $BASEREF (branch $NWHY)" \
                "$KEY no parent PR on $BASEREF (branch $NWHY) and this PR is clean against $PBASE ($OWHY), but the retarget PATCH was refused — it keeps waiting and the retarget is retried next tick" \
                && mc_log "RETARGETED $KEY base $NOLD -> $PBASE (parent: none, branch $NWHY)" ;;
            1)
              MC_STACK=parent-closed-orphan
              MC_STACK_BASE="$BASEREF (no parent PR; branch $NWHY; $OWHY)"
              mc_attempt_has "noneorphan $KEY $HEAD" 2>/dev/null || { mc_attempt_put "noneorphan $KEY $HEAD"
                mc_log "$KEY BLOCKED_AGENT orphaned-child: no PR was ever opened on $BASEREF (branch $NWHY), and this PR cannot be retargeted to $PBASE as it stands — $OWHY — handed to bin/blocked-resolver.sh (fix round on $BR, then a fresh rebuild); nothing closes it here: $URL"; } ;;
            *)
              mc_attempt_has "noneorphanunknown $KEY $HEAD" 2>/dev/null || { mc_attempt_put "noneorphanunknown $KEY $HEAD"
                mc_log "$KEY no parent PR on $BASEREF (branch $NWHY), but this tick could not judge $BR against $PBASE ($OWHY) — keeps waiting and is re-read on the next tick"; } ;;
          esac
        fi ;;
      CLOSED)
        # THE PARENT WAS CLOSED FOR A REBUILD, AND THE REBUILD IS A DIFFERENT
        # BRANCH (BH-458, 2026-09-16). `mc_stack_parent` answers about the base
        # branch, which is the parent's FIRST attempt; when that attempt was
        # closed and the ticket rebuilt, the work is now on `ticket/<key>-rN`
        # and this child is sitting on a branch nothing will ever merge.
        # GitHub's own retarget cannot help either: it fires when the MERGED
        # branch is deleted, and the branch that merges is the retry.
        #
        # Five fully built, APPROVED, CI-green children were closed by hand in
        # one six-hour window on 2026-09-15 for exactly this, about 50 minutes
        # of paid build each. the operator's decision (2026-09-16): stacking stays on
        # and the answer is to RETARGET, never to close. So:
        #   retry OPEN    rebase the child onto the retry branch and move its
        #                 base there; it waits on the new parent like any
        #                 healthy stack.
        #   retry MERGED  the work is in the project base now, so the child is
        #                 rebased and retargeted onto that.
        #   no retry      nothing has replaced the dead branch, so there is
        #                 nothing to move the child ONTO — and that is where the
        #                 orphan read takes over rather than where the child
        #                 stops (see the arm below).
        # `git rebase --onto <new> <old>` replays ONLY the child's own commits,
        # so its diff stays one ticket's change (mc_restack). Close-for-rebuild
        # survives as the fallback for a rebase that CONFLICTS, and then the
        # comment names the files, because that is all a rebuild has to go on.
        #
        # AND `no retry` IS NO LONGER A DEAD END EITHER (2026-09-16): a parent
        # closed with nothing to replace it gets its child's branch READ, and
        # the child is either retargeted to the project base or handed to
        # bin/blocked-resolver.sh. See that arm below. Kill flag
        # MC_ORPHAN_RETARGET=0 restores the park.
        MC_STACK=parent-closed; MC_STACK_BASE="$BASEREF (parent ${PARURL:-?})"
        IFS=$'\t' read -r RSTATE RURL RBR <<<"$(mc_retry_pr "$SLUG" "$BASEREF")"
        RNEWBASE=""
        case "${RSTATE:-NONE}" in
          OPEN)   RNEWBASE="$RBR" ;;
          MERGED) RNEWBASE="$PBASE" ;;
        esac
        NOREPL="nothing live has replaced it (newest rebuild: ${RURL:--} ${RSTATE:-NONE}, probed to -r${MC_RETRY_MAX:-6})"
        if [ -z "$RNEWBASE" ]; then
          # NOTHING REPLACED THE DEAD BRANCH — AND THAT IS STILL AN EVENT
          # (2026-09-16). The restack above answers the parent that was closed
          # FOR A REBUILD, because the rebuild is a branch to move onto. The
          # other ending has no replacement at all: bin/blocked-resolver.sh
          # closed project-5 #1556 at 09:35Z to rebuild TK-1529 fresh, and its
          # three children (#1586/#1585/#1587, all based on ticket/TK-1529) were
          # parked `parent-closed` — a reason no lane owns — and stopped moving.
          #
          # So before parking, the BRANCH is read (mc_orphan_clean, read-only,
          # local, no ref written):
          #   clean    it carries nothing of the dead parent beyond the base and
          #            merges into the base — retarget it to the base, exactly
          #            like the MERGED arm above, kick included. It keeps its
          #            number and its CI; its review is re-bought (BH-3950,
          #            reversing 2026-09-16's "keeps its review"): the review it
          #            has was of its diff against a branch that never merged,
          #            so a head-bound re-review is owed before it can merge.
          #            MC_RETARGET_REREVIEW=0 restores keeping it.
          #   not      it still carries the parent's commits, its parent branch
          #            is gone, or it conflicts — park it on a reason the
          #            RESOLVER owns, which gets it a fix round on this same
          #            branch and, if that fails, a fresh rebuild. Never a
          #            close, and never a timer (the operator, 2026-09-16).
          #   unknown  no checkout, no token, an old git — say so once per head
          #            and leave the row exactly where it was.
          if [ "$ACTIONS" = 1 ] && [ "${MC_ORPHAN_RETARGET:-1}" != 0 ]; then
            OWHY=$(mc_orphan_clean "$SLUG" "$P" "$PBASE" "$BASEREF" "$HEAD"); ORC=$?
            case "$ORC" in
              0)
                stack_orphan_retarget \
                  "$KEY parent ${PARURL:-?} CLOSED without merging on $BASEREF and $NOREPL — $OWHY, so this PR was retargeted to $PBASE" \
                  "$KEY parent ${PARURL:-?} CLOSED without merging on $BASEREF" \
                  "$KEY parent ${PARURL:-?} CLOSED without merging and this PR is clean against $PBASE ($OWHY), but the retarget PATCH was refused — the park stands and the retarget is retried next tick" ;;
              1)
                MC_STACK=parent-closed-orphan
                MC_STACK_BASE="$BASEREF (parent ${PARURL:-?} closed without merging; $OWHY)"
                mc_attempt_has "orphan $KEY $HEAD" 2>/dev/null || { mc_attempt_put "orphan $KEY $HEAD"
                  mc_log "$KEY BLOCKED_AGENT orphaned-child: the parent ${PARURL:-?} closed without merging on $BASEREF, $NOREPL, and this PR cannot be retargeted to $PBASE as it stands — $OWHY — handed to bin/blocked-resolver.sh (fix round on $BR, then a fresh rebuild); nothing closes it here: $URL"; } ;;
              *)
                mc_attempt_has "orphanunknown $KEY $HEAD" 2>/dev/null || { mc_attempt_put "orphanunknown $KEY $HEAD"
                  mc_log "$KEY parent ${PARURL:-?} CLOSED without merging on $BASEREF and $NOREPL, but this tick could not judge $BR against $PBASE ($OWHY) — left parked on parent-closed and re-read on the next tick"; } ;;
            esac
          else
            mc_log "$KEY parent ${PARURL:-?} closed unmerged on $BASEREF and $NOREPL — parked parent-closed"
          fi
        elif [ "$ACTIONS" != 1 ]; then
          mc_log "$KEY would restack onto $RNEWBASE — parent ${PARURL:-?} closed unmerged on $BASEREF, rebuilt as ${RURL:-?} ($RSTATE) (observe mode: nothing written)"
        elif mc_attempt_has "restack $KEY $HEAD" 2>/dev/null; then
          mc_log "$KEY has already had its one restack attempt on ${HEAD:0:8} — nothing retried until the head moves"
        else
          # The attempt is recorded on the outcomes that MEAN something (pushed,
          # or closed for rebuild), never on a setup failure or a moved head —
          # the same rule mc_rebase's marker follows, so a token outage cannot
          # strand a child for the life of its head.
          RSOUT=$(mc_restack "$SLUG" "$P" "$BR" "$HEAD" "$BASEREF" "$RNEWBASE" "$URL"); RSRC=$?
          case "$RSRC" in
            0)
              mc_attempt_put "restack $KEY $HEAD"
              if mc_retarget_base "$SLUG" "$NUM" "$RNEWBASE"; then
                # A base change fires no workflow and the push's own
                # `synchronize` run was started against the OLD base, so the
                # kick is what gives this head a run of the tree that will
                # actually merge (the same lesson as the MERGED arm above).
                # No expected head (BH-3804): the PR's head lags our own push of
                # $RSOUT, so a head check here would refuse our own kick.
                if mc_kick_ci "$SLUG" "$NUM"; then
                  mc_attempt_has "cikick $KEY $RSOUT" 2>/dev/null || mc_attempt_put "cikick $KEY $RSOUT"
                  mc_log "$KEY restacked: parent ${PARURL:-?} closed unmerged on dead base $BASEREF, rebuilt as ${RURL:-?} ($RSTATE) — rebased onto $RNEWBASE (${RSOUT:0:8}), base PATCHed and CI kicked; the head-bound re-review runs on the new head"
                else
                  mc_log "$KEY restacked: parent ${PARURL:-?} closed unmerged on dead base $BASEREF, rebuilt as ${RURL:-?} ($RSTATE) — rebased onto $RNEWBASE (${RSOUT:0:8}) and base PATCHed, but the CI kick FAILED; the generic kick picks it up on a later tick"
                fi
                # Parked for THIS tick on purpose: every field read above (head,
                # base, CI) is about the PR as it was before the push, so
                # classifying on it would be classifying stale facts. The next
                # tick reads the new head on the new base and treats it as the
                # ordinary stack it now is.
                MC_STACK=wait; MC_STACK_BASE="$RNEWBASE (restacked off the dead $BASEREF; rebuilt parent ${RURL:-?})"
              else
                mc_log "$KEY rebased onto $RNEWBASE (${RSOUT:0:8}) — parent ${PARURL:-?} closed unmerged on dead base $BASEREF, rebuilt as ${RURL:-?} — but the base PATCH was REFUSED; the branch is moved and a later tick retries the base"
              fi ;;
            1)
              # THE ONLY PATH THAT STILL THROWS A BUILD AWAY, and it is the one
              # where the child's own work genuinely has to be redone: its
              # commits do not apply on the branch that replaced its parent.
              # The comment names the files because that is everything the
              # rebuild has to go on; the ticket is left OPEN so the next
              # triage tick picks it up.
              RCONF=$(printf '%s' "$RSOUT" | tr '\n' ' ')
              if mc_close_for_rebuild "$SLUG" "$NUM" \
                   "$(printf 'Closing this one for a rebuild. The PR it was stacked on (%s) was closed without merging and rebuilt as %s, and replaying this change onto %s conflicts in files this PR owns: %s. The ticket stays open, so the next build starts fresh against %s.' "${PARURL:-the parent}" "${RURL:-the rebuild}" "$RNEWBASE" "$RCONF" "$RNEWBASE")"; then
                mc_attempt_put "restack $KEY $HEAD"
                mc_log "$KEY closed for rebuild: parent ${PARURL:-?} closed unmerged on dead base $BASEREF, rebuilt as ${RURL:-?} ($RSTATE) — the rebase onto $RNEWBASE conflicts in $RCONF; the ticket stays open for a fresh build"
              else
                mc_log "$KEY the rebase onto $RNEWBASE conflicts in $RCONF (parent ${PARURL:-?}, rebuilt as ${RURL:-?}) and the close FAILED — left open and parked parent-closed; the next tick tries again"
              fi
              MC_STACK_BASE="$BASEREF (parent ${PARURL:-?}; closed for rebuild — the rebase onto $RNEWBASE conflicts in $RCONF)" ;;
            3)
              mc_log "$KEY restack onto $RNEWBASE refused the lease on ${HEAD:0:8} (parent ${PARURL:-?}, rebuilt as ${RURL:-?}) — the head moved under the tick; the next one reads it and tries again" ;;
            *)
              mc_log "$KEY restack onto $RNEWBASE failed to set up (rc $RSRC; parent ${PARURL:-?}, rebuilt as ${RURL:-?}) — parked parent-closed and retried on the next tick" ;;
          esac
        fi ;;
    esac
  fi
  # ---- a retarget off a closed or absent parent owes a re-review (BH-3950) --
  # stack_orphan_retarget wrote `rtreview <key> <head>`. Until a claude
  # head-bound read bought AFTER the retarget APPROVES this head, the row is
  # held on WAIT_REVIEW and never reaches the classifier's READY on the review
  # it had before. The release is its own record, `rtcleared <key> <head>`,
  # and NOT mc_prov_cleared: a retarget does not move the head, so a
  # `provcleared` row or a lead/human MERGE on it can predate the retarget, and
  # both judged the diff against the dead parent. The read is the detached one
  # headbound_review buys (job body mc_rereview_run -> mc_rereview), with all
  # its debounces: CI green, budget, cap, call-guard. A head that already had a
  # read when it was retargeted (`rtpreread`) cannot buy another one — that job
  # is one per (PR, head) — so it stays held until a push, whose new head the
  # HEAD_MOVED arm re-reviews against the new base. Not on the retarget's own
  # tick (its CI was just kicked), and not on a DIRTY/CONFLICTING head, which
  # the rebase path owns.
  MC_PROV_CLEARED=0
  if [ -z "$MC_STACK" ] && [ "$MC_RETARGET_REREVIEW" != 0 ] && [ "$MSTATE" != DIRTY ] && [ "$MGABLE" != CONFLICTING ] \
     && mc_attempt_has "rtreview $KEY $HEAD" 2>/dev/null && ! mc_attempt_has "rtcleared $KEY $HEAD" 2>/dev/null; then
    RTWHY="retargeted off closed parent - re-review owed"
    if mc_attempt_has "rtpreread $KEY $HEAD" 2>/dev/null; then
      RTWHY="$RTWHY; ${HEAD:0:8} was already read against the dead parent, so a push buys the read against $PBASE"
    elif [ "$MC_RT_THIS_TICK" = 0 ] && [ "$ACTIONS" = 1 ]; then
      headbound_review provenance "$KEY" "$SLUG" "$NUM" "$P" "$URL" "$REC" "$HEAD" "$REVIEWED" "$VERDICT" "$MSTATE" "$CI" || return 0
      if [ "$MC_PROV_CLEARED" = 1 ]; then
        mc_attempt_put "rtcleared $KEY $HEAD"
        mc_log "$KEY re-review owed after the retarget APPROVED ${HEAD:0:8} — the hold is released"
      fi
    fi
    if ! mc_attempt_has "rtcleared $KEY $HEAD" 2>/dev/null; then
      mc_transition "$KEY" WAIT_REVIEW "$RTWHY" "$HEAD" "$REVIEWED" "$URL" "$VERDICT" "$MSTATE" "$REC" >/dev/null
      return 0
    fi
  fi
  # ---- a provenance hold consumes its head-bound re-review (2026-09-14) ----
  # `provenance` is the one BLOCKED_HUMAN reason whose FIX this lane can buy:
  # it says a non-primary runner authored the build's own APPROVE, and a
  # claude read of the head sitting here answers it. Today that read was
  # already being bought (#864 got one at 20:25Z) and then thrown away, because
  # mc_classify returns `provenance` BEFORE the drift branch and the done-job
  # handling lived only in the HEAD_MOVED arm. #864 and #867 were merged by
  # hand; #865 and #866 were still parked when this was written.
  #
  # So the hold is resolved HERE, ahead of the classifier, in the same four
  # answers the HEAD_MOVED arm gives (headbound_review). A consumed APPROVE
  # sets MC_PROV_CLEARED and the row classifies normally on this very tick; a
  # BLOCK parks it `head-not-reapproved`, which is a reason the resolver owns,
  # rather than `provenance`, which nothing does.
  #
  # NOT for a stacked child or a PR the queue holds (neither may be reviewed
  # or merged from here), and not for a verdict that is already BLOCK or
  # CONTRADICTION or a tightened repo — mc_classify parks all three ahead of
  # provenance, and buying a review to argue with them would be spend for
  # nothing.
  if mc_prov_held "$PROV" && [ -z "$MC_STACK" ] && [ "$MC_INQUEUE" = 0 ] && \
     [ "$TIGHT" = 0 ] && [ "$VERDICT" != BLOCK ] && [ "$VERDICT" != CONTRADICTION ]; then
    if mc_prov_cleared "$KEY" "$HEAD"; then
      # The marker records exactly what the consume recorded: a claude
      # head-bound review APPROVED this head. Every later tick reads it back
      # as the same three facts, so the row does not oscillate.
      MC_PROV_CLEARED=1; REVIEWED="$HEAD"; VERDICT=APPROVE
    elif [ "$ACTIONS" = 1 ] && [ "$MSTATE" != DIRTY ] && [ "$MGABLE" != CONFLICTING ]; then
      # BH-491: skip buying a review on a DIRTY head — no CI can run, the read would
      # wait forever. The new head the rebase pushes gets its own review.
      headbound_review provenance "$KEY" "$SLUG" "$NUM" "$P" "$URL" "$REC" "$HEAD" "$REVIEWED" "$VERDICT" "$MSTATE" "$CI" || return 0
    fi
  fi
  # ---- has OUR OWN read already refused this exact head? (2026-09-16) -----
  # The one thing that still parks a `blocked@<this head>` on sight. The build's
  # own head-bound gate no longer does: mc_classify sends that head to
  # HEAD_MOVED, the arm below buys the detached Claude re-review, and only when
  # THAT comes back BLOCK is `hbrefused <key> <head>` written (mc_hb_refuse, in
  # headbound_review) and the row parked on head-not-reapproved for the resolver.
  # A NAMED variable for the same reason MC_INQUEUE, MC_STACK and
  # MC_PROV_CLEARED are: it is not a word gh's PR fields produce, it is a fact
  # about (this PR, this head) that only the caller can look up.
  # MC_REREVIEW_ON_MOVE=0 restores the immediate park and this read costs
  # nothing, because the classifier stops consulting it.
  MC_HB_REFUSED=0
  mc_hb_refused "$KEY" "$HEAD" && MC_HB_REFUSED=1
  # ...and has the lane already PARKED this exact head for want of a verdict?
  # (BH-1019.) Same shape, same reason, the other stop: without it the park is
  # undone on the next tick by the very head drift that produced it, and the
  # spawn re-arms on a head nobody has pushed to (cromford#818).
  mc_step diff-scan
  # THE EPOCH IS READ HERE, FOR EVERY ROW (BH-1019 review, BLOCK 1). It used
  # to be evaluated only inside the lanefail and spawn arms — which a PARKED row
  # never reaches — so a lane recovery was invisible to exactly the rows waiting
  # for it and the park never released. Read once per PR per tick: a file read,
  # and a write only on a transition.
  MC_HB_PARKED=0
  mc_hb_parked "$KEY" "$HEAD" "$MC_LANE_EPOCH" && MC_HB_PARKED=1
  # The scan and the pre-arm guards cost a gh diff / a workflow dispatch, so
  # they run only when everything cheaper already says READY.
  SCAN=0; PREARM=0; DIFF_UNREAD=0; DIFF_WHY=""; MC_HIT_NAMES=""; MC_NEEDS_HV=""; DF=""
  PRE=$(mc_classify "$PSTATE" "$EFF" "$MGABLE" "$HEAD" "$REVIEWED" "$VERDICT" "$PROV" "$CI" "$REDS" "$TIGHT" 0 0 "$PREV" "${HEADBOUND:--}" | cut -f1)
  if [ "$PRE" = READY ]; then
    # A DIFF WE COULD NOT READ IS NOT A CLEAN DIFF (BH-784), the same rule
    # bin/merge-sweep.sh's scan takes. An unread diff is an EMPTY file and the
    # scan finds the zero hits an empty file always has — so without the flag
    # below a 403/429 burst, the exact condition this change is about, would
    # merge PRs the iron-law scan never ran on. SCAN stays 0 because 0 is the
    # honest count of hits FOUND; what the flag carries is that nobody looked,
    # and the READY arm refuses to act on it.
    # AND THE DIFF READ IS MEMOISED ACROSS TICKS TOO (BH-1486): a READY PR
    # nobody has pushed to is re-scanned every five minutes on bytes that did
    # not move. Only a scan from a diff we actually READ is stored — a
    # DIFF_UNREAD is the one thing that must never be remembered as "no hits",
    # which is the BH-784 rule this arm exists for.
    # The scan's fingerprint is NOT the plain attempts count: it also carries
    # the scanner and the base tip (see scan_memo_fp). An unknown component
    # leaves MC_SCAN_FP empty, and an empty fingerprint turns the memo off for
    # this PR — read_memo_get and read_memo_put both refuse it — so the diff is
    # read, which is what every unknown gets here.
    MC_SCAN_FP=$(scan_memo_fp "$MC_MEMO_FP" "${MC_SCANNER_FP:-}" "${LAND_SHA:-}") || MC_SCAN_FP=""
    SCANMEMO=$(read_memo_get scan "$KEY" "$HEAD" "$UPDATED" "$MC_SCAN_FP") || SCANMEMO=""
    case "$SCANMEMO" in ''|*[!0-9]*) SCANMEMO="" ;; esac
    if [ -n "$SCANMEMO" ]; then
      SCAN="$SCANMEMO"; mc_count_inc "$P" scanmemo >/dev/null
    else
      DF=$(mktemp)
      # >>> iron-law diff read (BH-5914; tests/mc-diff-local.bh-5914-test.sh drives this block)
      # BH-5914: a diff too large for the API (HTTP 406) is read from a local
      # clone instead, so a big PR is scanned rather than held forever.
      mc_pr_diff_or_local "$URL" "$DF" "$SLUG" "$P" "$NUM" "${BASEREF:-$PBASE}" "$HEAD" 2>/dev/null; DRC=$?
      if [ "$DRC" = 0 ]; then
        SCAN=$(mc_iron_law_scan "$DF")
        read_memo_put scan "$KEY" "$HEAD" "$UPDATED" "$MC_SCAN_FP" "$SCAN"
      elif [ "$DRC" = 3 ]; then
        # A PARTIAL SCAN IS NOT A CLEAN ONE (BH-5914 review). The local diff has
        # file(s) with no text to scan (binary): what IS there is scanned so its
        # hits are counted and named, but the head is held like an unread diff,
        # and the count is never stored in the scan memo.
        SCAN=$(mc_iron_law_scan "$DF"); DIFF_UNREAD=1
        DIFF_WHY="iron-law: ${MC_DIFF_UNSCANNED-?} file(s) not scanned (no text in the local diff)"
        mc_log "$KEY $DIFF_WHY on ${HEAD:0:8} — held, not stored as a clean scan"
      else DIFF_UNREAD=1
        mc_log "$KEY diff read UNVERIFIABLE (HTTP $(mc_rest_status)) — iron-law scan NOT run on ${HEAD:0:8}"
      fi
      if [ "${SCAN:-0}" -gt 0 ] 2>/dev/null; then MC_HIT_NAMES=$(mc_iron_law_names "$DF" | awk 'NR <= 10' | paste -sd';' -); fi
      # <<< iron-law diff read
    fi
    # AN ACCEPT IN THE DB IS AN ACCEPT (BH-4157): mc_ila_accept, fragment bh-4157-ironlaw-accept.sh.
    # The row is bound to the sha it judged: a push after the adjudication is
    # code nobody adjudicated, and the scan must bite again.
    command -v mc_ila_accept >/dev/null 2>&1 && mc_ila_accept
    # THE SAME HITS ON A NEW HEAD ARE STILL ADJUDICATED (BH-4474). An ACCEPT
    # also records each hit's fingerprint (rule, file, the flagged line's
    # content hash) in the jobs ledger, so a push that never touched those lines
    # (a merge of main, a renumber) does not buy the same ruling again. Every
    # hit must be covered for THIS PR; a new or changed one, or anything
    # ilc_covered cannot prove (outage, crashed check), parks exactly as before.
    if [ "${SCAN:-0}" -gt 0 ] 2>/dev/null && [ "$DIFF_UNREAD" = 0 ] && command -v ilc_covered >/dev/null 2>&1; then
      if [ -z "$DF" ] || [ ! -s "$DF" ]; then
        [ -n "$DF" ] || DF=$(mktemp)
        mc_pr_diff "$URL" "$DF" 2>/dev/null || : > "$DF"
      fi
      if [ -s "$DF" ]; then
        ILC_OUT=$(ilc_covered "$URL" "$SCAN" "$DF"); ILC_RC=$?
      else ILC_OUT="diff unreadable"; ILC_RC=2; fi
      case "$ILC_RC" in
        0) mc_log "$KEY iron-law: carried acceptance from $(printf '%s\n' "$ILC_OUT" | cut -c1-8 | paste -sd, -) — $SCAN hit(s) on ${HEAD:0:8} match an adjudicated set on this PR, not parking"
           SCAN=0 ;;
        1) mc_log "$KEY iron-law: carry refused on ${HEAD:0:8} — new or changed hit(s): $(printf '%s\n' "$ILC_OUT" | paste -sd';' -)" ;;
        *) mc_log "$KEY iron-law: carry UNVERIFIABLE on ${HEAD:0:8} ($(printf '%s' "$ILC_OUT" | head -1)) — parking as before" ;;
      esac
    fi
    [ -n "$DF" ] && rm -f "$DF"; DF=""
    # >>> merge verdict publish (BH-5914; tests/mc-diff-local.bh-5914-test.sh drives this block)
    # THE VERDICT LEAVES THIS PROCESS (BH-5914). Other lanes merge too (the
    # per-box bin/merge-queue.sh merged project-6 #27 twenty seconds after this
    # arm refused it), so the answer for this head goes to the jobs ledger,
    # where their gate reads it.
    # Hits first, so a held head always names what the scan found.
    if [ "${SCAN:-0}" -gt 0 ] 2>/dev/null; then
      mc_merge_verdict_put "$KEY" "$HEAD" hold "iron-law: $SCAN hit(s) on this head${MC_HIT_NAMES:+: $MC_HIT_NAMES}${DIFF_WHY:+; $DIFF_WHY}"
    elif [ "$DIFF_UNREAD" = 1 ]; then
      mc_merge_verdict_put "$KEY" "$HEAD" hold "${DIFF_WHY:-diff-unread: the diff read was UNVERIFIABLE (HTTP $(mc_rest_status)), iron-law scan NOT run}"
    else
      mc_merge_verdict_put "$KEY" "$HEAD" clear "iron-law scan clean"
    fi
    # <<< merge verdict publish
    # The pre-arm guards are SKIPPED on a merge-queue repo: the queue's own
    # merge_group run builds main + the entries ahead + this PR and runs the
    # required check on exactly that tree, which is the same question asked
    # better — and pre-arm's rc-3 "main moved since" path is unsatisfiable in
    # a busy repo, the tail this whole change exists to kill. The script stays
    # exactly as it is for every repo without the rule.
    if [ "${SCAN:-0}" -eq 0 ] && [ -x "$H/bin/pre-arm-guards.sh" ] && [ "$MODE" = merge ] && [ "$QUEUE" = 0 ]; then
      "$H/bin/pre-arm-guards.sh" "$SLUG" "$NUM" >/dev/null 2>>"$MC_LOG"; PA_RC=$?
      [ "$PA_RC" -eq 1 ] && PREARM=1
      [ "$PA_RC" -eq 3 ] && { mc_log "$KEY pre-arm guards not green (rc 3) — retry next tick"; EFF=UNKNOWN; }
    fi
    # A WITHHELD LEAD-VERDICT IS NOT READY (BH-3777). On a Mergify repo the
    # READY arm labels the PR and asks the queue, and a head BH-3683 withholds
    # the status on then waits on queue_conditions for a person while every
    # surface says QUEUED. Asked here, before the classify below, so such a row
    # is NEEDS_HUMAN_VERDICT and never reaches the arm; re-asked every tick, so a
    # human verdict on the head makes the next tick READY and it enqueues.
    if [ "$QUEUE" = 1 ] && [ "$PROVIDER" = mergify ] && [ "${SCAN:-0}" -eq 0 ] 2>/dev/null && [ "$DIFF_UNREAD" = 0 ]; then
      mc_nhv_gate "$SLUG" "$NUM" "$HEAD" "$ACTIONS"
    fi
  fi
  mc_step classify
  IFS=$'\t' read -r STATE WHY <<<"$(mc_classify "$PSTATE" "$EFF" "$MGABLE" "$HEAD" "$REVIEWED" "$VERDICT" "$PROV" "$CI" "$REDS" "$TIGHT" "$SCAN" "$PREARM" "$PREV" "${HEADBOUND:--}")"
  # MIGRATION NOT IN PROD IS NOT READY (BH-7785): mc_mig_hold, fragment bh-7785-migration-hold.sh
  command -v mc_mig_hold >/dev/null 2>&1 && mc_mig_hold
  # ---- the merge-queue re-entry arm (BH-636) ------------------------------
  # A head the merge queue already EJECTED is not READY, whatever the PR's own
  # checks say: the merge_group build tested main+this and went red, and
  # re-enqueueing the same sha just burns another build and ejects again.
  #
  # EXCEPT WHEN THE BATCH, NOT THE PR, WAS THE PROBLEM. Mergify ejects the
  # culprit of a batch, and a batch goes red for a sibling's flake or a killed
  # runner as readily as for this diff. Those PRs sat in `WAIT_CI queue-ejected`
  # with every required check green at their head, an approval bound to that
  # exact sha and a clean merge state — waiting for a push that was never
  # coming, because nothing else in the harness pushes to a finished PR.
  #
  # SO IT GOES BACK IN, ONCE PER (PR, sha), and every clause below is a guard
  # somebody would otherwise pay for:
  #   READY               = approval bound to THIS head, checks green at THIS
  #                         head (mc_ci_state reads actions/runs?head_sha=<full
  #                         sha>, never the PR's rollup) — re-asserted by name
  #                         so a future reordering of mc_classify cannot turn
  #                         into a requeue over a red or unreviewed head
  #   CLEAN + MERGEABLE   GitHub's own word for "required contexts green and
  #                         this merges" — BLOCKED/DIRTY/UNKNOWN never requeue
  #   requeued mark       one per (PR, sha). A head already put back WAITS; it
  #                         is never put back twice, and — the load-bearing half
  #                         — it never falls through to the READY arm's degraded
  #                         direct merge either. This sweep does not merge.
  #   EJN >= 2            ejected again after a requeue: the resolver's, on the
  #                         reason it already owns
  #   tick cap            MC_REQUEUE_CAP per project per tick, deferred and
  #                         re-offered next tick, never dropped
  # A red head keeps today's answer and is NAMED once (DEQUEUED_RED) so a reader
  # can tell "left alone on purpose" from "nothing looked at it".
  if [ "$QUEUE" = 1 ] && [ "$CI" = red ] && mc_ejection_live "$KEY" "$HEAD" \
     && ! mc_attempt_has "dequeuedred $KEY $HEAD" 2>/dev/null; then
    mc_attempt_put "dequeuedred $KEY $HEAD"
    mc_log "DEQUEUED_RED $KEY $HEAD — ejected from the queue and a required check is genuinely failed at this head; left alone, the red ladder owns it"
  fi
  # NEVER RE-QUEUE OVER A LEAD CR (BH-2275 review of #2277). Mergify stamps its
  # `dequeued` label on every PR that leaves the queue — including one it (or
  # mc_cr_dequeue) took out for a standing CHANGES_REQUESTED — and that label is
  # exactly what arms the re-entry below, which runs BEFORE the READY arm's
  # block gate. So when the row carries our crdequeue mark or that label, the
  # CR is asked first (with the thread, so the reviewer's RESUME/MERGE counts):
  # standing — or unreadable — leaves the row READY for the block gate to
  # refuse; cleared lets the re-entry run as before.
  # Whether a `bejv` line predates this tick's re-entry gate (BH-5819): only
  # such a line can make this head the culprit by a failed solo check, in the
  # re-entry arm below and in sdq_arm after it.
  EJSOLO=0; [ "$QUEUE" = 1 ] && [ "$(mc_attempt_count bejv "$KEY" "$HEAD")" -gt 0 ] 2>/dev/null && EJSOLO=1
  CRHOLD=0
  if [ "$STATE" = READY ] && [ "$QUEUE" = 1 ] && [ "$PROVIDER" = mergify ] && command -v bg_cr_standing >/dev/null 2>&1 \
     && { mc_attempt_has "crdequeue $KEY $HEAD" 2>/dev/null || grep -qE '(^|,)dequeued(,|$)' <<<"${RAWLBL:-}"; }; then
    CRTHREAD=$(bg_read "repos/$SLUG/issues/$NUM/comments" created_at 2>/dev/null) || CRTHREAD=""
    CRRC=0; bg_cr_standing "$SLUG" "$NUM" "$URL" "$HEAD" "$CRTHREAD" >/dev/null || CRRC=$?
    if [ "$CRRC" != 1 ]; then
      CRHOLD=1
      mc_log "$KEY not re-queued: a standing CHANGES_REQUESTED (lead/human BLOCK)$([ "$CRRC" = 2 ] && printf ' could not be ruled out (reviews unreadable)') — the block gate owns this row"
    fi
  fi
  if [ "$STATE" = READY ] && [ "$QUEUE" = 1 ] && [ "$CRHOLD" = 0 ] && \
     { mc_ejection_live "$KEY" "$HEAD" \
       || [ -n "$(mc_requeued_mark "$KEY" "$HEAD")" ] \
       || { [ "$PROVIDER" = mergify ] && grep -qE '(^|,)dequeued(,|$)' <<<"${RAWLBL:-}"; }; }; then
    EJN=$(mc_eject_head_strikes "$KEY" "$HEAD")
    EJWHY="queue-ejected — push a fix; the next head is enqueued on its own merits"
    command -v ec_head_why >/dev/null 2>&1 && QS2=$(ec_head_why "$SLUG" "$NUM" "$HEAD") && [ -n "$QS2" ] && EJWHY="queue-ejected: $QS2 — push a fix; the next head is enqueued on its own merits"
    if [ "${EJN:-0}" -ge 2 ]; then
      STATE=BLOCKED_HUMAN; WHY="queue-ejected-twice"
      command -v ec_summary >/dev/null 2>&1 && QS2=$(ec_summary "$SLUG" "$NUM") && [ -n "$QS2" ] && WHY="queue-ejected-twice: $QS2"
    elif [ "$PROVIDER" != mergify ] || [ "${MC_QUEUE_REENTRY:-1}" = 0 ]; then
      STATE=WAIT_CI; WHY="$EJWHY"
    elif [ -n "$(mc_requeued_mark "$KEY" "$HEAD")" ]; then
      STATE=WAIT_CI; WHY="requeued on ${HEAD:0:8}, waiting for Mergify to acknowledge — never re-queued twice"
    elif mc_tick_ejected_now "$P" "$KEY" "$HEAD"; then
      # The settle pass of THIS tick ejected it. Let the ejection stand for one
      # tick: the row has to be able to SAY `queue-ejected` to whoever reads it,
      # and Mergify's own check on this head still carries the failure that
      # ejection was read from — polling it for a witness seconds later would
      # take that failure for an acknowledgement and stamp the row QUEUED.
      mc_log "$KEY ejected by this same tick on ${HEAD:0:8} — the re-entry waits one tick, so the row says queue-ejected and Mergify's check can move off the failure"
      STATE=WAIT_CI; WHY="$EJWHY"
    # A HEAD dequeue-watch NAMED THE CULPRIT of its batch (BH-3728; the lane,
    # BH-3719, writes the mark) is not put back: a fix round owns it, and the
    # fixed head is a new sha this mark does not match. Named once per head.
    elif mc_attempt_has "dqwculprit $KEY $HEAD" 2>/dev/null; then
      STATE=WAIT_CI; WHY="dequeue-watch named this head the culprit of its batch; a fix round owns it"
      mc_attempt_has "dqwculpritlog $KEY $HEAD" 2>/dev/null || { mc_attempt_put "dqwculpritlog $KEY $HEAD"; mc_log "DQW_CULPRIT $KEY $HEAD — not re-queued: dequeue-watch named it the culprit and a fix round owns it"; }
    # A CULPRIT HEAD IS NEVER RE-QUEUED (BH-5819, the operator 2026-10-08 on #5430):
    # #5221/#5281/#5301 came back into batch #5455 on the same heads that had
    # failed. Only a new head clears it. A bystander keeps the requeue below
    # (mc_ejected_hold); MC_EJECTED_REQUEUE=never holds every ejected head.
    elif mc_ejected_hold "$KEY" "$HEAD"; then
      STATE=WAIT_CI; WHY="ejected on ${HEAD:0:8} as the culprit: never re-queued; only a new head clears it"
      mc_attempt_has "ejectedheldlog $KEY $HEAD" 2>/dev/null || { mc_attempt_put "ejectedheldlog $KEY $HEAD"; mc_log "EJECTED_HELD $KEY $HEAD — not re-queued: this head was ejected, and only a new head clears an ejection"; }
    elif [ "$MGABLE" != MERGEABLE ] || [ "$VERDICT" != APPROVE ] || [ "$REVIEWED" != "$HEAD" ]; then
      STATE=WAIT_CI; WHY="$EJWHY"
    # A head that failed its batch is held while it carries that patch (BH-8186);
    # mc_fbh_apply sets STATE and WHY. A clear lets the gate below decide.
    elif command -v mc_fbh_apply >/dev/null 2>&1 && mc_fbh_apply; then
      :
    elif ! { FR_STATE=""; if command -v bej_reentry_gate >/dev/null 2>&1; then bej_reentry_gate "$SLUG" "$NUM" "$KEY" "$URL" "$HEAD" "$MSTATE"
             else fr_reentry_gate "$SLUG" "$NUM" "$KEY" "$URL" "$HEAD" "$MSTATE"; fi; }; then
      # BH-3776: CLEAN, or UNSTABLE only through Mergify's own leftover checks,
      # and a batch failure that is not this PR's (bin/lib/mc-foreign-red.sh).
      # BH-4428: first, Mergify's own verdict — a PR it did not name, or one of
      # several tested alone on the same red main, goes back in; the PR it
      # named gets one comment naming the failing checks (bin/lib/mc-batch-eject.sh).
      # BH-4550: a member whose batch's failing suites reproduce with it merged
      # alone onto the base is parked by the gate itself (FR_STATE).
      STATE="${FR_STATE:-WAIT_CI}"; WHY="${FR_WHY:-$EJWHY}"
    # >>> eject culprit (BH-5819): the last question before a requeue. A human
    # dequeue or a failed solo check makes this head the culprit (dqwculprit +
    # reejected). Asked here, after every other gate, so its comments read is
    # never spent on a head that would not be re-queued anyway (bh-3776 R3/R4).
    elif [ "$PROVIDER" = mergify ] && mc_attempt_has "ejected $KEY $HEAD" 2>/dev/null \
         && mc_eject_culprit_mark "$SLUG" "$NUM" "$KEY" "$HEAD" "$EJSOLO" >/dev/null 2>&1; then
      EJN=$(mc_eject_head_strikes "$KEY" "$HEAD")
      if [ "${EJN:-0}" -ge 2 ]; then STATE=BLOCKED_HUMAN; WHY="queue-ejected-twice"
        command -v ec_summary >/dev/null 2>&1 && QS2=$(ec_summary "$SLUG" "$NUM") && [ -n "$QS2" ] && WHY="queue-ejected-twice: $QS2"
      else STATE=WAIT_CI; WHY="ejected on ${HEAD:0:8} as the culprit: never re-queued; only a new head clears it"; fi
    # <<< eject culprit
    elif [ "$MERGES" != 1 ]; then
      mc_log "$KEY would REQUEUE $KEY $HEAD (merge mode off) — every check is green at this head, the approval is bound to it and the merge is clean${FR_LINE:+; $FR_LINE}"
      STATE=WAIT_CI; WHY="$EJWHY"
    # The pre-queue gate before the requeue (BH-6161): the head merged onto
    # current main must pass a run dispatched after its ejection. Before the
    # budget, so a held head spends no requeue unit (the READY arm's order).
    elif command -v ec_requeue_gate >/dev/null 2>&1 \
         && ! ec_requeue_gate "$SLUG" "$NUM" "$URL" "$HEAD" "$PBASE" "$(ec_last_at "$SLUG" "$NUM" "$HEAD")"; then
      case "$EC_PQ_WORD" in
        red)    STATE=BLOCKED_HUMAN; WHY="$EC_PQ_WHY" ;;
        rebase) STATE=NEEDS_REBASE;  WHY="prequeue after ejection: $EC_PQ_WHY" ;;
        *)      STATE=WAIT_CI;       WHY="queue-ejected: $EC_PQ_WHY" ;;
      esac
    elif ! mc_tick_budget_take "$P" requeue "${MC_REQUEUE_CAP:-5}"; then
      mc_log "$KEY REQUEUE_DEFERRED $KEY $HEAD — this project has spent its ${MC_REQUEUE_CAP:-5} re-queues for this tick; re-offered on the next one"
      STATE=WAIT_CI; WHY="$EJWHY"
    else
      # The mark BEFORE the write, like every other attempt in this lane: a
      # requeue we tried and could not finish must not be tried again every five
      # minutes, and a crash between the two costs this head its one re-entry
      # rather than an unbounded loop.
      mc_requeued_record "$KEY" "$HEAD"
      RQERR=$(mc_requeue_mergify "$SLUG" "$URL" "$HEAD"); RQRC=$?
      case "$RQRC" in
        0|2) STATE=QUEUED; WHY="requeued on ${HEAD:0:8} after a flake ejection"
             command -v mc_fbh_clear >/dev/null 2>&1 && mc_fbh_clear "$KEY" "$HEAD" bystander
             mc_attempt_clear crdequeue "$KEY" "$HEAD" 2>/dev/null   # BH-2275: back in after a cleared CR
             mc_log "REQUEUED $KEY $HEAD — dequeued label off, $MC_MERGIFY_LABEL back on, Mergify acknowledged; its batch build decides from here"
             fr_requeue_note "$SLUG" "$NUM" "$KEY" "$HEAD" ;;
        3)   STATE=WAIT_CI; WHY="requeued on ${HEAD:0:8}, awaiting Mergify's witness"
             mc_log "REQUEUE_UNWITNESSED $KEY $HEAD — ${RQERR:-Mergify acknowledged nothing}. The row waits; it is NOT merged directly"
             fr_requeue_note "$SLUG" "$NUM" "$KEY" "$HEAD" ;;
        *)   STATE=WAIT_CI; WHY="$EJWHY"
             mc_log "REQUEUE_FAILED $KEY $HEAD — ${RQERR:-the requeue was refused}; the row keeps its ejection and a later tick tries again" ;;
      esac
    fi
  fi
  # A HUMAN PARK ON A GREEN, REVIEWED HEAD SAYS SO ON THE PR (BH-3456). The
  # likely project-5#3414 path: a classifier park the self-enqueue then skips
  # as gate `conductor`, silently. Every tick; mc_hold_comment dedupes.
  if [ "$STATE" = BLOCKED_HUMAN ] && [ "$CI" = green ] && [ "$REVIEWED" = "$HEAD" ] && command -v mc_hold_comment >/dev/null 2>&1; then
    case "$WHY" in tightened*) HCK=tightened ;; provenance*) HCK=provenance ;; iron-law*) HCK=iron-law ;; *) HCK="" ;; esac
    [ -n "$HCK" ] && mc_hold_comment "$KEY" "$HEAD" "$HCK" "$WHY"
  fi
  # ---- a failed batch follows its patch (BH-8186) --------------------------
  # A READY head that carries the patch of a head Mergify dequeued for a failed
  # batch is not enqueued (mc_fbh_apply, the BH-8186 fragment).
  if [ "$STATE" = READY ] && [ "$QUEUE" = 1 ] && [ "$PROVIDER" = mergify ] && command -v mc_fbh_apply >/dev/null 2>&1; then
    mc_fbh_apply || true
  fi
  # ---- a stale Mergify dequeue on a freshly approved head (BH-3480) -------
  # Our merge-queue label plus a row that was QUEUED last tick reads as "in the
  # queue" (mc_mergify_inqueue) even after Mergify dequeued the PR, and a plain
  # `@mergifyio queue` does nothing on a dequeued PR. sdq_arm reads Mergify's
  # payload and requeues ONCE per head when a verdict newer than the dequeue
  # binds it, on BH-636's requeue mark and tick budget. Only for a labelled PR
  # Mergify is not visibly holding (no queued/checking label), so a queued PR
  # costs no read. MC_QUEUE_REENTRY=0 switches it off with the BH-636 arm.
  if [ "$QUEUE" = 1 ] && [ "$PROVIDER" = mergify ] && [ "${CRHOLD:-0}" = 0 ] \
     && [ "${MC_QUEUE_REENTRY:-1}" != 0 ] && [ "${PSTATE:-}" = OPEN ] \
     && { [ "$STATE" = READY ] || [ "$STATE" = QUEUED ]; } \
     && grep -qE "(^|,)$MC_MERGIFY_LABEL(,|\$)" <<<"${RAWLBL:-}" \
     && ! grep -qE '(^|,)(queued|checking)(,|$)' <<<"${RAWLBL:-}" \
     && command -v sdq_arm >/dev/null 2>&1; then
    sdq_arm
  fi
  # ---- a hotfix PR with migration SQL needs its proof first (BH-370.2) ----
  # A migration PR is always tier 2 — bin/run-build.sh forces TIER=2 on any diff
  # matching `migrations?/|\.sql$`, so its own gated tier-1 merge never lands one
  # and this lane is the only merger left. THIS is therefore the gate that
  # decides whether unapplied SQL reaches main. It sits
  # above the `case "$STATE"` below, which is where both writes live — the
  # merge-queue label add and the degraded `gh pr merge` — so a hotfix whose SQL
  # nobody has applied cannot take either exit.
  #
  # It only READS. bin/hotfix-migrate.sh posts the proof; nothing here runs it.
  # The hold is not sticky either: the row is re-derived every tick, so the tick
  # after the stage posts an accepted proof takes the ordinary READY path.
  if [ "$STATE" = READY ] && hotfix_pr_is "${RAWLBL:-}" "${REC:-}"; then
    HP=$(mc_hotfix_proof "$SLUG" "$NUM" "${RAWLBL:-}" "${REC:-}" "${P:-}")
    case "$HP" in
      ok|n/a) ;;
      # A hold is a decision a person made about this SQL, so it parks for a
      # person: the reason is deliberately NOT in mc_resolver_owns, which is
      # what makes it page at once and keeps bin/blocked-resolver.sh's rebuild
      # ladder off a PR whose problem is a database.
      hold) STATE=BLOCKED_HUMAN; WHY="hotfix-migration-hold: the stage held (flagged, quiet window, or no apply path); a human reads the proof comment" ;;
      # missing, stale, and any word a later contract adds: wait and re-read.
      *)    STATE=WAIT_CI; WHY="hotfix migration proof $HP: bin/hotfix-migrate.sh must post its proof on this head before the queue" ;;
    esac
    [ "$HP" = n/a ] || mc_log "$KEY hotfix migration proof on ${HEAD:0:8}: $HP"
  fi
  # ---- a head with NO workflow run at all gets ONE kick (2026-09-15) ------
  # The catch-all under the retarget above, for every OTHER way a head ends
  # up with no run: GitHub retargets a child by ITSELF when the parent's
  # branch is deleted, and that base change fires no `pull_request` workflow
  # either (default activity types opened|synchronize|reopened). project-5
  # #913/#943/#1011/#1020/#1021 each carried a base_ref_changed event by
  # cromford[bot] and zero runs on the head, sat in `WAIT_CI checks
  # none` with the required check never reporting and the merge-queue label
  # never added, and were unstuck one at a time by hand with a close/reopen.
  #
  # FOUR GUARDS, and each of them is load-bearing:
  #   MERGEABLE   `ci=none` is the NORMAL state of a CONFLICTING PR — GitHub
  #               runs no workflow on a tree it cannot merge (see the DIRTY
  #               clause in mc_classify) — so kicking one would close and
  #               reopen every conflicted PR on the fleet for nothing.
  #   on $PBASE   a PR still based on a feature branch is STACKED_WAIT and
  #               belongs to the block above, not to this one.
  #   >= 10m      the clock is the ROW's age in WAIT_CI, not the age of this
  #               reason: mc_transition keeps `since` across a reason-only
  #               change, so a PR that waited on a pending run and then lost
  #               it carries that older `since` here. Below the window, a head
  #               with no run is a run that has not APPEARED yet; above it, it
  #               is a run that is never coming. Note `checks none` also
  #               covers a head whose every run was CANCELLED (mc_ci_state
  #               answers `none` for that too) — a kick is the right answer
  #               there as well, and it is why this is not written as "no run
  #               has ever existed".
  #   once        recorded as `cikick <key> <head>` in MC_ATTEMPTS, beside
  #               `rebase`, `red` and `ejected`, so a second tick over the
  #               same head never closes the PR again.
  # ACTIONS only, like every other gh write in this lane; observe mode says
  # what it would have done and writes nothing.
  #   not flaky   a head whose runs were CANCELLED reads `checks flake` now and
  #               is RE-RUN by the ladder above; closing and reopening it as
  #               well would be two builds of the same tree.
  #   identity    BH-800, and the reason it is guarded HERE too: `checks none`
  #               wins over the BLOCKED arm in mc_classify, so an identity-blocked
  #               head GitHub has also never run a workflow on lands in this
  #               block — and stuck_rekick already refuses this exact
  #               close/reopen for this exact reason: it cannot add a push
  #               permission. The IDENTITY_NOT_PERMITTED line above is this
  #               tick's record and the ALERT is the action. The escalate arm
  #               below needs a `cikick` row this never writes, so it stays quiet
  #               too.
  # CI NEVER STARTED (BH-7241): every state, its own first-seen clock, one
  # workflow_dispatch and one alert per head. It writes cikick on a dispatch, so
  # the close/reopen below stays quiet on a head it already re-triggered.
  command -v mst_ci_nostart >/dev/null 2>&1 && mst_ci_nostart "$P" "$KEY" "$SLUG" "$NUM" "$URL" "$HEAD" \
    "$CI" "${MC_FLAKE:-}" "$MSTATE" "$MGABLE" "${BASEREF:-}" "$PBASE" "$WHY" "$BR"
  if [ "$STATE" = WAIT_CI ] && [ "$WHY" = "checks none" ] && [ "$MGABLE" = MERGEABLE ] && \
     [ "${MC_IDENTITY_BLOCKED:-0}" != 1 ] && \
     [ "$MSTATE" != DIRTY ] && [ -z "${MC_FLAKE:-}" ] && \
     [ -n "$PBASE" ] && [ -n "${BASEREF:-}" ] && [ "$BASEREF" = "$PBASE" ] && \
     [ "$PREV" = WAIT_CI ] && ! mc_attempt_has "cikick $KEY $HEAD" 2>/dev/null; then
    KSINCE=$(mc_row_field "$KEY" 3); KAGE=$(( $(mc_now) - ${KSINCE:-0} ))
    if [ -n "$KSINCE" ] && [ "$KAGE" -ge "${MC_CI_KICK_MIN_AGE:-600}" ]; then
      if [ "$ACTIONS" != 1 ]; then
        mc_log "$KEY would kick CI on ${HEAD:0:8} — $((KAGE/60))m in WAIT_CI on $PBASE with no workflow run at all (observe mode: nothing written)"
      elif mc_kick_ci "$SLUG" "$NUM" "$HEAD"; then
        mc_attempt_put "cikick $KEY $HEAD"
        mc_log "$KEY CI kicked (close/reopen) on ${HEAD:0:8} — $((KAGE/60))m in WAIT_CI on $PBASE and GitHub has never run a workflow on this head"
      else
        mc_log "$KEY CI kick FAILED on ${HEAD:0:8} — the row stays WAIT_CI and a later tick tries again"
      fi
    fi
  # AND THE KICK THAT DID NOT WORK GETS AN OWNER (BH-636). The block above fires
  # once per head and then has nothing left to do, which is how #1827/#1645 sat
  # in WAIT_CI after their kick with no further line ever written. A head that is
  # still run-less at twice the window is a workflow that is never going to fire
  # for it, and that is a sentence, not a wait.
  elif [ "$STATE" = WAIT_CI ] && [ "$WHY" = "checks none" ] && [ "$MGABLE" = MERGEABLE ] && \
       [ "$MSTATE" != DIRTY ] && [ -z "${MC_FLAKE:-}" ] && \
       mc_attempt_has "cikick $KEY $HEAD" 2>/dev/null; then
    KSINCE=$(mc_row_field "$KEY" 3); KAGE=$(( $(mc_now) - ${KSINCE:-0} ))
    [ -n "$KSINCE" ] && ci_absent_escalate "$KEY" "$URL" "$HEAD" "$KAGE"
  fi
  # HOW MANY PRs OF THIS PROJECT A BATCH TRAIN COULD BE MADE OF (BH-498). An
  # approved PR that is READY or waiting on a rebase is exactly what
  # bin/batch-resolve.sh looks for; counting them here is what lets the tick
  # decide whether to spawn that lane at all, instead of paying for a PR list
  # and a fetch on every repo every five minutes to learn there is nothing to do.
  case "$STATE" in
    READY|NEEDS_REBASE) [ "$VERDICT" = APPROVE ] && mc_count_inc "$P" batchable >/dev/null ;;
  esac
  SINCE=$(mc_transition "$KEY" "$STATE" "$WHY" "$HEAD" "$REVIEWED" "$URL" "$VERDICT" "$MSTATE" "$REC")
  if [ "$STATE" = READY ]; then MC_STEP_LOG=1; fi
  mc_step ready-checks
  # `ci=absent` and `ci=flake`, not `ci=none`, in every line a person reads
  # (BH-636): "none" reads as "nothing to report" when what it means is "GitHub
  # never built this head" or "the runs were killed", which are the two things
  # the reader would act on.
  CIWORD=$(mc_ci_word "$CI" "${MC_FLAKE:-}")
  # BH-3630: the verdict and CI word of a provenance park, in the page's own
  # words, for bin/blocked-resolver.sh (removed in any other state).
  mc_prov_detail_put "$KEY" "$STATE" "$WHY" "$HEAD" "$VERDICT" "$CIWORD"
  mc_budget_check "$KEY" "$STATE" "$SINCE" "$URL" "$WHY (verdict=$VERDICT ci=$CIWORD mergeState=$MSTATE mode=$MODE)"
  # ---- the stuck-state detector (2026-09-15) ------------------------------
  # The backstop under every state in the table: a PR that has not moved in
  # longer than its TTL says so ONCE per (PR, state, head) and, where a
  # deterministic re-kick exists, gets it in the same tick (stuck_rekick).
  # This is what #1045 and #1124/#1136 needed and no budget could give them —
  # #1045 was inside WAIT_CI's budget for ten hours after its one alert, and a
  # park the resolver owns pages never by design.
  if mc_stuck_check "$KEY" "$STATE" "$SINCE" "$HEAD" "$URL" "$WHY" "verdict=$VERDICT ci=$CIWORD mergeState=$MSTATE mode=$MODE"; then
    stuck_rekick "$KEY" "$STATE" "$WHY" "$SLUG" "$NUM" "$URL" "$HEAD" "$MSTATE" "$MGABLE" "${BASEREF:-}" "$PBASE" "$CI" "$VERDICT" "$REVIEWED" "${PROVIDER:-}"
  fi
  # ---- the land trigger, before the state arms (BH-870) --------------------
  # This project's base moved since the last completed fan-out, so every open
  # PR of it is offered one mechanical rebase. It runs HERE — after
  # mc_transition, so it judges this tick's state, and before the arms, so a
  # spawn takes the REBASING transition the way the NEEDS_REBASE arm's does.
  # rc 0 means it spawned and this PR's tick is over.
  mc_step land-rebase
  land_rebase_arm && return 0
  # ---- actions, behind the flags ------------------------------------------
  mc_step "arm:$STATE"
  case "$STATE" in
    RED_TWICE)
      # THE PARK IS THE HAND-OFF. RED_TWICE is not a state this lane can move
      # — the head has had its one rerun and is still red — so it is offered
      # to bin/blocked-resolver.sh exactly like the BLOCKED_AGENT reasons, in
      # the line shape br_handoff_lines reads, once per park.
      [ "$PREV" = RED_TWICE ] && return 0
      mc_log "$KEY RED_TWICE red-twice: CI is still red on ${HEAD:0:8} after its failed jobs were re-run once — handed to bin/blocked-resolver.sh (fix round on the branch, or a fresh rebuild against current main): $URL"
      return 0 ;;
    NEEDS_REBASE)
      [ "$ACTIONS" = 1 ] || return 0
      # A head Mergify ejected for a base conflict gets its one rebase ahead of
      # the budget and the merge-tree test (eject_rebase_arm, BH-1677).
      eject_rebase_arm && return 0
      # THE BUDGET IS A FILE, NOT A VARIABLE (2026-09-15). The PR workers of one
      # project run side by side and each is its own subshell, so a decremented
      # variable would be decremented in a copy and every worker would spend the
      # same last rebase. mc_tick_budget_left is the cheap guard; the claim is
      # the take, next to the spawn.
      mc_tick_budget_left "$P" rebase "$REBASE_BUDGET" || { budget_spent "$P" rebase "$KEY"; return 0; }
      # THE CONFLICT TEST COMES FIRST (W2-D, 2026-09-14). A merge into main
      # marks every open PR on the repo DIRTY-or-stale, and today each one of
      # them buys a rebase — a clone, a typecheck, a push, and a moved head
      # that then costs a re-review. `git merge-tree --write-tree` asks the
      # same question locally, touching nothing, and a clean answer means
      # there was nothing to rebase. The row stays NEEDS_REBASE and says why:
      # this is not a state change, it is this tick declining to spend one,
      # and the next tick asks again (capped — see merge_tree_clean).
      # MC_MERGE_TREE=0 skips the test and rebases exactly as before.
      # THE LAND ARM IS THE DELIBERATE EXCEPTION (land_rebase_arm, BH-870): a
      # landing on the base brings every clean open PR current on purpose, and
      # it runs before this case. What stays true here is the narrower claim
      # this block was written for — a head GitHub calls DIRTY that git says
      # merges clean does not buy a rebase on that evidence alone.
      if [ "${MC_MERGE_TREE:-1}" != 0 ] && merge_tree_clean "$KEY" "$SLUG" "$P" "$HEAD" "$NUM"; then
        mc_transition "$KEY" NEEDS_REBASE "MERGE_TREE clean on ${HEAD:0:8} — no conflict with origin/main, head left alone" "$HEAD" "$REVIEWED" "$URL" "$VERDICT" "$MSTATE" "$REC" >/dev/null
        return 0
      fi
      # THE POOL PATH (BH-486) WINS OVER BOTH REBASE BRANCHES BELOW. Under
      # REBASE_ON_POOL there is no hub work to detach: mc_rebase writes a queue
      # row and returns, so the call is INLINE and no lane job, no setsid child
      # and no hub worktree exist for this PR at all. The detached knob is about
      # how long a rebase holds this tick, and a pool rebase holds it for one
      # HTTP call.
      if mc_pool_rebase_enabled "$P"; then
        JOBF=$(mc_rb_file "$SLUG" "$NUM" "$HEAD"); JOBST=$(mc_rb_state "$JOBF")
        case "$JOBST" in
          running)
            if [ "$(mc_rr_field "$JOBF" status)" = pool ]; then
              mc_log "$KEY REBASING ${HEAD:0:8} — pool rebase running on a pool machine; nothing waits on it"
              mc_transition "$KEY" REBASING "REBASING ${HEAD:0:8} (pool rebase running)" "$HEAD" "$REVIEWED" "$URL" "$VERDICT" "$MSTATE" "$REC" >/dev/null
            else
              # A pid job spawned before the flag flipped: today's line, kept
              # verbatim so `pid 0` can never render for a file that has no pid
              # to report.
              mc_log "$KEY REBASING ${HEAD:0:8} — detached job (pid $(mc_rr_field "$JOBF" pid)) still running; nothing waits on it"
              mc_transition "$KEY" REBASING "REBASING ${HEAD:0:8} (detached rebase running)" "$HEAD" "$REVIEWED" "$URL" "$VERDICT" "$MSTATE" "$REC" >/dev/null
            fi
            return 0 ;;
          done|failed|stale)
            # rebase_consume above read this result and applied it, once per
            # (PR, head); walking out in silence is what made the row look
            # stranded (BH-764), so the exit names itself.
            rebase_noop_say consumed "$KEY" "$HEAD" "the pool rebase of this head already produced its result ($JOBST) and it was applied on an earlier tick; the row is still NEEDS_REBASE, so nothing here re-queues it — the NEEDS_REBASE TTL forgets the attempt and a later tick may queue a fresh one"
            return 0 ;;
        esac
        if mc_attempt_has "rebase $KEY $HEAD" 2>/dev/null; then
          rebase_noop_say attempted "$KEY" "$HEAD" "this head has already had its one pool rebase and its job file is gone; nothing re-queues it here — the NEEDS_REBASE TTL forgets the attempt and a later tick may queue a fresh one"
          return 0
        fi
        mc_tick_budget_take "$P" rebase "$REBASE_BUDGET" || { budget_spent "$P" rebase "$KEY"; return 0; }
        OUT=$(mc_rebase "$SLUG" "$P" "$BR" "$HEAD" "$URL"); RC=$?
        # rc 7 spent NOTHING — no queue row, no job file — so the budget goes
        # back and this head's one rebase is NOT recorded: the next tick asks
        # again. Anything else reached the queue and counts.
        if [ "$RC" = 7 ]; then mc_tick_budget_give "$P" rebase
        else mc_attempt_put "rebase $KEY $HEAD"; mc_count_inc "$P" rebases >/dev/null; fi
        rebase_result "$KEY" "$URL" "$REC" "$HEAD" "$REVIEWED" "$VERDICT" "$MSTATE" "$RC" "$OUT"
        return 0
      fi
      # THE REBASE IS DETACHED (2026-09-14), for the reason the re-review is:
      # a clone + merge + typecheck + push is minutes long and every one of
      # them was spent inside this tick, holding the project's lock. The tick
      # now spawns one job per (PR, head) and READS the result on a later
      # tick; the approval reaches the pushed head through mc_rebase's own
      # rebind inside the job, or through the patch-id rebind above.
      # MC_DETACHED_REBASE=0 restores the inline call.
      if [ "${MC_DETACHED_REBASE:-1}" = 0 ]; then
        mc_attempted rebase "$KEY" "$HEAD" && return 0
        mc_tick_budget_take "$P" rebase "$REBASE_BUDGET" || { budget_spent "$P" rebase "$KEY"; return 0; }
        mc_count_inc "$P" rebases >/dev/null
        mc_transition "$KEY" REBASING "merging origin/main into $BR" "$HEAD" "$REVIEWED" "$URL" "$VERDICT" "$MSTATE" "$REC" >/dev/null
        OUT=$(mc_rebase "$SLUG" "$P" "$BR" "$HEAD" "$URL"); RC=$?
        rebase_result "$KEY" "$URL" "$REC" "$HEAD" "$REVIEWED" "$VERDICT" "$MSTATE" "$RC" "$OUT"
        return 0
      fi
      JOBF=$(mc_rb_file "$SLUG" "$NUM" "$HEAD"); JOBST=$(mc_rb_state "$JOBF")
      case "$JOBST" in
        running)
          mc_log "$KEY REBASING ${HEAD:0:8} — detached job (pid $(mc_rr_field "$JOBF" pid)) still running; nothing waits on it"
          mc_transition "$KEY" REBASING "REBASING ${HEAD:0:8} (detached rebase running)" "$HEAD" "$REVIEWED" "$URL" "$VERDICT" "$MSTATE" "$REC" >/dev/null ;;
        done|failed|stale)
          # rebase_consume above read this result and applied it, once per
          # (PR, head). Reading it a second time would re-park a PR that has
          # since moved on — but walking out in silence is what made the row
          # look stranded (BH-764), so the exit names itself.
          rebase_noop_say consumed "$KEY" "$HEAD" "the detached rebase of this head already produced its result ($JOBST) and it was applied on an earlier tick; the row is still NEEDS_REBASE, so nothing here re-runs it — the NEEDS_REBASE TTL forgets the attempt and a later tick may spawn a fresh one"
          return 0 ;;
        *)
          # One rebase per (PR, head), recorded AFTER the spawn and not before:
          # a spawn refused at the parallel cap must be retried on a later
          # tick, never counted as this head's one rebase.
          if mc_attempt_has "rebase $KEY $HEAD" 2>/dev/null; then
            rebase_noop_say attempted "$KEY" "$HEAD" "this head has already had its one rebase and its detached job file is gone; nothing re-runs it here — the NEEDS_REBASE TTL forgets the attempt and a later tick may spawn a fresh one"
            return 0
          fi
          # Taken BEFORE the spawn and handed back when the spawn did not
          # happen: a claim made after the fact is one two workers can both
          # make, and a refusal at the parallel cap must not cost the project a
          # rebase it never ran.
          mc_tick_budget_take "$P" rebase "$REBASE_BUDGET" || { budget_spent "$P" rebase "$KEY"; return 0; }
          mc_rebase_spawn "$SLUG" "$NUM" "$P" "$BR" "$HEAD" "$URL"; RC=$?
          [ "$RC" = 0 ] || mc_tick_budget_give "$P" rebase
          case "$RC" in
            0) mc_attempt_put "rebase $KEY $HEAD"; mc_count_inc "$P" rebases >/dev/null
               mc_log "$KEY REBASE_SPAWNED — detached rebase of ${HEAD:0:8} into $BR ($(mc_rebase_job_ref "$SLUG" "$NUM" "$P" "$HEAD"))"
               mc_transition "$KEY" REBASING "REBASING ${HEAD:0:8} (detached rebase spawned)" "$HEAD" "$REVIEWED" "$URL" "$VERDICT" "$MSTATE" "$REC" >/dev/null ;;
            3) if [ "${MC_ON_MACHINE:-}" = 1 ]; then mc_log "$KEY REBASE_DEFERRED ${HEAD:0:8} — $(mc_rebase_spawn_why 3)"
               else mc_log "$KEY REBASE_QUEUED — ${MC_REBASE_PARALLEL:-0} rebases already running fleet-wide (operator-set MC_REBASE_PARALLEL); spawning on a later tick"; fi ;;
            4) mc_log "$KEY REBASE_ON_RECORD ${HEAD:0:8} — $(mc_rebase_spawn_why 4)" ;;
            *) mc_log "$KEY detached rebase could not be spawned (rc $RC)" ;;
          esac ;;
      esac ;;
    HEAD_MOVED)
      [ "$ACTIONS" = 1 ] || return 0
      headbound_review moved "$KEY" "$SLUG" "$NUM" "$P" "$URL" "$REC" "$HEAD" "$REVIEWED" "$VERDICT" "$MSTATE" "$CI" ;;
    READY)
      mc_step base-guard
      # NOTHING MERGES INTO ANYTHING BUT THE PROJECT'S BASE (BH-410). This runs
      # before the freeze, before the flags and before the budget, because it is
      # not a policy about WHEN to merge — it is the answer to "would this write
      # land the PR into somebody's feature branch", and that answer is the same
      # in observe mode, under a red main and with the budget spent. A refusal
      # writes one row and nothing to GitHub.
      #
      # It is the SECOND check, and deliberately redundant with the classifier's
      # MC_STACK=wait arm above, which is what parks a stacked child today.
      # mc_base_guard reads no label and depends on no clause ordering, so a
      # future reordering of mc_classify cannot turn into a merge into a feature
      # branch — BH-491 hoisted one clause in that classifier on 2026-09-16 and
      # shadowed two branches that had nothing to do with it.
      if WRONGB=$(mc_base_guard "$PBASE" "${BASEREF:-}" ""); then :; else
        mc_log "$KEY MERGE_REFUSED: the PR list says this PR is based on $WRONGB, not $PBASE — a merge or enqueue would land it INTO that branch. Parked STACKED_WAIT; no gh write"
        mc_transition "$KEY" STACKED_WAIT "merge refused: based on $WRONGB, not $PBASE — waiting for the parent to merge and retarget" "$HEAD" "$REVIEWED" "$URL" "$VERDICT" "$MSTATE" "$REC" >/dev/null
        return 0
      fi
      # NOTHING MERGES ON A DIFF NOBODY READ (BH-784). The scan above answered
      # "0 hits" out of an empty file because GitHub refused the diff, not
      # because the diff is clean, and this arm is the one that lands or
      # enqueues the PR. The row keeps the state the classifier gave it —
      # nothing is parked, relabelled or dequeued for a rate limit — and the
      # next tick asks for the diff again. bin/merge-sweep.sh's scan takes the
      # same rule one line before its own merge verb.
      if [ "${DIFF_UNREAD:-0}" = 1 ]; then
        mc_log "$KEY not merged this tick: ${DIFF_WHY:-the diff read was UNVERIFIABLE so the iron-law scan NOT run} — row left as-is, the next tick re-reads it"
        mc_ready_why "$KEY" "$HEAD" diff-unread "not merged this tick: ${DIFF_WHY:-the diff read was UNVERIFIABLE so the iron-law scan NOT run} — row left as-is, the next tick re-reads it" logged
        return 0
      fi
      # THE FREEZE COMES FIRST, before the budget and before any gh write: a
      # merge into a red main is a merge whose CI signal is worthless, and on
      # a queue repo it is an ejection for everything behind it too.
      if [ -n "$MAIN_RED" ]; then
        if main_red_exempt "$SLUG" "$NUM" "$URL" "$HEAD" "${RAWLBL:-}"; then
          mc_attempt_has "mainredpass $KEY $HEAD" 2>/dev/null \
            || { mc_attempt_put "mainredpass $KEY $HEAD"
                 mc_log "$KEY is exempt from the main-red freeze (labelled $MC_MAIN_RED_LABEL, or its whole diff is test files) — it may merge while flags/$MAIN_RED is on"; }
        else
          mc_attempt_has "mainredhold $KEY $HEAD" 2>/dev/null \
            || { mc_attempt_put "mainredhold $KEY $HEAD"
                 mc_log "$KEY READY and HELD by the main-red freeze on ${HEAD:0:8} — $SLUG main is red (flags/$MAIN_RED); it merges as soon as the flag is gone, and nothing about this PR needs doing"; }
          mc_ready_why "$KEY" "$HEAD" main-red "HELD by the main-red freeze: $SLUG main is red (flags/$MAIN_RED); it merges as soon as the flag is gone" logged
          return 0
        fi
      fi
      mc_step dep-gate
      # >>> dep gate
      # AN OPEN DECLARED DEPENDENCY HOLDS THIS MERGE (BH-629). #615 merged with
      # "Depends on #459 (PR #609)" in its own body while #609 was still open,
      # so main carried a suite sourcing a file main did not have and every open
      # PR in the repo was red for 7.5 hours. Nothing between READY and
      # `gh pr merge` had ever read the PR's own body.
      #
      # Same shape as the main-red hold above: one dedupe line per (PR, head),
      # one log line, `return 0`. The row stays READY, no transition, no gh
      # write, and it sits BEFORE the budget check so a hold costs no merge
      # budget. rc 2 (could not read) holds too, on its own dedupe key and with
      # no alert — a dependency nobody could read is not one that closed.
      # The dedupe line is appended BEFORE the alert is sent: an alert that dies
      # then costs one line rather than one per tick.
      #
      # THE FOURTH ARGUMENT IS STILL "" ON PURPOSE (BH-994, 2026-09-19). This
      # tick does not hold the PR's body and cannot: the rows it works from are
      # the TAB-SEPARATED lines built at `mapfile -t ROWS` from the open-PR
      # list, and a PR body is multi-line free text that no tsv row can carry —
      # `IFS=$'\t' read` would tear it across the columns the way an empty
      # labels column once tore baseRefName out of the row. Nor is the body in
      # the list: this lane asks for mergeStateStatus, mergeable and
      # isInMergeQueue, which are outside gh-pr-list.sh's REST-mappable set, so
      # the list is a GraphQL read and adding `body` to it would grow exactly
      # the budget BH-994 is moving OFF. So the gate fetches the body itself —
      # over REST since BH-994 — and that read is the one GraphQL call this arm
      # no longer makes.
      #
      # THE RELEASE IS SAID ONCE, AND THE HOLD IS NOTED EVERY TICK (BH-4497).
      # #4415 was held at 21:33Z on 2026-10-04 behind "PR #4242 QUEUED"; #4242
      # merged at 21:38, and at 21:57 its STUCK page still read "#4242 QUEUED"
      # from a note written once, when the hold comment posted. Now every held
      # tick rewrites the dep-hold ready-why note (mc_stuck_waiting_on re-reads
      # the gate live for that kind), and the first passing tick on a head this
      # gate held logs ONE RELEASED line naming what it read (PDG_SAY_PASS=1).
      # It says the row goes on to the merge checks, never "enqueued": a ticket
      # hold, merges-off or the budget can still stop it, each with its own line.
      if command -v pdg_hold >/dev/null 2>&1; then
        PDGOUT=$(PDG_SAY_PASS=1 pdg_hold "$SLUG" "$NUM" "$URL" ""); PDGRC=$?
        if [ "$PDGRC" = 0 ]; then
          if ! mc_attempt_has "depwaithold $KEY $HEAD" 2>/dev/null; then
            mc_attempt_put "depwaithold $KEY $HEAD"
            mc_log "$KEY READY and HELD by the PR-dependency gate on ${HEAD:0:8}: it declares ${PDGOUT:-a dependency} that is still open — it merges as soon as that closes, and nothing about this PR needs doing"
            mc_alert "$KEY" READY "held by the PR-dependency gate on ${HEAD:0:8}: it declares ${PDGOUT:-a dependency} that is still open; it merges when that closes: $URL"
          fi
          command -v mc_hold_comment >/dev/null 2>&1 && mc_hold_comment "$KEY" "$HEAD" dep-hold "held by the PR-dependency gate: it declares ${PDGOUT:-a dependency} that is still open"
          command -v mc_ready_why >/dev/null 2>&1 && mc_ready_why "$KEY" "$HEAD" dep-hold "held by the PR-dependency gate: it declares ${PDGOUT:-a dependency} that is still open" logged
          return 0
        elif [ "$PDGRC" = 1 ]; then
          if mc_attempt_has "depwaithold $KEY $HEAD" 2>/dev/null && ! mc_attempt_has "depwaitrelease $KEY $HEAD" 2>/dev/null; then
            mc_attempt_put "depwaitrelease $KEY $HEAD"
            mc_log "$KEY READY and RELEASED by the PR-dependency gate on ${HEAD:0:8}: read this tick — ${PDGOUT:-no open dependency}; it goes on to the merge checks this tick"
          fi
        elif [ "$PDGRC" = 2 ]; then
          mc_attempt_has "depwaitunread $KEY $HEAD" 2>/dev/null \
            || { mc_attempt_put "depwaitunread $KEY $HEAD"
                 mc_log "$KEY not merged this tick: the PR-dependency gate could not read its dependency — nothing written, the next tick asks again"; }
          mc_ready_why "$KEY" "$HEAD" dep-unread "not merged this tick: the PR-dependency gate could not read its dependency — nothing written, the next tick asks again" logged
          return 0
        fi
      fi
      # <<< dep gate
      # THE TIER-2 SELF-ENQUEUE ACTS ON THIS ROW ONLY IF IT GOT THIS FAR (BH-1668
      # review F1). Everything above is the conductor's own answer to "may this
      # head land": the classifier's provenance, iron-law, tightened, pre-arm and
      # red-twice parks, the unread-diff refusal, the freeze and the dependency
      # hold. ae_project posts `@mergifyio queue`, which on a Mergify repo IS a
      # merge, so it reads this mark rather than re-deciding on fewer gates. It
      # sits BEFORE the merge switch and the budget on purpose: the step keeps
      # its own WOULD line under observe/kill and takes no merge budget.
      # A HELD TICKET'S PR DOES NOT MERGE (BH-1526), and neither does a PR held
      # by a HOLD on its own thread (BH-1668): one log line, no row, no alert.
      # BEFORE the READY mark (review of #1926), so the self-enqueue never sees a
      # held head as cleared — and before the merge switch, so observe mode says
      # it too.
      # EVERY HOLD FROM HERE ON SAYS WHY (2026-09-27): mc_ready_why refreshes a
      # per-PR note each tick and logs ONE line per (PR, head, reason), so
      # pipeline-health's sweepstall detector and the STUCK READY page can tell
      # a PR held on purpose from one nobody is landing. These three returns
      # were silent, and 816 false sweepstall pages came out of that silence.
      mc_step ticket-hold
      command -v to_lane_hold >/dev/null 2>&1 && to_lane_hold "$P" "$SLUG" "$NUM" \
        && { mc_ready_why "$KEY" "$HEAD" ticket-hold "held by a HOLD on its ticket or on its own thread (to_lane_hold; the MERGE_HELD line names it)"; return 0; }
      # THE PRE-QUEUE GATE (BH-4545): a head that fails its suites merged onto
      # current main never enters the queue. Asked only on a tick that can
      # enqueue, before the READY mark and the budget, so a hold or a park
      # spends no merge unit and the tier-2 self-enqueue never sees the head.
      # The park is a resolver hand-off: no label, no @mergifyio. An invariant
      # red (BH-5439) also posts ONE evidence comment per (PR, head, main);
      # every other red posts none.
      # BH-5572: `rebase` is a reused green whose head conflicts with current
      # main, so the row goes to NEEDS_REBASE. `defer` is a dispatch the gate
      # skipped because the lead fence or the block gate below will refuse this
      # head; the arm goes on so they refuse it as usual (`# >>> prequeue defer`).
      mc_step prequeue
      PQ_DEFER=0
      if [ "$MERGES" = 1 ] && [ "${QUEUE:-0}" = 1 ] && [ "${PREV:-}" != QUEUED ] && command -v pq_gate >/dev/null 2>&1; then
        pq_gate "$SLUG" "$NUM" "$URL" "$HEAD" "$PBASE" >/dev/null
        case "$PQ_VERDICT" in
          hold) mc_ready_why "$KEY" "$HEAD" prequeue-pending "$PQ_WHY"; return 0 ;;
          rebase) mc_transition "$KEY" NEEDS_REBASE "prequeue reuse: $PQ_WHY" "$HEAD" "$REVIEWED" "$URL" "$VERDICT" "$MSTATE" "$REC" >/dev/null
                  return 0 ;;
          defer) PQ_DEFER=1 ;;
          red)  PQ_WHY=""; [ -n "$PQ_PATH" ] && [ -r "$PQ_PATH.why" ] && PQ_WHY=$(head -n1 "$PQ_PATH.why")
                PQ_RSN="the head merged onto current main fails them"
                case "$PQ_WHY" in invariant:*) PQ_RSN="$PQ_WHY: $PQ_RSN" ;; esac
                mc_attempt_has "pqred $KEY $HEAD $PQ_MAIN" 2>/dev/null \
                  || { mc_attempt_put "pqred $KEY $HEAD $PQ_MAIN"
                       mc_log "$KEY PREQUEUE_RED on ${HEAD:0:8}: $PQ_SUITES fail merged onto main ${PQ_MAIN:0:12} — not enqueued, handed to bin/blocked-resolver.sh: $URL"
                       case "$PQ_WHY" in invariant:*)
                         if [ -s "$PQ_PATH.fail" ] && command -v pq_red_comment >/dev/null 2>&1; then pq_red_comment "$SLUG" "$NUM" "$URL" "$HEAD" "$PQ_MAIN" "$PQ_PATH"
                         else mc_log "$SLUG#$NUM prequeue: invariant red with no fail lines, no comment"; fi ;;
                       esac; }
                mc_transition "$KEY" BLOCKED_HUMAN "prequeue-red: $PQ_SUITES on main ${PQ_MAIN:0:12} — $PQ_RSN" "$HEAD" "$REVIEWED" "$URL" "$VERDICT" "$MSTATE" "$REC" >/dev/null
                return 0 ;;
        esac
      fi
      [ "$PQ_DEFER" = 1 ] || { command -v ae_mark >/dev/null 2>&1 && ae_mark "$P" ready "$KEY" "$HEAD"; }
      # A READY ROW THAT IS NOT ENQUEUED SAYS WHY (Lane D, 2026-09-24): this
      # return was silent, so a READY row under a merges pause, observe mode or
      # a missing merge flag read as the silent-skip shape. Once per (PR, head).
      # Only when this tick TAKES actions: an observe or kill-switch tick is
      # inert as a whole and says so once per tick already. The ready-why NOTE
      # is written on every tick either way (2026-09-27, `logged`: Lane D's line
      # below is this hold's one reason line, so mc_ready_why adds none).
      if [ "$MERGES" != 1 ]; then
        mc_ready_why "$KEY" "$HEAD" merges-off "merges are off this tick (mode ${MODE:-?} — a merges pause or no merge flag); it enqueues on the first tick they are on" logged
        [ "$ACTIONS" = 1 ] && ! mc_attempt_has "readymergesoff $KEY $HEAD" 2>/dev/null && { mc_attempt_put "readymergesoff $KEY $HEAD"
          mc_log "$KEY READY on ${HEAD:0:8} and NOT enqueued: merges are off this tick (mode $MODE — a merges pause or no merge flag); it enqueues on the first tick they are on"; }
        return 0
      fi
      mc_tick_budget_left "$P" merge "$MERGE_BUDGET" || { budget_spent "$P" merge "$KEY"
        mc_ready_why "$KEY" "$HEAD" budget "merge deferred — $P has spent this tick's merge budget" logged; return 0; }
      # Re-read immediately before acting: the tick's own read may be minutes
      # old and a human may have merged or pushed since.
      # baseRefName RIDES ALONG ON IT (BH-410) — one more field on a call the arm
      # already makes, so the guard costs no API call. This is the read that
      # matters: the list's base column has been lost before (the collapsed tsv
      # that hid every stacked child until #342) and a positional column added
      # without a `-` placeholder would lose it again, and when it is lost the
      # classifier's stacked-child test abstains and the row arrives here READY.
      # `// ""` so a field GitHub answers null renders as EMPTY and the guard
      # ABSTAINS on it; the bare template would print the word `null`, which is
      # not a branch name and would refuse every merge on the fleet.
      mc_step state-guard
      # >>> pre-merge state guard
      # THIS READ IS REST, NEVER `gh pr view` (BH-994, 2026-09-19; the whole
      # merge family followed it in BH-784). It is the read that actually stops
      # a merge: with the App installation's GraphQL budget exhausted,
      # `gh pr view` answered nothing, NOWST was EMPTY, and the test below
      # refused every READY row on the fleet with "not merged: state changed
      # under the tick ()" — an empty parenthesis that names no state at all,
      # which is what the hub logged on 2026-09-19 while REST on the same token
      # still had 3141/6600 points.
      #
      # THE THREE FIELDS ARE THE SAME THREE, IN THE SAME ORDER AND CASE.
      # mc_pr_view normalises REST's `.state` (lower case, plus merged_at) into
      # STATE, and `.head.sha` / `.base.ref` are REST's spelling of the other
      # two. `// ""` keeps its job: a null renders EMPTY so the base guard below
      # ABSTAINS rather than reading the word `null` as a branch.
      # ONE NUANCE, in the log line only: GraphQL distinguishes MERGED from
      # CLOSED and so does MC_REST_NORM (merged_at set = MERGED), so the log
      # line still names the state it read. The GUARD is unchanged either way —
      # it tests `= OPEN`, and neither spelling is OPEN.
      # BH-1606 (#1624 review S1): the PR's AUTHOR rides on the same read, after a
      # `|`, for the lead fence below — no second GET of the pull. Split off
      # before the three words are read, so an answer without it (an older
      # stub, a field GitHub left out) is the three words exactly as before and
      # the fence reads the author itself.
      NOWST=$(mc_pr_view "$URL" '"\(.STATE) \(.head.sha) \(.base.ref // "")|\(.user.login // "")"' 2>/dev/null); NOWRC=$?
      NLOGIN=""
      case "$NOWST" in *'|'*) NLOGIN="${NOWST##*|}"; NOWST="${NOWST%|*}" ;; esac
      # A READ THAT COULD NOT ANSWER IS NOT A STATE CHANGE (BH-784). Before this
      # it fell into the line below and logged "state changed under the tick ()",
      # which is a claim about the PR made out of an empty answer — the #768
      # sentence. Now the row is left exactly where it is, nothing is written,
      # and the next tick asks again.
      # 404 and 403 are not the same sentence: an ABSENT PR is a fact the next
      # list read will act on by simply not offering the row, while a 403 is a
      # question to ask again. Neither writes anything here.
      if [ "$NOWRC" = 44 ]; then
        mc_log "$KEY not merged this tick: PR ABSENT (HTTP 404) — row left as-is, the list read decides next tick"
        mc_ready_why "$KEY" "$HEAD" gh-unread "not merged this tick: PR ABSENT (HTTP 404) — row left as-is, the list read decides next tick" logged; return 0
      elif [ "$NOWRC" != 0 ]; then
        NOWHTTP=$(mc_rest_status)
        mc_log "$KEY not merged this tick: GitHub read UNVERIFIABLE (HTTP $NOWHTTP) — row left as-is"
        mc_ready_why "$KEY" "$HEAD" gh-unread "not merged this tick: GitHub read UNVERIFIABLE (HTTP $NOWHTTP) — row left as-is" logged; return 0
      fi
      read -r NPS NHEAD NBASE <<<"$NOWST"
      [ "$NPS" = OPEN ] && [ "$NHEAD" = "$HEAD" ] || { mc_log "$KEY not merged: state changed under the tick ($NOWST)"
        mc_ready_why "$KEY" "$HEAD" state-moved "not merged: state changed under the tick ($NOWST)" logged; return 0; }
      # <<< pre-merge state guard
      # A read that FAILED never reaches the line above — the rc arms answered
      # it first, and said which failure it was. A read that SUCCEEDED but is
      # missing a field renders empty under `-q`, and an empty NPS is not OPEN:
      # that merge stops, loudly, in the log, rather than landing unchecked.
      if WRONGB=$(mc_base_guard "$PBASE" "" "${NBASE:-}"); then :; else
        mc_log "$KEY MERGE_REFUSED: GitHub says this PR is based on $WRONGB, not $PBASE (the list said '${BASEREF:-unknown}') — a merge or enqueue would land it INTO that branch. Parked STACKED_WAIT; no gh write"
        mc_transition "$KEY" STACKED_WAIT "merge refused: based on $WRONGB, not $PBASE — waiting for the parent to merge and retarget" "$HEAD" "$REVIEWED" "$URL" "$VERDICT" "$MSTATE" "$REC" >/dev/null
        return 0
      fi
      # A LEAD PR MERGES ONLY ON A LEAD/HUMAN MERGE ROW ON THIS HEAD (BH-1606).
      # to_lane_hold below exempts a lead PR, so it cannot stop the lead's own
      # PR landing on this row's APPROVE. The fence is asked on $HEAD, the head
      # the state guard above just re-read and the one mc_merge / mc_enqueue pin
      # to, so the verdict and the merge are about one sha. It is asked AFTER
      # MC_PROV_CLEARED (#1536) and does not read it: a provenance clearance —
      # a claude head-bound re-review, or the provcleared marker — makes a row
      # READY and is never a lead verdict. A lead row is read here, in
      # vd_standing, and nowhere else. Unreadable holds this tick (rc 2) and
      # feeds the lane-wide outage alert. AHEAD of the block gate, whose clean
      # scan would otherwise restart that alert's count on every tick. No row,
      # no budget, no alert for a lead PR simply waiting on its lead.
      mc_step lead-fence
      MC_LEAD_CLEARED=0
      if command -v to_lane_lead_fence >/dev/null 2>&1; then
        to_lane_lead_fence "$P" "$SLUG" "$NUM" "$HEAD" "$NLOGIN"; MC_LEAD_RC=$?
        if [ "$MC_LEAD_RC" != 1 ]; then
          if [ "$MC_LEAD_RC" = 0 ]; then
            mc_ready_why "$KEY" "$HEAD" lead-held "lead PR: merges only on a lead/human MERGE row on this head (the MERGE_HELD lead-pr line names it)"
          else
            mc_ready_why "$KEY" "$HEAD" lead-unread "the lead fence could not be read this tick (${TO_LEAD_KIND:-unknown}) — asked again next tick"
          fi
          return 0
        fi
        MC_LEAD_CLEARED="$TO_LEAD_CLEARED"   # to_lane_lead_hold always sets it
      fi
      mc_step block-gate
      # >>> block gate
      # A HUMAN BLOCK ON THE THREAD REFUSES THE MERGE (BH-762). The verdict this
      # row carries was true when the review was written; the thread has had
      # every minute since to move. THREAD RECENCY IS LAW on the build side, and
      # this is the merge side of the same law — the reason the incident PR was
      # squash-merged 8 minutes after its BLOCK is that nothing between READY and
      # `gh pr merge` had ever read a comment.
      #
      # It sits before the budget take, so a refusal spends nothing, and it
      # writes NO row: the PR stays READY, the next tick asks the thread again,
      # and a block that stands is caught by the ordinary READY TTL alert. A new
      # state would hand the PR to the blocked-resolver's fix ladder, which is
      # the opposite of "wait for the human's clear".
      if command -v bg_scan >/dev/null 2>&1; then
        BG_ISSUE=""
        [ "$("$H/bin/fleet-conf.sh" "$P" board_prefix 2>/dev/null)" = "-" ] && BG_ISSUE=$(mc_issue_of "$REC" "$BR")
        BGOUT=$(bg_scan "$SLUG" "$NUM" "$URL" "$HEAD" "$BG_ISSUE"); BGRC=$?
        if [ "$BGRC" != 0 ] && ! bg_enforce; then
          mc_log "$KEY block gate WARN-ONLY (BLOCK_GATE_ENFORCE=0): $(bg_reason "$BGRC" "$BGOUT" "$HEAD") — merging as it would have before the gate"
        elif [ "$BGRC" = 1 ]; then
          mc_log "$KEY MERGE_REFUSED block-gate: $(bg_why "$BGOUT" "$HEAD") — nothing merges until a newer commit lands or that author clears it"
          bg_refuse "$SLUG" "$NUM" "$URL" "$HEAD" "$BGOUT" merge-conductor \
            || mc_log "$KEY block gate could not post the refusal comment on $URL — the merge is refused either way and the next tick retries the post"
          # THE CI-BLOCK HOOK (BH-3932): bg_scan's 4th field is the block's id;
          # its body is not in BGOUT, so the hook gets "" and reads it by id. Its
          # rc is ignored and the refusal below stands whatever it answers.
          IFS=$'\t' read -r _ _ _ BG_ID <<<"$BGOUT"
          command -v mc_block_ci_step >/dev/null 2>&1 && { mc_block_ci_step "$SLUG" "$NUM" "$HEAD" "$URL" "$BG_ID" "" || true; }
          # A HELD PR STILL CARRIES OUR LABEL (BH-2199), so a lead CR on it must
          # take it out of the Mergify queue too, once (BH-2275).
          if [ "$PROVIDER" = mergify ] && mc_labels_csv_has "${RAWLBL:-}" "$MC_MERGIFY_LABEL"; then
            mc_cr_dequeue "$SLUG" "$KEY" "$URL" "$HEAD" "$MERGES" "$BGOUT" || true
          fi
          mc_ready_why "$KEY" "$HEAD" block-gate "MERGE_REFUSED block-gate: $(bg_why "$BGOUT" "$HEAD") — nothing merges until a newer commit lands or that author clears it" logged
          return 0
        elif [ "$BGRC" = 2 ]; then
          mc_log "$KEY not merged this tick: block gate could not read $BGOUT — nothing written, the next tick tries again"
          mc_ready_why "$KEY" "$HEAD" block-gate-unread "not merged this tick: block gate could not read $BGOUT — nothing written, the next tick tries again" logged
          return 0
        fi
      fi
      # <<< block gate
      # >>> prequeue defer
      # BH-5572: the gate skipped its dispatch because a check above was
      # expected to refuse this head, and none did (the BLOCK cleared or the
      # lead fence changed its answer between the two reads). No verdict, so
      # no enqueue: the gate dispatches on the next tick.
      if [ "$PQ_DEFER" = 1 ]; then
        mc_ready_why "$KEY" "$HEAD" prequeue-pending "$PQ_WHY; nothing refused it this tick, so the gate dispatches on the next tick"
        return 0
      fi
      # <<< prequeue defer
      # A CLEARED LEAD PR IS NEVER LABEL-ENQUEUED (BH-1606). Mergify queues
      # whatever head the PR has when it picks it up, so its label cannot carry
      # the pin the lead verdict needs (mc_enqueue_mergify's "honest gap"). The
      # lead lands it — or the native queue / a direct merge, both pinned. Said
      # once per (PR, head).
      if [ "${MC_LEAD_CLEARED:-0}" = 1 ] && [ "$PROVIDER" = mergify ]; then
        mc_attempt_has "leadmergify $KEY $HEAD" 2>/dev/null || { mc_attempt_put "leadmergify $KEY $HEAD"
          mc_log "$KEY lead PR cleared on ${HEAD:0:12} but NOT enqueued: a Mergify label cannot be pinned to that head — left for the lead: $URL"; }
        command -v mc_hold_comment >/dev/null 2>&1 && mc_hold_comment "$KEY" "$HEAD" lead-mergify "lead PR cleared but a Mergify label cannot be pinned to this head; left for the lead"
        mc_ready_why "$KEY" "$HEAD" lead-unpinned "lead PR cleared on ${HEAD:0:12} but NOT enqueued: a Mergify label cannot be pinned to that head — left for the lead" logged
        return 0
      fi
      # A HELD PR IS NOT RE-ASKED EVERY TICK (BH-2199). The hold below (rc 3,
      # the queue acknowledged nothing) is counted per (PR, head) in the attempts
      # ledger; between asks a held tick adds one to the count and stops here,
      # so a repo whose queue product is off does not get an `@mergifyio queue`
      # comment every five minutes. Every MC_MERGIFY_REASK_TICKS-th held tick
      # asks again. Before the take, so a held tick spends no merge budget.
      if [ "$QUEUE" = 1 ] && [ "$PROVIDER" = mergify ] && [ "${PREV:-}" != QUEUED ]; then
        HELDN=$(mc_attempt_count mergifyhold "$KEY" "$HEAD"); HELDN=${HELDN:-0}
        REASK=$(mergify_reask_ticks_for "$P")
        if [ "$HELDN" -gt 0 ] && [ $((HELDN % REASK)) -ne 0 ]; then
          mc_attempt_put_n mergifyhold "$KEY" "$HEAD"
          mc_log "$KEY MERGE_HELD: the $PROVIDER queue has acknowledged nothing at ${HEAD:0:8} for $HELDN held tick(s) — NOT merged directly; the queue is asked again every $REASK held ticks"
          mc_ready_why "$KEY" "$HEAD" queue-held "MERGE_HELD: the $PROVIDER queue has acknowledged nothing at ${HEAD:0:8} for $HELDN held tick(s); the queue is asked again every $REASK held ticks" logged
          return 0
        fi
      fi
      # ON A LANE-RUN MACHINE NOTHING LANDS (BH-6495). The machine has no
      # builds/ record, so its verdict is the ledger's alone and the BH-4585
      # CONTRADICTION park cannot fire, and its flock serialises against
      # nobody. An enqueue and a direct merge are both landings, so both wait
      # for the hub, which runs this PR itself on its next tick (deferred=land).
      # Before the budget take, so a deferred PR spends no merge budget.
      # A LEASE-HELD PROJECT RUN ENQUEUES (BH-6890): bin/merge-conductor-project.sh
      # holds the project lease for the whole tick (MC_LEASED_RUN=1 with
      # MC_LEASE_FENCE), and every landing writer renews that fence first. Only
      # on a repo with a queue: its landing settles through the QUEUED pass,
      # which the hub runs when the machine defers the settle. A direct merge
      # (no queue, or landing_direct) settles in the same tick, and a settle
      # needs hub files, so it still waits for the hub (deferred=land).
      if [ "${MC_ON_MACHINE:-}" = 1 ] && ! { [ "${MC_LEASED_RUN:-}" = 1 ] && [ -n "${MC_LEASE_FENCE:-}" ] && [ "$QUEUE" = 1 ]; }; then
        mc_defer_word land "$KEY"
        mc_log "$KEY READY at ${HEAD:0:8} on a lane-run machine — not landed here; the hub lands it on its next tick (deferred=land)"
        mc_ready_why "$KEY" "$HEAD" machine-deferred "READY on a lane-run machine; the hub lands it on its next tick" logged
        return 0
      fi
      mc_step enqueue
      # The refusal above sits BEFORE the take, so a PR that never reached gh
      # costs the project no unit of this tick's merge budget.
      mc_tick_budget_take "$P" merge "$MERGE_BUDGET" || { budget_spent "$P" merge "$KEY"
        mc_ready_why "$KEY" "$HEAD" budget "merge deferred — $P has spent this tick's merge budget" logged; return 0; }
      # On a repo with a queue the conductor ENQUEUES (mc_enqueue picks the
      # provider's own entry mechanism: `gh pr merge` under GitHub's native
      # queue, the trigger LABEL under Mergify) and the landing settles on a
      # later tick through the QUEUED pass above. On a repo without one it
      # merges here and settles in the same tick.
      if [ "$QUEUE" = 1 ]; then
        # THE CALL — AND ONLY THE CALL — IS SERIALISED PER PROJECT. mc_merge_locked
        # holds locks/merge-conductor-<project>-merge.lock for exactly this gh
        # invocation, so two READY PRs of one repo can never race main, and the
        # lock is gone before the settle, the issue close and the deploy lane
        # below, every one of which forks a child that would otherwise inherit
        # the fd and hold the lock for its whole life.
        # EXCEPT A MERGIFY ENQUEUE (Lane D, 2026-09-24). That call is a label,
        # a comment and a witness poll of up to MC_MERGIFY_WAIT_S (90s): it
        # touches neither main nor the queue's order, so it has nothing to
        # serialise against — and holding the lock through the poll let about
        # two READY PRs per project per tick in while every other one timed out
        # at MC_MERGE_LOCK_WAIT and waited a tick, in flock's random order
        # (cromford PRs 30-175 min approved, CLEAN and unqueued). Nothing
        # after it merges: a silent queue (rc 3) is HELD (BH-2199), so no gate
        # read before the poll can go stale into a merge.
        # OPTIMISTIC LANDING (BH-6745, wave 2 of #6541). With MC_LANDING_MODE
        # optimistic on a Mergify repo, a PR that landing_eligible accepts is
        # merged here, bound to its head and under the project merge lock, with
        # no queue label, inside its own per-tick budget MC_DIRECT_MERGE_BUDGET.
        # rc 1 is "not direct": the enqueue below runs exactly as before. A
        # refused merge (405/409/422) is no strike: the queue takes the PR on
        # the next tick (landing_direct's landingfail mark). Modes queue and
        # shadow never get here. The step is marked HERE, not in the $( ):
        # mc_step exits on a 401, and a subshell's exit 0 is not a merge, so
        # only rc 0 WITH the `merged` token settles; anything else enqueues.
        if [ "$PROVIDER" = mergify ] && command -v landing_direct_on >/dev/null 2>&1 && landing_direct_on "$P" "$PROVIDER"; then
          mc_step landing-direct
          LDOUT=$(landing_direct "$P" "$SLUG" "$NUM" "$HEAD" "$KEY" "${RAWLBL:-}" "$URL"); LDRC=$?
          case "$LDRC:$(head -1 <<<"$LDOUT")" in
            0:merged) mc_count_inc "$P" merges >/dev/null
               mc_step settle
               conductor_settle "$KEY" "$URL" "$P" "$SLUG" "$BR" "$REC" "$JOB" "$HEAD" "$REVIEWED" "$VERDICT" "$MSTATE" "by:conductor (direct landing)" "$(sed -n 2p <<<"$LDOUT")"
               return 0 ;;
            2:*) mc_tick_budget_give "$P" merge
               mc_ready_why "$KEY" "$HEAD" budget "direct merge deferred — $P has spent this tick's direct-merge budget" logged
               return 0 ;;
            3:*) mc_tick_budget_give "$P" merge
               mc_ready_why "$KEY" "$HEAD" merge-lock "not merged directly this tick: another PR of $P held the project merge lock for ${MC_MERGE_LOCK_WAIT:-120}s — the next tick tries again" logged
               return 0 ;;
            4:*) mc_tick_budget_give "$P" merge
               mc_ready_why "$KEY" "$HEAD" direct-failed "direct merge refused ($(head -1 <<<"$LDOUT")); the queue takes it on the next tick" logged
               return 0 ;;
          esac
        fi
        if [ "$PROVIDER" = mergify ]; then
          ERR=$(mc_enqueue "$URL" "$HEAD"); RC=$?
        else
          ERR=$(mc_merge_locked "$P" mc_enqueue "$URL" "$HEAD"); RC=$?
        fi
        if [ "$RC" = 99 ]; then
          mc_tick_budget_give "$P" merge
          mc_log "$KEY not enqueued this tick: another PR of $P held the project merge lock for ${MC_MERGE_LOCK_WAIT:-120}s — nothing was written, the next tick tries again"
          mc_ready_why "$KEY" "$HEAD" merge-lock "not enqueued this tick: another PR of $P held the project merge lock for ${MC_MERGE_LOCK_WAIT:-120}s — the next tick tries again" logged
          return 0
        fi
        case "$RC" in
          0) mc_count_inc "$P" merges >/dev/null
             command -v ae_mark >/dev/null 2>&1 && ae_mark "$P" asked "$KEY" "$HEAD"   # BH-1668 F2: no second ask
             mc_attempt_clear crdequeue "$KEY" "$HEAD" 2>/dev/null   # BH-2275: re-queued after a cleared CR
             mc_log "$KEY enqueued in the $PROVIDER merge queue at ${HEAD:0:8} — the conductor settles it when the queue merges it"
             [ -n "${MC_LANDED_FILE:-}" ] && printf 'queued %s\n' "$KEY" >> "$MC_LANDED_FILE"
             mc_transition "$KEY" QUEUED "enqueued at ${HEAD:0:8}" "$HEAD" "$REVIEWED" "$URL" "$VERDICT" "$MSTATE" "$REC" >/dev/null ;;
          2) mc_count_inc "$P" merges >/dev/null
             command -v ae_mark >/dev/null 2>&1 && ae_mark "$P" asked "$KEY" "$HEAD"
             mc_step settle
             conductor_settle "$KEY" "$URL" "$P" "$SLUG" "$BR" "$REC" "$JOB" "$HEAD" "$REVIEWED" "$VERDICT" "$MSTATE" "by:conductor (merge queue, landed in-tick)" ;;
          # rc 3: the request is in place and the QUEUE never answered. That is
          # a standing condition on the REPO — Mergify told us so in as many
          # words on project-5 #510: "The product Merge Queue needs to be
          # activated" — or it is simply slow, and nothing about THIS PR.
          # Burning the two-strike path would park every READY PR on the repo in
          # BLOCKED_HUMAN for one dashboard toggle.
          #
          # AND IT NEVER MERGES AROUND THE QUEUE (BH-2199). Until 2026-09-24 this
          # arm fell back to a DIRECT merge. #2196 landed that way at 21:09Z over
          # a lead CHANGES_REQUESTED, while Mergify was running batches and was
          # only slow to acknowledge. rc 3 only ever comes from Mergify, and the
          # provider is `mergify` only when the repo's .mergify.yml declares
          # queue_rules — the repo chose a queue to keep main green, so the
          # conductor HOLDS: no merge, no strike, the budget unit goes back, the
          # row stays READY with our label on (the queue may still pick it up;
          # mc_mergify_inqueue then classifies it QUEUED), ONE alert per repo per
          # day, and the ask is repeated every MC_MERGIFY_REASK_TICKS held ticks
          # (the throttle above the budget take). A direct merge in this state
          # is an explicit lead action, never the conductor's. That includes a
          # hotfix: it still heads the tick's order, so it is asked first.
          3) mc_tick_budget_give "$P" merge
             mc_attempt_put_n mergifyhold "$KEY" "$HEAD"
             mc_queue_inactive_alert "$SLUG" "$URL" "${ERR:-}" >/dev/null 2>&1 || true
             HWORD=""; [ "$HOTFIX_THIS" = 1 ] && HWORD="HOTFIX "
             mc_log "$KEY MERGE_HELD: ${HWORD}the $PROVIDER queue acknowledged nothing at ${HEAD:0:8} (${ERR:-no reason given}) — NOT merged directly: $SLUG's .mergify.yml has queue_rules, so the queue owns main. Row stays READY; the queue is asked again every $(mergify_reask_ticks_for "$P") held ticks. A direct merge here is a lead action"
             mc_ready_why "$KEY" "$HEAD" queue-held "MERGE_HELD: the $PROVIDER queue acknowledged nothing at ${HEAD:0:8} (${ERR:-no reason given}); the row stays READY and the queue is asked again" logged ;;
          # rc 4 (BH-3806): the enqueue's own la_decide withheld the verdict, so
          # nothing was labelled or asked. Only a gate/enqueue race reaches it
          # (the gate above normally classifies such a row first). No strike;
          # the budget unit goes back; `asked` keeps the tier-2 self-enqueue
          # from posting the `@mergifyio queue` this refused.
          4) mc_tick_budget_give "$P" merge
             command -v ae_mark >/dev/null 2>&1 && ae_mark "$P" asked "$KEY" "$HEAD"
             mc_log "$KEY NOT enqueued: ${ERR#refused: }"
             mc_transition "$KEY" NEEDS_HUMAN_VERDICT "${ERR#refused: }" "$HEAD" "$REVIEWED" "$URL" "$VERDICT" "$MSTATE" "$REC" >/dev/null ;;
          *) N=$(mc_attempt_count mergefail "$KEY" "$HEAD"); mc_attempt_put_n mergefail "$KEY" "$HEAD"
             mc_log "$KEY enqueue FAILED on the $PROVIDER queue (${ERR:-no reason given}) attempt $((N+1))"
             [ "$N" -ge 1 ] || mc_ready_why "$KEY" "$HEAD" enqueue-failed "enqueue FAILED on the $PROVIDER queue (${ERR:-no reason given}) attempt $((N+1)); the next tick tries again" logged
             [ "$N" -ge 1 ] && { mc_transition "$KEY" BLOCKED_HUMAN "queue-enqueue-failed-twice: ${ERR:-?}" "$HEAD" "$REVIEWED" "$URL" "$VERDICT" "$MSTATE" "$REC" >/dev/null
               mc_log "$KEY BLOCKED_AGENT queue-enqueue-failed-twice: the $PROVIDER merge queue refused a READY PR twice (${ERR:-no reason given}) — handed to bin/blocked-resolver.sh (fresh rebuild against current main): $URL"; } ;;
        esac
        # BH-6744: record what the landing contract WOULD do with this head.
        # After the enqueue, so it can never delay or change it; rc 0 always.
        # Mode queue (the default) returns before its step mark, read or line.
        command -v landing_shadow >/dev/null 2>&1 && landing_shadow "$P" "$SLUG" "$NUM" "$HEAD" "$KEY" "${RAWLBL:-}"
      elif mc_step merge; ERR=$(mc_merge_locked "$P" mc_merge "$URL" "$HEAD"); RC=$?; [ "$RC" = 0 ]; then
        mc_count_inc "$P" merges >/dev/null
        mc_step settle
        conductor_settle "$KEY" "$URL" "$P" "$SLUG" "$BR" "$REC" "$JOB" "$HEAD" "$REVIEWED" "$VERDICT" "$MSTATE" "by:conductor" "$ERR"
      elif [ "$RC" = 99 ]; then
        # Nothing was written — another PR of this project was merging — so this
        # is not one of the two strikes, and the budget unit goes back.
        mc_tick_budget_give "$P" merge
        mc_log "$KEY not merged this tick: another PR of $P held the project merge lock for ${MC_MERGE_LOCK_WAIT:-120}s — the next tick tries again"
        mc_ready_why "$KEY" "$HEAD" merge-lock "not merged this tick: another PR of $P held the project merge lock for ${MC_MERGE_LOCK_WAIT:-120}s — the next tick tries again" logged
      else
        N=$(mc_attempt_count mergefail "$KEY" "$HEAD"); mc_attempt_put_n mergefail "$KEY" "$HEAD"
        mc_log "$KEY merge FAILED (${ERR:-no stderr}) attempt $((N+1))"
        [ "$N" -ge 1 ] || mc_ready_why "$KEY" "$HEAD" merge-failed "merge FAILED (${ERR:-no stderr}) attempt $((N+1)); the next tick tries again" logged
        [ "$N" -ge 1 ] && { mc_transition "$KEY" BLOCKED_HUMAN "merge-failed-twice: ${ERR:-?}" "$HEAD" "$REVIEWED" "$URL" "$VERDICT" "$MSTATE" "$REC" >/dev/null
          mc_log "$KEY BLOCKED_AGENT merge-failed-twice: gh pr merge failed twice on a READY PR (${ERR:-no stderr}) — handed to bin/blocked-resolver.sh (fresh rebuild against current main): $URL"; }  # gh-guard-allow: prose in a log line, not a call
      fi ;;
  esac
  return 0
}

# tick_project <project> — one project's whole tick: the merge-queue settle
# pass, the open-PR pass, the closed-unmerged pass. Run in its OWN background
# subshell (see mc_tick_fanout in bin/lib/mc/tick-scope.sh).
#
# THE PROJECT-WIDE LOCK IS GONE (2026-09-15). It was one flock per project taken
# with `flock -n` for the WHOLE tick, so a tick that was still working — a queue
# settle, a rebase result, a slow list — cost its repo the next one to three
# ticks ENTIRELY. Measured 21:00-23:00Z on 2026-09-15: 102 "an earlier conductor
# tick still holds this project's lock — skipped" lines in two hours
# (cromford 30, project-5 21, project-7 15, project-2 9,
# project-8 9, project-4 6, the rest 3 each) — every one of them a whole
# repo's PRs standing still because ONE of them was busy.
#
# What replaces it is two much smaller locks (mc_pr_lock, mc_merge_lock):
# pr_worker holds PR N's own lock for PR N's work, and the merge call alone is
# serialised per project. Two overlapping ticks of one project are therefore
# fine by construction — they meet on a PR, not on the repo, and the one that
# arrives second skips THAT PR and carries on with the others.
#
# The per-tick spend budgets moved with it: they were bash variables, which a
# concurrent worker would inherit a copy of, and they are now flock'd counter
# files keyed by tick id (mc_tick_budget_take).
#
# BH-5463 (2026-10-08) puts back a lock for FULL ticks only, outside this
# function: wake-loop started a full tick every 12-15 min, each ran 536-1167 s,
# and the overlap paid twice for one repo. Keyed ticks still meet a full tick
# only on PR locks. The lock fd is never open in here.
tick_project() {
  local P="$1"
  hb_tick merge-conductor "tick $P"
  # >>> project hold
  # IS THIS PROJECT HELD (BH-1465)? First thing after the heartbeat and before
  # everything that costs: no lock, no mc_tick_budget_take, no use_token, no
  # GitHub read, and no mc_tick_metrics — that last one rewrites
  # tick-<p>.json.started_at, which the cadence hold below measures from, and a
  # hold that stamped it would hold the project for ever (the same reason
  # BH-1486's hold skips it). hb_tick has already fired, so the heartbeat and
  # bin/lane-reaper.sh still see a live lane rather than a dead one.
  if command -v lane_project_held >/dev/null 2>&1 && lane_project_held merge-conductor "$P"; then
    mc_log "$(command -v pause_label >/dev/null 2>&1 && pause_label "$P")TICK $P held: flags/$LANE_HELD_FLAG is set — no lock, no budget and no GitHub read this tick (decision=held)"
    return 0
  fi
  # <<< project hold
  # >>> project on a machine (BH-6890)
  # lane_placement.merge-conductor.<project> = fly: the whole project runs on
  # a lane-run machine (bin/lib/mc/project-placement.sh). rc 0 = a row is
  # enqueued or live, or the fallback is off: no PR work here. rc 2 = the hub
  # takes a finished row back (failed or deferred) and runs the whole project
  # once: a full tick runs on, a keyed tick starts a full tick of this one
  # project under the BH-5463 full-tick lock (mc_proj_takeback_full). rc 4
  # (BH-7635) = a deferred row that names its PRs: on a full or a keyed tick,
  # the hub runs ONE keyed tick of only those PRs (mc_proj_takeback_keyed,
  # MC_PROJ_TAKEBACK_KEYS) and nothing more for the project. rc 1 = today's
  # tick. A machine is never gated; MC_PROJ_GATE=0 (set once by
  # mc_tick_fanout from the settings cache) skips the gate when no project is placed fly.
  if [ "${MC_PROJ_GATE:-1}" != 0 ] && command -v mc_fly_project_gate >/dev/null 2>&1; then
    mc_fly_project_gate "$P"
    case $? in
      0) return 0 ;;
      2) if [ -n "$MC_ONLY_KEYS" ] && command -v mc_proj_takeback_full >/dev/null 2>&1; then
           mc_proj_takeback_full "$P"; return 0
         fi ;;
      4) if command -v mc_proj_takeback_keyed >/dev/null 2>&1; then
           mc_proj_takeback_keyed "$P" "${MC_PROJ_TAKEBACK_KEYS:-}"; return 0
         fi ;;
    esac
  fi
  # <<< project on a machine
  local T0; T0=$(mc_now)
  # ---- the per-project cadence hold (BH-1486) -------------------------------
  # The cron fires every five minutes for the whole fleet; this is how ONE
  # project asks for a longer effective cadence without a code deploy. A
  # project whose last REAL tick started less than MC_TICK_SECS ago is held
  # here — above use_token, above the PR list, above every GitHub read — and
  # says so once. The knob is a settings row per project
  # (`lane.merge-conductor.<project>.mc_tick_secs`, or the fleet-wide
  # `lane.merge-conductor.mc_tick_secs`); its default is 0, which means "tick
  # on every cron fire", which is exactly what this lane does today.
  #
  # NO METRICS LINE ON A HOLD, and that is load-bearing rather than tidy:
  # mc_tick_metrics rewrites tick-<p>.json, `started_at` is what the age above
  # is measured from, and a hold that stamped it would hold the project for
  # ever. hb_tick has already run, so the heartbeat and lane-reaper still see a
  # live lane.
  local TICK_SECS LAST_T0
  TICK_SECS=$(tick_secs_for "$P")
  if [ "$TICK_SECS" -gt 0 ]; then
    LAST_T0=$(jq -r '.started_at // 0' "$MC_STATE_DIR/tick-$(mc_safe_name "$P").json" 2>/dev/null)
    case "$LAST_T0" in ''|*[!0-9]*) LAST_T0=0 ;; esac
    # A missing or unparseable row means 0, which means the project TICKS: the
    # fail-open answer, the same rule main_red_flag takes.
    if [ "$LAST_T0" -gt 0 ] && [ $((T0 - LAST_T0)) -lt "$TICK_SECS" ]; then
      mc_log "$(pause_label "$P")TICK $P held: its last tick started $((T0 - LAST_T0))s ago and mc_tick_secs=$TICK_SECS (lane.merge-conductor.$P.mc_tick_secs, or the fleet row) — this cron fire is skipped before any GitHub read (decision=held)"
      return 0
    fi
  fi
  # A PROJECT MERGES PAUSE (BH-1672): MERGES=0 for this project only (a fleet
  # row matches here as well, so the fleet case is enforced twice). This
  # function runs in the project's own backgrounded subshell, so the change
  # never reaches another project, and every pr_worker forked below inherits
  # it. MODE follows, exactly as the fleet case derives it; KILL is untouched.
  if pause_active "$P" merges; then
    MERGES=0; [ "$MODE" = merge ] && MODE=actions
  fi
  # THIS BOARD'S AUTO-MERGE TOGGLE (#2322), flags/automerge-disabled-<project>:
  # the same effect as a project merges pause, in the same subshell. The fleet
  # switch (automerge-disabled) is still KILL, read once at the top.
  if flag_on "automerge-disabled-$P"; then
    MERGES=0; [ "$MODE" = merge ] && MODE=actions
  fi
  SLUG=$("$H/bin/fleet-conf.sh" "$P" repo 2>/dev/null); [ -n "$SLUG" ] && [ "$SLUG" != "-" ] || return 0
  use_token "$SLUG" || { mc_tick_metrics "$P" "$T0"; return 0; }
  TIGHT=0; command -v review_tighten_active >/dev/null 2>&1 && review_tighten_active "$SLUG" && TIGHT=1
  # Does this repo's main sit behind a merge queue, and WHOSE? One cached probe
  # per repo per tick; everything below branches on the answer. `github` is
  # GitHub's native queue (a merge_queue ruleset rule), `mergify` is the Mergify
  # App reading .mergify.yml, `none` is today's synchronous path.
  PROVIDER=$(mc_queue_provider "$SLUG")
  command -v msf_eligible >/dev/null 2>&1 && msf_sweep "$SLUG"
  # AN UNREADABLE PROBE HOLDS THE TICK (BH-2275). `unknown` is not `none`: a
  # 5xx on .mergify.yml used to read as "no queue", and every READY PR on a
  # Mergify repo was merged directly around it. Nothing on this repo moves this
  # tick, ONE alert per repo per day says why, and the next tick probes again.
  if [ "$PROVIDER" = unknown ]; then
    mc_log "$SLUG merge-queue provider UNKNOWN this tick: the .mergify.yml probe could not be read — nothing merged or enqueued on $P; the next tick asks again (BH-2275)"
    mc_queue_unknown_alert "$SLUG" "the .mergify.yml probe could not be read" >/dev/null 2>&1 || true
    mc_tick_metrics "$P" "$T0"; return 0
  fi
  QUEUE=0; [ "$PROVIDER" != none ] && QUEUE=1
  # The branch this project's PRs are supposed to merge into. Any OPEN PR whose
  # base is something else is a STACKED child (2026-09-14) — see the block in
  # the open pass below and docs/MERGE-CONDUCTOR.md section 3.
  PBASE=$(mc_project_base "$P")
  # BH-7241: the CI-never-started window, read once per project per tick.
  MST_NOSTART_MIN=""
  if command -v mst_nostart_min >/dev/null 2>&1; then MST_NOSTART_MIN=$(mst_nostart_min "$P"); mst_prune; fi
  # ---- did this project's base MOVE since the last completed fan-out? ------
  # (BH-870) One authenticated ls-remote per project per tick, no gh budget.
  # The sha is the trigger and the state file is what makes it fire once: a
  # restart, a second overlapping tick or a crash mid-fan-out must not re-offer
  # a rebase for a sha every PR already answered.
  #   unreadable  nothing fires and the recorded sha stands. "Could not tell"
  #               is never read as "main has not moved" — that would silently
  #               skip the landing the outage straddled.
  #   no record   BASELINE. The first tick after a rollout records the sha and
  #               fans out nothing: seven repos each offering every open PR a
  #               rebase on the same */5 is the wrong first event.
  #   changed     LAND_FIRE=1, and every pr_worker below reads it.
  # LAND_SHA and LAND_FIRE are plain variables of this function; the workers are
  # its background subshells and inherit them, exactly as they do PBASE and SLUG.
  # ONE digest of the scanner per project per tick (BH-1486 follow-up), read by
  # every pr_worker of this project as a plain inherited variable, exactly as
  # PBASE and LAND_SHA are. It is a component of the scan memo's key, so a check
  # deployed to the hub invalidates every stored scan on the next tick.
  MC_SCANNER_FP=$(scanner_fp)
  LAND_SHA=""; LAND_PREV=""; LAND_FIRE=0
  if [ "${MC_LAND_REBASE:-1}" != 0 ] && [ -z "$MC_ONLY_KEYS" ]; then
    LAND_SHA=$(mc_land_main_sha "$SLUG" "$PBASE") || LAND_SHA=""
    LAND_PREV=$(mc_land_prev "$P")
    if [ -z "$LAND_SHA" ]; then
      mc_log "$SLUG LAND: $PBASE sha unreadable this tick — no land rebase; the recorded sha (${LAND_PREV:-none}) stands"
    elif [ -z "$LAND_PREV" ]; then
      mc_land_record "$P" "$LAND_SHA"
      mc_log "$SLUG LAND baseline $PBASE ${LAND_SHA:0:8} recorded — the first tick after rollout fires no fan-out"
    elif [ "$LAND_PREV" != "$LAND_SHA" ]; then
      LAND_FIRE=1
      mc_log "$SLUG LAND $PBASE moved ${LAND_PREV:0:8} -> ${LAND_SHA:0:8} — every open $PBASE-based PR of $P is offered a rebase this tick"
    fi
  fi
  # Is this repo's main red? One flag read per project per tick; while it is on,
  # the READY arm below merges nothing here except the two exceptions.
  MAIN_RED=""; MAIN_RED_WHY=""
  if command -v main_red_flag >/dev/null 2>&1 && MAIN_RED=$(main_red_flag "$P" "$SLUG"); then
    MAIN_RED_WHY=$(head -c 200 "$H/flags/$MAIN_RED" 2>/dev/null | tr '\n' ' ')
    mc_log "$SLUG MAIN_RED_FREEZE in force (flags/$MAIN_RED${MAIN_RED_WHY:+: $MAIN_RED_WHY}) — nothing merges in this repo until the flag is gone, except a PR labelled $MC_MAIN_RED_LABEL or one whose whole diff is test files ($MC_MAIN_RED_TEST_PATHS)"
  else
    MAIN_RED=""
  fi

  # GitHub API budget guard: the closed-list settle pass is non-essential and
  # skips when the shared budget is low; merge-queue settle and open-PR passes
  # continue because they drive the conductor's core work.
  MC_BUDGET_LOW=0
  if command -v gh_budget_low >/dev/null 2>&1 && gh_budget_low merge-conductor >/dev/null 2>&1; then
    MC_BUDGET_LOW=1
    mc_log "budget low — closed-list settle pass skipped this tick"
  fi

  # ---- settle the merge queue --------------------------------------------------
  # A PR GitHub merges OUT OF ITS QUEUE disappears from the open list (merged)
  # and from the closed list (which selects mergedAt == null), so the open pass
  # below would never see it land and NOTHING the landing owes would ever run —
  # no issue close, no deploy train, no merge_sha. The rows this repo left in
  # QUEUED are therefore read here, FIRST, and each one is settled, ejected, or
  # left where it is. It runs before the open pass so an ejected PR is already
  # out of READY by the time the classifier gets to it.
  # NEVER ON A LANE-RUN MACHINE (BH-6495). This pass reads EVERY QUEUED row of
  # the repo, not only MC_ONLY_PR's, and a settle is a landing: the issue close,
  # the deployreq ledger row and the deploy-verify the machine cannot spawn.
  # The hub runs this pass on every tick, so it owns each settle and ejection.
  # A lease-held project run (BH-6890) runs it: it is the only conductor of
  # the repo for the tick. Its settle still defers (deferred=settle), and the
  # hub's next tick of the project settles it.
  if [ "$QUEUE" = 1 ] && { [ "${MC_ON_MACHINE:-}" != 1 ] || { [ "${MC_LEASED_RUN:-}" = 1 ] && [ -n "${MC_LEASE_FENCE:-}" ]; }; }; then
    mapfile -t QROWS < <(awk -F'\t' -v p="$SLUG#" '$2=="QUEUED" && index($1,p)==1' "$MC_ROWS" 2>/dev/null)
    # BH-8457: the open list (one list read, shared with the open pass under
    # the snapshot) answers state, branch and head for a row still open at its
    # QUEUED head; mc_queue_state below still reads that PR live once.
    QOPEN=""; [ -n "${QROWS[0]:-}" ] && QOPEN=$(mc_queued_open_heads "$SLUG")
    for QROW in "${QROWS[@]:-}"; do
      [ -n "$QROW" ] || continue
      IFS=$'\t' read -r QKEY QST QSINCE QHEAD QREV QAL QWHY QURL <<<"$QROW"
      [ -n "$QURL" ] || continue
      # UNDER THAT PR'S LOCK, like every other piece of per-PR work. It stays
      # sequential — a repo has a handful of QUEUED rows at a time and each one
      # is two gh reads — but it must not settle a PR an open-pass worker of an
      # overlapping tick is already handling.
      QLK="$(mc_pr_lock "$P" "${QKEY##*#}")"
      exec 9>"$QLK"
      flock -n 9 || { exec 9>&-; mc_count_inc "$P" locked >/dev/null
        mc_log "$QKEY: another conductor worker holds this PR's lock — its queue settle waits for the next tick"; continue; }
      # The PR's own state first (it is the same read for both providers and it
      # carries the branch the issue close needs), then, only for a PR that is
      # still OPEN, the provider-aware question "does the queue still hold it".
      QV=$(mc_queued_list_view "$QOPEN" "${QKEY##*#}" "$QHEAD") \
        || QV=$(mc_pr_view "$QURL" '"\(.STATE) \(.head.ref) \(.head.sha // "")"' 2>/dev/null) || QV=""
      read -r QPS QBR QLIVE <<<"$QV"
      [ -n "${QPS:-}" ] || { mc_log "$QKEY still QUEUED: GitHub read UNVERIFIABLE (HTTP $(mc_rest_status)) — row left as-is"; continue; }
      QREC=$(mc_record_for "$QURL" || true)
      # Five fields, not four: mc_verdict's 5th is the head-bound outcome. It is
      # unused on the settle path (a PR that already reached the queue was bound
      # to its head long ago), but it must be READ, or the tab would ride into
      # QJOB and conductor_settle would be handed "<job>\t<outcome>" as a job id.
      IFS=$'\t' read -r QVERDICT QPROV QREVIEWED QJOB QHEADBOUND <<<"$(mc_verdict "$QURL" "$QREC")"
      case "$QPS" in
        MERGED)
          conductor_settle "$QKEY" "$QURL" "$P" "$SLUG" "${QBR:-}" "$QREC" "$QJOB" "$QHEAD" "$QREV" "$QVERDICT" CLEAN "by:conductor (merge queue)" ;;
        CLOSED)
          mc_transition "$QKEY" CLOSED "closed while in the merge queue" "$QHEAD" "$QREV" "$QURL" "$QVERDICT" "-" "$QREC" >/dev/null ;;
        OPEN)
          # A LEAD CR ON A QUEUED PR TAKES IT OUT (BH-2275). .mergify.yml's
          # #changes-requested-reviews-by=0 already stops the batch merging it;
          # this removes our label and posts `@mergifyio dequeue`, once per (PR,
          # head, review), and hands the row back to READY, where the block gate
          # refuses it until the reviewer clears it. One reviews read per queued
          # PR per tick, Mergify repos only.
          if [ "$PROVIDER" = mergify ] && { mc_attempt_has "crdequeue $QKEY $QHEAD" 2>/dev/null \
               || mc_cr_dequeue "$SLUG" "$QKEY" "$QURL" "$QHEAD" "$MERGES"; }; then
            mc_transition "$QKEY" READY "dequeued: a standing CHANGES_REQUESTED (lead/human BLOCK) — the block gate holds it" "$QHEAD" "$QREV" "$QURL" "$QVERDICT" UNKNOWN "$QREC" >/dev/null
            continue
          fi
          QS=$(mc_queue_state "$QURL" "$QHEAD")
          [ "$QS" = queued ] && continue
          # An API outage is not an ejection. Leave the row where it is and say
          # so: inventing an ejection out of a 500 would cost the PR its place
          # in the queue and count a strike against it.
          [ "$QS" = unknown ] && { mc_log "$QKEY still QUEUED: the queue provider ($PROVIDER) could not be read this tick"; continue; }
          # >>> queue left confirm (BH-4562)
          # A PR THAT LEFT THE QUEUE MERGED IS NOT AN EJECTION. `merged` from the
          # queue read is a landing between our two reads (both providers). On
          # Mergify, ask why it left before anything is counted: Mergify drops its
          # labels and moves its check before GitHub sets merged_at, and #4142 was
          # parked BLOCKED_HUMAN one second before it merged. No-witness is held
          # one tick per head; a stated reason ejects exactly as below.
          QLW=ejected
          if [ "$QS" = merged ]; then QLW=merged
          elif [ "$PROVIDER" = mergify ]; then QLW=$(mc_queue_left_why "$SLUG" "$QURL" "$QHEAD")
          fi
          case "$QLW" in
            merged)
              mc_log "$QKEY left the merge queue MERGED on ${QHEAD:0:8} (not an ejection) — settled (BH-4562)"
              conductor_settle "$QKEY" "$QURL" "$P" "$SLUG" "${QBR:-}" "$QREC" "$QJOB" "$QHEAD" "$QREV" "$QVERDICT" CLEAN "by:conductor (merge queue)"
              exec 9>&-; continue ;;
            merging)
              mc_log "$QKEY still QUEUED: Mergify's check says merged on ${QHEAD:0:8} but GitHub has no merged_at yet — no ejection; the next tick settles it (BH-4562)"
              exec 9>&-; continue ;;
            unknown)
              mc_log "$QKEY still QUEUED: the dequeue could not be confirmed this tick (PR or check read failed) — no ejection counted (BH-4562)"
              exec 9>&-; continue ;;
            nowitness)
              if ! mc_attempt_has "qgone $QKEY $QHEAD" 2>/dev/null; then
                mc_attempt_put "qgone $QKEY $QHEAD"
                mc_log "$QKEY left the merge queue on ${QHEAD:0:8} with no stated reason and not merged — held one tick before it counts as an ejection (BH-4562)"
                exec 9>&-; continue
              fi ;;   # second sighting of the same head: today's ejection below
          esac
          # <<< queue left confirm
          # OPEN, not merged, and the queue no longer holds it = EJECTED. Under
          # the native queue that means its merge_group build (main + the entries
          # ahead of it + this PR) went red; under Mergify, that its batch failed
          # and Mergify removed the culprit. Either way it is a CI fact about a
          # tree the PR's own checks never saw, so it goes back to WAIT_CI rather
          # than to a human — but it is COUNTED, because a PR that keeps being
          # ejected is a human's problem and re-enqueueing it forever is the
          # exact loop this replaces.
          mc_attempt_has "ejected $QKEY $QHEAD" || mc_attempt_put "ejected $QKEY $QHEAD"
          # The failure follows the PATCH, not only the sha (BH-8186): a rebase of
          # this head must not come back READY with no failure on it.
          [ "$PROVIDER" = mergify ] && command -v mc_fbh_record >/dev/null 2>&1 && mc_fbh_record "$SLUG" "$P" "$QKEY" "$QURL" "$QHEAD"
          # EJECTED AGAIN AFTER WE PUT IT BACK (BH-636). The `ejected` line is
          # already there from the first time, so without this the second
          # ejection of the SAME head would be invisible and the re-entry arm
          # would offer it to the queue for ever. One more line, counted with
          # the first, which is what hands it to bin/blocked-resolver.sh on
          # `queue-ejected-twice` instead.
          if [ -n "$(mc_requeued_mark "$QKEY" "$QHEAD")" ]; then
            mc_attempt_has "reejected $QKEY $QHEAD" || mc_attempt_put "reejected $QKEY $QHEAD"
          fi
          # This tick made this ejection, so this tick does not undo it.
          mc_tick_eject_note "$P" "$QKEY" "$QHEAD"
          # A BASE-CONFLICT EJECTION IS NOT A STRIKE (BH-1677). Main moved under
          # the PR; the answer is a rebase, not the resolver. Marked before the
          # count reads the file. Mergify only: the native queue has no dequeue
          # comment to read (see the dequeue surface below).
          [ "$PROVIDER" = mergify ] && mc_eject_conflict_note "$SLUG" "$QKEY" "$QURL" "$QHEAD"
          EJN=$(mc_eject_head_strikes "$QKEY" "$QHEAD")
          # Mergify does not take OUR trigger label off — its own signal is the
          # check run and its own `dequeued` label — so a label left behind would
          # read as "queued" on every later tick and the PR would never be
          # reclassified. Take it back so the next enqueue is a fresh signal.
          # It is a gh WRITE, so it happens only in merge mode, exactly like the
          # enqueue it undoes.
          [ "$MERGES" = 1 ] && { mc_dequeue_label "$QURL" \
            && mc_log "$QKEY ejected — removed the $MC_MERGIFY_LABEL label" \
            || mc_log "$QKEY ejected but the $MC_MERGIFY_LABEL label could not be removed — the next tick reads it as queued until it goes (gh pr edit --remove-label $MC_MERGIFY_LABEL)"; }  # gh-guard-allow: prose in a log line, not a call
          # >>> dequeue surface
          # WHY IT LEFT, not just that it left (BH-872). The arms below call
          # every Mergify ejection a red batch, and most are. The one that is
          # not is a standing changes-requested review: it makes Mergify's
          # `github-review-approved` condition false, Mergify drops the PR, and
          # the requeue arm then waits for a CLEAN merge state that same review
          # denies. Only mergify answers this question — the native queue ejects
          # on its merge_group build and has no dequeue comment to read — so the
          # read is spent nowhere else. One comment and one beat per (PR, head).
          if [ "$PROVIDER" = mergify ]; then
            QDQ=$(mc_dequeue_reason "$SLUG" "$QURL" "$QHEAD")
            [ -n "$QDQ" ] && mc_dequeue_surface "$QKEY" "$QURL" "$QHEAD" "$QDQ" "$MERGES"
          fi
          # <<< dequeue surface
          # WHAT THE CAUSE WAS (BH-6161): one comments read, one record line, one
          # EJECT_CAUSE line, and the cause in the row reason below.
          QEC=""; QEWHY=""
          if command -v ec_cause >/dev/null 2>&1 && [ "$(ec_knob MC_EJECT_CAUSE 1)" != 0 ]; then
            QEC=$(ec_cause "$PROVIDER" "$SLUG" "$QURL" "$QHEAD" "${QLIVE:-}")
            QORD=first; [ -n "$(mc_requeued_mark "$QKEY" "$QHEAD")" ] && QORD=again
            ec_record "$SLUG" "${QKEY##*#}" "$QHEAD" "$QORD" "${QEC%%$'\t'*}" "${QEC#*$'\t'}"
            QEWHY="${QEC%%$'\t'*}"; [ -n "${QEC#*$'\t'}" ] && QEWHY="$QEWHY (${QEC#*$'\t'})"
            mc_log "EJECT_CAUSE $QKEY ${QHEAD:0:8} $QORD $QEWHY"
          fi
          if [ "${EJN:-1}" -ge 2 ]; then
            mc_log "$QKEY EJECTED from the merge queue again on ${QHEAD:0:8} (ejections: $EJN, provider $PROVIDER)"
            mc_transition "$QKEY" BLOCKED_HUMAN "queue-ejected-twice${QEWHY:+: $(ec_summary "$SLUG" "${QKEY##*#}")}" "$QHEAD" "$QREV" "$QURL" "$QVERDICT" UNKNOWN "$QREC" >/dev/null
            mc_log "$QKEY BLOCKED_AGENT queue-ejected-twice — its batch build fails against current main, which its own checks never test; handed to bin/blocked-resolver.sh (its ladder: an agent fix round with the failing batch runs when they could be read, else merge main / re-run CI first; then a fresh rebuild): $QURL"
            # BH-6000 part 5: the fix round starts now, with the two failing runs.
            mc_eject_fix_now "$P" "$SLUG" "$QKEY" "$QHEAD" "$QURL"
          else
            mc_log "$QKEY ejected from the merge queue on ${QHEAD:0:8} — cause: ${QEWHY:-not read (MC_EJECT_CAUSE=0)} (provider $PROVIDER)"
            mc_transition "$QKEY" WAIT_CI "queue-ejected${QEWHY:+: $QEWHY}" "$QHEAD" "$QREV" "$QURL" "$QVERDICT" UNKNOWN "$QREC" >/dev/null
          fi ;;
      esac
      exec 9>&-
    done
    # And once more after the loop: the arms above `continue` on a queue the
    # provider could not read, and a fd left open here would still be holding
    # that PR's lock when the open pass forks its worker for the same PR.
    exec 9>&-
    # >>> parked merged settle (BH-4562)
    # A ROW THE DEQUEUE RACE ALREADY PARKED IS SETTLED ONCE GITHUB SAYS MERGED.
    # Nothing else reads it: the open pass does not list a merged PR, the loop
    # above reads QUEUED rows only, and the closed pass memos `merged` and moves
    # on. One ETag-cached read per parked-queue row; OPEN, CLOSED or unreadable
    # leaves the row to its owner (the resolver, the closed pass).
    mapfile -t PROWS < <(awk -F'\t' -v p="$SLUG#" 'index($1,p)==1 && (($2=="BLOCKED_HUMAN" && $7 ~ /^queue-ejected-twice/) || ($2=="WAIT_CI" && $7 ~ /^queue-ejected/))' "$MC_ROWS" 2>/dev/null)
    for QROW in "${PROWS[@]:-}"; do
      [ -n "$QROW" ] || continue
      IFS=$'\t' read -r QKEY QST QSINCE QHEAD QREV QAL QWHY QURL <<<"$QROW"
      [ -n "$QURL" ] || continue
      mc_only_has "$QKEY" || continue
      exec 9>"$(mc_pr_lock "$P" "${QKEY##*#}")"
      flock -n 9 || { exec 9>&-; mc_log "$QKEY: another conductor worker holds this PR's lock — the parked-merged check waits for the next tick"; continue; }
      QV=$(mc_pr_view "$QURL" '"\(.STATE) \(.head.ref)"' 2>/dev/null) || QV=""
      read -r QPS QBR <<<"$QV"
      if [ "${QPS:-}" = MERGED ]; then
        QREC=$(mc_record_for "$QURL" || true)
        IFS=$'\t' read -r QVERDICT QPROV QREVIEWED QJOB QHEADBOUND <<<"$(mc_verdict "$QURL" "$QREC")"
        mc_log "$QKEY was parked $QST ($QWHY) but GitHub reports it MERGED — settled from the dequeue park (BH-4562)"
        conductor_settle "$QKEY" "$QURL" "$P" "$SLUG" "${QBR:-}" "$QREC" "$QJOB" "$QHEAD" "$QREV" "$QVERDICT" CLEAN "by:conductor (merge queue, settled from a dequeue park — BH-4562)"
        mc_handoff_release "$QKEY" merged
      elif [ "${QPS:-}" = OPEN ] && [ "$QST" = BLOCKED_HUMAN ]; then
        # BH-6000 part 5: a queue-ejected-twice park whose hand-over could not
        # read the dequeue comments is asked again here, once a tick, until it
        # is stamped (mc_eject_fix_now returns at once for a stamped head).
        case "$QWHY" in queue-ejected-twice*) mc_eject_fix_now "$P" "$SLUG" "$QKEY" "$QHEAD" "$QURL" ;; esac
      fi
      exec 9>&-
    done
    exec 9>&-
    # <<< parked merged settle
  fi

  # ---- a Mergify batch draft that sits green (BH-1790) ------------------------
  # Mergify sometimes misses a check's completion event and leaves a batch draft
  # green and unmerged, which stalls the whole queue behind it. One list read
  # per Mergify repo per tick; mc_mergify_stuck_pass posts `@mergifyio refresh`
  # on a draft green for MC_MERGIFY_STUCK_SECS, once per window. The comment
  # makes the queue MERGE, so it is written in merge mode only, like the
  # enqueue label; every other mode logs what it would post.
  if [ "$PROVIDER" = mergify ] && [ -z "$MC_ONLY_KEYS" ]; then
    mc_mergify_stuck_pass "$P" "$SLUG" "$MERGES"
    # BH-5372: one BATCH_RESET line per batch draft main moved under; a log line
    # and a mark only, so it runs in every mode. A failed read is one line.
    if command -v bres_tick >/dev/null 2>&1; then
      BRC=0; bres_tick "$SLUG" || BRC=$?
      [ "$BRC" = 0 ] || mc_log "$SLUG BATCH_RESET_UNREAD rc=$BRC — closed batch drafts not classified this tick"
    fi
    # BH-5374: the minutes each finished draft spent, after bres_tick logged its resets.
    command -v bmin_tick >/dev/null 2>&1 && { bmin_tick "$SLUG" || mc_log "$SLUG QUEUE_MINUTES_UNREAD rc=$? — batch minutes not recorded this tick"; }
    # BH-7290: the `full` label comes off each open member after one completed batch.
    command -v fle_tick >/dev/null 2>&1 && { fle_tick "$SLUG" "$MERGES" || mc_log "$SLUG FULL_LABEL_EXPIRY_UNREAD rc=$? — the full label was not checked this tick"; }
  fi

  # ---- open PRs ---------------------------------------------------------------
  # isInMergeQueue is requested in the list because mergeStateStatus has no
  # QUEUED value. gh's --json allowlist is a separate thing from the GraphQL
  # type, so a refusal must not blind the whole tick: the list is retried
  # without the field and the flag is then read per PR (mc_inqueue).
  # `labels` rides along because it is the Mergify provider's queue witness, and
  # in the LIST it costs nothing: the open pass then knows "is this PR queued"
  # for every PR on the repo without one extra call each.
  # THE FIELD IS ASKED FOR ONLY WHERE IT CAN BE USED AND ONLY WHILE gh TAKES IT
  # (2026-09-15): never on a repo with no queue, and never at all while the
  # refusal marker is fresh. A refusal is recorded ONCE — and only when the
  # plain list then succeeded, which is what proves the field was the problem
  # rather than the repo.
  # ONE PR PER TICKET (BH-1526), before the list this tick works from, so a
  # duplicate it closes is simply absent from that list. A lead PR always wins.
  # A CLOSE IS A WRITE, so it obeys ACTIONS like every other write here: in
  # observe mode and under the kill switch it only says what it would close.
  # AND IT IS OPT-IN PER PROJECT (MC_TICKET_DEDUPE, default 0): a project whose
  # row is not 1 is not listed, not logged about, not touched.
  if command -v to_dedupe_open_prs >/dev/null 2>&1 && [ "$(ticket_dedupe_for "$P")" = 1 ]; then
    if [ "$ACTIONS" = 1 ]; then to_dedupe_open_prs "$SLUG"; else TO_DEDUPE_DRY=1 to_dedupe_open_prs "$SLUG"; fi
  fi
  INQ_IN_LIST=0; LIST=""; INQ_ASKED=0
  # BH-1585: isInMergeQueue is one GraphQL mergeQueue read per list
  # (bin/lib/gh-pr-list.sh), so it is asked only where it is read — GitHub's
  # NATIVE queue. A Mergify repo's witness is its labels, which ride the list.
  INQ_RC=0
  if [ "$QUEUE" = 1 ] && [ "$PROVIDER" = github ] && inq_list_ok "$SLUG"; then
    INQ_ASKED=1
    LIST=$(mc_lazy_scoped "$SLUG" harness_pr_list "$SLUG" open number,url,headRefOid,headRefName,baseRefName,isDraft,mergeStateStatus,mergeable,state,labels,isInMergeQueue,updatedAt,isCrossRepository 100 2>/dev/null) || INQ_RC=$?
    [ -n "$LIST" ] && { INQ_IN_LIST=1; rm -f "$(inq_mark "$SLUG")" 2>/dev/null; }
  fi
  if [ "$INQ_IN_LIST" = 0 ]; then
    LIST=$(mc_lazy_scoped "$SLUG" harness_pr_list "$SLUG" open number,url,headRefOid,headRefName,baseRefName,isDraft,mergeStateStatus,mergeable,state,labels,updatedAt,isCrossRepository 100 2>/dev/null) || {
      command -v gh_repo_list_failed >/dev/null 2>&1 && gh_repo_list_failed merge-conductor "$SLUG" "$P: PR list failed this tick"; reset_token; mc_tick_metrics "$P" "$T0"; return 0; }
    [ -n "$LIST" ] || { command -v gh_repo_list_failed >/dev/null 2>&1 && gh_repo_list_failed merge-conductor "$SLUG" "$P: PR list failed this tick"; reset_token; mc_tick_metrics "$P" "$T0"; return 0; }
    # REMEMBERED ONLY WHEN IT WAS A REFUSAL (rc 65: GitHub answered the
    # mergeQueue query with errors). A read that did not complete (44/75) says
    # nothing about the repo: the witness is off for THIS tick and the next tick
    # asks again. Remembering a blip used to switch it off for 24h.
    if [ "$INQ_ASKED" = 1 ] && [ "$INQ_RC" = 65 ]; then
      date -u +%s > "$(inq_mark "$SLUG")" 2>/dev/null
      mc_log "$SLUG: gh refused --json isInMergeQueue (the mergeQueue read was refused) — remembered for $((MC_INQUEUE_PROBE_TTL_SECS/3600))h for this repo ($(inq_mark "$SLUG")), so no later tick asks again; the field is read per PR only where the merge state is one of: $MC_INQUEUE_STATES"
    elif [ "$INQ_ASKED" = 1 ]; then
      mc_log "$SLUG: mergeQueue read unverifiable (rc $INQ_RC) — isInMergeQueue is not in the list this tick only; nothing remembered, the next tick asks again"
    fi
  fi
  # THE LIST WORKED, so whatever blind streak this lane was carrying on this repo
  # is over (BH-847). This is the only lane that closes a streak, and it is the
  # right one: the conductor is what enqueues PRs, so its blindness is the one
  # that stops work. Guarded because merge-conductor-lib.sh is sourced standalone
  # by fixtures that never load bin/lib/gh-repo-token.sh.
  command -v gh_repo_list_ok >/dev/null 2>&1 && gh_repo_list_ok merge-conductor "$SLUG"
  # The list is read into an array FIRST: gh, agent-call and npm inside the loop
  # must never eat the loop's own stdin.
  # baseRefName rides the list (2026-09-14): "is this PR stacked on another PR's
  # branch" is one string comparison, and asking it per PR would be one extra
  # API call each. It is APPENDED to the tsv, never inserted, so the positional
  # read below keeps every existing field where it was.
  #
  # EVERY COLUMN EMITS A `-` RATHER THAN AN EMPTY STRING, and that is a
  # correctness requirement, not tidiness (2026-09-14, project-5 #868/#885/
  # #848/#850/#852). `IFS=$'\t' read` collapses runs of delimiters, because TAB
  # is an IFS WHITESPACE character in bash — so a PR with no labels emitted
  # `…\tfalse\t\tticket/TK-763` and the read slid baseRefName into RAWLBL and
  # left BASEREF EMPTY. The stacked-child block below tests `[ -n "$BASEREF" ]`,
  # so it never fired on a single PR: #868 sat WAIT_CI for an hour after its
  # parent merged (no retarget) and #848/#850/#852 were never parked
  # STACKED_WAIT at all. Harness PRs carry no labels on any repo without
  # Mergify, which is why this bit every one of them.
  #
  # `updatedAt` IS THE 12TH COLUMN AND IT COSTS NOTHING (BH-1486). It is a
  # `gh pr list --json` field and a mappable REST one, so it rides the list
  # read this tick already makes — and it is the other half of the read memo's
  # key: a PR whose head sha AND updated_at are both where they were is a PR
  # whose diff and terminal CI answer this tick already knows. A list that does
  # not carry it emits `-`, which read_memo_get treats as UNKNOWN and therefore
  # as "memo off" — absent is not unchanged (D11).
  #
  # `isCrossRepository` IS THE 13TH (BH-1529), and it is spelled out rather
  # than `// "-"` because `false // x` is x in jq: a same-repo PR would read as
  # unknown. The head-lag check acts only on a literal `false`, so a list that
  # does not carry it (or a deleted fork) is never read as "same repo".
  mapfile -t ROWS < <(printf '%s' "$LIST" | jq -r '.[] | [.number, .url, .headRefOid, .headRefName, (.isDraft|tostring), (.mergeStateStatus // "UNKNOWN"), (.mergeable // "UNKNOWN"), .state, ((.isInMergeQueue // false)|tostring), ((((.labels // []) | map(.name) | join(",")) // "") | if . == "" then "-" else . end), ((.baseRefName // "") | if . == "" then "-" else . end), ((.updatedAt // "") | if . == "" then "-" else . end), (if .isCrossRepository == null then "-" else (.isCrossRepository|tostring) end)] | @tsv' 2>/dev/null)
  # Every PR the open list shows gets a closed-watch memo (BH-1592), and the
  # closed-unmerged settle below skips the numbers that are open this tick.
  closed_watch_seen "$SLUG" "${ROWS[@]}"
  OPEN_NUMS=$(printf '%s\n' "${ROWS[@]}" | cut -f1 | tr '\n' ' ')
  # BH-1606: the MERGE_HELD dedupe files of this repo's closed PRs go, off the
  # same open numbers (a PR the list does not carry is asked once first).
  # A keyed tick (BH-1387) skips it: the prune is a repo sweep, the cron tick's.
  # shellcheck disable=SC2086  # one PR number per word, on purpose
  [ -z "$MC_ONLY_KEYS" ] && command -v to_held_prune >/dev/null 2>&1 && to_held_prune "$SLUG" $OPEN_NUMS
  if [ -n "$MC_ONLY_KEYS" ]; then # keyed tick: only the woken PRs
    local _kr=() _r; for _r in "${ROWS[@]}"; do mc_only_has "$SLUG#${_r%%$'\t'*}" && _kr+=("$_r"); done; ROWS=("${_kr[@]}")
    # A key bin/pr-owner-sweep.sh enrolled whose author the list filters out (BH-3933).
    mc_enroll_external_load
    mapfile -t -O "${#ROWS[@]}" ROWS < <(mc_enrolled_rows "$SLUG" "$OPEN_NUMS")
  fi
  # ---- the hotfix lane heads the order (BH-369) ------------------------------
  # A PR carrying the hotfix label is launched before every plain PR of this
  # repo AND is written into this tick's marker before the first worker starts,
  # which is what the degraded direct merge in pr_worker reads. Launch order
  # alone would not be enough: the workers are background subshells, so the
  # marker is the part that actually orders the merges.
  #
  # THE ORDER IS FOR EVERY REPO; THE MARKER IS FOR QUEUE REPOS (BH-645). This
  # block was `QUEUE=1` whole, which was right for the marker and wrong for the
  # order: a repo with no merge queue at all — PROVIDER none, most of the fleet
  # — worked its PRs in whatever order GitHub listed them, which is the state
  # this lane exists to remove. So the classification and the reorder run
  # wherever there are rows, and hotfix_pending_write (the degraded-merge
  # marker that a plain PR reads before bypassing a silent queue) stays inside
  # its own QUEUE=1 guard, semantics untouched. While the queue IS answering,
  # Mergify's own hotfix queue does the ordering and this costs one label read
  # per PR and changes nothing else.
  if [ "${#ROWS[@]}" -gt 0 ]; then
    HOTROWS=(); PLAINROWS=(); HOTNUMS=()
    for ROW in "${ROWS[@]}"; do
      [ -n "$ROW" ] || continue
      IFS=$'\t' read -r HNUM HURL _ _ HDRAFT _ _ _ _ HLBL _ <<<"$ROW"
      # The list row's labels first (a `-` there means none, and hotfix-lib
      # reads it as none); the build record's ticket-meta.json is the fallback
      # for a harness PR built before the PR label existed.
      if [ -n "$HNUM" ] && [ "$HDRAFT" != true ] \
         && hotfix_pr_is "$HLBL" "$(mc_record_for "$HURL" 2>/dev/null || true)"; then
        HOTROWS+=("$ROW"); HOTNUMS+=("$HNUM")
        # The tail is queue-only because the wait it describes is queue-only: on
        # a repo with no queue there is no degraded merge to hold back, and a
        # log line that says there is would be describing something that cannot
        # happen.
        HWAIT=""
        [ "$QUEUE" = 1 ] && HWAIT=" and a plain degraded merge waits a tick for it"
        mc_log "$SLUG#$HNUM heads this tick's order — it carries the $(hotfix_label "$H") label, so it is launched before $P's other PRs$HWAIT"
      else
        PLAINROWS+=("$ROW")
      fi
    done
    [ "${#HOTNUMS[@]}" -gt 0 ] && [ "$QUEUE" = 1 ] && hotfix_pending_write "$P" "${HOTNUMS[@]}"
    # READY ROWS COME NEXT (BH-7376): after the hotfix rows, every READY row
    # gets the worker window before any WAIT_CI or HEAD_MOVED row, so the
    # full tick's window never runs out on re-reads while a merge waits.
    command -v mc_ready_first >/dev/null 2>&1 && [ "${#PLAINROWS[@]}" -gt 0 ] \
      && mapfile -t PLAINROWS < <(mc_ready_first "$SLUG" "${PLAINROWS[@]}")
    ROWS=("${HOTROWS[@]}" "${PLAINROWS[@]:-}")
  fi
  # ---- one worker per PR (2026-09-15) ---------------------------------------
  # The list is walked here and the WORK is done in pr_worker, one background
  # subshell per PR under that PR's own lock. N PRs of one repo therefore make
  # progress in the same tick, and the PR that is slow — a rebase result to
  # read, a re-review to dispatch, a merge to settle — holds up nobody but
  # itself. MC_PR_PARALLEL caps how many of them run at once for one project
  # (0 = unlimited, the MC_REREVIEW_PARALLEL/MC_REBASE_PARALLEL convention);
  # a box that wants a ceiling on the whole fleet sets it with the others.
  #
  # FAN-IN (BH-186): every row is enumerated BEFORE the first worker starts, and
  # each worker runs pr_worker in a nested subshell inside fanin_run_sub, which
  # accounts the PR when it comes back, whichever return (or exit) it took. A
  # worker killed outright is what fanin_end names as missing; a tick killed
  # outright is named by the next tick's fanin_begin.
  #
  # EACH WORKER HAS ITS OWN DEADLINE (BH-4918). mc_worker_bounded kills a worker
  # past MC_WORKER_DEADLINE_S on its own, so one slow PR no longer holds the
  # tick, and its siblings and ae_project below, until an outer `timeout` kills
  # them all. MC_FANIN_T0 is the tick's start for mc_fanin_outcome: a ready-why
  # note older than it is not this tick's reason.
  #
  # WHY IT DIED, AND WORKED ALONE (BH-4842). fanin_trap_run stamps a TERM/INT/
  # HUP to this subshell into the ledger (the backstop's `timeout` signals the
  # whole process group), and fanin_run_sub stamps its own worker's signal and
  # the last mc_log line that worker wrote, so the alert says why. A PR missing
  # from fan-in on MC_FANIN_SOLO_AFTER runs in a row (0 = off) is handed to its
  # own keyed run (mc_fanin_solo → kw_conductor), accounted deferred:solo here
  # and dropped from ROWS, so a slow PR can no longer take its siblings' enqueue
  # down with it every fire. Never from a solo run (MC_FANIN_SOLO_RUN=1, set by
  # kw_conductor on the run mc_fanin_solo launches); a one-key run that is not
  # one (a backstop fire, under its `timeout`) does solo. A refused launch keeps
  # the row in this run.
  #
  # THE WINDOW (BH-4842). A backstop fire passes MC_WORKERS_DONE_BY, the epoch
  # by which its workers must be gone. mc_window_cap starts a worker only while
  # 15 s or more are left until then, and caps its deadline to fit; a row it
  # cannot fit is accounted deferred:window and handed back
  # (MC_WINDOW_DEFER_FILE) for the next fire.
  PRPIDS=()
  MC_FANIN_T0=$(mc_now)
  fanin_begin merge-conductor "$SLUG" "$MC_LOG"
  fanin_trap_run
  local SOLO_AFTER="${MC_FANIN_SOLO_AFTER:-2}"; [[ "$SOLO_AFTER" =~ ^[0-9]+$ ]] || SOLO_AFTER=2
  [ "${MC_FANIN_SOLO_RUN:-}" = 1 ] && SOLO_AFTER=0
  local _batch=() _solo=0 _sn
  for ROW in "${ROWS[@]}"; do
    [ -n "$ROW" ] || continue
    fanin_enumerate "$SLUG#${ROW%%$'\t'*}"
    if [ "$SOLO_AFTER" -gt 0 ]; then
      _sn=$(fanin_streak "$SLUG#${ROW%%$'\t'*}")
      if [ "${_sn:-0}" -ge "$SOLO_AFTER" ] && mc_fanin_solo "$SLUG" "${ROW%%$'\t'*}" "$_sn"; then
        fanin_account "$SLUG#${ROW%%$'\t'*}" deferred:solo
        hotfix_pending_is "$P" "${ROW%%$'\t'*}" 2>/dev/null && hotfix_pending_drop "$P" "${ROW%%$'\t'*}"
        _solo=1; continue
      fi
    fi
    _batch+=("$ROW")
  done
  [ "$_solo" = 1 ] && ROWS=("${_batch[@]}")
  # THE REFS PIN (BH-6462): one refs read per branch prefix for the whole tick,
  # before any worker starts, so no worker's head-lag step reads them again.
  local MC_REFS_PIN_PREFIX _pinbr=()
  MC_REFS_PIN_PREFIX="$MC_TICK_DIR/$(mc_safe_name "${MC_TICK_ID:-notick}").refspin-"
  mapfile -t _pinbr < <(printf '%s\n' "${ROWS[@]}" | cut -f4)
  command -v prs_refs_pin >/dev/null 2>&1 && prs_refs_pin "$SLUG" "$MC_REFS_PIN_PREFIX" "${_pinbr[@]}"
  # THE ATTEMPTS READ (BH-4156): one batch read of these PRs' attempt rows.
  command -v mc_tick_prefetch >/dev/null 2>&1 && mc_tick_prefetch "$SLUG" "${ROWS[@]}"
  local _wcap
  # ON A LANE-RUN MACHINE (BH-6495, bin/lib/mc/fly-workers.sh). With the
  # conductor_workers_on_fly switch on, a row is enqueued as one lane_runs row
  # and starts no worker here (mc_fly_arm rc 0); any other answer runs it here
  # as before. A run on a machine (MC_ON_MACHINE=1) never enqueues.
  # Each row's enqueue runs in the background inside the pr_slot_wait bound,
  # like a local worker, so its 2 jobs-worker reads never queue behind the
  # other rows' reads in this loop; the tally comes back through a tick file.
  local _fly=0
  MC_FLY_N_ENQ=0; MC_FLY_N_SKIP=0; MC_FLY_N_FB=0; MC_FLY_COUNT_FILE=""
  [ "${MC_ON_MACHINE:-}" != 1 ] && [ "${#ROWS[@]}" -gt 0 ] && command -v mc_fly_workers_on >/dev/null 2>&1 \
    && mc_fly_workers_on "$P" && _fly=1
  if [ "$_fly" = 1 ]; then
    mkdir -p "$MC_TICK_DIR" 2>/dev/null
    MC_FLY_COUNT_FILE="$MC_TICK_DIR/fly-count.$(mc_safe_name "$P").$BASHPID"
    : > "$MC_FLY_COUNT_FILE" 2>/dev/null || MC_FLY_COUNT_FILE=""
  fi
  local _stopped=0
  for ROW in "${ROWS[@]}"; do
    [ -n "$ROW" ] || continue
    # THE PR BOUNDARY (BH-6890): a project run that was told to stop (TERM, or
    # a lost project lease) starts no further worker; the running ones finish.
    if [ -n "${MC_STOP_FILE:-}" ] && [ -e "$MC_STOP_FILE" ]; then
      [ "$_stopped" = 1 ] || mc_log "$SLUG stop asked ($MC_STOP_FILE) — no further PR worker starts this tick"
      _stopped=1; fanin_account "$SLUG#${ROW%%$'\t'*}" deferred:stop; continue
    fi
    # THE WINDOW (BH-4842). Under the backstop's timeout, a worker starts only
    # if it can finish before it; the rest wait for the next fire.
    if ! _wcap=$(mc_window_cap); then
      fanin_account "$SLUG#${ROW%%$'\t'*}" deferred:window
      mc_window_defer "$SLUG#${ROW%%$'\t'*}"
      hotfix_pending_is "$P" "${ROW%%$'\t'*}" 2>/dev/null && hotfix_pending_drop "$P" "${ROW%%$'\t'*}"
      continue
    fi
    if [ "$_fly" = 1 ] && [ -n "$MC_FLY_COUNT_FILE" ]; then
      MC_WORKER_DEADLINE_CAP_S="${_wcap:-${MC_WORKER_DEADLINE_CAP_S:-}}" \
        mc_fly_launch "$P" "$SLUG" "$ROW" &
      PRPIDS+=("$!")
      pr_slot_wait
      continue
    fi
    [ "$_fly" = 1 ] && mc_fly_arm "$P" "$SLUG" "$ROW" && continue
    MC_WORKER_DEADLINE_CAP_S="${_wcap:-${MC_WORKER_DEADLINE_CAP_S:-}}" \
      fanin_run_sub "$SLUG#${ROW%%$'\t'*}" mc_fanin_outcome mc_worker_bounded "$ROW" &
    PRPIDS+=("$!")
    pr_slot_wait
  done
  # Explicit pids, never a bare `wait`: a settle in this same tick may have
  # spawned a deploy-verify lane as a child of this subshell, and `wait` would
  # sit on that verifier's twenty minutes. A pid an earlier pr_slot_wait already
  # reaped answers rc 127 on stderr, which is why this is quiet and unchecked.
  for PID in "${PRPIDS[@]:-}"; do [ -n "$PID" ] && wait "$PID" 2>/dev/null; done
  fanin_end
  # PREQUEUE GROUPS (BH-8327): one prequeue group gate run per (repo, main).
  command -v mc_pq_group_tick_end >/dev/null 2>&1 && mc_pq_group_tick_end "$SLUG"
  if [ "$_fly" = 1 ] && [ -n "$MC_FLY_COUNT_FILE" ]; then
    MC_FLY_N_ENQ=$(grep -cx enq "$MC_FLY_COUNT_FILE" 2>/dev/null); MC_FLY_N_SKIP=$(grep -cx skip "$MC_FLY_COUNT_FILE" 2>/dev/null)
    MC_FLY_N_FB=$(grep -cx fb "$MC_FLY_COUNT_FILE" 2>/dev/null); rm -f "$MC_FLY_COUNT_FILE"
  fi
  [ "$_fly" = 1 ] && mc_log "FLY-ENQUEUE $SLUG enqueued=${MC_FLY_N_ENQ:-0} skipped=${MC_FLY_N_SKIP:-0} fallback=${MC_FLY_N_FB:-0}"

  # ---- what the read memo saved this tick (BH-1486) --------------------------
  # One line per project per tick, read AFTER the workers have answered because
  # the counters are files they write and this shell only reads. Together with
  # the `gh-etag lane=merge-conductor:<P> fetched= cached=` line each project
  # subshell logs a moment later, this is the whole per-tick read ledger: what
  # was not asked for at all, and what was asked for conditionally and 304'd.
  mc_log "$SLUG READ-MEMO tick=${MC_TICK_ID:-notick} stack_hits=$(mc_count_get "$P" stackmemo) ci_skipped=$(mc_count_get "$P" cimemo) scan_skipped=$(mc_count_get "$P" scanmemo)"
  # ---- the tier-2 self-enqueue (BH-1668) -------------------------------------
  # AFTER every worker has answered, over the rows this tick already listed,
  # and only on a row whose worker reached the READY arm's enqueue point this
  # tick (ae_mark above). It writes nothing outside MODE=merge (a WOULD line
  # instead), takes no merge budget (a post is not a merge) and has its own cap,
  # MC_AUTOENQUEUE_CAP.
  # Both steps post `@mergifyio queue`, which is a landing, so a lane-run
  # machine (MC_ON_MACHINE=1) runs neither (BH-6495). The hub runs them.
  # A lease-held project run (BH-6890) runs both, unless it was told to stop.
  local _land_ok=1
  [ "${MC_ON_MACHINE:-}" = 1 ] && ! { [ "${MC_LEASED_RUN:-}" = 1 ] && [ -n "${MC_LEASE_FENCE:-}" ]; } && _land_ok=0
  [ -n "${MC_STOP_FILE:-}" ] && [ -e "$MC_STOP_FILE" ] && _land_ok=0
  [ "$_land_ok" = 1 ] && command -v ae_project >/dev/null 2>&1 && ae_project "$P" "$SLUG" "$PROVIDER" "$PBASE" "${ROWS[@]}"
  # The same step for the open PRs of NON-harness authors (BH-4580), which the
  # list above never carries: one REST page, review-prs' APPROVE on the head, the
  # iron-law scan in the READY mark's place, the same cap (bin/lib/mc/external-enqueue.sh).
  [ "$_land_ok" = 1 ] && command -v xe_project >/dev/null 2>&1 && xe_project "$P" "$SLUG" "$PROVIDER" "$PBASE"

  # ---- what the land fan-out actually reached (BH-870) -----------------------
  # The handled sha is recorded HERE, after every worker has answered, and only
  # when NONE of them deferred. A deferral is a PR this fan-out did not reach —
  # a spawn refused at the cap, a PR another worker held, a re-review in flight,
  # a merge-tree this tick could not run — and recording the sha over it would
  # drop that PR's rebase for good. Capped work is re-offered, never dropped.
  if [ "$LAND_FIRE" = 1 ]; then
    LSP=$(mc_count_get "$P" landspawned);  LCU=$(mc_count_get "$P" landcurrent)
    LCO=$(mc_count_get "$P" landconflict); LSK=$(mc_count_get "$P" landskipped)
    LDF=$(mc_count_get "$P" landdeferred); LWD=$(mc_count_get "$P" landwould)
    if [ "$ACTIONS" != 1 ]; then
      mc_log "$SLUG LAND $PBASE ${LAND_SHA:0:8} observe mode: would=$LWD, nothing spawned, sha not recorded — turning actions on re-offers this landing"
    elif [ "${LDF:-0}" -gt 0 ]; then
      mc_log "$SLUG LAND $PBASE ${LAND_SHA:0:8} PARTIAL: spawned=$LSP deferred=$LDF (MC_LAND_REBASE_PARALLEL=${MC_LAND_REBASE_PARALLEL:-4}, a PR lock, a read in flight, or a test this tick could not make) — sha NOT recorded, the next tick re-offers the deferred PRs"
    else
      mc_land_record "$P" "$LAND_SHA"
      mc_log "$SLUG LAND $PBASE ${LAND_SHA:0:8} handled: spawned=$LSP current=$LCU conflict=$LCO skipped=$LSK"
    fi
  fi

  # ---- the batch train (BH-498) ----------------------------------------------
  # AFTER CLASSIFICATION, because the count it keys on is what classification
  # produced: two or more approved PRs of this repo sitting in READY or
  # NEEDS_REBASE is the only shape a merge-time train can be made of. Below two
  # the lane is not spawned at all, which keeps a quiet repo at zero extra API
  # calls per tick.
  #
  # AND DETACHED, for the reason the rebase and the deploy verifier are: it
  # clones, merges, regenerates and runs the repo's whole verification contract
  # once, which is minutes. A lane that can hold a tick is the 03:54-04:02Z
  # stall this conductor was rebuilt to make impossible. batch-resolve.sh takes
  # its own `flock -n`, so a second spawn while one is working is a no-op, and
  # the fds are closed for the same reason every other setsid line closes them.
  # mc_batch_should_spawn, not an inline `-ge 2`: an OPEN TRAIN is its own reason
  # to run the lane, because settling that train is work only the lane does and
  # this conductor is its only invoker.
  BATCHABLE=$(mc_count_get "$P" batchable)
  # Never on a lane-run machine (BH-6890): the lane is detached, clones and
  # runs for minutes, and the machine stops when its run ends.
  if [ -z "$MC_ONLY_KEYS" ] && [ "${MC_ON_MACHINE:-}" != 1 ] && [ "$ACTIONS" = 1 ] && [ -x "$H/bin/batch-resolve.sh" ] && mc_batch_should_spawn "$P" "${BATCHABLE:-0}"; then
    setsid nohup env PATH="$MC_RR_PATH" HARNESS="$H" bash -c \
      '"$1/bin/batch-resolve.sh" "$2"' _ "$H" "$P" >/dev/null 2>&1 9>&- 8>&- 7>&- &
    if mc_batch_train_open "$P"; then
      mc_log "$P: bin/batch-resolve.sh spawned — a batch train of this project is still in flight and only that lane settles it (batchable=$BATCHABLE)"
    else
      mc_log "$P: $BATCHABLE approved PRs are READY or waiting on a rebase — bin/batch-resolve.sh spawned to look for a merge-time train"
    fi
  fi

  # ---- recently closed, not merged (the #319 shape) ----------------------------
  if [ "$MC_BUDGET_LOW" != 1 ]; then
    # ---- recently closed, not merged (the #319 shape) ----------------------------
    # Read from the harness's own PR records, never the repo's raw closed list
    # (BH-1592): see closed_unmerged_rows.
    CLOSED=$(closed_unmerged_rows "$P" "$SLUG" "$OPEN_NUMS")
    mapfile -t CROWS <<<"$CLOSED"
    if [ -n "$MC_ONLY_KEYS" ]; then
      # A keyed tick settles only its keys; every other candidate the probe just
      # memo'd closed goes back to "never probed", so the cron tick settles it.
      local _kc=() _c; for _c in "${CROWS[@]}"; do
        [ -n "$_c" ] || continue
        if mc_only_has "$SLUG#${_c%%$'\t'*}"; then _kc+=("$_c"); else closed_watch_reoffer "$SLUG" "${_c%%$'\t'*}"; fi
      done; CROWS=("${_kc[@]}")
    fi
    for ROW in "${CROWS[@]}"; do
      IFS=$'\t' read -r NUM URL BR CAT <<<"$ROW"
      [ -n "$NUM" ] || continue
      KEY="$SLUG#$NUM"
      [ "$(mc_row_field "$KEY" 2)" = CLOSED ] && continue
      # Under that PR's lock as well: the alert below fires once per PR and is
      # guarded by the row, so two overlapping ticks reading the same freshly
      # closed PR must not both get past the guard. The fd is replaced on each
      # iteration and closed after the loop.
      exec 9>"$(mc_pr_lock "$P" "$NUM")"
      flock -n 9 || { exec 9>&-
        closed_watch_reoffer "$SLUG" "$NUM"
        mc_log "$KEY: another conductor worker holds this PR's lock — its closed-unmerged settle waits for the next tick"; continue; }
      REC=$(mc_record_for "$URL" || true)
      mc_is_harness_pr "$BR" "$REC" || continue
      if ticket_open "$P" "$SLUG" "$REC" "$BR"; then WHY="closed-unmerged-issue-open"; else WHY="closed without merging"; fi
      mc_transition "$KEY" CLOSED "$WHY" "-" "-" "$URL" "-" "-" "$REC" >/dev/null
      [ "$WHY" = closed-unmerged-issue-open ] && mc_alert "$KEY" CLOSED "closed $CAT without merging and its issue is still open — rebuild or close the issue: $URL"
      exec 9>&-
    done
    exec 9>&-
    command -v mc_offlist_settle_tick >/dev/null 2>&1 && mc_offlist_settle_tick "$SLUG" "$OPEN_NUMS"
    # A memo nothing has touched in 30 days goes (D21); losing one costs a re-probe.
    find "$MC_CLOSED_WATCH_DIR" -type f -mtime +30 -delete 2>/dev/null
  fi
  reset_token
  mc_tick_metrics "$P" "$T0"
  return 0
}

# ---- the fleet, one background tick per project -----------------------------
# ONE cron line and ONE entry script, as before; what changed is that the
# projects no longer queue behind each other. Shared state stays safe because
# the only file the tick rewrites whole (pr-state.tsv) is written under its own
# flock in mc_row_put, and everything else it writes is append-only or keyed by
# project, repo or PR.
# THE MAIN-RED DETECTOR (BH-636) and the fleet-sweeps decision (BH-6890) live
# in mc_tick_main_red (bin/lib/mc/tick-scope.sh). It sets MC_FLEET_SWEEPS, which
# mc_tick_fanout and the keyed exit below read.
mc_tick_main_red

# BH-1295 REVIEW FIX (F1, round 2): armed in the PARENT shell too, not only
# inside each project's subshell below — gh-rest-etag.sh's _gh_etag_count is
# now a no-op with nothing exported, so any gh_rest traffic from this
# process's own sequential work (before the loop, and the *_gc calls after
# `wait`) would otherwise go uncounted even though this tick reports.
# BH-1322: under the box's state dir, with an EXIT trap so a SIGTERM (deploy,
# tick deadline) takes the parent's file with it. The trap is the parent's
# alone: bash runs an EXIT trap once, in the shell that set it, and each
# project subshell below re-exports GH_ETAG_COUNT_FILE and sets its own trap,
# so neither can remove the other's file.
export GH_ETAG_COUNT_FILE="$H/state/gh-etag/counts/merge-conductor.$$"
trap 'rm -f "$GH_ETAG_COUNT_FILE"; [ -n "${BG_PERM_MEMO_DIR:-}" ] && rm -rf -- "$BG_PERM_MEMO_DIR"' EXIT

# THE PER-PROJECT FAN-OUT (BH-7879): the held-page flush, the project gate and
# one backgrounded tick_project subshell per project live in mc_tick_fanout
# (bin/lib/mc/tick-scope.sh). It runs after the parent GH_ETAG_COUNT_FILE
# trap above and returns when every project subshell is done.
mc_tick_fanout
# The *_gc housekeeping and mc_dv_reap are fleet sweeps: the cron tick's alone.
if [ "$MC_FLEET_SWEEPS" != 1 ]; then
  command -v gh_rest_etag_report >/dev/null 2>&1 && gh_rest_etag_report merge-conductor
  hb_done merge-conductor; exit 0
fi
# THE FLEET SWEEPS (BH-7879): the *_gc housekeeping and mc_dv_reap live in
# mc_tick_sweeps (bin/lib/mc/tick-scope.sh). It runs after every project
# subshell is done, on a fleet-sweep tick only.
mc_tick_sweeps

# Rows for PRs GitHub no longer lists as open (merged/closed by anyone) are
# settled on the next pass through the closed list or by the open pass; a row
# whose PR is neither listed open nor closed in 30 is left as-is and ages out
# of the mirror by hand — never deleted here.
# BH-1295: how much of this tick's PR-state/diff/list traffic a 304 answered.
command -v gh_rest_etag_report >/dev/null 2>&1 && gh_rest_etag_report merge-conductor
# BH-1201: the tick's held-page summary, the two published settings rows every
# reader keys on, and the once-every-MC_HOLD_REMINDER_S PAUSED reminder. After
# the fan-out, because the counters it sums are written by the workers.
command -v mc_hold_tick_end >/dev/null 2>&1 && mc_hold_tick_end
command -v mc_tick_clock_end >/dev/null 2>&1 && mc_tick_clock_end
hb_done merge-conductor
exit 0
