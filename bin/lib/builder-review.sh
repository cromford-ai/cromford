#!/bin/bash
# bin/lib/builder-review.sh — BH-5355: the builder review of ONE head, for the
# lead review's build-on mode (bin/lead-review.sh). Sourced; defines functions
# only. Needs gh_rest (bin/lib/gh-rest.sh) and verdict_parse
# (bin/lib/verdict-parse.sh), which the lane sources first.
#
# The builder review is what bin/review-prs.sh posts on GitHub: the model's
# answer, then a `---` line and the footer `_$RP_MARKER <sha>. ..._`.
#
#   br_fetch <owner/repo> <pr> <sha> <out-file>
#     rc 0  found; <out-file> holds the section body:
#             verdict: <APPROVE|REQUEST_CHANGES>
#             reviewed sha: <sha>
#             reviewer: <login>
#             (blank line, then the review body as posted)
#     rc 1  no usable builder review of <sha>
#     rc 2  could not read (the lead then does a full review)
#     BR_WHY is the reason on every rc. BR_VERDICT is set on rc 0.
#
# A review counts only when ALL of these hold:
#   * GitHub's commit_id is <sha> (a review of an older push is not used);
#   * the body carries "$BR_MARKER <sha>", the review-prs.sh footer (the
#     trivial-route advisory read has no marker, so it never counts);
#   * the author is a verdict author (harness_verdict_author_match,
#     bin/lib/gh-pr-list.sh): the builders App and a PR author never are.
# Several on one head (a re-review): the last by submitted_at, then id.
# A full page (100 reviews) is rc 2: the newest review could be on page 2.

# The same string as RP_MARKER in bin/review-prs.sh (the suite pins the two).
BR_MARKER="Automated harness review (Fable) of"

_br_root() { printf '%s' "${HARNESS:-${H:-}}"; }
# The author matcher. Beside the harness root first, then beside this file.
if ! command -v harness_verdict_author_match >/dev/null 2>&1; then
  if [ -n "$(_br_root)" ] && [ -r "$(_br_root)/bin/lib/gh-pr-list.sh" ]; then
    # shellcheck source=bin/lib/gh-pr-list.sh
    . "$(_br_root)/bin/lib/gh-pr-list.sh" 2>/dev/null
  else
    # shellcheck source=bin/lib/gh-pr-list.sh
    . "$(dirname "${BASH_SOURCE[0]}")/gh-pr-list.sh" 2>/dev/null
  fi
fi

br_fetch() {
  local repo="${1:-}" pr="${2:-}" sha="${3:-}" out="${4:-}" tmp rc=0 n login state body v
  BR_WHY=""; BR_VERDICT=""
  if [ -z "$repo" ] || ! [[ "$pr" =~ ^[0-9]+$ && "$sha" =~ ^[0-9a-f]{40}$ ]] || [ -z "$out" ]; then
    BR_WHY="bad arguments"; return 2
  fi
  command -v harness_verdict_author_match >/dev/null 2>&1 || { BR_WHY="author matcher missing"; return 2; }
  command -v gh_rest >/dev/null 2>&1 || { BR_WHY="gh_rest missing"; return 2; }
  command -v verdict_parse >/dev/null 2>&1 || { BR_WHY="verdict reader missing"; return 2; }
  tmp=$(mktemp "${TMPDIR:-/tmp}/br-reviews.XXXXXX") || { BR_WHY="no temp file"; return 2; }
  gh_rest GET "repos/$repo/pulls/$pr/reviews?per_page=100" > "$tmp" 2>/dev/null || rc=$?
  if [ "$rc" != 0 ] || ! jq -e 'type == "array"' "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"; BR_WHY="reviews read failed: rc $rc, HTTP ${GH_REST_STATUS:-000}"; return 2
  fi
  n=$(jq 'length' "$tmp")
  if [ "${n:-0}" -ge 100 ]; then rm -f "$tmp"; BR_WHY="reviews list may be cut at 100"; return 2; fi
  # Newest first; the first one by a verdict author is the one used.
  while IFS=$'\t' read -r login state body; do
    [ -n "$login" ] || continue
    # or the operator login a PAT post goes out as (BH-8466; the jq select below
    # requires the marker). A lib without the own matcher falls to the verdict one.
    harness_own_review_match "$login" 2>/dev/null || harness_verdict_author_match "$login" || continue
    body=$(printf '%s' "$body" | base64 -d 2>/dev/null) || continue
    # The shared reader, footer (after the last ---) dropped; then the state.
    v=$(printf '%s\n' "$body" | verdict_parse -c -w 'APPROVE|REQUEST_CHANGES' 2>/dev/null) || v=""
    if [ -z "$v" ]; then
      case "$state" in APPROVED) v=APPROVE ;; CHANGES_REQUESTED) v=REQUEST_CHANGES ;; esac
    fi
    rm -f "$tmp"
    [ -n "$v" ] || { BR_WHY="builder review has no verdict"; return 1; }
    printf 'verdict: %s\nreviewed sha: %s\nreviewer: %s\n\n%s\n' "$v" "$sha" "$login" "$body" > "$out" \
      || { BR_WHY="could not write $out"; return 2; }
    BR_VERDICT="$v"; BR_WHY="builder review $v by $login"
    return 0
  done < <(jq -r --arg s "$sha" --arg m "$BR_MARKER $sha" '
    [.[] | select(.commit_id == $s) | select((.body // "") | contains($m))]
    | sort_by(.submitted_at // "", .id // 0) | reverse | .[]
    | [(.user.login // ""), (.state // ""), ((.body // "") | @base64)] | @tsv' "$tmp" 2>/dev/null)
  rm -f "$tmp"
  BR_WHY="no builder review on ${sha:0:12}"
  return 1
}
