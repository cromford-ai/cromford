#!/bin/bash
# deploy-verify.sh <project> <repo-slug> <merge-sha> <build-dir> — post-merge prod gate.
# Runs DETACHED after a tier-1 auto-merge (never holds a build slot): polls the
# GitHub "Production" deployment Vercel creates for the merge commit until it
# succeeds or fails (timeout 20 min), then smoke-curls the prod domain. Any
# failure -> ALERTS.log + fleet_alert beat (Telegram). Success -> one log line,
# and then bin/hotfix-after-deploy.sh for a build whose hotfix SQL was deferred to
# the deploy (BH-370.4) — hooked after the OK line, never able to change the verdict.
set -uo pipefail
PROJECT="${1:?project}"; SLUG="${2:?slug}"; SHA="${3:?sha}"; BUILD="${4:?build-dir}"
HARNESS="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$HARNESS")
ALERTS="$HARNESS/logs/ALERTS.log"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
set -a; . "$HENV/global.env" 2>/dev/null; [ -f "$HENV/$PROJECT.env" ] && . "$HENV/$PROJECT.env"; set +a
# BH-3387: does this project have a GitHub production deployment at all? The
# deploy.<project>.kind row answers before any gh call (the branch is below
# SMOKE_ONLY). No row, an outage or an unknown value keeps the poll.
# shellcheck source=bin/lib/deploy-kind.sh
. "$HARNESS/bin/lib/deploy-kind.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/deploy-kind.sh" 2>/dev/null || deploy_kind() { return 2; }
KIND=$(deploy_kind "$PROJECT")
# BH-6786: the smoke probe is a browser page load (Clerk 404s anything else) on
# <prod><deploy.<project>.smoke_path>. The fallback keeps the bare curl on the
# bare URL, so a half-synced box still smokes.
# shellcheck source=bin/lib/smoke-probe.sh
. "$HARNESS/bin/lib/smoke-probe.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/smoke-probe.sh" 2>/dev/null || {
  smoke_url() { printf '%s\n' "$2"; }
  smoke_code() { curl -s -o /dev/null -w '%{http_code}' -m 30 -L "$1"; }
}
if [ "$KIND" = none ]; then
  echo "$(STAMP) [$PROJECT] deploy-verify SKIP: $PROJECT has no GitHub production deployment (deploy.kind=none)" >> "$BUILD/pipeline.log"
  if [ -s "$BUILD/hotfix-migrate.json" ]; then
    echo "$(STAMP) [$PROJECT] post-deploy apply not run for ${SHA:0:8}: deploy.kind=none, the */15 tick will apply the deferred SQL" >> "$BUILD/pipeline.log"
  fi
  "$HARNESS/bin/deploy-kind-resolve.sh" "$PROJECT" >/dev/null 2>&1 || true
  exit 0
fi

FAIL() {
  echo "$(STAMP) [$PROJECT] DEPLOY-VERIFY FAILED ($SHA): $1 (build $(basename "$BUILD"))" >> "$ALERTS"
  "$HARNESS/bin/beat.sh" "$(jq -nc --arg p "$PROJECT" --arg akey "deployfail:$PROJECT:$SHA" \
    --arg l "PROD DEPLOY problem after auto-merge: $1 (commit ${SHA:0:8})" \
    '{kind:"fleet_alert",project:$p,akey:$akey,line:$l}')"
  exit 1
}

# READABLE <api-output> <rc> — can this box observe deployments on this repo AT
# ALL? Not only the "Resource not accessible" string the project-3 PAT answered: a
# 404 (the repo is invisible to the token) and a 403 (the scope is missing) are
# the same fact, and treating either as "no deployment yet" is what turned an
# unreadable API into a 20-minute false FAIL.
READABLE() {
  [ "$2" = 0 ] || return 1
  case "$1" in
    *"Resource not accessible"*|*"Not Found"*|*"Must have push access"*|*"HTTP 40"*) return 1 ;;
  esac
  return 0
}

