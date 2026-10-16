#!/bin/bash
# bin/verify-claims.sh — mechanical pre-POST check for board comments that
# claim work is live/shipped/fixed/deployed (2026-08-14).
#
# Incident class: bulk "checked against production" claims where nothing had
# been checked, and PR-body/board claims of verification for PRs that never
# merged. A claim a machine can check must be machine-checked BEFORE it is
# posted to a client-facing thread — this script is that check.
#
# usage: verify-claims.sh <project> <comment-html-file>
#   1. Extracts every https URL from the comment.
#   2. Probes each one (with the project's Vercel bypass secret where the env
#      configures one). Verdicts:
#        2xx/3xx            PASS
#        401/403            AUTH-GATED (note, not a failure — the link exists,
#                           the probe just isn't signed in)
#        404 on a fleet.conf app domain
#                           AUTH-GATED — the fail-closed lesson (TK-44/TK-48,
#                           project-2 #212): these apps deliberately answer
#                           404, not 401, to anonymous probes of token-gated
#                           routes, so an app-domain 404 NEVER proves absence
#        404 elsewhere, 5xx, timeout
#                           FAIL
#   3. If the comment text claims live/shipped/deployed/fixed AND names a
#      GitHub PR, verifies via gh that the PR is actually MERGED — a merged
#      claim about an open PR is exactly the lie this gate exists to stop.
# Exit 0 = claim verified, comment may post. Exit 1 = at least one FAIL (or an
# unmerged PR under a live-claim): fix the links or soften the claim; do not
# post. Exit 2 = usage.
set -uo pipefail
PROJECT="${1:?project}"; FILE="${2:?comment-html-file}"
[ -f "$FILE" ] || { echo "verify-claims: no such file $FILE" >&2; exit 2; }
H=/root/harness
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s
' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")
set -a; . "$HENV/global.env" 2>/dev/null; . "$HENV/$PROJECT.env" 2>/dev/null; set +a
# shellcheck source=bin/lib/gh-app-auth.sh
[ -r "$H/bin/lib/gh-app-auth.sh" ] && . "$H/bin/lib/gh-app-auth.sh"   # App token per repo (#425); unarmed box untouched
BYPASS="${VERCEL_AUTOMATION_BYPASS_SECRET:-}"
PROD=$("$H/bin/fleet-conf.sh" "$PROJECT" prod 2>/dev/null || echo "")

# Every fleet prod host — a 404 from ANY of our apps is fail-closed territory,
# not just this project's (comments legitimately cross-link, e.g. to the hub).
APP_HOSTS=$(awk '!/^#/ && NF>=3 && $3 ~ /^https/ {sub("https://","",$3); print $3}' "$H/fleet.conf")

URLS=$(grep -oE 'https://[A-Za-z0-9._~:/?#@!$&()*+,;=%-]+' "$FILE" | sed -E 's/[).,;>"'"'"']+$//' | sort -u)
TEXT=$(sed -E 's/<[^>]+>/ /g' "$FILE")
CLAIMS_LIVE=0
grep -qiE '\b(live|shipped|deployed|fixed)\b' <<<"$TEXT" && CLAIMS_LIVE=1

FAILS=0
if [ -z "$URLS" ]; then
  echo "NOTE: no https URLs in the comment (direct-links rule says there should be some)"
fi
for U in $URLS; do
  HOST=$(echo "$U" | sed -E 's#https://([^/]+).*#\1#')
  case "$U" in
    https://github.com/*/pull/*)
      # PR links are judged by gh below, not by HTTP status.
      continue ;;
  esac
  ARGS=(-s -o /dev/null -w '%{http_code}' -m 20 -H "User-Agent: curl/8")
  # Bypass only rides to this project's own prod host — never third parties.
  if [ -n "$BYPASS" ] && [ "https://$HOST" = "$PROD" ]; then
    ARGS+=(-H "x-vercel-protection-bypass: $BYPASS")
  fi
  CODE=$(curl "${ARGS[@]}" "$U" 2>/dev/null || echo 000)
  case "$CODE" in
    2*|3*) echo "PASS $CODE $U" ;;
    401|403) echo "AUTH-GATED $CODE $U (probe unauthenticated; link presumed live behind sign-in)" ;;
    404)
      if grep -qxF "$HOST" <<<"$APP_HOSTS"; then
        echo "AUTH-GATED 404 $U (fleet app domain — these apps fail CLOSED: token-gated routes answer 404 to anonymous probes, so this does not prove absence)"
      else
        echo "FAIL 404 $U"; FAILS=$((FAILS+1))
      fi ;;
    *) echo "FAIL $CODE $U"; FAILS=$((FAILS+1)) ;;
  esac
done

# Live-claim + named PR → the PR must be MERGED, per gh, not per memory.
if [ "$CLAIMS_LIVE" = 1 ]; then
  for PRURL in $(echo "$URLS" | grep -E '^https://github.com/[^/]+/[^/]+/pull/[0-9]+' || true); do
    command -v gh_auth_for_url >/dev/null 2>&1 && gh_auth_for_url "$PRURL" || true
    ST=$(gh pr view "$PRURL" --json state -q .state 2>/dev/null || echo UNKNOWN)
    if [ "$ST" = "MERGED" ]; then
      echo "PR-MERGED $PRURL"
    else
      echo "FAIL PR $PRURL is $ST — the comment claims live/shipped/fixed but the PR has not merged"
      FAILS=$((FAILS+1))
    fi
  done
fi
command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset

if [ "$FAILS" -gt 0 ]; then
  echo "VERDICT: FAIL ($FAILS) — do not post this comment as written"
  exit 1
fi
echo "VERDICT: PASS"
exit 0
