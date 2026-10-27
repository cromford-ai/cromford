#!/bin/bash
# shellcheck shell=bash
# bin/lib/hub-probes/repo-detect.sh — BH-7997 (BH-7935 wave 2): can the App see
# this repo, and what are its tracer facts? Sourced by common.sh's hp_run.
#
# hp_probe_repo_detect <owner/repo>
#   One read of repos/<owner/repo> through og_get (bin/lib/onboard-github.sh,
#   the only GitHub seam). Prints ONE line, because hub-probe.sh stores it and
#   GET /api/onboarding/repo parses it as JSON; every stderr goes to /dev/null.
#   PASS (rc 0):
#     visible -> {visible:true, default_branch, has_issues, open_issues,
#                install_url} merged (jq *) with hp_repo_detect_extra's object.
#                An extra that is not one JSON object is ignored.
#     404, or the App cannot mint for the repo -> {visible:false, install_url}.
#   FAIL (rc 1): `not-configured` (this box does not mint App tokens),
#     `unparseable` (a 2xx body without the three fields), `unverifiable`
#     (anything else).
command -v og_get >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/../onboard-github.sh"
command -v hp_repo_detect_extra >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/repo-detect-extra.sh"

hp_probe_repo_detect() {
  local slug="$1" tmp rc=0 url base extra merged
  url=$(og_install_url 2>/dev/null)
  tmp=$(mktemp "${TMPDIR:-/tmp}/hp-repo-detect.XXXXXX") || { echo "unverifiable"; HP_HTTP_STATUS=000; return 1; }
  og_get "repos/$slug" > "$tmp" 2>/dev/null || rc=$?
  HP_HTTP_STATUS=${OG_HTTP_STATUS:-000}
  case "$rc" in
    0) ;;
    44) rm -f "$tmp"; jq -nc --arg u "$url" '{visible:false, install_url:$u}'; return 0 ;;
    4) rm -f "$tmp"; echo "not-configured"; return 1 ;;
    *) rm -f "$tmp"; echo "unverifiable"; return 1 ;;
  esac
  base=$(jq -c --arg u "$url" 'if type == "object" and (.default_branch | type) == "string"
      and (.has_issues | type) == "boolean" and (.open_issues_count | type) == "number"
    then {visible:true, default_branch, has_issues, open_issues:.open_issues_count, install_url:$u}
    else empty end' "$tmp" 2>/dev/null)
  rm -f "$tmp"
  if [ -z "$base" ]; then echo "unparseable"; return 1; fi
  extra=$(hp_repo_detect_extra "$slug" 2>/dev/null)
  merged=$(printf '%s\n%s\n' "$base" "$extra" \
    | jq -cs 'if length == 2 and (.[1] | type) == "object" then .[0] * .[1] else empty end' 2>/dev/null)
  printf '%s\n' "${merged:-$base}"
  return 0
}