# SMOKE_ONLY <why> <fire-hook 0|1> — the whole verification, honestly labeled.
# The deployments API cannot answer (or deploy.kind=smoke-only says there is no
# deployment to poll), so the evidence is the prod domain itself.
SMOKE_ONLY() {
  # A declared kind (BH-3387) is not an unreadable API: say which it is.
  local lead="deployments unreadable for $SLUG" why="deployments unreadable" api="deployments API unreadable"
  case "$1" in deploy.kind=*) lead="deployments not polled for $SLUG"; why="$1"; api="$1" ;; esac
  echo "$(STAMP) [$PROJECT] $lead: smoke-only ($1)" >> "$BUILD/pipeline.log"
  if [ "$2" = 1 ]; then
    [ -n "${DEPLOY_HOOK_URL:-}" ] && curl -s -m 20 -X POST "$DEPLOY_HOOK_URL" -o /dev/null || true
    sleep "${DEPLOY_HOOK_WAIT:-420}"   # give the hook build time
  fi
  PROD=$("$HARNESS/bin/prod-url.sh" "$PROJECT") || exit 0
  PROD=$(smoke_url "$PROJECT" "$PROD"); CODE=$(smoke_code "$PROD")
  case "$CODE" in
    2*|3*|404)
      echo "$(STAMP) [$PROJECT] deploy-verify (smoke-only: $1): prod answers $CODE for ${SHA:0:8}" >> "$BUILD/pipeline.log"
      # The post-deploy apply (bin/hotfix-after-deploy.sh) only runs from the
      # deployments-read path below. A deferred hotfix ledger here waits on the
      # */15 tick and its issue stays open, and the pre-merge proof promised the
      # post-deploy step would pick it up: say so where the trail is read.
      if [ -s "$BUILD/hotfix-migrate.json" ]; then
        echo "$(STAMP) [$PROJECT] post-deploy apply not run for ${SHA:0:8}: $why, the */15 tick will apply the deferred SQL and the issue stays open" >> "$BUILD/pipeline.log"
      fi ;;
    *) FAIL "prod smoke check $PROD returned HTTP $CODE ($api — verify by smoke only)" ;;
  esac
  exit 0
}

# A declared smoke-only project has no deployment to poll: the smoke curl is the
# whole verification, and no hook (the hook is the Vercel recovery path).
[ "$KIND" = smoke-only ] && SMOKE_ONLY "deploy.kind=smoke-only" 0

# WHICH TOKEN CAN SEE THIS REPO (#301). The hub's default PAT 404s on
# example-org/project-5, so every project-5 merge alerted "no successful
# production deployment within 20 min" while CI and "Deploy Worker to Railway"
# had both gone green — a page about a token, dressed as a page about a deploy.
# shellcheck source=bin/lib/gh-repo-token.sh
[ -r "$HARNESS/bin/lib/gh-repo-token.sh" ] && . "$HARNESS/bin/lib/gh-repo-token.sh"
# shellcheck source=bin/lib/gh-app-auth.sh
[ -r "$HARNESS/bin/lib/gh-app-auth.sh" ] && . "$HARNESS/bin/lib/gh-app-auth.sh"
command -v gh_repo_use_token >/dev/null 2>&1 && { gh_repo_use_token "$SLUG" \
  || gh_repo_invisible_alert deploy-verify "$SLUG" "the deploy of ${SHA:0:8} is verified by prod smoke only"; }

