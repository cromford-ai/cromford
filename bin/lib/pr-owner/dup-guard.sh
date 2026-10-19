#!/bin/bash
# bin/lib/pr-owner/dup-guard.sh — BH-6929: the duplicate-close guard of
# bin/pr-owner-sweep.sh. Sourced, never executed. Rules: docs/PR-OWNERSHIP.md.
#
# po_dup_guard — called before every DUPLICATE close: po_superseded rules 1
#   and 3 (bin/lib/pr-owner/superseded.sh) and the sweep's close-duplicate arm.
#   Takes no args; reads the sweep's per-PR context (PO_SLUG PO_NUM PO_HEAD
#   PO_EKEY PO_MC_STATE PO_PROJECT), $TD/open.json, $TD/verdicts.tsv and
#   PR_OWNER_REPO_ROOT (the checkouts, `<root>/<project>`; empty = REST only).
#   rc 0 = KEEP: one `say` line `<slug>#<n>: duplicate close refused — <tag>:
#   <detail>`, and HELD += #n:<tag>. rc 1 = clear to close. First match keeps:
#     slice           the title says `slice` or `part N`
#     blocked-by      another open PR's body has a `Blocked-by:` line naming it
#     armed           the conductor has it READY, QUEUED or MERGING
#     approved        a latest review is APPROVED
#     reopened        its issue events hold a `reopened` (a human undid a close)
#     not-a-duplicate a PR comment says "not a duplicate"
#     stacked         its head is an ancestor of the head of another open PR
#                     with the same key, or that head is an ancestor of its
#                     head: `git merge-base --is-ancestor` when the checkout
#                     has both commits, else REST compare
#     guard-unread    a read failed or did not parse, or the key has more open
#                     PRs than PO_DUP_GUARD_SIBLINGS_MAX. Fail closed: the next
#                     sweep tries again.
#   `reopened` and `not-a-duplicate` are GitHub's own records, so once true
#   they keep the PR on every later sweep.
#
# po_dup_closed — after a repo's PR loop: prints the entries of $CLOSED that
#   are duplicate closes, comma-joined (empty when none, and always under
#   DRY=1). A `superseded:ticket-*` close is not a duplicate close. The sweep
#   sends its one per-repo alert as critical (Telegram now) when this is set.

PO_DUP_GUARD_SIBLINGS_MAX=10

_po_dg_say() { if declare -F say >/dev/null 2>&1; then say "$*"; else echo "$*" >&2; fi; }
_po_dg_keep() { # <tag> <detail>
  _po_dg_say "${PO_SLUG}#$PO_NUM: duplicate close refused — $1: $2"
  HELD="${HELD:+$HELD,}#$PO_NUM:$1"
  return 0
}

# The REST helper, loaded on first use from next to this lib.
_po_dg_rest() {
  command -v gh_rest >/dev/null 2>&1 && return 0
  # shellcheck source=bin/lib/gh-rest.sh
  [ -r "${BASH_SOURCE[0]%/*}/../gh-rest.sh" ] && . "${BASH_SOURCE[0]%/*}/../gh-rest.sh"
  command -v gh_rest >/dev/null 2>&1
}

# _po_dg_list <path> — the JSON array GET answers, rc 1 for a failed read, a
# body that is not an array, or a full page (the rest was not read). The read
# goes to a file in $TD, never into `$( )`: bin/lib/gh-rest.sh's rule
# (tests/gh-rest-no-subshell-lint.sh) keeps GH_REST_STATUS in this shell.
_po_dg_list() {
  local f="$TD/dup-guard.rest.json"
  gh_rest GET "$1?per_page=100" </dev/null >"$f" 2>/dev/null || return 1
  jq -e 'type == "array" and length < 100' >/dev/null 2>&1 <"$f" || return 1
  cat "$f"
}

# _po_dg_related <a> <b> — rc 0 one head is an ancestor of the other (or they
# are the same commit), rc 1 diverged, rc 2 unknown.
_po_dg_related() {
  local a="$1" b="$2" repo="" st
  [ -n "${PR_OWNER_REPO_ROOT:-}" ] && [ "${PO_PROJECT:--}" != - ] && repo="$PR_OWNER_REPO_ROOT/$PO_PROJECT"
  if [ -n "$repo" ] && git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 \
     && git -C "$repo" cat-file -e "$a^{commit}" 2>/dev/null && git -C "$repo" cat-file -e "$b^{commit}" 2>/dev/null; then
    git -C "$repo" merge-base --is-ancestor "$a" "$b" 2>/dev/null && return 0
    git -C "$repo" merge-base --is-ancestor "$b" "$a" 2>/dev/null && return 0
    return 1
  fi
  _po_dg_rest || return 2
  gh_rest GET "repos/$PO_SLUG/compare/$a...$b?per_page=1" </dev/null >"$TD/dup-guard.rest.json" 2>/dev/null || return 2
  st=$(jq -r '.status // empty' "$TD/dup-guard.rest.json" 2>/dev/null)
  case "$st" in
    ahead|behind|identical) return 0 ;;
    diverged) return 1 ;;
  esac
  return 2
}

