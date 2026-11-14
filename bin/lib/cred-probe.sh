#!/bin/bash
# bin/lib/cred-probe.sh — BH-2558 (BH-2549.0): the credential-probe CONTRACT
# the BH-2549 slices ("canaries without inference") code against. Sourced,
# never executed; defines functions, runs nothing, prints nothing, and sources
# bin/lib/endpoints.sh itself.
#
# cred_account_fp is BH-2558's; cred_probe, cred_inference_claim and
# cred_inference_record are real since BH-2559 (BH-2549.1).
#
#   cred_probe <runner>
#     A FREE, non-inference GET against the runner's vendor (no model id, no
#     token spent). Prints exactly one line and exits to match —
#       ALIVE <detail>       rc 0   200 with a JSON body
#       DEAD <http-code>     rc 1   only the runner's named auth codes
#       INCONCLUSIVE <why>   rc 2
#       DEGRADED <detail>    rc 3
#       NO_ENDPOINT          rc 4
#     - 429, 5xx, curl 000/timeout, DNS failure, a non-JSON 200, an
#       unresolved endpoint_url and a missing credential are INCONCLUSIVE,
#       never DEAD;
#     - openrouter 200 with limit_remaining<=0 is DEGRADED (null = unlimited
#       = ALIVE); grok 200 with api_key_blocked/api_key_disabled is DEAD 200
#       blocked, and grok 400 "Incorrect API key…" (xAI's bad-key answer) DEAD 400;
#     - codex on a ChatGPT login (no API key), grok off GROK_BILLING=api and an
#       unknown runner are NO_ENDPOINT.
#     Probes:  claude setup-token  GET <anthropic>/v1/models (OAuth beta header)
#                                  DEAD on 401/403
#              claude api key      GET <anthropic>/v1/models (x-api-key header),
#                                  only with no OAuth token (BH-9676); DEAD on 401/403
#              claude full login   <anthropic>/api/oauth/usage through
#                                  ${OAUTH_USAGE_FETCH:-oauth-usage-fetch.py}
#              codex    GET <openai>/v1/models            DEAD on 401
#              openrouter GET <openrouter>/api/v1/key     DEAD on 401
#              fireworks GET <fireworks>/inference/v1/models  DEAD on 401/403
#              grok     GET <xai>/v1/api-key              DEAD on 401/403 (+ 400 bad key)
#     THE SECRET NEVER REACHES ARGV, STDOUT, STDERR OR A LOG: curl reads it from
#     `-H @<file>` in a 0700 mktemp dir removed before the function returns, and
#     the response body is parsed with jq, never printed.
#     CRED_PROBE_TIMEOUT_S (default 20) bounds each call.
#
#   cred_account_fp <runner>
#     Prints the first 16 hex of sha256 over the runner's credential string,
#     rc 0; empty stdout and rc 1 when there is none (or the runner is
#     unknown). Never prints the secret. Reads the environment only:
#       claude     CLAUDE_CODE_OAUTH_TOKEN, else ANTHROPIC_API_KEY (BH-9676,
#                  the auth_fp_for_runner order), else .claudeAiOauth.accessToken in
#                  ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json
#                  (a full login's token rotates ~8 h, so its fp does too)
#       codex      CODEX_API_KEY, else OPENAI_API_KEY
#       openrouter OPENROUTER_API_KEY     fireworks FIREWORKS_API_KEY
#       grok       XAI_API_KEY, else GROK_CODE_XAI_API_KEY
#
#   cred_inference_claim <runner> <fp>
#     rc 0 = spend today's inference probe (a `claimed` row was written first),
#     rc 1 = already spent today (ANY row for the key, `claimed` included),
#     rc 2 = the store is unreachable or unconfigured, so do NOT spend.
#     Store: the worker `ledgers` table through bin/jobs-client.sh
#     (job_ledger_get / job_ledger_put), kind=canary-inference,
#     key=<runner>:<fp>:<YYYY-MM-DD UTC>, detail box=<hostname>.
#
#   cred_inference_record <runner> <fp> <ok|down|degraded|empty>
#     PUTs the terminal status onto the same key (the claimed day's, when the
#     claim ran in this shell); rc 0 on success, rc 1 on a bad status or a
#     failed PUT. `empty` is stored as-is and counts as billed.
#
# Override convention: every consumer sources
#   . "${CRED_PROBE_LIB:-$HARNESS/bin/lib/cred-probe.sh}"
# so a sibling's test suite can inject a stub lib.
[ -n "${_CRED_PROBE_LOADED:-}" ] && return 0
_CRED_PROBE_LOADED=1
_CP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_CP_DIR/endpoints.sh" >/dev/null 2>&1

