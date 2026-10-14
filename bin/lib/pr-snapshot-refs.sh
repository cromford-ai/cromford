#!/bin/bash
# bin/lib/pr-snapshot-refs.sh — BH-4659 (BH-4656.1): branch tips from ONE refs
# read per branch prefix, so the conductor stops paying one `branches/<br>`
# read per PR per tick. Sourced, never executed.
#
#   prs_branch_tip <slug> <branch>   rc 0 and the 40-hex tip on stdout (a hit),
#                                    rc 2 (a miss). Never a "gone" answer: a
#                                    miss is the caller's cue to probe live.
#   prs_refs_pin <slug> <pin-prefix> <branch>...
#                                    BH-6462: pin this tick's refs, once per
#                                    branch prefix (THE PIN, below). Always rc 0.
#
# The read is `GET repos/<slug>/git/matching-refs/heads/<prefix>/`, where
# <prefix> is the branch's first path segment. It is ONE gh_rest GET, not
# _gh_rest_list: the endpoint answers every match at once and has no pages, so
# paging it would fetch the same set again per page. A truncated answer could
# only turn a hit into a miss, and a miss probes live.
#
# A MISS when: the snapshot is off (_prs_on), there is no root, the branch has
# no `/`, the open list (open.json) is unreadable or no open PR's head.ref
# shares the prefix (so only the prefixes open PRs use are ever read), the read
# failed or did not answer an array, or the branch is not in it with a 40-hex
# sha.
#
# THE CACHE is state/pr-snapshot/<owner_repo>/refs-<prefix>.json, an array of
# {ref, sha} (refs/heads/ stripped, sha lowercased), trusted while it is younger
# than PR_SNAPSHOT_TTL_S. It is written under `flock -n refs-<prefix>.lock`,
# temp file then mv, and never after a failed read. The loser of the lock reads
# for itself and writes nothing: the lock is dedupe, never a queue.
#
# THE PIN (BH-6462). A tick runs its workers at the same time for up to 200 s,
# so each worker that reached head-lag past the TTL, or before the first read
# landed, made its own refs read. prs_refs_pin runs once in the tick before the
# workers start: per distinct prefix of the branches it is given, it asks
# prs_branch_tip once (one GET at most, none while the cache is fresh), then
# copies the cache to <pin-prefix><owner_repo>-<prefix>.json (temp file, then
# mv), but only while that cache is younger than PR_SNAPSHOT_TTL_S. A failed
# read, a branch without `/` and the snapshot switched off write nothing.
# prs_branch_tip reads the pin first when the CALLER sets PRS_REFS_PIN_PREFIX:
# a pin that is an array holding the branch with a 40-hex sha answers, whatever
# its age. A branch it does not hold, or a pin that is missing or not an array,
# takes the path above. Only head_lag_tip passes the variable, and it trusts a
# refs tip only when it equals the PR head from the same tick's open list.
#
# No `set -e`, no `exit`; the root is pr-snapshot.sh's ${HARNESS:-${H:-}}.
if [ -n "${PR_SNAPSHOT_REFS_LIB:-}" ]; then return 0 2>/dev/null; fi
PR_SNAPSHOT_REFS_LIB=1
# shellcheck source=bin/lib/pr-snapshot.sh
command -v prs_open_list >/dev/null 2>&1 || . "$(dirname "${BASH_SOURCE[0]}")/pr-snapshot.sh" 2>/dev/null

