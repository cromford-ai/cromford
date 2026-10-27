#!/bin/bash
# External-PR review guard (per the operator, 2026-07-27): every open PR authored by
# someone other than the harness/operator (operator) gets a Fable adversarial review.
# Findings post on the PR; when the author pushes fixes, the new head re-reviews.
# APPROVE (any tier) -> merge here (respects flags/automerge-disabled), unless
# tier_gate_mode[.<project>]=human holds a tier-2 APPROVE (bin/lib/tier-gate.sh).
# On a Mergify repo the conductor's external enqueue asks the queue instead
# (bin/lib/mc/external-enqueue.sh). The beat is news, not a request.
#
# COVERS EVERY PROJECT IN fleet.conf (BH-659). This lane needs exactly one
# per-project fact — the GitHub repo slug — and the registry's column 2 holds
# it, so it is read from there. It used to be a `case` over the four original
# projects with a silent `*) exit 1`, while bin/lib/cron-lines.sh generated a
# review-prs line for EVERY project: seven of eleven ran this script twice an
# hour, reviewed nothing and told no one. A project the registry cannot answer
# for now writes one ALERTS line and exits 1 — never a quiet exit.
# usage: review-prs.sh <project>   (cron per box, its own project only)
set -uo pipefail
# BH-2303: every model call this lane makes names the lane, so its cost rows
# carry lane_id and its LLM_* knobs (on/off, runners, daily cap) bind it alone.
export AGENT_CALL_LANE=review-prs
# Overridable so tests can drive this script against a scratch tree. Cron
# never sets it, so production resolves to exactly the path it always has.
HARNESS="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s
' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$HARNESS")
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
# The registry reader, from the checkout beside this script or from the live
# harness — the same two-location resolution this script uses for
# lib/gh-pr-list.sh below. In production both are /root/harness/bin.
_FC=""
for _C in "$(dirname "$0")/fleet-conf.sh" "$HARNESS/bin/fleet-conf.sh"; do
  [ -x "$_C" ] && { _FC="$_C"; break; }
done
if [ $# -eq 0 ]; then
  echo "usage: review-prs.sh <project>   (cron per box, its own project only)" >&2
  echo "covers every project in fleet.conf:" >&2
  if [ -n "$_FC" ]; then "$_FC" --projects >&2; else echo "  (registry unreadable — no fleet.conf reader found)" >&2; fi
  exit 2
fi
PROJECT="${1:?project}"
set -a; . "$HENV/global.env" 2>/dev/null; . "$HENV/$PROJECT.env" 2>/dev/null; set +a
REPO_DIR="${REPOS_ROOT:-/root/repos}/$PROJECT"
SLUG=""
[ -n "$_FC" ] && { SLUG=$("$_FC" "$PROJECT" repo 2>/dev/null) || SLUG=""; }
if [ -z "$SLUG" ] || [ "$SLUG" = "-" ]; then
  # Loud, and before anything else: no state file, no lock, no gh call. The
  # reason matters to whoever reads it — a missing row is a registry edit, an
  # unreadable registry is a broken box.
  if [ -n "$_FC" ]; then REASON="project not in registry"; else REASON="registry unreadable"; fi
  HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[$PROJECT] review-prs: no repo slug for '$PROJECT' in fleet.conf ($REASON) — external-PR review is NOT running for it; add the fleet.conf row or drop its cron line"
  exit 1
fi
STATE="$HARNESS/state/$PROJECT.pr-reviews.json"
[ -f "$STATE" ] || echo '{}' > "$STATE"
exec 8>"$HARNESS/locks/review-prs-$PROJECT.lock"
flock -n 8 || exit 0
# >>> wake backstop (BH-1034/BH-1060): a wake launch just ran this lane; the next cron tick within the window stands down. Fails open.
# shellcheck source=bin/lib/wake-lanes.sh
[ -r "$HARNESS/bin/lib/wake-lanes.sh" ] && . "$HARNESS/bin/lib/wake-lanes.sh"
command -v wake_backstop_skip >/dev/null 2>&1 && wake_backstop_skip review-prs "$PROJECT" && exit 0
# <<< wake backstop
# The reviewer's model is review_model's answer (REVIEW_MODEL, else this
# project's build.review model_routes row — BH-1510.1), never a literal here
# (BH-1507). Asked once per tick. Empty means no route anywhere: the resolver
# has written the ALERTS line, and no head is charged or reviewed this tick
# (see the check in front of the in-flight marker).
[ -r "$HARNESS/bin/lib/review-model.sh" ] && . "$HARNESS/bin/lib/review-model.sh"
RP_MODEL=""
command -v review_model >/dev/null 2>&1 && RP_MODEL=$(review_model "$HARNESS" "$PROJECT")
# The tick's model, kept: a trivial route (BH-2545) changes RP_MODEL for ONE head
# and the next head starts from this again.
RP_MODEL_TICK="$RP_MODEL"
# >>> review-prs state load (BH-977; tests/review-prs-state.bh-977-test.sh drives this block)
# A 0-byte or non-object state file reads as "nothing reviewed" and every jq
# write on it produces an empty file with rc 0, so it can never self-heal:
# every open head is re-reviewed on every tick (project-5, 2026-09-19: 304
# reviews, USD 328 in one day on unchanged shas). Reseed once, say so once.
# After the flock on purpose — only the tick that owns the lane repairs and
# alerts, never a second tick that is about to exit at the lock.
if ! jq -e 'type == "object"' "$STATE" >/dev/null 2>&1; then
  _SZ=$(stat -c%s "$STATE" 2>/dev/null || echo '?')
  # Evidence only when there is any: a 0-byte .bad tells nobody anything.
  [ -s "$STATE" ] && cp -f "$STATE" "$STATE.bad" 2>/dev/null
  echo '{}' > "$STATE"
  HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[$PROJECT] review-prs: state/$PROJECT.pr-reviews.json was not a JSON object (${_SZ} bytes) — reseeded to {}; each open head is reviewed once more this tick and dedupes from then on (BH-977)"
  unset _SZ
fi
# <<< review-prs state load
LOG="$HARNESS/logs/pr-reviews.log"
# Per-(PR, review) counter of refused dismissals — a permanent refusal has to
# page once instead of logging one line a tick for ever (#891 round 1, Nit 11).
RP_DISMISS_FAILS="$HARNESS/state/$PROJECT.dismiss-fails"
# THE RECEIPT. Every review this lane posts ends with this sentence and the head
# it judged, and BH-1017 makes that sentence the dedup of last resort: when the
# ledger file has lost an entry, the body already on the PR proves we paid for
# that head. Spelled ONCE, here, because the writer (the POSTED block) and the
# reader (rp_rehydrate) have to agree byte for byte — a second copy is how a
# dedup comes to look for text nothing posts any more.
RP_MARKER="Automated harness review (Fable) of"
# >>> review-prs state write (BH-977; tests/review-prs-state.bh-977-test.sh drives this block)
# THE ONLY WRITER OF $STATE. `jq … "$STATE" > tmp && mv` replaces the ledger
# with whatever jq printed — and on an empty or unparseable input jq prints
# nothing with rc 0, so the chain committed a 0-byte file and reported success.
# The result is checked BEFORE it replaces anything: empty or not an object is a
# refusal that keeps the file as it was. One log line per refusal, one ALERTS
# line per tick, and the tick carries on — a refused write costs one re-review,
# not a loop.
RP_WRITE_ALERTED=0
# BH-5284: review workers run in parallel, so the read-modify-write is held
# under $STATE.lock (fd 6, for this call only). Without it two workers that
# each read the file and wrote it back would drop each other's PR row.
rp_state_write() { # rp_state_write <jq args…>  (the filter and its --arg/--argjson; $STATE is appended here)
  local out tmpf="$STATE.tmp.$BASHPID"
  if { flock -w 60 6 2>/dev/null || true
       out=$(jq "$@" "$STATE" 2>/dev/null) && [ -n "$out" ] \
       && jq -e 'type == "object"' <<<"$out" >/dev/null 2>&1 \
       && printf '%s\n' "$out" > "$tmpf" && mv "$tmpf" "$STATE"
     } 6>>"$STATE.lock"; then
    return 0
  fi
  rm -f "$tmpf" 2>/dev/null
  echo "$(STAMP) [$PROJECT] review-prs: refused to write state/$PROJECT.pr-reviews.json — jq produced no object for: $*" >> "$LOG"
  if [ "$RP_WRITE_ALERTED" = 0 ]; then
    RP_WRITE_ALERTED=1
    HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[$PROJECT] review-prs: a state write was refused (jq produced no JSON object); the file was left as it was and the tick continued — see logs/pr-reviews.log (BH-977)"
  fi
  return 1
}
# <<< review-prs state write

# >>> review-prs freeze (BH-1017; tests/review-prs-gh-dedup-test.sh drives this)
# rp_freeze <num> <sha> [flag-key]
#   Stop buying THIS head, and say nothing about its quality.
#
# `sha` is what ends the re-buy: the loop's `DONE == SHA` check skips a head
# whose sha is on record. But `sha` is ALSO what arms merge_retry, which reads
# `verdict`, `served` and the merge counters off the SAME record — so a freeze
# written as `(.[$n] // {}) + {sha:$s}` carries a PREVIOUS head's `APPROVE` and
# `served:claude` onto the NEW sha, and the very next tick merges a head no
# reviewer ever read. (Probe on PR #1048: `gh pr merge --squash` fired with zero
# review calls, from a ledger seeded with an old-head APPROVE plus a capped
# attempt counter.) Both cap sites went through this shape — the pre-existing
# no-verdict cap and the in-flight cap added by BH-1017 — so the judgement
# fields are deleted here, once, rather than trusted to two call sites.
#
# The counters (`noverdict*`, `reviewing*`) survive on purpose: they are the
# evidence of WHY the head is frozen, and neither one can merge anything.
rp_freeze() {
  local num="$1" sha="$2" flag="${3:-}"
  rp_state_write --arg n "$num" --arg s "$sha" --arg f "$flag" \
    '.[$n] = ((.[$n] // {})
              | del(.verdict, .tier, .served, .rehydrated_from,
                    .merge_retries, .merge_retry_sha, .merge_retry_alerted_sha)
              + {sha:$s}
              + (if $f == "" then {} else {($f): true} end))'
}
# <<< review-prs freeze

# --- Coordination row (phase 4) ----------------------------------------------
# This lane spends real money — one Fable session per unreviewed head — and
# until now it spent it with no row anywhere: a kill mid-review left a PR with
# no verdict, no cost attribution and nothing to age. The claim is LAZY because
# this cron fires twice an hour per project and reviews nothing on most ticks;
# a row per tick would be ~380 empty rows a day across the fleet. It opens the
# first time a PR actually needs reviewing, beats while the session runs, and
# closes with the run's real rc.
#
# SPEND IS NOT WIRED HERE ON PURPOSE. JOB_ID is EXPORTED, and bin/agent-call.sh
# already posts each stage's dollars onto whatever row JOB_ID names — so this
# lane's cost lands on the row without this script computing a number a second
# way. Two spellings of one figure is how they come to disagree.
# shellcheck source=/dev/null
[ -r "$HARNESS/bin/jobs-client.sh" ] && . "$HARNESS/bin/jobs-client.sh"
# BH-7123: review levels. rl_prompt_note rides into the prompt; rl_cap demotes a
# finding that names no ALWAYS-BLOCK class to a NOTE before the verdict posts.
. "${HARNESS}/bin/lib/review-level.sh" 2>/dev/null || true
# BH-7667: the migration index lint (mil_tables, mil_scan, mil_merge). Without
# it no PR is linted and every review posts as the model and the cap left it.
. "${HARNESS}/bin/lib/migration-index-lint.sh" 2>/dev/null || true
# tg_holds (BH-4580): the tier_gate_mode row, read through setting_get above.
# A tree without the lib merges as before (the bin/lib/rb/pr.sh rule).
# shellcheck source=bin/lib/tier-gate.sh
[ -r "$HARNESS/bin/lib/tier-gate.sh" ] && . "$HARNESS/bin/lib/tier-gate.sh"

# --- BH-1132: the lane's one off-switch -------------------------------------
# flags/all-off, flags/lane-off-review-prs-<project>, or the D1 pause_flags row of the
# same name stops this tick (exit 0 — a paused lane is not a failure). With no
# flag and no row this returns immediately and the lane behaves exactly as it
# always has, and an unreachable worker fails OPEN to the last cached answer.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off review-prs <project>.
# shellcheck disable=SC1091
. "${HARNESS}/bin/lib/lane-gate.sh" 2>/dev/null || true
# The Sentry reporter (BH-5617): a pool capped below 3 by /tmp. Missing, the
# `command -v sentry_report` guard is false and nothing is reported.
# shellcheck disable=SC1091
. "${HARNESS}/bin/lib/sentry-report.sh" 2>/dev/null || true
# The ONE verdict reader (bin/lib/verdict-parse.sh, BH-1625). Missing, every
# verdict reads unknown — never APPROVE.
. "${HARNESS}/bin/lib/verdict-parse.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/lib/verdict-parse.sh" 2>/dev/null || true
# The same-patch test for the verdict replay below (BH-2310). Missing, nothing is
# replayed and every moved head is reviewed as before.
. "${HARNESS}/bin/lib/patch-same.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/lib/patch-same.sh" 2>/dev/null || true
# The trivial-diff route and the review-saving events (BH-2545). Missing, every
# head is reviewed by RP_MODEL and no saving is recorded, as before.
. "${HARNESS}/bin/lib/review-saving.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/lib/review-saving.sh" 2>/dev/null || true
# The "already bought?" read and the shared per-head guard key (BH-3930).
# Missing, every head is bought as before, under the inline key below.
# review_bought's outputs, empty when the library is absent (BH-4134).
RB_SOURCE=""; RB_WORD=""; RB_CLASS=""; RB_SERVED=""
. "${HARNESS}/bin/lib/review-bought.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/lib/review-bought.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit review-prs "$PROJECT"
# THE KNOBS, BELOW THE ENV LOAD (BH-1165). The gate above stops this lane; this
# is what lets a settings row reach its own unmodified ${KNOB:-default} reads.
# It is BELOW `set -a; . env/global.env` on purpose: above it, the env file
# re-assigns every name and the row silently loses. Fails open — with no row,
# nothing is exported and the lane behaves byte-for-byte as it does today.
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    review-prs "$PROJECT"
command -v verdict_prime >/dev/null 2>&1 && verdict_prime || true

# WHOSE PRs ARE OURS. The harness author SET (bin/lib/gh-pr-list.sh,
# HARNESS_PR_AUTHORS) — since bin/gh-token.sh went live a harness PR is authored
# by the GitHub App (`app/cromford`) as often as by the PAT, and a
# hardcoded login matches only half of them (2026-09-14, project-5 #696/#697).
# shellcheck source=bin/lib/gh-pr-list.sh
for _P in "$(dirname "$0")/lib/gh-pr-list.sh" "$HARNESS/bin/lib/gh-pr-list.sh"; do
  # shellcheck source=/dev/null
  [ -r "$_P" ] && { . "$_P"; break; }
done
# BH-1585: this lane's PR reads are REST (the open list, the body, the thread,
# the post-merge state and merge commit) — it ran on every box, per external PR,
# out of the GraphQL bucket. gh-rest-list.sh sources gh-rest.sh.
for _P in "$(dirname "$0")/lib/gh-rest-list.sh" "$HARNESS/bin/lib/gh-rest-list.sh"; do
  # shellcheck source=bin/lib/gh-rest-list.sh
  [ -r "$_P" ] && { . "$_P"; break; }
done

# The App identity for this lane's WRITES (bin/lib/gh-app-auth.sh). A bot verdict
# posted as `operator` is indistinguishable from the operator's own at a glance, which is
# half of why the parked PRs in BH-872 read as a human's refusal. Reads,
# merge_step, the block gate and the CI read keep today's token. An unarmed box
# gets rc 1 with the environment untouched, so it behaves byte for byte as before.
# shellcheck source=bin/lib/gh-app-auth.sh
for _A in "$(dirname "$0")/lib/gh-app-auth.sh" "$HARNESS/bin/lib/gh-app-auth.sh"; do
  # shellcheck source=/dev/null
  [ -r "$_A" ] && { . "$_A"; break; }
done
type gh_auth_for >/dev/null 2>&1 || { gh_auth_for() { return 1; }; gh_auth_reset() { return 0; }; }

# A REVIEW THAT FELL TO THE PAT IS SAID, NOT SILENT (BH-8466). On an App-armed
# box a post whose GH_TOKEN after gh_auth_for is not an installation token
# (ghs_) goes out as the operator login: the App could not see the repo. The
# log gets one line per post. ALERTS.log gets one warn line per project per UTC
# day, keyed by one overwritten marker file (no growth, so no retention job).
# An unarmed box runs on the PAT by design and is silent. The ALERTS line is
# written before the marker, so a failed marker write repeats it, never hides it.
rp_pat_post_note() { # call right after gh_auth_for in the post step; always rc 0
  command -v gh_auth_armed >/dev/null 2>&1 && gh_auth_armed || return 0
  case "${GH_TOKEN:-}" in ghs_*) return 0 ;; esac
  local f="$HARNESS/state/review-prs-pat-alert/$PROJECT" day
  day=$(date -u +%F)
  echo "$(STAMP) [$PROJECT] #$NUM @${SHA:0:7} github auth: default PAT — the App token did not answer for $SLUG, so this review posts as the operator login" >> "$LOG"
  [ "$(cat "$f" 2>/dev/null)" = "$day" ] && return 0
  HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" --severity warn --id "review-prs-pat-$PROJECT" --project "$PROJECT" \
    "[$PROJECT] review-prs: github auth: default PAT — reviews on $SLUG post as the operator login, not the App (first today: #$NUM)" >/dev/null 2>&1 || true
  mkdir -p "${f%/*}" 2>/dev/null && printf '%s\n' "$day" > "$f" 2>/dev/null
  return 0
}

# Is this login the REVIEWING App itself (BH-2119)? The one PR the App cannot
# approve is its own: GitHub 422s a self-approve. rc 0 = yes, OR the App's login
# cannot be read (no lib, no slug or name in env/github-app.env): unknown keeps
# the default credential, which is what every APPROVE used before, so it never
# guesses its way into a new 422.
rp_author_is_reviewer_app() { # rp_author_is_reviewer_app <login>
  local app
  command -v _hpl_app_login >/dev/null 2>&1 || return 0
  app=$(_hpl_app_login)
  [ -n "$app" ] || return 0
  [ "$(_hpl_bare "${1:-}")" = "$(_hpl_bare "$app")" ]
}

# The merge-queue provider probe, from the conductor's lib (sourced, never
# copied). It decides whether this script's own `gh pr merge` below would feed a
# queue, bypass one, or do what it has always done. A tree without the lib
# answers "no queue", which is exactly today's behaviour.
# shellcheck source=bin/lib/merge-conductor-lib.sh
# BH-1295 REVIEW FIX (F1b, drain review): merge_retry()'s state+mergeStateStatus
# re-check is also this lane's read of mc_pr_view now, so a box missing the
# lib must degrade the same way it always has (the fact is unreadable this
# tick, not permanently 75) rather than silently killing the whole retry.
# `return 75` here emptied ST on every no-lib box, `case "OPEN CLEAN"` never
# matched, and the retry never fired. The fallback re-derives the same
# STATE/MSTATE object over `gh api` — REST, never GraphQL (the standing fleet
# rule gh_rest exists for: a GraphQL rate limit kills a lane mid-session, and
# a no-lib fallback is exactly the path firing when things are already
# degraded) — the same derivation bin/lib/mc/classify.sh's MC_REST_NORM uses.
if [ -r "$HARNESS/bin/lib/merge-conductor-lib.sh" ]; then . "$HARNESS/bin/lib/merge-conductor-lib.sh"
else
  mc_queue_conductor_only() { return 1; }
  mc_pr_queued() { return 1; }
  mc_pr_view() { # mc_pr_view <pr-url> <jq-expr> -- no lib: gh api REST, translated
    local url="${1:-}" slug num j
    slug=$(sed -E 's|https://github.com/([^/]+/[^/]+)/pull/.*|\1|' <<<"$url")
    num=$(grep -oE '[0-9]+$' <<<"$url")
    [ -n "$slug" ] && [ -n "$num" ] || return 75
    j=$(gh api "repos/$slug/pulls/$num" \
          -q '{STATE:(if (.merged_at // null) != null then "MERGED" elif .state == "open" then "OPEN" else "CLOSED" end), MSTATE:((.mergeable_state // "unknown")|ascii_upcase), base:{ref:(.base.ref // null)}}' 2>/dev/null) || return 75
    [ -n "$j" ] || return 75
    printf '%s' "$j" | jq -r "${2:-.}" 2>/dev/null || return 75
  }
fi
# Judge provenance comes with that lib (bin/lib/review-provenance.sh, sourced by
# it). A tree without either keeps the literal rule this script shipped with.
type rp_prov_is_claude >/dev/null 2>&1 || { rp_prov_is_claude() { [ "${1:-}" = claude ]; }
  rp_out_prov() { head -1 "${1:-}.runner" 2>/dev/null || printf 'claude'; }; }
