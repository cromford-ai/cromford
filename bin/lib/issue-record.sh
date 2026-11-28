#!/bin/bash
# bin/lib/issue-record.sh — the fleet's own record of an issue or PR thread
# (BH-10199, slice 1). Sourced, never executed. Defines functions only: no
# set -e, no exit, nounset-safe.
#
# The record is issue_records + issue_comments + issue_record_syncs in the
# jobs D1 (worker/jobs/src/routes/issue-records.js). Webhooks (issues,
# issue_comment, pull_request) write it in the wake batch; this file writes a
# full GitHub read back (PUT) and runs the per-repo list backstop.
#
# THE VERSION MARKS, in this order (ticket comment 2026-11-26 10:38):
#   1. The webhook delivery that writes the `wakes` row writes the record in
#      the same batch. 0 GitHub calls. The change mark is the record's `rev`,
#      not the wake id: two events in one minute share one wakes row.
#   2. issue_record_sync: one list read per repo, at most once per
#      issue_records.sync_every_s across the fleet (the worker's claim):
#      issues?state=all&since=<mark>&sort=updated&direction=asc. A thread
#      GitHub moved past the record is marked stale (a lost webhook).
#   3. comments?since and a stored ETag: the next slice. gh_rest already
#      sends a box-local If-None-Match.
#
#   issue_record_peek <owner/repo> <n> <out> [markdir]
#       ONE jobs GET. rc 0: the record is ready; <out> holds
#       {"issue": {number, state, title, body, labels: [{name}], updated_at},
#        "comments": [{id, body, created_at, updated_at, user: {login, type}}]}.
#       Else rc 1, an empty <out>, and one miss word on stdout: unreadable
#       (the jobs read failed), malformed, or the worker's word (no-record
#       no-backfill stale backfill-old no-sync sync-old truncated too-many).
#       With [markdir], when the jobs read answered: <markdir>/rev holds the
#       record's rev (0 = no row) and <markdir>/row the row. A failed read
#       writes neither: no write-back can follow an unknown base.
#
#   issue_record_put <owner/repo> <n> <base_rev> <thread-file>
#       One PUT of a full GitHub read: <thread-file> is {"issue": <REST issue
#       or null>, "comments": [<REST comments>]}. rc 0 applied; rc 1 refused
#       (the rev moved: a webhook landed during the read), bad args or a
#       failed request. Writes no file.
#
#   issue_record_sync <owner/repo>
#       The list backstop. One jobs claim; not due = rc 0 and 0 GitHub calls.
#       No claim at all when this box claimed the repo inside the worker's
#       every_s (the marker state/issue-record-claim/<owner>_<repo>).
#       Due: the list pages (at most the claim's pages_max), then ONE POST
#       with the claim's `started` (worker clock). A page that does not read
#       or parse = rc 1 and no POST: nothing is written and the mark does not
#       move (the claim lease ends by itself).
#
#   irr_step
#       off, shadow or record: $IRR_STEP (the lane's knob GH_SOURCE_ISSUES),
#       `shadow` when it is empty, `shadow` plus one PRR_STEP line for any
#       other value.
#
#   irr_read <thread|comments> <github-fn> <owner/repo> <n> <out>
#       The reader seam, for the lane named in $IRR_LANE. thread = the issue
#       and its comments (hold_read); comments = the comments only
#       (hold_check_thread). <github-fn> <out> <owner/repo> <n> is the
#       caller's own GitHub read, which writes the same JSON shape and returns
#       its rc. Step off: the github-fn alone (0 jobs calls). Step shadow and
#       record: issue_record_sync first, then prr_read <lane>
#       "<repo>#<n>@<kind>" (bin/lib/prr-shadow.sh): shadow acts on GitHub and
#       logs PRR_SHADOW when the record differs; record acts on the record and
#       reads GitHub on a miss (PRR_MISS). After a GitHub answer (rc 0) that
#       the record missed or that differs, the answer is written back
#       (issue_record_put) with the rev the record read saw BEFORE the GitHub
#       read. Returns the rc of the source in <out>.
#
# Log: <root>/logs/issue-record.log (root ${HARNESS:-${H:-}}):
#   <UTC> sync <repo> due=<0|1> pages=<n> items=<n> complete=<0|1> rc=<rc>
#   <UTC> put <repo>#<n> base=<rev> applied=<0|1>
if [ -n "${_ISSUE_RECORD_LOADED:-}" ]; then return 0 2>/dev/null; fi
_ISSUE_RECORD_LOADED=1
_IRR_DIR="${BASH_SOURCE[0]%/*}"

