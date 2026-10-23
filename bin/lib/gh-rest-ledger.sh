#!/bin/bash
# bin/lib/gh-rest-ledger.sh — BH-1484: the GitHub REST quota ledger and the
# reserve gate for bin/lib/gh-rest.sh's `gh_rest`. Sourced by gh-rest.sh, never
# executed.
#
# THE INCIDENT (measured 2026-09-22 17:00Z). The hub and the pool boxes run
# every lane under ONE GitHub App installation, so every repo's token draws on
# the SAME primary bucket: `rate_limit` read through the project-4, project-7 and
# cromford tokens, from the hub AND from the small box, returned one
# counter (used 2452..2535 of 6600, reset 17:33:58Z). Consumption ran ~95
# calls/min — about 5,700/h against a 6,600/h cap — so the fleet drained the
# bucket in the last five minutes of every hourly window. The symptom was an
# hourly burst of ~30 "UNVERIFIABLE (HTTP 000)" lines in merge-conductor.log and
# merge-sweep.log (203 + 93 in one hour), each one a decision path skipping a
# tick: "not merged this tick: the diff read was UNVERIFIABLE", "stack-parent
# read … answering NONE, which keeps the child waiting". Nothing read
# `X-RateLimit-*` and nothing ledgered a call, so the quota was invisible until
# it was gone and no lane could be blamed.
#
# WHY A SECOND FILE. The same reason bin/lib/gh-rest-etag.sh gives for itself:
# gh-rest.sh is a CONTRACT file held under a code-line ceiling by
# tests/gh-rest-lib-test.sh on purpose, so a caller-conversion cannot quietly
# grow it into a lane. Header parsing, the path classifier, the ledger writer,
# the sweep, the reserve resolution and the gate are a lane's worth of code and
# live here; gh_rest calls back into exactly two functions (`_gh_quota_gate`
# before the request, `_gh_quota_observe` after it), each behind a
# `command -v` guard, so a box missing this file loses the ledger and the gate,
# never correctness.
#
# THE THREE THINGS THIS FILE MUST NEVER DO:
#   1. cost an API call. Everything here reads the response gh_rest ALREADY
#      has and files on this box. There is no `gh api` in this file and
#      tests/gh-rest-quota-test.sh section 6 asserts that.
#   2. fail a caller. A ledger that cannot be written is a missing line and one
#      log line — never a non-zero rc, and never a changed body. Every function
#      here ends in `return 0`, which matters because gh_rest calls them as the
#      last statement of an `if` block and 542 of this repo's suites (and every
#      lane) run under `set -e`: a non-zero return would kill the lane rather
#      than skip a measurement.
#   3. read the wall clock twice for one decision. The reset comparison uses one
#      `date -u +%s`.
#
# UNKNOWN IS NEVER ZERO. A response with no rate-limit headers leaves
# GH_REST_QUOTA_REMAINING EMPTY, and an empty reading never gates: "we do not
# know how much is left" and "nothing is left" are the two answers this whole
# file exists to keep apart, and collapsing them would either stop every
# optional read for ever or gate none of them.
#
# No `set -e`, no `exit`, no side effect at source time — sourcing this file in
# any lane costs zero API budget and cannot kill the lane.
if [ -n "${GH_REST_LEDGER_LIB:-}" ]; then return 0 2>/dev/null; fi
GH_REST_LEDGER_LIB=1

# The quota a response reported, in the shell that CALLED gh_rest — the same
# scope rule GH_REST_STATUS obeys and for the same reason: a helper run inside
# `$( )` leaves its status in the subshell that then died. Read them after a
# `gh_rest … > file`, never after `X=$(gh_rest …)`.
GH_REST_QUOTA_REMAINING=
GH_REST_QUOTA_LIMIT=
GH_REST_QUOTA_RESET=
GH_REST_QUOTA_RETRY_AFTER=
# BH-1574: the two headers that say WHICH bucket answered and how much of it is
# spent. `X-RateLimit-Resource` is `core` for REST and `graphql` for GraphQL —
# two meters under one token, and /rate_limit's graphql numbers read used=0 on
# the hub while a live GraphQL response said 80, so the header is the truth.
GH_REST_QUOTA_RESOURCE=
GH_REST_QUOTA_USED=
# BH-8066: `cache` or `304` when the response was a replay by the PATH shim's
# cache (its X-Gh-Cache-Served header), else empty.
GH_REST_QUOTA_SERVED=

# C2: the default-identity lib _gh_quota_gate asks (see the gate). Function
# definitions only; a box without the file keeps today's credential.
# shellcheck source=bin/lib/gh-app-default.sh
[ -r "$(dirname "${BASH_SOURCE[0]}")/gh-app-default.sh" ] && . "$(dirname "${BASH_SOURCE[0]}")/gh-app-default.sh" 2>/dev/null

