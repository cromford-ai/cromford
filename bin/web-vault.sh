#!/bin/bash
# bin/web-vault.sh — BH-7595: the operator CLI of the web_vault credential
# store (worker/jobs/src/routes/web-vault.js). Run it on the hub, never on a
# lane-run machine. Contract: docs/notes/2026-10-19-BH-7595-web-vault.md.
#
# THE VALUE COMES FROM STDIN ONLY. `set` refuses a 4th word, so a value typed
# as an argument is never sent. From a terminal it reads with no echo. One
# trailing newline is stripped. The value goes jq -> curl through a pipe, and
# both tokens go to curl in a `-K <(...)` config written by printf (a builtin),
# so no secret is ever on a process argv. Nothing here prints a value.
#
# Env: JOBS_URL, HARNESS_SECRET and WEB_VAULT_ADMIN_TOKEN, from the environment
# or else from env/global.env (bin/lib/env-path.sh resolves the directory).
#
# usage: bin/web-vault.sh set <project> <site> <field>     (the value on stdin)
#          prints `stored <project> <site> <field> key_id=<n>`
#        bin/web-vault.sh list [project] [site]
#        bin/web-vault.sh stale [project]
#          TSV: project site field key_id created_at updated_at last_used_at
#        bin/web-vault.sh audit <project> [site] [limit]
#          TSV: at action outcome project site field actor run_id key_id
# exit:  0 ok | 1 the worker refused or is unreachable (its error on stderr)
#        2 usage | 3 not-configured: <NAME> (no request sent)
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS="${HARNESS:-$(cd "$SELF_DIR/.." && pwd)}"
# shellcheck source=bin/lib/env-path.sh
. "$SELF_DIR/lib/env-path.sh" || { echo "web-vault: bin/lib/env-path.sh did not load" >&2; exit 1; }
# shellcheck source=bin/lib/web-vault.sh
. "$SELF_DIR/lib/web-vault.sh" || { echo "web-vault: bin/lib/web-vault.sh did not load" >&2; exit 1; }

usage() { sed -n '/^# usage:/,/^#        2 usage/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

# conf <NAME> — the env value, else the first NAME= line of env/global.env.
# Missing in both: `not-configured: <NAME>` and exit 3.
ENV_FILE="$(harness_env_dir "$HARNESS")/global.env"
conf() {
  local name="$1" v="${!1:-}"
  if [ -z "$v" ] && [ -r "$ENV_FILE" ]; then
    v=$(sed -n "s/^$name=//p" "$ENV_FILE" | head -1 | tr -d '"'"'"' \r')
  fi
  [ -n "$v" ] || { echo "not-configured: $name" >&2; exit 3; }
  printf -v "$name" '%s' "$v"
  export "${name?}"
}
need_env() { conf JOBS_URL; conf HARNESS_SECRET; conf WEB_VAULT_ADMIN_TOKEN; }

# answer <curl output> — sets CODE and BODY from `<body>\n<http code>`.
answer() { CODE="${1##*$'\n'}"; BODY="${1%$'\n'*}"; }
fail() {
  echo "web-vault: $CODE $(printf '%s' "$BODY" | jq -r '.error // empty' 2>/dev/null)" >&2
  exit 1
}
curl_wv() {
  curl -sS -m "${JOBS_TIMEOUT:-15}" --connect-timeout 5 -w $'\n%{http_code}' -K <(wv_curl_cfg admin) "$@" 2>/dev/null
}

cmd_set() {
  [ "$#" -eq 3 ] && [ -n "$1" ] && [ -n "$2" ] && [ -n "$3" ] || usage
  local project="$1" site="$2" field="$3" out v=""
  need_env
  if [ -t 0 ]; then
    printf 'value for %s %s %s (not echoed): ' "$project" "$site" "$field" >&2
    IFS= read -rs v || true
    echo >&2
    out=$(printf '%s' "$v" | jq -Rs --arg project "$project" --arg site "$site" --arg field "$field" \
            '{project:$project, site:$site, field:$field, value:.}' \
          | curl_wv -H 'content-type: application/json' -X POST --data-binary @- "$JOBS_URL/api/web-vault/set")
  else
    out=$(jq -Rs --arg project "$project" --arg site "$site" --arg field "$field" \
            '{project:$project, site:$site, field:$field, value:(if endswith("\n") then .[:-1] else . end)}' \
          | curl_wv -H 'content-type: application/json' -X POST --data-binary @- "$JOBS_URL/api/web-vault/set")
  fi || { unset v; echo "web-vault: worker unreachable" >&2; exit 1; }
  unset v
  answer "$out"
  [ "$CODE" = 200 ] && printf '%s' "$BODY" | jq -e '.stored == true' >/dev/null 2>&1 || fail
  printf '%s' "$BODY" | jq -r '"stored \(.project) \(.site) \(.field) key_id=\(.key_id)"'
}

# get_rows <path> <jq row array> [--data-urlencode k=v ...] — GET, then TSV.
get_rows() {
  local path="$1" cols="$2" out; shift 2
  need_env
  out=$(curl_wv --get "$@" "$JOBS_URL$path") || { echo "web-vault: worker unreachable" >&2; exit 1; }
  answer "$out"
  [ "$CODE" = 200 ] || fail
  printf '%s' "$BODY" | jq -r ".rows[] | $cols | map(. // \"\" | tostring) | @tsv"
  if printf '%s' "$BODY" | jq -e '.more == true' >/dev/null 2>&1; then
    echo "web-vault: more rows than shown (the worker's limit)" >&2
  fi
}
ENTRY_COLS='[.project, .site, .field, .key_id, .created_at, .updated_at, .last_used_at]'
AUDIT_COLS='[.at, .action, .outcome, .project, .site, .field, .actor, .run_id, .key_id]'

verb="${1:-}"; [ "$#" -gt 0 ] && shift
case "$verb" in
  set) cmd_set "$@" ;;
  list)
    [ "$#" -le 2 ] || usage
    args=(); [ -n "${1:-}" ] && args+=(--data-urlencode "project=$1"); [ -n "${2:-}" ] && args+=(--data-urlencode "site=$2")
    get_rows /api/web-vault/entries "$ENTRY_COLS" --data-urlencode limit=500 "${args[@]}" ;;
  stale)
    [ "$#" -le 1 ] || usage
    args=(); [ -n "${1:-}" ] && args+=(--data-urlencode "project=$1")
    get_rows /api/web-vault/entries "$ENTRY_COLS" --data-urlencode stale=1 --data-urlencode limit=500 "${args[@]}" ;;
  audit)
    [ "$#" -ge 1 ] && [ "$#" -le 3 ] && [ -n "$1" ] || usage
    args=(--data-urlencode "project=$1"); [ -n "${2:-}" ] && args+=(--data-urlencode "site=$2")
    get_rows /api/web-vault/audit "$AUDIT_COLS" --data-urlencode "limit=${3:-100}" "${args[@]}" ;;
  *) usage ;;
esac
