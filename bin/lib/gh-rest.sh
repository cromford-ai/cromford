#!/bin/bash
# bin/lib/gh-rest.sh — the GitHub REST read every decision path goes through.
# Sourced, never executed.
#
# THE INCIDENT (#768, 2026-09-18 02:49-03:05Z). The GraphQL-backed CLI got
# rate-limited and answered an empty string. The decision path read that silence
# as "no such PR": five real PRs were rewritten RESULT_UNVERIFIED and TK-2302 was
# launched three times. The three exit codes below exist so "GitHub said no such
# thing" can never again be read off the same silence as "GitHub said come back
# later".
#
# THE RULE THE CALLERS OBEY:
#   rc 0   2xx. Act on the body. An empty LIST ([]) under rc 0 is a real
#          "nothing there", not an unknown. A cache HIT (BH-1295: a GET that
#          answered 304 against a cached ETag) is ALSO rc 0 — GH_REST_STATUS
#          is 304, GH_REST_REASON is "cached", and the body is the cached one,
#          byte for byte what the original 2xx read printed. A caller that
#          only checks the rc sees no difference; one that checks the reason
#          can tell a fresh read from a replay.
#   rc 44  HTTP 404. ABSENT, act on it.
#   rc 75  UNVERIFIABLE. 403/429 rate limit, any other non-2xx, 000/network, a
#          malformed slug or number, an EMPTY body on a 2xx GET, or a 304 whose
#          cached body is gone (GH_REST_REASON "cache-miss" — never treated as
#          an empty answer standing in for a state). Skip this tick, log, leave
#          state exactly as it is. 75 is the #769 shim's code. BH-1484 adds ONE
#          new way to reach 75 and it is the only one the API never hears about:
#          GH_REST_REASON "quota-reserve", a read the CALLER marked optional
#          (GH_REST_OPTIONAL=1) refused BEFORE the request because the shared
#          installation bucket is below its reserve. Same contract as every
#          other 75 — skip this tick, leave state as it is.
#
# READING THE STATUS. GH_REST_STATUS (3 digits, or 000 when no status line came
# back) and GH_REST_REASON (rate-limit | network | empty | bad-args |
# quota-reserve | auth | auth-skipped | empty string) are set in the shell that
# CALLS a helper. `auth` is a 401. `auth-skipped` is a call refused with no
# request, status 401, because an earlier call of the same conductor worker got
# a 401 (BH-6346, bin/lib/gh-rest-auth.sh); outside a worker it never occurs. The
# SAME SCOPE RULE governs GH_REST_QUOTA_REMAINING / GH_REST_QUOTA_LIMIT /
# GH_REST_QUOTA_RESET / GH_REST_QUOTA_RETRY_AFTER (BH-1484: the `X-RateLimit-*`
# and `Retry-After` headers of the response just read, EMPTY when the response
# carried none — never 0, because a bucket nobody read must not look like a
# bucket that is empty). When you need the status
# after a helper, run the helper as a plain command with `> file` and read the
# file; a helper inside `$( )` still returns the right rc, but its status stays
# in the subshell that then died. The helpers here obey their own rule: none of
# them wraps gh_rest in a command substitution. BH-781 hit exactly this and
# every alert said "HTTP 000" for a 403 the library had classified correctly.
#
# NO CALLER IS CONVERTED HERE. #781..#784 move the lanes onto these helpers, so
# the names, the argument orders and the three exit codes are frozen; only the
# internals below belong to this file.
#
# gh-rest: no-graphql
#
# THIS LIBRARY MINTS NO TOKEN. A lane that wants the App identity arms it with
# `gh_auth_for` from `bin/lib/gh-app-auth.sh` before its first helper call;
# gh_rest_alert reports which identity was in force as a LABEL, never a value.
#
# No `set -e`, no `exit`, no side effect at source time: sourcing this file in
# any lane costs zero API budget and cannot kill the lane. Inside the helpers
# every fallible call is written `cmd || rc=$?`, never `cmd; rc=$?`, so a caller
# running under `set -e` reaches the 44/75 mapping and leaves no temp file
# behind. That caller still exits on the non-zero return itself, which is what
# errexit is for; a lane that wants to act on 44 or 75 writes
# `helper … > f || rc=$?` (or `if ! helper …`) the same as anywhere else.
if [ -n "${GH_REST_LIB:-}" ]; then return 0 2>/dev/null; fi
GH_REST_LIB=1
GH_REST_STATUS=000
GH_REST_REASON=

