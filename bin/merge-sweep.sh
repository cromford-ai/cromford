#!/bin/bash
# bin/merge-sweep.sh — hub cron (*/10): merge reviewed harness PRs promptly
# (the reviewed-merge sweep).
#
# Authorized by the operator 2026-08-17 ("the hub should be able to merge by itself",
# after TK-124/#319): tier 2 is a recorded risk class. It means the BUILD
# session does not merge its own PR, not that a reviewed-and-approved PR should
# age. Dwell time is where conflicts breed — #316 sat 30h and its shadow killed
# #318. This sweep gives tier-2 PRs the same double-gate treatment tier-1 gets,
# minus none of the rails:
#
#   merge IFF  the VERDICT is APPROVE                    (Fable's judgment)
#         AND  the review was served by the primary lane   (cheap-lane APPROVE
#              never auto-merges — same rule as the tier-1 gate)
#              Both read from the jobs ledger (phase 7: bin/run-build.sh records
#              them as artifacts on the claim) when a row exists for this PR,
#              and from review.md + pipeline.log when it does not. An empty
#              ledger leaves this sweep byte-identical to phase 6. A ledger that
#              CONTRADICTS the record parks the PR — two copies of one judgement
#              that disagree is a human's question, not a tie to break.
#         AND  the PR's head IS the head the review approved   (SDLC item 1)
#              bin/run-build.sh records the reviewed sha on the verdict row
#              (fallback: the build record's reviewed-sha file, written by the
#              gate itself); a head that has
#              moved since carries code no reviewer and no suite ever saw, so it
#              is parked for bin/blocked-resolver.sh — NOT ledgered, because a re-review,
#              a rebind by bin/rebase-train.sh or HEADBOUND_ENFORCE=0 all undo
#              it. Absent reviewed sha = no claim = the old behavior, and
#              HEADBOUND_ENFORCE=0 downgrades the park to a log line AND sends
#              the merge PUT unbound (no sha), so the switch merges rather than
#              collecting a 409 from the very head it waved through.
#         AND  no REBASE_CONFLICT/REBASE_VERIFY_FAILED/REBASE_VERIFY_INCONCLUSIVE
#              note in RESULT (BH-575: a verify typecheck that CRASHED writes
#              INCONCLUSIVE instead of FAILED, and parks the PR the same way —
#              an unverified rebase is not a verified one)
#         AND  gh says OPEN + mergeStateStatus CLEAN     (never red/unknown)
#         AND  the added-lines scan finds none of the iron-law red flags
#              (native dialogs, hardcoded claude-* model strings, VERCEL_URL
#              self-fetch) — a hit parks the PR for bin/blocked-resolver.sh to
#              ADJUDICATE (one Fable call over the flagged lines; ACCEPT writes
#              an ironlaw-head-accept row in the jobs DB, which this sweep honors)
#         AND  flags/automerge-disabled is absent        (the kill switch)
#         AND  this repo's REVIEW GATE is not tightened   (SDLC item 2)
#              bin/review-tighten.sh parks a repo whose trailing-window
#              revert/reopen rate crossed the threshold; a parked repo's PRs
#              are SKIPPED here, not ledgered, so they land the moment the
#              rate comes back down or the operator merges them by judgement.
#
# MIGRATION-GATED results merge too (apply comes AFTER the merge deploys, per
# standing policy) — but the sweep never applies SQL itself. Allowlisted
# migration SQL is auto-applied post-deploy by bin/migration-autopilot.sh
# (trust-5); a MIGRATION GATE marker means classifier-FLAGGED SQL, which the
# autopilot never touches — the ALERT names exactly those files for the
# orchestrator's judged apply through the app's own migrations endpoint. That
# one gate genuinely is not an agent's to take: no box holds prod DB credentials
# (the operator, 2026-07-24), so the apply can only go through the app.
# Ledger: harness-jobs ledgers table (kind=merge, key=PR url) with
# state/merge-sweep-done.txt as write-through fallback. Cap SWEEP_MERGE_BUDGET
# merges/run (default 5); the walk is BH-710's round-robin across projects.
# Reads fail CLOSED: if the DB is unreachable we consult the file, never
# treat a transport failure as "not yet merged". A worker outage must not
# cause a double merge.
#
# THE WALK (BH-710, 2026-09-17). Until this landed the whole scheduling policy
# was `for D in "$H"/builds/pool-*-*/ "$H"/builds/*-*/`: it visited every pool-*
# record TWICE (pool-*-* is a subset of *-*), it ordered by the shell's
# alphabetical glob so one project's tail sat in front of every later project,
# and it had no memory between runs, so a refusal decided entirely from the
# build record was re-derived every ten minutes — 3,513 identical "ledger
# provenance is" lines while #693-#707 had never been looked at at all. Now:
#   * sweep_order() walks each record ONCE, round-robin across projects
#     (buckets from bin/fleet-conf.sh, never a list in this file), newest
#     RESULT first inside a project, so a PR built at 20:11Z is looked at in
#     the 20:16Z tick. No find, or an empty stream, falls back to the old glob.
#   * state/merge-sweep-terminal.txt caches the five refusals whose cause is a
#     static property of the record — no APPROVE, ledger verdict, ledger
#     provenance, judge provenance, recorded E2E FAIL — keyed on the PR plus a
#     fingerprint (mtime+size) of RESULT/review.md/pipeline.log/e2e.md/
#     reviewed-sha. Touch any of those and the entry is gone and the record is
#     re-evaluated. RETRYABLE skips (UNSTABLE, head-bound park, TIGHTENED gate,
#     rebase park, pre-arm rc 3, invisible repo, queue hand-off) are NEVER
#     cached: each flips with no change to the record. Entries re-log their
#     reason line once a day (SWEEP_TERMINAL_RELOG_SECS) so
#     bin/pipeline-health.sh:344's `grep -F "$PR" merge-sweep.log` still finds
#     an explanation, and age out after SWEEP_TERMINAL_TTL_SECS (7d). The file
#     is pure cache: delete it and the sweep does one expensive tick and
#     converges.
#   * SWEEP_DEADLINE_SECS (540, under the */10 tick) bounds the walk, because
#     flock -n above means a tick that overruns silently eats the next ones.
#   * one summary line per project per tick, plus a fleet total — no PR URL on
#     them, so pipeline-health's per-PR grep is unaffected.
set -uo pipefail
# Overridable so tests can drive this sweep against a scratch tree. Cron
# never sets it, so production resolves to exactly the path it always has.
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-merge-sweep
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off merge-sweep.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
# The ONE verdict reader (bin/lib/verdict-parse.sh, BH-1625). Missing, every
# verdict reads unknown — never APPROVE.
. "${HARNESS:-/root/harness}/bin/lib/verdict-parse.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/lib/verdict-parse.sh" 2>/dev/null || true
# Where a project keeps its migration SQL (migrations_glob.<project>), for the
# MIGRATION GATE alert. Missing, the alert names scripts/migrations as before.
. "${HARNESS:-/root/harness}/bin/lib/migrations-glob.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/lib/migrations-glob.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit merge-sweep
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    merge-sweep
command -v verdict_prime >/dev/null 2>&1 && verdict_prime || true
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
LOG="$H/logs/merge-sweep.log"
DONE="$H/state/merge-sweep-done.txt"; mkdir -p "$H/state" "$H/logs" "$H/locks"; touch "$DONE"
# One ALERT per (PR, head) for the head-bound park below. The park itself is
# never ledgered (it is reversible — see the gate), so without this the sweep
# would page every ten minutes for as long as the PR sat there.
HBALERT="$H/state/headbound-alerted.txt"; touch "$HBALERT"
# >>> sweep modules (BH-5242)
# bin/lib/ms/ holds the sweep's helper modules, loaded through the module map
# (bin/lib/ms/load.sh). The copy next to this script is tried first, because
# the fixtures copy this script into a scratch bin/; then $H/bin/lib/ms. A
# module that is missing or unusable REFUSES the tick: a box mid-sync can see
# this script new and bin/lib/ms/ missing, and a sweep without its helpers
# would fail on the first record instead of saying why.
MS_LIB_DIR="$(dirname "$0")/lib/ms"; [ -r "$MS_LIB_DIR/load.sh" ] || MS_LIB_DIR="$H/bin/lib/ms"
# shellcheck source=bin/lib/ms/load.sh
if ! . "$MS_LIB_DIR/load.sh"; then
  HARNESS="$H" "$H/bin/alert-line.sh" "SWEEP MODULE MISSING: bin/lib/ms/ is missing or unusable on $(hostname) — the box's bin/ is half-synced; no PR was swept this tick" 2>/dev/null || true
  echo "$(STAMP) [merge-sweep] bin/lib/ms/ is missing or unusable — refusing the tick" >> "$LOG"
  exit 1
fi
# <<< sweep modules

# HARNESS_SECRET lives in global.env; cron does not source it for us. Sourced
# BEFORE the kill-switch test now, because that test is the flag lookup and the
# flag lookup wants the client.
if [ -f "$HENV/global.env" ]; then set -a; # shellcheck disable=SC1091
  . "$HENV/global.env"; set +a; fi
# AND AGAIN, BELOW THE ENV LOAD (BH-1165 review). `set -a; . env/global.env`
# re-assigns every name it carries, so the call above lost each knob the box's
# env file also sets — the settings row was gone, the page went on reporting
# `source: settings`, and nothing errored: the exact shape this ticket exists to
# end. The call above still earns its place: the knobs this lane reads BEFORE
# this line have no other way to see a row. Applying twice is idempotent (the
# settings cache is already warm) and section 16 of tests/lanes-registry-test.sh
# is the ordering.
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    merge-sweep
# --- Merge budget (BH-778) ---------------------------------------------------
# Max VERIFIED merges per pass, fleet-wide. SWEEP_MERGE_BUDGET overrides the
# default of 5, from the process env or env/global.env — which is why it is read
# HERE and not above the source. The budget is consumed only by a MERGED state:
# a skip, a park, an enqueue and a failed attempt all cost nothing. Not an
# integer -> say so and use the default; a typo in global.env must not turn
# fleet-wide merging off, and must not turn it unlimited either. The ORDER the
# budget is spent in is sweep_order() below (BH-710): round-robin across
# projects, newest record first inside one.
BUDGET_DEFAULT=5
BUDGET="${SWEEP_MERGE_BUDGET:-$BUDGET_DEFAULT}"
case "$BUDGET" in ''|*[!0-9]*)
  echo "$(STAMP) SWEEP_MERGE_BUDGET='$BUDGET' is not a non-negative integer — using the default $BUDGET_DEFAULT" >> "$LOG"
  BUDGET=$BUDGET_DEFAULT ;;
esac
if [ -n "${SWEEP_MERGE_BUDGET+x}" ]; then BUDGET_SRC="SWEEP_MERGE_BUDGET=$SWEEP_MERGE_BUDGET"
else BUDGET_SRC="SWEEP_MERGE_BUDGET unset"; fi
BUDGET_EFF=$BUDGET; SWEEP_BUDGET_MERGED=0; SWEEP_BUDGET_LOGGED=""
if [ -f "$H/bin/jobs-client.sh" ]; then # shellcheck source=/dev/null
  . "$H/bin/jobs-client.sh"; fi
# Carry an iron-law acceptance across heads (BH-4474). Missing, ilc_covered is
# undefined and the per-head marker is the only acceptance, as before.
# shellcheck source=bin/lib/ironlaw-carry.sh
[ -r "$H/bin/lib/ironlaw-carry.sh" ] && . "$H/bin/lib/ironlaw-carry.sh"
# The builds of record, read from the ledger (BH-2348). A tree without the lib
# has no bor_union, and sweep_order() then walks builds/*/RESULT as it always did.
# shellcheck source=bin/lib/builds-of-record.sh
[ -r "$H/bin/lib/builds-of-record.sh" ] && . "$H/bin/lib/builds-of-record.sh"
# One owner per ticket (BH-1526): the merge-time HOLD and one-PR-per-ticket.
# shellcheck source=bin/lib/ticket-ownership.sh
[ -r "$H/bin/lib/ticket-ownership.sh" ] && . "$H/bin/lib/ticket-ownership.sh"
# GitHub's NATIVE merge queue changes what `gh pr merge` MEANS on a repo (it
# enqueues and exits 0, the PR stays open), so this sweep has to know. The probe
# lives in the conductor's lib — sourced, not copied, because a second copy of
# "does this repo have a queue" that drifted would be a silent double-merge.
# A tree without the lib (an old box mid-rollout, a fixture that copies only
# this script) answers "no queue", which is exactly today's behaviour.
#
# EVERY DECISION READ IN THIS FILE GOES THROUGH THAT LIB'S REST HELPERS (BH-784)
# — rc 0 acted on, 44 ABSENT, 75 UNVERIFIABLE (#768). The marker below is what
# tests/gh-no-graphql-decision-guard-test.sh scans this file for. On a tree
# WITHOUT the lib the shims answer 75, and every gate here reads that as "skip
# this record" — the fail-closed side, and the same shape merge-queue.sh takes.
# shellcheck source=bin/lib/merge-conductor-lib.sh
# gh-rest: no-graphql
if [ -r "$H/bin/lib/merge-conductor-lib.sh" ]; then . "$H/bin/lib/merge-conductor-lib.sh"
else mc_queue_enabled() { return 1; }; mc_queue_conductor_only() { return 1; }; mc_pr_queued() { return 1; }
     mc_closed_settled() { return 0; }
     mc_pr_view() { return 75; }; mc_pr_diff() { return 75; }; mc_rest_pages() { return 75; }
     mc_rest_status() { printf '?'; }
     # The close-out shim DEFERS rather than pretends: a lib-less tree cannot
     # verify a close, and this sweep now writes the done-marker only after a
     # verified one. `close-failed` is the word the close-out logs and the
     # `issue-close-owed` marker is what the next pass picks up.
     mc_close_shipped() { printf 'close-failed\n'; return 1; }; fi
# BH-1575: the per-PR reads — one memoised pulls/N read in THIS shell (so a
# failed read logs its own status), a cache-miss 304 re-asked instead of
# skipped, pulls/N/commits only for a head not seen before, and no read at all
# while merge-conductor's pr-state.tsv is fresh and says it holds the PR. A tree
# without the lib keeps every read below exactly as it was.
# shellcheck source=bin/lib/sweep-reads.sh
[ -r "$H/bin/lib/sweep-reads.sh" ] && . "$H/bin/lib/sweep-reads.sh"
# BH-1684: pauses (BH-1672) — a live `merges` row for this PR's project or for
# the fleet stops the merge call below. A tree without the lib is never paused,
# which is exactly today's behaviour.
# shellcheck source=bin/lib/pause.sh
if [ -r "$H/bin/lib/pause.sh" ]; then . "$H/bin/lib/pause.sh"
else pause_active() { return 1; }; pause_label() { :; }; pause_refresh() { return 0; }
     pause_env_shapes() { :; }; fi
