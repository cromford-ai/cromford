#!/bin/bash
# bin/lib/prr-shadow.d/merge-conductor.sh — the prr-shadow seam of lane merge-conductor (BH-9926).
# Sourced by prr_seam_load merge-conductor (bin/lib/prr-shadow.sh), never executed.
#
# The knob GH_SOURCE (settings row lane.merge-conductor.gh_source, default
# shadow) is registered in catalog/lanes.d/merge-conductor.knobs.d/.
#
# The CI word (BH-9926 wave 4). mc_ci_state <slug> <sha> <n> (bin/lib/mc/classify.sh)
# calls prr_read merge-conductor "<slug>#<n>@<sha12>" <file> mc_ci_record mc_ci_github mc_ci_norm <slug> <sha> <n>:
#   mc_ci_record <file> <slug> <sha> <n>
#       prr_ci_state (bin/lib/prr-ci-state.sh). green or pending: the word in
#       <file>, rc 0. red prints ci:red, unknown prints ci:unknown, rc 1: the
#       record never serves red, because the red arms need the run ids and the
#       advisory split (BH-9210) that only the actions/runs read fills. In step
#       shadow it runs with PRR_CI_GUARD=0, so shadow makes no guard read.
#   mc_ci_github <file> <slug> <sha> <n>
#       _mc_ci_state_github <slug> <sha> > <file>, a plain command, so its
#       globals (MC_CI_READ_HELD, MC_CI_RUNS, ...) reach the caller. rc 0.
#   mc_ci_norm <file>
#       [{"n":"ci","v":"<word>"}] for green, pending or red; nothing for none
#       and unavailable, so those are never compared.
#
# The open list (BH-9938 slice C1, wave 6). The conductor exports
# PRS_OPEN_PRR=merge-conductor, and prs_open_list (bin/lib/pr-snapshot.sh, the
# page under harness_pr_list) then reads through prr_read merge-conductor
# "<slug>#open" <file> mc_open_record mc_open_github mc_open_norm <slug>:
#   mc_open_record <file> <slug>
#       pr_record_open_rest <slug> <file> "" need-cross (bin/lib/pr-record.sh):
#       the WHOLE open list (no window), in the REST pulls shape, with the
#       head and base repo full names from the cross-repo memo. Misses:
#       pr_record_list's words (stale, no-sync, truncated, unknown, ...),
#       field:default_branch, field:cross (a PR the memo does not know),
#       malformed. A record list is never written into the shared snapshot
#       (state/pr-snapshot), which other lanes read.
#   mc_open_github <file> <slug>
#       Today's prs_open_list read (snapshot or the REST list), and on rc 0
#       the default-branch and cross-repo memos (`full`: the whole list).
#   mc_open_norm <file>
#       [{n, head, draft, labels}] sorted by n: the fields the tick acts on.
# The flake read (BH-9938 C1). mc_ci_flake_runs <slug> <sha> <n> (bin/lib/mc/classify.sh)
# runs for a green row that GitHub calls BLOCKED or UNSTABLE, every tick. It
# calls prr_read merge-conductor "<slug>#<n>@<sha12>:flake" <file>
# mc_flake_record mc_flake_github mc_flake_norm <slug> <sha> <n>:
#   mc_flake_record <file> <slug> <sha> <n>
#       "No flake evidence" (an empty <file>, rc 0) only when the record row
#       (pr_record_peek) is fresh (PR_RECORD_FIELD_MAX_AGE_S), its head_sha is <sha>,
#       it holds at least 1 check entry for <sha> and fewer than
#       PRR_CI_CHECKS_MAX names, and every entry for <sha> completed with a
#       conclusion that is not cancelled or timed_out. The rerun list needs run
#       ids that only GitHub has, so any other case is a miss (stale, head,
#       none, pending, flake, checks-max, unreadable): the record never invents
#       a rerun and never hides a cancelled run it holds.
#   mc_flake_github <file> <slug> <sha> <n>
#       Today's read: MC_FLAKE_GH=1 mc_ci_flake_runs <slug> <sha> > <file>, rc 0.
#   mc_flake_norm <file>
#       [{"n":"flake","v":"<run ids, sorted, comma-joined>"}].
# The external-PR list of bin/lib/mc/external-enqueue.sh (one page of 100,
# key "<slug>#open:100") uses mc_xe_record (the record window of 100, with
# the cross-repo memo), mc_xe_github (today's gh_rest read, same rc) and
# mc_open_norm.
if ! command -v prr_ci_state >/dev/null 2>&1 && [ -r "${BASH_SOURCE[0]%/*}/../prr-ci-state.sh" ]; then
  # shellcheck source=bin/lib/prr-ci-state.sh
  . "${BASH_SOURCE[0]%/*}/../prr-ci-state.sh"
