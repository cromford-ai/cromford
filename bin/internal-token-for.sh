#!/bin/bash
# internal-token-for.sh <project> — that project's internal board API token,
# read from env/<project>.env. Prints it and exits 0 only when the file defines
# EXACTLY ONE *_INTERNAL_API_TOKEN; otherwise prints nothing, writes one ALERTS
# line naming the FILE and the variables, and exits 1.
#
# WHY NOT A NAME TABLE. The variable name differs per project and is not
# derivable from the project name — project-2 calls it PROJECT_2_INTERNAL_API_TOKEN
# and project-8 calls it PROJECT_8_INTERNAL_API_TOKEN — and fleet.conf has no
# column for it. A per-project map of those names is exactly the hardcoded
# project list tests/fleet-projects-not-hardcoded-test.sh exists to forbid, and
# the map that used to live in stale-owed-tickets.sh had drifted: it named
# PROJECT_2_INTERNAL_API_TOKEN, which is not what that env file calls it. So the
# SUFFIX is the contract and the file is the source. The honest long-term fix is
# a token_var column in fleet.conf; until then, this.
#
# WHY NOT `head -1`. Matching the first line is correct on every env file that
# has one token and silently wrong on the day one has two: the sweep would
# authenticate with whichever happened to be first — a rotated-but-not-deleted
# stale token, say — take a 401, and log "board list failed". A credential bug
# wearing an outage's clothes is worse than a skipped project that says so.
# Values are never logged, only variable NAMES.
#
# The pattern itself is defined once, in bin/lib/internal-token.sh (BH-1953).
set -uo pipefail
P="${1:?project}"
HERE="$(cd "$(dirname "$0")" && pwd)"
HR="${HARNESS:-$(cd "$HERE/.." && pwd)}"
ENVF="$HR/env/$P.env"
say() { # say <reason>
  local FLAG="$HR/flags/alerted-token-$P-$(date -u +%Y%m%d)"
  [ -f "$FLAG" ] && return
  mkdir -p "$HR/flags" "$HR/logs" 2>/dev/null; touch "$FLAG" 2>/dev/null
  echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [internal-token] $P: $1 — this project is SKIPPED by every board sweep until it is fixed." >> "$HR/logs/ALERTS.log"
}
[ -r "$ENVF" ] || { say "env/$P.env is missing or unreadable"; exit 1; }
# Resolved from the script's REAL path so a symlinked copy still finds it.
. "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")/lib/internal-token.sh" 2>/dev/null \
  || { say "bin/lib/internal-token.sh is missing or unreadable"; exit 1; }
NAME=$(internal_token_var "$ENVF"); RC=$?
if [ "$RC" -eq 1 ]; then
  say "env/$P.env defines no *_INTERNAL_API_TOKEN"
  exit 1
fi
if [ "$RC" -ne 0 ]; then
  NAMES=$(internal_token_vars "$ENVF" || true)
  N=$(printf '%s' "$NAMES" | grep -c . || true)
  say "env/$P.env defines $N tokens ($(printf '%s' "$NAMES" | paste -sd', ' -)) — refusing to guess which one is live"
  exit 1
fi
sed -E 's/^[[:space:]]*export[[:space:]]+//' "$ENVF" \
  | grep -E "^${NAME}=" \
  | head -1 | sed -E 's/^[^=]*=//; s/^"(.*)"$/\1/; s/^'"'"'(.*)'"'"'$/\1/'