SWEEP_PRS_FILE="$H/state/merge-conductor/pr-state.tsv"   # the conductor's; read-only here
SWEEP_HEADS="$H/state/merge-sweep-heads.tsv"              # <pr> <head> <head commit date>
# sweep_custody — rc 0 when a FRESH conductor row (its project's last tick
# finished inside the knob and saw PRs) is in a state STRICTER than this sweep's
# own gates (see sweep_prstate_custody — WAIT_CI, RED_TWICE, WAIT_REVIEW,
# HEAD_MOVED and BLOCKED_HUMAN are read live, because this sweep can merge
# through them): the skip is logged, nothing is recorded, and the next
# tick asks again. SWEEP_PRS_FRESH_S is the knob (catalog/lanes.d,
# required, 0 = off); empty or unset answers "no row" and GitHub is read.
sweep_custody() {
  command -v sweep_prstate_read >/dev/null 2>&1 || return 1
  sweep_prstate_read "$PR" "$SWEEP_PRS_FILE" "${SWEEP_PRS_FRESH_S:-}" || return 1
  sweep_prstate_custody "$SWEEP_PRS_STATE" || return 1
  echo "$(STAMP) $PR skipped: the merge conductor holds it $SWEEP_PRS_STATE on ${SWEEP_PRS_HEAD:0:8} (pr-state.tsv, its project's conductor tick ${SWEEP_PRS_AGE}s old) — no GitHub read, re-offered next tick" >> "$LOG"
  return 0
}
# Judge provenance rides on that lib (bin/lib/review-provenance.sh). Without it,
# the literal `claude` is the only primary word — this script's original rule.
type rp_prov_is_claude >/dev/null 2>&1 || rp_prov_is_claude() { [ "${1:-}" = claude ]; }
# The Actions reads below (the rebase-note supersede, the project-4 E2E discount, the
# green-run discount) go through bin/lib/gh-ci-read.sh: the default token first,
# and ONLY when it 403s — a fine-grained PAT that cannot see actions/runs, the
# 2026-09-14 project-2 shape — a read-only App token. Without the lib it is a
# plain `gh api`, which is exactly the read this sweep has always done — and
# since BH-1575 a gh_rest read (ledgered, ETag-conditional) when this tree has
# bin/lib/sweep-reads.sh.
# shellcheck source=bin/lib/gh-ci-read.sh
if [ -r "$H/bin/lib/gh-ci-read.sh" ]; then . "$H/bin/lib/gh-ci-read.sh"
elif command -v sweep_ci_rest >/dev/null 2>&1; then gh_ci_api() { sweep_ci_rest "$@"; }
else gh_ci_api() { shift; gh api "$@"; }; fi
# The MERGE itself goes over REST (BH-892). `gh pr merge` is a GraphQL mutation,
# and on 2026-09-18 the PAT's GraphQL bucket was empty while the REST one was
# fine — the sweep parked CLEAN, APPROVEd PRs as "merge FAILED" on a budget that
# says nothing about whether they could merge. Guarded: a tree without the lib
# (an old box mid-rollout, a fixture that copies only this script) runs the
# `gh pr merge` line below exactly as it always has.
# shellcheck source=bin/lib/gh-pr-merge.sh
[ -r "$H/bin/lib/gh-pr-merge.sh" ] && . "$H/bin/lib/gh-pr-merge.sh"

# --- Token routing per repo (2026-09-12, the #251 lesson, second consumer) ---
# The hub's default gh auth does not reach every repo the pool builds for
# (example-org/project-5 and project-7 404 on it). `mc_pr_view` below then
# answers nothing, PSTATE is empty, and the PR is silently `continue`d — every
# project-5 tier-2 APPROVE (six PRs on 2026-09-12 alone) sat open with nobody
# sweeping it while its Blocked-by children waited on the merge. When the
# default auth cannot see a PR's repo and env/github-admin.env holds the
# org-admin token, this iteration's gh calls run on that token instead, and
# after that a GitHub App installation token from bin/gh-token.sh (BH-796).
# The answer is cached per repo for the run; with neither an admin token nor an
# armed App the sweep behaves exactly as before.
# WHOSE PRs ARE OURS (2026-09-14). A PR opened on a GitHub App installation
# token is authored by the App (`app/cromford`, or `cromford[bot]` in
# REST), not by the PAT's owner, so the literal `operator` the author gate below
# used to carry stopped matching the moment bin/gh-token.sh went live. The set lives in
# bin/lib/gh-pr-list.sh; the shim below is this script's own copy of it for the
# same reason the token probe above is inline — the fixtures copy this script
# standalone into a scratch tree with no bin/lib beside it.
# shellcheck source=bin/lib/gh-pr-list.sh
for _P in "$(dirname "$0")/lib/gh-pr-list.sh" "$H/bin/lib/gh-pr-list.sh"; do
  # shellcheck source=/dev/null
  [ -r "$_P" ] && { . "$_P"; break; }
done
# WHICH IDENTITY IS ABOUT TO PUSH (BH-800, 2026-09-18). `mergeState=BLOCKED` on
# a branch that gates nothing is not a PR that is not ready — it is GitHub
# saying this token may not push there. bin/lib/gh-push-identity.sh owns that
# judgement for both merge lanes; a tree without it (an old box, a fixture that
# copies only this script) writes exactly the line it always did.
# shellcheck source=bin/lib/gh-push-identity.sh
for _P in "$(dirname "$0")/lib/gh-push-identity.sh" "$H/bin/lib/gh-push-identity.sh"; do
  # shellcheck source=/dev/null
  [ -r "$_P" ] && { . "$_P"; break; }
done
declare -A SWEEP_IDV   # (repo, base) -> "<verdict>\t<identity>\t<allow-list>"
command -v harness_pr_author_match >/dev/null 2>&1 || harness_pr_author_match() {
  local l="${1#app/}"; l="${l%\[bot\]}"
  case " ${HARNESS_PR_AUTHORS:-${HARNESS_OPERATOR_LOGIN:-} app/cromford app/cromford-builders app/cromford-board} " in *" $l "*|*" app/$l "*) return 0 ;; esac
  return 1; }

# >>> sweep token routing
# The two identity libs are found the way gh-pr-list.sh above is found: next to
# this script first (the fixtures copy it standalone), then the harness root.
# Both stay INERT on a box with no env/github-app.env — gh_auth_armed is false
# there, so the sweep makes exactly the calls it always did.
for _GHL in gh-app-auth.sh gh-limit-logger.sh; do
  for _P in "$(dirname "$0")/lib/$_GHL" "$H/bin/lib/$_GHL"; do
    # shellcheck source=/dev/null
    [ -r "$_P" ] && { . "$_P"; break; }
  done
done
_SWEEP_ADMIN_TOK=$(sed -n 's/^\(export \)\{0,1\}GH_ADMIN_TOKEN=//p' "$HENV/github-admin.env" 2>/dev/null | tr -d "\"'" | head -n 1)
_SWEEP_DEFAULT_TOK="${GH_TOKEN:-}"
declare -A _SWEEP_REPO_TOK _SWEEP_APP_TOK _SWEEP_REPO_WHY
# A 403 IS NOT A 404 (2026-09-18, BH-796). The probe used to read gh's EXIT CODE
# and nothing else, so `gh: You have exceeded a secondary rate limit … (HTTP 403)`
# and `gh: Not Found (HTTP 404)` were the same answer — rc 1 — and a rate limit
# was recorded as "no token on this box can see this repo". On the hub between
# 03:55 and 04:00Z that verdict wrote 238 of 400 merge-sweep.log lines, fired the
# invisible-repo page, and skipped every approved PR while merged-to-main sat
# flat at 24. The status gh prints is the classification; rc only says "not ok".
#
# `gh api rate_limit` is NOT consulted here and must not be. During that outage
# it read core 5000/5000. Secondary limits (the concurrency/burst kind) do not
# appear in that endpoint at all, so a green rate_limit is not evidence that the
# 403 in front of us is anything else.
_sweep_probe_class() { # _sweep_probe_class <owner/repo> [token] -> ok|invisible|transient
  local slug="$1" tok="${2-}" out rc st
  # BH-1575: the same classification through gh_rest (ledgered, ETag), when
  # this tree has the lib. The raw read below is the lib-less tree's.
  if command -v sweep_probe_class_rest >/dev/null 2>&1; then
    sweep_probe_class_rest "$slug" "$tok"; return 0
  fi
  if [ -n "$tok" ]; then out=$(GH_TOKEN="$tok" gh api "repos/$slug" -q .id 2>&1); rc=$?
  else out=$(env -u GH_TOKEN gh api "repos/$slug" -q .id 2>&1); rc=$?
  fi
  [ "$rc" -eq 0 ] && { printf 'ok\n'; return 0; }
  st=$(sed -nE 's/.*\(HTTP ([0-9]{3})\).*/\1/p' <<<"$out" | head -1)
  # Older gh prints the API body and no `(HTTP nnn)` line; the body carries it.
  [ -n "$st" ] || st=$(sed -nE 's/.*"status"[[:space:]]*:[[:space:]]*"?([0-9]{3}).*/\1/p' <<<"$out" | head -1)
  case "$st" in
    404|401) printf 'invisible\n' ;;   # gone, or a dead credential: both actionable
    403) if grep -qiE 'rate limit|secondary rate|abuse detection' <<<"$out"; then printf 'transient\n'
         else printf 'invisible\n'; fi ;;   # "Resource not accessible", "Must have admin rights"
    429|5??) printf 'transient\n' ;;
    # No status at all — a network error, a gh that is not authenticated, a
    # killed process. That is weather, not evidence that nobody can see the
    # repo, so it defers and the next tick asks again.
    *) printf 'transient\n' ;;
  esac
}
# THE LADDER: default PAT, then the admin PAT, then a GitHub App installation
# token scoped to this one repo (bin/gh-token.sh). The App rung is third and
# lazy — it is a mint, and a repo either PAT can see never spends one.
#
# The cache is filled in the CALLER's shell, never inside a $(...) — that was
# the second half of the defect and bin/lib/gh-repo-token.sh:41-48 documents it
# for its own copy: a subshell-filled associative array dies with the subshell,
# so "cached per repo for the run" was never true and every PR re-probed.
# Rung 1 is pinned to the DEFAULT token for the same reason the lib pins it: a
# previous iteration exported the admin (or App) token, and an unpinned rung 1
# would measure the wrong credential and then label the answer "default".
_sweep_probe() { # _sweep_probe <owner/repo> -> fills _SWEEP_REPO_TOK[slug] in THIS shell
  local slug="$1" cdef cadm capp tok
  [ -n "${_SWEEP_REPO_TOK[$slug]+x}" ] && return 0
  cadm=absent; capp=absent
  cdef=$(_sweep_probe_class "$slug" "$_SWEEP_DEFAULT_TOK")
  if [ "$cdef" = ok ]; then _SWEEP_REPO_TOK[$slug]="default"
  else
    [ -n "$_SWEEP_ADMIN_TOK" ] && cadm=$(_sweep_probe_class "$slug" "$_SWEEP_ADMIN_TOK")
    if [ "$cadm" = ok ]; then _SWEEP_REPO_TOK[$slug]="admin"
    else
      if [ -x "$H/bin/gh-token.sh" ]; then
        # A plain mint, not --read: this sweep merges, comments and closes, so
        # it must honour the write kill switches --read deliberately bypasses.
        # Unarmed (or a failed mint) makes gh-token.sh print the PAT we already
        # tried, so an answer equal to one of them is "no App token here" and
        # costs no extra request.
        capp=unavailable
        tok=$(GH_TOKEN="$_SWEEP_DEFAULT_TOK" "$H/bin/gh-token.sh" "$slug" 2>/dev/null | head -n 1)
        if [ -n "$tok" ] && [ "$tok" != "$_SWEEP_DEFAULT_TOK" ] && [ "$tok" != "$_SWEEP_ADMIN_TOK" ]; then
          capp=$(_sweep_probe_class "$slug" "$tok")
          [ "$capp" = ok ] && _SWEEP_APP_TOK[$slug]="$tok"
        fi
      fi
      if [ "$capp" = ok ]; then _SWEEP_REPO_TOK[$slug]="app"
      elif [ "$cdef" = transient ] || [ "$cadm" = transient ] || [ "$capp" = transient ]; then
        # One rung answering "weather" is enough: we cannot claim no token can
        # see this repo when one of them never got to answer the question.
        _SWEEP_REPO_TOK[$slug]="transient"
      else _SWEEP_REPO_TOK[$slug]="none"; fi
    fi
  fi
  _SWEEP_REPO_WHY[$slug]="default=$cdef admin=$cadm app=$capp"
}
sweep_token_for() { # sweep_token_for <owner/repo> — prints default|admin|app|transient|none
  _sweep_probe "$1"; printf '%s\n' "${_SWEEP_REPO_TOK[$1]}"
}
# A repo NO token can see is an ALERT, never a quiet `continue` (2026-09-12, the
# 10-hour project-5 loss): before #254 this sweep 404'd on every project-5 PR
# for days and its log carried not one line about them. rc 1 here, and the
# caller logs the skip; the page itself is deduped per (repo, day) so a repo
# that stays invisible pages once a day, not once a tick. Token VALUES never
# reach a log — only the words default/admin.
SWEEP_INVIS="$H/flags"
# WHICH CREDENTIAL ANSWERED, said once per tick per repo (BH-597, ticket item 2).
# The WORDS app/default/admin and nothing else: a token value in a log is the
# leak, and this file is read by anyone debugging a merge.
declare -A _SWEEP_AUTH_SAID
sweep_auth_log() { # sweep_auth_log <owner/repo> <human words>
  [ -n "${_SWEEP_AUTH_SAID[$1]+x}" ] && return 0
  _SWEEP_AUTH_SAID[$1]=1
  echo "$(STAMP) github auth: $2 for $1" >> "$LOG"
}
sweep_use_token_for() { # sweep_use_token_for <owner/repo> — exports GH_TOKEN for this iteration; rc 2 = transient (defer), rc 1 = no token can see the repo
  # A repo-scoped App token first (#469). A token that MINTED is proof the App
  # can see the repo, so the ladder below gets no vote on it and spends no probe
  # call. Anything else (unarmed box, App not installed on this repo, a failed
  # mint that answers the PAT) restores this run's own default token and falls
  # into the existing probe/admin/app/transient ladder COMPLETELY unchanged —
  # BH-796's rc 2 and its invisible-repo page included. gh_default_auth_for_slug
  # resets the previous repo's token before minting (never carries repo A's
  # token into repo B's probe below).
  if command -v gh_default_auth_for_slug >/dev/null 2>&1; then
    if gh_default_auth_for_slug "$1"; then
      case "${GH_TOKEN:-}" in ghs_*) sweep_auth_log "$1" "App installation token"; return 0 ;; esac
    fi
    if [ -n "$_SWEEP_DEFAULT_TOK" ]; then export GH_TOKEN="$_SWEEP_DEFAULT_TOK"; else unset GH_TOKEN; fi
  fi
  # _sweep_probe IN THIS SHELL, not `how=$(sweep_token_for …)`: the probe's
  # answers live in _SWEEP_REPO_TOK / _SWEEP_APP_TOK / _SWEEP_REPO_WHY, and a
  # command substitution populates them in a subshell that then exits. The
  # caller's transient branch reads _SWEEP_REPO_WHY[$slug] by name under
  # `set -u`, so a subshell probe makes every deferral an unbound-variable
  # death instead of a logged retry (BH-796's whole point).
  _sweep_probe "$1"
  local how="${_SWEEP_REPO_TOK[$1]}"
  if [ "$how" = admin ]; then export GH_TOKEN="$_SWEEP_ADMIN_TOK"; sweep_auth_log "$1" "admin PAT"; return 0; fi
  if [ "$how" = app ]; then export GH_TOKEN="${_SWEEP_APP_TOK[$1]}"; sweep_auth_log "$1" "App installation token"; return 0; fi
  if [ -n "$_SWEEP_DEFAULT_TOK" ]; then export GH_TOKEN="$_SWEEP_DEFAULT_TOK"; else unset GH_TOKEN; fi
  # Weather is not a page. The PR is deferred by the caller and re-offered on the
  # next */10 tick, when the ladder probes again (the cache dies with the run).
  [ "$how" = transient ] && return 2
  [ "$how" = none ] || { sweep_auth_log "$1" "default PAT"; return 0; }
  local flag="$SWEEP_INVIS/alerted-repo-invisible-merge-sweep-${1//\//_}-$(date -u +%Y%m%d)" adminw
  if [ ! -f "$flag" ]; then
    mkdir -p "$SWEEP_INVIS" 2>/dev/null; touch "$flag"
    if [ -n "$_SWEEP_ADMIN_TOK" ]; then adminw="the admin token cannot see it either"; else adminw="no admin token on this box (env/github-admin.env absent)"; fi
    HARNESS="$H" "$H/bin/alert-line.sh" "[merge-sweep] repo $1 is INVISIBLE to the default gh token ($adminw) — its approved PRs are SKIPPED, not swept. This is the 2026-09-12 project-5 shape: an empty loop nobody logged."
    "$H/bin/beat.sh" "$(jq -nc --arg akey "repoinvisible:merge-sweep:$1" --arg l "[merge-sweep] repo $1 is INVISIBLE to the default gh token ($adminw) — its approved PRs are skipped, not swept" \
      '{kind:"fleet_alert",project:"fleet",akey:$akey,line:$l}')" >/dev/null 2>&1 || true
  fi
  return 1
}
# <<< sweep token routing

