#!/bin/bash
# bin/review-rescue.sh — hub cron (7,37): re-enter builds whose review lane
# stopped without a PR instead of letting them orphan (the operator go 2026-08-13;
# TK-49's review died overnight and the PR sat 20h with only a DRAFT review —
# nothing owned the retry).
#
# THREE ORPHAN SHAPES, one lane:
#
#   A. DIED MID-REVIEW — RESULT says REVIEW_BLOCKED but review.md never reached
#      a VERDICT line: the review session died (timeout, OOM, session kill)
#      between claiming the stage and finishing it. Re-run the review.
#
#   B. FALSELY BLOCKED BY THE TEST-TAMPER GATE (2026-09-13) — RESULT's first
#      line is `REVIEW_BLOCKED test-tamper: …`. On 2026-09-13 thirty-nine pool
#      builds fleet-wide (23 on project-5) held this terminal because the
#      scanner counted a RETITLED or SPLIT test case as a deletion. Their branch
#      was pushed and no PR was ever opened. Four of them even carried a real
#      `VERDICT: APPROVE` from the original round — they were not waiting for a
#      review, they were waiting for a PR. So a test-tamper block is a candidate
#      EVEN WITH a verdict, the gate is RE-RUN here (the scanner has since been
#      fixed), and a standing APPROVE is reused rather than re-bought.
#
# The pipeline treats REVIEW_BLOCKED as terminal, the tier-2 sweep only moves
# completed APPROVEs, and triage's results sweep just alerts — so without this
# lane the PR rots.
#
# Per tick: take the OLDEST unrescued candidates (up to RESCUE_PER_TICK, default
# 3 — the bound on cost), find each one's open PR or pushed branch, and in a
# throwaway worktree with a HARD deadline: re-scan a test-tamper block, merge
# fresh main into the branch, OPEN THE PR if only a branch exists, and either
# reuse a standing APPROVE or re-run the adversarial review.
#
# NOTHING QUEUES BEHIND ANOTHER RESCUE (the operator, 2026-09-13: "change the rule so we
# never lock and serialize"). This lane used to hold ONE global
# locks/review-rescue.lock for the whole tick, so every rescue in the fleet
# waited behind one 40-minute Fable review and 39 stranded builds needed a
# fortnight of ticks. Candidates now run in parallel, RESCUE_PARALLEL (default 8)
# at a time, and the only lock is the per-KEY one bin/run-build.sh already uses —
# taken with `flock -n` purely so a rescue can never race a LIVE build of the
# same key. A held key is skipped, never waited on. On APPROVE -> RESULT becomes `PR_CREATED <url>` with a REAL
# url so the normal merge lanes (tier-1 gate / tier-2 sweep / the operator) take over;
# BLOCK -> leave REVIEW_BLOCKED (now with a genuine verdict) and log it for
# bin/blocked-resolver.sh's fix round; a re-scan that still finds a real deletion
# -> hand the build to that resolver's ADJUDICATE rung, which buys one Fable
# ruling on the deletion instead of waiting for anybody.
# Two attempts max, then the build is retired FROM THIS LANE (not from the
# fleet: the resolver picks it up as a fresh-rebuild candidate) — a rescue that
# hangs (like the 2h zero-output wedge on 2026-08-13) is killed by the deadline
# and counted as an attempt. The RESCUE PATH never touches the ledger: it rewrites
# RESULT, which is what the merge lanes read.
#
# C. NO DIR ON THE HUB (BH-4437) — `ledger_materialize` below. A REVIEW_BLOCKED
#    build with no verdict whose pool box was reaped before its result was
#    relayed exists only in the jobs ledger and on origin. The pass rebuilds its
#    record as builds/pool-<build_dir>/ from the ledger row, and the walk then
#    rescues it like any relayed dir. With no PR and no pushed branch it gets one
#    RESCUE_OUTCOME: no-branch line and one ALERTS line, never a silent retire.
#
# D. HUMAN STEP DONE (BH-6536) — RESULT says REVIEW_BLOCKED and review.md DOES
#    have a verdict, but every blocking finding of its final round is a step a
#    person has to take (bin/lib/needs-human/step-done.sh nh_sd_human_only).
#    TK-232 (project-6-os, 2026-10-13) blocked only on "migration 0020 not
#    applied in prod"; the person applied it and posted HUMAN-STEP-DONE, and
#    nothing re-reviewed the branch. Such a record is offered on its own per-tick
#    cap (RESCUE_HUMAN_STEP_PER_TICK). With no person's HUMAN-STEP-DONE: comment
#    after the RESULT it only writes the ticket_stage row human-step-waiting: no
#    attempt, no model call. With one, the pushed head is re-reviewed with the
#    person's evidence in the prompt; APPROVE opens the PR, BLOCK opens it too
#    and posts the round as a signed review, which bin/blocked-resolver.sh reads
#    as review-changes-requested (a fix round). It never enqueues a build.
#    Kill switch: RESCUE_HUMAN_STEP=0 (the walk is then exactly the A/B/C one).
#
# A FIFTH SHAPE, LEDGER-ONLY (BH-858) — `verdict_backfill` below, which runs
# before the candidate walk and shares nothing with it. A record whose terminal
# is PR_CREATE_FAILED and whose review.md ends in VERDICT: APPROVE holds a real
# judgement that was never written down (until BH-858 the verdict row needed a PR
# to exist first). That pass writes ONE settled tier-2 verdict row per such
# record, bound to the sha the review ran on, and pages once when a PR owes a
# verdict nothing here can produce. It opens no PR, buys no review, takes no
# worktree and calls no gh. Cap: VERDICT_BACKFILL_MAX (25).
# Kill switch: the settings row switch.review-rescue-disabled[.<box>], read
# through lane_switch (bin/lib/lane-switch.sh); with no row, flag_active
# review-rescue-disabled when the jobs client is loaded (lane_switch's settings
# fetch loads it; a pause_flags row reconciled into the file, then the file),
# else the bare file, which is what a still-warm settings cache leaves.
set -uo pipefail
# RUN MODES (BH-6893). No argument is the fleet run: every project's records in
# one process. `--project <p>` (or `--project=<p>`) works on <p>'s records only,
# under locks/review-rescue-<p>.lock. `--dispatch` is the cron tick: pl_dispatch
# starts (or, placed fly, enqueues) one `--project` run per project and returns.
# Any other argument is ignored with one log line. The mode block is below the
# lane gate and the kill switch.
RR_DISPATCH=""; RR_PROJECT=""; RR_PROJECT_SET=""; RR_JUNK=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dispatch) RR_DISPATCH=1 ;;
    --project) RR_PROJECT_SET=1; RR_PROJECT="${2-}"; [ "$#" -ge 2 ] && shift ;;
    --project=*) RR_PROJECT_SET=1; RR_PROJECT="${1#--project=}" ;;
    *) RR_JUNK="${RR_JUNK:+$RR_JUNK }'$1'" ;;
  esac
  shift
done
if [ -n "$RR_DISPATCH" ] && [ -n "$RR_PROJECT_SET" ]; then
  echo "review-rescue: --dispatch and --project do not go together — no run" >&2
  exit 2
fi
# BH-2303: every model call this lane makes names the lane, so its cost rows
# carry lane_id and its LLM_* knobs (on/off, runners, daily cap) bind it alone.
export AGENT_CALL_LANE=review-rescue
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")
# THE ENV LOAD IS ABOVE THE LIB SOURCES ON PURPOSE (#469). bin/lib/gh-app-auth.sh
# and bin/lib/gh-repo-token.sh snapshot "the token this shell started with" AT
# SOURCE TIME, and cron/hub.cron runs this lane with no GH_TOKEN in the crontab
# env. While this load sat at the BOTTOM of the file both snapshots were empty,
# so once bin/ensure-box-gh-app-default.sh logs the hub's keyring out, a
# candidate on a repo the App cannot mint for has no PAT rung left and is left
# un-rescued. bin/run-triage.sh and bin/reconcile-prs.sh load the env here too.
# The knobs below now resolve from global.env as well as from the process env,
# which is what an operator who sets one there already expects.
set -a; . "$HENV/global.env" 2>/dev/null; set +a

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-review-rescue
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off review-rescue.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
# The ONE verdict reader (bin/lib/verdict-parse.sh, BH-1625). Missing, every
# verdict reads unknown — never APPROVE.
. "${HARNESS:-/root/harness}/bin/lib/verdict-parse.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/lib/verdict-parse.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit review-rescue
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    review-rescue
command -v verdict_prime >/dev/null 2>&1 && verdict_prime || true
REPOS="${REPOS_ROOT:-/root/repos}"
# The hub clones carry a tokenless https origin and no credential store; the
# merge conductor already solved git auth there (GIT_ASKPASS + token probe).
# BH-4080: the merge identity's defaults (also sourced by merge-conductor-lib).
# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-$(dirname "${BASH_SOURCE[0]}")/lib/deployment.sh}" || exit 1
. "$H/bin/lib/merge-conductor-lib.sh" 2>/dev/null || { mc_git_auth() { return 1; }; mc_git_auth_clear() { :; }; }
# The hub's default token cannot see every repo (project-5 was invisible to it
# for ten hours on 2026-09-12); gh_repo_use_token picks the token that can, for
# gh AND for mc_git_auth, which reads GH_TOKEN. Absent in the test scratch tree.
[ -r "$H/bin/lib/gh-repo-token.sh" ] && . "$H/bin/lib/gh-repo-token.sh"
# shellcheck source=bin/lib/gh-app-auth.sh
[ -r "$H/bin/lib/gh-app-auth.sh" ] && . "$H/bin/lib/gh-app-auth.sh"   # App token per repo (#425); unarmed box untouched
# shellcheck source=bin/lib/gh-limit-logger.sh
[ -r "$H/bin/lib/gh-limit-logger.sh" ] && . "$H/bin/lib/gh-limit-logger.sh"
# shellcheck source=bin/lib/self-heal.sh
[ -r "$H/bin/lib/self-heal.sh" ] && . "$H/bin/lib/self-heal.sh"   # BH-4724: the rescued-APPROVE notice is info
# BH-5125: a BLOCK this lane hands to bin/blocked-resolver.sh is CLAIMED there,
# so the resolver's sweep can say why it has not acted yet and page when it
# never does. Absent on a box whose sync has not landed it: the line is still
# written, nothing is claimed.
# shellcheck source=bin/lib/handoff-watch.sh
[ -r "$H/bin/lib/handoff-watch.sh" ] && . "$H/bin/lib/handoff-watch.sh"
# BH-6536: the human-step decisions and the ticket_stage writer. Missing, shape
# D is off and the walk is the A/B/C one.
# shellcheck source=bin/lib/needs-human.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/needs-human.sh" 2>/dev/null || . "$H/bin/lib/needs-human.sh" 2>/dev/null || true
command -v nh_sd_human_only >/dev/null 2>&1 || RESCUE_HUMAN_STEP=0
# BH-1651: the ticket-state read is REST. gh-rest.sh sources gh-rest-var.sh.
for _P in "$(dirname "$0")/lib/gh-rest.sh" "$H/bin/lib/gh-rest.sh"; do
  # shellcheck source=bin/lib/gh-rest.sh
  [ -r "$_P" ] && { . "$_P"; break; }
