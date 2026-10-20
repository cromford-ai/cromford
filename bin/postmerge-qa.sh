#!/bin/bash
# bin/postmerge-qa.sh <project> [build-dir] [--dry-run] — POST-MERGE PRODUCTION QA (SDLC 3b).
# --dry-run: print the account, prod URL and routes the drive would use, then exit (BH-3438).
#
# THE HOLE THIS FILLS. The pipeline QAs a PREVIEW deployment before the merge
# (run-build.sh's qa stage) and then verifies, after the merge, that production
# answers HTTP 200 (deploy-verify.sh). Nothing has ever driven the SHIPPED
# screen on the production domain as a signed-in user. So the last thing anyone
# actually observed about a feature was a preview build of a branch, and "it
# works in prod" was an inference from a status code on `/`.
#
# WHAT IT DOES, in order, and it stops at the first step that is not satisfied:
#   1. DEPLOY GATE FIRST. Production must be serving the MERGE SHA — via the
#      project's VERSION_URL when it has one, else a successful GitHub
#      production deployment for that sha. A VERSION_URL reports the one sha
#      prod serves NOW, so serving means that sha OR ANY DESCENDANT of it, the
#      same ancestry rule bin/deploy-train.sh uses; a merge the next merge
#      supersedes is a merge that IS live. Not yet deployed is NOT a failure: it
#      is "come back next tick". Nothing is driven against the old build, which
#      is the one way this stage could manufacture a false FAIL. But "next tick"
#      ends: POSTMERGE_QA_DEPLOY_MAX_HOURS after the merge (default 12, 0 = off)
#      a build the gate can READ and says is not served is written
#      NOT_COVERED_DEPLOY_TIMEOUT and alerted once, because a merge the gate
#      never saw served is a fact somebody needs told, not a line to re-log
#      forever (BH-1022: 30,698 requeues in 3 days). A gate that could not be
#      read at all never ages anything out — that is a fact about the box. The
#      outcome says only what was observed — not covered — and is never a FAIL.
#   2. DRIVE, deterministically. bin/qa-drive.mjs signs in as the project's QA
#      user and loads each shipped screen at 1280px AND 375px, screenshotting,
#      collecting console errors and failed requests, checking for horizontal
#      body scroll and native dialogs. A landing on /sign-in is a HARD FAIL.
#   3. DRIVE, judgementally — only when step 2 FAILED (BH-2547). A green drive
#      is the verdict; the prodqa agent is paid only to characterise a failure,
#      and can never turn a drive FAIL into a PASS. "Failed" is a non-zero rc
#      or a `FLOW … fail` row, the drive's own signals the verdict reads too.
#      BLOCKED and requeue never reach it — nothing was observed, so there is
#      nothing to characterise.
#   4. ATTACH. qa-prod.md in the build dir, a row per finding in
#      logs/findings.log (lens=prodqa, so the rule miner counts a recurring prod
#      defect like it counts a recurring review comment), and a comment on the
#      merged PR — the ticket's close-out record.
#
# FAIL-OPEN, AND LOUD. This runs AFTER the merge, so it can never block one.
# Every unreachable dependency (no QA env, no playwright, no console, worker
# down) exits 0 having said what it could not do. A real FAIL is the opposite of
# quiet: ALERTS.log plus a fleet_alert beat, because a defect that only exists
# in production is the most expensive kind we ship.
#
# THE ACCOUNT IS ALWAYS ROUTED THROUGH bin/qa-unbanned.sh, even for accounts
# that are active at rest — where it is a no-op. Privileged QA accounts are
# BANNED at rest by design and Clerk mints them a sign-in ticket anyway, so an
# "unban only when we think we need it" rule is a rule that will be wrong once.
#
# Ledger: the harness-jobs coordination row (lane prodqa/<project>/claude) is
# what the RUN is attributed to. What stops a build being driven twice is
# state/postmerge-qa-done.txt and, behind the no-twin-ledgers flag (BH-1036),
# its row twin — kind `postmerge_qa`, key the build-dir basename, status the
# verdict. The file is written first and read first; the row is what answers
# after a hub wipe, when the file is the one thing that did not survive.
#
# Cron (conservative, one build per tick):
#   23,53 * * * * /root/harness/bin/postmerge-qa.sh <project>
set -uo pipefail
# BH-2303: every model call this lane makes names the lane, so its cost rows
# carry lane_id and its LLM_* knobs (on/off, runners, daily cap) bind it alone.
export AGENT_CALL_LANE=postmerge-qa
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")
SELF="$(cd "$(dirname "$0")" && pwd)"
P="${1:-}"; ONE_BUILD=""; DRY=0
[ "$#" -gt 0 ] && shift
for A in "$@"; do
  case "$A" in --dry-run) DRY=1 ;; *) ONE_BUILD="$A" ;; esac
done

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-postmerge-qa
# (or its project row) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off postmerge-qa <project>.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit postmerge-qa "$P"
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    postmerge-qa "$P"
[ -n "$P" ] || { echo "usage: postmerge-qa.sh <project> [build-dir] [--dry-run]" >&2; exit 2; }
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
LOG="$H/logs/postmerge-qa.log"
ALERTS="$H/logs/ALERTS.log"
DONE="$H/state/postmerge-qa-done.txt"
mkdir -p "$H/logs" "$H/state" "$H/locks" 2>/dev/null || true
say() { echo "$(STAMP) [$P] $*" >> "$LOG"; }