po_dup_guard() {
  local n="${PO_NUM:-}" slug="${PO_SLUG:-}" me t named sibs cnt sn sh l
  if [ -z "$n" ] || [ -z "$slug" ] || [ -z "${TD:-}" ] || [ ! -r "$TD/open.json" ]; then
    _po_dg_keep guard-unread "no open-PR list to check"; return 0
  fi
  me=$(jq -c --argjson n "$n" '[.[]? | select(.number == $n)][0] // empty' "$TD/open.json" 2>/dev/null)
  [ -n "$me" ] || { _po_dg_keep guard-unread "#$n is not in the open-PR list"; return 0; }

  t=$(jq -r '.title // ""' <<<"$me")
  if jq -e '(.title // "") | test("\\bslice\\b|\\bpart\\s*\\d"; "i")' >/dev/null 2>&1 <<<"$me"; then
    _po_dg_keep slice "the title \"$t\" names a slice of the ticket"; return 0
  fi
  named=$(jq -r --argjson n "$n" '[.[]? | select(.number != $n)
      | select((.body // "") | split("\n")
               | any(test("^[\\s>*_-]*blocked[- ]?by\\s*:"; "i") and test("(#|/pull/)\($n)(?![0-9])")))
      | "#\(.number)"] | join(", ")' "$TD/open.json" 2>/dev/null) \
    || { _po_dg_keep guard-unread "the open-PR bodies did not parse"; return 0; }
  [ -n "$named" ] && { _po_dg_keep blocked-by "$named names it in Blocked-by"; return 0; }
  case "${PO_MC_STATE:--}" in
    READY|QUEUED|MERGING) _po_dg_keep armed "the merge conductor has it $PO_MC_STATE"; return 0 ;;
  esac
  case "$(jq -r 'if (.latestReviews | type) != "array" then "!"
                 elif any(.latestReviews[]; .state == "APPROVED") then "y" else "n" end' <<<"$me" 2>/dev/null)" in
    y) _po_dg_keep approved "it has an APPROVE review"; return 0 ;;
    n) ;;
    *) _po_dg_keep guard-unread "the open-PR list has no latestReviews for it"; return 0 ;;
  esac

  _po_dg_rest || { _po_dg_keep guard-unread "bin/lib/gh-rest.sh is not loadable"; return 0; }
  l=$(_po_dg_list "repos/$slug/issues/$n/events") || { _po_dg_keep guard-unread "its issue events could not be read"; return 0; }
  if jq -e 'any(.[]; .event == "reopened")' >/dev/null 2>&1 <<<"$l"; then
    _po_dg_keep reopened "it was closed and reopened before"; return 0
  fi
  l=$(_po_dg_list "repos/$slug/issues/$n/comments") || { _po_dg_keep guard-unread "its comments could not be read"; return 0; }
  if jq -e 'any(.[]; (.body // "") | test("not a duplicate"; "i"))' >/dev/null 2>&1 <<<"$l"; then
    _po_dg_keep not-a-duplicate "a comment says it is not a duplicate"; return 0
  fi

  [ "${PO_EKEY:--}" = - ] && return 1
  [ -r "$TD/verdicts.tsv" ] || { _po_dg_keep guard-unread "no verdicts to find its siblings"; return 0; }
  sibs=$(awk -F'\t' -v n="$n" -v k="$PO_EKEY" '$1 != n && $12 == k { print $1 "\t" $11 }' "$TD/verdicts.tsv")
  [ -n "$sibs" ] || return 1
  cnt=$(grep -c . <<<"$sibs")
  if [ "$cnt" -gt "$PO_DUP_GUARD_SIBLINGS_MAX" ]; then
    _po_dg_keep guard-unread "$PO_EKEY has $cnt other open PRs, over the $PO_DUP_GUARD_SIBLINGS_MAX checked"; return 0
  fi
  if [ "${PO_HEAD:--}" = - ]; then _po_dg_keep guard-unread "its head sha is unknown"; return 0; fi
  while IFS=$'\t' read -r sn sh; do
    if [ "${sh:--}" = - ]; then _po_dg_keep guard-unread "the head of #$sn is unknown"; return 0; fi
    _po_dg_related "$PO_HEAD" "$sh"
    case $? in
      0) _po_dg_keep stacked "its head and the head of #$sn are one stack"; return 0 ;;
      1) ;;
      *) _po_dg_keep guard-unread "its head could not be compared with #$sn"; return 0 ;;
    esac
  done <<<"$sibs"
  return 1
}

po_dup_closed() {
  [ "${DRY:-0}" = 1 ] && return 0
  tr ',' '\n' <<<"${CLOSED:-}" | grep -E '\((dup of #|superseded:(merged|newer|ready)-#)' | paste -sd, -
  return 0
}
