#!/bin/bash
# bin/blocked-resolver.sh — hub cron (*/10, offset from the merge conductor):
# NOTHING IN THIS HARNESS WAITS ON A HUMAN REVIEW.
#
# the operator, 2026-09-13 22:54Z: "Can we change all these definitions that require a
# human / the reality is I will never do a human review."
#
# Every lane in this fleet had the same escape hatch. A rebase that conflicts, a
# merge queue that ejects twice, a re-review that BLOCKs, an iron-law scan that
# fires, a test-tamper gate that refuses, a pool machine that dies, a rescue that
# gives up — each of them parked the work and wrote a line asking a person to
# look. Nobody was ever going to. So the park became the terminal, and a ticket
# that reached one was finished in the only sense that matters: it never shipped
# and nothing said so out loud.
#
# This lane drains those parks on an AGENT ladder and, when the ladder runs out,
# records an OUTCOME rather than a request:
#
#   MECHANICAL      rung 1 for a branch problem: merge origin/main into the
#                   branch in the authed clone (mc_rebase — gate, lease, push),
#                   or, when there is nothing to merge, re-run the failed CI
#                   runs once. No model, no tokens, seconds of wall clock.
#   REGENERATE      rung 1b for a red CI (BH-950.2): one more free merge of
#                   origin/main before any agent call is bought. That merge is
#                   what will regenerate the generated-files table ONCE #969
#                   lands (it teaches mc_rebase to run mc_regen_table); until
#                   then it is a plain re-merge, and a park with nothing to
#                   merge records regen-noop and takes the ladder's own answer in
#                   the same tick. Once per head; BR_REGEN_RUNG=0 turns it off.
#   FIX ROUND       one execute-stage agent call in a worktree of the PR branch:
#                   merge origin/main, apply whatever evidence exists — the
#                   reviewer's posted findings, the conflict the merge leaves in
#                   the tree, the failing job's log — run the project's
#                   typecheck + unit IN THE FOREGROUND, push with
#                   --force-with-lease. The conductor's head-bound re-review
#                   then re-judges it.
#   REBUILD FRESH   close the stale PR, enqueue a new build of the same ticket
#                   against CURRENT main. Three of these, maximum, per ticket.
#                   AND THE RUNG FINISHES (2026-09-16, BH-530): br_from_rebuilds
#                   reads how that build ENDED and acts on it — a PR_CREATED is
#                   left to the conductor, a BUILD_DEAD spends the next rebuild,
#                   and a DECOMPOSE_FAILED / PLAN_BLOCKED / REVIEW_BLOCKED is a
#                   TICKET-level stop that abandons the park and tells the ticket
#                   once (br_ticket_comment). A refusal this rung cannot fix — no
#                   ticket key on the branch, the title or any record — is a
#                   SPENT attempt (br_enqueue_fresh rc 2), capped like every
#                   other, rather than the same refusal every ten minutes.
#                   A RUNNING REBUILD IS NOT A NEW ONE (BH-487.1). Before this
#                   rung spends anything it asks the worker whether a build of
#                   this ticket is already queued or claimed, and if one is it
#                   writes wait=REBUILD_WAIT and holds: no event, no PR closed,
#                   no counter bumped, and no PER_TICK slot. The cap counts the
#                   DISTINCT job ids this lane bought (rebuild_jobs[]), not the
#                   ticks that asked, so a worker answering `duplicate` can no
#                   longer burn the ladder in three ticks while the one real
#                   build is still executing. An unreadable queue at the cap
#                   holds too — an outage is never "the build finished".
#   ADJUDICATE      one review-stage agent call over the flagged lines (iron-law
#                   scan hits, test-tamper blocks) with 30 lines of context, the
#                   plan, and the iron laws. It answers ACCEPT or REJECT and
#                   nothing else. ACCEPT writes a marker the merge sweep and the
#                   conductor both honor; REJECT drops to FIX ROUND or REBUILD.
#   ABANDONED       the ladder is exhausted. The PR is closed, the row moves to
#                   a terminal state called ABANDONED, and ONE alert lists every
#                   attempt and why it failed. That alert is a record of what was
#                   tried, not a request for a review.
#
# AND THE LADDER CLIMBS IN THAT ORDER (2026-09-15, the operator: "plan and launch all
# 10 upgrades"). 24 hours of blocked-resolver.log: 121 rebuild-fresh outcomes,
# ZERO fix rounds, one ABANDONED. A rebuild is the most expensive rung on the
# board — plan + execute + review, $20-40 — and it was the DEFAULT answer to a
# rebase conflict and to red CI, which are the two cheapest things in this
# harness to actually fix. So for the three reason classes that are about a
# BRANCH rather than about a dead machine (br_ladder_class: rebase-conflict,
# ci-red, review-blocked) the rungs are now
#
#   rung 1  MECHANICAL     merge main / re-run CI            (free)
#   rung 2  FIX ROUND      one agent call on the EXISTING branch
#   rung 3  REBUILD FRESH  only after rung 2 did not land it
#
# AND THE CAPS COME IN TWO SHAPES, DECIDED BY THE SIZE OF THE CONFLICT (BH-579,
# 2026-09-17). conflict_lines is MEASURED — the conductor's sidecar for the
# parked PR (mc_conflict_size_file) and the fix round's own tree
# (mc_conflict_lines), whichever is bigger:
#
#   shape  conflict_lines           mechanical  fix rounds  rebuilds
#   large  unknown, 0, or > 300     1           1           3   (today, unchanged)
#   small  1..300                   1           2           1
#
# Unknown is LARGE, never small: an unmeasured conflict keeps today's ladder —
# and a measured 0 is unknown, because a delete/modify conflict leaves no
# `<<<<<<<` markers to count (br_shape).
#
# A CONFLICT THAT KEEPS COMING BACK IS CONTESTED. When the same path conflicts
# again under a DIFFERENT (pr, head) of one ticket and the next rung would be
# the rebuild, this lane writes a contested hold instead: the ticket wins the
# path, every open harness PR and planned ticket touching it is parked
# BLOCKED_HUMAN `contested:<path> (winner <KEY>)`, and the winner gets ONE bonus
# fix round to land. The same PR on the same head re-offered is the same
# occurrence, not a recurrence. A hold ends when the winner merges, is abandoned
# or its ttl runs out — a release UNPARKS the losers and closes nothing, and a
# loser named by two holds is released by the LAST of them.
#
# WHAT THE HOLD BINDS, TODAY: THIS LANE. `contested*` is not a sticky hand-off
# reason, so until #589 lands the conductor re-derives a loser's row from GitHub
# on its next tick and may rebase it, or merge it if it is clean and approved.
# What the hold buys now is that this lane spends no rung, no rebuild and no API
# call on a held PR, and that the winner gets its bonus round uncontested by the
# ladder. Long form: docs/MERGE-CONDUCTOR.md section 12.
#
# each rung capped per TICKET and each transition recorded as an event line
# (br_event -> `EVENT resolver_rung …` in this log and a fleet_event beat).
#
# EVERY RUNG TRANSITION IS AN EVENT, NEVER A CLOCK (the operator, 2026-09-16: "We
# shouldn't have rules that kill PRs because of time; it should be event
# based"). Nothing in this lane closes or abandons a PR because it has been
# parked a while: rung 2 is reached because rung 1 reported conflict / gate-red /
# nothing-to-do, rung 3 because the fix round RAN and did not produce a verified
# commit (or its push lost the lease, or the cap is spent), and ABANDONED
# because the rebuild cap is spent. Time is allowed to PAGE and never to kill —
# the conductor's mc_ttl fires one stuck alert and a re-kick, which is why a
# NEEDS_REBASE PR past 30m gets an alert and another rebase attempt, not a
# close. Anything that stops a rung BEFORE it runs (a missing clone, a dead
# credential, a failed worktree add) is a fact about the box, not an event about
# the PR: br_setup_blocked pages once and the next tick tries the same rung
# again. See docs/MERGE-CONDUCTOR.md, "No time kills, and a setup failure is
# not an event".
# build-dead and the pool's deaths keep going straight to REBUILD FRESH: there
# is no branch to fix, the machine went away with the work.
#
# NO RUNG IS SPENT ON A PR THIS LANE COULD NOT READ (2026-09-16). br_pr_ref
# answers rc 2 when GitHub did not answer at all — gh non-zero, an empty body, a
# rate limit, a 5xx — as opposed to rc 1, which means the PR WAS read and really
# has no branch. On rc 2 both branch rungs log `PR read FAILED (<gh error>) —
# retrying next tick, no rung spent` and return: no counter moves, no state is
# written, and the park is re-offered on the next tick. The read itself is REST
# (`gh api repos/…/pulls/N`) rather than the GraphQL `gh pr view`, because the
# GraphQL bucket is the one the whole hub shares and the one that ran out.
#
# THE ONE GATE THAT STAYS WITH A PERSON is a production DB migration apply where
# the app has no /api/internal/migrations endpoint: no box in this fleet holds
# prod DB credentials (the operator, 2026-07-24), so there is no agent path to give it.
# Those messages say "needs the app's migrations endpoint (orchestrator judged
# apply)" — they do not say "needs a human", because the distinction is the
# whole point: one is a missing capability, the other was a missing owner.
#
# IDEMPOTENT, ONE ACTION PER KEY PER TICK. Attempt counters live in
# state/blocked-resolver/<project>/<rkey>.json and every action is taken under a
# PER-KEY flock — never one global lock, because a fix round holds its lock for
# up to 90 minutes and a global one would stop the whole fleet's drain behind a
# single slow build.
#
# THE REVIEW LANE'S VERDICT HAS A CONSUMER (BH-872, 2026-09-18). bin/review-prs.sh
# reviewed harness PRs and asked for changes, and NOTHING read that verdict: the
# PR sat with a blocking review, Mergify dequeued it on `github-review-approved`,
# and the lane re-posted the same findings on the same head every tick. So a
# CHANGES_REQUESTED verdict from that lane, on the CURRENT head of a
# harness-authored PR, is now a candidate here (br_from_reviews) and routes
# straight to the FIX ROUND with the review body as the brief — keyed on
# (PR, head sha) so a second verdict on the same head buys nothing, capped, and
# then ABANDONED (br_fix_terminal -> br_abandon, BH-4149): the PR is closed with
# what was tried and the ticket is re-filed through the board. No rebuild,
# because a hand-made harness PR may have no ticket to rebuild. Before BH-4149
# this terminal was an ESCALATED park that waited for a person to push; records
# stamped ESCALATED then stay terminal and are never backfilled.
#
# KNOBS (code constants are the documented fallback, env/global.env overrides):
#   BR_REVIEW_FIX_ROUNDS      2       fix rounds per TICKET for a review verdict;
#                                     since BH-7123 wave B the settings row
#                                     review.fix_rounds_max[.<project>] outranks
#                                     it (br_review_fix_cap), review.mode
#                                     cowboy/off reads 0, and the terminal is
#                                     br_cap_notes (merge with notes) unless an
#                                     ALWAYS-BLOCK finding stands (br_abandon)
#                                     (every other reason keeps BR_MAX_FIXROUNDS)
#   BR_CONFLICT_FIX_ROUNDS    2       fix rounds per TICKET for a SMALL measured
#                                     conflict before rebuild-fresh (BH-6964);
#                                     unset, BR_MAX_FIXROUNDS_SMALL is the cap
#   BR_CONFLICT_BRIEF_BYTES   6000    bytes of the merged-in side's diff and of
#                                     the plan in a conflict round's brief (0 off)
#   BR_REVIEW_LOOKBACK_SECS   172800  how far back a PR must have been updated
#                                     for its reviews to be read at all (48h)
#   BR_SUPERSEDE_SETTLE_SECS  (registry, required) the window after a new head
#                                     — including this lane's own fix-round
#                                     push — before the rebuild rung may close
#                                     the PR (br_supersede_guard, BH-1642)
#   BR_SUPERSEDE_DECLINE_ALERT_SECS (registry, required) how long one
#                                     (PR, head, reason) decline may last before
#                                     it raises ONE lane-alert (br_sup_alert)
#   (no knob) a CI-reason park whose current head is green is never closed
#                                     by the rebuild rung: `SKIP green-at-head`
#                                     (br_supersede_guard, BH-1671)
# See docs/MERGE-CONDUCTOR.md, section 12 ("The review lane's verdict is an
# event with a consumer").
#
# FLAGS
#   flags/blocked-resolver-disabled   kill switch: this lane does nothing
#   flags/blocked-resolver-observe    classify and log, take no action
#   flags/automerge-disabled          the fleet kill switch, honored here too
# usage: blocked-resolver.sh [project]      (no argument = every fleet project)
#
# EVERY DECISION READ, SEARCH, COMMENT AND CLOSE IN THIS FILE IS REST (#783).
# The marker below opts this file into
# tests/gh-no-graphql-decision-guard-test.sh: no `gh pr`, `gh issue` or `gh run`
# call may survive here except a line that carries its own `# gh-guard-allow:`
# reason (there is exactly one, in br_ci_log). The rc 0/44/75 contract the reads
# obey lives in bin/lib/gh-rest.sh; the helpers they go through are the br-rest
# block below br_slug_of_url.
# gh-rest: no-graphql
set -uo pipefail
# BH-2303: every model call this lane makes names the lane, so its cost rows
# carry lane_id and its LLM_* knobs (on/off, runners, daily cap) bind it alone.
export AGENT_CALL_LANE=blocked-resolver
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")
# NOT EXPORTED (#463). Exporting it handed a live harness root to every child of
# this lane, including the agent sessions it starts and whatever those run —
# which is the 2026-09-15 hub wipe one layer up (#388, root cause #404). The
# children that genuinely need it get `HARNESS="$H"` on their own command line.
# BH-452's env-dir lookup above keeps its own `${HARNESS:-...}` default, which
# resolves the same value without pushing it into the environment.
[ -f "$H/fleet.conf" ] && export FLEET_CONF="${FLEET_CONF:-$H/fleet.conf}"
mkdir -p "$H/logs" "$H/locks" "$H/state" "$H/flags" "$H/builds" 2>/dev/null
if [ -f "$HENV/global.env" ]; then set -a; # shellcheck disable=SC1091
  . "$HENV/global.env"; set +a; fi
# shellcheck source=/dev/null
[ -r "$H/bin/jobs-client.sh" ] && . "$H/bin/jobs-client.sh"
# shellcheck source=bin/lib/comment-mark.sh
[ -r "$H/bin/lib/comment-mark.sh" ] && . "$H/bin/lib/comment-mark.sh"
# shellcheck source=bin/lib/fix-round-queue.sh
[ -r "$H/bin/lib/fix-round-queue.sh" ] && . "$H/bin/lib/fix-round-queue.sh"
# shellcheck source=bin/lib/model-route.sh
[ -r "$H/bin/lib/model-route.sh" ] && . "$H/bin/lib/model-route.sh"
# BH-5003: build notes are also ledger rows (bn_put below). Fail-open: no lib,
# no bn_put, and every note is written to the hub file exactly as before.
# shellcheck source=bin/lib/build-note-db.sh
{ [ -r "$H/bin/lib/build-note-db.sh" ] && . "$H/bin/lib/build-note-db.sh"; } || true
# BH-6128: a run on a Fly lane machine (LANE_RUN_ID set) fetched its hub inputs
# through this lib and writes its changes back through it. Fail-open on the hub:
# no lib, no write-back and no pre-apply, and a tick runs exactly as before.
# shellcheck source=bin/lib/lane-run-inputs.sh
{ [ -r "$H/bin/lib/lane-run-inputs.sh" ] && . "$H/bin/lib/lane-run-inputs.sh"; } || true

# --- BH-594: the owning box's entry ------------------------------------------
# `blocked-resolver.sh --fix-here <project> <rkey> <reason> <url> <record> <tkey>`
# is how a fix round the HUB queued runs on the box that owns the project: the
# hub writes a fix_round_jobs row (br_fix_remote, BH-2674), and this box's
# bin/fix-round-claim.sh claims it and invokes this entry with the row's record
# on stdin, then reads the FIX_RESULT / FIX_RECORD lines back into the row's
# finish. It is not a tick: no cron single-flight, no heartbeat.
# THE BOX'S OFF-SWITCHES STILL HOLD (BH-2038): all-off, lane-off-blocked-resolver,
# lane-off-blocked-resolver-<project> and blocked-resolver-disabled each answer
# one `FIX_RESULT box-paused <base64 why>` and run nothing — the hub admitted
# the round, but an operator who switched this box off has the last word.
BR_FIX_HERE=0; BR_FIX_ARGS=()
if [ "${1:-}" = --fix-here ]; then BR_FIX_HERE=1; shift; BR_FIX_ARGS=("$@"); set --; fi
# --- BH-5913: the cron entry is a DISPATCHER ---------------------------------
# `blocked-resolver.sh --dispatch` scans nothing. It starts one detached
# `blocked-resolver.sh <project>` per project, each on
# its own lock, at its own stable offset, and exits (bin/lib/project-lanes.sh).
# One project's 55-minute run never delays another's.
BR_DISPATCH=0
if [ "${1:-}" = --dispatch ]; then BR_DISPATCH=1; shift; set --; fi

# --- BH-1132: the lane's one off-switch -------------------------------------
# flags/all-off, flags/lane-off-blocked-resolver, or the D1 pause_flags row of the
# same name stops this tick (exit 0 — a paused lane is not a failure). With no
# flag and no row this returns immediately and the lane behaves exactly as it
# always has, and an unreachable worker fails OPEN to the last cached answer.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off blocked-resolver.
# shellcheck disable=SC1091
. "${H}/bin/lib/lane-gate.sh" 2>/dev/null || true
# BH-2435: blocked-resolver-disabled is a settings row before it is a file.
. "${H}/bin/lib/lane-switch.sh" 2>/dev/null || true
command -v lane_switch >/dev/null 2>&1 || lane_switch() { [ -f "${H}/flags/$1" ]; }
# THE BUILDS OF RECORD, FROM THE LEDGER (BH-2349). Missing, bor_union is
# undefined and br_from_builds / br_from_rebuilds read builds/ as they always have.
. "${H}/bin/lib/builds-of-record.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/lib/builds-of-record.sh" 2>/dev/null || true
# The ONE verdict reader (bin/lib/verdict-parse.sh, BH-1625). Missing, every
# verdict reads unknown — never APPROVE.
. "${H}/bin/lib/verdict-parse.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/lib/verdict-parse.sh" 2>/dev/null || true
# THE CONFIGURED COMMIT IDENTITY (BH-1134): the fix round's git writes run under
# it and nothing else is pushed. Missing, there is no pin and br_fix_round's
# author check answers "could not run" — the round is refused, never pushed.
. "${H}/bin/lib/git-identity.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/lib/git-identity.sh" 2>/dev/null || true
# THE ACCEPT'S HIT FINGERPRINTS (BH-4474): an iron-law ACCEPT records them in
# the jobs ledger so the next head with the same hits is not re-adjudicated.
# Missing, nothing is recorded and every new head is adjudicated as before.
. "${H}/bin/lib/ironlaw-carry.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/lib/ironlaw-carry.sh" 2>/dev/null || true
# ARCHIE FIRST (BH-4585): afm_first says whether Archie's rebase-repair playbook
# is still working a park and hands over its diagnosis. Missing, afm_first is
# undefined and every park gets its fix round exactly as before.
{ . "${H}/bin/lib/archie-fm.sh" && . "${H}/bin/lib/archie-fm-repair.sh"; } 2>/dev/null || true
if [ "$BR_FIX_HERE" != 1 ]; then
  command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit blocked-resolver
elif command -v lane_paused >/dev/null 2>&1 && lane_paused blocked-resolver "${BR_FIX_ARGS[0]:-}"; then
  # The predicate, not lane_gate_or_exit: that exits with no protocol line and
  # posts a liveness tick for a hub lane from a box. Before stdin is read and
  # before any write, so a paused box cannot do half a round.
  echo "FIX_RESULT box-paused $(printf '%s on %s' "$LANE_PAUSED_WHY" "$(hostname 2>/dev/null || echo the owning box)" | base64 -w0)"
  exit 0
fi
# THE KNOBS, BELOW THE ENV LOAD (BH-1165). The gate above stops this lane; this
# is what lets a settings row reach its own unmodified ${KNOB:-default} reads.
# It is BELOW `set -a; . env/global.env` on purpose: above it, the env file
# re-assigns every name and the row silently loses. Fails open — with no row,
# nothing is exported and the lane behaves byte-for-byte as it does today.
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    blocked-resolver


# The per-repo App token, and then the "which PAT can see this repo" probe that
# is still the fallback. Both guarded: a box whose harness sync has not landed
# gh-app-auth.sh yet runs today's code instead of dying on an unset function.
# shellcheck source=bin/lib/gh-app-auth.sh
[ -r "$H/bin/lib/gh-app-auth.sh" ] && . "$H/bin/lib/gh-app-auth.sh"
# WHICH IDENTITY GOT REFUSED, AND HOW MANY CALLS THIS LANE MAKES (BH-426). The
# tag gh-app-auth.sh sets above is only worth setting if something writes it
# down; this lane was one of two on the merge path that never sourced the writer,
# so a rate-limit 403 here named nothing. Guarded and fail-open, like every
# source in this block.
# shellcheck source=bin/lib/gh-limit-logger.sh
[ -r "$H/bin/lib/gh-limit-logger.sh" ] && . "$H/bin/lib/gh-limit-logger.sh"
# shellcheck source=bin/lib/gh-repo-token.sh
[ -r "$H/bin/lib/gh-repo-token.sh" ] && . "$H/bin/lib/gh-repo-token.sh"
# THE REVIEW-VERDICT SOURCE's two libs (BH-872), guarded the same way: the
# harness-author PR list (which is also the "is this one of ours" test) and the
# shared rate-limit budget that bounds its extra reads. A box whose sync has not
# landed them runs every other source exactly as before — br_from_reviews asks
# `command -v harness_pr_list` and answers nothing when it is missing.
# shellcheck source=bin/lib/gh-pr-list.sh
[ -r "$H/bin/lib/gh-pr-list.sh" ] && . "$H/bin/lib/gh-pr-list.sh"
# shellcheck source=bin/lib/gh-budget.sh
[ -r "$H/bin/lib/gh-budget.sh" ] && . "$H/bin/lib/gh-budget.sh"
# IS THIS TICKET HELD? The one shared reading (bin/lib/hold.sh), and the same
# guard as the two libs above: a box whose harness sync has not landed it runs
# today's code rather than dying on an unset function. br_hold_gate answers
# "proceed" when the lib is absent, which is exactly the pre-2026-09-18
# behaviour.
# shellcheck source=bin/lib/hold.sh
[ -r "$H/bin/lib/hold.sh" ] && . "$H/bin/lib/hold.sh"
# THE REVIEW LEVELS (BH-7123 wave B): rl_mode / rl_knob read the review cap row
# (bin/lib/br/record.sh br_review_fix_cap) and rl_line_blocks says whether a
# standing finding is on the ALWAYS-BLOCK floor (br_cap_notes). Guarded like
# the libs above: without it the cap is the registry knob and every review
# terminal is today's abandon.
# shellcheck source=bin/lib/review-level.sh
[ -r "$H/bin/lib/review-level.sh" ] && . "$H/bin/lib/review-level.sh"
# A HAND-OFF ACTS, SAYS WHY NOT, OR PAGES (BH-5125): the claim/ack/sweep record
# the main loop keeps for every candidate. The ticket thread reader and the
# untrusted-input wrapper are what br_fix_round's DIRECTIVE reads and wraps the
# newest principal comment with. All three guarded like the libs above: a box
# without them runs today's tick and today's brief.
# shellcheck source=bin/lib/handoff-watch.sh
[ -r "$H/bin/lib/handoff-watch.sh" ] && . "$H/bin/lib/handoff-watch.sh"
# shellcheck source=bin/lib/prebuild-repro/thread.sh
[ -r "$H/bin/lib/prebuild-repro/thread.sh" ] && . "$H/bin/lib/prebuild-repro/thread.sh"
# shellcheck source=bin/lib/untrusted-input.sh
command -v ui_wrap >/dev/null 2>&1 || { [ -r "$H/bin/lib/untrusted-input.sh" ] && . "$H/bin/lib/untrusted-input.sh"; }
# THE ONE PUSH (BH-2504): the fix round re-reads the ticket's hold right before
# it pushes, and pushes under a lease on the head it started from. NOT guarded
# like the libs above, on purpose: a box without it has no hold_push, so the
# fix round's push fails and nothing is written — an unchecked push onto a
# held branch is the incident, and "no push this tick" is not.
# shellcheck source=bin/lib/hold-push.sh
[ -r "$H/bin/lib/hold-push.sh" ] && . "$H/bin/lib/hold-push.sh"
# THE DATA LANE'S CONTRACT (BH-4926): dl_candidate & co. Absent, every
# br_data_lane_route call site asks `command -v dl_candidate` and runs today's code.
# shellcheck source=bin/lib/data-lane.sh
[ -r "$H/bin/lib/data-lane.sh" ] && . "$H/bin/lib/data-lane.sh"
# WHO HAS SPOKEN ON THIS HEAD, AND DOES ITS TICKET SAY STOP (BH-1642). The
# rebuild rung's supersede guard (br_supersede_guard) asks both before it closes
# a PR: bin/lib/verdicts.sh, the ONE reader of the verdicts table (the
# conductor lib usually brings it through block-gate.sh already), and
# bin/lib/ticket-ownership.sh's to_merge_hold, the one answer every merge lane
# gives to "is this ticket held". Guarded like the libs above: a box whose sync
# has not landed them says so on the guard's own line and keeps today's rung.
# shellcheck source=bin/lib/verdicts.sh
command -v vd_standing >/dev/null 2>&1 || { [ -r "$H/bin/lib/verdicts.sh" ] && . "$H/bin/lib/verdicts.sh"; }
# shellcheck source=bin/lib/ticket-ownership.sh
[ -r "$H/bin/lib/ticket-ownership.sh" ] && . "$H/bin/lib/ticket-ownership.sh"
# The "already bought?" read (BH-3930). Guarded like the two above; without it
# every re-review is bought as before.
# review_bought's outputs, empty when the library is absent (BH-4134).
RB_SOURCE=""; RB_WORD=""; RB_CLASS=""; RB_SERVED=""
# shellcheck source=bin/lib/review-bought.sh
[ -r "$H/bin/lib/review-bought.sh" ] && . "$H/bin/lib/review-bought.sh"
# WHO OUR PRs ARE, and the one list call that finds all of them: the contested
# hold has to know which OPEN pull requests touch the path it is about to hold,
# and a hardcoded --author is how eleven consumers went blind to App-authored
# PRs. Guarded like the two above; without it br_competitors answers "cannot
# read" and the ladder takes today's rung.
# shellcheck source=bin/lib/gh-pr-list.sh
[ -r "$H/bin/lib/gh-pr-list.sh" ] && . "$H/bin/lib/gh-pr-list.sh"
# The priority contract (#644) and the scheduler knobs. Same guarded shape as
# bin/run-build.sh:113,156: a box whose harness sync has not landed either file
# runs today's code — discovery order and no slot cap — instead of dying on an
# unset function.
# shellcheck source=bin/lib/hotfix-lib.sh
[ -r "$H/bin/lib/hotfix-lib.sh" ] && . "$H/bin/lib/hotfix-lib.sh"
# shellcheck source=bin/lib/scheduler-conf.sh
[ -r "$H/bin/lib/scheduler-conf.sh" ] && . "$H/bin/lib/scheduler-conf.sh"
# The conductor's lib gives us MC_ROWS, mc_transition, mc_rereview, mc_git_auth
# and mc_record_for. Sourced, never re-implemented: a second answer to "which
# build record belongs to this PR" that drifted would resolve the wrong build.
# shellcheck source=bin/lib/merge-conductor-lib.sh
if [ -r "$H/bin/lib/merge-conductor-lib.sh" ]; then . "$H/bin/lib/merge-conductor-lib.sh"; mc_init
else echo "blocked-resolver: bin/lib/merge-conductor-lib.sh missing — cannot read PR state" >&2; exit 1; fi
# THE REBUILD LEDGER (BH-487.0). HARD, like the conductor's lib above and for
# the same reason: a resolver whose ledger functions are undefined does not
# refuse, it silently counts rebuilds on the bare `rebuilds` counter again once
# the rung reads them — a ladder that looks bounded and is not.
# shellcheck source=bin/lib/rebuild-ledger.sh
if [ -r "$H/bin/lib/rebuild-ledger.sh" ]; then . "$H/bin/lib/rebuild-ledger.sh"
else echo "blocked-resolver: bin/lib/rebuild-ledger.sh missing — cannot read the rebuild ledger" >&2; exit 1; fi
# THE REST CONTRACT every decision read below goes through: rc 0 act on the
# body, rc 44 the thing is ABSENT, rc 75 GitHub did not answer and the tick ends
# with the park exactly as it was. HARD-required, like the two libs above and
# for the same reason: a resolver whose reads are undefined functions answers rc
# 127 on every one of them, which is neither 44 nor 75 and would be read as "not
# open, nothing to close" — the #768 bug with a different empty answer.
# shellcheck source=bin/lib/gh-rest.sh
if [ -r "$H/bin/lib/gh-rest.sh" ]; then . "$H/bin/lib/gh-rest.sh"
else echo "blocked-resolver: bin/lib/gh-rest.sh missing — cannot read PR state" >&2; exit 1; fi
# The review poster (BH-641) and the guard-silencing classifier. Both degrade on
# a box mid-sync that carries this script with the old bin/lib: rp_post falls
# back to the pre-BH-641 comment, and an absent gs_classify classifies nothing
# and refuses nothing — a gate's own absence never blocks work here.
# shellcheck source=bin/lib/review-post.sh
[ -r "$H/bin/lib/review-post.sh" ] && . "$H/bin/lib/review-post.sh"
# The fallback posts through br_pr_comment for the same reason every other
# comment on this lane does (BH-783): `gh pr comment` wraps GraphQL, which is
# the credential that rate-limits first and answers with silence.
command -v rp_post >/dev/null 2>&1 || rp_post() {
  printf -- '-\n'
  br_pr_comment "$4" "$(printf '%s\n\n---\n%s' "$(cat "$3" 2>/dev/null)" "$5")" >/dev/null 2>&1
}
# shellcheck source=bin/lib/guard-silenced.sh
[ -r "$H/bin/lib/guard-silenced.sh" ] && . "$H/bin/lib/guard-silenced.sh"
# WHO THIS BOX IS (BH-594): the hub runs no agent build work, so its fix rounds
# hop to the owning box. A box without the lib runs every round where it is,
# which is exactly the behaviour before the hop existed.
# shellcheck source=bin/lib/hub-box.sh
[ -r "$H/bin/lib/hub-box.sh" ] && . "$H/bin/lib/hub-box.sh"
command -v hub_box_builds_here >/dev/null 2>&1 || hub_box_builds_here() { return 0; }
command -v is_hub_box >/dev/null 2>&1 || is_hub_box() { [ "${1:-}" = local ]; }
# The fix-round preflight (BH-1794). Guarded like the two above: a box whose
# sync has not landed it runs every fix round exactly as before (br_preflight
# answers "proceed" when frp_ci does not exist).
# shellcheck source=bin/lib/fixround-preflight.sh
[ -r "$H/bin/lib/fixround-preflight.sh" ] && . "$H/bin/lib/fixround-preflight.sh"
# The fix-round scratch-closure gate (BH-5064). Guarded: a box whose sync has not
# landed it runs every fix round exactly as before.
# shellcheck source=bin/lib/fixround-closure-lint.sh
[ -r "$H/bin/lib/fixround-closure-lint.sh" ] && . "$H/bin/lib/fixround-closure-lint.sh"
# The fix-round CI lint run (BH-6897), guarded the same way.
# shellcheck source=bin/lib/ci-local-verify.sh
[ -r "$H/bin/lib/ci-local-verify.sh" ] && . "$H/bin/lib/ci-local-verify.sh"
# shellcheck source=bin/lib/br-pool-terminals.sh
[ -r "$H/bin/lib/br-pool-terminals.sh" ] && . "$H/bin/lib/br-pool-terminals.sh"

# br_queue_enq <project> <key> — the enqueued_at stamp of the worker's row for
# this key, if it has one and we can read it. rc 1 on no row / no reader /
# blank stamp.
br_queue_enq() {
  local row enq
  command -v queue_row >/dev/null 2>&1 || return 1
  row=$(queue_row "$1" "$2" 2>/dev/null) || return 1
  enq=$(printf '%s' "$row" | cut -f2)
  [ -n "$enq" ] && [ "$enq" != "-" ] || return 1
  printf '%s' "$enq"
}

# br_rebuild_inflight <project> <ticket-key> — is a rebuild already queued for
# this ticket? rc 0 + prints the row when queued/claimed; rc 1 if not live
# (done/failed/no row/box lane); rc 2 if the queue could not be read; rc 3 if
# there is no usable key or this box has no queue_row reader.
#
# rc 2 IS DELIBERATELY BOTH "the queue is down" AND "the client answered with no
# row" — bin/jobs-client.sh returns the same non-zero for an empty `.queue[0]`
# as for an unreachable worker, so this lane genuinely cannot tell them apart.
# Erring toward "unreadable" is the safe half: an outage that read as "no row"
# would ABANDON a park whose build is still running. It costs nothing today
# because POST /api/queue upserts on (project, ticket_key) and nothing deletes
# build_queue rows, so a ledger at the cap always HAS a row to read.
br_rebuild_inflight() {
  local p="$1" tkey="$2" row st
  [ -n "$tkey" ] && [ "$tkey" != "-" ] || return 3
  br_pool_routed "$p" || return 1
  command -v queue_row >/dev/null 2>&1 || return 3
  row=$(queue_row "$p" "$tkey" 2>/dev/null) || return 2
  st=$(printf '%s' "$row" | cut -f1)
  case "$st" in
    queued|claimed) printf '%s' "$row"; return 0 ;;
    *) return 1 ;;
  esac
}

# br_job_for_enq <state-json> <enqueued-at> — the ledger id of the job this lane
# enqueued at that stamp, or nothing when the ledger has never seen it (a triage
# relaunch, a watchdog requeue: an EXTERNAL job, whose RESULT is still ours to
# read but whose cost this lane did not buy).
br_job_for_enq() {
  [ -n "${2:-}" ] && [ "$2" != "-" ] || return 0
  printf '%s' "${1:-}" | jq -r --arg e "$2" \
    'first(.rebuild_jobs[]? | select((.enqueued_at // "") == $e) | (.id // empty)) // empty' 2>/dev/null
  return 0
}

# BR_REBUILD_WAITING — set by br_rebuild_wait and by the two other holds in the
# rebuild rungs (an unreadable queue at the cap, a duplicate answer that raced
# the pre-check). A WAIT IS NOT A RUNG: br_one reads this after the dispatch and
# returns 3, which keeps the conductor's park and costs no PER_TICK slot. It is
# a variable rather than the rung's exit code because br_regen_rung dispatches
# the displaced rebuild rung itself and returns its own rc, so a wait behind the
# regenerate rung would otherwise be read as a rung that ran.
BR_REBUILD_WAITING=0
# DID THIS RUNG ACTUALLY BUY A POOL BUILD (BH-1457, review I2)? Set at the ONE
# place an enqueue lands (br_rebuild_settle's rc-0 arm) and read by the per-tick
# rebuild cap. The first cut counted the DISPATCHED rung instead, and both
# rebuild rungs return 0 on paths that enqueue nothing — the merged guard, the
# hold gate, a spent ticket cap that abandons, a refused close, a duplicate
# race. Four abandons therefore exhausted BR_REBUILDS_PER_TICK and every genuine
# rebuild that tick was turned away by a line that said "already bought 4 pool
# build(s)", which was false.
BR_REBUILD_BOUGHT=0
# BR_XPR_PARKED (BH-4667) — set by br_xpr_parked when a terminal or a refused
# close left an outsider's PR for its author. Nothing was closed, recorded or
# bought, so br_one reads this after the dispatch and returns 3, exactly like a
# wait: a parked outsider PR never spends a PER_TICK slot. A variable for the
# same reason as BR_REBUILD_WAITING — the callers of the terminals mostly
# return 0 over the terminal's own rc.
BR_XPR_PARKED=0

# br_rebuild_wait <project> <cap-key> <job-id> [external] [row]
#   A rebuild is already in flight. Write the wait fields, log it, and — for an
#   external job the ledger has never seen — record exactly one rebuild-fresh
#   attempt so the cap later knows this ticket already consumed its one look and
#   br_from_rebuilds consumes that build's RESULT when it ends.
br_rebuild_wait() {
  local p="$1" ck="$2" jobid="$3" external="${4:-}" row="${5:-}" st has qs qby qreq who
  BR_REBUILD_WAITING=1
  br_set_wait "$p" "$ck" "$jobid"
  who=""
  if [ -n "$row" ]; then
    qs=$(printf '%s' "$row" | cut -f1); qby=$(printf '%s' "$row" | cut -f3)
    qreq=$(printf '%s' "$row" | cut -f4)
    who=", ${qs:-live} on ${qby:--}"
    [ -n "$qreq" ] && [ "$qreq" != "-" ] && who="$who, requested by $qreq"
  fi
  say "$p/$ck: rebuild already in flight (job $jobid$who) — waiting"
  [ "$external" = external ] || return 0
  st=$(br_load "$p" "$ck")
  has=$(printf '%s' "$st" | jq -r --arg i "$jobid" '[.attempts[]? | select((.detail // "") | contains("external job \($i)"))] | length' 2>/dev/null)
  # A jq THAT COULD NOT ANSWER IS NOT "already recorded" (BH-947 review N1): an
  # attempts list this jq chokes on printed nothing, and `[ "" != 0 ]` is true —
  # which skipped the one attempt that lets br_from_rebuilds consume the build.
  # Unreadable falls through and records; the dedupe above it is the same shape.
  [ "${has:-0}" = 0 ] || return 0
  br_record "$p" "$ck" rebuild-fresh "external-rebuild-wait" \
    "a build of $ck is already running (external job $jobid, not enqueued by this lane) — waiting for its RESULT"
}

# br_enqueue_dup_race <project> <cap-key> <ticket-key>
#   THE ENQUEUE ANSWERED `duplicate` THOUGH THE PRE-CHECK SAW NOTHING LIVE —
#   somebody (a triage relaunch, a watchdog requeue) claimed the key between the
#   two calls. Re-probe the queue so the hold names the REAL job id and the
#   external attempt is recorded on THIS tick; that attempt is what later lets
#   br_from_rebuilds consume that build's RESULT instead of starting another
#   build on top of it.
#
#   `inflight_rc` is LOCAL AND ZEROED here on purpose (BH-947 review I3). The
#   callers reach this arm only with a non-zero rc from their own pre-check, and
#   `|| inflight_rc=$?` assigns ONLY when the probe fails — so re-using their
#   variable made a SUCCESSFUL re-probe read as a failed one and the hold always
#   fell through to the id-less `@duplicate-race` branch.
#
#   Always rc 3: a duplicate answer is a wait, never a rung that ran.
br_enqueue_dup_race() {
  local p="$1" ck="$2" tkey="$3" row enq jobid external inflight_rc=0
  row=$(br_rebuild_inflight "$p" "$tkey" 2>/dev/null) || inflight_rc=$?
  if [ "$inflight_rc" = 0 ]; then
    # THE LEDGER IS KEYED ON enqueued_at, not on the id: the id this lane minted
    # carries a ~rN suffix the worker's row has never seen, so matching on the
    # whole string would read every one of our own builds as somebody else's.
    enq=$(printf '%s' "$row" | cut -f2)
    jobid=$(br_job_for_enq "$(br_load "$p" "$ck")" "$enq")
    external=""; [ -n "$jobid" ] || { jobid="$tkey@${enq}"; external=external; }
    br_rebuild_wait "$p" "$ck" "$jobid" "$external" "$row"
    return 3
  fi
  # The queue could not be read back (an outage, or a box with no reader): hold
  # anyway — the one thing we know is that a live build already covers this key.
  # THE ATTEMPT IS STILL RECORDED, under the placeholder id (BH-947 review I2).
  # Without it the row's last non-hold attempt is not `rebuild-fresh`, so
  # br_from_rebuilds does not poll this ticket at all and the raced build's
  # RESULT is never consumed: the next readable tick reads the row as `done`,
  # finds the cap unspent and buys a second build on top of a finished one. The
  # `has` dedupe in br_rebuild_wait keeps it to one attempt per episode, and
  # br_from_rebuilds' queue-row fallback accepts a `done` row against this exact
  # placeholder — the next tick that CAN read the row rewrites `wait_job` with
  # the real id.
  say "$p/$ck: duplicate enqueue race — holding (job id unknown)"
  br_rebuild_wait "$p" "$ck" "$tkey@duplicate-race" external
  return 3
}

REPOS="${REPOS_ROOT:-/root/repos}"
LOG="$H/logs/blocked-resolver.log"
ST="$H/state/blocked-resolver"
NOTES="$H/state/build-notes"
mkdir -p "$ST" "$NOTES" 2>/dev/null
MAX_REBUILDS="${BR_MAX_REBUILDS:-3}"
# THE ONE KNOB AN OPERATOR HAND-EDITS ON THE HUB, and until BH-1457 the only one
# on this line with no numeric guard (STARVE_SECS, REBUILD_CAP and TICK_MAX all
# have one). `BR_PER_TICK=abc` used to survive every comparison in the tick loop
# — they are all `[ "$N" -ge "$PER_TICK" ]`, which is an error, not a crash —
# until the arithmetic added by this ticket evaluated it, and `$(( PER_TICK + …))`
# on a non-number EXITS THE SHELL under `set -u`: after the pre-pass had written
# its retire events and flags, before any rung, with no tick line and no ALERTS
# line to say a tick had died. A typo is a fallback and a log line, never that.
#
# 0 IS LEGAL HERE (the registry says "0 makes every tick a no-op"), so this is
# not br_knob_num, which treats an explicit 0 as a typo. The bad value is kept
# and said out loud below, where say() exists.
PER_TICK="${BR_PER_TICK:-4}"
PER_TICK_BAD=""
case "$PER_TICK" in
  ''|*[!0-9]*) PER_TICK_BAD="$PER_TICK"; PER_TICK=4 ;;
esac
# How long a project with candidates may go unlooked-at before ONE alert says so
# (BH-980). A typo is never a page every ten minutes: a non-numeric value falls
# back to the default, the same way br_per_tick_for treats a bad share.
STARVE_SECS="${BR_STARVE_ALERT_SECS:-3600}"
case "$STARVE_SECS" in ''|*[!0-9]*) STARVE_SECS=3600 ;; esac
# HOW LONG A STORED FAMILY RULING MAY BE CARRIED (BH-1468). The reader is
# bin/lib/br/opt/family.sh (#1471), which does not exist yet — the knob is
# resolved HERE, in the lane, for two reasons: the lanes registry refuses a knob
# whose lane script never names it (a knob nothing reads is a phantom), and the
# console has to be able to explain the setting before the module lands. The
# module reads the resolved value out of the environment it is sourced into, so
# a typo is corrected once, here, rather than in every module that reads it.
# 0 = a ruling never expires.
BR_FAMILY_TTL_SECS="${BR_FAMILY_TTL_SECS:-0}"
case "$BR_FAMILY_TTL_SECS" in ''|*[!0-9]*) BR_FAMILY_TTL_SECS=0 ;; esac
# A RUNG BUDGET IS NOT A POOL-BUILD BUDGET (BH-1457). PER_TICK bounds RUNGS, and
# the rebuild rung is the most expensive one on the board — plan + execute +
# review, a whole pool machine. When BR_PER_TICK was raised from 4 to 50 on the
# hub (2026-09-22) it silently became permission for 50 fresh pool builds inside
# one ten-minute tick. This is the second bound: counted across the fleet, per
# tick, and enforced at the dispatch in br_one rather than at discovery, because
# only the dispatch knows which rung the ladder actually resolved to.
#
# THE DEFAULT IS TODAY'S DEFAULT RUNG BUDGET, deliberately. At BR_PER_TICK=4 a
# tick could never buy more than four rebuilds anyway, so a fleet at defaults
# behaves byte for byte as it did and this cap bites only where the budget was
# raised. 0 means no rebuild rung fires at all; every other rung still runs.
REBUILD_CAP="${BR_REBUILDS_PER_TICK:-4}"
case "$REBUILD_CAP" in ''|*[!0-9]*) REBUILD_CAP=4 ;; esac
# HOW LONG ONE TICK MAY GO ON STARTING RUNGS (BH-1457; the operator, 2026-09-22 15:03Z).
# The 14:04Z hub tick ran 12 rungs and took 53 MINUTES, and every ten-minute
# cron in between exited on "another tick is live" — so raising the rung budget
# bought latency rather than throughput. Rungs are serial and cannot simply be
# made concurrent (the reasons are at the tick loop), so the answer is a bound
# on the TICK plus a rung budget that is carried forward rather than lost.
#
# IT CAN ONLY STOP THE TICK BETWEEN RUNGS. A fix round holds its machine for up
# to BR_FIX_LANE_TIMEOUT (5400s) and is never interrupted; this decides whether
# the NEXT rung starts. 1800 is three cron periods. 0 is no cap at all, which is
# the pre-BH-1457 loop exactly.
TICK_MAX="${BR_TICK_MAX_SECS:-1800}"
case "$TICK_MAX" in ''|*[!0-9]*) TICK_MAX=1800 ;; esac
# THE LADDER'S CAPS, one per rung and all counted on the TICKET (br_cap_key).
# BR_LADDER=0 restores exactly the pre-2026-09-15 behaviour: every branch reason
# goes straight to REBUILD FRESH and head-not-reapproved straight to a fix round
# (read where it is decided, in br_action, so the extracted classifier answers
# the same thing the lane does).
MAX_MECHANICAL="${BR_MAX_MECHANICAL:-1}"
MAX_FIXROUNDS="${BR_MAX_FIXROUNDS:-1}"
# THE REGENERATE RUNG, rung 1b (BH-950.2). Read by br_regen_ladder and
# br_regen_rung: a ci-red park whose mechanical rung is spent is offered ONE
# more tokenless merge of origin/main (mc_rebase) before an agent fix round is
# bought. mc_rebase regenerates the generated-files table on the way through
# ONLY once #969 lands; on today's main it is a plain re-merge, so a park with
# nothing to merge pays a clone and falls through to its ladder answer in the
# same tick. The default stays 1 because the #968 contract pins it there
# (tests/merge-conductor-lib.bh-968-test.sh); 0 restores the pre-BH-950 dispatch
# exactly.
#
# WHAT BOUNDS WHAT, precisely — the two are not the same bound:
#   br_regen_offered (head8 dedup) is what bounds mc_rebase CALLS: at most one
#     per ticket per distinct head, whatever the counter says.
#   BR_MAX_REGEN bounds LANDED regenerates per ticket — the regens counter is
#     bumped only by an arm that actually pushed (rc 0/5 with a new head) or
#     handed the branch to the pool (rc 6). A regen-noop, a conflict, a rejected
#     lease and a setup failure spend nothing, by design: nothing was merged, so
#     a later head deserves the free merge again.
BR_REGEN_RUNG="${BR_REGEN_RUNG:-1}"
# A registry knob since BH-1940 (lane_env_apply above sets it). The 1 below only
# answers when lane-gate.sh or the registry could not run: a scratch tree.
MAX_REGEN="${BR_MAX_REGEN:-}"
case "$MAX_REGEN" in ''|*[!0-9]*) MAX_REGEN=1 ;; esac
# THE SMALL SHAPE'S CAPS (BH-579). A conflict of at most
# RESOLVER_SMALL_CONFLICT_LINES lines is worth a second agent round and is not
# worth three rebuilds; everything unmeasured keeps the large shape above.
# CONTESTED_PR_SCAN_MAX bounds what one hold creation may read: one PR list plus
# at most that many cached file lists.
MAX_FIXROUNDS_SMALL="${BR_CONFLICT_FIX_ROUNDS:-${BR_MAX_FIXROUNDS_SMALL:-2}}"
MAX_REBUILDS_SMALL="${BR_MAX_REBUILDS_SMALL:-1}"
SMALL_CONFLICT_LINES="${RESOLVER_SMALL_CONFLICT_LINES:-300}"
CONTESTED_SCAN_MAX="${CONTESTED_PR_SCAN_MAX:-40}"
# CONTESTED_TTL (21600 = 6h) is not read here: the contract stamps it into each
# hold at write time (mc_contested_write) and br_contested_sweep reads the ttl
# the hold itself carries, so a hold keeps the window it was written under.
# How much of a failing job's log rides into the fix round's prompt, per run, and
# how many failing runs are read. The log is the whole reason the fix round can
# answer a red CI at all, and an unbounded tail is a context bill.
CI_LOG_BYTES="${BR_CI_LOG_BYTES:-6000}"
CI_LOG_RUNS="${BR_CI_LOG_RUNS:-3}"
# The fix round runs the repo's own typecheck and unit suite in the FOREGROUND.
# 90 minutes is the lane timeout the operator specified; the agent call inside it gets
# less, so a hung model never eats the whole budget and leaves nothing for the
# verification that decides whether the push is safe.
FIX_LANE_TIMEOUT="${BR_FIX_LANE_TIMEOUT:-5400}"
# The claimer's stale-claim margin (bin/fix-round-claim.sh). The hub reads it
# only to page a claim older than FIX_LANE_TIMEOUT + this (br_fix_stale_claim).
FIX_HOP_MARGIN="${BR_FIX_HOP_MARGIN:-300}"
FIX_AGENT_TIMEOUT="${BR_FIX_AGENT_TIMEOUT:-3600}"
ADJ_TIMEOUT="${BR_ADJ_TIMEOUT:-1200}"
# The two models this lane runs are model_routes rows, asked PER PROJECT at the
# call (BH-1510.1): build.execute.fallback for a fix round, build.review for an
# adjudication. EXECUTE_MODEL / REVIEW_MODEL set in env still win, as they did
# when the fallback was a literal here. See br_model.
BR_EXECUTE_MODEL_ENV="${EXECUTE_MODEL:-}"
BR_REVIEW_MODEL_ENV="${REVIEW_MODEL:-}"

STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
say()   { echo "$(STAMP) $*" >> "$LOG"; }

# br_model <env-value> <role> <project> — the model one call runs: the env
# override when there is one, else the project's route. rc 75 = no route (the
# resolver has written the ALERTS line; a missing resolver is the same answer).
# The caller does not buy the call — a rung with no model is a rung not run,
# offered the same head again next tick.
br_model() {
  [ -n "${1:-}" ] && { printf '%s' "$1"; return 0; }
  command -v model_for >/dev/null 2>&1 || return 75
  model_for "$2" "$3"
}

# br_count <token> — ONE counted thing, appended to this tick's ledger.
#
# WHY A FILE AND NOT A VARIABLE (BH-1468). Every row is dispatched inside a
# subshell (the per-key flock below), so `BR_N_CARRIED=$((BR_N_CARRIED + 1))` at
# the site that did the work dies with that subshell and the tick line reads 0
# for ever. TICK_COUNTS is the same shape TICK_DONE and TICK_REBUILDS already
# have: a mktemp made once per tick, removed by the EXIT trap. A tick that could
# not make one counts nothing and says so once, where the file is made — never
# here, which runs per rung.
#
# The tokens are `llm`, `carried`, `mechanical` and `family`. `llm` is this
# slice's; the other three are written by the optional modules at the site that
# did the thing, which is why this is part of the hook contract in
# bin/lib/br/opt/README.md rather than a private helper.
br_count() {
  [ -n "${TICK_COUNTS:-}" ] || return 0
  printf '%s\n' "${1:-}" >> "$TICK_COUNTS" 2>/dev/null || true
  return 0
}

# br_quiet <class> — this row ends on a quiet exit (BH-5946). With
# bin/lib/br/opt/unchanged.sh loaded it stores the row's local fingerprint, so
# the next run can skip the row while nothing changed; without it, nothing.
# The row is BR_ROW, set in br_one once the cap key is known.
br_quiet() {
  command -v br_opt_unchanged_mark >/dev/null 2>&1 && br_opt_unchanged_mark "${1:-}" ${BR_ROW[@]+"${BR_ROW[@]}"}
  return 0
}

# THE THREE BOUNDS THAT TURN A RETRY-FOREVER PARK INTO A STALLED ONE (BH-1122),
# read here rather than beside the knobs above because a typo has to be able to
# SAY so and say() is the line above. An explicit 0 is treated as a typo too: on
# the two stall knobs it would stall on the first failure, which is not a bound
# anybody asked for, and on the streak it would page every tick.
br_knob_num() { # br_knob_num <name> <value> <default> -> a usable count
  case "${2:-}" in
    '')            printf '%s' "$3" ;;
    0|*[!0-9]*)    say "$1='$2' is not a usable count — using $3"; printf '%s' "$3" ;;
    *)             printf '%s' "$2" ;;
  esac
}
# After this many consecutive enqueue failures with the SAME reason, the park
# stops spending rungs (br_stall). 3 is half an hour of */10 ticks — long enough
# that a jobs client restarting is never a page, short enough that nothing
# retries a dead answer 79 times (project-4 TK-1674, 2026-09-20).
ENQUEUE_FAIL_MAX=$(br_knob_num BR_ENQUEUE_FAIL_MAX "${BR_ENQUEUE_FAIL_MAX:-}" 3)
# ...and the same bound on an adjudication that keeps coming back with no
# verdict. Its own knob rather than the one above: a variable named ENQUEUE
# governing the review rung is the kind of thing an operator reads once, wrong.
ADJ_NOVERDICT_MAX=$(br_knob_num BR_ADJ_NOVERDICT_MAX "${BR_ADJ_NOVERDICT_MAX:-}" 3)
# How many ticks in a row may end on `reason=budget` before ONE line says this
# lane has more parks than rungs. 12 is two hours of */10 ticks.
SATURATED_TICKS=$(br_knob_num BR_SATURATED_TICKS "${BR_SATURATED_TICKS:-}" 12)
# The rung budget's own typo, said here because say() did not exist where the
# value is read. One line per tick, which is what a wrong knob deserves.
[ -n "$PER_TICK_BAD" ] && say "BR_PER_TICK='$PER_TICK_BAD' is not a usable count — using $PER_TICK"

# BH-1372: pool routing from the BH-1369 routing contract when the client is
# loaded (its reader syncs the row, then answers from the files); the bare file otherwise.
br_pool_routed() { if command -v routing_builder >/dev/null 2>&1; then [ "$(routing_builder "$1" 2>/dev/null)" = pool ]; else ( . "$H/bin/lib/flag-on.sh" 2>/dev/null || flag_on() { [ -f "$H/flags/$1-$2" ]; }; flag_on fly-pool "$1" ); fi; }
flag_on() { if command -v flag_active >/dev/null 2>&1; then flag_active "$1"; else [ -f "$H/flags/$1" ]; fi; }
if lane_switch blocked-resolver-disabled; then
  [ "$BR_FIX_HERE" = 1 ] && echo "FIX_RESULT box-paused $(printf 'blocked-resolver-disabled on %s' "$(hostname 2>/dev/null || echo the owning box)" | base64 -w0)"
  exit 0
fi
# BH-1627: ONE routing read per tick. br_pool_routed runs per PR; after this sync
# the client answers every one of them from the files without another request
# (knob off: no request at all). An outage leaves the files as they are.
command -v routing_sync_all >/dev/null 2>&1 && { routing_sync_all >/dev/null 2>&1 || true; }
OBSERVE=0
flag_on blocked-resolver-observe && OBSERVE=1
# The fleet kill switch stops every lane that WRITES to GitHub or launches
# builds. This lane does both, so it honors it — classification still runs so
# the log keeps saying what it WOULD have done while the fleet is paused.
flag_on automerge-disabled && OBSERVE=1

ONLY="${1:-}"
# The shared per-project lane runner (BH-5913): the dispatcher's pl_dispatch and
# a dispatched run's pl_unlock. A box mid-sync without it still scans: a project
# run then takes the same lock file itself, below.
# shellcheck source=bin/lib/project-lanes.sh
[ -r "$H/bin/lib/project-lanes.sh" ] && . "$H/bin/lib/project-lanes.sh"

# >>> resolver cron single-flight
# ONE SCAN AT A TIME, AND THE LOCK IS GONE BEFORE THE FIRST RUNG. Cron fires
# this lane every ten minutes and the ticks stacked: several live at once,
# rediscovering the same parks and racing each other's counters. So the SCAN —
# discovery, classification, the merged guard — runs under one lock, taken with
# `flock -n` and never waited on: an overlapping tick exits, it does not queue
# (the operator, 2026-09-13, "we never lock and serialize").
#
# The release is br_cron_unlock, called at the top of br_one's dispatch, i.e.
# BEFORE any rung. A fix round holds its per-key lock for up to 90 minutes, and
# a lane-wide lock held across that would stop the whole fleet's drain behind
# one slow build — the very thing the per-key locks exist to avoid. flock lives
# on the open file description, so the unlock inside the per-key subshell
# releases the parent's lock too, and closing fd 8 there keeps any child the
# rung spawns from inheriting it.
#
# This line goes to STDOUT, which is the cron log, and it is NOT an alert: two
# ticks overlapping is the normal shape of a lane that sometimes runs long.
# A --fix-here run is one round the hub already admitted, not a scan: it takes
# no lock, so a box's own tick never turns the hub's round away (BH-594).
# The dispatcher holds no lock: it only forks the runs, and each run locks its
# own project.
if [ "$BR_FIX_HERE" = 1 ] || [ "$BR_DISPATCH" = 1 ]; then
  br_cron_unlock() { :; }
else
# A ONE-PROJECT RUN TAKES ITS PROJECT'S LOCK (BH-5913). `blocked-resolver.sh
# <project>` is the unit bin/lib/project-lanes.sh starts, one per project, on
# locks/blocked-resolver-<project>.lock. A whole-fleet scan that ran 55 minutes
# on one project's rows used to turn every other project away. Two runs share
# no row outside their own project, and the per-key locks keep two rounds off
# one park, so a run locks only its project: a second run of the SAME project
# still exits here. Under the runner the lock is already held (PL_LOCK_FD) and
# br_cron_unlock releases it the same way, before the first rung. A run with no
# project (an operator's whole-fleet scan) keeps the fleet scan lock.
if [ -n "$ONLY" ]; then
  case "$ONLY" in
    .*|*[!A-Za-z0-9._-]*)
      echo "$(STAMP) blocked-resolver: '$ONLY' is not a project name — exiting without a scan" >&2
      exit 2 ;;
  esac
fi
BR_SCAN_LOCK=blocked-resolver-cron.lock
[ -z "$ONLY" ] || BR_SCAN_LOCK="blocked-resolver-$ONLY.lock"
if [ -n "$ONLY" ] && [ "${PL_LANE:-}" = blocked-resolver ] && [ "${PL_PROJECT:-}" = "$ONLY" ] \
   && command -v pl_unlock >/dev/null 2>&1 && [ -n "${PL_LOCK_FD:-}" ] \
   && { : >&"$PL_LOCK_FD"; } 2>/dev/null; then
  br_cron_unlock() { pl_unlock; }
else
  exec 8>"$H/locks/$BR_SCAN_LOCK"
  if ! flock -n 8; then
    echo "$(STAMP) blocked-resolver: another tick is live (locks/$BR_SCAN_LOCK held) — exiting without a scan"
    exit 0
  fi
  br_cron_unlock() { flock -u 8 2>/dev/null; exec 8>&-; }
fi
fi
# A HUB RUN OF ONE PROJECT FIRST TAKES IN WHAT A LANE MACHINE WROTE (BH-6128).
# A project that ran on Fly has write-backs in the jobs worker; the hub
# publisher applies them every ten minutes, and this applies them now, so a
# lane moved back to the hub never starts on state older than the machine's.
# Only for a project the publisher has seen; a failure is one line and the run
# goes on.
if [ -n "$ONLY" ] && [ -z "${LANE_RUN_ID:-}" ] && [ "$BR_FIX_HERE" != 1 ] && [ "$BR_DISPATCH" != 1 ] \
   && [ -d "$H/state/lane-run-inputs/blocked-resolver/$ONLY" ] && command -v lri_apply_pending >/dev/null 2>&1; then
  BR_PRE_APPLY=$(lri_apply_pending blocked-resolver "$ONLY" 2>&1) \
    || say "$ONLY: the lane machine's write-backs were not all applied before this run ($BR_PRE_APPLY) — the publisher retries them"
fi
# WHEN THIS TICK BEGAN (BH-1457). Taken HERE, the instant the tick knows it is
# the tick, and not at the top of the rung loop: discovery is part of what a
# tick spends, and on a fleet with 785 candidates it is a real share of it. The
# only reader is the wall-clock bound in the loop below.
TICK_START=$(date -u +%s)
# WHETHER THIS SHELL HAS THE CLOCK BUILTIN. The wall bound below is read once per
# candidate — 785 times on the hub — and `$(date -u +%s)` is a fork each time,
# spent in the one stretch of the tick the bound itself cannot stop. bash 5 has
# $EPOCHSECONDS; this records whether it does, once, and the fork is the fallback
# for a shell that does not. It is NOT written as ${EPOCHSECONDS:-…} on purpose:
# that shape is what tests/lanes-registry-test.sh §7 reads as an operator knob,
# and a bash builtin is not one.
BR_HAVE_EPOCH=0
[ -n "${EPOCHSECONDS+x}" ] && BR_HAVE_EPOCH=1
# br_now — this second, without a fork where the shell can answer.
br_now() {
  if [ "$BR_HAVE_EPOCH" = 1 ]; then printf '%s' "$EPOCHSECONDS"; else date -u +%s; fi
}
# <<< resolver cron single-flight
# Lane liveness (BH-638): optional exactly like the libs above, so a box whose
# harness sync has not landed the lib runs this lane unchanged. The expected-by
# is FIX_LANE_TIMEOUT, the longest one tick may take. THE RHYTHM IS A THIRD OF
# THAT and has to be: the reaper calls a lane silent at interval x HB_STALE_MULT
# (3), and this lane's only tick is the per-candidate one below, BEFORE the
# per-key subshell — inside it a fix round blocks synchronously with no chance
# to tick, so a fixed 600s rhythm would page "silent" on every long fix round.
# Derived, never a literal: BR_FIX_LANE_TIMEOUT is an operator knob.
# shellcheck source=bin/lib/heartbeat.sh
[ -r "$H/bin/lib/heartbeat.sh" ] && . "$H/bin/lib/heartbeat.sh"
command -v hb_tick >/dev/null 2>&1 || { hb_start(){ :; }; hb_tick(){ :; }; hb_done(){ :; }; }
HB_RHYTHM=1
case "$FIX_LANE_TIMEOUT" in ''|*[!0-9]*) ;; *) [ "$((FIX_LANE_TIMEOUT / 3))" -gt 1 ] && HB_RHYTHM=$(( FIX_LANE_TIMEOUT / 3 )) ;; esac
# The watchdog expects this lane on the hub only; a box running one --fix-here
# round must not start a heartbeat it will never tick (BH-594).
[ "$BR_FIX_HERE" = 1 ] || hb_start blocked-resolver "$HB_RHYTHM" "$FIX_LANE_TIMEOUT" "the drain of parked PRs"

# >>> resolver modules
# BH-1176: this lane is becoming a shim over bin/lib/br/. It is 3,778 lines that
# 19 of the last 200 merges touched, and it and its suite were two of the five
# files behind 40 of one day's 53 merge conflicts — two builds that touch two
# unrelated concerns conflict in a file neither ticket is about. The sections
# move out one slice at a time: ladder.sh (the classifier) and record.sh (the
# per-key json) first, the discovery reads, the gates and the rungs after.
#
# LADDER AND RECORD ARE CUT (BH-5241). ladder.sh is the only copy of the
# classifier and of br_regen_rung, and record.sh is the only copy of the
# per-key json layer, so both are load-bearing. tests/br-split-layout-test.sh
# case 4 holds every mapped name absent from this file;
# tests/br/driver-ceiling.tsv caps its size.
#
# Modules resolve off $H, the way bin/run-triage.sh resolves bin/lib/rt and
# bin/run-build.sh resolves bin/lib/rb. A SCRIPT has a harness root; only a
# LIBRARY (bin/lib/merge-conductor-lib.sh, which is sourced from anywhere) has
# to resolve bin/lib/mc off BASH_SOURCE. It matters here: the mutation block in
# tests/blocked-resolver-rest.bh-783-test.sh runs a sed-mutated COPY of this
# script out of its own directory, and a BASH_SOURCE lookup would send that copy
# looking for modules that were never beside it.
#
# A module it cannot READ, or one it reads and cannot USE, is a REFUSAL and not
# a shrug. Boxes take bin/ through `rsync -a` per FILE (bin/harness-sync.sh), so
# a tick that fires mid-sync can see this script new and a module missing or
# half written. Sourcing garbage and carrying on would drain parks with half a
# classifier — every park answered `none`, nothing fixed, and a log line that
# reads exactly like a quiet tick.
BR_LIB_DIR="$H/bin/lib/br"
BR_MODULES="discovery keys ladder record cap"
for _br_m in $BR_MODULES; do
  # shellcheck source=/dev/null
  if [ -r "$BR_LIB_DIR/$_br_m.sh" ] && . "$BR_LIB_DIR/$_br_m.sh"; then continue; fi
  HARNESS="$H" "$H/bin/alert-line.sh" "RESOLVER MODULE MISSING: bin/lib/br/$_br_m.sh is missing or unusable on $(hostname) — the box's bin/ is half-synced; no park was drained this tick"
  echo "blocked-resolver: bin/lib/br/$_br_m.sh is missing or unusable — refusing the tick" >&2
  exit 1
done
unset _br_m
# THE OPTIONAL LOOP (BH-1468), and it is the OPPOSITE of the required one above.
# A box that has no bin/lib/br/opt/ at all is the NORMAL box — the modules are
# shipped by #1470 (carry an unchanged verdict / rebase a derived-only conflict)
# and #1471 (family-batched iron-law adjudication), and until they land every
# hook below is undefined and the lane does exactly what it does today. So
# absent is SILENT, not an alert and not an exit: paging a hub every ten minutes
# for a file nobody has written yet is how an alert log stops being read.
#
# Fail-open on the two ways a half-synced module can arrive. bin/ reaches a box
# through `rsync -a` per FILE (bin/harness-sync.sh, which already recurses into
# bin/lib/br/opt/ — no sync change is needed for these), so a tick can see a
# module that does not parse or one whose source dies part-way. Either is ONE
# log line and today's path for the rest of the tick; sourcing garbage and
# carrying on is what the required loop refuses, and here there is nothing to
# refuse because the lane's own rungs are all still there.
#
# BR_OPT_OFF is the ONE kill switch for every optional rung: a comma list, no
# spaces, of module names to leave unsourced. Per-behaviour flags are
# deliberately not offered — an operator turning the seam off at 3am wants one
# word, not a table.
# external, extfix, extpark, extrebase are BH-4664's external-PR modules; the
# siblings that ship the last three may land after this list does, and a name
# whose file is absent is skipped silently, like every name here.
# parentprio is BH-5741: a BLOCKed parent with approved stacked children ranks
# above ordinary rows, and pages once when no fix round starts for it.
# profile, readmemo and unchanged are BH-5946: the run's `prof:` line, the
# per-run read memo and the unchanged-row skip.
# untouched is BH-5913: a project whose oldest park no run has looked at for
# BR_UNTOUCHED_ALERT_MIN pages once per episode.
BR_OPT_MODULES="mechanical family cirepair stale external extfix extpark extrebase parentprio untouched profile readmemo unchanged"
BR_OPT_OFF="${BR_OPT_OFF:-}"
for _br_o in $BR_OPT_MODULES; do
  case ",$BR_OPT_OFF," in *",$_br_o,"*) continue ;; esac
  _br_of="$BR_LIB_DIR/opt/$_br_o.sh"
  [ -r "$_br_of" ] || continue
  if ! bash -n "$_br_of" 2>/dev/null; then
    say "optional module bin/lib/br/opt/$_br_o.sh does not parse — skipped, this tick runs without it"
    continue
  fi
  # shellcheck source=/dev/null
  . "$_br_of" \
    || say "optional module bin/lib/br/opt/$_br_o.sh failed on source — skipped, this tick runs without it"
done
unset _br_o _br_of

# THE DISPATCHER STOPS HERE (BH-5913): it needed only the libraries above (the
# project hold gate among them). Nothing below this line runs in --dispatch.
# The runs are started by the shared per-project lane runner
# (bin/lib/project-lanes.sh): one detached `blocked-resolver.sh <project>` per
# project that is not held, no cap, each at a stable offset inside
# BR_DISPATCH_SPREAD_SECS (default 540, 0 = all at once). 540 keeps every start
# inside the 10-minute cadence.
if [ "$BR_DISPATCH" = 1 ]; then
  BR_DISPATCH_RC=0
  if ! command -v pl_dispatch >/dev/null 2>&1; then
    say "bin/lib/project-lanes.sh is not loaded — no project run started this dispatch"
    BR_DISPATCH_RC=1
  else
    BR_SPREAD="${BR_DISPATCH_SPREAD_SECS:-540}"
    case "$BR_SPREAD" in
      ''|*[!0-9]*) say "BR_DISPATCH_SPREAD_SECS='$BR_SPREAD' is not a number of seconds — the dispatch uses 540"
                   BR_SPREAD=540 ;;
    esac
    BR_DISPATCH_LINE=$(pl_dispatch blocked-resolver "$BR_SPREAD" "$H/bin/blocked-resolver.sh") || BR_DISPATCH_RC=$?
    say "$BR_DISPATCH_LINE"
  fi
  hb_done blocked-resolver
  exit "$BR_DISPATCH_RC"
fi
# <<< resolver modules

# br_note_conflict_lines <project> <cap-key> <n> — record a measurement, biggest
#   wins. A non-numeric n is not a measurement and is dropped rather than read
#   as zero, and NEITHER IS A ZERO: the sidecar of a delete/modify conflict
#   carries 0 (no markers to count), and a record that reads `conflict_lines: 0`
#   says "measured, tiny" to every later reader when the truth is "not
#   measurable". br_shape answers `large` for a 0 either way; this keeps the
#   fiction out of the record as well.
br_note_conflict_lines() {
  local n="${3:-}"
  case "$n" in ''|0|*[!0-9]*) return 0 ;; esac
  br_json_edit "$1" "$2" \
    '.conflict_lines = ([((.conflict_lines // 0) | if type == "number" then . else 0 end), ($n|tonumber)] | max)' \
    --arg n "$n"
}

# ---------------------------------------------------------------------------
# WHICH PATHS THIS TICKET KEEPS FIGHTING OVER (BH-579).
#
# TK-1529 was rebuilt three times and then ABANDONED, and every one of those
# rebuilds hit the same conflict on the same file: siblings kept landing edits
# to it while this ticket walked its ladder. Rebuilding against a path somebody
# else is still moving buys the same conflict again at full price. So every
# conflict this lane sees is remembered per (pr, head), and the second
# occurrence of one path under a DIFFERENT (pr, head) is a RECURRENCE.
# ---------------------------------------------------------------------------
# br_paths_of_reason <raw-reason> — the paths a park's reason names, one per
#   line. The raw string is whatever the conductor wrote:
#     conflict-unresolvable: a.txt src/b.ts
#     conflict-unresolvable: CONFLICT (content): Merge conflict in a.txt
#   so the filter is conservative on purpose — a token is a path only when it is
#   made of path characters, carries a `/` or a `.`, and does not end in `:`.
#   CONFLICT, (content):, Merge, in and Auto-merging never parse, and the legacy
#   line above answers `a.txt` and nothing else. Parking other people's PRs on
#   an invented path is the failure this filter exists to refuse.
br_paths_of_reason() {
  local raw="${1:-}" tok
  raw="${raw#conflict-unresolvable:}"
  printf '%s\n' "$raw" | tr '[:space:]' '\n' | while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    case "$tok" in
      *:)                 continue ;;
      *[!A-Za-z0-9_./-]*) continue ;;
      */*|*.*)            printf '%s\n' "$tok" ;;
    esac
  done | sort -u
}
# br_conflict_note <project> <cap-key> <pr-num> <head> <paths>
#   One entry per (pr, head): a park re-read on the next tick is the SAME
#   occurrence, and appending it again would turn one conflict into a
#   recurrence with itself. Missing pr, head or paths writes nothing at all.
br_conflict_note() {
  local p="$1" k="$2" num="${3:-}" head="${4:-}" paths="${5:-}" arr
  case "$num"  in ''|-) return 0 ;; esac
  case "$head" in ''|-) return 0 ;; esac
  [ -n "$paths" ] || return 0
  arr=$(printf '%s\n' "$paths" | sed '/^$/d' | jq -R . | jq -sc .) || return 1
  [ -n "$arr" ] && [ "$arr" != '[]' ] || return 0
  br_json_edit "$p" "$k" '
    if ((.conflicts // []) | any(((.pr|tostring) == $pr) and (.head == $head)))
    then .
    else .conflicts = ((.conflicts // []) + [{at:$t, pr:(($pr|tonumber?) // $pr), head:$head, paths:$paths}])
    end' --arg pr "$num" --arg head "$head" --arg t "$(STAMP)" --argjson paths "$arr"
}
# br_recurring_paths <json> <pr-num> <head> <paths> — the given paths that this
#   ticket ALREADY conflicted on under a different (pr, head). Exact string
#   match: src/a.ts and src/a.tsx are two files. Empty output = nothing recurred.
br_recurring_paths() {
  local st="${1:-}" num="${2:-}" head="${3:-}" paths="${4:-}" arr
  [ -n "$paths" ] || return 0
  arr=$(printf '%s\n' "$paths" | sed '/^$/d' | jq -R . | jq -sc .) || return 0
  [ -n "$arr" ] && [ "$arr" != '[]' ] || return 0
  printf '%s' "$st" | jq -r --arg pr "$num" --arg head "$head" --argjson want "$arr" '
    [ (.conflicts // [])[]
      | select(((.pr|tostring) != $pr) or (.head != $head))
      | (.paths // [])[] ] as $prev
    | $want | map(select(. as $p | $prev | index($p))) | unique | .[]' 2>/dev/null
}

# ---------------------------------------------------------------------------
# The ROUNDS LEDGER — which fix rounds are running right now, on this box.
#
# A fix round is one execute-stage agent call that can hold its worktree for 90
# minutes. Unbounded they are, across overlapping */10 ticks, why a hotfix park
# that arrives while three of them work waits for one of them to finish. The
# ledger is what makes "how many are running" answerable at all: one file per
# round, keyed on <project>-<cap-key>, which is the key the per-key flock below
# already makes unique — so two live rows for one ticket are unrepresentable.
#
# THE ONLY PRUNE RULE IS "the pid in this row is not alive", read at
# br_rounds_live time. Nothing sweeps later, because "later" is how a phantom
# slot outlives the box that died holding it.
# ---------------------------------------------------------------------------
BR_ROUND_FILE="${BR_ROUND_FILE:-}"
br_round_file() { echo "$ST/rounds/$(br_rkey "$1-$2").json"; }
# br_rounds_live — prunes dead/unreadable rows FROM DISK, then prints one TSV
# line per survivor: started_at <TAB> hotfix <TAB> file. The single reader, so
# the prune happens exactly once per read.
br_rounds_live() {
  local f pid at hot row
  [ -d "$ST/rounds" ] || return 0
  for f in "$ST/rounds"/*.json; do
    [ -e "$f" ] || continue
    row=$(jq -r '[(.pid|tostring),((.started_at//0)|tostring),((.hotfix//0)|tostring)] | @tsv' "$f" 2>/dev/null) || row=""
    IFS=$'\t' read -r pid at hot <<<"$row"
    case "${pid:-}" in ''|null|*[!0-9]*) rm -f "$f" 2>/dev/null; continue ;; esac
    if ! kill -0 "$pid" 2>/dev/null; then rm -f "$f" "${f%.json}.yield" 2>/dev/null; continue; fi
    case "${at:-}" in ''|null|*[!0-9]*) at=0 ;; esac
    [ "${hot:-0}" = 1 ] || hot=0
    printf '%s\t%s\t%s\n' "$at" "$hot" "$f"
  done
}
# THE FLEET'S REMOTE ROUNDS HOLD SLOTS TOO (BH-2674). A round the hub queued
# for a box has no pid row here, so the queued + claimed fix_round_jobs rows
# are added in. Read ONCE per tick (br_remote_open_prime, before the drain) and
# inherited by every per-key subshell. An unreadable count is 0 and said: the
# cap fails open, exactly as the local ledger does.
BR_REMOTE_OPEN=0
br_remote_open_prime() {
  local n
  BR_REMOTE_OPEN=0
  command -v hub_box_builds_here >/dev/null 2>&1 && ! hub_box_builds_here || return 0
  command -v fix_round_open_count >/dev/null 2>&1 || return 0
  n=$(fix_round_open_count 2>>"$LOG") || n=""
  case "$n" in
    ''|*[!0-9]*) say "open fix rounds unreadable — slot cap fails open this tick" ;;
    *) BR_REMOTE_OPEN="$n" ;;
  esac
  return 0
}
br_rounds_running() { echo $(( $(br_rounds_live | wc -l) + ${BR_REMOTE_OPEN:-0} )); }
# br_round_begin <project> <cap-key> <hotfix 0|1> <rkey> — the row, written
# immediately before the agent call.
#
# $BASHPID, NOT $$: the round runs inside the per-key subshell and $$ there is
# still the tick's pid, so a row written with it would stay "live" after the
# round's subshell died and hold a slot until the whole tick ended.
br_round_begin() {
  local p="$1" ck="$2" hot="${3:-0}" rkey="${4:-}" f
  f=$(br_round_file "$p" "$ck"); mkdir -p "$(dirname "$f")" 2>/dev/null
  jq -nc --argjson pid "$BASHPID" --argjson t "$(date -u +%s)" --argjson h "${hot:-0}" \
    --arg p "$p" --arg ck "$ck" --arg rk "$rkey" \
    '{pid:$pid,started_at:$t,hotfix:$h,project:$p,ck:$ck,rkey:$rk}' > "$f.tmp" 2>/dev/null \
    && mv "$f.tmp" "$f" 2>/dev/null
  BR_ROUND_FILE="$f"
  # THE CAP FAILS OPEN. A ledger write that failed leaves the round running and
  # uncounted; a ledger that blocks work would be worse than a slot overrun.
  return 0
}
# ---------------------------------------------------------------------------
# THE FIX ROUND'S SCRATCH WORKTREE (BH-1363). The hub sat at 92% disk on
# 2026-09-22 holding 14 GB of leaked fix worktrees dated 09-17..09-20: 1.8-2.7 GB
# each, still registered, nothing running, the resolver idle. Two holes put them
# there and this helper closes both.
#
#   * The removal was UNCHECKED. Eleven call sites ran
#     `git worktree remove --force "$wt" >/dev/null 2>&1` and dropped the rc, and
#     that command genuinely fails (rc 128, directory untouched) on a LOCKED
#     worktree. A removal that failed read exactly like one that worked.
#   * Nothing owned the directory on an UNPLANNED exit. Removal happened only at
#     the eleven inline call sites; the per-key subshell's EXIT trap freed the
#     ledger row and nothing else, so a round that ended anywhere but one of
#     those eleven lines — a reboot, update-runners, an operator kill, the OOM
#     killer — left the whole checkout behind.
#
# BR_FIX_WT is set the moment the path is chosen, so the trap below has an owner
# even for a half-created tree. brfix/<ck> is NEVER touched here: that branch is
# the round's paid-for work and the reuse path at the top of br_fix_round starts
# from it, so dropping it buys the same agent tokens twice. Branch deletion
# stays exactly where it is today, on the terminal call sites.
BR_FIX_WT=""
BR_FIX_REPO=""
# br_wt_drop <why> [<repo> <worktree>] — remove a fix-round worktree and say so.
# With no path it drops the round's own and CLEARS it, so an explicit call
# followed by the trap removes once and logs once. rc 0 = the directory is gone,
# and no call site ever reads it: a cleanup result never rewrites a verdict.
br_wt_drop() {
  local why="${1:-the round ended}" repo="${2:-}" wt="${3:-}"
  if [ -z "$wt" ]; then
    wt="${BR_FIX_WT:-}"; repo="${BR_FIX_REPO:-}"; BR_FIX_WT=""
  fi
  [ -n "$wt" ] || return 0
  if [ ! -e "$wt" ]; then
    [ -n "$repo" ] && git -C "$repo" worktree prune >/dev/null 2>&1
    return 0
  fi
  if [ -n "$repo" ]; then
    git -C "$repo" worktree remove --force "$wt" >/dev/null 2>&1
    # -f -f is the documented override for a LOCKED working tree, and the only
    # reason this ladder has a second rung.
    [ -e "$wt" ] && git -C "$repo" worktree remove --force --force "$wt" >/dev/null 2>&1
  fi
  # ANCHORED. The last resort deletes a path under tmp/brfix/ and nothing else —
  # never the parent, never a path a caller happened to hand us.
  if [ -e "$wt" ]; then
    case "$wt" in "$H/tmp/brfix/"?*) rm -rf "$wt" 2>/dev/null ;; esac
  fi
  [ -n "$repo" ] && git -C "$repo" worktree prune >/dev/null 2>&1
  if [ -e "$wt" ]; then
    say "could NOT remove the fix-round worktree $wt ($why) — it is left for bin/disk-clean.sh to sweep"
    return 1
  fi
  say "removed the fix-round worktree $wt ($why)"
  return 0
}
# br_round_end — the row and its yield marker die together. Safe to call twice,
# which is what the EXIT trap relies on.
br_round_end() {
  [ -n "${BR_ROUND_FILE:-}" ] || return 0
  rm -f "$BR_ROUND_FILE" "${BR_ROUND_FILE%.json}.yield" 2>/dev/null
  BR_ROUND_FILE=""
  return 0
}
# br_yield_request <requesting-cap-key> — ask the OLDEST live PLAIN round for
# its slot. A marker on disk, never a signal and never a wait: this returns
# immediately and the hotfix park is re-offered next tick.
#
# A hotfix NEVER preempts a hotfix: if any live row is itself rank 0, no marker
# is written and the caller logs the ordinary deferral instead. rc 0 = a marker
# exists (written now or already there), rc 1 = nothing was asked.
br_yield_request() {
  local ck="$1" rows oldest
  rows=$(br_rounds_live | sort -s -t$'\t' -k1,1n) || return 1
  [ -n "$rows" ] || return 1
  printf '%s\n' "$rows" | awk -F'\t' '$2==1{found=1} END{exit found?1:0}' || return 1
  oldest=$(head -1 <<<"$rows" | cut -f3)
  [ -n "$oldest" ] || return 1
  # Idempotent: an existing marker is left exactly as it is.
  [ -e "${oldest%.json}.yield" ] && return 0
  printf 'requested_by=%s\n' "$ck" > "${oldest%.json}.yield" 2>/dev/null || return 1
  return 0
}
# br_yield_take <project> <rkey> <cap-key> <reason> <worktree> <where> — rc 0
# when THIS round was asked to yield and just did, rc 1 when it was not.
#
# A YIELD GIVES BACK THE SLOT AND NOTHING ELSE. The worktree goes; brfix/<ck>
# STAYS, so the reuse path above picks the work up next round and the tokens are
# bought once. No counter is bumped, no attempt is written, no state row is
# touched, no push and no PR comment happen — the ticket is exactly as pending
# as it was. And the agent process is NEVER signalled: the marker is only ever
# read between calls, so nothing is killed mid-write.
br_yield_take() {
  local p="$1" rkey="$2" ck="$3" reason="$4" wt="$5" where="$6" marker
  [ -n "${BR_ROUND_FILE:-}" ] || return 1
  marker="${BR_ROUND_FILE%.json}.yield"
  [ -e "$marker" ] || return 1
  [ -n "$wt" ] && br_wt_drop "the round yielded its slot" "$REPOS/$p" "$wt"
  mc_git_auth_clear 2>/dev/null
  # The EVENT line is written BEFORE the row and marker are removed: a crash
  # between them costs a duplicate event line, never a silent yield.
  br_event resolver_yield "$p" "$ck" "$reason" "gave its slot back to $(sed -n 's/^requested_by=//p' "$marker" 2>/dev/null | head -1 || true) at $where — brfix/$ck kept, no counter spent"
  br_round_end
  return 0
}

# ---------------------------------------------------------------------------
# Discovery. Each source prints TSV rows:
#   src <TAB> project <TAB> rkey <TAB> reason <TAB> pr-url <TAB> record <TAB> ticket-key
# "-" is the empty field everywhere, so a reader splitting on tabs never shifts.
# ---------------------------------------------------------------------------

# br_derive_ticket_key (bin/lib/br/keys.sh) sets these.
BR_TICKET_KEY=""
BR_KEY_SOURCE=""

# br_prov_promote <key> <row-head> — BH-3630. Prints `provenance-ci-red` when
#   the conductor's own detail for this park (mc_prov_detail_get, written by the
#   tick from the same words its page prints) is on the row's head and says
#   verdict=APPROVE ci=red. rc 1 otherwise, and what it prints then is WHY
#   (`verdict=- ci=pending`, `no conductor detail for head abc12345`).
#   No GitHub read: the conductor already paid for these words.
br_prov_promote() {
  local key="$1" head="${2:-}" line dh dv dc
  if ! command -v mc_prov_detail_get >/dev/null 2>&1 || ! line=$(mc_prov_detail_get "$key" 2>/dev/null); then
    echo "no conductor detail for head ${head:0:8}"; return 1
  fi
  IFS=$'\t' read -r dh dv dc _ <<<"$line"
  dh=$(printf '%s' "${dh:-}" | tr 'A-F' 'a-f'); head=$(printf '%s' "$head" | tr 'A-F' 'a-f')
  if [ -z "$head" ] || [ "$head" = - ] || [ "${dh:0:12}" != "${head:0:12}" ]; then
    echo "no conductor detail for head ${head:0:8}"; return 1
  fi
  if [ "${dv:-}" = APPROVE ] && [ "${dc:-}" = red ]; then
    echo provenance-ci-red; return 0
  fi
  echo "verdict=${dv:--} ci=${dc:--}"
  return 1
}

# br_unmapped <key> <raw-reason> <url> <unmapped|skip> [skip-why] — BH-3630. A
#   BLOCKED_HUMAN/RED_TWICE row no rung maps says so: one log line per PR per
#   BR_UNMAPPED_WINDOW_S and, for a reason nothing maps at all, ONE warn alert
#   per reason family per window. `skip` is a provenance park that was not
#   promoted: its line names why (br_prov_promote's words) and raises no alert, since
#   the conductor's re-review owns those shapes. A `hotfix-migration-hold:` row
#   is a skip too (BH-4149): the production-DB apply gate, which no agent rung
#   can take because no box holds prod DB credentials. The stamps are written before
#   the line and the alert (marked before sent). Always rc 0, observe mode
#   included: this reports a fact and acts on no PR.
br_unmapped() {
  local key="${1:-}" raw="${2:-}" url="${3:--}" mode="${4:-unmapped}" swhy="${5:-}" fam win now f last
  fam="${raw%%[: (]*}"; fam=$(br_rkey "$fam"); [ -n "$fam" ] || fam=unknown
  win="${BR_UNMAPPED_WINDOW_S:-21600}"
  case "$win" in ''|*[!0-9]*|0) win=21600 ;; esac
  now=$(date -u +%s)
  f="$ST/unmapped/$(br_rkey "$key").$fam"
  mkdir -p "$ST/unmapped" "$ST/unmapped-family" 2>/dev/null
  last=$(cat "$f" 2>/dev/null); case "$last" in ''|*[!0-9]*) last=0 ;; esac
  if [ "$(( now - last ))" -ge "$win" ]; then
    printf '%s\n' "$now" > "$f" 2>/dev/null
    if [ "$mode" = skip ] && [ "$raw" = provenance ]; then
      say "provenance-skip $key: ${swhy:-no promotable detail} — only verdict=APPROVE ci=red is the resolver's (ci-red ladder); left to the conductor's claude re-review: $url"
    elif [ "$mode" = skip ]; then
      say "$fam-skip $key: ${swhy:-no agent path} — no rung is offered and nothing is closed; the conductor keeps the row: $url"
    else
      say "unmapped-reason $fam $key: $raw — no rung maps this BLOCKED_HUMAN reason; the conductor still owns the page: $url"
    fi
  fi
  [ "$mode" = unmapped ] || return 0
  f="$ST/unmapped-family/$fam"
  last=$(cat "$f" 2>/dev/null); case "$last" in ''|*[!0-9]*) last=0 ;; esac
  [ "$(( now - last ))" -ge "$win" ] || return 0
  printf '%s\n' "$now" > "$f" 2>/dev/null
  [ -x "$H/bin/lane-alert.sh" ] && "$H/bin/lane-alert.sh" --severity warn --id "br-unmapped-$fam" blocked-resolver \
    "unmapped BLOCKED_HUMAN reason '$fam' (first seen on $key): bin/blocked-resolver.sh has no agent rung for it yet, so the conductor's page is its only owner until one is mapped in br_reason_of/br_ladder_class." \
    >/dev/null 2>&1
  return 0
}

# br_key_in_only's memo (bin/lib/br/keys.sh).
declare -A _BR_ONLY_REPO=()

# br_conductor_emit <key> <reason> <url> — the shared tail of both conductor
# sources: resolve the project, the build record, the branch and the ticket key,
# and print the candidate row. rc 1 when the key does not belong to a project
# this tick is handling.
# br_conductor_emit <key> <reason> <url> [parked-at]
#   The 4th argument (BH-1122) is the epoch this PR was parked — the conductor
#   row's own `since` field, or the hand-off record's timestamp on the recovery
#   path — and it rides out as an 8th tuple field so the drain can say how old
#   the oldest thing it did NOT reach is. Every other source prints 7 fields and
#   an absent 8th reads as "unknown", which is never treated as 0 (D11).
br_conductor_emit() {
  local key="$1" reason="$2" url="$3" parked="${4:--}" project rec br tkey kr
  # Conductor keys are owner/repository#PR, not fleet project names. Resolve
  # the registered slug so differently named repositories cannot disappear.
  project=$("$H/bin/project-of.sh" --repo "${key%#*}" 2>/dev/null) || project=""
  [ -n "$project" ] || return 1
  [ -z "$ONLY" ] || [ "$ONLY" = "$project" ] || return 1
  rec=$(mc_record_for "$url" 2>/dev/null || true); [ -n "$rec" ] || rec="-"
  br=$(br_pr_field "$url" .head.ref 'head branch'); [ -n "$br" ] || br=""
  # Discovery asks for no TITLE: this runs before br_one installs the repo's own
  # token, so a second gh call here buys an answer we may not be able to read
  # anyway. br_one asks again, inside the token, across every source.
  if kr=$(br_ticket_key "$project" "$rec" "$br" ""); then
    tkey="${kr%%	*}"
    say "$project/$(br_rkey "$key"): ticket key $tkey from $(br_key_source_phrase "${kr##*	}")"
  else
    tkey="-"
  fi
  tkey=$(br_tkey_sync "$project" "$(br_rkey "$key")" "$tkey")
  printf 'conductor\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$project" "$(br_rkey "$key")" "$reason" "${url:--}" "$rec" "$tkey" "${parked:--}"
}

# br_handoff_rows — the hand-offs the ROWS hold (BH-1388, BH-1025.3).
#
#   rc 1  the pr-state-rows flag is off, or either read was an OUTAGE. The
#         caller then greps the log, which is today's path exactly.
#   rc 2  the rows answered and hold no hand-off. The log is NOT consulted:
#         a real empty answer is an answer.
#   rc 0  with TSV, one line per (repo, number):
#           key <TAB> reason <TAB> url <TAB> head <TAB> since
#
# WHY IT EXISTS. logs/merge-conductor.log lives on ONE box. A rebuilt hub has
# no log and no state/merge-conductor/handoff file, so every open hand-off is
# forgotten and the parks sit until somebody notices. The rows outlive the box.
#
# WHY FIVE COLUMNS AND NOT THE LOG'S THREE. The recovery loop below needs the
# head the hand-off named, and on a rebuilt hub neither mc_handoff_file nor the
# pr-state.tsv row has one — so with three columns the loop's head guard would
# `continue` on every rows-sourced hand-off and this source could never emit.
# The head and the park's `since` ride along as columns 4 and 5; the log source
# still prints three and every guard below reads them as absent, as today.
#
# WHICH EVENTS COUNT: the NEWEST BLOCKED_HUMAN event per PR, kept only when the
# pr_state view says that PR's LATEST state is still BLOCKED_HUMAN (a park the
# conductor has since re-classified is the conductor's again), when the raw
# reason is one mc_handoff_owns — the same subset the conductor logs as "handed
# to bin/blocked-resolver.sh" — and when it is inside BR_HANDOFF_MAX_AGE_SECS.
# The reason is normalized through br_reason_of exactly as the row source above
# does, so the ladder reads the word it knows and a `contested:` loser (which
# br_reason_of answers empty for) is never offered a rung.
#
# TWO list GETs per tick, whatever the park count (D21).
#
# A FULL PAGE IS rc 1, NOT AN ANSWER (lead review N3). Each read is ONE page of
# $page rows. When either page comes back full there may be rows on a page this
# never read: an event for a PR, or (the dangerous one) the PR's latest state,
# whose absence would read as "no longer parked" and, at rc 2, silence the log
# too. So a full page is treated like an outage and the log answers, exactly
# as today, until this reader pages.
br_handoff_rows() {
  local cutoff since ev cur rc key raw reason at atsec seen=" " page=1000 n
  local repo num state esince ehead ereviewed eurl ealerted
  type pr_rows_on >/dev/null 2>&1 || return 1
  pr_rows_on || return 1
  cutoff=$(( $(date -u +%s) - ${BR_HANDOFF_MAX_AGE_SECS:-172800} ))
  since=$(date -u -d "@$cutoff" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || return 1
  ev=$(pr_state_events_page BLOCKED_HUMAN "$since" "$page"); rc=$?
  case "$rc" in 0) ;; 2) return 2 ;; *) return 1 ;; esac
  n=$(grep -c . <<<"$ev")
  [ "${n:-0}" -lt "$page" ] || return 1
  # The CURRENT state of every PR. rc 2 here means no PR has any state at all,
  # so none of them is still BLOCKED_HUMAN — a real empty answer, not an outage.
  cur=$(pr_state_page "$page"); rc=$?
  case "$rc" in 0) ;; 2) return 2 ;; *) return 1 ;; esac
  n=$(printf '%s' "$cur" | jq -r '(.rows // []) | length' 2>/dev/null)
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  [ "$n" -lt "$page" ] || return 1
  local -A latest=()
  while IFS=$'\t' read -r key state; do
    [ -n "$key" ] && latest["$key"]="$state"
  done < <(printf '%s' "$cur" | jq -r '(.rows // [])[] | "\(.repo)#\(.number)\t\(.state)"' 2>/dev/null)
  while IFS=$'\t' read -r repo num state esince ehead ereviewed raw eurl ealerted at; do
    [ -n "$repo" ] && [ -n "$num" ] || continue
    key="$repo#$num"
    # NEWEST FIRST is the verb's own ordering, so the first line per PR wins —
    # and the guard is set before every filter below, or a PR whose newest event
    # was re-classified away would be re-admitted by an older one.
    case "$seen" in *" $key "*) continue ;; esac
    seen="$seen$key "
    [ "${latest[$key]:-}" = BLOCKED_HUMAN ] || continue
    mc_handoff_owns "$raw" || continue
    reason=$(br_reason_of "$raw"); [ -n "$reason" ] || continue
    # A BELT ON THE AGE, in case the route ever filters `since` on a different
    # column than the one it reports. An `at` nobody can parse is NOT treated as
    # old — unknown is not out of range (D11).
    case "$at" in
      ''|-) ;;
      *) atsec=$(date -u -d "$at" +%s 2>/dev/null || echo "")  # determinism: ok date-empty-stamp ''|-) arm above handles empty
         [ -z "$atsec" ] || [ "$atsec" -ge "$cutoff" ] || continue ;;
    esac
    printf '%s\t%s\t%s\t%s\t%s\n' "$key" "$reason" "${eurl:--}" "${ehead:--}" "${esince:--}"
  done <<<"$ev"
}

# br_handoff_lines — every hand-off the conductor has LOGGED, newest line per PR:
#   "<key> BLOCKED_AGENT <reason>… — handed to bin/blocked-resolver.sh (…): <url>"
#   (and, since 2026-09-15, the same line with RED_TWICE in place of the display
#   word — a red-twice park is handed over in exactly this shape).
#   TSV: key <TAB> reason <TAB> url.
#
# THE ROW IS NOT THE ONLY RECORD (2026-09-14). A hand-off the conductor writes
# and then re-classifies away on its own next tick leaves a BLOCKED_HUMAN row for
# as little as 22 seconds — project-5 #759 handed off at 16:30:30Z, back to
# NEEDS_REBASE at 16:30:52Z; #749 handed off at 16:48:07Z, WAIT_CI at 16:50:26Z;
# project-7#438 handed off at 11:37Z, HEAD_MOVED at 11:39:56Z — and a lane that
# only reads rows misses all three. bin/merge-conductor.sh no longer re-flips a
# hand-off (mc_handoff_sticky), but rows parked before that shipped need
# recovering and a log line is the durable record of the hand-off.
#
# The `not paged` budget line is deliberately NOT matched: it is an age report on
# a row that IS still BLOCKED_HUMAN, which the row source already sees.
#
# ONE PROCESS PER CALL, NOT TWO PER LINE (BH-6044). The age test used to fork
# `date -d` for every matching line — 4,013 lines on 2026-10-11, in each of the
# 13 project runs. A stamp is `YYYY-MM-DD HH:MM:SS` UTC, so it orders as a
# string: the cutoff is rendered ONCE in that shape and awk compares. A stamp
# that is not a valid time of day is dropped, as the failed `date -d` dropped it.
br_handoff_lines() {
  local f="$H/logs/merge-conductor.log" cutoff cutstr
  [ -s "$f" ] || return 0
  cutoff=$(( $(date -u +%s) - ${BR_HANDOFF_MAX_AGE_SECS:-172800} ))
  cutstr=$(date -u -d "@$cutoff" '+%Y-%m-%d %H:%M:%S' 2>/dev/null) || return 0
  [ -n "$cutstr" ] || return 0
  grep -F 'handed to bin/blocked-resolver.sh' "$f" 2>/dev/null \
    | sed -nE 's#^([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8})Z ([^ ]+) (BLOCKED_AGENT|RED_TWICE) ([^ :]+).*(https://github\.com/[^ ]+)$#\1\t\2\t\4\t\5#p' \
    | awk -F'\t' -v c="$cutstr" '
        $2 == "" || $4 == "" { next }
        $1 !~ /^[0-9][0-9][0-9][0-9]-[01][0-9]-[0-3][0-9] [0-2][0-9]:[0-5][0-9]:[0-5][0-9]$/ { next }
        $1 < c { next }
        { last[$2] = $2 "\t" $3 "\t" $4 }
        END { for (k in last) print last[k] }'
}

# br_rereview_inflight <key> <head> — rc 0 when the conductor is re-reviewing
#   this PR right now, so the resolver must wait (BH-594): the row is back in
#   HEAD_MOVED, or the head-bound job for <head> is running, or its prompt is on
#   disk while the job file is not yet (the spawn window). A rung taken now
#   races that verdict — the TK-1669 shape. Local files only, no gh call. A
#   done, failed or stale job does not hold the park: the conductor has
#   answered, or will fail it into its own no-verdict park.
br_rereview_inflight() {
  local key="$1" head="${2:-}" jf
  [ "$(mc_row_field "$key" 2 2>/dev/null)" = HEAD_MOVED ] && return 0
  case "$head" in ''|-) return 1 ;; esac
  command -v mc_rr_file >/dev/null 2>&1 || return 1
  jf=$(mc_rr_file "${key%#*}" "${key##*#}" "$head")
  if [ -f "$jf" ]; then
    [ "$(mc_rr_state "$jf")" = running ] && return 0
    return 1
  fi
  [ -e "${jf%.json}.out.prompt" ] && return 0
  return 1
}

br_from_conductor() {
  local key st head rev al why url reason row seen=" " hhead
  local since parked breached ttl ttlbh ttlrt now age _breached _rank
  # The rows are read into an array FIRST: gh inside the loop must never eat the
  # loop's own stdin (the conductor learned this the expensive way).
  local rows=(); [ -s "$MC_ROWS" ] && mapfile -t rows < "$MC_ROWS"
  # OLDEST HAND-OFF FIRST (BH-1122). pr-state.tsv is in whatever order the rows
  # were written, so before this the park that had waited longest was whichever
  # one happened to be near the top of the file — hub #679 sat 434 minutes past
  # its TTL while younger rows took every rung of every tick. The rank is
  # (TTL-breached first, then oldest park), and the TTL is read through mc_ttl so
  # an MC_TTL_<STATE> override is honoured rather than hardcoded here.
  #
  # AN UNREADABLE `since` SORTS LAST, not first: a row whose park age nobody can
  # read is unknown, and unknown is not oldest (D11).
  local dec=() sorted=()
  now=$(date -u +%s)
  ttlbh=$(mc_ttl BLOCKED_HUMAN); ttlrt=$(mc_ttl RED_TWICE)
  for row in "${rows[@]:-}"; do
    [ -n "$row" ] || continue
    IFS=$'\t' read -r key st since head rev al why url <<<"$row"
    case "$st" in BLOCKED_HUMAN|RED_TWICE) ;; *) continue ;; esac
    [ -n "$key" ] || continue
    br_key_in_only "$key" || continue
    case "$st" in RED_TWICE) ttl="$ttlrt" ;; *) ttl="$ttlbh" ;; esac
    breached=1
    case "$since" in
      ''|*[!0-9]*) since=999999999999 ;;
      *) age=$((now - since))
         case "$ttl" in ''|-*|*[!0-9]*) ;; *) [ "$age" -ge "$ttl" ] && breached=0 ;; esac ;;
    esac
    dec+=("$breached	$since	$row")
  done
  if [ "${#dec[@]}" -gt 0 ]; then
    # -s, and it matters: without it sort's last-resort comparison falls back to
    # the whole LINE, so rows parked in the same second would be re-ordered by
    # their text — a park order that changes when somebody renames a repo.
    # Stable means "same age, same order as the file", which is what every
    # reader of this source assumed before there was an order at all.
    mapfile -t sorted < <(printf '%s\n' "${dec[@]}" | sort -s -t $'\t' -k1,1n -k2,2n)
  fi
  for row in "${sorted[@]:-}"; do
    [ -n "$row" ] || continue
    IFS=$'\t' read -r _breached _rank key st since head rev al why url <<<"$row"
    # RED_TWICE is a park this lane owns exactly like BLOCKED_HUMAN (2026-09-15):
    # the conductor cannot move a head whose CI is red after its one rerun, so
    # the row is read here on the same terms as every other park.
    case "$st" in BLOCKED_HUMAN|RED_TWICE) ;; *) continue ;; esac
    [ -n "$key" ] || continue
    br_key_in_only "$key" || continue
    reason=$(br_reason_of "$why")
    # A REASON NO RUNG MAPS IS SAID OUT LOUD (BH-3630). Before this a
    # `provenance` park (example-org/project-7#530) was dropped here without a
    # line. A provenance park the conductor saw APPROVE + ci=red on is promoted
    # onto the ci-red ladder and claimed; every other provenance shape and every
    # other unmapped reason logs why it was left to the conductor. A contested
    # loser stays silent: the loser skip owns it (BH-579). A migration hold is
    # logged and never alerted (BH-4149): it is the one gate that stays with a
    # person, the production-DB apply this file's header names.
    if [ -z "$reason" ]; then
      case "$why" in
        provenance)
          if reason=$(br_prov_promote "$key" "$head"); then
            [ "$OBSERVE" = 0 ] && command -v mc_resolver_claim >/dev/null 2>&1 \
              && mc_resolver_claim "$key" "$head" provenance-ci-red
          else
            br_unmapped "$key" "$why" "$url" skip "$reason"; continue
          fi ;;
        contested*) continue ;;
        hotfix-migration-hold*) br_unmapped "$key" "$why" "$url" skip "the production-DB migration gate (no agent path: no box holds prod DB credentials)"; continue ;;
        *) br_unmapped "$key" "$why" "$url" unmapped; continue ;;
      esac
    fi
    # DEDUPE BY (slug, num, head), the way every br_* source dedupes: one
    # candidate per PR per head, whichever source found it first.
    case "$seen" in *" $key@${head:--} "*) continue ;; esac
    seen="$seen$key@${head:--} "
    if br_rereview_inflight "$key" "$head"; then say "$key: re-review in flight on ${head:0:8}, resolver waits"; continue; fi
    # The ROW's `since` is the durable park age. The hand-off file's timestamp is
    # not: mc_handoff_record rewrites it on every re-kick, so a park that is
    # re-offered past its TTL would read as brand new on the tick it is oldest.
    case "$since" in ''|*[!0-9]*) parked="-" ;; *) parked="$since" ;; esac
    br_conductor_emit "$key" "$reason" "$url" "$parked" || continue
  done
  # AND THE HAND-OFFS WHOSE ROW HAS SINCE MOVED ON. Three guards, because a
  # rebuild is expensive and a wrong one is a duplicate build:
  #   - the PR is still OPEN (a merged one is never rebuilt — br_already_merged
  #     is the #304 guard and it still runs on every candidate below);
  #   - it is still on the head the hand-off named, so work somebody has already
  #     pushed on top of the refused head is left to the conductor's re-review;
  #   - the row is not at a terminal the resolver itself wrote (ABANDONED) or
  #     that says the work landed (MERGED).
  #
  # THE ROWS ARE READ FIRST (BH-1388). They outlive the box; the log does not.
  # The log is consulted only when the rows source answered rc 1 — the flag is
  # off, or a read was an outage — so a dark lane and an unreachable worker both
  # behave exactly as this loop did yesterday.
  local rowst prst parked hsrc hrc ehead esince
  hsrc=$(br_handoff_rows); hrc=$?
  case "$hrc" in
    0) : ;;                          # the rows answered, and they hold hand-offs
    2) hsrc="" ;;                    # the rows answered: there are none
    *) hsrc=$(br_handoff_lines) ;;   # flag off / outage: the log, exactly today
  esac
  while IFS=$'\t' read -r key reason url ehead esince; do
    [ -n "$key" ] && [ -n "$url" ] || continue
    br_key_in_only "$key" || continue
    rowst=$(mc_row_field "$key" 2)
    case "$rowst" in MERGED|CLOSED|ABANDONED|BLOCKED_HUMAN|RED_TWICE) continue ;; esac
    # ONE REST read for both fields. A 75 leaves both empty, so this hand-off is
    # simply skipped for the tick — never recovered on a state nobody read.
    read -r prst hhead <<<"$(br_pr_field "$url" \
      '"\(if .state=="closed" and .merged_at!=null then "merged" else .state end) \(.head.sha // "")"' \
      'pr state and head')"
    [ "${prst:-}" = open ] && [ -n "${hhead:-}" ] || continue
    # The head the hand-off named: the conductor's own record when it has one,
    # and otherwise the row's head field, which is the only head evidence a park
    # made before mc_handoff_record shipped ever wrote down.
    parked=$(cut -f2 "$(mc_handoff_file "$key")" 2>/dev/null)
    [ -n "$parked" ] && [ "$parked" != "-" ] || parked=$(mc_row_field "$key" 4)
    # ...and, on a rebuilt hub, neither of those exists: the EVENT ROW's own
    # head is the head the hand-off named (BH-1388). Empty for the log source,
    # which is why this is a third fallback and not a replacement.
    [ -n "$parked" ] && [ "$parked" != "-" ] || parked="${ehead:-}"
    [ -n "$parked" ] && [ "$parked" != "-" ] || continue
    [ "$parked" = "$hhead" ] || continue
    if br_rereview_inflight "$key" "$hhead"; then say "$key: re-review in flight on ${hhead:0:8}, resolver waits"; continue; fi
    case "$seen" in *" $key@$hhead "*) continue ;; esac
    seen="$seen$key@$hhead "
    say "$key: the conductor handed this off ($reason) and its row has since moved to ${rowst:--} — recovered from the hand-off $([ "$hrc" = 0 ] && echo rows || echo log) at ${hhead:0:8}"
    # The row this park came from has moved on, so the hand-off record's own
    # timestamp is the only park age left to read. Unreadable stays "-".
    parked=$(cut -f1 "$(mc_handoff_file "$key")" 2>/dev/null)
    # ...and when that file is gone too, the event row's own `since` (BH-1388).
    case "$parked" in ''|*[!0-9]*) parked="${esince:-}" ;; esac
    case "$parked" in ''|*[!0-9]*) parked="-" ;; esac
    br_conductor_emit "$key" "$reason" "$url" "$parked" || continue
  done <<<"$hsrc"
}

# br_rank_rows — the 7-column candidate TSV with the PRIORITY RANK prepended as
# a new first column, every other byte passed through untouched. The rank comes
# from the build record's own ticket-meta.json, which bin/run-build.sh already
# saved, so ordering the tick costs no GitHub call. A row with no record (the
# queue shape, rec '-') ranks 2: absent is not zero, and asking GitHub for the
# labels of every candidate every ten minutes is the API bill this lane already
# paid once.
#
# Fail-open: no hotfix-lib on the box and this is `cat`, which is discovery
# order — exactly today's behaviour.
#
# THE RANK IS priority_rank_meta's DOUBLED: 0 hotfix, 2 main-red, 4 plain. The
# odd value 3 is a BLOCKed parent with approved stacked children (BH-5741,
# bin/lib/br/opt/parentprio.sh): above every plain row, below main-red. Only a
# plain row is promoted. The column is stripped before anything else reads the
# row, so no other reader sees these values.
br_rank_rows() {
  command -v priority_rank_meta >/dev/null 2>&1 || { cat; return 0; }
  local src p rkey reason url rec tkey rank pn pnums
  while IFS=$'\t' read -r src p rkey reason url rec tkey; do
    [ -n "${rkey:-}" ] || continue
    rank=2
    case "${rec:--}" in
      -|'') ;;
      *) rank=$(priority_rank_meta "$rec/ticket-meta.json" "$H") ;;
    esac
    case "$rank" in ''|*[!0-9]*) rank=2 ;; esac
    rank=$((rank * 2))
    # An eight-wide row puts "tkey<TAB>parked" in tkey; the hook wants the key.
    if [ "$rank" = 4 ] && command -v br_opt_parent_children >/dev/null 2>&1; then
      IFS=$'\t' read -r pn pnums <<<"$(br_opt_parent_children "$p" "$rkey" "$reason" "$url" "${tkey%%$'\t'*}" </dev/null)"
      case "${pn:-}" in ''|*[!0-9]*) pn=0 ;; esac
      if [ "$pn" -gt 0 ]; then
        rank=3
        say "$p/$rkey [$reason]: PRIORITY parent — $pn approved child PR(s) wait on its branch ($pnums); ranked above ordinary rows, below main-red"
      fi
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$rank" "$src" "$p" "$rkey" "$reason" "$url" "$rec" "$tkey"
  done
}


# >>> br-reviews
# THE REVIEW LANE'S VERDICT, READ FROM GITHUB (BH-872) — the fifth source.
#
# bin/review-prs.sh reviews every open harness PR and posts its verdict as a
# review carrying one footer line. Until this source existed nothing consumed a
# REQUEST_CHANGES: the findings were posted, the PR was blocked, Mergify
# dequeued it because `github-review-approved` was false, and the next tick
# posted the same findings again. project-5 #2367 collected four of them.
#
# GITHUB IS THE LEDGER, not a state file: the review row carries the head it was
# submitted against (`commit_id`), so "is there a standing verdict on THIS head"
# is a question the API answers and no local cache can lose. The row must satisfy
# all three of:
#   * a harness VERDICT author (harness_verdict_author_match — any spelling; the
#     builders App opens pool PRs but never issues a verdict, BH-1668),
#   * the lane's own footer (a human's changes-requested is for a human),
#   * `commit_id` == the PR's current head (an older one has been answered by
#     whatever was pushed since).
# and then the BODY's own `VERDICT:` line must say REQUEST_CHANGES. The newest
# matching row wins, so an APPROVE posted after a block ends the park.
#
# BOUNDED (D21): behind gh_budget_low, and only PRs updated within
# BR_REVIEW_LOOKBACK_SECS (48h) have their reviews read at all. It is the LAST
# source in br_candidates, so conductor, queue and build parks are never starved
# out of PER_TICK by review candidates.
BR_REVIEW_FOOTER='Automated harness review (Fable) of '

# br_review_verdict <body> -> APPROVE|REQUEST_CHANGES|"" — the one shared reader
# bin/review-prs.sh uses on the same body (bin/lib/verdict-parse.sh, BH-1625):
# the anchored VERDICT line in the review's final block, the lane's footer
# (after the last `---`) dropped first. A body that quotes another verdict, or
# carries none, is "" — never APPROVE.
br_review_verdict() {
  local v
  v=$(printf '%s\n' "${1:-}" | verdict_parse -c -w 'APPROVE|REQUEST_CHANGES' 2>/dev/null) || return 0
  printf '%s\n' "$v"
}

# THE REVIEWS LIST, READ ONCE (BH-2200). The PR's reviews over the REST
# contract (bin/lib/gh-rest.sh; a plain call into a file, never `$( )`), 100 a
# page, oldest first (GitHub's order), as a compact JSON array of
# {l login, t user type, a author_association, c commit_id, s state, b body,
# id review id (BH-7123 wave B: br_cap_notes dismisses by it)}.
# Both pickers below read this one answer, so finding the lane's own verdict AND
# a lead's costs the same read the lane always made.
#   rc 0 the array on stdout ([] when the PR has none, or is gone: 404)
#   rc 2 THE READ FAILED (75, a non-array page, past 1000 reviews) — never "no review"
br_review_rows() {
  local slug="$1" num="$2" f acc='[]' page grc len
  f=$(mktemp "${TMPDIR:-/tmp}/br-reviews.XXXXXX") || return 2
  for page in 1 2 3 4 5 6 7 8 9 10; do
    grc=0; gh_rest GET "repos/$slug/pulls/$num/reviews?per_page=100&page=$page" > "$f" 2>/dev/null || grc=$?
    [ "$grc" = 44 ] && break
    if [ "$grc" != 0 ] || ! jq -e 'type == "array"' "$f" >/dev/null 2>&1; then rm -f "$f"; return 2; fi
    acc=$(jq -c --argjson acc "$acc" '$acc + [ .[] | {l:(.user.login // ""), t:(.user.type // ""), a:(.author_association // ""), c:(.commit_id // ""), s:(.state // ""), b:(.body // ""), id:(.id // 0)} ]' "$f" 2>/dev/null) \
      || { rm -f "$f"; return 2; }
    len=$(jq 'length' "$f" 2>/dev/null)
    [ "${len:-0}" -lt 100 ] && break
    [ "$page" = 10 ] && { rm -f "$f"; return 2; }
  done
  rm -f "$f"
  printf '%s\n' "$acc"
}

# br_review_harness_pick <head> <rows-json> — the NEWEST harness-footer review on
# <head>, printed as ONE line of base64 (a review body is multi-line, and a
# multi-line answer inside a $() in a while-read loop is how a parser starts
# guessing).
#   rc 0  there is one; its body, base64, on stdout
#   rc 1  the list holds no such review
#
# The review STATE is read for exactly ONE thing: a DISMISSED row is a review
# GitHub no longer counts — bin/review-prs.sh's rp_dismiss_own retracts the
# lane's own legacy CHANGES_REQUESTED exactly this way on a pipeline-built PR
# whose current head it approved — so it must not brief a fix round either
# (#891 review, item 2: a fix round pushed under a queued PR unbinds its
# approval and ejects it). Beyond that the state deliberately decides nothing:
# the body's own `VERDICT:` line is what this lane acts on, and a COMMENT-state
# review carrying REQUEST_CHANGES is exactly what bin/review-prs.sh posts on a
# harness PR since BH-872.
br_review_harness_pick() {
  local head="$1" rows="$2" login cid rstate b64 pick=""
  # Oldest first, which is the order GitHub lists reviews in, so the last row
  # that matches is the newest one.
  while IFS=$'\t' read -r login cid rstate b64; do
    [ -n "${login:-}" ] && [ -n "${b64:-}" ] || continue
    [ "${cid:-}" = "$head" ] || continue
    [ "${rstate:-}" != DISMISSED ] || continue
    harness_verdict_author_match "$login" || continue
    printf '%s' "$b64" | base64 -d 2>/dev/null | grep -qF "$BR_REVIEW_FOOTER" || continue
    pick="$b64"
  done < <(printf '%s' "$rows" | jq -r '.[]? | [.l, .c, .s, (.b | @base64)] | @tsv' 2>/dev/null)
  [ -n "$pick" ] || return 1
  printf '%s\n' "$pick"
}

# br_review_harness_newest <slug> <num> <head> — the lane's own verdict on
# <head>, exactly as br_review_newest answered it before BH-2200: rc 0 base64
# body / rc 1 none / rc 2 the read failed.
br_review_harness_newest() {
  local rows
  rows=$(br_review_rows "$1" "$2") || return 2
  br_review_harness_pick "$3" "$rows"
}

# A LEAD'S (OR A HUMAN'S) CHANGES_REQUESTED IS A BRIEF (BH-2200).
#
# Until this, only a review carrying the review lane's footer from a harness
# verdict author could brief a fix round. The lead's REQUEST_CHANGES — operator,
# no footer, the findings ARE the body — was invisible, so the rounds on #2045,
# #2051 and #2065 pushed main merges and nothing else, and #2158 merged over the
# lead's unfixed BLOCK. The picker below takes the NEWEST STANDING one:
#   * STANDING: per reviewer, the latest of APPROVED / CHANGES_REQUESTED /
#     DISMISSED decides (a COMMENTED review changes nothing, as on GitHub), and
#     only a reviewer whose latest decisive review is CHANGES_REQUESTED counts.
#   * A LEAD OR A HUMAN WITH WRITE ACCESS: never a bot (`user.type` Bot or a
#     `[bot]` login), never a body carrying the lane's footer (that is the review
#     lane's own verdict, picked above), and write access proved, never assumed:
#     author_association OWNER / MEMBER / COLLABORATOR, or CONTRIBUTOR plus a
#     collaborator-permission read answering admin / maintain / write. Anything
#     else — NONE, or no association at all — is not trusted to brief an agent.
#   * ON THIS HEAD, or on an older head followed only by merge commits
#     (br_lead_merges_only): a real commit after the review means the lead has to
#     look again, which is not a fix round.
#   * THE LEAD-REVIEW LANE'S OWN FINDINGS REVIEW (BH-3780). bin/lead-review-land.sh
#     posts a lead BLOCK as a REQUEST_CHANGES whose body opens with
#     `<!-- lead-review:<id> -->`, under the hub's default gh identity: the App,
#     so `cromford[bot]`, user.type Bot, author_association NONE. The bot
#     and association rules above dropped every one of them, so a lead BLOCK
#     never briefed a round (#3722). A row that is BOTH a bot and carries that
#     marker is its own reviewer (`<login>#lead-review`, so the App's review-lane
#     APPROVE never lifts it, nor its DISMISS hide one) and is trusted on
#     harness_verdict_author_match instead of the association: the builders App
#     or an outsider pasting the marker is never a brief, and a lifted copy with
#     no trust set skips these rows. A marker row from a person (the hub on a
#     PAT) takes the association path as before.
#   * NEVER A `needs-human` FINDING. A marker row with a `- [BLOCK needs-human]`
#     line is a question only a person can settle; the land lane holds the
#     ticket for it, and no agent is briefed from it whatever the hold did.
# The body goes out framed, so the agent and every reader know whose it is:
BR_LEAD_HDR='LEAD FINDINGS — every item must be addressed in code'

# br_lead_merges_only <slug> <old-head> <head> — rc 0 when every commit the
# branch gained after <old-head> is a merge commit (main merged in, nothing
# else); rc 1 when there is a real commit, or history was rewritten; rc 2 when
# GitHub would not answer. Two compare reads: <old>...<head> is everything
# <head> gained, main...<head> is what is the branch's own; a commit in both
# with a single parent is somebody's real change.
br_lead_merges_only() {
  local slug="$1" old="$2" head="$3" f grc status gained own s
  f=$(mktemp "${TMPDIR:-/tmp}/br-compare.XXXXXX") || return 2
  grc=0; gh_rest GET "repos/$slug/compare/$old...$head" > "$f" 2>/dev/null || grc=$?
  # 404: the old head is gone (history rewritten) — not "followed only by merges".
  case "$grc" in 0) ;; 44) rm -f "$f"; return 1 ;; *) rm -f "$f"; return 2 ;; esac
  status=$(jq -r '.status // ""' "$f" 2>/dev/null)
  gained=$(jq -r '[.commits[]? | .sha] | join(" ")' "$f" 2>/dev/null)
  [ "$status" = ahead ] || { rm -f "$f"; return 1; }
  grc=0; gh_rest GET "repos/$slug/compare/main...$head" > "$f" 2>/dev/null || grc=$?
  [ "$grc" = 0 ] || { rm -f "$f"; return 2; }
  own=$(jq -r '[.commits[]? | select((.parents | length) < 2) | .sha] | join(" ")' "$f" 2>/dev/null) || { rm -f "$f"; return 2; }
  rm -f "$f"
  for s in $gained; do
    case " $own " in *" $s "*) return 1 ;; esac
  done
  return 0
}

# br_lead_pick <slug> <head> <rows-json> — the newest standing lead/human
# CHANGES_REQUESTED that speaks for <head>, FRAMED, as one line of base64.
#   rc 0 found   rc 1 none   rc 2 a read it needed failed (permission, compare)
# BH-5909: a lead review whose body has `- [BLOCK console-qa]` (the console QA
# gate, bin/lib/console-qa-gate.sh) briefs no fix round: no code change answers
# it. A QA: PASS comment on the head does, and the hub then reviews it again.
br_lead_pick() {
  local slug="$1" head="$2" rows="$3" login assoc cid b64 lr nh perm hrc pf grc
  while IFS=$'\t' read -r login assoc cid b64 lr nh; do
    [ -n "${login:-}" ] || continue
    [ "$nh" = true ] && continue
    if [ "$lr" = true ]; then
      command -v harness_verdict_author_match >/dev/null 2>&1 || continue
      harness_verdict_author_match "$login" || continue
    else
      case "$assoc" in
        OWNER|MEMBER|COLLABORATOR) ;;
        CONTRIBUTOR)
          # Write access is READ, never assumed (the REST contract, into a file).
          # 404 is "not a collaborator": no write access, not an unknown.
          pf=$(mktemp "${TMPDIR:-/tmp}/br-perm.XXXXXX") || return 2
          grc=0; gh_rest GET "repos/$slug/collaborators/$login/permission" > "$pf" 2>/dev/null || grc=$?
          case "$grc" in
            0)  perm=$(jq -r '.permission // ""' "$pf" 2>/dev/null) ;;
            44) perm="" ;;
            *)  rm -f "$pf"; return 2 ;;
          esac
          rm -f "$pf"
          case "$perm" in admin|maintain|write) ;; *) continue ;; esac ;;
        *) continue ;;
      esac
    fi
    if [ "$cid" != "$head" ]; then
      hrc=0; br_lead_merges_only "$slug" "$cid" "$head" || hrc=$?
      [ "$hrc" = 2 ] && return 2
      [ "$hrc" = 0 ] || continue
    fi
    printf '%s\n(CHANGES_REQUESTED by %s on %s)\n\n%s\n' "$BR_LEAD_HDR" "$login" "${cid:0:12}" \
      "$(printf '%s' "$b64" | base64 -d 2>/dev/null)" | base64 | tr -d '\n'
    printf '\n'
    return 0
  done < <(printf '%s' "$rows" | jq -r --arg f "$BR_REVIEW_FOOTER" '
      [ to_entries[] | .value + {i: .key}
        | (.b // "") as $b | ($b | startswith("<!-- lead-review:")) as $m
        | . + {lr: ($m and (.t == "Bot" or (.l | endswith("[bot]")))),
               nh: ($m and ($b | test("(^|\n)- \\[BLOCK needs-human\\]")))}
        | select(.s == "APPROVED" or .s == "CHANGES_REQUESTED" or .s == "DISMISSED") ]
      | group_by(.l + (if .lr then "#lead-review" else "" end)) | map(last) | map(select(.s == "CHANGES_REQUESTED"))
      | map(select((.lr and (.b | test("(^|\n)- \\[BLOCK console-qa\\]"))) | not))
      | map(select((.lr or (.t != "Bot" and ((.l | endswith("[bot]")) | not))) and ((.b | contains($f)) | not)))
      | sort_by(.i) | reverse | .[] | [.l, .a, .c, (.b | @base64), .lr, .nh] | @tsv' 2>/dev/null)
  return 1
}

# br_lead_review <slug> <num> <head> — br_lead_pick on a fresh reviews read.
br_lead_review() {
  local rows
  rows=$(br_review_rows "$1" "$2") || return 2
  br_lead_pick "$1" "$3" "$rows"
}

# br_review_newest <slug> <num> <head> — the review that parks this PR on
# <head>, as ONE line of base64: a standing lead/human CHANGES_REQUESTED first
# (framed with BR_LEAD_HDR; the lead's word outranks the lane's own verdict,
# including a later lane APPROVE), else the lane's own footer review exactly as
# before (BH-872). ONE reviews read for both.
#   rc 0  one; its body, base64, on stdout
#   rc 1  the list was READ and holds no such review
#   rc 2  THE READ FAILED — the caller says so and consumes nothing. An
#         unreadable ledger is never "no review" (D11).
br_review_newest() {
  local slug="$1" num="$2" head="$3" rows out rc=0
  rows=$(br_review_rows "$slug" "$num") || return 2
  out=$(br_lead_pick "$slug" "$head" "$rows") || rc=$?
  case "$rc" in
    0) printf '%s\n' "$out"; return 0 ;;
    2) return 2 ;;
  esac
  br_review_harness_pick "$head" "$rows"
}

# br_open_prs <slug> -> this repo's open harness PRs, as the JSON array
# harness_pr_list answers with, READ ONCE PER TICK.
#
# Two things in this lane want that list now — the review-verdict source below
# (BH-872) and the contested hold's competitor scan (BH-579) — and each used to
# buy its own `pulls?state=open` page. Same tick, same repo, same answer, so the
# first read is kept in a process-global and the second is free; the hold's own
# hoist out of its path loop is unchanged and still the reason two holds cost
# one list. The field set is the UNION of what both callers ask for, and every
# consumer picks its fields out of the row, so the extra ones cost nothing.
#
# ONLY A READ THAT WORKED IS REMEMBERED. A failed or non-array answer is not
# cached, so the next caller asks GitHub again rather than inheriting a gap —
# the same rule br_review_newest holds about an unreadable ledger.
#
# THE CACHE IS A FILE, NOT A VARIABLE. The candidate sources run inside
# `RAW=$(br_candidates)`, and a command substitution takes every variable its
# subshell set with it — so a shell-level memo would be gone by the time the
# hold path asks, and the list would be bought twice anyway. The key is the
# LANE'S PID (identical in every subshell of this tick) plus the slug, and a
# cached answer is read back only while it is younger than BR_PRS_CACHE_SECS,
# so a recycled PID can never hand a later tick a stale list. The directory is
# removed by the tick's EXIT trap.
br_open_prs() {
  local slug="${1:-}" dir f age now mtime out
  [ -n "$slug" ] || return 1
  command -v harness_pr_list >/dev/null 2>&1 || return 1
  dir="${TMPDIR:-/tmp}/br-open-prs.$$"
  f="$dir/${slug//[^A-Za-z0-9]/_}.json"
  if [ -s "$f" ]; then
    now=$(date -u +%s); mtime=$(date -u -r "$f" +%s 2>/dev/null || echo 0)
    age=$(( now - mtime ))
    if [ "$age" -ge 0 ] && [ "$age" -le "${BR_PRS_CACHE_SECS:-300}" ]; then cat "$f"; return 0; fi
  fi
  out=$(harness_pr_list "$slug" open number,url,headRefOid,headRefName,baseRefName,isDraft,updatedAt 2>/dev/null) || return 1
  printf '%s' "$out" | jq -e 'type == "array"' >/dev/null 2>&1 || return 1
  mkdir -p "$dir" 2>/dev/null && printf '%s\n' "$out" > "$f" 2>/dev/null
  printf '%s\n' "$out"
}

br_from_reviews() {
  # A box whose harness sync has not landed bin/lib/gh-pr-list.sh answers
  # nothing here and keeps every other source exactly as it is.
  command -v harness_pr_list >/dev/null 2>&1 || return 0
  local p slug list rows row num head brn url draft upd upd_ep cutoff
  local b64 body rkey tkey rc esc esc_rkey
  if command -v gh_budget_low >/dev/null 2>&1 && gh_budget_low blocked-resolver >/dev/null 2>&1; then
    say "the review-verdict source is skipped this tick — the GitHub API budget is low"
    return 0
  fi
  cutoff=$(( $(date -u +%s) - ${BR_REVIEW_LOOKBACK_SECS:-172800} ))
  while read -r p; do
    [ -n "${p:-}" ] || continue
    [ -z "$ONLY" ] || [ "$ONLY" = "$p" ] || continue
    slug=$("$H/bin/fleet-conf.sh" "$p" repo 2>/dev/null)
    [ -n "$slug" ] && [ "$slug" != "-" ] || continue
    br_use_token "$slug"
    list=$(br_open_prs "$slug") || list=""
    # The rows are read into an array FIRST: gh inside the loop must never eat
    # the loop's own stdin (the conductor learned this the expensive way).
    rows=()
    [ -n "$list" ] && mapfile -t rows < <(printf '%s' "$list" \
      | jq -r '.[]? | [((.number // "") | tostring), (.headRefOid // ""), (.headRefName // ""), (.url // ""), ((.isDraft // false) | tostring), (.updatedAt // "")] | @tsv' 2>/dev/null)
    for row in "${rows[@]:-}"; do
      [ -n "${row:-}" ] || continue
      IFS=$'\t' read -r num head brn url draft upd <<<"$row"
      [ -n "${num:-}" ] && [ -n "${head:-}" ] || continue
      [ "${draft:-false}" = true ] && continue
      [ -n "${upd:-}" ] || continue
      upd_ep=$(date -u -d "${upd:-}" +%s 2>/dev/null) || continue
      [ "$upd_ep" -ge "$cutoff" ] || continue
      rkey=$(br_rkey "$slug#$num")
      # br_ticket_key prints "<key>\t<source>" since BH-488; the source word
      # belongs in a log line, not in the candidate's ticket-key column.
      tkey=$(br_ticket_key "$p" "-" "${brn:-}" "" 2>/dev/null); tkey="${tkey%%	*}"
      # A RECORD WRITTEN BEFORE BH-4149 MAY SAY ESCALATED, and it stays terminal
      # for this source (#891 review, item 3). That verdict outlasted the cap
      # and was handed to a person with one comment, and re-offering it every
      # ten minutes would spend one reviews read, the merged-guard reads and one
      # "already ran N of cap" log line per tick for nothing. The record is a
      # file, so the escalated PR is skipped BEFORE the API call. No new record
      # is stamped ESCALATED: the review terminal is ABANDONED now.
      #
      # TERMINAL FOR THE ESCALATED PR, NOT FOR THE TICKET (#891 round 1,
      # Important 5). br_cap_key keys on the TICKET when the branch names one,
      # so a SECOND PR opened by hand for the same ticket key inherited the
      # escalation and could never be a candidate — the "no consumer" state,
      # recreated for that ticket and silent. The escalating rung stamps the PR
      # it escalated (`escalated_rkey`); only that PR is skipped here. A record
      # written before this change carries no such field and stays terminal, so
      # nothing already handed to a person is re-offered.
      # A HEAD FROZEN BY fix-round-noop (BH-2200) is NOT skipped here any more
      # (BH-4149): it reaches br_fix_round's frozen-head gate, which hands it to
      # br_fix_terminal. Once that closes the PR, the open-PR list stops naming it.
      esc=$(br_load "$p" "$(br_cap_key "$p" "$rkey" "$tkey")" \
            | jq -r '(.outcome // "") + "|" + (.escalated_rkey // "")' 2>/dev/null)
      if [ "${esc%%|*}" = ESCALATED ]; then
        esc_rkey="${esc#*|}"
        case "$esc_rkey" in
          ''|-|"$rkey") continue ;;
        esac
      fi
      rc=0; b64=$(br_review_newest "$slug" "$num" "$head") || rc=$?
      case "$rc" in
        2) say "$p/$slug#$num: the reviews list would not read (GitHub answered nothing) — no verdict consumed this tick, unreadable is not 'no review'"
           continue ;;
        0) ;;
        *) continue ;;
      esac
      body=$(printf '%s' "$b64" | base64 -d 2>/dev/null)
      # A lead/human CHANGES_REQUESTED (BH-2200) carries no `VERDICT:` line: its
      # review STATE is the verdict, and br_review_newest only returns one that
      # stands, so the framed body is the candidate as it is.
      case "$body" in
        "$BR_LEAD_HDR"*) ;;
        *) [ "$(br_review_verdict "$body")" = REQUEST_CHANGES ] || continue ;;
      esac
      [ -n "${url:-}" ] || url="https://github.com/$slug/pull/$num"
      # The reason is the NORMALIZED word: br_one hands the row's reason straight
      # to br_action, so a candidate carrying the detail too would classify as
      # `none` and be left where it is. The head rides in the rung's own event
      # line, where the (PR, head) key is the thing a reader wants.
      printf 'reviews\t%s\t%s\treview-changes-requested\t%s\t-\t%s\t-\n' \
        "$p" "$rkey" "$url" "${tkey:--}"
    done
    br_reset_token
  done < <("$H/bin/fleet-conf.sh" --projects 2>/dev/null)
}
# <<< br-reviews

# br_round_robin — the candidate TSV (SRC P RKEY REASON URL REC TKEY) on stdin,
# the same lines out, interleaved by project: the project this lane looked at
# LONGEST AGO goes first, ties keep first-appearance order, and the order WITHIN
# one project is preserved.
#
# WHY (BH-870). Every source above emits in its own file order — pr-state.tsv
# rows, the builds glob, the queue — so the fleet budget below was spent top to
# bottom. One repo with four parked PRs took all four rungs, every ten minutes,
# for as long as it stayed parked, and the other six were invisible to this lane
# while nothing anywhere said so. This is the same answer BH-778 gave the merge
# sweep (sweep_order, bin/merge-sweep.sh), in the same awk shape.
#
# WHY THE LEDGER (BH-980). BH-870 fixed the starvation INSIDE one tick. It could
# not fix the one BETWEEN ticks, because first appearance is a DETERMINISTIC
# order: the same rows, the same glob, the same queue, so every tick offered the
# same first PER_TICK projects and the fifth project on a box with more parks
# than rungs was never reached — tick after tick. On the hub that was project-5,
# 14 hand-offs and not one resolver line in seven hours. The visit ledger
# ($ST/.last-visited.tsv, written by br_visited_put) is the only memory the
# rotation needs: a project this lane looked at is stamped, and the next tick
# puts the ones it has not looked at first. NO LEDGER FILE = every stamp 0 = the
# BH-870 order, byte for byte, which is what a box running this for the first
# time gets. The sort is insertion sort and stable on purpose: np is one entry
# per fleet project, and a stable sort is what makes "no ledger" identical to
# today rather than merely similar.
#
# A line with an empty project field keeps its own bucket rather than joining
# somebody else's: it is still a candidate and it is still emitted. It has no
# ledger stamp, so it sorts with the never-visited projects, in its own slot.
#
# ONE EMISSION, EVER (BH-980). awk's output is captured and printed once. The
# old fail-open printed the whole stream AFTER awk may already have printed part
# of it, so an awk that died mid-write offered the head of the candidate list
# twice — two rungs, two rebuilds, one ticket. A fail-open that duplicates work
# is worse than the ordering it was protecting.
br_round_robin() {
  local stream out rc
  stream=$(cat)
  [ -n "$stream" ] || return 0
  out=$(printf '%s\n' "$stream" \
    | awk -F'\t' -v vf="${ST:-}/.last-visited.tsv" '
        BEGIN { while ((getline ln < vf) > 0) {
                  nf = split(ln, f, "\t")
                  if (nf >= 2 && f[1] != "") lv[f[1]] = f[2] + 0 }
                close(vf) }
        { p = $2; r = ++n[p]; if (r == 1) ord[++np] = p
          line[p, r] = $0; if (r > maxr) maxr = r }
        END { for (i = 2; i <= np; i++) {
                k = ord[i]; kv = lv[k] + 0; j = i - 1
                while (j >= 1 && (lv[ord[j]] + 0) > kv) { ord[j+1] = ord[j]; j-- }
                ord[j+1] = k }
              for (r = 1; r <= maxr; r++) for (i = 1; i <= np; i++)
                if ((ord[i], r) in line) print line[ord[i], r] }')
  rc=$?
  if [ "$rc" = 0 ]; then
    [ -z "$out" ] || printf '%s\n' "$out"
    return 0
  fi
  # FAIL OPEN. No awk, a broken awk, anything: print what we read, in the order
  # we read it. A broken ordering must never be the reason a parked ticket is
  # not looked at — the sweep's own rule. It says so out loud, and rc 2 puts
  # `+ordering-fallback` on the tick line, because an ordering nobody can see
  # fail is an ordering nobody fixes.
  printf '%s\n' "$stream"
  say "ordering fell back to source order (awk rc=$rc) — every candidate is still offered, in the order it was read"
  return 2
}

# ---------------------------------------------------------------------------
# THE DETERMINISTIC PRE-PASS (BH-1457). Everything below runs BEFORE any rung,
# reads NOTHING but this lane's own state files, and calls no model, no gh, no
# git and no jobs client. It answers two questions per candidate:
#
#   is this row FINISHED?  -> drop it from the list, and say so once
#   what will its rung COST? -> a sort key, so the cheap rungs go first
#
# THE CENSUS IT IS FOR (hub, 2026-09-22 14:1xZ): candidates=785 every tick,
# reason=budget every tick, and of the 586 state records 98 RESOLVED_MERGED and
# 79 ABANDONED were FINISHED rows still being offered. An ABANDONED row already
# answers rc 3 inside br_one, but it is still discovered, still counted, still
# read from disk and still offered — every ten minutes, for ever. A
# RESOLVED_MERGED row is worse: it spends a whole PER_TICK slot and a handful of
# REST reads before br_already_merged answers what this lane already knew.
#
# THE CANDIDATE ROW IS EIGHT FIELDS, ALWAYS (BH-1457 review B1). Until this
# ticket only br_conductor_emit filled the eighth (`parked`); queue, builds,
# rebuilds and reviews emitted SEVEN, and there was nothing in the pipeline that
# noticed — the tick loop's `read` with eight names simply left PARKED empty and
# br_rank_rows' seven-name read absorbed the remainder into `tkey` and printed
# it back. Appending a ninth column to a seven-field row put the COST in
# `parked`: br_note_untouched reads an all-digit string as an epoch, so
# oldest_untouched became ~29,000,000m on the tick line AND on the SATURATED
# page, and `sort -k9,9n` keyed those rows 0 — which put the rebuild-shaped
# sources (pool-died-twice, pool-deferred-max, build-dead, rebuild-*) FIRST and
# let them eat the whole rebuild budget, the exact inverse of the ask. Every
# source now pads its row to eight; br_prepass re-emits from PARSED FIELDS, nine
# wide, so the width is a property of this function and not of eight call sites
# staying right for ever.
# ---------------------------------------------------------------------------

# br_finished <outcome> <resolved-url> <candidate-url> <reason> — rc 0 when this
#   CANDIDATE's row is finished and may leave the list. The first two come from
#   br_record_index's row for this candidate's cap key; `-` for either means the
#   record does not carry it.
#
#   ABANDONED is a TICKET-level terminal and br_one already treats it as one for
#   every row under the cap key, so retiring it is today's behaviour minus the
#   read.
#
#   RESOLVED_MERGED IS NOT, AND THE URL-LESS ARM IS THE TRAP (review B2). The
#   first cut retired any candidate carrying no url of its own. br_from_builds
#   ALWAYS emits `-`, and br_from_rebuilds emits it whenever the record has no
#   parked_url — so a ticket whose PR merged, and whose LATER rebuild then died
#   in the pool, was retired for ever: no ABANDONED outcome, no ticket comment,
#   no alert, silent after the first tick. A ticket can always acquire a new
#   pull request, so RESOLVED_MERGED retires ONE thing: the park on the PR the
#   resolve was actually about. Everything else keeps today's path.
#
#   THE LEGACY RECORDS ARE STILL SAVED, without guessing. `resolved_url` is new,
#   so the 98 RESOLVED_MERGED rows the census counted carry none — but the
#   `resolved-merged` ATTEMPT that wrote the outcome carries the url in its own
#   detail string ("<url> is already MERGED — stale park, no rebuild"), and that
#   is a fact on disk, not an inference. The caller extracts it into
#   `resolved_url_eff`; a record with neither stays unretired (D11).
#
#   `rebuild-landed` is deliberately NOT finished. It is a finished ATTEMPT, not
#   a finished ticket: the rebuild it records created a new PR, and that PR is a
#   legitimate new candidate under the same cap key.
br_finished() {
  local oc="${1:-}" rurl="${2:-}" url="${3:--}" reason="${4:-}"
  case "$oc" in
    ABANDONED) return 0 ;;
    RESOLVED_MERGED)
      # A REBUILD'S OWN ENDING IS STILL OWED (review I3). These reasons ARE the
      # rebuild this lane started reporting how it finished, and br_rebuild_*
      # is what turns them into an ABANDONED outcome and one ticket comment.
      # Dropping them here would delete the only consumer that record has.
      case "$reason" in rebuild-*) return 1 ;; esac
      case "$url" in ''|-) return 1 ;; esac
      [ -n "$rurl" ] && [ "$rurl" != "-" ] && [ "$rurl" = "$url" ] && return 0
      return 1 ;;
  esac
  return 1
}

# br_cost_rank <reason> <mechanicals> <fixrounds> <fixcap> -> 0|1|2|3, cheapest
#   first.
#
#   0  mechanical / regen / abandon-rebuild / none   no model at all
#   1  adjudicate / re-review                        one call
#   2  fix-round                                     one execute-stage agent round
#   3  rebuild-fresh / rebuild-retry                 a whole pool build
#
#   PURE AND FORK-FREE (review I6). The counters arrive as NUMBERS rather than as
#   a json blob, because the first cut forked jq four more times per candidate —
#   br_num twice and br_fix_cap's br_shape + br_num — record or no record, which
#   at 785 candidates was thousands of forks spent BEFORE the first rung, in the
#   one stretch of the tick the new wall bound deliberately cannot stop.
#   br_action, br_ladder_class, br_ladder_rung and br_regen_ladder are already
#   pure, so with the numbers in hand this whole function forks nothing.
#
#   It resolves the ladder exactly as br_one:5285 does, off THIS TICKET's own
#   counters, so a conflict whose mechanical rung is already spent sorts as the
#   fix round it is rather than as the free rung its reason word suggests.
#
#   ADVISORY, AND BLIND TO A KEYLESS ROW. br_one re-resolves under the per-key
#   lock and its answer is the one that runs. A candidate that arrives with no
#   ticket key is costed against the record under its RKEY, which is usually
#   absent — br_one derives the key later and reads the ticket's record instead —
#   so such a row is costed at zero counters and sorts as free work. It costs
#   sort order and nothing else, and the rebuild cap is enforced at the dispatch,
#   never in this sort.
br_cost_rank() {
  local reason="${1:-}" mech="${2:-0}" fix="${3:-0}" cap="${4:-}" act class rung
  act=$(br_action "$reason")
  case "$act" in
    ladder)
      class=$(br_ladder_class "$reason")
      rung=$(br_ladder_rung "$class" "$mech" "$fix" "$cap")
      rung=$(br_regen_ladder "$class" "$rung") ;;
    *) rung="$act" ;;
  esac
  case "$rung" in
    mechanical|regen|abandon-rebuild|none) printf '0' ;;
    adjudicate|re-review)                  printf '1' ;;
    fix-round)                             printf '2' ;;
    rebuild-fresh|rebuild-retry)           printf '3' ;;
    # An action this table does not know sorts with the agent rounds rather than
    # with the free ones: a rung nobody has costed is not a rung to run first.
    *)                                     printf '2' ;;
  esac
}

# br_record_index — ONE jq pass over every record this lane holds, as
#   `<project>\t<cap-key>\t<outcome>\t<resolved_url_eff>\t<retired>\t<mechanicals>\t<fixrounds>\t<fixround_bonus>\t<conflict_lines>`,
#   one row per record file. The glob is the one br_from_rebuilds already walks.
#
#   `resolved_url_eff` is `.resolved_url` when the record has one and otherwise
#   the url the `resolved-merged` attempt recorded in its detail — the legacy
#   half of review B2, read off the record rather than guessed.
#
#   `-` for an absent scalar, never an empty field: a reader that cannot tell
#   "absent" from "empty" is the D11 mistake one layer down.
br_record_index() {
  # ONE jq INVOCATION over the whole tree, not one per file (review I6). The
  # first cut forked jq per record — 586 of them on the hub — in the stretch of
  # the tick the wall bound deliberately cannot stop. `find | xargs` chunks the
  # argument list so a fleet with tens of thousands of records cannot overflow
  # argv; in practice that is one or two forks.
  #
  # AND IT IS TOLERANT PER RECORD, NOT PER CHUNK (review r2/I1). Handing jq the
  # files as ARGUMENTS made it one input stream: a single unparseable record
  # aborted the whole invocation, every record after it in that argv was never
  # indexed, and the only symptom was `retired=` quietly reading 0 — for ever,
  # since every record write in this file is a non-atomic `printf > "$f"`. So
  # each record travels as ONE LINE prefixed with its path, `fromjson` is tried
  # per line, and a record that will not parse costs only itself. It is emitted
  # with the outcome `!PARSE`, which br_finished never matches (so nothing is
  # wrongly retired) and which the caller COUNTS and says out loud.
  #
  # THE KEY IS THE FILE NAME, never the record's own `.rkey` field. br_load
  # stamps `.rkey` with whatever key created the record and not every writer
  # passes the cap key — br_abandon writes `br_set_outcome "$p" "$rkey"`, so an
  # ABANDONED record can carry an `.rkey` that is not its own file name. The
  # file name IS the key every reader here resolves (br_file), which is why
  # br_from_rebuilds takes it the same way.
  #
  # FNR==1: a record is one line (`br_record` writes `jq -c` output). A file
  # with more is malformed, and reading only its first line is what makes the
  # path prefix unambiguous.
  { find "$ST" -mindepth 2 -maxdepth 2 -name '*.json' -type f -print0 2>/dev/null \
      | xargs -0 -r awk 'FNR==1 { printf "%s\t%s\n", FILENAME, $0 }' 2>/dev/null
    # A ZERO-BYTE RECORD HAS NO FIRST LINE (BH-1512). awk runs its rule on
    # RECORDS and an empty file contributes none, so FNR==1 never fires for it
    # and the file was dropped from the index with no count, no line and no
    # mark — the one degradation of this pre-pass that was still silent, and
    # the one a non-atomic `printf > "$f"` produces every time it is
    # interrupted. It is emitted here as `<path>\t`, a payload jq's
    # `try fromjson` turns into null, i.e. the same `!PARSE` row a `not json`
    # record gets. The two walks partition on -empty, so nothing is emitted
    # twice; a record written BETWEEN them can be (the last row wins, which is
    # `!PARSE`: counted, marked, nothing retired — the safe direction — and it
    # heals next tick).
    find "$ST" -mindepth 2 -maxdepth 2 -name '*.json' -type f -empty -printf '%p\t\n' 2>/dev/null
  } | jq -R -r '
        (index("\t")) as $i |
        if $i == null then empty else
          (.[:$i] | split("/")) as $seg |
          (.[$i+1:]) as $raw |
          ((try ($raw | fromjson) catch null)) as $r |
          def d(x): (x // "") | tostring | if . == "" or . == "null" then "-" else . end;
          def n(x): (x // 0) | if type == "number" then . else 0 end;
          $seg[-2] + "\t" + ($seg[-1] | sub("\\.json$"; "")) + "\t"
          + ( if $r == null then "!PARSE\t-\t0\t0\t0\t0\t-"
              else
                d($r.outcome) + "\t"
                + d( $r.resolved_url //
                     ( [ $r.attempts[]? | select((.action // "") == "resolved-merged")
                                        | (.detail // "")
                                        | capture("^(?<u>https://github\\.com/[^ ]+) is already MERGED") .u ] | last ) ) + "\t"
                + ( if ($r.retired // false) == true then "1" else "0" end ) + "\t"
                + (n($r.mechanicals)|tostring) + "\t"
                + (n($r.fixrounds)|tostring) + "\t"
                + (n($r.fixround_bonus)|tostring) + "\t"
                + d($r.conflict_lines)
              end )
        end
      ' 2>/dev/null
  return 0
}

# br_prepass <count-file> — the candidate TSV on stdin; the same rows out, NINE
#   fields wide with the cost appended, finished rows dropped, and the number
#   dropped written to <count-file>.
#
#   THE COUNT TRAVELS IN A FILE because this runs inside a command substitution
#   and a variable set here dies with the subshell (br_pr_ref's lesson). The
#   event lines and the record flag are ordinary file writes and do survive.
#
#   THE ROW IS RE-EMITTED FROM PARSED FIELDS, not appended to `$line` (review
#   B1): the width is then this function's property rather than a promise eight
#   printfs in five source functions have to keep for ever.
#
#   THE RECORDS ARE READ ONCE, NOT ONCE PER CANDIDATE (review I6). br_record_index
#   is one jq pass over the record tree; the candidates then index into it and
#   the per-candidate loop forks NOTHING.
br_prepass() {
  local cf="${1:-/dev/null}" line src p rkey reason url rec tkey parked
  local ck n=0 bad=0 rp rck roc rurl rret rmech rfix rbonus rconf key cap cost
  declare -A _BRIDX=()
  while IFS=$'\t' read -r rp rck roc rurl rret rmech rfix rbonus rconf; do
    [ -n "${rp:-}" ] && [ -n "${rck:-}" ] || continue
    # A RECORD THAT WOULD NOT PARSE IS COUNTED AND KEPT (review r2/I1). It is
    # indexed under its own key with an outcome br_finished never matches, so
    # its rows are not retired and are costed off zero counters — the safe
    # direction — and the count rides out on line 2 of the count file so the
    # tick line can carry `+index-short`. Silence here would be a permanent,
    # invisible regression of the number this ticket is about.
    if [ "$roc" = "!PARSE" ]; then bad=$((bad+1)); fi
    _BRIDX["$rp/$rck"]="$roc	$rurl	$rret	$rmech	$rfix	$rbonus	$rconf"
  done < <(br_record_index)
  [ "$bad" = 0 ] || say "$bad state record(s) could not be parsed and were not indexed — their parks are neither retired nor costed this tick"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    IFS=$'\t' read -r src p rkey reason url rec tkey parked <<<"$line"
    if [ -z "${rkey:-}" ]; then
      # A row with no key is not costable and not retirable; it is re-emitted at
      # the same width as every other row so the strip below is uniform.
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t2\n' \
        "$src" "${p:-}" "" "${reason:-}" "${url:--}" "${rec:--}" "${tkey:--}" "${parked:--}"
      continue
    fi
    # ONE SPELLING OF THE PROJECT, on the lookup and on every write below
    # (review M8): br_round_robin deliberately keeps a candidate whose project
    # field is empty, and reading it as "" while writing it as "-" meant the
    # retired flag never took and the event fired every tick, for ever — inside
    # the very block whose comment says "ONE LINE PER ROW, EVER".
    key="${p:--}"
    ck=$(br_cap_key "$key" "$rkey" "${tkey:--}")
    roc="-"; rurl="-"; rret=0; rmech=0; rfix=0; rbonus=0; rconf="-"
    if [ -n "${_BRIDX["$key/$ck"]:-}" ]; then
      IFS=$'\t' read -r roc rurl rret rmech rfix rbonus rconf <<<"${_BRIDX["$key/$ck"]}"
    fi
    if br_finished "$roc" "$rurl" "${url:--}" "$reason"; then
      n=$((n+1))
      # ONE LINE PER ROW, EVER. 177 retirements a tick, every ten minutes, is
      # the noise the lane's own "one line per episode" rule forbids; the tick
      # line's `retired=` is the standing number. Observe mode writes no flag,
      # so it keeps saying WOULD — it took no action to remember.
      if [ "$rret" != 1 ]; then
        if [ "$OBSERVE" = 1 ]; then
          say "$key/$rkey [$reason]: WOULD retire — the record is $roc — observe mode"
        else
          # </dev/null: this is the first br_event call site inside a
          # stdin-consuming loop, at up to 177 invocations a tick, and a child
          # that read one byte of stdin would make candidate rows vanish.
          br_event resolver_retired "$key" "$ck" "$reason" \
            "finished: the record is $roc — dropped from the candidate list, no rung" </dev/null
          # THE FLAG IS WHAT MAKES THE LINE ABOVE FIRE ONCE. A write that failed
          # and said nothing would repeat it every tick for ever (D16).
          br_set_flag "$key" "$ck" retired \
            || say "$key/$rkey: the retire flag was not written — this line will repeat next tick"
        fi
      fi
      continue
    fi
    # THE FIX CAP, computed here the way br_fix_cap computes it, from numbers
    # already in hand. Its two arms are the review-verdict cap and the
    # shape-driven one; `conflict_lines` of `-`, `0` or a non-number is LARGE,
    # exactly as br_shape reads it.
    case "$reason" in
      # The review cap is the settings row (BH-7123 wave B), memoised per
      # project inside br_review_fix_cap, so this loop still forks nothing new
      # after the first row of a project.
      review-changes-requested) br_review_fix_cap "${p:-}" >/dev/null; cap="$_BR_REVIEW_CAP_OUT" ;;
      *)
        case "$rconf" in
          ''|-|0|*[!0-9]*) cap="${MAX_FIXROUNDS:-${BR_MAX_FIXROUNDS:-1}}" ;;
          *) if [ "$rconf" -le "${SMALL_CONFLICT_LINES:-300}" ]
             then cap="${MAX_FIXROUNDS_SMALL:-${BR_CONFLICT_FIX_ROUNDS:-${BR_MAX_FIXROUNDS_SMALL:-2}}}"
             else cap="${MAX_FIXROUNDS:-${BR_MAX_FIXROUNDS:-1}}"; fi ;;
        esac
        case "$cap" in ''|*[!0-9]*) cap=1 ;; esac
        cap=$(( cap + rbonus )) ;;
    esac
    cost=$(br_cost_rank "$reason" "$rmech" "$rfix" "$cap")
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$src" "${p:-}" "$rkey" "${reason:-}" "${url:--}" "${rec:--}" "${tkey:--}" "${parked:--}" "$cost"
  done
  printf '%s\n%s\n' "$n" "$bad" > "$cf" 2>/dev/null
  return 0
}

# THE VISIT LEDGER (BH-980), one row per project:
#
#   <project>\t<last_visited>\t<first_seen>\t<last_alerted>   unix epochs, 0 = never
#
# last_visited is what br_round_robin sorts on. first_seen is the starvation
# clock for a project this lane has never reached at all (it has no last visit to
# measure from). last_alerted is the "one line per episode" guard: a later visit
# moves last_visited past it and re-arms the alert.
#
# A DOTFILE on purpose: br_from_rebuilds globs "$ST"/*/*.json and the per-project
# state directories live here, so a visible file is one more thing those globs
# have to know to skip. Bounded by fleet.conf (D21): only a project that reached
# the candidate stream is ever written, and the stream can only name a project
# bin/project-of.sh resolved.
BR_VISITED_FILE="$ST/.last-visited.tsv"

# A ledger field is an epoch or it is zero. A row half-written by a killed tick
# must read as "never", never as a crash under set -u and never as a date.
br_epoch_or_zero() { case "${1:-}" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$1" ;; esac; }

# br_visited_row <project> -> "<last_visited> <first_seen> <last_alerted>".
# Zeros when the file, the row or a field is absent or unreadable — which is
# exactly the pre-BH-980 behaviour, so an unreadable ledger degrades to today's
# order rather than to a refused tick.
br_visited_row() {
  local p="$1" a b c d lv=0 fs=0 la=0
  if [ -r "$BR_VISITED_FILE" ]; then
    while IFS=$'\t' read -r a b c d; do
      [ "${a:-}" = "$p" ] || continue
      lv=$(br_epoch_or_zero "${b:-}"); fs=$(br_epoch_or_zero "${c:-}"); la=$(br_epoch_or_zero "${d:-}")
      break
    done < "$BR_VISITED_FILE"
  fi
  printf '%s %s %s\n' "$lv" "$fs" "$la"
}

# br_visited_put <project> <last_visited> <first_seen> <last_alerted> — rewrite
# that project's row, atomically.
#
# THE LOCK IS SHORT AND IT IS NOT A QUEUE (D33). Two ticks overlap whenever a fix
# round runs past the next cron fire, and a lost stamp is a project that silently
# keeps its place at the front of the order. So the read-modify-write takes the
# lock for its own few milliseconds and nothing else — never across a rung. A
# lock this box cannot take in 5 seconds is not worth a skipped stamp: the write
# goes ahead, which is no worse than not having the lock at all.
br_visited_put() {
  local p="$1" lv="$2" fs="$3" la="$4"
  [ -n "$p" ] && [ "$p" != "-" ] || return 0
  mkdir -p "$ST" "$H/locks" 2>/dev/null
  (
    exec 9>"$H/locks/blocked-resolver-visited.lock" || exit 0
    flock -w 5 9 2>/dev/null || true
    [ -f "$BR_VISITED_FILE" ] || : > "$BR_VISITED_FILE"
    if awk -F'\t' -v OFS='\t' -v p="$p" -v lv="$lv" -v fs="$fs" -v la="$la" \
         '$1 == p { next } NF { print } END { print p, lv, fs, la }' \
         "$BR_VISITED_FILE" > "$BR_VISITED_FILE.tmp.$$" 2>/dev/null; then
      mv -f "$BR_VISITED_FILE.tmp.$$" "$BR_VISITED_FILE"
    else
      rm -f "$BR_VISITED_FILE.tmp.$$"
      say "$p: could not rewrite the visit ledger — its order and its starvation clock are unchanged this tick"
    fi
  )
}

# br_starved_alert <project> <candidate-count> <age-seconds> <since-text> <visited-list>
#   ONE actionable line for a project this lane has candidates for and has not
#   looked at for more than STARVE_SECS. It names what is parked, how long it has
#   been ignored, what the tick spent instead, and the two knobs that change it —
#   every value read from the ledger and this tick, none of them invented (D26).
#   Same ALERTS.log + beat fallback as br_lane_down_alert, for the same reason: a
#   box whose harness sync has not landed lane-alert.sh still pages.
br_starved_alert() {
  local p="$1" k="$2" age="$3" since="$4" vis="$5" line
  line="[blocked-resolver] STARVED $p: $k parked candidate(s) were offered and this lane has not looked at the project since $since ($((age / 60)) min). This tick spent BR_PER_TICK=$PER_TICK on [${vis:--}]. Raise BR_PER_TICK in env/global.env or cap the busy projects with BR_PER_TICK_<PROJECT>; see the tick: lines in logs/blocked-resolver.log."
  if [ -x "$H/bin/lane-alert.sh" ]; then
    "$H/bin/lane-alert.sh" blocked-resolver "$line" >/dev/null 2>&1 || true
  else
    HARNESS="$H" "$H/bin/alert-line.sh" "$line"
    "$H/bin/beat.sh" "$(jq -nc --arg p "$p" --arg akey "blocked-resolver-starved:$p" --arg l "$line" \
      '{kind:"fleet_alert",project:$p,akey:$akey,line:$l}')" >/dev/null 2>&1 || true
  fi
  say "$p: STARVED — $k candidate(s) offered, no rung for $((age / 60)) min (since $since); one ALERTS line written"
}

# br_per_tick_for <project> — how many rungs this project may spend in this
# tick. BR_PER_TICK_<PROJECT> (uppercased, every non-alphanumeric an
# underscore: project-1 -> BR_PER_TICK_project-1_OS) when it is set to a
# number, and the fleet total BR_PER_TICK otherwise.
#
# The fleet total is still the tick's hard ceiling. This only says how much of
# it ONE project may take, so an unset override is byte-for-byte today's spend.
# A typo is never a cap of zero: it falls back and says which variable it could
# not read, because a project silently stopped by a bad env line is exactly the
# invisible starvation this function exists to end.
br_per_tick_for() {
  local v val
  v="BR_PER_TICK_$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9\n' '_')"
  val="${!v:-}"
  case "$val" in
    '')       printf '%s\n' "$PER_TICK" ;;
    *[!0-9]*) say "$1: $v='$val' is not a number — using BR_PER_TICK=$PER_TICK"
              printf '%s\n' "$PER_TICK" ;;
    *)        printf '%s\n' "$val" ;;
  esac
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------
# >>> br-token
# The App token first, exactly as bin/merge-conductor.sh's use_token does it
# (live since 2026-09-14, docs/MERGE-CONDUCTOR.md section 7.1): an installation
# token is per-installation rate-limited and dead in an hour, and it is the
# identity this resolver should be reading PRs on. When it is not available —
# unarmed box, kill flag, a repo the App is not installed on — this falls to
# today's "which of our PATs can see this repo" probe, unchanged, alert and all.
# Both rungs are `command -v` guarded and neither ever returns nonzero.
#
# WHICH CREDENTIAL ANSWERED IS LOGGED (BH-597, ticket item 2). Deduped per RUN
# rather than per tick: this resolver touches one repo many times in a single
# pass, and a line per call would be a hundred lines saying the same thing. The
# WORDS app/default/admin and never a token value.
declare -A _BR_AUTH_SAID
br_auth_log() { # br_auth_log <owner/repo> <human words>
  [ -n "${_BR_AUTH_SAID[$1]+x}" ] && return 0
  _BR_AUTH_SAID[$1]=1
  say "$1: github auth: $2"
}
br_use_token() {
  local _br_tok
  if command -v gh_auth_for >/dev/null 2>&1 && gh_auth_for "$1"; then
    br_auth_log "$1" "App installation token"; return 0
  fi
  if command -v gh_repo_use_token >/dev/null 2>&1; then
    # `none` is the probe's answer for a repo NO PAT of ours can see. It is not a
    # credential, so it must not be logged as one — "none PAT" reads like a token
    # named none. This rung still returns 0 (the resolver's reads then fail and
    # take their own "could not read" branch, unchanged), so unlike the
    # conductor's use_token it cannot say this by returning early.
    gh_repo_use_token "$1"
    _br_tok=$(gh_repo_token_for "$1")
    # `app` reaches here too: gh_auth_for above refuses on an empty mint, but
    # gh-repo-token.sh's own App rung mints again with --min-life and verifies
    # visibility, so this ladder can still answer with an installation token.
    # "app PAT" would name a credential that does not exist.
    case "$_br_tok" in
      app)  br_auth_log "$1" "App installation token" ;;
      none) br_auth_log "$1" "no credential — no App installation and no PAT on this box can see the repo" ;;
      *)    br_auth_log "$1" "$_br_tok PAT" ;;
    esac
  else
    br_auth_log "$1" "default PAT"
  fi
  return 0
}
# Two arms, two resets, App first. Resetting only one would leave the process on
# whichever token the other rung happened to export.
br_reset_token() {
  command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset
  command -v gh_repo_token_reset >/dev/null 2>&1 && gh_repo_token_reset
  # In a project run the identity to come back to is the project's own.
  [ -z "${BR_HOME_SLUG:-}" ] || br_home_token
  return 0
}
# A PROJECT RUN READS GITHUB AS ITS PROJECT (BH-5913). One run per project, with
# no cap on how many run at once, must not draw on one shared PAT's rate limit.
# So a run with a project arms that project's repo credential (br_use_token:
# its App installation token, else its repo token) before its first read, after
# every reset, and at every row, so an hour-long run never reads on an expired
# token (gh-token.sh answers from its cache, so the re-arm costs no mint). A
# whole-fleet scan has no home repo and keeps the default credential.
BR_HOME_SLUG=""
br_home_token() {
  case "${BR_HOME_SLUG:-}" in */*) br_use_token "$BR_HOME_SLUG" ;; esac
  return 0
}
# <<< br-token

# br_slug_of_url <url> — the owner/repo a PR URL names, or rc 1.
#
# THE SLUG WAS NEVER MISSING (2026-09-16). Both branch rungs asked
# `fleet-conf.sh <project> repo` for it and, on an empty answer, said "no
# repo/branch" and fell to the rung below — so on every conductor hand-off where
# that lookup or the gh read came back blank the ladder collapsed and REBUILD
# FRESH was the only rung that ever fired. From the log that day, on project-5
# #1542 #1556 #1526 #1592 #1630 #1634 #1645, each within one second:
#   "no repo/branch/head for https://github.com/example-org/project-5/pull/1645
#    — nothing mechanical to try, FIX ROUND"
#   "no repo/branch for https://github.com/example-org/project-5/pull/1645
#    — REBUILD FRESH instead"
# The answer is in the URL that line prints. It is taken from there.
#
# The URL is read rather than `gh pr view --json headRepository` on purpose: the
# URL names the BASE repo, which is the one both rungs want — main is merged FROM
# it and, for a same-repo branch (every harness build branch is one), the push
# goes back TO it. `headRepository` is the HEAD's repo, the same thing on a
# same-repo PR and the wrong thing on a fork. It is also one more API call for an
# answer already in the string.
br_slug_of_url() {
  local url="${1:--}" slug
  case "$url" in https://github.com/*/*/pull/*) ;; *) return 1 ;; esac
  slug=$(mc_slug_of_url "$url")
  case "$slug" in */*) printf '%s' "$slug"; return 0 ;; esac
  return 1
}

# >>> br-rest
# THE DECISION READS AND THE DECISION WRITES, ALL OF THEM (#783).
#
# Every one answers the gh-rest contract: rc 0 the API answered and the field is
# on stdout, rc 44 GitHub said the PR does not exist (ABSENT — act on it), rc 75
# GitHub did not answer (UNVERIFIABLE — the caller takes its "unknown" path, logs
# the HTTP status, spends nothing and is re-offered the same park next tick).
#
# WHY THE HELPER LOGS ITS OWN 75. GH_REST_STATUS is set by gh_rest in the shell
# that calls it, so a helper run inside `$( )` cannot hand the status back to its
# caller — the subshell dies with it. A `say` is a file append and survives, so
# the one line the ticket asks for is written HERE and callers only branch on rc.
# Callers must never read GH_REST_STATUS after a `$(br_pr_field …)`.

# br_pr_field <url> <jq-filter> [what] — one field of the REST PR object, on
# stdout. A null field renders as EMPTY at rc 0 (jq `// empty`): a head repo
# somebody deleted is a read that WORKED and said "no branch".
br_pr_field() {
  local url="${1:--}" filter="$2" what="${3:-pr read}" slug num f rc v
  slug=$(br_slug_of_url "$url") || return 75
  num=$(mc_num_of_url "$url"); [ -n "$num" ] || return 75
  f=$(mktemp) || return 75
  gh_rest GET "repos/$slug/pulls/$num" > "$f" 2>/dev/null; rc=$?
  case "$rc" in
    0)  if jq -e . "$f" >/dev/null 2>&1; then
          v=$(jq -r "$filter // empty" "$f" 2>/dev/null) || v=""
          printf '%s' "$v"
        else
          rc=75
          say "$url: $what UNVERIFIABLE (HTTP $GH_REST_STATUS, unparsable body) — left as-is, retried next tick"
        fi ;;
    44) say "$url: $what — HTTP 404, the PR is absent" ;;
    *)  say "$url: $what UNVERIFIABLE (HTTP $GH_REST_STATUS${GH_REST_REASON:+ $GH_REST_REASON}) — left as-is, retried next tick" ;;
  esac
  rm -f "$f"
  return "$rc"
}

# br_pr_state <url> -> open | merged | closed, the contract's own three words.
# `merged` is closed AND a merged_at, never the one without the other.
br_pr_state() {
  br_pr_field "$1" 'if .state=="closed" and .merged_at!=null then "merged" else .state end' "pr state"
}

# br_pr_comment <url> <body> — rc 0 posted, rc 75 not. The body goes to a 0600
# temp file and is passed as `-F body=@<file>`, so it never reaches argv (or
# anybody's process list).
br_pr_comment() {
  local url="${1:--}" slug num f rc
  slug=$(br_slug_of_url "$url") || return 75
  num=$(mc_num_of_url "$url"); [ -n "$num" ] || return 75
  f=$(mktemp) || return 75; chmod 600 "$f" 2>/dev/null
  printf '%s\n' "${2:-}" > "$f"
  gh_rest_comment "$slug" "$num" "$f"; rc=$?
  rm -f "$f"
  return "$rc"
}

# br_issue_comment <owner/repo> <issue> <body> — the same, on an issue.
br_issue_comment() {
  local slug="${1:-}" issue="${2:-}" f rc
  [ -n "$slug" ] && [ -n "$issue" ] || return 75
  f=$(mktemp) || return 75; chmod 600 "$f" 2>/dev/null
  printf '%s\n' "${3:-}" > "$f"
  gh_rest_comment "$slug" "$issue" "$f"; rc=$?
  rm -f "$f"
  return "$rc"
}
# <<< br-rest

# br_pr_ref <url> [fallback-slug] — "<slug> <branch> <head>" for a PR, read with a
# token that can actually SEE the repo.
#
#   rc 0  the read worked: "<slug> <branch> <head>" on stdout.
#   rc 1  the PR was READ and genuinely has no branch (head.ref null — the head
#         repo was deleted), or there is no URL to read at all.
#   rc 2  THE READ FAILED — gh exited non-zero, or answered an empty body. The
#         first line of gh's error is printed on stdout and left in
#         BR_PR_REF_ERR. Callers must retry next tick, NOT spend a rung: the
#         stdout copy is what survives `ref=$(br_pr_ref …)`, because a global set
#         inside a command substitution dies with the subshell.
#
# THE 1-vs-2 SPLIT IS THE BUG. 2026-09-16 17:24Z and 18:04Z: both hub PATs are
# the same GitHub user (id 2220366), so they share one 5000/hr GraphQL budget and
# it ran out — "API rate limit already exceeded for user ID 2220366". The read
# answered nothing, this function returned 1, and both callers read that as "this
# PR has no branch": project-5 #1677, #1696 (ticket/TK-1669) and #1694
# (ticket/TK-1564-r2) were OPEN and mergeable=true and were sent to REBUILD
# FRESH, with a duplicate pool build enqueued for TK-1669. Clean PRs that needed
# a re-review were thrown away because GitHub was rate-limiting us.
#
# THE READ IS REST, NEVER GRAPHQL (the fleet lesson behind
# docs/verification-map/gh-pr-list-rest.md): `gh pr view --json` is a GraphQL
# call and spends the bucket that was exhausted, while `gh api repos/…/pulls/N`
# spends the far larger core bucket and carries the same two fields.
#
# The retry under the repo's own token stays. gh-repo-token.sh exists precisely
# because the hub's default PAT cannot see example-org/project-5, and a read made
# with it is a failed read rather than a PR without a branch.
br_pr_ref() {
  local url="${1:--}" fallback="${2:-}" slug num br="" head="" out rc=0 try errf
  BR_PR_REF_ERR=""
  [ -n "$url" ] && [ "$url" != "-" ] || return 1
  slug=$(br_slug_of_url "$url") || slug="$fallback"
  [ -n "$slug" ] || return 1
  num=$(mc_num_of_url "$url")
  [ -n "$num" ] || return 1
  errf=$(mktemp 2>/dev/null) || errf=/dev/null
  # The read memo answers first (BH-5946): the same PR object every gate before
  # the rung already read. Any read it cannot make is the raw read below.
  if command -v br_opt_readmemo_pr_ref >/dev/null 2>&1 && out=$(br_opt_readmemo_pr_ref "$slug" "$num"); then
    read -r head br <<<"$out"
  else
  for try in 1 2; do
    [ "$try" = 2 ] && br_use_token "$slug"
    out=$(gh api "repos/$slug/pulls/$num" --jq '"\(.head.sha) \(.head.ref)"' 2>"$errf"); rc=$?
    if [ "$rc" = 0 ] && [ -n "$out" ]; then read -r head br <<<"$out"; break; fi
    BR_PR_REF_ERR=$(head -n 1 "$errf" 2>/dev/null | tr -d '\r')
    [ -n "$BR_PR_REF_ERR" ] || BR_PR_REF_ERR="gh api repos/$slug/pulls/$num answered an empty body (rc=$rc)"
    rc=2
  done
  fi
  [ "$errf" = /dev/null ] || rm -f "$errf"
  # A READ THAT FAILED IS NOT AN ANSWER. It says nothing about the branch, so it
  # ends here and the caller comes back next tick.
  [ "$rc" = 2 ] && { printf '%s' "$BR_PR_REF_ERR"; return 2; }
  BR_PR_REF_ERR=""
  [ "${br:-}" = null ] && br=""
  [ "${head:-}" = null ] && head=""
  # A HEAD IS A SHA OR IT IS NOTHING (2026-09-16). The paired read is positional,
  # so a first field that is not the sha slides the branch into `head`:
  # ` ticket/TK-93` reads back as head=ticket/TK-93, br= — leaving a branch NAME
  # in the variable rung 2 falls back to for its push lease. That is the same
  # shape as the bare `rev-parse` this file already documents: a string that is
  # not a sha became a --force-with-lease value. jq prints a genuinely absent
  # field as `null` (handled above), so anything that is not 40 hex here is a
  # read that did not answer.
  case "${head:-}" in
    *[!0-9a-fA-F]* | "") head="" ;;
    *) [ "${#head}" = 40 ] || head="" ;;
  esac
  # THE BRANCH IS REQUIRED, THE HEAD IS NOT. Rung 1 needs a head for its push
  # lease and checks for one itself; rung 2 reads its own lease off `origin/<br>`
  # and never needed the sha, so a head that would not read must not cost that
  # rung the branch it CAN have.
  [ -n "${br:-}" ] || return 1
  printf '%s %s %s' "$slug" "$br" "${head:-}"
}

# br_close_pr <url> <why> — comment the reason, close the PR, VERIFY the close.
# The branch is NEVER deleted: an -rN rebuild leans on the old name still being
# taken, and a deleted branch is evidence gone.
#
#   rc 0   there is nothing to close (no url, a PR GitHub says is absent, one
#          that is already closed or merged), or the PR was closed AND a fresh
#          read confirmed it.
#   rc 3   REFUSED (BH-4664): a positive read says an outsider wrote this PR
#          (harness_pr_author_match says it is not ours). Nothing is commented
#          or closed; the caller parks the row for the author and records
#          nothing. An author read that answered with no login is NOT an
#          outsider and keeps the path below; one that FAILED is rc 75.
#   rc 75  GitHub did not answer — the state read, the author read, the comment
#          or the PATCH. The PR is left EXACTLY as it is, the caller defers its
#          whole rung and the park is re-offered next tick.
#
# THE EMPTY ANSWER WAS THE BUG (#768/#783). This used to ask `gh pr view --json
# state` and compare the answer to OPEN: under a GraphQL rate limit that read
# came back EMPTY, "not OPEN" meant "nothing to close", and rc 0 told
# br_rebuild_fresh and br_abandon to carry on — enqueueing a duplicate build and
# stamping ABANDONED over PRs that were open the whole time.
br_close_pr() {
  local url="${1:--}" why="${2:-}" slug num st rc login
  [ -n "$url" ] && [ "$url" != "-" ] || return 0
  # Not a PR URL at all is ABSENCE, not an unreadable PR: there is nothing here
  # to close and no later tick will make one appear.
  slug=$(br_slug_of_url "$url") || return 0
  num=$(mc_num_of_url "$url"); [ -n "$num" ] || return 0
  st=$(br_pr_state "$url"); rc=$?
  case "$rc" in
    0)  [ "$st" = open ] || return 0 ;;
    44) return 0 ;;
    *)  return 75 ;;
  esac
  if command -v harness_pr_author_match >/dev/null 2>&1; then
    # A FAILED AUTHOR READ DEFERS, like the state read above it: the belt is the
    # backstop for an outsider PR that reached a terminal, so an unknown author
    # is never closed on.
    login=$(br_pr_field "$url" '.user.login' "pr author") || return 75
    if [ -n "$login" ] && [ "$login" != null ] && ! harness_pr_author_match "$login"; then
      say "refused: $url is an external author's PR — never closed by this lane"
      return 3
    fi
  fi
  # THE COMMENT FIRST. A PR closed with no reason on it is the worse failure; a
  # comment that lands before a PATCH that does not is repeated next tick.
  if ! br_pr_comment "$url" "$why"; then
    say "could not comment on $url before closing (HTTP $GH_REST_STATUS) — left open, retried next tick"
    return 75
  fi
  # gh_rest_close answers 0 only when a FRESH read says closed, so the "closed"
  # line below is written on evidence and never on a 2xx.
  if gh_rest_close "$slug" "$num" pulls; then
    say "closed $url ($why)"
    # A later row of this run reads the closed PR live (BH-5946).
    command -v br_opt_readmemo_drop >/dev/null 2>&1 && br_opt_readmemo_drop "$url"
    return 0
  fi
  say "could not close $url (HTTP $GH_REST_STATUS) — left open, retried next tick"
  return 75
}

# ---------------------------------------------------------------------------
# THE HOLD GATE. A human said "do not rebuild this" on the TICKET, and until
# 2026-09-18 nothing on this lane's rebuild path ever read the ticket.
#
# Console alert 6726 (2026-09-14): project-5 #414's parent PR was CLOSED, the
# issue put on HOLD and de-labelled by the operator at 07:03Z, and this lane enqueued a
# fresh build of it three times that morning (05:04, 06:44, 08:24Z). The rung
# read the PR's merge state and its own counters; the only `gh issue` calls in
# this whole file were the two comment WRITES. So the instruction was invisible
# to the one lane whose job is restarting tickets.
#
# The gate runs BEFORE anything irreversible — before the close, before the
# enqueue, before the cap check that would write an ABANDONED alert — so there
# is no window where a PR has been closed and the rebuild is then refused.
# ---------------------------------------------------------------------------
# br_hold_issue <project> <ticket-key> <record> — "<slug> <issue-number>" for the
# GitHub issue behind this park, or rc 1 when this lane is not one that has one.
#   rc 1  an in-app product board (board_prefix != "-"): the ticket is not a
#         GitHub issue, so there is nothing to read and the gate is a no-op.
#   rc 2  an issues lane whose slug or number could not be named — logged once
#         by the caller, and today's behaviour otherwise (a lane that cannot
#         name the issue cannot read it).
br_hold_issue() {
  local p="$1" tkey="$2" rec="${3:--}" prefix slug n
  prefix=$("$H/bin/fleet-conf.sh" "$p" board_prefix 2>/dev/null)
  [ "$prefix" = "-" ] || return 1
  slug=$("$H/bin/fleet-conf.sh" "$p" repo 2>/dev/null)
  case "$slug" in */*) ;; *) return 2 ;; esac
  n=$(br_ticket_id "$p" "$tkey" "$rec") || n=""
  case "$n" in ''|*[!0-9]*) return 2 ;; esac
  printf '%s %s' "$slug" "$n"
}

# br_hold_gate <project> <rkey> <reason> <pr-url> <record> <ticket-key>
#   rc 0 proceed, rc 1 STOP. Called at both places a build is (re)started.
#
#   held       one log line in the ticket's own spelling, the row parked at the
#              HELD terminal, NO rung spent, nothing closed, nothing enqueued,
#              no GitHub write, no ALERTS line (a respected human instruction is
#              not an alert) and no ticket comment (a comment per tick on a held
#              issue is noise nobody asked for).
#   unreadable no rung spent and nothing written but ONE attempt per episode: a
#              read that failed says NOTHING about the ticket, so the park is
#              re-offered next tick. The same 1-vs-2 split br_pr_ref learned on
#              2026-09-16.
#   clear      silent, rc 0.
#
#   BR_HOLD_PARKED is set on both refusals so br_one knows the rung did not run.
#   A conductor hand-off released after a refusal would hand the PR straight back
#   to the conductor to classify and re-park, every tick, over a read this box
#   could not make.
BR_HOLD_PARKED=0
br_hold_gate() {
  local p="$1" rkey="$2" reason="$3" url="${4:--}" rec="${5:--}" tkey="${6:--}"
  local ck ref slug n out rc why uf
  command -v hold_check >/dev/null 2>&1 || return 0
  ref=$(br_hold_issue "$p" "$tkey" "$rec"); rc=$?
  case "$rc" in
    1) return 0 ;;
    2) say "$p/$rkey [$reason]: no repo/issue number for ${tkey:--} — the hold gate has nothing to read, proceeding as before"
       return 0 ;;
  esac
  read -r slug n <<<"$ref"
  ck=$(br_cap_key "$p" "$rkey" "$tkey")
  uf="$ST/$p/$ck.hold-unreadable"
  # hold_read (bin/lib/hold-push.sh) is hold_check's verdict over the REST
  # contract this lane already speaks (BH-2504), so every gate here and the
  # fix round's push read the ticket the same way.
  if command -v hold_read >/dev/null 2>&1; then out=$(hold_read "$slug" "$n"); rc=$?
  else out=$(hold_check "$slug" "$n"); rc=$?; fi
  why=$(printf '%s' "$out" | cut -f2-)
  case "$rc" in
    0) rm -f "$uf"; return 0 ;;
    2) BR_HOLD_PARKED=1
       say "$p/$rkey: hold check could not read $slug#$n ($why) — no rung spent, retried next tick"
       # ONE attempt per EPISODE, the way br_setup_blocked does it. This lane
       # re-offers the same park every ten minutes, so an outage that lasts a day
       # would otherwise write 144 entries into a record whose whole job is to
       # say what was TRIED — and every one of them would displace the
       # `rebuild-fresh` attempt br_from_rebuilds reads to find a build in
       # flight. The log line above is the per-tick evidence; the marker is
       # deleted the moment gh answers, so the next outage says it all again.
       [ -e "$uf" ] && return 1
       mkdir -p "$(dirname "$uf")" 2>/dev/null; : > "$uf"
       br_record "$p" "$ck" hold-unreadable "$reason" "could not read $slug#$n: $why"
       return 1 ;;
  esac
  rm -f "$uf"
  BR_HOLD_PARKED=1
  # AN ABANDON IS A DIFFERENT INSTRUCTION FROM A HOLD (BH-1460). The two used to
  # be one word, so the only way to say "close this PR" on a ticket was the same
  # word that means "pause everything" — and a pause that closes a green,
  # approved PR is the 2026-09-22 #1453 shape. A ticket that says ABANDON gets
  # its PR closed, with the word that did it named on the PR.
  if command -v hold_is_abandon >/dev/null 2>&1 && hold_is_abandon "$out"; then
    if [ "$OBSERVE" = 1 ]; then
      say "$p/$rkey [$reason]: WOULD abandon — $slug#$n says $why — observe mode"
      return 1
    fi
    br_hold_abandon "$p" "$ck" "$rkey" "$reason" "$url" "$rec" "$tkey" "$slug#$n" "$why"
    return 1
  fi
  if [ "$OBSERVE" = 1 ]; then
    say "$p/$rkey [$reason]: WOULD hold — $slug#$n says $why — observe mode"
    return 1
  fi
  br_record "$p" "$ck" held "$reason" "$slug#$n is held ($why)"
  br_set_outcome "$p" "$ck" HELD
  br_set_field "$p" "$ck" held_rec "${rec:--}"
  [ -n "$rec" ] && [ "$rec" != "-" ] && [ -d "$rec" ] && : > "$rec/.blocked-resolver-held"
  br_event resolver_held "$p" "$ck" "$reason" "$slug#$n is held ($why) — no rebuild, no enqueue, no close"
  # "held, PR kept" IS THE CONTRACT, SPELLED OUT (BH-1460). This lane has always
  # left the PR alone on a hold; saying it in the words the ticket uses is what
  # makes the next reader — and the next test — able to tell a pause from an
  # abandon at a glance.
  say "[resolver] HOLD respected ${tkey:--} ($why) — held, PR kept: no rebuild, no enqueue, PR ${url:--} left as it is"
  # Waiting on a human step (BH-3443) says which step, in every lane's words.
  case "$why" in hold:waiting-on-human\ *)
    say "$p/$rkey: #$n skip :: waiting on human: $(printf '%s' "${why#hold:waiting-on-human }" | cut -d' ' -f2-)" ;;
  esac
  return 1
}

# ---------------------------------------------------------------------------
# THE BOARD-DONE GATE (BH-4438). br_hold_gate reads a GitHub issue and is a
# no-op on every product-board project, so nothing on the rebuild path ever
# read a board ticket's status: project-3 TK-231 was rebuilt after it was already
# done on the board, and the rebuild ended PLAN_BLOCKED (alert 19435).
# ---------------------------------------------------------------------------
# br_board_status <project> <ticket-key> — the ticket's live board `.status`,
# read the way br_ticket_id reads the board (bin/stale-owed-tickets.sh's read).
#   rc 0  the board answered and lists the ticket (status printed, may be empty)
#   rc 1  not a product-board project: nothing to read
#   rc 2  UNREADABLE: no prod base, no token, no board id, a non-2xx, or a body
#         that is not a ticket list (the BH-1007 rule: only 2xx WITH a list
#         counts as the board answering). The reason is printed.
#   rc 3  the board answered, and this ticket is not on it
br_board_status() {
  local p="$1" tkey="$2" prefix base token bid bodyf code body out
  prefix=$("$H/bin/fleet-conf.sh" "$p" board_prefix 2>/dev/null)
  [ -n "$prefix" ] && [ "$prefix" != "-" ] || return 1
  base=$("$H/bin/fleet-conf.sh" "$p" prod 2>/dev/null); [ "$base" = "-" ] && base=""
  [ -n "$base" ] || { printf 'no prod base'; return 2; }
  token=$("$H/bin/internal-token-for.sh" "$p" 2>/dev/null) || token=""
  [ -n "$token" ] || { printf 'no internal token'; return 2; }
  bid=$(curl -s -m 20 -H "Authorization: Bearer $token" -H "User-Agent: curl/8" "$base$prefix/boards" 2>/dev/null \
        | jq -r 'if type=="array" then (.[0].id // empty) else (.boards[0].id // empty) end' 2>/dev/null)
  [ -n "$bid" ] || { printf 'no board id'; return 2; }
  bodyf=$(mktemp) || { printf 'no temp file'; return 2; }
  code=$(curl -s -m 30 -o "$bodyf" -w '%{http_code}' \
        -H "Authorization: Bearer $token" -H "User-Agent: curl/8" \
        "$base$prefix/boards/$bid/tickets" 2>/dev/null) || code=000
  body=$(cat "$bodyf" 2>/dev/null); rm -f "$bodyf"
  case "$code" in 2*) ;; *) printf 'HTTP %s' "${code:-000}"; return 2 ;; esac
  printf '%s' "$body" | jq -e 'type=="array" or (type=="object" and has("tickets"))' >/dev/null 2>&1 \
    || { printf 'HTTP %s, not a ticket list' "$code"; return 2; }
  # S:<status> when listed (an absent status is an empty one), MISS when not.
  out=$(printf '%s' "$body" | jq -r --arg k "$tkey" '
    [(if type=="array" then . else (.tickets // []) end)[]
     | select((.key // "") == $k or ((.number // -1) == ($k | split("-") | last | try tonumber catch -1)))]
    | if length == 0 then "MISS" else "S:" + (.[0].status // "" | tostring) end' 2>/dev/null)
  case "$out" in
    S:*) printf '%s' "${out#S:}"; return 0 ;;
    MISS) return 3 ;;
  esac
  printf 'HTTP %s, unparseable ticket list' "$code"
  return 2
}

# br_board_done_gate <project> <rkey> <reason> <pr-url> <record> <ticket-key>
#   rc 0 proceed, rc 1 STOP. Called in both rebuild rungs right after
#   br_hold_gate, so before the cap check, the supersede close and the enqueue.
#   done      (status in the closed set) the rebuild is dropped: one done-on-board
#             attempt, outcome RESOLVED_DONE, the record marked superseded, the
#             queue row closed done, one line. Nothing closed, nothing enqueued,
#             no ALERTS line, no ticket comment. Said ONCE, never per tick.
#   unreadable no rung spent, nothing enqueued or closed, no outcome: one log
#             line per tick and ONE hold-board-unreadable attempt per episode
#             (the hold-unreadable precedent). The `hold-` prefix keeps
#             br_from_rebuilds reading past it, so a retry row stays offered.
#   open      proceed; a RESOLVED_DONE left by an earlier tick (the ticket was
#             reopened) is cleared with one done-lifted attempt.
#   not a board project / not listed: proceed. A miss stays on the BH-1007
#             board-miss ladder in br_enqueue_fresh.
# The closed set is CLOSED_STATUSES in bin/triage-state.py, the fleet's one
# definition of a closed in-app status.
BR_BOARD_CLOSED=" done closed cancelled canceled archived rejected resolved completed wontfix "
br_board_done_gate() {
  local p="$1" rkey="$2" reason="$3" url="${4:--}" rec="${5:--}" tkey="${6:--}"
  local ck out rc s uf msg
  [ -n "$tkey" ] && [ "$tkey" != "-" ] || return 0
  out=$(br_board_status "$p" "$tkey"); rc=$?
  case "$rc" in 1|3) return 0 ;; esac
  ck=$(br_cap_key "$p" "$rkey" "$tkey")
  uf="$ST/$p/$ck.board-unreadable"
  if [ "$rc" != 0 ]; then
    BR_HOLD_PARKED=1
    say "$p/$rkey [$reason]: board state for $tkey unreadable (${out:-unknown}) — no rebuild, no rung spent, retried next tick"
    [ "$OBSERVE" = 1 ] && return 1
    [ -e "$uf" ] && return 1
    mkdir -p "$(dirname "$uf")" 2>/dev/null; : > "$uf"
    br_record "$p" "$ck" hold-board-unreadable "$reason" "could not read $tkey on the board: ${out:-unknown}"
    return 1
  fi
  s=$(printf '%s' "$out" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  # An exact member of the set, never a substring: "not done" and "done-review"
  # are open. An empty status is open too (the board answered with the ticket).
  case "$s" in ''|*[[:space:]]*) s="" ;; esac
  case "$BR_BOARD_CLOSED" in *" $s "*) ;; *) s="" ;; esac
  if [ -z "$s" ]; then
    [ "$OBSERVE" = 1 ] && return 0
    rm -f "$uf"
    if [ "$(br_load "$p" "$ck" | jq -r '.outcome // ""' 2>/dev/null)" = RESOLVED_DONE ]; then
      br_set_outcome "$p" "$ck" ""
      br_record "$p" "$ck" done-lifted "$reason" "$tkey reads '${out}' on the board again — rebuild allowed"
      say "$p/$rkey [$reason]: $tkey is open on the board again ('${out}') — RESOLVED_DONE lifted"
    fi
    return 0
  fi
  BR_HOLD_PARKED=1
  msg="$tkey reads '$out' on the board — rebuild dropped"
  if [ "$OBSERVE" = 1 ]; then
    say "$p/$rkey [$reason]: WOULD drop the rebuild — $msg — observe mode"
    return 1
  fi
  rm -f "$uf"
  [ "$(br_load "$p" "$ck" | jq -r '.outcome // ""' 2>/dev/null)" = RESOLVED_DONE ] && return 1
  br_record "$p" "$ck" done-on-board "$reason" "$msg"
  br_set_outcome "$p" "$ck" RESOLVED_DONE
  br_set_field "$p" "$ck" done_status "$s"
  [ -n "$rec" ] && [ "$rec" != "-" ] && [ -d "$rec" ] && { : > "$rec/.blocked-resolver-superseded"; touch "$rec/COMMENTED" 2>/dev/null; }
  command -v queue_done >/dev/null 2>&1 \
    && queue_done "$p" "$tkey" done "$msg" >/dev/null 2>&1
  br_event resolver_done_on_board "$p" "$ck" "$reason" "$msg — no rebuild, no enqueue, no close"
  say "[resolver] $tkey is $s on the board — rebuild dropped, PR ${url:--} left as it is"
  return 1
}

# br_rung_hold_gate <project> <rkey> <reason> <pr-url> <record> <ticket-key>
#   THE GATE IN FRONT OF EVERY OTHER RUNG (BH-2504): rc 0 run the rung, rc 1 the
#   ticket is HELD (br_hold_gate did the bookkeeping: the one respected line,
#   the HELD row the next tick re-reads, or the ABANDON close).
#   AN UNREADABLE READ RUNS THE RUNG, which is where this differs from the
#   rebuild gate, and on purpose: every rung that could write the branch pushes
#   through hold_push, which re-reads the ticket AT the push and refuses on an
#   unreadable answer. A read outage therefore cannot reach a branch, and
#   parking every fix round in the fleet for its duration would be a stall
#   bought for nothing. One line says so.
br_rung_hold_gate() {
  local p="$1" rkey="$2" reason="$3" url="${4:--}" rec="${5:--}" tkey="${6:--}" ref slug n out rc
  command -v hold_check >/dev/null 2>&1 || return 0
  ref=$(br_hold_issue "$p" "$tkey" "$rec") || return 0
  read -r slug n <<<"$ref"
  # hold_read (bin/lib/hold-push.sh) is hold_check's verdict over the REST
  # contract this lane already speaks (BH-2504), so every gate here and the
  # fix round's push read the ticket the same way.
  if command -v hold_read >/dev/null 2>&1; then out=$(hold_read "$slug" "$n"); rc=$?
  else out=$(hold_check "$slug" "$n"); rc=$?; fi
  case "$rc" in
    0) return 0 ;;
    2) say "$p/$rkey [$reason]: the hold on $slug#$n could not be read before the rung ($(printf '%s' "$out" | cut -f2-)) — running it; its push re-reads the hold and refuses on the same answer"
       return 0 ;;
  esac
  br_hold_gate "$p" "$rkey" "$reason" "$url" "$rec" "$tkey" && return 0
  return 1
}

# br_hold_abandon <project> <cap-key> <rkey> <reason> <pr-url> <record>
#                 <ticket-key> <slug#n> <why>
#   The ABANDON word's rung. It closes the PR NAMING THE WORD, writes the
#   ABANDONED terminal, and moves the rows that would otherwise re-offer the
#   ticket for ever (the conductor's, the pool's).
#
#   NO ALERTS LINE, and that is the same rule a respected hold follows: this is
#   an instruction being obeyed, not an incident somebody has to be paged about.
#   br_abandon's alert exists because a ladder ran out on its own; here a person
#   asked for it in writing, on the ticket, and the ticket already says so.
#
#   THE CLOSE COMES FIRST and a refusal defers the whole terminal (#783's
#   lesson, verbatim from br_abandon): an ABANDONED stamp over a PR this lane
#   could not close is the worst of both — the row reads terminal, the PR stays
#   open, and nothing looks at it again.
br_hold_abandon() {
  local p="$1" ck="$2" rkey="$3" reason="$4" url="${5:--}" rec="${6:--}" tkey="${7:--}"
  local ref="${8:-the ticket}" why="${9:-}" ckey
  # THE QUOTED LINE IS FLATTENED FIRST. `$why` is a line a person typed on the
  # ticket, and it goes out inside a backtick span: one backtick in their
  # comment closes the span early and the rest of the sentence renders as prose
  # — or, worse, swallows the paragraph after it. hold_classify already caps and
  # flattens the line; this takes the one character that is markup HERE.
  why=${why//\`/\'}
  local crc=0
  br_close_pr "$url" "Closing this PR because ${ref} says ABANDON.

The instruction read: \`${why}\`

A \`HOLD\` on a ticket pauses this harness and leaves an open PR exactly as it is; \`ABANDON\` (or \`CLOSE-PR\`) is the word that closes one. The branch is left in place, so nothing here is lost — reopen this PR, or comment \`RESUME\` on the ticket for a fresh build." || crc=$?
  if [ "$crc" = 3 ]; then
    br_xpr_parked "$p/$rkey [$reason]: $url is an external author's PR — parked for the author, nothing recorded"
    return 0
  fi
  if [ "$crc" != 0 ]; then
    say "$p/$rkey [$reason]: ABANDON deferred — the PR could not be closed this tick, so the terminal was NOT recorded; retried next tick"
    return 1
  fi
  br_record "$p" "$ck" abandoned "$reason" "$ref says ABANDON ($why)"
  br_set_outcome "$p" "$ck" ABANDONED
  br_row_closed "$p" "$tkey" "$rec" "$url" abandoned "closed unmerged: $ref says ABANDON" "$reason"
  [ -n "$rec" ] && [ "$rec" != "-" ] && [ -d "$rec" ] && { : > "$rec/.blocked-resolver-abandoned"; touch "$rec/COMMENTED" 2>/dev/null; }
  br_event resolver_abandoned "$p" "$ck" "$reason" "$ref says ABANDON ($why) — the PR was closed and the ticket left as it is"
  if [ -n "$url" ] && [ "$url" != "-" ]; then
    ckey=$(mc_slug_of_url "$url")
    [ -n "$ckey" ] && mc_transition "$ckey#$(mc_num_of_url "$url")" ABANDONED "blocked-resolver: the ticket says ABANDON" "-" "-" "$url" "-" "-" "${rec:--}" >/dev/null
  fi
  [ "$tkey" != "-" ] && command -v queue_done >/dev/null 2>&1 \
    && queue_done "$p" "$tkey" failed "the ticket says ABANDON — the PR was closed by the blocked-resolver" >/dev/null 2>&1
  say "[resolver] ABANDON respected ${tkey:--} ($why) — PR ${url:--} closed, the ticket left open for whatever comes next"
  return 0
}

# br_hold_recheck <project> <rkey> <reason> <cap-key> <ticket-key> <record> <state-json>
#   HELD IS TERMINAL FOR THE LADDER AND STILL RE-READ. rc 0 = the hold has
#   lifted and this tick may run the ladder with its counters intact; rc 1 =
#   still held, or unreadable, in which case the caller spends nothing and says
#   nothing (the one line was written at the transition).
#
#   Nothing in this harness waits on a person to clear state by hand, so the
#   lift needs no human plumbing: the issue itself says when the ladder resumes.
#   The outcome is cleared and the marker removed BEFORE the ladder runs, so a
#   crash between them leaves a clear row the next tick re-offers — never a held
#   row with a build in flight.
br_hold_recheck() {
  local p="$1" rkey="$2" reason="$3" ck="$4" tkey="$5" rec="${6:--}" st="$7"
  local ref slug n out rc why hrec
  command -v hold_check >/dev/null 2>&1 || return 1
  ref=$(br_hold_issue "$p" "$tkey" "$rec") || return 1
  read -r slug n <<<"$ref"
  # hold_read (bin/lib/hold-push.sh) is hold_check's verdict over the REST
  # contract this lane already speaks (BH-2504), so every gate here and the
  # fix round's push read the ticket the same way.
  if command -v hold_read >/dev/null 2>&1; then out=$(hold_read "$slug" "$n"); rc=$?
  else out=$(hold_check "$slug" "$n"); rc=$?; fi
  why=$(printf '%s' "$out" | cut -f2-)
  # A PARKED ROW CAN STILL BE ABANDONED (BH-1460). The newest word on a held
  # ticket is allowed to be ABANDON, and a row that could only ever be lifted
  # would sit HELD for ever while the ticket already said what to do with it.
  # rc is still 1 (an abandon is "do not build" too), so this is asked before
  # the lift test and answers 1 either way: the ladder does not run on the tick
  # that closes the PR.
  if [ "$rc" = 1 ] && command -v hold_is_abandon >/dev/null 2>&1 && hold_is_abandon "$out"; then
    [ "$OBSERVE" = 1 ] && { say "$p/$rkey: WOULD abandon — $slug#$n says $why — observe mode"; return 1; }
    br_hold_abandon "$p" "$ck" "$rkey" "$reason" "${8:--}" "$rec" "$tkey" "$slug#$n" "$why"
    return 1
  fi
  # Still held is a quiet look (BH-5946); an unreadable read (rc 2) is not.
  if [ "$rc" != 0 ]; then [ "$rc" = 1 ] && br_quiet held; return 1; fi
  br_set_outcome "$p" "$ck" ""
  # gh answered, so the unreadable episode (if there was one) is over.
  rm -f "$ST/$p/$ck.hold-unreadable"
  hrec=$(printf '%s' "$st" | jq -r '.held_rec // ""' 2>/dev/null)
  [ -n "$hrec" ] && [ "$hrec" != "-" ] && rm -f "$hrec/.blocked-resolver-held"
  [ -n "$rec" ] && [ "$rec" != "-" ] && rm -f "$rec/.blocked-resolver-held"
  br_record "$p" "$ck" hold-lifted "$reason" "$slug#$n is clear ($why) — the ladder resumes"
  br_event resolver_hold_lifted "$p" "$ck" "$reason" "$slug#$n is clear ($why)"
  say "$p/$rkey: HOLD lifted on $slug#$n — the ladder resumes with its counters intact"
  return 0
}

# br_needs_human_park <project> <rkey> <reason> <pr-url> <record> <ticket-key>
#                     <cap-key> <state-json>
#   A REVIEW BLOCK ONLY A PERSON CAN CLEAR IS PARKED ON THE TICKET, NOT REBUILT
#   (BH-3443, slice 2 of BH-3433). BH-3348 paid $6.53 in rebuilds that each
#   ended on the same step the hub had to take. The review stage appends
#   ` NEEDS_HUMAN:<fp>:<action>` to such a RESULT line; this reads it, has
#   bin/needs-human-hold.sh put the marker on the issue, and parks the row HELD
#   through br_hold_gate, whose re-read on every tick (br_hold_recheck) is
#   what lifts it when a person answers HUMAN-STEP-DONE:.
#   rc 0  not a needs-human block, or nothing placed: the rung runs as today
#   rc 3  parked (or the placer could not read the thread): no rung this tick
#   rc 4  this exact RESULT was placed before and the ticket reads clear now:
#         the human did the step, so the ticket re-enters as a fresh build
#   `nh_placed` (<fp> <sha12 of the RESULT line>) is the only state this adds,
#   and it only stops a second marker after the lift; the marker's own nh-fp
#   tag is the placer's dedupe on GitHub.
br_needs_human_park() {
  local p="$1" rkey="$2" reason="$3" url="${4:--}" rec="${5:--}" tkey="${6:--}" ck="$7" st="$8"
  local res="" fp act key ref slug n rc
  [ "$reason" = rebuild-review-blocked ] && res=$(printf '%s' "$st" | jq -r '.rebuild_result // ""' 2>/dev/null)
  [ "$res" = "-" ] && res=""
  [ -z "$res" ] && [ "$rec" != "-" ] && [ -d "$rec" ] && res=$(head -1 "$rec/RESULT" 2>/dev/null)
  case "$res" in *" NEEDS_HUMAN:"*) ;; *) return 0 ;; esac
  fp=$(printf '%s' "$res" | sed -nE 's/.* NEEDS_HUMAN:([0-9a-f]+):.*/\1/p')
  [ -n "$fp" ] || return 0
  act="${res#* NEEDS_HUMAN:"$fp":}"
  [ -n "$act" ] && [ "$act" != "$res" ] || return 0
  key="$fp $(printf '%s' "$res" | sha1sum | cut -c1-12)"
  [ "$(printf '%s' "$st" | jq -r '.nh_placed // ""' 2>/dev/null)" = "$key" ] && return 4
  ref=$(br_hold_issue "$p" "$tkey" "$rec") || return 0
  read -r slug n <<<"$ref"
  if [ "$OBSERVE" = 1 ]; then
    say "$p/$rkey [$reason]: WOULD place a needs-human hold on $slug#$n ($act) — observe mode"
    return 3
  fi
  HARNESS="$H" "$H/bin/needs-human-hold.sh" "$p" "$n" "$fp" "$act" resolver >>"$LOG" 2>&1; rc=$?
  case "$rc" in
    0) ;;
    75) say "$p/$rkey [$reason]: needs-human hold on $slug#$n: thread unreadable — no rung spent, retried next tick"
        return 3 ;;
    *) say "$p/$rkey [$reason]: needs-human hold on $slug#$n was not placed (rc $rc) — the ladder runs as before"
       return 0 ;;
  esac
  # Clear here means nothing was placed (the switch is on): today's rung.
  br_hold_gate "$p" "$rkey" "$reason" "$url" "$rec" "$tkey" && return 0
  # Held: br_hold_gate parked the row and said so. An unreadable re-read or an
  # ABANDON on the ticket is its own answer, and records nothing here, so the
  # next tick asks again (the placer finds its fp and posts nothing twice).
  [ "$(br_load "$p" "$ck" | jq -r '.outcome // ""' 2>/dev/null)" = HELD ] || return 3
  br_set_field "$p" "$ck" nh_placed "$key"
  br_record "$p" "$ck" hold-needs-human "$reason" "$slug#$n waits on a human step: $act"
  return 3
}

# >>> data-lane park (BH-4926)
# A review block whose ONLY finding is a migration not yet applied to prod (the
# reviewer's DATA_LANE: line, bin/lib/data-lane.sh) waits on the data lane's
# pre-merge apply, not on a rebuild: a rebuild of the same diff ends on the same
# BLOCK, and rebuild-review-blocked -> abandon-rebuild is how TK-32 was
# ABANDONED. State, all on this ticket's record: outcome DATA_LANE (the park),
# data_lane_file/_fp (what was parked), data_lane_escalated=<fp> (alerted once),
# data_lane_released="<fp> <head>" (the one re-review, claimed before the call),
# data_lane_unbound="<fp> <head>" (the PR head moved past it: the ladder's).

# br_dl_eval <project> <record|-> <ticket-key> — is this park's review a
#   data-lane candidate? Sets BR_DL_REC BR_DL_FILE BR_DL_HEAD BR_DL_FP, so it is
#   called directly, never inside $( ). The record is <record> when it holds a
#   review.md, else the ticket's newest local build dir that does.
#   rc 0 candidate. rc 1 not one: a final round with no DATA_LANE line costs no
#   git call. rc 2 it HAS a DATA_LANE line but the reviewed sha, the diff or the
#   file could not be read: unreadable holds, it is never "not a candidate".
# _br_dl_fetch_due <sha> — rc 0 a fetch for this sha may run: no miss stamp, or
#   one older than BR_DL_FETCH_MISS_S. _br_dl_fetch_miss <sha> stamps a miss.
_br_dl_fetch_due() {
  local f="$ST/.dl-fetch-miss/$1" t
  [ -f "$f" ] || return 0
  t=$(tr -dc '0-9' < "$f" 2>/dev/null); [ -n "$t" ] || return 0
  [ $(( $(date -u +%s) - t )) -ge "${BR_DL_FETCH_MISS_S:-600}" ]
}
_br_dl_fetch_miss() { mkdir -p "$ST/.dl-fetch-miss" 2>/dev/null && date -u +%s > "$ST/.dl-fetch-miss/$1" 2>/dev/null; return 0; }

br_dl_eval() {
  local p="$1" rec="${2:--}" tkey="${3:--}" repo d diff blob mb cand rc=0
  BR_DL_REC=""; BR_DL_FILE=""; BR_DL_HEAD=""; BR_DL_FP=""
  command -v dl_candidate >/dev/null 2>&1 && command -v _nh_final >/dev/null 2>&1 || return 1
  if [ "$rec" = - ] || [ ! -f "$rec/review.md" ]; then
    rec=""
    if [ -n "$tkey" ] && [ "$tkey" != - ]; then
      # The trailing dash keeps BH-23 from answering for BH-234.
      for d in $(ls -td "$H"/builds/pool-"$p"-"$tkey"-*/ "$H"/builds/"$p"-"$tkey"-*/ 2>/dev/null); do
        [ -f "$d/review.md" ] && { rec="${d%/}"; break; }
      done
    fi
    [ -n "$rec" ] || return 1
  fi
  _nh_final "$rec/review.md" | tr -d '\r' | _nh_lines | grep -q '^DATA_LANE:' || return 1
  BR_DL_REC="$rec"
  BR_DL_HEAD=$(dl_reviewed_sha "$rec") || return 2
  repo="$REPOS/$p"
  diff=$(mktemp) || return 2
  blob=$(mktemp) || { rm -f "$diff"; return 2; }
  # A merged re-review header carries the SHORT sha review.sh writes (7 to 40
  # hex, dl_reviewed_sha). Resolve it to the full commit here, so every later
  # compare, dedupe key and reviewed-sha binding uses one form. A short sha
  # cannot be fetched by itself: fetch origin's branches (the PR branch is one)
  # and resolve again. Unresolvable or ambiguous holds (rc 2), never "moved".
  # A fetch runs only when the object is missing here; once fetched, later
  # ticks resolve it locally. A sha that a fetch could not find is not fetched
  # again for BR_DL_FETCH_MISS_S (600 s): one miss stamp per sha
  # (_br_dl_fetch_due), so an unresolvable park costs one fetch per window,
  # not one per tick and per br_abandon call (lead NOTE on dbed6c45).
  # The miss stamp is written ONLY when a fetch really ran and still could not
  # find the sha (lead BLOCK on 0d5f96563): a call inside the window skips the
  # fetch and leaves the stamp alone, so the window ends BR_DL_FETCH_MISS_S
  # after the last real fetch, not after the last tick.
  if ! [[ "$BR_DL_HEAD" =~ ^[0-9a-f]{40}$ ]]; then
    local full
    full=$(git -C "$repo" rev-parse --verify -q "$BR_DL_HEAD^{commit}" 2>/dev/null) || full=""
    if ! [[ "$full" =~ ^[0-9a-f]{40}$ ]] && _br_dl_fetch_due "$BR_DL_HEAD"; then
      git -C "$repo" fetch -q origin 2>/dev/null
      full=$(git -C "$repo" rev-parse --verify -q "$BR_DL_HEAD^{commit}" 2>/dev/null) || full=""
      [[ "$full" =~ ^[0-9a-f]{40}$ ]] || _br_dl_fetch_miss "$BR_DL_HEAD"
    fi
    [[ "$full" =~ ^[0-9a-f]{40}$ ]] || { rm -f "$diff" "$blob"; return 2; }
    BR_DL_HEAD="$full"
  fi
  local have=0
  git -C "$repo" cat-file -e "$BR_DL_HEAD^{commit}" 2>/dev/null && have=1
  if [ "$have" = 0 ] && _br_dl_fetch_due "$BR_DL_HEAD"; then
    git -C "$repo" fetch -q origin "$BR_DL_HEAD" 2>/dev/null && git -C "$repo" cat-file -e "$BR_DL_HEAD^{commit}" 2>/dev/null && have=1
    [ "$have" = 1 ] || _br_dl_fetch_miss "$BR_DL_HEAD"
  fi
  [ "$have" = 1 ] \
    && mb=$(git -C "$repo" merge-base origin/HEAD "$BR_DL_HEAD" 2>/dev/null) \
    && git -C "$repo" diff --name-only "$mb" "$BR_DL_HEAD" > "$diff" 2>/dev/null || rc=2
  if [ "$rc" = 0 ]; then cand=$(dl_candidate "$rec/review.md" "$diff"); rc=$?; fi
  if [ "$rc" = 0 ]; then
    BR_DL_FILE="${cand#*$'\t'}"
    git -C "$repo" show "$BR_DL_HEAD:$BR_DL_FILE" > "$blob" 2>/dev/null && BR_DL_FP=$(dl_fp "$blob") || rc=2
  fi
  rm -f "$diff" "$blob"
  return "$rc"
}

# br_dl_escalate <project> <rkey> <reason> <url> <cap-key> <ticket-key> <why>
#   ONCE per fingerprint. The record row and the stamp are written before the
#   send (br_stall's rule), so a failed send can never re-page every tick; the
#   alert's --id is the second dedupe. The row stays DATA_LANE.
br_dl_escalate() {
  local p="$1" rkey="$2" reason="$3" url="${4:--}" ck="$5" tkey="${6:--}" why="$7" ref
  [ "$(br_load "$p" "$ck" | jq -r '.data_lane_escalated // ""' 2>/dev/null)" = "$BR_DL_FP" ] && return 0
  if [ "$OBSERVE" = 1 ]; then say "$p/$rkey [$reason]: WOULD escalate the data-lane park ($BR_DL_FILE: $why) — observe mode"; return 0; fi
  br_record "$p" "$ck" escalate-data-lane "$reason" "$BR_DL_FILE fp=${BR_DL_FP:0:12}: $why"
  br_set_field "$p" "$ck" data_lane_escalated "$BR_DL_FP"
  ref="$tkey"
  case "$url" in https://github.com/*/pull/*) ref="$(mc_num_of_url "$url")" ;; esac
  "$H/bin/lane-alert.sh" --id "data-lane-escalate:$p:$ref:$BR_DL_FP" --severity warn blocked-resolver \
    "[$p] data-lane: $tkey ${url:+($url) }is parked because its only review BLOCK is $BR_DL_FILE, which is not applied to prod, and the data lane will not apply it: $why. The row stays DATA_LANE. Nothing was abandoned or closed." >/dev/null 2>&1 || true
  say "$p/$rkey [$reason]: data-lane park escalated once ($BR_DL_FILE fp ${BR_DL_FP:0:12}: $why) — the row stays DATA_LANE"
}

# br_dl_unbind <project> <rkey> <reason> <cap-key> <why> — this fp+head no
#   longer describes the PR (its head moved past the reviewed sha), so the park
#   hands the row back to the ladder and is never re-taken on the same fp+head:
#   data_lane_unbound="<fp> <head>". Nothing in this lane re-binds the record's
#   review.md, so a park that stayed would wait forever with nobody told.
br_dl_unbind() {
  local p="$1" rkey="$2" reason="$3" ck="$4" why="$5"
  if [ "$OBSERVE" = 1 ]; then say "$p/$rkey [$reason]: WOULD hand the data-lane park back to the ladder ($why) — observe mode"; return 0; fi
  [ "$(br_load "$p" "$ck" | jq -r '.outcome // ""' 2>/dev/null)" = DATA_LANE ] && br_set_outcome "$p" "$ck" ""
  br_set_field "$p" "$ck" data_lane_unbound "$BR_DL_FP $BR_DL_HEAD"
  br_record "$p" "$ck" data-lane-unbound "$reason" "$BR_DL_FILE fp=${BR_DL_FP:0:12}: $why — the ladder owns it"
  say "$p/$rkey [$reason]: data-lane park handed back to the ladder — $why"
}

# br_dl_rcr_bound <url> — for a review-changes-requested row: is the PR's
#   standing CHANGES_REQUESTED the record's own DATA_LANE BLOCK, on the record's
#   review-head? The row's reason comes from the PR's newest standing review,
#   and the record is only the ticket's newest local build: a lead review on an
#   unrelated bug is not the data lane's to park.
#   rc 0 bound. rc 1 not bound (the ladder's). rc 4 the head moved. rc 2 the
#   head or the reviews list could not be read: held, never "not bound".
br_dl_rcr_bound() {
  local url="${1:--}" slug num head rc=0 b64 body
  slug=$(br_slug_of_url "$url") || return 2
  num=$(mc_num_of_url "$url"); [ -n "$num" ] || return 2
  head=$(br_pr_field "$url" .head.sha 'head sha') || return 2
  [ -n "$head" ] || return 2
  dl_sha_is "$BR_DL_HEAD" "$head" || return 4
  b64=$(br_review_newest "$slug" "$num" "$head") || rc=$?
  case "$rc" in 0) ;; 1) return 1 ;; *) return 2 ;; esac
  body=$(printf '%s' "$b64" | base64 -d 2>/dev/null | tr -d '\r')
  case "$body" in "$BR_LEAD_HDR"*) return 1 ;; esac
  grep -qxF -- "DATA_LANE: $BR_DL_FILE" <<<"$body" || return 1
  return 0
}

# br_data_lane_route <project> <rkey> <reason> <url> <record> <ticket-key> <cap-key>
#   rc 0 not a data-lane park: today's path. rc 3 parked (or held): no rung, no
#   slot, like HELD. rc 5 the release is due: the ledger says applied at this fp,
#   the probe file names this fp, and this fp+head has not been released yet.
br_data_lane_route() {
  local p="$1" rkey="$2" reason="$3" url="${4:--}" rec="${5:--}" tkey="${6:--}" ck="$7"
  local st oc rc=0 key status lrc probe base
  st=$(br_load "$p" "$ck"); oc=$(printf '%s' "$st" | jq -r '.outcome // ""' 2>/dev/null)
  br_dl_eval "$p" "$rec" "$tkey" || rc=$?
  case "$rc" in
    2) # Held, but never silently forever (lead BLOCK on dbed6c45): after
       # BR_DL_UNREADABLE_MAX (3) held ticks in a row, one escalation, deduped
       # on the park's fp (or on the record, for a review never parked).
       local nu
       nu=$(( $(br_num "$st" data_lane_unreadable) + 1 ))
       br_set_field "$p" "$ck" data_lane_unreadable "$nu"
       say "$p/$rkey [$reason]: DATA_LANE review in ${BR_DL_REC:-its record} could not be read (reviewed sha, diff or file) — held ($nu in a row), nothing abandoned, asked again next tick"
       if [ "$nu" -ge "${BR_DL_UNREADABLE_MAX:-3}" ]; then
         BR_DL_FILE=$(printf '%s' "$st" | jq -r '.data_lane_file // "its migration"')
         BR_DL_FP=$(printf '%s' "$st" | jq -r --arg r "unreadable:${BR_DL_REC##*/}" '.data_lane_fp // $r')
         br_dl_escalate "$p" "$rkey" "$reason" "$url" "$ck" "$tkey" "its review could not be read for $nu ticks in a row (reviewed sha, diff or file), so the park can neither release nor hand back"
       fi
       return 3 ;;
    1) if [ "$oc" = DATA_LANE ]; then
         br_set_outcome "$p" "$ck" ""
         br_record "$p" "$ck" data-lane-cleared "$reason" "the review is no longer a data-lane candidate — the ladder resumes"
         say "$p/$rkey [$reason]: the review is no longer a data-lane candidate — DATA_LANE cleared, the ladder resumes"
       fi
       return 0 ;;
  esac
  [ "$(br_num "$st" data_lane_unreadable)" = 0 ] || br_set_field "$p" "$ck" data_lane_unreadable 0
  key="$BR_DL_FP $BR_DL_HEAD"
  # Handed back once (the head moved): the same fp+head never parks again.
  [ "$(printf '%s' "$st" | jq -r '.data_lane_unbound // ""' 2>/dev/null)" = "$key" ] && return 0
  if [ "$reason" = review-changes-requested ]; then
    rc=0; br_dl_rcr_bound "$url" || rc=$?
    case "$rc" in
      2) say "$p/$rkey [$reason]: DATA_LANE — the PR's head or reviews could not be read — held, nothing abandoned, asked again next tick"
         return 3 ;;
      4) br_dl_unbind "$p" "$rkey" "$reason" "$ck" "the PR head moved past the reviewed ${BR_DL_HEAD:0:12}"
         return 0 ;;
      1) if [ "$oc" = DATA_LANE ]; then
           br_set_outcome "$p" "$ck" ""
           br_record "$p" "$ck" data-lane-cleared "$reason" "the PR's standing CHANGES_REQUESTED is not the data-lane BLOCK — the ladder resumes"
         fi
         say "$p/$rkey [$reason]: the PR's standing CHANGES_REQUESTED is not the record's data-lane BLOCK — not parked, the ladder runs"
         return 0 ;;
    esac
  fi
  if [ "$oc" != DATA_LANE ]; then
    # The one release ran and its re-review did not approve: the ladder owns it,
    # and the same fp+head never parks again.
    [ "$(printf '%s' "$st" | jq -r '.data_lane_released // ""' 2>/dev/null)" = "$key" ] && return 0
    if [ "$OBSERVE" = 1 ]; then say "$p/$rkey [$reason]: WOULD park DATA_LANE ($BR_DL_FILE) — observe mode"; return 3; fi
    br_set_outcome "$p" "$ck" DATA_LANE
    br_set_field "$p" "$ck" data_lane_file "$BR_DL_FILE"
    br_set_field "$p" "$ck" data_lane_fp "$BR_DL_FP"
    br_record "$p" "$ck" data-lane-parked "$reason" "$BR_DL_FILE fp=${BR_DL_FP:0:12} head=${BR_DL_HEAD:0:12}: the review's only BLOCK is this migration, not applied yet"
    say "$p/$rkey [$reason]: parked DATA_LANE — the only BLOCK is $BR_DL_FILE, not applied yet (fp ${BR_DL_FP:0:12}); no rung, nothing abandoned"
    st=$(br_load "$p" "$ck")
  fi
  status=$(dl_ledger_status "$p" "$BR_DL_FILE"); lrc=$?
  case "$lrc" in
    0) case "$status" in
         "flagged "*" fp=$BR_DL_FP"|"failed "*" fp=$BR_DL_FP")
           br_dl_escalate "$p" "$rkey" "$reason" "$url" "$ck" "$tkey" "ledger: $status"
           return 3 ;;
         "applied "*" fp=$BR_DL_FP"|"already-applied "*" fp=$BR_DL_FP")
           probe=$(dl_probe_file "$BR_DL_REC")
           if [ -f "$probe" ] && grep -qF "fp=$BR_DL_FP" "$probe"; then
             if [ "$(printf '%s' "$st" | jq -r '.data_lane_released // ""' 2>/dev/null)" = "$key" ]; then
               say "$p/$rkey [$reason]: DATA_LANE — the release for ${BR_DL_HEAD:0:12} was already requested; the conductor merges on its APPROVE"
               return 3
             fi
             return 5
           fi
           say "$p/$rkey [$reason]: DATA_LANE — $BR_DL_FILE applied, no probe yet — release waits"
           return 3 ;;
       esac ;;
    1) ;;
    *) say "$p/$rkey [$reason]: DATA_LANE — the migration ledger is unknown this tick, held (no alert, no release)"
       return 3 ;;
  esac
  # Absent, or another fp: the apply lane owns it, unless it has nowhere to go.
  # Read for emptiness only and never logged: it is the host the token goes to.
  base=$(sed -n 's/^DATA_LANE_APP_BASE=//p' "$HENV/$p.env" 2>/dev/null | sed -n '$p' | tr -d "\"' ")
  if [ -z "$base" ]; then
    br_dl_escalate "$p" "$rkey" "$reason" "$url" "$ck" "$tkey" "no apply path: DATA_LANE_APP_BASE unset in env/$p.env"
  else
    say "$p/$rkey [$reason]: DATA_LANE — $BR_DL_FILE waits on the data lane's apply (fp ${BR_DL_FP:0:12})"
  fi
  return 3
}

# br_data_lane_release <project> <cap-key> <reason> <url> <record> <ticket-key>
#   The release rung: ONE re-review of the SAME head, with the probe file as
#   evidence that the BLOCK is answered. It never merges, enqueues or builds; the
#   conductor merges on the head-bound APPROVE as for any other review. Reads the
#   BR_DL_* globals br_data_lane_route set in this same br_one.
br_data_lane_release() {
  local p="$1" ck="$2" reason="$3" url="${4:--}" tkey="${6:--}"
  local key probe purl="" slug brn head rc n0 n1 last
  key="$BR_DL_FP $BR_DL_HEAD"; probe=$(dl_probe_file "$BR_DL_REC")
  case "$url" in https://github.com/*/pull/*) purl="$url" ;; esac
  if [ -z "$purl" ]; then
    slug=$("$H/bin/fleet-conf.sh" "$p" repo 2>/dev/null)
    brn=$(sed -n 1p "$BR_DL_REC/branch" 2>/dev/null | tr -d '[:space:]')
    [ -n "$slug" ] && [ -n "$brn" ] \
      && purl=$(br_open_prs "$slug" | jq -r --arg b "$brn" '[.[]? | select(.headRefName == $b) | .url] | first // empty' 2>/dev/null)
  fi
  if [ -z "$purl" ]; then
    say "$p/$ck [$reason]: DATA_LANE release due, but no open PR carries ${BR_DL_REC##*/}'s branch — asked again next tick"
    return 0
  fi
  head=$(br_pr_field "$purl" .head.sha 'head sha'); rc=$?
  if [ "$rc" != 0 ] || [ -z "$head" ]; then
    say "$p/$ck [$reason]: DATA_LANE release due, but the head of $purl could not be read — asked again next tick"
    return 0
  fi
  if ! dl_sha_is "$BR_DL_HEAD" "$head"; then
    br_dl_unbind "$p" "$ck" "$reason" "$ck" "release refused, the PR head moved (${head:0:12}, reviewed ${BR_DL_HEAD:0:12})"
    return 0
  fi
  if [ "$OBSERVE" = 1 ]; then say "$p/$ck [$reason]: WOULD request the data-lane re-review of ${head:0:12} — observe mode"; return 0; fi
  br_set_field "$p" "$ck" data_lane_released "$key" || return 0
  n0=$(br_num "$(br_load "$p" "$ck")" data_lane_rereviews)
  br_rereview "$p" "$ck" "$reason" "$purl" "$BR_DL_REC" "$tkey" data-lane "$probe" "dl-${BR_DL_FP:0:12}"
  n1=$(br_num "$(br_load "$p" "$ck")" data_lane_rereviews)
  last=$(br_load "$p" "$ck" | jq -r '[.attempts[]? | select(.action == "re-review")] | last | (.detail // "")' 2>/dev/null)
  if [ "${n1:-0}" -le "${n0:-0}" ]; then
    # Nothing read the code (the lane failed, the call-guard deferred, the head
    # was unreadable): the claim is given back and the next tick asks again.
    br_set_field "$p" "$ck" data_lane_released "-"
    return 0
  fi
  case "$last" in
    APPROVE*) br_record "$p" "$ck" data-lane-released "$reason" "re-review APPROVE on ${head:0:12}, the BLOCK answered by $probe" ;;
    BLOCK*)   br_set_outcome "$p" "$ck" ""
              br_record "$p" "$ck" data-lane-release-blocked "$reason" "re-review BLOCK on ${head:0:12} after the apply — the ladder owns it" ;;
    # A paid read with no verdict is asked again next tick, up to the lane's
    # no-verdict cap; past it the claim stays (nothing more is bought) and one
    # escalation says so. The row stays DATA_LANE either way.
    *) if [ "${n1:-0}" -lt "$BR_NOVERDICT_MAX" ]; then br_set_field "$p" "$ck" data_lane_released "-"
       else br_dl_escalate "$p" "$ck" "$reason" "$purl" "$ck" "$tkey" "$n1 data-lane re-reviews of ${head:0:12} returned no verdict (BR_NOVERDICT_MAX)"; fi ;;
  esac
}
# <<< data-lane park

# br_resolve_merged <project> <cap-key> <reason> <url> <record> — the park points
# at a PR that is ALREADY MERGED: the work landed and the row is just stale.
# br_close_pr returns silently on anything that is not OPEN, so a rebuild from
# here would sail past the close and enqueue a DUPLICATE build of merged work.
# This is the resolved path: record it, mark the record so no sweep re-handles
# it, move the conductor row to its MERGED terminal, and take no other rung.
br_resolve_merged() {
  local p="$1" ck="$2" reason="$3" url="$4" rec="$5" ckey
  if [ "$OBSERVE" = 1 ]; then say "$p/$ck [$reason]: WOULD resolve — $url is already MERGED — observe mode"; return 0; fi
  br_record "$p" "$ck" resolved-merged "$reason" "$url is already MERGED — stale park, no rebuild"
  br_set_outcome "$p" "$ck" RESOLVED_MERGED
  # WHICH PR THIS RESOLVED (BH-1457). The outcome alone is a TICKET-level fact
  # and a ticket can acquire a new PR (a rebuild's), so the pre-pass that
  # retires finished rows needs to know which url the resolve was about. A
  # record written before this shipped carries none, and br_prepass reads an
  # absent url as "not the same PR" rather than as a match (D11).
  br_set_field "$p" "$ck" resolved_url "$url"
  [ -n "$rec" ] && [ "$rec" != "-" ] && [ -d "$rec" ] && { : > "$rec/.blocked-resolver-superseded"; touch "$rec/COMMENTED" 2>/dev/null; }
  ckey=$(mc_slug_of_url "$url")
  [ -n "$ckey" ] && mc_transition "$ckey#$(mc_num_of_url "$url")" MERGED \
    "blocked-resolver: already merged, the $reason park is stale" "-" "-" "$url" "-" "-" "${rec:--}" >/dev/null
  say "$p/$ck [$reason]: RESOLVED — $url is already merged, nothing rebuilt"
}

# THE TICKET-MERGED CHECK. It runs FIRST, before any rung, for every park.
#
# 2026-09-14, 03:00-03:37Z: this lane rebuilt SEVEN tickets that had merged days
# earlier (project-3 TK-53/TK-131/TK-135, project-4 TK-1587/TK-791, project-1 TK-115/TK-202).
# Every one of them was a stale POOL record — a test-tamper block, a rescue that
# gave up — carrying NO PR url, and the only merged-guard there was sat at the
# REBUILD rung and asked about the url. So the guard never fired: three duplicate
# builds ran to PLAN_BLOCKED and the rest were quarantined by bin/fly-pool.sh.
#
# The lesson is that the park's url is the WRONG question. The question is
# whether the TICKET landed, and the repo answers that whether or not this park
# ever knew a PR number.

# br_park_time <project> <cap-key> <ticket-key> <record> — when this park was
# recorded, in epoch seconds. The record's own terminal first (it is the fact),
# then the queue row the pool left behind, then this lane's state file. NOTHING
# is guessed: with no dated evidence the caller keeps today's behaviour rather
# than resolving a park it cannot place in time.
#
# A LEDGER-ONLY park (BH-2349) has no RESULT, and a build that never touched
# this box has no queue row or state file either. Its date is the ledger row's
# updated_at, the newest for the ticket, asked before the state file (whose
# mtime is this lane's own write, not the park). A ledger that does not answer
# (rc 1) for a park with no record is rc 2: UNKNOWN, never "no merged PR" —
# the 2026-09-14 wave was exactly a park nothing could date, rebuilt anyway.
br_park_time() {
  local p="$1" ck="$2" tkey="$3" rec="$4" f rows brc bdir bupd bep newest=""
  for f in "$rec/RESULT" "$H/state/build-queue/$p/$tkey.failed.json" \
           "$H/state/build-queue/$p/$tkey.json"; do
    [ -e "$f" ] || continue
    date -u -r "$f" +%s 2>/dev/null && return 0
  done
  if [ "${rec:--}" = - ] && command -v bor_union >/dev/null 2>&1; then
    rows=$(bor_union "$p" 2>/dev/null); brc=$?
    [ "$brc" = 1 ] && return 2
    while IFS=$'\t' read -r _ bdir _ bupd _ _ _; do
      # The trailing dash keeps BH-23 from answering for BH-234.
      case "$bdir" in "$p-$tkey-"*) ;; *) continue ;; esac
      [ -n "$bupd" ] || continue
      bep=$(date -u -d "$bupd" +%s 2>/dev/null) || continue
      [ -z "$newest" ] || [ "$bep" -gt "$newest" ] && newest="$bep"
    done <<<"$rows"
    [ -n "$newest" ] && { printf '%s\n' "$newest"; return 0; }
  fi
  f=$(br_file "$p" "$ck")
  [ -e "$f" ] && date -u -r "$f" +%s 2>/dev/null && return 0
  return 1
}

# br_merged_prs_for <owner/repo> <ticket-key> — TSV of the repo's MERGED PRs for
# this ticket: url, mergedAt, branch. Two searches, because a PR names its ticket
# in one of two places and neither is reliable alone: the TITLE and the BRANCH
# this pipeline always builds on (`ticket/<key>`, lowercased, sometimes with an
# -rN rebuild suffix). Each arm is capped at 20 hits.
# GitHub's search tokenises on the hyphen, so TK-53 can come back with TK-531's
# PR — every row is re-checked HERE against the whole key before it counts.
#
#   rc 0   the searches answered; the TSV (possibly empty) is the answer.
#   rc 75  a search or a per-hit read did not answer. THERE IS NO PARTIAL
#          ANSWER: an incomplete list read as "this ticket never merged" is how
#          seven already-merged tickets were rebuilt on 2026-09-14, and how #768
#          rebuilt PRs it could not read. The caller takes its unknown path.
#
# Search items carry no head branch, so each unique hit costs one REST read of
# the PR itself (<= 40 worst case, typically 0-3) to keep the whole-key filter
# exactly as strict as it was.
br_merged_prs_for() {
  local slug="$1" tkey="$2" lk q hits f u n at brn ti rc
  lk=$(printf '%s' "$tkey" | tr '[:upper:]' '[:lower:]')
  hits=$(mktemp) || return 75
  f=$(mktemp) || { rm -f "$hits"; return 75; }
  for q in "repo:$slug is:pr is:merged \"$tkey\" in:title" \
           "repo:$slug is:pr is:merged head:ticket/$lk"; do
    gh_rest GET search/issues -f "q=$q" -F per_page=20 > "$f" 2>/dev/null || {
      say "$slug: the merged-PR search for $tkey is UNVERIFIABLE (HTTP $GH_REST_STATUS${GH_REST_REASON:+ $GH_REST_REASON}) — nothing decided from it this tick"
      rm -f "$hits" "$f"; return 75
    }
    jq -r '.items[]?.html_url // empty' "$f" 2>/dev/null >> "$hits"
  done
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    n=$(mc_num_of_url "$u"); [ -n "$n" ] || continue
    gh_rest GET "repos/$slug/pulls/$n" > "$f" 2>/dev/null; rc=$?
    case "$rc" in
      0)  ;;
      44) continue ;;
      *)  say "$slug#$n: a merged-search hit for $tkey could not be read (HTTP $GH_REST_STATUS${GH_REST_REASON:+ $GH_REST_REASON}) — nothing decided from the search this tick"
          rm -f "$hits" "$f"; return 75 ;;
    esac
    at=$(jq -r '.merged_at // "-"' "$f" 2>/dev/null)
    [ "$at" = "-" ] && continue
    brn=$(jq -r '.head.ref // "-"' "$f" 2>/dev/null)
    ti=$(jq -r '.title // "-"' "$f" 2>/dev/null)
    case "$brn" in
      "ticket/$lk"|"ticket/$lk-"*) ;;
      *) printf '%s' "$ti" | tr '[:lower:]' '[:upper:]' \
           | grep -qE "(^|[^A-Z0-9])$tkey([^0-9]|\$)" || continue ;;
    esac
    printf '%s\t%s\t%s\n' "$u" "$at" "$brn"
  done < <(sort -u "$hits")
  rm -f "$hits" "$f"
  return 0
}

# br_resolve_ticket_merged <project> <cap-key> <reason> <ticket-key> <merged-url>
#                          <record> — the TICKET landed; this park is scenery.
br_resolve_ticket_merged() {
  local p="$1" ck="$2" reason="$3" tkey="$4" murl="$5" rec="$6" msg d dres dname
  msg="ticket $tkey already merged via $murl, park is stale, nothing rebuilt"
  if [ "$OBSERVE" = 1 ]; then say "$p/$ck [$reason]: WOULD resolve — $msg — observe mode"; return 0; fi
  br_record "$p" "$ck" resolved-merged "$reason" "$msg"
  br_set_outcome "$p" "$ck" RESOLVED_MERGED
  [ -n "$rec" ] && [ "$rec" != "-" ] && [ -d "$rec" ] && touch "$rec/COMMENTED" 2>/dev/null
  # EVERY record of this ticket is stale now, not just the one that was parked:
  # the duplicate builds the 2026-09-14 wave produced left their own PLAN_BLOCKED
  # records behind, and an unmarked one is a candidate again on the next tick.
  for d in "$H"/builds/"$p"-"$tkey"-*/ "$H"/builds/pool-"$p"-"$tkey"-*/; do
    [ -d "$d" ] || continue
    : > "${d%/}/.blocked-resolver-superseded"
    # Its ledger row ends at `superseded` too (BH-3481.1), except the dir that
    # merged, and a hub mirror of a pool build: its basename is no row's bkey
    # (the real row is under the BUILD_DIR:/BUILT_AS: name), so a beat there
    # would invent a phantom row.
    dres="${d%/}/RESULT"; dname=$(basename "${d%/}")
    head -1 "$dres" 2>/dev/null | grep -q '^PR_MERGED' && continue
    [ -n "$murl" ] && grep -qF -- "$murl" "$dres" 2>/dev/null && continue
    sed -n 's/^\(BUILT_AS\|BUILD_DIR\): *//p' "$dres" 2>/dev/null | sed 's#/*[[:space:]]*$##; s#.*/##; /^$/d' \
      | grep -qvxF -- "$dname" && continue
    br_row_closed "$p" "$tkey" "${d%/}" - superseded "superseded: $tkey already merged via $murl" resolved-merged
  done
  # The queue row too, so the pool never re-offers a ticket that has landed.
  command -v queue_done >/dev/null 2>&1 \
    && queue_done "$p" "$tkey" done "$msg" >/dev/null 2>&1
  say "$p/$ck [$reason]: RESOLVED — $msg"
}

# br_already_merged <project> <rkey> <reason> <pr-url> <record> <ticket-key> <slug>
#   rc 0 = this park is stale because the work is already merged; the caller
#   takes NO rung at all (no adjudication, no fix round, no rebuild).
#   rc 2 = GitHub did not answer, so whether the work merged is UNKNOWN. The
#   caller takes no rung either — "we could not read it" must never be walked
#   down the ladder as "it did not merge, rebuild it" (#783).
br_already_merged() {
  local p="$1" rkey="$2" reason="$3" url="$4" rec="$5" tkey="$6" slug="$7"
  local ck park u at brn ep newest newest_at older mst mrc rows
  ck=$(br_cap_key "$p" "$rkey" "$tkey")
  # Already answered on an earlier tick. Terminal, and costs nothing to re-read.
  [ "$(br_load "$p" "$ck" | jq -r '.outcome // ""' 2>/dev/null)" = RESOLVED_MERGED ] && return 0
  # (a) the park carries a PR and that PR is MERGED. This is the guard that
  #     already existed, hoisted out of the rebuild rung so that an adjudication
  #     of merged code is never bought either.
  #     AND A STATE WE COULD NOT READ IS NOT "not merged" (BH-642, shipped as
  #     #783). The old read was `gh pr view … -q .state`, which prints nothing
  #     and exits non-zero when GitHub rate-limits us — an empty string matched
  #     no arm here, this function answered 1, and the ladder walked on to close
  #     and rebuild a PR whose real state nobody had read. br_pr_state answers
  #     rc 75 instead: this returns 2, spends nothing, and the next tick asks.
  if [ -n "$url" ] && [ "$url" != "-" ]; then
    mst=$(br_pr_state "$url"); mrc=$?
    [ "$mrc" = 75 ] && return 2
    [ "$mst" = merged ] && { br_resolve_merged "$p" "$ck" "$reason" "$url" "$rec"; return 0; }
  fi
  # (b) and, url or no url, whether the TICKET itself has a merged PR.
  [ -n "$tkey" ] && [ "$tkey" != "-" ] && [ -n "$slug" ] || return 1
  case "$tkey" in [A-Za-z]*-[0-9]*) ;; *) return 1 ;; esac
  # rc 2 from the dating is UNKNOWN too: a ledger-only park the ledger could not
  # date is never read as "nothing merged after it" (BH-2349).
  park=$(br_park_time "$p" "$ck" "$tkey" "$rec"); mrc=$?
  [ "$mrc" = 2 ] && return 2
  [ "$mrc" = 0 ] || return 1
  newest=""; newest_at=""; older=""
  # A TEMP FILE, NOT `< <( )`: the search's rc has to be readable, and a process
  # substitution hides it. An unreadable search is rc 2 — unknown, not "this
  # ticket has no merged PR".
  rows=$(mktemp) || return 2
  br_merged_prs_for "$slug" "$tkey" > "$rows"; mrc=$?
  [ "$mrc" = 75 ] && { rm -f "$rows"; return 2; }
  while IFS=$'\t' read -r u at brn; do
    [ -n "$u" ] || continue
    [ -n "$at" ] || continue
    ep=$(date -u -d "$at" +%s 2>/dev/null) || continue
    if [ "$ep" -gt "$park" ]; then
      [ -z "$newest_at" ] || [ "$ep" -gt "$newest_at" ] || continue
      newest="$u"; newest_at="$ep"
    else
      older="$u"
    fi
  done < "$rows"
  rm -f "$rows"
  if [ -n "$newest" ]; then
    br_resolve_ticket_merged "$p" "$ck" "$reason" "$tkey" "$newest" "$rec"
    return 0
  fi
  # A merge OLDER than the park is not this park's answer — the ticket can
  # legitimately have a follow-up. One line so the decision is readable later.
  [ -n "$older" ] && say "$p/$rkey [$reason]: $tkey has a merged PR ($older) but it predates this park — continuing the ladder"
  return 1
}

# br_ticket_id <project> <ticket-key> <record> — the TICKET ID a queue row needs,
# resolved the way the producers that own the row resolve it.
#
# A ROW WITHOUT ONE IS NOT A BUILD. bin/fly-pool.sh quarantines it ("malformed
# queue entry (ticket='')") and bin/run-build.sh refuses it, so the enqueue this
# lane thought it had made was a loud nothing — four of the seven rebuilds in the
# 2026-09-14 wave died exactly there, having already closed their PR and spent a
# rebuild counter. Sources in order of authority: the build record the pipeline
# itself wrote, the queue row still on disk, the key's own number on a
# GitHub-Issues lane, and the product board as the last word.
br_ticket_id() {
  local p="$1" tkey="$2" rec="${3:--}" tid="" f prefix base token bid tickets_json bodyf code
  [ -n "$tkey" ] && [ "$tkey" != "-" ] || return 1
  if [ -n "$rec" ] && [ "$rec" != "-" ] && [ -d "$rec" ]; then
    tid=$(jq -r '.ticket_id // ""' "$rec/job.json" 2>/dev/null)
    case "$tid" in ''|null) tid=$(sed -n 's/^TICKET_ID: //p' "$rec/RESULT" 2>/dev/null | head -1) ;; esac
  fi
  if [ -z "$tid" ] && command -v queue_list >/dev/null 2>&1; then
    tid=$(queue_list "$p" 2>/dev/null | awk -F'\t' -v k="$tkey" '$2==k && $3!="-" && $3!="" {print $3; exit}')
  fi
  if [ -z "$tid" ]; then
    for f in "$H/state/build-queue/$p/$tkey.json" "$H/state/build-queue/$p/$tkey.failed.json"; do
      [ -s "$f" ] || continue
      tid=$(jq -r '.ticket_id // ""' "$f" 2>/dev/null)
      case "$tid" in ''|null) tid="" ;; *) break ;; esac
    done
  fi
  prefix=$("$H/bin/fleet-conf.sh" "$p" board_prefix 2>/dev/null)
  # A GitHub-Issues lane has no id of its own: the issue number IS the key's tail
  # (the same reading bin/run-build.sh's resume path makes).
  if [ -z "$tid" ] && [ "$prefix" = "-" ]; then
    case "${tkey##*-}" in ''|*[!0-9]*) ;; *) tid="${tkey##*-}" ;; esac
  fi
  # The product board itself, read exactly as bin/stale-owed-tickets.sh reads it.
  if [ -z "$tid" ] && [ -n "$prefix" ] && [ "$prefix" != "-" ]; then
    base=$("$H/bin/fleet-conf.sh" "$p" prod 2>/dev/null); [ "$base" = "-" ] && base=""
    token=$("$H/bin/internal-token-for.sh" "$p" 2>/dev/null) || token=""
    if [ -n "$base" ] && [ -n "$token" ]; then
      bid=$(curl -s -m 20 -H "Authorization: Bearer $token" -H "User-Agent: curl/8" "$base$prefix/boards" 2>/dev/null \
            | jq -r 'if type=="array" then (.[0].id // empty) else (.boards[0].id // empty) end' 2>/dev/null)
      if [ -n "$bid" ]; then
        # The STATUS is part of the answer (bin/board-fetch.sh:61 makes the same
        # read). `{"error":"Unauthorized"}` is valid JSON and parses, so a gate
        # of "the body is JSON" alone turns a rotated PROJECT_4_INTERNAL_API_TOKEN —
        # or any 5xx that renders JSON — into a terminal ABANDONED + page for
        # EVERY parked PR on the project inside three ticks. A credential is a
        # fact about the machine, not an event about the PR (br_setup_blocked),
        # so only 2xx WITH a ticket-list shape counts as the board answering.
        bodyf=$(mktemp) || return 1
        code=$(curl -s -m 30 -o "$bodyf" -w '%{http_code}' \
              -H "Authorization: Bearer $token" -H "User-Agent: curl/8" \
              "$base$prefix/boards/$bid/tickets" 2>/dev/null) || code=000
        tickets_json=$(cat "$bodyf" 2>/dev/null); rm -f "$bodyf"
        # A board that answered WITH A TICKET LIST but does not list this ticket
        # is a DETERMINISTIC miss (rc 2). Everything else — a non-2xx, an error
        # object, an empty body, unparseable JSON, no board id — stays rc 1 and
        # is retried for free.
        case "$code" in
          2*)
            if printf '%s' "$tickets_json" | jq -e 'type=="array" or (type=="object" and has("tickets"))' >/dev/null 2>&1; then
              tid=$(printf '%s' "$tickets_json" | jq -r --arg k "$tkey" 'first((if type=="array" then . else (.tickets // []) end)[] | select((.key // "") == $k or ((.number // -1) == ($k | split("-") | last | try tonumber catch -1))) | (.id // empty)) // empty' 2>/dev/null)
              [ -n "$tid" ] || return 2
            fi ;;
        esac
      fi
    fi
  fi

  case "$tid" in ''|null) return 1 ;; esac
  printf '%s' "$tid"
}

# br_enqueue_fresh <project> <ticket-key> <attempt-label> <note> [record] [rkey] [pr-url]
#   Pool project: the queue ROW is the enqueue (bin/fly-dispatch.sh materialises
#   the directory from rows and claims as it goes), at attempt 0 — a fresh build
#   has no deaths and no deferrals behind it, and lying about that is precisely
#   the bug this change also fixes in bin/fly-pool.sh.
#   Box project: the box's own triage tick re-claims the ticket once the marker
#   that says "this one is finished" is gone. That marker is the blocked stamp
#   bin/run-build.sh writes plus the build dir's RESULT, both of which live on
#   the BOX, so the hub reaches it through the stamp's D1 `commented` row.
#
#   BR_ENQUEUE_WHY carries the rc-1 reason out to the caller, so the STALLED
#   alert at BR_ENQUEUE_FAIL_MAX failures can name what is actually broken rather
#   than "the enqueue failed" — and so the streak can tell IDENTICAL failures
#   apart from a new one (br_rebuild_settle compares it against the stored
#   enqueue_why). A plain global, read by a caller that does NOT use `$( )`
#   (br_rebuild_fresh and br_rebuild_retry both call this directly), for the
#   reason br_pr_ref documents.
BR_ENQUEUE_WHY=""
br_enqueue_fresh() {
  local p="$1" tkey="$2" n="$3" note="$4" rec="${5:--}" rkey="${6:--}" url="${7:--}" meta box rc tid trc
  BR_ENQUEUE_WHY=""
  # CLEARED ON ENTRY, not inside the pool branch (BH-947 review N2). Both are
  # plain globals a caller reads after this returns, so a rung that refuses
  # before either branch is reached (no ticket key) must not leave the PREVIOUS
  # park's job id standing for br_rebuild_settle to record.
  BR_JOB_ID=""; BR_JOB_ENQ=""
  if [ -z "$tkey" ] || [ "$tkey" = "-" ]; then
    # NEVER SILENT. The PR is closed by the time this runs, so a ticket with no
    # derivable key has no owner at all — that is an alert, not a log line.
    #
    # AND NEVER FREE (2026-09-16, project-5 #1634). rc 2, not 1: this refusal is
    # DETERMINISTIC — the branch, the title and the record will read the same on
    # the next tick and on every tick after it — so the caller counts it as a
    # spent rung attempt and caps it. rc 1 stays what it has always been: an
    # enqueue that could not be made THIS time (no ticket id, a box that would
    # not answer), which is worth retrying for free.
    say "$p/$rkey: no ticket key — cannot enqueue a fresh build (${url:--no url}, record ${rec:--none})"
    br_nokey_alert "$p" "$rkey" "$url" "$rec"
    return 2
  fi
  meta=$(jq -nc --argjson d 0 --argjson x 0 --arg s "-r$((n+1))" --arg w "$note" \
    '{deferrals:$d,deaths:$x,branch_suffix:$s,blocked_resolver:$w}' 2>/dev/null)
  if br_pool_routed "$p"; then
    if ! command -v queue_put >/dev/null 2>&1; then
      BR_ENQUEUE_WHY="no jobs client on this box"
      say "$p/$tkey: no jobs client — cannot enqueue"; return 1
    fi
    # NEVER a blank ticket id. An enqueue that cannot name the ticket is refused
    # here, so the caller records rebuild-fresh-failed and spends no counter,
    # instead of buying a quarantine.
    tid=$(br_ticket_id "$p" "$tkey" "$rec"); trc=$?
    case "$trc" in
      # BOARD ANSWERED BUT THE TICKET IS NOT ON IT (BH-1007). Deterministic, so
      # it is not the free rc-1 retry: rc 4 carries it to br_rebuild_settle,
      # which counts it as a miss and caps the ladder. BR_ENQUEUE_WHY is still
      # set so a STALLED page can name it if this ever reaches that arm.
      #
      # 4, NOT 3: rc 3 out of this function is BH-947's `duplicate` answer, and
      # both rungs route that to br_enqueue_dup_race and hold. A board miss
      # sharing the code would be parked as REBUILD_WAIT on a job that was never
      # enqueued, and the miss would never be counted or capped.
      2) BR_ENQUEUE_WHY="the board answered but no ticket id matched $tkey"
         say "$p/$tkey: board answered but ticket id unresolved — cannot enqueue"; return 4 ;;
      0) ;;
      *) tid="" ;;
    esac
    [ -n "$tid" ] || { BR_ENQUEUE_WHY="no ticket id could be resolved for $tkey"
                       say "$p/$tkey: no ticket id — cannot enqueue"; return 1; }
    rc=$(queue_put "$p" "$tkey" "$tid" fly 0 "$meta" 2>/dev/null)
    if [ "$rc" = "queued" ]; then
      local enq
      # THE STAMP IS READ BACK FROM THE WORKER whenever it can be (D26): that is
      # the only value a later queue_row will agree with. A local clock is the
      # fallback and says so, so a ledger entry that can never match a live row
      # is readable as such instead of looking like a stamp the worker gave us.
      local lmark=""
      enq=$(br_queue_enq "$p" "$tkey" 2>/dev/null) || enq=""
      [ -n "$enq" ] || { enq=$(date -u '+%Y-%m-%dT%H:%M:%SZ'); lmark="~local"; }
      BR_JOB_ID="$tkey@${enq}~r$((n+1))$lmark"
      BR_JOB_ENQ="$enq"
      say "$p/$tkey: fresh pool build enqueued (attempt 0, $note) -> queued (job $BR_JOB_ID)"
      return 0
    fi
    if [ "$rc" = "duplicate" ]; then
      say "$p/$tkey: fresh pool build REFUSED as duplicate — a live build already covers this key (no rung spent, $note)"
      return 3
    fi
    if [ -z "$rc" ]; then
      BR_ENQUEUE_WHY="the jobs queue took no row for $tkey"
      say "$p/$tkey: fresh pool build NOT enqueued — the jobs queue took no row ($note)"
    else
      BR_ENQUEUE_WHY="the jobs queue answered '$rc' for $tkey"
      say "$p/$tkey: fresh pool build NOT enqueued — unexpected answer '$rc' ($note)"
    fi
    return 1
  fi
  box=$("$H/bin/box-for.sh" "$p" 2>/dev/null)
  # THE ROW IS THE RE-OFFER (BH-2317, BH-2674). The blocked stamp is a D1
  # `commented` row as well as a file on the owning box, and a `cleared` row
  # outvotes any file left there (bin/lib/comment-mark.sh), so clearing the row
  # IS the re-offer, wherever the box is. cm_clear also removes this box's own
  # files through the glob, DB or no DB. A row the DB did not take is a failed
  # re-offer (rc 1, the caller's re-offer/alert path): there is no other box
  # this lane reaches into any more.
  local crc=1
  cm_clear "blocked $p $tkey" "$H/state/blocked-commented-$p-$tkey-*" 2>/dev/null && crc=0
  if [ "$box" = local ] || [ "$(hostname)" = "$box" ]; then
    BR_JOB_ID="$tkey@reoffer-$(date -u +%s)~r$((n+1))"
    say "$p/$tkey: cleared the local blocked stamps — the next triage tick re-claims it ($note)"
    return 0
  fi
  if [ "$crc" = 0 ]; then
    BR_JOB_ID="$tkey@reoffer-$(date -u +%s)~r$((n+1))"
    say "$p/$tkey: cleared row commented 'blocked $p $tkey' — $box's stamps no longer count, its next triage tick re-claims it ($note)"
    return 0
  fi
  BR_ENQUEUE_WHY="the jobs DB did not take the cleared row for $tkey"
  say "$p/$tkey: the jobs DB did not take the cleared row for $tkey — $box's blocked stamp still stands, re-offered next tick ($note)"
  return 1
}

# br_failed_runs <owner/repo> <head> — the ids of the FAILING workflow runs on
# this head, bounded by BR_CI_LOG_RUNS. Same endpoint mc_ci_state reads, so the
# two can never disagree about which runs are red.
br_failed_runs() {
  gh api "repos/$1/actions/runs?head_sha=$2&per_page=50" \
    -q '.workflow_runs[]? | select(.conclusion=="failure" or .conclusion=="timed_out" or .conclusion=="startup_failure") | .id' \
    2>/dev/null | head -"${CI_LOG_RUNS:-3}"
}

# br_rerun_ci <owner/repo> <head> — re-run the failed jobs of every failing run
# on this head, over REST. The failed jobs re-run INSIDE the same run, so the
# run's own conclusion flips and the conductor's next mc_ci_state read sees the
# answer with no special case.
#
#   rc 0  at least one re-run was DISPATCHED (the API answered 2xx).
#   rc 1  there was nothing to re-run: no failing run on this head.
#   rc 2  there were runs to re-run and GitHub refused every dispatch. That is
#         not "the mechanical rung had nothing to do" — nothing was spent and the
#         same rung is tried again next tick.
br_rerun_ci() {
  local slug="$1" head="$2" id n=0 u=0
  for id in $(br_failed_runs "$slug" "$head"); do
    if gh_rest POST "repos/$slug/actions/runs/$id/rerun-failed-jobs" >/dev/null 2>&1; then
      n=$((n+1))
    else
      u=1
      say "$slug: could not re-run the failed jobs of run $id (HTTP $GH_REST_STATUS${GH_REST_REASON:+ $GH_REST_REASON})"
    fi
  done
  [ "$n" -gt 0 ] && return 0
  [ "$u" = 1 ] && return 2
  return 1
}

# br_queue_batch <owner/repo> <pr#> — "<conclusion> <run-id>" of the NEWEST
# completed merge-queue batch run (head mergify/merge-queue/*) whose title names
# #<pr#>; nothing when there is none or the read failed (2026-09-24). On a repo
# that tests only in its queue that batch is the ONLY place the PR's corpus ran:
# its head runs the fast checks and reads green through any test failure.
br_queue_batch() {
  local raw
  raw=$(gh api "repos/$1/actions/runs?event=pull_request&per_page=100" 2>/dev/null) || return 0
  jq -r --arg n "$2" '[.workflow_runs[]? | select((.head_branch // "") | startswith("mergify/merge-queue/"))
      | select(.status == "completed") | select((.display_title // "") | test("#" + $n + "([^0-9]|$)"))]
      | sort_by(.created_at) | last // empty | "\(.conclusion) \(.id)"' <<<"$raw" 2>/dev/null
}

# br_queue_red_batch <owner/repo> <pr#> — "<conclusion> <run-id>" of the RED
# merge-queue batch that is this PR's own log: failure or timed_out only (a newer
# cancelled draft is Mergify re-embarking, not a verdict, and must not hide the
# red one), newer than the newest green batch naming the PR (a later green
# answers it), and a batch whose title has no "stacked on" first — a batch
# stacked on someone else's can fail on what it stood on. Only stacked reds:
# the newest of those. Nothing on no match or a failed read (review round 3).
br_queue_red_batch() {
  local raw
  raw=$(gh api "repos/$1/actions/runs?event=pull_request&per_page=100" 2>/dev/null) || return 0
  jq -r --arg n "$2" '[.workflow_runs[]? | select((.head_branch // "") | startswith("mergify/merge-queue/"))
      | select(.status == "completed") | select((.display_title // "") | test("#" + $n + "([^0-9]|$)"))] as $b
      | ([$b[] | select(.conclusion == "success") | .created_at] | max // "") as $g
      | [$b[] | select(.conclusion == "failure" or .conclusion == "timed_out") | select(.created_at > $g)]
      | sort_by([((.display_title // "") | test("stacked on") | not), .created_at]) | last // empty
      | "\(.conclusion) \(.id)"' <<<"$raw" 2>/dev/null
}

# br_ci_log <owner/repo> <head> [pr#] — the tail of each failing job's log. This
# is what makes a fix round possible on a red CI at all: without it the agent is
# told "CI is red" and has to go and find out what failed, which is a build's
# worth of turns spent re-discovering a fact the API hands over in one call.
# With no failing run on the head and a PR number, the newest RED merge-queue
# batch carrying that PR is the log (a queue-only repo's corpus runs there).
br_ci_log() {
  local slug="$1" head="$2" num="${3:-}" id out="" qb
  for id in $(br_failed_runs "$slug" "$head"); do
    out="$out"$'\n'"--- failing run $id of $slug @ ${head:0:8} ---"$'\n'"$(gh run view "$id" -R "$slug" --log-failed 2>/dev/null | tail -c "${CI_LOG_BYTES:-6000}")"  # gh-guard-allow: non-decision read, feeds the agent brief only — the REST equivalent is a zip download
  done
  if [ -z "$out" ] && [ -n "$num" ]; then
    qb=$(br_queue_red_batch "$slug" "$num")
    case "$qb" in failure\ *|timed_out\ *)
      id=${qb#* }
      out=$'\n'"--- failing MERGE-QUEUE batch run $id of $slug carrying #$num (the PR's own head runs only the fast checks; its tests ran here) ---"$'\n'"$(gh run view "$id" -R "$slug" --log-failed 2>/dev/null | tail -c "${CI_LOG_BYTES:-6000}")"  # gh-guard-allow: non-decision read, feeds the agent brief only
    esac
  fi
  printf '%s' "$out"
}

# RUNG 1: MECHANICAL. No model, no tokens, seconds of wall clock — merge current
# main into the branch in the authed clone (mc_rebase: deterministic conflict
# resolution, the hub's typecheck/unit gate, an explicit lease, the approval
# rebind) and, when there is nothing to merge, re-run the failed CI runs once.
#
# IT IS RUNG 1 BECAUSE MAIN MOVES. A conflict the conductor could not resolve an
# hour ago is often a conflict against a main that has since taken the very
# commit the branch was fighting, and a red CI on a branch that is 40 commits
# behind is frequently main's fix missing rather than the branch's bug. Both
# cost nothing to ask again.
br_mechanical() {
  local p="$1" rkey="$2" reason="$3" url="$4" rec="$5" tkey="$6"
  local ck st n slug br head out rc ref ckey rvw rrc=0 mbase=""
  ck=$(br_cap_key "$p" "$rkey" "$tkey")
  st=$(br_load "$p" "$ck"); n=$(br_num "$st" mechanicals)
  if [ "$n" -ge "$MAX_MECHANICAL" ]; then
    say "$p/$rkey [$reason]: the mechanical rung has already run $n time(s) — FIX ROUND"
    br_fix_round "$p" "$rkey" "$reason" "$url" "$rec" "$tkey"; return 0
  fi
  if [ "$OBSERVE" = 1 ]; then say "$p/$rkey [$reason]: WOULD take the mechanical rung (merge origin/main, else re-run CI) — observe mode"; return 0; fi
  slug=$("$H/bin/fleet-conf.sh" "$p" repo 2>/dev/null)
  [ -n "$slug" ] || slug=$(br_slug_of_url "$url") || slug=""
  # THE PR URL IS THE SLUG. fleet-conf is asked first (it is the project's own
  # answer) but it is no longer the only one: br_pr_ref falls back to the owner/
  # repo in the URL and re-reads under the repo's token. See br_slug_of_url for
  # what this cost before.
  br=""; head=""
  if [ -n "$url" ] && [ "$url" != "-" ]; then
    # Assigned only on success: a failed read must not clobber fleet-conf's slug.
    ref=$(br_pr_ref "$url" "$slug"); rc=$?
    # rc 2 IS "GITHUB DID NOT ANSWER", NOT "THIS PR HAS NO BRANCH". It costs no
    # rung, writes no state and takes no cascade — the park is simply re-offered
    # on the next tick. See br_pr_ref for the 2026-09-16 rate-limit incident.
    if [ "$rc" = 2 ]; then
      say "$p/$rkey [$reason]: PR read FAILED (${ref:-no detail}) — retrying next tick, no rung spent"
      return 0
    fi
    [ "$rc" = 0 ] && read -r slug br head <<<"$ref"
    # The head this rung read is the head this lane now knows the PR on (BH-1642).
    [ "$rc" = 0 ] && br_sup_seen "$p" "$ck" "$url" "$head"
    # The derived slug's token is installed for THIS shell too: br_pr_ref's own
    # retry happened inside a command substitution, and mc_rebase's clone and
    # every gh read after it want the same credential.
    [ -n "${slug:-}" ] && br_use_token "$slug"
  fi
  if [ -z "$slug" ] || [ -z "${br:-}" ] || [ -z "${head:-}" ]; then
    # Down here the slug came from the URL as well as from fleet-conf and the
    # read was re-tried under the repo's own token, so this really is a park
    # with no branch to merge into — a dead pool machine, a BUILD_DEAD record.
    say "$p/$rkey [$reason]: no branch/head for ${url:--} even after re-reading it under ${slug:-no repo}'s own token — nothing mechanical to try, FIX ROUND"
    br_fix_round "$p" "$rkey" "$reason" "$url" "$rec" "$tkey"; return 0
  fi
  # A STACKED CHILD'S RUNG 1 MERGES ITS OWN BASE (BH-5796), as its fix round
  # does: main's diff must not ride into a PR read against the parent branch.
  # mc_rebase answers rc 5 for a pushed parent merge (no approval rebind).
  mbase=$(br_pr_field "$url" .base.ref 'base branch' 2>/dev/null) || mbase=""
  case "$mbase" in ''|main) mbase=main ;; esac
  br_event resolver_rung "$p" "$ck" "$reason" "rung 1 mechanical: merging origin/$mbase into $br at ${head:0:8}"
  if [ "$mbase" = main ]; then out=$(mc_rebase "$slug" "$p" "$br" "$head" "$url"); rc=$?
  else out=$(mc_rebase "$slug" "$p" "$br" "$head" "$url" "$mbase"); rc=$?; fi
  # The setup alert is cleared the moment the rung actually RAN, exactly as the
  # fix round clears it: a LATER box problem on this park is a new fact and pages
  # again. rc 4 is the setup arm below and must NOT clear it, or a permanently
  # broken credential pages every ten minutes for ever.
  case "$rc" in 0|1|2|3|5|6) rm -f "$ST/$p/$ck.setup-alerted" 2>/dev/null ;; esac
  case "$rc" in
    0|5)
      if [ -n "$out" ] && [ "$out" != "$head" ]; then
        br_record "$p" "$ck" mechanical "$reason" "merged origin/$mbase into $br and pushed ${out:0:8} (mc_rebase rc=$rc)" mechanicals
        say "$p/$rkey [$reason]: MECHANICAL — pushed ${out:0:8} over ${head:0:8}; CI runs on the new head and the conductor judges it"
        return 0
      fi
      # Nothing to merge: the branch already carries main, so the only mechanical
      # move left is to re-run the CI that failed on this exact tree.
      br_rerun_ci "$slug" "$head"; rrc=$?
      if [ "$rrc" = 0 ]; then
        br_record "$p" "$ck" mechanical "$reason" "nothing to merge from main; re-ran the failed CI runs on ${head:0:8}" mechanicals
        say "$p/$rkey [$reason]: MECHANICAL — $br already carries main, so the failed runs on ${head:0:8} were re-run once"
        return 0
      fi
      if [ "$rrc" = 2 ]; then
        # There WERE failing runs and GitHub refused every dispatch. A rung that
        # never ran is not a rung that failed: nothing is recorded, nothing is
        # spent and the ladder does not walk toward the rebuild on it.
        say "$p/$rkey [$reason]: the CI re-run is UNVERIFIABLE (GitHub refused the dispatch) — nothing spent, retried next tick"
        return 0
      fi
      br_record "$p" "$ck" mechanical-failed "$reason" "nothing to merge from main and no failing run could be re-run" mechanicals
      say "$p/$rkey [$reason]: mechanical rung had nothing to do (branch carries main, no failing run to re-run) — FIX ROUND"
      br_fix_round "$p" "$rkey" "$reason" "$url" "$rec" "$tkey"; return 0 ;;
    1)
      # The conflicting paths are on stdout. They are kept for rung 2's prompt:
      # the fix round re-does the merge and leaves the markers IN the tree, and
      # the agent is told which files the machine could not resolve.
      mkdir -p "$ST/$p" 2>/dev/null
      printf '%s\n' "$out" > "$ST/$p/$ck.conflict.txt"
      # And they are remembered on the TICKET, per (pr, head): a path that
      # conflicts again on a later head is the recurrence br_one acts on.
      br_conflict_note "$p" "$ck" "$(mc_num_of_url "$url")" "$head" "$out"
      br_record "$p" "$ck" mechanical-failed "$reason" "origin/main still conflicts with $br in: $(tr '\n' ' ' <<<"$out")" mechanicals
      say "$p/$rkey [$reason]: mechanical rung still conflicts ($(tr '\n' ' ' <<<"$out")) — FIX ROUND with the conflict in its prompt"
      br_fix_round "$p" "$rkey" "$reason" "$url" "$rec" "$tkey"; return 0 ;;
    2)
      br_record "$p" "$ck" mechanical-failed "$reason" "merged with main the branch fails the hub's typecheck/unit gate" mechanicals
      say "$p/$rkey [$reason]: mechanical rung merged cleanly but the gate is RED — FIX ROUND"
      br_fix_round "$p" "$rkey" "$reason" "$url" "$rec" "$tkey"; return 0 ;;
    3)
      # The head moved between the read and the push: somebody (a build, another
      # lane) is working on this branch right now. Nothing is spent and nothing
      # is said twice — the next tick reads the new head.
      say "$p/$rkey [$reason]: mechanical rung's lease was rejected — the head moved under it; no rung spent, retried next tick"
      return 0 ;;
    6)
      # THE POOL TOOK IT (BH-486). The rung RAN — a queue row exists and a pool
      # machine is rebasing this branch — so it counts, and the conductor row
      # leaves the park for REBASING: a park left BLOCKED_HUMAN would have the
      # next tick of this lane start a fix round on top of a running rebase.
      # The conductor key is derived from the url the same way the rest of this
      # file derives it, and the reviewed sha is copied off the row so the
      # approval binding is untouched by the move.
      #
      # AND THE PARK COMES BACK. mc_pool_rebase_enqueue forgets this head's
      # previous `rebasedone` line, so the machine's answer is read like any
      # other: a second conflict parks the row again, the ladder is at
      # mechanicals=MAX, and the next offer is rung 2 (the fix round).
      ckey="$(mc_slug_of_url "$url")#$(mc_num_of_url "$url")"; rvw=$(mc_row_field "$ckey" 5)
      br_record "$p" "$ck" mechanical "$reason" \
        "queued a pool rebase of $br at ${head:0:8} ($(mc_pool_rebase_key "$(mc_num_of_url "$url")" "$head")); the conductor reads the pool's result" mechanicals
      mc_transition "$ckey" REBASING "pool rebase queued by the resolver" "$head" "${rvw:--}" "$url" "-" "-" "${rec:--}" >/dev/null
      say "$p/$rkey [$reason]: MECHANICAL — pool rebase queued for ${head:0:8}; the row leaves the park and the conductor reads the result"
      return 0 ;;
    7)
      # The queue refused it and nothing was spent, which is the rc-3 shape: no
      # rung, no state, the park is simply re-offered on the next tick.
      say "$p/$rkey [$reason]: pool queue unreachable — no rung spent, retried next tick"
      return 0 ;;
    *)
      # SETUP FAILED (rc 4: no credential that can read the repo, a fetch that
      # would not run, a clone that would not clone) — and any rc mc_rebase does
      # not document, which is the same thing said less clearly.
      #
      # It does NOT cascade inside the tick: the fix round needs the SAME clone
      # and the same credential, so falling through would walk a machine problem
      # down to a fresh rebuild in one go. And since 2026-09-16 it SPENDS
      # NOTHING either (br_setup_blocked). It used to spend the rung, on the
      # reasoning that a broken setup must not park a key for ever — but parking
      # it, out loud and with one alert, is exactly the right answer: the
      # alternative walked the ladder toward the rung that CLOSES PRs on a fact
      # about this box. The free rung is still there for the tick after somebody
      # fixes the box.
      br_setup_blocked "$p" "$ck" "$rkey" "$reason" "$url" "mc_rebase rc=$rc on $slug — a clone or credential problem; see the credential line in merge-conductor.log" mechanical
      return 0 ;;
  esac
}

# ── THE SUPERSEDE GUARD (BH-1642) ─────────────────────────────────────────────
# On 2026-09-23 the rebuild rung closed two PRs as "Superseded by a fresh build"
# that nobody should have thrown away. #1559 was parked `red-twice` on the heads
# BEFORE the lead force-pushed a reviewed fix; the rung closed it ten minutes
# after that push, and the new head went green and was approved minutes later.
# #1448 was closed `head-not-reapproved` six minutes after this lane's OWN fix
# round pushed 3d02abc6, while the lead's MERGE stood on the head that round had
# pushed over. Both were reopened by hand. So before the rung closes an OPEN PR
# (the supersede, and the ABANDONED close at the cap) it asks, in this order:
#
#   head-unreadable     the PR's current head could not be read: nothing is
#                       closed on a head nobody saw.
#   green-at-head       (BH-1671) the park is for a CI reason (red-ci-twice,
#                       red-twice, queue-ejected-twice) and mc_ci_state says the
#                       current head is green: the red count is about code that
#                       is gone, and the PR is the queue's. Read right after the
#                       head, so it outranks head-moved; only an affirmative
#                       green declines (pending, none and unavailable fall
#                       through), it logs `SKIP green-at-head` and releases the
#                       park. project-5 #3172/#3175 were closed green.
#                       Its other half is in mc_classify: the conductor no
#                       longer parks `red-ci-twice` (reds counted ACROSS
#                       heads), so a red head reaches this rung only as
#                       red-twice on that same head; red-ci-twice is a legacy
#                       row's reason.
#   park-moved-on       the conductor's row for the PR is no longer a park and
#                       no open hand-off record names a head: the conductor is
#                       judging the PR again (a recovered, non-sticky red-twice
#                       hand-off after a force-push is the #1559 shape).
#   head-moved          the conductor judged this park (red twice, not
#                       re-approved) on a head the PR is no longer on. That
#                       count is about code that is gone; it restarts on the new
#                       head, which is the conductor's to judge.
#   settle-window       a NEW head — one that replaced the head this lane last
#                       recorded for the PR, one the conductor did not judge, or
#                       this lane's own fix-round push — gets
#                       BR_SUPERSEDE_SETTLE_SECS for CI and the head-bound review
#                       to answer on it. The first sighting of a PR with no push
#                       evidence starts no window, so "red twice on the head it
#                       is on" is superseded exactly as before.
#   verdict             a lead/human verdict row stands on the current head, or
#                       a MERGE / MERGE-WITH-NOTES stands on the head this
#                       lane's fix round pushed or the head that round pushed
#                       OVER (the #1448 shape). Reviewed work is the lead's to
#                       throw away, never this rung's.
#   hold                the ticket is held (to_merge_hold: the HOLD, the
#                       one-PR-per-ticket loser list).
#
# FAIL CLOSED on a read (the operator, #1642): a verdict or hold read that cannot be
# made declines this tick, and so does an unreadable window while a window is
# in force. A LIBRARY that is not on the box is not a read — it is the state
# every lane in this file keeps for a half-synced box (br_hold_gate's rule), so
# the guard says so in one line of its own and today's rung runs.
#
# A DECLINE IS ONE LINE, `SUPERSEDE DECLINED (<reason>): …`, and it spends
# nothing: no close, no comment, no enqueue, no counter. The conductor's park is
# KEPT only for `hold` and the fail-closed reads; every other decline RELEASES
# it, so the conductor judges the head again (br_sup_decline). A decline that
# lasts BR_SUPERSEDE_DECLINE_ALERT_SECS pages once (br_sup_alert). Nothing here
# is a clock that kills: the window only ever DELAYS a close.
br_is_sha() { [[ "${1:-}" =~ ^[0-9a-f]{40}$ ]]; }

# br_judged_head <owner/repo> <num> — the full sha the conductor judged this
#   park on. The hand-off record comes first (mc_handoff_sticky's own order).
#   The row's head field counts ONLY while the row is still a park
#   (BLOCKED_HUMAN / RED_TWICE). A row the conductor has moved on carries the
#   head it is judging NOW, not the one it parked. A recovered hand-off with no
#   record would otherwise read the new head as the parked one, which is exactly
#   #1559. rc 1 when nothing names a full sha: unknown, never read as "moved".
#   rc 3 when the conductor HAS a row for this PR, the row is no longer a park,
#   and no unreleased hand-off record names a head: the conductor is judging
#   this PR again, so no park of it is standing to supersede on.
br_judged_head() {
  local key="$1#$2" row h="" hf rel=""
  hf=$(mc_handoff_file "$key" 2>/dev/null) || hf=""
  command -v mc_handoff_rel_file >/dev/null 2>&1 && rel=$(mc_handoff_rel_file "$key" 2>/dev/null)
  row=$(mc_row_get "$key" 2>/dev/null)
  case "$(cut -f2 <<<"$row")" in
    BLOCKED_HUMAN|RED_TWICE)
      # A RELEASED record is not the park any more (review N2). mc_transition
      # rewrites it only on a state CHANGE, so a BLOCKED_HUMAN -> BLOCKED_HUMAN
      # re-park on a new head leaves the old head in it while the row carries
      # the new one; read after the release, it would say head-moved until the
      # TTL re-kick, and never while this lane is saturated.
      if [ "$(cut -f2 <<<"$row")" = BLOCKED_HUMAN ] && command -v mc_handoff_owns >/dev/null 2>&1 \
         && mc_handoff_owns "$(cut -f7 <<<"$row")" && [ -n "$hf" ] && [ -s "$hf" ] \
         && { [ -z "$rel" ] || [ ! -e "$rel" ]; }; then
        h=$(cut -f2 "$hf")
      fi
      case "$h" in ''|-) h=$(cut -f4 <<<"$row") ;; esac ;;
    '') [ -n "$hf" ] && [ -s "$hf" ] && h=$(cut -f2 "$hf") ;;
    *) if [ -n "$hf" ] && [ -s "$hf" ] && { [ -z "$rel" ] || [ ! -e "$rel" ]; }; then
         h=$(cut -f2 "$hf")
       else
         return 3
       fi ;;
  esac
  h=$(printf '%s' "$h" | tr 'A-F' 'a-f')
  br_is_sha "$h" || return 1
  printf '%s' "$h"
}

# br_sup_seen <project> <cap-key> <pr-url> <head> — a rung that READ the PR's
#   head (mechanical, regenerate, fix round) records it, so the rebuild rung can
#   tell a head it has seen before from one pushed since. A head that replaces a
#   recorded one is a push this lane has now seen, and the window runs from here.
#   The first sighting starts no window.
br_sup_seen() {
  local p="$1" ck="$2" url="$3" h prev
  h=$(printf '%s' "${4:-}" | tr 'A-F' 'a-f')
  br_is_sha "$h" && [ "$OBSERVE" = 0 ] || return 0
  prev=$(br_load "$p" "$ck" | jq -r --arg u "$url" 'if .sup_pr == $u then (.sup_head // "") else "" end' 2>/dev/null)
  [ "$prev" = "$h" ] && return 0
  br_sup_write "$p" "$ck" \
    '.sup_pr=$u | .sup_head=$h | .sup_at=($a|tonumber) | .sup_settle=($s == "true")' \
    --arg u "$url" --arg h "$h" --arg a "$(date -u +%s)" --arg s "$([ -n "$prev" ] && echo true || echo false)"
}

# br_sup_write <project> <cap-key> <jq-filter> [jq args…] — one write of the
#   guard's own fields on the ticket's record.
br_sup_write() {
  local p="$1" ck="$2" flt="$3" f cur; shift 3
  f=$(br_file "$p" "$ck"); mkdir -p "$(dirname "$f")" 2>/dev/null
  cur=$(br_load "$p" "$ck" | jq -c --arg t "$(STAMP)" "$@" "$flt | .updated=\$t" 2>/dev/null) || return 1
  [ -n "$cur" ] && br_save "$p" "$ck" "$cur"
}

# br_fix_push_note <project> <cap-key> <pr-url> <pushed-sha> <base-sha> — the
#   fix round's push, remembered: the head it pushed, the head it pushed OVER,
#   and when. The pushed head is also the head this lane now knows the PR on,
#   with a window in force from the push.
br_fix_push_note() {
  br_sup_write "$1" "$2" \
    '.fix_pr=$u | .fix_head=$h | .fix_base=$b | .fix_at=($a|tonumber)
     | .sup_pr=$u | .sup_head=$h | .sup_at=($a|tonumber) | .sup_settle=true' \
    --arg u "$3" --arg h "$4" --arg b "${5:-}" --arg a "$(date -u +%s)"
}

# br_sup_decline <project> <cap-key> <rkey> <reason> <pr-url> <head> <kind> <why>
#   The ONE line, and what the decline does with the conductor's park.
#
#   WHICH DECLINES KEEP THE PARK (review N3). `hold` is the ticket's own
#   instruction, and the fail-closed reads (head-, verdict-, knob-unreadable)
#   know nothing yet: those keep it (BR_HOLD_PARKED, br_hold_gate's contract).
#   Every other decline says "this head is the conductor's to judge", so the
#   park is RELEASED and the conductor classifies the PR again. For `verdict`
#   that is the only way the lead's MERGE is ever read: a sticky park gets no
#   verdict read in the conductor.
br_sup_decline() {
  local p="$1" ck="$2" rkey="$3" reason="$4" url="$5" head="$6" kind="$7" why="$8"
  case "$kind" in hold|*-unreadable) BR_HOLD_PARKED=1 ;; esac
  # green-at-head leads with the words the ticket asked the log to carry.
  local skip=""; [ "$kind" = green-at-head ] && skip="SKIP green-at-head — "
  say "$p/$rkey [$reason]: ${skip}SUPERSEDE DECLINED ($kind): $why — nothing closed, nothing enqueued, no counter spent; asked again next tick"
  br_sup_alert "$p" "$ck" "$rkey" "$reason" "$url" "$head" "$kind" "$why"
}

# br_sup_alert <project> <cap-key> <rkey> <reason> <pr-url> <head> <kind> <why>
#   A DECLINE THAT DOES NOT END PAGES, ONCE (review N1). A resolver-owned park
#   is never paged by the conductor (mc_budget_check) and this lane alerts only
#   on ABANDONED, which a declined PR never reaches, so a verdict or an
#   unreadable read would strand the PR with nothing but a log line per tick.
#   One lane-alert per (PR, head, reason) once the same decline has lasted
#   BR_SUPERSEDE_DECLINE_ALERT_SECS; a new head or a new reason starts again.
#   `hold` never pages: it is an instruction being obeyed. An unreadable knob
#   pages on the first decline, which is the loud side of not knowing.
br_sup_alert() {
  local p="$1" ck="$2" rkey="$3" reason="$4" url="$5" head="$6" kind="$7" why="$8"
  local key st since alerted now thr
  [ "$kind" = hold ] && return 0
  [ "$OBSERVE" = 1 ] && return 0
  key="$url|${head:--}|$kind"; now=$(date -u +%s)
  st=$(br_load "$p" "$ck")
  if [ "$(jq -r '.decl_key // ""' <<<"$st" 2>/dev/null)" != "$key" ]; then
    br_sup_write "$p" "$ck" '.decl_key=$k | .decl_since=($a|tonumber) | .decl_alerted=false' \
      --arg k "$key" --arg a "$now"
    since=$now; alerted=false
  else
    since=$(jq -r '.decl_since // ""' <<<"$st" 2>/dev/null)
    alerted=$(jq -r '.decl_alerted // false' <<<"$st" 2>/dev/null)
  fi
  [ "$alerted" = true ] && return 0
  case "$since" in ''|*[!0-9]*) since=$now ;; esac
  thr="${BR_SUPERSEDE_DECLINE_ALERT_SECS:-}"
  case "$thr" in ''|*[!0-9]*) thr=0 ;; esac
  [ $(( now - since )) -ge "$thr" ] || return 0
  "$H/bin/lane-alert.sh" blocked-resolver "$p/$rkey: SUPERSEDE DECLINED ($kind) for $(( now - since ))s on ${url:--} at head ${head:0:12} — $why. The rebuild rung will not close this PR while that stands, and nothing else pages about a resolver-owned park; decide it (merge, push, or close) or clear what the reason names." >/dev/null 2>&1 || true
  br_sup_write "$p" "$ck" '.decl_alerted=true'
}

# br_supersede_guard <project> <cap-key> <rkey> <reason> <pr-url>
#   rc 0 the rung may close this PR; rc 1 it may not (one line already said why).
#   Only for an OPEN PR — the caller has already read its state.
br_supersede_guard() {
  local p="$1" ck="$2" rkey="$3" reason="$4" url="$5"
  local slug num cur rc st now judged prev supat settle start="" by="" win h seen=" " line v why lib=""
  slug=$(br_slug_of_url "$url") || return 0
  num=$(mc_num_of_url "$url"); [ -n "$num" ] || return 0
  cur=$(br_pr_field "$url" '.head.sha' "pr head"); rc=$?
  cur=$(printf '%s' "$cur" | tr 'A-F' 'a-f')
  # GitHub did not answer: nothing is closed on a head nobody saw. A head that
  # DID come back but is not a full sha is handed to vd_standing below, whose
  # contract answers rc 2 for it, so it still declines (verdict-unreadable).
  if [ "$rc" != 0 ]; then
    br_sup_decline "$p" "$ck" "$rkey" "$reason" "$url" "$cur" head-unreadable "the PR's current head could not be read (rc $rc), and nothing is closed on a head nobody saw"
    return 1
  fi
  # GREEN AT HEAD (BH-1671): a CI-reason park whose current head is green is a
  # count about code that is not there any more. Only an affirmative `green`
  # declines; pending, none and an unreadable read fall through to the rest.
  # A QUEUE EJECTION ON A QUEUE-ONLY REPO IS NOT ANSWERED BY THE HEAD (2026-09-24):
  # the head runs the fast checks only, so only a green batch carrying the PR is.
  if [ "$(br_ladder_class "$reason")" = ci-red ] && command -v mc_ci_state >/dev/null 2>&1 \
     && [ "$(mc_ci_state "$slug" "$cur")" = green ] \
     && { [ "$reason" != queue-ejected-twice ] || ! command -v mc_queue_batch_only >/dev/null 2>&1 \
          || ! mc_queue_batch_only "$slug" || [ "$(br_queue_batch "$slug" "$num" | cut -d' ' -f1)" = success ]; }; then
    br_sup_decline "$p" "$ck" "$rkey" "$reason" "$url" "$cur" green-at-head "CI is green on the PR's current head ${cur:0:12} — the red count is about code that is not there any more; left for the queue"
    return 1
  fi
  now=$(date -u +%s)
  st=$(br_load "$p" "$ck")
  judged=$(br_judged_head "$slug" "$num"); rc=$?
  if [ "$rc" = 3 ]; then
    br_sup_decline "$p" "$ck" "$rkey" "$reason" "$url" "$cur" park-moved-on "the conductor's row for $slug#$num is $(mc_row_field "$slug#$num" 2 2>/dev/null) now, not a park, and no open hand-off names a head — no count of it stands on ${cur:0:12}"
    return 1
  fi
  [ "$rc" = 0 ] || judged=""
  # WHAT THIS LANE KNOWS ABOUT THE PR'S HEAD, brought up to date. A head that
  # replaces the one recorded for THIS PR, or that the conductor did not judge,
  # is a push this lane has now seen: the window runs from here.
  prev=$(jq -r --arg u "$url" 'if .sup_pr == $u then (.sup_head // "") else "" end' <<<"$st" 2>/dev/null)
  supat=$(jq -r --arg u "$url" 'if .sup_pr == $u then (.sup_at // "") else "" end' <<<"$st" 2>/dev/null)
  settle=$(jq -r --arg u "$url" 'if .sup_pr == $u then (.sup_settle // false) else false end' <<<"$st" 2>/dev/null)
  if [ "$prev" != "$cur" ]; then
    settle=false
    { [ -n "$prev" ] || { [ -n "$judged" ] && [ "$judged" != "$cur" ]; }; } && settle=true
    supat=$now
    [ "$OBSERVE" = 1 ] || br_sup_write "$p" "$ck" \
      '.sup_pr=$u | .sup_head=$h | .sup_at=($a|tonumber) | .sup_settle=($s == "true")' \
      --arg u "$url" --arg h "$cur" --arg a "$now" --arg s "$settle"
  fi
  if [ -n "$judged" ] && [ "$judged" != "$cur" ]; then
    br_sup_decline "$p" "$ck" "$rkey" "$reason" "$url" "$cur" head-moved "the park was judged on ${judged:0:12} and the PR is on ${cur:0:12} now — that count is about a head that is gone, and it restarts on the new one"
    return 1
  fi
  [ "$settle" = true ] && case "$supat" in ''|*[!0-9]*) ;; *) start=$supat; by="a new head, ${cur:0:12}, first seen by this lane" ;; esac
  v=$(jq -r --arg u "$url" 'if .fix_pr == $u then (.fix_at // "") else "" end' <<<"$st" 2>/dev/null)
  case "$v" in ''|*[!0-9]*) ;; *)
    if [ -z "$start" ] || [ "$v" -gt "$start" ]; then
      start=$v; by="this lane's own fix round, which pushed $(jq -r '.fix_head // "?"' <<<"$st" | cut -c1-12)"
    fi ;;
  esac
  if [ -n "$start" ]; then
    win="${BR_SUPERSEDE_SETTLE_SECS:-}"
    case "$win" in ''|*[!0-9]*)
      br_sup_decline "$p" "$ck" "$rkey" "$reason" "$url" "$cur" knob-unreadable "BR_SUPERSEDE_SETTLE_SECS is '${win:-unset}', so the settle window after $by cannot be measured"
      return 1 ;;
    esac
    if [ $(( now - start )) -lt "$win" ]; then
      br_sup_decline "$p" "$ck" "$rkey" "$reason" "$url" "$cur" settle-window "$(( win - (now - start) ))s of the ${win}s window left after $by (PR head ${cur:0:12}) — CI and the head-bound review answer on it first"
      return 1
    fi
  fi
  # A LEAD/HUMAN VERDICT on the current head, the head this lane pushed, or the
  # head its push replaced. Bound to the full sha, so a verdict on older code
  # protects nothing it did not read.
  if command -v vd_standing >/dev/null 2>&1; then
    # The CURRENT head is always asked, whatever it looks like: the reader owns
    # "is this a head a row can bind to" and fails closed on one that is not.
    # ANY lead/human verdict standing on it keeps the PR (a BLOCK there is the
    # lead's to act on, not this rung's) — with ONE exception (BH-4149): a BLOCK
    # on a head frozen in noop_heads. This lane's fix round already ran on that
    # head against the lead's own findings and answered none of them, so the
    # BLOCK has been acted on and is the reason to rebuild, not to keep the PR.
    # Declining there parked the PR for ever behind a "decide it" page.
    line=$(vd_standing "$slug" "$num" "$cur"); rc=$?
    if [ "$rc" = 0 ] && [ "$(cut -f1 <<<"$line")" = BLOCK ] && br_has_field_value "$st" noop_heads "$cur"; then
      say "$p/$rkey [$reason]: a $(cut -f2 <<<"$line") BLOCK (row $(cut -f3 <<<"$line")) stands on ${cur:0:12}, and the fix round on that head answered none of its findings (fix-round-noop) — the BLOCK does not keep this PR"
      rc=1
    fi
    case "$rc" in
      0) br_sup_decline "$p" "$ck" "$rkey" "$reason" "$url" "$cur" verdict "a $(cut -f2 <<<"$line")/human $(cut -f1 <<<"$line") verdict (row $(cut -f3 <<<"$line")) stands on ${cur:0:12} — reviewed work is the lead's to throw away"
         return 1 ;;
      1) ;;
      *) br_sup_decline "$p" "$ck" "$rkey" "$reason" "$url" "$cur" verdict-unreadable "the verdicts table could not be read for ${cur:0:12} (logs/verdicts.log says why), so whether a lead verdict stands there is unknown"
         return 1 ;;
    esac
    # The two REMEMBERED heads (the one this lane's fix round pushed, and the
    # one it pushed over) are protected only by a CLEARANCE — MERGE or
    # MERGE-WITH-NOTES, vd_clear_word's rule (review N4). A lead BLOCK on the
    # head the fix round replaced says "do not merge that code", not "keep this
    # PR", and must not hold the PR for the rest of its life.
    seen=" $cur "
    for h in "$(jq -r --arg u "$url" 'if .fix_pr == $u then (.fix_head // "") else "" end' <<<"$st" 2>/dev/null)" \
             "$(jq -r --arg u "$url" 'if .fix_pr == $u then (.fix_base // "") else "" end' <<<"$st" 2>/dev/null)"; do
      h=$(printf '%s' "$h" | tr 'A-F' 'a-f')
      br_is_sha "$h" || continue
      case "$seen" in *" $h "*) continue ;; esac
      seen="$seen$h "
      command -v vd_clear_word >/dev/null 2>&1 || break
      if v=$(vd_clear_word "$slug" "$num" "$h"); then
        br_sup_decline "$p" "$ck" "$rkey" "$reason" "$url" "$cur" verdict "a lead/human $v stands on ${h:0:12}, the head this lane's fix round pushed or pushed over — reviewed work is the lead's to throw away"
        return 1
      fi
    done
  else
    lib="no verdict reader (bin/lib/verdicts.sh) on this box"
  fi
  if command -v to_merge_hold >/dev/null 2>&1; then
    if why=$(to_merge_hold "$p" "$slug" "$num"); then
      br_sup_decline "$p" "$ck" "$rkey" "$reason" "$url" "$cur" hold "${why:-the ticket is held}"
      return 1
    fi
  else
    lib="${lib:+$lib; }no ownership reader (bin/lib/ticket-ownership.sh) on this box"
  fi
  [ -z "$lib" ] || say "$p/$rkey [$reason]: supersede guard ran without every reader — $lib; the rung proceeds as it did before BH-1642"
  return 0
}

# REBUILD FRESH. The LAST rung for a branch park (rung 3) and the first and only
# one for a park with no branch to fix — a dead pool machine, a malformed plan, a
# BUILD_DEAD record. Close the stale PR, enqueue the same ticket against CURRENT
# main. It ends most of these, and it is also the most expensive thing this lane
# can buy, which is why the two cheaper rungs run first (br_ladder).
br_rebuild_fresh() {
  local p="$1" rkey="$2" reason="$3" url="$4" rec="$5" tkey="$6" st n cap lim ck mst mrc row jobid enq external inflight_rc crc
  ck=$(br_cap_key "$p" "$rkey" "$tkey")
  if br_is_external "$p" "$ck" "$reason"; then
    command -v br_xpr_terminal >/dev/null 2>&1 && { br_xpr_terminal "$@"; return $?; }
    br_xpr_parked "$p/$rkey [$reason]: external PR — never closed or rebuilt; left for the author"; return 3
  fi
  # A MERGED PR IS NEVER REBUILT, from any branch into this rung — and neither is
  # a PR whose state this tick could not read (#783): unknown is not "not merged".
  if [ -n "$url" ] && [ "$url" != "-" ]; then
    mst=$(br_pr_state "$url"); mrc=$?
    if [ "$mrc" = 75 ]; then
      say "$p/$rkey [$reason]: the PR state is UNVERIFIABLE this tick — nothing closed, nothing enqueued, no counter spent, retried next tick"
      return 0
    fi
    if [ "$mst" = merged ]; then
      br_resolve_merged "$p" "$ck" "$reason" "$url" "$rec"
      return 0
    fi
  fi
  # DID A HUMAN SAY NO? Asked BEFORE the cap check on purpose: a held ticket
  # gets neither a close nor an ABANDONED alert on the tick its ladder happens
  # to run out.
  br_hold_gate "$p" "$rkey" "$reason" "$url" "$rec" "$tkey" || return 0
  # IS THE TICKET ALREADY DONE ON THE BOARD (BH-4438)? Same place, same reason.
  br_board_done_gate "$p" "$rkey" "$reason" "$url" "$rec" "$tkey" || return 0
  st=$(br_load "$p" "$ck"); n=$(br_num "$st" rebuilds)
  n=$(br_cap_rows "$p" "$rkey" "$reason" "$n" "$url" rebuild rebuilds)
  # HOW MANY REBUILDS THIS TICKET IS WORTH is the shape's answer (BH-579): three
  # for a large conflict, exactly one for a small one — a two-line disagreement
  # that survived a rebuild will survive the next two.
  lim=$(br_rebuild_cap "$st")
  # HOW MANY IT HAS ALREADY BOUGHT is the LEDGER's answer (BH-947): the distinct
  # job ids this lane enqueued, so a duplicate the worker deduped never spends a
  # rung. The legacy `rebuilds` counter is the fallback for a row with no ledger.
  cap=$(br_jobs_count "$st")
  # THE CAP IS THE LARGER OF THE TWO COUNTERS, never just the ledger (BH-947
  # review B1). `rebuilds` is bumped in exactly two places — br_rebuild_settle's
  # rc-0 arm, beside br_job_add, and its self-capped nokey arm — so for a row
  # born after this landed `rebuilds >= length(rebuild_jobs)` always holds and
  # the max changes nothing. For a row parked BEFORE it (rebuilds:2, no ledger)
  # the first post-merge enqueue writes a one-entry ledger, and reading the
  # ledger alone would forget the two builds already bought: the ladder would
  # buy three more, log `rebuild 4 of 3`, and the ABANDONED alert would say
  # "rebuilt fresh 3 times" against a counter of 5.
  case "$cap" in ''|null) cap=$n ;; *) [ "$cap" -ge "$n" ] 2>/dev/null || cap=$n ;; esac

  # IS A REBUILD ALREADY IN FLIGHT? Asked BEFORE the cap check, the event and
  # the PR close: a duplicate answer must not spend a rung or close anything.
  row=$(br_rebuild_inflight "$p" "$tkey" 2>/dev/null) || inflight_rc=$?
  inflight_rc=${inflight_rc:-0}
  if [ "$inflight_rc" = 0 ]; then
    # THE LEDGER IS KEYED ON enqueued_at, not on the id: the id this lane minted
    # carries a ~rN suffix the worker's row has never seen, so matching on the
    # whole string would read every one of our own builds as somebody else's.
    enq=$(printf '%s' "$row" | cut -f2)
    jobid=$(br_job_for_enq "$st" "$enq")
    external=""; [ -n "$jobid" ] || { jobid="$tkey@${enq}"; external=external; }
    if [ "$OBSERVE" = 1 ]; then
      say "$p/$rkey [$reason]: WOULD wait for rebuild already in flight (job $jobid) — observe mode"
      return 0
    fi
    br_rebuild_wait "$p" "$ck" "$jobid" "$external" "$row"
    return 3
  fi
  if [ "$inflight_rc" = 2 ] && [ "$cap" -ge "$lim" ]; then
    jobid=$(printf '%s' "$st" | jq -r '(.rebuild_jobs[-1].id // "unknown")' 2>/dev/null)
    [ -n "$jobid" ] && [ "$jobid" != "null" ] || jobid="unknown"
    if [ "$OBSERVE" = 1 ]; then
      say "$p/$rkey [$reason]: WOULD hold at the rebuild cap — queue unreadable (last job $jobid) — observe mode"
      return 0
    fi
    BR_REBUILD_WAITING=1
    br_set_wait "$p" "$ck" "$jobid"
    say "$p/$ck: cannot read the queue to tell whether job $jobid finished — holding, NOT abandoned"
    return 3
  fi
  # MAY THIS OPEN PR BE THROWN AWAY AT ALL? (BH-1642.) Asked after the cheap
  # answers above and before either close below — the supersede and the
  # ABANDONED close at the cap both discard the PR. A decline spends nothing.
  if [ "${mst:-}" = open ] && ! br_supersede_guard "$p" "$ck" "$rkey" "$reason" "$url"; then
    return 0
  fi
  if [ "$cap" -ge "$lim" ]; then
    if [ "$OBSERVE" = 1 ]; then
      say "$p/$rkey [$reason]: WOULD abandon — rebuilt fresh $cap times and the ladder is exhausted — observe mode"
      return 0
    fi
    br_abandon "$p" "$ck" "$reason" "$url" "$rec" "rebuilt fresh $cap times and the ladder is exhausted$(br_jobs_why "$st")" "$tkey"
    return 0
  fi
  if [ "$OBSERVE" = 1 ]; then say "$p/$rkey [$reason]: WOULD rebuild fresh (rebuild $((n+1)) of $lim) — observe mode"; return 0; fi
  # THE CLOSE COMES FIRST, AND IT HAS TO LAND (#783). A rebuild enqueued behind a
  # PR that is still open is two builds of one ticket, so a close GitHub refused
  # defers the whole rung: no event, no superseded marker, no enqueue, no
  # counter. The park is re-offered next tick and tries the same close again.
  crc=0
  br_close_pr "$url" "Superseded by a fresh build against current main (blocked-resolver: $reason, rebuild $((n+1)) of $lim). This branch is left in place; the rebuild takes the next free name." || crc=$?
  if [ "$crc" = 3 ]; then
    br_xpr_parked "$p/$rkey [$reason]: $url is an external author's PR — parked for the author, nothing recorded"
    return 3
  fi
  if [ "$crc" != 0 ]; then
    say "$p/$rkey [$reason]: rebuild deferred — the stale PR could not be closed this tick, nothing enqueued and no counter spent"
    return 0
  fi
  if [ -n "$(br_ladder_class "$reason")" ]; then
    br_event resolver_rung "$p" "$ck" "$reason" "rung 3 rebuild-fresh (rebuild $((n+1)) of $lim)"
  else
    br_event resolver_rung "$p" "$ck" "$reason" "rebuild-fresh (rebuild $((n+1)) of $lim; this park has no branch to fix, so there is no ladder above it)"
  fi
  # The stale record is marked so no sweep re-handles it and this lane does not
  # re-discover it as a candidate next tick. It is MARKED, never deleted: it is
  # the evidence the ABANDONED alert points at.
  [ -n "$rec" ] && [ "$rec" != "-" ] && [ -d "$rec" ] && { : > "$rec/.blocked-resolver-superseded"; touch "$rec/COMMENTED" 2>/dev/null; }
  # THE PARKED PR AND RECORD GO ON THE TICKET BEFORE THE ENQUEUE (BH-488), not
  # after it succeeds. Everything above this line is already irreversible — the
  # PR is closed, the record is marked, the conductor row will be released — so
  # if the enqueue then fails, these two fields are the ONLY way a later tick
  # can find its way back to this ticket. Written first, they make the retry
  # possible; written last, they were exactly what the failed path never got.
  br_set_field "$p" "$ck" parked_url "${url:--}"
  br_set_field "$p" "$ck" parked_rec "${rec:--}"
  local erc=0
  br_enqueue_fresh "$p" "$tkey" "$n" "$reason rebuild $((n+1)) of $lim" "$rec" "$rkey" "$url" || erc=$?
  case "$erc" in
    3) br_enqueue_dup_race "$p" "$ck" "$tkey"; return 3 ;;
    *)
      br_rebuild_settle "$p" "$ck" "$rkey" "$reason" "$url" "$rec" "$tkey" "$n" "$erc" \
        "rebuild $((n+1)) of $lim" ;;
  esac
}

# br_rebuild_settle <p> <ck> <rkey> <reason> <url> <rec> <tkey> <n> <erc> <label>
#   WHAT AN ENQUEUE ANSWERED, READ THE SAME WAY BY BOTH RUNGS that make one
#   (br_rebuild_fresh and br_rebuild_retry). Three answers, three meanings:
#
#   rc 0  it landed: the rebuild counter is spent, the failure counter is reset
#         and the page marker removed. This is the ONLY arm that bumps
#         `rebuilds` — a build is never stamped done without a queue row id
#         behind it.
#   rc 2  no ticket key: DETERMINISTIC, so it is a spent attempt and the cap
#         ends the ladder (BH-530, project-5 #1634). Unchanged here.
#   rc 3  never reaches here: a `duplicate` answer is a WAIT, not a settlement,
#         and both rungs route it to br_enqueue_dup_race before calling this.
#   rc 4  the board answered and this key is not on it (BH-1007): also
#         DETERMINISTIC, but on its OWN counter (`board_misses`), because a
#         ticket the board cannot name is a different thing to fix than a PR
#         with no derivable key. Same cap, and the abandon pages with the key.
#         The attempt is `rebuild-fresh-board-miss`, and it is re-offered by
#         br_from_rebuilds exactly like `rebuild-fresh-failed` — those two are
#         the retryable pair. The miss is only ever counted a second time
#         because the retry rung re-runs the enqueue; without the re-offer the
#         conductor's closed sweep buries the park after miss 1.
#         IT IS 4 AND NOT 3 BECAUSE BH-947 TOOK 3 for the duplicate-enqueue
#         race, which both rungs intercept before this function is reached. Two
#         different answers on one code would have routed every board miss into
#         br_enqueue_dup_race — a REBUILD_WAIT hold on a build that was never
#         enqueued — and this arm would never have run.
#
#   rc 1  the enqueue could not be made THIS time — a jobs client that is down,
#         a box that would not answer. No counter is spent, the attempt is
#         recorded ONCE PER EPISODE (the hold-unreadable precedent: this lane
#         re-offers every ten minutes, and 144 identical entries a day would
#         bury the attempt list that the ABANDONED alert prints), and the
#         failure counter climbs. AND IT ENDS (BH-1122): after
#         BR_ENQUEUE_FAIL_MAX failures carrying the SAME reason the park is
#         STALLED — one alert, and no rung spent on it until its row changes.
#         "Identical" is the reason string, so a jobs client that goes down and
#         then a box that will not answer are two episodes, not six failures.
br_rebuild_settle() {
  local p="$1" ck="$2" rkey="$3" reason="$4" url="$5" rec="$6" tkey="$7" n="$8" erc="$9" label="${10}"
  local st last fails why prev m
  case "$erc" in
    0)
      # THE ONE LANDED PATH, for both rungs. It lives here rather than inline in
      # each caller because the inline copies drifted: one of them dropped the
      # `enqueue_why` clear and BH-1122's per-episode attempt record went with it
      # (BH-947 review B1).
      # OLD CLIENT (no queue_row): keep legacy counter behaviour, no ledger.
      if br_pool_routed "$p" && [ -n "${BR_JOB_ID:-}" ] && command -v queue_row >/dev/null 2>&1; then
        br_job_add "$p" "$ck" "$BR_JOB_ID" "$BR_JOB_ENQ"
      fi
      # THE POOL BUILD IS BOUGHT HERE, and nowhere else. This is the only arm of
      # either rebuild rung that an enqueue reaches, so it is the only honest
      # place for the per-tick cap's counter (review I2).
      BR_REBUILD_BOUGHT=1
      br_record "$p" "$ck" rebuild-fresh "$reason" "fresh build enqueued against current main ($label${BR_JOB_ID:+, job $BR_JOB_ID})" rebuilds "$url" -
      # The closed PR's row moves now that there is a successor to name (BH-389).
      br_row_closed "$p" "$tkey" "$rec" "$url" superseded \
        "closed unmerged by blocked-resolver ($reason); superseded by rebuild ${BR_JOB_ID:-(job id not returned)} — $label" "$reason"
      br_set_num "$p" "$ck" enqueue_failures 0
      # BOTH non-terminal counters are spent by an enqueue that landed. Leaving
      # board_misses behind would carry misses from a board outage into the next
      # park on the same cap key: two old misses plus one new one is an
      # immediate abandon for a ticket the board answered for in between.
      br_set_num "$p" "$ck" board_misses 0
      br_set_field "$p" "$ck" enqueue_why ""
      # A build that STARTED is never still waiting on the last one.
      br_set_wait "$p" "$ck" -
      say "$p/$rkey [$reason]: REBUILD FRESH $label" ;;
    2)
      # NO KEY, AND THE SAME ANSWER EVERY TICK (2026-09-16, project-5 #1634).
      # The branch, the title and the record are all read before we get here and
      # none of them carried a key; nothing about the next tick changes that. So
      # it is a spent rung attempt like any other, and the third one is the cap.
      br_record "$p" "$ck" rebuild-fresh-nokey "$reason" "refused: no ticket key (branch/title/record all empty), $label" rebuilds "$url" -
      n=$(br_num "$(br_load "$p" "$ck")" rebuilds)
      n=$(br_cap_rows "$p" "$rkey" "$reason" "$n" "$url" rebuild rebuilds)
      say "$p/$rkey [$reason]: rebuild enqueue REFUSED — no ticket key; counted as attempt $n of $MAX_REBUILDS"
      if [ "$n" -ge "$MAX_REBUILDS" ]; then
        br_abandon "$p" "$ck" "$reason" "$url" "$rec" \
          "the fresh rebuild was refused $n times: no ticket key could be derived from the PR branch, its title, or a build record" "$tkey"
      fi ;;
    4)
      # BOARD ANSWERED BUT TICKET ID UNRESOLVED (BH-1007). The API is reachable
      # and the ticket list is readable, but this key is not present in it.
      # Count it as a miss; after MAX_REBUILDS identical misses the ladder is
      # exhausted and the park is abandoned. A transient failure (empty curl,
      # no token) stays rc 1 and is retried for free.
      br_record "$p" "$ck" rebuild-fresh-board-miss "$reason" "board answered but ticket id unresolved for $tkey, $label" board_misses
      m=$(br_num "$(br_load "$p" "$ck")" board_misses)
      say "$p/$rkey [$reason]: rebuild enqueue BOARD MISS — ticket id unresolved; counted as miss $m of $MAX_REBUILDS"
      if [ "$m" -ge "$MAX_REBUILDS" ]; then
        [ -x "$H/bin/lane-alert.sh" ] && "$H/bin/lane-alert.sh" blocked-resolver \
          "$p/$tkey: the fresh rebuild was abandoned after $m identical board-miss attempts — the board answered but no ticket id matched $tkey. The outcome and the attempts are in $H/logs/ALERTS.log and $H/state/blocked-resolver/$p/$ck.json." >/dev/null 2>&1 || true
        br_abandon "$p" "$ck" "$reason" "$url" "$rec" \
          "the fresh rebuild missed the board ticket $m times: the board answered but no ticket id matched $tkey" "$tkey"
      fi ;;
    *)
      st=$(br_load "$p" "$ck")
      last=$(printf '%s' "$st" | jq -r '[.attempts[]? | select((.action // "") | . != "held" and . != "stalled" and . != "stall-cleared" and (startswith("hold-") | not))] | last | (.action // "")' 2>/dev/null)
      why="${BR_ENQUEUE_WHY:-no reason recorded}"
      # THE STREAK IS PER REASON. A failure that says something new is a new
      # episode: the jobs client coming back and the box going away are two
      # different things to fix, and counting them together would stall a park
      # nobody has actually retried three times for one cause.
      prev=$(printf '%s' "$st" | jq -r '.enqueue_why // ""' 2>/dev/null)
      if [ "$prev" = "$why" ]; then fails=$(( $(br_num "$st" enqueue_failures) + 1 )); else fails=1; fi
      [ "$last" = rebuild-fresh-failed ] \
        || br_record "$p" "$ck" rebuild-fresh-failed "$reason" "the enqueue did not land ($why); retried next tick, $label"
      br_set_num "$p" "$ck" enqueue_failures "$fails"
      br_set_field "$p" "$ck" enqueue_why "$why"
      if [ "$fails" -ge "$ENQUEUE_FAIL_MAX" ]; then
        br_stall "$p" "$ck" "$rkey" "$reason" "$url" "$rec" "$tkey" "rebuild enqueue" "$why" \
                 "$(br_stall_fp "$reason" "$url" "$rec")" "$fails"
        return 0
      fi
      say "$p/$rkey [$reason]: rebuild enqueue FAILED ${fails}x ($why) — retried next tick, no counter spent" ;;
  esac
}

# RETRY THE ENQUEUE, AND NOTHING ELSE (BH-488). Reached from a state file whose
# last attempt is `rebuild-fresh-failed`: rung 3 already ran, so the PR is
# closed, the record is marked and the conductor row is released. The only thing
# still owed is the queue row.
#
# It never calls br_close_pr and never re-marks the record — both were done once,
# and doing them again is how one park turns into two closed PRs. The guards are
# rung 3's, in rung 3's order: a PR somebody merged in the meantime resolves, a
# HOLD on the ticket stops it, and the rebuild cap still ends the ladder.
br_rebuild_retry() {
  local p="$1" rkey="$2" reason="$3" url="$4" rec="$5" tkey="$6" st n k cap ck mst mrc row jobid enq external inflight_rc erc=0
  ck=$(br_cap_key "$p" "$rkey" "$tkey")
  # Same three answers as rung 3's own guard: merged resolves, unreadable defers,
  # and only a state somebody actually read lets the retry proceed.
  if [ -n "$url" ] && [ "$url" != "-" ]; then
    mst=$(br_pr_state "$url"); mrc=$?
    if [ "$mrc" = 75 ]; then
      say "$p/$rkey [$reason]: the PR state is UNVERIFIABLE this tick — the enqueue retry is deferred, no counter spent"
      return 0
    fi
    if [ "$mst" = merged ]; then
      br_resolve_merged "$p" "$ck" "$reason" "$url" "$rec"
      return 0
    fi
  fi
  br_hold_gate "$p" "$rkey" "$reason" "$url" "$rec" "$tkey" || return 0
  br_board_done_gate "$p" "$rkey" "$reason" "$url" "$rec" "$tkey" || return 0
  st=$(br_load "$p" "$ck"); n=$(br_num "$st" rebuilds); k=$(br_num "$st" enqueue_failures)
  n=$(br_cap_rows "$p" "$rkey" "$reason" "$n" "$url" rebuild rebuilds)
  cap=$(br_jobs_count "$st")
  # The larger of the two counters, for the reason br_rebuild_fresh spells out:
  # a row parked before the ledger landed must not buy its ladder a second time.
  case "$cap" in ''|null) cap=$n ;; *) [ "$cap" -ge "$n" ] 2>/dev/null || cap=$n ;; esac

  row=$(br_rebuild_inflight "$p" "$tkey" 2>/dev/null) || inflight_rc=$?
  inflight_rc=${inflight_rc:-0}
  if [ "$inflight_rc" = 0 ]; then
    # THE LEDGER IS KEYED ON enqueued_at, not on the id: the id this lane minted
    # carries a ~rN suffix the worker's row has never seen, so matching on the
    # whole string would read every one of our own builds as somebody else's.
    enq=$(printf '%s' "$row" | cut -f2)
    jobid=$(br_job_for_enq "$st" "$enq")
    external=""; [ -n "$jobid" ] || { jobid="$tkey@${enq}"; external=external; }
    if [ "$OBSERVE" = 1 ]; then
      say "$p/$rkey [$reason]: WOULD wait for rebuild already in flight (job $jobid) — observe mode"
      return 0
    fi
    br_rebuild_wait "$p" "$ck" "$jobid" "$external" "$row"
    return 3
  fi
  if [ "$inflight_rc" = 2 ] && [ "$cap" -ge "$MAX_REBUILDS" ]; then
    jobid=$(printf '%s' "$st" | jq -r '(.rebuild_jobs[-1].id // "unknown")' 2>/dev/null)
    [ -n "$jobid" ] && [ "$jobid" != "null" ] || jobid="unknown"
    if [ "$OBSERVE" = 1 ]; then
      say "$p/$rkey [$reason]: WOULD hold at the rebuild cap — queue unreadable (last job $jobid) — observe mode"
      return 0
    fi
    BR_REBUILD_WAITING=1
    br_set_wait "$p" "$ck" "$jobid"
    say "$p/$ck: cannot read the queue to tell whether job $jobid finished — holding, NOT abandoned"
    return 3
  fi
  if [ "$cap" -ge "$MAX_REBUILDS" ]; then
    if [ "$OBSERVE" = 1 ]; then
      say "$p/$rkey [$reason]: WOULD abandon — rebuilt fresh $cap times and the ladder is exhausted — observe mode"
      return 0
    fi
    br_abandon "$p" "$ck" "$reason" "$url" "$rec" "rebuilt fresh $cap times and the ladder is exhausted$(br_jobs_why "$st")" "$tkey"
    return 0
  fi
  if [ "$OBSERVE" = 1 ]; then
    say "$p/$rkey [$reason]: WOULD retry the enqueue (rebuild $((n+1)) of $MAX_REBUILDS, retry $((k+1))) — observe mode"
    return 0
  fi
  br_enqueue_fresh "$p" "$tkey" "$n" "$reason rebuild $((n+1)) of $MAX_REBUILDS (enqueue retry $((k+1)))" "$rec" "$rkey" "$url" || erc=$?
  case "$erc" in
    3) br_enqueue_dup_race "$p" "$ck" "$tkey"; return 3 ;;
    *)
      br_rebuild_settle "$p" "$ck" "$rkey" "$reason" "$url" "$rec" "$tkey" "$n" "$erc" \
        "rebuild $((n+1)) of $MAX_REBUILDS (enqueue retry $((k+1)))" ;;
  esac
}

# br_setup_blocked <project> <cap-key> <rkey> <reason> <url> <what> [rung]
#   THE RUNG COULD NOT START, WHICH IS NOT A RUNG THAT FAILED. `rung` is
#   fix-round (the default, rung 2) or mechanical (rung 1); both reach here for
#   the same class of reason and neither spends anything.
#
#   the operator, 2026-09-16: "We shouldn't have rules that kill PRs because of time; it
#   should be event based." The same holds for a rule that kills a PR because of
#   THIS BOX. cromford #489 (12:04:57Z) and #465 (01:44:26Z) were both
#   CLOSED by the rebuild rung after `worktree add failed for origin/ticket/...`
#   and `no repo/branch for <url>` — the hub has no /root/repos/cromford
#   clone, so rung 2 could never run there, and rung 3 closed two finished PRs
#   on a machine problem that had nothing to do with either branch.
#
#   A missing clone, an unresolvable remote ref and a failed `worktree add` are
#   FACTS ABOUT THE MACHINE, not events about the PR. So this rung:
#     * spends NO counter (br_record without a bump field), so the ladder does
#       not walk toward the rebuild on a setup failure;
#     * closes nothing and enqueues nothing;
#     * pages ONCE per park, naming what is missing and who fixes it;
#     * is retried on the next tick, on the SAME branch, as the same rung.
#   The escalation to rung 3 stays exactly where it was: an agent that ran and
#   did not produce a verified commit, a push the lease rejected, a fix-round cap
#   that is spent. Those are events.
#
#   Rung 1 joins it (2026-09-16): `mc_rebase` rc 4 is the same sentence in the
#   same place — no credential, no clone, a fetch that would not run — and it
#   used to spend the mechanical rung, which walked a park one step closer to the
#   rung that closes PRs for a reason that was never about the PR.
br_setup_blocked() {
  local p="$1" ck="$2" rkey="$3" reason="$4" url="${5:--}" what="$6" rung="${7:-fix-round}" f name
  # What the page says is NEEDED (BH-594): a missing clone is the default, and a
  # caller whose block is not about a clone says what it IS about.
  local need="${8:-a working clone at $REPOS/$p and a credential that can fetch it}"
  case "$rung" in
    mechanical) name="the mechanical rung" ;;
    regen)      name="the regenerate rung" ;;
    *)          name="the fix round" ;;
  esac
  say "$p/$rkey [$reason]: $name could not START ($what) — a machine problem, not a failed rung: no rung spent, nothing closed, retried next tick"
  # ONE of everything per park, the way br_nokey_alert does it: this lane
  # re-offers the same park every ten minutes, and a block that stands for a day
  # would otherwise write 144 alerts, 144 beats and 144 attempt entries into a
  # record whose whole job is to say what was TRIED. The log line above is the
  # per-tick evidence; the record, the event and the page are per EPISODE, and
  # the marker is deleted the moment a rung runs, so the next block says it all
  # again. Stopping is an alert, not a whisper — but only the once.
  f="$ST/$p/$ck.setup-alerted"; mkdir -p "$(dirname "$f")" 2>/dev/null
  [ -e "$f" ] && return 0
  : > "$f"
  br_record "$p" "$ck" "$rung-blocked" "$reason" "$name could not START: $what — no rung spent, nothing closed, retried next tick"
  br_event resolver_setup_blocked "$p" "$ck" "$reason" "$name could not start: $what — no rung spent, no rebuild, no close"
  "$H/bin/lane-alert.sh" blocked-resolver "$p/$rkey [$reason]: the resolver's $rung rung cannot START on ${url:--no url} — $what. The PR is LEFT OPEN and nothing was rebuilt (an event-based ladder never closes a PR over a machine problem), so this park stands until somebody fixes the box. Needed on $(hostname 2>/dev/null || echo this box): $need." >/dev/null 2>&1 || true
  return 0
}

# br_findings <url> [reason] [head] — the findings the reviewer already posted,
# which are what a fix round is FOR. The head-bound re-review signs its comment,
# so the newest one carrying that signature is the brief; anything else and we
# say so rather than sending an agent off to fix findings it was never given.
#
# A REVIEW-LANE PARK READS THE REVIEW, NOT THE COMMENTS (BH-872). That verdict
# is posted as a REVIEW (a comment-state review since BH-872's workstream A), so
# the head-bound comment grep below would never find it. Same read as
# br_from_reviews, and the head is passed in by the caller that already has it
# rather than bought a second time.
#
# A LEAD'S REVIEW LEADS EVERY BRIEF (BH-2200). A standing lead/human
# CHANGES_REQUESTED on this head (br_lead_pick) is prepended, framed with
# BR_LEAD_HDR, whatever the reason; the lane's own findings follow it.
#
#   rc 0   the comments were read: the newest signed body, or empty when there
#          genuinely is none. An empty LIST is a real "no findings".
#   rc 75  the comments could not be read, or (BH-1992) the verdict-trust set
#          that decides whose comment is a brief is missing. THE CALLER MUST NOT TREAT THAT AS AN
#          EMPTY BRIEF (#783): with no findings, no conflict and no job log the
#          fix round drops straight to REBUILD FRESH, which closes the PR — so an
#          unreadable comments list would close a PR for being unreadable.
#          The review-verdict branch keeps BH-872's rc 0 because its terminal is
#          br_fix_terminal's ESCALATE, never a rebuild-fresh that closes the PR.
br_findings() {
  local url="${1:--}" reason="${2:-}" head="${3:-}" slug num f rc b64 authors rows lrc lead="" rest="" use_lead=0
  slug=$(br_slug_of_url "$url") || return 0
  num=$(mc_num_of_url "$url"); [ -n "$num" ] || return 0
  # A copy of this function lifted WITHOUT its BH-2200 helpers (a fixture that
  # extracts br_findings by name) answers exactly as it did before them. In the
  # lane itself they are defined in this same file, so the lead is always read.
  command -v br_review_rows >/dev/null 2>&1 && command -v br_lead_pick >/dev/null 2>&1 \
    && command -v br_findings_join >/dev/null 2>&1 && use_lead=1
  if [ "$use_lead" = 1 ] || [ "$reason" = review-changes-requested ]; then
    if [ -z "$head" ]; then
      head=$(gh api "repos/$slug/pulls/$num" --jq '.head.sha' 2>/dev/null) || head=""
    fi
    [ "$head" = null ] && head=""
  fi
  if [ "$use_lead" = 0 ]; then
    if [ "$reason" = review-changes-requested ]; then
      [ -n "$head" ] || return 0
      b64=$(br_review_newest "$slug" "$num" "$head") || return 0
      printf '%s' "$b64" | base64 -d 2>/dev/null
      return 0
    fi
  # THE LEAD'S FINDINGS, FOR EVERY REASON (BH-2200). A lead/human
  # CHANGES_REQUESTED standing on this head leads the brief, framed with
  # BR_LEAD_HDR. One reviews read, shared with the review-verdict branch below.
  # A read that failed is rc 75 on a park that is not the review lane's (the
  # caller retries, nothing spent); the review branch keeps its BH-872 rc 0.
  elif [ -n "$head" ]; then
    rc=0; rows=$(br_review_rows "$slug" "$num") || rc=$?
    if [ "$rc" != 0 ]; then
      [ "$reason" = review-changes-requested ] && return 0
      say "$url: the posted reviews are UNVERIFIABLE (the reviews list would not read) — no brief read this tick"
      return 75
    fi
    lrc=0; b64=$(br_lead_pick "$slug" "$head" "$rows") || lrc=$?
    case "$lrc" in
      0) lead=$(printf '%s' "$b64" | base64 -d 2>/dev/null) ;;
      2) say "$url: the lead review's standing is UNVERIFIABLE (a permission or compare read failed) — no brief read this tick"
         return 75 ;;
    esac
    if [ "$reason" = review-changes-requested ]; then
      b64=$(br_review_harness_pick "$head" "$rows") && rest=$(printf '%s' "$b64" | base64 -d 2>/dev/null)
      br_findings_join "$lead" "$rest"
      return 0
    fi
  elif [ "$reason" = review-changes-requested ]; then
    return 0
  else
    say "$url: the PR head would not read — the lead's findings cannot be checked, no brief read this tick"
    return 75
  fi
  # ONLY A VERDICT AUTHOR'S COMMENT IS A BRIEF (BH-1992). Anybody who can
  # comment on the PR can write "Head-bound", and the newest such comment used
  # to become the fix round's instructions. The trust set is bin/lib/gh-pr-list.sh's
  # HARNESS_VERDICT_AUTHORS; a box without it cannot tell a finding from an
  # injection, so it reads as unreadable (rc 75, nothing spent), never unfiltered.
  if ! command -v harness_verdict_authors_json >/dev/null 2>&1 \
     || ! authors=$(harness_verdict_authors_json 2>/dev/null) \
     || ! jq -e 'type == "array" and length > 0' >/dev/null 2>&1 <<<"$authors"; then
    say "$url: the posted findings are UNVERIFIABLE — the verdict-trust set (bin/lib/gh-pr-list.sh) is unavailable on this box, so no comment can be trusted as a brief this tick"
    return 75
  fi
  f=$(mktemp) || return 75
  gh_rest GET "repos/$slug/issues/$num/comments" -F per_page=100 > "$f" 2>/dev/null; rc=$?
  case "$rc" in
    0)  rest=$(jq -r --argjson a "$authors" '[.[]? | select((.user.login // "") as $u | any($a[]; . == $u))
          | select((.body // "") | test("[Hh]ead-bound"))] | last | .body // empty' "$f" 2>/dev/null) ;;
    44) rc=0 ;;   # no such PR: absent, which is genuinely no findings
    *)  rc=75
        say "$url: the posted findings are UNVERIFIABLE (HTTP $GH_REST_STATUS${GH_REST_REASON:+ $GH_REST_REASON}) — no brief read this tick" ;;
  esac
  rm -f "$f"
  if [ "$rc" = 0 ]; then
    if [ "$use_lead" = 1 ]; then br_findings_join "$lead" "$rest"
    elif [ -n "$rest" ]; then printf '%s\n' "$rest"; fi
  fi
  return "$rc"
}

# br_findings_join <lead> <rest> — the lead block first, the lane's findings
# after it, one blank line between; either may be empty.
br_findings_join() {
  if [ -n "${1:-}" ] && [ -n "${2:-}" ]; then printf '%s\n\n%s\n' "$1" "$2"
  elif [ -n "${1:-}" ]; then printf '%s\n' "$1"
  elif [ -n "${2:-}" ]; then printf '%s\n' "$2"
  fi
}

# br_fix_terminal <project> <rkey> <reason> <pr-url> <record> <ticket-key>
#   WHAT HAPPENS WHEN THE FIX ROUND IS NOT THE ANSWER (BH-872). Every exit
#   inside br_fix_round that used to call br_rebuild_fresh calls this instead,
#   and for every reason except the review verdict it IS br_rebuild_fresh —
#   byte for byte, same arguments, same rung.
#
#   A review verdict is the exception because rung 3 is the wrong shape for it:
#   closing the PR and rebuilding the TICKET answers "this branch cannot land"
#   and not "the reviewer wants three lines changed", and a hand-made harness PR
#   may have no ticket to rebuild at all. So its terminal is br_abandon
#   (BH-4149): the PR is closed with what was tried, one ABANDONED outcome is
#   recorded on the cap key, and the ticket is re-filed through the board. It
#   used to be an ESCALATED park that waited for a person to push, and nothing
#   in this harness waits on a person. A refused close returns 75 with nothing
#   recorded, and the next tick comes back here through the cap check or the
#   frozen-head gate in br_fix_round. A lead/human clearance standing on the
#   PR's head is asked first (br_review_cleared): that PR is the conductor's to
#   merge on the lead's verdict, so it is not closed.
br_fix_terminal() {
  if br_is_external "$1" "$(br_cap_key "$1" "$2" "${6:--}")" "${3:-}"; then
    command -v br_xpr_terminal >/dev/null 2>&1 && { br_xpr_terminal "$@"; return $?; }
    br_xpr_parked "$1/$2 [${3:-}]: external PR — never closed or rebuilt; left for the author"; return 3
  fi
  case "${3:-}" in
    review-changes-requested)
      br_review_cleared "$1" "$2" "$3" "$4" && return 0
      # BH-7123 wave B: at the cap, findings none of which is on the
      # ALWAYS-BLOCK floor merge with notes (br_cap_notes, rc 0 = handled this
      # tick); a standing floor line keeps today's abandon.
      br_cap_notes "$1" "$2" "$3" "$4" "$5" "${6:--}" && return 0
      br_abandon "$1" "$(br_cap_key "$1" "$2" "${6:--}")" "$3" "$4" "$5" \
        "the review findings outlasted the harness fix round(s) on this branch" "${6:--}" || true ;;
    *) br_rebuild_fresh "$@" ;;
  esac
}



# br_review_cleared <project> <rkey> <reason> <pr-url>
#   rc 0 the review terminal must NOT close this PR this tick (one line says
#   why): a lead/human MERGE or MERGE-WITH-NOTES stands on its current head, so
#   the conductor merges it on that verdict, or the head or the verdicts table
#   could not be read and nothing is closed on what nobody saw (retried next
#   tick). rc 1 nothing clears it, or this box has no verdict reader: close.
br_review_cleared() {
  local p="$1" rkey="$2" reason="$3" url="$4" slug num cur line rc
  command -v vd_standing >/dev/null 2>&1 || return 1
  [ -n "$url" ] && [ "$url" != "-" ] || return 1
  slug=$(br_slug_of_url "$url") || return 1
  num=$(mc_num_of_url "$url"); [ -n "$num" ] || return 1
  cur=$(br_pr_field "$url" '.head.sha' "pr head"); rc=$?
  if [ "$rc" != 0 ]; then
    say "$p/$rkey [$reason]: the PR's head could not be read (rc $rc) — nothing closed on a head nobody saw, retried next tick"
    return 0
  fi
  cur=$(printf '%s' "$cur" | tr 'A-F' 'a-f')
  line=$(vd_standing "$slug" "$num" "$cur"); rc=$?
  case "$rc" in
    0) case "$(cut -f1 <<<"$line")" in
         MERGE|MERGE-WITH-NOTES)
           say "$p/$rkey [$reason]: a $(cut -f2 <<<"$line") $(cut -f1 <<<"$line") stands on ${cur:0:12} — the lead cleared this head, so nothing is closed; the conductor merges on that verdict"
           return 0 ;;
       esac
       return 1 ;;
    1) return 1 ;;
    *) say "$p/$rkey [$reason]: the verdicts table could not be read for ${cur:0:12} — nothing closed while a lead clearance may stand there, retried next tick"
       return 0 ;;
  esac
}

# br_is_external <project> <cap-key> <reason> — rc 0 when this row is an
#   outsider's PR (BH-4664): an external-* reason, a gate that passed in this
#   process, or a record the external module stamped. br_set_field stores the
#   stamp as the string "true", so both spellings are read.
br_is_external() {
  case "${3:-}" in external-*) return 0 ;; esac
  [ "${BR_XPR_ACTIVE-}" = 1 ] && return 0
  br_load "$1" "$2" | jq -e '(.external // "" | tostring) == "true"' >/dev/null 2>&1
}

# br_xpr_parked <log line> — an outsider's PR was left for its author: nothing
#   closed, recorded or bought. Logs the line and sets BR_XPR_PARKED, so br_one
#   answers rc 3 (no PER_TICK slot) whatever rc the terminal's caller returns.
br_xpr_parked() { BR_XPR_PARKED=1; say "$1"; }

# br_fix_terminal_word <reason> — what the log line above each terminal exit
# must SAY is about to happen. D13: the sentence "REBUILD FRESH instead" is a
# lie on a park that abandons instead.
br_fix_terminal_word() {
  [ "${BR_XPR_ACTIVE-}" = 1 ] && { printf 'PARKED for the author instead'; return 0; }
  case "${1:-}" in
    external-*)               printf 'PARKED for the author instead' ;;
    # BH-7123 wave B: the review terminal decides between the two inside
    # br_fix_terminal (br_cap_notes), so the line names both, never one.
    review-changes-requested) printf 'merged with notes (no ALWAYS-BLOCK finding) or ABANDONED instead' ;;
    *)                        printf 'REBUILD FRESH instead' ;;
  esac
}

# br_xpr_wait_line <p> <rkey> <reason> <n> <cap> — on an external round that
#   ended without a push (BH-4668), while rounds remain, say what happens next:
#   nothing is closed and the next round is for the author's next head. At the
#   cap the terminal word above ("PARKED for the author") says it alone (D13).
br_xpr_wait_line() {
  [ "${BR_XPR_ACTIVE-}" = 1 ] && [ "$(($4 + 1))" -lt "$5" ] || return 0
  say "$1/$2 [$3]: external PR — nothing closed; the next round waits for the next head"
}

# br_fix_remote <project> <rkey> <reason> <url> <record> <tkey> <cap-key> <hotfix>
#   THE HUB'S FIX ROUND, QUEUED FOR THE BOX THAT OWNS THE PROJECT (BH-594,
#   BH-2674). The hub runs no agent build work (docs/HUB-THINNING-PLAN.md), and
#   since BH-393 its agent-call refuses the execute stage outright — so a fix
#   round the hub ran itself was a refusal. It writes ONE fix_round_jobs row
#   (bin/lib/fix-round-queue.sh) addressed to the owning box, carrying the six
#   --fix-here args and the hub's record. That box's bin/fix-round-claim.sh
#   claims the row, runs `blocked-resolver.sh --fix-here` there and finishes
#   the row with the round's FIX_RESULT and FIX_RECORD. A later tick's in-flight
#   gate in br_one reads the row and, once it is done, hands it to br_fix_adopt.
#   The hub keeps no pid row, temp file or lock for the round, so a hub restart
#   loses nothing that describes it.
#
#   THE HUB STAYS THE ONE WRITER OF THE RECORD: the box works on the copy in the
#   row, and only br_fix_adopt writes what comes back.
#
#   fix_round_enqueue's answer decides the one line this writes. None spends:
#     rc 0            queued: one resolver_rung event naming the box
#     rc 0 duplicate  a round for this park is already open: said, no event
#     rc 1            an outage, a 404, a 413 or no client: NOT queued, and the
#                     park is re-offered next tick (D9: never read as queued)
br_fix_remote() {
  local p="$1" rkey="$2" reason="$3" url="$4" rec="$5" tkey="$6" ck="$7" hot="${8:-0}"
  local box out rc=0 id st
  box=$("$H/bin/box-for.sh" "$p" 2>/dev/null)
  if [ -z "$box" ] || is_hub_box "$box"; then
    br_setup_blocked "$p" "$ck" "$rkey" "$reason" "$url" "no non-hub box owns $p in fleet.conf (box-for.sh answered '${box:--}') — the hub runs no agent build work" fix-round "$p owned by a non-hub box in fleet.conf that runs bin/fix-round-claim.sh and a bin/ with blocked-resolver.sh --fix-here"
    return 0
  fi
  if ! command -v fix_round_enqueue >/dev/null 2>&1; then
    say "$p/$rkey [$reason]: fix round NOT queued — bin/lib/fix-round-queue.sh is not on this box, nothing spent, re-offered next tick"
    # Harmless (nothing spent) but, with the ssh hop gone, it is the ONLY fix
    # round path: without a page every fix round of the project waits unseen.
    # One id per project, so alert-state sends it once.
    "$H/bin/lane-alert.sh" --id "fix-round-queue-missing-$p" blocked-resolver \
      "$p: fix rounds are not being queued — bin/lib/fix-round-queue.sh is not on the hub; every fix round for $p waits until it is synced" \
      >/dev/null 2>&1 || true
    return 0
  fi
  [ "$hot" = 1 ] || hot=0
  out=$(fix_round_enqueue "$p" "$ck" "$box" "$hot" "$(br_load "$p" "$ck")" "$p" "$rkey" "$reason" "$url" "$rec" "$tkey" 2>>"$LOG") || rc=$?
  if [ "$rc" != 0 ]; then
    say "$p/$rkey [$reason]: fix round NOT queued — jobs DB unreachable, re-offered next tick"
    return 0
  fi
  id=$(printf '%s' "$out" | jq -r '.id // "?"' 2>/dev/null)
  if [ "$(printf '%s' "$out" | jq -r '.duplicate // false' 2>/dev/null)" = true ]; then
    st=$(printf '%s' "$out" | jq -r '.status // "open"' 2>/dev/null)
    say "$p/$rkey [$reason]: a fix round is already in flight on $box (row $id, $st) — not queued again"
    return 0
  fi
  br_event resolver_rung "$p" "$ck" "$reason" "rung 2 fix-round queued for $box"
  say "$p/$rkey [$reason]: fix round queued for $box as row $id — its bin/fix-round-claim.sh runs it, and a later tick adopts the result"
  return 0
}

# br_fix_unclaimed <project> <rkey> <cap-key> <row-json> — NOTHING WAITS
#   SILENTLY (BH-2674). A queued row older than FIX_LANE_TIMEOUT means the
#   owning box's claimer is not taking its work: one page, keyed on the park, so
#   the --id alert-state (bin/lib/alert-state.sh) sends it once however many
#   ticks see it. An enqueued_at that does not parse is said and never read as
#   age 0 (D11).
br_fix_unclaimed() {
  local p="$1" rkey="$2" ck="$3" row="$4" box id enq at now
  case "$FIX_LANE_TIMEOUT" in ''|*[!0-9]*) return 0 ;; esac
  box=$(printf '%s' "$row" | jq -r '.box // "?"' 2>/dev/null)
  id=$(printf '%s' "$row" | jq -r '.id // "?"' 2>/dev/null)
  enq=$(printf '%s' "$row" | jq -r '.enqueued_at // ""' 2>/dev/null)
  at=""
  [ -n "$enq" ] && { at=$(date -u -d "$enq" +%s 2>/dev/null) || at=""; }
  if [ -z "$at" ]; then
    say "$p/$rkey: fix-round row $id's enqueued_at '$enq' does not parse — its age is unknown, no unclaimed page"
    return 0
  fi
  now=$(date -u +%s)
  [ $((now - at)) -gt "$FIX_LANE_TIMEOUT" ] || return 0
  "$H/bin/lane-alert.sh" --id "fix-round-unclaimed-$p-$ck" blocked-resolver \
    "$p/$rkey: fix-round row $id for $box has sat queued since $enq (over ${FIX_LANE_TIMEOUT}s) — bin/fix-round-claim.sh on $box has not claimed it; the park is held until it does" \
    >/dev/null 2>&1 || true
  return 0
}

# br_fix_stale_claim <project> <rkey> <cap-key> <row-json> — A DEAD BOX'S CLAIM
#   IS PAGED, NOT WAITED ON FOREVER (review F1 on #2872). The claim route
#   re-offers a stale `claimed` row only to the box that holds it, so a box
#   that died, was drained or was replaced mid-round leaves the row claimed
#   for good and br_one holds the park every tick. Past FIX_LANE_TIMEOUT +
#   FIX_HOP_MARGIN (the claimer's own stale bound; the box kills its round at
#   FIX_LANE_TIMEOUT) that is one page, keyed on the park so alert-state sends
#   it once. An updated_at that does not parse is said, never read as age 0.
br_fix_stale_claim() {
  local p="$1" rkey="$2" ck="$3" row="$4" box id up at now bound
  case "$FIX_LANE_TIMEOUT" in ''|*[!0-9]*) return 0 ;; esac
  case "$FIX_HOP_MARGIN" in ''|*[!0-9]*) return 0 ;; esac
  bound=$((FIX_LANE_TIMEOUT + FIX_HOP_MARGIN))
  box=$(printf '%s' "$row" | jq -r '.claimed_by // .box // "?"' 2>/dev/null)
  id=$(printf '%s' "$row" | jq -r '.id // "?"' 2>/dev/null)
  up=$(printf '%s' "$row" | jq -r '.updated_at // ""' 2>/dev/null)
  at=""
  [ -n "$up" ] && { at=$(date -u -d "$up" +%s 2>/dev/null) || at=""; }
  if [ -z "$at" ]; then
    say "$p/$rkey: fix-round row $id's updated_at '$up' does not parse — its claim age is unknown, no stale-claim page"
    return 0
  fi
  now=$(date -u +%s)
  [ $((now - at)) -gt "$bound" ] || return 0
  "$H/bin/lane-alert.sh" --id "fix-round-stale-claim-$p-$ck" blocked-resolver \
    "$p/$rkey: fix-round row $id claimed by $box since $up (over ${bound}s = BR_FIX_LANE_TIMEOUT + BR_FIX_HOP_MARGIN) with no result — the claim is re-offered only to $box, so if $box is gone the park is held until the row is released" \
    >/dev/null 2>&1 || true
  return 0
}

# br_fix_adopt <project> <rkey> <reason> <url> <record> <tkey> <cap-key> <row-json>
#   THE HUB TAKES A FINISHED ROUND'S RESULT, EXACTLY ONCE (BH-2674). br_one's
#   in-flight gate calls it for this park's row once the row is `done`. The
#   order is the point:
#     1. the record: record_out is saved only when it parses as a record for
#        this project AND holds more attempts than the hub's, so a second pass
#        over the same row saves nothing;
#     2. the CAS: fix_round_adopt moves the row done -> adopted, and only the
#        tick that wins it goes on. rc 9 is another tick's adopt; rc 1 is an
#        adopt not recorded, the row stays done and the next tick tries again;
#     3. the rung the box answered.
#   So a paid round takes its rung once. A crash before the CAS leaves a done
#   row the next tick re-adopts; a crash after it leaves a record that already
#   counts the attempt, and br_fix_round's cap takes the terminal from there.
br_fix_adopt() {
  local p="$1" rkey="$2" reason="$3" url="$4" rec="$5" tkey="$6" ck="$7" row="$8"
  local id box res ro rjson="" n0 n1="" what arc=0
  id=$(printf '%s' "$row" | jq -r '.id // empty' 2>/dev/null)
  box=$(printf '%s' "$row" | jq -r '.claimed_by // .box // "the owning box"' 2>/dev/null)
  res=$(printf '%s' "$row" | jq -r '.result // empty | strings' 2>/dev/null)
  ro=$(printf '%s' "$row" | jq -r '.record_out // empty | strings' 2>/dev/null)
  n0=$(br_load "$p" "$ck" | jq '(.attempts // []) | length' 2>/dev/null)
  if [ -n "$ro" ]; then
    rjson=$(printf '%s' "$ro" | jq -c --arg p "$p" 'select(.project == $p)' 2>/dev/null)
    [ -n "$rjson" ] || say "$p/$rkey [$reason]: the record $box sent back is not a record for $p — the hub's record is kept"
  fi
  [ -n "$rjson" ] && n1=$(printf '%s' "$rjson" | jq '(.attempts // []) | length' 2>/dev/null)
  if [ -n "$n1" ] && [ "$n1" -gt "${n0:-0}" ] 2>/dev/null; then
    br_save "$p" "$ck" "$rjson"
  fi
  fix_round_adopt "$id" >/dev/null 2>>"$LOG" || arc=$?
  case "$arc" in
    0) ;;
    9) say "$p/$rkey [$reason]: fix-round row $id was already adopted by another tick — nothing taken again"
       return 0 ;;
    *) say "$p/$rkey [$reason]: fix-round row $id: the adopt was not recorded — retried next tick, no rung taken"
       return 0 ;;
  esac
  case "$res" in
    "box-paused "*)
      what=$(printf '%s' "${res#box-paused }" | base64 -d 2>/dev/null)
      say "$p/$rkey [$reason]: $box is paused (${what:-no detail}) — the fix round did not run there, nothing spent, re-offered next tick" ;;
    done)
      if [ -z "$rjson" ]; then
        say "$p/$rkey [$reason]: fix round on $box answered done but sent no usable record — what it did is in $box's logs/blocked-resolver.log, and this record is unchanged"
      elif [ "${n1:-0}" -gt "${n0:-0}" ] 2>/dev/null; then
        rm -f "$ST/$p/$ck.setup-alerted" 2>/dev/null
        say "$p/$rkey [$reason]: fix round ran on $box: $(br_load "$p" "$ck" | jq -r '.attempts[-1].detail // "-"' 2>/dev/null)"
      else
        say "$p/$rkey [$reason]: fix round on $box recorded nothing new (its logs/blocked-resolver.log says why) — re-offered next tick"
      fi ;;
    "setup-blocked "*)
      what=$(printf '%s' "${res#setup-blocked }" | base64 -d 2>/dev/null)
      br_setup_blocked "$p" "$ck" "$rkey" "$reason" "$url" "on $box: ${what:-no detail}" fix-round "whatever the owning box $box names above, on $box" ;;
    terminal)
      rm -f "$ST/$p/$ck.setup-alerted" 2>/dev/null
      say "$p/$rkey [$reason]: the fix round on $box ended without a verified push — $(br_fix_terminal_word "$reason")"
      br_fix_terminal "$p" "$rkey" "$reason" "$url" "$rec" "$tkey" ;;
    rebuild-fresh)
      rm -f "$ST/$p/$ck.setup-alerted" 2>/dev/null
      say "$p/$rkey [$reason]: the fix round on $box asked for REBUILD FRESH"
      br_rebuild_fresh "$p" "$rkey" "$reason" "$url" "$rec" "$tkey" ;;
    *)
      say "$p/$rkey [$reason]: fix-round row $id on $box finished with a result this lane does not know ('$res') — adopted, no rung taken" ;;
  esac
  return 0
}

# >>> br fixround preflight (tests/fixround-preflight.bh-1794-test.sh drives this block)
# THE PR AS IT IS NOW, BEFORE ANY FIX ROUND SPENDS (BH-1794). project-3 #378 bought a
# second fix round and a second re-review only to refresh a PR-body Evidence
# block that still said head-red over a head whose CI was green: the round was
# briefed from the review record it was queued from, and the reviewer's token
# could not read check-runs. So br_fix_round asks this first, after it has read
# the head and the findings and before it touches git:
#   rereview  the findings were posted on an older sha, the head has moved and
#             its CI is green — the head is re-judged, no fix round;
#   wait      the head moved and its CI is not finished — nothing spent, the
#             park is offered again next tick;
#   skip      a red-CI park whose current head is green — nothing to fix;
#   evidence  every blocking finding is about the PR body's evidence and CI is
#             green — the live-CI block is written into the body (bash, no
#             model) and the head re-reviewed, no fix round;
#   fix       the round runs, and its prompt carries BR_PREFLIGHT_BRIEF: the
#             live head sha and the live check states with their run URLs.
# A re-review route is taken ONCE per (PR, head) — `preflight_heads` on the
# record — so a reviewer who still blocks the same head gets the fix round next
# tick instead of another re-review. Where the re-review comes from depends on
# the park: a review-lane verdict (review-changes-requested) is re-read by the
# project box's bin/review-prs.sh, which honours the `rereview-requested` marker
# in the refreshed body once per head; every other park is a conductor row and
# br_rereview buys the head-bound re-review directly.
# Every non-fix route writes one tick line and one resolver_preflight event row
# (br_event: the log line plus a fleet_event beat). A CI read that fails is
# `unreadable` in the brief, and a PR that cannot be read at all never reaches
# this function (br_fix_round retries it next tick).
# Knob: BR_FIXROUND_PREFLIGHT (default 1; 0 = every fix round runs exactly as
# before this existed).
#
# NOTHING WAITS FOR EVER (BH-1992). `wait` and `skip` are counted per head on
# the record (`preflight_wait_head/_n/_first`): after BR_PREFLIGHT_WAIT_MAX of
# them on one head (default 6; 0 = no cap) the round runs, and a head that has
# had no CI at all for BR_PREFLIGHT_NOCI_S (default 1800; 0 = off) since its
# first wait reads as `unreadable`, which is a round. A head that moves starts
# a new count, and a wait that cannot be recorded runs the round: an unrecorded
# wait is the same wait every tick.
# THE REVIEW LANE GETS ITS CADENCE (BH-1992). After a review-lane park's
# evidence/rereview route, the next ticks defer the round (nothing spent) until
# a verdict author has reviewed the head since the request, or
# BR_PREFLIGHT_DEFER_S (default 1800, one :07/:37 review-prs cadence; 0 = off)
# has passed since it (`preflight_route_at`).
# THE REQUEST IS A COMMENT (BH-1992). bin/review-prs.sh honours the re-review
# request only from a verdict author's PR comment; the body marker is for
# people. So the review-lane route posts one (br_pr_comment, the hub identity).
# A BODY WITH A BROKEN MARKER IS LEFT ALONE (BH-1992): frp_body_refresh rc 4
# sends nothing, and br_preflight_marker_alert pages once per PR.
BR_PREFLIGHT_BRIEF=""

# br_preflight_marker_alert <p> <ck> <url> — ONE alert per PR for a body whose
# live-CI begin marker has no end. Recorded first (`marker_alerted`), sent only
# when the record took it: a record that will not write sends nothing and the
# next tick tries again, never an alert every tick.
br_preflight_marker_alert() {
  local p="${1:-}" ck="${2:-}" url="${3:--}"
  if [ -z "$p" ] || [ -z "$ck" ]; then
    say "${url}: the PR body's live-CI begin marker has no end — the block was not written and the body was left alone (no park record to alert against)"
    return 0
  fi
  if br_has_field_value "$(br_load "$p" "$ck")" marker_alerted "$url"; then
    say "$p/$ck: the PR body's live-CI begin marker still has no end on $url — body left alone, already alerted"
    return 0
  fi
  if ! br_push_field "$p" "$ck" marker_alerted "$url"; then
    say "$p/$ck: the PR body's live-CI begin marker has no end on $url, and the alert could not be recorded on $(br_file "$p" "$ck") — not sent this tick"
    return 0
  fi
  say "$p/$ck: the PR body's live-CI begin marker has no end on $url — body left alone, alerted once"
  "$H/bin/lane-alert.sh" blocked-resolver "$p/$ck: PR $url body has a harness:live-ci begin marker with no end; the live-CI block was NOT written and the body was left alone. Fix the body by hand." >/dev/null 2>&1 || true
}

# br_review_after <slug> <num> <head> <epoch> — has a verdict author reviewed
# <head> since <epoch>? rc 0 yes, 1 no, 2 the list or the trust set could not
# be read (the caller does not defer on that: when in doubt the round runs).
br_review_after() {
  local slug="$1" num="$2" head="$3" since="$4" out login cid at
  command -v harness_verdict_author_match >/dev/null 2>&1 || return 2
  out=$(gh api "repos/$slug/pulls/$num/reviews" --paginate \
        --jq '.[] | [(.user.login // ""), (.commit_id // ""), ((.submitted_at // "") | (try fromdateiso8601 catch 0) | tostring)] | @tsv' 2>/dev/null) || return 2
  while IFS=$'\t' read -r login cid at; do
    [ "${cid:-}" = "$head" ] || continue
    case "${at:-}" in ''|*[!0-9]*) continue ;; esac
    [ "$at" -gt "$since" ] || continue
    harness_verdict_author_match "$login" && return 0
  done <<<"$out"
  return 1
}
br_preflight() { # br_preflight <p> <ck> <rkey> <reason> <url> <rec> <tkey> <slug> <head> <findings>
  local p="$1" ck="$2" rkey="$3" reason="$4" url="$5" rec="$6" tkey="$7" slug="$8" head="$9" findings="${10:-}"
  local num ci state fh dec act why rr brc st now wn wf wmax noci dfr ra age noci_note=""
  BR_PREFLIGHT_BRIEF=""
  case "${BR_FIXROUND_PREFLIGHT:-1}" in 0|off|false|no) return 0 ;; esac
  command -v frp_ci >/dev/null 2>&1 || return 0
  [ -n "$slug" ] && [ -n "$head" ] && [ "$head" != - ] || return 0
  num=$(mc_num_of_url "$url"); [ -n "$num" ] || return 0
  ci=$(frp_ci "$slug" "$head")
  state=$(jq -r '.state // "unreadable"' <<<"$ci" 2>/dev/null); [ -n "$state" ] || state=unreadable
  fh=$(frp_findings_head "$findings")
  now=$(date -u +%s)
  st=$(br_load "$p" "$ck")
  # The per-head wait count. Another head's count is not this one's.
  if [ "$(jq -r '.preflight_wait_head // ""' <<<"$st" 2>/dev/null)" = "$head" ]; then
    wn=$(br_num "$st" preflight_wait_n); wf=$(br_num "$st" preflight_wait_first)
    [ "$wf" -gt 0 ] || wf=$now
  else
    wn=0; wf=$now
  fi
  wmax="${BR_PREFLIGHT_WAIT_MAX:-6}"; case "$wmax" in ''|*[!0-9]*) wmax=6 ;; esac
  noci="${BR_PREFLIGHT_NOCI_S:-1800}"; case "$noci" in ''|*[!0-9]*) noci=1800 ;; esac
  if [ "$state" = none ] && [ "$noci" -gt 0 ] && [ $(( now - wf )) -ge "$noci" ]; then
    noci_note="no CI on ${head:0:8} after $(( (now - wf) / 60 )) minutes, read as unreadable"
    say "$p/$rkey [$reason]: preflight: $noci_note"
    state=unreadable
    ci=$(jq -c '.state = "unreadable"' <<<"$ci" 2>/dev/null) || ci='{"state":"unreadable"}'
  fi
  dec=$(frp_decide "$reason" "$head" "$fh" "$state" "$findings")
  act="${dec%%$'\t'*}"; why="${dec#*$'\t'}"
  case "$act" in
    rereview|evidence)
      if br_has_field_value "$st" preflight_heads "$head"; then
        # The review lane re-reads on its own cadence. Until it has answered on
        # this head, or one cadence has passed, a round here would be paid for
        # before the review it was routed to has even run.
        dfr="${BR_PREFLIGHT_DEFER_S:-1800}"; case "$dfr" in ''|*[!0-9]*) dfr=1800 ;; esac
        ra=$(br_num "$st" preflight_route_at); age=$(( now - ra ))
        if [ "$reason" = review-changes-requested ] && [ "$dfr" -gt 0 ] && [ "$ra" -gt 0 ] \
           && [ "$age" -ge 0 ] && [ "$age" -lt "$dfr" ]; then
          br_review_after "$slug" "$num" "$head" "$ra"
          if [ $? = 1 ]; then
            say "$p/$rkey [$reason]: deferring the fix round on ${head:0:8}: re-review requested $(( age / 60 )) min ago, review cadence not yet elapsed"
            br_event resolver_preflight "$p" "$ck" "$reason" "defer on ${head:0:8}: re-review requested $(( age / 60 )) min ago, no verdict-author review on it since"
            return 1
          fi
        fi
        say "$p/$rkey [$reason]: preflight already routed ${head:0:8} away from a fix round once ($act) and the park is still here — the fix round runs this time, from the live state"
        why="a $act route on this head already ran once"; act=fix
      elif ! br_push_field "$p" "$ck" preflight_heads "$head"; then
        say "$p/$rkey [$reason]: preflight could not record ${head:0:8} on $(br_file "$p" "$ck") — an unrecorded route repeats every tick, so the fix round runs instead"
        act=fix; why="the route could not be recorded"
      fi ;;
    wait|skip)
      if [ "$wmax" -gt 0 ] && [ $(( wn + 1 )) -gt "$wmax" ]; then
        say "$p/$rkey [$reason]: preflight answered $act on ${head:0:8} $wn times — the cap (BR_PREFLIGHT_WAIT_MAX=$wmax) is spent, so the fix round runs"
        why="waited $wn ticks on ${head:0:8}"; act=fix
      elif ! { br_set_field "$p" "$ck" preflight_wait_head "$head" \
               && br_set_num "$p" "$ck" preflight_wait_n $(( wn + 1 )) \
               && br_set_num "$p" "$ck" preflight_wait_first "$wf"; }; then
        say "$p/$rkey [$reason]: preflight could not record the $act on ${head:0:8} on $(br_file "$p" "$ck") — an unrecorded wait repeats every tick, so the fix round runs instead"
        why="the $act could not be recorded"; act=fix
      fi ;;
  esac
  case "$act" in
    wait|skip)
      say "$p/$rkey [$reason]: preflight: no fix round on ${head:0:8} — $why"
      br_event resolver_preflight "$p" "$ck" "$reason" "$act on ${head:0:8}: $why"
      return 1 ;;
    rereview|evidence)
      rr=""; [ "$reason" = review-changes-requested ] && rr="$head"
      frp_body_refresh "$slug" "$num" "$ci" "$rr"; brc=$?
      [ "$brc" = 4 ] && br_preflight_marker_alert "$p" "$ck" "$url"
      if [ "$reason" = review-changes-requested ]; then
        # The review lane lives on the project box and honours a request only
        # from a verdict author's PR comment. A body that would not take the
        # block, or a comment that would not post, leaves the verdict standing
        # with nobody asked, so the round runs instead.
        if [ "$brc" = 0 ] || [ "$brc" = 3 ]; then
          if br_pr_comment "$url" "The harness fix-round preflight asks for one more review of ${head:0:12}: $why. The live CI for this head is in the PR body.

<!-- $FRP_RR_TAG $head -->"; then
            br_set_num "$p" "$ck" preflight_route_at "$now" \
              || say "$p/$rkey [$reason]: the re-review request time could not be recorded — the next tick will not defer for it"
            say "$p/$rkey [$reason]: preflight: no fix round on ${head:0:8} — $why; live-CI block written and re-review requested in a PR comment"
            br_event resolver_preflight "$p" "$ck" "$reason" "$act on ${head:0:8}: $why"
            return 1
          fi
          say "$p/$rkey [$reason]: preflight wanted a re-review of ${head:0:8} ($act) but the request comment would not post — the fix round runs instead"
        else
          say "$p/$rkey [$reason]: preflight wanted a re-review of ${head:0:8} ($act) but the PR body would not take the live-CI block (rc $brc) — the fix round runs instead"
        fi
        why="the re-review request could not be written"
      else
        say "$p/$rkey [$reason]: preflight: no fix round on ${head:0:8} — $why; buying the head-bound re-review (body refresh rc $brc)"
        br_event resolver_preflight "$p" "$ck" "$reason" "$act on ${head:0:8}: $why"
        br_rereview "$p" "$rkey" "$reason" "$url" "$rec" "$tkey" preflight
        return 1
      fi ;;
  esac
  # THE ROUND RUNS. The body is brought up to date first (a failure costs the
  # round nothing), and the brief carries the live state.
  frp_body_refresh "$slug" "$num" "$ci" "" >/dev/null 2>&1; brc=$?
  [ "$brc" = 4 ] && br_preflight_marker_alert "$p" "$ck" "$url"
  BR_PREFLIGHT_BRIEF=$(frp_brief "$ci" "$head" "$fh")
  [ -n "$noci_note" ] && BR_PREFLIGHT_BRIEF="$BR_PREFLIGHT_BRIEF
- $noci_note: no workflow run or check-run has appeared on this head since the harness first waited on it"
  br_event resolver_preflight "$p" "$ck" "$reason" "fix on ${head:0:8}: $why"
  return 0
}

# br_preflight_after_push <slug> <pr-url> <new-head> [<p> <ck>] — after a fix
# round pushes, the PR body's live-CI block names the NEW head and what GitHub
# reports for it (usually `none` or `pending` this soon), so no reviewer reads
# the old head's result as this one's. Bash only, fail-open, one log line; a
# body with a broken marker is left alone and alerted once per PR when the park
# (<p> <ck>) is named.
br_preflight_after_push() {
  local slug="${1:-}" url="${2:-}" nh="${3:-}" p="${4:-}" ck="${5:-}" num ci brc
  case "${BR_FIXROUND_PREFLIGHT:-1}" in 0|off|false|no) return 0 ;; esac
  command -v frp_ci >/dev/null 2>&1 || return 0
  [ -n "$slug" ] && [ -n "$nh" ] || return 0
  num=$(mc_num_of_url "$url"); [ -n "$num" ] || return 0
  ci=$(frp_ci "$slug" "$nh")
  frp_body_refresh "$slug" "$num" "$ci" ""; brc=$?
  say "$slug#$num: live-CI block refreshed for the pushed head ${nh:0:8} (CI $(jq -r '.state // "?"' <<<"$ci" 2>/dev/null), body rc $brc)"
  [ "$brc" = 4 ] && br_preflight_marker_alert "$p" "$ck" "$url"
  return 0
}
# <<< br fixround preflight

# br_prequeue_brief <raw-park-reason> — the brief paragraph for a prequeue-red
#   round (BH-4549). PURE. The raw reason is the pre-queue gate's park text:
#   `prequeue-red: <suites> on main <m12> — …` (bin/merge-conductor.sh) or
#   `prequeue-red: <suites> (reproduced alone on <base12>, batch #n)` (the
#   batch-solo slice). It NEVER prints an empty string: a reason it cannot
#   parse (the row moved on, the record has no copy) gets one line that names
#   no suite and no sha, so the round still runs rather than dropping to
#   REBUILD FRESH on a failed read, and nothing is invented (D11).
br_prequeue_brief() {
  local raw="${1:-}" body="" suites="" sha=""
  case "$raw" in "prequeue-red: "*) body="${raw#prequeue-red: }" ;; esac
  if [ -n "$body" ] && [[ "$body" =~ (" on main "|" (reproduced alone on ")([0-9a-f]{7,40}) ]]; then
    sha="${BASH_REMATCH[2]}"
    suites="${body%% on main *}"; suites="${suites%% (reproduced alone on *}"
  fi
  if [ -n "$sha" ] && [ -n "$suites" ]; then
    printf 'THE PRE-QUEUE GATE PARKED THIS HEAD (the harness park reads: %s).\n' "$raw"
    printf 'These suites fail when this head is merged onto current main %s: %s. Merge origin/main and make them pass; run `bin/test-impact-gate.sh --base origin/main`.' "$sha" "$suites"
    case "$raw" in *" — invariant:"*) printf ' These are whole-repo invariant suites from catalog/prequeue-invariants.tsv, and the PR'"'"'s pre-queue comment carries their first FAIL lines.' ;; esac
  else
    printf 'This head was parked prequeue-red: its suites fail when it is merged onto current main, and the park'"'"'s suite list could not be re-read here. Merge origin/main, run `bin/test-impact-gate.sh --base origin/main` and make every suite it selects pass.'
  fi
}

# br_prequeue_note <project> <cap-key> <url> — copy the conductor row's raw
#   prequeue-red reason onto the resolver record as `.prequeue_reason`
#   (BH-4549). The fix round only sees the normalized word, and on the hub it
#   hops to the owning box with a COPY of the record and no pr-state.tsv, so
#   the suites and the sha have to ride on the record (the `.dequeue.brief`
#   precedent). Only a row that still reads prequeue-red is copied; any failed
#   read writes nothing, and the round falls back to br_prequeue_brief's line.
br_prequeue_note() {
  local slug num why
  command -v mc_row_field >/dev/null 2>&1 || return 0
  slug=$(br_slug_of_url "${3:-}") || return 0
  num=$(mc_num_of_url "${3:-}" 2>/dev/null); [ -n "$num" ] || return 0
  why=$(mc_row_field "$slug#$num" 7 2>/dev/null)
  case "$why" in prequeue-red*) br_set_field "$1" "$2" prequeue_reason "$why" ;; esac
  return 0
}

# br_directive <project> <ticket-key> <record> — THE TICKET'S NEWEST WORD FROM A
# PRINCIPAL, FOR THE FIX ROUND'S BRIEF (BH-5125). On 2026-10-07 the operator narrowed
# BH-5022's fix on the ticket ("what the AGENT fix round should do") and the
# round's brief never read the ticket: it is built from the review findings, the
# conflict, the CI log and the dequeue/prequeue brief only. So the newest comment
# a principal wrote (pr_fetch_thread's `principal`; never one of our own
# (`harness`), never a `[bot]` login) rides at the end of the brief, capped at
# BR_DIRECTIVE_MAX_CHARS (0 = off) and wrapped as untrusted ticket text.
#   rc 0  the DIRECTIVE paragraph on stdout
#   rc 1  the thread (or the ticket id) could not be read — the round runs
#         without one, and the caller says so
#   rc 2  nothing to add: the knob is 0, no ticket key, no board this can read,
#         the libs are absent, or no principal has commented
br_directive() {
  local p="$1" tkey="${2:--}" rec="${3:--}" cap tid trc th c author at body
  cap="${BR_DIRECTIVE_MAX_CHARS:-4000}"
  case "$cap" in ''|*[!0-9]*) cap=4000 ;; esac
  [ "$cap" -gt 0 ] || return 2
  case "$tkey" in ''|-) return 2 ;; esac
  command -v pr_fetch_thread >/dev/null 2>&1 && command -v ui_wrap >/dev/null 2>&1 || return 2
  trc=0; tid=$(br_ticket_id "$p" "$tkey" "$rec") || trc=$?
  case "$trc" in 0) ;; 2) return 2 ;; *) return 1 ;; esac
  trc=0; th=$(pr_fetch_thread "$p" "$tid" "$tkey") || trc=$?
  case "$trc" in 0) ;; 3) return 2 ;; *) return 1 ;; esac
  c=$(printf '%s' "$th" | jq -c '[ (.comments // [])[]
        | select(.principal == true and (.harness == true | not)
                 and ((.author // "") | tostring | ascii_downcase | endswith("[bot]") | not)) ]
        | sort_by(.createdAt // "") | last // empty' 2>/dev/null) || return 1
  [ -n "$c" ] || return 2
  author=$(printf '%s' "$c" | jq -r '.author // "" | tostring')
  at=$(printf '%s' "$c" | jq -r '.createdAt // "" | tostring')
  body=$(printf '%s' "$c" | jq -r '.body // "" | tostring')
  [ -n "${body//[[:space:]]/}" ] || return 2
  [ "${#body}" -gt "$cap" ] && body="${body:0:$cap}"$'\n'"[…truncated at $cap chars]"
  printf 'DIRECTIVE — the newest comment from a project principal on %s (%s, %s). It is direction for THIS round: apply it where it bears on the brief above. Where it conflicts with a finding, follow the finding and say why in the commit message.\n' \
    "$tkey" "${author:-unknown}" "${at:-unknown time}"
  printf '%s' "$body" | ui_wrap ticket-thread
}

# br_archie_first <project> <rkey> <reason> <url> <cap-key> — rc 1 when Archie
#   (bin/archie-fm.sh, rebase-repair) is still working this park's head, so the
#   round is offered again next tick with nothing spent; rc 0 otherwise. Its
#   diagnosis, when it has one, is copied onto the record as
#   `.archie_diagnosis` with the head it is about (`.archie_diagnosis_head`):
#   on the hub the round hops to the owning box with a COPY of the record and no
#   pr-state.tsv (the br_prequeue_note precedent), and the brief below reads it
#   back only for that same head. Bounded by archie.fm.first_s (afm_first), and
#   fail-open: anything unreadable is rc 0 and today's round.
br_archie_first() {
  local p="$1" rkey="$2" reason="$3" url="$4" ck="$5" slug num head diag rc=0
  command -v afm_first >/dev/null 2>&1 && command -v mc_row_field >/dev/null 2>&1 || return 0
  slug=$(br_slug_of_url "$url" 2>/dev/null) || return 0
  num=$(mc_num_of_url "$url" 2>/dev/null); [ -n "$num" ] || return 0
  head=$(mc_row_field "$slug#$num" 4 2>/dev/null)
  diag=$(afm_first "$p" "$slug" "$num" "$head" 2>/dev/null) || rc=$?
  case "$rc" in
    3) say "$p/$rkey [$reason]: Archie (archie-fm) is working head ${head:0:8} first; offered again next tick"
       return 1 ;;
    0) [ -n "$diag" ] && br_set_field "$p" "$ck" archie_diagnosis "$diag" \
         && br_set_field "$p" "$ck" archie_diagnosis_head "$head"
       say "$p/$rkey [$reason]: Archie's rebase-repair could not finish head ${head:0:8}; its diagnosis goes in the fix round's brief" ;;
  esac
  return 0
}

# FIX ROUND — RUNG 2, AND THE DEFAULT ANSWER TO A BRANCH THAT CAN STILL BE FIXED
# (2026-09-15). One execute-stage agent call, in a throwaway worktree of the PR
# branch, with the verification IN THE FOREGROUND — the push happens only if the
# repo's own typecheck and unit suite pass on the merged tree. A fix round that
# pushes unverified code is worse than no fix round: it costs the PR its approval
# and buys a red CI run.
#
# THE BRIEF IS WHATEVER EVIDENCE EXISTS, not review findings alone. Requiring
# posted findings is what made this rung unreachable for the two commonest parks
# in the log — a rebase conflict has no findings and a red CI run has none
# either — so the brief is assembled from three sources and the rung runs when
# ANY of them says something:
#   * the head-bound reviewer's posted findings (a review-blocked park);
#   * the conflict `origin/main` leaves in the tree, markers and all, LEFT IN
#     PLACE for the agent to resolve rather than aborted away;
#   * the failing job's log (br_ci_log), which is what a red CI park is about.
# With none of the three there is genuinely nothing to brief an agent with, and
# only then does this drop to REBUILD FRESH.
#
# A SETUP FAILURE IS NOT A FAILED FIX ROUND (2026-09-16). Everything that stops
# this rung before the agent runs — no repo/branch, no local clone, an
# unresolvable origin ref, a failed worktree add — goes to br_setup_blocked:
# no counter, no rebuild, no close, one alert, retried next tick. Only the agent
# having run and not produced a verified commit, a push the lease rejected, or a
# spent fix-round cap reaches REBUILD FRESH.
#
# A CHECKPOINT BRANCH IS REUSED. A round killed mid-flight (a lane timeout, a
# box reboot) leaves its work on `brfix/<ticket>`; starting again from the PR
# head would throw that away and buy the same tokens twice. The branch is taken
# as the starting tree whenever it still contains the PR head, and the push
# lease is the PR head either way.
br_fix_round() {
  local p="$1" rkey="$2" reason="$3" url="$4" rec="$5" tkey="$6"
  local ck st n cap slug br wt findings prompt rc out cilog="" lease head brief conflicts markers f ref gsv gsrc gsnot
  local reuse=0 oldwt frc=0 br_next_judge dqbrief pqbrief="" archie="" ejruns=""
  local lead_blocked=0 unaddr="" noop_named noop_own noop_hit noop_n noop_f
  local gienv=() gibad="" girc=0 br_author_bad=0
  local hot=0 slots=0 reserve=0 running=0 directive="" drc=0
  local frcl_w="" frcl_dir=""
  local mref=main pbase=""
  local cok="" cfail="" clines cbytes cbase cdiff cplan cplan_show cpaths=()
  ck=$(br_cap_key "$p" "$rkey" "$tkey")
  st=$(br_load "$p" "$ck"); n=$(br_num "$st" fixrounds)
  n=$(br_cap_rows "$p" "$rkey" "$reason" "$n" "$url" fixround fixrounds)
  # THE CAP IS THE TICKET'S, not the file's (BH-579): a small conflict buys two
  # rounds, a contested winner one more. br_one chose this rung from the same
  # br_fix_cap, so the rung chosen and the rung that runs always agree. THE
  # REASON RIDES ALONG SINCE BH-872: a review verdict is worth
  # BR_REVIEW_FIX_ROUNDS rounds whatever the record's conflict shape says, and
  # every other reason reads exactly the shape-driven cap it read before. A
  # missing or unusable answer falls back to today's single round rather than to
  # zero or to unbounded — the same shape br_num uses on every number this lane
  # reads.
  cap=$(br_fix_cap "$st" "$reason" "$p" 2>/dev/null)
  case "$cap" in ''|*[!0-9]*) cap="${MAX_FIXROUNDS:-${BR_MAX_FIXROUNDS:-1}}" ;; esac
  if [ "$n" -ge "$cap" ]; then
    say "$p/$rkey [$reason]: the fix round already ran $n time(s) of $cap — $(br_fix_terminal_word "$reason")"
    br_fix_terminal "$p" "$rkey" "$reason" "$url" "$rec" "$tkey"; return 0
  fi
  if [ "$OBSERVE" = 1 ]; then say "$p/$rkey [$reason]: WOULD run a fix round — observe mode"; return 0; fi
  # ARCHIE FIRST (BH-4585), on the hub only: a box running a hopped round
  # (--fix-here) has no pr-state.tsv and reads the diagnosis off the record. A
  # lifted copy of this function without br_archie_first runs as before.
  if [ "${BR_FIX_HERE:-0}" != 1 ] && command -v br_archie_first >/dev/null 2>&1 \
     && ! br_archie_first "$p" "$rkey" "$reason" "$url" "$ck"; then return 0; fi
  # THE SLOT GATE (#643 fix 2). A refusal here SPENDS NOTHING: no counter, no
  # attempt row, no state write, no rebuild, no close — the park is re-offered
  # on the next */10 tick, which is why it sits before any git or gh work and
  # after the MAX_FIXROUNDS check (a spent cap still drops to REBUILD FRESH).
  #
  # The count is not locked, on purpose: two overlapping ticks can each admit a
  # round against the same free slot, so the effective ceiling is
  # BR_FIX_SLOTS + (concurrent ticks - 1) in the worst case. This is a throttle,
  # not a correctness barrier, and a lock held across an admission is the queue
  # shape the fleet does not do (the operator, 2026-09-13: "we never lock and serialize").
  hot=0
  if command -v priority_rank_meta >/dev/null 2>&1 && [ "${rec:--}" != - ] \
     && [ "$(priority_rank_meta "$rec/ticket-meta.json" "$H")" = 0 ]; then hot=1; fi
  if command -v sched_num >/dev/null 2>&1; then
    slots=$(sched_num BR_FIX_SLOTS 0 "$H")
    if [ "$slots" -gt 0 ]; then
      reserve=$(sched_num BR_HOTFIX_RESERVE 1 "$H")
      # A reserve at or above the cap would starve plain work for ever, so it is
      # clamped to leave one slot a plain round can always take.
      [ "$reserve" -lt "$slots" ] || reserve=$((slots - 1))
      running=$(br_rounds_running)
      if [ "$hot" = 1 ]; then
        if [ "$running" -ge "$slots" ]; then
          # Every slot held by PLAIN work: ask the oldest of them to yield and
          # come back next tick. Nothing here waits on that round.
          if br_yield_request "$ck"; then
            say "$p/$rkey [$reason]: $running of $slots slots busy and this park is a hotfix — asked the oldest plain round to yield, re-offered next tick"
          else
            say "$p/$rkey [$reason]: deferred: $running of $slots slots busy, $reserve reserved for hotfix — re-offered next tick"
          fi
          return 0
        fi
      elif [ "$running" -ge "$((slots - reserve))" ]; then
        say "$p/$rkey [$reason]: deferred: $running of $slots slots busy, $reserve reserved for hotfix — re-offered next tick"
        return 0
      fi
    fi
  fi
  # THE HUB QUEUES IT (BH-594, BH-2674). Everything above — the cap, observe
  # mode, the slot gate — is admission and stays on the hub; everything below
  # is the round itself, and the hub runs no agent build work. The owning box
  # claims the queued row and runs it (br_fix_remote).
  # Written to survive being lifted out of this file on its own (the suites that
  # drive br_fix_round verbatim): no identity lib means the round runs here.
  # A prequeue-red park's raw reason goes onto the record FIRST (BH-4549), so
  # the copy br_fix_remote hands the owning box carries the suites and the sha.
  [ "$(br_ladder_class "$reason")" = prequeue-red ] && br_prequeue_note "$p" "$ck" "$url"
  if [ "${BR_FIX_HERE:-0}" != 1 ] && command -v hub_box_builds_here >/dev/null 2>&1 \
     && ! hub_box_builds_here; then
    br_fix_remote "$p" "$rkey" "$reason" "$url" "$rec" "$tkey" "$ck" "$hot"
    return 0
  fi
  slug=$("$H/bin/fleet-conf.sh" "$p" repo 2>/dev/null)
  # THE PR URL IS THE SLUG, and the branch is in it too (#508). fleet-conf is
  # asked first — it is the project's own answer — and the URL is the fallback,
  # re-read under the repo's own token, exactly as the mechanical rung does it.
  [ -n "$slug" ] || slug=$(br_slug_of_url "$url") || slug=""
  br=""; head=""
  if [ -n "$url" ] && [ "$url" != "-" ]; then
    # Assigned only on success: a failed read must not clobber fleet-conf's slug.
    ref=$(br_pr_ref "$url" "$slug"); rc=$?
    # Same rc 2 as rung 1, and for the same reason: a PR this lane could not READ
    # must never be closed and rebuilt. That is exactly what threw away project-5
    # #1677/#1694/#1696 on 2026-09-16.
    if [ "$rc" = 2 ]; then
      say "$p/$rkey [$reason]: PR read FAILED (${ref:-no detail}) — retrying next tick, no rung spent"
      return 0
    fi
    [ "$rc" = 0 ] && read -r slug br head <<<"$ref"
    # The head this rung read is the head this lane now knows the PR on (BH-1642).
    [ "$rc" = 0 ] && br_sup_seen "$p" "$ck" "$url" "$head"
    [ -n "${slug:-}" ] && br_use_token "$slug"
  fi
  # A HEAD THAT ENDED fix-round-noop IS NOT RUN AGAIN (BH-2200). It sits after
  # the one PR-ref read above but BEFORE the findings (reviews, compare,
  # permission) are read. On the hub this point is never reached: the round
  # went to br_fix_remote above, the owning box's copy of this gate fires there,
  # and br_fix_adopt runs br_fix_terminal on a later hub tick. noop_heads is only written by the lead gate below. The round on
  # this head is spent, so the park goes to its terminal (BH-4149) instead of
  # waiting for a person to push: br_rebuild_fresh for a ladder reason (whose
  # supersede guard does not decline on the lead's BLOCK on a frozen head, so it
  # rebuilds or, at its cap, ends ABANDONED), br_abandon for a review verdict.
  # It sits ABOVE the (PR, head) dedupe below,
  # because a frozen review head is in review_fix_heads too and that dedupe
  # would return before it. A terminal a refused close deferred comes back here.
  if [ -n "${head:-}" ] && br_has_field_value "$st" noop_heads "$head"; then
    say "$p/$rkey [$reason]: fix-round-noop already stands on ${head:0:8} (the last round answered none of the lead's findings) — not run again, $(br_fix_terminal_word "$reason")"
    br_fix_terminal "$p" "$rkey" "$reason" "$url" "$rec" "$tkey"; return 0
  fi
  # ONE ROUND PER (PR, HEAD) FOR A REVIEW VERDICT (BH-872). The review lane
  # re-reads GitHub every half hour and the same standing verdict is a candidate
  # on every tick, so without this key the same head would buy an execute call
  # every ten minutes. Asked here, where the head is the one the PR ACTUALLY has
  # (never the one discovery saw) and before anything expensive has been set up.
  if [ "$reason" = review-changes-requested ]; then
    if [ -z "${head:-}" ]; then
      say "$p/$rkey [$reason]: no head sha could be read for ${url:--} — a round keyed on (PR, head) cannot run without one; retried next tick, no rung spent"
      return 0
    fi
    if br_has_field_value "$st" review_fix_heads "$head"; then
      say "$p/$rkey [$reason]: fix round already ran on ${head:0:8} — the verdict is standing, not new; nothing spent"
      return 0
    fi
  fi
  # SETUP, NOT AN EVENT (see br_setup_blocked): no repo and no branch even after
  # the URL and the repo's own token were both tried, and no local clone to work
  # in. Each of these means the rung never ran, so none of them escalates — the
  # derivation above is what tells the two apart, because before it a park whose
  # branch WAS readable went down this path too.
  [ -n "$slug" ] && [ -n "${br:-}" ] || { br_setup_blocked "$p" "$ck" "$rkey" "$reason" "$url" "no repo/branch could be resolved for ${url:--} even after re-reading it under ${slug:-no repo}'s own token (fleet.conf repo='${slug:--}', gh headRefName='${br:--}')"; return 0; }
  [ -d "$REPOS/$p/.git" ] || { br_setup_blocked "$p" "$ck" "$rkey" "$reason" "$url" "there is no local clone at $REPOS/$p for the fix round to work in"; return 0; }
  # BEFORE the credential, the fetch and the worktree, so there is nothing to
  # clean up: a findings list GitHub would not hand over is an unknown, and an
  # unknown read as an empty brief drops this rung to REBUILD FRESH below.
  findings=$(br_findings "$url" "$reason" "${head:-}"); frc=$?
  # A DEQUEUE BRIEF (BH-3728). The dequeue-watch lane (BH-3719) sends reason
  # queue-dequeued with record_in.dequeue.brief: the failing suite, its FAIL
  # lines and the class hint. It is not a hub park, so there are no posted
  # findings to read; the brief leads whatever there is, and a round that has
  # one is not held back by an unreadable review read.
  if [ "$reason" = queue-dequeued ]; then
    dqbrief=$(printf '%s' "$st" | jq -r '.dequeue.brief // empty' 2>/dev/null)
    [ -n "$dqbrief" ] && { findings=$(br_findings_join "$dqbrief" "$findings"); frc=0; }
  fi
  if [ "$frc" = 75 ]; then
    say "$p/$rkey [$reason]: the posted findings could not be read this tick — fix round not started, no rung spent, retried next tick"
    return 0
  fi
  # A REVIEW PARK WITH NO READABLE VERDICT IS NOT AN ESCALATION. The candidate
  # existed because the verdict WAS read a moment ago, so an empty answer here is
  # a failed read or a head that moved under us — neither is a fact about the PR
  # worth spending a rung or a person on (D11). Next tick asks again; if the
  # verdict is genuinely gone, discovery stops offering it.
  if [ "$reason" = review-changes-requested ] && [ -z "$findings" ]; then
    say "$p/$rkey [$reason]: the review verdict on ${head:0:8} would not re-read — no rung spent, nothing escalated, retried next tick"
    return 0
  fi
  # A LEAD-BLOCKED ROUND (BH-2200): the brief carries a lead's or a human's
  # CHANGES_REQUESTED. An empty header would match every brief, so a lifted copy
  # of this function with no BR_LEAD_HDR has no lead gate rather than a gate on
  # everything.
  [ -n "${BR_LEAD_HDR:-}" ] && case "$findings" in *"$BR_LEAD_HDR"*) lead_blocked=1 ;; esac
  # THE PREFLIGHT (BH-1794): the PR's live head, CI and findings decide whether
  # a round is the answer at all. rc 1 = routed or waiting, nothing spent here.
  # Fail-open like its lib: a caller that lifted this function without the
  # preflight block runs the round exactly as before.
  BR_PREFLIGHT_BRIEF=""
  if command -v br_preflight >/dev/null 2>&1 \
     && ! br_preflight "$p" "$ck" "$rkey" "$reason" "$url" "$rec" "$tkey" "$slug" "${head:-}" "$findings"; then
    return 0
  fi
  case "$(git -C "$REPOS/$p" remote get-url origin 2>/dev/null)" in
    https://*) mc_git_auth "$slug" >/dev/null 2>&1 || say "$p/$rkey: no git credential for $slug — the push will probably fail" ;;
  esac
  git -C "$REPOS/$p" fetch -q origin 2>/dev/null
  # THE LEASE IS THE PR HEAD, read from the fetch we just did — never the HEAD of
  # the tree we start from, which on a reused checkpoint is already ahead of it.
  # --verify -q, NOT a bare rev-parse: a bare one ECHOES the ref it could not
  # resolve ("origin/ticket/TK-93") and exits 128, so `lease` came back non-empty
  # for a branch this clone has never seen — the guard below could never fire and
  # that string went on to be the --force-with-lease value.
  lease=$(git -C "$REPOS/$p" rev-parse --verify -q "origin/$br" 2>/dev/null)
  [ -n "$lease" ] || lease="$head"
  [ -n "$lease" ] || { mc_git_auth_clear 2>/dev/null; br_setup_blocked "$p" "$ck" "$rkey" "$reason" "$url" "origin/$br will not resolve in $REPOS/$p (the fetch did not run, or the credential cannot read $slug)"; return 0; }
  git -C "$REPOS/$p" worktree prune >/dev/null 2>&1
  if git -C "$REPOS/$p" rev-parse --verify -q "brfix/$ck" >/dev/null 2>&1 \
     && git -C "$REPOS/$p" merge-base --is-ancestor "$lease" "brfix/$ck" >/dev/null 2>&1; then
    reuse=1
    oldwt=$(git -C "$REPOS/$p" worktree list --porcelain 2>/dev/null \
            | awk -v b="refs/heads/brfix/$ck" '$1=="worktree"{w=$2} $1=="branch" && $2==b {print w; exit}')
    [ -n "$oldwt" ] && br_wt_drop "an earlier round left it registered on brfix/$ck" "$REPOS/$p" "$oldwt"
  fi
  # ON DISK, NOT tmpfs (2026-09-16). /tmp on the hub is a tmpfs sized at half
  # of RAM; three of these worktrees (1.7GB each, node_modules included) filled
  # it to 99% and every lane that wanted a temp file failed. The scratch lives
  # under the harness tree, which is the 100GB root disk.
  mkdir -p "$H/tmp/brfix"
  wt=$(mktemp -d "$H/tmp/brfix/brfix-XXXX"); rmdir "$wt"
  # OWNED FROM HERE (BH-1363), before the worktree add rather than after it: a
  # half-created tree costs the same gigabytes as a finished one.
  BR_FIX_WT="$wt"; BR_FIX_REPO="$REPOS/$p"
  if [ "$reuse" = 1 ] && git -C "$REPOS/$p" worktree add -q "$wt" "brfix/$ck" 2>>"$LOG"; then
    say "$p/$rkey [$reason]: reusing the checkpoint branch brfix/$ck left by an earlier round ($(git -C "$wt" rev-parse --short HEAD))"
  elif ! git -C "$REPOS/$p" worktree add -q "$wt" -B "brfix/$ck" "origin/$br" 2>>"$LOG"; then
    mc_git_auth_clear 2>/dev/null
    br_setup_blocked "$p" "$ck" "$rkey" "$reason" "$url" "worktree add failed for origin/$br in $REPOS/$p — see the git error in logs/blocked-resolver.log"
    return 0
  fi
  # THE ROUND COMMITS AS THE BOX'S CONFIGURED AUTHOR (BH-1134): the harness's own
  # merge below and the agent session both run under the GIT_AUTHOR_*/
  # GIT_COMMITTER_* pin, which beats user.* config and `git -c`. Only an explicit
  # --author gets past it, and the check before the push refuses that.
  if command -v gi_resolve >/dev/null 2>&1; then
    gi_resolve
    gienv=(GIT_AUTHOR_NAME="$GI_NAME" GIT_AUTHOR_EMAIL="$GI_EMAIL" GIT_COMMITTER_NAME="$GI_NAME" GIT_COMMITTER_EMAIL="$GI_EMAIL")
  fi
  # MERGE MAIN, AND KEEP THE CONFLICT. Aborting here is what sent every
  # conflict-unresolvable park straight to a rebuild: the markers ARE the brief.
  # A STACKED CHILD MERGES ITS OWN BASE, NOT MAIN (BH-5796). Its diff is read
  # against the parent branch, and the conductor parks it here when the
  # parent's new tip conflicts; merging main would carry main's diff into the
  # PR and leave the parent's change unmerged. A base that will not resolve is
  # main, as before.
  [ "$(br_ladder_class "$reason")" != orphaned-parent ] \
    && { pbase=$(br_pr_field "$url" .base.ref 'base branch' 2>/dev/null) || pbase=""; }
  if [ -n "$pbase" ] && [ "$pbase" != main ] && git -C "$wt" rev-parse --verify -q "origin/$pbase" >/dev/null 2>&1; then
    mref="$pbase"
    say "$p/$rkey [$reason]: $br is a stacked child of $pbase — the round merges origin/$pbase, not origin/main"
  fi
  conflicts=""
  if [ "$(br_ladder_class "$reason")" = orphaned-parent ]; then
    # NO MERGE ON THIS CLASS (2026-09-16). The job of this round is to take an
    # abandoned parent's commits OUT of the branch, which is a rebase onto
    # origin/main — and a merge commit landed on top of the branch first is
    # exactly the thing that makes that rebase hard. origin/main arrives with
    # the rebase.
    say "$p/$rkey [$reason]: not merging origin/main into $br — this round rebases the branch off a parent that closed without merging, and origin/main arrives with that rebase"
  # The pin is EXPORTED IN A SUBSHELL, not passed through `env`: `env git` execs
  # the git binary by path and so skips any `git` shell function (the test
  # doubles), while a subshell scopes the pin to this one merge all the same.
  elif ! ( [ "${#gienv[@]}" -gt 0 ] && export "${gienv[@]}"; git -C "$wt" merge --no-edit "origin/$mref" ) >>"$LOG" 2>&1; then
    conflicts=$(git -C "$wt" diff --name-only --diff-filter=U 2>/dev/null)
    if [ -z "$conflicts" ]; then
      say "$p/$rkey: origin/$mref will not merge into $br and git named no conflicted path — $(br_fix_terminal_word "$reason")"
      git -C "$wt" merge --abort >/dev/null 2>&1
      br_wt_drop "origin/main would not merge and git named no conflicted path"
      git -C "$REPOS/$p" branch -D "brfix/$ck" >/dev/null 2>&1
      mc_git_auth_clear 2>/dev/null
      br_fix_terminal "$p" "$rkey" "$reason" "$url" "$rec" "$tkey"; return 0
    fi
    say "$p/$rkey [$reason]: origin/$mref conflicts with $br in $(tr '\n' ' ' <<<"$conflicts") — the markers stay in the tree for the fix round to resolve"
    # The tree in front of us is the best measurement of this conflict there is,
    # and the paths are this ticket's memory of what it keeps fighting over.
    br_conflict_note "$p" "$ck" "$(mc_num_of_url "$url")" "$head" "$conflicts"
    br_note_conflict_lines "$p" "$ck" "$(mc_conflict_lines "$wt")"
    # EVERY SPENT ROUND ON A CONFLICTED MERGE SAYS HOW IT WENT (BH-6964), on the
    # fix-round row it already writes: `ok` only on the pushed exit, `failed`
    # on the four other spent exits. The size is the record's MAX measure; an
    # absent one is `unknown`, never 0 (a measured 0 stays 0).
    clines=$(br_load "$p" "$ck" | jq -r '.conflict_lines // empty' 2>/dev/null)
    case "$clines" in ''|*[!0-9]*) clines=unknown ;; esac
    cok=" · fix-round-conflict ok lines=$clines"; cfail=" · fix-round-conflict failed lines=$clines"
  fi
  # ---- the brief -----------------------------------------------------------
  brief=""
  [ -n "$findings" ] && brief="$brief"$'\n\n'"REVIEW FINDINGS AS POSTED ON THE PR:"$'\n'"$findings"
  if [ -n "$conflicts" ]; then
    markers=""
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      markers="$markers"$'\n'"--- $f ---"$'\n'"$(grep -n -B4 -A12 '^<<<<<<<' "$wt/$f" 2>/dev/null | head -c 2000)"
    done < <(head -5 <<<"$conflicts")
    if [ "$mref" = main ]; then
      brief="$brief"$'\n\n'"THE MERGE OF origin/main IS IN PROGRESS IN YOUR WORKTREE AND THESE PATHS ARE CONFLICTED. Resolve every one of them, keeping BOTH sides' intent (main's change is already reviewed and merged; this branch's change is what the ticket asked for), \`git add\` each file and commit the merge. Conflicted paths:"$'\n'"$conflicts"$'\n'"$markers"
    else
      brief="$brief"$'\n\n'"THE MERGE OF origin/$mref (the parent PR's branch this stacked PR is based on) IS IN PROGRESS IN YOUR WORKTREE AND THESE PATHS ARE CONFLICTED. Resolve every one of them, keeping BOTH sides' intent (the parent's new commits are the base this PR builds on; this branch's change is what the ticket asked for), \`git add\` each file and commit the merge. Do NOT merge origin/main. Conflicted paths:"$'\n'"$conflicts"$'\n'"$markers"
    fi
    # >>> br conflict brief (BH-6964)
    # THE MARKERS SHOW TWO LINES THAT DISAGREE, NOT WHAT EITHER SIDE WAS FOR. So
    # the brief adds the rule (prompts/fix-round.d/conflict.md), the merged-in
    # side's diff of the conflicted paths since the merge base, and the plan
    # this PR was built from. Each part is bounded by BR_CONFLICT_BRIEF_BYTES
    # (0 omits the diff and the plan), and a part that cannot be read says so
    # in one line: no empty heading, no invented path.
    if [ -r "$H/prompts/fix-round.d/conflict.md" ]; then
      brief="$brief"$'\n\n'"$(cat "$H/prompts/fix-round.d/conflict.md")"
    else
      say "$p/$rkey [$reason]: $H/prompts/fix-round.d/conflict.md is not readable — the brief carries the one-line rule instead"
      brief="$brief"$'\n\n'"Resolve the conflict only. Make no other change."
    fi
    cbytes="${BR_CONFLICT_BRIEF_BYTES:-6000}"
    case "$cbytes" in ''|*[!0-9]*) cbytes=6000 ;; esac
    if [ "$cbytes" -gt 0 ]; then
      mapfile -t cpaths < <(head -5 <<<"$conflicts")
      cdiff=""
      if cbase=$(git -C "$wt" merge-base HEAD MERGE_HEAD 2>/dev/null) && [ -n "$cbase" ]; then
        # Captured whole, then cut: a `head -c` on the pipe would SIGPIPE git.
        cdiff=$(git -C "$wt" diff "$cbase" MERGE_HEAD -- "${cpaths[@]}" 2>/dev/null) || cdiff=""
        [ -n "$cdiff" ] && cdiff=$(head -c "$cbytes" <<<"$cdiff")
        [ -n "$cdiff" ] || cdiff="(the merged-in side changed none of these paths since the merge base)"
      else
        cdiff="(no merge base: the main-side diff is not available)"
      fi
      brief="$brief"$'\n\n'"THE MERGED-IN SIDE'S DIFF SINCE THE MERGE BASE (origin/$mref, conflicted files only):"$'\n'"$cdiff"
      cplan=""; cplan_show=""
      if [ -n "$tkey" ] && [ "$tkey" != - ] && [ -r "$wt/.harness/specs/$tkey/plan.md" ]; then
        cplan="$wt/.harness/specs/$tkey/plan.md"; cplan_show=".harness/specs/$tkey/plan.md"
      elif [ -n "$rec" ] && [ "$rec" != - ] && [ -r "$rec/plan.md" ]; then
        cplan="$rec/plan.md"; cplan_show="$rec/plan.md"
      fi
      if [ -n "$cplan" ]; then
        brief="$brief"$'\n\n'"THE PLAN THIS PR WAS BUILT FROM: $cplan_show"$'\n'"$(head -c "$cbytes" "$cplan" 2>/dev/null)"
      else
        brief="$brief"$'\n\n'"THE PLAN THIS PR WAS BUILT FROM: not found (no .harness/specs/${tkey:--}/plan.md and no build record)"
      fi
    fi
    # <<< br conflict brief
  fi
  if [ "$(br_ladder_class "$reason")" = ci-red ]; then
    cilog=$(br_ci_log "$slug" "$head" "$(mc_num_of_url "$url" 2>/dev/null)")
    [ -n "$cilog" ] && brief="$brief"$'\n\n'"THE FAILING CI JOBS ON THIS HEAD (tail of each failed job's log):"$'\n'"$cilog"
  fi
  # >>> eject runs brief (BH-6000)
  # A queue-ejected-twice park: the two failing merge-queue batch runs the
  # conductor handed over (mc_eject_fix_now). They are the evidence; the PR's
  # own head CI is green by construction (the queue only takes green heads).
  if [ "$reason" = queue-ejected-twice ] && ejruns=$(br_eject_runs "$url" "${head:-}"); then
    brief="$brief"$'\n\n'"THE MERGE QUEUE EJECTED THIS PR TWICE. Its batch build (this branch merged onto current main together with the PRs queued ahead of it) failed both times, while this branch's own checks are green. Open these failing batch runs first; fixing what they show is the job:"$'\n'"$ejruns"
  fi
  # <<< eject runs brief
  # AN ORPHANED CHILD ALWAYS HAS A BRIEF, and it is the only one it needs: there
  # are no review findings on this park and no conflict was produced above, so
  # without this the `-z "$brief"` test below would drop straight to a fresh
  # rebuild and throw away a branch that is one rebase from being mergeable.
  if [ "$(br_ladder_class "$reason")" = orphaned-parent ]; then
    local deadbase carried
    # A 75 here leaves deadbase empty and the brief is written without the branch
    # name, exactly as it is for a PR that never named one: this is a prompt
    # detail, not a decision, so it does not defer the rung.
    deadbase=$(br_pr_field "$url" .base.ref 'base branch')
    carried=""
    [ -n "$deadbase" ] && [ "$deadbase" != main ] \
      && carried=$(git -C "$wt" log -20 --oneline "origin/$deadbase" --not origin/main 2>/dev/null)
    brief="$brief"$'\n\n'"THE PULL REQUEST THIS BRANCH WAS CUT FROM CLOSED WITHOUT MERGING${deadbase:+ (its branch is \`$deadbase\`)}. The harness park reads: $reason. So this branch still sits on work that will never land, and the PR cannot just be repointed at main. Make this branch carry THIS ticket's change and nothing else, on top of \`origin/main\` — \`git rebase --onto origin/main ${deadbase:-<the dead base branch>}\` is usually the entire job — and then make it typecheck and pass unit tests against current main. Do NOT re-implement the abandoned parent's work, and do not drop anything of your own ticket's. The harness force-pushes the result under a lease, and bin/merge-conductor.sh repoints the PR at main by itself once the branch carries nothing of the dead parent."
    [ -n "$carried" ] && brief="$brief"$'\n\n'"COMMITS THAT BELONG TO THE CLOSED PARENT AND MUST NOT SURVIVE ON THIS BRANCH:"$'\n'"$carried"
  fi
  # A PREQUEUE-RED PARK ALWAYS HAS A BRIEF (BH-4549): its head is green on its
  # own CI, so there is no failing job to read; the suites and the main sha come
  # from the park reason the hub copied onto the record (br_prequeue_note), or
  # from the conductor row when the round runs on the hub itself.
  if [ "$(br_ladder_class "$reason")" = prequeue-red ]; then
    local pqraw
    pqraw=$(printf '%s' "$st" | jq -r '.prequeue_reason // empty' 2>/dev/null)
    if [ -z "$pqraw" ] && command -v mc_row_field >/dev/null 2>&1; then
      pqraw=$(mc_row_field "$(br_slug_of_url "$url" 2>/dev/null)#$(mc_num_of_url "$url" 2>/dev/null)" 7 2>/dev/null)
      case "$pqraw" in prequeue-red*) ;; *) pqraw="" ;; esac
    fi
    pqbrief=$(br_prequeue_brief "$pqraw")
    brief="$brief"$'\n\n'"$pqbrief"
  fi
  # ARCHIE'S DIAGNOSIS (BH-4585): what its rebase-repair playbook found on THIS
  # head (br_archie_first), deterministic text, never a model's.
  archie=$(br_load "$p" "$ck" | jq -r --arg h "${head:-}" 'if $h != "" and .archie_diagnosis_head == $h then .archie_diagnosis // empty else empty end' 2>/dev/null)
  [ -n "$archie" ] && [ "$archie" != - ] \
    && brief="$brief"$'\n\n'"ARCHIE'S DIAGNOSIS (bin/archie-fm.sh, deterministic, no model):"$'\n'"$archie"
  if [ -z "$brief" ]; then
    say "$p/$rkey [$reason]: nothing to brief a fix round with (no posted findings, no conflict, no readable failing job) — $(br_fix_terminal_word "$reason")"
    br_wt_drop "there was nothing to brief a round with"
    git -C "$REPOS/$p" branch -D "brfix/$ck" >/dev/null 2>&1
    mc_git_auth_clear 2>/dev/null
    br_fix_terminal "$p" "$rkey" "$reason" "$url" "$rec" "$tkey"; return 0
  fi
  # THE MODEL BEFORE THE MARK (BH-1510.1). A round with no model route never
  # ran, so it must not spend this head's one mark: nothing is recorded and the
  # same head is offered again once a route exists.
  local fix_model
  if ! fix_model=$(br_model "$BR_EXECUTE_MODEL_ENV" build.execute.fallback "$p") || [ -z "$fix_model" ]; then
    say "$p/$rkey [$reason]: no model route for build.execute.fallback — the fix round is not run and the head is not marked; offered again next tick"
    br_wt_drop "there is no model route for the fix round"
    git -C "$REPOS/$p" branch -D "brfix/$ck" >/dev/null 2>&1
    mc_git_auth_clear 2>/dev/null
    return 0
  fi
  # The setup alert is cleared the moment the rung actually runs: a LATER setup
  # failure on this park is a new fact about the box and pages again.
  rm -f "$ST/$p/$ck.setup-alerted" 2>/dev/null
  # MARK BEFORE THE SPEND (D16), and only here: every path above this line is a
  # rung that never ran (a failed read, a setup problem, an unreadable verdict)
  # and must be offered the same head again. From here the execute call is about
  # to happen, so the (PR, head) key goes on the record FIRST — a crash
  # mid-round costs that head its one round, which is the right side to fail on
  # (the checkpoint branch brfix/<key> is reused by the next verdict).
  # A mark that did not WRITE stops the round: an unmarked round is a round that
  # runs again every ten minutes for ever.
  if [ "$reason" = review-changes-requested ]; then
    if ! br_push_field "$p" "$ck" review_fix_heads "$head"; then
      say "$p/$rkey [$reason]: could NOT record the fix-round head ${head:0:8} on $(br_file "$p" "$ck") — the round is not run, because an unmarked round repeats every tick"
      br_wt_drop "the fix-round head could not be recorded"
      git -C "$REPOS/$p" branch -D "brfix/$ck" >/dev/null 2>&1
      mc_git_auth_clear 2>/dev/null
      return 0
    fi
  fi
  # THE DIRECTIVE (BH-5125), read before the event so the event can name it.
  # An unreadable thread is said and costs nothing else: the round runs.
  directive=$(br_directive "$p" "$tkey" "$rec") || drc=$?
  [ "$drc" = 0 ] || directive=""
  [ "$drc" = 1 ] && say "$p/$rkey [$reason]: the ticket thread of $tkey is unreadable — round runs without a DIRECTIVE"
  br_event resolver_rung "$p" "$ck" "$reason" "rung 2 fix-round on $br (${head:0:8}): $([ -n "$findings" ] && printf 'findings '; [ -n "$conflicts" ] && printf 'conflict '; [ -n "$cilog" ] && printf 'ci-log '; [ -n "$pqbrief" ] && printf 'prequeue '; [ -n "$directive" ] && printf 'directive ')"
  # The live state (BH-1794) leads the brief, on its own paragraph.
  local live=""
  [ -n "${BR_PREFLIGHT_BRIEF:-}" ] && live=$'\n'"$BR_PREFLIGHT_BRIEF"$'\n'
  # A lead-blocked round must answer the lead in code, or say what it could not
  # (BH-2200). The list travels in the agent's FINAL REPORT, which agent-call.sh
  # (the harness) writes to $ST/$p/$ck.fix-run.txt: a runner confined to its
  # worktree cannot write under $ST (BH-2276). $unaddr is the harness's own copy.
  if [ "$lead_blocked" = 1 ]; then
    unaddr="$ST/$p/$ck.unaddressed.md"; mkdir -p "$(dirname "$unaddr")" 2>/dev/null; rm -f "$unaddr"
    brief="$brief"$'\n\n'"THE LEAD FINDINGS ABOVE ARE THE JOB. Every item must be addressed in code. For any item you genuinely cannot address, end your final message with a line reading exactly \`UNADDRESSED:\` followed by one line per item: \`- <the finding> — <why it cannot be done here>\`. Write no file for this. A round that changes none of the files the findings name and lists nothing there is not pushed."
  fi
  [ -n "$directive" ] && brief="$brief"$'\n\n'"$directive"
  # AN OUTSIDE CONTRIBUTOR'S PR (BH-4668): its author reads the history, so
  # each commit says which finding it answers. Empty for every other caller.
  local xprline=""
  [ "${BR_XPR_ACTIVE-}" = 1 ] && xprline=" This is an outside contributor's pull request: every commit message names the review finding it answers."
  # >>> br closure-lint brief (BH-5064)
  # Only when the merge of origin/main left no conflicted path: then the pack's
  # fork is origin/main and every line it prints is this PR's own.
  if [ -z "$conflicts" ] && command -v frcl_scan >/dev/null 2>&1; then
    frcl_dir="$ST/$p/$ck.closure-lint"; mkdir -p "$frcl_dir" 2>/dev/null
    frcl_w=$(frcl_scan "$wt" origin/main "$frcl_dir")
    if [ "${frcl_w:-}" = red ]; then
      brief="$brief"$'\n\n'"THE SCRATCH-CLOSURE LINT IS RED ON THIS BRANCH (bin/rules-pack.sh --only scratch-closure, the same check the merge queue runs). The harness re-runs it after you and will refuse to push while it is red. Each line names a suite and the line that hand-copies bin/lib files:"$'\n'"$(frcl_findings "$frcl_dir")"$'\n'"Replace each hand copy with \`scratch_install_closure <script> \"\$T\"\` (tests/lib/scratch.sh), installing the script the suite drives, so the closure follows the script's own sources. Do not edit tests/lib/scratch-closure-lint.sh, catalog/rules-pack.tsv or bin/rules-pack.sh. Add \`# scratch-closure-allow: <reason>\` only to a suite that copies one lib in order to unit-test that lib directly."
    fi
  fi
  # <<< br closure-lint brief
  # >>> br ci-local brief (BH-6897)
  # The previous round's CI lint findings, when that round was refused on them.
  if [ -s "$ST/$p/$ck.ci-local/findings.txt" ]; then
    brief="$brief"$'\n\n'"THE CI LINT STEPS WERE RED ON THE LAST ROUND (bin/ci-local.sh, the steps of CI's lint job and the rules pack). The harness re-runs them after you and will not push while they are red. Reproduce one step with \`bin/ci-local.sh --step '<step>'\`. Fix the code each line names; never edit .github/workflows/harness-ci.yml, bin/ci-local.sh or catalog/ci-local-skip.d/:"$'\n'"$(head -40 "$ST/$p/$ck.ci-local/findings.txt")"
  fi
  # <<< br ci-local brief
  prompt="FIX ROUND on an open pull request. Branch $br of $slug ($url) is parked with the harness on: $reason. Your job is to make that park false, and nothing else. Apply ONLY what the brief below asks for — no refactors, no adjacent cleanups, no new features: every line you change must trace to it. Where an item in the brief is wrong, say so in the commit message with your reasoning rather than silently ignoring it. Never answer a finding, a conflict or a red test by weakening, skipping or deleting a test. When you are done, run the repo's own typecheck and unit suite yourself and make them pass; the harness re-runs both after you and will refuse to push if they are red or if any conflicted path is left unresolved. Commit with a message naming what you addressed.$xprline
$live$brief"
  # THE LEDGER ROW, immediately before the spend. Written first so a crash
  # mid-call leaves a row the next tick prunes as a dead pid — never a round
  # that ran while the ledger said the box was idle.
  br_round_begin "$p" "$ck" "$hot" "$rkey"
  # CHECKPOINT (a): a hotfix asked for this slot while the round was setting up.
  if br_yield_take "$p" "$rkey" "$ck" "$reason" "$wt" "before the agent call"; then return 0; fi
  rc=0
  br_count llm
  ( cd "$wt" && env ${gienv[@]+"${gienv[@]}"} AGENT_CALL_ROLE=build.execute.fallback HARNESS="$H" timeout -k 60 "$FIX_AGENT_TIMEOUT" "$H/bin/agent-call.sh" execute "$p" "$fix_model" \
      "$FIX_AGENT_TIMEOUT" "$ST/$p/$ck.fix-run.txt" "$prompt" ) >>"$LOG" 2>&1 || rc=$?
  # CHECKPOINT (b): the ask arrived WHILE the agent worked. Its commit is on
  # brfix/$ck and stays there, so the next round starts from it.
  if br_yield_take "$p" "$rkey" "$ck" "$reason" "$wt" "after the agent call"; then return 0; fi
  # AGENT-CALL REFUSED BEFORE IT SPENT ANYTHING (BH-594). rc 77 is the hub's
  # hub-no-build refusal and rc 78 the no-tools refusal; both exit before a
  # runner is resolved, so the round never ran and nothing was billed. Reading
  # them as a failed round spent the fix round and went to REBUILD FRESH, which
  # closed project-5 #1740 and #1813 on 2026-09-16 over a machine problem. A
  # review park's head was marked above, before the spend; the spend did not
  # happen, so the mark goes back or that head is never offered again.
  if [ "$rc" = 77 ] || [ "$rc" = 78 ]; then
    local refusal
    refusal=$(head -1 "$ST/$p/$ck.fix-run.txt" 2>/dev/null)
    case "$refusal" in AGENT_CALL_REFUSED*) ;; *) refusal="no refusal line" ;; esac
    if [ "$reason" = review-changes-requested ]; then
      # shellcheck disable=SC2016  # $h is a jq variable, bound by --arg
      br_json_edit "$p" "$ck" '.review_fix_heads = ((.review_fix_heads // []) - [$h])' --arg h "$head" \
        || say "$p/$rkey [$reason]: could NOT un-mark ${head:0:8} on $(br_file "$p" "$ck") after the refusal — that head will not be offered again"
    fi
    br_wt_drop "agent-call refused the execute stage"
    mc_git_auth_clear 2>/dev/null
    br_setup_blocked "$p" "$ck" "$rkey" "$reason" "$url" "agent-call refused the execute stage on $(hostname 2>/dev/null || echo this box) (rc=$rc: $refusal)" fix-round "an agent-call that runs the execute stage here (rc 77: this box is the hub and runs no agent build work — the round belongs on the owning box; rc 78: a runner that can honour the no-tools contract)"
    return 0
  fi
  # THE VERIFICATION IS OURS, NOT THE AGENT'S. "I ran the tests" is a claim; this
  # is the evidence. FOREGROUND, inside the lane timeout, and a red result means
  # nothing is pushed.
  out="$ST/$p/$ck.fix-verify.txt"; mkdir -p "$(dirname "$out")" 2>/dev/null
  # >>> br regenerate (BH-5796)
  # THE GENERATED FILES ARE RE-RENDERED AS THE ROUND'S LAST STEP. A conflict
  # round resolves by hand, and a hand-resolved tree can leave a generated file
  # (the lanes registry, the env example, a rendered index) stale against its
  # sources: the PR then goes red on a --check step no ticket is about. So the
  # repo's own "Generated files" table, read from the merged base, is re-run
  # over the round's tree and committed as one extra commit under the round's
  # author pin, before the verification below reads the tree.
  if [ "$(br_ladder_class "$reason")" = rebase-conflict ] && command -v mc_regen_generated >/dev/null 2>&1; then
    ( [ "${#gienv[@]}" -gt 0 ] && export "${gienv[@]}"; mc_regen_generated "$wt" "origin/${mref:-main}" "$url fix round" )
    say "$p/$rkey [$reason]: reran the generated-file commands over the round's tree (base origin/${mref:-main}) as its last step"
  fi
  # <<< br regenerate
  local vrc=0
  {
    echo "== typecheck =="
    if grep -q '"typecheck"' "$wt/package.json" 2>/dev/null; then
      ( cd "$wt" && timeout 1200 npm run typecheck 2>&1 ); echo "TYPECHECK_EXIT: $?"
    else echo "TYPECHECK_EXIT: no-typecheck-script"; fi
    echo "== unit =="
    if grep -q '"test:unit"' "$wt/package.json" 2>/dev/null; then
      ( cd "$wt" && timeout 1800 npm run test:unit 2>&1 ); echo "UNIT_EXIT: $?"
    elif grep -q '"test"' "$wt/package.json" 2>/dev/null; then
      ( cd "$wt" && timeout 1800 npm test 2>&1 ); echo "UNIT_EXIT: $?"
    else echo "UNIT_EXIT: no-test-script"; fi
    # >>> br closure-lint verify (BH-5064)
    # Red refuses the push like a red unit run. could-not-run, skipped (no pack:
    # every product repo) and off are recorded and refuse nothing.
    echo "== scratch-closure =="
    if command -v frcl_scan >/dev/null 2>&1; then
      frcl_dir="$ST/$p/$ck.closure-lint"; mkdir -p "$frcl_dir" 2>/dev/null
      frcl_w=$(frcl_scan "$wt" origin/main "$frcl_dir")
      case "${frcl_w:-}" in
        red)   frcl_findings "$frcl_dir"; echo "CLOSURE_LINT_EXIT: 1" ;;
        clean) echo "CLOSURE_LINT_EXIT: 0" ;;
        *)     echo "CLOSURE_LINT_EXIT: ${frcl_w:-could-not-run}" ;;
      esac
    else echo "CLOSURE_LINT_EXIT: skipped (bin/lib/fixround-closure-lint.sh not on this box)"; fi
    # <<< br closure-lint verify
    # >>> br ci-local verify (BH-6897)
    # The worktree's own bin/ci-local.sh: CI's lint job steps and the rules
    # pack. Red refuses the push like a red unit run; could-not-run, skipped
    # (no bin/ci-local.sh: every product repo) and off refuse nothing.
    if command -v cl_verify_lines >/dev/null 2>&1; then
      mkdir -p "$ST/$p" 2>/dev/null
      cl_verify_lines "$wt" "origin/${mref:-main}" "$ST/$p/$ck.ci-local"
    else echo "== ci-local =="; echo "CI_LOCAL_EXIT: skipped (bin/lib/ci-local-verify.sh not on this box)"; fi
    # <<< br ci-local verify
  } > "$out" 2>&1
  grep -qE '^(TYPECHECK|UNIT|CLOSURE_LINT)_EXIT: [1-9]' "$out" && vrc=1
  grep -q '^CI_LOCAL_EXIT: 1' "$out" && { vrc=1; say "$p/$rkey [$reason]: the CI lint steps are red on the round's head ($(grep -c '^CI-LOCAL ' "$out") finding line(s), see $out) — not pushed"; }
  grep -q '^CLOSURE_LINT_EXIT: 1' "$out" && say "$p/$rkey [$reason]: the scratch-closure lint is red on the round's head ($(frcl_findings "$frcl_dir" | grep -c .) finding line(s), see $out) — not pushed"
  # A HALF-RESOLVED MERGE IS NEVER PUSHED. An agent that answered the conflict by
  # staging one file and committing another would otherwise send markers to main.
  if [ -n "$(git -C "$wt" diff --name-only --diff-filter=U 2>/dev/null)" ]; then
    vrc=1; echo "UNRESOLVED_PATHS: $(git -C "$wt" diff --name-only --diff-filter=U | tr '\n' ' ')" >> "$out"
  fi
  # A FOREIGN AUTHOR IS NEVER PUSHED (BH-1134). The round's own commits — HEAD
  # minus the PR head and minus origin/main, merges included — must all be
  # authored AND committed as the configured email. A mismatch, or a check that
  # could not run (no lib, a ref that will not resolve), is a failed round: the
  # push below is only reachable with rc 0.
  gsnot="$lease"
  git -C "$wt" rev-parse --verify -q origin/main >/dev/null 2>&1 && gsnot="$gsnot origin/main"
  [ "${mref:-main}" != main ] && gsnot="$gsnot origin/$mref"
  girc=3
  # shellcheck disable=SC2086
  command -v gi_check >/dev/null 2>&1 && { gibad=$(gi_check "$wt" $gsnot); girc=$?; }
  if [ "$girc" != 0 ]; then
    vrc=1; br_author_bad=1
    if [ "$girc" = 1 ]; then
      printf 'AUTHOR_MISMATCH: %s\n' "$(printf '%s' "$gibad" | tr '\n' ';')" >> "$out"
      say "$p/$rkey [$reason]: the round's commits are not all authored+committed as $GI_EMAIL ($(printf '%s' "$gibad" | awk '{printf "%s ", $1}')) — not pushed"
    else
      echo "AUTHOR_CHECK: could-not-run" >> "$out"
      say "$p/$rkey [$reason]: the commit-author check could not run (bin/lib/git-identity.sh missing or git log failed) — not pushed"
    fi
  fi
  if [ "$rc" != 0 ] || [ "$vrc" != 0 ] || [ "$(git -C "$wt" rev-parse HEAD)" = "$lease" ]; then
    br_record "$p" "$ck" fix-round "$reason" "agent rc=$rc, verify rc=$vrc — no verified commit$cfail" fixrounds "$url" "${head:--}"
    # A FAILED ROUND WITH ROUNDS REMAINING ENDS THE TICK. The cap is re-read
    # because this round just measured the conflict, and the checkpoint branch
    # is KEPT: the next round starts from whatever this one got done rather
    # than buying the same tokens again.
    #
    # A REVIEW PARK NEVER TAKES THAT EXIT (BH-872 ∩ BH-579). Its rounds are keyed
    # on (PR, head) and this head was marked spent before the agent ran, so the
    # next tick would not offer it again: "rounds remaining" would mean the park
    # sits with no round, no terminal and nobody told. Its remaining round is for
    # the next head, and for THIS head a failed round is the terminal.
    st=$(br_load "$p" "$ck"); cap=$(br_fix_cap "$st" "$reason" "$p")
    if [ "$reason" != review-changes-requested ] && [ "$((n+1))" -lt "$cap" ]; then
      say "$p/$rkey [$reason]: fix round $((n+1)) of $cap did not land — fix round $((n+2)) next tick (agent rc=$rc, verify rc=$vrc)"
      br_wt_drop "the round did not land and another one is owed"
      # A foreign-authored checkpoint is never reused: the next round would
      # start from the same commit and fail on it again.
      [ "$br_author_bad" = 1 ] && git -C "$REPOS/$p" branch -D "brfix/$ck" >/dev/null 2>&1
      mc_git_auth_clear 2>/dev/null
      return 0
    fi
    say "$p/$rkey [$reason]: fix round did not produce a verified commit (agent rc=$rc, verify rc=$vrc) — $(br_fix_terminal_word "$reason")"
    br_xpr_wait_line "$p" "$rkey" "$reason" "$n" "$cap"
    br_wt_drop "the round produced no verified commit"
    git -C "$REPOS/$p" branch -D "brfix/$ck" >/dev/null 2>&1
    mc_git_auth_clear 2>/dev/null
    br_fix_terminal "$p" "$rkey" "$reason" "$url" "$rec" "$tkey"; return 0
  fi
  # >>> br guard-silenced gate (tests/review-record-integrity-test.sh section 5 drives this block)
  # THE SAME GUARD-SILENCING RULE AS THE BUILD'S FIX ROUND (BH-641). A round
  # that answered the park by editing the guard's own rule module, allow-list or
  # fixture changed nothing the findings were about, so it is not pushed at all
  # and the ticket takes the rebuild path this rung already has for a round that
  # produced nothing usable.
  #
  # THE ROUND'S OWN COMMITS, NEVER "$lease"..HEAD. origin/main is merged into
  # this worktree ABOVE, before the agent runs, so a lease..HEAD diff carries
  # every file main changed since the branch diverged: on any park where main
  # had moved — an mq conflict is that by definition — it answered CODE_CHANGED
  # and this gate could never fire. `log HEAD --not $lease origin/main` is the
  # set of commits reachable from HEAD and from neither side, which is exactly
  # what this round wrote. --no-merges drops the merge commit itself, so a
  # conflict resolution inside it is not counted as the round's own work: the
  # safe direction, since silencing a guard is not how anyone resolves a merge.
  if command -v gs_classify >/dev/null 2>&1; then
    gsnot="$lease"
    git -C "$wt" rev-parse --verify -q origin/main >/dev/null 2>&1 && gsnot="$gsnot origin/main"
    [ "${mref:-main}" != main ] && gsnot="$gsnot origin/$mref"
    # shellcheck disable=SC2086
    gsv=$(git -C "$wt" log --no-merges --name-only --format= HEAD --not $gsnot 2>/dev/null \
          | sort -u | gs_classify); gsrc=$?
    if [ "$gsrc" = 1 ] && [ "$gsv" = GUARD_SILENCED ]; then
      say "$p/$rkey [$reason]: fix round is GUARD_SILENCED (edited only guard rules/allow-lists/fixtures) — not pushed"
      # ${cfail:-}, not $cfail: section 5 sources this block alone under set -u.
      br_record "$p" "$ck" fix-round "$reason" "guard-silenced — not pushed${cfail:-}" fixrounds "$url" "${head:--}"
      br_wt_drop "the round was guard-silenced"
      git -C "$REPOS/$p" branch -D "brfix/$ck" >/dev/null 2>&1
      mc_git_auth_clear 2>/dev/null
      br_rebuild_fresh "$p" "$rkey" "$reason" "$url" "$rec" "$tkey"; return 0
    fi
  fi
  # <<< br guard-silenced gate
  # >>> br lead noop gate (tests/fixround-lead-reviews.bh-2200-test.sh F2-F4)
  # A LEAD-BLOCKED ROUND THAT ANSWERED NOTHING IS NOT PUSHED (BH-2200). On #2045,
  # #2051 and #2065 the "fix" was origin/main merged in and nothing else. The
  # round's OWN commits (the guard gate's set: reachable from HEAD, from neither
  # the PR head nor origin/main, merges dropped) must touch a file the findings
  # name — the exact path or a path ending in it — or, when they name no file,
  # anything at all. A round that could not may instead list what it could not
  # address in its final report's UNADDRESSED: section (copied to $unaddr): that
  # list is posted on the PR and the round is pushed.
  # Anything else is fix-round-noop: nothing pushed, one record, one event, one
  # alert, and the head remembered so the next tick does not buy it again.
  if [ "$lead_blocked" = 1 ]; then
    gsnot="$lease"
    git -C "$wt" rev-parse --verify -q origin/main >/dev/null 2>&1 && gsnot="$gsnot origin/main"
    [ "${mref:-main}" != main ] && gsnot="$gsnot origin/$mref"
    # shellcheck disable=SC2086
    noop_own=$(git -C "$wt" log --no-merges --name-only --format= HEAD --not $gsnot 2>/dev/null | sed '/^$/d' | sort -u)
    # A NAME COUNTS ONLY IF THE REPO HAS IT (review of #2271). The candidates are
    # every path-looking token in the brief, and "e.g", "Node.js" or a PR URL
    # look like paths too — read as files they would turn off the "names no
    # file" fallback and freeze a correct round. So a token is kept only when a
    # tracked file IS it, ends in it, or sits under it as a directory.
    noop_named=$(printf '%s\n' "$findings" | grep -oE '[A-Za-z0-9_.@-]*[A-Za-z0-9_@-]/[A-Za-z0-9_./@-]*[A-Za-z0-9_@-]|[A-Za-z0-9_@-]+\.[A-Za-z][A-Za-z0-9]{0,5}' | sort -u \
      | awk 'NR == FNR { t[$0] = 1; next }
             { n = $0; keep = 0
               for (f in t) if (f == n || substr(f, length(f) - length(n)) == "/" n || index(f, n "/") == 1 || index(f, "/" n "/") > 0) { keep = 1; break }
               if (keep) print n }' <(git -C "$wt" ls-files 2>/dev/null) -)
    noop_hit=0
    if [ -z "$noop_named" ]; then
      [ -n "$noop_own" ] && noop_hit=1
    else
      # A file is answered by a change to it (exact or as a path suffix); a
      # directory by a change anywhere under it.
      while IFS= read -r noop_f; do
        [ -n "$noop_f" ] || continue
        while IFS= read -r noop_n; do
          [ -n "$noop_n" ] || continue
          case "$noop_f" in "$noop_n"|*/"$noop_n"|"$noop_n"/*|*/"$noop_n"/*) noop_hit=1; break 2 ;; esac
        done <<<"$noop_named"
      done <<<"$noop_own"
    fi
    # The list is the final report's LAST `UNADDRESSED:` section: its `- ` items,
    # up to the first line that is neither blank nor an item. `UNADDRESSED: none`,
    # a bare header or prose is an empty list (BH-2276). A file the agent wrote
    # itself is used as it is.
    if [ "$noop_hit" = 0 ] && [ ! -s "$unaddr" ]; then
      awk '/^[[:space:]]*UNADDRESSED:[[:space:]]*$/ { on = 1; buf = ""; next }
           on && /^[[:space:]]*- [^[:space:]]/ { buf = buf $0 "\n"; next }
           on && /^[[:space:]]*$/ { next }
           on { on = 0 }
           END { printf "%s", buf }' "$ST/$p/$ck.fix-run.txt" > "$unaddr" 2>/dev/null
    fi
    if [ "$noop_hit" = 0 ] && [ -s "$unaddr" ]; then
      br_pr_comment "$url" "Fix round by \`bin/blocked-resolver.sh\` ($reason): these LEAD findings were NOT addressed in code, and why:

$(head -c 4000 "$unaddr")" >/dev/null 2>&1 || true
      say "$p/$rkey [$reason]: the round changed no file the lead's findings name, but listed what it could not address — posted on the PR, pushing"
      noop_hit=1
    fi
    if [ "$noop_hit" = 0 ]; then
      say "$p/$rkey [$reason]: fix-round-noop — the round changed none of the files the lead's findings name ($(printf '%s' "$noop_named" | tr '\n' ' ' | head -c 200)) and listed nothing it could not address — NOT pushed"
      br_record "$p" "$ck" fix-round-noop "$reason" "changed no file the lead's findings name and listed nothing unaddressed — not pushed (own files: $(printf '%s' "$noop_own" | tr '\n' ' ' | head -c 200))$cfail" fixrounds "$url" "${head:--}"
      br_push_field "$p" "$ck" noop_heads "${head:-$lease}" \
        || say "$p/$rkey [$reason]: could NOT record ${head:0:8} in noop_heads — the next tick may run this head again"
      br_event resolver_fix_noop "$p" "$ck" "$reason" "fix round on ${head:0:8} answered none of the lead's findings — not pushed"
      br_wt_drop "the round answered none of the lead's findings"
      git -C "$REPOS/$p" branch -D "brfix/$ck" >/dev/null 2>&1
      mc_git_auth_clear 2>/dev/null
      # NO PAGE (BH-4149). This used to lane-alert a person to act or push
      # and leave the head frozen for ever. The head's round is spent, so the
      # park goes to its terminal in this same tick.
      say "$p/$rkey [$reason]: fix-round-noop on ${head:0:8} — $(br_fix_terminal_word "$reason")"
      br_fix_terminal "$p" "$rkey" "$reason" "$url" "$rec" "$tkey"
      return 0
    fi
  fi
  # <<< br lead noop gate
  # WHO JUDGES THE NEW HEAD depends on the park (#891 round 1, Nit 10). A
  # conductor park (a queued pipeline PR) is re-judged by the conductor's
  # head-bound re-review. A `review-changes-requested` park comes from
  # bin/review-prs.sh on a PR the conductor never queued, and it is that lane —
  # the project box's review tick — that reviews the pushed head. Naming the
  # wrong one sends a reader to a log that says nothing about their PR.
  case "$reason" in
    review-changes-requested) br_next_judge="the project box's review lane re-reviews it on its next tick" ;;
    *)                        br_next_judge="the conductor's head-bound re-review judges it next" ;;
  esac
  [ "${BR_XPR_ACTIVE-}" = 1 ] && br_next_judge="the project box's review lane re-reviews it on its next tick"
  # THE HOLD IS READ AGAIN HERE, AT THE PUSH (BH-2504). The dispatch read it
  # minutes ago; a lead who typed HOLD while this round ran is the #2481 shape
  # (the push landed 29 s after the HOLD). The ticket is the issue this lane
  # already names for its hold gate; a board ticket has none, and the lease is
  # the whole guard there.
  local hticket href hrc=0 prc=0
  href=$(br_hold_issue "$p" "$tkey" "$rec") || hrc=$?
  case "$hrc" in
    0) hticket="${href% *}#${href##* }" ;;
    1) hticket=none ;;
    *) hticket=- ;;
  esac
  HOLD_PUSH_LOG="$LOG" hold_push "$p" "$hticket" "$wt" origin HEAD "$br" "$lease" >>"$LOG" 2>&1 || prc=$?
  if [ "$prc" = 3 ] || [ "$prc" = 4 ]; then
    # NOT PUSHED, NOTHING SPENT: no fixrounds counter, no PR comment, and the
    # local round is thrown away. br_hold_gate does the HELD bookkeeping (the
    # one respected line, the HELD row the next tick re-reads) or, on a read
    # that failed, the one-per-episode hold-unreadable record.
    say "$p/$rkey [$reason]: fix round NOT pushed — the ticket is $( [ "$prc" = 3 ] && echo held || echo unreadable) at the push; the round is discarded"
    br_record "$p" "$ck" fix-round-held "$reason" "not pushed: the hold was re-read at the push (rc $prc)"
    br_wt_drop "the ticket was held at the push"
    git -C "$REPOS/$p" branch -D "brfix/$ck" >/dev/null 2>&1
    mc_git_auth_clear 2>/dev/null
    br_hold_gate "$p" "$rkey" "$reason" "$url" "$rec" "$tkey" >/dev/null 2>&1 || true
    return 0
  fi
  if [ "$prc" = 0 ]; then
    say "$p/$rkey [$reason]: FIX ROUND pushed $(git -C "$wt" rev-parse --short HEAD) to $br — $br_next_judge"
    br_record "$p" "$ck" fix-round "$reason" "pushed $(git -C "$wt" rev-parse --short HEAD) to $br, typecheck+unit green$cok" fixrounds "$url" "${head:--}"
    # THE PUSH IS REMEMBERED FOR THE SUPERSEDE GUARD (BH-1642): the rebuild rung
    # may not close this PR inside the settle window after it, nor while a lead
    # verdict stands on the head it pushed over (#1448).
    br_fix_push_note "$p" "$ck" "$url" "$(git -C "$wt" rev-parse HEAD)" "${head:-}"
    # The body's live-CI block now names the pushed head (BH-1794).
    command -v br_preflight_after_push >/dev/null 2>&1 \
      && br_preflight_after_push "$slug" "$url" "$(git -C "$wt" rev-parse HEAD)" "$p" "$ck"
    # An external PR's comment is extfix.sh's template (BH-4668); a box without
    # that module posts the generic one.
    if [ "${BR_XPR_ACTIVE-}" = 1 ] && command -v br_xpr_round_comment >/dev/null 2>&1; then
      br_xpr_round_comment "$url" "${head:-$lease}" "$(git -C "$wt" rev-parse HEAD)" "$findings" "$wt" "$lease" >/dev/null 2>&1 || true
    else
      br_pr_comment "$url" "Fix round by \`bin/blocked-resolver.sh\` ($reason): merged \`origin/main\`, worked the brief the harness had for this park (posted findings, the conflict, and the failing job's log, whichever existed), and verified with the repo's own typecheck + unit suite before pushing. Next: $br_next_judge; no person is holding this PR." >/dev/null 2>&1 || true
    fi
  else
    br_record "$p" "$ck" fix-round "$reason" "push rejected under the lease$cfail" fixrounds "$url" "${head:--}"
    # Same split as the no-verified-commit exit above: a review park's head is
    # already marked spent, so it goes to its terminal rather than waiting for a
    # round that would never be offered.
    st=$(br_load "$p" "$ck"); cap=$(br_fix_cap "$st" "$reason" "$p")
    if [ "$reason" != review-changes-requested ] && [ "$((n+1))" -lt "$cap" ]; then
      # Somebody just moved this head. With a round still owed the right answer
      # is the next round on the head they pushed, not a rebuild of a branch
      # that is being worked on.
      say "$p/$rkey [$reason]: fix round $((n+1)) of $cap did not land — fix round $((n+2)) next tick (push REJECTED: the head moved under the lease)"
      br_wt_drop "the push was rejected and another round is owed"
      mc_git_auth_clear 2>/dev/null
      return 0
    fi
    say "$p/$rkey [$reason]: fix round push REJECTED (the head moved under the lease) — $(br_fix_terminal_word "$reason")"
    br_xpr_wait_line "$p" "$rkey" "$reason" "$n" "$cap"
    br_wt_drop "the push was rejected under the lease"
    git -C "$REPOS/$p" branch -D "brfix/$ck" >/dev/null 2>&1
    mc_git_auth_clear 2>/dev/null
    br_fix_terminal "$p" "$rkey" "$reason" "$url" "$rec" "$tkey"; return 0
  fi
  br_wt_drop "the round pushed its fix"
  git -C "$REPOS/$p" branch -D "brfix/$ck" >/dev/null 2>&1
  mc_git_auth_clear 2>/dev/null
}

# br_ironlaw_context <diff-file> — the flagged added lines with 30 lines of
# context each. The adjudicator has to see what the line DOES, not just that a
# pattern matched: every false park this scan has ever produced (a doc comment
# citing an iron law, a seed row that IS the DB-driven pattern, a test asserting
# against the pattern) is invisible in the matched line alone.
br_ironlaw_context() {
  local f="$1" n lines=""
  [ -s "$f" ] || return 0
  while read -r n; do
    [ -n "$n" ] || continue
    lines="$lines"$'\n'"--- around line $n of the diff ---"$'\n'"$(sed -n "$((n>30?n-30:1)),$((n+30))p" "$f")"
  done < <(grep -nE '^\+' "$f" | grep -E "window\.(confirm|alert|prompt)\(|claude-(fable|opus|sonnet|haiku)|VERCEL_URL" | cut -d: -f1 | head -6)
  printf '%s' "$lines"
}

# ADJUDICATE. One review-stage call, one word back. This rung exists because the
# two gates it serves are DETECTORS, not verdicts: the iron-law scan matches a
# pattern in added lines, and the test-tamper scanner counts deleted test names.
# Both are right often enough to be worth keeping and wrong often enough that
# parking on them forever is how tickets died.
# br_opt_family_store <p> <rkey> <reason> <rec> <url> <verdict> — hand a ruling
# the lane has just posted to the optional family module (BH-1468), when one is
# loaded. BEST EFFORT, rc 0 whatever happens: by the time this runs the verdict
# has already been recorded, commented and acted on, so a module that fails must
# not become br_adjudicate's exit code. Called at the end of the ACCEPT and the
# REJECT arm, never in one place before the case — see the comment there.
br_opt_family_store() {
  command -v br_opt_family_record >/dev/null 2>&1 || return 0
  br_opt_family_record "$@" || true
  return 0
}

br_adjudicate() {
  local p="$1" rkey="$2" reason="$3" url="$4" rec="$5" tkey="$6"
  local st n slug head evidence prompt adj verdict issue prefix df silent ck dslug dnum
  local report adj_cases adj_prefix="" ilc_f="" ilc_rc=2 ilc_n ilc_arc
  st=$(br_load "$p" "$rkey"); n=$(br_num "$st" adjudications)
  n=$(br_cap_rows "$p" "$rkey" "$reason" "$n" "$url" adjudicate adjudications)
  if [ "$n" -ge 1 ]; then
    say "$p/$rkey [$reason]: already adjudicated once — dropping to the rung below"
    case "$reason" in
      iron-law) br_fix_round "$p" "$rkey" "$reason" "$url" "$rec" "$tkey" ;;
      *)        br_rebuild_fresh "$p" "$rkey" "$reason" "$url" "$rec" "$tkey" ;;
    esac
    return 0
  fi
  # THE FAMILY SEAM (BH-1468). rc 0 means a stored ruling was carried onto this
  # PR: br_adjudicate returns 0 and makes NO model call, posts no ruling and
  # spends no adjudication counter — the module owns all three, because it is
  # the thing that decided.
  #
  # BEFORE the observe check below on purpose. #1471's observe behaviour is to
  # log `WOULD carry family` and write no marker, which it can only do if it is
  # asked; returning on OBSERVE first would hide every carry from it and make
  # observe mode a worse predictor of a real tick than no observe mode at all.
  # The site is pure dispatch — a module reads $OBSERVE itself.
  if command -v br_opt_family_pre >/dev/null 2>&1 \
     && br_opt_family_pre "$p" "$rkey" "$reason" "$rec" "$url"; then
    return 0
  fi
  if [ "$OBSERVE" = 1 ]; then say "$p/$rkey [$reason]: WOULD adjudicate — observe mode"; return 0; fi
  # No model route, no ruling bought (BH-1510.1): no counter, no comment, and
  # the same park is adjudicated once a route exists — the unreadable-diff rule.
  local adj_model
  if ! adj_model=$(br_model "$BR_REVIEW_MODEL_ENV" build.review "$p") || [ -z "$adj_model" ]; then
    say "$p/$rkey [$reason]: no model route for build.review — adjudication not bought this tick, retried next tick"
    return 0
  fi
  mkdir -p "$ST/$p" 2>/dev/null
  slug=$("$H/bin/fleet-conf.sh" "$p" repo 2>/dev/null)
  if [ "$reason" = iron-law ]; then
    # THE DIFF IS THE WHOLE EVIDENCE, so a diff this tick could not read does not
    # buy a review-stage agent call on nothing: no counter, no comment, no
    # ruling, and the same park is adjudicated next tick.
    df=$(mktemp)
    dslug=$(br_slug_of_url "$url") || dslug="$slug"
    dnum=$(mc_num_of_url "$url")
    if [ -n "$dslug" ] && [ -n "$dnum" ]; then
      if ! gh_rest GET "repos/$dslug/pulls/$dnum" -H "Accept: application/vnd.github.v3.diff" > "$df" 2>/dev/null; then
        rm -f "$df"
        say "$p/$rkey [iron-law]: the PR diff is UNVERIFIABLE (HTTP $GH_REST_STATUS${GH_REST_REASON:+ $GH_REST_REASON}) — adjudication not bought this tick, retried next tick"
        return 0
      fi
    fi
    evidence="The merge gate's iron-law scan flagged added lines in this diff. The flagged lines with 30 lines of context each:
$(br_ironlaw_context "$df")"
    # The fingerprints of exactly the diff this ruling reads (BH-4474). Kept
    # for the ACCEPT arm; rc 2 (hit set unknown) leaves nothing to record.
    if command -v ilc_hits >/dev/null 2>&1 && ilc_f=$(mktemp); then
      ilc_hits "$df" > "$ilc_f" 2>/dev/null; ilc_rc=$?
      [ "$ilc_rc" = 0 ] || : > "$ilc_f"
    fi
    rm -f "$df"
  else
    # THE RULING NAMES THE CASES (BH-1047). A verdict that says "the tamper gate
    # was right" without saying about WHAT is the same park in different words:
    # nobody can check it without opening the box. The scanner now prints the
    # case names under DELETED_CASES, so they ride into the prompt and into both
    # comment bodies. A pre-BH-1047 report has no such block and says so rather
    # than rendering an empty heading.
    report="$rec/test-tamper.txt"
    [ -s "$rec/test-tamper-rescan.txt" ] && report="$rec/test-tamper-rescan.txt"
    adj_cases=$(sed -n '/^DELETED_CASES:/,/^[A-Z_]*:/p' "$report" 2>/dev/null | grep '^  ' | head -40)
    [ -n "$adj_cases" ] || adj_cases="(the scanner named no cases; this is a pre-BH-1047 report)"
    evidence="The test-tamper scanner refused this build: it found test cases removed from the diff with no TEST-CHANGE justification.

Deleted cases under adjudication:
$adj_cases

Its report:
$(head -c 4000 "$report" 2>/dev/null)"
    adj_prefix="Deleted cases under adjudication:
$adj_cases

"
  fi
  prompt="ADJUDICATION, not a review. A MECHANICAL gate refused this change and the harness needs one ruling so the ticket can move. You are the ruling.

Ticket: $tkey ($p). ${url:+PR: $url}
The plan this build executed:
$(head -c 4000 "$rec/plan.md" 2>/dev/null || echo '(no plan on this record)')

The iron laws this fleet holds: no native browser dialogs (window.confirm/alert/prompt) in product UI; no hardcoded claude-* model strings in agent code (models resolve through the project's DB-backed config); never VERCEL_URL or a *.vercel.app host for a serverless self-fetch (Deployment Protection 401s it); tests are never weakened, skipped or deleted to make a build pass.

$evidence

Rule on it. A gate hit is not automatically a violation: a doc comment that CITES an iron law is compliance, a seed row in scripts/migrations that carries a model string IS the DB-driven pattern the law prescribes, a test asserting against the pattern is the test doing its job, and a test case that was RETITLED or SPLIT was not deleted. Equally, a real violation is a real violation however plausible the surrounding code looks, and a test whose assertion was removed to make something pass is never acceptable.

Write your reasoning, then the LAST LINE of your answer must be exactly one word: ACCEPT (the flagged change is legitimate and this build may proceed) or REJECT (the gate was right)."
  # COUNTED ON REACHING THE CALL, not on getting an answer back (BH-1468): an
  # adjudication that came back empty was billed exactly like one that ruled.
  br_count llm
  HARNESS="$H" timeout -k 60 "$ADJ_TIMEOUT" "$H/bin/agent-call.sh" review "$p" "$adj_model" "$ADJ_TIMEOUT" \
    "$ST/$p/$rkey.adjudication-run.txt" "$prompt" >>"$LOG" 2>&1 || true
  # agent-call.sh writes the model's answer to its OUT file and prints nothing on
  # stdout: the verdict lives in the run file. Reading stdout here left a 0-byte
  # adjudication.md and four unanimous ACCEPTs re-bought every tick (2026-09-14).
  adj="$ST/$p/$rkey.adjudication-run.txt"
  verdict=$(tail -5 "$adj" 2>/dev/null | grep -oE '^[[:space:]]*(ADJUDICATION:[[:space:]]*)?(ACCEPT|REJECT)[[:space:]]*$' | grep -oE 'ACCEPT|REJECT' | tail -1)
  # Post it where the ticket's reader is. A ruling nobody can see is the same as
  # no ruling — this whole change is about parks that happened in silence.
  if [ -n "$url" ] && [ "$url" != "-" ]; then
    br_pr_comment "$url" "$(printf '_Adjudication by `bin/blocked-resolver.sh` (%s) of the %s gate: **%s**._\n\n%s%s' "$adj_model" "$reason" "${verdict:-NO VERDICT}" "$adj_prefix" "$(head -c 6000 "$adj")")" >/dev/null 2>&1 || true
  else
    # >>> adjudication issue post (BH-5799)
    prefix=$("$H/bin/fleet-conf.sh" "$p" board_prefix 2>/dev/null)
    issue=$(sed -nE 's/^[A-Za-z]+-([0-9]+)$/\1/p' <<<"$tkey")
    if [ "$prefix" = "-" ] && [ -n "$issue" ] && [ -n "$slug" ]; then
      local adj_body; adj_body=$(printf '_Adjudication by `bin/blocked-resolver.sh` (%s) of the %s gate: **%s**._\n\n%s%s' "$adj_model" "$reason" "${verdict:-NO VERDICT}" "$adj_prefix" "$(head -c 6000 "$adj")")
      # BH-5799: this post lands on the ISSUE, newer than the plan's
      # plan-thread-at, and an ACCEPT below resumes that plan. Without a line in
      # the build's own-post ledger the plan thread gate would refuse the plan
      # this ruling just cleared, and the TEST-CHANGE block with it.
      if br_issue_comment "$slug" "$issue" "$adj_body" >/dev/null 2>&1 \
         && [ -n "$rec" ] && [ "$rec" != "-" ] && [ -d "$rec" ]; then
        declare -F ptg_own_post >/dev/null || . "$H/bin/lib/plan-thread.sh" 2>/dev/null
        local adj_bf; adj_bf=$(mktemp) && chmod 600 "$adj_bf" 2>/dev/null \
          && printf '%s\n' "$adj_body" > "$adj_bf" \
          && { declare -F ptg_own_post >/dev/null && ptg_own_post "$rec" "$adj_bf"; }
        [ -n "${adj_bf:-}" ] && rm -f "$adj_bf"
      fi
    fi
    # <<< adjudication issue post (BH-5799)
  fi
  case "$verdict" in
    ACCEPT)
      br_record "$p" "$rkey" adjudicate "$reason" "ACCEPT — $adj" adjudications "$url" "${head:--}"
      if [ "$reason" = iron-law ]; then
        # A head this tick could not read leaves $head empty, and the else-branch
        # below is the right answer for it: the ACCEPT marker is BOUND to a sha,
        # so writing one for a sha nobody read would unpark code nobody judged.
        head=$(br_pr_field "$url" .head.sha 'head sha')
        if [ -n "$head" ] && [ -n "$rec" ] && [ "$rec" != "-" ] && [ -d "$rec" ]; then
          # BOUND TO THE SHA IT JUDGED, exactly like the head-bound approval. A
          # push after this ruling is code nobody adjudicated and the scan must
          # bite again — bin/merge-sweep.sh and bin/merge-conductor.sh both read
          # this file name, and both key it on the head they are looking at.
          : > "$rec/iron-law-accepted-$head"
          say "$p/$rkey [iron-law]: ADJUDICATED ACCEPT — wrote $rec/iron-law-accepted-$head; the sweep and conductor unpark this sha"
          # AFTER the marker: a ledger failure leaves this head accepted and
          # only costs the next head a re-adjudication, never a false carry.
          if ! command -v ilc_record >/dev/null 2>&1; then
            say "$p/$rkey [iron-law]: carry NOT recorded (no ironlaw-carry lib) — the next head re-adjudicates"
          elif [ "$ilc_rc" != 0 ] || [ ! -s "$ilc_f" ]; then
            say "$p/$rkey [iron-law]: carry NOT recorded (no hit fingerprinted: rc $ilc_rc) — the next head re-adjudicates"
          elif ilc_n=$(ilc_record "$url" "$head" "$ilc_f"); then
            say "$p/$rkey [iron-law]: recorded $ilc_n hit fingerprint(s) for carry"
          else
            say "$p/$rkey [iron-law]: carry NOT recorded (ledger write failed after ${ilc_n:-0} row(s)) — the next head re-adjudicates"
          fi
        else
          say "$p/$rkey [iron-law]: ADJUDICATED ACCEPT but no record/head to mark — the park stands, next tick drops a rung"
        fi
      else
        # A test-tamper ACCEPT has to reach the GATE, and the gate reads plan.md
        # for a TEST-CHANGE: block. On a record we can resume we write it there
        # and re-enter the pipeline; on a pool copy (the machine is gone and the
        # hub holds only the artifacts) we carry it to the NEXT build instead —
        # bin/run-build.sh's plan stage consumes state/build-notes/<p>/<key>.md.
        local just; just=$(printf 'TEST-CHANGE: adjudicated ACCEPT by bin/blocked-resolver.sh on %s. %s\n' \
          "$(STAMP)" "$(grep -vE '^[[:space:]]*(ACCEPT|REJECT)[[:space:]]*$' "$adj" 2>/dev/null | tail -20 | tr '\n' ' ' | head -c 900)")
        if [ -n "$rec" ] && [ "$rec" != "-" ] && [ -d "$rec" ] && [ -s "$rec/plan.md" ] && [ "${rec##*/pool-}" = "${rec##*/}" ]; then
          printf '\n%s\n' "$just" >> "$rec/plan.md"
          # run-build refuses an empty ticket id, so it comes from the record
          # that already holds it (the job the build ran under, then the RESULT
          # header the relay writes); an issue-lane key is its own id.
          local tid; tid=$(jq -r '.ticket_id // ""' "$rec/job.json" 2>/dev/null)
          [ -n "$tid" ] || tid=$(sed -n 's/^TICKET_ID: //p' "$rec/RESULT" 2>/dev/null | head -1)
          [ -n "$tid" ] || tid="${tkey##*-}"
          # A RESUME IS A RE-ENQUEUE. Same gate as the rebuild rung stands in
          # front of it, and the "resuming the build" line is written only once
          # the resume is actually going to happen.
          #
          # NOTE, so nobody reads this as covered: the branch this sits in is
          # unreachable in production today. Its guard above reads
          # `${rec##*/pool-}` = `${rec##*/}`, which for any ABSOLUTE record path
          # compares a full path with a basename and is therefore never true —
          # every test-tamper ACCEPT takes the pool-copy arm below, which is
          # gated by br_rebuild_fresh's own call. The gate is here so the hole
          # does not reopen the day that guard is fixed; the fix itself is not
          # BH-408's to make (it would switch every ACCEPT from a rebuild to a
          # resume) and is named in the PR body.
          if br_hold_gate "$p" "$rkey" "$reason" "$url" "$rec" "$tkey"; then
            if [ -n "${LANE_RUN_ID:-}" ]; then
              # A LANE MACHINE BUILDS NOTHING ITSELF (BH-6128): it holds a copy
              # of the record, not the build, so the resume is a fresh enqueue.
              say "$p/$rkey [test-tamper]: ADJUDICATED ACCEPT — TEST-CHANGE written into $rec/plan.md; this run is on a lane machine, so it is rebuilt fresh"
              br_rebuild_fresh "$p" "$rkey" "$reason" "$url" "$rec" "$tkey"
            else
            say "$p/$rkey [test-tamper]: ADJUDICATED ACCEPT — TEST-CHANGE written into $rec/plan.md, resuming the build"
            # 8>&- is belt to br_cron_unlock's braces: the lane lock is already
            # released and closed by the time a rung runs, and a detached build
            # that inherited the fd would hold it for its whole life anyway.
            RESUME_BUILD="$rec" HARNESS="$H" setsid nohup "$H/bin/run-build.sh" "$p" "$tid" "$tkey" >> "$rec/blocked-resolver-resume.log" 2>&1 8>&- &
            fi
          fi
        else
          # >>> test-tamper build note
          mkdir -p "$NOTES/$p" 2>/dev/null
          printf '%s\n' "$just" > "$NOTES/$p/$tkey.md"
          # BH-5003: and the ledger row, so a build on a watcher box sees it.
          if command -v bn_put >/dev/null 2>&1 && ! bn_put "$p" "$tkey" "$NOTES/$p/$tkey.md"; then
            say "$p/$rkey [test-tamper]: build note NOT in the DB — only hub/pool builds will see it"
          fi
          # <<< test-tamper build note
          say "$p/$rkey [test-tamper]: ADJUDICATED ACCEPT — record is a pool copy and cannot be resumed; justification carried to $NOTES/$p/$tkey.md and rebuilt fresh"
          br_rebuild_fresh "$p" "$rkey" "$reason" "$url" "$rec" "$tkey"
        fi
      fi
      # THE RULING IS STORED LAST (BH-1468), at the END of the arm rather than
      # before the case, and that ordering is the contract #1471 asked for: the
      # per-PR iron-law-accepted-<head> marker is written FIRST by the code
      # above, so a module may key its family row on a marker that already
      # exists. Best effort — a store that fails must never turn an ACCEPT the
      # lane has already acted on into an error. A run with no verdict reaches
      # neither arm, which is the "a dead session stores nothing" rule for free.
      br_opt_family_store "$p" "$rkey" "$reason" "$rec" "$url" ACCEPT ;;
    REJECT)
      br_record "$p" "$rkey" adjudicate "$reason" "REJECT — $adj" adjudications "$url" "${head:--}"
      if [ "$reason" = iron-law ]; then
        say "$p/$rkey [iron-law]: ADJUDICATED REJECT — the gate was right; handing to the fix round"
        br_fix_round "$p" "$rkey" "$reason" "$url" "$rec" "$tkey"
      else
        [ -n "$url" ] && [ "$url" != "-" ] && br_pr_comment "$url" "Rebuilt fresh rather than merged: the removed tests were adjudicated REJECT. Tests are not removed to make a build pass — the rebuild must make them pass or justify each removal with a TEST-CHANGE block." >/dev/null 2>&1 || true
        say "$p/$rkey [test-tamper]: ADJUDICATED REJECT — rebuilding fresh with the tests intact"
        br_rebuild_fresh "$p" "$rkey" "$reason" "$url" "$rec" "$tkey"
      fi
      br_opt_family_store "$p" "$rkey" "$reason" "$rec" "$url" REJECT ;;
    *)
      # No word back is not a REJECT and not an ACCEPT. It is a dead session, and
      # spending an adjudication counter on silence would let one timeout decide
      # a ticket's fate.
      #
      # BUT SILENCE IS NOT FREE FOR EVER (BH-1122). Each of these ticks buys a
      # review-stage model call and throws the answer away, so after
      # BR_ADJ_NOVERDICT_MAX consecutive silent reads the park STALLS: one alert,
      # and no rung until its row changes. The count is the TRAILING run of
      # `adjudicate-noverdict` attempts, so a verdict in between resets it by
      # construction. The trail lives on the rkey record where the other
      # adjudication attempts already are; the STALLED outcome goes on the cap
      # key, because that is the record br_one reads before it dispatches.
      br_record "$p" "$rkey" adjudicate-noverdict "$reason" "no ACCEPT/REJECT in $adj"
      # A CONTRACT-FIRST CHILD NOBODY CAN RULE ON IS PAGED, ONCE (BH-1047). The
      # retry stands (silence is not a verdict and still spends no counter), but
      # the ticket asked for a rung that cannot decide to hand a person the list
      # rather than park on it quietly. One line per record: the marker is
      # touched only AFTER lane-alert returns, so a failed page is re-sent next
      # tick instead of being stamped as delivered.
      #
      # TAMPER BLOCKS ONLY. This page says "rule on these deleted cases", so it
      # belongs to the two reasons that ARE a tamper block: test-tamper and
      # rescue-real-deletion (the rescan found a real deletion, and its report
      # is where the names come from). Every other reason that can reach this
      # arm has no deleted cases to rule on, and the scanner writes
      # CONTRACT_CHILD: into the report of every `.N` child whatever blocked it,
      # so without this guard a park on another gate would page a person with
      # "rule on these deleted cases: (none named)".
      if { [ "$reason" = test-tamper ] || [ "$reason" = rescue-real-deletion ]; } \
         && [ -n "$rec" ] && [ "$rec" != "-" ] && [ -d "$rec" ] \
         && [ ! -f "$rec/.adjudicate-noverdict-paged" ] \
         && grep -qs '^CONTRACT_CHILD:' "$rec/test-tamper-rescan.txt" "$rec/test-tamper.txt"; then
        "$H/bin/lane-alert.sh" blocked-resolver "$p/$tkey [$reason]: adjudication produced no verdict on a contract-first child. A human must rule on these deleted cases: $(printf '%s' "${adj_cases:-(none named)}" | sed 's/^[[:space:]]*//' | tr '\n' ';' | sed 's/;/; /g; s/[[:space:]]*$//'). Record: $rec" >/dev/null 2>&1 \
          && : > "$rec/.adjudicate-noverdict-paged"
      fi
      silent=$(br_load "$p" "$rkey" \
        | jq -r '[.attempts[]?.action] | reverse | (map(. == "adjudicate-noverdict") | index(false) // length)' 2>/dev/null)
      case "$silent" in ''|*[!0-9]*) silent=0 ;; esac
      if [ "$silent" -ge "$ADJ_NOVERDICT_MAX" ]; then
        ck=$(br_cap_key "$p" "$rkey" "$tkey")
        br_stall "$p" "$ck" "$rkey" "$reason" "$url" "$rec" "$tkey" adjudication \
                 "no ACCEPT/REJECT in $adj after $silent reads" \
                 "$(br_stall_fp "$reason" "$url" "$rec")" "$silent"
      else
        say "$p/$rkey [$reason]: adjudication produced no ACCEPT/REJECT — retried next tick, no counter spent"
      fi ;;
  esac
  ilc_arc=$?
  [ -n "$ilc_f" ] && rm -f "$ilc_f"
  return "$ilc_arc"
}

# RE-ASK. Only for `no-verdict`, which means nobody answered — not that somebody
# said no.
#
# NO VERDICT NEVER CLOSES A PR (the operator, 2026-09-16; project-5 #1621). This rung
# used to buy ONE more re-review and, if that one was silent too, hand the PR to
# br_rebuild_fresh — which CLOSES it and enqueues a rebuild. On 2026-09-16 that
# is exactly what happened to a finished, green, approved project-5 build: the
# claude account was 429 `session limit` for the hour, both reads came back
# empty, and a build that had cost a full pipeline was closed and started again
# from scratch. Silence from OUR reviewer is not a failed event of somebody's
# PR, and the operator's standing order is that only a concrete failed event closes one.
#
# So this rung re-asks, up to BR_NOVERDICT_MAX reads, and then STOPS SPENDING
# and says so in one actionable ALERTS line. The PR stays open and parked. The
# moment a read lands — here, or on the conductor's own head-bound lane — the
# row classifies normally again. A BLOCK is still a real answer and still
# reclassifies to head-not-reapproved, where the fix-round ladder owns it.
BR_NOVERDICT_MAX="${BR_NOVERDICT_MAX:-5}"
# And a SEPARATE bound on lane failures. "No counter spent" is about fairness to
# the PR — a read it never got must not eat one of its reads — but it is not a
# licence to buy an attempt every tick forever: a lane failure can still COST
# (the grok rung runs, answers, and is discarded because it is not a Claude
# read). So the failures are counted on their own axis and stop the spending
# without ever touching the PR's read budget: when the lane comes back, this PR
# still has all BR_NOVERDICT_MAX of its reads waiting for it.
BR_LANEFAIL_MAX="${BR_LANEFAIL_MAX:-5}"
#
# THE PREFLIGHT'S RE-REVIEW IS NOT A NO-VERDICT READ (BH-1992). br_preflight
# buys a head-bound re-review when findings on an older head meet green CI at
# the new one; that is not silence from the reviewer, so it passes a 7th
# argument `preflight` and is charged to its own counter (`preflight_rereviews`)
# and logged [preflight-rereview]. It is bounded once per head by the
# preflight's own `preflight_heads`, so BR_NOVERDICT_MAX and the lane-failure cap
# do not gate it, and its lane failures are not no-verdict lane failures.
br_rereview() {
  local p="$1" rkey="$2" reason="$3" url="$4" rec="$5" tkey="$6" kind="${7:-no-verdict}"
  local evid="${8:-}" dlreason="${9:-}"
  local st n lf lfep slug num head rev outf v rc why rpkept tag ctr lfctr bought nth rrreason rrlede reused
  st=$(br_load "$p" "$rkey"); n=$(br_num "$st" rereviews); lf=$(br_num "$st" lanefails)
  if [ "$kind" = preflight ]; then
    tag=preflight-rereview; ctr=preflight_rereviews; lfctr=""; nth="the preflight's one re-review of this head"
    bought='after the fix-round preflight found the findings were posted on an older head'
  elif [ "$kind" = data-lane ]; then
    # BH-4926: bounded once per fp+head by br_data_lane_release's claim, so the
    # no-verdict caps below are skipped like the preflight's.
    tag=data-lane-rereview; ctr=data_lane_rereviews; lfctr=""; nth="the data lane's one re-review of this head"
    bought='after the data lane applied and probed the migration'
  else
    tag=no-verdict; ctr=rereviews; lfctr=lanefails; nth="read $((n+1)) of $BR_NOVERDICT_MAX"
    bought='after the conductor got no verdict'
  fi
  # ...AND THAT CAP NEEDS THE SAME RELEASE EVENT THE CONDUCTOR'S DOES
  # (BH-1019). `lanefails` only ever incremented: "this rung stops buying
  # attempts until it is fixed" named no mechanical event that counts as fixed,
  # so five lane failures during one quota outage stranded the row for good —
  # the conductor's park released when the lane came back and the resolver's cap
  # did not, which strands the same rows one lane further down. The counter is
  # therefore bound to the lane-health epoch (mc_lane_epoch, shared with the
  # conductor: the fleet auth monitor's line OR the conductor's own marker), and
  # a lane that comes back gives this rung its failures back. The PR's READ
  # budget is untouched by this, exactly as before.
  if [ "$kind" != preflight ] && [ "$kind" != data-lane ]; then
    lfep=$(mc_lane_epoch)
    if [ "$lf" -gt 0 ] && [ "$(br_num "$st" lanefail_epoch)" != "$lfep" ]; then
      br_set_num   "$p" "$rkey" lanefails 0
      br_set_field "$p" "$rkey" lanefail_epoch "$lfep"
      say "$p/$rkey [$tag]: the review lane's health changed (epoch $lfep) — the $lf lane failure(s) counted against the previous outage are forgotten; this rung may ask again"
      lf=0
    fi
    if [ "$lf" -ge "$BR_LANEFAIL_MAX" ]; then
      say "$p/$rkey [$tag]: the review lane has failed $lf times on this PR — this rung stops buying attempts until it is fixed. The PR stays OPEN and parked, and its $((BR_NOVERDICT_MAX - n)) remaining reads are still waiting for it; nothing here closes it."
      br_lane_down_alert "$p" "$rkey" "$url" "$lf"
      return 0
    fi
    if [ "$n" -ge "$BR_NOVERDICT_MAX" ]; then
      # Out of reads, and NOT out of PR. Deduped by the akey: one line per park,
      # not one per tick.
      say "$p/$rkey [$tag]: $n reads bought and not one came back with a verdict — the review lane is the broken thing, so this rung stops spending. The PR stays OPEN and parked; nothing here closes it."
      br_lane_down_alert "$p" "$rkey" "$url" "$n"
      return 0
    fi
  fi
  if [ "$OBSERVE" = 1 ]; then say "$p/$rkey [$tag]: WOULD buy another re-review ($nth) — observe mode"; return 0; fi
  # >>> br rereview post (tests/review-record-integrity-test.sh section 2 drives this block)
  slug=$(mc_slug_of_url "$url"); num=$(mc_num_of_url "$url")
  # NO READ, NO SPEND. A re-review is bought FOR a head; buying one against a
  # head this tick could not read would rebind an approval to nothing.
  head=$(br_pr_field "$url" .head.sha 'head sha'); rc=$?
  if [ "$rc" = 75 ]; then
    say "$p/$rkey [$tag]: the PR head could not be read this tick — re-review not bought, no counter spent; the park is offered again next tick"
    return 0
  fi
  rev=$(mc_row_field "$(printf '%s#%s' "$slug" "$num")" 5)
  outf=$(mktemp)
  # A VERDICT ALREADY PAID FOR ON THIS HEAD IS NOT RE-BOUGHT (BH-3930, F5).
  # review_bought answers from the D1 rows and the box history; a hit skips
  # both the llm count and the read, and the arms below run on its verdict. Only
  # class `approve` is an APPROVE; anything else is a BLOCK. A miss or a failed
  # read buys as before, under this rung's own reason (`preflight`, or
  # `brnv<n>` for no-verdict read n), so K=1 on the conductor's key never
  # refuses the ladder.
  # AN APPROVE IS REUSED ONLY WITH ITS PROVENANCE (BH-4134): one whose serving
  # lane is unknown or a fallback (review_bought_prov) is not reused, and this
  # rung buys its read as on a miss. A lead/human row is cleared (BH-1525); a
  # BLOCK merges nothing and is reused whatever served it.
  reused=""
  # A data-lane release is NOT reused: the BLOCK on this head was bought before
  # the migration was applied, and the evidence is what this read is for.
  if [ "${kind:-}" != data-lane ] && command -v review_bought >/dev/null 2>&1 && command -v review_dedupe_on >/dev/null 2>&1 \
     && review_dedupe_on && review_bought "$slug" "$num" "$head" >/dev/null 2>&1; then
    reused="${RB_SOURCE:-}"
    if [ "${RB_CLASS:-}" = approve ]; then
      case "$(review_bought_prov 2>/dev/null || echo unknown)" in
        unknown|fallback)
          say "$p/$rkey [$tag]: $RB_SOURCE's APPROVE on ${head:0:8} carries provenance '${RB_SERVED:-none}' — not reused, buying the read"
          reused="" ;;
      esac
    fi
  fi
  if [ -n "$reused" ]; then
    v=BLOCK; [ "${RB_CLASS:-}" = approve ] && v=APPROVE
    rc=0
    printf 'Not re-bought: %s already verdicted %s on %s.\n' "$RB_SOURCE" "$RB_WORD" "${head:0:12}" > "$outf"
    say "$p/$rkey [$tag]: review_skip_unchanged — $RB_SOURCE verdicted $RB_WORD on ${head:0:8}; no re-review bought"
  else
    case "${kind:-}" in preflight) rrreason=preflight ;; data-lane) rrreason="${dlreason:-data-lane}" ;; *) rrreason="brnv$(( ${n:-0} + 1 ))" ;; esac
    br_count llm
    # The data-lane release states only what br_data_lane_route checked before
    # it asked: the ledger row and the probe both name this fp.
    rrlede=""
    [ "${kind:-}" = data-lane ] && rrlede="the migration ledger says ${BR_DL_FILE:-the migration} is applied at fp ${BR_DL_FP:0:12}, and this probe file names that fp; the harness checked both before asking"
    v=$(MC_RR_REASON="$rrreason" MC_RR_EVIDENCE="${evid:-}" MC_RR_EVIDENCE_LEDE="$rrlede" mc_rereview "$slug" "$num" "$p" "$url" "$rev" "$head" "$rec" "$outf"); rc=$?
  fi
  if [ "$rc" = 0 ] && [ "$v" = APPROVE ]; then
    [ -n "$rec" ] && [ "$rec" != "-" ] && [ -d "$rec" ] && echo "$head" > "$rec/reviewed-sha"
    type job_verdict_rebind >/dev/null 2>&1 && job_verdict_rebind "$url" "$head" >/dev/null 2>&1 || true
    if [ -n "$reused" ]; then
      rpkept=$(rp_post "$rec" "$head" "$outf" "$url" "$(printf '_Re-review not bought: %s verdicted %s on this exact head (%s). Approval rebound to %s. No new review was run._' "$reused" "$RB_WORD" "${head:0:12}" "$head")") \
        || say "$p/$rkey [$tag]: the reused verdict is persisted at ${rpkept:--} but the PR comment did NOT post (gh rc $?)"
    else
      rpkept=$(rp_post "$rec" "$head" "$outf" "$url" "$(printf '_Extra re-review bought by `bin/blocked-resolver.sh` %s: APPROVE — approval rebound to %s. Static review, no build run._' "$bought" "$head")") \
        || say "$p/$rkey [$tag]: the re-review is persisted at ${rpkept:--} but the PR comment did NOT post (gh rc $?)"
    fi
    mc_transition "$(printf '%s#%s' "$slug" "$num")" WAIT_REVIEW "resolver re-review approved ${head:0:8}" "$head" "$head" "$url" APPROVE UNKNOWN "$rec" >/dev/null
    if [ -n "$reused" ]; then br_record "$p" "$rkey" re-review reused "APPROVE from $reused on record — approval rebound to ${head:0:8}, no read bought" ""
      say "$p/$rkey [$tag]: $reused's APPROVE on ${head:0:8} rebound — unparked, nothing bought"
    else br_record "$p" "$rkey" re-review "$tag" "APPROVE — approval rebound to ${head:0:8}" "$ctr"
      say "$p/$rkey [$tag]: extra re-review APPROVED ${head:0:8} — unparked"; fi
  elif [ "$rc" = 0 ] && [ -n "$v" ]; then
    if [ -n "$reused" ]; then
      rpkept=$(rp_post "$rec" "$head" "$outf" "$url" "$(printf '_Re-review not bought: %s verdicted %s on this exact head (%s). The resolver runs an agent fix round next._' "$reused" "$RB_WORD" "${head:0:12}")") \
        || say "$p/$rkey [$tag]: the reused verdict is persisted at ${rpkept:--} but the PR comment did NOT post (gh rc $?)"
    else
      rpkept=$(rp_post "$rec" "$head" "$outf" "$url" '_Extra re-review bought by `bin/blocked-resolver.sh`: BLOCK. The resolver runs an agent fix round against these findings next._') \
        || say "$p/$rkey [$tag]: the findings are persisted at ${rpkept:--} but the PR comment did NOT post (gh rc $?)"
    fi
    mc_transition "$(printf '%s#%s' "$slug" "$num")" BLOCKED_HUMAN head-not-reapproved "$head" "$rev" "$url" BLOCK UNKNOWN "$rec" >/dev/null
    if [ -n "$reused" ]; then br_record "$p" "$rkey" re-review reused "BLOCK from $reused on record — fix round next, no read bought" ""
      say "$p/$rkey [$tag]: $reused's $RB_WORD on ${head:0:8} stands — reclassified head-not-reapproved, fix round next tick, nothing bought"
    else br_record "$p" "$rkey" re-review "$tag" "BLOCK — findings posted, fix round next" "$ctr"
      say "$p/$rkey [$tag]: extra re-review BLOCKED — reclassified head-not-reapproved, fix round next tick"; fi
  elif [ "$rc" = 3 ]; then
    # DEFERRED BY THE CALL-GUARD (K3): agent-call.sh refused a repeat read of
    # this head before calling anything. Not a lane failure — no lanefail
    # counter, no lane-down alert — and not a read: nothing is spent.
    say "$p/$rkey [$tag]: the re-review was deferred by the call-guard ($(head -1 "$outf.lanefail" 2>/dev/null | cut -c1-160)) — nothing called, no counter spent; the park is offered again later"
  elif [ "$rc" = 2 ]; then
    # THE LANE FAILED, NOT THE REVIEW (mc_review_lane_failure): an account
    # limit, a dead survival ladder, a non-Claude runner. Nothing read the code,
    # so no counter is spent — a read we never got must not count as a read we
    # bought — and the next tick asks again.
    why=$(head -1 "$outf.lanefail" 2>/dev/null || true)
    br_record "$p" "$rkey" re-review-lane-failed "$tag" "${why:-the review lane failed} — no read counter spent, asked again next tick" "$lfctr"
    # WHICH OUTAGE these failures belong to, so the cap above can forget them
    # when the lane comes back (BH-1019). Re-read rather than reused: mc_rereview
    # may have marked the lane down on THIS very failure.
    [ -n "$lfctr" ] && br_set_field "$p" "$rkey" lanefail_epoch "$(mc_lane_epoch)"
    say "$p/$rkey [$tag]: the review lane failed (${why:-no detail}) — nothing read the code, so no counter spent and nothing closed; the park is offered again next tick"
  else
    br_record "$p" "$rkey" re-review "$tag" "still no verdict — asked again next tick, PR left open" "$ctr"
    say "$p/$rkey [$tag]: $nth produced no verdict either — the park is offered again next tick. The PR is NOT closed: silence from our reviewer is not a failed event of this build."
  fi
  # .account included (BH-1090): the per-account lane-down marker reads it, and
  # a sidecar left behind by the previous re-ask would name the wrong account.
  rm -f "$outf" "$outf.runner" "$outf.model" "$outf.json" "$outf.err" "$outf.events" "$outf.prompt" "$outf.promptsha" "$outf.lanefail" "$outf.account"
  # <<< br rereview post
}

# br_lane_down_alert <project> <rkey> <pr-url> <reads>
#   ONE actionable line when the review lane has swallowed every read this rung
#   bought. It names what is down, what it is holding, and who can clear it —
#   and it says out loud that the PR was NOT closed, because the whole point of
#   this rung is that it no longer closes one.
br_lane_down_alert() {
  local p="$1" rkey="$2" url="${3:--}" reads="$4" line
  line="[blocked-resolver] REVIEW LANE DOWN $p/$rkey: $reads head-bound reads were bought for this PR and not one returned a verdict (see logs/blocked-resolver.log for which failed and how). That is our review lane (claude account quota, or a survival ladder that cannot carry a review-sized prompt), not this build — so the PR is parked and left OPEN, never closed, and no rebuild was started. Clear the lane (quota/ladder) and the next tick merges it. ${url:+PR: $url}"
  if [ -x "$H/bin/lane-alert.sh" ]; then
    "$H/bin/lane-alert.sh" blocked-resolver "$line" >/dev/null 2>&1 || true
  else
    HARNESS="$H" "$H/bin/alert-line.sh" "$line"
    "$H/bin/beat.sh" "$(jq -nc --arg p "$p" --arg akey "blocked-resolver-lane-down:$p:$rkey" --arg l "$line" \
      '{kind:"fleet_alert",project:$p,akey:$akey,line:$l}')" >/dev/null 2>&1 || true
  fi
}

# STALLED (BH-1122). Not a terminal for the TICKET — nothing is closed, nothing
# is abandoned, no counter is spent — a terminal for the SPENDING. The park has
# answered the same way N times in a row and the next tick would answer it again
# for the same reason, so it leaves the candidate budget until its row changes.
#
# br_stall_fp <reason> <url> <record> — THE PARK'S ROW, as one string.
#   "Until its row changes" has to be a question this lane can answer locally on
#   every tick, so it is: the reason it was classified with, the PR, the build
#   record, and the head the conductor has on file for that PR. The head is a
#   read of state/merge-conductor/pr-state.tsv, never a gh call — a fingerprint
#   that costs an API request on every candidate is a fingerprint that goes stale
#   the first time the bucket runs out.
br_stall_fp() {
  local reason="${1:--}" url="${2:--}" rec="${3:--}" head="-" slug num
  if [ -n "$url" ] && [ "$url" != "-" ]; then
    slug=$(mc_slug_of_url "$url" 2>/dev/null)
    num=$(mc_num_of_url "$url" 2>/dev/null)
    if [ -n "$slug" ] && [ -n "$num" ]; then
      head=$(mc_row_field "$slug#$num" 4 2>/dev/null)
      [ -n "$head" ] || head="-"
    fi
  fi
  printf '%s|%s|%s|%s' "${reason:--}" "${url:--}" "${rec:--}" "$head"
}

# br_stall <project> <cap-key> <rkey> <reason> <url> <record> <ticket-key>
#          <what> <why> <fingerprint> <n>
#   THE STATE IS WRITTEN BEFORE THE SEND, always. A page that does not deliver
#   must still stop the spending, or the lane is back to paying for the same
#   answer every ten minutes with an alert nobody got; and an outcome written
#   after a failed send would be "paged but still spending". Both halves are on
#   disk first, the alert second.
br_stall() {
  local p="$1" ck="$2" rkey="$3" reason="$4" url="$5" rec="$6" tkey="$7"
  local what="$8" why="$9" fp="${10}" n="${11:-0}" line
  br_record "$p" "$ck" stalled "$reason" "$what: $why"
  br_set_outcome "$p" "$ck" STALLED
  br_set_field "$p" "$ck" stalled_fp "$fp"
  br_event resolver_stalled "$p" "$ck" "$reason" "$n identical $what outcomes in a row — $why"
  line="[blocked-resolver] STALLED $p/${tkey:--}: $n identical $what outcomes in a row — $why. No rung is spent on this park until its row changes (its reason, its PR, its build record, or its head). Fix what that reason names, then set .outcome to \"\" in state/blocked-resolver/$p/$ck.json to put it back in the stream — never delete that file, for a closed-PR park it is the only thing that re-offers the ticket. PR: ${url:--none} record: ${rec:--none}"
  if [ -x "$H/bin/lane-alert.sh" ]; then
    "$H/bin/lane-alert.sh" blocked-resolver "$line" >/dev/null 2>&1 || true
  else
    HARNESS="$H" "$H/bin/alert-line.sh" "$line"
    "$H/bin/beat.sh" "$(jq -nc --arg p "$p" --arg akey "blocked-resolver-stalled:$p:$ck" --arg l "$line" \
      '{kind:"fleet_alert",project:$p,akey:$akey,line:$l}')" >/dev/null 2>&1 || true
  fi
  say "$p/$rkey [$reason]: STALLED — $n identical $what outcomes in a row ($why); one ALERTS line written, no rung spent until its row changes"
}

# ABANDONED. The terminal, and the only thing in this lane that alerts.
#
# It is an OUTCOME RECORD. It does not ask anybody to do anything, because the
# whole point is that asking did not work: it says what this ticket is, what was
# tried, and why each attempt failed, so that the next decision about it is made
# with evidence instead of with a backlog.
br_abandon() { # br_abandon <project> <rkey> <reason> <pr-url> <record> <why> <ticket-key>
  local p="$1" rkey="$2" reason="$3" url="$4" rec="$5" why="$6" tkey="${7:--}" st lines line crc
  # rc 3 on every external arm, never 0 (BH-4667 refute 1): br_abandon_rebuild
  # and cirepair read rc 0 as "closed and ABANDONED recorded" and act on it.
  if br_is_external "$p" "$rkey" "$reason"; then
    if command -v br_xpr_terminal >/dev/null 2>&1; then
      local xrc=0; br_xpr_terminal "$@" || xrc=$?
      [ "$xrc" = 0 ] && xrc=3
      return "$xrc"
    fi
    br_xpr_parked "$p/$rkey [$reason]: external PR — never closed or rebuilt; left for the author"; return 3
  fi
  st=$(br_load "$p" "$rkey")
  [ "$(printf '%s' "$st" | jq -r '.outcome // ""')" = ABANDONED ] && return 0
  # A DATA-LANE PARK IS NEVER ABANDONED (BH-4926). The guard agrees with the
  # route (lead BLOCK on dbed6c45): it refuses ONLY a row the route parked,
  # outcome DATA_LANE, whose review is still a candidate (rc 0) or unreadable
  # (rc 2), until its one release ran or the park was handed back on this
  # fp+head. Any other row (a lead CHANGES_REQUESTED on another bug, a rebuild
  # or CI-repair cap on another failure, a record whose OLD review has a
  # DATA_LANE line) is the ladder's, and an exhausted ladder records ABANDONED.
  # A refusal is never silent: the park is escalated once (br_dl_escalate,
  # deduped on the fp), and rc 4 means nothing closed or recorded.
  if command -v dl_candidate >/dev/null 2>&1 && [ "$(printf '%s' "$st" | jq -r '.outcome // ""')" = DATA_LANE ]; then
    local dlrc=0
    br_dl_eval "$p" "${rec:--}" "$tkey" || dlrc=$?
    if [ "$dlrc" = 2 ] || { [ "$dlrc" = 0 ] \
         && [ "$(printf '%s' "$st" | jq -r '.data_lane_released // ""')" != "$BR_DL_FP $BR_DL_HEAD" ] \
         && [ "$(printf '%s' "$st" | jq -r '.data_lane_unbound // ""')" != "$BR_DL_FP $BR_DL_HEAD" ]; }; then
      # rc 2 read nothing: the park's own record names its file and fp.
      [ -n "$BR_DL_FILE" ] || BR_DL_FILE=$(printf '%s' "$st" | jq -r '.data_lane_file // "its migration"')
      [ -n "$BR_DL_FP" ] || BR_DL_FP=$(printf '%s' "$st" | jq -r '.data_lane_fp // "unreadable"')
      say "$p/$rkey [$reason]: ABANDON refused — data-lane park ($BR_DL_FILE), the row stays a data-lane park, nothing closed"
      if [ "$dlrc" = 2 ]; then
        br_dl_escalate "$p" "$rkey" "$reason" "$url" "$rkey" "$tkey" "the ladder ran out ($why), and the park's review could not be read (reviewed sha, diff or file), so nothing can release it"
      else
        br_dl_escalate "$p" "$rkey" "$reason" "$url" "$rkey" "$tkey" "the ladder ran out ($why) while the row waits on the data lane"
      fi
      return 4
    fi
  fi
  if [ "$OBSERVE" = 1 ]; then say "$p/$rkey [$reason]: WOULD abandon ($why) — observe mode"; return 0; fi
  # THE CLOSE COMES BEFORE THE STAMP (#783). A terminal recorded over a PR this
  # lane could not close is the worst of both: the ticket reads ABANDONED, the
  # PR stays open, and no later tick looks at it again. So the close is attempted
  # first and a 75 defers the whole terminal to the next tick — nothing is
  # recorded, nothing is alerted, nothing is told.
  lines=$(br_load "$p" "$rkey" | jq -r '.attempts[]? | "  - \(.at) \(.action) [\(.reason)]: \(.detail)"' 2>/dev/null)
  crc=0
  br_close_pr "$url" "Abandoned by \`bin/blocked-resolver.sh\` after its ladder was exhausted. What was tried:
$lines" || crc=$?
  if [ "$crc" = 3 ]; then
    br_xpr_parked "$p/$rkey [$reason]: $url is an external author's PR — parked for the author, nothing recorded"
    return 3
  fi
  if [ "$crc" != 0 ]; then
    say "$p/$rkey [$reason]: ABANDON deferred — the PR could not be closed this tick, so the outcome was NOT recorded; retried next tick"
    return 75
  fi
  br_record "$p" "$rkey" abandoned "$reason" "$why"
  br_set_outcome "$p" "$rkey" ABANDONED
  br_row_closed "$p" "$tkey" "$rec" "$url" abandoned "closed unmerged: resolver ladder exhausted — $why" "$reason"
  # EVERY HOLD THIS TICKET WON ENDS HERE (BH-579). The winner is gone, so the
  # PRs it was holding go back to the conductor in this same tick — waiting out
  # the ttl would park other people's work behind a ticket that is finished.
  if [ -n "$tkey" ] && [ "$tkey" != "-" ]; then
    local hf
    while IFS= read -r hf; do
      [ -n "$hf" ] || continue
      [ "$(jq -r 'select(type=="object")|.winner_key // ""' "$hf" 2>/dev/null)" = "$tkey" ] || continue
      mc_contested_release "$hf" "winner abandoned" alert
    done < <(mc_contested_list "$p")
  fi
  br_event resolver_abandoned "$p" "$rkey" "$reason" "the ladder is exhausted: $why"
  [ -n "$rec" ] && [ "$rec" != "-" ] && [ -d "$rec" ] && { : > "$rec/.blocked-resolver-abandoned"; touch "$rec/COMMENTED" 2>/dev/null; }
  # The conductor row moves to its terminal, so no later tick walks it back into
  # the pipeline and no budget ages it.
  local ckey=""
  if [ -n "$url" ] && [ "$url" != "-" ]; then
    ckey=$(mc_slug_of_url "$url")
    [ -n "$ckey" ] && mc_transition "$ckey#$(mc_num_of_url "$url")" ABANDONED "blocked-resolver: $why" "-" "-" "$url" "-" "-" "${rec:--}" >/dev/null
  fi
  # And the queue row, so the pool never re-offers it either.
  [ "$tkey" != "-" ] && command -v queue_done >/dev/null 2>&1 \
    && queue_done "$p" "$tkey" failed "ABANDONED by the blocked-resolver: $why" >/dev/null 2>&1
  # ...and the fleet's ledger (2026-09-23). The queue row is not enough on its
  # own: a watcher's triage re-offers an open ticket, bin/run-build.sh's
  # queue_put turns the failed row back into a queued one, and BH-1681 was
  # rebuilt twice after its ABANDONED (19:04, 00:06, requested_by
  # box-small). This record lives on the hub; the ledger row is what a
  # watcher can read before it enqueues. An operator releases it with
  # `jobs-client.sh ledger-put abandoned "<project> <KEY>" released`.
  [ "$tkey" != "-" ] && command -v job_ledger_put >/dev/null 2>&1 \
    && job_ledger_put abandoned "$p $tkey" abandoned "$(head -c 300 <<<"$why")" >/dev/null 2>&1
  line="[blocked-resolver] ABANDONED $p/$rkey ($reason): $why. This is an outcome record, not a review request — the agent ladder ran and did not land it. Attempts:
$lines
Evidence: ${rec:-no build record}${url:+ | $url}"
  HARNESS="$H" "$H/bin/alert-line.sh" "$line"
  "$H/bin/beat.sh" "$(jq -nc --arg p "$p" --arg akey "blocked-resolver-abandoned:$p:$rkey" --arg l "$line" \
    '{kind:"fleet_alert",project:$p,akey:$akey,line:$l}')" >/dev/null 2>&1 || true
  say "$p/$rkey [$reason]: ABANDONED — $why"
}

# ABANDON A REBUILD THAT ENDED ON A TICKET-LEVEL STOP (2026-09-16).
#
# DECOMPOSE_FAILED, PLAN_BLOCKED and a REVIEW_BLOCKED nobody rescued are not
# facts about a branch or a machine — they are facts about the TICKET, and a
# second rebuild of the same ticket against the same main ends the same way. So
# this is the terminal, and it carries the one thing the old silence never did:
# the ticket is told, once.
br_abandon_rebuild() {
  local p="$1" rkey="$2" reason="$3" url="$4" rec="$5" tkey="$6"
  local ck res oc art why
  ck=$(br_cap_key "$p" "$rkey" "$tkey")
  res=$(br_load "$p" "$ck" | jq -r '.rebuild_result // ""' 2>/dev/null)
  case "$res" in
    ''|-|null) res=$(head -1 "$rec/RESULT" 2>/dev/null) ;;
  esac
  oc="${res%% *}"; [ -n "$oc" ] || oc=UNKNOWN
  art=$(br_rebuild_artifact "$res" "$oc")
  if [ "$OBSERVE" = 1 ]; then
    say "$p/$rkey [$reason]: WOULD abandon — the fresh rebuild ended $oc (${art:-no artifact named}) — observe mode"
    return 0
  fi
  why="the fresh rebuild ended $oc (${art:-no artifact named}) — that is a ticket-level stop, another rebuild would end the same way"
  # An abandon that did not happen must not tell the ticket it did: the comment
  # is written once, ever, so sending it over a deferred terminal would leave the
  # client told about a stop the harness then keeps retrying.
  br_abandon "$p" "$ck" "$reason" "$url" "$rec" "$why" "$tkey" || return 0
  # THE STATE IS WRITTEN BEFORE THE SEND, always. A comment that goes out over a
  # record this lane never closed is a client told about a stop that then keeps
  # being retried.
  # BH-3971: a PLAN_BLOCKED stop is a QUESTION for the client, so the comment
  # quotes it. No other outcome reads the plan.
  local ex=""
  [ "$oc" = PLAN_BLOCKED ] && ex=$(br_blocked_excerpt "$p" "$rec" "$art")
  br_ticket_comment "$p" "$ck" "$tkey" "$oc" "$art" "$url" "$ex"
}

br_html_esc() { printf '%s' "${1:-}" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'; }

# br_blocked_excerpt <project> <rec> <art> — the top of a blocked plan, ready to
# quote on a client ticket (BH-3971), or NOTHING.
#   The plan is read from the first of: <rec>/plan.md, <art> when it is a path
#   readable here, and the jobs ledger's copy (BH-531, job_transcripts source
#   plan_md), which outlives the box that wrote it. A first line that is only
#   the parked marker (BLOCKED, BLOCKED-NEEDS-CLARIFICATION, # **BLOCKED** …)
#   is dropped; a line that merely contains the word is content. At most 40
#   lines and 3000 bytes, cut on a line end.
#   FAIL CLOSED: the text goes through bin/transcript-scrub.sh first, and a
#   missing or failing scrub prints nothing, so an unscrubbed plan never
#   reaches a client.
br_blocked_excerpt() {
  local p="$1" rec="$2" art="$3" src="" name job out
  [ -x "$H/bin/transcript-scrub.sh" ] || return 0
  if [ -n "$rec" ] && [ -s "$rec/plan.md" ]; then src=$(cat "$rec/plan.md" 2>/dev/null)
  elif [ "${art#/}" != "$art" ] && [ -f "$art" ] && [ -s "$art" ]; then src=$(cat "$art" 2>/dev/null)
  fi
  if [ -z "$src" ] && command -v job_for_record >/dev/null 2>&1 \
     && command -v job_transcript_get_source >/dev/null 2>&1; then
    case "$art" in */*/plan.md) name=$(basename "$(dirname "$art")") ;; *) name=$(basename "${rec:-}") ;; esac
    if [ -n "$name" ] && [ "$name" != . ] && [ "$name" != / ]; then
      job=$(job_for_record "$p" "$name" 2>/dev/null) || job=""
      [ -n "$job" ] && src=$(job_transcript_get_source "$job" plan_md 2>/dev/null)
    fi
  fi
  [ -n "$src" ] || return 0
  out=$(printf '%s\n' "$src" | "$H/bin/transcript-scrub.sh" 2>/dev/null) || return 0
  out=$(printf '%s\n' "$out" \
    | awk 'NR == 1 && /^[[:space:]]*([#*]+[[:space:]]*)*(PLAN[_ -])?BLOCKED([^_[:alnum:]][-A-Z_*:.[:space:]]*)?$/ { next }
           !seen && /^[[:space:]]*$/ { next }
           { seen = 1; print }' | head -40)
  if [ "$(printf '%s' "$out" | LC_ALL=C wc -c)" -gt 3000 ]; then
    out=$(printf '%s' "$out" | LC_ALL=C head -c 3000 | sed '$d')
  fi
  printf '%s' "$out"
}

# br_comment_refused <project> <cap-key> <ticket-key> <artifact> <what>
#   THE POST DID NOT HAPPEN, AND IT IS NOT RETRIED. The marker is written before
#   the send (a client ticket commented twice is the worse failure — the same
#   rule bin/board-closeout.sh holds), so a refusal is said out loud instead: one
#   log line and one lane alert naming the ticket and the artifact, so the fact
#   survives in the two places somebody reads.
br_comment_refused() {
  local p="$1" ck="$2" tkey="$3" art="$4" what="$5"
  say "$p/$ck: the rebuild close-out comment was REFUSED ($what) — not retried; the ABANDONED line in ALERTS.log carries the outcome"
  "$H/bin/lane-alert.sh" blocked-resolver "$p/$tkey: the fresh rebuild was abandoned and the TICKET COULD NOT BE TOLD ($what). The outcome and the evidence are in logs/ALERTS.log and ${art:-the build record}; the ticket's own thread still shows the first build's comment." >/dev/null 2>&1 || true
}

# br_ticket_comment <project> <cap-key> <ticket-key> <OUTCOME> <artifact> <parked-url> [excerpt]
#   ONE comment per ticket, ever, guarded by a marker written BEFORE the post.
#   Routed exactly as the adjudication comment is: a GitHub-Issues lane (board
#   prefix "-") gets an issue comment, a product board gets the same POST
#   bin/board-closeout.sh makes.
#   A PLAN_BLOCKED body never names the artifact path (a file on a build box the
#   client cannot open, BH-3971): it quotes [excerpt] when there is one, and says
#   plainly that the plan could not be read back when there is not.
br_ticket_comment() {
  local p="$1" ck="$2" tkey="$3" oc="$4" art="$5" url="$6" ex="${7:-}"
  local marker prefix slug issue tid base token body sentence resp quote html
  marker="$ST/$p/$ck.rebuild-commented"
  mkdir -p "$(dirname "$marker")" 2>/dev/null
  # The marker is a D1 `commented` row too (BH-2317): a wiped hub still knows.
  # A bin/ without bin/lib/comment-mark.sh (127) answers from the file alone.
  local mrc=0
  cm_has "rebuild $p $ck" - "$marker" 2>/dev/null || mrc=$?
  [ "$mrc" = 127 ] && { [ -e "$marker" ] && mrc=0; }
  if [ "$mrc" = 0 ]; then
    say "$p/$ck: this ticket has already been told about its rebuild — not posting a second comment"
    return 0
  fi
  cm_put "rebuild $p $ck" - "$marker" 2>/dev/null || : > "$marker"
  case "$oc" in
    DECOMPOSE_FAILED) sentence="the planner could not break the work into pieces it could build" ;;
    PLAN_BLOCKED)     sentence="the plan stopped on a question about what to build that the ticket does not answer" ;;
    REVIEW_BLOCKED)   sentence="the review read the diff and refused it" ;;
    *)                sentence="the build stopped there" ;;
  esac
  body="We rebuilt this ticket fresh after the first PR could not be landed, and the rebuild stopped at $oc: $sentence. The detail is in ${art:-the build record}. The parked PR ${url:--none} is closed and this ticket has no build in flight now."
  if [ "$oc" = PLAN_BLOCKED ]; then
    if [ -n "$ex" ]; then
      body="We rebuilt this ticket fresh after the first PR could not be landed, and the rebuild stopped at $oc: $sentence. The parked PR ${url:--none} is closed and this ticket has no build in flight now."
    else
      body="We rebuilt this ticket fresh after the first PR could not be landed, and the rebuild stopped at $oc: $sentence. We could not read the plan back from the machine that wrote it, so the question is not quoted here. The parked PR ${url:--none} is closed and this ticket has no build in flight now."
    fi
  fi
  prefix=$("$H/bin/fleet-conf.sh" "$p" board_prefix 2>/dev/null)
  slug=$("$H/bin/fleet-conf.sh" "$p" repo 2>/dev/null)
  if [ "$prefix" = "-" ]; then
    issue=$(sed -nE 's/^[A-Za-z]+-([0-9]+)$/\1/p' <<<"$tkey")
    if [ -z "$issue" ] || [ -z "$slug" ]; then
      br_comment_refused "$p" "$ck" "$tkey" "$art" "no repo/issue number for the issues lane (repo='${slug:--}', key='$tkey')"
      return 0
    fi
    if [ -n "$ex" ]; then
      quote=$(printf '%s\n' "$ex" | sed -E 's/^/> /; s/^> $/>/')
      body="$body

The question the plan stopped on:

$quote"
    fi
    if br_issue_comment "$slug" "$issue" "$body"; then
      say "$p/$ck: told $slug#$issue that the rebuild ended $oc"
    else
      br_comment_refused "$p" "$ck" "$tkey" "$art" "the REST comment on $slug#$issue answered HTTP $GH_REST_STATUS"
    fi
    return 0
  fi
  base=$("$H/bin/fleet-conf.sh" "$p" prod 2>/dev/null); [ "$base" = "-" ] && base=""
  token=$("$H/bin/internal-token-for.sh" "$p" 2>/dev/null) || token=""
  tid=$(br_ticket_id "$p" "$tkey" "-") || tid=""
  if [ -z "$base" ] || [ -z "$prefix" ] || [ -z "$token" ] || [ -z "$tid" ]; then
    br_comment_refused "$p" "$ck" "$tkey" "$art" "the board is not configured for this post (prod='${base:--}', prefix='${prefix:--}', token=$([ -n "$token" ] && echo yes || echo no), ticket id='${tid:--}')"
    return 0
  fi
  html="<p>$(br_html_esc "$body")</p>"
  if [ -n "$ex" ]; then
    html="$html<p>The question the plan stopped on:</p><blockquote><p>$(br_html_esc "$ex" | awk 'NR > 1 { printf "<br>" } { printf "%s", $0 }')</p></blockquote>"
  fi
  resp=$(curl -s -m 25 -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
              -H "User-Agent: curl/8" -X POST \
              -d "$(jq -nc --arg b "$html" '{body:$b}')" \
              "$base$prefix/tickets/$tid/comments" 2>/dev/null)
  # A BOARD THAT ANSWERED WITH ANYTHING ELSE HAS NOT TAKEN THE COMMENT. Same
  # check bin/board-closeout.sh makes, for the same reason: a 200 with an error
  # body recorded as a delivered comment is how a client ends up never told.
  if printf '%s' "$resp" | jq -e '(.comment // .id // .data) != null' >/dev/null 2>&1; then
    say "$p/$ck: told the board (ticket $tid) that the rebuild ended $oc"
  else
    br_comment_refused "$p" "$ck" "$tkey" "$art" "the board refused the comment: $(printf '%.160s' "$resp")"
  fi
}

# ---------------------------------------------------------------------------
# THE CONTESTED HOLD (BH-579). Who else wants the path this ticket keeps losing,
# and the hold that parks them behind it.
# ---------------------------------------------------------------------------
# br_competitors <project> <cap-key> <slug> <path> <winner-num> <winner-key>
#   Writes {loser_prs, loser_tickets, note} to
#   state/blocked-resolver/<p>/<ck>.competitors.json — one file, REWRITTEN per
#   path, because the caller reads it before asking about the next one — and
#   answers rc 0; rc 1 only
#   when the PR list could not be READ, which is never the same thing as "nobody
#   else wants it". The file is the channel because the caller cannot run this
#   in a command substitution and still see a global it set.
#
#   ONE LIST CALL, then cached per-(PR, head) file lists (mc_pr_files), capped at
#   CONTESTED_SCAN_MAX. Two PRs are never losers: the winner itself, and the
#   winner's OWN rebuild (ticket/<key>-rN carries the same ticket key). A PR this
#   harness did not author is not in harness_pr_list's answer at all.
#
#   THE 7th ARGUMENT IS THAT LIST, already read (review round 1). The competitor
#   set is per PATH — a sibling that touches only the second contested file is a
#   loser of that file's hold and of no other — so this runs once per path, and
#   the caller hoists the one open-PR list call out of the loop rather than
#   buying it again per path. Absent, it is read here, which is what any other
#   caller and every direct test gets.
br_competitors() {
  local p="$1" ck="$2" slug="$3" path="$4" wnum="$5" wkey="$6" list="${7:-}"
  local total seen=0 num url head bkey k f want line
  local prs='[]' tix='[]' note="" skipped=""
  if [ -z "$list" ]; then
    command -v harness_pr_list >/dev/null 2>&1 || return 1
    list=$(br_open_prs "$slug") || return 1
  fi
  printf '%s' "$list" | jq -e 'type == "array"' >/dev/null 2>&1 || return 1
  total=$(printf '%s' "$list" | jq 'length' 2>/dev/null); case "$total" in ''|*[!0-9]*) total=0 ;; esac
  while IFS=$'\t' read -r num url head bkey; do
    case "$num" in ''|*[!0-9]*) continue ;; esac
    [ "$num" = "$wnum" ] && continue
    # THE CAP IS DECLARED, NEVER SILENT (D12): what was not scanned is named in
    # the log and in the hold's own `why`.
    if [ "$seen" -ge "${CONTESTED_SCAN_MAX:-40}" ]; then skipped="${skipped:+$skipped }#$num"; continue; fi
    seen=$((seen+1))
    k=$(br_key_from_branch "$bkey" 2>/dev/null) || k="-"
    [ -n "$k" ] && [ "$k" = "$wkey" ] && continue
    grep -Fxq -- "$path" <<<"$(mc_pr_files "$slug" "$num" "$url" "$head" 2>/dev/null)" || continue
    prs=$(printf '%s' "$prs" | jq -c --argjson n "$num" --arg u "$url" --arg k "${k:--}" \
            '. + [{num:$n,url:$u,key:$k}]' 2>/dev/null) || return 1
  done < <(printf '%s' "$list" | jq -r '.[]? | "\(.number)\t\(.url)\t\(.headRefOid)\t\(.headRefName)"' 2>/dev/null)
  if [ -n "$skipped" ]; then
    note="scan capped at ${CONTESTED_SCAN_MAX:-40} of $total"
    say "$p/$ck: contested scan capped at ${CONTESTED_SCAN_MAX:-40} of $total open PRs — $skipped were not read and are NOT parked"
  fi
  # And the tickets that are PLANNED to touch it: a build that has not launched
  # yet is the cheapest competitor to stop (bin/triage-gate.sh reads this list).
  for f in "$H/plans/$p-"*/planned-files.txt; do
    [ -s "$f" ] || continue
    k=$(basename "$(dirname "$f")"); k="${k#"$p-"}"
    [ -n "$k" ] && [ "$k" != "$wkey" ] || continue
    while IFS= read -r want; do
      [ -n "$want" ] || continue
      case "$want" in '#'*|SOURCE:*|source:*) continue ;; esac
      # The path itself, or a directory scope that contains it. Never a string
      # prefix: a.txt is not claimed by a plan that names a.txtx.
      # shellcheck disable=SC2254
      case "$path" in
        "$want"|"$want"/*) tix=$(printf '%s' "$tix" | jq -c --arg k "$k" '. + [$k]' 2>/dev/null); break ;;
      esac
    done < "$f"
  done
  mkdir -p "$ST/$p" 2>/dev/null
  jq -nc --argjson prs "$prs" --argjson tix "$tix" --arg note "$note" \
    '{loser_prs:$prs, loser_tickets:($tix|unique), note:$note}' > "$ST/$p/$ck.competitors.json" 2>/dev/null || return 1
  return 0
}

# br_contested_hold <project> <cap-key> <slug> <pr-url> <ticket-key> <head> <paths>
#   rc 0 when the path is held and the bonus round is granted; rc 1, with ONE
#   log line saying why, for every case that leaves the ladder exactly where it
#   was — the PR list unreadable, nobody to hold, a hold that will not write.
#
#   THE ORDER IS THE DURABILITY ARGUMENT. Hold files first (tmp+rename, so a
#   reader never sees half a hold), then ONE json write that records the attempt,
#   grants the bonus and marks the ticket contested, then the loser rows, then
#   the event. A crash after the holds and before the json rewrites the same
#   holds next tick (same key, last write wins). A crash after the json leaves
#   the losers named in a live hold, so they are skipped here and parked by the
#   conductor. Nothing is ever marked contested without a hold on disk.
br_contested_hold() {
  local p="$1" ck="$2" slug="$3" url="$4" tkey="$5" head="$6" recs="$7"
  local first num list prs tix note why written="" heldpaths="" parks="" path f
  local prevpr prevhead cnum cpurl nums keys detail arr allprs='[]' alltix='[]'
  first=$(printf '%s\n' "$recs" | sed '/^$/d' | head -1)
  [ -n "$first" ] || return 1
  num=$(mc_num_of_url "$url")
  # ONE OPEN-PR LIST FOR THE WHOLE HOLD CREATION, hoisted out of the path loop
  # (review round 1, finding 3). What is PER PATH is the file match: the first
  # cut computed the loser set for the first recurring path and stamped it onto
  # every hold, so a sibling touching only the SECOND path was named by no hold,
  # parked by nobody and raced the winner exactly as before — while the second
  # path's hold parked PRs that never touch it. The file lists mc_pr_files reads
  # are cached per (PR, head), so the second path costs no API call either.
  if ! command -v harness_pr_list >/dev/null 2>&1 \
     || ! list=$(br_open_prs "$slug") \
     || [ -z "$list" ]; then
    say "$p/$ck [$tkey]: competitors unreadable (harness_pr_list failed) — contested hold not written, rebuilding as before"
    return 1
  fi
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if ! br_competitors "$p" "$ck" "$slug" "$path" "$num" "$tkey" "$list"; then
      say "$p/$ck [$tkey]: competitors unreadable (harness_pr_list failed) — contested hold not written, rebuilding as before"
      br_contested_withdraw "$written" "hold read incomplete"
      return 1
    fi
    f="$ST/$p/$ck.competitors.json"
    prs=$(jq -c '.loser_prs' "$f" 2>/dev/null); tix=$(jq -c '.loser_tickets' "$f" 2>/dev/null)
    note=$(jq -r '.note // ""' "$f" 2>/dev/null)
    [ -n "$prs" ] || prs='[]'; [ -n "$tix" ] || tix='[]'
    if [ "$prs" = '[]' ] && [ "$tix" = '[]' ]; then
      say "$p/$ck [$tkey]: $path recurs but no open PR or planned ticket touches it — nothing to hold on that path"
      continue
    fi
    IFS=$'\t' read -r prevpr prevhead < <(br_load "$p" "$ck" | jq -r --arg pr "$num" --arg h "$head" --arg path "$path" '
        [ (.conflicts // [])[]
          | select((((.pr|tostring) != $pr) or (.head != $h)) and (((.paths // []) | index($path)) != null)) ]
        | last | select(. != null) | "\(.pr)\t\(.head)"' 2>/dev/null)
    # THE `select(. != null)` IS THE POINT. `last` over an empty list is jq's
    # `null`, and `"\(null)"` renders the four letters n-u-l-l — so with no
    # earlier occurrence the `${prevpr:--}` default below never fired and the
    # hold's own `why` read `after null@null`. Selected away, the no-match case
    # prints nothing, `read` leaves both variables empty, and the defaults answer.
    why="recurred on $num@${head:0:8} after ${prevpr:--}@${prevhead:0:8}${note:+; $note}"
    if ! mc_contested_write "$p" "$slug" "$path" "$tkey" "$url" "$prs" "$tix" "" "$why"; then
      say "$p/$ck [$tkey]: contested hold could not be written — rebuilding as before"
      br_contested_withdraw "$written" "hold write incomplete"
      return 1
    fi
    written="$written$(mc_contested_file "$p" "$path")"$'\n'
    heldpaths="$heldpaths$path"$'\n'
    allprs=$(printf '%s\n%s\n' "$allprs" "$prs" | jq -sc 'add | unique_by(.num)' 2>/dev/null) || allprs='[]'
    alltix=$(printf '%s\n%s\n' "$alltix" "$tix" | jq -sc 'add | unique' 2>/dev/null) || alltix='[]'
    # EVERY LOSER IS PARKED ON THE PATH THAT NAMED IT FIRST. A PR in two holds
    # carries one reason, and the release rule (mc_contested_loser, asked with
    # the hold being released excluded) is what keeps it parked until the LAST
    # hold naming it is gone.
    while IFS=$'\t' read -r cnum cpurl; do
      [ -n "$cnum" ] || continue
      case $'\n'"$parks" in *$'\n'"$cnum"$'\t'*) continue ;; esac
      parks="$parks$cnum"$'\t'"${cpurl:--}"$'\t'"$path"$'\n'
    done < <(printf '%s' "$prs" | jq -r '.[]? | "\(.num)\t\(.url // "-")"' 2>/dev/null)
  done < <(printf '%s\n' "$recs" | sed '/^$/d')
  if [ -z "$heldpaths" ]; then
    say "$p/$ck [$tkey]: $(tr '\n' ' ' <<<"$recs")recurred but no open PR or planned ticket touches any of them — nothing to hold, rebuilding as before"
    return 1
  fi
  first=$(head -1 <<<"$heldpaths")
  arr=$(printf '%s' "$heldpaths" | sed '/^$/d' | jq -R . | jq -sc .)
  nums=$(printf '%s' "$allprs" | jq -r '[.[].num] | join(", ")' 2>/dev/null)
  keys=$(printf '%s' "$alltix" | jq -r 'join(", ")' 2>/dev/null)
  detail="hold on $(tr '\n' ' ' <<<"$heldpaths")written — winner $tkey, loser PRs ${nums:-none}, loser tickets ${keys:-none}; one bonus fix round granted"
  # ONE WRITE: the attempt, the bonus and the mark. The bonus is persisted BEFORE
  # the round runs and the mark is what stops a second hold, so they cannot come
  # apart — two writes here would let a crash grant the bonus twice.
  if ! br_json_edit "$p" "$ck" '
        .attempts += [{at:$t, action:"contested", reason:$why, detail:$d}]
        | .updated = $t
        | .fixround_bonus = ((.fixround_bonus // 0) + 1)
        | .contested = {at:$t, paths:$paths, hold:$hold}' \
        --arg t "$(STAMP)" --arg why conflict-unresolvable --arg d "$detail" \
        --argjson paths "$arr" --arg hold "$(mc_contested_file "$p" "$first")"; then
    say "$p/$ck [$tkey]: the contested hold could not be recorded on the ticket — holds withdrawn, rebuilding as before"
    br_contested_withdraw "$written" "hold could not be recorded"
    return 1
  fi
  # THE LOSERS' ROWS. mc_transition is the conductor's own writer, so the park
  # is recorded exactly like every other one — and `contested:*` is not a
  # hand-off reason, so the conductor may reclassify the row the moment it is
  # released. A loser with NO row is left alone: this lane invents no rows.
  local lnum lurl lpath row lhead lrev
  while IFS=$'\t' read -r lnum lurl lpath; do
    [ -n "$lnum" ] || continue
    row=$(mc_row_get "$slug#$lnum")
    if [ -z "$row" ]; then
      say "$p/$ck: loser #$lnum has no conductor row — left to the conductor"
      continue
    fi
    lhead=$(cut -f4 <<<"$row"); lrev=$(cut -f5 <<<"$row")
    case "$lurl" in ''|-|null) lurl=$(cut -f8 <<<"$row") ;; esac
    mc_transition "$slug#$lnum" BLOCKED_HUMAN "contested:$lpath (winner $tkey)" \
      "$lhead" "$lrev" "$lurl" - - - >/dev/null
  done <<<"$parks"
  br_event resolver_contested "$p" "$ck" conflict-unresolvable \
    "hold on $(tr '\n' ' ' <<<"$heldpaths")— winner $tkey ($url), loser PRs ${nums:-none}, loser tickets ${keys:-none}"
  return 0
}

# br_contested_withdraw <written-list> <why> — every hold this creation managed
#   to write, released, for the paths that came before the one that failed. A
#   half-written hold set parks people behind a winner nothing recorded.
br_contested_withdraw() {
  local written="${1:-}" why="${2:-withdrawn}" f
  [ -n "$written" ] || return 0
  while IFS= read -r f; do
    [ -n "$f" ] && mc_contested_release "$f" "$why" >/dev/null 2>&1
  done <<<"$written"
  return 0
}

# br_contested_sweep — once per tick, before the drain. Every hold is read and
#   ended when its winner is done with it:
#     row MERGED           -> released, no page (the happy ending)
#     row ABANDONED        -> released + alert (it was held for nothing)
#     no row, gh merged    -> released
#     no row, gh closed     -> released + alert (same shape as abandoned)
#     no row, read failed  -> left in place, one UNVERIFIABLE line, no page
#     now - created >= ttl -> released + alert
#   A TTL RELEASE IS NOT A TIME KILL: it unparks rows and closes nothing. A hold
#   whose created/ttl do not parse is MALFORMED, not expired — it holds nobody
#   (the contract decides liveness per read), it is left on disk as the evidence
#   of a bad write, and it pages nobody.
#
#   NO LOCK, ever (the operator, 2026-09-13 — we never lock and serialize): every write
#   here is either a contract-atomic file op or a row transition the conductor's
#   own writer already serialises. Bounded by the number of holds, outside
#   PER_TICK, and on the row path it costs no GitHub call at all.
br_contested_sweep() {
  local d p f repo wkey wurl created ttl now st rc malformed
  [ -d "$MC_CONTESTED_DIR" ] || return 0
  now=$(date -u +%s)
  for d in "$MC_CONTESTED_DIR"/*; do
    [ -d "$d" ] || continue
    p=$(basename "$d")
    [ -z "$ONLY" ] || [ "$p" = "$ONLY" ] || continue
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      IFS=$'\t' read -r repo wkey wurl created ttl < <(jq -r \
        'select(type=="object")|"\(.repo)\t\(.winner_key)\t\(.winner_url)\t\(.created)\t\(.ttl)"' "$f" 2>/dev/null)
      malformed=0
      case "${created:-}" in ''|*[!0-9]*) malformed=1 ;; esac
      case "${ttl:-}"     in ''|*[!0-9]*) malformed=1 ;; esac
      if [ "$malformed" = 1 ]; then
        say "contested hold $f is malformed — not live, left in place"
        continue
      fi
      if [ "$(( now - created ))" -ge "$ttl" ]; then
        br_release_hold "$f" "expired after ${ttl}s" alert
        continue
      fi
      st=$(mc_row_field "$repo#$(mc_num_of_url "$wurl")" 2)
      case "$st" in
        MERGED)    br_release_hold "$f" "winner merged" ;;
        ABANDONED) br_release_hold "$f" "winner abandoned" alert ;;
        '')
          # No row at all — the only arm that asks GitHub, and the only one that
          # can. Anything but merged/closed (open, a PR GitHub says is absent, a
          # read nobody could make) leaves the hold exactly where it is.
          #
          # THE READ IS br_pr_state, this file's own (#783), NEVER `gh pr view`
          # (docs/verification-map/gh-pr-list-rest.md): `gh pr view --json` is
          # GraphQL, and the GraphQL bucket is the one that empties first on
          # these accounts — a sweep that cannot read the winner leaves every
          # loser parked until the TTL, i.e. the feature fails exactly when the
          # fleet is busiest. It is also the three-answer contract rather than a
          # raw `gh api -q`: rc 0 a state, rc 44 the PR is absent, rc 75 GitHub
          # did not answer, with the `UNVERIFIABLE (HTTP …)` line written for us.
          # A raw read collapsed a 5xx and a rate limit into "not merged" and
          # left nothing in the log to say a read had failed at all.
          br_use_token "$repo"
          st=$(br_pr_state "$wurl"); rc=$?
          if [ "$rc" = 0 ]; then
            case "$st" in
              merged) br_release_hold "$f" "winner merged" ;;
              closed) br_release_hold "$f" "winner closed" alert ;;
            esac
          fi
          br_reset_token ;;
      esac
    done < <(mc_contested_list "$p")
  done
  return 0
}
# br_release_hold <file> <why> [alert] — mc_contested_release, except while the
#   fleet kill switch or this lane's observe flag is on, when a release would
#   move other people's rows for a tick that took no action at all.
br_release_hold() {
  local f="$1" why="$2" alert="${3:-}"
  if [ "$OBSERVE" = 1 ]; then
    say "WOULD release contested hold on $(jq -r '.path // "?"' "$f" 2>/dev/null) ($why) — observe mode"
    return 0
  fi
  mc_contested_release "$f" "$why" "$alert"
}

# ---------------------------------------------------------------------------
# The drain. ONE action per key per tick, under a PER-KEY lock.
# ---------------------------------------------------------------------------
br_one() {
  local src="$1" p="$2" rkey="$3" reason="$4" url="$5" rec="$6" tkey="$7"
  local action st slug ck ladder_action=""
  local class="" held paths="" rowhead="" num="" pslug="" sizef rec_paths bought=0
  # Set by br_hold_gate when it REFUSED a (re)start — held, or a read this box
  # could not make. Read at the hand-off release below.
  BR_HOLD_PARKED=0
  # Set when a rebuild rung found a build of this ticket already running and
  # held instead of starting another. Read after the dispatch, below.
  BR_REBUILD_WAITING=0
  BR_REBUILD_BOUGHT=0
  BR_XPR_PARKED=0
  action=$(br_action "$reason")
  slug=$("$H/bin/fleet-conf.sh" "$p" repo 2>/dev/null)
  [ -n "$slug" ] && br_use_token "$slug"
  # THE KEY IS DERIVED HERE, NOT AT DISCOVERY. br_conductor_emit asks gh for the
  # head branch before this line installs the repo's installation token, so on a
  # repo the default token cannot see it reads an empty branch and the candidate
  # arrives keyless. Every rung below wants the key — the cap counts on it, the
  # merged-guard asks the board with it, the rebuild enqueues it — so it is
  # asked for once, here, where gh can actually answer.
  # Called with stdout thrown away rather than in `$( )`: the derivation sets
  # BR_TICKET_KEY and BR_KEY_SOURCE, and a global set inside a command
  # substitution dies with the subshell (br_pr_ref's lesson). The source word is
  # the point — "derived TK-9 from the PR/record" named two places to look.
  # AN EXTERNAL PR HAS NO TICKET KEY (BH-4664): an outsider's branch name
  # (`agent/TK-245`) is not one of ours, and a key derived from it would share a
  # cap, a record and a rebuild with a ticket this PR is not.
  case "$reason|$tkey" in
    external-*) tkey="-" ;;
    *'|'|*'|-') if br_derive_ticket_key "$p" "$url" "$rec" >/dev/null; then
            tkey="$BR_TICKET_KEY"
            say "$p/$rkey: discovery carried no ticket key — derived $tkey from $(br_key_source_phrase "$BR_KEY_SOURCE")"
            br_tkey_put "$p" "$rkey" "$tkey"
          else tkey="-"; fi ;;
  esac
  # UNCHANGED SINCE THE LAST QUIET LOOK (BH-5946, bin/lib/br/opt/unchanged.sh).
  # rc 0 means the row ended on a quiet exit less than BR_UNCHANGED_RECHECK_S
  # ago and none of its local inputs moved since, so it takes no rung and makes
  # no further call. rc 3, like every quiet exit below. Asked AFTER the key
  # derivation (lead review of a102133f3): br_quiet marks the look under the
  # DERIVED key, so a row that arrived keyless fingerprinted with `-` here and
  # never matched. A keyless row pays the derivation's reads (memoised per run
  # by readmemo) before the skip; every other row still skips before any rung.
  if command -v br_opt_unchanged_skip >/dev/null 2>&1 \
     && br_opt_unchanged_skip "$p" "$rkey" "$reason" "$url" "$rec" "$tkey" "$src"; then
    br_reset_token; return 3
  fi
  # THE COUNTERS AND THE TERMINAL LIVE ON THE TICKET (br_cap_key), not on the PR
  # number: a rebuild produces a new PR, so a ladder read off the number starts
  # from zero on every rung and an ABANDONED ticket comes back under a new one.
  # Read AFTER the derivation above, or a candidate that arrived keyless would
  # count its rungs on a PR number that will not exist after the next rebuild.
  ck=$(br_cap_key "$p" "$rkey" "$tkey")
  st=$(br_load "$p" "$ck")
  # The row br_quiet marks at a quiet exit (BH-5946).
  BR_ROW=("$p" "$rkey" "$reason" "$url" "$rec" "$tkey" "$src" "$ck")
  # A TERMINAL TAKES NO RUNG (BH-1122). rc 3, not 0: PER_TICK counts rungs that
  # RAN, and an ABANDONED row at the top of a project's list used to be that
  # project's whole tick — a budget spent on reading a record and returning.
  [ "$(printf '%s' "$st" | jq -r '.outcome // ""')" = ABANDONED ] && { br_reset_token; return 3; }
  # A FIX ROUND THE HUB QUEUED IS THIS PARK'S ONE ACTION UNTIL IT IS ADOPTED
  # (BH-2674). The row is the whole state of a remote round, so this read is
  # what makes it survive a hub restart: queued or claimed holds the park (rc 3,
  # not a rung), done is adopted here, and no row falls through to the ladder.
  # A queue this box cannot read holds the park too: an outage must never let a
  # second paid round be queued behind one that may still be running.
  if command -v hub_box_builds_here >/dev/null 2>&1 && ! hub_box_builds_here      && command -v fix_round_get >/dev/null 2>&1; then
    local frow frc=0 fst
    frow=$(fix_round_get "$p" "$ck" 2>>"$LOG") || frc=$?
    case "$frc" in
      0) fst=$(printf '%s' "$frow" | jq -r '.status // ""' 2>/dev/null)
         case "$fst" in
           queued|claimed)
             say "$p/$rkey [$reason]: fix round in flight on $(printf '%s' "$frow" | jq -r '.claimed_by // .box // "?"' 2>/dev/null) ($fst since $(printf '%s' "$frow" | jq -r '.updated_at // "?"' 2>/dev/null))"
             [ "$fst" = queued ] && br_fix_unclaimed "$p" "$rkey" "$ck" "$frow"
             [ "$fst" = claimed ] && br_fix_stale_claim "$p" "$rkey" "$ck" "$frow"
             br_reset_token; return 3 ;;
           done)
             BR_READMEMO_LIVE=0 br_fix_adopt "$p" "$rkey" "$reason" "$url" "$rec" "$tkey" "$ck" "$frow"
             br_reset_token; return 0 ;;
         esac ;;
      2) ;;
      *) say "$p/$rkey [$reason]: fix-round queue unreadable, park held this tick"
         br_reset_token; return 3 ;;
    esac
  fi
  # AN EXTERNAL PR (BH-4664) takes the external module's gates and hooks, never
  # this ladder: nothing below may close, rebuild or abandon an outsider's PR.
  case "$reason" in
    external-*)
      local xrc=3
      if command -v br_opt_external_rung >/dev/null 2>&1; then
        xrc=0; BR_READMEMO_LIVE=0 br_opt_external_rung "$p" "$rkey" "$reason" "$url" "$rec" "$tkey" || xrc=$?
      else
        say "$p/$rkey [$reason]: external PR — the external module is not installed, nothing done"
      fi
      br_reset_token; return "$xrc" ;;
  esac
  # A RECORD WRITTEN BEFORE BH-4149 MAY SAY ESCALATED, and that stays terminal
  # for the review verdict, the way ABANDONED is for the ladder (#891 review,
  # item 3). Nothing stamps ESCALATED any more (the review terminal is
  # br_abandon), and old records are not backfilled. br_from_reviews
  # already skips the PR; this is the backstop for a candidate that arrives with
  # the same reason from another source. rc 3 for BH-1122's reason above — it is
  # a terminal that reads a record and returns, so it is not a rung either.
  # Scoped to the ESCALATED PR, not the ticket key, for br_from_reviews' reason
  # (#891 round 1, Important 5); a record with no stamp stays terminal.
  if [ "$reason" = review-changes-requested ] \
     && [ "$(printf '%s' "$st" | jq -r '.outcome // ""')" = ESCALATED ]; then
    case "$(printf '%s' "$st" | jq -r '.escalated_rkey // ""')" in
      ''|-|"$rkey") br_quiet escalated; br_reset_token; return 3 ;;
    esac
  fi
  # HELD IS TERMINAL FOR THE LADDER AND RE-READ ON EVERY TICK. A human's HOLD
  # parks the row; the issue itself is what un-parks it, so nothing here waits
  # for somebody to clear state by hand. Still held (or unreadable) answers rc 3,
  # which the drain does NOT count against PER_TICK — that budget counts RUNGS,
  # and this row took none.
  if [ "$(printf '%s' "$st" | jq -r '.outcome // ""')" = HELD ]; then
    # The PR url rides in as the 8th argument so an ABANDON on an already-held
    # row has something to close (BH-1460); every other path ignores it.
    if br_hold_recheck "$p" "$rkey" "$reason" "$ck" "$tkey" "$rec" "$st" "$url"; then
      st=$(br_load "$p" "$ck")
    else
      br_reset_token; return 3
    fi
  fi
  # STALLED IS A PAUSE ON THE SPENDING, RE-READ ON EVERY TICK (BH-1122). The
  # park answered the same way N times running and one alert said so; until its
  # row changes the next tick would buy the same answer again, so it costs no
  # rung and writes no line — the record and the alert already said everything.
  # The moment the row DOES change (a new head, a rebuild's new PR, a
  # re-classified reason, a different record) the ladder resumes with its
  # counters intact, and a re-hand-off from the conductor on the SAME head is
  # deliberately not a change: that is the loop this stall exists to break.
  if [ "$(printf '%s' "$st" | jq -r '.outcome // ""')" = STALLED ]; then
    local fp oldfp
    fp=$(br_stall_fp "$reason" "$url" "$rec")
    oldfp=$(printf '%s' "$st" | jq -r '.stalled_fp // ""')
    if [ "$fp" = "$oldfp" ]; then br_quiet stalled; br_reset_token; return 3; fi
    br_set_outcome "$p" "$ck" ""
    br_record "$p" "$ck" stall-cleared "$reason" "row changed: ${oldfp:--} -> $fp"
    say "$p/$rkey [$reason]: the stalled park's row changed (${oldfp:--} -> $fp) — the ladder resumes with its counters intact"
    st=$(br_load "$p" "$ck")
  fi
  # AN OPERATOR ABANDONED THIS TICKET (BH-2406). The ticket's newest build row is
  # `abandoned`, which is final: no fix round, no rebuild, no merged-guard read.
  # rc 3 for BH-1122's reason (a terminal takes no rung, so no PER_TICK slot).
  # Nothing is written to the record, so a later attempt (a newer job row) is
  # offered again with its counters intact. Asked once per ticket per tick; a
  # worker that does not answer (rc 2) leaves the ladder exactly as before.
  if [ "$tkey" != - ] && command -v job_ticket_abandoned >/dev/null 2>&1; then
    declare -gA BR_ABANDONED_MEMO 2>/dev/null || true
    local ab_k="$p/$tkey" ab_jid
    if [ -z "${BR_ABANDONED_MEMO[$ab_k]+x}" ]; then
      if ab_jid=$(job_ticket_abandoned "$p" "$tkey" 2>/dev/null); then
        BR_ABANDONED_MEMO[$ab_k]="$ab_jid"
      else
        BR_ABANDONED_MEMO[$ab_k]=""
      fi
    fi
    ab_jid="${BR_ABANDONED_MEMO[$ab_k]}"
    if [ -n "$ab_jid" ]; then
      say "$p/$rkey [$reason]: job $ab_jid for $tkey was abandoned by an operator — final, no rung"
      br_quiet job-abandoned; br_reset_token; return 3
    fi
  fi
  # IS SOMEBODY ELSE HOLDING THE PATH THIS PR CONFLICTS ON? (BH-579.) A live
  # contested hold that names this PR means another ticket won the file and is
  # landing it; a rung spent here buys the same conflict at full price and
  # races the winner. So the loser gets ONE log line and nothing else — no
  # rung, no counter, no record, and no hand-off release, because the row goes
  # back to the conductor when the hold is released, not when this tick ends.
  # Asked BEFORE the merged guard, so a loser costs zero GitHub calls.
  case "$url" in
    https://github.com/*/*/pull/*)
      if held=$(mc_contested_loser "$p" "$(mc_slug_of_url "$url")" "$(mc_num_of_url "$url")") && [ -n "$held" ]; then
        held=$(head -1 <<<"$held")
        say "$p/$rkey: held: contested $(cut -f1 <<<"$held") (winner $(cut -f2 <<<"$held"))"
        # rc 0, NOT the BH-1122 rc 3, on purpose: a held PR eats a PER_TICK slot
        # while spending nothing. PER_TICK counts rungs, so rc 3 would be the
        # tidier answer — but a hold can name up to CONTESTED_PR_SCAN_MAX (40)
        # PRs, and 40 free skips would let one hold pull the whole fleet's parks
        # into a single tick's list. The slot is the back-pressure.
        br_reset_token; return 0
      fi ;;
  esac
  # IS THIS TICKET ALREADY MERGED? Asked FIRST, before the ladder reads its
  # reason at all — including for a reason with no ladder entry, because a stale
  # park is worth closing whether or not this lane would have acted on it.
  br_already_merged "$p" "$rkey" "$reason" "$url" "$rec" "$tkey" "$slug"
  case "$?" in
    0) br_reset_token; return 0 ;;
    # GITHUB DID NOT ANSWER, so nobody knows whether this ticket landed. No rung
    # is taken on that silence; the same park is offered again next tick.
    2) say "$p/$rkey [$reason]: merged-state UNVERIFIABLE this tick — no rung taken, retried next tick"
       br_reset_token; return 0 ;;
  esac
  # A DATA-LANE PARK (BH-4926), asked after the merged guard (a parked PR that
  # merged still resolves) and before the carry seam, the CI cap and the
  # needs-human park, so nothing pushes onto a parked head. rc 3 is HELD's
  # answer (no rung, no slot); rc 5 is the release, the one rung it runs.
  case "$reason" in
    rescue-giving-up|rebuild-review-blocked|review-changes-requested)
      if command -v dl_candidate >/dev/null 2>&1; then
        br_data_lane_route "$p" "$rkey" "$reason" "$url" "$rec" "$tkey" "$ck"
        case "$?" in
          3) br_reset_token; return 3 ;;
          5) action=data-lane-release ;;
        esac
      fi ;;
  esac
  # A HUMAN ALREADY CLEARED THIS HEAD (BH-3814). A lead/human MERGE row on the
  # parked head, newer than the re-review BLOCK, is the answer the fix round
  # would be trying to earn, and the round could push code no human asked for.
  # Asked before the carry seam so no rung of the ladder runs. rc 3: no rung.
  # rc 2 (verdicts unreadable, or lead authority undecidable) keeps today's
  # ladder; the conductor still holds. The head is the PR's LIVE head, re-read
  # here (br_pr_field, the merged guard's own reader): the hand-off file names
  # the head that was parked, and a verdict on it says nothing about a push
  # since. An unreadable head keeps the ladder too.
  if [ "$(br_ladder_class "$reason")" = review-blocked ] && command -v mc_hv_override >/dev/null 2>&1; then
    case "$url" in https://github.com/*/*/pull/*)
      local hvkey hvhead
      hvkey="$(mc_slug_of_url "$url")#$(mc_num_of_url "$url")"
      if hvhead=$(br_pr_field "$url" .head.sha 'head sha') && [ -n "$hvhead" ]; then
        mc_hv_override "$hvkey" "$hvhead"
        case "$?" in
          0) say "$p/$rkey [$reason]: human verdict #$MC_HV_ID ($MC_HV_VERDICT, $MC_HV_SOURCE) stands on ${hvhead:0:8} and is newer than the re-review BLOCK — no fix round; the conductor rebinds the approval"
             br_quiet hv-stands; br_reset_token; return 3 ;;
          2) say "$p/$rkey [$reason]: the verdicts table (or lead authority) could not be read for ${hvhead:0:8} — the ladder runs as it did before BH-3814" ;;
        esac
      else
        say "$p/$rkey [$reason]: the live head could not be read — no verdict override asked; the ladder runs as it did before BH-3814"
      fi ;;
    esac
  fi
  # THE CARRY SEAM (BH-1468), asked AFTER the merged guard and BEFORE the ladder
  # reads its rung. rc 0 means the module HANDLED this row, and what that costs
  # is fixed here so the two siblings cannot disagree about it:
  #   - br_one returns 0, so the row SPENDS its PER_TICK slot and its share of
  #     NP[] — it ran under the per-key lock and it did work;
  #   - it is NOT an llm rung unless the module wrote the token itself;
  #   - the return happens BEFORE TICK_DONE is stamped, before the rebuild-cap
  #     gate and before mc_handoff_release, so the module owns its own conductor
  #     transition and its own hand-off (#1470 does mc_transition … WAIT_REVIEW).
  # These run under the lane-wide scan lock, which br_cron_unlock releases a few
  # lines further down. That call is idempotent (flock -u then exec 8>&-), so a
  # module about to do long git work may call it first and the lane's own later
  # call is a no-op. Any rc but 0 is today's path, byte for byte.
  # A data-lane release (rc 5 above) skips the four seams below: the carry
  # seam could push onto the very head the release re-reviews (lead NOTE on
  # dbed6c45), and the conflict seam, CI cap and stale rung are not its rung.
  # Each rung hook reads live (BR_READMEMO_LIVE=0, BH-5946): what it reads is
  # what it acts on, so it never takes an answer from the read memo.
  if [ "$action" != data-lane-release ] && command -v br_opt_carry_rung >/dev/null 2>&1 \
     && BR_READMEMO_LIVE=0 br_opt_carry_rung "$p" "$rkey" "$reason" "$url" "$rec" "$tkey"; then
    br_reset_token; return 0
  fi
  if [ "$action" != data-lane-release ] && command -v br_opt_conflict_rung >/dev/null 2>&1 \
     && BR_READMEMO_LIVE=0 br_opt_conflict_rung "$p" "$rkey" "$reason" "$url" "$rec" "$tkey"; then
    br_reset_token; return 0
  fi
  # THE CI REPAIR CAP (Lane D, bin/lib/br/opt/cirepair.sh): rc 0 parked this
  # tick, rc 3 already parked (a terminal: no rung, no slot), else the ladder.
  if [ "$action" != data-lane-release ] && command -v br_opt_ci_cap_rung >/dev/null 2>&1; then
    BR_READMEMO_LIVE=0 br_opt_ci_cap_rung "$p" "$rkey" "$reason" "$url" "$rec" "$tkey"
    case "$?" in 0) br_reset_token; return 0 ;; 3) br_quiet ci-parked; br_reset_token; return 3 ;; esac
  fi
  # THE AGE LADDER'S RE-PLAN (BH-3935, bin/lib/br/opt/stale.sh): rc 0 acted
  # this tick, rc 3 a terminal (no rung, no slot). A stale park NEVER reaches
  # the ladder below, whose fix round is a model call: with the module off
  # (BR_OPT_OFF=stale) or unloadable it is left where it is.
  if [ "$action" != data-lane-release ] && command -v br_opt_stale_rung >/dev/null 2>&1; then
    BR_READMEMO_LIVE=0 br_opt_stale_rung "$p" "$rkey" "$reason" "$url" "$rec" "$tkey"
    case "$?" in 0) br_reset_token; return 0 ;; 3) br_reset_token; return 3 ;; esac
  fi
  if [ "$(br_ladder_class "$reason")" = stale-replan ]; then
    say "$p/$rkey [$reason]: no stale module loaded (BR_OPT_OFF or a module that failed to source) — left where it is, no rung"
    br_reset_token; return 3
  fi
  [ "$action" = none ] && { say "$p/$rkey: reason '$reason' has no ladder entry — left where it is"; br_reset_token; return 0; }
  # WHAT THIS PARK CONFLICTS ON, AND HOW BIG IT IS (BH-579). The paths come from
  # the conductor row's RAW reason, which is where the conflicting paths were
  # written; the size comes from the sidecar mc_rebase left for this PR. Both
  # are recorded before the rung is chosen, because the rung is chosen from them.
  class=$(br_ladder_class "$reason")
  if [ "$src" = conductor ] && [ "$class" = rebase-conflict ]; then
    case "$url" in
      https://github.com/*/*/pull/*)
        pslug=$(mc_slug_of_url "$url"); num=$(mc_num_of_url "$url")
        rowhead=$(mc_row_field "$pslug#$num" 4)
        paths=$(br_paths_of_reason "$(mc_row_field "$pslug#$num" 7)")
        br_conflict_note "$p" "$ck" "$num" "$rowhead" "$paths"
        sizef=$(mc_conflict_size_file "$pslug" "$num")
        [ -r "$sizef" ] && br_note_conflict_lines "$p" "$ck" "$(cut -f1 "$sizef")"
        st=$(br_load "$p" "$ck") ;;
    esac
  fi
  # THE LADDER RESOLVES TO A RUNG HERE, before anything is logged, so the one
  # line a reader greps says what is about to RUN rather than the name of the
  # table it was looked up in. The rung is a pure function of the class and this
  # TICKET's counters (br_ladder_rung), and every word it answers is one the
  # dispatch below already had.
  if [ "$action" = ladder ]; then
    action=$(br_ladder_rung "$class" "$(br_num "$st" mechanicals)" "$(br_num "$st" fixrounds)" "$(br_fix_cap "$st")")
    say "$p/$rkey [$reason/$class]: ladder rung: $action (shape=$(br_shape "$st") mechanical=$(br_num "$st" mechanicals)/$MAX_MECHANICAL fix=$(br_num "$st" fixrounds)/$(br_fix_cap "$st") rebuilds=$(br_num "$st" rebuilds)/$(br_rebuild_cap "$st"))"
    # RUNG 1b SITS IN FRONT OF THE LADDER'S ANSWER, never instead of it: the
    # displaced action rides into br_regen_rung and is dispatched by it in this
    # same tick whenever the free merge landed nothing (br_regen_ladder). It
    # answers only for ci-red, so it never displaces the rebase-conflict rung
    # the contested hold below reads.
    ladder_action=$action; action=$(br_regen_ladder "$class" "$action")
    # >>> ejected twice: fix round first (BH-6000)
    # A PR the merge queue ejected twice failed its BATCH build (this PR merged
    # onto current main with the PRs queued ahead of it) both times. Merging
    # main and re-running the PR's own CI (rung 1, and the regenerate rung)
    # answer nothing about that build. When the conductor handed over the two
    # failing batch runs (mc_eject_runs_file, for the PR's head now), the ladder starts
    # at the fix round, whose brief carries those runs. Without the file the
    # ladder runs as before.
    if [ "$reason" = queue-ejected-twice ] && { [ "$action" = mechanical ] || [ "$action" = regen ]; } \
       && [ "$(br_num "$st" fixrounds)" -lt "$(br_fix_cap "$st")" ] && br_eject_runs "$url" "${rowhead:-}" >/dev/null; then
      say "$p/$rkey [$reason]: the conductor handed over the failing batch runs — straight to the fix round (rung 1 cannot answer a batch build red against current main)"
      ladder_action=fix-round; action=fix-round
    fi
    # <<< ejected twice: fix round first
  fi
  # THE SAME PATH, AGAIN, AND THE NEXT RUNG WOULD BE THE REBUILD (BH-579). That
  # is the TK-1529 shape: three rebuilds, one conflict, siblings still moving
  # the file. So the path is held for this ticket and the competitors are parked
  # behind it, and the ticket gets one bonus round to land instead. Once per
  # ticket — `.contested` is the mark that says the bonus was already bought.
  if [ "$action" = rebuild-fresh ] && [ "$reason" = conflict-unresolvable ] \
     && [ "$class" = rebase-conflict ] && [ -n "$paths" ] \
     && [ "$(printf '%s' "$st" | jq -r '.contested // "null"' 2>/dev/null)" = null ]; then
    rec_paths=$(br_recurring_paths "$st" "$num" "$rowhead" "$paths")
    if [ -n "$rec_paths" ]; then
      if [ -z "$tkey" ] || [ "$tkey" = "-" ]; then
        say "$p/$rkey [$reason]: $(tr '\n' ' ' <<<"$rec_paths")recurs but this park carries no ticket key — cannot name a winner, rebuilding as before"
      elif [ "$OBSERVE" = 1 ]; then
        say "$p/$rkey [$reason]: WOULD write a contested hold on $(tr '\n' ' ' <<<"$rec_paths")(winner $tkey) and grant one fix round — observe mode"
      elif br_contested_hold "$p" "$ck" "$pslug" "$url" "$tkey" "$rowhead" "$rec_paths"; then
        action=fix-round
        st=$(br_load "$p" "$ck")
        say "$p/$rkey [$reason]: contested $(tr '\n' ' ' <<<"$rec_paths")— rung 2 fix-round (bonus round, hold written)"
      fi
    fi
  fi
  # EVERY RUNG THAT WRITES OR RESTARTS READS THE TICKET FIRST (BH-2504).
  # br_hold_gate used to stand in front of the two rebuild rungs only, so a fix
  # round, a mechanical merge, a regenerate, a re-review or an abandon on a held
  # ticket never asked: on 2026-09-25 the lead's own REQUEST_CHANGES on #2476
  # (`review-changes-requested` -> fix-round) bought a round and a push 18
  # minutes after the lead's HOLD on #2353. Asked here, once the rung is known
  # and before the line that names it, so a held row spends nothing and never
  # logs a rung it did not run. Three rungs keep their own answer: the rebuilds
  # call the gate themselves (after checks this one does not make), and an
  # adjudication is a RULING, not a restart — every restart it can lead to
  # (the resume, the rebuild, the fix round's push) is gated where it happens.
  # The optional carry/conflict rungs above push only through hold_push, which
  # re-reads the hold at the push.
  # >>> needs-human park (BH-3443)
  # A review block whose only open finding is a human step waits on the person,
  # not on a rebuild (br_needs_human_park). rc 4 is that step done: the ticket
  # re-enters as a fresh build, never the abandon a second REVIEW_BLOCKED earns.
  case "$action:$reason" in
    data-lane-release:*) ;;
    *:rescue-giving-up|*:rebuild-review-blocked)
      br_needs_human_park "$p" "$rkey" "$reason" "$url" "$rec" "$tkey" "$ck" "$st"
      case "$?" in
        3) br_quiet needs-human; br_reset_token; return 3 ;;
        4) # BH-6536: a human-step-only BLOCK whose step is done is re-reviewed
           # on its built branch by bin/review-rescue.sh (shape D), not rebuilt.
           if command -v nh_sd_pending >/dev/null 2>&1 && [ -d "$rec" ] && nh_sd_pending "$rec" "$p"; then
             [ -e "$rec/.human-step-said" ] || { say "$p/$rkey [$reason]: human step done — bin/review-rescue.sh re-reviews the built branch of ${rec##*/}; no rebuild"; : > "$rec/.human-step-said"; }
             br_quiet needs-human; br_reset_token; return 3
           fi
           action=rebuild-fresh ;;
      esac ;;
  esac
  # <<< needs-human park
  case "$action" in
    rebuild-fresh|rebuild-retry|adjudicate) ;;
    *) if ! br_rung_hold_gate "$p" "$rkey" "$reason" "$url" "$rec" "$tkey"; then
         br_quiet rung-hold; br_reset_token; return 3
       fi ;;
  esac
  say "$p/$rkey [$src/$reason] -> $action (mechanical=$(br_num "$st" mechanicals) rebuilds=$(br_num "$st" rebuilds) fix=$(br_num "$st" fixrounds) adj=$(br_num "$st" adjudications) rereview=$(br_num "$st" rereviews))"
  # THE SCAN IS OVER; the lane-wide lock is released here, before any rung runs.
  # Everything above this line is reading — below it a rung can hold a machine
  # for 90 minutes, and no other tick may be waiting on that.
  br_cron_unlock
  # ONE ACTION PER TICKET PER TICK, not per rkey (BH-488). The drain below
  # dedupes on the rkey, and the same ticket can arrive under two of them: a
  # retry row keys on the CAP key (tproj-TK-9) while a conductor row for the
  # same PR keys on the number (o-tproj-9). On a tick where the conductor has
  # not yet re-classified the closed PR, both rows would act — two queue rows
  # for one ticket, and a PR closed twice. The cap key is what "the same ticket"
  # means everywhere else in this lane, so it is what the tick dedupes on.
  #
  # ASKED HERE, AFTER THE CANDIDATE LINE, AND ANSWERED ONLY BY A RUNG THAT RAN.
  # The first cut recorded the key the moment it was known — ahead of the
  # terminal reads, ahead of the merged guard, ahead of the line above, and in
  # observe mode too — so sibling rows were logged as "already took a rung"
  # when no rung had run anywhere and their candidate line never printed at all.
  # The record below therefore sits AFTER the dispatch and skips observe mode,
  # which takes no rung by definition.
  # rc 3: no rung ran, so it costs no PER_TICK slot either.
  if [ -n "${TICK_DONE:-}" ] && grep -qxF "$p/$ck" "$TICK_DONE" 2>/dev/null; then
    say "$p/$rkey: $ck already took a rung this tick under another row — no second enqueue, no slot"
    br_reset_token; return 3
  fi
  # THE POOL-BUILD CAP (BH-1457). PER_TICK counts RUNGS; this counts the rung
  # that costs a whole pool machine. Asked HERE, after the ladder has resolved,
  # because only now is it known that this park's rung IS a rebuild.
  #
  # rc 3, exactly like a HELD row: no LADDER record, no slot, no project share,
  # no PR closed, and NO hand-off release — the release below is past this
  # return, so the conductor keeps the park and re-offers it on the next tick.
  # "Untouched" is nearly true and not quite (review M1/M7): br_tkey_put may have
  # cached a derived key, br_conflict_note may have recorded conflict_lines, and
  # br_cron_unlock has already dropped the lane-wide scan lock — all of which
  # happen above this line for every row and none of which is a ladder attempt,
  # a counter or a spend.
  #
  # abandon-rebuild is NOT counted: it closes out a ticket, it starts no build.
  case "$action" in
    rebuild-fresh|rebuild-retry)
      # `grep -c` PRINTS 0 AND EXITS 1 on an empty file, so a `|| echo 0`
      # fallback here would make the count the two-line string "0 0" and the
      # comparison below an error that reads as "not capped" — which is exactly
      # how BR_REBUILDS_PER_TICK=0 bought a pool build in the first cut.
      bought=0
      [ -n "${TICK_REBUILDS:-}" ] && bought=$(grep -c . "$TICK_REBUILDS" 2>/dev/null)
      case "$bought" in ''|*[!0-9]*) bought=0 ;; esac
      if [ -n "${TICK_REBUILDS:-}" ] && [ "$bought" -ge "$REBUILD_CAP" ]; then
        # ONE LINE PER TICK, not one per refused park (review M6). A fleet at
        # BR_PER_TICK=50 with a rebuild-heavy list would otherwise print this
        # fifty times, saying the same thing about the same spent budget — the
        # shape the per-project share line already solved with CAPSAID.
        if [ -n "${TICK_CAPSAID:-}" ] && [ ! -s "$TICK_CAPSAID" ]; then
          printf 'said\n' > "$TICK_CAPSAID"
          say "$p/$rkey [$reason]: this tick has already bought $REBUILD_CAP pool build(s) (BR_REBUILDS_PER_TICK) — no rebuild started here or for any other park this tick; they are re-offered next tick"
        elif [ -z "${TICK_CAPSAID:-}" ]; then
          say "$p/$rkey [$reason]: this tick has already bought $REBUILD_CAP pool build(s) (BR_REBUILDS_PER_TICK) — no rebuild started, the park is re-offered next tick"
        fi
        br_reset_token; return 3
      fi ;;
  esac
  # TODO (#1477): a park this cap refuses does not yet age `oldest_untouched`.
  # BH-1122's walk covers rows past the break and share-capped rows, and an rc 3
  # from inside br_one is invisible to it — so a 100-minute rebuild park held
  # back by the cap reads as `-`, which means "nothing is waiting" (D11). #1477
  # carries a BR_TICK_REFUSED scratch file the parent reads to call
  # br_note_untouched; it is not on main yet, and copying its file shape here
  # would collide with it. Fixed when that seam lands.
  # A RUNG READS LIVE (BH-5946). The read memo forgets this PR and every search,
  # and nothing past this line reads from it or stores into it; the row loses
  # its quiet-look ledger line, so the next run looks at it again.
  command -v br_opt_readmemo_drop >/dev/null 2>&1 && br_opt_readmemo_drop "$url"
  BR_READMEMO_LIVE=0
  command -v br_opt_unchanged_forget >/dev/null 2>&1 && br_opt_unchanged_forget "$p" "$rkey"
  case "$action" in
    mechanical)    br_mechanical    "$p" "$rkey" "$reason" "$url" "$rec" "$tkey" ;;
    regen)         br_regen_rung    "$p" "$rkey" "$reason" "$url" "$rec" "$tkey" "$ladder_action" ;;
    rebuild-fresh) br_rebuild_fresh "$p" "$rkey" "$reason" "$url" "$rec" "$tkey" ;;
    rebuild-retry) br_rebuild_retry "$p" "$rkey" "$reason" "$url" "$rec" "$tkey" ;;
    abandon-rebuild) br_abandon_rebuild "$p" "$rkey" "$reason" "$url" "$rec" "$tkey" ;;
    fix-round)     br_fix_round     "$p" "$rkey" "$reason" "$url" "$rec" "$tkey" ;;
    adjudicate)    br_adjudicate    "$p" "$rkey" "$reason" "$url" "$rec" "$tkey" ;;
    re-review)     br_rereview      "$p" "$rkey" "$reason" "$url" "$rec" "$tkey" ;;
    data-lane-release) br_data_lane_release "$p" "$ck" "$reason" "$url" "$rec" "$tkey" ;;
  esac
  # A WAIT IS NOT A RUNG. A build of this ticket is already running, so nothing
  # was bought: the conductor's park stays (no hand-off release below), the row
  # is not this tick's ticket (no TICK_DONE line), and rc 3 keeps it out of the
  # PER_TICK budget — exactly what the HELD path does.
  if [ "$BR_REBUILD_WAITING" = 1 ]; then br_reset_token; return 3; fi
  # NOR IS A PARKED OUTSIDER PR (BH-4667): a belt that refused to close bought
  # nothing, so it costs no slot and releases no conductor park.
  if [ "${BR_XPR_PARKED:-0}" = 1 ]; then br_reset_token; return 3; fi
  # THE RUNG HAS RUN — now the ticket is this tick's, and a second row carrying
  # the same cap key is the duplicate the check above turns away. Observe mode
  # records nothing: it bought nothing, so there is nothing for a sibling row to
  # be a second of.
  if [ -n "${TICK_DONE:-}" ] && [ "$OBSERVE" = 0 ]; then
    printf '%s\n' "$p/$ck" >> "$TICK_DONE"
  fi
  # AND THE POOL BUILD IS COUNTED WHERE IT WAS BOUGHT (BH-1457) — here, past the
  # WAIT return above and skipped in observe mode, for the same two reasons the
  # line above is: a rebuild that HELD because one was already running bought
  # nothing, and observe mode buys nothing by definition.
  if [ -n "${TICK_REBUILDS:-}" ] && [ "$OBSERVE" = 0 ] && [ "$BR_REBUILD_BOUGHT" = 1 ]; then
    printf '%s\n' "$p/$ck" >> "$TICK_REBUILDS"
  fi
  # THE CONDUCTOR'S STICKY PARK IS RELEASED HERE. While a hand-off is open the
  # conductor leaves the row in BLOCKED_HUMAN and takes no action on that PR at
  # all; a rung has now run, so the PR is this lane's and the conductor may
  # classify it again on its next tick. Observe mode writes nothing: it took no
  # rung, so releasing would put the PR back in the loop this fixed for nothing.
  # A REFUSED RUNG KEEPS ITS PARK. The rung did not run — it was refused on the
  # ticket's own instruction, or on a read this box could not make — so releasing
  # the hand-off would hand that PR back to the conductor to classify and re-park
  # every tick, over a question the resolver never got to ask.
  if [ "$src" = conductor ] && [ "$OBSERVE" = 0 ] && [ -n "$url" ] && [ "$url" != "-" ] \
     && [ "$BR_HOLD_PARKED" = 0 ] \
     && [ "$(br_load "$p" "$ck" | jq -r '.outcome // ""')" != HELD ]; then
    mc_handoff_release "$(mc_slug_of_url "$url")#$(mc_num_of_url "$url")" "blocked-resolver/$action"
  fi
  br_reset_token
}

# >>> br fix-here entry
# THE OWNING BOX'S HALF OF A HOPPED FIX ROUND (BH-594; the hub's half is
# br_fix_remote). The UNCHANGED br_fix_round runs here — worktree, merge, brief,
# agent-call execute, verify, guard-silence gate, push, PR comment — and what
# belongs to the hub is turned into protocol lines instead: the setup alert and
# its episode marker, the terminal rungs (a close or a rebuild is the hub's
# call, taken on its own record), the slot ledger, and the ladder's events. The
# record comes in on stdin, so caps and marks are read from the hub's truth,
# and goes back as FIX_RECORD. Nothing after this block — the sweep, the scan,
# the drain — runs in this mode.
if [ "$BR_FIX_HERE" = 1 ]; then
  BR_FIX_SAID=0
  br_setup_blocked() { BR_FIX_SAID=1; echo "FIX_RESULT setup-blocked $(printf '%s' "$6" | base64 -w0)"; }
  br_fix_terminal()  { BR_FIX_SAID=1; echo "FIX_RESULT terminal"; }
  br_rebuild_fresh() { BR_FIX_SAID=1; echo "FIX_RESULT rebuild-fresh"; }
  br_round_begin() { :; }
  br_yield_take() { return 1; }
  br_rounds_running() { echo 0; }
  br_event() { say "EVENT $1 $2/$3 [$4] $5 (on the owning box; the hub beats it)"; }
  if [ "${#BR_FIX_ARGS[@]}" -lt 6 ]; then
    echo "blocked-resolver: --fix-here needs <project> <rkey> <reason> <url> <record> <tkey>" >&2
    exit 2
  fi
  _fh_p="${BR_FIX_ARGS[0]}"; _fh_ck=$(br_cap_key "$_fh_p" "${BR_FIX_ARGS[1]}" "${BR_FIX_ARGS[5]}")
  # The project's own lane rows (BH-7123 wave B): the hub's tick applied them
  # for its project; the hopped round reads the same rows on this box.
  br_env_for_project "$_fh_p"
  # The round reads GitHub as its project from the first call (BH-5913 audit:
  # its first PR read ran on the box's default PAT).
  BR_HOME_SLUG=$("$H/bin/fleet-conf.sh" "$_fh_p" repo 2>/dev/null) || BR_HOME_SLUG=""
  case "$BR_HOME_SLUG" in */*) br_home_token ;; *) BR_HOME_SLUG="" ;; esac
  _fh_in=$(cat)
  if printf '%s' "$_fh_in" | jq -e --arg p "$_fh_p" '.project == $p' >/dev/null 2>&1; then
    mkdir -p "$ST/$_fh_p" 2>/dev/null
    br_save "$_fh_p" "$_fh_ck" "$(printf '%s' "$_fh_in" | jq -c .)"
  else
    say "$_fh_p/${BR_FIX_ARGS[1]}: --fix-here got no usable record on stdin — working from this box's own copy"
  fi
  say "$_fh_p/${BR_FIX_ARGS[1]} [${BR_FIX_ARGS[2]}]: fix round hopped here from the hub"
  # THE HUB'S RECORD SAYS WHETHER THIS IS AN OUTSIDER'S PR (BH-4668): read off
  # the record now on disk, so the round runs with external.sh's prompt line,
  # comment and terminal word, exactly as it would have on the hub.
  if br_is_external "$_fh_p" "$_fh_ck" "${BR_FIX_ARGS[2]}"; then
    BR_XPR_ACTIVE=1
    say "$_fh_p/${BR_FIX_ARGS[1]} [${BR_FIX_ARGS[2]}]: external PR: this round runs as an outside contributor's fix round"
  fi
  if [ "$OBSERVE" = 1 ]; then
    br_setup_blocked - - - - - "blocked-resolver is in observe mode on $(hostname 2>/dev/null || echo the owning box) (flags/blocked-resolver-observe or automerge-disabled)"
  else
    trap 'br_wt_drop "the round ended"' EXIT
    trap 'br_wt_drop "the round was signalled"; mc_git_auth_clear 2>/dev/null; exit 143' TERM INT HUP
    br_fix_round "${BR_FIX_ARGS[@]}"
  fi
  echo "FIX_RECORD $(br_load "$_fh_p" "$_fh_ck" | base64 -w0)"
  [ "$BR_FIX_SAID" = 1 ] || echo "FIX_RESULT done"
  exit 0
fi
# <<< br fix-here entry

# THE HOLDS ARE SWEPT BEFORE THE DRAIN, every tick: a hold whose winner has
# merged, been abandoned or run out its window is holding PRs for nothing, and
# the drain below may offer one of those losers a rung in this very tick. It
# takes no lock and is bounded by the number of holds, so it is outside
# PER_TICK — nothing waits for it and it waits for nothing.
if [ -n "$ONLY" ]; then
  BR_HOME_SLUG=$("$H/bin/fleet-conf.sh" "$ONLY" repo 2>/dev/null) || BR_HOME_SLUG=""
  case "$BR_HOME_SLUG" in
    */*) br_home_token ;;
    *)   say "$ONLY: fleet.conf names no repo for this project — this run reads GitHub on the default credential"
         BR_HOME_SLUG="" ;;
  esac
fi
br_contested_sweep

DONE_KEYS=" "
# THE PROJECTS AN OPERATOR HAS HELD THIS LANE ON (BH-1465), in DONE_KEYS' own
# substring shape. Per tick and in memory only: the hold itself is the
# `lane-off-blocked-resolver-<project>` row, read through bin/lib/lane-gate.sh.
# The skiplist below reads it, so a project an operator stopped on purpose never
# reaches the starvation clock.
HELD_PROJECTS=" "
# THE TICKETS THIS TICK HAS ALREADY ACTED ON, one `<project>/<cap-key>` per
# line. A file rather than a variable because each row runs in its own subshell
# under the per-key lock; it is removed on exit, and a tick that cannot make one
# simply keeps the old rkey-only dedupe (br_one skips the check when it is
# unset).
TICK_DONE=$(mktemp "${TMPDIR:-/tmp}/br-tick-done.XXXXXX" 2>/dev/null) || TICK_DONE=""
# THE POOL BUILDS THIS TICK HAS BOUGHT (BH-1457), one `<project>/<cap-key>` per
# line, and a file for exactly the reason TICK_DONE is one. PER PROCESS, so two
# overlapping ticks each hold their own cap — see the .tick-budget comment for
# why that window is accepted rather than locked away. A tick that cannot
# make one takes no rebuild cap at all rather than refusing every rebuild: a
# missing scratch file is a fact about the box, never an event about a PR.
TICK_REBUILDS=$(mktemp "${TMPDIR:-/tmp}/br-tick-rebuilds.XXXXXX" 2>/dev/null) \
  || { TICK_REBUILDS=""; say "no scratch file for the rebuild ledger on $(hostname 2>/dev/null || echo this box) — BR_REBUILDS_PER_TICK cannot be counted this tick and is NOT enforced"; }
# The "already said it" mark for the rebuild cap's line, the same shape CAPSAID
# gives the per-project share (review M6). A tick that cannot make one prints the
# line per refused park, which is noisy and not wrong.
TICK_CAPSAID=$(mktemp "${TMPDIR:-/tmp}/br-tick-capsaid.XXXXXX" 2>/dev/null) || TICK_CAPSAID=""
# WHAT THIS TICK COUNTED (BH-1468), one token per line, appended by br_count at
# the site that did the thing. Same shape and same tolerance as the two ledgers
# above: a tick that cannot make one counts 0 on every field and says so once
# here, rather than once per rung.
TICK_COUNTS=$(mktemp "${TMPDIR:-/tmp}/br-tick-counts.XXXXXX" 2>/dev/null) \
  || { TICK_COUNTS=""; say "no scratch file for the tick counters on $(hostname 2>/dev/null || echo this box) — carried/mechanical/families/llm_rungs read 0 on this tick's line whatever ran"; }
# The tick's scratch goes with it: TICK_DONE, TICK_REBUILDS, TICK_COUNTS, and
# br_open_prs' one open-PR list per repo (BH-872 ∩ BH-579).
# br_load's per-tick memory of keys with no br_record row (BH-2317): one read
# per key per tick. A file, because br_load runs inside $(...).
BR_ROW_MISS="${TMPDIR:-/tmp}/br-row-miss.$$"
# The parent wait pass's tick file (BH-5741), made in the ordering block below.
BR_PARENT_TICK=""
trap 'rm -rf "${TMPDIR:-/tmp}/br-open-prs.$$" "${TMPDIR:-/tmp}/br-read-memo.$$" "$BR_ROW_MISS"; [ -n "${BR_PARENT_TICK:-}" ] && rm -f "$BR_PARENT_TICK"; [ -n "${TICK_DONE:-}" ] && rm -f "$TICK_DONE"; [ -n "${TICK_REBUILDS:-}" ] && rm -f "$TICK_REBUILDS"; [ -n "${TICK_CAPSAID:-}" ] && rm -f "$TICK_CAPSAID"; [ -n "${TICK_COUNTS:-}" ] && rm -f "$TICK_COUNTS"' EXIT
N=0
# How many rows this loop DISPATCHED, rc whatever — the wall bound's counter.
LOOKED=0
# THE PER-PROJECT SHARE (BH-870). N is the FLEET budget and still is; NP is how
# much of it each project has taken this tick, and CAPSAID is the "already said
# it" set, the same shape DONE_KEYS uses. Both are per tick: a project that hit
# its share keeps every candidate it did not reach, and they come back out of
# their own source on the next tick.
declare -A NP=()
CAPSAID=" "
# THE CANDIDATE LIST IS READ ONCE, INTO AN ARRAY (BH-980). It used to arrive
# through a process substitution, and the `break` below closed the reader while
# br_round_robin was still writing into it: awk took a SIGPIPE, so the
# `&& return 0` never fired, and the fail-open printf wrote into the same closed
# pipe — `bin/blocked-resolver.sh: line 946: printf: Broken pipe`, on every tick
# that hit its budget. An array has no writer left to break. It also gives the
# tick line below the one thing the pipe never could: the WHOLE list, so "which
# projects did this tick not reach" is a fact rather than an inference.
# THE RUNG BUDGET A PREVIOUS TICK DID NOT SPEND (BH-1457). A tick that ended on
# its WALL budget leaves rungs it was allowed and never bought; losing them
# would make BR_TICK_MAX_SECS a throughput cut rather than a latency bound. So
# the remainder is carried, once, and clamped to BR_PER_TICK — the budget may at
# most double, and a long outage can never produce one enormous tick.
#
# A dotfile in $ST for the same reason .saturation.tsv is one: br_from_rebuilds
# globs "$ST"/*/*.json. Written whole with tmp+mv.
#
# NO LOCK, AND THE WINDOW IS ACCEPTED (review I3). The cron lock is NOT the
# guard the first cut claimed: br_cron_unlock releases it at the top of the
# FIRST dispatch, so once a tick reaches a rung a second tick can scan, read
# this same carry and later clobber it — and TICK_REBUILDS is a per-process
# mktemp, so each overlapping tick carries its own rebuild cap. Two ticks live
# at once can therefore buy up to 2x BR_REBUILDS_PER_TICK between them. That is
# bounded, it is the same shape .saturation.tsv already accepts (D33: a lock
# held across a tick end would be a queue), and the per-TICKET rebuild ledger
# (br_jobs_count) is what actually stops a ticket being rebuilt twice. Making
# both a windowed on-disk ledger under flock is a real change with its own
# failure modes and belongs to whoever builds the concurrent-rung lane.
# A project run carries its own budget (BH-5913): runs of different projects
# overlap, and one shared file would hand one project's carry to another.
BUDGET_FILE="$ST/.tick-budget${ONLY:+-$ONLY}"
CARRY_IN=$(head -1 "$BUDGET_FILE" 2>/dev/null)
case "$CARRY_IN" in ''|*[!0-9]*) CARRY_IN=0 ;; esac
[ "$CARRY_IN" -le "$PER_TICK" ] || CARRY_IN="$PER_TICK"
EFF_PER_TICK=$(( PER_TICK + CARRY_IN ))
br_remote_open_prime
# The per-project share (br_per_tick_for) and the saturation alert keep reading
# BR_PER_TICK: the carry raises what the FLEET may spend this tick, never what
# one project may take of it, and the alert's arithmetic is about the knob.
# READ ABOVE THE DISCOVERY (review M12), because br_from_rebuilds bounds its own
# output by the budget: on a carried tick the fleet may spend up to twice
# BR_PER_TICK while that source would otherwise still offer only BR_PER_TICK
# candidates, and the carry would buy rungs with nothing to spend them on.
command -v br_opt_prof_stage >/dev/null 2>&1 && br_opt_prof_stage discovery
RAW=$(br_candidates)
# A PROJECT RUN SEES ONLY ITS PROJECT (BH-5913). Each source filters on ONLY,
# and this line holds it for any source that does not: runs of other projects
# are live at the same time, and a row of theirs is theirs to move.
if [ -n "$ONLY" ] && [ -n "$RAW" ]; then
  RAW=$(printf '%s\n' "$RAW" | awk -F'\t' -v p="$ONLY" '$2 == p')
fi
ORDERED=""; ORDER_RC=0
# HOW MANY THE SOURCES FOUND, and how many the pre-pass dropped. `candidates`
# stays the DISCOVERED number — it is the 785 the hub reports and the one an
# operator compares across ticks — and `retired` says what came off it, so
# candidates minus retired is what the loop below could reach.
RAWCOUNT=0; RETIRED=0; PRE_RC=0; IDX_BAD=0
if [ -n "$RAW" ]; then
  RAWCOUNT=$(printf '%s\n' "$RAW" | grep -c . 2>/dev/null)
  case "$RAWCOUNT" in ''|*[!0-9]*) RAWCOUNT=0 ;; esac
  # THE DETERMINISTIC PRE-PASS (BH-1457), before the interleave and before any
  # rung: finished rows leave the list, and every survivor gains a cost column.
  # FAIL OPEN like every other stage here — a pre-pass that produced nothing out
  # of a non-empty list is a pre-pass that broke, and a broken one must never be
  # the reason a parked ticket is not looked at.
  # THE COUNT TRAVELS IN A FILE because br_prepass runs inside a command
  # substitution. With no scratch file the pre-pass still works — rows are still
  # retired — but the COUNT cannot come back, and a tick line that says
  # `retired=0` while rows are leaving the list is the silent half of this
  # change. So it says so, once, instead of under-reporting quietly.
  command -v br_opt_prof_stage >/dev/null 2>&1 && br_opt_prof_stage prepass
  PREF=$(mktemp "${TMPDIR:-/tmp}/br-prepass.XXXXXX" 2>/dev/null) \
    || { PREF="/dev/null"; say "no scratch file for the pre-pass count on $(hostname 2>/dev/null || echo this box) — rows are still retired, but this tick's retired= is reported as 0"; }
  PRE=$(printf '%s\n' "$RAW" | br_prepass "$PREF")
  # A MISSING COUNT FILE MEANS THE PRE-PASS DID NOT FINISH (review M5). It is
  # written as the function's LAST act, so its absence on a run that produced
  # rows says the loop died part way: the surviving rows are a PREFIX of the
  # list and the rest were silently dropped. That is not a result to order and
  # spend rungs against, so it falls open to the whole list, like every other
  # stage here. `/dev/null` is the one case where absence proves nothing — the
  # box could not make the file at all, which the line above already said.
  if [ -n "$PRE" ] && { [ "$PREF" = /dev/null ] || [ -s "$PREF" ]; }; then
    [ -s "$PREF" ] && RETIRED=$(sed -n 1p "$PREF" 2>/dev/null)
    [ -s "$PREF" ] && IDX_BAD=$(sed -n 2p "$PREF" 2>/dev/null)
  elif [ -z "$PRE" ] && [ -s "$PREF" ] && [ "$(sed -n 1p "$PREF" 2>/dev/null)" = "$RAWCOUNT" ]; then
    # Every row was retired. An empty list is the honest answer, not a failure.
    RETIRED="$RAWCOUNT"
    IDX_BAD=$(sed -n 2p "$PREF" 2>/dev/null)
  else
    # rc 2 puts `+prepass-fallback` on the tick line for the reason ORDER_RC=2
    # puts `+ordering-fallback` there: a stage nobody can see fail is a stage
    # nobody fixes, and this one leaves the list uncosted AND unretired.
    say "the pre-pass did not finish over $RAWCOUNT candidates — every candidate is still offered, uncosted and unretired"
    PRE="$RAW"; PRE_RC=2; RETIRED=0
  fi
  case "$RETIRED" in ''|*[!0-9]*) RETIRED=0 ;; esac
  case "$IDX_BAD" in ''|*[!0-9]*) IDX_BAD=0 ;; esac
  [ "$PREF" = /dev/null ] || rm -f "$PREF"
  # THE CHEAPEST RUNG FIRST, WITHIN EACH PROJECT (BH-1457, review finding 2).
  # The first cut sorted by cost GLOBALLY, after br_round_robin — which undoes
  # BH-980 outright: a project whose parks are all rebuilds sits behind every
  # cheaper rung in every other project, tick after tick, and the visit ledger
  # can never rotate it in. Measured: p1 with three adjudications and p2 with one
  # rebuild at BR_PER_TICK=1 went p2,p1,p2 on main and p1,p1,p1 with a global
  # sort — and p2 then earns a STARVED page for a starvation the ordering itself
  # created.
  #
  # So cost is a WITHIN-PROJECT key, applied BEFORE the interleave. Round 1 of
  # the rotation is then every project's cheapest rung, round 2 its next, and the
  # hotfix rank still decides everything above both. The project's own ordinal
  # (first appearance) is the primary key, so the order br_round_robin sees its
  # projects in — which is its tie-break for two never-visited projects — is
  # byte-for-byte what the sources produced.
  # THE SORT ALSO DROPS THE COST COLUMN, so nothing downstream of this line ever
  # sees a ninth field — not br_round_robin, not br_rank_rows, not the loop's
  # own `read`. Three rungs, each one narrower than the last, and the floor is
  # $RAW, which every source now emits exactly eight fields wide.
  # AN EMPTY LIST IS NOT ONE EMPTY ROW (review r2/S1). `printf '%s\n' ""` writes
  # a newline, the awk below re-emits it as eight empty fields, br_round_robin
  # keeps it (it keeps an empty-project row on purpose) and the tick then reports
  # `projects=1 visited=[] skipped=[-]` for a phantom. Harmless downstream — the
  # loop `continue`s on an empty RKEY — and wrong on the one line this ticket is
  # about, which is a tick that retired its whole list.
  command -v br_opt_prof_stage >/dev/null 2>&1 && br_opt_prof_stage order
  if [ -z "$PRE" ]; then
    PRESORT=""
  else
  PRESORT=$(printf '%s\n' "$PRE" \
    | awk -F'\t' '{ if (!($2 in o)) o[$2] = ++k
                    c = $9; if (c !~ /^[0-9]+$/) c = 2
                    printf "%d\t%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n",
                           o[$2], c, $1, $2, $3, $4, $5, $6, $7, $8 }' 2>/dev/null \
    | sort -s -t$'\t' -k1,1n -k2,2n 2>/dev/null | cut -f3- 2>/dev/null)
  if [ -n "$PRESORT" ]; then
    PRE="$PRESORT"
  else
    say "the cost ordering fell back to source order (the within-project sort produced nothing) — every candidate is still offered, dearest rungs no longer last"
    PRESORT=$(printf '%s\n' "$PRE" | cut -f1-8 2>/dev/null)
    if [ -n "$PRESORT" ]; then PRE="$PRESORT"; else PRE="$RAW"; fi
  fi
  fi
  ORDERED=$(printf '%s\n' "$PRE" | br_round_robin) || ORDER_RC=$?
  # A HOTFIX PARK CAN NEVER FALL PAST BR_PER_TICK (#643 fix 1, BH-646). The rank
  # is a SORT KEY, not a separate queue: every candidate the sources found is
  # still here, behind the ranked ones. It is applied LAST, after the
  # per-project interleave above — br_round_robin rotates rows across projects,
  # so a rank-0 park sitting fifth in its project's rows would otherwise land
  # fifth in the tick. priority_sort_tsv's `-s` is what keeps the interleave
  # byte-for-byte inside one rank band, and the rank column is stripped again
  # before the PER_TICK loop ever sees a row.
  #
  # Fail-open twice over: no hotfix-lib on the box (or flags/hotfix-lane-off,
  # which ranks every ticket 2) and ORDERED stays exactly what br_round_robin
  # wrote — today's behaviour, byte for byte.
  if [ -n "$ORDERED" ] \
     && command -v priority_rank_meta >/dev/null 2>&1 \
     && command -v priority_sort_tsv >/dev/null 2>&1; then
    # BH-5741: br_rank_rows writes each BLOCKed parent it saw here, for the
    # parent wait pass after the loop. No file = ranking still runs, no alert.
    if command -v br_opt_parent_wait >/dev/null 2>&1; then
      BR_PARENT_TICK=$(mktemp "${TMPDIR:-/tmp}/br-parent.XXXXXX" 2>/dev/null) \
        || { BR_PARENT_TICK=""; say "no scratch file for the parent wait pass — parents are still ranked, no parent alert this tick"; }
    fi
    RANKED=$(printf '%s\n' "$ORDERED" | br_rank_rows | priority_sort_tsv 1 | cut -f2-)
    [ -n "$RANKED" ] && ORDERED="$RANKED"
  fi
fi
CANDS=()
[ -n "$ORDERED" ] && mapfile -t CANDS <<<"$ORDERED"
# EVERY CANDIDATE IS A HAND-OFF THIS LANE OWNS (BH-5125). A row on this list is
# the resolver's own statement that the park is its to move, so it is claimed
# here and the sweep at the end of the tick holds the tick to it: acted, or a
# HANDOFF-WAIT line saying why not, or one page once it has sat silent for
# BR_HANDOFF_SILENT_PAGE_S.
BHW_ON=0
# >>> one-PR run (BH-6000)
# BR_ONLY_PR=<owner/repo>#<n>: the merge conductor started this run for ONE
# park (a queue-ejected-twice PR whose fix round must start now,
# mc_eject_fix_now). Every other candidate is left to the normal ticks; this
# run works only the rows whose URL is that PR. Unset: every candidate, as before.
if [ -n "${BR_ONLY_PR-}" ]; then
  _bro_url="https://github.com/${BR_ONLY_PR%#*}/pull/${BR_ONLY_PR##*#}"
  _bro=()
  for LINE in ${CANDS[@]+"${CANDS[@]}"}; do
    IFS=$'\t' read -r _ _ _ _ XURL _ <<<"$LINE"
    [ "$XURL" = "$_bro_url" ] && _bro+=("$LINE")
  done
  say "one-PR run for $BR_ONLY_PR: ${#_bro[@]} of ${#CANDS[@]} candidate(s) are its rows"
  CANDS=(${_bro[@]+"${_bro[@]}"})
  # The filter is this run's own: no fix-round child or nested resolver call
  # inherits it (lead review lr-6024). br_only_pr_run, unexported, tells
  # br_untouched_alert that this run saw one PR only, so it ends no episode.
  br_only_pr_run="$BR_ONLY_PR"; unset BR_ONLY_PR
fi
# <<< one-PR run
if command -v bhw_tick_begin >/dev/null 2>&1 && bhw_tick_begin; then
  BHW_ON=1
  for LINE in ${CANDS[@]+"${CANDS[@]}"}; do
    IFS=$'\t' read -r XSRC XP _ XREASON XURL _ XTKEY _ <<<"$LINE"
    [ -n "${XP:-}" ] || continue
    bhw_claim "$XP" "${XTKEY:--}" "${XURL:--}" "resolver:${XSRC:--}" 0 "${XREASON:--}"
    bhw_seen "$XP" "${XTKEY:--}" "${XURL:--}"
  done
fi
# Every project the stream holds, in the order it is offered: the denominator of
# the tick line, and the list the starvation check walks. The empty-project
# bucket is "-" here exactly as it is in NP below.
ALLSEEN=" "; ALLORDER=""; NPROJ=0
for LINE in ${CANDS[@]+"${CANDS[@]}"}; do
  IFS=$'\t' read -r _ XP _ <<<"$LINE"
  XPB="${XP:--}"
  case "$ALLSEEN" in
    *" $XPB "*) ;;
    *) ALLSEEN="$ALLSEEN$XPB "; ALLORDER="${ALLORDER:+$ALLORDER }$XPB"; NPROJ=$((NPROJ+1)) ;;
  esac
done
# VISITED is the same substring-set shape DONE_KEYS and CAPSAID use; VISITLIST is
# the same thing in visit order, for the line. STOPREASON is decided by the
# loop's own exit and never inferred afterwards (D9/D13): `budget` only when the
# break below actually ran.
VISITED=" "; VISITLIST=""; STOPREASON=drained; BR_EXIT=0
NOW_TICK=$(date -u +%s)
# HOW OLD IS THE OLDEST THING THIS TICK DID NOT TOUCH (BH-1122). `rungs=4/4
# reason=budget` reads the same whether the lane is one rung behind or seven
# hours behind, which is how hub #679 sat 434 minutes past its TTL with a tick
# line on it every ten minutes. Only candidates the loop never DISPATCHED count:
# a row that answered rc 3 (held, stalled, a tick dedupe) was looked at.
OLDEST_MIN=""; BREAKAT=""; LIDX=-1
br_note_untouched() {
  local e="${1:--}"
  case "$e" in ''|-|*[!0-9]*) return 0 ;; esac
  if [ -z "$OLDEST_MIN" ] || [ "$e" -lt "$OLDEST_MIN" ]; then OLDEST_MIN="$e"; fi
  if command -v br_untouched_note >/dev/null 2>&1; then br_untouched_note "${2:--}" "$e"; fi
  return 0
}
command -v br_opt_prof_stage >/dev/null 2>&1 && br_opt_prof_stage loop
for LINE in ${CANDS[@]+"${CANDS[@]}"}; do
  LIDX=$((LIDX+1))
  IFS=$'\t' read -r SRC P RKEY REASON URL REC TKEY PARKED <<<"$LINE"
  [ -n "${RKEY:-}" ] || continue
  # THIS PROJECT'S LANE ROWS (BH-7123 wave B): applied as the row's project
  # changes, memoised, the tick budgets kept fleet-wide (br_env_for_project).
  br_env_for_project "$P"
  [ -z "$BR_HOME_SLUG" ] || br_home_token
  # >>> project hold
  # IS THIS PROJECT HELD (BH-1465)? Asked here — above the budget break, above
  # the DONE_KEYS mark, and a long way above br_one — because a held candidate
  # was never looked at: it buys no agent round, takes no lock, spends no rung
  # and stamps no visit, so the rungs it would have used go to the projects that
  # are running. A second copy of the same park is skipped by the same branch.
  # The check is one memoised lookup per project per tick, and a box mid-sync
  # that carries this script without the gate library runs exactly as today.
  if [ -n "${P:-}" ] && [ "$P" != "-" ] \
     && command -v lane_project_held >/dev/null 2>&1 \
     && lane_project_held blocked-resolver "$P"; then
    case "$HELD_PROJECTS" in
      *" $P "*) ;;
      *) HELD_PROJECTS="$HELD_PROJECTS$P "
         HELDN=0
         for HELDLINE in ${CANDS[@]+"${CANDS[@]}"}; do
           IFS=$'\t' read -r _ HELDP _ <<<"$HELDLINE"
           if [ "${HELDP:--}" = "$P" ]; then HELDN=$((HELDN+1)); fi
         done
         say "$P: held — flags/$LANE_HELD_FLAG is set, so its $HELDN candidate(s) wait; no rung is spent on it and no visit is stamped for it" ;;
    esac
    [ "$BHW_ON" = 1 ] && bhw_ack "$P" "${TKEY:--}" "${URL:--}" held
    br_note_untouched "${PARKED:--}"
    continue
  fi
  # <<< project hold
  # THE TICK'S WALL BUDGET (BH-1457). Asked BEFORE the rung budget, because a
  # tick that is out of time is out of time whatever its rungs say.
  #
  # IT IS GATED ON `LOOKED`, NOT ON `N` (review I2). The guarantee this gate
  # buys is that a tick ALWAYS DOES SOMETHING — discovery is inside the budget
  # (TICK_START is taken when the tick takes its lock), so on a fleet with 785
  # candidates a small cap can be spent before the loop starts, and a lane that
  # then looked at nothing would do nothing, for ever, logging exactly like a
  # quiet tick. The first cut gated on N, the RUNG counter, which only moves on
  # a non-rc-3 return — and every terminal, held, stalled, deduped and
  # cap-refused row returns rc 3. A tick whose rows are all held therefore kept
  # N at 0 and walked all 785 of them unbounded, and those rows are not free:
  # br_hold_gate and br_hold_recheck read GitHub. LOOKED counts every row this
  # loop dispatched, whatever it answered, so the bound now holds on the tick
  # shape it was written for while the "at least one row" floor still stands.
  #
  # RUNGS ARE SERIAL AND STAY SERIAL. A bounded pool was the other half of the
  # ask and this lane cannot hold one safely today, for ONE sufficient reason:
  # br_cron_unlock releases the LANE-WIDE scan lock from inside the first rung's
  # dispatch — flock lives on the open file description, so the unlock in one
  # subshell releases the parent's, and the first rung to reach the dispatch
  # would drop the tick's single-flight guard while others are still scanning.
  # A second reason is real but not a blocker: NP, CAPSAID and VISITED are
  # parent-shell ledgers a background subshell cannot write, so a pool's parent
  # would have to update them after `wait`, the way mc_count_inc already does
  # for the conductor's concurrent workers. Two reasons the first cut gave here
  # were WRONG and are struck: an exported GH_TOKEN is per process, so two rungs
  # in two subshells each hold their own and cannot clobber one another; and
  # mc_row_put does take a flock — what is unlocked is the get/put PAIR inside
  # mc_transition, a lost-update window only for two rungs on the same key,
  # which the per-key lock already prevents.
  if [ "$BR_HAVE_EPOCH" = 1 ]; then TICK_NOW=$EPOCHSECONDS; else TICK_NOW=$(date -u +%s); fi
  if [ "$TICK_MAX" -gt 0 ] && [ "$LOOKED" -gt 0 ] \
     && [ "$(( TICK_NOW - TICK_START ))" -ge "$TICK_MAX" ]; then
    STOPREASON=tick-budget; BREAKAT="$LIDX"; break
  fi
  if [ "$N" -ge "$EFF_PER_TICK" ]; then STOPREASON=budget; BREAKAT="$LIDX"; break; fi
  # ONE ACTION PER KEY PER TICK, even when two sources report the same park (a
  # conductor row and a build record for the same ticket is the normal case).
  case "$DONE_KEYS" in *" $P/$RKEY "*) continue ;; esac
  DONE_KEYS="$DONE_KEYS$P/$RKEY "
  # Bash refuses an EMPTY associative subscript ("bad array subscript"), and
  # br_round_robin deliberately keeps a candidate whose project field is empty
  # rather than dropping it, so that line gets the "-" bucket here.
  PB="${P:--}"
  PCAP=$(br_per_tick_for "$P")
  if [ "${NP[$PB]:-0}" -ge "$PCAP" ]; then
    case "$CAPSAID" in
      *" $PB "*) ;;
      *) CAPSAID="$CAPSAID$PB "
         say "$P: its share of this tick is spent ($PCAP rungs, BR_PER_TICK=$PER_TICK) — its remaining candidates wait for the next tick" ;;
    esac
    br_note_untouched "${PARKED:--}" "$PB"
    continue
  fi
  # THIS TICK IS NOW LOOKING AT THIS PROJECT (BH-980). Stamped BEFORE the rung
  # runs, not after: a fix round holds the subshell for up to 90 minutes and a
  # tick killed inside one must still have moved its project to the back of the
  # order, or the same project is first again on the next tick and the one behind
  # it waits another ten minutes for nothing.
  case "$VISITED" in
    *" $PB "*) ;;
    *) VISITED="$VISITED$PB "; VISITLIST="${VISITLIST:+$VISITLIST }$PB"
       if [ "$PB" != "-" ]; then
         read -r VLV VFS VLA <<<"$(br_visited_row "$PB")"
         [ "$VFS" != 0 ] || VFS="$NOW_TICK"
         br_visited_put "$PB" "$NOW_TICK" "$VFS" "$VLA"
       fi ;;
  esac
  # EVERY ROW THIS LOOP DISPATCHES, whatever it answers (review I2). N is the
  # RUNG budget and counts only rungs that ran; LOOKED is what the wall bound is
  # measured against, so a tick made entirely of held rows is bounded too.
  LOOKED=$((LOOKED+1))
  hb_tick blocked-resolver "$P/$RKEY"
  mkdir -p "$ST/$P" 2>/dev/null
  # PER-KEY, NEVER GLOBAL. A fix round holds this for up to 90 minutes; one
  # global lock would put the whole fleet's drain behind one slow build, which
  # is the same "nothing is moving and nothing says so" this lane exists to end.
  RC=0
  # The row br_event acks against (bhw_event_ack), inside the subshell below.
  BHW_P="$P"; BHW_TKEY="${TKEY:--}"; BHW_URL="${URL:--}"
  [ "$BHW_ON" = 1 ] || BHW_P=""
  command -v br_opt_prof_row_begin >/dev/null 2>&1 && br_opt_prof_row_begin
  (
    exec 9>"$H/locks/blocked-resolver-$P-$RKEY.lock"
    # A HELD KEY LOCK IS A ROUND ALREADY RUNNING, and it says so (BH-5125): this
    # exit used to be silent. rc stays 0 on purpose, so the rung accounting
    # below counts it exactly as it always has.
    flock -n 9 || {
      say "$P/$RKEY: key lock held — a round for it is already running (locks/blocked-resolver-$P-$RKEY.lock); not dispatched this tick"
      [ -n "$BHW_P" ] && bhw_ack "$P" "${TKEY:--}" "${URL:--}" lock-held
      exit 0
    }
    # EVERY exit path drops the ledger row, a kill included — a slot a dead
    # round still holds is a slot nothing ever gives back. And since BH-1363 it
    # drops the round's WORKTREE first: the ledger row is freed only once the
    # gigabytes are gone, so a slot is never handed back while its scratch tree
    # is still on the disk.
    trap 'br_wt_drop "the round ended"; br_round_end' EXIT
    # A SIGNAL CLEANS UP AFTER THE AGENT, NOT UNDER IT. Bash does run the EXIT
    # trap when a signal kills it — but it runs it AT ONCE, abandoning the wait
    # on the agent, and `timeout` has put that agent in a process group of its
    # own, so a kill aimed at this lane leaves it writing into the worktree the
    # EXIT trap is deleting. With this trap the round finishes waiting on its
    # agent and then cleans up after it. 143 = 128 + SIGTERM, the rc a shell
    # killed by that signal reports.
    trap 'br_wt_drop "the round was signalled"; mc_git_auth_clear 2>/dev/null; br_round_end; exit 143' TERM INT HUP
    br_one "$SRC" "$P" "$RKEY" "$REASON" "${URL:--}" "${REC:--}" "${TKEY:--}"
  ) </dev/null || RC=$?
  command -v br_opt_prof_row_end >/dev/null 2>&1 && br_opt_prof_row_end "$P" "$RKEY" "$SRC" "$REASON" "$RC"
  [ -n "$BHW_P" ] && bhw_ack "$P" "${TKEY:--}" "${URL:--}" dispatched
  BHW_P=""
  # rc 3 = the row is HELD and took no rung. PER_TICK counts RUNGS, so a held
  # candidate must not eat a slot: one held ticket at the top of the list would
  # otherwise starve the whole drain, at zero cost and in silence. The project
  # share counts the same thing for the same reason — a held ticket at the top
  # of a capped project would otherwise be that project's entire tick.
  [ "$RC" = 3 ] || { N=$((N+1)); NP[$PB]=$(( ${NP[$PB]:-0} + 1 )); }
  # OFF THE HUB, EVERY CANDIDATE'S WRITES REACH THE HUB BEFORE THE NEXT ONE
  # (BH-6128). A write-back that fails stops the run: no later rung runs on
  # state the hub has not received, and the run exits 75.
  if [ -n "${LANE_RUN_ID:-}" ] && command -v lri_checkpoint >/dev/null 2>&1 \
     && ! BR_CKPT=$(lri_checkpoint blocked-resolver "$PB" 2>&1); then
    say "$PB/$RKEY: the write-back to the hub failed ($(printf '%s' "$BR_CKPT" | tail -n 1)) — this run stops before its next candidate"
    STOPREASON=writeback-failed; BR_EXIT=75; break
  fi
done

# ONE LINE PER TICK (BH-980), and only when there was something to do. An idle
# tick stays quiet — CLAUDE.md's "if a run finds nothing new, exit quietly", and
# tests/rebuild-ledger.bh-946-test.sh reads an empty log as proof a refused run
# took no tick at all. What the line has to answer is the question the hub could
# not answer for seven hours: did this tick look at project-5, and if not, why.
#
# A TICK WHOSE WHOLE LIST WAS RETIRED IS NOT AN IDLE TICK (BH-1457), so the
# guard asks what DISCOVERY found rather than what survived the pre-pass: 270
# finished rows coming off the list is the fact this ticket is about, and a lane
# that dropped them in silence would be indistinguishable from one that found
# nothing. A genuinely idle tick has RAWCOUNT=0 and stays quiet exactly as it
# does today.
SKIPLIST=""; OLDEST_UNTOUCHED="-"
# THE RUNG BUDGET THIS TICK HANDS ON (BH-1457). Only a tick that ran out of WALL
# clock is owed anything: a drained tick had nothing left to do, and a tick that
# spent every rung it was allowed was not cut short. Clamped to BR_PER_TICK so
# the next tick's budget can at most double.
BUDGET_CARRY=0
if [ "$STOPREASON" = tick-budget ]; then
  BUDGET_CARRY=$(( EFF_PER_TICK - N ))
  [ "$BUDGET_CARRY" -ge 0 ] || BUDGET_CARRY=0
  [ "$BUDGET_CARRY" -le "$PER_TICK" ] || BUDGET_CARRY="$PER_TICK"
fi
BUDGET_TMP="$BUDGET_FILE.tmp.$$"
# A WRITE THAT FAILED SAYS SO (review M3). Without the line, an unwritable $ST
# leaves the PREVIOUS carry on disk and the next tick re-spends it, for ever, on
# a lane whose tick lines all look correct.
if printf '%s\n' "$BUDGET_CARRY" > "$BUDGET_TMP" 2>/dev/null && mv -f "$BUDGET_TMP" "$BUDGET_FILE" 2>/dev/null; then :
else say "the carried rung budget could not be written to $BUDGET_FILE — the next tick will re-read the previous value"; fi
rm -f "$BUDGET_TMP" 2>/dev/null
REBUILDS_BOUGHT=0
[ -n "${TICK_REBUILDS:-}" ] && REBUILDS_BOUGHT=$(grep -c . "$TICK_REBUILDS" 2>/dev/null)
case "$REBUILDS_BOUGHT" in ''|*[!0-9]*) REBUILDS_BOUGHT=0 ;; esac
# WHAT THE OPTIONAL SEAM AND THE MODEL CALLS SPENT (BH-1468). Read with the same
# guard REBUILDS_BOUGHT uses: `grep -c` prints 0 and exits 1 on an empty file,
# so the count is taken and then range-checked rather than papered over with an
# `|| echo 0` that would also swallow an unreadable file. Three of the four are
# written by optional modules that do not exist yet and read 0 until they land.
N_CARRIED=0; N_MECHANICAL=0; N_FAMILIES=0; N_LLM=0
if [ -n "${TICK_COUNTS:-}" ]; then
  N_CARRIED=$(grep -cx carried "$TICK_COUNTS" 2>/dev/null)
  N_MECHANICAL=$(grep -cx mechanical "$TICK_COUNTS" 2>/dev/null)
  N_FAMILIES=$(grep -cx family "$TICK_COUNTS" 2>/dev/null)
  N_LLM=$(grep -cx llm "$TICK_COUNTS" 2>/dev/null)
fi
case "$N_CARRIED"    in ''|*[!0-9]*) N_CARRIED=0 ;; esac
case "$N_MECHANICAL" in ''|*[!0-9]*) N_MECHANICAL=0 ;; esac
case "$N_FAMILIES"   in ''|*[!0-9]*) N_FAMILIES=0 ;; esac
case "$N_LLM"        in ''|*[!0-9]*) N_LLM=0 ;; esac
if [ "$RAWCOUNT" -gt 0 ]; then
  for PJ in $ALLORDER; do
    # A PROJECT AN OPERATOR HELD IS NOT SKIPPED, it is stopped (BH-1465). It is
    # out of the skiplist for the same reason it gets no visit stamp: the
    # STARVED walk and br_saturated_alert both read this list, and paging that a
    # deliberately held project has waited an hour is the pager crying about the
    # thing somebody just turned off. Its own held line already said so.
    case "$HELD_PROJECTS" in *" $PJ "*) continue ;; esac
    case "$VISITED" in *" $PJ "*) ;; *) SKIPLIST="${SKIPLIST:+$SKIPLIST }$PJ" ;; esac
  done
  # Everything from the break to the end of the list was never looked at —
  # except a SECOND copy of a ticket this tick already acted on. Two sources
  # reporting one park is the normal case (the loop above skips the duplicate on
  # DONE_KEYS), and a copy that happens to sit past the break is the same ticket:
  # reading its park age as "waiting" would age the lane by a park it just
  # worked. This can only overstate, never understate, which is why it is a
  # filter here rather than a second ledger.
  if [ -n "$BREAKAT" ]; then
    for ((BI = BREAKAT; BI < ${#CANDS[@]}; BI++)); do
      IFS=$'\t' read -r _ XP XRKEY _ _ _ _ XPARKED <<<"${CANDS[$BI]}"
      case "$DONE_KEYS" in *" $XP/$XRKEY "*) continue ;; esac
      br_note_untouched "${XPARKED:--}" "${XP:--}"
    done
  fi
  # `-` when nothing was left untouched OR when none of the untouched rows
  # carried a park age. Never 0m: "nothing is waiting" and "we cannot tell how
  # long it has waited" are different facts (D11).
  if [ -n "$OLDEST_MIN" ]; then
    OLDEST_AGE=$(( NOW_TICK - OLDEST_MIN )); [ "$OLDEST_AGE" -ge 0 ] || OLDEST_AGE=0
    OLDEST_UNTOUCHED="$((OLDEST_AGE / 60))m"
  fi
  TICKREASON="$STOPREASON"
  [ "$ORDER_RC" = 2 ] && TICKREASON="$TICKREASON+ordering-fallback"
  # A PRE-PASS THAT DID NOT FINISH gets the same treatment as an ordering that
  # fell back (review I5): the tick otherwise looks entirely normal — same
  # count, same reason word — while nothing was retired and nothing was costed.
  [ "$PRE_RC" = 2 ] && TICKREASON="$TICKREASON+prepass-fallback"
  # A RECORD THE INDEX COULD NOT PARSE is a park that is neither retired nor
  # costed. The log line naming the count comes from br_prepass; this is the
  # grep-able mark on the tick itself, the shape +ordering-fallback already has.
  [ "$IDX_BAD" = 0 ] || TICKREASON="$TICKREASON+index-short"
  # HOW LONG THE TICK ACTUALLY TOOK. The whole of ask 7 was a 53-MINUTE number,
  # and `reason=tick-budget` alone does not say whether the tick ran 31 minutes
  # or three hours — a fix round can hold it 90 minutes past the cap, and
  # discovery alone can eat the budget before the first rung. It is also the
  # field to read when `rungs=` looks small: on a permanently wall-bound lane the
  # carry sits at its clamp, so the DENOMINATOR is 2x BR_PER_TICK for ever and
  # `rungs=3/100` means "time-bound", not "idle" (review M13).
  TICKSECS=$(( $(br_now) - TICK_START ))
  [ "$TICKSECS" -ge 0 ] || TICKSECS=0
  # `candidates` is what DISCOVERY found and `retired` is what the pre-pass
  # dropped, so candidates minus retired is what the loop could reach. `rungs`
  # is over the EFFECTIVE budget, which is BR_PER_TICK on every tick that
  # carried nothing — i.e. every tick at defaults.
  # `carried`, `mechanical` and `families` are the optional seam's (BH-1468) and
  # read 0 until #1470 and #1471 land; `llm_rungs` is every dispatch that
  # REACHED a model call, which is the number to read `rungs` against.
  say "tick: candidates=$RAWCOUNT retired=$RETIRED carried=$N_CARRIED mechanical=$N_MECHANICAL families=$N_FAMILIES llm_rungs=$N_LLM projects=$NPROJ visited=[$VISITLIST] skipped=[$SKIPLIST] rungs=$N/$EFF_PER_TICK reason=$TICKREASON secs=$TICKSECS rebuilds=$REBUILDS_BOUGHT/$REBUILD_CAP budget_carry=$BUDGET_CARRY oldest_untouched=$OLDEST_UNTOUCHED"
  # Where this tick's time and calls went (BH-5946, bin/lib/br/opt/profile.sh).
  command -v br_opt_prof_tick_end >/dev/null 2>&1 && br_opt_prof_tick_end
  # THE STARVATION CLOCK. A project is starved when it HAD candidates this tick
  # and got no look at all; a project with nothing parked is not starved however
  # old its row, so only SKIPLIST is walked. One line per episode: last_alerted
  # is compared with the newer of last_visited and first_seen, so a later visit
  # re-arms it and an unchanged situation stays silent.
  for PJ in $SKIPLIST; do
    [ "$PJ" != "-" ] || continue
    read -r VLV VFS VLA <<<"$(br_visited_row "$PJ")"
    # FIRST SIGHT IS NOT STARVATION. A project this lane has never had a row for
    # gets its clock started and nothing else — alerting on it would page for
    # every new park in the fleet, ten minutes after it was parked.
    if [ "$VLV" = 0 ] && [ "$VFS" = 0 ]; then
      br_visited_put "$PJ" 0 "$NOW_TICK" 0
      continue
    fi
    ANCHOR="$VLV"; [ "$VFS" -le "$ANCHOR" ] || ANCHOR="$VFS"
    AGE=$((NOW_TICK - ANCHOR)); [ "$AGE" -ge 0 ] || AGE=0
    [ "$AGE" -gt "$STARVE_SECS" ] || continue
    [ "$VLA" -le "$ANCHOR" ] || continue
    KCNT=0
    for LINE in ${CANDS[@]+"${CANDS[@]}"}; do
      IFS=$'\t' read -r _ XP _ <<<"$LINE"
      if [ "${XP:--}" = "$PJ" ]; then KCNT=$((KCNT+1)); fi
    done
    if [ "$VLV" != 0 ]; then
      SINCE=$(date -u -d "@$VLV" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) || SINCE="epoch $VLV"
    else
      SINCE="it first appeared at $(date -u -d "@$VFS" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "epoch $VFS")"
    fi
    br_starved_alert "$PJ" "$KCNT" "$AGE" "$SINCE" "$VISITLIST"
    # THE ALERT IS SENT BEFORE THE STAMP, and the stamp is written whatever the
    # send answered: lane-alert.sh carries its own durable ALERTS.log half, and
    # re-paging every ten minutes because a beat hiccuped is precisely the noise
    # the "ONE line" ask forbids.
    br_visited_put "$PJ" "$VLV" "$VFS" "$NOW_TICK"
  done
fi
# ONE PAGE PER PROJECT EPISODE when its oldest untouched park passes
# BR_UNTOUCHED_ALERT_MIN (BH-5913, bin/lib/br/opt/untouched.sh). Outside the
# block above on purpose: a tick with no candidates ends every episode.
if command -v br_untouched_alert >/dev/null 2>&1; then br_untouched_alert "$NOW_TICK"; fi
# THE PARENT WAIT CLOCK (BH-5741): one ALERTS line per BLOCKed parent whose
# approved children have waited BR_PARENT_WAIT_ALERT_MIN with no fix round.
# Not observe-gated, like STARVED: a page about state is not a rung.
if [ -n "${BR_PARENT_TICK:-}" ] && command -v br_opt_parent_wait >/dev/null 2>&1; then
  br_opt_parent_wait "$BR_PARENT_TICK"
fi
[ -z "${BR_PARENT_TICK:-}" ] || rm -f "$BR_PARENT_TICK"

# ---------------------------------------------------------------------------
# SATURATION (BH-1122). A tick that ends on its budget is ordinary; K of them in
# a row is a lane that will never reach the back of its own list, and before
# this the two were the same line in the log. On the hub, 40 consecutive ticks
# ended `rungs=4/4 reason=budget` and nothing anywhere said the drain was
# falling behind — the STARVED alert next door only fires for a project with no
# look at all, which is a different question.
#
# The streak lives in $ST/.saturation.tsv — a dotfile for the same reason the
# visit ledger is one (br_from_rebuilds globs "$ST"/*/*.json) — and is rewritten
# whole with tmp+mv. No lock: two overlapping ticks can at worst double-count
# one tick, which moves the page one tick earlier, and a lock held across a tick
# end would be a queue (D33). The `alerted` flag is what makes it ONE line per
# episode, and the first tick that ends any other way resets both it and the
# marker bin/merge-conductor.sh reads.
# A PROJECT RUN KEEPS ITS OWN STREAK (BH-5913): runs of different projects
# overlap, and a shared streak would count one project's budget endings against
# another. Its marker is named for the project's REPO, the key
# bin/lib/mc/classify.sh holds (mc_resolver_saturated). A whole-fleet scan keeps
# the fleet-wide files.
SAT_FILE="$ST/.saturation.tsv"
SAT_MARK="$ST/.saturated"
if [ -n "$ONLY" ]; then
  SAT_FILE="$ST/.saturation-$ONLY.tsv"
  SAT_SLUG=$("$H/bin/fleet-conf.sh" "$ONLY" repo 2>/dev/null) || SAT_SLUG=""
  case "$SAT_SLUG" in
    */*) SAT_MARK="$ST/.saturated-${SAT_SLUG//\//_}" ;;
    *)   SAT_MARK="$ST/.saturated-project-$ONLY" ;;
  esac
fi
SAT_STREAK=0; SAT_ALERTED=0
declare -A SAT_RUNGS=()
if [ -r "$SAT_FILE" ]; then
  while IFS=$'\t' read -r SKEY SA SB SC; do
    case "$SKEY" in
      streak) case "$SA" in ''|*[!0-9]*) ;; *) SAT_STREAK="$SA" ;; esac
              [ "${SC:-0}" = 1 ] && SAT_ALERTED=1 ;;
      rungs)  [ -n "${SA:-}" ] || continue
              case "${SB:-}" in ''|*[!0-9]*) ;; *) SAT_RUNGS["$SA"]="$SB" ;; esac ;;
    esac
  done < "$SAT_FILE"
fi

# br_saturated_alert <streak> <candidates> <oldest-untouched> <skiplist>
#                    <stop-reason> <retired> <secs>
#   ONE actionable line: how long, how many parks, how many rungs a tick buys,
#   how old the oldest untouched park is, where the rungs went over the streak,
#   and the arithmetic that turns those into "hours to first touch". Every value
#   comes from this tick and the streak file — nothing is invented (D26).
#
#   THE REMEDIATION DEPENDS ON WHICH BOUND BIT (BH-1457, review I4). Folding
#   `tick-budget` into the streak is right — both endings mean this lane cannot
#   reach the back of its own list — but the line said "ended on reason=budget"
#   for both and told the operator to RAISE BR_PER_TICK, which on a wall-bound
#   lane is precisely the action that produced the 53-minute tick this ticket
#   exists to bound. It now names the ending it saw and advises accordingly.
#
#   `candidates` is the SAME number the tick line prints (what discovery found),
#   with the retired count beside it. The first cut passed the post-retire array
#   length here and RAWCOUNT there: two different numbers under one word, in two
#   places an operator reads side by side.
br_saturated_alert() {
  local streak="$1" cands="$2" oldest="$3" skip="$4" stop="${5:-budget}" retd="${6:-0}" secs="${7:-0}"
  local line top="" rate perh advice
  if [ "${#SAT_RUNGS[@]}" -gt 0 ]; then
    top=$(for PJ in "${!SAT_RUNGS[@]}"; do printf '%s\t%s\n' "${SAT_RUNGS[$PJ]}" "$PJ"; done \
          | sort -rn -k1,1 | head -3 \
          | awk -F'\t' '{printf "%s%s:%s", (n++ ? " " : ""), $2, $1}')
  fi
  [ -n "$top" ] || top=none
  case "$PER_TICK" in
    ''|*[!0-9]*) rate="BR_PER_TICK='$PER_TICK' is not a number, so this lane's budget is whatever bash made of it" ;;
    0)           rate="BR_PER_TICK=0: nothing is ever touched" ;;
    *)           perh=$((PER_TICK * 6))
                 rate="At this rate candidates ÷ (rungs×6/h) = $cands ÷ $perh ≈ $(( (cands + perh - 1) / perh ))h to first touch" ;;
  esac
  case "$stop" in
    tick-budget) advice="This lane is TIME-bound, not rung-bound: its last tick ran ${secs}s against BR_TICK_MAX_SECS=$TICK_MAX and the rungs it did not spend are already being carried. Raise BR_TICK_MAX_SECS in env/global.env, or shrink the list (the rungs themselves are what is slow). DO NOT raise BR_PER_TICK — on a time-bound lane that buys latency, which is what BH-1457 was filed about." ;;
    *)           advice="Raise BR_PER_TICK in env/global.env (the arithmetic is in env-templates/global.env.example) or cap the busy projects with BR_PER_TICK_<PROJECT>." ;;
  esac
  line="[blocked-resolver] SATURATED: $streak consecutive ticks ended on reason=$stop. candidates=$cands retired=$retd rungs/tick=BR_PER_TICK=$PER_TICK secs=$secs oldest_untouched=$oldest skipped=[${skip:--}] top rung consumers over the streak: $top. $rate. $advice bin/merge-conductor.sh will not re-hand-off stuck parks while this stands."
  if [ -x "$H/bin/lane-alert.sh" ]; then
    "$H/bin/lane-alert.sh" blocked-resolver "$line" >/dev/null 2>&1 || true
  else
    HARNESS="$H" "$H/bin/alert-line.sh" "$line"
    "$H/bin/beat.sh" "$(jq -nc --arg akey "blocked-resolver-saturated" --arg l "$line" \
      '{kind:"fleet_alert",project:"-",akey:$akey,line:$l}')" >/dev/null 2>&1 || true
  fi
  say "SATURATED — $streak consecutive budget ticks, $cands candidates, BR_PER_TICK=$PER_TICK, oldest_untouched=$oldest; one ALERTS line written"
}

SAT_TMP="$SAT_FILE.tmp.$$"
# A WALL-BUDGET TICK IS A SATURATED TICK TOO (BH-1457). `budget` and
# `tick-budget` are one condition wearing two words — this lane cannot reach the
# back of its own list — so letting the new ending reset the streak would
# silence the SATURATED alert on exactly the fleet that needs it.
case "$STOPREASON" in budget|tick-budget) SAT_ENDED=1 ;; *) SAT_ENDED=0 ;; esac
if [ "$SAT_ENDED" = 1 ]; then
  SAT_STREAK=$((SAT_STREAK + 1))
  if [ "${#NP[@]}" -gt 0 ]; then
    for PJ in "${!NP[@]}"; do
      SAT_RUNGS["$PJ"]=$(( ${SAT_RUNGS[$PJ]:-0} + ${NP[$PJ]:-0} ))
    done
  fi
  if [ "$SAT_STREAK" -ge "$SATURATED_TICKS" ] && [ "$SAT_ALERTED" = 0 ]; then
    br_saturated_alert "$SAT_STREAK" "$RAWCOUNT" "$OLDEST_UNTOUCHED" "$SKIPLIST" \
                       "$STOPREASON" "$RETIRED" "${TICKSECS:-0}"
    # The flag is written whatever the send answered — lane-alert.sh carries its
    # own durable ALERTS.log half, and re-paging because a beat hiccuped is
    # exactly the noise "one line" forbids (the STARVED precedent).
    SAT_ALERTED=1
    : > "$SAT_MARK"
  fi
  { printf 'streak\t%s\talerted\t%s\n' "$SAT_STREAK" "$SAT_ALERTED"
    if [ "${#SAT_RUNGS[@]}" -gt 0 ]; then
      for PJ in "${!SAT_RUNGS[@]}"; do printf 'rungs\t%s\t%s\n' "$PJ" "${SAT_RUNGS[$PJ]}"; done
    fi
  } > "$SAT_TMP" 2>/dev/null && mv -f "$SAT_TMP" "$SAT_FILE"
  rm -f "$SAT_TMP" 2>/dev/null
else
  # Drained, or an idle tick with no candidates at all. Either way this lane is
  # keeping up with its list and the episode is over.
  printf 'streak\t0\talerted\t0\n' > "$SAT_TMP" 2>/dev/null && mv -f "$SAT_TMP" "$SAT_FILE"
  rm -f "$SAT_TMP" "$SAT_MARK" 2>/dev/null
fi

# The lane lock is already released by br_cron_unlock inside the first
# dispatched rung; this closes the fd on every other path out (an idle
# tick, a tick whose every row was held) so nothing leaves it open.
# The push-rejected pool terminals, listed and told once (BH-6821).
command -v br_pool_terminal_pass >/dev/null 2>&1 && br_pool_terminal_pass "$ONLY"
exec 8>&-
# THE HAND-OFF SWEEP (BH-5125), after everything above has had its say.
[ "$BHW_ON" = 1 ] && bhw_sweep "$STOPREASON"
hb_done blocked-resolver
exit "$BR_EXIT"
