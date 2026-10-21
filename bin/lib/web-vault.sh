#!/bin/bash
# bin/lib/web-vault.sh — BH-7595: the client half of the web_vault credential
# store (worker/jobs/src/routes/web-vault.js). Sourced, never run.
#
#   wv_read <project> <site> <field>
#     For a lane run on a lane-run machine. POSTs /api/web-vault/read with
#     run_id=$LANE_RUN_ID, machine=${WEB_VAULT_MACHINE:-$FLY_MACHINE_ID} and the
#     header x-web-vault-run-token=$WEB_VAULT_RUN_TOKEN (the token the claim
#     answer gave; bin/lane-run-worker.sh exports it). The worker answers only
#     when that run is a claimed web-task run of <project>, held by this
#     machine, the token is that claim's, and <site> is on the allow-list.
#     rc 0: the value on stdout, with no newline added.
#     rc 1: `web-vault: refused <why>` (or `web-vault: <http> <error>`) on stderr.
#     rc 2: no LANE_RUN_ID, no machine, no WEB_VAULT_RUN_TOKEN, no
#           JOBS_URL/HARNESS_SECRET, or bad
#           arguments; no request is sent.
#     The answer is held in a variable, never a file, and never logged.
#
#   wv_curl_cfg [admin|run]
#     Prints a curl config (for `curl -K <(wv_curl_cfg)`) with the bearer and,
#     with `admin`, the x-web-vault-admin-token header, or with `run`, the
#     x-web-vault-run-token header. printf is a builtin, so no token is ever on
#     a process argv. bin/web-vault.sh uses it too.
#
# Needs curl and jq. Reads JOBS_URL, HARNESS_SECRET (and WEB_VAULT_ADMIN_TOKEN
# for `admin`) from the environment only; this file loads no env file.

# A curl config value inside double quotes: \ and " escaped.
_wv_cfg_q() {
  local s="${1//\\/\\\\}"
  printf '%s' "${s//\"/\\\"}"
}

wv_curl_cfg() {
  printf 'header = "authorization: Bearer %s"\n' "$(_wv_cfg_q "${HARNESS_SECRET:-}")"
  if [ "${1:-}" = admin ]; then
    printf 'header = "x-web-vault-admin-token: %s"\n' "$(_wv_cfg_q "${WEB_VAULT_ADMIN_TOKEN:-}")"
  elif [ "${1:-}" = run ]; then
    printf 'header = "x-web-vault-run-token: %s"\n' "$(_wv_cfg_q "${WEB_VAULT_RUN_TOKEN:-}")"
  fi
}

wv_read() {
  local project="${1:-}" site="${2:-}" field="${3:-}" machine="${WEB_VAULT_MACHINE:-${FLY_MACHINE_ID:-}}"
  local run="${LANE_RUN_ID:-}" out code body why
  if [ "$#" -ne 3 ] || [ -z "$project" ] || [ -z "$site" ] || [ -z "$field" ]; then
    echo "web-vault: usage: wv_read <project> <site> <field>" >&2; return 2
  fi
  [[ $run =~ ^[1-9][0-9]{0,15}$ ]] || { echo "web-vault: no LANE_RUN_ID (wv_read runs inside a lane run)" >&2; return 2; }
  [ -n "$machine" ] || { echo "web-vault: no machine id (WEB_VAULT_MACHINE or FLY_MACHINE_ID)" >&2; return 2; }
  [ -n "${WEB_VAULT_RUN_TOKEN:-}" ] || { echo "web-vault: no WEB_VAULT_RUN_TOKEN (the claim of this run gave none)" >&2; return 2; }
  [ -n "${JOBS_URL:-}" ] || { echo "web-vault: not-configured: JOBS_URL" >&2; return 2; }
  [ -n "${HARNESS_SECRET:-}" ] || { echo "web-vault: not-configured: HARNESS_SECRET" >&2; return 2; }
  out=$(jq -nc --arg project "$project" --arg site "$site" --arg field "$field" --arg machine "$machine" --argjson run_id "$run" \
          '{project:$project, site:$site, field:$field, machine:$machine, run_id:$run_id}' \
        | curl -sS -m "${JOBS_TIMEOUT:-15}" --connect-timeout 5 -w $'\n%{http_code}' -K <(wv_curl_cfg run) \
            -H 'content-type: application/json' -X POST --data-binary @- "$JOBS_URL/api/web-vault/read" 2>/dev/null) \
    || { echo "web-vault: worker unreachable" >&2; return 1; }
  code="${out##*$'\n'}"; body="${out%$'\n'*}"
  if [ "$code" = 200 ]; then
    printf '%s' "$body" | jq -j 'if (.value | type) == "string" then .value else error("no value") end' 2>/dev/null && return 0
    echo "web-vault: the worker answered 200 with no value" >&2; return 1
  fi
  why=$(printf '%s' "$body" | jq -r '.why // empty' 2>/dev/null)
  if [ -n "$why" ]; then echo "web-vault: refused $why" >&2; return 1; fi
  echo "web-vault: $code $(printf '%s' "$body" | jq -r '.error // empty' 2>/dev/null)" >&2
  return 1
}
