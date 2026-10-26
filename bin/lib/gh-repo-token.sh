#!/bin/bash
# bin/lib/gh-repo-token.sh — which gh credential can SEE a repo, and the alert
# that fires when none can. Sourced, never executed.
#
# THE SILENCE THIS KILLS (2026-09-12, the 10-hour project-5 loss). The hub's
# default PAT 404s on example-org/project-5. Every consumer that listed or viewed
# PRs there got an empty answer with `2>/dev/null`, ran an empty loop, and
# logged nothing — six Fable-approved PRs sat unmerged for days and no line
# anywhere said "this repo is invisible to this token". #254 gave merge-sweep a
# per-repo admin-token fallback; this file is that fallback for every OTHER
# consumer, plus the rule that a repo NO credential can see is an ALERT, never a
# quiet skip. bin/merge-sweep.sh keeps its own inline copy of the probe on
# purpose: the fixtures copy that script standalone into a scratch tree.
#
# THE LADDER IS app -> default -> admin (BH-765, 2026-09-18). It used to be two
# rungs, so every consumer that met a repo the default PAT cannot see spent the
# ONE org-admin PAT and its one 5000/h account bucket — while the App
# installation token (per installation, 6600/h on this one, minted and cached on
# disk by bin/gh-token.sh) was never asked. The App rung is tried first when
# this box is armed for it.
#
#   gh_repo_token_for <owner/repo>      -> prints app | default | admin | none (cached per process)
#   gh_repo_pat_for <owner/repo>        -> prints default | admin | none: the PAT-ONLY question,
#                                          for a consumer whose sentence is about the PATs
#                                          (bin/claude-auth-check.sh's canary)
#   gh_repo_use_token <owner/repo>      -> exports GH_TOKEN for the credential that can see it;
#                                          rc 1 (default token restored) when none can
#   gh_repo_token_reset                 -> restore the caller's default GH_TOKEN
#   gh_repo_tried_words <owner/repo>    -> one clause per rung, in words a human can act on
#   gh_repo_invisible_alert <lane> <owner/repo> <what was skipped>
#                                       -> ONE ALERTS.log line + fleet_alert beat per
#                                          (lane, repo) per day, naming which token
#                                          cannot see it, whether the admin one can,
#                                          and what each of the three rungs answered
#   gh_repo_list_failed <lane> <owner/repo> <what was skipped>
#                                       -> a failed `gh pr list`: invisible repo ->
#                                          the alert above; anything else -> one line
#                                          in logs/<lane>.log (transient weather is
#                                          not a page, but it is never silent either).
#                                          That transient branch — and ONLY it —
#                                          bumps the consecutive-blind counter
#                                          below and pages ONCE at N.
#   gh_repo_list_ok <lane> <owner/repo> -> a list that finally worked: one
#                                          "recovered" line and the counter cleared
#   gh_repo_current_rung                -> app | default | admin | unknown
#   gh_repo_next_rung <owner/repo>      -> exports GH_TOKEN for the next rung the
#                                          ladder can reach for THIS repo and prints
#                                          its WORD; rc 1 (env untouched) when there
#                                          is no next rung
#
# N BLIND TICKS ARE A PAGE, ONE TICK IS A LOG LINE (BH-847). One failed list is
# weather. The 2026-09-12 shape was a lane blind for hours, writing the same
# transient line every tick, which reads exactly like a lane that hiccuped once.
# So a transient failed list bumps a per-(lane, repo) counter under
# state/blind-list/, and at N consecutive ticks ONE ALERTS.log line and one beat
# say how long it has been blind and what that blocks. Further ticks are silent;
# the first successful list writes one "recovered" line and clears it. The two
# failures that ALREADY page — a repo no credential can see, an exhausted API
# bucket — keep their own single line and never touch the counter, because two
# pages for one cause is the noise this was built to remove.
# N resolves `setting_get blind_ticks_alert` -> BLIND_TICKS_ALERT -> 3.
# "Consecutive" has a window (`setting_get blind_ticks_window_secs` ->
# BLIND_TICKS_WINDOW_SECS -> 7200): a failure two hours after the last one starts
# a new streak AND drops the dedupe flag, so a lane that never calls
# gh_repo_list_ok can neither accumulate a stale count across unrelated days nor
# be muted for ever by one page.
#
# AN `app` VERDICT IS PERISHABLE, A PAT VERDICT IS NOT. "The admin PAT can see
# this repo" is a fact about access and holds for the life of the process. "The
# App token can see it" is a fact about a credential GitHub kills in an hour, so
# that verdict ages out after GHRT_TOKEN_MIN_LIFE seconds (default 1800) and is
# re-probed — a long-lived process (the fly-pool reap loop, the conductor) would
# otherwise hand out a token that expired two hours ago.
#
# THE CYCLE, AND THE ONE VARIABLE THAT BREAKS IT. bin/gh-token.sh's `pat_for`
# sources THIS file (it is the one answer to "which PAT can see this repo", never
# a second copy), and the App rung below runs bin/gh-token.sh. Either direction
# alone would recurse until the box runs out of pids, so `_GHRT_NO_APP=1` says
# "answer the PAT question only": this file exports it into every mint it makes,
# and gh-token.sh sets it before it sources this file.
#
# SOURCE IT TWICE AND THE SECOND SOURCE DOES NOTHING. bin/merge-conductor.sh
# sources this file and then bin/lib/merge-conductor-lib.sh, which sources it
# again — after a gh_repo_use_token may already have exported an App token.
# Without the guard the second pass would save THAT token as "the caller's" and
# gh_repo_token_reset would restore an expiring installation token for ever
# after. Same argument, same shape, as bin/lib/gh-app-auth.sh's own guard.
#
# Token values never reach a log, a comment or stdout: only the WORDS app/
# default/admin do. env/github-admin.env is chmod 600 and read by name only.
[ -n "${_GHRT_LOADED:-}" ] && return 0
_GHRT_LOADED=1
_GHRT_H="${HARNESS:-/root/harness}"
# The alert helper beside THIS copy of the library first, then $_GHRT_H/bin (as lane-caps.sh).
_GHRT_AL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/alert-line.sh"
[ -x "$_GHRT_AL" ] || _GHRT_AL="$_GHRT_H/bin/alert-line.sh"
_GHRT_ADMIN_TOK=$(sed -n 's/^\(export \)\{0,1\}GH_ADMIN_TOKEN=//p' "$_GHRT_H/env/github-admin.env" 2>/dev/null | tr -d "\"' \t\r" | head -n 1)
_GHRT_DEFAULT_TOK="${GH_TOKEN:-}"
# Digits only: this value is spent as a CLI argument to bin/gh-token.sh and as a
# number in an age comparison, and an operator knob is not a place to trust.
_GHRT_MIN_LIFE=$(printf '%s' "${GHRT_TOKEN_MIN_LIFE:-1800}" | tr -dc '0-9'); _GHRT_MIN_LIFE="${_GHRT_MIN_LIFE:-1800}"
declare -A _GHRT_REPO_TOK _GHRT_PAT_TOK _GHRT_APP_TOK _GHRT_APP_AT _GHRT_VIA_FILE
if command -v gh_budget_exhausted >/dev/null 2>&1; then :; else
  # shellcheck source=bin/lib/gh-budget.sh
  [ -r "$_GHRT_H/bin/lib/gh-budget.sh" ] && . "$_GHRT_H/bin/lib/gh-budget.sh"
