#!/bin/bash
# bin/hotfix-after-deploy.sh: the post-deploy half of the hotfix lane (BH-370.4 / BH-378).
#
# bin/hotfix-migrate.sh applies a hotfix PR's SQL BEFORE the merge when the app
# already serves it, and records `deferred-to-deploy` when it does not: the
# endpoint's own rule is that a file is pending only once the merge carrying it
# is live. Something has to come back afterwards, and until this script existed
# nothing did — the */15 cron tick would eventually apply the file, silently,
# with no second proof on the PR and the client's issue still open. So: once
# bin/deploy-verify.sh has logged `deploy-verify OK` for the merge sha, it calls
# this, which applies the deferred files through the same driver, posts a SECOND
# proof comment on the PR, records the outcome in the ledger, and only when every
# file came back with the endpoint's literal `applied`/`already-applied` word
# comments "deployed <sha>, live at <url>" on the issue and closes it, if
# issue_close_guard says the merge delivered the issue (BH-2508; a slice keeps
# the issue open and takes ai-build off it, an undecided guard alerts). A file
# that did not apply is an ALERT and leaves the issue open; it never masks the
# deploy verdict (the caller ignores our exit code on purpose).
#
#   usage: hotfix-after-deploy.sh <project> <build-dir> <sha>
#   exit 0 nothing to do / applied and closed out | 1 a file did not apply, an
#   unparseable ledger, no PR to post on, or no token that can see the repo
#
# Knob: HOTFIX_AFTERDEPLOY_RETRY_WAIT (seconds, default 60) — the one pause
# before the single retry when the */15 cron tick owns the driver's lock.
set -uo pipefail
PROJECT="${1:-}"; BUILD="${2:-}"; SHA="${3:-}"
HARNESS="${HARNESS:-/root/harness}"
if [ -z "$PROJECT" ] || [ -z "$BUILD" ] || [ -z "$SHA" ] || [ ! -d "$BUILD" ]; then
  echo "usage: hotfix-after-deploy.sh <project> <build-dir> <sha>" >&2; exit 1
fi
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
ALERTS="$HARNESS/logs/ALERTS.log"

# THE LEDGER DECIDES WHETHER THIS SCRIPT HAS ANY BUSINESS RUNNING, and it is read
# before anything else: most merges are not hotfixes, and a no-op must cost zero
# API calls. Absent is "not a hotfix build" and silent; unparseable is a bug we
# refuse to guess through (D11).
LEDGER="$BUILD/hotfix-migrate.json"
[ -s "$LEDGER" ] || exit 0
if ! jq -e . >/dev/null 2>&1 < "$LEDGER"; then
  echo "hotfix-after-deploy: $LEDGER is not readable JSON. Refusing to guess what happened to the SQL" >&2
  exit 1
fi

# shellcheck source=bin/lib/env-path.sh
. "$HARNESS/bin/lib/env-path.sh" 2>/dev/null \
  || harness_env_dir() { printf '%s\n' "${1:-$HARNESS}/env"; }
HENV=$(harness_env_dir "$HARNESS")
set -a
[ -f "$HENV/global.env" ] && . "$HENV/global.env"
[ -f "$HENV/$PROJECT.env" ] && . "$HENV/$PROJECT.env"
set +a
# shellcheck source=bin/lib/gh-repo-token.sh
[ -r "$HARNESS/bin/lib/gh-repo-token.sh" ] && . "$HARNESS/bin/lib/gh-repo-token.sh"
# shellcheck source=bin/lib/gh-app-auth.sh
[ -r "$HARNESS/bin/lib/gh-app-auth.sh" ] && . "$HARNESS/bin/lib/gh-app-auth.sh"
# BH-1651: the issue comment and close are REST (gh_rest_comment, gh_rest_close).
for _P in "$(dirname "$0")/lib/gh-rest.sh" "$HARNESS/bin/lib/gh-rest.sh"; do
  # shellcheck source=bin/lib/gh-rest.sh
  [ -r "$_P" ] && { . "$_P"; break; }