# runner:service:knob — the endpoint_url <service> each runner's probe
# resolves. The URLs are registry defaults (catalog/lanes.d/_lib.endpoint-*),
# never literals here.
_CRED_PROBE_ENDPOINTS="claude:anthropic:ENDPOINT_ANTHROPIC claude-oauth:anthropic-oauth:ENDPOINT_ANTHROPIC_OAUTH fireworks:fireworks:ENDPOINT_FIREWORKS grok:xai:ENDPOINT_XAI codex:openai:ENDPOINT_OPENAI openrouter:openrouter:ENDPOINT_OPENROUTER"

# _cp_http <url> <header-line>... — one GET. Sets _CP_CODE (000 when curl
# itself failed) and _CP_BODY. The header lines, secret included, live only in a
# file inside a 0700 mktemp dir that is removed on every return path.
_cp_http() {
  local url="$1" d; shift
  _CP_CODE=000; _CP_BODY=""
  d=$(mktemp -d 2>/dev/null) || return 1
  ( umask 077; printf '%s\n' "$@" > "$d/h" ) || { rm -rf "$d"; return 1; }
  _CP_CODE=$(curl -sS -o "$d/b" -w '%{http_code}' --max-time "${CRED_PROBE_TIMEOUT_S:-20}" \
    -H @"$d/h" "$url" 2>/dev/null) || _CP_CODE=000
  [ -n "$_CP_CODE" ] || _CP_CODE=000
  _CP_BODY=$(cat "$d/b" 2>/dev/null) || _CP_BODY=""
  rm -rf "$d"
  return 0
}

# _cp_classify <dead-codes...> — prints the class line for _CP_CODE/_CP_BODY and
# returns its rc. Only 200 + JSON is ALIVE; only the named codes are DEAD.
_cp_classify() {
  local c
  for c in "$@"; do
    [ "$_CP_CODE" = "$c" ] && { echo "DEAD $c"; return 1; }
  done
  case "$_CP_CODE" in
    200) if printf '%s' "$_CP_BODY" | jq -e . >/dev/null 2>&1; then
           echo "ALIVE http 200"; return 0
         fi
         echo "INCONCLUSIVE non-json 200"; return 2 ;;
    429) echo "INCONCLUSIVE http 429"; return 2 ;;
    *)   echo "INCONCLUSIVE http $_CP_CODE"; return 2 ;;
  esac
}

# _cp_base <service> — endpoint_url, or the INCONCLUSIVE line and rc 2.
_cp_base() {
  _CP_BASE=$(endpoint_url "$1" 2>/dev/null) && [ -n "$_CP_BASE" ] && return 0
  echo "INCONCLUSIVE no endpoint url for $1"; return 2
}