set -a; . "$HENV/global.env" 2>/dev/null; . "$HENV/$P.env" 2>/dev/null; set +a
# AND AGAIN, BELOW THE ENV LOAD (BH-1165 review). `set -a; . env/global.env`
# re-assigns every name it carries, so the call above lost each knob the box's
# env file also sets — the settings row was gone, the page went on reporting
# `source: settings`, and nothing errored: the exact shape this ticket exists to
# end. The call above still earns its place: the knobs this lane reads BEFORE
# this line have no other way to see a row. Applying twice is idempotent (the
# settings cache is already warm) and section 16 of tests/lanes-registry-test.sh
# is the ordering.
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    postmerge-qa "$P"
# shellcheck source=/dev/null
[ -r "$H/bin/jobs-client.sh" ] && . "$H/bin/jobs-client.sh"
# shellcheck source=bin/lib/ledger-twin.sh
[ -r "$H/bin/lib/ledger-twin.sh" ] && . "$H/bin/lib/ledger-twin.sh"
# A box mid-sync can carry this script without the library; every verb then
# answers "no row", which is today's behaviour exactly.
declare -F lt_on >/dev/null 2>&1 || { lt_on() { return 1; }; lt_get() { return 1; }; lt_read() { LT_VAL=""; return 1; }; lt_seen() { return 1; }; lt_put() { return 0; }; }
# shellcheck source=bin/lib/gh-app-auth.sh
[ -r "$H/bin/lib/gh-app-auth.sh" ] && . "$H/bin/lib/gh-app-auth.sh"
# The verification-map lookup the prodqa agent is handed (BH-2005.2). Absent on
# a box mid-sync: the agent branch says so in the prompt and drives as before.
# shellcheck source=bin/lib/vmap-entry.sh
[ -r "$SELF/lib/vmap-entry.sh" ] && . "$SELF/lib/vmap-entry.sh" 2>/dev/null || true

# --- which screens shipped ---------------------------------------------------
# The plan's own "## QA screens" section is the pipeline's existing statement of
# what this ticket touches — the same list the preview QA stage drives. Paths
# are taken literally; anything that is not an app path is ignored rather than
# guessed at. With no plan and no section we drive `/` and SAY that is all we
# drove, which is a thin pass, not a false one.
screens_for() { # screens_for <build-dir>
  local bd="$1" out
  out=$(sed -n '/^#\{1,6\}[[:space:]]*QA screens/I,/^#\{1,6\}[[:space:]]/p' "$bd/plan.md" 2>/dev/null \
        | grep -oE '(^|[[:space:]`("])/[A-Za-z0-9/_.-]*' \
        | tr -d '`("' | sed 's/^[[:space:]]*//' \
        | grep -vE '^/(root|tmp|usr|etc|var|home)(/|$)' \
        | sort -u | head -5)
  [ -n "$out" ] || out="/"
  echo "$out"
}

# >>> dry run (BH-3438) -------------------------------------------------------
# `--dry-run` answers "would this lane drive, and what?" before a box's first
# real run: the account, the prod URL and the routes, from exactly the reads the
# drive uses. It stops HERE — before the lock, the switches, the model route and
# any gh, curl, node or qa-unbanned.sh call — and writes nothing: no done row,
# no ALERTS line, no log line. The key's VALUE is never printed, only set/UNSET.
# rc 0 when prod, user and key all resolved; rc 1 names what is owed.
if [ "$DRY" = 1 ]; then
  D_SLUG=$("$SELF/fleet-conf.sh" "$P" repo 2>/dev/null) || D_SLUG=""
  D_PROD=$("$SELF/prod-url.sh" "$P" 2>/dev/null) || D_PROD=""
  D_UID="${POSTMERGE_QA_USER_ID:-${QA_TEST_USER_ID:-}}"
  D_KEY=UNSET; [ -n "${QA_CLERK_SECRET_KEY:-}" ] && D_KEY=set
  D_BUILD="$ONE_BUILD"
  if [ -z "$D_BUILD" ]; then
    # The newest build of this project that has a plan to read routes from.
    D_BUILD=$(ls -1dt "$H/builds/$P-"*/ 2>/dev/null | while read -r d; do
      [ -f "${d%/}/plan.md" ] && { echo "${d%/}"; break; }; done)
  fi
  if [ -n "$D_BUILD" ]; then D_ROUTES=$(screens_for "$D_BUILD"); D_BN=$(basename "$D_BUILD"); else D_ROUTES="/"; D_BN=none; fi
  echo "DRY RUN postmerge-qa $P: prod=${D_PROD:-UNSET} user=${D_UID:-UNSET} clerk_key=$D_KEY build=$D_BN routes=$(echo $D_ROUTES)"
  D_RC=0
  [ -n "$D_SLUG" ] && [ -n "$D_PROD" ] || { echo "owed: no fleet.conf repo/prod row for $P"; D_RC=1; }
  [ -n "$D_UID" ] && [ "$D_KEY" = set ] || { echo "owed: set QA_TEST_USER_ID and QA_CLERK_SECRET_KEY in env/$P.env"; D_RC=1; }
  exit "$D_RC"
fi
# <<< dry run

exec 8>"$H/locks/postmerge-qa-$P.lock"
flock -n 8 || exit 0

[ -z "${POSTMERGE_QA_DISABLED:-}" ] || { say "disabled by env — nothing driven"; exit 0; }
# Kill switch: settings row switch.postmerge-qa-disabled.<box> or
# switch.postmerge-qa-disabled (1 = off), read by lane_switch
# (bin/lib/lane-switch.sh); flags/postmerge-qa-disabled decides only when
# neither row exists.
# shellcheck source=lib/lane-switch.sh
. "$SELF/lib/lane-switch.sh" || exit 1
lane_switch postmerge-qa-disabled && { say "kill switch on — nothing driven"; exit 0; }

