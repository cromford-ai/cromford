#!/bin/bash
# gh-identity: raw-by-design — sourced by bin/main-red-detector.sh after it has armed the repo's identity (gh_default_auth_for_slug); minting a second token here would override it
# bin/lib/main-red-queue-attr.sh — BH-3890 (3 of 5 of BH-3886): was a red
# merge-queue batch broken by one of its OWN PRs?
#
# mrqa_attr <owner/repo> <run-id> <pr-number...> sets
#   MRQA_VERDICT  own | untouched | unreadable
#   MRQA_PR       the PR that owns it (own only)
#   MRQA_WHY      the failure line and the path, or why it could not be read
# and always returns 0; the caller (mr_queue_verdict) reads only the globals.
#
# THE RULE. Read the run's failure text (`gh run view --log-failed`, bounded at
# FLAKY_LOG_MAX bytes, flaky.sh's default), keep only FAILURE lines, take every
# repo path token on them, and read each batch PR's changed files (`gh api
# …/pulls/<n>/files --paginate`). `own` means a failure-line path is EXACTLY a
# file one of THESE PRs changes: the batch's own diff broke the suite that went
# red, so the red says nothing about main. Anything else is `untouched`.
#
# THE FAIL DIRECTION. `own` is the only answer that removes a count, so it needs
# proof: a failed or empty read, a log over the cap, or one PR's file list that
# cannot be read is `unreadable`, and unreadable COUNTS, exactly like untouched.
#
# THE CACHE. A completed run never changes, so own/untouched is written to the
# ledger (kind main_red_qattr, key <owner/repo>#<run-id>, value
# `own pr=<n> path=<p>` or `untouched`) and the next tick — and the BH-1927
# confirming re-read in the same tick — answers from it with no read.
# `unreadable` is never written; an unusable ledger means read again. Under
# --explain (EXPLAIN=1) nothing is written.
MRQA_KIND=main_red_qattr
# A failure line: a suite that exited non-zero in the traced runner, a FAIL:
# summary, a TAP `not ok`, a thrown Error / node ERR_ code, the gh ratchet's
# `raw gh call`, and a `RED: <path> …` line at the start of the line content
# (no-state-files, suite-reach-check and the tests/ convention name the file
# that broke this way; BH-9516, the 2026-11-11 false freeze, where three
# PR-owned `RED:` batches read as untouched). Case-sensitive on purpose: a wider
# match only adds attributions.
MRQA_FAIL_RE='(--- tests/[^ ]+ rc=[1-9]|FAIL:|not ok|Error|ERR_|raw gh call|^[[:space:]]*RED: )'

_mrqa_log() { if declare -F log >/dev/null 2>&1; then log "$@"; fi; return 0; }

# _mrqa_paths — a raw --log-failed text on stdin; prints "<path>\t<excerpt>"
# for every repo path named on a failure line, first occurrence per path, in
# log order (the excerpt is the line without its indent, cut to 160). A token is a MAXIMAL run of path characters (with any :<line>
# suffix, trailing dots and leading ./ removed) that ENDS in a source
# extension, so `tests/foo-test.sh.bak` is dropped, never read as
# `tests/foo-test.sh`.
_mrqa_paths() {
  local t=$'\t'
  sed -E "s/^[^${t}]*${t}[^${t}]*${t}//; s/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z ?//" \
    | grep -aE -- "$MRQA_FAIL_RE" \
    | awk '{
        line = $0; sub(/^[ \t]+/, "", line); s = line
        while (match(s, /[A-Za-z0-9_.\/-]+(:[0-9]+)?/)) {
          tok = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
          sub(/:[0-9]+$/, "", tok); sub(/\.+$/, "", tok); sub(/^\.\//, "", tok)
          if (tok ~ /\.(sh|js|mjs|ts|py|json|yml|yaml|sql|md)$/ && !(tok in seen)) {
            seen[tok] = 1; print tok "\t" substr(line, 1, 160)
          }
        }
      }'
}

# _mrqa_fail <why> — the unreadable answer, logged once; never cached.
_mrqa_fail() {
  MRQA_VERDICT=unreadable; MRQA_PR=""; MRQA_WHY="$1"
  _mrqa_log "${_mrqa_slug:-?}: queue batch ${_mrqa_id:-?} attribution unreadable ($1) — it stays counted"
}

# _mrqa_put <key> <value> — the cache write, after the verdict is decided.
_mrqa_put() {
  [ "${EXPLAIN:-0}" = 1 ] && return 0
  command -v job_ledger_put >/dev/null 2>&1 || return 0
  job_ledger_put "$MRQA_KIND" "$1" "$2" >/dev/null 2>&1 \
    || _mrqa_log "${_mrqa_slug:-?}: queue batch ${_mrqa_id:-?} attribution could not be cached — the next tick reads it again"
  return 0
}

