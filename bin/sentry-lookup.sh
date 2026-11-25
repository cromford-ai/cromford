#!/bin/bash
# bin/sentry-lookup.sh "<search terms>" [project-slug] — deterministic Sentry
# issue lookup for the alert-triage/medic lanes (the operator 2026-08-21).
#
# Why: the project-4 board 500s generated fleet alerts for DAYS while 227 Sentry
# events held the exact root cause (and 2,583 more sat unconnected on
# /accounting/bank). Any alert about a 500/timeout/error on an owned app should
# check Sentry FIRST — a curl, not a theory.
#
# Auth: SENTRY_API_TOKEN in env (a read-only user auth token with issue:read /
# event:read / org:read on org operator — env/global.env on each box).
# No token or any API failure prints a one-line notice and exits 0 — callers
# treat Sentry as advisory evidence, never a hard dependency.
#
# Per-project source (BH-9799): when [project-slug] is a fleet project with a
# `sentry` block in catalog/signal-sources.d/<project>.json
# (bin/lib/signal-source.sh), the lookup uses that row's org, Sentry project
# slug and token (the env name the row gives, from the environment or parsed
# from env/<project>.env). A slug with no row keeps SENTRY_ORG and
# SENTRY_API_TOKEN. Its own notices, each one line and exit 0:
#   (sentry lookup unavailable — <TOKEN_ENV> unset for <project>)
#   (sentry lookup unavailable — bad signal source row for <project>)
# Every output line goes through token_redact (bin/lib/token-redact.sh).
#
# Output: up to 8 matching unresolved issues, one line each:
#   <shortId>  events=<count>  last=<lastSeen>  <title>  <permalink>
set -uo pipefail
Q="${1:?usage: sentry-lookup.sh \"<search terms>\" [project-slug]}"
PROJ="${2:-}"
ORG="${SENTRY_ORG:-operator}"
TOKEN="${SENTRY_API_TOKEN:-}"
SELF="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/lib/token-redact.sh
. "$SELF/lib/token-redact.sh" || { echo "(sentry lookup unavailable — bin/lib/token-redact.sh missing)"; exit 0; }
# shellcheck source=bin/lib/signal-source.sh
. "$SELF/lib/signal-source.sh" || { echo "(sentry lookup unavailable — bin/lib/signal-source.sh missing)"; exit 0; }

if [ -n "$PROJ" ]; then
  src=0; ss_sentry "$PROJ" || src=$?
  case "$src" in
    0)
      if [ -z "$SS_TOKEN" ]; then
        echo "(sentry lookup unavailable — $SS_TOKEN_ENV unset for $PROJ)"; exit 0
      fi
      ORG=$SS_ORG; TOKEN=$SS_TOKEN; PROJ=$SS_SLUG ;;
    1) echo "(sentry lookup unavailable — bad signal source row for $PROJ)"; exit 0 ;;
  esac
fi

if [ -z "$TOKEN" ]; then
  echo "(sentry lookup unavailable — SENTRY_API_TOKEN unset)"
  exit 0
fi

URL="https://sentry.io/api/0/organizations/$ORG/issues/?query=$(python3 - "$Q" <<'PYEOF'
import sys, urllib.parse
print(urllib.parse.quote(f"is:unresolved {sys.argv[1]}"))
PYEOF
)&limit=8&sort=freq&statsPeriod=14d"
[ -n "$PROJ" ] && URL="$URL&project=$PROJ"

T=$(mktemp)
trap 'rm -f "$T"' EXIT
curl -sS -m 25 -H "Authorization: Bearer $TOKEN" -o "$T" "$URL" || {
  echo "(sentry lookup failed: curl error)"; exit 0; }

{ python3 - "$T" <<'PYEOF' || echo "(sentry lookup: parse error)"
import json, sys
try:
    issues = json.load(open(sys.argv[1]))
except Exception:
    print("(sentry lookup: unparseable response)"); raise SystemExit
if not isinstance(issues, list):
    print(f"(sentry lookup: {str(issues)[:120]})"); raise SystemExit
if not issues:
    print("(sentry: no unresolved issues match)")
for i in issues[:8]:
    sid = i.get("shortId", "?")
    cnt = i.get("count", "?")
    seen = i.get("lastSeen", "?")
    title = (i.get("title") or "")[:100]
    link = i.get("permalink", "")
    print(f"{sid}  events={cnt}  last={seen}  {title}  {link}")
PYEOF
} | token_redact
exit 0