# The CI read's second credential (bin/lib/gh-ci-read.sh). The default token
# answers first and nothing about that read changed; a 403 on actions/runs — the
# project-2 box's PAT, which is why #294/#488/#489 deferred for days — retries
# once on a READ-ONLY App token. A tree without the lib gets a plain `gh api`,
# byte for byte the read this script has always done.
# shellcheck source=bin/lib/gh-ci-read.sh
if [ -r "$HARNESS/bin/lib/gh-ci-read.sh" ]; then . "$HARNESS/bin/lib/gh-ci-read.sh"
else gh_ci_api() { shift; GH_CI_READ_TOKEN=default; gh api "$@"; }; fi
# The live-CI reader and the re-review request marker (BH-1794,
# bin/lib/fixround-preflight.sh). A tree without the lib reviews exactly as it
# did before: no live-CI block in the prompt, no marker honoured.
# shellcheck source=bin/lib/fixround-preflight.sh
[ -r "$HARNESS/bin/lib/fixround-preflight.sh" ] && . "$HARNESS/bin/lib/fixround-preflight.sh"
# >>> gh default auth
# THIS LANE'S FIVE RAW `gh` CALLS (BH-470, #424): `pr merge`, `pr view`,
# `pr diff` and two `pr review`s. They went out on the fleet PAT — one 5000/h
# bucket shared by every box — and now go out on this project's App installation
# token instead. BELOW the gh-ci-read.sh source on purpose: that lib captures the
# DEFAULT token for its own fallback rung (`GH_CI_READ_TOKEN=default`), and
# arming above it would silently redefine what "default" means there.
# shellcheck source=bin/lib/gh-app-auth.sh
[ -r "$HARNESS/bin/lib/gh-app-auth.sh" ] && . "$HARNESS/bin/lib/gh-app-auth.sh"
# shellcheck source=bin/lib/gh-limit-logger.sh
[ -r "$HARNESS/bin/lib/gh-limit-logger.sh" ] && . "$HARNESS/bin/lib/gh-limit-logger.sh"
if command -v gh_default_auth_for_project >/dev/null 2>&1; then
  gh_default_auth_for_project "$PROJECT" || true
fi
# <<< gh default auth
REVIEW_RC=0
# >>> review-prs per-review row (BH-1064; tests/review-prs-d1-row.bh-1064-test.sh drives this block)
# ONE ROW PER PAID REVIEW, KEYED ON THE HEAD IT BOUGHT. This used to be one row
# per TICK with an EMPTY key, reused by every PR the tick reviewed. That was
# harmless while the row only carried spend, and wrong the moment it carries
# artifacts: the worker upserts them on `(job_id, artifact_kind)`
# (worker/jobs/src/index.js, `ON CONFLICT(job_id, artifact_kind) DO UPDATE`), so
# a tick that reviewed #7 and then #9 would leave ONE pr_url and ONE verdict —
# #9's — with #7's overwritten. `/api/verdict?pr=…/pull/7` would 404 and the
# dedup this ticket exists to build would miss every PR but the last of each
# tick; worse, a reader that DID resolve the row would read another PR's
# verdict against this PR's head.
#
# The lane string is unchanged, so the budget catalog resolves exactly as it
# does today; only the KEY is new, and it is the ticket's own spelling
# (`review/<project>/<num>@<sha>`): a re-review of the same head is the same
# work, a new head is new work.
#
# A refused or failed claim leaves JOB_ID empty and the review is bought anyway
# — fail-open, like every other ledger read in this file. The cost of failing
# open is one row that records nothing; the cost of failing closed is a lane
# that reviews nothing during a worker outage.
review_claim() {   # review_claim <num> <sha> — one row per paid review
  local num="${1:-}" sha="${2:-}"
  command -v job_lane_open >/dev/null 2>&1 || return 0
  # Close the row the PREVIOUS PR of this tick opened, with that review's own
  # rc, before opening this one: two open rows on one lane both beat, and
  # bin/agent-call.sh bills whatever JOB_ID names.
  if [ -n "${JOB_ID:-}" ] && command -v job_lane_close >/dev/null 2>&1; then
    job_lane_close "$REVIEW_RC" "review-prs $PROJECT" >/dev/null 2>&1 || true
  fi
  REVIEW_RC=0
  job_lane_open "review/$PROJECT/claude" "review/$PROJECT/$num@$sha" review \
    "$(jq -nc --arg l "review-prs" --arg s "$SLUG" --arg n "$num" --arg h "$sha" \
        '{label:$l,repo:$s,pr:$n,head:$h}' 2>/dev/null)" >/dev/null 2>&1 || true
  return 0
}
# <<< review-prs per-review row
trap 'command -v job_lane_close >/dev/null 2>&1 && job_lane_close "$REVIEW_RC" "review-prs $PROJECT"' EXIT

# --- the merge step, one copy --------------------------------------------------
# This arm used to live inline in the APPROVE path. It is a function now because
# a LATER TICK has to be able to run it again (merge_retry below) — and a second
# reading of "may this PR merge" is how two lanes come to disagree about one PR.
# The holds are the same three switches, spelled once:
# >>> review-prs merge (tests/block-gate-lanes-test.sh drives this block)
# BH-5914: the conductor-verdict rule, sourced inside the block the suites run.
# shellcheck source=bin/lib/conductor-verdict.sh
[ -r "$HARNESS/bin/lib/conductor-verdict.sh" ] && . "$HARNESS/bin/lib/conductor-verdict.sh"
hold_conductor_owns_merges() { command -v flag_active >/dev/null 2>&1 \
  && flag_active conductor-owns-merges || [ -f "$HARNESS/flags/conductor-owns-merges" ]; }
# The fleet kill switch, or this project's own toggle (#2322).
# BH-4153: rows through flag_active (an unreadable one is ON); the file only
# when no client is loaded.
hold_automerge_disabled() { local n; for n in automerge-disabled "automerge-disabled-$PROJECT"; do
  if command -v flag_active >/dev/null 2>&1; then flag_active "$n" && return 0; elif [ -f "$HARNESS/flags/$n" ]; then return 0; fi; done; return 1; }
hold_paused_project() { if command -v flag_active >/dev/null 2>&1; then flag_active "paused-$PROJECT"; else [ -f "$HARNESS/flags/paused-$PROJECT" ]; fi; }
# rp_base_hold <num> — rc 0 (held, logged, RP_FENCED=1) unless the PR's base
# reads as ${BASE_BRANCH:-main} (BH-1285 AC3). A stacked PR lands through its
# parent, never straight into its parent branch from here. An unreadable base is
# "not this pass", fail-closed. RP_FENCED=1 hands merge_retry its attempt back,
# the same as the ticket fence: a stacked head waiting on its parent is a hold,
# not a refusal, so it never spends the retry budget or pages "needs a look".
# BH-1646: but it must not wait SILENTLY. Each hold counts against (PR, head) in
# the per-PR state record; at REVIEW_BASE_HOLD_ALERT_TICKS consecutive holds
# (default 6, <=0 disables) ONE ALERTS line names the PR, head and base. A new
# head starts from 0. No readable $STATE or no rp_state_write: no counting, the
# hold itself unchanged. The alerted marker is stamped only after the line.
rp_base_hold() {
  local b sha="${2:-}" rec psha pcnt palert n
  b=$(mc_pr_view "https://github.com/$SLUG/pull/$1" '.base.ref' 2>/dev/null) || b=""
  [ -n "$b" ] && [ "$b" = "${BASE_BRANCH:-main}" ] && return 1
  echo "$(STAMP) [$PROJECT] #$1 APPROVE left unmerged: base is ${b:-unreadable}, not ${BASE_BRANCH:-main} — a stacked PR lands through its parent" >> "$LOG"
  RP_FENCED=1
  [ -n "$sha" ] && [ -r "${STATE:-}" ] && command -v rp_state_write >/dev/null 2>&1 || return 0
  rec=$(jq -r --arg n "$1" '[.[$n].base_hold_sha // "-", (.[$n].base_hold_count // 0 | tostring), .[$n].base_hold_alerted_sha // "-"] | join(" ")' "$STATE" 2>/dev/null) || return 0
  read -r psha pcnt palert <<<"$rec"
  case "$pcnt" in ''|*[!0-9]*) pcnt=0 ;; esac
  [ "$psha" = "$sha" ] || { pcnt=0; palert=-; }
  pcnt=$((pcnt+1))
  rp_state_write --arg n "$1" --arg s "$sha" --argjson c "$pcnt" --arg a "${palert#-}" \
    '.[$n] = ((.[$n] // {}) + {base_hold_sha:$s, base_hold_count:$c, base_hold_alerted_sha:$a})' || return 0
  n=${REVIEW_BASE_HOLD_ALERT_TICKS:-6}; case "$n" in ''|*[!0-9]*) n=6 ;; esac
  if [ "$n" -gt 0 ] && [ "$pcnt" -ge "$n" ] && [ "$palert" != "$sha" ]; then
    HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[$PROJECT] review-prs: #$1 @${sha:0:7} APPROVED but base-held $pcnt ticks: base is ${b:-unreadable}, not ${BASE_BRANCH:-main}. A stacked PR waits on its parent; retarget or land the parent: https://github.com/$SLUG/pull/$1"
    rp_state_write --arg n "$1" --arg s "$sha" '.[$n] = ((.[$n] // {}) + {base_hold_alerted_sha:$s})' || true
  fi
  return 0
}

# rp_ticket_fence <num> <sha> [author] — rc 0 when the ticket or the PR's author
# says this lane must not merge it (BH-1558), and it has logged the one line
# that says why. The two questions every other merge lane already asks, from
# the ONE library that answers them (sourced here, inside the block the suites
# drive, for the reason gh-pr-merge.sh is sourced below):
#   * a HELD ticket's PR does not merge (to_lane_hold, BH-1526);
#   * a LEAD-authored PR merges only on a lead/human MERGE row standing on this
#     head (to_lane_lead_hold over bin/lib/verdicts.sh, BH-1525) — this lane's
#     APPROVE is information, never a clearance. #1547 merged on exactly that.
# Unreadable is "not this pass" in both. RP_FENCED=1 tells merge_retry the tick
# was not a merge attempt, so a lead PR waiting on its lead never spends the
# retry budget and pages "needs a look".
#
# AN UNREADABLE FENCE FEEDS THE BLOCK GATE'S OUTAGE STREAK (#1603 review F3).
# The fence stands AHEAD of bg_review_hold, so on a worker outage this lane no
# longer reaches the gate that used to count the unreadable ticks and alert at
# K. The same counter is fed here, with the same `verdicts` reason when the
# verdicts table is what failed (one lane-wide alert per outage window), so the
# fence cannot swallow the one loud signal this lane had. A lead PR merely
# WAITING on its lead is not an outage and stays silent.
#
# RP_LEAD_CLEARED=1 when the PR is a lead PR cleared by a lead row on $SHA: the
# merge below is pinned to that head, and a failed merge is NOT handed to the
# box merge queue, which lands later, on whatever head then stands, and asks no
# lead question (#1603 review F1b).
# shellcheck source=bin/lib/ticket-ownership.sh
command -v to_lane_hold >/dev/null 2>&1 \
  || { [ -r "$HARNESS/bin/lib/ticket-ownership.sh" ] && . "$HARNESS/bin/lib/ticket-ownership.sh"; }
rp_ticket_fence() { # rp_ticket_fence <num> <sha> [author]
  local rc
  RP_LEAD_CLEARED=0
  command -v to_lane_hold >/dev/null 2>&1 || return 1
  if to_lane_hold "$PROJECT" "$SLUG" "$1" "$LOG"; then RP_FENCED=1; return 0; fi
  # to_lane_lead_fence feeds the streak on rc 2 (BH-1606: a lead-row outage is
  # one lane-wide alert, like a verdicts outage, not one per PR).
  to_lane_lead_fence "$PROJECT" "$SLUG" "$1" "$2" "${3:-}" "$LOG"; rc=$?
  # to_lane_lead_hold always sets both (never env knobs: no default read here).
  if [ "$rc" = 1 ]; then RP_LEAD_CLEARED="$TO_LEAD_CLEARED"; return 1; fi
  RP_FENCED=1
  return 0
}

# hold_main_red <num> <sha> — rc 0 while this repo's main is red and the PR is
# not one of the two ways out (BH-945). This lane is the leak the ticket names:
# it merges any operator-authored APPROVE, and on 2026-09-18 it did that straight
# through a hub freeze the merge conductor was logging every five minutes.
# MERGED stays `no`, so the approved-head-nobody-lands retry below re-asks on
# the next tick and the hold ends by itself when the flag clears.
hold_main_red() {
  local num="$1" sha="$2"
  command -v main_red_hold >/dev/null 2>&1 || return 1
  main_red_hold "$PROJECT" "$SLUG" "$num" "https://github.com/$SLUG/pull/$num" "$sha" || return 1
  echo "$(STAMP) [$PROJECT] #$num APPROVE left unmerged, HELD by the main-red freeze: $SLUG main is red (flags/${MRG_FLAG:-main-red}) — it merges as soon as the flag clears; a PR labelled ${MC_MAIN_RED_LABEL:-fix-main-red} or one whose whole diff is test files still lands" >> "$LOG"
  return 0
}

# hold_factory_stop <num> — rc 0 while settings row switch.factory-stop is on
# (BH-3687): nothing merges while the factory is stopped, and this lane is a
# direct merge path. The FIRST hold, so a stopped tick buys no other gate's
# read. MERGED stays `no` and merge_retry hands the attempt back, so the APPROVE
# lands on a later tick once the switch is off. Sourced here, inside the block
# the suites drive, like gh-pr-merge.sh below. No lib or no readable row: rc 1.
# shellcheck source=bin/lib/factory-stop.sh
command -v factory_stopped >/dev/null 2>&1 \
  || { [ -r "$HARNESS/bin/lib/factory-stop.sh" ] && . "$HARNESS/bin/lib/factory-stop.sh" 2>/dev/null; }
hold_factory_stop() {
  command -v factory_stopped >/dev/null 2>&1 || return 1
  factory_stopped || return 1
  echo "$(STAMP) [$PROJECT] #$1 APPROVE left unmerged, HELD by factory-stop: switch.factory-stop is on — it merges on a later tick after bin/factory-stop.sh off" >> "$LOG"
  return 0
}

# bg_review_hold <num> <sha> — rc 0 when a human BLOCK on the thread holds this
# merge (BH-762). The APPROVE below was written by a reviewer reading a diff;
# the thread is where a PERSON says no, and until this gate landed no merge path
# read it. The PR conversation and the PR's review bodies are the sources — the
# four projects this script serves keep their tickets on an in-app board, so
# there is no GitHub issue thread to read. A tree without the lib holds nothing.
bg_review_hold() {
  local num="$1" sha="$2" url out rc
  command -v bg_scan >/dev/null 2>&1 || return 1
  url="https://github.com/$SLUG/pull/$num"
  out=$(bg_scan "$SLUG" "$num" "$url" "$sha"); rc=$?
  [ "$rc" = 0 ] && return 1
  if ! bg_enforce; then
    echo "$(STAMP) [$PROJECT] #$num block gate WARN-ONLY (BLOCK_GATE_ENFORCE=0): $(bg_reason "$rc" "$out" "$sha") — merging as it would have before the gate" >> "$LOG"
    return 1
  fi
  if [ "$rc" = 1 ]; then
    echo "$(STAMP) [$PROJECT] #$num APPROVE left unmerged, MERGE_REFUSED block-gate: $(bg_why "$out" "$sha") — it merges when a newer commit lands or that author clears it" >> "$LOG"
    bg_refuse "$SLUG" "$num" "$url" "$sha" "$out" review-prs \
      || echo "$(STAMP) [$PROJECT] #$num block gate could not post the refusal comment — the merge is refused either way and the next tick retries the post" >> "$LOG"
  else
    # BH-1525 (review F3): a tick the gate could not judge is not a merge
    # ATTEMPT — merge_retry reads this and hands the attempt back, the same
    # rule the main-red freeze follows, so an outage cannot spend the budget.
    RP_BG_UNREAD=1
    echo "$(STAMP) [$PROJECT] #$num not merged this tick: block gate could not read $out — nothing written, the next tick tries again" >> "$LOG"
  fi
  return 0
}

merge_step() { # merge_step <num> <sha> <served-by> [author]; sets MERGED=yes|no|queued
  local NUM="$1" SHA="$2" SERVED="$3" RP_AUTHOR="${4:-}" RP_STATE RP_INQ MSHA EXTDIR RP_MERR=""
  MERGED=no; RP_FENCED=0; RP_LEAD_CLEARED=0
  # Per the operator 2026-07-27 (second directive): APPROVE merges regardless of tier —
  # "in reality I won't be not approving those anyway". Kill switch stays:
  # flags/automerge-disabled blocks all review-driven merges.
  # Judge provenance (2026-08-03): an APPROVE authored by a fallback/survival
  # runner (not Fable-on-claude) never auto-merges and never enters the merge
  # queue — it posts and alerts, and a later head (a fresh review on the primary
  # lane) is what unblocks it. `claude-via-openrouter` is NOT a fallback in that
  # sense (2026-09-16, bin/lib/review-provenance.sh): a Claude model read the
  # diff, it just reached it through the tier-3 lane.
  if ! rp_prov_is_claude "$SERVED"; then
    echo "$(STAMP) [$PROJECT] #$NUM APPROVE served by fallback lane '$SERVED' — auto-merge withheld (judge provenance)" >> "$LOG"
    "$HARNESS/bin/beat.sh" "$(jq -nc --arg p "$PROJECT" --arg akey "provenance:$PROJECT:$NUM:$SHA" \
      --arg l "PR #$NUM reviewed APPROVE, but on the $SERVED fallback lane (Fable lane was down) — auto-merge withheld. Merge yourself when ready; a new push gets a fresh review." \
      '{kind:"fleet_alert",project:$p,akey:$akey,line:$l}')" >/dev/null 2>&1 || true
  # BH-3687: the factory stop. hold_factory_stop has logged the one line.
  elif hold_factory_stop "$NUM"; then
    :
  # flags/conductor-owns-merges (docs/MERGE-CONDUCTOR.md section 9): while it is
  # on, bin/merge-conductor.sh is the fleet's only merger, so this reviewer stays
  # a REVIEWER — it posts the verdict and lands nothing, and it does NOT enqueue
  # on the box queue either (that queue is stood down by the same flag). NOTE for
  # whoever flips it: on a Mergify repo the conductor's external enqueue
  # (xe_project, bin/lib/mc/external-enqueue.sh) asks Mergify to queue an
  # approved external PR; on any other repo nothing lands one while it is on.
  elif hold_conductor_owns_merges; then
    echo "$(STAMP) [$PROJECT] #$NUM APPROVE left unmerged: flags/conductor-owns-merges is on — the merge conductor owns merges" >> "$LOG"
  # MERGIFY: the same stand-down, decided by the REPO instead of by a flag. On a
  # Mergify repo `gh pr merge` below does not feed the queue — it merges around
  # it, onto main, unbatched and unverified against the entries ahead. The
  # conductor is the only actor that knows how to label a PR into that queue, so
  # this reviewer hands it over. (Under GitHub's NATIVE queue the same call IS
  # the enqueue, which is why this keys on mc_queue_conductor_only and not on
  # mc_queue_enabled.)
  elif mc_queue_conductor_only "$SLUG"; then
    echo "$(STAMP) [$PROJECT] #$NUM APPROVE left unmerged: $SLUG is behind a Mergify merge queue — the merge conductor's external enqueue asks Mergify to queue it (bin/lib/mc/external-enqueue.sh); a direct merge here would BYPASS the queue" >> "$LOG"
  # The kill switch, now reconciled from its DB row first (phase 3's flag rule):
  # flag_active syncs flags/automerge-disabled and then tests the FILE, so a
  # console pause reaches this merge path and a 404 or an outage leaves the box
  # deciding exactly as it does today. No client, no change: the bare file test.
  # It is asked BEFORE the block gate on purpose: while the fleet is paused
  # nothing merges anyway, and a gate ahead of it would spend two GitHub reads
  # per PR per tick and tell a client "it merges when a newer commit is pushed"
  # about a merge that was never going to happen.
  elif hold_automerge_disabled; then
    :
  # BH-1285: per-project pause flag. Same fail-open/file-fallback shape as the
  # fleet-wide kill switch above, but logged because this is project-scoped.
  elif hold_paused_project; then
    echo "$(STAMP) [$PROJECT] #$NUM APPROVE left unmerged: flags/paused-$PROJECT is on — auto-merge paused for this project" >> "$LOG"
  # BH-1558: a HELD ticket, or a lead PR with no lead MERGE row on this head.
  # rp_ticket_fence has already logged the one line that says so. Ahead of the
  # block gate so a lead PR waiting on its lead never buys the thread reads.
  elif rp_ticket_fence "$NUM" "$SHA" "$RP_AUTHOR"; then
    :
  # BH-762: a human BLOCK on the thread, newer than this head and uncleared.
  # bg_review_hold has already logged it and posted the one comment that says so.
  elif bg_review_hold "$NUM" "$SHA"; then
    :
  # BH-945: this repo's main is red and this PR is not the way out of it.
  # hold_main_red has already logged the one line that says so. Last of the
  # holds, so a PR stopped by an earlier one never buys this gate's read.
  elif hold_main_red "$NUM" "$SHA"; then
    :
  # BH-1285 AC3: the direct merge below lands on whatever base the PR names.
  # rp_base_hold has already logged the one line that says so. Last hold, so
  # the base read is bought only by a PR every other gate would merge.
  elif rp_base_hold "$NUM" "$SHA"; then
    :
  # BH-5914: the merge conductor's verdict for this head (project-6 #27: the
  # conductor refused a head and a second lane merged it). cv_hold has logged
  # the MERGE_REFUSED line; RP_FENCED=1 hands merge_retry its attempt back, as
  # the other holds do, so a held head is not counted toward the retry alert.
  elif command -v cv_hold >/dev/null 2>&1 && cv_hold "$SLUG" "$NUM" "$SHA" "$LOG" "$(STAMP) [$PROJECT] #$NUM"; then
    RP_FENCED=1
  else
    # THE METHOD COMES FROM THE REPO (BH-1313/BH-1428). This lane merges from a
    # POOL box, which does not source the ladder anywhere else, so the source
    # line lives HERE, inside the block the suites extract and run — a sourcing
    # line outside it is one nothing drives. `--squash` stands when the lib is
    # absent, which is this line byte for byte as it was.
    # shellcheck source=bin/lib/gh-pr-merge.sh
    [ -r "$HARNESS/bin/lib/gh-pr-merge.sh" ] && . "$HARNESS/bin/lib/gh-pr-merge.sh"
    RP_MFLAG=--squash
    command -v gh_pr_merge_flag >/dev/null 2>&1 \
      && RP_MFLAG=$(gh_pr_merge_flag "$SLUG" "$NUM" "$LOG" "review-prs #$NUM")
    # PINNED TO THE HEAD THIS LANE JUDGED (BH-1558, #1603 review F1): the APPROVE,
    # the block gate and the lead verdict were all read on $SHA, and a push since
    # then is a head none of them read. GitHub refuses the pinned merge, and the
    # next head gets its own review.
    RP_PIN=(); [ -n "$SHA" ] && RP_PIN=(--match-head-commit "$SHA")
    # gh's refusal is KEPT (BH-1606): "Head branch was modified" is GitHub saying
    # the pin did its job, and the arm below must not hand that PR to the box
    # queue, which would land the new head with no pin and no review of it.
    RP_MERR=$(gh pr merge "$NUM" -R "$SLUG" "$RP_MFLAG" ${RP_PIN[@]+"${RP_PIN[@]}"} 2>&1 >/dev/null) || true
    sleep 5
    # On a repo behind GitHub's native merge queue this call ENQUEUED the PR: it
    # is still OPEN, so the old read said merged=no and the PR was pushed onto
    # the box merge queue, which would try to land it again every 20 minutes.
    # Queued is its own answer, and the merge conductor settles it. The question
    # goes through the PROVIDER-AWARE reader so a PR sitting in a Mergify queue
    # (which never sets isInMergeQueue) gets the same answer.
    RP_STATE=$(mc_pr_view "https://github.com/$SLUG/pull/$NUM" .STATE 2>/dev/null)
    RP_INQ=false
    if [ "${RP_STATE:-}" = "MERGED" ]; then MERGED=yes
    elif mc_pr_queued "https://github.com/$SLUG/pull/$NUM"; then RP_INQ=true; fi
    if [ "$MERGED" = yes ]; then
      # Same post-merge prod gate tier-1 builds get: polls the deployment, fires
      # the project deploy hook if none appears (external authors may not trigger
      # auto-deploy), smoke-checks prod, alerts on failure.
      RP_PRJ=""; gh_rest_var RP_PRJ GET "repos/$SLUG/pulls/$NUM" 2>/dev/null || RP_PRJ=""
      MSHA=$(jq -r '.merge_commit_sha // empty' <<<"${RP_PRJ:-null}" 2>/dev/null)
      EXTDIR="$HARNESS/builds/ext-$PROJECT-pr$NUM"; mkdir -p "$EXTDIR"
      [ -n "$MSHA" ] && "$HARNESS/bin/deploy-request.sh" "$PROJECT" "$SLUG" "$MSHA" "$EXTDIR"
    elif [ "${RP_INQ:-}" = true ]; then
      MERGED=queued
      echo "$(STAMP) [$PROJECT] #$NUM enqueued in $SLUG's merge queue — not merged yet; the merge conductor settles it (no box-queue entry)" >> "$LOG"
    elif [ "${RP_LEAD_CLEARED:-0}" = 1 ]; then
      # BH-1558 F1b: a lead PR cleared on $SHA whose pinned merge did not land
      # (the head moved, a check is pending, a conflict). The box queue would
      # land it later on whatever head then stands and asks no lead question.
      echo "$(STAMP) [$PROJECT] #$NUM lead PR cleared on ${SHA:0:12} but the pinned merge did not land — left for the lead (no box-queue entry: a newer head needs its own lead verdict)" >> "$LOG"
    elif grep -qi 'head branch was modified' <<<"${RP_MERR:-}"; then
      # BH-1606: the branch moved after this lane judged $SHA. The new head gets
      # its own review on the next tick; the box queue would land it unread.
      echo "$(STAMP) [$PROJECT] #$NUM pinned merge refused: the head moved after the review of ${SHA:0:12} (Head branch was modified) — left for the re-review of the new head (no box-queue entry)" >> "$LOG"
    else
      # Wave 4a: approved external PR that would not merge cleanly -> queue
      mkdir -p "$HARNESS/state/merge-queue/$PROJECT"; touch "$HARNESS/state/merge-queue/$PROJECT/$NUM"
      # BH-1026.2: and this is the ONE place in this lane that has decided the
      # PR belongs on the box queue. Every hold above — fallback provenance,
      # conductor-owns-merges, Mergify, automerge-disabled, the block gate,
      # main-red — has been asked and answered, and the two arms beside this one
      # are "already merged" and "already in the repo's own queue". The verdict
      # blocks below enqueue the ROW on this flag and on nothing else: on the
      # bare verdict they would put a row on a PR this lane just merged, which
      # bin/merge-queue.sh records as `dropped` — a PR that landed, written into
      # the ledger as not landed.
      RP_MQ_WANT=1
      (setsid "$HARNESS/bin/merge-queue.sh" "$PROJECT" </dev/null >/dev/null 2>&1 &)
    fi
  fi
}
# <<< review-prs merge