# The documented code fallback for the `gh.quota.reserve` settings row. 600 is
# about six minutes of the measured burn: enough for the decision-critical reads
# of a tick and the next one, not enough to be a bucket nobody can use.
_GH_QUOTA_RESERVE_DEFAULT=600
# How long a resolved reserve is reused without asking the worker again. The
# gate runs inside gh_rest, so an unmemoised `setting_get` would put an HTTP
# request in front of a read whose whole point is to be cheap.
_GH_QUOTA_RESERVE_TTL=300

_gh_led_home() { printf '%s' "${HARNESS:-/root/harness}"; }
_gh_led_dir()  { printf '%s/state/gh-rest-ledger' "$(_gh_led_home)"; }

# _gh_led_log <class> <words> — ONE line, to logs/gh-rate.log (where the etag
# counter already reports), at most once per CLASS per process: a ledger that
# cannot be written usually cannot be written for the whole tick, and a line per
# call would turn a failed mkdir into a log flood. Never returns non-zero.
#
# BH-1484 REVIEW FIX (S-2): the guard used to be ONE flag for every message, so
# the first "cannot create dir" of a process silenced the later "unusable
# setting gh.quota.reserve='abc'" — two unrelated faults, one of them then
# invisible for the rest of the tick. The classes are a space-delimited seen
# list rather than one variable per class, because the class names come from
# this file (not from data) and a list needs no indirection to test.
_gh_led_log() {
  local class="${1:-other}" f
  case " ${_GH_LED_LOG_SEEN:-} " in *" $class "*) return 0 ;; esac
  _GH_LED_LOG_SEEN="${_GH_LED_LOG_SEEN:-}${_GH_LED_LOG_SEEN:+ }$class"
  shift
  f="$(_gh_led_home)/logs/gh-rate.log"
  { mkdir -p "${f%/*}"; printf '%s [gh-ledger] %s\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "$*" >> "$f"; } \
    >/dev/null 2>&1
  return 0
}

# gh_quota_bucket — WHICH GitHub rate-limit bucket the call in this shell spends
# from. This is the BH-1484 review's I-1 fix and it is the whole reason the
# reading below is not one file per box.
#
# The fleet does not run on one bucket. bin/merge-sweep.sh and
# bin/lib/gh-repo-token.sh both switch GH_TOKEN per repo INSIDE one process
# ("the ladder: default PAT, then the admin PAT, then a GitHub App installation
# token"), and each PAT carries its OWN 5,000/h user bucket with its own reset,
# while every installation token of one App shares the single 6,600/h
# installation bucket the ticket measured. A reading keyed by box alone is
# therefore "whichever token answered last", and the gate would refuse an App
# read on a PAT's headroom, or wave one through on a bucket that is empty.
#
# THE TOKEN DECIDES, NOT THE TAG. GH_LIMIT_IDENTITY is a label a lane exports
# and bin/lib/gh-app-auth.sh writes it LAST, from whatever GH_TOKEN holds after
# its fallback ladder — so it is usually right, and the token is right by
# construction. `ghs_` is the installation prefix, which is exactly the test
# gh-app-auth.sh itself uses to earn the `app:` tag.
#
# NO TOKEN VALUE EVER REACHES A FILENAME. A PAT is identified by the first 12
# hex of a sha1 of its value: enough to tell the default PAT from the admin PAT
# on one box, not enough to be a credential. A shell with no GH_TOKEN spends
# from whatever credential `gh` has stored, which is one bucket per box, so it
# gets the stable name `pat-default`.
# ONE BUCKET PER INSTALLATION (BH-1509 S-10). `app` alone was right only while
# the fleet ran under a single GitHub App: the hub's installation (161623167)
# and the Cromford Board App (163842147) are two separate 6,600/h meters,
# and a reading one of them wrote under `app` is the other one's headroom as far
# as the gate and the Fleet tile can tell. So the installation id joins the
# name, resolved from the token CACHE bin/gh-token.sh writes — the token decides
# here too, and the id is the one it actually minted against.
#
# EVERY MISS IS THE LEGACY `app`, NEVER EMPTY AND NEVER A FAILURE: an unarmed
# box, a token minted before this change, a `ghs_` value this box never minted
# (a Fly test host), an unreadable or corrupt cache. This function runs on the
# per-call observe hook under the caller's `set -e`, so it must not return
# non-zero, and a bucket name that came back empty would write `.quota-`.
#
# Memoised on the token's sha12, not on the process: bin/merge-sweep.sh and
# bin/lib/gh-repo-token.sh swap GH_TOKEN per repo INSIDE one shell, so a
# process-wide memo would file the second repo's reading under the first
# installation. The memo is also what keeps jq off the hot path — a box doing
# ~95 REST calls a minute would otherwise run it on every one.
gh_quota_bucket() {
  local sha
  # BH-1585: a response GitHub charged to the GraphQL bucket is ledgered (and
  # its reading persisted) as `graphql-<token bucket>`, never as the REST one.
  if [ "${GH_REST_QUOTA_RESOURCE:-}" = graphql ]; then
    printf 'graphql-%s' "$(GH_REST_QUOTA_RESOURCE='' gh_quota_bucket)"; return 0
  fi
  case "${GH_TOKEN:-}" in
    ghs_*) ;;
    '')    printf 'pat-default'; return 0 ;;
    *)     printf 'pat-%s' "$(printf '%s' "$GH_TOKEN" | _gh_led_sha1 | cut -c1-12)"
           return 0 ;;
  esac
  sha=$(printf '%s' "$GH_TOKEN" | _gh_led_sha1 | cut -c1-12)
  if [ -n "${_GHQ_BKT_MEMO_KEY:-}" ] && [ "$_GHQ_BKT_MEMO_KEY" = "$sha" ]; then
    printf '%s' "${_GHQ_BKT_MEMO_VAL:-app}"; return 0
  fi
  _GHQ_BKT_MEMO_KEY=$sha
  _GHQ_BKT_MEMO_VAL=$(_gh_app_install_of_token)
  printf '%s' "$_GHQ_BKT_MEMO_VAL"
  return 0
}

