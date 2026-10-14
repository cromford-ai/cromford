#!/bin/bash
# bin/lib/mq-premerge.sh — the box merge queue's last check before a merge
# (BH-6428). Sourced, never executed. bin/merge-queue.sh calls pmg_check from
# mq_land, before the REST rung and before the `gh pr merge` fallback, so it
# covers every rung on both landing paths (the union train and the serial loop).
#
#   pmg_check <slug> <num> <head> <reviewed-sha> <enqueued-epoch> <log> <prefix>
#     Prints ONE line, rc 0:
#       ok                 the merge may proceed
#       hold <reason>      no merge this pass; the entry stays queued
#       handback <reason>  no merge; the entry leaves the box queue and the
#                          merge conductor owns the PR
#     Every non-ok answer writes ONE line to <log>:
#       "<prefix> MERGE_REFUSED premerge-<leg>: <detail>"
#
# THE INCIDENT (example-org/project-6 #216, 2026-10-13). The conductor parked #216
# RED_TWICE on head 1ad9442c at 07:23:55Z. At 07:26:24Z this queue on project-6-os
# merged that head over REST. The queue never read CI, and cv_hold reads only
# the conductor's mc-merge-verdict kind, which a RED_TWICE park never writes.
#
# The legs, in order; the first miss wins:
#   head          the head is 7-40 hex, else hold head-unread
#   reviewed-sha  the head is the reviewed sha (prefix both ways, 7-char floor),
#                 else handback. HEADBOUND_ENFORCE != 1 skips it with a log line.
#   park          the conductor's pr_state row (ledger kind pr_state, key
#                 <slug>#<num>, written by mc_ledger_put in bin/lib/mc/settle.sh)
#                 holds no park state on this head, and no park newer than the
#                 enqueue. A ledger outage passes with a log line: the CI leg
#                 reads GitHub, not the worker, so a red head is still refused.
#   ci            mc_ci_state <slug> <head> is green (bin/lib/mc/classify.sh,
#                 the rule the conductor merges on). red -> handback; pending,
#                 none, unavailable or no mc_ci_state -> hold (fail closed).
[ -n "${_PMG_LOADED:-}" ] && return 0
_PMG_LOADED=1

# pmg_sha_match <a> <b> — rc 0 when one is a prefix of the other, both 7+ chars.
pmg_sha_match() {
  local a="${1:-}" b="${2:-}"
  [ "${#a}" -ge 7 ] && [ "${#b}" -ge 7 ] || return 1
  case "$a" in "$b"*) return 0 ;; esac
  case "$b" in "$a"*) return 0 ;; esac
  return 1
}

# pmg_park_state <word> — rc 0 for a conductor state that parks the PR. The
# ticket's set: RED_TWICE, any BLOCKED_*, NEEDS_REBASE.
pmg_park_state() {
  case "${1:-}" in RED_TWICE|NEEDS_REBASE|BLOCKED_*) return 0 ;; esac
  return 1
}

# pmg_epoch <iso> — prints the epoch, or nothing when the time does not parse.
pmg_epoch() {
  local iso="${1:-}"
  [ -n "$iso" ] && [ "$iso" != - ] || return 0
  date -u -d "$iso" +%s 2>/dev/null || true
}

# _pmg_no <hold|handback> <leg> <reason> <detail> — the one log line and the
#   answer for a miss. Reads pmg_check's <log> and <prefix>.
_pmg_no() {
  printf '%s MERGE_REFUSED premerge-%s: %s — not merged here\n' "$prefix" "$2" "$4" >> "$log"
  printf '%s %s\n' "$1" "$3"
}

pmg_check() {
  local slug="$1" num="$2" head="${3:-}" rev="${4:-}" enq="${5:-}" log="${6:-/dev/null}" prefix="${7:-}"
  local row rc st detail phead since sepoch ci
  case "$head" in
    *[!0-9a-f]*|'') _pmg_no hold head "head-unread" "the head could not be read"; return 0 ;;
  esac
  if [ "${#head}" -lt 7 ] || [ "${#head}" -gt 40 ]; then
    _pmg_no hold head "head-unread" "the head '$head' is not a sha"; return 0
  fi

  if [ "${HEADBOUND_ENFORCE:-1}" != 1 ]; then
    printf '%s premerge reviewed-sha leg skipped (HEADBOUND_ENFORCE=0): head %s, reviewed sha %s\n' \
      "$prefix" "${head:0:8}" "${rev:-none}" >> "$log"
  elif [ -z "$rev" ]; then
    _pmg_no handback reviewed-sha "no-reviewed-sha" "no review is bound to a sha for this PR, so nothing proves head ${head:0:8} was reviewed"; return 0
  elif ! pmg_sha_match "$head" "$rev"; then
    _pmg_no handback reviewed-sha "head-not-reviewed" "head ${head:0:8} is not the reviewed sha ${rev:0:8}"; return 0
  fi

  if command -v job_ledger_row >/dev/null 2>&1; then
    row=$(job_ledger_row pr_state "$slug#$num"); rc=$?
  else
    rc=absent
  fi
  case "$rc" in
    0)
      st=$(jq -r '.status // ""' <<<"$row" 2>/dev/null)
      detail=$(jq -c '.detail | if type == "string" then (fromjson? // {}) elif type == "object" then . else {} end' <<<"$row" 2>/dev/null)
      [ -n "$detail" ] || detail='{}'
      phead=$(jq -r '.head_sha // ""' <<<"$detail" 2>/dev/null)
      since=$(jq -r '.since // ""' <<<"$detail" 2>/dev/null)
      if pmg_park_state "$st"; then
        if pmg_sha_match "$head" "$phead"; then
          _pmg_no handback park "conductor-park $st on ${head:0:8}" "the merge conductor parked head ${head:0:8} $st at ${since:-an unknown time}"; return 0
        fi
        sepoch=$(pmg_epoch "$since")
        if [ -z "$sepoch" ] || [ -z "$enq" ] || [ -n "${enq//[0-9]/}" ]; then
          _pmg_no handback park "stale-enqueue: enqueue time or park time unreadable" "the conductor parked this PR $st (head ${phead:0:8}, since ${since:-none}) and the enqueue time ${enq:-none} cannot be compared with it"; return 0
        fi
        if [ "$sepoch" -gt "$enq" ]; then
          local eiso; eiso=$(date -u -d "@$enq" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$enq")
          _pmg_no handback park "stale-enqueue: enqueued $eiso, the conductor parked it $st at $since" "the enqueue at $eiso is older than the conductor's $st park at $since (head ${phead:0:8})"; return 0
        fi
      fi
      ;;
    2) : ;;
    *)
      printf '%s premerge park state could not be read (ledger rc %s) — the CI leg still applies\n' "$prefix" "$rc" >> "$log"
      ;;
  esac

  if command -v mc_ci_state >/dev/null 2>&1; then
    ci=$(mc_ci_state "$slug" "$head" 2>/dev/null)
  else
    ci=unavailable
  fi
  case "$ci" in
    green) : ;;
    red) _pmg_no handback ci "ci-red" "CI is red on head ${head:0:8}"; return 0 ;;
    pending|none) _pmg_no hold ci "ci-$ci" "CI is $ci on head ${head:0:8}; the entry stays queued"; return 0 ;;
    *) _pmg_no hold ci "ci-unavailable" "CI on head ${head:0:8} could not be read (${ci:-no answer}); the entry stays queued"; return 0 ;;
  esac
  printf 'ok\n'
}
