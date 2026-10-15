#!/bin/bash
# bin/lib/mc-prequeue.d/restamp.sh — THE CONDUCTOR RESTAMPS A READY HEAD'S
# STALE SCHEMA FRAGMENTS BEFORE IT QUEUES IT (BH-6842). Sourced by
# bin/lib/mc-prequeue.sh's hook loop, never executed; no side effect at source time.
#
# pq_gate calls pq_restamp <slug> <num> <head> <main> once PQ_MAIN is read. It
# prints one word line, and pq_gate reads it:
#   none            nothing stale, the knob is off (MC_SCHEMA_RESTAMP=0),
#                   ACTIONS is not 1, the lib is not loaded, or the conductor
#                   has no clone of the repo yet or its origin/main has no stamp
#                   fragment (read with no credential, lock or fetch): proceed
#                   as before
#   pushed <sha> <n>  <n> fragments renamed in one commit on the PR branch; the
#                   push answered 0 AND ls-remote shows <sha>. pq_gate holds; the
#                   new head is asked next tick (bin/lib/lead-carry.sh carries
#                   the lead MERGE onto it through restamp_same)
#   held <why>      the head is stale and was not restamped. pq_gate holds, so a
#                   mis-ordered fragment is never queued
# The work is bin/lib/schema-restamp.sh's (sr_plan, sr_apply), on the conductor's
# clone (mc_funnel_repo) under the project's git lock, in a temp worktree that
# every path removes. The push is hold_push (bin/lib/hold-push.sh): it re-reads
# the ticket's HOLD and leases on <head>, so a branch that moved is refused.
#
# Terminal or not. A held answer whose cause will not change by itself (no
# branch, pool mode, an sr_plan / sr_apply refusal, a push refusal) writes the
# attempts line `restampfail <key> <head> <newest stamp at main>`, one log line
# and one warn mc_alert, and the next tick holds again with no git and no line.
# A new head or a newer fragment on main is a new key. A busy lock, a failed
# fetch, no clone and a HOLD are not terminal: one log line a head, asked again.
#   <key> SCHEMA_RESTAMP <pushed|held|refused> head=<h12> new=<n12|-> main=<m12>
#     renames=<n> reason=<text>
#
# P, BR and KEY are the READY arm's variables (bin/merge-conductor.sh), read the
# way pq_knob reads P.

_pq_rs_dir="${BASH_SOURCE[0]%/*}"

# _pq_rs_knob -> MC_SCHEMA_RESTAMP for this project: the lane knob, else the
#   env, else 1. Anything but 0 is on.
_pq_rs_knob() {
  local v=""
  command -v lane_knob >/dev/null 2>&1 && v=$(lane_knob merge-conductor MC_SCHEMA_RESTAMP "${P:-}" 2>/dev/null)
  [ -n "$v" ] || v="${MC_SCHEMA_RESTAMP:-1}"
  printf '%s' "$v"
}

# _pq_rs_local <slug> -> the clone mc_funnel_repo would use, when it exists
#   already: the hub checkout, else the conductor's own clone. rc 1 = none.
_pq_rs_local() {
  local r="${MC_REPOS:-/root/repos}/${P:-}"
  [ -n "${P:-}" ] && [ -d "$r/.git" ] && { printf '%s' "$r"; return 0; }
  [ -n "${MC_H:-}" ] || return 1
  r="$MC_H/tmp/conductor/${1//\//_}"
  [ -d "$r/.git" ] && { printf '%s' "$r"; return 0; }
  return 1
}

# _pq_rs_line <key> <result> <head> <new> <main> <n> <reason>
_pq_rs_line() { mc_log "$1 SCHEMA_RESTAMP $2 head=${3:0:12} new=${4:0:12} main=${5:0:12} renames=$6 reason=$7"; }

# _pq_rs_held <key> <head> <main> <reason> — transient: one line a head.
_pq_rs_held() {
  mc_attempt_has "restampheld $1 $2" 2>/dev/null || { mc_attempt_put "restampheld $1 $2"; _pq_rs_line "$1" held "$2" - "$3" 0 "$4"; }
  printf 'held %s\n' "$4"
}

