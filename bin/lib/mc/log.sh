#!/bin/bash
# shellcheck shell=bash
# module: log
# bin/lib/mc/log.sh — BH-477: the base module: MC_* globals, tunables, the gh-app-auth/flaky/review-provenance source guards, mc_log, mc_alert, mc_budget_check. Sourced by bin/lib/merge-conductor-lib.sh, never run.
# bin/lib/merge-conductor-lib.sh — the merge conductor's pure logic. Sourced by
# bin/merge-conductor.sh and by tests/merge-conductor-test.sh; never executed.
# Design: docs/MERGE-CONDUCTOR.md. Nothing here touches GitHub or a branch
# except the three action functions at the bottom (mc_rebase, mc_rereview,
# mc_merge), and bin/merge-conductor.sh calls those only behind their flags.
#
# Every gh call is plain `gh` on PATH so the fixtures can stub it; token
# routing (which GH_TOKEN is exported while a repo is handled) is the caller's
# job through bin/lib/gh-repo-token.sh, and through the mc_use_token /
# mc_reset_token pair below, which arms the per-repo App token.
#
# THREE OF THE FOUR WAYS A PR USED TO GET STRANDED, CLOSED 2026-09-14 (the operator,
# "fix the conductor problems"). The remaining one — the stacked-child block
# that never fired, because an empty tsv field slid baseRefName out of its
# variable — is plumbing in bin/merge-conductor.sh and is documented there.
#   1. mc_classify tested CI BEFORE the DIRTY/CONFLICTING line. GitHub runs no
#      pull_request workflow on a conflicted PR, so `ci=none` is the normal
#      state of a DIRTY one and every conflicted PR answered `WAIT_CI checks
#      none` and never reached mc_rebase (project-5 #799 for four hours;
#      #826/#838/#863 the same). DIRTY now answers NEEDS_REBASE whatever CI
#      says, and the no-verdict DIRTY dead end (WAIT_REVIEW) goes with it.
#   2. `provenance` parked a PR whose head-bound re-review then came back
#      APPROVE, and nothing consumed the answer (project-5 #864/#867 merged by
#      hand). mc_prov_held / mc_prov_cleared / mc_prov_clear are how the tick
#      ends that hold; MC_PROV_CLEARED is how mc_classify hears about it.
#   4. The conductor bought a review of a PR whose OWN build was still running
#      and about to review it. mc_job_running is the wait, and it is bounded.
# THE DECISION READS GO THROUGH REST (BH-784), and the marker below is what
# tests/gh-no-graphql-decision-guard-test.sh scans this file for. It moved here
# with the code when BH-477.3 emptied bin/lib/merge-conductor-lib.sh: the lib
# carried the marker while it carried these calls, and a module holding them
# unmarked would be a call site the guard silently stopped policing.
# gh-rest: no-graphql