# --- the approved head nobody lands (the operator, 2026-09-14) -------------------------
# example-org/project-2 #294/#488/#489 sat approved-but-unmerged for days.
# Each one's FIRST review answered APPROVE with merged=no because a hold was in
# force that minute (flags/automerge-disabled, held during a hand-kicked review).
# From the next tick on the recorded sha matched the head, so the loop below
# `continue`d before it reached any merge code — and an approved-on-head, OPEN,
# CLEAN external PR is invisible to every other lane in the fleet: the merge
# conductor and the hub's merge sweep both list harness-authored PRs only. The
# verdict was on record and nothing in the harness owned the merge.
#
# So a recorded APPROVE on the CURRENT head is a CLAIM this lane re-checks every
# tick rather than a fact it filed once: PR still OPEN, mergeStateStatus CLEAN,
# no hold in force -> run the same merge step a fresh APPROVE runs. Bounded: one
# attempt per PR per tick, REVIEW_MERGE_RETRY_MAX (6) attempts per head, then one
# ALERT — a PR that refuses six times needs a person, not a seventh `gh pr merge`.
# Off with REVIEW_MERGE_RETRY=0.
# >>> review-prs merge-retry (tests/main-red-box-freeze.bh-945-test.sh drives this block)
merge_retry() { # merge_retry <num> <sha> [author]
  local NUM="$1" SHA="$2" RP_WHO="${3:-}" V SERVED N ALERTED ST
  [ "${REVIEW_MERGE_RETRY:-1}" = 0 ] && return 0
  V=$(jq -r --arg n "$NUM" '.[$n].verdict // ""' "$STATE")
  [ "$V" = "APPROVE" ] || return 0
  # BH-2545: an APPROVE from the trivial route's cheap model is advisory and is
  # never merged, on this tick or a later one; the main loop re-reviews that head
  # on the full model. A replay onto a new head carries the flag with the row.
  [ "$(jq -r --arg n "$NUM" '.[$n].trivial // ""' "$STATE")" = 1 ] && return 0
  # Judge provenance is a hold here exactly as it is above. Records written
  # before this change carry no `served`; they read as the primary lane, which
  # is what they overwhelmingly are — a withheld APPROVE alerted at the time and
  # from now on the verdict write records the lane, so it can never be guessed.
  # A REUSED row is never guessed (BH-4134): one with `reused_from` and no
  # `served` was written before the reuse recorded its lane, and reads as
  # `reused-unknown`, which is held.
  SERVED=$(jq -r --arg n "$NUM" '.[$n] | if (.reused_from // "") != "" and .served == null then "reused-unknown" else (.served // "claude") end' "$STATE")
  rp_prov_is_claude "$SERVED" || return 0
  # BH-4580: tier_gate_mode=human holds a tier-2 APPROVE here exactly as at the
  # fresh verdict. Silent and uncounted like the switches below: a hold is not an
  # attempt, so it never spends REVIEW_MERGE_RETRY_MAX.
  command -v tg_holds >/dev/null 2>&1 \
    && tg_holds "$PROJECT" "$(jq -r --arg n "$NUM" '.[$n].tier // "?"' "$STATE")" && return 0
  # The holds return SILENTLY: each is a deliberate switch, and a line per PR
  # per tick while a fleet-wide pause is on is noise, not news.
  # BH-3687: a factory-stopped tick is not an attempt either, for the reason
  # the main-red freeze below gives.
  command -v factory_stopped >/dev/null 2>&1 && factory_stopped && return 0
  hold_conductor_owns_merges && return 0
  mc_queue_conductor_only "$SLUG" && return 0
  hold_automerge_disabled && return 0
  # BH-1285: the project pause is the same kind of switch, so it is silent here
  # for the same reason — counted, a pause longer than six ticks would spend the
  # budget, alert "needs a look" and strand the APPROVE when the pause lifts.
  hold_paused_project && return 0
  # The main-red freeze holds here too (BH-945). The counter below is a budget
  # of merge ATTEMPTS and a frozen tick is not one: counted, six frozen ticks
  # would spend it, alert "needs a look" and stop retrying the head, so the
  # APPROVE would never land when main went green — the opposite of what
  # hold_main_red promises. Silent like the switches above; merge_step's own
  # hold writes the one HELD line when a real attempt is made.
  command -v main_red_hold >/dev/null 2>&1 \
    && main_red_hold "$PROJECT" "$SLUG" "$NUM" "https://github.com/$SLUG/pull/$NUM" "$SHA" && return 0
  N=$(jq -r --arg n "$NUM" '.[$n].merge_retries // 0' "$STATE")
  [ "$(jq -r --arg n "$NUM" '.[$n].merge_retry_sha // ""' "$STATE")" = "$SHA" ] || N=0
  if [ "$N" -ge "${REVIEW_MERGE_RETRY_MAX:-6}" ]; then
    ALERTED=$(jq -r --arg n "$NUM" '.[$n].merge_retry_alerted_sha // ""' "$STATE")
    if [ "$ALERTED" != "$SHA" ]; then
      HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[$PROJECT] #$NUM @${SHA:0:7} is APPROVED on its current head and still OPEN after ${REVIEW_MERGE_RETRY_MAX:-6} merge attempts — https://github.com/$SLUG/pull/$NUM needs a look (merge it, or say why it must not land); the lane stops retrying this head"
      rp_state_write --arg n "$NUM" --arg s "$SHA" '.[$n] = ((.[$n] // {}) + {merge_retry_alerted_sha:$s})'
    fi
    return 0
  fi
  # One read, and only for a PR whose record already says APPROVE: a tick over a
  # board of REQUEST_CHANGES PRs costs nothing extra. BH-994/BH-1295: REST
  # through mc_pr_view, never `gh pr view` (GraphQL) — this is the exact
  # "re-check the same PR every tick while it stays APPROVE" read the ETag
  # cache exists for. .MSTATE is mc_rest_pr_json's uppercase of the REST
  # mergeable_state field, which is CLEAN/DIRTY/UNSTABLE/... — the same
  # vocabulary GraphQL's mergeStateStatus used, so the case below is unchanged.
  ST=$(mc_pr_view "https://github.com/$SLUG/pull/$NUM" '.STATE + " " + .MSTATE' 2>/dev/null)
  case "$ST" in "OPEN CLEAN") ;; *) return 0 ;; esac
  N=$((N+1))
  rp_state_write --arg n "$NUM" --arg s "$SHA" --argjson c "$N" \
    '.[$n] = ((.[$n] // {}) + {merge_retries:$c, merge_retry_sha:$s})'
  RP_BG_UNREAD=0
  merge_step "$NUM" "$SHA" "$SERVED" "$RP_WHO"
  if [ "${RP_BG_UNREAD:-0}" = 1 ]; then
    rp_state_write --arg n "$NUM" --argjson c "$((N-1))" '.[$n] = ((.[$n] // {}) + {merge_retries:$c})'
    echo "$(STAMP) [$PROJECT] #$NUM approved head still open — the block gate could not judge it this tick, so this is not counted as a merge attempt" >> "$LOG"
    return 0
  fi
  # BH-1558: a held ticket or a lead PR still waiting on its lead is a hold, not
  # a refusal — handed back like the main-red freeze, and merge_step's fence has
  # already written the one line that says why.
  if [ "${RP_FENCED:-0}" = 1 ]; then
    rp_state_write --arg n "$NUM" --argjson c "$((N-1))" '.[$n] = ((.[$n] // {}) + {merge_retries:$c})'
    return 0
  fi
  echo "$(STAMP) [$PROJECT] #$NUM approved head still open -> merge retried (merged=$MERGED), attempt $N" >> "$LOG"
  [ "$MERGED" = yes ] && "$HARNESS/bin/beat.sh" "$(jq -nc --arg p "$PROJECT" \
    --arg akey "prmergeretry:$PROJECT:$NUM:$SHA" \
    --arg l "PR #$NUM was approved on this head and still open — merged now. https://github.com/$SLUG/pull/$NUM" \
    '{kind:"pr_review",project:$p,akey:$akey,line:$l}')" >/dev/null 2>&1
  return 0
}
# <<< review-prs merge-retry