done
# One reset for both halves (#469): the identity tag and the App token, plus the
# PAT probe's own restore for the boxes that have no App configured.
rescue_reset() {
  command -v gh_default_auth_reset >/dev/null 2>&1 && gh_default_auth_reset
  type gh_repo_token_reset >/dev/null 2>&1 && gh_repo_token_reset
  return 0
}
LOG="$H/logs/review-rescue.log"
# RESCUE_PER_TICK and RESCUE_PARALLEL are registry knobs since BH-1940
# (lane_env_apply above sets them). The 3 below and the 0 at the parallel
# sanitizer only answer when lane-gate.sh or the registry could not run.
RESCUE_PER_TICK="${RESCUE_PER_TICK:-}"
case "$RESCUE_PER_TICK" in ''|*[!0-9]*) RESCUE_PER_TICK=3 ;; esac
# BH-6536 shape D. Registry knobs too; 1 and 5 only answer when the registry
# could not run. Its own cap, so a record waiting on a person never takes an A/B slot.
RESCUE_HUMAN_STEP="${RESCUE_HUMAN_STEP:-}"
case "$RESCUE_HUMAN_STEP" in ''|*[!01]*) RESCUE_HUMAN_STEP=1 ;; esac
RESCUE_HUMAN_STEP_PER_TICK="${RESCUE_HUMAN_STEP_PER_TICK:-}"
case "$RESCUE_HUMAN_STEP_PER_TICK" in ''|*[!0-9]*|0) RESCUE_HUMAN_STEP_PER_TICK=5 ;; esac
export RESCUE_HUMAN_STEP
# How many candidates may be in flight at once. A rescue is mostly waiting — on
# gh, on a git fetch, on a Fable review — so the cap is about the account and the
# box, not about ordering: they do not touch each other's keys (the per-key flock
# below is what guarantees that) and there is nothing to take turns over.
RESCUE_PARALLEL="${RESCUE_PARALLEL:-}"   # 0 = unlimited (default since 2026-09-14)
# BH-4437: how far back the ledger pass looks for a REVIEW_BLOCKED build with no
# dir on the hub. A registry knob (lane_env_apply above); 168 only answers when
# the registry could not run. It is a read window, so the first tick does not
# materialize every historic REVIEW_BLOCKED row the ledger holds.
RESCUE_LEDGER_LOOKBACK_H="${RESCUE_LEDGER_LOOKBACK_H:-}"
case "$RESCUE_LEDGER_LOOKBACK_H" in ''|*[!0-9]*|0) RESCUE_LEDGER_LOOKBACK_H=168 ;; esac
# RESCUE_ONLY=<project>: restrict a run to one project's build dirs, in all
# three passes. Oldest-first is right for the cron, wrong for an operator who
# needs one project's stranded builds back before the rest of the fleet's.
# `--project <p>` (BH-6893) sets it to <p>.
RESCUE_ONLY="${RESCUE_ONLY:-}"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
say() { echo "$(STAMP) $*" >> "$LOG"; }
alert() { HARNESS="$H" "$H/bin/alert-line.sh" "[review-rescue] $*"; }
# Refuse on an empty registry before anything else: an unresolved project below
# writes .review-rescued and gives up on that build permanently, so a registry
# blip would quietly retire every stuck review this lane touched.
# The list is kept: the ledger pass below (BH-4437) walks it.
PROJECTS=$("$H/bin/fleet-projects-or-alert.sh" review-rescue) || exit 1
# shellcheck source=lib/lane-switch.sh
. "$(dirname "$0")/lib/lane-switch.sh" || exit 1
lane_switch review-rescue-disabled && exit 0
# cron's PATH lacks /usr/local/bin, and this lane needs what lives there (claude
# via bin/agent-call.sh, codegraph, rtk). APPENDED, never prepended (BH-1250):
# prepending overrode whatever PATH the caller chose, so on a box that has a gh
# in /usr/local/bin the lane ran THAT gh — on the Fly test host that was the
# host's authenticated gh, talking to example-org/project-5, in place of the
# suite's fake. Appending keeps the cron need and drops the shadowing.
export PATH="$PATH:/usr/local/bin"

# >>> run mode (BH-6893)
# fleet     no argument: every project's records, one process (today's run)
# project   --project <p>: <p>'s records only (RESCUE_ONLY=<p>, PROJECTS=<p>)
# dispatch  --dispatch: pl_dispatch, then exit; the dispatcher touches no record
RR_MODE=fleet
mkdir -p "$H/logs" "$H/locks" 2>/dev/null
[ -z "$RR_JUNK" ] || say "unknown argument(s) $RR_JUNK ignored — this is the fleet run"
if [ -n "$RR_PROJECT_SET$RR_DISPATCH" ] && [ -r "$H/bin/lib/project-lanes.sh" ]; then
  # shellcheck source=bin/lib/project-lanes.sh
  . "$H/bin/lib/project-lanes.sh"
fi
if [ -n "$RR_PROJECT_SET" ]; then
  case "$RR_PROJECT" in
    ''|.*|*[!A-Za-z0-9._-]*) RR_NOTP=1 ;;
    *) case $'\n'"$PROJECTS"$'\n' in *$'\n'"$RR_PROJECT"$'\n'*) RR_NOTP=0 ;; *) RR_NOTP=1 ;; esac ;;
  esac
  if [ "$RR_NOTP" = 1 ]; then
    say "--project '$RR_PROJECT' is not a project in fleet.conf — no run"
    exit 2
  fi
  # The runner (bin/project-lane-run.sh) already holds the project lock on
  # PL_LOCK_FD. A run started by hand takes the same lock, so a hand run and a
  # dispatched run of one project never overlap. Fd 9 stays the parent's:
  # rescue_one's `exec 9>build-key-…` runs in its own subshell.
  if [ "${PL_LANE:-}" = review-rescue ] && [ "${PL_PROJECT:-}" = "$RR_PROJECT" ] \
     && [ -n "${PL_LOCK_FD:-}" ] && { : >&"$PL_LOCK_FD"; } 2>/dev/null; then
    :
  elif command -v pl_lock_take >/dev/null 2>&1; then
    pl_lock_take review-rescue "$RR_PROJECT" 9 || {
      say "a run of $RR_PROJECT is still live (locks/review-rescue-$RR_PROJECT.lock held) — exiting"; exit 0; }
  else
    exec 9>"$H/locks/review-rescue-$RR_PROJECT.lock"
    flock -n 9 || {
      say "a run of $RR_PROJECT is still live (locks/review-rescue-$RR_PROJECT.lock held) — exiting"; exit 0; }
  fi
  RR_MODE=project; RESCUE_ONLY="$RR_PROJECT"; PROJECTS="$RR_PROJECT"
  # `set -a; . env/global.env` above can reset GH_TOKEN: re-arm the project's own.
  command -v pl_token >/dev/null 2>&1 && pl_token >/dev/null 2>&1 || true
  say "project run $RR_PROJECT"
elif [ -n "$RR_DISPATCH" ]; then
  RR_SPREAD="${RESCUE_DISPATCH_SPREAD_SECS:-600}"
  case "$RR_SPREAD" in
    *[!0-9]*) say "RESCUE_DISPATCH_SPREAD_SECS='$RR_SPREAD' is not a whole number — using 600"; RR_SPREAD=600 ;;
  esac
  if command -v pl_dispatch >/dev/null 2>&1; then
    # Every pass of this lane is per project, so the dispatcher has no fleet part.
    say "$(pl_dispatch review-rescue "$RR_SPREAD" "$H/bin/review-rescue.sh" --project)"
    exit 0
  fi
  say "project-lanes.sh not loaded — this tick is the fleet run, in one process"
fi
# <<< run mode

slug_for() { awk -v p="$1" '$1==p {print $2}' "$H/fleet.conf"; }
is_tamper_block() { case "$1" in "REVIEW_BLOCKED test-tamper"*) return 0 ;; *) return 1 ;; esac; }

# rescue_post_block <record> <slug> <pr-number> <reviewed-sha> — BH-6536 shape
# D's BLOCK. The appended round (the text after the last `=== ` header, its own
# VERDICT line dropped), then `VERDICT: REQUEST_CHANGES`, `---` and the review
# lane's signed footer on the 40-hex head: the shape bin/blocked-resolver.sh's
# br_review_harness_pick + br_review_verdict read as review-changes-requested.
# Posted as a COMMENT review, else as a PR comment. rc 0 when either post
# answered 0; rc 1 when neither did (nothing is claimed then).
rescue_post_block() {
  local cand="$1" slug="$2" num="$3" sha="$4" bf rc=1
  case "$num" in ''|*[!0-9]*) return 1 ;; esac
  bf=$(mktemp "${TMPDIR:-/tmp}/rescue-review-XXXX" 2>/dev/null) || return 1
  { _nh_final "$cand/review.md" | grep -vE '^[[:space:]]*VERDICT:'
    printf '\nVERDICT: REQUEST_CHANGES\n\n---\n'
    printf '_Automated harness review (Fable) of %s. Human-step re-review by bin/review-rescue.sh; the harness fix round consumes this verdict._\n' "$sha"
  } > "$bf"
  if gh pr review "$num" -R "$slug" --comment --body-file "$bf" >>"$cand/rescue-lane.log" 2>&1; then rc=0
  elif gh pr comment "$num" -R "$slug" --body-file "$bf" >>"$cand/rescue-lane.log" 2>&1; then rc=0; fi
  rm -f "$bf"
  return "$rc"
}