# BH-1295: the ETag/If-None-Match cache. Its mechanics (key hashing, the
# on-disk format, the TTL/size sweep) live in a second file for the reason
# bin/lib/gh-rest-list.sh's own header gives — this file is held under a
# code-line ceiling on purpose. A box missing the file loses caching, not
# correctness: every `command -v _gh_etag_*` below is false, `use_etag` never
# goes to 1, and gh_rest behaves exactly as it did before this file existed.
[ -r "$(dirname "${BASH_SOURCE[0]}")/gh-rest-etag.sh" ] && . "$(dirname "${BASH_SOURCE[0]}")/gh-rest-etag.sh" 2>/dev/null

# BH-1484: the quota ledger and the reserve gate, in a third file for exactly
# the reason above — header parsing, the path classifier, the ledger writer, the
# 48h sweep and the reserve resolution are a lane's worth of code and this file
# is a contract held under a code-line ceiling. A box missing the file loses the
# ledger and the gate, not correctness: both `command -v` tests below are then
# false and gh_rest behaves exactly as it did before this file existed.
[ -r "$(dirname "${BASH_SOURCE[0]}")/gh-rest-ledger.sh" ] && . "$(dirname "${BASH_SOURCE[0]}")/gh-rest-ledger.sh" 2>/dev/null

# BH-6346: the 401 stop of a conductor worker, in a sibling for the same reason.
# A box missing the file sends every call, as before.
[ -r "$(dirname "${BASH_SOURCE[0]}")/gh-rest-auth.sh" ] && . "$(dirname "${BASH_SOURCE[0]}")/gh-rest-auth.sh" 2>/dev/null