# _cp_claude_login <token> — the full-login probe: the usage endpoint through
# the same fetcher bin/quota-poll.sh uses, token in its environment only.
_cp_claude_login() {
  local tok="$1" fetch="${OAUTH_USAGE_FETCH:-$_CP_DIR/oauth-usage-fetch.py}" d err rc
  _cp_base anthropic || return 2
  d=$(mktemp -d 2>/dev/null) || { echo "INCONCLUSIVE mktemp failed"; return 2; }
  OAUTH_USAGE_TOKEN="$tok" OAUTH_USAGE_URL="$_CP_BASE/api/oauth/usage" \
    OAUTH_USAGE_TIMEOUT="${CRED_PROBE_TIMEOUT_S:-20}" "$fetch" >/dev/null 2>"$d/e" && rc=0 || rc=$?
  err=$(grep -m1 -oE 'HTTP Error (401|403)' "$d/e" 2>/dev/null) || err=""
  rm -rf "$d"
  [ "$rc" -eq 0 ] && { echo "ALIVE usage 200"; return 0; }
  [ -n "$err" ] && { echo "DEAD ${err##* }"; return 1; }
  echo "INCONCLUSIVE usage fetch rc=$rc"; return 2
}

cred_probe() {
  local runner="${1:-}" tok=""
  case "$runner" in
    claude)
      if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
        _cp_base anthropic || return 2
        _cp_http "$_CP_BASE/v1/models" "Authorization: Bearer $CLAUDE_CODE_OAUTH_TOKEN" \
          "anthropic-beta: oauth-2025-04-20" "anthropic-version: 2023-06-01" \
          || { echo "INCONCLUSIVE mktemp failed"; return 2; }
        _cp_classify 401 403 && return 0 || return $?
      elif [ -n "${ANTHROPIC_API_KEY:-}" ]; then
        # An api-key project (BH-9676): the CLI uses the key when no OAuth
        # token is set, so that is the credential to probe.
        _cp_base anthropic || return 2
        _cp_http "$_CP_BASE/v1/models" "x-api-key: $ANTHROPIC_API_KEY" "anthropic-version: 2023-06-01" \
          || { echo "INCONCLUSIVE mktemp failed"; return 2; }
        _cp_classify 401 403 && return 0 || return $?
      fi
      tok=$(jq -r '.claudeAiOauth.accessToken // empty' \
        "${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/.credentials.json" 2>/dev/null) || tok=""
      [ -n "$tok" ] || { echo "INCONCLUSIVE no credential"; return 2; }
      _cp_claude_login "$tok" && return 0 || return $? ;;
    codex)
      tok="${CODEX_API_KEY:-${OPENAI_API_KEY:-}}"
      [ -n "$tok" ] || { echo NO_ENDPOINT; return 4; }
      _cp_base openai || return 2
      _cp_http "$_CP_BASE/v1/models" "Authorization: Bearer $tok" || { echo "INCONCLUSIVE mktemp failed"; return 2; }
      _cp_classify 401 && return 0 || return $? ;;
    openrouter)
      tok="${OPENROUTER_API_KEY:-}"
      [ -n "$tok" ] || { echo "INCONCLUSIVE no credential"; return 2; }
      _cp_base openrouter || return 2
      _cp_http "$_CP_BASE/api/v1/key" "Authorization: Bearer $tok" || { echo "INCONCLUSIVE mktemp failed"; return 2; }
      local left
      if [ "$_CP_CODE" = 200 ] && left=$(printf '%s' "$_CP_BODY" | jq -er \
           '.data.limit_remaining | select(type == "number" and . <= 0)' 2>/dev/null); then
        echo "DEGRADED limit_remaining=$left"; return 3
      fi
      _cp_classify 401 && return 0 || return $? ;;
    fireworks)
      tok="${FIREWORKS_API_KEY:-}"
      [ -n "$tok" ] || { echo "INCONCLUSIVE no credential"; return 2; }
      _cp_base fireworks || return 2
      _cp_http "$_CP_BASE/inference/v1/models" "Authorization: Bearer $tok" || { echo "INCONCLUSIVE mktemp failed"; return 2; }
      _cp_classify 401 403 && return 0 || return $? ;;
    grok)
      [ "${GROK_BILLING:-}" = api ] || { echo NO_ENDPOINT; return 4; }
      tok="${XAI_API_KEY:-${GROK_CODE_XAI_API_KEY:-}}"
      [ -n "$tok" ] || { echo "INCONCLUSIVE no credential"; return 2; }
      _cp_base xai || return 2
      _cp_http "$_CP_BASE/v1/api-key" "Authorization: Bearer $tok" || { echo "INCONCLUSIVE mktemp failed"; return 2; }
      if [ "$_CP_CODE" = 200 ] && printf '%s' "$_CP_BODY" | jq -e \
           '.api_key_blocked == true or .api_key_disabled == true' >/dev/null 2>&1; then
        echo "DEAD 200 blocked"; return 1
      fi
      # xAI answers a bad key 400, not 401: only that exact error is DEAD.
      if [ "$_CP_CODE" = 400 ] && printf '%s' "$_CP_BODY" | jq -e \
           '(.error // "") | startswith("Incorrect API key")' >/dev/null 2>&1; then
        echo "DEAD 400"; return 1
      fi
      _cp_classify 401 403 && return 0 || return $? ;;
    *) echo NO_ENDPOINT; return 4 ;;
  esac
}

