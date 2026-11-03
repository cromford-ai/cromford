#!/bin/bash
# shellcheck shell=bash
# bin/lib/hub-probes/repo-create.sh — BH-8001 (BH-7935.4): make a new repo
# from a template. Sourced by common.sh's hp_run, which validated the args.
# owner BH-7935.4
#
# hp_probe_repo_create <owner> <name> <template-key>
#   1. setting_get onboarding.template.<key> (bin/jobs-client.sh, sourced when
#      setting_get is not defined). rc 1 -> `settings-unreadable`. No row, or a
#      value that is not a bare owner/repo in og_get's charset -> `no template
#      repo set`. Neither path calls GitHub.
#   2. One POST repos/<tmpl>/generate through og_post (bin/lib/onboard-github.sh,
#      the only GitHub seam) with {owner, name, private:true,
#      include_all_branches:false}. The body file is removed on every path.
#   Prints ONE line; every stderr goes to /dev/null, so no token and no
#   response body reaches the stored output. Never retries.
#   PASS (rc 0):
#     201 -> {"slug":"<owner>/<name>","created":true}
#     422, and repos/<owner>/<name> carries template_repository.full_name equal
#       to <tmpl> (case-insensitive) -> {"slug":...,"created":false}. This is
#       the finish of a create whose result was never stored.
#   FAIL (rc 1): `name already exists: <owner>/<name> was not made from <tmpl>`
#     (422 and any other repo), `template repo not visible to the App: <tmpl>`
#     (403/404 or a refused mint), `not-configured` (this box does not mint App
#     tokens), `github error <status>` (anything else).
command -v og_post >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/../onboard-github.sh"

hp_probe_repo_create() {
  local owner="$1" name="$2" key="$3" tmpl rc=0 body full
  local re='^[A-Za-z0-9-]{1,39}/[A-Za-z0-9_.-]{1,100}$'
  HP_HTTP_STATUS=000
  if ! declare -F setting_get >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    . "${BASH_SOURCE[0]%/*}/../../jobs-client.sh" >/dev/null 2>&1 || { echo "settings-unreadable"; return 1; }
    declare -F setting_get >/dev/null 2>&1 || { echo "settings-unreadable"; return 1; }
  fi
  tmpl=$(setting_get "onboarding.template.$key" 2>/dev/null) || rc=$?
  if [ "$rc" = 1 ]; then echo "settings-unreadable"; return 1; fi
  if [ "$rc" != 0 ] || ! [[ "$tmpl" =~ $re ]]; then echo "no template repo set"; return 1; fi
  case "${tmpl#*/}" in .|..) echo "no template repo set"; return 1 ;; esac
  body=$(mktemp "${TMPDIR:-/tmp}/hp-repo-create.XXXXXX") || { echo "github error 000"; return 1; }
  if ! jq -nc --arg o "$owner" --arg n "$name" '{owner:$o, name:$n, private:true, include_all_branches:false}' > "$body" 2>/dev/null; then
    rm -f "$body"; echo "github error 000"; return 1
  fi
  rc=0
  og_post "repos/$tmpl/generate" "$body" >/dev/null 2>&1 || rc=$?
  rm -f "$body"
  HP_HTTP_STATUS=${OG_HTTP_STATUS:-000}
  case "$rc" in
    0) jq -nc --arg s "$owner/$name" '{slug:$s, created:true}'; return 0 ;;
    22)
      full=$(og_get "repos/$owner/$name" 2>/dev/null | jq -r '.template_repository.full_name // empty' 2>/dev/null)
      if [ -n "$full" ] && [ "$(printf '%s' "$full" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$tmpl" | tr '[:upper:]' '[:lower:]')" ]; then
        jq -nc --arg s "$owner/$name" '{slug:$s, created:false}'; return 0
      fi
      echo "name already exists: $owner/$name was not made from $tmpl"; return 1 ;;
    44) echo "template repo not visible to the App: $tmpl"; return 1 ;;
    4) echo "not-configured"; return 1 ;;
    *) echo "github error $HP_HTTP_STATUS"; return 1 ;;
  esac
}