# _pq_rs_fail <key> <head> <main> <top> <result> <n> <reason> — terminal.
_pq_rs_fail() {
  mc_attempt_put "restampfail $1 $2 ${4:--}"
  _pq_rs_line "$1" "${5/heldterm/held}" "$2" - "$3" "$6" "$7"
  mc_alert "$1" SCHEMA_RESTAMP "head ${2:0:12} has a schema fragment stamped before main's newest (${4:--}) and the conductor could not restamp it: $7. It is held out of the queue. Rename the fragment to the current UTC minute (git mv) and push, or set MC_SCHEMA_RESTAMP=0 to queue it as it is."
  printf 'held %s\n' "$7"
}

# _pq_rs_run <slug> <head> <main> — the git half, under the git lock. Sets
#   _PQ_RS (the answer) and _PQ_RS_TOP. Never pushes on a stale read.
_pq_rs_run() {
  local slug="$1" head="$2" main="$3" repo="$MC_FUNNEL_WT" plan rc=0 wt new n prc=0 remote_sha err why
  _PQ_RS=""; _PQ_RS_TOP=""
  if ! git -C "$repo" -c credential.helper= fetch -q origin main "$head" >/dev/null 2>&1; then
    _PQ_RS="transient the fetch of main and ${head:0:12} failed"; return 0
  fi
  git -C "$repo" cat-file -e "$main^{commit}" 2>/dev/null || main=$(git -C "$repo" rev-parse --verify --quiet origin/main 2>/dev/null)
  [ -n "$main" ] || { _PQ_RS="transient origin/main does not resolve after the fetch"; return 0; }
  err=$(mktemp "${TMPDIR:-/tmp}/pq-restamp-err.XXXXXX") || { _PQ_RS="transient cannot make a temp file"; return 0; }
  plan=$(sr_plan "$repo" "$main" "$head" 2>"$err") || rc=$?
  why=$(head -n 1 "$err" 2>/dev/null); rm -f "$err"
  _PQ_RS_TOP=$(sr_top "$repo" "$main")
  [ "$rc" = 0 ] && [ -z "$plan" ] && { _PQ_RS=none; return 0; }
  # A terminal answer for this (PR, head, main's newest) was already given.
  if mc_attempt_has "restampfail ${KEY:-$slug} $head ${_PQ_RS_TOP:--}" 2>/dev/null; then _PQ_RS=said; return 0; fi
  [ "$rc" = 0 ] || { _PQ_RS="refused-0 sr_plan refused: ${why:-rc $rc}"; return 0; }
  n=$(grep -c . <<<"$plan")
  [ -n "${BR:-}" ] || { _PQ_RS="heldterm-$n no branch name for this PR"; return 0; }
  if declare -F mc_pool_rebase_enabled >/dev/null && mc_pool_rebase_enabled "${P:-}"; then
    _PQ_RS="heldterm-$n REBASE_ON_POOL is on for ${P:-?}: the hub does not push PR branches (BH-486)"; return 0
  fi
  wt=$(mktemp -d "${TMPDIR:-/tmp}/pq-restamp.XXXXXX") || { _PQ_RS="transient cannot make a temp worktree"; return 0; }
  rmdir "$wt"
  if ! git -C "$repo" worktree add -q --detach "$wt" "$head" >/dev/null 2>&1; then
    _PQ_RS="transient git worktree add failed"; return 0
  fi
  rc=0; new=$(sr_apply "$wt" "$main" 2>"$wt.err") || rc=$?
  if [ "$rc" != 0 ]; then
    _PQ_RS="refused-$n sr_apply rc $rc: $(head -n 1 "$wt.err" 2>/dev/null)"
  else
    command -v hold_push >/dev/null 2>&1 || { declare -F mc_hold_push_load >/dev/null && mc_hold_push_load; }
    if ! command -v hold_push >/dev/null 2>&1; then
      _PQ_RS="transient bin/lib/hold-push.sh is not loaded"
    else
      HOLD_PUSH_LOG="${MC_LOG:-}" hold_push -n "${P:-}" - "$wt" "$MC_REMOTE" HEAD "$BR" "$head" >/dev/null 2>"$wt.err" || prc=$?
      case "$prc" in
        0) remote_sha=$(git -C "$repo" -c credential.helper= ls-remote "$MC_REMOTE" "refs/heads/$BR" 2>/dev/null | awk 'NF {print $1; exit}')
           if [ "$remote_sha" = "$new" ]; then _PQ_RS="pushed $new $n"
           else _PQ_RS="refused-$n the push answered 0 but origin $BR is ${remote_sha:-unreadable}, not ${new:0:12}"; fi ;;
        3|4) _PQ_RS="transient $(tail -n 1 "$wt.err" 2>/dev/null | sed 's/^.*\[hold-push\] //')" ;;
        *) _PQ_RS="refused-$n the push was refused (rc $prc): $(tail -n 1 "$wt.err" 2>/dev/null | sed 's/^.*\[hold-push\] //')" ;;
      esac
    fi
  fi
  rm -f "$wt.err"
  git -C "$repo" worktree remove --force "$wt" >/dev/null 2>&1 || { rm -rf "$wt"; git -C "$repo" worktree prune >/dev/null 2>&1; }
  return 0
}

