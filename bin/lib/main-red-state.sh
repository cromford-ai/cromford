#!/bin/bash
# shellcheck shell=bash
# bin/lib/main-red-state.sh — the main-red lanes' records as rows (BH-4156).
# Sourced by bin/main-red-detector.sh, bin/main-red-pr-pair.sh and
# bin/main-red-recheck.sh, never run. The routes are
# worker/jobs/src/routes/main-red-state.js; the two marker rows use /api/ledger
# through job_ledger_get / job_ledger_put (bin/lib/jobs/jobs.sh).
#
# Every verb needs _jobs_req (bin/jobs-client.sh, sourced by the caller first).
# This file reads no root and builds no path: the file fallback lives in the
# lanes, which own their state/main-red/ paths.
#
# THE RETURN CODES are the same for every verb:
#   0  the row was read or written
#   3  (reads only) the worker answered and there is no row: a measured none
#   2  use today's file: there is no coordination DB on this box (mrs_on is
#      rc 1), or the worker answered 404 because it predates these routes (a
#      box synced before the worker deploy)
#   1  could not read or write: an outage, a refused request (400), a 500, or
#      an answer that does not parse. A reader must NOT act on it: it is
#      neither "no row" nor "use the file".

# mrs_on — rc 0 when this box has a coordination DB to keep the rows in: the
# client is loaded, JOBS_URL is set and HARNESS_SECRET is set. rc 1 is "no DB
# here", the per-box files jobs-client already falls back to (BH-1957), so
# every verb answers rc 2 and the lane keeps today's file.
mrs_on() {
  command -v _jobs_req >/dev/null 2>&1 || return 1
  [ -n "${JOBS_URL:-}" ] && [ -n "${HARNESS_SECRET:-}" ]
}

# _mrs_req <method> <path> [body] — _jobs_req with this file's return codes.
# Prints the 2xx payload. A 404 is rc 2 (the route is not deployed: these
# routes never answer 404 for a missing row). Anything else that is not a 2xx
# is rc 1.
_mrs_req() {
  mrs_on || return 2
  local out rc
  out=$(_jobs_req "$@"); rc=$?
  case "$rc" in
    0) printf '%s' "$out"; return 0 ;;
    2) return 2 ;;
    *) return 1 ;;
  esac
}

# _mrs_uri <text> — the text as one URL query value.
_mrs_uri() { jq -rn --arg v "$1" '$v|@uri'; }

# mrs_verdict_put <owner/repo> <decision> <reason> <sha>
mrs_verdict_put() {
  local body out
  body=$(jq -nc --arg r "$1" --arg d "$2" --arg why "${3:-}" --arg s "${4:-}" \
    '{repo:$r, decision:$d, reason:$why, sha:$s}') || return 1
  out=$(_mrs_req PUT /api/main-red-state/verdict "$body") || return $?
  jq -e '.verdict.decision | strings' >/dev/null 2>&1 <<<"$out" || return 1
}