# flag_active reads automerge-disabled as a harness_flags ROW (BH-4153): a
# console pause reaches this sweep, a worker outage answers from the box's
# last good read, and with nothing cached it reads as ON (a stop switch fails
# closed). A 404 on the flag is "no row", never "unpause" — and with no client
# at all this falls back to the bare file test it has always done.
if command -v flag_active >/dev/null 2>&1; then
  flag_active automerge-disabled && exit 0
else
  [ -f "$H/flags/automerge-disabled" ] && exit 0
fi
# One board's toggle (#2322) is read per PR, below: flag_active when the client
# is loaded, the file otherwise.
ms_project_am_off() {
  if command -v flag_active >/dev/null 2>&1; then flag_active "automerge-disabled-$1"
  else [ -f "$H/flags/automerge-disabled-$1" ]; fi
}
exec 9>"$H/locks/merge-sweep.lock"; flock -n 9 || exit 0
# Once per run, under the lock (BH-1684). A failed refresh keeps the cache it
# had, and no cache reads as "not paused".
pause_refresh || true
# BH-1295 REVIEW FIX (F1, round 2): armed BEFORE any gh_rest GET runs — see
# reconcile-prs.sh's copy of this comment for why an unarmed tick counts
# nothing rather than leaking a file.
# BH-1322: under the box's state dir now, not $TMPDIR. The removal on exit
# rides the EXIT trap this lane ALREADY has (_sweep_finish below) rather than a
# second `trap … EXIT`, which would replace it and drop the job-lane close.
export GH_ETAG_COUNT_FILE="$H/state/gh-etag/counts/merge-sweep.$$"

# --- Coordination row (phase 4) ----------------------------------------------
# LAZY CLAIM, and the laziness is the design. This sweep runs every ten minutes
# on the hub and does nothing on the overwhelming majority of ticks; opening a
# row per tick would put ~144 empty rows a day on the console's JOBS screen and
# give bin/jobs-watchdog.sh 144 more things to age. The window that actually
# needs evidence is the one around `gh pr merge` — a kill there leaves a PR
# whose merge state nobody wrote down. So the row opens the first time this run
# commits to a real merge attempt, beats for the rest of the run, and closes
# with the run's real rc. Fail-open throughout: no worker, no row, no change.
#
# Spend stays 0 on this lane and that is honest, not missing: merge-sweep makes
# no LLM calls at all. Its cost is wall-clock and gh API, neither of which this
# table meters.
SWEEP_RC=0
sweep_claim() {   # idempotent: the second and later merges of a run reuse the row
  [ -n "${JOB_ID:-}" ] && return 0
  command -v job_lane_open >/dev/null 2>&1 || return 0
  job_lane_open merge/fleet/none "" merge \
    "$(jq -nc --arg l "merge-sweep" '{label:$l}' 2>/dev/null)" >/dev/null 2>&1 || true
  return 0
}
_sweep_finish() {
  # BH-1322: this lane's ETag counter file, removed first so a job_lane_close
  # that fails (no worker, a 500) still leaves nothing behind in state/.
  [ -n "${GH_ETAG_COUNT_FILE:-}" ] && rm -f "$GH_ETAG_COUNT_FILE" 2>/dev/null
  command -v job_lane_close >/dev/null 2>&1 && job_lane_close "$SWEEP_RC" merge-sweep
  return 0
}
trap '_sweep_finish' EXIT

# 0 = already ledgered (DB or file). File miss + DB miss = not seen. A legacy
# DB row 'closed' is NOT seen (BH-1601): only MERGED/parked rows are permanent.
# File miss + DB down  = not seen on THIS hub; the file is complete for the
# single-hub writer. DB hit back-fills the file so a rebuilt hub converges.
sweep_seen() {
  local pr="$1"
  grep -qxF "$pr" "$DONE" && return 0
  if type job_ledger_get >/dev/null 2>&1; then
    local st
    if st=$(job_ledger_get merge "$pr") && [ "$st" != closed ]; then
      echo "$pr" >> "$DONE"
      return 0
    fi
  fi
  return 1
}
sweep_record() { # sweep_record <pr-url> [status]
  local pr="$1" st="${2:-merged}"
  grep -qxF "$pr" "$DONE" || echo "$pr" >> "$DONE"
  if type job_ledger_put >/dev/null 2>&1; then
    job_ledger_put merge "$pr" "$st" >/dev/null 2>&1 || true
  fi
}

# --- The walk order (BH-710) -------------------------------------------------
# Project buckets come from the registry and nowhere else — a literal fleet list
# in a bin/*.sh is what left nine project-7 PRs unswept for ten days
# (tests/fleet-projects-not-hardcoded-test.sh). Longest name first, so a record
# named pool-project-1-... never buckets as "project-1". A tree with no
# fleet-conf.sh (the fixtures) gets one bucket, "-", which is newest-first over
# every record — today's behaviour for a single-project tree.
SWEEP_PROJECTS=$("$H/bin/fleet-conf.sh" --projects 2>/dev/null \
  | awk 'NF {print length($0) "\t" $0}' | sort -k1,1nr -k2,2 | cut -f2- | tr '\n' ' ')

# DB-FIRST (BH-2348). The records come from the jobs ledger through bor_union
# (bin/lib/builds-of-record.sh): one call per project, ordered by the ledger's
# updated_at (the RESULT mtime for a record only this disk has). A line is then
# "<project>\t<dir>\t<key>\t<ledger result line>\t<ledger updated_at>", and <dir>
# is `-` for a record no local dir backs (the loop holds it). Every local RESULT the ledger does not
# name — a `-`-bucket dir, a second pool- copy — is appended from find, so this
# never walks less than the file path. rc 1 from ANY project (outage, JOBS_URL
# unset, no client) drops the whole ledger answer and runs sweep_order_files,
# today's walk byte for byte: one tick never mixes the two orders.
sweep_order() {
  local p rows rc err out="" k bd ts rl d
  if command -v bor_union >/dev/null 2>&1 && [ -n "${SWEEP_PROJECTS// /}" ]; then
    err=$(mktemp 2>/dev/null) || err=/dev/null
    for p in $SWEEP_PROJECTS; do
      rows=$(bor_union "$p" 2>"$err"); rc=$?
      if [ "$rc" = 1 ]; then out=""; rc=fallback; break; fi
      # D12: a capped feed says so. bor_union already added every local RESULT
      # the capped rows do not name, so nothing on this disk is dropped.
      grep -q '^BOR_TRUNCATED=1' "$err" 2>/dev/null \
        && echo "$(STAMP) [merge-sweep] $p: ledger feed hit BOR_LIMIT — the newest rows only; every local record is still walked" >> "$LOG"
      while IFS=$'\t' read -r k bd _ ts rl _; do
        [ -n "$bd" ] || continue
        d=$(bor_local_dir "$bd") || d=-
        ts=${ts/ /T}; ts=${ts:0:19}
        # Tab is IFS whitespace, so an empty feed field (a blank box) shifts
        # result_line into ts. Drop the row rather than walk a shifted one: its
        # local RESULT, if any, is then appended from find like any unnamed dir.
        if ! [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]; then
          echo "$(STAMP) [merge-sweep] $p: ledger row for ${bd} has no updated_at in its column (a blank field?) — walked from its local RESULT, if any" >> "$LOG"
          continue
        fi
        # Tab is IFS whitespace: an empty field would shift the loop's columns.
        out="$out$p"$'\t'"${ts:--}"$'\t'"$d"$'\t'"${k:--}"$'\t'"${rl:--}"$'\n'
      done <<<"$rows"
    done
    [ "$err" = /dev/null ] || rm -f "$err"
    if [ "$rc" != fallback ]; then
      awk -F'\t' -v projects="$SWEEP_PROJECTS" '
          BEGIN { np = split(projects, P, " ") }
          FILENAME == ARGV[1] { if (NF) { seen[$3] = 1; print }; next }
          !($2 in seen) {
            dir = $2; b = dir; sub(/^.*\//, "", b); s = b; sub(/^pool-/, "", s)
            proj = "-"
            for (i = 1; i <= np; i++) if (index(s, P[i] "-") == 1) { proj = P[i]; break }
            printf "%s\t%s\t%s\n", proj, substr($1, 1, 19), dir
          }' <(printf '%s' "$out") \
             <(TZ=UTC find "$H/builds" -mindepth 2 -maxdepth 2 -type f -name RESULT -printf '%TY-%Tm-%TdT%TT\t%h\n' 2>/dev/null) \
        | sort -t$'\t' -k1,1 -k2,2r \
        | awk -F'\t' '
            { r = ++n[$1]; if (r == 1) ord[++np] = $1
              v = $3; for (i = 4; i <= NF; i++) v = v "\t" $i
              if (NF >= 5) v = v "\t" $2
              rec[$1, r] = v; if (r > maxr) maxr = r }
            END { for (r = 1; r <= maxr; r++) for (i = 1; i <= np; i++)
                    if ((ord[i], r) in rec) printf "%s\t%s\n", ord[i], rec[ord[i], r] }'
      return 0
    fi
  fi
  sweep_order_files
}

sweep_order_files() {  # prints "<project>\t<record dir>" — round-robin across projects, newest first within one
  local stream
  stream=$(find "$H/builds" -mindepth 2 -maxdepth 2 -type f -name RESULT -printf '%T@\t%h\n' 2>/dev/null)
  if [ -n "$stream" ]; then
    printf '%s\n' "$stream" \
      | awk -F'\t' -v projects="$SWEEP_PROJECTS" '
          BEGIN { np = split(projects, P, " ") }
          {
            dir = $2; b = dir; sub(/^.*\//, "", b); s = b; sub(/^pool-/, "", s)
            proj = "-"
            for (i = 1; i <= np; i++) if (index(s, P[i] "-") == 1) { proj = P[i]; break }
            printf "%s\t%018.6f\t%s\n", proj, $1, dir
          }' \
      | sort -t$'\t' -k1,1 -k2,2r \
      | awk -F'\t' '
          { r = ++n[$1]; if (r == 1) ord[++np] = $1; rec[$1, r] = $3; if (r > maxr) maxr = r }
          END { for (r = 1; r <= maxr; r++) for (i = 1; i <= np; i++)
                  if ((ord[i], r) in rec) printf "%s\t%s\n", ord[i], rec[ord[i], r] }'
    return 0
  fi
  # FAIL OPEN. No find, no -printf, an unreadable builds/ — walk the glob this
  # loop always walked (minus the duplicate pool-*-* pass) with one bucket. A
  # broken ordering must never be a reason a mergeable PR is not looked at.
  local d
  for d in "$H"/builds/*-*/; do [ -d "$d" ] || continue; printf -- '-\t%s\n' "${d%/}"; done
}

# --- The terminal-skip cache (BH-710) ----------------------------------------
# One line per cached refusal: "<last-logged-epoch> <cause> <pr-url> <fingerprint>".
# Loaded once, written under locks/merge-sweep.lock (held since line 168), and
# rewritten at end of run with the aged-out entries dropped. Lines that do not
# parse are DROPPED, which fails open to re-evaluating the record: an unreadable
# cache must never invent a reason to hold a mergeable PR.
TERM_CACHE="$H/state/merge-sweep-terminal.txt"; touch "$TERM_CACHE"
NOW=$(date +%s)   # one clock read for the whole run
declare -A _TERM
while read -r _TS _CAUSE _TPR _TFP; do
  case "$_TS" in ''|*[!0-9]*) continue ;; esac
  [ -n "$_TPR" ] && [ -n "$_TFP" ] || continue
  _TERM["$_TPR|$_TFP"]="$_TS $_CAUSE"
done < "$TERM_CACHE"

# --- The issue close-out, retryable (BH-784) ---------------------------------
# ORDER: comment, then close, then the done-marker — and the marker only after
# gh_rest_close has RE-READ the issue and seen it closed. Before this, a close
# that 403'd was one log line and the PR was stamped into merge-sweep-done.txt
# anyway; the file is permanent (sweep_seen reads it for ever), so the issue
# stayed open with nothing left in the fleet that would ever notice.
#
# TWO MARKERS, both in the build record (the natural key: the record is what
# sweep_seen and the whole loop are already keyed on):
#   issue-close-owed  written before the first attempt, removed when the close
#                     lands. It is what tells a LATER pass — which finds the PR
#                     already MERGED — that this record still owes a close.
#   issue-commented   written when the comment POST succeeded, so a retry closes
#                     without posting a second "Closing this issue".
sweep_close_issue() { # sweep_close_issue <pr-url> <record-dir> <owner/repo> <issue>
  local pr="$1" d="$2" slug="$3" issue="$4" w
  touch "$d/issue-close-owed" 2>/dev/null
  if w=$(mc_close_shipped "$slug" "$issue" "Merged in $pr (reviewed-merge sweep, reviewed record $(basename "$d")). Closing this issue." "$d" "$pr"); then
    rm -f "$d/issue-close-owed"
    # A slice (BH-2477) settles the close-out too: the issue stays open on purpose.
    case "$w" in
      kept-slice*) echo "$(STAMP) $pr left issue #$issue on $slug open on retry, slice delivered ($w)" >> "$LOG" ;;
      *)           echo "$(STAMP) $pr closed issue #$issue on $slug on retry (ai-build: $w)" >> "$LOG" ;;
    esac
    return 0
  fi
  echo "$(STAMP) $pr merged, but issue #$issue on $slug did not close ($w, HTTP $(mc_rest_status)) — close deferred to next sweep" >> "$LOG"
  return 1
}

# sweep_issue_for <record-dir> <pr-url> -> "<owner/repo> <issue>" for an
# issue-driven project's record, nothing otherwise. One derivation, used by both
# the first attempt and the retry, so the two cannot drift.
#
# THREE ANSWERS, NOT TWO. "No issue is owed" and "an issue is owed and I cannot
# name it" are opposite facts and they used to share rc 1:
#   0  this record owes a close, and here is the repo and the number
#   2  this record owes NO close — the project is board-driven (a board ticket
#      is closed through the app's API by whoever posts the what-shipped
#      comment, never from here), so there is nothing to retry and nothing to
#      wait for
#   1  we could not resolve the project or the number. That one IS a debt, and
#      the caller leaves the record alone and pages instead of recording it.
# Most of the fleet is board-driven, so collapsing 2 into 1 stranded every one
# of their merges behind a retry that could never succeed.
sweep_issue_for() {
  local d="$1" pr="$2" slug p n
  slug=$(sed -E 's|https://github.com/([^/]+/[^/]+)/pull/.*|\1|' <<<"$pr")
  for p in $("$H/bin/fleet-conf.sh" --projects 2>/dev/null); do
    [ "$("$H/bin/fleet-conf.sh" "$p" repo 2>/dev/null)" = "$slug" ] || continue
    [ "$("$H/bin/fleet-conf.sh" "$p" board_prefix 2>/dev/null)" = "-" ] || return 2
    n=$(basename "$d" | sed -nE "s/^(pool-)?$p-[A-Za-z]+-([0-9]+)-.*/\2/p")
    [ -n "$n" ] || return 1
    printf '%s %s' "$slug" "$n"; return 0
  done
  return 1
}