# --- GitHub's own review rows (BH-872) ----------------------------------------
# A review this lane posted is a row on the PR carrying (commit_id, author,
# footer). BH-872 read that triple for TWO jobs: dismissing this lane's own
# standing blocking verdict, and deduping the paid review. THE DEDUPE HALF IS
# GONE — main landed BH-1017 below, which answers the same question from the D1
# jobs ledger first and GitHub second, and which fails OPEN on an unreadable
# read where BH-872 deferred. Two dedupes cannot both own the decision, and
# BH-1017 is the later, wider one (rp_standing_at / rp_review_verdict were this
# block's dedupe half and went with it). What is left is the DISMISSAL read,
# which BH-1017 does not do and nothing else in the fleet does either.
#
# NON-TSV OUTPUT IS "NO STANDING REVIEW", A NON-ZERO RC IS "UNREADABLE". They are
# different answers (D11): nothing is dismissed on a read this box could not
# make, and the next tick asks again.
#
# THE READ GOES THROUGH gh_ci_api, not bare `gh api`: the project-2 box's
# fine-grained PAT answers 403 on endpoints the App token reads fine, and a
# ledger this lane cannot read defers every review on that box for ever — the
# 2026-09-14 silence, with a new endpoint. Default token first, read-only App
# token once if it refuses (tests/external-review-ci-read-test.sh pins it).
# The footer test is RP_MARKER itself, interpolated into the filter rather than
# spelled a second time: a gh `-q` filter takes no `--arg`, and two copies of
# the marker is exactly how a reader comes to look for text nothing posts any
# more (tests/review-prs-gh-dedup-test.sh G13 pins the single spelling).
rp_reviews_tsv() { # rp_reviews_tsv <num> -> id<TAB>state<TAB>commit_id<TAB>login<TAB>yes|no
  local q
  q=".[] | [
      (.id // \"\" | tostring), (.state // \"\"), (.commit_id // \"\"), (.user.login // \"\"),
      (if ((.body // \"\") | contains(\"$RP_MARKER \")) then \"yes\" else \"no\" end)
    ] | @tsv"
  GH_CI_READ_WHAT="pulls/$1/reviews" GH_CI_READ_LOG="$LOG" GH_CI_READ_TAG="[$PROJECT] #$1" \
  gh_ci_api "$SLUG" "repos/$SLUG/pulls/$1/reviews" --paginate -q "$q" 2>/dev/null
}

# Our OWN standing CHANGES_REQUESTED reviews on a HARNESS-authored PR, dismissed.
# Mergify reads that state as `github-review-approved = false` and takes the PR
# out of the queue, and nothing in the fleet consumed the verdict, so four PRs
# sat parked on a bot's refusal. The verdict stays on the PR as text; only the
# blocking STATE goes. Never on a review without this lane's footer (a person's
# changes-requested is for a person), and never on a non-blocking row. The
# per-tick pass below runs on harness-authored PRs only; on any other PR the
# only caller is the post-APPROVE supersede pass (BH-2119), which dismisses a
# row only after this lane's own approval of a newer head has landed.
#
# A THIRD ARGUMENT: THE HEAD TO LEAVE ALONE (#891 review round 1, Important 3).
# A dismissal only helps where the verdict has a CONSUMER. On a pipeline PR it
# does: the lane skips the PR entirely (it never re-posts), the conductor's
# requeue arm takes the PR back, and the build record owns the findings — so
# everything goes, including a row at the current head (project-5 #2367, the
# park this ticket was filed for). On a HAND harness PR the lane reviews the
# head itself, and dismissing the row that sits AT that head throws the verdict
# away: rp_rehydrate's GitHub rung has no DISMISSED filter, so it heals the
# ledger from the dismissed row and posts nothing, br_review_newest skips the
# DISMISSED state, and findings that were blocking stop being anything at all.
# So the caller passes the current head there and a row at it is left standing;
# a STALE row (an older head) is dismissed on both paths, which is what makes a
# pushed branch re-enter the queue. An empty third argument means "no head is
# protected" — the pipeline path.
#
# THE RETURN CODE IS THE WATERMARK'S GATE (BH-989). The caller records
# `ledger_sha` — "this head's dismissal pass completed with nothing left to do"
# — and skips this read on later ticks at the same head, so a pass that left a
# row standing must NOT be recorded as complete. rc 0 = every row that had to
# go, went; rc 1 = at least one dismissal was refused, so no watermark is
# written and the next tick reads again. A KEPT row is not a failure: it is the
# at-head verdict the keep-sha above deliberately leaves standing.
#
# A FOURTH ARGUMENT: THE DISMISSAL MESSAGE (BH-2119). Empty = the BH-872 text
# above. The post-APPROVE supersede pass passes one that cites the approval that
# replaced the row, and the log line then says "superseded".
rp_dismiss_own() { # rp_dismiss_own <num> <reviews-tsv> [head-sha-to-keep] [message]
  local num="$1" keep="${3:-}" msg="${4:-}" why="BH-872" id st cid login foot armed=0 rc=0
  [ -n "$msg" ] && why="superseded, BH-2119"
  : "${msg:=Dismissed by the harness review lane (BH-872): bot verdicts no longer block the merge queue; the findings stay in the review body and the harness fix round consumes them.}"
  while IFS=$'\t' read -r id st cid login foot; do
    [ -n "$id" ] && [ "$st" = CHANGES_REQUESTED ] && [ "$foot" = yes ] || continue
    # the lane's OWN review: a verdict author, never merely a PR author (BH-1668),
    # or the operator login a PAT post goes out as (BH-8466; foot=yes above)
    harness_verdict_author_match "$login" || harness_own_review_match "$login" 2>/dev/null || continue
    if [ -n "$keep" ] && [ "$cid" = "$keep" ]; then
      echo "$(STAMP) [$PROJECT] #$num left its own CHANGES_REQUESTED review $id standing — it is AT the current head (${keep:0:7}) on a PR this lane reviews itself, and nothing else would consume the findings if the state went" >> "$LOG"
      continue
    fi
    [ "$armed" = 1 ] || { gh_auth_for "$SLUG" || true; armed=1; }
    if gh api -X PUT "repos/$SLUG/pulls/$num/reviews/$id/dismissals" \
        -f event=DISMISS \
        -f message="$msg" >/dev/null 2>&1; then
      echo "$(STAMP) [$PROJECT] #$num dismissed its own standing CHANGES_REQUESTED review $id ($why) — the findings stay in the body, the queue is no longer blocked by it" >> "$LOG"
      rm -f "$RP_DISMISS_FAILS/$num-$id" 2>/dev/null
    else
      # A PERMANENT REFUSAL IS NOT A TRANSIENT ONE (#891 round 1, Nit 11). The
      # App lacking dismiss rights on a protected repo refuses every tick for
      # ever, and one log line a tick is a silence nobody reads. The attempt is
      # counted on disk per (PR, review) and the third one pages, once.
      echo "$(STAMP) [$PROJECT] #$num could not dismiss its own standing review $id — still blocking, the next tick tries again" >> "$LOG"
      mkdir -p "$RP_DISMISS_FAILS" 2>/dev/null
      printf 'x' >> "$RP_DISMISS_FAILS/$num-$id"
      if [ "$(wc -c < "$RP_DISMISS_FAILS/$num-$id" 2>/dev/null || echo 0)" = "${RP_DISMISS_FAIL_ALERT:-3}" ]; then
        HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[$PROJECT] #$num: GitHub has refused to dismiss this lane's own standing review $id ${RP_DISMISS_FAIL_ALERT:-3} times — the PR stays out of the merge queue until a person dismisses it or the token gains the right: https://github.com/$SLUG/pull/$num"
      fi
      rc=1
    fi
  done <<<"$2"
  [ "$armed" = 1 ] && gh_auth_reset
  return "$rc"
}

# --- the ledger is a CACHE, not the truth (BH-1017) ----------------------------
# The dedup above is `state/<project>.pr-reviews.json` and nothing else, so a
# ledger that is GONE — reseeded by the BH-977 guard, restored from an old
# snapshot, deleted by hand, lost with a box — reads as "nothing has ever been
# reviewed" and every open head is bought again. On project-5, 2026-09-18/19:
# 460 verdicts across 122 distinct PR+head pairs, #229 reviewed 52 times, USD
# 1.1K in two days, while GitHub was holding every one of those reviews and the
# D1 jobs ledger was holding the verdict rows. Neither was ever asked.
#
# So before the money is spent, two free reads answer "have we already paid for
# THIS head?":
#   1. the D1 verdict row (`job_verdict`) — the only source that also carries
#      PROVENANCE, so when it answers the rehydrated record is as good as the
#      original one;
#   2. the PR's own reviews over REST — a review authored by a harness identity
#      whose body carries the marker above for the CURRENT head.
# Either one rehydrates the ledger entry and the call is skipped.
#
# D1 IS THE TRUTH, THE FILE A CACHE, AND AN UNREADABLE D1 HOLDS (BH-2315). The
# old rule failed OPEN on every unreadable source: "one duplicate review" per
# outage. On a fleet with a dozen repos and a ledger file that can vanish, that
# rule is how a worker blip became the $328/day class — every open head bought
# again, silently, for as long as D1 could not answer. So:
#   - a D1 verdict for THIS head (any of APPROVE / REQUEST_CHANGES / BLOCK, the
#     last being the verdict_single_home row's word) is replayed: no purchase;
#   - D1 answering "no row" or "another head" is a real answer: the GitHub rung
#     runs, and a GitHub outage then still fails open (one review per new head
#     is the job);
#   - D1 UNREADABLE on a box whose jobs client is configured (a non-empty
#     JOBS_URL, the fleet default included, BH-2457) and GitHub holding nothing
#     for this head: HELD — no paid call this tick, one log line per PR, one
#     alert per project per day, and the next tick asks again. A box with no
#     worker configured (JOBS_URL empty) has no D1 to be the truth, and keeps
#     the GitHub rung and the old fail-open;
#   - HELD for REVIEW_D1_HOLD_MAX_H hours of one outage (BH-2457, default 6,
#     0 = hold until D1 answers): the head is bought on the runners
#     bin/billing-mode.sh calls `subscription` on this box and nothing else,
#     with the call-guard's metered refusal pinned on. No such runner: held;
#   - the call-guard in agent-call.sh (K3) stays the backstop under all of it.
# >>> review-prs gh dedup (BH-1017; tests/review-prs-gh-dedup-test.sh drives this block)
# rp_withheld_beat <num> <sha> <source> [reused]
#   A rehydrated APPROVE cannot be auto-merged: `served:"rehydrated"` is not a
#   Claude lane to rp_prov_is_claude, so merge_retry returns on every later tick
#   and no other lane in the fleet lists an external author's PR. Without this
#   the PR sits approved and open with one line in a log nobody pages on — the
#   failure mode this harness treats as an iron law.
#
#   BOTH RUNGS CALL IT, and that is the whole reason it is a function. It lived
#   inside the GitHub rung until the hub's own review of 5376a75e found the jobs
#   rung returning before it ever got there: review round 2 made a D1 row with
#   no provenance write `served:"rehydrated"` too, so the D1 rung silently
#   acquired the muteness the GitHub rung had just been fixed for. One call
#   site per rung, one helper, so a third rung cannot reopen it.
#
#   Same akey as merge_step's live provenance-withheld beat
#   (`provenance:<project>:<num>:<sha>`), so beat.sh collapses a head withheld
#   by both paths into one announcement per head.
#
#   A 4th arg of `reused` (BH-4134) is the bought-reuse path: nothing was lost
#   there, review-prs found another lane's verdict at the head, and the line
#   says so instead of sending an operator after a ledger outage. Same akey.
rp_withheld_beat() {
  local num="$1" sha="$2" src="$3" why
  why=", but the review ledger lost the record and the $src it was recovered from does not say which lane served it"
  [ "${4:-}" = reused ] && why=" by a $src that does not say which lane served it"
  "$HARNESS/bin/beat.sh" "$(jq -nc --arg p "$PROJECT" --arg akey "provenance:$PROJECT:$num:$sha" \
    --arg l "PR #$num is APPROVED on its current head$why — auto-merge withheld. Merge yourself when ready; a new push gets a fresh review. https://github.com/$SLUG/pull/$num" \
    '{kind:"fleet_alert",project:$p,akey:$akey,line:$l}')" >/dev/null 2>&1 || true
}

# rp_rehydrate_record <num> <sha> <verdict> <tier> <served> <source> <log-line>
#   The one write both rungs rehydrate through, and the one place that decides
#   whether the recovery has to be announced.
#
#   IT MERGES, IT DOES NOT REPLACE. A wholesale `.[$n] = {…}` dropped
#   `deferred_sha` / `deferred_at` / `ci_alerted_sha`, so a rehydration on a
#   LIVE ledger reset that PR's CI-debounce clock and bought one extra
#   `gh pr diff --name-only` + `actions/runs` read on the next head. Those keys
#   are this PR's own bookkeeping and none of them can merge anything, so they
#   survive. What does NOT survive is the judgement — same list rp_freeze
#   deletes — because a record being rehydrated may still hold a PREVIOUS
#   head's verdict, and the new judgement must be the only one on the record.
rp_rehydrate_record() {
  local num="$1" sha="$2" v="$3" t="$4" prov="$5" src="$6" line="$7"
  rp_state_write --arg n "$num" --arg s "$sha" --arg v "$v" --arg t "$t" \
    --arg sv "$prov" --arg src "$src" \
    '.[$n] = ((.[$n] // {})
              | del(.verdict, .tier, .served, .rehydrated_from,
                    .merge_retries, .merge_retry_sha, .merge_retry_alerted_sha)
              + {sha:$s, verdict:$v, tier:$t, served:$sv, rehydrated_from:$src})' \
    || return 1
  echo "$line" >> "$LOG"
  # REQUEST_CHANGES beats nothing: nobody is waiting on a person for it.
  if [ "$v" = APPROVE ] && [ "$prov" = rehydrated ]; then
    rp_withheld_beat "$num" "$sha" "$src"
  fi
  return 0
}

# rp_d1_hold <num> <sha> — one log line for this PR, and ONE alert for the
#   project per tick (RP_D1_HELD_TICK) under a per-day akey, which beat.sh
#   collapses into one announcement a day. Nothing is written to the ledger: a
#   held head is not a reviewed head.
RP_D1_HELD_TICK=0
rp_d1_hold() {
  local num="$1" sha="$2"
  echo "$(STAMP) [$PROJECT] #$num @${sha:0:7} NOT reviewed this tick: the D1 verdict ledger could not be read and $SLUG holds no review of this head — held, no session bought (BH-2315); the next tick asks again" >> "$LOG"
  [ "$RP_D1_HELD_TICK" = 1 ] && return 0
  RP_D1_HELD_TICK=1
  "$HARNESS/bin/beat.sh" "$(jq -nc --arg p "$PROJECT" --arg akey "review-d1-unreadable:$PROJECT:$(date -u +%Y%m%d)" \
    --arg l "review-prs on $PROJECT is HOLDING paid reviews: the D1 verdict ledger (jobs worker) could not be read, so whether a head was already reviewed cannot be told — nothing is bought until it answers (BH-2315). Check the jobs worker and logs/jobs-client.log." \
    '{kind:"fleet_alert",project:$p,akey:$akey,line:$l}')" >/dev/null 2>&1 || true
}

# THE HOLD HAS A CLOCK (BH-2457). $RP_D1_HOLD_FILE holds one line, the epoch of
#   this outage's first held tick; `.fallback` beside it says the fallback start
#   was already announced. Both are LOCAL on purpose: the thing being timed is
#   D1 being unreachable, so D1 cannot keep the clock. Both go the moment D1
#   gives a real answer, so the next outage starts, and alerts, afresh. A
#   missing or unparseable clock starts NOW, never "held forever": losing the
#   file can only mean holding longer, never paying sooner.
RP_D1_HOLD_FILE="$HARNESS/state/$PROJECT.review-d1-hold"
RP_D1_SUBONLY=0
RP_SUB_RUNNERS=""
RP_D1_KNOB_LOGGED=0
rp_d1_clear() {
  [ -e "$RP_D1_HOLD_FILE" ] || [ -e "$RP_D1_HOLD_FILE.fallback" ] || return 0
  rm -f "$RP_D1_HOLD_FILE" "$RP_D1_HOLD_FILE.fallback" 2>/dev/null
  return 0
}
# rp_d1_since — the outage's start epoch, (re)written as now when the file is
#   absent or not a number. A future epoch is kept: it reads as "not yet N
#   hours", so clock skew holds, it never pays. Every held tick touches the
#   file, so its mtime is the outage's LAST held tick; one older than an hour
#   (two ticks of the 7,37 cadence) is an outage that ended while no PR asked
#   D1 (every head already reviewed), and the clock and its alert start afresh.
rp_d1_since() {
  local s="" m
  if [ -r "$RP_D1_HOLD_FILE" ]; then
    m=$(stat -c %Y "$RP_D1_HOLD_FILE" 2>/dev/null) || m=0
    if [ $(( $(date +%s) - ${m:-0} )) -gt 3600 ]; then rp_d1_clear
    else s=$(head -c 32 "$RP_D1_HOLD_FILE" 2>/dev/null | tr -d '[:space:]'); fi
  fi
  # A real epoch is ten digits: `0`, or thirty digits that overflow, would read
  # as held for decades, so anything else is garbage and restarts the clock.
  case "$s" in
    [1-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) touch "$RP_D1_HOLD_FILE" 2>/dev/null ;;
    *)
      s=$(date +%s)
      mkdir -p "${RP_D1_HOLD_FILE%/*}" 2>/dev/null
      printf '%s\n' "$s" > "$RP_D1_HOLD_FILE.tmp.$BASHPID" 2>/dev/null \
        && mv -f "$RP_D1_HOLD_FILE.tmp.$BASHPID" "$RP_D1_HOLD_FILE" 2>/dev/null ;;
  esac
  printf '%s' "$s"
}
# rp_d1_hold_or_fallback <num> <sha> — every D1-unreadable exit of rp_rehydrate.
#   rc 3: held (rp_d1_hold), the caller buys nothing.
#   rc 1: held REVIEW_D1_HOLD_MAX_H hours or more and a subscription runner is
#         here: RP_D1_SUBONLY=1 and RP_SUB_RUNNERS name the runners the caller
#         may buy on.
rp_d1_hold_or_fallback() {
  local num="$1" sha="$2" max since now r list=""
  since=$(rp_d1_since)
  max="${REVIEW_D1_HOLD_MAX_H:-6}"
  # Four digits and up is garbage too: an overflowing N must not wrap to "past".
  # Above the registry's max of 168 (catalog/lanes.d/review-prs.json) takes the
  # same logged path, never a silent clamp (BH-2492).
  case "$max" in
    ''|*[!0-9]*|????*) max=x ;;
    *) max=$((10#$max)); [ "$max" -le 168 ] || max=x ;;
  esac
  if [ "$max" = x ]; then
    [ "$RP_D1_KNOB_LOGGED" = 1 ] || echo "$(STAMP) [$PROJECT] REVIEW_D1_HOLD_MAX_H is '${REVIEW_D1_HOLD_MAX_H:-}', not an hour count of 0-168 — the default 6 is used (BH-2457)" >> "$LOG"
    RP_D1_KNOB_LOGGED=1; max=6
  fi
  now=$(date +%s)
  if [ "$max" = 0 ] || [ $((now - since)) -lt $((max * 3600)) ]; then
    rp_d1_hold "$num" "$sha"; return 3
  fi
  for r in claude codex grok gemini; do
    [ "$("$HARNESS/bin/billing-mode.sh" "$r" 2>/dev/null)" = subscription ] || continue
    if [ -n "${AGENT_CALL_RUNNERS:-}" ]; then
      case ",${AGENT_CALL_RUNNERS//[[:space:]]/,}," in *",$r,"*) ;; *) continue ;; esac
    fi
    list="${list:+$list,}$r"
  done
  if [ -z "$list" ]; then
    echo "$(STAMP) [$PROJECT] #$num @${sha:0:7} D1 held $(( (now - since) / 3600 ))h, past REVIEW_D1_HOLD_MAX_H ($max h), but there is no subscription runner on this box — still held (BH-2457)" >> "$LOG"
    rp_d1_hold "$num" "$sha"; return 3
  fi
  RP_D1_SUBONLY=1; RP_SUB_RUNNERS="$list"
  echo "$(STAMP) [$PROJECT] #$num @${sha:0:7} D1 held $(( (now - since) / 3600 ))h, past REVIEW_D1_HOLD_MAX_H ($max h) — fallback: subscription-only ($list); metered spend stays refused (BH-2457)" >> "$LOG"
  # Once per outage: the marker first, so a failed beat never re-alerts.
  if [ ! -e "$RP_D1_HOLD_FILE.fallback" ]; then
    : > "$RP_D1_HOLD_FILE.fallback" 2>/dev/null
    local l="review-prs on $PROJECT has held paid reviews for $(( (now - since) / 3600 ))h because the D1 verdict ledger cannot be read. It now reviews on subscription runners only ($list) and still buys nothing metered. REVIEW_D1_HOLD_MAX_H (now $max) sets the wait, and 0 holds until D1 answers (BH-2457). Check the jobs worker and logs/jobs-client.log."
    HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[$PROJECT] $l"
    "$HARNESS/bin/beat.sh" "$(jq -nc --arg p "$PROJECT" --arg akey "review-d1-fallback:$PROJECT:$since" --arg l "$l" \
      '{kind:"fleet_alert",project:$p,akey:$akey,line:$l}')" >/dev/null 2>&1 || true
  fi
  return 1
}

rp_rehydrate() { # rp_rehydrate <num> <sha> [gh-only]
  # rc 0: a verdict for THIS head already exists outside the ledger and the
  #       ledger now records it — the caller must NOT buy a review.
  # rc 1: no such verdict: the caller buys the review.
  # rc 3: HELD (BH-2315) — D1 could not be read on a box that has one, and
  #       GitHub holds nothing for this head: the caller must NOT buy a review
  #       this tick either. Past REVIEW_D1_HOLD_MAX_H hours this is rc 1 with
  #       RP_D1_SUBONLY=1 instead (BH-2457, rp_d1_hold_or_fallback).
  local NUM="$1" SHA="$2" row v t prov rsha out login rstate body found="" jrc=0 d1down=0

  # 1. The jobs ledger. rc 2 is "no row"; rc 1 is an outage (or no client
  #    configured). Both still ask GitHub, free, before anything else.
  #    A 3rd arg `gh-only` (BH-5396, a stale-CR head) skips this rung: a D1
  #    row at this head may be another lane's, and only this lane's own review
  #    on GitHub answers for it, so a D1 outage cannot hold it either.
  if [ "${3:-}" != gh-only ] && command -v job_verdict >/dev/null 2>&1; then
    row=$(job_verdict "https://github.com/$SLUG/pull/$NUM" 2>/dev/null) || jrc=$?
    [ "$jrc" = 1 ] && command -v jobs_configured >/dev/null 2>&1 && jobs_configured && d1down=1
    # A real answer, or no worker at all, ends the outage the hold clock times.
    [ "$d1down" = 1 ] || rp_d1_clear
    if [ "$jrc" = 0 ]; then
      IFS=$'\t' read -r v t prov _ _ rsha <<<"$row"
      # BLOCK is the verdict_single_home row's word for REQUEST_CHANGES.
      # Pipeline-built PRs (the build job's default BLOCK) never reach here: the loop skips them at its top (the harness-generated check), so no build BLOCK is replayed.
      [ "${v:-}" = BLOCK ] && v=REQUEST_CHANGES
      if [ -n "${rsha:-}" ] && [ "$rsha" != "-" ] && [ "$rsha" = "$SHA" ] \
         && { [ "${v:-}" = APPROVE ] || [ "${v:-}" = REQUEST_CHANGES ]; }; then
        # A row with no provenance is NOT guessed as claude (same rule as the
        # GitHub rung below): `rehydrated` posts and waits for a human or a
        # provenance-carrying re-read instead of arming merge_retry.
        [ -n "${prov:-}" ] && [ "$prov" != "-" ] || prov=rehydrated
        rp_rehydrate_record "$NUM" "$SHA" "$v" "${t:-?}" "$prov" jobs \
          "$(STAMP) [$PROJECT] #$NUM @${SHA:0:7} not re-reviewed: the jobs ledger already holds $v (tier ${t:-?}, served $prov) for this head — ledger entry rehydrated, no session bought" \
          || return 1
        return 0
      fi
    fi
  fi

  # 2. GitHub, over REST (never GraphQL — this fleet's accounts hit the GraphQL
  #    limit and die mid-tick). One read; a failure is announced and fails open.
  # The body rides as base64 (BH-1625): the verdict reader is anchored to a
  # LINE, and the old `gsub("[\r\n]+"; " ")` flattened every body into one line
  # nothing could anchor to.
  if ! out=$(gh api "repos/$SLUG/pulls/$NUM/reviews?per_page=100" --paginate \
       -q '.[] | [(.user.login // ""), (.state // ""), ((.body // "") | @base64)] | @tsv' 2>/dev/null); then
    if [ "$d1down" = 1 ]; then rp_d1_hold_or_fallback "$NUM" "$SHA"; return; fi
    echo "$(STAMP) [$PROJECT] #$NUM @${SHA:0:7} could not read $SLUG's reviews over REST — failing OPEN (the review is bought; a read outage must not stop reviews)" >> "$LOG"
    return 1
  fi
  [ -n "$out" ] || { if [ "$d1down" = 1 ]; then rp_d1_hold_or_fallback "$NUM" "$SHA"; return; fi; return 1; }
  while IFS=$'\t' read -r login rstate body; do
    [ -n "${login:-}" ] || continue
    # a harness verdict counts only from a verdict author (BH-1668): the builders
    # App opens pool PRs and must never post the review that clears one. A PAT
    # post goes out as the operator login, and that row is ours only with the
    # footer (BH-8466), so the body is decoded first.
    body=$(printf '%s' "${body:-}" | base64 -d 2>/dev/null) || body=""
    harness_verdict_author_match "$login" || harness_own_review_row "$login" "$body" 2>/dev/null || continue
    case "${body:-}" in *"$RP_MARKER $SHA"*) found="${rstate:-}"$'\t'"${body:-}" ;; esac
  done <<<"$out"
  [ -n "$found" ] || { if [ "$d1down" = 1 ]; then rp_d1_hold_or_fallback "$NUM" "$SHA"; return; fi; return 1; }

  rstate="${found%%$'\t'*}"; body="${found#*$'\t'}"
  # The same tolerant parse the live path uses, then the review's own STATE as
  # the fallback. A body we cannot read a verdict out of is STILL proof we paid
  # for this head, so it records terminally either way — writing nothing here is
  # what would let the next tick buy it again.
  # The one shared reader (bin/lib/verdict-parse.sh, BH-1625), on the posted
  # body with its footer (after the last `---`) dropped. Unknown is empty.
  v=$(printf '%s\n' "$body" | verdict_parse -c -w 'APPROVE|REQUEST_CHANGES' 2>/dev/null) || v=""
  t=$(grep -oE "TIER:? *\**[12]" <<<"$body" | grep -oE "[12]" | tail -1)
  if [ -z "$v" ]; then
    case "$rstate" in
      APPROVED) v=APPROVE ;;
      CHANGES_REQUESTED) v=REQUEST_CHANGES ;;
      *) v="" ;;
    esac
  fi
  # `served` is NOT guessed. The body does not say which lane answered, and
  # recording "claude" here would let merge_retry auto-merge an APPROVE that
  # judge provenance may have deliberately withheld. `rehydrated` is not a
  # Claude lane to rp_prov_is_claude, so a rehydrated APPROVE posts and waits
  # for a person or for a new head — announced on the line below, never silent.
  rp_rehydrate_record "$NUM" "$SHA" "$v" "${t:-?}" rehydrated github \
    "$(STAMP) [$PROJECT] #$NUM @${SHA:0:7} not re-reviewed: $SLUG already carries this lane's review of this head (${v:-no parseable verdict}, tier ${t:-?}) — ledger entry rehydrated from GitHub, no session bought; auto-merge is withheld because the serving lane is not recoverable from the posted body" \
    || return 1
  return 0
}
# <<< review-prs gh dedup

# The GitHub rate-limit reader, loaded the guarded way the resolver loads it
# (#891 round 1, Nit 7): a box whose harness sync has not landed the lib keeps
# every read exactly as it is today. It gates the per-PR standing-review read
# below, never the review spend — the spend has its own dedup.
[ -r "$HARNESS/bin/lib/gh-budget.sh" ] && . "$HARNESS/bin/lib/gh-budget.sh" 2>/dev/null

# BH-1585: REST, every author (external PRs are the point), drafts dropped. The
# author is REST's spelling (`x[bot]` for an App); harness_pr_author_match below
# compares bare names, so both spellings are ours.
command -v gh_rest_pr_list_all >/dev/null 2>&1 || exit 0
RP_LISTF=$(mktemp "${TMPDIR:-/tmp}/review-prs-list.XXXXXX") || exit 0
gh_rest_pr_list_all "$SLUG" open 100 > "$RP_LISTF" 2>/dev/null || { rm -f "$RP_LISTF"; exit 0; }
PRS=$(jq -r '.[] | select(.draft | not) | [.number, .head.sha, .user.login, .title] | @tsv' "$RP_LISTF") || { rm -f "$RP_LISTF"; exit 0; }
rm -f "$RP_LISTF"
[ -n "$PRS" ] || exit 0
# BH-1606: the MERGE_HELD dedupe files of this repo's closed PRs go. A PR this
# list does not carry (a draft, past the page) is asked once before its go.
# shellcheck disable=SC2046  # one PR number per word, on purpose
command -v to_held_prune >/dev/null 2>&1 && to_held_prune "$SLUG" $(cut -f1 <<<"$PRS")

