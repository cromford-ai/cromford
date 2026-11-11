#!/bin/bash
# Owner: BH-9417.2 (full event coverage). Sourced by bin/lib/gh-cache.sh.
# bin/lib/gh-cache-scope.sh — the scope seam of the gh shim cache: which tag an
# endpoint's entry carries, and which entries a wake (or a write on this box)
# drops. The defaults here are the BH-8066 rules; gh-cache.sh defines the same
# bodies inline, so a box without this file behaves the same.
# No `set -e`, no `exit`, no side effect at source time.
if [ -n "${GH_CACHE_SCOPE_LIB:-}" ]; then return 0 2>/dev/null; fi
GH_CACHE_SCOPE_LIB=1

# ghc_scope_tag <bare endpoint> — prints a tag (`<repo>~<obj>`) to use instead
# of ghc_tag's own, or nothing for "use the default tag". The default prints
# nothing.
ghc_scope_tag() { return 0; }

# ghc_wake_drop <dir> <repo_tag> <kind> <key> — drop what a wake (or a write) of
# <kind> for <key> on <repo_tag> makes stale: the repo's list entries
# (<repo>~r~*), plus n-<N> for a number key or s-<sha12> for a hex key. The
# default ignores <kind>.
ghc_wake_drop() {
  local dir="${1:-}" repo="${2:-}" key
  [ -n "$dir" ] && [ -n "$repo" ] || return 0
  ghc_drop "$dir/$repo~r~*"
  key=$(printf '%s' "${4:-}" | tr 'A-Z' 'a-z')
  if [[ "$key" =~ ^[0-9]{1,9}$ ]]; then ghc_drop "$dir/$repo~n-$((10#$key))~*"
  elif [[ "$key" =~ ^[0-9a-f]{7,64}$ ]]; then ghc_drop "$dir/$repo~s-${key:0:12}~*"
  fi
  return 0
}