prs_branch_tip() {
  local slug="${1:-}" br="${2:-}" d pre safe f src="" now m ttl tmp fd rc=0 sha
  command -v _prs_on >/dev/null 2>&1 && _prs_on || return 2
  d=$(_prs_dir "$slug") || return 2
  case "$br" in ?*/?*) ;; *) return 2 ;; esac
  pre="${br%%/*}"
  safe=$(printf '%s' "$pre" | tr -cd 'A-Za-z0-9._-')
  [ "$safe" = "$pre" ] || return 2
  jq -e --arg p "$pre/" 'type == "array" and any(.[]; (.head.ref // "") | startswith($p))' \
    "$d/open.json" >/dev/null 2>&1 || return 2
  if [ -n "${PRS_REFS_PIN_PREFIX:-}" ]; then
    sha=$(jq -r --arg r "$br" 'if type == "array" then first(.[] | select(.ref == $r) | .sha) // empty else empty end' \
      "${PRS_REFS_PIN_PREFIX}${d##*/}-$safe.json" 2>/dev/null)
    if [[ "$sha" =~ ^[0-9a-f]{40}$ ]]; then printf '%s\n' "$sha"; return 0; fi
  fi
  f="$d/refs-$safe.json"
  now=$(date +%s); ttl=$(_prs_int "${PR_SNAPSHOT_TTL_S:-}")
  m=$(stat -c %Y "$f" 2>/dev/null) || m=""
  if [ -n "$m" ] && [ $((now - m)) -ge 0 ] && [ $((now - m)) -lt "$ttl" ]; then
    src="$f"
  else
    tmp=$(mktemp "${TMPDIR:-/tmp}/pr-snapshot-refs.XXXXXX") || return 2
    # A plain command with `> file`, never `$( )`: GH_REST_* reach the caller.
    gh_rest GET "repos/$slug/git/matching-refs/heads/$pre/" > "$tmp" || rc=$?
    if [ "$rc" = 0 ] && jq -c 'if type != "array" then error("not an array") else . end
         | [.[] | {ref: ((.ref // "") | sub("^refs/heads/"; "")),
         sha: ((.object.sha // "") | ascii_downcase)}] | unique_by(.ref)' "$tmp" > "$tmp.m" 2>/dev/null; then
      src="$tmp.m"
      # The braces scope the 2>/dev/null to the open (BH-4658).
      if { exec {fd}>"$d/refs-$safe.lock"; } 2>/dev/null; then
        if flock -n "$fd"; then
          cp "$tmp.m" "$f.tmp.$$" 2>/dev/null && mv -f "$f.tmp.$$" "$f" 2>/dev/null
          rm -f "$f.tmp.$$"
        fi
        exec {fd}>&-
      fi
    fi
  fi
  sha=""
  [ -n "$src" ] && sha=$(jq -r --arg r "$br" 'first(.[]? | select(.ref == $r) | .sha) // empty' "$src" 2>/dev/null)
  [ -n "${tmp:-}" ] && rm -f "$tmp" "$tmp.m"
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 2
  printf '%s\n' "$sha"
}

prs_refs_pin() {
  local slug="${1:-}" pin="${2:-}" br d pre safe f m now ttl seen=" "
  [ -n "$pin" ] && [ $# -ge 3 ] || return 0
  command -v _prs_on >/dev/null 2>&1 && _prs_on || return 0
  d=$(_prs_dir "$slug") || return 0
  ttl=$(_prs_int "${PR_SNAPSHOT_TTL_S:-}")
  shift 2
  for br in "$@"; do
    case "$br" in ?*/?*) ;; *) continue ;; esac
    pre="${br%%/*}"
    safe=$(printf '%s' "$pre" | tr -cd 'A-Za-z0-9._-')
    [ "$safe" = "$pre" ] || continue
    case "$seen" in *" $safe "*) continue ;; esac
    seen="$seen$safe "
    PRS_REFS_PIN_PREFIX="" prs_branch_tip "$slug" "$br" >/dev/null 2>&1
    f="$d/refs-$safe.json"
    m=$(stat -c %Y "$f" 2>/dev/null) || continue
    now=$(date +%s)
    [ $((now - m)) -ge 0 ] && [ $((now - m)) -lt "$ttl" ] || continue
    mkdir -p "$(dirname "${pin}x")" 2>/dev/null
    cp "$f" "${pin}${d##*/}-$safe.json.tmp.$$" 2>/dev/null \
      && mv -f "${pin}${d##*/}-$safe.json.tmp.$$" "${pin}${d##*/}-$safe.json" 2>/dev/null
    rm -f "${pin}${d##*/}-$safe.json.tmp.$$" 2>/dev/null
  done
  return 0
}