_gh_rest_args_ok() { # _gh_rest_args_ok <slug> [num]
  [[ "${1:-}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
  if [ $# -ge 2 ]; then [[ "${2:-}" =~ ^[0-9]+$ ]] || return 1; fi
  return 0
}

_gh_rest_bad_args() { GH_REST_STATUS=000; GH_REST_REASON=bad-args; return 75; }

# Only the words GitHub actually uses, and only on the two statuses that can
# mean it (D10). A 2xx body that happens to say "abuse" is a successful read.
_gh_rest_sniff() {
  local b
  b=$(printf '%s' "${1:-}" | tr 'A-Z' 'a-z')
  case "$b" in
    *"rate limit"*|*"secondary rate"*|*abuse*) GH_REST_REASON=rate-limit ;;
  esac
  return 0
}

gh_rest() { # gh_rest <method> <path> [extra args for the REST call...]
  # GH_TOKEN is local (C2): the gate may put the App token on THIS call; the caller's shell never keeps it.
  local m="${1:-}" p="${2:-}" tmp st body etagkey= etagval= extra=() use_etag=0 GH_TOKEN="${GH_TOKEN:-}" ct0=""
  if [ -z "$m" ] || [ -z "$p" ]; then _gh_rest_bad_args; return 75; fi
  shift 2
  GH_REST_STATUS=000; GH_REST_REASON=; GH_REST_QUOTA_REMAINING=; GH_REST_QUOTA_LIMIT=; GH_REST_QUOTA_RESET=; GH_REST_QUOTA_RETRY_AFTER=
  # BH-6346. A worker that already got a 401 sends nothing more: refused here,
  # before the quota gate, so the refusal costs no ledger line.
  if command -v _gh_auth_gate >/dev/null 2>&1 && ! _gh_auth_gate; then GH_REST_STATUS=401; GH_REST_REASON=auth-skipped; return 75; fi
  # BH-1484. BEFORE the request, and before the mktemp, so a refused read costs
  # nothing at all. Only a caller that marked itself optional is ever refused.
  if command -v _gh_quota_gate >/dev/null 2>&1 && ! _gh_quota_gate "$p"; then GH_REST_REASON=quota-reserve; return 75; fi
  [ "$m" = GET ] && [ "${GH_ETAG:-1}" != 0 ] && command -v _gh_etag_key >/dev/null 2>&1 && use_etag=1
  # BH-1574: the only exit between the gate and the request; it clears the gate's GH_LEDGER_BY_CALLER marker.
  tmp=$(mktemp "${TMPDIR:-/tmp}/gh-rest.XXXXXX") || { unset GH_LEDGER_BY_CALLER; return 75; }
  # BH-1295: a cached ETag rides as If-None-Match so an unchanged resource
  # answers 304 (not counted against the rate limit) instead of a fresh 200.
  if [ "$use_etag" = 1 ]; then
    etagkey=$(_gh_etag_key "$m" "$p" "$@")
    etagval=$(_gh_etag_read_etag "$etagkey")
    [ -n "$etagval" ] && extra=(-H "If-None-Match: $etagval")
  fi
  # `|| true`: gh exits non-zero on every 4xx/5xx, and an errexit caller must
  # reach the mapping below rather than die on gh's own rc.
  # ${extra[@]+…}: bash < 4.4 (macOS /bin/bash 3.2) calls an empty array unbound under set -u (BH-3565).
  if [ -n "${HARNESS_CALL_TRACE_FILE:-}" ] && command -v call_trace_t0 >/dev/null 2>&1; then call_trace_t0 ct0; fi
  gh api -i -X "$m" "$p" "$@" ${extra[@]+"${extra[@]}"} > "$tmp" 2>/dev/null || true
  # The FIRST status line only, and no pipe: `sed | head` can answer 141 under
  # pipefail and take an errexit caller down with it.
  st=$(sed -n '/^HTTP\/[0-9.]* [0-9][0-9][0-9]/{s/^HTTP\/[0-9.]* \([0-9][0-9][0-9]\).*/\1/p;q;}' "$tmp")
  # BH-6462: one call-trace line per request sent, inside a bounded conductor
  # worker only (bin/lib/call-trace.sh). Method and path, never the args.
  if [ -n "${HARNESS_CALL_TRACE_FILE:-}" ] && command -v call_trace_put >/dev/null 2>&1; then call_trace_put gh "$m $p" "${st:-000}" "$ct0"; fi
  # BH-1484: the quota headers and the ledger line, ONCE, before the status
  # branching below — so the 000/network path is ledgered too, which is the most
  # interesting row in the file the hour the shared bucket drains.
  if command -v _gh_quota_observe >/dev/null 2>&1; then _gh_quota_observe "$tmp" "$m" "$p" "$st"; fi
  if [ -z "$st" ]; then rm -f "$tmp"; GH_REST_REASON=network; return 75; fi
  GH_REST_STATUS=$st
  if [ "$st" = 401 ]; then
    GH_REST_REASON=auth
    if command -v _gh_auth_observe >/dev/null 2>&1; then _gh_auth_observe; fi
  fi
  # A 304 with no cached body left (lost mid-tick) falls through as 75, never
  # as an empty answer a caller could mistake for a real state (BH-1295 spec).
  if [ "$st" = 304 ] && [ "$use_etag" = 1 ]; then
    rm -f "$tmp"
    _gh_etag_on_304 "$etagkey" "$etagval" && { _gh_etag_count cached; return 0; }
    GH_REST_REASON=cache-miss; return 75
  fi
  body=$(awk 'f{print} /^\r?$/{f=1}' "$tmp")
  case "$st" in 403|429) _gh_rest_sniff "$body" ;; esac
  case "$st" in
    2*)
      if [ -z "$body" ] && [ "$m" = GET ]; then rm -f "$tmp"; GH_REST_REASON=empty; return 75; fi
      [ "$use_etag" = 1 ] && [ -n "$body" ] && { _gh_etag_on_2xx "$etagkey" "$tmp" "$body"; _gh_etag_count fetched; }
      rm -f "$tmp"
      if [ -n "$body" ]; then printf '%s\n' "$body"; fi
      return 0 ;;
    404) rm -f "$tmp"; return 44 ;;
    *) rm -f "$tmp"; return 75 ;;
  esac
}

# One read, through a FILE and never a `$( )`, so the status the read produced
# is still in the caller's shell when the caller alerts. Unparseable JSON under
# a 2xx is 75, not an empty answer a caller could mistake for a state.
_gh_rest_field() { # _gh_rest_field <api path> <jq filter>
  local t rc=0 s
  t=$(mktemp "${TMPDIR:-/tmp}/gh-rest.XXXXXX") || return 75
  # `|| rc=$?` and never `cmd; rc=$?`: under a caller's `set -e` the bare form
  # dies on the 44/75 return before the `rm -f` below and leaks the temp file.
  gh_rest GET "$1" > "$t" || rc=$?
  if [ "$rc" != 0 ]; then rm -f "$t"; return "$rc"; fi
  rc=0
  s=$(jq -er "$2" "$t" 2>/dev/null) || rc=$?
  rm -f "$t"
  if [ "$rc" != 0 ] || [ -z "$s" ]; then return 75; fi
  printf '%s\n' "$s"
  return 0
}