# --- one candidate, start to finish -------------------------------------------
# Returns 0 always: a candidate that cannot be rescued must not stop the tick.
rescue_one() {
  local CAND="$1" SD=0
  local BN CORE PROJECT KEY REST SLUG ATT FIRST TAMPER WT MB RC V T RMODEL
  local PRNUM BRANCH PRURL RESCAN RESCAN_NOTE TITLE BODY REUSED PRE PRBF TJOB
  local SD_ACT="" SD_EV="" SD_WHO="" SD_AT="" SD_SECTION="" REV_SHA="" POSTRC=1
  [ "${2:-}" = human-step ] && SD=1
  BN=$(basename "$CAND")
  FIRST=$(head -1 "$CAND/RESULT" 2>/dev/null)
  TAMPER=0; is_tamper_block "$FIRST" && TAMPER=1

# >>> build dir project
  # The registry decides which project a build dir belongs to. Under the
  # four-name loop this replaces, a stuck review on any newer project parsed as
  # "cannot parse project/key", got marked rescued, and was dropped — a rescue
  # lane that quietly declined to rescue.
  #
  # `pool-` is the hub's copy marker on a build relayed back from a Fly pool
  # machine (pool-project-5-TK-551-202609131444). Stripped here as well as in
  # project-of.sh --prefix because the KEY is cut from the same string: with the
  # marker left on, every relayed build — which is most of the fleet's builds —
  # parsed as unparseable and was retired without ever being looked at.
  CORE="${BN#pool-}"
  PROJECT=$("${H:-/root/harness}/bin/project-of.sh" --prefix "$CORE" 2>/dev/null || echo "")
  KEY=""
  if [ -n "$PROJECT" ]; then REST="${CORE#"$PROJECT"-}"; KEY="${REST%-*}"; fi
# <<< build dir project
  [ -n "$PROJECT" ] && [ -n "$KEY" ] || { say "$BN: cannot parse project/key — marking rescued"; touch "$CAND/.review-rescued"; return 0; }
  # THE ONLY LOCK IN THIS LANE, AND IT IS DEDUPE. Same file bin/run-build.sh
  # flocks (locks/build-key-<project>-<KEY>.lock), so a rescue can never re-review
  # or re-PR a key a build is working on right now — and `-n`, so a busy key is
  # SKIPPED and re-offered next tick rather than queued behind that build. Runs in
  # this candidate's own subshell, so fd 9 is private to it.
  mkdir -p "$H/locks" 2>/dev/null
  exec 9>"$H/locks/build-key-$PROJECT-$KEY.lock"
  if ! flock -n 9; then
    say "[$PROJECT/$KEY] $BN: key is building right now (build-key lock held) — skipped this tick, nothing waits"
    return 0
  fi
  # INTERLEAVED OUTPUT HAS TO STAY READABLE. With candidates running in parallel
  # the log is no longer one rescue's story told in order, so every line this
  # candidate writes gets its key. Redefined INSIDE rescue_one on purpose: the
  # body runs in this candidate's own subshell, so the override cannot leak into a
  # sibling's, and the `say "$BN: ..."` calls below need no rewriting.
  say()   { echo "$(STAMP) [$PROJECT/$KEY] $*" >> "$LOG"; }
  alert() { HARNESS="$H" "$H/bin/alert-line.sh" "[review-rescue] [$PROJECT/$KEY] $*"; }
  # ...and the raw output of the tools this candidate drives goes to its OWN file
  # rather than into the shared log, where two reviews' stdout would interleave
  # line by line and neither would be readable.
  local CLOG="$CAND/rescue-lane.log"
  SLUG=$(slug_for "$PROJECT")
  # #469: the App token for this repo first, with the PAT probe as its fallback
  # (both inside the helper); rc 1 still means NO token can see this repo, which
  # is still the alert.
  if type gh_default_auth_for_slug >/dev/null 2>&1; then
    if ! gh_default_auth_for_slug "$SLUG"; then
      gh_repo_invisible_alert review-rescue "$SLUG" "cannot rescue $BN — no token can see the repo"
      say "$BN: no gh token can see $SLUG — left un-rescued"
      return 0
    fi
  elif type gh_repo_use_token >/dev/null 2>&1 && ! gh_repo_use_token "$SLUG"; then
    gh_repo_invisible_alert review-rescue "$SLUG" "cannot rescue $BN — no token can see the repo"
    say "$BN: no gh token can see $SLUG — left un-rescued"
    return 0
  else
    command -v gh_auth_for >/dev/null 2>&1 && gh_auth_for "$SLUG" || true
  fi
  # A closed ticket is nothing to rescue: the work landed some other way (or was
  # dropped), and a PR opened now for it would only confuse the merge lanes.
  # Costs one API read; retires the dir without spending an attempt or a review.
  # Only for projects whose tickets ARE GitHub issues (board-api-prefix "-" in
  # fleet.conf); a board project's key number is a board id, and `gh issue view`
  # on it would read some unrelated issue or PR.
  local ISSUE ST BPFX
  BPFX=$(awk -v p="$PROJECT" '$1==p {print $4}' "$H/fleet.conf" 2>/dev/null | head -1)
  ISSUE="${KEY##*-}"
  [ "$BPFX" = "-" ] || ISSUE=""
  case "$ISSUE" in ''|*[!0-9]*) ;; *)
    ST=
    command -v gh_rest_issue_state_var >/dev/null 2>&1 && { gh_rest_issue_state_var ST "$SLUG" "$ISSUE" || ST=; }
    if [ "$ST" = closed ]; then
      say "$BN: ticket #$ISSUE is closed — nothing to rescue, retiring"
      touch "$CAND/.review-rescued"; return 0
    fi ;;
  esac
  # >>> human-step evidence (BH-6536)
  # Shape D spends nothing until a person answered: the thread is read (one REST
  # read, no attempt), and only a person's HUMAN-STEP-DONE: after the RESULT
  # lets the shared path below buy a review.
  if [ "$SD" = 1 ]; then
    local SD_THREAD SD_SINCE SD_RC
    case "$ISSUE" in ''|*[!0-9]*)
      # The walk does not offer these (sd_issues_board); stamp the check
      # anyway, so a record that gets here never keeps sort key 0.
      : > "$CAND/.human-step-checked"
      say "$BN: human-step re-review needs a GitHub-issues board (board prefix '-') — not offered here"
      return 0 ;;
    esac
    : > "$CAND/.human-step-checked"
    SD_ACT=$(nh_sd_human_only "$CAND/review.md" 2>/dev/null | cut -f2-)
    SD_SINCE=$(date -u -d "@$(stat -c %Y "$CAND/RESULT" 2>/dev/null || echo 0)" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)
    SD_RC=0; SD_THREAD=$(_nh_rel_thread "$SLUG" "$ISSUE" 2>/dev/null) || SD_RC=2
    [ "$SD_RC" = 0 ] && { SD_EV=$(nh_sd_done_after "$SD_THREAD" "$SD_SINCE"); SD_RC=$?; }
    case "$SD_RC" in
      0) ;;
      1)
        nh_sd_stage_put "$PROJECT" "$ISSUE" "$KEY" human-step-waiting           "review blocked only on a human step: ${SD_ACT:-see review.md}; waits for a person's HUMAN-STEP-DONE: comment"
        if [ ! -e "$CAND/.human-step-waiting-said" ]; then
          say "$BN: review blocked only on a human step (${SD_ACT:-see review.md}); no person's HUMAN-STEP-DONE: on #$ISSUE after $SD_SINCE — waiting, no attempt spent"
          : > "$CAND/.human-step-waiting-said"
        fi
        rescue_reset; return 0 ;;
      *)
        say "$BN: human-step thread unreadable — no attempt spent"
        rescue_reset; return 0 ;;
    esac
    SD_WHO=$(sed -n 's/^author: \(@[^ ]*\) at .*/\1/p' <<<"$SD_EV" | head -1)
    SD_AT=$(sed -n 's/^author: @[^ ]* at //p' <<<"$SD_EV" | head -1)
    nh_sd_stage_put "$PROJECT" "$ISSUE" "$KEY" human-step-done "$SD_WHO posted HUMAN-STEP-DONE at $SD_AT; re-reviewing the built branch"
    say "$BN: $SD_WHO posted HUMAN-STEP-DONE at $SD_AT — re-reviewing the built branch"
    SD_SECTION=$(printf '\n\n## Human step evidence\n\nFrom %s:\n\n%s' "$(sed -n '1s/^comment: //p' <<<"$SD_EV")" \
      "$(sed '1d; s/^/> /; s/^> $/>/' <<<"$SD_EV")")
  fi
  # <<< human-step evidence
  # THE REVIEWER'S MODEL IS A ROUTE (BH-1510.1): REVIEW_MODEL in env, else this
  # project's rescue.review row. Asked BEFORE an attempt is spent: with no route
  # nothing is bought, the resolver has written the ALERTS line naming the role,
  # and the candidate is offered again next tick with its attempts intact.
  RMODEL="${REVIEW_MODEL:-}"
  if [ -z "$RMODEL" ]; then
    command -v model_for >/dev/null 2>&1 && RMODEL=$(model_for rescue.review "$PROJECT")
    if [ -z "$RMODEL" ]; then
      say "$BN: no model route for rescue.review — not rescued this tick, no attempt spent"
      return 0
    fi
  fi
  ATT=$(( $(cat "$CAND/.rescue-attempts" 2>/dev/null || echo 0) + 1 ))
  echo "$ATT" > "$CAND/.rescue-attempts"
  say "$BN: rescue attempt $ATT (project=$PROJECT key=$KEY)"

  # --- find the PR / branch ---------------------------------------------------
  read -r PRNUM BRANCH PRURL <<<"$(gh pr list -R "$SLUG" --state open --search "$KEY" --json number,headRefName,url \
    --jq 'map(select((.headRefName|ascii_downcase|contains("'"${KEY,,}"'")) or true)) | .[0] | (.number|tostring) + " " + .headRefName + " " + .url' 2>/dev/null)"
  # 2026-09-13: without credentials every ls-remote here came back empty and 23
  # rescuable project-5 builds were retired as "no open PR or branch found".
  # A local (path) origin, as in the tests, needs nothing.
  case "$(git -C "$REPOS/$PROJECT" remote get-url origin 2>/dev/null)" in
    https://*) mc_git_auth "$SLUG" >/dev/null 2>&1 || say "$BN: no git credential could read $SLUG — branch lookup may come back empty" ;;
  esac
  if [ -z "${BRANCH:-}" ]; then
    # captured first: head on a git pipe is a SIGPIPE race under pipefail (BH-1248)
    BRANCH=$(git -C "$REPOS/$PROJECT" ls-remote --heads origin "*${KEY,,}*" 2>/dev/null)
    BRANCH=${BRANCH%%$'\n'*}; BRANCH=${BRANCH##*refs/heads/}
    PRURL=""; PRNUM=""
  fi
  if [ -z "${BRANCH:-}" ]; then
    say "$BN: no open PR or branch found for $KEY — nothing to re-review here; bin/blocked-resolver.sh rebuilds the ticket fresh against current main."
    # BH-4437: a record this lane MATERIALIZED from the ledger (its box was
    # reaped) gets a terminal line and one page, never a silent retire. Record,
    # then alert, then the marker below: a crash before the marker re-enters next
    # tick, and the RESCUE_OUTCOME guard stops a second record and a second page.
    if [ -f "$CAND/.rescue-materialized" ] && ! grep -q '^RESCUE_OUTCOME:' "$CAND/RESULT" 2>/dev/null; then
      local MJOB
      MJOB=$(sed -n 's/^JOB_ID: //p' "$CAND/RESULT" 2>/dev/null | head -1)
      echo "RESCUE_OUTCOME: no-branch $(STAMP) — no open PR and no pushed branch for $KEY; handed to bin/blocked-resolver.sh" >> "$CAND/RESULT"
      alert "$BN: materialized from the ledger (box reaped) but no open PR or pushed branch exists — nothing to re-review; retired to bin/blocked-resolver.sh for a fresh rebuild (job ${MJOB:-unknown})"
    fi
    [ "$SD" = 1 ] && nh_sd_stage_put "$PROJECT" "$ISSUE" "$KEY" handed-to-resolver \
      "human step done, but no open PR or pushed branch for $KEY; bin/blocked-resolver.sh rebuilds the ticket"
    mc_git_auth_clear
    rescue_reset
    touch "$CAND/.review-rescued"; return 0
  fi

  # --- a throwaway worktree on the pushed head --------------------------------
  git -C "$REPOS/$PROJECT" fetch -q origin 2>/dev/null
  WT=$(mktemp -d /tmp/rescue-XXXX)
  rmdir "$WT"
  if ! git -C "$REPOS/$PROJECT" worktree add -q --detach "$WT" "origin/$BRANCH" 2>>"$CLOG"; then
    say "$BN: worktree add failed for origin/$BRANCH"; return 0
  fi
  # The head this rescue starts from: the main-merge push below leases on it.
  RESCUE_LEASE=$(git -C "$WT" rev-parse HEAD 2>/dev/null)

  # --- re-run the gate that blocked it ----------------------------------------
  # The scanner that wrote this terminal counted retitles as deletions. Re-run
  # it on the pushed head before spending anything else: rc 1 is a REAL deletion
  # with no justification and goes to the resolver's adjudication rung; rc 0/2 clears the block
  # and the report is pasted into the review prompt; any other rc could not
  # verify and must NOT block — the same degrade run-build.sh applies (F27).
  RESCAN_NOTE=""
  if [ "$TAMPER" -eq 1 ]; then
    MB=$(git -C "$WT" merge-base origin/main HEAD 2>/dev/null)
    if [ -z "$MB" ]; then
      say "$BN: no merge base against origin/main — test-tamper re-scan skipped, NOT blocking"
      RESCAN_NOTE=$'\n''TEST-TAMPER RE-SCAN: could not run (no merge base against origin/main) — integrity was NOT re-checked mechanically here; read the test diff yourself.'
    else
      RESCAN=$( cd "$WT" && BUILD_DIR="$CAND" "$H/bin/test-tamper-scan.sh" "$MB" . 2>&1 ); RC=$?
      printf '%s\n' "$RESCAN" > "$CAND/test-tamper-rescan.txt"
      case "$RC" in
        0|2)
          say "$BN: test-tamper re-scan rc=$RC — the block does not stand, continuing"
          RESCAN_NOTE=$'\n'"TEST-TAMPER RE-SCAN (rc=$RC): this build was blocked by an earlier version of the scanner; the re-scan below is the current one. Adjudicate it, it is not a free pass:"$'\n'"$RESCAN" ;;
        1)
          alert "$BN: still blocked after re-scan — a test was really deleted. Retired from THIS lane and handed to bin/blocked-resolver.sh, which buys one adversarial ruling on the deletion (ACCEPT writes the TEST-CHANGE justification and the build resumes, REJECT rebuilds the ticket with the tests intact). Nobody is waiting on a person; report in $CAND/test-tamper-rescan.txt"
          say "$BN: test-tamper re-scan rc=1 — real deletion, retiring to the blocked-resolver"
          touch "$CAND/.review-rescued"
          git -C "$REPOS/$PROJECT" worktree remove --force "$WT" 2>/dev/null
          mc_git_auth_clear
          rescue_reset
          return 0 ;;
        *)
          say "$BN: test-tamper re-scan did not run (rc=$RC, not blocking): $(head -1 <<<"$RESCAN")"
          RESCAN_NOTE=$'\n'"TEST-TAMPER RE-SCAN: scan_failed (rc=$RC) — integrity was NOT re-checked mechanically on this build; read the test diff yourself:"$'\n'"$RESCAN" ;;
      esac
    fi
  fi

  # --- a verdict needs somewhere to land: open the PR if only a branch exists --
  # This lane used to write `PR_CREATED ` with an EMPTY url whenever it had found
  # a branch rather than a PR — a terminal every close-out handler in the fleet
  # reads and none of them can act on. A branch with no PR gets a PR first.
  if [ -z "${PRURL:-}" ]; then
    # FRESH MAIN FIRST (2026-09-13). These branches were pushed hours or days ago
    # and nothing has moved them since. A PR opened on a stale head is reviewed
    # against a diff nobody will merge — the merge lanes then have to rebase it,
    # and the reviewed sha stops matching the head, which parks the PR. So main is
    # merged INTO the branch here, in this candidate's own worktree, and the merge
    # is pushed before the PR exists. `--no-edit` because a rescue has nothing to
    # say in a merge message.
    #
    # A CONFLICT IS NOT THIS LANE'S JOB. It opens no PR at all and leaves the
    # candidate where the resolver lane finds it — opening a conflicted PR would
    # only park it one step further downstream, with a review bought for a diff
    # that cannot land.
    # Identity is passed -c, same as lander.sh: CI runners and some boxes have
    # no user.email, and `merge --no-edit` writes a commit. Without -c the merge
    # fails "Please tell me who you are" and the next lines used to stamp
    # .conflicts-with-main for that too — every clean rescue looked conflicted
    # (Harness CI on this PR, 2026-09-13, 14 false fails).
    if ! git -C "$WT" -c user.name="$HARNESS_MERGE_GIT_NAME" -c user.email="$HARNESS_GIT_EMAIL" merge --no-edit origin/main >>"$CLOG" 2>&1; then
      CONFLICTED=$(git -C "$WT" status --porcelain 2>/dev/null | grep -cE '^(UU|AA|DD|AU|UA)')
      git -C "$WT" merge --abort 2>/dev/null
      if [ "${CONFLICTED:-0}" -gt 0 ]; then
        : > "$CAND/.conflicts-with-main"
        say "$BN: conflicts with main on $BRANCH — no PR opened, left for the resolver"
        [ "$SD" = 1 ] && nh_sd_stage_put "$PROJECT" "$ISSUE" "$KEY" handed-to-resolver \
          "human step done, but $BRANCH conflicts with main; bin/blocked-resolver.sh owns it"
      else
        say "$BN: merge origin/main failed without conflicts (see $CLOG) — left un-rescued this tick"
      fi
      git -C "$REPOS/$PROJECT" worktree remove --force "$WT" 2>/dev/null
      mc_git_auth_clear
      rescue_reset
      return 0
    fi
    rm -f "$CAND/.conflicts-with-main"
    # The ticket's hold is re-read at the push and the branch must still be at
    # the head this rescue found (BH-2504, bin/lib/hold-push.sh).
    if ! { command -v hold_push >/dev/null 2>&1 || . "$(dirname "${BASH_SOURCE[0]}")/lib/hold-push.sh" 2>/dev/null || . "$H/bin/lib/hold-push.sh" 2>/dev/null; } \
       || ! HOLD_PUSH_LOG="$CLOG" hold_push "$PROJECT" - "$WT" origin HEAD "$BRANCH" "${RESCUE_LEASE:-x}" >>"$CLOG" 2>&1; then
      # The merge is local-only, so the PR would show the stale diff. Worth
      # opening anyway — a PR that exists can be rebased by the merge lanes, a
      # branch with no PR is invisible to all of them — but it says so.
      say "$BN: could not push the main merge to $BRANCH (see $CLOG) — opening the PR on the pushed head as it stands"
    fi
    TITLE=$(git -C "$REPOS/$PROJECT" log -1 --format=%s "origin/$BRANCH" 2>/dev/null)
    TITLE=${TITLE:0:80}
    [ -n "$TITLE" ] || TITLE=$(grep -m1 '^#' "$CAND/plan.md" 2>/dev/null | sed 's/^#\{1,\}[[:space:]]*//' | head -c 80)
    [ -n "$TITLE" ] || TITLE="rescued build $BN"
    BODY=$(printf 'Rescued by `bin/review-rescue.sh` on %s: this build %s, so its branch was pushed and no pull request was ever opened.\n\nPlan: `%s`\n\n%s\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)\n' \
      "$(STAMP)" \
      "$(if [ "$SD" = 1 ]; then echo "was blocked only on a human step (${SD_ACT:-see review.md}); $SD_WHO posted HUMAN-STEP-DONE at $SD_AT"
         elif [ "$TAMPER" -eq 1 ]; then echo 'was blocked by a test-tamper false positive (retitled test cases counted as deletions)'
         else echo 'died mid-review'; fi)" \
      "$CAND/plan.md" \
      "${RESCAN_NOTE:-No test-tamper re-scan was needed for this build.}$SD_SECTION")
    # >>> pr trailers (BH-3987)
    # THE PR SAYS WHO BUILT IT: the build's own job (its pr-body.md trailer, else
    # its job.json), never this lane's exported JOB_ID. The body goes through a
    # file so the block can be applied. With no file to write, the same create
    # reads the untrailered body from stdin and one line says so.
    PRBF=$(mktemp "${TMPDIR:-/tmp}/rescue-body-XXXX" 2>/dev/null) \
      && { printf '%s\n' "$BODY" > "$PRBF"; } 2>/dev/null || { rm -f "$PRBF"; PRBF=""; }
    [ -r "${H:-}/bin/lib/pr-trailers.sh" ] && . "$H/bin/lib/pr-trailers.sh"
    if [ -n "$PRBF" ] && command -v pr_trailers_apply >/dev/null 2>&1; then
      TJOB=$(pr_trailers_read "$CAND/pr-body.md" 2>/dev/null | cut -f1)
      case "$TJOB" in ""|none) TJOB=$(JOB_ID='' pr_trailers_job_for "$CAND") ;; esac
      pr_trailers_apply "$PRBF" "$TJOB" "$KEY" || say "$BN: pr trailers: could not write $PRBF — PR opened without trailers"
    elif [ -z "$PRBF" ]; then
      say "$BN: pr trailers: no body file could be written in ${TMPDIR:-/tmp} — PR opened without trailers"
    fi
    PRURL=$(gh pr create -R "$SLUG" --head "$BRANCH" --base main --title "$KEY: $TITLE" --body-file "${PRBF:--}" <<<"$BODY" 2>>"$CLOG" | grep -oE 'https://[^[:space:]]+' | tail -1)
    [ -z "$PRBF" ] || rm -f "$PRBF"
    # <<< pr trailers
    # gh refuses when the head already has an open PR. The PR existing IS
    # success — adopt its url rather than shipping an empty one.
    [ -n "$PRURL" ] || PRURL=$(gh pr list -R "$SLUG" --head "$BRANCH" --state open --json url -q '.[0].url' 2>/dev/null)
    if [ -z "$PRURL" ]; then
      alert "$BN: could not open a PR for branch $BRANCH (attempt $ATT of 2) — left un-rescued, retried next tick; gh stderr in $CLOG."
      say "$BN: gh pr create failed for $BRANCH — leaving un-rescued"
      git -C "$REPOS/$PROJECT" worktree remove --force "$WT" 2>/dev/null
      mc_git_auth_clear
      rescue_reset
      return 0
    fi
    say "$BN: opened $PRURL for branch $BRANCH (a pushed branch with no PR)"
  fi

  # --- reuse a standing verdict, or re-run the review --------------------------
  # The one shared reader (bin/lib/verdict-parse.sh, BH-1625), kept in the
  # "VERDICT: <word>" shape the case below matches; unknown is empty.
  V=$(verdict_parse -L "$CAND/review.md" 2>/dev/null) && V="VERDICT: $V" || V=""
  T=$(grep -oE "TIER: [12]" "$CAND/review.md" 2>/dev/null | tail -1)
  REUSED=0
  if [ "$TAMPER" -eq 1 ] && [ "$V" = "VERDICT: APPROVE" ]; then
    # The review already happened and APPROVEd; the gate refused AFTER it. Buying
    # the same review a second time would cost a full Fable run to learn what is
    # already written down.
    REUSED=1
    say "$BN: reusing the standing $V ($T) from the original round — the gate blocked after the review, not before it"
  elif [ "$SD" = 1 ]; then
    # The re-review is APPENDED under its own header, so the rounds above stay
    # the record and every final-round reader (_nh_final, verdict_parse -L)
    # reads this one. The header names the head the review runs on.
    REV_SHA=$(git -C "$WT" rev-parse HEAD 2>/dev/null)
    printf '\n=== human-step re-review %s %s ===\n' "${REV_SHA:0:8}" "$(STAMP)" >> "$CAND/review.md"
    PROMPT="Adversarially review the diff of origin/main...HEAD in this repo for ticket $KEY (branch $BRANCH${PRNUM:+, PR #$PRNUM}), against the plan at $CAND/plan.md if present and the iron laws in ~/.claude/CLAUDE.md. Rules: /root/harness/prompts/build-discipline.md — cite rule ids (D1-D27) in findings. The original review BLOCKed only on this human step: ${SD_ACT:-see $CAND/review.md}. A person ran it; their evidence is below. Do not re-block on that finding. Judge the rest of the diff as a full adversarial review: correctness, edge cases, test honesty (do new tests fail if the feature breaks?), the touched-file UI iron laws, and security basics (authz on changed routes, injection, secrets). APPEND your complete review to $CAND/review.md below the line '=== human-step re-review ${REV_SHA:0:8}' (already written); do not edit the rounds above it. Second-to-last line exactly 'TIER: 1' or 'TIER: 2'. Last line exactly VERDICT: APPROVE or VERDICT: BLOCK."$'\n\n'"The person's evidence:"$'\n'"$SD_EV"
    PRE=$(cksum < "$CAND/review.md" 2>/dev/null)
    ( cd "$WT" && AGENT_CALL_ROLE=rescue.review timeout -k 60 2400 "$H/bin/agent-call.sh" review "$PROJECT" "$RMODEL" 2100 "$CAND/rescue-review-run.txt" "$PROMPT" ) >>"$CLOG" 2>&1
    [ "$PRE" != "$(cksum < "$CAND/review.md" 2>/dev/null)" ] && rm -f "$CAND/.findings-general"
    # The appended round only: a verdict above the header is the original BLOCK.
    V=$(_nh_final "$CAND/review.md" | verdict_parse -L 2>/dev/null) && V="VERDICT: $V" || V=""
    T=$(_nh_final "$CAND/review.md" | grep -oE "TIER: [12]" | tail -1)
    # A BLOCK is posted on the PR now, while this repo's token is still the
    # one in use: the resolver's review source reads it as a fix round.
    [ "$V" = "VERDICT: BLOCK" ] && { rescue_post_block "$CAND" "$SLUG" "${PRURL##*/}" "$REV_SHA"; POSTRC=$?; }
  else
    PROMPT="Adversarially review the diff of origin/main...HEAD in this repo for ticket $KEY (branch $BRANCH${PRNUM:+, PR #$PRNUM}), against the plan at $CAND/plan.md if present and the iron laws in ~/.claude/CLAUDE.md. Rules: /root/harness/prompts/build-discipline.md — cite rule ids (D1-D27) in findings. A prior review round DIED MID-RUN leaving a draft in $CAND/review.md — supersede it: REWRITE $CAND/review.md as the complete review. Judge correctness, edge cases, test honesty (do new tests fail if the feature breaks?), the touched-file UI iron laws, and security basics (authz on changed routes, injection, secrets).${RESCAN_NOTE} Second-to-last line exactly 'TIER: 1' or 'TIER: 2'. Last line exactly VERDICT: APPROVE or VERDICT: BLOCK."
    PRE=$(cksum < "$CAND/review.md" 2>/dev/null)
    ( cd "$WT" && AGENT_CALL_ROLE=rescue.review timeout -k 60 2400 "$H/bin/agent-call.sh" review "$PROJECT" "$RMODEL" 2100 "$CAND/rescue-review-run.txt" "$PROMPT" ) >>"$CLOG" 2>&1
    # BH-118: the draft this rewrites was usually harvested already, and
    # bin/findings-log.sh skips a lens whose marker exists. A changed review.md
    # is new content, so its marker goes and the next harvest reads it once. An
    # agent that wrote nothing leaves the marker, so nothing is logged twice.
    [ "$PRE" != "$(cksum < "$CAND/review.md" 2>/dev/null)" ] && rm -f "$CAND/.findings-general"
    V=$(verdict_parse -L "$CAND/review.md" 2>/dev/null) && V="VERDICT: $V" || V=""
    T=$(grep -oE "TIER: [12]" "$CAND/review.md" 2>/dev/null | tail -1)
  fi
  git -C "$REPOS/$PROJECT" worktree remove --force "$WT" 2>/dev/null
  mc_git_auth_clear
  rescue_reset

  # --- act on the verdict -----------------------------------------------------
  # ADDITIVE, NOT WHOLESALE (BH-1301). This used to be three echo lines into
  # `> "$CAND/RESULT"`, which threw away everything else the file held —
  # `TICKET_ID:`, `SOURCE:`, `JOB_ID:`, `BUILT_AS:`, `BUILD_DIR:`. The
  # candidate walk is `find $H/builds -maxdepth 2 -name RESULT`, so relayed
  # and ledger-staged dirs are candidates too, and those lines are how
  # bin/lib/rt/staging.sh tells one build of a ticket from another: a
  # marker-less dir made its dedup blind and the next result for that ticket
  # was consumed instead of staged — a close-out nothing retries.
  #
  # So: the new header, then every old line except the one it replaces
  # (line 1) and the keys it rewrites. Written to .tmp and moved into place,
  # because reading and truncating one file in a single pipeline empties it.
  rescue_result_rewrite() { # rescue_result_rewrite <RESCUED: line>
    { echo "PR_CREATED ${PRURL}"; [ -n "$T" ] && echo "$T"
      echo "$1"
      # An old TIER: line is dropped only when this rescue HAS a tier of its
      # own; with no verdict tier to write, the original's is the record. An
      # unreadable old RESULT degrades to the three-line file written above.
      if [ -n "$T" ]; then sed -e 1d -e '/^RESCUED: /d' -e '/^TIER: /d' "$CAND/RESULT" 2>/dev/null
      else                sed -e 1d -e '/^RESCUED: /d' "$CAND/RESULT" 2>/dev/null; fi
    } > "$CAND/RESULT.tmp" && mv -f "$CAND/RESULT.tmp" "$CAND/RESULT"
  }
  case "$V" in
    "VERDICT: APPROVE")
      if [ "$REUSED" -eq 1 ]; then rescue_result_rewrite "RESCUED: test-tamper block re-scanned clean $(STAMP); the original APPROVE stands and the PR was opened"
      elif [ "$SD" = 1 ]; then rescue_result_rewrite "RESCUED: human-step re-review $(STAMP) after HUMAN-STEP-DONE by $SD_WHO"
      else rescue_result_rewrite "RESCUED: review re-run $(STAMP) after died-mid-review orphan"; fi
      touch "$CAND/.review-rescued"
      [ "$SD" = 1 ] && nh_sd_stage_put "$PROJECT" "$ISSUE" "$KEY" rereview-approve "re-review APPROVE; PR ${PRURL} opened for the merge lanes"
      # A self-heal, not a page (BH-4724): info plus a self_heal ledger row, the
      # text the alert wrapper would build. No lib on this box -> the raw info line.
      local SH_MSG="[review-rescue] [$PROJECT/$KEY] $BN: rescued review = APPROVE ($T) — ${PRURL:-branch $BRANCH} now flows through the normal merge lanes."
      { command -v self_heal_note >/dev/null 2>&1 && self_heal_note review-rescue "$PROJECT/$KEY:$(basename "$CAND")" "$SH_MSG"; } \
        || HARNESS="$H" "$H/bin/alert-line.sh" --severity info "$SH_MSG"
      say "$BN: APPROVE ($T) — RESULT upgraded to PR_CREATED" ;;
    "VERDICT: BLOCK")
      touch "$CAND/.review-rescued"
      # >>> human-step block (BH-6536)
      # Posted (rc 0): the PR exists and carries a signed REQUEST_CHANGES on the
      # reviewed head, which br_from_reviews turns into a fix round, so the
      # record leaves REVIEW_BLOCKED. Not posted: nothing is claimed, the record
      # stays REVIEW_BLOCKED for the resolver, and one ALERTS line says so.
      if [ "$SD" = 1 ]; then
        if [ "$POSTRC" = 0 ]; then
          rescue_result_rewrite "RESCUED: human-step re-review $(STAMP) = BLOCK; findings posted on the PR for the fix round"
          nh_sd_stage_put "$PROJECT" "$ISSUE" "$KEY" rereview-block \
            "re-review BLOCK on ${REV_SHA:0:8}; findings posted on ${PRURL}; the resolver's fix round owns it"
          say "$BN: human-step re-review = BLOCK ($T) — findings posted on $PRURL; RESULT is PR_CREATED and bin/blocked-resolver.sh's review source runs the fix round"
        else
          alert "$BN: human-step re-review = BLOCK but the review could not be posted on $PRURL — the record stays REVIEW_BLOCKED for bin/blocked-resolver.sh"
          nh_sd_stage_put "$PROJECT" "$ISSUE" "$KEY" handed-to-resolver \
            "re-review BLOCK, but the review could not be posted on ${PRURL}; the record stays REVIEW_BLOCKED for bin/blocked-resolver.sh"
        fi
        return 0
      fi
      # <<< human-step block
      # SAY WHAT HAPPENS NEXT, NOT WHAT WE WISH HAPPENED (BH-5125). This line
      # used to promise "an agent fix round". br_from_builds offers a plain
      # REVIEW_BLOCKED record as rescue-giving-up, which br_action sends to a
      # fresh REBUILD, and only once the RESULT is 90 minutes old. An open PR's
      # own review verdict reaches the fix round on a separate source.
      # The floor is the lib's mirror of br_from_builds' `-mmin +90`; 5400 is
      # that same floor for a box that has not landed the lib yet.
      local nb=0 at="(its RESULT's age unknown)" floor=5400
      [ -n "${BHW_BUILD_FLOOR_S-}" ] && floor=$BHW_BUILD_FLOOR_S
      nb=$(stat -c %Y "$CAND/RESULT" 2>/dev/null) && nb=$(( nb + floor )) \
        && at=$(date -u -d "@$nb" +%H:%MZ 2>/dev/null) || { nb=0; at="(its RESULT's age unknown)"; }
      say "$BN: rescued review = BLOCK — the record stays REVIEW_BLOCKED; bin/blocked-resolver.sh offers it as rescue-giving-up (a fresh rebuild) from $at (its RESULT's 90-minute floor). An open PR's own review verdict reaches the resolver's fix round separately (br_from_reviews); ${PRURL:-branch $BRANCH}; findings in $CAND/review.md."
      command -v bhw_claim >/dev/null 2>&1 \
        && bhw_claim "$PROJECT" "$KEY" "${PRURL:--}" review-rescue "$nb" "rescued review = BLOCK; rescue-giving-up from $at"
      say "$BN: BLOCK — fix round needed" ;;
    *)
      say "$BN: attempt $ATT produced no VERDICT (killed at deadline or died again)"
      # The empty round stays under its header; nh_sd_human_only reads the round
      # above it, so the record is shape D again next tick (attempt 2, then the
      # walk's GIVING UP path writes rereview-gave-up).
      [ "$SD" = 1 ] && nh_sd_stage_put "$PROJECT" "$ISSUE" "$KEY" human-step-done \
        "$SD_WHO posted HUMAN-STEP-DONE at $SD_AT; re-review attempt $ATT produced no verdict; the rescue lane retries next tick (2 attempts, then bin/blocked-resolver.sh)" ;;
  esac
  return 0
}

