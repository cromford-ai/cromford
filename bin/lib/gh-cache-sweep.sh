#!/bin/bash
# Owner: BH-9417.3 (missed-webhook sweep). Sourced by bin/lib/gh-cache.sh.
# bin/lib/gh-cache-sweep.sh — the sweep seam of the gh shim cache. ghc_main asks
# it whether a sweep re-validated an entry that is older than
# GH_CACHE_EVENT_MAX_S. gh-cache.sh defines the same default inline.
# No `set -e`, no `exit`, no side effect at source time.
if [ -n "${GH_CACHE_SWEEP_LIB:-}" ]; then return 0 2>/dev/null; fi
GH_CACHE_SWEEP_LIB=1

# ghc_sweep_covers <dir> <tag> <fetched_epoch> — rc 0 when a sweep checked the
# object after <fetched_epoch>, so the entry may be served. The default is rc 1:
# no sweep coverage.
ghc_sweep_covers() { return 1; }