done
# BH-2508: the close-out asks issue_close_guard whether this merge delivered the
# issue, the same guard the merge close-outs use (BH-2477).
for _P in "$(dirname "$0")/lib/issue-state-lib.sh" "$HARNESS/bin/lib/issue-state-lib.sh"; do
  # shellcheck source=bin/lib/issue-state-lib.sh
  [ -r "$_P" ] && { . "$_P"; break; }
done

MODE=$(jq -r '.mode // ""' "$LEDGER")
DECISION=$(jq -r '.decision // ""' "$LEDGER")
FP=$(jq -r '.fp // ""' "$LEDGER")

# The build-dir name carries the ticket key, same parse as hotfix-migrate.sh.
KEY=$(basename "$BUILD"); KEY="${KEY#"$PROJECT"-}"; KEY="${KEY%-*}"
ISSUE="${KEY##*-}"; case "$ISSUE" in ''|*[!0-9]*) ISSUE="" ;; esac

SLUG="${SLUG:-}"
[ -n "$SLUG" ] || SLUG=$("$HARNESS/bin/fleet-conf.sh" "$PROJECT" repo 2>/dev/null)
[ -n "$SLUG" ] || SLUG=$(git -C "/root/repos/$PROJECT" remote get-url origin 2>/dev/null \
  | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')

PR_URL="${PR_URL:-}"
if [ -z "$PR_URL" ] && [ -s "$BUILD/RESULT" ]; then
  case "$(awk 'NR==1{print $1}' "$BUILD/RESULT")" in
    PR_*) PR_URL=$(awk 'NR==1{print $2}' "$BUILD/RESULT") ;;
  esac
fi
PRN=$(sed -nE 's#.*/pull/([0-9]+).*#\1#p' <<<"$PR_URL" | head -n1)
case "${PRN:-}" in ''|*[!0-9]*)
  echo "hotfix-after-deploy: no PR number in '$PR_URL'. There is nothing to post the second proof on" >&2
  exit 1 ;;
esac

# Once per merge sha, implemented and not just claimed: a by-hand re-run after
# the ledger already records THIS sha as applied would re-POST the SQL and post
# a duplicate proof. Say so and stop, before any token is spent. The ledger
# records only the apply, so a close-out that was owed after it (HOTFIX
# CLOSE-OUT OWED on ALERTS) is finished by hand, never by a re-run.
AD_SHA=$(jq -r '.after_deploy.sha // ""' "$LEDGER")
AD_STATUS=$(jq -r '.after_deploy.status // ""' "$LEDGER")
if [ "$AD_SHA" = "$SHA" ] && [ "$AD_STATUS" = applied ]; then
  echo "$(STAMP) [$PROJECT] hotfix-after-deploy: $KEY already applied on ${SHA:0:8}; the close-out is not re-run, see ALERTS if it was owed. Nothing to do" >&2
  exit 0
fi

if command -v gh_repo_use_token >/dev/null 2>&1; then
  gh_repo_use_token "$SLUG" || {
    gh_repo_invisible_alert hotfix-after-deploy "$SLUG" \
      "the post-deploy apply and close-out for $KEY was not posted"
    exit 1; }
fi
# #425: the probe above only proved the repo is visible. Spend this repo's App
# installation token for every gh call below when the box is armed, the same
# shape as bin/deploy-verify.sh; unarmed, the PAT carries on as today.
command -v gh_auth_for >/dev/null 2>&1 && gh_auth_for "$SLUG" || true

