#!/bin/bash
# bin/lib/pr-snapshot.sh — BH-4658 (BH-4656 part 1): a shared on-disk snapshot
# of a repo's PRs, so a lane that asks "what is PR <n>'s head" every tick stops
# paying one live `pulls/<n>` read per PR per tick. Sourced, never executed.
#
#   prs_open_list <slug> <out>       the open-PR list (raw REST rows) into <out>
#   prs_base_tip <slug> <base>       print the 40-hex sha of heads/<base>
#   prs_pr_get <slug> <n> <head> <updated_at> <base> <out>
#                                    the pulls/<n> body into <out>
#   prs_gc                           drop pr-* files older than 3 days
#   prs_wake_seen <slug> <any|push|pr> <ref|n|-> <since-epoch>
#                                    rc 0 = a wake for it arrived since, rc 1 =
#                                    none did, rc 2 = unknown. This file answers
#                                    2; bin/lib/pr-snapshot-wakes.sh (BH-4656)
#                                    replaces it when it is present.
#
# Every function returns the gh_rest code of the read it made (0 / 44 / 75), so
# a caller reads it exactly as it read gh_rest. Unreadable is never empty: a
# read that failed stores nothing, never overwrites a good file, and a cache
# past its TTL is never served.
#
# THE PER-PR KEY is (head, updated_at, base tip), written to pr-<n>.key next to
# pr-<n>.json and compared byte for byte. A hit needs all three non-empty and
# not `-`, the key equal, the cached body's .head.sha equal to the head, and no
# `pr` wake since the key was written. A body is only stored when its own
# .head.sha IS the list head and GitHub had finished computing it (mergeable
# not null, mergeable_state not unknown): caching an unfinished answer would
# freeze it. So a hit is the live head as of the last change to the PR.
#
# LOCKS ARE DEDUPE, NEVER A QUEUE: open.lock and pr-<n>.lock are `flock -n`.
# The loser reads for itself and writes nothing; nothing ever waits.
#
# KNOBS (catalog/lanes.d/_lib.pr-snapshot.json, keys lib.pr-snapshot.*):
# PR_SNAPSHOT (the kill switch), PR_SNAPSHOT_TTL_S, PR_SNAPSHOT_QUIET_TTL_S and
# PR_SNAPSHOT_FEED_STALE_S (read by the wakes sibling). They resolve the way
# bin/lib/gh-budget.sh's do: lib_env_apply in a SUBSHELL, handing back on fd 3
# whatever resolved. Empty or not a number: PR_SNAPSHOT means off (every
# function calls GitHub straight through and touches no file), a TTL means 0
# (no cache). Each takes the branch that does less.
#
# The root is ${HARNESS:-${H:-}} and nothing else; with none, the snapshot is
# off. No `set -e`, no `exit`, every fallible call is `cmd || rc=$?`.
if [ -n "${PR_SNAPSHOT_LIB:-}" ]; then return 0 2>/dev/null; fi
PR_SNAPSHOT_LIB=1
# shellcheck source=bin/lib/gh-rest-list.sh
command -v _gh_rest_list >/dev/null 2>&1 || . "$(dirname "${BASH_SOURCE[0]}")/gh-rest-list.sh" 2>/dev/null

_PRS_KV=$(
  exec 3>&1
  _PRS_R=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd) || exit 0
  command -v lib_env_apply >/dev/null 2>&1 || . "$_PRS_R/bin/lib/lane-gate.sh" >/dev/null 2>&1 || exit 0
  if [ -z "${LANE_REGISTRY:-}" ] && [ ! -r "$(_lg_registry)" ] && . "$_PRS_R/bin/lib/lanes-registry.sh" >/dev/null 2>&1; then
    LANE_REGISTRY=$(lanes_json_path "$_PRS_R" 2>/dev/null) && export LANE_REGISTRY
  fi
  trap 'for _PRS_K in PR_SNAPSHOT PR_SNAPSHOT_TTL_S PR_SNAPSHOT_QUIET_TTL_S PR_SNAPSHOT_FEED_STALE_S; do printf "%s\t%s\n" "$_PRS_K" "${!_PRS_K:-}" >&3; done' EXIT
  lib_env_apply pr-snapshot >/dev/null 2>&1)
while IFS=$'\t' read -r _PRS_K _PRS_V; do
  if [ -n "$_PRS_V" ]; then printf -v "$_PRS_K" '%s' "$_PRS_V"; fi
done <<<"$_PRS_KV"
unset _PRS_KV _PRS_K _PRS_V