SLUG=$("$SELF/fleet-conf.sh" "$P" repo 2>/dev/null) || SLUG=""
PROD=$("$SELF/prod-url.sh" "$P" 2>/dev/null) || PROD=""
REPO_DIR="${QA_REPO_DIR:-/root/repos/$P}"
LOOKBACK_H="${POSTMERGE_QA_LOOKBACK_HOURS:-48}"
MAX="${POSTMERGE_QA_MAX:-1}"
# ONE clock read for the whole run, so every build in this tick is aged against
# the same instant. A knob that is not a whole number would make the comparison
# below error and read as "under the limit", i.e. no limit at all — say what
# happened and use the default, the same way E2E_MAX_PERSONAS is handled.
NOW=$(date +%s)
DEPLOY_MAX_H="${POSTMERGE_QA_DEPLOY_MAX_HOURS:-12}"
case "$DEPLOY_MAX_H" in
  ''|*[!0-9]*) say "POSTMERGE_QA_DEPLOY_MAX_HOURS='$DEPLOY_MAX_H' is not a whole number — using the default of 12"
               DEPLOY_MAX_H=12 ;;
esac
# The QA agent's model (BH-1510.1): POSTMERGE_QA_MODEL, then QA_MODEL, from env
# as before; otherwise this project's postmerge.qa model_routes row. No route
# anywhere = nothing driven this tick (rc 75); the resolver has already written
# the ALERTS line naming the role, and no model is guessed in its place.
QA_MODEL="${POSTMERGE_QA_MODEL:-${QA_MODEL:-}}"
if [ -z "$QA_MODEL" ]; then
  # shellcheck source=bin/lib/model-route.sh
  [ -r "$H/bin/lib/model-route.sh" ] && . "$H/bin/lib/model-route.sh"
  command -v model_for >/dev/null 2>&1 && QA_MODEL=$(model_for postmerge.qa "$P")
  [ -n "$QA_MODEL" ] || { say "no model route for postmerge.qa — nothing driven"; exit 75; }
fi
[ -n "$SLUG" ] && [ -n "$PROD" ] || { say "no fleet.conf repo/prod row — nothing to do"; exit 0; }
# #425: one repo for the whole run — arm it here, where the slug is known good.
command -v gh_auth_for >/dev/null 2>&1 && gh_auth_for "$SLUG" || true

# --- deploy gate -------------------------------------------------------------
# Two ways to know prod is serving a sha, in preference order. Both answer
# yes/no/unknown; only `yes` proceeds. "unknown" leaves the build queued.
FETCHED=0
# Is <live> — the sha production reports it is serving — this merge, or anything
# BUILT ON TOP of it? The local clone is the only thing that can answer, and a
# clone that has never seen one of the two shas answers "cannot tell" rather
# than "no": `git merge-base --is-ancestor` exits non-zero for an unknown object
# exactly as it does for a real no, and reading that as "no" is how a stale
# clone writes a deployed merge off as undeployed.
descends_from() { # descends_from <sha> <live> -> 0 yes | 1 no | 2 cannot tell
  local sha="$1" live="$2" try
  [ -d "$REPO_DIR/.git" ] || return 2
  for try in 1 2; do
    if (cd "$REPO_DIR" && git cat-file -e "$sha^{commit}" && git cat-file -e "$live^{commit}") 2>/dev/null; then
      (cd "$REPO_DIR" && git merge-base --is-ancestor "$sha" "$live") 2>/dev/null && return 0
      return 1
    fi
    # One fetch per RUN, not per build: the gate is asked for every candidate in
    # the lookback and a fetch each would be dozens of network round trips a tick.
    [ "$try" = 1 ] && [ "$FETCHED" = 0 ] && { FETCHED=1; (cd "$REPO_DIR" && git fetch -q origin) >/dev/null 2>&1 || true; }
  done
  return 2
}

serves_sha() { # serves_sha <sha> -> 0 serving | 1 not yet | 2 cannot tell
  local sha="$1" body live did state
  if [ -n "${VERSION_URL:-}" ]; then
    # VERSION_AUTH exactly as bin/deploy-train.sh sends it: without it a
    # protected endpoint answers a 401 body, which reads as "not serving" for
    # every merge on that project, forever.
    body=$(curl -s -m 20 -L ${VERSION_AUTH:+-H "$VERSION_AUTH"} "$VERSION_URL" 2>/dev/null) || return 2
    [ -n "$body" ] || return 2
    # The endpoint reports the ONE sha prod is serving now — the newest merge,
    # not necessarily this one. So serving = this sha OR ANY DESCENDANT of it,
    # the same rule bin/deploy-train.sh:135-141 already applies ("a PR merged
    # mid-window, Vercel skipped to the newer build"). A strict match answers
    # "not serving" forever for a merge that went live minutes after it landed,
    # which is what the audited feed was made of: every sampled project-5 sha
    # was an ancestor of the sha prod was serving (BH-1022 review, round 1).
    live=$(printf '%s' "$body" | jq -r '.sha // .commit // empty' 2>/dev/null)
    if [ -z "$live" ]; then           # not JSON: a bare sha, a plain-text banner
      case "$body" in *"${sha:0:7}"*) return 0 ;; esac
      return 1
    fi
    [ "${live:0:7}" = "${sha:0:7}" ] && return 0
    descends_from "$sha" "$live"
    return $?
  fi
  did=$(gh api "repos/$SLUG/deployments?sha=$sha&per_page=10" \
        -q '[.[] | select(.environment | test("production"; "i"))][0].id' 2>/dev/null) || return 2
  [ -n "$did" ] || return 1
  state=$(gh api "repos/$SLUG/deployments/$did/statuses?per_page=20" \
          -q '[.[] | select(.state == "success" or .state == "failure" or .state == "error")][0].state // empty' 2>/dev/null) || return 2
  [ "$state" = success ] && return 0
  return 1
}

