# shellcheck shell=bash
# bin/lib/dequeue-watch/provider-memo.sh — BH-10218 W3: dequeue-watch keeps
# each repo's merge-queue provider word, so a tick reads `.mergify.yml` and the
# rulesets only after a push to the default branch or after a backstop age.
# Sourced by bin/dequeue-watch.sh, never run.
#
# WHY. The hub ledger (2026-11-26 10:00Z-10:33Z): dequeue-watch spent 48
# `contents/.mergify.yml` and 11 `rulesets` GETs in 33 minutes, about 110 an
# hour. The two caches under mc_queue_provider do not hold them: the provider
# word file in $MC_H/tmp lives one tick (MC_QUEUE_TTL), and the policy cache
# (bin/lib/gh-policy-cache.sh) keeps only a positive 2xx, so a repo with no
# .mergify.yml (GitHub's 404) is read again every tick. The config lives in the
# default branch, and a push to it is a `push` wake (wakeOf, core.js).
#
#   dqw_provider <owner/repo>  prints github | mergify | none | unknown
#     SERVE the stored word when the store
#     state/dequeue-watch/provider/<owner_repo> (`<word>\t<epoch>\t<mark>`)
#     holds github, mergify or none, its age is below DQW_PROVIDER_BACKSTOP_S,
#     and rcm_moved (bin/lib/repo-change-mark.sh) says no push wake arrived
#     above <mark>. A pr, checks or repo wake does not void it.
#     ELSE call mc_queue_provider (its reads go through mc_policy_get ->
#     gh_policy_read -> gh_rest, ETag on, so an unchanged file with a stored
#     ETag answers 304, which GitHub does not count). The store is written ONLY
#     when that call made a REAL read: mc_queue_provider rewrote its provider
#     file in this call (it writes that file only after a 200 or GitHub's 404),
#     the file holds the word printed, and the mark was read BEFORE the call.
#     A last-known-good answer after a failed read (BH-2275), `unknown`, a
#     provider-file hit and a mark the feed cannot give write nothing, and the
#     store is removed, so the next tick asks again.
#
# KNOB: DQW_PROVIDER_BACKSTOP_S (catalog/lanes.d/dequeue-watch.knobs.d/,
# settings row lane.dequeue-watch.dqw_provider_backstop_s; lane_env_apply
# exports it). 0 = no store: every tick asks mc_queue_provider, as before
# BH-10218. Not a number = the code fallback below. DQW_NOW is the lane's
# sandbox-only clock seam.
#
# The store is a cache: losing it costs one read per repo. One file per repo,
# bounded by the fleet's repo count. The root is ${HARNESS:-${H:-}} and
# nothing else. No `set -e`, no `exit`.
if [ -n "${DQW_PROVIDER_MEMO_LIB:-}" ]; then return 0 2>/dev/null; fi
DQW_PROVIDER_MEMO_LIB=1
DQW_PROVIDER_BACKSTOP_DEFAULT=21600   # fallback only: the knob is DQW_PROVIDER_BACKSTOP_S in catalog/lanes.d/dequeue-watch.knobs.d/
# shellcheck source=bin/lib/repo-change-mark.sh
declare -F rcm_moved >/dev/null 2>&1 || . "$(dirname "${BASH_SOURCE[0]}")/../repo-change-mark.sh" 2>/dev/null

_dqwp_now() {
  if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [[ "${DQW_NOW:-}" =~ ^[0-9]+$ ]]; then
    printf '%s' "$((10#$DQW_NOW))"
  else date -u +%s; fi
}
dqw_provider_backstop() {
  local v="${DQW_PROVIDER_BACKSTOP_S:-}"
  [[ "$v" =~ ^[0-9]{1,9}$ ]] || v="$DQW_PROVIDER_BACKSTOP_DEFAULT"
  printf '%s' "$((10#$v))"
}
_dqwp_file() { # <owner/repo> — rc 1 no root or not owner/repo
  local root="${HARNESS:-${H:-}}"
  [ -n "$root" ] || return 1
  [[ "${1:-}" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || return 1
  printf '%s/state/dequeue-watch/provider/%s' "$root" "$(printf '%s' "${1//\//_}" | tr 'A-Z' 'a-z')"
}
# _dqwp_pfile_sig <file> — what changes when mc_queue_provider rewrites its
# provider file: the full mtime and the inode. Empty when there is no file.
_dqwp_pfile_sig() { stat -c '%y %i' "$1" 2>/dev/null; }

dqw_provider() {
  local slug="${1:-}" f back now w ep mk rc mark pf b4 af word
  if ! f=$(_dqwp_file "$slug"); then mc_queue_provider "$slug"; return; fi
  back=$(dqw_provider_backstop)
  now=$(_dqwp_now)
  if [ "$back" -gt 0 ] && IFS=$'\t' read -r w ep mk _ 2>/dev/null < "$f"; then
    case "$w" in
      github|mergify|none)
        if [[ "$ep" =~ ^[0-9]{1,12}$ ]] && [[ "${mk:-}" =~ ^[0-9]{1,18}$ ]] \
           && [ $((now - ep)) -ge 0 ] && [ $((now - ep)) -lt "$back" ]; then
          rc=0; rcm_moved "$slug" push "$mk" "$ep" >/dev/null 2>&1 || rc=$?
          [ "$rc" = 1 ] && { printf '%s' "$w"; return 0; }
        fi ;;
    esac
  fi
  mark=$(rcm_mark "$slug" 2>/dev/null) || mark=""
  now=$(_dqwp_now)
  pf=""; [ -n "${MC_H:-}" ] && pf="$MC_H/tmp/merge-queue-${slug//\//_}.provider"
  b4=""; [ -n "$pf" ] && b4=$(_dqwp_pfile_sig "$pf")
  word=$(mc_queue_provider "$slug" 2>/dev/null)
  af=""; [ -n "$pf" ] && af=$(_dqwp_pfile_sig "$pf")
  if [ "$back" -gt 0 ] && [[ "$mark" =~ ^[0-9]{1,18}$ ]] && [ -n "$af" ] && [ "$af" != "$b4" ] \
     && [ "$(cat "$pf" 2>/dev/null)" = "$word" ]; then
    case "$word" in
      github|mergify|none)
        if mkdir -p "${f%/*}" 2>/dev/null \
           && printf '%s\t%s\t%s\n' "$word" "$now" "$mark" > "$f.tmp.$$" 2>/dev/null \
           && mv -f "$f.tmp.$$" "$f" 2>/dev/null; then :; else rm -f "$f" 2>/dev/null; fi
        rm -f "$f.tmp.$$" 2>/dev/null ;;
      *) rm -f "$f" 2>/dev/null ;;
    esac
  else
    rm -f "$f" 2>/dev/null
  fi
  printf '%s' "$word"
}