# --- Per-tick tallies (BH-710) -----------------------------------------------
# Every record is RETRYABLE until it says otherwise, and the classification is
# banked at the TOP of the next iteration — which is how a loop with fourteen
# `continue`s gets an honest count without a tally call on each of them.
declare -A T_SEEN T_MERGED T_RETRY T_TERMNEW T_TERMCACHED
SWEEP_PROJ_ORDER=""; _ITER_PROJ=""; _ITER_CLASS=""
SWEEP_DEADLINE_HIT=no; SWEEP_UNSEEN=0; SWEEP_DB_ONLY=0
# THE PROJECTS AN OPERATOR HAS HELD THIS LANE ON (BH-1465). SAID is the "already
# logged it" substring set, so hundreds of held records cost one line; LIST is
# the same set for the TOTAL line. Per tick and in memory only — the hold itself
# is the `lane-off-merge-sweep-<project>` row.
SWEEP_HELD_SAID=" "; SWEEP_HELD_LIST=""
sweep_tally_prev() {
  [ -n "$_ITER_PROJ" ] || return 0
  case "$_ITER_CLASS" in
    merged)          T_MERGED[$_ITER_PROJ]=$(( ${T_MERGED[$_ITER_PROJ]:-0} + 1 )) ;;
    terminal-new)    T_TERMNEW[$_ITER_PROJ]=$(( ${T_TERMNEW[$_ITER_PROJ]:-0} + 1 )) ;;
    terminal-cached) T_TERMCACHED[$_ITER_PROJ]=$(( ${T_TERMCACHED[$_ITER_PROJ]:-0} + 1 )) ;;
    *)               T_RETRY[$_ITER_PROJ]=$(( ${T_RETRY[$_ITER_PROJ]:-0} + 1 )) ;;
  esac
  _ITER_PROJ=""
}
# What the walk did NOT reach. Counted, never guessed: a budget or deadline
# break leaves records unwalked and the summary says how many (D12).
sweep_drain() { local n=0; while IFS= read -r _; do n=$((n+1)); done; SWEEP_UNSEEN=$((SWEEP_UNSEEN + n)); }