MC_H="${HARNESS:-/root/harness}"
# THE SOURCE GUARDS THEMSELVES LIVE IN THE SHIM (BH-684). The eight sibling
# libs this lane needs — gh-app-auth, gh-pr-merge, flaky, review-provenance,
# issue-state-lib, block-gate, pr-dep-gate, main-red-gate — are sourced by
# bin/lib/merge-conductor-lib.sh and not from here. Four of them resolve off
# the sourcing file's OWN directory, which is bin/lib/ for the shim and one
# level too deep for a module; and a module that pulled them in would make
# what mc/log.sh "defines" depend on what happens to be on the box, which is
# what tests/mc-split-layout-test.sh reads. The fail-open shims for the two
# that have one stay here, below: the shim sources the real definitions after
# the module loop, so a real helper always replaces the shim that stood in.
MC_LOG="$MC_H/logs/merge-conductor.log"
MC_STATE_DIR="$MC_H/state/merge-conductor"
MC_ROWS="$MC_STATE_DIR/pr-state.tsv"      # key state since head reviewed alerted reason url
MC_ATTEMPTS="$MC_STATE_DIR/attempts.txt"  # "<kind> <key> <sha>" — one rebase/re-review per (PR, sha)
MC_RR_DIR="$MC_STATE_DIR/rereview"         # one job file per (PR, head) detached re-review
MC_REREVIEW_PARALLEL="${MC_REREVIEW_PARALLEL:-0}"              # detached re-reviews running at once, fleet-wide; 0 = unlimited (default since 2026-09-14)
MC_REREVIEW_TIMEOUT_SECS="${MC_REREVIEW_TIMEOUT_SECS:-2700}"   # a running job older than this is failed
# The PATH a detached job runs on. Named, not inherited: cron's PATH is not the
# one bin/agent-call.sh needs, and the fixtures point it at their stub bin.
MC_RR_PATH="${MC_RR_PATH:-/root/.fly/bin:/usr/local/bin:/usr/bin:/bin}"
# How much of the diff the re-review prompt INLINES. The complete diff is always
# written to $MC_STATE_DIR/diffs and named in the prompt, so the cap costs the
# reviewer a read, never a fact. 96000 = AGENT_ARGV_MAX (bin/agent-call.sh): a
# 26-file PR should not need a 140KB prompt in the first place (BH-495).
MC_RR_DIFF_INLINE_BYTES="${MC_RR_DIFF_INLINE_BYTES:-96000}"
MC_RB_DIR="$MC_STATE_DIR/rebase"           # one job file per (PR, head) detached rebase
MC_REBASE_PARALLEL="${MC_REBASE_PARALLEL:-0}"                  # detached rebases running at once, fleet-wide; 0 = unlimited (default since 2026-09-14)
MC_REBASE_TIMEOUT_SECS="${MC_REBASE_TIMEOUT_SECS:-1800}"       # a running rebase older than this is failed
MC_REBASE_POOL_TIMEOUT_SECS="${MC_REBASE_POOL_TIMEOUT_SECS:-5400}"  # a POOL rebase job older than this is failed (BH-486; nothing reads it until BH-486.2)
MC_DETACHED_REBASE="${MC_DETACHED_REBASE:-1}"                  # 0 = the tick rebases INLINE, exactly as it did before 2026-09-14
MC_LAND_DIR="$MC_STATE_DIR/land"           # one line per project: the last base sha whose land fan-out completed (BH-870)
MC_LAND_REBASE="${MC_LAND_REBASE:-1}"                          # 0 = a merge to a project's base triggers nothing; byte-for-byte the pre-BH-870 conductor
MC_LAND_REBASE_PARALLEL="${MC_LAND_REBASE_PARALLEL:-4}"        # hub rebases the LAND arm may have running at once; 0 = unlimited (the MC_REBASE_PARALLEL convention)
MC_EJECT_REBASE="${MC_EJECT_REBASE:-1}"                        # 0 = a base-conflict ejection is a strike and buys no out-of-budget rebase, and no Mergify comment is read for it — as before BH-1669 (read since BH-1677)
MC_HANDOFF_DIR="$MC_STATE_DIR/handoff"             # one open resolver hand-off per PR
MC_HANDOFF_REL_DIR="$MC_STATE_DIR/handoff-released" # the resolver's release marker per PR
MC_RESOLVER_CLAIM_DIR="$MC_STATE_DIR/resolver-claim" # a park bin/blocked-resolver.sh has claimed (BH-3630)
MC_STICKY_HANDOFF="${MC_STICKY_HANDOFF:-1}"        # 0 = re-classify a handed-off row every tick, as before 2026-09-14
MC_STICKY_LOG_SECS="${MC_STICKY_LOG_SECS:-3600}"   # a parked PR says so at most this often
# The PR label a PERSON applies to end a sticky park (BH-292). Empty = off, and
# the `-` rather than `:-` is deliberate: MC_RELEASE_LABEL= in the environment
# is how the feature is turned off, so an explicit empty value must survive.
MC_RELEASE_LABEL="${MC_RELEASE_LABEL-conductor-release}"
MC_HANDOFF_HUMAN_DIR="$MC_STATE_DIR/handoff-human"  # one marker per (PR, head) the label has already released
MC_DV_DIR="$MC_STATE_DIR/deploy-verify"    # one job file per (project, merge sha) detached deploy verify
MC_DV_TIMEOUT_SECS="${MC_DV_TIMEOUT_SECS:-2400}"               # deploy-verify polls for 20 min; past 40 it is not coming back
MC_DETACHED_DEPLOY_VERIFY="${MC_DETACHED_DEPLOY_VERIFY:-1}"    # 0 = the tick calls deploy-request.sh itself, as before
MC_STUCK_DIR="$MC_STATE_DIR/stuck"         # one marker per (PR, state, head) the stuck detector has alerted on
# bin/blocked-resolver.sh's SATURATED marker (BH-1122). That lane writes it when
# K ticks in a row have ended on its own budget and removes it on the first tick
# that ends any other way. READ ONLY here, by the two places that would otherwise
# tell a reader to go and wait on a lane that is already out of rungs: the stuck
# page (mc_stuck_check) and the re-kick (stuck_rekick in bin/merge-conductor.sh).
MC_RESOLVER_SAT="$MC_H/state/blocked-resolver/.saturated"
MC_BATCH_DIR="$MC_STATE_DIR/batch-hold"    # one marker per PR bin/batch-resolve.sh has put in a live train (BH-498)
MC_CONTESTED_DIR="$MC_H/state/contested"   # one hold file per (project, contested path) — BH-579, the block below
MC_CONFLICT_SIZE_DIR="$MC_STATE_DIR/conflict-size"  # <safe-slug>_<num>: how big the conflict mc_rebase last hit was
MC_RED_RERUN="${MC_RED_RERUN:-1}"                              # 0 = no red is ever re-run; every red takes its strike on sight, as before 2026-09-15
MC_RED_RERUN_SETTLE_SECS="${MC_RED_RERUN_SETTLE_SECS:-300}"    # a red seen sooner than this after the rerun was dispatched is the OLD red, not a second one
MC_AUTOPILOT_CONSUME="${MC_AUTOPILOT_CONSUME:-1}"              # 0 = the >12h review-autopilot verdict on a moved head is never read; the conductor buys its own, as before 2026-09-18 (BH-764)
MC_AUTOPILOT_RECHECK_SECS="${MC_AUTOPILOT_RECHECK_SECS:-3600}" # how often ONE (PR, head) may re-read the PR's comments looking for that verdict
MC_STATES="WAIT_CI WAIT_REVIEW HEAD_MOVED NEEDS_REBASE REBASING BLOCKED_HUMAN NEEDS_HUMAN_VERDICT RED_TWICE READY QUEUED STACKED_WAIT MERGED CLOSED ABANDONED"
# ABANDONED (2026-09-13, the operator: "I will never do a human review") is the ONE
# terminal this lane gained. BLOCKED_HUMAN is no longer a request for a person:
# bin/blocked-resolver.sh drains it on an agent ladder (rebuild fresh / fix
# round / adjudicate), and only when that ladder is exhausted does the row move
# here. ABANDONED is an OUTCOME RECORD, not a review request — the conductor
# takes no action on it, its budget is -1 so it never pages by age, and
# mc_classify pins it so a tick cannot walk a retired PR back into the pipeline.
#
# The state string BLOCKED_HUMAN is KEPT for compatibility: rows written before
# today carry it, and every reader keys on the word. What changed is what it
# MEANS and what it is CALLED — mc_state_display prints BLOCKED_AGENT for the
# reasons the resolver owns, so a log line or a console panel says who is
# actually working on it.
#
# RED_TWICE (2026-09-15, the operator: project-5 #1045) is the end of the RED LADDER,
# and it exists because `WAIT_CI checks red once` had no next transition. #1045
# (TK-989) went red at 02:04Z, the conductor logged it once, and then nothing
# touched the PR for ten hours — the red-ci-twice park counted reds on DIFFERENT
# heads (BH-1671 removed it: red is counted per head only), so a PR that goes red once and is never pushed to again sits in
# WAIT_CI for ever. The ladder is now per head: red -> ONE `gh run rerun
# --failed` of the failing runs (mc_red_rerun, the flake path's mechanics for
# every red) -> still red on the SAME head -> RED_TWICE, which is a park
# bin/blocked-resolver.sh owns exactly like the BLOCKED_AGENT reasons (reason
# `red-twice`, action rebuild-fresh). It is NOT sticky, for the reason
# `red-ci-twice` is not: it is re-derived from CI every tick and a rerun that
# goes green underneath us must move the row.
#
# What a flaky red is, and the ledger that says which tests are known flaky, is
# bin/lib/flaky.sh — sourced by the shim, after this module. Optional: an older
# tree without the lib leaves mc_flake_rerun undefined, the REDS lines in
# bin/merge-conductor.sh fall through to their `else`, and every red counts
# exactly as it did before.
# Judge provenance, as a (runner, model) pair rather than a runner word — a
# review served on the OpenRouter survival lane with an anthropic/ slug IS a
# Claude read (bin/lib/review-provenance.sh). The shim sources it AFTER this
# module, which reaches the conductor, bin/merge-sweep.sh, bin/blocked-resolver.sh
# and bin/review-prs.sh, all four of which source the lib. An older tree without
# the file keeps EXACTLY today's rule through the fail-open definitions at the
# bottom of this block: the literal word `claude` and nothing else, which is the
# fail-closed direction (an unrecognised word holds a PR, it never merges one).
# The one way this harness closes an issue after a merge (BH-637 §3b): comment,
# close, then take `ai-build` off, in that order and never out of it. The shim
# sources bin/lib/issue-state-lib.sh BEFORE this module — so when the real one is
# on the box this definition never fires — and that reaches the conductor,
# bin/merge-sweep.sh and bin/batch-resolve.sh, all of which source the lib. An
# older tree without the file keeps EXACTLY today's behaviour through the
# fail-open definition below: comment, close, and the label left on.
# MC_ICS_SHIM marks that the label rule is NOT available on this tree, which is
# what mc_close_shipped reads to decide whether delegating the strip is worth a
# second call. Without it the shim would re-PATCH an issue mc_close_shipped has
# already read as closed — idempotent, but one wasted write per merge and a
# second `issues/{n}` line in every argv log that claims "closed exactly once".
MC_ICS_SHIM=0
type issue_close_shipped >/dev/null 2>&1 || { MC_ICS_SHIM=1; issue_close_shipped() {
  local _f _rc=0
  if [ -n "${3:-}" ]; then
    _f=$(mktemp "${TMPDIR:-/tmp}/mc-shim-comment.XXXXXX") || { printf 'close-failed\n'; return 1; }
    printf '%s' "$3" > "$_f"; gh_rest_comment "$1" "$2" "$_f" >/dev/null 2>&1 || _rc=1
    rm -f "$_f"
  fi
  gh_rest_close "$1" "$2" issues >/dev/null 2>&1 || { printf 'close-failed\n'; return 1; }
  [ "$_rc" = 0 ] || { printf 'strip-unavailable,comment-failed\n'; return 0; }
  printf 'strip-unavailable\n'; return 0
}; }
# The BLOCK gate (BH-762). Sourced HERE, off this file's own directory, because
# The BLOCK gate (BH-762) is sourced by the SHIM, off the shim's own directory,
# because every automatic merge path in the fleet already sources the lib —
# bin/merge-conductor.sh, bin/merge-sweep.sh, bin/merge-queue.sh,
# bin/review-prs.sh and bin/run-build.sh — so one guarded line arms all five and
# no lane grows its own sourcing. A tree without the file leaves bg_scan
# undefined and every lane behaves exactly as it did (each one guards on
# `command -v bg_scan`), which is the same rule this lib's own absence follows.
# The PR-dependency gate (BH-629), the same guarded shape as the BLOCK gate
# above and in the same place: one line in the shim arms every lane that sources
# the lib, and a tree without the file leaves pdg_hold undefined so each lane
# behaves exactly as it did (the call sites guard on `command -v pdg_hold`, as
# they do bg_scan).
# The main-red freeze (BH-945), the same guarded shape again, also in the shim.
# It used to be private to bin/merge-conductor.sh, which is how #931 and #942
# merged into a red main through box lanes on 2026-09-18; that one line arms
# every lane that sources the lib, and a tree without the file leaves
# main_red_hold undefined so each lane behaves exactly as it did (the call sites
# guard on `command -v main_red_hold`, as they do bg_scan and pdg_hold).
if ! type rp_prov_is_claude >/dev/null 2>&1; then
  rp_prov_is_claude() { [ "${1:-}" = claude ]; }
  rp_is_claude()      { [ "${1:-}" = claude ]; }
  rp_prov_word()      { printf '%s' "${1:--}"; }
  rp_out_prov()       { head -1 "${1:-}.runner" 2>/dev/null || printf 'claude'; }
  rp_out_is_claude()  { rp_prov_is_claude "$(rp_out_prov "$1")"; }
  rp_out_label()      { rp_out_prov "$1"; }