# ── the apply ───────────────────────────────────────────────────────────────
# Only the endpoint shape defers to deploy; a workflow deferral is BH-370.3's
# and this slice says so rather than inventing a verdict for it.
STATUS_WORDS=""; APPLY_LINES=""; RAN_APPLY=0; VERDICT=applied
if [ "$DECISION" = deferred-to-deploy ]; then
  if [ "$MODE" != endpoint ]; then
    echo "$(STAMP) [$PROJECT] hotfix-after-deploy: $KEY deferred under mode=$MODE, which this slice does not apply. Nothing was touched" >&2
    exit 0
  fi
  mapfile -t LPATHS < <(jq -r '.files[]?.path // empty' "$LEDGER")
  if [ "${#LPATHS[@]}" -eq 0 ]; then
    echo "hotfix-after-deploy: the ledger defers to deploy but names no files. Nothing to apply" >&2
    exit 1
  fi
  BN=(); for f in "${LPATHS[@]}"; do BN+=("$(basename "$f")"); done
  RAN_APPLY=1
  WAIT="${HOTFIX_AFTERDEPLOY_RETRY_WAIT:-60}"
  case "$WAIT" in ''|*[!0-9]*) WAIT=60 ;; esac
  TRY=0
  while :; do
    "$HARNESS/bin/apply-migrations.sh" "$PROJECT" --files "${BN[@]}" \
      > "$BUILD/hotfix-after-deploy.jsonl" 2>>"$BUILD/hotfix-after-deploy.err"
    ARC=$?
    # 75 is the driver's "the */15 tick owns the lock". We never wait on a lock
    # for its lifetime: one pause, one retry, then it is a failure with a word
    # that says so, because the tick will apply the file and the alert says that.
    [ "$ARC" = 75 ] || break
    TRY=$((TRY+1)); [ "$TRY" -ge 2 ] && break
    sleep "$WAIT"
  done
  if [ "$ARC" = 75 ]; then
    for b in "${BN[@]}"; do
      APPLY_LINES="$APPLY_LINES$(jq -nc --arg f "$b" '{filename:$f,status:"busy"}')
"
      STATUS_WORDS="$STATUS_WORDS$b=busy,"
    done
    VERDICT=failed
  else
    mapfile -t LINES < "$BUILD/hotfix-after-deploy.jsonl"
    if [ "${#LINES[@]}" != "${#BN[@]}" ]; then
      VERDICT=failed
      for b in "${BN[@]}"; do STATUS_WORDS="$STATUS_WORDS$b=unreadable,"; done
      APPLY_LINES=$(cat "$BUILD/hotfix-after-deploy.jsonl")
    else
      i=0
      while [ "$i" -lt "${#BN[@]}" ]; do
        ST=$(jq -r '.status // empty' <<<"${LINES[$i]}" 2>/dev/null)
        WANT=$(jq -r '.filename // empty' <<<"${LINES[$i]}" 2>/dev/null)
        [ -n "$ST" ] && [ "$WANT" = "${BN[$i]}" ] || { ST="unreadable"; }
        # The WORD decides, never .ok and never the rc: the endpoint has answered
        # ok:true beside a refused status.
        case "$ST" in applied|already-applied) ;; *) VERDICT=failed ;; esac
        STATUS_WORDS="$STATUS_WORDS${BN[$i]}=$ST,"
        APPLY_LINES="$APPLY_LINES${LINES[$i]}
"
        i=$((i+1))
      done
    fi
  fi
elif [ "$DECISION" != applied ]; then
  # hold, flagged, no-path: nothing was applied and nothing is owed. The first
  # proof comment already said so and no issue gets closed on the strength of it.
  echo "$(STAMP) [$PROJECT] hotfix-after-deploy: $KEY decision=$DECISION, so there is no post-deploy apply and no close-out" >&2
  exit 0
fi
STATUS_WORDS="${STATUS_WORDS%,}"

# ── the ledger, written AFTER the side effect it records ────────────────────
TMP="$LEDGER.tmp.$$"
if jq --arg sha "$SHA" --arg st "$VERDICT" --arg w "$STATUS_WORDS" \
      '.after_deploy = {sha:$sha, status:$st, files:$w}' "$LEDGER" > "$TMP" 2>/dev/null; then
  mv "$TMP" "$LEDGER"
else
  rm -f "$TMP"
  echo "hotfix-after-deploy: could not update the ledger's after_deploy block" >&2
fi