# _gh_app_install_of_token — `app-<installation id>` for the installation token
# in GH_TOKEN, or `app` when nothing in the cache claims it. Digits only: the
# value becomes part of a FILENAME (`.quota-app-<id>`) and `install_id` will
# hand back whatever `GH_APP_INSTALLATION_<OWNER>` was set to, unvalidated. The
# token value itself never leaves this function — it is compared inside jq and
# never printed, logged or hashed into a name beyond the existing sha12.
#
# EVERY APP PROFILE'S CACHE, AND THEN THE BUNDLE'S HINT (BH-1578). The Fly
# builders mint from their own App (bin/gh-token.sh --app builders), whose cache
# is state/gh-app-tokens-<profile>/, so the hub finds a builders token there and
# names the builders installation. A BUILDER has no cache at all — its token
# arrived in the env bundle — so bin/fly-pool.sh ships GH_TOKEN_INSTALLATION_ID
# beside it, and that is the answer when no cache row claims the token. A cache
# row always wins over the hint: the row is what this box actually minted.
_gh_app_install_of_token() {
  local home f id
  local -a files=()
  home=$(_gh_led_home)
  for f in "$home"/state/gh-app-tokens/*.json "$home"/state/gh-app-tokens-*/*.json; do
    [ -f "$f" ] && files+=("$f")
  done
  id=""
  # ${files[@]+…}: bash 3.2 guard for the lead's Mac (BH-3565); the count check already keeps it non-empty.
  if [ "${#files[@]}" -gt 0 ]; then
    id=$(jq -r --arg t "${GH_TOKEN:-}" \
          'select((.token // "") == $t) | .installation_id // empty' \
          ${files[@]+"${files[@]}"} 2>/dev/null | head -n 1) || id=""
  fi
  [ -n "$id" ] || id="${GH_TOKEN_INSTALLATION_ID:-}"
  case "${id:-}" in
    ''|*[!0-9]*) printf 'app' ;;
    *)           printf 'app-%s' "$id" ;;
  esac
  return 0
}

# Portable across the fleet's Debian boxes and this Mac, the same ladder and the
# same reasoning as _gh_etag_sha1 (which is NOT reused: a box missing
# gh-rest-etag.sh must still key its buckets apart).
_gh_led_sha1() {
  if command -v sha1sum >/dev/null 2>&1; then sha1sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 1 | awk '{print $1}'
  else cksum | tr -dc '0-9a-f' | cut -c1-16
  fi
}

# gh_rest_path_class <path> — the PATH CLASS a ledger line carries.
#
# The raw path cannot be the grouping key: `repos/o/r/pulls/1284` and
# `repos/o/r/pulls/1285` are the same question asked twice, and a report keyed
# on the raw path answers "every path was read once" for a lane that read one
# endpoint four thousand times. So a digit RUN collapses to a single `N` and a
# 40-hex object name to `SHA` — shas first, because a sha is mostly digits and
# collapsing its digits first would leave a class of `NaNbN…` that differs per
# commit, which is the same as not classing at all.
#
# The query string is dropped: `per_page`, `page` and `state` are parameters of
# one endpoint, not different endpoints, and keeping them would split every
# paginated list across as many classes as it has pages.
#
# Fork-free and glob-free on purpose. This runs once per REST call on a box
# doing ~95 a minute, and `for seg in $p` would both fork nothing and glob a
# path containing `*` into whatever files happen to sit in the cwd.
gh_rest_path_class() {
  local p="${1:-}" seg out="" pre=""
  p=${p%%\?*}
  case "$p" in /*) pre=/; p=${p#/} ;; esac
  while [ -n "$p" ]; do
    seg=${p%%/*}
    if [ "$seg" = "$p" ]; then p=; else p=${p#*/}; fi
    case "$seg" in
      [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f])
        seg=SHA ;;
      *[0-9]*)
        seg=${seg//[0-9]/N}
        while [ "$seg" != "${seg//NN/N}" ]; do seg=${seg//NN/N}; done ;;
    esac
    out="$out/$seg"
  done
  printf '%s' "$pre${out#/}"
}

# gh_ledger_clean_resource — GH_REST_QUOTA_RESOURCE as a bucket NAME or empty.
# It becomes a TSV column and a D1 key, and it arrives from a response header:
# lowercase letters and `_` only (core, graphql, search, code_search,
# integration_manifest …), anything else is dropped rather than carried. The
# awk that read it already lowercased it; no fork here, this is on the per-call
# path.
gh_ledger_clean_resource() {
  case "${GH_REST_QUOTA_RESOURCE:-}" in *[!a-z_]*) GH_REST_QUOTA_RESOURCE= ;; esac
  return 0
}

