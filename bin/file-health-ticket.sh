#!/bin/bash
# file-health-ticket.sh <project> <prod-base> <pr-url>
# Files the out-of-band-work record ticket for the /api/health endpoint on this
# project's product board, then closes it (documentation ticket, no client action).
set -uo pipefail
PROJECT="$1"; PROD="$2"; PRURL="$3"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir /root/harness)
set -a; . $HENV/global.env 2>/dev/null; . "$HENV/$PROJECT.env"; set +a
# Token NAME through bin/lib/board-creds.sh, base+prefix through fc_board_base
# (fleet.conf's board prefix, never a hardcoded board path) — BH-1955. Either
# one unresolved is a FAIL with no board call; the resolver writes the ALERTS line
# (board_base_var runs first so a base with no match or two gets one too).
# The entry point owns the root default (BH-2613.4): bin/lib/file-children.sh reads
# HARNESS, then H, and has no literal of its own.
H="${HARNESS:-/root/harness}"
LIB="$(dirname "${BASH_SOURCE[0]}")/lib"
# shellcheck source=bin/lib/file-children.sh
. "$LIB/file-children.sh" 2>/dev/null || { echo "FAIL: $LIB/file-children.sh is missing or unreadable"; exit 1; }
# shellcheck source=bin/lib/board-creds.sh
. "$LIB/board-creds.sh" 2>/dev/null || { echo "FAIL: $LIB/board-creds.sh is missing or unreadable"; exit 1; }
TOKEN_VAR=$(board_token_var "$PROJECT" "$HENV/$PROJECT.env" file-health-ticket) \
  || { echo "FAIL: could not resolve one *_INTERNAL_API_TOKEN from $HENV/$PROJECT.env (see ALERTS.log)"; exit 1; }
TOKEN="${!TOKEN_VAR:-}"
[ -n "$TOKEN" ] || { echo "FAIL: $TOKEN_VAR is empty in $HENV/$PROJECT.env"; exit 1; }
board_base_var "$PROJECT" "$HENV/$PROJECT.env" file-health-ticket >/dev/null \
  || { echo "FAIL: could not resolve one *_API_BASE / *_APP_BASE from $HENV/$PROJECT.env (see ALERTS.log)"; exit 1; }
BASE=$(fc_board_base "$PROJECT") \
  || { echo "FAIL: no board base for $PROJECT (fleet.conf board prefix / *_API_BASE / *_APP_BASE)"; exit 1; }
CURL() { curl -s --max-time 25 -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -H "User-Agent: curl/8" "$@"; }

BOARDS=$(CURL "$BASE/boards")
BOARD=$(echo "$BOARDS" | jq -r '(.boards // .)[0].id // empty')
[ -n "$BOARD" ] || { echo "FAIL: no board id in: $(head -c 200 <<<"$BOARDS")"; exit 1; }

DESC="<p>We added an automatic health monitor to the app: <a href=\"$PROD/api/health\">$PROD/api/health</a>.</p><p>Our monitoring fleet now checks it twice a day. It verifies 2 things: the database answers, and the AI connection actually works (a real test call, not just a key check). If the AI provider key stops working or runs out of credits, we get an alert within 12 hours instead of finding out from a broken feature days later.</p><p>Shipped today in $PRURL. Filed here for the record. Nothing is needed from your side.</p>"
PAYLOAD=$(jq -nc --arg t "Automatic health monitoring for the app (/api/health)" --arg d "$DESC" '{title:$t, description:$d, priority:"low"}')
CREATED=$(CURL -X POST -d "$PAYLOAD" "$BASE/boards/$BOARD/tickets")
TID=$(echo "$CREATED" | jq -r '.ticket.id // .id // empty')
TKEY=$(echo "$CREATED" | jq -r '.ticket.key // .key // "?"')
[ -n "$TID" ] || { echo "FAIL: create: $(head -c 300 <<<"$CREATED")"; exit 1; }

MOVED=$(CURL -X POST -d '{"toStatus":"done","sortOrder":999999}' "$BASE/tickets/$TID/move")
echo "OK $PROJECT ticket $TKEY (id $TID) filed+closed: $(head -c 120 <<<"$MOVED")"
