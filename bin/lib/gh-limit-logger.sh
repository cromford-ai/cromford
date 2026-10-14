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
#   <epoch> <caller> <argv1> <argv2>
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

# _ghll_count <argv1> <argv2> — one line per wrapped call. printf's %()T is a
# bash builtin, so counting costs no fork; `date` here would double the process
# count of every lane that makes hundreds of gh calls a tick. Every failure is
# swallowed: the count is bookkeeping, the gh call is the point.
_ghll_count() {
  local ep hr dir
  printf -v ep '%(%s)T' -1
  printf -v hr '%(%Y%m%d%H)T' -1
  dir="$_GHLL_H/logs/gh-calls"
  {
    mkdir -p "$dir"
    printf '%s %s %s %s\n' "$ep" "${GH_CALL_CALLER:-${0##*/}}" "${1:-}" "${2:-}" \
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
  _ghll_count "${1:-}" "${2:-}"
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
