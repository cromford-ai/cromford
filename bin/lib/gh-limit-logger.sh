#!/bin/bash
# bin/lib/gh-limit-logger.sh — write down WHICH GitHub identity got rate-limited.
# Sourced, never executed.
#
# THE QUESTION IT ANSWERS. Once every lane runs on its own repo-scoped App
# installation token (#424), "we are being rate-limited" stops being one fact
# about one PAT and becomes a fact about one installation, on one repo, in one
# lane. A 403 that names nothing sends the next person looking for headroom in
# the wrong bucket. So: every refusal that is actually a rate limit appends ONE
# line to $HARNESS/logs/gh-rate.log naming GH_LIMIT_IDENTITY — the tag
# bin/lib/gh-app-auth.sh sets (app:<owner/repo> or pat:<owner/repo>).
#
# IT IS A WRAPPER, NOT A PIPE. `gh` here is a shell function around the real
# binary: stdout is left completely alone (--paginate streams, `--input -` still
# reads stdin, a $(...) caller gets exactly the bytes it always did), stderr is
# captured only long enough to classify it and is then replayed verbatim, and
# the real exit code is what the caller sees. A failed mktemp or a log we cannot
# write changes NOTHING about the call — the logging is the side effect, the gh
# call is the point.
#
# WHAT COUNTS AS A RATE LIMIT is GitHub's own wording, and nothing else:
# "API rate limit exceeded", "API rate limit already exceeded" (the GraphQL
# phrasing), a secondary rate limit, the abuse-detection mechanism, and a bare
# HTTP 429. Deliberately NOT a rate limit: HTTP 404, HTTP 401 Bad credentials,
# "HTTP 403: Resource not accessible by integration" (that is a permission, and
# it is exactly what an installation token gets from /user), and a GraphQL
# "Could not resolve to a Repository". A 403 is not a rate limit just because it
# is a 403 — a classifier that cries wolf on every permission error is a
# classifier nobody reads.
#
# STDOUT IS NEVER CLASSIFIED. A PR body that quotes "API rate limit exceeded"
# comes back on stdout of a SUCCESSFUL call; only stderr votes.
#
# NO TOKEN VALUE EVER REACHES THE LOG. GitHub sometimes echoes the credential in
# its own message, so anything token-shaped (gh?_..., github_pat_...) is
# replaced with <redacted> before the line is written, and the line is cut to
# 200 characters.
#
# IT ALSO COUNTS (BH-426). "Below 20 percent remaining … naming the top three
# scripts by call count in the last hour" needs a counter, and this wrapper is
# the one place every lane's ordinary gh call already passes through. So each
# call appends ONE line to logs/gh-calls/<YYYYMMDDHH>.log:
#
#   <epoch> <caller> <argv1> <argv2> [<METHOD>:<template>]
#
# The 5th field (BH-8334) is written only for the `gh api -i -X M P` shape
# gh_rest sends (argv1 `api`, argv2 a flag): the method and the path with its
# ids replaced (_ghll_ep), so `gh_calls_top_endpoints` can name the busiest
# endpoints. A plain `gh api <path>` already shows its path in field 4 and
# stays 4 fields. Readers that take fields 1-2 are unchanged.
#
# and nothing else changes: not stdout, not stderr, not the exit code, and not
# whether the call happens at all. The caller name is $0's basename, or
# GH_CALL_CALLER when a lane launches work under another name. The line is
# written with O_APPEND and is far under PIPE_BUF, so two lanes appending at the
# same instant cannot tear one. Each file is pruned at 180 minutes by the first
# writer into a NEW hour (D21) — the directory bounds itself, with no cron line
# and no second process reading it.
#
# THE LIMIT, SAID OUT LOUD: `timeout 60 gh ...` and `env -u GH_TOKEN gh ...`
# exec the BINARY, so those call sites bypass this wrapper — for the refusal
# line and for the count alike, which is why the alert says "wrapped calls".
# That is a shell fact, not a bug to fix here — the lanes' ordinary calls are the
# ones that spend the bucket.
[ -n "${_GHLL_LOADED:-}" ] && return 0
# A tree with no gh BINARY defines nothing. Several libs ask `command -v gh` to
# decide whether a feature is available at all (bin/lib/hotfix-lib.sh,
# bin/lib/revdep-lib.sh), and a function by that name would answer yes for a box
# or a fixture that has no gh at all.
command -v gh >/dev/null 2>&1 || return 0
_GHLL_LOADED=1
_GHLL_H="${HARNESS:-/root/harness}"
# The classifier. It matches GitHub's message text, not our own summary of it.
_GHLL_RE='rate limit (already )?exceeded|secondary rate limit|abuse detection|HTTP 429'
# The hour file this process last appended to. A change means a new hour started
# under us, which is the one moment worth spending a `find` on.
_GHLL_HOUR=""

