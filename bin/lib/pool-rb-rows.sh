#!/bin/bash
# bin/lib/pool-rb-rows.sh — conductor rebase rows (RB-<pr>-<head8>) in the pool
# SPAWN walk of bin/fly-pool.sh (BH-7643).
#
# hotfix_first walks RB rows right after hotfix rows (BH-7642), and an RB row
# skips the tick-time budget. With no limit, RB rows that piled up over ticks
# took every budget slot and ticket builds waited. And a row whose PR was
# merged or closed in the meantime still got a machine (project-6 #1924, #2005).
#
#   pool_rb_max_per_tick
#       prints the most RB rows the walk spawns in one tick, from
#       POOL_RB_MAX_PER_TICK (0 = no limit). A value that is not a number in
#       0..1000 prints the fallback 4 and says one line.
#   pool_rb_pr_state <pr-number>
#       sets _PRB_ST to open|closed|merged|unknown and _PRB_WHY to the reason
#       of an unknown. Caller's shell, never `$( )`: the answer is cached in
#       _POOL_RB_PR_ST for the rest of the process, so a tick reads each PR
#       once, and a pool-decide worker forked later inherits the cache.
#       No read (unknown) when the number is not a number or the pool's
#       GitHub gates do not apply (no slug, no gh, a repo no credential sees).
#   pool_rb_close_if_pr_closed <job-file> <key> <ticket-id>
#       rc 0: the PR is closed or merged. The row is closed `done` with the
#       reason `empty: pr-closed (PR #<n> <state>)` and the queue file is
#       removed. The caller starts no machine.
#       rc 1: spawn as before. An unknown state fails open, with one line per
#       key. A row whose rebase.slug is not the pool's slug is not read.
#
# Needs from the caller: say, POOL_SLUG, POOL_SLUG_TOK, pool_gates_applicable,
# pool_rest_read, QROW. A missing helper reads as "unknown" (spawn as before).

declare -gA _POOL_RB_PR_ST=() _POOL_RB_PR_WHY=() _POOL_RB_SAID=()
_PRB_ST=""; _PRB_WHY=""

_pool_rb_say() { if declare -F say >/dev/null 2>&1; then say "$@"; else echo "$*" >&2; fi; }

pool_rb_max_per_tick() {
  # Settings row lane.fly-pool.pool_rb_max_per_tick
  # (catalog/lanes.d/fly-pool.knobs.d/POOL_RB_MAX_PER_TICK.json); 4 is its
  # documented fallback.
  local v="${POOL_RB_MAX_PER_TICK:-}"
  [ -n "$v" ] || { echo 4; return 0; }
  case "$v" in
    *[!0-9]*) v="" ;;
    *) if [ "${#v}" -gt 4 ] || [ "$((10#$v))" -gt 1000 ]; then v=""; else v=$((10#$v)); fi ;;
  esac
  if [ -z "$v" ]; then
    _pool_rb_say "POOL_RB_MAX_PER_TICK=$POOL_RB_MAX_PER_TICK is not a number of rows (0-1000) — using 4"
    v=4
  fi
  echo "$v"
}

pool_rb_pr_state() {
  local n="${1:-}" out code body st
  _PRB_ST=unknown; _PRB_WHY=""
  case "$n" in ''|*[!0-9]*) _PRB_WHY="ticket id '$n' is not a PR number"; return 0 ;; esac
  if [ -n "${_POOL_RB_PR_ST[$n]+x}" ]; then
    _PRB_ST=${_POOL_RB_PR_ST[$n]}; _PRB_WHY=${_POOL_RB_PR_WHY[$n]}; return 0
  fi
  if ! command -v pool_rest_read >/dev/null 2>&1 \
     || ! command -v pool_gates_applicable >/dev/null 2>&1 || ! pool_gates_applicable; then
    _PRB_WHY="no repo slug, no gh, or no credential sees the repo: no PR read"; return 0
  fi
  out=$(pool_rest_read "repos/$POOL_SLUG/pulls/$n" "${POOL_SLUG_TOK:-}")
  code=$(head -n 1 <<<"$out")
  case "$out" in *$'\n'*) body=${out#*$'\n'} ;; *) body="" ;; esac
  if [ "$code" = 200 ]; then
    st=$(jq -r 'if type == "object" then "\(.state) \(.merged == true)" else "" end' <<<"$body" 2>/dev/null)
    case "$st" in
      "open "*)     _PRB_ST=open ;;
      "closed true") _PRB_ST=merged ;;
      "closed false") _PRB_ST=closed ;;
      *)            _PRB_WHY="read answered 200 with no known state" ;;
    esac
  else
    _PRB_WHY="read answered ${code:-no status line}"
  fi
  _POOL_RB_PR_ST[$n]=$_PRB_ST; _POOL_RB_PR_WHY[$n]=$_PRB_WHY
  return 0
}

pool_rb_close_if_pr_closed() {
  local jf="${1:-}" key="${2:-}" tid="${3:-}" slug
  slug=$(jq -r '.rebase.slug // ""' "$jf" 2>/dev/null)
  if [ -n "$slug" ] && [ "$slug" != "${POOL_SLUG:-}" ]; then
    _PRB_ST=unknown; _PRB_WHY="the row's repo $slug is not the pool's ${POOL_SLUG:-(none)}"
  else
    pool_rb_pr_state "$tid"
  fi
  case "$_PRB_ST" in
    closed|merged)
      command -v QROW >/dev/null 2>&1 && QROW done "$key" "empty: pr-closed (PR #$tid $_PRB_ST)"
      rm -f -- "$jf"
      _pool_rb_say "$key: PR #$tid is $_PRB_ST — row closed empty (pr-closed), queue file removed, no machine"
      return 0 ;;
    unknown)
      [ -n "${_POOL_RB_SAID[$key]+x}" ] || _pool_rb_say "$key: PR #$tid state unreadable ($_PRB_WHY) — spawning as before"
      _POOL_RB_SAID[$key]=1 ;;
  esac
  return 1
}