# --- BH-858: the strandee whose verdict was never recorded ---------------------
# A record whose terminal is `PR_CREATE_FAILED` but whose review.md ends in
# `VERDICT: APPROVE` is not a build waiting for a review — a reviewer read the
# diff and answered, and the only thing that died was `gh pr create` (the App
# installation's GraphQL budget, fifteen builds fleet-wide on 2026-09-18). Until
# BH-858 the verdict row was written only after a PR existed, so those judgements
# are in no ledger at all, and this lane walked straight past them because it
# keys on REVIEW_BLOCKED.
#
# TWO LINE-1 SHAPES WEAR THE SAME FACTS. bin/pr-url-reconcile.sh relinks a
# strandee to the PR somebody opened by hand and rewrites line 1 to `PR_CREATED
# … | RECONCILED …`, keeping the create failure as `RECONCILED_FROM:`. It ticks
# three times as often as this lane, so it gets to every one of those records
# first — a backfill that only knew `PR_CREATE_FAILED` would find none of them.
#
# One bounded pass, BEFORE the candidate selection below, which it does not
# touch: neither shape a backfill walks can contain REVIEW_BLOCKED, which is what
# a rescue candidate's line 1 must say, so the two can never fight over a dir.
#
# TIER 2, ALWAYS. The build never finished its pipeline — QA, E2E, scope, kind
# and the head-bound gate never ran on it, and tier 1 means auto-merge. Tier 2
# sends it through the hub's reviewed tier-2 sweep instead.
# shellcheck source=bin/jobs-client.sh
[ -r "$H/bin/jobs-client.sh" ] && . "$H/bin/jobs-client.sh"
# shellcheck source=bin/lib/model-route.sh
[ -r "$H/bin/lib/model-route.sh" ] && . "$H/bin/lib/model-route.sh"
# The knob. env/global.env is loaded at the TOP of this file (see the note
# there), so VERDICT_BACKFILL_MAX is already exported when it is set; the file
# read below is the fallback for a tree where it is not.
VB_MAX="${VERDICT_BACKFILL_MAX:-}"
[ -n "$VB_MAX" ] || VB_MAX=$(sed -n 's/^[[:space:]]*VERDICT_BACKFILL_MAX=//p' "$HENV/global.env" 2>/dev/null | head -1 | tr -d "\"' ")
case "$VB_MAX" in ''|*[!0-9]*) VB_MAX=25 ;; esac

