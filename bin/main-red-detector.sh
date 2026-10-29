#!/bin/bash
# bin/main-red-detector.sh [--explain] [--flagged-only] [owner/repo ...] — is MAIN itself red?
#
# THE SILENCE THIS KILLS (2026-09-15). worker/jobs/test/cost-anchored.test.js
# windowed off the wall clock against fixtures pinned to 2026-09-14. At ~14:00Z
# it went red on MAIN, every open PR (#355-#359) inherited the red, four
# "Harness CI failure" alerts fired at the PR authors — and not one line
# anywhere said "main itself is red". Four lanes each debugged their own
# innocent diff. The lint for the cause is bin/test-determinism-lint.sh; this is
# the detector for the symptom, and it exists because a red shared by every PR
# is a REPO-level fact that no PR-level alert can express.
#
# Deterministic, no model, one gh read per repo (plus one jobs read the tick a
# repo turns red, to name the failing job, and one re-read of the runs page to
# confirm that red first — BH-1927 below). For each harness repo: the latest
# runs on main, grouped by workflow, REQUIRED workflows only (e2e / nightly /
# smoke / publish names or paths are skipped — a nightly prod suite red on main
# is bin/pipeline-health.sh's perma-red check, not a merge freeze). A workflow
# whose newest MAIN_RED_STREAK (2) concluded runs are both red makes the repo
# red. cancelled / skipped / neutral / in-progress runs are not evidence and
# neither break a streak nor make one.
#
# AND A STREAK BEING RE-TESTED IS NOT RAISED ON (BH-1281). While NO flag is on
# disk, a streak whose workflow has a newer run on main that has not concluded
# (queued / in_progress / waiting / pending / requested) is HELD, not raised:
# that is the tip arm's in-flight suppression, applied to the streak arm. It
# matters because bin/batch-resolve.sh lifts the flag the moment a fix-main-red
# PR merges green (BH-1269) while the fix's own run on main is still in flight
# — and re-raising on the same two completed reds would both page again and
# give the flag a new mtime, which is the lower bound that lift uses for "has a
# fix merged since the freeze went up". A flag ALREADY on disk is judged exactly
# as before: the hold is on RAISING, never on the still-red republish, the
# new-sha notice or the green clear.
#
# SECOND ARM, THE TIP (BH-629.4). The streak above is applied to a stream whose
# only producer is a push to main, and here a push to main is a merge — so the
# second red run it waits for can only arrive from the very merge the red is
# meant to prevent. On 2026-09-17 that was 7.5 hours of "main green" while
# every open PR inherited the red. So when the streak arm finds nothing, ONE red
# completed run of a required workflow makes the repo red if it sits on main's
# TIP (its sha is the newest sha in the page) and has stood there at least
# MAIN_RED_TIP_MIN_AGE_MIN minutes with no newer run of its own workflow — a
# newer in-progress or cancelled run means a re-run is in flight, and the wait
# is what keeps a flake from freezing the fleet. The streak's flake tolerance is
# untouched; this is an additional arm, never a lower threshold, and the flag
# says which one fired (reason=tip / reason=streak).
#
# THIRD ARM, THE BURST BACK-WALK (BH-1451). Both arms above need evidence that a
# MERGE BURST removes from the page. On 2026-09-22 main went red at 12:28Z and
# the hub merged five more PRs onto it while this detector logged, every tick
# for 15+ minutes, "no completed run of a REQUIRED workflow on main — nothing
# decided": main was advancing every minute or two, so every run in the page was
# still in_progress, the streak arm had no second red and the tip arm's red was
# never on the tip. So when both arms above find nothing and the head still has
# required runs IN FLIGHT, walk BACK: the newest COMPLETED required run within
# MAIN_RED_BURST_DEPTH (5) distinct main shas of the head decides, and a red
# there freezes merges even though a newer head exists. The flag carries the sha
# it JUDGED (sha=), the head it is behind (head=) and how far (depth=), and the
# log says which sha decided. There is NO green side to this arm: a green that
# predates two pushes is no claim about the head, so it clears nothing.
# The wait the tip arm makes (MAIN_RED_TIP_MIN_AGE_MIN) is deliberately absent
# here — in a burst the alternative to freezing is merging onto a proven red —
# but the two guards that stand in for it are not: a run whose created_at does
# not parse decides nothing, and "in flight" means a required run on a STRICTLY
# NEWER sha, so a re-run in flight on the SAME sha still holds the arm.
#
# If the FIRST page holds no completed required run at all (the 2026-09-22
# shape), the page is re-read ONCE at MAIN_RED_BURST_PER_PAGE (100) before the
# arms are applied — one extra read per repo, only on a tick that would
# otherwise decide nothing, and never on a page with nothing pending.
#
# AND A PAGE THAT GOES BACKWARDS IS NOT EVIDENCE (BH-1927). GitHub's runs list
# sometimes answers with a STALE page: on 2026-09-24 the hub read
# total_count=4355 with week-old runs, then 7094 on the very next call. The
# stale page carried two red monitor.yml pushes, so the streak arm froze every
# merge lane and paged --critical, and the next fresh page cleared it a minute
# later — an hour of flapping on project-5. So each repo's newest total_count
# and newest run created_at this detector has ACCEPTED live in one `ledgers`
# row (kind=main_red_runs, key=<owner>/<repo>, never a file), and a page whose
# newest run is older than that decides NOTHING: no raise, no clear, no new-sha
# rewrite (decision=none reason=stale-page). A page whose newest run is the
# same or NEWER is fresh even at a lower count — GitHub's retention deleting
# old runs lowers it too — and resets the row to its own count; the count alone
# decides only for a page that carries no run to compare. And before a NEW flag goes up the page
# that decided is read once more and the arms run again on it: the raise
# stands only if the re-read picks the same arm, workflow and sha
# (decision=none reason=unconfirmed otherwise). That second read is what
# guards a raise when the ledger cannot be reached. --explain reads the row
# and never writes it.
#
# ONE PASS, FLAGGED REPOS FIRST (BH-6352). On 2026-10-13 a pass judged the 13
# repos in fleet.conf order, ended after repo 6, and never reached
# example-org/project-6 (the last row): its freeze stayed up 39 minutes on a green
# main, and the log said nothing. A scheduled pass (no repo arguments) now
# judges every repo with a flags/main-red-* file first, in fleet.conf order,
# then the rest; an explicit repo list keeps its order. Each pass logs a
# `pass start:` and a `pass end:` line (repos decided, seconds, exit code,
# signal, last repo). A freeze the pass leaves undecided gets one
# `<slug|flag>: decision=none reason=<why>` line: the verdict's own reason
# (stale-page, no-runs, ...), not-reached (the pass ended first),
# not-in-repo-list (no repo in the pass maps to the flag) or lock-held
# (another pass held the lock). A SIGKILL cannot be trapped and leaves no
# line; the next pass judges the flagged repo first. --explain logs none of it.
#
# FLAGGED-ONLY RE-CHECK (BH-6502). The scheduled pass runs inside the merge
# conductor's full tick, and that tick runs once an hour (BH-5521). On
# 2026-10-13 a project-6 freeze stayed up for most of an hour on a green main,
# twice. bin/main-red-recheck.sh (a */5 hub lane) runs `--flagged-only`: the
# repo list is resolved as above, then cut to the slugs whose freeze flag is
# up, in list order, and judged by the same loop. A repo with no flag is not
# read. No flag in the list = exit 0 with no line. The pass logs
# `pass start: recheck, <n> flagged repo(s): <slugs>` and, before its
# `pass end:` line, `recheck: <n> flagged repo(s), <r> Actions read(s)`
# (every GitHub Actions GET this pass made). It names no stray flag: the
# hourly pass does that.
#
#   red, and no flag yet  -> write flags/main-red-<owner>-<repo> (sha, workflow,
#                            since, run url, reason) + ONE --critical alert naming
#                            the failing JOB, not just the workflow
#   red, flag already there -> SAME sha: one log line, NO second alert.
#                            NEW sha: the flag's sha/workflow/job/run are
#                            rewritten (`since` keeps the original) and ONE
#                            non-critical line says main is still red on a new
#                            sha, naming the job. A push that did not fix it is
#                            new information; the same sha on the next tick is not
#   green again            -> remove the flag + ONE resolve alert
#   no evidence (API error, invisible repo, no completed runs on main)
#                          -> change NOTHING. An existing flag is never cleared
#                            because a read failed: "we could not look" is not
#                            "it is fixed".
#
# WHAT READS THE FLAG: EVERY automatic merge lane, through the one shared gate
# bin/lib/main-red-gate.sh (BH-945) — the merge conductor, the hub merge sweep,
# the box merge queue, the reviewer, the tier-2 sweep, the tier-1 gate inside a
# build and the union merge train. All of them freeze merges for a repo whose
# flag is present, except PRs carrying the main-red label (MC_MAIN_RED_LABEL,
# default fix-main-red) or whose whole diff is test files
# (docs/TEST-DETERMINISM.md carries the contract).
#
# AND THE FLAG IS PUBLISHED, not just written (BH-945): only the hub runs this
# detector, so every raise and clear goes through flag_set as well, which writes
# the pause_flags row a BOX materialises into its own flags/ directory. Without
# that row no box could see the freeze even if it asked.
#
# FIFTH ARM, THE MERGE QUEUE (2026-09-24, "each tree is tested exactly once").
# The test corpus runs only in the Mergify merge-queue batch — a pull_request
# whose head is mergify/merge-queue/* — and a push to main runs the fast checks
# only. So a main that breaks BY ITSELF (the 2026-09-15 clock bomb, a drifted
# tool) is visible in one place: every batch goes red, whatever it carries, and
# since nothing merges no push arrives for the arms above to read. For a repo in
# MAIN_RED_QUEUE_REPOS this reads the newest pull_request runs (one more read
# per tick), keeps the REQUIRED runs on a merge-queue head, and walks them newest
# first until one is green. A red batch counts only when the PR numbers in its
# title share none with a batch already counted — Mergify's speculative batches
# STACK, so one bad PR reddens the whole stack, and that is one culprit, not a
# red main. MAIN_RED_QUEUE_STREAK independent red batches freeze merges
# (reason=queue); a title with no PR number proves no independence and does not
# count, and a batch STACKED on others ("stacked on N pull requests ahead") is
# never counted: it carries every PR ahead of it. It is the LAST arm. A freeze it
# raised clears only when a green batch newer than the freeze is seen — main's
# own push runs are fast checks and prove nothing about the corpus, and a queue
# that could not be read (or whose reds scrolled off the page) clears nothing.
#
# AND THREE OPTIONAL LIBS HOOK INTO IT (BH-3886), each called only when it is
# installed; with none of them this arm is exactly the one above. The walk also
# keeps the newest counted red's created_at and updated_at (QRED_T, QRED_DONE),
# the newest green batch's finish (QGREEN_DONE) and one W line per counted batch
# (QWALK). bin/lib/main-red-queue-attr.sh's mrqa_attr is asked about at most
# MAIN_RED_QUEUE_STREAK*2 of those batches, and one it calls `own` is left out
# of a second walk of the same page. bin/lib/main-red-queue-thaw.sh's
# mrqt_stand_down can stand the verdict down, and its mrqt_clear_ok decides a
# queue freeze's clear in place of the comparison above.
# bin/lib/main-red-queue-dispatch.sh's mrqd_self_dispatch is called wherever a
# queue freeze survives a tick. Those files own their rules. A queue flag also
# carries qred_t= and qred_done= (that newest red's created_at and updated_at)
# and raised= (the episode's first raise, kept across a new-sha rewrite).
#
# AND EVERY TICK LEAVES A VERDICT (BH-1451): the repo's main_red_verdicts row
# (BH-4156; else state/main-red/<owner>-<repo>.verdict) carries decision=red|
# green|held|none|infra, the reason, the sha and when. `held` is the streak
# arm's re-test hold (BH-1281): the detector looked, declined to raise, and its
# sha names the run it waits on. It is a last-write cell, rewritten whole on
# every path including the ones that decide nothing, so another lane can ask
# "has the detector LOOKED?" rather than infer it from a missing flag.
# bin/main-red-pr-pair.sh freezes only against decision=none; an ABSENT verdict
# freezes nothing, so a box running an older copy of this script cannot surprise anyone.
#
# SCHEDULED RUNS ARE NOT CODE EVIDENCE (BH-3769). On 2026-10-01 project-5's
# quarterly access-review report, a `schedule` run, went red on a sha main had
# already passed CI on, and the tip arm froze every project-5 merge. A
# scheduled run tests the schedule's target (prod, a vendor API, a report), not
# main's code. So a run whose event is the literal `schedule` is out of every
# arm: it is in no streak, it is no tip red, an in-flight one holds no re-test
# and arms no burst, and a scheduled green clears nothing either. It still
# counts toward which sha is the tip and how deep a sha is, because it ran on a
# sha that was really pushed. A run with no event field is code evidence, as
# before. What a scheduled red still gets is ONE --severity warn per run id
# (the newest completed scheduled run per workflow path, and only for a
# workflow MAIN_RED_SKIP_RE does not already skip), deduped in the ledger row
# kind=main_red_sched, key=<owner>/<repo>#<run-id>, written before the send,
# plus one `SCHED:` log line. Never a flag, never critical.
# A scheduled red on a sha that never had a green run of that workflow is NOT
# special-cased: that is true of every quarterly report (its last green is
# months old, on another sha), so the exception would re-freeze the very
# incident above. New code on main is judged by the push run every merge makes.
#
# Knobs (env/global.env, documented fallbacks in brackets):
#   MAIN_RED_DETECT=0 or flags/main-red-detector-off (or the `switch.main-red-detector-off` settings row)   kill switch
#   MAIN_RED_STREAK      [2]   consecutive red runs of one workflow
#   MAIN_RED_TIP_RED     [1]   the tip arm above. Only the literal 0 disarms it,
#                              which is byte-for-byte the pre-BH-629 decision
#   MAIN_RED_TIP_MIN_AGE_MIN [15]  minutes a red run on the tip must have stood
#                              before the tip arm fires
#   MAIN_RED_PER_PAGE    [20]  runs fetched per repo. Not 5: a repo with four
#                              workflows shows barely one run each in five, and
#                              a streak you cannot see reads as green.
#   MAIN_RED_BURST_BACKWALK [1] the burst arm above. Only the literal 0 disarms
#                              it, which is byte-for-byte the pre-BH-1451
#                              decision — including the deeper re-read
#   MAIN_RED_BURST_DEPTH [5]   how many distinct main shas back the walk may
#                              reach. Depth 0 is the tip arm's, never this one
#   MAIN_RED_HOLD_OVERRUN [2]  how many distinct main shas may land ON TOP of a
#                              HELD streak's sha before the hold ends early and
#                              the freeze goes up on the held failure
#                              (reason=held-overrun). 0 disarms it, which is
#                              byte-for-byte the pre-BH-1475 decision: a held
#                              streak is then never bounded
#   MAIN_RED_BURST_PER_PAGE [100] runs fetched on the ONE re-read a tick makes
#                              when its first page holds no completed required
#                              run and something required is still in flight
#   MAIN_RED_STALE_GUARD [1]   the stale-page guard and the confirming re-read
#                              above. Only the literal 0 disarms both, which is
#                              byte-for-byte the pre-BH-1927 decision: no
#                              ledger read or write and no second read
#   MAIN_RED_INFRA_RERUN [1]   a red whose failed steps are ALL `infra:` steps
#                              is re-run once, not raised (BH-2165, see
#                              mr_infra_only). Only the literal 0 disarms it,
#                              which is byte-for-byte the pre-BH-2165 decision
#   MAIN_RED_SKIP_RE     [(e2e|nightly|smoke|publish|deploy)]  workflow names OR
#                              paths that are NOT required checks
#                              (case-insensitive). Resolved once per tick: the
#                              settings row lane.main-red-pr-pair.main_red_skip_re
#                              (the knob is registered on that lane; this script
#                              reads its row and registers none), then this env
#                              name, then the default. A value that does not
#                              compile falls back to the default with one warn
#                              (BH-3769); it never disarms the detector
#   MAIN_RED_SKIP_RE_OVERRIDES [{}]  a JSON object {"<owner>/<repo>": "<regex>"}
#                              that replaces MAIN_RED_SKIP_RE for that one repo
#                              (BH-8706: a repo whose E2E runs on push can count
#                              it as required). Settings row
#                              lane.main-red-breaker.main_red_skip_re_overrides,
#                              then this env name, then {}. A bad object or a
#                              regex that does not compile logs one line and
#                              that repo keeps the global value
#   MAIN_RED_REPOS       [fleet.conf repos + $HARNESS_REPO]  explicit repo list
#   HARNESS_REPO         [example-org/cromford]
#   MAIN_RED_QUEUE       [1]   the merge-queue arm above. Only the literal 0
#                              disarms it, which is byte-for-byte the detector
#                              before it: no pull_request runs read at all
#   MAIN_RED_QUEUE_REPOS [$HARNESS_REPO]  the repos whose merge queue is read —
#                              the ones that test only in the queue
#   MAIN_RED_QUEUE_STREAK [3]  independent red batches that freeze
#   MAIN_RED_QUEUE_PER_PAGE [100] pull_request runs read per tick (GitHub's max: a
#                              busy PR stream must not scroll the batches away)
#   MAIN_RED_QUEUE_ATTR  [1]   the attribution hook above; 0 = off. Settings row
#                              lib.main-red-detector.main_red_queue_attr > env >
#                              default; a non-numeric value is the default
#   MAIN_RED_QUEUE_SELF_DISPATCH_MIN [60]  minutes, for the self-dispatch lib;
#                              0 = off. Settings row lib.main-red-detector.
#                              main_red_queue_self_dispatch_min > env > default;
#                              a non-numeric value is the default
#
#   --flagged-only  judge only the repos in the list whose freeze flag is up
#               (BH-6502, above). bin/main-red-recheck.sh runs it every 5 min.
#   --explain   print what this tick WOULD do, and exit. READ-ONLY (BH-997):
#               takes no lock, writes and clears no flags/main-red-* file,
#               publishes no pause row, writes no verdict row or file,
#               sends no alert. Its only writes are its own lines in
#               logs/main-red.log and the shared settings cache
#               (state/settings-cache.json) its settings-row reads
#               refresh, so an operator's dry run can be
#               taken next to the live */5 tick without either silencing the
#               other — and cannot freeze or unfreeze the fleet by itself.
set -uo pipefail
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")
export HARNESS="$H"
EXPLAIN=0; FLAGGED_ONLY=0; ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --explain) EXPLAIN=1 ;;
    --flagged-only) FLAGGED_ONLY=1 ;;
    -h|--help) sed -n '2,284p' "$0"; exit 0 ;;
    -*) echo "main-red-detector.sh: unknown flag $1" >&2; exit 2 ;;
    *) ARGS+=("$1") ;;
  esac
  shift