mrqa_attr() {
  MRQA_VERDICT=unreadable; MRQA_PR=""; MRQA_WHY=""
  local _mrqa_slug="${1:-}" _mrqa_id="${2:-}"
  local slug="${1:-}" id="${2:-}" key cached max tmp rc size paths n p ex files
  shift 2 2>/dev/null || { _mrqa_fail "no slug and run id"; return 0; }
  local -a prs=("$@")
  local -A pf=()
  [[ "$slug" =~ ^[^/\ ]+/[^/\ ]+$ ]] || { _mrqa_fail "bad slug '$slug'"; return 0; }
  [[ "$id" =~ ^[0-9]+$ ]] || { _mrqa_fail "bad run id '$id'"; return 0; }
  [ "${#prs[@]}" -gt 0 ] || { _mrqa_fail "no PR numbers"; return 0; }
  for n in "${prs[@]}"; do [[ "$n" =~ ^[0-9]+$ ]] || { _mrqa_fail "bad PR number '$n'"; return 0; }; done
  key="$slug#$id"

  # The cache. Only a well-formed own/untouched row answers; rc 1 (ledger
  # unusable), rc 2 (no row) and anything else read live.
  if command -v job_ledger_get >/dev/null 2>&1 && cached=$(job_ledger_get "$MRQA_KIND" "$key" 2>/dev/null); then
    if [[ "$cached" =~ ^own\ pr=([0-9]+)\ path=(.+)$ ]]; then
      MRQA_VERDICT=own; MRQA_PR="${BASH_REMATCH[1]}"; MRQA_WHY="cached: #${BASH_REMATCH[1]} changes ${BASH_REMATCH[2]}"
      return 0
    elif [ "$cached" = untouched ]; then
      MRQA_VERDICT=untouched; MRQA_WHY="cached: untouched"
      return 0
    fi
  fi

  # The failure text, bounded the way flaky_run_tests_strict bounds it.
  max="${FLAKY_LOG_MAX:-2000000}"
  [[ "$max" =~ ^[0-9]+$ ]] && [ "$max" -gt 0 ] || { _mrqa_fail "FLAKY_LOG_MAX '$max' is not a positive number"; return 0; }
  tmp=$(mktemp "${TMPDIR:-/tmp}/mrqa.XXXXXX" 2>/dev/null) || { _mrqa_fail "no temp file"; return 0; }
  gh run view "$id" -R "$slug" --log-failed > "$tmp" 2>/dev/null </dev/null; rc=$?
  [ "$rc" = 0 ] || { rm -f "$tmp"; _mrqa_fail "the failed-log read answered rc $rc"; return 0; }
  size=$(wc -c < "$tmp" 2>/dev/null | tr -d ' ')
  [ "${size:-0}" -gt 0 ] 2>/dev/null || { rm -f "$tmp"; _mrqa_fail "the failed-log is empty"; return 0; }
  [ "$size" -le "$max" ] || { rm -f "$tmp"; _mrqa_fail "the failed-log is $size bytes, over FLAKY_LOG_MAX $max"; return 0; }
  paths=$(_mrqa_paths < "$tmp")
  rm -f "$tmp"
  if [ -z "$paths" ]; then
    MRQA_VERDICT=untouched; MRQA_WHY="no repo path on a failure line"
    _mrqa_put "$key" untouched
    return 0
  fi

  # Each PR's changed files; one that cannot be read leaves the batch unproven.
  for n in "${prs[@]}"; do
    files=$(gh api "repos/$slug/pulls/$n/files" --paginate -q '.[].filename' 2>/dev/null </dev/null); rc=$?
    [ "$rc" = 0 ] || { _mrqa_fail "the files of #$n answered rc $rc"; return 0; }
    [ -n "$files" ] || { _mrqa_fail "the files of #$n came back empty"; return 0; }
    pf[$n]="$files"
  done

  # Exact path equality, failure paths in log order, PRs in argument order.
  while IFS=$'\t' read -r p ex; do
    [ -n "$p" ] || continue
    for n in "${prs[@]}"; do
      if grep -Fxq -- "$p" <<<"${pf[$n]}"; then
        MRQA_VERDICT=own; MRQA_PR="$n"; MRQA_WHY="$ex (#$n changes $p)"
        _mrqa_put "$key" "own pr=$n path=$p"
        return 0
      fi
    done
  done <<<"$paths"
  MRQA_VERDICT=untouched; MRQA_WHY="no failure-line path is a file this batch's PRs change"
  _mrqa_put "$key" untouched
  return 0
}
