#!/bin/bash
# Owner: BH-9417.4 (eligible paths). Sourced by bin/lib/gh-cache.sh.
# bin/lib/gh-cache-eligible.sh — the path seam of the gh shim cache: which bare
# endpoints ghc_eligible may serve from the cache. The default is the BH-8066
# refusal list; gh-cache.sh defines the same body inline.
# No `set -e`, no `exit`, no side effect at source time.
if [ -n "${GH_CACHE_ELIGIBLE_LIB:-}" ]; then return 0 2>/dev/null; fi
GH_CACHE_ELIGIBLE_LIB=1

# ghc_path_ok <bare path> — rc 1 for a path the cache must never serve: graphql,
# rate_limit, an artifact zip, a job log, an installation token. rc 0 otherwise.
ghc_path_ok() {
  case "${1%%\?*}" in
    graphql|rate_limit) return 1 ;;
    *actions/artifacts/*/zip*|*actions/jobs/*/logs*|*installation/token*) return 1 ;;
  esac
  return 0
}