# BUDGET itself is set in the `# --- Merge budget (BH-778)` block above (the
# env knob, its validation and BUDGET_SRC); the loop only spends it.
while IFS=$'\t' read -r PROJ D BOR_KEY BOR_R BOR_TS; do
  sweep_tally_prev
  command -v sweep_pr_memo_reset >/dev/null 2>&1 && sweep_pr_memo_reset
  if [ "$BUDGET" -le 0 ]; then
    SWEEP_UNSEEN=1; sweep_drain
    # EXHAUSTION IS NOT SILENCE (BH-778): the line names the budget, where it came
    # from, how many merges spent it and how many records were left unwalked, so a
    # starved tick never reads like a tick with nothing eligible.
    echo "$(STAMP) [merge-sweep] merge budget spent this tick — budget $BUDGET_EFF ($BUDGET_SRC) EXHAUSTED after $SWEEP_BUDGET_MERGED merge(s): $SWEEP_UNSEEN record(s) not walked, the next */10 tick starts again at the newest" >> "$LOG"
    break
  fi
  # THE TICK HAS A DEADLINE, because flock -n above does not queue: a walk that
  # runs 60 minutes silently swallows the next five ticks, and "freshly built
  # PRs are seen in the tick they land" cannot hold no matter how the records
  # are ordered. 0 expires immediately (that is the test hook); the default sits
  # under the */10 cron line.
  if [ "$SECONDS" -ge "${SWEEP_DEADLINE_SECS:-540}" ]; then
    SWEEP_DEADLINE_HIT=hit; SWEEP_UNSEEN=1; sweep_drain
    echo "$(STAMP) [merge-sweep] tick deadline ${SWEEP_DEADLINE_SECS:-540}s reached after ${SECONDS}s — $SWEEP_UNSEEN record(s) not walked this tick" >> "$LOG"
    break
  fi
  # The ledger's result line wins over a STALE local copy (BH-2348); the filter
  # below applies to it exactly as it does to the file's first line. The ledger
  # row is put once, at build close. Two lanes rewrite line 1 of the local RESULT
  # after that and leave the row alone: bin/pr-url-reconcile.sh relinks a
  # PR_CREATE_FAILED to PR_CREATED (BH-848: the sweep must see it) and
  # bin/fly-pool.sh relabels a dead PR_CREATED as RESULT_UNVERIFIED (the sweep
  # must not). So a local RESULT written AFTER the ledger's updated_at is the
  # newer record, and its line wins.
  if [ -n "$BOR_R" ] && [ "$BOR_R" != - ]; then
    R=$BOR_R
    if [ "$D" != - ] && [ -f "$D/RESULT" ] \
       && [[ "$(date -u -r "$D/RESULT" +%Y-%m-%dT%H:%M:%S 2>/dev/null)" > "${BOR_TS:--}" ]]; then
      R=$(head -1 "$D/RESULT")
    fi
  else
    [ -f "$D/RESULT" ] || continue
    R=$(head -1 "$D/RESULT")
  fi
  case "$R" in "PR_CREATED https://"*) ;; *) continue ;; esac
  # No tier filter on purpose: hub-local RESULTs are single-line (no TIER:
  # marker), and a tier-1 whose gate merge failed should be swept too. An
  # already-merged PR just gets ledgered below.
  PR=$(grep -oE 'https://github.com/[^ ]+/pull/[0-9]+' <<<"$R" | head -1)
  [ -n "$PR" ] || continue
  # ABANDONED IS TERMINAL (2026-09-13). bin/blocked-resolver.sh ran its whole
  # ladder on this build, could not land it, closed the PR and recorded the
  # outcome. The record is left on disk as evidence, so without this the sweep
  # would keep picking it up and asking GitHub about a PR that is gone.
  [ -f "$D/.blocked-resolver-abandoned" ] && continue
  # >>> project hold
  # IS THIS RECORD'S PROJECT HELD (BH-1465)? Here, below the RESULT and
  # PR_CREATED filters so a record that is not a PR record at all costs no gate
  # lookup, and above everything that spends: no sweep_seen mark, no gate memo
  # read, no jobs-worker round trip, no gh call, no merge. The record is NOT
  # tallied as evaluated (_ITER_PROJ is still empty, so the next iteration's
  # sweep_tally_prev banks nothing) and NOT counted as unseen either: unseen
  # means "the walk ran out of budget before reaching it", and a record an
  # operator stopped on purpose is neither of those. The `-` bucket — a record
  # whose project sweep_order could not resolve — is never held; fail-open is
  # the rule the rest of this lane runs on, and lane_project_held refuses `-`
  # itself for the same reason.
  if [ "$PROJ" != "-" ] \
     && command -v lane_project_held >/dev/null 2>&1 && lane_project_held merge-sweep "$PROJ"; then
    case "$SWEEP_HELD_SAID" in
      *" $PROJ "*) ;;
      *) SWEEP_HELD_SAID="$SWEEP_HELD_SAID$PROJ "
         SWEEP_HELD_LIST="${SWEEP_HELD_LIST:+$SWEEP_HELD_LIST }$PROJ"
         echo "$(STAMP) [merge-sweep] $PROJ held: flags/$LANE_HELD_FLAG is set — its records are not walked this tick, and none of them is counted as seen or as unseen" >> "$LOG" ;;
    esac
    continue
  fi
  # <<< project hold
  sweep_seen "$PR" && continue
  # A LEDGER-ONLY RECORD IS NEVER MERGED (BH-2348). No local dir means no
  # review.md, no MIGRATION GATE grep and no REBASE note to read, and merging on
  # job_verdict alone would be a new merge path (guardrail 1). Held, logged once
  # per tick, counted on the TOTAL line — never tallied, recorded or cached, so
  # the next tick asks again and it merges once its record lands here.
  if [ "$D" = - ]; then
    SWEEP_DB_ONLY=$((SWEEP_DB_ONLY + 1))
    echo "$(STAMP) [merge-sweep] db-only record $BOR_KEY $PR held: no local evidence (review.md/migration-gate)" >> "$LOG"
    continue
  fi
  # This record is being EVALUATED this tick — everything above is a record that
  # is already handled or is not a PR record at all.
  _ITER_PROJ="$PROJ"; _ITER_CLASS=retryable
  T_SEEN[$PROJ]=$(( ${T_SEEN[$PROJ]:-0} + 1 ))
  if [ -z "$SWEEP_BUDGET_LOGGED" ]; then  # once per tick, and only on a tick that evaluates something
    SWEEP_BUDGET_LOGGED=1
    echo "$(STAMP) [merge-sweep] budget $BUDGET_EFF this tick ($BUDGET_SRC), spent round-robin across projects, newest record first" >> "$LOG"
  fi
  case " $SWEEP_PROJ_ORDER " in *" $PROJ "*) ;; *) SWEEP_PROJ_ORDER="$SWEEP_PROJ_ORDER $PROJ" ;; esac
  # >>> terminal cache hit
  # HERE, and not lower down, is where the saving is: every one of the five
  # terminal causes below is decided before the first jobs-worker round trip and
  # before the first gh call, so a refusal we already made costs one stat.
  FP=$(sweep_record_fp "$D")
  if [ -n "$FP" ] && [ -n "${_TERM[$PR|$FP]+x}" ]; then
    _ITER_CLASS=terminal-cached
    read -r _HTS _HCAUSE <<<"${_TERM[$PR|$FP]}"
    if [ $(( NOW - _HTS )) -ge "${SWEEP_TERMINAL_RELOG_SECS:-86400}" ]; then
      RELOG=$(sweep_relog_line "$_HCAUSE")
      if [ -n "$RELOG" ]; then
        echo "$(STAMP) $RELOG" >> "$LOG"
        _TERM["$PR|$FP"]="$NOW $_HCAUSE"
        printf '%s %s %s %s\n' "$NOW" "$_HCAUSE" "$PR" "$FP" >> "$TERM_CACHE"
      fi
    fi
    continue
  fi
  # <<< terminal cache hit
  # Token routing (sweep_use_token_for) is deliberately NOT here: the probe is
  # itself a gh call, and the record-based refusals below (tightened gate,
  # rebase note, missing APPROVE, provenance, recorded E2E FAIL) decide without
  # ever reaching GitHub — tests/e2e-smoke-test.sh asserts exactly that. The
  # probe runs at the first point this iteration actually consults gh.
  # SDLC item 2: the review gate. A repo whose trailing-window revert/reopen
  # rate crossed its threshold does not auto-merge; bin/review-tighten.sh
  # parked it and told the operator in ALERTS.log, and these PRs wait for HIS judged
  # merge. SKIPPED, never sweep_record'ed — a ledger row would mark them
  # handled forever and they would never land once the flag clears. With no
  # client at all this is a no-op and the sweep behaves exactly as it did.
  if command -v review_tighten_active >/dev/null 2>&1; then
    RT_SLUG=$(sed -E 's|https://github.com/([^/]+/[^/]+)/pull/.*|\1|' <<<"$PR")
    if [ -n "$RT_SLUG" ] && review_tighten_active "$RT_SLUG"; then
      echo "$(STAMP) $PR held: $RT_SLUG review gate is TIGHTENED (bin/review-tighten.sh) — parked for a judged merge" >> "$LOG"
      continue
    fi
  fi
  # A REBASE_* note describes the head AT BUILD TIME. The rebase train re-pushes
  # fixed heads; a head commit NEWER than the RESULT file means the note is
  # stale evidence, not a live defect (#1263 sat starved on this 2026-08-19).
  if grep -qE "REBASE_CONFLICT|REBASE_VERIFY_(FAILED|INCONCLUSIVE)" "$D/RESULT"; then
    # A PR the conductor holds is skipped below whatever its note says, so it
    # buys no commits read either (BH-1575).
    sweep_custody && continue
    sweep_use_token_for "$(sed -E 's|https://github.com/([^/]+/[^/]+)/pull/.*|\1|' <<<"$PR")"
    RB_COMMITS="repos/$(sed -E 's|https://github.com/([^/]+/[^/]+)/pull/.*|\1|' <<<"$PR")/pulls/${PR##*/}/commits"
    RB_HEAD=""
    if command -v sweep_head_date_var >/dev/null 2>&1; then
      # BH-1575: the head commit's date is a property of the head sha, so a sha
      # seen on an earlier tick answers from $SWEEP_HEADS. The head comes off
      # the tick's one memoised pull read, which the state read below reuses.
      sweep_pr_view_var RB_HEAD "$PR" '.head.sha // ""' || RB_HEAD=""
      sweep_head_date_var HTS "$SWEEP_HEADS" "$PR" "$RB_HEAD" "$RB_COMMITS"
    else
      HTS=$(mc_rest_pages "$RB_COMMITS" 2>/dev/null | jq -r '.[-1].commit.committer.date // ""' 2>/dev/null)
    fi
    RTS=$(date -u -d "@$(stat -c %Y "$D/RESULT")" +%Y-%m-%dT%H:%M:%SZ)
    if [ -z "$HTS" ] || [[ "$HTS" < "$RTS" ]]; then
      # Relayed RESULTs defeat the mtime comparison (the file lands on the hub
      # AFTER the head commit — #1283 parked on a train-OOM mislabeled as a
      # typecheck fail). A VERIFY note (not CONFLICT) claims the tree types
      # red; if the head's own CI Typecheck run is green, CI supersedes the
      # note — it tested the exact tree the note worried about.
      if grep -qE "REBASE_VERIFY_(FAILED|INCONCLUSIVE)" "$D/RESULT" && ! grep -q "REBASE_CONFLICT" "$D/RESULT"; then
        NREPO=$(sed -E 's|https://github.com/([^/]+/[^/]+)/pull/.*|\1|' <<<"$PR")
        if [ -n "$RB_HEAD" ]; then NHEAD="$RB_HEAD"; else NHEAD=$(mc_pr_view "$PR" .head.sha 2>/dev/null); fi
        TCRUN=$(gh_ci_api "$NREPO" "repos/$NREPO/actions/runs?head_sha=$NHEAD&per_page=20"           -q '.workflow_runs[] | select(.name=="Typecheck") | .conclusion' 2>/dev/null | head -1)
        if [ "$TCRUN" = "success" ]; then
          echo "$(STAMP) $PR REBASE_VERIFY note superseded by green CI Typecheck on head — proceeding" >> "$LOG"
        else
          continue
        fi
      else
        continue   # CONFLICT notes and untestable heads stay parked
      fi
    else
      echo "$(STAMP) $PR REBASE note is stale (head $HTS > record $RTS) — proceeding on current evidence" >> "$LOG"
    fi
  fi
  # --- The verdict: from the LEDGER when it has one, from the record when not --
  # Through phase 6 the three inputs to this decision — Fable's APPROVE, the
  # tier, and whether a cheap lane authored the review — were three files on the
  # box that ran the build. That works exactly as long as the record and the
  # sweep sit on one disk. Phase 7 has bin/run-build.sh write them down as
  # artifacts on the claim, so the merge decision's inputs are DB state.
  #
  # THE FALLBACK IS THE POINT. rc 2 (no job recorded this PR) and rc 1 (the
  # worker is unreachable) both fall through to the scraping below, unchanged
  # and unweakened — with an empty ledger this sweep behaves byte for byte as it
  # did before phase 7, which is what makes the ledger safe to fill one build at
  # a time.
  LEDGER_V=""; LEDGER_TIER=""; LEDGER_PROV=""; LEDGER_JOB=""; LEDGER_RSHA=""
  if type job_verdict >/dev/null 2>&1; then
    if LV=$(job_verdict "$PR"); then
      IFS=$'\t' read -r LEDGER_V LEDGER_TIER LEDGER_PROV _LSHA LEDGER_JOB LEDGER_RSHA <<<"$LV"
    fi
  fi
  if [ -n "$LEDGER_V" ]; then
    # A ledger verdict and a record verdict that DISAGREE is not a tie to break.
    # They are two copies of one judgement, written by the same script from the
    # same file; if they differ, one of them was edited or one build's record is
    # sitting in another build's directory. Park it and say which said what —
    # merging on either half of a contradiction is the expensive guess. This one
    # is NOT a resolver class: the two records disagree about a judgement that
    # was already made, and a rebuild would not settle which copy was right.
    RECORD_V=BLOCK
    verdict_is APPROVE -L "$D/review.md" 2>/dev/null && RECORD_V=APPROVE
    if [ "$LEDGER_V" != "$RECORD_V" ]; then
      echo "$(STAMP) $PR parked: ledger says $LEDGER_V, build record says $RECORD_V — verdict contradiction" >> "$LOG"
      HARNESS="$H" "$H/bin/alert-line.sh" "[merge-sweep] $PR parked: the jobs ledger ($LEDGER_V, job $LEDGER_JOB) and the build record ($RECORD_V, $(basename "$D")) disagree about the verdict — two copies of one judgement, so neither is a verdict; re-review the PR or delete the record that does not belong to it"
      sweep_record "$PR" parked
      continue
    fi
    if [ "$LEDGER_V" != APPROVE ]; then sweep_terminal "ledger-verdict-$LEDGER_V"; continue; fi
    # Judge provenance, from the row rather than from a grep of one box's
    # pipeline.log: a review served by anything but the primary lane gates the
    # build and never auto-merges. Same rule, sourced from the ledger.
    # `claude-via-openrouter` IS the primary lane's model, reached through the
    # tier-3 survival lane — bin/lib/review-provenance.sh owns that judgement,
    # and a tree without it reads the word as non-primary and holds.
    if [ -n "$LEDGER_PROV" ] && [ "$LEDGER_PROV" != "-" ] && ! rp_prov_is_claude "$LEDGER_PROV"; then
      echo "$(STAMP) $PR skipped: ledger provenance is $LEDGER_PROV, not the primary review lane" >> "$LOG"
      sweep_terminal "ledger-provenance-$LEDGER_PROV"
      continue
    fi
  else
    # Fable's verdict, from the same build record that names the PR.
    # The one shared reader (BH-1625): anchored, final block, unknown is no.
    if ! verdict_is APPROVE -L "$D/review.md" 2>/dev/null; then
      sweep_terminal no-approve-record; continue
    fi
    # Judge provenance: a fallback-lane review gates the build but never merges it.
    if grep -q "judge provenance" "$D/pipeline.log" 2>/dev/null; then
      sweep_terminal judge-provenance-record; continue
    fi
  fi

  # E2E smoke: a RECORDED browser failure is never merged over. Fable reviews
  # the diff; this is the only evidence in the record that the app was actually
  # LOADED, and a build whose preview 5xx'd has already been told so.
  #
  # RECORDED is the whole rule, and the asymmetry is deliberate. Only an explicit
  # "E2E: FAIL" parks a PR. An absent e2e.md means a build that never ran the
  # stage (non-UI diff, no Vercel lane, a box still on an older run-build.sh, a
  # relay that dropped the file) — treating that silence as a failure would park
  # every PR in the fleet on the day this shipped, which is the starvation shape
  # the project-4 E2E discount above exists to undo. A SKIP is likewise not a failure:
  # it says nothing was verified, and the APPROVE gate still carries the merge.
  if [ -f "$D/e2e.md" ] && tail -1 "$D/e2e.md" 2>/dev/null | grep -qx "E2E: FAIL"; then
    echo "$(STAMP) $PR skipped: E2E smoke FAILED on the build's preview deployment (see $D/e2e.md)" >> "$LOG"
    sweep_terminal e2e-fail
    continue
  fi

  # A PR the merge conductor holds (fresh pr-state.tsv row, BH-1575) costs no
  # GitHub read at all — not even the token probe below.
  sweep_custody && continue
  # Every gh call from here to the end of this iteration runs on the token
  # that can see this PR's repo (see sweep_token_for above; cached per repo,
  # so a second call after the rebase branch costs no API round-trip).
  SWEEP_SLUG=$(sed -E 's|https://github.com/([^/]+/[^/]+)/pull/.*|\1|' <<<"$PR")
  sweep_use_token_for "$SWEEP_SLUG"; TOK_RC=$?
  if [ "$TOK_RC" = 2 ]; then
    # Not ledgered, so the next tick re-offers it — the whole point of telling
    # a rate limit apart from an invisible repo (BH-796).
    echo "$(STAMP) $PR deferred: GitHub answered a transient error for $SWEEP_SLUG on every token this box holds (${_SWEEP_REPO_WHY[$SWEEP_SLUG]}) — not an invisible repo, retried next tick" >> "$LOG"
    continue
  elif [ "$TOK_RC" != 0 ]; then
    echo "$(STAMP) $PR skipped: its repo is invisible to every gh token on this box (ALERTS.log has the page)" >> "$LOG"
    continue
  fi
  # A READ THAT COULD NOT ANSWER IS SKIPPED, NOT SWEPT (BH-784). Before this an
  # empty answer left PSTATE empty and the PR was silently `continue`d — the
  # 2026-09-12 project-5 shape, a loop nobody logged. It is still skipped, but it
  # says so, and nothing about the PR is recorded.
  # 404 and 403 are different sentences (BH-784, the operator's finding 1 on #941): one
  # says the PR is not there, the other says GitHub would not answer. The row is
  # left exactly as it is either way, but the log says which it was.
  # THE BASE RIDES ALONG (BH-800, carried over the REST conversion): `.base.ref`
  # is REST's spelling of baseRefName, it keeps its `// "-"` placeholder, and it
  # stays BEFORE the closed-at field — closed_at is empty on an open PR and
  # `read` collapses whitespace, so a field after it would shift into PCLOSED.
  # The identity-not-permitted arm below reads PBASE and would otherwise go
  # silently unarmed on every PR the sweep touches.
  # BH-1575: with bin/lib/sweep-reads.sh the read runs in THIS shell (the log
  # line below names ITS status, not the parent's last one — the 2026-09-22
  # "UNVERIFIABLE (HTTP 304)" burst), a cache-miss 304 is re-asked, and a
  # fresh conductor row that says MERGED — immutable, and read off GitHub by
  # the conductor — is recorded without a read. READY and CLOSED are always read.
  SRC=0
  if command -v sweep_prstate_read >/dev/null 2>&1 \
     && sweep_prstate_read "$PR" "$SWEEP_PRS_FILE" "${SWEEP_PRS_FRESH_S:-}" \
     && [ "$SWEEP_PRS_STATE" = MERGED ]; then
    STATE="MERGED - - $SWEEP_PRS_HEAD - -"
    echo "$(STAMP) $PR MERGED per the merge conductor (pr-state.tsv, its project's conductor tick ${SWEEP_PRS_AGE}s old) — no GitHub read" >> "$LOG"
  elif command -v sweep_pr_view_var >/dev/null 2>&1; then
    sweep_pr_view_var STATE "$PR" '"\(.STATE) \(.MSTATE) \(.user.login) \(.head.sha) \(.base.ref // "-") \(.closed_at // "")"' || SRC=$?
  else
    STATE=$(mc_pr_view "$PR" '"\(.STATE) \(.MSTATE) \(.user.login) \(.head.sha) \(.base.ref // "-") \(.closed_at // "")"' 2>/dev/null); SRC=$?
  fi
  if [ "$SRC" != 0 ]; then
    if [ "$SRC" = 44 ]; then
      echo "$(STAMP) $PR ABSENT (HTTP 404) — skipped this pass, nothing recorded" >> "$LOG"
    else
      echo "$(STAMP) $PR read UNVERIFIABLE (HTTP $(mc_rest_status)) — skipped this pass, nothing recorded" >> "$LOG"
    fi
    continue
  fi
  read -r PSTATE PMERGE PAUTHOR PHEAD PBASE PCLOSED <<<"$STATE"
  # A CLOSED PR MAY BE MID-KICK (2026-09-15). The merge conductor closes a PR
  # and reopens it one REST call later (mc_kick_ci) to fire the `pull_request`
  # workflow a base change does not fire. It does that under its own
  # per-project lock, which this sweep does not take and cannot see — and
  # a recorded MERGED is PERMANENT (sweep_seen reads the row for ever). So a
  # closure younger than MC_CLOSED_SETTLE is left alone and re-read on the next
  # */10 pass. bin/reconcile-prs.sh asks the same question for the same reason.
  if [ "${PSTATE:-}" = "CLOSED" ] && ! mc_closed_settled "${PCLOSED:-}"; then
    echo "$(STAMP) $PR reads CLOSED but has not settled (closed $PCLOSED, window ${MC_CLOSED_SETTLE:-180}s) — skipped this pass, it may be a merge-conductor CI kick" >> "$LOG"
    continue
  fi
  # ONLY MERGED IS REMEMBERED (BH-1601). A settled CLOSED PR can still be
  # reopened, and a recorded one would be hidden by sweep_seen for ever, so it
  # is logged and re-read live on the next pass.
  if [ "${PSTATE:-}" = "CLOSED" ]; then
    echo "$(STAMP) $PR reads CLOSED — not recorded, re-read live next pass (BH-1601)" >> "$LOG"
    continue
  fi
  if [ "${PSTATE:-}" = "MERGED" ]; then
    # THIS IS THE RETRY (BH-784). A close-out this sweep started and could not
    # finish left issue-close-owed in the record; the PR reads MERGED from here
    # on, so this is the branch the retry has to live in. Still deferred = still
    # not recorded, and the next */10 pass asks again. A record that owes
    # nothing is recorded exactly as it always was.
    #
    # AND AN OWED CLOSE WHOSE ISSUE WE CANNOT NAME IS STILL AN OWED CLOSE. If
    # sweep_issue_for cannot resolve the project or the issue number, recording
    # the PR here would retire the debt by forgetting it — the marker would sit
    # in a record nothing ever reads again. So say which record, and leave it —
    # once, in ALERTS.log, because a line repeated every ten minutes into this
    # sweep's own log is a question nobody is being asked.
    #
    # A BOARD PROJECT OWES NO ISSUE CLOSE AT ALL (rc 2). Its ticket lives on the
    # product board and is closed through the app's API, so "cannot resolve an
    # issue" is not a debt here, it is the normal state of most of the fleet.
    # Marking one of those owed would strand a merge that really happened: never
    # recorded, no beat, no ledger row, and a line every pass sending someone
    # after an issue that does not exist. The marker is cleared and the merge is
    # recorded, which is what it always was before this ticket.
    if [ "${PSTATE:-}" = "MERGED" ] && [ -f "$D/issue-close-owed" ]; then
      SI=$(sweep_issue_for "$D" "$PR"); SIRC=$?
      if [ "$SIRC" = 0 ]; then
        read -r SI_SLUG SI_NUM <<<"$SI"
        sweep_close_issue "$PR" "$D" "$SI_SLUG" "$SI_NUM" || continue
      elif [ "$SIRC" = 2 ]; then
        rm -f "$D/issue-close-owed"
        echo "$(STAMP) $PR owes no issue close (board-driven project) — the marker is cleared and the merge is recorded now" >> "$LOG"
      else
        echo "$(STAMP) $PR owed close cannot be retried: project or issue number unresolved for record $(basename "$D") — NOT recorded" >> "$LOG"
        if [ ! -f "$D/issue-close-alerted" ]; then
          touch "$D/issue-close-alerted" 2>/dev/null
          HARNESS="$H" "$H/bin/alert-line.sh" "[merge-sweep] $PR merged and its issue close is owed, but neither the project nor the issue number can be derived from record $(basename "$D") — the merge is NOT recorded and every */10 pass will re-read it until someone closes the issue and removes $D/issue-close-owed"
        fi
        continue
      fi
    fi
    sweep_record "$PR" merged
    continue
  fi
  [ "${PSTATE:-}" = "OPEN" ] || continue
  harness_pr_author_match "${PAUTHOR:-}" || continue
  # >>> head-bound approval
  # SDLC item 1: an approval is about a SHA, not about a branch name. Every
  # commit after the reviewed head — a security, refuter or QA fix round — is
  # code no reviewer and no suite has read, and this sweep would otherwise merge
  # it on the strength of a verdict that predates it. The reviewed sha comes off
  # the verdict row; the build record's review-head file is the fallback for a
  # PR the ledger has no row for.
  #
  # FAIL-OPEN ON ABSENCE, deliberately: no reviewed sha (a build from before
  # this shipped, a relayed record without the file, an empty ledger) leaves the
  # sweep behaving exactly as it did — the same rule the ledger fallback follows,
  # for the same reason. Only a sha we HAVE that disagrees with the head parks.
  #
  # The FALLBACK FILE is reviewed-sha, written by the gate itself — not
  # review-head. review-head predates this feature: the old pipeline wrote it at
  # general-review time and then let the security, refuter and QA fix rounds
  # commit past it without moving it, so on an old record it is a sha that never
  # meant "this is what merges". reviewed-sha only ever exists where the gate
  # settled one, which keeps "absence = today's behaviour" true in both readers.
  HB_SHA="$LEDGER_RSHA"
  case "$HB_SHA" in ""|"-") HB_SHA=$(head -1 "$D/reviewed-sha" 2>/dev/null || true) ;; esac
  if [ -n "$HB_SHA" ] && [ -n "${PHEAD:-}" ] && [ "$HB_SHA" != "$PHEAD" ]; then
    if [ "${HEADBOUND_ENFORCE:-1}" = 1 ]; then
      echo "$(STAMP) $PR parked: head $PHEAD is not the reviewed sha $HB_SHA — commits landed after the approval" >> "$LOG"
      # NOT sweep_record'ed, and that is the whole point: a head-bound park is
      # REVERSIBLE. A human re-review, a rebind by bin/rebase-train.sh, or the operator
      # setting HEADBOUND_ENFORCE=0 all make this PR mergeable again, and a
      # ledger row would mark it handled forever — the same reason the review
      # gate above skips instead of recording. The alert is deduped on the HEAD
      # instead, so a stuck PR pages once per head rather than once per tick.
      if ! grep -qxF "$PR $PHEAD" "$HBALERT"; then
        echo "$PR $PHEAD" >> "$HBALERT"
        HARNESS="$H" "$H/bin/alert-line.sh" "[merge-sweep] $PR parked: its head ($PHEAD) is not the sha the review approved ($HB_SHA) — code no reviewer saw. The merge conductor buys the head-bound re-review; if that BLOCKs, bin/blocked-resolver.sh runs the agent fix round. Nothing here waits on a person."
      fi
      continue
    fi
    echo "$(STAMP) $PR head $PHEAD is not the reviewed sha $HB_SHA (HEADBOUND_ENFORCE=0 — warn only)" >> "$LOG"
  fi
  # <<< head-bound approval
  # project-4 E2E discount, mechanized (standing policy since 2026-08-14; sweep
  # taught 2026-08-19): project-4's E2E judges PROD, not the diff, so its red keeps
  # every PR UNSTABLE forever and the sweep starved a 10-PR backlog twice.
  # UNSTABLE on project-4 merges IFF the substance runs on the head sha are green —
  # Typecheck + Unit tests + Guard all success, and nothing except E2E is red.
  # Anything unknown fails closed to the old skip.
  if [ "${PMERGE:-}" = "UNSTABLE" ] && grep -q "/project-4/" <<<"$PR"; then
    # PHEAD is this tick's read of the same pull object (BH-1575: no second read).
    if command -v sweep_pr_view_var >/dev/null 2>&1 && [ -n "${PHEAD:-}" ]; then HEADSHA="$PHEAD"
    else HEADSHA=$(mc_pr_view "$PR" .head.sha 2>/dev/null); fi
    if [ -n "$HEADSHA" ]; then
      # The repo is the PR's own (BH-4080: no literal owner).
      PROJECT_4_SLUG=$(sed -E 's|https://github.com/([^/]+/[^/]+)/pull/.*|\1|' <<<"$PR")
      RUNS=$(gh_ci_api "$PROJECT_4_SLUG" "repos/$PROJECT_4_SLUG/actions/runs?head_sha=$HEADSHA&per_page=20" \
        -q '.workflow_runs[] | "\(.name)|\(.conclusion // .status)"' 2>/dev/null | sort -u)
      if grep -qxF "Typecheck|success" <<<"$RUNS" && grep -qxF "Unit tests|success" <<<"$RUNS" \
         && ! grep -vE "^E2E" <<<"$RUNS" | grep -qv "|success$"; then
        echo "$(STAMP) $PR UNSTABLE but substance green (typecheck+unit+guard; only E2E red) — project-4 discount applies" >> "$LOG"
        PMERGE=CLEAN
      fi
    fi
  fi
  # Generic green-but-UNSTABLE discount (2026-08-23, project-3 #226/227/228/234 then
  # #241/242 — three hand-merge rounds of the same class): GitHub can hold a PR
  # UNSTABLE on a phantom expected context that never reports, and the checks
  # API is 403 for our tokens so the sweep can't see WHICH context. When every
  # workflow that actually ran on the head sha CONCLUDED success (≥1 run, none
  # pending/failed), the record APPROVE + green runs are the same evidence the
  # orchestrator merged on by hand each time. project-4 keeps its stricter block
  # above (its E2E is genuinely red — prod-judging — so all-green never holds).
  if [ "${PMERGE:-}" = "UNSTABLE" ] && ! grep -q "/project-4/" <<<"$PR"; then
    GREPO=$(sed -E 's|https://github.com/([^/]+/[^/]+)/pull/.*|\1|' <<<"$PR")
    if command -v sweep_pr_view_var >/dev/null 2>&1 && [ -n "${PHEAD:-}" ]; then GHEAD="$PHEAD"
    else GHEAD=$(mc_pr_view "$PR" .head.sha 2>/dev/null); fi
    if [ -n "$GHEAD" ]; then
      GRUNS=$(gh_ci_api "$GREPO" "repos/$GREPO/actions/runs?head_sha=$GHEAD&per_page=20" \
        -q '.workflow_runs[] | .conclusion // .status' 2>/dev/null)
      if [ -n "$GRUNS" ] && ! grep -qv "^success$" <<<"$GRUNS"; then
        echo "$(STAMP) $PR UNSTABLE but every run on head concluded success ($(wc -l <<<"$GRUNS") run(s)) — green-run discount applies" >> "$LOG"
        PMERGE=CLEAN
      fi
    fi
  fi
  # CLEAN stays the requirement under the E2E policy (the operator 2026-09-12,
  # docs/E2E-POLICY.md). The policy makes E2E ADVISORY for non-UI diffs on the
  # REVIEW side (review-prs / review-autopilot read bin/lib/e2e-paths.sh); the
  # sweep does not grow a matching discount, on purpose: (1) the app repos now
  # paths-gate their browser jobs, so a non-UI PR's E2E job SKIPS green and the
  # PR is CLEAN on its own — the discount would have nothing to do; (2) a UI PR
  # whose E2E is red is exactly the PR that must NOT auto-merge, and CLEAN is
  # the one signal that still says so after branch protection stops requiring
  # E2E; (3) the sweep runs unattended and merges — a second, looser reading
  # of "green" here is where a red that should have blocked gets waved in.
  # The two discounts above remain for the phantom-context and pre-policy
  # project-4 shapes and are unchanged.
  if [ "${PMERGE:-}" != "CLEAN" ]; then
    # >>> identity not permitted
    # BLOCKED IS TWO DIFFERENT FACTS (BH-800, 2026-09-18). With something on the
    # base gating the merge, it is the one this line has always meant — the PR
    # is not ready, retry. With NOTHING gating it, GitHub is refusing the PUSH,
    # because this token is not in the branch's push allow-list. On 2026-09-18
    # that produced 42 of these lines in 40 minutes for PRs that could never
    # land on the App identity, and not one of them said so. One protection read
    # per (repo, base) per run answers it; anything the read cannot settle keeps
    # today's line with the reason annotated, and never pages.
    SWEEP_IDNOTE=""
    if [ "${PMERGE:-}" = "BLOCKED" ] && [ -n "${PBASE:-}" ] && [ "${PBASE:-}" != "-" ] \
       && command -v gh_push_blocked_verdict >/dev/null 2>&1; then
      if [ -z "${SWEEP_IDV["$SWEEP_SLUG $PBASE"]+x}" ]; then
        IFS=$'\t' read -r SPSTATUS SPJSON <<<"$(gh_branch_protection "$SWEEP_SLUG" "$PBASE")"
        if [ "$SPSTATUS" = "ok" ]; then
          SIDWORD=$(gh_token_identity)
          SWEEP_IDV["$SWEEP_SLUG $PBASE"]=$(printf '%s\t%s\t%s' \
            "$(gh_push_blocked_verdict "$SPJSON" "$SIDWORD")" "$SIDWORD" "$(gh_push_allowlist_summary "$SPJSON")")
        else
          # unprotected / unreadable <code>: we know only that we cannot say.
          SWEEP_IDV["$SWEEP_SLUG $PBASE"]=$(printf '%s\t-\t-' "$SPSTATUS")
        fi
      fi
      IFS=$'\t' read -r SIDV SIDW SIDLIST <<<"${SWEEP_IDV["$SWEEP_SLUG $PBASE"]}"
      case "$SIDV" in
        identity)
          echo "$(STAMP) $PR IDENTITY_NOT_PERMITTED $SWEEP_SLUG $SIDW: mergeState BLOCKED on $PBASE with no required checks and no required reviews — this identity cannot push to $SWEEP_SLUG (push allow-list: $SIDLIST). Nothing merges here until a repo admin adds it to branches/$PBASE/protection/restrictions. Not a PR state; not retried on this identity." >> "$LOG"
          gh_identity_alert merge-sweep "$SWEEP_SLUG" "$SIDW" "$PBASE"
          # NOT sweep_record'ed, for the same reason the head-bound park above is
          # not: the day an admin adds the identity, this PR must land.
          continue ;;
        allowlisted)
          echo "$(STAMP) $PR skipped: mergeState=BLOCKED (will retry; identity $SIDW is on the push allow-list, cause not readable from here)" >> "$LOG"
          continue ;;
        protected) : ;;                                  # today's line, unchanged
        *) SWEEP_IDNOTE=" — branch protection $SIDV" ;;   # unexplained / unprotected / unreadable
      esac
    fi
    echo "$(STAMP) $PR skipped: mergeState=${PMERGE:-unknown} (will retry)$SWEEP_IDNOTE" >> "$LOG"
    # <<< identity not permitted
    continue
  fi
  # Iron-law red-flag scan over ADDED lines (tests excluded — they may assert
  # against these very patterns). A hit is not a verdict, it is an adjudication —
  # bin/blocked-resolver.sh buys one Fable call over the flagged lines and their
  # context, and an ACCEPT lands as an ironlaw-head-accept row in the jobs DB,
  # which this block honors below.
  # Exclude test/spec FILES (awk tracks the current file across the diff) —
  # the old per-line "grep -v test" missed test-file lines that don't say
  # "test", parking #1267 on an assertion INSIDE a resurrection test.
  # scripts/migrations/ is also excluded: model strings in AgentModelConfig
  # seed rows there ARE the DB-driven pattern the iron law prescribes
  # (project-3 #262 parked on its own seed VALUES, 2026-08-27).
  # Comment-only added lines are also excluded: doc comments that CITE an iron
  # law ("// Never VERCEL_URL ...") are compliance, not violations (project-3 #266
  # and #270 both parked on exactly that, 2026-08-28/29). A commented-out
  # violation is dead code, which review owns, not the sweep.
  # .harness/specs/ is excluded for the same reason as the test files, one step
  # further out: since 2026-08-29 every harness PR carries the plan it was built
  # from (bin/run-build.sh's spec-artifact stage), and that file is client-ticket
  # PROSE. A plan that quotes the ticket's "no more confirm() dialogs" or names
  # the model a config row should hold would park its own PR on the words it
  # used to describe the fix.
  # >>> iron-law scan
  SWEEP_DIFF=$(mktemp) || SWEEP_DIFF=/dev/null
  # A DIFF WE COULD NOT READ IS NOT A CLEAN DIFF. This is a one-shot merge
  # decision, so an unread diff skips the PR rather than scanning an empty file
  # and finding the zero hits that let it merge.
  mc_pr_diff "$PR" "$SWEEP_DIFF" 2>/dev/null || {
    [ "$SWEEP_DIFF" = /dev/null ] || rm -f "$SWEEP_DIFF"
    echo "$(STAMP) $PR diff read UNVERIFIABLE (HTTP $(mc_rest_status)) — not scanned, not merged this pass" >> "$LOG"; continue; }
  FLAGS=$(awk '/^\+\+\+ /{skip=($2 ~ /\.(test|spec)\.|__tests__\/|__mocks__\/|\/tests?\/|scripts\/migrations\/|\.harness\/specs\//)} /^\+/ && !/^\+\+\+/ && !skip && $0 !~ /^\+[[:space:]]*(\/\/|\*|\/\*|#|--|<!--)/' "$SWEEP_DIFF" | \
    grep -cE "window\.(confirm|alert|prompt)\(|claude-(fable|opus|sonnet|haiku)|VERCEL_URL" || true)
  # The MINED checks (checks/, promoted from ruled repeat-finding families) run
  # over the SAME diff and their hits are added to the same red-flag count, so a
  # hit gets the treatment the inline patterns already get: park, alert, human
  # read. Detection only — checks-run.sh reads a diff and writes stdout, it has
  # no git write and no gh call. FAIL-OPEN by construction: an absent or
  # unrunnable runner contributes 0 and the sweep behaves exactly as it did
  # before the catalog existed, because a broken detector must never invent a
  # reason to hold a PR that passed review.
  CHECK_HITS=""
  CHECKS_RUN=""
  for _c in "${H:-/root/harness}/bin/checks-run.sh" "$(dirname "$0")/checks-run.sh"; do
    [ -x "$_c" ] && { CHECKS_RUN="$_c"; break; }
  done
  if [ -n "$CHECKS_RUN" ] && [ -s "$SWEEP_DIFF" ]; then
    CHECK_OUT=$("$CHECKS_RUN" "$SWEEP_DIFF" 2>/dev/null); CHECK_RC=$?
    if [ "$CHECK_RC" = 1 ]; then
      CHECK_HITS=$(printf '%s\n' "$CHECK_OUT" | grep '^CHECK-HIT ' | awk '{print $2}' | sort | uniq -c \
        | awk '{printf "%s(x%s) ", $2, $1}')
      FLAGS=$((FLAGS + $(printf '%s\n' "$CHECK_OUT" | grep -c '^CHECK-HIT ')))
    fi
  fi
  # <<< iron-law scan
  # AN ACCEPT IN THE DB IS AN ACCEPT (BH-4157, the conductor's arm): a row for
  # this exact head unparks it; an unprovable read parks. The row is bound to
  # the sha it judged: a push after the adjudication bites again.
  if [ "${FLAGS:-0}" -gt 0 ] && [ -n "${PHEAD:-}" ] && command -v ila_gate >/dev/null 2>&1; then
    ILA_OUT=$(ila_gate "$PR" "$PHEAD"); ILA_RC=$?
    case "$ILA_RC" in
      0) echo "$(STAMP) $PR iron-law scan found $FLAGS hit(s) on ${PHEAD:0:8}, $ILA_OUT" >> "$LOG"; FLAGS=0 ;;
      2) echo "$(STAMP) $PR iron-law: $ILA_OUT" >> "$LOG" ;;
    esac
  fi
  # THE SAME HITS ON A NEW HEAD ARE STILL ADJUDICATED (BH-4474, the conductor's
  # arm). Every hit's fingerprint must have an ACCEPT row for THIS PR in the
  # jobs ledger; a new or changed hit, or anything unprovable, parks as before.
  if [ "${FLAGS:-0}" -gt 0 ] && [ -n "${PHEAD:-}" ] && [ -s "$SWEEP_DIFF" ] && command -v ilc_covered >/dev/null 2>&1; then
    ILC_OUT=$(ilc_covered "$PR" "$FLAGS" "$SWEEP_DIFF"); ILC_RC=$?
    case "$ILC_RC" in
      0) echo "$(STAMP) $PR iron-law: carried acceptance from $(printf '%s\n' "$ILC_OUT" | cut -c1-8 | paste -sd, -) — $FLAGS hit(s) on ${PHEAD:0:8} match an adjudicated set on this PR, not parking" >> "$LOG"
         FLAGS=0 ;;
      1) echo "$(STAMP) $PR iron-law: carry refused on ${PHEAD:0:8} — new or changed hit(s): $(printf '%s\n' "$ILC_OUT" | paste -sd';' -)" >> "$LOG" ;;
      *) echo "$(STAMP) $PR iron-law: carry UNVERIFIABLE on ${PHEAD:0:8} ($(printf '%s' "$ILC_OUT" | head -1)) — parking as before" >> "$LOG" ;;
    esac
  fi
  [ "$SWEEP_DIFF" = /dev/null ] || rm -f "$SWEEP_DIFF"
  if [ "${FLAGS:-0}" -gt 0 ]; then
    PARK_WHY=""; [ -n "$CHECK_HITS" ] && PARK_WHY=" [mined checks: $CHECK_HITS]"
    echo "$(STAMP) $PR parked: $FLAGS iron-law red-flag line(s) in the diff — handed to the blocked-resolver for adjudication$PARK_WHY" >> "$LOG"
    if [ -n "$CHECK_HITS" ]; then
      # Every hit, verbatim, in the run log: the alert says a check fired, the
      # log says which line of which file, so the adjudicator it parks for does
      # not have to re-derive it from the diff.
      printf '%s\n' "$CHECK_OUT" | grep '^CHECK-HIT ' | while IFS= read -r _hit; do
        echo "$(STAMP) [merge-sweep] $PR $_hit" >> "$LOG"
      done
    fi
    HARNESS="$H" "$H/bin/alert-line.sh" "[merge-sweep] $PR parked on iron-law scan ($FLAGS hit(s))$PARK_WHY — handed to bin/blocked-resolver.sh: one Fable adjudication of the flagged lines, ACCEPT unparks this sha, REJECT buys an agent fix round. No person is waiting on it."
    sweep_record "$PR" parked   # never re-park-spam; the alert owns it now
    continue
  fi

  # Pre-arm static guards (2026-09-12): CI at the PR head was green against
  # the main of THAT moment. Re-run the repo's static-guard list against the
  # head merged into CURRENT main (bin/pre-arm-guards.sh dispatches the repo's
  # static-guards.yml on refs/pull/<n>/merge). Red parks the PR with the files
  # named; a repo with no such workflow, or a check that could not run, is
  # logged and the merge goes ahead — most fleet repos carry no suite.
  #
  # SKIPPED on a merge-queue repo: the queue's own merge_group run builds
  # main + the entries ahead of this one + this PR and runs the required check
  # on that tree — the same question, asked by GitHub, with the answer binding.
  # Dispatching a second workflow and waiting up to 1800s for it would only add
  # the rc-3 "main moved since" tail the queue exists to remove.
  PA_SLUG=$(sed -E 's|https://github.com/([^/]+/[^/]+)/pull/.*|\1|' <<<"$PR"); PA_NUM="${PR##*/}"
  # >>> lead fence (BH-1606)
  # A LEAD PR MERGES ONLY ON A LEAD/HUMAN MERGE ROW ON ITS LIVE HEAD. This sweep
  # lists operator-authored PRs (harness_pr_author_match above), and the ticket
  # hold below exempts a lead PR, so without this the sweep landed the lead's
  # PR on a box APPROVE. Asked on PHEAD — this pass's read of the pull object,
  # the head every gate below reads and the one the merge is pinned to — BEFORE
  # the pre-arm dispatch, so a lead PR waiting on its lead buys no workflow run,
  # and before the block gate, whose clean scan would restart the outage count.
  # Held or unreadable: nothing recorded (the hold ends by itself), next pass
  # asks again; to_lane_lead_fence has logged the one line and fed the alert.
  if command -v to_lane_lead_fence >/dev/null 2>&1; then
    LF_P=""
    for LF_X in $("$H/bin/fleet-conf.sh" --projects 2>/dev/null); do
      [ "$("$H/bin/fleet-conf.sh" "$LF_X" repo 2>/dev/null)" = "$PA_SLUG" ] && { LF_P="$LF_X"; break; }
    done
    to_lane_lead_fence "$LF_P" "$PA_SLUG" "$PA_NUM" "${PHEAD:-}" "${PAUTHOR:-}" "$LOG"
    [ "$?" = 1 ] || continue   # rc 0 held, rc 2 unreadable: not this pass
  fi
  # <<< lead fence
  SWEEP_QUEUE=0; mc_queue_enabled "$PA_SLUG" && SWEEP_QUEUE=1
  if [ "$SWEEP_QUEUE" = 1 ]; then
    PA_RC=0; PA_OUT=""
    echo "$(STAMP) $PR pre-arm guards skipped: $PA_SLUG main is behind a merge queue (its batch build is the gate)" >> "$LOG"
  else
    PA_OUT=$("$H/bin/pre-arm-guards.sh" "$PA_SLUG" "$PA_NUM" 2>>"$LOG"); PA_RC=$?
  fi
  if [ "$PA_RC" -eq 1 ]; then
    PA_FILES=$(tr '\n' ' ' <<<"$PA_OUT")
    echo "$(STAMP) $PR parked: static guards RED against current main (${PA_FILES:-files not named}) — CI was green at head, main moved" >> "$LOG"
    HARNESS="$H" "$H/bin/alert-line.sh" "[merge-sweep] $PR parked: static guards RED against CURRENT main — ${PA_FILES:-see the static-guards.yml run} — rebase or fix, then re-review"
    sweep_record "$PR" parked
    continue
  elif [ "$PA_RC" -eq 3 ]; then
    # Cancelled/skipped/timed-out run, or one still running when the wait
    # ended: nothing proven. Not a merge, not a park — the next tick
    # dispatches again.
    echo "$(STAMP) $PR pre-arm guards NOT GREEN (run cancelled/skipped/timed out/still running, rc=3) — not merging this tick, retry next" >> "$LOG"
    continue
  elif [ "$PA_RC" -ne 0 ]; then
    echo "$(STAMP) $PR pre-arm guards not checked (rc=$PA_RC) — merging on the reviewed head" >> "$LOG"
  fi

  # MERGIFY: this sweep must not merge AT ALL. Under GitHub's native queue the
  # call below IS the enqueue, so the sweep keeps making it and simply reads the
  # answer apart. Mergify sits BESIDE GitHub's merge button, not in front of it:
  # `gh pr merge` on a Mergify repo lands the PR straight onto main with none of
  # the batch verification the queue exists for, and with none of the settle the
  # conductor owes. The conductor is the only actor that knows how to put a PR
  # into that queue, so this leaves the PR to it — the same shape as the box
  # merge queue's stand-down, and the repo capability is the switch.
  if mc_queue_conductor_only "$PA_SLUG"; then
    echo "$(STAMP) $PR left to the merge conductor: $PA_SLUG is behind a Mergify merge queue — a direct gh pr merge here would BYPASS it" >> "$LOG"  # gh-guard-allow: prose in a log line, not a call
    continue
  fi
  # >>> block gate
  # A HUMAN BLOCK ON THE THREAD REFUSES THIS MERGE TOO (BH-762). The gate that
  # only covers the conductor is no gate at all: whichever lane picks the PR up
  # first is the one that lands it, and this one runs every 10 minutes on the
  # hub. Same rule, same lib, read immediately before the merge.
  #
  # NOT sweep_record'ed. A recorded park is invisible for ever (sweep_seen reads
  # the row on every later pass), and this hold must end by itself the moment a
  # newer commit lands or the author clears it — the same reason the review-
  # tighten hold above records nothing.
  if command -v bg_scan >/dev/null 2>&1; then
    BG_ISSUE=""
    for BG_P in $("$H/bin/fleet-conf.sh" --projects 2>/dev/null); do
      [ "$("$H/bin/fleet-conf.sh" "$BG_P" repo 2>/dev/null)" = "$PA_SLUG" ] || continue
      [ "$("$H/bin/fleet-conf.sh" "$BG_P" board_prefix 2>/dev/null)" = "-" ] || break
      BG_BR=$(mc_pr_view "$PR" .head.ref 2>/dev/null)
      BG_ISSUE=$(mc_issue_of "$D" "${BG_BR:-}")
      break
    done
    BGOUT=$(bg_scan "$PA_SLUG" "$PA_NUM" "$PR" "${PHEAD:-}" "$BG_ISSUE"); BGRC=$?
    if [ "$BGRC" != 0 ] && ! bg_enforce; then
      echo "$(STAMP) $PR block gate WARN-ONLY (BLOCK_GATE_ENFORCE=0): $(bg_reason "$BGRC" "$BGOUT" "${PHEAD:-}") — merging as it would have before the gate" >> "$LOG"
    elif [ "$BGRC" = 1 ]; then
      echo "$(STAMP) $PR MERGE_REFUSED block-gate: $(bg_why "$BGOUT" "${PHEAD:-}") — nothing merges until a newer commit lands or that author clears it" >> "$LOG"
      bg_refuse "$PA_SLUG" "$PA_NUM" "$PR" "${PHEAD:-}" "$BGOUT" merge-sweep \
        || echo "$(STAMP) $PR block gate could not post the refusal comment — the merge is refused either way and the next pass retries the post" >> "$LOG"
      continue
    elif [ "$BGRC" = 2 ]; then
      echo "$(STAMP) $PR not merged this pass: block gate could not read $BGOUT — nothing written, the next pass tries again" >> "$LOG"
      continue
    fi
  fi
  # <<< block gate
  # >>> dep gate
  # AN OPEN DECLARED DEPENDENCY HOLDS THIS MERGE TOO (BH-629). This is the lane
  # that merged #615 ahead of its own "Depends on #459 (PR #609)", so the gate
  # the conductor asks is asked here, immediately before the merge.
  #
  # Nothing is claimed and nothing is recorded: a recorded park is invisible for
  # ever (sweep_seen reads the row on every later pass), and this hold must end
  # by itself the moment the dependency closes. rc 2 holds on the same rule the
  # block gate above follows — an unreadable answer is not a landed dependency.
  if command -v pdg_hold >/dev/null 2>&1; then
    PDGOUT=$(pdg_hold "$PA_SLUG" "$PA_NUM" "$PR" ""); PDGRC=$?
    if [ "$PDGRC" = 0 ]; then
      echo "$(STAMP) $PR not merged this pass: HELD by the PR-dependency gate — it declares ${PDGOUT:-a dependency} that is still open; nothing written, re-offered next pass" >> "$LOG"
      continue
    elif [ "$PDGRC" = 2 ]; then
      echo "$(STAMP) $PR not merged this pass: the PR-dependency gate could not read its dependency — nothing written, the next pass asks again" >> "$LOG"
      continue
    fi
  fi
  # <<< dep gate
  # >>> main-red gate
  # A RED MAIN FREEZES THIS SWEEP TOO (BH-945). The merge conductor has refused
  # to merge into a red main since 2026-09-15; this lane never read the flag, so
  # the freeze the hub raised on 2026-09-18 stopped one merger out of six.
  #
  # Nothing is claimed and nothing is recorded, the dep gate's reason: a recorded
  # park is invisible for ever (sweep_seen reads the row on every later pass),
  # and this hold must end by itself the moment main goes green. The two ways
  # through are the conductor's own — the fix label, or a whole diff of test
  # files — and an answer nobody could read holds, because an unreadable PR
  # merging into a red main is the shape of the incident.
  #
  # The project is resolved from fleet.conf for THIS PR's slug (the block gate's
  # own loop above; BG_P is not reused because it keeps the last iteration's
  # value), so a hand-raised flags/main-red-<project> holds this lane the way it
  # holds the conductor and the boxes. Unresolvable = empty, and the gate skips
  # an empty project, so the slug spelling the detector writes is always read.
  MR_P=""
  for MR_X in $("$H/bin/fleet-conf.sh" --projects 2>/dev/null); do
    [ "$("$H/bin/fleet-conf.sh" "$MR_X" repo 2>/dev/null)" = "$PA_SLUG" ] || continue
    MR_P="$MR_X"; break
  done
  if command -v main_red_hold >/dev/null 2>&1 \
     && main_red_hold "$MR_P" "$PA_SLUG" "$PA_NUM" "$PR" "${PHEAD:-}"; then
    echo "$(STAMP) $PR not merged this pass: HELD by the main-red freeze — $PA_SLUG main is red (flags/${MRG_FLAG:-main-red}); nothing written, re-offered next pass. A PR labelled ${MC_MAIN_RED_LABEL:-fix-main-red} or one whose whole diff is test files still merges" >> "$LOG"
    continue
  fi
  # <<< main-red gate
  # A HELD TICKET'S PR DOES NOT MERGE (BH-1526): one log line, nothing recorded.
  command -v to_lane_hold >/dev/null 2>&1 && to_lane_hold "$MR_P" "$PA_SLUG" "$PA_NUM" "$LOG" && continue
  # THIS BOARD'S AUTO-MERGE TOGGLE (#2322): flags/automerge-disabled-<project>,
  # the Project page switch. Retryable like the pause below. The fleet switch
  # already stopped the whole sweep at the top.
  if [ -n "${MR_P:-$PROJ}" ] && [ "${MR_P:-$PROJ}" != - ] && ms_project_am_off "${MR_P:-$PROJ}"; then
    echo "$(STAMP) $PR skipped: flags/automerge-disabled-${MR_P:-$PROJ} is on — auto-merge is off for this board; nothing written, re-offered next tick" >> "$LOG"
    _ITER_CLASS=retryable
    continue
  fi
  # A MERGES PAUSE DOES NOT MERGE (BH-1684): after every gate, before the claim
  # and the merge call. Retryable like the hold above — never sweep_record'ed,
  # never ledgered, never in the terminal cache — so the first tick after the
  # pause ends or expires merges it. pause_active matches scope `fleet` for any
  # project, so a `-` bucket record (MR_P and PROJ both unresolved) still stops
  # on a fleet row.
  if pause_active "${MR_P:-$PROJ}" merges; then
    echo "$(STAMP) $PR skipped: PAUSED(merges) — a live merges pause covers ${MR_P:-$PROJ} or the fleet; nothing written, re-offered next tick" >> "$LOG"
    _ITER_CLASS=retryable
    continue
  fi
  sweep_claim
  # GH'S EXIT CODE IS NOT A LANDING. On a merge-queue repo `gh pr merge` exits 0
  # having only ENQUEUED the PR: it stays OPEN and mergeCommit.oid is null. The
  # old `if gh pr merge …; then` therefore recorded the merge, closed the issue
  # and beat tier2_sweep_merged for a PR that had not merged — while the deploy
  # hand-off silently skipped on the empty sha. Ask GitHub what happened
  # instead.
  #
  # NO `--delete-branch` ON THE gh LINE (BH-1715). Real gh deletes the head ref
  # with no look at the PRs stacked on it, and with delete_branch_on_merge off
  # GitHub CLOSES those children rather than retargeting them (#1664 and #1666,
  # 2026-09-23). The branch is deleted after a confirmed MERGED, below, through
  # `_gpm_delete_branch`: list the children, PATCH each, then DELETE.
  # >>> merge over rest (BH-892)
  # The merge PUT carries the REVIEWED sha (HB_SHA above), so a head that moved
  # between the gate and this line is refused by GitHub with a 409 instead of
  # merged blind. rc 0 is believed on the strength of the 200: under the cap the
  # state read below is the call that fails, and reading a real merge as
  # "merge FAILED despite CLEAN" is what sends the conductor into a retry, a
  # second 405 and a rebuild of a ticket that has already landed.
  # HEADBOUND_ENFORCE=0 is the operator's "merge it anyway" (header, and the
  # warn-only branch above): the head/reviewed-sha mismatch was downgraded to a
  # log line, so the PUT must not re-park the PR with the stale sha — a 409
  # there is terminal and would read as "merge FAILED despite CLEAN". Off means
  # UNBOUND, said here and again by the lib.
  MB_SHA="${HB_SHA:-}"
  if [ -n "$MB_SHA" ] && [ "${HEADBOUND_ENFORCE:-1}" != 1 ]; then
    echo "$(STAMP) $PR HEADBOUND_ENFORCE=0 — the merge is not bound to the reviewed sha $MB_SHA (it is pinned to the head this pass read)" >> "$LOG"
    MB_SHA=""
  fi
  # EVERY MERGE IS PINNED (BH-1606): with no reviewed sha in hand (or the switch
  # above off) the pin is PHEAD, the head the lead fence, the block gate and the
  # main-red gate all read this pass. A push since then is a head none of them
  # read, and GitHub refuses it (409 / "Head branch was modified") instead of
  # landing it. With HB_SHA set, HB_SHA == PHEAD already (the head-bound check).
  [ -n "$MB_SHA" ] || MB_SHA="${PHEAD:-}"
  # SWEEP_MRC is the gh verb's exit code and is read below only under a native
  # queue, where the REST path is skipped and the verb always runs; when the
  # verb does not run it stays 1, "not an enqueue". PM_RC is the state read's rc:
  # 0 when GitHub's own 200 already answered MERGED, otherwise the REST read's.
  PM_STATE=""; MSHA=""; MRC=2; SWEEP_MRC=1; PM_RC=0
  if [ "$SWEEP_QUEUE" != 1 ] && command -v gh_pr_merge_rest >/dev/null 2>&1; then
    MOUT=$(gh_pr_merge_rest "$PA_SLUG" "$PA_NUM" "$MB_SHA" \
             "$H/logs/merge-sweep-gh.err" "$LOG" "merge-sweep $PR" 1); MRC=$?
    case "$MRC" in
      0) PM_STATE=MERGED; MSHA="$MOUT" ;;
      2) : ;;   # no REST verdict — today's line below runs
      *) echo "$(STAMP) $PR REST merge refused (rc $MRC): $MOUT — not retried this tick" >> "$LOG" ;;
    esac
  fi
  if [ -z "$PM_STATE" ] && [ "$MRC" = 2 ]; then
    # THE METHOD COMES FROM THE REPO (BH-1313); `--squash` without the lib.
    SWEEP_MFLAG=--squash
    command -v gh_pr_merge_flag >/dev/null 2>&1 \
      && SWEEP_MFLAG=$(gh_pr_merge_flag "$PA_SLUG" "$PA_NUM" "$LOG" "merge-sweep $PR")
    SWEEP_PIN=(); [ -n "$MB_SHA" ] && SWEEP_PIN=(--match-head-commit "$MB_SHA")   # BH-1606
    gh pr merge "$PR" "$SWEEP_MFLAG" ${SWEEP_PIN[@]+"${SWEEP_PIN[@]}"} >/dev/null 2>&1; SWEEP_MRC=$?  # gh-guard-allow: gated merge verb, out of BH-770 scope
  fi
  if [ "$PM_STATE" != MERGED ]; then
    sleep "${SWEEP_MERGE_SETTLE:-3}"
    PM_STATE=$(mc_pr_view "$PR" .STATE 2>/dev/null); PM_RC=$?
  fi
  # <<< merge over rest
  # "did it queue instead of merging" is asked through the PROVIDER-AWARE reader,
  # not through isInMergeQueue, which only GitHub's own queue ever sets.
  #
  # …AND UNDER GITHUB'S OWN QUEUE THE WITNESS IS NOW THE VERB (BH-784).
  # isInMergeQueue is GraphQL-only and has no REST field, so mc_pr_queued answers
  # `unknown` there — and without this clause an ENQUEUED PR would fall into the
  # "merge FAILED despite CLEAN" branch below and page as a failure every ten
  # minutes while the queue was doing exactly what it was asked to. On a repo
  # whose main IS behind the native queue, `gh pr merge` having SUCCEEDED and the
  # PR still reading OPEN IS the enqueue — the same witness mc_enqueue_github
  # uses, which is why the exit code is now captured instead of `|| true`'d away:
  # a verb that FAILED outright (not mergeable, branch protection, auth) is not
  # an enqueue, and logging it as one records nothing, pages nobody and re-runs
  # the same failing merge every ten minutes forever. Both halves are required:
  # an unreadable state is not an enqueue either.
  if [ "${PM_STATE:-}" != "MERGED" ] \
     && { mc_pr_queued "$PR" \
          || { [ "$SWEEP_QUEUE" = 1 ] && [ "$SWEEP_MRC" = 0 ] && [ "${PM_STATE:-}" = "OPEN" ]; }; }; then
    # Enqueued, not merged. NOTHING is recorded here — not the ledger row, not
    # the done-file, not the issue close, not the beat: bin/merge-conductor.sh
    # owns the QUEUED -> MERGED settle and does all of it once, with the real
    # merge sha. Leaving the PR unrecorded is what lets the conductor see it.
    echo "$(STAMP) $PR enqueued in $PA_SLUG's merge queue (not merged) — the merge conductor settles it" >> "$LOG"
    continue
  fi
  if [ "${PM_STATE:-}" = "MERGED" ]; then
    BUDGET=$((BUDGET-1)); SWEEP_BUDGET_MERGED=$((SWEEP_BUDGET_MERGED+1))
    _ITER_CLASS=merged
    # The gh fallback merged it and deleted nothing (BH-1715): the branch goes
    # here, children first, and a child it retargets is recorded as owed a
    # restack. The REST merge already did this inside the lib. A queue repo's
    # branch is never ours to delete, and without the lib the branch is KEPT —
    # litter, never a closed PR. Best effort: the merge stands whatever it says.
    if [ "$MRC" = 2 ] && [ "$SWEEP_QUEUE" != 1 ] && command -v _gpm_delete_branch >/dev/null 2>&1; then
      _gpm_delete_branch "$PA_SLUG" "$PA_NUM" "" "$LOG" "merge-sweep $PR" || true
    fi
    # THE DONE-MARKER IS WRITTEN LAST NOW (BH-784). It used to be written here,
    # before the issue close-out below, so a close that 403'd left the record
    # permanently done with its issue still open and nothing but reconcile-prs.sh
    # to notice. CLOSE_DEFERRED carries that answer down to the bottom of this
    # branch, where sweep_record runs only if the close was verified.
    CLOSE_DEFERRED=0
    # Phase 7: the merge sha closes the build's outcome contract. It goes on the
    # BUILD's job — the claim that produced the PR, found through the same
    # lookup that gave us the verdict — and not on this sweep's own row, which
    # is a coordination claim for the sweep and knows nothing about the build.
    if [ -n "$LEDGER_JOB" ] && type job_artifact_put >/dev/null 2>&1; then
      # The REST answer already carried the merge sha when it merged (BH-892);
      # the pull-object read (BH-784) is the fallback, not the first question.
      [ -n "$MSHA" ] || MSHA=$(mc_pr_view "$PR" '.merge_commit_sha // ""' 2>/dev/null)
      [ -n "$MSHA" ] && job_artifact_put merge_sha "$MSHA" \
        "$(jq -nc --arg p "$PR" '{by:"merge-sweep",pr:$p}' 2>/dev/null)" "$LEDGER_JOB" \
        >/dev/null 2>&1 || true
    fi
    # --- CODEGRAPH REFRESH (begin) ---
    # the operator's directive: the graph is refreshed after each PR as well as before.
    # The PULL is not optional here — codegraph indexes the main clone's WORKING
    # TREE, so refreshing without pulling would faithfully re-index the tree that
    # does not yet contain the merge, and report itself fresh. Project comes from
    # the PR's repo slug matched against fleet.conf, not from a hardcoded map.
    CG_SLUG=$(sed -E 's|https://github.com/([^/]+/[^/]+)/pull/.*|\1|' <<<"$PR")
    for CG_P in $("$H/bin/fleet-conf.sh" --projects 2>/dev/null); do
      [ "$("$H/bin/fleet-conf.sh" "$CG_P" repo 2>/dev/null)" = "$CG_SLUG" ] || continue
      ( cd "/root/repos/$CG_P" 2>/dev/null && git pull --ff-only --quiet 2>/dev/null
        "$H/bin/codegraph-ensure.sh" "$CG_P" >/dev/null 2>&1 ) || true
      # Post-merge prod gate (2026-09-12) — the tier-1 path has handed every
      # merge to deploy-request.sh since 2026-07-27; the reviewed-merge sweep never did,
      # so three red Vercel production builds on project-5 main went unseen for
      # an hour (#374/#378/#385, prod pinned at the last good deploy). Detached;
      # inert for a project with neither VERSION_URL nor a deployments API.
      [ -n "${MSHA:-}" ] || MSHA=$(mc_pr_view "$PR" '.merge_commit_sha // ""' 2>/dev/null)
      [ -n "${MSHA:-}" ] && "$H/bin/deploy-request.sh" "$CG_P" "$CG_SLUG" "$MSHA" "$D" >/dev/null 2>&1 || true
      # >>> issue close after merge
      # Issue-driven projects (fleet.conf board prefix "-"): close the ticket
      # the PR was built for, explicitly (2026-09-12). The PR body now carries
      # "Closes #n" (bin/run-build.sh), but a squash by another actor may not,
      # and hand-merged project-5 PRs left their issues open for a day — so the
      # box's issue-fingerprint gate saw nothing move and "gate no-change"
      # repeated every tick. The issue number is the build KEY's number
      # (pool-<project>-<KEY>-<stamp>, KEY = <PREFIX>-<n>). Fail-open: a
      # comment or close that fails is one log line, never a failed merge.
      if [ "$("$H/bin/fleet-conf.sh" "$CG_P" board_prefix 2>/dev/null)" = "-" ]; then
        CG_ISSUE=$(basename "$D" | sed -nE "s/^(pool-)?$CG_P-[A-Za-z]+-([0-9]+)-.*/\2/p")
        if [ -n "$CG_ISSUE" ]; then
          # Comment, then close, then strip `ai-build` (BH-637 §3b) — a shipped
          # issue that still carries the handoff label is what re-offers finished
          # work to every selector in the fleet. mc_close_shipped answers 0 only
          # after a fresh read says the issue really is closed, so the "closed
          # issue" line is never written off a PATCH that 403'd, and the comment
          # is paid for once: the `issue-commented` marker in this record makes
          # the retry silent on the thread. A failure marks the record as owing
          # a close and leaves the done-marker unwritten, so the next */10 pass
          # picks it up instead of stamping it done with the issue still open.
          # The marker goes on BEFORE the attempt, not on its failure: a sweep
          # killed between the comment and the close would otherwise leave a
          # record that owes a close and says nothing, and the next pass would
          # read MERGED, find nothing owed, and record it with the issue open.
          touch "$D/issue-close-owed" 2>/dev/null
          if CG_W=$(mc_close_shipped "$CG_SLUG" "$CG_ISSUE" "Merged in $PR (reviewed-merge sweep, reviewed record $(basename "$D")). Closing this issue." "$D" "$PR"); then
            rm -f "$D/issue-close-owed" 2>/dev/null
            case "$CG_W" in
              kept-slice*) echo "$(STAMP) $PR left issue #$CG_ISSUE on $CG_SLUG open, slice delivered ($CG_W)" >> "$LOG" ;;
              *)           echo "$(STAMP) $PR closed issue #$CG_ISSUE on $CG_SLUG (ai-build: $CG_W)" >> "$LOG" ;;
            esac
          else
            touch "$D/issue-close-owed" 2>/dev/null; CLOSE_DEFERRED=1
            echo "$(STAMP) $PR merged; issue #$CG_ISSUE on $CG_SLUG close deferred to next sweep ($CG_W, HTTP $(mc_rest_status))" >> "$LOG"
          fi
        fi
      fi
      # <<< issue close after merge
      break
    done
    # --- CODEGRAPH REFRESH (end) ---
    # NOW the record is done — after a close this pass verified, and not before.
    # A deferred close leaves the PR out of merge-sweep-done.txt on purpose: the
    # done-file is this sweep's dedup key, so leaving the PR out of it is exactly
    # what brings the record back next pass for the owed-close retry above.
    if [ "$CLOSE_DEFERRED" = 0 ]; then
      sweep_record "$PR" merged
      echo "$(STAMP) MERGED $PR (reviewed-merge sweep, record $(basename "$D"))" >> "$LOG"
    else
      echo "$(STAMP) MERGED $PR (reviewed-merge sweep, record $(basename "$D")) — issue close deferred, NOT recorded; the next sweep retries the close-out and records it then" >> "$LOG"
    fi
    "$H/bin/beat.sh" "$(jq -nc --arg pr "$PR" --arg d "$(basename "$D")" \
      '{kind:"build",project:"fleet",stage:"tier2_sweep_merged",pr_url:$pr,merged:true,detail:("merge-sweep: verified reviewed-merge record "+$d)}')" >/dev/null 2>&1 || true
    if grep -q "MIGRATION GATE" "$D/RESULT"; then
      if declare -F mg_first_named >/dev/null 2>&1; then
        MIGF=$(mg_first_named "$PROJ" "$D"/migration-gate.txt "$D"/RESULT 2>/dev/null)
      else
        MIGF=$(grep -hoE 'scripts/migrations/[^ `"]+\.sql' "$D"/migration-gate.txt "$D"/RESULT 2>/dev/null | head -1)
      fi
      HARNESS="$H" "$H/bin/alert-line.sh" "[merge-sweep] $PR merged with MIGRATION GATE — classifier-FLAGGED SQL needs the app's migrations endpoint (orchestrator judged apply): apply ${MIGF:-see PR body} via the project's /api/internal/migrations/apply AFTER the deploy serves, then verify the reading surface. No box holds prod DB credentials, so this is the one gate an agent cannot take itself (allowlisted files in this PR are handled by migration-autopilot; only the flagged SQL is left)"
    fi
  elif [ "$PM_RC" != 0 ]; then
    # GITHUB WOULD NOT SAY WHAT HAPPENED (BH-784). Writing "merge FAILED despite
    # CLEAN" here is the defect this whole change is about, one level up: a read
    # that could not answer, recorded in the ledger as a fact about the PR. So
    # nothing is recorded either way and the next */10 pass re-reads it.
    if [ "$SWEEP_MRC" = 0 ]; then
      # The verb returned 0, so this PR is in all likelihood merged. The record
      # is marked as owing its issue close-out and the retry above runs it as
      # soon as a read confirms MERGED. The deploy request and the ship beat are
      # NOT re-run on that pass — deploy-train's self-source floor covers the
      # deploy, the same net the conductor leans on when GitHub publishes no
      # merge sha.
      #
      # THE MARKER GOES ON ONLY WHERE A CLOSE IS ACTUALLY OWED. On a board
      # project nothing here closes anything (the ticket is closed through the
      # app's API), so marking the record owed would leave it owing a debt no
      # pass can ever repay — the merge never recorded, the beat never fired.
      # Most of the fleet is board-driven, so that is the common path, not the
      # corner. The retry branch clears a stale marker for the same reason.
      sweep_issue_for "$D" "$PR" >/dev/null; SIRC=$?
      if [ "$SIRC" = 2 ]; then
        echo "$(STAMP) $PR merge verb returned 0 but the verifying read is UNVERIFIABLE (HTTP $(mc_rest_status)) — NOT recorded either way; the next sweep re-reads it and records it then (board-driven project, no issue close is owed; no deploy request issued for this merge, deploy-train's self-source floor covers it)" >> "$LOG"
      else
        touch "$D/issue-close-owed" 2>/dev/null
        echo "$(STAMP) $PR merge verb returned 0 but the verifying read is UNVERIFIABLE (HTTP $(mc_rest_status)) — NOT recorded either way; the next sweep re-reads it and retries the issue close (no deploy request issued for this merge, deploy-train's self-source floor covers it)" >> "$LOG"
      fi
    else
      echo "$(STAMP) $PR merge verb failed and the verifying read is UNVERIFIABLE (HTTP $(mc_rest_status)) — nothing recorded, no merge failure claimed, re-read next pass" >> "$LOG"
    fi
  else
    SWEEP_RC=1
    command -v job_event >/dev/null 2>&1 && [ -n "${JOB_ID:-}" ] \
      && job_event "$JOB_ID" merge FAILED "$PR merge failed despite CLEAN" >/dev/null 2>&1 || true
    echo "$(STAMP) $PR merge FAILED despite CLEAN — left for the conductor's retry; a second failure parks it as merge-failed-twice and bin/blocked-resolver.sh rebuilds it fresh" >> "$LOG"
  fi
