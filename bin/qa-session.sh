#!/bin/bash
# bin/qa-session.sh <project> <role> [ttl-seconds] — print a Clerk session JWT
# for that project's QA account at that role tier. The building block for
# role-matrix authz probes, prod QA passes, and incident ops (born from the
# TK-88 cleanup, where deleting spam needed an admin session minted by hand).
#
# Accounts live in state/qa-accounts.json (per-project role -> {email,user_id})
# and are resolved through bin/qa-account.sh — ONE lookup, so a role that
# resolves here resolves identically in bin/qa-unbanned.sh. Secrets are
# QA_CLERK_SECRET_KEY in env/<project>.env. Use the JWT as
# `Authorization: Bearer <jwt>` against the app. Sessions self-expire; default
# TTL 600s — mint short, mint often.
#
# BANNED ACCOUNTS (updated 2026-08-29, SDLC item 3a). qa-owner/qa-admin/
# qa-administrator tiers are DISABLED at rest inside each app, and app-disable
# also BANS the user in Clerk — so session-create here fails with `user_banned`.
# That error IS the rest state working. What changed is that there is now a
# sanctioned way through it for an authorized drive:
#
#   /root/harness/bin/qa-unbanned.sh <project> <role> -- <command…>
#
# which lifts the ban for the length of <command> and restores it from an EXIT
# trap. Run THIS script inside that window and it mints normally. Minting a JWT
# and then re-banning would be pointless on its own: a ban revokes live
# sessions, so the token would die with the window — which is exactly why the
# unban has to wrap the whole drive rather than just the mint.
#
# This script never unbans anything itself. It reports the ban plainly and names
# the wrapper, so a caller cannot mistake `user_banned` for a transport failure
# (the misreading that let drives quietly QA the sign-in page for two weeks).
set -euo pipefail
P="${1:?project}"; ROLE="${2:?role}"; TTL="${3:-600}"
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")
SELF="$(cd "$(dirname "$0")" && pwd)"
CLERK_API="${CLERK_API:-https://api.clerk.com}"
SK="${QA_CLERK_SECRET_KEY:-}"
[ -n "$SK" ] || SK=$(grep -E "^QA_CLERK_SECRET_KEY=" "$HENV/$P.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')
[ -n "$SK" ] || { echo "no QA_CLERK_SECRET_KEY for $P" >&2; exit 1; }
UID_=$("$SELF/qa-account.sh" "$P" "$ROLE" user_id) || exit 1

# -sf hid the response BODY, so `user_banned` and "Clerk is down" arrived as the
# same empty string and the same exit code. Capture body and status separately.
RESP=$(curl -sS -m 20 -w '\n%{http_code}' -X POST "$CLERK_API/v1/sessions" \
  -H "Authorization: Bearer $SK" -H "Content-Type: application/json" \
  -d "{\"user_id\":\"$UID_\"}" 2>/dev/null) || RESP=$'\n000'
CODE="${RESP##*$'\n'}"; BODY="${RESP%$'\n'*}"
if [ "${CODE:0:1}" != 2 ]; then
  if grep -q 'user_banned' <<<"$BODY"; then
    echo "$P/$ROLE is BANNED in Clerk — that is the rest state, not an outage." >&2
    echo "Drive it through: $SELF/qa-unbanned.sh $P $ROLE -- <command…>" >&2
    exit 3
  fi
  echo "clerk session-create HTTP ${CODE:-none} for $P/$ROLE" >&2
  exit 1
fi
SID=$(printf '%s' "$BODY" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])') || {
  echo "clerk session-create returned no session id for $P/$ROLE" >&2; exit 1; }
curl -sf -m 20 -X POST "$CLERK_API/v1/sessions/$SID/tokens" \
  -H "Authorization: Bearer $SK" -H "Content-Type: application/json" \
  -d "{\"expires_in_seconds\":$TTL}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["jwt"])'
