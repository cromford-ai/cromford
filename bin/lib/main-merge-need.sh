# shellcheck shell=bash
# bin/lib/main-merge-need.sh — DOES THIS PR BRANCH NEED A MERGE OF MAIN?
# Sourced, never run. No `set -e`, no `exit`, no output and no state at source
# time. One REST read and local git; no model.
#
# WHY. A merge of origin/main into a PR branch makes a new head. The new head
# loses its lead verdict, stops a running Mac gate as STALE and restarts CI.
# The merge queue (Mergify) already tests every PR on current main, so a merge
# with no conflict buys nothing (#6988, 2026-10-16: about 50 minutes lost
# twice). A lane asks this check BEFORE it merges main, and merges only on rc 0.
#
#   pr_needs_main_merge <slug> <pr|-> <git-dir> <head> [<main-ref>=origin/main]
#     Prints one word and returns:
#       rc 0  merge:  gate-off | conflict-github | conflict-merge-tree | schema-stamp
#       rc 1  skip:   queued | clean
#       rc 2  cannot tell: unknown (the caller merges, as before)
#     Order:
#       1. MAIN_MERGE_GATE=0 -> gate-off.
#       2. <pr> a number: GET repos/<slug>/pulls/<pr> (gh_rest, REST only).
#          A `queued` or `checking` label (a PR in a Mergify batch) -> queued,
#          even when GitHub says dirty: a push ejects it from the batch.
#          mergeable == false or mergeable_state == dirty -> conflict-github.
#          A failed read or mergeable == null is no answer, not "clean".
#       3. git merge-tree of <head> against <main-ref> conflicts -> conflict-merge-tree.
#       4. sr_plan (bin/lib/schema-restamp.sh) names a stale schema.d stamp
#          -> schema-stamp.
#       5. merge-tree clean -> clean. merge-tree could not run, and GitHub said
#          mergeable == true and not dirty -> clean. Else unknown.

_mmn_dir="${BASH_SOURCE[0]%/*}"

# _mmn_pr_read <slug> <pr> -> "<queued 0|1> <mergeable true|false|null> <state>"
#   rc 1 when GitHub gave no answer.
_mmn_pr_read() {
  local slug="$1" pr="$2" tmp rc
  command -v gh_rest >/dev/null 2>&1 || . "$_mmn_dir/gh-rest.sh" 2>/dev/null
  command -v gh_rest >/dev/null 2>&1 || return 1
  # A plain command into a file, never inside $( ): gh-rest.sh's rule
  # (tests/gh-rest-no-subshell-lint.sh) keeps GH_REST_STATUS in this shell.
  tmp=$(mktemp "${TMPDIR:-/tmp}/mmn-pr.XXXXXX") || return 1
  if ! gh_rest GET "repos/$slug/pulls/$pr" > "$tmp" 2>/dev/null; then rm -f "$tmp"; return 1; fi
  jq -r '[
      (if ([.labels[]?.name] | any(. == "queued" or . == "checking")) then 1 else 0 end),
      (if .mergeable == null then "null" else (.mergeable | tostring) end),
      (.mergeable_state // "unknown")
    ] | map(tostring) | join(" ")' < "$tmp" 2>/dev/null; rc=$?
  rm -f "$tmp"
  return "$rc"
}

# _mmn_merge_tree <git-dir> <main-ref> <head> -> rc 0 clean | 1 conflict | 2 could not run
_mmn_merge_tree() {
  local rc=0
  # --attr-source reads .gitattributes (the union merge drivers) from main, as
  # the merge itself would. Git before 2.43 rejects the option: retry without.
  git -C "$1" --attr-source="$2" merge-tree --write-tree --name-only --no-messages "$2" "$3" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -gt 1 ]; then
    rc=0
    git -C "$1" merge-tree --write-tree --name-only --no-messages "$2" "$3" >/dev/null 2>&1 || rc=$?
  fi
  [ "$rc" -gt 1 ] && return 2
  return "$rc"
}

pr_needs_main_merge() {
  local slug="${1:-}" pr="${2:--}" g="${3:-}" head="${4:-}" main="${5:-origin/main}"
  local q="" m="" s="" gh_ok=0 mt=2 stale
  if [ "${MAIN_MERGE_GATE:-1}" = 0 ]; then echo gate-off; return 0; fi
  if [[ "$pr" =~ ^[0-9]+$ ]] && [ -n "$slug" ]; then
    if read -r q m s <<<"$(_mmn_pr_read "$slug" "$pr")" && [ -n "$q" ]; then
      gh_ok=1
      if [ "$q" = 1 ]; then echo queued; return 1; fi
      if [ "$m" = false ] || [ "$s" = dirty ]; then echo conflict-github; return 0; fi
    fi
  fi
  if [ -n "$g" ] && [ -n "$head" ] && git -C "$g" rev-parse --verify -q "$head^{commit}" >/dev/null 2>&1; then
    _mmn_merge_tree "$g" "$main" "$head"; mt=$?
  fi
  if [ "$mt" = 1 ]; then echo conflict-merge-tree; return 0; fi
  if [ "$mt" = 0 ]; then
    command -v sr_plan >/dev/null 2>&1 || . "$_mmn_dir/schema-restamp.sh" 2>/dev/null
    if command -v sr_plan >/dev/null 2>&1; then
      stale=$(sr_plan "$g" "$main" "$head" 2>/dev/null) || stale=""
      if [ -n "$stale" ]; then echo schema-stamp; return 0; fi
    fi
    echo clean; return 1
  fi
  if [ "$gh_ok" = 1 ] && [ "$m" = true ]; then echo clean; return 1; fi
  echo unknown; return 2
}

# pr_main_merge_why <word> -> the log phrase for a skip word.
pr_main_merge_why() {
  case "${1:-}" in
    queued) echo "in the merge queue (queued label)" ;;
    *)      echo "clean against main" ;;
  esac
}
