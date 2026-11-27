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
# The branch lookup (BH-10215). prs_branch_tip (bin/lib/pr-snapshot-refs.sh),
# under PRS_OPEN_PRR=merge-conductor, reads one branch prefix through
# prr_read merge-conductor "<slug>#refs:<prefix>" <file> mc_refs_record
# mc_refs_github mc_refs_norm <slug> <prefix> <branch>:
#   mc_refs_record <file> <slug> <prefix> <branch>
#       pr_record_list <slug> open <tmp> "" "" head_commit: the open rows of
#       the record, trusted by pr_record_list's own rule (a miss passes its
#       word: stale, no-sync, truncated, unknown, unreadable, ...). <file>
#       gets [{ref, sha}] for each row whose head_ref starts with <prefix>/
#       and whose head_commit.sha (the tip of the last push webhook) is
#       40-hex, unique by ref. field:absent when <branch> is not in it: GitHub
#       then answers for that branch (a base branch with no open PR of its own).
#   mc_refs_github <file> <slug> <prefix>
#       Today's read: gh_rest GET repos/<slug>/git/matching-refs/heads/<prefix>/
#       mapped to the same [{ref, sha}], a plain command (GH_REST_* reach the
#       caller). The read's rc; rc 1 and an empty <file> when it is not an array.
#   mc_refs_norm <file>
#       [{n: ref, sha}] sorted by ref. In step shadow the GitHub side also
#       holds branches with no open PR, so a PRR_SHADOW line of this key with
#       only_github > 0 and changed=0 is a match.
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

