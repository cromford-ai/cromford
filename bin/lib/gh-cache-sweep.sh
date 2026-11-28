#!/bin/bash
# Owner: BH-9417.3 (missed-webhook sweep). Sourced by bin/lib/gh-cache.sh.
# bin/lib/gh-cache-sweep.sh — the sweep seam of the gh shim cache. ghc_main asks
# it whether a sweep re-validated an entry that is older than
# GH_CACHE_EVENT_MAX_S (an n-<N> entry), or older than GH_CACHE_TTL_S (a repo
# list or search entry, tag <repo>~r). gh-cache.sh defines an inline default
# that always answers rc 1.
# No `set -e`, no `exit`, no side effect at source time.
if [ -n "${GH_CACHE_SWEEP_LIB:-}" ]; then return 0 2>/dev/null; fi
GH_CACHE_SWEEP_LIB=1

# ghc_sweep_covers <dir> <tag> <fetched_epoch> — rc 0 only when ALL hold:
#   - the tag is <repo>~n-<N> or <repo>~r, and <repo> is owner__name (not `_`);
#   - <dir>/../gh-cache-sweep/<repo>.stamp is
#     `v3 <start> <chain> <period> <base> <end> <trust>`, written by
#     bin/gh-cache-sweep.sh after a complete, clean read (<trust> is the knob
#     GH_CACHE_SWEEP_TRUST_PERIODS the sweep used, so this seam reads no knob);
#   - fetched >= chain (the sweep record already held the state at fetch time);
#   - fetched > base, the time the previous sweep of the chain finished its
#     reads and drops (the record this sweep compared with was read before the
#     fetch, so a change after the fetch is a difference this sweep saw; a fetch
#     made while that sweep was still reading, or stored after its drop, is not
#     vouched for);
#   - start > fetched (a sweep read GitHub after the fetch and found no change);
#   - 0 <= now - start < trust * period (the sweep is fresh);
#   - for an r tag: fetched > each of <dir>/.rdrop.<repo> and <dir>/.rdrop._all
#     (the time ghc_drop last dropped the repo lists; a missing file is 0).
# Any other case is rc 1. An s-<sha12> entry is never covered: a commit status
# or check run changes with no change to a PR's updated_at or head, so the
# sweep cannot see it. The bare PR read is never covered either: when
# GHC_LPATH (set by ghc_main to the request's bare path) is
# repos/<o>/<r>/pulls/<N> (any query string), rc 1. Its mergeable and
# mergeable_state change with no updated_at or head change (a merge to main),
# so it keeps the GH_CACHE_EVENT_MAX_S bound (lead review of #9597, BLOCK 1). now is ghc_now (GH_CACHE_NOW is the test clock).
ghc_sweep_covers() {
  local dir="${1:-}" tag="${2:-}" fetched="${3:-}" repo obj v="" s="" c="" p="" b="" e="" k="" x="" now d f
  [ -n "$dir" ] || return 1
  [[ "$fetched" =~ ^[0-9]{1,12}$ ]] || return 1
  repo="${tag%%~*}"; obj="${tag#*~}"
  [ "$tag" = "$repo~$obj" ] || return 1
  [[ "$repo" =~ ^[a-z0-9._-]+__[a-z0-9._-]+$ ]] || return 1
  [[ "$obj" =~ ^(r|n-[0-9]+)$ ]] || return 1
  [[ "${GHC_LPATH:-}" =~ ^repos/[^/]+/[^/]+/pulls/[0-9]+(\?.*)?$ ]] && return 1
  f="${dir%/}"; f="${f%/*}/gh-cache-sweep/$repo.stamp"
  [ -r "$f" ] || return 1
  read -r v s c p b e k x < "$f" 2>/dev/null   # the fields are checked below
  [ "$v" = v3 ] && [ -z "$x" ] || return 1
  [[ "$s" =~ ^[0-9]{1,12}$ ]] && [[ "$c" =~ ^[0-9]{1,12}$ ]] && [[ "$p" =~ ^[0-9]{1,9}$ ]] || return 1
  [[ "$b" =~ ^[0-9]{1,12}$ ]] && [[ "$e" =~ ^[0-9]{1,12}$ ]] && [[ "$k" =~ ^[0-9]{1,3}$ ]] || return 1
  s=$((10#$s)); c=$((10#$c)); p=$((10#$p)); b=$((10#$b)); k=$((10#$k)); fetched=$((10#$fetched))
  [ "$p" -gt 0 ] && [ "$k" -gt 0 ] || return 1
  now=$(ghc_now 2>/dev/null) || return 1
  [[ "$now" =~ ^[0-9]+$ ]] || return 1
  [ "$fetched" -ge "$c" ] && [ "$fetched" -gt "$b" ] && [ "$s" -gt "$fetched" ] || return 1
  [ $((now - s)) -ge 0 ] && [ $((now - s)) -lt $((k * p)) ] || return 1
  if [ "$obj" = r ]; then
    for f in "${dir%/}/.rdrop.$repo" "${dir%/}/.rdrop._all"; do
      d=0
      [ -r "$f" ] && { d=""; read -r d _ < "$f" 2>/dev/null; }   # an unreadable stamp is not 0
      [[ "$d" =~ ^[0-9]{1,12}$ ]] || return 1
      [ "$fetched" -gt $((10#$d)) ] || return 1
    done
  fi
  return 0
}