# _gh_quota_headers <raw response file> — the rate-limit headers, into this shell.
#
# ONE awk pass, stopping at the header/body boundary so a body line that happens
# to read `x-ratelimit-remaining: 0` can never be taken for a header (the same
# trap gh-rest-etag.sh names for `etag:`). tolower() rather than a case-folded
# pattern: HTTP/2 lowercases every header name and HTTP/1.1 does not, and
# `IGNORECASE` is a gawk-only variable that mawk and BSD awk silently ignore.
#
# A value that is not a plain integer is dropped rather than carried: the gate
# and the ledger both compare it as a number, and a `?` or an empty string that
# reached an arithmetic test would be a shell error on a path that must not be
# able to produce one.
_gh_quota_headers() {
  local out
  [ -r "${1:-}" ] || return 0
  out=$(awk '
    /^\r?$/ { exit }
    { line = $0; sub(/\r$/, "", line)
      k = line; sub(/:.*/, "", k); k = tolower(k)
      v = line; sub(/^[^:]*:[ \t]*/, "", v)
      if (k == "x-ratelimit-remaining") r = v
      else if (k == "x-ratelimit-limit") l = v
      else if (k == "x-ratelimit-reset") t = v
      else if (k == "retry-after") a = v
      else if (k == "x-ratelimit-resource") s = tolower(v)
      else if (k == "x-ratelimit-used") u = v
      else if (k == "x-gh-cache-served") c = tolower(v) }
    END { printf "%s\037%s\037%s\037%s\037%s\037%s\037%s", r, l, t, a, s, u, c }' "$1" 2>/dev/null)
  # \037 (unit separator), NOT a tab (BH-1574). A tab is IFS WHITESPACE, and
  # `read` collapses a run of it into one delimiter: an absent Retry-After — the
  # normal case — made "\t\t", every field after it slid one to the left, and
  # the resource landed in RETRY_AFTER where the digit check erased it. A
  # non-whitespace separator keeps an empty field empty.
  IFS=$'\037' read -r GH_REST_QUOTA_REMAINING GH_REST_QUOTA_LIMIT \
    GH_REST_QUOTA_RESET GH_REST_QUOTA_RETRY_AFTER GH_REST_QUOTA_RESOURCE GH_REST_QUOTA_USED \
    GH_REST_QUOTA_SERVED <<EOF
$out
EOF
  # BH-1585 files a `graphql` answer under its own bucket (gh_quota_bucket);
  # BH-1574 keeps every bucket name (core, graphql, search …) for ledger column
  # 11, validated rather than narrowed.
  gh_ledger_clean_resource
  case "${GH_REST_QUOTA_USED:-}" in *[!0-9]*) GH_REST_QUOTA_USED= ;; esac
  case "${GH_REST_QUOTA_REMAINING:-}" in *[!0-9]*) GH_REST_QUOTA_REMAINING= ;; esac
  case "${GH_REST_QUOTA_LIMIT:-}" in *[!0-9]*) GH_REST_QUOTA_LIMIT= ;; esac
  case "${GH_REST_QUOTA_RESET:-}" in *[!0-9]*) GH_REST_QUOTA_RESET= ;; esac
  case "${GH_REST_QUOTA_RETRY_AFTER:-}" in *[!0-9]*) GH_REST_QUOTA_RETRY_AFTER= ;; esac
  # BH-8066: the shim cache's replay marker (bin/lib/gh-cache.sh ghc_replay).
  case "${GH_REST_QUOTA_SERVED:-}" in cache|304) ;; *) GH_REST_QUOTA_SERVED= ;; esac
  return 0
}