fi
# gh_auth_armed is the App rung's whole off switch, and it is read at LOAD time,
# never lazily inside the probe: a source from inside a loop would capture
# whatever GH_TOKEN that iteration had exported.
if command -v gh_auth_armed >/dev/null 2>&1; then :; else
  # shellcheck source=bin/lib/gh-app-auth.sh
  [ -r "$_GHRT_H/bin/lib/gh-app-auth.sh" ] && . "$_GHRT_H/bin/lib/gh-app-auth.sh"
fi
_ghrt_stamp() { date -u '+%Y-%m-%d %H:%M:%SZ'; }

# rc 0 when this box mints App tokens at all and this call is allowed to ask.
_ghrt_app_armed() {
  [ -n "${_GHRT_NO_APP:-}" ] && return 1
  command -v gh_auth_armed >/dev/null 2>&1 || return 1
  gh_auth_armed
}

# The PAT probe runs with the DEFAULT token pinned (or gh's keyring when none is
# exported), never with whatever GH_TOKEN holds at call time. 2026-09-13,
# review-rescue on project-5: the first gh_repo_use_token exported the admin
# token; mc_git_auth then asked again, the probe ran WITH that admin token,
# passed, was labelled "default", and gh_repo_token_reset put the invisible
# default PAT back — every `gh pr create` after it answered 404. The cache was
# no help: it was filled inside a $(...) subshell and vanished with it, so it
# is filled in the caller's shell here.
# THE DEFAULT RUNG ON A LOGGED-OUT BOX IS env/gh-pat (review round 2 of #2231).
# C2 logs the box keyring out and keeps the plain PAT in env/gh-pat. With no
# GH_TOKEN either, the default probe below went out with NO identity, a private
# repo failed it, and the ADMIN rung answered before the plain PAT was ever
# asked — `gh-token.sh --pat` then printed the org-admin PAT into a Fly bundle.
# So when GH_TOKEN and the keyring are both empty, env/gh-pat (resolved through
# bin/lib/env-path.sh, as bin/gh-token.sh does) is the default rung's token, and
# it is asked BEFORE admin. It is not written into _GHRT_DEFAULT_TOK: that is
# what gh_repo_token_reset restores, and on a C2 box "reset" must leave GH_TOKEN
# unset so the gh shim keeps minting the App token (bin/lib/gh-app-default.sh).
# Only a verdict this token earned (_GHRT_VIA_FILE) exports it. Lazy, once per
# shell: a lane that never probes pays no `gh auth token`.
_ghrt_file_pat() { # -> env/gh-pat's PAT, only when GH_TOKEN and the keyring are both empty.
  # Call it in THIS shell (not $(…)) when the answer must stick: it caches into
  # _GHRT_FILE_PAT, which _ghrt_default_export reads.
  if [ -z "${_GHRT_FILE_PAT_DONE:-}" ]; then
    _GHRT_FILE_PAT_DONE=1; _GHRT_FILE_PAT=""
    if [ -z "$_GHRT_DEFAULT_TOK" ] && [ -z "$(env -u GH_TOKEN -u GITHUB_TOKEN gh auth token 2>/dev/null)" ]; then
      local d f l
      if command -v harness_env_dir >/dev/null 2>&1 || . "$_GHRT_H/bin/lib/env-path.sh" 2>/dev/null; then
        d=$(harness_env_dir "$_GHRT_H")
      else d="$_GHRT_H/env"; fi
      f="$d/gh-pat"
      if [ -r "$f" ]; then
        while IFS= read -r l || [ -n "$l" ]; do
          case "$l" in ''|'#'*) continue ;; esac
          l="${l#export }"; l="${l#GH_TOKEN=}"; l="${l#GH_PAT=}"
          l="${l//\"/}"; l="${l//\'/}"; l="${l//[[:space:]]/}"
          [ -n "$l" ] || continue
          # never let a misfiled admin token become the "plain" rung
          [ -n "$_GHRT_ADMIN_TOK" ] && [ "$l" = "$_GHRT_ADMIN_TOK" ] && break
          _GHRT_FILE_PAT="$l"; break
        done < "$f"
      fi
    fi
  fi
  [ -n "$_GHRT_FILE_PAT" ] || return 1
  printf '%s' "$_GHRT_FILE_PAT"
}
_ghrt_default_export() { # the default rung's identity for <slug> into GH_TOKEN
  if [ "${_GHRT_VIA_FILE[$1]:-}" = 1 ] && [ -n "${_GHRT_FILE_PAT:-}" ]; then export GH_TOKEN="$_GHRT_FILE_PAT"
  else gh_repo_token_reset; fi
}
# _ghrt_plain_pat -> the default rung as an EXPLICIT PAT value, or rc 1 (review
# round 3 of #2231). _GHRT_DEFAULT_TOK, else the keyring, else env/gh-pat; never
# the admin PAT, never an App installation token. gh_repo_use_pat exports THIS
# rather than resetting: an unset GH_TOKEN is no longer "the keyring PAT" on a
# C2 box, it is "the App" — the gh shim and gh_rest's gate both mint one for
# repos/example-org/* — and Mergify ignores `@mergifyio …` authored by the App.
_ghrt_plain_pat() {
  local t=""
  if [ -n "$_GHRT_DEFAULT_TOK" ]; then t="$_GHRT_DEFAULT_TOK"
  else
    t=$(env -u GH_TOKEN -u GITHUB_TOKEN gh auth token 2>/dev/null | tr -d ' \t\r\n')
    [ -n "$t" ] || { _ghrt_file_pat >/dev/null; t="${_GHRT_FILE_PAT:-}"; }
  fi
  [ -n "$t" ] || return 1
  [ -n "$_GHRT_ADMIN_TOK" ] && [ "$t" = "$_GHRT_ADMIN_TOK" ] && return 1
  case "$t" in ghs_*) return 1 ;; esac
  printf '%s' "$t"
}
# BH-8457: THE PROBE MEMO. The `gh api repos/<slug>` visibility GET answers the
# same thing on every tick, and each conductor tick is a new process, so the
# shell arrays above never carry it from one tick to the next. With
# _GHRT_PROBE_MEMO_DIR set (bin/merge-conductor.sh sets it), each rung's
# verdict WORD is kept in <dir>/<slug>.<app|pat> as `<epoch>\t<word>` for
# _GHRT_PROBE_MEMO_TTL_S seconds (the conductor passes its knob
# MC_REPO_PROBE_TTL_S; 300 here is the fallback; 0 = off). A word, never a
# token. `none` is never stored, so an invisible repo is probed (and alerted)
# as before. Unset dir = no memo, which is every other lane.
_GHRT_PROBE_MEMO_TTL_DEFAULT=300   # fallback only: the knob is MC_REPO_PROBE_TTL_S in catalog/lanes.d/merge-conductor.knobs.d/
_ghrt_memo_file() { # <slug> <app|pat>
  [ -n "${_GHRT_PROBE_MEMO_DIR:-}" ] || return 1
  printf '%s/%s.%s' "$_GHRT_PROBE_MEMO_DIR" "$(printf '%s' "${1//\//_}" | tr -cd 'A-Za-z0-9._-')" "$2"
}
_ghrt_memo_ttl() {
  local t="${_GHRT_PROBE_MEMO_TTL_S:-$_GHRT_PROBE_MEMO_TTL_DEFAULT}"
  [[ "$t" =~ ^[0-9]{1,9}$ ]] || t=$_GHRT_PROBE_MEMO_TTL_DEFAULT
  printf '%s' "$((10#$t))"
}
_ghrt_memo_get() { # <slug> <app|pat> -> the stored word, rc 1 when none is fresh
  local f ep v now ttl
  f=$(_ghrt_memo_file "$1" "$2") || return 1
  ttl=$(_ghrt_memo_ttl); [ "$ttl" -gt 0 ] || return 1
  IFS=$'\t' read -r ep v < "$f" 2>/dev/null || return 1
  [[ "$ep" =~ ^[0-9]{1,12}$ ]] || return 1
  now=$(date +%s)
  [ $((now - ep)) -ge 0 ] && [ $((now - ep)) -lt "$ttl" ] || return 1
  case "$v" in app|default|default-file|admin) printf '%s' "$v" ;; *) return 1 ;; esac
}
_ghrt_memo_put() { # <slug> <app|pat> <word>
  local f
  case "${3:-}" in app|default|default-file|admin) ;; *) return 0 ;; esac
  f=$(_ghrt_memo_file "$1" "$2") || return 0
  [ "$(_ghrt_memo_ttl)" -gt 0 ] || return 0
  mkdir -p "$_GHRT_PROBE_MEMO_DIR" 2>/dev/null || return 0
  printf '%s\t%s\n' "$(date +%s)" "$3" > "$f.$$" 2>/dev/null && mv -f "$f.$$" "$f" 2>/dev/null
  rm -f "$f.$$" 2>/dev/null
  return 0
}
_ghrt_pat_probe() { # _ghrt_pat_probe <owner/repo> -> fills _GHRT_PAT_TOK[slug] in THIS shell
  # The no-token probe runs with GH_USE_PAT=1 (round 3): through the gh shim an
  # unset GH_TOKEN would otherwise be answered by the App, and "default" here
  # means a PAT can see the repo — never "the App can".
  local slug="$1" fp=""
  [ -n "${_GHRT_PAT_TOK[$slug]+x}" ] && return 0
  # A fresh memo answers without the GET, only while the credential it names
  # is still on this box.
  case "$(_ghrt_memo_get "$slug" pat)" in
    default) _GHRT_PAT_TOK[$slug]="default"; return 0 ;;
    default-file) if _ghrt_file_pat >/dev/null; then _GHRT_PAT_TOK[$slug]="default"; _GHRT_VIA_FILE[$slug]=1; return 0; fi ;;
    admin) if [ -n "$_GHRT_ADMIN_TOK" ]; then _GHRT_PAT_TOK[$slug]="admin"; return 0; fi ;;
  esac
  if { if [ -n "$_GHRT_DEFAULT_TOK" ]; then GH_TOKEN="$_GHRT_DEFAULT_TOK" gh api "repos/$slug" -q .id
       else env -u GH_TOKEN GH_USE_PAT=1 gh api "repos/$slug" -q .id; fi; } >/dev/null 2>&1; then _GHRT_PAT_TOK[$slug]="default"
  elif _ghrt_file_pat >/dev/null && fp="$_GHRT_FILE_PAT" && GH_TOKEN="$fp" gh api "repos/$slug" -q .id >/dev/null 2>&1; then
    _GHRT_PAT_TOK[$slug]="default"; _GHRT_VIA_FILE[$slug]=1
  elif [ -n "$_GHRT_ADMIN_TOK" ] && GH_TOKEN="$_GHRT_ADMIN_TOK" gh api "repos/$slug" -q .id >/dev/null 2>&1; then _GHRT_PAT_TOK[$slug]="admin"
  else _GHRT_PAT_TOK[$slug]="none"; fi
  if [ "${_GHRT_PAT_TOK[$slug]}" = default ] && [ "${_GHRT_VIA_FILE[$slug]:-}" = 1 ]; then _ghrt_memo_put "$slug" pat default-file
  else _ghrt_memo_put "$slug" pat "${_GHRT_PAT_TOK[$slug]}"; fi
}
# rc 0 ONLY when an App installation token exists AND sees this repo. Every
# other answer falls through to the PATs with nothing exported and nothing
# cached: an unarmed box spawns no process at all, and a mint that printed a PAT
# (which is exactly what bin/gh-token.sh does when a mint fails) is refused —
# labelling that `app` would put a lie in an alert.
_ghrt_app_probe() { # _ghrt_app_probe <owner/repo>
  local slug="$1" tok=""
  _ghrt_app_armed || return 1
  tok=$(_GHRT_NO_APP=1 "$_GHRT_H/bin/gh-token.sh" --min-life "$_GHRT_MIN_LIFE" "$slug" 2>/dev/null) || return 1
  [ -n "$tok" ] || return 1
  [ "$tok" = "$_GHRT_DEFAULT_TOK" ] && return 1
  [ -n "$_GHRT_ADMIN_TOK" ] && [ "$tok" = "$_GHRT_ADMIN_TOK" ] && return 1
  # The token is still minted every time; only the visibility GET is memoed.
  if [ "$(_ghrt_memo_get "$slug" app)" != app ]; then
    GH_TOKEN="$tok" gh api "repos/$slug" -q .id >/dev/null 2>&1 || return 1
    _ghrt_memo_put "$slug" app app
  fi
  _GHRT_APP_TOK[$slug]="$tok"; _GHRT_APP_AT[$slug]=$(date +%s)
  return 0
}
_ghrt_probe() { # _ghrt_probe <owner/repo> -> fills _GHRT_REPO_TOK[slug] in THIS shell
  local slug="$1" now
  if [ -n "${_GHRT_REPO_TOK[$slug]+x}" ]; then
    [ "${_GHRT_REPO_TOK[$slug]}" != app ] && return 0
    now=$(date +%s)
    [ $(( now - ${_GHRT_APP_AT[$slug]:-0} )) -lt "$_GHRT_MIN_LIFE" ] && return 0
    unset "_GHRT_REPO_TOK[$slug]" "_GHRT_APP_TOK[$slug]" "_GHRT_APP_AT[$slug]"
  fi
  if _ghrt_app_probe "$slug"; then _GHRT_REPO_TOK[$slug]="app"; return 0; fi
  _ghrt_pat_probe "$slug"
  _GHRT_REPO_TOK[$slug]="${_GHRT_PAT_TOK[$slug]}"
}
gh_repo_token_for() { # gh_repo_token_for <owner/repo> -> app|default|admin|none
  _ghrt_probe "$1"; printf '%s\n' "${_GHRT_REPO_TOK[$1]}"
}
gh_repo_pat_for() { # gh_repo_pat_for <owner/repo> -> default|admin|none
  _ghrt_pat_probe "$1"; printf '%s\n' "${_GHRT_PAT_TOK[$1]}"
}
gh_repo_token_reset() {
  if [ -n "$_GHRT_DEFAULT_TOK" ]; then export GH_TOKEN="$_GHRT_DEFAULT_TOK"; else unset GH_TOKEN; fi
}
gh_repo_use_token() { # gh_repo_use_token <owner/repo>; rc 1 = nothing can see it
  _ghrt_probe "$1"
  case "${_GHRT_REPO_TOK[$1]}" in
    app)   export GH_TOKEN="${_GHRT_APP_TOK[$1]}"; return 0 ;;
    admin) export GH_TOKEN="$_GHRT_ADMIN_TOK"; return 0 ;;
    default) _ghrt_default_export "$1"; return 0 ;;
    *) gh_repo_token_reset; return 1 ;;
  esac
}
# gh_repo_use_pat <owner/repo> — the PAT ladder ONLY (BH-1668): the default PAT,
# then the admin PAT, NEVER the App rung. For the one write a bot identity cannot
# make: Mergify refuses `@mergifyio queue` from the App ("sender needs write
# permission"). rc 1 = no PAT sees the repo, GH_TOKEN reset. GH_REPO_PAT_RUNG
# names the rung (default|admin|none) for the caller's log line. The caller
# restores its own token afterwards; gh_repo_token_reset is the default PAT.
gh_repo_use_pat() { # an explicit PAT in GH_TOKEN (default, then admin), never unset, never the App
  local _ghrt_pv
  _ghrt_pat_probe "$1"
  GH_REPO_PAT_RUNG="${_GHRT_PAT_TOK[$1]}"
  case "$GH_REPO_PAT_RUNG" in
    default)
      if _ghrt_pv=$(_ghrt_plain_pat); then export GH_TOKEN="$_ghrt_pv"; return 0; fi
      GH_REPO_PAT_RUNG=none; gh_repo_token_reset; return 1 ;;
    admin) export GH_TOKEN="$_GHRT_ADMIN_TOK"; return 0 ;;
    *) gh_repo_token_reset; return 1 ;;
  esac
}
# The admin PAT's own verdict, in words a human can act on. It asks the PAT-only
# question on purpose: the sentence it lands in is about the default gh token.
_ghrt_admin_words() {
  local slug="$1"
  if [ -z "$_GHRT_ADMIN_TOK" ]; then printf 'no admin token on this box (env/github-admin.env absent)'
  elif [ "$(gh_repo_pat_for "$slug")" = admin ]; then printf 'the admin token CAN see it — route this consumer through it'
  else printf 'the admin token cannot see it either'; fi
}
# What each rung actually answered. An alert that says only "invisible" sends an
# operator to guess which of three credentials to fix.
gh_repo_tried_words() { # gh_repo_tried_words <owner/repo>
  local slug="$1" pat app adm
  _ghrt_probe "$slug"; pat=$(gh_repo_pat_for "$slug")
  if [ "${_GHRT_REPO_TOK[$slug]}" = app ]; then app='CAN see it — route this consumer through it'
  elif ! _ghrt_app_armed; then app='not armed on this box'
  else app='could not see it'; fi
  if [ -z "$_GHRT_ADMIN_TOK" ]; then adm='absent on this box (env/github-admin.env)'
  elif [ "$pat" = admin ]; then adm='CAN see it — route this consumer through it'
  else adm='blind'; fi
  printf 'tried the App installation token: %s; the default PAT: %s; the admin PAT: %s' \
    "$app" "$([ "$pat" = default ] && printf 'CAN see it' || printf 'blind')" "$adm"
}
# One alert per (lane, repo, UTC day), deduped by a flag. The hub flag goes
# through bin/lib/flags.sh (flag_has --cached / flag_set, the file
# flags/alerted-repo-invisible-<lane>-<repo>-<YYYYMMDD>); bin/alerts-groom.sh
# prunes old alerted-* days. On a lane-run machine (LANE_RUN_ID set) flags/
# never rides back to the hub, so the flag goes under GHRT_FLAG_DIR when the
# caller sets it to a dir its write-back carries, and flags there older than
# yesterday are pruned by the date in the name. A machine makes no beat.sh
# call: alert-line.sh posts the line to the jobs API and the hub's replay
# notes it.
# _ghrt_flag has|set <name> — bin/lib/flags.sh in a subshell, so the client's
# set -u and env loading never reach the caller. rc 2 when the lib is missing:
# the caller then alerts without the dedup (a repeat, never a lost alert).
_ghrt_flag() {
  ( # shellcheck source=bin/lib/flags.sh
    HARNESS="$_GHRT_H"; . "$(dirname "${BASH_SOURCE[0]}")/flags.sh" 2>/dev/null || exit 2
    # shellcheck disable=SC2034 # read by _flag_dir in bin/lib/jobs/flags.sh
    JOBS_HARNESS="$_GHRT_H"
    case "$1" in
      has) flag_has --cached "$2" 2>/dev/null ;;
      set) flag_set "$2" on "gh-repo-token: repo-invisible alert sent" >/dev/null 2>&1 ;;
      *) exit 2 ;;
    esac )
}
gh_repo_invisible_alert() { # gh_repo_invisible_alert <lane> <owner/repo> <what was skipped>
  local lane="$1" slug="$2" what="$3" name line mdir="" day old f d
  day=$(date -u +%Y%m%d)
  [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [[ "${GHRT_TODAY:-}" =~ ^[0-9]{8}$ ]] && day=$GHRT_TODAY
  name="alerted-repo-invisible-$lane-${slug//\//_}-$day"
  if [ -n "${LANE_RUN_ID:-}" ] && [ -n "${GHRT_FLAG_DIR:-}" ]; then
    mdir=$GHRT_FLAG_DIR
    old=$(date -u -d "$day -1 day" +%Y%m%d 2>/dev/null)
    if [ -n "$old" ]; then
      for f in "$mdir"/alerted-repo-invisible-*; do
        [ -f "$f" ] || continue
        d=${f##*-}
        [[ "$d" =~ ^[0-9]{8}$ ]] && [ "$d" -lt "$old" ] && rm -f "$f"
      done
    fi
    [ -f "$mdir/$name" ] && return 0
    mkdir -p "$mdir" 2>/dev/null
    touch "$mdir/$name"
  else
    _ghrt_flag has "$name" && return 0
    _ghrt_flag set "$name"
  fi
  mkdir -p "$_GHRT_H/logs" 2>/dev/null
  line="repo $slug is INVISIBLE to the default gh token ($(_ghrt_admin_words "$slug")) — $what. This is the 2026-09-12 project-5 shape: an empty PR list that nobody logged. Tried: $(gh_repo_tried_words "$slug")."
  HARNESS="$_GHRT_H" "$_GHRT_AL" "[$lane] $line"
  [ -n "${LANE_RUN_ID:-}" ] && return 0
  "$_GHRT_H/bin/beat.sh" "$(jq -nc --arg akey "repoinvisible:$lane:$slug" --arg l "[$lane] $line" \
    '{kind:"fleet_alert",project:"fleet",akey:$akey,line:$l}')" >/dev/null 2>&1 || true
}
# THE LADDER, IN THE ORDER THE HUB ALREADY PROBES IT: App installation token ->
# default PAT -> admin PAT. The App rung is recognised by ELIMINATION rather than
# by asking the App-auth lib (named in full nowhere in this file on purpose:
# tests/gh-app-ratchet-test.sh reads that filename as "this script arms App
# tokens", and this one does not — it owns the PATs): a token that is neither of
# the two PATs, on a box where minting is armed, is the minted one. That keeps
# the rung API in the file that owns the PATs instead of teaching two files about
# each other.
gh_repo_current_rung() { # -> app|default|admin|unknown
  local tok="${GH_TOKEN:-}"
  if [ -n "$_GHRT_ADMIN_TOK" ] && [ "$tok" = "$_GHRT_ADMIN_TOK" ]; then printf 'admin\n'; return 0; fi
  if [ -z "$tok" ] || [ "$tok" = "$_GHRT_DEFAULT_TOK" ]; then printf 'default\n'; return 0; fi
  if [ -n "${_GHRT_FILE_PAT:-}" ] && [ "$tok" = "$_GHRT_FILE_PAT" ]; then printf 'default\n'; return 0; fi
  if command -v gh_auth_armed >/dev/null 2>&1 && gh_auth_armed; then printf 'app\n'; return 0; fi
  printf 'unknown\n'
}
# THE RUNG WORD COMES BACK IN A VARIABLE, NOT ON STDOUT, because the whole point
# of this function is the export it performs: a caller writing
# `w=$(gh_repo_next_rung ...)` would run it in a subshell and keep the old token.
# It prints the word too, for a human running it by hand.
gh_repo_next_rung() { # gh_repo_next_rung <owner/repo>; rc 1 = no next rung, env untouched
  local slug="${1:-}"
  _GHRT_RUNG=""
  case "$(gh_repo_current_rung)" in
    app)
      # FROM `app` THE NEXT RUNG IS A QUESTION, NOT THE NEXT ITEM IN A LIST. On
      # the 2026-09-12 project-5 shape the default PAT 404s the repo, so stepping
      # to it blindly spends the one retry on a credential that cannot answer and
      # reports the tick blind while admin, which CAN see it, was never tried.
      # The question is the PAT-ONLY one — _ghrt_pat_probe, read out of the cache
      # array in THIS shell. Not `$(gh_repo_pat_for …)`: that fills the cache
      # inside a subshell and loses it. Not gh_repo_token_for: that would re-run
      # the App mint under the very token that is rate-limited.
      if [ -n "$slug" ]; then
        _ghrt_pat_probe "$slug"
        if [ "${_GHRT_PAT_TOK[$slug]:-}" = admin ] && [ -n "$_GHRT_ADMIN_TOK" ]; then
          export GH_TOKEN="$_GHRT_ADMIN_TOK"
          _GHRT_RUNG=admin; printf '%s\n' "$_GHRT_RUNG"; return 0
        fi
      fi
      if [ -n "$slug" ] && [ "${_GHRT_VIA_FILE[$slug]:-}" = 1 ]; then _ghrt_default_export "$slug"
      elif [ -n "$_GHRT_DEFAULT_TOK" ]; then export GH_TOKEN="$_GHRT_DEFAULT_TOK"; else unset GH_TOKEN; fi
      _GHRT_RUNG=default; printf '%s\n' "$_GHRT_RUNG"; return 0 ;;
    default)
      [ -n "$_GHRT_ADMIN_TOK" ] || return 1
      export GH_TOKEN="$_GHRT_ADMIN_TOK"
      _GHRT_RUNG=admin; printf '%s\n' "$_GHRT_RUNG"; return 0 ;;
    *) return 1 ;;
  esac
}

