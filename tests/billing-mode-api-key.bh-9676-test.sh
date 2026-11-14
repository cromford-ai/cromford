#!/bin/bash
# tests/billing-mode-api-key.bh-9676-test.sh — BH-9676 (C0):
# `bin/billing-mode.sh <runner> [project]`. With runner claude and a project
# whose settings row claude_auth.<project> is `api-key`, the answer is metered,
# whatever the box env holds. With no project the answer is main's env rule.
#
#   B1 claude p-key, row api-key, key only           -> metered
#   B2 claude p-key, row api-key, key + OAuth token  -> metered
#   B3 claude p-oauth, no row, OAuth token           -> subscription
#   B4 claude (no project), key only                 -> metered     (main rule)
#   B5 claude (no project), key + OAuth token        -> subscription (main rule)
#   B6 claude p-bad, row API-KEY, key + OAuth token  -> subscription (env rule)
#   B7 codex p-key, row api-key                      -> subscription
#   B8 no settings cache at all, claude p-key, both  -> subscription (env rule)
#   B9 no project: billing-mode.sh sources nothing new (strace-free check: a
#      broken claude-auth lib beside a copy of the script changes no answer).
# 0 network calls: JOBS_URL is empty and the settings cache is a local file.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
mkdir -p "$T/state"
KEY="sk-ant-api""03-bh9676-billing-fixture"
TOK="sk-ant-oat""01-bh9676-billing-fixture"
cache() { jq -n --argjson fa "$(date -u +%s)" --argjson v "$1" '{fetched_at:$fa,values:$v,seeded:{}}' > "$T/state/settings-cache.json"; }
bm() { # bm <case> <want> <script> <args...> [-- VAR=val ...]
  local c="$1" want="$2" script="$3"; shift 3
  local -a args=() envs=()
  while [ $# -gt 0 ]; do [ "$1" = -- ] && { shift; envs=("$@"); break; }; args+=("$1"); shift; done
  local got
  got=$(env -u ANTHROPIC_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN -u GROK_BILLING HARNESS="$T" HOME="$T" JOBS_URL= \
        "${envs[@]}" bash "$script" "${args[@]}" 2>/dev/null)
  [ "$got" = "$want" ] && ok || bad "$c: billing-mode ${args[*]} -> '$got' (want $want)"
}
BM="$DIR/bin/billing-mode.sh"

cache '{"claude_auth.p-key":"api-key","claude_auth.p-bad":"API-KEY"}'
bm B1 metered      "$BM" claude p-key   -- ANTHROPIC_API_KEY="$KEY"
bm B2 metered      "$BM" claude p-key   -- ANTHROPIC_API_KEY="$KEY" CLAUDE_CODE_OAUTH_TOKEN="$TOK"
bm B3 subscription "$BM" claude p-oauth -- CLAUDE_CODE_OAUTH_TOKEN="$TOK"
bm B4 metered      "$BM" claude         -- ANTHROPIC_API_KEY="$KEY"
bm B5 subscription "$BM" claude         -- ANTHROPIC_API_KEY="$KEY" CLAUDE_CODE_OAUTH_TOKEN="$TOK"
bm B6 subscription "$BM" claude p-bad   -- ANTHROPIC_API_KEY="$KEY" CLAUDE_CODE_OAUTH_TOKEN="$TOK"
bm B7 subscription "$BM" codex  p-key   -- ANTHROPIC_API_KEY="$KEY"
rm -f "$T/state/settings-cache.json"
bm B8 subscription "$BM" claude p-key   -- ANTHROPIC_API_KEY="$KEY" CLAUDE_CODE_OAUTH_TOKEN="$TOK"

# B9 a copy beside a lib that exits on source: the no-project answers are main's.
mkdir -p "$T/copy/lib"
cp "$BM" "$T/copy/billing-mode.sh"
printf 'echo SOURCED; exit 42\n' > "$T/copy/lib/claude-auth.sh"
cache '{"claude_auth.p-key":"api-key"}'
bm B9a metered      "$T/copy/billing-mode.sh" claude -- ANTHROPIC_API_KEY="$KEY"
bm B9b subscription "$T/copy/billing-mode.sh" claude -- ANTHROPIC_API_KEY="$KEY" CLAUDE_CODE_OAUTH_TOKEN="$TOK"
bm B9c subscription "$T/copy/billing-mode.sh" codex p-key -- ANTHROPIC_API_KEY="$KEY"

echo "billing-mode-api-key.bh-9676: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