done

STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
LOG="$H/logs/main-red.log"
# --explain CREATES NOTHING but the log dir log() writes into: flags/ and
# locks/ are the lane's, and a dry run that mkdirs them has already changed the
# tree it was asked only to describe.
if [ "$EXPLAIN" = 1 ]; then mkdir -p "$H/logs" 2>/dev/null
else mkdir -p "$H/logs" "$H/flags" "$H/locks" 2>/dev/null; fi
log() { echo "$(STAMP) $*" >> "$LOG"; [ "$EXPLAIN" = 1 ] && echo "$*"; return 0; }

if [ -f "$HENV/global.env" ]; then set -a
  # shellcheck disable=SC1091
  . "$HENV/global.env" 2>/dev/null; set +a; fi
# THE FLAG HAS TO LEAVE THIS BOX (BH-945). Only the hub runs this detector, and
# until now the freeze was a LOCAL FILE: no pause_flags row was ever written for
# it, so a box asking flag_active main-red-<slug> got "no row" and merged
# straight through — which is how #931 and #942 landed in a red main on
# 2026-09-18 while the conductor logged the freeze every five minutes. Sourced
# AFTER global.env so HARNESS_SECRET is in scope. Guarded and fail-open: a tree
# with no client publishes nothing and behaves exactly as it did.
# shellcheck source=/dev/null
[ -r "$H/bin/jobs-client.sh" ] && . "$H/bin/jobs-client.sh"
# The verdict and the published marker are rows (BH-4156). Without the lib
# (a tree that carries this script alone) mrs_on says "no DB here" and the
# files below stay the record, exactly as before.
# shellcheck source=bin/lib/main-red-state.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/main-red-state.sh" 2>/dev/null || mrs_on() { return 1; }
[ "${MAIN_RED_DETECT:-1}" = 0 ] && exit 0
# shellcheck source=lib/lane-switch.sh
command -v lane_switch >/dev/null 2>&1 || . "$(dirname "${BASH_SOURCE[0]}")/lib/lane-switch.sh" 2>/dev/null || lane_switch() { [ -e "${HARNESS:-${H:-/root/harness}}/flags/$1" ]; }
lane_switch main-red-detector-off file && exit 0
command -v gh >/dev/null 2>&1 || exit 0
command -v jq >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

STREAK="${MAIN_RED_STREAK:-2}";      case "$STREAK"   in ''|*[!0-9]*) STREAK=2 ;; esac
PER_PAGE="${MAIN_RED_PER_PAGE:-20}"; case "$PER_PAGE" in ''|*[!0-9]*) PER_PAGE=20 ;; esac
# THE SKIP REGEX IS ONE KNOB WITH TWO READERS (BH-3769). It is registered once,
# on the main-red-pr-pair lane (settings row lane.main-red-pr-pair.main_red_skip_re),
# and this script is a contract reader of that row, not a second registration:
# two settable rows for one regex is the BH-1770 twin-knob defect. Read in a
# subshell with the env name UNSET, so what comes back can only be the row, and
# so the lane's other knob exports (or an exit 75) never reach this process.
mr_skip_re_row() {
  [ -r "$H/bin/lib/lane-gate.sh" ] || return 0
  ( unset MAIN_RED_SKIP_RE; export HARNESS="$H"
    # shellcheck source=bin/lib/lane-gate.sh
    . "$H/bin/lib/lane-gate.sh" >/dev/null 2>&1
    command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply main-red-pr-pair >/dev/null 2>&1
    printf '%s' "${MAIN_RED_SKIP_RE:-}" )
}
SKIP_DEFAULT='(e2e|nightly|smoke|publish|deploy)'
SKIP_BAD=""
SKIP_RE=$(mr_skip_re_row); SKIP_FROM=settings
if [ -z "$SKIP_RE" ]; then
  if [ -n "${MAIN_RED_SKIP_RE:-}" ]; then SKIP_RE="$MAIN_RED_SKIP_RE"; SKIP_FROM=env
  else SKIP_RE="${MAIN_RED_SKIP_RE:-(e2e|nightly|smoke|publish|deploy)}"; SKIP_FROM=default; fi
fi
# A REGEX THAT DOES NOT COMPILE MUST NOT DISARM THE DETECTOR. mr_verdicts' python
# would exit with no rows on it, and every repo would read "no-required" forever.
# The default is used instead, and the bad value is warned about (below, once
# the alert sender exists) and logged.
if ! python3 -c 'import re,sys; re.compile(sys.argv[1], re.I)' "$SKIP_RE" >/dev/null 2>&1; then
  SKIP_BAD="$SKIP_RE ($SKIP_FROM)"
  log "skip regex $SKIP_RE from $SKIP_FROM is invalid — using the default $SKIP_DEFAULT"
  SKIP_RE="$SKIP_DEFAULT"; SKIP_FROM=default
fi
log "skip regex $SKIP_RE from $SKIP_FROM"
# THE PER-REPO OVERRIDE (BH-8706). Registered on the main-red-breaker lane
# (settings row lane.main-red-breaker.main_red_skip_re_overrides); read here the
# same way as mr_skip_re_row: the row, then the env name, then {} (the code
# fallback of that row: no repo overridden, every decision as before).
mr_skip_by_repo_row() {
  [ -r "$H/bin/lib/lane-gate.sh" ] || return 0
  ( unset MAIN_RED_SKIP_RE_OVERRIDES; export HARNESS="$H"
    # shellcheck source=bin/lib/lane-gate.sh
    . "$H/bin/lib/lane-gate.sh" >/dev/null 2>&1
    command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply main-red-breaker >/dev/null 2>&1
    printf '%s' "${MAIN_RED_SKIP_RE_OVERRIDES:-}" )
}
SKIP_BY_REPO=$(mr_skip_by_repo_row)
[ -n "$SKIP_BY_REPO" ] || SKIP_BY_REPO="${MAIN_RED_SKIP_RE_OVERRIDES:-}"
[ -n "$SKIP_BY_REPO" ] || SKIP_BY_REPO='{}'
SKIP_GLOBAL="$SKIP_RE"
# mr_skip_for <slug> — rc 0 prints the repo's override regex; rc 1 the repo has
# none; rc 2 the object or the regex is invalid. The key match is exact.
mr_skip_for() {
  python3 - "$SKIP_BY_REPO" "$1" <<'PYEOF' 2>/dev/null
import json, re, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    sys.exit(2)
if not isinstance(d, dict):
    sys.exit(2)
if sys.argv[2] not in d:
    sys.exit(1)
v = d[sys.argv[2]]
if not isinstance(v, str) or v == "":
    sys.exit(2)
try:
    re.compile(v, re.I)
except Exception:
    sys.exit(2)
print(v)
PYEOF
}
# BH-4080: HARNESS_REPO's default lives in the deployment defaults home.
# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-$(dirname "${BASH_SOURCE[0]}")/lib/deployment.sh}" || exit 1
TIP_RED="${MAIN_RED_TIP_RED:-1}"     # only the literal 0 disarms, as MAIN_RED_DETECT
TIP_AGE="${MAIN_RED_TIP_MIN_AGE_MIN:-15}"; case "$TIP_AGE" in ''|*[!0-9]*) TIP_AGE=15 ;; esac
BACKWALK="${MAIN_RED_BURST_BACKWALK:-1}"   # only the literal 0 disarms, as above
BURST_DEPTH="${MAIN_RED_BURST_DEPTH:-5}";  case "$BURST_DEPTH" in ''|*[!0-9]*) BURST_DEPTH=5 ;; esac
BURST_PAGE="${MAIN_RED_BURST_PER_PAGE:-100}"; case "$BURST_PAGE" in ''|*[!0-9]*) BURST_PAGE=100 ;; esac
# BH-1475. A typo must never silently disarm a freeze, so a non-numeric or
# negative value falls back to the default rather than to "off" — the same
# `case` every other numeric knob here uses. Only the literal 0 disarms.
HOLD_OVER="${MAIN_RED_HOLD_OVERRUN:-2}"; case "$HOLD_OVER" in ''|*[!0-9]*) HOLD_OVER=2 ;; esac
# THE WAY OUT NAMES THE REAL LABEL (BH-1985). The alert below tells an operator
# to land the fix as a PR carrying the main-red label, and the merge lanes
# exempt whatever bin/lib/main-red-label.sh resolves, so the text reads the same
# resolver once here. The lib is in the same bin/ tree this script syncs with
# (it landed on main before this read did), so without it the default is the
# honest answer. Not an env read: a bare ${X:-} here would make this lane look
# like it owns a knob the lib owns (tests/lanes-registry-test.sh section 7).
if [ -r "$(dirname "${BASH_SOURCE[0]}")/lib/main-red-label.sh" ]; then
  # shellcheck source=bin/lib/main-red-label.sh
  . "$(dirname "${BASH_SOURCE[0]}")/lib/main-red-label.sh"
  main_red_label_prime "$H"
  MRD_LABEL=$(main_red_label_resolve "$H")
else
  MRD_LABEL=fix-main-red