_ghrt_blind_file() { printf '%s/state/blind-list/%s-%s\n' "$_GHRT_H" "$1" "${2//\//_}"; }
_ghrt_blind_flag() { printf '%s/flags/alerted-blindlist-%s-%s\n' "$_GHRT_H" "$1" "${2//\//_}"; }

# BOTH KNOBS RESOLVE settings row -> env var -> code constant, which is the
# order _ghb_resolve_threshold in bin/lib/gh-budget.sh already uses for
# gh_budget_min_remaining: an operator changes the number without a deploy, the
# env template documents the fallback, and the constant is the last word. No seed
# row ships — per docs/verification-map/settings-knobs.md "no row" is a real
# answer that sends a consumer to its fallback. A value that is not a tick count
# says so in the lane's log rather than being silently clamped.
_ghrt_knob() { # _ghrt_knob <setting_key> <ENV_NAME> <default> <lane>
  local key="$1" envname="$2" def="$3" lane="$4" val
  if command -v setting_get >/dev/null 2>&1; then
    val=$(setting_get "$key" 2>/dev/null) || true
    if [ -n "${val:-}" ]; then
      case "$val" in
        *[!0-9]*) : ;;
        *) [ "$val" -ge 1 ] && { printf '%s\n' "$val"; return 0; } ;;
      esac
      mkdir -p "$_GHRT_H/logs" 2>/dev/null
      echo "$(_ghrt_stamp) [$lane] unusable setting $key='$val' — falling back" >> "$_GHRT_H/logs/$lane.log"
    fi
  fi
  val="${!envname:-}"
  if [ -n "$val" ]; then
    case "$val" in
      *[!0-9]*) : ;;
      *) [ "$val" -ge 1 ] && { printf '%s\n' "$val"; return 0; } ;;
    esac
    mkdir -p "$_GHRT_H/logs" 2>/dev/null
    echo "$(_ghrt_stamp) [$lane] $envname='$val' is not a tick count — using $def" >> "$_GHRT_H/logs/$lane.log"
  fi
  printf '%s\n' "$def"
}
_ghrt_blind_threshold() { # _ghrt_blind_threshold <lane>
  _ghrt_knob blind_ticks_alert BLIND_TICKS_ALERT 3 "$1"
}
_ghrt_blind_window() { # _ghrt_blind_window <lane>
  _ghrt_knob blind_ticks_window_secs BLIND_TICKS_WINDOW_SECS 7200 "$1"
}