# _gh_quota_persist — the last reading, as a FILE, ONE PER BUCKET.
#
# A shell variable cannot carry this. gh_rest's dominant caller is
# `X=$(mc_pr_view …)` — a `$( )` subshell — and merge-conductor backgrounds one
# subshell per project, so a reading taken in one of them is gone before the
# next read starts (the same argument gh-rest-etag.sh makes for its counter).
# The gate has to answer "how much was left when anything on this box last
# looked AT THIS BUCKET", so it lives on the box, keyed by bucket.
#
# tmp + mv, so a concurrent reader sees one whole line or the previous one,
# never a half-written reading it would then parse as a small remaining.
_gh_quota_persist() {
  local dir tmp bucket
  [ -n "${GH_REST_QUOTA_REMAINING:-}" ] || return 0
  bucket=$(gh_quota_bucket)
  dir=$(_gh_led_dir)
  mkdir -p "$dir" 2>/dev/null || { _gh_led_log mkdir "cannot create $dir"; return 0; }
  tmp="$dir/.quota-$bucket.${BASHPID:-$$}"
  printf '%s %s %s %s\n' "$GH_REST_QUOTA_REMAINING" "${GH_REST_QUOTA_LIMIT:--}" \
    "${GH_REST_QUOTA_RESET:--}" "$(date -u +%s)" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$dir/.quota-$bucket" 2>/dev/null
  rm -f "$tmp" 2>/dev/null
  return 0
}

# _gh_quota_read [bucket] — one bucket's persisted reading into
# _GHQ_REM/_GHQ_LIM/_GHQ_RESET/_GHQ_STALE/_GHQ_BUCKET. With no argument it reads
# the bucket THIS shell's token would spend from, which is what the gate wants.
#
# Every field is validated here rather than at each use: a hand-edited or torn
# file must read as UNKNOWN, which never gates and never renders as 0.
#
# BH-1484 REVIEW FIX (I-3): a reading whose reset has already passed is marked
# _GHQ_STALE=1 HERE, at the one place that reads the file, so the gate, the
# per-tick line and the fleet push cannot disagree about it. The bucket refilled
# at that reset; the old remaining is not a small number, it is no number.
_gh_quota_read() {
  local f now
  _GHQ_REM=; _GHQ_LIM=; _GHQ_RESET=; _GHQ_STALE=0
  _GHQ_BUCKET="${1:-$(gh_quota_bucket)}"
  f="$(_gh_led_dir)/.quota-$_GHQ_BUCKET"
  [ -r "$f" ] || return 0
  read -r _GHQ_REM _GHQ_LIM _GHQ_RESET _ < "$f" 2>/dev/null || return 0
  case "${_GHQ_REM:-}" in ''|*[!0-9]*) _GHQ_REM=; _GHQ_LIM=; _GHQ_RESET=; return 0 ;; esac
  case "${_GHQ_LIM:-}" in *[!0-9]*) _GHQ_LIM= ;; esac
  case "${_GHQ_RESET:-}" in *[!0-9]*) _GHQ_RESET= ;; esac
  now=$(date -u +%s 2>/dev/null) || return 0
  case "${_GHQ_RESET:-}" in
    '') ;;
    *) [ "$_GHQ_RESET" -gt "$now" ] || _GHQ_STALE=1 ;;
  esac
  return 0
}

# gh_quota_reserve — how much of the bucket is kept for decision-critical reads.
#
# DB FIRST, exactly the shape bin/lib/gh-quota.sh uses for gh_quota_alert_pct: a
# `gh.quota.reserve` settings row an operator can edit in the console, the code
# constant only as the documented fallback. Resolution order, first usable wins:
#   GH_QUOTA_RESERVE   the per-run override (tests, a one-off drain)
#   this process's memo — the gate can run once per REST call
#   a file cache younger than _GH_QUOTA_RESERVE_TTL — shared across the
#                      subshells gh_rest is called from, which a shell variable
#                      is not
#   setting_get gh.quota.reserve — only when jobs-client is loaded in this shell
#   600
# A value that is not a non-negative integer is LOGGED and ignored rather than
# clamped: a knob is not a place to trust, and silently repairing a typo hides it.
#
# THE MEMO HAS NO TTL (review S-7) and the file cache does. Every caller today is
# a cron tick — a process that lives seconds — so the memo is a per-tick cache
# and an operator's edit is picked up on the next tick either way. A long-lived
# shell (an interactive drain session sourcing this library) would hold the
# first value for its whole life; unset `_GH_QUOTA_RESERVE_MEMO` to re-resolve.
gh_quota_reserve() {
  local v="${GH_QUOTA_RESERVE:-}" f age now
  if [ -z "$v" ] && [ -n "${_GH_QUOTA_RESERVE_MEMO:-}" ]; then v="$_GH_QUOTA_RESERVE_MEMO"; fi
  if [ -z "$v" ]; then
    f="$(_gh_led_dir)/.reserve"
    now=$(date -u +%s 2>/dev/null)
    if [ -r "$f" ] && [ -n "$now" ]; then
      read -r v age _ < "$f" 2>/dev/null || { v=; age=; }
      case "${age:-}" in
        ''|*[!0-9]*) v= ;;
        *) [ $((now - age)) -lt "$_GH_QUOTA_RESERVE_TTL" ] || v= ;;
      esac
    fi
  fi
  if [ -z "$v" ] && command -v setting_get >/dev/null 2>&1; then
    v=$(setting_get gh.quota.reserve 2>/dev/null) || v=
    case "${v:-}" in
      '') ;;
      *[!0-9]*) _gh_led_log knob "unusable setting gh.quota.reserve='$v' — falling back to $_GH_QUOTA_RESERVE_DEFAULT"; v= ;;
      *) mkdir -p "$(_gh_led_dir)" 2>/dev/null \
           && printf '%s %s\n' "$v" "${now:-$(date -u +%s)}" > "$(_gh_led_dir)/.reserve" 2>/dev/null ;;
    esac
  fi
  case "${v:-}" in ''|*[!0-9]*) v=$_GH_QUOTA_RESERVE_DEFAULT ;; esac
  _GH_QUOTA_RESERVE_MEMO=$v
  printf '%s' "$v"
  return 0
}