# Process substitution, so BUDGET, _SWEEP_REPO_TOK, JOB_ID and the tallies all
# live in the MAIN shell — a pipe into `while` would run the body in a subshell
# and lose every one of them.
done < <(sweep_order)
sweep_tally_prev

# --- The tick summary (BH-710) -----------------------------------------------
# One line per project that had a record this tick, then one fleet total. NO PR
# URL on any of them: bin/pipeline-health.sh:344 greps this log per PR to
# explain a starved PR, and a summary line that carried one would answer that
# grep with a number instead of a reason. A tick that evaluated nothing and
# reached the end of the walk stays silent, as it always has.
SWEEP_TOT_SEEN=0; SWEEP_TOT_MERGED=0; SWEEP_TOT_CACHED=0; SWEEP_NPROJ=0
for SWEEP_P in $SWEEP_PROJ_ORDER; do
  SW_S=${T_SEEN[$SWEEP_P]:-0}; SW_M=${T_MERGED[$SWEEP_P]:-0}; SW_R=${T_RETRY[$SWEEP_P]:-0}
  SW_TN=${T_TERMNEW[$SWEEP_P]:-0}; SW_TC=${T_TERMCACHED[$SWEEP_P]:-0}
  echo "$(STAMP) [merge-sweep] tick $SWEEP_P: seen=$SW_S merged=$SW_M retryable=$SW_R terminal-new=$SW_TN terminal-cached=$SW_TC" >> "$LOG"
  SWEEP_NPROJ=$((SWEEP_NPROJ + 1)); SWEEP_TOT_SEEN=$((SWEEP_TOT_SEEN + SW_S))
  SWEEP_TOT_MERGED=$((SWEEP_TOT_MERGED + SW_M)); SWEEP_TOT_CACHED=$((SWEEP_TOT_CACHED + SW_TC))