# Bump the (lane, repo) streak and print "<count> <first_blind_epoch>". A file
# that is missing, corrupt, or older than the window starts a fresh streak: a
# failure two hours after the last one is not "consecutive", and a fresh streak
# also drops the dedupe flag so the new outage can page.
_ghrt_blind_bump() { # _ghrt_blind_bump <lane> <owner/repo> -> "<count> <first_epoch>"
  local lane="$1" slug="$2" f count first last now win fresh=1
  f=$(_ghrt_blind_file "$lane" "$slug")
  now=$(date -u +%s)
  win=$(_ghrt_blind_window "$lane")
  count=0; first="$now"; last=0
  if [ -f "$f" ]; then
    read -r count first last < "$f" 2>/dev/null
    case "${count:-}" in ''|*[!0-9]*) count=0 ;; esac
    case "${first:-}" in ''|*[!0-9]*) first="$now" ;; esac
    case "${last:-}" in ''|*[!0-9]*) last=0 ;; esac
    if [ "$count" -lt 1 ] || [ $((now - last)) -gt "$win" ]; then count=0; first="$now"; else fresh=0; fi
  fi
  # A NEW STREAK DROPS THE DEDUPE FLAG. bin/pipeline-health.sh,
  # bin/pr-owner-sweep.sh and bin/jobs-watchdog.sh report failed lists but never
  # call gh_repo_list_ok, so nothing else would ever remove their flag — it would
  # outlive the counter that justified it and every later outage on that
  # (lane, repo) would be silent for the life of the box. The counter and the
  # flag start together or the page happens once, ever.
  [ "$fresh" = 1 ] && rm -f "$(_ghrt_blind_flag "$lane" "$slug")" 2>/dev/null
  count=$((count + 1))
  mkdir -p "$(dirname "$f")" 2>/dev/null
  printf '%s %s %s\n' "$count" "$first" "$now" > "$f" 2>/dev/null # BLIND-COUNTER-WRITE
  printf '%s %s\n' "$count" "$first"
}