fi
STALE_GUARD="${MAIN_RED_STALE_GUARD:-1}"   # only the literal 0 disarms, as MAIN_RED_DETECT
INFRA_RERUN="${MAIN_RED_INFRA_RERUN:-1}"   # only the literal 0 disarms, as MAIN_RED_DETECT
QUEUE_ARM="${MAIN_RED_QUEUE:-1}"           # only the literal 0 disarms, as MAIN_RED_DETECT
QUEUE_REPOS="${MAIN_RED_QUEUE_REPOS:-$HARNESS_REPO}"
QUEUE_STREAK="${MAIN_RED_QUEUE_STREAK:-3}"; case "$QUEUE_STREAK" in ''|*[!0-9]*|0) QUEUE_STREAK=3 ;; esac
QUEUE_PAGE="${MAIN_RED_QUEUE_PER_PAGE:-100}"; case "$QUEUE_PAGE" in ''|*[!0-9]*|0) QUEUE_PAGE=100 ;; esac
# THE QUEUE HOOKS' TWO KNOBS (BH-3886) are registered on the lib scope
# (catalog/lanes.d/_lib.main-red-detector.json) and read the way mr_skip_re_row
# reads its row: in a subshell with both env names UNSET, so what comes back is
# the row alone. One per line, never tab-joined: a tab is IFS whitespace and an
# empty first field would collapse into the second.
mr_lib_knob_rows() {
  [ -r "$H/bin/lib/lane-gate.sh" ] || return 0
  ( unset MAIN_RED_QUEUE_ATTR MAIN_RED_QUEUE_SELF_DISPATCH_MIN; export HARNESS="$H"
    # shellcheck source=bin/lib/lane-gate.sh
    . "$H/bin/lib/lane-gate.sh" >/dev/null 2>&1
    command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply main-red-detector >/dev/null 2>&1
    printf '%s\n%s\n' "${MAIN_RED_QUEUE_ATTR:-}" "${MAIN_RED_QUEUE_SELF_DISPATCH_MIN:-}" )
}
# mr_knob <row> <env> <default> — "<value> <from>": row, then env, then the
# default. A value that is not a whole number is the default, never off.
mr_knob() {
  local v="$1" from=settings
  [ -n "$v" ] || { v="$2"; from=env; }
  [ -n "$v" ] || { v="$3"; from=default; }
  case "$v" in *[!0-9]*) v="$3"; from=default ;; esac
  printf '%s %s' "$v" "$from"
}
MRK_ATTR=""; MRK_DISP=""
{ read -r MRK_ATTR; read -r MRK_DISP; } < <(mr_lib_knob_rows)
read -r MR_QUEUE_ATTR MRK_ATTR_FROM <<<"$(mr_knob "$MRK_ATTR" "${MAIN_RED_QUEUE_ATTR:-}" 1)"
read -r MR_QUEUE_SELF_DISPATCH_MIN MRK_DISP_FROM <<<"$(mr_knob "$MRK_DISP" "${MAIN_RED_QUEUE_SELF_DISPATCH_MIN:-}" 60)"
export MR_QUEUE_ATTR MR_QUEUE_SELF_DISPATCH_MIN
log "queue knobs attr=$MR_QUEUE_ATTR (from $MRK_ATTR_FROM) self-dispatch=$MR_QUEUE_SELF_DISPATCH_MIN (from $MRK_DISP_FROM)"
# ONE clock read for the whole run: every repo in the loop below is judged
# against the same NOW, so two repos cannot disagree about what "15 minutes
# ago" means half a second apart.
NOW=$(date +%s)

# DEDUPE, NEVER A QUEUE: two ticks would both see the same red and both alert.
# --explain SENDS NOTHING, so it has nothing to dedupe against: taking the lock
# made a dry run and the */5 tick silence each other in whichever order they
# arrived — and this arm's held-lock path is a bare `exit 0`, so the operator
# got no output at all — while opening the file truncated the one the running
# tick was holding.
# mr_flag_name <slug> — the freeze flag's basename. mr_flag_up <name> — rc 0
# when that freeze is up on this hub. mr_flag_files — the basename of every
# freeze flag on disk; the two lane switches share the prefix and are not freezes.
mr_flag_name() { printf 'main-red-%s' "$(printf '%s' "$1" | tr '/' '-')"; }
mr_flag_up()   { [ -f "$H/flags/$1" ]; }
mr_flag_files() {
  local f n
  for f in "$H"/flags/main-red-*; do
    [ -f "$f" ] || continue
    n=$(basename "$f")
    case "$n" in main-red-detector-off|main-red-pr-pair-off) continue ;; esac
    printf '%s\n' "$n"
  done
}
if [ "$EXPLAIN" != 1 ] && command -v flock >/dev/null 2>&1; then
  exec 8>"$H/locks/main-red-detector.lock"
  if ! flock -n 8; then
    # A skipped pass is said for every freeze it leaves up (BH-6352), and only
    # then: with no flag up a held lock stays as quiet as it always was.
    while read -r _mrn; do
      [ -n "$_mrn" ] && log "$_mrn: decision=none reason=lock-held — another pass holds locks/main-red-detector.lock"
    done < <(mr_flag_files)
    exit 0
  fi
fi

# The repo list, read exactly the way bin/pipeline-health.sh's perma-red check
# reads it (fleet.conf through bin/fleet-conf.sh), plus the harness repo itself
# — which is the repo this detector was written for and the one no project row
# names.
if [ "${#ARGS[@]}" -gt 0 ]; then
  REPOS=$(printf '%s\n' "${ARGS[@]}")
elif [ -n "${MAIN_RED_REPOS:-}" ]; then
  REPOS=$(printf '%s\n' $MAIN_RED_REPOS)
else
  REPOS=$( { awk '$1!~/^#/ && NF>=2 {print $1}' "$H/fleet.conf" 2>/dev/null | grep -vE "redirect" | while read -r P; do
              "$H/bin/fleet-conf.sh" "$P" repo 2>/dev/null; done; echo "$HARNESS_REPO"; } \
            | grep -E '^[^-][^ ]*/[^ ]+$' | awk '!seen[$0]++' )
fi
[ -n "$REPOS" ] || { log "no repos to check — fleet.conf unreadable and MAIN_RED_REPOS unset"; exit 0; }
# --flagged-only (BH-6502): keep only the slugs whose freeze is up, in list
# order. None left = nothing to re-check: exit 0 before any line or trap.
if [ "$FLAGGED_ONLY" = 1 ]; then
  _mrf=""
  for _mrs in $REPOS; do mr_flag_up "$(mr_flag_name "$_mrs")" && _mrf+="$_mrs"$'\n'; done
  REPOS="${_mrf%$'\n'}"
  [ -n "$REPOS" ] || exit 0
fi

# mr_flagged_first — REPOS with every slug whose freeze is up moved to the
# front. Both groups keep their relative order. Only a scheduled pass (no repo
# arguments) is reordered: an explicit list is judged as given.
mr_flagged_first() {
  local s up=() rest=()
  for s in $REPOS; do
    if mr_flag_up "$(mr_flag_name "$s")"; then up+=("$s"); else rest+=("$s"); fi
  done
  printf '%s\n' ${up[@]+"${up[@]}"} ${rest[@]+"${rest[@]}"}
}
# mr_stray_flags — one line for each freeze flag that no repo in this pass maps
# to. This pass can never clear one, so it is said, not skipped in silence.
mr_stray_flags() {
  local n s hit
  while read -r n; do
    [ -n "$n" ] || continue
    hit=0
    for s in $REPOS; do [ "$n" = "$(mr_flag_name "$s")" ] && { hit=1; break; }; done
    [ "$hit" = 1 ] || log "$n: decision=none reason=not-in-repo-list — no repo in this pass maps to it"
  done < <(mr_flag_files)
}
# mr_pass_end <rc> — the EXIT trap of a pass that is not --explain. One
# not-reached line per flagged repo the pass did not decide, then one line for
# the pass. It writes no verdict, flag, ledger row or alert.
mr_pass_end() {
  local s
  for s in $REPOS; do
    [ -n "${MR_DECIDED[$s]:-}" ] && continue
    mr_flag_up "$(mr_flag_name "$s")" || continue
    log "$s: decision=none reason=not-reached flag=$(mr_flag_name "$s") — the pass ended (exit $1, signal $MR_SIG) while on ${MR_CUR:-none}; the freeze stays up"
  done
  if [ "$FLAGGED_ONLY" = 1 ]; then
    local r=0
    [ -n "${MR_READS_F:-}" ] && [ -f "$MR_READS_F" ] && r=$(wc -c < "$MR_READS_F" | tr -d ' ')
    log "recheck: $(wc -w <<<"$REPOS" | tr -d ' ') flagged repo(s), ${r:-0} Actions read(s)"
    [ -n "${MR_READS_F:-}" ] && rm -f "$MR_READS_F"
  fi
  log "pass end: decided ${#MR_DECIDED[@]} of $(wc -w <<<"$REPOS" | tr -d ' ') repo(s) in $((SECONDS - MR_T0))s, exit $1, signal $MR_SIG, last repo ${MR_CUR:-none}"
}
declare -A MR_DECIDED=()
MR_CUR=""; MR_SIG=none; MR_T0=$SECONDS
if [ "$EXPLAIN" != 1 ]; then
  _mrup=""
  for _mrs in $REPOS; do mr_flag_up "$(mr_flag_name "$_mrs")" && _mrup+="${_mrup:+ }$_mrs"; done
  if [ "$FLAGGED_ONLY" = 1 ]; then
    log "pass start: recheck, $(wc -w <<<"$REPOS" | tr -d ' ') flagged repo(s): $(printf '%s' "$REPOS" | tr '\n' ' ')"
    MR_READS_F=$(mktemp 2>/dev/null) || MR_READS_F=""
  elif [ "${#ARGS[@]}" -eq 0 ]; then
    REPOS=$(mr_flagged_first)
    mr_stray_flags
    log "pass start: $(wc -w <<<"$REPOS" | tr -d ' ') repo(s), $(wc -w <<<"$_mrup" | tr -d ' ') with a flag up, decided first: ${_mrup:-none}"
  else
    log "pass start: $(wc -w <<<"$REPOS" | tr -d ' ') repo(s), $(wc -w <<<"$_mrup" | tr -d ' ') with a flag up, order as given"
  fi
  trap 'MR_SIG=TERM; exit 143' TERM
  trap 'MR_SIG=INT; exit 130' INT
  trap 'MR_SIG=HUP; exit 129' HUP
  trap 'mr_pass_end $?' EXIT
fi

# shellcheck source=bin/lib/gh-repo-token.sh
[ -r "$H/bin/lib/gh-repo-token.sh" ] && . "$H/bin/lib/gh-repo-token.sh" 2>/dev/null
# The App installation token is the identity when this box mints them (#469);
# the PAT probe above stays the fallback, and gh_default_auth_for_slug asks in
# that order. The tag it exports is what bin/lib/gh-limit-logger.sh writes down
# when GitHub rate-limits one of the Actions reads below.
# shellcheck source=bin/lib/gh-app-auth.sh
[ -r "$H/bin/lib/gh-app-auth.sh" ] && . "$H/bin/lib/gh-app-auth.sh"
# shellcheck source=bin/lib/gh-limit-logger.sh
[ -r "$H/bin/lib/gh-limit-logger.sh" ] && . "$H/bin/lib/gh-limit-logger.sh" 2>/dev/null
# THE QUEUE ARM'S OPTIONAL LIBS (BH-3886). Each defines hooks mr_queue_verdict
# and the clear/still-red paths call only when `type` finds them; a lib that is
# absent leaves today's path running unchanged. Sourced in-process, so they read
# $EXPLAIN (and write nothing when it is 1), $SKIP_RE, $RUNS, $NOW, log and alert.
for _mrl in main-red-queue-thaw main-red-queue-attr main-red-queue-dispatch; do
  # shellcheck source=/dev/null
  . "$H/bin/lib/$_mrl.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/$_mrl.sh" 2>/dev/null || true
done

# mr_mark <flag-basename> on|off — the published marker (BH-4156): the ledgers
# row main_red_published/<name>, status on|off. state/main-red/<name>.published
# is the file it replaced. A landed row write removes a leftover file. When the
# row cannot be written (no DB here, a worker that answers 404, an outage) the
# file is written as before: a marker left ON only costs one harmless OFF
# republish later, and a lost one would leave every box frozen.
mr_mark() {
  local pf="$H/state/main-red/$1.published" rc=2
  if mrs_on; then mrs_published_set "$1" "$2"; rc=$?; fi
  if [ "$rc" = 0 ]; then rm -f "$pf"; return 0; fi
  [ "$rc" = 2 ] || log "$1: published marker row not written — state/main-red/$1.published holds it until a write lands"
  if [ "$2" = on ]; then mkdir -p "$H/state/main-red" 2>/dev/null; : > "$pf"; else rm -f "$pf"; fi
  return 0
}
# mr_marked <flag-basename> — rc 0 when the marker is ON (the row says on, or
# the fallback file is there), 1 when it is not, 2 when the row is unreadable
# and no file says on: do not act on it.
mr_marked() {
  local rc=2
  [ -f "$H/state/main-red/$1.published" ] && return 0
  if mrs_on; then mrs_published_get "$1"; rc=$?; fi
  case "$rc" in 0) return 0 ;; 3|2) return 1 ;; *) return 2 ;; esac
}

# mr_publish <flag-basename> on|off <reason> — the row every OTHER box reads.
# ORDER IS ALWAYS file -> row -> alert: the hub is correct even if the PUT dies,
# and the next red tick republishes (this is called on the still-red tick too,
# which is what makes a missed PUT self-heal). flag_set only touch/rm's the
# file, so the flag BODY written just above — sha, workflow, job, since, reason
# — is untouched and the conductor's MAIN_RED_WHY line still reads it.
# Returns flag_set's rc, and keeps the published marker (mr_mark) while the
# row is known to be ON: set on a landed `on` PUT, cleared on a landed `off`
# PUT. The marker is what makes the OFF side self-heal. The red side republishes
# every tick because the flag file is there to prompt it; after `rm -f "$FLAG"`
# a green tick has no file, so a dead `off` PUT used to leave the row active
# and every box frozen until a hand ran `flag_set ... off` (#957 review, item 2).
mr_publish() {
  local n="$1" onoff="$2"
  # The row IS the freeze as every other box sees it, so a dry run names it and
  # writes nothing — not even state/main-red/.
  [ "$EXPLAIN" = 1 ] && { log "WOULD PUBLISH $n=$onoff (${3:-})"; log "WOULD PUBLISH detail $n=$onoff"; return 0; }
  command -v flag_set >/dev/null 2>&1 || return 0
  if flag_set "$n" "$onoff" "${3:-}" >/dev/null 2>&1; then
    mr_mark "$n" "$onoff"
    mr_row "$n" "$onoff" "${3:-}"
    return 0
  fi
  log "$n: could not be published to the coordination DB — the hub file is authoritative, boxes see it on the next successful publish"
  mr_row "$n" "$onoff" "${3:-}"
  return 1
}

# mr_project <slug> — the fleet.conf project whose repo is <slug>; empty when no
# row names it (the harness repo itself), which the detail row sends as null.
mr_project() {
  awk -v s="$1" '$1!~/^#/ && $2==s {print $1; exit}' "$H/fleet.conf" 2>/dev/null
}