done
if [ "$SWEEP_TOT_SEEN" -gt 0 ] || [ "$SWEEP_UNSEEN" -gt 0 ] || [ "$SWEEP_DB_ONLY" -gt 0 ]; then
  echo "$(STAMP) [merge-sweep] tick TOTAL: projects=$SWEEP_NPROJ seen=$SWEEP_TOT_SEEN merged=$SWEEP_TOT_MERGED terminal-cached=$SWEEP_TOT_CACHED deadline=$SWEEP_DEADLINE_HIT unseen=$SWEEP_UNSEEN held=[$SWEEP_HELD_LIST] db-only=$SWEEP_DB_ONLY" >> "$LOG"
fi

# --- Prune the terminal cache by AGE -----------------------------------------
# By age ONLY, never by "not seen this run": a budget- or deadline-stopped walk
# leaves live records unwalked, and evicting their entries would hand the next
# tick the expensive work back. Temp + mv so a kill mid-write leaves the old
# file, and a failed rewrite costs at most one re-evaluation per entry.
SWEEP_TT=$(mktemp "$H/state/.merge-sweep-terminal.XXXXXX" 2>/dev/null) || SWEEP_TT=""
if [ -n "$SWEEP_TT" ]; then
  for SWEEP_K in "${!_TERM[@]}"; do
    SWEEP_V=${_TERM[$SWEEP_K]}
    [ $(( NOW - ${SWEEP_V%% *} )) -lt "${SWEEP_TERMINAL_TTL_SECS:-604800}" ] || continue
    printf '%s %s %s %s\n' "${SWEEP_V%% *}" "${SWEEP_V#* }" "${SWEEP_K%%|*}" "${SWEEP_K#*|}"
  done > "$SWEEP_TT"
  mv -f "$SWEEP_TT" "$TERM_CACHE"
