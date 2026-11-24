#!/bin/bash
# guardrails/verification-map-freshness/check.sh [<base-ref>]
#
# Colocation-as-CI. A PR that changes what the app DOES must change the map that
# says how to reach and drive it, in the same diff — "without enforcement, the
# principle decays in months". This is the mechanical half of the verification
# map (Wave B): the map lives in the target repo at docs/verification-map/, the
# PR that changes a route updates it, and this check is what makes that true
# rather than aspirational.
#
# Built generically NOW, ahead of the map itself, so Wave B has a working
# freshness gate on day one instead of a TODO. On a repo with no
# docs/verification-map/ yet it reports "not adopted" and exits 0 — a check that
# failed every PR in every unmigrated repo would be turned off before the map
# ever landed.
#
# Configuration (env, so a repo tunes it without forking the script):
#   VMAP_ROUTE_GLOBS  space-separated shell globs for "this changes behavior"
#                     (default: src/app/* app/* pages/* src/pages/*)
#   VMAP_MAP_PREFIX   path prefix the map lives under
#                     (default: docs/verification-map/)
#   VMAP_FILES        a file containing the changed-file list, one per line.
#                     Set this and no git call is made — that is how the check
#                     is testable on fixtures, and how a CI that already has the
#                     list avoids a second diff.
#
# rc 0 = fresh / not adopted / skipped. rc 1 = routes changed, map did not.
set -uo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/escape-hatch.sh
. "$SELF/../lib/escape-hatch.sh" 2>/dev/null || true
declare -F guardrail_escape_hatch >/dev/null \
  && guardrail_escape_hatch verification-map-freshness && exit 0

ROUTE_GLOBS="${VMAP_ROUTE_GLOBS:-src/app/* app/* pages/* src/pages/*}"
MAP_PREFIX="${VMAP_MAP_PREFIX:-docs/verification-map/}"
BASE="${1:-origin/main}"

# Adoption is a fact about the CHECKOUT, never about this diff: reading it off
# the changed-file list would mean a PR that deletes the map reports "not
# adopted" and passes — the exact PR this check exists to stop.
if [ ! -d "${MAP_PREFIX%/}" ]; then
  echo "GUARDRAIL verification-map-freshness: no ${MAP_PREFIX} in this checkout yet — not adopted, nothing to keep fresh."
  exit 0
fi

if [ -n "${VMAP_FILES:-}" ]; then
  [ -f "$VMAP_FILES" ] || { echo "GUARDRAIL verification-map-freshness: VMAP_FILES=$VMAP_FILES not readable — not checked."; exit 0; }
  CHANGED=$(cat "$VMAP_FILES")
else
  CHANGED=$(git diff --name-only "$BASE"...HEAD 2>/dev/null) || {
    echo "GUARDRAIL verification-map-freshness: could not diff against $BASE — not checked."
    exit 0
  }
fi

ROUTES_TOUCHED=""
MAP_TOUCHED=""
while IFS= read -r F; do
  [ -n "$F" ] || continue
  case "$F" in "$MAP_PREFIX"*) MAP_TOUCHED="yes"; continue ;; esac
  # Route side only: on a Mergify batch draft a route file only a hatched source
  # PR changed is exempt (BH-9965). A map edit always counts.
  declare -F guardrail_is_exempt >/dev/null && guardrail_is_exempt "$F" && continue
  for G in $ROUTE_GLOBS; do
    # shellcheck disable=SC2254  # $G is a glob on purpose
    case "$F" in $G*) ROUTES_TOUCHED="$ROUTES_TOUCHED$F"$'\n'; break ;; esac
  done
done <<< "$CHANGED"

if [ -z "$ROUTES_TOUCHED" ]; then
  echo "GUARDRAIL verification-map-freshness: no route/screen files in this diff — nothing to keep fresh."
  exit 0
fi
if [ -n "$MAP_TOUCHED" ]; then
  echo "GUARDRAIL verification-map-freshness: routes changed and ${MAP_PREFIX} changed with them. Clean."
  exit 0
fi

echo "GUARDRAIL verification-map-freshness: this diff changes routes/screens but touches nothing under ${MAP_PREFIX}."
printf '%s' "$ROUTES_TOUCHED" | head -20 | sed 's/^/    /'
cat <<EOF

Update the map entry for the feature you changed — what it is, its nav path, key
routes, selectors, preconditions — in this same PR. A map that lags the app is
worse than no map: agents and QA sessions drive it as if it were true.

If this genuinely needs no map change (a pure refactor, a typo), take the
escape hatch: add the 'skip-guardrail' label AND say why in
GUARDRAIL_JUSTIFICATION. The reason stays in the PR record.
EOF
exit 1