gh_rest_pr_state() { # gh_rest_pr_state <slug> <num> -> open|merged|closed
  if ! _gh_rest_args_ok "${1:-}" "${2:-}"; then _gh_rest_bad_args; return 75; fi
  _gh_rest_field "repos/$1/pulls/$2" \
    'if .state=="closed" and .merged_at!=null then "merged" else .state end'
}

gh_rest_pr_list() { # gh_rest_pr_list <slug> <state> [head] [per_page]
  local -a a
  if ! _gh_rest_args_ok "${1:-}" || [ -z "${2:-}" ]; then _gh_rest_bad_args; return 75; fi
  a=(-f "state=$2")
  if [ -n "${3:-}" ]; then a+=(-f "head=$3"); fi
  a+=(-F "per_page=${4:-100}")
  gh_rest GET "repos/$1/pulls" ${a[@]+"${a[@]}"}
}

gh_rest_issue_state() { # gh_rest_issue_state <slug> <num> -> open|closed
  if ! _gh_rest_args_ok "${1:-}" "${2:-}"; then _gh_rest_bad_args; return 75; fi
  _gh_rest_field "repos/$1/issues/$2" '.state'
}

# A 404 here is 75, not 44: the spec gives this one 0 or 75, and posting is not
# a probe. The body goes by FILE so it never reaches argv or a process list.
gh_rest_comment() { # gh_rest_comment <slug> <num> <bodyfile>
  if ! _gh_rest_args_ok "${1:-}" "${2:-}"; then _gh_rest_bad_args; return 75; fi
  if [ ! -r "${3:-}" ]; then _gh_rest_bad_args; return 75; fi
  gh_rest POST "repos/$1/issues/$2/comments" -F "body=@$3" >/dev/null || return 75
  return 0
}

# rc 0 ONLY when a fresh read says closed (D9/D11): "stamped closed without
# being closed" is impossible by construction, and `merged` is not `closed`.
gh_rest_close() { # gh_rest_close <slug> <num> [issues|pulls]
  local kind="${3:-issues}" t rc=0 seen
  if ! _gh_rest_args_ok "${1:-}" "${2:-}"; then _gh_rest_bad_args; return 75; fi
  case "$kind" in issues|pulls) ;; *) _gh_rest_bad_args; return 75 ;; esac
  gh_rest PATCH "repos/$1/$kind/$2" -f state=closed >/dev/null || return 75
  t=$(mktemp "${TMPDIR:-/tmp}/gh-rest.XXXXXX") || return 75
  # The re-read goes to a FILE for the reason the header gives: its status is
  # the one the caller's alert must name.
  if [ "$kind" = pulls ]; then gh_rest_pr_state "$1" "$2" > "$t" || rc=$?
  else gh_rest_issue_state "$1" "$2" > "$t" || rc=$?; fi
  seen=$(cat "$t" 2>/dev/null || true); rm -f "$t"
  if [ "$rc" != 0 ] || [ "$seen" != closed ]; then return 75; fi
  return 0
}

# ONE line, naming the HTTP status and WHICH identity answered, never its value.
# The status is this shell's, which is why the helper above it must have been
# called with `> file`. The rc is the append's own: a lost alert is the only
# signal on a skip path, so it is never swallowed.
gh_rest_alert() { # gh_rest_alert <project> <what> <path>
  local f="${HARNESS:-/root/harness}/logs/ALERTS.log" label=default ts
  if [ -n "${GH_TOKEN:-}" ]; then label=explicit; fi
  ts=$(date -u '+%Y-%m-%d %H:%M:%SZ')
  mkdir -p "${f%/*}" 2>/dev/null
  printf '%s [%s] gh-rest: %s %s HTTP %s%s token=%s, unverifiable, left as-is this tick\n' \
    "$ts" "${1:-?}" "${2:-?}" "${3:-?}" "$GH_REST_STATUS" \
    "${GH_REST_REASON:+ ($GH_REST_REASON)}" "$label" >> "$f" 2>/dev/null
}

# BH-1485: the variable-assigning variants (`gh_rest_pr_state_var st …`), in a
# second file for the same reason gh-rest-etag.sh is one — this file is held
# to its contract functions on purpose (tests/gh-rest-lib-test.sh), and the
# source sits at the END so a sibling editing the helpers above it merges
# without touching this line. A box missing the file loses the variants, not
# the contract: everything above is unchanged, and `|| true` keeps a failed read of it from becoming this file's
# source rc under a caller's `set -e`.
[ -r "$(dirname "${BASH_SOURCE[0]}")/gh-rest-var.sh" ] && . "$(dirname "${BASH_SOURCE[0]}")/gh-rest-var.sh" 2>/dev/null || true