fi

mc_ci_record() {
  local f="${1:-}" slug="${2:-}" sha="${3:-}" n="${4:-}" w g="${PRR_CI_GUARD:-1}"
  [ -n "$f" ] || return 2
  command -v prr_ci_state >/dev/null 2>&1 || { echo ci:unknown; return 1; }
  command -v prr_step >/dev/null 2>&1 && [ "$(prr_step merge-conductor)" = shadow ] && g=0
  w=$(PRR_CI_GUARD="$g" prr_ci_state "$slug" "$n" "$sha")
  case "$w" in
    green|pending) printf '%s\n' "$w" > "$f"; return 0 ;;
    red) echo ci:red; return 1 ;;
    *) echo ci:unknown; return 1 ;;
  esac
}

mc_ci_github() {
  local f="${1:-}"
  [ -n "$f" ] || return 2
  _mc_ci_state_github "${2:-}" "${3:-}" > "$f"
  return 0
}

mc_ci_norm() {
  local w
  w=$(head -1 "${1:-}" 2>/dev/null)
  case "$w" in green|pending|red) printf '[{"n":"ci","v":"%s"}]\n' "$w" ;; esac
}

mc_open_record() {
  local f="${1:-}" slug="${2:-}"
  [ -n "$f" ] || return 2
  command -v pr_record_open_rest >/dev/null 2>&1 || { echo unreadable; return 1; }
  pr_record_open_rest "$slug" "$f" "" need-cross
}

mc_open_github() {
  local f="${1:-}" slug="${2:-}" rc=0
  [ -n "$f" ] || return 2
  _PRS_IN_PRR=1 prs_open_list "$slug" "$f" || rc=$?
  [ "$rc" = 0 ] && command -v pr_record_default_branch_note >/dev/null 2>&1 \
    && pr_record_default_branch_note "$slug" "$f" full
  return "$rc"
}

mc_open_norm() {
  jq -c '[.[]? | {n: .number, head: .head.sha, draft: (.draft == true),
          labels: ([.labels[]?.name] | sort)}] | sort_by(.n)' "${1:-}" 2>/dev/null
}

mc_xe_record() {
  local f="${1:-}" slug="${2:-}"
  [ -n "$f" ] || return 2
  command -v pr_record_open_rest >/dev/null 2>&1 || { echo unreadable; return 1; }
  pr_record_open_rest "$slug" "$f" 100 need-cross
}

mc_xe_github() {
  local f="${1:-}" slug="${2:-}" rc=0
  [ -n "$f" ] || return 2
  gh_rest GET "repos/$slug/pulls?state=open&per_page=100" > "$f" || rc=$?
  [ "$rc" = 0 ] && command -v pr_record_default_branch_note >/dev/null 2>&1 \
    && pr_record_default_branch_note "$slug" "$f"
  return "$rc"
}