mc_refs_record() {
  local f="${1:-}" slug="${2:-}" pre="${3:-}" br="${4:-}" tmp why rc=0
  [ -n "$f" ] || return 2
  command -v pr_record_list >/dev/null 2>&1 || { echo unreadable; return 1; }
  tmp=$(mktemp "${TMPDIR:-/tmp}/mc-refs-record.XXXXXX") || { echo unreadable; return 1; }
  why=$(pr_record_list "$slug" open "$tmp" "" "" head_commit) || rc=$?
  if [ "$rc" != 0 ]; then rm -f "$tmp" "$tmp.sync"; echo "${why:-unreadable}"; return 1; fi
  if ! jq -c --arg p "$pre/" '[.[]? | select((.head_ref // "") | startswith($p))
        | select((.head_commit.sha // "") | test("^[0-9a-fA-F]{40}$"))
        | {ref: .head_ref, sha: (.head_commit.sha | ascii_downcase)}] | unique_by(.ref)' "$tmp" > "$f" 2>/dev/null; then
    rm -f "$tmp" "$tmp.sync"; : > "$f"; echo malformed; return 1
  fi
  rm -f "$tmp" "$tmp.sync"
  jq -e --arg r "$br" 'any(.[]; .ref == $r)' "$f" >/dev/null 2>&1 || { : > "$f"; echo field:absent; return 1; }
  return 0
}

mc_refs_github() {
  local f="${1:-}" slug="${2:-}" pre="${3:-}" rc=0
  [ -n "$f" ] || return 2
  gh_rest GET "repos/$slug/git/matching-refs/heads/$pre/" > "$f.raw" || rc=$?
  if [ "$rc" = 0 ] && jq -c 'if type != "array" then error("not an array") else . end
       | [.[] | {ref: ((.ref // "") | sub("^refs/heads/"; "")),
       sha: ((.object.sha // "") | ascii_downcase)}] | unique_by(.ref)' "$f.raw" > "$f" 2>/dev/null; then
    rm -f "$f.raw"; return 0
  fi
  rm -f "$f.raw"; : > "$f"
  [ "$rc" = 0 ] && rc=1
  return "$rc"
}

mc_refs_norm() {
  jq -c '[.[]? | {n: .ref, sha}] | sort_by(.n)' "${1:-}" 2>/dev/null
}

# ── BH-10257 slice 2: the QUEUED pass's PR view and its reviews read ──────────
# _mc_rec_put_gh <slug> <n> <pulls-json-file> <at> — in step record, the
#   GitHub pulls/<n> read in <file> is written back into the record
#   (pr_record_put, source github, at = the read's start), the slice 1 rule,
#   so the next reads of an idle QUEUED PR come from the record.
_mc_rec_put_gh() {
  local mapped
  command -v prr_step >/dev/null 2>&1 && [ "$(prr_step merge-conductor)" = record ] || return 0
  command -v _prr_map >/dev/null 2>&1 && command -v pr_record_put >/dev/null 2>&1 || return 0
  mapped=$(_prr_map < "$3")
  [ -n "$mapped" ] && [ "$mapped" != "{}" ] \
    && pr_record_put "$(printf '%s' "$1" | tr 'A-Z' 'a-z')" "$2" github "$mapped" "$4" >/dev/null 2>&1
  return 0
}

# _mc_rec_row <slug> <n> — the fresh record row of a PR (pr_record_peek), or a
#   miss word on stdout and rc 1: unknown (no row or no read), stale (age_s
#   not in 0..MC_RECORD_MAX_AGE_S; a knob of 0 trusts no row).
_mc_rec_row() {
  local row age max
  command -v pr_record_peek >/dev/null 2>&1 || { echo unknown; return 1; }
  row=$(pr_record_peek "$1" "$2") || { echo unknown; return 1; }
  age=$(jq -r '.age_s // empty' <<<"$row" 2>/dev/null)
  max=$(mc_record_max_age_s)
  { [[ "$age" =~ ^[0-9]+$ ]] && [ "$max" -gt 0 ] && [ "$age" -le "$max" ]; } || { echo stale; return 1; }
  printf '%s\n' "$row"
}

# The view of a QUEUED row. mc_queued_view_rec <url> <head> (bin/lib/mc/queue.sh)
# calls prr_read merge-conductor "<slug>#<n>@<head12>:view" <file> mc_qv_record
# mc_qv_github mc_qv_norm <url> <head> <slug> <n>. It replaces the pulls/<n>
# read of a QUEUED row the open list does not hold at its QUEUED head.
#   mc_qv_record <file> <url> <head> <slug> <n>
#       `OPEN <head_ref> <head>` in <file>, rc 0, only when the row is fresh,
#       state is open, head_sha is <head>, head_ref is set, AND the state and
#       head_sha fields themselves are young: fields_at.state and
#       fields_at.head_sha (the time a whole-PR source, a pull_request webhook
#       or a GitHub pulls read, last wrote them) are 0..MC_RECORD_MAX_AGE_S
#       old. age_s alone is not enough: a PUT of other fields (the CR read's
#       reviews write-back) moves refreshed_at, so a row whose closed webhook
#       was lost would stay "fresh" and OPEN forever, and a merged PR would
#       never settle. OPEN changes
#       nothing on its own: the row goes on to the reviews read and the queue
#       word, each with its own rule. The record never answers MERGED or
#       CLOSED, so it never settles or closes a row. Misses: unknown, stale,
#       state, head, field:head_ref, state-age, malformed.
#   mc_qv_github <file> <url> <head> <slug> <n>
#       Today's read: ONE pulls/<n> GET (mc_rest_pr_json), the line
#       `<STATE> <head.ref> <head.sha>` in <file>, the read's rc (75 for an
#       answer with no state). Written back in step record.
#   mc_qv_norm <file>   [{"n":"view","v":"<line>"}]
mc_qv_record() {
  local f="${1:-}" head="${3:-}" slug="${4:-}" n="${5:-}" row w max now
  [ -n "$f" ] || return 2
  row=$(_mc_rec_row "$slug" "$n") || { printf '%s\n' "$row"; return 1; }
  head=$(printf '%s' "$head" | tr 'A-F' 'a-f')
  max=$(mc_record_max_age_s); now=$(date -u +%s)
  w=$(jq -r --arg h "$head" --argjson max "$max" --argjson now "$now" '
    def fage($k): ((.fields_at // {})[$k] // "") as $t
      | if ($t | type) != "string" or $t == "" then -1 else ($now - ($t | fromdateiso8601)) end;
    if (.state // "") != "open" then "state"
    elif ((.head_sha // "") | ascii_downcase) != $h then "head"
    elif ((.head_ref // "") | type) != "string" or (.head_ref // "") == "" or ((.head_ref // "") | test("\\s")) then "field:head_ref"
    elif ([fage("state"), fage("head_sha")] | any(. < 0 or . > $max)) then "state-age"
    else "OPEN \(.head_ref) \($h)" end' <<<"$row" 2>/dev/null) || w=malformed
  case "$w" in "OPEN "*) printf '%s\n' "$w" > "$f"; return 0 ;; esac
  echo "${w:-malformed}"; return 1
}

mc_qv_github() {
  local f="${1:-}" slug="${4:-}" n="${5:-}" t rc=0 j="" at
  [ -n "$f" ] || return 2
  t=$(mktemp "${TMPDIR:-/tmp}/mc-qv-gh.XXXXXX") || return 75
  at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  mc_rest_pr_json "$slug" "$n" > "$t" 2>/dev/null || rc=$?
  if [ "$rc" = 0 ]; then
    j=$(jq -r '"\(.STATE) \(.head.ref) \(.head.sha // "")"' "$t" 2>/dev/null) || j=""
    [ -n "$j" ] && _mc_rec_put_gh "$slug" "$n" "$t" "$at"
  fi
  rm -f "$t"
  [ "$rc" = 0 ] || return "$rc"
  [ -n "$j" ] || return 75
  printf '%s\n' "$j" > "$f"
}

mc_qv_norm() {
  local w
  w=$(head -1 "${1:-}" 2>/dev/null)
  [ -n "$w" ] && jq -nc --arg v "$w" '[{n:"view", v:$v}]'
}

# Is a CHANGES_REQUESTED standing on a QUEUED row (mc_cr_dequeue's first
# read). mc_cr_standing_rec (bin/lib/mc/queue.sh) calls prr_read
# merge-conductor "<slug>#<n>@<head12>:cr" <file> mc_cr_record mc_cr_github
# mc_cr_norm <slug> <n> <url> <head>. <file>: line 1 none | stands |
# unreadable, line 2 the scan line of a standing CR.
#   mc_cr_record <file> <slug> <n> <url> <head>
#       `none`, rc 0, only from a COMPLETE review set. The record proves it
#       with reviews_sync {head_sha, at, cr}: the conductor's own whole GitHub
#       reviews read (bg_cr_standing, every page) of <head>, written by
#       mc_cr_github. ALL must hold: the row is fresh, open, on <head>;
#       reviews is an object (not NULL: a NULL object drops review webhooks,
#       so a later review could not show); reviews_sync.head_sha is <head>;
#       reviews_sync.cr is 0 (bg_cr_standing said none); reviews_sync.at is
#       0..MC_RECORD_MAX_AGE_S old; and no review was delivered at or after
#       the sync (fields_at.reviews, which every review webhook moves to its
#       submitted_at, is earlier than reviews_sync.at). reviews_sync.at is the
#       read's start minus MC_CR_SYNC_SKEW_S (a review submitted just before
#       the read, or inside the box-to-GitHub clock skew, counts as after it),
#       and the write-back's own `at` is one second before that, so the
#       write-back itself never looks like a later review. A dismissal never
#       makes a CR stand, so a missed one only holds a PR back. The record
#       never answers `stands`: a standing CR, a sync that said one stood and
#       every miss read GitHub. Misses: unknown, stale, state, head,
#       field:reviews, no-sync, sync-head, sync-cr, sync-old, sync-later,
#       malformed.
#   mc_cr_github <file> <slug> <n> <url> <head>
#       Today's read: bg_cr_standing <slug> <n> <url> <head> "" (bin/lib/
#       block-gate.sh, one paginated pulls/<n>/reviews read). In step record,
#       an answer (none or stands) is written back with source github and
#       at = reviews_sync.at - 1 s: reviews (the BH-8481 shape, the latest review
#       per bare lowercase login, from BG_CR_ROWS) and reviews_sync {head_sha,
#       at, cr}. More than _MC_REVIEWERS_MAX logins, or a login the record
#       cannot key, writes nothing (the next tick reads GitHub again).
#   mc_cr_norm <file>   [{"n":"cr","v":"<word>"}]
_MC_REVIEWERS_MAX=100   # input shape bound: REVIEWERS_MAX of worker/jobs/src/routes/pr-records.js
_MC_DEFAULT_CR_SYNC_SKEW_S=30   # fallback only: the knob is MC_CR_SYNC_SKEW_S in catalog/lanes.d/merge-conductor.knobs.d/

# mc_cr_sync_skew_s — the knob MC_CR_SYNC_SKEW_S: lane_knob merge-conductor,
#   else the environment, else 30.
mc_cr_sync_skew_s() {
  local v=""
  if command -v lane_knob >/dev/null 2>&1; then v=$(lane_knob merge-conductor MC_CR_SYNC_SKEW_S 2>/dev/null | tr -d '[:space:]'); fi
  [ -n "$v" ] || v="${MC_CR_SYNC_SKEW_S:-}"
  [[ "$v" =~ ^[0-9]+$ ]] || v="$_MC_DEFAULT_CR_SYNC_SKEW_S"
  printf '%s\n' "$((10#$v))"
}

# _mc_iso_of <epoch> — the UTC time of an epoch, YYYY-MM-DDTHH:MM:SSZ.
_mc_iso_of() { date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -r "$1" '+%Y-%m-%dT%H:%M:%SZ'; }

mc_cr_record() {
  local f="${1:-}" slug="${2:-}" n="${3:-}" head="${5:-}" row w max now
  [ -n "$f" ] || return 2
  row=$(_mc_rec_row "$slug" "$n") || { printf '%s\n' "$row"; return 1; }
  head=$(printf '%s' "$head" | tr 'A-F' 'a-f')
  max=$(mc_record_max_age_s); now=$(date -u +%s)
  w=$(jq -r --arg h "$head" --argjson max "$max" --argjson now "$now" '
    (.reviews_sync // null) as $s
    | if (.state // "") != "open" then "state"
    elif ((.head_sha // "") | ascii_downcase) != $h then "head"
    elif (.reviews | type) != "object" then "field:reviews"
    elif ($s | type) != "object" then "no-sync"
    elif (($s.head_sha // "") | ascii_downcase) != $h then "sync-head"
    elif $s.cr != 0 then "sync-cr"
    elif (($s.at // "") | type) != "string" then "malformed"
    elif ($now - ($s.at | fromdateiso8601)) as $a | ($a < 0 or $a > $max or $max == 0) then "sync-old"
    elif ((.fields_at // {}).reviews // "") as $fr | ($fr != "" and $fr >= $s.at) then "sync-later"
    else "hit" end' <<<"$row" 2>/dev/null) || w=malformed
  [ "$w" = hit ] || { echo "${w:-malformed}"; return 1; }
  printf 'none\n' > "$f"
}

# _mc_cr_reviews_obj — BG_CR_ROWS (bg_cr_standing's rows: id, submitted_at,
#   login, type, association, state, commit, url, marker) on stdin -> the
#   record's reviews object, or rc 1.
_mc_cr_reviews_obj() {
  jq -R -s -c --argjson max "$_MC_REVIEWERS_MAX" '
    [split("\n")[] | select(length > 0) | split("\t") | select(length == 9)
     | {id: (.[0] | tonumber? // 0), at: .[1], login: .[2], state: .[5], commit: .[6]}
     | .key = (.login | ascii_downcase | sub("^app/"; "") | sub("\\[bot\\]$"; ""))]
    | if any(.[]; (.key | test("^[a-z0-9-]{1,39}$") | not)
                 or (.state | IN("APPROVED","CHANGES_REQUESTED","COMMENTED","DISMISSED","PENDING") | not)) then error("key")
      else . end
    | group_by(.key) | map(sort_by(.at, .id) | last)
    | if length > $max then error("max") else . end
    | map({key: .key, value: {state: .state,
        commit_id: (if (.commit | test("^[0-9a-f]{40}$")) then .commit else null end),
        at: (if .at == "-" then null else (.at | sub("\\.[0-9]+Z$"; "Z")) end)}})
    | from_entries' 2>/dev/null
}

mc_cr_github() {
  local f="${1:-}" slug="${2:-}" n="${3:-}" url="${4:-}" head="${5:-}" t rc=0 at sat t0 obj fields
  [ -n "$f" ] || return 2
  t=$(mktemp "${TMPDIR:-/tmp}/mc-cr-gh.XXXXXX") || { printf 'unreadable\n' > "$f"; return 0; }
  t0=$(( $(date -u +%s) - $(mc_cr_sync_skew_s) ))
  sat=$(_mc_iso_of "$t0"); at=$(_mc_iso_of "$((t0 - 1))")
  BG_CR_ROWS=""; BG_CR_ROWS_OK=0
  bg_cr_standing "$slug" "$n" "$url" "$head" "" > "$t" || rc=$?
  case "$rc" in
    0) { printf 'stands\n'; head -1 "$t"; printf '\n'; } > "$f" ;;
    1) printf 'none\n' > "$f" ;;
    *) printf 'unreadable\n' > "$f" ;;
  esac
  rm -f "$t"
  if { [ "$rc" = 0 ] || [ "$rc" = 1 ]; } && [ "$BG_CR_ROWS_OK" = 1 ] && [[ "$head" =~ ^[0-9a-fA-F]{40}$ ]] \
     && command -v prr_step >/dev/null 2>&1 && [ "$(prr_step merge-conductor)" = record ] \
     && command -v pr_record_put >/dev/null 2>&1 && obj=$(printf '%s' "$BG_CR_ROWS" | _mc_cr_reviews_obj) && [ -n "$obj" ]; then
    fields=$(jq -nc --argjson r "$obj" --arg h "$(printf '%s' "$head" | tr 'A-F' 'a-f')" --arg at "$sat" --argjson cr "$([ "$rc" = 0 ] && echo 1 || echo 0)" \
      '{reviews: $r, reviews_sync: {head_sha: $h, at: $at, cr: $cr}}') \
      && pr_record_put "$(printf '%s' "$slug" | tr 'A-Z' 'a-z')" "$n" github "$fields" "$at" >/dev/null 2>&1
  fi
  return 0
}

mc_cr_norm() {
  local w
  w=$(head -1 "${1:-}" 2>/dev/null)
  [ -n "$w" ] && jq -nc --arg v "$w" '[{n:"cr", v:$v}]'
}