already_done() { grep -qF "$1 " "$DONE" 2>/dev/null || lt_seen postmerge_qa "$1"; }
mark_done() { # mark_done <build-key> <merge-sha> <verdict>
  printf '%s %s %s %s\n' "$(STAMP)" "$1" "${2:0:8}" "$3" >> "$DONE"
  lt_put postmerge_qa "$1" "$3" "${2:0:8}"
}

# --- candidate builds --------------------------------------------------------
if [ -n "$ONE_BUILD" ]; then
  CANDIDATES="$ONE_BUILD"
else
  # A pool build's dir is pool-<project>-<KEY>-<stamp> (bin/fly-pool.sh). Without
  # it here a pool build never got a verdict row, and bin/merged-ticket-advance.sh
  # (which reads pool- dirs) skipped its ticket as no-audit forever.
  CANDIDATES=$(find "$H/builds" -maxdepth 1 -type d \( -name "$P-*" -o -name "pool-$P-*" \) \
                 -mmin "-$((LOOKBACK_H * 60))" 2>/dev/null | sort)
fi
[ -n "$CANDIDATES" ] || exit 0

RAN=0
for BUILD in $CANDIDATES; do
  [ "$RAN" -lt "$MAX" ] || break
  BK=$(basename "$BUILD")
  [ -f "$BUILD/RESULT" ] || continue
  already_done "$BK" && continue
  PR_URL=$(grep -oE 'https://github.com/[^ ]+/pull/[0-9]+' "$BUILD/RESULT" 2>/dev/null | head -1)
  [ -n "$PR_URL" ] || continue

  # The `// "-"` sentinel is load-bearing: `read` collapses runs of separators
  # (tab included, even with IFS set to just tab), so an EMPTY middle column
  # would shift the fields left and land mergedAt in MSHA — past the -n guard
  # below, probing production for a date. A column GitHub left null comes back
  # as "-" and is turned into the empty string here, where nothing can shift.
  read -r STATE MSHA MERGED_AT < <(gh pr view "$PR_URL" --json state,mergeCommit,mergedAt \
      -q '[.state, (.mergeCommit.oid // "-"), (.mergedAt // "-")] | @tsv' 2>/dev/null | tr '\t' ' ')
  [ "${MSHA:-}" = - ] && MSHA=""
  [ "${MERGED_AT:-}" = - ] && MERGED_AT=""
  [ "$STATE" = MERGED ] && [ -n "${MSHA:-}" ] || continue

  serves_sha "$MSHA"; GATE=$?
  if [ "$GATE" != 0 ]; then
    # >>> deploy age-out (BH-1022) ------------------------------------------
    # The gate's two not-serving answers used to have one reply between them:
    # come back next tick, forever. The clock is the PR's own mergedAt — prod
    # cannot serve a sha before it is merged, so "N hours since merge and still
    # not serving" is exactly "N hours of not yet serving" with no new state.
    # An absent or unparseable mergedAt is UNKNOWN, never old: it requeues as
    # before rather than ending a build on data we could not read.
    #
    # ONLY rc 1 AGES OUT. rc 2 means the SIGNAL was unreadable — curl failed or
    # `gh api` did — which is a fact about this box, not about this build. Twelve
    # hours of expired gh auth or an unreachable version host would otherwise
    # write every merged build of every project terminal in a single tick, and
    # none of them would be driven when the signal came back.
    case "$GATE" in
      1) WHY="prod not yet serving ${MSHA:0:8}" ;;
      *) WHY="cannot determine whether prod serves ${MSHA:0:8} (the deploy signal was unreadable)" ;;
    esac
    AGE_S=""
    [ -n "${MERGED_AT:-}" ] && ME=$(date -u -d "$MERGED_AT" +%s 2>/dev/null) && AGE_S=$((NOW - ME))
    if [ "$DEPLOY_MAX_H" -gt 0 ] && [ "$GATE" = 1 ] && [ -n "$AGE_S" ] && [ "$AGE_S" -ge $((DEPLOY_MAX_H * 3600)) ]; then
      # Alert BEFORE the done row: a crash between the two can duplicate an
      # alert, which is noise, but can never leave a build silently terminal.
      say "$BK: $WHY $((AGE_S / 3600))h after merge (limit ${DEPLOY_MAX_H}h) — NOT_COVERED_DEPLOY_TIMEOUT, not re-offered"
      echo "$(STAMP) [$P] POST-MERGE PROD QA NOT RUN for $BK (${MSHA:0:8}, $PR_URL): $WHY $((AGE_S / 3600))h after merge (limit ${DEPLOY_MAX_H}h). Nothing was driven for this merge, so the shipped screen has NOT been observed in production. Needed: confirm ${MSHA:0:8} reached $PROD (check bin/deploy-train.sh / the project's deploy lane; set VERSION_URL for this project if prod has no version endpoint), then re-run '$SELF/postmerge-qa.sh $P $BUILD' after removing the $BK row from $DONE." >> "$ALERTS"
      "$SELF/beat.sh" "$(jq -nc --arg p "$P" --arg akey "prodqa-deploy:$P:$MSHA" \
        --arg l "Post-merge QA gave up on $BK (${MSHA:0:8}): $WHY $((AGE_S / 3600))h after merge (limit ${DEPLOY_MAX_H}h) — $PROD is not confirmed serving this merge and nothing was driven ($PR_URL)" \
        '{kind:"fleet_alert",project:$p,akey:$akey,line:$l}')" >/dev/null 2>&1 || true
      mark_done "$BK" "$MSHA" NOT_COVERED_DEPLOY_TIMEOUT
      continue
    fi
    say "$BK: $WHY — requeued"
    continue
    # <<< deploy age-out
  fi

  # --- the account -----------------------------------------------------------
  QA_UID="${POSTMERGE_QA_USER_ID:-${QA_TEST_USER_ID:-}}"
  if [ -z "$QA_UID" ] || [ -z "${QA_CLERK_SECRET_KEY:-}" ]; then
    say "$BK: QA_TEST_USER_ID / QA_CLERK_SECRET_KEY unset — prod drive NOT run, no authed screen covered"
    mark_done "$BK" "$MSHA" NOT_COVERED_NO_QA_ENV
    continue
  fi

  RAN=$((RAN + 1))
  KEY=$(sed -E "s/^(pool-)?${P}-//; s/-[0-9]{8,}$//" <<<"$BK")
  OUT="$BUILD/qa-prod-shots"; mkdir -p "$OUT"
  REPORT="$BUILD/qa-prod.md"
  SCREENS=$(screens_for "$BUILD")
  # shellcheck disable=SC2086  # SCREENS is a deliberate whitespace-separated list
  set -- $SCREENS

  # >>> personas --------------------------------------------------------------
  # A repo that ships qa/personas.json gets its IN-SCOPE personas driven instead
  # of the one default account. Every reason we did NOT use personas is written
  # into the report as a PERSONAS: line rather than left to be inferred from its
  # absence — "not configured", "invalid" and "nothing in scope" are three
  # different answers and a reader of qa-prod.md is entitled to know which.
  PERSONAS_NOTE="none (no qa/personas.json)"
  SCOPED=""
  if [ -f "$REPO_DIR/qa/personas.json" ]; then
    if [ -r "$SELF/lib/qa-personas.sh" ]; then
      # shellcheck source=/dev/null
      . "$SELF/lib/qa-personas.sh"
      AF=""; [ -f "$REPO_DIR/qa/apps.json" ] && AF="$REPO_DIR/qa/apps.json"
      # Production scoping uses the PLANNED files run-build.sh already wrote.
      # The scoper refuses a missing path on purpose (a missing diff is not an
      # empty diff), so an absent planned-files.txt becomes a real empty file
      # here and scopes to NONE rather than to everything.
      CF="$BUILD/planned-files.txt"
      [ -f "$CF" ] || { CF="$OUT/planned-files.empty"; : > "$CF"; }
      # BH-5204: one persona per changed app area (qa.personas_per_area), least
      # privileged first. lane_env_apply above refreshed the settings cache, so
      # the row is read without a network call here. The per-area stderr goes
      # to its own file: personas.err's first line is the "invalid" note.
      SC=$(qa_personas_pick "$REPO_DIR/qa/personas.json" "$AF" "$CF" production \
             "$(qa_personas_per_area 2>"$OUT/personas-knob.err")" 2>"$OUT/personas.err")
      SCOPE_RC=$?
      [ -s "$OUT/personas-knob.err" ] && say "$BK: $(head -1 "$OUT/personas-knob.err")"
      if [ "$SCOPE_RC" != 0 ]; then
        PERSONAS_NOTE="invalid — $(head -1 "$OUT/personas.err" 2>/dev/null)"
        say "$BK: PERSONAS: $PERSONAS_NOTE — falling back to the screen drive"
      elif [ "$SC" = NONE ]; then
        PERSONAS_NOTE="NONE (no persona owns a changed area)"
      else
        printf '%s\n' "$SC" > "$OUT/scoped.json"
        SCOPED="$OUT/scoped.json"
        PICK_NOTE=$(qa_personas_pick_note "$SCOPED")
        PERSONAS_NOTE="$(qa_personas_list "$SCOPED" | cut -f1 | tr '\n' ' ' | sed 's/ *$//') (mode production) — $PICK_NOTE"
        say "$BK: PERSONAS: $PICK_NOTE"
      fi
    else
      PERSONAS_NOTE="invalid — bin/lib/qa-personas.sh missing"
      say "$BK: PERSONAS: $PERSONAS_NOTE — falling back to the screen drive"
    fi
  fi
  # <<< personas

  QA_RC=0
  command -v job_lane_open >/dev/null 2>&1 && \
    job_lane_open "prodqa/$P/claude" "$PR_URL" prodqa \
      "$(jq -nc --arg l postmerge-qa --arg s "$SLUG" --arg k "$KEY" --arg sha "$MSHA" \
         '{label:$l,repo:$s,ticket:$k,merge_sha:$sha}' 2>/dev/null)" >/dev/null 2>&1 || true
  trap 'command -v job_lane_close >/dev/null 2>&1 && job_lane_close "$QA_RC" "postmerge-qa $P"' EXIT

  {
    printf '# Post-merge production QA — %s\n\n' "$KEY"
    printf -- '- base: %s\n- merge sha: %s\n- PR: %s\n- screens requested: %s\n- PERSONAS: %s\n\n' \
      "$PROD" "${MSHA:0:8}" "$PR_URL" "$SCREENS" "$PERSONAS_NOTE"
    printf '## Observed (deterministic drive)\n\n```\n'
  } > "$REPORT"

  # THE DRIVE. Always through qa-unbanned.sh: a no-op for an account that is
  # active at rest, and the unban/restore window for one that is not.
  # errexit is off in this script by design (set -uo pipefail, no -e): a QA
  # drive that fails is the OUTPUT, not a reason to abandon the run.
  PBLOCKED=""; DRIVEN=""
  if [ -n "$SCOPED" ]; then
    # THE PERSONA DRIVE, one persona at a time. Sequential is not laziness: the
    # unban window is per (project, account) and two open at once would have one
    # drive re-ban the account out from under the other. The cap is an operator
    # knob, and the personas past it are PRINTED as not driven — capped work
    # that leaves no row is work nobody knows is missing.
    MAXP="${E2E_MAX_PERSONAS:-4}"
    # A knob that is not a number would make `[ $N -gt $MAXP ]` error and read
    # as "under the cap", i.e. silently no cap at all. Say what happened and use
    # the default instead.
    case "$MAXP" in
      ''|*[!0-9]*) say "$BK: E2E_MAX_PERSONAS='$MAXP' is not a whole number — using the default of 4"
                   MAXP=4 ;;
    esac
    PLAN_SCREENS=("$@")
    N=0; DRIVE_RC=0; REQUEUE=0; FIRST=1
    while IFS=$'\t' read -r PID PROLE; do
      N=$((N + 1))
      if [ "$N" -gt "$MAXP" ]; then
        qa_personas_blocked_rows "$SCOPED" "$PID" "not driven (persona cap)" >> "$REPORT"
        continue
      fi
      # An unresolvable role STOPS this persona. Falling through to the default
      # account would drive production as somebody else and report it as this
      # persona — the one lie this lane must not be able to tell.
      PUID=$("$SELF/qa-account.sh" "$P" "$PROLE" 2>/dev/null) || {
        qa_personas_blocked_rows "$SCOPED" "$PID" "no QA account for $P/$PROLE" >> "$REPORT"
        PBLOCKED="${PBLOCKED:+$PBLOCKED; }persona $PID: no QA account for $P/$PROLE"
        continue
      }
      # The plan's screens ride the FIRST persona actually driven, so the screen
      # coverage the old lane gave is not lost and not paid for N times.
      if [ "$FIRST" = 1 ]; then FIRST=0; PATHS=("${PLAN_SCREENS[@]}"); else PATHS=(); fi
      mkdir -p "$OUT/$PID"
      PDRIVE="$OUT/$PID/drive.txt"
      QA_TEST_USER_ID="$PUID" "$SELF/qa-unbanned.sh" "$P" "$PROLE" -- \
        node "$SELF/qa-drive.mjs" "$PROD" "$REPO_DIR" "$OUT/$PID" \
        ${PATHS[@]+"${PATHS[@]}"} --flows "$SCOPED" --persona "$PID" --production \
        > "$PDRIVE" 2>&1
      PRC=$?
      cat "$PDRIVE" >> "$REPORT"
      # NO `|| echo 0`: grep -c prints 0 on no match and exits 1, so a fallback
      # would append a SECOND zero and the comparison below would read "0\n0".
      ROWS=$(grep -c '^FLOW ' "$PDRIVE")
      [ "$ROWS" = 0 ] || DRIVEN="${DRIVEN:+$DRIVEN }$PID"
      case "$PRC" in
        0) ;;
        75) REQUEUE=1; break ;;
        90) qa_personas_blocked_rows "$SCOPED" "$PID" "qa-unbanned rc=90 (re-ban failed)" >> "$REPORT"
            PBLOCKED="${PBLOCKED:+$PBLOCKED; }persona $PID: the drive ran but the QA account could NOT be re-banned — it is live in production right now" ;;
        91) qa_personas_blocked_rows "$SCOPED" "$PID" "qa-unbanned rc=91 (ban state unreadable or unban did not take)" >> "$REPORT"
            PBLOCKED="${PBLOCKED:+$PBLOCKED; }persona $PID: the QA account's Clerk ban state was unreadable or the unban did not take — nothing was driven" ;;
        # A drive that exited non-zero having printed NO flow rows observed
        # nothing, so it is BLOCKED, not a defect claim. One that printed rows
        # did observe something, and its rc is a real FAIL.
        *) if [ "$ROWS" = 0 ]; then
             qa_personas_blocked_rows "$SCOPED" "$PID" "drive emitted no FLOW rows (rc=$PRC)" >> "$REPORT"
             PBLOCKED="${PBLOCKED:+$PBLOCKED; }persona $PID: drive emitted no FLOW rows (rc=$PRC)"
           else
             DRIVE_RC=$PRC
           fi ;;
      esac
    done < <(qa_personas_list "$SCOPED")
    # A busy window requeues the whole BUILD, and the rc-75 handling below is
    # the one that already knows how to say so.
    [ "$REQUEUE" = 1 ] && DRIVE_RC=75
  else
    QA_TEST_USER_ID="$QA_UID" "$SELF/qa-unbanned.sh" "$P" "$QA_UID" -- \
      node "$SELF/qa-drive.mjs" "$PROD" "$REPO_DIR" "$OUT" "$@" >> "$REPORT" 2>&1
    DRIVE_RC=$?
  fi
  printf '```\n\n' >> "$REPORT"

  DRIVE_LAST=$(grep -E '^QA: (PASS|FAIL)$' "$REPORT" | tail -1)
  # Recursive: the persona lane writes into $OUT/<persona>/, so a depth-1 count
  # would report zero screenshots for a run that took plenty.
  SHOTS=$(find "$OUT" -type f -name '*.png' 2>/dev/null | wc -l)

  # BLOCKED IS ITS OWN OUTCOME, and inventing it was not optional. qa-unbanned.sh
  # has three rcs that mean "the harness never drove anything": 75 (another drive
  # holds this account's unban window), 91 (the ban state was unreadable, or the
  # unban did not take) and 90 (the drive ran but the RE-ban failed). Folding any
  # of them into FAIL would page a human with "prod is broken" when the truth is
  # "we could not look" — a fabricated defect claim about a shipped feature, which
  # is the exact dishonesty this stage exists to remove from the other direction.
  #
  #   75  -> requeue silently. Contention is normal and self-clearing.
  #   90  -> the account is LIVE IN PRODUCTION. qa-unbanned.sh has already
  #          written its own ALERTS line and beat; this one records that the
  #          ticket was not QA'd, and does not retry into the same window.
  #   91  -> stop and say what is needed, once. Retrying hourly would turn one
  #          unanswerable question into a daily alert stream.
  BLOCKED=""
  case "$DRIVE_RC" in
    75) say "$BK: another drive holds the QA account's unban window — requeued"
        printf '```\n\n_(not driven: the QA account'"'"'s unban window was busy; requeued)_\n' >> "$REPORT"
        command -v job_lane_close >/dev/null 2>&1 && job_lane_close 0 "postmerge-qa $P $KEY requeued" || true
        trap - EXIT; continue ;;
    90) BLOCKED="the drive ran but the QA account could NOT be re-banned — it is live in production right now" ;;
    91) BLOCKED="the QA account's Clerk ban state was unreadable or the unban did not take — nothing was driven" ;;
  esac
  # The case above reads ONE rc, which is all the single-account lane has. The
  # persona lane can have a different answer per persona, so its blocks arrive
  # here as text. Folded in before the agent gate on purpose: an LLM cannot read
  # a screen nobody reached, for a persona any more than for an account.
  [ -n "$PBLOCKED" ] && BLOCKED="${BLOCKED:+$BLOCKED; }$PBLOCKED"

  # --- the judgemental pass, only when the drive FAILED (BH-2547) -------------
  # A green drive already has its verdict, so paying a model to re-confirm it is
  # spend with no decision behind it. The agent characterises a failure instead.
  # Failed = a non-zero rc (qa-drive.mjs exits non-zero on every `QA: FAIL` it
  # prints) or a `FLOW … fail` row, which a persona can leave at rc 0.
  DRIVE_FAILED=0
  [ "$DRIVE_RC" = 0 ] || DRIVE_FAILED=1
  grep -qE '^FLOW [^ ]+ [^ ]+ fail( |$)' "$REPORT" && DRIVE_FAILED=1
  AGENT_NOTE="not run"
  if [ "$DRIVE_FAILED" = 1 ] && [ -z "$BLOCKED" ] && [ "${POSTMERGE_QA_AGENT:-1}" = 1 ] && [ -x "$SELF/agent-call.sh" ]; then
    printf '## Observed (driven flows)\n\n' >> "$REPORT"
    # The map entries for the screens this ticket touches: their nav paths and
    # selectors, and the "What usually lies" bullets a PASS has to survive.
    # Only the outcome line goes into the report; the content is for the agent.
    if declare -F vmap_note >/dev/null; then VMAP_NOTE=$(vmap_note "$REPO_DIR" "$BUILD/plan.md")
    else VMAP_NOTE="VERIFICATION MAP: lookup unavailable (lib absent)"; fi
    printf '%s\n\n' "$(head -n1 <<<"$VMAP_NOTE")" >> "$REPORT"
    # One sentence, only when a persona lane actually ran, so the agent does not
    # pay to re-drive a flow the deterministic lane already has a verdict for.
    FLOWS_NOTE=""
    [ -n "$SCOPED" ] && FLOWS_NOTE=" Persona flows already driven by the deterministic lane (id: verdict): $(grep -E '^FLOW ' "$REPORT" | awk '{printf "%s%s/%s %s", (NR>1?", ":""), $2, $3, $4}')."
    PROMPT="Post-merge PRODUCTION QA. $PROD is serving merge sha ${MSHA:0:8} for $PR_URL. A deterministic drive FAILED on these screens (signed in as the QA user, loaded at 1280px and 375px): $SCREENS — its observations (the failing FLOW rows / FAIL lines) are in $REPORT and $OUT/observed.json, and its screenshots in $OUT/.$FLOWS_NOTE Read $BUILD/plan.md for what this ticket claimed to ship. Your job is to reproduce and characterise that failure: what breaks, where, and whether it is a real in-scope defect of this ticket or a pre-existing / out-of-scope one. The drive's FAIL stands whatever you find.