fi
# The sweep is finished with every repo it touched: put back the token and the
# identity tag this process started with (a no-op on a box without the lib).
command -v gh_default_auth_reset >/dev/null 2>&1 && gh_default_auth_reset
# BH-1295: mc_pr_view's tick-over-tick PR-state reads are this lane's main
# gh_rest traffic (see the many call sites above); one line names how much of
# it a 304 answered instead of a fresh read.
command -v gh_rest_etag_report >/dev/null 2>&1 && gh_rest_etag_report merge-sweep
# BH-1484: and ONE line naming how much of the SHARED App-installation bucket is
# left and when it refills, so the hourly drain is predictable from this log
# instead of from the burst of UNVERIFIABLE lines it causes. It reads the
# reading this tick's own REST calls already wrote — it costs no API call. The
# bucket it names is `app`, the shared installation bucket the ticket measured;
# a reading whose window already reset prints `stale=1` and no numbers, exactly
# as the gate treats it. The 48h ledger sweep is its own call (it self-limits to
# once an hour) so that bin/gh-quota-report.sh can print the line and stay the
# read-only command its header claims to be.
command -v gh_quota_line >/dev/null 2>&1 && gh_quota_line
command -v gh_quota_ledger_sweep >/dev/null 2>&1 && gh_quota_ledger_sweep
# The PROCESS still exits 0 whatever happened, exactly as it always has: this
# is a cron whose exit code nothing reads, and a merge that failed is recorded
# where it can actually be seen — the job row's status and its FAILED event.
exit 0
