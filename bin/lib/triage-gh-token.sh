#!/bin/bash
# bin/lib/triage-gh-token.sh — a triage tick arms a GitHub App token that
# outlives the tick. Sourced, never executed; defines functions and runs
# nothing on source. Its own file so bin/run-triage.sh stays under the driver
# ceiling (tests/rt-split-layout-test.sh A6).
#
# A TICK IS NOT A MINUTE (project-4, 2026-09-24). The token cache hands a token
# out until 5 minutes before it dies, which is right for a shard and wrong for a
# full tick: those run 10-20 minutes, and the session's `git fetch origin` goes
# through `gh auth git-credential`, i.e. the GH_TOKEN the driver exports. The
# ticks that started at 17:58Z and 18:58Z armed a token with ~7 minutes left and
# stopped on "Invalid username or token" mid-run, four times that day. So the
# driver asks the minter for a token that outlives the tick BEFORE it arms: a
# shorter cached one is re-minted, a longer one is reused, and the arming then
# reads that cache row. gh_app_premint (bin/lib/gh-app-auth.sh) honours the
# App kill switches and is a no-op on a box that does not mint.
#
# TRIAGE_TOKEN_MIN_LIFE (catalog/lanes.d/run-triage.json, default 3000) is the
# life asked for, in seconds. An installation token lives 3600s, so the value
# is held to 300..3500: under 300 is what the cache already guarantees, over
# 3500 would re-mint on every tick. Unparseable text falls back to the default.

# triage_gh_premint <owner/repo> — rc 1 when there is no slug or no minter.
triage_gh_premint() {
  local slug="${1:-}" life="${TRIAGE_TOKEN_MIN_LIFE:-3000}"
  case "$life" in ''|*[!0-9]*) life=3000 ;; esac
  life=$((10#$life))
  [ "$life" -lt 300 ] && life=300
  [ "$life" -gt 3500 ] && life=3500
  [ -n "$slug" ] && command -v gh_app_premint >/dev/null 2>&1 || return 1
  gh_app_premint "$slug" "$life"
}

# triage_gh_session_arm <owner/repo> [project] — BH-9354: put bin/gh-session/gh
# first on this tick's PATH, so every gh the tick's shards and agent sessions
# run re-mints the armed token per call and tries the next credential on a 401
# (the wrapper's header says how). Arms only when GH_TOKEN is a ghs_ App token
# (the box minted it) and GH_SESSION_REMINT is 1 (knob row
# lib.gh-session.gh_session_remint, the off switch); otherwise rc 1 and the env is untouched. The knobs are resolved ONCE
# here (lib_env_apply gh-session, when the shell has it) and exported, so the
# wrapper reads env and never a settings row per call. The token value is never
# exported under a new name: GH_SESSION_TOKEN_FP is a sha256 prefix.
triage_gh_session_arm() {
  local slug="${1:-}" project="${2:-${PROJECT:-}}" h exp
  h="${HARNESS:-${H:-}}"
  [ -n "$slug" ] && [ -n "$h" ] || return 1
  case "${GH_TOKEN:-}" in ghs_*) ;; *) return 1 ;; esac
  [ -x "$h/bin/gh-session/gh" ] || return 1
  # shellcheck source=bin/lib/gh-session-token.sh
  . "${BASH_SOURCE[0]%/*}/gh-session-token.sh" 2>/dev/null || . "$h/bin/lib/gh-session-token.sh" 2>/dev/null || return 1
  command -v lib_env_apply >/dev/null 2>&1 && { lib_env_apply gh-session >/dev/null 2>&1 || true; }
  gh_session_knobs
  [ "$_GSS_REMINT" = 1 ] || return 1
  export GH_SESSION_REMINT="$_GSS_REMINT" GH_SESSION_MIN_LIFE_S="$_GSS_MIN_LIFE" \
         GH_SESSION_MINT_TIMEOUT_S="$_GSS_MINT_TO" GH_SESSION_PROBE_TIMEOUT_S="$_GSS_PROBE_TO" \
         GH_SESSION_ALERT_EVERY_S="$_GSS_ALERT_EVERY" GH_SESSION_PAT_FALLBACK="$_GSS_PAT_FB"
  exp=$(gh_session_mint "$slug" expires-at) || exp=""
  export GH_SESSION_SLUG="$slug" GH_SESSION_PROJECT="$project" \
         GH_SESSION_TOKEN_FP="$(gh_session_tok_fp "$GH_TOKEN")" \
         GH_SESSION_ARMED_AT="$(date -u +%s)" GH_SESSION_EXPIRES_AT="$exp"
  case ":${PATH:-}:" in
    *":$h/bin/gh-session:"*) ;;
    *) export PATH="$h/bin/gh-session${PATH:+:$PATH}" ;;
  esac
  return 0
}