# >>> review-prs one pr (BH-5284)
# ONE PR, start to finish: what the loop body always was. The one-pass `for`
# keeps every `continue` below meaning "done with this PR". It runs in a worker
# of bin/lib/review-pool.sh (below the function), or inline when that lib is
# not on the box.
rp_one_pr() { for _rp_once in 1; do
  [ -n "$NUM" ] || continue
  # BH-2457: a D1-hold fallback is this PR's, never the next one's.
  RP_D1_SUBONLY=0
  # BH-5396: set only when THIS pass deferred the head on CI (read by
  # rp_stale_head_watch); the row's deferred_sha is sticky past green CI.
  RP_CI_DEFERRED=0
  # Our OWN PRs are reviewed too (the operator, 2026-07-29) — but NOT harness-generated
  # ones: pipeline builds (a build dir RESULT references the PR, or the body
  # carries the pipeline marker) and train rollbacks review themselves already.
  RP_REVIEWS=""; RP_REVIEWS_RC=1; RP_PIPELINE=0; RP_DISMISS_RC=0
  # THE LOCAL RECORD, READ ONCE PER PR PER TICK (BH-989), and used by both the
  # dismissal gate below and the already-reviewed gate under this block. `sha`
  # is the head this lane has reviewed; `ledger_sha` is the head whose dismissal
  # pass completed with nothing left to do. A pipeline PR never gets a `sha` row
  # — the lane never reviews it — so `ledger_sha` is the only local answer the
  # ~45 of ~55 open harness PRs that are pipeline-built can ever have.
  RP_ROW=$(jq -r --arg n "$NUM" '[(.[$n].sha // ""), (.[$n].ledger_sha // "")] | @tsv' "$STATE" 2>/dev/null)
  # Split on the TAB by parameter expansion, not `read`: bash treats a tab in
  # IFS as IFS whitespace and collapses a LEADING empty field, so a pipeline
  # PR's row (no `sha`, only `ledger_sha`) would land its watermark in DONE.
  DONE="${RP_ROW%%$'\t'*}"; LEDGER_SHA="${RP_ROW##*$'\t'}"
  [ "$DONE" = "$RP_ROW" ] && LEDGER_SHA=""
  if harness_pr_author_match "$AUTHOR"; then
    case "$TITLE" in Rollback:*) continue ;; esac
    # WHETHER THIS IS A PIPELINE PR IS DECIDED FIRST (#891 round 1, Important 3).
    # It used to be decided after the dismissal, and the dismissal needs the
    # answer: on a pipeline PR the lane walks away and the row at the current
    # head has to go, on a hand PR the lane reviews that head itself and the row
    # at it is the verdict. Same two reads, in the order the decision needs.
    #
    # THE WHOLE BODY, not the first 2000 bytes. bin/run-build.sh prints its
    # `Plan: harness build …` line AFTER the What/Why/verify/spec sections, so a
    # normal pipeline PR body puts the marker past a 2000-byte window — and every
    # pool-built PR was reviewed a second time by a lane whose own header says it
    # skips them (the operator, 2026-07-29).
    #
    # ANCHORED (#891 round 1, Nit 8): run-build prints the phrase line-initial
    # (`Plan: harness build …`); an unanchored match would skip a PR whose body
    # merely TALKS about a harness build, and a skipped PR is never reviewed.
    #
    # OVER REST, not `gh pr view --json body` (#891 round 1, Nit 6): that is a
    # GraphQL call and this fleet's accounts die on the GraphQL limit mid-tick;
    # `repos/<slug>/pulls/<n>` carries `.body` on the REST bucket every other
    # read in this lane already uses.
    grep -qE "pull/$NUM\$" "$HARNESS"/builds/*/RESULT 2>/dev/null && RP_PIPELINE=1
    [ "$RP_PIPELINE" = 1 ] || { gh api "repos/$SLUG/pulls/$NUM" -q '.body // ""' 2>/dev/null \
      | grep -qE '^Plan: harness build ' && RP_PIPELINE=1; }
    # A PR this lane is about to walk past may still be carrying this lane's own
    # blocking review, which is what parked project-5 #2367 and three others. The
    # read is one call and it answers ONE question — what to dismiss. Its only
    # consumer is rp_dismiss_own below. Whether this head was already reviewed
    # is the local row's answer (`.sha`, read once above), and on a cache miss
    # rp_rehydrate makes its own read further down (BH-1289 corrected the "both
    # questions" wording #891 left here; BH-989 is what split them).
    #
    # SKIPPED WHEN THE LOCAL RECORD ALREADY ANSWERS FOR THIS HEAD (BH-989). The
    # read ran for EVERY open harness PR on EVERY tick, ahead of any local
    # check: ~110 paginated reads an hour per box for a lane that walks past
    # most of those PRs. `ledger_sha` is the free answer — it is written only
    # when a pass at this head finished with nothing left standing that had to
    # go — so a second tick at the same head asks GitHub nothing. It is NOT
    # `.sha`: a head can be reviewed on a tick whose dismissal pass was deferred
    # (budget low) or refused, and skipping on `.sha` would leave a stale-head
    # blocking row standing until the branch moved again.
    #
    # SKIPPED WHEN THE GITHUB BUDGET IS LOW (#891 round 1, Nit 7). One paginated
    # reviews read per open harness PR per tick, before any local-cache skip, is
    # ~60 reads a tick on this repo alone. It is a dismissal read, not a spend
    # guard — BH-1017's rehydrate still runs and still dedupes the money — so a
    # low bucket skips it and the next tick asks again. No lib on the box = the
    # read happens, exactly as it does today. rc 2 (the rate limit is unreadable)
    # is not "low": unknown fails open, the same way the resolver's guard does.
    if [ -n "$LEDGER_SHA" ] && [ "$LEDGER_SHA" = "$SHA" ]; then
      :
    elif command -v gh_budget_low >/dev/null 2>&1 && gh_budget_low review-prs >/dev/null 2>&1; then
      echo "$(STAMP) [$PROJECT] #$NUM: the standing-review read is skipped this tick — the GitHub API budget is low; nothing is dismissed and the next tick asks again" >> "$LOG"
    else
      RP_REVIEWS=$(rp_reviews_tsv "$NUM"); RP_REVIEWS_RC=$?
      [ "$RP_REVIEWS_RC" = 0 ] && { rp_dismiss_own "$NUM" "$RP_REVIEWS" \
        "$([ "$RP_PIPELINE" = 1 ] || printf '%s' "$SHA")" || RP_DISMISS_RC=$?; }
      # THE WATERMARK (BH-989). Written only when the list was readable AND
      # nothing that had to go was refused, so an unreadable list or a refused
      # dismissal leaves no watermark and the next tick retries. It is MERGED
      # into the row and never replaces `sha`/`verdict`: merge_retry reads
      # `.verdict` and returns at its first check on a row that has none, so a
      # pipeline PR's watermark-only row stays inert.
      [ "$RP_REVIEWS_RC" = 0 ] && [ "$RP_DISMISS_RC" = 0 ] \
        && rp_state_write --arg n "$NUM" --arg s "$SHA" '.[$n] = ((.[$n] // {}) + {ledger_sha:$s})'
    fi
    [ "$RP_PIPELINE" = 1 ] && continue
  fi
  # >>> review-prs rereview request (BH-1794; tests/fixround-preflight.bh-1794-test.sh drives this)
  # A HEAD THIS LANE BLOCKED MAY BE ASKED FOR ONCE MORE. bin/blocked-resolver.sh's
  # fix-round preflight answers a verdict whose only blocker is stale PR-body
  # evidence (CI green on this head) by rewriting the body's live-CI block and
  # posting a PR comment carrying `<!-- harness:rereview-requested <sha> -->`
  # instead of buying a fix round — project-3 #378 paid for a second round only to
  # refresh that block. The request is honoured ONCE per head (`rereq_sha`,
  # kept across the verdict write below), only on a head whose verdict on
  # record is REQUEST_CHANGES, and the comments are read only then: an approved
  # or unreviewed head costs no read.
  # ONLY A VERDICT AUTHOR CAN ASK (BH-1992). The PR body is anybody's to edit,
  # so the marker there triggers nothing; the request counts only in a comment
  # whose author passes harness_verdict_author_match (the hub App posts it). A
  # comments list that will not read asks for nothing this tick (fail closed:
  # the verdict on record stands).
  # The request is only SPENT (rereq_sha) at `# >>> review-prs rereview consume`,
  # after the green-CI debounce, so a head still waiting on CI keeps it.
  RP_REREQ=0
  if [ "$DONE" = "$SHA" ] && [ "${REVIEW_REREVIEW_ON_REQUEST:-1}" = 1 ] \
     && command -v frp_rereview_requested >/dev/null 2>&1 \
     && command -v harness_verdict_author_match >/dev/null 2>&1 \
     && command -v gh_rest_issue_comments >/dev/null 2>&1 \
     && [ "$(jq -r --arg n "$NUM" '.[$n].verdict // ""' "$STATE" 2>/dev/null)" = REQUEST_CHANGES ] \
     && [ "$(jq -r --arg n "$NUM" '.[$n].rereq_sha // ""' "$STATE" 2>/dev/null)" != "$SHA" ]; then
    # To a file, never inside $( ): GH_REST_STATUS and the budget accounting live
    # in this shell (tests/gh-rest-no-subshell-lint.sh). An unreadable list is '[]'.
    RP_COMS_F=$(mktemp "${TMPDIR:-/tmp}/review-prs-rq.XXXXXX") || RP_COMS_F=/dev/null
    [ "$RP_COMS_F" = /dev/null ] || gh_rest_issue_comments "$SLUG" "$NUM" > "$RP_COMS_F" 2>/dev/null || echo '[]' > "$RP_COMS_F"
    while IFS=$'\t' read -r RP_RQ_LOGIN RP_RQ_B64; do
      [ -n "${RP_RQ_LOGIN:-}" ] && [ -n "${RP_RQ_B64:-}" ] || continue
      # the operator login a PAT lane posts as asks too (BH-8466); the tag is the marker
      harness_verdict_author_match "$RP_RQ_LOGIN" || harness_own_review_match "$RP_RQ_LOGIN" 2>/dev/null || continue
      if frp_rereview_requested "$(printf '%s' "$RP_RQ_B64" | base64 -d 2>/dev/null)" "$SHA"; then
        RP_REREQ=1
        echo "$(STAMP) [$PROJECT] #$NUM @${SHA:0:7} re-review requested by $RP_RQ_LOGIN in a PR comment (fix-round preflight: the only blocker was stale evidence) — this head is reviewed once more when its CI is green, with the live CI in the prompt REREVIEW_REASON=rereq" >> "$LOG"
        break
      fi
    done < <(jq -r '.[]? | [(.user.login // ""), ((.body // "") | @base64)] | @tsv' "$RP_COMS_F" 2>/dev/null)
    [ "$RP_COMS_F" = /dev/null ] || rm -f "$RP_COMS_F"
  fi
  # <<< review-prs rereview request
  # BH-2545: an APPROVE on record from the trivial route's cheap model is
  # advisory. It merged nothing, so this head is reviewed again on the full
  # model, and that review's verdict is the one that can merge it.
  RP_ESCALATE=0
  RP_STALECR=0   # BH-5396: set by `# >>> review-prs stale cr`
  RP_PROVBUY=0   # BH-4134: set by `# >>> review-prs bought` for a fallback-served APPROVE
  if [ "$DONE" = "$SHA" ] \
     && [ "$(jq -r --arg n "$NUM" 'if .[$n].trivial == "1" then .[$n].verdict // "" else "" end' "$STATE" 2>/dev/null)" = APPROVE ]; then
    RP_ESCALATE=1
    echo "$(STAMP) [$PROJECT] #$NUM @${SHA:0:7} the APPROVE on record is the trivial route's advisory read — re-reviewing on the full model before anything can merge it REREVIEW_REASON=stepup" >> "$LOG"
  fi
  if [ "$DONE" = "$SHA" ] && [ "$RP_REREQ" = 0 ] && [ "$RP_ESCALATE" = 0 ]; then      # this head already reviewed
    merge_retry "$NUM" "$SHA" "$AUTHOR"   # ... but an APPROVE on it may still be unlanded
    continue
  fi

  # >>> review-prs verdict replay (BH-2310; tests/review-prs-replay.bh-2310-test.sh drives this block)
  # THE HEAD MOVED BUT THE PATCH DID NOT. A fix round that only merged main, or a
  # rebase that carried every commit across unchanged, is the change a reviewer
  # already judged. bin/lib/patch-same.sh proves that from the commits themselves
  # (only clean main merges since the reviewed head, or a byte-exact patch-id),
  # with no model. The standing verdict is REPLAYED onto the new head: the
  # local row moves, the ledger verdict is rebound (job_verdict_rebind), and no
  # agent call is made. The verdict is replayed as it stood, REQUEST_CHANGES
  # included: an unchanged patch fixes nothing. Nothing is posted to, or dismissed
  # on, GitHub, so a lead's or a human's CHANGES_REQUESTED stands exactly as it
  # did (bin/lib/block-gate.sh bg_cr_standing, #2273). Anything it cannot prove,
  # including a repo with no checkout here or a fetch that fails, falls through to
  # today's path and buys the review.
  RP_PREV_V=$(jq -r --arg n "$NUM" '.[$n].verdict // ""' "$STATE" 2>/dev/null)
  if [ -n "$DONE" ] && [ "$DONE" != "$SHA" ] && [ -n "$RP_PREV_V" ] \
     && command -v patch_same >/dev/null 2>&1 && [ -d "$REPO_DIR/.git" ] \
     && patch_same_fetch "$REPO_DIR" "$DONE" "$SHA" \
     && RP_HOW=$(patch_same "$REPO_DIR" origin/main "$DONE" "$SHA"); then
    rp_state_write --arg n "$NUM" --arg s "$SHA" --arg d "$DONE" --arg h "$RP_HOW" \
      '.[$n] = ((.[$n] // {}) + {sha:$s, replayed_from:$d, replay_how:$h})' || true
    RP_RB="not rebound"
    if command -v job_verdict_rebind >/dev/null 2>&1; then
      job_verdict_rebind "https://github.com/$SLUG/pull/$NUM" "$SHA" >/dev/null 2>&1 && RP_RB="ledger rebound"
    fi
    echo "$(STAMP) [$PROJECT] #$NUM @${SHA:0:7} verdict REPLAYED from ${DONE:0:7} ($RP_PREV_V): own patch unchanged ($RP_HOW), $RP_RB — no review bought" >> "$LOG"
    command -v review_saving_event >/dev/null 2>&1 \
      && review_saving_event "$PROJECT" review-prs "$SLUG" "$NUM" "$SHA" REUSED "from=${DONE:0:12} to=${SHA:0:12} how=$RP_HOW" || true
    merge_retry "$NUM" "$SHA" "$AUTHOR"
    continue
  fi
  # <<< review-prs verdict replay
  # >>> review-prs stale cr (BH-5396; tests/review-prs-stale-cr.bh-5396-test.sh drives this)
  # A NEW HEAD AFTER THIS LANE'S OWN REQUEST_CHANGES, ON AN EXTERNAL PR, IS
  # REVIEWED ON GITHUB. The author pushed a fix, and the only thing that clears
  # the blocking review they are looking at is this lane's own review of the new
  # head. Another lane's verdict at that head (an mc_rereview rrverdict, a
  # foreign build or rescue row in D1) posts nothing and dismisses nothing, so
  # settling the head from it left project-3 #481's CHANGES_REQUESTED standing with
  # the fix never judged on the PR. Under RP_STALECR the D1 rung of rp_rehydrate
  # and the review_bought reuse are skipped (GitHub still answers "did this lane
  # already post at this head"), and the call-guard key carries ~stalecr: one
  # more read of this head under its own key. Harness-authored PRs are out:
  # their REQUEST_CHANGES posts as a non-blocking COMMENT review.
  RP_STALECR=0
  if [ -n "$DONE" ] && [ "$DONE" != "$SHA" ] && [ "$RP_PREV_V" = REQUEST_CHANGES ] \
     && ! harness_pr_author_match "$AUTHOR"; then
    RP_STALECR=1
  fi
  # <<< review-prs stale cr

  # Re-review debounce (the operator, 2026-08-31): a PR's FIRST review runs immediately,
  # but once it has a verdict on record, each new head waits for green CI before
  # burning a review session — push-iterating authors otherwise cost one Fable
  # run per push (42-review night on project-1, 08-30), and heads that die in CI
  # get reviewed for nothing. Checks are read via the actions/runs API because
  # the fleet PAT 403s on statusCheckRollup. An API error or a repo with no CI
  # runs must wait too: immediately after a push GitHub commonly
  # returns an empty run list for a few seconds, and failing open there defeats
  # the debounce. A long wait alerts for attention, but never spends by
  # bypassing the green-CI requirement.
  #
  # E2E policy (the operator, 2026-09-12; docs/E2E-POLICY.md point 6): browser E2E /
  # Production-QA / deployment-targeted runs are ADVISORY here unless the
  # diff touches an E2E path (bin/lib/e2e-paths.sh is the one definition).
  # project-4's E2E judges prod and was red on main for 9 days; under the old rule
  # every non-UI head on project-4 waited 12h for a green that could never come,
  # then alerted. A non-E2E diff cannot have broken the browser suite, so its
  # red (or its never-reporting "expected" context) must not hold the review.
  # When the diff DOES touch an E2E path the run is substance again and a red
  # one defers exactly as before. Fail closed: no lib, or the changed-file
  # list unavailable, and every run counts (the pre-policy behaviour).
  if [ -n "$DONE" ]; then
    CI_WAIT=""
    E2E_HIT=1; E2E_RE=""
    if [ -r "$HARNESS/bin/lib/e2e-paths.sh" ]; then # shellcheck source=bin/lib/e2e-paths.sh
      . "$HARNESS/bin/lib/e2e-paths.sh"; E2E_RE="$E2E_CHECK_RE"
      if CHANGED=$(gh pr diff "$NUM" -R "$SLUG" --name-only 2>/dev/null) && [ -n "$CHANGED" ]; then
        e2e_path_hit <<<"$CHANGED" || E2E_HIT=0
      fi
    fi
    # Where the CI read says which credential answered, and about which PR: the
    # read happens inside a command substitution, so the helper writes the line
    # rather than handing back a variable that dies with the subshell.
    GH_CI_READ_LOG="$LOG" GH_CI_READ_TAG="[$PROJECT] #$NUM @${SHA:0:7}"
    if ! RUNS=$(gh_ci_api "$SLUG" --paginate \
      "repos/$SLUG/actions/runs?head_sha=$SHA&per_page=100" \
      -q '.workflow_runs[] | {s:.status, c:.conclusion, n:.name}' 2>/dev/null | jq -s '.'); then
      CI_WAIT="CI status unavailable (default token and read-only App token both refused)"
    elif [ "$RUNS" = "[]" ]; then
      CI_WAIT="CI has no runs yet"
    elif ! NOTGREEN=$(jq -r --arg re "$E2E_RE" --argjson hit "$E2E_HIT" \
        '[.[] | select($hit == 1 or $re == "" or ((.n // "") | test($re; "i") | not))
              | select(.s != "completed" or ((.c // "") | IN("success","skipped","neutral") | not))] | length' <<<"$RUNS" 2>/dev/null); then
      CI_WAIT="CI status unreadable"
    elif [ "${NOTGREEN:-0}" -gt 0 ]; then
      CI_WAIT="$NOTGREEN run(s) pending/red"
    elif [ "$E2E_HIT" -eq 0 ] && [ -n "$E2E_RE" ] && \
         [ "$(jq -r --arg re "$E2E_RE" '[.[] | select((.n // "") | test($re; "i") | not)] | length' <<<"$RUNS" 2>/dev/null || echo 0)" -eq 0 ]; then
      # Only advisory runs exist on this head (the fast jobs have not been
      # created yet, or the repo has none): that is no evidence, so wait —
      # the same fail-closed reading as an empty run list.
      CI_WAIT="CI has no substantive (non-E2E) runs yet"
    elif [ "$E2E_HIT" -eq 0 ] && [ -n "$E2E_RE" ]; then
      # Substance is green; say which advisory runs were set aside so the log
      # explains a review that started under a red E2E badge.
      ADVISORY=$(jq -r --arg re "$E2E_RE" '[.[] | select((.n // "") | test($re; "i"))
        | select(.s != "completed" or ((.c // "") | IN("success","skipped","neutral") | not)) | (.n // "?") + "=" + (.c // .s)] | unique | join(", ")' <<<"$RUNS" 2>/dev/null)
      [ -n "$ADVISORY" ] && echo "$(STAMP) [$PROJECT] #$NUM @${SHA:0:7} re-review proceeds: substance green, E2E-class run(s) advisory (no E2E path in diff): $ADVISORY" >> "$LOG"
    fi

    if [ -n "$CI_WAIT" ]; then
      NOW=$(date -u +%s)
      DEFERRED=$(jq -r --arg n "$NUM" '.[$n].deferred_sha // ""' "$STATE")
      DEFERRED_AT=$(jq -r --arg n "$NUM" '.[$n].deferred_at // 0' "$STATE")
      if [ "$DEFERRED" != "$SHA" ] || [ "$DEFERRED_AT" -le 0 ]; then
        rp_state_write --arg n "$NUM" --arg s "$SHA" --argjson at "$NOW" \
          '.[$n] = ((.[$n] // {}) + {deferred_sha:$s, deferred_at:$at} | del(.ci_alerted_sha))'
        echo "$(STAMP) [$PROJECT] #$NUM @${SHA:0:7} re-review deferred — CI not green ($CI_WAIT); reviews when green" >> "$LOG"
      elif [ $((NOW - DEFERRED_AT)) -ge "${REVIEW_CI_STALE_SECS:-43200}" ]; then
        ALERTED=$(jq -r --arg n "$NUM" '.[$n].ci_alerted_sha // ""' "$STATE")
        if [ "$ALERTED" != "$SHA" ]; then
          HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[$PROJECT] #$NUM @${SHA:0:7} re-review has waited at least ${REVIEW_CI_STALE_SECS:-43200}s for green CI ($CI_WAIT) — inspect the checks; the review remains deferred"
          rp_state_write --arg n "$NUM" --arg s "$SHA" '.[$n] = ((.[$n] // {}) + {ci_alerted_sha:$s})'
        fi
      fi
      RP_CI_DEFERRED=1
      continue
    fi
  fi

  # THE LAST FREE READ. Everything above this line decided that this head has no
  # verdict in the ledger and no reason to wait; the free GitHub reads follow,
  # and the money moves at agent-call.sh below.
  # >>> review-prs gh dedup call (BH-1017)
  # BH-2315: rc 0 replayed a verdict, rc 3 is HELD (D1 unreadable) — neither buys.
  if [ "${RP_REREQ:-0}" != 1 ]; then
    RP_RH=0
    if [ "${RP_STALECR:-0}" = 1 ]; then rp_rehydrate "$NUM" "$SHA" gh-only || RP_RH=$?   # BH-5396
    else rp_rehydrate "$NUM" "$SHA" || RP_RH=$?; fi
    case "$RP_RH" in 0|3) continue ;; esac
  fi
  # <<< review-prs gh dedup call

  # Full diff goes to a FILE the reviewer can Read — the old 100KB truncation
  # guarded a kernel argv limit that died when agent-call moved prompts to
  # stdin (2026-08-05), and it was blocking legitimate external PRs (collaborator-1,
  # 2026-08-12: project-2 #287, project-1 #482). 250KB rides inline for immediate
  # context; anything bigger is read from the file. No hard ceiling: PR size
  # is an engineering-judgment call for the review, not a truncation artifact.
  mkdir -p "$HARNESS/state/pr-review-diffs"
  DIFF_FILE="$HARNESS/state/pr-review-diffs/${SLUG##*/}-$NUM.diff"
  gh pr diff "$NUM" -R "$SLUG" > "$DIFF_FILE" 2>/dev/null
  DIFF=$(head -c 250000 "$DIFF_FILE")
  if [ "$(stat -c%s "$DIFF_FILE" 2>/dev/null || echo 0)" -gt 250000 ]; then
    DIFF="$DIFF

