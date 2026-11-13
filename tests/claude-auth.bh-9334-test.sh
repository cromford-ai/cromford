#!/bin/bash
# tests/claude-auth.bh-9334-test.sh — bin/lib/claude-auth.sh (BH-9334 C0):
# claude_auth_mode <project> and runner_lock_for <project> read the settings
# rows claude_auth.<project> / runner_lock.<project> through the lane-gate
# settings cache, the same way account.<project> is read (project-account.sh).
#
# A1-A13: claude_auth_mode. L1-L8: runner_lock_for. R1: both rows round-trip
# from one cache in the /api/settings `values` shape. P1: the lib only defines
# functions. No network: JOBS_URL is empty, the cache file is written here.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/bin/lib/claude-auth.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
mkdir -p "$T/state"
cache() { jq -n --argjson fa "$(date -u +%s)" --argjson v "$1" '{fetched_at:$fa,values:$v,seeded:{}}' > "$T/state/settings-cache.json"; }
nocache() { rm -f "$T/state/settings-cache.json"; }
RC=0
run() { # run <fn> <project> — stdout to $OUT, stderr to $T/err, rc to $RC
  OUT=$(env HARNESS="$T" JOBS_URL= bash -c '. "$0" || exit 99; '"$1"' "$1"' "$LIB" "$2" 2>"$T/err"); RC=$?
}
errlines() { grep -c . "$T/err" 2>/dev/null || true; }
answer() { # answer <case> <fn> <project> <expected>
  run "$2" "$3"
  [ "$RC" = 0 ] && [ "$OUT" = "$4" ] && ok || bad "$1: $2 $3 want rc0 [$4], got rc$RC [$OUT] err[$(cat "$T/err")]"
}
refuse() { # refuse <case> <fn> <project> <row-key-or-empty>
  run "$2" "$3"
  [ "$RC" = 1 ] && [ -z "$OUT" ] && [ "$(errlines)" = 1 ] && ok \
    || bad "$1: $2 '$3' want rc1, empty stdout, one stderr line; got rc$RC [$OUT] err[$(cat "$T/err")]"
  if [ -n "${4:-}" ]; then grep -qF "$4" "$T/err" && ok || bad "$1: stderr must name the row $4"; fi
}

# ── P1. the lib loads and defines functions only ────────────────────────────
if [ ! -r "$LIB" ]; then
  bad "P1: $LIB must exist"
  echo "claude-auth.bh-9334: $PASS pass, $FAIL fail"; exit 1
fi
bash -n "$LIB" && ok || bad "P1: bash -n"
p1=$(env -i PATH="$PATH" HOME="$T" HARNESS="$T" JOBS_URL= bash --norc --noprofile -uc '. "$0" || exit 9; declare -F claude_auth_mode runner_lock_for' "$LIB" 2>&1 </dev/null); rc=$?
[ "$rc" = 0 ] && [ "$p1" = "$(printf 'claude_auth_mode\nrunner_lock_for')" ] && ok || bad "P1: source under set -u printed [$p1] rc$rc"

# ── A. claude_auth_mode ─────────────────────────────────────────────────────
cache '{"account.proj-a":"own:proj-a"}'
answer A1 claude_auth_mode proj-a oauth
cache '{"claude_auth.proj-a":"oauth"}'
answer A2 claude_auth_mode proj-a oauth
cache '{"claude_auth.proj-a":"api-key"}'
answer A3 claude_auth_mode proj-a api-key
nocache
answer A4 claude_auth_mode proj-a oauth
n=5
for v in API-KEY api_key " api-key " apikey "oauth,api-key" ""; do
  cache "$(jq -n --arg v "$v" '{"claude_auth.proj-a":$v}')"
  refuse "A$n [$v]" claude_auth_mode proj-a claude_auth.proj-a
  n=$((n+1))
done
cache '{"claude_auth.x":"api-key"}'
refuse A11 claude_auth_mode "../x"
refuse A12 claude_auth_mode ""
cache '{"claude_auth.proj-a2":"api-key"}'
answer A13 claude_auth_mode proj-a oauth

# ── L. runner_lock_for ──────────────────────────────────────────────────────
cache '{"claude_auth.proj-a":"api-key"}'
answer L1 runner_lock_for proj-a ""
cache '{"runner_lock.proj-a":"claude"}'
answer L2 runner_lock_for proj-a claude
nocache
answer L3 runner_lock_for proj-a ""
n=4
for v in Claude "claude " codex none 0; do
  cache "$(jq -n --arg v "$v" '{"runner_lock.proj-a":$v}')"
  refuse "L$n [$v]" runner_lock_for proj-a runner_lock.proj-a
  n=$((n+1))
done
refuse L9 runner_lock_for "a/b"

# ── R1. round-trip: both rows for one project, from one cache ───────────────
cache '{"claude_auth.my-proj_1":"api-key","runner_lock.my-proj_1":"claude","claude_auth.other":"oauth"}'
answer R1a claude_auth_mode my-proj_1 api-key
answer R1b runner_lock_for my-proj_1 claude
answer R1c runner_lock_for other ""

echo "claude-auth.bh-9334: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
