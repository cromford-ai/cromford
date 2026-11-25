#!/bin/bash
# tests/gh-budget-empty-cache.bh-10071-test.sh — BH-10071. A gh-budget cache
# file that is empty or holds no numeric fetched_at is NOT a valid cache, and
# reading it never makes a shell arithmetic error.
#
# WHY. A failed rate-limit read leaves an empty cache file
# (gh_budget_refresh). `_ghb_cache_valid` then ran
# `$(( now - $(jq ... file) ))` with an empty value: "syntax error: operand
# expected". Inside `RAW=$(br_candidates)` that error ended the subshell, the
# blocked-resolver tick lost every candidate row, and
# tests/resolver-human-step.bh-6536-test.sh went red on main (R5, R6).
#
#   bash tests/gh-budget-empty-cache.bh-10071-test.sh      exit 0 = pass
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# The library reads GH_BUDGET_TTL_S when it is sourced.
export GH_BUDGET_TTL_S=60
# shellcheck source=bin/lib/gh-budget.sh
. "$DIR/bin/lib/gh-budget.sh" >/dev/null 2>&1 || { echo "FAIL: cannot source bin/lib/gh-budget.sh"; exit 1; }
[ "${_GHB_TTL:-}" = 60 ] && ok || bad "setup: _GHB_TTL is '${_GHB_TTL:-}', want 60"

C="$T/cache.json"
check() { # check <label> <want rc>
  local label="$1" want="$2" rc=0 err
  err=$( { ( _ghb_cache_valid "$C" ); } 2>&1 >/dev/null ) || true
  ( _ghb_cache_valid "$C" ) 2>/dev/null; rc=$?
  [ "$rc" = "$want" ] && ok || bad "$label: rc $rc, want $want"
  [ -z "$err" ] && ok || bad "$label: wrote to stderr: $err"
}

: > "$C";                                   check "E1 an empty cache file" 1
printf 'not json\n' > "$C";                 check "E2 a cache that is not JSON" 1
printf '{"fetched_at":"soon"}\n' > "$C";    check "E3 a fetched_at that is not a number" 1
printf '{"core":1}\n' > "$C";               check "E4 a cache with no fetched_at (0 = long ago)" 1
printf '{"fetched_at":%s}\n' "$(date -u +%s)" > "$C"; check "E5 a fresh cache" 0
printf '{"fetched_at":%s}\n' "$(( $(date -u +%s) - 600 ))" > "$C"; check "E6 a cache past the TTL" 1
rm -f "$C";                                 check "E7 no cache file" 1

# The caller's shell survives an empty cache: the command substitution that
# holds the read still returns its earlier output (the resolver's candidates).
: > "$C"
OUT=$( echo row-1; _ghb_cache_valid "$C"; echo row-2 ) 2>/dev/null
[ "$OUT" = "row-1"$'\n'"row-2" ] && ok || bad "E8 the subshell lost output after the read: '$OUT'"

echo "gh-budget-empty-cache: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