mc_flake_record() {
  local f="${1:-}" slug="${2:-}" sha="${3:-}" n="${4:-}" row w max
  [ -n "$f" ] || return 2
  command -v pr_record_peek >/dev/null 2>&1 || { echo unreadable; return 1; }
  row=$(pr_record_peek "$slug" "$n") || { echo unreadable; return 1; }
  command -v _prr_row_fresh >/dev/null 2>&1 && ! _prr_row_fresh "$row" && { echo stale; return 1; }
  sha=$(printf '%s' "$sha" | tr 'A-F' 'a-f')
  max=$(command -v _prr_ci_int >/dev/null 2>&1 && _prr_ci_int PRR_CI_CHECKS_MAX "${_PRR_CI_DEFAULT_CHECKS_MAX:-100}" 1 1000 2>/dev/null)
  [[ "$max" =~ ^[0-9]+$ ]] || max="${_PRR_CI_DEFAULT_CHECKS_MAX:-100}"
  w=$(jq -r --arg h "$sha" --argjson max "$max" '
    if (.head_sha // "" | ascii_downcase) != $h then "head"
    elif (.checks | type) != "object" then "none"
    elif (.checks | length) >= $max then "checks-max"
    else ([.checks[] | objects | select((.sha // "" | ascii_downcase) == $h)]) as $e
      | if ($e | length) == 0 then "none"
        elif any($e[]; .status != "completed") then "pending"
        elif any($e[]; .conclusion == "cancelled" or .conclusion == "timed_out") then "flake"
        else "hit" end
    end' <<<"$row" 2>/dev/null) || w=malformed
  [ "$w" = hit ] || { echo "${w:-malformed}"; return 1; }
  : > "$f"
}

mc_flake_github() {
  local f="${1:-}"
  [ -n "$f" ] || return 2
  MC_FLAKE_GH=1 mc_ci_flake_runs "${2:-}" "${3:-}" > "$f"
  return 0
}

mc_flake_norm() {
  local ids
  ids=$(cut -d'|' -f1 "${1:-}" 2>/dev/null | grep -E '^[0-9]+$' | sort -n | paste -sd, -)
  printf '[{"n":"flake","v":"%s"}]\n' "$ids"
}

# The QUEUED pass's queue word (BH-10257). mc_queue_state_rec <url> <head>
# (bin/lib/mc/queue.sh) calls prr_read merge-conductor
# "<slug>#<n>@<head12>:queue" <file> mc_qs_record mc_qs_github mc_qs_norm
# <url> <head> <slug> <n>. It replaces the PR read (pulls/<n>) and, on
# Mergify, the queue check-runs read of mc_queue_state for a QUEUED row.
#   mc_qs_record <file> <url> <head> <slug> <n>
#       `queued` in <file>, rc 0, only when ALL hold on the record row
#       (pr_record_peek, one jobs GET): age_s is 0..MC_RECORD_MAX_AGE_S; state
#       is open; head_sha is <head>; labels hold our trigger label
#       (MC_MERGIFY_LABEL), queued or checking, and not dequeued; on Mergify,
#       checks is an object with fewer than PRR_CI_CHECKS_MAX names and no
#       queue check (^Mergify, ^Queue:, (queue)) of <head> ended failure,
#       cancelled, timed_out, action_required, startup_failure or stale.
#       `queued` changes nothing: the row stays QUEUED. The record never
#       answers merged, ejected or unknown, so it never settles, ejects or
#       strikes a PR. Misses: unknown (no row or no read), stale, state, head,
#       field:labels, labels, field:checks, checks-max, check-red, malformed.
#   mc_qs_github <file> <url> <head> <slug> <n>
#       Today's read: ONE pulls/<n> GET (mc_rest_pr_json) and the rule of
#       mc_queue_state (mc_queue_state_judge, which reads the check runs on
#       Mergify). In step record a read that answered is written back into
#       the record (pr_record_put, source github, at = the read's start), so
#       the next ticks of an idle QUEUED PR read the record again.
#   mc_qs_norm <file>
#       [{"n":"queue","v":"<word>"}].
# The knob MC_RECORD_MAX_AGE_S (catalog/lanes.d/merge-conductor.knobs.d/) is
# read by mc_record_max_age_s: lane_knob merge-conductor, else the
# environment, else 900. 0 trusts no row.
_MC_DEFAULT_RECORD_MAX_AGE_S=900   # fallback only: the knob is MC_RECORD_MAX_AGE_S in catalog/lanes.d/merge-conductor.knobs.d/

mc_record_max_age_s() {
  local v=""
  if command -v lane_knob >/dev/null 2>&1; then v=$(lane_knob merge-conductor MC_RECORD_MAX_AGE_S 2>/dev/null | tr -d '[:space:]'); fi
  [ -n "$v" ] || v="${MC_RECORD_MAX_AGE_S:-}"
  [[ "$v" =~ ^[0-9]+$ ]] || v="$_MC_DEFAULT_RECORD_MAX_AGE_S"
  printf '%s\n' "$((10#$v))"
}

mc_qs_record() {
  local f="${1:-}" head="${3:-}" slug="${4:-}" n="${5:-}" row age max prov cmax w
  [ -n "$f" ] || return 2
  command -v pr_record_peek >/dev/null 2>&1 || { echo unknown; return 1; }
  row=$(pr_record_peek "$slug" "$n") || { echo unknown; return 1; }
  age=$(jq -r '.age_s // empty' <<<"$row" 2>/dev/null)
  max=$(mc_record_max_age_s)
  { [[ "$age" =~ ^[0-9]+$ ]] && [ "$max" -gt 0 ] && [ "$age" -le "$max" ]; } || { echo stale; return 1; }
  head=$(printf '%s' "$head" | tr 'A-F' 'a-f')
  prov=$(mc_queue_provider "$slug" 2>/dev/null)
  cmax=$(command -v _prr_ci_int >/dev/null 2>&1 && _prr_ci_int PRR_CI_CHECKS_MAX "${_PRR_CI_DEFAULT_CHECKS_MAX:-100}" 1 1000 2>/dev/null)
  [[ "$cmax" =~ ^[0-9]+$ ]] || cmax="${_PRR_CI_DEFAULT_CHECKS_MAX:-100}"
  w=$(jq -r --arg h "$head" --arg lab "${MC_MERGIFY_LABEL:-merge-queue}" --arg prov "$prov" --argjson max "$cmax" '
    if (.state // "") != "open" then "state"
    elif ((.head_sha // "") | ascii_downcase) != $h then "head"
    elif (.labels | type) != "array" then "field:labels"
    elif any(.labels[]; . == "dequeued") then "labels"
    elif (any(.labels[]; . == $lab or . == "queued" or . == "checking") | not) then "labels"
    elif $prov != "mergify" then "hit"
    elif (.checks | type) != "object" then "field:checks"
    elif (.checks | length) >= $max then "checks-max"
    elif any(.checks | to_entries[];
           (.key | test("^Mergify|^Queue:|\\(queue\\)"))
           and (((.value.sha // "") | ascii_downcase) == $h)
           and ((.value.conclusion // "") | IN("failure","cancelled","timed_out","action_required","startup_failure","stale")))
      then "check-red"
    else "hit" end' <<<"$row" 2>/dev/null) || w=malformed
  [ "$w" = hit ] || { echo "${w:-malformed}"; return 1; }
  printf 'queued\n' > "$f"
}

mc_qs_github() {
  local f="${1:-}" url="${2:-}" head="${3:-}" slug="${4:-}" n="${5:-}" t rc=0 j="" at mapped
  [ -n "$f" ] || return 2
  t=$(mktemp "${TMPDIR:-/tmp}/mc-qs-gh.XXXXXX") || { mc_queue_state "$url" "$head" > "$f"; return 0; }
  at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  mc_rest_pr_json "$slug" "$n" > "$t" 2>/dev/null || rc=$?
  if [ "$rc" = 0 ]; then
    j=$(jq -r '"\(.STATE) \(.head.sha) \(.LABELS)"' "$t" 2>/dev/null) || j=""
    if [ -n "$j" ] && command -v prr_step >/dev/null 2>&1 && [ "$(prr_step merge-conductor)" = record ] \
       && command -v _prr_map >/dev/null 2>&1 && command -v pr_record_put >/dev/null 2>&1; then
      mapped=$(_prr_map < "$t")
      [ -n "$mapped" ] && [ "$mapped" != "{}" ] \
        && pr_record_put "$(printf '%s' "$slug" | tr 'A-Z' 'a-z')" "$n" github "$mapped" "$at" >/dev/null 2>&1
    fi
  fi
  rm -f "$t"
  mc_queue_state_judge "$url" "$head" given "$j" > "$f"
  return 0
}

mc_qs_norm() {
  local w
  w=$(head -1 "${1:-}" 2>/dev/null)
  [ -n "$w" ] && printf '[{"n":"queue","v":"%s"}]\n' "$w"
}