_irr_root() { local r="${HARNESS:-${H:-}}"; [ -n "$r" ] || return 1; printf '%s' "$r"; }
_irr_log() {
  local root; root=$(_irr_root) || return 0
  mkdir -p "$root/logs" 2>/dev/null
  printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >> "$root/logs/issue-record.log" 2>/dev/null || true
}
_irr_args_ok() { [[ "${1:-}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] && [[ "${2:-}" =~ ^[1-9][0-9]{0,9}$ ]]; }
_irr_lower() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }

# _irr_client — rc 0 when _jobs_req exists. Sources bin/jobs-client.sh when
# it does not, and restores nounset and pipefail (the _prr_client pattern).
_irr_client() {
  local root pf nu=0
  command -v _jobs_req >/dev/null 2>&1 && return 0
  root=$(_irr_root) || return 1
  [ -r "$root/bin/jobs-client.sh" ] || return 1
  ( . "$root/bin/jobs-client.sh" ) >/dev/null 2>&1 || return 1
  case $- in *u*) nu=1 ;; esac
  pf=$(set -o 2>/dev/null | awk '$1=="pipefail"{print $2}')
  # shellcheck source=bin/jobs-client.sh
  . "$root/bin/jobs-client.sh" >/dev/null 2>&1 || true
  [ "$pf" = off ] && set +o pipefail
  [ "$nu" = 0 ] && set +u
  command -v _jobs_req >/dev/null 2>&1
}

issue_record_peek() {
  local repo="${1:-}" n="${2:-}" out="${3:-}" md="${4:-}" ans why
  _irr_args_ok "$repo" "$n" && [ -n "$out" ] || { echo unreadable; return 1; }
  : > "$out" 2>/dev/null
  if ! _irr_client || ! ans=$(_jobs_req GET "/api/issue-records?repo=$(_irr_lower "$repo")&number=$n"); then
    echo unreadable; return 1
  fi
  if ! jq -e 'type == "object" and has("row") and has("why") and (.comments | type) == "array"' <<<"$ans" >/dev/null 2>&1; then
    echo malformed; return 1
  fi
  if [ -n "$md" ] && [ -d "$md" ]; then
    jq -r 'if (.row | type) == "object" then (.row.rev // 0) else 0 end' <<<"$ans" > "$md/rev" 2>/dev/null
    jq -c '.row' <<<"$ans" > "$md/row" 2>/dev/null
  fi
  why=$(jq -r '.why // empty' <<<"$ans" 2>/dev/null)
  if [ -n "$why" ]; then printf '%s\n' "$why"; return 1; fi
  if ! jq -c --argjson n "$n" '{
        issue: {number: $n, state: .row.state, title: (.row.title // ""), body: (.row.body // ""),
                labels: [(.row.labels // [])[] | {name: .}], updated_at: .row.gh_updated_at},
        comments: [.comments[] | {id: .comment_id, body: (.body // ""), created_at: .gh_created_at,
                updated_at: .gh_updated_at, user: {login: (.author // ""), type: (.author_type // "User")}}]}' \
        <<<"$ans" > "$out" 2>/dev/null; then
    : > "$out"; echo malformed; return 1
  fi
  return 0
}

issue_record_put() {
  local repo="${1:-}" n="${2:-}" base="${3:-}" f="${4:-}" body ans
  _irr_args_ok "$repo" "$n" && [[ "$base" =~ ^[0-9]{1,15}$ ]] && [ -r "$f" ] || return 1
  body=$(jq -c --arg r "$(_irr_lower "$repo")" --argjson n "$n" --argjson b "$base" '
      {repo: $r, number: $n, base_rev: $b, issue: (.issue // null),
       comments: [(.comments // [])[] | {id, body, created_at, updated_at, user: {login: (.user.login // null), type: (.user.type // null)}}]}' \
      "$f" 2>/dev/null) || return 1
  [ -n "$body" ] && _irr_client || return 1
  if ans=$(_jobs_req PUT /api/issue-records "$body") && jq -e '.applied == true' <<<"$ans" >/dev/null 2>&1; then
    _irr_log "put $(_irr_lower "$repo")#$n base=$base applied=1"; return 0
  fi
  _irr_log "put $(_irr_lower "$repo")#$n base=$base applied=0"
  return 1
}

# THE CLAIM MARKER (review of #10343): state/issue-record-claim/<owner>_<repo>,
# one line `<epoch>\t<every_s>`, written tmp+mv after each claim answer (due
# or not; a failed claim writes none). Both values are this box's: the epoch
# is its clock (IRR_NOW, a fixture epoch, in tests), every_s the worker's
# issue_records.sync_every_s row from the answer. Losing it costs one claim.
_irr_now() { if [[ "${IRR_NOW:-}" =~ ^[0-9]{1,12}$ ]]; then printf '%s' "$IRR_NOW"; else date -u +%s; fi; }
_irr_claim_file() { local root; root=$(_irr_root) || return 1; printf '%s/state/issue-record-claim/%s' "$root" "${1//\//_}"; }
_irr_claim_fresh() { # <lower-repo> — rc 0 when this box claimed the repo inside every_s
  local f at ev now
  f=$(_irr_claim_file "$1") && [ -r "$f" ] || return 1
  IFS=$'\t' read -r at ev < "$f" || return 1
  [[ "$at" =~ ^[0-9]{1,12}$ ]] && [[ "$ev" =~ ^[1-9][0-9]{0,5}$ ]] || return 1
  now=$(_irr_now)
  [ "$now" -ge "$at" ] && [ $((now - at)) -lt "$ev" ]
}
_irr_claim_mark() { # <lower-repo> <every_s>
  local f
  [[ "${2:-}" =~ ^[1-9][0-9]{0,5}$ ]] || return 0
  f=$(_irr_claim_file "$1") || return 0
  mkdir -p "${f%/*}" 2>/dev/null || return 0
  printf '%s\t%s\n' "$(_irr_now)" "$2" > "$f.tmp.$$" 2>/dev/null && mv -f "$f.tmp.$$" "$f" 2>/dev/null
  rm -f "$f.tmp.$$" 2>/dev/null
  return 0
}

issue_record_sync() {
  local repo="${1:-}" lr ans since started pmax d p rc=0 len items mark complete=0 body
  [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
  lr=$(_irr_lower "$repo")
  # The box-local skip (review of #10343): no claim POST for the repo inside
  # the worker's every_s after this box's last claim answer.
  _irr_claim_fresh "$lr" && return 0
  _irr_client || return 1
  ans=$(_jobs_req POST /api/issue-record-syncs/claim "$(jq -nc --arg r "$lr" '{repo: $r}')") || return 1
  _irr_claim_mark "$lr" "$(jq -r '.every_s // empty' <<<"$ans" 2>/dev/null)"
  jq -e '.due == true' <<<"$ans" >/dev/null 2>&1 || return 0
  since=$(jq -r '.since // empty' <<<"$ans"); started=$(jq -r '.started // empty' <<<"$ans")
  pmax=$(jq -r '.pages_max // empty' <<<"$ans")
  [ -n "$since" ] && [ -n "$started" ] && [[ "$pmax" =~ ^[1-9][0-9]{0,2}$ ]] || return 1
  command -v gh_rest >/dev/null 2>&1 || return 1
  d=$(mktemp -d "${TMPDIR:-/tmp}/irr-sync.XXXXXX") || return 1
  p=0
  while [ "$p" -lt "$pmax" ]; do
    p=$((p + 1))
    rc=0; gh_rest GET "repos/$repo/issues?state=all&since=$since&sort=updated&direction=asc&per_page=100&page=$p" > "$d/p$p" 2>/dev/null || rc=$?
    if [ "$rc" != 0 ] || ! jq -e 'type == "array"' "$d/p$p" >/dev/null 2>&1; then
      _irr_log "sync $lr due=1 pages=$p items=0 complete=0 rc=${rc/#0/1}"
      rm -rf "$d"; return 1
    fi
    len=$(jq 'length' "$d/p$p")
    [ "$len" -lt 100 ] && { complete=1; break; }
  done
  items=$(jq -sc '[.[][] | {number, state, title, body, labels: [(.labels // [])[] | {name: (.name // .)}],
      updated_at, pull_request: (if .pull_request then {} else null end)}]' "$d"/p* 2>/dev/null) || { rm -rf "$d"; return 1; }
  rm -rf "$d"
  mark=$(jq -r '[.[].updated_at | strings] | max // empty' <<<"$items")
  body=$(jq -c --arg r "$lr" --arg s "$started" --arg m "$mark" --argjson c "$([ "$complete" = 1 ] && echo true || echo false)" \
      '{repo: $r, started: $s, mark: (if $m == "" then null else $m end), complete: $c, items: .}' <<<"$items") || return 1
  rc=0; _jobs_req POST /api/issue-record-syncs "$body" >/dev/null || rc=1
  _irr_log "sync $lr due=1 pages=$p items=$(jq length <<<"$items") complete=$complete rc=$rc"
  return "$rc"
}

irr_step() {
  case "${IRR_STEP:-}" in
    off|shadow|record) printf '%s\n' "$IRR_STEP" ;;
    '') printf 'shadow\n' ;;
    *) command -v _prr_shadow_log >/dev/null 2>&1 && _prr_shadow_log "PRR_STEP lane=${IRR_LANE:-} bad=$IRR_STEP"
       printf 'shadow\n' ;;
  esac
}

# The compare forms (prr_read's norm-fn): a JSON array of objects keyed on .n.
irr_thread_norm() {
  jq -c '[{n: "issue", s: (.issue.state // ""), t: (.issue.title // ""), b: (.issue.body // ""),
            l: ([(.issue.labels // [])[] | if type == "object" then (.name // "") else tostring end] | sort)}]
         + [(.comments // [])[] | {n: .id, b: (.body // ""), c: (.created_at // ""), u: ((.user.type // "") | ascii_downcase)}]
         | sort_by(.n | tostring)' "${1:-}" 2>/dev/null
}
irr_comments_norm() {
  jq -c '[(.comments // [])[] | {n: .id, b: (.body // ""), c: (.created_at // ""), u: ((.user.type // "") | ascii_downcase)}]
         | sort_by(.n)' "${1:-}" 2>/dev/null
}

# The record-fns: <file> <owner/repo> <n> <markdir>. A hit also leaves the
# compare form in <markdir>/norm, so the shadow step can see a difference.
irr_thread_record() {
  local why
  why=$(issue_record_peek "${2:-}" "${3:-}" "${1:-}" "${4:-}") || { printf '%s\n' "${why:-unreadable}"; return 1; }
  [ -d "${4:-}" ] && irr_thread_norm "${1:-}" > "$4/norm" 2>/dev/null
  return 0
}
irr_comments_record() {
  local why
  why=$(issue_record_peek "${2:-}" "${3:-}" "${1:-}" "${4:-}") || { printf '%s\n' "${why:-unreadable}"; return 1; }
  jq -c '{comments}' "$1" > "$1.c" 2>/dev/null && mv "$1.c" "$1" || { : > "$1"; echo malformed; return 1; }
  [ -d "${4:-}" ] && irr_comments_norm "$1" > "$4/norm" 2>/dev/null
  return 0
}

# The write-back (prr_read's <prefix>_note in step record, irr_read's in
# shadow): <out> <github-rc> <why> <owner/repo> <n> <markdir>. Only a GitHub
# rc 0 and a base rev the record read saw. comments: issue null, a stored row only.
irr_thread_note() {
  [ "${2:-}" = 0 ] && [ -r "${6:-}/rev" ] || return 0
  local base; base=$(tr -dc '0-9' < "$6/rev")
  [ -n "$base" ] && jq -e '(.issue | type) == "object" and (.comments | type) == "array"' "${1:-}" >/dev/null 2>&1 || return 0
  issue_record_put "${4:-}" "${5:-}" "$base" "$1" || true
}
irr_comments_note() {
  [ "${2:-}" = 0 ] && [ -r "${6:-}/rev" ] || return 0
  local base f; base=$(tr -dc '0-9' < "$6/rev")
  [ -n "$base" ] || return 0
  if [ "$base" = 0 ]; then irr_comments_seed "$@"; return 0; fi
  f=$(mktemp "${TMPDIR:-/tmp}/irr-note.XXXXXX") || return 0
  jq -c '{issue: null, comments}' "${1:-}" > "$f" 2>/dev/null && issue_record_put "${4:-}" "${5:-}" "$base" "$f" || true
  rm -f "$f"
}
# irr_comments_seed (BH-10485): the record had no row, so a comments-only
# write cannot land (the worker needs a stored row for `issue: null`) and the
# same thread would miss on every pass. One issues/N read, once per issue,
# makes the write a whole thread (base 0), which creates the row; later reads
# are record hits. A failed or odd issues/N read writes nothing, as before.
irr_comments_seed() {
  local repo="${4:-}" n="${5:-}" ij f rc=0
  command -v gh_rest >/dev/null 2>&1 && _irr_args_ok "$repo" "$n" || return 0
  ij=$(mktemp "${TMPDIR:-/tmp}/irr-seed.XXXXXX") || return 0
  GH_REASON=record-miss:no-record gh_rest GET "repos/$repo/issues/$n" > "$ij" 2>/dev/null || rc=$?
  if [ "$rc" = 0 ] && jq -e 'type == "object" and has("number") and has("state")' "$ij" >/dev/null 2>&1; then
    f="$ij.t"
    jq -c --slurpfile i "$ij" '{issue: $i[0], comments}' "${1:-}" > "$f" 2>/dev/null \
      && issue_record_put "$repo" "$n" 0 "$f" || true
    rm -f "$f"
  fi
  rm -f "$ij"
}

irr_read() {
  local kind="${1:-}" gfn="${2:-}" repo="${3:-}" n="${4:-}" out="${5:-}" lane="${IRR_LANE:-}" step md rc nr ng
  case "$kind" in thread|comments) ;; *) return 2 ;; esac
  [ -n "$out" ] && [ -n "$gfn" ] || return 2
  step=$(irr_step)
  if [ "$step" = off ] || [ -z "$lane" ] || ! command -v prr_read >/dev/null 2>&1; then
    "$gfn" "$out" "$repo" "$n"; return $?
  fi
  md=$(mktemp -d "${TMPDIR:-/tmp}/irr-read.XXXXXX") || { "$gfn" "$out" "$repo" "$n"; return $?; }
  issue_record_sync "$repo" >/dev/null 2>&1 || true
  GH_SOURCE="$step" GH_SOURCE_LANE="$lane" \
    prr_read "$lane" "$(_irr_lower "$repo")#$n@$kind" "$out" "irr_${kind}_record" "$gfn" "irr_${kind}_norm" "$repo" "$n" "$md"
  rc=$?
  # Shadow: write GitHub's answer back when the record missed or differs.
  if [ "$step" = shadow ] && [ "$rc" = 0 ]; then
    nr=$(cat "$md/norm" 2>/dev/null); ng=$("irr_${kind}_norm" "$out")
    [ -n "$nr" ] && [ "$nr" = "$ng" ] || "irr_${kind}_note" "$out" 0 shadow "$repo" "$n" "$md"
  fi
  rm -rf "$md"
  return "$rc"
}