verdict_backfill() {
  local n=0 D BN FIRST V PROJECT CORE REST KEY JOB RC STATE RSHA PROV WHY DIRS
  command -v job_for_record >/dev/null 2>&1 || return 0
  # One project's run walks that project's record dirs only. A glob that
  # matches nothing stays literal and has no RESULT, so it is skipped below.
  if [ -n "$RESCUE_ONLY" ]; then
    DIRS=("$H"/builds/"$RESCUE_ONLY"-*/ "$H"/builds/pool-"$RESCUE_ONLY"-*/ "$H"/builds/fly-"$RESCUE_ONLY"-*/)
  else
    DIRS=("$H"/builds/*/)
  fi
  for D in "${DIRS[@]}"; do
    [ "$n" -lt "$VB_MAX" ] || break
    D="${D%/}"
    [ -f "$D/RESULT" ] || continue
    # Write-then-mark, and the marker is the whole idempotency story: it is only
    # reached after a row landed, or after an alert was written.
    [ -f "$D/.verdict-backfilled" ] && continue
    # bin/blocked-resolver.sh ran its ladder and closed this one out.
    [ -f "$D/.blocked-resolver-abandoned" ] && continue
    FIRST=$(head -1 "$D/RESULT" 2>/dev/null)
    # BOTH SHAPES A STRANDEE WEARS. bin/pr-url-reconcile.sh rewrites line 1 to
    # `PR_CREATED <url> | RECONCILED …` as soon as it finds the PR somebody
    # opened by hand, and keeps the create failure one line down as
    # `RECONCILED_FROM:`. That lane ticks every 10 minutes and this one every
    # 30, so for the population this ticket was filed about — builds whose PR
    # already exists on the branch — the reconciler always wins the race, and
    # RECONCILED is the only shape the backfill ever meets. Keying on
    # PR_CREATE_FAILED alone walks past every one of them.
    case "$FIRST" in
      PR_CREATE_FAILED*) ;;
      "PR_CREATED "*" | RECONCILED "*)
        # The rewritten line 1 says nothing about how the build ENDED; only the
        # preserved original does. A record the builder linked itself carries no
        # RECONCILED_FROM line at all and is not a strandee.
        grep -q '^RECONCILED_FROM: PR_CREATE_FAILED' "$D/RESULT" || continue ;;
      *) continue ;;
    esac
    BN=$(basename "$D")
    CORE="${BN#pool-}"; CORE="${CORE#fly-}"
    PROJECT=$("$H/bin/project-of.sh" --prefix "$CORE" 2>/dev/null || echo "")
    # `pa-*` also matches `pa-x-…`: a record of another project is not this run's.
    [ -z "$RESCUE_ONLY" ] || [ "$PROJECT" = "$RESCUE_ONLY" ] || continue
    KEY=""
    if [ -n "$PROJECT" ]; then REST="${CORE#"$PROJECT"-}"; KEY="${REST%-*}"; fi
    [ -n "$PROJECT" ] && [ -n "$KEY" ] || { say "$BN: cannot parse project/key — no verdict backfilled, and nothing marked"; continue; }
    n=$((n+1))
    # THE VERDICT LINE IN THE FINAL BLOCK, and only a line that starts with it
    # (bin/lib/verdict-parse.sh, BH-1625): a review that quotes
    # `VERDICT: APPROVE` in its findings and ends in BLOCK is a BLOCK, and a
    # review whose own last line was lost in relay must not have a quotation
    # promoted into a judgement.
    V=$(verdict_parse -L "$D/review.md" 2>/dev/null) || V=""
    if [ "$V" = BLOCK ]; then
      say "[$PROJECT/$KEY] $BN: the create failed on a BLOCKed build — no verdict is owed"
      touch "$D/.verdict-backfilled"; continue
    fi
    JOB=$(job_for_record "$PROJECT" "$BN"); RC=$?
    if [ "$RC" = 1 ]; then
      say "[$PROJECT/$KEY] $BN: the ledger did not answer which job wrote this record — nothing written, nothing marked, the next tick retries"
      continue
    fi
    if [ "$V" != APPROVE ] || [ -z "$JOB" ]; then
      WHY="no VERDICT line in review.md"
      [ "$V" = APPROVE ] && WHY="no job row names this build dir"
      alert "[$PROJECT/$KEY] $BN died at PR create and owes a verdict this lane cannot backfill ($WHY); the merge conductor's head-bound re-review is the only path left — if it is not armed, review the PR by hand"
      touch "$D/.verdict-backfilled"; continue
    fi
    STATE=$(job_verdict_state "$JOB"); RC=$?
    if [ "$RC" = 1 ]; then
      say "[$PROJECT/$KEY] $BN: the ledger would not say whether job $JOB owns a verdict — nothing written, nothing marked, the next tick retries"
      continue
    fi
    if [ "${STATE%%	*}" = settled ]; then
      say "[$PROJECT/$KEY] $BN: job $JOB already carries a settled verdict — nothing owed"
      touch "$D/.verdict-backfilled"; continue
    fi
    # The sha the review ran on, in order of how close it is to the review:
    # `reviewed-sha` is what bin/fly-results-ingest.sh relays with the record,
    # `review-head` is the builder's own copy, and the provisional row's own
    # reviewed_sha is what the build recorded before it died. Empty is OMITTED —
    # a blank sha reads as a claim about the head.
    RSHA=$(head -1 "$D/reviewed-sha" 2>/dev/null || true)
    [ -n "$RSHA" ] || RSHA=$(head -1 "$D/review-head" 2>/dev/null || true)
    if [ -z "$RSHA" ] && [ "$RC" = 0 ]; then
      RSHA="${STATE#*	}"; [ "$RSHA" = "-" ] && RSHA=""
    fi
    [ -n "$RSHA" ] || say "[$PROJECT/$KEY] $BN: no record of the sha this review ran on — the row is written without one rather than claiming a head"
    # Provenance from pipeline.log, the same read bin/merge-sweep.sh and
    # mc_verdict make on a record: the `.runner` sidecars are not relayed to the
    # hub, so a demoted review announces itself here or nowhere.
    PROV=claude
    grep -q 'judge provenance' "$D/pipeline.log" 2>/dev/null && PROV=fallback
    if job_artifact_put verdict APPROVE \
        "$(jq -nc --arg p "$PROV" --arg r "$BN" --arg s "$RSHA" \
            '{tier:"2",provenance:$p,record:$r,settled:true,source:"review-rescue-backfill"}
             + (if $s == "" then {} else {reviewed_sha:$s} end)' 2>/dev/null)" "$JOB" >/dev/null 2>&1; then
      say "[$PROJECT/$KEY] $BN: backfilled the ledger verdict APPROVE (tier 2, job $JOB, provenance $PROV, reviewed sha ${RSHA:-none}) from the review this build did buy"
      touch "$D/.verdict-backfilled"
    else
      say "[$PROJECT/$KEY] $BN: the verdict row would not write (job $JOB) — nothing marked, the next tick retries"
    fi
  done
}
verdict_backfill

# --- BH-4437: the REVIEW_BLOCKED build whose pool box was reaped ---------------
# The candidate walk below reads only the hub's builds/. A pool build whose
# review died, on a machine reaped before its result was relayed, never gets a
# dir there — but the ledger still holds its `result` row (build_dir, key, box,
# job) and its branch is still on origin. This pass rebuilds the hub-side record
# as builds/pool-<build_dir>/, the name a relayed copy of that build would have
# had, so bor_local_dir, bin/blocked-resolver.sh and bin/stale-owed-tickets.sh
# all map the ledger row to it with no change of their own. The walk then finds
# it the same tick (its RESULT carries the ledger's age) and rescue_one re-runs
# the review on the pushed head, exactly as for a relayed dir.
#
# A row qualifies only when ALL hold — the same orphan test stale-owed pages on:
# line 1 REVIEW_BLOCKED; a plain build_dir and a job id; no dir for it on the
# hub (exact, pool-, fly-); its job not already staged (no RESULT names its
# JOB_ID); 90 min <= age <= RESCUE_LEDGER_LOOKBACK_H; and the job has NO verdict
# artifact (rc 2). An outage on either read writes nothing and the next tick
# retries. At most RESCUE_PER_TICK per tick, oldest first; the rest come back.
#
# AND the build was not already dealt with. bin/blocked-resolver.sh acts on
# exactly these ledger-only rows from hour 6, and with no dir to mark it records
# that only in the ticket's state file; once this pass makes a dir, the resolver
# reads the dir, not that file. So a row is skipped when (a) the ticket's
# resolver state has the build in rebuild_seen (plain, pool-, fly-) or a non-hold
# ladder attempt at or after the row — the resolver's own NOT RE-OFFERED test,
# and an unreadable file fails closed — or (b) the ledger holds a NEWER result
# row for the same ticket under another build_dir: the ticket was built again,
# and the KEY search in rescue_one would find THAT build's PR and review it twice.
# shellcheck source=bin/lib/builds-of-record.sh
[ -r "$H/bin/lib/builds-of-record.sh" ] && . "$H/bin/lib/builds-of-record.sh"
NOW=$(date -u +%s)
# ledger_tkey <project> <build_dir> <ledger key> — the ticket a ledger row is
# for, derived from build_dir exactly as bin/blocked-resolver.sh derives it (so
# the state file named below is the one the resolver wrote), the ledger's key
# only when build_dir does not carry the project prefix.
ledger_tkey() {
  local rest
  case "$2" in "$1"-*) rest="${2#"$1"-}"; printf '%s' "${rest%-*}" ;; *) printf '%s' "$3" ;; esac
}
# resolver_acted <project> <ticket key> <build_dir> <row epoch> — rc 0 when the
# resolver's state for the ticket says it already acted on this build, or the
# state cannot be read (fail closed); rc 1 when it has not.
resolver_acted() {
  local rk st sx at ate
  rk="$1-$2"; st="$H/state/blocked-resolver/$1/${rk//[^A-Za-z0-9._-]/-}.json"
  [ -f "$st" ] || return 1
  sx=$(jq -r --arg b "$3" '[
      ((.rebuild_seen // []) | any(. == $b or . == ("pool-" + $b) or . == ("fly-" + $b))),
      ([.attempts[]? | select((.action // "") | . != "held" and . != "stalled" and . != "stall-cleared" and (startswith("hold-") | not))] | last | (.at // ""))
    ] | @tsv' "$st" 2>/dev/null) || return 0
  [ "${sx%%$'\t'*}" = false ] || return 0
  at="${sx#*$'\t'}"
  [ -n "$at" ] || return 1
  ate=$(date -u -d "$at" +%s 2>/dev/null) || return 0
  [ "$ate" -ge "$4" ]
}
ledger_materialize() {
  local n=0 P ROWS RC STAGED KEY BDIR BOX UPD RLINE _PR JOB TS AGE TMP DEST TK
  local -A NEWEST=()
  command -v bor_list >/dev/null 2>&1 && command -v bor_local_dir >/dev/null 2>&1 \
    && command -v job_verdict_state >/dev/null 2>&1 || return 0
  # A tmp record left by a run that died between mkdir and mv: the walk skips
  # it, and this sweeps it once it is plainly not a live run's (an hour old).
  find "$H/builds" -mindepth 1 -maxdepth 1 -type d -name '.pool-*.tmp.*' -mmin +60 \
    -exec rm -rf {} + 2>/dev/null
  STAGED=$'\n'"$(sed -n 's/^JOB_ID: //p' "$H"/builds/*/RESULT 2>/dev/null)"$'\n'
  for P in $PROJECTS; do
    [ -z "$RESCUE_ONLY" ] || [ "$P" = "$RESCUE_ONLY" ] || continue
    ROWS=$(bor_list "$P" 2>/dev/null); RC=$?
    if [ "$RC" = 1 ]; then say "$P: ledger read failed — no record materialized this tick"; continue; fi
    [ "$RC" = 0 ] || continue
    # The newest result row per ticket, whatever its line 1 (updated_at is ISO,
    # so it orders as text). An older row of a ticket built since is superseded.
    NEWEST=()
    while IFS=$'\t' read -r KEY BDIR BOX UPD RLINE _PR JOB; do
      [ -n "$BDIR" ] && [ -n "$UPD" ] && [ "$UPD" != - ] || continue
      TK=$(ledger_tkey "$P" "$BDIR" "$KEY"); [ -n "$TK" ] && [ "$TK" != - ] || continue
      [[ "$UPD" > "${NEWEST[$TK]:-}" ]] && NEWEST[$TK]="$UPD"
    done <<<"$ROWS"
    # Oldest first, the same order the candidate walk takes (updated_at is ISO).
    while IFS=$'\t' read -r KEY BDIR BOX UPD RLINE _PR JOB; do
      case "$RLINE" in REVIEW_BLOCKED*) ;; *) continue ;; esac
      [ -n "$JOB" ] && [ "$JOB" != - ] || continue
      # Ledger text that becomes a path: a plain name, or nothing.
      if ! [[ "$BDIR" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
        say "$P: refused ledger build_dir '$BDIR' (job $JOB) — not a plain name, never used as a path"
        continue
      fi
      bor_local_dir "$BDIR" >/dev/null && continue
      case "$STAGED" in *$'\n'"$JOB"$'\n'*) continue ;; esac
      [ -n "$UPD" ] && [ "$UPD" != - ] || continue
      TS=$(date -u -d "$UPD" +%s 2>/dev/null) || continue
      AGE=$(( NOW - TS ))
      [ "$AGE" -ge 5400 ] && [ "$AGE" -le $(( RESCUE_LEDGER_LOOKBACK_H * 3600 )) ] || continue
      TK=$(ledger_tkey "$P" "$BDIR" "$KEY")
      if [ -z "$TK" ] || [ "$TK" = - ]; then
        say "[$P] $BDIR: no ticket key on the ledger row (job $JOB) — not materialized"
        continue
      fi
      if [[ "${NEWEST[$TK]:-}" > "$UPD" ]]; then
        say "[$P/$TK] $BDIR: superseded — the ledger holds a newer build of $TK; not materialized"
        continue
      fi
      if resolver_acted "$P" "$TK" "$BDIR" "$TS"; then
        say "[$P/$TK] $BDIR: bin/blocked-resolver.sh already acted on this build (or its state is unreadable) — not materialized"
        continue
      fi
      job_verdict_state "$JOB" >/dev/null 2>&1; RC=$?
      if [ "$RC" = 1 ]; then
        say "[$P/$KEY] $BDIR: the ledger would not say whether job $JOB has a verdict — not materialized, the next tick retries"
        continue
      fi
      [ "$RC" = 2 ] || continue
      if [ "$n" -ge "$RESCUE_PER_TICK" ]; then
        say "ledger pass capped at RESCUE_PER_TICK=$RESCUE_PER_TICK materializations — the rest come back next tick"
        return 0
      fi
      # Built aside and moved into place whole: no half record is ever visible.
      TMP="$H/builds/.pool-$BDIR.tmp.$$"; DEST="$H/builds/pool-$BDIR"
      if mkdir "$TMP" 2>/dev/null \
         && printf '%s\nSOURCE: remote (ledger, built on %s; materialized by review-rescue — no build dir on the hub)\nJOB_ID: %s\nBUILT_AS: %s\nMATERIALIZED: %s\n' \
              "$RLINE" "$BOX" "$JOB" "$BDIR" "$(STAMP)" > "$TMP/RESULT" \
         && : > "$TMP/.rescue-materialized" && : > "$TMP/.stale-flagged"; then
        if job_transcript_get_source "$JOB" plan_md > "$TMP/plan.md" 2>/dev/null && [ -s "$TMP/plan.md" ]; then :
        else rm -f "$TMP/plan.md"; say "[$P/$KEY] $BDIR: no plan_md in the ledger for job $JOB — the review runs without a plan"; fi
        # The record keeps the ledger's age, so the walk's -mmin +90 and its
        # oldest-first order treat it as the build it is.
        touch -d "$UPD" "$TMP/RESULT" 2>/dev/null
        if mv -T "$TMP" "$DEST" 2>/dev/null; then
          n=$((n+1)); STAGED="$STAGED$JOB"$'\n'
          say "[$P/$KEY] materialized pool-$BDIR from the ledger (job $JOB, box $BOX)"
          continue
        fi
      fi
      case "$TMP" in "$H"/builds/.pool-*) rm -rf "$TMP" ;; esac
      say "[$P/$KEY] $BDIR: could not write the hub record for job $JOB — nothing materialized, the next tick retries"
    done < <(printf '%s\n' "$ROWS" | sort -t$'\t' -k4,4)
  done
}
ledger_materialize

