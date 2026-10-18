# shellcheck shell=bash
# bin/lib/docker-pool-token.sh — GitHub App token rotation for a docker-pool
# build that runs past 1 hour (BH-7348, BH-7300 slice C2). The pull-mode copy
# of bin/fly-pool.sh rotate_gh_token: the docker host mints the token itself
# and writes the file the container reads, so nothing is pushed in. Contract:
# docs/notes/2026-10-17-BH-7348-docker-pool-results.md.
#
#   docker_pool_token_rotate <owner/repo> <env-dir> <state-file>
#       called by the host runner from its heartbeat loop. Always rc 0. Prints
#       one word line:
#         off <why>    GH_APP_TOKENS=0, switch gh-app-tokens-off, switch
#                      gh-app-rotate-off, GH_APP_ROTATE=0, no executable
#                      bin/gh-token.sh, or a missing argument
#         no-expiry    the state file has no expires_at (a PAT build)
#         not-due      more than POOL_GH_TOKEN_ROTATE_BEFORE (1200) s left, or
#                      rotated less than POOL_GH_TOKEN_ROTATE_EVERY (1800) s ago
#         no-fresher   the mint gave no token, or no expiry later than the old
#                      one (bin/gh-token.sh prints the PAT when a mint fails)
#         rotated <expires_at>
#                      <env-dir>/gh-token and gh-installation-id written (mode
#                      600, temp file + mv), GH_TOKEN in <env-dir>/global.env
#                      synced when that file exists, the state file stamped
#         keep <why>   the mint was good but a write failed; the old token stays
#                      and the state file is not stamped, so the next beat
#                      tries again
#   <state-file> holds two key=value lines, expires_at and rotated_at (ISO, Z).
#   It never holds the token. The token never goes to argv, stdout or a log.
#   The mint is bin/gh-token.sh [--app $POOL_GH_APP_PROFILE] --min-life
#   $POOL_GH_TOKEN_MIN_LIFE (3300) <owner/repo>. DOCKER_POOL_TOKEN_NOW (epoch
#   seconds) pins the clock for a test.
#
# The harness root is ${HARNESS:-${H:-}}. Defines functions only. Nothing runs
# on source.

# _dpt_switch <name> — rc 0 when the kill switch is on (bin/lib/lane-switch.sh).
_dpt_switch() {
  local root="${HARNESS:-${H:-}}"
  # shellcheck source=bin/lib/lane-switch.sh
  command -v lane_switch >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/lane-switch.sh" 2>/dev/null \
    || lane_switch() { [ -n "${HARNESS:-${H:-}}" ] && [ -e "${HARNESS:-${H:-}}/flags/$1" ]; }
  HARNESS="$root" lane_switch "$1"
}

# _dpt_get <state-file> <key> — the value of key=, or nothing.
_dpt_get() { sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -n 1; }

# _dpt_put <dir> <name> <value> — writes <dir>/<name> through a temp file in
# the same dir (umask 077, then mv). The value goes through printf, a builtin.
_dpt_put() {
  local tf
  tf=$(umask 077 && mktemp "$1/.$2.XXXXXX" 2>/dev/null) || return 1
  if ( umask 077 && printf '%s\n' "$3" > "$tf" ) 2>/dev/null && chmod 600 "$tf" && mv -f "$tf" "$1/$2"; then return 0; fi
  rm -f "$tf"; return 1
}