# ONE line, at the Nth tick only. The flag is touched BEFORE the write so a crash
# between them costs a page rather than duplicating one — same order as
# gh_repo_invisible_alert. It is cleared when the streak ENDS (a successful list,
# or a gap wider than the window starting a new one), never at midnight: a lane
# blind across the date boundary pages once, and a lane that recovers and goes
# blind again pages again.
_ghrt_blind_alert() { # _ghrt_blind_alert <lane> <owner/repo> <what> <count> <first_epoch>
  local lane="$1" slug="$2" what="$3" n="$4" first="$5" flag line since
  flag=$(_ghrt_blind_flag "$lane" "$slug")
  [ -f "$flag" ] && return 0
  mkdir -p "$_GHRT_H/flags" "$_GHRT_H/logs" 2>/dev/null
  touch "$flag"
  since=$(date -u -d "@$first" '+%H:%MZ' 2>/dev/null || date -u '+%H:%MZ')
  line="$lane has been blind on $slug for $n consecutive ticks since $since (every PR list failed; rate-limited or unreachable) — no PR on $slug can be enqueued while this holds; last skip: $what"
  HARNESS="$_GHRT_H" "$_GHRT_AL" "[$lane] $line"
  "$_GHRT_H/bin/beat.sh" "$(jq -nc --arg akey "blindlist:$lane:$slug" --arg l "[$lane] $line" \
    '{kind:"fleet_alert",project:"fleet",akey:$akey,line:$l}')" >/dev/null 2>&1 || true
}