pq_restamp() {
  local slug="${1:-}" num="${2:-}" head="${3:-}" main="${4:-}" key rc=0 why new n
  key="${KEY:-$slug#$num}"
  [ "$(_pq_rs_knob)" != 0 ] || { echo none; return 0; }
  [ "${ACTIONS:-0}" = 1 ] || { echo none; return 0; }
  command -v sr_plan >/dev/null 2>&1 || { [ -r "$_pq_rs_dir/../schema-restamp.sh" ] && . "$_pq_rs_dir/../schema-restamp.sh"; }
  command -v sr_plan >/dev/null 2>&1 || { echo none; return 0; }
  [[ "$head" =~ ^[0-9a-f]{40}$ ]] && [[ "$main" =~ ^[0-9a-f]{40}$ ]] || { echo none; return 0; }
  # Cheapest first, with no credential, lock or fetch: a repo the conductor has
  # no clone of, or whose clone's origin/main has no stamp fragment, cannot have
  # a stale one. Every repo without worker/*/schema.d stops here.
  local lr; lr=$(_pq_rs_local "$slug") || { echo none; return 0; }
  [ -n "$(sr_top "$lr" origin/main 2>/dev/null)" ] || { echo none; return 0; }
  if ! declare -F mc_funnel_repo >/dev/null || ! mc_funnel_repo "$slug" "${P:-}"; then
    _pq_rs_held "$key" "$head" "$main" "no clone of $slug could be had"; return 0
  fi
  mc_git_locked "${P:-}" _pq_rs_run "$slug" "$head" "$main" || rc=$?
  declare -F mc_git_auth_clear >/dev/null && mc_git_auth_clear
  if [ "$rc" = 99 ]; then _pq_rs_held "$key" "$head" "$main" "the git lock for ${P:-?} was busy"; return 0; fi
  case "${_PQ_RS:-}" in
    none) echo none ;;
    said) printf 'held %s\n' "restamp failed earlier for this head and main's newest stamp ${_PQ_RS_TOP:--}" ;;
    pushed\ *)
      read -r _ new n <<<"$_PQ_RS"
      _pq_rs_line "$key" pushed "$head" "$new" "$main" "$n" "renamed $n stale schema fragment(s) past main's newest ${_PQ_RS_TOP:--}"
      printf 'pushed %s %s\n' "$new" "$n" ;;
    transient\ *) _pq_rs_held "$key" "$head" "$main" "${_PQ_RS#transient }" ;;
    refused-*|heldterm-*)
      why="${_PQ_RS#*-}"
      _pq_rs_fail "$key" "$head" "$main" "$_PQ_RS_TOP" "${_PQ_RS%%-*}" "${why%% *}" "${why#* }" ;;
    *) _pq_rs_held "$key" "$head" "$main" "the restamp gave no answer (rc $rc)" ;;
  esac
  return 0
}