_prs_int() { case "${1:-}" in ''|*[!0-9]*) printf 0 ;; *) printf '%s' "$((10#$1))" ;; esac; }
_prs_dir() { # _prs_dir <slug> — rc 1 when there is no root or no usable slug
  local h="${HARNESS:-${H:-}}" s
  s=$(printf '%s' "${1//\//_}" | tr -cd 'A-Za-z0-9._-')
  [ -n "$h" ] && [ -n "$s" ] || return 1
  printf '%s/state/pr-snapshot/%s' "$h" "$s"
}
_prs_on() { [ "${PR_SNAPSHOT:-}" = 1 ] && [ "$(_prs_int "${PR_SNAPSHOT_TTL_S:-}")" -gt 0 ]; }
_prs_count() { [ -n "${PRS_COUNT_FILE:-}" ] && printf '%s %s\n' "$1" "$2" >> "$PRS_COUNT_FILE" 2>/dev/null; return 0; }

prs_wake_seen() { return 2; }

prs_open_list() {
  local slug="$1" out="$2" d meta ttl now wrc=0 rc=0 fd tmp
  # BH-9938 C1: the merge conductor (PRS_OPEN_PRR=merge-conductor) reads its
  # open list through prr_read and its seam (mc_open_record / mc_open_github,
  # bin/lib/prr-shadow.d/merge-conductor.sh). The GitHub side calls back here
  # with _PRS_IN_PRR=1 and runs the body below unchanged. A record answer is
  # never written into the shared snapshot. Every other lane: no change.
  if [ "${PRS_OPEN_PRR:-}" = merge-conductor ] && [ -z "${_PRS_IN_PRR:-}" ] \
     && declare -F prr_read >/dev/null 2>&1 && declare -F mc_open_record >/dev/null 2>&1; then
    prr_read merge-conductor "$slug#open" "$out" mc_open_record mc_open_github mc_open_norm "$slug"
    return
  fi
  if ! _prs_on || ! d=$(_prs_dir "$slug") || ! mkdir -p "$d" 2>/dev/null; then
    _gh_rest_list "$slug" pulls 1000 '.' -f state=open > "$out" || rc=$?
    return "$rc"
  fi
  now=$(date +%s)
  meta=$(tr -dc '0-9' < "$d/open.meta" 2>/dev/null)
  if [ -n "$meta" ] && [ -r "$d/open.json" ]; then
    ttl=$(_prs_int "${PR_SNAPSHOT_TTL_S:-}")
    prs_wake_seen "$slug" any - "$meta" || wrc=$?
    [ "$wrc" = 1 ] && ttl=$(_prs_int "${PR_SNAPSHOT_QUIET_TTL_S:-}")
    if [ $((now - meta)) -ge 0 ] && [ $((now - meta)) -lt "$ttl" ] && cp "$d/open.json" "$out" 2>/dev/null; then return 0; fi
  fi
  # The braces scope the 2>/dev/null to the open: a bare `exec {fd}>f 2>/dev/null`
  # rebinds fd 2 for the rest of the caller's process.
  if ! { exec {fd}>"$d/open.lock"; } 2>/dev/null; then
    _gh_rest_list "$slug" pulls 1000 '.' -f state=open > "$out" || rc=$?
    return "$rc"
  fi
  if ! flock -n "$fd"; then
    exec {fd}>&-
    _gh_rest_list "$slug" pulls 1000 '.' -f state=open > "$out" || rc=$?
    return "$rc"
  fi
  tmp="$d/open.json.tmp.$$"
  _gh_rest_list "$slug" pulls 1000 '.' -f state=open > "$tmp" || rc=$?
  if [ "$rc" != 0 ]; then
    rm -f "$tmp"; exec {fd}>&-; : > "$out"
    return "$rc"
  fi
  if mv -f "$tmp" "$d/open.json" 2>/dev/null; then
    printf '%s\n' "$now" > "$d/open.meta.tmp.$$" 2>/dev/null && mv -f "$d/open.meta.tmp.$$" "$d/open.meta" 2>/dev/null
    rm -f "$d/open.meta.tmp.$$"
    cp "$d/open.json" "$out" || rc=75
  else
    mv -f "$tmp" "$out" 2>/dev/null || rc=75
  fi
  exec {fd}>&-
  return "$rc"
}