# A close-out that did not happen after a SUCCESSFUL apply is owed to a human:
# the ledger says applied while the PR carries no proof or the issue stays open,
# and the caller drops our rc on purpose, so a stderr line in pipeline.log is
# silence. One ALERTS line + one fleet_alert beat, naming exactly what is owed.
CLOSEOUT_ALERT() { # CLOSEOUT_ALERT <what is owed>
  mkdir -p "$HARNESS/logs" 2>/dev/null
  echo "$(STAMP) [$PROJECT] HOTFIX CLOSE-OUT OWED (${SHA:0:8}): $1 (PR $PR_URL, build $(basename "$BUILD"))" >> "$ALERTS"
  "$HARNESS/bin/beat.sh" "$(jq -nc --arg p "$PROJECT" --arg akey "hotfixafter:$PROJECT:$SHA:closeout" \
    --arg l "HOTFIX close-out owed on ${SHA:0:8}: $1 ($PR_URL)" \
    '{kind:"fleet_alert",project:$p,akey:$akey,line:$l}')" >/dev/null 2>&1
}

# ── the second proof, on the PR ─────────────────────────────────────────────
BODY=$(mktemp)
{
  printf '<!-- hotfix-migrate-afterdeploy fp=%s status=%s -->\n\n' "$FP" "$VERDICT"
  if [ "$RAN_APPLY" = 1 ]; then
    if [ "$VERDICT" = applied ]; then
      printf 'The merge is deployed, so I applied the SQL this hotfix had deferred.\n\n'
    else
      printf 'The merge is deployed and I tried to apply the SQL this hotfix deferred. It did not all go through, so I left the ticket open.\n\n'
    fi
    printf 'post-deploy apply on %s:\n\n```\n%s```\n' "$SHA" "$APPLY_LINES"
  else
    printf 'Nothing was deferred for this hotfix: the SQL went in with the PR. Recording the deploy so the trail is complete.\n\n'
    printf 'post-deploy apply on %s: nothing to apply.\n' "$SHA"
  fi
} > "$BODY"
CID=$(gh api "repos/$SLUG/issues/$PRN/comments" -F "body=@$BODY" -q .id 2>>"$BUILD/hotfix-after-deploy.err")
rm -f "$BODY"
if [ -z "$CID" ]; then
  echo "hotfix-after-deploy: the post-deploy proof for $KEY did not post to $PR_URL" >&2
  POST_FAILED=1
else
  POST_FAILED=0
fi

# ── failure is loud, and closes nothing ────────────────────────────────────
if [ "$VERDICT" != applied ]; then
  mkdir -p "$HARNESS/logs" 2>/dev/null
  echo "$(STAMP) [$PROJECT] HOTFIX POST-DEPLOY APPLY FAILED (${SHA:0:8}): PR $PR_URL files: $STATUS_WORDS (build $(basename "$BUILD"))" >> "$ALERTS"
  "$HARNESS/bin/beat.sh" "$(jq -nc --arg p "$PROJECT" --arg akey "hotfixafter:$PROJECT:$SHA" \
    --arg l "HOTFIX post-deploy apply did not go through on ${SHA:0:8}: $STATUS_WORDS ($PR_URL)" \
    '{kind:"fleet_alert",project:$p,akey:$akey,line:$l}')" >/dev/null 2>&1
  command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset
  exit 1
fi
if [ "$POST_FAILED" = 1 ]; then
  CLOSEOUT_ALERT "the SQL is applied but the post-deploy proof did not post to the PR; post it by hand${ISSUE:+ and close issue $ISSUE}"
  command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset
  exit 1
fi