[INLINE DIFF SHOWS THE FIRST 250KB. The COMPLETE diff is saved at $DIFF_FILE — Read the remainder from that file before judging; never verdict on a partial read. If the changes are genuinely separable, you may also note that a split would shrink revert blast radius — as advice, not a blocking demand.]"
  fi
  [ -n "$DIFF" ] || continue
  # >>> review-prs migration diff lint (BH-7667)
  # A plain CREATE INDEX on a table in review.large_tables.<project>, read from
  # this diff: RP_MIL holds the finding lines. No row = no lint. A red lint
  # refuses the review_bought reuse below and turns the verdict after the cap.
  RP_MIL=""; RP_MILT=""
  command -v mil_scan >/dev/null 2>&1 && RP_MILT=$(mil_tables "$PROJECT" 2>>"$LOG")
  if [ -n "$RP_MILT" ]; then
    RP_MILRC=0; RP_MIL=$(mil_scan "$DIFF_FILE" "$RP_MILT" "$PROJECT") || RP_MILRC=$?
    case "$RP_MILRC" in
      0|1) echo "$(STAMP) [$PROJECT] #$NUM @${SHA:0:7} migration lint: $(grep -c '[^[:space:]]' <<<"$RP_MIL") finding(s)" >> "$LOG" ;;
      *) RP_MIL=""; echo "$(STAMP) [$PROJECT] #$NUM @${SHA:0:7} migration lint could not run (rc $RP_MILRC)" >> "$LOG" ;;
    esac
  fi
  # <<< review-prs migration diff lint
  RP_PRJ=""; gh_rest_var RP_PRJ GET "repos/$SLUG/pulls/$NUM" 2>/dev/null || RP_PRJ=""
  BODY=$(jq -r '.body // ""' <<<"${RP_PRJ:-null}" 2>/dev/null | head -c 4000)
  # Prior harness review + author replies give the re-review its context.
  # BH-1585: two REST reads (reviews, then issue comments), each to a file, and
  # the same six-entry tail the GraphQL read produced. An unreadable half is an
  # empty half.
  RP_REVF=$(mktemp "${TMPDIR:-/tmp}/review-prs-rev.XXXXXX"); RP_COMF=$(mktemp "${TMPDIR:-/tmp}/review-prs-com.XXXXXX")
  gh_rest GET "repos/$SLUG/pulls/$NUM/reviews?per_page=100" > "$RP_REVF" 2>/dev/null || echo '[]' > "$RP_REVF"
  gh_rest_issue_comments "$SLUG" "$NUM" > "$RP_COMF" 2>/dev/null || echo '[]' > "$RP_COMF"
  THREAD=$(jq -rs '[(.[0][]? | {a:.user.login, b:(.body // "")}), (.[1][]? | {a:.user.login, b:(.body // "")})] | .[-6:] | .[] | "--- \(.a):\n\(.b)"' "$RP_REVF" "$RP_COMF" 2>/dev/null | head -c 20000)
  rm -f "$RP_REVF" "$RP_COMF"

  # >>> review-prs rereview consume (BH-1794)
  # The request is spent HERE, after the CI debounce and the diff read and
  # immediately before the prompt: a head whose CI is still pending, or whose
  # diff would not read, keeps its request for the next tick instead of losing
  # it to a `continue` above. A write that fails leaves RP_REREQ at 0 for the
  # record's sake only — the review below still runs this once.
  # The value it replaces is kept (RP_REREQ_PRIOR): a call agent-call.sh
  # refuses before billing bought no review, so the request is handed back.
  RP_REREQ_PRIOR=""
  if [ "${RP_REREQ:-0}" = 1 ]; then
    RP_REREQ_PRIOR=$(jq -r --arg n "$NUM" '.[$n].rereq_sha // ""' "$STATE" 2>/dev/null)
    rp_state_write --arg n "$NUM" --arg s "$SHA" '.[$n] = ((.[$n] // {}) + {rereq_sha:$s})' || true
  fi
  # <<< review-prs rereview consume
  # >>> review-prs live ci (BH-1794)
  # THE REVIEWER IS NOT BLIND TO CI. Its token may 403 on check-runs (project-3 #378:
  # a green head was blocked on a PR-body Evidence block that still said red),
  # so the lane hands it what GitHub reports for THIS head, read on the lane's
  # own credential ladder. Unreadable is written as unreadable, never as red.
  RP_LIVE_CI=""
  if [ "${REVIEW_LIVE_CI:-1}" = 1 ] && command -v frp_ci >/dev/null 2>&1; then
    RP_LIVE_CI=$(frp_ci_text "$(frp_ci "$SLUG" "$SHA")")
  fi
  # <<< review-prs live ci
  # BH-7123: the `## Review level` section (mode, speed thresholds, core flows),
  # read from settings rows at call time. Empty when the lib is not loaded.
  RP_LEVEL_NOTE=""
  command -v rl_prompt_note >/dev/null 2>&1 && RP_LEVEL_NOTE=$(rl_prompt_note "$PROJECT" 2>/dev/null) || RP_LEVEL_NOTE=""
  PROMPT="Adversarial review of an EXTERNAL team PR on $SLUG (#$NUM by $AUTHOR): \"$TITLE\".
You are the harness reviewer. The repo checkout at $REPO_DIR is on main (may be behind the PR); use it to read surrounding context. Judge ONLY the diff below.${RP_SCRATCH:+
Scratch space: if you need a checkout of the PR head or any temporary file, create it under $RP_SCRATCH (for example: git -C $REPO_DIR worktree add --detach $RP_SCRATCH/head $SHA). Create nothing else under /tmp. The harness deletes $RP_SCRATCH when this review ends.}

Apply the standing iron laws (from /root/.claude/CLAUDE.md, which you must read) under its REVIEW LEVELS rule (BH-7123): a finding is a BLOCK only when it carries a class from the ALWAYS-BLOCK list (data-loss, tenant-leak, auth-bypass, money, destructive-migration, red-build, core-flow-broken, wrong-data, secret, model-id, weakened-test, scalable-tests, user-flows); every other finding, an iron law included, is a [NOTE] that rides in the review for a later cleanup and does not stop the merge. The laws:additive-only schema + RLS on new tables (Supabase projects), indexes for every query on a new table in the same migration (proven with EXPLAIN on seeded data), no per-row correlated subquery over a large table, a retention rule (scheduled delete/archive, window in a settings row) for every growing table, DB-driven config not hardcoded (incl. no hardcoded claude-* model strings), exactly-once writes where money/records move, dedup-before-spend on metered/billable APIs (transcription, LLM tokens, embeddings, enrichment, SMS/email — a PERSISTED 'have we already paid for this?' check must run BEFORE the billable call, never after; 'succeeded but returned nothing' is still billed and is TERMINAL, never retried; key the ledger on a stable fingerprint of the input, not a presigned/tokenized URL), De-AI voice on AI->human surfaces, mobile-responsive UI, no native dialogs, sortable data tables, no dead rows, VERCEL_URL self-fetch ban, CRON_SECRET .trim(), new-env-var-must-be-listed rule, and FOLLOW-UPS ARE GROUPED: a follow-up found during a build or review goes into ONE follow-up ticket per screen or flow, with every item as a checklist, never one ticket per finding (BH-6902). PERFORMANCE BY DEFAULT (BH-6946), each one a [NOTE] (a BLOCK only on a measured regression on a key screen over the REVIEW LEVELS thresholds, or on a perf ticket): a new sequential await over independent reads; a list read in a layout where a count would do; a route without loading.tsx; a repeated config read without a request memo; a list query without a matching index at seeded volume; unbounded rows to the client; a speed claim without before and after numbers; a client snapshot that holds a token, is not keyed by user and company, or survives sign-out; a key screen with two or more independent requests in sequence before its first content.
The ALWAYS-BLOCK list also has hardcoded-knob (BH-7945): a new or changed literal limit, rate, threshold, price, timeout, cap or max_tokens with no DB row or knob read; the literal may stay only as the documented fallback of a knob that exists.

Also judge: correctness bugs, security (injection, authz, secrets in code), and honest scope.

Verification limits: you may read files, but do NOT run installs/builds (no build lock held). Say plainly in your output that this is a static review without build verification.

PR body:
$BODY
${RP_LIVE_CI:+
LIVE CI ON THIS HEAD, read from GitHub by the harness just now (trust it over any Evidence block or CI claim in the PR body, which may describe an older head). A run that shows cancelled was superseded by a newer push and the merge queue re-runs CI on the head it merges: cancelled is not red and not a finding. Only a FAILED run is [BLOCK red-build]:
$RP_LIVE_CI
}
Recent review thread (your prior findings may be here; check whether they were addressed):
$THREAD

DIFF:
$DIFF