$VMAP_NOTE
Take nav paths and selectors from these entries; before writing QA: PASS check each 'What usually lies' bullet against what you observed; an entry that no longer matches the app is a finding.

Now drive the FLOW that failed, as the same signed-in user, with a HEADLESS playwright script (chromium; resolve playwright via createRequire from $REPO_DIR, ESM ignores NODE_PATH; sign in exactly as $SELF/qa-drive.mjs does — mint a one-time Clerk ticket and open <base>/sign-in?__clerk_ticket=<token>). THIS IS PRODUCTION: obviously-fake inputs, NON-DESTRUCTIVE actions only, never a delete, a payment, an email, or a write to a real client record. Note, do not FAIL on, a missing sort indicator, a dead non-identity row, a few px of overflow or a copy nit (BH-7123). FAIL on a core flow a user cannot finish, a broken screen, a console error, a native dialog that freezes the drive. LANDING ON /sign-in IS A FAIL, never a skip. Append your findings to $REPORT as '- ' bullets. COUNT WHAT YOU ACTUALLY DID: the second-to-last line must be exactly 'QA COVERAGE: screens=<n> flows=<n> shots=<n>' counting only what you really loaded, really drove and really wrote. Last line exactly 'QA: PASS' or 'QA: FAIL' — FAIL for real in-scope defects, console errors, broken screens, or zero coverage. Pre-existing issues outside this ticket are noted separately, not failed."
    AGENT_CALL_ROLE=postmerge.qa "$SELF/agent-call.sh" prodqa "$P" "$QA_MODEL" 1500 "$BUILD/qa-prod-run.txt" "$PROMPT" >/dev/null 2>&1
    AGENT_RC=$?
    if [ "$AGENT_RC" = 0 ]; then AGENT_NOTE="ran"; else AGENT_NOTE="failed (rc=$AGENT_RC) — flows NOT covered"; fi
  elif [ "$DRIVE_FAILED" = 0 ] && [ -z "$BLOCKED" ]; then
    AGENT_NOTE="not run — the deterministic drive was green, its verdict stands"
  fi

  # --- the verdict -----------------------------------------------------------
  # The deterministic drive is authoritative for a FAIL: it either landed a
  # session and loaded the screens or it did not, and no later prose can talk
  # that back. The agent pass can only ADD a failure.
  LAST=$(tail -1 "$REPORT" 2>/dev/null)
  VERDICT=PASS
  [ "$DRIVE_RC" = 0 ] || VERDICT=FAIL
  case "$LAST" in *"QA: FAIL"*) VERDICT=FAIL ;; esac
  # A per-flow assertion that timed out is a ROW, not an exit code: the drive can
  # finish every flow it was given, exit 0, and still have watched one fail. The
  # rows are the observation, so the rows decide too.
  grep -qE '^FLOW [^ ]+ [^ ]+ fail( |$)' "$REPORT" && VERDICT=FAIL
  [ -n "$BLOCKED" ] && VERDICT=BLOCKED
  if [ -n "$SCOPED" ]; then
    FPASS=$(grep -cE '^FLOW [^ ]+ [^ ]+ pass' "$REPORT")
    FFAIL=$(grep -cE '^FLOW [^ ]+ [^ ]+ fail' "$REPORT")
    FBLOCK=$(grep -cE '^FLOW [^ ]+ [^ ]+ blocked' "$REPORT")
    FSKIP=$(grep -cE '^FLOW [^ ]+ [^ ]+ skipped' "$REPORT")
  fi
  {
    printf '\n## Verdict\n\n'
    printf -- '- deterministic drive: %s (rc=%s, %s screenshots on disk)\n' "${DRIVE_LAST:-no verdict line}" "$DRIVE_RC" "$SHOTS"
    [ -n "$SCOPED" ] && printf -- '- persona flows: pass=%s fail=%s blocked=%s skipped=%s (driven: %s)\n' \
      "$FPASS" "$FFAIL" "$FBLOCK" "$FSKIP" "${DRIVEN:-none}"
    printf -- '- flow drive: %s\n' "$AGENT_NOTE"
    printf -- '- deploy gate: prod confirmed serving %s before anything was driven\n' "${MSHA:0:8}"
    [ -n "$BLOCKED" ] && printf -- '- BLOCKED: %s. This ticket was NOT QA'"'"'d in production — the verdict below is about the harness, not the app.\n' "$BLOCKED"
    printf '\nQA: %s\n' "$VERDICT"
  } >> "$REPORT"

  [ "$VERDICT" = PASS ] || QA_RC=1
  say "$BK: prod QA $VERDICT (${MSHA:0:8}, shots=$SHOTS, drive rc=$DRIVE_RC, flows: $AGENT_NOTE)"

  # --- attach ---------------------------------------------------------------
  "$SELF/findings-log.sh" "$BUILD" "$P" "$KEY" >/dev/null 2>&1 || true
  gh pr comment "$PR_URL" --body "$(printf 'Post-merge production QA (%s, merge sha %s):\n\n```\n%s\n```' \
      "$PROD" "${MSHA:0:8}" "$(tail -c 1200 "$REPORT" 2>/dev/null)")" >/dev/null 2>&1 || true

  if [ "$VERDICT" = FAIL ]; then
    # BH-6902: collect first, then one issue per screen or flow (off per board
    # until lib.group-findings.<board>.group_findings is 1). Fail-open.
    # shellcheck source=bin/lib/group-findings.sh
    if [ -r "$SELF/lib/group-findings.sh" ] && . "$SELF/lib/group-findings.sh"; then
      GF_OBS=()
      while IFS= read -r -d '' GF_F; do GF_OBS+=("$GF_F"); done < <(find "$OUT" -name observed.json -type f -print0 2>/dev/null)
      gf_from_observed "$P" ${GF_OBS[@]+"${GF_OBS[@]}"} > "$BUILD/qa-findings.jsonl" 2>>"$LOG"
      GF_SLUG=$(sed -nE 's#^https://github\.com/([^/]+/[^/]+)/pull/[0-9]+.*#\1#p' <<<"$PR_URL")
      gf_run "$BUILD/qa-findings.jsonl" "$BUILD" "$GF_SLUG" >/dev/null 2>>"$LOG" || true
      say "$BK: $(tail -1 "$BUILD/group-findings.md" 2>/dev/null || echo 'group-findings: no summary written')"
    fi
    echo "$(STAMP) [$P] POST-MERGE PROD QA FAILED for $KEY (${MSHA:0:8}, $PR_URL): $(grep -m1 '^FAIL: ' "$REPORT" 2>/dev/null || echo 'see '"$REPORT")" >> "$ALERTS"
    "$SELF/beat.sh" "$(jq -nc --arg p "$P" --arg akey "prodqa:$P:$MSHA" \
      --arg l "PROD QA FAILED after merge: $KEY is live at $PROD and a real signed-in drive found defects ($PR_URL)" \
      '{kind:"fleet_alert",project:$p,akey:$akey,line:$l}')" >/dev/null 2>&1 || true
  elif [ "$VERDICT" = BLOCKED ]; then
    # Stopping is an alert, not a whisper (2026-08-13 doctrine): say what is
    # needed and from whom, once, rather than asking the question into a log.
    echo "$(STAMP) [$P] POST-MERGE PROD QA BLOCKED for $KEY (${MSHA:0:8}, $PR_URL): $BLOCKED. NOT a defect claim — the shipped screen has not been observed in production. Next step is mechanical: bin/qa-unbanned.sh settles the QA account's Clerk ban state, then re-run '$SELF/postmerge-qa.sh $P $BUILD'." >> "$ALERTS"
  fi

  mark_done "$BK" "$MSHA" "$VERDICT"
  command -v job_lane_close >/dev/null 2>&1 && job_lane_close "$QA_RC" "postmerge-qa $P $KEY $VERDICT" || true
  trap - EXIT
done
command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset
exit 0