# _gh_quota_gate — rc 0 PROCEED, rc 1 REFUSE. Called by gh_rest BEFORE the
# request, which is the whole point: a guard that runs on the response has
# already spent the call it exists to save (the same shape as a post-charge
# dedup on any metered API).
#
# Only an OPTIONAL read is ever refused. `GH_REST_OPTIONAL=1` is the caller
# saying "skipping this read costs me a re-read next tick, not a wrong answer":
# a stack-parent re-read of an unchanged head, a list re-read inside one tick, a
# metrics read. Everything else — every read a merge or a close decision turns
# on — goes through regardless, because starving the decision paths is a worse
# failure than draining the bucket and is exactly what the drained bucket
# already causes.
#
# THE READING IT JUDGES IS THIS CALL'S OWN BUCKET (BH-1484 review I-1). A lane
# that just read a repo on a PAT and is now about to read one on the App token
# must be judged on the App installation's headroom, not on the PAT's — the
# whole failure the review reproduced. `_gh_quota_read` with no argument keys on
# the token in scope right now, which is the token this call is about to spend.
#
# Four separate ways this answers PROCEED on purpose:
#   no reading for this bucket    nobody has looked yet; unknown never gates
#   the reading's window has reset  the bucket refilled since, so a small
#                                 remaining from the old window says nothing
#                                 about this one (_GHQ_STALE)
#   the reading carries no reset  (review S-4) we cannot tell a live reading
#                                 from an expired one, and an unknown that
#                                 gates for ever is worse than one that does
#                                 not gate at all
#   remaining >= reserve          there is headroom
#
# BH-1574: EVERY PROCEED EXPORTS GH_LEDGER_BY_CALLER=1. gh_rest's next line runs
# the real request through `gh` by name, and with bin/gh-ledger/gh first on PATH
# that call reaches the shim — which would ledger it a second time. The shim
# passes a call straight through only when the marker is set AND its argv starts
# `api -i -X` (gh_rest's exact shape), so a raw `gh pr view` in the same shell is
# still ledgered; _gh_quota_observe unsets the marker as the very next thing
# gh_rest does. A refusal never exports it: no request follows a refusal.
#
# THE GATE ALSO PICKS THE IDENTITY (C2, 2026-09-24). Given gh_rest's path, a
# caller holding no token gets the GitHub App for a repos/<owner>/<repo> path
# (bin/lib/gh-app-default.sh) BEFORE the bucket is read, so the reserve check
# and the ledger row both name the bucket the request really spends. The export
# lands on gh_rest's `local GH_TOKEN` (bash dynamic scope), so it lives for that
# one call and the caller's shell never holds the App token. No path, no token
# change: a caller of the gate other than gh_rest is exactly as before.
_gh_quota_gate() {
  local _gqg_tok
  if [ -n "${1:-}" ] && command -v gh_default_token_for_path >/dev/null 2>&1 \
     && _gqg_tok=$(gh_default_token_for_path "$1"); then
    export GH_TOKEN="$_gqg_tok"
  fi
  _gh_quota_gate_decide || return 1
  export GH_LEDGER_BY_CALLER=1
  return 0
}
_gh_quota_gate_decide() {
  local res
  [ "${GH_REST_OPTIONAL:-0}" = 1 ] || return 0
  _gh_quota_read
  [ -n "${_GHQ_REM:-}" ] || return 0
  [ -n "${_GHQ_RESET:-}" ] || return 0
  [ "${_GHQ_STALE:-0}" = 0 ] || return 0
  res=$(gh_quota_reserve)
  [ "$_GHQ_REM" -lt "$res" ] || return 0
  return 1
}