Output format: start with a 2-4 sentence summary, then numbered findings (each tagged [BLOCK <class>] with a class from the ALWAYS-BLOCK list, or [NOTE]; file:line; concrete fix each), then EXACTLY two final lines:
TIER: 1 or 2   (1 = trivial/safe to auto-merge: docs, copy, isolated fix with tests, no schema/auth/money/cron surface; 2 = higher-risk class (reported, not gated))
VERDICT: APPROVE or REQUEST_CHANGES   (REQUEST_CHANGES only when at least one [BLOCK <class>] finding stands; a review whose findings are all [NOTE] is APPROVE, and the notes are the cleanup list)
${RP_LEVEL_NOTE:+
$RP_LEVEL_NOTE}
Style (external teams pay tokens to read this): terse, direct, declarative. No preamble beyond the static-review disclaimer, no restating the PR body, no inventory of everything that checked out — at most one sentence of verified-good context. A finding is: what breaks, where, the fix. Cut every sentence that does not change what the author does next."

  # >>> review-prs bought (BH-3930; tests/review-dedupe-lanes.bh-3940-test.sh drives this block)
  # A VERDICT ALREADY PAID FOR ON THIS EXACT HEAD IS NOT BOUGHT AGAIN.
  # review_bought (bin/lib/review-bought.sh) asks the D1 rows and this box's
  # history. Here, after every read and debounce and before the in-flight charge
  # and the claim row, so a skip charges no attempt and writes no row. A rereq or
  # a step-up is never skipped: each is a named second read. rc 1 (a read failed)
  # and rc 2 (a miss) buy the review as before. Only class `approve` records an
  # APPROVE; anything else records REQUEST_CHANGES, never an inferred approval.
  # A REUSED APPROVE CARRIES ITS PROVENANCE (BH-4134). `served` is the hit's
  # serving lane when review_bought_prov says claude, and `reused-unknown`
  # otherwise, which merge_retry's rp_prov_is_claude holds exactly as it holds
  # a `rehydrated` row, with the same one beat per head. A fallback-served
  # APPROVE is not reused at all: this head buys one read under ~prov.
  if [ "${RP_REREQ:-0}" = 0 ] && [ "${RP_ESCALATE:-0}" = 0 ] && [ "${RP_STALECR:-0}" = 0 ] \
     && [ -z "${RP_MIL:-}" ] \
     && command -v review_bought >/dev/null 2>&1 && review_dedupe_on \
     && review_bought "$SLUG" "$NUM" "$SHA" >/dev/null 2>&1; then
    RP_RB_V=REQUEST_CHANGES; [ "${RB_CLASS:-}" = approve ] && RP_RB_V=APPROVE
    RP_RB_PROV=$(review_bought_prov 2>/dev/null) || RP_RB_PROV=unknown
    if [ "$RP_RB_V" = APPROVE ] && [ "$RP_RB_PROV" = fallback ]; then
      RP_PROVBUY=1
      echo "$(STAMP) [$PROJECT] #$NUM @${SHA:0:7} ${RB_SOURCE:-}'s APPROVE on ${SHA:0:7} was served by ${RB_SERVED:-}, a fallback lane — not reused; buying one read under ~prov" >> "$LOG"
    else
      RP_RB_SV=reused-unknown; [ "$RP_RB_PROV" = claude ] && RP_RB_SV="${RB_SERVED:-}"
      rp_state_write --arg n "$NUM" --arg s "$SHA" --arg v "$RP_RB_V" --arg r "${RB_SOURCE:-}" --arg sv "$RP_RB_SV" \
        '.[$n] = {sha:$s, verdict:$v, reused_from:$r, served:$sv}
                + ((.[$n] // {}) | {ledger_sha, deferred_sha, deferred_at, ci_alerted_sha, rereq_sha}
                   | with_entries(select(.value != null)))' || true
      [ "$RP_RB_V" = APPROVE ] && [ "$RP_RB_SV" = reused-unknown ] && rp_withheld_beat "$NUM" "$SHA" "${RB_SOURCE:-} verdict" reused
      review_skip_log "$LOG" "$SLUG" "$NUM" "$SHA" review-prs
      merge_retry "$NUM" "$SHA" "$AUTHOR"
      continue
    fi
  fi
  # <<< review-prs bought
  # >>> review-prs inflight (BH-1017; tests/review-prs-gh-dedup-test.sh drives this block)
  # THE IN-FLIGHT MARKER, and the genuine last free moment: the diff, the body
  # and the thread are all in hand, every `continue` above has been taken, and
  # the only thing left is the session.
  #
  # Until BH-1017 the ledger learned about a head only AFTER agent-call
  # returned, so a tick killed mid-review (a box reboot, an OOM, a deploy that
  # rolls the lane) left no trace and the next tick bought the same head again,
  # for ever, with nothing counting the attempts. The marker is written before
  # the money moves and replaced wholesale by the verdict record after, so a
  # completed review clears it by itself.
  #
  # IT SITS HERE AND NOT ABOVE THE READS ON PURPOSE. The first cut of this
  # block ran before `gh pr diff`, `[ -n "$DIFF" ] || continue` and two
  # `gh pr view`s — so two ticks of a transient GitHub read failure spent the
  # whole attempt budget, froze the head terminally and paged "started a review
  # 2 times" when not one session had been bought, and the head was never
  # reviewed again until the author pushed. The budget counts SESSIONS, so it
  # may only be charged where a session is actually about to start.
  #
  # Bounded at REVIEW_INFLIGHT_MAX (2): a crashed review is owed exactly one
  # retry, and a head that dies twice mid-call is a head that needs a person.
  # rp_freeze writes the terminal record — sha, no verdict — or the counter
  # could never stop the re-buy.
  # NO MODEL, NO SESSION, NO CHARGE (BH-1510.1): checked before the marker, so a
  # tick with no route spends none of this head's attempt budget.
  if [ -z "$RP_MODEL" ]; then
    echo "$(STAMP) [$PROJECT] #$NUM @${SHA:0:7} no model route for build.review (and no REVIEW_MODEL) — no session bought, head not charged" >> "$LOG"
    continue
  fi
  IF_SHA=$(jq -r --arg n "$NUM" '.[$n].reviewing_sha // ""' "$STATE" 2>/dev/null)
  IF_N=$(jq -r --arg n "$NUM" '.[$n].reviewing_attempts // 0' "$STATE" 2>/dev/null)
  case "${IF_N:-0}" in ''|*[!0-9]*) IF_N=0 ;; esac
  [ "$IF_SHA" = "$SHA" ] || IF_N=0
  if [ "$IF_N" -ge "${REVIEW_INFLIGHT_MAX:-2}" ]; then
    rp_freeze "$NUM" "$SHA" reviewing_gave_up
    HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[$PROJECT] #$NUM @${SHA:0:7} started a review ${IF_N} times without ever recording a verdict — the lane stops buying this head (it resumes when the author pushes a new one); https://github.com/$SLUG/pull/$NUM needs a look"
    echo "$(STAMP) [$PROJECT] #$NUM @${SHA:0:7} in-flight cap reached (${IF_N}) — head frozen, no session bought" >> "$LOG"
    continue
  fi
  IF_N=$((IF_N + 1))
  rp_state_write --arg n "$NUM" --arg s "$SHA" --argjson c "$IF_N" --argjson at "$(date -u +%s)" \
    '.[$n] = ((.[$n] // {}) + {reviewing_sha:$s, reviewing_attempts:$c, reviewing_at:$at})'
  # <<< review-prs inflight

  # A real review is about to run: this is the first moment the tick has work
  # worth a row, and the last moment before the money is spent.
  review_claim "$NUM" "$SHA"
  # >>> review-prs trivial route (BH-2545; tests/review-saving.bh-2545-test.sh drives this block)
  # A diff under the line cap whose class is in REVIEW_TRIVIAL_ROUTE_CLASSES
  # (docs by default) is reviewed by the review.trivial route when
  # REVIEW_TRIVIAL_MODE=route; in shadow (the default) it is only recorded.
  # Never skipped: every head below still makes its call. A routed APPROVE is
  # ADVISORY (RP_ADVISORY below): it posts as a comment, merges nothing, writes
  # no ledger verdict, and the next tick re-reviews the head on RP_MODEL. So a
  # cheap read is never the only read behind a merge. The escalated re-review
  # is never routed.
  RP_MODEL="$RP_MODEL_TICK"; RP_TRIVIAL=""
  if [ "${RP_ESCALATE:-0}" = 1 ]; then
    command -v review_saving_event >/dev/null 2>&1 \
      && review_saving_event "$PROJECT" review-prs "$SLUG" "$NUM" "$SHA" TRIVIAL_ESCALATED "model=$RP_MODEL" || true
  elif command -v review_trivial_pick >/dev/null 2>&1; then
    review_trivial_pick "$DIFF_FILE" "$PROJECT" "$RP_MODEL"
    if [ "$RT_ACTION" = routed ]; then RP_MODEL="$RT_MODEL"; RP_TRIVIAL=1; fi
    if [ -n "$RT_ACTION" ]; then
      echo "$(STAMP) [$PROJECT] #$NUM @${SHA:0:7} trivial $RT_CLASS $RT_LINES lines: $RT_ACTION model=$RP_MODEL" >> "$LOG"
      RP_RT_V=$(printf 'TRIVIAL_%s' "$RT_ACTION" | tr 'a-z-' 'A-Z_')
      review_saving_event "$PROJECT" review-prs "$SLUG" "$NUM" "$SHA" "$RP_RT_V" "class=$RT_CLASS lines=$RT_LINES model=$RP_MODEL" || true
    fi
  fi
  # <<< review-prs trivial route
  # BH-5284: every read, debounce and ledger write for this head is done, in PR
  # order; the tick may move on to the next PR while this one is reviewed.
  command -v rpool_gate_open >/dev/null 2>&1 && rpool_gate_open
  OUT_FILE=$(mktemp)
  # Prompt goes via @file, never argv: with the diff riding inline the prompt
  # regularly tops 128KB, and a single argv element that big fails execve with
  # E2BIG — the reviewer never runs, no cost row, and the empty output reads as
  # "no verdict" (project-4 #1181/#1168, 2026-08-14: 150KB diff, 13 silent retries).
  PROMPT_FILE=$(mktemp)
  printf '%s' "$PROMPT" > "$PROMPT_FILE"
  # K3: the work is THIS PR at THIS head. bin/agent-call.sh's call-guard counts
  # paid reviews of it in harness-jobs (stage review-head: 1 a day by default,
  # BH-3930), so a wiped $STATE — the 09-17 runaway, 52 reviews of one head —
  # cannot re-buy it.
  # BH-2457: a D1-hold fallback buys on the subscription runners only, and pins
  # K3's metered refusal on so an operator's =0 cannot open metered spend here.
  RP_AC_ENV=()
  [ "${RP_D1_SUBONLY:-0}" = 1 ] && RP_AC_ENV=(AGENT_CALL_RUNNERS="$RP_SUB_RUNNERS" CALL_GUARD_FAIL_CLOSED_METERED=1)
  # BH-2537: AGENT_CALL_PR names the PR for the cost row; no slug, no URL.
  # BH-2492: the +-guard keeps an empty array legal under set -u on bash < 4.4.
  # BH-3930: the guard key is the one per-head key every review lane shares,
  # `review:<repo>#<pr>@<head>` on stage review-head (K=1), so this head is paid
  # for once across lanes. A rereq or a step-up names its reason and buys
  # exactly one more read under it.
  RP_REASON=""
  [ "${RP_REREQ:-0}" = 1 ] && RP_REASON=rereq
  [ "${RP_ESCALATE:-0}" = 1 ] && RP_REASON=stepup
  [ "${RP_PROVBUY:-0}" = 1 ] && RP_REASON=prov
  if [ "${RP_STALECR:-0}" = 1 ] && [ -z "$RP_REASON" ]; then
    RP_REASON=stalecr
    echo "$(STAMP) [$PROJECT] #$NUM @${SHA:0:7} new head after this lane's REQUEST_CHANGES on ${DONE:0:7} (external PR): reviewed on GitHub, not settled from another lane's verdict REREVIEW_REASON=stalecr" >> "$LOG"
  fi
  if command -v review_fp >/dev/null 2>&1; then
    RP_FP=$(review_fp "${SLUG:-$PROJECT}" "$NUM" "$SHA" "$RP_REASON")
  else
    RP_FP="review:${SLUG:-$PROJECT}#$NUM@$SHA${RP_REASON:+~$RP_REASON}"
  fi
  env ${RP_AC_ENV[@]+"${RP_AC_ENV[@]}"} AGENT_CALL_GUARD_STAGE=review-head AGENT_CALL_FP="$RP_FP" \
    AGENT_CALL_PR="${SLUG:+https://github.com/$SLUG/pull/$NUM}" \
  "$HARNESS/bin/agent-call.sh" review "$PROJECT" "$RP_MODEL" 2400 "$OUT_FILE" "@$PROMPT_FILE" >/dev/null 2>&1
  RP_AC_RC=$?
  # BH-5284: a call refused for a rate or concurrency limit (a 429, "overloaded",
  # the account's concurrency cap) bought no review either. It takes the
  # before-billing path below (no verdict, no no-verdict strike, the in-flight
  # charge and any re-review request handed back), and the pool pauses starts.
  RP_RATE_LIMITED=0
  case "$RP_AC_RC" in 0|74|75|76|77|78|79) ;;
    *) command -v rpool_rate_limited >/dev/null 2>&1 && rpool_rate_limited "$OUT_FILE" && RP_RATE_LIMITED=1 ;;
  esac
  [ "$RP_RATE_LIMITED" = 1 ] && echo "$(STAMP) [$PROJECT] #$NUM @${SHA:0:7} agent call hit a rate or concurrency limit (rc=$RP_AC_RC) — treated as before billing: no verdict recorded, the head is reviewed on a later tick" >> "$LOG" \
    && RP_AC_RC=75
  # >>> review-prs before-billing (K3; tests/fixround-preflight.bh-1794-test.sh T6c drives this)
  # 74..79 IS "NOTHING WAS CALLED AND NOTHING WAS BILLED" (bin/agent-call.sh's
  # contract): the lane's own gate, the call-guard's repeat refusal, no account
  # with headroom. $OUT_FILE holds a one-line marker, not a review, so it must
  # not reach the no-verdict path below (which would count a strike and page
  # "NO VERDICT twice" about a review nobody bought). The in-flight charge made
  # above is taken back for the same reason — that budget counts SESSIONS.
  case "$RP_AC_RC" in
    74|75|76|77|78|79)
      echo "$(STAMP) [$PROJECT] #$NUM @${SHA:0:7} agent-call returned before billing (rc=$RP_AC_RC: $(head -c 160 "$OUT_FILE" 2>/dev/null | tr '\n' ' ')) — nothing called, no verdict recorded; retries next tick" >> "$LOG"
      rp_state_write --arg n "$NUM" --argjson c "$((${IF_N:-1} - 1))" '.[$n] = ((.[$n] // {}) + {reviewing_attempts:$c})'
      # The re-review REQUEST spent at the consume block above is handed back
      # too: it asked for a review, and none was bought.
      if [ "${RP_REREQ:-0}" = 1 ]; then
        rp_state_write --arg n "$NUM" --arg p "${RP_REREQ_PRIOR:-}" \
          'if $p == "" then (.[$n] |= ((. // {}) | del(.rereq_sha))) else (.[$n] = ((.[$n] // {}) + {rereq_sha:$p})) end'
      fi
      rm -f "$OUT_FILE" "$OUT_FILE.runner" "$OUT_FILE.model" "$OUT_FILE.err" "$PROMPT_FILE"
      continue ;;
  esac
  # <<< review-prs before-billing
  REVIEW=$(cat "$OUT_FILE" 2>/dev/null)
  # The (runner, model) pair, not the runner word: a Claude model served through
  # the OpenRouter survival lane is a Claude read and records as one.
  SERVED=$(rp_out_prov "$OUT_FILE")
  rm -f "$OUT_FILE" "$OUT_FILE.runner" "$OUT_FILE.model" "$PROMPT_FILE"
  # Tolerant of bold/indent (383/401/403 all skipped on a formatting quirk), and
  # ANCHORED to the review's final block (bin/lib/verdict-parse.sh, BH-1625): a
  # REQUEST_CHANGES that quotes an earlier APPROVE is not an approval. Unknown
  # is empty, the no-verdict path below.
  VERDICT=$(printf '%s\n' "$REVIEW" | verdict_parse -w 'APPROVE|REQUEST_CHANGES' 2>/dev/null) || VERDICT=""
  TIER=$(grep -oE "TIER:? *\**[12]" <<<"$REVIEW" | grep -oE "[12]" | tail -1)
  # >>> review-prs level cap (BH-7123; tests/review-level-cap.bh-7123-test.sh drives the lib)
  # THE DEMOTER. A finding tagged BLOCK/HIGH/MEDIUM that names no ALWAYS-BLOCK
  # class (catalog/review-always-block.tsv) becomes `[NOTE demoted from …]`, and
  # a REQUEST_CHANGES with no standing BLOCK becomes APPROVE: the posted review
  # body, the GitHub review state and the ledger all follow the rewritten text.
  # review.mode=strict leaves the model's answer alone; shadow logs WOULD.
  # --golive (BH-7123 wave B): a go-live human step becomes `[HUMAN go-live]
  # <step>` and gates nothing while review.golive_gates_merge reads 0; the
  # review body carries it, and the lead's landing places the ticket hold.
  RL_OUT=""
  if [ -n "$VERDICT" ] && command -v rl_cap >/dev/null 2>&1; then
    RL_GOLIVE=stand; command -v rl_golive_opt >/dev/null 2>&1 && RL_GOLIVE=$(rl_golive_opt "$PROJECT" 2>/dev/null 7>&- 8>&-)
    printf '%s\n' "$REVIEW" > "$OUT_FILE.rl"
    RL_OUT=$(rl_cap "$OUT_FILE.rl" "$PROJECT" --approve APPROVE --block REQUEST_CHANGES --lens prs --golive "$RL_GOLIVE" 2>>"$LOG") && {
      REVIEW=$(cat "$OUT_FILE.rl")
      VERDICT=$(printf '%s\n' "$REVIEW" | verdict_parse -w 'APPROVE|REQUEST_CHANGES' 2>/dev/null) || VERDICT=""
    }
    rm -f "$OUT_FILE.rl"
    echo "$(STAMP) [$PROJECT] #$NUM @${SHA:0:7} review level: ${RL_OUT:-not applied} -> verdict ${VERDICT:-unknown}" >> "$LOG"
  fi
  # <<< review-prs level cap
  # >>> review-prs migration lint (BH-7667; tests/migration-index-lint.bh-7667-test.sh drives this block)
  # After the cap, so no demoter touches it: the lint lines (RP_MIL, from the
  # diff above) go into the posted review just before its verdict line, and the
  # verdict is REQUEST_CHANGES. mil_merge REPLACES the verdict line: two that
  # disagree read as unknown. An empty VERDICT stays on the no-verdict path.
  if [ -n "${RP_MIL:-}" ] && [ -n "$VERDICT" ]; then
    printf '%s\n' "$REVIEW" > "$OUT_FILE.mil"; printf '%s\n' "$RP_MIL" > "$OUT_FILE.milf"
    RP_MILREV=$(mil_merge "$OUT_FILE.mil" "$OUT_FILE.milf" REQUEST_CHANGES 'APPROVE|REQUEST_CHANGES' 2>/dev/null) && REVIEW="$RP_MILREV"
    rm -f "$OUT_FILE.mil" "$OUT_FILE.milf"
    VERDICT=REQUEST_CHANGES
    echo "$(STAMP) [$PROJECT] #$NUM @${SHA:0:7} migration lint: $(grep -c '[^[:space:]]' <<<"$RP_MIL") finding(s) -> REQUEST_CHANGES" >> "$LOG"
  fi
  # <<< review-prs migration lint
  # A cheap-model read (BH-2545 trivial route) is recorded at TIER 2 at most.
  # The tier is a label here: merge_step merges any APPROVE whatever its tier,
  # so what keeps a cheap read from merging is RP_ADVISORY, not this cap.
  if [ "${RP_TRIVIAL:-}" = 1 ] && [ "$TIER" = 1 ]; then
    TIER=2
    echo "$(STAMP) [$PROJECT] #$NUM @${SHA:0:7} trivial route: reviewer said TIER 1, capped at TIER 2 (model=$RP_MODEL)" >> "$LOG"
  fi
  # RP_ADVISORY: a routed APPROVE. It posts as a COMMENT review (never a GitHub
  # approval a merge queue could consume), carries no head marker (so the
  # GitHub dedup rung cannot rehydrate it as this lane's verdict), dismisses
  # nothing, never reaches merge_step, and writes neither ledger verdict. The
  # state row records it with trivial=1, which merge_retry refuses and the
  # already-reviewed gate escalates to a full-model review on the next tick.
  RP_ADVISORY=0
  [ "${RP_TRIVIAL:-}" = 1 ] && [ "$VERDICT" = APPROVE ] && RP_ADVISORY=1
  if [ -z "$VERDICT" ]; then
    # Keep the evidence: an unparseable review is a bug, not a shrug.
    mkdir -p "$HARNESS/builds/ext-$PROJECT-noverdict"
    printf '%s\n' "$REVIEW" > "$HARNESS/builds/ext-$PROJECT-noverdict/pr$NUM-$(date -u +%H%M%S).txt"
    # Retry cap (project-1 #523, 2026-08-15: five 1-byte reviews in one evening,
    # a session burned every half hour on the same sha). Two no-verdict attempts
    # on one head = stop until the head moves; one ALERTS line, once.
    NV=$(jq -r --arg n "$NUM" '.[$n].noverdict // 0' "$STATE")
    NVSHA=$(jq -r --arg n "$NUM" '.[$n].noverdict_sha // ""' "$STATE")
    [ "$NVSHA" = "$SHA" ] || NV=0
    NV=$((NV+1))
    rp_state_write --arg n "$NUM" --arg s "$SHA" --argjson c "$NV" '.[$n] = ((.[$n] // {}) + {noverdict:$c, noverdict_sha:$s})'
    if [ "$NV" -ge 2 ]; then
      # Through rp_freeze since BH-1017: this used to be `+ {sha:$s}`, which
      # kept a PREVIOUS head's APPROVE on the new sha and let merge_retry land
      # a head two reviewers had failed to read.
      rp_freeze "$NUM" "$SHA"
      [ "$NV" -eq 2 ] && HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[$PROJECT] #$NUM @$SHA produced NO VERDICT twice — review retries stopped until the head moves; likely the diff overwhelms the reviewer ($(stat -c%s "$DIFF_FILE" 2>/dev/null || echo '?')B). The merge conductor parks it no-verdict and bin/blocked-resolver.sh buys one more re-review, then rebuilds the ticket fresh (a smaller diff is exactly what a fresh build produces)."
    fi
    REVIEW_RC=1
    [ -n "${JOB_ID:-}" ] && command -v job_event >/dev/null 2>&1 \
      && job_event "$JOB_ID" review NO_VERDICT "#$NUM @${SHA:0:7} attempt $NV" >/dev/null 2>&1 || true
    echo "$(STAMP) [$PROJECT] #$NUM @$SHA review produced no verdict — skipping (attempt $NV)" >> "$LOG"
    continue
  fi

  # BH-7123: the footer says which review mode judged this head, every time,
  # so a reader can tell a review under the levels from one under strict
  # without opening the box's log (the marker line above TIER: appears only
  # when something was demoted).
  RL_FOOT=""
  command -v rl_mode >/dev/null 2>&1 && RL_FOOT=" Review level (BH-7123): mode $(rl_mode "$PROJECT" 2>/dev/null || echo unknown)${RL_OUT:+, $RL_OUT}."
  POSTED="$REVIEW

---
_$RP_MARKER $SHA. Static review — no build run. Push fixes and the next pass re-reviews; approved PRs merge automatically.${RL_FOOT}_"
  # WHICH GITHUB STATE THE VERDICT CARRIES (BH-872). An APPROVE approves, as it
  # always has. A REQUEST_CHANGES on an EXTERNAL author's PR still blocks — that
  # is a real refusal and it should hold. On a HARNESS-authored PR it posts as a
  # COMMENT review instead: Mergify reads CHANGES_REQUESTED as
  # `github-review-approved = false` and ejects the PR from the merge queue, and
  # until this ticket nothing in the fleet consumed the verdict, so the PR just
  # stopped. The findings are identical; only the blocking state goes, and the
  # consumer that acts on them is bin/blocked-resolver.sh's fix round.
  RP_STATE_FLAG="--request-changes"
  if [ "${RP_ADVISORY:-0}" = 1 ]; then
    RP_STATE_FLAG="--comment"
    POSTED="$REVIEW

---
_Advisory read of ${SHA:0:12} by the trivial-diff route (${RP_MODEL}). It approves nothing and merges nothing: a full review of this head follows, and that one decides._"
  elif [ "$VERDICT" = "APPROVE" ]; then
    RP_STATE_FLAG="--approve"
  elif harness_pr_author_match "$AUTHOR"; then
    RP_STATE_FLAG="--comment"
    POSTED="$POSTED