# --- pick the oldest candidates -----------------------------------------------
# sd_rec_ids <record> — "<project> <key> <issue>" for a record, the parse
# rescue_one makes; nothing when the registry does not know the project.
sd_rec_ids() {
  local core p rest k
  core=$(basename "$1"); core="${core#pool-}"
  p=$("$H/bin/project-of.sh" --prefix "$core" 2>/dev/null) || return 1
  [ -n "$p" ] || return 1
  rest="${core#"$p"-}"; k="${rest%-*}"
  printf '%s %s %s\n' "$p" "$k" "${k##*-}"
}
# sd_human_block <record> — rc 0 when review.md is a BLOCK whose findings are
# human steps only. A no is remembered in .human-step-none and reused while it
# is newer than review.md, so an old code-BLOCK record costs one stat per tick,
# not a verdict_parse and an nh_sd_human_only fork per review line (lead review
# lr-6621-e59f79a9aa94). An appended review round makes review.md newer, and
# the record is parsed again.
sd_human_block() {
  local d="$1"
  [ -f "$d/review.md" ] || return 1
  [ -f "$d/.human-step-none" ] && [ "$d/.human-step-none" -nt "$d/review.md" ] && return 1
  if [ "$(verdict_parse -L "$d/review.md" 2>/dev/null)" = BLOCK ] \
     && nh_sd_human_only "$d/review.md" >/dev/null 2>&1; then
    return 0
  fi
  : > "$d/.human-step-none"
  return 1
}
# sd_issues_board <project> — rc 0 when the project's tickets are GitHub issues
# (board prefix "-" in fleet.conf). Shape D reads a GitHub thread; an in-app
# board record is never offered, so it never takes a per-tick slot.
sd_issues_board() {
  [ "$(awk -v p="$1" '$1==p {print $4}' "$H/fleet.conf" 2>/dev/null | head -1)" = "-" ]
}
CANDS=(); SD_ALL=()
while read -r R; do
  # Shape D has its own list; with it off, the walk stops where it always did.
  [ "${#CANDS[@]}" -lt "$RESCUE_PER_TICK" ] || [ "$RESCUE_HUMAN_STEP" = 1 ] || break
  D=$(dirname "$R")
  # BH-4437: a ledger pass's half-built tmp record is never a candidate.
  case "$D" in */.pool-*.tmp.*) continue ;; esac
  if [ -n "$RESCUE_ONLY" ]; then
    case "$(basename "$D")" in "$RESCUE_ONLY"-*|pool-"$RESCUE_ONLY"-*) ;; *) continue ;; esac
  fi
  FIRST=$(head -1 "$R" 2>/dev/null)
  grep -q "REVIEW_BLOCKED" <<<"$FIRST" || continue
  # The basename test above lets `pa-x-…` into a `pa` run: the registry decides.
  if [ -n "$RESCUE_ONLY" ]; then
    read -r RRP _ <<<"$(sd_rec_ids "$D")"
    [ "${RRP:-}" = "$RESCUE_ONLY" ] || continue
  fi
  # >>> shape D candidates (BH-6536)
  # A verdict-bearing BLOCK whose final round is a human step only. It is
  # collected whole here and rotated below, so a record that waits on a person
  # for days never holds a slot another one needs. The marker stats come first:
  # most old records carry one, and every path below skips those two anyway.
  [ -f "$D/.review-rescued" ] && continue
  [ -f "$D/.blocked-resolver-superseded" ] && continue
  if [ "$RESCUE_HUMAN_STEP" = 1 ] && [ ! -f "$D/.blocked-resolver-abandoned" ] \
     && ! is_tamper_block "$FIRST" \
     && sd_human_block "$D"; then
    # A newer build of the same ticket is the one a done comment answers.
    read -r SDP SDK SDN <<<"$(sd_rec_ids "$D")"
    # An in-app board has no GitHub thread to read: not offered (the record
    # is verdict-bearing, so the A/B/C path below skips it as before).
    [ -n "${SDP:-}" ] && ! sd_issues_board "$SDP" && continue
    if [ -n "${SDK:-}" ]; then
      SDNEW=""
      for O in "$H"/builds/"$SDP-$SDK"-*/RESULT "$H"/builds/pool-"$SDP-$SDK"-*/RESULT; do
        [ -f "$O" ] && [ "$O" != "$R" ] && [ "$O" -nt "$R" ] && { SDNEW="$O"; break; }
      done
      [ -z "$SDNEW" ] || continue
    fi
    A=$(cat "$D/.rescue-attempts" 2>/dev/null || echo 0)
    if [ "$A" -ge 2 ]; then
      HARNESS="$H" "$H/bin/alert-line.sh" "[review-rescue] GIVING UP on $(basename "$D") after 2 failed rescue attempts — retired from this lane and handed to bin/blocked-resolver.sh, which rebuilds the ticket fresh against current main (3 tries, then one ABANDONED outcome record). Nobody is waiting on a person."
      [ -n "${SDK:-}" ] && nh_sd_stage_put "$SDP" "$SDN" "$SDK" rereview-gave-up \
        "re-review produced no verdict twice; bin/blocked-resolver.sh rebuilds after its floor"
      touch "$D/.review-rescued"; continue
    fi
    SD_ALL+=("$D"); continue
  fi
  # <<< shape D candidates
  [ "${#CANDS[@]}" -lt "$RESCUE_PER_TICK" ] || continue
  # A verdict normally means this build was already judged and there is nothing
  # to re-enter. Shape D above takes the human-step-only BLOCK (BH-6536); the
  # other exception is a test-tamper block: the gate runs BEFORE
  # the review on a fresh build and AFTER it on a resumed one, so four of the
  # 2026-09-13 strandees held `VERDICT: APPROVE` and a REVIEW_BLOCKED terminal at
  # the same time. Skipping them is what left them waiting for a PR forever.
  # "Has a verdict" is the shared reader's answer (BH-1625, #1639 review), -L as
  # for every appended build artifact, so this skip agrees with
  # bin/stale-owed-tickets.sh about which REVIEW_BLOCKED builds are orphaned.
  if ! is_tamper_block "$FIRST" && verdict_parse -L "$D/review.md" >/dev/null 2>&1; then continue; fi
  [ -f "$D/.review-rescued" ] && continue
  # bin/blocked-resolver.sh stamps this when it has ruled on the record and
  # enqueued a fresh build. Since BH-1047 its fast path adjudicates a
  # contract-first tamper block from minute 90, the same floor this lane uses,
  # so both crons can hold the same record on the same minute. Rescuing one the
  # resolver has already superseded opens a second PR on the branch it just
  # closed and buys a second review for one ticket — the record is its owner's.
  [ -f "$D/.blocked-resolver-superseded" ] && continue
  A=$(cat "$D/.rescue-attempts" 2>/dev/null || echo 0)
  if [ "$A" -ge 2 ]; then
    HARNESS="$H" "$H/bin/alert-line.sh" "[review-rescue] GIVING UP on $(basename "$D") after 2 failed rescue attempts — retired from this lane and handed to bin/blocked-resolver.sh, which rebuilds the ticket fresh against current main (3 tries, then one ABANDONED outcome record). Nobody is waiting on a person."
    touch "$D/.review-rescued"; continue
  fi
  CANDS+=("$D")