fi
# The PR record writer (BH-8150, bin/lib/pr-record-write.sh). The shim sources
# it BEFORE the modules, like issue-state-lib.sh, so when it is on the box these
# definitions never fire. Without it each GitHub write runs exactly as before
# and nothing is recorded.
if ! type prr_write >/dev/null 2>&1; then
  prr_write()         { shift 4; "$@"; }
  prr_note_push()     { return 0; }
  prr_now()           { :; }
  prr_mergify_extra() { printf '%s' -; }
fi
mc_stamp() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
mc_now()   { date -u +%s; }
mc_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }
# mc_rows_rehydrate is defined further down (next to mc_row_put, whose lock it
# shares) and resolved at CALL time: every caller sources the whole lib first.
mc_init()  { mkdir -p "$MC_STATE_DIR" "$MC_RR_DIR" "$MC_RB_DIR" "$MC_DV_DIR" "$MC_HANDOFF_DIR" "$MC_HANDOFF_REL_DIR" "$MC_STUCK_DIR" "$MC_BATCH_DIR" "$MC_CONTESTED_DIR" "$MC_CONFLICT_SIZE_DIR" "$MC_TICK_DIR" "$MC_LAND_DIR" "$MC_LOCK_DIR" "$MC_H/logs" 2>/dev/null; touch "$MC_ROWS" "$MC_ATTEMPTS"; mc_rows_rehydrate; }
# mc_log also overwrites $FANIN_STAGE_FILE when set (BH-4842: bin/lib/fanin.sh
# sets it, unexported, for one worker's body), so a worker killed before fan-in
# is named with the last line it logged. The rc is the log write's, as before.
# It stays ONE line: tests/hub-lanes-project-hold.bh-1465-test.sh lifts it by grep.
mc_log()   { local rc; echo "$(mc_stamp) $*" >> "$MC_LOG"; rc=$?; [ -z "${FANIN_STAGE_FILE:-}" ] || { printf '%s\n' "$*" > "$FANIN_STAGE_FILE"; } 2>/dev/null; return "$rc"; }