_Posted as a comment review: the harness fix round consumes this verdict; it does not block the queue._"
  fi
  # WHICH IDENTITY POSTS IT (#891 round 1, Important 4; BH-2119). The App token
  # is the right identity for a bot verdict, APPROVE included: a verdict posted
  # as `operator` reads as the operator's own, and it can never supersede the App's own
  # earlier CHANGES_REQUESTED, because GitHub keeps one standing review per
  # reviewer. The one exception is an APPROVE on a PR the reviewing App itself
  # opened, which GitHub refuses with 422 ("Can not approve your own pull
  # request"); that one, and only that one, goes out on the lane's DEFAULT
  # credential (rp_author_is_reviewer_app, which also answers yes when the App's
  # login cannot be read). Since BH-1668 pool PRs are opened by a different App
  # (`cromford-builders[bot]`), so the reviewing App approves those.
  #
  # AND THE REASON IS KEPT. gh's error body is the only thing that says WHY a
  # verdict did not land; discarding it is how a 422 became a blank line.
  RP_POST_APP=1
  [ "$RP_STATE_FLAG" = "--approve" ] && rp_author_is_reviewer_app "$AUTHOR" && RP_POST_APP=0
  RP_POSTED_REVIEW=0
  RP_POST_ERR=$(mktemp)
  [ "$RP_POST_APP" = 1 ] && { gh_auth_for "$SLUG" || true; rp_pat_post_note; }
  if gh pr review "$NUM" -R "$SLUG" "$RP_STATE_FLAG" --body "$POSTED" >/dev/null 2>"$RP_POST_ERR"; then
    RP_POSTED_REVIEW=1
  else
    echo "$(STAMP) [$PROJECT] #$NUM @${SHA:0:7} verdict=$VERDICT: \`gh pr review $RP_STATE_FLAG\` was refused — $(tr '\n' ' ' < "$RP_POST_ERR" | cut -c1-400)" >> "$LOG"
    gh pr comment "$NUM" -R "$SLUG" --body "$POSTED" >/dev/null 2>&1 \
      || echo "$(STAMP) [$PROJECT] #$NUM @${SHA:0:7} verdict=$VERDICT could not be posted (review and comment fallback both failed) — the findings are on no PR; the record below still marks this head reviewed, so a later tick will not repost" >> "$LOG"
  fi
  rm -f "$RP_POST_ERR"
  [ "$RP_POST_APP" = 1 ] && gh_auth_reset

  # AN APPROVE THAT LANDED SUPERSEDES THIS LANE'S OWN OLDER BLOCKING REVIEWS
  # (BH-2119) — ON A PR THE PER-TICK PASS DOES NOT COVER. The per-tick pass
  # above (BH-872) runs on every harness-authored PR, and since BH-1668 (#1926)
  # the default author set carries the builders App too, so a pool PR's stale
  # lane review is already dismissed there, once, before the review. A second
  # dismissal of the same row from here would be a duplicate write, so this pass
  # SKIPS every PR harness_pr_author_match accepts. What is left is a PR by any
  # other author (an external contributor's, or a box whose author set predates
  # the builders App): after an APPROVE of head H has LANDED (a refused post that
  # fell back to a comment approved nothing, and dismisses nothing), the reviews
  # are read once more and rp_dismiss_own drops the lane's own footer rows on
  # older heads, keeping any at H. The rows touched are only this lane's own. It
  # writes no `ledger_sha`; that watermark stays the per-tick pass's. An
  # unreadable list dismisses nothing (D11), and a low GitHub budget skips the
  # read, the same guard as the per-tick pass.
  if [ "$VERDICT" = APPROVE ] && [ "${RP_ADVISORY:-0}" = 0 ] && [ "$RP_POSTED_REVIEW" = 1 ] && ! harness_pr_author_match "$AUTHOR"; then
    if command -v gh_budget_low >/dev/null 2>&1 && gh_budget_low review-prs >/dev/null 2>&1; then
      echo "$(STAMP) [$PROJECT] #$NUM @${SHA:0:7}: the post-APPROVE supersede read is skipped — the GitHub API budget is low; an older blocking review of this lane's may still stand" >> "$LOG"
    elif RP_SUP=$(rp_reviews_tsv "$NUM"); then
      RP_SUP_ID=$(awk -F'\t' -v s="$SHA" '$2 == "APPROVED" && $3 == s && $5 == "yes" { id = $1 } END { print id }' <<<"$RP_SUP")
      rp_dismiss_own "$NUM" "$RP_SUP" "$SHA" \
        "Superseded by this lane's APPROVE${RP_SUP_ID:+ (review $RP_SUP_ID)} of ${SHA:0:7} (BH-2119): the earlier findings stay in this review's body." || true
    else
      echo "$(STAMP) [$PROJECT] #$NUM @${SHA:0:7}: could not read the reviews after the APPROVE — nothing superseded this tick; an older blocking review of this lane's may still stand" >> "$LOG"
    fi
  fi

  # >>> review-prs fresh merge (BH-4580; tests/mc/external-pr-enqueue.bh-4572-test.sh X12 drives this block)
  MERGED=no
  # BH-1026.2: reset beside MERGED, for the same reason — both are merge_step's
  # answer about THIS PR, and a value carried over from the previous iteration
  # would enqueue the wrong one.
  RP_MQ_WANT=0
  if [ "${RP_ADVISORY:-0}" = 1 ]; then
    echo "$(STAMP) [$PROJECT] #$NUM @${SHA:0:7} APPROVE left unmerged: an advisory read by the trivial route ($RP_MODEL) — the next tick re-reviews this head on the full model" >> "$LOG"
  # BH-4580: the tier decides who merges only when tier_gate_mode says so.
  elif [ "$VERDICT" = "APPROVE" ] && command -v tg_holds >/dev/null 2>&1 && tg_holds "$PROJECT" "${TIER:-?}"; then
    echo "$(STAMP) [$PROJECT] #$NUM @${SHA:0:7} APPROVE left unmerged: tier_gate_mode (${TG_MODE:-unreadable}, ${TG_MODE_SRC:-unread}) holds tier ${TIER:-?}" >> "$LOG"
  elif [ "$VERDICT" = "APPROVE" ]; then
    merge_step "$NUM" "$SHA" "$SERVED" "$AUTHOR"
  fi
  # <<< review-prs fresh merge

  # THE VERDICT IS MERGED, NOT ASSIGNED (BH-1289). A wholesale `.[$n] = {…}`
  # dropped the `ledger_sha` the dismissal pass wrote at this head earlier in
  # the SAME tick, so every reviewed hand PR bought one more dismissal-list
  # read on its next tick and only the tick after skipped. The four keys
  # carried through are the row's cross-tick caches, keyed on the head and
  # inert under a verdict: `ledger_sha` (BH-989) and the CI-debounce
  # bookkeeping G7d of tests/review-prs-gh-dedup-test.sh already keeps across
  # the rehydrate merge. Everything else on the row was bookkeeping for the
  # attempt that just ended (in-flight marker, no-verdict counter, merge-retry
  # counters, a frozen head's flag) and is dropped exactly as before — G11
  # pins that the in-flight marker does not outlive the verdict. The object
  # literal stays the FIRST operand: the four keys can never collide with it,
  # and tests/review-prs-state.bh-977-test.sh's fault injector matches the
  # write by that literal.
  # `trivial` (BH-2545) rides in the SAME write as the verdict: a second write
  # that failed would leave a bare APPROVE on record, and merge_retry merges one.
  rp_state_write --arg n "$NUM" --arg s "$SHA" --arg v "$VERDICT" --arg t "${TIER:-?}" --arg sv "$SERVED" \
     --arg tv "${RP_ADVISORY:-0}" \
     '.[$n] = {sha:$s, verdict:$v, tier:$t, served:$sv}
             + ((.[$n] // {}) | {ledger_sha, deferred_sha, deferred_at, ci_alerted_sha, rereq_sha}
                | with_entries(select(.value != null)))
             + (if $tv == "1" then {trivial:"1"} else {} end)'

# >>> review-prs d1 artifacts (BH-1064; tests/review-prs-d1-row.bh-1064-test.sh drives this block)
  # THE LANE'S OWN VERDICT, ON ITS OWN ROW. `/api/verdict?pr=` resolves a PR
  # through its `pr_url` artifact, and this lane never wrote one — so the D1
  # rung of its own dedup could only ever answer for harness BUILD PRs, which
  # are exactly the PRs it skips. Same shape bin/run-build.sh writes, so
  # job_verdict and job_verdict_headbound read it unchanged.
  #
  # VERDICT FIRST, pr_url SECOND, and that order is the whole failure mode: the
  # row becomes FINDABLE the moment pr_url lands. Writing pr_url first opens a
  # window where a reader resolves the row and finds no verdict (or, on a
  # re-review, the previous one). With the verdict already in place a partial
  # write is simply unfindable, which every caller already handles as "the
  # ledger has nothing to say about this one".
  # THE DETAIL CARRIES THE FIELDS THE FLEET READS, not just the ones this lane
  # happens to have. `/api/verdict` returns the verdict detail's `record`
  # verbatim (`worker/jobs/src/index.js`, `record: d.record !== undefined ?
  # d.record : null`) and `job_verdict_headbound` reads `.headbound` out of the
  # same blob; an omitted field reads as NOT MEASURED downstream, so an operator
  # resolving an external PR would get `null` where a harness build PR names its
  # build record. There is no build directory here — the review IS the work — so
  # the pointer is the lane, the project and the PR. `headbound:"n/a"` is the
  # same word bin/run-build.sh writes when no head-bound gate ran, and
  # `mc_hb_blocks` only ever acts on `blocked@<sha>`, so it parks nothing.
  RP_RECORD="review-prs:$PROJECT:$NUM"
  if [ "${RP_ADVISORY:-0}" = 0 ] && [ -n "${JOB_ID:-}" ] && command -v job_artifact_put >/dev/null 2>&1; then
    job_artifact_put verdict "$VERDICT" \
      "$(jq -nc --arg t "${TIER:-?}" --arg p "$SERVED" --arg s "$SHA" --arg r "$RP_RECORD" \
          '{tier:$t,provenance:$p,record:$r,headbound:"n/a",reviewed_sha:$s,settled:true}' 2>/dev/null)" \
      >/dev/null 2>&1 || true
    job_artifact_put pr_url "https://github.com/$SLUG/pull/$NUM" \
      "$(jq -nc --arg n "$NUM" --arg s "$SHA" --arg r "$RP_RECORD" \
          '{number:$n,reviewed_sha:$s,record:$r,lane:"review-prs"}' 2>/dev/null)" >/dev/null 2>&1 || true
  fi
  # BH-1026.2: THE QUEUE ROW, BESIDE THE VERDICT THAT EARNED IT. The file at
  # merge_step's queue arm is still written there; this is the row that says WHY
  # — a `<pr>` filename cannot. Gated on RP_MQ_WANT, which only that arm sets,
  # and on the verdict word this block already has in a variable. Idempotent per
  # tick through RP_MQ_ENQUEUED, and per box through the table's (project, pr)
  # key. A refused row is not silent: the sweep that used to re-offer these is
  # retired, so the PR is named in ALERTS.
  if [ "$VERDICT" = APPROVE ] && [ "${RP_MQ_WANT:-0}" = 1 ] \
     && command -v merge_queue_put >/dev/null 2>&1; then
    if [ "${RP_MQ_ENQUEUED:-}" = "$NUM" ]; then
      :
    elif merge_queue_put "$PROJECT" "$NUM" "$SLUG" "APPROVE from review-prs @${SHA:0:7}" >/dev/null 2>&1; then
      RP_MQ_ENQUEUED="$NUM"
      echo "$(STAMP) [$PROJECT] #$NUM APPROVE enqueued on the merge queue" >> "$LOG"
    else
      HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[merge-queue] $PROJECT #$NUM: the merge_queue row was refused at the APPROVE verdict (worker unreachable) — the box-queue file is the only record: https://github.com/$SLUG/pull/$NUM"
    fi
  fi
# <<< review-prs d1 artifacts

  # >>> review verdict ledger (BH-1024; tests/verdict-single-home.bh-1024-test.sh drives this block)
  # THE SAME JUDGEMENT, IN THE LEDGER. Until this block, an external PR this
  # lane reviewed had its verdict in ONE place: the JSON file above, on this
  # box. job_verdict could not see it, so the merge conductor, the sweep and
  # bin/review-autopilot.sh all behaved as if nobody had read the diff — and the
  # autopilot's own dedupe had to reach into this project's state file to find
  # out otherwise. Written from the SAME parsed values, at the same point, right
  # after the file: the file is the write-through cache, and neither write is
  # gated on the other.
  #
  # A ROW PER (PR, sha) REVIEW EVENT, not on this lane's JOB_ID. /api/verdict?pr=
  # resolves through a `pr_url` artifact and artifacts key on (job_id, kind),
  # while this lane reviews many PRs under one row — so each reviewed head opens
  # its own short-lived `review-verdict` job, writes pr_url + verdict, and closes
  # itself. JOB_ID is never touched: that row carries the spend (see phase 4
  # above) and a second meaning on it is how one figure becomes two.
  #
  # It sits BELOW the no-verdict `continue`, so a review that produced nothing
  # can never be stamped as judged, and $SHA is never empty here (the loop
  # `continue`s on an empty one). Every failure is one log line and the tick
  # carries on — the jobs-client fail-open contract, not an exception to it.
  if [ "${RP_ADVISORY:-0}" = 0 ] && type verdict_single_home_on >/dev/null 2>&1 && verdict_single_home_on \
     && command -v job_open >/dev/null 2>&1; then
    RV_WORD=BLOCK; [ "$VERDICT" = APPROVE ] && RV_WORD=APPROVE
    RV_PROV="$SERVED"; rp_prov_is_claude "$SERVED" && RV_PROV=claude
    RV_URL="https://github.com/$SLUG/pull/$NUM"
    RJ=$(job_open "$PROJECT" "$SLUG#$NUM" review-verdict review "" \
          "$(jq -nc --arg l "review-prs verdict" --arg u "$RV_URL" '{label:$l,pr:$u}')"); RJ_RC=$?
    if [ "$RJ_RC" = 0 ] && [ -n "$RJ" ]; then
      job_heartbeat "$RJ" start >/dev/null 2>&1 || true
      if job_artifact_put pr_url "$RV_URL" "" "$RJ" >/dev/null 2>&1 \
         && job_artifact_put verdict "$RV_WORD" "$(jq -nc --arg t "${TIER:-?}" --arg p "$RV_PROV" \
              --arg sv "$SERVED" --arg s "$SHA" --arg u "$RV_URL" \
              '{tier:$t,provenance:$p,served_by:$sv,reviewed_sha:$s,settled:true,source:"review-prs",pr:$u}')" "$RJ" >/dev/null 2>&1; then
        echo "$(STAMP) [$PROJECT] #$NUM @${SHA:0:7} verdict $RV_WORD recorded in the ledger (job $RJ, tier ${TIER:-?}, served $SERVED)" >> "$LOG"
      else
        echo "$(STAMP) [$PROJECT] #$NUM @${SHA:0:7} ledger verdict NOT written (artifact put failed, job $RJ) — the state file is the only copy this tick" >> "$LOG"
      fi
      # A FAILED CLOSE IS NAMED, not swallowed. The row is opened on the lane
      # key (project, `<slug>#<num>`, review-verdict) — per PR, not per head —
      # so one left `running` is what the NEXT review of this PR resolves
      # against: THIS box gets the same row back (the worker's double-build
      # guard returns `200 {resumed:true}` to the same box, which is why a
      # relaunched pipeline is idempotent), and it then writes the new head's
      # verdict onto the OLD job; any OTHER box is refused with a 409 whose only
      # trace would be the generic line above. Still best-effort (the tick
      # carries on either way); it just says so.
      job_update "$RJ" status=done stage=done >/dev/null 2>&1 \
        || echo "$(STAMP) [$PROJECT] #$NUM @${SHA:0:7} review-verdict job $RJ NOT closed (job_update failed) — the next review of this PR reuses this row from this box, and is refused from any other until it goes stale" >> "$LOG"
    else
      # THE REASON COMES OFF THIS CALL'S OWN STDOUT ("REFUSED <scope> :: <why>"
      # / "IN_FLIGHT <box> <job>"), never out of $JOB_REFUSED: job_open ran in a
      # command substitution, so the variable it set died with that subshell and
      # what survived would be the PREVIOUS PR's refusal quoted as this one's.
      RJ_WHY=failed; [ "$RJ_RC" = 9 ] && RJ_WHY="${RJ:-refused}"
      echo "$(STAMP) [$PROJECT] #$NUM @${SHA:0:7} ledger verdict NOT written (job_open $RJ_WHY) — the state file is the only copy this tick" >> "$LOG"
    fi
  fi
  # BH-1026.2: the same hand-off as `# >>> review-prs d1 artifacts`, spelled
  # again rather than shared, because each of these blocks is extracted by its
  # markers and run on its own. RP_MQ_ENQUEUED is what makes the pair produce
  # ONE row per reviewed head. It sits OUTSIDE the verdict_single_home_on gate:
  # the queue row is not the ledger row, and a fleet with that flag off still
  # has to land its approved PRs.
  if [ "$VERDICT" = APPROVE ] && [ "${RP_MQ_WANT:-0}" = 1 ] \
     && command -v merge_queue_put >/dev/null 2>&1; then
    if [ "${RP_MQ_ENQUEUED:-}" = "$NUM" ]; then
      :
    elif merge_queue_put "$PROJECT" "$NUM" "$SLUG" "APPROVE from review-prs @${SHA:0:7}" >/dev/null 2>&1; then
      RP_MQ_ENQUEUED="$NUM"
      echo "$(STAMP) [$PROJECT] #$NUM APPROVE enqueued on the merge queue" >> "$LOG"
    else
      HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[merge-queue] $PROJECT #$NUM: the merge_queue row was refused at the APPROVE verdict (worker unreachable) — the box-queue file is the only record: https://github.com/$SLUG/pull/$NUM"
    fi
  fi
  # <<< review verdict ledger
  [ -n "${JOB_ID:-}" ] && command -v job_event >/dev/null 2>&1 \
    && job_event "$JOB_ID" review "$VERDICT" "#$NUM tier=${TIER:-?} merged=$MERGED" >/dev/null 2>&1 || true
  echo "$(STAMP) [$PROJECT] #$NUM by $AUTHOR @${SHA:0:7} verdict=$VERDICT tier=${TIER:-?} merged=$MERGED" >> "$LOG"

  # >>> review-prs beat line (BH-4580; tests/mc/external-pr-enqueue.bh-4572-test.sh X12 drives this block)
  LINE="PR #$NUM ($AUTHOR) reviewed: $VERDICT tier ${TIER:-?}$([ $MERGED = yes ] && echo ', auto-merged' || { [ "$MERGED" = queued ] && echo ', queued in the merge queue' || { [ "$VERDICT" = APPROVE ] && { mc_queue_conductor_only "$SLUG" && echo ', handed to the merge queue' || echo ', left for the merge step'; }; }; }) — https://github.com/$SLUG/pull/$NUM"
  # <<< review-prs beat line
  "$HARNESS/bin/beat.sh" "$(jq -nc --arg p "$PROJECT" --arg akey "prreview:$PROJECT:$NUM:$SHA" --arg l "$LINE" \
    '{kind:"pr_review",project:$p,akey:$akey,line:$l}')" >/dev/null 2>&1
done; }
# <<< review-prs one pr

# >>> review-prs pool (BH-5284)
# Up to REVIEW_CONCURRENCY PRs at once (registry knob, settings row
# lane.review-prs.<project>.review_concurrency; default 10), capped per box
# (REVIEW_BOX_MAX, else free memory and /tmp). Each PR is a worker; the tick
# waits for its gate (just before the paid call) before the next PR starts, so
# the reads, the debounce and the dedup still run one PR at a time in list
# order. A worker owns its review row (review_claim's JOB_ID) and closes it on
# exit. No new worker starts while /tmp is under REVIEW_TMP_MIN_MB, nor during
# a rate-limit pause (REVIEW_RATE_BACKOFF_S, doubling to 900s). The tick
# waits for every worker before it exits, so the flock above covers them all.
RP_POOL=0; RP_SCRATCH=""; RP_SCRATCH_ROOT=""
[ -r "$HARNESS/bin/lib/review-pool.sh" ] && . "$HARNESS/bin/lib/review-pool.sh" && RP_POOL=1
# The /tmp scratch and the /tmp cap report (BH-6130). Missing, no scratch is
# made or reaped and nothing is reported; the pool runs as before.
# shellcheck disable=SC1091
. "$HARNESS/bin/lib/review-prs-tmp.sh" 2>/dev/null || true
# >>> review-prs stale head watch (BH-5396; tests/review-prs-stale-cr.bh-5396-test.sh S4/S6)
# rp_stale_head_watch <num> <sha> — after the PR's pass: a row whose verdict is
# REQUEST_CHANGES on an OLDER head means this head still has no verdict from
# this lane, whatever the pass did (a call-guard refusal, no model route, any
# skip). The first sight of the head starts a clock in the row
# (stale_head_sha/_since); REVIEW_CI_STALE_SECS later ONE alert line names the
# head and quotes the last log line about it, the alert first and the
# stale_head_alerted_sha stamp second. A head THIS pass deferred on CI
# (RP_CI_DEFERRED) is left to the CI path's own alert, which only fires while
# CI is not green. The row's deferred_sha is not the test: nothing clears it
# when CI turns green, so a head first seen with CI pending and then skipped
# (call-guard rc 74, no model route) would never start a clock. A verdict at
# the head ends the watch (the row's sha is that head), and a newer head
# restarts the clock.
rp_stale_head_watch() {
  local num="$1" sha="$2" row v rsha hsha since asha now last
  [ -n "$num" ] && [ -n "$sha" ] && [ "${RP_CI_DEFERRED:-0}" != 1 ] || return 0
  row=$(jq -r --arg n "$num" '.[$n] // {} | [(.verdict // ""), (.sha // ""),
      (.stale_head_sha // ""), (.stale_head_since // 0 | tostring), (.stale_head_alerted_sha // "")] | join("|")' "$STATE" 2>/dev/null) || return 0
  # `|`, not a space: IFS whitespace would collapse an empty field into the next.
  IFS='|' read -r v rsha hsha since asha <<<"$row"
  [ "$v" = REQUEST_CHANGES ] && [ -n "$rsha" ] && [ "$rsha" != "$sha" ] || return 0
  now=$(date -u +%s)
  case "$since" in ''|*[!0-9]*) since=0 ;; esac
  if [ "$hsha" != "$sha" ] || [ "$since" -le 0 ]; then
    rp_state_write --arg n "$num" --arg s "$sha" --argjson at "$now" \
      '.[$n] = ((.[$n] // {}) + {stale_head_sha:$s, stale_head_since:$at} | del(.stale_head_alerted_sha))' || true
    return 0
  fi
  [ $((now - since)) -ge "${REVIEW_CI_STALE_SECS:-43200}" ] && [ "$asha" != "$sha" ] || return 0
  last=$(grep -F -e "#$num @${sha:0:7}" -e "#$num@${sha:0:12}" "$LOG" 2>/dev/null | tail -1 | cut -c1-300)
  HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[$PROJECT] #$num @${sha:0:7} has had no verdict from review-prs for $(( (now - since) / 3600 ))h while this lane's REQUEST_CHANGES on ${rsha:0:7} stands — https://github.com/$SLUG/pull/$num needs a look; last log line: ${last:-no log line for this head}" \
    || return 0
  rp_state_write --arg n "$num" --arg s "$sha" '.[$n] = ((.[$n] // {}) + {stale_head_alerted_sha:$s})' || true
}
# <<< review-prs stale head watch
rp_worker() {
  RPOOL_ON_EXIT=rp_worker_exit; JOB_ID=""; REVIEW_RC=0; RP_RATE_LIMITED=0; RP_AC_RC=""
  RP_SCRATCH=""
  [ -n "$RP_SCRATCH_ROOT" ] && RP_SCRATCH="$RP_SCRATCH_ROOT/$RPOOL_ID" && { mkdir -p "$RP_SCRATCH" 2>/dev/null || RP_SCRATCH=""; }
  rp_one_pr
  rp_stale_head_watch "$NUM" "$SHA"
  if [ "$RP_RATE_LIMITED" = 1 ]; then RPOOL_RESULT=ratelimited
  elif [ "$RP_AC_RC" = 0 ]; then RPOOL_RESULT=reviewed
  else RPOOL_RESULT=done; fi
}
rpool_on_result() {
  [ -n "$RP_SCRATCH_ROOT" ] && rm -rf -- "${RP_SCRATCH_ROOT:?}/$1" 2>/dev/null
  case "$2" in ratelimited) rpool_rate_hit ;; reviewed) rpool_rate_ok ;; esac; return 0; }
rp_worker_exit() {
  command -v job_lane_close >/dev/null 2>&1 && [ -n "${JOB_ID:-}" ] && job_lane_close "$REVIEW_RC" "review-prs $PROJECT"
  if [ -n "${RP_SCRATCH:-}" ]; then
    rm -rf -- "${RP_SCRATCH:?}" 2>/dev/null
    [ -e "$REPO_DIR/.git" ] && git -C "$REPO_DIR" worktree prune 2>/dev/null
  fi
  return 0
}
if [ "$RP_POOL" = 1 ]; then
  # 0 = no cap: every PR starts, bounded by the box guardrails (rpool_init).
  case "${REVIEW_CONCURRENCY:-}" in 0) RP_K=0 ;; ''|*[!0-9]*|0*) RP_K=10 ;; *) RP_K="$REVIEW_CONCURRENCY" ;; esac
  rp_pool_log() { echo "$(STAMP) [$PROJECT] review-prs: $*" >> "$LOG"; }
  RP_POOL_DIR="$HARNESS/tmp/review-prs-pool-$PROJECT-$$"
  if command -v rp_scratch_reap >/dev/null 2>&1; then
    RP_SCRATCH_ROOT="$(rp_tmp_base)/review-prs-wk-$$"
    rp_scratch_reap
  fi
  rpool_init review-prs REVIEW "$RP_K" "$RP_POOL_DIR" rp_pool_log
  # Once per cap episode, and again each REVIEW_TMP_CAPPED_REPORT_S while the
  # episode lasts, with the measured numbers (BH-6130). A tick that is not
  # capped by /tmp ends the episode when /tmp is back over the threshold (BH-6133).
  if [ "${RPOOL_CAP_BY-}" = tmp ] && [ "$RPOOL_K" -lt 3 ]; then
    if command -v rp_tmp_capped_report >/dev/null 2>&1 && rp_tmp_capped_report && command -v sentry_report >/dev/null 2>&1; then
      sentry_report warning review-prs review-prs-tmp-capped "$RP_TMP_MSG" "$RP_TMP_EXTRA"
    fi
  elif command -v rp_tmp_episode_end >/dev/null 2>&1; then
    rp_tmp_episode_end
  fi
  trap 'command -v job_lane_close >/dev/null 2>&1 && job_lane_close "$REVIEW_RC" "review-prs $PROJECT"; rpool_finish; [ -n "$RP_SCRATCH_ROOT" ] && rm -rf -- "${RP_SCRATCH_ROOT:?}" 2>/dev/null' EXIT
fi
RP_RUNNING_AT_CLOSE=0
while IFS=$'\t' read -r NUM SHA AUTHOR TITLE; do
  [ -n "$NUM" ] || continue
  if [ "$RP_POOL" = 1 ]; then
    while [ "$(rpool_running)" -ge "$RPOOL_K" ]; do rpool_wait_one || break; done
    rpool_reap
    rpool_tmp_ok || break
    if rpool_paused; then
      echo "$(STAMP) [$PROJECT] review-prs: new starts paused ${RPOOL_PAUSE_LEFT}s more after a rate limit; #$NUM and the PRs after it wait for a later tick" >> "$LOG"
      break
    fi
    rpool_start "pr$NUM" rp_worker
    rpool_gate_wait "pr$NUM"
  else
    rp_one_pr
    rp_stale_head_watch "$NUM" "$SHA"
  fi
done <<<"$PRS"
if [ "$RP_POOL" = 1 ]; then
  RP_RUNNING_AT_CLOSE=$(rpool_running)
  rpool_wait_all
  echo "$(STAMP) [$PROJECT] review-prs tick concurrency=$RPOOL_K running=$RP_RUNNING_AT_CLOSE started=$RPOOL_STARTED" >> "$LOG"
fi
# <<< review-prs pool
exit 0