# mrs_verdict_get <owner/repo> — prints "decision<TAB>reason<TAB>sha<TAB>at".
mrs_verdict_get() {
  local out q
  q=$(_mrs_uri "$1") || return 1
  out=$(_mrs_req GET "/api/main-red-state/verdict?repo=$q") || return $?
  jq -e 'has("verdict")' >/dev/null 2>&1 <<<"$out" || return 1
  jq -e '.verdict == null' >/dev/null 2>&1 <<<"$out" && return 3
  jq -er '.verdict | select(.decision | type == "string")
          | [.decision, (.reason // ""), (.sha // ""), (.at // "")] | @tsv' <<<"$out" 2>/dev/null || return 1
}

# mrs_pr_errors_get <owner/repo> <out-file> <head>... — the rows of those heads
# as "head<TAB>job<TAB>error<TAB>run_at" lines in <out-file>. A head with no
# row has no line. Asks 50 heads a request. rc 0 only when every request
# answered: a part-read is rc 1, never a short list read as "no rows".
mrs_pr_errors_get() {
  local repo="$1" out="$2" q heads resp rc=0 chunk=()
  shift 2
  : > "$out" || return 1
  q=$(_mrs_uri "$repo") || return 1
  while [ $# -gt 0 ]; do
    chunk=("${@:1:50}"); shift "${#chunk[@]}"
    heads=$(IFS=,; printf '%s' "${chunk[*]}")
    resp=$(_mrs_req GET "/api/main-red-state/pr-errors?repo=$q&heads=$heads") || { rc=$?; : > "$out"; return "$rc"; }
    jq -er '.rows | arrays | .[] | [.head, .job, .error, .run_at] | @tsv' <<<"$resp" >> "$out" 2>/dev/null \
      || jq -e '.rows | arrays | length == 0' >/dev/null 2>&1 <<<"$resp" \
      || { : > "$out"; return 1; }
  done
  return 0
}

# mrs_pr_error_put <owner/repo> <head> <job> <error> <run_at> — write-once; a
# stored error that starts with "##[" is replaced (BH-5988). rc 0 either way.
mrs_pr_error_put() {
  local body out
  body=$(jq -nc --arg r "$1" --arg h "$2" --arg j "$3" --arg e "$4" --arg t "$5" \
    '{repo:$r, head:$h, job:$j, error:$e, run_at:$t}') || return 1
  out=$(_mrs_req PUT /api/main-red-state/pr-errors "$body") || return $?
  jq -e '.row.head | strings' >/dev/null 2>&1 <<<"$out" || return 1
}

# mrs_pr_errors_prune <owner/repo> <days> — delete that repo's rows older than <days>.
mrs_pr_errors_prune() {
  local body out
  body=$(jq -nc --arg r "$1" --arg d "$2" '{repo:$r, days:$d}') || return 1
  out=$(_mrs_req POST /api/main-red-state/pr-errors/prune "$body") || return $?
  jq -e '.deleted | numbers' >/dev/null 2>&1 <<<"$out" || return 1
}

# mrs_pairs_open <owner/repo> <out-file> — the open pairs as
# "hash<TAB>job<TAB>first_error<TAB>prs<TAB>opened_at" lines. A truncated
# answer is rc 1: a partial list must not resolve or re-send anything.
mrs_pairs_open() {
  local out q
  : > "$2" || return 1
  q=$(_mrs_uri "$1") || return 1
  out=$(_mrs_req GET "/api/main-red-state/pairs?repo=$q") || return $?
  jq -e '(.pairs | arrays) and (.truncated == false)' >/dev/null 2>&1 <<<"$out" || return 1
  jq -r '.pairs[] | [.hash, .job, (.first_error // ""), (.prs // ""), .opened_at] | @tsv' <<<"$out" > "$2" 2>/dev/null \
    || { : > "$2"; return 1; }
}

# mrs_pair_open <owner/repo> <hash> <job> <first_error> <prs> — rc 0 when the
# pair is open after the call (opened now, or already open).
mrs_pair_open() {
  local body out
  body=$(jq -nc --arg r "$1" --arg h "$2" --arg j "$3" --arg e "$4" --arg p "$5" \
    '{repo:$r, hash:$h, job:$j, first_error:$e, prs:$p}') || return 1
  out=$(_mrs_req POST /api/main-red-state/pairs "$body") || return $?
  jq -e '.opened | type == "boolean"' >/dev/null 2>&1 <<<"$out" || return 1
}

# mrs_pair_resolve <owner/repo> <hash> — stamp the open row resolved. rc 0
# also when no row was open (nothing left to stamp).
mrs_pair_resolve() {
  local body out
  body=$(jq -nc --arg r "$1" --arg h "$2" '{repo:$r, hash:$h}') || return 1
  out=$(_mrs_req POST /api/main-red-state/pairs/resolve "$body") || return $?
  jq -e '.resolved | numbers' >/dev/null 2>&1 <<<"$out" || return 1
}

# _mrs_ledger_get <kind> <key> — prints the row status. rc 0 row, 3 no row,
# 2 no DB here or no ledger verb, 1 unreadable. /api/ledger answers 404 for a
# missing row, so a 404 here is a measured none, not an undeployed route.
_mrs_ledger_get() {
  mrs_on && command -v job_ledger_get >/dev/null 2>&1 || return 2
  local out rc
  out=$(job_ledger_get "$1" "$2"); rc=$?
  case "$rc" in
    0) printf '%s' "$out"; return 0 ;;
    2) return 3 ;;
    *) return 1 ;;
  esac
}
# _mrs_ledger_put <kind> <key> <status> — rc 0 written, 2 no DB here, no
# ledger verb or a 404 (a real ledger PUT never answers 404), 1 not written.
_mrs_ledger_put() {
  mrs_on && command -v job_ledger_put >/dev/null 2>&1 || return 2
  job_ledger_put "$1" "$2" "$3"
  case "$?" in 0) return 0 ;; 2) return 2 ;; *) return 1 ;; esac
}

# mrs_published_get <flag-name> — rc 0 when the published marker row says on,
# 3 when it says off or there is no row, 2 no DB here, 1 unreadable.
mrs_published_get() {
  local s rc
  s=$(_mrs_ledger_get main_red_published "$1"); rc=$?
  [ "$rc" = 0 ] || return "$rc"
  case "$s" in on) return 0 ;; off) return 3 ;; *) return 1 ;; esac
}
# mrs_published_set <flag-name> on|off
mrs_published_set() {
  case "${2:-}" in on|off) ;; *) return 1 ;; esac
  _mrs_ledger_put main_red_published "$1" "$2"
}

# mrs_recheck_get — prints the last recheck epoch. rc 0, 3 none, 2, 1.
mrs_recheck_get() {
  local s rc
  s=$(_mrs_ledger_get main_red_recheck last); rc=$?
  [ "$rc" = 0 ] || return "$rc"
  case "$s" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$s"
}
# mrs_recheck_set <epoch>
mrs_recheck_set() {
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
  _mrs_ledger_put main_red_recheck last "$1"
}