STATE=""
HOOK_FIRED=0
HOOK_TS=""
# Worker PATs may lack the Deployments:read permission — the API 403s and this
# gate can NEVER observe success (project-3 false-FAIL, 2026-07-28). Detect that and
# fall back to hook + prod smoke as the whole verification.
# #425: spend this repo's App installation token, not the fleet PAT, for every gh call below.
command -v gh_auth_for >/dev/null 2>&1 && gh_auth_for "$SLUG" || true
PROBE=$(gh api "repos/$SLUG/deployments?per_page=1" 2>&1); PRC=$?
READABLE "$PROBE" "$PRC" || SMOKE_ONLY "PAT cannot read deployments" 1
END=$((SECONDS + 1200))
SEEN_READ=0
while [ "$SECONDS" -lt "$END" ]; do
  RAW=$(gh api "repos/$SLUG/deployments?sha=$SHA&per_page=10" 2>&1); RRC=$?
  if READABLE "$RAW" "$RRC"; then
    SEEN_READ=1
    DID=$(printf '%s' "$RAW" | jq -r '[.[] | select(.environment | test("production"; "i"))][0].id // empty' 2>/dev/null)
  else
    DID=""
  fi
  # Recovery (2026-07-27): some projects never auto-deploy certain merges (project-3
  # only deploys operator-authored commits — TK-19 served stale 3 days). If no
  # production deployment even EXISTS after 5 min and this project has a deploy
  # hook, fire it once and then accept the newest post-hook production deploy
  # (the hook builds current main, which contains our merge).
  if [ -z "$DID" ] && [ "$HOOK_FIRED" = 0 ] && [ -n "${DEPLOY_HOOK_URL:-}" ] && [ "$SECONDS" -gt 300 ]; then
    curl -s -m 20 -X POST "$DEPLOY_HOOK_URL" -o /dev/null || true
    HOOK_FIRED=1; HOOK_TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    echo "$(STAMP) [$PROJECT] no production deployment for ${SHA:0:8} after 5 min — fired deploy hook" >> "$BUILD/pipeline.log"
  fi
  if [ -z "$DID" ] && [ "$HOOK_FIRED" = 1 ]; then
    DID=$(gh api "repos/$SLUG/deployments?per_page=10" \
          -q "[.[] | select((.environment | test(\"production\"; \"i\")) and (.created_at > \"$HOOK_TS\"))][0].id" 2>/dev/null)
  fi
  if [ -n "$DID" ]; then
    STATE=$(gh api "repos/$SLUG/deployments/$DID/statuses?per_page=20" \
            -q '[.[] | select(.state == "success" or .state == "failure" or .state == "error")][0].state // empty' 2>/dev/null)
    [ "$STATE" = "success" ] && break
    [ -n "$STATE" ] && FAIL "Vercel production deployment state=$STATE"
  fi
  sleep 30
done
# A repo whose deployments went unreadable mid-poll (the token lost the repo, the
# API 403s now) never had a deployment to see. That is not a failed deploy, and
# alerting it as one is the project-5 shape: a page nobody can act on.
[ "$STATE" = "success" ] || [ "$SEEN_READ" = 1 ] || SMOKE_ONLY "deployments API stopped answering during the poll" 0
[ "$STATE" = "success" ] || FAIL "no successful production deployment within 20 min"

PROD=$("$HARNESS/bin/prod-url.sh" "$PROJECT") || exit 0
PROD=$(smoke_url "$PROJECT" "$PROD"); CODE=$(smoke_code "$PROD")
case "$CODE" in
  2*|3*)
    echo "$(STAMP) [$PROJECT] deploy-verify OK: prod deployed ${SHA:0:8}, $PROD -> $CODE" >> "$BUILD/pipeline.log"
    # BH-370.4: a hotfix that deferred its SQL to the deploy gets applied and
    # closed out HERE, after the OK line, because this is the first moment the
    # merge is genuinely live. `|| true`: our callers (bin/deploy-request.sh:22,27)
    # read this script's exit code as the deploy verdict, and a failed post-deploy
    # apply alerts on its own rather than masking it.
    [ -s "$BUILD/hotfix-migrate.json" ] && [ -x "$HARNESS/bin/hotfix-after-deploy.sh" ] \
      && "$HARNESS/bin/hotfix-after-deploy.sh" "$PROJECT" "$BUILD" "$SHA" >> "$BUILD/pipeline.log" 2>&1
    # BH-3690: does the deployment we just saw succeed serve the merge? In the
    # hook-recovery path it is "the newest post-hook deploy", whatever commit
    # that is. The contract always exits 0, so this verdict cannot change.
    if [ -x "$HARNESS/bin/post-merge-verify.sh" ]; then
      SERVED=$(gh api "repos/$SLUG/deployments/$DID" -q '.sha // empty' 2>/dev/null)
      timeout 120 "$HARNESS/bin/post-merge-verify.sh" "$PROJECT" --target app --merged "$SHA" --served "$SERVED" \
        --slug "$SLUG" --log "$BUILD/pipeline.log" >/dev/null 2>&1
    fi
    true ;;
  *) FAIL "prod smoke check $PROD returned HTTP $CODE" ;;
esac
command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset
exit 0