# _gh_led_write <method> <path> <status> <counted> — ONE append-only line.
#
#   ts  lane  project  method  path-class  status  counted  remaining  reset  bucket
#     resource  source  used  limit                           (columns 11-14, BH-1574)
#     served                                                  (column 15, BH-8066)
#
# THE BUCKET IS A COLUMN, not an assumption (BH-1484 review I-1). `remaining`
# and `reset` are properties of a specific GitHub rate-limit bucket, and one
# lane spends from several in one tick as its token ladder switches per repo —
# so a file of bare remainings from mixed buckets cannot be read as a burn-down
# at all. With the column, `bin/gh-quota-report.sh` can split by bucket and the
# App installation's 6,600/h (the one the ticket measured) is separable from
# each PAT's own 5,000/h.
#
# COLUMNS 11-14 (BH-1574). Column 10 names the TOKEN's meter; one token has TWO
# primary buckets under it — `core` (REST) and `graphql` — and column 11 is the
# one GitHub named in X-RateLimit-Resource, so a report can finally tell a
# GraphQL drain from a REST one. Column 12 says who wrote the row: `rest` is
# gh_rest (this file), `gh` is the PATH shim bin/gh-ledger/gh ledgering a raw
# `gh` call. 13 and 14 are X-RateLimit-Used and -Limit. Every reader takes
# `NF >= 7` and treats a missing column as `-`, so a line written before this
# change still reads.
#
# `counted` is what makes the report honest: GitHub does not charge a
# conditional request that answers 304, so counting it would over-report every
# cached read and hide the real burn under the ETag cache's own success. A 000
# (nothing came back at all) is counted=0 for the same reason — there is no
# evidence a request was charged, and inventing one would put the network's
# failures on the quota's bill.
#
# An unwritable ledger is a MISSING LINE, never a failed caller: the first
# append is tried straight (the steady state, where the directory is already
# there, costs exactly one append), and only a failure pays for a mkdir, one
# retry and at most one log line for the whole process.
_gh_led_write() {
  gh_ledger_append rest "${1:-}" "${2:-}" "${3:-}" "${4:-1}"
  return 0
}

# gh_ledger_append <source> <method> <path> <status> <counted> — the writer both
# sources share. The quota numbers come from the GH_REST_QUOTA_* variables in
# THIS shell (gh_rest sets them from the response; the shim sets them from each
# request it parsed out of gh's trace). The lane is HARNESS_LANE, then
# GH_LEDGER_CALLER (the shim's parent script — it is a process of its own, so
# its own $0 would read `gh` on every row), then this shell's $0.
gh_ledger_append() {
  local dir ts hour lane proj cls line served
  dir=$(_gh_led_dir)
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) || return 0
  hour=${ts%:*}; hour=${hour%:*}
  lane="${HARNESS_LANE:-${GH_LEDGER_CALLER:-}}"
  [ -n "$lane" ] || lane="${0##*/}"
  [ -n "$lane" ] || lane='-'
  proj="${HARNESS_LANE_PROJECT:-${PROJECT:-}}"
  [ -n "$proj" ] || proj='-'
  cls=$(gh_rest_path_class "${3:-}")
  # Column 15 `served` (BH-8066), derived from the status: `cache` (the
  # bin/lib/gh-cache.sh replay, no request), `304`, `-` (no answer at all) and
  # `200` for any other answer — GitHub sent a full response, whatever its code.
  case "${4:-000}" in cache) served=cache ;; 304) served=304 ;; 000|'') served=- ;; *) served=200 ;; esac
  line=$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' "$ts" "$lane" "$proj" \
    "${2:--}" "$cls" "${4:-000}" "${5:-1}" "${GH_REST_QUOTA_REMAINING:--}" \
    "${GH_REST_QUOTA_RESET:--}" "$(gh_quota_bucket)" "${GH_REST_QUOTA_RESOURCE:--}" \
    "${1:--}" "${GH_REST_QUOTA_USED:--}" "${GH_REST_QUOTA_LIMIT:--}" "$served")
  printf '%s\n' "$line" 2>/dev/null >> "$dir/$hour.tsv" && return 0
  mkdir -p "$dir" 2>/dev/null || { _gh_led_log mkdir "cannot create $dir — ledger line dropped"; return 0; }
  printf '%s\n' "$line" 2>/dev/null >> "$dir/$hour.tsv" \
    || _gh_led_log append "cannot append $dir/$hour.tsv — ledger line dropped"
  return 0
}