# _ghll_tpl <path> — BH-8334: the path with its ids replaced, in _GHLL_TPL.
# A leading / and the query string are dropped; repos/<o>/<r> is
# repos/{o}/{r}; an all-digit segment is {n}; a 40-hex segment, or a 7-39 char
# hex segment with a digit in it, is {sha}; everything after heads/, branches/
# or compare/ is {ref}. Pure parameter expansion and [[ ]]: no fork (see below).
_ghll_tpl() {
  local p="${1#/}" seg out=""
  p="${p%%\?*}"
  if [[ "$p" == repos/*/* ]]; then
    p="${p#repos/}"; p="${p#*/}"; out="repos/{o}/{r}"
    if [[ "$p" == */* ]]; then p="${p#*/}"; else p=""; fi
  fi
  while [ -n "$p" ]; do
    seg="${p%%/*}"
    if [ "$seg" = "$p" ]; then p=""; else p="${p#*/}"; fi
    if [[ "$seg" =~ ^[0-9]+$ ]]; then seg="{n}"
    elif [[ "$seg" =~ ^[0-9a-fA-F]{40}$ ]]; then seg="{sha}"
    elif [[ "$seg" =~ ^[0-9a-fA-F]{7,39}$ && "$seg" == *[0-9]* ]]; then seg="{sha}"
    fi
    out="${out:+$out/}$seg"
    case "$seg" in heads|branches|compare) [ -n "$p" ] && { out="$out/{ref}"; p=""; } ;; esac
  done
  _GHLL_TPL="$out"
}

# _ghll_ep <argv of `gh api` after "api"> — BH-8334: `<METHOD>:<template>` in
# _GHLL_EP, empty when the argv names no path. -X/--method sets the method;
# with none it is POST when a field or --input is given (gh's own rule), else
# GET. Flags that take a value skip it. No fork.
_ghll_ep() {
  local m="" path="" body=0 a
  _GHLL_EP=""
  while [ $# -gt 0 ]; do
    a="$1"; shift
    case "$a" in
      -X|--method) m="${1:-}"; shift ;;
      --method=*) m="${a#--method=}" ;;
      -f|-F|--field|--raw-field|--input) body=1; shift ;;
      --field=*|--raw-field=*|--input=*) body=1 ;;
      -H|--header|-q|--jq|-t|--template|-p|--preview|--hostname|--cache) shift ;;
      -*) ;;
      *) [ -n "$path" ] || path="$a" ;;
    esac
  done
  [ -n "$path" ] || return 0
  [ -n "$m" ] || { if [ "$body" = 1 ]; then m=POST; else m=GET; fi; }
  _ghll_tpl "$path"
  [ -n "$_GHLL_TPL" ] && _GHLL_EP="$m:$_GHLL_TPL"
  return 0
}

# _ghll_count <argv...> — one line per wrapped call. printf's %()T is a
# bash builtin, so counting costs no fork; `date` here would double the process
# count of every lane that makes hundreds of gh calls a tick. Every failure is
# swallowed: the count is bookkeeping, the gh call is the point.
_ghll_count() {
  local ep hr dir x=""
  printf -v ep '%(%s)T' -1
  printf -v hr '%(%Y%m%d%H)T' -1
  dir="$_GHLL_H/logs/gh-calls"
  {
    if [ "${1:-}" = api ] && [[ "${2:-}" == -* ]]; then
      _ghll_ep "${@:2}"
      [ -n "$_GHLL_EP" ] && x=" $_GHLL_EP"
    fi
    mkdir -p "$dir"
    printf '%s %s %s %s%s\n' "$ep" "${GH_CALL_CALLER:-${0##*/}}" "${1:-}" "${2:-}" "$x" \
      >> "$dir/$hr.log"
    # Pruned by the writer, on the hour boundary only. Readers glob the whole
    # directory and filter on the epoch in each line, so the file NAME is
    # rotation and nothing else — the 180-minute floor is what bounds the box.
    if [ "$hr" != "$_GHLL_HOUR" ]; then
      _GHLL_HOUR="$hr"
      find "$dir" -maxdepth 1 -name '*.log' -mmin +180 -delete
    fi
  } >/dev/null 2>&1 || true
}

gh() {
  local ef rc=0 msg
  _ghll_count "$@"
  ef=$(mktemp 2>/dev/null) || { command gh "$@"; return $?; }
  command gh "$@" 2>"$ef" || rc=$?
  cat "$ef" >&2
  # `|| msg=""` IS LOAD-BEARING, not tidiness. grep exits 1 when stderr is clean,
  # which is every SUCCESSFUL call — and an assignment from a failed command
  # substitution is a failed command, so under `set -e` this line killed the
  # caller before `return "$rc"` ran. A drop-in wrapper may not do that to the
  # first `set -euo pipefail` lane that sources it (section 4p of
  # tests/gh-default-identity-test.sh is that lane).
  msg=$(grep -m1 -iE "$_GHLL_RE" "$ef" 2>/dev/null) || msg=""
  # A 401 inside a conductor worker marks the worker (bin/lib/gh-rest-auth.sh):
  # its next gh_rest sends nothing. An `if`, not a bare `&&` chain, for the same
  # set -e reason as the line above.
  if [ -n "${GH_REST_AUTH_FAIL_FILE:-}" ] && grep -qE 'HTTP 401|Bad credentials' "$ef" 2>/dev/null; then
    : > "$GH_REST_AUTH_FAIL_FILE" 2>/dev/null || true
  fi
  rm -f "$ef" 2>/dev/null
  if [ -n "$msg" ]; then
    # Every failure below is swallowed on purpose: the caller's rc is the gh
    # call's rc, whatever this bookkeeping does.
    { msg=$(printf '%s' "$msg" | sed -E 's/gh[a-z]_[A-Za-z0-9_]+/<redacted>/g; s/github_pat_[A-Za-z0-9_]+/<redacted>/g' | cut -c1-200)
      mkdir -p "$_GHLL_H/logs"
      printf '%s gh-limit identity=%s rc=%s cmd=%s msg=%s\n' \
        "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "${GH_LIMIT_IDENTITY:-unset}" "$rc" \
        "${1:-} ${2:-}" "$msg" >> "$_GHLL_H/logs/gh-rate.log"
    } >/dev/null 2>&1 || true
  fi
  return "$rc"
}