# mr_row <flag-basename> on|off <reason> — the main_red DETAIL row (BH-2373):
# which sha, workflow, job and run froze this repo, for the console banner and
# the operator's clear. Sent after the pause_flags PUT whatever that returned,
# so the freeze itself never waits on it. `on` reads the fields from the flag
# body just written; `off` has no flag left to read, so it sends name + active
# only. A field the flag lacks goes out null, never a made-up value. Always
# returns 0: a dead PUT is one log line and the next red tick republishes.
mr_row() {
  local n="$1" f="$H/flags/$1" active=0 body k
  local -A v=([sha]="" [workflow]="" [job]="" [since]="" [run]="")
  command -v _jobs_req >/dev/null 2>&1 || return 0
  if [ "$2" = on ]; then
    active=1
    for k in "${!v[@]}"; do v[$k]=$(sed -n "s/^$k=//p" "$f" 2>/dev/null | head -1); done
  fi
  body=$(jq -nc --arg name "$n" --argjson active "$active" --arg slug "$SLUG" \
    --arg project "$(mr_project "$SLUG")" --arg reason "${3:-}" --arg sha "${v[sha]}" \
    --arg workflow "${v[workflow]}" --arg job "${v[job]}" --arg since "${v[since]}" --arg run "${v[run]}" '
    def n: if . == "" then null else . end;
    {name:$name, active:$active, slug:$slug, project:($project|n), sha:($sha|n),
     workflow:($workflow|n), job:($job|n), run_url:($run|n), since:($since|n), reason:$reason}') \
    && _jobs_req PUT /api/main-red "$body" >/dev/null \
    || log "$n: detail row not published"
  return 0
}

# mr_cleared_load — MR_CLEARED[<flag-basename>]=<cleared_sha> for every main_red
# row an operator cleared (active 0, cleared_sha set), read ONCE per run before
# the per-repo loop. A read that fails, 404s (a worker without the route) or
# does not parse leaves the map EMPTY and says so in one line: no clear is
# honoured and every red raises exactly as before. It is a read, so --explain
# makes it too.
declare -A MR_CLEARED=()
mr_cleared_load() {
  local raw rows name sha
  command -v _jobs_req >/dev/null 2>&1 || return 0
  if ! raw=$(_jobs_req GET '/api/main-red?all=1') \
     || ! rows=$(jq -r '(.main_red // .rows // (if type=="array" then . else error end))[]
          | select((.active==0 or .active==false) and ((.cleared_sha // "")|length>0))
          | [.name, .cleared_sha] | @tsv' <<<"$raw" 2>/dev/null); then
    log "main-red clears unreadable — no operator clear honoured this run"
    return 0
  fi
  while IFS=$'\t' read -r name sha; do
    [[ "$name" =~ ^main-red-[A-Za-z0-9._-]+$ ]] && [ -n "$sha" ] && MR_CLEARED["$name"]="$sha"
  done <<<"$rows"
  return 0
}

# mr_verdict <slug> <decision> <reason> [sha] — what this tick DECIDED, in a
# file another lane can read (BH-1451). Every exit path of the per-repo loop
# below writes one, including the ones that decide nothing: the whole value of
# this cell is that "none" is stated rather than inferred from a missing flag,
# which is also what a repo that was never checked looks like.
# Last-write, rewritten whole, keyed on the slug. Nothing dedupes on it and a
# missing one is read as "do not act", so it cannot go stale into an action.
# --explain writes NOTHING here: the record is a fact about a tick that happened.
# BH-4156: the record is the main_red_verdicts row. state/main-red/<slug>.verdict
# is written only where the row cannot be (no DB here, or a worker that
# answers 404 because it predates the route), and a landed row removes a
# leftover file. A row write that fails writes no file: the reader does not act
# on an unreadable row, so a file would only be read by nobody.
# mr_count_read — one byte in $MR_READS_F per GitHub Actions GET, in a
# --flagged-only pass only (the file is unset otherwise). A file, not a
# variable: read_jobs runs inside $(...). The rerun POST is not counted.
mr_count_read() { [ -n "${MR_READS_F:-}" ] && printf x >> "$MR_READS_F" 2>/dev/null; return 0; }
mr_verdict() {
  MR_DECIDED["$1"]=1
  [ "$EXPLAIN" = 1 ] && return 0
  local d="$H/state/main-red" vrc=2
  local vf="$d/$(echo "$1" | tr '/' '-').verdict"
  if mrs_on; then mrs_verdict_put "$1" "${2:-none}" "${3:-}" "${4:-}"; vrc=$?; fi
  if [ "$vrc" = 0 ]; then
    rm -f "$vf"
  elif [ "$vrc" = 2 ]; then
    # the top-level mkdir makes logs/ flags/ locks/, never state/ — so this one
    # is not redundant and a tree without it silently records nothing.
    mkdir -p "$d" 2>/dev/null || return 0
    { echo "decision=${2:-none}"; echo "reason=${3:-}"; echo "sha=${4:-}"; echo "at=$(STAMP)"; } > "$vf" 2>/dev/null
  else
    log "$1: verdict row not written (decision=${2:-none}) — the coordination DB did not take it, and a reader does not act on an unreadable verdict"
  fi
  # A freeze this tick did not judge is said in the log too (BH-6352).
  if [ "${2:-none}" = none ] && mr_flag_up "$(mr_flag_name "$1")"; then
    log "$1: decision=none reason=${3:-unknown} flag=$(mr_flag_name "$1") — the freeze stays up"
  fi
  return 0
}

# mr_verdicts <runs-json> — one verdict line per required workflow, newest first:
#   1 state(red|green) 2 streak 3 path 4 name 5 newest-sha 6 oldest-in-streak
#   7 url 8 run-id 9 tip(1|0) 10 newest-run-created_at-as-epoch (EMPTY when it
#   does not parse) 11 in-flight-sha 12 depth 13 pending_newer(1|0) 14 tip-sha
#   15 newer-shas
# Every column comes out of the runs page already in hand and costs no API call.
# 9/10 are the tip arm's; 11 is the streak arm's re-test hold (BH-1281):
#   in-flight-sha EMPTY unless a newer run of THIS workflow has not concluded —
#                 the re-test the streak arm waits for rather than freezing on
#                 top of. 12/13/14 are the burst back-walk's (BH-1451):
#   depth         how many DISTINCT main shas in the page are newer than this
#                 run's sha, shas ordered by the newest run each one carries.
#                 0 = the tip, which is the arm above's business.
#   pending_newer 1 when a REQUIRED run on a STRICTLY NEWER sha has not
#                 completed — "the head is still busy". Strictly newer is what
#                 keeps a re-run in flight on the SAME sha from arming the arm.
#   tip-sha       the head the decision would be made behind, for the flag body.
# 15 is the hold-overrun arm's (BH-1475):
#   newer-shas    the DISTINCT main shas newer than this run's sha, newest
#                 first, comma joined and capped at 10 — the same ordering
#                 depth counts, so the list is exactly what the number says.
#                 It is what "which merges landed during the hold" is built
#                 from, and it costs no API call either.
# A function, not an inline block, because the burst path evaluates it twice: a
# first page that decides nothing is re-read deeper and recomputed.
mr_verdicts() {
  python3 - "$1" "$SKIP_RE" <<'PYEOF' 2>/dev/null
import calendar, json, re, sys, time
try: runs = json.loads(sys.argv[1])
except Exception: sys.exit(0)
skip = re.compile(sys.argv[2], re.I) if sys.argv[2] else None
RED = {"failure", "timed_out", "startup_failure"}
# An ALLOW-LIST, not "anything that is not completed": a run whose status field
# is missing or a word GitHub has not shipped yet decides nothing, the same rule
# the epoch below follows. cancelled/skipped runs ARE completed and so are never
# in flight.
INFLIGHT = {"queued", "in_progress", "waiting", "pending", "requested"}

def rid(r):
    try: return int(r.get("id") or 0)
    except Exception: return 0

def order(r):                                         # newest last; ties break on the larger id
    return (r.get("t") or "", rid(r))

def epoch(t):
    try: return str(calendar.timegm(time.strptime(t, "%Y-%m-%dT%H:%M:%SZ")))
    except Exception: return ""                       # unparseable decides nothing

def required(r):                                     # name OR path (BH-3769)
    return not (skip and (skip.search(r.get("n") or "") or skip.search(r.get("p") or "")))

def sched(r):                                        # a cron run tests its target, not main's code
    return r.get("e") == "schedule"

allruns = [r for r in runs if isinstance(r, dict)]
# The tip: the newest sha in the page across EVERY workflow and EVERY status,
# skip-listed ones included. A sha is only "the tip" if nothing newer was pushed.
tip_sha = ""
if allruns: tip_sha = max(allruns, key=order).get("sha") or ""
# The main shas the page holds, newest first, each ranked by the NEWEST run it
# carries. That ranking is the back-walk's idea of "how many commits behind" —
# the runs page is the only history this detector reads, and a sha with a run in
# it is a sha that was pushed.
sha_newest = {}
for r in allruns:
    s = r.get("sha") or ""
    if not s: continue
    if s not in sha_newest or order(r) > sha_newest[s]: sha_newest[s] = order(r)
ordered = [s for s, _ in sorted(sha_newest.items(), key=lambda kv: kv[1], reverse=True)]
depth_of = {s: i for i, s in enumerate(ordered)}
# The shallowest sha carrying a required run that has NOT completed. Anything
# deeper than this has something newer still in flight.
pending = [depth_of[r.get("sha") or ""] for r in allruns
           if r.get("s") != "completed" and (r.get("sha") or "") in depth_of and required(r)
           and not sched(r)]
min_pending = min(pending) if pending else None
# And the newest run of each workflow whatever its status: a newer in-progress or
# cancelled run of the same workflow means a re-run is in flight or somebody
# intervened, and the arm waits rather than freezing on top of them.
# A scheduled run is not a re-run of anything (BH-3769): it never holds a streak.
newest_any = {}
for r in allruns:
    if sched(r): continue
    k = r.get("p") or r.get("n") or "?"
    if k not in newest_any or order(r) > order(newest_any[k]): newest_any[k] = r

by = {}
for r in allruns:
    if r.get("s") != "completed": continue
    c = r.get("c")
    if c not in RED and c != "success": continue      # cancelled/skipped/neutral: not evidence
    name = r.get("n") or "?"
    path = r.get("p") or name
    if not required(r): continue                      # not a required check
    if sched(r): continue                             # not evidence about main's code (BH-3769)
    by.setdefault(path, []).append(r)
for path, rs in sorted(by.items()):
    rs.sort(key=order, reverse=True)
    newest = rs[0]
    streak = 0
    for r in rs:
        if r.get("c") == "success": break
        streak += 1
    state = "red" if streak else "green"
    since = rs[streak - 1].get("t") if streak else newest.get("t")
    na = newest_any.get(path)
    tip = "1" if (na is not None and order(na) == order(newest)
                  and tip_sha and (newest.get("sha") or "") == tip_sha) else "0"
    # The sha of a newer run of THIS workflow that has not concluded — the
    # re-test the streak arm waits for rather than freezing on top of (BH-1281).
    inflight = (na.get("sha") or "?") if (na is not None and order(na) > order(newest)
                                          and (na.get("s") or "") in INFLIGHT) else ""
    depth = depth_of.get(newest.get("sha") or "", "")
    pend = "1" if (min_pending is not None and depth != "" and min_pending < depth) else "0"
    # The shas that landed ON TOP of this row's sha, newest first (BH-1475).
    # Same ordering `depth` is counted from, so the list is exactly what the
    # number says, and capped so one pathological page cannot produce a log
    # line nobody can read.
    newer = ",".join(ordered[:depth][:10]) if depth != "" else ""
    print("\t".join([state, str(streak), path, newest.get("n") or "?", newest.get("sha") or "?",
                     since or "?", newest.get("u") or "", str(newest.get("id") or ""),
                     tip, epoch(newest.get("t")), inflight, str(depth), pend, tip_sha, newer]))
PYEOF
}

# mr_read_page <slug> <per_page> — ONE runs read. Sets PG_RUNS (the projected
# runs array every arm reads), PG_TOTAL (the page's total_count) and PG_NEWEST
# (the newest created_at in it); either of the last two is EMPTY when the page
# does not carry it, and an empty one decides nothing in mr_stale. rc 1 when the
# read failed. A bare array is still read as the runs: that is the projection
# this script asked for before BH-1927, and it simply carries no count.
mr_read_page() {
  local raw
  PG_RUNS=""; PG_TOTAL=""; PG_NEWEST=""
  mr_count_read
  raw=$(gh api -X GET "repos/$1/actions/runs" -f branch=main -f per_page="$2" \
    -q '{total:.total_count, runs:[.workflow_runs[]? | {n:.name, p:.path, s:.status, c:.conclusion, sha:.head_sha, t:.created_at, u:.html_url, id:.id, e:.event}]}' 2>/dev/null) || return 1
  PG_RUNS=$(jq -c 'if type=="array" then . else (.runs // []) end' <<<"$raw" 2>/dev/null) || PG_RUNS=""
  PG_TOTAL=$(jq -r 'if type=="object" then (.total // empty) else empty end' <<<"$raw" 2>/dev/null)
  case "$PG_TOTAL" in *[!0-9]*) PG_TOTAL="" ;; esac
  PG_NEWEST=$(jq -r '[.[]? | .t // empty | select(test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$"))] | max // empty' <<<"$PG_RUNS" 2>/dev/null)
  return 0
}

# The floor (BH-1927): the newest total_count (FL_TOTAL) and newest run
# created_at (FL_NEWEST) this detector has ACCEPTED for $SLUG. It lives in ONE
# `ledgers` row, kind=main_red_runs, key=<owner>/<repo>, status
# "total=<n> newest=<created_at>". No file: with the ledger unreachable the
# floor is empty for the tick, nothing can be called stale on it, and the
# confirming re-read before a raise is the guard that is left.
MR_LEDGER_KIND=main_red_runs
mr_floor_load() {
  local st
  FL_TOTAL=""; FL_NEWEST=""
  [ "$STALE_GUARD" = 0 ] && return 0
  command -v job_ledger_get >/dev/null 2>&1 || return 0
  st=$(job_ledger_get "$MR_LEDGER_KIND" "$1" 2>/dev/null) || return 0
  FL_TOTAL=$(sed -n 's/^total=\([0-9][0-9]*\) .*/\1/p' <<<"$st")
  FL_NEWEST=$(sed -n 's/.* newest=\([0-9T:Z-]*\)$/\1/p' <<<"$st")
  return 0
}

# mr_stale — rc 0 when the page in PG_* goes BACKWARDS against the floor, with
# both sides of it in STALE_WHY. ISO-8601 Z timestamps compare as strings. Only
# an OLDER newest run makes a page stale (the incident's pages carried week-old
# runs). A page whose newest run is the floor's or newer is fresh whatever its
# count: retention or a manual delete lowers total_count on a live repo, and a
# count-only rejection there would hide a run that finished red (or was re-run
# green) under the same created_at until the next push (#1966 review). The
# count decides only when the page has no newest run to compare.
mr_stale() {
  STALE_WHY="total_count ${PG_TOTAL:-?} (already seen ${FL_TOTAL:-?}), newest run ${PG_NEWEST:-?} (already seen ${FL_NEWEST:-?})"
  [ "$STALE_GUARD" = 0 ] && return 1
  if [ -n "$PG_NEWEST" ] && [ -n "$FL_NEWEST" ] && [[ "$PG_NEWEST" < "$FL_NEWEST" ]]; then
    return 0
  fi
  if [ -z "$PG_NEWEST" ] && [ -n "$FL_NEWEST" ] \
     && [ -n "$PG_TOTAL" ] && [ -n "$FL_TOTAL" ] && [ "$PG_TOTAL" -lt "$FL_TOTAL" ]; then
    return 0
  fi
  return 1
}

# mr_floor_raise — an accepted page moves the floor, in memory and in the row.
# A page whose newest run is the floor's or newer sets the count to the page's
# own, lower or not (see mr_stale); a page with no newest run only ever raises
# it. One idempotent upsert, and only when something moved.
# --explain reads the row and never writes it.
mr_floor_raise() {
  local moved=0
  [ "$STALE_GUARD" = 0 ] && return 0
  if [ -n "$PG_NEWEST" ] && { [ -z "$FL_NEWEST" ] || ! [[ "$PG_NEWEST" < "$FL_NEWEST" ]]; }; then
    if [ "$PG_NEWEST" != "$FL_NEWEST" ] || { [ -n "$PG_TOTAL" ] && [ "$PG_TOTAL" != "$FL_TOTAL" ]; }; then
      FL_NEWEST=$PG_NEWEST; [ -n "$PG_TOTAL" ] && FL_TOTAL=$PG_TOTAL; moved=1
    fi
  elif [ -n "$PG_TOTAL" ] && { [ -z "$FL_TOTAL" ] || [ "$PG_TOTAL" -gt "$FL_TOTAL" ]; }; then
    FL_TOTAL=$PG_TOTAL; moved=1
  fi
  [ "$moved" = 1 ] && [ "$EXPLAIN" != 1 ] && [ -n "$FL_TOTAL" ] && [ -n "$FL_NEWEST" ] || return 0
  command -v job_ledger_put >/dev/null 2>&1 || return 0
  job_ledger_put "$MR_LEDGER_KIND" "$SLUG" "total=$FL_TOTAL newest=$FL_NEWEST" >/dev/null 2>&1 \
    || log "$SLUG: could not record the runs-page floor (total=$FL_TOTAL newest=$FL_NEWEST) in the ledger — the next tick judges staleness without it"
  return 0
}

# mr_queue_verdict <slug> — the merge-queue arm's input (see the header). Sets
#   QREAD     ok | fail | off — whether the queue was looked at this tick
#   QVERDICT  ONE row in mr_verdicts' column layout (state red, streak = the
#             independent red batches, the newest one's name/sha/url/id, since =
#             the oldest counted batch's created_at, tip 0) when
#             MAIN_RED_QUEUE_STREAK independent batches are red with no green
#             batch newer; empty otherwise
#   QGREEN_T  the created_at of the newest GREEN merge-queue batch in the page
#             (any batch, stacked or not: a green stack proves main green too)
#   QGREEN_DONE the newest updated_at (finish) over those green batches
#   QRED_T / QRED_DONE  the newest COUNTED red batch's created_at / updated_at,
#             set only with a verdict. Empty when GitHub gave no updated_at,
#             which a reader takes as "unknown", never as green
#   QWALK     one "W<tab><run-id><tab><PR,PR...>" line per counted red batch,
#             newest first, set only with a verdict — what attribution reads
#
# ONLY A BATCH TESTED DIRECTLY ON MAIN COUNTS AS RED EVIDENCE. Mergify titles a
# speculative batch "merge queue: checking #2153 + #2148 together on main
# (11b8d1e), stacked on 8 pull requests ahead" — it carries every PR ahead of
# it, so one bad PR at the head reddens the whole stack (2026-09-24 19:08-19:17Z:
# one red head batch, a stack of reds behind it, main green). A title with
# "stacked on" is never counted; among the rest, a batch counts only when its PR
# numbers share none with a batch already counted, and a title with no PR
# number proves nothing.
#
# _mrq_walk <raw> <exclude-csv> prints the G / GD lines, and with a verdict the
# verdict row, R and the W lines. The run ids in <exclude-csv> are skipped
# before the stacked and independence checks; an empty list is the walk as it
# always was. Pass 2 re-walks the SAME raw page, so it costs no second read.
_mrq_walk() {
  python3 - "$1" "$SKIP_RE" "$QUEUE_STREAK" "$2" <<'PYEOF' 2>/dev/null
import calendar, json, re, sys, time
try: runs = json.loads(sys.argv[1])
except Exception: sys.exit(3)
if not isinstance(runs, list): sys.exit(3)
skip = re.compile(sys.argv[2], re.I) if sys.argv[2] else None
need = int(sys.argv[3])
excl = set(x for x in sys.argv[4].split(",") if x)
# Only a FAILED batch is red code. timed_out and startup_failure are the runner
# or the platform (a job that never started, a machine that died): they are
# skipped, neither red evidence nor a green that ends the walk.
RED = {"failure"}
def rid(r):
    try: return int(r.get("id") or 0)
    except Exception: return 0
q = [r for r in runs if isinstance(r, dict)
     and str(r.get("hb") or "").startswith("mergify/merge-queue/")
     and r.get("s") == "completed" and (r.get("c") in RED or r.get("c") == "success")
     and not (skip and (skip.search(r.get("n") or "") or skip.search(r.get("p") or "")))]
q.sort(key=lambda r: (r.get("t") or "", rid(r)), reverse=True)
greens = [r for r in q if r.get("c") == "success"]
print("G\t" + max([r.get("t") or "" for r in greens], default=""))
print("GD\t" + max([r.get("ut") or "" for r in greens], default=""))
seen, counted = set(), []
for r in q:
    if r.get("c") == "success": break
    if str(r.get("id")) in excl: continue
    dt = r.get("dt") or ""
    if re.search(r"stacked on", dt, re.I): continue
    prs = set(re.findall(r"#(\d+)", dt))
    if not prs or prs & seen: continue
    seen |= prs; counted.append((r, prs))
if len(counted) < need: sys.exit(0)
new, old = counted[0][0], counted[-1][0]
try: ep = str(calendar.timegm(time.strptime(new.get("t") or "", "%Y-%m-%dT%H:%M:%SZ")))
except Exception: ep = ""
print("\t".join(["red", str(len(counted)), new.get("p") or new.get("n") or "?", new.get("n") or "?",
                 new.get("sha") or "?", old.get("t") or "?", new.get("u") or "", str(new.get("id") or ""),
                 "0", ep, "", "", "0", "", ""]))
print("R\t" + (new.get("t") or "") + "\t" + (new.get("ut") or ""))
for r, prs in counted:
    print("W\t" + str(r.get("id") or "") + "\t" + ",".join(sorted(prs, key=int)))
PYEOF
}
# _mrq_parse <walk-output> — the Q* globals from one walk.
_mrq_parse() {
  QGREEN_T=$(sed -n 's/^G\t//p' <<<"$1" | head -1)
  QGREEN_DONE=$(sed -n 's/^GD\t//p' <<<"$1" | head -1)
  QVERDICT=$(grep '^red	' <<<"$1" | head -1)
  QRED_T=$(grep '^R	' <<<"$1" | head -1 | cut -f2)
  QRED_DONE=$(grep '^R	' <<<"$1" | head -1 | cut -f3)
  QWALK=$(grep '^W	' <<<"$1")
}
mr_queue_verdict() {
  QVERDICT=""; QGREEN_T=""; QREAD=off; QRED_T=""; QRED_DONE=""; QGREEN_DONE=""; QWALK=""
  [ "$QUEUE_ARM" = 0 ] && return 0
  case " $(printf '%s' "$QUEUE_REPOS" | tr ',' ' ') " in *" $1 "*) ;; *) return 0 ;; esac
  local raw out
  QREAD=fail
  mr_count_read
  raw=$(gh api -X GET "repos/$1/actions/runs" -f event=pull_request -f per_page="$QUEUE_PAGE" \
    -q '[.workflow_runs[]? | {n:.name, p:.path, s:.status, c:.conclusion, sha:.head_sha, hb:.head_branch, dt:.display_title, t:.created_at, ut:.updated_at, u:.html_url, id:.id}]' 2>/dev/null) || {
    log "$1: the merge-queue runs could not be read — the queue arm decides nothing this tick"; return 0; }
  out=$(_mrq_walk "$raw" "") || { log "$1: the merge-queue runs page did not parse — the queue arm decides nothing this tick"; return 0; }
  QREAD=ok
  _mrq_parse "$out"
  # ATTRIBUTION, TWO PASSES (BH-3886). mrqa_attr (bin/lib/main-red-queue-attr.sh
  # owns its rule) is asked about at most QUEUE_STREAK*2 of the counted batches,
  # newest first; each it answers `own` for — the batch's own diff broke it —
  # is excluded and the SAME page is walked again, so the exclusion costs no
  # read. Any other answer, or none, leaves the batch counted.
  if [ -n "$QVERDICT" ] && [ "$MR_QUEUE_ATTR" != 0 ]; then
    if type mrqa_attr >/dev/null 2>&1; then
      local cap=$((QUEUE_STREAK * 2)) excl="" w wid wprs wsha n=0
      local -a walk prs
      mapfile -t walk <<<"$QWALK"
      for w in "${walk[@]}"; do
        [ -n "$w" ] || continue
        n=$((n + 1)); [ "$n" -gt "$cap" ] && continue
        IFS=$'\t' read -r _ wid wprs <<<"$w"; IFS=, read -ra prs <<<"$wprs"
        MRQA_VERDICT=""; MRQA_PR=""; MRQA_WHY=""
        mrqa_attr "$1" "$wid" "${prs[@]}" </dev/null || true
        [ "${MRQA_VERDICT:-}" = own ] || continue
        excl="${excl:+$excl,}$wid"
        wsha=$(jq -r --arg id "$wid" '[.[]? | select((.id|tostring) == $id) | .sha // empty][0] // empty' <<<"$raw" 2>/dev/null)
        [ -n "$wsha" ] && wsha="${wsha:0:8}" || wsha="run $wid"
        log "$1: queue batch $wid (#${wprs//,/ + #}) red on $wsha attributed to #${MRQA_PR:-?}, not counted toward main-red — ${MRQA_WHY:-}"
      done
      [ "$n" -gt "$cap" ] && log "$1: attribution read $cap of $n red batches (cap QUEUE_STREAK*2) — the rest stay counted"
      if [ -n "$excl" ]; then
        if out=$(_mrq_walk "$raw" "$excl"); then _mrq_parse "$out"
        else log "$1: the walk without the attributed batches did not parse — the first pass stands"; fi
      fi
    elif [ -z "${MRQA_OFF_SAID:-}" ]; then
      MRQA_OFF_SAID=1
      log "attribution is off: bin/lib/main-red-queue-attr.sh is not installed"
    fi
  fi
  # A GREEN FULL-CORPUS RUN ON MAIN ITSELF outranks older red batches: a
  # workflow_dispatch of a required workflow on main that passed after the
  # newest counted red batch is main proven green. It is the way out when the
  # queue is empty and no batch will ever run to clear the freeze.
  if [ -n "$QVERDICT" ]; then
    local qd qe
    qd=$(jq -r --arg re "$SKIP_RE" '[.[]? | select(.e == "workflow_dispatch" and .s == "completed" and .c == "success")
           | select((((.n // "") | test($re; "i")) or ((.p // "") | test($re; "i"))) | not) | .t // empty] | max // empty' <<<"${RUNS:-[]}" 2>/dev/null)
    qe=$(cut -f10 <<<"$QVERDICT")
    if [ -n "$qd" ] && [ -n "$qe" ] && [ "$(date -u -d "$qd" +%s 2>/dev/null || echo 0)" -gt "$qe" ]; then
      log "$1: $(cut -f2 <<<"$QVERDICT") red merge-queue batches, but a workflow_dispatch run passed on main at $qd, after them — the queue arm stands down"
      QVERDICT=""
    fi
  fi
  # main proven green after the newest counted red, by bin/lib/main-red-queue-thaw.sh's rule.
  if [ -n "$QVERDICT" ] && type mrqt_stand_down >/dev/null 2>&1; then
    MRQT_WHY=""
    if mrqt_stand_down "$1"; then
      log "$1: $(cut -f2 <<<"$QVERDICT") red merge-queue batches, but ${MRQT_WHY:-} — the queue arm stands down"
      QVERDICT=""
    fi
  fi
  return 0
}

# mr_queue_holds — rc 0 when a reason=queue flag STAYS on a tick main's own
# runs are green. bin/lib/main-red-queue-thaw.sh's mrqt_clear_ok decides when it
# is installed (rc 0 = thawed, its MRQT_WHY lands in QTHAW for the clear's log;
# any other rc holds). Without it, today's comparison against detected=.
mr_queue_holds() {
  if type mrqt_clear_ok >/dev/null 2>&1; then
    MRQT_WHY=""
    mrqt_clear_ok "$SLUG" "$FLAG" || return 0
    QTHAW="${MRQT_WHY:-mrqt_clear_ok answered thawed}"
    return 1
  fi
  QSINCE="$(sed -n 's/^detected=//p' "$FLAG" | head -1 | sed 's/ /T/; s/Z$//')Z" \
  && QDISP=$(jq -r --arg re "$SKIP_RE" '[.[]? | select(.e == "workflow_dispatch" and .s == "completed" and .c == "success")
               | select((((.n // "") | test($re; "i")) or ((.p // "") | test($re; "i"))) | not) | .t // empty] | max // empty' <<<"$RUNS" 2>/dev/null) \
  && { [ -z "$QDISP" ] || [[ "$QDISP" < "$QSINCE" ]]; } \
  && { [ "$QREAD" != ok ] || [ -z "$QGREEN_T" ] || [[ "$QGREEN_T" < "$QSINCE" ]]; }
}
# mr_queue_self_dispatch — a reason=queue flag survived this tick: hand it to
# bin/lib/main-red-queue-dispatch.sh when installed. It owns its own gates and
# honours $EXPLAIN.
mr_queue_self_dispatch() {
  type mrqd_self_dispatch >/dev/null 2>&1 || return 0
  mrqd_self_dispatch "$SLUG" "$FLAG" || true
}

# mr_arms <verdicts> — the four arms, in order, over one page's mr_verdicts.
# Sets WORST (the row that freezes, empty when none does), REASON, HELD, HDEPTH,
# HMERGES and RMERGES. A function so the confirming re-read (BH-1927) can apply
# exactly the same decision to a second page.
mr_arms() {
  local VERDICTS="$1"
  # THE HOLD IS ON RAISING ONLY (BH-1281). With a flag already on disk this is
  # byte-for-byte the filter it has always been — the still-red republish, the
  # new-sha notice and the green clear must all keep judging an open episode on
  # completed evidence alone. With NO flag, a streak whose workflow has a newer
  # unconcluded run ($11) is a streak being re-tested: it is held rather than
  # raised on, and HELD carries the row so the tick can say so.
  # HDEPTH / HMERGES are the held row's columns 12 and 15 — how far main has
  # run past the sha being held, and which shas those are (BH-1475). Read per
  # field with awk rather than one `read`, so a column count can never shift a
  # value, and initialised together so every path below is `set -u` safe.
  HELD=""; HDEPTH=""; HMERGES=""; RMERGES=""
  if [ -f "$FLAG" ]; then
    WORST=$(awk -F'\t' -v n="$STREAK" '$1=="red" && $2+0>=n {print; exit}' <<<"$VERDICTS")
  else
    WORST=$(awk -F'\t' -v n="$STREAK" '$1=="red" && $2+0>=n && $11=="" {print; exit}' <<<"$VERDICTS")
    HELD=$(awk -F'\t' -v n="$STREAK" '$1=="red" && $2+0>=n && $11!="" {print; exit}' <<<"$VERDICTS")
    HDEPTH=$(awk -F'\t' '{print $12; exit}' <<<"$HELD")
    HMERGES=$(awk -F'\t' '{print $15; exit}' <<<"$HELD")
  fi
  REASON=streak
  # THE TIP ARM, only when the streak arm found nothing: one red run is enough if
  # it is on main's tip ($9) and has stood there long enough ($10, empty when the
  # timestamp did not parse — an unreadable field decides nothing).
  if [ -z "$WORST" ] && [ "$TIP_RED" != 0 ]; then
    WORST=$(awk -F'\t' -v now="$NOW" -v age="$TIP_AGE" \
      '$1=="red" && $9=="1" && $10!="" && (now-$10)>=age*60 {print; exit}' <<<"$VERDICTS")
    [ -n "$WORST" ] && REASON=tip
  fi
  # THE BURST BACK-WALK, last of the three: a red on a sha the head has already
  # moved past, while the head's own required runs are still in flight ($13).
  # $10!="" keeps an unparseable timestamp from deciding; $12>=1 leaves the tip
  # to the arm above; $12<=BURST_DEPTH is how far back an operator lets it look.
  #
  # A HELD STREAK HOLDS THIS ARM TOO (BH-1281 x BH-1451, resolved on the rebase
  # onto BH-1281). A streak the arm above declined to raise on because that
  # workflow is being RE-TESTED is the one shape this arm must not convert into
  # a freeze: the re-test in flight is a fix-main-red merge whose own run has not
  # finished, the reds behind it are the ones batch-resolve just lifted the flag
  # for, and re-raising here would page again and reset the mtime the lift reads
  # — exactly the fight BH-1281 exists to end, arriving through a different arm.
  # THE PRICE, stated: a burst that starts on a main ALREADY red twice keeps a
  # held streak for its whole length (every push re-runs the same workflow), so
  # this arm stays down and that shape is not seen. Current main is blind there
  # too — the hold cannot tell a re-test from a burst from the runs page alone —
  # so the gate inherits that blindness rather than introducing it. The incident
  # this arm was built for is the other shape: one completed red behind a busy
  # head, streak short, nothing held.
  if [ -z "$WORST" ] && [ -z "$HELD" ] && [ "$BACKWALK" != 0 ]; then
    WORST=$(awk -F'\t' -v d="$BURST_DEPTH" \
      '$1=="red" && $10!="" && $13=="1" && $12+0>=1 && $12+0<=d {print; exit}' <<<"$VERDICTS")
    [ -n "$WORST" ] && REASON=burst
  fi
  # FOURTH ARM, AND IT ENDS A HOLD RATHER THAN STARTING ONE (BH-1475). BH-1281's
  # hold has no upper bound: while it is held NO flag exists, so every merge
  # lane reads "not frozen" and keeps merging onto a main whose last COMPLETED
  # evidence is two reds. The re-test that bought the hold can sit in flight for
  # an hour. So when main has run away from the held sha by MAIN_RED_HOLD_OVERRUN
  # distinct shas ($12, the same measure the burst arm counts with), the hold
  # ends and the freeze goes up on the HELD failure.
  #
  # At depth 1 — the fix merged, its own run in flight — the arm does NOT fire,
  # and that is the whole BH-1281 fight, still won: the default of 2 means a
  # SECOND PR has to land on a main whose only completed evidence is red before
  # this says anything. An unreadable depth decides nothing, the same doctrine
  # as the unparseable created_at guard on the arms above. Clearing HELD keeps
  # "a held streak" and "a raised freeze" from both being true in one tick.
  if [ -z "$WORST" ] && [ -n "$HELD" ] && [ "$HOLD_OVER" != 0 ]; then
    case "$HDEPTH" in ''|*[!0-9]*) : ;; *)
      if [ "$HDEPTH" -ge "$HOLD_OVER" ]; then
        WORST="$HELD"; REASON=held-overrun; RMERGES="$HMERGES"; HELD=""
      fi ;;
    esac
  fi
  # FIFTH ARM, THE MERGE QUEUE (see the header), last: main's own runs are the
  # better evidence whenever they have any to give. QVERDICT is computed per
  # repo by mr_queue_verdict before the arms run.
  if [ -z "$WORST" ] && [ -n "${QVERDICT:-}" ]; then
    WORST="$QVERDICT"; REASON=queue
  fi
  return 0
}

alert() { # alert <critical|resolve|warn|notice|infra> <text>
  local kind="$1"; shift
  [ "$EXPLAIN" = 1 ] && { log "WOULD ALERT($kind) $*"; return 0; }
  # GREEN is a recovery, not an alert (BH-2337): it RESOLVES the RED's open
  # condition — both lines key on main-red-<slug> through bin/lib/alert-state.sh's
  # collapse table — and --log-only keeps its ALERTS.log line even when nothing
  # was open, without ever opening a row of its own.
  case "$kind" in
    critical) "$H/bin/lane-alert.sh" --critical main-red "$*" >/dev/null 2>&1 ;;
    resolve)  "$H/bin/lane-alert.sh" --resolve --log-only main-red "$*" >/dev/null 2>&1 ;;
    warn)     "$H/bin/lane-alert.sh" --severity warn main-red "$*" >/dev/null 2>&1 ;;
    *)        "$H/bin/lane-alert.sh" main-red "$*" >/dev/null 2>&1 ;;
  esac
  log "ALERT($kind) $*"
}

# INFRA-ONLY FAILURES (BH-2165). On 2026-09-24 Harness CI runs 36029556164 and
# 36029663354 failed on main because apt could not install packages: no test
# ran, and the two-red streak froze every merge lane anyway. #2159 names those
# steps `infra: …`, so a red run whose ONLY failed steps carry that prefix is
# not evidence that main is broken. It is re-run once (GitHub's own run_attempt
# is the "already re-ran it" record, so the POST goes out only at attempt 1),
# recorded as decision=infra, and never raises the flag. The same run failing
# on infra again after its rerun sends ONE non-critical alert, still no flag.
#
# mr_infra_only <slug> <run-id> — rc 0 only when the run's jobs JSON PROVES the
# failure is infra-only. Sets INF_ATTEMPT (the run_attempt the jobs belong to),
# INF_JOBS and INF_STEPS (the failed job and step names). A failed read,
# non-JSON, no jobs, a truncated list (total_count above what came back), a
# failed job with no failed step, or any failed step without the literal
# `infra:` prefix is rc 1, and the caller raises exactly as before: absent is
# not infra.
# INF_RAW keeps the body of a read that succeeded, infra or not, so read_jobs
# names the failing job from it rather than spending a second jobs read.
mr_infra_only() {
  local raw
  INF_ATTEMPT=""; INF_JOBS=""; INF_STEPS=""; INF_RAW=""
  mr_count_read
  raw=$(gh api "repos/$1/actions/runs/$2/jobs?per_page=100" 2>/dev/null) || return 1
  INF_RAW=$raw
  jq -e '
    type=="object" and (.jobs|type)=="array" and (.jobs|length)>0
    and (.total_count|type)=="number" and .total_count <= (.jobs|length)
    and ([.jobs[] | select(.conclusion=="failure" or .conclusion=="timed_out")] as $f
         | ($f|length)>0
           and all($f[]; [.steps[]? | select(.conclusion=="failure")] as $s
                         | ($s|length)>0
                           and all($s[]; (.name|type)=="string" and (.name|startswith("infra:")))))
  ' <<<"$raw" >/dev/null 2>&1 || return 1
  INF_ATTEMPT=$(jq -r '[.jobs[].run_attempt] | max // empty' <<<"$raw" 2>/dev/null)
  case "$INF_ATTEMPT" in ''|*[!0-9]*|0) INF_ATTEMPT=""; return 1 ;; esac
  INF_JOBS=$(jq -r '[.jobs[] | select(.conclusion=="failure" or .conclusion=="timed_out") | .name] | join(", ")' <<<"$raw" 2>/dev/null)
  INF_STEPS=$(jq -r '[.jobs[].steps[]? | select(.conclusion=="failure") | .name] | unique | join("; ")' <<<"$raw" 2>/dev/null)
  return 0
}

# mr_infra <slug> <run-id> <sha> <workflow> <url> — the INFRA decision for a
# run mr_infra_only has classified. Writes no flag, publishes no row, sends no
# critical alert. The alert dedupe is one `ledgers` row, kind=main_red_infra,
# key=<owner>/<repo>#<run-id>, written BEFORE the send; a ledger that cannot be
# read re-sends rather than going quiet. --explain POSTs and writes nothing.
MR_INFRA_KIND=main_red_infra
mr_infra() {
  local slug="$1" rid="$2" sha="$3" wf="$4" url="$5" key="$1#$2" st="" frozen
  # True in both states: a freeze already up on an earlier sha still holds.
  if [ -f "$FLAG" ]; then frozen="Merges stay frozen on the earlier red ($(basename "$FLAG")), not on this one."
  else frozen="Merges are NOT frozen."; fi
  command -v job_ledger_get >/dev/null 2>&1 && st=$(job_ledger_get "$MR_INFRA_KIND" "$key" 2>/dev/null)
  if [ "$INF_ATTEMPT" -le 1 ]; then
    # A POST that GitHub accepted but whose run still reads attempt 1 on this
    # tick is not a reason to ask again: that is two reruns, not one.
    if [ "$st" = "rerun=requested attempt=1" ]; then
      mr_verdict "$slug" infra rerun-pending "$sha"
      log "$slug: \"$wf\" run $rid failed only on infra step(s) ($INF_STEPS) and its rerun is already requested — waiting for it, main-red NOT raised"
      return 0
    fi
    if [ "$EXPLAIN" = 1 ]; then
      log "WOULD RERUN $slug run $rid (\"$wf\", ${sha:0:8}): only infra step(s) failed ($INF_STEPS) — main-red would NOT be raised"
      return 0
    fi
    if gh api -X POST "repos/$slug/actions/runs/$rid/rerun-failed-jobs" >/dev/null 2>&1; then
      mr_infra_put "$key" "rerun=requested attempt=1"
      mr_verdict "$slug" infra rerun "$sha"
      log "INFRA: $slug \"$wf\" run $rid (${sha:0:8}, job: $INF_JOBS) — only infra step(s) failed ($INF_STEPS) — re-ran the failed jobs once, main-red NOT raised"
      return 0
    fi
    mr_verdict "$slug" infra rerun-refused "$sha"
    case "$st" in rerun=refused*)
      log "$slug: the rerun of infra-only run $rid was refused again — already alerted, main-red NOT raised"
      return 0 ;;
    esac
    mr_infra_put "$key" "rerun=refused attempt=1"
    alert infra "$slug main: \"$wf\" failed on infra step(s) only ($INF_STEPS) and the rerun request was refused — re-run run $rid by hand. $frozen $url"
    return 0
  fi
  mr_verdict "$slug" infra repeat "$sha"
  if [ "$st" = "alerted attempt=$INF_ATTEMPT" ]; then
    log "$slug: \"$wf\" run $rid is still infra-only red at attempt $INF_ATTEMPT — already alerted, main-red NOT raised"
    return 0
  fi
  mr_infra_put "$key" "alerted attempt=$INF_ATTEMPT"
  alert infra "$slug main: \"$wf\" failed on infra step(s) again after its rerun ($INF_STEPS, attempt $INF_ATTEMPT). No test failed. $frozen $url"
  return 0
}
mr_infra_put() {
  [ "$EXPLAIN" = 1 ] && return 0
  command -v job_ledger_put >/dev/null 2>&1 || return 0
  job_ledger_put "$MR_INFRA_KIND" "$1" "$2" >/dev/null 2>&1 \
    || log "$1: could not record '$2' in the ledger — the next tick may repeat the alert"
  return 0
}

# SCHEDULED RUNS ARE NOT CODE EVIDENCE (BH-3769, see the header). mr_verdicts
# drops them from every arm; these two are what a scheduled red still gets.
#
# mr_sched_reds <runs-json> — for each workflow path, the NEWEST completed
# `schedule` run, kept only when it is red and its workflow is not skip-listed
# (a skip-listed nightly is bin/pipeline-health.sh's perma-red business). One
# TSV row each: name path sha url id created_at. Only the newest per path, so
# older scheduled reds deeper in the page never page on their own.
mr_sched_reds() {
  python3 - "$1" "$SKIP_RE" <<'PYEOF' 2>/dev/null
import json, re, sys
try: runs = json.loads(sys.argv[1])
except Exception: sys.exit(0)
skip = re.compile(sys.argv[2], re.I) if sys.argv[2] else None
RED = {"failure", "timed_out", "startup_failure"}
def rid(r):
    try: return int(r.get("id") or 0)
    except Exception: return 0
newest = {}
for r in runs if isinstance(runs, list) else []:
    if not isinstance(r, dict) or r.get("e") != "schedule" or r.get("s") != "completed": continue
    k = r.get("p") or r.get("n") or "?"
    if k not in newest or (r.get("t") or "", rid(r)) > (newest[k].get("t") or "", rid(newest[k])): newest[k] = r
for k, r in sorted(newest.items()):
    if r.get("c") not in RED: continue
    if skip and (skip.search(r.get("n") or "") or skip.search(r.get("p") or "")): continue
    print("\t".join([r.get("n") or "?", r.get("p") or "?", r.get("sha") or "?", r.get("u") or "",
                     str(r.get("id") or ""), r.get("t") or ""]))
PYEOF
}

# mr_sched_warn <slug> <runs-json> — ONE warn per scheduled red run, never a flag, never
# critical. The dedupe is one `ledgers` row, kind=main_red_sched,
# key=<owner>/<repo>#<run-id>, written BEFORE the send. A ledger that cannot be
# read sends anyway (the mr_infra doctrine); lane-alert collapses the identical
# text into a counted repeat, which is why the text carries no timestamp. The
# text does not start "<slug> main is RED", so it never lands on the
# main-red-<slug> condition a GREEN resolves. --explain reads, never writes.
MR_SCHED_KIND=main_red_sched
mr_sched_warn() {
  local slug="$1" name path sha url id t key st rc
  while IFS=$'\t' read -r name path sha url id t; do
    [ -n "$id" ] || continue
    key="$slug#$id"
    log "SCHED: $slug \"$name\" ($path) run $id is red on ${sha:0:8} ($t) — a scheduled run, not freeze evidence"
    st=""; rc=1
    if command -v job_ledger_get >/dev/null 2>&1; then
      st=$(job_ledger_get "$MR_SCHED_KIND" "$key" 2>/dev/null); rc=$?
    fi
    if [ "$rc" = 0 ] && [ "$st" = warned ]; then
      log "$slug: scheduled run $id (\"$name\") already warned — nothing sent"
      continue
    fi
    if [ "$EXPLAIN" != 1 ] && command -v job_ledger_put >/dev/null 2>&1; then
      job_ledger_put "$MR_SCHED_KIND" "$key" warned >/dev/null 2>&1 \
        || log "$key: could not record the scheduled-red warn in the ledger — the next tick may repeat it"
    fi
    alert warn "$slug: scheduled workflow \"$name\" ($path) is red on main at ${sha:0:8} — a scheduled run tests the schedule's target (prod, a vendor API, a report), not main's code, so merges are NOT frozen on it. $url"
  done < <(mr_sched_reds "$2")
  return 0
}

# The invalid skip regex resolved above, said once per tick now the sender
# exists. lane-alert's text hash collapses the repeats into one counted row.
[ -n "$SKIP_BAD" ] && alert warn "main-red detector: the skip regex $SKIP_BAD is not a valid regex, so the default $SKIP_DEFAULT is used instead. Fix the settings row lane.main-red-pr-pair.main_red_skip_re or MAIN_RED_SKIP_RE."

mr_cleared_load
for SLUG in $REPOS; do
  MR_CUR="$SLUG"
  [ -n "$SLUG" ] && [ "$SLUG" != "-" ] || continue
  FLAG="$H/flags/main-red-$(echo "$SLUG" | tr '/' '-')"
  SKIP_RE="$SKIP_GLOBAL"
  if [ "$SKIP_BY_REPO" != '{}' ]; then
    SKRC=0; SKV=$(mr_skip_for "$SLUG") || SKRC=$?
    case "$SKRC" in
      0) SKIP_RE="$SKV"; log "$SLUG: skip regex $SKIP_RE (by-repo)" ;;
      1) ;;
      *) log "skip regex override for $SLUG is invalid — global used" ;;
    esac
  fi
  if command -v gh_default_auth_for_slug >/dev/null 2>&1; then
    # #469: ONE call for both halves — the App token when this box can mint one
    # for this repo, the gh_repo_use_token PAT probe inside the helper when it
    # cannot. rc 1 still means NO token can see the repo, which is still the alert
    # — and --explain still only SAYS it (#997: both --explain arms are read-only,
    # no page), which is why this arm carries the same EXPLAIN branch as the one below.
    gh_default_auth_for_slug "$SLUG" || {
      if [ "$EXPLAIN" = 1 ]; then log "WOULD ALERT(repo-invisible) $SLUG: main-red detector cannot list its workflow runs"
      else gh_repo_invisible_alert main-red "$SLUG" "main-red detector cannot list its workflow runs"; fi
      mr_verdict "$SLUG" none invisible
      log "$SLUG: no token can see this repo — nothing decided, any existing flag left alone"
      continue; }
  elif command -v gh_repo_use_token >/dev/null 2>&1; then
    gh_repo_use_token "$SLUG" || {
      if [ "$EXPLAIN" = 1 ]; then log "WOULD ALERT(repo-invisible) $SLUG: main-red detector cannot list its workflow runs"
      else gh_repo_invisible_alert main-red "$SLUG" "main-red detector cannot list its workflow runs"; fi
      mr_verdict "$SLUG" none invisible
      log "$SLUG: no token can see this repo — nothing decided, any existing flag left alone"
      continue; }
    # #425: after the PAT probe on purpose — armed, the App token wins; unarmed, the probe's export stands.
    command -v gh_auth_for >/dev/null 2>&1 && gh_auth_for "$SLUG" || true
  fi
  mr_floor_load "$SLUG"
  if mr_read_page "$SLUG" "$PER_PAGE"; then RUNS="$PG_RUNS"; else RUNS=""; fi
  if [ -z "$RUNS" ] || [ "$RUNS" = "[]" ]; then
    mr_verdict "$SLUG" none no-runs
    log "$SLUG: no readable runs on main — nothing decided, any existing flag left alone"
    continue
  fi
  # A STALE PAGE DECIDES NOTHING (BH-1927): not a raise, not a clear, not a
  # new-sha rewrite. Whatever flag is on disk is left exactly as it is.
  if mr_stale; then
    mr_verdict "$SLUG" none stale-page
    log "$SLUG: GitHub answered a stale runs page — $STALE_WHY — nothing decided, any existing flag left alone"
    continue
  fi
  mr_floor_raise
  PAGE_N="$PER_PAGE"
  VERDICTS=$(mr_verdicts "$RUNS")
  # THE DEEPER READ (BH-1451). Nothing required has COMPLETED in this page and
  # something required is still in flight: that is the merge-burst shape, where
  # every run on the page belongs to a sha pushed in the last few minutes. Read
  # ONE deeper page and judge from that instead. A page with nothing pending is
  # not a burst — nothing newer is coming, so a second read would buy nothing —
  # and a re-read that fails, finds nothing or is stale (BH-1927) leaves the
  # first page's (empty) verdicts exactly as they are. Never mapped to green.
  if [ -z "$VERDICTS" ] && [ "$BACKWALK" != 0 ] && [ "$PER_PAGE" -lt "$BURST_PAGE" ]; then
    PENDING_REQ=$(jq -r --arg re "$SKIP_RE" '
        [ .[]? | select(.s!="completed") | select(.e != "schedule")
               | select((((.n // "") | test($re; "i")) or ((.p // "") | test($re; "i"))) | not) ] | length' <<<"$RUNS" 2>/dev/null)
    if [ "${PENDING_REQ:-0}" -gt 0 ] 2>/dev/null; then
      log "$SLUG: all $PENDING_REQ required run(s) in the newest $PER_PAGE are still in flight — re-reading $BURST_PAGE runs to find the newest COMPLETED one"
      if mr_read_page "$SLUG" "$BURST_PAGE"; then DEEP="$PG_RUNS"; else DEEP=""; fi
      if [ -n "$DEEP" ] && [ "$DEEP" != "[]" ] && mr_stale; then
        log "$SLUG: the deeper re-read answered a stale runs page — $STALE_WHY — it decides nothing"
      elif [ -n "$DEEP" ] && [ "$DEEP" != "[]" ]; then
        mr_floor_raise
        DEEPV=$(mr_verdicts "$DEEP")
        [ -n "$DEEPV" ] && { RUNS="$DEEP"; VERDICTS="$DEEPV"; PAGE_N="$BURST_PAGE"; }
      fi
    fi
  fi
  mr_queue_verdict "$SLUG"
  mr_sched_warn "$SLUG" "$RUNS"
  if [ -z "$VERDICTS" ] && [ -z "$QVERDICT" ]; then
    mr_verdict "$SLUG" none no-required
    log "$SLUG: no completed run of a REQUIRED workflow on main (skip=$SKIP_RE) — nothing decided"
    continue
  fi
  mr_arms "$VERDICTS"
  # AN OPERATOR CLEAR OF THIS EXACT SHA IS HONOURED (BH-2373). The console's
  # clear turns the pause_flags row off and stamps cleared_sha on the main_red
  # row; without this the still-red republish turned it back on within five
  # minutes, or the first-red path paged --critical again. Full string equality
  # on the judged sha, never a prefix: a new red sha is a new episode and raises.
  if [ -n "$WORST" ]; then
    CSHA=$(cut -f5 <<<"$WORST"); CNAME=$(basename "$FLAG")
    if [ -n "$CSHA" ] && [ "$CSHA" = "${MR_CLEARED[$CNAME]:-}" ]; then
      if [ "$EXPLAIN" = 1 ]; then
        log "WOULD HONOUR CLEAR $SLUG: main still red on ${CSHA:0:8} but an operator cleared this sha — no freeze, no page"
        continue
      fi
      mr_verdict "$SLUG" red operator-cleared "$CSHA"
      rm -f "$FLAG"; mr_mark "$CNAME" off
      log "$SLUG: main still red on ${CSHA:0:8} but an operator cleared this sha — no freeze, no page"
      continue
    fi
  fi
  # CONFIRM A NEW RAISE ON A SECOND READ (BH-1927). A flag with a `sha=` is an
  # episode this detector already called, and its still-red / new-sha / clear
  # paths are guarded by the stale check above. A flag with no `sha=` (or none
  # at all) means this tick would make a FIRST red call, page --critical and
  # freeze every merge lane — so the page that decided is read once more at the
  # same size and the arms run again on it. Only the same arm on the same
  # workflow and sha confirms. Anything else (a failed read, a stale page, a
  # different answer) decides nothing this tick; the next tick looks again.
  if [ -n "$WORST" ] && [ "$STALE_GUARD" != 0 ] \
     && [ -z "$( [ -f "$FLAG" ] && sed -n 's/^sha=//p' "$FLAG" | head -1)" ]; then
    FIRST=$(printf '%s\t%s' "$REASON" "$(cut -f3,5 <<<"$WORST")")
    CONFIRMED=""
    if ! mr_read_page "$SLUG" "$PAGE_N" || [ -z "$PG_RUNS" ] || [ "$PG_RUNS" = "[]" ]; then
      WHYNOT="the re-read returned no runs"
    elif mr_stale; then
      WHYNOT="the re-read answered a stale runs page — $STALE_WHY"
    else
      mr_floor_raise
      [ "$REASON" = queue ] && mr_queue_verdict "$SLUG"
      mr_arms "$(mr_verdicts "$PG_RUNS")"
      SECOND=$(printf '%s\t%s' "$REASON" "$(cut -f3,5 <<<"$WORST")")
      if [ -z "$WORST" ]; then WHYNOT="the re-read decided no freeze"
      elif [ "$SECOND" = "$FIRST" ]; then CONFIRMED=1
      else WHYNOT="the re-read decided $(tr '\t' ' ' <<<"$SECOND")"; fi
    fi
    if [ -z "$CONFIRMED" ]; then
      mr_verdict "$SLUG" none unconfirmed
      log "$SLUG: a freeze ($(tr '\t' ' ' <<<"$FIRST")) was not confirmed on a second read of the runs page — $WHYNOT — nothing decided, any existing flag left alone"
      continue
    fi
  fi
  # AN INFRA-ONLY RED IS RE-RUN, NOT RAISED (BH-2165, mr_infra_only above).
  # Only on the paths that would WRITE or REWRITE the flag: a flag already on
  # this sha is the still-red republish, and that self-heal stays untouched. A
  # flag on an older sha is left exactly as it is, since an infra failure says
  # nothing about whether the real red was fixed.
  INF_RAW=""
  if [ -n "$WORST" ] && [ "$INFRA_RERUN" != 0 ]; then
    IFS=$'\t' read -r _ _ _ INAME ISHA _ IURL IRID _ <<<"$WORST"
    if [ "$( [ -f "$FLAG" ] && sed -n 's/^sha=//p' "$FLAG" | head -1)" != "$ISHA" ] \
       && mr_infra_only "$SLUG" "$IRID"; then
      mr_infra "$SLUG" "$IRID" "$ISHA" "$INAME" "$IURL"
      continue
    fi
  fi
  if [ -n "$WORST" ]; then
    # Every column is named or thrown away EXPLICITLY, in order: the last
    # variable read assigns the REST of the line, so a column left off the end
    # is silently swallowed by the one before it — which is how REPOCH once
    # became "<epoch><tab><sha>" and the tip arm did arithmetic on it (BH-1281).
    # 11 is the in-flight sha (BH-1281), 12/13/14 the burst arm's (BH-1451),
    # 15 the hold-overrun arm's merge list (BH-1475) — and the trailing `_` is
    # what stops column 15 being swallowed into RTIP, which would put
    # "<tip-sha><tab><shalist>" in the burst arm's own `head=` flag field.
    IFS=$'\t' read -r _ RSTREAK RPATH RNAME RSHA RSINCE RURL RID _ REPOCH _ RDEPTH _ RTIP _ <<<"$WORST"
    mr_verdict "$SLUG" red "$REASON" "$RSHA"
    # The alert has to be true at a streak of one: "failed 1 runs in a row" is
    # neither English nor what happened.
    #
    # SHALBL is what the alert calls $RSHA, and on the burst and held-overrun
    # arms it is NOT the head — calling it one would make the alert point a
    # reader at a sha that has already been pushed over, which is the whole
    # thing those two arms are about.
    SHALBL=head
    # The two extra flag-body fields both of the behind-the-head arms write:
    # the sha they JUDGED stays `sha=`, and `head=`/`depth=` say which head it
    # is behind and by how much. Written through one variable so the flag has
    # one shape whichever of them fired.
    BURSTF=""
    if [ "$REASON" = tip ]; then
      HOW="failed on main's tip and has stood red for $(( (NOW - REPOCH) / 60 )) minutes with no re-run"
    elif [ "$REASON" = burst ]; then
      SHALBL=sha
      HOW="failed on main's newest COMPLETED run, $RDEPTH commit(s) behind head ${RTIP:0:8}, while that head still has required runs in flight"
      BURSTF=$(printf 'head=%s\ndepth=%s' "$RTIP" "$RDEPTH")
      log "$SLUG: burst back-walk decided on $RSHA ($RNAME), $RDEPTH commit(s) behind head $RTIP — that head's required runs are still in flight, so nothing newer can be judged"
    elif [ "$REASON" = queue ]; then
      SHALBL="batch sha"
      HOW="failed on $RSTREAK independent merge queue batches in a row with no green batch since — the queue tests every tree before it lands, so batches that share no PR all going red is main itself"
      # raised= is the episode's FIRST raise and survives a new-sha rewrite the
      # way since= does (a legacy flag's detected= stands in for it).
      QRAISED=""
      if [ -f "$FLAG" ] && [ -n "$(sed -n 's/^sha=//p' "$FLAG" | head -1)" ]; then
        QRAISED=$(sed -n 's/^raised=//p' "$FLAG" | head -1)
        [ -n "$QRAISED" ] || QRAISED=$(sed -n 's/^detected=//p' "$FLAG" | head -1)
      fi
      [ -n "$QRAISED" ] || QRAISED=$(STAMP)
      BURSTF=$(printf 'qred_t=%s\nqred_done=%s\nraised=%s' "$QRED_T" "$QRED_DONE" "$QRAISED")
    elif [ "$REASON" = held-overrun ]; then
      SHALBL=sha
      HOW="failed $RSTREAK runs in a row on main and $RDEPTH merge(s) landed on top of it while its re-test was still in flight"
      BURSTF=$(printf 'head=%s\ndepth=%s' "$RTIP" "$RDEPTH")
      log "$SLUG: hold ended after $RDEPTH merge(s) landed on main past ${RSHA:0:8} while its re-test was in flight ($RMERGES) — freezing on the held failure (BH-1475)"
    else
      HOW="failed $RSTREAK runs in a row on main"
    fi
    # The failing JOB, not just the workflow: "Harness CI is red" sends a reader
    # to a 4-job run; "the decisions job failed" sends them to the test.
    # The infra check above already read this run's jobs (BH-2165): name the
    # job from that body when it is jobs JSON, so a raise still costs one read.
    read_jobs() {
      local j
      if jq -e 'type=="object" and (.jobs|type)=="array"' <<<"$INF_RAW" >/dev/null 2>&1; then
        j=$(jq -r '[.jobs[] | select(.conclusion=="failure") | .name] | join(", ")' <<<"$INF_RAW" 2>/dev/null)
      else
        mr_count_read
        j=$(gh api "repos/$SLUG/actions/runs/$RID/jobs" \
          -q '[.jobs[]? | select(.conclusion=="failure") | .name] | join(", ")' 2>/dev/null)
      fi
      [ -n "$j" ] || j="(job list unavailable)"
      printf '%s' "$j"
    }
    # A FLAG WITH NO `sha=` IS NOT A DETECTOR VERDICT (BH-1451). Since this
    # build bin/main-red-pr-pair.sh can raise the same flag from PR evidence
    # alone (reason=pr-pair-suspected), and its body carries no sha= because
    # nobody had judged a run on main yet. When the detector then turns red on
    # that repo it is making its FIRST red call, so it takes the first-verdict
    # path below: the --critical "main is RED" page, and its own `since=`. The
    # new-sha branch would say "something landed on main and it did not fix
    # this" — nothing landed, and no fix was ever claimed.
    PSHA=""
    [ -f "$FLAG" ] && PSHA=$(sed -n 's/^sha=//p' "$FLAG" | head -1)
    if [ -n "$PSHA" ]; then
      # ONE LINE PER NEW RED SHA (BH-636), not one per episode. The flag's job is
      # to stop the same red paging every five minutes, and it did that by going
      # silent for the whole episode — so a main that stayed red across three
      # different shas, with a different job failing each time and two attempted
      # fixes that did not land, said nothing after the first line. A NEW sha is
      # new information: somebody pushed, and main is still red. It is NOT
      # critical — the episode already paged once, and what this adds is the
      # detail, not a second emergency. `since` keeps the ORIGINAL time: the
      # question a reader has is how long main has been broken, not how long this
      # particular sha has. The flag is rewritten BEFORE the send, so an alert
      # that dies costs one line rather than one per tick.
      if [ "$PSHA" = "$RSHA" ]; then
        # The republish is deliberate and is the whole resumability story: a PUT
        # that died on the tick main turned red would otherwise leave every box
        # unfrozen until the next sha. One idempotent write per red repo per
        # tick, and no second alert.
        mr_publish "$(basename "$FLAG")" on "main is red on ${RSHA:0:8} ($RNAME)"
        log "$SLUG: still red ($RNAME $HOW, $SHALBL ${RSHA:0:8}) — flag already set, no second alert"
        [ "$(sed -n 's/^reason=//p' "$FLAG" | head -1)" = queue ] && mr_queue_self_dispatch
        continue
      fi
      JOBS=$(read_jobs)
      WAS=$(sed -n 's/^since=//p' "$FLAG" | head -1)
      if [ "$EXPLAIN" = 1 ]; then
        log "WOULD UPDATE $(basename "$FLAG") sha=$RSHA workflow=$RNAME job=$JOBS since=${WAS:-$RSINCE} streak=$RSTREAK reason=$REASON${BURSTF:+ $(echo "$BURSTF" | tr '\n' ' ')}"
      else
        { echo "sha=$RSHA"; echo "workflow=$RNAME"; echo "path=$RPATH"; echo "job=$JOBS";
          echo "since=${WAS:-$RSINCE}"; echo "streak=$RSTREAK"; echo "run=$RURL"; echo "detected=$(STAMP)";
          echo "reason=$REASON"; [ -n "$BURSTF" ] && printf '%s\n' "$BURSTF"; } > "$FLAG"
      fi
      mr_publish "$(basename "$FLAG")" on "main is still red on a new sha ${RSHA:0:8} ($RNAME)"
      if [ "$REASON" = queue ]; then STILL="Another merge-queue batch tested directly on main went red."
      else STILL="Something landed on main and it did not fix this."; fi
      alert notice "$SLUG main is STILL RED on a new sha: \"$RNAME\" failed (job: $JOBS; $SHALBL ${RSHA:0:8}; red since ${WAS:-$RSINCE}). $STILL Merges for $SLUG stay frozen while $(basename "$FLAG") exists. $RURL"
      continue
    fi
    if [ -f "$FLAG" ]; then
      POWN=$(sed -n 's/^owner=//p' "$FLAG" | head -1)
      log "$SLUG: main's own history confirms a freeze that was already up (${POWN:-owner not recorded}, no sha judged) — this is the detector's first red call here, so it pages and takes the flag over"
    fi
    JOBS=$(read_jobs)
    if [ "$EXPLAIN" = 1 ]; then
      log "WOULD WRITE $(basename "$FLAG") sha=$RSHA workflow=$RNAME job=$JOBS since=$RSINCE streak=$RSTREAK reason=$REASON${BURSTF:+ $(echo "$BURSTF" | tr '\n' ' ')} — merges for $SLUG would be frozen"
    else
      { echo "sha=$RSHA"; echo "workflow=$RNAME"; echo "path=$RPATH"; echo "job=$JOBS";
        echo "since=$RSINCE"; echo "streak=$RSTREAK"; echo "run=$RURL"; echo "detected=$(STAMP)";
        echo "reason=$REASON"; [ -n "$BURSTF" ] && printf '%s\n' "$BURSTF"; } > "$FLAG"
    fi
    mr_publish "$(basename "$FLAG")" on "main is red on ${RSHA:0:8} ($RNAME, $REASON)"
    alert critical "$SLUG main is RED: \"$RNAME\" $HOW (job: $JOBS; $SHALBL ${RSHA:0:8}; red since $RSINCE). Every open PR on this repo inherits it, so a PR-level CI alert there is probably not that PR's fault. Merges for $SLUG are frozen while $(basename "$FLAG") exists — land the fix as a PR labelled $MRD_LABEL. $RURL"
  else
    GREEN=$(awk -F'\t' '$1=="green" {print; exit}' <<<"$VERDICTS")
    [ -n "$HELD" ] && IFS=$'\t' read -r _ HSTREAK _ HNAME _ _ _ _ _ _ HSHA _ <<<"$HELD"
    # NO ARM FIRED IS NOT THE SAME FACT TWICE (BH-1451). With something green in
    # hand this tick decided GREEN; with nothing green it decided NOTHING — a
    # red below the streak, on a sha nothing newer is pending behind, is a repo
    # this detector has looked at and cannot call. Writing green there would
    # tell bin/main-red-pr-pair.sh the question is settled in exactly the case
    # where its own evidence is the only evidence anybody has.
    #
    # AND A HELD TICK IS A FOURTH FACT, ahead of both (BH-1281 x BH-1451). The
    # hold above is this detector declining to raise on evidence a run now in
    # flight is about to replace. `none` would tell the pair lane nobody has
    # looked, and that lane's own trigger — open PRs failing alike — is the
    # normal state of a repo whose main has just been red, so it would raise its
    # sha-less freeze DURING the re-test; the next tick reads a flag with no
    # `sha=`, calls it its own first red, pages --critical and rewrites the
    # mtime bin/batch-resolve.sh's lift reads as "has a fix merged since". That
    # is the BH-1281 defect arriving one lane further out. `green` would be a
    # second lie: a sibling workflow being green is no claim about the held one.
    # The sha recorded is the RE-TEST being waited on, never a judgement.
    if   [ -n "$HELD" ];  then mr_verdict "$SLUG" held re-test "$HSHA"
    elif [ -z "$GREEN" ]; then mr_verdict "$SLUG" none below-streak
    else mr_verdict "$SLUG" green green "$(awk -F'\t' '$1=="green" {print $5; exit}' <<<"$VERDICTS")"; fi
    QTHAW=""
    if [ -f "$FLAG" ] && [ -z "$GREEN" ]; then
      # Below the streak but with nothing actually green (main broke again on its
      # first run after a fix): not a freeze yet, and certainly not a resolve.
      log "$SLUG: no required workflow is green and none is red $STREAK in a row — flag left as it is"
    elif [ -f "$FLAG" ] && [ "$(sed -n 's/^reason=//p' "$FLAG" | head -1)" = queue ] && mr_queue_holds; then
      # A QUEUE FREEZE CLEARS ONLY ON A GREEN BATCH NEWER THAN IT — or on a
      # green workflow_dispatch run of a required workflow on main newer than it,
      # which runs the full corpus on main itself: the way out when the queue is
      # empty and no batch will ever run. Main's own push runs are the fast
      # checks, green through any corpus failure, so they are no evidence; and a
      # queue that could not be read, or whose red batches merely scrolled off
      # the page, is "could not look", never "fixed".
      if type mrqt_clear_ok >/dev/null 2>&1; then
        log "$SLUG: the freeze was raised by the merge queue and bin/lib/main-red-queue-thaw.sh holds it${MRQT_WHY:+ — $MRQT_WHY} — flag left as it is"
      else
        log "$SLUG: the freeze was raised by the merge queue and no green batch newer than it has been seen (queue read: $QREAD) — flag left as it is"
      fi
      mr_queue_self_dispatch
    elif [ -f "$FLAG" ]; then
      IFS=$'\t' read -r _ _ _ GNAME GSHA _ GURL _ <<<"$GREEN"
      WAS=$(sed -n 's/^since=//p' "$FLAG" | head -1)
      [ -n "$QTHAW" ] && log "$SLUG: queue freeze thawed — $QTHAW"
      if [ "$EXPLAIN" = 1 ]; then log "WOULD CLEAR $(basename "$FLAG") — merges for $SLUG would be unfrozen"
      else rm -f "$FLAG"; fi
      mr_publish "$(basename "$FLAG")" off "main is green again on ${GSHA:0:8} ($GNAME)"
      alert resolve "$SLUG main is GREEN again: \"$GNAME\" passed on ${GSHA:0:8} (it was red since ${WAS:-unknown}). $(basename "$FLAG") cleared — merges for $SLUG are unfrozen. $GURL"
    else
      # THE OFF SIDE SELF-HEALS TOO. No file here means the clear already
      # happened; if the published marker is still there, the `off` PUT of that
      # clear died and the row is still ON for every box. Republish OFF until it
      # lands. No alert: the resolve already paged on the tick the file went.
      mr_marked "$(basename "$FLAG")"; MRC=$?
      if [ "$MRC" = 0 ]; then
        if mr_publish "$(basename "$FLAG")" off "main is green"; then
          log "$SLUG: main green — the row was still published ON from a clear whose PUT died; published OFF now"
        fi
      elif [ "$MRC" = 2 ] && [ "$EXPLAIN" != 1 ]; then
        log "$SLUG: main green — the published marker row is unreadable, so no OFF republish this tick (the next tick reads it again)"
      fi
      # A HELD STREAK IS NOT A GREEN MAIN. Saying "main green" here would be a
      # false line in the one log an operator reads to find out why no freeze
      # went up, so the hold names the workflow, the streak and the re-test.
      if [ -n "$HELD" ]; then
        # The `in flight on <sha>` substring is the BH-1281 suite's assertion and
        # stays byte-identical; what follows it is the operator's only warning
        # that a hold is running toward its bound (BH-1475). A disarmed arm
        # advertises no bound, because there is none.
        # And it is true in every state that renders it: an unreadable depth is
        # the one input that decides nothing above, so it must not be printed as
        # a number of merges either.
        HOLDEND=""
        case "$HOLD_OVER" in 0) ;; *)
          case "$HDEPTH" in
            ''|*[!0-9]*) HOLDEND="; how far main has moved past that sha is unreadable, so the hold stands" ;;
            *)           HOLDEND="; $HDEPTH merge(s) have landed on main since, the hold ends at $HOLD_OVER" ;;
          esac ;;
        esac
        log "$SLUG: \"$HNAME\" failed $HSTREAK runs in a row on main but a newer run of it is in flight on ${HSHA:0:8} — a re-test is under way, freeze not raised on top of it (BH-1281)$HOLDEND"
      else
        log "$SLUG: main green ($(awk -F'\t' '$1=="green"' <<<"$VERDICTS" | wc -l | tr -d ' ') required workflow(s))"
      fi
    fi
  fi
  command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset
done
command -v gh_default_auth_reset >/dev/null 2>&1 && gh_default_auth_reset
command -v gh_repo_token_reset >/dev/null 2>&1 && gh_repo_token_reset
exit 0
