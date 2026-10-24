#!/bin/bash
# bin/lib/pr-record-write.sh — the fleet's own GitHub writes update its PR
# record (BH-8150, slice C1 of BH-8067). Sourced, never executed. Defines
# functions only and prints nothing at source time.
#
#   prr_write <owner/repo> <number> <labels|comment|pull|none> <extra-json|-> <cmd...>
#       Runs <cmd...> unchanged. Its stdout is printed byte for byte, its
#       stderr is not touched and its rc is returned. Only when the rc is 0, it
#       writes to the record (bin/lib/pr-record.sh pr_record_put, source fleet)
#       what GitHub answered:
#         labels   the label names of the answer (POST and DELETE
#                  issues/<n>/labels both answer the issue's full label set)
#         comment  last_comment_id: `.id` of the answer, or the digits of
#                  `#issuecomment-<id>` in a URL (`gh pr comment` prints one)
#         pull     the pulls object, mapped by _prr_map (state, refs, shas...)
#         none     nothing from the answer
#       plus <extra-json> (a JSON object, or `-` for none). An answer that does
#       not parse adds no field; when no field is left nothing is sent.
#       `at` is the box's UTC time taken BEFORE <cmd...> runs, so a webhook for
#       the event the write caused carries a later time and wins.
#
#   prr_note_push <owner/repo> <number> <at> <worktree> <src-ref> <lease>
#       Call it after a push that returned 0. The record gets head_sha = the
#       sha of <src-ref> in <worktree>. When that sha is not <lease> (the head
#       before the push), it also gets checks {} and mergeable_state unknown:
#       the old head's checks do not apply to the new one. Always rc 0.
#
#   prr_now                  the UTC time in the form the record takes.
#   prr_mergify_extra <body> the queue_state of a `@mergifyio <verb>` comment:
#       queue/requeue -> requested, dequeue -> dequeue_requested, else `-`.
#       The verb is the first word after `@mergifyio` at the start of the body.
#
# A record write happens only when all of these are true. Otherwise the
# command runs as before and nothing else happens:
#   - the caller has the jobs client loaded (`_jobs_req`). This lib never loads
#     it, so a suite that stubs `gh` and never loads the client makes no jobs
#     request (BH-7563).
#   - the knob PR_RECORD_WRITES is 1 (catalog/lanes.d/_lib.pr-record-write.json;
#     read through lane_knob when the caller has it, else the env, else 1).
#   - no earlier record write of this process failed. The first failure that
#     is not a 4xx sets a per-process latch file and writes one
#     logs/pr-record.log line; the process then sends no more record writes, so
#     a dead worker costs its timeout once per process, not once per write.
# Every record step has stdout and stderr on /dev/null and never changes the rc.
[ -n "${_PRW_LOADED:-}" ] && declare -F prr_write >/dev/null && return 0
_PRW_LOADED=1
_PRW_LIBDIR="${BASH_SOURCE[0]%/*}"
# shellcheck source=bin/lib/pr-record.sh
command -v pr_record_put >/dev/null 2>&1 || . "$_PRW_LIBDIR/pr-record.sh" 2>/dev/null || true

prr_now() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

prr_mergify_extra() {
  local l="${1:-}"
  l="${l%%$'\n'*}"; l="${l,,}"
  if [[ $l =~ ^@mergifyio[[:space:]]+(queue|requeue|dequeue)([^a-z0-9_-]|$) ]]; then
    case "${BASH_REMATCH[1]}" in
      dequeue) printf '%s' '{"queue_state":"dequeue_requested"}' ;;
      *) printf '%s' '{"queue_state":"requested"}' ;;
    esac
  else
    printf '%s' -
  fi
}

# _prw_latch — the per-process latch path: pid plus the process start time, so
# a later process that reuses the pid does not read it.
_prw_latch() {
  local st=0
  [ -r "/proc/$$/stat" ] && st=$(sed 's/^.*) //' "/proc/$$/stat" 2>/dev/null | awk '{print $20}')
  printf '%s/prw-down.%s.%s' "${TMPDIR:-/tmp}" "$$" "${st:-0}"
}

_prw_on() {
  local v="" _LG_KIND=libs
  declare -F _jobs_req >/dev/null 2>&1 && declare -F pr_record_put >/dev/null 2>&1 || return 1
  [ -e "$(_prw_latch)" ] && return 1
  if command -v lane_knob >/dev/null 2>&1; then v=$(lane_knob pr-record-write PR_RECORD_WRITES 2>/dev/null); fi
  [ -n "$v" ] || v="${PR_RECORD_WRITES:-}"
  # No lane_knob and no env: the registry default (1) is not reachable here.
  [ -n "$v" ] || v=1
  case "$v" in
    0) return 1 ;;
    1) return 0 ;;
  esac
  if [ -z "${_PRW_KNOB_LOGGED:-}" ]; then
    _PRW_KNOB_LOGGED=1
    _prr_log "knob PR_RECORD_WRITES='$v' is not 0 or 1: using 1"
  fi
  return 0
}