done < <(if [ -n "$RESCUE_ONLY" ]; then
           find "$H"/builds/"$RESCUE_ONLY"-*/ "$H"/builds/pool-"$RESCUE_ONLY"-*/ -maxdepth 1 -name RESULT -mmin +90 2>/dev/null
         else
           find "$H/builds" -maxdepth 2 -name RESULT -mmin +90 2>/dev/null
         fi | xargs -r ls -tr 2>/dev/null)
# Shape D rotates: the record checked longest ago (.human-step-checked, touched
# on every thread read) goes first, oldest RESULT first among the unchecked.
SD_CANDS=()
if [ "${#SD_ALL[@]}" -gt 0 ]; then
  while IFS=$'\t' read -r _ C; do SD_CANDS+=("$C"); done < <(
    for C in "${SD_ALL[@]}"; do printf '%s\t%s\n' "$(stat -c %Y "$C/.human-step-checked" 2>/dev/null || echo 0)" "$C"; done \
      | sort -s -t$'\t' -k1,1n | head -n "$RESCUE_HUMAN_STEP_PER_TICK")
fi
[ "${#CANDS[@]}" -gt 0 ] || [ "${#SD_CANDS[@]}" -gt 0 ] || exit 0

# Oldest first, RESCUE_PER_TICK of them, all IN PARALLEL. One per tick was the
# original bound on cost; with 39 stranded builds on one day that is a fortnight
# of ticks, so the bound is a knob (env) rather than a constant — and since
# 2026-09-13 the candidates no longer take turns either. Each runs in its own
# subshell (its own worktree, its own fds, its own per-key flock), at most
# RESCUE_PARALLEL at a time, and the tick waits for all of them before it exits so
# cron never overlaps a rescue with its own successor.
case "$RESCUE_PARALLEL" in ''|*[!0-9]*) RESCUE_PARALLEL=0 ;; esac   # 0 = no cap: every candidate starts now
RUNNING=0
for C in "${CANDS[@]}" "${SD_CANDS[@]/#/human-step:}"; do
  case "$C" in
    human-step:*) ( rescue_one "${C#human-step:}" human-step ) & ;;
    *) ( rescue_one "$C" ) & ;;
  esac
  RUNNING=$((RUNNING+1))
  # `wait -n` returns on the FIRST child to finish, which is what keeps the cap a
  # cap without making the slowest candidate the pace-setter for the rest.
  if [ "$RESCUE_PARALLEL" -gt 0 ] && [ "$RUNNING" -ge "$RESCUE_PARALLEL" ]; then
    wait -n 2>/dev/null || wait
    RUNNING=$((RUNNING-1))
  fi
done
wait
command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset
exit 0