# mc_defer_word <word> <key> — BH-7635: a step this lane-run machine leaves to
# the hub. <word> goes to MC_PR_DEFERRED_FILE as before (the PROF deferred=
# words). With MC_PR_DEFERRED_KEYS_FILE set (bin/merge-conductor-project.sh)
# and <key> an owner/repo#number, `<word> <key>` goes to that file too, so the
# hub runs a keyed tick of those PRs instead of the whole project. rc 0.
mc_defer_word() {
  [ -n "${MC_PR_DEFERRED_FILE:-}" ] && echo "$1" >> "$MC_PR_DEFERRED_FILE"
  [ -n "${MC_PR_DEFERRED_KEYS_FILE:-}" ] && [[ ${2:-} =~ ^[^#[:space:]]+#[0-9]+$ ]] \
    && printf '%s %s\n' "$1" "$2" >> "$MC_PR_DEFERRED_KEYS_FILE"
  return 0
}

# TOKEN ROUTING IS STILL THE CALLER'S JOB; these two are how a caller does it.
# mc_use_token arms the per-repo App token and NOTHING ELSE: no PAT fallback, no
# alert, no new skip path. The "which PAT can see this repo" fallback and its
# page stay in bin/merge-conductor.sh's own use_token, where a lane that needs
# them opts in by name — a shared lib that pages would page under the wrong lane
# (the merge queue writing "conductor cannot list its PRs") and would share the
# conductor's once-a-day dedupe flag. Both are `command -v` guarded, so a box
# whose harness sync has not landed gh-app-auth.sh yet runs exactly as it did
# before, and neither ever returns nonzero into an `&&` chain.
mc_use_token() { command -v gh_auth_for >/dev/null 2>&1 && gh_auth_for "${1:-}" || true; return 0; }

# mc_reset_token — put back the GH_TOKEN this process started with. The reset is
# never called by the lib itself, only by a caller at the end of its own run: a
# sourced file that un-arms the shell out from under a lane is a bug nobody sees
# until a later call goes out on the wrong identity.
mc_reset_token() { command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset; return 0; }


# --- Alerts ------------------------------------------------------------------
# mc_alert <key> <state> <line> [critical] [statenote]
#   bin/lane-alert.sh when installed (ALERTS line + fleet_alert beat, --critical
#   DMs when the monitor is off); else the same two writes by hand.
#
# ── A PER-PR STATE NOTE IS NOT AN ALERT (BH-979) ─────────────────────────────
# Measured on the hub 2026-09-19: 1033 of the 2019 lines in the alert-triage
# deferral spool were this function's output — HEAD_MOVED / WAIT_CI /
# STACKED_WAIT / "Nm in state" budget notes, one per PR, each one a brand-new
# root-cause family and therefore each one buying the STRONG investigator. They
# are a progress report on a lane that re-reads every one of those rows every
# tick; the conductor log is where a progress report belongs. A caller that is
# reporting one passes statenote=1 and gets mc_log and nothing else.
#
# WHICH STATES, AND WHY NOT ALL OF THEM. MC_STATE_NOTE_STATES is the set. It
# began as the four states that mean "waiting on this lane's own machinery" and
# that nothing else pages about: HEAD_MOVED, STACKED_WAIT, NEEDS_REBASE,
# REBASING. BH-4717 adds READY and QUEUED, because an aged READY or QUEUED row
# already gets its page from the STUCK detector (mc_stuck_check, TTL 20m READY
# and 60m QUEUED in mc_ttl), so this function's 15m/60m budget page was a status
# report about the same row. Pages that only carry the READY or QUEUED label —
# mc_queue_inactive_alert's queue-not-answering page, MERGIFY_BATCH_STUCK in
# bin/lib/mc/queue.sh — are direct mc_alert calls with no statenote and still
# page.
# WAIT_CI is NOT in the set: nothing else pages about a WAIT_CI row before the
# STUCK TTL's 90m, and an aged WAIT_CI means CI is not reporting, which a person
# acts on. Its pin is tests/merge-conductor-state-notes.bh-979-test.sh block 5.
# What BH-979 asked for WAIT_CI is the OTHER half of the fix, which it gets in
# the family key: see fold_volatile() in bin/alert_family.py, which folds the
# branch slug and the status parenthetical so the 6h family brake groups these
# instead of buying a session each (measured on the hub's 434 conductor spool
# lines: 171 families before, 69 after; WAIT_CI 17 -> 14, READY 4 -> 2).
# Parks (BLOCKED_HUMAN, RED_TWICE), terminals (CLOSED, ABANDONED) and the stuck
# detector are untouched by the note rule and still page — in merge and actions.
# Under kill-switch and observe the two AGE pages among them (this function's
# final else, and mc_stuck_check) are HELD instead of sent, which is a deferral,
# not a mute: see mc_hold_mode below (BH-1201). MC_STATE_NOTES_ALERT=1 restores
# the old note behaviour verbatim; widening MC_STATE_NOTE_STATES is an env edit,
# not a deploy.
MC_STATE_NOTE_STATES="${MC_STATE_NOTE_STATES:-HEAD_MOVED STACKED_WAIT NEEDS_REBASE REBASING READY QUEUED}"
mc_state_note_only() {  # rc 0 when this state is a progress report, not an alert
  case " $MC_STATE_NOTE_STATES " in *" ${1:-} "*) return 0 ;; esac
  return 1
}
#
# ── AND THE TEXT IS LEFT ALONE ON PURPOSE ────────────────────────────────────
# The grouping half of BH-979 is NOT done here. An earlier cut folded the branch
# slug out of this text before sending it, which measured 59 -> 59 families per
# (repo, state) on the hub's real lines — the per-PR variance is the status
# parenthetical, not the branch — while taking the branch away from the person
# reading ALERTS.log or the --critical DM. The fold now lives in
# bin/alert_family.py's fold_volatile(), on the family INPUT, shared by every
# lane that keys on it; what a human receives from here is verbatim.
mc_alert() {
  local key="$1" st="$2" line="$3" crit="${4:-}" note="${5:-}" text
  text="conductor: $key $st — $line"
  if [ -n "$note" ] && [ "${MC_STATE_NOTES_ALERT:-0}" != 1 ]; then
    # Declared where the lane's own history is kept, and nowhere that costs a
    # session. Silence here would be the drop this whole ticket is about.
    mc_log "$key state note (not an alert): $st — $line"
    return 0
  fi
  if [ -x "$MC_H/bin/lane-alert.sh" ]; then
    if [ -n "$crit" ]; then "$MC_H/bin/lane-alert.sh" --critical merge-conductor "$text" >/dev/null 2>&1 || true
    else "$MC_H/bin/lane-alert.sh" merge-conductor "$text" >/dev/null 2>&1 || true; fi
  else
    echo "$(mc_stamp) [merge-conductor] $text" >> "$MC_H/logs/ALERTS.log"
    "$MC_H/bin/beat.sh" "$(jq -nc --arg akey "conductor:$key:$st" --arg l "[merge-conductor] $text" \
      '{kind:"fleet_alert",project:"fleet",akey:$akey,line:$l}')" >/dev/null 2>&1 || true
  fi
}

# --- The PAUSED hold (BH-1201) ----------------------------------------------
# AN OPERATOR WHO SWITCHED THE LANE OFF IS STILL PAGED BY IT. The hub's
# ALERTS.log carried 424 conductor age pages between 2026-09-13 and 09-21 while
# MODE was kill-switch — pages about PRs nothing was going to touch, because the
# two age pagers (mc_stuck_check and the paging arm below) have never read the
# mode. Under kill-switch and observe those two now HOLD: one row per
# (PR, state, head, kind) in the worker's conductor_held_pages table, no alert,
# and — this is the part that makes it a pause rather than a mute — no marker
# and no `alerted` mark either, so the page is still OWED. When the mode comes
# back the tick's first act is to send them, oldest first, capped.
#
# WHAT IS DELIBERATELY NOT HELD: everything else. mc_alert itself is untouched
# and every other caller of it pages in every mode (a deploy that is not
# serving, an identity GitHub refuses, a PR closed unmerged with its issue still
# open) — those are facts about the world, not about this lane's throttle. State
# notes (BH-979) are not held either, because they never paged.
#
# UNSET IS NOT A HOLD. bin/merge-sweep.sh, bin/blocked-resolver.sh,
# bin/review-prs.sh, bin/batch-resolve.sh and bin/run-build.sh all source this
# lib with no MC_MODE at all, and they must page exactly as they do today. Only
# the conductor exports it (bin/merge-conductor.sh, beside MODE).
mc_hold_mode() { case "${MC_MODE:-}" in kill-switch|observe) return 0 ;; esac; return 1; }

# The tick's own cache of what the worker says is held, and the tick's own
# counters. TICK-KEYED, like mc_count_file and mc_tick_eject_file: the conductor
# has had no global lock since 2026-09-14, so two overlapping ticks share this
# directory. A bare `held.tsv` would let tick B's begin truncate the cache tick
# A is walking, and a bare counter file would sum both ticks into one summary.
# mc_tick_gc prunes them on the same daily rule as every other file in here.
mc_hold_cache_file() {
  printf '%s/%s.held.tsv' "$MC_TICK_DIR" "$(mc_safe_name "${MC_TICK_ID:-notick}")"
}
# One file per (kind, state), APPEND-ONLY and counted by line. Append-only
# because the pagers run inside per-project pr_worker subshells: a
# read-modify-write of one counter from two of them loses whichever lost the
# race, and a page that is held but not counted is a summary that under-reports
# on exactly the busiest tick.
mc_hold_count_file() { # mc_hold_count_file <kind> <state>
  printf '%s/%s.hold-count.%s.%s' "$MC_TICK_DIR" "$(mc_safe_name "${MC_TICK_ID:-notick}")" \
    "$(mc_safe_name "${1:-}")" "$(mc_safe_name "${2:-}")"
}
# The worker's WHOLE held list for this tick (BH-2361), and its outage latch.
mc_hold_rows_file() {
  printf '%s/%s.held-rows.tsv' "$MC_TICK_DIR" "$(mc_safe_name "${MC_TICK_ID:-notick}")"
}
# mc_hold_rows_load — at most ONE GET per tick, under the pr-state-rows flag.
#   Whole list -> the rows file (empty = nothing held). Anything else -> the
#   latch and one log line, so the local cache decides for the rest of the tick.
#   rc 2 (no held route) latches quietly, as mc_hold_tick_begin treats it.
mc_hold_rows_load() {
  local f tick rows rc tmp
  type pr_rows_on >/dev/null 2>&1 && pr_rows_on || return 0
  command -v held_pages_whole >/dev/null 2>&1 || return 0
  f=$(mc_hold_rows_file); tick="$MC_TICK_DIR/$(mc_safe_name "${MC_TICK_ID:-notick}")"
  [ -e "$f" ] || [ -e "$tick.held-rows.down" ] || [ -e "$tick.pr-rows-down" ] && return 0
  mkdir -p "$MC_TICK_DIR" 2>/dev/null
  rows=$(held_pages_whole 500); rc=$?
  if [ "$rc" -eq 0 ]; then
    tmp=$(mktemp "$MC_TICK_DIR/held-rows.XXXXXX") || return 0
    [ -n "$rows" ] && printf '%s\n' "$rows" > "$tmp"
    mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp"
    return 0
  fi
  if ( set -C; : > "$tick.held-rows.down" ) 2>/dev/null && [ "$rc" -ne 2 ]; then
    mc_log "held rows unreadable (rc=$rc) — local held marks decide"
  fi
  return 0
}

# mc_hold_cached <key> <state> <head> <kind> — rc 0 when the worker already
#   holds this exact row, which is the PK of conductor_held_pages. Two callers
#   read it and both mean the same thing: the FLUSH owns this row, so the pager
#   must not page it, hold it again, or spend its mark — in ANY mode.
mc_hold_cached() {
  local f repo num
  repo="${1%#*}"; num="${1##*#}"
  # ROWS FIRST (BH-2361): the worker's whole held list, read once per tick. It
  # can only ADD a "held" answer; not listed, or unreadable, falls to the local
  # cache below exactly as before.
  mc_hold_rows_load
  f=$(mc_hold_rows_file)
  if [ -s "$f" ] && awk -F'\t' -v r="$(printf '%s' "$repo" | tr '[:upper:]' '[:lower:]')" -v n="$num" \
       -v s="${2:-}" -v h="${3:-}" -v k="${4:-}" \
       'tolower($1)==r && $2==n && $3==s && $4==h && $5==k {found=1; exit} END{exit !found}' "$f"; then
    return 0
  fi
  f=$(mc_hold_cache_file); [ -s "$f" ] || return 1
  awk -F'\t' -v r="$repo" -v n="$num" -v s="${2:-}" -v h="${3:-}" -v k="${4:-}" \
    '$1==r && $2==n && $3==s && $4==h && $5==k {found=1; exit} END{exit !found}' "$f"
}

# mc_hold_page <key> <state> <head> <kind> <text> <mark>
#   ALWAYS rc 0: every caller uses it as a statement, never in an `&&` chain.
#   A failed PUT is logged with its rc and NOT counted as held (D9) — the row
#   keeps owing its page and the next tick offers it again, in whatever mode
#   that tick is in. "Stamped held without a row" is the one outcome that would
#   drop a page silently, so it cannot happen here.
mc_hold_page() {
  local key="${1:-}" st="${2:-}" head="${3:-}" kind="${4:-}" text="${5:-}" mark="${6:-}"
  local repo num rc line
  mc_hold_cached "$key" "$st" "$head" "$kind" && return 0
  if ! command -v held_page_put >/dev/null 2>&1; then
    mc_log "$key $kind hold: no jobs client on this box — not held, not paged"
    return 0
  fi
  repo="${key%#*}"; num="${key##*#}"
  held_page_put "$repo" "$num" "$st" "$head" "$kind" "$text" "$mark" "${MC_MODE:-}" ; rc=$?
  if [ "$rc" -ne 0 ]; then
    mc_log "$key $kind hold: held_page_put rc=$rc — NOT counted as held, the page is still owed"
    return 0
  fi
  mkdir -p "$MC_TICK_DIR" 2>/dev/null
  # The cache row is what makes a second call this tick — from this worker or
  # any other — a no-op rather than a second PUT. Tabs and newlines are flattened
  # because the cache IS a TSV; the text column here is never paged from (the
  # flush reads the worker's own copy at the next tick's begin).
  line=$(printf '%s' "$text" | tr '\t\n' '  ')
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$repo" "$num" "$st" "$head" "$kind" "$line" "$mark" "${MC_MODE:-}" "-" "-" \
    >> "$(mc_hold_cache_file)"
  echo 1 >> "$(mc_hold_count_file "$kind" "$st")"
  return 0
}

# mc_hold_flush_one <repo> <num> <state> <head> <kind> <text> <mark> <mode> <first_held_at>
#   ORDER IS PAGE -> MARK -> RELEASE, never release first. A crash between the
#   page and the mark re-pages once next tick (bounded, and visible). A crash
#   between the mark and the release re-attempts only the release, because the
#   mark-already-stands guard below refuses to page a row twice. "Released
#   without paging" is impossible: the release is the last thing that happens.
mc_hold_flush_one() {
  local repo="$1" num="$2" st="$3" head="$4" kind="$5" text="$6" mark="$7" mode="$8" first="$9"
  local key="$repo#$num" row rst rhead rsince why rc crit="" page=1 mark_rec f6
  # THE MARK COMES BACK FROM AN API AND IS USED AS A FILENAME. mc_stuck_check
  # sends a basename, but the worker stores any string it is given, and the
  # STUCK arm below opens `$MC_STUCK_DIR/$mark` for writing AS ROOT on the hub.
  # A row PUT with `../../..` in that field would truncate a file outside the
  # marker directory, or — by naming one that already exists — flip the guard
  # below to page=0 and drop the page without sending it. Reduce it to a leaf
  # here, once, before either use.
  [ -n "$mark" ] && mark=$(basename -- "$mark" 2>/dev/null)
  case "$mark" in .|..|/*) mark="" ;; esac
  # held_pages_list renders text through jq's @tsv, so a tab or a newline in an
  # operator's line arrives escaped. Undo it here and the flushed page is
  # byte-for-byte the un-held one plus the held-since suffix.
  text=$(printf '%b' "$text")
  row=$(mc_row_get "$key")
  rst=$(cut -f2 <<<"$row"); rhead=$(cut -f4 <<<"$row"); why=$(cut -f7 <<<"$row")
  rsince=$(cut -f3 <<<"$row")
  if [ "$rst" != "$st" ] || [ "$rhead" != "$head" ]; then
    # THE PR MOVED UNDER THE PAUSE — merged, closed, rebased, re-classified.
    # Paging about a state it left is worse than not paging at all.
    command -v held_page_release >/dev/null 2>&1 \
      && { held_page_release "$repo" "$num" "$st" "$head" "$kind" moved >/dev/null || rc=$?; }
    mc_log "$key $kind held page released: the PR moved (row ${rst:--}@${rhead:0:8}, held $st@${head:0:8}) — not paged"
    return 0
  fi
  # THE MARK A FLUSHED BUDGET PAGE SPENDS IS TODAY'S, NOT THE ONE IT WAS HELD
  # WITH. A park's mark carries the UTC day (`BLOCKED_HUMAN@<since>@20260913`),
  # because a park pages once a day; a park held on the 13th and flushed on the
  # 22nd that recorded its held mark verbatim would be paged AGAIN by
  # mc_budget_check seconds later, in the same tick, on today's mark — the row
  # is released by then, so nothing suppresses it. What this page spends is the
  # mark mc_budget_check would compute for the row as it stands right now, which
  # is what makes the flushed page count as today's page for that park. Every
  # other BUDGET mark (`<STATE>@<since>`) is unchanged: it is already exactly
  # that value whenever the state entry the flush checked is still the row's.
  mark_rec="$mark"
  [ "$kind" = BUDGET ] && [ -n "$mark" ] && mc_park_state "$st" \
    && mark_rec="$st@$rsince@$(date -u +%Y%m%d)"
  # ONE PAGE PER ROW EVER, BY CONSTRUCTION. If the mark already stands, this row
  # was paged on an earlier tick whose release never landed; re-attempt the
  # release and send nothing. Either spelling counts as standing: the mark this
  # row was held with, or the one a flush on an earlier tick recorded for it.
  f6=$(cut -f6 <<<"$row")
  case "$kind" in
    STUCK)  [ -n "$mark" ] && [ -e "$MC_STUCK_DIR/$mark" ] && page=0 ;;
    BUDGET) [ -n "$mark" ] && { [ "$f6" = "$mark" ] || [ "$f6" = "$mark_rec" ]; } && page=0 ;;
  esac
  if [ "$page" = 1 ]; then
    mc_park_state "$st" && crit=1
    mc_alert "$key" "$(mc_state_display "$st" "$why")" "$text (held since $first under mode=$mode)" "$crit"
    case "$kind" in
      STUCK)  [ -n "$mark" ] && { mkdir -p "$MC_STUCK_DIR" 2>/dev/null; : > "$MC_STUCK_DIR/$mark"; } ;;
      BUDGET) [ -n "$mark" ] && { mc_row_put "$key" "$rst" "$rsince" "$rhead" \
                "$(cut -f5 <<<"$row")" "$mark_rec" "$why" "$(cut -f8 <<<"$row")"
                # An alert mark appends its state event (BH-1387): file row, then
                # event. No ledgers row here, so flag off stays byte for byte.
                command -v mc_state_event_put >/dev/null 2>&1 && mc_state_event_put "$key" "$rst" \
                  "$(date -u -d "@$rsince" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$rsince")" \
                  "$rhead" "$(cut -f5 <<<"$row")" "$why" "$(cut -f8 <<<"$row")" "$mark_rec"; } ;;
    esac
    mc_log "$key $kind flushed: paged (held since $first under mode=$mode)"
  else
    mc_log "$key $kind flush: the mark already stands — not paged again, retrying the release only"
  fi
  rc=0
  command -v held_page_release >/dev/null 2>&1 \
    && { held_page_release "$repo" "$num" "$st" "$head" "$kind" paged >/dev/null || rc=$?; }
  [ "$rc" -eq 0 ] || mc_log "$key $kind held page release rc=$rc — the page and the mark stand; the release retries next tick"
  return 0
}

# mc_hold_tick_begin — called ONCE per tick, in the main process, BEFORE the
#   project fan-out: every pager runs inside a pr_worker subshell and reads the
#   cache this writes, and the flush's marks are what make those pagers skip the
#   rows it just paged.
#   `--load-only` (a keyed tick, BH-1840) stops after the cache is written: no
#   flush, no release, no count file, so its pagers defer to the cron tick's flush.
#   Either way it ends by loading the worker's whole held list for the tick's
#   pagers (mc_hold_rows_load, BH-2361), AFTER the flush has released what it paged.
#   The flag is spelled out, not passed as "$@": bin/merge-conductor.sh probes
#   this function's body for `--load-only` before a keyed tick calls it.
mc_hold_tick_begin() {
  case "${1:-}" in --load-only) mc_hold_tick_flush --load-only ;; *) mc_hold_tick_flush ;; esac
  mc_hold_rows_load
  return 0
}
mc_hold_tick_flush() {
  local cache rows rc max i=0 remain=0 keep load_only=""
  [ "${1:-}" = --load-only ] && load_only=1
  mkdir -p "$MC_TICK_DIR" 2>/dev/null
  cache=$(mc_hold_cache_file)
  # A RE-ENTERED TICK ID STARTS CLEAN. Same tick, same files: leaving yesterday's
  # counters would double-count the summary and leaving the cache would suppress
  # rows the worker has already released.
  rm -f "$cache" "$MC_TICK_DIR/$(mc_safe_name "${MC_TICK_ID:-notick}").hold-count."* \
    "$(mc_hold_rows_file)" "$MC_TICK_DIR/$(mc_safe_name "${MC_TICK_ID:-notick}").held-rows.down" 2>/dev/null
  : > "$cache"
  if ! command -v held_pages_list >/dev/null 2>&1; then
    mc_log "held pages: no jobs client on this box — nothing flushed, nothing suppressed twice"
    return 0
  fi
  rows=$(held_pages_list 500); rc=$?
  # An empty table is rc 0 with no rows. rc 2 is _jobs_req's 404: a worker that
  # does not serve the held route yet. That is also treated as quiet, since the
  # conductor cannot hold or flush against a route that is not there. Only an
  # outage (rc 1) or an unparseable answer is worth a line; logging the quiet
  # cases would put 288 "unreadable" lines a day in front of the reader who
  # needs to notice the real one.
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 2 ]; then
    mc_log "held pages unreadable this tick (rc=$rc) — nothing flushed, nothing suppressed twice"
    return 0
  fi
  [ "$rc" -eq 0 ] && [ -n "$rows" ] && printf '%s\n' "$rows" > "$cache"
  [ -s "$cache" ] || return 0
  [ -n "$load_only" ] && return 0
  case "${MC_MODE:-}" in merge|actions) ;; *) return 0 ;; esac
  max=""
  command -v lane_knob >/dev/null 2>&1 && max=$(lane_knob merge-conductor MC_FLUSH_MAX 2>/dev/null)
  case "$max" in ''|*[!0-9]*|0) max="${MC_FLUSH_MAX:-10}" ;; esac
  case "$max" in ''|*[!0-9]*|0) max=10 ;; esac
  keep="$cache.keep"; : > "$keep"
  local repo num st head kind text mark mode first last
  while IFS=$'\t' read -r repo num st head kind text mark mode first last; do
    [ -n "$repo" ] && [ -n "$num" ] || continue
    i=$((i+1))
    if [ "$i" -gt "$max" ]; then
      # CAPPED WORK IS DEFERRED, NEVER DROPPED (D12). The row stays in the cache
      # so this tick's pagers still skip it, and the next tick flushes it.
      remain=$((remain+1))
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$repo" "$num" "$st" "$head" "$kind" "$text" "$mark" "$mode" "$first" "$last" >> "$keep"
      continue
    fi
    mc_hold_flush_one "$repo" "$num" "$st" "$head" "$kind" "$text" "$mark" "$mode" "$first"
  done < "$cache"
  mv -f "$keep" "$cache" 2>/dev/null
  [ "$remain" -gt 0 ] && mc_log "flush: $remain held pages remain, next tick"
  return 0
}

# mc_hold_breakdown <stuck-count> <"STATE n" lines> — the parenthetical, built
#   once for both readers of it (the per-tick summary line and the reminder),
#   because two copies of this format drift and a reader comparing the log line
#   with the DM would be reading two different spellings of the same thing.
#   THE ZEROS ARE COMPUTED, NOT ASSUMED (D13): the three named states are always
#   printed so a reader can tell "none" from "not measured", and every other
#   state appears only when it has a count.
mc_hold_breakdown() {
  local stuck="${1:-0}" states="${2:-}" out st n extra
  out="STUCK $stuck"
  for st in HEAD_MOVED BLOCKED_HUMAN RED_TWICE; do
    n=$(printf '%s\n' "$states" | awk -v k="$st" '$1==k {print $2; exit}')
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    out="$out, $st $n"
  done
  extra=$(printf '%s\n' "$states" | awk '$1!="HEAD_MOVED" && $1!="BLOCKED_HUMAN" && $1!="RED_TWICE" && $2>0 {printf ", %s %s", $1, $2}')
  printf '%s%s' "$out" "$extra"
}

# mc_hold_tick_end — called ONCE per tick, right before hb_done: the summary
#   line, the two published settings rows, and the paused reminder.
#
#   TWO DIFFERENT NUMBERS, AND THE DIFFERENCE IS THE POINT. The tick counters
#   say how many pages THIS tick suppressed, which is what the log line reports.
#   The published `merge-conductor.held_pages` row and the reminder's "is
#   holding N pages" are statements about the set that IS held right now, and
#   that set is the tick's cache: the worker's own list, read at tick begin,
#   plus whatever this tick added to it. Summing the counters for those two
#   would report 0 on every tick of a nine-day pause after the first — nothing
#   new is held once every aged PR is already held — so the operator's only
#   view of the pause would say it holds nothing while the worker holds dozens.
mc_hold_tick_end() {
  local prefix f rest kind st n total=0 stuck=0 states breakdown summary rc stamp every now
  local cache hstates hstuck=0 htotal=0 hbreakdown
  [ -n "${MC_MODE:-}" ] || return 0
  prefix="$MC_TICK_DIR/$(mc_safe_name "${MC_TICK_ID:-notick}").hold-count."
  states=""
  for f in "$prefix"*; do
    [ -f "$f" ] || continue
    n=$(wc -l < "$f" 2>/dev/null | tr -d ' ')
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    rest="${f#"$prefix"}"; kind="${rest%%.*}"; st="${rest#*.}"
    total=$((total+n))
    [ "$kind" = STUCK ] && stuck=$((stuck+n))
    states="$states$st $n"$'\n'
  done
  # Summed BY STATE, sorted, so the same tick always prints the same string.
  states=$(printf '%s' "$states" | awk 'NF==2 {a[$1]+=$2} END{for (k in a) print k, a[k]}' | sort)
  breakdown=$(mc_hold_breakdown "$stuck" "$states")
  if mc_hold_mode; then
    mc_log "mode=$MC_MODE: $total PRs would have paged ($breakdown) — suppressed"
  fi
  # WHAT IS HELD, from this tick's cache: every row the worker listed at tick
  # begin, minus the ones the flush released, plus the ones this tick held. An
  # unreadable list leaves an empty cache and publishes 0 — the outage itself is
  # already one log line from mc_hold_tick_begin.
  cache=$(mc_hold_cache_file)
  hstates=""
  if [ -s "$cache" ]; then
    htotal=$(awk -F'\t' 'NF>=5 && $1!="" {n++} END{print n+0}' "$cache")
    hstuck=$(awk -F'\t' 'NF>=5 && $5=="STUCK" {n++} END{print n+0}' "$cache")
    hstates=$(awk -F'\t' 'NF>=5 && $1!="" {a[$3]++} END{for (k in a) print k, a[k]}' "$cache" | sort)
  fi
  case "$htotal" in ''|*[!0-9]*) htotal=0 ;; esac
  case "$hstuck" in ''|*[!0-9]*) hstuck=0 ;; esac
  hbreakdown=$(mc_hold_breakdown "$hstuck" "$hstates")
  # PUBLISHED IN EVERY MODE, including merge: a reader that keys on
  # merge-conductor.mode must never sit on a row a whole pause older than the
  # truth, and "nothing held" is the word 0, not a missing row.
  summary="$htotal"
  if [ "$htotal" -gt 0 ]; then
    summary="$htotal$(printf '%s\n' "$hstates" | awk '$2>0 {printf " %s=%s", $1, $2}')"
  fi
  if command -v conductor_mode_publish >/dev/null 2>&1; then
    conductor_mode_publish "$MC_MODE" "$summary" >/dev/null 2>&1; rc=$?
    [ "$rc" -eq 0 ] || mc_log "conductor_mode_publish rc=$rc — the previously published row stands"
  fi
  # THE REMINDER IS NOT AN ALARM. A paused conductor is a deliberate state, so
  # this says so once every MC_HOLD_REMINDER_S, non-critical, and names the way
  # out. Silence for a week is how a pause somebody forgot to lift becomes an
  # outage nobody can see.
  mc_hold_mode || return 0
  stamp=$(cat "$MC_STATE_DIR/hold-reminder-at" 2>/dev/null || echo 0)
  case "$stamp" in ''|*[!0-9]*) stamp=0 ;; esac
  every=""
  command -v lane_knob >/dev/null 2>&1 && every=$(lane_knob merge-conductor MC_HOLD_REMINDER_S 2>/dev/null)
  case "$every" in ''|*[!0-9]*|0) every="${MC_HOLD_REMINDER_S:-21600}" ;; esac
  case "$every" in ''|*[!0-9]*|0) every=21600 ;; esac
  now=$(mc_now)
  [ "$(( now - stamp ))" -ge "$every" ] || return 0
  mc_alert conductor PAUSED "the conductor is in mode=$MC_MODE and is holding $htotal pages ($hbreakdown) — nothing here is broken; pages flush when the mode returns (see bin/harness-ctl.sh show merge-conductor)"
  # STAMPED AFTER THE SEND, never before: a stamp without a send is six hours of
  # silence nobody asked for, while a send without a stamp is one extra reminder.
  mkdir -p "$MC_STATE_DIR" 2>/dev/null
  printf '%s\n' "$now" > "$MC_STATE_DIR/hold-reminder-at"
  return 0
}

# mc_budget_check <key> <state> <since-epoch> <url> <detail>
#   One alert per (PR, state entry): the row's `alerted` field holds
#   "<STATE>@<since>". BLOCKED_HUMAN pages at once and again once per UTC day
#   ("<STATE>@<since>@<day>"). A budget alert is not a transition.
mc_budget_check() {
  local key="$1" st="$2" since="$3" url="$4" detail="$5" budget age mark alerted row
  budget=$(mc_budget "$st"); [ "$budget" -ge 0 ] || return 0
  age=$(( $(mc_now) - since ))
  [ "$age" -ge "$budget" ] || return 0
  row=$(mc_row_get "$key"); alerted=$(cut -f6 <<<"$row")
  mark="$st@$since"
  mc_park_state "$st" && mark="$st@$since@$(date -u +%Y%m%d)"
  [ "$alerted" = "$mark" ] && return 0
  local crit=""; mc_park_state "$st" && crit=1
  # A PARK THE RESOLVER OWNS IS NOT A PAGE (2026-09-13). bin/blocked-resolver.sh
  # drains these on its own cron and alerts exactly once, on ABANDONED, with the
  # whole attempt list. Paging daily in the meantime trains the reader to ignore
  # the one alert that does mean something. The row still ages, still records
  # its mark, and still says so in the conductor log.
  local why; why=$(cut -f7 <<<"$row")
  # A PROVENANCE HOLD THE CONDUCTOR IS ALREADY FIXING IS NOT A PAGE EITHER
  # (2026-09-15, project-5 #1058/#1071, project-4 #1478). `provenance` is parked and
  # paged in the same tick that buys the claude read which clears it (the
  # headbound_review provenance branch), so every one of these paged
  # "BLOCKED_HUMAN — 0m in BLOCKED_HUMAN: provenance" and then merged on its
  # own minutes later. While the actions flag is on and the hold is younger
  # than MC_PROV_AUTO_SECS the row logs `auto-resolving` and keeps a marker
  # that is NOT the day mark, so the moment the window runs out (a read that
  # never came back, CI that never went green) it pages exactly as before.
  # Observe-only (flag off, kill switch on) still pages at once: nobody is
  # buying the read.
  local auto
  # AND NEITHER IS A ROW GITHUB IS REFUSING ON THE PUSH IDENTITY (BH-988). The
  # read that classified it already sent one alert naming the identity and the
  # base; a second page 30 minutes later says the same thing in weaker words.
  # Same shape as the resolver-owned park above: the row still ages, still
  # records its mark, and still says so in the conductor log.
  # A PARK bin/blocked-resolver.sh HAS CLAIMED PAGES TWICE AT MOST (BH-3630).
  # example-org/project-7#530 paged CRITICAL about every 30 minutes for days while
  # the resolver was the only thing that could move it. The claim file is the
  # page ledger here, not `alerted`: it pages once when parked, once more when
  # it is still parked MC_CLAIMED_REPAGE_S later AND the resolver has recorded
  # no rung in that span, and is silent after that — the resolver's own
  # CI_PARKED/ABANDONED alerts carry the ending. `alerted` still counts as
  # evidence of a page (a held page the flush sent stamps only the mark), and
  # the claim is stamped from it so the next wiped mark cannot re-page.
  local claim pagenow="" claimfirst="" claimstale="" line="$((age/60))m in $st: $detail — $url"
  local c_at a_at p_at s_at repage cnow
  if mc_identity_blocked "$why"; then
    mc_log "$key $((age/60))m in $st — the push identity is not permitted on the base; the IDENTITY_NOT_PERMITTED alert is the page, not this one: $url"
  elif mc_park_state "$st" && mc_resolver_owns "$why"; then
    mc_log "$key $((age/60))m in $(mc_state_display "$st" "$why") ($why) — handed to bin/blocked-resolver.sh, not paged: $url"
  elif mc_park_state "$st" && claim=$(mc_resolver_claim_get "$key" "$(cut -f4 <<<"$row")"); then
    IFS=$'\t' read -r _ _ c_at a_at p_at s_at <<<"$claim"
    case "${c_at:-}" in ''|*[!0-9]*) c_at=$(mc_now) ;; esac
    case "${a_at:-}" in ''|*[!0-9]*) a_at="$c_at" ;; esac
    case "${p_at:-}" in ''|*[!0-9]*) p_at="" ;; esac
    case "${s_at:-}" in ''|*[!0-9]*) s_at="" ;; esac
    repage="${MC_CLAIMED_REPAGE_S:-86400}"
    case "$repage" in ''|*[!0-9]*|0) repage=86400 ;; esac
    cnow=$(mc_now)
    if [ -z "$p_at" ]; then
      case "$alerted" in
        "$st@$since"|"$st@$since@"[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]|"$st@$since@claimed-paged"|"$st@$since@claimed-stale")
          mc_resolver_claim_mark "$key" paged; p_at="$cnow" ;;
      esac
    fi
    if [ -z "$s_at" ] && [ "$alerted" = "$st@$since@claimed-stale" ]; then
      mc_resolver_claim_mark "$key" stale; s_at="$cnow"
    fi
    if [ -z "$p_at" ]; then
      claimfirst=1; pagenow=1; mark="$st@$since@claimed-paged"
    elif [ -z "$s_at" ] && [ "$age" -ge "$repage" ] && [ "$(( cnow - a_at ))" -ge "$repage" ]; then
      claimstale=1; pagenow=1; mark="$st@$since@claimed-stale"
      line="$((age/60))m in $st: $detail — claimed by bin/blocked-resolver.sh $(( (cnow - c_at) / 3600 ))h ago, no resolver rung for $(( (cnow - a_at) / 3600 ))h — $url"
    else
      mark="$st@$since@claimed"
      [ "$alerted" = "$mark" ] && return 0
      mc_log "$key $((age/60))m in $st ($why) — claimed by bin/blocked-resolver.sh, not re-paged (last resolver rung $(( (cnow - a_at) / 60 ))m ago; re-pages once after $((repage/3600))h without one): $url"
    fi
  elif [ "$st" = BLOCKED_HUMAN ] && auto=$(mc_prov_autoresolving "$key" "$why" "$(cut -f4 <<<"$row")" "$age"); then
    mark="$st@$since@auto"
    [ "$alerted" = "$mark" ] && return 0
    mc_log "$key $((age/60))m in BLOCKED_HUMAN (provenance) — auto-resolving, not paged: $auto; pages after $((${MC_PROV_AUTO_SECS:-3600}/60))m if it has not cleared: $url"
  else
    pagenow=1
  fi
  if [ -n "$pagenow" ]; then
    # A MACHINERY-WAIT IS A NOTE, EVERYTHING ELSE PAGES (BH-979). mc_budget fires
    # at 30 minutes for HEAD_MOVED, NEEDS_REBASE, REBASING and at 4h for
    # STACKED_WAIT, and those are the bulk of the 1033 spool lines the
    # alert-triage lane was paying a strong model to re-read. READY (15m) and
    # QUEUED (60m) are notes too since BH-4717: mc_stuck_check pages them on its
    # own TTL, so a budget page here would be a second one. A park can never be
    # one of them — mc_park_state is checked first, so a state cannot be critical
    # on the line above and a silent note here.
    local statenote=""
    if ! mc_park_state "$st" && mc_state_note_only "$st" \
       && [ "${MC_STATE_NOTES_ALERT:-0}" != 1 ]; then
      # THE MARK RECORDS WHICH IT WAS (BH-979 round 2). `alerted` is spent by
      # this entry either way, so a mark that does not say "this was a note"
      # means an operator who later sets MC_STATE_NOTES_ALERT=1 — the documented
      # way back to the old paging — gets silence for every entry already noted:
      # the flag reads as on, and nothing pages. Same idiom as the @auto
      # provenance mark above: suffix it, and re-check it, so a note still
      # dedupes inside its own mode and a mode CHANGE pages once.
      statenote=1; mark="$mark@note"
      [ "$alerted" = "$mark" ] && return 0
    fi
    # THE HOLD (BH-1201), and ONLY where this call would reach mc_alert with an
    # empty statenote — parks and WAIT_CI-like states outside the note set. A
    # state note never paged, so there is nothing to hold about one.
    if [ -z "$statenote" ]; then
      local hhead; hhead=$(cut -f4 <<<"$row")
      # The flush owns this row, in every mode: return BEFORE the mc_row_put
      # below, so `alerted` is not spent by a page this function did not send.
      mc_hold_cached "$key" "$st" "$hhead" BUDGET && return 0
      if mc_hold_mode; then
        mc_log "$key $((age/60))m in $st — HELD (mode=$MC_MODE), not paged: $url"
        mc_hold_page "$key" "$st" "$hhead" BUDGET "$line" "$mark"
        # NO mc_row_put: the row still owes exactly one page, and the mark it
        # would spend is the one the flush records when that page goes out.
        return 0
      fi
    fi
    mc_alert "$key" "$(mc_state_display "$st" "$why")" "$line" "$crit" "$statenote"
    [ -n "$claimfirst" ] && mc_resolver_claim_mark "$key" paged
    [ -n "$claimstale" ] && mc_resolver_claim_mark "$key" stale
  fi
  mc_row_put "$key" "$st" "$since" "$(cut -f4 <<<"$row")" "$(cut -f5 <<<"$row")" "$mark" "$(cut -f7 <<<"$row")" "$url"
  mc_ledger_put "$key" "$st" "$(date -u -d "@$since" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$since")" \
    "$(cut -f4 <<<"$row")" "$(cut -f5 <<<"$row")" "-" "-" "$(cut -f7 <<<"$row")" "-" "$url" "$mark"
}