prs_base_tip() {
  local slug="$1" base="${2:-}" d="" f="" ep sha now rc=0 tmp
  [ -n "$base" ] || return 1
  now=$(date +%s)
  if _prs_on && d=$(_prs_dir "$slug"); then
    f="$d/base-$(printf '%s' "${base//\//_}" | tr -cd 'A-Za-z0-9._-')"
    ep=""; sha=""
    [ -r "$f" ] && IFS=$'\t' read -r ep sha < "$f"
    case "$ep" in ''|*[!0-9]*) ep="" ;; esac
    if [ -n "$ep" ] && [[ "$sha" =~ ^[0-9a-f]{40}$ ]] && [ $((now - ep)) -ge 0 ] \
       && [ $((now - ep)) -lt "$(_prs_int "${PR_SNAPSHOT_TTL_S:-}")" ]; then
      prs_wake_seen "$slug" push "$base" "$ep" || rc=$?
      if [ "$rc" != 0 ]; then printf '%s\n' "$sha"; return 0; fi
    fi
  fi
  tmp=$(mktemp "${TMPDIR:-/tmp}/pr-snapshot.XXXXXX") || return 1
  rc=0; gh_rest GET "repos/$slug/git/ref/heads/$base" > "$tmp" || rc=$?
  sha=$(jq -r '.object.sha // empty' "$tmp" 2>/dev/null | tr 'A-F' 'a-f')
  rm -f "$tmp"
  [ "$rc" = 0 ] && [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 1
  if [ -n "$f" ] && mkdir -p "$d" 2>/dev/null; then
    printf '%s\t%s\n' "$now" "$sha" > "$f.tmp.$$" 2>/dev/null && mv -f "$f.tmp.$$" "$f" 2>/dev/null
    rm -f "$f.tmp.$$"
  fi
  printf '%s\n' "$sha"
}

prs_pr_get() {
  local slug="$1" n="$2" head lupd="${4:-}" base="${5:-}" out="$6" d tip="" key valid=1 rc=0 wrc=0 kf jf fd v
  head=$(printf '%s' "${3:-}" | tr 'A-F' 'a-f')
  if ! _prs_on || ! d=$(_prs_dir "$slug"); then
    _prs_count MISS "$n"
    gh_rest GET "repos/$slug/pulls/$n" > "$out" || rc=$?
    return "$rc"
  fi
  case "$n" in ''|*[!0-9]*) valid=0 ;; esac
  [[ "$head" =~ ^[0-9a-f]{40}$ ]] || valid=0
  [ "$valid" = 1 ] && { tip=$(prs_base_tip "$slug" "$base" 2>/dev/null) || tip=""; }
  for v in "$lupd" "$tip"; do case "$v" in ''|-) valid=0 ;; esac; done
  key=$(printf '%s\t%s\t%s' "$head" "$lupd" "$tip")
  kf="$d/pr-$n.key"; jf="$d/pr-$n.json"
  if [ "$valid" = 1 ] && [ -r "$kf" ] && [ -r "$jf" ] && cmp -s "$kf" <(printf '%s' "$key") \
     && [ "$(jq -r '.head.sha // empty' "$jf" 2>/dev/null | tr 'A-F' 'a-f')" = "$head" ]; then
    prs_wake_seen "$slug" pr "$n" "$(stat -c %Y "$kf" 2>/dev/null || echo 0)" || wrc=$?
    if [ "$wrc" != 0 ] && cp "$jf" "$out" 2>/dev/null; then _prs_count HIT "$n"; return 0; fi
  fi
  _prs_count MISS "$n"
  # A plain command with `> file`, never `$( )`: GH_REST_STATUS has to survive
  # into the caller's shell for its log line.
  gh_rest GET "repos/$slug/pulls/$n" > "$out" || rc=$?
  [ "$rc" = 0 ] && [ "$valid" = 1 ] || return "$rc"
  jq -e --arg h "$head" '.mergeable != null and .mergeable_state != "unknown"
    and ((.head.sha // "") | ascii_downcase) == $h' "$out" >/dev/null 2>&1 || return 0
  mkdir -p "$d" 2>/dev/null && { exec {fd}>"$d/pr-$n.lock"; } 2>/dev/null || return 0
  if flock -n "$fd"; then
    # The body first, then its key: a key never names a body that is not on disk.
    cp "$out" "$jf.tmp.$$" 2>/dev/null && mv -f "$jf.tmp.$$" "$jf" 2>/dev/null \
      && printf '%s' "$key" > "$kf.tmp.$$" 2>/dev/null && mv -f "$kf.tmp.$$" "$kf" 2>/dev/null
    rm -f "$jf.tmp.$$" "$kf.tmp.$$"
  fi
  exec {fd}>&-
  return 0
}

prs_gc() {
  local h="${HARNESS:-${H:-}}"
  [ -n "$h" ] && [ -d "$h/state/pr-snapshot" ] || return 0
  find "$h/state/pr-snapshot" -name 'pr-*' -type f -mtime +3 -delete 2>/dev/null
  return 0
}

# The wakes sibling (BH-4656), when this box has it, replaces prs_wake_seen.
_PRS_F="$(dirname "${BASH_SOURCE[0]}")/pr-snapshot-wakes.sh"
# shellcheck source=/dev/null
[ -r "$_PRS_F" ] && . "$_PRS_F"
unset _PRS_F