# _prw_put <repo> <n> <kind> <fields-json> <at> — one pr_record_put. A failure
# that is not a 4xx sets the latch and writes one log line; a 4xx (the worker
# refused this one payload) writes one log line and leaves the latch off.
_prw_put() {
  local repo="$1" n="$2" kind="$3" fields="$4" at="$5" st="" rc=0 lr
  local JOBS_STATUS_FILE
  JOBS_STATUS_FILE=$(mktemp "${TMPDIR:-/tmp}/prw-st.XXXXXX" 2>/dev/null) || JOBS_STATUS_FILE=""
  pr_record_put "$repo" "$n" fleet "$fields" "$at" >/dev/null 2>&1 || rc=$?
  if [ -n "$JOBS_STATUS_FILE" ]; then st=$(cat "$JOBS_STATUS_FILE" 2>/dev/null); rm -f "$JOBS_STATUS_FILE"; fi
  [ "$rc" = 0 ] && return 0
  lr=$(_prr_lower "$repo")
  case "$st" in
    http=4*) _prr_log "write $lr#$n $kind put=failed ($st): the worker refused this write" ;;
    *) : > "$(_prw_latch)" 2>/dev/null
       _prr_log "write $lr#$n $kind put=failed (${st:-no status}): record writes off for pid $$" ;;
  esac
  return 0
}

# _prw_record <repo> <n> <kind> <extra> <at> — the command's stdout on stdin.
_prw_record() {
  local repo="$1" n="$2" kind="$3" extra="$4" at="$5" resp fields="" id
  _prw_on || return 0
  _prr_args_ok "$repo" "$n" || return 0
  resp=$(cat)
  case "$kind" in
    labels)
      fields=$(jq -c 'if type == "array" and all(.[]; type == "object" and (.name | type) == "string")
                      then {labels: [.[].name]} else empty end' <<<"$resp" 2>/dev/null) ;;
    comment)
      id=$(jq -r 'if type == "object" and (.id | type) == "number" then .id else empty end' <<<"$resp" 2>/dev/null)
      [ -n "$id" ] || id=$(grep -oE '#issuecomment-[0-9]+' <<<"$resp" | head -n 1 | sed 's/^#issuecomment-//')
      [[ "$id" =~ ^[1-9][0-9]{0,15}$ ]] && fields="{\"last_comment_id\":$id}" ;;
    pull) fields=$(_prr_map <<<"$resp") ;;
    none) ;;
    *) return 0 ;;
  esac
  [ -n "$fields" ] || fields='{}'
  if [ "$extra" != - ] && [ -n "$extra" ]; then
    fields=$(jq -c --argjson e "$extra" 'if ($e | type) == "object" then . + $e else empty end' <<<"$fields" 2>/dev/null)
    [ -n "$fields" ] || return 0
  fi
  [ "$fields" != '{}' ] || return 0
  _prw_put "$repo" "$n" "$kind" "$fields" "$at"
}

prr_write() {
  [ "$#" -ge 5 ] || return 64
  local repo="$1" n="$2" kind="$3" extra="$4" at tmp rc=0
  shift 4
  at=$(prr_now)
  tmp=$(mktemp "${TMPDIR:-/tmp}/prw-out.XXXXXX" 2>/dev/null) || { "$@"; return; }
  "$@" > "$tmp" || rc=$?
  cat "$tmp"
  if [ "$rc" = 0 ]; then
    _prw_record "$repo" "$n" "$kind" "$extra" "$at" < "$tmp" >/dev/null 2>&1 || true
  fi
  rm -f "$tmp"
  return "$rc"
}

prr_note_push() {
  local repo="${1:-}" n="${2:-}" at="${3:-}" wt="${4:-}" src="${5:-}" lease="${6:-}" sha fields
  {
    _prw_on && _prr_args_ok "$repo" "$n" && [ -n "$wt" ] && [ -n "$src" ] || return 0
    sha=$(git -C "$wt" rev-parse --verify -q "$src^{commit}" 2>/dev/null) || sha=""
    [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 0
    if [ "$sha" = "$lease" ]; then
      fields="{\"head_sha\":\"$sha\"}"
    else
      fields="{\"head_sha\":\"$sha\",\"checks\":{},\"mergeable_state\":\"unknown\"}"
    fi
    _prw_put "$repo" "$n" push "$fields" "$at"
  } >/dev/null 2>&1
  return 0
}
