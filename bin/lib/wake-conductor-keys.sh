#!/bin/bash
# bin/lib/wake-conductor-keys.sh — turn a checks wake's head sha into the open
# PR(s) it heads, for bin/wake-loop.sh's keyed conductor launch (BH-5521).
# Sourced, never executed.
#
# The wake loop first maps a sha through the conductor's pr-state.tsv. A sha
# that file does not know (a head the conductor has not seen yet, a main-branch
# CI run, a pre-queue run on main) used to make the whole batch unkeyed: a
# fleet-wide full tick for one event. This asks GitHub once instead.
#
# gh-rest: no-graphql
#
# No side effect at source time, no `exit`, no root default (D43).

if ! command -v gh_rest_var >/dev/null 2>&1; then
  # shellcheck source=bin/lib/gh-rest.sh
  [ -r "$(dirname "${BASH_SOURCE[0]}")/gh-rest.sh" ] && . "$(dirname "${BASH_SOURCE[0]}")/gh-rest.sh"
fi

# wck_sha_prs <lrepo> <sha> — print `<lrepo>#<n>` for each OPEN PR whose head
# starts with <sha>, deduped. rc 0 = one or more printed; rc 1 = GitHub answered
# and no open PR has that head (a merge commit on main, a moved head); rc 2 =
# unreadable (bad input, no gh_rest_var, rate limited, not a list). Never guesses.
#
# BH-10351: the read goes through prr_read wake-loop "<lrepo>@<sha12>:sha"
# and the wake-loop seam (bin/lib/prr-shadow.d/wake-loop.sh: wl_sha_record,
# wl_sha_github, wl_sha_norm), so in step record the PR record answers first:
# the open PRs it holds at that head, or "none" for the tip of a base branch
# the PR snapshot knows. Hub 2026-11-27 08:00Z-09:00Z: 301 of these reads
# (wake-loop 183, merge-conductor-wake 118). No prr-shadow lib or no seam:
# the GitHub read below, as before.
wck_sha_prs() {
  local lrepo="${1:-}" sha="${2:-}" f rc=0
  [[ "$lrepo" =~ ^[a-z0-9._-]+/[a-z0-9._-]+$ ]] || return 2
  [[ "$sha" =~ ^[0-9a-f]{7,64}$ ]] || return 2
  if _wck_prr_on && f=$(mktemp "${TMPDIR:-/tmp}/wck-sha.XXXXXX" 2>/dev/null); then
    prr_read wake-loop "$lrepo@${sha:0:12}:sha" "$f" wl_sha_record wl_sha_github wl_sha_norm "$lrepo" "$sha" || rc=$?
    if [ "$rc" = 0 ] && [ -s "$f" ]; then cat "$f"; rm -f "$f"; return 0; fi
    rm -f "$f"
    case "$rc" in 0|1) return 1 ;; *) return 2 ;; esac
  fi
  wck_sha_prs_github "$lrepo" "$sha"
}

# _wck_prr_on — rc 0 when prr_read and the wake-loop seam's sha functions are
# loaded (both are loaded here on first use, from this lib's directory).
_wck_prr_on() {
  local d="${BASH_SOURCE[0]%/*}"
  if ! declare -F prr_read >/dev/null 2>&1 && [ -r "$d/prr-shadow.sh" ]; then
    # shellcheck source=bin/lib/prr-shadow.sh
    . "$d/prr-shadow.sh" 2>/dev/null || true
  fi
  declare -F prr_read >/dev/null 2>&1 || return 1
  declare -F wl_sha_record >/dev/null 2>&1 || prr_seam_load wake-loop 2>/dev/null || return 1
  declare -F wl_sha_record >/dev/null 2>&1
}

# wck_sha_prs_github <lrepo> <sha> — today's read (the GitHub side of the
# seam): ONE GET repos/<lrepo>/commits/<sha>/pulls, same output and rc as
# wck_sha_prs.
wck_sha_prs_github() {
  local lrepo="${1:-}" sha="${2:-}" body out
  [[ "$lrepo" =~ ^[a-z0-9._-]+/[a-z0-9._-]+$ ]] || return 2
  [[ "$sha" =~ ^[0-9a-f]{7,64}$ ]] || return 2
  command -v gh_rest_var >/dev/null 2>&1 || return 2
  # gh_rest_var, never $(gh_rest ...): a command substitution drops the
  # GH_REST_STATUS the helper sets (gh-rest-no-subshell-lint).
  gh_rest_var body GET "repos/$lrepo/commits/$sha/pulls" || return 2
  out=$(jq -r --arg s "$sha" 'if type=="array" then .[] | select(.state=="open")
          | select(((.head.sha // "") | ascii_downcase | startswith($s))) | .number
        else error("not a list") end' <<<"$body" 2>/dev/null) || return 2
  out=$(grep -E '^[0-9]+$' <<<"$out" | awk '!seen[$0]++')
  [ -n "$out" ] || return 1
  sed "s|^|$lrepo#|" <<<"$out"
}
