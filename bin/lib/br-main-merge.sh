#!/bin/bash
# shellcheck shell=bash
# bin/lib/br-main-merge.sh — the blocked-resolver mechanical rung asks
# "does this PR need a merge of main?" before mc_rebase. Sourced by
# bin/blocked-resolver.sh, never run: no `set`, no `exit`, nothing runs at
# source time.
#
#   br_main_merge_gate <p> <ck> <rkey> <reason> <slug> <br> <head> <url>
#     Fetches origin main and <br> into $REPOS/<p> (best effort), then asks
#     pr_needs_main_merge (bin/lib/main-merge-need.sh).
#       rc 0  the gate answered the park; the rung returns:
#             queued -> record `queued-skip`, no counter: a push into a
#               Mergify batch ejects the PR from it.
#             clean on a `conflict-unresolvable*` park -> record
#               `conflict-cleared`, no counter. The rung's caller then releases the conductor hand-off,
#               so the conductor judges the PR again.
#       rc 3  clean on any other park: no merge; the caller runs its existing
#             "nothing to merge -> re-run the failed CI" arm.
#       rc 1  merge as before (conflict, stale schema stamp, gate off, cannot
#             tell, no lib, or a `rebase-gate-red` park: its merge is clean by
#             definition, and its red gate needs the merge and the fix round).
#
# Needs the caller's say, br_record, br_event, br_ladder_class, mc_git_auth,
# mc_git_bounded, mc_num_of_url and REPOS.

# shellcheck source=bin/lib/main-merge-need.sh
command -v pr_needs_main_merge >/dev/null 2>&1 || . "$(dirname "${BASH_SOURCE[0]}")/main-merge-need.sh"

br_main_merge_gate() {
  local p="$1" ck="$2" rkey="$3" reason="$4" slug="$5" br="$6" head="$7" url="$8"
  local repo="${REPOS:-}/$p" why nrc
  command -v pr_needs_main_merge >/dev/null 2>&1 || return 1
  [ -n "${REPOS:-}" ] || return 1
  # A repo that is missing, or a fetch that fails, leaves the check on what is
  # there: a head it cannot find is "unknown", and unknown merges as before.
  if [ -d "$repo/.git" ]; then
    command -v mc_git_auth >/dev/null 2>&1 && mc_git_auth "$slug" >/dev/null 2>&1
    if command -v mc_git_bounded >/dev/null 2>&1; then
      mc_git_bounded 180 git -C "$repo" -c credential.helper= fetch -q origin main "$br" >/dev/null 2>&1
    fi
  fi
  why=$(pr_needs_main_merge "$slug" "$(mc_num_of_url "$url")" "$repo" "$head" origin/main); nrc=$?
  [ "$nrc" = 1 ] || return 1
  if [ "$why" = queued ]; then
    br_record "$p" "$ck" queued-skip "$reason" "$br is in the merge queue (queued/checking label) at ${head:0:8}; no main merge, no rung spent"
    br_event queued-skip "$p" "$ck" "$reason" "$br is in the merge queue at ${head:0:8}; no main merge"
    say "$p/$rkey [$reason]: main merge skipped: $(pr_main_merge_why queued) — no rung spent"
    return 0
  fi
  # Only a CONFLICT park is cleared by a clean tree. `rebase-gate-red` shares
  # the rebase-conflict ladder class, but mc_rebase writes it when the merge of
  # main is clean and the hub gate fails: a clean merge-tree is its normal case,
  # not a cleared park. It merges as before (rc 1), so it reaches its fix round.
  case "$reason" in
    conflict-unresolvable*) ;;
    *) [ "$(br_ladder_class "$reason")" = rebase-conflict ] && return 1 ;;
  esac
  if [ "$(br_ladder_class "$reason")" = rebase-conflict ]; then
    br_record "$p" "$ck" conflict-cleared "$reason" "$br no longer conflicts with origin/main at ${head:0:8}; park cleared, no merge"
    br_event conflict-cleared "$p" "$ck" "$reason" "$br no longer conflicts with origin/main at ${head:0:8}"
    say "$p/$rkey [$reason]: main merge skipped: clean against main — the conflict park is cleared"
    return 0
  fi
  say "$p/$rkey [$reason]: main merge skipped: clean against main"
  return 3
}
