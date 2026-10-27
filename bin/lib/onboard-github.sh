#!/bin/bash
# shellcheck shell=bash
# bin/lib/onboard-github.sh — BH-7997 (BH-7935 wave 2): the ONE GitHub seam for
# the onboarding probes. Sourced, never run. No other onboarding file calls gh,
# curl or gh_rest toward GitHub (tests/onboard-github-vendor-budget.bh-7935-test.sh).
#
# og_get <path>
#   One REST GET. <path> must be repos/<owner>/<name>[/<segment>...] (owner
#   1-39 of [A-Za-z0-9-], name 1-100 of [A-Za-z0-9_.-], no . or .. segment),
#   else rc 2 and nothing is read. The body goes to stdout; OG_HTTP_STATUS is
#   set. rc 0 = 2xx, 44 = 404 or the App cannot see the repo, 75 = unverifiable,
#   4 = this box does not mint App tokens (no process is run).
#   FAKE (tests): ONBOARD_GITHUB_FAKE=<dir> appends <path> to <dir>/.calls and
#   prints <dir>/<path with / as __>.json. A sibling .status.txt file holding 404
#   is rc 44 with no body; no file is rc 3. gh and curl never run.
#   REAL: gh_auth_armed, then gh_app_only_for <owner/repo>. A refused mint is
#   rc 44 and never falls back to the PAT. Then gh_rest GET and
#   gh_app_only_release, so GH_TOKEN is back as it was on every path.
# og_install_url
#   https://github.com/apps/<slug>/installations/new. The slug is GH_APP_SLUG
#   (else GH_APP_NAME) read, never sourced, from env/github-app.env and
#   slugged the way GitHub slugs an App name; default cromford, the same
#   default as bin/lib/gh-push-identity.sh.

og_get() {
  local path="${1:-}" f owner repo rc=0
  local re='^repos/[A-Za-z0-9-]{1,39}/[A-Za-z0-9_.-]{1,100}(/[A-Za-z0-9_.-]+)*$'
  OG_HTTP_STATUS=""
  [ $# -eq 1 ] && [[ "$path" =~ $re ]] || return 2
  case "/$path/" in */./*|*/../*) return 2 ;; esac
  if [ -n "${ONBOARD_GITHUB_FAKE:-}" ]; then
    printf '%s\n' "$path" >> "$ONBOARD_GITHUB_FAKE/.calls"
    f="$ONBOARD_GITHUB_FAKE/${path//\//__}"
    if [ "$(cat "$f.status.txt" 2>/dev/null)" = 404 ]; then OG_HTTP_STATUS=404; return 44; fi
    [ -f "$f.json" ] || return 3
    OG_HTTP_STATUS=200
    cat "$f.json"
    return 0
  fi
  declare -F gh_auth_armed gh_app_only_for gh_app_only_release >/dev/null 2>&1 \
    || . "${BASH_SOURCE[0]%/*}/gh-app-auth.sh" || return 4
  gh_auth_armed || return 4
  IFS=/ read -r _ owner repo _ <<< "$path"
  if ! gh_app_only_for "$owner/$repo"; then OG_HTTP_STATUS=000; return 44; fi
  declare -F gh_rest >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/gh-rest.sh" || { gh_app_only_release; return 75; }
  gh_rest GET "$path" || rc=$?
  gh_app_only_release
  OG_HTTP_STATUS=${GH_REST_STATUS:-000}
  case "$rc" in 0|44|75) return "$rc" ;; *) return 75 ;; esac
}

og_install_url() {
  local h="${HARNESS:-${H:-}}" envd raw
  declare -F harness_env_dir >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/env-path.sh" 2>/dev/null
  if declare -F harness_env_dir >/dev/null 2>&1; then envd=$(harness_env_dir "$h"); else envd="$h/env"; fi
  raw=$(sed -n 's/^\(export \)\{0,1\}GH_APP_SLUG=//p' "$envd/github-app.env" 2>/dev/null | tr -d "\"'" | head -n 1)
  [ -n "$raw" ] || raw=$(sed -n 's/^\(export \)\{0,1\}GH_APP_NAME=//p' "$envd/github-app.env" 2>/dev/null | tr -d "\"'" | head -n 1)
  raw=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
  [ -n "$raw" ] || raw="cromford"
  printf 'https://github.com/apps/%s/installations/new\n' "$raw"
}