docker_pool_token_rotate() {
  local slug="${1:-}" envd="${2:-}" sf="${3:-}" root="${HARNESS:-${H:-}}"
  local now expat exp rotat rot tok newexp nexp ninst ml="${POOL_GH_TOKEN_MIN_LIFE:-3300}"
  local before="${POOL_GH_TOKEN_ROTATE_BEFORE:-1200}" every="${POOL_GH_TOKEN_ROTATE_EVERY:-1800}"
  local -a app=()
  if [ -z "$slug" ] || [ -z "$envd" ] || [ -z "$sf" ] || [ -z "$root" ]; then echo "off missing-argument"; return 0; fi
  [ "${GH_APP_TOKENS:-1}" = 0 ] && { echo "off GH_APP_TOKENS=0"; return 0; }
  _dpt_switch gh-app-tokens-off && { echo "off gh-app-tokens-off"; return 0; }
  _dpt_switch gh-app-rotate-off && { echo "off gh-app-rotate-off"; return 0; }
  [ "${GH_APP_ROTATE:-1}" = 0 ] && { echo "off GH_APP_ROTATE=0"; return 0; }
  [ -x "$root/bin/gh-token.sh" ] || { echo "off no-gh-token"; return 0; }
  [ -d "$envd" ] || { echo "off no-env-dir"; return 0; }
  expat=$(_dpt_get "$sf" expires_at)
  [ -n "$expat" ] || { echo no-expiry; return 0; }
  exp=$(date -u -d "$expat" +%s 2>/dev/null) || { echo no-expiry; return 0; }
  now="${DOCKER_POOL_TOKEN_NOW:-$(date -u +%s)}"
  [ "$((exp - now))" -le "$before" ] || { echo not-due; return 0; }
  # Once per 30 min. Without this a build whose push keeps failing would buy a
  # token on every beat for the rest of its life.
  rotat=$(_dpt_get "$sf" rotated_at)
  if [ -n "$rotat" ]; then
    rot=$(date -u -d "$rotat" +%s 2>/dev/null) || rot=0
    [ "$((now - rot))" -ge "$every" ] || { echo not-due; return 0; }
  fi
  case "${POOL_GH_APP_PROFILE:-}" in ''|hub|*[!a-z0-9-]*) ;; *) app=(--app "$POOL_GH_APP_PROFILE") ;; esac
  tok=$("$root/bin/gh-token.sh" ${app[@]+"${app[@]}"} --min-life "$ml" "$slug" 2>/dev/null | tr -d ' \t\r\n') || tok=""
  newexp=$("$root/bin/gh-token.sh" ${app[@]+"${app[@]}"} --min-life "$ml" --expires-at "$slug" 2>/dev/null | tr -d ' \t\r\n') || newexp=""
  nexp=0; [ -n "$newexp" ] && nexp=$(date -u -d "$newexp" +%s 2>/dev/null) || nexp=0
  if [ -z "$tok" ] || [ "$nexp" -le "$exp" ]; then tok=""; echo no-fresher; return 0; fi
  ninst=$("$root/bin/gh-token.sh" ${app[@]+"${app[@]}"} --min-life "$ml" --installation-id "$slug" 2>/dev/null | tr -d ' \t\r\n') || ninst=""
  case "$ninst" in *[!0-9]*) ninst="" ;; esac
  if ! _dpt_put "$envd" gh-token "$tok"; then tok=""; echo "keep token-write-failed"; return 0; fi
  tok=""
  if [ -n "$ninst" ]; then _dpt_put "$envd" gh-installation-id "$ninst" || true; else rm -f "$envd/gh-installation-id"; fi
  if [ -f "$envd/global.env" ]; then
    # shellcheck source=bin/lib/gh-token-live.sh
    { declare -F gh_token_live_sync_env >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/gh-token-live.sh" 2>/dev/null; } \
      && HARNESS="$root" gh_token_live_sync_env "$envd/global.env" >/dev/null 2>&1 || true
  fi
  # The state file carries the 30-min floor: no stamp means the next beat tries again.
  if ! printf 'expires_at=%s\nrotated_at=%s\n' "$newexp" "$(date -u -d "@$now" +%Y-%m-%dT%H:%M:%SZ)" > "$sf.tmp" 2>/dev/null \
     || ! mv -f "$sf.tmp" "$sf"; then
    rm -f "$sf.tmp"; echo "keep state-write-failed"; return 0
  fi
  echo "rotated $newexp"
}