cred_account_fp() {
  local cred=""
  case "${1:-}" in
    claude)
      cred="${CLAUDE_CODE_OAUTH_TOKEN:-${ANTHROPIC_API_KEY:-}}"
      [ -n "$cred" ] || cred=$(jq -r '.claudeAiOauth.accessToken // empty' \
        "${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/.credentials.json" 2>/dev/null) || cred="" ;;
    codex)      cred="${CODEX_API_KEY:-${OPENAI_API_KEY:-}}" ;;
    openrouter) cred="${OPENROUTER_API_KEY:-}" ;;
    fireworks)  cred="${FIREWORKS_API_KEY:-}" ;;
    grok)       cred="${XAI_API_KEY:-${GROK_CODE_XAI_API_KEY:-}}" ;;
    *) return 1 ;;
  esac
  [ -n "$cred" ] || return 1
  printf '%s' "$cred" | sha256sum | cut -c1-16
}

# _cp_ledger <verb> <args...> — one jobs-client ledger call in a SUBSHELL, so
# the client's `set -uo pipefail` and its module loader never touch the
# caller's shell (and sourcing this lib stays silent). rc 3 = no client.
_cp_ledger() {
  local client="${HARNESS:-$_CP_DIR/../..}/bin/jobs-client.sh"
  [ -r "$client" ] || client="$_CP_DIR/../jobs-client.sh"
  [ -r "$client" ] || return 3
  ( . "$client" >/dev/null 2>&1 || exit 3; "$@" )
}

cred_inference_claim() {
  local runner="${1:-}" fp="${2:-}" day key rc
  [ -n "$runner" ] && [ -n "$fp" ] || return 2
  day=$(date -u +%F); key="$runner:$fp:$day"
  _cp_ledger job_ledger_get canary-inference "$key" >/dev/null 2>&1 && rc=0 || rc=$?
  case "$rc" in
    0) return 1 ;;
    2) _cp_ledger job_ledger_put canary-inference "$key" claimed "box=$(hostname 2>/dev/null)" \
         >/dev/null 2>&1 || return 2
       _CP_CLAIM="$key"; return 0 ;;
    *) return 2 ;;
  esac
}

cred_inference_record() {
  local runner="${1:-}" fp="${2:-}" status="${3:-}" key
  [ -n "$runner" ] && [ -n "$fp" ] || return 1
  case "$status" in ok|down|degraded|empty) ;; *) return 1 ;; esac
  key="$runner:$fp:$(date -u +%F)"
  # the claimed day's row, when the claim ran in this shell (a spend that
  # crossed UTC midnight still lands on the row that blocked the re-spend)
  case "${_CP_CLAIM:-}" in "$runner:$fp:"*) key="$_CP_CLAIM" ;; esac
  _cp_ledger job_ledger_put canary-inference "$key" "$status" >/dev/null 2>&1 || return 1
  return 0
}