# ── close-out, only for the GitHub-Issues lane ─────────────────────────────
# board_prefix `-` in fleet.conf IS the GitHub-Issues lane; a project with an
# in-app product board has no issue to close and its PR comment is the whole
# record (bin/fleet-conf.sh --projects-with-board is the same fact).
PREFIX=$("$HARNESS/bin/fleet-conf.sh" "$PROJECT" board_prefix 2>/dev/null)
if [ "$PREFIX" = "-" ] && [ -n "$ISSUE" ]; then
  STATE=$(gh api "repos/$SLUG/issues/$ISSUE" -q .state 2>/dev/null)
  # A merge that only SLICED the issue (Refs, a SLICE plan line, open children)
  # leaves it open and takes ai-build off it (the slice comment is skipped when
  # the merge close-out already paid it into this build record); a guard that cannot decide, or is
  # not loaded, closes nothing. Our rc is dropped, so each of those is ALERTS.
  G=close
  if [ "$STATE" = open ]; then
    if command -v issue_close_guard >/dev/null 2>&1; then
      G=$(issue_close_guard "$SLUG" "$ISSUE" "$PR_URL" "$BUILD" "$HARNESS")
    else
      G=unknown:no-guard
    fi
  fi
  if [ "$STATE" = open ] && [ "${G%%:*}" = slice ]; then
    W=$(issue_slice_settle "$SLUG" "$ISSUE" "$PR_URL" "$G" "$HARNESS" "$BUILD")
    # BH-6308: with no open child the slice close-out may close the issue.
    case "$W" in
      closed-slice:*) echo "hotfix-after-deploy: closed issue $ISSUE, the merged slices delivered it ($W)" >&2 ;;
      *)              echo "hotfix-after-deploy: left issue $ISSUE open, slice delivered ($W)" >&2 ;;
    esac
    OWED=""
    case "$W" in *+strip-failed*) OWED="take ai-build off issue $ISSUE by hand" ;; esac
    case "$W" in *,comment-failed*) OWED="${OWED:+$OWED and }post the slice note on issue $ISSUE by hand" ;; esac
    # BH-4662: the child-issue read failed, so nothing was written; our rc is dropped.
    # BH-5961: close-deferred:remainder is the remainder filing, not that read.
    case "$W" in
      close-deferred:remainder) OWED="filing the remaining slices of issue $ISSUE did not finish; the next close-out tick resumes it from $BUILD/slice-remainder" ;;
      close-deferred:slice-closeout) OWED="the slice close-out of issue $ISSUE did not finish; the next close-out tick resumes it from $BUILD/slice-closeout" ;;
      close-deferred:*) OWED="the child-issue read failed, so check issue $ISSUE's children and settle it by hand" ;; esac
    [ -z "$OWED" ] || CLOSEOUT_ALERT "issue $ISSUE is a slice of a master; $W; $OWED"
  elif [ "$STATE" = open ] && [ "$G" != close ]; then
    echo "hotfix-after-deploy: the close guard could not decide ($G), so issue $ISSUE stays open" >&2
    CLOSEOUT_ALERT "the close guard could not decide ($G); check whether PR $PR_URL delivered issue $ISSUE and close it by hand"
  elif [ "$STATE" = open ]; then
    PROD=$("$HARNESS/bin/prod-url.sh" "$PROJECT" 2>/dev/null)
    if [ -n "$PROD" ]; then
      WHERE="It is live at $PROD"
    else
      # No invented URL: fleet.conf has no prod column for this project and the
      # comment says that rather than guessing a domain.
      WHERE="I have no production URL on file for this project, so check it where you normally do"
    fi
    CF=$(mktemp "${TMPDIR:-/tmp}/hotfix-comment.XXXXXX") || CF=
    [ -n "$CF" ] && printf '%s' "Deployed $SHA for this hotfix, and the migration SQL is applied. $WHERE (deploy verified $(STAMP))." > "$CF"
    if [ -n "$CF" ] && command -v gh_rest_comment >/dev/null 2>&1 && gh_rest_comment "$SLUG" "$ISSUE" "$CF"; then
      gh_rest_close "$SLUG" "$ISSUE" || {
        echo "hotfix-after-deploy: commented on issue $ISSUE but could not close it" >&2
        CLOSEOUT_ALERT "the deployed comment is on issue $ISSUE but the close failed; close issue $ISSUE by hand"; }
    else
      echo "hotfix-after-deploy: could not comment on issue $ISSUE, so it stays open" >&2
      CLOSEOUT_ALERT "the SQL is applied but issue $ISSUE took no deployed comment; comment and close issue $ISSUE by hand"
    fi
    [ -n "$CF" ] && rm -f "$CF"
  elif [ -z "$STATE" ]; then
    echo "hotfix-after-deploy: could not read the state of issue $ISSUE, so it was not closed" >&2
    CLOSEOUT_ALERT "the SQL is applied but the state of issue $ISSUE was unreadable; close issue $ISSUE by hand"
  fi
fi
command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset
exit 0