# _gh_quota_observe <raw response file> <method> <path> <status> — everything
# gh_rest does with a response that is not the response itself. Called ONCE,
# before gh_rest's own status branching, so the 000/network path is ledgered
# too: a tick that could not reach GitHub is the single most interesting row in
# the file the hour the bucket drains.
#
# FIRST it drops GH_LEDGER_BY_CALLER, the marker _gh_quota_gate exported for the
# one request this gh_rest call made (see the gate).
#
# A REPLAY (BH-8066). The PATH shim's cache (bin/lib/gh-cache.sh) answers a
# repeat GET from disk and marks the header block `X-Gh-Cache-Served: cache`
# (no request) or `304` (a conditional request GitHub did not charge). The row
# then says that, counted 0, and the replayed X-RateLimit-* headers are stale:
# they are blanked and never persisted, so the gate reads only live answers.
_gh_quota_observe() {
  local st="${4:-}" counted=1
  unset GH_LEDGER_BY_CALLER
  GH_REST_QUOTA_REMAINING=; GH_REST_QUOTA_LIMIT=; GH_REST_QUOTA_RESET=; GH_REST_QUOTA_RETRY_AFTER=
  GH_REST_QUOTA_RESOURCE=; GH_REST_QUOTA_USED=; GH_REST_QUOTA_SERVED=
  _gh_quota_headers "${1:-}"
  case "$st" in ''|000) st=000; counted=0 ;; 304) counted=0 ;; esac
  case "${GH_REST_QUOTA_SERVED:-}" in
    cache|304)
      st=$GH_REST_QUOTA_SERVED; counted=0
      GH_REST_QUOTA_REMAINING=; GH_REST_QUOTA_LIMIT=; GH_REST_QUOTA_RESET=; GH_REST_QUOTA_RETRY_AFTER=
      GH_REST_QUOTA_RESOURCE=; GH_REST_QUOTA_USED= ;;
    *) _gh_quota_persist ;;
  esac
  _gh_led_write "${2:-}" "${3:-}" "$st" "$counted"
  # The next PRE-request gate reads the REST bucket unless told otherwise.
  GH_REST_QUOTA_RESOURCE=
  return 0
}

# gh_quota_ledger_sweep — the 48h bound, at most once an hour per box (a stamp
# beside the ledger, the same shape and the same reason as the etag sweep).
# Age comes from the MTIME, not from the file name, so a file written by a box
# whose clock was wrong is still aged out, and a name this sweep does not
# recognise is left alone rather than deleted.
_gh_led_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }

gh_quota_ledger_sweep() {
  local dir stamp now last ttl_h cutoff f
  dir=$(_gh_led_dir)
  [ -d "$dir" ] || return 0
  now=$(date -u +%s 2>/dev/null) || return 0
  stamp="$dir/.swept"
  if [ -f "$stamp" ]; then
    last=$(_gh_led_mtime "$stamp")
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    [ $((now - last)) -ge 3600 ] || return 0
  fi
  : > "$stamp" 2>/dev/null
  ttl_h="${GH_LEDGER_TTL_H:-48}"
  # Review S-6: 0 would set cutoff = now and delete the hour file a lane is
  # writing INTO, which is the one file the report always wants. The floor is 1
  # hour, so the knob can shorten retention and can never erase the present.
  case "$ttl_h" in ''|*[!0-9]*) ttl_h=48 ;; esac
  [ "$ttl_h" -ge 1 ] || ttl_h=1
  cutoff=$((now - ttl_h * 3600))
  for f in "$dir"/*.tsv; do
    [ -f "$f" ] || continue
    [ "$(_gh_led_mtime "$f")" -lt "$cutoff" ] && rm -f "$f" 2>/dev/null
  done
  # A pre-BH-1484-review box carries one unkeyed `.quota`, which nothing reads
  # any more (the readings are `.quota-<bucket>` now). Removing it here means a
  # box does not keep a file that looks like a current reading and is not one.
  rm -f "$dir/.quota" 2>/dev/null
  return 0
}

# gh_quota_line [bucket] — the ONE line a lane prints per tick so the hourly
# burst is predictable from the log instead of from the failures it causes. The
# conductor and bin/merge-sweep.sh call it; it reads a file and never the API.
#
# IT NAMES ITS BUCKET and defaults to `app` — the shared installation bucket the
# ticket measured and the one a fleet-wide drain actually happens in. Before the
# review's I-1 fix this printed "whichever token answered last", so a PAT's
# 4,900 and the App's 98 were the same field.
#
# An unknown remaining renders `?`, never 0 — a bucket nobody has read must not
# look like a bucket that is empty, which is the whole unknown-is-not-zero rule
# this library is built on. A reading whose window has ALREADY RESET is exactly
# that kind of unknown (review I-3): the numbers are dropped and `stale=1` says
# why, so this line and the gate agree, instead of the screen showing a red
# QUOTA LOW for hours against a bucket that refilled.
#
# NO SWEEP HERE (review S-1). bin/gh-quota-report.sh calls this and documents
# itself as read-only, so the sweep is its own call that bin/merge-sweep.sh
# makes right after this one.
gh_quota_line() {
  local res
  _gh_quota_read "${1:-app}"
  res=$(gh_quota_reserve)
  if [ "${_GHQ_STALE:-0}" = 1 ]; then
    printf 'QUOTA bucket=%s rem=? limit=? reset=%s reserve=%s stale=1\n' \
      "$_GHQ_BUCKET" "${_GHQ_RESET:-?}" "$res"
    return 0
  fi
  printf 'QUOTA bucket=%s rem=%s limit=%s reset=%s reserve=%s\n' \
    "$_GHQ_BUCKET" "${_GHQ_REM:-?}" "${_GHQ_LIM:-?}" "${_GHQ_RESET:-?}" "$res"
  return 0
}