gh_repo_list_ok() { # gh_repo_list_ok <lane> <owner/repo>; quiet unless a streak was open
  local lane="${1:-}" slug="${2:-}" f count first last mins
  [ -n "$lane" ] && [ -n "$slug" ] || return 0
  f=$(_ghrt_blind_file "$lane" "$slug")
  [ -f "$f" ] || return 0
  read -r count first last < "$f" 2>/dev/null
  case "${count:-}" in ''|*[!0-9]*) count=0 ;; esac
  case "${first:-}" in ''|*[!0-9]*) first=$(date -u +%s) ;; esac
  rm -f "$f" "$(_ghrt_blind_flag "$lane" "$slug")" 2>/dev/null
  [ "$count" -ge 1 ] || return 0
  mins=$(( ( $(date -u +%s) - first ) / 60 ))
  mkdir -p "$_GHRT_H/logs" 2>/dev/null
  echo "$(_ghrt_stamp) [$lane] list recovered for $slug after $count blind ticks (${mins}m)" >> "$_GHRT_H/logs/$lane.log"
}

gh_repo_list_failed() { # gh_repo_list_failed <lane> <owner/repo> <what was skipped>
  local lane="$1" slug="$2" what="$3" bump count first n
  # THE COUNTER BELONGS TO THE TRANSIENT BRANCH ALONE. An invisible repo and an
  # exhausted API bucket each already page once, with the cause named exactly and
  # the fix in the line. Counting those ticks too would page a SECOND time for
  # the same outage, in the vaguer words "rate-limited or unreachable" — two
  # pages for one cause is the opposite of what this counter is for. So each of
  # them returns here, before the bump, and never reads or writes the counter or
  # the flag.
  if [ "$(gh_repo_token_for "$slug")" = none ]; then
    gh_repo_invisible_alert "$lane" "$slug" "$what"
    return 0
  fi
  if command -v gh_budget_exhausted >/dev/null 2>&1 && gh_budget_exhausted; then
    gh_budget_ratelimit_alert "$lane" "$what"
    return 0
  fi
  mkdir -p "$_GHRT_H/logs" 2>/dev/null
  echo "$(_ghrt_stamp) [$lane] gh pr list failed for $slug (repo is visible; transient?) — $what" >> "$_GHRT_H/logs/$lane.log"
  bump=$(_ghrt_blind_bump "$lane" "$slug")
  count="${bump%% *}"; first="${bump##* }"
  n=$(_ghrt_blind_threshold "$lane")
  [ "$count" -ge "$n" ] && _ghrt_blind_alert "$lane" "$slug" "$what" "$count" "$first"
  return 0
}
