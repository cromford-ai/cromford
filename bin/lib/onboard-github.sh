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
# og_clone <owner/repo> <dest>
#   One depth-1 clone into <dest>, which must be an existing EMPTY directory.
#   The slug must be owner/name in og_get's charset (no . or .. name), else
#   rc 2 and nothing runs. rc 0 = <dest> is a checkout with NO remote,
#   44 = the App cannot mint for the repo, 75 = the clone failed or timed out,
#   4 = this box does not mint App tokens (no process is run).
#   FAKE (tests): appends `clone repos/<owner/repo>` to <fake>/.calls and copies
#   <fake>/clone__<owner>__<repo>/ into <dest>, then commits it into a fresh
#   local repo (a real clone is a git checkout; no network). No such dir: rc 3.
#   REAL: gh_auth_armed, gh_app_only_for, then `git clone` under `timeout
#   $(og_clone_timeout)`. The App token rides an exported GIT_CONFIG_VALUE_0
#   http.extraHeader inside a subshell: never argv, never the URL, never
#   .git/config. git output goes to /dev/null. Then the origin remote is
#   removed and gh_app_only_release runs on every path.
# og_clone_timeout
#   The lane knob HUB_PROBE_REPO_CLONE_TIMEOUT_S (catalog/lanes.d/hub-probe.json)
#   when it is an integer 5..600, else its documented fallback 60.
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

og_clone_timeout() {
  local v="${HUB_PROBE_REPO_CLONE_TIMEOUT_S:-}"
  # Fallback of the knob HUB_PROBE_REPO_CLONE_TIMEOUT_S (catalog/lanes.d/hub-probe.json).
  if [[ "$v" =~ ^[0-9]{1,3}$ ]] && [ "$((10#$v))" -ge 5 ] && [ "$((10#$v))" -le 600 ]; then echo "$((10#$v))"; else echo 60; fi
}

og_clone() {
  local slug="${1:-}" dest="${2:-}" src hdr rc=0
  local re='^[A-Za-z0-9-]{1,39}/[A-Za-z0-9_.-]{1,100}$'
  [ $# -eq 2 ] && [[ "$slug" =~ $re ]] || return 2
  case "${slug#*/}" in .|..) return 2 ;; esac
  [ -d "$dest" ] && [ -z "$(ls -A "$dest" 2>/dev/null)" ] || return 2
  if [ -n "${ONBOARD_GITHUB_FAKE:-}" ]; then
    printf 'clone repos/%s\n' "$slug" >> "$ONBOARD_GITHUB_FAKE/.calls"
    src="$ONBOARD_GITHUB_FAKE/clone__${slug//\//__}"
    [ -d "$src" ] || return 3
    cp -R "$src"/. "$dest"/ || return 3
    ( cd "$dest" && export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 && git init -q && git add -A \
      && git -c user.name=fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false commit -qm fixture ) \
      >/dev/null 2>&1 || return 3
    return 0
  fi
  declare -F gh_auth_armed gh_app_only_for gh_app_only_release >/dev/null 2>&1 \
    || . "${BASH_SOURCE[0]%/*}/gh-app-auth.sh" || return 4
  gh_auth_armed || return 4
  gh_app_only_for "$slug" || return 44
  hdr=$(printf 'x-access-token:%s' "${GH_TOKEN:-}" | base64 | tr -d '\n')
  ( export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraHeader GIT_CONFIG_VALUE_0="Authorization: Basic $hdr" \
      GIT_TERMINAL_PROMPT=0
    timeout "$(og_clone_timeout)" git clone -q --depth 1 --single-branch --no-tags -- \
      "https://github.com/$slug.git" "$dest" ) >/dev/null 2>&1 || rc=75
  hdr=""
  gh_app_only_release
  [ "$rc" = 0 ] || return 75
  git -C "$dest" remote remove origin >/dev/null 2>&1 || return 75
  return 0
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
